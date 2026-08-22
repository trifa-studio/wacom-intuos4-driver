import Foundation
import AppKit

public struct AppProfile: Identifiable, Codable, Sendable, Equatable {
    public var id: String { bundleIdentifier }
    public var name: String
    public var bundleIdentifier: String
    public var oledLabels: [String]
    public var keyActions: [String]
    public var pressureGamma: Double
    public var smoothing: Double
    public var ringModeLabels: [String]

    public init(
        name: String,
        bundleIdentifier: String,
        oledLabels: [String],
        keyActions: [String] = ["undo", "redo", "brush-", "brush+", "hand", "displayToggle", "radialMenu", "precisionMode"],
        pressureGamma: Double = 1.0,
        smoothing: Double = 0.55,
        ringModeLabels: [String] = ["Scroll/Zoom", "Layers", "Brush Size", "Rotate Canvas"]
    ) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.oledLabels = oledLabels
        self.keyActions = keyActions
        self.pressureGamma = pressureGamma
        self.smoothing = smoothing
        self.ringModeLabels = ringModeLabels
    }

    public static let defaultProfile = AppProfile(
        name: "General / Desktop",
        bundleIdentifier: "default",
        oledLabels: ["Undo", "Redo", "Brush-", "Brush+", "Hand", "Displays", "Radial", "Precise"],
        keyActions: ["undo", "redo", "brush-", "brush+", "hand", "displayToggle", "radialMenu", "precisionMode"],
        pressureGamma: 1.0,
        smoothing: 0.55
    )

    public static let presets: [AppProfile] = [
        defaultProfile,
        AppProfile(
            name: "Adobe Photoshop",
            bundleIdentifier: "com.adobe.Photoshop",
            oledLabels: ["Undo", "Step Fwd", "Brush-", "Brush+", "Hand", "Eyedrop", "Radial", "Precise"],
            keyActions: ["undo", "redo", "brush-", "brush+", "hand", "eyedropper", "radialMenu", "precisionMode"],
            pressureGamma: 0.85,
            smoothing: 0.65,
            ringModeLabels: ["Zoom", "Layers", "Brush Size", "Rotate Canvas"]
        ),
        AppProfile(
            name: "Adobe Illustrator",
            bundleIdentifier: "com.adobe.illustrator",
            oledLabels: ["Undo", "Redo", "Select", "Direct", "Pen", "Displays", "Radial", "Zoom-"],
            keyActions: ["undo", "redo", "brush-", "brush+", "hand", "displayToggle", "radialMenu", "zoomOut"],
            pressureGamma: 1.0,
            smoothing: 0.50,
            ringModeLabels: ["Zoom", "Scroll", "Brush Size", "Rotate"]
        ),
        AppProfile(
            name: "Blender",
            bundleIdentifier: "org.blenderfoundation.blender",
            oledLabels: ["Undo", "Redo", "Radius-", "Radius+", "Grab", "Smooth", "Radial", "View All"],
            keyActions: ["undo", "redo", "brush-", "brush+", "hand", "displayToggle", "radialMenu", "zoomOut"],
            pressureGamma: 0.90,
            smoothing: 0.70,
            ringModeLabels: ["Zoom View", "Frame Step", "Brush Size", "Rotate View"]
        ),
        AppProfile(
            name: "Figma",
            bundleIdentifier: "com.figma.Desktop",
            oledLabels: ["Undo", "Redo", "Frame", "Pen", "Hand", "Displays", "Radial", "Zoom 100%"],
            keyActions: ["undo", "redo", "brush-", "brush+", "hand", "displayToggle", "radialMenu", "zoomIn"],
            pressureGamma: 1.0,
            smoothing: 0.40,
            ringModeLabels: ["Zoom", "Scroll H", "Scroll V", "Nudge"]
        ),
        AppProfile(
            name: "Safari / Chrome",
            bundleIdentifier: "com.apple.Safari",
            oledLabels: ["Back", "Forward", "New Tab", "CloseTab", "Reload", "Displays", "Radial", "Zoom-"],
            keyActions: ["undo", "redo", "zoomIn", "zoomOut", "hand", "displayToggle", "radialMenu", "zoomOut"],
            pressureGamma: 1.0,
            smoothing: 0.30,
            ringModeLabels: ["Scroll", "Tab Switch", "Zoom Page", "History"]
        )
    ]
}

