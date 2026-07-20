import Foundation

enum LLMClientError: LocalizedError {
    case missingAPIKey
    case missingModel
    case invalidURL(String)
    case invalidResponse
    case requestFailed(Int, String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "请先填写 API key"
        case .missingModel:
            return "请先选择模型"
        case .invalidURL(let value):
            return "模型接口地址无效：\(value)"
        case .invalidResponse:
            return "模型接口返回格式不正确"
        case .requestFailed(let code, let message):
            return "请求失败（\(code)）：\(message)"
        case .emptyResponse:
            return "模型返回了空内容（HTTP 200，但没有可展示文本或工具调用）"
        }
    }
}

struct LLMToolUse: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var input: String
    var source: String
}

struct LLMResponse: Codable, Equatable {
    var text: String
    var toolUses: [LLMToolUse]
    var usage: LLMTokenUsage?
    var rawSSE: String

    var displayText: String {
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }

        if toolUses.isEmpty {
            return ""
        }

        return "Requested \(toolUses.count) tool call\(toolUses.count == 1 ? "" : "s")."
    }
}

struct LLMClient {
    private static let session = URLSession(configuration: .default)

    static func fetchModels(baseURL: String, apiKey: String) async throws -> [String] {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedKey.isEmpty {
            throw LLMClientError.missingAPIKey
        }

        let normalizedBaseURL = normalizeBaseURL(baseURL)
        guard !normalizedBaseURL.isEmpty,
              let url = URL(string: "\(normalizedBaseURL)/models") else {
            throw LLMClientError.invalidURL(baseURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        traceLog("http.models.start", "GET \(url.absoluteString)", rawHTTP: rawRequest(method: "GET", url: url, headers: authorizationHeaders(redacted: true), body: nil))

        let json = try await performJSON(request)
        if let data = json["data"] as? [[String: Any]] {
            let models = data.compactMap { $0["id"] as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return Array(Set(models)).sorted()
        }

        throw LLMClientError.invalidResponse
    }

    static func send(
        transcript: [AgentMessage],
        settings: LLMSettings,
        apiKey: String
    ) async throws -> LLMResponse {
        try await send(
            messages: messages(from: transcript, toolConfiguration: AgentToolConfiguration.defaultConfiguration),
            settings: settings,
            apiKey: apiKey,
            toolConfiguration: AgentToolConfiguration.defaultConfiguration
        )
    }

    static func send(
        messages: [[String: Any]],
        settings: LLMSettings,
        apiKey: String,
        toolConfiguration: AgentToolConfiguration
    ) async throws -> LLMResponse {
        try await send(
            messages: messages,
            settings: settings,
            apiKey: apiKey,
            toolConfiguration: toolConfiguration,
            allowEmptyRetry: true
        )
    }

    private static func send(
        messages: [[String: Any]],
        settings: LLMSettings,
        apiKey: String,
        toolConfiguration: AgentToolConfiguration,
        allowEmptyRetry: Bool
    ) async throws -> LLMResponse {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedKey.isEmpty {
            throw LLMClientError.missingAPIKey
        }

        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.isEmpty {
            throw LLMClientError.missingModel
        }

        let normalizedBaseURL = settings.normalizedBaseURL
        guard !normalizedBaseURL.isEmpty,
              let url = URL(string: "\(normalizedBaseURL)/chat/completions") else {
            throw LLMClientError.invalidURL(settings.baseURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": true
        ]
        let tools = toolDefinitions(for: toolConfiguration, model: model)
        if !tools.isEmpty {
            body["tools"] = tools
            body["tool_choice"] = usesAnthropicToolShape(model: model) ? ["type": "auto"] : "auto"
        }
        if usesAnthropicToolShape(model: model) {
            body["max_tokens"] = 1024
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let rawBody = prettyJSONString(from: redactedForTrace(body)) ?? String(data: request.httpBody ?? Data(), encoding: .utf8)
        let requestWordCount = wordCount(in: requestText(from: messages))
        traceLog(
            "http.chat.start",
            "POST \(url.absoluteString)\nmodel=\(model)\nmessages=\(messages.count)\ntools=\(tools.count)\nrequest_words=\(requestWordCount)",
            rawHTTP: rawRequest(method: "POST", url: url, headers: authorizationHeaders(redacted: true), body: rawBody)
        )

        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = try await collectErrorMessage(from: bytes)
            traceLog("http.chat.status", "status=\(httpResponse.statusCode)\nmessage=\(message)")
            throw LLMClientError.requestFailed(httpResponse.statusCode, message)
        }
        traceLog("http.chat.status", "status=\(httpResponse.statusCode)")

        var accumulator = StreamAccumulator(requestWordCount: requestWordCount)
        var rawSSE = ""
        for try await line in bytes.lines {
            rawSSE += line + "\n"
            try accumulator.consume(line)
        }

        let trimmedResult = accumulator.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let trimmedReasoning = accumulator.reasoningText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if trimmedResult.isEmpty && accumulator.toolUses.isEmpty {
            let usage = accumulator.finalUsage(responseWordCount: 0)
            traceLog(
                "http.chat.empty",
                """
                data_events=\(accumulator.dataEventCount)
                raw_sse_chars=\(rawSSE.count)
                reasoning_chars=\(trimmedReasoning.count)
                retry=\(allowEmptyRetry)
                """,
                rawHTTP: rawSSE.isEmpty ? nil : rawSSE,
                tokenUsage: usage
            )

            if allowEmptyRetry {
                traceLog("http.chat.retry", "reason=empty_model_response")
                return try await send(
                    messages: emptyResponseRetryMessages(from: messages),
                    settings: settings,
                    apiKey: apiKey,
                    toolConfiguration: toolConfiguration,
                    allowEmptyRetry: false
                )
            }

            if !trimmedReasoning.isEmpty {
                let fallback = "模型这次只返回了推理内容，没有返回最终答案。TICK 已把原始响应写入 Trace Log；建议重试一次，或切换到会稳定返回 content 的模型。"
                let responseWordCount = wordCount(in: fallback)
                let usage = accumulator.finalUsage(responseWordCount: responseWordCount)
                traceLog(
                    "http.chat.done",
                    """
                    characters=\(fallback.count)
                    reasoning_characters=\(trimmedReasoning.count)
                    reasoning_only_fallback=true
                    \(tokenUsageDetail(usage))
                    """,
                    rawHTTP: rawSSE,
                    tokenUsage: usage
                )
                return LLMResponse(text: fallback, toolUses: [], usage: usage, rawSSE: rawSSE)
            }

            throw LLMClientError.emptyResponse
        }

        let responseWordCount = wordCount(in: trimmedResult)
        let usage = accumulator.finalUsage(responseWordCount: responseWordCount)
        let tokenDetail = tokenUsageDetail(usage)
        let toolDetail = accumulator.toolUses.map { "\($0.name): \($0.input)" }.joined(separator: "\n")
        traceLog(
            "http.chat.done",
            """
            characters=\(trimmedResult.count)
            reasoning_characters=\(trimmedReasoning.count)
            tools=\(accumulator.toolUses.count)
            \(tokenDetail)
            \(toolDetail)
            """,
            rawHTTP: rawSSE,
            tokenUsage: usage
        )
        return LLMResponse(text: trimmedResult, toolUses: accumulator.toolUses, usage: usage, rawSSE: rawSSE)
    }

    private static func performJSON(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMClientError.invalidResponse
        }

        let jsonObject = try? JSONSerialization.jsonObject(with: data)
        let json = jsonObject as? [String: Any] ?? [:]

        guard (200..<300).contains(httpResponse.statusCode) else {
            traceLog("http.json.status", "status=\(httpResponse.statusCode)")
            throw LLMClientError.requestFailed(httpResponse.statusCode, errorMessage(from: json, data: data))
        }
        traceLog("http.json.status", "status=\(httpResponse.statusCode)")

        guard !json.isEmpty else {
            throw LLMClientError.invalidResponse
        }

        return json
    }

    static func messages(from transcript: [AgentMessage], toolConfiguration: AgentToolConfiguration) -> [[String: Any]] {
        let memoryContext = MemoryStore.shared.promptContext(about: transcript)
        let systemContent = [
            LLMProviderConfig.systemPrompt,
            toolConfiguration.systemPromptContext,
            memoryContext
        ]
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .joined(separator: "\n\n")

        var messages: [[String: Any]] = [
            [
                "role": "system",
                "content": systemContent
            ]
        ]

        messages += transcript.suffix(8).filter { !isTransientLocalError($0) }.suffix(6).map { message in
            if message.role == .user && !message.attachments.isEmpty {
                var content: [[String: Any]] = message.attachments.map { attachment in
                    [
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": attachment.mediaType,
                            "data": attachment.base64Data
                        ]
                    ]
                }
                content.append([
                    "type": "text",
                    "text": message.text.isEmpty ? "解释这张图" : message.text
                ])
                return [
                    "role": "user",
                    "content": content
                ]
            }

            return [
                "role": message.role == .user ? "user" : "assistant",
                "content": message.text
            ]
        }

        return messages
    }

    private static func emptyResponseRetryMessages(from messages: [[String: Any]]) -> [[String: Any]] {
        messages + [
            [
                "role": "user",
                "content": "上一轮模型没有返回可展示内容。请直接输出最终中文回答，不要只返回 reasoning_content 或空内容；如果没有足够信息，请输出 TICK_SILENT。"
            ]
        ]
    }

    private static func isTransientLocalError(_ message: AgentMessage) -> Bool {
        guard message.role == .agent else {
            return false
        }

        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text == "Empty model response" ||
            text.hasPrefix("模型返回了空内容") ||
            text.hasPrefix("模型这次只返回了推理内容")
    }

    private static func textContent(from value: Any?) -> String? {
        if let text = value as? String {
            return text
        }

        if let parts = value as? [[String: Any]] {
            return parts.compactMap { part -> String? in
                if let text = part["text"] as? String {
                    return text
                }
                if let text = part["content"] as? String {
                    return text
                }
                return nil
            }
            .joined()
        }

        return nil
    }

    private static func toolDefinitions(for configuration: AgentToolConfiguration, model: String) -> [[String: Any]] {
        let definitions = configuration.definitions
        guard !definitions.isEmpty else {
            return []
        }

        if usesAnthropicToolShape(model: model) {
            return definitions
        }

        return definitions.map { definition in
            [
                "type": "function",
                "function": [
                    "name": definition["name"] ?? "",
                    "description": definition["description"] ?? "",
                    "parameters": definition["input_schema"] ?? ["type": "object"]
                ]
            ]
        }
    }

    static func usesAnthropicToolShape(model: String) -> Bool {
        let lowercasedModel = model.lowercased()
        return lowercasedModel.contains("claude") || lowercasedModel.contains("sonnet") || lowercasedModel.contains("opus") || lowercasedModel.contains("haiku")
    }

    private static func requestText(from value: Any) -> String {
        if let text = value as? String {
            return text
        }

        if let dictionary = value as? [String: Any] {
            return dictionary.compactMap { key, nestedValue -> String? in
                if key == "data" {
                    return nil
                }
                return requestText(from: nestedValue)
            }
            .joined(separator: " ")
        }

        if let array = value as? [Any] {
            return array.map { requestText(from: $0) }.joined(separator: " ")
        }

        return ""
    }

    static func wordCount(in text: String) -> Int {
        var count = 0
        var isInsideAlphanumericWord = false

        for scalar in text.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if !isInsideAlphanumericWord {
                    count += 1
                    isInsideAlphanumericWord = true
                }
            } else {
                isInsideAlphanumericWord = false
                if isCJKScalar(scalar) {
                    count += 1
                }
            }
        }

        return count
    }

