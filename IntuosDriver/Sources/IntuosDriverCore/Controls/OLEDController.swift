import Foundation
import IOKit.hid

/// Controls the Touch Ring quadrant LEDs, OLED display brightness, and 8 ExpressKey OLED screens
/// using the exact hardware protocol reverse-engineered from the official Wacom Intuos4 driver.
public final class OLEDController: @unchecked Sendable {
    public weak var transport: USBTransport?
    private let writeQueue = DispatchQueue(label: "com.intuos.oled.queue", qos: .utility)

    public init(transport: USBTransport? = nil) {
        self.transport = transport
    }

    /// Sets the active Touch Ring quadrant LED (0..3), Ring LED brightness (0..15), and OLED brightness (0..15).
    /// Official driver layout for Report 0x20 (9 bytes total):
    /// [0x20, LEDState, LEDNormal, LEDDown, OLEDStateUpper, OLEDStateLower, 0x00, 0x00, 0x00]
    @discardableResult
    public func setRingLED(mode: UInt8, ringBrightness: UInt8 = 15, oledBrightness: UInt8 = 15) -> Bool {
        guard let transport else { return false }
        let normalLum: UInt8 = UInt8(min(127, Int(ringBrightness) * 8 + 7))
        let oledLum: UInt8 = (oledBrightness & 0x0F) | 0x30
        let payload: [UInt8] = [
            (mode & 0x03) | 0x40, // LEDState: active quadrant 0..3 + enable flag
            normalLum,            // LEDNormal: 0..127
            normalLum,            // LEDDown: 0..127
            oledLum,              // OLEDState (Upper bank displays 0..3)
            oledLum,              // OLEDState (Lower bank displays 4..7)
            0x00, 0x00, 0x00
        ]
        return transport.sendFeatureReport(reportID: 0x20, payload: payload)
    }

    /// Sets a 64×32 text label on an ExpressKey OLED display (key 0..7).
    @discardableResult
    public func setKeyText(index: Int, text: String, fontSize: CGFloat = 11.0) -> Bool {
        guard index >= 0, index < WacomConstants.expressKeyCount else { return false }
        let payload1024 = OLEDEncoder.renderText(text, fontSize: fontSize)
        return setKeyImage(index: index, payload1024: payload1024)
    }

    /// Sets a 1024-byte 4-bit nibbilized image buffer on an ExpressKey OLED display (key 0..7).
    @discardableResult
    public func setKeyImage(index: Int, payload1024: [UInt8]) -> Bool {
        guard index >= 0, index < WacomConstants.expressKeyCount else { return false }
        guard payload1024.count == OLEDEncoder.payloadSize else { return false }
        guard let transport else { return false }

        // Start display transaction for this key
        transport.sendFeatureReport(reportID: 0x21, payload: [0x01])
        Thread.sleep(forTimeInterval: 0.005)

        // Send 4 blocks of 256 bytes (Report 0x23)
        for block: UInt8 in 0..<4 {
            let start = Int(block) * 256
            let slice = Array(payload1024[start ..< start + 256])
            let blockPayload: [UInt8] = [UInt8(index), block] + slice
            transport.sendFeatureReport(reportID: 0x23, payload: blockPayload)
            Thread.sleep(forTimeInterval: 0.005)
        }

        // Commit display transaction for this key
        transport.sendFeatureReport(reportID: 0x21, payload: [0x00])
        Thread.sleep(forTimeInterval: 0.005)
        return true
    }

    /// Asynchronously writes all 8 key labels with per-key transaction framing so both upper and lower banks commit properly.
    public func applyLabels(_ labels: [String] = ["Undo", "Redo", "Brush-", "Brush+", "Hand", "Alt", "Zoom+", "Zoom-"], ringMode: UInt8 = 0, brightness: UInt8 = 15, isFlipped: Bool = false, completion: (@Sendable () -> Void)? = nil) {
        writeQueue.async { [weak self] in
            guard let self, let transport = self.transport else { return }

            // 1. Ensure LED & OLED brightness are enabled across both upper and lower banks
            self.setRingLED(mode: ringMode, ringBrightness: brightness, oledBrightness: brightness)
            Thread.sleep(forTimeInterval: 0.02)

            // 2. Stream all 8 OLED displays with discrete per-key transaction framing
            // The hardware microcontroller requires start (0x21, 0x01) and commit (0x21, 0x00)
            // around each button's 4 image blocks to prevent FIFO overflow.
            for (keyIdx, label) in labels.prefix(8).enumerated() {
                let img1024 = OLEDEncoder.renderText(label, isFlipped: isFlipped)
                
                // Open key transaction
                transport.sendFeatureReport(reportID: 0x21, payload: [0x01])
                Thread.sleep(forTimeInterval: 0.005)

                // Send 4 chunks of 256 bytes (Report 0x23)
                for block: UInt8 in 0..<4 {
                    let start = Int(block) * 256
                    let slice = Array(img1024[start ..< start + 256])
                    let blockPayload: [UInt8] = [UInt8(keyIdx), block] + slice
                    transport.sendFeatureReport(reportID: 0x23, payload: blockPayload)
                    Thread.sleep(forTimeInterval: 0.005)
                }

                // Commit key transaction
                transport.sendFeatureReport(reportID: 0x21, payload: [0x00])
                Thread.sleep(forTimeInterval: 0.01)
            }

            // 3. Finalize LED State
            self.setRingLED(mode: ringMode, ringBrightness: brightness, oledBrightness: brightness)

            completion?()
        }
    }
}
