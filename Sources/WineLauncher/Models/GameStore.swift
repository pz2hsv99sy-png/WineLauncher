import Foundation
import Combine

@MainActor
class GameStore: ObservableObject {
    @Published var games: [Game] = []
    @Published var runningGameID: UUID? = nil
    @Published var launchLog: String = ""

    private let saveURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("WineLauncher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("games.json")
    }()

    private var launchProcess: Process? = nil

    init() { load() }

    // Called when user adds an .exe — scans + auto-sets up
    func addAndSetup(exePath: String) {
        let name = URL(fileURLWithPath: exePath)
            .deletingLastPathComponent()
            .lastPathComponent
        var game = Game(name: name, exePath: exePath, prefixPath: "")
        game.detection = DetectionService.detect(exePath: exePath)
        game.setupStatus = .installing
        games.append(game)
        save()

        let id = game.id
        Task {
            await runSetup(gameID: id)
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

    func reRunSetup(id: UUID) {
        guard let i = games.firstIndex(where: { $0.id == id }) else { return }
        games[i].setupStatus = .installing
        games[i].setupError = ""
        save()
        Task { await runSetup(gameID: id) }
    }

    // MARK: - Setup pipeline

    private func runSetup(gameID: UUID) async {
        guard let game = games.first(where: { $0.id == gameID }) else { return }

        var log = ""
        let logCB: (String) -> Void = { [weak self] str in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let i = self.games.firstIndex(where: { $0.id == gameID }) {
                    self.games[i].setupError = log  // reuse setupError as install log while installing
                }
                log += str
            }
        }

        logCB("Scanning \(game.name)...\n")
        logCB("  Arch: \(game.detection.arch)  |  DirectX: \(game.detection.directX)\n")
        if let ac = game.detection.antiCheat { logCB("  Anti-cheat: \(ac)\n") }
        logCB("\n")

        guard let winePath = await SetupService.shared.ensureWine(log: logCB) else {
            markError(id: gameID, msg: "Wine installation failed. Open Terminal and run: brew install --cask wine-stable")
            return
        }

        let _ = await SetupService.shared.ensureWinetricks(log: logCB)

        let ok = await SetupService.shared.setupPrefix(for: game, winePath: winePath, log: logCB)
        if !ok {
            markError(id: gameID, msg: "Prefix setup failed. Check the log for details.")
            return
        }

        // All good
        if let i = games.firstIndex(where: { $0.id == gameID }) {
            games[i].setupStatus = .ready
            games[i].setupError = log
            save()
        }
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
