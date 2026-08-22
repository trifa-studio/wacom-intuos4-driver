import Foundation
import CoreGraphics
import AppKit

public enum MappingMode: Sendable, Equatable {
    case mainDisplay
    case fullDesktop
    case specificDisplay(CGDirectDisplayID)
}

public struct CoordinateTransformer: Sendable {
    public var mode: MappingMode
    public var preserveAspectRatio: Bool
    public var isOrientationFlipped: Bool
    public var isPrecisionMode: Bool
    public var precisionScale: Double
    public var precisionCenter: CGPoint?

    public init(
        mode: MappingMode = .mainDisplay,
        preserveAspectRatio: Bool = false,
        isOrientationFlipped: Bool = false,
        isPrecisionMode: Bool = false,
        precisionScale: Double = 0.5
    ) {
        self.mode = mode
        self.preserveAspectRatio = preserveAspectRatio
        self.isOrientationFlipped = isOrientationFlipped
        self.isPrecisionMode = isPrecisionMode
        self.precisionScale = precisionScale
    }

    /// Maps normalized tablet coords (0…1) into **CGEvent global space** (top-left origin).
    public func transform(normalizedX: Double, normalizedY: Double) -> CGPoint {
        var effectiveX = max(0.0, min(1.0, normalizedX))
        var effectiveY = max(0.0, min(1.0, normalizedY))

        // 180° Left-Handed Orientation Flip
        if isOrientationFlipped {
            effectiveX = 1.0 - effectiveX
            effectiveY = 1.0 - effectiveY
        }

        let target = targetRectGlobalTopLeft()

        if preserveAspectRatio {
            let tabletAspect = Double(WacomConstants.maxX) / Double(WacomConstants.maxY)
            let screenAspect = target.width / max(target.height, 1)
            if screenAspect > tabletAspect {
                let scale = tabletAspect / screenAspect
                effectiveX = (effectiveX - 0.5) * scale + 0.5
            } else {
                let scale = screenAspect / tabletAspect
                effectiveY = (effectiveY - 0.5) * scale + 0.5
            }
        }

        if isPrecisionMode {
            let center = precisionCenter ?? CGPoint(x: target.midX, y: target.midY)
            let pWidth = target.width * precisionScale
            let pHeight = target.height * precisionScale
            let pOriginX = center.x - pWidth / 2.0
            let pOriginY = center.y - pHeight / 2.0
            let screenX = pOriginX + effectiveX * pWidth
            let screenY = pOriginY + effectiveY * pHeight
            return CGPoint(x: screenX, y: screenY)
        }

        var screenX = target.origin.x + effectiveX * target.width
        var screenY = target.origin.y + effectiveY * target.height

        // Ensure hitting outer boundary pixels so macOS Dock reveal,
        // menu bar auto-show, and hot corners activate cleanly
        if effectiveY >= 0.995 {
            screenY = target.maxY - 0.5
        } else if effectiveY <= 0.005 {
            screenY = target.minY
        }
        if effectiveX >= 0.995 {
            screenX = target.maxX - 0.5
        } else if effectiveX <= 0.005 {
            screenX = target.minX
        }

        return CGPoint(x: screenX, y: screenY)
    }

    /// AppKit `NSScreen.frame` is bottom-left; CG events use top-left global coordinates.
    private func targetRectGlobalTopLeft() -> CGRect {
        let desktopHeight = NSScreen.screens.map { $0.frame.maxY }.max() ?? 1080

        switch mode {
        case .mainDisplay:
            guard let main = NSScreen.main else {
                return CGRect(x: 0, y: 0, width: 1920, height: 1080)
            }
            return appKitToGlobalTopLeft(main.frame, desktopHeight: desktopHeight)

        case .fullDesktop:
            var union = CGRect.null
            for screen in NSScreen.screens {
                let g = appKitToGlobalTopLeft(screen.frame, desktopHeight: desktopHeight)
                union = union.isNull ? g : union.union(g)
            }
            return union.isNull ? CGRect(x: 0, y: 0, width: 1920, height: 1080) : union

        case .specificDisplay(let displayID):
            return CGDisplayBounds(displayID)
        }
    }

    private func appKitToGlobalTopLeft(_ appKitFrame: CGRect, desktopHeight: CGFloat) -> CGRect {
        let top = desktopHeight - appKitFrame.maxY
        return CGRect(x: appKitFrame.origin.x, y: top, width: appKitFrame.width, height: appKitFrame.height)
    }
}
