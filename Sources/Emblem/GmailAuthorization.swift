import AppKit
import AppAuth
import Security
import LocalAuthentication
import PortraitCore

struct GmailOAuthClient: Codable, Equatable {
    var clientID:String
    var clientSecret:String?
    // Google rejects desktop token exchange when this configuration is absent.
    // Installed-app configuration is public; user authorization is not.
    var readyForTokenExchange:Bool {clientSecret?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty == false}
    static func parse(_ data:Data)throws->Self {
        struct File:Decodable {struct Client:Decodable {var client_id:String;var client_secret:String?};var installed:Client?}
        guard data.count<64_000,let client=try JSONDecoder().decode(File.self,from:data).installed,
              client.client_id.hasSuffix(".apps.googleusercontent.com"),!client.client_id.contains(where:{$0.isWhitespace}) else {
            throw PortraitError.message("Choose a Google OAuth JSON file for a Desktop app, not a web client.")
        }
        return Self(clientID:client.client_id,clientSecret:client.client_secret)
    }
}
struct GmailOAuthTokens: Sendable {
    var accessToken:String
    var idToken:String?
}
/// Secrets stay in this Mac's Keychain, not the JSON library, diagnostics or URLs.
enum GmailKeychain {
    static let service="com.protoyard.emblem.gmail"
    static let legacyService=EmblemMigration.legacyKeychainService
    static func context()->LAContext {let value=LAContext();value.interactionNotAllowed=true;return value}
    private static func read(_ account:String,service:String)throws->Data? {
        let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne,kSecUseAuthenticationContext as String:context()]
        var result:CFTypeRef?;let code=SecItemCopyMatching(query as CFDictionary,&result)
        if code==errSecItemNotFound {return nil}
        guard code==errSecSuccess else {throw PortraitError.message("Unlock the login Keychain to use Gmail (\(code)).")}
        return result as? Data
    }
    static func read(_ account:String)throws->Data? {
        if let current=try read(account,service:service) {return current}
        guard let legacy=try read(account,service:legacyService) else{return nil}
        try save(legacy,account:account)
        return legacy
    }
    static func save(_ data:Data,account:String)throws {
        let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account,kSecUseAuthenticationContext as String:context()]
        let attributes:[String:Any]=[kSecValueData as String:data,kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var code=SecItemUpdate(query as CFDictionary,attributes as CFDictionary)
        if code==errSecItemNotFound {code=SecItemAdd(query.merging(attributes){_,new in new} as CFDictionary,nil)}
        guard code==errSecSuccess else {throw PortraitError.message("Gmail credentials were not saved to Keychain (\(code)).")}
    }
    static func delete(_ account:String)throws {
        let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account,kSecUseAuthenticationContext as String:context()]
        let code=SecItemDelete(query as CFDictionary)
        guard code==errSecSuccess || code==errSecItemNotFound else {throw PortraitError.message("Gmail credentials remain in Keychain (\(code)).")}
    }
}
@MainActor final class GmailAuthorization {
    private var handler:OIDRedirectHTTPHandler?
    private var timeout:Task<Void,Never>?
    private var gate:GmailAuthorizationGate<OIDAuthState>?
    private var states:[String:OIDAuthState]=[:]
    static let clientKey="desktop-client"
    static let identityScopes=["openid","email",GmailAPI.scope]
    static func hasRequiredScopes(_ scope:String?)->Bool {
        // Google canonicalizes the OpenID `email` alias in token responses.
        // Accept the equivalent scope, still requiring openid and gmail.metadata.
        func canonical(_ value:String)->String {value == "email" ? "https://www.googleapis.com/auth/userinfo.email" : value}
        let granted=Set((scope ?? "").split(separator:" ").map{canonical(String($0))})
        return Set(identityScopes.map(canonical)).isSubset(of:granted)
    }
    init() {
        let configuration=URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest=15;configuration.timeoutIntervalForResource=20
        configuration.httpCookieStorage=nil;configuration.urlCredentialStorage=nil
        OIDURLSessionProvider.setSession(URLSession(configuration:configuration))
    }
    func configuredClient()throws->GmailOAuthClient? {
        let embedded=Bundle.main.object(forInfoDictionaryKey:"EmblemGoogleClientID") as? String
        let configuration=Bundle.main.object(forInfoDictionaryKey:"EmblemGoogleClientSecret") as? String
        let stored=try GmailKeychain.read(Self.clientKey).map{try JSONDecoder().decode(GmailOAuthClient.self,from:$0)}
        return Self.client(embeddedID:embedded,embeddedSecret:configuration,stored:stored)
    }
    static func client(embeddedID:String?,embeddedSecret:String?=nil,stored:GmailOAuthClient?)->GmailOAuthClient? {
        guard let id=embeddedID,id.hasSuffix(".apps.googleusercontent.com") else{return stored}
        // Preserve an imported desktop client's matching configuration. Never
        // attach another OAuth client's secret to the embedded public client ID.
        if let stored,stored.clientID == id,stored.readyForTokenExchange {return stored}
        let bundled=GmailOAuthClient(clientID:id,clientSecret:embeddedSecret)
        return bundled.readyForTokenExchange ? bundled:(stored?.clientID == id ? stored:bundled)
    }
    func importClient(_ data:Data)throws {try GmailKeychain.save(JSONEncoder().encode(GmailOAuthClient.parse(data)),account:Self.clientKey)}
    static func request(client:GmailOAuthClient,redirect:URL)->OIDAuthorizationRequest {
        let configuration=OIDServiceConfiguration(authorizationEndpoint:URL(string:"https://accounts.google.com/o/oauth2/v2/auth")!,tokenEndpoint:URL(string:"https://oauth2.googleapis.com/token")!,issuer:URL(string:"https://accounts.google.com")!)
        return OIDAuthorizationRequest(configuration:configuration,clientId:client.clientID,clientSecret:client.clientSecret,scopes:identityScopes,redirectURL:redirect,responseType:OIDResponseTypeCode,additionalParameters:["access_type":"offline","prompt":"consent select_account"])
    }
    func authorize(client:GmailOAuthClient)async throws->OIDAuthState {
        guard handler==nil else{throw PortraitError.message("A Gmail sign-in is already open.")}
        let listener=OIDRedirectHTTPHandler(successURL:nil)
        var listenerError:NSError?
        let redirect=listener.startHTTPListener(&listenerError,withPort:0)
        if let listenerError {throw listenerError}
        handler=listener
        let attemptID=UUID()
        defer {timeout?.cancel();timeout=nil;listener.cancelHTTPListener();handler=nil;if gate?.id == attemptID {gate=nil}}
        guard (NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first) != nil else {
            throw PortraitError.message("Open the Emblem window before connecting Gmail.")
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let attempt=GmailAuthorizationGate<OIDAuthState>(id:attemptID) {continuation.resume(with:$0)}
                gate=attempt
                listener.currentAuthorizationFlow=OIDAuthState.authState(byPresenting:Self.request(client:client,redirect:redirect),externalUserAgent:GmailBrowserAgent()) { state,error in
                    Task { @MainActor in
                        if let state,state.isAuthorized,Self.hasRequiredScopes(state.scope) {
                            attempt.finish(.success(state))
                        } else if (error as NSError?)?.code == OIDErrorCode.userCanceledAuthorizationFlow.rawValue {
                            attempt.finish(.failure(CancellationError()))
                        } else {attempt.finish(.failure(PortraitError.message("Gmail sign-in did not finish. Check the Google consent screen and try again.")))}
                    }
                }
                timeout=Task {
                    try? await Task.sleep(for:.seconds(600));guard !Task.isCancelled else{return}
                    attempt.finish(.failure(PortraitError.message("Google sign-in timed out. Please reconnect.")))
                    await listener.currentAuthorizationFlow?.cancel();listener.cancelHTTPListener()
                }
            }
        } onCancel: { Task { @MainActor in self.cancel(attemptID:attemptID) } }
    }
    func save(_ state:OIDAuthState,accountID:String)throws {
        let data=try NSKeyedArchiver.archivedData(withRootObject:state,requiringSecureCoding:true)
        try GmailKeychain.save(data,account:accountID);states[accountID]=state
    }
    func token(accountID:String)async throws->String {
        let pair=try await tokens(accountID:accountID)
        return pair.accessToken
    }
    func statusMetadata(accountID:String)throws->[String:Bool] {
        let state=try loadState(accountID:accountID)
        return ["authorized":state.isAuthorized,"requiredScopesGranted":Self.hasRequiredScopes(state.scope),
                "idTokenPresent":state.lastTokenResponse?.idToken != nil,
                "clientSecretPresent":state.lastAuthorizationResponse.request.clientSecret != nil]
    }
    func tokens(accountID:String,forceRefresh:Bool=false)async throws->GmailOAuthTokens {
        let state=try loadState(accountID:accountID)
        let pair=try await Self.freshTokens(state,forceRefresh:forceRefresh)
        try Task.checkCancellation()
        try save(state,accountID:accountID)
        return pair
    }
    private func loadState(accountID:String)throws->OIDAuthState {
        if let existing=states[accountID] {return existing}
        guard let data=try GmailKeychain.read(accountID),let stored=try NSKeyedUnarchiver.unarchivedObject(ofClass:OIDAuthState.self,from:data) else {throw GmailHTTPError(status:401)}
        states[accountID]=stored;return stored
    }
    static func freshToken(_ state:OIDAuthState)async throws->String {
        try await freshTokens(state).accessToken
    }
    static func freshTokens(_ state:OIDAuthState,forceRefresh:Bool=false)async throws->GmailOAuthTokens {
        if forceRefresh {state.setNeedsTokenRefresh()}
        return try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<GmailOAuthTokens,Error>) in
            state.performAction { token,idToken,error in
                if error != nil {continuation.resume(throwing:GmailHTTPError(status:401))}
                else if let token {continuation.resume(returning:GmailOAuthTokens(accessToken:token,idToken:idToken))}
                else {continuation.resume(throwing:GmailHTTPError(status:401))}
            }
        }
    }
    func forget(accountID:String)throws {try GmailKeychain.delete(accountID);try GmailPushCredentials.delete(accountID:accountID);states.removeValue(forKey:accountID)}
    func cancel(attemptID:UUID?=nil) {
        guard attemptID == nil || gate?.id == attemptID else{return}
        gate?.finish(.failure(CancellationError()))
        handler?.currentAuthorizationFlow?.cancel();handler?.cancelHTTPListener()
    }
}
