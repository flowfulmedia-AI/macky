import Foundation
import MackyCore

enum TranscriptionEngine: String, CaseIterable, Identifiable {
    case whisperKit
    case appleSpeech

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisperKit: return "Whisper local (recomandat)"
        case .appleSpeech: return "Apple Speech"
        }
    }
}

/// WhisperKit model folders from huggingface.co/argmaxinc/whisperkit-coreml.
enum WhisperModelVariant: String, CaseIterable, Identifiable {
    case base = "openai_whisper-base"
    case small = "openai_whisper-small"
    case largeTurbo = "openai_whisper-large-v3-v20240930_626MB"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .base: return "Base · ~150 MB · cel mai rapid"
        case .small: return "Small · ~480 MB · echilibrat"
        case .largeTurbo: return "Large v3 Turbo · ~630 MB · cel mai precis la română"
        }
    }
}

/// Whether Macky may click and type on the computer when asked to.
enum ActionMode: String, CaseIterable, Identifiable {
    case disabled
    case askFirst
    case automatic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .disabled: return "Dezactivat (doar arată)"
        case .askFirst: return "Întreabă înainte de fiecare acțiune (recomandat)"
        case .automatic: return "Automat, fără confirmare"
        }
    }
}

enum CoordinateConventionChoice: String, CaseIterable, Identifiable {
    case automatic
    case imagePixels
    case normalizedTo1000

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "Automat (după familia modelului)"
        case .imagePixels: return CoordinateConvention.imagePixels.displayName
        case .normalizedTo1000: return CoordinateConvention.normalizedTo1000.displayName
        }
    }
}

