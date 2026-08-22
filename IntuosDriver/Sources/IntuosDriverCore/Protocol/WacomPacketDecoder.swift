import Foundation

/// Packet decoder aligned with linuxwacom `wacom_intuos_irq` / `wacom_intuos_general`
/// / `wacom_intuos_pad` / `wacom_intuos_bt_irq` for INTUOS4 and INTUOS4WL (PTK-540WL).
public final class WacomPacketDecoder: @unchecked Sendable {
    private var currentToolID: UInt32 = 0
    private var currentSerial: UInt64 = 0
    private var stylusInProximity: Bool = false
    private var isEraserTool: Bool = false
    private var ringMode: UInt8 = 0
    private var previousCenterButton: Bool = false

    /// Last known pen sample used when emitting proximity-only transitions.
    private var lastPen: PenEvent?

    public init() {}

    public func reset() {
        currentToolID = 0
        currentSerial = 0
        stylusInProximity = false
        isEraserTool = false
        ringMode = 0
        previousCenterButton = false
        lastPen = nil
    }

    /// Decode a HID input report. `bytes` may or may not include the report ID as byte 0.
    public func decode(reportID: UInt8, buffer: UnsafeRawBufferPointer, timestamp: UInt64 = 0) -> [ParsedPacket] {
        decode(reportID: reportID, bytes: Array(buffer), timestamp: timestamp)
    }

    public func decode(reportID: UInt8, bytes: [UInt8], timestamp: UInt64 = 0) -> [ParsedPacket] {
        guard !bytes.isEmpty else {
            return [.unknown(reportID: reportID, length: 0)]
        }

        let frame = normalizeFrame(reportID: reportID, bytes: bytes)
        let rid = frame[0]

        switch rid {
        case WacomConstants.reportBTBatch3:
            return decodeBluetoothBatch(frame: frame, penFrames: 3, timestamp: timestamp)
        case WacomConstants.reportBTBatch2:
            return decodeBluetoothBatch(frame: frame, penFrames: 2, timestamp: timestamp)
        case WacomConstants.reportIntuosPad:
            return [decodePadReport(frame: frame)]
        case WacomConstants.reportPenEnabled,
             WacomConstants.reportIntuosPen,
             WacomConstants.reportIntuosID1,
             WacomConstants.reportIntuosID2:
            if let packet = decodeIntuosPenPath(frame: frame, timestamp: timestamp) {
                return [packet]
            }
            return [.unknown(reportID: rid, length: frame.count)]
        default:
            // Some stacks deliver pad on 0x03 for USB; only treat as pad if short and not BT-sized.
            if rid == 0x03 && frame.count < 20 {
                return [decodePadReport(frame: frame)]
            }
            return [.unknown(reportID: rid, length: frame.count)]
        }
    }

    // MARK: - Frame normalize

    private func normalizeFrame(reportID: UInt8, bytes: [UInt8]) -> [UInt8] {
        if bytes[0] == reportID {
            return bytes
        }
        // HID callback often strips report ID into the reportID argument.
        if reportID != 0 {
            return [reportID] + bytes
        }
        return bytes
    }

    // MARK: - BT batch (INTUOS4WL)

    private func decodeBluetoothBatch(frame: [UInt8], penFrames: Int, timestamp: UInt64) -> [ParsedPacket] {
        var packets: [ParsedPacket] = []
        var offset = 1
        let needed = 1 + penFrames * 10 + 1
        guard frame.count >= min(needed, 1 + 2 * 10 + 1) else {
            return [.unknown(reportID: frame[0], length: frame.count)]
        }

        for _ in 0..<penFrames {
            guard offset + 10 <= frame.count else { break }
            let slice = Array(frame[offset..<(offset + 10)])
            // Sub-frames are full 10-byte Intuos packets starting with report-like byte;
            // linuxwacom feeds data+i where first byte is the sub-report lead (often 0x02).
            var sub = slice
            if sub[0] != WacomConstants.reportPenEnabled
                && sub[0] != WacomConstants.reportIntuosPen
                && sub[0] != WacomConstants.reportIntuosPad
                && sub[0] != WacomConstants.reportIntuosID1 {
                // Prepend pen report id if missing
                sub = [WacomConstants.reportPenEnabled] + Array(sub.prefix(9))
            }
            if let packet = decodeIntuosPenPath(frame: sub, timestamp: timestamp) {
                packets.append(packet)
            }
            offset += 10
        }

        if offset < frame.count {
            packets.append(decodeBatteryFromPowerByte(frame[offset]))
        }
        return packets.isEmpty ? [.unknown(reportID: frame[0], length: frame.count)] : packets
    }

