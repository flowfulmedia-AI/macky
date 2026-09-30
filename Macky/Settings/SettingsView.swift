import AVFoundation
import MackyCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// Macky's settings: a sidebar grouped by topic and one clean page per topic.
struct SettingsView: View {
    enum Page: String, CaseIterable, Identifiable {
        case general, voice, shortcuts, conversation, screen
        case model, memory, skills
        case aiAccounts, google, whatsApp, zoom, apps, spotify
        case routines

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "General"
            case .voice: return "Voce și limbă"
            case .shortcuts: return "Scurtături"
            case .conversation: return "Conversație și acțiuni"
            case .screen: return "Ecran și confidențialitate"
            case .model: return "Model AI"
            case .memory: return "Memorie"
            case .skills: return "Skills"
            case .aiAccounts: return "Claude și ChatGPT"
            case .google: return "Gmail și Drive"
            case .whatsApp: return "WhatsApp"
            case .zoom: return "Zoom"
            case .apps: return "Aplicații (MCP)"
            case .spotify: return "Spotify"
            case .routines: return "Rutine"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape.fill"
            case .voice: return "waveform"
            case .shortcuts: return "command"
            case .conversation: return "bubble.left.and.bubble.right.fill"
            case .screen: return "lock.display"
            case .model: return "sparkles"
            case .memory: return "brain.head.profile"
            case .skills: return "wand.and.stars"
            case .aiAccounts: return "text.bubble.fill"
            case .google: return "envelope.fill"
            case .whatsApp: return "message.fill"
            case .zoom: return "video.fill"
            case .apps: return "square.stack.3d.up.fill"
            case .spotify: return "music.note"
            case .routines: return "calendar.badge.clock"
            }
        }

        static let groups: [(title: String, pages: [Page])] = [
            ("Macky", [.general, .voice, .shortcuts, .conversation, .screen]),
            ("Inteligență", [.model, .memory, .skills]),
            ("Conexiuni", [.aiAccounts, .google, .whatsApp, .zoom, .apps, .spotify]),
            ("Automatizări", [.routines])
        ]
    }

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
    @ObservedObject var whatsAppController: WhatsAppController
    @ObservedObject var memoryManager: MemoryManager
    var openMemory: () -> Void = {}
    var openHistory: () -> Void = {}
    var openCalibration: () -> Void = {}

    @State private var page: Page = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(MackyDesign.hairline).frame(width: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(MackyDesign.windowBackground)
        .environment(\.colorScheme, .dark)
        .toggleStyle(MackyToggleStyle())
        .frame(minWidth: 900, minHeight: 640)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                MackyMascotView(mood: .happy, size: 30)
                Text("Setări").font(MackyDesign.rounded(22, .bold)).foregroundColor(MackyDesign.textPrimary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 34)
            .padding(.bottom, 16)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Page.groups, id: \.title) { group in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(group.title.uppercased())
                                .font(MackyDesign.rounded(11, .bold))
                                .tracking(1.3)
                                .foregroundColor(MackyDesign.textSecondary)
                                .padding(.horizontal, 20)
                                .padding(.bottom, 4)
                            ForEach(group.pages) { item in
                                sidebarItem(item)
                            }
                        }
                    }
                }
                .padding(.bottom, 16)
            }
            Spacer(minLength: 0)
            Text("Macky · \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                .font(MackyDesign.rounded(11))
                .foregroundColor(MackyDesign.textSecondary)
                .padding(18)
        }
        .frame(width: 250)
        .background(MackyDesign.sidebarBackground)
    }

    private func sidebarItem(_ item: Page) -> some View {
        let isSelected = page == item
        return Button { page = item } label: {
            HStack(spacing: 11) {
                Image(systemName: item.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isSelected ? MackyDesign.textPrimary : MackyDesign.textSecondary)
                    .frame(width: 20)
                Text(item.title)
                    .font(MackyDesign.rounded(14, isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? MackyDesign.textPrimary : Color.white.opacity(0.78))
                Spacer()
                if let badge = badge(for: item) {
                    Circle().fill(badge).frame(width: 7, height: 7)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(isSelected ? MackyDesign.surfaceStrong : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .pointingHandOnHover()
    }

    /// A small dot for connections: green when connected.
    private func badge(for item: Page) -> Color? {
        switch item {
        case .google: return googleAccountManager.isConnected ? MackyDesign.accent : nil
        case .zoom: return zoomMeetingsManager.hasCredentials ? MackyDesign.accent : nil
        case .whatsApp: return whatsAppController.isAvailable ? MackyDesign.accent : nil
        case .aiAccounts: return session.chatArchiveStore.isEmpty ? nil : MackyDesign.accent
        case .spotify: return spotifyCredentialsStore.hasCredentials ? MackyDesign.accent : nil
        case .model: return apiKeyStore.hasAPIKey ? nil : .orange
        default: return nil
        }
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .general: GeneralPage(settings: settings)
        case .voice: VoicePage(settings: settings, session: session)
        case .shortcuts: ShortcutsPage(settings: settings)
        case .conversation: ConversationPage(settings: settings)
        case .screen: ScreenPage(settings: settings)
        case .model: ModelPage(settings: settings, apiKeyStore: apiKeyStore, modelCatalogStore: modelCatalogStore,
                               openRouterClient: openRouterClient, openCalibration: openCalibration)
        case .memory: MemorySettingsPage(settings: settings, memoryManager: memoryManager, openMemory: openMemory, openHistory: openHistory)
        case .skills: SkillsPage(settings: settings, skillLibrary: skillLibrary)
        case .aiAccounts: AIAccountsPage(store: session.chatArchiveStore, skillLibrary: skillLibrary)
        case .google: GooglePage(googleAccountManager: googleAccountManager)
        case .whatsApp: WhatsAppPage(settings: settings, controller: whatsAppController)
        case .zoom: ZoomPage(manager: zoomMeetingsManager, googleConnected: googleAccountManager.isConnected)
        case .apps: AppsPage(store: mcpConnectionStore)
        case .spotify: SpotifyPage(credentialsStore: spotifyCredentialsStore)
        case .routines:
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Rutine").font(MackyDesign.rounded(28, .bold)).foregroundColor(MackyDesign.textPrimary)
                    Text("Lucruri pe care Macky le face la o frază („brief de dimineață”) sau singur, la o oră. Scrii în cuvintele tale ce să facă: calendar, mailuri, WhatsApp, taskuri, aplicații.")
                        .font(MackyDesign.rounded(14)).foregroundColor(MackyDesign.textSecondary)
                }
                RoutinesSettingsTab(routineStore: routineStore, session: session)
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 30)
        }
    }
}

// MARK: - General

private struct GeneralPage: View {
    @ObservedObject var settings: AppSettings
    @State private var launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    var body: some View {
        SettingsPage(title: "General", subtitle: "Unde stă Macky și cum pornește.") {
            SettingsGroup(title: "Unde stă Macky", footer: "Pe Mac-urile fără notch, zona din mijlocul barei de meniu ține locul notch-ului.") {
                SettingsRow(title: "Panoul din notch", subtitle: "Coboară când duci mouse-ul la notch.") {
                    Toggle("", isOn: $settings.notchPanelEnabled).labelsHidden()
                }
                SettingsDivider()
                SettingsRow(title: "Iconiță în bara de meniu", subtitle: "Un al doilea mod de a deschide Macky.") {
                    Toggle("", isOn: $settings.showMenuBarIcon).labelsHidden()
                        .disabled(!settings.notchPanelEnabled)
                }
            }
            SettingsGroup(title: "Pornire") {
                SettingsRow(title: "Pornește Macky la login", subtitle: "Macky e gata imediat după ce deschizi Mac-ul.") {
                    Toggle("", isOn: Binding(get: { launchAtLoginEnabled }, set: { setLaunchAtLogin($0) })).labelsHidden()
                }
                if let launchAtLoginError {
                    SettingsBlock { SettingsMessage(text: launchAtLoginError) }
                }
            }
        }
    }

    private func setLaunchAtLogin(_ shouldLaunchAtLogin: Bool) {
        do {
            if shouldLaunchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Nu am putut schimba pornirea la login: \(error.localizedDescription)"
        }
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Voice

private struct VoicePage: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var session: CompanionSession

    private var availableVoices: [AVSpeechSynthesisVoice] {
        SpeechSpeaker.availableVoices(forLanguageCode: settings.responseLanguage.transcriptionLanguageCode)
    }

    var body: some View {
        SettingsPage(title: "Voce și limbă", subtitle: "Cum te aude Macky și cum îți răspunde.") {
            SettingsGroup(title: "Limbă") {
                SettingsRow(title: "Macky vorbește și înțelege", subtitle: "Limba răspunsurilor și a transcrierii.") {
                    Picker("", selection: $settings.responseLanguage) {
                        ForEach(ResponseLanguage.allCases, id: \.self) { language in Text(language.displayName).tag(language) }
                    }
                    .settingsMenu()
                }
            }

            SettingsGroup(title: "Vocea lui Macky") {
                SettingsRow(title: "Citește răspunsurile cu voce") {
                    Toggle("", isOn: $settings.speakResponses).labelsHidden()
                }
                SettingsDivider()
                SettingsRow(title: "Motor", subtitle: settings.speechEngine == .neural ? "Voci neurale gratuite (online); fără internet trece pe vocea Mac-ului." : "Vocile instalate pe Mac, fără internet.") {
                    Picker("", selection: $settings.speechEngine) {
                        ForEach(SpeechEngineChoice.allCases) { engine in Text(engine.displayName).tag(engine) }
                    }
                    .settingsMenu()
                }
                if settings.speechEngine == .neural {
                    SettingsDivider()
                    SettingsRow(title: "Voce neurală") {
                        Picker("", selection: $settings.neuralVoiceIdentifier) {
                            ForEach(EdgeTTSProtocol.romanianVoices + EdgeTTSProtocol.englishVoices) { voice in
                                Text("\(voice.displayName) · \(voice.id.prefix(5))").tag(voice.id)
                            }
                        }
                        .settingsMenu()
                    }
                }
                SettingsDivider()
                SettingsRow(title: settings.speechEngine == .neural ? "Voce Mac (rezervă)" : "Voce Mac") {
                    Picker("", selection: $settings.speechVoiceIdentifier) {
                        Text("Automat (cea mai bună instalată)").tag("")
                        ForEach(availableVoices, id: \.identifier) { voice in
                            Text("\(voice.name) · \(SpeechSpeaker.qualityDescription(of: voice))").tag(voice.identifier)
                        }
                    }
                    .settingsMenu()
                }
                SettingsDivider()
                SettingsRow(title: "Viteză", subtitle: String(format: "%.2fx", settings.speechRateMultiplier)) {
                    Slider(value: $settings.speechRateMultiplier, in: 0.7...1.5, step: 0.05).frame(width: 200)
                }
                SettingsDivider()
                SettingsBlock {
                    HStack {
                        Button { session.previewVoice() } label: { Label("Ascultă vocea", systemImage: "play.fill") }
                            .buttonStyle(MackyPrimaryPillStyle())
                        Button("Descarcă voci Mac mai bune") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent")!)
                        }
                        .buttonStyle(MackySecondaryPillStyle())
                    }
                }
            }

            SettingsGroup(title: "Transcriere", footer: "Vocea ta devine text direct pe Mac, gratuit. Pe M1 sau mai nou, Large v3 Turbo e cel mai precis pentru română.") {
                SettingsRow(title: "Motor") {
                    Picker("", selection: $settings.transcriptionEngine) {
                        ForEach(TranscriptionEngine.allCases) { engine in Text(engine.displayName).tag(engine) }
                    }
                    .settingsMenu()
                }
                if settings.transcriptionEngine == .whisperKit {
                    SettingsDivider()
                    SettingsRow(title: "Model Whisper") {
                        Picker("", selection: $settings.whisperModelVariant) {
                            ForEach(WhisperModelVariant.allCases) { variant in Text(variant.displayName).tag(variant) }
                        }
                        .settingsMenu()
                    }
                }
                if let transcriberStatusText = session.transcriberStatusText {
                    SettingsDivider()
                    SettingsBlock { SettingsMessage(text: transcriberStatusText) }
                }
            }
        }
        .onChange(of: settings.neuralVoiceIdentifier) { _ in session.prepareNeuralVoice() }
        .onChange(of: settings.speechEngine) { _ in session.prepareNeuralVoice() }
        .onChange(of: settings.transcriptionEngine) { _ in session.prepareTranscriber() }
        .onChange(of: settings.whisperModelVariant) { _ in session.prepareTranscriber() }
    }
}

// MARK: - Shortcuts

private struct ShortcutsPage: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsPage(title: "Scurtături", subtitle: "Ține apăsată combinația, vorbește, apoi eliberează.") {
            SettingsGroup(title: "Taste", footer: "Dacă apeși și altă tastă cât ții combinația (de ex. ⌃⇧Tab), Macky o ignoră, ca scurtăturile obișnuite să meargă în continuare.") {
                SettingsRow(title: "Întreabă", subtitle: "Macky vede ecranul, îți răspunde și face lucruri pentru tine.") {
                    Picker("", selection: $settings.talkCombination) {
                        ForEach(ModifierKeys.selectableCombinations, id: \.rawValue) { combination in
                            Text("\(combination.symbols)  \(combination.readableName)").tag(combination)
                        }
                    }
                    .settingsMenu()
                }
                SettingsDivider()
                SettingsRow(title: "Dictează", subtitle: "Scrie ce spui în orice aplicație, fără AI.") {
                    Picker("", selection: Binding(
                        get: { settings.dictationCombination?.rawValue ?? 0 },
                        set: { settings.dictationCombination = $0 == 0 ? nil : ModifierKeys(rawValue: $0) }
                    )) {
                        Text("Dezactivat").tag(0)
                        ForEach(ModifierKeys.selectableCombinations.filter { $0 != settings.talkCombination }, id: \.rawValue) { combination in
                            Text("\(combination.symbols)  \(combination.readableName)").tag(combination.rawValue)
                        }
                    }
                    .settingsMenu()
                }
            }
        }
    }
}

