import Foundation
import Observation
import UIKit

nonisolated enum HoshiAutomation {
    static var isTesting: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment.keys.contains { $0.hasPrefix("HOSHI_UI_TESTING") || $0.hasPrefix("XCTest") || $0 == "XCInjectBundleInto" }
            || NSClassFromString("XCTestCase") != nil
    }

    static var preventReports: Bool {
        #if DEBUG || targetEnvironment(simulator)
        true
        #else
        isTesting
        #endif
    }
}

/// The complete wire whitelist. No titles, file names, device name, account, server URL,
/// sync identifiers or credentials can enter this payload.
nonisolated struct AnonymousStatsPayload: Encodable, Sendable {
    let installId: String
    var platform = "ios"
    var appVersion: String?
    var versionCode: Int?
    var buildType: String?
    var osVersion: String?
    var manufacturer: String?
    var model: String?
    var emulator: Bool?
    var screenWidthPx: Int?
    var screenHeightPx: Int?
    var locale: String?
    var appLanguage: String?
    var epubCount: Int?
    var mangaCount: Int?
    var cloudOnlyCount: Int?
    var dictionaryCount: Int?
    var httpSyncEnabled: Bool?
    var driveSyncEnabled: Bool?
    var readerContinuous: Bool?
    var readerVertical: Bool?
}

nonisolated struct AnonymousStatsState: Codable, Equatable, Sendable {
    var installId: String?
    var notBefore: Date?
    var lastSentAt: Date?
    var lastAttemptAt: Date?
}

@Observable @MainActor
final class AnonymousStatsReporter {
    static let shared = AnonymousStatsReporter()
    nonisolated static let endpoint = URL(string: "https://dragos.games/api/book_sync/v1/stats")!
    static let sendInterval: TimeInterval = 20 * 60 * 60
    static let retryInterval: TimeInterval = 60 * 60
    enum Outcome: Equatable { case sent, rejected, failed, notDue, disabled, automatedRun }
    private(set) var enabled: Bool
    private let defaults: UserDefaults
    private let directory: URL
    private let now: () -> Date
    private let automated: () -> Bool
    private let collect: @MainActor (String) -> AnonymousStatsPayload
    private let post: (Data) async throws -> Int
    private var pending: Task<Void, Never>?
    private var sending = false
    private static let enabledKey = "anonymousStats.enabled"

