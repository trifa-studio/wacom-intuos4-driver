import Foundation

/// Four distinct Control taps in four seconds. Save after the fourth release,
/// preserving the events before the user's recovery gesture.
public struct ControlIncidentGesture {
    private var isDown = false
    private var presses: [TimeInterval] = []
    public init() {}

    public mutating func transition(isDown down: Bool, at time: TimeInterval) -> Bool {
        guard down != isDown else { return false }
        isDown = down
        if down {
            presses.removeAll { time - $0 > 4 }
            presses.append(time)
            return false
        }
        guard presses.count >= 4, let first = presses.first, time - first <= 4 else { return false }
        presses.removeAll()
        return true
    }
}
