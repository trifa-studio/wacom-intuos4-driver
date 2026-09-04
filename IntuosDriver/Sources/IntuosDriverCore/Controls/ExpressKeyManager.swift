import Foundation
import CoreGraphics
import Carbon.HIToolbox
import AppKit

public enum KeyAction: Sendable, Equatable {
    case keystroke(keyCode: CGKeyCode, flags: CGEventFlags)
    case modifier(flags: CGEventFlags, keyCode: CGKeyCode)
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

    public static func == (lhs: KeyAction, rhs: KeyAction) -> Bool {
        switch (lhs, rhs) {
        case (.undo, .undo), (.redo, .redo), (.zoomIn, .zoomIn), (.zoomOut, .zoomOut),
             (.brushSizeIncrease, .brushSizeIncrease), (.brushSizeDecrease, .brushSizeDecrease),
             (.radialMenu, .radialMenu), (.displayToggle, .displayToggle), (.precisionMode, .precisionMode):
            return true
        case (.keystroke(let k1, let f1), .keystroke(let k2, let f2)):
            return k1 == k2 && f1 == f2
        case (.modifier(let f1, let k1), .modifier(let f2, let k2)):
            return f1 == f2 && k1 == k2
        default:
            return false
        }
    }

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
        case .modifier(let flags, _):
            if flags.contains(.maskAlternate) { return "Eyedropper" }
            if flags.contains(.maskShift) { return "Shift" }
            if flags.contains(.maskCommand) { return "Command" }
            if flags.contains(.maskControl) { return "Control" }
            return "Modifier"
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
        case "eyedropper", "eyedrop", "alt", "option": return .modifier(flags: .maskAlternate, keyCode: CGKeyCode(kVK_Option))
        case "shift": return .modifier(flags: .maskShift, keyCode: CGKeyCode(kVK_Shift))
        case "cmd", "command": return .modifier(flags: .maskCommand, keyCode: CGKeyCode(kVK_Command))
        case "ctrl", "control": return .modifier(flags: .maskControl, keyCode: CGKeyCode(kVK_Control))
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
        case .modifier(let flags, _):
            if flags.contains(.maskAlternate) { return "eyedropper" }
            if flags.contains(.maskShift) { return "shift" }
            if flags.contains(.maskCommand) { return "command" }
            if flags.contains(.maskControl) { return "control" }
            return "modifier"
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
    public var onModifiersChanged: (@Sendable (CGEventFlags) -> Void)?

    /// Currently active ExpressKey modifier flags (e.g. holding Alt/Option or Shift)
    public private(set) var activeModifiers: CGEventFlags = []
    /// Track non-modifier keys held down (e.g. Space for Hand/Pan)
    private var activeHoldKeyCodes = Set<CGKeyCode>()
    /// Track each held modifier keycode and its associated flag for precise release
    private var activeModifierKeys: [CGKeyCode: CGEventFlags] = [:]

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
            let action = keyBindings[index]