// MARK: - Conversation and actions

private struct ConversationPage: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsPage(title: "Conversație și acțiuni", subtitle: "Cât de liber lucrează Macky pe calculatorul tău.") {
            SettingsGroup(title: "Acțiuni pe calculator", footer: "Spune „apasă tu pe Export” sau „caută pisici pe YouTube”. O nouă apăsare pe scurtătură oprește imediat orice acțiune.") {
                SettingsRow(title: "Macky poate apăsa și scrie") {
                    Picker("", selection: $settings.actionMode) {
                        ForEach(ActionMode.allCases) { mode in Text(mode.displayName).tag(mode) }
                    }
                    .settingsMenu()
                }
                SettingsDivider()
                SettingsRow(title: "Comenzi instant, fără AI", subtitle: "„pauză”, „următoarea melodie”, „volumul la 40”, „deschide Safari”.") {
                    Toggle("", isOn: $settings.quickCommandsEnabled).labelsHidden()
                }
                SettingsDivider()
                SettingsRow(title: "Desenează pe ecran", subtitle: "Cât ții apăsat, mișcarea mouse-ului încercuiește ce vrei să întrebi.") {
                    Toggle("", isOn: $settings.drawingEnabled).labelsHidden()
                }
            }
            SettingsGroup(title: "Conversație") {
                SettingsRow(title: "Conversație fără taste", subtitle: "După un răspuns, Macky mai ascultă câteva secunde. „Mulțumesc” sau „gata” încheie.") {
                    Toggle("", isOn: $settings.followUpListeningEnabled).labelsHidden()
                }
                SettingsDivider()
                SettingsRow(title: "Ține minte ultimele \(settings.rememberedExchangeCount) replici", subtitle: "Doar întrebarea curentă trimite captura de ecran, ca să coste puțin.") {
                    Stepper("", value: $settings.rememberedExchangeCount, in: 0...20).labelsHidden()
                }
            }
        }
    }
}

