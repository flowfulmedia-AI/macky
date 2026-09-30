import AVFoundation
import Foundation
import MackyCore
import Speech
import WhisperKit

protocol SpeechTranscriber: Sendable {
    /// Loads (and on first use downloads) whatever the transcriber needs. Safe to call repeatedly.
    func prepare() async throws
    /// `languageCode` is an ISO code such as "ro"; nil means detect automatically.
    func transcribe(samples: [Float], languageCode: String?) async throws -> String
}

enum SpeechTranscriberError: LocalizedError {
    case speechRecognitionNotAuthorized
    case recognizerUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .speechRecognitionNotAuthorized:
            return "Macky nu are voie să folosească recunoașterea vocală Apple (System Settings → Privacy & Security → Speech Recognition)."
        case .recognizerUnavailable(let localeIdentifier):
            return "Recunoașterea vocală Apple nu e disponibilă pentru \(localeIdentifier)."
        }
    }
}

/// Whisper running fully on the Mac through WhisperKit (Core ML). Free and private:
/// audio never leaves the computer. The model is downloaded once into Application Support.
actor WhisperKitTranscriber: SpeechTranscriber {
    private let modelVariant: String
    private var whisperKit: WhisperKit?
    private var loadingTask: Task<WhisperKit, Error>?

    init(modelVariant: String) {
        self.modelVariant = modelVariant
    }

    func prepare() async throws {
        _ = try await loadedWhisperKit()
    }

    func transcribe(samples: [Float], languageCode: String?) async throws -> String {
        let whisperKit = try await loadedWhisperKit()
        var decodingOptions = DecodingOptions()
        decodingOptions.task = .transcribe
        decodingOptions.language = languageCode
        decodingOptions.detectLanguage = languageCode == nil
        // Forcing the language token avoids Whisper answering in English for Romanian speech.
        decodingOptions.usePrefillPrompt = languageCode != nil
        decodingOptions.temperature = 0
        decodingOptions.skipSpecialTokens = true
        decodingOptions.withoutTimestamps = true
        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: decodingOptions)
        return results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A long recording (e.g. a meeting), with the time each passage starts.
    func transcribeFile(at fileURL: URL, languageCode: String?) async throws -> [TranscriptLine] {
        let whisperKit = try await loadedWhisperKit()
        var decodingOptions = DecodingOptions()
        decodingOptions.task = .transcribe
        decodingOptions.language = languageCode
        decodingOptions.detectLanguage = languageCode == nil
        decodingOptions.usePrefillPrompt = languageCode != nil
        decodingOptions.temperature = 0
        decodingOptions.skipSpecialTokens = true
        decodingOptions.withoutTimestamps = false
        // Splits long audio at pauses and transcribes the pieces in parallel.
        decodingOptions.chunkingStrategy = .vad
        let results = try await whisperKit.transcribe(audioPath: fileURL.path, decodeOptions: decodingOptions)
        let lines = results.flatMap(\.segments).map { segment in
            TranscriptLine(startSeconds: Double(segment.start), speaker: nil, text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return TranscriptFormatter.mergingConsecutiveSpeakers(lines.sorted { $0.startSeconds < $1.startSeconds })
    }

    private func loadedWhisperKit() async throws -> WhisperKit {
        if let whisperKit { return whisperKit }
        if let loadingTask { return try await loadingTask.value }

        let modelVariant = self.modelVariant
        let modelsDirectory = ApplicationDirectories.applicationSupportDirectory.appendingPathComponent("WhisperModels", isDirectory: true)
        let task = Task { () throws -> WhisperKit in
            let configuration = WhisperKitConfig(model: modelVariant)
            // Keep downloads out of ~/Documents so macOS does not ask for Documents folder access.
            configuration.downloadBase = modelsDirectory
            configuration.verbose = false
            configuration.prewarm = true
            configuration.load = true
            configuration.download = true
            return try await WhisperKit(configuration)
        }
        loadingTask = task
        do {
            let loadedWhisperKit = try await task.value
            whisperKit = loadedWhisperKit
            loadingTask = nil
            return loadedWhisperKit
        } catch {
            loadingTask = nil
            throw error
        }
    }
}

/// Apple's speech recognizer. Used as a fallback; for Romanian it may send audio to Apple's servers.
final class AppleSpeechTranscriber: SpeechTranscriber, @unchecked Sendable {
    private var activeRecognizer: SFSpeechRecognizer?
    private var activeRecognitionTask: SFSpeechRecognitionTask?

    func prepare() async throws {
        let authorizationStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard authorizationStatus == .authorized else {
            throw SpeechTranscriberError.speechRecognitionNotAuthorized
        }
    }

    func transcribe(samples: [Float], languageCode: String?) async throws -> String {
        guard !samples.isEmpty else { return "" }
        let localeIdentifier: String
        switch languageCode {
        case "ro": localeIdentifier = "ro-RO"
        case "en": localeIdentifier = "en-US"
        default: localeIdentifier = Locale.current.identifier
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)), recognizer.isAvailable else {
            throw SpeechTranscriberError.recognizerUnavailable(localeIdentifier)
        }
        guard let audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.transcriptionSampleRate, channels: 1, interleaved: false),
              let audioBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channelData = audioBuffer.floatChannelData else {
            throw AudioRecorderError.unsupportedFormat
        }
        audioBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { samplePointer in
            if let baseAddress = samplePointer.baseAddress {
                channelData[0].update(from: baseAddress, count: samples.count)
            }
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.append(audioBuffer)
        request.endAudio()

        activeRecognizer = recognizer
        return try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false
            activeRecognitionTask = recognizer.recognitionTask(with: request) { result, error in
                guard !hasResumed else { return }
                if let result, result.isFinal {
                    hasResumed = true
                    continuation.resume(returning: result.bestTranscription.formattedString)
                } else if let error {
                    hasResumed = true
                    // "No speech detected" is reported as an error; treat it as an empty transcript.
                    let nsError = error as NSError
                    if nsError.domain == "kAFAssistantErrorDomain" && (nsError.code == 1110 || nsError.code == 203) {
                        continuation.resume(returning: "")
                    } else {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
}
