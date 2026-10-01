import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import QuartzCore

#if DEBUG
// MARK: - Pairing recording demo
//
// Records the website's auto-pairing videos in the Simulator, one phone per take, with no debug
// buttons on screen and a touch indicator under every tap.
//
//   English: no headphones → "Tap here to connect them now" opens a look-alike Bluetooth page →
//   tap the AirPods → "◀ Dari AI Translate" back to the app → the card flips → success.
//     -pairingDemo en -debugPairingEntryMode autoPairing
//
//   Korean: headphones already in, waits on "Looking for your partner.", then succeeds.
//     -pairingDemo ko -demoPairAfter <seconds> -debugPairingEntryMode autoPairing
//
// Record the English take first. Its stderr log prints "search → success" in seconds; pass that
// as the Korean take's -demoPairAfter and both phones reach the success screen at the same
// moment after their language tap. The success screens hold instead of moving on to live.
//
// Tuning: -demoConnectFor 1.2 (AirPods spinner), -demoSuccessAfter 1.5 (card flip → success),
// -demoAirPodsName "AirPods Pro". -cleanRecording (no debug buttons) and -showTouches (touch
// indicators) also work on their own, in any flow. -noStatusBar hides the status bar for the whole
// take (the Bluetooth page's fake one too), for adding one back in the edit.

enum RecordingDemo {
    enum Role: String { case en, ko }

    struct Config {
        var role: Role?
        var hidesDebugUI = false
        var showsTouches = false
        /// Korean: seconds from "Looking for your partner." appearing to success
        var pairAfter: Double = 12
        /// English: the AirPods row's spinner in Settings
        var connectFor: Double = 1.2
        /// English: seconds from the card flipping to "Headphones connected" to success
        var successAfter: Double = 1.5
        var airPodsName = "AirPods Pro"
        /// Taps on its own, on the fixed timeline in `Autopilot`, so every take matches
        var autopilot = false
        /// No status bar at all, real or fake
        var hidesStatusBar = false
    }

    static let config = Config(arguments: ProcessInfo.processInfo.arguments)

    static var role: Role? { config.role }
    static var isPairingDemo: Bool { config.role != nil }
    static var hidesDebugUI: Bool { config.hidesDebugUI }
    /// The takes end on the success screen, so it doesn't move on to the live screen
    static var holdsOnSuccess: Bool { isPairingDemo }
    /// The Korean phone already has its headphones in
    static var startsWithHeadphones: Bool { config.role == .ko }
    static let roomId = "DEMO-ROOM"

    /// `-demoAutopilot`: the takes' fixed timeline, in seconds from t0 = `homeSettle` after the
    /// home screen appears. The home heading plays one full cycle first: English types (0.2-1.4),
    /// holds 5 s, fades (6.4-6.8), then Korean types (7.0-7.8) with its body fading in (6.8-8.05).
    /// Each tap time is when the finger lifts, which is when a real tap fires; its dot lands
    /// `press` earlier.
    /// Both phones succeed at `success`, so the English and Korean takes line up frame for frame.
    enum Autopilot {
        /// The take opens like a launch. A launch from devicectl reaches the screen 0.7-1.3 s after
        /// the home screen appears, so a fake white launch screen covers the app until
        /// `launchFadeAt` (from t0), fades out over `launchFade`, and the home screen holds still
        /// until t0. The heading and the autopilot both wait `homeSettle`. Export from t0 - `intro`
        /// so both clips open on white.
        static let homeSettle: Double = 3.0
        static let launchFadeAt: Double = -0.5
        static let launchFade: Double = 0.2
        static let intro: Double = 1.0
        static let languageTap: Double = 8.40     // 0.6 s after the Korean heading finishes typing
        static let headphoneCardTap: Double = 11.40
        static let airPodsTap: Double = 12.90     // "Connected" 1.2 s later (connectFor)
        static let breadcrumbTap: Double = 14.90  // slide back 0.5 s, card flips 0.25 s after
        static let success: Double = 17.15
        static let press: Double = 0.12
    }

    /// The home heading's per-character wobble (±0.01 s). Random in the app; under the autopilot a
    /// fixed hash of the character index, so both phones and every take type identically.
    static func typingJitter(index: Int, korean: Bool) -> Double? {
        guard config.autopilot else { return nil }
        let x = sin(Double(index + (korean ? 101 : 0)) * 12.9898) * 43758.5453
        return (x - x.rounded(.down)) * 0.02 - 0.01
    }

