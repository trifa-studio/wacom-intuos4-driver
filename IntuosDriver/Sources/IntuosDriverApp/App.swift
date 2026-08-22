import SwiftUI
import AppKit
import Combine
import ServiceManagement
import IOKit.hid
import IOBluetooth
import IntuosDriverCore

// MARK: - Settings persistence

enum DriverSettings {
    static let smoothingKey = "smoothing"          // 0...1, 0 = off
    static let gammaKey = "pressureGamma"          // 0.3...3.0
    static let deadZoneKey = "pressureDeadZone"    // 0...0.2
    static let mappingKey = "mappingMode"          // "main" | "desktop"
    static let stretchKey = "preserveAspectRatio"  // bool

    @MainActor
    static func save(_ model: AppDriverModel) {
        let d = UserDefaults.standard
        d.set(model.smoothing, forKey: smoothingKey)
        d.set(model.pressureGamma, forKey: gammaKey)
        d.set(model.deadZone, forKey: deadZoneKey)
        d.set(model.useFullDesktop ? "desktop" : "main", forKey: mappingKey)
        d.set(model.preserveAspectRatio, forKey: stretchKey)
    }
}

// MARK: - Model

@MainActor
final class AppDriverModel: ObservableObject, USBTransportDelegate, @unchecked Sendable {
    @Published var isConnected: Bool = false
    @Published var batteryLevel: Int = -1
    @Published var isCharging: Bool = false
    @Published var hasAccessibility: Bool = false
    @Published var lastStatus: String = "Starting…"
    @Published var seizeWarning: String?
    /// Set when Accessibility was granted mid-session: the running process is
    /// still denied CGEvent posting until it relaunches.
    @Published var needsRestart: Bool = false

