import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Offline songs. The audio sits in Documents, which the Files app shows under
/// On My iPad > Lyrenne, named `Artist - Title [id].m4a`; the id in the name is how the app finds
/// it. Each song's details are `<id>.json` in Application Support, out of the user's sight.
/// The audio is written atomically and the json after it, so a json means a complete song, and
/// a song deleted in Files counts as not downloaded.
public enum Downloads {
    public static var directory: URL { folder(.documentDirectory) }
    static var infoDirectory: URL { folder(.applicationSupportDirectory, "Downloads") }

    static func folder(_ base: FileManager.SearchPathDirectory, _ sub: String? = nil) -> URL {
        var dir = FileManager.default.urls(for: base, in: .userDomainMask)[0]
        if let sub { dir.appendPathComponent(sub) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func info(_ id: String) -> URL { infoDirectory.appendingPathComponent("\(id).json") }

    static func audioName(_ song: Song) -> String {
        // Characters Files and other apps can't take in a name, and a sane length
        let label = "\(song.artist) - \(song.title)".map { #"/:\?*"<>|"#.contains($0) ? "-" : $0 }
        return "\(String(label.prefix(150))) [\(song.id)].m4a"
    }

    /// The downloaded file to play instead of streaming, nil when not downloaded
    public static func file(for id: String) -> URL? {
        guard FileManager.default.fileExists(atPath: info(id).path) else { return nil }
        // ponytail: scans the folder per lookup; fine for hundreds of songs, index it past thousands
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.first { $0.hasSuffix("[\(id)].m4a") }.map { directory.appendingPathComponent($0) }
    }

    public static func download(_ song: Song) async throws {
        try await fetchAudio(song.id).write(to: directory.appendingPathComponent(audioName(song)), options: .atomic)
        try JSONEncoder().encode(song).write(to: info(song.id), options: .atomic)
    }

    /// Downloads from the first iPad builds: `<id>.m4a` and `<id>.json` in Documents/Downloads.
    /// Moves them to the current layout once; nothing to do afterwards.
    public static func migrateLegacy() {
        let fm = FileManager.default
        let old = directory.appendingPathComponent("Downloads")
        guard let files = try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil) else { return }
        for json in files where json.pathExtension == "json" {
            guard let data = try? Data(contentsOf: json), let song = try? JSONDecoder().decode(Song.self, from: data) else { continue }
            let audio = old.appendingPathComponent("\(song.id).m4a")
            guard (try? fm.moveItem(at: audio, to: directory.appendingPathComponent(audioName(song)))) != nil else { continue }
            try? fm.moveItem(at: json, to: info(song.id))
        }
        if ((try? fm.contentsOfDirectory(atPath: old.path)) ?? []).isEmpty { try? fm.removeItem(at: old) }
    }

    /// The whole song's audio. googlevideo refuses (403) a plain GET, an open-ended Range, and any
    /// Range over 1 MiB for these URLs, so AVPlayer can't stream them directly: the player plays
    /// this from a file instead. The first MiB tells the total size; the rest come in parallel.
    /// ponytail: whole song in memory (a few MB) — stream to disk if hour-long mixes ever matter
    public static func fetchAudio(_ videoId: String) async throws -> Data {
        let url = try await InnerTube.streamURL(for: videoId)
        let chunk = 1 << 20
        let (first, total) = try await range(url, from: 0, length: chunk)
        let rest = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            for start in stride(from: chunk, to: total, by: chunk) {
                group.addTask { (start, try await range(url, from: start, length: chunk).0) }
            }
            return try await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
        }
        let data = rest.keys.sorted().reduce(first) { $0 + rest[$1]! }
        guard data.count == total else { throw URLError(.cannotDecodeContentData) }
        return data
    }

    static func range(_ url: URL, from start: Int, length: Int) async throws -> (Data, total: Int) {
        var req = URLRequest(url: url)
        req.setValue("bytes=\(start)-\(start + length - 1)", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: req)
        let http = response as? HTTPURLResponse
        guard http?.statusCode == 206, !data.isEmpty else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http?.statusCode ?? 0) at byte \(start)"])
        }
        // "bytes 0-1048575/5983881"
        let total = (http?.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last).flatMap { Int($0) } ?? data.count
        return (data, total)
    }

    /// Every downloaded song, newest first
    public static func all() -> [Song] {
        let names = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        let files = (try? FileManager.default.contentsOfDirectory(at: infoDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { f -> (Date, Song)? in
                guard let data = try? Data(contentsOf: f), let song = try? JSONDecoder().decode(Song.self, from: data),
                      names.contains(where: { $0.hasSuffix("[\(song.id)].m4a") }) else { return nil }
                let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return (date, song)
            }
            .sorted { $0.0 > $1.0 }
            .map(\.1)
    }

    public static func delete(_ id: String) {
        if let audio = file(for: id) { try? FileManager.default.removeItem(at: audio) }
        try? FileManager.default.removeItem(at: info(id))
    }
}
