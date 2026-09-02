import re
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def read(relative_path: str) -> str:
    return (ROOT / relative_path).read_text(encoding="utf-8")


def method_body(source: str, signature: str) -> str:
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 0
    for index in range(brace, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Could not find body for {signature}")


class LastTenRegressionTests(unittest.TestCase):
    def test_payload_excludes_manga_statistics(self):
        payload = read("Features/HttpSync/HttpSyncPayload.swift")
        self.assertIn('"manga_statistics.json"', payload)

    def test_metadata_has_persisted_sync_id_and_importers_write_it(self):
        book = read("Models/Book.swift")
        sync_core = read("Features/HttpSync/SyncCore.swift")
        bookshelf = read("Features/Bookshelf/BookshelfViewModel.swift")
        mokuro = read("Features/Mokuro/MokuroImporter.swift")
        reconciler = read("Features/HttpSync/HttpSyncReconciler.swift")

        self.assertRegex(book, r"var\s+syncId:\s*String\?")
        self.assertIn("syncId: String? = nil", book)
        self.assertIn("func syncId(for metadata: BookMetadata) -> String?", sync_core)
        self.assertIn("deriveSyncId(document.title, folderName: bookFolder.lastPathComponent)", bookshelf)
        self.assertIn("deriveSyncId(title, folderName: folderName)", mokuro)
        self.assertIn("syncId: syncId", reconciler)

    def test_sync_uses_metadata_sync_id_for_local_books_deletes_and_hot_pushes(self):
        reconciler = read("Features/HttpSync/HttpSyncReconciler.swift")
        bookshelf = read("Features/Bookshelf/BookshelfViewModel.swift")
        manager = read("Features/HttpSync/HttpSyncManager.swift")

        self.assertIn("let bookSyncId = syncId(for: meta)", reconciler)
        self.assertNotIn("let syncId = deriveSyncId(title)", method_body(reconciler, "private func loadLocalBooks()"))
        self.assertIn("let bookSyncId = syncId(for: book)", bookshelf)
        self.assertIn("let bookSyncId = syncId(for: book)", manager)
        self.assertIn("batchState.queueBookmark(book: book)", manager)
        self.assertNotIn("pushBookmark(config: config, title:", manager)

    def test_offline_translation_fails_closed_without_downloaded_model(self):
        controller = read("Features/AI/MangaAiController.swift")
        ask_prefix = controller[
            controller.index("func ask(bubbleText: String, blockId:"):
            controller.index("let apiKey = settings.apiKey")
        ]
        self.assertIn("if offlineSettings.useOnDeviceTranslation {", ask_prefix)
        self.assertIn("guard !offlineDownloads.downloadedModelIds().isEmpty else", ask_prefix)

    def test_offline_history_records_actual_model_id(self):
        controller = read("Features/AI/MangaAiController.swift")
        self.assertIn("model: result.modelId", controller)
        self.assertNotIn("model: model.id", method_body(controller, "private func askOnDevice"))

    def test_manga_ai_dictionary_context_uses_cxx_string_helper(self):
        controller = read("Features/AI/MangaAiController.swift")
        result = method_body(controller, "private static func toResult")
        self.assertIn("cxxStringToSwift($0.name)", result)
        self.assertIn("cxxStringToSwift($0.description)", result)
        self.assertIn("cxxStringToSwift($0.dict_name)", result)
        self.assertIn("cxxStringToSwift(result.term.expression)", result)
        self.assertIn("cxxStringToSwift(result.matched)", result)
        self.assertNotIn("String($0.name)", result)
        self.assertNotIn("String($0.dict_name)", result)

    def test_download_delete_and_cancel_suppress_late_callbacks(self):
        manager = read("Features/AI/offline/ModelDownloadManager.swift")
        self.assertIn("cancelledModelIds", manager)
        self.assertIn("deletedModelIds", manager)
        finish = method_body(manager, "fileprivate func finishDownload")
        self.assertIn("deletedModelIds.remove(modelId)", finish)
        self.assertIn("cancelledModelIds.remove(modelId)", finish)
        self.assertIn("removeItem(at:", finish)

    def test_deleted_model_download_tombstones_survive_relaunch(self):
        manager = read("Features/AI/offline/ModelDownloadManager.swift")
        self.assertIn("deletedModelIdsStoreKey", manager)
        self.assertIn("cancelledModelIdsStoreKey", manager)
        self.assertIn("loadDeletedModelIds()", manager)
        self.assertIn("persistDeletedModelIds()", manager)
        self.assertIn("loadCancelledModelIds()", manager)
        self.assertIn("persistCancelledModelIds()", manager)
        self.assertIn("persistCancelledModelIds()", method_body(manager, "func cancel"))
        self.assertIn("persistDeletedModelIds()", method_body(manager, "func delete"))
        reattach = method_body(manager, "private func reattachOutstandingTasks")
        self.assertIn("deletedModelIds.contains(id)", reattach)
        self.assertIn("cancelledModelIds.contains(id)", reattach)
        self.assertIn("task.cancel()", reattach)
        self.assertIn("delegate.suppressTask", reattach)

    def test_offline_llm_gate_wait_is_cancellable(self):
        llm = read("Features/AI/offline/OfflineLlmManager.swift")
        self.assertIn("CheckedContinuation<Void, Error>", llm)
        self.assertIn("private func gateAcquire() async throws", llm)
        gate = method_body(llm, "private func gateAcquire")
        self.assertIn("withTaskCancellationHandler", gate)
        self.assertIn("cancelGateWaiter", llm)
        self.assertGreaterEqual(llm.count("Task.checkCancellation()"), 4)

    def test_http_sync_rejects_cleartext_non_loopback_urls(self):
        settings = read("Features/HttpSync/HttpSyncSettingsStore.swift")
        self.assertIn("static func isSecureBaseURL", settings)
        self.assertRegex(settings, r"var isConfigured: Bool \{[^}]*Self\.isSecureBaseURL\(baseURL\)", re.S)
        self.assertRegex(settings, r"var isConfigured: Bool \{[^}]*HttpSyncSettingsStore\.isSecureBaseURL\(baseURL\)", re.S)

    def test_http_sync_retries_rate_limits_and_resumes_from_checkpoint(self):
        kv = read("Features/HttpSync/HttpSyncKv.swift")
        reconciler = read("Features/HttpSync/HttpSyncReconciler.swift")
        gate = method_body(kv, "func wait() async throws")

        self.assertIn("HttpSyncRequestGate(minimumInterval: 0.150)", kv)
        self.assertIn("http.statusCode == 429", kv)
        self.assertIn('"Retry-After"', kv)
        self.assertIn("maxRateLimitRetries", kv)
        self.assertLess(gate.index("nextRequestAt ="), gate.index("Task.sleep"))
        self.assertIn("imposeCooldown(seconds:", kv)
        self.assertIn(
            "transport.listAll(prefix: SyncKeys.allBooksPrefix, since: nil)",
            reconciler,
        )
        self.assertIn("HttpSyncAppliedKeyStore.load()", reconciler)
        self.assertIn("let applied = appliedKeys[meta.key]", reconciler)
        self.assertIn("applied.matches(meta)", reconciler)
        self.assertIn('private static let filename = ".http_sync_applied_keys.json"', reconciler)
        self.assertIn("if inbound.listingSucceeded", reconciler)

    def test_epub_translation_buttons_have_scroll_reader_css(self):
        paginated = read("Features/Reader/ReaderWebView/ReaderWebView.swift")
        continuous = read("Features/Reader/ScrollReaderWebView/ScrollReaderWebView.swift")
        shared_css = read("Features/Reader/ReaderWebView/SentenceButtonCss.swift")

        for selector in (".hoshi-tl {", ".hoshi-tl::before {", ".hoshi-tl::after {"):
            self.assertIn(selector, shared_css)
        self.assertIn("\\(sentenceButtonCss)", paginated)
        self.assertIn("\\(sentenceButtonCss)", continuous)
        self.assertIn("left: -0.7em;", shared_css)
        self.assertIn("bottom: -0.7em;", shared_css)

    def test_translation_sync_uses_etag_ledger_not_equal_byte_size(self):
        reconciler = read("Features/HttpSync/HttpSyncReconciler.swift")
        pretranslations = method_body(reconciler, "private func applyPretranslationsFromRemote")
        sentences = method_body(reconciler, "private func applySentenceTranslationsFromRemote")

        self.assertNotIn("localSize == remoteSize", pretranslations)
        self.assertNotIn("localSize == remoteSize", sentences)
        self.assertNotIn("meta.size", pretranslations)
        self.assertNotIn("meta.size", sentences)
        self.assertIn("applied.matches(meta)", reconciler)
        self.assertIn("localArtifact: applied.localArtifact", reconciler)

    def test_applied_reading_key_requires_its_local_artifact(self):
        reconciler = read("Features/HttpSync/HttpSyncReconciler.swift")
        check = method_body(reconciler, "private func localReadingArtifactIsPresent")

        self.assertIn("BookStorage.loadBookmark(root: root) != nil", check)
        self.assertIn("SyncKeys.chat(parsed.syncId, suffix: suffix) == key", check)
        self.assertIn("FileNames.pretranslations", check)
        self.assertIn("FileNames.sentenceTranslations", check)
        self.assertIn("applied.localArtifact?.matches", check)
        self.assertIn("size.int64Value > 0", reconciler)

    def test_dual_payload_manifests_use_metadata_or_reject_ambiguity(self):
        reconciler = read("Features/HttpSync/HttpSyncReconciler.swift")
        inbound = method_body(reconciler, "private func pullChangedKeys")

        self.assertIn("remoteFormatBySyncId[parsed.syncId] = remote.blob.contentType", inbound)
        self.assertIn("if let mokuro = pair.mokuro, let epub = pair.epub", inbound)
        self.assertIn("switch remoteFormatBySyncId[bookSyncId]", inbound)
        self.assertIn("both payload.manifest and epub.manifest exist without authoritative metadata", inbound)
        self.assertNotIn("payloadManifests.map", inbound)

    def test_remote_epub_import_checks_manifest_format_and_parse(self):
        payload = read("Features/HttpSync/HttpSyncPayload.swift")
        reconciler = read("Features/HttpSync/HttpSyncReconciler.swift")
        download = method_body(payload, "func downloadAndUnpack")
        remote_import = method_body(reconciler, "private func importRemoteOnlyBook")

        self.assertIn("manifest.format == expectedFormat", download)
        self.assertIn("manifest.format == format", remote_import)
        self.assertIn("guard detected == format", remote_import)
        self.assertIn("guard let parsed = try? BookStorage.loadEpub(root)", remote_import)
        self.assertLess(
            remote_import.index("guard let parsed = try? BookStorage.loadEpub(root)"),
            remote_import.index("let metadata = BookMetadata("),
        )

    def test_epub_sentence_blob_contract_is_fail_closed(self):
        store = read("Features/AI/EpubTranslationStore.swift")
        reconciler = read("Features/HttpSync/HttpSyncReconciler.swift")
        validation = method_body(store, "func validationError")
        apply_sentences = method_body(reconciler, "private func applySentenceTranslationsFromRemote")

        self.assertIn("syncId == expectedSyncId", validation)
        self.assertIn("spineCount == expectedSpineCount", validation)
        self.assertIn("entry.spine >= 0", validation)
        self.assertIn("entry.spine < expectedSpineCount", validation)
        self.assertIn("entry.start >= 0", validation)
        self.assertIn("entry.len > 0", validation)
        self.assertIn('id == "c\\(entry.spine)s\\(entry.start)"', validation)
        self.assertIn("normalized.unicodeScalars.count == entry.len", validation)
        self.assertIn("entry.hash == EpubTranslationStore.textHash(normalized)", validation)
        self.assertIn("entry.translation.trimmingCharacters", validation)
        self.assertIn("syncId(for: localMetadata) == expectedSyncId", apply_sentences)
        self.assertIn("BookStorage.loadEpub(root)", apply_sentences)
        self.assertIn("blob.validationError", apply_sentences)
        self.assertIn('SentenceAnchor(id: "\\(id)#\\(entry.hash)"', store)

    def test_epub_translation_js_uses_code_point_offsets(self):
        translations = read("Features/Reader/ReaderWebView/translations.js")
        resolve = method_body(translations, "resolve(chapter, anchor)")

        self.assertIn("Array.from(want)", resolve)
        self.assertIn("start < 0", resolve)
        self.assertNotIn("chapter.text.substr(", resolve)
        self.assertNotIn("indexOf(want", resolve)
        if shutil.which("node") is None:
            self.skipTest("node is required for the supplementary-plane translation probe")
        js_path = ROOT / "Features/Reader/ReaderWebView/translations.js"
        probe = textwrap.dedent(f"""
            const fs = require('fs');
            global.window = {{}};
            eval(fs.readFileSync({str(js_path)!r}, 'utf8'));
            const chapter = {{ chars: Array.from('甲𠀀乙'), text: '甲𠀀乙', ends: [0, 1, 2] }};
            const resolve = window.hoshiTranslations.resolve.bind(window.hoshiTranslations);
            if (resolve(chapter, {{ start: 1, len: 1, text: '𠀀' }}) !== 1) {{
              throw new Error('supplementary-plane code point did not resolve to ends[1]');
            }}
            if (resolve(chapter, {{ start: -1, len: 1, text: '甲' }}) !== -1) {{
              throw new Error('negative start was accepted');
            }}
            if (resolve(chapter, {{ start: 2, len: 1, text: '𠀀' }}) !== -1) {{
              throw new Error('stale offset was allowed to target another code point');
            }}
        """)
        subprocess.run(["node", "-e", probe], check=True, capture_output=True, text=True)

    def test_sentence_translation_toggle_updates_open_reader(self):
        view = read("Features/Reader/ReaderView/ReaderView.swift")
        model = read("Features/Reader/ReaderView/ReaderViewModel.swift")

        self.assertIn(".onChange(of: userConfig.readerShowSentenceTranslations)", view)
        self.assertIn("viewModel.setSentenceTranslationsEnabled(enabled)", view)
        toggle = method_body(model, "func setSentenceTranslationsEnabled")
        self.assertIn("preloadSentenceTranslationsAndReloadIfNeeded()", toggle)
        self.assertIn("loadCurrentChapter()", toggle)
        self.assertIn("Task.detached(priority: .userInitiated)", model)

    def test_keychain_pastes_publish_configuration_changes(self):
        http = read("Features/HttpSync/HttpSyncSettingsStore.swift")
        ai = read("Features/AI/AiChatSettingsStore.swift")

        self.assertIn("private var tokenRevision = 0", http)
        self.assertIn("_ = tokenRevision", http)
        self.assertIn("tokenRevision &+= 1", http)
        self.assertIn("trimmingCharacters(in: .whitespacesAndNewlines)", http)
        self.assertIn("private var apiKeyRevision = 0", ai)
        self.assertIn("_ = apiKeyRevision", ai)
        self.assertIn("apiKeyRevision &+= 1", ai)

    def test_translation_settings_sync_before_books_and_ignores_book_breaker(self):
        manager = read("Features/HttpSync/HttpSyncManager.swift")
        reconcile = method_body(
            manager,
            "private func runReconcile(preflight: HttpSyncMapChanges?) async",
        )
        settings_push = method_body(manager, "func onAiSettingsChanged()")

        self.assertLess(
            reconcile.index("syncAppSettings"),
            reconcile.index("reconciler.syncOnce"),
        )
        self.assertIn("guard settings.enabled, settings.isConfigured, let aiSettings", settings_push)
        self.assertNotIn("autoPushReady", settings_push)
        self.assertNotIn("notePushOutcome", settings_push)

    def test_gemini_uses_google_and_never_displays_openai_fallback_labels(self):
        catalog = read("Features/AI/ChatModelCatalog.swift")
        client = read("Features/AI/OpenAiChatClient.swift")
        gemini = read("Features/AI/GeminiChatClient.swift")
        popup = read("Features/AI/MangaAiPopupView.swift")

        self.assertIn('id: "gemini-3.6-flash"', catalog)
        self.assertIn('baseURL: "https://generativelanguage.googleapis.com/v1beta"', catalog)
        self.assertIn("wireFormat: .gemini", catalog)
        self.assertIn("case .gemini:", catalog)
        self.assertIn("GeminiChatClient()", catalog)
        self.assertIn("models/\\(encodedModel):generateContent", gemini)
        self.assertIn('forHTTPHeaderField: "x-goog-api-key"', gemini)
        self.assertIn("serviceName: provider.displayName", catalog)
        self.assertIn(r'"\(serviceName) request failed', client)
        self.assertIn("controller.activeBackendName", popup)
        self.assertNotIn("Asking ChatGPT", popup)

    def test_page_ready_is_tied_to_navigation_load_token(self):
        view = read("Features/MangaReader/MangaReaderView.swift")
        webview = read("Features/MangaReader/MangaReaderWebView.swift")
        view_model = read("Features/MangaReader/MangaReaderViewModel.swift")

        self.assertIn("@State private var pendingSlideLoadToken: Int?", view)
        self.assertIn("private func onPageReady(loadToken: Int)", view)
        self.assertIn("pendingSlideLoadToken = token", view)
        self.assertIn("guard loadToken == pendingLoadToken", view)
        self.assertIn("var onPageReady: (Int) -> Void", webview)
        self.assertIn("navigationLoadTokens", webview)
        self.assertIn("parent.onPageReady(finishedLoadToken)", webview)
        self.assertIn("onLoadToken: ((Int) -> Void)? = nil", view_model)

    def test_manga_menu_actions_clear_existing_popups(self):
        view = read("Features/MangaReader/MangaReaderView.swift")
        menu_body = method_body(view, "private var topBar")
        self.assertRegex(
            menu_body,
            r"Button\s*\{\s*model\.closePopups\(\)\s*goToPageText =",
            re.S,
        )

    def test_ai_history_menu_cannot_toggle_to_blank_current_body(self):
        popup = read("Features/AI/MangaAiPopupView.swift")
        self.assertIn("showHistory || controller.state == .browsingHistory", popup)
        history_button = popup[
            popup.index("Button {"):
            popup.index(".help(showHistory ?")
        ]
        self.assertIn("guard controller.state != .browsingHistory else", history_button)

    def test_ai_popup_has_bounded_scroll_window_and_wraps_long_tokens(self):
        popup = read("Features/AI/MangaAiPopupView.swift")
        tokenizer = read("Features/AI/MangaAiTextTokenizer.swift")
        self.assertIn("let maxCardWidth: CGFloat = isPad ? 680 : 520", popup)
        self.assertIn(".frame(width: width, height: height)", popup)
        self.assertIn(".scrollIndicators(.visible)", popup)
        self.assertNotIn("let maxCharactersPerToken = 8", popup)
        self.assertIn("import NaturalLanguage", tokenizer)
        self.assertIn("NLTokenizer(unit: .word)", tokenizer)
        self.assertNotIn("maxUnbrokenCharacters", tokenizer)
        swift = shutil.which("swift")
        if swift is not None:
            assertions = r'''

let text = "This doesn't split words, and we're okay."
let segments = MangaAiTextTokenizer.segments(in: text).map(\.text)
precondition(segments.contains("doesn't"), "doesn't was split: \(segments)")
precondition(segments.contains("we're"), "we're was split: \(segments)")
precondition(!segments.contains("doesn"), "bad partial segment: \(segments)")
let chained = MangaAiTextTokenizer.segments(in: "state-of-the-art doesn't split").map(\.text)
precondition(chained.contains("state-of-the-art"), "hyphenated chain was split: \(chained)")
let mixed = MangaAiTextTokenizer.segments(in: "日本語 doesn't")
precondition(mixed.filter { $0.kind == .japanese }.map(\.text) == ["日", "本", "語"])
precondition(mixed.contains { $0.text == "doesn't" && $0.kind == .word })
'''
            with tempfile.TemporaryDirectory() as tmp:
                script = Path(tmp) / "main.swift"
                script.write_text(tokenizer + assertions, encoding="utf-8")
                subprocess.run([swift, str(script)], check=True, capture_output=True, text=True)

    def test_ai_screenshot_viewer_uses_native_zoom_scroll_view(self):
        popup = read("Features/AI/MangaAiPopupView.swift")
        self.assertIn("ZoomableScreenshotViewer", popup)
        self.assertIn("private final class ZoomingImageScrollView: UIScrollView, UIScrollViewDelegate", popup)
        self.assertIn("maximumZoomScale = 6", popup)
        self.assertIn("zoom(to: rect, animated: true)", popup)

    def test_ai_screenshot_translation_persists_attached_image(self):
        controller = read("Features/AI/MangaAiController.swift")
        history = read("Features/AI/AiChatHistoryStore.swift")
        types = read("Features/AI/AiChatTypes.swift")

        translate = method_body(controller, "func translateCrop")
        self.assertIn("screenshotImage: image", translate)
        self.assertIn("self.persist(entry, book: book)", translate)
        self.assertIn("func append(_ entry: AiChatEntry, folder: String)", history)
        self.assertIn("FileNames.aiChatLog", history)
        self.assertIn("var screenshotImage: AiChatImage?", types)

    def test_ai_popup_strips_thinking_and_uses_library_markdown_renderer(self):
        popup = read("Features/AI/MangaAiPopupView.swift")
        sanitizer = read("Features/AI/AiThinkingTextSanitizer.swift")
        project = read("Hoshi Reader.xcodeproj/project.pbxproj")

        self.assertIn("import Textual", popup)
        self.assertIn("let visible = AiThinkingTextSanitizer.strip(response)", popup)
        self.assertIn("StructuredText(markdown: visible)", popup)
        self.assertIn("HoshiMarkdownStyle(useUniformTextSize:", popup)
        self.assertIn("private struct HoshiMarkdownStyle: StructuredText.Style", popup)
        # The reply sits on an opaque system-background card and uses primary-coloured text in
        # every Markdown node, so it stays legible over a white manga page in either colour
        # scheme (white-on-ultraThinMaterial was unreadable).
        self.assertIn(".background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 20))", popup)
        self.assertNotIn(".ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20)", popup)
        self.assertGreaterEqual(popup.count(".foregroundColor(.primary)"), 4)
        self.assertGreaterEqual(popup.count(".foregroundStyle(.primary)"), 3)
        self.assertNotIn(".foregroundColor(.white)", popup)
        self.assertNotIn(".foregroundStyle(.white)", popup)
        self.assertIn(".textual.highlighterTheme(.init(", popup)
        self.assertIn("foregroundColor: DynamicColor(.primary)", popup)
        self.assertNotIn("tokenProperties:", popup)
        # Text selection in the reply stays off: Textual's selection bridge traps with "Index
        # out of range" under UIKit's edit menu on iOS (gonzalezreal/textual#87), which crashed
        # the app on a long-press in the reply. A header button copies the reply instead.
        self.assertNotIn("textSelection(.enabled)", popup)
        self.assertIn("gonzalezreal/textual#87", popup)
        self.assertIn('.accessibilityLabel("Copy reply")', popup)
        self.assertIn("UIPasteboard.general.string = AiThinkingTextSanitizer.strip(entry.response)", popup)
        self.assertNotIn("responseBlocks", popup)
        self.assertNotIn("markdownHeading", popup)
        self.assertNotIn("parseTableRow", popup)
        self.assertNotIn("AttributedString(markdown:", popup)
        self.assertIn("progress.totalTokens > 0", popup)
        self.assertIn("progress.thinkingTokens", popup)
        self.assertIn("%d answer tokens · %d thinking tokens", popup)
        self.assertIn('private static let startTags = ["<think>", "<thinking>"]', sanitizer)
        self.assertIn('private static let endTags = ["</think>", "</thinking>"]', sanitizer)
        self.assertIn('"thinking processes"', sanitizer)
        self.assertIn('"reasoning:"', sanitizer)
        self.assertIn('"analysis:"', sanitizer)
        self.assertIn("stripUntaggedReasoning", sanitizer)
        self.assertIn("\"wait, let's check\"", sanitizer)
        self.assertIn('"wait, looking"', sanitizer)
        self.assertIn('"draft translation"', sanitizer)
        self.assertIn('"draft breakdown"', sanitizer)
        self.assertNotIn('"wait,"', sanitizer)
        self.assertNotIn('"wait",', sanitizer)
        self.assertNotIn('"looking at",', sanitizer)
        self.assertNotIn('"first,"', sanitizer)
        self.assertNotIn('"i need to",', sanitizer)
        self.assertIn('"answer:"', sanitizer)
        self.assertIn("options: [.caseInsensitive]", sanitizer)
        self.assertIn('return ""', sanitizer)
        self.assertIn('XCRemoteSwiftPackageReference "textual"', project)
        self.assertIn("Textual in Frameworks", project)

    def test_ai_markdown_default_size_option_is_persistent_and_local(self):
        store = read("Features/AI/AiChatSettingsStore.swift")
        settings = read("Features/AI/AiSettingsView.swift")
        popup = read("Features/AI/MangaAiPopupView.swift")

        self.assertIn("private(set) var useUniformMarkdownTextSize: Bool", store)
        self.assertIn("defaults.bool(forKey: Keys.useUniformMarkdownTextSize)", store)
        size_setter = method_body(store, "func setUseUniformMarkdownTextSize")
        self.assertIn("defaults.set(enabled, forKey: Keys.useUniformMarkdownTextSize)", size_setter)
        self.assertNotIn("onAiSettingsChanged", size_setter)
        self.assertIn('Toggle("Use default Markdown text size"', settings)
        self.assertIn('Image(systemName: "textformat.size")', popup)
        self.assertIn("let scale = useUniformTextSize ? 1 :", popup)

    def test_sync_timestamp_clamps_instead_of_trapping(self):
        core = read("Features/HttpSync/SyncCore.swift")
        self.assertIn("rawMillis.isNaN", core)
        self.assertIn("253_402_300_799_999", core)
        self.assertNotIn("let unixMillis = Int64((appleSeconds + appleReferenceEpoch) * 1000.0)", core)
        swift = shutil.which("swift")
        if swift is not None:
            assertions = r"""

let poisoned = chatEntryKeySuffix(timestampAppleSeconds: 1e300, bubbleText: "b", response: "r")
precondition(!poisoned.isEmpty)
let negative = chatEntryKeySuffix(timestampAppleSeconds: -1e300, bubbleText: "b", response: "r")
precondition(!negative.isEmpty)
let nan = chatEntryKeySuffix(timestampAppleSeconds: Double.nan, bubbleText: "b", response: "r")
precondition(!nan.isEmpty)
let sane = appleSecondsToRfc3339(800_000_000.0)
precondition(sane.hasPrefix("2026-"), sane)
"""
            # SyncCore's only non-stdlib dependency is BookMetadata (three fields used).
            stub = "struct BookMetadata { var title: String?; var folder: String?; var syncId: String? }\n"
            with tempfile.TemporaryDirectory() as tmp:
                script = Path(tmp) / "main.swift"
                script.write_text(stub + core + assertions, encoding="utf-8")
                subprocess.run([swift, str(script)], check=True, capture_output=True, text=True)

    def test_ai_history_screenshots_use_downsampled_cached_thumbnails(self):
        popup = read("Features/AI/MangaAiPopupView.swift")
        self.assertIn("private struct ScreenshotThumbnail", popup)
        self.assertIn("NSCache<NSString, UIImage>", popup)
        self.assertIn("CGImageSourceCreateThumbnailAtIndex", popup)
        self.assertIn("kCGImageSourceThumbnailMaxPixelSize", popup)
        self.assertIn("Task.detached(priority: .utility)", popup)
        # Full-resolution decode happens only on tap-to-zoom, never in the list rows.
        self.assertNotIn("decodeImage(image)", popup)
        entry_view = method_body(popup, "private func entryView")
        self.assertNotIn("UIImage(data:", entry_view)
        self.assertIn("ScreenshotThumbnail(image: image, cacheKey: entry.id)", entry_view)

    def test_thinking_sanitizer_preserves_valid_wait_translations(self):
        sanitizer = read("Features/AI/AiThinkingTextSanitizer.swift")
        swift = shutil.which("swift")
        if swift is None:
            self.skipTest("swift is required to execute sanitizer behavior regression")

        assertions = r'''

func assertEqual(_ actual: String, _ expected: String, _ label: String) {
    precondition(actual == expected, "\(label): expected <\(expected)> got <\(actual)>")
}

assertEqual(
    AiThinkingTextSanitizer.strip("Wait, what is this?"),
    "Wait, what is this?",
    "valid wait translation"
)
assertEqual(
    AiThinkingTextSanitizer.stripUntaggedReasoning("Wait, what is this?"),
    "Wait, what is this?",
    "valid wait final after FINAL marker"
)
assertEqual(
    AiThinkingTextSanitizer.stripUntaggedReasoning("Wait, let's check the map."),
    "Wait, let's check the map.",
    "valid wait lets-check translation"
)
assertEqual(
    AiThinkingTextSanitizer.stripUntaggedReasoning("Let's check this out."),
    "Let's check this out.",
    "valid lets-check translation"
)
assertEqual(
    AiThinkingTextSanitizer.stripUntaggedReasoning("Wait, let's check the comma placement."),
    "",
    "comma placement reasoning is hidden"
)
assertEqual(
    AiThinkingTextSanitizer.stripUntaggedReasoning("Wait, looking at the comma placement."),
    "",
    "looking-at comma reasoning is hidden"
)
assertEqual(
    AiThinkingTextSanitizer.stripUntaggedReasoning("Wait, let's check the comma placement.\n\nTranslation: Wait, what is this?"),
    "Wait, what is this?",
    "reasoning wait prefix"
)
assertEqual(
    AiThinkingTextSanitizer.stripUntaggedReasoning("First, open the door."),
    "First, open the door.",
    "valid first final"
)
assertEqual(
    AiThinkingTextSanitizer.stripUntaggedReasoning("Looking at the moon, I smiled."),
    "Looking at the moon, I smiled.",
    "valid looking-at final"
)
assertEqual(
    AiThinkingTextSanitizer.stripUntaggedReasoning("This is a sentence looking at the moon."),
    "This is a sentence looking at the moon.",
    "valid embedded looking-at final"
)
assertEqual(
    AiThinkingTextSanitizer.stripUntaggedReasoning("""
*   "は" (wa) = topic marker.
*   "何" (nani) = what?

4.  **Draft Translation:**
    *   Literal: What is this? / What's that thing?
    *   Natural: What is this?

5.  **Draft Breakdown:**
    *   hidden scaffold
"""),
    "What is this?",
    "draft scaffold is not visible"
)
assertEqual(
    AiThinkingTextSanitizer.strip("Analysis: I should inspect this first.\n\nTranslation: This is a test."),
    "Translation: This is a test.",
    "analysis label"
)
assertEqual(
    AiThinkingTextSanitizer.strip("<thinking>private chain</thinking>Final answer"),
    "Final answer",
    "thinking tags"
)
'''
        with tempfile.TemporaryDirectory() as tmp:
            script = Path(tmp) / "main.swift"
            script.write_text(sanitizer + assertions, encoding="utf-8")
            subprocess.run([swift, str(script)], check=True, capture_output=True, text=True)

    def test_offline_llm_suppresses_qwen_thinking_and_awaits_reset(self):
        manager = read("Features/AI/offline/OfflineLlmManager.swift")
        llm = read("Libraries/LLM.swift/Sources/LLM/LLM.swift")

        translate = method_body(manager, "func translate")
        self.assertIn("let privateThinkingEnabled = templateKind == .chatML && settings.usePrivateThinking", translate)
        self.assertIn("let thinkingMode: ThinkingMode = privateThinkingEnabled ? .enabled", translate)
        self.assertIn(": (templateKind == .chatML ? .suppressed : .none)", translate)
        self.assertIn("await llm.prepareTemplateForGeneration()", translate)
        self.assertIn("await llm.reset()", translate)
        self.assertNotIn("Task.yield()", translate)
        self.assertNotIn("getChatTemplateHint()", translate)
        self.assertIn("nonisolated private static let contextCap: Int32 = 12288", manager)
        self.assertIn("nonisolated private static let thinkingTokenBudget = 192", manager)
        self.assertIn("nonisolated private static let suppressedThinkingTokenBudget = 1", manager)
        self.assertIn("await llm.core.setThinkingBudget(Self.thinkingBudget(for: thinkingMode))", translate)
        self.assertIn("let requestedResponseTokenBudget = OfflineTranslationSettingsStore.clampedResponseTokenLimit(", translate)
        self.assertIn("let responseTokenBudget = await Self.applyResponseTokenBudget(", translate)
        self.assertIn("prompt: prompt", translate)
        self.assertIn("thinking: thinking", translate)
        self.assertIn("await boxed.value.core.setThinkingBudget(Self.thinkingBudget(for: thinking))", translate)
        self.assertIn("await llm.core.setResponseTokenBudget(1)", translate)
        self.assertIn("await llm.core.setBlocksCJKOnFirstResponseLine(templateKind == .chatML)", translate)
        self.assertIn("await boxed.value.core.setBlocksCJKOnFirstResponseLine(templateKind == .chatML)", translate)
        self.assertIn("let generationTask = Task.detached", translate)
        self.assertIn("try Task.checkCancellation()", translate[translate.index("await llm.core.setResponseTokenBudget(1)"):])
        self.assertIn("guard !Task.isCancelled else { return }", translate)
        self.assertIn("boxed.value.stop()", translate)
        self.assertIn("generationTask.cancel()", translate)
        self.assertIn("let hiddenThinking = await boxed.value.think(", translate)
        self.assertIn("let finalPrompt = Self.buildFinalAnswerContent(", translate)
        self.assertIn("resetForFinalRetry", translate)
        self.assertIn("firstAnswerLineContainsCJK(firstPassText)", translate)
        self.assertIn('hiddenThinking: ""', translate)
        self.assertIn("thinking: .suppressed", translate)
        self.assertIn("thinking: thinkingMode", translate)
        self.assertIn("responsePrefix: responsePrefix", translate)
        self.assertIn("onThinkingTokenCount:", translate)
        self.assertIn("setThinkingTokens(count)", translate)
        self.assertIn("thinkingTokens: snapshot.thinkingTokens", translate)
        self.assertIn("Self.throughput(tokens: snapshot.totalTokens", translate)
        self.assertIn("let thinkingTokens: Int", manager)
        self.assertIn("var totalTokens: Int { tokens + thinkingTokens }", manager)
        self.assertIn("%d answer tokens · %d thinking tokens", manager)
        self.assertIn("nonisolated static var debugThinkingTokenBudget: Int { thinkingTokenBudget }", manager)
        self.assertIn("Self.visibleStreamingText(snapshot.text, template: templateKind)", translate)
        self.assertIn("let stableVisible = collectedBox.value.setVisibleText(visible)", translate)
        self.assertIn("private func shouldReplaceVisibleText(with candidate: String)", manager)
        self.assertIn("currentLooksLikeScaffold && !nextLooksLikeScaffold", manager)
        self.assertIn('"wait, looking"', manager)
        self.assertIn('"looking at the comma"', manager)
        self.assertNotIn('/no_think', manager)
        self.assertNotIn("answerFinalMarkerRange", manager)
        self.assertNotIn("options: [.caseInsensitive, .backwards]", manager)
        self.assertIn("topK: 20", manager)
        self.assertIn("temp: 0.2", manager)
        self.assertIn('private static let chatMLResponsePrefix = "The English answer is: "', manager)
        self.assertIn("Target language is English", manager)
        self.assertIn("must contain zero Chinese/Japanese/Korean characters", manager)
        self.assertIn('"the english answer is:"', manager)
        self.assertIn("stripLeadingFinalMarker", manager)
        self.assertIn("looksTruncated", manager)
        final_prompt = method_body(manager, "nonisolated private static func buildFinalAnswerContent")
        self.assertIn("NO MORE THINKING", final_prompt)
        self.assertIn("Do not quote, summarize, mention, or continue these notes", final_prompt)
        self.assertIn("English-only examples", final_prompt)
        self.assertIn("Final answer: What is this?", final_prompt)
        self.assertIn("Final answer: Wait, what is this?", final_prompt)
        self.assertIn('Do not write drafts, checks, plans, "wait"', final_prompt)
        cleanup = method_body(manager, "nonisolated private static func cleanup")
        self.assertIn("let withoutMarker = stripLeadingFinalMarker(stripped)", cleanup)
        self.assertIn("return stripLeadingFinalMarker(AiThinkingTextSanitizer.stripUntaggedReasoning(withoutMarker))", cleanup)
        self.assertNotIn('return ""', cleanup)
        self.assertIn("The on-device model stopped before producing a final answer", manager)
        self.assertIn("The on-device model answered in the wrong language", manager)
        self.assertIn("firstAnswerLineContainsCJK(visible) ? \"\" : visible", manager)
        self.assertIn("func resetResponse()", manager)
        self.assertIn("nonisolated private static func applyResponseTokenBudget", manager)
        self.assertIn("processedPromptTokenCount(for: prompt, thinking: thinking)", manager)
        self.assertIn("contextTokenLimit", manager)
        self.assertIn("nonisolated private static func effectiveResponseTokenBudget", manager)
        self.assertIn("guard let budget = effectiveResponseTokenBudget(", manager)
        self.assertIn("contextTokenLimit - promptAndSafetyReserve - hiddenTokenReserve", manager)
        self.assertIn("guard available > 0 else { return nil }", manager)
        self.assertNotIn("max(256, contextTokenLimit", manager)
        self.assertIn("The on-device model prompt is too long for the loaded model", manager)
        self.assertIn("collected.setError(", manager)
        self.assertIn("if let errorMessage = collected.errorMessage()", manager)
        self.assertIn("budget: finalOutput.responseBudget", manager)
        self.assertIn("let responseBudget: Int", manager)
        self.assertIn("func setError(_ message: String)", manager)
        self.assertIn("func errorMessage() -> String?", manager)
        self.assertIn("hit the answer limit before finishing", manager)
        gate = method_body(manager, "private func gateAcquire")
        self.assertIn("if Task.isCancelled {", gate)
        self.assertIn("gateRelease()", gate)
        self.assertIn("throw CancellationError()", gate)
        self.assertIn("private func applyTemplateToCore(_ template: Template?) async", llm)
        self.assertIn("@MainActor public func prepareTemplateForGeneration() async", llm)
        self.assertIn("@MainActor public func reset() async", llm)
        self.assertIn("await core.resetContext()", llm)
        self.assertIn("onThinkingTokenCount: (@Sendable (Int) async -> Void)? = nil", llm)
        self.assertIn("let streams = await core.generateResponseStreamWithThinking", llm)
        self.assertIn("onThinkingTokenCount: onThinkingTokenCount", llm)
        self.assertIn("public func think(", llm)
        self.assertIn("let responseDrain = Task", llm)
        self.assertIn("await core.stopGeneration()", llm)
        self.assertIn("public func contextTokenLimit() async -> Int", llm)
        self.assertIn("public func processedPromptTokenCount(for input: String, thinking: ThinkingMode = .none) async -> Int", llm)
        self.assertIn("await onThinkingTokenCount?(thinkingTokensSeen)", llm)
        self.assertIn("for await _ in streams.thinking", llm)
        self.assertIn("let output = await makeOutputFrom(streams.response)", llm)
        reset_context = method_body(llm, "func resetContext")
        self.assertIn("llama_memory_clear(llama_get_memory(context), false)", reset_context)
        self.assertNotIn("llama_memory_seq_rm(llama_get_memory(context), -1, -1, -1)", reset_context)

    def test_offline_model_catalog_keeps_legacy_qwen_downloads_visible(self):
        catalog = read("Features/AI/offline/LlmModelCatalog.swift")
        all_models = catalog[catalog.index("static let all: [LlmModel]"):catalog.index("static func byId")]

        self.assertIn("qwen35_9B", all_models)
        self.assertIn("qwen35_4B", all_models)
        self.assertIn("qwen35_2B", all_models)
        self.assertIn("qwen7BQ4", all_models)
        self.assertIn("qwen14BQ4", all_models)
        self.assertIn("qwen1_5BQ4", all_models)
        self.assertIn("qwen0_5BQ4", all_models)
        self.assertIn("Legacy Qwen2.5 entries are kept", catalog)

    def test_llm_thinking_marker_detection_supports_aliases_and_budget(self):
        llm = read("Libraries/LLM.swift/Sources/LLM/LLM.swift")

        self.assertIn("thinkingStartMarkerVariants", llm)
        self.assertIn("thinkingEndMarkerVariants", llm)
        self.assertIn('variants.append("<thinking>")', llm)
        self.assertIn('variants.append("</thinking>")', llm)
        self.assertIn("markerSuffix(in: pendingText, markers: startMarkers)", llm)
        self.assertIn("markerSuffix(in: pendingText, markers: endMarkers)", llm)
        self.assertIn("lowercased.hasSuffix", llm)
        self.assertIn("effectiveThinkingTokenBudget", llm)
        self.assertIn("thinkingTokensSeen >= effectiveThinkingTokenBudget", llm)
        self.assertIn("thinkingMode == .suppressed && thinkingTokenBudget == 0", llm)
        self.assertIn("injectTokensIntoContext(endTokens + [newlineToken])", llm)
        self.assertIn("private var responseTokenBudget: Int = 0", llm)
        self.assertIn("public func setResponseTokenBudget(_ tokens: Int)", llm)
        self.assertIn("public func setBlocksCJKOnFirstResponseLine(_ enabled: Bool)", llm)
        self.assertIn("blocksCJKOnFirstResponseLine", llm)
        self.assertIn("private static func containsCJK", llm)
        self.assertIn("rejecting shouldReject", llm)
        self.assertIn("responseTokensSeen >= responseTokenBudget", llm)
        self.assertIn("responsePrefix: String = \"\"", llm)
        self.assertIn("injectTokensIntoContext(prefixTokens)", llm)
        self.assertIn("injectResponsePrefixIfNeeded", llm)
        self.assertIn("var currentlyInThinkingPhase = thinkingMode == .enabled", llm)
        self.assertIn("await Task.yield()", llm)
        self.assertIn("public var postprocess: @Sendable (_ output: String) -> Void = { _ in }", llm)

    def test_offline_llm_launch_selftest_fails_on_visible_reasoning(self):
        app = read("App/HoshiReader.swift")

        self.assertIn("HOSHI_LLM_SELFTEST", app)
        self.assertIn("failed leaked-thinking", app)
        self.assertIn("secondText", app)
        self.assertIn("for (index, sample) in [text, secondText].enumerated()", app)
        self.assertIn("HOSHI_LLM_SELFTEST success runs=\\(summaries.count)", app)
        self.assertIn("answerTokens=\\(progress.tokens)", app)
        self.assertIn("thinkingTokens=\\(progress.thinkingTokens)", app)
        self.assertIn("thinkingTokens=\\(result.thinkingTokens)", app)
        self.assertIn("HOSHI_LLM_SELFTEST_PRIVATE_THINKING", app)
        self.assertIn("OfflineTranslationSettingsStore.shared.usePrivateThinking = privateThinkingEnabled", app)
        self.assertIn("failed missing-hidden-thinking", app)
        self.assertIn("if privateThinkingEnabled && result.thinkingTokens <= 0", app)
        self.assertIn("failed thinking-budget-exceeded", app)
        self.assertIn("failed non-english-translation", app)
        self.assertIn("firstAnswerLineLooksNonEnglish", app)
        self.assertIn("if result.thinkingTokens > OfflineLlmManager.debugThinkingTokenBudget", app)
        self.assertIn("budget=\\(OfflineLlmManager.debugThinkingTokenBudget)", app)
        self.assertIn('"analysis:"', app)
        self.assertIn('"reasoning:"', app)
        self.assertIn('"thinking process"', app)
        self.assertIn('"chain-of-thought"', app)
        self.assertIn('"draft translation"', app)
        self.assertIn('"draft breakdown"', app)
        self.assertIn('"checking the"', app)
        self.assertIn('"looking at the comma"', app)
        self.assertIn("return", app[app.index("if leakedThinking {"):app.index("HOSHI_LLM_SELFTEST success")])
        self.assertNotIn('"wait,"', app)

    def test_ai_controller_ignores_stale_second_tap_results(self):
        controller = read("Features/AI/MangaAiController.swift")

        self.assertIn("private var requestGeneration = 0", controller)
        self.assertIn("let requestGeneration = beginRequest()", controller)
        self.assertIn("defer { self.finishRequest(generation: requestGeneration) }", controller)
        self.assertIn("if !self.isCurrentRequest(requestGeneration) { return }", controller)
        self.assertIn("private func beginRequest() -> Int", controller)
        self.assertIn("private func finishRequest(generation: Int)", controller)

    def test_manga_ai_toolbar_clamps_inside_frame_without_viewport_nudge(self):
        html = read("Features/MangaReader/MangaPageHtml.swift")
        place_actions = method_body(html, "placeActions: function")

        self.assertIn("var frame = box.closest('.frame');", place_actions)
        self.assertIn("var actions = frame && frame.querySelector('.ocr-actions');", place_actions)
        self.assertIn("actions.classList.add('is-visible');", place_actions)
        self.assertIn("actions.dataset.bubbleText", place_actions)
        self.assertIn("uiTestSuffix", place_actions)
        self.assertIn("Ask about this bubble' + uiTestSuffix", place_actions)
        self.assertIn("Copy bubble text' + uiTestSuffix", place_actions)
        self.assertIn("var left = box.offsetLeft + (boxWidth / 2) - (actionsWidth / 2);", place_actions)
        self.assertIn("box.closest('.frame')", place_actions)
        self.assertIn("var minLeft = gap;", place_actions)
        self.assertIn("var maxLeft = frame.clientWidth - actionsWidth - gap;", place_actions)
        self.assertIn("var minGlobalTop = gap;", place_actions)
        self.assertIn("var minTop = minGlobalTop;", place_actions)
        self.assertIn("var maxTop = frame.clientHeight - actionsHeight - gap;", place_actions)
        self.assertIn("minGlobalTop = Math.max(minGlobalTop, hostMinTop + gap);", place_actions)
        self.assertIn("hostTappableTopInset", html)
        self.assertIn(".ocr-box::before", html)
        self.assertIn("inset: -20px;", html)
        self.assertIn("hitSlopBoxAt: function(x, y)", html)
        self.assertIn("document.querySelectorAll('.ocr-box')", html)
        self.assertIn("window.hoshiManga.hitSlopBoxAt(x, y)", html)
        self.assertIn("window.hoshiManga.clearRevealed();", html)
        self.assertGreaterEqual(html.count("window.hoshiManga.clearRevealed();"), 4)
        self.assertIn("} else {\n              window.hoshiManga.placeActions(box);", html)
        self.assertIn("renderedBoxRect: function(box)", html)
        self.assertIn("var renderedTop = box.offsetTop;", place_actions)
        self.assertIn("var renderedBottom = box.offsetTop + boxHeight;", place_actions)
        self.assertIn("var renderedRect = window.hoshiManga.renderedBoxRect(box);", place_actions)
        self.assertIn("renderedTextRects: function(box)", html)
        self.assertIn("hideActions: function(actions)", html)
        self.assertIn("var avoidGap = Math.max(gap + 10, Math.ceil(actionsHeight * 0.55));", place_actions)
        self.assertIn("var aboveTop = renderedTop - actionsHeight - avoidGap;", place_actions)
        self.assertIn("var actionsWidth = actions.offsetWidth || 56;", place_actions)
        self.assertIn("var actionsHeight = actions.offsetHeight || 26;", place_actions)
        self.assertIn("var belowClearance = Math.max(gap + 10, Math.ceil(actionsHeight * 0.65));", place_actions)
        self.assertIn("boxFontSize", place_actions)
        self.assertIn("var belowTop = renderedBottom + Math.max(belowClearance, avoidGap);", place_actions)
        self.assertIn("function overlapArea(leftValue, topValue)", place_actions)
        self.assertIn("var avoidRects = [];", place_actions)
        self.assertIn("window.hoshiManga.renderedTextRects(box)", place_actions)
        self.assertIn("var candidates = [", place_actions)
        self.assertIn("makeCandidate('above', left, aboveTop)", place_actions)
        self.assertIn("makeCandidate('below', left, belowTop)", place_actions)
        self.assertIn("var selected = null;", place_actions)
        self.assertIn("window.hoshiManga.hideActions(actions);", place_actions)
        self.assertIn("actions.dataset.placement = selected.name;", place_actions)
        self.assertIn("width: 26px;", html)
        self.assertIn("height: 26px;", html)
        self.assertIn("frameTop + top < minGlobalTop", place_actions)
        self.assertIn("z-index: 30;", html)
        self.assertIn("touch-action: manipulation;", html)
        self.assertIn("left = Math.max(minLeft, Math.min(left, maxLeft));", place_actions)
        self.assertIn("top = clampTop(top);", place_actions)
        self.assertNotIn("document.documentElement.clientWidth", place_actions)
        self.assertNotIn("window.innerWidth", place_actions)

        if shutil.which("node") is None:
            self.skipTest("node is required to execute the toolbar geometry regression")
        js = textwrap.dedent(f"""
            const placeActions = function(box) {{
            {place_actions}
            }};

            function run(frameWidth, offsetLeft, boxWidth, boxHeight, offsetTop, frameHeight = 300, topInset = 0, textOverflow = 0) {{
              const actions = {{
                offsetWidth: 56,
                offsetHeight: 26,
                style: {{}},
                dataset: {{}},
                visible: false,
                classList: {{
                  add: (name) => {{ if (name === 'is-visible') actions.visible = true; }},
                  remove: (name) => {{ if (name === 'is-visible') actions.visible = false; }},
                }},
                setAttribute: () => {{}},
                querySelector: () => null,
              }};
              const frame = {{
                clientWidth: frameWidth,
                clientHeight: frameHeight,
                offsetTop: 0,
                getBoundingClientRect: () => ({{
                  left: 0,
                  top: 0,
                  right: frameWidth,
                  bottom: frameHeight,
                  width: frameWidth,
                  height: frameHeight,
                }}),
                querySelector: (selector) => selector === '.ocr-actions' ? actions : null,
              }};
              global.window = {{
                hoshiManga: {{
                  hostOffsetTop: () => 0,
                  hostTappableTopInset: () => topInset,
                  hostScale: () => 1,
                  renderedBoxRect: (box) => {{
                    const rect = box.getBoundingClientRect();
                    const textRect = box.querySelector('p').getBoundingClientRect();
                    const left = Math.min(rect.left, textRect.left);
                    const top = Math.min(rect.top, textRect.top);
                    const right = Math.max(rect.right, textRect.right);
                    const bottom = Math.max(rect.bottom, textRect.bottom);
                    return {{
                      left,
                      top,
                      right,
                      bottom,
                      width: right - left,
                      height: bottom - top,
                    }};
                  }},
                  renderedTextRects: (box) => [box.querySelector('p').getBoundingClientRect()],
                  hideActions: (actions) => {{
                    actions.visible = false;
                    actions.dataset.placement = 'hidden';
                    actions.style.left = '-9999px';
                    actions.style.top = '-9999px';
                  }},
                }},
                getComputedStyle: () => ({{ fontSize: '20px' }}),
              }};
              const text = {{
                textContent: 'probe',
                getBoundingClientRect: () => ({{
                  left: offsetLeft,
                  top: offsetTop,
                  right: offsetLeft + boxWidth,
                  bottom: offsetTop + boxHeight + textOverflow,
                  width: boxWidth,
                  height: boxHeight + textOverflow,
                }}),
              }};
              const box = {{
                clientWidth: boxWidth,
                clientHeight: boxHeight,
                offsetLeft,
                offsetTop,
                classList: {{ contains: (name) => name === 'revealed' }},
                getBoundingClientRect: () => ({{
                  left: offsetLeft,
                  top: offsetTop,
                  right: offsetLeft + boxWidth,
                  bottom: offsetTop + boxHeight,
                  width: boxWidth,
                  height: boxHeight,
                }}),
                querySelector: (selector) => selector === 'p' ? text : null,
                closest: (selector) => selector === '.frame' ? frame : null,
              }};
              placeActions(box);
              return {{
                left: Number.parseInt(actions.style.left, 10),
                top: Number.parseInt(actions.style.top, 10),
                placement: actions.dataset.placement,
                visible: actions.visible,
              }};
            }}

            function assertInsideFrame(name, frameWidth, offsetLeft, boxWidth, expectedLeft) {{
              const result = run(frameWidth, offsetLeft, boxWidth, 20, 80);
              if (result.left !== expectedLeft) {{
                throw new Error(`${{name}} expected left ${{expectedLeft}}, got ${{result.left}}`);
              }}
              const globalLeft = result.left;
              const globalRight = globalLeft + 56;
              if (globalLeft < 4 || globalRight > frameWidth - 4) {{
                throw new Error(
                  `${{name}} escaped frame: [${{globalLeft}}, ${{globalRight}}] in ${{frameWidth}}px frame`
                );
              }}
            }}

            assertInsideFrame('rightEdge', 300, 298, 1, 240);
            assertInsideFrame('beyondRight', 300, 299, 1, 240);
            const leftEdge = run(300, 0, 10, 20, 80);
            if (leftEdge.left !== 4) {{
              throw new Error(`left-edge clamp expected 4, got ${{leftEdge.left}}`);
            }}
            const normal = run(300, 120, 80, 20, 80);
            if (normal.left !== 132) {{
              throw new Error(`normal bubble expected 132, got ${{normal.left}}`);
            }}
            const topEdge = run(300, 120, 80, 20, 10);
            if (topEdge.left !== 49 || topEdge.top !== 7 || topEdge.placement !== 'left') {{
              throw new Error(`top-edge fallback expected side placement at 49,7,left, got ${{topEdge.left}},${{topEdge.top}},${{topEdge.placement}}`);
            }}
            const overflowedText = run(300, 120, 80, 20, 10, 300, 0, 60);
            if (overflowedText.left !== 49 || overflowedText.top !== 37 || overflowedText.placement !== 'left') {{
              throw new Error(`overflowed text expected side placement at 49,37,left, got ${{overflowedText.left}},${{overflowedText.top}},${{overflowedText.placement}}`);
            }}
            const impossible = run(120, 0, 120, 260, 20, 300);
            if (impossible.visible || impossible.placement !== 'hidden') {{
              throw new Error(`impossible placement should hide toolbar, got visible=${{impossible.visible}} placement=${{impossible.placement}}`);
            }}
            const veryTop = run(300, 120, 80, 20, 0, 300);
            const globalTop = 0 + veryTop.top;
            const globalBottom = globalTop + 26;
            if (globalTop < 4 || globalBottom > 296) {{
              throw new Error(`top-edge toolbar escaped tappable frame: [${{globalTop}}, ${{globalBottom}}]`);
            }}
            const underChrome = run(300, 120, 80, 20, 0, 300, 72);
            if (underChrome.top < 76) {{
              throw new Error(`top chrome inset expected toolbar below 76px, got ${{underChrome.top}}`);
            }}
            const underStackedChrome = run(300, 120, 80, 20, 0, 300, 140);
            if (underStackedChrome.top < 144) {{
              throw new Error(`stacked top chrome inset expected toolbar below 144px, got ${{underStackedChrome.top}}`);
            }}
        """)
        subprocess.run(["node", "-e", js], check=True, capture_output=True, text=True)

    def test_manga_popup_and_crop_mapping_accounts_for_native_zoom_pan(self):
        view = read("Features/MangaReader/MangaReaderView.swift")
        webview = read("Features/MangaReader/MangaReaderWebView.swift")
        html = read("Features/MangaReader/MangaPageHtml.swift")
        selection = read("Features/Reader/ReaderWebView/selection.js")

        self.assertIn("syncHostViewport", webview)
        self.assertIn("contentOffset.x.isFinite", webview)
        self.assertIn("setHostViewport", webview)
        self.assertIn("setHostViewport(\\(Double(scale)), \\(Double(offsetX)), \\(Double(offsetY)), \\(Double(topInset)))", webview)
        self.assertNotIn("setHostViewport(\\(Double(scale)), \\(Double(offsetX)), \\(Double(offsetY))))", webview)
        self.assertIn("tappableTopInset: mangaActionTopInset(for: geometry)", view)
        self.assertIn("private func mangaActionTopInset(for geometry: GeometryProxy)", view)
        self.assertIn("AiChatSettingsStore.shared.isConfigured ? 140 : 72", view)
        self.assertIn("private static func configureZoom(for scrollView: UIScrollView)", webview)
        self.assertIn("scrollView.pinchGestureRecognizer?.isEnabled = true", webview)
        self.assertIn("scrollView.panGestureRecognizer.allowedScrollTypesMask = .all", webview)
        self.assertIn("observeNativePinch", webview)
        self.assertIn("observeNativePan", webview)
        self.assertNotIn("let pinch = UIPinchGestureRecognizer", webview)
        self.assertNotIn("let trackpadPan = UIPanGestureRecognizer", webview)
        self.assertIn("let trackpadPageTurn = UIPanGestureRecognizer", webview)
        self.assertIn("trackpadPageTurn.allowedScrollTypesMask = .continuous", webview)
        self.assertIn("trackpadPageTurn.allowedTouchTypes = []", webview)
        page_turn = method_body(webview, "@objc func handleTrackpadPageTurn")
        self.assertIn("gesture.state == .ended", page_turn)
        self.assertIn("commitTrackpadPageTurn(translation: translation)", page_turn)
        native_pan = method_body(webview, "@objc func observeNativePan")
        self.assertNotIn("setContentOffset", native_pan)
        self.assertNotIn("commitTrackpadPageTurn", native_pan)
        should_begin = method_body(webview, "func gestureRecognizerShouldBegin")
        self.assertIn("gestureRecognizer === trackpadPageTurnRecognizer", should_begin)
        self.assertIn("!pinchIsActive && !viewportNeedsPan(scrollView)", should_begin)
        self.assertIn("handlePinch", webview)
        self.assertIn("gesture.numberOfTouches == 0", webview)
        self.assertIn("rawLocation.x - scrollView.bounds.minX", webview)
        self.assertIn("setCurrentAnchor(currentLocation)", webview)
        self.assertIn("previousPinchLocation", webview)
        self.assertIn("MangaIndirectPinchTransform", webview)
        self.assertIn("claimPendingTrackpadTranslation", webview)
        self.assertIn("session.appliedTranslation = session.totalTranslation", webview)
        self.assertIn("MangaViewportGestureMath.zoomOffset", webview)
        self.assertIn("MangaViewportGestureMath.panOffset", webview)
        self.assertIn("session.usedForViewport = true", webview)
        self.assertIn("gesture.scale = 1", webview)
        self.assertNotIn("scrollView.panGestureRecognizer.translation", webview)
        self.assertNotIn("addEventListener('wheel'", html)
        self.assertNotIn("event: 'wheel'", html)
        project = read("Hoshi Reader.xcodeproj/project.pbxproj")
        self.assertEqual(project.count("INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;"), 2)
        self.assertIn("scrollView.setZoomScale(newScale, animated: false)", webview)
        self.assertIn("MangaReaderWebView.configureZoom(for: webView.scrollView)", webview)
        self.assertIn("hostOffsetLeftValue", html)
        self.assertIn("x: x * scale,", html)
        self.assertIn("y: y * scale,", html)
        self.assertNotIn("x: x * scale - this.hostOffsetLeft()", html)
        self.assertNotIn("y: y * scale - this.hostOffsetTop()", html)
        self.assertIn("function hostX(x) { return x / scale; }", html)
        self.assertIn("function hostY(y) { return y / scale; }", html)
        self.assertNotIn("function hostX(x) { return (x + window.hoshiManga.hostOffsetLeft()) / scale; }", html)
        self.assertIn("isHostZoomedOrPanned", html)
        self.assertNotIn("visualViewport.offsetLeft", html)
        self.assertIn("getPointSelectionRect", selection)
        self.assertIn("window.hoshiManga?.isHostZoomedOrPanned?.() && pointRect", selection)
        self.assertIn("getMangaBoxAtPoint(x, y)", selection)
        self.assertIn("getCharacterInContainerAtPoint(container, x, y)", selection)
        self.assertIn("const mangaHit = this.getCharacterInContainerAtPoint(mangaBox, x, y);", selection)
        self.assertIn("window.hoshiManga?.hitSlopBoxAt?.(x, y)", selection)
        self.assertIn("rectDistance(rect, x, y)", selection)

    def test_zoom_ui_test_asserts_selection_probe_not_only_screenshot(self):
        view = read("Features/MangaReader/MangaReaderView.swift")
        ui_test = read("UITests/ZoomPopupUITests.swift")
        html = read("Features/MangaReader/MangaPageHtml.swift")
        webview = read("Features/MangaReader/MangaReaderWebView.swift")

        self.assertIn("HOSHI_UI_TESTING", view)
        self.assertIn("manga-selection-probe", view)
        self.assertIn("manga-crop-probe", view)
        self.assertIn("manga-action-layout-probe", view)
        self.assertIn("uiTestActionProbe", view)
        self.assertIn("uiTestProbeLabel(for: selection)", view)
        self.assertIn("uiTestCropProbeLabel(crop: crop, image: image)", view)
        self.assertIn("uiTestActionLayoutProbeLabel", webview)
        self.assertIn("manga-options-menu", view)
        self.assertIn("controller.uiTestViewportProbeLabel()", view)
        self.assertIn("app.launchEnvironment[\"HOSHI_UI_TESTING\"] = \"1\"", ui_test)
        self.assertIn("parseSelectionProbe", ui_test)
        self.assertIn("parseCropProbe", ui_test)
        self.assertIn("let allowedDistance = max(", ui_test)
        self.assertIn("XCTAssertLessThan(distance", ui_test)
        self.assertIn("testScreenshotCropProducesPngAfterZoomedPan", ui_test)
        self.assertIn("webView.coordinate(withNormalizedOffset: CGVector(dx: 0.28, dy: 0.28))", ui_test)
        self.assertNotIn("CGVector(dx: 760, dy: 840)", ui_test)
        self.assertIn("XCTAssertEqual(crop.page, 0", ui_test)
        self.assertIn("XCTAssertLessThanOrEqual(crop.left + crop.width, 1179", ui_test)
        self.assertIn("XCTAssertTrue(abs(crop.offsetX) > 1 || abs(crop.offsetY) > 1", ui_test)
        self.assertIn("testUltraThinActionButtonsStayVisibleAndTappable", ui_test)
        self.assertIn("parseActionProbe", ui_test)
        self.assertIn("UI_THIN_RIGHT", ui_test)
        self.assertIn("UI_THIN_TOP_RIGHT", ui_test)
        self.assertIn("testLowerRevealedMangaTextCanBeSelected", ui_test)
        self.assertIn("下段選択", ui_test)
        self.assertIn("lowerProbe.textRect.y + lowerProbe.textRect.height * 0.75", ui_test)
        self.assertIn('expected: "copy=UI_THIN_TOP_RIGHT"', ui_test)
        self.assertIn("hitSlopPoint(for: boxFrame, in: webView.frame)", ui_test)
        self.assertIn("probe?.box.screenRect(in: webView.frame) ?? box.frame", ui_test)
        self.assertIn('let actionRect = accessibilityLabel.contains("Copy") ? probe.copy : probe.ai', ui_test)
        self.assertIn("let actionFrame = actionRect.screenRect(in: webView.frame)", ui_test)
        self.assertIn("let actionPoint = CGPoint(x: actionFrame.midX, y: actionFrame.midY)", ui_test)
        self.assertIn("func actionProbe(_ probes: [ActionProbe], containing text: String)", ui_test)
        self.assertIn("boxFrame.width < 8", ui_test)
        self.assertIn("horizontalNudge = boxFrame.midX > webViewFrame.midX ? -6 : 6", ui_test)
        self.assertIn("label CONTAINS %@ AND label CONTAINS %@", ui_test)
        self.assertIn("Copy bubble text", ui_test)
        self.assertIn("manga-copy-probe", view)
        self.assertIn("uiTestCopyProbe = \"copy=\\(text)\"", view)
        self.assertIn("waitForCopyProbe", ui_test)
        self.assertIn("data-hoshi-ui-test", html)
        self.assertIn('top: max(0, h / 8)', html)
        self.assertIn('"wide-top-overflow"', html)
        self.assertIn("下段広い選択", html)
        self.assertIn("actionLayoutProbe", html)
        self.assertIn("var actions = frame && frame.querySelector('.ocr-actions')", html)
        self.assertIn("actions.dataset.bubbleText", html)
        self.assertIn("document.addEventListener('touchend'", html)
        self.assertIn("lastHandledTouchAt", html)
        self.assertIn("distance > 14 || elapsed > 900", html)
        self.assertIn("hitSlopBoxAt", html)
        self.assertIn("return this.revealedBoxAt(x, y, 12) ||", html)
        self.assertIn("window.hoshiManga.revealedBoxAt(x, y) ||\n            window.hoshiManga.hitSlopBoxAt(x, y) ||\n            directBox", html)
        self.assertIn("revealedBoxAt: function(x, y, slop)", html)
        self.assertIn("boxFromHitSlop: function(boxes, x, y, fixedSlop)", html)
        self.assertIn('"lower-select"', html)
        self.assertIn('lines: ["上段", "下段選択"]', html)
        self.assertIn("textRect: textRect", html)
        self.assertIn("box: boxRect", html)
        self.assertIn("if (rect.width < 10 || rect.height < 10)", html)
        self.assertIn("slop = Math.max(slop, 20);", html)
        self.assertIn("var textRect = hostRect(window.hoshiManga.renderedBoxRect(box));", html)
        self.assertIn("placement: actions && actions.dataset", html)
        self.assertIn("unionBottom", html)
        self.assertIn("assertDoesNotOverlap", ui_test)
        self.assertIn("let renderedRects = probe.textRects.isEmpty ? [probe.textRect] : probe.textRects", ui_test)
        self.assertNotIn("assertDoesNotOverlap(probe.ai, probe.textRect", ui_test)
        self.assertNotIn("assertDoesNotOverlap(probe.copy, probe.textRect", ui_test)
        self.assertIn('let placement: String', ui_test)
        self.assertIn('let box: ActionRect', ui_test)
        self.assertIn("func screenRect(in webViewFrame: CGRect) -> CGRect", ui_test)
        self.assertIn('probe.placement == "below"', ui_test)
        self.assertIn("ProbeError(\"Requires IDB Zoom Fixture seeded into the app container.\")", ui_test)
        self.assertNotIn(".ocr-box.revealed .ocr-actions", html)
        self.assertNotIn("word-break: break-all", html)
        self.assertNotIn("overflow-wrap: anywhere", html)

    def test_manga_ai_ui_test_stub_covers_second_tap_path(self):
        controller = read("Features/AI/MangaAiController.swift")
        view = read("Features/MangaReader/MangaReaderView.swift")
        popup = read("Features/AI/MangaAiPopupView.swift")
        ui_test = read("UITests/ZoomPopupUITests.swift")

        self.assertIn("func resolveForUITest(bubbleText: String, book: BookMetadata)", controller)
        hook_start = controller.index("func resolveForUITest(bubbleText: String, book: BookMetadata)")
        hook_end = controller.index("func translateCrop")
        self.assertIn("#if DEBUG", controller[max(0, hook_start - 240):hook_start])
        self.assertIn("#endif", controller[hook_start:hook_end])
        self.assertIn("HOSHI_UI_TESTING_AI_STUB", controller)
        self.assertIn('let marker = trimmed.contains("二回目") ? "UI2OK" : "UI1OK"', controller)
        self.assertIn("\\(marker) UITESTOK **bold** for \\(trimmed)", controller)
        self.assertIn("| Term | Meaning |", controller)
        self.assertIn("| test | Japanese |", controller)
        self.assertIn("uiTestingAiStubEnabled", view)
        stub_body = method_body(view, "private var uiTestingAiStubEnabled")
        self.assertIn("#if DEBUG", stub_body)
        self.assertIn("#else", stub_body)
        self.assertIn("false", stub_body)
        stub_call = view[view.index("} else if uiTestingAiStubEnabled"):view.index("} else {", view.index("} else if uiTestingAiStubEnabled"))]
        self.assertIn("#if DEBUG", stub_call)
        self.assertIn("#else", stub_call)
        self.assertIn("aiController.ask(bubbleText: text, blockId: blockId, book: metadata)", stub_call)
        self.assertIn("aiController.resolveForUITest(bubbleText: text, book: metadata)", view)
        self.assertIn('accessibilityLabel("Close translation")', popup)
        self.assertIn("testNearTopAiButtonRespondsAndSecondTapDoesNotCrash", ui_test)
        self.assertIn('app.launchEnvironment["HOSHI_UI_TESTING_AI_STUB"] = "1"', ui_test)
        self.assertIn('app.buttons["Ask about this bubble"]', ui_test)
        self.assertIn('"UI1OK"', ui_test)
        self.assertIn('"UI2OK"', ui_test)
        self.assertIn('"**bold**"', ui_test)
        self.assertIn('"Meaning"', ui_test)
        self.assertIn('"Japanese"', ui_test)
        self.assertIn("XCTAssertEqual(app.state, .runningForeground)", ui_test)

    def test_offline_settings_expose_private_thinking_toggle(self):
        store = read("Features/AI/offline/OfflineTranslationSettingsStore.swift")
        view = read("Features/AI/offline/OfflineTranslationSettingsView.swift")
        self.assertIn("var usePrivateThinking: Bool", store)
        self.assertIn("Keys.usePrivateThinking", store)
        self.assertIn("offlineTranslation.usePrivateThinking", store)
        self.assertIn("defaults.object(forKey: Keys.usePrivateThinking) as? Bool ?? true", store)
        self.assertIn("static let responseTokenLimitOptions", store)
        self.assertIn("10000", store)
        self.assertIn("static let defaultResponseTokenLimit = 10000", store)
        self.assertIn("var responseTokenLimit: Int", store)
        self.assertIn("clampedResponseTokenLimit", store)
        self.assertIn("responseTokenLimitOptions.min", store)
        self.assertIn("abs(lhs - bounded) < abs(rhs - bounded)", store)
        self.assertIn("offlineTranslation.responseTokenLimit", store)
        self.assertIn('Toggle("Use private thinking"', view)
        self.assertNotIn("responseTokenLimit = Self.clampedResponseTokenLimit(responseTokenLimit)", store)
        self.assertIn("let responseTokenLimit = Binding<Int>", view)
        self.assertIn("OfflineTranslationSettingsStore\n                    .clampedResponseTokenLimit($0)", view)
        self.assertIn('Picker("Answer token limit"', view)
        self.assertIn("selection: responseTokenLimit", view)
        self.assertIn("responseTokenLimitOptions", view)
        self.assertIn(".disabled(!settings.useOnDeviceTranslation)", view)

    def test_ipad_dictionary_popup_gets_taller_floor(self):
        popup = read("Features/Popup/PopupView.swift")
        self.assertIn("preferTallPopup", popup)
        self.assertIn("UIDevice.current.userInterfaceIdiom == .pad", popup)
        self.assertIn("screenSize.height * 0.32", popup)
        self.assertIn("screenSize.height * 0.42", popup)
        self.assertIn("return max(1, min(max(spaceAbove, spaceBelow) - screenBorderPadding, cappedMaxHeight))", popup)

    def test_manga_ocr_reveal_font_size_overrides_drawn_size(self):
        html = read("Features/MangaReader/MangaPageHtml.swift")
        self.assertIn("font-size: var(--hoshi-drawn-fs);", html)
        self.assertIn("font-size: var(--hoshi-reveal-fs);", html)
        self.assertIn("--hoshi-drawn-fs:", html)
        self.assertNotIn("height: \\(heightPct)%; font-size:", html)
        self.assertIn("delete revealed[i].dataset.wrapTried;", html)

    def test_manga_reader_is_full_bleed_with_overlay_chrome(self):
        # The reserved chrome bands were deliberately removed (June 2026, user request): the
        # page is always full-bleed and the top/bottom chrome floats above it, Android-style.
        # Toggling focus mode must change bar visibility only — never relayout the page.
        view = read("Features/MangaReader/MangaReaderView.swift")
        self.assertNotIn("topChromeHeight", view)
        self.assertNotIn("bottomChromeHeight", view)
        self.assertIn(".ignoresSafeArea()", view)
        self.assertIn(".toolbar(.hidden, for: .navigationBar)", view)
        self.assertIn(".statusBarHidden(true)", view)
        self.assertIn(".persistentSystemOverlays(.hidden)", view)
        self.assertNotIn(".statusBarHidden(focusMode)", view)
        # The full-width strips must not swallow page taps: focus toggle on the capsule only,
        # exit via empty-art tap.
        self.assertIn(".allowsHitTesting(!focusMode)", view)

    def test_manga_reader_menu_button_hugs_top_right(self):
        view = read("Features/MangaReader/MangaReaderView.swift")
        top_bar = method_body(view, "private var topBar")
        self.assertIn(".padding(.horizontal, 6)", top_bar)
        self.assertNotIn("Text(title)", top_bar)

    def test_manga_scan_non_japanese_toggle_is_used_by_selection_script(self):
        selection = read("Features/Reader/ReaderWebView/selection.js")
        self.assertIn("scanNonJapaneseText", selection)
        self.assertIn("isJapaneseText", selection)
        self.assertIn("window.scanNonJapaneseText === false", selection)

    def test_manga_action_buttons_can_be_disabled_in_settings(self):
        config = read("Core/UserConfig.swift")
        settings = read("Features/MangaReader/MangaReaderSettingsView.swift")
        cache = read("Features/MangaReader/MangaPageRenderCache.swift")
        view_model = read("Features/MangaReader/MangaReaderViewModel.swift")
        html = read("Features/MangaReader/MangaPageHtml.swift")

        self.assertIn("var mangaShowActionButtons: Bool", config)
        self.assertIn('"mangaShowActionButtons"', config)
        self.assertIn("?? true", config[config.index("self.mangaShowActionButtons"):])
        self.assertIn('Toggle("Show Copy / AI buttons"', settings)
        self.assertIn("$userConfig.mangaShowActionButtons", settings)
        self.assertIn("let showActionButtons: Bool", cache)
        self.assertIn("showActionButtons: config.showActionButtons", cache)
        self.assertIn("showActionButtons: userConfig.mangaShowActionButtons", view_model)
        self.assertIn("showActionButtons: Bool = true", html)
        self.assertIn("let actionButtons = showActionButtons ? actionButtonsHtml : \"\"", html)
        self.assertIn("\\(actionButtons)", html)

    def test_docs_do_not_reference_removed_eink_mode(self):
        docs = read("docs/IOS_MOKURO_TESTING.md")
        self.assertNotIn("e-ink mode", docs.lower())

    def test_llm_package_is_linked_into_app_frameworks(self):
        project = read("Hoshi Reader.xcodeproj/project.pbxproj")
        frameworks_section = project[
            project.index("/* Frameworks */ = {"):
            project.index("/* Resources */ = {")
        ]
        self.assertIn("LLM in Frameworks", frameworks_section)

    def test_llm_runtime_does_not_emit_seed_debug_prints(self):
        llm = read("Libraries/LLM.swift/Sources/LLM/LLM.swift")
        self.assertIn("LLM.silenceLogging()", llm)
        self.assertNotIn("GNERATING WITH SEEED", llm)
        self.assertNotRegex(llm, r'print\(".*seed')

    def test_backup_restore_never_deletes_live_directory_before_successful_swap(self):
        backup = read("Features/Settings/BackupView.swift")
        restore = method_body(backup, "private func restoreFolder")
        self.assertIn("moveExistingDestinationAside", backup)
        self.assertIn("restoreMovedDestination", backup)
        self.assertNotIn("try? fm.removeItem(at: destination)", restore)
        self.assertNotIn("try? fm.moveItem(at: staging, to: destination)", restore)


if __name__ == "__main__":
    unittest.main()
