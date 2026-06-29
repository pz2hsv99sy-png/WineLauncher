import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {

    /// Are there any Wine processes alive (a game running)?
    private func wineIsRunning() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "pgrep -f 'wine64-preloader|wineserver' >/dev/null 2>&1"]
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Force-kill every Wine process so nothing is left running once Elvius quits.
    private func killAllWine() {
        try? Process.run(URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "pkill -9 -f wine64; pkill -9 -f wineserver; pkill -9 -f winedevice; pkill -9 -f plugplay; pkill -9 -f winetricks; pkill -9 -f Cities.exe; pkill -9 -f steam.exe"],
            terminationHandler: nil)
    }

    // If a game is running, warn the user (so they can save in-game) before we
    // close everything. Games are children of Elvius — quitting Elvius kills them.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard wineIsRunning() else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Un jeu est en cours d'exécution"
        alert.informativeText = "Quitter Elvius Gaming va fermer le jeu et tous les composants Wine.\n\nSauvegarde ta partie dans le jeu avant de continuer."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quitter quand même")
        alert.addButton(withTitle: "Annuler")
        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            killAllWine()
            return .terminateNow
        }
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Final safety net — nothing Wine-related survives Elvius.
        killAllWine()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