    private static func isCJKScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF,
             0x3400...0x4DBF,
             0x3040...0x30FF,
             0xAC00...0xD7AF:
            return true
        default:
            return false
        }
    }

    private static func tokenUsageDetail(_ usage: LLMTokenUsage?) -> String {
        guard let usage else {
            return "prompt_tokens=n/a\ncompletion_tokens=n/a\ntotal_tokens=n/a\nrequest_words=n/a\nresponse_words=n/a"
        }

        return """
        prompt_tokens=\(usage.promptTokens.map(String.init) ?? "n/a")
        completion_tokens=\(usage.completionTokens.map(String.init) ?? "n/a")
        total_tokens=\(usage.computedTotalTokens.map(String.init) ?? "n/a")
        request_words=\(usage.requestWordCount)
        response_words=\(usage.responseWordCount)
        total_words=\(usage.totalWordCount)
        """
    }

    private static func collectErrorMessage(from bytes: URLSession.AsyncBytes) async throws -> String {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }

        if let jsonObject = try? JSONSerialization.jsonObject(with: data),
           let json = jsonObject as? [String: Any] {
            return errorMessage(from: json, data: data)
        }

        return String(data: data, encoding: .utf8) ?? "Unknown error"
    }

    private static func errorMessage(from json: [String: Any], data: Data) -> String {
        if let error = json["error"] as? [String: Any] {
            if let message = error["message"] as? String {
                return message
            }
            if let message = error["error"] as? String {
                return message
            }
        }

        if let message = json["message"] as? String {
            return message
        }

        return String(data: data, encoding: .utf8) ?? "Unknown error"
    }

    private static func authorizationHeaders(redacted: Bool) -> [(String, String)] {
        [
            ("Authorization", redacted ? "Bearer <redacted>" : "Bearer <token>"),
            ("Content-Type", "application/json")
        ]
    }

    private static func rawRequest(method: String, url: URL, headers: [(String, String)], body: String?) -> String {
        var lines = [
            "\(method) \(url.absoluteString)"
        ]
        lines += headers.map { "\($0.0): \($0.1)" }
        if let body {
            lines.append("")
            lines.append(body)
        }
        return lines.joined(separator: "\n")
    }

    private static func prettyJSONString(from object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func redactedForTrace(_ value: Any) -> Any {
        if var dictionary = value as? [String: Any] {
            if let data = dictionary["data"] as? String, data.count > 120 {
                dictionary["data"] = "\(String(data.prefix(120)))...<base64 \(data.count) chars>"
            }
            for (key, nestedValue) in dictionary {
                dictionary[key] = redactedForTrace(nestedValue)
            }
            return dictionary
        }

        if let array = value as? [Any] {
            return array.map { redactedForTrace($0) }
        }

        return value
    }

    private static func normalizeBaseURL(_ rawValue: String) -> String {
        rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

private struct StreamAccumulator {
    var text = ""
    var reasoningText = ""
    var dataEventCount = 0
    var requestWordCount: Int
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?

    private var openAIToolBuffers: [Int: ToolCallBuffer] = [:]
    private var anthropicToolBuffers: [Int: ToolCallBuffer] = [:]

    init(requestWordCount: Int) {
        self.requestWordCount = requestWordCount
    }

    var toolUses: [LLMToolUse] {
        let openAIUses = openAIToolBuffers.keys.sorted().compactMap { openAIToolBuffers[$0]?.toolUse(index: $0) }
        let anthropicUses = anthropicToolBuffers.keys.sorted().compactMap { anthropicToolBuffers[$0]?.toolUse(index: $0) }
        return openAIUses + anthropicUses
    }

    mutating func consume(_ line: String) throws {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedLine.hasPrefix("data:") else {
            return
        }

        let payload = String(trimmedLine.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        if payload == "[DONE]" || payload.isEmpty {
            return
        }

        guard let data = payload.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        dataEventCount += 1
        mergeUsage(json["usage"] as? [String: Any])
        appendReasoning(json)
        parseOpenAIChunk(json)
        parseAnthropicChunk(json)
    }

    func finalUsage(responseWordCount: Int) -> LLMTokenUsage {
        LLMTokenUsage(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: totalTokens,
            requestWordCount: requestWordCount,
            responseWordCount: responseWordCount
        )
    }

    private mutating func parseOpenAIChunk(_ json: [String: Any]) {
        guard let choices = json["choices"] as? [[String: Any]] else {
            return
        }

        for choice in choices {
            if let delta = choice["delta"] as? [String: Any] {
                appendReasoning(delta)
                if let content = textContent(from: delta["content"]) {
                    text += content
                }
                parseAnthropicContent(delta["content"] as? [[String: Any]], includeText: false)
                parseOpenAIToolCalls(delta["tool_calls"] as? [[String: Any]])
            }

            if let message = choice["message"] as? [String: Any] {
                appendReasoning(message)
                if let content = textContent(from: message["content"]) {
                    text += content
                }
                parseAnthropicContent(message["content"] as? [[String: Any]], includeText: false)
                parseOpenAIToolCalls(message["tool_calls"] as? [[String: Any]])
            }
        }
    }

    private mutating func parseOpenAIToolCalls(_ toolCalls: [[String: Any]]?) {
        guard let toolCalls else {
            return
        }

        for toolCall in toolCalls {
            let index = toolCall["index"] as? Int ?? openAIToolBuffers.count
            var buffer = openAIToolBuffers[index] ?? ToolCallBuffer(source: "openai.tool_calls")
            if let id = toolCall["id"] as? String, !id.isEmpty {
                buffer.id = id
            }

            if let function = toolCall["function"] as? [String: Any] {
                if let name = function["name"] as? String, !name.isEmpty {
                    buffer.name = name
                }
                if let arguments = function["arguments"] as? String {
                    buffer.input += arguments
                } else if let input = function["input"] {
                    buffer.input = jsonString(from: input) ?? "\(input)"
                }
            }

            openAIToolBuffers[index] = buffer
        }
    }

    private mutating func parseAnthropicChunk(_ json: [String: Any]) {
        if let message = json["message"] as? [String: Any] {
            mergeUsage(message["usage"] as? [String: Any])
            appendReasoning(message)
            parseAnthropicContent(message["content"] as? [[String: Any]])
        }

        parseAnthropicContent(json["content"] as? [[String: Any]])

        guard let type = json["type"] as? String else {
            return
        }

        switch type {
        case "content_block_start":
            guard let index = json["index"] as? Int,
                  let block = json["content_block"] as? [String: Any] else {
                return
            }

            if let blockType = block["type"] as? String, blockType == "text" {
                text += block["text"] as? String ?? ""
            } else if let blockType = block["type"] as? String, blockType == "thinking" {
                reasoningText += block["thinking"] as? String ?? block["text"] as? String ?? ""
            } else if let blockType = block["type"] as? String, blockType == "tool_use" {
                var buffer = anthropicToolBuffers[index] ?? ToolCallBuffer(source: "anthropic.tool_use")
                if let id = block["id"] as? String, !id.isEmpty {
                    buffer.id = id
                }
                if let name = block["name"] as? String, !name.isEmpty {
                    buffer.name = name
                }
                if let input = block["input"],
                   let inputString = jsonString(from: input),
                   inputString != "{}" {
                    buffer.input = inputString
                }
                anthropicToolBuffers[index] = buffer
            }

        case "content_block_delta":
            guard let index = json["index"] as? Int,
                  let delta = json["delta"] as? [String: Any] else {
                return
            }

            if let deltaType = delta["type"] as? String, deltaType == "text_delta" {
                text += delta["text"] as? String ?? ""
            } else if let deltaType = delta["type"] as? String, deltaType == "thinking_delta" {
                reasoningText += delta["thinking"] as? String ?? delta["text"] as? String ?? ""
            } else if let deltaType = delta["type"] as? String, deltaType == "input_json_delta" {
                var buffer = anthropicToolBuffers[index] ?? ToolCallBuffer(source: "anthropic.tool_use")
                buffer.input += delta["partial_json"] as? String ?? ""
                anthropicToolBuffers[index] = buffer
            }

        case "message_delta":
            mergeUsage(json["usage"] as? [String: Any])

        default:
            break
        }
    }

    private mutating func parseAnthropicContent(_ content: [[String: Any]]?, includeText: Bool = true) {
        guard let content else {
            return
        }

        for (index, block) in content.enumerated() {
            guard let blockType = block["type"] as? String else {
                continue
            }

            if blockType == "text" && includeText {
                text += block["text"] as? String ?? ""
            } else if blockType == "thinking" {
                reasoningText += block["thinking"] as? String ?? block["text"] as? String ?? ""
            } else if blockType == "tool_use" {
                var buffer = anthropicToolBuffers[index] ?? ToolCallBuffer(source: "anthropic.tool_use")
                if let id = block["id"] as? String, !id.isEmpty {
                    buffer.id = id
                }
                if let name = block["name"] as? String, !name.isEmpty {
                    buffer.name = name
                }
                if let input = block["input"] {
                    buffer.input = jsonString(from: input) ?? "\(input)"
                }
                anthropicToolBuffers[index] = buffer
            }
        }
    }

    private mutating func mergeUsage(_ usage: [String: Any]?) {
        guard let usage else {
            return
        }

        if let value = intValue(usage["prompt_tokens"]) ?? intValue(usage["input_tokens"]) {
            promptTokens = value
        }

        if let value = intValue(usage["completion_tokens"]) ?? intValue(usage["output_tokens"]) {
            completionTokens = value
        }

        if let value = intValue(usage["total_tokens"]) {
            totalTokens = value
        }
    }

    private mutating func appendReasoning(_ value: Any?) {
        if let dictionary = value as? [String: Any] {
            if let text = textContent(from: dictionary["reasoning_content"]) {
                reasoningText += text
            }
            if let text = textContent(from: dictionary["thinking"]) {
                reasoningText += text
            }
            if let text = textContent(from: dictionary["reasoning"]) {
                reasoningText += text
            }
            if let text = textContent(from: dictionary["thoughts"]) {
                reasoningText += text
            }
            return
        }

        if let text = textContent(from: value) {
            reasoningText += text
        }
    }

    private func textContent(from value: Any?) -> String? {
        if let text = value as? String {
            return text
        }

        if let parts = value as? [[String: Any]] {
            return parts.compactMap { part -> String? in
                if let text = part["text"] as? String {
                    return text
                }
                if let text = part["content"] as? String {
                    return text
                }
                if let text = part["thinking"] as? String {
                    return text
                }
                return nil
            }
            .joined()
        }

        if let strings = value as? [String] {
            return strings.joined()
        }

        return nil
    }

    private func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }

        if let double = value as? Double {
            return Int(double)
        }

        if let string = value as? String {
            return Int(string)
        }

        return nil
    }

    private func jsonString(from value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }
}

private struct ToolCallBuffer {
    var id = ""
    var name = ""
    var input = ""
    var source: String

    func toolUse(index: Int) -> LLMToolUse? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty || !trimmedInput.isEmpty else {
            return nil
        }

        return LLMToolUse(
            id: id.isEmpty ? "\(source).\(index)" : id,
            name: trimmedName.isEmpty ? "unknown_tool" : trimmedName,
            input: trimmedInput.isEmpty ? "{}" : trimmedInput,
            source: source
        )
    }
}
