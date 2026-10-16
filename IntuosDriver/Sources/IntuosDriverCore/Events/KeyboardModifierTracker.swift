import Foundation
import CoreGraphics
import AppKit

/// Tracks physical keyboard modifiers independently of flags on posted pen events.
/// Start/stop run on the main run loop; flags can be read from any thread.
public final class KeyboardModifierTracker: @unchecked Sendable {
    public static let shared = KeyboardModifierTracker()
    public static let modifierMask: CGEventFlags = [
        .maskCommand, .maskAlternate, .maskShift, .maskControl, .maskAlphaShift, .maskSecondaryFn
    ]
    private static let modifierKeys: Set<Int64> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
    private let lock = NSLock()
    private var observedFlags: CGEventFlags?
    private let keyStateFlags: () -> CGEventFlags
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var wakeObserver: NSObjectProtocol?

    /// The injected state reader lets regression tests model stale system state
    /// without posting input or creating an event tap.
    public init(keyStateFlags: (() -> CGEventFlags)? = nil) {
        self.keyStateFlags = keyStateFlags ?? Self.pollKeyStates
    }

    public var flags: CGEventFlags {
        lock.lock()
        let observed = observedFlags
        lock.unlock()
        // Before the first event, or if monitoring is unavailable, query individual
        // keys. Never fall back to the accumulated Command/Option/Shift/Control flags.
        return (observed ?? keyStateFlags()).intersection(Self.modifierMask)
    }

    public var diagnosticState: [String: String] {
        lock.lock()
        let hasObservation = observedFlags != nil
        lock.unlock()
        return ["trackedKeyboardFlags": String(flags.rawValue),
                "modifierTrackingMode": hasObservation ? "keyboardEvents" : "keyStates"]
    }

    /// Only flagsChanged from the hardware stream (PID 0) is authoritative.
    /// Aggregate modifier bits in that event already account for both left/right
    /// keys: releasing one Option key must preserve Option if the other is held.
    @discardableResult
    public func observe(_ event: CGEvent) -> Bool {
        guard event.type == .flagsChanged,
              event.getIntegerValueField(.eventSourceUnixProcessID) == 0,
              Self.modifierKeys.contains(event.getIntegerValueField(.keyboardEventKeycode)) else { return false }
        lock.lock()
        observedFlags = event.flags.intersection(Self.modifierMask)
        lock.unlock()
        return true
    }

    @discardableResult
    public func start() -> Bool {
        precondition(Thread.isMainThread)
        if let tap, CGEvent.tapIsEnabled(tap: tap) { return true }
        stop()
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let tracker = Unmanaged<KeyboardModifierTracker>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                tracker.invalidateObservation()
                if let tap = tracker.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            } else {
                tracker.observe(event)
            }
            return Unmanaged.passUnretained(event)
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .listenOnly, eventsOfInterest: CGEventMask(1) << CGEventType.flagsChanged.rawValue,
            callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return false }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        guard let runLoopSource else {
            CFMachPortInvalidate(tap)
            self.tap = nil
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.invalidateObservation()
            if let tap = self?.tap { CGEvent.tapEnable(tap: tap, enable: true) }
        }
        return true
    }

    public func stop() {
        precondition(Thread.isMainThread)
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        if let tap { CFMachPortInvalidate(tap) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        invalidateObservation()
    }

    private func invalidateObservation() {
        lock.lock()
        observedFlags = nil
        lock.unlock()
    }

    private static func pollKeyStates() -> CGEventFlags {
        let pairs: [(CGEventFlags, [CGKeyCode])] = [
            (.maskCommand, [54, 55]), (.maskAlternate, [58, 61]),
            (.maskShift, [56, 60]), (.maskControl, [59, 62]), (.maskSecondaryFn, [63])
        ]
        var result: CGEventFlags = []
        for (flag, keys) in pairs where keys.contains(where: { CGEventSource.keyState(.hidSystemState, key: $0) }) {
            result.insert(flag)
        }
        // Caps Lock is a toggle, so key-down state does not describe its mode.
        result.formUnion(CGEventSource.flagsState(.hidSystemState).intersection(.maskAlphaShift))
        return result
    }
}
