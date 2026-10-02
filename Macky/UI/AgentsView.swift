import AppKit
import MackyCore
import SwiftUI

/// The "Agenți" section: the user's team of agents (on demand or on a schedule), each with its history and documents,
/// plus quick one-off background tasks.
struct AgentsSectionView: View {
    @ObservedObject var agentStore: AgentStore
    @ObservedObject var agentManager: BackgroundAgentManager
    @ObservedObject var skillLibrary: SkillLibrary
    @ObservedObject var googleAccountManager: GoogleAccountManager
    @Binding var selectedAgentIdentifier: UUID?
    var compact = false

    @State private var editedAgent: AgentDefinition?
    @State private var quickGoal = ""

    var body: some View {
        Group {
            if let identifier = selectedAgentIdentifier, let agent = agentStore.agents.first(where: { $0.id == identifier }) {
                AgentDetailView(agent: agent, agentStore: agentStore, googleAccountManager: googleAccountManager,
                                onEdit: { editedAgent = agent }, onBack: { selectedAgentIdentifier = nil })
            } else {
                teamView
            }
        }
        .padding(compact ? 18 : 28)
        .sheet(item: $editedAgent) { agent in
            AgentEditorView(initialAgent: agent, skillNames: skillLibrary.skills.map(\.name),
                            canWriteToDrive: googleAccountManager.isConnected && googleAccountManager.canWriteToDriveFolders) { saved in
                agentStore.upsert(saved)
            }
        }
    }

    private var teamView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Agenți").font(MackyDesign.rounded(compact ? 20 : 24, .bold)).foregroundColor(MackyDesign.textPrimary)
                        Text("Echipa ta: lucrează singuri, în fundal, la cerere sau la ora lor. Fără ferestre și fără taburi peste tine.")
                            .font(MackyDesign.rounded(13)).foregroundColor(MackyDesign.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button {
                        editedAgent = AgentDefinition(name: "", instructions: "")
                    } label: { Label("Agent nou", systemImage: "plus") }
                        .buttonStyle(MackyPrimaryPillStyle())
                }

                ForEach(agentStore.agents) { agent in
                    AgentCard(agent: agent, isRunning: agentStore.isRunning(agent.id),
                              onOpen: { selectedAgentIdentifier = agent.id },
                              onRun: { agentStore.run(agent.id) },
                              onToggle: { agentStore.setEnabled($0, for: agent.id) })
                }

                Text("SARCINI RAPIDE")
                    .font(MackyDesign.rounded(11, .bold)).tracking(1.3).foregroundColor(MackyDesign.textSecondary)
                    .padding(.top, 8)
                HStack(spacing: 10) {
                    TextField("ex. Caută cele mai bune 5 CRM-uri pentru agenții mici și fă o comparație", text: $quickGoal)
                        .textFieldStyle(.plain)
                        .font(MackyDesign.rounded(13))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(MackyDesign.surface))
                        .overlay(Capsule().stroke(MackyDesign.hairline, lineWidth: 1))
                        .onSubmit(startQuickTask)
                    Button(action: startQuickTask) { Image(systemName: "play.fill") }
                        .buttonStyle(MackySecondaryPillStyle())
                        .disabled(quickGoal.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !agentManager.jobs.isEmpty {
                    BackgroundJobsView(agentManager: agentManager)
                }
            }
        }
    }

    private func startQuickTask() {
        let goal = quickGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else { return }
        agentManager.start(goal: goal)
        quickGoal = ""
    }
}

// MARK: - Card

private struct AgentCard: View {
    let agent: AgentDefinition
    let isRunning: Bool
    let onOpen: () -> Void
    let onRun: () -> Void
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            MackyMascotView(mood: isRunning ? .thinking : .idle, size: 44, colors: MascotPalette.peach)
            VStack(alignment: .leading, spacing: 4) {
                Text(agent.name).font(MackyDesign.rounded(15, .bold)).foregroundColor(MackyDesign.textPrimary)
                Text(agent.modeDescription + (agent.skillName.isEmpty ? "" : " · skill \(agent.skillName)"))
                    .font(MackyDesign.rounded(12)).foregroundColor(MackyDesign.textSecondary)
                AgentStatusLine(agent: agent, isRunning: isRunning)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 8) {
                Toggle("", isOn: Binding(get: { agent.isEnabled }, set: onToggle))
                    .labelsHidden()
                    .toggleStyle(MackyToggleStyle())
                    .help(agent.isEnabled ? "Activ" : "Oprit: nu mai rulează singur")
                Button(isRunning ? "Lucrează…" : "Rulează acum", action: onRun)
                    .buttonStyle(MackySecondaryPillStyle())
                    .disabled(isRunning)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.055))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(MackyDesign.hairline, lineWidth: 1))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .pointingHandOnHover()
    }
}

