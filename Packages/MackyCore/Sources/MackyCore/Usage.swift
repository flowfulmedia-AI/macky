import Foundation

/// What a model request was for, so spending can be shown per category.
public enum UsagePurpose: String, Codable, CaseIterable, Sendable {
    case questions
    case memory
    case web
    case agents
    case meetings
    case calibration

    public var displayName: String {
        switch self {
        case .questions: return "Întrebări și acțiuni"
        case .memory: return "Memorie"
        case .web: return "Căutări pe web"
        case .agents: return "Agenți în fundal"
        case .meetings: return "Meetinguri Zoom"
        case .calibration: return "Calibrare"
        }
    }
}

/// Everything Macky spent on OpenRouter, per day and category. Kept locally; small (one entry per day).
public struct UsageLedger: Codable, Equatable, Sendable {
    public struct Day: Codable, Equatable, Sendable {
        public var costByPurpose: [String: Double] = [:]
        public var requestCount = 0
        public var promptTokens = 0
        public var completionTokens = 0

        public var totalCost: Double { costByPurpose.values.reduce(0, +) }
    }

    /// Keyed by "yyyy-MM-dd" in the user's time zone.
    public private(set) var days: [String: Day] = [:]

    public init() {}

    static func dayKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    public mutating func record(_ usage: TokenUsage, purpose: UsagePurpose, date: Date = Date(), calendar: Calendar = .current) {
        let key = Self.dayKey(for: date, calendar: calendar)
        var day = days[key] ?? Day()
        day.costByPurpose[purpose.rawValue, default: 0] += usage.costInCredits ?? 0
        day.requestCount += 1
        day.promptTokens += usage.promptTokens
        day.completionTokens += usage.completionTokens
        days[key] = day
        // A year of history is plenty.
        if days.count > 400, let oldestKey = days.keys.min() { days[oldestKey] = nil }
    }

    /// Total cost of the last `dayCount` days including today.
    public func totalCost(lastDays dayCount: Int, now: Date = Date(), calendar: Calendar = .current) -> Double {
        dailyTotals(lastDays: dayCount, now: now, calendar: calendar).map(\.cost).reduce(0, +)
    }

    public func totalCostThisMonth(now: Date = Date(), calendar: Calendar = .current) -> Double {
        let prefix = String(Self.dayKey(for: now, calendar: calendar).prefix(7))
        return days.filter { $0.key.hasPrefix(prefix) }.map(\.value.totalCost).reduce(0, +)
    }

    public func requestCount(lastDays dayCount: Int, now: Date = Date(), calendar: Calendar = .current) -> Int {
        dayKeys(lastDays: dayCount, now: now, calendar: calendar).compactMap { days[$0]?.requestCount }.reduce(0, +)
    }

    /// Oldest first, one entry per day, zero for days without requests.
    public func dailyTotals(lastDays dayCount: Int, now: Date = Date(), calendar: Calendar = .current) -> [(date: Date, cost: Double)] {
        (0..<max(dayCount, 0)).reversed().compactMap { daysBack in
            guard let date = calendar.date(byAdding: .day, value: -daysBack, to: calendar.startOfDay(for: now)) else { return nil }
            return (date, days[Self.dayKey(for: date, calendar: calendar)]?.totalCost ?? 0)
        }
    }

    /// Cost per category over the last `dayCount` days, most expensive first.
    public func costByPurpose(lastDays dayCount: Int, now: Date = Date(), calendar: Calendar = .current) -> [(purpose: UsagePurpose, cost: Double)] {
        var totals: [UsagePurpose: Double] = [:]
        for key in dayKeys(lastDays: dayCount, now: now, calendar: calendar) {
            for (rawPurpose, cost) in days[key]?.costByPurpose ?? [:] {
                if let purpose = UsagePurpose(rawValue: rawPurpose) { totals[purpose, default: 0] += cost }
            }
        }
        return totals.map { ($0.key, $0.value) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
    }

    /// How many days the remaining credit lasts at the average pace of the last week.
    public func estimatedDaysLeft(remainingCredit: Double, now: Date = Date(), calendar: Calendar = .current) -> Int? {
        let weeklyAverage = totalCost(lastDays: 7, now: now, calendar: calendar) / 7
        guard weeklyAverage > 0.000_1, remainingCredit > 0 else { return nil }
        return Int(remainingCredit / weeklyAverage)
    }

    private func dayKeys(lastDays dayCount: Int, now: Date, calendar: Calendar) -> [String] {
        dailyTotals(lastDays: dayCount, now: now, calendar: calendar).map { Self.dayKey(for: $0.date, calendar: calendar) }
    }
}

/// OpenRouter's own numbers for the API key (GET /api/v1/key); they include usage outside Macky.
public struct OpenRouterKeyUsage: Equatable, Sendable {
    public var totalUsage: Double
    public var dailyUsage: Double?
    public var weeklyUsage: Double?
    public var monthlyUsage: Double?
    public var limit: Double?
    public var limitRemaining: Double?

    public static func parse(_ data: Data) -> OpenRouterKeyUsage? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = json["data"] as? [String: Any] else { return nil }
        return OpenRouterKeyUsage(
            totalUsage: OpenRouterStreamDecoder.doubleValue(info["usage"]) ?? 0,
            dailyUsage: OpenRouterStreamDecoder.doubleValue(info["usage_daily"]),
            weeklyUsage: OpenRouterStreamDecoder.doubleValue(info["usage_weekly"]),
            monthlyUsage: OpenRouterStreamDecoder.doubleValue(info["usage_monthly"]),
            limit: OpenRouterStreamDecoder.doubleValue(info["limit"]),
            limitRemaining: OpenRouterStreamDecoder.doubleValue(info["limit_remaining"])
        )
    }
}

/// Starter ideas shown as cards when there is no conversation yet, picked by what is connected.
public enum SuggestionCatalog {
    public struct Suggestion: Equatable, Sendable, Identifiable {
        public var id: String { text }
        public var text: String
        public var symbol: String

        public init(text: String, symbol: String) {
            self.text = text
            self.symbol = symbol
        }
    }

    public static func suggestions(hasGoogle: Bool, hasTaskApp: Bool, hasZoom: Bool, hour: Int) -> [Suggestion] {
        var pool: [Suggestion] = []
        if hour < 12 { pool.append(Suggestion(text: "Brief de dimineață", symbol: "sun.max")) }
        if hasGoogle { pool.append(Suggestion(text: "Ce mailuri importante am necitite azi?", symbol: "envelope")) }
        if hasTaskApp { pool.append(Suggestion(text: "Ce taskuri am azi?", symbol: "checklist")) }
        pool.append(Suggestion(text: "Ce am în calendar mâine?", symbol: "calendar"))
        if hasZoom { pool.append(Suggestion(text: "Ce s-a decis în ultimul meeting?", symbol: "video")) }
        pool.append(Suggestion(text: "Agent, caută ultimele noutăți din marketingul pe Meta Ads și fă-mi un rezumat", symbol: "sparkle.magnifyingglass"))
        pool.append(Suggestion(text: "Ce știi despre mine și clienții mei?", symbol: "brain"))
        return Array(pool.prefix(3))
    }
}