    /// "Tap here to connect them now" on the English phone: slides in the look-alike Bluetooth
    /// page. Returns false outside the English demo, so the real Settings opens.
    @MainActor static func openFakeBluetoothSettings() -> Bool {
        guard role == .en else { return false }
        RecordingDemoState.shared.openSettings()
        return true
    }

    /// Unbuffered, on the host clock every simulator shares, so takes can be lined up
    static func log(_ message: String) {
        let line = "[PairingDemo] \(String(format: "%.3f", CACurrentMediaTime())) \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

extension RecordingDemo.Config {
    init(arguments args: [String]) {
        func value(after flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        func seconds(_ flag: String) -> Double? {
            value(after: flag).flatMap(Double.init).map { max(0, $0) }
        }

        role = value(after: "-pairingDemo").flatMap { RecordingDemo.Role(rawValue: $0.lowercased()) }
        // The live screen's demo too (LiveRecordingDemo)
        hidesDebugUI = role != nil || args.contains("-cleanRecording") || args.contains("-liveDemo")
        showsTouches = role != nil || args.contains("-showTouches")
        if let s = seconds("-demoPairAfter") { pairAfter = s }
        if let s = seconds("-demoConnectFor") { connectFor = s }
        if let s = seconds("-demoSuccessAfter") { successAfter = s }
        if let name = value(after: "-demoAirPodsName"), !name.isEmpty { airPodsName = name }
        autopilot = role != nil && args.contains("-demoAutopilot")
        hidesStatusBar = args.contains("-noStatusBar")
    }
}

// MARK: - Demo state

@MainActor
final class RecordingDemoState: ObservableObject {
    static let shared = RecordingDemoState()

    enum AirPods { case notConnected, connecting, connected }

    /// Where the slide is headed: true = Settings on screen, the app pushed off to the left
    @Published private(set) var settingsShown = false
    /// Screen-shaped corners while the two apps slide past each other
    @Published private(set) var switching = false
    @Published private(set) var airPods: AirPods = .notConnected
    @Published private(set) var headphonesConnected = RecordingDemo.startsWithHeadphones

    private var headphonesConnectedAt: CFTimeInterval?

    /// The autopilot's language tap; the home screen handles it like a finger on the card
    @Published private(set) var languageTap: RecordingDemo.Role?
    /// The autopilot's t0, once it has started
    private(set) var autopilotStart: CFTimeInterval?
    /// The fake white launch screen the autopilot's takes open on
    @Published private(set) var launchCover = RecordingDemo.config.autopilot && RecordingDemo.role != nil
    /// Tap targets that depend on the device: the screen width, and the AirPods row's middle
    var screenWidth: CGFloat = 402
    var airPodsRowY: CGFloat?

    /// iOS's app-to-app switch: a quick slide with no bounce
    static let slideDuration = 0.5
    static let slide = Animation.spring(duration: slideDuration, bounce: 0)

    func openSettings() {
        guard !settingsShown, !switching else { return }
        RecordingDemo.log("settings: open")
        switching = true
        withAnimation(Self.slide) { settingsShown = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.slideDuration) { self.switching = false }
    }

    func connectAirPods() {
        guard airPods == .notConnected else { return }
        RecordingDemo.log("settings: AirPods connecting")
        airPods = .connecting
        DispatchQueue.main.asyncAfter(deadline: .now() + RecordingDemo.config.connectFor) {
            self.airPods = .connected
            RecordingDemo.log("settings: AirPods connected")
        }
    }

    func returnToApp() {
        guard settingsShown else { return }
        RecordingDemo.log("settings: back to app")
        switching = true
        withAnimation(Self.slide) { settingsShown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.slideDuration) {
            self.switching = false
            guard self.airPods == .connected, !self.headphonesConnected else { return }
            // The app notices the new audio route a beat after it's back on screen
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self.headphonesConnected = true
                self.headphonesConnectedAt = CACurrentMediaTime()
                RecordingDemo.log("app: headphones connected")
            }
        }
    }

    /// Runs while "Looking for your partner." is on screen; true when the pairing should succeed
    func waitForMatch() async -> Bool {
        let appeared = CACurrentMediaTime()
        RecordingDemo.log("search: appeared")
        switch RecordingDemo.role {
        case .ko:
            if let t0 = autopilotStart {
                await Self.sleep(until: t0 + RecordingDemo.Autopilot.success)
            } else {
                try? await Task.sleep(for: .seconds(RecordingDemo.config.pairAfter))
            }
        case .en:
            while headphonesConnectedAt == nil {
                try? await Task.sleep(for: .milliseconds(20))
                if Task.isCancelled { return false }
            }
            if let t0 = autopilotStart {
                await Self.sleep(until: t0 + RecordingDemo.Autopilot.success)
            } else {
                try? await Task.sleep(for: .seconds(RecordingDemo.config.successAfter))
            }
        case nil:
            return false
        }
        guard !Task.isCancelled else { return false }
        let total = CACurrentMediaTime() - appeared
        var message = String(format: "search → success %.2f s", total)
        if RecordingDemo.role == .en {
            message += String(format: "   (Korean take: -demoPairAfter %.2f)", total)
        }
        RecordingDemo.log(message)
        return true
    }

    private static func sleep(until time: CFTimeInterval) async {
        let wait = time - CACurrentMediaTime()
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
    }

    /// `-demoAutopilot`: plays the take on the fixed timeline, with a touch dot for every tap
    func runAutopilot() async {
        guard RecordingDemo.config.autopilot, let role = RecordingDemo.role, autopilotStart == nil else { return }
        let t0 = CACurrentMediaTime() + RecordingDemo.Autopilot.homeSettle
        await Self.sleep(until: t0 + RecordingDemo.Autopilot.launchFadeAt)
        withAnimation(.easeOut(duration: RecordingDemo.Autopilot.launchFade)) { launchCover = false }
        await Self.sleep(until: t0)
        guard !Task.isCancelled else { return }
        autopilotStart = t0
        RecordingDemo.log("autopilot: t0")

        func tap(_ time: Double, at point: CGPoint, _ action: () -> Void) async {
            await Self.sleep(until: t0 + time - RecordingDemo.Autopilot.press)
            TouchIndicators.tap(at: point, hold: RecordingDemo.Autopilot.press)
            await Self.sleep(until: t0 + time)
            action()
        }

        // Language cards: 20pt margins, AppSpacing.betweenCards apart, a thumb's height up from the bottom
        let home = HomeLayoutTuning.shared
        let cardWidth = (screenWidth - 40 - AppSpacing.betweenCards) / 2
        let cardX = role == .en ? 20 + cardWidth / 2 : 20 + cardWidth + AppSpacing.betweenCards + cardWidth / 2
        await tap(RecordingDemo.Autopilot.languageTap, at: CGPoint(x: cardX, y: home.cardTop + home.cardHeight * 0.62)) {
            languageTap = role
        }
        guard role == .en else { return }

        // Headphone card: full width, at the partner search's Card Y, same height as home's cards
        let cardY = PartnerSearchLayoutTuning.shared.cardTop + home.cardHeight * 0.78
        await tap(RecordingDemo.Autopilot.headphoneCardTap, at: CGPoint(x: screenWidth / 2, y: cardY)) {
            openSettings()
        }
        await tap(RecordingDemo.Autopilot.airPodsTap, at: CGPoint(x: screenWidth * 0.3, y: airPodsRowY ?? 532)) {
            connectAirPods()
        }
        await tap(RecordingDemo.Autopilot.breadcrumbTap, at: FakeStatusBar.breadcrumbCenter) {
            returnToApp()
        }
    }
}

// MARK: - Hooks

extension View {
    /// "Looking for your partner." in the pairing demo: the headphones follow the demo, and the
    /// search succeeds on the demo's schedule. Does nothing outside the demo.
    @ViewBuilder
    func pairingDemoSearch(headphones: Binding<Bool>, onMatch: @escaping (String) -> Void) -> some View {
        if RecordingDemo.isPairingDemo {
            modifier(PairingDemoSearchHooks(headphones: headphones, onMatch: onMatch))
        } else {
            self
        }
    }

    /// Debug buttons and panels: gone while recording (-cleanRecording or -pairingDemo)
    @ViewBuilder
    func hiddenWhileRecording() -> some View {
        if RecordingDemo.hidesDebugUI {
            EmptyView()
        } else {
            self
        }
    }

    /// Home screen: the autopilot's language tap, handled exactly like a finger on the card
    @ViewBuilder
    func pairingDemoLanguageTap(_ select: @escaping (RecordingDemo.Role) -> Void) -> some View {
        if RecordingDemo.config.autopilot {
            modifier(LanguageTapHook(select: select))
        } else {
            self
        }
    }

    /// App root: the English demo's switch to the Bluetooth page and back, and touch indicators
    func pairingRecordingDemo() -> some View {
        modifier(PairingRecordingRoot())
    }
}

private struct PairingDemoSearchHooks: ViewModifier {
    @Binding var headphones: Bool
    let onMatch: (String) -> Void
    @ObservedObject private var state = RecordingDemoState.shared

    func body(content: Content) -> some View {
        content
            // The headphone card animates the change itself
            .onChange(of: state.headphonesConnected) { _, connected in headphones = connected }
            .task {
                if await state.waitForMatch() { onMatch(RecordingDemo.roomId) }
            }
    }
}

private struct LanguageTapHook: ViewModifier {
    @ObservedObject private var state = RecordingDemoState.shared
    let select: (RecordingDemo.Role) -> Void

    func body(content: Content) -> some View {
        content.onChange(of: state.languageTap) { _, role in
            if let role { select(role) }
        }
    }
}

private struct PairingRecordingRoot: ViewModifier {
    @ObservedObject private var state = RecordingDemoState.shared
    @State private var width: CGFloat = 402

    /// iPhone 17's screen corners, for the two apps sliding past each other
    private let screenCornerRadius: CGFloat = 55
    private let gap: CGFloat = 12

    func body(content: Content) -> some View {
        Group {
            if RecordingDemo.role == .en {
                ZStack {
                    Color.black.ignoresSafeArea()

                    content
                        .overlay { screenCorners }
                        .offset(x: state.settingsShown ? -(width + gap) : 0)

                    // Built at launch and parked off to the right, so sliding it in never stalls
                    // on its first frame
                    FakeBluetoothSettings(state: state)
                        .overlay { screenCorners }
                        .offset(x: state.settingsShown ? 0 : width + gap)
                }
                // Settings shows "◀ Dari AI Translate" where the time was
                // (its 0.2s fade stays on the status bar: on the whole stack it would override the
                // 0.5s slide, and the apps would whip past in 0.2s)
                .overlay {
                    Group {
                        if state.settingsShown && !RecordingDemo.config.hidesStatusBar {
                            FakeStatusBar { state.returnToApp() }
                                .ignoresSafeArea()
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: state.settingsShown)
                }
                .statusBarHidden(state.settingsShown || RecordingDemo.config.hidesStatusBar)
            } else {
                content
            }
        }
        .overlay {
            if state.launchCover {
                Color.white.ignoresSafeArea().transition(.opacity)
            }
        }
        .statusBarHidden(RecordingDemo.config.hidesStatusBar)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
            width = $0
            state.screenWidth = $0
        }
        .background(TouchIndicatorInstaller(enabled: RecordingDemo.config.showsTouches))
        .task { await state.runAutopilot() }
    }

    /// Black outside screen-shaped corners while the apps slide, nothing at rest. Drawn on top
    /// instead of masking, which would render the whole app off-screen on every frame.
    private var screenCorners: some View {
        ScreenCorners(radius: state.switching ? screenCornerRadius : 0)
            .fill(.black, style: FillStyle(eoFill: true))
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

/// The frame minus a rounded rect of the same size: only the four corners
private struct ScreenCorners: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRoundedRect(in: rect, cornerSize: CGSize(width: radius, height: radius), style: .continuous)
        return path
    }
}

// MARK: - Look-alike Bluetooth settings

private struct FakeBluetoothSettings: View {
    @ObservedObject var state: RecordingDemoState

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 6) {
                        BluetoothTile()
                            .frame(width: 56, height: 56)
                            .padding(.bottom, 8)
                        Text("Bluetooth")
                            .font(.title2.weight(.bold))
                        Text("Connect to accessories you can use for activities such as streaming music, typing, and gaming. \(Text("Learn more…").foregroundStyle(.blue))")
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)

                    Toggle("Bluetooth", isOn: .constant(true))
                } footer: {
                    Text("This iPhone is discoverable as “iPhone” while Bluetooth Settings is open.")
                }

