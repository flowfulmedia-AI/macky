import Foundation
import MackyCore

/// How much credit is left on OpenRouter and what Macky spent it on.
/// OpenRouter reports the balance and the key's daily/weekly/monthly usage; Macky itself keeps
/// a ledger per category (questions, meetings, memory…) in ~/Library/Application Support/Macky/usage.json.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var ledger = UsageLedger()
    @Published private(set) var remainingCredit: Double?
    @Published private(set) var totalPurchasedCredit: Double?
    @Published private(set) var keyUsage: OpenRouterKeyUsage?
    @Published private(set) var lastRefreshDate: Date?
    @Published private(set) var errorText: String?

    /// Below this, the panel shows the balance in orange.
    static let lowBalanceThreshold = 2.0

    private let apiKeyStore: OpenRouterAPIKeyStore
    private let openRouterClient: OpenRouterClient
    private let fileURL = ApplicationDirectories.applicationSupportDirectory.appendingPathComponent("usage.json")
    private var timer: Timer?
    private var pendingRefresh: Task<Void, Never>?

    init(apiKeyStore: OpenRouterAPIKeyStore, openRouterClient: OpenRouterClient) {
        self.apiKeyStore = apiKeyStore
        self.openRouterClient = openRouterClient
        if let data = try? Data(contentsOf: fileURL), let savedLedger = try? JSONDecoder().decode(UsageLedger.self, from: data) {
            ledger = savedLedger
        }
    }

    func start() {
        Task { await refresh() }
        let timer = Timer(timeInterval: 10 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func record(_ usage: TokenUsage, purpose: UsagePurpose) {
        ledger.record(usage, purpose: purpose)
        if let data = try? JSONEncoder().encode(ledger) {
            try? data.write(to: fileURL, options: .atomic)
        }
        // The balance on OpenRouter updates a few seconds later; refresh once things calm down.
        pendingRefresh?.cancel()
        pendingRefresh = Task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    func refresh() async {
        guard let apiKey = apiKeyStore.apiKey(), !apiKey.isEmpty else { return }
        do {
            let balance = try await openRouterClient.fetchCreditBalance(apiKey: apiKey)
            remainingCredit = balance.remainingCredits
            totalPurchasedCredit = balance.totalCredits
            errorText = nil
        } catch {
            errorText = CompanionSession.userFacingMessage(for: error)
        }
        keyUsage = try? await openRouterClient.fetchKeyUsage(apiKey: apiKey)
        lastRefreshDate = Date()
    }

    var estimatedDaysLeft: Int? {
        remainingCredit.flatMap { ledger.estimatedDaysLeft(remainingCredit: $0) }
    }

    static func format(_ amount: Double) -> String {
        SessionCostTracker.formatCredits(amount)
    }
}
