import AuthenticationServices
import Foundation
import Network
import Observation
import os
import Security

nonisolated struct ChatGPTCredential: Codable, Sendable, Equatable {
    var email: String?
    var subject: String
    var clientID: String
    var idToken: String?
    var accessToken: String?
    var refreshToken: String?
    var expiresAt: Date?
    var scopes: [String]
    var savedAt: Date

    var signedIn: Bool { refreshToken != nil || accessToken != nil }
    var planEnabled: Bool { scopes.contains("chatgpt.tokens.use.direct") }
    var ready: Bool { signedIn && planEnabled }
}

nonisolated struct ChatGPTModel: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

nonisolated enum ChatGPTError: LocalizedError, Equatable {
    case notSignedIn, planDisabled, accountMismatch, sessionExpired, notEligible, usageLimit, unavailable, noModel, incomplete, interrupted
    case unsupported(String)
    case signIn(String)
    case rejected(Int, String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Sign in with ChatGPT in AI settings first."
        case .planDisabled: "ChatGPT plan usage isn't enabled for Newswire. Enable it in AI settings."
        case .accountMismatch: "A different ChatGPT account signed in than the one saved. Choose “Use a different account” to switch."
        case .sessionExpired: "Your ChatGPT session ended. Sign in again in AI settings."
        case .notEligible: "ChatGPT plan usage isn't available for this account or workspace."
        case .usageLimit: "You've reached the ChatGPT usage limit for apps. Check Settings → Usage in ChatGPT."
        case .unavailable: "ChatGPT is temporarily unavailable. Try again shortly."
        case .noModel: "No ChatGPT models are available for this account."
        case .incomplete: "ChatGPT didn't finish its answer. Try a more focused question."
        case .interrupted: "The connection to ChatGPT dropped before the answer finished. Try again."
        case .unsupported(let param): "ChatGPT plan usage doesn't support part of this request\(param.isEmpty ? "" : " (\(param))")."
        case .signIn(let reason): "Couldn't sign in with ChatGPT: \(reason)"
        case .rejected(let status, let message): "ChatGPT returned an error (\(status))\(message.isEmpty ? "." : ": \(message)")"
        }
    }

    static func from(status: Int, body: Data, requestID: String? = nil) -> ChatGPTError {
        let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let error = root?["error"] as? [String: Any]
        let code = error?["code"] as? String ?? ""
        let message = String((error?["message"] as? String ?? root?["detail"] as? String ?? "").prefix(200))
        switch code {
        case "subscription_sharing_user_not_eligible": return .notEligible
        case "subscription_sharing_usage_limit_exceeded": return .usageLimit
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable": return .unavailable
        case "subscription_sharing_unsupported_capability": return .unsupported(error?["param"] as? String ?? "")
        case "subscription_sharing_invalid_user": return .sessionExpired
        default: break
        }
        if status == 401 { return .sessionExpired }
        if status == 503 { return .unavailable }
        return .rejected(status, requestID.map { message.isEmpty ? "request \($0)" : "\(message) (request \($0))" } ?? message)
    }
}

nonisolated enum ChatGPTKeychain {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.brycecole.newswire.chatgpt",
         kSecAttrAccount as String: account]
    }

    static func read(_ account: String) -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func save(_ data: Data?, _ account: String) throws {
        guard let data else {
            let status = SecItemDelete(query(account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw StockAIError.keychain }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query(account).merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw StockAIError.keychain }
        } else if status != errSecSuccess { throw StockAIError.keychain }
    }

    static var credential: ChatGPTCredential? {
        read("credential").flatMap { try? JSONDecoder().decode(ChatGPTCredential.self, from: $0) }
    }
}

@Observable final class ChatGPTAccount {
    static let shared = ChatGPTAccount()
    static let modelKey = "ai.chatgpt.model"
    static let webSearchKey = "ai.chatgpt.webSearch"
    typealias Browser = @MainActor (URL) async throws -> URL

    private(set) var credential: ChatGPTCredential? = ChatGPTKeychain.credential
    private(set) var models: [ChatGPTModel] = []
    private(set) var busy = false
    var error: String?
    private var refresh: Task<String, Error>?

    private static let issuer = URL(string: "https://auth.openai.com")!
    private static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    private static let resource = "https://api.openai.com/v1"
    private static let unusableRefresh: Set<String> = ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"]

    var ready: Bool { credential?.ready == true }

