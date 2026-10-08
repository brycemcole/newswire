import CryptoKit
import DeviceCheck
import Foundation
import Security

nonisolated enum AttestKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.brycecole.newswire",
         kSecAttrAccount as String: "attest"]
    }

    static func read() -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess ? result as? Data : nil
    }

    static func save(_ data: Data?) {
        guard let data else {
            SecItemDelete(query as CFDictionary)
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
    }

    static func removeLegacyReaderToken() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: "com.brycecole.newswire",
                       kSecAttrAccount as String: "reader"] as CFDictionary)
    }
}

nonisolated enum AttestError: LocalizedError {
    case unsupported, rejected(String), network
    var errorDescription: String? {
        switch self {
        case .unsupported: "This device can't prove it's running Newswire (App Attest is unavailable)."
        case .rejected(let reason): "The server rejected this device (\(reason))."
        case .network: "Could not reach the server to verify this device."
        }
    }
}

/// Holds a Secure Enclave key (via App Attest) and exchanges proof of it for a short-lived session token.
actor Attestation {
    static let shared = Attestation()

    private struct State: Codable {
        var origin: String
        var keyID: String?
        var token: String?
        var expires: Date?
    }

    private struct Session: Decodable { let token: String; let expiresAt: String }
    private struct Challenge: Decodable { let challenge: String }

    private var inflight: Task<String, Error>?

    func token(for baseURL: URL, refresh: Bool = false) async throws -> String {
        #if DEBUG && targetEnvironment(simulator)
        if let override = ProcessInfo.processInfo.environment["NEWSWIRE_TEST_TOKEN"], !override.isEmpty { return override }
        #endif
        let origin = baseURL.absoluteString
        if !refresh, let state = load(origin), let token = state.token, let expires = state.expires, expires.timeIntervalSinceNow > 3600 { return token }
        if let inflight { return try await inflight.value }
        let task = Task { try await mint(baseURL) }
        inflight = task
        defer { inflight = nil }
        return try await task.value
    }

    private func load(_ origin: String) -> State? {
        guard let data = AttestKeychain.read(), let state = try? JSONDecoder().decode(State.self, from: data), state.origin == origin else { return nil }
        return state
    }

    private func store(_ state: State) {
        AttestKeychain.save(try? JSONEncoder().encode(state))
    }

    private func mint(_ baseURL: URL) async throws -> String {
        let service = DCAppAttestService.shared
        guard service.isSupported else { throw AttestError.unsupported }
        let origin = baseURL.absoluteString
        if let state = load(origin), let keyID = state.keyID {
            do {
                return try await renew(baseURL, keyID: keyID, state: state)
            } catch AttestError.rejected(let reason) where reason == "unknown_key" || reason == "attestation_failed" {
            } catch let error as DCError where error.code == .invalidKey || error.code == .invalidInput {
                AttestKeychain.save(nil)
            }
        }
        do {
            return try await enroll(baseURL)
        } catch let error as DCError where error.code == .invalidKey {
            return try await enroll(baseURL)
        }
    }

    private func enroll(_ baseURL: URL) async throws -> String {
        let service = DCAppAttestService.shared
        let keyID = try await service.generateKey()
        let challenge = try await challenge(baseURL)
        let attestation = try await service.attestKey(keyID, clientDataHash: Data(SHA256.hash(data: Data(challenge.utf8))))
        let session = try await post(baseURL, "v1/attest", ["key_id": keyID, "challenge": challenge, "attestation": attestation.base64EncodedString()])
        return save(session, baseURL: baseURL, keyID: keyID)
    }

    private func renew(_ baseURL: URL, keyID: String, state: State) async throws -> String {
        let challenge = try await challenge(baseURL)
        let assertion = try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: Data(SHA256.hash(data: Data(challenge.utf8))))
        let session = try await post(baseURL, "v1/attest/session", ["key_id": keyID, "challenge": challenge, "assertion": assertion.base64EncodedString()])
        return save(session, baseURL: baseURL, keyID: keyID)
    }

    private func save(_ session: Session, baseURL: URL, keyID: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        store(State(origin: baseURL.absoluteString, keyID: keyID, token: session.token, expires: formatter.date(from: session.expiresAt) ?? .now.addingTimeInterval(86400)))
        return session.token
    }

    private func challenge(_ baseURL: URL) async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "v1/attest/challenge"), timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await send(request, as: Challenge.self).challenge
    }

    private func post(_ baseURL: URL, _ path: String, _ body: [String: String]) async throws -> Session {
        var request = URLRequest(url: baseURL.appending(path: path), timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request, as: Session.self)
    }

    private func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let data: Data
        let response: URLResponse
        do { (data, response) = try await NewswireAPI.session.data(for: request) } catch { throw AttestError.network }
        guard let http = response as? HTTPURLResponse else { throw AttestError.network }
        guard (200..<300).contains(http.statusCode) else {
            let code = (try? JSONDecoder().decode(APIError.self, from: data))?.error.code ?? "http_\(http.statusCode)"
            throw AttestError.rejected(code)
        }
        do { return try JSONDecoder.snakeCase.decode(T.self, from: data) } catch { throw AttestError.network }
    }
}

extension JSONDecoder {
    nonisolated static var snakeCase: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
