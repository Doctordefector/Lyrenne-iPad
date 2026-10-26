import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Offline songs: `<id>.m4a` beside `<id>.json` (the Song) in Documents/Downloads.
/// The audio is written atomically and the json after it, so a json means a complete song.
public enum Downloads {
    public static var directory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func audio(_ id: String) -> URL { directory.appendingPathComponent("\(id).m4a") }
    static func info(_ id: String) -> URL { directory.appendingPathComponent("\(id).json") }

    /// The downloaded file to play instead of streaming, nil when not downloaded
    public static func file(for id: String) -> URL? {
        FileManager.default.fileExists(atPath: info(id).path) ? audio(id) : nil
    }

    public static func download(_ song: Song) async throws {
        try await fetchAudio(song.id).write(to: audio(song.id), options: .atomic)
        try JSONEncoder().encode(song).write(to: info(song.id), options: .atomic)
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
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { f -> (Date, Song)? in
                guard let data = try? Data(contentsOf: f), let song = try? JSONDecoder().decode(Song.self, from: data) else { return nil }
                let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return (date, song)
            }
            .sorted { $0.0 > $1.0 }
            .map(\.1)
    }

    public static func delete(_ id: String) {
        try? FileManager.default.removeItem(at: info(id))
        try? FileManager.default.removeItem(at: audio(id))
    }
}
