import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
#if canImport(UIKit)
import UIKit
#endif

/// Dotted QR code: modules drawn as round dots, the corner markers as thin rings with a centre
/// dot, and the Dari logo in a small cleared space in the middle. Generated at the highest error correction
/// (H, ~30% recoverable) so the styling and the logo don't get in the way of scanning.
enum StyledQRCode {
    /// Look of the code, in modules (one module = one QR grid square)
    struct Style {
        /// Dot diameter as a share of a module - large enough for cameras to read reliably
        var dotScale: CGFloat = 0.78
        /// Corner markers: a thin ring with a centre dot. The dot is the smallest that still scans:
        /// with the 0.44 ring, Apple's reader decoded 60/60 at 2.6 in every test condition, but only
        /// 22/60 camera-like shots at 2.4 and 0/60 sharp ones at 2.1 (it read those only when blurred)
        var finderDiameter: CGFloat = 6.6
        var finderRingWidth: CGFloat = 0.44
        var finderDotDiameter: CGFloat = 2.6
        /// Logo width, and the clear space kept around it (1.5 clears one more ring of dots than 0.6)
        var logoWidth: CGFloat = 3.6
        var logoMargin: CGFloat = 1.5
    }

    /// Pairing QR payload. The Join scanner keeps only the digits, so this still yields the
    /// 6-digit code, while the longer link gives a denser, more detailed code (33×33 modules).
    static func pairingPayload(code: String, language: String) -> String {
        "dari://join?code=\(code)&from=\(language)"
    }

    /// Module grid (true = dark), trimmed of Core Image's quiet zone
    static func modules(for payload: String) -> [[Bool]]? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "H"
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output, from: output.extent),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }

        // Bitmap memory runs top row first; one pixel per module
        let bytesPerRow = context.bytesPerRow
        func isDark(_ x: Int, _ y: Int) -> Bool { data[y * bytesPerRow + x] < 128 }
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        for y in 0..<image.height {
            for x in 0..<image.width where isDark(x, y) {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard minX <= maxX, minY <= maxY else { return nil }
        return (minY...maxY).map { y in (minX...maxX).map { x in isDark(x, y) } }
    }

    /// Draws the code filling `rect` of a context whose origin is top-left (UIKit-style).
    /// `logo` gives the logo's width/height ratio and draws it into the rect it's handed.
    static func draw(_ modules: [[Bool]], in context: CGContext, rect: CGRect, color: CGColor,
                     style: Style = Style(), logo: (aspect: CGFloat, draw: (CGRect) -> Void)?) {
        let n = modules.count
        let cell = rect.width / CGFloat(n)
        let finders = [(0, 0), (0, n - 7), (n - 7, 0)]

        // Logo box centred on the symbol; clear only the modules whose centres fall inside it
        // (plus a margin), so the dots sit evenly around the logo on every side
        let logoRect: CGRect? = logo.map { logo in
            let width = style.logoWidth * cell
            let height = width / logo.aspect
            return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
        }
        let clearRect = logoRect?.insetBy(dx: -style.logoMargin * cell, dy: -style.logoMargin * cell)

        func isReserved(_ r: Int, _ c: Int) -> Bool {
            if finders.contains(where: { r >= $0.0 && r < $0.0 + 7 && c >= $0.1 && c < $0.1 + 7 }) { return true }
            guard let clearRect else { return false }
            let centre = CGPoint(x: rect.minX + (CGFloat(c) + 0.5) * cell, y: rect.minY + (CGFloat(r) + 0.5) * cell)
            return clearRect.contains(centre)
        }

        context.setFillColor(color)
        context.setStrokeColor(color)

        // Data modules (including the alignment pattern) as dots
        let inset = cell * (1 - style.dotScale) / 2
        for r in 0..<n {
            for c in 0..<n where modules[r][c] && !isReserved(r, c) {
                context.fillEllipse(in: CGRect(x: rect.minX + CGFloat(c) * cell, y: rect.minY + CGFloat(r) * cell,
                                               width: cell, height: cell).insetBy(dx: inset, dy: inset))
            }
        }

        // Corner markers: a ring and a centre dot, centred on each 7×7 finder square
        context.setLineWidth(style.finderRingWidth * cell)
        for (r, c) in finders {
            let centre = CGPoint(x: rect.minX + (CGFloat(c) + 3.5) * cell, y: rect.minY + (CGFloat(r) + 3.5) * cell)
            let ringDiameter = (style.finderDiameter - style.finderRingWidth) * cell  // stroke is centred on the path
            context.strokeEllipse(in: CGRect(x: centre.x - ringDiameter / 2, y: centre.y - ringDiameter / 2,
                                             width: ringDiameter, height: ringDiameter))
            let dot = style.finderDotDiameter * cell
            context.fillEllipse(in: CGRect(x: centre.x - dot / 2, y: centre.y - dot / 2, width: dot, height: dot))
        }

        if let logo, let logoRect {
            logo.draw(logoRect)
        }
    }

    #if canImport(UIKit)
    /// Styled QR as a transparent image, `size` points square with no quiet zone (the page around
    /// it provides one). Uses the "qr-logo" asset in the middle.
    static func image(for payload: String, size: CGFloat = 400,
                      color: UIColor = UIColor(AppColors.primaryText)) -> UIImage? {
        guard let modules = modules(for: payload) else { return nil }
        let logoImage = UIImage(named: "qr-logo")?.withTintColor(color, renderingMode: .alwaysOriginal)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { renderer in
            draw(modules, in: renderer.cgContext, rect: CGRect(x: 0, y: 0, width: size, height: size),
                 color: color.cgColor,
                 logo: logoImage.map { image in (image.size.width / image.size.height, { image.draw(in: $0) }) })
        }
    }
    #endif
}
