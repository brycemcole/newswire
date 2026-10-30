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
    case newswire, deepSeek, chatGPT, onDevice
    var label: String {
        switch self {
        case .newswire: "DeepSeek Free"
        case .deepSeek: "DeepSeek"
        case .chatGPT: "ChatGPT"
        case .onDevice: "Apple Intelligence"
        }
    }
}

enum AIRouter {
    static let providerKey = "ai.provider"

    static var provider: String {
        if !UserDefaults.standard.bool(forKey: "ai.freeDeepSeek.v1") {
            UserDefaults.standard.set("newswire", forKey: providerKey)
            UserDefaults.standard.set(true, forKey: "ai.freeDeepSeek.v1")
        }
        return UserDefaults.standard.string(forKey: providerKey) ?? "newswire"
    }

    static var hasDeepSeekKey: Bool { !StockAIKeychain.read().isEmpty }

    static func deepSeekEnabled(_ feature: AIFeature) -> Bool {
        UserDefaults.standard.object(forKey: feature.defaultsKey) as? Bool ?? true
    }

    static var onDeviceAvailable: Bool { SystemLanguageModel.default.availability == .available }

    static func backend(for feature: AIFeature) -> AIBackend? {
        if provider == "newswire", deepSeekEnabled(feature) { return .newswire }
        if provider == "deepSeek", hasDeepSeekKey, deepSeekEnabled(feature) { return .deepSeek }
        if provider == "chatGPT", ChatGPTAccount.shared.ready, deepSeekEnabled(feature) { return .chatGPT }
        return onDeviceAvailable ? .onDevice : nil
    }

    static func isAvailable(_ feature: AIFeature) -> Bool { backend(for: feature) != nil }

    static func inputLimit(for feature: AIFeature) -> Int { backend(for: feature) == .onDevice ? 6000 : 120000 }

    static func session(_ backend: AIBackend, instructions: String, tools: [any Tool] = [], permissive: Bool = false) -> LanguageModelSession {
        let model = permissive ? SystemLanguageModel(guardrails: .permissiveContentTransformations) : SystemLanguageModel.default
        return LanguageModelSession(model: model, tools: tools, instructions: instructions)
    }

    /// Runs one prompt on whichever backend the feature's settings select. `onPartial` receives growing text when the backend streams.
    static func generate(_ feature: AIFeature, instructions: String, prompt: String, temperature: Double, maxTokens: Int,
                         onPartial: ((String) -> Void)? = nil) async throws -> String {
        guard let backend = backend(for: feature) else { throw StockAIError.unavailable }
        if backend == .newswire {
            let data = try await freeCompletion(["messages": [["role": "system", "content": instructions], ["role": "user", "content": prompt]], "max_tokens": maxTokens])
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choice = (root["choices"] as? [[String: Any]])?.first,
                  let text = (choice["message"] as? [String: Any])?["content"] as? String, !text.isEmpty else { throw StockAIError.incomplete }
            onPartial?(text)
            return text
        }
        if backend == .chatGPT {
            let text = try await ChatGPTResponses.text(instructions: instructions, prompt: prompt)
            onPartial?(text)
            return text
        }
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

    static func freeCompletion(_ body: [String: Any], api: NewswireAPI? = nil) async throws -> Data {
        guard let api = api ?? NewswireAPI.validatedURL(FeedStore.shared.serverURL).map({ NewswireAPI(baseURL: $0) }) else { throw WireError.configuration }
        var request = URLRequest(url: api.baseURL.appending(path: "v1/ai/chat/completions"), timeoutInterval: 95)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await api.send(request)
        guard (200..<300).contains(response.statusCode) else {
            if let error = try? JSONDecoder().decode(APIError.self, from: data) { throw error }
            throw WireError.status(response.statusCode)
        }
        return data
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
