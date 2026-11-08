import CryptoKit
import Foundation

@MainActor
final class ReadingPositionSession {
    let initialBookmark: Bookmark?
    let bookId: String
    private let device: ReadingDevice
    private let originId: String
    private let sessionId = UUID().uuidString.lowercased()
    private let nextSequence: () -> Int64
    private var previous: ReadingPosition
    private var parent: String?
    private var stamp: Double
    private var seen: [String: Int64]

    init(bookId: String, initialBookmark: Bookmark?, device: ReadingDevice, origin: String,
         state: ReadingPositionState, nextSequence: @escaping () -> Int64) {
        self.bookId = bookId; self.initialBookmark = initialBookmark; self.device = device
        originId = origin; self.nextSequence = nextSequence
        previous = initialBookmark.map(ReadingPosition.init) ?? ReadingPosition(chapterIndex: 0, progress: 0, characterCount: 0)
        parent = state.winner?.id
        stamp = initialBookmark?.lastModified?.timeIntervalSinceReferenceDate ?? 0
        seen = state.frontier
    }
    func navigate(bookmark: Bookmark, action: String = "pageTurn") -> ReadingPositionEvent? {
        let position = ReadingPosition(bookmark)
        guard position.isValid, !position.samePlace(as: previous), let date = bookmark.lastModified,
              abs(date.timeIntervalSinceReferenceDate) <= 1e12 else { return nil }
        let time = date.timeIntervalSinceReferenceDate, number = nextSequence()
        let compatibility = ReadingPositionProtocol.nextTimestamp(action: time, previous: stamp)
        let event = ReadingPositionEvent(id: UUID().uuidString.lowercased(), deviceId: device.id, deviceName: device.name,
            originId: originId, sequence: number, sessionId: sessionId, action: action, from: previous,
            position: position, occurredAt: time, compatibilityAt: compatibility, basedOn: parent,
            seen: seen, missingTimestamp: false, bookId: bookId)
        previous = position; parent = event.id; stamp = compatibility; seen[originId] = number
        return event
    }
    fileprivate func adoptSamePlace(_ state: ReadingPositionState) {
        guard let winner = state.winner, winner.originId != originId,
              (seen[winner.originId] ?? 0) < winner.sequence, winner.position.samePlace(as: previous) else { return }
        seen = seen.filter { !$0.key.hasPrefix("legacy-") || state.heads[$0.key] != nil }
        seen[winner.originId] = winner.sequence
        parent = winner.id; stamp = max(stamp, winner.compatibilityAt)
    }
}

@MainActor
private final class WeakPositionSession {
    weak var value: ReadingPositionSession?
    init(_ value: ReadingPositionSession) { self.value = value }
}

/// Durable own-writer journals live outside book payloads. Journal commit precedes the released
/// bookmark projection, so a crash cannot erase the navigation that produced that projection.
@MainActor
final class ReadingPositionRepository {
    static let shared = ReadingPositionRepository()
    let directory: URL
    let device: ReadingDevice
    private var origin: String
    private var sequence: Int64 = 0
    private var sessions: [String: [WeakPositionSession]] = [:]
    private var cached: [String: ReadingPositionState] = [:]
    private var ownIndex: [String: Set<String>]?
    private(set) var indexGeneration = 0
    private let encoder: JSONEncoder = { let value = JSONEncoder(); value.outputFormatting = [.sortedKeys]; return value }()

