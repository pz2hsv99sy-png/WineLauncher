import Foundation

// Fetches a game's achievement schema by combining two keyless Steam sources:
//  - GetGlobalAchievementPercentagesForApp → apiName + global % (schema order
//    is %-descending)
//  - the public community achievements page → display name, description, icon
//    (also %-descending), so the two align by index.
// Unlock state is read from the local Goldberg (gbe_fork) save.
actor AchievementsService {
    static let shared = AchievementsService()

    private var cacheDir: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("WineLauncher/achievements", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Returns the achievement schema for an app id (cached after first fetch).
    func schema(appid: String) async -> [Achievement] {
        let cache = cacheDir.appendingPathComponent("\(appid).json")
        if let data = try? Data(contentsOf: cache),
           let decoded = try? JSONDecoder().decode([Achievement].self, from: data), !decoded.isEmpty {
            return decoded
        }
        let fetched = await fetchSchema(appid: appid)
        if !fetched.isEmpty, let data = try? JSONEncoder().encode(fetched) {
            try? data.write(to: cache)
        }
        return fetched
    }

    private func fetchSchema(appid: String) async -> [Achievement] {
        // 1. Global % API → ordered apiNames + percent
        var apiNames: [(name: String, pct: Double)] = []
        let pctURL = URL(string: "https://api.steampowered.com/ISteamUserStats/GetGlobalAchievementPercentagesForApp/v0002/?gameid=\(appid)&format=json")!
        if let (data, _) = try? await URLSession.shared.data(from: pctURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let ach = (obj["achievementpercentages"] as? [String: Any])?["achievements"] as? [[String: Any]] {
            for a in ach {
                if let n = a["name"] as? String {
                    let p = (a["percent"] as? Double) ?? Double("\(a["percent"] ?? "0")") ?? 0
                    apiNames.append((n, p))
                }
            }
        }

        // 2. Community page → ordered (name, desc, icon)
        var display: [(name: String, desc: String, icon: String)] = []
        let pageURL = URL(string: "https://steamcommunity.com/stats/\(appid)/achievements/")!
        var req = URLRequest(url: pageURL)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        if let (data, _) = try? await URLSession.shared.data(for: req),
           let html = String(data: data, encoding: .utf8) {
            display = AchievementsService.parsePage(html)
        }

        // 3. Zip by index (both %-descending)
        let count = max(apiNames.count, display.count)
        guard count > 0 else { return [] }
        var result: [Achievement] = []
        for i in 0..<count {
            let api = i < apiNames.count ? apiNames[i] : (name: "ach_\(i)", pct: 0)
            let d = i < display.count ? display[i] : (name: api.name, desc: "", icon: "")
            result.append(Achievement(id: api.name, name: d.name, desc: d.desc,
                                      iconURL: d.icon, globalPercent: api.pct))
        }
        return result
    }

    nonisolated static func parsePage(_ html: String) -> [(name: String, desc: String, icon: String)] {
        var out: [(String, String, String)] = []
        // Split on achieveRow blocks
        let rows = html.components(separatedBy: "achieveRow")
        for row in rows.dropFirst() {
            guard let icon = firstMatch(#"<img[^>]+src="([^"]+)""#, in: row),
                  let name = firstMatch(#"<h3>(.*?)</h3>"#, in: row) else { continue }
            let desc = firstMatch(#"<h5>(.*?)</h5>"#, in: row) ?? ""
            out.append((name.htmlDecoded, desc.htmlDecoded, icon))
        }
        return out
    }

    nonisolated static func firstMatch(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// apiNames Goldberg recorded as unlocked for this game.
    nonisolated func unlockedAPINames(prefix: String, appid: String) -> Set<String> {
        let candidates = [
            "\(prefix)/drive_c/users/crossover/AppData/Roaming/GSE Saves/\(appid)/achievements.json",
            "\(prefix)/drive_c/users/chacha/AppData/Roaming/GSE Saves/\(appid)/achievements.json",
        ]
        for path in candidates {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            var unlocked = Set<String>()
            for (key, val) in obj {
                if let d = val as? [String: Any], (d["earned"] as? Bool) == true { unlocked.insert(key) }
            }
            return unlocked
        }
        return []
    }
}

private extension String {
    var htmlDecoded: String {
        replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}
