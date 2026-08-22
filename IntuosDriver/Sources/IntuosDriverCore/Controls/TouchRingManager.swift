import Foundation
import CoreGraphics
import Carbon.HIToolbox

public enum TouchRingMode: Int, CaseIterable, Sendable {
    case autoScrollZoom = 0
    case cycleLayers = 1
    case brushSize = 2
    case rotateCanvas = 3

    public init(modeIndex: UInt8) {
        self = TouchRingMode(rawValue: Int(modeIndex) % 4) ?? .brushSize
    }
}

public final class TouchRingManager: @unchecked Sendable {
    private var lastPosition: UInt8 = 0
    private var wasTouched: Bool = false
    public var currentMode: TouchRingMode = .brushSize

    public init() {}

    public func processPadEvent(_ event: PadEvent) {
        currentMode = TouchRingMode(modeIndex: event.mode)

        if event.ringTouched {
            if wasTouched && lastPosition != event.ringPosition {
                let diff = calculateDelta(oldPos: lastPosition, newPos: event.ringPosition)
                if abs(diff) > 0 {
                    handleRotation(delta: diff)
                }
            }
            lastPosition = event.ringPosition
            wasTouched = true
        } else {
            wasTouched = false
        }
    }

    private func calculateDelta(oldPos: UInt8, newPos: UInt8) -> Int {
        var delta = Int(newPos) - Int(oldPos)
        if delta > 36 {
            delta -= 72
        } else if delta < -36 {
            delta += 72
        }
        return delta
    }

    private func handleRotation(delta: Int) {
        let isClockwise = delta > 0
        let steps = min(4, abs(delta))

        for _ in 0..<steps {
            switch currentMode {
            case .brushSize:
                let key = isClockwise ? CGKeyCode(kVK_ANSI_RightBracket) : CGKeyCode(kVK_ANSI_LeftBracket)
                postKey(key)
            case .autoScrollZoom:
                postScrollWheel(deltaY: isClockwise ? 3 : -3)
            case .cycleLayers:
                let key = isClockwise ? CGKeyCode(kVK_ANSI_RightBracket) : CGKeyCode(kVK_ANSI_LeftBracket)
                postKey(key, flags: .maskAlternate)
            case .rotateCanvas:
                postKey(CGKeyCode(kVK_ANSI_R), flags: isClockwise ? [] : .maskShift)
            }
        }
    }

    private func postKey(_ code: CGKeyCode, flags: CGEventFlags = []) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func postScrollWheel(deltaY: Int32) {
        guard let scrollEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: deltaY,
            wheel2: 0,
            wheel3: 0
        ) else { return }
        scrollEvent.post(tap: .cghidEventTap)
    }
}
