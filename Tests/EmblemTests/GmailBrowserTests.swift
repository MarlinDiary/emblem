import XCTest
import AppAuth
@testable import Emblem

final class GmailBrowserTests: XCTestCase {
    @MainActor private func request()->OIDAuthorizationRequest {
        GmailAuthorization.request(client:GmailOAuthClient(clientID:"fixture.apps.googleusercontent.com"),redirect:URL(string:"http://127.0.0.1:41001")!)
    }
    @MainActor func testDefaultBrowserReceivesOnlyGooglePKCERequest() async {
        var opened:URL?
        let agent=GmailBrowserAgent(open:{opened=$0;return true})
        let done=expectation(description:"cancelled")
        let flow=OIDAuthState.authState(byPresenting:request(),externalUserAgent:agent) {state,error in
            XCTAssertNil(state);XCTAssertNotNil(error);done.fulfill()
        }
        XCTAssertEqual(opened?.host,"accounts.google.com")
        let query=URLComponents(url:opened!,resolvingAgainstBaseURL:false)!.queryItems!
        XCTAssertEqual(query.first{$0.name == "code_challenge_method"}?.value,"S256")
        XCTAssertNotNil(query.first{$0.name == "state"}?.value)
        XCTAssertFalse(query.contains{$0.name == "code_verifier" || $0.name == "access_token" || $0.name == "refresh_token"})
        await flow.cancel()
        await fulfillment(of:[done],timeout:1)
    }
    @MainActor func testBrowserOpenFailureFinishesRatherThanWaitingForTimeout() async {
        let done=expectation(description:"failed immediately")
        _=OIDAuthState.authState(byPresenting:request(),externalUserAgent:GmailBrowserAgent(open:{_ in false})) {state,error in
            XCTAssertNil(state);XCTAssertNotNil(error);done.fulfill()
        }
        await fulfillment(of:[done],timeout:1)
    }
    @MainActor func testDuplicatePresentationIsRejectedAndCancellationReleasesAgent() async {
        var opens=0
        let agent=GmailBrowserAgent(open:{_ in opens+=1;return true})
        let first=expectation(description:"first cancelled")
        let r=request()
        let flow=OIDAuthState.authState(byPresenting:r,externalUserAgent:agent) {_,_ in first.fulfill()}
        XCTAssertFalse(agent.present(r,session:flow));XCTAssertEqual(opens,1)
        await flow.cancel();await fulfillment(of:[first],timeout:1)
        let second=expectation(description:"second cancelled")
        let next=OIDAuthState.authState(byPresenting:request(),externalUserAgent:agent) {_,_ in second.fulfill()}
        XCTAssertEqual(opens,2)
        await next.cancel();await fulfillment(of:[second],timeout:1)
    }
    func testLoopbackLoginDoesNotUseAuthenticationSheet() throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source=try String(contentsOf:root.appendingPathComponent("Sources/Emblem/GmailAuthorization.swift"))
        XCTAssertTrue(source.contains("externalUserAgent:"),"Loopback OAuth must open the default browser explicitly.")
        XCTAssertFalse(source.contains("presenting:presentingWindow"),"Do not send HTTP loopback OAuth into the authentication-sheet route.")
    }
}
