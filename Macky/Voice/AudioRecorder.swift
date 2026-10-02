import AudioToolbox
import AVFoundation

struct RecordedAudio {
    /// 16 kHz mono Float32 samples, the format Whisper expects.
    var samples: [Float]
    /// The microphone it came from, for error messages.
    var microphoneName: String?
    var durationInSeconds: Double { Double(samples.count) / AudioRecorder.transcriptionSampleRate }

    /// The loudest tenth of a second (RMS). Near zero means the microphone delivered silence.
    var peakLevel: Float {
        let window = Int(AudioRecorder.transcriptionSampleRate / 10)
        guard !samples.isEmpty else { return 0 }
        var peak: Float = 0
        var start = 0
        while start < samples.count {
            let end = min(start + window, samples.count)
            var sum: Float = 0
            for index in start..<end { sum += samples[index] * samples[index] }
            peak = max(peak, (sum / Float(end - start)).squareRoot())
            start = end
        }
        return peak
    }
}

enum AudioRecorderError: LocalizedError {
    case noInputDevice
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .noInputDevice: return "Nu găsesc niciun microfon."
        case .unsupportedFormat: return "Formatul microfonului nu poate fi convertit."
        }
    }
}

/// Records the microphone while the talk hotkey is held, converting on the fly to 16 kHz mono.
final class AudioRecorder {
    static let transcriptionSampleRate: Double = 16_000

    /// Called on the main thread with a 0...1 loudness value, used for the waveform.
    var onAudioLevel: ((Float) -> Void)?
    /// Called on the main thread for every converted chunk: its raw loudness (RMS) and its length in samples.
    var onAudioChunk: ((Float, Int) -> Void)?

    private var audioEngine: AVAudioEngine?
    private let recordedSamplesLock = NSLock()
    private var recordedSamples: [Float] = []

    var isRecording: Bool { audioEngine != nil }

    /// The microphone preference from settings (see AudioInputDevices).
    var microphonePreference = AudioInputDevices.automaticPreference
    private(set) var currentMicrophoneName: String?
    private var configurationObserver: NSObjectProtocol?

    func startRecording() throws {
        stopEngine()
        recordedSamplesLock.lock()
        recordedSamples.removeAll(keepingCapacity: true)
        recordedSamplesLock.unlock()
        try startEngine()
    }

    /// Starts (or restarts, after the device changed) the engine without clearing what was recorded.
    private func startEngine() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let chosenDevice = AudioInputDevices.resolve(preference: microphonePreference)
        if let chosenDevice, let audioUnit = inputNode.audioUnit {
            var deviceID = chosenDevice.id
            AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        currentMicrophoneName = chosenDevice?.name ?? AudioInputDevices.systemDefault()?.name
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioRecorderError.noInputDevice
        }
        guard let transcriptionFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.transcriptionSampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: transcriptionFormat) else {
            throw AudioRecorderError.unsupportedFormat
        }

        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.convertAndStore(buffer, converter: converter, transcriptionFormat: transcriptionFormat)
        }
        engine.prepare()
        try engine.start()
        audioEngine = engine

        // Headphones connecting, or switching to their headset mode, change the format mid-recording:
        // without a restart the engine stops delivering sound.
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, self.audioEngine === engine else { return }
            self.stopEngine()
            try? self.startEngine()
        }
    }

    func stopRecording() -> RecordedAudio {
        stopEngine()
        recordedSamplesLock.lock()
        let samples = recordedSamples
        recordedSamples.removeAll()
        recordedSamplesLock.unlock()
        return RecordedAudio(samples: samples, microphoneName: currentMicrophoneName)
    }

    /// A copy of everything recorded so far, while recording continues.
    func snapshotSamples() -> [Float] {
        recordedSamplesLock.lock()
        defer { recordedSamplesLock.unlock() }
        return recordedSamples
    }

    private func stopEngine() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        guard let audioEngine else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        self.audioEngine = nil
    }

    /// Runs on the audio thread.
    private func convertAndStore(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, transcriptionFormat: AVAudioFormat) {
        let ratio = transcriptionFormat.sampleRate / buffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: transcriptionFormat, frameCapacity: outputCapacity) else { return }

        // The converter pulls input through this block; we hand it exactly one buffer per call.
        // Reusing the same converter across calls keeps the resampler's state continuous.
        var hasProvidedInputBuffer = false
        var conversionError: NSError?
        converter.convert(to: convertedBuffer, error: &conversionError) { _, inputStatus in
            if hasProvidedInputBuffer {
                inputStatus.pointee = .noDataNow
                return nil
            }
            hasProvidedInputBuffer = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard conversionError == nil, let channelData = convertedBuffer.floatChannelData else { return }

        let frameCount = Int(convertedBuffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        recordedSamplesLock.lock()
        recordedSamples.append(contentsOf: samples)
        recordedSamplesLock.unlock()

        let audioLevel = Self.normalizedLevel(of: samples)
        let rootMeanSquare = samples.isEmpty ? 0 : (samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
        let chunkSampleCount = samples.count
        DispatchQueue.main.async { [weak self] in
            self?.onAudioLevel?(audioLevel)
            self?.onAudioChunk?(rootMeanSquare, chunkSampleCount)
        }
    }

    /// Maps RMS loudness from -50 dB (silence) ... 0 dB (very loud) onto 0...1.
    private static func normalizedLevel(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let meanSquare = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)
        let decibels = 10 * log10(max(meanSquare, 1e-10))
        return min(max((decibels + 50) / 50, 0), 1)
    }
}
