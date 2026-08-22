import Cocoa
import SwiftUI
import Combine

public final class HUDOverlayController: ObservableObject, @unchecked Sendable {
    public static let shared = HUDOverlayController()

    @Published public var isVisible: Bool = false
    @Published public var title: String = ""
    @Published public var subtitle: String = ""
    @Published public var iconName: String = "circle.grid.cross"

    private var panel: NSPanel?
    private var fadeWorkItem: DispatchWorkItem?

    public init() {
        DispatchQueue.main.async { [weak self] in
            self?.setupPanel()
        }
    }

    private func setupPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 90),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        let hosting = NSHostingView(rootView: HUDOverlayView(controller: self))
        panel.contentView = hosting
        self.panel = panel
    }

    public func show(title: String, subtitle: String = "", iconName: String = "circle.grid.cross") {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.title = title
            self.subtitle = subtitle
            self.iconName = iconName
            self.isVisible = true

            if let screen = NSScreen.main, let panel = self.panel {
                let screenRect = screen.visibleFrame
                let x = screenRect.midX - 140
                let y = screenRect.minY + 120
                panel.setFrameOrigin(NSPoint(x: x, y: y))
                panel.orderFrontRegardless()
            }

            self.fadeWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                withAnimation(.easeOut(duration: 0.3)) {
                    self.isVisible = false
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    if !self.isVisible {
                        self.panel?.orderOut(nil)
                    }
                }
            }
            self.fadeWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
        }
    }
}

struct HUDOverlayView: View {
    @ObservedObject var controller: HUDOverlayController

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: controller.iconName)
                .font(.system(size: 28, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.white.opacity(0.15)))

            VStack(alignment: .leading, spacing: 3) {
                Text(controller.title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                if !controller.subtitle.isEmpty {
                    Text(controller.subtitle)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(.white.opacity(0.75))
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(width: 280, height: 80)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.3), radius: 15, x: 0, y: 8)
        )
        .opacity(controller.isVisible ? 1 : 0)
        .scaleEffect(controller.isVisible ? 1.0 : 0.95)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: controller.isVisible)
    }
}
