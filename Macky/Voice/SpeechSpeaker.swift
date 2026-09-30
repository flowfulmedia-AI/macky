import AVFoundation

/// Speaks answers sentence by sentence, in order.
/// - Neural voices (Microsoft Edge's free Alina/Emil): each sentence is fetched as soon as it is queued,
///   so the next one is usually ready before the current one ends. Short phrases are cached.
/// - Mac voices (AVSpeechSynthesizer): offline, and the automatic fallback when the neural service
///   cannot be reached (then it is not tried again for a few minutes).
/// Tip for Mac voices: System Settings → Accessibility → Spoken Content → System Voice → Manage Voices
/// lets you download the "Enhanced"/"Premium" voices (e.g. Ioana for Romanian).
@MainActor
final class SpeechSpeaker: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    private struct Segment {
        let identifier = UUID()
        let text: String
        let systemVoiceIdentifier: String
        let languageCode: String?
        let rateMultiplier: Double
        var neuralAudioTask: Task<Data?, Never>?
    }

    private let synthesizer = AVSpeechSynthesizer()
    private let edgeClient = EdgeTTSClient()
    private var queuedSegments: [Segment] = []
    private var currentSegmentIdentifier: UUID?
    private var audioPlayer: AVAudioPlayer?
    /// Links finished utterances and players back to their segment.
    private var segmentIdentifiersByPlayback: [ObjectIdentifier: UUID] = [:]
    private var neuralVoiceUnavailableUntil: Date?
    /// Audio of short, frequent phrases ("Sigur!", "Gata.") so they play instantly.
    private var shortPhraseCache: [String: Data] = [:]

    var onAllSpeechFinished: (() -> Void)?

    var isSpeaking: Bool { currentSegmentIdentifier != nil || !queuedSegments.isEmpty }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// `neuralVoice` is an Edge voice name (e.g. "ro-RO-AlinaNeural"), or nil for the Mac voice.
    func speak(_ text: String, voiceIdentifier: String, languageCode: String?, rateMultiplier: Double, neuralVoice: String? = nil) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        var segment = Segment(text: trimmedText, systemVoiceIdentifier: voiceIdentifier, languageCode: languageCode, rateMultiplier: rateMultiplier)
        if let neuralVoice, isNeuralVoiceAvailable {
            segment.neuralAudioTask = neuralAudioTask(for: trimmedText, voice: neuralVoice, rateMultiplier: rateMultiplier)
        }
        queuedSegments.append(segment)
        playNextSegmentIfIdle()
    }

    /// Fetches common short phrases ahead of time, so the first "Sigur!" is instant too.
    func prepareShortPhrases(_ phrases: [String], neuralVoice: String, rateMultiplier: Double) {
        guard isNeuralVoiceAvailable else { return }
        for phrase in phrases where shortPhraseCache[cacheKey(phrase, neuralVoice, rateMultiplier)] == nil {
            _ = neuralAudioTask(for: phrase, voice: neuralVoice, rateMultiplier: rateMultiplier)
        }
    }

    func stopSpeaking() {
        for segment in queuedSegments { segment.neuralAudioTask?.cancel() }
        queuedSegments.removeAll()
        currentSegmentIdentifier = nil
        audioPlayer?.stop()
        audioPlayer = nil
        segmentIdentifiersByPlayback.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
    }

    private var isNeuralVoiceAvailable: Bool {
        guard let neuralVoiceUnavailableUntil else { return true }
        return Date() >= neuralVoiceUnavailableUntil
    }

    private func cacheKey(_ text: String, _ voice: String, _ rateMultiplier: Double) -> String {
        "\(voice)|\(Int(rateMultiplier * 100))|\(text)"
    }

    private func neuralAudioTask(for text: String, voice: String, rateMultiplier: Double) -> Task<Data?, Never> {
        let key = cacheKey(text, voice, rateMultiplier)
        if let cachedAudio = shortPhraseCache[key] {
            return Task { cachedAudio }
        }
        let ratePercent = min(max(Int((rateMultiplier - 1) * 100), -50), 100)
        let edgeClient = self.edgeClient
        return Task { [weak self] in
            let audio = await edgeClient.synthesize(text, voice: voice, ratePercent: ratePercent)
            if let audio, text.count <= 40 {
                await MainActor.run {
                    guard let self else { return }
                    if self.shortPhraseCache.count > 60 { self.shortPhraseCache.removeAll() }
                    self.shortPhraseCache[key] = audio
                }
            }
            return audio
        }
    }

    private func playNextSegmentIfIdle() {
        guard currentSegmentIdentifier == nil, !queuedSegments.isEmpty else { return }
        let segment = queuedSegments.removeFirst()
        currentSegmentIdentifier = segment.identifier
        guard let neuralAudioTask = segment.neuralAudioTask else {
            speakWithMacVoice(segment)
            return
        }
        Task {
            let audio = await neuralAudioTask.value
            guard currentSegmentIdentifier == segment.identifier else { return }
            if let audio, let player = try? AVAudioPlayer(data: audio) {
                player.delegate = self
                audioPlayer = player
                segmentIdentifiersByPlayback[ObjectIdentifier(player)] = segment.identifier
                if player.play() { return }
            }
            // The service is unreachable or changed: use the Mac voice for a while.
            neuralVoiceUnavailableUntil = Date().addingTimeInterval(5 * 60)
            speakWithMacVoice(segment)
        }
    }

    private func speakWithMacVoice(_ segment: Segment) {
        let utterance = AVSpeechUtterance(string: segment.text)
        utterance.voice = Self.voice(identifier: segment.systemVoiceIdentifier, languageCode: segment.languageCode)
        let rate = AVSpeechUtteranceDefaultSpeechRate * Float(segment.rateMultiplier)
        utterance.rate = min(max(rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
        segmentIdentifiersByPlayback[ObjectIdentifier(utterance)] = segment.identifier
        synthesizer.speak(utterance)
    }

    private func playbackEnded(_ playbackIdentifier: ObjectIdentifier) {
        guard let segmentIdentifier = segmentIdentifiersByPlayback.removeValue(forKey: playbackIdentifier),
              segmentIdentifier == currentSegmentIdentifier else { return }
        currentSegmentIdentifier = nil
        audioPlayer = nil
        if queuedSegments.isEmpty {
            onAllSpeechFinished?()
        } else {
            playNextSegmentIfIdle()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let playbackIdentifier = ObjectIdentifier(utterance)
        Task { @MainActor in self.playbackEnded(playbackIdentifier) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let playbackIdentifier = ObjectIdentifier(utterance)
        Task { @MainActor in self.playbackEnded(playbackIdentifier) }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let playbackIdentifier = ObjectIdentifier(player)
        Task { @MainActor in self.playbackEnded(playbackIdentifier) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let playbackIdentifier = ObjectIdentifier(player)
        Task { @MainActor in self.playbackEnded(playbackIdentifier) }
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
