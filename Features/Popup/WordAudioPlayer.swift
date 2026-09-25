//
//  WordAudioPlayer.swift
//  Hoshi Reader
//
//  Copyright © 2026 HuangAntimony.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import AVFoundation
import os

/// AVPlayers in the same app share an audio session; taking Now Playing ownership alone
/// does not pause the previous player. Keep one long-form source audible at a time.
@MainActor final class LongFormAudioCoordinator {
    static let shared = LongFormAudioCoordinator()
    private var owner: UUID?
    private var pauseCurrent: (() -> Void)?
    private nonisolated static let audioActive = OSAllocatedUnfairLock(initialState: false)
    var isActive: Bool { owner != nil }
    nonisolated static var isAudioActive: Bool { audioActive.withLock { $0 } }
    nonisolated static func deactivateAudioIfInactive() {
        audioActive.withLock { active in
            if !active { try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation]) }
        }
    }

    func begin(owner: UUID, pause: @escaping () -> Void) {
        let previous = self.owner == owner ? nil : pauseCurrent
        self.owner = owner; pauseCurrent = pause
        Self.audioActive.withLock { $0 = true }
        previous?()
    }
    func end(owner: UUID) {
        guard self.owner == owner else { return }
        self.owner = nil; pauseCurrent = nil
        Self.audioActive.withLock { $0 = false }
    }
}

actor WordAudioPlayer {
    static let shared = WordAudioPlayer()
    
    private var player: AVPlayer?
    private var playToEndObserver: NSObjectProtocol?
    private var failedToEndObserver: NSObjectProtocol?
    private var id: UUID?
    
    private init() {}
    
    func stop(id: UUID? = nil) {
        if let id, id != self.id {
            return
        }
        cleanupPlayback()
    }
    
    func play(urlString: String, requestedMode: AudioPlaybackMode, id: UUID) {
        guard let url = URL(string: urlString) else {
            return
        }
        
        stopPlayer()
        let session = AVAudioSession.sharedInstance()
        
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: categoryOptions(for: requestedMode))
            if !LongFormAudioCoordinator.isAudioActive {
                try session.setActive(true, options: [])
            }
        } catch {
            return
        }
        
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        self.id = id
        
        playToEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task {
                await self.cleanupPlayback()
            }
        }
        
        failedToEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task {
                await self.cleanupPlayback()
            }
        }
        
        player.play()
    }
    
    private func cleanupPlayback() {
        stopPlayer()
        LongFormAudioCoordinator.deactivateAudioIfInactive()
    }
    
    private func stopPlayer() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        id = nil
        
        if let playToEndObserver {
            NotificationCenter.default.removeObserver(playToEndObserver)
            self.playToEndObserver = nil
        }
        if let failedToEndObserver {
            NotificationCenter.default.removeObserver(failedToEndObserver)
            self.failedToEndObserver = nil
        }
    }
    
    private func categoryOptions(for mode: AudioPlaybackMode) -> AVAudioSession.CategoryOptions {
        switch mode {
        case .interrupt:
            return []
        case .duck:
            return [.mixWithOthers, .duckOthers]
        case .mix:
            return [.mixWithOthers]
        }
    }
}
