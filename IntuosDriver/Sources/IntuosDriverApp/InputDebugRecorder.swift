import Foundation
import AppKit
import CoreGraphics
import Carbon.HIToolbox
import IntuosDriverCore

/// Passive recorder. It never consumes, changes, or posts an input event.
/// Lifecycle and recording calls run on the driver's main run loop.
final class InputDebugRecorder {
    static let shared = InputDebugRecorder()
    struct Entry: Codable, Sendable {
        let timestamp: TimeInterval
        let kind: String
        let fields: [String: String]
    }
    private(set) var isEnabled = false
    var onStatus: ((String) -> Void)?
    var onSaved: ((URL) -> Void)?
    var stateProvider: (() -> [String: String])?
    let directory: URL

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/IntuosDriver/diagnostics", isDirectory: true)) {
        self.directory = directory
    }
    private var entries: [Entry] = []
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var stateTimer: Timer?
    private var appObserver: NSObjectProtocol?
    private var gesture = ControlIncidentGesture()
    private var pendingSave: DispatchWorkItem?
    private var lastState = ""
    private var lastSamples: [String: TimeInterval] = [:]
    private var lastPenButtons = ""
    private var lastPad = ""
    private var receivedKeyboard = false
    private let writer = DispatchQueue(label: "com.trifa.intuosdriver.diagnostics")

    func start() {
        guard !isEnabled else { return }
        isEnabled = true
        entries.removeAll(keepingCapacity: true)
        lastSamples.removeAll()
        lastState = ""
        lastPenButtons = ""
        lastPad = ""
        gesture = ControlIncidentGesture()
        receivedKeyboard = false
        record("started", ["os": ProcessInfo.processInfo.operatingSystemVersionString,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "pid": String(ProcessInfo.processInfo.processIdentifier),
            "listenAccess": String(CGPreflightListenEventAccess()),
            "profile": AppProfileManager.shared.activeProfile.name])
        recordActiveApp()
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp, .mouseMoved,
            .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown,
            .rightMouseUp, .rightMouseDragged, .tabletPointer, .tabletProximity]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let recorder = Unmanaged<InputDebugRecorder>.fromOpaque(context).takeUnretainedValue()
            recorder.observe(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
            options: .listenOnly, eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let tap {
            tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            if let tapSource { CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes) }
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        onStatus?("Recording pen input; waiting for Control key observation")
        if tap == nil { onStatus?("Pen recording active; enable Input Monitoring for the Control marker") }
        stateTimer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.recordSystemState() }
        if let stateTimer { RunLoop.main.add(stateTimer, forMode: .common) }
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.recordActiveApp() }
        recordSystemState()
    }

    func stop() {
        guard isEnabled else { return }
        if pendingSave != nil {
            pendingSave?.cancel()
            pendingSave = nil
            writeSnapshot()
        }
        isEnabled = false
        stateTimer?.invalidate()
        stateTimer = nil
        if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }
        appObserver = nil
        if let tap { CFMachPortInvalidate(tap) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
        entries.removeAll()
        onStatus?("Debug recording off")
    }

    func record(_ kind: String, _ fields: [String: String] = [:]) {
        guard isEnabled else { return }
        let now = Date().timeIntervalSince1970
        entries.append(Entry(timestamp: now, kind: kind, fields: fields))
        if let first = entries.first, now - first.timestamp > 60 {
            entries.removeAll { now - $0.timestamp > 60 }
        }
        if entries.count > 12000 { entries.removeFirst(entries.count - 12000) }
    }

    func recordPen(_ pen: PenEvent) {
        guard isEnabled else { return }
        let buttons = "\(pen.isTipDown),\(pen.isBarrel1),\(pen.isBarrel2),\(pen.isHovering)"
        let changed = buttons != lastPenButtons
        lastPenButtons = buttons
        guard changed || shouldSample("pen") else { return }
        record("penInput", ["tip": String(pen.isTipDown), "barrel1": String(pen.isBarrel1),
            "barrel2": String(pen.isBarrel2), "hover": String(pen.isHovering),
            "pressure": String(pen.rawPressure), "eraser": String(pen.isEraser)])
    }

    func recordPad(_ pad: PadEvent) {
        guard isEnabled else { return }
        let state = pad.keys.map { $0 ? "1" : "0" }.joined() + ":\(pad.ringTouched):\(pad.ringPosition):\(pad.mode):\(pad.centerButton)"
        guard state != lastPad else { return }
        lastPad = state
        record("padInput", ["state": state])
    }

    func recordEvent(_ event: CGEvent, kind: String) {
        guard isEnabled else { return }
        if [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .tabletPointer].contains(event.type),
           !shouldSample("\(kind)-\(event.type.rawValue)") { return }
        var fields: [String: String] = ["type": String(event.type.rawValue), "flags": String(event.flags.rawValue),
            "sourcePID": String(event.getIntegerValueField(.eventSourceUnixProcessID)),
            "sourceState": String(event.getIntegerValueField(.eventSourceStateID)),
            "targetPID": String(event.getIntegerValueField(.eventTargetUnixProcessID)),
            "buttons": String(event.getIntegerValueField(.tabletEventPointButtons)),
            "clickCount": String(event.getIntegerValueField(.mouseEventClickState)),
            "pressure": String(event.getDoubleValueField(.tabletEventPointPressure)),
            "proximity": String(event.getIntegerValueField(.tabletProximityEventEnterProximity))]
        fields["x"] = String(Double(event.location.x))
        fields["y"] = String(Double(event.location.y))
        fields["deltaX"] = String(event.getIntegerValueField(.mouseEventDeltaX))
        fields["deltaY"] = String(event.getIntegerValueField(.mouseEventDeltaY))
        record(kind, fields)
    }

    func markIncident(reason: String = "manual") {
        guard isEnabled, pendingSave == nil else { return }
        record("incidentMarker", ["reason": reason])
        recordSystemState(force: true)
        onStatus?("Incident marked; saving three seconds of follow-up…")
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingSave = nil
            self.writeSnapshot()
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func observe(type: CGEventType, event: CGEvent) {
        guard isEnabled else { return }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            record("observerDisabled", ["type": String(type.rawValue)])
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .flagsChanged || type == .keyDown || type == .keyUp {
            // Store only modifier transitions and Tab. Never record other keycodes or text.
            let allowed: Set<Int64> = [54, 55, 56, 58, 59, 60, 61, 62, 48]
            guard allowed.contains(code) else { return }
            if !receivedKeyboard {
                receivedKeyboard = true
                onStatus?("Recording keyboard and pen; tap Control four times to mark an incident")
            }
            record("keyboardObserved", ["type": String(type.rawValue), "keyCode": String(code),
                "flags": String(event.flags.rawValue),
                "sourcePID": String(event.getIntegerValueField(.eventSourceUnixProcessID))])
            if type == .flagsChanged, (code == 59 || code == 62),
               event.getIntegerValueField(.eventSourceUnixProcessID) != Int64(ProcessInfo.processInfo.processIdentifier),
               gesture.transition(isDown: event.flags.contains(.maskControl), at: ProcessInfo.processInfo.systemUptime) {
                markIncident(reason: "fourControlTaps")
            }
        } else {
            recordEvent(event, kind: "eventObserved")
        }
    }

    private func shouldSample(_ lane: String) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - (lastSamples[lane] ?? -.infinity) >= 0.2 else { return false }
        lastSamples[lane] = now
        return true
    }

    private func recordActiveApp() {
        let app = NSWorkspace.shared.frontmostApplication
        record("applicationActivated", ["bundleID": app?.bundleIdentifier ?? "unknown",
            "pid": String(app?.processIdentifier ?? 0)])
    }

    private func recordSystemState(force: Bool = false) {
        var fields = ["hidFlags": String(CGEventSource.flagsState(.hidSystemState).rawValue),
            "sessionFlags": String(CGEventSource.flagsState(.combinedSessionState).rawValue),
            "commandLeft": String(CGEventSource.keyState(.hidSystemState, key: 55)),
            "commandRight": String(CGEventSource.keyState(.hidSystemState, key: 54)),
            "controlLeft": String(CGEventSource.keyState(.hidSystemState, key: 59)),
            "controlRight": String(CGEventSource.keyState(.hidSystemState, key: 62)),
            "tab": String(CGEventSource.keyState(.hidSystemState, key: 48)),
            "optionLeft": String(CGEventSource.keyState(.hidSystemState, key: 58)),
            "optionRight": String(CGEventSource.keyState(.hidSystemState, key: 61)),
            "leftMouse": String(CGEventSource.buttonState(.combinedSessionState, button: .left)),
            "rightMouse": String(CGEventSource.buttonState(.combinedSessionState, button: .right))]
        fields.merge(stateProvider?() ?? [:]) { _, new in new }
        let state = fields.keys.sorted().map { "\($0)=\(fields[$0]!)" }.joined(separator: ";")
        guard force || state != lastState else { return }
        lastState = state
        record("systemState", fields)
    }

    private func writeSnapshot() {
        record("snapshotEnd", ["keyboardObserved": String(receivedKeyboard),
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "pid": String(ProcessInfo.processInfo.processIdentifier),
            "profile": AppProfileManager.shared.activeProfile.name,
            "bundleID": Bundle.main.bundleIdentifier ?? "unknown",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"])
        recordActiveApp()
        recordSystemState(force: true)
        let snapshot = entries
        let url = directory.appendingPathComponent("incident-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8)).jsonl")
        let directory = self.directory
        writer.async { [weak self] in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                var data = Data()
                for entry in snapshot {
                    data.append(try encoder.encode(entry))
                    data.append(0x0a)
                }
                try data.write(to: url, options: .atomic)
                let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    .filter { $0.lastPathComponent.hasPrefix("incident-") && $0.pathExtension == "jsonl" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                for old in files.dropLast(20) { try FileManager.default.removeItem(at: old) }
                DispatchQueue.main.async {
                    self?.onStatus?("Saved \(url.lastPathComponent)")
                    self?.onSaved?(url)
                }
            } catch {
                DispatchQueue.main.async { self?.onStatus?("Could not save incident: \(error.localizedDescription)") }
            }
        }
    }
}