private struct AgentStatusLine: View {
    let agent: AgentDefinition
    let isRunning: Bool

    var body: some View {
        if isRunning {
            Label("Lucrează acum, în fundal…", systemImage: "hourglass")
                .font(MackyDesign.rounded(12, .semibold)).foregroundColor(MascotPalette.peach[0])
        } else if let run = agent.runs.first {
            HStack(spacing: 6) {
                Image(systemName: run.status == .succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(run.status == .succeeded ? MackyDesign.accent : .orange)
                Text(run.startedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute()) + " · " + run.summary)
                    .lineLimit(1)
            }
            .font(MackyDesign.rounded(12)).foregroundColor(MackyDesign.textSecondary)
        } else {
            Text(agent.isEnabled ? "N-a rulat încă." : "Oprit.")
                .font(MackyDesign.rounded(12)).foregroundColor(MackyDesign.textSecondary)
        }
    }
}

// MARK: - Detail

private struct AgentDetailView: View {
    let agent: AgentDefinition
    @ObservedObject var agentStore: AgentStore
    @ObservedObject var googleAccountManager: GoogleAccountManager
    let onEdit: () -> Void
    let onBack: () -> Void

    @State private var extraRequest = ""
    @State private var isConfirmingDeletion = false

    private var isRunning: Bool { agentStore.isRunning(agent.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button(action: onBack) { Label("Toți agenții", systemImage: "chevron.left") }
                    .buttonStyle(.plain)
                    .font(MackyDesign.rounded(13, .semibold))
                    .foregroundColor(MackyDesign.textSecondary)
                    .pointingHandOnHover()

                HStack(alignment: .center, spacing: 14) {
                    MackyMascotView(mood: isRunning ? .thinking : .happy, size: 54, colors: MascotPalette.peach)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(agent.name).font(MackyDesign.rounded(22, .bold)).foregroundColor(MackyDesign.textPrimary)
                        Text(agent.modeDescription).font(MackyDesign.rounded(13)).foregroundColor(MackyDesign.textSecondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { agent.isEnabled }, set: { agentStore.setEnabled($0, for: agent.id) }))
                        .labelsHidden()
                        .toggleStyle(MackyToggleStyle())
                    Button(action: onEdit) { Label("Modifică", systemImage: "pencil") }
                        .buttonStyle(MackySecondaryPillStyle())
                }

                if let warning {
                    SettingsMessage(text: "✗ " + warning)
                }

                SettingsGroup(title: "Rulează acum") {
                    SettingsBlock {
                        TextField("Opțional: ceva în plus doar pentru rularea asta (ex. „pune accent pe ADN Financiar”)", text: $extraRequest)
                            .mackyField()
                        HStack {
                            if isRunning {
                                Label("Lucrează în fundal. Poți închide fereastra.", systemImage: "hourglass")
                                    .font(MackyDesign.rounded(12, .semibold)).foregroundColor(MascotPalette.peach[0])
                                Spacer()
                                Button("Oprește") { agentStore.stop(agent.id) }.buttonStyle(MackySecondaryPillStyle())
                            } else {
                                Spacer()
                                Button {
                                    agentStore.run(agent.id, extraRequest: extraRequest)
                                    extraRequest = ""
                                } label: { Label("Rulează", systemImage: "play.fill") }
                                    .buttonStyle(MackyPrimaryPillStyle())
                            }
                        }
                    }
                }

                SettingsGroup(title: "Instrucțiuni") {
                    SettingsBlock {
                        Text(agent.instructions)
                            .font(MackyDesign.rounded(13))
                            .foregroundColor(MackyDesign.textPrimary.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        if !agent.skillName.isEmpty || !agent.driveFolder.isEmpty {
                            Text([agent.skillName.isEmpty ? nil : "Skill: \(agent.skillName)",
                                  agent.driveFolder.isEmpty ? "Rezultatul: Documents/Macky/Agenti" : "Rezultatul: Google Doc în folderul din Drive"]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(MackyDesign.rounded(12)).foregroundColor(MackyDesign.textSecondary)
                        }
                    }
                }

                SettingsGroup(title: "Rulări (\(agent.runs.count))") {
                    if agent.runs.isEmpty {
                        SettingsBlock { SettingsMessage(text: "N-a rulat încă.") }
                    }
                    ForEach(Array(agent.runs.enumerated()), id: \.element.id) { index, run in
                        if index > 0 { SettingsDivider() }
                        AgentRunRow(run: run)
                    }
                }

                HStack {
                    Spacer()
                    Button("Șterge agentul…", role: .destructive) { isConfirmingDeletion = true }
                        .buttonStyle(.plain)
                        .font(MackyDesign.rounded(12))
                        .foregroundColor(.orange)
                }
            }
        }
        .confirmationDialog("Ștergi agentul „\(agent.name)”?", isPresented: $isConfirmingDeletion) {
            Button("Șterge", role: .destructive) {
                agentStore.delete(agent.id)
                onBack()
            }
        } message: {
            Text("Documentele deja create rămân în Drive.")
        }
    }

