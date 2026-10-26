import SwiftUI
import LyrenneCore

extension Color {
    /// Desktop's accent (Theme.kt LyrenneGoldLight) and the dark text that sits on it
    static let gold = Color(red: 0xE3 / 255, green: 0xC0 / 255, blue: 0x89 / 255)
    static let onGold = Color(red: 0x2A / 255, green: 0x1B / 255, blue: 0x06 / 255)
}

@main
struct LyrenneApp: App {
    @State private var player = Player()
    @State private var session = Session()
    @State private var downloads = DownloadStore()
    @State private var room = Room()
    @State private var library = LibraryStore()
    @State private var home = HomeFeed()
    @State private var nav = Nav()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                // Loaded on sign-in, not when the Library tab opens: likes show on every song row
                .task(id: session.signedIn) { if session.signedIn { await library.load() } else { library.clear() } }
                .task(id: session.signedIn) { await home.load() } // the account's own feed, or the anonymous one
                .alert("Not saved", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
                } message: { Text(library.error ?? "") }
                .environment(player)
                .environment(session)
                .environment(downloads)
                .environment(room)
                .environment(library)
                .environment(home)
                .environment(nav)
                .preferredColorScheme(.dark)
                .tint(.gold)
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { downloads.refresh() } }
    }
}

struct ContentView: View {
    // LYRENNE_TAB picks the starting tab (CI screenshots); otherwise Home, or Search for LYRENNE_DEMO
    @State private var tab = ProcessInfo.processInfo.environment["LYRENNE_TAB"]
        ?? (ProcessInfo.processInfo.environment["LYRENNE_DEMO"] == nil ? "Home" : "Search")
    @Environment(Nav.self) private var nav
    // Both columns side by side even in portrait; the sidebar button still hides it
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var nav = nav
        NavigationSplitView(columnVisibility: $columns) {
            // Its own stack, so opening a playlist pushes in the sidebar and Now Playing stays put
            NavigationStack(path: $nav.path) {
                VStack(spacing: 0) {
                    TabBar(tab: $tab)
                    switch tab {
                    case "Library": LibraryView()
                    case "Downloads": DownloadsView() // CI's offline check; in the app it's under Library
                    case "Together": TogetherView()
                    case "Search": SearchView()
                    default: HomeView()
                    }
                    Link("Made by Andrei with love <3", destination: URL(string: "https://github.com/Doctordefector")!)
                        .font(.caption2).foregroundStyle(.secondary).padding(.vertical, 6)
                }
                .navigationTitle("Lyrenne")
                .navigationDestination(for: Playlist.self) { PlaylistView(playlist: $0) }
                .navigationDestination(for: Item.self) { ItemPage(item: $0) }
                .navigationDestination(for: Screen.self) { _ in DownloadsView().navigationTitle("Downloads") }
            }
            .navigationSplitViewColumnWidth(min: 340, ideal: 400)
        } detail: {
            NowPlayingView()
        }
        .navigationSplitViewStyle(.balanced)
    }
}

