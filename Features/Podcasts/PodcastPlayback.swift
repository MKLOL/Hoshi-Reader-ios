import AVFoundation
import MediaPlayer
import Observation

@Observable @MainActor final class PodcastPlayback {
    static let shared = PodcastPlayback()
    private(set) var episode: PodcastEpisode?
    private(set) var playing = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var error: String?
    var speed: Float = 1 { didSet { if playing { player?.rate = speed }; updateNowPlaying() } }
    private var player: AVPlayer?
    private var account: String?
    private var ticker: Any?
    private var observer: NSKeyValueObservation?
    private var finished: NSObjectProtocol?
    private var interrupted: NSObjectProtocol?
    private var routeChanged: NSObjectProtocol?
    private var commands: [(MPRemoteCommand, Any)] = []
    private var seekGeneration = 0

    func play(_ episode: PodcastEpisode) {
        let store = PodcastStore.shared
        guard store.enabled, let account = store.account, let url = store.files.audio(account: account, id: episode.id), store.isDownloaded(episode.id) else { error = "The downloaded lesson is missing. Download it again."; return }
        stop()
        self.episode = episode; self.account = account; error = nil
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .spokenAudio)
            try audio.setActive(true)
            let item = AVPlayerItem(url: url), player = AVPlayer(playerItem: AVPlayerItem(url: url))
            player.replaceCurrentItem(with: item)
            self.player = player
            duration = episode.lessonDurationSeconds ?? 0
            let saved = store.files.position(account: account, id: episode.id)
            position = saved < 0 || (duration > 0 && saved >= duration - 1) ? 0 : saved
            observer = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
                Task { @MainActor in
                    guard let self, self.player?.currentItem === item else { return }
                    if item.status == .failed { self.error = PodcastRules.display(item.error?.localizedDescription) ?? "Playback failed."; self.playing = false }
                    if item.duration.seconds.isFinite { self.duration = max(0, item.duration.seconds) }
                    self.updateNowPlaying()
                }
            }
            ticker = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] time in
                Task { @MainActor in
                    guard let self, self.player === player, time.seconds.isFinite else { return }
                    self.position = max(0, time.seconds)
                    if item.duration.seconds.isFinite { self.duration = max(0, item.duration.seconds) }
                    self.savePosition(); self.updateNowPlaying()
                }
            }
            finished = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.playing = false; self?.savePosition(); self?.updateNowPlaying() }
            }
            interrupted = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.pause() } }
            routeChanged = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
                if note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { Task { @MainActor in self?.pause() } }
            }
            installCommands()
            seek(to: position)
            playing = true; player.playImmediately(atRate: speed); updateNowPlaying()
        } catch { self.error = PodcastRules.display(error.localizedDescription); playing = false }
    }
    func toggle() {
        if playing { pause() } else {
            if let episode, duration > 0 && position >= duration - 1 { play(episode); return }
            guard player != nil, PodcastStore.shared.enabled, PodcastStore.shared.account == account else { return }
            playing = true; player?.playImmediately(atRate: speed); updateNowPlaying()
        }
    }
    func pause() { player?.pause(); playing = false; savePosition(); updateNowPlaying() }
    func seek(to seconds: Double) {
        guard seconds.isFinite, let player else { return }
        let target = max(0, duration > 0 ? min(duration, seconds) : seconds)
        seekGeneration += 1; let generation = seekGeneration
        position = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] landed in
            Task { @MainActor in
                guard let self, landed, self.player === player, self.seekGeneration == generation else { return }
                let actual = player.currentTime().seconds
                if actual.isFinite { self.position = max(0, actual) }
                self.savePosition(); self.updateNowPlaying()
            }
        }
    }
    func stop() {
        savePosition(); player?.pause()
        if let ticker { player?.removeTimeObserver(ticker) }; ticker = nil
        observer = nil
        for token in [finished, interrupted, routeChanged].compactMap({ $0 }) { NotificationCenter.default.removeObserver(token) }
        finished = nil; interrupted = nil; routeChanged = nil
        for (command, token) in commands { command.removeTarget(token) }; commands = []
        player = nil; episode = nil; account = nil; playing = false; position = 0; duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    private func savePosition() {
        guard let account, let episode else { return }
        PodcastStore.shared.files.savePosition(position, account: account, id: episode.id)
    }
    private func updateNowPlaying() {
        guard let episode else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: PodcastRules.display(episode.title) ?? "Podcast lesson", MPMediaItemPropertyPlaybackDuration: duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: position, MPNowPlayingInfoPropertyPlaybackRate: playing ? speed : 0]
    }
    private func installCommands() {
        let center = MPRemoteCommandCenter.shared()
        commands.append((center.playCommand, center.playCommand.addTarget { [weak self] _ in Task { @MainActor in if self?.playing == false { self?.toggle() } }; return .success }))
        commands.append((center.pauseCommand, center.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }))
        for (command, delta) in [(center.skipForwardCommand, 15.0), (center.skipBackwardCommand, -15.0)] {
            command.preferredIntervals = [15]
            commands.append((command, command.addTarget { [weak self] _ in Task { @MainActor in guard let self else { return }; self.seek(to: self.position + delta) }; return .success }))
        }
        commands.append((center.changePlaybackPositionCommand, center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let time = event.positionTime
            Task { @MainActor in self?.seek(to: time) }; return .success
        }))
    }
}
