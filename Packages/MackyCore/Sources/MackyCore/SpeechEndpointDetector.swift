import Foundation

/// Notices when the user has stopped talking while still holding the hotkey.
/// Most people finish their sentence a moment before letting go of the keys; transcribing
/// right at that moment means the text is usually ready the instant the keys are released.
public struct SpeechEndpointDetector {
    /// Loudness (RMS) that clearly counts as a voice.
    public static let speechLevel: Float = 0.02
    /// Quiet enough to be a pause, relative to how loud the user speaks.
    public static let relativeSilenceLevel: Float = 0.15
    public static let absoluteSilenceLevel: Float = 0.008

    public private(set) var totalSampleCount = 0
    public private(set) var hasHeardSpeech = false
    public private(set) var loudestLevel: Float = 0
    /// Where the current stretch of silence began; nil while the user is talking.
    public private(set) var trailingSilenceStartSample: Int?

    public init() {}

    public mutating func append(chunkLevel: Float, sampleCount: Int) {
        let chunkStartSample = totalSampleCount
        totalSampleCount += sampleCount
        loudestLevel = max(loudestLevel, chunkLevel)
        if chunkLevel >= Self.speechLevel { hasHeardSpeech = true }

        let silenceThreshold = max(Self.absoluteSilenceLevel, loudestLevel * Self.relativeSilenceLevel)
        if chunkLevel < silenceThreshold {
            if trailingSilenceStartSample == nil { trailingSilenceStartSample = chunkStartSample }
        } else {
            trailingSilenceStartSample = nil
        }
    }

    public func trailingSilenceDuration(sampleRate: Double) -> Double {
        guard let trailingSilenceStartSample else { return 0 }
        return Double(totalSampleCount - trailingSilenceStartSample) / sampleRate
    }

    /// True when the user spoke and has now been quiet for at least `minimumPause` seconds.
    public func hasSpeechEnded(minimumPause: Double, sampleRate: Double) -> Bool {
        hasHeardSpeech && trailingSilenceDuration(sampleRate: sampleRate) >= minimumPause
    }

    /// True when everything recorded after `sampleIndex` is silence, so a transcript
    /// of the first `sampleIndex` samples already contains everything that was said.
    public func isSilentAfter(sampleIndex: Int) -> Bool {
        guard let trailingSilenceStartSample else { return sampleIndex >= totalSampleCount }
        return trailingSilenceStartSample <= sampleIndex
    }
}
