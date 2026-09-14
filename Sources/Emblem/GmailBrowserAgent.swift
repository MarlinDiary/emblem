import AppKit
import AppAuth

/// Desktop OAuth uses a random loopback port. Open the system's default browser
/// directly instead of passing an HTTP callback to ASWebAuthenticationSession.
/// AppAuth still owns PKCE/state validation and the loopback HTTP handler.
final class GmailBrowserAgent: NSObject, OIDExternalUserAgent {
    private let open:(URL)->Bool
    private var presented=false
    init(open:@escaping (URL)->Bool={NSWorkspace.shared.open($0)}) {self.open=open}
    func present(_ request:OIDExternalUserAgentRequest,session:OIDExternalUserAgentSession)->Bool {
        guard !presented,let url=request.externalUserAgentRequestURL(),
              url.scheme == "https",url.host == "accounts.google.com",
              url.path == "/o/oauth2/v2/auth" else {return false}
        presented=open(url)
        return presented
    }
    func dismiss(animated:Bool,completion:@escaping @Sendable ()->Void) {
        presented=false
        // Never close unrelated browser windows or inspect browser credentials.
        completion()
    }
}
