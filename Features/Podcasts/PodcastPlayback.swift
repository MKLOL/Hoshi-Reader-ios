import AVFoundation
import MediaPlayer
import Observation

@Observable @MainActor final class PodcastPlayback {
    static let shared = PodcastPlayback()
    private(set) var episode: PodcastEpisode?
    private let audioOwner = UUID()
    private(set) var playing = false {
        didSet { if !playing { LongFormAudioCoordinator.shared.end(owner: audioOwner) } }
    }
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var error: String?
    var speed: Float = 1 { didSet { if playing { player?.rate = speed }; updateNowPlaying() } }
    private var player: AVPlayer?
    private var account: String?
    private var ticker: Any?
    private var observer: NSKeyValueObservation?
    private var finished: NSObjectProtocol?
    private var failed: NSObjectProtocol?
    private var seeking = false
    private var ended = false
    private var nowPlayingSession: MPNowPlayingSession?
    private var interrupted: NSObjectProtocol?
    private var routeChanged: NSObjectProtocol?
    private var resumeAfterInterruption = false
    private var commands: [(MPRemoteCommand, Any)] = []
    private var seekGeneration = 0

    func play(_ episode: PodcastEpisode) {
        let store = PodcastStore.shared
        guard store.enabled, let account = store.account, let url = store.files.audio(account: account, id: episode.id), store.isDownloaded(episode.id) else {
            error = "The downloaded lesson is missing. Download it again."; store.revision += 1; return
        }
        stop()
        self.episode = episode; self.account = account; error = nil
        do {
            LongFormAudioCoordinator.shared.begin(owner: audioOwner) { [weak self] in self?.pause() }
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .spokenAudio)
            try audio.setActive(true)
            let item = AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: item)
            self.player = player
            duration = max(0, episode.lessonDurationSeconds ?? 0)
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
                    guard let self, self.player === player, !self.seeking, !self.ended, time.seconds.isFinite else { return }
                    self.position = max(0, time.seconds)
                    if item.duration.seconds.isFinite { self.duration = max(0, item.duration.seconds) }
                    self.savePosition(); self.updateNowPlaying()
                }
            }
            finished = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.player?.currentItem === item else { return }
                    self.playing = false; self.ended = true
                    self.position = 0 // A completed lesson starts at the beginning next time.
                    self.savePosition(); self.updateNowPlaying()
                }
            }
            failed = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
                let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
                Task { @MainActor in
                    guard let self, self.player?.currentItem === item else { return }
                    self.pause(); self.error = PodcastRules.display(message) ?? "Playback failed."
                }
            }
            interrupted = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
                let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                Task { @MainActor in
                    guard let self, self.player === player else { return }
                    if type == .began {
                        let resume = self.playing
                        self.pause(); self.resumeAfterInterruption = resume
                    } else if type == .ended {
                        let resume = self.resumeAfterInterruption && AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
                        self.resumeAfterInterruption = false
                        if resume, !LongFormAudioCoordinator.shared.isActive { self.toggle() }
                    }
                }
            }
            routeChanged = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
                if note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { Task { @MainActor in self?.pause() } }
            }
            nowPlayingSession = MPNowPlayingSession(players: [player])
            nowPlayingSession?.becomeActiveIfPossible()
            installCommands()
            seek(to: position)
            playing = true; player.playImmediately(atRate: speed); updateNowPlaying()
        } catch { self.error = PodcastRules.display(error.localizedDescription); playing = false }
    }
    func toggle() {
        if playing { pause() } else {
            if let episode, error != nil || ended || (duration > 0 && position >= duration - 1) { play(episode); return }
            guard player != nil, PodcastStore.shared.enabled, PodcastStore.shared.account == account else { return }
            LongFormAudioCoordinator.shared.begin(owner: audioOwner) { [weak self] in self?.pause() }
            try? AVAudioSession.sharedInstance().setActive(true)
            nowPlayingSession?.becomeActiveIfPossible()
            playing = true; player?.playImmediately(atRate: speed); updateNowPlaying()
        }
    }
    func pause() { resumeAfterInterruption = false; player?.pause(); playing = false; savePosition(); updateNowPlaying() }
    func seek(to seconds: Double) {
        guard seconds.isFinite, let player else { return }
        let target = max(0, duration > 0 ? min(duration, seconds) : seconds)
        seekGeneration += 1; let generation = seekGeneration
        position = target; seeking = true; ended = false
        savePosition()
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] landed in
            Task { @MainActor in
                guard let self, self.player === player, self.seekGeneration == generation else { return }
                self.seeking = false
                guard landed else { return }
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
        for token in [finished, failed, interrupted, routeChanged].compactMap({ $0 }) { NotificationCenter.default.removeObserver(token) }
        finished = nil; failed = nil; interrupted = nil; routeChanged = nil
        for (command, token) in commands { command.removeTarget(token) }; commands = []
        player = nil; episode = nil; account = nil; playing = false; position = 0; duration = 0
        nowPlayingSession?.nowPlayingInfoCenter.nowPlayingInfo = nil
        nowPlayingSession = nil; seeking = false; ended = false; resumeAfterInterruption = false; seekGeneration += 1
    }
    private func savePosition() {
        guard let account, let episode else { return }
        PodcastStore.shared.files.savePosition(position, account: account, id: episode.id)
    }
    private func updateNowPlaying() {
        guard let episode else { return }
        nowPlayingSession?.nowPlayingInfoCenter.nowPlayingInfo = [MPMediaItemPropertyTitle: PodcastRules.display(episode.title) ?? "Podcast lesson", MPMediaItemPropertyPlaybackDuration: duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: position, MPNowPlayingInfoPropertyPlaybackRate: playing ? speed : 0]
    }
    private func installCommands() {
        guard let center = nowPlayingSession?.remoteCommandCenter else { return }
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
