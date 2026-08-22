import Foundation
import CoreGraphics

public struct WacomModelDescriptor: Sendable, Equatable {
    public let modelName: String
    public let productID: Int
    public let maxX: UInt32
    public let maxY: UInt32
    public let maxPressure: UInt16
    public let keyCount: Int
    public let hasOLED: Bool
    public let isWireless: Bool

    public init(modelName: String, productID: Int, maxX: UInt32, maxY: UInt32, maxPressure: UInt16 = 2047, keyCount: Int = 8, hasOLED: Bool = true, isWireless: Bool = false) {
        self.modelName = modelName
        self.productID = productID
        self.maxX = maxX
        self.maxY = maxY
        self.maxPressure = maxPressure
        self.keyCount = keyCount
        self.hasOLED = hasOLED
        self.isWireless = isWireless
    }
}

/// Hardware and protocol constants for Wacom Intuos4 / Intuos5 / Intuos Pro families.
public enum WacomConstants {
    public static let vendorID: Int = 0x056A
    public static let usbProductID: Int = 0x00B9
    public static let bluetoothProductID: Int = 0x00BD

    /// All supported Intuos4, Intuos5, and Intuos Pro models
    public static let supportedModels: [Int: WacomModelDescriptor] = [
        // Intuos4 Series
        0x00B8: WacomModelDescriptor(modelName: "Intuos4 Small (PTK-440)", productID: 0x00B8, maxX: 31496, maxY: 19685, keyCount: 6, hasOLED: false),
        0x00B9: WacomModelDescriptor(modelName: "Intuos4 Medium (PTK-640)", productID: 0x00B9, maxX: 44704, maxY: 27940, keyCount: 8, hasOLED: true),
        0x00BA: WacomModelDescriptor(modelName: "Intuos4 Large (PTK-840)", productID: 0x00BA, maxX: 65024, maxY: 40640, keyCount: 8, hasOLED: true),
        0x00BB: WacomModelDescriptor(modelName: "Intuos4 Extra Large (PTK-1240)", productID: 0x00BB, maxX: 97536, maxY: 60960, keyCount: 8, hasOLED: true),
        0x00BC: WacomModelDescriptor(modelName: "Intuos4 Wireless USB (PTK-540WL)", productID: 0x00BC, maxX: 40640, maxY: 25400, keyCount: 8, hasOLED: true, isWireless: true),
        0x00BD: WacomModelDescriptor(modelName: "Intuos4 Wireless Bluetooth (PTK-540WL)", productID: 0x00BD, maxX: 40640, maxY: 25400, keyCount: 8, hasOLED: true, isWireless: true),

        // Intuos5 & Intuos Pro Series (Share same pen/pad packets)
        0x0026: WacomModelDescriptor(modelName: "Intuos5 Touch Small (PTH-450)", productID: 0x0026, maxX: 31496, maxY: 19685, keyCount: 6, hasOLED: false),
        0x0027: WacomModelDescriptor(modelName: "Intuos5 Touch Medium (PTH-650)", productID: 0x0027, maxX: 44704, maxY: 27940, keyCount: 8, hasOLED: false),
        0x0028: WacomModelDescriptor(modelName: "Intuos5 Touch Large (PTH-850)", productID: 0x0028, maxX: 65024, maxY: 40640, keyCount: 8, hasOLED: false),
        0x0314: WacomModelDescriptor(modelName: "Intuos Pro Small (PTH-451)", productID: 0x0314, maxX: 31496, maxY: 19685, keyCount: 6, hasOLED: false),
        0x0315: WacomModelDescriptor(modelName: "Intuos Pro Medium (PTH-651)", productID: 0x0315, maxX: 44704, maxY: 27940, keyCount: 8, hasOLED: false),
        0x0317: WacomModelDescriptor(modelName: "Intuos Pro Large (PTH-851)", productID: 0x0317, maxX: 65024, maxY: 40640, keyCount: 8, hasOLED: false)
    ]

    public static var usbProductIDs: [Int] {
        Array(supportedModels.keys)
    }

    public static func descriptor(for productID: Int) -> WacomModelDescriptor {
        supportedModels[productID] ?? WacomModelDescriptor(
            modelName: "Intuos4 Wireless (PTK-540WL)",
            productID: productID,
            maxX: 40640,
            maxY: 25400,
            maxPressure: 2047,
            keyCount: 8,
            hasOLED: true,
            isWireless: true
        )
    }

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
        maxX: UInt32 = WacomConstants.maxX,
        maxY: UInt32 = WacomConstants.maxY,
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
        self.rawX = min(rawX, maxX)
        self.rawY = min(rawY, maxY)
        self.normalizedX = Double(self.rawX) / Double(max(1, maxX))
        self.normalizedY = Double(self.rawY) / Double(max(1, maxY))

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