    private var warning: String? {
        guard !agent.driveFolder.isEmpty else { return nil }
        if !googleAccountManager.isConnected {
            return "Google nu e conectat: conectează-l în Setări → Conexiuni → Gmail și Drive, ca agentul să poată salva în Drive."
        }
        if !googleAccountManager.canWriteToDriveFolders {
            return "Macky are nevoie de permisiunea nouă de scriere în Drive: Setări → Conexiuni → Gmail și Drive → Deconectează, apoi Conectează din nou."
        }
        if AgentKit.driveFolderIdentifier(from: agent.driveFolder) == nil {
            return "Linkul folderului din Drive nu pare corect. Modifică agentul și pune linkul complet al folderului."
        }
        return nil
    }
}

private struct AgentRunRow: View {
    let run: AgentRun

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundColor(color).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(run.startedAt.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute()))
                    .font(MackyDesign.rounded(13, .semibold)).foregroundColor(MackyDesign.textPrimary)
                Text(run.summary.isEmpty ? (run.status == .running ? "Lucrează…" : "") : run.summary)
                    .font(MackyDesign.rounded(12)).foregroundColor(run.status == .failed ? .orange : MackyDesign.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if run.costInCredits > 0 {
                    Text(UsageStore.format(run.costInCredits)).font(MackyDesign.rounded(11)).foregroundColor(MackyDesign.textSecondary)
                }
            }
            Spacer()
            if let link = run.documentLink, let url = URL(string: link) {
                Button("Deschide") { NSWorkspace.shared.open(url) }.buttonStyle(MackySecondaryPillStyle())
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var icon: String {
        switch run.status {
        case .running: return "hourglass"
        case .succeeded: return "doc.text.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch run.status {
        case .running: return MascotPalette.peach[0]
        case .succeeded: return MackyDesign.accent
        case .failed: return .orange
        }
    }
}

// MARK: - Editor

struct AgentEditorView: View {
    @State private var draft: AgentDefinition
    let skillNames: [String]
    let canWriteToDrive: Bool
    let onSave: (AgentDefinition) -> Void
    @Environment(\.dismiss) private var dismiss

