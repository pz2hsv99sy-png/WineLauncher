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
                    .font(.system(.caption, design: .rounded).bold())
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

            // Wine memory + history graph
            if monitor.wineMemoryMB > 0 {
                resourceRow(
                    icon: "wineglass",
                    label: "Wine",
                    value: String(format: "%.0f MB", monitor.wineMemoryMB),
                    fraction: min(1, monitor.wineMemoryMB / 4096),
                    color: .purple
                )
                Sparkline(samples: monitor.wineHistory, color: .purple)
                    .frame(height: 26)
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
                Text(label).font(.system(.caption2, design: .rounded).weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                // Rounded font with monospaced digits = clean look + stable width
                Text(value).font(.system(.caption, design: .rounded).weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
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

// MARK: - RAM history sparkline

struct Sparkline: View {
    let samples: [Double]
    var color: Color

    var body: some View {
        GeometryReader { geo in
            let pts = samples
            let maxV = max(pts.max() ?? 1, 1)
            let minV = min(pts.min() ?? 0, maxV)
            let range = max(maxV - minV, 1)
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06))
                if pts.count > 1 {
                    // Filled area under the curve
                    path(in: geo.size, pts: pts, minV: minV, range: range, closed: true)
                        .fill(color.opacity(0.18))
                    // Line on top
                    path(in: geo.size, pts: pts, minV: minV, range: range, closed: false)
                        .stroke(color.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }
            }
        }
    }

    private func path(in size: CGSize, pts: [Double], minV: Double, range: Double, closed: Bool) -> Path {
        Path { p in
            let stepX = size.width / CGFloat(max(pts.count - 1, 1))
            func point(_ i: Int) -> CGPoint {
                let x = CGFloat(i) * stepX
                let norm = (pts[i] - minV) / range
                let y = size.height - CGFloat(norm) * size.height
                return CGPoint(x: x, y: y)
            }
            p.move(to: point(0))
            for i in 1..<pts.count { p.addLine(to: point(i)) }
            if closed {
                p.addLine(to: CGPoint(x: size.width, y: size.height))
                p.addLine(to: CGPoint(x: 0, y: size.height))
                p.closeSubpath()
            }
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
        // Greyed/translucent so it stays discreet over the game.
        panel.alphaValue = 0.6
        // Let the user drag the HUD anywhere by its background.
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: panel)
        panel.delegate = self
    }

    // Once the user has dragged the HUD we keep its position instead of
    // snapping it back to a corner on the next show.
    private var userMovedHUD = false
    // True while a game is running; the HUD is only visible when the game
    // (a Wine process) is the frontmost app, and hidden when the user switches
    // to another app.
    private var gameActive = false
    private var activationObservers: [NSObjectProtocol] = []

    required init?(coder: NSCoder) { fatalError() }

    func show(gameName: String? = nil, corner: HUDCorner = .topRight) {
        self.corner = corner
        let hostingView = NSHostingView(rootView: HUDView(monitor: monitor, gameName: gameName))
        window?.contentView = hostingView
        positionWindow()
        gameActive = true
        monitor.start()
        observeAppFocus()
        updateVisibility()
    }

    func updateGameName(_ name: String?) {
        show(gameName: name, corner: corner)
    }

    func hide() {
        // Only shown while a game runs — actually hide it when the game stops.
        gameActive = false
        window?.orderOut(nil)
        monitor.stop()
        for o in activationObservers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        activationObservers.removeAll()
    }

    private func observeAppFocus() {
        guard activationObservers.isEmpty else { return }
        let nc = NSWorkspace.shared.notificationCenter
        for note in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didDeactivateApplicationNotification] {
            let o = nc.addObserver(forName: note, object: nil, queue: .main) { [weak self] _ in
                self?.updateVisibility()
            }
            activationObservers.append(o)
        }
    }

    // Show the HUD only when the frontmost app is the game (a Wine process).
    private func updateVisibility() {
        guard gameActive, let win = window else { return }
        let front = NSWorkspace.shared.frontmostApplication
        let name = (front?.executableURL?.lastPathComponent ?? "").lowercased()
        let isGameFront = name.contains("wine")
        if isGameFront {
            if !win.isVisible { win.orderFront(nil) }
        } else {
            if win.isVisible { win.orderOut(nil) }
        }
    }

    private func positionWindow() {
        // Respect a position the user dragged the HUD to.
        guard !userMovedHUD else { return }
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

extension HUDWindowController: NSWindowDelegate {
    func windowDidMove(_ notification: Notification) {
        // User dragged the HUD — remember it and stop auto-positioning.
        userMovedHUD = true
    }
}