                Section("My Devices") {
                    Button {
                        state.connectAirPods()
                    } label: {
                        HStack(spacing: 10) {
                            Text(RecordingDemo.config.airPodsName)
                                .foregroundStyle(Color.primary)
                            Spacer()
                            status
                            Image(systemName: "info.circle")
                                .font(.system(size: 22))
                                .foregroundStyle(.blue)
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).midY } action: {
                            state.airPodsRowY = $0
                        }
                    }
                }

                Section {
                } header: {
                    HStack(spacing: 6) {
                        Text("Other Devices")
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {} label: { Image(systemName: "chevron.left") }
                }
            }
        }
        .environment(\.colorScheme, .light)
    }

    @ViewBuilder private var status: some View {
        switch state.airPods {
        case .notConnected:
            Text("Not Connected").foregroundStyle(Color.secondary)
        case .connecting:
            ProgressView()
        case .connected:
            Text("Connected").foregroundStyle(Color.secondary)
        }
    }
}

/// Settings' blue rounded-square icon with the Bluetooth rune
private struct BluetoothTile: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(Color(red: 0.0, green: 0.48, blue: 1.0))
            .overlay(
                BluetoothRune()
                    .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .padding(.vertical, 12)
            )
    }
}

private struct BluetoothRune: Shape {
    func path(in rect: CGRect) -> Path {
        // Drawn on a 10 × 20 grid: the arrow-ended bind rune, centered in `rect`
        let scale = rect.height / 20
        let originX = rect.midX - 5 * scale
        let grid: [(x: CGFloat, y: CGFloat)] = [(0, 5), (10, 15), (5, 20), (5, 0), (10, 5), (0, 15)]
        let points = grid.map { CGPoint(x: originX + $0.x * scale, y: rect.minY + $0.y * scale) }
        var path = Path()
        path.addLines(points)
        return path
    }
}

