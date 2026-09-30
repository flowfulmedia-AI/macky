import MackyCore
import SwiftUI

/// The panel under the notch (or the menu bar icon): Macky's face, the answer, suggestions, and quick input.
struct CompanionPanelView: View {
    @ObservedObject var session: CompanionSession
    @ObservedObject var settings: AppSettings
    @ObservedObject var permissions: PermissionsManager
    @ObservedObject var apiKeyStore: OpenRouterAPIKeyStore
    @ObservedObject var modelCatalogStore: ModelCatalogStore
    @ObservedObject var agentManager: BackgroundAgentManager
    @ObservedObject var usageStore: UsageStore

    let suggestions: [SuggestionCatalog.Suggestion]
    let openHome: () -> Void
    let openSettings: () -> Void
    let openCalibration: () -> Void
    let openMemory: () -> Void
    let openHistory: () -> Void

    @State private var typedQuestion = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !apiKeyStore.hasAPIKey || !permissions.allPermissionsGranted {
                ScrollView {
                    OnboardingChecklistView(permissions: permissions, apiKeyStore: apiKeyStore, openSettings: openSettings)
                }
            } else {
                if let transcriberStatusText = session.transcriberStatusText {
                    Label(transcriberStatusText, systemImage: "arrow.down.circle")
                        .font(MackyDesign.rounded(11))
                        .foregroundColor(MackyDesign.textSecondary)
                }
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        if session.lastQuestionText.isEmpty && session.lastAnswerText.isEmpty {
                            emptyState
                        } else {
                            conversation
                        }
                        if !agentManager.jobs.isEmpty {
                            BackgroundJobsView(agentManager: agentManager)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: .infinity)
                modelSwitch
                inputRow
            }
            footer
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            MackyMascotView(mood: mascotMood, size: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text("Macky").font(MackyDesign.rounded(17, .bold)).foregroundColor(MackyDesign.textPrimary)
                Text(session.state.displayName)
                    .font(MackyDesign.rounded(11, .medium))
                    .foregroundColor(stateColor)
            }
            Spacer()
            creditPill
            Button(action: openHome) { Image(systemName: "square.grid.2x2") }
                .buttonStyle(MackyIconButtonStyle())
                .help("Deschide Macky")
            Button(action: openSettings) { Image(systemName: "gearshape") }
                .buttonStyle(MackyIconButtonStyle())
                .help("Setări")
        }
    }

    private var creditPill: some View {
        Button(action: openHome) {
            HStack(spacing: 5) {
                Circle()
                    .fill(creditColor)
                    .frame(width: 7, height: 7)
                Text(usageStore.remainingCredit.map(UsageStore.format) ?? "—")
                    .font(MackyDesign.rounded(12, .semibold))
                    .foregroundColor(MackyDesign.textPrimary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(MackyDesign.surface))
            .overlay(Capsule().stroke(MackyDesign.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Credit OpenRouter rămas · azi \(UsageStore.format(usageStore.ledger.totalCost(lastDays: 1)))")
        .pointingHandOnHover()
    }

    private var creditColor: Color {
        guard let remainingCredit = usageStore.remainingCredit else { return MackyDesign.textSecondary }
        return remainingCredit < UsageStore.lowBalanceThreshold ? .orange : MackyDesign.accent
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

    private var stateColor: Color {
        switch session.state {
        case .idle: return MackyDesign.textSecondary
        case .failed: return .orange
        default: return MackyDesign.accent
        }
    }

    // MARK: Content

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cu ce te ajut?")
                .font(MackyDesign.rounded(20, .bold))
                .foregroundColor(MackyDesign.textPrimary)
            Text("Ține \(settings.talkCombination.symbols) și vorbește, sau alege o idee:")
                .font(MackyDesign.rounded(13))
                .foregroundColor(MackyDesign.textSecondary)
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                    SuggestionCardView(
                        text: suggestion.text,
                        symbol: suggestion.symbol,
                        color: MackyDesign.pastels[index % MackyDesign.pastels.count],
                        tilt: [-2.0, 1.5, -1.0][index % 3]
                    ) {
                        session.ask(typedQuestion: suggestion.text)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private var conversation: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if !session.lastQuestionText.isEmpty {
                Text(session.lastQuestionText)
                    .font(MackyDesign.rounded(13, .medium))
                    .foregroundColor(MackyDesign.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(MackyDesign.surfaceStrong))
                    .frame(maxWidth: 300, alignment: .trailing)
                    .textSelection(.enabled)
            }
            if !session.lastAnswerText.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(session.lastAnswerText)
                        .font(MackyDesign.rounded(14))
                        .foregroundColor(MackyDesign.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) {
                        if let lastTimingSummary = session.lastTimingSummary {
                            Text(lastTimingSummary.replacingOccurrences(of: "Ultima cerere: ", with: ""))
                                .font(MackyDesign.rounded(10))
                                .foregroundColor(MackyDesign.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(session.lastAnswerText, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(MackyIconButtonStyle())
                            .help("Copiază răspunsul")
                        Button { session.forgetConversation() } label: { Image(systemName: "plus.bubble") }
                            .buttonStyle(MackyIconButtonStyle())
                            .help("Conversație nouă")
                    }
                }
                .mackyCard()
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var modelSwitch: some View {
        HStack(spacing: 6) {
            modelChip(title: "Rapid", symbol: "bolt.fill", isSelected: !settings.usePowerfulModel) { settings.usePowerfulModel = false }
            modelChip(title: "Puternic", symbol: "sparkles", isSelected: settings.usePowerfulModel) { settings.usePowerfulModel = true }
            Text(activeModelDescription)
                .font(MackyDesign.rounded(10))
                .foregroundColor(MackyDesign.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func modelChip(title: String, symbol: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(MackyDesign.rounded(12, .semibold))
                .foregroundColor(isSelected ? Color(red: 0.08, green: 0.10, blue: 0.25) : MackyDesign.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(isSelected ? AnyShapeStyle(MackyDesign.primaryButtonGradient) : AnyShapeStyle(MackyDesign.surface)))
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
    }

    private var activeModelDescription: String {
        let identifier = settings.activeModelIdentifier
        guard !identifier.isEmpty else { return "Alege un model în Setări" }
        return modelCatalogStore.model(withIdentifier: identifier)?.name ?? identifier
    }

    // MARK: Input

    private var inputRow: some View {
        HStack(spacing: 8) {
            HoldToTalkButton(session: session, title: "Ține \(settings.talkCombination.symbols) ca să vorbești")
            HStack(spacing: 6) {
                Image(systemName: "keyboard").foregroundColor(MackyDesign.textSecondary)
                TextField("Scrie…", text: $typedQuestion)
                    .textFieldStyle(.plain)
                    .font(MackyDesign.rounded(13))
                    .onSubmit(submitTypedQuestion)
                if session.state.isBusy {
                    Button { session.stopEverything() } label: { Image(systemName: "stop.fill") }
                        .buttonStyle(.plain)
                        .foregroundColor(.orange)
                        .help("Oprește")
                } else if !typedQuestion.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button(action: submitTypedQuestion) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 17)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(MackyDesign.primaryButtonGradient)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Capsule().fill(MackyDesign.surface))
            .overlay(Capsule().stroke(MackyDesign.hairline, lineWidth: 1))
        }
    }

    private func submitTypedQuestion() {
        let question = typedQuestion
        typedQuestion = ""
        session.ask(typedQuestion: question)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            footerButton("Memorie", systemImage: "brain", action: openMemory)
            footerButton("Istoric", systemImage: "clock.arrow.circlepath", action: openHistory)
            Spacer()
            Text(sessionCostText)
                .font(MackyDesign.rounded(10))
                .foregroundColor(MackyDesign.textSecondary)
            footerButton("Calibrare", systemImage: "scope", iconOnly: true, action: openCalibration)
                .help("Calibrare")
            footerButton("Ieșire", systemImage: "power", iconOnly: true) { NSApp.terminate(nil) }
                .help("Ieșire din Macky")
        }
    }

    private var sessionCostText: String {
        let tracker = session.costTracker
        guard tracker.requestCount > 0 else { return "" }
        return "sesiune \(SessionCostTracker.formatCredits(tracker.totalCostInCredits))"
    }

    private func footerButton(_ title: String, systemImage: String, iconOnly: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if iconOnly {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .accessibilityLabel(title)
            } else {
                Label(title, systemImage: systemImage)
                    .font(MackyDesign.rounded(11, .medium))
            }
        }
        .buttonStyle(.plain)
        .foregroundColor(MackyDesign.textSecondary)
        .pointingHandOnHover()
    }
}

/// The glowing pill: hold the mouse button on it to talk, like holding the shortcut.
struct HoldToTalkButton: View {
    @ObservedObject var session: CompanionSession
    let title: String
    @State private var isHolding = false

    var body: some View {
        Label(isHolding ? "Eliberează ca să trimiți" : title, systemImage: "mic.fill")
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
            .modifier(PrimaryPillLook(isActive: isHolding || session.state == .listening))
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isHolding else { return }
                        isHolding = true
                        session.handle(.pressed(.talk))
                    }
                    .onEnded { _ in
                        isHolding = false
                        session.handle(.released(.talk))
                    }
            )
            .pointingHandOnHover()
    }
}

/// The primary pill look for views that are not buttons.
struct PrimaryPillLook: ViewModifier {
    var isActive: Bool

    func body(content: Content) -> some View {
        content
            .font(MackyDesign.rounded(14, .semibold))
            .foregroundColor(Color(red: 0.08, green: 0.10, blue: 0.25))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(MackyDesign.primaryButtonGradient)
                    .overlay(Capsule().stroke(MackyDesign.primaryButtonGlow.opacity(0.9), lineWidth: 1.5))
            )
            .shadow(color: MackyDesign.primaryButtonGlow.opacity(isActive ? 0.95 : 0.45), radius: isActive ? 16 : 8)
            .scaleEffect(isActive ? 1.02 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isActive)
    }
}

/// First-run checklist: the API key and the four permissions, each with a button.
struct OnboardingChecklistView: View {
    @ObservedObject var permissions: PermissionsManager
    @ObservedObject var apiKeyStore: OpenRouterAPIKeyStore
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hai să te pregătim")
                .font(MackyDesign.rounded(17, .bold))

            checklistRow(
                isDone: apiKeyStore.hasAPIKey,
                title: "Cheia OpenRouter",
                explanation: "Se păstrează doar pe Mac-ul tău, într-un fișier privat.",
                buttonTitle: "Adaugă",
                action: openSettings
            )

            ForEach(MackyPermission.allCases) { permission in
                checklistRow(
                    isDone: permissions.isGranted(permission),
                    title: permission.title,
                    explanation: permission.explanation,
                    buttonTitle: "Permite",
                    action: { permissions.request(permission) }
                )
            }

            if permissions.needsRestartForScreenRecording {
                HStack {
                    Text("Ai permis înregistrarea ecranului? macOS cere repornirea aplicației.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("Repornește") { PermissionsManager.relaunchApplication() }
                        .controlSize(.small)
                }
            }
        }
        .mackyCard()
    }

    private func checklistRow(isDone: Bool, title: String, explanation: String, buttonTitle: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isDone ? MackyDesign.accent : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                Text(explanation).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if !isDone {
                Button(buttonTitle, action: action)
                    .controlSize(.small)
                    .pointingHandOnHover()
            }
        }
    }
}

/// The latest background agent jobs: what they are doing now, or what they found.
struct BackgroundJobsView: View {
    @ObservedObject var agentManager: BackgroundAgentManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("În fundal").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                Spacer()
                if agentManager.jobs.contains(where: { !$0.isRunning }) {
                    Button("Curăță") { agentManager.removeFinishedJobs() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .pointingHandOnHover()
                }
            }
            ForEach(agentManager.jobs.prefix(3)) { job in
                jobRow(job)
            }
        }
        .mackyCard()
    }

    private func jobRow(_ job: BackgroundAgentManager.Job) -> some View {
        HStack(alignment: .top, spacing: 8) {
            statusIcon(for: job)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.goal)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(detailText(for: job))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                if case .finished(_, let savedFilePath?) = job.status {
                    Button("Deschide rezultatul") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: savedFilePath))
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .pointingHandOnHover()
                }
            }
            Spacer(minLength: 0)
            if job.isRunning {
                Button {
                    agentManager.cancel(job.id)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Oprește agentul")
                .pointingHandOnHover()
            }
        }
    }

    @ViewBuilder
    private func statusIcon(for job: BackgroundAgentManager.Job) -> some View {
        switch job.status {
        case .running:
            ProgressView().controlSize(.small)
        case .finished:
            Image(systemName: "checkmark.circle.fill").foregroundColor(MackyDesign.accent)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
        case .cancelled:
            Image(systemName: "stop.circle").foregroundColor(.secondary)
        }
    }

    private func detailText(for job: BackgroundAgentManager.Job) -> String {
        let costText = job.costInCredits > 0 ? " · \(SessionCostTracker.formatCredits(job.costInCredits))" : ""
        switch job.status {
        case .running(let progress): return progress + costText
        case .finished(let summary, _): return summary + costText
        case .failed(let reason): return reason
        case .cancelled: return "Oprit."
        }
    }
}
