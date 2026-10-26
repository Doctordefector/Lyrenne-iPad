import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LyrenneCore

setvbuf(stdout, nil, _IOLBF, 0) // CI: lines printed before a crash still reach the log
// Live end-to-end check of everything the app does over the network. Run: swift run lyrenne-check
// With LYRENNE_COOKIE set to a signed-in music.youtube.com cookie it also checks the library.
let parsed = Lyrics.parse("[01:02.50] hello\n[ar: x]\n[00:00.00]")
assert(parsed == [LyricLine(time: 62.5, text: "hello"), LyricLine(time: 0, text: "")], "LRC parse")
precondition(Song(id: "", title: "", artist: "", thumbnail: nil, duration: "6:10").seconds == 370 && seconds("1:02:03") == 3723, "listed length")
let ttml = #"<body><p begin="27.395" end="29" itunes:key="L1"><span begin="27.395">I</span> <span>tr</span><span>y</span></p>"#
    + #"<p begin="2:21.720" end="2:30"><span>Rock &amp; roll</span><span ttm:role="x-bg"><span>(back)</span></span></p></body>"#
precondition(Lyrics.ttml(ttml) == [LyricLine(time: 27.395, text: "I try"), LyricLine(time: 141.72, text: "Rock & roll (back)")], "TTML parse: \(Lyrics.ttml(ttml))")
// KuGou ends lines "\r\n", as YouTube's Lyrics tab does
let kugou = "\u{FEFF}[ti:x]\r\n[00:00.00]Artist - Title\r\n[00:01.00]作词：Someone\r\n[00:05.50]First line\r\n[00:09.120]Last line\n[00:12.00]Mixed by: Someone"
precondition(Lyrics.kuGouLines(kugou) == [LyricLine(time: 5.5, text: "First line"), LyricLine(time: 9.12, text: "Last line")], "KuGou credits: \(Lyrics.kuGouLines(kugou))")
precondition(Lyrics.cleanTitle("Get Lucky (feat. Pharrell Williams and Nile Rodgers)") == "Get Lucky"
    && Lyrics.primaryArtist("Daft Punk, Pharrell Williams & Nile Rodgers") == "Daft Punk", "LrcLib cleaning")
precondition(sha1Hex("abc") == "a9993e364706816aba3e25717850c26c9cd0d89d", "sha1")
precondition(sha1Hex(String(repeating: "a", count: 1000)) == "291e9a6c66994949b57ba5e650361e98fc36b1ba", "sha1 multi-block")
let rotated = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": "SID=new; Path=/; Domain=.youtube.com"], for: URL(string: "https://music.youtube.com")!)
    + [HTTPCookie(properties: [.name: "NEW", .value: "x", .domain: ".youtube.com", .path: "/"])!, HTTPCookie(properties: [.name: "HSID", .value: "", .domain: ".youtube.com", .path: "/"])!]
precondition(InnerTube.mergeCookies("SID=old; HSID=keep", rotated) == "SID=new; HSID=keep", "cookie merge")

// Listen Together: a host's sync_playback (change_track with a TrackInfo) decodes, then the live
// server answers a join for a room that doesn't exist, which proves our messages parse there
let track = PB().string(1, "abc").string(2, "Title").string(3, "Artist").int(5, 185_000)
let action = PB().string(1, "change_track").int(3, 1234).bytes(4, track.data)
guard case .sync("change_track", let synced)? = ListenTogether.Client.decode(PB().string(1, "sync_playback").bytes(2, action.data).data)
else { fatalError("sync_playback decode") }
precondition(synced.track?.id == "abc" && synced.track?.duration == "3:05" && synced.position == 1234, "TrackInfo decode")
precondition(PBMessage(Data([0x0a, 0x05, 0x61])) == nil, "truncated protobuf accepted")
#if canImport(Darwin) // Linux Foundation's libcurl has no WebSockets
let lt = ListenTogether.Client()
Task { try? await Task.sleep(for: .seconds(15)); lt.leave() } // no answer: ends the stream as disconnected
for await event in lt.join(code: "ZZZZZZ", name: "lyrenne-check") {
    if case .ended(let why) = event {
        print("listen together: server says \"\(why)\"")
        precondition(why != "Disconnected from the room.", "no answer from the Listen Together server")
        break
    }
}
lt.leave()
#endif

let songs = try await InnerTube.search("Daft Punk Get Lucky")
guard let first = songs.first, !first.title.isEmpty else { fatalError("search returned no songs") }
print("search: \(songs.count) songs, first: \(first.title) — \(first.artist) [\(first.duration ?? "?")]")
let big = try await URLSession.shared.data(from: first.artwork!)
let small = try await URLSession.shared.data(from: first.thumbnail!)
precondition(first.artwork!.absoluteString.contains("=w1200-h1200") && big.0.count > small.0.count * 4, "artwork not enlarged")
print("artwork: \(small.0.count / 1024) KB thumbnail -> \(big.0.count / 1024) KB cover")

let radio = try await InnerTube.radio(after: first.id)
precondition(!radio.isEmpty, "radio empty")
print("radio: \(radio.count) songs, next: \(radio.dropFirst().first?.title ?? "-")")

