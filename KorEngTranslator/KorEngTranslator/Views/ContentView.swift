import SwiftUI

struct ContentView: View {
    // MARK: - State Objects

    @StateObject private var audioSession = AudioSessionManager.shared
    @StateObject private var audioCapture = AudioCaptureService()
    @StateObject private var audioPlayback = AudioPlaybackService()
    @StateObject private var webSocket = WebSocketManager()

    // MARK: - State

    @State private var direction: TranslationDirection = .koreanToEnglish
    @AppStorage("serverURL") private var serverURL: String = "ws://192.168.1.100:8000/ws/translate"
    @State private var showingSettings: Bool = false
    @State private var showingHeadphoneAlert: Bool = false
    @State private var debugLog: [String] = []

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Connection Status
                connectionStatusView

                Divider()

                // Direction Toggle
                directionToggleView

                Divider()

                // Recording Status
                recordingStatusView

                Divider()

                // Debug Output
                debugOutputView

                Spacer()

                // Connect/Disconnect Button
                connectionButton
            }
            .padding()
            .navigationTitle("KR-EN Translator")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingSettings = true }) {
                        Image(systemName: "gear")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                settingsSheet
            }
            .alert("Headphones Required", isPresented: $showingHeadphoneAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Please connect headphones to use this app.")
            }
            .onAppear {
                setupAudioCapture()
                checkHeadphones()
            }
            .onChange(of: audioSession.headphonesConnected) { _, connected in
                if !connected && webSocket.connectionState.isConnected {
                    showingHeadphoneAlert = true
                    stopSession()
                }
            }
        }
    }

    // MARK: - Subviews

    private var connectionStatusView: some View {
        HStack {
            Circle()
                .fill(connectionStatusColor)
                .frame(width: 12, height: 12)

            Text(webSocket.connectionState.displayText)
                .font(.headline)

            Spacer()

            if audioSession.headphonesConnected {
                Image(systemName: "headphones")
                    .foregroundColor(.green)
            } else {
                Image(systemName: "headphones")
                    .foregroundColor(.red)
            }
        }
        .padding(.horizontal)
    }

    private var connectionStatusColor: Color {
        switch webSocket.connectionState {
        case .connected:
            return .green
        case .connecting:
            return .yellow
        case .disconnected:
            return .gray
        case .error:
            return .red
        }
    }

    private var directionToggleView: some View {
        VStack(spacing: 10) {
            Text("Translation Direction")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Picker("Direction", selection: $direction) {
                ForEach(TranslationDirection.allCases, id: \.self) { dir in
                    Text(dir.displayName).tag(dir)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal)
    }

    private var recordingStatusView: some View {
        HStack {
            if audioCapture.isCapturing {
                Circle()
                    .fill(.red)
                    .frame(width: 16, height: 16)
                    .overlay(
                        Circle()
                            .stroke(.red, lineWidth: 2)
                            .scaleEffect(1.5)
                            .opacity(0.5)
                    )

                Text("Recording...")
                    .font(.headline)
                    .foregroundColor(.red)
            } else {
                Circle()
                    .fill(.gray.opacity(0.3))
                    .frame(width: 16, height: 16)

                Text("Not Recording")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if audioPlayback.isPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundColor(.blue)
                Text("Playing")
                    .font(.caption)
                    .foregroundColor(.blue)
            }

            if audioPlayback.queueCount > 0 {
                Text("(\(audioPlayback.queueCount) queued)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal)
    }

    private var debugOutputView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Debug Output")
                .font(.subheadline)
                .foregroundColor(.secondary)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        // Last transcription
                        if !webSocket.lastTranscription.isEmpty {
                            HStack(alignment: .top) {
                                Text("STT:")
                                    .font(.caption)
                                    .foregroundColor(.blue)
                                    .frame(width: 40, alignment: .leading)
                                Text(webSocket.lastTranscription)
                                    .font(.caption)
                            }
                        }

                        // Last translation
                        if !webSocket.lastTranslation.isEmpty {
                            HStack(alignment: .top) {
                                Text("TTS:")
                                    .font(.caption)
                                    .foregroundColor(.green)
                                    .frame(width: 40, alignment: .leading)
                                Text(webSocket.lastTranslation)
                                    .font(.caption)
                            }
                        }

                        Divider()

                        // Log entries
                        ForEach(Array(debugLog.enumerated()), id: \.offset) { index, entry in
                            Text(entry)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                                .id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: debugLog.count) { _, _ in
                    if let last = debugLog.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
            .frame(height: 200)
            .padding(8)
            .background(Color(.systemGray6))
            .cornerRadius(8)
        }
        .padding(.horizontal)
    }

    private var connectionButton: some View {
        Button(action: toggleConnection) {
            HStack {
                Image(systemName: webSocket.connectionState.isConnected ? "stop.fill" : "play.fill")
                Text(webSocket.connectionState.isConnected ? "Disconnect" : "Connect")
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(webSocket.connectionState.isConnected ? Color.red : Color.blue)
            .foregroundColor(.white)
            .cornerRadius(12)
        }
        .disabled(webSocket.connectionState == .connecting)
        .padding(.horizontal)
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("WebSocket URL", text: $serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                }

                Section("Audio Route") {
                    Text(audioSession.currentRoute)
                        .font(.system(.caption, design: .monospaced))
                }

                Section("Permissions") {
                    HStack {
                        Text("Microphone")
                        Spacer()
                        if audioSession.microphonePermissionGranted {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        } else {
                            Button("Request") {
                                Task {
                                    await audioSession.requestMicrophonePermission()
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        showingSettings = false
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func toggleConnection() {
        if webSocket.connectionState.isConnected {
            stopSession()
        } else {
            startSession()
        }
    }

    private func startSession() {
        // Check headphones
        guard audioSession.headphonesConnected else {
            showingHeadphoneAlert = true
            return
        }

        // Check microphone permission
        guard audioSession.microphonePermissionGranted else {
            Task {
                let granted = await audioSession.requestMicrophonePermission()
                if granted {
                    startSession()
                }
            }
            return
        }

        addDebugLog("Connecting to \(serverURL)")

        Task {
            // Configure audio session (async to allow Bluetooth enumeration)
            do {
                try await audioSession.configureAudioSession()
            } catch {
                addDebugLog("Audio session error: \(error.localizedDescription)")
                return
            }

            // Connect WebSocket and start session with selected direction
            webSocket.connect(to: serverURL, direction: direction)

            // Start audio capture after a short delay
            try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second

            if webSocket.connectionState.isConnected {
                do {
                    try audioCapture.startCapture()
                    addDebugLog("Started audio capture")
                } catch {
                    addDebugLog("Capture error: \(error.localizedDescription)")
                }
            }
        }
    }

    private func stopSession() {
        audioCapture.stopCapture()
        webSocket.disconnect()
        audioPlayback.stopAndClear()
        addDebugLog("Session stopped")
    }

    private func setupAudioCapture() {
        // Set up audio data callback
        audioCapture.onAudioData = { [self] data in
            webSocket.sendAudioChunk(data, direction: direction)
        }

        // Set up audio received callback
        webSocket.onAudioReceived = { [self] data in
            audioPlayback.queueAudio(data)
            addDebugLog("Received audio: \(data.count) bytes")
        }
    }

    private func checkHeadphones() {
        if !audioSession.headphonesConnected {
            showingHeadphoneAlert = true
        }

        // Request microphone permission on first launch
        Task {
            await audioSession.requestMicrophonePermission()
        }
    }

    private func addDebugLog(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        debugLog.append("[\(timestamp)] \(message)")

        // Keep only last 50 entries
        if debugLog.count > 50 {
            debugLog.removeFirst(debugLog.count - 50)
        }
    }
}

#Preview {
    ContentView()
}
