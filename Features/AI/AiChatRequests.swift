import CryptoKit
import Foundation
import Observation
import SwiftUI
import UIKit

@Observable @MainActor
final class AiChatRequest: Identifiable {
    let id = UUID()
    let key: String
    let bookKey: String
    let bubbleText: String
    let createdAt = Date()
    var state: MangaAiController.State
    var backendName = "Translation"
    var seen = false
    @ObservationIgnored var worker: MangaAiController?
    @ObservationIgnored var retry: (() -> Void)?
    @ObservationIgnored var observers: [UUID: () -> Void] = [:]
    @ObservationIgnored var lease: UIBackgroundTaskIdentifier = .invalid
    var isRunning: Bool { if case .loading = state { true } else { false } }

    init(key: String, bookKey: String, bubbleText: String) {
        self.key = key; self.bookKey = bookKey; self.bubbleText = bubbleText
        state = .loading(bubbleText: bubbleText, onDevice: false)
    }
}

/// Requests belong to the app. A popup follows a request until it closes; closing the
/// popup never changes the worker's lifetime or opens it again when a reply arrives.
@Observable @MainActor
final class AiChatRequests {
    static let shared = AiChatRequests()
    private(set) var requests: [AiChatRequest] = []
    private(set) var revision = 0

    static func bookKey(_ book: BookMetadata) -> String { syncId(for: book) ?? book.folder ?? book.id.uuidString }
    static func key(book: BookMetadata, address: String?, text: String) -> String {
        let digest = SHA256.hash(data: Data(((address.map { $0 + "\n" } ?? "") + text).utf8)).map { String(format: "%02x", $0) }.joined()
        return bookKey(book) + ":" + digest
    }
    func forBook(_ book: BookMetadata) -> [AiChatRequest] { requests.filter { $0.bookKey == Self.bookKey(book) } }
    func hasRunning(_ book: BookMetadata) -> Bool { forBook(book).contains(where: \.isRunning) }
    func hasUnseen(_ book: BookMetadata) -> Bool { forBook(book).contains { !$0.isRunning && !$0.seen } }

    func reusable(key: String, force: Bool = false) -> AiChatRequest? {
        requests.last { $0.key == key && ($0.isRunning || (!force && !$0.seen)) }
    }

    @discardableResult
    func request(key: String, bookKey: String, bubbleText: String, force: Bool = false,
                 start: @escaping @MainActor (AiChatRequest) -> Void) -> AiChatRequest {
        if let existing = reusable(key: key, force: force) { return existing }
        let item = AiChatRequest(key: key, bookKey: bookKey, bubbleText: bubbleText)
        item.retry = { [weak self, weak item] in
            guard let self, let item, !item.isRunning else { return }
            item.state = .loading(bubbleText: item.bubbleText, onDevice: false)
            item.seen = false
            self.beginLease(item)
            self.revision &+= 1
            start(item)
        }
        requests.append(item)
        // Completed replies are durable in the per-book history; only requests and errors
        // need a live owner. Keep enough recent handles to rejoin unseen replies.
        if requests.count > 200, let old = requests.firstIndex(where: { !$0.isRunning && $0.seen }) { requests.remove(at: old) }
        beginLease(item)
        revision &+= 1
        start(item)
        return item
    }

    func update(_ item: AiChatRequest, state: MangaAiController.State, backend: String) {
        item.state = state; item.backendName = backend
        if !item.isRunning {
            endLease(item)
            item.worker = nil
            if case .result = state { item.retry = nil }
            let perBook = requests.filter { $0.bookKey == item.bookKey && !$0.isRunning }
            let removeForBook = Set(perBook.prefix(max(0, perBook.count - 20)).map(\.id))
            requests.removeAll { removeForBook.contains($0.id) }
            let completed = requests.filter { !$0.isRunning }
            let removeGlobal = Set(completed.prefix(max(0, completed.count - 40)).map(\.id))
            requests.removeAll { removeGlobal.contains($0.id) }
        }
        revision &+= 1
        for observer in Array(item.observers.values) { observer() }
    }

    func dismissFailure(_ item: AiChatRequest) {
        guard !item.isRunning else { return }
        requests.removeAll { $0.id == item.id }
        revision &+= 1
    }

    private func beginLease(_ item: AiChatRequest) {
        guard item.lease == .invalid else { return }
        item.lease = UIApplication.shared.beginBackgroundTask(withName: "Translation") { [weak self, weak item] in
            guard let item else { return }
            // iOS can suspend the process after its allowance expires. Retain the task so
            // returning to the app can complete it; a popup dismissal never cancels it.
            self?.endLease(item)
        }
    }
    private func endLease(_ item: AiChatRequest) {
        guard item.lease != .invalid else { return }
        UIApplication.shared.endBackgroundTask(item.lease)
        item.lease = .invalid
    }
}

struct TranslationHistoryButton: View {
    let book: BookMetadata
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "clock.arrow.circlepath")
                if AiChatRequests.shared.hasRunning(book) {
                    ProgressView().controlSize(.mini).offset(x: 7, y: -7)
                } else if AiChatRequests.shared.hasUnseen(book) {
                    Circle().fill(Color.accentColor).frame(width: 7, height: 7).offset(x: 5, y: -5)
                }
            }
        }
        .accessibilityLabel("Translation history")
    }
}
