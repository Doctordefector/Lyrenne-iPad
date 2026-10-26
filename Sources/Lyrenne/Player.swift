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

    var current: Song? { queue.indices.contains(index) ? queue[index] : nil }

    private let av = AVPlayer()
    private var artwork: MPMediaItemArtwork?
    private var loadTask: Task<Void, Never>?

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        av.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.time = t.seconds
                if let d = self.av.currentItem?.duration.seconds, d.isFinite { self.duration = d }
                self.isPlaying = self.av.timeControlStatus != .paused
            }
        }
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.next() }
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

    func enqueue(_ song: Song) {
        queue.append(song)
        if queue.count == 1 { start(0) }
    }

    func toggle() { av.timeControlStatus == .paused ? av.play() : av.pause() }

    func next() {
        if index + 1 < queue.count { start(index + 1) } else { av.pause() }
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
        av.pause()
        time = 0; duration = 0; lyrics = []; error = nil; artwork = nil
        loadTask?.cancel()
        loadTask = Task {
            do {
                let url = try await InnerTube.streamURL(for: song.id)
                guard !Task.isCancelled else { return }
                try? AVAudioSession.sharedInstance().setActive(true)
                av.replaceCurrentItem(with: AVPlayerItem(url: url))
                av.play()
                updateNowPlaying()
            } catch {
                guard !Task.isCancelled else { return }
                self.error = "Could not load audio stream"
                return
            }
            async let lyr = Lyrics.fetch(title: song.title, artist: song.artist)
            async let art = loadArtwork(song.thumbnail)
            lyrics = await lyr
            if let image = await art {
                artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                updateNowPlaying()
            }
            // Autoplay: near the end of the queue, top it up with the song's radio
            if autoplay, index >= queue.count - 2, let radio = try? await InnerTube.radio(after: song.id) {
                let known = Set(queue.map(\.id))
                queue += radio.filter { !known.contains($0.id) }
            }
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
            MPNowPlayingInfoPropertyPlaybackRate: av.rate,
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
