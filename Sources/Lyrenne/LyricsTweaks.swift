import Foundation

/// What the user changed about a song's lyrics, per song id, in UserDefaults: how far they're
/// moved in time, and lyrics they wrote or edited. Desktop keeps the same two things in
/// data/lyrics-offsets.json and data/lyrics-overrides.json.
enum LyricsTweaks {
    private static let offsetsKey = "lyricsOffsets"
    private static let editedKey = "lyricsEdited"

    /// Seconds; positive shows the lyrics sooner
    static func offset(_ id: String) -> TimeInterval {
        UserDefaults.standard.dictionary(forKey: offsetsKey)?[id] as? Double ?? 0
    }

    /// Zero is stored as no entry, so a song put back on time leaves nothing behind
    static func setOffset(_ seconds: TimeInterval, for id: String) {
        var all = UserDefaults.standard.dictionary(forKey: offsetsKey) ?? [:]
        if seconds == 0 { all.removeValue(forKey: id) } else { all[id] = seconds }
        UserDefaults.standard.set(all, forKey: offsetsKey)
    }

    static func edited(_ id: String) -> String? {
        UserDefaults.standard.dictionary(forKey: editedKey)?[id] as? String
    }

    static func setEdited(_ text: String?, for id: String) {
        var all = UserDefaults.standard.dictionary(forKey: editedKey) ?? [:]
        if let text { all[id] = text } else { all.removeValue(forKey: id) }
        UserDefaults.standard.set(all, forKey: editedKey)
    }
}
