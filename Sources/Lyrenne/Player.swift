import AVFoundation
import MediaPlayer
import Observation
import UIKit
import LyrenneCore

/// The iPad counterpart of desktop's DesktopPlayer: one queue, AVPlayer instead of VLC,
/// and the lock screen / Control Center instead of the tray and media keys.
@MainActor @Observable
final class Player {
    var queue: [Song] = []
    var index = 0
    var isPlaying = false
    var time: TimeInterval = 0
    var duration: TimeInterval = 0
    var lyrics: [LyricLine] = []
    var error: String?
    var autoplay = true
    var repeatMode = Repeat.off
    enum Repeat { case off, all, one }
    /// Called once a started song has loaded, or failed to (Listen Together reports it ready)
    @ObservationIgnored var onLoaded: (@MainActor (String) -> Void)?

    var current: Song? { queue.indices.contains(index) ? queue[index] : nil }

    private let av = AVPlayer()
    private var artwork: MPMediaItemArtwork?
    private var loadTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var statusObservation: NSKeyValueObservation?

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        av.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, self.av.currentItem != nil else { return }
                self.time = t.seconds
                // The listed length first: YouTube's m4a gives its full length in the header and
                // again in its fragments, and AVPlayer adds the two, nearly doubling it
                if let d = self.current?.seconds ?? self.av.currentItem?.duration.seconds, d.isFinite, d != self.duration {
                    self.duration = d
                    self.updateNowPlaying() // the lock screen's bar needs the length
                }
                // That doubled length also means AVPlayer never reaches its own end: it sits in
                // silence past the real one, so didPlayToEnd never fires. End on the listed length.
                if let listed = self.current?.seconds, self.time >= listed - 0.5 { self.ended() }
            }
        }
        // Play/pause state straight from AVPlayer. The periodic observer stops firing while
        // paused, so reading it there left the button and the lock screen showing the old state
        // until the next play/pause.
        statusObservation = av.observe(\.timeControlStatus) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in
                guard let self, self.isPlaying != playing else { return }
                self.isPlaying = playing
                self.updateNowPlaying()
            }
        }
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.ended() }
        }
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.av.play() }; return .success }
        cc.pauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.av.pause() }; return .success }
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.toggle() }; return .success }
        cc.nextTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.next() }; return .success }
        cc.previousTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.previous() }; return .success }
        cc.changePlaybackPositionCommand.addTarget { [weak self] e in
            let t = (e as? MPChangePlaybackPositionCommandEvent)?.positionTime ?? 0
            MainActor.assumeIsolated { self?.seek(t) }
            return .success
        }
    }

    func play(_ songs: [Song], at i: Int) {
        queue = songs
        start(i)
    }

    /// [song] and the songs listed after it among [items]
    func play(_ song: Song, in items: [Item]) {
        let songs = items.compactMap(\.song)
        play(songs, at: songs.firstIndex(of: song) ?? 0)
    }

    func enqueue(_ song: Song) {
        queue.append(song)
        if queue.count == 1 { start(0) }
    }

    func playNext(_ song: Song) {
        if queue.isEmpty { return enqueue(song) }
        queue.insert(song, at: index + 1)
    }

    /// Shuffle what's still to come; the playing song and those already played stay put
    func shuffleUpcoming() {
        guard index + 1 < queue.count else { return }
        queue[(index + 1)...].shuffle()
        prefetchNext()
    }

    func toggle() {
        guard av.currentItem != nil else { return } // still loading: nothing to play yet
        av.timeControlStatus == .paused ? av.play() : av.pause()
    }

    func setPlaying(_ playing: Bool) {
        guard av.currentItem != nil else { return }
        playing ? av.play() : av.pause()
    }

    func next() {
        if index + 1 < queue.count { start(index + 1) }
        else if repeatMode == .all, !queue.isEmpty { start(0) }
        else { av.pause() }
    }

    /// The song played to its end: again under repeat one, else the next. Next and the lock
    /// screen still skip a repeated song.
    private func ended() {
        if repeatMode == .one { seek(0); av.play() } else { next() }
    }

    func previous() {
        // Like every player: a few seconds in, "previous" restarts the song
        if time > 3 || index == 0 { seek(0) } else { start(index - 1) }
    }

    func seek(_ t: TimeInterval) {
        av.seek(to: CMTime(seconds: t, preferredTimescale: 600))
        time = t
        updateNowPlaying()
    }

    func start(_ i: Int) {
        guard queue.indices.contains(i) else { return }
        index = i
        let song = queue[i]
        // Unload the previous song now, not when the next one is ready: left loaded, a play
        // pressed while the next one loaded resumed the old song, and its position kept
        // reporting into the new song's time and lyrics
        av.replaceCurrentItem(with: nil)
        time = 0; duration = 0; lyrics = []; error = nil; artwork = nil
        updateNowPlaying()
        loadTask?.cancel()
        loadTask = Task {
            // Lyrics and artwork don't wait on the audio, and still show if it fails
            async let lyr = Lyrics.fetch(title: song.title, artist: song.artist, length: song.seconds, videoId: song.id)
            async let art = loadArtwork(song.artwork)
            do {
                let local = Downloads.file(for: song.id)
                let url = if let local { local } else { try await fetchToCache(song.id) }
                guard !Task.isCancelled else { return }
                try? AVAudioSession.sharedInstance().setActive(true)
                av.replaceCurrentItem(with: AVPlayerItem(url: url))
                av.play()
                updateNowPlaying()
                prefetchNext()
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            onLoaded?(song.id)
            // Checked before writing: a song skipped mid-lookup used to put its lyrics on the next one
            let found = await lyr
            guard !Task.isCancelled else { return }
            lyrics = found
            if let image = await art {
                artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                updateNowPlaying()
            }
            // Autoplay: near the end of the queue, top it up with the song's radio
            // Not under repeat all, which would never get back round to the start
            if autoplay, repeatMode != .all, index >= queue.count - 2, let radio = try? await InnerTube.radio(after: song.id) {
                let known = Set(queue.map(\.id))
                queue += radio.filter { !known.contains($0.id) }
            }
        }
    }

    /// Streams are fetched whole and played from a file: googlevideo refuses the open-ended
    /// Range requests AVPlayer streams with (see Downloads.fetchAudio). A typical song is ~0.3 s,
    /// and the next one is usually already here (prefetchNext).
    private func fetchToCache(_ id: String) async throws -> URL {
        let file = cacheFile(id)
        if !FileManager.default.fileExists(atPath: file.path) {
            try await Downloads.fetchAudio(id).write(to: file, options: .atomic)
        }
        // Keep only the playing song and the next; AVPlayer keeps an open file readable after unlink
        let keep = [cacheFile(id), queue.indices.contains(index + 1) ? cacheFile(queue[index + 1].id) : file]
        let tmp = FileManager.default.temporaryDirectory
        for old in (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent.hasPrefix("stream-") && !keep.contains(old) {
            try? FileManager.default.removeItem(at: old)
        }
        return file
    }

    private func cacheFile(_ id: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("stream-\(id).m4a")
    }

    /// Fetch the next song while this one plays, so Next and the end of a song switch at once
    private func prefetchNext() {
        prefetchTask?.cancel()
        guard queue.indices.contains(index + 1) else { return }
        let id = queue[index + 1].id
        guard Downloads.file(for: id) == nil, !FileManager.default.fileExists(atPath: cacheFile(id).path) else { return }
        let file = cacheFile(id)
        prefetchTask = Task {
            guard let data = try? await Downloads.fetchAudio(id), !Task.isCancelled else { return }
            try? data.write(to: file, options: .atomic)
        }
    }

    private func loadArtwork(_ url: URL?) async -> UIImage? {
        guard let url, let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return UIImage(data: data)
    }

    private func updateNowPlaying() {
        guard let song = current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: time,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
