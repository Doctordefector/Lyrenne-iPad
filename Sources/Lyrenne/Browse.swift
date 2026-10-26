import SwiftUI
import LyrenneCore

/// The sidebar's navigation stack, so the player column and song menus can open an artist or album
@MainActor @Observable
final class Nav {
    var path = NavigationPath()
    func open(_ item: Item) { path.append(item) }
}

extension Song {
    var artistPage: Item? { artistId.map { .artist(Playlist(id: $0, title: artist, subtitle: "", thumbnail: nil)) } }
    var albumPage: Item? { albumId.map { .album(Playlist(id: $0, title: title, subtitle: "", thumbnail: thumbnail)) } }
}

/// The home feed, kept across tab switches. Loaded again when the account changes.
@MainActor @Observable
final class HomeFeed {
    var shelves: [Shelf] = []
    var loading = false
    var failed = false

    /// The first page and up to four more, like desktop's five, shown as each arrives
    func load() async {
        loading = true; failed = false
        var all: [Shelf] = []
        var token: String?
        do {
            for _ in 0..<5 {
                let page = try await InnerTube.home(continuation: token)
                all += page.shelves
                shelves = all
                guard let next = page.next else { break }
                token = next
            }
        } catch {}
        // Offline, or an empty answer (a dead session's): say so instead of spinning
        failed = all.isEmpty
        loading = false
    }
}

struct HomeView: View {
    @Environment(HomeFeed.self) private var feed

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                ForEach(Array(feed.shelves.enumerated()), id: \.offset) { ShelfView(shelf: $0.element) }
            }
            .padding(.vertical)
        }
        .refreshable { await feed.load() }
        .overlay {
            if feed.shelves.isEmpty && feed.failed {
                ContentUnavailableView {
                    Label("Couldn't load Home", systemImage: "wifi.exclamationmark")
                } actions: {
                    Button("Try again") { Task { await feed.load() } }
                }
            } else if feed.shelves.isEmpty {
                ProgressView()
            }
        }
    }
}

/// A titled row of cards. Song-only shelves (Quick picks, Top songs) are rows of songs four
/// deep instead, as YouTube Music lays them out.
struct ShelfView: View {
    let shelf: Shelf

    var body: some View {
        let items = Array(shelf.items.enumerated())
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(shelf.title).font(.title3.bold())
                Spacer()
                if let more = shelf.more {
                    NavigationLink("See all", value: Item.playlist(more)).font(.subheadline)
                }
            }
            .padding(.horizontal)
            ScrollView(.horizontal) {
                if shelf.items.allSatisfy({ $0.song != nil }) {
                    LazyHGrid(rows: Array(repeating: GridItem(.fixed(56), spacing: 8), count: min(4, shelf.items.count)), spacing: 20) {
                        ForEach(items, id: \.offset) { _, item in
                            ItemLink(item, in: shelf.items) { SongRow(song: item.song!) }.frame(width: 300)
                        }
                    }
                    .padding(.horizontal)
                } else {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(items, id: \.offset) { _, item in
                            ItemLink(item, in: shelf.items) { ItemCard(item: item) }
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}

/// A song plays, with the songs after it in [items]; anything else opens its page
struct ItemLink<Label: View>: View {
    let item: Item
    let items: [Item]
    let label: Label
    @Environment(Player.self) private var player

    init(_ item: Item, in items: [Item], @ViewBuilder label: () -> Label) {
        self.item = item; self.items = items; self.label = label()
    }

    var body: some View {
        if let song = item.song {
            Button { player.play(song, in: items) } label: { label }
                .buttonStyle(.plain)
                .songActions(song)
        } else {
            NavigationLink(value: item) { label }.buttonStyle(.plain)
        }
    }
}

extension Item {
    /// Artists round, everything else a rounded square
    func shape(_ radius: CGFloat) -> AnyShape { isArtist ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: radius)) }
}

struct Cover: View {
    let url: URL?
    var icon = "music.note"

    var body: some View {
        AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: {
            Image(systemName: icon).foregroundStyle(Color.gold)
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.secondary.opacity(0.2))
        }
    }
}

struct ItemCard: View {
    let item: Item

    var body: some View {
        VStack(alignment: item.isArtist ? .center : .leading, spacing: 6) {
            Cover(url: sized(item.thumbnail, 400), icon: item.isArtist ? "person.fill" : "music.note")
                .frame(width: 150, height: 150)
                .clipShape(item.shape(12))
            Text(item.title).font(.subheadline.weight(.medium)).lineLimit(2)
            Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .multilineTextAlignment(item.isArtist ? .center : .leading)
        .frame(width: 150, alignment: item.isArtist ? .center : .leading)
        .contentShape(.rect)
    }
}

/// An album, artist or playlist in a list, beside SongRow
struct ItemRow: View {
    let item: Item

    var body: some View {
        HStack(spacing: 12) {
            Cover(url: item.thumbnail, icon: item.isArtist ? "person.fill" : "music.note.list")
                .frame(width: 48, height: 48)
                .clipShape(item.shape(8))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1)
                Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// Where an Item NavigationLink goes
struct ItemPage: View {
    let item: Item

    var body: some View {
        switch item {
        case .artist(let p): ArtistView(artist: p)
        case .album(let p), .playlist(let p): PlaylistView(playlist: p)
        case .song: EmptyView()
        }
    }
}

struct ArtistView: View {
    let artist: Playlist
    @Environment(Player.self) private var player
    @State private var page: ArtistPage?
    @State private var failed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                ForEach(Array((page?.shelves ?? []).enumerated()), id: \.offset) { ShelfView(shelf: $0.element) }
            }
            .padding(.vertical)
        }
        .navigationTitle(page?.title ?? artist.title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if page == nil { if failed { ContentUnavailableView("Couldn't load \(artist.title)", systemImage: "wifi.exclamationmark") } else { ProgressView() } }
        }
        .task {
            guard page == nil else { return }
            do { page = try await InnerTube.artist(artist.id) } catch { failed = true }
        }
    }

    private var header: some View {
        // Top songs is the first shelf; Play starts them and autoplay carries on from there
        let top = page?.shelves.first?.items.compactMap(\.song) ?? []
        return VStack(spacing: 14) {
            Cover(url: sized(page?.thumbnail ?? artist.thumbnail, 600), icon: "person.fill")
                .frame(width: 180, height: 180)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
            Text(page?.title ?? artist.title).font(.title2.bold()).multilineTextAlignment(.center)
            HStack {
                Button { player.play(top, at: 0) } label: { Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).foregroundStyle(Color.onGold)
                Button { player.play(top.shuffled(), at: 0) } label: { Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .disabled(top.isEmpty)
            .padding(.horizontal)
        }
        .frame(maxWidth: .infinity)
    }
}
