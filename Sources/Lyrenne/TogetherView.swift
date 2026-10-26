import SwiftUI
import LyrenneCore

/// A Listen Together room joined as a guest: the host's song, play/pause and position drive the
/// player. The queue is the room's one song, so autoplay is off while in a room.
@MainActor @Observable
final class Room {
    enum Status: Equatable { case idle, waiting, joined(String) }
    var status = Status.idle
    var message: String?

    private var client: ListenTogether.Client?
    private var track: Song?                  // the room's song; play/pause/seek don't resend it
    private var target: ListenTogether.State? // where the host is, applied once the song has loaded
    private var savedAutoplay = true

    func join(code: String, name: String, player: Player) {
        let client = ListenTogether.Client()
        self.client = client
        status = .waiting
        message = nil
        savedAutoplay = player.autoplay
        player.autoplay = false
        player.onLoaded = { [weak self] id in self?.loaded(id, player) }
        Task {
            for await event in client.join(code: code.trimmingCharacters(in: .whitespaces), name: name) {
                guard self.client === client else { break } // left, or joined another room since
                self.handle(event, player)
            }
        }
    }

    func leave(_ player: Player) {
        client?.leave()
        end(nil, player)
    }

    func resync() { client?.requestSync() }

    private func end(_ why: String?, _ player: Player) {
        client = nil; track = nil; target = nil
        status = .idle
        message = why
        player.onLoaded = nil
        player.autoplay = savedAutoplay
    }

    private func handle(_ event: ListenTogether.Event, _ player: Player) {
        switch event {
        case .joined(let code, let s):
            status = .joined(code)
            apply(s, player)
        case .state(let s):
            apply(s, player)
        case .sync("change_track", var s):
            s.playing = false; s.position = 0 // the host plays once every guest has loaded it
            apply(s, player)
        case .sync("seek", var s):
            s.playing = player.isPlaying
            apply(s, player)
        case .sync("play", let s), .sync("pause", let s):
            apply(s, player)
        case .ended(let why):
            end(why, player)
        case .sync, .other:
            break // queue edits, volume, users coming and going
        }
    }

    private func apply(_ s: ListenTogether.State, _ player: Player) {
        guard let song = s.track ?? track else { return }
        track = song
        target = s
        if player.current?.id != song.id {
            player.play([song], at: 0) // loaded() applies the target
        } else if player.duration > 0 || player.error != nil {
            settle(player)
        }
    }

    private func loaded(_ id: String, _ player: Player) {
        guard id == track?.id else { return }
        client?.ready(id)
        settle(player)
    }

    private func settle(_ player: Player) {
        guard let t = target else { return }
        var position = Double(t.position) / 1000
        // Positions are stamped with the sender's clock in ms; a playing room has moved on since
        if t.playing, t.at > 0 { position += max(0, Date().timeIntervalSince1970 - Double(t.at) / 1000) }
        if abs(player.time - position) > 1.5 { player.seek(position) }
        player.setPlaying(t.playing)
    }
}

struct TogetherView: View {
    @Environment(Room.self) private var room
    @Environment(Player.self) private var player
    @AppStorage("togetherName") private var name = "iPad"
    @State private var code = ""
    private var canJoin: Bool { !code.trimmingCharacters(in: .whitespaces).isEmpty && !name.isEmpty }

    var body: some View {
        List {
            switch room.status {
            case .idle:
                Section {
                    TextField("Room code", text: $code)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .font(.title3.monospaced())
                    TextField("Your name", text: $name)
                } footer: {
                    Text("Join a room someone started in Lyrenne on their computer or phone (Listen Together). Their music plays here in sync; the host approves you first.")
                }
                Section {
                    Button { room.join(code: code, name: name, player: player) } label: {
                        Label("Join room", systemImage: "person.2.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .foregroundStyle(canJoin ? Color.onGold : .secondary)
                    .disabled(!canJoin)
                    .listRowBackground(Color.clear)
                    if let m = room.message {
                        Label(m, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                    }
                }
            case .waiting:
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Waiting for the host to let you in…")
                    }
                    Button("Cancel", role: .destructive) { room.leave(player) }
                }
            case .joined(let roomCode):
                Section {
                    LabeledContent("Room", value: roomCode).font(.body.monospaced())
                    if let song = player.current { SongRow(song: song) }
                } footer: {
                    Text("The host picks the songs. Pausing here only pauses you; Resync catches up with the room.")
                }
                Section {
                    Button("Resync with host", systemImage: "arrow.triangle.2.circlepath") { room.resync() }
                    Button("Leave room", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { room.leave(player) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .animation(.default, value: room.status)
    }
}
