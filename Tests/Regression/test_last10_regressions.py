import re
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
        self.assertIn("pushBookmark(config: config, syncId: bookSyncId", manager)
        self.assertNotIn("pushBookmark(config: config, title:", manager)

    def test_offline_translation_fails_closed_without_downloaded_model(self):
        controller = read("Features/AI/MangaAiController.swift")
        ask_prefix = controller[
            controller.index("func ask(bubbleText: String, book: BookMetadata)"):
            controller.index("let apiKey = settings.apiKey")
        ]
        self.assertIn("if offlineSettings.useOnDeviceTranslation {", ask_prefix)
        self.assertIn("guard !offlineDownloads.downloadedModelIds().isEmpty else", ask_prefix)

    def test_offline_history_records_actual_model_id(self):
        controller = read("Features/AI/MangaAiController.swift")
        self.assertIn("model: result.modelId", controller)
        self.assertNotIn("model: model.id", method_body(controller, "private func askOnDevice"))

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

    def test_top_chrome_reserves_actual_button_height(self):
        view = read("Features/MangaReader/MangaReaderView.swift")
        match = re.search(
            r"private var topChromeHeight: CGFloat \{\s*"
            r"\(focusMode \|\| screenshotCropMode\) \? 0 : (?P<height>\d+)",
            view,
            re.S,
        )
        self.assertIsNotNone(match)
        self.assertGreaterEqual(int(match.group("height")), 72)

    def test_manga_scan_non_japanese_toggle_is_used_by_selection_script(self):
        selection = read("Features/Reader/ReaderWebView/selection.js")
        self.assertIn("scanNonJapaneseText", selection)
        self.assertIn("isJapaneseText", selection)
        self.assertIn("window.scanNonJapaneseText === false", selection)

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

    def test_backup_restore_never_deletes_live_directory_before_successful_swap(self):
        backup = read("Features/Settings/BackupView.swift")
        restore = method_body(backup, "private func restoreFolder")
        self.assertIn("moveExistingDestinationAside", backup)
        self.assertIn("restoreMovedDestination", backup)
        self.assertNotIn("try? fm.removeItem(at: destination)", restore)
        self.assertNotIn("try? fm.moveItem(at: staging, to: destination)", restore)


if __name__ == "__main__":
    unittest.main()
