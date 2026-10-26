import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct Song: Identifiable, Hashable, Codable, Sendable {
    public let id: String // YouTube videoId
    public let title: String
    public let artist: String
    public let thumbnail: URL?
    public let duration: String?

    public init(id: String, title: String, artist: String, thumbnail: URL?, duration: String?) {
        self.id = id; self.title = title; self.artist = artist; self.thumbnail = thumbnail; self.duration = duration
    }

    /// The cover at full size. Album art URLs carry their size (`=w60-h60-…`), so ask for a big
    /// one, as desktop's song details do; video frames (ytimg.com) stay as they are.
    public var artwork: URL? {
        guard let s = thumbnail?.absoluteString,
              let r = s.range(of: #"=w\d+-h\d+"#, options: .regularExpression) else { return thumbnail }
        return URL(string: s.replacingCharacters(in: r, with: "=w1200-h1200"))
    }
}

/// A port of the desktop's InnerTube use: search, radio, and stream resolution.
public enum InnerTube {
    struct Client {
        let name: String, version: String, id: String, userAgent: String
        var extra: [String: String] = [:]
        var userAgentInContext = false
    }

    static let webRemix = Client(
        name: "WEB_REMIX", version: "1.20260114.03.00", id: "67",
        userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0")

    // ponytail: only clients whose URLs need no signature deobfuscation; desktop's web clients need
    // NewPipe's JS player, which has no iOS port. Add them if all of these stop working.
    static let streamClients = [
        Client(name: "VISIONOS", version: "0.1", id: "101",
               userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
               extra: ["osName": "visionOS", "osVersion": "1.3.21O771", "deviceMake": "Apple", "deviceModel": "RealityDevice14,1"]),
        Client(name: "ANDROID_VR", version: "1.65.10", id: "28",
               userAgent: "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
               extra: ["osName": "Android", "osVersion": "12L", "deviceMake": "Oculus", "deviceModel": "Quest 3", "androidSdkVersion": "32"],
               userAgentInContext: true),
        Client(name: "ANDROID_VR", version: "1.43.32", id: "28",
               userAgent: "com.google.android.apps.youtube.vr.oculus/1.43.32 (Linux; U; Android 12; en_US; Quest 3; Build/SQ3A.220605.009.A1; Cronet/107.0.5284.2)",
               extra: ["osName": "Android", "osVersion": "12", "deviceMake": "Oculus", "deviceModel": "Quest 3", "androidSdkVersion": "32"],
               userAgentInContext: true),
        Client(name: "ANDROID_VR", version: "1.61.48", id: "28",
               userAgent: "com.google.android.apps.youtube.vr.oculus/1.61.48 (Linux; U; Android 12; en_US; Oculus Quest 3; Build/SQ3A.220605.009.A1; Cronet/132.0.6808.3)",
               userAgentInContext: true),
        Client(name: "IOS", version: "21.03.1", id: "5",
               userAgent: "com.google.ios.youtube/21.03.1 (iPhone16,2; U; CPU iOS 18_2 like Mac OS X;)",
               extra: ["osVersion": "18.2.22C152"]),
    ]

    static let filterSongs = "EgWKAQIIAWoKEAkQBRAKEAMQBA=="

    static func post(_ endpoint: String, client: Client, body: [String: Any], auth: Bool = false) async throws -> [String: Any] {
        var context: [String: Any] = ["clientName": client.name, "clientVersion": client.version, "hl": "en", "gl": "US"]
        context.merge(client.extra) { $1 }
        if client.userAgentInContext { context["userAgent"] = client.userAgent }
        if let visitorData { context["visitorData"] = visitorData }
        var payload = body
        payload["context"] = ["client": context]
        if auth, let dataSyncId { payload["context"] = ["client": context, "user": ["onBehalfOfUser": dataSyncId]] }

        var req = URLRequest(url: URL(string: "https://music.youtube.com/youtubei/v1/\(endpoint)?prettyPrint=false")!)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        for (k, v) in [
            "Content-Type": "application/json", "User-Agent": client.userAgent,
            "X-Goog-Api-Format-Version": "1", "X-YouTube-Client-Name": client.id,
            "X-YouTube-Client-Version": client.version, "Origin": "https://music.youtube.com",
            "Referer": "https://music.youtube.com/",
        ] { req.setValue(v, forHTTPHeaderField: k) }
        if auth {
            // Our cookie string, not whatever URLSession's jar picked up
            req.httpShouldHandleCookies = false
            for (k, v) in authHeaders() { req.setValue(v, forHTTPHeaderField: k) }
        }
        if let visitorData { req.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if visitorData == nil { visitorData = (json["responseContext"] as? [String: Any])?["visitorData"] as? String }
        return json
    }

    /// YouTube's id for this anonymous visitor, from the first response that carries one.
    /// Without it the Android VR clients answer LOGIN_REQUIRED ("confirm you're not a bot").
    nonisolated(unsafe) public static var visitorData: String?

    public static func search(_ query: String) async throws -> [Song] {
        let json = try await post("search", client: webRemix, body: ["query": query, "params": filterSongs])
        return find("musicResponsiveListItemRenderer", in: json).compactMap(song(fromListItem:))
    }

    /// The radio YouTube Music would play after [videoId], the source of autoplay.
    public static func radio(after videoId: String) async throws -> [Song] {
        let json = try await post("next", client: webRemix, body: ["videoId": videoId, "playlistId": "RDAMVM\(videoId)"])
        return find("playlistPanelVideoRenderer", in: json).compactMap { r in
            guard let id = r["videoId"] as? String else { return nil }
            return Song(id: id, title: text(r["title"]) ?? "", artist: text(r["shortBylineText"]) ?? "",
                        thumbnail: thumbnail(r["thumbnail"]), duration: text(r["lengthText"]))
        }
    }

    /// Same order as desktop's getStreamUrl: each client's URL gets checked (issue #17), and if
    /// none passes the first is returned anyway so a misfiring check costs nothing. When every
    /// client fails, the error says why for each, like desktop's per-client log lines.
    public static func streamURL(for videoId: String) async throws -> URL {
        if visitorData == nil { _ = try? await post("visitor_id", client: webRemix, body: [:]) }
        var unchecked: URL?
        var reasons: [String] = []
        for client in streamClients {
            let json: [String: Any]
            do { json = try await post("player", client: client, body: ["videoId": videoId]) } catch {
                reasons.append("\(client.name) \(client.version): \(error.localizedDescription)")
                continue
            }
            let playability = json["playabilityStatus"] as? [String: Any]
            guard playability?["status"] as? String == "OK",
                  let formats = (json["streamingData"] as? [String: Any])?["adaptiveFormats"] as? [[String: Any]]
            else {
                reasons.append("\(client.name) \(client.version): \(playability?["status"] as? String ?? "no answer") \(playability?["reason"] as? String ?? "")")
                continue
            }
            // AVPlayer decodes AAC (m4a) but not Opus/WebM
            let best = formats
                .filter { ($0["mimeType"] as? String)?.hasPrefix("audio/mp4") == true && $0["url"] != nil }
                .max { ($0["bitrate"] as? Int ?? 0) < ($1["bitrate"] as? Int ?? 0) }
            guard let s = best?["url"] as? String, let url = URL(string: s) else {
                reasons.append("\(client.name) \(client.version): no m4a URL")
                continue
            }
            // Probe the last byte: URLs that want a PO token serve only the first MiB, so a
            // first-byte check (desktop's) passes them
            let length = (best?["contentLength"] as? String).flatMap(Int.init) ?? 1
            if await isServed(url, at: length - 1) { return url }
            reasons.append("\(client.name) \(client.version): stream refused")
            unchecked = unchecked ?? url
        }
        if let unchecked { return unchecked }
        throw URLError(.resourceUnavailable, userInfo: [NSLocalizedDescriptionKey: reasons.joined(separator: "\n")])
    }

    /// One line per stream client saying whether it still hands out whole-file URLs.
    /// What to look at when playback breaks (lyrenne-check prints it).
    public static func clientReport(for videoId: String) async -> [String] {
        var lines: [String] = []
        for client in streamClients {
            let json = (try? await post("player", client: client, body: ["videoId": videoId])) ?? [:]
            let status = (json["playabilityStatus"] as? [String: Any])?["status"] as? String ?? "no answer"
            let m4a = ((json["streamingData"] as? [String: Any])?["adaptiveFormats"] as? [[String: Any]] ?? [])
                .first { ($0["mimeType"] as? String)?.hasPrefix("audio/mp4") == true }
            var whole = "-"
            if let u = (m4a?["url"] as? String).flatMap(URL.init(string:)), let len = (m4a?["contentLength"] as? String).flatMap(Int.init) {
                whole = await isServed(u, at: len - 1) ? "whole file served" : "first MiB only (wants a PO token)"
            }
            lines.append("client \(client.name) \(client.version): \(status), \(whole)")
        }
        return lines
    }

    public static func isServed(_ url: URL, at byte: Int = 0) async -> Bool {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("bytes=\(byte)-\(byte)", forHTTPHeaderField: "Range")
        let code = (try? await URLSession.shared.data(for: req))?.1 as? HTTPURLResponse
        return (200..<300).contains(code?.statusCode ?? 0)
    }

    // MARK: JSON helpers. ponytail: untyped walk instead of Codable models for YouTube's renderer tree

    static func find(_ key: String, in node: Any) -> [[String: Any]] {
        if let d = node as? [String: Any] {
            if let hit = d[key] as? [String: Any] { return [hit] }
            return d.values.flatMap { find(key, in: $0) }
        }
        if let a = node as? [Any] { return a.flatMap { find(key, in: $0) } }
        return []
    }

    static func runs(_ node: Any?) -> [String] {
        ((node as? [String: Any])?["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String } ?? []
    }

    static func text(_ node: Any?) -> String? {
        if let s = (node as? [String: Any])?["simpleText"] as? String { return s }
        let r = runs(node)
        return r.isEmpty ? nil : r.joined()
    }

    static func thumbnail(_ node: Any?) -> URL? {
        let thumbs = find("thumbnails", inArrayOf: node)
        return (thumbs.last?["url"] as? String).flatMap(URL.init(string:))
    }

    static func find(_ key: String, inArrayOf node: Any?) -> [[String: Any]] {
        if let d = node as? [String: Any] {
            if let a = d[key] as? [[String: Any]] { return a }
            for v in d.values { let r = find(key, inArrayOf: v); if !r.isEmpty { return r } }
        }
        return []
    }

    static func song(fromListItem r: [String: Any]) -> Song? {
        guard let id = (r["playlistItemData"] as? [String: Any])?["videoId"] as? String else { return nil }
        let cols = (r["flexColumns"] as? [[String: Any]])?.map { $0["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any] ?? [:] } ?? []
        let title = cols.first.flatMap { text($0["text"]) } ?? ""
        // Search: second column reads "Artist • Album • 3:45". Playlists: just the artist, duration in a fixed column
        let parts = cols.count > 1 ? (text(cols[1]["text"]) ?? "").components(separatedBy: " • ") : []
        let fixed = (r["fixedColumns"] as? [[String: Any]])?.first?["musicResponsiveListItemFixedColumnRenderer"] as? [String: Any]
        let duration = text(fixed?["text"]) ?? parts.last.flatMap { $0.contains(":") ? $0 : nil }
        return Song(id: id, title: title, artist: parts.first ?? "", thumbnail: thumbnail(r["thumbnail"]), duration: duration)
    }
}
