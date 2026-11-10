import SwiftUI

nonisolated struct MangaTextPreviewSource: Sendable {
    let book: MokuroBook
    let root: URL
    let pageIndex: Int
}

/// A separate, read-only reader: page selection never writes bookmarks or reading statistics.
struct MangaTextPreviewLauncher: View {
    @Environment(UserConfig.self) private var config
    @Environment(\.dismiss) private var dismiss
    @State private var source: MangaTextPreviewSource?
    @State private var books: [BookMetadata] = []
    @State private var loading = false
    @State private var error: String?

    init(source: MangaTextPreviewSource? = nil) { _source = State(initialValue: source) }

    var body: some View {
        NavigationStack {
            if let source {
                MangaTextSizePreview(source: source, initial: config.mangaTextEnlargement,
                    useSans: config.mangaUseNotoSansJpFont, furigana: config.mangaShowFurigana) { value in
                        config.mangaTextEnlargement = value
                        dismiss()
                    }
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            } else {
                List {
                    if loading { ProgressView() }
                    if let error { Text(error).foregroundStyle(.secondary) }
                    if !loading && books.isEmpty && error == nil {
                        Text("Download or import a manga to preview its text size here.")
                    }
                    ForEach(books) { metadata in
                        Button(metadata.title ?? metadata.folder ?? "Manga") { load(metadata) }
                            .disabled(loading)
                    }
                }
                .navigationTitle("Choose manga")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
                .task {
                    do {
                        let directory = try BookStorage.getBooksDirectory()
                        books = try await Task.detached {
                            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                                .compactMap { root -> BookMetadata? in
                                    guard FileManager.default.fileExists(atPath: root.appendingPathComponent(FileNames.mokuro).path),
                                          let data = try? Data(contentsOf: root.appendingPathComponent(FileNames.metadata)) else { return nil }
                                    return try? JSONDecoder().decode(BookMetadata.self, from: data)
                                }.sorted { $0.lastAccess > $1.lastAccess }
                        }.value
                    } catch { self.error = error.localizedDescription }
                }
            }
        }
    }

    private func load(_ metadata: BookMetadata) {
        loading = true; error = nil
        Task {
            do {
                guard let folder = metadata.folder, !folder.isEmpty else { throw CocoaError(.fileNoSuchFile) }
                let directory = try BookStorage.getBooksDirectory().standardizedFileURL.resolvingSymlinksInPath()
                let root = directory.appendingPathComponent(folder).standardizedFileURL.resolvingSymlinksInPath()
                guard root.path.hasPrefix(directory.path + "/") else { throw CocoaError(.fileReadNoPermission) }
                let result = try await Task.detached {
                    let book = try MokuroBookParser.shared.parse(bookRoot: root)
                    let bookmark = (try? Data(contentsOf: root.appendingPathComponent(FileNames.bookmark)))
                        .flatMap { try? JSONDecoder().decode(Bookmark.self, from: $0) }
                    return MangaTextPreviewSource(book: book, root: root, pageIndex: bookmark?.chapterIndex ?? 0)
                }.value
                source = result
            } catch { self.error = error.localizedDescription }
            loading = false
        }
    }
}

struct MangaTextSizePreview: View {
    let source: MangaTextPreviewSource
    let useSans: Bool
    let furigana: Bool
    let onApply: (MangaTextEnlargement) -> Void
    @State private var draft: MangaTextEnlargement
    @State private var pageIndex: Int
    @State private var original = false
    @State private var rendering = true
    @State private var expectedToken: Int?
    @State private var controller = MangaWebViewController()
    private let cache = MangaPageRenderCache()

    init(source: MangaTextPreviewSource, initial: MangaTextEnlargement, useSans: Bool, furigana: Bool,
         onApply: @escaping (MangaTextEnlargement) -> Void) {
        self.source = source; self.useSans = useSans; self.furigana = furigana; self.onApply = onApply
        _draft = State(initialValue: initial)
        _pageIndex = State(initialValue: min(max(0, source.pageIndex), max(0, source.book.pages.count - 1)))
    }

