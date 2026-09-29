import Foundation

/// Keeps the recent exchanges of the current session. Only the newest question carries
/// screenshots; older turns are sent as text to keep each request small and cheap.
public struct ConversationHistory {
    public struct Exchange: Equatable, Sendable {
        public var userText: String
        public var assistantText: String
    }

    public private(set) var exchanges: [Exchange] = []
    public var maximumRememberedExchanges: Int

    public init(maximumRememberedExchanges: Int = 6) {
        self.maximumRememberedExchanges = maximumRememberedExchanges
    }

    public mutating func record(userText: String, assistantText: String) {
        exchanges.append(Exchange(userText: userText, assistantText: assistantText))
        if exchanges.count > maximumRememberedExchanges {
            exchanges.removeFirst(exchanges.count - maximumRememberedExchanges)
        }
    }

    public mutating func clear() {
        exchanges.removeAll()
    }

    public func messagesForRequest(systemPrompt: String, currentUserParts: [ChatContentPart]) -> [ChatMessage] {
        var messages = [ChatMessage(role: .system, text: systemPrompt)]
        for exchange in exchanges.suffix(maximumRememberedExchanges) {
            messages.append(ChatMessage(role: .user, text: exchange.userText))
            let assistantText = exchange.assistantText.isEmpty ? "(fără răspuns)" : exchange.assistantText
            messages.append(ChatMessage(role: .assistant, text: assistantText))
        }
        messages.append(ChatMessage(role: .user, parts: currentUserParts))
        return messages
    }
}

/// Totals for the running session, shown in the menu bar panel.
public struct SessionCostTracker: Equatable, Sendable {
    public private(set) var requestCount = 0
    public private(set) var totalCostInCredits: Double = 0
    public private(set) var lastRequestCostInCredits: Double?
    public private(set) var totalPromptTokens = 0
    public private(set) var totalCompletionTokens = 0

    public init() {}

    public mutating func record(_ usage: TokenUsage) {
        requestCount += 1
        totalPromptTokens += usage.promptTokens
        totalCompletionTokens += usage.completionTokens
        lastRequestCostInCredits = usage.costInCredits
        totalCostInCredits += usage.costInCredits ?? 0
    }

    public static func formatCredits(_ credits: Double) -> String {
        if credits == 0 { return "$0" }
        if credits < 0.01 { return String(format: "$%.4f", credits) }
        return String(format: "$%.2f", credits)
    }
}
