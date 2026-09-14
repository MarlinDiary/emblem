import Foundation

/// Exactly one terminal result, including after the loopback listener has handed
/// off to token exchange. A late callback belongs only to its original attempt.
@MainActor final class GmailAuthorizationGate<Value> {
    let id:UUID
    private var completion:((Result<Value,Error>)->Void)?
    init(id:UUID=UUID(),completion:@escaping (Result<Value,Error>)->Void) {self.id=id;self.completion=completion}
    @discardableResult func finish(_ result:Result<Value,Error>)->Bool {
        guard let completion else{return false}
        self.completion=nil;completion(result);return true
    }
}
