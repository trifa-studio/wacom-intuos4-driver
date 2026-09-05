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

    /// Pen tip click / double-click detection state
    private var lastTipDownTime: Date = Date.distantPast
    private var lastTipDownPoint: CGPoint = .zero
    private var tipClickCount: Int64 = 1
    public var doubleClickInterval: TimeInterval = NSEvent.doubleClickInterval
    public var doubleClickTolerance: Double = 4.0
    /// Screen points of pen jitter tolerated before a tap becomes a drag.
    public var dragThreshold: Double = 3.0
    private var tipAnchor = CGPoint.zero
    private var rightAnchor = CGPoint.zero
    private var tipDragging = false
    private var rightDragging = false
    private var lastPen: PenEvent?
    private var lastPoint = CGPoint.zero
    private var lastClickModifiers: CGEventFlags = []
    private let emit: (CGEvent) -> Void
    private let keyboardFlags: () -> CGEventFlags

    /// Proximity exit debounce — prevents rapid double-taps from generating
    /// spurious tabletProximity leave/enter cycles that reset Cocoa's double-click tracking.
    private var lastHoverTime: Date = Date.distantPast
    public var proximityExitDelay: TimeInterval = 0.40

    /// Stable device id for proximity/point pairing (must match across events).
    public var systemTabletID: Int64 = 1
    public var pointingDeviceID: Int64 = 1

    /// Wacom capability mask (Wacom macOS dev kit / OpenTabletDriver):
    /// deviceId | absX | absY | buttons | tiltX | tiltY | pressure.
    /// Adobe apps refuse pen pressure unless the pressure bit (0x400) is present.
    public var capabilityMask: Int64 = 0x001 | 0x002 | 0x004 | 0x040 | 0x080 | 0x100 | 0x400

    /// Keep injected pointer state isolated from the shared session state. Using
    /// combinedSessionState here can feed a modifier copied onto one synthetic
    /// event back into later events, leaving Command/Option apparently stuck.
    private let eventSource = CGEventSource(stateID: .privateState)
    /// Re-post proximity if this much time passed since the previous event
    /// (apps expire tablet state when no traffic arrives).
    public var proximityRefreshInterval: TimeInterval = 0.2
    private var lastEventTime = Date.distantPast

    /// Live modifier flags held by ExpressKeys (e.g. holding Alt/Option or Shift on the tablet)
    public var activeExpressKeyModifiers: CGEventFlags = []

    public init(
        eventSink: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) },
        keyboardFlags: @escaping () -> CGEventFlags = { CGEventSource.flagsState(.hidSystemState) }
    ) {
        self.emit = eventSink
        self.keyboardFlags = keyboardFlags
    }

    private var modifiers: CGEventFlags { keyboardFlags().union(activeExpressKeyModifiers) }

    public static func isAccessibilityTrusted(promptIfNeeded: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: promptIfNeeded] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public func handleToolProximity(toolID: UInt32, isEraser: Bool) {
        if !isProximityIn {
            postProximityEvent(enter: true, isEraser: isEraser, toolID: toolID)
            isProximityIn = true
        } else if lastIsEraser != isEraser {
            // Tool flip tip ↔ eraser
            postProximityEvent(enter: false, isEraser: !isEraser, toolID: toolID)
            postProximityEvent(enter: true, isEraser: isEraser, toolID: toolID)
        }
        lastIsEraser = isEraser
    }

    public func handleToolOutOfProximity() {
        if let pen = lastPen { releaseButtons(point: lastPoint, event: pen) }
        if isProximityIn {
            postProximityEvent(enter: false, isEraser: lastIsEraser, toolID: 0)
            isProximityIn = false
            wasTipDown = false
            wasBarrel1Down = false
            wasBarrel2Down = false
            smoothedX = nil
            smoothedY = nil
            smoothedPressure = nil
            tipClickCount = 1
        }
        lastPen = nil
        lastTipDownTime = .distantPast
    }

    private func releaseButtons(point: CGPoint, event: PenEvent) {
        if wasTipDown {
            wasTipDown = false
            postMouseTablet(type: .leftMouseUp, button: .left, point: tipDragging ? point : tipAnchor,
                            event: event, pressure: 0, clickCount: tipClickCount)
        }
        if wasBarrel1Down {
            wasBarrel1Down = false
            postMouseTablet(type: .rightMouseUp, button: .right, point: rightDragging ? point : rightAnchor,
                            event: event, pressure: 0, clickCount: 1)
        }
        tipDragging = false
        rightDragging = false
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
        lastPen = event
        lastPoint = screenPoint

        if event.isHovering {
            lastHoverTime = Date()
            if !isProximityIn {
                postProximityEvent(enter: true, isEraser: event.isEraser, toolID: event.toolID)
                isProximityIn = true
            }
        } else if isProximityIn {
            // Pen lifted: immediately release any held buttons so clicks do not stick
            releaseButtons(point: screenPoint, event: event)
            wasBarrel2Down = false

            // Debounce proximity exit: only post proximity leave after sustained absence (> 0.4s).
            // Quick double-taps (which momentarily bounce out of the 10mm hover range) keep proximity
            // alive, allowing Cocoa / Finder to receive unbroken clickState = 1 -> 2 double-click sequences.
            if Date().timeIntervalSince(lastHoverTime) > proximityExitDelay {
                postProximityEvent(enter: false, isEraser: event.isEraser, toolID: event.toolID)
                isProximityIn = false
                smoothedX = nil
                smoothedY = nil
                smoothedPressure = nil
            }
            return
        }

        guard event.isHovering else { return }

        // 1. Upper barrel button (Barrel 2) -> Instant Double Click at current pen location
        if event.isBarrel2 {
            if !wasBarrel2Down {
                releaseButtons(point: screenPoint, event: event)
                wasBarrel2Down = true
                postDoubleClick(point: screenPoint, event: event)
            }
            return
        } else if wasBarrel2Down {
            wasBarrel2Down = false
        }

        // 2. Lower barrel button (Barrel 1) -> Right Click
        if event.isBarrel1 {
            if wasTipDown { releaseButtons(point: screenPoint, event: event) }
            if !wasBarrel1Down {
                rightAnchor = screenPoint
                rightDragging = false
            } else if hypot(screenPoint.x - rightAnchor.x, screenPoint.y - rightAnchor.y) >= dragThreshold {
                rightDragging = true
            }
            let mouseType: CGEventType = !wasBarrel1Down ? .rightMouseDown :
                (rightDragging ? .rightMouseDragged : .tabletPointer)
            wasBarrel1Down = true
            postMouseTablet(
                type: mouseType,
                button: .right,
                point: rightDragging ? screenPoint : rightAnchor,
                event: event,
                pressure: evaluatedPressure,
                clickCount: 1
            )
            return
        } else if wasBarrel1Down {
            wasBarrel1Down = false
            postMouseTablet(
                type: .rightMouseUp,
                button: .right,
                point: rightDragging ? screenPoint : rightAnchor,
                event: event,
                pressure: 0,
                clickCount: 1
            )
            return
        }

        // 3. Pen Tip -> Left Click / Double Click / Drag
        var mouseType: CGEventType = .mouseMoved
        var mouseButton: CGMouseButton = .left
        var clickCount: Int64 = 0

        if event.isTipDown {
            if !wasTipDown {
                // Check if Alt/Option is held (ExpressKey or physical keyboard) specifically for sampling
                let clickModifiers = modifiers.intersection([.maskAlternate, .maskCommand, .maskShift, .maskControl])
                let isAltSampling = clickModifiers.contains(.maskAlternate)

                if isAltSampling {
                    // Clicks carrying Alt (Photoshop sampling / eyedropper / clone stamp)
                    // MUST ALWAYS be single-clicks (clickCount = 1). Multi-clicks (2 or 3)
                    // are rejected by Photoshop's tool sampling engine!
                    tipClickCount = 1
                    lastTipDownTime = .distantPast
                } else {
                    // Normal pen taps: evaluate double click interval & distance
                    let now = Date()
                    let elapsed = now.timeIntervalSince(lastTipDownTime)
                    let dist = hypot(screenPoint.x - lastTipDownPoint.x, screenPoint.y - lastTipDownPoint.y)
                    if elapsed <= doubleClickInterval && dist <= doubleClickTolerance && clickModifiers == lastClickModifiers {
                        tipClickCount += 1
                    } else {
                        tipClickCount = 1
                    }
                    lastTipDownTime = now
                    lastTipDownPoint = screenPoint
                }

                lastClickModifiers = clickModifiers
                tipAnchor = screenPoint
                tipDragging = false
                wasTipDown = true
                mouseType = .leftMouseDown
            } else {
                if hypot(screenPoint.x - tipAnchor.x, screenPoint.y - tipAnchor.y) >= dragThreshold {
                    tipDragging = true
                    lastTipDownTime = .distantPast
                }
                // A stationary pressure update is a tablet event, not a mouse
                // drag. Java cancels mouseClicked after even a zero-length drag.
                mouseType = tipDragging ? .leftMouseDragged : .tabletPointer
            }
            mouseButton = .left
            clickCount = tipClickCount
        } else if wasTipDown {
            mouseType = .leftMouseUp
            mouseButton = .left
            clickCount = tipClickCount
            wasTipDown = false
        }

        postMouseTablet(
            type: mouseType,
            button: mouseButton,
            point: (mouseType == .leftMouseUp || wasTipDown) && !tipDragging ? tipAnchor : screenPoint,
            event: event,
            pressure: mouseType == .leftMouseUp ? 0 : evaluatedPressure,
            clickCount: clickCount
        )
    }

    private func postDoubleClick(point: CGPoint, event: PenEvent) {
        // First click
        postMouseTablet(type: .leftMouseDown, button: .left, point: point, event: event, pressure: 0.9, clickCount: 1)
        postMouseTablet(type: .leftMouseUp, button: .left, point: point, event: event, pressure: 0.0, clickCount: 1)
        // Second click
        postMouseTablet(type: .leftMouseDown, button: .left, point: point, event: event, pressure: 0.9, clickCount: 2)
        postMouseTablet(type: .leftMouseUp, button: .left, point: point, event: event, pressure: 0.0, clickCount: 2)
    }

    private func postMouseTablet(
        type: CGEventType,
        button: CGMouseButton,
        point: CGPoint,
        event: PenEvent,
        pressure: Double,
        clickCount: Int64 = 1
    ) {
        // OpenTabletDriver trick: after an idle gap, apps have expired the tablet
        // state — refresh proximity and mark this event as a proximity carrier.
        // Proximity refresh must ONLY happen during pure hover movement (mouseMoved).
        // Never trigger on mouseDown, mouseDragged, or mouseUp, and NEVER while modifiers are held,
        // as Adobe Photoshop resets tool sampling state upon receiving a proximity event!
        let now = Date()
        let idleGap = now.timeIntervalSince(lastEventTime)
        lastEventTime = now

        let hasModifiers = !modifiers.intersection([.maskAlternate, .maskShift, .maskCommand, .maskControl]).isEmpty

        let needsProximityRefresh = type == .mouseMoved
            && isProximityIn
            && !event.isTipDown
            && !event.isBarrel1
            && !event.isBarrel2
            && !hasModifiers
            && idleGap > proximityRefreshInterval

        if needsProximityRefresh {
            postProximityEvent(enter: true, isEraser: event.isEraser, toolID: event.toolID)
        }

        let created = type == .tabletPointer ? CGEvent(source: eventSource) : CGEvent(
            mouseEventSource: eventSource,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button
        )
        guard let cgEvent = created else {
            return
        }
        cgEvent.type = type
        cgEvent.location = point

        // Inherit live keyboard modifiers (Shift, Command, Option, Control)
        // so Shift+Click range select in Finder, Cmd+Click multi-select, and shortcuts work natively.
        // Also include active ExpressKey modifiers (e.g. holding Alt/Option or Shift on the tablet).
        cgEvent.flags = modifiers

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
        cgEvent.setIntegerValueField(.mouseEventClickState, value: clickCount)

        var buttonMask: Int64 = 0
        if wasTipDown { buttonMask |= 0x01 }
        if wasBarrel1Down { buttonMask |= 0x02 }
        // The tablet fields must describe the synthesized mouse state, including
        // the side-button double-click's explicit down/up pairs.
        if type == .leftMouseDown { buttonMask |= 0x01 }
        if type == .leftMouseUp { buttonMask &= ~0x01 }
        if type == .rightMouseDown { buttonMask |= 0x02 }
        if type == .rightMouseUp { buttonMask &= ~0x02 }
        cgEvent.setIntegerValueField(.tabletEventPointButtons, value: buttonMask)

        emit(cgEvent)
    }

    private func postProximityEvent(enter: Bool, isEraser: Bool, toolID: UInt32) {
        guard let proxEvent = CGEvent(source: eventSource) else { return }
        proxEvent.type = .tabletProximity
        proxEvent.flags = modifiers

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

        emit(proxEvent)
    }
}
