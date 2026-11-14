//
//  HoshiReader.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import UIKit
import WebKit

@main
struct HoshiReaderApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    // Capture first-use evidence before migration and dictionary startup create their folders.
    @State private var firstLaunchSetup = FirstLaunchSetup()
    @State private var userConfig = UserConfig()
    @State private var pendingImportURL: URL?
    @State private var pendingRemoteImportURL: URL?
    @State private var pendingLookup: String?
    @State private var pendingTab: Int?

    @State private var pendingNewsURL: String?
    private var shortcutHandler = ShortcutHandler.shared
    
    init() {
        DiagnosticsCollector.shared.start()
        HttpSyncBackgroundDownloads.shared.restore()
        TokenStorage.clearOldKeys()
        BookStorage.migrateFromDocuments()
        if let books = try? BookStorage.getBooksDirectory() {
            HttpSyncPayloadCodec().recoverInterruptedReplacements(booksDirectory: books)
            // A manga import the app was closed during leaves its whole staged volume behind.
            BookStorage.removeInterruptedStaging(in: books, prefix: MokuroImporter.stagingPrefix)
        }
        WebViewPreloader.shared.warmup()
        _ = DictionaryManager.shared
        configureTabBarAppearance()
        #if DEBUG
        let fixtures = HoshiAutomation.fixtureEnvironment
        if fixtures["HOSHI_UI_TESTING_ZOOM"] == "1" {
            HttpSyncSettingsStore.shared.token = ""
            do { try ZoomUITestFixture.seed(lookup: fixtures["HOSHI_UI_TESTING_MANGA_LOOKUP"] == "1") }
            catch { assertionFailure("Could not prepare the zoom fixture: \(error)") }
        }
        if fixtures["HOSHI_UI_TESTING_STATISTICS"] == "1" {
            HttpSyncSettingsStore.shared.token = ""
            UserDefaults.standard.set(3, forKey: ReadingDay.resetKey)
            UserDefaults.standard.set(10, forKey: ReadingDay.goalKey)
        }
        // Other UI scenarios run without sync, whatever an earlier scenario configured.
        if fixtures["HOSHI_UI_TESTING_PODCAST"] == "1" { HttpSyncSettingsStore.shared.token = "" }
        // CloudMangaDownloadUITests: the gate's local sync server, as a pasted shared token would.
        if let url = fixtures["HOSHI_UI_TESTING_SYNC_URL"], let token = fixtures["HOSHI_UI_TESTING_SYNC_TOKEN"] {
            HttpSyncSettingsStore.shared.baseURL = url
            HttpSyncSettingsStore.shared.token = token
        }
        OfflineLlmLaunchSelfTest.startIfRequested()
        #endif
    }
    
    private func configureTabBarAppearance() {
        let tab = UITabBarAppearance()
        tab.configureWithDefaultBackground()
        tab.stackedLayoutAppearance.selected.iconColor = .label
        tab.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: UIColor.label]
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }
    
    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if HoshiAutomation.fixtureEnvironment["HOSHI_UI_TESTING_PODCAST"] == "1" {
                    PodcastTranscriptUITestFixture()
                } else if HoshiAutomation.fixtureEnvironment["HOSHI_UI_TESTING_STATISTICS"] == "1" {
                    StatisticsUITestFixture()
                } else { bookshelf }
                #else
                bookshelf
                #endif
            }
            .environment(userConfig)
            .preferredColorScheme(userConfig.theme == .custom ? userConfig.uiTheme.colorScheme : (userConfig.theme == .sepia && userConfig.sepiaInvertInDark ? nil : userConfig.theme.colorScheme))
            .onChange(of: scenePhase, initial: true) { _, phase in
                switch phase {
                case .active:
                    // Device diagnostics must not ask the user to keep unlocking during capture.
                    // This process-only flag is absent from normal launches; quitting restores
                    // UIKit's default idle timer without changing a system preference.
                    if MangaStartupTrace.isEnabled { ScreenAwake.set(.diagnostics, true) }
                    LocalFileServer.shared.endBackgroundTask()
                    LocalFileServer.shared.setAudioServer(enabled: userConfig.enableLocalAudio)
                    HttpSyncManager.shared.resumePolling()
                    Task { await HttpStatisticsLane.shared.refresh() }
                    AnonymousStatsReporter.shared.onForeground()
                case .background:
                    HttpSyncManager.shared.suspendPolling()
                    Task {
                        async let bookmarks: Void = HttpSyncManager.shared.flushBookmarkSync()
                        await HttpStatisticsLane.shared.refresh()
                        await bookmarks
                    }
                    LocalFileServer.shared.startBackgroundTask()
                default:
                    break
                }
            }
            .onChange(of: userConfig.enableLocalAudio) { _, _ in
                LocalFileServer.shared.setAudioServer(enabled: userConfig.enableLocalAudio)
            }
            .onOpenURL { url in
                handleURL(url)
            }
            .onChange(of: shortcutHandler.pendingType, initial: true) { _, type in
                switch type {
                case "com.dragosristache.hoshi.books":
                    pendingTab = 0
                case "com.dragosristache.hoshi.dictionary":
                    pendingLookup = ""
                default:
                    break
                }
                shortcutHandler.pendingType = nil
            }
        }
    }
    
    private var bookshelf: some View {
        BookshelfView(
                pendingImportURL: $pendingImportURL,
                pendingRemoteImportURL: $pendingRemoteImportURL,
                pendingLookup: $pendingLookup,
                pendingTab: $pendingTab,
                pendingNewsURL: $pendingNewsURL
            )
            .sheet(isPresented: Binding(
                get: { firstLaunchSetup.step != .hidden && !HoshiAutomation.isTesting },
                set: { _ in }
            )) { FirstLaunchSetupView(setup: firstLaunchSetup) }
    }

    private func handleURL(_ url: URL) {
        if url.scheme == "hoshi" {
            if url.host == "ankiFetch" {
                AnkiManager.shared.fetch()
            } else if url.host == "ankiSuccess" {
                LocalFileServer.shared.clearMedia()
                if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let expression = components.queryItems?.first(where: { $0.name == "expression" })?.value {
                    AnkiManager.shared.addWord(expression)
                }
            } else if url.host == "search" {
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                pendingLookup = components?.queryItems?.first(where: { $0.name == "text" })?.value ?? ""
            } else if url.host == "podcasts" {
                if PodcastStore.shared.enabled { pendingTab = 4 }
            } else if url.host == "news" {
                pendingTab = 3
            } else if url.host == "save-article", let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                      let article = components.queryItems?.first(where: { $0.name == "url" })?.value,
                      let articleURL = NewsSharedUrl.extract(article) {
                pendingNewsURL = articleURL
            } else if url.host == "open", let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                      let urlString = components.queryItems?.first(where: { $0.name == "url" })?.value,
                      let remoteURL = URL(string: urlString) {
                pendingRemoteImportURL = remoteURL
            }
        } else if url.isFileURL {
            pendingImportURL = url
        }
    }
}

