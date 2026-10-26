import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Listen Together as a guest: join a desktop/Android Lyrenne room and follow the host.
/// Same server and protobuf messages as desktop's listentogether/ (listentogether.proto);
/// hosting is left out. Field numbers below are that file's.
public enum ListenTogether {
    public static let server = URL(string: "wss://metroserverx.meowery.eu/ws")!

    /// What the room is playing. Positions are milliseconds, like the protocol.
    public struct State: Sendable {
        public var track: Song?
        public var playing: Bool
        public var position: Int64
        /// Server/host clock (ms) the position was taken at, 0 if not sent
        public var at: Int64
    }

    public enum Event: Sendable {
        case joined(code: String, State)
        case sync(action: String, State) // play, pause, seek, change_track; State.track only on change_track
        case state(State)                // full resync (sync_state)
        case ended(String)               // rejected, kicked, error, socket closed
        case other(String)               // message types a guest doesn't act on
    }

    public final class Client: @unchecked Sendable {
        private let socket: URLSessionWebSocketTask
        private var pinger: Task<Void, Never>?

        public init() { socket = URLSession.shared.webSocketTask(with: server) }

        /// Connects and asks to join; the host has to approve before `.joined` arrives.
        public func join(code: String, name: String) -> AsyncStream<Event> {
            socket.resume()
            send("join_room", PB().string(1, code.uppercased()).string(2, name))
            pinger = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(25))
                    self?.send("ping")
                }
            }
            return AsyncStream { cont in
                Task {
                    while true {
                        guard let msg = try? await socket.receive() else { cont.yield(.ended("Disconnected from the room.")); break }
                        guard case .data(let data) = msg, let event = Self.decode(data) else { continue }
                        cont.yield(event)
                        if case .ended = event { break }
                    }
                    cont.finish()
                }
            }
        }

        /// Tells the host this song is loaded, so it can start everyone together
        public func ready(_ trackID: String) { send("buffer_ready", PB().string(1, trackID)) }

        public func requestSync() { send("request_sync") }

        public func leave() {
            send("leave_room")
            pinger?.cancel()
            socket.cancel(with: .normalClosure, reason: nil)
        }

        private func send(_ type: String, _ payload: PB = PB()) {
            let envelope = PB().string(1, type).bytes(2, payload.data)
            socket.send(.data(envelope.data)) { _ in }
        }

        static func decode(_ data: Data) -> Event? {
            guard let env = PBMessage(data) else { return nil }
            var payload = env.bytes(2)
            if env.bool(3) { guard let raw = gunzip(payload) else { return nil }; payload = raw }
            guard let p = PBMessage(payload) else { return nil }
            switch env.string(1) {
            case "join_approved":
                return .joined(code: p.string(1), state(p.message(4) ?? PBMessage(), track: 4, playing: 5, position: 6, at: 7))
            case "reconnected":
                return .joined(code: p.string(1), state(p.message(3) ?? PBMessage(), track: 4, playing: 5, position: 6, at: 7))
            case "sync_state":
                return .state(state(p, track: 1, playing: 2, position: 3, at: 4))
            case "sync_playback":
                let s = State(track: p.message(4).flatMap(song), playing: p.string(1) == "play", position: p.int(3), at: p.int(9))
                return .sync(action: p.string(1), s)
            case "join_rejected": return .ended("The host didn't let you in. \(p.string(1))")
            case "kicked": return .ended("You were removed from the room. \(p.string(1))")
            case "error": return .ended(p.string(2).isEmpty ? p.string(1) : p.string(2))
            case let type: return .other(type)
            }
        }

        private static func state(_ m: PBMessage, track: Int, playing: Int, position: Int, at: Int) -> State {
            State(track: m.message(track).flatMap(song), playing: m.bool(playing), position: m.int(position), at: m.int(at))
        }

        /// TrackInfo -> Song
        static func song(_ t: PBMessage) -> Song? {
            guard !t.string(1).isEmpty else { return nil }
            let secs = t.int(5) / 1000
            return Song(id: t.string(1), title: t.string(2), artist: t.string(3), thumbnail: URL(string: t.string(6)),
                        duration: secs > 0 ? String(format: "%d:%02d", secs / 60, secs % 60) : nil)
        }
    }

    /// Payloads over 100 bytes arrive gzipped (desktop's MessageCodec). Apple's zlib codec
    /// inflates raw deflate, so skip the gzip header first.
    static func gunzip(_ d: Data) -> Data? {
        #if canImport(Darwin)
        let b = [UInt8](d)
        guard b.count > 18, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { return nil }
        let flags = b[3]
        var i = 10
        if flags & 4 != 0 { guard i + 2 <= b.count else { return nil }; i += 2 + Int(b[i]) | Int(b[i + 1]) << 8 } // FEXTRA
        for bit: UInt8 in [8, 16] where flags & bit != 0 { // FNAME, FCOMMENT: zero-terminated
            while i < b.count && b[i] != 0 { i += 1 }
            i += 1
        }
        if flags & 2 != 0 { i += 2 } // FHCRC
        guard i < b.count - 8 else { return nil }
        return try? (Data(b[i..<(b.count - 8)]) as NSData).decompressed(using: .zlib) as Data
        #else
        return nil // ponytail: Linux only runs lyrenne-check, which sends nothing big enough to be gzipped back
        #endif
    }
}

