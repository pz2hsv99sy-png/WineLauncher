import Foundation

// What the scanner found inside the .exe
struct GameDetection: Codable {
    var arch: String = "unknown"          // "x86" or "x64"
    var directX: String = "unknown"       // "dx9" "dx11" "dx12"
    var antiCheat: String? = nil          // "EAC" "BattlEye" nil
    var needsVKD3D: Bool = false
    var needsDXVK: Bool = false
    var notes: [String] = []
}

enum GameKind: String, Codable {
    case game = "Game"
    case steam = "Steam"    // Steam for Windows — gets full prereq treatment
}

// Platform a game runs on. Windows games go through Wine; native macOS/Linux
// games run directly. Used to label and group games in the sidebar.
enum GameOS: String, Codable, CaseIterable {
    case windows = "Windows"
    case macos   = "macOS"
    case linux   = "Linux"

    var symbol: String {
        switch self {
        case .windows: return "pc"
        case .macos:   return "apple.logo"
        case .linux:   return "terminal"
        }
    }
}

enum SetupStatus: String, Codable {
    case notSetup = "Not set up"
    case installing = "Installing tools…"
    case ready = "Ready"
    case error = "Error"
}

struct Game: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var exePath: String
    var prefixPath: String
    var kind: GameKind = .game
    var os: GameOS = .windows
    var coverImagePath: String = ""
    var detection: GameDetection = GameDetection()
    var setupStatus: SetupStatus = .notSetup
    var setupError: String = ""
    var lastPlayed: Date? = nil
    var totalPlaytime: TimeInterval = 0     // accumulated seconds played

    var lastPlayedFormatted: String {
        guard let d = lastPlayed else { return "Never played" }
        let fmt = RelativeDateTimeFormatter()
        return fmt.localizedString(for: d, relativeTo: Date())
    }

    // "12h 30m", "45m", or "—" when never played.
    var playtimeFormatted: String {
        guard totalPlaytime > 0 else { return "—" }
        let h = Int(totalPlaytime) / 3600
        let m = (Int(totalPlaytime) % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    var playedThisMonth: Bool {
        guard let d = lastPlayed else { return false }
        return Calendar.current.isDate(d, equalTo: Date(), toGranularity: .month)
    }

    // Tolerant decoding: missing keys fall back to defaults so adding new
    // fields never wipes the saved library.
    enum CodingKeys: String, CodingKey {
        case id, name, exePath, prefixPath, kind, os, coverImagePath
        case detection, setupStatus, setupError, lastPlayed, totalPlaytime
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "Game"
        exePath = (try? c.decode(String.self, forKey: .exePath)) ?? ""
        prefixPath = (try? c.decode(String.self, forKey: .prefixPath)) ?? ""
        kind = (try? c.decode(GameKind.self, forKey: .kind)) ?? .game
        os = (try? c.decode(GameOS.self, forKey: .os)) ?? .windows
        coverImagePath = (try? c.decode(String.self, forKey: .coverImagePath)) ?? ""
        detection = (try? c.decode(GameDetection.self, forKey: .detection)) ?? GameDetection()
        setupStatus = (try? c.decode(SetupStatus.self, forKey: .setupStatus)) ?? .notSetup
        setupError = (try? c.decode(String.self, forKey: .setupError)) ?? ""
        lastPlayed = try? c.decodeIfPresent(Date.self, forKey: .lastPlayed)
        totalPlaytime = (try? c.decode(TimeInterval.self, forKey: .totalPlaytime)) ?? 0
    }

    init(name: String, exePath: String, prefixPath: String) {
        self.name = name
        self.exePath = exePath
        self.prefixPath = prefixPath
    }

    // Default prefix next to the exe if not set
    var resolvedPrefixPath: String {
        if !prefixPath.isEmpty { return prefixPath }
        let dir = URL(fileURLWithPath: exePath).deletingLastPathComponent()
        return dir.appendingPathComponent("wineprefix").path
    }
}