    /// Signs in through OpenAI's loopback flow. `newAccount` registers a fresh client instead of reusing the saved one.
    func signIn(newAccount: Bool = false, consent: Bool = false, browser: Browser) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let saved = newAccount ? nil : credential
            let server = try await ChatGPTCallbackServer.start()
            defer { server.stop() }
            let attempt = try ChatGPTAuthorization(redirect: server.redirect, hostID: try hostID(), clientID: saved?.clientID,
                                                   idTokenHint: saved?.idToken, loginHint: saved?.email, consent: consent)
            async let callback = server.callback()
            _ = try await browser(attempt.authorizationURL)
            let (code, clientID) = try attempt.callback(try await callback)
            let tokens = try await tokenRequest(["grant_type": "authorization_code", "client_id": clientID, "code": code,
                                                 "code_verifier": attempt.verifier, "redirect_uri": attempt.redirect.absoluteString, "resource": Self.resource])
            guard let idToken = tokens.id_token, let access = tokens.access_token else { throw ChatGPTError.signIn("OpenAI didn't return the expected tokens.") }
            let (keys, _) = try await URLSession.shared.data(from: Self.issuer.appending(path: ".well-known/jwks.json"))
            let identity = try ChatGPTIdentity.verify(idToken, clientID: clientID, nonce: attempt.nonce, keys: keys)
            if let saved, saved.subject != identity.subject { throw ChatGPTError.accountMismatch }
            let scopes = tokens.scope?.split(separator: " ").map(String.init) ?? []
            try store(ChatGPTCredential(email: identity.email, subject: identity.subject, clientID: clientID, idToken: idToken,
                                        accessToken: access, refreshToken: tokens.refresh_token,
                                        expiresAt: Date.now.addingTimeInterval(tokens.expires_in ?? 3600), scopes: scopes, savedAt: .now))
            if credential?.planEnabled == true { await loadModels() }
            else { error = "Signed in, but ChatGPT plan usage wasn't granted. Choose “Enable plan usage” to allow it." }
        } catch let failure as ASWebAuthenticationSessionError where failure.code == .canceledLogin {
        } catch is CancellationError {
        } catch ChatGPTAuthorization.Failure.denied {
            error = "Sign-in was declined."
        } catch let failure as ChatGPTError {
            error = failure.localizedDescription
        } catch is ChatGPTAuthorization.Failure, is ChatGPTIdentity.Failure {
            error = ChatGPTError.signIn("OpenAI's response couldn't be verified. Try again.").localizedDescription
        } catch {
            self.error = ChatGPTError.signIn(error.localizedDescription).localizedDescription
        }
    }

    func signOut() async {
        guard var credential, credential.signedIn else { return }
        busy = true
        defer { busy = false }
        refresh?.cancel()
        var confirmed = false
        if let token = credential.refreshToken, let endpoint = await revocationEndpoint() {
            for attempt in 0..<3 {
                var request = URLRequest(url: endpoint, timeoutInterval: 20)
                request.httpMethod = "POST"
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = Self.form(["token": token, "token_type_hint": "refresh_token", "client_id": credential.clientID])
                let status = ((try? await URLSession.shared.data(for: request))?.1 as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200 { confirmed = true; break }
                if (400..<500).contains(status) { break }
                try? await Task.sleep(for: .seconds(1 << attempt))
            }
        }
        credential.accessToken = nil
        credential.refreshToken = nil
        credential.idToken = nil
        credential.expiresAt = nil
        try? store(credential)
        models = []
        error = confirmed ? nil : "Signed out on this device, but OpenAI didn't confirm the session was revoked. You can disconnect Newswire in ChatGPT settings."
    }

    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let credential, credential.signedIn else { throw ChatGPTError.notSignedIn }
        guard credential.planEnabled else { throw ChatGPTError.planDisabled }
        if !forceRefresh, let token = credential.accessToken, let expiry = credential.expiresAt, expiry.timeIntervalSinceNow > 120 { return token }
        if let refresh { return try await refresh.value }
        let task = Task { try await refreshTokens() }
        refresh = task
        defer { refresh = nil }
        return try await task.value
    }

    func loadModels() async {
        do {
            var request = URLRequest(url: URL(string: "\(Self.resource)/models")!, timeoutInterval: 20)
            request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { throw ChatGPTError.from(status: status, body: data) }
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            models = (root?["models"] as? [[String: Any]] ?? []).compactMap { model in
                guard let slug = model["slug"] as? String, (model["visibility"] as? String ?? "list") == "list" else { return nil }
                return ChatGPTModel(id: slug, name: model["display_name"] as? String ?? slug)
            }
            let selected = UserDefaults.standard.string(forKey: Self.modelKey)
            if let first = models.first, !models.contains(where: { $0.id == selected }) { UserDefaults.standard.set(first.id, forKey: Self.modelKey) }
        } catch {
            self.error = "Couldn't load ChatGPT models: \(error.localizedDescription)"
        }
    }

    func model() async throws -> String {
        if let saved = UserDefaults.standard.string(forKey: Self.modelKey), !saved.isEmpty { return saved }
        await loadModels()
        guard let first = models.first else { throw ChatGPTError.noModel }
        return first.id
    }

    private func refreshTokens() async throws -> String {
        guard var credential, let token = credential.refreshToken else { throw ChatGPTError.sessionExpired }
        let tokens: TokenResponse
        do {
            tokens = try await tokenRequest(["grant_type": "refresh_token", "client_id": credential.clientID, "refresh_token": token, "resource": Self.resource])
        } catch TokenFailure.rejected(let code) where Self.unusableRefresh.contains(code) {
            credential.accessToken = nil
            credential.refreshToken = nil
            credential.expiresAt = nil
            try? store(credential)
            throw ChatGPTError.sessionExpired
        } catch TokenFailure.rejected(let code) {
            throw ChatGPTError.signIn(code)
        }
        guard let access = tokens.access_token else { throw ChatGPTError.sessionExpired }
        credential.accessToken = access
        credential.refreshToken = tokens.refresh_token ?? token
        credential.idToken = tokens.id_token ?? credential.idToken
        credential.expiresAt = Date.now.addingTimeInterval(tokens.expires_in ?? 3600)
        if let scope = tokens.scope { credential.scopes = scope.split(separator: " ").map(String.init) }
        credential.savedAt = .now
        try store(credential)
        return access
    }

    private struct TokenResponse: Decodable {
        let id_token: String?
        let access_token: String?
        let refresh_token: String?
        let expires_in: Double?
        let scope: String?
    }

    private enum TokenFailure: Error { case rejected(String) }

    private func tokenRequest(_ fields: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: Self.tokenURL, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.form(fields)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let code = root?["error"] as? String ?? (root?["error"] as? [String: Any])?["code"] as? String
            if let code { throw TokenFailure.rejected(code) }
            if status >= 500 { throw ChatGPTError.unavailable }
            throw ChatGPTError.signIn("OpenAI returned status \(status).")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func revocationEndpoint() async -> URL? {
        guard let (data, _) = try? await URLSession.shared.data(from: Self.issuer.appending(path: ".well-known/openid-configuration")),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let endpoint = (root["revocation_endpoint"] as? String).flatMap(URL.init(string:)), endpoint.host == "auth.openai.com" else { return nil }
        return endpoint
    }

    private func store(_ credential: ChatGPTCredential) throws {
        try ChatGPTKeychain.save(try JSONEncoder().encode(credential), "credential")
        self.credential = credential
    }

    private func hostID() throws -> String {
        if let data = ChatGPTKeychain.read("host"), let id = String(data: data, encoding: .utf8), id.hasPrefix("urn:uuid:") { return id }
        let id = "urn:uuid:" + UUID().uuidString.lowercased()
        try ChatGPTKeychain.save(Data(id.utf8), "host")
        return id
    }

    nonisolated static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").utf8)
    }
}

