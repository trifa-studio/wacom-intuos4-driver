import Foundation
import IOKit
import IOKit.hid

public enum WacomModeSwitch {
    /// Feature report that switches the tablet from generic HID mouse fallback
    /// into full Wacom digitizer reports.
    /// Verified on PTK-540WL (PID 0x00BC): SET_REPORT(feature, id=0x02, {0x02, 0x02}).
    /// IOKit counts the report-ID byte inside the buffer length, so 3 bytes total.
    public static let featureReportID: CFIndex = 2
    public static let primaryPayload: [UInt8] = [0x02, 0x02, 0x02]
    public static let alternatePayload: [UInt8] = [0x02, 0x02]

    @discardableResult
    public static func enableDigitizerMode(device: IOHIDDevice) -> Bool {
        // USB mode switch: Report 0x02
        _ = setFeature(device: device, report: [0x02, 0x02])
        _ = setFeature(device: device, report: [0x02, 0x02, 0x02])

        // Bluetooth mode switch: Report 0x03 (SetHidModeWacom, SetScanRateFast, SetPenScanMode)
        _ = setFeature(device: device, report: [0x03, 0x01, 0x01, 0x01])
        _ = setFeature(device: device, report: [0x03, 0x01])
        return true
    }

    /// Returns the tablet to generic HID mouse mode so the system driver keeps
    /// working after we close. Verified on PTK-540WL: readback reflects 0x01.
    @discardableResult
    public static func restoreMouseMode(device: IOHIDDevice) -> Bool {
        return setFeature(device: device, report: [0x02, 0x01])
    }

    private static func setFeature(device: IOHIDDevice, report: [UInt8]) -> Bool {
        var buffer = report
        var result = IOHIDDeviceSetReport(
            device,
            kIOHIDReportTypeFeature,
            CFIndex(buffer[0]),
            &buffer,
            buffer.count
        )
        if result != kIOReturnSuccess {
            result = IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeOutput,
                CFIndex(buffer[0]),
                &buffer,
                buffer.count
            )
        }
        return result == kIOReturnSuccess
    }
}
