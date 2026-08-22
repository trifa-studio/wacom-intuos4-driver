import Foundation
import CoreGraphics

/// Hardware and protocol constants for PTK-540WL (linuxwacom INTUOS4 / INTUOS4WL).
public enum WacomConstants {
    public static let vendorID: Int = 0x056A
    public static let usbProductID: Int = 0x00B9
    /// PTK-540WL firmware variants: USB (0x00B9, 0x00BC) and Bluetooth (0x00BD).
    public static let usbProductIDs: [Int] = [0x00B9, 0x00BC, 0x00BD]
    public static let bluetoothProductID: Int = 0x00BD

    public static let maxX: UInt32 = 40640
    public static let maxY: UInt32 = 25400
    public static let maxPressure: UInt16 = 2047
    public static let maxDistance: UInt8 = 63
    /// Tilt is reported as signed offset from 64 (range approximately -64…+63).
    public static let tiltCenter: Int = 64
    public static let maxTiltMagnitude: Double = 64.0

    public static let oledWidth: Int = 64
    public static let oledHeight: Int = 32
    public static let oledBufferSize: Int = 1024
    public static let expressKeyCount: Int = 8
    public static let touchRingSteps: Int = 72

    // Report IDs (linuxwacom wacom_wac.h)
    public static let reportPenEnabled: UInt8 = 0x02
    public static let reportIntuosID1: UInt8 = 0x05
    public static let reportIntuosID2: UInt8 = 0x06
    public static let reportIntuosPad: UInt8 = 0x0C
    public static let reportIntuosPen: UInt8 = 0x10
    public static let reportBTBatch2: UInt8 = 0x03
    public static let reportBTBatch3: UInt8 = 0x04

    /// linuxwacom batcap_i4[]
    public static let batcapI4: [Int] = [1, 15, 30, 45, 60, 70, 85, 100]
}

public struct PenEvent: Sendable, Equatable {
    public let rawX: UInt32
    public let rawY: UInt32
    public let normalizedX: Double
    public let normalizedY: Double

    public let rawPressure: UInt16
    public let normalizedPressure: Double

    /// Normalized tilt −1…1 (raw/64 after centering).
    public let tiltX: Double
    public let tiltY: Double
    public let rawTiltX: Int
    public let rawTiltY: Int

    public let distance: UInt8
    public let isTipDown: Bool
    public let isBarrel1: Bool
    public let isBarrel2: Bool
    public let isEraser: Bool
    public let isHovering: Bool

    public let toolID: UInt32
    public let serialNumber: UInt64
    public let timestamp: UInt64

    public init(
        rawX: UInt32,
        rawY: UInt32,
        rawPressure: UInt16,
        tiltX: Double,
        tiltY: Double,
        rawTiltX: Int = 0,
        rawTiltY: Int = 0,
        distance: UInt8 = 0,
        isTipDown: Bool,
        isBarrel1: Bool,
        isBarrel2: Bool,
        isEraser: Bool,
        isHovering: Bool,
        toolID: UInt32 = 0x822,
        serialNumber: UInt64 = 0,
        timestamp: UInt64 = 0
    ) {
        self.rawX = min(rawX, WacomConstants.maxX)
        self.rawY = min(rawY, WacomConstants.maxY)
        self.normalizedX = Double(self.rawX) / Double(WacomConstants.maxX)
        self.normalizedY = Double(self.rawY) / Double(WacomConstants.maxY)

        self.rawPressure = min(rawPressure, WacomConstants.maxPressure)
        self.normalizedPressure = Double(self.rawPressure) / Double(WacomConstants.maxPressure)

        self.tiltX = max(-1.0, min(1.0, tiltX))
        self.tiltY = max(-1.0, min(1.0, tiltY))
        self.rawTiltX = rawTiltX
        self.rawTiltY = rawTiltY
        self.distance = min(distance, WacomConstants.maxDistance)

        self.isTipDown = isTipDown
        self.isBarrel1 = isBarrel1
        self.isBarrel2 = isBarrel2
        self.isEraser = isEraser
        self.isHovering = isHovering

        self.toolID = toolID
        self.serialNumber = serialNumber
        self.timestamp = timestamp
    }
}

public struct PadEvent: Sendable, Equatable {
    /// 8 ExpressKeys (true = pressed), index 0…7
    public let keys: [Bool]
    public let ringTouched: Bool
    public let ringPosition: UInt8
    /// Ring center / mode toggle (Intuos4 button bit 0 from data[2])
    public let centerButton: Bool
    /// 0…3 ring mode LED index (host-tracked on center edge)
    public let mode: UInt8

    public init(
        keys: [Bool] = [Bool](repeating: false, count: 8),
        ringTouched: Bool = false,
        ringPosition: UInt8 = 0,
        centerButton: Bool = false,
        mode: UInt8 = 0
    ) {
        var k = keys
        if k.count < 8 {
            k.append(contentsOf: [Bool](repeating: false, count: 8 - k.count))
        } else if k.count > 8 {
            k = Array(k.prefix(8))
        }
        self.keys = k
        self.ringTouched = ringTouched
        self.ringPosition = ringPosition % 72
        self.centerButton = centerButton
        self.mode = mode % 4
    }
}

public struct BatteryEvent: Sendable, Equatable {
    public let percentage: Int
    public let isCharging: Bool
    public let isConnectedPower: Bool

    public init(percentage: Int, isCharging: Bool, isConnectedPower: Bool) {
        self.percentage = max(0, min(100, percentage))
        self.isCharging = isCharging
        self.isConnectedPower = isConnectedPower
    }
}

public enum ParsedPacket: Sendable, Equatable {
    case pen(PenEvent)
    case pad(PadEvent)
    case battery(BatteryEvent)
    /// Tool entered proximity with ID (no coordinates yet)
    case toolProximity(toolID: UInt32, serial: UInt64, isEraser: Bool)
    case toolOutOfProximity
    case unknown(reportID: UInt8, length: Int)
}
