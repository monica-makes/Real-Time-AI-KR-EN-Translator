import SwiftUI
import Observation

/// Layout of the manual pairing screens ("Can't find your partner?", English and Korean).
/// Create mode stacks the title, subtitle, "Show this QR code:", the QR box, "Or share this code:"
/// and the code box. Join mode stacks the title, subtitle, "Scan their QR code:", the camera (a
/// square as wide as the page's content), "Not scanning? ..." and the code entry.
///
/// Both modes use the same gaps. Each mode has its own top (the whole unit's Y) and its own gap from
/// the square (QR box / camera) to the code section under it; Debug builds tune those two live from
/// the screen's layout panel (ruler, bottom left). Values last until the app relaunches, then
/// "Copy" hands them over for the code.
@Observable
final class PairingLayoutTuning {
    static let shared = PairingLayoutTuning()

    // Both modes (points). Like every page after home, the subtitle sits
    // HomeLayoutTuning.bodyLiftAfterHome closer to the title than titleBodyGap; the label under it stays put.
    static let titleBodyGap: CGFloat = 16
    static let labelGap: CGFloat = 28           // subtitle → "Show this QR code:" / "Scan their QR code:"
    static let squareGap: CGFloat = 12          // label → QR box / camera
    static let codeGap: CGFloat = 12            // "Or share this code:" / "Not scanning? ..." → code box(es)

    // Tunable per mode (points; tops from the top of the safe area)
    static let defaultTop: CGFloat = 128
    static let defaultSectionGap: CGFloat = 60  // square → the code section's label

    var createTop = defaultTop                  // title top
    var shareGap = defaultSectionGap            // QR box → "Or share this code:"
    var joinTop = defaultTop                    // title top
    var codeEntryGap = defaultSectionGap        // camera → "Not scanning? Enter in their code."

    /// Camera box edge → viewfinder
    static let cameraInset: CGFloat = 12

    /// The QR box: the QR at 80% of the page's content width, plus its 16pt padding a side
    static func qrBoxSide(pageWidth: CGFloat) -> CGFloat { (pageWidth - 72) * 0.8 + 32 }
    /// The camera box: a square as wide as the page's content (20pt margins)
    static func cameraSide(pageWidth: CGFloat) -> CGFloat { pageWidth - 40 }
    static func viewfinderSide(pageWidth: CGFloat) -> CGFloat { cameraSide(pageWidth: pageWidth) - 2 * cameraInset }
    /// Same corner radius as the camera box around it
    static var viewfinderRadius: CGFloat { AppStyle.cornerRadius }

    var isDefault: Bool {
        createTop == Self.defaultTop && shareGap == Self.defaultSectionGap
            && joinTop == Self.defaultTop && codeEntryGap == Self.defaultSectionGap
    }

    func reset() {
        createTop = Self.defaultTop
        shareGap = Self.defaultSectionGap
        joinTop = Self.defaultTop
        codeEntryGap = Self.defaultSectionGap
    }

    /// For pasting into a chat or the code
    var summary: String {
        func pt(_ value: CGFloat) -> String { String(format: "%.0f", value) }
        return """
        Manual pairing layout (pt; tops from the safe-area top)
        create: top \(pt(createTop)), QR-share \(pt(shareGap))
        join: top \(pt(joinTop)), camera-code \(pt(codeEntryGap))
        """
    }
}
