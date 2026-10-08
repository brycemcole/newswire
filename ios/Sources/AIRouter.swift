import Foundation
import FoundationModels

enum AIFeature: String, CaseIterable, Identifiable {
    case stockChat, articleSummaries, moveExplanations
    var id: String { rawValue }
    var title: String {
        switch self {
        case .stockChat: "Ask"
        case .articleSummaries: "Article summaries"
        case .moveExplanations: "Why it moved"
        }
    }
    var defaultsKey: String { "ai.deepseek." + rawValue }
}

enum AIBackend: Equatable {
    case deepSeek, privateCloud, onDevice
    var label: String {
        switch self {
        case .deepSeek: "DeepSeek"
        case .privateCloud: "Private Cloud Compute"
        case .onDevice: "Apple Intelligence"
        }
    }
}

enum AIRouter {
    static let appleKey = "ai.appleBackend"
    static let providerKey = "ai.provider"

    /// The provider picked in settings: "deepSeek", "privateCloud" or "onDevice". Before the picker existed a saved key meant DeepSeek.
    static var provider: String {
        UserDefaults.standard.string(forKey: providerKey) ?? (hasDeepSeekKey ? "deepSeek" : UserDefaults.standard.string(forKey: appleKey) ?? "onDevice")
    }

    static var hasDeepSeekKey: Bool { !StockAIKeychain.read().isEmpty }

    static func deepSeekEnabled(_ feature: AIFeature) -> Bool {
        UserDefaults.standard.object(forKey: feature.defaultsKey) as? Bool ?? true
    }

    static var prefersPrivateCloud: Bool { UserDefaults.standard.string(forKey: appleKey) == "privateCloud" }

    static var privateCloudAvailable: Bool {
        if #available(iOS 27.0, *) { return PrivateCloudComputeLanguageModel().isAvailable }
        return false
    }

    static var onDeviceAvailable: Bool { SystemLanguageModel.default.availability == .available }

    static func backend(for feature: AIFeature) -> AIBackend? {
        if provider == "deepSeek", hasDeepSeekKey, deepSeekEnabled(feature) { return .deepSeek }
        if prefersPrivateCloud, privateCloudAvailable { return .privateCloud }
        return onDeviceAvailable ? .onDevice : nil
    }

    static func isAvailable(_ feature: AIFeature) -> Bool { backend(for: feature) != nil }

    static func session(_ backend: AIBackend, instructions: String, tools: [any Tool] = [], permissive: Bool = false) -> LanguageModelSession {
        if backend == .privateCloud, #available(iOS 27.0, *) {
            return LanguageModelSession(model: PrivateCloudComputeLanguageModel(), tools: tools, instructions: instructions)
        }
        let model = permissive ? SystemLanguageModel(guardrails: .permissiveContentTransformations) : SystemLanguageModel.default
        return LanguageModelSession(model: model, tools: tools, instructions: instructions)
    }

    /// Runs one prompt on whichever backend the feature's settings select. `onPartial` receives growing text when the backend streams.
    static func generate(_ feature: AIFeature, instructions: String, prompt: String, temperature: Double, maxTokens: Int,
                         onPartial: ((String) -> Void)? = nil) async throws -> String {
        guard let backend = backend(for: feature) else { throw StockAIError.unavailable }
        if backend == .deepSeek {
            let text = try await deepSeek(key: StockAIKeychain.read(), instructions: instructions, prompt: prompt, temperature: temperature, maxTokens: maxTokens)
            onPartial?(text)
            return text
        }
        let session = session(backend, instructions: instructions, permissive: true)
        let options = GenerationOptions(temperature: temperature, maximumResponseTokens: maxTokens)
        if let onPartial {
            var text = ""
            for try await snapshot in session.streamResponse(to: prompt, options: options) {
                try Task.checkCancellation()
                text = snapshot.content
                onPartial(text)
            }
            return text
        }
        return try await session.respond(to: prompt, options: options).content
    }

    static func deepSeek(key: String, instructions: String, prompt: String, temperature: Double, maxTokens: Int) async throws -> String {
        guard !key.isEmpty else { throw StockAIError.missingKey }
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/chat/completions")!, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": "deepseek-flash", "temperature": temperature, "max_tokens": maxTokens,
            "messages": [["role": "system", "content": instructions], ["role": "user", "content": prompt]], "thinking": ["type": "disabled"]] as [String: Any])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw StockAIError.status((response as? HTTPURLResponse)?.statusCode ?? 0) }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let choice = (root["choices"] as? [[String: Any]])?.first,
              let text = (choice["message"] as? [String: Any])?["content"] as? String, !text.isEmpty else { throw StockAIError.incomplete }
        return text
    }
}
