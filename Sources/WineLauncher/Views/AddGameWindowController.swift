import SwiftUI
import AppKit

class AddGameWindowController: NSWindowController, NSWindowDelegate {
    static let shared = AddGameWindowController()
    private var onClose: (() -> Void)?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 460),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Add a Game"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func open(store: GameStore, preselectBottle: String? = nil, onClose: @escaping () -> Void) {
        self.onClose = onClose
        let view = AddGameView(preselectBottlePath: preselectBottle)
            .environmentObject(store)
        window?.contentView = NSHostingView(rootView: view)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close(store: GameStore) {
        window?.orderOut(nil)
        onClose?()
        onClose = nil
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
        onClose = nil
    }
}