    // MARK: - Pen path (inout + general)

    private func decodeIntuosPenPath(frame: [UInt8], timestamp: UInt64) -> ParsedPacket? {
        guard frame.count >= 2 else { return nil }

        // Pad misplaced?
        if frame[0] == WacomConstants.reportIntuosPad {
            return decodePadReport(frame: frame)
        }

        if let inoutResult = decodeInOut(frame: frame) {
            return inoutResult
        }

        return decodeGeneralPen(frame: frame, timestamp: timestamp)
    }

    /// linuxwacom wacom_intuos_inout
    private func decodeInOut(frame: [UInt8]) -> ParsedPacket? {
        let b1 = frame[1]

        // Enter report: (data[1] & 0xfc) == 0xc0
        if (b1 & 0xfc) == 0xc0 {
            guard frame.count >= 9 else { return .unknown(reportID: frame[0], length: frame.count) }
            let serial =
                (UInt64(frame[3] & 0x0f) << 28)
                + (UInt64(frame[4]) << 20)
                + (UInt64(frame[5]) << 12)
                + (UInt64(frame[6]) << 4)
                + (UInt64(frame[7]) >> 4)

            let toolID =
                (UInt32(frame[2]) << 4)
                | (UInt32(frame[3]) >> 4)
                | (UInt32(frame[7] & 0x0f) << 20)
                | (UInt32(frame[8] & 0xf0) << 12)

            currentSerial = serial
            currentToolID = toolID
            isEraserTool = (toolID & 0x0008) != 0 || Self.isEraserToolID(toolID)
            stylusInProximity = true

            return .toolProximity(toolID: toolID, serial: serial, isEraser: isEraserTool)
        }

        // In range: (data[1] & 0xfe) == 0x20
        if (b1 & 0xfe) == 0x20 {
            stylusInProximity = true
            if let pen = lastPen {
                let updated = PenEvent(
                    rawX: pen.rawX,
                    rawY: pen.rawY,
                    rawPressure: 0,
                    tiltX: pen.tiltX,
                    tiltY: pen.tiltY,
                    rawTiltX: pen.rawTiltX,
                    rawTiltY: pen.rawTiltY,
                    distance: WacomConstants.maxDistance,
                    isTipDown: false,
                    isBarrel1: false,
                    isBarrel2: false,
                    isEraser: isEraserTool,
                    isHovering: true,
                    toolID: currentToolID,
                    serialNumber: currentSerial,
                    timestamp: pen.timestamp
                )
                lastPen = updated
                return .pen(updated)
            }
            return .toolProximity(toolID: currentToolID, serial: currentSerial, isEraser: isEraserTool)
        }

        // Exit: (data[1] & 0xfe) == 0x80
        if (b1 & 0xfe) == 0x80 {
            stylusInProximity = false
            currentToolID = 0
            return .toolOutOfProximity
        }

        return nil
    }