/// Stands in for the status bar while Settings is up: the back-to-app breadcrumb on the left, and
/// the right side drawn at the real icons' positions (measured on iPhone 17's status bar)
private struct FakeStatusBar: View {
    let onBack: () -> Void

    /// Centered where the time sits (measured on iPhone 17 / 16 Pro)
    static let breadcrumbCenter = CGPoint(x: 74, y: 32)

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Back"
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrowtriangle.left.fill")
                            .font(.system(size: 8, weight: .bold))
                        Text(appName)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.black)
                    .frame(height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .position(Self.breadcrumbCenter)

                // Measured against the real status bar in a USB capture of the iPhone 16 Pro
                // (iOS 26.6, 2026-09-30)
                // Cellular: four bars, 3.33pt wide on a 5.33pt pitch, bottoms level
                ForEach(0..<4, id: \.self) { bar in
                    let height = [4.67, 7, 9.67, 12.33][bar]
                    RoundedRectangle(cornerRadius: 1.1, style: .continuous)
                        .frame(width: 3.33, height: height)
                        .position(x: width - 112.17 + CGFloat(bar) * 5.33, y: 38.67 - height / 2)
                }
                Image(systemName: "wifi")
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.bold)
                    .frame(width: 16.7, height: 12.7)
                    .position(x: width - 78.3, y: 32.4)
                // Battery at 100%: a 1pt 40% outline, a 1pt gap, the solid fill, then a faint nub
                // 1pt to the right
                RoundedRectangle(cornerRadius: 4.3, style: .continuous)
                    .strokeBorder(.black.opacity(0.4), lineWidth: 1)
                    .frame(width: 25, height: 13)
                    .position(x: width - 50.17, y: 32.5)
                RoundedRectangle(cornerRadius: 2.7, style: .continuous)
                    .frame(width: 21, height: 9)
                    .position(x: width - 50.17, y: 32.5)
                UnevenRoundedRectangle(bottomTrailingRadius: 1, topTrailingRadius: 1)
                    .fill(.black.opacity(0.48))
                    .frame(width: 1.33, height: 4.33)
                    .position(x: width - 36, y: 32.5)
            }
            .foregroundStyle(.black)
        }
        .environment(\.colorScheme, .light)
    }
}

