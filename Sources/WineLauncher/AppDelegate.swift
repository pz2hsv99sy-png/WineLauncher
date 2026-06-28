import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        // Kill all Wine background processes when app quits
        try? Process.run(URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "pkill -f wineserver; pkill -f winedevice; pkill -f plugplay; pkill -f winetricks"],
            terminationHandler: nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