/// Just enough protobuf to write Listen Together's messages
struct PB {
    var data = Data()

    func string(_ field: Int, _ s: String) -> PB { bytes(field, Data(s.utf8)) }

    func int(_ field: Int, _ v: Int64) -> PB {
        var pb = self
        pb.varint(UInt64(field) << 3)
        pb.varint(UInt64(bitPattern: v))
        return pb
    }

    func bytes(_ field: Int, _ d: Data) -> PB {
        var pb = self
        pb.varint(UInt64(field) << 3 | 2)
        pb.varint(UInt64(d.count))
        pb.data += d
        return pb
    }

    private mutating func varint(_ v: UInt64) {
        var v = v
        while v >= 0x80 { data.append(UInt8(v & 0x7f) | 0x80); v >>= 7 }
        data.append(UInt8(v))
    }
}

/// ...and to read them: the last value of each field, by number. nil if the bytes don't parse.
struct PBMessage {
    private var ints: [Int: UInt64] = [:]
    private var blobs: [Int: Data] = [:]

    init() {}

    init?(_ data: Data) {
        let b = [UInt8](data)
        var i = 0
        func varint() -> UInt64? {
            var v: UInt64 = 0
            for shift in stride(from: 0, to: 64, by: 7) {
                guard i < b.count else { return nil }
                let byte = b[i]; i += 1
                v |= UInt64(byte & 0x7f) << shift
                if byte < 0x80 { return v }
            }
            return nil
        }
        while i < b.count {
            guard let key = varint() else { return nil }
            let field = Int(key >> 3)
            switch key & 7 {
            case 0: guard let v = varint() else { return nil }; ints[field] = v
            case 1: guard i + 8 <= b.count else { return nil }; i += 8 // fixed64: not used by these messages
            case 2:
                guard let n = varint(), n <= UInt64(b.count - i) else { return nil }
                blobs[field] = Data(b[i..<(i + Int(n))]); i += Int(n)
            case 5: guard i + 4 <= b.count else { return nil }; i += 4 // float volume: not used
            default: return nil
            }
        }
    }

    func int(_ f: Int) -> Int64 { Int64(bitPattern: ints[f] ?? 0) }
    func bool(_ f: Int) -> Bool { (ints[f] ?? 0) != 0 }
    func bytes(_ f: Int) -> Data { blobs[f] ?? Data() }
    func string(_ f: Int) -> String { String(decoding: bytes(f), as: UTF8.self) }
    func message(_ f: Int) -> PBMessage? { blobs[f].flatMap(PBMessage.init) }
}