@Observable
class ShortcutHandler {
    static let shared = ShortcutHandler()
    var pendingType: String?
    func handle(_ shortcutItem: UIApplicationShortcutItem) {
        pendingType = shortcutItem.type
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = ShortcutSceneDelegate.self
        return config
    }

    /// The system relaunched us (or woke a suspended app) to deliver events for a background
    /// `URLSession` — namely the on-device model download (see `ModelDownloadManager`). Hand the
    /// completion handler to the manager, which recreates the session under the same identifier so
    /// the delegate receives the queued events, then calls this handler once they've all been
    /// delivered (`urlSessionDidFinishEvents`). Called on the main thread by UIKit.
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        // `UIApplicationDelegate` is `@MainActor`, so this runs on the main actor — the manager's
        // (main-actor) handler store is reachable directly.
        if identifier == PodcastDownloads.identifier {
            PodcastDownloads.shared.backgroundCompletion = completionHandler
            PodcastDownloads.shared.restore()
            return
        }
        if identifier == HttpSyncBackgroundDownloads.identifier {
            HttpSyncBackgroundDownloads.shared.backgroundCompletion = completionHandler
            HttpSyncBackgroundDownloads.shared.restore()
            return
        }
        ModelDownloadManager.shared.setBackgroundCompletionHandler(
            completionHandler, forIdentifier: identifier
        )
    }
}

class ShortcutSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let shortcutItem = connectionOptions.shortcutItem {
            ShortcutHandler.shared.handle(shortcutItem)
        }
    }
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        ShortcutHandler.shared.handle(shortcutItem)
        completionHandler(true)
    }
}

