import Security
import SwiftUI
import WebKit
import LyrenneCore

/// Signed-in state. The cookie lives in the Keychain and is refreshed on every launch,
/// like desktop's AuthManager, so the session doesn't quietly die after a few weeks.
@MainActor @Observable
final class Session {
    var signedIn = false
    var message: String?

    init() {
        InnerTube.cookie = Keychain.cookie
        signedIn = InnerTube.cookie != nil
        if signedIn { Task { await refresh() } }
    }

    func refresh() async {
        switch await InnerTube.refreshSession() {
        case true?:
            Keychain.cookie = InnerTube.cookie // rotated cookies
            signedIn = true
            message = nil
        case false?:
            signOut()
            message = "Your YouTube session expired. Sign in again to see your library."
        case nil:
            break // offline: keep the stored login
        }
    }

    func signIn(cookie: String) async {
        InnerTube.cookie = cookie
        await refresh()
        if !signedIn { message = "Sign-in didn't complete. Try again." }
    }

    func signOut() {
        InnerTube.cookie = nil
        InnerTube.dataSyncId = nil
        Keychain.cookie = nil
        signedIn = false
    }
}

enum Keychain {
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "lyrenne.youtube.cookie"] }

    static var cookie: String? {
        get {
            var item: CFTypeRef?
            let q = query.merging([kSecReturnData as String: true]) { $1 }
            guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            SecItemDelete(query as CFDictionary)
            guard let newValue else { return }
            let q = query.merging([
                kSecValueData as String: Data(newValue.utf8),
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]) { $1 }
            SecItemAdd(q as CFDictionary, nil)
        }
    }
}

/// Google's sign-in page, the same flow as upstream Android's LoginScreen: once it lands on
/// music.youtube.com, the youtube.com cookies are the session.
struct LoginWebView: UIViewRepresentable {
    let onCookie: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCookie: onCookie) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent() // a fresh sign-in every time; the Keychain keeps the result
        let web = WKWebView(frame: .zero, configuration: config)
        // Google refuses sign-in from user agents that look like an embedded view
        web.customUserAgent = "Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: URL(string: "https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fmusic.youtube.com")!))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onCookie: (String) -> Void
        var done = false
        init(onCookie: @escaping (String) -> Void) { self.onCookie = onCookie }

        func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) {
            guard !done, web.url?.host == "music.youtube.com" else { return }
            web.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let yt = cookies.filter { $0.domain.hasSuffix("youtube.com") }
                guard !self.done, yt.contains(where: { $0.name == "SAPISID" }) else { return }
                self.done = true
                self.onCookie(yt.map { "\($0.name)=\($0.value)" }.joined(separator: "; "))
            }
        }
    }
}

/// The signed-in library: its playlists, which songs are liked, and playlists' songs as last
/// loaded whole this session. Edits show at once and are put back if YouTube refuses them:
/// unlike desktop there's no local database here to keep a refused edit in.
@MainActor @Observable
final class LibraryStore {
    var playlists: [Playlist] = []
    var liked: Set<String> = []
    var songs: [String: [Song]] = [:]
    var loading = false
    /// The last edit YouTube refused, shown as an alert
    var error: String?

    /// Playlists a song can go into. ponytail: includes saved playlists of other people, which
    /// YouTube refuses edits to (the alert says so); the library listing doesn't mark ownership.
    var editable: [Playlist] { playlists.filter { $0.id != Playlist.likedSongs.id } }

    func load() async {
        loading = true
        if let found = try? await InnerTube.libraryPlaylists() { playlists = found }
        loading = false
        // Liked songs whole, so every song row knows its heart. Several pages on a big library,
        // which is fine here: nothing waits on it.
        if let likes = try? await InnerTube.playlistSongs(Playlist.likedSongs.id) {
            songs[Playlist.likedSongs.id] = likes
            liked = Set(likes.map(\.id))
        }
    }

    func clear() { playlists = []; liked = []; songs = [:] }

    func toggleLike(_ song: Song) async {
        let like = !liked.contains(song.id)
        setLiked(like, song)
        if !(await edit(like ? "like the song" : "remove the like", { try await InnerTube.setLiked(song.id, like) })) { setLiked(!like, song) }
    }

