import Foundation
import CoreGraphics
import Carbon.HIToolbox

public enum KeyAction: Sendable {
    case keystroke(keyCode: CGKeyCode, flags: CGEventFlags)
    case undo
    case redo
    case zoomIn
    case zoomOut
    case brushSizeIncrease
    case brushSizeDecrease
    case radialMenu
    case displayToggle
    case precisionMode
    case custom(@Sendable () -> Void)

    public var displayLabel: String {
        switch self {
        case .undo: return "Undo"
        case .redo: return "Redo"
        case .zoomIn: return "Zoom +"
        case .zoomOut: return "Zoom -"
        case .brushSizeIncrease: return "Brush +"
        case .brushSizeDecrease: return "Brush -"
        case .radialMenu: return "Radial Menu"
        case .displayToggle: return "Display Toggle"
        case .precisionMode: return "Precision Mode"
        case .keystroke(let code, _):
            if code == CGKeyCode(kVK_Space) { return "Pan / Hand" }
            if code == CGKeyCode(kVK_Option) { return "Eyedropper" }
            return "Key \(code)"
        case .custom: return "Custom"
        }
    }

    public static func from(string: String) -> KeyAction {
        switch string.lowercased() {
        case "undo": return .undo
        case "redo": return .redo
        case "zoomin", "zoom+": return .zoomIn
        case "zoomout", "zoom-": return .zoomOut
        case "brushsizeincrease", "brush+": return .brushSizeIncrease
        case "brushsizedecrease", "brush-": return .brushSizeDecrease
        case "radialmenu", "radial": return .radialMenu
        case "displaytoggle", "displays": return .displayToggle
        case "precisionmode", "precise": return .precisionMode
        case "hand", "pan": return .keystroke(keyCode: CGKeyCode(kVK_Space), flags: [])
        case "eyedropper", "eyedrop", "alt", "option": return .keystroke(keyCode: CGKeyCode(kVK_Option), flags: .maskAlternate)
        default: return .undo
        }
    }

    public var identifier: String {
        switch self {
        case .undo: return "undo"
        case .redo: return "redo"
        case .zoomIn: return "zoomIn"
        case .zoomOut: return "zoomOut"
        case .brushSizeIncrease: return "brush+"
        case .brushSizeDecrease: return "brush-"
        case .radialMenu: return "radialMenu"
        case .displayToggle: return "displayToggle"
        case .precisionMode: return "precisionMode"
        case .keystroke(let code, _):
            if code == CGKeyCode(kVK_Space) { return "hand" }
            if code == CGKeyCode(kVK_Option) { return "eyedropper" }
            return "key_\(code)"
        case .custom: return "custom"
        }
    }
}

public protocol ExpressKeyListener: AnyObject, Sendable {
    func expressKeyDidTrigger(index: Int, action: KeyAction, label: String)
}

public final class ExpressKeyManager: @unchecked Sendable {
    private var previousKeyStates: [Bool] = [Bool](repeating: false, count: 8)
    public var keyBindings: [KeyAction]
    public weak var listener: ExpressKeyListener?
    public var onRadialMenuTrigger: (@Sendable () -> Void)?
    public var onDisplayToggleTrigger: (@Sendable () -> Void)?
    public var onPrecisionModeTrigger: (@Sendable () -> Void)?

    public init() {
        // Default ExpressKey bindings suitable for Photoshop / Illustrator / Digital Art
        self.keyBindings = [
            .undo,                                       // Key 0: Cmd + Z
            .redo,                                       // Key 1: Cmd + Shift + Z
            .brushSizeDecrease,                          // Key 2: [
            .brushSizeIncrease,                          // Key 3: ]
            .keystroke(keyCode: CGKeyCode(kVK_Space), flags: []), // Key 4: Pan / Hand
            .displayToggle,                              // Key 5: Cycle Monitors
            .radialMenu,                                 // Key 6: On-screen Radial Menu
            .precisionMode                               // Key 7: Precision 2x Zoom
        ]
    }

    public func processPadEvent(_ event: PadEvent) {
        for (index, isPressed) in event.keys.enumerated() {
            guard index < keyBindings.count else { break }
            let wasPressed = previousKeyStates[index]
            
            if isPressed && !wasPressed {
                let action = keyBindings[index]
                executeAction(action)
                listener?.expressKeyDidTrigger(index: index, action: action, label: action.displayLabel)
            }
            previousKeyStates[index] = isPressed
        }
    }

    private func executeAction(_ action: KeyAction) {
        switch action {
        case .undo:
            postKeystroke(keyCode: CGKeyCode(kVK_ANSI_Z), flags: .maskCommand)
        case .redo:
            postKeystroke(keyCode: CGKeyCode(kVK_ANSI_Z), flags: [.maskCommand, .maskShift])
        case .brushSizeIncrease:
            postKeystroke(keyCode: CGKeyCode(kVK_ANSI_RightBracket), flags: [])
        case .brushSizeDecrease:
            postKeystroke(keyCode: CGKeyCode(kVK_ANSI_LeftBracket), flags: [])
        case .zoomIn:
            postKeystroke(keyCode: CGKeyCode(kVK_ANSI_Equal), flags: .maskCommand)
        case .zoomOut:
            postKeystroke(keyCode: CGKeyCode(kVK_ANSI_Minus), flags: .maskCommand)
        case .radialMenu:
            onRadialMenuTrigger?()
        case .displayToggle:
            onDisplayToggleTrigger?()
        case .precisionMode:
            onPrecisionModeTrigger?()
        case .keystroke(let keyCode, let flags):
            postKeystroke(keyCode: keyCode, flags: flags)
        case .custom(let closure):
            closure()
        }
    }

    private func postKeystroke(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            return
        }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
