import Foundation

nonisolated enum ChatGPTEvent: Sendable {
    /// Text of the current response so far.
    case text(String)
    case searching
}

enum ChatGPTResponses {
    nonisolated private static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    /// Sends one Responses request on the signed-in ChatGPT plan and returns the completed response's output items.
    static func respond(_ body: [String: Any], onEvent: @escaping @MainActor @Sendable (ChatGPTEvent) -> Void = { _ in }) async throws -> [[String: Any]] {
        var body = body
        body["store"] = false
        body["stream"] = true
        let data = try JSONSerialization.data(withJSONObject: body)
        let response: Data
        do {
            response = try await stream(data, token: try await ChatGPTAccount.shared.accessToken(), onEvent: onEvent)
        } catch ChatGPTError.sessionExpired {
            response = try await stream(data, token: try await ChatGPTAccount.shared.accessToken(forceRefresh: true), onEvent: onEvent)
        }
        guard let root = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              let output = root["output"] as? [[String: Any]] else { throw ChatGPTError.incomplete }
        return output
    }

    static func text(instructions: String, prompt: String) async throws -> String {
        let model = try await ChatGPTAccount.shared.model()
        let output = try await respond(["model": model, "instructions": instructions, "input": [["role": "user", "content": prompt]]])
        let text = message(output).text
        guard !text.isEmpty else { throw ChatGPTError.incomplete }
        return text
    }

    static func message(_ output: [[String: Any]]) -> (text: String, titles: [String: String]) {
        var text = ""
        var titles: [String: String] = [:]
        for item in output where item["type"] as? String == "message" {
            for part in item["content"] as? [[String: Any]] ?? [] where part["type"] as? String == "output_text" {
                text += part["text"] as? String ?? ""
                for annotation in part["annotations"] as? [[String: Any]] ?? [] where annotation["type"] as? String == "url_citation" {
                    if let url = annotation["url"] as? String, let title = annotation["title"] as? String, !title.isEmpty { titles[url] = title }
                }
            }
        }
        return (text, titles)
    }

    /// Replaces Markdown links to web pages with numbered citations the chat renders as source chips.
    static func cite(_ text: String, titles: [String: String], research: StockResearchTools) async -> String {
        var result = ""
        var cursor = text.startIndex
        var numbers: [URL: Int] = [:]
        for match in text.matches(of: /\(?\[([^\]\n]{1,300})\]\((https?:\/\/[^\s()]+)\)\)?/) {
            result += text[cursor..<match.range.lowerBound]
            cursor = match.range.upperBound
            let full = text[match.range]
            let link = String(match.output.2)
            guard var components = URLComponents(string: link) else { result += full; continue }
            components.queryItems = components.queryItems?.filter { $0.name != "utm_source" }
            if components.queryItems?.isEmpty == true { components.queryItems = nil }
            guard let url = components.url else { result += full; continue }
            let label = String(match.output.1)
            let number: Int
            if let existing = numbers[url] { number = existing } else {
                number = await research.cite(StockSource(title: titles[link] ?? label, url: url))
                numbers[url] = number
            }
            let opened = full.hasPrefix("("), closed = full.hasSuffix("))")
            if opened && closed {
                if let last = result.last, !last.isWhitespace { result += " " }
                result += "[\(number)]"
            } else {
                result += (opened ? "(" : "") + "\(label) [\(number)]" + (closed ? ")" : "")
            }
        }
        return result + text[cursor...]
    }

    @concurrent nonisolated private static func stream(_ body: Data, token: String, onEvent: @escaping @MainActor @Sendable (ChatGPTEvent) -> Void) async throws -> Data {
        var request = URLRequest(url: endpoint, timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = body
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatGPTError.interrupted }
        let requestID = http.value(forHTTPHeaderField: "x-request-id")
        guard (200..<300).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 65536 { break }
            }
            throw ChatGPTError.from(status: http.statusCode, body: data, requestID: requestID)
        }
        var text = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let type = event["type"] as? String else { continue }
            switch type {
            case "response.output_text.delta":
                text += event["delta"] as? String ?? ""
                let snapshot = text
                await onEvent(.text(snapshot))
            case "response.output_item.added":
                if (event["item"] as? [String: Any])?["type"] as? String == "web_search_call" { await onEvent(.searching) }
            case "response.completed":
                guard let completed = event["response"] else { throw ChatGPTError.incomplete }
                return try JSONSerialization.data(withJSONObject: completed)
            case "response.incomplete":
                throw ChatGPTError.incomplete
            case "response.failed", "error":
                let error = (event["response"] as? [String: Any])?["error"] ?? event["error"] ?? event
                throw ChatGPTError.from(status: http.statusCode == 200 ? 400 : http.statusCode,
                                        body: (try? JSONSerialization.data(withJSONObject: ["error": error])) ?? Data(), requestID: requestID)
            default:
                break
            }
        }
        throw ChatGPTError.interrupted
    }
}

