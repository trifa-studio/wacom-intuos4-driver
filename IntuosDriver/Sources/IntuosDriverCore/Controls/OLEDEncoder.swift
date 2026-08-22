import Foundation
import CoreGraphics
import CoreText
import AppKit

public final class OLEDEncoder: Sendable {
    public static let width = 64
    public static let height = 32
    public static let payloadSize = 1024 // (64 * 32) / 2 (4-bit nibbles)

    public init() {}

    /// Renders a short text string (e.g. "Undo", "Brush+", "Zoom") into a 1024-byte 4-bit nibbilized Intuos4 OLED buffer
    public static func renderText(_ text: String, fontSize: CGFloat = 11.0, isFlipped: Bool = false) -> [UInt8] {
        var rawGrayscale = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        
        guard let context = CGContext(
            data: &rawGrayscale,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return [UInt8](repeating: 0, count: payloadSize)
        }

        // Fill background with black
        context.setFillColor(gray: 0.0, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Draw centered anti-aliased white text
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1.0, alpha: 1.0)
        ]
        let attrString = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attrString)
        let bounds = CTLineGetImageBounds(line, context)
        
        let textX = max(2.0, (CGFloat(width) - bounds.width) / 2.0)
        let textY = max(2.0, (CGFloat(height) - bounds.height) / 2.0 + 4.0)
        
        context.textPosition = CGPoint(x: textX, y: textY)
        CTLineDraw(line, context)

        return packGrayscaleTo4BitNibbles(rawGrayscale: rawGrayscale, isFlipped: isFlipped)
    }

    /// Converts 64x32 8-bit grayscale pixels into the official 4-bit nibbilized format (1024 bytes)
    public static func packGrayscaleTo4BitNibbles(rawGrayscale: [UInt8], isFlipped: Bool = false) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: payloadSize)
        var outIdx = 0
        
        if isFlipped {
            for y in stride(from: height - 1, through: 0, by: -2) {
                for x in 0..<width {
                    let p0 = rawGrayscale[y * width + x] >> 4
                    let p1 = (y - 1 >= 0) ? (rawGrayscale[(y - 1) * width + x] >> 4) : 0
                    output[outIdx] = (p1 << 4) | (p0 & 0x0F)
                    outIdx += 1
                }
            }
        } else {
            for y in stride(from: 0, to: height, by: 2) {
                for x in (0..<width).reversed() {
                    let p0 = rawGrayscale[y * width + x] >> 4
                    let p1 = (y + 1 < height) ? (rawGrayscale[(y + 1) * width + x] >> 4) : 0
                    output[outIdx] = (p1 << 4) | (p0 & 0x0F)
                    outIdx += 1
                }
            }
        }
        
        return output
    }
}
