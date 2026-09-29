import Foundation
import MackyCore

/// Talks to OpenRouter directly from the app. There is no proxy server: Macky is a personal
/// app, so the only user is the owner of the API key, which lives in the macOS Keychain.
final class OpenRouterClient: @unchecked Sendable {
    static let baseURL = URL(string: "https://openrouter.ai/api/v1")!

    struct CollectedResponse {
        var text: String
        var toolCalls: [ChatToolCall]
        var usage: TokenUsage?
    }

    struct CreditBalance {
        var totalCredits: Double
        var totalUsage: Double
        var remainingCredits: Double { totalCredits - totalUsage }
    }

    private let urlSession: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 180
        urlSession = URLSession(configuration: configuration)
    }

    func streamChatCompletion(requestBody: Data, apiKey: String) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let streamingTask = Task {
                do {
                    var request = makeRequest(path: "chat/completions", apiKey: apiKey)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = requestBody

                    let (responseBytes, response) = try await urlSession.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw OpenRouterAPIError(httpStatusCode: nil, message: "Răspuns invalid de la server.")
                    }
                    if httpResponse.statusCode != 200 {
                        var errorBody = ""
                        for try await line in responseBytes.lines {
                            errorBody += line
                            if errorBody.count > 20_000 { break }
                        }
                        throw OpenRouterAPIError.fromHTTPResponse(statusCode: httpResponse.statusCode, body: errorBody)
                    }

                    var decoder = OpenRouterStreamDecoder()
                    lineLoop: for try await line in responseBytes.lines {
                        try Task.checkCancellation()
                        switch ServerSentEventLineParser.parse(line) {
                        case .data(let payload):
                            for event in try decoder.consume(dataPayload: payload) {
                                continuation.yield(event)
                            }
                        case .done:
                            break lineLoop
                        case .ignorable:
                            continue
                        }
                    }
                    for event in decoder.finish() {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                streamingTask.cancel()
            }
        }
    }

    /// Runs a streaming request and gathers the whole answer. Used by calibration, where nothing is spoken.
    func collectChatCompletion(requestBody: Data, apiKey: String) async throws -> CollectedResponse {
        var collectedResponse = CollectedResponse(text: "", toolCalls: [], usage: nil)
        for try await event in streamChatCompletion(requestBody: requestBody, apiKey: apiKey) {
            switch event {
            case .textDelta(let text):
                collectedResponse.text += text
            case .toolCall(let toolCall):
                collectedResponse.toolCalls.append(toolCall)
            case .usage(let usage):
                collectedResponse.usage = usage
            case .finished:
                break
            }
        }
        return collectedResponse
    }

    /// Opens the network connection (DNS + TLS) while the user is still talking, so the real
    /// request a few seconds later reuses it instead of paying that setup time.
    func warmUpConnection() {
        var request = makeRequest(path: "models", apiKey: nil)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        urlSession.dataTask(with: request).resume()
    }

    func fetchModels() async throws -> [ModelSummary] {
        let request = makeRequest(path: "models", apiKey: nil)
        let (data, response) = try await urlSession.data(for: request)
        try Self.throwIfUnsuccessful(response: response, data: data)
        return try ModelCatalog.parseModelsResponse(data)
    }

    /// Also serves as an API key check: an invalid key answers 401.
    func fetchCreditBalance(apiKey: String) async throws -> CreditBalance {
        let request = makeRequest(path: "credits", apiKey: apiKey)
        let (data, response) = try await urlSession.data(for: request)
        try Self.throwIfUnsuccessful(response: response, data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let balance = json["data"] as? [String: Any] else {
            throw OpenRouterAPIError(httpStatusCode: nil, message: "Răspuns neașteptat pentru credite.")
        }
        return CreditBalance(
            totalCredits: (balance["total_credits"] as? NSNumber)?.doubleValue ?? 0,
            totalUsage: (balance["total_usage"] as? NSNumber)?.doubleValue ?? 0
        )
    }

    private func makeRequest(path: String, apiKey: String?) -> URLRequest {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent(path))
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        // Optional attribution headers; they only label requests in the OpenRouter dashboard.
        request.setValue("https://github.com/flowfulmedia-ai/macky", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Macky", forHTTPHeaderField: "X-Title")
        return request
    }

    private static func throwIfUnsuccessful(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw OpenRouterAPIError.fromHTTPResponse(statusCode: httpResponse.statusCode, body: String(decoding: data, as: UTF8.self))
        }
    }
}
