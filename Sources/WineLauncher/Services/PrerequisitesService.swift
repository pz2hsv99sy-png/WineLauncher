import Foundation

// Installs common Windows runtime prerequisites into a Wine prefix via winetricks.
// These are needed by most games (Visual C++ runtimes, DirectX, .NET, etc.)
actor PrerequisitesService {

    static let shared = PrerequisitesService()

    // Full set of prerequisites needed to run modern Windows games + Steam
    static let steamPrereqs: [String] = [
        "vcrun2022",    // Visual C++ 2015-2022 (required by almost everything)
        "vcrun2019",
        "vcrun2017",
        "vcrun2015",
        "vcrun2013",
        "vcrun2010",
        "dotnet48",     // .NET Framework 4.8
        "d3dcompiler_47", // DirectX shader compiler
        "dxvk",         // DirectX 9/10/11 → Metal
        "vkd3d",        // DirectX 12 → Metal
        "corefonts",    // Windows core fonts (avoids UI glitches)
        "mf",           // Media Foundation (video cutscenes)
    ]

    // Minimal set for a single game (no Steam)
    static let gamePrereqs: [String] = [
        "vcrun2022",
        "vcrun2015",
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

        for (i, verb) in verbs.enumerated() {
            p.current = i
            p.currentPackage = verb
            progress(p)

            log("  [\(i+1)/\(verbs.count)] \(verb)... ")
            let ok = await run("\(wt) \(verb)", prefix: prefix, log: { _ in })
            log(ok ? "✓\n" : "✗ (may be optional)\n")

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