    // Settings — initialised straight from UserDefaults in init() so there is
    // no publish storm while SwiftUI mounts the menu bar host.
    @Published var smoothing: Double { didSet { settingsChanged() } }
    @Published var pressureGamma: Double { didSet { settingsChanged() } }
    @Published var deadZone: Double { didSet { settingsChanged() } }
    @Published var useFullDesktop: Bool { didSet { settingsChanged() } }
    @Published var preserveAspectRatio: Bool { didSet { settingsChanged() } }
    @Published var ledBrightness: Double { didSet { ledBrightnessChanged() } }
    @Published var currentRingMode: UInt8 = 0
    @Published var isLeftHanded: Bool { didSet { settingsChanged(); updateOrientation() } }
    @Published var isPrecisionMode: Bool = false { didSet { applySettings() } }
    @Published var activeProfileName: String = "General / Desktop"
    @Published var autoSwitchProfiles: Bool = true {
        didSet {
            AppProfileManager.shared.isAutoSwitchEnabled = autoSwitchProfiles
        }
    }
    @Published var showHUDOverlays: Bool {
        didSet {
            UserDefaults.standard.set(showHUDOverlays, forKey: "showHUDOverlays")
        }
    }
    @Published var showProfileHUD: Bool {
        didSet {
            UserDefaults.standard.set(showProfileHUD, forKey: "showProfileHUD")
        }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            toggleLaunchAtLogin(launchAtLogin)
        }
    }

    private let transport: USBTransport
    private let decoder = WacomPacketDecoder()
    let synthesizer = TabletEventSynthesizer()
    let oledController: OLEDController
    private let keyManager = ExpressKeyManager()
    private let ringManager = TouchRingManager()
    private var tccTimer: Timer?
    private var didInitialPermissionCheck = false

    /// Lightweight file log — survives even when the UI fails to render.
    nonisolated static func log(_ message: String) {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/IntuosDriver", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let line = "\(Date()) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: dir.appendingPathComponent("driver.log")) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            try? line.data(using: .utf8)!.write(to: dir.appendingPathComponent("driver.log"))
        }
    }

    init() {
        let d = UserDefaults.standard
        _smoothing = Published(initialValue: d.object(forKey: DriverSettings.smoothingKey) as? Double ?? 0.55)
        _pressureGamma = Published(initialValue: d.object(forKey: DriverSettings.gammaKey) as? Double ?? 1.0)
        _deadZone = Published(initialValue: d.object(forKey: DriverSettings.deadZoneKey) as? Double ?? 0.01)
        _useFullDesktop = Published(initialValue: (d.string(forKey: DriverSettings.mappingKey) ?? "main") == "desktop")
        _preserveAspectRatio = Published(initialValue: d.object(forKey: DriverSettings.stretchKey) as? Bool ?? false)
        _ledBrightness = Published(initialValue: d.object(forKey: "ledBrightness") as? Double ?? 15.0)
        _isLeftHanded = Published(initialValue: d.bool(forKey: "isLeftHanded"))
        _showHUDOverlays = Published(initialValue: d.object(forKey: "showHUDOverlays") as? Bool ?? true)
        _showProfileHUD = Published(initialValue: d.object(forKey: "showProfileHUD") as? Bool ?? false)
        _launchAtLogin = Published(initialValue: SMAppService.mainApp.status == .enabled)

        let fixtures = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/IntuosDriver/usb", isDirectory: true)
        let tr = USBTransport(options: USBTransport.Options(
            seizeDevice: true,
            matchBluetoothPID: true,
            fixtureDirectory: fixtures
        ))
        self.transport = tr
        self.oledController = OLEDController(transport: tr)

        checkPermissions()
        Self.log("app starting; accessibility=\(hasAccessibility) smoothing=\(smoothing) gamma=\(pressureGamma)")
        applySettings()

        keyManager.listener = self
        keyManager.onRadialMenuTrigger = {
            RadialMenuController.shared.toggle()
        }
        keyManager.onDisplayToggleTrigger = { [weak self] in
            guard let self else { return }
            let name = DisplayToggleManager.shared.cycleNextDisplay(synthesizer: self.synthesizer)
            HUDOverlayController.shared.show(title: "Display Toggle", subtitle: name, iconName: "display.2")
        }
        keyManager.onPrecisionModeTrigger = { [weak self] in
            guard let self else { return }
            let active = DisplayToggleManager.shared.togglePrecisionMode(synthesizer: self.synthesizer)
            Task { @MainActor in
                self.isPrecisionMode = active
            }
            HUDOverlayController.shared.show(
                title: "Precision Mode",
                subtitle: active ? "Active (2x Detail Zoom)" : "Standard 1:1 Mapping",
                iconName: active ? "viewfinder" : "rectangle.dashed"
            )
        }
        AppProfileManager.shared.listener = self

        transport.delegate = self
        transport.start()
        lastStatus = "Waiting for tablet (USB / Bluetooth)…"

        // Prompt for Accessibility once if missing (new bundle identity needs it).
        if !hasAccessibility {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.requestAccessibility()
            }
        }
    }

    private func toggleLaunchAtLogin(_ enable: Bool) {
        do {
            if enable {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            Self.log("LaunchAtLogin error: \(error)")
        }
    }

    func exportProfiles() {
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = "IntuosDriver-Profiles.json"
        savePanel.begin { result in
            if result == .OK, let url = savePanel.url {
                try? AppProfileManager.shared.exportProfiles(to: url)
                HUDOverlayController.shared.show(title: "Profiles Exported", subtitle: url.lastPathComponent, iconName: "square.and.arrow.up")
            }
        }
    }

    func importProfiles() {
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = false
        openPanel.begin { result in
            if result == .OK, let url = openPanel.url {
                try? AppProfileManager.shared.importProfiles(from: url)
                self.activeProfileName = AppProfileManager.shared.activeProfile.name
                HUDOverlayController.shared.show(title: "Profiles Imported", subtitle: url.lastPathComponent, iconName: "square.and.arrow.down")
            }
        }
    }

    private func settingsChanged() {
        applySettings()
        UserDefaults.standard.set(isLeftHanded, forKey: "isLeftHanded")
        DriverSettings.save(self)
    }

    public func updateOrientation() {
        let b = UInt8(ledBrightness)
        let labels = AppProfileManager.shared.activeProfile.oledLabels
        oledController.applyLabels(labels, ringMode: currentRingMode, brightness: b, isFlipped: isLeftHanded)
    }

    private func ledBrightnessChanged() {
        UserDefaults.standard.set(ledBrightness, forKey: "ledBrightness")
        let b = UInt8(ledBrightness)
        oledController.setRingLED(mode: currentRingMode, ringBrightness: b, oledBrightness: b)
    }

    /// Apply UI settings to the live driver objects.
    /// NOTE: must never assign back to @Published properties — didSet would
    /// recurse (Swift fires didSet even when the value is unchanged).
    func applySettings() {
        let s = max(0.0, min(0.9, smoothing))
        // Smoothing slider: 0% → no filtering (alpha 1.0), 100% → heavy (alpha ~0.12)
        synthesizer.smoothingAlpha = 1.0 - s * 0.95 + 0.07
        pressureCurveApply()
        synthesizer.coordinateTransformer.mode = useFullDesktop ? .fullDesktop : .mainDisplay
        synthesizer.coordinateTransformer.preserveAspectRatio = preserveAspectRatio
        synthesizer.coordinateTransformer.isOrientationFlipped = isLeftHanded
        synthesizer.coordinateTransformer.isPrecisionMode = isPrecisionMode
    }

    private func pressureCurveApply() {
        if abs(pressureGamma - 1.0) < 0.001 {
            synthesizer.pressureCurve.profile = .linear
        } else {
            synthesizer.pressureCurve.profile = .custom(gamma: pressureGamma)
        }
        synthesizer.pressureCurve.deadZoneThreshold = deadZone
    }

    func checkPermissions() {
        let trusted = TabletEventSynthesizer.isAccessibilityTrusted(promptIfNeeded: false)
        if didInitialPermissionCheck && trusted && !hasAccessibility {
            needsRestart = true
            lastStatus = "Accessibility granted — restart to activate pen input"
            Self.log("accessibility granted mid-session; restart required")
        }
        hasAccessibility = trusted
        didInitialPermissionCheck = true
        if trusted {
            stopPermissionPoll()
        } else {
            needsRestart = false
            startPermissionPoll()
        }
    }

    func requestAccessibility() {
        _ = TabletEventSynthesizer.isAccessibilityTrusted(promptIfNeeded: true)
        checkPermissions()
    }

    private func startPermissionPoll() {
        guard tccTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
            DispatchQueue.main.async { [weak self] in
                self?.checkPermissions()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tccTimer = timer
    }

    private func stopPermissionPoll() {
        tccTimer?.invalidate()
        tccTimer = nil
    }

    func prepareForExit() {
        transport.stop()
    }

    func restartApp() {
        Self.log("restarting app to activate TCC")
        transport.stop()
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/zsh")
        relaunch.arguments = ["-c", "sleep 1; open '\(Bundle.main.bundleURL.path)'"]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    nonisolated func transportDidConnect(device: IOHIDDevice) {
        let pidVal = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? WacomConstants.usbProductID
        let desc = WacomConstants.descriptor(for: pidVal)
        self.decoder.activeModel = desc
        Self.log("tablet connected: \(desc.modelName) (PID 0x\(String(pidVal, radix: 16)))")
        Task { @MainActor in
            self.isConnected = true
            self.lastStatus = desc.modelName
            self.checkPermissions()

            // Initialize Ring LED and update OLED key displays
            let b = UInt8(self.ledBrightness)
            self.oledController.setRingLED(mode: self.currentRingMode, ringBrightness: b, oledBrightness: b)
            if desc.hasOLED {
                let labels = AppProfileManager.shared.activeProfile.oledLabels
                self.oledController.applyLabels(labels, ringMode: self.currentRingMode, brightness: b, isFlipped: self.isLeftHanded)
            }

            HUDOverlayController.shared.show(title: desc.modelName, subtitle: "Connected & Ready", iconName: "checkmark.circle.fill")
        }
    }

    nonisolated func transportDidDisconnect(device: IOHIDDevice) {
        Self.log("tablet disconnected")
        Task { @MainActor in
            self.isConnected = false
            self.lastStatus = "Tablet disconnected"
            self.decoder.reset()
            self.synthesizer.handleToolOutOfProximity()
            HUDOverlayController.shared.show(title: "Wacom Intuos4", subtitle: "Disconnected", iconName: "xmark.circle")
        }
    }

    nonisolated func transportDidFail(message: String) {
        Self.log("transport FAIL: \(message)")
        Task { @MainActor in
            self.seizeWarning = message
            self.lastStatus = message
        }
    }

    nonisolated func transportDidReceiveReport(reportID: UInt8, bytes: UnsafeRawBufferPointer) {
        processIncomingReport(reportID: reportID, bytes: bytes)
    }

    private nonisolated func processIncomingReport(reportID: UInt8, bytes: UnsafeRawBufferPointer) {
        let packets = decoder.decode(reportID: reportID, buffer: bytes)
        for packet in packets {
            switch packet {
            case .pen(let pen):
                synthesizer.processPenEvent(pen)
            case .pad(let pad):
                keyManager.processPadEvent(pad)
                ringManager.processPadEvent(pad)
                Task { @MainActor in
                    if self.currentRingMode != pad.mode {
                        self.currentRingMode = pad.mode
                        let b = UInt8(self.ledBrightness)
                        self.oledController.setRingLED(mode: pad.mode, ringBrightness: b, oledBrightness: b)

                        let profile = AppProfileManager.shared.activeProfile
                        let ringTitles = profile.ringModeLabels
                        let ringIcons = ["arrow.up.and.down.circle", "square.2.layers.3d", "paintbrush.pointed", "rotate.right"]
                        let idx = Int(pad.mode) % ringTitles.count
                        HUDOverlayController.shared.show(title: "Touch Ring", subtitle: ringTitles[idx], iconName: ringIcons[idx])
                    }
                }
            case .battery(let bat):
                Task { @MainActor in
                    self.batteryLevel = bat.percentage
                    self.isCharging = bat.isCharging
                }
            case .toolProximity(let toolID, _, let isEraser):
                synthesizer.handleToolProximity(toolID: toolID, isEraser: isEraser)
            case .toolOutOfProximity:
                synthesizer.handleToolOutOfProximity()
            case .unknown:
                break
            }
        }
    }
}

// MARK: - AppProfileListener

extension AppDriverModel: AppProfileListener {
    public nonisolated func appProfileDidChange(profile: AppProfile) {
        Task { @MainActor in
            self.activeProfileName = profile.name
            self.pressureGamma = profile.pressureGamma
            self.smoothing = profile.smoothing
            let b = UInt8(self.ledBrightness)
            if self.decoder.activeModel.hasOLED {
                self.oledController.applyLabels(profile.oledLabels, ringMode: self.currentRingMode, brightness: b, isFlipped: self.isLeftHanded)
            }
            if self.showProfileHUD && self.showHUDOverlays {
                HUDOverlayController.shared.show(title: "Active Profile", subtitle: profile.name, iconName: "macbook.and.ipad")
            }
        }
    }
}

// MARK: - ExpressKeyListener

extension AppDriverModel: ExpressKeyListener {
    public nonisolated func expressKeyDidTrigger(index: Int, action: KeyAction, label: String) {
        switch action {
        case .radialMenu:
            break
        default:
            Task { @MainActor in
                if self.showHUDOverlays {
                    HUDOverlayController.shared.show(title: "ExpressKey \(index + 1)", subtitle: label, iconName: "hand.tap")
                }
            }
        }
    }
}

// MARK: - Pressure curve preview

struct CurvePreview: View {
    let gamma: Double
    let deadZone: Double

    var path: Path {
        var p = Path()
        let steps = 60
        let curve = PressureCurve(profile: abs(gamma - 1.0) < 0.001 ? .linear : .custom(gamma: gamma),
                                  deadZoneThreshold: deadZone)
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let y = curve.evaluate(rawNormalized: t)
            let point = CGPoint(x: CGFloat(t), y: CGFloat(1 - y))
            if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
        }
        return p
    }

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width - 8)
            let h = max(1, geo.size.height - 8)
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
                    )
                path
                    .transform(CGAffineTransform(scaleX: w, y: h))
                    .offset(x: 4, y: 4)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                Text("output ↑ / input →")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(6)
            }
        }
        .frame(height: 100)
    }
}

