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

    // MARK: - Private Properties

    private var audioPlayer: AVAudioPlayer?
    private var audioQueue: [Data] = []
    private var isProcessingQueue: Bool = false

    // MARK: - Initialization

    override init() {
        super.init()
        setupAudioSession()
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
    /// - Parameter data: Audio data (MP3 or other format supported by AVAudioPlayer)
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
            return
        }

        let audioData = audioQueue.removeFirst()
        queueCount = audioQueue.count

        do {
            audioPlayer = try AVAudioPlayer(data: audioData)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()

            if audioPlayer?.play() == true {
                isPlaying = true
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