class WebViewPreloader {
    static let shared = WebViewPreloader()
    func warmup() {
        DispatchQueue.main.async { MangaWebViewPreloader.shared.warmup() }
    }

    func close() {
        DispatchQueue.main.async { MangaWebViewPreloader.shared.discardIdle() }
    }
}

#if DEBUG
private enum OfflineLlmLaunchSelfTest {
    @MainActor
    static func startIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HOSHI_LLM_SELFTEST"] == "1" else { return }
        let text = environment["HOSHI_LLM_SELFTEST_TEXT"] ?? "これは何？"
        let secondText = environment["HOSHI_LLM_SELFTEST_TEXT_2"] ?? "待って、これは何？"

        Task { @MainActor in
            let started = Date()
            try? FileManager.default.removeItem(at: logFileURL)
            log("HOSHI_LLM_SELFTEST starting")
            do {
                let downloadedIds = ModelDownloadManager.shared.downloadedModelIds()
                log("HOSHI_LLM_SELFTEST downloaded=\(downloadedIds.joined(separator: ","))")
                guard let modelId = downloadedIds.first(where: { $0.contains("qwen3.5-2b") })
                    ?? downloadedIds.first else {
                    log("HOSHI_LLM_SELFTEST failed no-downloaded-model")
                    return
                }
                log("HOSHI_LLM_SELFTEST selected model=\(modelId)")
                OfflineTranslationSettingsStore.shared.selectedModelId = modelId
                let privateThinkingEnabled = environment["HOSHI_LLM_SELFTEST_PRIVATE_THINKING"] != "0"
                OfflineTranslationSettingsStore.shared.usePrivateThinking = privateThinkingEnabled
                log("HOSHI_LLM_SELFTEST privateThinking=\(privateThinkingEnabled)")
                var summaries: [String] = []
                for (index, sample) in [text, secondText].enumerated() {
                    let runNumber = index + 1
                    log("HOSHI_LLM_SELFTEST run=\(runNumber) begin text=\(sample)")
                    let progressTask = Task { @MainActor in
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 5_000_000_000)
                            let status = String(describing: OfflineLlmManager.shared.status)
                            if let progress = OfflineLlmManager.shared.generationProgress {
                                let preview = String(progress.partialText.prefix(160))
                                    .replacingOccurrences(of: "\n", with: "\\n")
                                log(
                                    "HOSHI_LLM_SELFTEST run=\(runNumber) progress "
                                    + "status=\(status) answerTokens=\(progress.tokens) "
                                    + "thinkingTokens=\(progress.thinkingTokens) "
                                    + String(format: "tps=%.2f", progress.tokensPerSecond)
                                    + " text=\(preview)"
                                )
                            } else {
                                log("HOSHI_LLM_SELFTEST run=\(runNumber) progress status=\(status) tokens=nil")
                            }
                        }
                    }
                    let result: OfflineLlmManager.Result
                    do {
                        result = try await OfflineLlmManager.shared.translate(
                            instruction: AiChatDefaults.prompt,
                            japaneseText: sample
                        )
                    } catch {
                        progressTask.cancel()
                        throw error
                    }
                    progressTask.cancel()
                    let lowercased = result.text.lowercased()
                    let leakedThinking = [
                        "<think",
                        "</think",
                        "<thinking",
                        "</thinking",
                        "analysis:",
                        "reasoning:",
                        "thinking process",
                        "chain of thought",
                        "chain-of-thought",
                        "draft translation",
                        "draft breakdown",
                        "draft answer",
                        "let's check",
                        "let me check",
                        "looking at the comma",
                        "checking the"
                    ]
                        .contains { lowercased.contains($0) }
                    let elapsed = Date().timeIntervalSince(started)
                    let preview = String(result.text.prefix(360))
                        .replacingOccurrences(of: "\n", with: "\\n")
                    log(
                        "HOSHI_LLM_SELFTEST run=\(runNumber) complete "
                        + "model=\(result.modelId) answerTokens=\(result.approxTokens) "
                        + "thinkingTokens=\(result.thinkingTokens) "
                        + String(format: "elapsed=%.2f", elapsed)
                        + " text=\(preview)"
                    )
                    if leakedThinking {
                        log(
                            "HOSHI_LLM_SELFTEST failed leaked-thinking run=\(runNumber) "
                            + "model=\(result.modelId) answerTokens=\(result.approxTokens) "
                            + "thinkingTokens=\(result.thinkingTokens) "
                            + String(format: "elapsed=%.2f", elapsed)
                            + " text=\(preview)"
                        )
                        return
                    }
                    if firstAnswerLineLooksNonEnglish(result.text) {
                        log(
                            "HOSHI_LLM_SELFTEST failed non-english-translation run=\(runNumber) "
                            + "model=\(result.modelId) answerTokens=\(result.approxTokens) "
                            + "thinkingTokens=\(result.thinkingTokens) "
                            + String(format: "elapsed=%.2f", elapsed)
                            + " text=\(preview)"
                        )
                        return
                    }
                    if privateThinkingEnabled && result.thinkingTokens <= 0 {
                        log(
                            "HOSHI_LLM_SELFTEST failed missing-hidden-thinking run=\(runNumber) "
                            + "model=\(result.modelId) answerTokens=\(result.approxTokens) "
                            + "thinkingTokens=\(result.thinkingTokens) "
                            + String(format: "elapsed=%.2f", elapsed)
                            + " text=\(preview)"
                        )
                        return
                    }
                    if result.thinkingTokens > OfflineLlmManager.debugThinkingTokenBudget {
                        log(
                            "HOSHI_LLM_SELFTEST failed thinking-budget-exceeded run=\(runNumber) "
                            + "model=\(result.modelId) answerTokens=\(result.approxTokens) "
                            + "thinkingTokens=\(result.thinkingTokens) "
                            + "budget=\(OfflineLlmManager.debugThinkingTokenBudget) "
                            + String(format: "elapsed=%.2f", elapsed)
                            + " text=\(preview)"
                        )
                        return
                    }
                    summaries.append(
                        "run\(runNumber){model=\(result.modelId),answerTokens=\(result.approxTokens),"
                        + "thinkingTokens=\(result.thinkingTokens),text=\(preview)}"
                    )
                }
                let elapsed = Date().timeIntervalSince(started)
                log(
                    "HOSHI_LLM_SELFTEST success runs=\(summaries.count) "
                    + String(format: "elapsed=%.2f leakedThinking=false", elapsed)
                    + " " + summaries.joined(separator: " ")
                )
            } catch {
                log("HOSHI_LLM_SELFTEST failed \(error.localizedDescription)")
            }
        }
    }

    private static func firstAnswerLineLooksNonEnglish(_ text: String) -> Bool {
        guard let firstLine = text.split(separator: "\n")
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) else {
            return false
        }
        let scalars = firstLine.unicodeScalars
        let hasCJK = scalars.contains { scalar in
            (0x3040...0x30FF).contains(Int(scalar.value)) ||
            (0x3400...0x9FFF).contains(Int(scalar.value)) ||
            (0xF900...0xFAFF).contains(Int(scalar.value))
        }
        return hasCJK
    }

    private static func log(_ message: String) {
        let line = message + "\n"
        guard let data = line.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
        if FileManager.default.fileExists(atPath: logFileURL.path) {
            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        } else {
            try? data.write(to: logFileURL, options: .atomic)
        }
    }

    private static var logFileURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("HoshiLlmSelfTest.log")
    }
}
#endif

