# iOS Mokuro Manga Reader — Port Plan (v2, post-review)

Transform **Hoshi Reader (iOS)** from an EPUB reader into a **mokuro manga reader** matching the
Android fork (`/Users/dragosristache/Hoshi-Reader-Android`), with **ChatGPT/LLM** and **HTTP KV
sync** as headline features. This v2 incorporates the architecture review (merged renderer+UX,
hardened contracts, added plumbing).

## Guiding architectural decisions

1. **Reuse Android's WebView renderer — adapted, not byte-for-byte.** Android renders each page as
   generated HTML/CSS/JS (`MangaPageHtml.kt`) inside a WebView. iOS already renders EPUB in `WKWebView`
   with a JS↔native bridge. We port the HTML/CSS/JS but must adapt: custom URL scheme instead of
   `https://hoshi.local`, and `webkit.messageHandlers.*` instead of Android `window.HoshiX` objects.
   Vertical Japanese (縦書き) is free via WebKit CSS.
2. **Clean new manga WebView — do NOT fork `ReaderWebView.swift`.** That file (773 lines) is
   EPUB-pagination-specific. Build a fresh `MangaReaderWebView` and reuse ONLY the bundled
   `selection.js` (its `findParagraph` scopes to `<p>`, exactly the OCR box design) + the existing
   `SelectionData {text, sentence, rect, normalizedOffset}` contract + the lookup popup.
3. **Keep the learning stack untouched.** Dictionary engine (`hoshidicts`), lookup popup, Anki mining,
   word audio already exist on iOS, decoupled from the reader. Manga posts the same `textSelected`
   message the popup already consumes.
4. **Additive, not destructive.** Add manga as a parallel `ContentType` routed in `ReaderLoader`
   (book dir containing `mokuro.json` ⇒ manga). EPUB code stays inert; library is manga-first, EPUB
   import entry hidden.
5. **Contracts first (real code + ported tests), then fan-out in worktrees.** Phase 0 lands a tree
   that compiles AND links green, with the cross-agent pure cores already implemented and unit-tested.
   Each Phase 1 agent works in its own git worktree and must build before merge.

## Source-of-truth files

- Android rendering/tap: `features/mangareader/{MangaPageHtml,MangaReaderScreen,MangaWebResourceBridge,MangaReaderWebView,MangaPageNavigation,MangaScreenshotCrop}.kt`
- Android format: `mokuro/{MokuroBook,MokuroBookParser,MokuroImporter}.kt`, `docs/MOKURO_ZIP_FORMAT.md`
- Android LLM: `features/ai/{OpenAiChatClient,AiChatSettings,AiChatHistory,AiChatHistoryStore}.kt`
- Android sync: `features/sync/http/{HttpSyncKv,HttpSyncBlobs,HttpSyncSettings,HttpSyncReconciler,HttpSyncPusher}.kt`, `docs/{HTTP_SYNC_KV,SYNC_V3_SPEC}.md`
- iOS reuse: `Features/Reader/ReaderWebView/ReaderWebView.swift` (reference only), `Core/{BookStorage,UserConfig,LookupEngine,LocalFileServer}.swift`, `Models/Book.swift`, `Features/Popup/PopupView.swift`, `Features/Bookshelf/*`, `selection.js`

---

## Phase 0 — Contracts skeleton: REAL code + ported tests, must build+link green

Not stubs for the cross-agent cores. The tree must `xcodebuild` clean before Phase 1.

### Shared types (exact fields, pinned JSON names)
- `Models/Mokuro/MokuroBook.swift`
  - `MokuroTextBox { left, top, width, height: Int; fontSize: Int; vertical: Bool; lines: [String] }`
  - `MokuroPage { index: Int; imagePath: String; imageWidth, imageHeight: Int; textBoxes: [MokuroTextBox] }`
  - `MokuroBook { title: String; pages: [MokuroPage]; coverImagePath: String? }`
  - `RawMokuro*` Codable mirrors of on-disk JSON (`img_path`, `img_width`, `img_height`, `font_size`,
    `box: [Double]`, `vertical`, `lines`; `volume`/`title` fallback; `ignoreUnknownKeys` behavior).