/// Receives OpenAI's redirect on 127.0.0.1 and bounces the browser to newswire:// so the in-app web session closes.
nonisolated final class ChatGPTCallbackServer: @unchecked Sendable {
    let redirect: URL
    private let listener: NWListener
    private let urls: AsyncThrowingStream<URL, Error>
    private let continuation: AsyncThrowingStream<URL, Error>.Continuation
    private static let queue = DispatchQueue(label: "com.brycecole.newswire.chatgpt-callback")

    private init(listener: NWListener, port: UInt16, urls: AsyncThrowingStream<URL, Error>, continuation: AsyncThrowingStream<URL, Error>.Continuation) {
        self.listener = listener
        self.redirect = URL(string: "http://127.0.0.1:\(port)/auth/callback")!
        self.urls = urls
        self.continuation = continuation
    }

    static func start() async throws -> ChatGPTCallbackServer {
        do { return try await start(port: 1455) } catch { return try await start(port: 0) }
    }

    private static func start(port: UInt16) async throws -> ChatGPTCallbackServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener = try NWListener(using: parameters)
        let (urls, continuation) = AsyncThrowingStream<URL, Error>.makeStream()
        listener.newConnectionHandler = { [weak listener] connection in
            serve(connection, port: listener?.port?.rawValue, continuation: continuation)
        }
        let resumed = OSAllocatedUnfairLock(initialState: false)
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                let result: Result<Void, Error>? = switch state {
                case .ready: .success(())
                case .failed(let error): .failure(error)
                case .cancelled: .failure(CancellationError())
                default: nil
                }
                guard let result, resumed.withLock({ done in defer { done = true }; return !done }) else { return }
                if case .failure = result { listener.cancel() }
                ready.resume(with: result)
            }
            listener.start(queue: queue)
        }
        guard let bound = listener.port?.rawValue else { listener.cancel(); throw CancellationError() }
        return ChatGPTCallbackServer(listener: listener, port: bound, urls: urls, continuation: continuation)
    }

    func callback() async throws -> URL {
        for try await url in urls { return url }
        throw CancellationError()
    }

    func stop() {
        listener.cancel()
        continuation.finish()
    }

    private static func serve(_ connection: NWConnection, port: UInt16?, continuation: AsyncThrowingStream<URL, Error>.Continuation) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
            let line = data.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\r\n").first ?? ""
            let parts = line.split(separator: " ")
            var status = "404 Not Found"
            var location = ""
            if parts.count == 3, parts[0] == "GET", parts[1] == "/auth/callback" || parts[1].hasPrefix("/auth/callback?"),
               let port, let url = URL(string: "http://127.0.0.1:\(port)\(parts[1])") {
                continuation.yield(url)
                status = "302 Found"
                location = "Location: newswire://chatgpt-signed-in\r\n"
            }
            let body = "You can return to Newswire."
            let response = "HTTP/1.1 \(status)\r\n\(location)Content-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