    init(defaults: UserDefaults = .standard, directory: URL? = nil,
         now: @escaping () -> Date = Date.init,
         automated: @escaping () -> Bool = { HoshiAutomation.preventReports },
         collect: @escaping @MainActor (String) -> AnonymousStatsPayload = AnonymousStatsReporter.collect,
         post: @escaping (Data) async throws -> Int = { try await AnonymousStatsTransport.post($0) }) {
        self.defaults = defaults
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AnonymousStats", isDirectory: true)
        self.now = now
        self.automated = automated
        self.collect = collect
        self.post = post
        self.enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// One delayed attempt per foreground transition; a pending attempt is shared by all scenes.
    func onForeground() {
        guard !automated(), pending == nil else { return }
        pending = Task { [weak self] in
            defer { self?.pending = nil }
            do { try await Task.sleep(for: .seconds(Double.random(in: 60...300))) }
            catch { return }
            _ = await self?.reportIfDue()
        }
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if !enabled {
            pending?.cancel()
            // A cancelled task's defer clears its own pending slot. Cancellation propagates
            // through URLSession.data, so opting out also cancels a request already in flight.
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func reportIfDue() async -> Outcome {
        guard !automated() else { return .automatedRun }
        guard enabled else { try? FileManager.default.removeItem(at: directory); return .disabled }
        guard !sending else { return .notDue }
        let at = now()
        do {
            guard var state = readState() else {
                try writeState(.init(notBefore: at.addingTimeInterval(Self.sendInterval)))
                return .notDue
            }
            // Backward clock changes never hold an installation until the old date catches up.
            if let date = state.notBefore, (0...Self.sendInterval).contains(date.timeIntervalSince(at)), date > at { return .notDue }
            if let date = state.lastSentAt, (0..<Self.sendInterval).contains(at.timeIntervalSince(date)) { return .notDue }
            if let date = state.lastAttemptAt, (0..<Self.retryInterval).contains(at.timeIntervalSince(date)) { return .notDue }
            let id = state.installId ?? UUID().uuidString.lowercased()
            state.installId = id
            try writeState(state)
            let body = try JSONEncoder().encode(collect(id))
            guard enabled else { return .disabled }
            sending = true
            defer { sending = false }
            let status: Int?
            do { status = try await post(body) }
            catch is CancellationError { return enabled ? .failed : .disabled }
            catch { status = nil }
            guard enabled, readState()?.installId == id else { return .disabled }
            let handled = status.map { (200...499).contains($0) && $0 != 408 && $0 != 429 } ?? false
            if handled { state.notBefore = nil; state.lastSentAt = now(); state.lastAttemptAt = nil }
            else { state.lastAttemptAt = now() }
            try writeState(state)
            if let status, (200...299).contains(status) { return .sent }
            return handled ? .rejected : .failed
        } catch { return .failed }
    }

    func readState() -> AnonymousStatsState? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("state.json")),
              var state = try? JSONDecoder().decode(AnonymousStatsState.self, from: data) else { return nil }
        if let id = state.installId {
            let characters = Array(id)
            if UUID(uuidString: id) == nil || id != id.lowercased() || characters.count != 36 || characters[14] != "4" || !"89ab".contains(characters[19]) {
                state.installId = nil
            }
        }
        return state
    }

    private func writeState(_ state: AnonymousStatsState) throws {
        var directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try directory.setResourceValues(resources)
        try JSONEncoder().encode(state).write(to: directory.appendingPathComponent("state.json"), options: .atomic)
    }

    private static func collect(_ id: String) -> AnonymousStatsPayload {
        var payload = AnonymousStatsPayload(installId: id)
        payload.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        payload.versionCode = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(Int.init)
        payload.buildType = "release"
        payload.osVersion = UIDevice.current.systemVersion
        payload.manufacturer = "Apple"
        // Hardware family, never UIDevice.name or identifierForVendor.
        var system = utsname()
        if uname(&system) == 0 {
            payload.model = withUnsafePointer(to: &system.machine) {
                $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
            }
        }
        payload.emulator = false
        if let screen = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first?.screen {
            let size = screen.nativeBounds.size
            payload.screenWidthPx = Int(min(size.width, size.height))
            payload.screenHeightPx = Int(max(size.width, size.height))
        }
        payload.locale = Locale.current.language.languageCode?.identifier
        payload.appLanguage = (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String])?.first ?? "system"
        if let books = try? BookStorage.loadAllBooks() {
            payload.epubCount = books.filter { $0.resolvedContentType == .epub }.count
            payload.mangaCount = books.filter { $0.resolvedContentType == .mokuro }.count
        }
        let dictionary = DictionaryManager.shared
        payload.dictionaryCount = dictionary.termDictionaries.count + dictionary.frequencyDictionaries.count + dictionary.pitchDictionaries.count
        payload.cloudOnlyCount = HttpSyncCloudBooks.shared.records.count
        payload.httpSyncEnabled = HttpSyncSettingsStore.shared.isConfigured
        let defaults = UserDefaults.standard
        payload.driveSyncEnabled = defaults.bool(forKey: "enableSync")
        payload.readerContinuous = defaults.object(forKey: "continuousMode") as? Bool ?? false
        payload.readerVertical = defaults.object(forKey: "verticalWriting") as? Bool ?? true
        return payload
    }
}

/// An isolated, credential-free JSON POST. Redirects cannot forward a report elsewhere.
private final class AnonymousStatsTransport: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static func post(_ body: Data) async throws -> Int {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        let delegate = AnonymousStatsTransport()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: AnonymousStatsReporter.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                               willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                               completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
