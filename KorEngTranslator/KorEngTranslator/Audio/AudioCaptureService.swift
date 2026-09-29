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

    // ~100ms chunks (1600 samples at 16kHz after conversion)
    private let chunkDuration: Double = 0.1

    // Extra output frames for resampler state carried between buffers
    private let converterFrameSlack: AVAudioFrameCount = 64

    // Audio level smoothing
    private var levelSmoothing: Float = 0.3

    // MARK: - Initialization

    init() {}

    // MARK: - Public Interface

    /// Start capturing audio with a callback (convenience method)
    /// - Parameter callback: Called with audio data and normalized audio level (0-1)
    /// - Returns: true if capture is running, false if it failed to start
    @discardableResult
    func startCapturing(callback: @escaping (Data, Float) -> Void) -> Bool {
        self.onAudioDataWithLevel = callback
        do {
            try startCapture()
            return true
        } catch {
            print("[AudioCaptureService] Failed to start: \(error)")
            self.onAudioDataWithLevel = nil
            return false
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

        // Mic permission not granted yet -> 0Hz/0ch format; installTap would raise
        // an uncatchable ObjC exception. Turn it into a thrown Swift error.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioCaptureError.invalidFormat
        }

        // Create target format (16kHz, mono, PCM float for processing)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: false
        ) else {
            throw AudioCaptureError.invalidFormat
        }

        // One converter per capture session, reused for every tap buffer so the
        // resampler keeps its state across chunk edges (only needed if formats differ)
        let converter: AVAudioConverter?
        if inputFormat.sampleRate != targetSampleRate || inputFormat.channelCount != targetChannels {
            guard let sessionConverter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                throw AudioCaptureError.invalidFormat
            }
            converter = sessionConverter
        } else {
            converter = nil
        }

        // Install tap on input node (buffer size in input-format frames for ~100ms)
        let tapBufferSize = AVAudioFrameCount(inputFormat.sampleRate * chunkDuration)
        inputNode.installTap(
            onBus: 0,
            bufferSize: tapBufferSize,
            format: inputFormat
        ) { [weak self] buffer, time in
            self?.processAudioBuffer(buffer, converter: converter)
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
        converter: AVAudioConverter?
    ) {
        // Convert buffer to target format if needed
        let convertedBuffer: AVAudioPCMBuffer

        if let converter = converter {
            guard let converted = convertBuffer(buffer, using: converter) else {
                print("[AudioCaptureService] Failed to convert buffer")
                return
            }
            // Resampler may hold back a few frames at the start; nothing to send yet
            guard converted.frameLength > 0 else { return }
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
        using converter: AVAudioConverter
    ) -> AVAudioPCMBuffer? {
        let inputFormat = converter.inputFormat
        let outputFormat = converter.outputFormat

        // Calculate output frame capacity based on sample rate ratio
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + converterFrameSlack

        // Hand this tap buffer over exactly once, then report .noDataNow so the converter
        // returns what it has and waits for the next buffer (keeps resampler state intact)
        nonisolated(unsafe) var bufferConsumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if bufferConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            bufferConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        // Convert until the converter asks for more input (.inputRanDry). A full output buffer
        // (.haveData) means it may not be done reading this tap buffer yet, and the engine can
        // reuse that memory once we return - so drain into another pass (usually just one)
        var passes: [AVAudioPCMBuffer] = []
        var status: AVAudioConverterOutputStatus = .haveData
        while status == .haveData {
            guard let pass = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: outputFrameCapacity
            ) else {
                return nil
            }

            var error: NSError?
            status = converter.convert(to: pass, error: &error, withInputFrom: inputBlock)

            if status == .error || error != nil {
                print("[AudioCaptureService] Conversion error: \(error?.localizedDescription ?? "unknown")")
                return nil
            }
            guard pass.frameLength > 0 else { break }
            passes.append(pass)
        }

        return joinBuffers(passes, format: outputFormat)
    }

    /// Join conversion passes into a single buffer (returns the pass itself when there's only one)
    private func joinBuffers(_ buffers: [AVAudioPCMBuffer], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffers.count == 1 {
            return buffers[0]
        }

        let totalFrames = buffers.reduce(AVAudioFrameCount(0)) { $0 + $1.frameLength }
        guard let joined = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(totalFrames, 1)),
              let joinedData = joined.floatChannelData else {
            return nil
        }

        for channel in 0..<Int(format.channelCount) {
            var offset = 0
            for buffer in buffers {
                guard let source = buffer.floatChannelData else { return nil }
                let frames = Int(buffer.frameLength)
                joinedData[channel].advanced(by: offset).update(from: source[channel], count: frames)
                offset += frames
            }
        }
        joined.frameLength = totalFrames

        return joined
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
