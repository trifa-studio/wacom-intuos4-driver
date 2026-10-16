import Foundation
import CoreGraphics
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

    private func sample(x: UInt32 = 20000, down: Bool = true, right: Bool = false,
                        double: Bool = false, pressure: UInt16 = 1000) -> PenEvent {
        PenEvent(rawX: x, rawY: 10000, rawPressure: down ? pressure : 0,
                 tiltX: 0, tiltY: 0, isTipDown: down, isBarrel1: right,
                 isBarrel2: double, isEraser: false, isHovering: true)
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
}

PointerTests().testStationaryTapHasNoDragButPreservesPressureUpdates()
PointerTests().testJitterIsATapAndReleaseStaysAtPressLocation()
PointerTests().testIntentionalMovementStartsAndContinuesDrag()
PointerTests().testLeavingRangeReleasesBeforeProximityExitAndOnlyOnce()
PointerTests().testSideButtonReleasesTipBeforeRightClick()
PointerTests().testDoubleClickButtonHasConsistentButtonFields()
PointerTests().testCommandReleaseIsReflectedInNextClick()
PointerTests().testDoubleClickAndSeparateControlClicks()
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