// Each provider on its own, then the chain. BetterLyrics only answers songs it has cached, so a
// miss there is printed, not fatal
func describe(_ l: [LyricLine]?) -> String { l.map { "\($0.count) lines, synced: \($0.contains { $0.time > 0 })" } ?? "none" }
let length = first.seconds.map { Int($0) }
let lrclib = await Lyrics.lrcLib(first.title, first.artist, length)
let kugouLive = await Lyrics.kuGou(first.title, first.artist, length)
let youtube = await Lyrics.youTube(first.id)
print("lyrics: BetterLyrics \(describe(await Lyrics.betterLyrics("Blinding Lights", "The Weeknd", 200)))")
print("lyrics: LrcLib \(describe(lrclib)), KuGou \(describe(kugouLive)), YouTube \(describe(youtube))")
precondition(lrclib?.contains { $0.time > 0 } == true && kugouLive?.contains { $0.time > 0 } == true && youtube != nil, "a lyrics provider failed")
// KuGou's first hit is the 4:07 radio edit; the length must pick the 6:10 album cut
precondition((kugouLive?.last?.time ?? 0) > 300, "KuGou matched the wrong recording")
let lyrics = await Lyrics.fetch(title: first.title, artist: first.artist, length: first.seconds, videoId: first.id)
print("lyrics: chain \(describe(lyrics))")

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
let visible = Downloads.file(for: first.id)!.lastPathComponent
precondition(visible == "Daft Punk, Pharrell Williams & Nile Rodgers - Get Lucky (feat. Pharrell Williams and Nile Rodgers) [\(first.id)].m4a", "file name: \(visible)")
print("download file: \(visible)")
// Deleted from the Files app: the song is no longer downloaded
try FileManager.default.removeItem(at: Downloads.file(for: first.id)!)
precondition(!Downloads.all().contains(first) && Downloads.file(for: first.id) == nil, "song deleted in Files still listed")
Downloads.delete(first.id)

// The first builds' layout (Documents/Downloads/<id>.m4a + .json) moves to the current one
let legacy = Downloads.directory.appendingPathComponent("Downloads")
try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
try audio.write(to: legacy.appendingPathComponent("\(first.id).m4a"))
try JSONEncoder().encode(first).write(to: legacy.appendingPathComponent("\(first.id).json"))
Downloads.migrateLegacy()
precondition(Downloads.all() == [first] && Downloads.file(for: first.id)?.lastPathComponent == visible, "migration")
precondition(!FileManager.default.fileExists(atPath: legacy.path), "legacy folder left behind")
Downloads.delete(first.id)
precondition(Downloads.file(for: first.id) == nil && Downloads.all().isEmpty, "delete")
print("downloads: Files-visible names, deletion in Files, migration OK")

// A public playlist: same parsing as the library's, and long enough to need continuations
let listStart = Date()
var firstPage: TimeInterval?
var top: [Song] = []
for try await page in InnerTube.playlistPages("VLPLw-VjHDlEOgtH-Ce-dJzPOtIm5xTVC4t2") {
    firstPage = firstPage ?? Date().timeIntervalSince(listStart)
    top += page
}
print("playlist timing: first \(Int(firstPage! * 1000)) ms, all \(top.count) in \(Int(Date().timeIntervalSince(listStart) * 1000)) ms")
precondition(top.count > 100 && Set(top.map(\.id)).count > 100, "playlist paging: \(top.count) songs")
precondition(top.allSatisfy { !$0.title.isEmpty && !$0.artist.isEmpty }, "playlist rows missing title/artist")
print("playlist: \(top.count) songs, first: \(top[0].title) — \(top[0].artist) [\(top[0].duration ?? "?")]")
// Removing a song from a playlist needs its entry id, which only the playlist's listing carries
precondition(top.allSatisfy { $0.setVideoId != nil }, "playlist rows missing setVideoId")
// Downloads saved before setVideoId existed still decode
precondition((try? JSONDecoder().decode(Song.self, from: Data(#"{"id":"a","title":"t","artist":"x","duration":"1:00"}"#.utf8))) != nil, "old Song JSON")
do { try await InnerTube.setLiked(first.id, true); preconditionFailure("signed-out edit went through") } catch {}

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

    // Edits, as a round trip that leaves the library as it was: a throwaway playlist made with one
    // song, a second added and removed again, a song not yet liked liked and unliked, then deleted
    let other = radio.first { $0.id != first.id }!
    let scratch = try await InnerTube.createPlaylist("lyrenne-check \(Int(Date().timeIntervalSince1970))", videoIds: [first.id])
    try await InnerTube.addToPlaylist(scratch, other.id)
    try await Task.sleep(for: .seconds(2)) // the listing trails an edit by a moment
    var inScratch = try await InnerTube.playlistSongs(scratch)
    precondition(Set(inScratch.map(\.id)) == [first.id, other.id], "create + add: \(inScratch.map(\.id))")
    try await InnerTube.removeFromPlaylist(scratch, inScratch.first { $0.id == other.id }!)
    try await Task.sleep(for: .seconds(2))
    inScratch = try await InnerTube.playlistSongs(scratch)
    precondition(inScratch.map(\.id) == [first.id], "remove: \(inScratch.map(\.id))")
    let likedIds = Set(liked.map(\.id))
    if let fresh = radio.first(where: { !likedIds.contains($0.id) }) {
        try await InnerTube.setLiked(fresh.id, true)
        try await Task.sleep(for: .seconds(2))
        var newest: [Song] = []
        for try await page in InnerTube.playlistPages(Playlist.likedSongs.id) { newest = page; break }
        precondition(newest.contains { $0.id == fresh.id }, "like didn't reach Liked songs")
        try await InnerTube.setLiked(fresh.id, false)
    }
    try await InnerTube.deletePlaylist(scratch)
    print("edits: create, add, remove, like, unlike, delete OK")
}
print("ALL OK")