/// Icon over label, like desktop's rail. A segmented picker cut "Downloads" short.
struct TabBar: View {
    @Binding var tab: String
    // Downloads sit inside Library and the queue beside the player, so four fit roomily
    private let tabs = [("Home", "house"), ("Search", "magnifyingglass"), ("Library", "music.note.house"), ("Together", "person.2")]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs, id: \.0) { name, icon in
                let on = tab == name
                Button { tab = name } label: {
                    VStack(spacing: 4) {
                        Image(systemName: icon).font(.title3).symbolVariant(on ? .fill : .none)
                        Text(name).font(.caption2.weight(.medium)).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .foregroundStyle(on ? Color.gold : .secondary)
                    .background(on ? Color.gold.opacity(0.14) : .clear, in: .rect(cornerRadius: 12))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .animation(.snappy, value: tab)
    }
}

struct SongRow: View {
    let song: Song
    @Environment(Player.self) private var player
    @Environment(DownloadStore.self) private var downloads

    var body: some View {
        let playing = player.current?.id == song.id
        HStack(spacing: 12) {
            AsyncImage(url: song.thumbnail) { $0.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.2) }
                .frame(width: 48, height: 48)
                .overlay {
                    if playing {
                        Color.black.opacity(0.5)
                        Image(systemName: "waveform").foregroundStyle(Color.gold)
                            .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).lineLimit(1).fontWeight(playing ? .semibold : .regular)
                    .foregroundStyle(playing ? Color.gold : .primary)
                Text(song.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if downloads.isDownloaded(song.id) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.secondary).accessibilityLabel("Downloaded")
            } else if downloads.isQueued(song.id) {
                ProgressView().controlSize(.small)
            }
            if let d = song.duration { Text(d).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
        }
        .contentShape(.rect)
    }
}

struct SearchView: View {
    @Environment(Player.self) private var player
    @State private var query = ""
    @State private var filter = InnerTube.SearchFilter.songs
    @State private var results: [Item] = []
    @State private var searched = "" // the query the results are for
    @State private var loading = false
    @State private var suggestions: [String] = []
    // ponytail: newest 20, newline-joined in UserDefaults
    @AppStorage("searchHistory") private var historyText = ""
    private var history: [String] { historyText.split(separator: "\n").map(String.init) }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $filter) {
                ForEach(InnerTube.SearchFilter.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)
            List(Array(results.enumerated()), id: \.offset) { _, item in
                ItemLink(item, in: results) {
                    if let song = item.song { SongRow(song: song) } else { ItemRow(item: item) }
                }
            }
            .listStyle(.plain)
            .overlay {
                if loading {
                    ProgressView()
                } else if results.isEmpty && searched.isEmpty {
                    ContentUnavailableView("Search YouTube Music", systemImage: "magnifyingglass",
                                           description: Text("Tap a song to play it, and everything below it after."))
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: searched)
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Songs, albums, artists")
        .searchSuggestions {
            // Empty field: recent searches. Typing: YouTube's completions, gone once that text is searched
            if query.isEmpty {
                ForEach(history, id: \.self) { suggestion($0, icon: "clock.arrow.circlepath") }
                if !history.isEmpty {
                    Button("Clear recent searches", systemImage: "trash", role: .destructive) { historyText = "" }
                }
            } else if query != searched {
                ForEach(suggestions, id: \.self) { suggestion($0, icon: "magnifyingglass") }
            }
        }
        .onSubmit(of: .search) { Task { await search(query) } }
        .task(id: query) {
            suggestions = []
            guard !query.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(250)) // ask once typing pauses
            guard !Task.isCancelled, let found = try? await InnerTube.suggestions(query) else { return }
            suggestions = found
        }
        .onChange(of: filter) { if !searched.isEmpty { Task { await search(searched) } } }
        .task {
            // LYRENNE_DEMO="query": search and play the first result (CI screenshots)
            guard results.isEmpty, let demo = ProcessInfo.processInfo.environment["LYRENNE_DEMO"], demo != "downloads" else { return }
            query = demo
            await search(demo)
            player.play(results.compactMap(\.song), at: 0)
        }
    }

    private func suggestion(_ text: String, icon: String) -> some View {
        Button { query = text; Task { await search(text) } } label: { Label(text, systemImage: icon) }
            .foregroundStyle(.primary)
    }

    private func search(_ q: String) async {
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        loading = true
        results = (try? await InnerTube.search(q, filter)) ?? []
        searched = q
        loading = false
        historyText = ([q] + history.filter { $0 != q }).prefix(20).joined(separator: "\n")
    }
}

struct QueueView: View {
    @Environment(Player.self) private var player

    var body: some View {
        @Bindable var player = player
        List {
            Toggle(isOn: $player.autoplay) { Label("Autoplay similar songs", systemImage: "infinity") }
            ForEach(Array(player.queue.enumerated()), id: \.offset) { i, song in
                Button { player.start(i) } label: { SongRow(song: song) }
                    .buttonStyle(.plain)
                    .songActions(song)
            }
            .onDelete { set in
                // ponytail: removing the playing song just leaves it playing until it ends
                for i in set where i < player.index { player.index -= 1 }
                player.queue.remove(atOffsets: set)
            }
        }
        .listStyle(.plain)
        .overlay {
            if player.queue.isEmpty {
                ContentUnavailableView("Queue is empty", systemImage: "list.bullet",
                                       description: Text("Songs you play, and the ones autoplay picks, line up here."))
            }
        }
    }
}

