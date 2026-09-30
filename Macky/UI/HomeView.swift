import Charts
import MackyCore
import SwiftUI

/// Macky's main window: a sidebar of little characters (home, agents, meetings, memory, history, routines, usage)
/// and the selected section on the right.
struct HomeView: View {
    enum Section: String, CaseIterable, Identifiable {
        case home, agents, meetings, memory, history, routines, usage
        var id: String { rawValue }

        var title: String {
            switch self {
            case .home: return "Macky"
            case .agents: return "Agenți"
            case .meetings: return "Meetinguri"
            case .memory: return "Memorie"
            case .history: return "Istoric"
            case .routines: return "Rutine"
            case .usage: return "Consum"
            }
        }

        var palette: [Color] {
            switch self {
            case .home: return MascotPalette.mint
            case .agents: return MascotPalette.peach
            case .meetings: return MascotPalette.sky
            case .memory: return MascotPalette.lilac
            case .history: return MascotPalette.silver
            case .routines: return MascotPalette.lemon
            case .usage: return MascotPalette.mint.reversed()
            }
        }
    }

    @ObservedObject var session: CompanionSession
    @ObservedObject var settings: AppSettings
    @ObservedObject var usageStore: UsageStore
    @ObservedObject var agentManager: BackgroundAgentManager
    @ObservedObject var zoomMeetingsManager: ZoomMeetingsManager
    @ObservedObject var memoryManager: MemoryManager
    @ObservedObject var historyStore: HistoryStore
    @ObservedObject var routineStore: RoutineStore
    let suggestions: [SuggestionCatalog.Suggestion]
    let openSettings: () -> Void
    /// The smaller version shown under the notch.
    var compact = false
    /// Replaces the Home section (the notch uses its quick-question panel there).
    var homeContent: AnyView?

