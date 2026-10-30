import Foundation
import Security

struct ChatGPTIdentity {
    let subject: String
    let email: String?

    enum Failure: Error { case invalidToken, invalidKey, invalidSignature, invalidClaims }

    static func verify(_ token: String, clientID: String, nonce: String, keys: Data, now: Date = .now) throws -> Self {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let headerData = decode(String(parts[0])),
              let claimsData = decode(String(parts[1])),
              let signature = decode(String(parts[2])),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "RS256", let kid = header["kid"] as? String,
              let claims = try JSONSerialization.jsonObject(with: claimsData) as? [String: Any],
              let jwks = try JSONSerialization.jsonObject(with: keys) as? [String: Any],
              let candidates = jwks["keys"] as? [[String: Any]] else { throw Failure.invalidToken }
        let matches = candidates.filter { ($0["kid"] as? String) == kid && ($0["kty"] as? String) == "RSA" && ($0["alg"] as? String) == "RS256" }
        guard matches.count == 1, let n = matches[0]["n"] as? String, let e = matches[0]["e"] as? String,
              let modulus = decode(n), let exponent = decode(e), !modulus.isEmpty, !exponent.isEmpty else { throw Failure.invalidKey }
        let rsa = sequence(integer(modulus) + integer(exponent))
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                         kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        guard let key = SecKeyCreateWithData(rsa as CFData, attributes as CFDictionary, nil) else { throw Failure.invalidKey }
        let signed = Data("\(parts[0]).\(parts[1])".utf8)
        guard SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, signed as CFData, signature as CFData, nil) else { throw Failure.invalidSignature }
        let audience = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard claims["iss"] as? String == "https://auth.openai.com", audience.contains(clientID),
              claims["nonce"] as? String == nonce,
              let subject = claims["sub"] as? String, !subject.isEmpty,
              let expiry = claims["exp"] as? Double, expiry > now.timeIntervalSince1970,
              let issued = claims["iat"] as? Double, issued <= now.timeIntervalSince1970 + 5 else { throw Failure.invalidClaims }
        if audience.count > 1 && claims["azp"] as? String != clientID { throw Failure.invalidClaims }
        return Self(subject: subject, email: claims["email"] as? String)
    }

    private static func decode(_ input: String) -> Data? {
        guard input.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        var text = input.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        return Data(base64Encoded: text)
    }

    private static func length(_ count: Int) -> Data {
        if count < 128 { return Data([UInt8(count)]) }
        var value = count
        var bytes: [UInt8] = []
        while value > 0 { bytes.insert(UInt8(value & 255), at: 0); value >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    private static func integer(_ value: Data) -> Data {
        var value = value
        while value.count > 1 && value.first == 0 { value.removeFirst() }
        if value.first.map({ $0 & 0x80 != 0 }) == true { value.insert(0, at: 0) }
        return Data([0x02]) + length(value.count) + value
    }

    private static func sequence(_ value: Data) -> Data { Data([0x30]) + length(value.count) + value }
}