            if isPressed && !wasPressed {
                // Button Pressed Down
                handleKeyPress(at: index, action: action)
            } else if !isPressed && wasPressed {
                // Button Released Up
                handleKeyRelease(at: index, action: action)
            }
            previousKeyStates[index] = isPressed
        }
    }

    private func handleKeyPress(at index: Int, action: KeyAction) {
        switch action {
        case .modifier(let flags, let keyCode):
            activeModifiers.insert(flags)
            activeModifierKeys[keyCode] = flags
            postFlagsChanged(keyCode: keyCode, newFlags: activeModifiers)
            onModifiersChanged?(activeModifiers)
            listener?.expressKeyDidTrigger(index: index, action: action, label: action.displayLabel)

        case .keystroke(let keyCode, let flags):
            if keyCode == CGKeyCode(kVK_Space) {
                // Space is a holdable navigation key (Pan/Hand tool in Photoshop/Illustrator)
                activeHoldKeyCodes.insert(keyCode)
                postKeyDown(keyCode: keyCode, flags: flags)
                listener?.expressKeyDidTrigger(index: index, action: action, label: action.displayLabel)
            } else if keyCode == CGKeyCode(kVK_Option) {
                // Fallback for keystroke with Option
                activeModifiers.insert(.maskAlternate)
                activeModifierKeys[keyCode] = .maskAlternate
                postFlagsChanged(keyCode: keyCode, newFlags: activeModifiers)
                onModifiersChanged?(activeModifiers)
                listener?.expressKeyDidTrigger(index: index, action: action, label: action.displayLabel)
            } else {
                // One-shot keystroke
                postKeystroke(keyCode: keyCode, flags: flags)
                listener?.expressKeyDidTrigger(index: index, action: action, label: action.displayLabel)
            }

        case .undo:
            postKeystroke(keyCode: CGKeyCode(kVK_ANSI_Z), flags: .maskCommand)
            listener?.expressKeyDidTrigger(index: index, action: action, label: action.displayLabel)
        case .redo:
            postKeystroke(keyCode: CGKeyCode(kVK_ANSI_Z), flags: [.maskCommand, .maskShift])
            listener?.expressKeyDidTrigger(index: index, action: action, label: action.displayLabel)
        case .brushSizeIncrease:
            postKeystroke(keyCode: CGKeyCode(kVK_ANSI_RightBracket), flags: [])
            listener?.expressKeyDidTrigger(index: index, action: action, label: action.displayLabel)
        case .brushSizeDecrease:
            postKeystroke(keyCode: CGKeyCode(kVK_ANSI_LeftBracket), flags: [])
            listener?.expressKeyDidTrigger(index: index, action: action, label: action.displayLabel)
        case .zoomIn:
            postKeystroke(keyCode: CGKeyCode(kVK_ANSI_Equal), flags: .maskCommand)
            listener?.expressKeyDidTrigger(index: index, action: action, label: action.displayLabel)
        case .zoomOut:
            postKeystroke(keyCode: CGKeyCode(kVK_ANSI_Minus), flags: .maskCommand)
            listener?.expressKeyDidTrigger(index: index, action: action, label: action.displayLabel)
        case .radialMenu:
            onRadialMenuTrigger?()
            listener?.expressKeyDidTrigger(index: index, action: action, label: action.displayLabel)
        case .displayToggle:
            onDisplayToggleTrigger?()
            listener?.expressKeyDidTrigger(index: index, action: action, label: action.displayLabel)
        case .precisionMode:
            onPrecisionModeTrigger?()
            listener?.expressKeyDidTrigger(index: index, action: action, label: action.displayLabel)
        case .custom(let closure):
            closure()
            listener?.expressKeyDidTrigger(index: index, action: action, label: action.displayLabel)
        }
    }

    private func handleKeyRelease(at index: Int, action: KeyAction) {
        switch action {
        case .modifier(let flags, let keyCode):
            activeModifiers.subtract(flags)
            activeModifierKeys.removeValue(forKey: keyCode)
            postFlagsChanged(keyCode: keyCode, newFlags: activeModifiers)
            onModifiersChanged?(activeModifiers)

        case .keystroke(let keyCode, let flags):
            if keyCode == CGKeyCode(kVK_Space) {
                activeHoldKeyCodes.remove(keyCode)
                postKeyUp(keyCode: keyCode, flags: flags)
            } else if keyCode == CGKeyCode(kVK_Option) {
                activeModifiers.remove(.maskAlternate)
                activeModifierKeys.removeValue(forKey: keyCode)
                postFlagsChanged(keyCode: keyCode, newFlags: activeModifiers)
                onModifiersChanged?(activeModifiers)
            }

        default:
            break
        }
    }

    public func reset() {
        for code in activeHoldKeyCodes {
            postKeyUp(keyCode: code, flags: [])
        }
        activeHoldKeyCodes.removeAll()

        for (code, flags) in activeModifierKeys {
            activeModifiers.subtract(flags)
            postFlagsChanged(keyCode: code, newFlags: activeModifiers)
        }
        activeModifierKeys.removeAll()

        if !activeModifiers.isEmpty {
            let old = activeModifiers
            activeModifiers = []
            postFlagsChanged(keyCode: keyCode(for: old), newFlags: [])
        }
        onModifiersChanged?([])
        previousKeyStates = [Bool](repeating: false, count: 8)
    }

    private func postFlagsChanged(keyCode: CGKeyCode, newFlags: CGEventFlags) {
        let source = CGEventSource(stateID: .privateState)
        guard let event = CGEvent(source: source) else { return }
        event.type = .flagsChanged
        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(keyCode))
        var current = CGEventSource.flagsState(.hidSystemState)
        current.insert(newFlags)
        event.flags = current
        event.post(tap: .cghidEventTap)

        // Immediately refresh cursor so Photoshop instantly swaps between
        // Target Crosshair (Sample Pen) and Brush Size Circle with 0 delay.
        postCursorRefresh(flags: current)
    }

    private func postCursorRefresh(flags: CGEventFlags) {
        let loc = CGEvent(source: nil)?.location ?? .zero
        let source = CGEventSource(stateID: .privateState)
        if let moveEvent = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: loc, mouseButton: .left) {
            moveEvent.flags = flags
            if let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
                moveEvent.postToPid(frontPid)
            }
            moveEvent.post(tap: .cghidEventTap)
        }
    }

    private func postKeyDown(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .privateState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) else { return }
        var current = CGEventSource.flagsState(.hidSystemState)
        current.insert(flags)
        current.insert(activeModifiers)
        keyDown.flags = current
        keyDown.post(tap: .cghidEventTap)
    }

    private func postKeyUp(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .privateState)
        guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return }
        var current = CGEventSource.flagsState(.hidSystemState)
        current.insert(flags)
        current.insert(activeModifiers)
        keyUp.flags = current
        keyUp.post(tap: .cghidEventTap)
    }

    private func postKeystroke(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .privateState)
        let physicalFlags = CGEventSource.flagsState(.hidSystemState)
        var chordFlags = physicalFlags
        chordFlags.insert(activeModifiers)

        // Shortcut modifiers need real transitions. Attaching Command only as a
        // flag to Z-down/Z-up can leave the session's last synthetic flag state
        // latched, which later contaminates tablet clicks after app switching.
        let shortcutModifiers: [(CGEventFlags, CGKeyCode)] = [
            (.maskControl, CGKeyCode(kVK_Control)),
            (.maskAlternate, CGKeyCode(kVK_Option)),
            (.maskShift, CGKeyCode(kVK_Shift)),
            (.maskCommand, CGKeyCode(kVK_Command))
        ]
        let modifiersToPress = shortcutModifiers.filter {
            flags.contains($0.0) && !chordFlags.contains($0.0)
        }
        for (flag, modifierKeyCode) in modifiersToPress {
            chordFlags.insert(flag)
            postKeyboardEvent(keyCode: modifierKeyCode, keyDown: true, flags: chordFlags, source: source)
        }

        chordFlags.insert(flags)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            for (flag, modifierKeyCode) in modifiersToPress.reversed() {
                chordFlags.subtract(flag)
                postKeyboardEvent(keyCode: modifierKeyCode, keyDown: false, flags: chordFlags, source: source)
            }
            return
        }
        keyDown.flags = chordFlags
        keyUp.flags = chordFlags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        for (flag, modifierKeyCode) in modifiersToPress.reversed() {
            chordFlags.subtract(flag)
            postKeyboardEvent(keyCode: modifierKeyCode, keyDown: false, flags: chordFlags, source: source)
        }
    }

    private func postKeyboardEvent(
        keyCode: CGKeyCode,
        keyDown: Bool,
        flags: CGEventFlags,
        source: CGEventSource?
    ) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    private func keyCode(for flags: CGEventFlags) -> CGKeyCode {
        if flags.contains(.maskCommand) { return CGKeyCode(kVK_Command) }
        if flags.contains(.maskShift) { return CGKeyCode(kVK_Shift) }
        if flags.contains(.maskControl) { return CGKeyCode(kVK_Control) }
        return CGKeyCode(kVK_Option)
    }
}
