import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LyrenneCore

// Live end-to-end check of everything the app does over the network. Run: swift run lyrenne-check
// With LYRENNE_COOKIE set to a signed-in music.youtube.com cookie it also checks the library.
let parsed = Lyrics.parse("[01:02.50] hello\n[ar: x]\n[00:00.00]")
assert(parsed == [LyricLine(time: 62.5, text: "hello"), LyricLine(time: 0, text: "")], "LRC parse")
precondition(sha1Hex("abc") == "a9993e364706816aba3e25717850c26c9cd0d89d", "sha1")
precondition(sha1Hex(String(repeating: "a", count: 1000)) == "291e9a6c66994949b57ba5e650361e98fc36b1ba", "sha1 multi-block")
let rotated = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": "SID=new; Path=/; Domain=.youtube.com"], for: URL(string: "https://music.youtube.com")!)
    + [HTTPCookie(properties: [.name: "NEW", .value: "x", .domain: ".youtube.com", .path: "/"])!, HTTPCookie(properties: [.name: "HSID", .value: "", .domain: ".youtube.com", .path: "/"])!]
precondition(InnerTube.mergeCookies("SID=old; HSID=keep", rotated) == "SID=new; HSID=keep", "cookie merge")

let songs = try await InnerTube.search("Daft Punk Get Lucky")
guard let first = songs.first, !first.title.isEmpty else { fatalError("search returned no songs") }
print("search: \(songs.count) songs, first: \(first.title) — \(first.artist) [\(first.duration ?? "?")]")

let radio = try await InnerTube.radio(after: first.id)
precondition(!radio.isEmpty, "radio empty")
print("radio: \(radio.count) songs, next: \(radio.dropFirst().first?.title ?? "-")")

let lyrics = await Lyrics.fetch(title: first.title, artist: first.artist)
print("lyrics: \(lyrics.count) lines, synced: \(lyrics.contains { $0.time > 0 })")

// Which clients still hand out fully served URLs: what to look at when playback breaks
for line in await InnerTube.clientReport(for: first.id) { print(line) }

let url = try await InnerTube.streamURL(for: first.id)
let served = await InnerTube.isServed(url)
precondition(served, "stream URL refused")
print("stream: OK \(url.host ?? "")")

let started = Date()
try await Downloads.download(first)
let audio = try Downloads.file(for: first.id).map { try Data(contentsOf: $0) } ?? Data()
// An m4a starts with an ftyp box: bytes 4..<8 are "ftyp"
precondition(audio.count > 500_000 && String(decoding: audio[4..<8], as: UTF8.self) == "ftyp", "download is not an m4a: \(audio.count) bytes")
print("download: \(audio.count) bytes in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
precondition(Downloads.all().contains(first), "download not listed")
Downloads.delete(first.id)
precondition(Downloads.file(for: first.id) == nil, "delete")

// A public playlist: same parsing as the library's, and long enough to need continuations
let top = try await InnerTube.playlistSongs("VLPLw-VjHDlEOgtH-Ce-dJzPOtIm5xTVC4t2")
precondition(top.count > 100 && Set(top.map(\.id)).count > 100, "playlist paging: \(top.count) songs")
precondition(top.allSatisfy { !$0.title.isEmpty && !$0.artist.isEmpty }, "playlist rows missing title/artist")
print("playlist: \(top.count) songs, first: \(top[0].title) — \(top[0].artist) [\(top[0].duration ?? "?")]")

if let cookie = ProcessInfo.processInfo.environment["LYRENNE_COOKIE"] {
    InnerTube.cookie = cookie
    let alive = await InnerTube.refreshSession()
    print("session: \(alive.map { $0 ? "signed in" : "expired" } ?? "unreachable")")
    precondition(alive == true, "cookie session is not signed in; sign in again to check the library")
    precondition(InnerTube.cookie!.split(separator: ";").count == cookie.split(separator: ";").count, "merge changed the cookie set")
    let playlists = try await InnerTube.libraryPlaylists()
    precondition(playlists.count > 1, "no library playlists")
    print("library: \(playlists.count) playlists: \(playlists.prefix(4).map(\.title))")
    let liked = try await InnerTube.playlistSongs(Playlist.likedSongs.id)
    precondition(!liked.isEmpty, "liked songs empty")
    print("liked songs: \(liked.count), first: \(liked[0].title) — \(liked[0].artist) [\(liked[0].duration ?? "?")]")
    if let other = playlists.dropFirst().first {
        let s = try await InnerTube.playlistSongs(other.id)
        print("\(other.title): \(s.count) songs")
    }
}
print("ALL OK")
