import Foundation

// A Wine bottle = a named prefix that can hold several pieces of software.
// The launcher is now bottle-first: you create a bottle, then add software
// (games / apps) into it.
struct Bottle: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var prefixPath: String
    var os: GameOS = .windows

    enum CodingKeys: String, CodingKey { case id, name, prefixPath, os }

    init(name: String, prefixPath: String, os: GameOS = .windows) {
        self.name = name
        self.prefixPath = prefixPath
        self.os = os
    }

    // Tolerant decoding so adding fields never wipes saved bottles.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "Bottle"
        prefixPath = (try? c.decode(String.self, forKey: .prefixPath)) ?? ""
        os = (try? c.decode(GameOS.self, forKey: .os)) ?? .windows
    }
}
