import SwiftUI
import Observation

/// Layout of the manual pairing screens ("Can't find your partner?", English and Korean).
/// Create mode stacks the title, subtitle, "Show this QR code:", the QR box, "Or share this code:"
/// and the code box. Join mode stacks the title, subtitle, "Scan their QR code:", the camera (a
/// square as wide as the page's content), "Not scanning? ..." and the code entry.
///
/// Each mode has its own top (the whole unit's Y) and gaps. Unless it's set, the gap above
/// "Or share this code:" is worked out so it sits exactly where join mode's code-entry label does.
/// Debug builds tune it all live from the screen's layout panel (ruler, bottom left); values last
/// until the app relaunches, then "Copy" hands them over for the code.
@Observable
final class PairingLayoutTuning {
    static let shared = PairingLayoutTuning()

    // Today's layout (points; tops from the top of the safe area)
    static let defaultTop: CGFloat = 135
    static let defaultTitleBodyGap: CGFloat = AppSpacing.headerBody
    static let defaultQRLabelGap: CGFloat = 14
    static let defaultQRGap: CGFloat = 10
    static let defaultShareCodeGap: CGFloat = 16
    static let defaultScanLabelGap: CGFloat = 12
    static let defaultCameraGap: CGFloat = 12
    static let defaultCodeEntryGap: CGFloat = 32
    static let defaultDigitsGap: CGFloat = 16

    // Create mode
    var createTop = defaultTop                      // title top
    var createTitleBodyGap = defaultTitleBodyGap
    var qrLabelGap = defaultQRLabelGap              // subtitle → "Show this QR code:"
    var qrGap = defaultQRGap                        // label → QR box
    /// QR box → "Or share this code:". Nil lines it up with join mode's code-entry label.
    var shareGap: CGFloat? = nil
    var shareCodeGap = defaultShareCodeGap          // label → code box

    // Join mode
    var joinTop = defaultTop                        // title top
    var joinTitleBodyGap = defaultTitleBodyGap
    var scanLabelGap = defaultScanLabelGap          // subtitle → "Scan their QR code:"
    var cameraGap = defaultCameraGap                // label → camera
    var codeEntryGap = defaultCodeEntryGap          // camera → "Not scanning? Enter in their code."
    var digitsGap = defaultDigitsGap                // label → code entry boxes

    /// Camera box edge → viewfinder
    static let cameraInset: CGFloat = 12

    /// The QR box: the QR at 80% of the page's content width, plus its 16pt padding a side
    static func qrBoxSide(pageWidth: CGFloat) -> CGFloat { (pageWidth - 72) * 0.8 + 32 }
    /// The camera box: a square as wide as the page's content (20pt margins)
    static func cameraSide(pageWidth: CGFloat) -> CGFloat { pageWidth - 40 }
    static func viewfinderSide(pageWidth: CGFloat) -> CGFloat { cameraSide(pageWidth: pageWidth) - 2 * cameraInset }
    /// Concentric with the camera box's corners
    static var viewfinderRadius: CGFloat { max(0, AppStyle.cornerRadius - cameraInset) }

    /// QR box → "Or share this code:". Both modes have the same title, subtitle and one label
    /// above their square, so lining the two up only takes the tops, the gaps and the squares.
    func currentShareGap(pageWidth: CGFloat) -> CGFloat {
        if let shareGap { return shareGap }
        let joinCodeLabel = joinTop + joinTitleBodyGap + scanLabelGap + cameraGap
            + Self.cameraSide(pageWidth: pageWidth) + codeEntryGap
        let createQRBottom = createTop + createTitleBodyGap + qrLabelGap + qrGap
            + Self.qrBoxSide(pageWidth: pageWidth)
        return max(0, joinCodeLabel - createQRBottom)
    }

    var isDefault: Bool {
        createTop == Self.defaultTop && createTitleBodyGap == Self.defaultTitleBodyGap
            && qrLabelGap == Self.defaultQRLabelGap && qrGap == Self.defaultQRGap && shareGap == nil
            && shareCodeGap == Self.defaultShareCodeGap
            && joinTop == Self.defaultTop && joinTitleBodyGap == Self.defaultTitleBodyGap
            && scanLabelGap == Self.defaultScanLabelGap && cameraGap == Self.defaultCameraGap
            && codeEntryGap == Self.defaultCodeEntryGap && digitsGap == Self.defaultDigitsGap
    }

