import AVFoundation

/// Speaks answers sentence by sentence with the free voices built into macOS.
/// Tip: System Settings → Accessibility → Spoken Content → System Voice → Manage Voices
/// lets you download the "Enhanced"/"Premium" voices (e.g. Ioana for Romanian), which sound much better.
@MainActor
final class SpeechSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    /// Tracks queued utterances by identity so a late "cancelled" callback from a previous
    /// answer can never be mistaken for the end of the current one.
    private var pendingUtteranceIdentifiers: Set<ObjectIdentifier> = []

    var onAllSpeechFinished: (() -> Void)?

    var isSpeaking: Bool { !pendingUtteranceIdentifiers.isEmpty }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, voiceIdentifier: String, languageCode: String?, rateMultiplier: Double) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: trimmedText)
        utterance.voice = Self.voice(identifier: voiceIdentifier, languageCode: languageCode)
        let rate = AVSpeechUtteranceDefaultSpeechRate * Float(rateMultiplier)
        utterance.rate = min(max(rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
        pendingUtteranceIdentifiers.insert(ObjectIdentifier(utterance))
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        pendingUtteranceIdentifiers.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let utteranceIdentifier = ObjectIdentifier(utterance)
        Task { @MainActor in
            self.utteranceEnded(utteranceIdentifier)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let utteranceIdentifier = ObjectIdentifier(utterance)
        Task { @MainActor in
            self.utteranceEnded(utteranceIdentifier)
        }
    }

    private func utteranceEnded(_ utteranceIdentifier: ObjectIdentifier) {
        guard pendingUtteranceIdentifiers.remove(utteranceIdentifier) != nil else { return }
        if pendingUtteranceIdentifiers.isEmpty {
            onAllSpeechFinished?()
        }
    }

    static func voice(identifier: String, languageCode: String?) -> AVSpeechSynthesisVoice? {
        if !identifier.isEmpty, let chosenVoice = AVSpeechSynthesisVoice(identifier: identifier) {
            return chosenVoice
        }
        guard let languageCode else { return nil }
        return bestVoice(forLanguageCode: languageCode)
    }

    /// Highest quality installed voice for a language ("ro" matches "ro-RO").
    static func bestVoice(forLanguageCode languageCode: String) -> AVSpeechSynthesisVoice? {
        availableVoices(forLanguageCode: languageCode).first
    }

    static func availableVoices(forLanguageCode languageCode: String?) -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { voice in
                guard let languageCode else { return true }
                return voice.language.lowercased().hasPrefix(languageCode.lowercased())
            }
            .sorted { first, second in
                if first.quality != second.quality { return first.quality.rawValue > second.quality.rawValue }
                return first.name < second.name
            }
    }

    static func qualityDescription(of voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Standard"
        }
    }
}
