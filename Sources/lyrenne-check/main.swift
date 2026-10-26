import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LyrenneCore

// Live end-to-end check of everything the app does over the network. Run: swift run lyrenne-check
let parsed = Lyrics.parse("[01:02.50] hello\n[ar: x]\n[00:00.00]")
assert(parsed == [LyricLine(time: 62.5, text: "hello"), LyricLine(time: 0, text: "")], "LRC parse")

let songs = try await InnerTube.search("Daft Punk Get Lucky")
guard let first = songs.first, !first.title.isEmpty else { fatalError("search returned no songs") }
print("search: \(songs.count) songs, first: \(first.title) — \(first.artist) [\(first.duration ?? "?")]")

let url = try await InnerTube.streamURL(for: first.id)
let served = await InnerTube.isServed(url)
precondition(served, "stream URL refused")
print("stream: OK \(url.host ?? "")")

let radio = try await InnerTube.radio(after: first.id)
precondition(!radio.isEmpty, "radio empty")
print("radio: \(radio.count) songs, next: \(radio.dropFirst().first?.title ?? "-")")

let lyrics = await Lyrics.fetch(title: first.title, artist: first.artist)
print("lyrics: \(lyrics.count) lines, synced: \(lyrics.contains { $0.time > 0 })")
print("ALL OK")
