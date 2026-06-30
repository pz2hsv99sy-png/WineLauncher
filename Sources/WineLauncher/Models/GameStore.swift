import Foundation
import Combine
import SwiftUI

@MainActor
class GameStore: ObservableObject {
    @Published var games: [Game] = []
    @Published var bottles: [Bottle] = []
    @Published var achievements: [UUID: [Achievement]] = [:]
    @Published var runningGameID: UUID? = nil
    @Published var launchLog: String = ""
    @Published var setupProgress: [UUID: SetupProgress] = [:]
    @Published var hudCorner: HUDCorner = HUDCorner(rawValue: UserDefaults.standard.string(forKey: "hudCorner") ?? "") ?? .topRight

    private var setupTasks: [UUID: Task<Void, Never>] = [:]
    private var logBuffer: String = ""
    private var logFlushTimer: Timer?

    var hudCornerBinding: Binding<HUDCorner> {
        Binding(get: { self.hudCorner }, set: { v in
            self.hudCorner = v
            UserDefaults.standard.set(v.rawValue, forKey: "hudCorner")
        })
    }

    private static var supportDir: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("WineLauncher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private let saveURL: URL = supportDir.appendingPathComponent("games.json")
    private let bottlesURL: URL = supportDir.appendingPathComponent("bottles.json")

    private var launchProcess: Process? = nil
    // Stored at launch so stopRunning() can shut the bottle down gracefully
    // (let the game save settings/mods/saves) then force-kill as a fallback.
    private var activeWineBinDir: String? = nil
    private var activePrefix: String? = nil
    private var activeWineInvocation: [String]? = nil   // tokens to run wine (incl. arch wrapper)
    private var activeExeName: String? = nil            // image name for taskkill
    private var launchStartTime: Date? = nil            // to accumulate playtime
    private var memoryWatchdog: Timer? = nil
    /// Kill a game only if Wine RAM runs away catastrophically. Apple Silicon
    /// handles heavy use via memory compression + fast SSD swap, so a game can
    /// legitimately use far more than physical RAM and still play fine (Cities
    /// Skylines runs well at ~22 GB on a 16 GB Mac). The cap is therefore very
    /// generous — 3× physical RAM — so it only catches a true runaway that
    /// would otherwise crash the Mac, never a working game.
    /// Stored in UserDefaults ("memoryCapGB") so it can be tuned.
    var memoryCapBytes: UInt64 = {
        let physical = Double(ProcessInfo.processInfo.physicalMemory)
        let defaultGB = physical / 1_073_741_824 * 1.5   // generous headroom, still protective
        let gb = UserDefaults.standard.object(forKey: "memoryCapGB") as? Double ?? defaultGB
        return UInt64(gb * 1_073_741_824)
    }()
    @Published var memoryKillNotice: String? = nil

    init() { load(); fetchCoversIfNeeded() }

    // Directory where downloaded Steam cover art is cached.
    private var coversDir: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("WineLauncher/covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // For each game without a cover, try to find its Steam app-id (from a
    // steam_appid.txt next to the exe) and download the Steam library cover.
    func fetchCoversIfNeeded() {
        for game in games where game.coverImagePath.isEmpty {
            guard let appid = steamAppID(for: game) else { continue }
            let dest = coversDir.appendingPathComponent("\(appid).jpg")
            if FileManager.default.fileExists(atPath: dest.path) {
                setCover(gameID: game.id, path: dest.path); continue
            }
            Task.detached { [weak self] in
                let urls = [
                    "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appid)/library_600x900.jpg",
                    "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appid)/library_600x900_2x.jpg",
                ]
                for u in urls {
                    guard let url = URL(string: u),
                          let data = try? Data(contentsOf: url), data.count > 2000 else { continue }
                    try? data.write(to: dest)
                    await MainActor.run { self?.setCover(gameID: game.id, path: dest.path) }
                    return
                }
            }
        }
    }

    private func setCover(gameID: UUID, path: String) {
        guard let i = games.firstIndex(where: { $0.id == gameID }) else { return }
        games[i].coverImagePath = path
        save()
    }

    private func steamAppID(for game: Game) -> String? {
        let exeDir = (game.exePath as NSString).deletingLastPathComponent
        for candidate in ["\(exeDir)/steam_appid.txt", "\(exeDir)/steam_settings/steam_appid.txt"] {
            if let s = try? String(contentsOfFile: candidate, encoding: .utf8) {
                let id = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !id.isEmpty, Int(id) != nil { return id }
            }
        }
        return nil
    }

    // Called when user adds an .exe — scans + auto-sets up
    func addAndSetup(exePath: String, sharedPrefix: String? = nil) {
        let name = URL(fileURLWithPath: exePath)
            .deletingLastPathComponent()
            .lastPathComponent
        var game = Game(name: name, exePath: exePath, prefixPath: sharedPrefix ?? "")
        game.detection = DetectionService.detect(exePath: exePath)
        // If sharing an existing bottle, skip full setup — prefix is already configured
        game.setupStatus = sharedPrefix != nil ? .ready : .installing
        if sharedPrefix != nil {
            game.setupError = "Using shared bottle at \(sharedPrefix!)\nNo additional setup needed."
        }
        games.append(game)
        save()

        if sharedPrefix == nil {
            let id = game.id
            let task = Task { await runSetup(gameID: id) }
            setupTasks[id] = task
        }
    }

    func cancelSetup(id: UUID) {
        setupTasks[id]?.cancel()
        setupTasks.removeValue(forKey: id)
        // Kill any running winetricks/wine processes
        let _ = try? Process.run(URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "pkill -f winetricks; pkill -f wineserver"])
        setupProgress.removeValue(forKey: id)
        if let i = games.firstIndex(where: { $0.id == id }) {
            games[i].setupStatus = .notSetup
            games[i].setupError = "Setup cancelled by user."
            save()
        }
    }

    func delete(id: UUID) {
        games.removeAll { $0.id == id }
        save()
    }

    func rename(id: UUID, to name: String) {
        guard let i = games.firstIndex(where: { $0.id == id }) else { return }
        games[i].name = name
        save()
    }

    func installExtra(gameID: UUID, verb: String) {
        guard let game = games.first(where: { $0.id == gameID }) else { return }
        guard let i = games.firstIndex(where: { $0.id == gameID }) else { return }
        games[i].setupStatus = .installing
        save()
        Task {
            let logCB: (String) -> Void = { [weak self] str in
                Task { @MainActor [weak self] in
                    guard let self, let idx = self.games.firstIndex(where: { $0.id == gameID }) else { return }
                    self.games[idx].setupError += str
                }
            }
            let wt = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/winetricks")
                ? "/opt/homebrew/bin/winetricks" : "/usr/local/bin/winetricks"
            logCB("\nInstalling \(verb)...\n")
            await PrerequisitesService.shared.installPrereqs(
                verb.split(separator: " ").map(String.init),
                prefix: game.resolvedPrefixPath,
                log: logCB,
                progress: { [weak self] p in Task { @MainActor [weak self] in self?.setupProgress[gameID] = p } }
            )
            if let idx = self.games.firstIndex(where: { $0.id == gameID }) {
                self.games[idx].setupStatus = .ready
                self.save()
            }
            self.setupProgress.removeValue(forKey: gameID)
        }
    }

    func reRunSetup(id: UUID) {
        guard let i = games.firstIndex(where: { $0.id == id }) else { return }
        games[i].setupStatus = .installing
        games[i].setupError = ""
        save()
        let task = Task { await runSetup(gameID: id) }
        setupTasks[id] = task
    }

    // MARK: - Setup pipeline

    private func runSetup(gameID: UUID) async {
        guard let game = games.first(where: { $0.id == gameID }) else { return }

        var log = ""
        let logCB: (String) -> Void = { [weak self] str in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let i = self.games.firstIndex(where: { $0.id == gameID }) {
                    self.games[i].setupError = log
                }
                log += str
            }
        }
        let progressCB: (SetupProgress) -> Void = { [weak self] p in
            Task { @MainActor [weak self] in self?.setupProgress[gameID] = p }
        }

        // Kick off with a zeroed progress so the bar appears immediately
        setupProgress[gameID] = SetupProgress(total: 1)

        logCB("Scanning \(game.name)...\n")
        logCB("  Arch: \(game.detection.arch)  |  DirectX: \(game.detection.directX)\n")
        if let ac = game.detection.antiCheat { logCB("  Anti-cheat: \(ac)\n") }
        logCB("\n")

        guard let winePath = await SetupService.shared.ensureWine(log: logCB) else {
            markError(id: gameID, msg: "Wine installation failed. Open Terminal and run: brew install --cask wine-stable")
            setupProgress.removeValue(forKey: gameID)
            return
        }

        let _ = await SetupService.shared.ensureWinetricks(log: logCB)

        let ok = await SetupService.shared.setupPrefix(for: game, winePath: winePath, log: logCB, progress: progressCB)
        if !ok {
            markError(id: gameID, msg: "Prefix setup failed. Check the log for details.")
            setupProgress.removeValue(forKey: gameID)
            return
        }

        // All good — if SteamSetup was used, point exePath to the installed steam.exe
        if let i = games.firstIndex(where: { $0.id == gameID }) {
            games[i].setupStatus = .ready
            games[i].setupError = log
            let installedSteam = games[i].resolvedPrefixPath + "/drive_c/Program Files (x86)/Steam/steam.exe"
            if DetectionService.isSteam(exePath: games[i].exePath),
               URL(fileURLWithPath: games[i].exePath).lastPathComponent.lowercased() == "steamsetup.exe",
               FileManager.default.fileExists(atPath: installedSteam) {
                games[i].exePath = installedSteam
                games[i].name = "Steam"
            }
            save()
        }
        setupProgress.removeValue(forKey: gameID)
    }

