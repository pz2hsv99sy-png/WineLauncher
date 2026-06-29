import SwiftUI
import AppKit

@main
struct ElviusGamingApp: App {
    @StateObject private var store = GameStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // Kill any leftover wineserver from previous session
        try? Process.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "pkill -f wineserver; pkill -f winedevice; pkill -f plugplay"], terminationHandler: nil)
        // The HUD now appears only while a game is running (see GameStore.launch).
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands {
            // ⌘N = nouvelle bouteille · ⇧⌘N = ajouter un logiciel
            CommandGroup(replacing: .newItem) {
                Button("Nouvelle bouteille") {
                    NotificationCenter.default.post(name: .newBottle, object: nil)
                }.keyboardShortcut("n", modifiers: .command)
                Button("Ajouter un logiciel") {
                    NotificationCenter.default.post(name: .addSoftware, object: nil)
                }.keyboardShortcut("n", modifiers: [.command, .shift])
            }
            // About → Elvius Gaming v2 by ELVIUS
            CommandGroup(replacing: .appInfo) {
                Button("À propos d'Elvius Gaming") {
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .applicationName: "Elvius Gaming",
                        .applicationVersion: "Version 2",
                        .init(rawValue: "Copyright"): "Développé par ELVIUS",
                        .credits: NSAttributedString(string: "Launcher Wine / D3DMetal pour macOS Apple Silicon.\nDéveloppé par ELVIUS.")
                    ])
                }
            }
        }
        .defaultSize(width: 1100, height: 720)
    }
}

extension Notification.Name {
    static let newBottle = Notification.Name("elvius.newBottle")
    static let addSoftware = Notification.Name("elvius.addSoftware")
}