    @State private var selection: Section = .home

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(MackyDesign.hairline)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(compact ? Color.clear : MackyDesign.windowBackground)
        }
        .background(compact ? Color.clear : MackyDesign.windowBackground)
        .environment(\.colorScheme, .dark)
        .frame(minWidth: compact ? nil : 900, minHeight: compact ? nil : 620)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !compact {
                HStack(spacing: 8) {
                    MackyMascotView(mood: .happy, size: 30)
                    Text("Macky").font(MackyDesign.rounded(20, .bold)).foregroundColor(MackyDesign.textPrimary)
                }
                .padding(.horizontal, 14)
                .padding(.top, 18)
                .padding(.bottom, 12)
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(Section.allCases) { section in
                        sidebarRow(section)
                    }
                }
            }

            Spacer(minLength: 0)
            Divider().overlay(MackyDesign.hairline)
            HStack {
                creditSummary
                Spacer()
                Button(action: openSettings) { Image(systemName: "gearshape") }
                    .buttonStyle(MackyIconButtonStyle())
                    .help("Setări")
            }
            .padding(compact ? 10 : 14)
        }
        .padding(.top, compact ? 8 : 0)
        .frame(width: compact ? 214 : 270)
        .background(compact ? MackyDesign.surface.opacity(0.5) : MackyDesign.sidebarBackground)
        .clipShape(RoundedRectangle(cornerRadius: compact ? 18 : 0, style: .continuous))
    }

    private func sidebarRow(_ section: Section) -> some View {
        let isSelected = selection == section
        return Button { selection = section } label: {
            HStack(spacing: compact ? 9 : 12) {
                MackyMascotView(mood: section == .home ? mascotMood : .idle, size: compact ? 30 : 40, colors: section.palette)
                VStack(alignment: .leading, spacing: compact ? 1 : 2) {
                    HStack {
                        Text(section.title).font(MackyDesign.rounded(compact ? 13 : 15, .bold)).foregroundColor(MackyDesign.textPrimary)
                        Spacer()
                        if let badge = badge(for: section) {
                            Text(badge)
                                .font(MackyDesign.rounded(11, .semibold))
                                .foregroundColor(MackyDesign.textSecondary)
                        }
                    }
                    Text(subtitle(for: section))
                        .font(MackyDesign.rounded(compact ? 11 : 12))
                        .foregroundColor(MackyDesign.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 6 : 8)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.85).opacity(0.55), Color(red: 0.30, green: 0.34, blue: 0.70).opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)) : AnyShapeStyle(Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(isSelected ? MackyDesign.primaryButtonGlow.opacity(0.7) : Color.clear, lineWidth: 1.5))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, compact ? 4 : 8)
        .pointingHandOnHover()
    }

    private func subtitle(for section: Section) -> String {
        switch section {
        case .home: return session.lastAnswerText.isEmpty ? session.state.displayName : session.lastAnswerText
        case .agents:
            if agentManager.runningJobCount > 0 { return "\(agentManager.runningJobCount) lucrează acum" }
            return agentManager.jobs.first?.goal ?? "Cercetări și sarcini lungi"
        case .meetings: return zoomMeetingsManager.processedMeetings.first?.topic ?? "Zoom → notițe în Drive"
        case .memory: return "\(memoryManager.items.count) amintiri · \(memoryManager.procedureBook.procedures.count) proceduri"
        case .history: return historyStore.entries.first?.question ?? "Toate cererile tale"
        case .routines: return routineStore.routines.filter(\.isEnabled).map(\.name).joined(separator: ", ")
        case .usage: return usageStore.remainingCredit.map { "\(UsageStore.format($0)) credit rămas" } ?? "Credit OpenRouter"
        }
    }

    private func badge(for section: Section) -> String? {
        switch section {
        case .agents: return agentManager.runningJobCount > 0 ? "\(agentManager.runningJobCount)" : nil
        case .history: return historyStore.entries.first.map { $0.date.formatted(date: .omitted, time: .shortened) }
        case .meetings: return zoomMeetingsManager.processedMeetings.first.map { $0.date.formatted(.dateTime.day().month(.abbreviated)) }
        default: return nil
        }
    }

    private var creditSummary: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(usageStore.remainingCredit.map(UsageStore.format) ?? "—")
                .font(MackyDesign.rounded(15, .bold))
                .foregroundColor((usageStore.remainingCredit ?? 99) < UsageStore.lowBalanceThreshold ? .orange : MackyDesign.textPrimary)
            Text("credit OpenRouter").font(MackyDesign.rounded(11)).foregroundColor(MackyDesign.textSecondary)
        }
    }

    private var mascotMood: MackyMood {
        switch session.state {
        case .idle: return .idle
        case .listening: return .listening
        case .transcribing, .thinking: return .thinking
        case .speaking: return .speaking
        case .failed: return .error
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .home:
            if let homeContent {
                homeContent.padding(.leading, 10)
            } else {
                HomeSectionView(session: session, settings: settings, suggestions: suggestions, mood: mascotMood)
            }
        case .agents:
            AgentsSectionView(agentManager: agentManager)
        case .meetings:
            MeetingsSectionView(manager: zoomMeetingsManager, openSettings: openSettings)
        case .memory:
            MemoryView(memoryManager: memoryManager, settings: settings)
        case .history:
            HistoryView(historyStore: historyStore, settings: settings)
        case .routines:
            RoutinesSettingsTab(routineStore: routineStore, session: session).padding(20)
        case .usage:
            UsageView(usageStore: usageStore)
        }
    }
}

// MARK: - Home

