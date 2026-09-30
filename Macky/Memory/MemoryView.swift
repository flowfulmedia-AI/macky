import MackyCore
import SwiftUI

/// Everything Macky knows about the user, editable: memories, the profile, learned procedures, and switches.
struct MemoryView: View {
    @ObservedObject var memoryManager: MemoryManager
    @ObservedObject var settings: AppSettings
    @State private var tab: Tab = .items

    enum Tab: String, CaseIterable, Identifiable {
        case items, profile, procedures, settings
        var id: String { rawValue }
        var title: String {
            switch self {
            case .items: return "Amintiri"
            case .profile: return "Profil"
            case .procedures: return "Proceduri învățate"
            case .settings: return "Setări"
            }
        }
        var symbol: String {
            switch self {
            case .items: return "brain"
            case .profile: return "person.crop.circle"
            case .procedures: return "bolt"
            case .settings: return "slider.horizontal.3"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                MackyMascotView(mood: .happy, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Memoria lui Macky").font(MackyDesign.rounded(22, .bold)).foregroundColor(MackyDesign.textPrimary)
                    Text("Ce știe despre tine, ce a învățat și cum folosește memoria.")
                        .font(MackyDesign.rounded(13))
                        .foregroundColor(MackyDesign.textSecondary)
                }
                Spacer()
            }
            HStack(spacing: 6) {
                ForEach(Tab.allCases) { item in
                    Button {
                        tab = item
                    } label: {
                        Label(item.title, systemImage: item.symbol)
                            .font(MackyDesign.rounded(13, .semibold))
                            .foregroundColor(tab == item ? MackyDesign.textPrimary : MackyDesign.textSecondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(tab == item ? MackyDesign.surfaceStrong : Color.clear))
                            .overlay(Capsule().stroke(tab == item ? MackyDesign.hairline : Color.clear, lineWidth: 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                }
                Spacer()
            }
            .padding(4)
            .background(Capsule().fill(MackyDesign.surface))

            Group {
                switch tab {
                case .items: MemoryItemsTab(memoryManager: memoryManager)
                case .profile: MemoryProfileTab(memoryManager: memoryManager)
                case .procedures: ProceduresTab(memoryManager: memoryManager)
                case .settings: MemorySettingsTab(memoryManager: memoryManager, settings: settings)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 28)
        .padding(.top, 38)
        .padding(.bottom, 20)
        .background(MackyDesign.windowBackground)
        .environment(\.colorScheme, .dark)
        .toggleStyle(MackyToggleStyle())
        .frame(minWidth: 640, minHeight: 480)
    }
}

private struct MemoryItemsTab: View {
    @ObservedObject var memoryManager: MemoryManager
    @State private var searchText = ""
    @State private var kindFilter: MemoryKind?
    @State private var editedItem: MemoryItem?
    @State private var isAddingItem = false

    private var visibleItems: [MemoryItem] {
        var result = memoryManager.items
        if let kindFilter { result = result.filter { $0.kind == kindFilter } }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            let foldedQuery = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            result = result.filter {
                $0.searchableText.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(foldedQuery)
            }
        }
        return result.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.updatedAt > $1.updatedAt
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundColor(MackyDesign.textSecondary)
                    TextField("Caută în memorie…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(MackyDesign.rounded(13))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.35)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(MackyDesign.hairline, lineWidth: 1))
                .frame(maxWidth: .infinity)
                Picker("", selection: $kindFilter) {
                    Text("Toate").tag(MemoryKind?.none)
                    ForEach(MemoryKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(MemoryKind?.some(kind))
                    }
                }
                .settingsMenu()
                Button {
                    isAddingItem = true
                } label: {
                    Label("Adaugă", systemImage: "plus")
                }
                .buttonStyle(MackyPrimaryPillStyle())
            }
            if memoryManager.items.isEmpty {
                Spacer()
                Text("Macky nu ține minte nimic încă. Învață singur din conversații, sau spune-i „ține minte că…”. Poți adăuga și tu aici lucruri: clienți, unde sunt fișierele, preferințe.")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(visibleItems) { item in
                            row(for: item)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(Color.white.opacity(0.055))
                                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(MackyDesign.hairline, lineWidth: 1))
                                )
                        }
                    }
                }
            }
            Text("\(memoryManager.items.count) amintiri · Macky primește doar cele relevante pentru fiecare cerere, ca să coste puțin.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .sheet(item: $editedItem) { item in
            MemoryItemEditor(title: "Editează amintirea", initialItem: item) { updatedItem in
                memoryManager.update(updatedItem)
            }
        }
        .sheet(isPresented: $isAddingItem) {
            MemoryItemEditor(title: "Amintire nouă", initialItem: MemoryItem(kind: .person, subject: "", content: "", source: .user)) { newItem in
                memoryManager.add(kind: newItem.kind, subject: newItem.subject, content: newItem.content, isPinned: newItem.isPinned)
            }
        }
    }

