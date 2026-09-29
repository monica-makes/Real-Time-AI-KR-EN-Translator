import AVFoundation
import Combine

/// Plays audio received from the WebSocket (translated speech)
@MainActor
class AudioPlaybackService: NSObject, ObservableObject {
    // MARK: - Singleton

    static let shared = AudioPlaybackService()

    // MARK: - Published Properties

    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var queueCount: Int = 0

    /// True while translated audio is playing and for a short tail after the last queued clip,
    /// so capture can avoid re-transcribing our own speaker output
    @Published private(set) var isOutputActive: Bool = false

    // MARK: - Private Properties

    private var audioPlayer: AVAudioPlayer?
    private var audioQueue: [Data] = []
    private var isProcessingQueue: Bool = false

    // Covers output latency + room echo after the last clip ends
    private let outputTailNanoseconds: UInt64 = 350_000_000  // 0.35 seconds
    private var outputTailTask: Task<Void, Never>?

    // MARK: - Initialization

    override init() {
        super.init()
        setupAudioSession()
        observeInterruptions()
    }

    /// A phone call / Siri pauses the player without calling its delegate, which would leave
    /// isOutputActive stuck on (and the echo guard muting the mic). Drop the queue instead.
    private func observeInterruptions() {
        #if os(iOS)
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: rawType) == .began else { return }
            Task { @MainActor in
                print("[AudioPlaybackService] Audio session interrupted - clearing playback")
                self?.stopAndClear()
            }
        }
        #endif
    }

    private func setupAudioSession() {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch {
            print("[AudioPlaybackService] Failed to setup audio session: \(error)")
        }
        #endif
    }

    // MARK: - Public Methods

    /// Play audio data immediately (convenience method)
    /// - Parameter data: Audio data to play
    func playAudio(_ data: Data) {
        queueAudio(data)
    }

    /// Queue audio data for playback
    /// - Parameter data: One complete MP3 clip (backend sends one per phrase)
    func queueAudio(_ data: Data) {
        audioQueue.append(data)
        queueCount = audioQueue.count

        print("[AudioPlaybackService] Queued audio, queue size: \(audioQueue.count)")

        // Start processing queue if not already
        if !isProcessingQueue {
            processQueue()
        }
    }

    /// Queue audio from base64 encoded string
    /// - Parameter base64String: Base64 encoded audio data
    func queueAudio(base64String: String) {
        guard let data = Data(base64Encoded: base64String) else {
            print("[AudioPlaybackService] Failed to decode base64 audio")
            return
        }
        queueAudio(data)
    }

    /// Stop all playback and clear queue
    func stopAndClear() {
        audioPlayer?.stop()
        audioPlayer = nil
        audioQueue.removeAll()
        queueCount = 0
        isPlaying = false
        isProcessingQueue = false

        outputTailTask?.cancel()
        outputTailTask = nil
        isOutputActive = false

        print("[AudioPlaybackService] Stopped and cleared queue")
    }

    // MARK: - Private Methods

    private func processQueue() {
        guard !isProcessingQueue else { return }
        isProcessingQueue = true
        playNextInQueue()
    }

    private func playNextInQueue() {
        guard !audioQueue.isEmpty else {
            isProcessingQueue = false
            isPlaying = false
            scheduleOutputInactive()
            return
        }

        let audioData = audioQueue.removeFirst()
        queueCount = audioQueue.count

        do {
            audioPlayer = try AVAudioPlayer(data: audioData, fileTypeHint: AVFileType.mp3.rawValue)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()

            if audioPlayer?.play() == true {
                isPlaying = true
                markOutputActive()
                print("[AudioPlaybackService] Playing audio, remaining in queue: \(audioQueue.count)")
            } else {
                print("[AudioPlaybackService] Failed to start playback")
                playNextInQueue()
            }
        } catch {
            print("[AudioPlaybackService] Error creating player: \(error)")
            playNextInQueue()
        }
    }

    private func markOutputActive() {
        outputTailTask?.cancel()
        outputTailTask = nil
        if !isOutputActive {
            isOutputActive = true
        }
    }

    /// Queue drained - keep isOutputActive true for a short tail, then clear it
    private func scheduleOutputInactive() {
        guard isOutputActive else { return }

        let tail = outputTailNanoseconds
        outputTailTask?.cancel()
        outputTailTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: tail)
            guard let self, !Task.isCancelled, !self.isPlaying else { return }
            self.isOutputActive = false
            self.outputTailTask = nil
        }
    }
}

// MARK: - AVAudioPlayerDelegate

extension AudioPlaybackService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            print("[AudioPlaybackService] Finished playing, success: \(flag)")
            self.playNextInQueue()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            print("[AudioPlaybackService] Decode error: \(error?.localizedDescription ?? "unknown")")
            self.playNextInQueue()
        }
    }
}
