//
//  NewsView.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The News tab: articles from the enabled easy-Japanese sources, each with "Want to read" (save
//  as a book on the News shelf) and "Pre-translate" (send its sentences to a model). Saved
//  articles open in the regular reader.
//

import SwiftUI

struct NewsView: View {
    @Environment(UserConfig.self) private var userConfig
    @Binding var pendingSharedURL: String?

    @State private var store = NewsStore.shared
    @State private var settings = NewsSettingsStore.shared
    @State private var jobs = NewsPretranslationManager.shared
    @State private var readerWindow = ReaderWindow()
    @State private var selectedSourceId: String?
    @State private var showSources = false
    @State private var message: String?
    @State private var pretranslate: PretranslateSheetModel?
    @State private var openBook: BookMetadata?

    private var visibleArticles: [NewsArticle] {
        var seen = Set<String>()
        return store.articles.filter { selectedSourceId == nil || $0.sourceId == selectedSourceId }
            .filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        Group {
            if !store.loaded {
                ProgressView()
            } else if visibleArticles.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(visibleArticles) { article in
                        NewsArticleRow(
                            article: article,
                            sourceName: sourceName(article.sourceId),
                            saved: store.saved[article.id],
                            saving: store.saving.contains(article.id),
                            job: store.saved[article.id].flatMap { jobs.jobs[$0.bookId] },
                            onSave: { save(article) },
                            onOpen: { bookId in open(bookId: bookId) },
                            onPretranslate: { pretranslate = PretranslateSheetModel(article: article) },
                            onCancelJob: { jobs.cancel(bookId: $0) },
                            onDismissJob: { jobs.dismiss(bookId: $0) }
                        )
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { sourceChips }
        .navigationTitle("News")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showSources = true } label: { Label("Sources", systemImage: "dot.radiowaves.left.and.right") }
                Button { store.refreshAll(force: true) } label: {
                    if store.refreshing.isEmpty { Label("Refresh", systemImage: "arrow.clockwise") } else { ProgressView() }
                }
                .disabled(!store.refreshing.isEmpty)
            }
        }
        .sheet(isPresented: $showSources) { NewsSourcesSheet(settings: settings, store: store) }
        .sheet(item: $pretranslate) { model in PretranslateSheet(model: model) }
        .overlay(alignment: .bottom) {
            if let message {
                Text(message)
                    .font(.footnote)
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: message) {
                        try? await Task.sleep(for: .seconds(4))
                        withAnimation { self.message = nil }
                    }
            }
        }
        .onAppear {
            store.load()
            store.reconcileSavedBooks()
            store.refreshAll(force: false)
        }
        .onChange(of: pendingSharedURL, initial: true) { _, url in
            guard let url else { return }
            pendingSharedURL = nil
            importShared(url)
        }
        .onChange(of: openBook) { old, new in
            if let book = new {
                readerWindow.present(content: { ReaderLoader(book: book).environment(userConfig) }) {
                    if openBook?.id == book.id { openBook = nil }
                }
            } else if old != nil {
                store.load()
                readerWindow.dismiss()
            }
        }
    }

    private var sourceChips: some View {
        let sources = settings.enabledSources
        return Group {
            if sources.count >= 2 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chip("All", selected: selectedSourceId == nil) { selectedSourceId = nil }
                        ForEach(sources) { source in
                            chip(store.sourceErrors[source.id] == nil ? source.name : "\(source.name) !", selected: selectedSourceId == source.id) {
                                selectedSourceId = source.id
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .background(.bar)
            }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            if !store.refreshing.isEmpty {
                ProgressView()
            } else {
                ContentUnavailableView {
                    Label(settings.enabledSources.isEmpty ? "No Sources" : "No Articles", systemImage: "newspaper")
                } description: {
                    Text(settings.enabledSources.isEmpty ? "All sources are switched off. Enable one under Sources." : "Refresh to load the enabled sources.")
                }
                ForEach(store.sourceErrors.sorted(by: { $0.key < $1.key }), id: \.key) { sourceId, error in
                    Text("\(sourceName(sourceId)): \(error)")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sourceName(_ id: String) -> String {
        settings.sources.first { $0.id == id }?.name ?? (id == NewsSourceCatalog.sharedLinkId ? NewsSourceCatalog.sharedLink.name : id)
    }

    private func save(_ article: NewsArticle) {
        Task {
            do {
                let saved = try await store.saveArticle(article)
                withAnimation { message = "Saved “\(saved.title)” to the News shelf." }
            } catch {
                withAnimation { message = "Could not save the article: \(error.localizedDescription)" }
            }
        }
    }

    private func importShared(_ url: String) {
        Task {
            withAnimation { message = "Saving \(url)…" }
            do {
                let saved = try await store.saveSharedUrl(url)
                withAnimation { message = "Saved “\(saved.title)” to the News shelf." }
                open(bookId: saved.bookId)
            } catch {
                withAnimation { message = "Could not save the article: \(error.localizedDescription)" }
            }
        }
    }

    private func open(bookId: UUID) {
        guard let book = ((try? BookStorage.loadAllBooks()) ?? []).first(where: { $0.id == bookId }) else {
            withAnimation { message = "The article is no longer on the shelf." }
            return
        }
        openBook = book
    }
}

private struct NewsArticleRow: View {
    let article: NewsArticle
    let sourceName: String
    let saved: SavedNewsArticle?
    let saving: Bool
    let job: PretranslationJobState?
    let onSave: () -> Void
    let onOpen: (UUID) -> Void
    let onPretranslate: () -> Void
    let onCancelJob: (UUID) -> Void
    let onDismissJob: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text([sourceName, article.publishedDate.map { $0.formatted(.relative(presentation: .named)) }].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(article.title)
                .font(.headline)
                .lineLimit(3)
            if let summary = article.summary, !summary.isEmpty {
                Text(summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
            }
            HStack(spacing: 8) {
                if saving {
                    Button {} label: { Label("Saving…", systemImage: "hourglass") }.disabled(true)
                } else if let saved {
                    Button { onOpen(saved.bookId) } label: { Label("Open", systemImage: "book") }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(action: onSave) { Label("Want to read", systemImage: "bookmark") }
                }
                Button(action: onPretranslate) { Label("Pre-translate", systemImage: "character.book.closed") }
                    .disabled(saving || job?.isActive == true)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, 4)
            jobStatus
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var jobStatus: some View {
        switch job {
        case .queued:
            statusRow("Waiting to translate…") { if let saved { Button("Cancel") { onCancelJob(saved.bookId) } } }
        case .running(let completed, let total, _, let cancelling):
            ProgressView(value: total > 0 ? Double(completed) / Double(total) : 0)
            statusRow(cancelling ? "\(completed) / \(total) sentences\nStopping after the current request…" : "\(completed) / \(total) sentences") {
                if !cancelling, let saved { Button("Cancel") { onCancelJob(saved.bookId) } }
            }
        case .uploading:
            statusRow("Uploading translations…") {}
        case .finished(let translated, let total, let uploadAttempted, let uploaded, _):
            statusRow("Translated \(translated) of \(total) sentences" + (uploadAttempted && !uploaded ? "\nTranslated, but the upload to sync failed. Run Pre-translate again to retry the upload." : "")) {
                if let saved { Button { onDismissJob(saved.bookId) } label: { Image(systemName: "xmark") } }
            }
        case .failed(let message, let kept):
            statusRow("Translation failed: \(message)" + (kept > 0 ? "\n\(kept) translated sentences were kept." : ""), error: true) {
                if let saved { Button { onDismissJob(saved.bookId) } label: { Image(systemName: "xmark") } }
            }
        case .cancelled(let kept):
            statusRow("Translation cancelled." + (kept > 0 ? " \(kept) translated sentences were kept." : "")) {
                if let saved { Button { onDismissJob(saved.bookId) } label: { Image(systemName: "xmark") } }
            }
        case nil:
            if let record = saved?.translation {
                statusRow(record.translatedCount >= record.sentenceCount
                          ? "Translated with \(record.model)"
                          : "\(record.translatedCount) / \(record.sentenceCount) sentences translated with \(record.model)") {}
            }
        }
    }

    private func statusRow<Trailing: View>(_ text: String, error: Bool = false, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Text(text).font(.footnote).foregroundStyle(error ? Color.red : Color.secondary)
            Spacer()
            trailing().buttonStyle(.borderless).font(.footnote)
        }
    }
}

private struct NewsSourcesSheet: View {
    let settings: NewsSettingsStore
    let store: NewsStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Built-in sources") {
                    ForEach(NewsSourceCatalog.builtIn) { source in
                        Toggle(source.name, isOn: Binding(
                            get: { settings.isEnabled(source) },
                            set: { enabled in
                                settings.setEnabled(enabled, source: source)
                                if enabled { Task { await store.refreshSource(source) } } else { store.refreshAll(force: false) }
                            }
                        ))
                    }
                }
                if !settings.customSources.isEmpty {
                    Section("Your feeds") {
                        ForEach(settings.customSources) { source in
                            Toggle(source.name, isOn: Binding(
                                get: { settings.isEnabled(source) },
                                set: { enabled in
                                    settings.setEnabled(enabled, source: source)
                                    if enabled { Task { await store.refreshSource(source) } } else { store.refreshAll(force: false) }
                                }
                            ))
                        }
                        .onDelete { offsets in
                            for index in offsets { settings.removeCustomSource(settings.customSources[index]) }
                            store.refreshAll(force: false)
                        }
                    }
                }
                Section("Add RSS feed") {
                    TextField("Name", text: $name)
                    TextField("Feed URL", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Add RSS feed") {
                        let source = settings.addCustomRss(name: name, url: url)
                        name = ""; url = ""
                        Task { await store.refreshSource(source) }
                    }
                    .disabled(!url.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("http"))
                }
            }
            .navigationTitle("Sources")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

// MARK: - Pre-translate sheet

@Observable
@MainActor
final class PretranslateSheetModel: Identifiable {
    struct Choice: Identifiable, Hashable {
        let engine: PretranslationEngine
        let label: String
        let detail: String?
        var id: String { engine.label }
    }

    let id = UUID()
    let article: NewsArticle
    private(set) var saved: SavedNewsArticle?
    private(set) var plan: PretranslationPlan?
    private(set) var config: PretranslationConfig
    private(set) var estimate: PretranslationEstimate?
    private(set) var choices: [Choice] = []
    private(set) var apiKeyMissingFor: String?
    private(set) var syncConfigured = true
    private(set) var preparing = true
    private(set) var error: String?

    init(article: NewsArticle) {
        self.article = article
        let engine = Self.defaultEngine()
        config = PretranslationConfig(engine: engine, includeExplanations: !engine.isOnDevice, customInstructions: UserDefaults.standard.string(forKey: "news.pretranslationInstructions") ?? "").withEffectiveBatchSize()
    }

    var canStart: Bool {
        !preparing && error == nil && plan != nil && apiKeyMissingFor == nil && (estimate?.sentenceCount ?? 0) > 0
    }

    func prepare() async {
        // Offer the models first so the picker is populated even when saving or planning fails.
        choices = Self.modelChoices()
        syncConfigured = HttpSyncSettingsStore.shared.isConfigured
        do {
            let saved = try await NewsStore.shared.saveArticle(article)
            self.saved = saved
            guard let book = ((try? BookStorage.loadAllBooks()) ?? []).first(where: { $0.id == saved.bookId }), let folder = book.folder else {
                throw PretranslationFailure("The article is no longer on the shelf.")
            }
            guard let bookSyncId = syncId(for: book) else { throw PretranslationFailure("The article has no sync identity.") }
            let root = try BookStorage.getBooksDirectory().appendingPathComponent(folder, isDirectory: true)
            let config = self.config
            plan = try await Task.detached { try PretranslationPlanner.plan(bookId: book.id, syncId: bookSyncId, bookRoot: root, config: config) }.value
            estimate = plan?.estimate
            apiKeyMissingFor = Self.apiKeyMissing(for: config.engine)
        } catch let failure as PretranslationFailure {
            self.error = failure.message
        } catch {
            self.error = "Could not save the article: \(error.localizedDescription)"
        }
        preparing = false
    }

    func select(engine: PretranslationEngine) {
        update { $0.engine = engine }
    }

    func setInstructions(_ text: String) {
        let bounded = String(text.prefix(12000))
        UserDefaults.standard.set(bounded, forKey: "news.pretranslationInstructions")
        update { $0.customInstructions = bounded }
    }

    func setIncludeExplanations(_ include: Bool) {
        update { $0.includeExplanations = include }
    }

    private func update(_ transform: (inout PretranslationConfig) -> Void) {
        var next = config
        next.sentencesPerRequest = PretranslationConfig.defaultSentencesPerRequest
        transform(&next)
        next = next.withEffectiveBatchSize()
        // On-device models are only ever asked for a translation.
        if next.engine.isOnDevice { next.includeExplanations = false }
        config = next
        estimate = plan.map { PretranslationPlanner.estimate($0.sentences, config: next) }
        apiKeyMissingFor = Self.apiKeyMissing(for: next.engine)
    }

    func start() {
        guard let saved else { return }
        NewsPretranslationManager.shared.enqueue(PretranslationRequest(bookId: saved.bookId, articleId: saved.articleId, title: saved.title, config: config))
    }

    private static func defaultEngine() -> PretranslationEngine {
        let offline = OfflineTranslationSettingsStore.shared
        if offline.useOnDeviceTranslation, ModelDownloadManager.shared.isDownloaded(offline.selectedModel) {
            return .onDevice(modelId: offline.selectedModel.id)
        }
        return .cloud(modelId: AiChatSettingsStore.shared.model)
    }

    private static func modelChoices() -> [Choice] {
        let configured = AiChatSettingsStore.shared.model
        var choices: [Choice] = []
        if !ChatModelCatalog.models.contains(where: { $0.id == configured }) {
            choices.append(Choice(engine: .cloud(modelId: configured), label: configured, detail: "\(ChatModelCatalog.provider(forModelId: configured).displayName) · Model from settings"))
        }
        choices += ChatModelCatalog.models.map { option in
            Choice(engine: .cloud(modelId: option.id), label: option.displayName, detail: [option.provider.displayName, option.note].compactMap { $0 }.joined(separator: " · "))
        }
        // The offline manager always runs the model selected in settings, so only that one is offered.
        let offline = OfflineTranslationSettingsStore.shared.selectedModel
        if ModelDownloadManager.shared.isDownloaded(offline) {
            choices.append(Choice(engine: .onDevice(modelId: offline.id), label: "On device: \(offline.displayName)", detail: nil))
        }
        return choices
    }

    private static func apiKeyMissing(for engine: PretranslationEngine) -> String? {
        guard case .cloud(let modelId) = engine else { return nil }
        let provider = ChatModelCatalog.provider(forModelId: modelId)
        return AiChatSettingsStore.shared.apiKey(for: provider).isEmpty ? provider.displayName : nil
    }
}

private struct PretranslateSheet: View {
    let model: PretranslateSheetModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(model.article.title).font(.headline).lineLimit(2)
                    Text("The article is saved to the News shelf first. Every sentence is then sent to the model below, and the translations are saved with the article and shared through sync so other devices can read them.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let error = model.error { Text(error).foregroundStyle(.red) }
                    if model.preparing { HStack { ProgressView(); Text("Preparing sentences…") } }
                }
                Section("Model") {
                    Picker("Model", selection: Binding(get: { model.config.engine }, set: { model.select(engine: $0) })) {
                        ForEach(model.choices) { choice in
                            VStack(alignment: .leading) {
                                Text(choice.label)
                                if let detail = choice.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                            }
                            .tag(choice.engine)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    if !model.config.engine.isOnDevice {
                        TextField("Your translation instructions (optional)", text: Binding(get: { model.config.customInstructions }, set: { model.setInstructions($0) }), axis: .vertical)
                            .lineLimit(3...8)
                        Text("Leave blank for the default. The reply format is added automatically.").font(.caption).foregroundStyle(.secondary)
                        Toggle("Include vocabulary and grammar notes", isOn: Binding(get: { model.config.includeExplanations }, set: { model.setIncludeExplanations($0) }))
                    }
                }
                if let estimate = model.estimate {
                    Section("Estimate") {
                        Text("\(estimate.sentenceCount) sentences · \(estimate.characterCount) characters")
                        Text("About \(estimate.inputTokens.formatted()) input and \(estimate.outputTokens.formatted()) output tokens")
                            .font(.footnote).foregroundStyle(.secondary)
                        if model.config.engine.isOnDevice {
                            Text("Runs on this device at no cost. This can take a while.")
                        } else if let cost = estimate.costUsd {
                            Text("Estimated cost \(ModelPricing.formatUsd(cost))").font(.title3.weight(.semibold))
                            Text("Estimates use approximate list prices (as of \(ModelPricing.pricesAsOf)) and character-based token counts; the provider’s bill is authoritative.")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Text("No price on file for this model; only the token estimate is shown.").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                if let provider = model.apiKeyMissingFor {
                    Text("Add a \(provider) API key in Settings › AI before starting.").foregroundStyle(.red).font(.footnote)
                }
                if !model.syncConfigured {
                    Text("Sync is not configured, so the translations stay on this device.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Pre-translate article")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Translate") { model.start(); dismiss() }.disabled(!model.canStart)
                }
            }
            .task { await model.prepare() }
        }
    }
}
