import Foundation
import MackyCore

/// Web search (through OpenRouter's web plugin on the fast model) and page reading,
/// shared by spoken questions and background agents.
@MainActor
final class WebResearchService {
    private let settings: AppSettings
    private let openRouterClient: OpenRouterClient
    private let pageDownloadSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"]
        return URLSession(configuration: configuration)
    }()

    init(settings: AppSettings, openRouterClient: OpenRouterClient) {
        self.settings = settings
        self.openRouterClient = openRouterClient
    }

    /// A small model call with the web plugin, asked for a clean list of sources. Returns the text and its cost.
    func search(_ query: String, apiKey: String, resultCount: Int = 6) async -> (text: String, cost: Double?) {
        let modelIdentifier = settings.fastModelIdentifier.isEmpty ? settings.powerfulModelIdentifier : settings.fastModelIdentifier
        do {
            let requestBody = try OpenRouterRequestBuilder.makeChatCompletionBody(
                modelIdentifier: modelIdentifier,
                messages: [ChatMessage(role: .user, text: "Web search: \(query)\n\nList the \(resultCount) most relevant results. For each: title, full URL, and 1-2 sentences with the concrete facts it contains (numbers, prices, dates). No introduction.")],
                tools: [],
                coordinateConvention: .imagePixels,
                disableReasoning: settings.shouldDisableReasoning(forModelIdentifier: modelIdentifier),
                enableWebSearch: true,
                maximumResponseTokens: 1500
            )
            let response = try await openRouterClient.collectChatCompletion(requestBody: requestBody, apiKey: apiKey, purpose: .web)
            return (response.text.isEmpty ? "No results." : response.text, response.usage?.costInCredits)
        } catch {
            return ("Search failed: \(CompanionSession.userFacingMessage(for: error))", nil)
        }
    }

    func readableText(from address: String, maximumCharacters: Int = 12_000) async -> String {
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return "Invalid URL."
        }
        do {
            let (data, response) = try await pageDownloadSession.data(from: url)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<400).contains(statusCode) else { return "The page answered HTTP \(statusCode)." }
            let html = String(decoding: data.prefix(3_000_000), as: UTF8.self)
            let text = HTMLTextExtractor.readableText(fromHTML: html, maximumCharacters: maximumCharacters)
            return text.isEmpty ? "The page has no readable text." : text
        } catch {
            return "Could not download the page: \(error.localizedDescription)"
        }
    }
}