// MARK: - Pressure test pad

class TestPadNSView: NSView {
    var segments: [(NSPoint, NSPoint, CGFloat)] = []
    var onPressure: ((Double) -> Void)?

    override func mouseDown(with event: NSEvent) { handle(event) }
    override func mouseDragged(with event: NSEvent) { handle(event) }
    override func mouseUp(with event: NSEvent) { handle(event); lastPoint = nil }
    override var acceptsFirstResponder: Bool { true }

    private var lastPoint: NSPoint?

    private func handle(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.contains(p) else {
            lastPoint = nil
            return
        }
        guard event.pressure > 0.01, let from = lastPoint else { lastPoint = p; return }
        segments.append((from, p, max(1, CGFloat(event.pressure) * 24)))
        needsDisplay = true
        lastPoint = p
        onPressure?(Double(event.pressure))
    }

    func clear() {
        segments.removeAll()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.clip(to: bounds)

        NSColor.controlBackgroundColor.setFill()
        bounds.fill()

        NSColor.labelColor.setStroke()
        for seg in segments {
            let path = NSBezierPath()
            path.lineWidth = seg.2
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: seg.0)
            path.line(to: seg.1)
            path.stroke()
        }
        ctx.restoreGState()
    }
}

struct PressureTestPad: NSViewRepresentable {
    @Binding var livePressure: Double
    let holder: PadHolder

