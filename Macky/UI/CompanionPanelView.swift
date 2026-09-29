import MackyCore
import SwiftUI

/// Content of the menu bar panel: status, onboarding, model switch, last answer, typed questions.
struct CompanionPanelView: View {
    @ObservedObject var session: CompanionSession
    @ObservedObject var settings: AppSettings
    @ObservedObject var permissions: PermissionsManager
    @ObservedObject var apiKeyStore: OpenRouterAPIKeyStore
    @ObservedObject var modelCatalogStore: ModelCatalogStore
    @ObservedObject var agentManager: BackgroundAgentManager

    let openSettings: () -> Void
    let openCalibration: () -> Void

    @State private var typedQuestion = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !apiKeyStore.hasAPIKey || !permissions.allPermissionsGranted {
                OnboardingChecklistView(permissions: permissions, apiKeyStore: apiKeyStore, openSettings: openSettings)
            } else {
                hotkeyHints
            }

            if let transcriberStatusText = session.transcriberStatusText {
                Label(transcriberStatusText, systemImage: "arrow.down.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            modelSwitch
            if !agentManager.jobs.isEmpty {
                BackgroundJobsView(agentManager: agentManager)
            }
            conversationCard
            questionField
            Spacer(minLength: 0)
            footer
        }
        .padding(16)
    }

    private var header: some View {
        HStack(spacing: 10) {
            MackyCursorShape()
                .fill(MackyDesign.accentGradient)
                .frame(width: 20, height: 20)
            Text("Macky")
                .font(.system(size: 17, weight: .bold, design: .rounded))
            Spacer()
            Text(session.state.displayName)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(stateColor.opacity(0.2)))
                .foregroundColor(stateColor)
        }
    }

    private var stateColor: Color {
        switch session.state {
        case .idle: return .secondary
        case .failed: return .orange
        default: return MackyDesign.accent
        }
    }

    private var hotkeyHints: some View {
        VStack(alignment: .leading, spacing: 4) {
            hintRow(symbols: settings.talkCombination.symbols, text: "ține apăsat și întreabă ce vezi pe ecran")
            if let dictationCombination = settings.dictationCombination {
                hintRow(symbols: dictationCombination.symbols, text: "ține apăsat și dictează text în orice aplicație")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: MackyDesign.cornerRadius).fill(MackyDesign.cardBackground))
    }

    private func hintRow(symbols: String, text: String) -> some View {
        HStack(spacing: 8) {
            Text(symbols)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.1)))
            Text(text)
                .font(.callout)
                .foregroundColor(.secondary)
        }
    }

    private var modelSwitch: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("", selection: $settings.usePowerfulModel) {
                Text("Rapid").tag(false)
                Text("Puternic").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(activeModelDescription)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var activeModelDescription: String {
        let identifier = settings.activeModelIdentifier
        guard !identifier.isEmpty else { return "Niciun model ales — deschide Setări" }
        return modelCatalogStore.model(withIdentifier: identifier)?.name ?? identifier
    }

    private var conversationCard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if session.lastQuestionText.isEmpty && session.lastAnswerText.isEmpty {
                    Text("Întreabă orice despre ce e pe ecran: „Unde export video aici?”, „Ce înseamnă eroarea asta?”, „Cum schimb fontul?”")
                        .font(.callout)
                        .foregroundColor(.secondary)
                } else {
                    if !session.lastQuestionText.isEmpty {
                        Text(session.lastQuestionText)
                            .font(.callout.weight(.semibold))
                            .textSelection(.enabled)
                    }
                    if !session.lastAnswerText.isEmpty {
                        Text(session.lastAnswerText)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: MackyDesign.cornerRadius).fill(MackyDesign.cardBackground))
    }

    private var questionField: some View {
        HStack(spacing: 8) {
            TextField("Sau scrie o întrebare…", text: $typedQuestion)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submitTypedQuestion)
            Button(action: submitTypedQuestion) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(MackyDesign.accentGradient)
            }
            .buttonStyle(.plain)
            .disabled(typedQuestion.trimmingCharacters(in: .whitespaces).isEmpty)
            .pointingHandOnHover()
            if session.state.isBusy {
                Button(action: { session.stopEverything() }) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.orange)
                }
                .buttonStyle(.plain)
                .help("Oprește")
                .pointingHandOnHover()
            }
        }
    }

    private func submitTypedQuestion() {
        let question = typedQuestion
        typedQuestion = ""
        session.ask(typedQuestion: question)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(costSummary)
                .font(.caption)
                .foregroundColor(.secondary)
            if let lastTimingSummary = session.lastTimingSummary {
                Text(lastTimingSummary)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 14) {
                footerButton("Setări", systemImage: "gearshape", action: openSettings)
                footerButton("Calibrare", systemImage: "scope", action: openCalibration)
                footerButton("Uită", systemImage: "arrow.counterclockwise", action: { session.forgetConversation() })
                    .help("Începe o conversație nouă")
                Spacer()
                footerButton("Ieșire", systemImage: "power") { NSApp.terminate(nil) }
            }
        }
    }

    private var costSummary: String {
        let tracker = session.costTracker
        guard tracker.requestCount > 0 else { return "Sesiune: nicio cerere încă" }
        var summary = "Sesiune: \(SessionCostTracker.formatCredits(tracker.totalCostInCredits)) · \(tracker.requestCount) cereri"
        if let lastCost = tracker.lastRequestCostInCredits {
            summary += " · ultima \(SessionCostTracker.formatCredits(lastCost))"
        }
        return summary
    }

    private func footerButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .pointingHandOnHover()
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
                .font(.headline)

            checklistRow(
                isDone: apiKeyStore.hasAPIKey,
                title: "Cheia OpenRouter",
                explanation: "Se păstrează în Keychain, doar pe Mac-ul tău.",
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
        .padding(10)
        .background(RoundedRectangle(cornerRadius: MackyDesign.cornerRadius).fill(MackyDesign.cardBackground))
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
        .padding(10)
        .background(RoundedRectangle(cornerRadius: MackyDesign.cornerRadius).fill(MackyDesign.cardBackground))
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
