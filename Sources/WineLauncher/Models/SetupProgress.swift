import Foundation

struct SetupProgress {
    var current: Int = 0
    var total: Int = 0
    var currentPackage: String = ""
    var startTime: Date = Date()

    var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(current) / Double(total)
    }

    var estimatedSecondsRemaining: Double? {
        guard current > 0, total > 0 else { return nil }
        let elapsed = Date().timeIntervalSince(startTime)
        let perItem = elapsed / Double(current)
        return perItem * Double(total - current)
    }

    var etaString: String {
        guard let secs = estimatedSecondsRemaining, secs > 0 else { return "Calculating…" }
        if secs < 60 { return "~\(Int(secs))s remaining" }
        let mins = Int(secs / 60)
        let s = Int(secs) % 60
        return s > 0 ? "~\(mins)m \(s)s remaining" : "~\(mins)m remaining"
    }

    var isComplete: Bool { total > 0 && current >= total }
}
