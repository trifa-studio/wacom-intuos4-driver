import Foundation
import CoreGraphics
import AppKit

public final class TabletEventSynthesizer: @unchecked Sendable {
    private var isProximityIn: Bool = false
    private var wasTipDown: Bool = false
    private var wasBarrel1Down: Bool = false
    private var wasBarrel2Down: Bool = false
    private var lastIsEraser: Bool = false

    /// Exponential smoother state (raw normalized coords jitter a few units
    /// at 5080 LPI; real drivers filter this before injection).
    private var smoothedX: Double?
    private var smoothedY: Double?
    private var smoothedPressure: Double?
    /// Higher = more responsive, less smoothing.
    public var smoothingAlpha: Double = 0.45

    public var coordinateTransformer = CoordinateTransformer()
    public var pressureCurve = PressureCurve()

    /// Stable device id for proximity/point pairing (must match across events).
    public var systemTabletID: Int64 = 1
    public var pointingDeviceID: Int64 = 1

    /// Wacom capability mask (Wacom macOS dev kit / OpenTabletDriver):
    /// deviceId | absX | absY | buttons | tiltX | tiltY | pressure.
    /// Adobe apps refuse pen pressure unless the pressure bit (0x400) is present.
    public var capabilityMask: Int64 = 0x001 | 0x002 | 0x004 | 0x040 | 0x080 | 0x100 | 0x400

    /// Combined session event source — allows global gestures (Dock edge triggers,
    /// hot corners) and active keyboard modifier flags to pass through seamlessly.
    private let eventSource = CGEventSource(stateID: CGEventSourceStateID.combinedSessionState)
    /// Re-post proximity if this much time passed since the previous event
    /// (apps expire tablet state when no traffic arrives).
    public var proximityRefreshInterval: TimeInterval = 0.2
    private var lastEventTime = Date.distantPast

    public init() {}

    public static func isAccessibilityTrusted(promptIfNeeded: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: promptIfNeeded] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public func handleToolProximity(toolID: UInt32, isEraser: Bool) {
        lastIsEraser = isEraser
        if !isProximityIn {
            postProximityEvent(enter: true, isEraser: isEraser, toolID: toolID)
            isProximityIn = true
        } else if lastIsEraser != isEraser {
            // Tool flip tip ↔ eraser
            postProximityEvent(enter: false, isEraser: !isEraser, toolID: toolID)
            postProximityEvent(enter: true, isEraser: isEraser, toolID: toolID)
        }
    }

    public func handleToolOutOfProximity() {
        if isProximityIn {
            postProximityEvent(enter: false, isEraser: lastIsEraser, toolID: 0)
            isProximityIn = false
            wasTipDown = false
            wasBarrel1Down = false
            wasBarrel2Down = false
            smoothedX = nil
            smoothedY = nil
            smoothedPressure = nil
        }
    }

    /// Exponential moving average with snap-to-target on large jumps (re-entry,
    /// fast strokes) so smoothing never introduces visible lag.
    private func smooth(_ value: Double, _ state: inout Double?) -> Double {
        guard let s = state else {
            state = value
            return value
        }
        if abs(value - s) > 0.04 {
            state = value
            return value
        }
        let result = s + smoothingAlpha * (value - s)
        state = result
        return result
    }

    public func processPenEvent(_ event: PenEvent) {
        lastIsEraser = event.isEraser
        let sx = smooth(event.normalizedX, &smoothedX)
        let sy = smooth(event.normalizedY, &smoothedY)
        let sp = smooth(event.normalizedPressure, &smoothedPressure)
        let screenPoint = coordinateTransformer.transform(normalizedX: sx, normalizedY: sy)
        let evaluatedPressure = pressureCurve.evaluate(rawNormalized: sp)

        if event.isHovering && !isProximityIn {
            postProximityEvent(enter: true, isEraser: event.isEraser, toolID: event.toolID)
            isProximityIn = true
        } else if !event.isHovering && isProximityIn {
            // Release buttons then leave proximity
            if wasTipDown {
                postMouseTablet(type: .leftMouseUp, button: .left, point: screenPoint, event: event, pressure: 0)
                wasTipDown = false
            }
            postProximityEvent(enter: false, isEraser: event.isEraser, toolID: event.toolID)
            isProximityIn = false
            return
        }

        guard event.isHovering else { return }

        var mouseType: CGEventType = .mouseMoved
        var mouseButton: CGMouseButton = .left

        if event.isBarrel2 {
            mouseButton = .center
            mouseType = wasBarrel2Down ? .otherMouseDragged : .otherMouseDown
            wasBarrel2Down = true
        } else if wasBarrel2Down {
            mouseButton = .center
            mouseType = .otherMouseUp
            wasBarrel2Down = false
        } else if event.isBarrel1 {
            mouseButton = .right
            mouseType = wasBarrel1Down ? .rightMouseDragged : .rightMouseDown
            wasBarrel1Down = true
        } else if wasBarrel1Down {
            mouseButton = .right
            mouseType = .rightMouseUp
            wasBarrel1Down = false
        } else if event.isTipDown {
            mouseButton = .left
            mouseType = wasTipDown ? .leftMouseDragged : .leftMouseDown
            wasTipDown = true
        } else if wasTipDown {
            mouseButton = .left
            mouseType = .leftMouseUp
            wasTipDown = false
        }

        postMouseTablet(
            type: mouseType,
            button: mouseButton,
            point: screenPoint,
            event: event,
            pressure: evaluatedPressure
        )
    }

