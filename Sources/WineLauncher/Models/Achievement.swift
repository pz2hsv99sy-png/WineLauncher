import Foundation

struct Achievement: Codable, Identifiable {
    var id: String          // apiName when known, else index-based
    var name: String
    var desc: String
    var iconURL: String
    var globalPercent: Double
    var unlocked: Bool = false
}
