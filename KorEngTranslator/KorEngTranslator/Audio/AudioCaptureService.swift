import AVFoundation
import Combine

/// Protocol for receiving audio capture events
protocol AudioCaptureDelegate: AnyObject {
    func audioCaptureService(_ service: AudioCaptureService, didCaptureAudioData data: Data)
    func audioCaptureService(_ service: AudioCaptureService, didEncounterError error: Error)
}

/// Captures microphone audio using AVAudioEngine
/// Outputs PCM 16-bit mono at 16kHz in ~100ms chunks
@MainActor
class AudioCaptureService: ObservableObject {
    // MARK: - Singleton

    static let shared = AudioCaptureService()

    // MARK: - Published Properties

    @Published private(set) var isCapturing: Bool = false
    @Published private(set) var audioLevel: Float = 0.0

    // MARK: - Public Properties

    weak var delegate: AudioCaptureDelegate?

    /// Callback for audio data (alternative to delegate)
    var onAudioData: ((Data) -> Void)?

    /// Callback for audio data with level (for UI visualization)
    var onAudioDataWithLevel: ((Data, Float) -> Void)?

    // MARK: - Private Properties

    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?

    // Target format: 16kHz, mono, PCM 16-bit
    private let targetSampleRate: Double = 16000
    private let targetChannels: AVAudioChannelCount = 1

    // Buffer size for ~100ms chunks at 16kHz = 1600 samples
    private let bufferSize: AVAudioFrameCount = 1600

    // Audio level smoothing
    private var levelSmoothing: Float = 0.3

    // MARK: - Initialization

    init() {}

    // MARK: - Public Interface

    /// Start capturing audio with a callback (convenience method)
    /// - Parameter callback: Called with audio data and normalized audio level (0-1)
    func startCapturing(callback: @escaping (Data, Float) -> Void) {
        self.onAudioDataWithLevel = callback
        do {
            try startCapture()
        } catch {
            print("[AudioCaptureService] Failed to start: \(error)")
        }
    }

    /// Stop capturing audio (convenience method)
    func stopCapturing() {
        stopCapture()
        self.onAudioDataWithLevel = nil
    }

    /// Start capturing audio from the microphone
    func startCapture() throws {
        guard !isCapturing else { return }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Get the native format of the input
        let inputFormat = inputNode.outputFormat(forBus: 0)

        print("[AudioCaptureService] Input format: \(inputFormat)")

        // Create target format (16kHz, mono, PCM float for processing)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: false
        ) else {
            throw AudioCaptureError.invalidFormat
        }

        // Install tap on input node
        // Note: We need to convert from input format to target format
        inputNode.installTap(
            onBus: 0,
            bufferSize: bufferSize,
            format: inputFormat
        ) { [weak self] buffer, time in
            self?.processAudioBuffer(buffer, inputFormat: inputFormat, targetFormat: targetFormat)
        }

        // Prepare and start the engine
        engine.prepare()
        try engine.start()

        self.audioEngine = engine
        self.inputNode = inputNode
        self.isCapturing = true

        print("[AudioCaptureService] Started capturing audio")
    }

    /// Stop capturing audio
    func stopCapture() {
        guard isCapturing else { return }

        inputNode?.removeTap(onBus: 0)
        audioEngine?.stop()

        audioEngine = nil
        inputNode = nil
        isCapturing = false

        print("[AudioCaptureService] Stopped capturing audio")
    }

    // MARK: - Private Methods

    private func processAudioBuffer(
        _ buffer: AVAudioPCMBuffer,
        inputFormat: AVAudioFormat,
        targetFormat: AVAudioFormat
    ) {
        // Convert buffer to target format if needed
        let convertedBuffer: AVAudioPCMBuffer

        if inputFormat.sampleRate != targetSampleRate || inputFormat.channelCount != targetChannels {
            guard let converted = convertBuffer(buffer, from: inputFormat, to: targetFormat) else {
                print("[AudioCaptureService] Failed to convert buffer")
                return
            }
            convertedBuffer = converted
        } else {
            convertedBuffer = buffer
        }

        // Calculate audio level from float buffer
        let level = calculateAudioLevel(convertedBuffer)

        // Convert float samples to PCM 16-bit
        guard let pcmData = convertToPCM16(convertedBuffer) else {
            print("[AudioCaptureService] Failed to convert to PCM16")
            return
        }

        // Deliver audio data
        Task { @MainActor in
            // Update published audio level with smoothing
            self.audioLevel = self.audioLevel * self.levelSmoothing + level * (1 - self.levelSmoothing)

            // Call callbacks
            self.onAudioData?(pcmData)
            self.onAudioDataWithLevel?(pcmData, self.audioLevel)
            self.delegate?.audioCaptureService(self, didCaptureAudioData: pcmData)
        }
    }

    /// Calculate normalized audio level (0-1) from buffer
    private func calculateAudioLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let floatData = buffer.floatChannelData else { return 0 }

        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }

        // Calculate RMS (root mean square) for audio level
        var sum: Float = 0
        for i in 0..<frameLength {
            let sample = floatData[0][i]
            sum += sample * sample
        }

        let rms = sqrt(sum / Float(frameLength))

        // Convert to dB and normalize to 0-1 range
        // -60 dB = silence, 0 dB = max
        let db = 20 * log10(max(rms, 0.00001))
        let normalized = max(0, min(1, (db + 60) / 60))

        return normalized
    }

    private func convertBuffer(
        _ buffer: AVAudioPCMBuffer,
        from inputFormat: AVAudioFormat,
        to outputFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return nil
        }

        // Calculate output frame capacity based on sample rate ratio
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            return nil
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        if let error = error {
            print("[AudioCaptureService] Conversion error: \(error)")
            return nil
        }

        return outputBuffer
    }

    private func convertToPCM16(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let floatData = buffer.floatChannelData else {
            return nil
        }

        let frameLength = Int(buffer.frameLength)
        var pcmData = Data(capacity: frameLength * 2)  // 2 bytes per sample

        // Convert float32 [-1, 1] to int16 [-32768, 32767]
        for i in 0..<frameLength {
            let sample = floatData[0][i]
            let clampedSample = max(-1.0, min(1.0, sample))
            let int16Sample = Int16(clampedSample * 32767.0)

            // Append as little-endian bytes
            withUnsafeBytes(of: int16Sample.littleEndian) { bytes in
                pcmData.append(contentsOf: bytes)
            }
        }

        return pcmData
    }
}

// MARK: - Errors

enum AudioCaptureError: Error, LocalizedError {
    case invalidFormat
    case engineStartFailed
    case notCapturing

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "Failed to create audio format"
        case .engineStartFailed:
            return "Failed to start audio engine"
        case .notCapturing:
            return "Audio capture is not active"
        }
    }
}
