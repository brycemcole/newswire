import Foundation
import Testing
@testable import Newswire

struct ChatGPTIdentityTests {
    @Test func rejectsMalformedAndUnsignedIdentity() throws {
        let keys = Data(#"{"keys":[]}"#.utf8)
        #expect(throws: (any Error).self) {
            try ChatGPTIdentity.verify("not-a-token", clientID: "oaiapp_test", nonce: "test", keys: keys)
        }
        let header = Data(#"{"alg":"none","kid":"test"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let claims = Data(#"{"iss":"https://auth.openai.com","sub":"test"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        #expect(throws: (any Error).self) {
            try ChatGPTIdentity.verify("\(header).\(claims).", clientID: "oaiapp_test", nonce: "test", keys: keys)
        }
    }
}