// MARK: - Touch indicators

/// Installs the indicators on the window it lands in (once per window)
private struct TouchIndicatorInstaller: UIViewRepresentable {
    let enabled: Bool

    func makeUIView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.enabled = enabled
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: InstallerView, context: Context) {}

    final class InstallerView: UIView {
        var enabled = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard enabled, let window else { return }
            TouchIndicators.install(on: window)
        }
    }
}

enum TouchIndicators {
    fileprivate static weak var overlay: TouchIndicatorOverlay?

    /// A dot without a finger, for the autopilot: lands, holds `hold`, then lifts like a real tap
    static func tap(at point: CGPoint, hold: TimeInterval) {
        guard let overlay else { return }
        overlay.superview?.bringSubviewToFront(overlay)
        overlay.tap(at: point, hold: hold)
    }

    /// A soft circle under every finger, drawn inside the app so every recording shows it
    static func install(on window: UIWindow) {
        guard !(window.gestureRecognizers ?? []).contains(where: { $0 is TouchObserver }) else { return }
        let overlay = TouchIndicatorOverlay(frame: window.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.isUserInteractionEnabled = false
        overlay.backgroundColor = .clear
        window.addSubview(overlay)
        window.addGestureRecognizer(TouchObserver(overlay: overlay))
        Self.overlay = overlay
        RecordingDemo.log("touch indicators on")
    }
}

/// Sees every touch in the window without taking part: never recognizes, never delays or
/// cancels anything, and fails once all fingers are up so it resets for the next touch
private final class TouchObserver: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private weak var overlay: TouchIndicatorOverlay?

