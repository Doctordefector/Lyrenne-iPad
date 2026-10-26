import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct LyricLine: Hashable, Sendable {
    public let time: TimeInterval
    public let text: String

    public init(time: TimeInterval, text: String) { self.time = time; self.text = text }
}

/// "3:45", "1:02:03" or "27.395" in seconds
func seconds<S: StringProtocol>(_ clock: S) -> TimeInterval? {
    let parts = clock.split(separator: ":").map { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard !parts.isEmpty, !parts.contains(nil) else { return nil }
    return parts.reduce(0) { $0 * 60 + $1! }
}

/// The other way: 225 to "3:45", 3723 to "1:02:03"
public func clock(_ t: TimeInterval) -> String {
    let s = Int(t.rounded())
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

/// Desktop's provider chain (LyricsManager.kt): BetterLyrics, LrcLib, KuGou, then YouTube Music.
/// Desktop's last resort, YouTube transcripts, is left out: get_transcript answers 400 to every
/// client now, desktop's included. Synced lines when a provider has them, plain text otherwise.
public enum Lyrics {
    /// [length] is the song's listed length in seconds. LrcLib and KuGou match on it, which is
    /// what picks the album cut over the radio edit, whose timings are off for this recording.
    public static func fetch(title: String, artist: String, length: TimeInterval?, videoId: String) async -> [LyricLine] {
        let length = length.map { Int($0.rounded()) }
        if let lines = await betterLyrics(title, artist, length) { return lines }
        if let lines = await lrcLib(title, artist, length) { return lines }
        if let lines = await kuGou(title, artist, length) { return lines }
        return await youTube(videoId) ?? []
    }

    // MARK: Providers. Each is nil when it has nothing, so the chain moves on.

    /// lyrics-api.boidu.dev: Apple Music's TTML. Since 2026 it wants an API key for songs nobody
    /// has asked it for yet, so it only answers for popular ones.
    static func betterLyrics(_ title: String, _ artist: String, _ length: Int?) async -> [LyricLine]? {
        let response = await json(url("https://lyrics-api.boidu.dev/getLyrics", ["s": title, "a": artist, "d": length.map(String.init)]))
        guard let ttml = (response as? [String: Any])?["ttml"] as? String else { return nil }
        return nonEmpty(Self.ttml(ttml))
    }

    /// lrclib.net, crowdsourced LRC
    static func lrcLib(_ title: String, _ artist: String, _ length: Int?) async -> [LyricLine]? {
        let title = cleanTitle(title), artist = primaryArtist(artist)
        for query in [["track_name": title, "artist_name": artist], ["q": "\(artist) \(title)"]] {
            let tracks = await json(url("https://lrclib.net/api/search", query)) as? [[String: Any]] ?? []
            // Within 5 s of the song when its length is known, closest first; synced over plain
            let off = { (t: [String: Any]) in length.map { abs(number(t["duration"]) - Double($0)) } ?? 0 }
            let near = tracks.filter { off($0) <= 5 }.sorted { off($0) < off($1) }
            if let synced = near.lazy.compactMap({ $0["syncedLyrics"] as? String }).first { return nonEmpty(parse(synced)) }
            if let text = near.lazy.compactMap({ $0["plainLyrics"] as? String }).first { return nonEmpty(plain(text)) }
        }
        return nil
    }

    /// KuGou: synced LRC, strongest for Chinese, Japanese and Korean catalogs
    static func kuGou(_ title: String, _ artist: String, _ length: Int?) async -> [LyricLine]? {
        let artist = artist.replacing(/\(.*\)|（.*）|\./, with: "").replacing(/, | & |和/, with: "、")
        let keyword = title.replacing(/\(.*\)|（.*）|「.*」|『.*』|<.*>|《.*》|〈.*〉|＜.*＞/, with: "") + " - " + artist
        let search = await json(url("https://mobileservice.kugou.com/api/v3/search/song",
                                    ["version": "9108", "plat": "0", "pagesize": "8", "showtype": "0", "keyword": keyword]))
        let songs = ((search as? [String: Any])?["data"] as? [String: Any])?["info"] as? [[String: Any]] ?? []
        var candidate: [String: Any]?
        // A recording within 8 s of ours first, then KuGou's own lyrics search
        for song in songs where length.map({ abs(number(song["duration"]) - Double($0)) <= 8 }) ?? true {
            candidate = await kuGouCandidates(["hash": string(song["hash"])]).first
            if candidate != nil { break }
        }
        if candidate == nil {
            candidate = await kuGouCandidates(["keyword": keyword, "duration": length.map { String($0 * 1000) }]).first
        }
        guard let candidate, let id = string(candidate["id"]), let key = string(candidate["accesskey"]) else { return nil }
        let download = await json(url("https://lyrics.kugou.com/download",
                                      ["fmt": "lrc", "charset": "utf8", "client": "pc", "ver": "1", "id": id, "accesskey": key]))
        guard let content = (download as? [String: Any])?["content"] as? String,
              let data = Data(base64Encoded: content) else { return nil }
        return nonEmpty(kuGouLines(String(decoding: data, as: UTF8.self)))
    }

    static func kuGouCandidates(_ query: [String: String?]) async -> [[String: Any]] {
        let base: [String: String?] = ["ver": "1", "man": "yes", "client": "pc"]
        let response = await json(url("https://lyrics.kugou.com/search", base.merging(query) { $1 }))
        return (response as? [String: Any])?["candidates"] as? [[String: Any]] ?? []
    }

    /// The Lyrics tab of YouTube Music: plain text
    static func youTube(_ videoId: String) async -> [LyricLine]? {
        guard let text = try? await InnerTube.lyrics(videoId) else { return nil }
        return nonEmpty(plain(text))
    }

    // MARK: Formats

    /// "[01:23.45] text" lines into timed lines; tags like "[ar: x]" are skipped.
    /// Lines split on isNewline throughout: KuGou and YouTube end lines "\r\n", which Swift
    /// counts as one Character, so splitting on "\n" never splits them.
    public static func parse(_ lrc: String) -> [LyricLine] {
        lrc.split(whereSeparator: \.isNewline).compactMap { line in
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]"),
                  let time = seconds(line[line.index(after: line.startIndex)..<close]) else { return nil }
            return LyricLine(time: time, text: line[line.index(after: close)...].trimmingCharacters(in: .whitespaces))
        }
    }

    /// Lyrics written or edited by hand: LRC when any line carries a time, plain text otherwise
    public static func edited(_ text: String) -> [LyricLine] {
        let timed = parse(text)
        return timed.isEmpty ? plain(text) : timed
    }

    /// The other way, for the editor: LRC for synced lines, the bare text for plain ones
    public static func text(_ lines: [LyricLine]) -> String {
        guard lines.contains(where: { $0.time > 0 }) else { return lines.map(\.text).joined(separator: "\n") }
        return lines.map { line in
            let centis = Int((line.time * 100).rounded())
            return String(format: "[%02d:%02d.%02d]", centis / 6000, centis / 100 % 60, centis % 100) + line.text
        }.joined(separator: "\n")
    }

    /// Plain lyrics: every line at time 0, so nothing highlights
    static func plain(_ text: String) -> [LyricLine] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { LyricLine(time: 0, text: String($0)) }
    }

    /// Apple's TTML, one line per <p>. ponytail: line timing only; desktop also highlights each
    /// word from the <span> times, add that here if the iPad grows word highlighting.
    static func ttml(_ xml: String) -> [LyricLine] {
        xml.matches(of: /<p\s[^>]*?begin="([^"]+)"[^>]*>(.*?)<\/p>/).compactMap { m in
            guard let time = seconds(m.output.1) else { return nil }
            // Backing vocals ride inline after the lead, "(like this)", so they need a space
            let text = String(m.output.2).replacing(/<span[^>]*x-bg[^>]*>/, with: " ").replacing(/<[^>]+>/, with: "")
            return LyricLine(time: time, text: unescape(text).trimmingCharacters(in: .whitespaces))
        }
    }

    /// KuGou files open and close with credits ("作词：…", "Composer: …"): drop everything up to
    /// the last one near the top and from the first one near the bottom, as desktop does. "Near"
    /// is 30 lines, or half the file, so on a short one the top cut can't reach the bottom credits
    static func kuGouLines(_ lrc: String) -> [LyricLine] {
        var lines = lrc.split(whereSeparator: \.isNewline).filter { $0.prefixMatch(of: /\[\d\d:\d\d\.\d{2,3}\]/) != nil }
        let credit = /.+\].+[:：].+/
        if let i = lines.prefix(min(30, lines.count / 2)).lastIndex(where: { $0.wholeMatch(of: credit) != nil }) { lines.removeFirst(i + 1) }
        if let i = lines.suffix(min(30, lines.count / 2)).firstIndex(where: { $0.wholeMatch(of: credit) != nil }) { lines.removeSubrange(i...) }
        return parse(lines.joined(separator: "\n"))
    }

    // MARK: Matching, as desktop's LrcLib.kt cleans before searching

    static func cleanTitle(_ title: String) -> String {
        title
            .replacing(/(?i)\s*[(\[][^)\]]*(official|video|audio|lyric|visualizer|hd|hq|4k|remaster|remix|live|acoustic|version|edit|extended|radio|clean|explicit|feat\.|ft\.)[^)\]]*[)\]]/, with: "")
            .replacing(/\s*【.*?】/, with: "")
            .replacing(/(?i)\s*(\||-\s*(official|video|audio|lyrics?|visualizer)|\bfeat\.|\bft\.).*$/, with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// "Daft Punk, Pharrell Williams & Nile Rodgers" is "Daft Punk"
    static func primaryArtist(_ artist: String) -> String {
        String(artist.split(separator: #/(?i) & | and |, | x | feat\.? | ft\.? | featuring | with /#).first ?? "")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: Plumbing

    static func json(_ url: URL) async -> Any? {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Lyrenne iPad (https://github.com/Doctordefector/Lyrenne)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// Every value percent-encoded by hand: URLComponents leaves "+" alone, which servers read as a space
    static func url(_ base: String, _ query: [String: String?]) -> URL {
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let pairs = query.compactMap { k, v in v.map { "\(k)=\($0.addingPercentEncoding(withAllowedCharacters: safe)!)" } }
        return URL(string: base + "?" + pairs.sorted().joined(separator: "&"))!
    }

    static func number(_ any: Any?) -> Double { (any as? NSNumber)?.doubleValue ?? (any as? String).flatMap(Double.init) ?? 0 }
    static func string(_ any: Any?) -> String? { any as? String ?? (any as? NSNumber)?.stringValue }
    static func nonEmpty(_ lines: [LyricLine]) -> [LyricLine]? { lines.contains { !$0.text.isEmpty } ? lines : nil }

    static func unescape(_ s: String) -> String {
        [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"), ("&amp;", "&")]
            .reduce(s) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }
}