/// All user preferences, persisted in UserDefaults. The API key is NOT here; it lives in the Keychain.
@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var fastModelIdentifier: String { didSet { defaults.set(fastModelIdentifier, forKey: Keys.fastModelIdentifier) } }
    @Published var powerfulModelIdentifier: String { didSet { defaults.set(powerfulModelIdentifier, forKey: Keys.powerfulModelIdentifier) } }
    @Published var usePowerfulModel: Bool { didSet { defaults.set(usePowerfulModel, forKey: Keys.usePowerfulModel) } }
    @Published var coordinateConventionChoice: CoordinateConventionChoice { didSet { defaults.set(coordinateConventionChoice.rawValue, forKey: Keys.coordinateConventionChoice) } }

    @Published var responseLanguage: ResponseLanguage { didSet { defaults.set(responseLanguage.rawValue, forKey: Keys.responseLanguage) } }
    @Published var speakResponses: Bool { didSet { defaults.set(speakResponses, forKey: Keys.speakResponses) } }
    /// Empty string means "best available voice for the response language".
    @Published var speechVoiceIdentifier: String { didSet { defaults.set(speechVoiceIdentifier, forKey: Keys.speechVoiceIdentifier) } }
    @Published var speechRateMultiplier: Double { didSet { defaults.set(speechRateMultiplier, forKey: Keys.speechRateMultiplier) } }

    @Published var transcriptionEngine: TranscriptionEngine { didSet { defaults.set(transcriptionEngine.rawValue, forKey: Keys.transcriptionEngine) } }
    @Published var whisperModelVariant: WhisperModelVariant { didSet { defaults.set(whisperModelVariant.rawValue, forKey: Keys.whisperModelVariant) } }

    @Published var talkCombination: ModifierKeys { didSet { defaults.set(talkCombination.rawValue, forKey: Keys.talkCombination) } }
    /// nil disables dictation.
    @Published var dictationCombination: ModifierKeys? { didSet { defaults.set(dictationCombination?.rawValue ?? 0, forKey: Keys.dictationCombination) } }

    @Published var captureAllScreens: Bool { didSet { defaults.set(captureAllScreens, forKey: Keys.captureAllScreens) } }
    @Published var maximumScreenshotLongEdge: Int { didSet { defaults.set(maximumScreenshotLongEdge, forKey: Keys.maximumScreenshotLongEdge) } }
    @Published var excludedApplicationBundleIdentifiers: [String] { didSet { defaults.set(excludedApplicationBundleIdentifiers, forKey: Keys.excludedApplicationBundleIdentifiers) } }

    @Published var actionMode: ActionMode { didSet { defaults.set(actionMode.rawValue, forKey: Keys.actionMode) } }
    /// Holding the talk hotkey lets the user draw on screen with the mouse to mark what they mean.
    @Published var drawingEnabled: Bool { didSet { defaults.set(drawingEnabled, forKey: Keys.drawingEnabled) } }
    /// The panel drops down from the MacBook notch when the mouse touches it.
    @Published var notchPanelEnabled: Bool { didSet { defaults.set(notchPanelEnabled, forKey: Keys.notchPanelEnabled) } }
    @Published var showMenuBarIcon: Bool { didSet { defaults.set(showMenuBarIcon, forKey: Keys.showMenuBarIcon) } }
    /// Asks models not to "think" before answering, which saves seconds on every step.
    @Published var disableModelReasoning: Bool { didSet { defaults.set(disableModelReasoning, forKey: Keys.disableModelReasoning) } }
    /// "Pauză", "următoarea melodie", "deschide Safari" run instantly, without the model.
    @Published var quickCommandsEnabled: Bool { didSet { defaults.set(quickCommandsEnabled, forKey: Keys.quickCommandsEnabled) } }
    /// Models that rejected the "no reasoning" setting; they are called without it.
    @Published private(set) var modelsRejectingReasoningSetting: Set<String> { didSet { defaults.set(Array(modelsRejectingReasoningSetting), forKey: Keys.modelsRejectingReasoningSetting) } }

    /// Long-term memory: learns from conversations and gives relevant memories to the model.
    @Published var memoryEnabled: Bool { didSet { defaults.set(memoryEnabled, forKey: Keys.memoryEnabled) } }
    /// Requests solved the same way twice are then replayed directly, without the model.
    @Published var learnedProceduresEnabled: Bool { didSet { defaults.set(learnedProceduresEnabled, forKey: Keys.learnedProceduresEnabled) } }
    @Published var historyEnabled: Bool { didSet { defaults.set(historyEnabled, forKey: Keys.historyEnabled) } }

    @Published var rememberedExchangeCount: Int { didSet { defaults.set(rememberedExchangeCount, forKey: Keys.rememberedExchangeCount) } }
    /// Models that answered "tool use not supported"; they get text tags instead of the point_at tool.
    @Published private(set) var modelsWithoutToolCalling: Set<String> { didSet { defaults.set(Array(modelsWithoutToolCalling), forKey: Keys.modelsWithoutToolCalling) } }

    static let defaultExcludedApplicationBundleIdentifiers = [
        "com.apple.Passwords",
        "com.apple.keychainaccess",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop"
    ]

    init() {
        defaults.register(defaults: [
            Keys.usePowerfulModel: false,
            Keys.speakResponses: true,
            Keys.speechRateMultiplier: 1.0,
            Keys.talkCombination: ModifierKeys([.control, .option]).rawValue,
            Keys.dictationCombination: ModifierKeys([.control, .shift]).rawValue,
            Keys.captureAllScreens: false,
            Keys.maximumScreenshotLongEdge: 1280,
            Keys.rememberedExchangeCount: 6,
            Keys.excludedApplicationBundleIdentifiers: Self.defaultExcludedApplicationBundleIdentifiers,
            Keys.actionMode: ActionMode.askFirst.rawValue,
            Keys.drawingEnabled: true,
            Keys.notchPanelEnabled: true,
            Keys.showMenuBarIcon: false,
            Keys.disableModelReasoning: true,
            Keys.quickCommandsEnabled: true,
            Keys.memoryEnabled: true,
            Keys.learnedProceduresEnabled: true,
            Keys.historyEnabled: true
        ])

        fastModelIdentifier = defaults.string(forKey: Keys.fastModelIdentifier) ?? ""
        powerfulModelIdentifier = defaults.string(forKey: Keys.powerfulModelIdentifier) ?? ""
        usePowerfulModel = defaults.bool(forKey: Keys.usePowerfulModel)
        coordinateConventionChoice = CoordinateConventionChoice(rawValue: defaults.string(forKey: Keys.coordinateConventionChoice) ?? "") ?? .automatic
        responseLanguage = ResponseLanguage(rawValue: defaults.string(forKey: Keys.responseLanguage) ?? "") ?? .romanian
        speakResponses = defaults.bool(forKey: Keys.speakResponses)
        speechVoiceIdentifier = defaults.string(forKey: Keys.speechVoiceIdentifier) ?? ""
        speechRateMultiplier = defaults.double(forKey: Keys.speechRateMultiplier)
        transcriptionEngine = TranscriptionEngine(rawValue: defaults.string(forKey: Keys.transcriptionEngine) ?? "") ?? .whisperKit
        whisperModelVariant = WhisperModelVariant(rawValue: defaults.string(forKey: Keys.whisperModelVariant) ?? "") ?? .small
        talkCombination = ModifierKeys(rawValue: defaults.integer(forKey: Keys.talkCombination))
        let storedDictationCombination = defaults.integer(forKey: Keys.dictationCombination)
        dictationCombination = storedDictationCombination == 0 ? nil : ModifierKeys(rawValue: storedDictationCombination)
        captureAllScreens = defaults.bool(forKey: Keys.captureAllScreens)
        maximumScreenshotLongEdge = defaults.integer(forKey: Keys.maximumScreenshotLongEdge)
        excludedApplicationBundleIdentifiers = defaults.stringArray(forKey: Keys.excludedApplicationBundleIdentifiers) ?? Self.defaultExcludedApplicationBundleIdentifiers
        actionMode = ActionMode(rawValue: defaults.string(forKey: Keys.actionMode) ?? "") ?? .askFirst
        drawingEnabled = defaults.bool(forKey: Keys.drawingEnabled)
        notchPanelEnabled = defaults.bool(forKey: Keys.notchPanelEnabled)
        showMenuBarIcon = defaults.bool(forKey: Keys.showMenuBarIcon)
        disableModelReasoning = defaults.bool(forKey: Keys.disableModelReasoning)
        quickCommandsEnabled = defaults.bool(forKey: Keys.quickCommandsEnabled)
        modelsRejectingReasoningSetting = Set(defaults.stringArray(forKey: Keys.modelsRejectingReasoningSetting) ?? [])
        rememberedExchangeCount = defaults.integer(forKey: Keys.rememberedExchangeCount)
        memoryEnabled = defaults.bool(forKey: Keys.memoryEnabled)
        learnedProceduresEnabled = defaults.bool(forKey: Keys.learnedProceduresEnabled)
        historyEnabled = defaults.bool(forKey: Keys.historyEnabled)
        modelsWithoutToolCalling = Set(defaults.stringArray(forKey: Keys.modelsWithoutToolCalling) ?? [])
    }

    var activeModelIdentifier: String {
        usePowerfulModel ? powerfulModelIdentifier : fastModelIdentifier
    }

    func coordinateConvention(forModelIdentifier modelIdentifier: String) -> CoordinateConvention {
        switch coordinateConventionChoice {
        case .automatic: return CoordinateConvention.recommended(forModelIdentifier: modelIdentifier)
        case .imagePixels: return .imagePixels
        case .normalizedTo1000: return .normalizedTo1000
        }
    }

    func shouldUseToolCalling(forModelIdentifier modelIdentifier: String, catalogModel: ModelSummary?) -> Bool {
        if modelsWithoutToolCalling.contains(modelIdentifier) { return false }
        // When the catalog is unknown we try tools first and fall back automatically.
        return catalogModel?.supportsToolCalling ?? true
    }

    func markModelWithoutToolCalling(_ modelIdentifier: String) {
        modelsWithoutToolCalling.insert(modelIdentifier)
    }

    func shouldDisableReasoning(forModelIdentifier modelIdentifier: String) -> Bool {
        disableModelReasoning && !modelsRejectingReasoningSetting.contains(modelIdentifier)
    }

    func markModelRejectingReasoningSetting(_ modelIdentifier: String) {
        modelsRejectingReasoningSetting.insert(modelIdentifier)
    }

    /// Fills empty model slots with the newest suitable models from the catalog.
    func applyDefaultModelsIfNeeded(from models: [ModelSummary]) {
        if fastModelIdentifier.isEmpty, let fastModel = ModelCatalog.defaultFastModel(in: models) {
            fastModelIdentifier = fastModel.id
        }
        if powerfulModelIdentifier.isEmpty, let powerfulModel = ModelCatalog.defaultPowerfulModel(in: models) {
            powerfulModelIdentifier = powerfulModel.id
        }
    }

    private enum Keys {
        static let fastModelIdentifier = "fastModelIdentifier"
        static let powerfulModelIdentifier = "powerfulModelIdentifier"
        static let usePowerfulModel = "usePowerfulModel"
        static let coordinateConventionChoice = "coordinateConventionChoice"
        static let responseLanguage = "responseLanguage"
        static let speakResponses = "speakResponses"
        static let speechVoiceIdentifier = "speechVoiceIdentifier"
        static let speechRateMultiplier = "speechRateMultiplier"
        static let transcriptionEngine = "transcriptionEngine"
        static let whisperModelVariant = "whisperModelVariant"
        static let talkCombination = "talkCombination"
        static let dictationCombination = "dictationCombination"
        static let captureAllScreens = "captureAllScreens"
        static let maximumScreenshotLongEdge = "maximumScreenshotLongEdge"
        static let excludedApplicationBundleIdentifiers = "excludedApplicationBundleIdentifiers"
        static let rememberedExchangeCount = "rememberedExchangeCount"
        static let modelsWithoutToolCalling = "modelsWithoutToolCalling"
        static let actionMode = "actionMode"
        static let drawingEnabled = "drawingEnabled"
        static let notchPanelEnabled = "notchPanelEnabled"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let disableModelReasoning = "disableModelReasoning"
        static let quickCommandsEnabled = "quickCommandsEnabled"
        static let modelsRejectingReasoningSetting = "modelsRejectingReasoningSetting"
        static let memoryEnabled = "memoryEnabled"
        static let learnedProceduresEnabled = "learnedProceduresEnabled"
        static let historyEnabled = "historyEnabled"
    }
}