#if DEBUG
/// Generated only inside an explicitly requested UI-test process. Each launch resets this one
/// synthetic book, so zoom scenarios do not depend on a developer's library or a seeded simulator.
@MainActor private enum ZoomUITestFixture {
    static func seed(lookup: Bool) throws {
        let title = "IDB Zoom Fixture"
        let root = try BookStorage.getBooksDirectory().appendingPathComponent(title, isDirectory: true)
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("images"), withIntermediateDirectories: true)
        // The chrome fixture fills the mini's portrait viewport with white artwork, making
        // the History/options backgrounds visible in the interaction screenshots.
        let textPreview = ProcessInfo.processInfo.environment["HOSHI_UI_TESTING_TEXT_SIZE"] == "1"
        let width = textPreview ? 400 : 1179
        let height = textPreview ? 600 : (ProcessInfo.processInfo.environment["HOSHI_UI_TESTING_CHROME"] == "1" ? 1796 : 2556)
        let blocks: [[String: Any]] = lookup ? [
            ["box": [225, 1480, 920, 1650], "vertical": false, "font_size": 95, "lines": ["猫"]]
        ] : textPreview ? [
            ["box": [85, 65, 285, 105], "vertical": false, "font_size": 12, "lines": ["学校で本を読む"]],
            ["box": [85, 180, 285, 225], "vertical": false, "font_size": 20, "lines": ["こんにちは"]],
            ["box": [85, 400, 295, 465], "vertical": false, "font_size": 40, "lines": ["大きな文字"]]
        ] : [
            ["box": [200, 900, 760, 1050], "vertical": false, "font_size": 72,
             "lines": ["日本語のテキスト"], "lines_coords": [[[200, 900], [760, 900], [760, 1050], [200, 1050]]]],
            ["box": [200, 1700, 700, 1850], "vertical": false, "font_size": 72,
             "lines": ["二回目のテスト"], "lines_coords": [[[200, 1700], [700, 1700], [700, 1850], [200, 1850]]]]
        ]
        var pages: [[String: Any]] = []
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: CGFloat(width), height: CGFloat(height)), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            if textPreview {
                UIColor.darkGray.setStroke()
                for rect in [CGRect(x: 8, y: 8, width: 384, height: 284), CGRect(x: 8, y: 306, width: 384, height: 286)] {
                    let path = UIBezierPath(rect: rect); path.lineWidth = 2; path.stroke()
                }
                for rect in [CGRect(x: 45, y: 40, width: 285, height: 235), CGRect(x: 45, y: 350, width: 305, height: 190)] {
                    let path = UIBezierPath(ovalIn: rect); path.lineWidth = 2; path.stroke()
                }
            } else {
                UIColor.lightGray.setFill()
                context.fill(CGRect(x: 200, y: 900, width: 560, height: 150))
                context.fill(CGRect(x: 200, y: 1700, width: 500, height: 150))
            }
        }
        guard let data = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
        for index in 0..<3 {
            let path = "images/page\(index).png"
            try data.write(to: root.appendingPathComponent(path))
            pages.append(["img_width": width, "img_height": height, "img_path": path, "blocks": textPreview || index == 0 ? blocks : []])
        }
        try JSONSerialization.data(withJSONObject: ["title": title, "pages": pages])
            .write(to: root.appendingPathComponent(FileNames.mokuro))
        let metadata = BookMetadata(title: title, cover: nil, folder: title, lastAccess: Date(),
                                    contentType: .mokuro, syncId: "ui_zoom_fixture_\(UUID().uuidString)")
        try BookStorage.save(metadata, inside: root, as: FileNames.metadata)
        try BookStorage.save(Bookmark(chapterIndex: 0, progress: 0, characterCount: 0), inside: root, as: FileNames.bookmark)
        if lookup { try seedLookupDictionary() }
    }

    private static func seedLookupDictionary() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let archive = work.appendingPathComponent("dictionary.zip")
        // A generated two-file Yomitan archive with the single term 猫 → Fixture cat definition.
        let fixture = Data(base64Encoded: """
            UEsDBBQAAAAIALgSbl2je7jNYwAAAHgAAAAKAAAAaW5kZXguanNvbjWMQQrDMAwEv2J07iX01j/0mAcoWC4iimVsuQ2U/D1WIMednd0/GJsQvAK8MX8wiOraS0i8W68EjwBJ64Y2jOcIlb7cWLMPJm+5zSWi4XKdJJRGTnOkfa7imltRf1kU442OE1BLAwQUAAAACAC4Em5dQnM0ozoAAABBAAAAEAAAAHRlcm1fYmFua18xLmpzb26LjlZ63rNaSUdB6XHj2seNk0EsKDbQUYhWcsusKCktSlVITixRSElNy8zLLMnMz1OK1VEwBKmKjQUAUEsBAhQDFAAAAAgAuBJuXaN7uM1jAAAAeAAAAAoAAAAAAAAAAAAAAIABAAAAAGluZGV4Lmpzb25QSwECFAMUAAAACAC4Em5dQnM0ozoAAABBAAAAEAAAAAAAAAAAAAAAgAGLAAAAdGVybV9iYW5rXzEuanNvblBLBQYAAAAAAgACAHYAAADzAAAAAAA=
            """)!
        try fixture.write(to: archive)
        let dictionaries = try BookStorage.getAppDirectory().appendingPathComponent("Dictionaries/Term", isDirectory: true)
        _ = try DictionaryDownloads.importArchive(at: archive, to: dictionaries)
        DictionaryManager.shared.loadDictionaries()
        DictionaryManager.shared.rebuildLookupQuery()
    }
}
#endif
