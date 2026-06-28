import SwiftUI

enum HUDCorner: String, CaseIterable {
    case topLeft     = "Top Left"
    case topRight    = "Top Right"
    case bottomLeft  = "Bottom Left"
    case bottomRight = "Bottom Right"
}

struct HUDView: View {
    @ObservedObject var monitor: ResourceMonitor
    var gameName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Title
            HStack(spacing: 6) {
                Image(systemName: gameName != nil ? "gamecontroller.fill" : "chart.bar.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.caption.bold())
                Text(gameName ?? "System")
                    .font(.caption.bold())
                    .lineLimit(1)
                Spacer()
                Circle()
                    .fill(gameName != nil ? Color.green : Color.accentColor)
                    .frame(width: 6, height: 6)
            }

            Divider().opacity(0.3)

            // CPU
            resourceRow(
                icon: "cpu",
                label: "CPU",
                value: String(format: "%.1f%%", monitor.cpuPercent),
                fraction: monitor.cpuPercent / 100,
                color: monitor.cpuPercent > 80 ? .red : monitor.cpuPercent > 50 ? .orange : .green
            )

            // RAM
            let ramFraction = monitor.ramTotalGB > 0 ? monitor.ramUsedGB / monitor.ramTotalGB : 0
            resourceRow(
                icon: "memorychip",
                label: "RAM",
                value: String(format: "%.1f / %.0f GB", monitor.ramUsedGB, monitor.ramTotalGB),
                fraction: ramFraction,
                color: ramFraction > 0.85 ? .red : ramFraction > 0.65 ? .orange : .blue
            )

            // Wine memory
            if monitor.wineMemoryMB > 0 {
                resourceRow(
                    icon: "wineglass",
                    label: "Wine",
                    value: String(format: "%.0f MB", monitor.wineMemoryMB),
                    fraction: min(1, monitor.wineMemoryMB / 4096),
                    color: .purple
                )
            }
        }
        .padding(12)
        .frame(width: 200)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.3), radius: 10)
    }

    @ViewBuilder
    private func resourceRow(icon: String, label: String, value: String, fraction: Double, color: Color) -> some View {
        VStack(spacing: 3) {
            HStack {
                Image(systemName: icon).font(.caption2).foregroundStyle(color).frame(width: 14)
                Text(label).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(value).font(.caption.monospaced().bold()).foregroundStyle(.primary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary.opacity(0.1))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: geo.size.width * max(0, min(1, fraction)))
                        .animation(.easeInOut(duration: 0.5), value: fraction)
                }
            }
            .frame(height: 4)
        }
    }
}

// MARK: - Floating NSPanel controller

class HUDWindowController: NSWindowController {
    private var monitor = ResourceMonitor()
    private var corner: HUDCorner = .topRight

    static let shared = HUDWindowController()

    private init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 140),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: panel)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(gameName: String? = nil, corner: HUDCorner = .topRight) {
        self.corner = corner
        let hostingView = NSHostingView(rootView: HUDView(monitor: monitor, gameName: gameName))
        window?.contentView = hostingView
        positionWindow()
        window?.orderFront(nil)
        monitor.start()
    }

    func updateGameName(_ name: String?) {
        show(gameName: name, corner: corner)
    }

    func hide() {
        // Never hide — just update to system mode when no game is running
        updateGameName(nil)
    }

    private func positionWindow() {
        guard let screen = NSScreen.main, let win = window else { return }
        let margin: CGFloat = 16
        let sw = screen.visibleFrame
        let ww = win.frame.width
        let wh = win.frame.height

        let x: CGFloat
        let y: CGFloat
        switch corner {
        case .topLeft:     x = sw.minX + margin;          y = sw.maxY - wh - margin
        case .topRight:    x = sw.maxX - ww - margin;     y = sw.maxY - wh - margin
        case .bottomLeft:  x = sw.minX + margin;          y = sw.minY + margin
        case .bottomRight: x = sw.maxX - ww - margin;     y = sw.minY + margin
        }
        win.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
