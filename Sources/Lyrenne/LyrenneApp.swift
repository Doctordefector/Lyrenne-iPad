import SwiftUI
import LyrenneCore

@main
struct LyrenneApp: App {
    @State private var player = Player()
    @State private var session = Session()
    @State private var downloads = DownloadStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(player)
                .environment(session)
                .environment(downloads)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { downloads.refresh() } }
    }
}

struct ContentView: View {
    // LYRENNE_TAB picks the starting tab (CI screenshots); otherwise Search
    @State private var tab = ProcessInfo.processInfo.environment["LYRENNE_TAB"] ?? "Search"
    // Both columns side by side even in portrait; the sidebar button still hides it
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            // Its own stack, so opening a playlist pushes in the sidebar and Now Playing stays put
            NavigationStack {
                VStack(spacing: 0) {
                    Picker("", selection: $tab) {
                        ForEach(["Search", "Library", "Downloads", "Queue"], id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding()
                    switch tab {
                    case "Library": LibraryView()
                    case "Downloads": DownloadsView()
                    case "Queue": QueueView()
                    default: SearchView()
                    }
                }
                .navigationTitle("Lyrenne")
                .navigationDestination(for: Playlist.self) { PlaylistView(playlist: $0) }
            }
            .navigationSplitViewColumnWidth(min: 340, ideal: 400)
        } detail: {
            NowPlayingView()
        }
        .navigationSplitViewStyle(.balanced)
    }
}

struct SongRow: View {
    let song: Song
    var playing = false
    @Environment(DownloadStore.self) private var downloads

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: song.thumbnail) { $0.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.2) }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading) {
                Text(song.title).lineLimit(1).fontWeight(playing ? .bold : .regular)
                Text(song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if downloads.isDownloaded(song.id) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.secondary).accessibilityLabel("Downloaded")
            } else if downloads.isQueued(song.id) {
                ProgressView().controlSize(.small)
            }
            if let d = song.duration { Text(d).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
        }
    }
}

struct SearchView: View {
    @Environment(Player.self) private var player
    @State private var query = ""
    @State private var results: [Song] = []
    @State private var loading = false

    var body: some View {
        List(Array(results.enumerated()), id: \.element.id) { i, song in
            Button { player.play(Array(results[i...]), at: 0) } label: { SongRow(song: song) }
                .buttonStyle(.plain)
                .songActions(song)
        }
        .listStyle(.plain)
        .overlay { if loading { ProgressView() } }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Songs, artists")
        .onSubmit(of: .search) { Task { await search() } }
        .task {
            // LYRENNE_DEMO="query": search and play the first result (CI screenshots)
            guard results.isEmpty, let demo = ProcessInfo.processInfo.environment["LYRENNE_DEMO"] else { return }
            query = demo
            await search()
            if !results.isEmpty { player.play(results, at: 0) }
        }
    }

    private func search() async {
        loading = true
        results = (try? await InnerTube.search(query)) ?? []
        loading = false
    }
}

struct QueueView: View {
    @Environment(Player.self) private var player

    var body: some View {
        @Bindable var player = player
        List {
            Toggle("Autoplay similar songs", isOn: $player.autoplay)
            ForEach(Array(player.queue.enumerated()), id: \.offset) { i, song in
                Button { player.start(i) } label: { SongRow(song: song, playing: i == player.index) }
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
    }
}

struct NowPlayingView: View {
    @Environment(Player.self) private var player
    @State private var scrub: Double? // where the thumb is while dragging; seeks only on release

    var body: some View {
        if let song = player.current {
            HStack(spacing: 32) {
                VStack(spacing: 20) {
                    // The full-size cover, with the list's small thumbnail (already loaded) until it
                    // arrives. Keyed by song: reused for the next song, AsyncImage could keep
                    // showing the previous cover.
                    AsyncImage(url: song.artwork) { $0.resizable().scaledToFit() } placeholder: {
                        AsyncImage(url: song.thumbnail) { $0.resizable().scaledToFit() } placeholder: { Color.secondary.opacity(0.2) }
                    }
                        .id(song.id)
                        .frame(maxWidth: 420, maxHeight: 420)
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(radius: 20)
                    VStack {
                        Text(song.title).font(.title2.bold()).lineLimit(2).multilineTextAlignment(.center)
                        Text(song.artist).foregroundStyle(.secondary)
                    }
                    if let e = player.error { Text(e).foregroundStyle(.red).font(.caption) }
                    // Only a drag seeks. Seeking from the binding also fired when the range changed
                    // under it at a song switch, sending the new song to the old one's position.
                    Slider(value: Binding(get: { scrub ?? player.time }, set: { if scrub != nil { scrub = $0 } }),
                           in: 0...max(player.duration, 1)) { dragging in
                        if dragging { scrub = player.time } else if let t = scrub { player.seek(t); scrub = nil }
                    }
                    .disabled(player.duration == 0)
                    HStack {
                        Text(format(scrub ?? player.time)); Spacer(); Text(format(player.duration))
                    }
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    HStack(spacing: 48) {
                        Button { player.previous() } label: { Image(systemName: "backward.fill") }
                        Button { player.toggle() } label: { Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 64)) }
                        Button { player.next() } label: { Image(systemName: "forward.fill") }
                    }
                    .font(.title)
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: 420)
                LyricsView()
            }
            .padding(32)
        } else {
            ContentUnavailableView("Nothing playing", systemImage: "music.note", description: Text("Search for a song to start listening."))
        }
    }

    private func format(_ t: TimeInterval) -> String {
        guard t.isFinite else { return "0:00" }
        return String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

struct LyricsView: View {
    @Environment(Player.self) private var player

    var body: some View {
        // Last line whose time has passed; plain lyrics are all at 0, so none highlights
        let synced = player.lyrics.contains { $0.time > 0 }
        let active = synced ? player.lyrics.lastIndex { $0.time <= player.time } : nil
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if player.lyrics.isEmpty { Text("No lyrics").foregroundStyle(.secondary) }
                    ForEach(Array(player.lyrics.enumerated()), id: \.offset) { i, line in
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.title3.weight(i == active ? .bold : .regular))
                            .foregroundStyle(i == active || !synced ? .primary : .secondary)
                            .id(i)
                            .onTapGesture { if synced { player.seek(line.time) } }
                    }
                }
                .padding(.vertical, 200)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .onChange(of: active) { _, i in
                if let i { withAnimation { proxy.scrollTo(i, anchor: .center) } }
            }
        }
    }
}