    /// linuxwacom wacom_intuos_general (INTUOS4 / pressure_max 2047)
    private func decodeGeneralPen(frame: [UInt8], timestamp: UInt64) -> ParsedPacket? {
        guard frame.count >= 10 else {
            return .unknown(reportID: frame[0], length: frame.count)
        }

        // Without tool ID we still decode coordinates (host may have missed enter packet)
        // but mark hovering from prox-like traffic.
        let type = (frame[1] >> 1) & 0x0F

        let x = (Self.be16(frame, 2) << 1) | UInt32((frame[9] >> 1) & 0x01)
        let y = (Self.be16(frame, 4) << 1) | UInt32(frame[9] & 0x01)
        let distance = frame[9] >> 2

        switch type {
        case 0x00, 0x01, 0x02, 0x03:
            // General pen packet
            var pressure = UInt16(frame[6]) << 3
            pressure |= UInt16((frame[7] & 0xC0) >> 5)
            pressure |= UInt16(frame[1] & 0x01)
            // pressure_max == 2047 → no >>= 1

            let rawTiltX = Int(((Int(frame[7]) << 1) & 0x7e) | (Int(frame[8]) >> 7)) - WacomConstants.tiltCenter
            let rawTiltY = Int(frame[8] & 0x7f) - WacomConstants.tiltCenter
            let tiltX = Double(rawTiltX) / WacomConstants.maxTiltMagnitude
            let tiltY = Double(rawTiltY) / WacomConstants.maxTiltMagnitude

            let barrel1 = (frame[1] & 0x02) != 0
            let barrel2 = (frame[1] & 0x04) != 0
            let tipDown = pressure > 10
            let hovering = stylusInProximity || currentToolID != 0 || tipDown || distance < WacomConstants.maxDistance

            if hovering {
                stylusInProximity = true
            }

            let event = PenEvent(
                rawX: min(x, WacomConstants.maxX),
                rawY: min(y, WacomConstants.maxY),
                rawPressure: min(pressure, WacomConstants.maxPressure),
                tiltX: tiltX,
                tiltY: tiltY,
                rawTiltX: rawTiltX,
                rawTiltY: rawTiltY,
                distance: distance,
                isTipDown: tipDown,
                isBarrel1: barrel1,
                isBarrel2: barrel2,
                isEraser: isEraserTool,
                isHovering: hovering,
                toolID: currentToolID != 0 ? currentToolID : 0x822,
                serialNumber: currentSerial,
                timestamp: timestamp
            )
            lastPen = event
            return .pen(event)

        case 0x0a:
            // Airbrush second packet — tilt / wheel only; skip full pen emit
            return .unknown(reportID: frame[0], length: frame.count)

        default:
            // Mouse / lens / rotation — not required for MVP pen
            if stylusInProximity || currentToolID != 0 {
                let event = PenEvent(
                    rawX: min(x, WacomConstants.maxX),
                    rawY: min(y, WacomConstants.maxY),
                    rawPressure: 0,
                    tiltX: 0,
                    tiltY: 0,
                    distance: distance,
                    isTipDown: false,
                    isBarrel1: false,
                    isBarrel2: false,
                    isEraser: isEraserTool,
                    isHovering: true,
                    toolID: currentToolID != 0 ? currentToolID : 0x822,
                    serialNumber: currentSerial,
                    timestamp: timestamp
                )
                lastPen = event
                return .pen(event)
            }
            return .unknown(reportID: frame[0], length: frame.count)
        }
    }

    // MARK: - Pad (INTUOS4S…INTUOS4L)

    /// linuxwacom: buttons = (data[3] << 1) | (data[2] & 0x01); ring1 = data[1]
    private func decodePadReport(frame: [UInt8]) -> ParsedPacket {
        guard frame.count >= 4 else {
            return .unknown(reportID: frame[0], length: frame.count)
        }

        let ringByte = frame[1]
        let ringTouched = (ringByte & 0x80) != 0
        let ringPosition = ringByte & 0x7f

        let buttons = (Int(frame[3]) << 1) | (Int(frame[2]) & 0x01)
        // Bit 0 = center / mode (data[2] & 1); bits 1…8 = ExpressKeys from data[3]
        let center = (buttons & 0x01) != 0
        var keys = [Bool](repeating: false, count: 8)
        for i in 0..<8 {
            keys[i] = (buttons & (1 << (i + 1))) != 0
        }

        if center && !previousCenterButton {
            ringMode = (ringMode + 1) % 4
        }
        previousCenterButton = center

        return .pad(PadEvent(
            keys: keys,
            ringTouched: ringTouched,
            ringPosition: ringPosition,
            centerButton: center,
            mode: ringMode
        ))
    }

    // MARK: - Battery

    private func decodeBatteryFromPowerByte(_ powerRaw: UInt8) -> ParsedPacket {
        let idx = Int(powerRaw & 0x07)
        let pct = idx < WacomConstants.batcapI4.count ? WacomConstants.batcapI4[idx] : 0
        let charging = (powerRaw & 0x08) != 0
        let psConnected = (powerRaw & 0x10) != 0
        return .battery(BatteryEvent(
            percentage: pct,
            isCharging: charging,
            isConnectedPower: psConnected
        ))
    }

    // MARK: - Helpers

    private static func be16(_ bytes: [UInt8], _ index: Int) -> UInt32 {
        guard index + 1 < bytes.count else { return 0 }
        return (UInt32(bytes[index]) << 8) | UInt32(bytes[index + 1])
    }

    private static func isEraserToolID(_ toolID: UInt32) -> Bool {
        // linuxwacom: default eraser if tool_id & 0x0008
        (toolID & 0x0008) != 0
    }
}
