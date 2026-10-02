import AVFoundation
import CoreMedia

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

/// Records the microphone while the talk hotkey is held, as 16 kHz mono.
/// Uses a capture session on one chosen microphone: unlike AVAudioEngine it does not depend on (or change)
/// the Mac's sound settings, so Bluetooth headphones can keep playing while the Mac's own microphone listens.
final class AudioRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    static let transcriptionSampleRate: Double = 16_000

    /// Called on the main thread with a 0...1 loudness value, used for the waveform.
    var onAudioLevel: ((Float) -> Void)?
    /// Called on the main thread for every converted chunk: its raw loudness (RMS) and its length in samples.
    var onAudioChunk: ((Float, Int) -> Void)?
    /// The microphone preference from settings (see AudioInputDevices).
    var microphonePreference = AudioInputDevices.automaticPreference
    private(set) var currentMicrophoneName: String?

    private let captureQueue = DispatchQueue(label: "macky.audio.capture")
    private var captureSession: AVCaptureSession?
    private let recordedSamplesLock = NSLock()
    private var recordedSamples: [Float] = []
    private var converter: AVAudioConverter?
    private let transcriptionFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    var isRecording: Bool { captureSession != nil }

    func startRecording() throws {
        stopSession()
        recordedSamplesLock.lock()
        recordedSamples.removeAll(keepingCapacity: true)
        recordedSamplesLock.unlock()

        guard let device = Self.captureDevice(for: microphonePreference) else { throw AudioRecorderError.noInputDevice }
        currentMicrophoneName = device.localizedName
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw AudioRecorderError.noInputDevice }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        // Ask for Whisper's format directly; anything else is converted below.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.transcriptionSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        output.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(output) else { throw AudioRecorderError.unsupportedFormat }
        session.addOutput(output)
        captureSession = session
        converter = nil
        captureQueue.async { session.startRunning() }
    }

    func stopRecording() -> RecordedAudio {
        stopSession()
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

    private func stopSession() {
        guard let captureSession else { return }
        self.captureSession = nil
        // Runs after every sample already queued, so nothing said before releasing the keys is lost.
        captureQueue.sync { captureSession.stopRunning() }
    }

    /// The chosen microphone (see AudioInputDevices), or the Mac's default one.
    private static func captureDevice(for preference: String) -> AVCaptureDevice? {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        if let wanted = AudioInputDevices.resolve(preference: preference),
           let device = devices.first(where: { $0.uniqueID == wanted.uid }) {
            return device
        }
        return AVCaptureDevice.default(for: .audio) ?? devices.first
    }

    // MARK: Capture (on captureQueue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescriptionPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else { return }
        var streamDescription = streamDescriptionPointer.pointee
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0, let inputFormat = AVAudioFormat(streamDescription: &streamDescription),
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        inputBuffer.frameLength = AVAudioFrameCount(frameCount)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frameCount),
                                                           into: inputBuffer.mutableAudioBufferList) == noErr else { return }

        var samples: [Float]
        if inputFormat.commonFormat == .pcmFormatFloat32, inputFormat.sampleRate == Self.transcriptionSampleRate,
           inputFormat.channelCount == 1, let channelData = inputBuffer.floatChannelData {
            samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(inputBuffer.frameLength)))
        } else {
            samples = convert(inputBuffer)
        }
        // A misbehaving device can deliver NaN, which makes Whisper loop for minutes.
        for index in samples.indices where !samples[index].isFinite { samples[index] = 0 }
        store(samples)
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: transcriptionFormat)
        }
        guard let converter else { return [] }
        let ratio = transcriptionFormat.sampleRate / buffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: transcriptionFormat, frameCapacity: outputCapacity) else { return [] }
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
        guard conversionError == nil, let channelData = convertedBuffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(convertedBuffer.frameLength)))
    }

    private func store(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        recordedSamplesLock.lock()
        recordedSamples.append(contentsOf: samples)
        recordedSamplesLock.unlock()

        let meanSquare = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)
        let rootMeanSquare = meanSquare.squareRoot()
        let audioLevel = Self.normalizedLevel(meanSquare: meanSquare)
        let chunkSampleCount = samples.count
        DispatchQueue.main.async { [weak self] in
            self?.onAudioLevel?(audioLevel)
            self?.onAudioChunk?(rootMeanSquare, chunkSampleCount)
        }
    }

    /// Maps RMS loudness from -50 dB (silence) ... 0 dB (very loud) onto 0...1.
    private static func normalizedLevel(meanSquare: Float) -> Float {
        let decibels = 10 * log10(max(meanSquare, 1e-10))
        return min(max((decibels + 50) / 50, 0), 1)
    }
}