struct NowPlayingView: View {
    @Environment(Player.self) private var player
    @Environment(Room.self) private var room
    @Environment(Session.self) private var session
    @Environment(LibraryStore.self) private var library
    @Environment(Nav.self) private var nav
    @State private var showQueue = false
    @State private var scrub: Double? // where the thumb is while dragging; seeks only on release
    // Lyrics beside the player when there's room (landscape), under it otherwise (portrait split view)
    @State private var wide = true

    var body: some View {
        if let song = player.current {
            let layout = wide ? AnyLayout(HStackLayout(spacing: 40)) : AnyLayout(VStackLayout(spacing: 16))
            layout {
                VStack(spacing: 24) {
                    // The full-size cover, with the list's small thumbnail (already loaded) until it
                    // arrives. Keyed by song: reused for the next song, AsyncImage could keep
                    // showing the previous cover.
                    AsyncImage(url: song.artwork) { $0.resizable().scaledToFit() } placeholder: {
                        AsyncImage(url: song.thumbnail) { $0.resizable().scaledToFit() } placeholder: { Color.secondary.opacity(0.2) }
                    }
                        .id(song.id)
                        .frame(maxWidth: wide ? 420 : 300, maxHeight: wide ? 420 : 300)
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
                        // Shrinks a little while paused, like Music
                        .scaleEffect(player.isPlaying || player.duration == 0 ? 1 : 0.88)
                        .animation(.spring(duration: 0.5, bounce: 0.3), value: player.isPlaying)
                    VStack(spacing: 4) {
                        if case .joined(let code) = room.status {
                            Label("Listening together · \(code)", systemImage: "person.2.fill")
                                .font(.caption.weight(.semibold)).foregroundStyle(Color.gold)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Color.gold.opacity(0.15), in: .capsule)
                                .padding(.bottom, 6)
                        }
                        Text(song.title).font(.title2.bold()).lineLimit(2)
                        // Opens the artist in the sidebar when the listing linked one
                        Button { if let artist = song.artistPage { nav.open(artist) } } label: {
                            Text(song.artist).font(.title3).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .disabled(song.artistPage == nil)
                        HStack(spacing: 36) {
                            if session.signedIn {
                                let liked = library.liked.contains(song.id)
                                Button { Task { await library.toggleLike(song) } } label: {
                                    Image(systemName: liked ? "heart.fill" : "heart")
                                        .contentTransition(.symbolEffect(.replace))
                                }
                                .accessibilityLabel(liked ? "Remove like" : "Like")
                            }
                            // The queue lives with the player, in a popover, not as a sidebar tab
                            Button { showQueue = true } label: { Image(systemName: "list.bullet") }
                                .accessibilityLabel("Queue")
                                .popover(isPresented: $showQueue) {
                                    NavigationStack { QueueView().navigationTitle("Up next").navigationBarTitleDisplayMode(.inline) }
                                        .frame(minWidth: 380, idealWidth: 420, minHeight: 560)
                                        .tint(.gold)
                                }
                        }
                        .font(.title2).foregroundStyle(Color.gold)
                        .buttonStyle(.plain)
                        .padding(.top, 8)
                    }
                    .multilineTextAlignment(.center)
                    if let e = player.error {
                        PlayError(details: e)
                    } else {
                        progress
                    }
                    controls
                }
                .frame(maxWidth: 420)
                LyricsView()
            }
            .padding(wide ? 40 : 28)
            .onGeometryChange(for: Bool.self) { $0.size.width > 760 } action: { wide = $0 }
            .background { Backdrop(url: song.artwork ?? song.thumbnail).id(song.id) }
            .animation(.easeInOut(duration: 0.6), value: song.id)
        } else {
            ContentUnavailableView("Nothing playing", systemImage: "music.note",
                                   description: Text("Search for a song, or open your library, to start listening."))
        }
    }

