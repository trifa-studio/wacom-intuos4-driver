---
name: wacom-protocol-and-oled
description: >-
  Wacom Intuos4 / PTK-540WL packet protocol decoders, ExpressKey / Touch Ring handlers,
  and 64x32 1-bit OLED image conversion algorithms for physical key displays.
  Use when parsing Wacom raw USB/Bluetooth input packets, managing 8 ExpressKeys and 72-step Touch Ring,
  or encoding monochrome bitmaps to send to the tablet's OLED displays.
---

# Wacom Intuos4 Protocol & OLED Display Controller

This skill documents the binary packet formats, parsing algorithms, and OLED graphic conversion techniques for the **Wacom Intuos4 Wireless (PTK-540WL)** based on `linuxwacom` (`wacom_wac.c`) and reverse-engineered hardware specifications.

## 1. Hardware Report Formats

### 1.1 USB Report (PID `0x00B9`)
Standard Wacom USB Intuos4 packets are transmitted on Endpoint 1 (Interrupt IN).

#### Pen Packet (Report ID `0x02` or `0x10`)
* **Byte 1:** Status / proximity flags:
  - Bit 5: Proximity / In-Range
  - Bit 1: Tip switch (down/contact)
  - Bit 2: Barrel button 1
  - Bit 3: Barrel button 2 / Eraser
* **Bytes 2–3:** Absolute X Coordinate (Little Endian, 16-bit: `rawX = buffer[2] | (buffer[3] << 8) | ((buffer[9] & 0x03) << 16)`)
* **Bytes 4–5:** Absolute Y Coordinate (Little Endian: `rawY = buffer[4] | (buffer[5] << 8) | ((buffer[9] & 0x0C) << 14)`)
* **Bytes 6–7:** Pressure Level (0 to 2047: `pressure = (buffer[6] | (buffer[7] << 8)) & 0x07FF`)
* **Byte 8:** Tilt X (signed 7-bit, `-64` to `+63`)
* **Byte 9:** Tilt Y (signed 7-bit, `-64` to `+63`)

#### Pad Packet (Report ID `0x03` or `0x0C`)
* **Bytes 1–2:** ExpressKeys bitmask (8 buttons: Keys 0 to 7)
* **Byte 3:** Touch Ring:
  - Bit 7: Touch Ring touched flag
  - Bits 0–6: Position (0 to 71, counter-clockwise / clockwise)
* **Byte 4:** Center button / Mode toggle switch

---

## 2. OLED Display Conversion & Transmission

The PTK-540WL features 8 monochrome OLED displays (one next to each ExpressKey).
- **Resolution:** 64 pixels wide × 32 pixels high.
- **Color Depth:** 1-bit monochrome (0 = Black/Off, 1 = White/On).
- **Payload Size:** $64 \times 32 \div 8 = 256$ bytes per display.

### 2.1 CoreGraphics 1-Bit Nibbilizer Algorithm

```swift
import CoreGraphics
import Foundation

public final class WacomOLEDEncoder {
    public static let width = 64
    public static let height = 32
    public static let bufferSize = 256 // (64 * 32) / 8

    /// Converts a CGImage or custom text label to the 256-byte Intuos4 1-bit OLED buffer
    public static func encodeImage(_ image: CGImage) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: bufferSize)
        
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var rawPixels = [UInt8](repeating: 0, count: width * height)
        
        guard let context = CGContext(
            data: &rawPixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return output
        }
        
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        // Pack 8 horizontal grayscale pixels into 1 bitmask byte
        for y in 0..<height {
            for byteIndex in 0..<(width / 8) {
                var byteVal: UInt8 = 0
                for bit in 0..<8 {
                    let pixelX = byteIndex * 8 + bit
                    let pixel = rawPixels[y * width + pixelX]
                    if pixel > 128 { // Threshold to 1-bit
                        byteVal |= (1 << bit)
                    }
                }
                output[y * (width / 8) + byteIndex] = byteVal
            }
        }
        
        return output
    }
}
```

### 2.2 Transmitting OLED Image via HID Output Report
```swift
public func updateExpressKeyOLED(device: IOHIDDevice, keyIndex: UInt8, imageBytes: [UInt8]) {
    // Intuos4 OLED report structure:
    // Report ID 0x20..0x27 for keys 0..7
    var report = [UInt8](repeating: 0, count: 1 + imageBytes.count)
    report[0] = 0x20 + (keyIndex & 0x07) // Report ID
    for i in 0..<imageBytes.count {
        report[1 + i] = imageBytes[i]
    }
    
    IOHIDDeviceSetReport(
        device,
        kIOHIDReportTypeOutput,
        CFIndex(report[0]),
        &report,
        report.count
    )
}
```

---

## 3. Bluetooth Battery & Telemetry Decoding (PID `0x00BD`)

In Bluetooth Classic mode, battery status is transmitted in telemetry packets:

```swift
public struct WacomBatteryStatus {
    public let percentage: Int
    public let isCharging: Bool
    public let isConnectedPower: Bool
}

// Battery percentage LUT from linuxwacom batcap_i4
private let batcap_i4 = [1, 15, 30, 45, 60, 70, 85, 100]

public func parseBatteryByte(_ rawByte: UInt8) -> WacomBatteryStatus {
    let levelIndex = Int(rawByte & 0x07)
    let percentage = (levelIndex < batcap_i4.count) ? batcap_i4[levelIndex] : 0
    let isCharging = (rawByte & 0x20) != 0
    let isConnected = (rawByte & 0x40) != 0
    return WacomBatteryStatus(percentage: percentage, isCharging: isCharging, isConnectedPower: isConnected)
}
```
