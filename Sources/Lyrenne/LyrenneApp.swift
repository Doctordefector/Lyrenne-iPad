import SwiftUI
import LyrenneCore

@main
struct LyrenneApp: App {
    @State private var player = Player()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(player)
                .preferredColorScheme(.dark)
        }
    }
}

struct ContentView: View {
    @Environment(Player.self) private var player
    @State private var tab = "Search"

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("Search").tag("Search")
                    Text("Queue").tag("Queue")
                }
                .pickerStyle(.segmented)
                .padding()
                if tab == "Search" { SearchView() } else { QueueView() }
            }
            .navigationTitle("Lyrenne")
        } detail: {
            NowPlayingView()
        }
    }
}

struct SongRow: View {
    let song: Song
    var playing = false

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
                .contextMenu { Button("Add to queue", systemImage: "text.badge.plus") { player.enqueue(song) } }
        }
        .listStyle(.plain)
        .overlay { if loading { ProgressView() } }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Songs, artists")
        .onSubmit(of: .search) {
            loading = true
            Task {
                results = (try? await InnerTube.search(query)) ?? []
                loading = false
            }
        }
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

    var body: some View {
        if let song = player.current {
            HStack(spacing: 32) {
                VStack(spacing: 20) {
                    AsyncImage(url: song.thumbnail) { $0.resizable().scaledToFit() } placeholder: { Color.secondary.opacity(0.2) }
                        .frame(maxWidth: 420, maxHeight: 420)
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(radius: 20)
                    VStack {
                        Text(song.title).font(.title2.bold()).lineLimit(2).multilineTextAlignment(.center)
                        Text(song.artist).foregroundStyle(.secondary)
                    }
                    if let e = player.error { Text(e).foregroundStyle(.red).font(.caption) }
                    Slider(value: Binding(get: { player.time }, set: { player.seek($0) }), in: 0...max(player.duration, 1))
                    HStack {
                        Text(format(player.time)); Spacer(); Text(format(player.duration))
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
