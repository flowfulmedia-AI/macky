import AVFoundation
import MackyCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var apiKeyStore: OpenRouterAPIKeyStore
    @ObservedObject var modelCatalogStore: ModelCatalogStore
    @ObservedObject var session: CompanionSession
    @ObservedObject var spotifyCredentialsStore: SpotifyCredentialsStore
    let openRouterClient: OpenRouterClient
    @ObservedObject var skillLibrary: SkillLibrary
    @ObservedObject var googleAccountManager: GoogleAccountManager
    @ObservedObject var routineStore: RoutineStore
    @ObservedObject var mcpConnectionStore: MCPConnectionStore
    @ObservedObject var zoomMeetingsManager: ZoomMeetingsManager

    var body: some View {
        TabView {
            SpotifySettingsTab(credentialsStore: spotifyCredentialsStore)
                .tabItem { Label("Spotify", systemImage: "music.note") }
            OpenRouterSettingsTab(settings: settings, apiKeyStore: apiKeyStore, modelCatalogStore: modelCatalogStore, openRouterClient: openRouterClient)
                .tabItem { Label("AI", systemImage: "sparkles") }
            VoiceSettingsTab(settings: settings, session: session)
                .tabItem { Label("Voce", systemImage: "waveform") }
            RoutinesSettingsTab(routineStore: routineStore, session: session)
                .tabItem { Label("Rutine", systemImage: "calendar.badge.clock") }
            ConnectionsSettingsTab(googleAccountManager: googleAccountManager, mcpConnectionStore: mcpConnectionStore, zoomMeetingsManager: zoomMeetingsManager)
                .tabItem { Label("Conexiuni", systemImage: "link") }
            SkillsSettingsTab(settings: settings, skillLibrary: skillLibrary)
                .tabItem { Label("Skills", systemImage: "wand.and.stars") }
            GeneralSettingsTab(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .padding(16)
        .frame(minWidth: 820, minHeight: 640)
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
                    SecureField(apiKeyStore.hasAPIKey ? "•••••••• (salvată pe Mac)" : "sk-or-v1-…", text: $apiKeyDraft)
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

            Section("Viteză") {
                Toggle("Răspunsuri rapide: modelul nu mai „gândește” înainte să răspundă", isOn: $settings.disableModelReasoning)
                Text("Economisește câteva secunde la fiecare pas. Modelele care nu permit asta sunt detectate automat și folosite normal.")
                    .font(.caption).foregroundColor(.secondary)
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

            Section("Răspuns vocal") {
                Toggle("Citește răspunsurile cu voce", isOn: $settings.speakResponses)
                Picker("Motor", selection: $settings.speechEngine) {
                    ForEach(SpeechEngineChoice.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                if settings.speechEngine == .neural {
                    Picker("Voce neurală", selection: $settings.neuralVoiceIdentifier) {
                        ForEach(EdgeTTSProtocol.romanianVoices + EdgeTTSProtocol.englishVoices) { voice in
                            Text("\(voice.displayName) · \(voice.id.prefix(5))").tag(voice.id)
                        }
                    }
                    Text("Vocile neurale Microsoft (aceleași ca în Edge „Read aloud”) sună natural și sunt gratuite, dar au nevoie de internet. Fără internet, Macky trece singur pe vocea Mac-ului de mai jos.")
                        .font(.caption).foregroundColor(.secondary)
                }
                Picker(settings.speechEngine == .neural ? "Voce Mac (rezervă)" : "Voce", selection: $settings.speechVoiceIdentifier) {
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
                Text("Voci Mac mai bune: System Settings → Accessibility → Spoken Content → System Voice → Manage Voices, apoi descarcă „Ioana (Enhanced)”.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.neuralVoiceIdentifier) { _ in session.prepareNeuralVoice() }
        .onChange(of: settings.speechEngine) { _ in session.prepareNeuralVoice() }
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
                Toggle("Comenzi instant, fără AI: „pauză”, „următoarea melodie”, „deschide Safari”", isOn: $settings.quickCommandsEnabled)
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
                Toggle("Conversație fără taste: după un răspuns, ascultă încă 5 secunde", isOn: $settings.followUpListeningEnabled)
                Text("Poți răspunde direct, fără să mai ții apăsat. „Mulțumesc” sau „gata” încheie conversația. Nu ascultă după acțiuni ca pornirea muzicii.")
                    .font(.caption).foregroundColor(.secondary)
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

// MARK: - Spotify

private struct SpotifySettingsTab: View {
    @ObservedObject var credentialsStore: SpotifyCredentialsStore
    @State private var clientIdentifierDraft = ""
    @State private var clientSecretDraft = ""
    @State private var statusText: String?
    @State private var isTesting = false

    var body: some View {
        Form {
            Section("Cum merge") {
                Text("Macky controlează Spotify direct (fără click-uri) și verifică de fiecare dată ce cântă. Spune de exemplu: „pune Numb de la Linkin Park”, „pornește Liked Songs”, „ceva de la Queen”, „următoarea melodie”.")
                    .font(.callout)
                Text("Pentru căutare precisă după nume, Macky are nevoie de o aplicație Spotify pentru dezvoltatori (gratuită, nu cere Premium). Fără ea merg Liked Songs, pauză, următoarea, dar căutarea e mai puțin sigură.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("Date aplicație Spotify (o singură dată, ~3 minute)") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("1. Deschide developer.spotify.com/dashboard și intră cu contul tău Spotify.")
                    Text("2. Create app → nume „Macky”, descriere orice, Redirect URI: http://127.0.0.1:8888/callback, bifează „Web API” → Save.")
                    Text("3. Intră în aplicație → Settings → copiază Client ID și Client secret aici.")
                }
                .font(.caption)
                Link("Deschide Spotify Developer Dashboard", destination: URL(string: "https://developer.spotify.com/dashboard")!)

                TextField(credentialsStore.hasCredentials ? "Client ID (salvat)" : "Client ID", text: $clientIdentifierDraft)
                    .textFieldStyle(.roundedBorder)
                SecureField(credentialsStore.hasCredentials ? "Client secret (salvat)" : "Client secret", text: $clientSecretDraft)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Salvează") { saveCredentials() }
                        .disabled(clientIdentifierDraft.trimmingCharacters(in: .whitespaces).isEmpty || clientSecretDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button(isTesting ? "Testez…" : "Testează căutarea") { Task { await testSearch() } }
                        .disabled(!credentialsStore.hasCredentials || isTesting)
                    if credentialsStore.hasCredentials {
                        Button("Șterge", role: .destructive) {
                            credentialsStore.remove()
                            statusText = nil
                        }
                    }
                }
                if let statusText {
                    Text(statusText).font(.callout).foregroundColor(.secondary)
                }
            }

            Section("Permisiune") {
                Text("Prima dată când Macky controlează Spotify, macOS întreabă „Macky wants to control Spotify”. Apasă OK. Dacă ai apăsat „Don't Allow”, reactivează din System Settings → Privacy & Security → Automation → Macky.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func saveCredentials() {
        do {
            try credentialsStore.save(clientIdentifier: clientIdentifierDraft, clientSecret: clientSecretDraft)
            clientIdentifierDraft = ""
            clientSecretDraft = ""
            Task { await testSearch() }
        } catch {
            statusText = error.localizedDescription
        }
    }

    private func testSearch() async {
        guard let clientIdentifier = credentialsStore.clientIdentifier, let clientSecret = credentialsStore.clientSecret else { return }
        isTesting = true
        defer { isTesting = false }
        do {
            let result = try await SpotifyWebAPIClient().search(query: "Numb Linkin Park", kind: .track, clientIdentifier: clientIdentifier, clientSecret: clientSecret)
            statusText = "✓ Funcționează. Test: am găsit „\(result.name)”\(result.artistName.map { " – \($0)" } ?? "")."
        } catch {
            statusText = "✗ \(error.localizedDescription)"
        }
    }
}

// MARK: - Skills

private struct SkillsSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var skillLibrary: SkillLibrary

    var body: some View {
        Form {
            Section("Skill-urile tale din Claude") {
                Text("Macky folosește skill-urile tale când scrie pentru tine (mailuri, oferte, postări…) sau când o cerere se potrivește cu descrierea lor. Pune în folderul de mai jos fiecare skill: folderul lui cu SKILL.md, fișierul .md, sau arhiva .zip / .skill descărcată din Claude (se dezarhivează singură).")
                    .font(.callout)
                HStack {
                    Text(skillLibrary.folderURL.path)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Deschide folderul") {
                        skillLibrary.reload()
                        NSWorkspace.shared.open(skillLibrary.folderURL)
                    }
                    Button("Alege alt folder…") { chooseFolder() }
                }
                Text("Din Claude: Settings → Capabilities → Skills → la fiecare skill, meniul „…” → Download. Pentru skill-urile făcute de tine în Claude Code, copiază folderul din ~/.claude/skills.")
                    .font(.caption).foregroundColor(.secondary)
                if let lastError = skillLibrary.lastError {
                    Text(lastError).font(.caption).foregroundColor(.red)
                }
            }
            Section("Găsite (\(skillLibrary.skills.count))") {
                if skillLibrary.skills.isEmpty {
                    Text("Niciun skill încă.").foregroundColor(.secondary)
                }
                ForEach(skillLibrary.skills) { skill in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(skill.name).fontWeight(.semibold)
                        Text(skill.description).font(.caption).foregroundColor(.secondary).lineLimit(3)
                    }
                }
                Button("Reîncarcă") { skillLibrary.reload() }
            }
        }
        .formStyle(.grouped)
        .onAppear { skillLibrary.reload() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = skillLibrary.folderURL
        if panel.runModal() == .OK, let url = panel.url {
            settings.skillsFolderPath = url.path
            skillLibrary.reload()
        }
    }
}

// MARK: - Connections

private struct ConnectionsSettingsTab: View {
    @ObservedObject var googleAccountManager: GoogleAccountManager
    @ObservedObject var mcpConnectionStore: MCPConnectionStore
    @ObservedObject var zoomMeetingsManager: ZoomMeetingsManager
    @State private var clientIdentifier = ""
    @State private var clientSecret = ""
    @State private var saveError: String?

    var body: some View {
        Form {
            Section("Aplicațiile tale (MCP)") {
                Text("Macky poate citi și modifica direct date din aplicațiile tale care au un server MCP (ex. Flowts): „pune-mi un task…”, „ce taskuri am azi?”. Ștergerile cer confirmare.")
                    .font(.caption).foregroundColor(.secondary)
                ForEach(mcpConnectionStore.servers) { server in
                    MCPServerRow(server: server, store: mcpConnectionStore)
                }
                HStack {
                    Button {
                        mcpConnectionStore.upsert(MCPServerConfiguration(name: "Aplicație nouă", url: "https://", instructions: ""))
                    } label: { Label("Adaugă aplicație", systemImage: "plus") }
                    if !mcpConnectionStore.servers.contains(where: { $0.url == MCPServerConfiguration.canvaPreset.url }) {
                        Button {
                            let identifier = mcpConnectionStore.addCanva()
                            Task { await mcpConnectionStore.signIn(identifier) }
                        } label: { Label("Conectează Canva", systemImage: "paintpalette") }
                    }
                }
                Text("Canva: după login în browser, Macky poate genera designuri („fă-mi o postare de Instagram pentru atelierul de sâmbătă”), le creează în contul tău și îți dă linkul. Uneltele Canva se încarcă doar când ceri ceva de design, ca celelalte cereri să rămână ieftine.")
                    .font(.caption).foregroundColor(.secondary)
            }

            ZoomSettingsSections(manager: zoomMeetingsManager, googleConnected: googleAccountManager.isConnected)

            Section("Google: Gmail și Drive") {
                HStack {
                    Image(systemName: googleAccountManager.isConnected ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(googleAccountManager.isConnected ? .green : .secondary)
                    Text(googleAccountManager.isConnected
                         ? "Conectat" + (googleAccountManager.connectedEmailAddress.map { " ca \($0)" } ?? "")
                         : "Neconectat")
                    Spacer()
                    if googleAccountManager.isConnected {
                        Button("Deconectează") { googleAccountManager.disconnect() }
                    } else {
                        Button(googleAccountManager.isConnecting ? "Se conectează…" : "Conectează Google") {
                            Task { await googleAccountManager.connect() }
                        }
                        .disabled(!googleAccountManager.hasClientCredentials || googleAccountManager.isConnecting)
                    }
                }
                if let statusText = googleAccountManager.statusText {
                    Text(statusText).font(.caption).foregroundColor(.secondary)
                }
                Text("Macky poate căuta și citi mailuri și fișiere din Drive („ce mi-a scris Andrei ieri?”, „găsește contractul Nordic”) și poate crea documente noi (notițele meetingurilor). Nu poate trimite mailuri și nu poate modifica sau șterge fișierele tale existente. Dacă te-ai conectat înainte de notițele de meeting, apasă Deconectează și conectează-te din nou, ca să-i dai voie să creeze documente.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("Clientul tău Google (o singură dată, ~10 minute)") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Deschide Google Cloud Console și creează un proiect nou, de exemplu „Macky”.")
                    Text("2. APIs & Services → Library: activează „Gmail API” și „Google Drive API”.")
                    Text("3. Google Auth Platform (OAuth consent screen): tip External, nume Macky, emailul tău. La Audience adaugă-ți adresa de Gmail ca Test user, apoi apasă „Publish app”, ca să nu expire conectarea după 7 zile.")
                    Text("4. Clients → Create client → tip „Desktop app” → Create. Copiază aici Client ID și Client secret.")
                    Text("5. Apasă „Conectează Google”. Google va spune că aplicația nu e verificată (e aplicația ta): Advanced → Go to Macky → Continue.")
                }
                .font(.callout)
                Button("Deschide Google Cloud Console") {
                    NSWorkspace.shared.open(URL(string: "https://console.cloud.google.com/apis/credentials")!)
                }
                TextField("Client ID (…apps.googleusercontent.com)", text: $clientIdentifier)
                    .textFieldStyle(.roundedBorder)
                SecureField("Client secret", text: $clientSecret)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Salvează") {
                        do {
                            try googleAccountManager.saveClientCredentials(clientIdentifier: clientIdentifier, clientSecret: clientSecret)
                            clientIdentifier = ""
                            clientSecret = ""
                            saveError = nil
                        } catch {
                            saveError = error.localizedDescription
                        }
                    }
                    .disabled(clientIdentifier.trimmingCharacters(in: .whitespaces).isEmpty || clientSecret.trimmingCharacters(in: .whitespaces).isEmpty)
                    if googleAccountManager.hasClientCredentials {
                        Label("Salvat", systemImage: "checkmark").font(.caption).foregroundColor(.green)
                    }
                }
                if let saveError {
                    Text(saveError).font(.caption).foregroundColor(.red)
                }
            }

            Section("Fișiere de pe Mac") {
                Text("Macky caută cu Spotlight în folderul tău (Documents, Desktop, Downloads…) și citește PDF, Word, RTF și text. Nu are nevoie de nicio setare.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Routines

struct RoutinesSettingsTab: View {
    @ObservedObject var routineStore: RoutineStore
    @ObservedObject var session: CompanionSession
    @State private var selectedIdentifier: UUID?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                List(routineStore.routines, selection: $selectedIdentifier) { routine in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(routine.name).fontWeight(.medium)
                        Text(routineSummary(routine)).font(.caption2).foregroundColor(.secondary)
                    }
                    .opacity(routine.isEnabled ? 1 : 0.5)
                    .tag(routine.id)
                }
                .frame(width: 210)
                HStack {
                    Button {
                        let routine = Routine(name: "Rutină nouă", triggerPhrases: [],
                                              schedule: RoutineSchedule(isEnabled: false, hour: 9, minute: 0, weekdays: RoutineSchedule.workdays),
                                              instructions: "")
                        routineStore.upsert(routine)
                        selectedIdentifier = routine.id
                    } label: { Label("Adaugă", systemImage: "plus") }
                    Menu("…") {
                        Button("Readaugă exemplele") { routineStore.restoreExamples() }
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 30)
                }
            }
            if let routine = routineStore.routines.first(where: { $0.id == selectedIdentifier }) {
                RoutineEditor(routine: routine, routineStore: routineStore, session: session)
                    .id(routine.id)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Rutine").font(.headline)
                    Text("O rutină e ceva ce Macky face la o frază („brief de dimineață”) sau singur, la o oră. Scrii în cuvintele tale ce să facă; Macky folosește calendarul, remindere, Gmail, web, aplicațiile și memoria.")
                    Text("Alege o rutină din stânga ca s-o modifici.").foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .onAppear { if selectedIdentifier == nil { selectedIdentifier = routineStore.routines.first?.id } }
    }

    private func routineSummary(_ routine: Routine) -> String {
        var parts: [String] = []
        if let phrase = routine.triggerPhrases.first { parts.append("„\(phrase)”") }
        if routine.schedule.isEnabled { parts.append(routine.schedule.shortDescription) }
        if !routine.isEnabled { parts.append("oprită") }
        return parts.isEmpty ? "fără declanșator" : parts.joined(separator: " · ")
    }
}

private struct RoutineEditor: View {
    @State private var draft: Routine
    @State private var phrasesText: String
    let routineStore: RoutineStore
    let session: CompanionSession

    init(routine: Routine, routineStore: RoutineStore, session: CompanionSession) {
        _draft = State(initialValue: routine)
        _phrasesText = State(initialValue: routine.triggerPhrases.joined(separator: ", "))
        self.routineStore = routineStore
        self.session = session
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: draft.schedule.hour, minute: draft.schedule.minute, second: 0, of: Date()) ?? Date() },
            set: { newValue in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                draft.schedule.hour = components.hour ?? 9
                draft.schedule.minute = components.minute ?? 0
                commit()
            }
        )
    }

    var body: some View {
        Form {
            Section {
                TextField("Nume", text: $draft.name, onCommit: commit)
                Toggle("Activă", isOn: Binding(get: { draft.isEnabled }, set: { draft.isEnabled = $0; commit() }))
            }
            Section("Pornește când spui") {
                TextField("fraze separate prin virgulă, ex. brief de dimineață, briefing", text: $phrasesText, onCommit: commit)
                Text("Ține apăsat ⌃⌥ și spune fraza. Funcționează doar cererile scurte, ca „brief de dimineață”, nu și întrebările care conțin fraza.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Pornește singură") {
                Toggle("La o oră fixă", isOn: Binding(get: { draft.schedule.isEnabled }, set: { draft.schedule.isEnabled = $0; commit() }))
                if draft.schedule.isEnabled {
                    DatePicker("Ora", selection: timeBinding, displayedComponents: .hourAndMinute)
                    HStack(spacing: 4) {
                        ForEach([(2, "Lu"), (3, "Ma"), (4, "Mi"), (5, "Jo"), (6, "Vi"), (7, "Sâ"), (1, "Du")], id: \.0) { weekday, name in
                            Toggle(name, isOn: Binding(
                                get: { draft.schedule.weekdays.contains(weekday) },
                                set: { isOn in
                                    if isOn { draft.schedule.weekdays.insert(weekday) } else { draft.schedule.weekdays.remove(weekday) }
                                    commit()
                                }
                            ))
                            .toggleStyle(.button)
                        }
                    }
                    Text("Dacă Mac-ul doarme la ora respectivă, rutina pornește când îl trezești (în următoarele 2 ore).")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            Section("Ce să facă") {
                TextEditor(text: $draft.instructions)
                    .font(.body)
                    .frame(minHeight: 140)
                Toggle("Spune rezultatul cu voce", isOn: Binding(get: { draft.speaksResult }, set: { draft.speaksResult = $0; commit() }))
            }
            Section {
                HStack {
                    Button("Salvează", action: commit)
                        .keyboardShortcut(.defaultAction)
                    Button("Rulează acum") {
                        commit()
                        session.runRoutineNow(draft)
                    }
                    .disabled(draft.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                    Button("Șterge", role: .destructive) { routineStore.delete(draft.id) }
                }
                if let lastRunAt = draft.lastRunAt {
                    Text("Ultima rulare: \(lastRunAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear(perform: commit)
    }

    private func commit() {
        draft.triggerPhrases = phrasesText
            .components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // Keep the latest run time from the store (the scheduler may have run it meanwhile).
        if let stored = routineStore.routines.first(where: { $0.id == draft.id }) {
            draft.lastRunAt = stored.lastRunAt
        } else {
            return
        }
        routineStore.upsert(draft)
    }
}

private struct MCPServerRow: View {
    @ObservedObject var store: MCPConnectionStore
    @State private var draft: MCPServerConfiguration
    @State private var token = ""
    @State private var isExpanded = false
    @State private var errorText: String?
    @State private var keywordsText: String

    init(server: MCPServerConfiguration, store: MCPConnectionStore) {
        _store = ObservedObject(wrappedValue: store)
        _draft = State(initialValue: server)
        _keywordsText = State(initialValue: server.activationKeywords.joined(separator: ", "))
    }

    /// The draft with the keywords typed so far.
    private var draftToSave: MCPServerConfiguration {
        var server = draft
        server.activationKeywords = keywordsText.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return server
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Nume (ex. Flowts)", text: $draft.name)
                TextField("Adresa serverului MCP", text: $draft.url)
                    .font(.body.monospaced())
                Text("Când să-l folosească (Macky citește asta)").font(.caption).foregroundColor(.secondary)
                TextEditor(text: $draft.instructions)
                    .frame(minHeight: 60)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                TextField("Doar pentru cereri cu aceste cuvinte (opțional, separate prin virgulă)", text: $keywordsText)
                .help("Gol = uneltele aplicației sunt mereu disponibile. Cu cuvinte = doar când cererea le conține (economisește tokens).")
                HStack {
                    if store.isSignedIn(draft.id) {
                        Label("Conectat prin login", systemImage: "checkmark.seal.fill").foregroundColor(.green)
                        Spacer()
                        Button("Deconectează") { store.signOut(draft.id) }
                    } else {
                        Text("Serverele cu login (ex. Flowts) se conectează din browser, o singură dată.")
                            .font(.caption).foregroundColor(.secondary)
                        Spacer()
                        if store.signingInServers.contains(draft.id) {
                            ProgressView().controlSize(.small)
                        }
                        Button(store.signingInServers.contains(draft.id) ? "Conectează din nou" : "Conectează (login)") {
                            draft = draftToSave
                            store.upsert(draft)
                            Task { await store.signIn(draft.id) }
                        }
                    }
                }
                HStack {
                    SecureField(store.hasToken(for: draft.id) ? "Token salvat (scrie altul ca să-l schimbi)" : "Sau token / cheie API, dacă serverul folosește așa ceva", text: $token)
                    TextField("Header", text: $draft.authorizationHeaderName)
                        .frame(width: 130)
                        .help("„Authorization” trimite „Bearer <token>”; altfel tokenul se trimite exact în header-ul ales (ex. x-api-key).")
                }
                HStack {
                    Toggle("Activă", isOn: $draft.isEnabled)
                    Spacer()
                    Button("Șterge", role: .destructive) { store.delete(draft.id) }
                    Button("Testează") {
                        Task { await store.refreshTools(for: draft.id) }
                    }
                    Button("Salvează și testează") {
                        draft = draftToSave
                        store.upsert(draft)
                        do {
                            if !token.isEmpty { try store.saveToken(token, for: draft.id) }
                            token = ""
                            errorText = nil
                        } catch {
                            errorText = error.localizedDescription
                        }
                        Task { await store.refreshTools(for: draft.id) }
                    }
                }
                if let errorText {
                    Text(errorText).font(.caption).foregroundColor(.red)
                }
                if let status = store.statusByServer[draft.id] {
                    Text(status).font(.caption).foregroundColor(status.hasPrefix("Eroare") || status.hasPrefix("Login eșuat") ? .red : .secondary)
                }
                if let toolNames = store.toolNamesByServer[draft.id], !toolNames.isEmpty {
                    Text("Unelte: " + toolNames.joined(separator: ", "))
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack {
                Text(draft.name).fontWeight(.medium)
                Spacer()
                Text(store.statusByServer[draft.id] ?? (draft.isEnabled ? "" : "oprită"))
                    .font(.caption)
                    .foregroundColor((store.statusByServer[draft.id] ?? "").hasPrefix("Eroare") ? .red : .secondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Zoom

private struct ZoomSettingsSections: View {
    @ObservedObject var manager: ZoomMeetingsManager
    let googleConnected: Bool
    @State private var accountIdentifier = ""
    @State private var clientIdentifier = ""
    @State private var clientSecret = ""
    @State private var saveError: String?

    var body: some View {
        Section("Zoom: fiecare meeting transcris și salvat în Drive") {
            Toggle("Procesează automat meetingurile înregistrate în cloud", isOn: $manager.isEnabled)
            HStack {
                Image(systemName: manager.hasCredentials ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(manager.hasCredentials ? .green : .secondary)
                Text(manager.hasCredentials ? "Aplicația Zoom e configurată" : "Aplicația Zoom nu e configurată")
                Spacer()
                if manager.hasCredentials {
                    Button("Testează") { Task { await manager.testConnection() } }
                    Button(manager.isChecking ? "Verific…" : "Verifică acum") { Task { await manager.checkForNewMeetings() } }
                        .disabled(manager.isChecking)
                }
            }
            if let statusText = manager.statusText {
                Text(statusText).font(.caption).foregroundColor(statusText.hasPrefix("Eroare") ? .red : .secondary)
            }
            if !googleConnected {
                Text("Conectează și Google (mai jos), ca notițele să poată fi urcate în Drive.").font(.caption).foregroundColor(.orange)
            }
            TextField("Folder în Drive", text: $manager.driveFolderName)
            TextField("Emailul contului Zoom (opțional, dacă „Testează” dă eroare)", text: $manager.userEmail)
            Toggle("Pune acțiunile mele din meeting ca taskuri (în Flowts sau Reminders)", isOn: $manager.createsTasks)
            Text("Macky verifică la fiecare 15 minute. Folosește transcrierea Zoom; dacă lipsește, transcrie audio-ul pe Mac. Notițele (rezumat, decizii, acțiuni, transcriere) ajung ca Google Doc în Drive și ca fișier în Documents/Macky/Meetinguri.")
                .font(.caption).foregroundColor(.secondary)
        }

        Section("Aplicația ta Zoom (o singură dată, ~10 minute)") {
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Intră pe marketplace.zoom.us → Develop → Build App → Server-to-Server OAuth App. Nume: Macky.")
                Text("2. Copiază aici Account ID, Client ID și Client Secret.")
                Text("3. La Information completează numele companiei și emailul tău.")
                Text("4. La Scopes adaugă: cloud_recording:read:list_user_recordings:admin, cloud_recording:read:list_recording_files:admin, cloud_recording:read:recording:admin, user:read:user:admin.")
                Text("5. La Activation apasă Activate your app.")
                Text("6. În Zoom (web) → Settings → Recording: pornește Cloud recording, Audio transcript și, dacă vrei fiecare meeting, Automatic recording → In the cloud.")
                Text("Participanții sunt anunțați de Zoom că meetingul se înregistrează.").foregroundColor(.secondary)
            }
            .font(.callout)
            Button("Deschide Zoom Marketplace") { NSWorkspace.shared.open(URL(string: "https://marketplace.zoom.us/develop/create")!) }
            TextField("Account ID", text: $accountIdentifier).textFieldStyle(.roundedBorder)
            TextField("Client ID", text: $clientIdentifier).textFieldStyle(.roundedBorder)
            SecureField("Client Secret", text: $clientSecret).textFieldStyle(.roundedBorder)
            HStack {
                Button("Salvează și testează") {
                    do {
                        try manager.saveCredentials(accountIdentifier: accountIdentifier, clientIdentifier: clientIdentifier, clientSecret: clientSecret)
                        accountIdentifier = ""
                        clientIdentifier = ""
                        clientSecret = ""
                        saveError = nil
                        Task { await manager.testConnection() }
                    } catch {
                        saveError = error.localizedDescription
                    }
                }
                .disabled([accountIdentifier, clientIdentifier, clientSecret].contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
                if manager.hasCredentials {
                    Spacer()
                    Button("Șterge datele Zoom", role: .destructive) { manager.removeCredentials() }
                }
            }
            if let saveError {
                Text(saveError).font(.caption).foregroundColor(.red)
            }
        }

        if !manager.processedMeetings.isEmpty {
            Section("Meetinguri procesate") {
                ForEach(manager.processedMeetings.prefix(15)) { meeting in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(meeting.topic).fontWeight(.medium)
                            Text(meeting.date.formatted(date: .abbreviated, time: .shortened) + (meeting.message.map { " · \($0)" } ?? ""))
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        if let link = meeting.documentLink, let url = URL(string: link) {
                            Button("Deschide") { NSWorkspace.shared.open(url) }
                        } else {
                            Button("Încearcă din nou") { manager.retry(meeting.id) }
                        }
                    }
                }
            }
        }
    }
}
