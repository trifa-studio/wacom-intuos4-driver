import Foundation
import IOKit
import IOKit.hid

public protocol USBTransportDelegate: AnyObject, Sendable {
    func transportDidConnect(device: IOHIDDevice)
    func transportDidDisconnect(device: IOHIDDevice)
    func transportDidReceiveReport(reportID: UInt8, bytes: UnsafeRawBufferPointer)
    func transportDidFail(message: String)
}

public extension USBTransportDelegate {
    func transportDidFail(message: String) {}
}

public final class USBTransport: @unchecked Sendable {
    public struct Options: Sendable {
        /// Seize the HID device so the system generic mouse driver does not double-drive the cursor.
        public var seizeDevice: Bool
        /// Match Bluetooth PID on IOHIDManager (BT Classic still needs L2CAP later; HID path is best-effort).
        public var matchBluetoothPID: Bool
        /// Optional JSONL capture directory.
        public var fixtureDirectory: URL?

        public init(
            seizeDevice: Bool = true,
            matchBluetoothPID: Bool = false,
            fixtureDirectory: URL? = nil
        ) {
            self.seizeDevice = seizeDevice
            self.matchBluetoothPID = matchBluetoothPID
            self.fixtureDirectory = fixtureDirectory
        }
    }

    private var manager: IOHIDManager?
    private var activeDevice: IOHIDDevice?
    private let queue = DispatchQueue(label: "com.intuos.transport.hid", qos: .userInteractive)
    /// Stable buffer for the lifetime of the transport — IOHID keeps this pointer
    /// across callback invocations, so it must never be reallocated.
    private let reportBuffer: UnsafeMutablePointer<UInt8> = {
        let p = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        p.initialize(repeating: 0, count: 4096)
        return p
    }()
    private var options: Options
    private var recorder: FixtureRecorder?
    private var openedWithSeize = false

    public weak var delegate: USBTransportDelegate?

    public init(options: Options = Options()) {
        self.options = options
        if let dir = options.fixtureDirectory {
            recorder = try? FixtureRecorder(directory: dir)
        }
    }

