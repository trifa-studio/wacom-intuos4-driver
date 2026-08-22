import Foundation
import CoreGraphics
import AppKit

public final class DisplayToggleManager: @unchecked Sendable {
    public static let shared = DisplayToggleManager()

    private var currentIndex: Int = 0

    public init() {}

    /// Cycles between Display 1, Display 2 (if present), and Full Desktop.
    /// Returns the descriptive name for HUD display.
    @discardableResult
    public func cycleNextDisplay(synthesizer: TabletEventSynthesizer) -> String {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return "Main Display" }

        // Total options = screens.count (individual monitors) + 1 (full desktop)
        let totalOptions = screens.count > 1 ? screens.count + 1 : 1
        currentIndex = (currentIndex + 1) % totalOptions

        if currentIndex < screens.count {
            let screen = screens[currentIndex]
            let desc = screen.localizedName.isEmpty ? "Display \(currentIndex + 1)" : screen.localizedName
            if currentIndex == 0 {
                synthesizer.coordinateTransformer.mode = .mainDisplay
                return "Display 1: \(desc)"
            } else {
                if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                    synthesizer.coordinateTransformer.mode = .specificDisplay(num)
                } else {
                    synthesizer.coordinateTransformer.mode = .mainDisplay
                }
                return "Display \(currentIndex + 1): \(desc)"
            }
        } else {
            synthesizer.coordinateTransformer.mode = .fullDesktop
            return "Full Desktop (All Displays)"
        }
    }

    /// Toggles Precision Mode (2x zoom active area for fine pixel detailing).
    @discardableResult
    public func togglePrecisionMode(synthesizer: TabletEventSynthesizer) -> Bool {
        synthesizer.coordinateTransformer.isPrecisionMode.toggle()
        return synthesizer.coordinateTransformer.isPrecisionMode
    }
}
