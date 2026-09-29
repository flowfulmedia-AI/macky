import Foundation

public struct TokenUsage: Equatable, Sendable {
    public var promptTokens: Int
    public var completionTokens: Int
    /// Cost of the request in OpenRouter credits (USD), when OpenRouter reports it.
    public var costInCredits: Double?

    public init(promptTokens: Int, completionTokens: Int, costInCredits: Double?) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.costInCredits = costInCredits
    }
}

public enum LLMStreamEvent: Equatable, Sendable {
    case textDelta(String)
    case toolCall(name: String, argumentsJSON: String)
    case usage(TokenUsage)
    case finished(reason: String)
}

public enum ServerSentEventLine: Equatable {
    case data(String)
    case done
    case ignorable
}

public enum ServerSentEventLineParser {
    /// OpenRouter sends one JSON object per `data:` line, `data: [DONE]` at the end,
    /// and `: OPENROUTER PROCESSING` comment lines as keep-alives.
    public static func parse(_ line: String) -> ServerSentEventLine {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedLine.hasPrefix("data:") else { return .ignorable }
        let payload = trimmedLine.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        if payload.isEmpty { return .ignorable }
        return .data(payload)
    }
}

public struct OpenRouterAPIError: Error, Equatable, LocalizedError {
    public var httpStatusCode: Int?
    public var message: String

    public init(httpStatusCode: Int?, message: String) {
        self.httpStatusCode = httpStatusCode
        self.message = message
    }

    public var errorDescription: String? {
        if let httpStatusCode { return "OpenRouter (\(httpStatusCode)): \(message)" }
        return "OpenRouter: \(message)"
    }

    /// OpenRouter answers 404 "No endpoints found that support tool use" for models without tool calling.
    public var indicatesToolCallingUnsupported: Bool {
        let lowercasedMessage = message.lowercased()
        return lowercasedMessage.contains("tool") && (lowercasedMessage.contains("support") || httpStatusCode == 404)
    }

    public var indicatesInvalidAPIKey: Bool { httpStatusCode == 401 }
    public var indicatesInsufficientCredits: Bool { httpStatusCode == 402 }

    public static func fromHTTPResponse(statusCode: Int, body: String) -> OpenRouterAPIError {
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return OpenRouterAPIError(httpStatusCode: statusCode, message: message)
        }
        let shortenedBody = String(body.prefix(300))
        return OpenRouterAPIError(httpStatusCode: statusCode, message: shortenedBody.isEmpty ? "Eroare necunoscută" : shortenedBody)
    }
}

/// Turns OpenRouter streaming chunks into text deltas, complete tool calls and usage.
/// Tool call arguments arrive in fragments spread over many chunks, so they are
/// accumulated per tool call index and only emitted once the stream finishes.
public struct OpenRouterStreamDecoder {
    private struct PartialToolCall {
        var name: String = ""
        var argumentsJSON: String = ""
    }

    private var partialToolCallsByIndex: [Int: PartialToolCall] = [:]
    private var haveEmittedToolCalls = false

    public init() {}

    public mutating func consume(dataPayload: String) throws -> [LLMStreamEvent] {
        guard let data = dataPayload.data(using: .utf8),
              let chunk = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        // Errors that happen mid-stream arrive as a normal chunk with an `error` object.
        if let error = chunk["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Eroare necunoscută"
            let code = error["code"] as? Int
            throw OpenRouterAPIError(httpStatusCode: code, message: message)
        }

        var events: [LLMStreamEvent] = []

        if let choices = chunk["choices"] as? [[String: Any]], let firstChoice = choices.first {
            if let delta = firstChoice["delta"] as? [String: Any] {
                if let content = delta["content"] as? String, !content.isEmpty {
                    events.append(.textDelta(content))
                }
                if let toolCallFragments = delta["tool_calls"] as? [[String: Any]] {
                    accumulate(toolCallFragments: toolCallFragments)
                }
            }
            if let finishReason = firstChoice["finish_reason"] as? String {
                events.append(contentsOf: emitCompletedToolCalls())
                events.append(.finished(reason: finishReason))
            }
        }

        if let usage = chunk["usage"] as? [String: Any] {
            let promptTokens = Self.integerValue(usage["prompt_tokens"]) ?? 0
            let completionTokens = Self.integerValue(usage["completion_tokens"]) ?? 0
            let cost = Self.doubleValue(usage["cost"])
            events.append(.usage(TokenUsage(promptTokens: promptTokens, completionTokens: completionTokens, costInCredits: cost)))
        }

        return events
    }

    /// Call when the stream ends, in case the provider never sent a `finish_reason`.
    public mutating func finish() -> [LLMStreamEvent] {
        emitCompletedToolCalls()
    }

    private mutating func accumulate(toolCallFragments: [[String: Any]]) {
        for (positionInChunk, fragment) in toolCallFragments.enumerated() {
            let index = Self.integerValue(fragment["index"]) ?? positionInChunk
            var partialToolCall = partialToolCallsByIndex[index] ?? PartialToolCall()
            if let function = fragment["function"] as? [String: Any] {
                if let name = function["name"] as? String { partialToolCall.name += name }
                if let arguments = function["arguments"] as? String { partialToolCall.argumentsJSON += arguments }
            }
            partialToolCallsByIndex[index] = partialToolCall
        }
    }

    private mutating func emitCompletedToolCalls() -> [LLMStreamEvent] {
        guard !haveEmittedToolCalls, !partialToolCallsByIndex.isEmpty else { return [] }
        haveEmittedToolCalls = true
        return partialToolCallsByIndex.keys.sorted().compactMap { index in
            guard let toolCall = partialToolCallsByIndex[index], !toolCall.name.isEmpty else { return nil }
            return .toolCall(name: toolCall.name, argumentsJSON: toolCall.argumentsJSON)
        }
    }

    static func integerValue(_ value: Any?) -> Int? {
        if let intValue = value as? Int { return intValue }
        if let doubleValue = value as? Double { return Int(doubleValue) }
        if let stringValue = value as? String { return Int(stringValue) }
        return nil
    }

    static func doubleValue(_ value: Any?) -> Double? {
        if let doubleValue = value as? Double { return doubleValue }
        if let intValue = value as? Int { return Double(intValue) }
        if let stringValue = value as? String { return Double(stringValue) }
        return nil
    }
}
