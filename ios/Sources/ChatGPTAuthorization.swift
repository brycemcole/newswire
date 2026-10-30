import CryptoKit
import Foundation
import Security

struct ChatGPTAuthorization {
    enum Failure: Error {
        case randomness
        case invalidRedirect
        case invalidCallback
        case denied
    }

    let state: String
    let nonce: String
    let verifier: String
    let redirect: URL
    let hostID: String
    let clientID: String?
    let idTokenHint: String?
    let loginHint: String?
    let consent: Bool

    init(redirect: URL, hostID: String, clientID: String? = nil, idTokenHint: String? = nil, loginHint: String? = nil, consent: Bool = false) throws {
        guard redirect.scheme == "http", redirect.host == "127.0.0.1", redirect.port != nil,
              redirect.path == "/auth/callback", redirect.query == nil, redirect.fragment == nil else {
            throw Failure.invalidRedirect
        }
        self.redirect = redirect
        self.hostID = hostID
        self.clientID = clientID
        self.idTokenHint = clientID == nil ? nil : idTokenHint
        self.loginHint = clientID == nil ? nil : loginHint
        self.consent = consent
        state = try Self.randomValue()
        nonce = try Self.randomValue()
        verifier = try Self.randomValue()
    }

    var authorizationURL: URL {
        var components = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")!
        var items = [
            URLQueryItem(name: "client_id", value: clientID ?? "dynamic_agent_client"),
            URLQueryItem(name: "ext_agent_host_id", value: hostID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirect.absoluteString),
            URLQueryItem(name: "scope", value: "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"),
            URLQueryItem(name: "resource", value: "https://api.openai.com/v1"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))))
        ]
        if clientID == nil { items.append(URLQueryItem(name: "agent_name_hint", value: "Newswire")) }
        if let idTokenHint { items.append(URLQueryItem(name: "id_token_hint", value: idTokenHint)) }
        if let loginHint { items.append(URLQueryItem(name: "login_hint", value: loginHint)) }
        if consent { items.append(URLQueryItem(name: "prompt", value: "consent")) }
        components.queryItems = items
        return components.url!
    }

    func callback(_ url: URL) throws -> (code: String, clientID: String) {
        guard url.scheme == redirect.scheme, url.host == redirect.host, url.port == redirect.port,
              url.path == redirect.path, url.fragment == nil,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { throw Failure.invalidCallback }
        func value(_ name: String) -> String? {
            let matches = items.filter { $0.name == name }
            return matches.count == 1 ? matches[0].value : nil
        }
        guard value("state") == state else { throw Failure.invalidCallback }
        if items.contains(where: { $0.name == "error" }) { throw Failure.denied }
        guard let code = value("code"), !code.isEmpty else { throw Failure.invalidCallback }
        let returnedID = value("client_id")
        let issuedID = clientID ?? returnedID
        guard let issuedID, issuedID.hasPrefix("oaiapp_"),
              !items.contains(where: { $0.name == "client_id" }) || returnedID != nil,
              returnedID == nil || returnedID == issuedID else { throw Failure.invalidCallback }
        return (code, issuedID)
    }

    private static func randomValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw Failure.randomness }
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
