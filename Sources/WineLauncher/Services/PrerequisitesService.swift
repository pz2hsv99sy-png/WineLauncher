import Foundation

// Installs common Windows runtime prerequisites into a Wine prefix via winetricks.
// These are needed by most games (Visual C++ runtimes, DirectX, .NET, etc.)
actor PrerequisitesService {

    static let shared = PrerequisitesService()

    // vcrun2022 already bundles 2015/2017/2019/2022 — no need to install separately
    // dotnet48 is slow and not required by Steam or most games
    static let steamPrereqs: [String] = [
        "vcrun2022",        // VC++ 2015-2022 all-in-one
        "d3dcompiler_47",   // DirectX shader compiler
        "dxvk",             // DirectX 9/10/11 → Metal
        "vkd3d",            // DirectX 12 → Metal
        "corefonts",        // Windows fonts (avoids UI glitches)
    ]

    // Same list for individual games — dxvk/vkd3d will be filtered by detection
    static let gamePrereqs: [String] = [
        "vcrun2022",
        "d3dcompiler_47",
        "dxvk",
    ]

    func installPrereqs(
        _ verbs: [String],
        prefix: String,
        log: @escaping (String) -> Void,
        progress: @escaping (SetupProgress) -> Void
    ) async -> Bool {
        let wt = winetricksPath()
        guard !wt.isEmpty else {
            log("✗ winetricks not found. Install it: brew install winetricks\n")
            return false
        }

        log("Installing Windows prerequisites (\(verbs.count) packages)...\n")
        log("This may take several minutes — packages are downloaded once and cached.\n\n")

        var p = SetupProgress(total: verbs.count, startTime: Date())
        progress(p)

        // Run all verbs in one winetricks call — saves Wine startup overhead per package
        // But track progress by watching log output for package markers
        log("  Packages: \(verbs.joined(separator: ", "))\n\n")

        for (i, verb) in verbs.enumerated() {
            p.current = i
            p.currentPackage = verb
            progress(p)
            log("  [\(i+1)/\(verbs.count)] \(verb)... ")
            // -q = quiet (no GUI dialogs), speeds up installs significantly
            let ok = await run("\(wt) -q \(verb)", prefix: prefix, log: { _ in })
            log(ok ? "✓\n" : "✗ (skipping)\n")
            p.current = i + 1
            progress(p)
        }
        return true
    }

    private func winetricksPath() -> String {
        for p in ["/opt/homebrew/bin/winetricks", "/usr/local/bin/winetricks"] {
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return ""
    }

    @discardableResult
    private func run(_ command: String, prefix: String, log: @escaping (String) -> Void) async -> Bool {
        await withCheckedContinuation { cont in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.arguments = ["-c", command]
            var env = ProcessInfo.processInfo.environment
            env["WINEPREFIX"] = prefix
            env["WINEDEBUG"] = "-all"
            env["DISPLAY"] = ""         // suppress spurious X11 warnings
            proc.environment = env
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { h in
                if let s = String(data: h.availableData, encoding: .utf8), !s.isEmpty { log(s) }
            }
            proc.terminationHandler = { p in
                pipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: p.terminationStatus == 0)
            }
            try? proc.run()
        }
    }
}