    private func setLiked(_ like: Bool, _ song: Song) {
        if like { liked.insert(song.id); songs[Playlist.likedSongs.id]?.insert(song, at: 0) }
        else { liked.remove(song.id); songs[Playlist.likedSongs.id]?.removeAll { $0.id == song.id } }
    }

    func add(_ song: Song, to playlist: Playlist) async {
        // Reloaded on next open rather than appended: the added entry's setVideoId (needed to
        // remove it again) only comes from YouTube's listing
        if await edit("add it to \(playlist.title)", { try await InnerTube.addToPlaylist(playlist.id, song.id) }) { songs[playlist.id] = nil }
    }

    /// Out of Liked songs means unliking it
    func remove(_ song: Song, from playlist: Playlist) async {
        if playlist.id == Playlist.likedSongs.id { if liked.contains(song.id) { await toggleLike(song) }; return }
        let before = songs[playlist.id]
        songs[playlist.id]?.removeAll { $0.setVideoId == song.setVideoId }
        if !(await edit("remove it from \(playlist.title)", { try await InnerTube.removeFromPlaylist(playlist.id, song) })) { songs[playlist.id] = before }
    }

    func create(_ title: String, with song: Song?) async {
        await edit("create \(title)") {
            let id = try await InnerTube.createPlaylist(title, videoIds: song.map { [$0.id] } ?? [])
            // Under Liked songs, where YouTube lists a new playlist too
            playlists.insert(Playlist(id: id, title: title, subtitle: "Playlist", thumbnail: nil), at: min(1, playlists.count))
        }
    }

    func delete(_ playlist: Playlist) async -> Bool {
        guard await edit("delete \(playlist.title)", { try await InnerTube.deletePlaylist(playlist.id) }) else { return false }
        playlists.removeAll { $0.id == playlist.id }
        songs[playlist.id] = nil
        return true
    }

    @discardableResult
    private func edit(_ what: String, _ change: () async throws -> Void) async -> Bool {
        do { try await change(); return true } catch {
            self.error = "Couldn't \(what): \(error.localizedDescription)"
            return false
        }
    }
}

struct LibraryView: View {
    @Environment(Session.self) private var session
    @Environment(LibraryStore.self) private var library
    @State private var showLogin = false
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        Group {
            if session.signedIn {
                List(library.playlists) { p in
                    NavigationLink(value: p) {
                        HStack(spacing: 12) {
                            AsyncImage(url: p.thumbnail) { $0.resizable().scaledToFill() } placeholder: {
                                Image(systemName: p.id == Playlist.likedSongs.id ? "heart.fill" : "music.note.list")
                                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.secondary.opacity(0.2))
                            }
                            .frame(width: 56, height: 56)
                            .foregroundStyle(Color.gold)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.title).lineLimit(1)
                                Text(p.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .overlay { if library.loading && library.playlists.isEmpty { ProgressView() } }
                .refreshable { await library.load() }
                .toolbar {
                    Button("New playlist", systemImage: "plus") { naming = true }
                    Menu("Account", systemImage: "person.crop.circle") {
                        Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { session.signOut() }
                    }
                }
                .newPlaylistAlert(isPresented: $naming, name: $newName) { await library.create($0, with: nil) }
            } else {
                ContentUnavailableView {
                    Label("Your library", systemImage: "person.crop.circle")
                } description: {
                    Text(session.message ?? "Sign in with your Google account to see your playlists and liked songs.")
                } actions: {
                    Button("Sign in to YouTube Music") { showLogin = true }
                        .buttonStyle(.borderedProminent).controlSize(.large).foregroundStyle(Color.onGold)
                }
            }
        }
        .sheet(isPresented: $showLogin) {
            NavigationStack {
                LoginWebView { cookie in
                    Task { @MainActor in
                        showLogin = false
                        await session.signIn(cookie: cookie)
                    }
                }
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Sign in").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Cancel") { showLogin = false } }
            }
        }
    }

}

