import Foundation
import IOBluetooth

public protocol BluetoothTransportDelegate: AnyObject, Sendable {
    func bluetoothTransportDidConnect(device: IOBluetoothDevice)
    func bluetoothTransportDidDisconnect(device: IOBluetoothDevice)
    func bluetoothTransportDidFail(message: String)
    func bluetoothTransportDidReceiveReport(reportID: UInt8, bytes: UnsafeRawBufferPointer)
}

/// Native macOS Bluetooth Classic (L2CAP / RFCOMM) transport for Wacom Intuos4 Wireless (PTK-540WL).
/// Directly mirrors the official Wacom driver's OMacBTDevice and CPTKWLGraphicsTablet architecture.
public final class BluetoothTransport: NSObject, IOBluetoothL2CAPChannelDelegate, IOBluetoothRFCOMMChannelDelegate, @unchecked Sendable {

    public weak var delegate: BluetoothTransportDelegate?

    public private(set) var isConnected: Bool = false
    public private(set) var activeDevice: IOBluetoothDevice?
    public private(set) var connectedDeviceName: String = ""

    private var controlChannel: IOBluetoothL2CAPChannel?
    private var interruptChannel: IOBluetoothL2CAPChannel?
    private var rfcommChannel: IOBluetoothRFCOMMChannel?

    private var reconnectTimer: Timer?
    private var isRunning: Bool = false

    public override init() {
        super.init()
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        connectToPairedTablet()
        startPeriodicCheck()
    }

    public func stop() {
        isRunning = false
        stopPeriodicCheck()
        disconnect()
    }