- `Models/Ai/AiChatTypes.swift` — full graph matching Android `AiChatHistory.kt`:
  - `AiChatImage { mimeType, base64Data }`
  - `AiChatDeinflectionStep`, `AiChatGlossary`, `AiChatFrequency`/`AiChatFrequencyGroup`, `AiChatPitchGroup`,
    `AiChatDictionaryLookupResult { expression, reading, matched, deinflectionTrace, glossaries, frequencies, pitches, rules }`,
    `AiChatDictionaryLookup { query, results }`
  - `AiChatEntry { bubbleText, prompt, model, response, timestampSeconds: Double, screenshotImage: AiChatImage?, dictionaryLookup: AiChatDictionaryLookup?, debugInfo: String? }`
  - `AiChatLog { entries: [AiChatEntry] }`
- `Models/Sync/SyncBlobs.swift` — pinned JSON field names from `HttpSyncBlobs.kt`:
  - `HttpSyncMetadataBlob { title, contentType ("epub"|"mokuro"), shelfName?, shelfUpdatedAt?, importedAt?, deletedAt? }` (RFC3339 strings)
  - `HttpSyncBookmarkBlob { chapterIndex: Int, progress: Double, characterCount: Int, lastModified: String }`
  - `HttpSyncChatEntryBlob { bubbleText, prompt, model, response, timestampSeconds: Double, screenshotImage?, dictionaryLookup? }`
  - `HttpSyncAiChatSettingsBlob { model, promptText, imagePromptText, lastModified }` at fixed key `app/ai_chat_settings`
  - KV wire records: `HttpSyncKvKeyMeta`, `HttpSyncKvList { keys, truncated, nextCursor }`, `HttpSyncKvWriteResponse`
- `Core/ContentType.swift` — `enum ContentType { case epub, mokuro }` + `detect(bookDir:)` (mokuro.json present ⇒ mokuro).

### Real, unit-tested pure cores (ported from Android, with the Android tests)
- `clampMokuroFontSize(_:)` — target 30px, strength 0.5 (`MokuroBookParser.kt`).
- `RawMokuro* → MokuroTextBox/Page/Book` mapping (box→l/t/w/h, drop malformed, title/volume fallback).
- `SyncIds.deriveSyncId(_ title:)` — exact algorithm: trim; if empty→nil; lowercase + non-`[a-z0-9]`→`_`;
  collapse `_+`→`_`; trim `_`; empty→`book_`+hash; len≤64 return; else `prefix.take(64-17).trim('_')||"book" + "_" + hash`.
  `shortTitleHash` = first **8 bytes** of SHA-256(UTF-8 of the *trimmed-but-not-lowercased* title) → 16 hex.
- `chatEntryKeySuffix(appleSeconds:bubbleText:response:)` = `{rfc3339(ms,Z) with ':'→'-'}-{first 4 bytes sha256("bubbleText|response") → 8 hex}`.
- `AppleTime` converters: Apple-reference-seconds (epoch 978307200) ⇄ RFC3339 **millisecond precision, Z suffix**
  (NOT default `ISO8601DateFormatter` which is seconds). `Date.timeIntervalSinceReferenceDate` is already Apple seconds.

### Migrations & plumbing (orchestrator)
- `BookMetadata` (+`Models/Book.swift`): add optional `contentType` and `importedAt` (backfill existing
  books: default `contentType=epub`, `importedAt`=now/mtime). Detection precedence: `mokuro.json` present wins.
