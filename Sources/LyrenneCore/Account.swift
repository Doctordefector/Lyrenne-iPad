import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct Playlist: Identifiable, Hashable, Codable, Sendable {
    public let id: String // browseId, "VL..." for playlists
    public let title: String
    public let subtitle: String
    public let thumbnail: URL?

    public init(id: String, title: String, subtitle: String, thumbnail: URL?) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.thumbnail = thumbnail
    }

    public static let likedSongs = Playlist(id: "VLLM", title: "Liked songs", subtitle: "Auto playlist", thumbnail: nil)
}

/// The signed-in side of InnerTube: the account's playlists and their songs.
extension InnerTube {
    /// The music.youtube.com cookie from signing in, nil when signed out. Same as desktop's YouTube.cookie.
    nonisolated(unsafe) public static var cookie: String?

    /// The signed-in account's id, sent as onBehalfOfUser so brand accounts get their own library
    nonisolated(unsafe) public static var dataSyncId: String?

    /// Desktop's AuthManager.refreshSession: Google rotates the session cookies, and a stored copy
    /// that never takes the rotated ones dies within weeks. Loading music.youtube.com both answers
    /// whether the session is alive (ytcfg LOGGED_IN) and carries the rotated cookies.
    /// Returns true when signed in (cookie refreshed), false when expired, nil when YouTube
    /// couldn't be asked (offline): then keep the stored login, don't sign out.
    public static func refreshSession() async -> Bool? {
        guard cookie != nil else { return false }
        let page = URL(string: "https://music.youtube.com")!
        var req = URLRequest(url: page)
        req.httpShouldHandleCookies = false
        for (k, v) in authHeaders() { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse else { return nil }
        let html = String(decoding: data, as: UTF8.self)
        guard let loggedIn = firstMatch(#""LOGGED_IN"\s*:\s*(true|false)"#, in: html) else { return nil }
        guard loggedIn == "true" else { return false }

        let headers = http.allHeaderFields.reduce(into: [String: String]()) { $0["\($1.key)"] = "\($1.value)" }
        cookie = mergeCookies(cookie!, HTTPCookie.cookies(withResponseHeaderFields: headers, for: page))
        if let raw = firstMatch(#""DATASYNC_ID"\s*:\s*"([^"]+)""#, in: html) {
            // "<account>||<user>" for a brand account, "<user>||" otherwise (desktop's smoke test)
            dataSyncId = !raw.contains("||") ? raw : raw.hasSuffix("||") ? String(raw.dropLast(2)) : raw.components(separatedBy: "||").last
        }
        return true
    }

    /// Fold rotated cookies into the stored string the way a browser would. Only names already
    /// held are updated, and blanks (deletions) are skipped, so a logged-out response can't wipe it.
    static func mergeCookies(_ current: String, _ fresh: [HTTPCookie]) -> String {
        var jar: [(String, String)] = current.split(separator: ";").compactMap { part in
            guard let eq = part.firstIndex(of: "=") else { return nil }
            return (part[..<eq].trimmingCharacters(in: .whitespaces), part[part.index(after: eq)...].trimmingCharacters(in: .whitespaces))
        }
        for c in fresh where !c.value.isEmpty && c.value != "\"\"" {
            if let i = jar.firstIndex(where: { $0.0 == c.name }) { jar[i].1 = c.value }
        }
        return jar.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    static func authHeaders() -> [String: String] {
        guard let cookie else { return [:] }
        var h = ["Cookie": cookie, "X-Goog-AuthUser": "0"]
        let sapisid = cookie.split(separator: ";").lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("SAPISID=") }?.dropFirst(8)
        if let sapisid {
            let now = Int(Date().timeIntervalSince1970)
            h["Authorization"] = "SAPISIDHASH \(now)_\(sha1Hex("\(now) \(sapisid) https://music.youtube.com"))"
        }
        return h
    }

    /// The library's playlists, Liked songs first
    public static func libraryPlaylists() async throws -> [Playlist] {
        let json = try await post("browse", client: webRemix, body: ["browseId": "FEmusic_liked_playlists"], auth: true)
        let found = find("musicTwoRowItemRenderer", in: json).compactMap { r -> Playlist? in
            let nav = (r["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any]
            guard let id = nav?["browseId"] as? String, id.hasPrefix("VL") else { return nil } // skips "New playlist"
            return Playlist(id: id, title: text(r["title"]) ?? "", subtitle: text(r["subtitle"]) ?? "", thumbnail: thumbnail(r["thumbnailRenderer"]))
        }
        return [.likedSongs] + found.filter { $0.id != Playlist.likedSongs.id }
    }

    /// Every song of a playlist, following continuations
    public static func playlistSongs(_ browseId: String) async throws -> [Song] {
        try await playlistPages(browseId).reduce([], +)
    }

    /// A playlist page by page (~100 songs each), as they arrive. Each page's request needs the
    /// token in the one before, so they can't be fetched in parallel; a big playlist is many
    /// round trips, and showing each page as it lands is what keeps that from looking stuck.
    public static func playlistPages(_ browseId: String) -> AsyncThrowingStream<[Song], Error> {
        AsyncThrowingStream { out in
            let task = Task {
                do {
                    var json = try await post("browse", client: webRemix, body: ["browseId": browseId], auth: true)
                    // ponytail: 50 pages (~5000 songs) cap so a broken continuation can't loop forever
                    for _ in 0..<50 {
                        out.yield(find("musicResponsiveListItemRenderer", in: json).compactMap(song(fromListItem:)))
                        guard let token = continuationToken(in: json), !Task.isCancelled else { break }
                        json = try await post("browse", client: webRemix, body: ["continuation": token], auth: true)
                    }
                    out.finish()
                } catch { out.finish(throwing: error) }
            }
            out.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Library edits, the requests desktop's YouTubeWrites sends

    public static func setLiked(_ videoId: String, _ liked: Bool) async throws {
        try await write(liked ? "like/like" : "like/removelike", ["target": ["videoId": videoId]])
    }

    public static func addToPlaylist(_ playlistId: String, _ videoId: String) async throws {
        try await write("browse/edit_playlist", ["playlistId": bare(playlistId), "actions": [["action": "ACTION_ADD_VIDEO", "addedVideoId": videoId]]])
    }

    /// Removal names the playlist entry (setVideoId), not the video, so [song] must come from
    /// that playlist's own listing
    public static func removeFromPlaylist(_ playlistId: String, _ song: Song) async throws {
        guard let setVideoId = song.setVideoId else { throw failure("Reload the playlist and try again") }
        try await write("browse/edit_playlist", ["playlistId": bare(playlistId), "actions": [
            ["action": "ACTION_REMOVE_VIDEO", "setVideoId": setVideoId, "removedVideoId": song.id],
        ]])
    }

    /// A private playlist holding [videoIds]; returns its browseId
    public static func createPlaylist(_ title: String, videoIds: [String] = []) async throws -> String {
        let json = try await write("playlist/create", ["title": title, "privacyStatus": "PRIVATE", "videoIds": videoIds])
        guard let id = json["playlistId"] as? String else { throw failure("YouTube didn't create the playlist") }
        return "VL" + id
    }

    public static func deletePlaylist(_ playlistId: String) async throws {
        try await write("playlist/delete", ["playlistId": bare(playlistId)])
    }

    /// An edit as the signed-in user. A refusal comes back as a JSON error (with HTTP 4xx, which
    /// post doesn't look at) or a non-success status, so both are checked.
    @discardableResult
    static func write(_ endpoint: String, _ body: [String: Any]) async throws -> [String: Any] {
        guard cookie != nil else { throw failure("Sign in to change your library") }
        let json = try await post(endpoint, client: webRemix, body: body, auth: true)
        if let error = json["error"] as? [String: Any] { throw failure(error["message"] as? String ?? "YouTube refused the change") }
        if let status = json["status"] as? String, status != "STATUS_SUCCEEDED" { throw failure("YouTube answered \(status)") }
        return json
    }

    /// Edits take the playlist id without the browse prefix
    static func bare(_ playlistId: String) -> String { playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId }

    static func failure(_ message: String) -> Error { URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: message]) }

    static func continuationToken(in json: [String: Any]) -> String? {
        if let c = find("continuationCommand", in: json).first?["token"] as? String { return c }
        return find("nextContinuationData", in: json).first?["continuation"] as? String
    }
}

/// SHA-1 hex digest, for the SAPISIDHASH header.
/// ponytail: hand-rolled because CryptoKit is Apple-only and the core must build on Linux
func sha1Hex(_ string: String) -> String {
    var message = Array(string.utf8)
    let bitLength = UInt64(message.count) * 8
    message.append(0x80)
    while message.count % 64 != 56 { message.append(0) }
    message += (0..<8).reversed().map { UInt8(truncatingIfNeeded: bitLength >> (UInt64($0) * 8)) }

    var h: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
    for chunk in stride(from: 0, to: message.count, by: 64) {
        var w = (0..<16).map { i in
            message[chunk + i * 4..<chunk + i * 4 + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        }
        for i in 16..<80 {
            let x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]
            w.append(x << 1 | x >> 31)
        }
        var (a, b, c, d, e) = (h[0], h[1], h[2], h[3], h[4])
        for i in 0..<80 {
            let (f, k): (UInt32, UInt32) = switch i {
            case 0..<20: ((b & c) | (~b & d), 0x5A827999)
            case 20..<40: (b ^ c ^ d, 0x6ED9EBA1)
            case 40..<60: ((b & c) | (b & d) | (c & d), 0x8F1BBCDC)
            default: (b ^ c ^ d, 0xCA62C1D6)
            }
            let t = (a << 5 | a >> 27) &+ f &+ e &+ k &+ w[i]
            (a, b, c, d, e) = (t, a, b << 30 | b >> 2, c, d)
        }
        h = [h[0] &+ a, h[1] &+ b, h[2] &+ c, h[3] &+ d, h[4] &+ e]
    }
    return h.map { String(format: "%08x", $0) }.joined()
}