    private func startPeriodicCheck() {
        DispatchQueue.main.async { [weak self] in
            self?.reconnectTimer?.invalidate()
            self?.reconnectTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                guard let self, self.isRunning, !self.isConnected else { return }
                self.connectToPairedTablet()
            }
        }
    }

    private func stopPeriodicCheck() {
        DispatchQueue.main.async { [weak self] in
            self?.reconnectTimer?.invalidate()
            self?.reconnectTimer = nil
        }
    }

    /// Finds paired PTK-540WL / Wacom tablets and initiates L2CAP / RFCOMM connections.
    public func connectToPairedTablet() {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return }

        for device in paired {
            guard let name = device.nameOrAddress else { continue }
            let lower = name.lowercased()
            if lower.contains("ptk-540") || lower.contains("intuos4") || lower.contains("wacom") {
                connect(to: device)
                return
            }
        }
    }

    public func connect(to device: IOBluetoothDevice) {
        guard !isConnected else { return }
        self.activeDevice = device
        self.connectedDeviceName = device.nameOrAddress ?? "Wacom Tablet"

        // Open device connection if not yet connected
        if !device.isConnected() {
            let res = device.openConnection()
            if res != kIOReturnSuccess {
                delegate?.bluetoothTransportDidFail(message: "Failed to open Bluetooth connection: 0x\(String(res, radix: 16))")
                return
            }
        }

        // Open HID Interrupt Channel (PSM 0x0013)
        var intChannel: IOBluetoothL2CAPChannel?
        let intRes = device.openL2CAPChannelSync(&intChannel, withPSM: BluetoothL2CAPPSM(kBluetoothL2CAPPSMHIDInterrupt), delegate: self)
        if intRes == kIOReturnSuccess, let intChannel {
            self.interruptChannel = intChannel
        }

        // Open HID Control Channel (PSM 0x0011)
        var ctrlChannel: IOBluetoothL2CAPChannel?
        let ctrlRes = device.openL2CAPChannelSync(&ctrlChannel, withPSM: BluetoothL2CAPPSM(kBluetoothL2CAPPSMHIDControl), delegate: self)
        if ctrlRes == kIOReturnSuccess, let ctrlChannel {
            self.controlChannel = ctrlChannel
        }

        if interruptChannel != nil || controlChannel != nil {
            self.isConnected = true
            delegate?.bluetoothTransportDidConnect(device: device)
            sendBluetoothModeSwitch()
        } else {
            // Fallback: try opening RFCOMM channel 1
            var rfChannel: IOBluetoothRFCOMMChannel?
            let rfRes = device.openRFCOMMChannelSync(&rfChannel, withChannelID: 1, delegate: self)
            if rfRes == kIOReturnSuccess, let rfChannel {
                self.rfcommChannel = rfChannel
                self.isConnected = true
                delegate?.bluetoothTransportDidConnect(device: device)
                sendBluetoothModeSwitch()
            } else {
                delegate?.bluetoothTransportDidFail(message: "Could not open Bluetooth L2CAP/RFCOMM channels")
            }
        }
    }

    public func disconnect() {
        controlChannel?.close()
        controlChannel = nil
        interruptChannel?.close()
        interruptChannel = nil
        _ = rfcommChannel?.close()
        rfcommChannel = nil

        if let dev = activeDevice {
            if isConnected {
                isConnected = false
                delegate?.bluetoothTransportDidDisconnect(device: dev)
            }
            dev.closeConnection()
        }
        activeDevice = nil
    }

    /// Sends the official Wacom Intuos4 Wireless Bluetooth initialization report (Report 0x03).
    /// Unlocks raw 200 Hz digitizer streaming and high-res pen/pad coordinates over Bluetooth.
    public func sendBluetoothModeSwitch() {
        // Report 0x03 with SetHidModeWacom(true), SetScanRateFast(true), SetPenScanMode(true)
        sendFeatureReport(reportID: 0x03, payload: [0x01, 0x01, 0x01])

        // Ensure LED State and OLED brightness are active
        let ledPayload: [UInt8] = [0x40, 127, 127, 0x3F, 0, 0, 0, 0]
        sendFeatureReport(reportID: 0x20, payload: ledPayload)
    }

    @discardableResult
    public func sendFeatureReport(reportID: UInt8, payload: [UInt8]) -> Bool {
        var buffer: [UInt8] = [0x53, reportID] + payload // 0x53 = HID SET_REPORT (Feature)
        if let ctrl = controlChannel {
            let res = ctrl.writeSync(&buffer, length: UInt16(buffer.count))
            return res == kIOReturnSuccess
        } else if let rf = rfcommChannel {
            var raw = [reportID] + payload
            let res = rf.writeSync(&raw, length: UInt16(raw.count))
            return res == kIOReturnSuccess
        }
        return false
    }

    // MARK: - IOBluetoothL2CAPChannelDelegate

    public func l2capChannelData(_ l2capChannel: IOBluetoothL2CAPChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        guard dataLength > 0, let dataPointer else { return }
        let bytes = UnsafeRawBufferPointer(start: dataPointer, count: dataLength)

        // Bluetooth HID packets usually have a 1-byte HID header (e.g. 0xA1 for DATA input)
        if bytes[0] == 0xA1 && dataLength > 1 {
            let reportBytes = UnsafeRawBufferPointer(start: dataPointer.advanced(by: 1), count: dataLength - 1)
            let reportID = reportBytes[0]
            delegate?.bluetoothTransportDidReceiveReport(reportID: reportID, bytes: reportBytes)
        } else {
            let reportID = bytes[0]
            delegate?.bluetoothTransportDidReceiveReport(reportID: reportID, bytes: bytes)
        }
    }

    public func l2capChannelClosed(_ l2capChannel: IOBluetoothL2CAPChannel!) {
        if let dev = activeDevice, isConnected {
            isConnected = false
            delegate?.bluetoothTransportDidDisconnect(device: dev)
        }
    }

    // MARK: - IOBluetoothRFCOMMChannelDelegate

    public func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        guard dataLength > 0, let dataPointer else { return }
        let bytes = UnsafeRawBufferPointer(start: dataPointer, count: dataLength)
        let reportID = bytes[0]
        delegate?.bluetoothTransportDidReceiveReport(reportID: reportID, bytes: bytes)
    }

    public func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        if let dev = activeDevice, isConnected {
            isConnected = false
            delegate?.bluetoothTransportDidDisconnect(device: dev)
        }
    }
}