- `Core/Keychain.swift` — net-new Keychain wrapper (no `SecItem` code exists today) for the OpenAI key.
- `HoshiReader-Info.plist`: ATS decision (require HTTPS for sync; document or add domain exception if HTTP needed);
  add `.cbz` UTType (`UTImportedTypeDeclarations`) + `CFBundleDocumentTypes` for zip/cbz/folder import.
  Keep custom image scheme distinct from existing `hoshi://` deep link → use `hoshi-img://`.
- Placeholder SwiftUI symbols so dependent agents compile: `AiSettingsView`, `HttpSyncSettingsView`,
  `MangaReaderView`; public signature for `MokuroImporter.import(...)`.

---

## Phase 1 — Parallel agents (git worktree each; must build before merge)

### Agent A — Mokuro parse + import + cover thumbnail
- Implement parser (uses Phase 0 mapping + `clampMokuroFontSize`).
- `MokuroImporter`: `.zip`/`.cbz` (zip-slip guarded, reuse `ZipArchive`) + folder import; locate single
  `.mokuro`; flatten images → `images/`; rewrite `img_path`→`images/<basename>`; write canonical
  `Books/<title>/mokuro.json` + `metadata.json` (`contentType=mokuro`, `importedAt`) + `bookinfo.json`.
- **Cover = downsampled thumbnail of page 1** via `CGImageSource` (not the full image) at the path the
  bookshelf expects. Tests mirror `MokuroBookParserTest.kt`.

### Agent BE — Manga reader (renderer + WebView + paging + zoom + screenshot-crop + page-turn stats)
**Owns all of `Features/MangaReader/`.** (Merged per review — these share one WebView coordinator + one
coordinate system.)
- `MangaPageHtml.swift`: port HTML/CSS/JS; **adapt** base URL→`hoshi-img://`, rewrite every
  `window.HoshiX.method(...)` call site to `webkit.messageHandlers.X.postMessage(...)`, re-point the
  selection wrapper at `textSelected`. Keep `.ocr-box` %/`cqw`, vertical-rl, reveal, action buttons,
  wrap-fallback, crop/host-rect JS.
- `MangaReaderWebView.swift` (`UIViewRepresentable`): register `WKURLSchemeHandler` for `hoshi-img://`
  on the config **before** webview creation; implement `webView(_:stop:)`; serve `images/` off disk with
  path-traversal + allow-list guard. `WKScriptMessageHandler`s: `hoshiManga` (tap/reveal), `hoshiMangaAi`,
  `hoshiMangaClipboard`, reuse `textSelected`→popup. JS `handleTap` owns tap disambiguation (NOT iOS's
  native tap path).
- Paging RTL (right swipe = forward), pinch-zoom via `scrollView`, swipe-gate while zoomed via
  `setHostScale(zoomScale)` + host-rect math fed from `scrollView.zoomScale/contentOffset`.
- Screenshot-crop translate: drag overlay → JS rect→image-pixel map → `CoreGraphics` crop + `CGImageSource`
  downsample → PNG → Agent C `completeImage`.
- Page-turn: **v1 crossfade** (avoid async `WKWebView.takeSnapshot` jank); hook for fancier later.
- "Go to page", focus/immersive chrome, e-ink mode (CSS swap). Emit page-turn events for stats.
- Min iOS target check: container queries (iOS16+), CSS Custom Highlight API (iOS17.2+) — verify target.

### Agent C — ChatGPT/LLM + Keychain + AI history
- `OpenAiChatClient.swift` (`URLSession async/await`): `POST /v1/chat/completions`, Bearer; `{model, messages}`
  (no temp/stream); text + vision (base64 `image_url`); parse `choices[0].message.content`; surface `error.message`.
- AI settings (model, prompt, image prompt) in `UserConfig`; **API key in Keychain (Phase 0 helper), never synced.**
- `AiChatHistoryStore.swift`: per-book `ai_chat_log.json`, atomic temp+rename, schema = Phase 0 `AiChatLog`.
- `AiChatPopupView.swift` + history browser (WebView; tap word → lookup). Cancellable `Task` on dismiss.

