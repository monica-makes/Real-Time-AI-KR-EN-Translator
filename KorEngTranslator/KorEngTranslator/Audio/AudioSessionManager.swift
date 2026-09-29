import AVFoundation
import Combine

/// Manages audio session configuration, route detection, and microphone permissions
@MainActor
class AudioSessionManager: ObservableObject {
    static let shared = AudioSessionManager()

    // MARK: - Published Properties

    @Published private(set) var headphonesConnected: Bool = false
    @Published private(set) var microphonePermissionGranted: Bool = false
    @Published private(set) var currentRoute: String = "Unknown"

    // MARK: - Private Properties

    private let audioSession = AVAudioSession.sharedInstance()
    private var routeChangeObserver: NSObjectProtocol?

    // MARK: - Supported Headphone Port Types
    // Note: AirPods typically appear as bluetoothA2DP (audio) or bluetoothHFP (calls/mic)

    private let supportedHeadphoneTypes: Set<AVAudioSession.Port> = [
        .bluetoothA2DP,
        .bluetoothHFP,
        .bluetoothLE,
        .headphones,
        .headsetMic
    ]

    // MARK: - Initialization

    private init() {
        setupRouteChangeObserver()
        checkMicrophonePermission()
        // Configure audio session and check route with delay for Bluetooth enumeration
        Task {
            await configureForDetection()
        }
    }

    /// Configure audio session minimally to enable Bluetooth device detection
    private func configureForDetection() async {
        do {
            // Use .default mode (not .voiceChat) to avoid Bluetooth routing restrictions
            try audioSession.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.allowBluetoothA2DP, .defaultToSpeaker]
            )
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            print("[AudioSessionManager] Audio session configured for detection")

            // Give iOS time to enumerate Bluetooth devices
            try await Task.sleep(nanoseconds: 500_000_000)  // 0.5 second
            checkCurrentRoute()
        } catch {
            print("[AudioSessionManager] Failed to configure for detection: \(error)")
        }
    }

    deinit {
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Public Methods

    /// Configure audio session for recording and playback
    func configureAudioSession() async throws {
        // Use .default mode (not .voiceChat) to avoid Bluetooth routing restrictions
        try audioSession.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.allowBluetoothA2DP, .defaultToSpeaker]
        )
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        // Give iOS time to enumerate Bluetooth devices
        try await Task.sleep(nanoseconds: 500_000_000)  // 0.5 second
        checkCurrentRoute()
    }

    /// Request microphone permission
    func requestMicrophonePermission() async -> Bool {
        let status = AVAudioApplication.shared.recordPermission

        switch status {
        case .granted:
            await MainActor.run {
                microphonePermissionGranted = true
            }
            return true

        case .denied:
            await MainActor.run {
                microphonePermissionGranted = false
            }
            return false

        case .undetermined:
            let granted = await AVAudioApplication.requestRecordPermission()
            await MainActor.run {
                microphonePermissionGranted = granted
            }
            return granted

        @unknown default:
            return false
        }
    }

    /// Check if headphones are currently connected
    func checkHeadphonesConnected() -> Bool {
        let currentRoute = audioSession.currentRoute

        // Debug: Print all detected ports
        print("[AudioSessionManager] === Checking headphones ===")
        print("[AudioSessionManager] Current outputs:")
        for output in currentRoute.outputs {
            print("[AudioSessionManager]   - \(output.portName): \(output.portType.rawValue)")
            // Check 1: currentRoute.outputs contains supported headphone types
            if supportedHeadphoneTypes.contains(output.portType) {
                print("[AudioSessionManager]   -> MATCHED as headphones!")
                return true
            }
        }

        print("[AudioSessionManager] Current inputs:")
        for input in currentRoute.inputs {
            print("[AudioSessionManager]   - \(input.portName): \(input.portType.rawValue)")
            // Also check inputs for headphone types
            if supportedHeadphoneTypes.contains(input.portType) {
                print("[AudioSessionManager]   -> MATCHED as headphones (via input)!")
                return true
            }
        }

        // Check 2: availableInputs contains any Bluetooth device
        // AirPods may be available but not yet active in the route
        print("[AudioSessionManager] Available inputs:")
        if let availableInputs = audioSession.availableInputs {
            for input in availableInputs {
                let portTypeString = input.portType.rawValue.lowercased()
                print("[AudioSessionManager]   - \(input.portName): \(input.portType.rawValue)")

                // Check if portType contains "bluetooth" (case insensitive)
                if portTypeString.contains("bluetooth") {
                    print("[AudioSessionManager]   -> MATCHED as Bluetooth device (available)!")
                    return true
                }

                // Also check for wired headphones in available inputs
                if supportedHeadphoneTypes.contains(input.portType) {
                    print("[AudioSessionManager]   -> MATCHED as headphones (available)!")
                    return true
                }
            }
        }

        print("[AudioSessionManager] No headphones detected")
        return false
    }

    /// True when playback goes to the phone's own speaker/receiver, where the mic can hear it
    /// (echo risk). The Simulator plays through the Mac's speakers, so it counts as speaker.
    nonisolated static func isOutputOnBuiltInSpeaker() -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { output in
            output.portType == .builtInSpeaker || output.portType == .builtInReceiver
        }
        #endif
    }

    /// Get human-readable description of current audio route
    func getCurrentRouteDescription() -> String {
        let route = audioSession.currentRoute

        var outputs: [String] = []
        for output in route.outputs {
            outputs.append("\(output.portName) (\(output.portType.rawValue))")
        }

        var inputs: [String] = []
        for input in route.inputs {
            inputs.append("\(input.portName) (\(input.portType.rawValue))")
        }

        var available: [String] = []
        if let availableInputs = audioSession.availableInputs {
            for input in availableInputs {
                available.append("\(input.portName) (\(input.portType.rawValue))")
            }
        }

        return """
            Out: \(outputs.isEmpty ? "None" : outputs.joined(separator: ", "))
            In: \(inputs.isEmpty ? "None" : inputs.joined(separator: ", "))
            Available: \(available.isEmpty ? "None" : available.joined(separator: ", "))
            """
    }

    // MARK: - Private Methods

    private func setupRouteChangeObserver() {
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleRouteChange(notification)
            }
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }

        print("[AudioSessionManager] Route changed: \(reason.description)")

        checkCurrentRoute()

        // Log details for debugging
        if let previousRoute = userInfo[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription {
            print("[AudioSessionManager] Previous route: \(previousRoute.outputs.map { $0.portType.rawValue })")
        }
        print("[AudioSessionManager] Current route: \(audioSession.currentRoute.outputs.map { $0.portType.rawValue })")
    }

    private func checkCurrentRoute() {
        headphonesConnected = checkHeadphonesConnected()
        currentRoute = getCurrentRouteDescription()
    }

    private func checkMicrophonePermission() {
        let status = AVAudioApplication.shared.recordPermission
        microphonePermissionGranted = (status == .granted)
    }
}

// MARK: - AVAudioSession.RouteChangeReason Extension

extension AVAudioSession.RouteChangeReason {
    var description: String {
        switch self {
        case .unknown: return "Unknown"
        case .newDeviceAvailable: return "New device available"
        case .oldDeviceUnavailable: return "Old device unavailable"
        case .categoryChange: return "Category change"
        case .override: return "Override"
        case .wakeFromSleep: return "Wake from sleep"
        case .noSuitableRouteForCategory: return "No suitable route"
        case .routeConfigurationChange: return "Route configuration change"
        @unknown default: return "Unknown (\(rawValue))"
        }
    }
}
