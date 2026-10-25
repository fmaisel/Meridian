// ProgressManager: persists the level state (mechanisms, flags, camera, position) and the settings.

import Foundation

struct Settings: Codable, Equatable {
    var music = 0.6
    var sfx = 0.8
    var shadows = true
    var turnButtons = false
    /// iOS: tactile detents, snaps and plates.
    var haptics = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        music = (try? c.decode(Double.self, forKey: .music)) ?? 0.6
        sfx = (try? c.decode(Double.self, forKey: .sfx)) ?? 0.8
        shadows = (try? c.decode(Bool.self, forKey: .shadows)) ?? true
        turnButtons = (try? c.decode(Bool.self, forKey: .turnButtons)) ?? false
        haptics = (try? c.decode(Bool.self, forKey: .haptics)) ?? true
    }
}

struct SaveData: Codable {
    var version = 1
    var state: PuzzleState
    var charNode: String
    var seenZones: [String]
    var done: Bool?
}

enum Progress {
    private static let settingsKey = "meridian.settings.v1"
    private static let completedKey = "meridian.completed.v1"

    /// Meridian keeps the key it always had, so a journey begun before the chapters existed carries on.
    private static func key(_ chapter: String) -> String {
        chapter == "meridian" ? "meridian.save.v1" : "meridian.save.\(chapter).v1"
    }

    static func load(_ chapter: String) -> SaveData? {
        guard let data = UserDefaults.standard.data(forKey: key(chapter)), let d = try? JSONDecoder().decode(SaveData.self, from: data) else { return nil }
        return d.version == 1 ? d : nil
    }

    static func save(_ chapter: String, _ d: SaveData) {
        if let data = try? JSONEncoder().encode(d) { UserDefaults.standard.set(data, forKey: key(chapter)) }
    }

    static func clear(_ chapter: String) {
        UserDefaults.standard.removeObject(forKey: key(chapter))
    }

    static func completed() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: completedKey) ?? [])
    }

    static func markCompleted(_ chapter: String) {
        var s = completed()
        s.insert(chapter)
        UserDefaults.standard.set(s.sorted(), forKey: completedKey)
    }

    /// A chapter opens once the one before it is complete (or, for Meridian, once a journey there has begun).
    static func unlocked(_ index: Int) -> Bool {
        if index == 0 || ProcessInfo.processInfo.arguments.contains("-unlockAll") { return true }
        let done = completed()
        if done.contains(CHAPTERS[index].id) || done.contains(CHAPTERS[index - 1].id) { return true }
        return load(CHAPTERS[index].id) != nil
    }

    static func loadSettings() -> Settings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey), let s = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return s
    }

    static func saveSettings(_ s: Settings) {
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: settingsKey) }
    }
}
