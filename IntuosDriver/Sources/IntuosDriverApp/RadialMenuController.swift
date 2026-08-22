import Cocoa
import SwiftUI
import Carbon.HIToolbox

public struct RadialMenuItem: Identifiable {
    public let id = UUID()
    public let title: String
    public let iconName: String
    public let action: () -> Void

    public init(title: String, iconName: String, action: @escaping () -> Void) {
        self.title = title
        self.iconName = iconName
        self.action = action
    }
}

public final class RadialMenuController: ObservableObject, @unchecked Sendable {
    public static let shared = RadialMenuController()

    @Published public var isVisible: Bool = false
    @Published public var hoveredIndex: Int? = nil
    @Published public var items: [RadialMenuItem] = []

    private var panel: NSPanel?

    public init() {
        self.items = [
            RadialMenuItem(title: "Undo", iconName: "arrow.uturn.backward") {
                Self.postKey(keyCode: CGKeyCode(kVK_ANSI_Z), flags: .maskCommand)
            },
            RadialMenuItem(title: "Redo", iconName: "arrow.uturn.forward") {
                Self.postKey(keyCode: CGKeyCode(kVK_ANSI_Z), flags: [.maskCommand, .maskShift])
            },
            RadialMenuItem(title: "Brush +", iconName: "plus.circle") {
                Self.postKey(keyCode: CGKeyCode(kVK_ANSI_RightBracket), flags: [])
            },
            RadialMenuItem(title: "Brush -", iconName: "minus.circle") {
                Self.postKey(keyCode: CGKeyCode(kVK_ANSI_LeftBracket), flags: [])
            },
            RadialMenuItem(title: "Zoom In", iconName: "plus.magnifyingglass") {
                Self.postKey(keyCode: CGKeyCode(kVK_ANSI_Equal), flags: .maskCommand)
            },
            RadialMenuItem(title: "Zoom Out", iconName: "minus.magnifyingglass") {
                Self.postKey(keyCode: CGKeyCode(kVK_ANSI_Minus), flags: .maskCommand)
            },
            RadialMenuItem(title: "Hand", iconName: "hand.raised") {
                Self.postKey(keyCode: CGKeyCode(kVK_Space), flags: [])
            },
            RadialMenuItem(title: "Eyedropper", iconName: "eyedropper") {
                Self.postKey(keyCode: CGKeyCode(kVK_Option), flags: .maskAlternate)
            }
        ]

        DispatchQueue.main.async { [weak self] in
            self?.setupPanel()
        }
    }

    private func setupPanel() {
        let size: CGFloat = 260
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true

        let hosting = NSHostingView(rootView: RadialMenuView(controller: self))
        panel.contentView = hosting
        self.panel = panel
    }

    public func toggle() {
        if isVisible {
            hide()
        } else {
            show(at: NSEvent.mouseLocation)
        }
    }

    public func show(at location: NSPoint) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel else { return }
            let size: CGFloat = 260
            let origin = NSPoint(x: location.x - size / 2.0, y: location.y - size / 2.0)
            panel.setFrameOrigin(origin)
            panel.orderFrontRegardless()
            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                self.isVisible = true
            }
        }
    }

    public func hide() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                self.isVisible = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                self.panel?.orderOut(nil)
            }
        }
    }

    public func executeItem(at index: Int) {
        guard index >= 0, index < items.count else { return }
        let action = items[index].action
        hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            action()
        }
    }

    public static func postKey(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

struct RadialMenuView: View {
    @ObservedObject var controller: RadialMenuController
    let size: CGFloat = 260

    var body: some View {
        ZStack {
            // Background blur circle
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: size, height: size)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.2), lineWidth: 1.5)
                )
                .shadow(color: Color.black.opacity(0.35), radius: 18, x: 0, y: 8)

            // 8 Sector Buttons
            ForEach(0..<controller.items.count, id: \.self) { i in
                let angle = Double(i) * (360.0 / Double(controller.items.count)) - 90.0
                let rad = angle * .pi / 180.0
                let radius = size * 0.33
                let x = cos(rad) * radius
                let y = sin(rad) * radius
                let isHovered = controller.hoveredIndex == i

                Button {
                    controller.executeItem(at: i)
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: controller.items[i].iconName)
                            .font(.system(size: 16, weight: .semibold))
                        Text(controller.items[i].title)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                    }
                    .foregroundColor(isHovered ? .white : .white.opacity(0.85))
                    .frame(width: 64, height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(isHovered ? Color.accentColor.opacity(0.8) : Color.white.opacity(0.08))
                    )
                    .scaleEffect(isHovered ? 1.08 : 1.0)
                }
                .buttonStyle(.plain)
                .offset(x: x, y: y)
                .onHover { hovering in
                    controller.hoveredIndex = hovering ? i : nil
                }
            }

            // Center cancel button
            Button {
                controller.hide()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
        }
        .frame(width: size, height: size)
        .scaleEffect(controller.isVisible ? 1.0 : 0.8)
        .opacity(controller.isVisible ? 1.0 : 0.0)
    }
}
