import SwiftUI

nonisolated struct MangaTextPreviewSource: Sendable {
    let book: MokuroBook
    let root: URL
    let pageIndex: Int
    var twoPageEnabled = false
    var viewport: MangaViewportState? = nil
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
                    useSans: config.mangaUseNotoSansJpFont, furigana: config.mangaShowFurigana,
                    showActions: config.mangaShowActionButtons, showCopy: config.mangaShowCopyButton) { value in
                        config.mangaTextEnlargement = value
                        dismiss()
                    } onCancel: { dismiss() }
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
                let twoPage = MangaReaderViewModel.savedTwoPagePreference(for: metadata.id)
                let result = try await Task.detached {
                    let book = try MokuroBookParser.shared.parse(bookRoot: root)
                    let bookmark = (try? Data(contentsOf: root.appendingPathComponent(FileNames.bookmark)))
                        .flatMap { try? JSONDecoder().decode(Bookmark.self, from: $0) }
                    return MangaTextPreviewSource(book: book, root: root, pageIndex: bookmark?.chapterIndex ?? 0, twoPageEnabled: twoPage)
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
    let showActions: Bool
    let showCopy: Bool
    let onApply: (MangaTextEnlargement) -> Void
    let onCancel: () -> Void
    @State private var draft: MangaTextEnlargement
    @State private var baseline: MangaTextEnlargement
    @State private var pageIndex: Int
    @State private var original = false
    @State private var controlsVisible = true
    @State private var loadedPage: Int?
    @State private var viewportSize: CGSize = .zero
    @State private var headerHeight: CGFloat = 0
    @State private var controller = MangaWebViewController()
    @State private var cache = MangaPageRenderCache()

    init(source: MangaTextPreviewSource, initial: MangaTextEnlargement, useSans: Bool, furigana: Bool,
         showActions: Bool, showCopy: Bool, onApply: @escaping (MangaTextEnlargement) -> Void,
         onCancel: @escaping () -> Void) {
        self.source = source; self.useSans = useSans; self.furigana = furigana
        self.showActions = showActions; self.showCopy = showCopy
        self.onApply = onApply; self.onCancel = onCancel
        _draft = State(initialValue: initial)
        _baseline = State(initialValue: initial)
        _pageIndex = State(initialValue: min(max(0, source.pageIndex), max(0, source.book.pages.count - 1)))
    }

    private var pageCount: Int { source.book.pages.count }
    private var step: Int { source.twoPageEnabled && viewportSize.width > viewportSize.height && pageCount > 1 ? 2 : 1 }
    private var firstPage: Int { pageIndex / step * step }
    private var endPage: Int { min(firstPage + step, pageCount) }
    private var scrim: Color { .black.opacity(0.62) }

    var body: some View {
        ZStack {
            GeometryReader { geometry in
                MangaReaderWebView(controller: controller, backgroundColor: .black,
                    onNavigate: { _ in }, onTextSelected: { _ in nil }, onTapOutside: {},
                    onAskAi: { _, _ in }, onCopy: { _ in }, onPageReady: { _ in }, pageTurnEnabled: false)
                    .task(id: RenderRequest(page: pageIndex, config: renderConfig(size: geometry.size))) {
                        viewportSize = geometry.size
                        let index = firstPage
                        let config = renderConfig(size: geometry.size)
                        let page = source.book.pages[index]
                        let left = step == 2 && index + 1 < pageCount ? source.book.pages[index + 1] : nil
                        try? await Task.sleep(for: .milliseconds(100))
                        guard !Task.isCancelled else { return }
                        let html = await cache.htmlFor(page: page, leftPage: left, config: config)
                        guard !Task.isCancelled else { return }
                        let initialIndex = source.pageIndex / step * step
                        let viewport = loadedPage == index ? controller.viewportForReload()
                            : (loadedPage == nil && index == initialIndex ? source.viewport : nil)
                        controller.bookRootForScheme = source.root
                        var paths: Set<String> = [page.imagePath.trimmingPrefixSlash()]
                        if let left { paths.insert(left.imagePath.trimmingPrefixSlash()) }
                        loadedPage = index
                        controller.load(html: html, allowedImagePaths: paths, preservingViewport: viewport, textSizePreview: true)
                    }
                    .overlay {
                        if !controller.isCurrentPageReady {
                            ProgressView().tint(.white).accessibilityIdentifier("manga-preview-loading")
                        }
                    }
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .bottom) {
            controls
                .frame(maxHeight: min(340, max(0, viewportSize.height - headerHeight - 48)))
                .padding(12)
                .background(scrim, in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 12).padding(.bottom, 8)
                .opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(controlsVisible)
                .accessibilityHidden(!controlsVisible)
        }
        .overlay(alignment: .top) {
            header.padding(.horizontal, 12).padding(.top, 8)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
        }
        .foregroundStyle(.white)
        .tint(.white)
        .onChange(of: draft) { _, _ in original = false }
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }

    private var header: some View {
        Group {
            if controlsVisible {
                VStack(spacing: 0) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { cancel; comparisonButtons; save; visibility }
                            .fixedSize(horizontal: true, vertical: false)
                        VStack(spacing: 0) {
                            HStack { cancel; Spacer(); save; visibility }
                            comparisonButtons
                        }
                    }
                    if original && draft != baseline {
                        Text("Viewing original size. Save settings keeps your adjustments.")
                            .font(.caption).padding(.bottom, 4)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
                .background(scrim, in: RoundedRectangle(cornerRadius: 16))
            } else {
                HStack { Spacer(); visibility.background(scrim, in: Capsule()) }
            }
        }
        .buttonStyle(.plain)
    }

    private var cancel: some View {
        Button(action: onCancel) {
            Text("Cancel").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
    }
    private var save: some View {
        Button {
            if draft == baseline { onCancel() } else { onApply(draft) }
        } label: {
            Text("Save settings").frame(minHeight: 44).contentShape(Rectangle())
        }.accessibilityIdentifier("manga-preview-apply")
    }
    private var visibility: some View {
        Button { controlsVisible.toggle() } label: {
            Label(controlsVisible ? "Hide controls" : "Show controls",
                  systemImage: controlsVisible ? "eye.slash" : "eye")
                .font(.subheadline)
                .frame(minWidth: 44, minHeight: 44)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
        }
    }
    private var comparisonButtons: some View {
        HStack(spacing: 6) {
            comparison("Original size", value: true)
            comparison("Adjusted", value: false)
        }
    }

    private var controls: some View {
        ScrollView {
            VStack(spacing: 6) {
                HStack {
                    pageButton("Previous page", icon: "chevron.left", delta: -step).disabled(firstPage == 0)
                    VStack(spacing: 0) {
                        if endPage > firstPage + 1 {
                            Text("Pages \(firstPage + 1)–\(endPage) of \(pageCount)").accessibilityIdentifier("manga-preview-page")
                        } else {
                            Text("Page \(firstPage + 1) of \(pageCount)").accessibilityIdentifier("manga-preview-page")
                        }
                        if pageCount > step {
                            Slider(value: Binding(get: { Double(firstPage / step) }, set: { pageIndex = Int($0) * step }),
                                in: 0...Double((pageCount - 1) / step), step: 1).accessibilityLabel("Preview page")
                        }
                    }.frame(maxWidth: .infinity)
                    pageButton("Next page", icon: "chevron.right", delta: step).disabled(endPage == pageCount)
                }
                if source.book.pages[firstPage..<endPage].allSatisfy({ $0.textBoxes.isEmpty }) {
                    Text("No recognized text on this page. Choose another page.").font(.caption)
                }
                Toggle("Enlarge Small Text", isOn: $draft.enabled).tint(.green)
                HStack { preset("Subtle", 25, 24); preset("Balanced", 50, 30); preset("Strong", 75, 40) }
                LabeledContent("Enlargement amount", value: "\(draft.amount)%")
                Slider(value: Binding(get: { Double(draft.amount) }, set: { draft.amount = Int($0) }), in: 0...100, step: 5)
                    .disabled(!draft.enabled).accessibilityLabel("Enlargement amount").accessibilityValue("\(draft.amount)%")
                LabeledContent("Small-text cutoff", value: "\(draft.threshold) px")
                Slider(value: Binding(get: { Double(draft.threshold) }, set: { draft.threshold = Int($0) }), in: 10...60, step: 1)
                    .disabled(!draft.enabled).accessibilityLabel("Small-text cutoff").accessibilityValue("\(draft.threshold) image pixels")
                Text("100% raises small text to the cutoff (image pixels).").font(.caption)
            }
        }
    }

    private func pageButton(_ label: LocalizedStringKey, icon: String, delta: Int) -> some View {
        Button { pageIndex = firstPage + delta } label: {
            Image(systemName: icon).frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(label)
    }
    private func comparison(_ title: LocalizedStringKey, value: Bool) -> some View {
        Button { original = value } label: {
            Text(title).padding(.horizontal, 8).frame(minHeight: 44)
                .contentShape(Rectangle())
                .overlay(Capsule().strokeBorder(original == value ? .white : .clear, lineWidth: 2))
        }.accessibilityAddTraits(original == value ? .isSelected : [])
    }
    private func preset(_ title: LocalizedStringKey, _ amount: Int, _ threshold: Int) -> some View {
        let selected = draft.enabled && draft.amount == amount && draft.threshold == threshold
        return Button {
            draft = .init(amount: amount, threshold: threshold)
            original = false
        } label: {
            Text(title).frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
                .overlay(Capsule().strokeBorder(selected ? .white : .clear, lineWidth: 2))
        }.accessibilityAddTraits(selected ? .isSelected : [])
    }

    private struct RenderRequest: Hashable {
        let page: Int
        let config: MangaPageRenderConfig
    }

    private func renderConfig(size: CGSize) -> MangaPageRenderConfig {
        MangaPageRenderConfig(backgroundCssColor: "#000", scanNonJapaneseText: false,
            viewportCssWidth: max(1, Int(size.width.rounded())), viewportCssHeight: max(1, Int(size.height.rounded())),
            singleTapLookup: false, useNotoSansJpFont: useSans, showActionButtons: showActions, selectionScript: "", showCopyButton: showCopy,
            enlargeSmallText: !original && draft.enabled, textEnlargementAmount: draft.amount,
            smallTextThreshold: draft.threshold, showFurigana: furigana, textSizePreview: true)
    }
}