    final class PadHolder: ObservableObject {
        weak var view: TestPadNSView?
    }

    func makeNSView(context: Context) -> TestPadNSView {
        let v = TestPadNSView()
        v.onPressure = { p in Task { @MainActor in livePressure = Double(p) } }
        holder.view = v
        return v
    }
    func updateNSView(_ nsView: TestPadNSView, context: Context) {}
}

// MARK: - Panel view

struct PanelView: View {
    @ObservedObject var model: AppDriverModel
    @State private var livePressure: Double = 0
    @State private var isKeyBindingsExpanded: Bool = false
    @StateObject private var padHolder = PressureTestPad.PadHolder()

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                headerSection
                accessSection
                profileSection
                pressureSection
                testSection
                smoothingSection
                mappingSection
                oledSection
                keyBindingsSection
                onScreenToolsSection
                footerSection
            }
            .padding(18)
            .padding(.bottom, 24)
        }
        .frame(width: 420, height: 680)
        .onAppear { model.checkPermissions() }
    }

    private var headerSection: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.isConnected ? Color.green : Color.red)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.isConnected ? "PTK-540WL Connected" : "Tablet Not Connected")
                    .font(.headline)
                HStack(spacing: 6) {
                    Text(model.lastStatus)
                        .font(.caption).foregroundStyle(.secondary)
                    if model.isConnected, model.batteryLevel >= 0 {
                        Text("• 🔋 \(model.batteryLevel)%\(model.isCharging ? " ⚡" : "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button(role: .destructive) {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Quit Intuos Driver")
        }
    }

    @ViewBuilder private var accessSection: some View {
        if !model.hasAccessibility {
            Button {
                model.requestAccessibility()
            } label: {
                Label("Grant Accessibility permission to enable pen input", systemImage: "lock.shield")
            }
            .buttonStyle(.borderedProminent)
            Divider()
        }

        if model.hasAccessibility && model.needsRestart {
            Button {
                model.restartApp()
            } label: {
                Label("Restart IntuosDriver to activate pen input", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            Divider()
        }

        if let warn = model.seizeWarning, model.hasAccessibility {
            Label(warn, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(3)
            Divider()
        }
    }

    @ViewBuilder private var profileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("App Profile").font(.subheadline).fontWeight(.medium)
                Spacer()
                Text(model.activeProfileName)
                    .font(.callout).fontWeight(.semibold)
                    .foregroundColor(.accentColor)
            }
            Picker("", selection: $model.activeProfileName) {
                ForEach(AppProfile.presets) { p in
                    Text(p.name).tag(p.name)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .onChange(of: model.activeProfileName) { newName in
                if let matched = AppProfile.presets.first(where: { $0.name == newName }) {
                    AppProfileManager.shared.applyProfile(matched)
                }
            }

            Toggle("Auto-switch profile based on active app", isOn: $model.autoSwitchProfiles)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Export Profiles…") {
                    model.exportProfiles()
                }
                .buttonStyle(.bordered).controlSize(.small)
                
                Button("Import Profiles…") {
                    model.importProfiles()
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
        }
        Divider()
    }

    @ViewBuilder private var pressureSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Pressure sensitivity").font(.subheadline).fontWeight(.medium)
                Spacer()
                Text(gammaLabel)
                    .font(.callout).foregroundStyle(.secondary)
            }
            Slider(value: $model.pressureGamma, in: 0.3...2.5, step: 0.05)
            HStack {
                Button("Soft") { model.pressureGamma = 0.65 }
                Button("Linear") { model.pressureGamma = 1.0 }
                Button("Firm") { model.pressureGamma = 1.5 }
            }
            .buttonStyle(.bordered).controlSize(.small)

            HStack {
                Text("Dead zone").font(.subheadline)
                Spacer()
                Slider(value: $model.deadZone, in: 0...0.15, step: 0.005)
                    .frame(width: 160)
                Text("\(Int(model.deadZone * 100))%")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }

            CurvePreview(gamma: model.pressureGamma, deadZone: model.deadZone)
        }
        Divider()
    }

    @ViewBuilder private var smoothingSection: some View {
        HStack {
            Text("Smoothing").font(.subheadline)
            Spacer()
            Slider(value: $model.smoothing, in: 0...0.9, step: 0.05)
                .frame(width: 180)
            Text("\(Int(model.smoothing * 100))%")
                .font(.callout).foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
        Divider()
    }

    @ViewBuilder private var mappingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Display & Orientation").font(.subheadline).fontWeight(.medium)
                Spacer()
                Button {
                    let name = DisplayToggleManager.shared.cycleNextDisplay(synthesizer: model.synthesizer)
                    HUDOverlayController.shared.show(title: "Display Toggle", subtitle: name, iconName: "display.2")
                } label: {
                    Label("Cycle Display", systemImage: "display.2")
                }
                .buttonStyle(.bordered).controlSize(.small)
            }

            Toggle("Map to full desktop across all displays", isOn: $model.useFullDesktop)
                .font(.subheadline)
            Toggle("Preserve tablet aspect ratio", isOn: $model.preserveAspectRatio)
                .font(.subheadline)
            Toggle("Left-handed mode (180° tablet rotation)", isOn: $model.isLeftHanded)
                .font(.subheadline)
            Toggle("Precision mode (2x detail zoom)", isOn: $model.isPrecisionMode)
                .font(.subheadline)
        }
        Divider()
    }

    @ViewBuilder private var testSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Live Pen & Pressure Test").font(.subheadline).fontWeight(.medium)
                Spacer()
                if livePressure > 0.01 {
                    Text("\(Int(livePressure * 100))% pressure")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.blue)
                }
                Button("Clear") {
                    padHolder.view?.clear()
                    livePressure = 0
                }
                .buttonStyle(.bordered).controlSize(.small)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.blue)
                        .frame(width: geo.size.width * CGFloat(min(1.0, max(0.0, livePressure))))
                }
            }
            .frame(height: 6)

            PressureTestPad(livePressure: $livePressure, holder: padHolder)
                .frame(height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.35)))

            Text("Draw with your pen above to test pressure levels and stroke thickness.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        Divider()
    }

    @ViewBuilder private var oledSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Touch Ring & OLED").font(.subheadline).fontWeight(.medium)
                Spacer()
                Button("Refresh Displays") {
                    model.oledController.applyLabels()
                }
                .buttonStyle(.bordered).controlSize(.small)
            }

            HStack(spacing: 6) {
                Text("Active Ring Mode:").font(.caption).foregroundStyle(.secondary)
                Text(ringModeLabel)
                    .font(.caption).fontWeight(.semibold)
                Spacer()
            }

            HStack {
                Text("LED Brightness").font(.subheadline)
                Spacer()
                Slider(value: $model.ledBrightness, in: 0...15, step: 1)
                    .frame(width: 160)
                Text("\(Int(model.ledBrightness))")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
            }
        }
        Divider()
    }

    private var ringModeLabel: String {
        switch model.currentRingMode {
        case 0: return "1. Auto Scroll / Zoom"
        case 1: return "2. Cycle Layers"
        case 2: return "3. Brush Size"
        case 3: return "4. Rotate Canvas"
        default: return "Mode \(model.currentRingMode + 1)"
        }
    }

    @ViewBuilder private var keyBindingsSection: some View {
        DisclosureGroup(isExpanded: $isKeyBindingsExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                let profile = AppProfileManager.shared.activeProfile
                ForEach(0..<8, id: \.self) { idx in
                    HStack(spacing: 8) {
                        Text("K\(idx + 1)")
                            .font(.caption).fontWeight(.bold)
                            .frame(width: 24, alignment: .leading)
                        
                        TextField("Label", text: Binding(
                            get: { idx < profile.oledLabels.count ? profile.oledLabels[idx] : "Key \(idx + 1)" },
                            set: { newLabel in
                                let act = idx < profile.keyActions.count ? profile.keyActions[idx] : "undo"
                                AppProfileManager.shared.updateKeyBinding(profileID: profile.bundleIdentifier, keyIndex: idx, actionStr: act, label: newLabel)
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 75)
                        .font(.caption)

                        Picker("", selection: Binding(
                            get: { idx < profile.keyActions.count ? profile.keyActions[idx] : "undo" },
                            set: { newAction in
                                let lbl = idx < profile.oledLabels.count ? profile.oledLabels[idx] : "Key"
                                AppProfileManager.shared.updateKeyBinding(profileID: profile.bundleIdentifier, keyIndex: idx, actionStr: newAction, label: lbl)
                            }
                        )) {
                            Text("Undo").tag("undo")
                            Text("Redo").tag("redo")
                            Text("Brush +").tag("brush+")
                            Text("Brush -").tag("brush-")
                            Text("Zoom +").tag("zoomIn")
                            Text("Zoom -").tag("zoomOut")
                            Text("Pan / Hand").tag("hand")
                            Text("Eyedropper").tag("eyedropper")
                            Text("Radial Menu").tag("radialMenu")
                            Text("Display Toggle").tag("displayToggle")
                            Text("Precision Mode").tag("precisionMode")
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            HStack {
                Text("ExpressKey Customizer").font(.subheadline).fontWeight(.medium)
                Spacer()
            }
        }
        Divider()
    }

    @ViewBuilder private var onScreenToolsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("On-Screen Tools & HUD").font(.subheadline).fontWeight(.medium)
                Spacer()
                Button {
                    RadialMenuController.shared.toggle()
                } label: {
                    Label("Radial Menu", systemImage: "circle.grid.cross")
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
            
            Toggle("Show on-screen HUD for Keys & Touch Ring", isOn: $model.showHUDOverlays)
                .font(.subheadline)
            Toggle("Show on-screen HUD when switching apps", isOn: $model.showProfileHUD)
                .font(.subheadline)
        }
        Divider()
    }

    @ViewBuilder private var footerSection: some View {
        VStack(spacing: 10) {
            Toggle("Launch at login", isOn: $model.launchAtLogin)
                .font(.subheadline)

            HStack {
                Button(role: .destructive) {
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit Intuos Driver", systemImage: "power")
                        .foregroundColor(.red)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
                Text("v1.0 (Apple Silicon)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var gammaLabel: String {
        switch model.pressureGamma {
        case ..<0.85: return "Soft"
        case 0.95...1.05: return "Linear"
        case ...1.75: return "Firm"
        default: return "Very firm"
        }
    }
}

// MARK: - App entry

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let model: AppDriverModel
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var connectionCancellable: AnyCancellable?

    init(model: AppDriverModel) {
        self.model = model
        super.init()
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: Self.symbol(connected: model.isConnected),
            accessibilityDescription: "Intuos4"
        )
        item.button?.target = self
        item.button?.action = #selector(statusBarClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        let p = NSPopover()
        p.behavior = .transient
        p.delegate = self
        p.contentSize = NSSize(width: 420, height: 680)
        p.contentViewController = NSHostingController(rootView: PanelView(model: model))
        self.popover = p

        connectionCancellable = model.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                DispatchQueue.main.async {
                    self?.statusItem?.button?.image = NSImage(
                        systemSymbolName: Self.symbol(connected: connected),
                        accessibilityDescription: "Intuos4"
                    )
                }
            }
    }

    func teardown() {
        popover?.close()
        popover = nil
        connectionCancellable?.cancel()
        connectionCancellable = nil
        model.prepareForExit()
    }

    @objc private func statusBarClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else {
            togglePanel(sender)
            return
        }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu()
        } else {
            togglePanel(sender)
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        let radialItem = NSMenuItem(title: "Radial Menu", action: #selector(toggleRadialFromMenu), keyEquivalent: "r")
        let quitItem = NSMenuItem(title: "Quit Intuos Driver", action: #selector(quitApp), keyEquivalent: "q")
        
        settingsItem.target = self
        radialItem.target = self
        quitItem.target = self

        menu.addItem(settingsItem)
        menu.addItem(radialItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(quitItem)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func openSettingsFromMenu() {
        togglePanel(nil)
    }

    @objc private func toggleRadialFromMenu() {
        RadialMenuController.shared.toggle()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc private func togglePanel(_ sender: Any?) {
        guard let button = statusItem?.button, let p = popover else { return }
        if p.isShown {
            p.performClose(sender)
        } else {
            model.checkPermissions()
            p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private static func symbol(connected: Bool) -> String {
        connected ? "pencil.tip" : "pencil.tip.crop.circle.badge.minus"
    }
}

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusBarController?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            let controller = StatusBarController(model: AppDriverModel())
            self.controller = controller
            controller.install()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            self.controller?.teardown()
        }
    }
}