    var body: some View {
        VStack(spacing: 8) {
            Picker("Comparison", selection: $original) {
                Text("Original").tag(true)
                Text("Adjusted").tag(false)
            }.pickerStyle(.segmented).padding(.horizontal)
            GeometryReader { geometry in
                MangaReaderWebView(controller: controller, backgroundColor: .black,
                    onNavigate: { _ in }, onTextSelected: { _ in nil }, onTapOutside: {},
                    onAskAi: { _, _ in }, onCopy: { _ in }, onPageReady: { token in
                        if token == expectedToken { rendering = false }
                    }, pageTurnEnabled: false)
                    .task(id: RenderRequest(page: pageIndex, config: renderConfig(size: geometry.size))) {
                        rendering = true; expectedToken = nil
                        let config = renderConfig(size: geometry.size)
                        let page = source.book.pages[pageIndex]
                        try? await Task.sleep(for: .milliseconds(100))
                        guard !Task.isCancelled else { return }
                        let html = await cache.htmlFor(page: page, config: config)
                        guard !Task.isCancelled else { return }
                        controller.bookRootForScheme = source.root
                        expectedToken = controller.load(html: html, allowedImagePaths: [page.imagePath])
                    }
                    .overlay {
                        if rendering { ProgressView().tint(.white).accessibilityIdentifier("manga-preview-loading") }
                    }
            }
            .background(.black)
            if source.book.pages[pageIndex].textBoxes.isEmpty {
                Text("No recognized text on this page. Choose another page.").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 8) {
                    HStack {
                        Button { pageIndex -= 1 } label: { Image(systemName: "chevron.left") }
                            .disabled(pageIndex == 0).accessibilityLabel("Previous page")
                        Spacer()
                        Text("Page \(pageIndex + 1) of \(source.book.pages.count)")
                            .accessibilityIdentifier("manga-preview-page")
                        Spacer()
                        Button { pageIndex += 1 } label: { Image(systemName: "chevron.right") }
                            .disabled(pageIndex == source.book.pages.count - 1).accessibilityLabel("Next page")
                    }
                    if source.book.pages.count > 1 {
                        Slider(value: Binding(get: { Double(pageIndex) }, set: { pageIndex = Int($0) }),
                            in: 0...Double(source.book.pages.count - 1), step: 1).accessibilityLabel("Preview page")
                    }
                    Toggle("Enlarge Small Text", isOn: $draft.enabled)
                    HStack {
                        preset("Subtle", 25, 24); preset("Balanced", 50, 30); preset("Strong", 75, 40)
                    }.buttonStyle(.bordered)
                    LabeledContent("Enlargement amount", value: "\(draft.amount)%")
                    Slider(value: Binding(get: { Double(draft.amount) }, set: { draft.amount = Int($0) }), in: 0...100, step: 5)
                        .disabled(!draft.enabled).accessibilityLabel("Enlargement amount")
                    LabeledContent("Small-text cutoff", value: "\(draft.threshold) px")
                    Slider(value: Binding(get: { Double(draft.threshold) }, set: { draft.threshold = Int($0) }), in: 10...60, step: 1)
                        .disabled(!draft.enabled).accessibilityLabel("Small-text cutoff")
                    Text("All recognized text is revealed. Pinch to zoom. Smaller text can match, but never overtake, larger text. Your reading position stays unchanged.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal).padding(.bottom, 8)
            }.frame(height: 235)
        }
        .onChange(of: draft) { _, _ in original = false }
        .navigationTitle("Preview text size").navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("manga-page-text-preview")
        .toolbar { ToolbarItem(placement: .confirmationAction) {
            Button("Apply") { onApply(draft) }.accessibilityIdentifier("manga-preview-apply")
        } }
    }

    private func preset(_ title: LocalizedStringKey, _ amount: Int, _ threshold: Int) -> some View {
        Button(title) { draft = .init(amount: amount, threshold: threshold); original = false }
            .frame(maxWidth: .infinity)
    }

    private struct RenderRequest: Hashable {
        let page: Int
        let config: MangaPageRenderConfig
    }

    private func renderConfig(size: CGSize) -> MangaPageRenderConfig {
        MangaPageRenderConfig(backgroundCssColor: "#000", scanNonJapaneseText: false,
            viewportCssWidth: max(1, Int(size.width)), viewportCssHeight: max(1, Int(size.height)),
            singleTapLookup: false, useNotoSansJpFont: useSans, showActionButtons: false, selectionScript: "",
            enlargeSmallText: !original && draft.enabled, textEnlargementAmount: draft.amount,
            smallTextThreshold: draft.threshold, showFurigana: furigana, textSizePreview: true)
    }
}