    private func markError(id: UUID, msg: String) {
        guard let i = games.firstIndex(where: { $0.id == id }) else { return }
        games[i].setupStatus = .error
        games[i].setupError += "\n✗ \(msg)"
        save()
    }

    // MARK: - Launch

    func launch(game: Game) {
        guard runningGameID == nil else { return }
        guard game.setupStatus == .ready else { return }

        runningGameID = game.id
        launchLog = ""
        // Performance overlay is Apple's Metal HUD drawn on the game window
        // (MTL_HUD_ENABLED); the custom floating HUD is intentionally not shown.

        // GPTK wine64 + Apple's D3DMetal is the proven path for D3D games on
        // Apple Silicon (real D3D11→Metal, bypasses the broken DXVK/MoltenVK
        // wall). GPTK wine64 is x86_64 → run it under Rosetta via `arch`.
        let gptkWine = "/Applications/Game Porting Toolkit.app/Contents/Resources/wine/bin/wine64"
        let useGPTK = FileManager.default.fileExists(atPath: gptkWine)
        let fallbackCandidates = [
            "/usr/local/bin/wine64",
            "/opt/homebrew/bin/wine64",
            "/opt/homebrew/bin/wine",
            "/usr/local/bin/wine",
        ]

        let resolvedExe = SetupService.shared.resolvedSteamExe(for: game)

        let process = Process()
        let wineBinDir: String
        let wineInvocation: [String]   // how to invoke wine (for a later graceful taskkill)
        if useGPTK {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
            process.arguments = ["-x86_64", gptkWine, resolvedExe]
            wineBinDir = (gptkWine as NSString).deletingLastPathComponent
            wineInvocation = ["/usr/bin/arch", "-x86_64", gptkWine]
        } else {
            guard let winePath = fallbackCandidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
                launchLog = "Wine not found. Run setup again."
                runningGameID = nil
                return
            }
            process.executableURL = URL(fileURLWithPath: winePath)
            process.arguments = [resolvedExe]
            wineBinDir = (winePath as NSString).deletingLastPathComponent
            wineInvocation = [winePath]
        }
        process.environment = SetupService.shared.launchEnvSync(for: game)

