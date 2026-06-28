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
    var coverImagePath: String = ""
    var detection: GameDetection = GameDetection()
    var setupStatus: SetupStatus = .notSetup
    var setupError: String = ""
    var lastPlayed: Date? = nil

    var lastPlayedFormatted: String {
        guard let d = lastPlayed else { return "Never played" }
        let fmt = RelativeDateTimeFormatter()
        return fmt.localizedString(for: d, relativeTo: Date())
    }

    // Default prefix next to the exe if not set
    var resolvedPrefixPath: String {
        if !prefixPath.isEmpty { return prefixPath }
        let dir = URL(fileURLWithPath: exePath).deletingLastPathComponent()
        return dir.appendingPathComponent("wineprefix").path
    }
}
