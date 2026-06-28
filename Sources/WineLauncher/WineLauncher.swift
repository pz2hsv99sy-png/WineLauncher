import SwiftUI
import AppKit

@main
struct ElviusGamingApp: App {
    @StateObject private var store = GameStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // Kill any leftover wineserver from previous session
        try? Process.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "pkill -f wineserver; pkill -f winedevice; pkill -f plugplay"], terminationHandler: nil)
        // Show HUD immediately on launch, always visible
        DispatchQueue.main.async {
            HUDWindowController.shared.show(gameName: nil, corner: .topRight)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
        .defaultSize(width: 1100, height: 720)
    }
}