    private var progress: some View {
        VStack(spacing: 6) {
            // Only a drag seeks. Seeking from the binding also fired when the range changed
            // under it at a song switch, sending the new song to the old one's position.
            Slider(value: Binding(get: { scrub ?? player.time }, set: { if scrub != nil { scrub = $0 } }),
                   in: 0...max(player.duration, 1)) { dragging in
                if dragging { scrub = player.time } else if let t = scrub { player.seek(t); scrub = nil }
            }
            .tint(.white)
            .disabled(player.duration == 0)
            HStack {
                Text(format(scrub ?? player.time)); Spacer(); Text(format(player.duration))
            }
            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 40) {
            Button { player.shuffleUpcoming() } label: { Image(systemName: "shuffle").font(.title3) }
                .accessibilityLabel("Shuffle upcoming")
            Button { player.previous() } label: { Image(systemName: "backward.fill") }
                .accessibilityLabel("Previous")
            Button { player.toggle() } label: {
                ZStack {
                    // Still fetching the song: a spinner where the play button goes
                    if player.duration == 0 && player.error == nil {
                        ProgressView().controlSize(.large).frame(width: 72, height: 72)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 72))
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Button { player.next() } label: { Image(systemName: "forward.fill") }
                .accessibilityLabel("Next")
            Button {
                player.repeatMode = switch player.repeatMode { case .off: .all; case .all: .one; case .one: .off }
            } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat").font(.title3)
                    .foregroundStyle(player.repeatMode == .off ? Color.white : Color.gold)
            }
            .accessibilityLabel(player.repeatMode == .off ? "Repeat off" : player.repeatMode == .all ? "Repeat all" : "Repeat one")
        }
        .font(.title)
        .foregroundStyle(.white)
        .buttonStyle(.plain)
    }

    private func format(_ t: TimeInterval) -> String {
        guard t.isFinite else { return "0:00" }
        return String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

/// The cover, blurred and darkened, behind the whole Now Playing column
struct Backdrop: View {
    let url: URL?

    var body: some View {
        Color.black
            .overlay {
                AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                    .blur(radius: 80, opaque: true)
                    .saturation(1.3)
                    .overlay(Color.black.opacity(0.45))
            }
            .clipped()
            .ignoresSafeArea()
            .transition(.opacity)
    }
}

/// A short message with the next steps; the per-client reasons are behind Details
struct PlayError: View {
    let details: String
    @Environment(Player.self) private var player

    var body: some View {
        VStack(spacing: 10) {
            Label("Couldn't play this song", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
            HStack {
                Button("Try again", systemImage: "arrow.clockwise") { player.start(player.index) }
                Button("Skip", systemImage: "forward.end") { player.next() }
            }
            .buttonStyle(.bordered)
            DisclosureGroup("Details") {
                Text(details).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 14))
    }
}

struct LyricsView: View {
    @Environment(Player.self) private var player

    var body: some View {
        // Only blank lines (an instrumental's "♪") counts as none
        let lines = player.lyrics.allSatisfy { $0.text.isEmpty } ? [] : player.lyrics
        // Last line whose time has passed; plain lyrics are all at 0, so none highlights
        let synced = lines.contains { $0.time > 0 }
        let active = synced ? lines.lastIndex { $0.time <= player.time } : nil
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(synced ? .system(size: 30, weight: .bold) : .title2.weight(.semibold))
                            .foregroundStyle(.white.opacity(i == active || !synced ? 1 : 0.35))
                            .scaleEffect(i == active ? 1.03 : 1, anchor: .leading)
                            .animation(.easeOut(duration: 0.3), value: active)
                            .id(i)
                            .onTapGesture { if synced { player.seek(line.time) } }
                    }
                }
                .padding(.vertical, 240)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            // Lines fade out at the top and bottom edges instead of being cut off
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.15),
                                         .init(color: .black, location: 0.85), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay {
                if lines.isEmpty {
                    ContentUnavailableView("No lyrics", systemImage: "quote.bubble")
                }
            }
            .onChange(of: active) { _, i in
                if let i { withAnimation(.easeInOut(duration: 0.5)) { proxy.scrollTo(i, anchor: .center) } }
            }
        }
    }
}
