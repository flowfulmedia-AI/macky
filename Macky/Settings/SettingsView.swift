import AVFoundation
import MackyCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var apiKeyStore: OpenRouterAPIKeyStore
    @ObservedObject var modelCatalogStore: ModelCatalogStore
    @ObservedObject var session: CompanionSession
    let openRouterClient: OpenRouterClient

    var body: some View {
        TabView {
            OpenRouterSettingsTab(settings: settings, apiKeyStore: apiKeyStore, modelCatalogStore: modelCatalogStore, openRouterClient: openRouterClient)
                .tabItem { Label("AI", systemImage: "sparkles") }
            VoiceSettingsTab(settings: settings, session: session)
                .tabItem { Label("Voce", systemImage: "waveform") }
            GeneralSettingsTab(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .padding(16)
        .frame(minWidth: 620, minHeight: 620)
    }
}

// MARK: - AI

private struct OpenRouterSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var apiKeyStore: OpenRouterAPIKeyStore
    @ObservedObject var modelCatalogStore: ModelCatalogStore
    let openRouterClient: OpenRouterClient

    @State private var apiKeyDraft = ""
    @State private var keyStatusText: String?
    @State private var isCheckingKey = false
    @State private var editedSlot: ModelSlot = .fast

    enum ModelSlot: String, CaseIterable, Identifiable {
        case fast
        case powerful
        var id: String { rawValue }
        var title: String { self == .fast ? "Model rapid" : "Model puternic" }
    }

    var body: some View {
        Form {
            Section("Cheia OpenRouter") {
                HStack {
                    SecureField(apiKeyStore.hasAPIKey ? "•••••••• (salvată în Keychain)" : "sk-or-v1-…", text: $apiKeyDraft)
                        .textFieldStyle(.roundedBorder)
                    Button("Salvează") { saveAPIKey() }
                        .disabled(apiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                HStack(spacing: 12) {
                    Button(isCheckingKey ? "Verific…" : "Verifică cheia și creditele") { Task { await checkAPIKey() } }
                        .disabled(!apiKeyStore.hasAPIKey || isCheckingKey)
                    if apiKeyStore.hasAPIKey {
                        Button("Șterge cheia", role: .destructive) {
                            apiKeyStore.remove()
                            keyStatusText = nil
                        }
                    }
                    Link("Obține o cheie", destination: URL(string: "https://openrouter.ai/settings/keys")!)
                }
                if let keyStatusText {
                    Text(keyStatusText).font(.callout).foregroundColor(.secondary)
                }
            }

            Section("Modele") {
                Picker("Editezi", selection: $editedSlot) {
                    ForEach(ModelSlot.allCases) { slot in Text(slot.title).tag(slot) }
                }
                .pickerStyle(.segmented)

                Text("Ales: \(selectedIdentifier(for: editedSlot).isEmpty ? "—" : selectedIdentifier(for: editedSlot))")
                    .font(.callout.monospaced())
                    .textSelection(.enabled)

                ModelPickerList(
                    models: modelCatalogStore.visionModels,
                    selectedIdentifier: Binding(
                        get: { selectedIdentifier(for: editedSlot) },
                        set: { newIdentifier in
                            if editedSlot == .fast { settings.fastModelIdentifier = newIdentifier } else { settings.powerfulModelIdentifier = newIdentifier }
                        }
                    )
                )

                HStack {
                    Button(modelCatalogStore.isLoading ? "Se încarcă…" : "Reîncarcă lista") {
                        Task { await modelCatalogStore.refresh() }
                    }
                    .disabled(modelCatalogStore.isLoading)
                    Text("\(modelCatalogStore.visionModels.count) modele care văd imagini")
                        .font(.caption).foregroundColor(.secondary)
                }
                if let loadErrorMessage = modelCatalogStore.loadErrorMessage {
                    Text(loadErrorMessage).font(.caption).foregroundColor(.orange)
                }
            }

            Section("Indicare pe ecran") {
                Picker("Coordonate", selection: $settings.coordinateConventionChoice) {
                    ForEach(CoordinateConventionChoice.allCases) { choice in Text(choice.displayName).tag(choice) }
                }
                Text("„Automat” alege formatul potrivit fiecărei familii de modele. Folosește Calibrarea din meniu ca să vezi cât de precis arată un model.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func selectedIdentifier(for slot: ModelSlot) -> String {
        slot == .fast ? settings.fastModelIdentifier : settings.powerfulModelIdentifier
    }

    private func saveAPIKey() {
        do {
            try apiKeyStore.save(apiKeyDraft)
            apiKeyDraft = ""
            Task { await checkAPIKey() }
        } catch {
            keyStatusText = error.localizedDescription
        }
    }

    private func checkAPIKey() async {
        guard let apiKey = apiKeyStore.apiKey() else { return }
        isCheckingKey = true
        defer { isCheckingKey = false }
        do {
            let creditBalance = try await openRouterClient.fetchCreditBalance(apiKey: apiKey)
            keyStatusText = String(format: "✓ Cheia funcționează. Credite rămase: $%.2f (folosit $%.2f din $%.2f).",
                                   creditBalance.remainingCredits, creditBalance.totalUsage, creditBalance.totalCredits)
        } catch {
            keyStatusText = "✗ " + CompanionSession.userFacingMessage(for: error)
        }
    }
}

/// Searchable list of OpenRouter vision models with price and tool support.
struct ModelPickerList: View {
    let models: [ModelSummary]
    @Binding var selectedIdentifier: String
    @State private var searchText = ""

    private var filteredModels: [ModelSummary] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return models }
        return models.filter { $0.id.lowercased().contains(query) || $0.name.lowercased().contains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Caută (ex: gemini flash, claude sonnet, qwen vl)", text: $searchText)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredModels) { model in
                        modelRow(model)
                    }
                }
            }
            .frame(minHeight: 200, maxHeight: 260)
        }
    }

    private func modelRow(_ model: ModelSummary) -> some View {
        Button {
            selectedIdentifier = model.id
        } label: {
            HStack {
                Image(systemName: model.id == selectedIdentifier ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(model.id == selectedIdentifier ? MackyDesign.accent : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.name).font(.callout)
                    Text(model.id).font(.caption.monospaced()).foregroundColor(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(model.priceDescription).font(.caption)
                    Text(model.supportsToolCalling ? "arată prin tool" : "arată prin text")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(model.id == selectedIdentifier ? MackyDesign.accent.opacity(0.12) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Voice

private struct VoiceSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var session: CompanionSession

    private var availableVoices: [AVSpeechSynthesisVoice] {
        SpeechSpeaker.availableVoices(forLanguageCode: settings.responseLanguage.transcriptionLanguageCode)
    }

    var body: some View {
        Form {
            Section("Limbă") {
                Picker("Macky vorbește și înțelege", selection: $settings.responseLanguage) {
                    ForEach(ResponseLanguage.allCases, id: \.self) { language in Text(language.displayName).tag(language) }
                }
            }

            Section("Transcriere (vocea ta → text, local, gratuit)") {
                Picker("Motor", selection: $settings.transcriptionEngine) {
                    ForEach(TranscriptionEngine.allCases) { engine in Text(engine.displayName).tag(engine) }
                }
                if settings.transcriptionEngine == .whisperKit {
                    Picker("Model Whisper", selection: $settings.whisperModelVariant) {
                        ForEach(WhisperModelVariant.allCases) { variant in Text(variant.displayName).tag(variant) }
                    }
                    Text("Modelul se descarcă o singură dată în ~/Library/Application Support/Macky. Pe Mac-uri cu M1 sau mai nou, Large v3 Turbo e cel mai bun pentru română.")
                        .font(.caption).foregroundColor(.secondary)
                }
                if let transcriberStatusText = session.transcriberStatusText {
                    Text(transcriberStatusText).font(.caption).foregroundColor(.orange)
                }
                Button("Aplică și pregătește modelul") { session.prepareTranscriber() }
            }

            Section("Răspuns vocal (text → voce, voci macOS gratuite)") {
                Toggle("Citește răspunsurile cu voce", isOn: $settings.speakResponses)
                Picker("Voce", selection: $settings.speechVoiceIdentifier) {
                    Text("Automat (cea mai bună instalată)").tag("")
                    ForEach(availableVoices, id: \.identifier) { voice in
                        Text("\(voice.name) · \(voice.language) · \(SpeechSpeaker.qualityDescription(of: voice))").tag(voice.identifier)
                    }
                }
                HStack {
                    Text("Viteză")
                    Slider(value: $settings.speechRateMultiplier, in: 0.7...1.5, step: 0.05)
                    Text(String(format: "%.2fx", settings.speechRateMultiplier)).monospacedDigit()
                }
                HStack {
                    Button("Ascultă vocea") { session.previewVoice() }
                    Button("Descarcă voci mai bune…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent")!)
                    }
                }
                Text("Pentru o voce naturală: System Settings → Accessibility → Spoken Content → System Voice → Manage Voices, apoi descarcă „Ioana (Enhanced)” sau o voce Premium.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.transcriptionEngine) { _ in session.prepareTranscriber() }
        .onChange(of: settings.whisperModelVariant) { _ in session.prepareTranscriber() }
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @State private var launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?
    @State private var newExcludedBundleIdentifier = ""

    var body: some View {
        Form {
            Section("Scurtături (ține apăsat)") {
                Picker("Întreabă", selection: $settings.talkCombination) {
                    ForEach(ModifierKeys.selectableCombinations, id: \.rawValue) { combination in
                        Text("\(combination.symbols)  \(combination.readableName)").tag(combination)
                    }
                }
                Picker("Dictează", selection: Binding(
                    get: { settings.dictationCombination?.rawValue ?? 0 },
                    set: { settings.dictationCombination = $0 == 0 ? nil : ModifierKeys(rawValue: $0) }
                )) {
                    Text("Dezactivat").tag(0)
                    ForEach(ModifierKeys.selectableCombinations.filter { $0 != settings.talkCombination }, id: \.rawValue) { combination in
                        Text("\(combination.symbols)  \(combination.readableName)").tag(combination.rawValue)
                    }
                }
                Text("Dacă apeși și altă tastă cât ții combinația (de ex. ⌃⇧Tab), Macky o ignoră, ca scurtăturile obișnuite să meargă în continuare.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("Acțiuni pe calculator") {
                Picker("Macky poate apăsa și scrie", selection: $settings.actionMode) {
                    ForEach(ActionMode.allCases) { mode in Text(mode.displayName).tag(mode) }
                }
                Text("Spune de exemplu „apasă tu pe Export” sau „caută pisici pe YouTube”. Macky face câte un pas, verifică pe ecran și continuă. O nouă apăsare pe scurtătură îl oprește imediat. Funcționează doar cu modele care „arată prin tool”.")
                    .font(.caption).foregroundColor(.secondary)
                Toggle("Desenează pe ecran cât ții apăsată scurtătura (încercuiește ce vrei să întrebi)", isOn: $settings.drawingEnabled)
            }

            Section("Unde stă Macky") {
                Toggle("Panoul coboară din notch când duci mouse-ul acolo", isOn: $settings.notchPanelEnabled)
                Toggle("Arată și iconița din bara de meniu", isOn: $settings.showMenuBarIcon)
                    .disabled(!settings.notchPanelEnabled)
                Text("Pe Mac-urile fără notch, zona din mijlocul barei de meniu ține locul notch-ului.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("Ecran") {
                Toggle("Trimite toate monitoarele (implicit doar cel cu mouse-ul)", isOn: $settings.captureAllScreens)
                Picker("Rezoluția capturii", selection: $settings.maximumScreenshotLongEdge) {
                    Text("1024 px · cel mai ieftin").tag(1024)
                    Text("1280 px · recomandat").tag(1280)
                    Text("1568 px · detalii fine").tag(1568)
                    Text("1920 px · maxim").tag(1920)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Aplicații ascunse din capturi").font(.callout.weight(.medium))
                    ForEach(settings.excludedApplicationBundleIdentifiers, id: \.self) { bundleIdentifier in
                        HStack {
                            Text(bundleIdentifier).font(.caption.monospaced())
                            Spacer()
                            Button(role: .destructive) {
                                settings.excludedApplicationBundleIdentifiers.removeAll { $0 == bundleIdentifier }
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain)
                        }
                    }
                    HStack {
                        Menu("Adaugă o aplicație deschisă") {
                            ForEach(runningApplicationChoices, id: \.bundleIdentifier) { choice in
                                Button(choice.name) { addExcludedBundleIdentifier(choice.bundleIdentifier) }
                            }
                        }
                        TextField("sau bundle ID", text: $newExcludedBundleIdentifier)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { addExcludedBundleIdentifier(newExcludedBundleIdentifier) }
                    }
                }
            }

            Section("Conversație") {
                Stepper("Ține minte ultimele \(settings.rememberedExchangeCount) schimburi", value: $settings.rememberedExchangeCount, in: 0...20)
                Text("Doar întrebarea curentă primește captura de ecran; cele vechi se trimit ca text, ca să coste puțin.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("Pornire") {
                Toggle("Pornește Macky la login", isOn: Binding(
                    get: { launchAtLoginEnabled },
                    set: { setLaunchAtLogin($0) }
                ))
                if let launchAtLoginError {
                    Text(launchAtLoginError).font(.caption).foregroundColor(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var runningApplicationChoices: [(name: String, bundleIdentifier: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { application in
                guard let bundleIdentifier = application.bundleIdentifier else { return nil }
                return (name: application.localizedName ?? bundleIdentifier, bundleIdentifier: bundleIdentifier)
            }
            .sorted { $0.name < $1.name }
    }

    private func addExcludedBundleIdentifier(_ bundleIdentifier: String) {
        let trimmedIdentifier = bundleIdentifier.trimmingCharacters(in: .whitespaces)
        guard !trimmedIdentifier.isEmpty, !settings.excludedApplicationBundleIdentifiers.contains(trimmedIdentifier) else { return }
        settings.excludedApplicationBundleIdentifiers.append(trimmedIdentifier)
        newExcludedBundleIdentifier = ""
    }

    private func setLaunchAtLogin(_ shouldLaunchAtLogin: Bool) {
        do {
            if shouldLaunchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Nu am putut schimba pornirea la login: \(error.localizedDescription)"
        }
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }
}
