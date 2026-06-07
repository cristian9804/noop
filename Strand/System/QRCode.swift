import Foundation
import CoreImage.CIFilterBuiltins
import AppKit

/// Generates a crisp QR code image for a string (e.g. a crypto address) so people can scan straight
/// from their wallet — the lowest-friction way to donate.
enum QRCode {
    private static let context = CIContext()

    static func image(for string: String, scale: CGFloat = 12) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
              let cg = context.createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