    private func postMouseTablet(
        type: CGEventType,
        button: CGMouseButton,
        point: CGPoint,
        event: PenEvent,
        pressure: Double
    ) {
        // OpenTabletDriver trick: after an idle gap, apps have expired the tablet
        // state — refresh proximity and mark this event as a proximity carrier.
        let now = Date()
        let idleGap = now.timeIntervalSince(lastEventTime)
        lastEventTime = now
        let needsProximityRefresh = isProximityIn && !wasTipDown && !wasBarrel1Down && !wasBarrel2Down
            && idleGap > proximityRefreshInterval
        if needsProximityRefresh {
            postProximityEvent(enter: true, isEraser: event.isEraser, toolID: event.toolID)
        }

        guard let cgEvent = CGEvent(
            mouseEventSource: eventSource,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button
        ) else {
            return
        }

        // Inherit live keyboard modifiers (Shift, Command, Option, Control)
        // so Shift+Click range select in Finder, Cmd+Click multi-select, and shortcuts work natively
        let currentModifiers = CGEventSource.flagsState(.combinedSessionState)
        cgEvent.flags = currentModifiers

        // Digitizer subtype so Cocoa delivers NSEvent.EventType.tabletPoint fields
        cgEvent.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))

        // Most apps (Cocoa/AppKit, Notes, browsers) read NSEvent.pressure from
        // this field; Adobe reads the tabletEvent fields below. Set both.
        cgEvent.setDoubleValueField(.mouseEventPressure, value: pressure)

        // Absolute tablet coordinates (device units) — what Adobe-scale apps expect
        cgEvent.setDoubleValueField(.tabletEventPointX, value: Double(event.rawX))
        cgEvent.setDoubleValueField(.tabletEventPointY, value: Double(event.rawY))
        cgEvent.setDoubleValueField(.tabletEventPointZ, value: 0)
        cgEvent.setDoubleValueField(.tabletEventPointPressure, value: pressure)
        // Tilt: CG expects scaled values; pass normalized −1…1 and also capability
        cgEvent.setDoubleValueField(.tabletEventTiltX, value: event.tiltX)
        cgEvent.setDoubleValueField(.tabletEventTiltY, value: -event.tiltY)
        cgEvent.setDoubleValueField(.tabletEventRotation, value: 0)
        cgEvent.setDoubleValueField(.tabletEventTangentialPressure, value: 0)

        cgEvent.setIntegerValueField(.tabletEventDeviceID, value: pointingDeviceID)
        cgEvent.setIntegerValueField(.mouseEventClickState, value: 1)

        var buttonMask: Int64 = 0
        if event.isTipDown { buttonMask |= 0x01 }
        if event.isBarrel1 { buttonMask |= 0x02 }
        if event.isBarrel2 { buttonMask |= 0x04 }
        cgEvent.setIntegerValueField(.tabletEventPointButtons, value: buttonMask)

        cgEvent.post(tap: .cghidEventTap)
    }

    private func postProximityEvent(enter: Bool, isEraser: Bool, toolID: UInt32) {
        guard let proxEvent = CGEvent(source: eventSource) else { return }
        proxEvent.type = .tabletProximity

        // NSPointingDeviceType: 1 tip/pen, 3 eraser (NSEraserPointingDevice)
        let pointerType: Int64 = isEraser ? 3 : 1
        proxEvent.setIntegerValueField(.tabletProximityEventEnterProximity, value: enter ? 1 : 0)
        proxEvent.setIntegerValueField(.tabletProximityEventPointerType, value: pointerType)
        proxEvent.setIntegerValueField(.tabletProximityEventPointerID, value: pointingDeviceID)
        proxEvent.setIntegerValueField(.tabletProximityEventDeviceID, value: pointingDeviceID)
        proxEvent.setIntegerValueField(.tabletProximityEventSystemTabletID, value: systemTabletID)
        // Wacom vendor pointer type: low 16 bits of the hardware tool ID
        // (e.g. 0x100802 → 0x802 "General Stylus" — what Adobe matches against).
        proxEvent.setIntegerValueField(.tabletProximityEventVendorPointerType, value: Int64(toolID & 0xFFFF))
        proxEvent.setIntegerValueField(.tabletProximityEventVendorID, value: Int64(WacomConstants.vendorID))
        proxEvent.setIntegerValueField(.tabletProximityEventTabletID, value: Int64(WacomConstants.usbProductID))

        // Capability mask: pressure | tilt | buttons | abs | deviceId (Wacom layout).
        proxEvent.setIntegerValueField(.tabletProximityEventCapabilityMask, value: capabilityMask)

        proxEvent.post(tap: .cghidEventTap)
    }
}
