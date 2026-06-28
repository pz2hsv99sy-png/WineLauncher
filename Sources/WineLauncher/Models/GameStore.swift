import Foundation
import Combine
import SwiftUI

@MainActor
class GameStore: ObservableObject {
    @Published var games: [Game] = []
    @Published var runningGameID: UUID? = nil
    @Published var launchLog: String = ""
    @Published var setupProgress: [UUID: SetupProgress] = [:]
    @Published var hudCorner: HUDCorner = HUDCorner(rawValue: UserDefaults.standard.string(forKey: "hudCorner") ?? "") ?? .topRight

    private var setupTasks: [UUID: Task<Void, Never>] = [:]

    var hudCornerBinding: Binding<HUDCorner> {
        Binding(get: { self.hudCorner }, set: { v in
            self.hudCorner = v
            UserDefaults.standard.set(v.rawValue, forKey: "hudCorner")
        })
    }

    private let saveURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("WineLauncher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("games.json")
    }()

    private var launchProcess: Process? = nil

    init() { load() }

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

        // All good
        if let i = games.firstIndex(where: { $0.id == gameID }) {
            games[i].setupStatus = .ready
            games[i].setupError = log
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
        HUDWindowController.shared.show(gameName: game.name, corner: hudCorner)

        let candidates = ["/opt/homebrew/bin/wine", "/usr/local/bin/wine", "/usr/bin/wine"]
        guard let winePath = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            launchLog = "Wine not found. Run setup again."
            runningGameID = nil
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: winePath)
        process.arguments = [game.exePath]
        process.environment = SetupService.shared.launchEnvSync(for: game)

        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let s = String(data: h.availableData, encoding: .utf8), !s.isEmpty else { return }
            Task { @MainActor [weak self] in self?.launchLog += s }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let s = String(data: h.availableData, encoding: .utf8), !s.isEmpty else { return }
            Task { @MainActor [weak self] in self?.launchLog += s }
        }

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                guard let self else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                self.launchLog += "\n[Exited with code \(proc.terminationStatus)]"
                self.runningGameID = nil
                HUDWindowController.shared.hide()
                if var g = self.games.first(where: { $0.id == game.id }) {
                    g.lastPlayed = Date()
                    self.update(game: g)
                }
            }
        }

        let envSummary = process.environment?
            .filter { ["WINEPREFIX","WINEMSYNC","DXVK_ASYNC","PROTON_EAC_RUNTIME"].contains($0.key) }
            .map { "\($0.key)=\($0.value)" }.joined(separator: "  ") ?? ""
        launchLog = "Launching \(game.name)...\n\(envSummary)\n\n"

        do { try process.run(); launchProcess = process }
        catch { launchLog += "Launch failed: \(error)"; runningGameID = nil }
    }

    func stopRunning() {
        launchProcess?.terminate()
        launchProcess = nil
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
    }
}