private struct HomeSectionView: View {
    @ObservedObject var session: CompanionSession
    @ObservedObject var settings: AppSettings
    let suggestions: [SuggestionCatalog.Suggestion]
    let mood: MackyMood
    @State private var typedQuestion = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .center, spacing: 18) {
                        MackyMascotView(mood: mood, size: 96)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(greeting).font(MackyDesign.rounded(30, .bold)).foregroundColor(MackyDesign.textPrimary)
                            Text("Ține \(settings.talkCombination.symbols) oriunde și vorbește. Văd ecranul, îți răspund și fac lucruri pentru tine.")
                                .font(MackyDesign.rounded(14))
                                .foregroundColor(MackyDesign.textSecondary)
                        }
                    }
                    if !session.lastAnswerText.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            if !session.lastQuestionText.isEmpty {
                                Text(session.lastQuestionText).font(MackyDesign.rounded(13, .semibold)).foregroundColor(MackyDesign.textSecondary)
                            }
                            Text(session.lastAnswerText)
                                .font(MackyDesign.rounded(15))
                                .foregroundColor(MackyDesign.textPrimary)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .mackyCard(cornerRadius: 22, padding: 18)
                    }
                    Text("Sugestii: alege una și mă apuc")
                        .font(MackyDesign.rounded(13, .medium))
                        .foregroundColor(MackyDesign.textSecondary)
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                            SuggestionCardView(text: suggestion.text, symbol: suggestion.symbol,
                                               color: MackyDesign.pastels[index % MackyDesign.pastels.count],
                                               tilt: [-2.0, 1.5, -1.0][index % 3]) {
                                session.ask(typedQuestion: suggestion.text)
                            }
                        }
                    }
                }
                .padding(28)
            }
            HStack(spacing: 12) {
                HoldToTalkButton(session: session, title: "Ține \(settings.talkCombination.symbols) ca să vorbești")
                    .frame(maxWidth: 360)
                HStack(spacing: 8) {
                    Image(systemName: "keyboard").foregroundColor(MackyDesign.textSecondary)
                    TextField("Scrie…", text: $typedQuestion)
                        .textFieldStyle(.plain)
                        .font(MackyDesign.rounded(14))
                        .onSubmit {
                            let question = typedQuestion
                            typedQuestion = ""
                            session.ask(typedQuestion: question)
                        }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(Capsule().fill(MackyDesign.surface))
                .overlay(Capsule().stroke(MackyDesign.hairline, lineWidth: 1))
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Bună dimineața!"
        case 12..<18: return "Bună ziua!"
        default: return "Bună seara!"
        }
    }
}

// MARK: - Agents

