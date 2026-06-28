import Foundation

// Installs Wine + required components (DXVK, VKD3D, winetricks) automatically.
// All operations are non-blocking — progress is reported via the log callback.
actor SetupService {

    static let shared = SetupService()

    // Returns path to wine binary, or nil if not found/installable
    func ensureWine(log: @escaping (String) -> Void) async -> String? {
        // Check common locations first
        let candidates = [
            "/opt/homebrew/bin/wine",
            "/usr/local/bin/wine",
            "/usr/bin/wine"
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                log("✓ Wine found at \(path)\n")
                return path
            }
        }

        log("Wine not found. Installing via Homebrew...\n")
        let result = await runShell("brew install --cask --no-quarantine wine-stable", log: log)
        if result {
            for path in candidates {
                if FileManager.default.fileExists(atPath: path) { return path }
            }
        }
        log("✗ Could not install Wine. Run: brew install --cask wine-stable\n")
        return nil
    }

    func ensureWinetricks(log: @escaping (String) -> Void) async -> Bool {
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/winetricks") ||
           FileManager.default.fileExists(atPath: "/usr/local/bin/winetricks") {
            log("✓ winetricks found\n")
            return true
        }
        log("Installing winetricks...\n")
        return await runShell("brew install winetricks", log: log)
    }

    func setupPrefix(for game: Game, winePath: String, log: @escaping (String) -> Void) async -> Bool {
        let prefix = game.resolvedPrefixPath
        let arch = game.detection.arch == "x86" ? "win32" : "win64"

        // Create prefix
        log("Creating Wine prefix at \(prefix)...\n")
        var env = baseEnv(prefix: prefix)
        env["WINEARCH"] = arch
        let ok = await runShell("\(winePath) wineboot --init", env: env, log: log)
        guard ok else { return false }

        // Install Windows runtime prerequisites (VC++, .NET, DirectX compiler, fonts, media)
        log("\nInstalling Windows prerequisites (Visual C++, .NET, DirectX, fonts)...\n")
        log("This can take 5-15 minutes on first run — packages are downloaded once and cached.\n")
        let prereqs = game.detection.needsVKD3D
            ? PrerequisitesService.steamPrereqs          // full set for DX12/Steam
            : PrerequisitesService.gamePrereqs           // lighter set for simpler games
        await PrerequisitesService.shared.installPrereqs(prereqs, prefix: prefix, log: log)

        // DXVK / VKD3D are included in prereqs above — skip duplicate installs
        // EAC single-player bypass: env vars applied at launch, no file changes needed
        if game.detection.antiCheat == "EAC" {
            log("\nEAC detected — single-player bypass env vars will be applied at launch.\n")
        }

        log("\n✓ Setup complete.\n")
        return true
    }

    // nonisolated so it can be called from sync context (GameStore)
    nonisolated func launchEnvSync(for game: Game) -> [String: String] {
        var env = baseEnv(prefix: game.resolvedPrefixPath)
        // Apple Silicon sync (better than esync on M-series)
        env["WINEMSYNC"] = "1"
        // DXVK async shader compilation (reduces stutter)
        if game.detection.needsDXVK { env["DXVK_ASYNC"] = "1" }
        // EAC single-player bypass
        if game.detection.antiCheat == "EAC" {
            env["PROTON_EAC_RUNTIME"] = "0"
            env["EOS_USE_ANTICHEATCLIENT_NULL"] = "1"
        }
        // BattlEye note (can't be fully bypassed in Wine)
        return env
    }

    // MARK: - Internals

    nonisolated private func baseEnv(prefix: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = prefix
        env["WINEDEBUG"] = "-all"  // silence Wine debug spam
        return env
    }

    private func runWinetricks(_ verbs: [String], prefix: String, log: @escaping (String) -> Void) async -> Bool {
        let winetricksPath = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/winetricks")
            ? "/opt/homebrew/bin/winetricks"
            : "/usr/local/bin/winetricks"
        var env = baseEnv(prefix: prefix)
        env["WINEPREFIX"] = prefix
        return await runShell("\(winetricksPath) \(verbs.joined(separator: " "))", env: env, log: log)
    }

    @discardableResult
    private func runShell(_ command: String, env: [String: String]? = nil, log: @escaping (String) -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", command]
            if let env { process.environment = env }

            let pipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = pipe
            process.standardError = errPipe

            pipe.fileHandleForReading.readabilityHandler = { h in
                if let s = String(data: h.availableData, encoding: .utf8), !s.isEmpty { log(s) }
            }
            errPipe.fileHandleForReading.readabilityHandler = { h in
                if let s = String(data: h.availableData, encoding: .utf8), !s.isEmpty { log(s) }
            }

            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: proc.terminationStatus == 0)
            }

            do { try process.run() }
            catch { log("Error: \(error)\n"); continuation.resume(returning: false) }
        }
    }
}
