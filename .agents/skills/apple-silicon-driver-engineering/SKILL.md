---
name: apple-silicon-driver-engineering
description: >-
  Expert guidance for low-level Apple Silicon (ARM64) macOS systems and driver engineering.
  Use when developing user-space drivers, IOKit / IOHIDManager USB/Bluetooth transports,
  handling ARM64 memory alignment and raw pointer buffers, or configuring launchd LaunchAgents.
---

# Apple Silicon macOS Driver Engineering

This skill provides best practices, APIs, and guidelines for developing native user-space drivers and hardware I/O services on Apple Silicon (`arm64`) macOS.

## 1. Core Principles for Apple Silicon (ARM64)

- **Zero KEXT Architecture:** Never use kernel extensions (`.kext`). Modern macOS exclusively uses user-space IOKit (`IOHIDManager`, `IOBluetooth`, `USBDriverKit`) running within standard user or daemon sessions.
- **ARM64 Alignment & Endianness:** Hardware packets from USB/Bluetooth are little-endian. When reading multi-byte integers from raw buffers:
  ```swift
  // Always use explicit little-endian byte reassembly
  let rawX = UInt16(buffer[2]) | (UInt16(buffer[3]) << 8)
  ```
- **Zero-Copy Memory Safety:** Use Swift's `UnsafeRawBufferPointer` or `Data` without unnecessary heap allocations inside high-frequency HID callback loops.

## 2. IOHIDManager Transport Lifecycle

### 2.1 Device Matching & Setup
```swift
import IOKit
import IOKit.hid

public final class USBHIDTransport {
    private var manager: IOHIDManager?
    private let queue = DispatchQueue(label: "com.intuos.hid.queue", qos: .userInteractive)

    public func start(vendorID: Int, productID: Int) {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let manager = manager else { return }

        let matchDict: [String: Any] = [
            kIOHIDVendorIDKey as String: vendorID,
            kIOHIDProductIDKey as String: productID
        ]

        IOHIDManagerSetDeviceMatching(manager, matchDict as CFDictionary)
        
        let matchingCallback: IOHIDDeviceCallback = { context, result, sender, device in
            guard let context = context else { return }
            let transport = Unmanaged<USBHIDTransport>.fromOpaque(context).takeUnretainedValue()
            transport.deviceAttached(device)
        }

        let removalCallback: IOHIDDeviceCallback = { context, result, sender, device in
            guard let context = context else { return }
            let transport = Unmanaged<USBHIDTransport>.fromOpaque(context).takeUnretainedValue()
            transport.deviceRemoved(device)
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, matchingCallback, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, removalCallback, context)

        IOHIDManagerSetDispatchQueue(manager, queue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }
}
```

### 2.2 Wacom Feature Report Mode Switch
Wacom tablets default to generic mouse emulation on connection. A feature report must be sent immediately after `IOHIDDeviceOpen` to activate raw digitizer streaming:

```swift
public func sendModeSwitch(device: IOHIDDevice) {
    // Wacom feature report command to switch from mouse to raw tablet mode (Report ID 0x02, Mode 0x02)
    var report: [UInt8] = [0x02, 0x02]
    let result = IOHIDDeviceSetReport(
        device,
        kIOHIDReportTypeFeature,
        CFIndex(report[0]),
        &report,
        report.count
    )
    if result != kIOReturnSuccess {
        // Fallback: Some Intuos firmware variants accept 1-byte command
        var altReport: [UInt8] = [0x02]
        IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(altReport[0]), &altReport, altReport.count)
    }
}
```

## 3. High-Rate Packet Stream Callbacks
Register the raw report callback to capture streaming HID packets:

```swift
let reportCallback: IOHIDReportCallback = { context, result, sender, type, reportID, report, reportLength in
    guard let context = context, let report = report, reportLength > 0 else { return }
    let transport = Unmanaged<USBHIDTransport>.fromOpaque(context).takeUnretainedValue()
    let buffer = UnsafeRawBufferPointer(start: report, count: reportLength)
    transport.handleIncomingReport(reportID: reportID, bytes: buffer)
}
IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, reportBufferSize, reportCallback, context)
```