    init(initialAgent: AgentDefinition, skillNames: [String], canWriteToDrive: Bool, onSave: @escaping (AgentDefinition) -> Void) {
        _draft = State(initialValue: initialAgent)
        self.skillNames = skillNames
        self.canWriteToDrive = canWriteToDrive
        self.onSave = onSave
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: draft.schedule.hour, minute: draft.schedule.minute, second: 0, of: Date()) ?? Date() },
            set: { newValue in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                draft.schedule.hour = components.hour ?? 8
                draft.schedule.minute = components.minute ?? 0
            }
        )
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty && !draft.instructions.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(draft.name.isEmpty ? "Agent nou" : draft.name).font(MackyDesign.rounded(22, .bold)).foregroundColor(MackyDesign.textPrimary)

                    SettingsGroup(title: "Ce face") {
                        SettingsBlock {
                            TextField("Nume (ex. Romeo · unghiuri și hookuri)", text: $draft.name).mackyField()
                            Text("Instrucțiuni: ce să facă de fiecare dată, cu cuvintele tale")
                                .font(MackyDesign.rounded(12)).foregroundColor(MackyDesign.textSecondary)
                            TextEditor(text: $draft.instructions)
                                .font(MackyDesign.rounded(13))
                                .scrollContentBackground(.hidden)
                                .padding(8)
                                .frame(minHeight: 170)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.35)))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(MackyDesign.hairline, lineWidth: 1))
                        }
                        SettingsDivider()
                        SettingsRow(title: "Skill", subtitle: "Cunoștințele și vocea pe care le folosește.") {
                            Picker("", selection: $draft.skillName) {
                                Text("Fără skill").tag("")
                                ForEach(skillNames, id: \.self) { Text($0).tag($0) }
                                if !draft.skillName.isEmpty && !skillNames.contains(draft.skillName) {
                                    Text("\(draft.skillName) (negăsit)").tag(draft.skillName)
                                }
                            }
                            .settingsMenu()
                        }
                        SettingsDivider()
                        SettingsRow(title: "Poate căuta pe internet", subtitle: "Pentru agenți care au nevoie de informații actuale.") {
                            Toggle("", isOn: $draft.allowsWebResearch).labelsHidden()
                        }
                    }

                    SettingsGroup(title: "Când lucrează", footer: "Dacă Mac-ul doarme sau e închis la ora respectivă, agentul lucrează imediat ce îl deschizi, în aceeași zi.") {
                        SettingsRow(title: "Singur, la o oră fixă", subtitle: draft.schedule.isEnabled ? nil : "Oprit: rulează doar când îi ceri.") {
                            Toggle("", isOn: $draft.schedule.isEnabled).labelsHidden()
                        }
                        if draft.schedule.isEnabled {
                            SettingsDivider()
                            SettingsRow(title: "Ora") {
                                DatePicker("", selection: timeBinding, displayedComponents: .hourAndMinute).labelsHidden()
                            }
                            SettingsDivider()
                            SettingsBlock {
                                HStack(spacing: 6) {
                                    ForEach([(2, "Lu"), (3, "Ma"), (4, "Mi"), (5, "Jo"), (6, "Vi"), (7, "Sâ"), (1, "Du")], id: \.0) { weekday, name in
                                        let isOn = draft.schedule.weekdays.contains(weekday)
                                        Button(name) {
                                            if isOn { draft.schedule.weekdays.remove(weekday) } else { draft.schedule.weekdays.insert(weekday) }
                                        }
                                        .buttonStyle(.plain)
                                        .font(MackyDesign.rounded(12, .semibold))
                                        .foregroundColor(isOn ? Color.black : MackyDesign.textSecondary)
                                        .frame(width: 34, height: 28)
                                        .background(Capsule().fill(isOn ? AnyShapeStyle(MackyDesign.primaryButtonGradient) : AnyShapeStyle(MackyDesign.surface)))
                                    }
                                }
                            }
                        }
                    }

                    SettingsGroup(title: "Unde pune rezultatul",
                                  footer: canWriteToDrive || draft.driveFolder.isEmpty ? "Fără folder, documentul ajunge în Documents/Macky/Agenti."
                                  : "Pentru Drive, Macky are nevoie de permisiunea de scriere: Setări → Conexiuni → Gmail și Drive → Deconectează, apoi Conectează.") {
                        SettingsBlock {
                            TextField("Link folder Google Drive (opțional)", text: $draft.driveFolder).mackyField()
                            if !draft.driveFolder.isEmpty && AgentKit.driveFolderIdentifier(from: draft.driveFolder) == nil {
                                SettingsMessage(text: "✗ Linkul nu pare a fi al unui folder din Drive.")
                            }
                        }
                    }
                }
                .padding(24)
            }
            Divider().overlay(MackyDesign.hairline)
            HStack {
                Spacer()
                Button("Renunță") { dismiss() }
                    .buttonStyle(MackySecondaryPillStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Salvează") {
                    var saved = draft
                    saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    saved.driveFolder = saved.driveFolder.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(saved)
                    dismiss()
                }
                .buttonStyle(MackyPrimaryPillStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding(16)
        }
        .frame(width: 620, height: 680)
        .background(MackyDesign.windowBackground)
        .environment(\.colorScheme, .dark)
        .toggleStyle(MackyToggleStyle())
    }
}