private struct AgentsSectionView: View {
    @ObservedObject var agentManager: BackgroundAgentManager
    @State private var goal = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Agenți în fundal").font(MackyDesign.rounded(24, .bold)).foregroundColor(MackyDesign.textPrimary)
            Text("Dă-le o sarcină lungă (cercetare, comparații, un document) și continuă-ți treaba. Rezultatul ajunge în Documents/Macky.")
                .font(MackyDesign.rounded(13)).foregroundColor(MackyDesign.textSecondary)
            HStack(spacing: 10) {
                TextField("ex. Caută cele mai bune 5 CRM-uri pentru agenții mici și fă o comparație", text: $goal)
                    .textFieldStyle(.plain)
                    .font(MackyDesign.rounded(14))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(Capsule().fill(MackyDesign.surface))
                    .overlay(Capsule().stroke(MackyDesign.hairline, lineWidth: 1))
                    .onSubmit(start)
                Button(action: start) { Label("Pornește", systemImage: "play.fill") }
                    .buttonStyle(MackyPrimaryPillStyle())
                    .disabled(goal.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if agentManager.jobs.isEmpty {
                Spacer()
                HStack { Spacer(); MackyMascotView(mood: .idle, size: 80, colors: MascotPalette.peach); Spacer() }
                Text("Niciun agent încă. Poți spune și „Agent, …” cu vocea.")
                    .font(MackyDesign.rounded(13)).foregroundColor(MackyDesign.textSecondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView { BackgroundJobsView(agentManager: agentManager) }
            }
        }
        .padding(28)
    }

    private func start() {
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGoal.isEmpty else { return }
        agentManager.start(goal: trimmedGoal)
        goal = ""
    }
}

// MARK: - Meetings

private struct MeetingsSectionView: View {
    @ObservedObject var manager: ZoomMeetingsManager
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Meetinguri Zoom").font(MackyDesign.rounded(24, .bold)).foregroundColor(MackyDesign.textPrimary)
                Spacer()
                if manager.hasCredentials {
                    Button(manager.isChecking ? "Verific…" : "Verifică acum") { Task { await manager.checkForNewMeetings() } }
                        .buttonStyle(MackySecondaryPillStyle())
                        .disabled(manager.isChecking)
                } else {
                    Button("Conectează Zoom", action: openSettings).buttonStyle(MackyPrimaryPillStyle())
                }
            }
            if let statusText = manager.statusText {
                Text(statusText).font(MackyDesign.rounded(12)).foregroundColor(statusText.hasPrefix("Eroare") ? .orange : MackyDesign.textSecondary)
            }
            if manager.processedMeetings.isEmpty {
                Spacer()
                HStack { Spacer(); MackyMascotView(mood: .idle, size: 80, colors: MascotPalette.sky); Spacer() }
                Text("Meetingurile înregistrate în cloud apar aici, cu notițele din Drive.")
                    .font(MackyDesign.rounded(13)).foregroundColor(MackyDesign.textSecondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(manager.processedMeetings) { meeting in
                            HStack(spacing: 12) {
                                Image(systemName: meeting.status == .saved ? "doc.text.fill" : "exclamationmark.triangle.fill")
                                    .foregroundColor(meeting.status == .saved ? MascotPalette.sky[1] : .orange)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(meeting.topic).font(MackyDesign.rounded(14, .semibold)).foregroundColor(MackyDesign.textPrimary)
                                    Text(meeting.date.formatted(date: .abbreviated, time: .shortened) + (meeting.message.map { " · \($0)" } ?? ""))
                                        .font(MackyDesign.rounded(12)).foregroundColor(MackyDesign.textSecondary)
                                }
                                Spacer()
                                if let link = meeting.documentLink, let url = URL(string: link) {
                                    Button("Deschide") { NSWorkspace.shared.open(url) }.buttonStyle(MackySecondaryPillStyle())
                                } else {
                                    Button("Încearcă din nou") { manager.retry(meeting.id) }.buttonStyle(MackySecondaryPillStyle())
                                }
                            }
                            .mackyCard(cornerRadius: 16, padding: 12)
                        }
                    }
                }
            }
        }
        .padding(28)
    }
}

// MARK: - Usage

struct UsageView: View {
    @ObservedObject var usageStore: UsageStore

    private struct DayCost: Identifiable {
        let date: Date
        let cost: Double
        var id: Date { date }
    }

    private struct PurposeCost: Identifiable {
        let index: Int
        let purpose: UsagePurpose
        let cost: Double
        var id: String { purpose.rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Consum OpenRouter").font(MackyDesign.rounded(24, .bold)).foregroundColor(MackyDesign.textPrimary)
                    Spacer()
                    Button { Task { await usageStore.refresh() } } label: { Label("Actualizează", systemImage: "arrow.clockwise") }
                        .buttonStyle(MackySecondaryPillStyle())
                    Button("Adaugă credit") { NSWorkspace.shared.open(URL(string: "https://openrouter.ai/settings/credits")!) }
                        .buttonStyle(MackyPrimaryPillStyle())
                }
                if let errorText = usageStore.errorText {
                    Text(errorText).font(MackyDesign.rounded(12)).foregroundColor(.orange)
                }

