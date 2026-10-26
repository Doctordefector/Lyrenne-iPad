import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Something YouTube Music lists: a song to play, or an album, artist or playlist to open.
/// Albums and artists reuse Playlist: all three are a browseId with a title and a cover.
public enum Item: Identifiable, Hashable, Sendable {
    case song(Song)
    case album(Playlist), artist(Playlist), playlist(Playlist)

    public var song: Song? { if case .song(let s) = self { return s }; return nil }
    public var page: Playlist? {
        switch self {
        case .song: return nil
        case .album(let p), .artist(let p), .playlist(let p): return p
        }
    }
    public var id: String { song?.id ?? page!.id }
    public var title: String { song?.title ?? page!.title }
    public var subtitle: String { song?.artist ?? page!.subtitle }
    public var thumbnail: URL? { song?.thumbnail ?? page!.thumbnail }
    public var isArtist: Bool { if case .artist = self { return true }; return false }
}

/// One row of a browse page: "Quick picks", "Albums", "Fans might also like"...
public struct Shelf: Sendable {
    public let title: String
    public let items: [Item]
    /// The whole list behind the shelf, when YouTube links one (an artist's "Top songs")
    public let more: Playlist?
}

public struct ArtistPage: Sendable {
    public let title: String?
    public let thumbnail: URL?
    public let shelves: [Shelf]
}

extension InnerTube {
    /// Desktop's YouTube.SearchFilter params
    public enum SearchFilter: String, CaseIterable, Sendable {
        case songs = "Songs", videos = "Videos", albums = "Albums", artists = "Artists", playlists = "Playlists"

        var params: String {
            switch self {
            case .songs: filterSongs
            case .videos: "EgWKAQIQAWoKEAkQChAFEAMQBA=="
            case .albums: "EgWKAQIYAWoKEAkQChAFEAMQBA=="
            case .artists: "EgWKAQIgAWoKEAkQChAFEAMQBA=="
            case .playlists: "EgeKAQQoAEABagoQAxAEEAoQCRAF" // community playlists
            }
        }
    }

    public static func search(_ query: String, _ filter: SearchFilter) async throws -> [Item] {
        let json = try await post("search", client: webRemix, body: ["query": query, "params": filter.params])
        return find("musicResponsiveListItemRenderer", in: json).compactMap(item(fromListItem:))
    }

    /// What YouTube Music suggests while typing [input]
    public static func suggestions(_ input: String) async throws -> [String] {
        let json = try await post("music/get_search_suggestions", client: webRemix, body: ["input": input])
        return find("searchSuggestionRenderer", in: json).compactMap { text($0["suggestion"]) }
    }

    /// One page of the home feed (the account's own when signed in) and the token for the next
    public static func home(continuation: String? = nil) async throws -> (shelves: [Shelf], next: String?) {
        let body: [String: Any] = continuation.map { ["continuation": $0] } ?? ["browseId": "FEmusic_home"]
        let json = try await post("browse", client: webRemix, body: body, auth: true)
        let list = find("sectionListContinuation", in: json).first ?? find("sectionListRenderer", in: json).first ?? [:]
        let next = ((list["continuations"] as? [[String: Any]])?.first?["nextContinuationData"] as? [String: Any])?["continuation"] as? String
        return (shelves(list), next)
    }

    public static func artist(_ browseId: String) async throws -> ArtistPage {
        let json = try await post("browse", client: webRemix, body: ["browseId": browseId], auth: true)
        let header = find("musicImmersiveHeaderRenderer", in: json).first ?? find("musicVisualHeaderRenderer", in: json).first
        return ArtistPage(title: text(header?["title"]), thumbnail: thumbnail(header?["thumbnail"]),
                          shelves: shelves(find("sectionListRenderer", in: json).first ?? [:]))
    }

    /// The shelves of a sectionListRenderer, in order (find() would lose it across shelves)
    static func shelves(_ list: [String: Any]) -> [Shelf] {
        (list["contents"] as? [[String: Any]] ?? []).compactMap { c in
            guard let s = c["musicCarouselShelfRenderer"] as? [String: Any] ?? c["musicShelfRenderer"] as? [String: Any] else { return nil }
            let header = (s["header"] as? [String: Any])?["musicCarouselShelfBasicHeaderRenderer"] as? [String: Any]
            let items = (s["contents"] as? [[String: Any]] ?? []).compactMap { i in
                (i["musicTwoRowItemRenderer"] as? [String: Any]).flatMap(item(fromTwoRow:))
                    ?? (i["musicResponsiveListItemRenderer"] as? [String: Any]).flatMap(item(fromListItem:))
            }
            guard let title = text(s["title"]) ?? text(header?["title"]), !items.isEmpty else { return nil }
            let more = ((s["bottomEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any])?["browseId"] as? String
            return Shelf(title: title, items: items,
                         more: more.flatMap { $0.hasPrefix("VL") ? Playlist(id: $0, title: title, subtitle: "", thumbnail: nil) : nil })
        }
    }

    /// A card: a song when it plays (watchEndpoint), else the page it opens
    static func item(fromTwoRow r: [String: Any]) -> Item? {
        let title = text(r["title"]) ?? "", subtitle = text(r["subtitle"]) ?? ""
        let cover = thumbnail(r["thumbnailRenderer"])
        let nav = r["navigationEndpoint"] as? [String: Any]
        if let id = (nav?["watchEndpoint"] as? [String: Any])?["videoId"] as? String {
            // "Artist • 907M views"
            return .song(Song(id: id, title: title, artist: byline(subtitle).first ?? "", thumbnail: cover, duration: nil))
        }
        return pageItem(nav, title, subtitle, cover)
    }

    /// A list row: a song when it has a videoId, else an album/artist/playlist result
    static func item(fromListItem r: [String: Any]) -> Item? {
        if let s = song(fromListItem: r) { return .song(s) }
        let cols = columns(r)
        return pageItem(r["navigationEndpoint"], cols.first.flatMap { text($0) } ?? "", cols.count > 1 ? text(cols[1]) ?? "" : "", thumbnail(r["thumbnail"]))
    }

    static func pageItem(_ endpoint: Any?, _ title: String, _ subtitle: String, _ cover: URL?) -> Item? {
        let browse = (endpoint as? [String: Any])?["browseEndpoint"] as? [String: Any]
        guard let id = browse?["browseId"] as? String else { return nil }
        let config = (browse?["browseEndpointContextSupportedConfigs"] as? [String: Any])?["browseEndpointContextMusicConfig"] as? [String: Any]
        let p = Playlist(id: id, title: title, subtitle: subtitle, thumbnail: cover)
        switch config?["pageType"] as? String {
        case "MUSIC_PAGE_TYPE_ALBUM": return .album(p)
        case "MUSIC_PAGE_TYPE_ARTIST": return .artist(p)
        case "MUSIC_PAGE_TYPE_PLAYLIST": return .playlist(p)
        default: return nil // ponytail: podcasts and profiles have no page here
        }
    }
}