// MARK: - Screen and privacy

private struct ScreenPage: View {
    @ObservedObject var settings: AppSettings
    @State private var newExcludedBundleIdentifier = ""

    var body: some View {
        SettingsPage(title: "Ecran și confidențialitate", subtitle: "Ce vede Macky și ce rămâne doar pe Mac-ul tău.") {
            SettingsGroup(title: "Captura de ecran", footer: "Captura se face doar când întrebi, niciodată în fundal.") {
                SettingsRow(title: "Toate monitoarele", subtitle: "Implicit, doar cel pe care e mouse-ul.") {
                    Toggle("", isOn: $settings.captureAllScreens).labelsHidden()
                }
                SettingsDivider()
                SettingsRow(title: "Rezoluție", subtitle: "Mai mare vede detalii fine, dar costă mai mult.") {
                    Picker("", selection: $settings.maximumScreenshotLongEdge) {
                        Text("1024 px · cel mai ieftin").tag(1024)
                        Text("1280 px · recomandat").tag(1280)
                        Text("1568 px · detalii fine").tag(1568)
                        Text("1920 px · maxim").tag(1920)
                    }
                    .settingsMenu()
                }
            }
            SettingsGroup(title: "Aplicații ascunse din capturi", footer: "Ferestrele lor nu apar niciodată în ce vede Macky (de exemplu managerii de parole).") {
                ForEach(settings.excludedApplicationBundleIdentifiers, id: \.self) { bundleIdentifier in
                    SettingsRow(title: applicationName(for: bundleIdentifier), subtitle: bundleIdentifier) {
                        Button { settings.excludedApplicationBundleIdentifiers.removeAll { $0 == bundleIdentifier } } label: { Image(systemName: "minus") }
                            .buttonStyle(MackyIconButtonStyle())
                    }
                    SettingsDivider()
                }
                SettingsBlock {
                    HStack {
                        Menu("Adaugă o aplicație deschisă") {
                            ForEach(runningApplicationChoices, id: \.bundleIdentifier) { choice in
                                Button(choice.name) { addExcludedBundleIdentifier(choice.bundleIdentifier) }
                            }
                        }
                        .fixedSize()
                        TextField("sau bundle ID", text: $newExcludedBundleIdentifier)
                            .mackyField()
                            .onSubmit { addExcludedBundleIdentifier(newExcludedBundleIdentifier) }
                    }
                }
            }
            SettingsGroup(title: "Datele tale") {
                SettingsBlock {
                    Text("Cheile și conexiunile stau doar pe Mac, în ~/Library/Application Support/Macky (fișier privat, criptat de FileVault). Memoria, istoricul și rutinele sunt tot acolo. Audio-ul vocii tale se transcrie pe Mac și nu pleacă nicăieri.")
                        .font(MackyDesign.rounded(13))
                        .foregroundColor(MackyDesign.textSecondary)
                    Button("Deschide folderul Macky") {
                        NSWorkspace.shared.open(ApplicationDirectories.applicationSupportDirectory)
                    }
                    .buttonStyle(MackySecondaryPillStyle())
                }
            }
        }
    }

    private func applicationName(for bundleIdentifier: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleIdentifier
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
}

// MARK: - AI model

private struct ModelPage: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var apiKeyStore: OpenRouterAPIKeyStore
    @ObservedObject var modelCatalogStore: ModelCatalogStore
    let openRouterClient: OpenRouterClient
    let openCalibration: () -> Void

    @State private var apiKeyDraft = ""
    @State private var keyStatusText: String?
    @State private var isCheckingKey = false
    @State private var editedSlot: ModelSlot = .fast

    enum ModelSlot: String, CaseIterable, Identifiable {
        case fast, powerful
        var id: String { rawValue }
        var title: String { self == .fast ? "Rapid" : "Puternic" }
    }