    private func row(for item: MemoryItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if item.isPinned {
                        Image(systemName: "pin.fill").font(.caption).foregroundColor(MackyDesign.accent)
                    }
                    Text(item.subject).font(MackyDesign.rounded(14, .semibold)).foregroundColor(MackyDesign.textPrimary)
                    Text(item.kind.displayName)
                        .font(MackyDesign.rounded(11, .semibold))
                        .foregroundColor(MackyDesign.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(MackyDesign.surfaceStrong))
                }
                Text(item.content)
                    .font(MackyDesign.rounded(13))
                    .foregroundColor(MackyDesign.textPrimary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(detailLine(for: item))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                var pinnedItem = item
                pinnedItem.isPinned.toggle()
                memoryManager.update(pinnedItem)
            } label: {
                Image(systemName: item.isPinned ? "pin.slash" : "pin")
            }
            .buttonStyle(.borderless)
            .help(item.isPinned ? "Nu mai trimite mereu" : "Trimite mereu modelului")
            Button { editedItem = item } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
                .help("Editează")
            Button { memoryManager.delete(item.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Șterge")
        }
        .padding(.vertical, 3)
    }

    private func detailLine(for item: MemoryItem) -> String {
        let source: String
        switch item.source {
        case .user: source = "de la tine"
        case .learned: source = "învățat singur"
        case .imported: source = "importat"
        }
        let date = item.updatedAt.formatted(date: .abbreviated, time: .omitted)
        return "\(source) · \(date) · folosit de \(item.useCount) ori"
    }
}

private struct MemoryItemEditor: View {
    let title: String
    @State var item: MemoryItem
    let onSave: (MemoryItem) -> Void
    @Environment(\.dismiss) private var dismiss

