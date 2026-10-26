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
    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "lyrenne.youtube.cookie"]

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

struct LibraryView: View {
    @Environment(Session.self) private var session
    @State private var playlists: [Playlist] = []
    @State private var loading = false
    @State private var showLogin = false

    var body: some View {
        Group {
            if session.signedIn {
                List(playlists) { p in
                    NavigationLink(value: p) {
                        HStack(spacing: 12) {
                            AsyncImage(url: p.thumbnail) { $0.resizable().scaledToFill() } placeholder: {
                                Image(systemName: p.id == Playlist.likedSongs.id ? "heart.fill" : "music.note.list")
                                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.secondary.opacity(0.2))
                            }
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading) {
                                Text(p.title).lineLimit(1)
                                Text(p.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .overlay { if loading && playlists.isEmpty { ProgressView() } }
                .refreshable { await load() }
                .task { if playlists.isEmpty { await load() } }
                .toolbar { Button("Sign out", role: .destructive) { session.signOut(); playlists = [] } }
            } else {
                ContentUnavailableView {
                    Label("Your library", systemImage: "person.crop.circle")
                } description: {
                    Text(session.message ?? "Sign in with your Google account to see your playlists and liked songs.")
                } actions: {
                    Button("Sign in to YouTube Music") { showLogin = true }.buttonStyle(.borderedProminent)
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

    private func load() async {
        loading = true
        playlists = (try? await InnerTube.libraryPlaylists()) ?? playlists
        loading = false
    }
}

struct PlaylistView: View {
    let playlist: Playlist
    @Environment(Player.self) private var player
    @Environment(DownloadStore.self) private var downloads
    @State private var songs: [Song] = []
    @State private var loading = true

    var body: some View {
        List(Array(songs.enumerated()), id: \.offset) { i, song in
            Button { player.play(songs, at: i) } label: { SongRow(song: song) }
                .buttonStyle(.plain)
                .songActions(song)
        }
        .listStyle(.plain)
        .overlay { if loading { ProgressView() } else if songs.isEmpty { ContentUnavailableView("Empty playlist", systemImage: "music.note.list") } }
        .navigationTitle(playlist.title)
        .toolbar {
            Button("Play", systemImage: "play.fill") { player.play(songs, at: 0) }.disabled(songs.isEmpty)
            Button("Shuffle", systemImage: "shuffle") { player.play(songs.shuffled(), at: 0) }.disabled(songs.isEmpty)
            Button("Download all", systemImage: "arrow.down.circle") { downloads.download(songs) }.disabled(songs.isEmpty)
        }
        .task {
            songs = (try? await InnerTube.playlistSongs(playlist.id)) ?? []
            loading = false
        }
    }
}