### Agent D — HTTP KV sync (new backend; leave Google-Drive/ttu intact)
- `HttpSyncKv.swift`: `PUT/GET/DELETE /v1/kv/{key}`, `GET /v1/kv?prefix&since&cursor&limit`, multipart
  (`/v1/kv-multipart/...`, 64 MiB parts). Bearer; base URL = mount point + `/v1/kv/...`; 404→nil GET;
  204/404 success DELETE; read server `etag`/`lastModified` (server-computed, do not compute).
- `HttpSyncReconciler.swift`: LWW per key (lexicographic RFC3339-Z compare); AI settings Lamport-monotonic
  `max(now, prev+1ms)` + CAS strictly-newer; chat set-union; tombstone `deletedAt` vs `importedAt` strict `>`.
- Payload zip round-trip + manifest. `HttpSyncSettings` UI (base URL + token). Fire-and-forget push hooks
  `onPageTurnPersisted`, `onChatEntryPersisted`.
- **Port Android conformance tests** (HttpSyncTest, payload, V3) as the regression suite.

### Agent F — Library/bookshelf + import UI + settings registration + manga stats UX
- Route `ContentType.mokuro` in `ReaderLoader` → `MangaReaderView`.
- `.fileImporter` accepts `.zip`/`.cbz`/folder (Phase 0 UTTypes) → Agent A importer; hide EPUB import; manga-first.
- `BookCell` progress = page X/Y. Register `AiSettingsView` + `HttpSyncSettingsView` in Settings.
- Manga statistics: reconcile with existing `statistics.json`/`StatisticsView` — page-turns + time
  (decide: extend `Statistics` w/ migration, or separate manga stats file). Stats sheet.

**Merge order:** A → BE → F (dependency chain); C and D independent, merge anytime. Each worktree must
build before merge; integration (Phase 2) is wiring, not bug-hunting.

---

## Phase 2 — Integration (orchestrator)
Wire seams: `ReaderLoader` routing, AI button→client→popup→history→sync push, OCR tap→lookup popup,
settings registration, `UserConfig` additions. Build with `xcodebuild`, fix until green, smoke-run.

## Phase 3 — Code review (3 agents parallel)
1. Correctness/bugs (render math, coord mapping, parser edge cases, memory).
2. Sync interop fidelity vs `HTTP_SYNC_KV.md` + Android blobs (silent-desync surface).
3. iOS idiom / concurrency / Keychain / large-image memory / `@MainActor` / `Task` cancellation.
Fix all confirmed findings.

## Phase 4 — Simulator play-test (1 agent, needs Xcode)
Boot simulator, install build, import `~/Dropbox/hoshi-manga-bundle/yotsubato/001 [JP] Yotsubato.zip`,
exercise: import → open → RTL page-turn → tap-reveal → lookup → Anki mine → ChatGPT bubble → screenshot
crop translate → zoom/pan → HTTP sync round-trip (diff blobs vs Android) → stats → e-ink. Screenshot +
log defects; iterate until clean.

## Phase 5 — Commit & push (branch `feat/mokuro-manga-reader`).

---

## Top risks
1. Page-turn animation / zoom-crop coordinate mapping in WKWebView (async snapshot ≠ Android sync draw) — crossfade-first.
2. Sync silent-desync (`deriveSyncId`, ms-precision RFC3339, chat-key hashing, LWW/tombstone/Lamport) — Phase 0 tested cores + Android-vs-iOS blob diff.
3. Mokuro font/wrap fidelity for vertical/small bubbles — port curve + wrap-fallback JS verbatim.
4. No on-device LLM (llama.cpp Android-only) — out of scope; ChatGPT cloud covers the ask.

## Build prerequisite
Full Xcode required (Phases 0 build-check, 2, 4). One-time:
`sudo xcode-select -s /Applications/Xcode.app && sudo xcodebuild -license accept && xcodebuild -runFirstLaunch`