    init(title: String, initialItem: MemoryItem, onSave: @escaping (MemoryItem) -> Void) {
        self.title = title
        self._item = State(initialValue: initialItem)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Picker("Tip", selection: $item.kind) {
                ForEach(MemoryKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            TextField("Titlu (ex. numele clientului)", text: $item.subject)
                .textFieldStyle(.roundedBorder)
            Text("Ce să țină minte").font(.caption).foregroundColor(.secondary)
            TextEditor(text: $item.content)
                .font(.body)
                .frame(minHeight: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            Toggle("Trimite mereu modelului (fixată)", isOn: $item.isPinned)
            HStack {
                Spacer()
                Button("Renunță") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Salvează") {
                    onSave(item)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(item.subject.trimmingCharacters(in: .whitespaces).isEmpty || item.content.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

private struct MemoryProfileTab: View {
    @ObservedObject var memoryManager: MemoryManager
    @State private var draftSummary = ""
    @State private var hasLoadedDraft = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Profilul tău")
                .font(.headline)
            Text("Un rezumat scurt despre tine, trimis cu fiecare cerere. Macky îl rescrie singur o dată pe zi din ce a învățat; îl poți corecta oricând.")
                .font(.callout)
                .foregroundColor(.secondary)
            TextEditor(text: $draftSummary)
                .font(.body)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Text("\(draftSummary.count)/900 caractere")
                    .font(.caption)
                    .foregroundColor(draftSummary.count > 900 ? .red : .secondary)
                Spacer()
                Button("Reorganizează memoria acum") {
                    Task {
                        await memoryManager.consolidateIfDue(force: true)
                        draftSummary = memoryManager.profileSummary ?? ""
                    }
                }
                .disabled(memoryManager.isLearning || memoryManager.items.isEmpty)
                .help("Unește dublurile, șterge ce e depășit și rescrie profilul")
                Button("Salvează") { memoryManager.setProfileSummary(String(draftSummary.prefix(900))) }
                    .keyboardShortcut(.defaultAction)
            }
            if let lastConsolidationDate = memoryManager.lastConsolidationDate {
                Text("Ultima reorganizare: \(lastConsolidationDate.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .onAppear {
            guard !hasLoadedDraft else { return }
            hasLoadedDraft = true
            draftSummary = memoryManager.profileSummary ?? ""
        }
    }
}

private struct ProceduresTab: View {
    @ObservedObject var memoryManager: MemoryManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Când Macky rezolvă aceeași cerere la fel de două ori, o învață: data viitoare o face instant, fără model și fără cost (⚡). Dacă greșește și îl corectezi, o oprește singur.")
                .font(.callout)
                .foregroundColor(.secondary)
            if memoryManager.procedureBook.procedures.isEmpty {
                Spacer()
                Text("Nicio procedură învățată încă.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                LazyVStack(spacing: 8) {
                ForEach(memoryManager.procedureBook.procedures.sorted { $0.useCount > $1.useCount }) { procedure in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("„\(procedure.exampleRequest)”").fontWeight(.semibold)
                            Text(stepsDescription(procedure))
                                .font(.callout)
                                .foregroundColor(.secondary)
                            Text("folosită de \(procedure.useCount) ori" + (procedure.failureCount > 0 ? " · \(procedure.failureCount) greșeli" : ""))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { procedure.isEnabled },
                            set: { memoryManager.setProcedureEnabled($0, identifier: procedure.id) }
                        ))
                        .labelsHidden()
                        Button { memoryManager.deleteProcedure(procedure.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white.opacity(0.055))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(MackyDesign.hairline, lineWidth: 1))
                    )
                }
                }
                }
            }
            Text("În curs de învățare: \(memoryManager.procedureBook.candidates.count) cereri văzute o dată.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func stepsDescription(_ procedure: LearnedProcedure) -> String {
        procedure.toolCalls.enumerated().map { index, storedCall in
            ScreenAction(toolCall: storedCall.chatToolCall(identifier: "\(index)"))?.userFacingDescription ?? storedCall.name
        }.joined(separator: " → ")
    }
}

private struct MemorySettingsTab: View {
    @ObservedObject var memoryManager: MemoryManager
    @ObservedObject var settings: AppSettings
    @State private var isConfirmingDeletion = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SettingsGroup(title: "Memorie", footer: "Învățarea folosește modelul „Rapid”, rar și în loturi: de obicei sub un cent pe zi.") {
                    SettingsRow(title: "Memorie pe termen lung", subtitle: "Învață din conversații ce contează despre tine.") {
                        Toggle("", isOn: $settings.memoryEnabled).labelsHidden()
                    }
                    SettingsDivider()
                    SettingsRow(title: "Învață proceduri", subtitle: "Repetă instant cererile rezolvate de două ori.") {
                        Toggle("", isOn: $settings.learnedProceduresEnabled).labelsHidden()
                    }
                }
                SettingsGroup(title: "Stare") {
                    stateRow("Amintiri", "\(memoryManager.items.count)")
                    SettingsDivider()
                    stateRow("Lecții învățate", "\(memoryManager.items.filter { $0.kind == .lesson }.count)")
                    SettingsDivider()
                    stateRow("Proceduri", "\(memoryManager.procedureBook.procedures.filter(\.isEnabled).count)")
                    SettingsDivider()
                    stateRow("Cereri rezolvate fără model", "\(memoryManager.requestsAnsweredWithoutModel)")
                    SettingsDivider()
                    stateRow("Căutare după sens", memoryManager.usesMeaningSearch ? "activă (model Apple, local)" : "doar cuvinte-cheie")
                    SettingsDivider()
                    SettingsRow(title: "Conversații de învățat", subtitle: "\(memoryManager.pendingExchangeCount) așteaptă") {
                        Button(memoryManager.isLearning ? "Învață…" : "Învață acum") {
                            Task { await memoryManager.curatePendingExchanges() }
                        }
                        .buttonStyle(MackySecondaryPillStyle())
                        .disabled(memoryManager.isLearning || memoryManager.pendingExchangeCount == 0)
                    }
                }
                SettingsGroup(title: "Date", footer: "Totul stă doar pe Mac-ul tău, în ~/Library/Application Support/Macky (memory.json, procedures.json).") {
                    SettingsRow(title: "Șterge toată memoria", subtitle: "Amintirile, profilul și procedurile se pierd definitiv.") {
                        Button("Șterge…", role: .destructive) { isConfirmingDeletion = true }
                            .buttonStyle(MackySecondaryPillStyle())
                    }
                }
            }
        }
        .confirmationDialog("Ștergi tot ce știe Macky despre tine?", isPresented: $isConfirmingDeletion) {
            Button("Șterge tot", role: .destructive) { memoryManager.deleteEverything() }
        } message: {
            Text("Amintirile, profilul și procedurile învățate se pierd definitiv.")
        }
    }

    private func stateRow(_ title: String, _ value: String) -> some View {
        SettingsRow(title: title) {
            Text(value).font(MackyDesign.rounded(13, .semibold)).foregroundColor(MackyDesign.textSecondary)
        }
    }
}