    public func start() {
        // IOHID device scheduling + callback registration must happen on the same
        // thread whose runloop delivers events (main). Doing this from a dispatch
        // queue silently drops all input reports on macOS 26.
        if Thread.isMainThread {
            setupManager()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.setupManager()
            }
        }
    }

    /// Synchronous teardown on the caller's thread (the main thread that scheduled
    /// everything). Must be called before process exit — killing a seized device
    /// open without closing wedges the tablet until it is power-cycled.
    public func stop() {
        if let device = activeDevice {
            // Hand the tablet back to the system mouse driver before closing,
            // otherwise it stays in digitizer mode until power-cycled.
            _ = WacomModeSwitch.restoreMouseMode(device: device)
            IOHIDDeviceUnscheduleFromRunLoop(
                device,
                CFRunLoopGetMain(),
                CFRunLoopMode.commonModes.rawValue
            )
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            activeDevice = nil
            delegate?.transportDidDisconnect(device: device)
        }
        if let manager = manager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            self.manager = nil
        }
        recorder?.close()
    }

    /// Re-send mode switch to the active device (e.g. after wake).
    public func reapplyModeSwitch() {
        queue.async { [weak self] in
            guard let self, let device = self.activeDevice else { return }
            _ = WacomModeSwitch.enableDigitizerMode(device: device)
        }
    }

    public var isConnected: Bool {
        activeDevice != nil
    }

    public var fixturePath: String? {
        recorder?.path
    }

    /// Write a feature report to the active device (OLED / LED / mode switch).
    @discardableResult
    public func sendFeatureReport(reportID: UInt8, payload: [UInt8]) -> Bool {
        guard let device = activeDevice else { return false }
        var buffer = [reportID] + payload
        let result = IOHIDDeviceSetReport(
            device,
            kIOHIDReportTypeFeature,
            CFIndex(reportID),
            &buffer,
            buffer.count
        )
        return result == kIOReturnSuccess
    }

    /// Write an output/feature report to the active device.
    @discardableResult
    public func sendOutputReport(reportID: UInt8, payload: [UInt8]) -> Bool {
        guard let device = activeDevice else { return false }
        var buffer = [reportID] + payload
        let result = IOHIDDeviceSetReport(
            device,
            kIOHIDReportTypeOutput,
            CFIndex(reportID),
            &buffer,
            buffer.count
        )
        if result != kIOReturnSuccess {
            return sendFeatureReport(reportID: reportID, payload: payload)
        }
        return true
    }

    private func setupManager() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        var matchArray: [[String: Any]] = WacomConstants.usbProductIDs.map { pid in
            [
                kIOHIDVendorIDKey as String: WacomConstants.vendorID,
                kIOHIDProductIDKey as String: pid
            ]
        }
        if options.matchBluetoothPID {
            matchArray.append([
                kIOHIDVendorIDKey as String: WacomConstants.vendorID,
                kIOHIDProductIDKey as String: WacomConstants.bluetoothProductID
            ])
        }

        IOHIDManagerSetDeviceMatchingMultiple(manager, matchArray as CFArray)

        let matchingCallback: IOHIDDeviceCallback = { context, result, sender, device in
            guard let context else { return }
            let transport = Unmanaged<USBTransport>.fromOpaque(context).takeUnretainedValue()
            transport.handleDeviceAttached(device: device)
        }

        let removalCallback: IOHIDDeviceCallback = { context, result, sender, device in
            guard let context else { return }
            let transport = Unmanaged<USBTransport>.fromOpaque(context).takeUnretainedValue()
            transport.handleDeviceRemoved(device: device)
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, matchingCallback, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, removalCallback, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        // NOTE: Do NOT call IOHIDManagerOpen here. Opening the manager implicitly
        // opens matched devices non-exclusively and our subsequent
        // IOHIDDeviceOpen(.seizeDevice) then delivers no input reports on macOS 26.
        // Enumeration below + per-device opens are sufficient (verified on hardware).

        // Attach already-connected devices
        if let copy = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            for device in copy {
                handleDeviceAttached(device: device)
            }
        }
    }

    private func handleDeviceAttached(device: IOHIDDevice) {
        // If a previous device handle was active (e.g. tablet was power cycled and got a new IOHIDDevice handle),
        // cleanly tear down the stale handle so it doesn't block the new device.
        if let oldDevice = activeDevice {
            if oldDevice == device && openedWithSeize {
                // Device already attached and opened
                return
            }
            IOHIDDeviceUnscheduleFromRunLoop(oldDevice, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDDeviceClose(oldDevice, IOOptionBits(kIOHIDOptionsTypeNone))
            activeDevice = nil
        }

        let seize = options.seizeDevice
        let openOptions = seize
            ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
            : IOOptionBits(kIOHIDOptionsTypeNone)

        var openResult = IOHIDDeviceOpen(device, openOptions)
        if openResult != kIOReturnSuccess && seize {
            // Fall back without seize (permissions / already open)
            openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            openedWithSeize = false
            if openResult != kIOReturnSuccess {
                delegate?.transportDidFail(message: "IOHIDDeviceOpen failed: \(openResult)")
                return
            }
            delegate?.transportDidFail(message: "Opened without seize; system may also drive the cursor")
        } else if openResult != kIOReturnSuccess {
            delegate?.transportDidFail(message: "IOHIDDeviceOpen failed: \(openResult)")
            return
        } else {
            openedWithSeize = seize
        }

        activeDevice = device

        // Cold power-on requires multiple staged mode switches as the tablet's
        // microcontroller initializes its USB/Bluetooth HID command processor.
        _ = WacomModeSwitch.enableDigitizerMode(device: device)
        queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.activeDevice == device else { return }
            _ = WacomModeSwitch.enableDigitizerMode(device: device)
        }
        queue.asyncAfter(deadline: .now() + 0.40) { [weak self] in
            guard let self, self.activeDevice == device else { return }
            _ = WacomModeSwitch.enableDigitizerMode(device: device)
        }

        let reportCallback: IOHIDReportCallback = { context, result, sender, type, reportID, report, reportLength in
            guard let context, result == kIOReturnSuccess, reportLength > 0 else { return }
            let transport = Unmanaged<USBTransport>.fromOpaque(context).takeUnretainedValue()
            let buffer = UnsafeRawBufferPointer(start: report, count: reportLength)
            let rid = UInt8(truncatingIfNeeded: reportID)
            if let recorder = transport.recorder {
                recorder.record(reportID: rid, bytes: Array(buffer))
            }
            transport.delegate?.transportDidReceiveReport(reportID: rid, bytes: buffer)
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device,
            reportBuffer,
            4096,
            reportCallback,
            context
        )
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        delegate?.transportDidConnect(device: device)
    }

    private func handleDeviceRemoved(device: IOHIDDevice) {
        if activeDevice == device {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            activeDevice = nil
        }
        delegate?.transportDidDisconnect(device: device)
    }
}
