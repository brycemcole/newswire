import CryptoKit
import Foundation
import Testing
@testable import Newswire

struct ChatGPTAuthorizationTests {
    private let redirect = URL(string: "http://127.0.0.1:1455/auth/callback")!

    @Test func newRegistrationUsesPKCEAndPlanScopes() throws {
        let attempt = try ChatGPTAuthorization(redirect: redirect, hostID: "urn:uuid:test")
        let items = try #require(URLComponents(url: attempt.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        let digest = Data(SHA256.hash(data: Data(attempt.verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        #expect(values["client_id"] == "dynamic_agent_client")
        #expect(values["agent_name_hint"] == "Newswire")
        #expect(values["code_challenge"] == digest)
        #expect(values["scope"]?.contains("chatgpt.tokens.use.direct") == true)
        #expect(attempt.verifier.count == 43)
        let another = try ChatGPTAuthorization(redirect: redirect, hostID: "urn:uuid:test")
        #expect(attempt.state != another.state)
        #expect(attempt.nonce != another.nonce)
    }

    @Test func callbackRequiresMatchingStateAndIssuedClient() throws {
        let attempt = try ChatGPTAuthorization(redirect: redirect, hostID: "urn:uuid:test")
        func url(_ query: String) -> URL { URL(string: "\(redirect.absoluteString)?\(query)")! }
        let result = try attempt.callback(url("state=\(attempt.state)&code=test&client_id=oaiapp_example"))
        #expect(result.clientID == "oaiapp_example")
        #expect(throws: ChatGPTAuthorization.Failure.self) { try attempt.callback(url("state=wrong&code=test&client_id=oaiapp_example")) }
        #expect(throws: ChatGPTAuthorization.Failure.self) { try attempt.callback(url("state=\(attempt.state)&code=test")) }
        #expect(throws: ChatGPTAuthorization.Failure.self) { try attempt.callback(url("state=\(attempt.state)&code=test&client_id=oaiapp_a&client_id=oaiapp_b")) }
        #expect(throws: ChatGPTAuthorization.Failure.self) { try attempt.callback(url("state=\(attempt.state)&error=access_denied")) }
    }

    @Test func returningClientCannotBeReplaced() throws {
        let attempt = try ChatGPTAuthorization(redirect: redirect, hostID: "urn:uuid:test", clientID: "oaiapp_saved")
        let url = URL(string: "\(redirect.absoluteString)?state=\(attempt.state)&code=test&client_id=oaiapp_other")!
        #expect(throws: ChatGPTAuthorization.Failure.self) { try attempt.callback(url) }
        #expect(!attempt.authorizationURL.absoluteString.contains("agent_name_hint"))
    }

    @Test func hintsOnlyAccompanyASavedClient() throws {
        let fresh = try ChatGPTAuthorization(redirect: redirect, hostID: "urn:uuid:test", idTokenHint: "token", loginHint: "a@b.c")
        #expect(!fresh.authorizationURL.absoluteString.contains("id_token_hint"))
        #expect(!fresh.authorizationURL.absoluteString.contains("login_hint"))
        let returning = try ChatGPTAuthorization(redirect: redirect, hostID: "urn:uuid:test", clientID: "oaiapp_saved", idTokenHint: "token", loginHint: "a@b.c", consent: true)
        let items = try #require(URLComponents(url: returning.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.contains(URLQueryItem(name: "id_token_hint", value: "token")))
        #expect(items.contains(URLQueryItem(name: "login_hint", value: "a@b.c")))
        #expect(items.contains(URLQueryItem(name: "prompt", value: "consent")))
    }

    @Test func rejectsNonLoopbackRedirect() {
        #expect(throws: ChatGPTAuthorization.Failure.self) {
            try ChatGPTAuthorization(redirect: URL(string: "http://localhost:1455/auth/callback")!, hostID: "urn:uuid:test")
        }
    }
}
