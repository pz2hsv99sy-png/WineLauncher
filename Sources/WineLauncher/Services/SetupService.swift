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
        let result = await runShell("brew install --cask wine-stable", log: log)
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

    func setupPrefix(for game: Game, winePath: String, log: @escaping (String) -> Void, progress: @escaping (SetupProgress) -> Void = { _ in }) async -> Bool {
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
        await PrerequisitesService.shared.installPrereqs(prereqs, prefix: prefix, log: log, progress: progress)

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
        env["WINEESYNC"] = "1"
        if game.detection.antiCheat == "EAC" {
            env["PROTON_EAC_RUNTIME"] = "0"
            env["EOS_USE_ANTICHEATCLIENT_NULL"] = "1"
        }

        // Apple's D3DMetal (Game Porting Toolkit) — real Direct3D 9/10/11/12 → Metal.
        // Force Wine's builtin d3d DLLs which bridge to D3DMetal (NOT DXVK), and
        // point the dynamic loader at the D3DMetal framework. This is the proven
        // working path for D3D games on Apple Silicon.
        let gptkExternal = "/Applications/Game Porting Toolkit.app/Contents/Resources/wine/lib/external"
        if FileManager.default.fileExists(atPath: gptkExternal) {
            var overrides = env["WINEDLLOVERRIDES"] ?? ""
            if !overrides.isEmpty { overrides += ";" }
            // =b forces builtin (D3DMetal bridge); dcomp stubbed; suppress popups
            overrides += "d3d9=b;d3d10core=b;d3d11=b;d3d12=b;d3d12core=b;dxgi=b;dcomp=;winemenubuilder.exe=d"
            env["WINEDLLOVERRIDES"] = overrides
            env["DYLD_FALLBACK_LIBRARY_PATH"] = "\(gptkExternal):/usr/lib:/usr/local/lib"
            // Apple's Metal Performance HUD — real FPS / frame-time / GPU stats
            // drawn directly on the game's Metal layer (the in-window perf HUD).
            // Toggleable via the "metalHUD" preference (default on).
            let metalHUD = UserDefaults.standard.object(forKey: "metalHUD") as? Bool ?? true
            env["MTL_HUD_ENABLED"] = metalHUD ? "1" : "0"
            env["WINEDEBUG"] = "-all"
        }
        return env
    }

    // Returns the real steam.exe path inside the prefix (after SteamSetup installs Steam)
    nonisolated func resolvedSteamExe(for game: Game) -> String {
        guard DetectionService.isSteam(exePath: game.exePath) else { return game.exePath }
        let name = URL(fileURLWithPath: game.exePath).lastPathComponent.lowercased()
        // If it's already steam.exe (not the setup), use as-is
        if name == "steam.exe" { return game.exePath }
        // After SteamSetup runs, steam.exe is at C:\Program Files (x86)\Steam\steam.exe
        let installedSteam = game.resolvedPrefixPath + "/drive_c/Program Files (x86)/Steam/steam.exe"
        return FileManager.default.fileExists(atPath: installedSteam) ? installedSteam : game.exePath
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