    var body: some View {
        SettingsPage(title: "Model AI", subtitle: "Creierul lui Macky vine prin OpenRouter: plătești doar ce folosești, din creditele tale.") {
            SettingsGroup(title: "Cheia OpenRouter") {
                SettingsRow(title: "Stare", subtitle: apiKeyStore.hasAPIKey ? "Cheia e salvată pe Mac." : "Adaugă o cheie ca Macky să poată răspunde.") {
                    StatusBadge(isOn: apiKeyStore.hasAPIKey, text: apiKeyStore.hasAPIKey ? "Salvată" : "Lipsește")
                }
                SettingsDivider()
                SettingsBlock {
                    HStack {
                        SecureField(apiKeyStore.hasAPIKey ? "•••••••• (scrie alta ca s-o înlocuiești)" : "sk-or-v1-…", text: $apiKeyDraft).mackyField()
                        Button("Salvează") { saveAPIKey() }
                            .buttonStyle(MackyPrimaryPillStyle())
                            .disabled(apiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    HStack {
                        Button(isCheckingKey ? "Verific…" : "Verifică cheia și creditul") { Task { await checkAPIKey() } }
                            .buttonStyle(MackySecondaryPillStyle())
                            .disabled(!apiKeyStore.hasAPIKey || isCheckingKey)
                        Button("Obține o cheie") { NSWorkspace.shared.open(URL(string: "https://openrouter.ai/settings/keys")!) }
                            .buttonStyle(MackySecondaryPillStyle())
                        Spacer()
                        if apiKeyStore.hasAPIKey {
                            Button("Șterge", role: .destructive) { apiKeyStore.remove(); keyStatusText = nil }
                                .buttonStyle(MackySecondaryPillStyle())
                        }
                    }
                    if let keyStatusText { SettingsMessage(text: keyStatusText) }
                }
            }

            SettingsGroup(title: "Modele", footer: "Comuți între Rapid și Puternic din panoul lui Macky. Toate modelele din listă văd imagini.") {
                SettingsBlock {
                    Picker("", selection: $editedSlot) {
                        ForEach(ModelSlot.allCases) { slot in Text(slot.title).tag(slot) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 240)
                    Text("Ales: \(selectedIdentifier(for: editedSlot).isEmpty ? "—" : selectedIdentifier(for: editedSlot))")
                        .font(MackyDesign.rounded(12).monospaced())
                        .foregroundColor(MackyDesign.textSecondary)
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
                        Button(modelCatalogStore.isLoading ? "Se încarcă…" : "Reîncarcă lista") { Task { await modelCatalogStore.refresh() } }
                            .buttonStyle(MackySecondaryPillStyle())
                            .disabled(modelCatalogStore.isLoading)
                        Text("\(modelCatalogStore.visionModels.count) modele").font(MackyDesign.rounded(12)).foregroundColor(MackyDesign.textSecondary)
                    }
                    if let loadErrorMessage = modelCatalogStore.loadErrorMessage { SettingsMessage(text: loadErrorMessage) }
                }
            }

            SettingsGroup(title: "Viteză și precizie") {
                SettingsRow(title: "Răspunsuri rapide", subtitle: "Modelul nu mai „gândește” înainte să răspundă; economisește secunde la fiecare pas.") {
                    Toggle("", isOn: $settings.disableModelReasoning).labelsHidden()
                }
                SettingsDivider()
                SettingsRow(title: "Coordonate pentru indicare", subtitle: "„Automat” alege formatul potrivit fiecărui model.") {
                    Picker("", selection: $settings.coordinateConventionChoice) {
                        ForEach(CoordinateConventionChoice.allCases) { choice in Text(choice.displayName).tag(choice) }
                    }
                    .settingsMenu()
                }
                SettingsDivider()
                SettingsRow(title: "Calibrare", subtitle: "Vezi cât de precis arată un model pe ecran.") {
                    Button("Deschide", action: openCalibration).buttonStyle(MackySecondaryPillStyle())
                }
            }
        }
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
            keyStatusText = String(format: "✓ Cheia funcționează. Credit rămas: $%.2f (folosit $%.2f din $%.2f).",
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
            TextField("Caută (ex: gemini flash, claude sonnet, qwen vl)", text: $searchText).mackyField()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredModels) { model in modelRow(model) }
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
                    .foregroundColor(model.id == selectedIdentifier ? MackyDesign.accent : MackyDesign.textSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.name).font(MackyDesign.rounded(13, .medium)).foregroundColor(MackyDesign.textPrimary)
                    Text(model.id).font(.caption.monospaced()).foregroundColor(MackyDesign.textSecondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(model.priceDescription).font(MackyDesign.rounded(11)).foregroundColor(MackyDesign.textPrimary)
                    Text(model.supportsToolCalling ? "poate acționa" : "doar arată")
                        .font(MackyDesign.rounded(10)).foregroundColor(MackyDesign.textSecondary)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(model.id == selectedIdentifier ? MackyDesign.accent.opacity(0.14) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Memory

private struct MemorySettingsPage: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var memoryManager: MemoryManager
    let openMemory: () -> Void
    let openHistory: () -> Void

    var body: some View {
        SettingsPage(title: "Memorie", subtitle: "Macky învață din conversații și din greșeli, ca să te ajute tot mai bine și mai ieftin.") {
            SettingsGroup(title: "Învățare", footer: "Învățarea folosește modelul Rapid, rar și în loturi: de obicei sub un cent pe zi.") {
                SettingsRow(title: "Memorie pe termen lung", subtitle: "Clienți, unde sunt fișierele, preferințe, lecții.") {
                    Toggle("", isOn: $settings.memoryEnabled).labelsHidden()
                }
                SettingsDivider()
                SettingsRow(title: "Proceduri învățate ⚡", subtitle: "Cererile rezolvate de două ori la fel se repetă apoi instant, fără cost.") {
                    Toggle("", isOn: $settings.learnedProceduresEnabled).labelsHidden()
                }
                SettingsDivider()
                SettingsRow(title: "Istoric", subtitle: "Păstrează toate cererile și ce a făcut Macky.") {
                    Toggle("", isOn: $settings.historyEnabled).labelsHidden()
                }
            }
            SettingsGroup(title: "Ce știe acum") {
                SettingsRow(title: "\(memoryManager.items.count) amintiri", subtitle: "\(memoryManager.items.filter { $0.kind == .lesson }.count) lecții · \(memoryManager.procedureBook.procedures.filter(\.isEnabled).count) proceduri · \(memoryManager.requestsAnsweredWithoutModel) cereri rezolvate fără model") {
                    Button("Deschide memoria", action: openMemory).buttonStyle(MackyPrimaryPillStyle())
                }
                SettingsDivider()
                SettingsRow(title: "Istoric", subtitle: "Toate cererile tale, căutabile.") {
                    Button("Deschide istoricul", action: openHistory).buttonStyle(MackySecondaryPillStyle())
                }
            }
        }
    }
}

// MARK: - Skills

private struct SkillsPage: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var skillLibrary: SkillLibrary

    var body: some View {
        SettingsPage(title: "Skills", subtitle: "Skill-urile tale din Claude: Macky le folosește când scrie pentru tine sau când o cerere li se potrivește.") {
            SettingsGroup(title: "Folderul cu skills", footer: "Din Claude: Settings → Capabilities → Skills → „…” → Download. Pune aici folderul cu SKILL.md, fișierul .md sau arhiva .zip / .skill (se dezarhivează singură).") {
                SettingsBlock {
                    Text(skillLibrary.folderURL.path)
                        .font(.caption.monospaced())
                        .foregroundColor(MackyDesign.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack {
                        Button("Deschide folderul") {
                            skillLibrary.reload()
                            NSWorkspace.shared.open(skillLibrary.folderURL)
                        }
                        .buttonStyle(MackyPrimaryPillStyle())
                        Button("Alege alt folder") { chooseFolder() }.buttonStyle(MackySecondaryPillStyle())
                        Button("Reîncarcă") { skillLibrary.reload() }.buttonStyle(MackySecondaryPillStyle())
                    }
                    if let lastError = skillLibrary.lastError { SettingsMessage(text: lastError) }
                }
            }
            SettingsGroup(title: "Găsite (\(skillLibrary.skills.count))") {
                if skillLibrary.skills.isEmpty {
                    SettingsBlock { SettingsMessage(text: "Niciun skill încă.") }
                }
                ForEach(Array(skillLibrary.skills.enumerated()), id: \.element.id) { index, skill in
                    if index > 0 { SettingsDivider() }
                    SettingsBlock {
                        Text(skill.name).font(MackyDesign.rounded(14, .semibold)).foregroundColor(MackyDesign.textPrimary)
                        Text(skill.description).font(MackyDesign.rounded(12)).foregroundColor(MackyDesign.textSecondary).lineLimit(3)
                    }
                }
            }
        }
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

// MARK: - Claude and ChatGPT

private struct AIAccountsPage: View {
    @ObservedObject var store: ChatArchiveStore
    @ObservedObject var skillLibrary: SkillLibrary

    var body: some View {
        SettingsPage(title: "Claude și ChatGPT",
                     subtitle: "Adu în Macky conversațiile, proiectele și skill-urile din conturile tale, ca să le poată căuta, continua și folosi pentru agenți.") {
            SettingsGroup(title: "Conversații", footer: "Claude și ChatGPT nu permit altor aplicații să citească direct conturile, așa că folosim exportul oficial de date. Totul rămâne doar pe Mac-ul tău. Poți reimporta oricând un export nou: conversațiile se actualizează, nu se dublează.") {
                accountRow(.claude, steps: "claude.ai → Settings → Privacy → Export data. Primești pe email un link către o arhivă .zip.")
                SettingsDivider()
                accountRow(.chatGPT, steps: "chatgpt.com → Settings → Data controls → Export data. Primești pe email o arhivă .zip.")
                SettingsDivider()
                SettingsBlock {
                    HStack {
                        Button(store.isImporting ? "Import…" : "Importă arhiva (.zip)") { chooseExport() }
                            .buttonStyle(MackyPrimaryPillStyle())
                            .disabled(store.isImporting)
                        Spacer()
                    }
                    if let statusText = store.statusText { SettingsMessage(text: statusText) }
                    Text("Apoi îi poți spune: „ce am discutat cu Claude despre lansarea cursului?” sau „continuă planul din ChatGPT despre reclame”.")
                        .font(MackyDesign.rounded(12))
                        .foregroundColor(MackyDesign.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsGroup(title: "Proiecte Claude (\(store.projects.count))",
                          footer: "Vin din exportul Claude. „Fă skill” transformă instrucțiunile și fișierele proiectului într-un skill pe care Macky îl folosește la cerere; e primul pas spre agenți.") {
                if store.projects.isEmpty {
                    SettingsBlock { SettingsMessage(text: "Niciun proiect importat încă.") }
                }
                ForEach(Array(store.projects.enumerated()), id: \.element.id) { index, project in
                    if index > 0 { SettingsDivider() }
                    SettingsRow(title: project.name,
                                subtitle: project.summary.isEmpty ? "\(project.documents.count) fișiere" : project.summary) {
                        let isSkill = skillLibrary.skills.contains { $0.name.caseInsensitiveCompare(project.name) == .orderedSame }
                        Button(isSkill ? "E skill ✓" : "Fă skill") {
                            if store.makeSkill(from: project, in: skillLibrary.folderURL) { skillLibrary.reload() }
                        }
                        .buttonStyle(MackySecondaryPillStyle())
                        .disabled(isSkill)
                    }
                }
            }

            SettingsGroup(title: "Skill-uri din Claude", footer: "Skill-urile din contul Claude nu se pot descărca automat. Le iei o singură dată, apoi Macky le vede pe toate.") {
                SettingsBlock {
                    SettingsSteps(steps: [
                        "claude.ai → Settings → Capabilities → Skills.",
                        "La fiecare skill al tău: „…” → Download (primești un .zip).",
                        "Pune arhivele în folderul de skills al lui Macky (Setări → Skills → Deschide folderul). Se dezarhivează singure.",
                        "Skill-urile din Claude Code (~/.claude/skills) le vede automat."
                    ])
                    HStack {
                        Button("Deschide folderul de skills") {
                            skillLibrary.reload()
                            NSWorkspace.shared.open(skillLibrary.folderURL)
                        }
                        .buttonStyle(MackySecondaryPillStyle())
                        Spacer()
                        Text("\(skillLibrary.skills.count) skill-uri găsite")
                            .font(MackyDesign.rounded(12, .semibold))
                            .foregroundColor(MackyDesign.textSecondary)
                    }
                }
            }
        }
        .onAppear { skillLibrary.reload() }
    }

    private func accountRow(_ source: ChatArchiveKit.Source, steps: String) -> some View {
        let count = store.chatCount(for: source)
        return SettingsRow(title: source.displayName, subtitle: steps) {
            VStack(alignment: .trailing, spacing: 6) {
                StatusBadge(isOn: count > 0, text: count > 0 ? "\(count) conversații" : "Neimportat")
                if count > 0 {
                    Button("Șterge") { Task { await store.removeAll(from: source) } }
                        .buttonStyle(.plain)
                        .font(MackyDesign.rounded(11))
                        .foregroundColor(MackyDesign.textSecondary)
                }
            }
        }
    }

    private func chooseExport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.zip, .json, .folder]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.message = "Alege arhiva exportată din Claude sau ChatGPT"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task {
            for url in urls { await store.importExport(from: url) }
        }
    }
}

// MARK: - Google

private struct GooglePage: View {
    @ObservedObject var googleAccountManager: GoogleAccountManager
    @State private var clientIdentifier = ""
    @State private var clientSecret = ""
    @State private var saveError: String?

    var body: some View {
        SettingsPage(title: "Gmail și Drive", subtitle: "Macky caută și citește mailuri și fișiere, și creează documente noi (de exemplu notițele meetingurilor). Nu trimite mailuri și nu modifică fișierele tale.") {
            SettingsGroup(title: "Cont") {
                SettingsRow(title: googleAccountManager.isConnected ? (googleAccountManager.connectedEmailAddress ?? "Conectat") : "Neconectat",
                            subtitle: googleAccountManager.isConnected ? "„Ce mi-a scris Andrei ieri?”, „găsește contractul Nordic”." : "Adaugă întâi clientul Google de mai jos.") {
                    if googleAccountManager.isConnected {
                        Button("Deconectează") { googleAccountManager.disconnect() }.buttonStyle(MackySecondaryPillStyle())
                    } else {
                        Button(googleAccountManager.isConnecting ? "Se conectează…" : "Conectează Google") {
                            Task { await googleAccountManager.connect() }
                        }
                        .buttonStyle(MackyPrimaryPillStyle())
                        .disabled(!googleAccountManager.hasClientCredentials || googleAccountManager.isConnecting)
                    }
                }
                if let statusText = googleAccountManager.statusText {
                    SettingsDivider()
                    SettingsBlock { SettingsMessage(text: statusText) }
                }
            }
            SettingsGroup(title: "Clientul tău Google · o singură dată, ~10 minute") {
                SettingsBlock {
                    SettingsSteps(steps: [
                        "Deschide Google Cloud Console și creează un proiect nou, de exemplu „Macky”.",
                        "APIs & Services → Library: activează „Gmail API” și „Google Drive API”.",
                        "Google Auth Platform: tip External, nume Macky, emailul tău. La Audience adaugă-ți Gmail-ul ca Test user, apoi „Publish app”, ca să nu expire conectarea după 7 zile.",
                        "Clients → Create client → „Desktop app”. Copiază aici Client ID și Client secret.",
                        "Apasă „Conectează Google”. Google spune că aplicația nu e verificată (e a ta): Advanced → Go to Macky."
                    ])
                    Button("Deschide Google Cloud Console") { NSWorkspace.shared.open(URL(string: "https://console.cloud.google.com/apis/credentials")!) }
                        .buttonStyle(MackySecondaryPillStyle())
                }
                SettingsDivider()
                SettingsBlock {
                    TextField("Client ID (…apps.googleusercontent.com)", text: $clientIdentifier).mackyField()
                    SecureField("Client secret", text: $clientSecret).mackyField()
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
                        .buttonStyle(MackyPrimaryPillStyle())
                        .disabled(clientIdentifier.trimmingCharacters(in: .whitespaces).isEmpty || clientSecret.trimmingCharacters(in: .whitespaces).isEmpty)
                        if googleAccountManager.hasClientCredentials { StatusBadge(isOn: true, text: "Client salvat") }
                    }
                    if let saveError { SettingsMessage(text: saveError) }
                }
            }
            SettingsGroup(title: "Fișiere de pe Mac") {
                SettingsBlock {
                    SettingsMessage(text: "Macky caută cu Spotlight în Documents, Desktop, Downloads și citește PDF, Word, RTF și text. Nu are nevoie de nicio setare.")
                }
            }
        }
    }
}

// MARK: - WhatsApp

private struct WhatsAppPage: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: WhatsAppController

    var body: some View {
        SettingsPage(title: "WhatsApp", subtitle: "Macky citește conversațiile și trimite mesaje prin aplicația WhatsApp de pe Mac. Merge și în rutine: „trimite-i lui Andrei rezumatul”, „ce mesaje necitite am?”.") {
            SettingsGroup(title: "Conexiune") {
                SettingsRow(title: "Folosește WhatsApp", subtitle: controller.statusText ?? "Apasă „Verifică” ca să vezi dacă Macky are acces.") {
                    Toggle("", isOn: $settings.whatsAppEnabled).labelsHidden()
                }
                SettingsDivider()
                SettingsBlock {
                    HStack {
                        Button("Verifică") { controller.checkAccess() }.buttonStyle(MackyPrimaryPillStyle())
                        Button("Deschide Full Disk Access") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                        }
                        .buttonStyle(MackySecondaryPillStyle())
                        Button("Descarcă WhatsApp pentru Mac") { NSWorkspace.shared.open(URL(string: "macappstore://apps.apple.com/app/id310633997")!) }
                            .buttonStyle(MackySecondaryPillStyle())
                    }
                }
            }
            SettingsGroup(title: "Cum se conectează · o singură dată") {
                SettingsBlock {
                    SettingsSteps(steps: [
                        "Instalează aplicația WhatsApp pentru Mac (App Store) și conectează-te în ea cu telefonul.",
                        "Apasă „Verifică”. Dacă macOS întreabă dacă Macky poate accesa datele altor aplicații, apasă Allow.",
                        "Dacă scrie că nu are voie: System Settings → Privacy & Security → Full Disk Access → pornește Macky, apoi repornește Macky.",
                        "Prima dată când trimite un mesaj, macOS poate cere permisiunea de Accessibility (o ai deja pentru click-uri)."
                    ])
                }
            }
            SettingsGroup(title: "Trimitere", footer: "Macky deschide conversația cu mesajul scris, apasă Enter și verifică în WhatsApp că a plecat. În modul „Întreabă înainte”, îți arată mesajul înainte să-l trimită; în rutine trimite direct. În grupuri, caută grupul în WhatsApp, scrie mesajul și se uită pe ecran că e grupul corect înainte să apese Enter (ecranul trebuie să fie deblocat).") {
                SettingsRow(title: "Prefix de țară implicit", subtitle: "Pentru numerele spuse fără prefix, de ex. „0722…”.") {
                    TextField("40", text: $settings.whatsAppCountryCode).mackyField().frame(width: 70)
                }
            }
        }
        .onAppear { controller.checkAccess() }
    }
}

// MARK: - Zoom

private struct ZoomPage: View {
    @ObservedObject var manager: ZoomMeetingsManager
    let googleConnected: Bool
    @State private var accountIdentifier = ""
    @State private var clientIdentifier = ""
    @State private var clientSecret = ""
    @State private var saveError: String?

    var body: some View {
        SettingsPage(title: "Zoom", subtitle: "Fiecare meeting înregistrat în cloud devine notițe (rezumat, decizii, acțiuni, transcriere) într-un Google Doc.") {
            SettingsGroup(title: "Meetinguri") {
                SettingsRow(title: "Procesează automat", subtitle: "Macky verifică la fiecare 15 minute.") {
                    Toggle("", isOn: $manager.isEnabled).labelsHidden()
                }
                SettingsDivider()
                SettingsRow(title: "Aplicația Zoom", subtitle: manager.statusText) {
                    HStack {
                        StatusBadge(isOn: manager.hasCredentials, text: manager.hasCredentials ? "Configurată" : "Lipsește")
                        if manager.hasCredentials {
                            Button(manager.isChecking ? "Verific…" : "Verifică acum") { Task { await manager.checkForNewMeetings() } }
                                .buttonStyle(MackySecondaryPillStyle())
                                .disabled(manager.isChecking)
                        }
                    }
                }
                if !googleConnected {
                    SettingsDivider()
                    SettingsBlock { SettingsMessage(text: "Nu găsesc Google conectat: conectează-l la „Gmail și Drive”, ca notițele să ajungă în Drive.") }
                }
                SettingsDivider()
                SettingsRow(title: "Folder în Drive") {
                    TextField("Folder", text: $manager.driveFolderName).mackyField().frame(width: 240)
                }
                SettingsDivider()
                SettingsRow(title: "Acțiunile mele devin taskuri", subtitle: "În Flowts (sau Reminders), cu linkul notițelor.") {
                    Toggle("", isOn: $manager.createsTasks).labelsHidden()
                }
                SettingsDivider()
                SettingsRow(title: "Emailul contului Zoom", subtitle: "Opțional, doar dacă verificarea dă eroare.") {
                    TextField("email", text: $manager.userEmail).mackyField().frame(width: 240)
                }
            }
            SettingsGroup(title: "Aplicația ta Zoom · o singură dată, ~10 minute", footer: "Participanții sunt anunțați de Zoom că meetingul se înregistrează.") {
                SettingsBlock {
                    SettingsSteps(steps: [
                        "marketplace.zoom.us → Develop → Build App → Server-to-Server OAuth App, nume Macky.",
                        "Copiază aici Account ID, Client ID și Client Secret.",
                        "Information: numele companiei și emailul tău.",
                        "Scopes: cloud_recording:read:list_user_recordings:admin, cloud_recording:read:list_recording_files:admin, cloud_recording:read:recording:admin, user:read:user:admin.",
                        "Activation → Activate your app.",
                        "În Zoom (web) → Settings → Recording: Cloud recording, Audio transcript și, dacă vrei fiecare meeting, Automatic recording → In the cloud."
                    ])
                    Button("Deschide Zoom Marketplace") { NSWorkspace.shared.open(URL(string: "https://marketplace.zoom.us/develop/create")!) }
                        .buttonStyle(MackySecondaryPillStyle())
                }
                SettingsDivider()
                SettingsBlock {
                    TextField("Account ID", text: $accountIdentifier).mackyField()
                    TextField("Client ID", text: $clientIdentifier).mackyField()
                    SecureField("Client Secret", text: $clientSecret).mackyField()
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
                        .buttonStyle(MackyPrimaryPillStyle())
                        .disabled([accountIdentifier, clientIdentifier, clientSecret].contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
                        Spacer()
                        if manager.hasCredentials {
                            Button("Testează") { Task { await manager.testConnection() } }.buttonStyle(MackySecondaryPillStyle())
                            Button("Șterge datele", role: .destructive) { manager.removeCredentials() }.buttonStyle(MackySecondaryPillStyle())
                        }
                    }
                    if let saveError { SettingsMessage(text: saveError) }
                }
            }
            if !manager.processedMeetings.isEmpty {
                SettingsGroup(title: "Ultimele meetinguri") {
                    ForEach(Array(manager.processedMeetings.prefix(10).enumerated()), id: \.element.id) { index, meeting in
                        if index > 0 { SettingsDivider() }
                        SettingsRow(title: meeting.topic, subtitle: meeting.date.formatted(date: .abbreviated, time: .shortened) + (meeting.message.map { " · \($0)" } ?? "")) {
                            if let link = meeting.documentLink, let url = URL(string: link) {
                                Button("Deschide") { NSWorkspace.shared.open(url) }.buttonStyle(MackySecondaryPillStyle())
                            } else {
                                Button("Încearcă din nou") { manager.retry(meeting.id) }.buttonStyle(MackySecondaryPillStyle())
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Connected apps (MCP)

private struct AppsPage: View {
    @ObservedObject var store: MCPConnectionStore

    var body: some View {
        SettingsPage(title: "Aplicații (MCP)", subtitle: "Aplicațiile tale cu server MCP: Macky le citește și le modifică direct. Ștergerile cer confirmare.") {
            SettingsGroup(title: "Conectate", footer: "Apps cu multe unelte (ca Canva) se încarcă doar când cererea conține cuvintele lor, ca celelalte cereri să rămână ieftine.") {
                ForEach(Array(store.servers.enumerated()), id: \.element.id) { index, server in
                    if index > 0 { SettingsDivider() }
                    MCPServerRow(server: server, store: store)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                }
                if store.servers.isEmpty {
                    SettingsBlock { SettingsMessage(text: "Nicio aplicație încă.") }
                }
            }
            HStack {
                Button {
                    store.upsert(MCPServerConfiguration(name: "Aplicație nouă", url: "https://", instructions: ""))
                } label: { Label("Adaugă aplicație", systemImage: "plus") }
                    .buttonStyle(MackySecondaryPillStyle())
                if !store.servers.contains(where: { $0.url == MCPServerConfiguration.canvaPreset.url }) {
                    Button {
                        let identifier = store.addCanva()
                        Task { await store.signIn(identifier) }
                    } label: { Label("Conectează Canva", systemImage: "paintpalette") }
                        .buttonStyle(MackyPrimaryPillStyle())
                }
            }
        }
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundColor(MackyDesign.primaryButtonGlow)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(MackyDesign.surfaceStrong))
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.name).font(MackyDesign.rounded(14, .semibold)).foregroundColor(MackyDesign.textPrimary)
                    Text(store.statusByServer[draft.id] ?? (draft.isEnabled ? draft.url : "oprită"))
                        .font(MackyDesign.rounded(12))
                        .foregroundColor((store.statusByServer[draft.id] ?? "").hasPrefix("Eroare") ? .orange : MackyDesign.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                if store.isSignedIn(draft.id) {
                    StatusBadge(isOn: true, text: "Conectat")
                } else {
                    if store.signingInServers.contains(draft.id) { ProgressView().controlSize(.small) }
                    Button(store.signingInServers.contains(draft.id) ? "Conectează din nou" : "Conectează") {
                        draft = draftToSave
                        store.upsert(draft)
                        Task { await store.signIn(draft.id) }
                    }
                    .buttonStyle(MackyPrimaryPillStyle())
                }
                Button { withAnimation { isExpanded.toggle() } } label: { Image(systemName: isExpanded ? "chevron.up" : "chevron.down") }
                    .buttonStyle(MackyIconButtonStyle())
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Nume (ex. Flowts)", text: $draft.name).mackyField()
                    TextField("Adresa serverului MCP", text: $draft.url).mackyField()
                    Text("Când să-l folosească (Macky citește asta)").font(MackyDesign.rounded(12)).foregroundColor(MackyDesign.textSecondary)
                    TextEditor(text: $draft.instructions)
                        .font(MackyDesign.rounded(13))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(minHeight: 64)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.35)))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(MackyDesign.hairline, lineWidth: 1))
                    TextField("Doar pentru cereri cu aceste cuvinte (opțional, separate prin virgulă)", text: $keywordsText).mackyField()
                    HStack {
                        SecureField(store.hasToken(for: draft.id) ? "Token salvat (scrie altul ca să-l schimbi)" : "Token / cheie API, doar dacă serverul cere", text: $token).mackyField()
                        TextField("Header", text: $draft.authorizationHeaderName).mackyField().frame(width: 130)
                    }
                    HStack {
                        Toggle("Activă", isOn: $draft.isEnabled)
                            .foregroundColor(MackyDesign.textPrimary)
                        Spacer()
                        if store.isSignedIn(draft.id) {
                            Button("Deconectează") { store.signOut(draft.id) }.buttonStyle(MackySecondaryPillStyle())
                        }
                        Button("Șterge", role: .destructive) { store.delete(draft.id) }.buttonStyle(MackySecondaryPillStyle())
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
                        .buttonStyle(MackyPrimaryPillStyle())
                    }
                    if let errorText { SettingsMessage(text: errorText) }
                    if let toolNames = store.toolNamesByServer[draft.id], !toolNames.isEmpty {
                        Text("Unelte: " + toolNames.joined(separator: ", "))
                            .font(MackyDesign.rounded(11)).foregroundColor(MackyDesign.textSecondary)
                    }
                }
                .padding(.top, 4)
            }
        }
    }
}

// MARK: - Spotify

private struct SpotifyPage: View {
    @ObservedObject var credentialsStore: SpotifyCredentialsStore
    @State private var clientIdentifierDraft = ""
    @State private var clientSecretDraft = ""
    @State private var statusText: String?
    @State private var isTesting = false

    var body: some View {
        SettingsPage(title: "Spotify", subtitle: "„Pune Numb de la Linkin Park”, „pornește Liked Songs”, „următoarea”. Macky controlează Spotify direct și verifică ce cântă.") {
            SettingsGroup(title: "Căutare precisă după nume", footer: "Fără aplicația de dezvoltator merg Liked Songs, pauză și următoarea, dar căutarea e mai puțin sigură. Nu cere Premium.") {
                SettingsRow(title: "Aplicația Spotify pentru dezvoltatori") {
                    StatusBadge(isOn: credentialsStore.hasCredentials, text: credentialsStore.hasCredentials ? "Configurată" : "Lipsește")
                }
                SettingsDivider()
                SettingsBlock {
                    SettingsSteps(steps: [
                        "Deschide developer.spotify.com/dashboard și intră cu contul tău.",
                        "Create app → nume „Macky”, Redirect URI: http://127.0.0.1:8888/callback, bifează „Web API” → Save.",
                        "Settings → copiază aici Client ID și Client secret."
                    ])
                    Button("Deschide Spotify Dashboard") { NSWorkspace.shared.open(URL(string: "https://developer.spotify.com/dashboard")!) }
                        .buttonStyle(MackySecondaryPillStyle())
                }
                SettingsDivider()
                SettingsBlock {
                    TextField(credentialsStore.hasCredentials ? "Client ID (salvat)" : "Client ID", text: $clientIdentifierDraft).mackyField()
                    SecureField(credentialsStore.hasCredentials ? "Client secret (salvat)" : "Client secret", text: $clientSecretDraft).mackyField()
                    HStack {
                        Button("Salvează") { saveCredentials() }
                            .buttonStyle(MackyPrimaryPillStyle())
                            .disabled(clientIdentifierDraft.trimmingCharacters(in: .whitespaces).isEmpty || clientSecretDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button(isTesting ? "Testez…" : "Testează căutarea") { Task { await testSearch() } }
                            .buttonStyle(MackySecondaryPillStyle())
                            .disabled(!credentialsStore.hasCredentials || isTesting)
                        Spacer()
                        if credentialsStore.hasCredentials {
                            Button("Șterge", role: .destructive) { credentialsStore.remove(); statusText = nil }
                                .buttonStyle(MackySecondaryPillStyle())
                        }
                    }
                    if let statusText { SettingsMessage(text: statusText) }
                }
            }
            SettingsGroup(title: "Permisiune") {
                SettingsBlock {
                    SettingsMessage(text: "Prima dată macOS întreabă „Macky wants to control Spotify”: apasă OK. Dacă ai refuzat, reactivează din System Settings → Privacy & Security → Automation → Macky.")
                }
            }
        }
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

// MARK: - Routines

struct RoutinesSettingsTab: View {
    @ObservedObject var routineStore: RoutineStore
    @ObservedObject var session: CompanionSession
    @State private var selectedIdentifier: UUID?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(routineStore.routines) { routine in
                            routineRow(routine)
                        }
                    }
                }
                HStack {
                    Button {
                        let routine = Routine(name: "Rutină nouă", triggerPhrases: [],
                                              schedule: RoutineSchedule(isEnabled: false, hour: 9, minute: 0, weekdays: RoutineSchedule.workdays),
                                              instructions: "")
                        routineStore.upsert(routine)
                        selectedIdentifier = routine.id
                    } label: { Label("Adaugă", systemImage: "plus") }
                        .buttonStyle(MackySecondaryPillStyle())
                    Menu("…") {
                        Button("Readaugă exemplele") { routineStore.restoreExamples() }
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 30)
                }
            }
            .frame(width: 230)
            if let routine = routineStore.routines.first(where: { $0.id == selectedIdentifier }) {
                RoutineEditor(routine: routine, routineStore: routineStore, session: session)
                    .id(routine.id)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Alege o rutină din stânga ca s-o modifici.").font(MackyDesign.rounded(13)).foregroundColor(MackyDesign.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .toggleStyle(MackyToggleStyle())
        .onAppear { if selectedIdentifier == nil { selectedIdentifier = routineStore.routines.first?.id } }
    }

    private func routineRow(_ routine: Routine) -> some View {
        let isSelected = routine.id == selectedIdentifier
        return Button { selectedIdentifier = routine.id } label: {
            HStack(spacing: 10) {
                MackyMascotView(mood: .idle, size: 28, colors: MascotPalette.lemon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(routine.name).font(MackyDesign.rounded(13, .semibold)).foregroundColor(MackyDesign.textPrimary)
                    Text(routineSummary(routine)).font(MackyDesign.rounded(11)).foregroundColor(MackyDesign.textSecondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(isSelected ? MackyDesign.surfaceStrong : Color.clear))
            .opacity(routine.isEnabled ? 1 : 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsGroup {
                    SettingsBlock {
                        TextField("Nume", text: $draft.name, onCommit: commit)
                            .font(MackyDesign.rounded(18, .bold))
                            .textFieldStyle(.plain)
                    }
                    SettingsDivider()
                    SettingsRow(title: "Activă") {
                        Toggle("", isOn: Binding(get: { draft.isEnabled }, set: { draft.isEnabled = $0; commit() })).labelsHidden()
                    }
                }
                SettingsGroup(title: "Pornește când spui", footer: "Ține apăsat ⌃⌥ și spune fraza. Merg doar cererile scurte, ca „brief de dimineață”.") {
                    SettingsBlock {
                        TextField("fraze separate prin virgulă, ex. brief de dimineață, briefing", text: $phrasesText, onCommit: commit).mackyField()
                    }
                }
                SettingsGroup(title: "Pornește singură", footer: draft.schedule.isEnabled ? "Dacă Mac-ul doarme la ora respectivă, rutina pornește când îl trezești (în următoarele 2 ore)." : nil) {
                    SettingsRow(title: "La o oră fixă") {
                        Toggle("", isOn: Binding(get: { draft.schedule.isEnabled }, set: { draft.schedule.isEnabled = $0; commit() })).labelsHidden()
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
                                        commit()
                                    }
                                    .buttonStyle(.plain)
                                    .font(MackyDesign.rounded(12, .semibold))
                                    .foregroundColor(isOn ? Color(red: 0.08, green: 0.10, blue: 0.25) : MackyDesign.textSecondary)
                                    .frame(width: 36, height: 30)
                                    .background(Capsule().fill(isOn ? AnyShapeStyle(MackyDesign.primaryButtonGradient) : AnyShapeStyle(MackyDesign.surface)))
                                }
                            }
                        }
                    }
                }
                SettingsGroup(title: "Ce să facă") {
                    SettingsBlock {
                        TextEditor(text: $draft.instructions)
                            .font(MackyDesign.rounded(13))
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .frame(minHeight: 150)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.35)))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(MackyDesign.hairline, lineWidth: 1))
                    }
                    SettingsDivider()
                    SettingsRow(title: "Spune rezultatul cu voce") {
                        Toggle("", isOn: Binding(get: { draft.speaksResult }, set: { draft.speaksResult = $0; commit() })).labelsHidden()
                    }
                }
                HStack {
                    Button("Salvează", action: commit).buttonStyle(MackyPrimaryPillStyle())
                    Button("Rulează acum") {
                        commit()
                        session.runRoutineNow(draft)
                    }
                    .buttonStyle(MackySecondaryPillStyle())
                    .disabled(draft.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                    Button("Șterge", role: .destructive) { routineStore.delete(draft.id) }.buttonStyle(MackySecondaryPillStyle())
                }
                if let lastRunAt = draft.lastRunAt {
                    Text("Ultima rulare: \(lastRunAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(MackyDesign.rounded(12)).foregroundColor(MackyDesign.textSecondary)
                }
            }
        }
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
