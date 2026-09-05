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
print("8 pointer scenarios completed; \(failures) failed assertions")
exit(failures == 0 ? 0 : 1)