extension View {
    /// Asks for a playlist's name, then hands it to [create]
    func newPlaylistAlert(isPresented: Binding<Bool>, name: Binding<String>, create: @escaping (String) async -> Void) -> some View {
        alert("New playlist", isPresented: isPresented) {
            TextField("Name", text: name)
            Button("Create") {
                let title = name.wrappedValue.trimmingCharacters(in: .whitespaces)
                name.wrappedValue = ""
                if !title.isEmpty { Task { await create(title) } }
            }
            Button("Cancel", role: .cancel) { name.wrappedValue = "" }
        }
    }
}

struct PlaylistView: View {
    let playlist: Playlist
    @Environment(Player.self) private var player
    @Environment(DownloadStore.self) private var downloads
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    /// The pages so far, while a first load is still arriving
    @State private var partial: [Song] = []
    @State private var loading = true
    @State private var confirmDelete = false

    /// The whole playlist once loaded (kept in the library, so edits show here), else the pages so far
    private var songs: [Song] { library.songs[playlist.id] ?? partial }

    var body: some View {
        List {
            header.listRowSeparator(.hidden)
            ForEach(Array(songs.enumerated()), id: \.offset) { i, song in
                Button { player.play(songs, at: i) } label: { SongRow(song: song) }
                    .buttonStyle(.plain)
                    .songActions(song)
                    .swipeActions {
                        Button(playlist.id == Playlist.likedSongs.id ? "Remove like" : "Remove", systemImage: "minus.circle", role: .destructive) {
                            partial.removeAll { $0.id == song.id && $0.setVideoId == song.setVideoId }
                            Task { await library.remove(song, from: playlist) }
                        }
                    }
            }
        }
        .listStyle(.plain)
        .overlay { if loading && songs.isEmpty { ProgressView() } else if !loading && songs.isEmpty { ContentUnavailableView("Empty playlist", systemImage: "music.note.list") } }
        .navigationTitle(playlist.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Download all", systemImage: "arrow.down.circle") { downloads.download(songs) }.disabled(songs.isEmpty)
            if playlist.id != Playlist.likedSongs.id {
                Button("Delete playlist", systemImage: "trash") { confirmDelete = true }
            }
        }
        .confirmationDialog("Delete \(playlist.title)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete playlist", role: .destructive) { Task { if await library.delete(playlist) { dismiss() } } }
        } message: {
            Text("It's deleted from YouTube Music too.")
        }
        .task {
            // Opened before this session: shown at once, then swapped for a fresh copy when that
            // has loaded whole. First time: filled in page by page as YouTube sends them.
            // ponytail: memory only, so a relaunch loads again; persist it if that bites
            if library.songs[playlist.id] != nil {
                loading = false
                if let fresh = try? await InnerTube.playlistSongs(playlist.id) { library.songs[playlist.id] = fresh }
                return
            }
            var all: [Song] = []
            do {
                for try await page in InnerTube.playlistPages(playlist.id) { all += page; partial = all; loading = false }
                // Left before the last page: don't keep a partial list as if it were the playlist
                if !Task.isCancelled { library.songs[playlist.id] = all }
            } catch {}
            loading = false
        }
    }

    /// Cover, title, and Play / Shuffle where the thumb reaches them
    private var header: some View {
        VStack(spacing: 14) {
            AsyncImage(url: playlist.thumbnail) { $0.resizable().scaledToFill() } placeholder: {
                Image(systemName: playlist.id == Playlist.likedSongs.id ? "heart.fill" : "music.note.list")
                    .font(.system(size: 56)).foregroundStyle(Color.gold)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.gold.opacity(0.12))
            }
            .frame(width: 180, height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
            VStack(spacing: 2) {
                Text(playlist.title).font(.title3.bold()).multilineTextAlignment(.center)
                Text(loading ? playlist.subtitle : "\(songs.count) songs").font(.subheadline).foregroundStyle(.secondary)
            }
            HStack {
                Button { player.play(songs, at: 0) } label: { Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).foregroundStyle(Color.onGold)
                Button { player.play(songs.shuffled(), at: 0) } label: { Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .disabled(songs.isEmpty)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}
