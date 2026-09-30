import MackyCore
import SwiftUI

/// Everything Macky knows about the user, editable: memories, the profile, learned procedures, and switches.
struct MemoryView: View {
    @ObservedObject var memoryManager: MemoryManager
    @ObservedObject var settings: AppSettings

    var body: some View {
        TabView {
            MemoryItemsTab(memoryManager: memoryManager)
                .tabItem { Label("Amintiri", systemImage: "brain") }
            MemoryProfileTab(memoryManager: memoryManager)
                .tabItem { Label("Profil", systemImage: "person.crop.circle") }
            ProceduresTab(memoryManager: memoryManager)
                .tabItem { Label("Proceduri învățate", systemImage: "bolt") }
            MemorySettingsTab(memoryManager: memoryManager, settings: settings)
                .tabItem { Label("Setări", systemImage: "slider.horizontal.3") }
        }
        .padding()
        .frame(minWidth: 700, minHeight: 520)
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
            HStack {
                TextField("Caută în memorie…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: $kindFilter) {
                    Text("Toate").tag(MemoryKind?.none)
                    ForEach(MemoryKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(MemoryKind?.some(kind))
                    }
                }
                .frame(width: 190)
                Button {
                    isAddingItem = true
                } label: {
                    Label("Adaugă", systemImage: "plus")
                }
            }
            if memoryManager.items.isEmpty {
                Spacer()
                Text("Macky nu ține minte nimic încă. Învață singur din conversații, sau spune-i „ține minte că…”. Poți adăuga și tu aici lucruri: clienți, unde sunt fișierele, preferințe.")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(visibleItems) { item in
                    row(for: item)
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
                    Text(item.subject).fontWeight(.semibold)
                    Text(item.kind.displayName)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(MackyDesign.cardBackground))
                }
                Text(item.content)
                    .font(.callout)
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
                List(memoryManager.procedureBook.procedures.sorted { $0.useCount > $1.useCount }) { procedure in
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
                        .toggleStyle(.switch)
                        .labelsHidden()
                        Button { memoryManager.deleteProcedure(procedure.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 3)
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
        Form {
            Section("Memorie") {
                Toggle("Memorie pe termen lung (învață din conversații)", isOn: $settings.memoryEnabled)
                Toggle("Învață proceduri (repetă instant cererile rezolvate de două ori)", isOn: $settings.learnedProceduresEnabled)
                Text("Învățarea folosește modelul „Rapid”, rar și în loturi: de obicei sub un cent pe zi.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Section("Stare") {
                LabeledContent("Amintiri", value: "\(memoryManager.items.count)")
                LabeledContent("Lecții învățate", value: "\(memoryManager.items.filter { $0.kind == .lesson }.count)")
                LabeledContent("Proceduri", value: "\(memoryManager.procedureBook.procedures.filter(\.isEnabled).count)")
                LabeledContent("Cereri rezolvate fără model", value: "\(memoryManager.requestsAnsweredWithoutModel)")
                LabeledContent("Căutare după sens", value: memoryManager.usesMeaningSearch ? "activă (model Apple, local)" : "doar cuvinte-cheie")
                HStack {
                    Text("Conversații care așteaptă să fie învățate: \(memoryManager.pendingExchangeCount)")
                    Spacer()
                    Button(memoryManager.isLearning ? "Învață…" : "Învață acum") {
                        Task { await memoryManager.curatePendingExchanges() }
                    }
                    .disabled(memoryManager.isLearning || memoryManager.pendingExchangeCount == 0)
                }
            }
            Section("Date") {
                Text("Totul stă doar pe Mac-ul tău, în ~/Library/Application Support/Macky (memory.json, procedures.json).")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("Șterge toată memoria…", role: .destructive) { isConfirmingDeletion = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Ștergi tot ce știe Macky despre tine?", isPresented: $isConfirmingDeletion) {
            Button("Șterge tot", role: .destructive) { memoryManager.deleteEverything() }
        } message: {
            Text("Amintirile, profilul și procedurile învățate se pierd definitiv.")
        }
    }
}