    init(overlay: TouchIndicatorOverlay) {
        self.overlay = overlay
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let overlay { overlay.superview?.bringSubviewToFront(overlay) }
        overlay?.show(touches)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        overlay?.move(touches)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        overlay?.hide(touches)
        failWhenAllUp(event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        overlay?.hide(touches)
        failWhenAllUp(event)
    }

    private func failWhenAllUp(_ event: UIEvent) {
        let down = event.allTouches?.filter { $0.phase != .ended && $0.phase != .cancelled } ?? []
        if down.isEmpty { state = .failed }
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

private final class TouchIndicatorOverlay: UIView {
    private var dots: [ObjectIdentifier: (view: UIView, shownAt: CFTimeInterval)] = [:]
    private let diameter: CGFloat = 38

    func show(_ touches: Set<UITouch>) {
        for touch in touches {
            let dot = makeDot()
            dot.center = touch.location(in: self)
            dot.alpha = 0
            dot.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
            addSubview(dot)
            UIView.animate(withDuration: 0.12, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                dot.alpha = 1
                dot.transform = .identity
            }
            dots[ObjectIdentifier(touch)] = (dot, CACurrentMediaTime())
        }
    }

    func move(_ touches: Set<UITouch>) {
        for touch in touches {
            dots[ObjectIdentifier(touch)]?.view.center = touch.location(in: self)
        }
    }

    func hide(_ touches: Set<UITouch>) {
        for touch in touches {
            guard let entry = dots.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            let dot = entry.view
            dot.center = touch.location(in: self)
            // A quick tap still stays up long enough to read on camera
            let hold = max(0, 0.18 - (CACurrentMediaTime() - entry.shownAt))
            UIView.animate(withDuration: 0.3, delay: hold, options: [.curveEaseOut, .allowUserInteraction]) {
                dot.alpha = 0
                dot.transform = CGAffineTransform(scaleX: 1.2, y: 1.2)
            } completion: { _ in
                dot.removeFromSuperview()
            }
        }
    }

    func tap(at point: CGPoint, hold: TimeInterval) {
        let dot = makeDot()
        dot.center = point
        dot.alpha = 0
        dot.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        addSubview(dot)
        UIView.animate(withDuration: 0.12, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            dot.alpha = 1
            dot.transform = .identity
        }
        UIView.animate(withDuration: 0.3, delay: max(hold, 0.18), options: [.curveEaseOut, .allowUserInteraction]) {
            dot.alpha = 0
            dot.transform = CGAffineTransform(scaleX: 1.2, y: 1.2)
        } completion: { _ in
            dot.removeFromSuperview()
        }
    }

    private func makeDot() -> UIView {
        let dot = UIView(frame: CGRect(x: 0, y: 0, width: diameter, height: diameter))
        dot.isUserInteractionEnabled = false
        dot.backgroundColor = UIColor(white: 1, alpha: 0.55)
        dot.layer.cornerRadius = diameter / 2
        dot.layer.borderWidth = 1
        dot.layer.borderColor = UIColor(white: 0, alpha: 0.18).cgColor
        dot.layer.shadowColor = UIColor.black.cgColor
        dot.layer.shadowOpacity = 0.2
        dot.layer.shadowRadius = 6
        dot.layer.shadowOffset = CGSize(width: 0, height: 2)
        return dot
    }
}
#endif
