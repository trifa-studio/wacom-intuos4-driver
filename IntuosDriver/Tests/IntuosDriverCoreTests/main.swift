import Foundation
import CoreGraphics
import AppKit
import IntuosDriverCore

private var failures = 0
private func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, line: Int = #line) {
    if a != b { failures += 1; print("FAIL line \(line): \(a) != \(b)") }
}
private func XCTAssertTrue(_ value: Bool, line: Int = #line) { XCTAssertEqual(value, true, line: line) }
private func XCTAssertFalse(_ value: Bool, line: Int = #line) { XCTAssertEqual(value, false, line: line) }

final class PointerTests {
    private var events: [CGEvent] = []
    private var flags: CGEventFlags = []
    private lazy var driver = TabletEventSynthesizer(
        eventSink: { [unowned self] in self.events.append($0) },
        keyboardFlags: { [unowned self] in self.flags }
    )

    private func sample(x: UInt32 = 20000, y: UInt32 = 10000, down: Bool = true, right: Bool = false,
                        double: Bool = false, pressure: UInt16 = 1000, hovering: Bool = true) -> PenEvent {
        PenEvent(rawX: x, rawY: y, rawPressure: down ? pressure : 0,
                 tiltX: 0, tiltY: 0, isTipDown: down, isBarrel1: right,
                 isBarrel2: double, isEraser: false, isHovering: hovering)
    }

    private var mouseEvents: [CGEvent] {
        events.filter { [.leftMouseDown, .leftMouseUp, .leftMouseDragged,
                         .rightMouseDown, .rightMouseUp, .rightMouseDragged].contains($0.type) }
    }

    func testStationaryTapHasNoDragButPreservesPressureUpdates() {
        driver.processPenEvent(sample())
        driver.processPenEvent(sample(pressure: 1500))
        driver.processPenEvent(sample(down: false))
        XCTAssertEqual(mouseEvents.map(\.type), [.leftMouseDown, .leftMouseUp])
        XCTAssertTrue(events.contains { $0.type == .tabletPointer && $0.getDoubleValueField(.tabletEventPointPressure) > 0 })
        XCTAssertEqual(mouseEvents.last?.getDoubleValueField(.mouseEventPressure), 0)
    }

    func testJitterIsATapAndReleaseStaysAtPressLocation() {
        driver.processPenEvent(sample())
        driver.processPenEvent(sample(x: 20001))
        driver.processPenEvent(sample(x: 20002, down: false))
        XCTAssertEqual(mouseEvents.map(\.type), [.leftMouseDown, .leftMouseUp])
        XCTAssertEqual(mouseEvents.first?.location, mouseEvents.last?.location)
    }

    func testIntentionalMovementStartsAndContinuesDrag() {
        driver.processPenEvent(sample())
        driver.processPenEvent(sample(x: 24000))
        driver.processPenEvent(sample(x: 20000))
        driver.processPenEvent(sample(down: false))
        XCTAssertEqual(mouseEvents.map(\.type), [.leftMouseDown, .leftMouseDragged, .leftMouseDragged, .leftMouseUp])
    }

    func testLeavingRangeReleasesBeforeProximityExitAndOnlyOnce() {
        driver.processPenEvent(sample())
        driver.handleToolOutOfProximity()
        driver.handleToolOutOfProximity()
        XCTAssertEqual(mouseEvents.map(\.type), [.leftMouseDown, .leftMouseUp])
        XCTAssertEqual(mouseEvents.last?.getIntegerValueField(.tabletEventPointButtons), 0)
        XCTAssertEqual(events.last?.type, .tabletProximity)
    }

    func testSideButtonReleasesTipBeforeRightClick() {
        driver.processPenEvent(sample())
        driver.processPenEvent(sample(right: true))
        driver.processPenEvent(sample(down: false, right: true))
        driver.processPenEvent(sample(down: false))
        XCTAssertEqual(mouseEvents.map(\.type), [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp])
    }

    func testDoubleClickButtonHasConsistentButtonFields() {
        driver.processPenEvent(sample(down: false, double: true))
        XCTAssertEqual(mouseEvents.map(\.type), [.leftMouseDown, .leftMouseUp, .leftMouseDown, .leftMouseUp])
        XCTAssertEqual(mouseEvents.map { $0.getIntegerValueField(.tabletEventPointButtons) }, [1, 0, 1, 0])
    }

    func testCommandReleaseIsReflectedInNextClick() {
        flags = .maskCommand
        driver.processPenEvent(sample())
        driver.processPenEvent(sample(down: false))
        flags = []
        driver.processPenEvent(sample())
        XCTAssertTrue(mouseEvents[0].flags.contains(.maskCommand))
        XCTAssertFalse(mouseEvents[2].flags.contains(.maskCommand))
        XCTAssertEqual(mouseEvents[2].getIntegerValueField(.mouseEventClickState), 1)
    }

    func testDoubleClickAndSeparateControlClicks() {
        driver.smoothingAlpha = 1
        driver.processPenEvent(sample())
        driver.processPenEvent(sample(down: false))
        driver.processPenEvent(sample())
        driver.processPenEvent(sample(down: false))
        driver.processPenEvent(sample(x: 21000))
        XCTAssertEqual(mouseEvents.filter { $0.type == .leftMouseDown }.map {
            $0.getIntegerValueField(.mouseEventClickState)
        }, [1, 2, 1])
    }

    func testDragDeltasReachAppKitAndReverseWithThePen(right: Bool = false) {
        driver.smoothingAlpha = 1
        driver.processPenEvent(sample(right: right))
        let anchor = mouseEvents.last!.location
        // Pressure and sub-threshold jitter must not consume the first drag's displacement.
        driver.processPenEvent(sample(x: 20001, right: right, pressure: 1500))
        XCTAssertEqual(events.last!.type, .tabletPointer)
        XCTAssertEqual(events.last!.getIntegerValueField(.mouseEventDeltaX), 0)
        driver.processPenEvent(sample(x: 24000, y: 12000, right: right))
        let drag = mouseEvents.last!
        XCTAssertEqual(drag.type, right ? .rightMouseDragged : .leftMouseDragged)
        XCTAssertEqual(drag.getIntegerValueField(.mouseEventDeltaX), Int64((drag.location.x - anchor.x).rounded()))
        XCTAssertEqual(drag.getIntegerValueField(.mouseEventDeltaY), Int64((drag.location.y - anchor.y).rounded()))
        let cocoa = NSEvent(cgEvent: drag)!
        XCTAssertTrue(cocoa.deltaX > 0 && cocoa.deltaY > 0)
        XCTAssertTrue(drag.getDoubleValueField(.tabletEventPointPressure) > 0)
        XCTAssertEqual(drag.getIntegerValueField(.tabletEventPointButtons), right ? 2 : 1)
        driver.processPenEvent(sample(x: 22000, y: 11000, right: right))
        XCTAssertTrue(events.last!.getIntegerValueField(.mouseEventDeltaX) < 0)
        XCTAssertTrue(events.last!.getIntegerValueField(.mouseEventDeltaY) < 0)
        driver.processPenEvent(sample(x: 22000, y: 11000, right: right, pressure: 1400))
        XCTAssertEqual(events.last!.getIntegerValueField(.mouseEventDeltaX), 0)
        XCTAssertEqual(events.last!.getIntegerValueField(.mouseEventDeltaY), 0)
        driver.processPenEvent(sample(x: 22000, y: 11000, down: false))
        XCTAssertEqual(events.last!.getIntegerValueField(.mouseEventDeltaX), 0)
        XCTAssertEqual(events.last!.getIntegerValueField(.tabletEventPointButtons), 0)
    }

    func testSmallMovementsAccumulateWithoutDrift(down: Bool) {
        driver.smoothingAlpha = 1
        driver.dragThreshold = 0
        // Hover proximity refreshes must not discard relative movement.
        driver.proximityRefreshInterval = -1
        driver.processPenEvent(sample(down: down))
        let anchor = events.last!.location
        var totalX: Int64 = 0
        var totalY: Int64 = 0
        for offset in Array(1...200) + Array((0..<200).reversed()) {
            driver.processPenEvent(sample(x: UInt32(20000 + offset), y: UInt32(10000 + offset), down: down))
            let event = events.last!
            totalX += event.getIntegerValueField(.mouseEventDeltaX)
            totalY += event.getIntegerValueField(.mouseEventDeltaY)
            XCTAssertTrue(abs(Double(totalX) - (event.location.x - anchor.x)) <= 0.501)
            XCTAssertTrue(abs(Double(totalY) - (event.location.y - anchor.y)) <= 0.501)
        }
        XCTAssertEqual(totalX, 0)
        XCTAssertEqual(totalY, 0)
    }

    func testHalfPointRemainderDoesNotMoveAStationaryDrag() {
        driver.smoothingAlpha = 1
        let left = driver.coordinateTransformer.transform(normalizedX: 0.25, normalizedY: 0.5)
        let right = driver.coordinateTransformer.transform(normalizedX: 0.75, normalizedY: 0.5)
        let displayWidth = 2 * (right.x - left.x)
        driver.coordinateTransformer.isPrecisionMode = true
        driver.coordinateTransformer.precisionCenter = .zero
        driver.coordinateTransformer.precisionScale = Double(WacomConstants.maxX) / (2 * displayWidth)
        driver.processPenEvent(sample(x: 0))
        let start = events.last!.location
        driver.processPenEvent(sample(x: 8))
        XCTAssertEqual(events.last!.location.x - start.x, 4)
        driver.processPenEvent(sample(x: 9))
        XCTAssertEqual(events.last!.location.x - start.x, 4.5)
        for pressure: UInt16 in [1100, 1200, 1300, 1400] {
            driver.processPenEvent(sample(x: 9, pressure: pressure))
            XCTAssertEqual(events.last!.getIntegerValueField(.mouseEventDeltaX), 0)
        }
    }

    func testReentryDoesNotCreateMovementJump(explicitExit: Bool) {
        driver.smoothingAlpha = 1
        driver.processPenEvent(sample(down: false))
        XCTAssertEqual(events.last!.getIntegerValueField(.mouseEventDeltaX), 0)
        driver.processPenEvent(sample(x: 24000, down: false))
        XCTAssertTrue(events.last!.getIntegerValueField(.mouseEventDeltaX) > 0)
        if explicitExit { driver.handleToolOutOfProximity() }
        else { driver.processPenEvent(sample(x: 24000, down: false, hovering: false)) }
        driver.processPenEvent(sample(x: 30000, down: false))
        XCTAssertEqual(events.last!.getIntegerValueField(.mouseEventDeltaX), 0)
        driver.processPenEvent(sample(x: 32000, down: false))
        XCTAssertTrue(events.last!.getIntegerValueField(.mouseEventDeltaX) > 0)
    }
}

PointerTests().testStationaryTapHasNoDragButPreservesPressureUpdates()
PointerTests().testJitterIsATapAndReleaseStaysAtPressLocation()
PointerTests().testIntentionalMovementStartsAndContinuesDrag()
PointerTests().testLeavingRangeReleasesBeforeProximityExitAndOnlyOnce()
PointerTests().testSideButtonReleasesTipBeforeRightClick()
PointerTests().testDoubleClickButtonHasConsistentButtonFields()
PointerTests().testCommandReleaseIsReflectedInNextClick()
PointerTests().testDoubleClickAndSeparateControlClicks()
PointerTests().testDragDeltasReachAppKitAndReverseWithThePen()
PointerTests().testDragDeltasReachAppKitAndReverseWithThePen(right: true)
PointerTests().testSmallMovementsAccumulateWithoutDrift(down: false)
PointerTests().testSmallMovementsAccumulateWithoutDrift(down: true)
PointerTests().testHalfPointRemainderDoesNotMoveAStationaryDrag()
PointerTests().testReentryDoesNotCreateMovementJump(explicitExit: true)
PointerTests().testReentryDoesNotCreateMovementJump(explicitExit: false)
// Exercise the incident gesture without posting keyboard or desktop input.
var gesture = ControlIncidentGesture()
for tap in 0..<4 {
    let time = Double(tap) * 0.6
    XCTAssertFalse(gesture.transition(isDown: true, at: time))
    XCTAssertFalse(gesture.transition(isDown: true, at: time + 0.05)) // duplicate down is not another tap
    XCTAssertEqual(gesture.transition(isDown: false, at: time + 0.1), tap == 3)
}
XCTAssertFalse(gesture.transition(isDown: false, at: 2.2)) // duplicate up cannot save twice
var slowGesture = ControlIncidentGesture()
for tap in 0..<4 {
    let time = Double(tap) * 2
    XCTAssertFalse(slowGesture.transition(isDown: true, at: time))
    XCTAssertFalse(slowGesture.transition(isDown: false, at: time + 0.1))
}
var heldGesture = ControlIncidentGesture()
XCTAssertFalse(heldGesture.transition(isDown: true, at: 0))
XCTAssertFalse(heldGesture.transition(isDown: false, at: 8))
for tap in 0..<4 {
    let time = 10 + Double(tap) * 0.5
    XCTAssertFalse(heldGesture.transition(isDown: true, at: time))
    XCTAssertEqual(heldGesture.transition(isDown: false, at: time + 0.1), tap == 3)
}

// Model stale system state and physical events without installing a tap or posting input.
private func modifierEvent(code: Int64, flags: CGEventFlags, pid: Int64 = 0,
                           type: CGEventType = .flagsChanged) -> CGEvent {
    let event = CGEvent(source: nil)!
    event.type = type
    event.flags = flags
    event.setIntegerValueField(.keyboardEventKeycode, value: code)
    event.setIntegerValueField(.eventSourceUnixProcessID, value: pid)
    return event
}

private func testModifierTracker() {
    var fallback: CGEventFlags = .maskShift
    let tracker = KeyboardModifierTracker(keyStateFlags: { fallback })
    XCTAssertEqual(tracker.flags, .maskShift) // held at startup / missing tap
    XCTAssertTrue(tracker.observe(modifierEvent(code: 58, flags: .maskAlternate)))
    fallback = .maskAlternate // deliberately remains stale throughout the release
    XCTAssertTrue(tracker.observe(modifierEvent(code: 58, flags: [])))
    XCTAssertEqual(tracker.flags, [])
    XCTAssertFalse(tracker.observe(modifierEvent(code: 58, flags: .maskAlternate, pid: 12345)))
    XCTAssertFalse(tracker.observe(modifierEvent(code: 58, flags: .maskAlternate, type: .mouseMoved)))
    XCTAssertFalse(tracker.observe(modifierEvent(code: -1, flags: .maskAlternate)))
    XCTAssertEqual(tracker.flags, [])
    // Left Option down, right Option down, left up while right held, right up.
    for code: Int64 in [58, 61, 58] {
        tracker.observe(modifierEvent(code: code, flags: .maskAlternate))
        XCTAssertEqual(tracker.flags, .maskAlternate)
    }
    tracker.observe(modifierEvent(code: 61, flags: []))
    XCTAssertEqual(tracker.flags, [])
    // Command-Tab must clear Command before the next unmodified pen click.
    tracker.observe(modifierEvent(code: 55, flags: .maskCommand))
    XCTAssertFalse(tracker.observe(modifierEvent(code: 48, flags: .maskCommand, type: .keyDown)))
    tracker.observe(modifierEvent(code: 55, flags: []))
    XCTAssertEqual(tracker.flags, [])
    for (code, flag): (Int64, CGEventFlags) in [(54, .maskCommand), (56, .maskShift),
            (60, .maskShift), (59, .maskControl), (62, .maskControl),
            (57, .maskAlphaShift), (63, .maskSecondaryFn)] {
        tracker.observe(modifierEvent(code: code, flags: flag))
        XCTAssertEqual(tracker.flags, flag)
        tracker.observe(modifierEvent(code: code, flags: []))
        XCTAssertEqual(tracker.flags, [])
    }
}

private func testCapturedPhotoshopSequence() throws {
    struct Record: Decodable {
        let kind: String
        let type: UInt32
        let flags: UInt64
        let keyCode: Int64
        let buttons: Int64
    }
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/diagnostics/photoshop-option-release.jsonl")
    let records = try String(contentsOf: fixture, encoding: .utf8).split(separator: "\n")
        .map { try JSONDecoder().decode(Record.self, from: Data($0.utf8)) }
    // This intentionally never clears, simulating the shared stale Option flag.
    let tracker = KeyboardModifierTracker(keyStateFlags: { .maskAlternate })
    tracker.observe(modifierEvent(code: 58, flags: []))
    var output: [CGEvent] = []
    let driver = TabletEventSynthesizer(eventSink: { output.append($0) }, keyboardFlags: { tracker.flags })
    var expected: CGEventFlags = []
    var staleCapturedEvents = 0
    var releases = 0
    for record in records {
        if record.kind == "keyboard" {
            let event = modifierEvent(code: record.keyCode, flags: CGEventFlags(rawValue: record.flags),
                                      type: CGEventType(rawValue: record.type)!)
            if tracker.observe(event) {
                expected = event.flags.intersection(KeyboardModifierTracker.modifierMask)
                if record.keyCode == 58 && !expected.contains(.maskAlternate) { releases += 1 }
            }
            continue
        }
        if CGEventFlags(rawValue: record.flags).contains(.maskAlternate) && !expected.contains(.maskAlternate) {
            staleCapturedEvents += 1
        }
        if record.type == CGEventType.tabletProximity.rawValue { continue }
        let down = record.buttons & 1 != 0
        let before = output.count
        driver.processPenEvent(PenEvent(rawX: 20000, rawY: 10000, rawPressure: down ? 1000 : 0,
            tiltX: 0, tiltY: 0, isTipDown: down, isBarrel1: false, isBarrel2: false,
            isEraser: false, isHovering: true))
        for event in output.dropFirst(before) {
            XCTAssertEqual(event.flags.intersection(KeyboardModifierTracker.modifierMask), expected)
        }
    }
    XCTAssertEqual(releases, 6)
    XCTAssertEqual(staleCapturedEvents, 23)
    XCTAssertTrue(output.contains { $0.type == .leftMouseDown && $0.flags.contains(.maskAlternate) })
    XCTAssertTrue(output.contains { $0.type == .leftMouseDown && !$0.flags.contains(.maskAlternate) })
    print("Captured Photoshop replay: six Option releases; 23 stale recorded events corrected")
}

testModifierTracker()
do { try testCapturedPhotoshopSequence() }
catch { failures += 1; print("FAIL loading Photoshop regression fixture: \(error)") }

print("Pointer, modifier tracker, incident gesture and captured-sequence checks completed; \(failures) failed assertions")
exit(failures == 0 ? 0 : 1)
