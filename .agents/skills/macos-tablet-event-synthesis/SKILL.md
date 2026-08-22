---
name: macos-tablet-event-synthesis
description: >-
  Guidelines and implementation patterns for generating native macOS CoreGraphics tablet events.
  Use when synthesizing kCGEventTabletPointer, kCGEventTabletProximity, and mouse/keyboard events,
  handling coordinate mapping across multi-display setups, setting pressure/tilt fields for Adobe apps,
  or configuring TCC Accessibility and Input Monitoring permissions.
---

# macOS Tablet Event Synthesis

This skill covers the synthesis of professional-grade digitizer and stylus events on macOS for compatibility with Adobe Photoshop, Illustrator, Clip Studio, Krita, and Affinity.

## 1. The macOS Digitizer Event Pipeline

macOS requires a two-part event stream for digitizers:
1. **Proximity Events (`kCGEventTabletProximity`):** Sent when the pen enters or exits hover range. Establishes pointer identity (Stylus Tip vs. Eraser), Tool ID, serial number, and capabilities.
2. **Pointer & Mouse Events (`kCGEventTabletPointer` + `kCGEventLeftMouseDown` / `Dragged` / `Up` / `MouseMoved`):** Carries sub-pixel coordinates, normalized pressure (0.0…1.0), tilt angles (X/Y), and button state.

## 2. Event Creation & Required Fields for Adobe Apps

Adobe apps query low-level tablet fields on the `CGEvent`. Omitting these fields causes Photoshop to treat the pen as a standard mouse (loss of pressure/tilt dynamics).

```swift
import CoreGraphics
import AppKit

public struct TabletState {
    public var x: Double          // Scaled screen coordinate X
    public var y: Double          // Scaled screen coordinate Y
    public var pressure: Double   // 0.0 to 1.0
    public var tiltX: Double      // -1.0 to 1.0 (-60 to +60 degrees)
    public var tiltY: Double      // -1.0 to 1.0 (-60 to +60 degrees)
    public var isTipDown: Bool
    public var isEraser: Bool
    public var isHovering: Bool
    public var deviceID: UInt32
}

public final class TabletEventSynthesizer {
    private var isProximityIn = false
    
    public func postProximityEvent(state: TabletState) {
        guard let proxEvent = CGEvent(source: nil) else { return }
        proxEvent.type = .tabletProximity
        
        // Enter proximity
        proxEvent.setIntegerValueField(.tabletProximityEventEnterProximity, value: state.isHovering ? 1 : 0)
        // Pointer type: 1 = Pen / Tip, 2 = Eraser, 3 = Puck / Mouse
        proxEvent.setIntegerValueField(.tabletProximityEventPointerType, value: state.isEraser ? 2 : 1)
        proxEvent.setIntegerValueField(.tabletProximityEventDeviceID, value: Int64(state.deviceID))
        proxEvent.setIntegerValueField(.tabletProximityEventSystemTabletID, value: 0)
        proxEvent.setIntegerValueField(.tabletProximityEventCapabilityMask, value: 0x000F) // Pressure + Tilt X/Y
        
        proxEvent.post(tap: .cghidEventTap)
        isProximityIn = state.isHovering
    }
    
    public func postPointerEvent(state: TabletState) {
        if !isProximityIn && state.isHovering {
            postProximityEvent(state: state)
        }
        
        let point = CGPoint(x: state.x, y: state.y)
        let eventType: CGEventType
        if state.isTipDown {
            eventType = .leftMouseDragged
        } else {
            eventType = .mouseMoved
        }
        
        guard let event = CGEvent(mouseEventSource: nil, mouseType: eventType, mouseCursorPosition: point, mouseButton: .left) else {
            return
        }
        
        // Tablet sub-type (must be 1 for tablet pointer)
        event.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
        
        // Pressure: 0.0 to 1.0 (Adobe scales this directly to brush size/opacity)
        event.setDoubleValueField(.tabletEventPressure, value: state.pressure)
        
        // Tilt: scaled to integer/float ranges expected by CoreGraphics
        event.setDoubleValueField(.tabletEventTiltX, value: state.tiltX)
        event.setDoubleValueField(.tabletEventTiltY, value: state.tiltY)
        
        // Coordinate fields
        event.setDoubleValueField(.tabletEventPointX, value: state.x)
        event.setDoubleValueField(.tabletEventPointY, value: state.y)
        
        // Device identity
        event.setIntegerValueField(.tabletEventDeviceID, value: Int64(state.deviceID))
        
        event.post(tap: .cghidEventTap)
    }
}
```

## 3. Coordinate Space Transformation

To map raw tablet points ($0 \dots 40640$, $0 \dots 25400$) to screen points:

```swift
public func transformCoordinates(rawX: Double, rawY: Double, maxX: Double = 40640.0, maxY: Double = 25400.0, targetScreen: NSScreen) -> CGPoint {
    let screenFrame = targetScreen.frame
    
    // Normalize to 0.0 ... 1.0
    let normX = rawX / maxX
    let normY = rawY / maxY
    
    // Invert Y for macOS AppKit top-left coordinate origin
    let screenX = screenFrame.origin.x + (normX * screenFrame.width)
    let screenY = screenFrame.origin.y + (normY * screenFrame.height)
    
    return CGPoint(x: screenX, y: screenY)
}
```

## 4. TCC Permissions Handling

Synthetic event injection requires `Accessibility` privileges:

```swift
public func checkAccessibilityPermissions(promptIfNeeded: Bool = true) -> Bool {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: promptIfNeeded] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
}
```
