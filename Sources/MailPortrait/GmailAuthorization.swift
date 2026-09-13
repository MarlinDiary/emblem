import AppKit
import AppAuth
import Security
import LocalAuthentication
import PortraitCore

struct GmailOAuthClient: Codable, Equatable {
    var clientID:String
    var clientSecret:String?
    static func parse(_ data:Data)throws->Self {
        struct File:Decodable {struct Client:Decodable {var client_id:String;var client_secret:String?};var installed:Client?}
        guard data.count<64_000,let client=try JSONDecoder().decode(File.self,from:data).installed,
              client.client_id.hasSuffix(".apps.googleusercontent.com"),!client.client_id.contains(where:{$0.isWhitespace}) else {
            throw PortraitError.message("Choose a Google OAuth JSON file for a Desktop app, not a web client.")
        }
        return Self(clientID:client.client_id,clientSecret:client.client_secret)
    }
}
/// Secrets stay in this Mac's Keychain, not the JSON library, diagnostics or URLs.
enum GmailKeychain {
    static let service="org.mailportrait.gmail"
    static func context()->LAContext {let value=LAContext();value.interactionNotAllowed=true;return value}
    static func read(_ account:String)throws->Data? {
        let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne,kSecUseAuthenticationContext as String:context()]
        var result:CFTypeRef?;let code=SecItemCopyMatching(query as CFDictionary,&result)
        if code==errSecItemNotFound {return nil}
        guard code==errSecSuccess else {throw PortraitError.message("Unlock the login Keychain to use Gmail (\(code)).")}
        return result as? Data
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
    private var states:[String:OIDAuthState]=[:]
    static let clientKey="desktop-client"
    init() {
        let configuration=URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest=15;configuration.timeoutIntervalForResource=20
        configuration.httpCookieStorage=nil;configuration.urlCredentialStorage=nil
        OIDURLSessionProvider.setSession(URLSession(configuration:configuration))
    }
    func configuredClient()throws->GmailOAuthClient? {
        if let id=Bundle.main.object(forInfoDictionaryKey:"MailPortraitGoogleClientID") as? String,id.hasSuffix(".apps.googleusercontent.com") {return GmailOAuthClient(clientID:id)}
        guard let data=try GmailKeychain.read(Self.clientKey) else{return nil}
        return try JSONDecoder().decode(GmailOAuthClient.self,from:data)
    }
    func importClient(_ data:Data)throws {try GmailKeychain.save(JSONEncoder().encode(GmailOAuthClient.parse(data)),account:Self.clientKey)}
    static func request(client:GmailOAuthClient,redirect:URL)->OIDAuthorizationRequest {
        let configuration=OIDServiceConfiguration(authorizationEndpoint:URL(string:"https://accounts.google.com/o/oauth2/v2/auth")!,tokenEndpoint:URL(string:"https://oauth2.googleapis.com/token")!)
        return OIDAuthorizationRequest(configuration:configuration,clientId:client.clientID,clientSecret:client.clientSecret,scopes:[GmailAPI.scope],redirectURL:redirect,responseType:OIDResponseTypeCode,additionalParameters:["access_type":"offline","prompt":"consent select_account"])
    }
    func authorize(client:GmailOAuthClient)async throws->OIDAuthState {
        guard handler==nil else{throw PortraitError.message("A Gmail sign-in is already open.")}
        let listener=OIDRedirectHTTPHandler(successURL:nil)
        var listenerError:NSError?
        let redirect=listener.startHTTPListener(&listenerError,withPort:0)
        if let listenerError {throw listenerError}
        handler=listener
        defer {timeout?.cancel();timeout=nil;listener.cancelHTTPListener();handler=nil}
        guard let presentingWindow=NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first else {
            throw PortraitError.message("Open the MailPortrait window before connecting Gmail.")
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                listener.currentAuthorizationFlow=OIDAuthState.authState(byPresenting:Self.request(client:client,redirect:redirect),presenting:presentingWindow) { state,error in
                    Task { @MainActor in
                        if let state,state.isAuthorized,Set((state.scope ?? "").split(separator:" ").map(String.init)).contains(GmailAPI.scope) {
                            continuation.resume(returning:state)
                        } else if (error as NSError?)?.code == OIDErrorCode.userCanceledAuthorizationFlow.rawValue {
                            continuation.resume(throwing:CancellationError())
                        } else {continuation.resume(throwing:PortraitError.message("Gmail sign-in did not finish. Check the Google consent screen and try again."))}
                    }
                }
                timeout=Task {try? await Task.sleep(for:.seconds(180));guard !Task.isCancelled else{return};await listener.currentAuthorizationFlow?.cancel()}
            }
        } onCancel: { Task { @MainActor in await listener.currentAuthorizationFlow?.cancel() } }
    }
    func save(_ state:OIDAuthState,accountID:String)throws {
        let data=try NSKeyedArchiver.archivedData(withRootObject:state,requiringSecureCoding:true)
        try GmailKeychain.save(data,account:accountID);states[accountID]=state
    }
    func token(accountID:String)async throws->String {
        let state:OIDAuthState
        if let existing=states[accountID] {state=existing}
        else {
            guard let data=try GmailKeychain.read(accountID),let stored=try NSKeyedUnarchiver.unarchivedObject(ofClass:OIDAuthState.self,from:data) else {throw GmailHTTPError(status:401)}
            state=stored;states[accountID]=stored
        }
        let token=try await Self.freshToken(state)
        try Task.checkCancellation()
        try save(state,accountID:accountID)
        return token
    }
    static func freshToken(_ state:OIDAuthState)async throws->String {
        try await withCheckedThrowingContinuation { continuation in
            state.performAction { token,_,error in
                if error != nil {continuation.resume(throwing:GmailHTTPError(status:401))}
                else if let token {continuation.resume(returning:token)}
                else {continuation.resume(throwing:GmailHTTPError(status:401))}
            }
        }
    }
    func forget(accountID:String)throws {try GmailKeychain.delete(accountID);states.removeValue(forKey:accountID)}
    func cancel(){handler?.currentAuthorizationFlow?.cancel()}
}
