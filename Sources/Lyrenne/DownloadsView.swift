import SwiftUI
import LyrenneCore

/// Downloads one song at a time, like desktop's queue. Songs keep downloading while music plays
/// in the background; with nothing playing, iOS suspends the app and the queue resumes on return.
@MainActor @Observable
final class DownloadStore {
    var songs: [Song]
    var pending: [Song] = []
    var current: String?
    var failed: Set<String> = []

    init() {
        Downloads.migrateLegacy()
        songs = Downloads.all()
    }

    /// Re-read the folder: songs can be deleted from the Files app while Lyrenne is in the background
    func refresh() { songs = Downloads.all() }

    func download(_ list: [Song]) {
        let busy = Set(songs.map(\.id) + pending.map(\.id) + [current].compactMap { $0 })
        pending += list.filter { !busy.contains($0.id) }
        guard current == nil, let first = pending.first else { return }
        current = first.id // claimed now, so a second call can't start a second worker
        Task { await work() }
    }

    private func work() async {
        while !pending.isEmpty {
            let song = pending.removeFirst()
            current = song.id
            do {
                try await Downloads.download(song)
                failed.remove(song.id)
            } catch {
                failed.insert(song.id)
            }
            songs = Downloads.all()
        }
        current = nil
    }

    func delete(_ id: String) {
        Downloads.delete(id)
        songs = Downloads.all()
    }

    func isDownloaded(_ id: String) -> Bool { songs.contains { $0.id == id } }
    func isQueued(_ id: String) -> Bool { current == id || pending.contains { $0.id == id } }
}

struct DownloadsView: View {
    @Environment(Player.self) private var player
    @Environment(DownloadStore.self) private var downloads

    var body: some View {
        List {
            if let current = downloads.current {
                let title = downloads.pending.isEmpty ? "Downloading 1 song" : "Downloading \(downloads.pending.count + 1) songs"
                Label(title, systemImage: "arrow.down.circle").foregroundStyle(.secondary).id(current)
            }
            ForEach(Array(downloads.songs.enumerated()), id: \.element.id) { i, song in
                Button { player.play(downloads.songs, at: i) } label: { SongRow(song: song) }
                    .buttonStyle(.plain)
                    .songActions(song)
            }
            .onDelete { set in set.map { downloads.songs[$0].id }.forEach(downloads.delete) }
        }
        .listStyle(.plain)
        .task {
            // LYRENNE_DEMO=downloads: play the downloads (CI plays a test tone from here)
            if ProcessInfo.processInfo.environment["LYRENNE_DEMO"] == "downloads", !downloads.songs.isEmpty {
                player.play(downloads.songs, at: 0)
            }
        }
        .overlay {
            if downloads.songs.isEmpty && downloads.current == nil {
                ContentUnavailableView("No downloads", systemImage: "arrow.down.circle",
                                       description: Text("Long-press a song, or use Download all on a playlist, to keep it for offline listening."))
            }
        }
    }
}

extension View {
    /// The long-press menu every song row shares
    func songActions(_ song: Song) -> some View { modifier(SongActions(song: song)) }
}

private struct SongActions: ViewModifier {
    let song: Song
    @Environment(Player.self) private var player
    @Environment(DownloadStore.self) private var downloads
    @Environment(Session.self) private var session
    @Environment(LibraryStore.self) private var library
    @Environment(Nav.self) private var nav
    @State private var naming = false
    @State private var newName = ""

    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Play next", systemImage: "text.line.first.and.arrowtriangle.forward") { player.playNext(song) }
            Button("Add to queue", systemImage: "text.badge.plus") { player.enqueue(song) }
            if let artist = song.artistPage { Button("Go to artist", systemImage: "music.mic") { nav.open(artist) } }
            if let album = song.albumPage { Button("Go to album", systemImage: "square.stack") { nav.open(album) } }
            if session.signedIn {
                let liked = library.liked.contains(song.id)
                Button(liked ? "Remove like" : "Like", systemImage: liked ? "heart.slash" : "heart") { Task { await library.toggleLike(song) } }
                Menu("Add to playlist", systemImage: "music.note.list") {
                    Button("New playlist…", systemImage: "plus") { naming = true }
                    ForEach(library.editable) { p in
                        Button(p.title) { Task { await library.add(song, to: p) } }
                    }
                }
            }
            if downloads.isDownloaded(song.id) {
                Button("Remove download", systemImage: "trash", role: .destructive) { downloads.delete(song.id) }
            } else if !downloads.isQueued(song.id) {
                Button("Download", systemImage: "arrow.down.circle") { downloads.download([song]) }
            }
        }
        .newPlaylistAlert(isPresented: $naming, name: $newName) { await library.create($0, with: song) }
    }
}