    func reset() {
        createTop = Self.defaultTop
        createTitleBodyGap = Self.defaultTitleBodyGap
        qrLabelGap = Self.defaultQRLabelGap
        qrGap = Self.defaultQRGap
        shareGap = nil
        shareCodeGap = Self.defaultShareCodeGap
        joinTop = Self.defaultTop
        joinTitleBodyGap = Self.defaultTitleBodyGap
        scanLabelGap = Self.defaultScanLabelGap
        cameraGap = Self.defaultCameraGap
        codeEntryGap = Self.defaultCodeEntryGap
        digitsGap = Self.defaultDigitsGap
    }

    /// For pasting into a chat or the code
    func summary(pageWidth: CGFloat) -> String {
        func pt(_ value: CGFloat) -> String { String(format: "%.0f", value) }
        let shareNote = shareGap == nil ? " (lined up with join)" : ""
        return """
        Manual pairing layout (pt; tops from the safe-area top)
        create: top \(pt(createTop)), title-body \(pt(createTitleBodyGap)), body-label \(pt(qrLabelGap)), \
        label-QR \(pt(qrGap)), QR-share \(pt(currentShareGap(pageWidth: pageWidth)))\(shareNote), \
        label-code \(pt(shareCodeGap))
        join: top \(pt(joinTop)), title-body \(pt(joinTitleBodyGap)), body-label \(pt(scanLabelGap)), \
        label-camera \(pt(cameraGap)), camera-code \(pt(codeEntryGap)), label-code \(pt(digitsGap))
        """
    }
}

#if DEBUG
/// Ruler + layout panel on the manual pairing screens: the whole unit's top, then each gap down
/// the page, for the mode on screen
struct PairingLayoutDebugPanel: View {
    let isCreate: Bool
    let pageWidth: CGFloat

    private var layout: PairingLayoutTuning { .shared }

    var body: some View {
        LayoutTunerPanel(isCreate ? "CREATE LAYOUT" : "JOIN LAYOUT", toggleIcon: "ruler.fill",
                         toggleOnLeading: true, launchArgument: "-pairingLayoutPanel",
                         isDefault: layout.isDefault, onReset: { layout.reset() },
                         summary: { layout.summary(pageWidth: pageWidth) }) {
            if isCreate {
                LayoutTunerRow("Top", value: layout.createTop, range: 0...500) { layout.createTop = $0 }
                LayoutTunerRow("Title ↔ body", value: layout.createTitleBodyGap, range: 0...80) { layout.createTitleBodyGap = $0 }
                LayoutTunerRow("Body ↔ label", value: layout.qrLabelGap, range: 0...120) { layout.qrLabelGap = $0 }
                LayoutTunerRow("Label ↔ QR", value: layout.qrGap, range: 0...80) { layout.qrGap = $0 }
                LayoutTunerRow("QR ↔ share", value: layout.currentShareGap(pageWidth: pageWidth), range: 0...300) { layout.shareGap = $0 }
                LayoutTunerRow("Label ↔ code", value: layout.shareCodeGap, range: 0...80) { layout.shareCodeGap = $0 }
            } else {
                LayoutTunerRow("Top", value: layout.joinTop, range: 0...500) { layout.joinTop = $0 }
                LayoutTunerRow("Title ↔ body", value: layout.joinTitleBodyGap, range: 0...80) { layout.joinTitleBodyGap = $0 }
                LayoutTunerRow("Body ↔ label", value: layout.scanLabelGap, range: 0...120) { layout.scanLabelGap = $0 }
                LayoutTunerRow("Label ↔ cam", value: layout.cameraGap, range: 0...80) { layout.cameraGap = $0 }
                LayoutTunerRow("Cam ↔ code", value: layout.codeEntryGap, range: 0...200) { layout.codeEntryGap = $0 }
                LayoutTunerRow("Label ↔ code", value: layout.digitsGap, range: 0...80) { layout.digitsGap = $0 }
            }
        }
    }
}
#endif
