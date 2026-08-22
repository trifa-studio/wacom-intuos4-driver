import Foundation

public enum PressureProfile: Sendable {
    case linear
    case soft
    case firm
    case custom(gamma: Double)
}

public struct PressureCurve: Sendable {
    public var profile: PressureProfile
    public var deadZoneThreshold: Double // Pressure below this is treated as 0

    public init(profile: PressureProfile = .linear, deadZoneThreshold: Double = 0.01) {
        self.profile = profile
        self.deadZoneThreshold = deadZoneThreshold
    }

    /// Evaluates the input pressure (0.0 ... 1.0) through the curve
    public func evaluate(rawNormalized: Double) -> Double {
        if rawNormalized <= deadZoneThreshold {
            return 0.0
        }
        
        let adjusted = (rawNormalized - deadZoneThreshold) / (1.0 - deadZoneThreshold)
        let clamped = max(0.0, min(1.0, adjusted))
        
        switch profile {
        case .linear:
            return clamped
        case .soft:
            // S-curve / Power function: gentle press gives more response
            return pow(clamped, 0.65)
        case .firm:
            // Requires higher pressure to reach top values
            return pow(clamped, 1.5)
        case .custom(let gamma):
            return pow(clamped, max(0.1, min(4.0, gamma)))
        }
    }
}
