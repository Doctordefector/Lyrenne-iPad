import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct Song: Identifiable, Hashable, Sendable {
    public let id: String // YouTube videoId
    public let title: String
    public let artist: String
    public let thumbnail: URL?
    public let duration: String?

    public init(id: String, title: String, artist: String, thumbnail: URL?, duration: String?) {
        self.id = id; self.title = title; self.artist = artist; self.thumbnail = thumbnail; self.duration = duration
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

    static func post(_ endpoint: String, client: Client, body: [String: Any]) async throws -> [String: Any] {
        var context: [String: Any] = ["clientName": client.name, "clientVersion": client.version, "hl": "en", "gl": "US"]
        context.merge(client.extra) { $1 }
        if client.userAgentInContext { context["userAgent"] = client.userAgent }
        var payload = body
        payload["context"] = ["client": context]

        var req = URLRequest(url: URL(string: "https://music.youtube.com/youtubei/v1/\(endpoint)?prettyPrint=false")!)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        for (k, v) in [
            "Content-Type": "application/json", "User-Agent": client.userAgent,
            "X-Goog-Api-Format-Version": "1", "X-YouTube-Client-Name": client.id,
            "X-YouTube-Client-Version": client.version, "Origin": "https://music.youtube.com",
            "Referer": "https://music.youtube.com/",
        ] { req.setValue(v, forHTTPHeaderField: k) }
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

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

    /// Same order as desktop's getStreamUrl: each client's URL gets a one-byte check (issue #17),
    /// and if none passes the first is returned anyway so a misfiring check costs nothing.
    public static func streamURL(for videoId: String) async throws -> URL {
        var unchecked: URL?
        for client in streamClients {
            guard let json = try? await post("player", client: client, body: ["videoId": videoId]),
                  (json["playabilityStatus"] as? [String: Any])?["status"] as? String == "OK",
                  let formats = (json["streamingData"] as? [String: Any])?["adaptiveFormats"] as? [[String: Any]]
            else { continue }
            // AVPlayer decodes AAC (m4a) but not Opus/WebM
            let best = formats
                .filter { ($0["mimeType"] as? String)?.hasPrefix("audio/mp4") == true && $0["url"] != nil }
                .max { ($0["bitrate"] as? Int ?? 0) < ($1["bitrate"] as? Int ?? 0) }
            guard let s = best?["url"] as? String, let url = URL(string: s) else { continue }
            if await isServed(url) { return url }
            unchecked = unchecked ?? url
        }
        if let unchecked { return unchecked }
        throw URLError(.resourceUnavailable)
    }

    public static func isServed(_ url: URL) async -> Bool {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
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

    private static func find(_ key: String, inArrayOf node: Any?) -> [[String: Any]] {
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
        // Second column reads "Artist • Album • 3:45"
        let parts = cols.count > 1 ? (text(cols[1]["text"]) ?? "").components(separatedBy: " • ") : []
        let duration = parts.last.flatMap { $0.contains(":") ? $0 : nil }
        return Song(id: id, title: title, artist: parts.first ?? "", thumbnail: thumbnail(r["thumbnail"]), duration: duration)
    }
}