extension StockChat {
    func chatGPT(instructions: String, history: String, question: String, research: StockResearchTools, data: [[String: Any]]) async throws -> String {
        let model = try await ChatGPTAccount.shared.model()
        var webSearch = UserDefaults.standard.object(forKey: ChatGPTAccount.webSearchKey) as? Bool ?? true
        let definitions: [[String: Any]] = functions(research: research, data: data).compactMap { tool in
            guard let function = tool["function"] as? [String: Any], let name = function["name"] as? String else { return nil }
            return ["type": "function", "name": name, "description": function["description"] ?? "", "parameters": function["parameters"] ?? [:]]
        }
        let isData: ([String: Any]) -> Bool = { ($0["name"] as? String ?? "").hasPrefix("data_") }
        var namespaces: [[String: Any]] = [["type": "namespace", "name": "newswire",
            "description": "The selected stock's quotes, company details, headlines and options; and the story on screen.",
            "tools": definitions.filter { !isData($0) }]]
        let market = definitions.filter(isData)
        if !market.isEmpty {
            namespaces.append(["type": "namespace", "name": "newswire_data",
                "description": "Newswire market and economic data: quotes, history, fundamentals, SEC filings, releases, rates, screeners and Newswire stories.",
                "tools": market])
        }
        var input: [[String: Any]] = [["role": "user", "content": "\(history)\n\(question)"]]
        let progress = research.progress
        for _ in 0..<16 {
            try Task.checkCancellation()
            let guidance = webSearch ? "\n\nWeb search: prefer Newswire tools for prices, filings and economic data. Use web_search for recent news, events or facts Newswire tools don't cover. Cite each web page as an inline Markdown link [publisher](url) right after the claim it supports; the app turns these links into numbered citations, so this is the one exception to the rule against writing URLs." : ""
            let output: [[String: Any]]
            do {
                output = try await ChatGPTResponses.respond(["model": model, "instructions": instructions + guidance, "input": input,
                    "tools": namespaces + (webSearch ? [["type": "web_search"]] : []), "tool_choice": "auto", "parallel_tool_calls": true]) { event in
                    if case .searching = event { progress("Searching the web…") }
                }
            } catch ChatGPTError.unsupported(let param) where webSearch && (param.isEmpty || param.contains("tools")) {
                webSearch = false
                continue
            }
            let calls = output.filter { $0["type"] as? String == "function_call" }
            if calls.isEmpty {
                let (text, titles) = ChatGPTResponses.message(output)
                guard !text.isEmpty else { throw ChatGPTError.incomplete }
                return await ChatGPTResponses.cite(text, titles: titles, research: research)
            }
            let preamble = ChatGPTResponses.message(output).text
            if !preamble.isEmpty { input.append(["role": "assistant", "content": preamble]) }
            for call in calls {
                guard let id = call["call_id"] as? String, let name = call["name"] as? String else { throw ChatGPTError.incomplete }
                var item = call
                item["id"] = nil
                input.append(item)
                let tool = name.split(separator: ".").last.map(String.init) ?? name
                let result = try await runTool(tool, arguments: call["arguments"] as? String, research: research)
                input.append(["type": "function_call_output", "call_id": id, "output": result])
            }
        }
        throw ChatGPTError.incomplete
    }
}
