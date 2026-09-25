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
    @State private var userConfig = UserConfig()
    @State private var pendingImportURL: URL?
    @State private var pendingRemoteImportURL: URL?
    @State private var pendingLookup: String?
    @State private var pendingTab: Int?

    @State private var pendingNewsURL: String?
    private var shortcutHandler = ShortcutHandler.shared
    
    init() {
        TokenStorage.clearOldKeys()
        BookStorage.migrateFromDocuments()
        if let books = try? BookStorage.getBooksDirectory() {
            HttpSyncPayloadCodec().recoverInterruptedReplacements(booksDirectory: books)
        }
        WebViewPreloader.shared.warmup()
        _ = DictionaryManager.shared
        configureTabBarAppearance()
        #if DEBUG
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
            BookshelfView(
                pendingImportURL: $pendingImportURL,
                pendingRemoteImportURL: $pendingRemoteImportURL,
                pendingLookup: $pendingLookup,
                pendingTab: $pendingTab,
                pendingNewsURL: $pendingNewsURL
            )
            .environment(userConfig)
            .preferredColorScheme(userConfig.theme == .custom ? userConfig.uiTheme.colorScheme : (userConfig.theme == .sepia && userConfig.sepiaInvertInDark ? nil : userConfig.theme.colorScheme))
            .onChange(of: scenePhase, initial: true) { _, phase in
                switch phase {
                case .active:
                    LocalFileServer.shared.endBackgroundTask()
                    LocalFileServer.shared.setAudioServer(enabled: userConfig.enableLocalAudio)
                    HttpSyncManager.shared.syncInBackground()
                case .background:
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
    private var dummy: WKWebView?
    func warmup() {
        DispatchQueue.main.async {
            self.dummy = WKWebView(frame: .zero)
            self.dummy?.loadHTMLString("", baseURL: nil)
        }
    }
    
    func close() {
        guard dummy != nil else {
            return
        }
        DispatchQueue.main.async {
            self.dummy = nil
        }
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
