import Foundation
import IOKit
import IOKit.hid
import IntuosDriverCore

final class DriverCLIHandler: USBTransportDelegate, @unchecked Sendable {
    private let decoder = WacomPacketDecoder()
    private let synthesizer = TabletEventSynthesizer()
    private let keyManager = ExpressKeyManager()
    private let ringManager = TouchRingManager()

    var enableEventSynthesis = true
    var verboseUnknown = true
    var hexDump = false
    var probeLEDs = false
    var transport: USBTransport?

    func transportDidConnect(device: IOHIDDevice) {
        print("✅ Connected to Wacom device")
        print("   Accessibility: \(TabletEventSynthesizer.isAccessibilityTrusted() ? "granted" : "MISSING (required for injection)")")
        print("   Event synthesis: \(enableEventSynthesis ? "ON" : "OFF (sniff only)")")

        if probeLEDs {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.runProbe(device: device)
            }
        }
    }

    private func runProbe(device: IOHIDDevice) {
        print("\n🔍 Testing multiplexed OLED format: [0x20, key_index, ... 256 bytes]...")
        let testPayload = OLEDEncoder.renderText("TEST")
        for keyIndex: UInt8 in 0..<8 {
            var buf = [0x20, keyIndex] + testPayload
            let r = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(0x20), &buf, buf.count)
            print(String(format: "  Key %d with [0x20, %02X, ... 256B]: result 0x%X", keyIndex, keyIndex, r))
            fflush(stdout)
            Thread.sleep(forTimeInterval: 0.02)
        }
        fflush(stdout)
        exit(0)
    }

    func transportDidDisconnect(device: IOHIDDevice) {
        print("⚠️  Tablet disconnected")
        decoder.reset()
        synthesizer.handleToolOutOfProximity()
    }

    func transportDidFail(message: String) {
        print("⚠️  \(message)")
    }

    func transportDidReceiveReport(reportID: UInt8, bytes: UnsafeRawBufferPointer) {
        if hexDump {
            let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            print(String(format: "RAW id=0x%02x len=%d | %@", reportID, bytes.count, hex))
        }

        let packets = decoder.decode(reportID: reportID, buffer: bytes)
        for packet in packets {
            handle(packet)
        }
    }

    private func handle(_ packet: ParsedPacket) {
        switch packet {
        case .pen(let pen):
            if enableEventSynthesis {
                synthesizer.processPenEvent(pen)
            }
            if pen.isHovering {
                print(String(
                    format: "🖊️  X=%5d Y=%5d P=%4d (%.2f) tilt=%+.2f,%+.2f dist=%2d tip=%d b1=%d b2=%d eraser=%d tool=0x%X",
                    pen.rawX, pen.rawY, pen.rawPressure, pen.normalizedPressure,
                    pen.tiltX, pen.tiltY, pen.distance,
                    pen.isTipDown ? 1 : 0, pen.isBarrel1 ? 1 : 0, pen.isBarrel2 ? 1 : 0,
                    pen.isEraser ? 1 : 0, pen.toolID
                ))
            }

        case .pad(let pad):
            if enableEventSynthesis {
                keyManager.processPadEvent(pad)
                ringManager.processPadEvent(pad)
            }
            let keyStr = pad.keys.map { $0 ? "1" : "0" }.joined()
            print("🎛️  keys=[\(keyStr)] ring=\(pad.ringPosition) touch=\(pad.ringTouched ? 1 : 0) center=\(pad.centerButton ? 1 : 0) mode=\(pad.mode)")

        case .battery(let bat):
            print("🔋 \(bat.percentage)% charging=\(bat.isCharging) ac=\(bat.isConnectedPower)")

        case .toolProximity(let toolID, let serial, let isEraser):
            if enableEventSynthesis {
                synthesizer.handleToolProximity(toolID: toolID, isEraser: isEraser)
            }
            print(String(format: "📎 tool in  id=0x%X serial=%llu eraser=%d", toolID, serial, isEraser ? 1 : 0))

        case .toolOutOfProximity:
            if enableEventSynthesis {
                synthesizer.handleToolOutOfProximity()
            }
            print("📎 tool out")

        case .unknown(let id, let len):
            if verboseUnknown {
                print(String(format: "❓ unknown report=0x%02x len=%d", id, len))
            }
        }
    }
}

// MARK: - Args

var sniffOnly = false
var hexDump = false
var noSeize = false
var matchBT = false
var probeLEDs = false
var fixtureDir: URL?

var args = Array(CommandLine.arguments.dropFirst())
while let arg = args.first {
    args.removeFirst()
    switch arg {
    case "--sniff":
        sniffOnly = true
    case "--hex":
        hexDump = true
    case "--no-seize":
        noSeize = true
    case "--bt":
        matchBT = true
    case "--probe-leds":
        probeLEDs = true
    case "--save":
        if let path = args.first {
            args.removeFirst()
            fixtureDir = URL(fileURLWithPath: path, isDirectory: true)
        }
    case "--help", "-h":
        print("""
        intuos-cli — PTK-540WL USB driver / sniffer (arm64)

          --sniff       Log only; do not inject CGEvents or hotkeys
          --hex         Hex-dump every HID report
          --probe-leds  Test and probe LED & OLED report IDs on the device
          --save DIR    Append JSONL fixtures under DIR
          --no-seize    Do not seize HID device (allows OS double-drive)
          --bt          Also match Bluetooth PID on IOHIDManager (best-effort)
          --help        This text
        """)
        exit(0)
    default:
        print("Unknown argument: \(arg) (try --help)")
        exit(2)
    }
}

let defaultFixtures = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Fixtures/usb", isDirectory: true)

print("=======================================================")
print("  Wacom Intuos4 Wireless (PTK-540WL) — native arm64")
print("=======================================================")

let handler = DriverCLIHandler()
handler.enableEventSynthesis = !sniffOnly
handler.hexDump = hexDump
handler.probeLEDs = probeLEDs

let options = USBTransport.Options(
    seizeDevice: !noSeize,
    matchBluetoothPID: matchBT,
    fixtureDirectory: fixtureDir ?? (sniffOnly ? defaultFixtures : fixtureDir)
)
let transport = USBTransport(options: options)
transport.delegate = handler
transport.start()

// Graceful shutdown: closing the seized device before exit is mandatory,
// otherwise the tablet wedges until it is power-cycled.
func cleanShutdown(_ sig: Int32) {
    print("\nShutting down (closing device cleanly)…")
    fflush(stdout)
    transport.stop()
    exit(0)
}
signal(SIGINT, cleanShutdown)
signal(SIGTERM, cleanShutdown)
signal(SIGHUP, cleanShutdown)

if let path = transport.fixturePath {
    print("Recording fixtures → \(path)")
}
print("Listening for USB PTK-540WL (VID 056A / PID 00B9)… Ctrl+C to exit")
RunLoop.main.run()
