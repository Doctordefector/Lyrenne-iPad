import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct LyricLine: Hashable, Sendable {
    public let time: TimeInterval
    public let text: String

    public init(time: TimeInterval, text: String) { self.time = time; self.text = text }
}

/// lrclib.net, desktop's first lyrics source. Synced when it has them, plain text otherwise.
public enum Lyrics {
    public static func fetch(title: String, artist: String) async -> [LyricLine] {
        var c = URLComponents(string: "https://lrclib.net/api/search")!
        c.queryItems = [.init(name: "track_name", value: title), .init(name: "artist_name", value: artist)]
        var req = URLRequest(url: c.url!)
        req.setValue("Lyrenne iPad (https://github.com/Doctordefector/Lyrenne)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let tracks = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        if let synced = tracks.lazy.compactMap({ $0["syncedLyrics"] as? String }).first {
            return parse(synced)
        }
        let plain = tracks.lazy.compactMap { $0["plainLyrics"] as? String }.first ?? ""
        // Plain lyrics: every line at time 0, so nothing highlights
        return plain.split(separator: "\n", omittingEmptySubsequences: false).map { LyricLine(time: 0, text: String($0)) }
    }

    /// "[01:23.45] text" lines into timed lines
    public static func parse(_ lrc: String) -> [LyricLine] {
        lrc.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
            let stamp = line[line.index(after: line.startIndex)..<close].split(separator: ":")
            guard stamp.count == 2, let m = Double(stamp[0]), let s = Double(stamp[1]) else { return nil }
            return LyricLine(time: m * 60 + s, text: line[line.index(after: close)...].trimmingCharacters(in: .whitespaces))
        }
    }
}