    init(directory: URL? = nil, device: ReadingDevice? = nil) {
        self.directory = directory ?? ((try? BookStorage.getAppDirectory()) ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("reading-positions", isDirectory: true)
        self.device = device ?? .current
        struct Identity: Codable { var deviceId: String; var origin: String }
        let file = self.directory.appendingPathComponent("origin.json")
        if let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode(Identity.self, from: data),
           stored.deviceId == self.device.id, UUID(uuidString: stored.origin) != nil { origin = stored.origin }
        else {
            origin = UUID().uuidString.lowercased()
            try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(Identity(deviceId: self.device.id, origin: origin)) { try? data.write(to: file, options: .atomic) }
        }
    }
    func open(bookId: String, root: URL) -> ReadingPositionSession {
        let state = observing(bookId: bookId, root: root, state: read(bookId))
        try? persist(state, root: root)
        sequence = max(sequence, state.heads[origin]?.sequence ?? 0)
        let session = ReadingPositionSession(bookId: bookId, initialBookmark: state.winner?.bookmark ?? BookStorage.loadBookmark(root: root),
            device: device, origin: origin, state: state, nextSequence: { [unowned self] in self.sequence += 1; return self.sequence })
        sessions[bookId, default: []].removeAll { $0.value == nil }
        sessions[bookId, default: []].append(WeakPositionSession(session))
        return session
    }
    @discardableResult
    func record(root: URL, event: ReadingPositionEvent) -> Bookmark? {
        do {
            let state = observing(bookId: event.bookId, root: root, state: read(event.bookId))
            let merged = try state.merging([event], ownPending: [event.id])
            try persist(merged, root: root)
            return merged.winner?.bookmark
        } catch { return nil }
    }
    /// Ingest resolved map/TTU projections without assigning a new timestamp to the import.
    @discardableResult
    func saveLegacy(bookId: String, root: URL, bookmark: Bookmark) -> Bookmark? {
        var state = observing(bookId: bookId, root: root, state: read(bookId))
        let time = bookmark.lastModified?.timeIntervalSinceReferenceDate ?? 0
        let old = state.winner
        // A corrupt imported time cannot be ordered (and would trap the millisecond conversion).
        if abs(time) <= 1e12, old == nil || ReadingPositionProtocol.wireMillis(time) > ReadingPositionProtocol.wireMillis(old!.compatibilityAt) ||
            (ReadingPositionProtocol.wireMillis(time) == ReadingPositionProtocol.wireMillis(old!.compatibilityAt) && !sameBookmark(bookmark, old!.bookmark)) {
            state = importing(bookmark, into: state)
        }
        try? persist(state, root: root)
        return state.winner?.bookmark
    }
    func observe(bookId: String, root: URL) {
        let state = observing(bookId: bookId, root: root, state: read(bookId))
        try? persist(state, root: root)
    }
    /// A user-requested TTU import is a new deliberate navigation, even when the remote file
    /// is older. Automatic imports retain the remote timestamp through saveLegacy instead.
    @discardableResult
    func importExplicit(bookId: String, root: URL, bookmark: Bookmark) -> Bookmark? {
        let session = open(bookId: bookId, root: root)
        let requested = Bookmark(chapterIndex: bookmark.chapterIndex, progress: bookmark.progress,
            characterCount: bookmark.characterCount, lastModified: .now)
        guard let event = session.navigate(bookmark: requested, action: "ttuImport") else { return session.initialBookmark }
        return record(root: root, event: event)
    }
    @discardableResult
    func merge(_ journal: ReadingPositionJournal, root: URL?) throws -> Bool {
        var incoming = Dictionary((journal.events + journal.heads).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values.map { $0 }
        incoming.sort(by: ReadingPositionEvent.ordered)
        guard journal.version == 1, ReadingPositionProtocol.validID(journal.bookId), incoming.count <= 512,
              incoming.allSatisfy({ $0.deviceId == journal.deviceId && $0.bookId == journal.bookId && $0.isValid }) else {
            throw ReadingPositionProtocolError.invalidJournal
        }
        let old = root.flatMap { BookStorage.loadBookmark(root: $0) }.map(ReadingPosition.init)
        let state = root.map { observing(bookId: journal.bookId, root: $0, state: read(journal.bookId)) } ?? read(journal.bookId)
        let merged = try state.merging(incoming)
        try persist(merged, root: root)
        if let winner = merged.winner { return root != nil && (old == nil || !winner.position.samePlace(as: old!)) }
        return false
    }
    func export(bookId: String) -> ReadingPositionJournal? {
        let state = read(bookId), heads = stateHeads(bookId: bookId)
        guard !heads.isEmpty else { return nil }
        let events = state.events.filter { $0.deviceId == device.id }
        return ReadingPositionJournal(bookId: bookId, deviceId: device.id, events: events, heads: heads)
    }
    func acknowledge(bookId: String, ids: Set<String>) {
        var state = read(bookId); state.pending.subtract(ids)
        try? persist(state, root: nil)
    }
    func ownHistories() -> [String: Set<String>] {
        if ownIndex == nil {
            ownIndex = [:]
            for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] where file.lastPathComponent.hasPrefix("book-") && file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file), let state = try? JSONDecoder().decode(ReadingPositionState.self, from: data),
                      state.heads.values.contains(where: { $0.deviceId == device.id }) else { continue }
                ownIndex?[state.bookId] = state.pending
            }
        }
        return ownIndex ?? [:]
    }
    func loadSyncIndex() -> (Data?, Int) { ((try? Data(contentsOf: directory.appendingPathComponent("sync-index.json"))), indexGeneration) }
    func saveSyncIndex(_ data: Data, generation: Int) {
        guard generation == indexGeneration else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("sync-index.json"), options: .atomic)
    }
    func snapshot(bookId: String) -> ReadingPositionState { read(bookId) }
    #if DEBUG
    /// Drops every journal and the sync index, as on a new installation, under a new origin so
    /// no sequence the server already holds is reused. Tests simulate a fresh install with it.
    func removeAllHistory() {
        try? FileManager.default.removeItem(at: directory)
        cached = [:]; ownIndex = nil; sessions = [:]; sequence = 0
        indexGeneration += 1
        origin = UUID().uuidString.lowercased()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identity = ["deviceId": device.id, "origin": origin]
        if let data = try? encoder.encode(identity) { try? data.write(to: directory.appendingPathComponent("origin.json"), options: .atomic) }
    }
    #endif
    private func stateHeads(bookId: String) -> [ReadingPositionEvent] {
        read(bookId).heads.values.filter { $0.deviceId == device.id }.sorted { $0.originId < $1.originId }
    }
    private func read(_ bookId: String) -> ReadingPositionState {
        if let state = cached[bookId] { return state }
        let file = fileURL(bookId)
        guard FileManager.default.fileExists(atPath: file.path) else { return ReadingPositionState(bookId: bookId) }
        if let data = try? Data(contentsOf: file), let state = try? JSONDecoder().decode(ReadingPositionState.self, from: data),
           state.bookId == bookId, state.heads.values.allSatisfy(\.isValid), state.events.allSatisfy(\.isValid) {
            cached[bookId] = state; return state
        }
        try? FileManager.default.moveItem(at: file, to: file.appendingPathExtension(UUID().uuidString + ".corrupt"))
        cached[bookId] = nil; ownIndex?[bookId] = nil
        indexGeneration += 1
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("sync-index.json"))
        // A lost journal must never reuse a sequence whose higher value exists on the server.
        origin = UUID().uuidString.lowercased()
        let identity = ["deviceId": device.id, "origin": origin]
        if let data = try? encoder.encode(identity) { try? data.write(to: directory.appendingPathComponent("origin.json"), options: .atomic) }
        return ReadingPositionState(bookId: bookId)
    }
    private func observing(bookId: String, root: URL, state: ReadingPositionState) -> ReadingPositionState {
        guard let bookmark = BookStorage.loadBookmark(root: root) else { return state }
        let time = bookmark.lastModified?.timeIntervalSinceReferenceDate ?? 0
        guard abs(time) <= 1e12 else { return state }
        if let winner = state.winner, ReadingPositionProtocol.wireMillis(time) <= ReadingPositionProtocol.wireMillis(winner.compatibilityAt) { return state }
        return importing(bookmark, into: state)
    }
    private func importing(_ projected: Bookmark, into state: ReadingPositionState) -> ReadingPositionState {
        let position = ReadingPosition(chapterIndex: max(0, projected.chapterIndex),
            progress: projected.progress.isFinite ? min(max(projected.progress, 0), 1) : 0, characterCount: max(0, projected.characterCount))
        let time = projected.lastModified?.timeIntervalSinceReferenceDate
        let validTime = time.flatMap { abs($0) <= 1e12 ? $0 : nil }
        struct Legacy: Codable { var chapterIndex: Int; var progress: Double; var characterCount: Int; var lastModified: Double? }
        let body = (try? encoder.encode(Legacy(chapterIndex: position.chapterIndex, progress: position.progress,
            characterCount: position.characterCount, lastModified: validTime))) ?? Data()
        let id = "legacy-" + Self.digest(body)
        let event = ReadingPositionEvent(id: id, deviceId: "legacy", deviceName: "Legacy client", originId: id,
            sequence: 1, sessionId: "legacy", action: "legacy", from: nil, position: position,
            occurredAt: validTime ?? 0, compatibilityAt: validTime ?? 0, basedOn: nil,
            seen: state.frontier.filter { $0.key != id }, missingTimestamp: validTime == nil, bookId: state.bookId)
        var retired = state; retired.heads = retired.heads.filter { $0.value.action != "legacy" }
        return (try? retired.merging([event])) ?? state
    }
    private func persist(_ state: ReadingPositionState, root: URL?) throws {
        let body = try encoder.encode(state)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = fileURL(state.bookId)
        if (try? Data(contentsOf: file)) != body { try body.write(to: file, options: .atomic) }
        cached[state.bookId] = state
        if ownIndex != nil {
            ownIndex?[state.bookId] = state.heads.values.contains { $0.deviceId == device.id } ? state.pending : nil
        }
        if let root, FileManager.default.fileExists(atPath: root.path), let winner = state.winner,
           !sameBookmark(BookStorage.loadBookmark(root: root), winner.bookmark) {
            // The root must already exist; final queued writes cannot recreate a deleted book.
            try BookStorage.save(winner.bookmark, inside: root, as: FileNames.bookmark)
        }
        sessions[state.bookId]?.removeAll { $0.value == nil }
        for weakSession in sessions[state.bookId] ?? [] { weakSession.value?.adoptSamePlace(state) }
    }
    private func sameBookmark(_ lhs: Bookmark?, _ rhs: Bookmark) -> Bool {
        guard let lhs else { return false }
        return lhs.chapterIndex == rhs.chapterIndex && lhs.progress == rhs.progress && lhs.characterCount == rhs.characterCount && lhs.lastModified == rhs.lastModified
    }
    private func fileURL(_ bookId: String) -> URL { directory.appendingPathComponent("book-" + Self.digest(Data(bookId.utf8)) + ".json") }
    nonisolated static func digest(_ data: Data) -> String { SHA256.hash(data: data).lowercaseHex }
}

@MainActor
extension ReadingPosition {
    init(_ bookmark: Bookmark) { self.init(chapterIndex: bookmark.chapterIndex, progress: bookmark.progress, characterCount: bookmark.characterCount) }
}
@MainActor
extension ReadingPositionEvent {
    var bookmark: Bookmark { Bookmark(chapterIndex: position.chapterIndex, progress: position.progress,
        characterCount: position.characterCount, lastModified: missingTimestamp ? nil : Date(timeIntervalSinceReferenceDate: compatibilityAt)) }
}