public protocol AppProfileListener: AnyObject, Sendable {
    func appProfileDidChange(profile: AppProfile)
}

public final class AppProfileManager: @unchecked Sendable {
    public static let shared = AppProfileManager()

    public weak var listener: AppProfileListener?
    public private(set) var activeProfile: AppProfile = .defaultProfile
    public var profiles: [String: AppProfile] = [:]
    public var isAutoSwitchEnabled: Bool = true

    private var workspaceObserver: NSObjectProtocol?

    public init() {
        for preset in AppProfile.presets {
            profiles[preset.bundleIdentifier] = preset
        }
        loadCustomProfiles()
        setupObserver()
    }

    deinit {
        if let obs = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
    }

    private func setupObserver() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            guard let self, self.isAutoSwitchEnabled else { return }
            guard let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier else { return }
            self.handleApplicationActivated(bundleID: bundleID, appName: app.localizedName ?? "")
        }
    }

    public func handleApplicationActivated(bundleID: String, appName: String) {
        if let matched = profiles[bundleID] {
            applyProfile(matched)
        } else {
            // Check substring matching for apps like "Google Chrome" or "Blender"
            let lower = bundleID.lowercased()
            if lower.contains("photoshop") {
                applyProfile(profiles["com.adobe.Photoshop"] ?? .defaultProfile)
            } else if lower.contains("illustrator") {
                applyProfile(profiles["com.adobe.illustrator"] ?? .defaultProfile)
            } else if lower.contains("blender") {
                applyProfile(profiles["org.blenderfoundation.blender"] ?? .defaultProfile)
            } else if lower.contains("figma") {
                applyProfile(profiles["com.figma.Desktop"] ?? .defaultProfile)
            } else if lower.contains("safari") || lower.contains("chrome") {
                applyProfile(profiles["com.apple.Safari"] ?? .defaultProfile)
            } else {
                applyProfile(profiles["default"] ?? .defaultProfile)
            }
        }
    }

    public func applyProfile(_ profile: AppProfile) {
        guard activeProfile != profile else { return }
        self.activeProfile = profile
        listener?.appProfileDidChange(profile: profile)
    }

    public func updateKeyBinding(profileID: String, keyIndex: Int, actionStr: String, label: String) {
        guard var prof = profiles[profileID] else { return }
        if keyIndex < prof.keyActions.count {
            prof.keyActions[keyIndex] = actionStr
        }
        if keyIndex < prof.oledLabels.count {
            prof.oledLabels[keyIndex] = label
        }
        profiles[profileID] = prof
        if activeProfile.bundleIdentifier == profileID {
            activeProfile = prof
            listener?.appProfileDidChange(profile: prof)
        }
        saveProfiles()
    }

    private func loadCustomProfiles() {
        let url = profileStorageURL()
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([AppProfile].self, from: data) else { return }
        for p in list {
            profiles[p.bundleIdentifier] = p
        }
    }

    public func saveProfiles() {
        let url = profileStorageURL()
        let list = Array(profiles.values)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(list) {
            try? data.write(to: url)
        }
    }

    public func exportProfiles(to url: URL) throws {
        let list = Array(profiles.values)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(list)
        try data.write(to: url)
    }

    public func importProfiles(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let list = try JSONDecoder().decode([AppProfile].self, from: data)
        for p in list {
            profiles[p.bundleIdentifier] = p
        }
        saveProfiles()
        if let current = profiles[activeProfile.bundleIdentifier] {
            activeProfile = current
            listener?.appProfileDidChange(profile: current)
        }
    }

    private func profileStorageURL() -> URL {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/IntuosDriver", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("profiles.json")
    }
}