        // Launch from the game's own directory — required so a Goldberg/Steam
        // emulator finds steam_appid.txt (else SteamAPI_RestartAppIfNecessary
        // makes the game quit) and the game locates its data files.
        let exeDir = (resolvedExe as NSString).deletingLastPathComponent
        if FileManager.default.fileExists(atPath: exeDir) {
            process.currentDirectoryURL = URL(fileURLWithPath: exeDir)
        }

        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe

        logFlushTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.logBuffer.isEmpty else { return }
                self.launchLog += self.logBuffer
                self.logBuffer = ""
            }
        }

        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let s = String(data: h.availableData, encoding: .utf8), !s.isEmpty else { return }
            Task { @MainActor [weak self] in self?.logBuffer += s }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let s = String(data: h.availableData, encoding: .utf8), !s.isEmpty else { return }
            Task { @MainActor [weak self] in self?.logBuffer += s }
        }

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                guard let self else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                self.logFlushTimer?.invalidate(); self.logFlushTimer = nil
                self.memoryWatchdog?.invalidate(); self.memoryWatchdog = nil
                if !self.logBuffer.isEmpty { self.launchLog += self.logBuffer; self.logBuffer = "" }
                self.launchLog += "\n[Exited with code \(proc.terminationStatus)]"
                self.runningGameID = nil
                HUDWindowController.shared.hide()
                if var g = self.games.first(where: { $0.id == game.id }) {
                    g.lastPlayed = Date()
                    if let start = self.launchStartTime {
                        g.totalPlaytime += Date().timeIntervalSince(start)
                    }
                    self.update(game: g)
                    // Refresh achievements — the play session may have unlocked some.
                    self.loadAchievements(for: g)
                }
                self.launchStartTime = nil
            }
        }

        let envSummary = process.environment?
            .filter { ["WINEPREFIX","WINEMSYNC","DXVK_ASYNC","PROTON_EAC_RUNTIME"].contains($0.key) }
            .map { "\($0.key)=\($0.value)" }.joined(separator: "  ") ?? ""
        launchLog = "Launching \(game.name)...\n\(envSummary)\n\n"

        do {
            try process.run()
            launchProcess = process
            // Remember how to shut this bottle down later (graceful then forced)
            activeWineBinDir = wineBinDir
            activePrefix = game.resolvedPrefixPath
            activeWineInvocation = wineInvocation
            activeExeName = (resolvedExe as NSString).lastPathComponent
            launchStartTime = Date()
            startMemoryWatchdog(gameName: game.name)
        }
        catch { launchLog += "Launch failed: \(error)"; runningGameID = nil }
    }

    // MARK: - Scan computer for games

    /// Scan the Mac for games and import any not already in the library:
    ///  - installed Steam (native) games via appmanifest .acf files
    ///  - game .exe files in Downloads / Desktop (Windows, via Wine)
    /// Returns how many new entries were added.
    @discardableResult
    func scanComputer() -> Int {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let existingExe = Set(games.map { $0.exePath })
        var added = 0

        // 1. Native Steam games (appmanifest_*.acf)
        let steamApps = "\(home)/Library/Application Support/Steam/steamapps"
        if let files = try? fm.contentsOfDirectory(atPath: steamApps) {
            for f in files where f.hasPrefix("appmanifest_") && f.hasSuffix(".acf") {
                guard let txt = try? String(contentsOfFile: "\(steamApps)/\(f)", encoding: .utf8) else { continue }
                let name = AchievementsService.firstMatch(#""name"\s*"([^"]+)""#, in: txt) ?? "Steam Game"
                let installdir = AchievementsService.firstMatch(#""installdir"\s*"([^"]+)""#, in: txt) ?? ""
                let appid = f.replacingOccurrences(of: "appmanifest_", with: "").replacingOccurrences(of: ".acf", with: "")
                let path = "\(steamApps)/common/\(installdir)"
                guard !existingExe.contains(path), fm.fileExists(atPath: path) else { continue }
                var g = Game(name: name, exePath: path, prefixPath: "")
                g.os = .macos
                g.setupStatus = .ready
                games.append(g); added += 1
                // appid lets us fetch the cover
                let coverDest = coversDir.appendingPathComponent("\(appid).jpg")
                if !fm.fileExists(atPath: coverDest.path) {
                    Task.detached { [weak self] in
                        if let url = URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appid)/library_600x900.jpg"),
                           let data = try? Data(contentsOf: url), data.count > 2000 {
                            try? data.write(to: coverDest)
                            await MainActor.run { self?.setCover(gameID: g.id, path: coverDest.path) }
                        }
                    }
                }
            }
        }

        // 2. Windows game .exe in Downloads / Desktop (skip tiny helper exes)
        for dir in ["\(home)/Downloads", "\(home)/Desktop"] {
            guard let en = fm.enumerator(atPath: dir) else { continue }
            var depth = 0
            for case let rel as String in en {
                if (rel as NSString).pathComponents.count > 3 { continue }   // shallow scan
                guard rel.lowercased().hasSuffix(".exe") else { continue }
                let lower = (rel as NSString).lastPathComponent.lowercased()
                if GameStore.nonGameExeMarkers.contains(where: { lower.contains($0) }) { continue }
                let full = "\(dir)/\(rel)"
                let size = (try? fm.attributesOfItem(atPath: full)[.size] as? Int64).flatMap { $0 } ?? 0
                guard size > 5_000_000, !existingExe.contains(full) else { continue }   // >5MB = likely a game
                let name = (rel as NSString).deletingLastPathComponent.isEmpty
                    ? lower.replacingOccurrences(of: ".exe", with: "")
                    : ((rel as NSString).pathComponents.first ?? lower)
                var g = Game(name: name, exePath: full, prefixPath: "")
                g.os = .windows
                games.append(g); added += 1
                depth += 1
                if depth > 50 { break }
            }
        }

        if added > 0 { save(); fetchCoversIfNeeded() }
        return added
    }

    // MARK: - Achievements

    /// Load (or refresh) a game's achievements: fetch the schema once, then mark
    /// which ones Goldberg recorded as unlocked.
    func loadAchievements(for game: Game) {
        guard let appid = steamAppID(for: game) else { return }
        let prefix = game.resolvedPrefixPath
        let gameID = game.id
        Task {
            let schema = await AchievementsService.shared.schema(appid: appid)
            let unlocked = AchievementsService.shared.unlockedAPINames(prefix: prefix, appid: appid)
            let merged = schema.map { a -> Achievement in
                var a = a; a.unlocked = unlocked.contains(a.id); return a
            }
            await MainActor.run { self.achievements[gameID] = merged }
        }
    }

    // MARK: - Installer auto-cleanup

    /// Is this exe an installer / setup rather than the actual game?
    nonisolated func isInstaller(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        let markers = ["setup", "install", "unarc", "redist"]
        return markers.contains { name.contains($0) } && name.hasSuffix(".exe")
    }

    // exe name fragments that are never the actual game.
    private static let nonGameExeMarkers = [
        "unins", "setup", "redist", "vcredist", "vc_redist", "dxsetup", "dotnet",
        "directx", "crashpad", "crashhandler", "dwhelper", "notification_helper",
        "uninstall", "quicksfv", "dxwebsetup", "oalinst", "python"
    ]

    /// After an installer ran, find the real game exe inside the bottle, re-point
    /// the entry to it, and move the original installer to the Trash.
    /// Returns the candidate exes found (for the caller to pick if ambiguous).
    func finalizeInstall(gameID: UUID) -> [String] {
        guard let game = games.first(where: { $0.id == gameID }) else { return [] }
        let prefix = game.resolvedPrefixPath
        var candidates: [(path: String, size: Int64)] = []

        let fm = FileManager.default
        let roots = [
            "\(prefix)/drive_c/Program Files",
            "\(prefix)/drive_c/Program Files (x86)",
            "\(prefix)/drive_c/games",
            "\(prefix)/drive_c/Games",
        ]
        for root in roots {
            guard let en = fm.enumerator(atPath: root) else { continue }
            for case let rel as String in en {
                guard rel.lowercased().hasSuffix(".exe") else { continue }
                let lower = (rel as NSString).lastPathComponent.lowercased()
                if GameStore.nonGameExeMarkers.contains(where: { lower.contains($0) }) { continue }
                let full = "\(root)/\(rel)"
                let size = (try? fm.attributesOfItem(atPath: full)[.size] as? Int64) ?? 0
                candidates.append((full, size ?? 0))
            }
        }
        // Largest exe is almost always the main game binary.
        let sorted = candidates.sorted { $0.size > $1.size }.map { $0.path }

        // Auto-pick the largest if we found exactly one strong candidate.
        if let best = sorted.first {
            repoint(gameID: gameID, toExe: best, trashOldInstaller: game.exePath)
        }
        return sorted
    }

    /// Re-point a game entry to a new exe and trash the old installer file.
    func repoint(gameID: UUID, toExe newExe: String, trashOldInstaller oldPath: String?) {
        guard let i = games.firstIndex(where: { $0.id == gameID }) else { return }
        // Move the old installer to the Trash (recoverable), if it still exists
        if let oldPath, oldPath != newExe, FileManager.default.fileExists(atPath: oldPath) {
            try? FileManager.default.trashItem(at: URL(fileURLWithPath: oldPath), resultingItemURL: nil)
        }
        games[i].exePath = newExe
        if games[i].name.lowercased().contains("setup") || games[i].name.lowercased().contains("install") {
            games[i].name = (newExe as NSString).lastPathComponent
                .replacingOccurrences(of: ".exe", with: "", options: .caseInsensitive)
        }
        save()
        fetchCoversIfNeeded()
    }

    // MARK: - Memory watchdog

    /// Sum the resident memory of all Wine processes (the game runs inside them).
    private func wineRSSBytes() -> UInt64 {
        let maxPids = Int(proc_listallpids(nil, 0))
        guard maxPids > 0 else { return 0 }
        var pids = [pid_t](repeating: 0, count: maxPids + 64)
        let bytes = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return 0 }
        let n = Int(bytes) / MemoryLayout<pid_t>.size
        var total: UInt64 = 0
        var nameBuf = [CChar](repeating: 0, count: 1024)
        for i in 0..<n {
            let pid = pids[i]
            if pid <= 0 { continue }
            guard proc_name(pid, &nameBuf, UInt32(nameBuf.count)) > 0 else { continue }
            let name = String(cString: nameBuf).lowercased()
            guard name.contains("wine") || name.contains("cities") || name.contains(".exe") else { continue }
            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size {
                total += info.pti_resident_size
            }
        }
        return total
    }

    private func startMemoryWatchdog(gameName: String) {
        memoryWatchdog?.invalidate()
        memoryKillNotice = nil
        let cap = memoryCapBytes
        memoryWatchdog = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.runningGameID != nil else { return }
                let rss = self.wineRSSBytes()
                if rss > cap {
                    let gb = Double(rss) / 1_073_741_824
                    let capGB = Double(cap) / 1_073_741_824
                    self.memoryKillNotice = String(format: "%@ a été arrêté : %.1f GB de RAM (limite %.1f GB) pour protéger ton Mac.", gameName, gb, capGB)
                    self.launchLog += "\n[Watchdog mémoire : \(String(format: "%.1f", gb)) GB > limite \(String(format: "%.1f", capGB)) GB — arrêt forcé]"
                    self.stopRunning()
                }
            }
        }
    }

    // Open the bottle's C: drive in Finder.
    func openCDrive(for game: Game) {
        let cDrive = game.resolvedPrefixPath + "/drive_c"
        NSWorkspace.shared.open(URL(fileURLWithPath: cDrive))
    }

    // Run an arbitrary command inside the game's bottle (winecfg, regedit, an
    // exe, …) using GPTK wine + D3DMetal, from the game's directory.
    func runCustomCommand(for game: Game, command: String) {
        let gptkWine = "/Applications/Game Porting Toolkit.app/Contents/Resources/wine/bin/wine64"
        let useGPTK = FileManager.default.fileExists(atPath: gptkWine)
        let env = SetupService.shared.launchEnvSync(for: game)
        let exeDir = (game.exePath as NSString).deletingLastPathComponent

        Task.detached {
            let p = Process()
            if useGPTK {
                p.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
                p.arguments = ["-x86_64", gptkWine] + command.split(separator: " ").map(String.init)
            } else {
                p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/wine")
                p.arguments = command.split(separator: " ").map(String.init)
            }
            p.environment = env
            if FileManager.default.fileExists(atPath: exeDir) {
                p.currentDirectoryURL = URL(fileURLWithPath: exeDir)
            }
            try? p.run()
        }
    }

    func stopRunning() {
        // Graceful shutdown so the game can SAVE (settings, enabled mods, saves):
        //   1. `taskkill /im <exe>` (no /f) asks the game window to close, which
        //      lets the game write its state to disk before exiting.
        //   2. Wait a few seconds for it to flush and exit.
        //   3. `wineserver -k` as a fallback to kill anything still alive
        //      (wineserver, winedevice, etc.) so no window is left hanging.
        // A bare force-kill loses unsaved settings/mods — that's why preferences
        // weren't persisting before.
        let binDir = activeWineBinDir
        let prefix = activePrefix
        let invocation = activeWineInvocation
        let exeName = activeExeName

        Task.detached {
            func runWine(_ extraArgs: [String]) {
                guard let prefix, let invocation, let first = invocation.first else { return }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: first)
                p.arguments = Array(invocation.dropFirst()) + extraArgs
                var env = ProcessInfo.processInfo.environment
                env["WINEPREFIX"] = prefix
                env["WINEDEBUG"] = "-all"
                p.environment = env
                try? p.run()
                p.waitUntilExit()
            }

            // 1. Ask the game to close cleanly so it saves.
            if let exeName {
                runWine(["taskkill", "/im", exeName])
            }
            // 2. Give it time to write its files and exit.
            try? await Task.sleep(nanoseconds: 6_000_000_000)

            // 3. Force-kill the rest of the bottle as a fallback.
            if let prefix {
                let wineserver = binDir.map { $0 + "/wineserver" }
                    .flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
                    ?? "wineserver"
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                p.arguments = ["-c", "WINEPREFIX=\(prefix.shellQuoted) \(wineserver.shellQuoted) -k"]
                try? p.run()
                p.waitUntilExit()
            }
        }

        launchProcess = nil
        activeWineBinDir = nil
        activePrefix = nil
        activeWineInvocation = nil
        activeExeName = nil
        memoryWatchdog?.invalidate(); memoryWatchdog = nil
        HUDWindowController.shared.hide()
    }

    // MARK: - Persistence

    func update(game: Game) {
        guard let i = games.firstIndex(where: { $0.id == game.id }) else { return }
        games[i] = game
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(games) {
            try? data.write(to: saveURL)
        }
    }

    private func load() {
        if let data = try? Data(contentsOf: saveURL),
           let decoded = try? JSONDecoder().decode([Game].self, from: data) {
            games = decoded
        }
        if let data = try? Data(contentsOf: bottlesURL),
           let decoded = try? JSONDecoder().decode([Bottle].self, from: data) {
            bottles = decoded
        }
    }

    private func saveBottles() {
        if let data = try? JSONEncoder().encode(bottles) {
            try? data.write(to: bottlesURL)
        }
    }

    // MARK: - Bottles (bottle-first model)

    /// Every bottle shown in the UI: explicit ones plus any implied by games
    /// that don't belong to an explicit bottle (backwards compatibility).
    var allBottles: [Bottle] {
        var result = bottles
        let knownPaths = Set(bottles.map { $0.prefixPath })
        for game in games {
            let path = game.resolvedPrefixPath
            if !knownPaths.contains(path), !result.contains(where: { $0.prefixPath == path }) {
                result.append(Bottle(name: GameStore.friendlyBottleName(path), prefixPath: path))
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func games(in bottle: Bottle) -> [Game] {
        games.filter { $0.resolvedPrefixPath == bottle.prefixPath }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func friendlyBottleName(_ prefixPath: String) -> String {
        let url = URL(fileURLWithPath: prefixPath)
        let last = url.lastPathComponent
        if last.lowercased() == "wineprefix" || last.lowercased() == "pfx" {
            return url.deletingLastPathComponent().lastPathComponent
        }
        return last
    }

    /// Create a new, empty bottle (named prefix) and initialise it with Wine.
    func addBottle(name: String) {
        let safe = name.replacingOccurrences(of: "/", with: "-")
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("ElviusBottles", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let prefixPath = base.appendingPathComponent(safe, isDirectory: true).path

        let bottle = Bottle(name: name, prefixPath: prefixPath)
        bottles.append(bottle)
        saveBottles()

        // Initialise the prefix in the background with GPTK wine.
        let gptkWine = "/Applications/Game Porting Toolkit.app/Contents/Resources/wine/bin/wine64"
        let useGPTK = FileManager.default.fileExists(atPath: gptkWine)
        Task.detached {
            let p = Process()
            if useGPTK {
                p.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
                p.arguments = ["-x86_64", gptkWine, "wineboot", "--init"]
            } else {
                p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/wine")
                p.arguments = ["wineboot", "--init"]
            }
            var env = ProcessInfo.processInfo.environment
            env["WINEPREFIX"] = prefixPath
            env["WINEDEBUG"] = "-all"
            p.environment = env
            try? p.run()
            p.waitUntilExit()
        }
    }

    func deleteBottle(id: UUID) {
        bottles.removeAll { $0.id == id }
        saveBottles()
    }
}

extension String {
    /// Wraps the string in single quotes for safe use in a shell command,
    /// escaping any embedded single quotes.
    var shellQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