                HStack(spacing: 12) {
                    statTile(title: "Credit rămas", value: usageStore.remainingCredit.map(UsageStore.format) ?? "—",
                             detail: usageStore.estimatedDaysLeft.map { "≈ \($0) zile la ritmul actual" } ?? (usageStore.totalPurchasedCredit.map { "din \(UsageStore.format($0)) cumpărate" } ?? ""),
                             color: (usageStore.remainingCredit ?? 99) < UsageStore.lowBalanceThreshold ? MackyDesign.blush : MackyDesign.mint)
                    statTile(title: "Azi", value: UsageStore.format(usageStore.keyUsage?.dailyUsage ?? usageStore.ledger.totalCost(lastDays: 1)),
                             detail: "\(usageStore.ledger.requestCount(lastDays: 1)) cereri Macky", color: MackyDesign.butter)
                    statTile(title: "Ultimele 7 zile", value: UsageStore.format(usageStore.keyUsage?.weeklyUsage ?? usageStore.ledger.totalCost(lastDays: 7)),
                             detail: "\(usageStore.ledger.requestCount(lastDays: 7)) cereri", color: MackyDesign.periwinkle)
                    statTile(title: "Luna asta", value: UsageStore.format(usageStore.keyUsage?.monthlyUsage ?? usageStore.ledger.totalCostThisMonth()),
                             detail: "", color: MackyDesign.blush)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Ultimele 30 de zile").font(MackyDesign.rounded(15, .semibold)).foregroundColor(MackyDesign.textPrimary)
                    Chart(usageStore.ledger.dailyTotals(lastDays: 30).map { DayCost(date: $0.date, cost: $0.cost) }) { day in
                        BarMark(x: .value("Zi", day.date, unit: .day), y: .value("Cost", day.cost))
                            .foregroundStyle(MackyDesign.primaryButtonGradient)
                            .cornerRadius(3)
                    }
                    .chartYAxis {
                        AxisMarks { value in
                            AxisGridLine().foregroundStyle(MackyDesign.hairline)
                            AxisValueLabel { if let cost = value.as(Double.self) { Text(UsageStore.format(cost)) } }
                        }
                    }
                    .frame(height: 170)
                }
                .mackyCard(cornerRadius: 20, padding: 16)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Pe ce s-au dus (30 de zile)").font(MackyDesign.rounded(15, .semibold)).foregroundColor(MackyDesign.textPrimary)
                    let byPurpose = usageStore.ledger.costByPurpose(lastDays: 30).enumerated().map { PurposeCost(index: $0.offset, purpose: $0.element.purpose, cost: $0.element.cost) }
                    let maximum = max(byPurpose.map(\.cost).max() ?? 1, 0.000_001)
                    if byPurpose.isEmpty {
                        Text("Încă nimic înregistrat. Apare după primele cereri.").font(MackyDesign.rounded(12)).foregroundColor(MackyDesign.textSecondary)
                    }
                    ForEach(byPurpose) { entry in
                        HStack(spacing: 10) {
                            Text(entry.purpose.displayName).font(MackyDesign.rounded(13)).foregroundColor(MackyDesign.textPrimary)
                                .frame(width: 170, alignment: .leading)
                            GeometryReader { proxy in
                                Capsule()
                                    .fill(MackyDesign.pastels[entry.index % MackyDesign.pastels.count])
                                    .frame(width: max(6, proxy.size.width * entry.cost / maximum))
                            }
                            .frame(height: 10)
                            Text(UsageStore.format(entry.cost)).font(MackyDesign.rounded(13, .semibold)).foregroundColor(MackyDesign.textPrimary)
                                .monospacedDigit()
                                .frame(width: 70, alignment: .trailing)
                        }
                    }
                }
                .mackyCard(cornerRadius: 20, padding: 16)

                Text("Creditul și consumul zilnic/săptămânal/lunar vin direct de la OpenRouter (includ și alte aplicații care folosesc aceeași cheie). Împărțirea pe categorii e ținută de Macky pe Mac-ul tău."
                     + (usageStore.lastRefreshDate.map { " Actualizat la \($0.formatted(date: .omitted, time: .shortened))." } ?? ""))
                    .font(MackyDesign.rounded(11))
                    .foregroundColor(MackyDesign.textSecondary)
            }
            .padding(28)
        }
    }

    private func statTile(title: String, value: String, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(MackyDesign.rounded(12, .semibold)).foregroundColor(.black.opacity(0.55))
            Text(value).font(MackyDesign.rounded(24, .bold)).foregroundColor(.black.opacity(0.85)).monospacedDigit()
            Text(detail).font(MackyDesign.rounded(11)).foregroundColor(.black.opacity(0.5)).lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(color))
    }
}
