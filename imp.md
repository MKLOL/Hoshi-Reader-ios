# What was done: branch `codex/ios-android-parity`

This file records Claude's initial handoff and the subsequent dated Codex fixes
and verification. Later sections contain the current device results.

## Commits

| Commit | Summary |
|---|---|
| 58ddd70 | Port the current Android reader and sync features |
| d0bc226 | Port manga reading pace; fix the parity review findings |
| 135212b | Download tapped manga one by one; show each when it finishes |
| 1f6260c | Stop the 5 s sync poll stalling scrolling; first Statistics redesign |
| a0e1dd7 | Make idle sync polls and statistics passes nearly free on the main thread |
| 195ef50, c1e38d5, 10c0bd8, 3e99e11, 4a29907, f576220, 4a781d2 | Statistics redesign to match Android: overview, hourly chart, history charts, book page, fixture, accessibility sizes |
| 7b3df47 | Docs for the shipped Statistics redesign |
| 5f5baaf | Fix four reviewer-found cases where the idle-sync skips could miss a change |

## Scrolling lag (P0): "a stall every 5 seconds"

The 5 s foreground poll (map exchange, position lane, statistics poll, preferences poll) did 50–220 ms of work on the main thread. Every poll now costs at most about 3 ms there.

**Moved off main:**
- `HttpSyncKvClient` `put`, `get`, `getBounded` and `list` are `@concurrent`, so bodies are read and decoded off main.
- The listing index is built off main by `HttpSyncListedKeys.index`.
- Statistics disk reads use `HttpStatisticsDisk.read`, and statistics shards are built by `HttpStatisticsDisk.shards`.
- Journal stamps are read by `HttpReadingPositionLane.journalStamps`.

**Nothing is rewritten when nothing changed:**
- `HttpSyncRememberedFile` caches the state and pending files by mtime and size, and skips writes of an unchanged value.
- `HttpSyncRevisionStore.noteRemote` skips identical records.
- The position lane writes its index only on change.
- `fileURL` no longer creates directories.

**Skip signatures:**
- The position lane skips a book whose bookmark and journal file stamps are unchanged.
- The statistics lane skips a whole pass when its settled signature (disk digest, listing and preferences) is unchanged.
- The statistics lane skips a book's legacy key by per-book signature. Books touched by a shard apply are never skipped.

**Android bookmark loop:** Android encodes map entries differently, so the same position has a different ETag. Such books were re-applied and announced as moved on every poll. Identical positions are now only noted, not applied.

**No-change sync:** a sync that changes nothing no longer posts `.hoshiLibraryChanged`, so the shelf does not reload. `activateScope` does not post from `init`.

**Smaller fixes:**
- Table-based `lowercaseHex` replaces per-byte `String(format:)`.
- The Application Support URL is cached.

**Measured in the gate's hosted test:** 80 books with 30 days of statistics each; main-thread CPU per heartbeat window, `CLOCK_THREAD_CPUTIME_ID`. The test enforces a 4 ms budget, and fails if any file is rewritten or any non-GET request is sent.

| Window | Main-thread maximum |
|---|---|
| After import | 0.13 ms |
| First poll | 2.59 ms |
| Steady polls | 2.89 ms |
| Statistics pass | 1.39 ms |
| Pass after a reading save | 2.62 ms |
| Wall-clock gaps | 4 ms or less |

Before: 48–61 ms per poll, and about 220 ms originally.

## Reviewer fixes (5f5baaf)

Reviewers found four cases where the idle-sync skips could miss a change:
- a reading saved during a pass;
- rows received from a shard that also need relaying to the legacy key;
- this device's month missing from the server;
- a position projected after a relaunch.

Each has a test that fails without its fix (mutation-checked): `StatisticsPassSkipTests`, plus the harness checks in `Tests/Fixtures/reading-position-harness.swift`.

The sync test server now exits right after saving its state on SIGTERM. This removed a 3-in-30 shutdown-timeout flake.

## Statistics redesign (matches Android)

- **Today:** reading time first, activity tiles, an hourly chart coloured by book, sessions, and chips of repeated lookups.
- **Streak:** a flame, goal progress, what is left to keep the streak, and a new-record note.
- **Heatmap:** month labels and a Less/More legend.
- **Charts:** labelled weekday and device rows; trend charts with units, a legend and a selected-day readout, in the statistics time zone throughout.
- **Text:** reading time reads like "2h 14m". Empty states have a message, and large text sizes stack instead of truncating.
- **New files:** `StatisticsViewSupport.swift` and `StatisticsHistoryCharts.swift`.
- **Fixture:** four months of reading on three devices.

All 18 UI-review findings are addressed. Screenshots were checked on iPhone and iPad, in light and dark.

## Earlier in the session

- Android feature port and parity fixes.
- The streak and the reading-day boundary.
- Manga download UX: one by one, a per-item ring, cancel and retry.
- Cover aspect ratio: spreads fill their place instead of stretching.

See `docs/CHANGELOG.md` and `docs/ANDROID_PARITY.md`.

## Tests: last full gate (`tools/test_ios_parity.py`) at 5f5baaf

| Suite | Result |
|---|---|
| Server tests | 20 OK |
| Regressions | 104 OK |
| Hosted XCTest | 246 tests, 0 failures |
| UI tests | 4 passed: CloudMangaDownload, Podcast ×2, StatisticsSync |

`ZoomPopupUITests` `testUltraThinActionButtonsStayVisibleAndTappable` and `testSelectionRectStaysNearZoomedMangaTap` already fail at 1f6260c. They are not in the gate.

## NOT done: app-wide main-thread audit findings (measured at 1f6260c, not yet fixed)

1. **EPUB reader rebuilds `ReaderViewModel` every second** (3–9 ms per tick). This is also a correctness bug.
   - **Cause:** the 1 s stats tick writes `readingTracker` (`ReaderViewModel.swift:586`, `:614`). That re-runs `ReaderLoader.body`, which calls `ReaderView.init`, which creates a new `ReaderViewModel` (`ReaderView.swift:192`).
   - **Side effects:** each throwaway model writes the position journal (`ReaderViewModel.swift:215`) and logs `.opened` and `.started` usage events that never close (`UsageLog.swift:214`). A 60 s session leaves 130 phantom sessions, which corrupts usage statistics.
   - **Fix:** build the model once (for example in `ReaderLoaderViewModel.loadBook()`), pass it via `ReaderView(viewModel:)` (`:207`), and move the side effects into a one-time `start()`.
2. **Every reading save triggers an all-books statistics pass.** The save goes `HttpReadingStatisticsSync.schedule` → `HttpStatisticsLane.refresh`, which does a full `listAll` and pass (40–50 ms at 1f6260c).
   - a0e1dd7 moved the disk work off main: the hosted test now shows 2.62 ms. That is unverified for the reader path on a device.
   - **Still open:** the next poll re-runs the pass after this device's own shard upload. Record the uploaded ETags (`HttpStatisticsLane.swift`, `polledStatistics`).
3. **Manga page turn spends 10–14 ms synchronously.**
   - `queueBookmark` decodes, re-encodes and rewrites the 102 KB map cache, the pending file and the revision store with fsync (`HttpSyncBatchExchange.swift:130`, ~4.4 ms).
   - `ReadingPositionRepository.record` takes ~1.6 ms.
   - The reader's own `.readingStatisticsChanged` posts make it re-read the files it just wrote (`MangaReaderView.swift:248`, `ReaderView.swift:771`).
4. **A full reconcile still posts `.hoshiLibraryChanged` unconditionally** (`HttpSyncManager.swift` defer), giving ~150 ms of shelf reload, render and focus inference.
   - Only the done-from-maps path is guarded now.
   - **Check on device:** a `booksChanged` mismatch that never clears (`HttpSyncBatchExchange.swift:345`) would make this happen every 5 s.
5. **UIKit focus inference costs 41–56 ms per shelf hierarchy change.** This was seen only on the simulator, where the Mac keyboard counts as hardware. Unverified on device.
6. **Date formatters are built per call:**
   - `MangaStatisticsTracker.dateKey` (`:121`), ~2 ms per tick;
   - `ReaderViewModel.formattedDate` (`:983`);
   - `ReaderUsageSession.record` (`UsageLog.swift:236`).
7. **`PodcastStore.monitorAccess` rewrites `validatedAccount` and runs `prune` every 60 s** even when nothing changed (`PodcastStore.swift:67-68`).

**Code-read only, not measured:**
- Download progress is unthrottled on the main delegate queue (`HttpSyncBackgroundDownloads.swift:17`, `HttpSyncManager.swift:207`).
- `CloudBookshelfView.items` is computed four times per body.
- `BookshelfView` depends on `records.isEmpty`.
- `fetchMissingCovers` decodes JPEGs on main and refetches 404s.
- A new `URLSession` is created per KV client (`HttpSyncKv.swift:281`).

The audit's scripts and traces are in `/private/tmp/claude-501/-Users-dragos-projects-hoshi/e7c29471-2606-4a15-a402-ecc27892f566/scratchpad/perfrev-mainthread/`.

## Other open items

- The iPad mini install has not been run. `install.sh` launches the stale bundle ID `com.dragosristache.hoshi`.
- Quirks-mode chapter height.
- Sentence-mode autostart.
- TTU Drive precision.
- Staged-manga refresh is invisible and cannot be cancelled.
- A shelf-placement race.

---

## Codex follow-up — completed November 8, 2026

This follow-up began after Claude's completed handoff at `5f5baaf`. Four fresh,
independent reviewers inspected that completed state before implementation. The
confirmed open findings above are superseded by the fixes and verification below.

Implementation: `4a472e4`. Disposable-Simulator readiness fix: `b525a4f`.

### Confirmed findings fixed

- Retain one EPUB reader model in the loader. Start and finish its usage session
  once; redraws and statistics ticks cannot create phantom sessions or timers.
- Stop readers rereading their own statistics writes. Skip identical statistics
  saves, reuse thread-safe date formatting, and use the reader's autostart setting.
- Compare TTU progress at millisecond precision without rewriting the authoritative
  bookmark or journal merely to acknowledge an export.
- Capture bookmark mutations before the asynchronous library scan, include those
  exact entries in uploads, and acknowledge only the captured mutation IDs. Page
  turns no longer rewrite the entire owned bookmark-map cache. Unconfigured HTTP
  sync does not maintain an HTTP outbox.
- Scope map acknowledgements to the account. Reject invalidated responses and
  commits throughout maps, reconciliation, statistics, usage and settings, including
  an account switch away and back. Bind scheduled preflights to their originating
  configuration and treat intentional cancellation quietly.
- Revalidate queued manga tombstones before transfer and installation. Preserve
  newer local shelf moves across GET/PUT waits. Give staged replacements the same
  visible transfer and cancellation lifecycle as fresh downloads.
- Notify the bookshelf only after an actual local library change.
- Record successful own-statistics upload metadata in the poll observation, retain
  newer observations, and recover missing or older local history even when remote
  shard ETags have not changed.
- Compute weighted medians without overflowing the total sample count. Bound
  imported reading durations and finish estimates before constructing Duration.
- Decode cloud covers off the main actor, back off absent covers while permitting
  archive/account changes and later backfills, reuse foreground HTTP sessions,
  coalesce transfer presentation updates, and avoid repeated shelf sorting and
  unchanged podcast-validation maintenance.
- Reserve the manga toolbar's measured height for page actions. Add self-contained
  fixtures for the two previously excluded zoom/action UI cases and require both
  in the full gate. Resolve the install script's launch identifier from the built
  app's Info.plist.
- Wait for a newly created Simulator's boot services before launching test hosts;
  cleanup remains restricted to the gate's own disposable device.

### Final verification

`build/parity-python/bin/python tools/test_ios_parity.py` exited **0** on the
committed source. Results:

- **20** real-server tests passed.
- **107** Python regressions passed, including the hosted simulator wrapper.
- **278** hosted XCTest cases passed with zero failures.
- **6** UI cases passed: cloud manga download, both podcast scenarios, Statistics,
  zoomed manga selection, and thin manga action buttons including AI and copy.
- The 80-book fixture measured **2.69 ms** main-thread CPU on the first poll,
  **3.05 ms** over later polls, **1.00 ms** in a statistics pass, and **2.26 ms**
  after a reading save. Maximum measured heartbeat gap: **4 ms**. Unchanged polls
  made no writes or non-GET requests.
- An actual manga page turn in that library took **3.78 ms CPU / 4.17 ms wall**;
  its final page survived close, sync and reopening an uncached position journal.
- The actual EPUB-loader lifetime test verified one open/start/stop/close session
  through redraws and ticks, with no continued logging after dismissal.

Logs: `build/codex-final-gate.log`, `build/ios-sync-integration.log`, and
`build/ios-parity-ui.log`. These generated artifacts remain ignored.

The four reviews found no demonstrated quirks-height defect in the current page
geometry. Device-specific UIKit focus-inference costs remain unmeasured; physical
hardware profiling and device installation were outside this simulator run.
The durable per-turn journal remains synchronous, with its reduced complete
navigation path measured above. No confirmed review findings remain open.


---

## Expanded commit and scrolling audit — November 8, 2026

A further four-reviewer pass covered the complete recent Claude sequence,
`46def8c..5f5baaf`, including the original port. The handoff had already completed
before this pass. Review coverage was:

| Commit | Reviewed change |
| --- | --- |
| `58ddd70` | Reader/sentence/manga port, AI lifetime, setup, settings, dictionary, audiobook, cloud books, preference and position protocols, statistics/import baseline |
| `d0bc226` | Manga pace, reader parity, download and position corrections |
| `135212b` | Sequential tapped-manga downloads and per-item shelf reveal |
| `1f6260c` | Five-second poll work, background library scanning and Statistics redesign |
| `a0e1dd7` | Idle skips, background statistics/index work and unchanged-write suppression |
| `195ef50` | Hours/minutes reading-time formatting |
| `c1e38d5` | Hourly reading and trends |
| `10c0bd8` | Overview, history charts, devices and book details |
| `3e99e11` | Four-month, three-device statistics fixture |
| `4a29907` | Accessibility-size book-cover behavior |
| `f576220` | Unused Charts import removal |
| `4a781d2` | Usage-aware current-day counts |
| `7b3df47` | Shipped Statistics documentation |
| `5f5baaf` | Journal recovery and statistics idle-skip races |

The independent assignments covered feature/reader changes, sync/protocol changes,
statistics and day arithmetic, and a separate poll/main-thread crosscheck. Findings
already fixed in `4a472e4` were checked against current source and tests.

### Additional findings fixed

- The poll still constructed ICU date parsers for every monthly statistics key.
  Fixed wire-format validation now uses strict ASCII year/month bounds.
- A changed monthly shard still decoded, merged and encoded statistics on the
  main actor. Preparation now runs in the background. A short final commit checks
  exact root/file stamps and the account; concurrent reading saves/imports retry,
  and removed/replaced payload directories cannot be recreated.
- Each saved book could trigger a whole-library Statistics reload. Reloads now
  debounce in bursts, load/aggregate in the background and publish cached arrays.
  Generation checks prevent an older load replacing newer data.
- Incoming position journals still hashed, decoded, validated, merged, selected a
  winner and serialized on the main actor. These operations and cold-cache journal
  reads now run in the background. Commits preserve newer local navigation and
  reject an invalidated account or removed/replaced root. Eight failed snapshot
  attempts leave the journal unacknowledged for a later poll.
- Successful-write fingerprints included keys excluded by the observed fingerprint.
  Reader-preference/legacy-reading writes could therefore prevent acknowledging a
  full reconcile and schedule another full pass. Both filters now use the same
  production predicate; payload changes still prevent unsafe acknowledgement.
- Local journal persistence no longer sorts every inherited causal key or serializes
  an unchanged state. File-stamp checks retain no-op bytes/timestamps, and the journal
  still commits synchronously before projecting the page bookmark.
- A valid 512-origin history could produce an invalid next local event whose causal
  frontier exceeded the protocol's 256-entry limit. Generated frontiers now retain
  the current winner and local origin within that bound; both navigation and legacy
  imports survive a fresh repository reload. Large-history winner selection avoids
  repeated pairwise scans while preserving self-observation and duplicate behavior.

### Expanded verification

`build/parity-python/bin/python tools/test_ios_parity.py` exited **0** on the
final source. Results:

- **20** real-server tests passed.
- **107** Python regressions passed, including the standalone position-protocol
  harness and hosted simulator wrapper.
- **298** hosted XCTest cases passed with zero failures.
- **6** UI cases passed: cloud manga download, both podcast scenarios, Statistics,
  zoomed manga selection and thin manga action buttons.
- The settled **80-book / 108-monthly-shard** fixture measured **1.93 ms** main-thread
  CPU on its first poll, **2.72 ms** over later polls, **1.85 ms** in a statistics
  pass and **2.26 ms** after a reading save. Maximum heartbeat gap: **4 ms**.
  Unchanged polls made no file writes or uploads.
- The production bookshelf scrolled through **4 real polls**, with **985** display
  callbacks and a maximum display gap of **18 ms**. A separate native scroll through
  a **999,133-byte / 512-event** incoming position journal peaked at **16 ms**.
- The production Statistics screen kept scrolling throughout the complete
  **2,400-row / 80-book** import: **14 seconds**, **859** display callbacks and a
  maximum display gap of **43 ms**. All imported rows were verified on disk.
- An actual manga page turn after those imports took **6.79 ms CPU / 7.21 ms wall**,
  within the unchanged **8 ms** CPU budget. Its final page survived close, sync and
  reopening an uncached position repository. The isolated durable position turn
  after a **1.3 MB** causal import took **3.09 ms CPU**.
- New native tests verified cold journal loading, 512-origin winner/frontier
  behavior, next-navigation and legacy-import durability, concurrent saves/imports,
  invalidated accounts, removed/replaced roots, unchanged journal bytes/timestamps,
  coalesced notifications and stale snapshot rejection.

Logs: `build/codex-poll-full-gate.log`, `build/ios-sync-integration.log`,
`build/ios-parity-ui.log` and `build/codex-poll-focused-final.log`. Generated
fixtures and logs remain ignored. The gate removed only its own disposable
Simulator; the pre-existing `hoshi-perf` Simulator was preserved.

These measurements use programmatic native scrolling of the real screens on a
Simulator. Physical hardware and one-time legacy migration/retained-history
absorption were not performance-profiled. No confirmed findings from this
expanded review remain open.

---

## iPad mini setup and navigation follow-up — November 9, 2026

The earlier review did not catch fresh dictionary setup or the five-tab iPad mini
layout. This follow-up reproduces and fixes the three reported problems.

- The official JMdict browser download URLs returned HTTP 504 on both the host
  and the mini Simulator. GitHub's official release-asset API served the same
  archive successfully. Dictionary downloads now retry transient errors once,
  bypass stale signed redirects, and fall back to that API for recognized GitHub
  release URLs. Asset IDs are resolved from release metadata, not hardcoded.
  HTTP error pages are rejected before native import and temporary failures are
  removed. This uses URLSession, Codable and the existing native dictionary backend.
- A partial native import writes `index.json` before its completion marker. It
  previously appeared installed and prevented retry despite producing no lookup
  results. Storage scans now require the marker and nonempty native data files.
  Recommended imports and updates build in a hidden sibling directory and publish
  only completed output, preserving an existing dictionary when import fails.
  The native low-memory mode limits concurrent bank processing to two workers.
  Setup displays the actual failing stage and error.
- The iPad's top tab strip shared width with six Bookshelf actions. With all five
  tabs enabled, Settings was clipped behind a Next Page control and Add Manga
  could disappear into toolbar overflow. iPad tabs now have their own bottom bar;
  every tab content root restores its real size class for tablet layouts.
- Add Manga is a compact, accessible plus button that opens Files directly.
  Sort, selection, shelf management and EPUB import remain in Bookshelf options.
  Dictionary popup placement now reads the actual tab-bar location.

Two independent source reviews found no introduced actionable defects in the
dictionary and iPad navigation changes. The native importer's existing handling
of untrusted archive titles was not changed; the staging directory is not a
sandbox for arbitrary ZIP archives.

### Focused verification

- **17/17** native tests passed on a disposable iPad mini: ten deterministic
  download/import cases, five setup cases and two opt-in live tests.
- The live tests downloaded both real default dictionaries, imported them with
  the C++ backend, and verified definitions and frequency results for `猫`.
  The public DictionaryManager setup path recovered an index-only interrupted
  installation, rebuilt the shared lookup query and completed an idempotent retry.
- Native fixture tests also verified failed-update preservation, completed-update
  replacement, HTTP/HTML rejection, temporary-file cleanup, release API headers,
  tagged releases and exclusion of unrelated URLs from fallback routing.
- The final two mini navigation cases passed, including actual selection of every
  tab, Manga settings, compact plus dimensions, both file pickers, and manga import
  open/cancel in portrait and landscape. Dictionary intentionally opens its keyboard;
  the test submits an empty search before checking navigation to the next tab.
  Full-screen portrait and landscape captures were inspected visually.

The regression gate now accepts an explicitly selected disposable iPad mini and
requires the new navigation/import UI cases. Opt-in live network tests are run
separately so the normal gate retains its no-skipped-scenarios check without
depending on public dictionary hosting. User devices and the existing `hoshi-perf`
Simulator are preserved.

The final mini stress case also passed: first-poll main-thread CPU **1.88 ms**,
later polls **2.27 ms**, statistics pass **1.89 ms**, and the pass after a reader
save **2.41 ms**. Maximum heartbeat gap was **4 ms**; unchanged polls wrote or
uploaded nothing. Bookshelf scrolling ran through four real polls with **924**
display callbacks and a maximum gap of **66 ms**. A **999,263-byte** incoming
position import peaked at **59 ms** while scrolling; the complete **2,400-row**
Statistics import peaked at **52 ms**. A real manga turn used **7.47 ms** CPU /
**8.12 ms** wall time and preserved its position through reopening. These are
Simulator measurements, with occasional missed frames; they do not establish
zero lag on physical hardware.

The final mini run passed **20** real-server tests, **108** Python regressions
and **308** hosted XCTest cases with zero failures or skipped scenarios. The two
live network cases above ran separately with explicit opt-in.

The mini UI run passed cloud manga download, both podcast scenarios, Statistics
and thin manga actions. Together with the corrected navigation rerun, **7/8** of
the gate's distinct UI cases passed on the mini. A fresh iPhone run passed all
**four** focused cases: the two navigation cases, zoomed selection, and page-jump
zoom reset followed by forward/backward swipes.

### Remaining independently reproduced reader issue

The complete mini UI gate is **not green**. The zoomed-selection case failed
because native zoom remained at `1.000`. A second explicit pinch/page-jump check
also failed. Repeating the checks with the original top-tab layout produced the
same failure, excluding the new bottom-tab adaptation as its cause.

The strengthened tests now verify that native zoom actually changed before
checking selection geometry; page-jump tests seed their own synthetic fixture.
Both cases pass on iPhone. On the iOS 27 mini Simulator, a temporary programmatic
probe could set zoom and the content transform to 2, but WebKit's
`_updateScrollViewForTransaction:` restored both to 1 on the following layer-tree
commit. The document load token stayed at 1 and `didFinish` did not run again.
The observed recognizer was the current native pinch recognizer.

Controlled checks of viewport-scale policy, root overflow, the external scroll
delegate, tab traits, a minimal document/native setup, and the document base URL
did not establish a working public fix. All temporary product changes and forced
zoom probes were removed. No reader scaling rewrite or private API was shipped.
The exact platform/app-shell cause remains unconfirmed; this is an open issue,
not a claim that reader zoom has been fixed or that the app is bug-free.

Evidence: `build/codex-mini-dictionaries-fallback.log`,
`build/codex-mini-full-gate-final.log`, `build/ios-sync-integration.log`,
`build/ios-parity-ui.log`, `build/codex-mini-navigation-reviewed.log`,
`build/mini-navigation-reviewed-screens/`, `build/codex-phone-navigation-final.log`
and the ignored `build/mini-zoom-reset-trace-diagnostics/` export.

Product fixes: `70d755a` (default dictionaries) and `7fe181f` (compact navigation).
The tested changes are committed locally; they require a new app build to reach
an installed iPad. No physical-device installation or profiling was performed.


## 2026-11-09 — Manga OCR, iPad usability and measured startup follow-up

The earlier map/history change did not establish that the reported three-second
opening delay was fixed. The user reproduced it on the physical mini after the
first update. That result reopens the startup issue; model readiness and page-turn
CPU measurements are not tap-to-visible-page measurements.

### Implemented changes and review

- `9b330e7`: reader-open consumes map readiness while histories continue in the
  same flight; close-flush still waits for the final history. Local parsing runs
  concurrently. Cold position warmup yields after each eight admissions rather
  than processing the whole library in one main-actor slice.
- `3c2feb9`: serialized background manga imports with progress and atomic staging,
  safe shared-Inbox cleanup, correct manga Mark Read, and EPUB-only bookshelf
  actions hidden/guarded for manga.
- `6666b47`: Android's image-relative OCR sizing and 30-pixel half-headroom curve,
  removal of the extra iOS reveal-size boost, stable measured AI toolbar placement,
  corrected wrap overflow measurement, and matching translucent settings/history
  controls. Crop clears revealed OCR, modal screens gate page navigation, keyboard
  Go submits page jumps, and history controls/empty states/copy actions are corrected.
- `2735e02`: manga opens the durable local position while bookmark refresh runs
  independently. A late remote winner still reaches the reader; newer local turns
  remain protected. WebKit is mounted during decoding and initial readiness,
  geometry and bookmark changes coalesce into one initial document. Initial
  restoration never snapshots a blank page as a page-turn animation.
- The same commit replaces the unused generic preloader with one prepared manga
  WebView, registered with its image scheme before construction. Readers reuse that
  view after removing their handlers, delegates, gestures, keyboard closures and
  controller attachment. The view stays hidden until its current navigation finishes.
  Per-document UUID checks reject obsolete OCR/AI/clipboard/readiness messages;
  image namespace checks reject an earlier book's requests. A closing/cancelled
  load does not start statistics after the image-loader suspension.
- Unused `lines_coords` arrays are no longer decoded. An optimized standalone
  Mac benchmark on a synthetic 12.07 MB/250-page sidecar improved from 238.37 ms
  to 59.05 ms. This is a smaller parsing improvement, not evidence for the full
  three-second cause.

Four independent reviewers examined the initial reader fixes, then three separate
agents searched and fixed library, daily-reader and translation QoL issues. After
the user's remaining startup report, three agents traced first paint, audited
large-book work, and built meaningful startup measurements/tests. They also
reviewed the WebView reuse and late-sync behavior; their concrete findings above
were addressed.

Android history was checked, including `3f6cfc9d` (the reported 3–5-second startup
fix) and `9b69b57d` (maps before histories). Android's original fixes bounded sync,
avoided redundant sidecar rewriting, and prevented repeated first-page loads during
system-bar changes. Its recorded cold no-sync result was 0.6 s and stalled-server
result 2.1 s; those are not universal instant-opening guarantees.

### Opening measurements

New opt-in Release-capable tracing records constant stage names with no book
titles, paths, OCR text or credentials. It is disabled normally, emits at most 48
lines, and writes one bounded diagnostic file in the background after the first
image signal. Only the newest eight traces are retained; there is no polling.

On the disposable mini simulator, the previous sequence reached HTML navigation
at 150.8 ms, then did not request the image until 1568.5 ms. Image bytes were ready
at 1569.4 ms, document loading finished at 1574.5 ms, and image decode plus two
browser frames completed at 1853.3 ms. This isolated a roughly 1.4-second WebKit
startup gap that removing the sync wait alone did not eliminate. In that sample,
statistics initialization took 2.9 ms, so it was not moved based on speculation.

With the actual manga WebView prepared/reused, the final fresh-launch UI run
measured **336 ms**, then **80 ms** and **92 ms** reopening saved page 2. Each
opening used exactly one initial document; the callback identified the actual
page image and screenshots checked white paper plus both gray fixture blocks.
These timings start at model creation and end at image decode plus two browser
frames. XCTest's tap operation/idle waits add overhead (the external automation
measurements were about 1.5–1.6 s); they are separate from the native timing and
do not establish physical finger-to-screen latency.

The synthetic DEBUG fixture now uses a fresh sync ID per launch, so an old
position journal cannot defeat its intentionally reset bookmark. Reopening in
the same launch preserves its real saved-page journal and is checked twice.
No synthetic fixture was installed on physical hardware.

### Verification and limits

- **49/49** final focused native tests passed: bookmark races, late map/local turn
  ordering, image namespace and parser behavior, OCR/ruby layout, reader lifetime,
  remote positions, scheme cancellation routing and clean concurrent view reuse.
  Test managers explicitly disable unrelated shared post-map lanes so isolated
  bookmark tests cannot scan a previous UI fixture's library. Production defaults
  retain both companion lanes. Mock uploads are selected by bookmark-map key and
  retain content types, rather than decoding an unrelated gzip usage upload.
- **107/107** non-hosted Python regressions passed, with no skips, using the
  existing `build/parity-python` environment. The first system-Python run skipped
  seven sentence tests for its missing regex dependency; that run was replaced.
- **Six distinct** final mini UI scenarios passed: decoded-image startup and two
  saved-page reopenings, repeated OCR actions in portrait/landscape, keyboard Go,
  crop clearing, AI/history navigation gating, and thin action controls. Five
  interaction cases passed together; startup passed separately after fixture
  isolation was corrected. Physical Return key delivery remains unvalidated;
  the platform SwiftUI field is retained and temporary keyboard workarounds removed.
- Earlier in this follow-up, the broad hosted run passed 311/312 and exposed the
  existing 8 ms cold-history limit. After batching, three consecutive isolated
  measurements passed that unchanged limit: 2.92, 2.29 and 4.31 ms. The complete
  312-case gate was not rerun after the final startup changes.
- The earlier large-library live-scroll scenario passed with 80 books, 2400
  statistics rows, 787 display callbacks across 14 seconds, and a maximum display
  gap of 50 ms. A manga turn took 6.96 ms CPU / 7.40 ms wall time. These simulator
  results include missed frames and do not establish zero lag on the physical mini.
- The independently reproduced iOS 27.0 mini-simulator pinch-reset issue described
  above remains open. Physical iPadOS 27.2 zoom has not been profiled.

The first optimized update was installed and its new bundle process was verified
on the user's iPad mini; a physical screenshot showed a manga reader. All 31
previous library directory entries remained present. That check established
installation/display and library preservation, not opening latency. Physical
startup tracing attempts then lost the connection or encountered a locked device;
there is no usable physical before/after timing from those attempts.

Latest optimized startup update (`2735e02`): Release build and strict/deep code
signature verification passed. The update installed successfully over the existing
app into bundle container `BC723C32-D86D-4DD6-AE0F-082540A0A8C4`. Wireless CoreDevice
connectivity failed immediately afterward. Reconnection then succeeded and a
fresh library listing verified all 31 prior entries remained present. A subsequent
fresh launch was explicitly rejected because the device was locked. The user has
been asked to leave the mini unlocked for an actual-book startup measurement.
At that checkpoint physical latency was still unverified; no claim of instant
physical opening was made.
The owned disposable review simulator was shut down and deleted after preserving
its traces. The user's existing `hoshi-perf` simulator was preserved.

### Automated physical follow-up

Added an explicitly selected, opt-in physical-library XCTest that opens the saved
manga three times, records native first-image timing and current document/page
identity, and attaches screenshots. It selects the existing book through a stable
accessibility identifier; no fixture, preference reset, import, or page turn is
used. Normal last-access, reading statistics and background sync still occur.
Tracing alone enables the probes, so generic UI-testing launch behavior is not
required. Trace-only probes update from state changes without a periodic refresh.
The diagnostic process disables its idle timer while active; quitting restores
normal system auto-lock behavior without changing a system preference.

Three agents rechecked presentation, parsing/rendering and Android startup parity.
No remaining fixed opening sleep was found. The 200 ms reader fade overlaps
preparation; the two-second recovery timeout belongs to subsequent page turns.
Position restoration and statistics still do synchronous work before the first
HTML load, and speculative adjacent-page preparation can contend with the visible
image. These remain data-dependent risks rather than demonstrated multi-second
causes in the available evidence.

Read-only copies from the actual selected volume allowed additional optimized
Mac measurements without further manual interaction with the iPad:

- OCR sidecar: 2,046,354 bytes, 232 pages and 1,333 boxes. The exact shipping
  parser took 7.76 ms initially, a 4.50 ms fresh-parser median and a 0.037 ms
  cached median. The previous coordinate-decoding implementation had a 9.46 ms
  median in the separate decode/map harness.
- Position journal: 89,472 bytes, 123 events and five heads. Ten fresh-process
  opens of isolated copies took 2.14–2.79 ms, median 2.30 ms, and restored page
  index 180 every time. Warm opens were approximately 0.12 ms.
- The two statistics sidecars were only 7,694 and 1,557 bytes, with the migration
  marker already present. These sizes do not establish their execution cost.

These desktop measurements do not replace the physical first-paint trace. The
signed optimized test build succeeded, but the physical test was blocked by
`Unlock iPad to Continue` and then lost its pending runner connection before
launch. No manga opening or physical startup metric was collected in that run.
The test can perform all three openings automatically after a successful launch;
the user does not need to repeat manual manga-opening steps.
The final build with event-driven trace probes also passed optimized test-build
compilation and strict/deep signature verification. It installed successfully over
the existing iPad app, and all 31 previous library entries remained present.
A fresh normal launch was again explicitly rejected with `Locked`; the diagnostic
idle override had not run, and physical first-paint verification remained pending
until the successful unlocked runs below.

### Verified physical manga opening — November 9, 2026

After the iPad was unlocked, two optimized Release runs of the real-library test
passed, with three openings each. The first run measured model-to-image readiness
at **151, 78 and 80 ms**. The final run moved the timer to the actual bookshelf
button handler, before selected-book state changes and reader presentation:

| Opening | Selection-handler to decoded image readiness | Initial HTML loads |
|---|---:|---:|
| First after app launch | 148 ms | 1 |
| Reopen | 83 ms | 1 |
| Reopen again | 98 ms | 1 |

Each final persisted trace contains `book_selected`, `model_created` and
`first_visible` under the same trace ID. Selection-to-model construction took
13.25 ms initially and 3.46–3.89 ms on reopen, so presentation setup is included
in those final measurements. Image readiness remains the current document's
successful image decode plus two browser frame callbacks received natively.
This is not a literal finger-down to fully composited-screen measurement; the
reader also has a 200 ms presentation fade that overlaps preparation.

All six openings restored page 181 (decoded page index 180), with one initial
document and no live bookmark displacement. All six exported screenshots show
the actual artwork and page indicator 181/232, without a spinner or blank overlay.
The root independently inspected the first screenshot from each run; a separate
agent inspected all six. The bookmark's JSON values are unchanged before/after.

The first physical trace reached HTML navigation at 53.84 ms, image request at
91.18 ms, bytes at 99.39 ms, document completion at 102.08 ms and decoded readiness
at 150.63 ms. Position and statistics setup each took under 2 ms on this real
volume. No additional speculative position/statistics rewrite was made.

XCTest's separate tap-to-observation wall times were approximately 3.6–3.7 s.
The test log attributes roughly 0.5 s to event synthesis/automation and 3.1 s to
its existence/readiness predicates and accessibility-query cadence. Those values
are not the app's black-screen duration and are not substituted for native timing.

This verifies the selected real volume and saved page on the user's physical
iPad mini (A20 Pro), iPadOS 27.2. It does not establish zero lag for every title,
every interaction or an immediate tap during cold app launch. The earlier zoom
and broad-test limits above are unchanged.

After verification, all 31 previous library directory entries were still present.
The temporary XCTest runner was uninstalled, and the updated Hoshi app was
successfully relaunched normally without diagnostic launch flags. The process-only
idle override and trace probes are therefore disabled for normal use.

Evidence (ignored): `build/codex-ocr-qol-native-final.log`,
`build/codex-ocr-qol-performance-final.log`, `build/codex-ocr-qol-ui-final.log`,
`build/codex-ocr-qol-ui-keyboard-go-final.log`, `build/codex-ocr-chrome-screens/`,
`build/codex-manga-startup-ui-baseline-v2.log`,
`build/codex-manga-startup-ui-prewarm.log`,
`build/codex-manga-startup-native-final-v2.log`,
`build/codex-manga-startup-python-final.log`,
`build/codex-manga-startup-ui-final.log`,
`build/codex-manga-startup-ui-final-startup.log`, and
`build/codex-manga-startup-release-final-build.log`,
`build/codex-manga-physical-build-for-testing-final.log`,
`build/codex-manga-physical-build-for-testing-no-poll.log`,
`build/codex-manga-physical-release-run.log`,
`build/codex-manga-physical-final-install.json`,
`build/codex-manga-physical-final-books.json`,
`build/codex-manga-physical-final-normal-launch.log`,
`build/codex-manga-physical-release-run-unlocked.log`,
`build/codex-manga-physical-first-traces/`,
`build/codex-manga-physical-selection-build.log`,
`build/codex-manga-physical-selection-run.log`,
`build/codex-manga-physical-selection-traces/`,
`build/codex-manga-physical-selection-stages.json`,
`build/codex-manga-physical-selection-review/`,
`build/codex-manga-physical-verified-library.json`,
`build/codex-manga-physical-verified-remove-runner.log`,
`build/codex-manga-physical-verified-normal-launch.log`,
`build/codex-startup-parser-audit/actual-production-parser.json`, and
`build/startup-first-paint-audit/position-open/results.json`.


---

## Three-reviewer pre-merge pass — November 9, 2026 (Claude)

Before merging `codex/ios-android-parity` into `main`, three independent reviewers read the
whole branch (35 commits, 195 files) with separate scopes: (A) HTTP sync, reading positions and
the statistics/usage data layer; (B) the EPUB, sentence and manga readers, podcasts, popup, AI
and their JavaScript; (C) app shell, bookshelf, settings, setup, statistics views, privacy
claims, test hooks and the build scripts. Reviewer B split podcasts/Sasayaki/furigana and
AI/popup/dictionary into two sub-reviews. Every reviewer worked read-only. Each finding below was
checked against the code before it was changed; the ones not changed are listed at the end.

The gate was green on the untouched branch first (20 server tests, 108 Python regressions, 333
hosted XCTest cases, 8 UI cases), which closes the note above that the complete gate had not been
rerun after the startup changes.

### Two findings that contradicted this file

**1. "Every poll now costs at most about 3 ms" did not hold once devices publish reading
activity.** `HttpUsageLane.run` is on the main actor and called `ReadingDay.parse` — which
built a `DateFormatter` and three calendars per call, about 165 µs — for every listed usage key in
four places, one of them inside a loop over this device's own day files. It also checked every
cached day file with `fileExists` on the main actor. Reviewer A measured 66 ms per pass with 30
keys, 583 ms with 99 keys and 919 ms with 126 keys (three devices, late in a month, a year of
history), on every statistics pass: once a minute from the poll and every 30 seconds while
reading. The hosted performance test missed it because it seeded no usage keys.

- `ReadingDay.fixedKey` reads the fixed `yyyy-MM-dd` and `yyyy-MM-dd'T'HH:mm[:ss]` grammar
  directly. `parse`, `hour`, `isDay` and `StatisticsZone.wallInstant` use it and keep the
  formatter for anything else, including dates before 1583, so their results are unchanged.
  This also removes the formatter from every statistics row read in a sync pass.
- The lane parses each key once, groups this device's keys by month, and asks `UsageLog.complete`
  for the cached-file check on the log's own queue.
- `StatisticsDayParityTests` compares the new readers with formatter-only references for every day
  from 1999 to 2042 in seven time zones (including ones whose DST changes skip midnight), every
  hour of sampled days, and malformed text. The large-library test now seeds 126 usage keys from
  three devices plus 30 of this device's own days and asserts they were received.
- Measured in that test with the usage keys present, over five runs: **1.9–2.7 ms** on the
  first poll, **2.0–3.0 ms** over later polls, **1.7–2.1 ms** in a statistics pass and
  **2.1–2.5 ms** in one after a reading save; longest heartbeat gap 4 ms.

**2. Sentence-aware pagination made EPUB chapters take seconds to open.** Reviewer B measured
`hoshiTextLayout.prepare` in a macOS WKWebView harness running the repository's own scripts:
0.7 s for 26 pages, 4.3 s for 52, 12.9 s for 104, and over two minutes for a 343-page single-file
book, all behind the loading spinner. On `main` this step does not exist.

The cause was not the algorithm. `-webkit-line-box-contain: block glyphs replaced`, a rule
that predates this branch, makes WebKit measure the ink bounds of every text run, and the word
boxes split a chapter into five times as many runs. One relayout of a 52-page chapter cost 1.5 s
with that rule and 0.08 s without it; the same held with the word boxes set to `display:
contents`, so the runs, not `nowrap`, are what cost.

- `ReaderTextStyle.lineBoxCSS` now uses `block inline-box replaced` for the paged reader, the
  continuous reader and podcast transcripts. Across 27 text constructs, two orientations, four
  fonts and five line heights, line sizes are identical for prose, ruby (including `rp` and
  long readings), emphasis, tate-chu-yoko, gaiji images, links and rare kanji. Lines holding
  inline text set larger than the paragraph, or sup/sub, are 1–2 px taller (up to 5 px for
  sup/sub at a line height of 1.2), and at that tight line height a line with an emoji or a
  Latin fallback font is 1.5–3.5 px shorter. At line heights of 1.65 and above nothing differs
  in vertical text.
- `textlayout.js` gives break placement a budget of 800 ms; past it the confirmed breaks stay
  and the rest of the chapter keeps ordinary page breaks. A document over 120,000 visible
  characters is left as the publisher wrote it, with no word boxes or breaks.
- Same harness, same Mac, vertical text at 744×1000 and 22 px:

  | Chapter | Before | After |
  |---|---:|---:|
  | 11 pages | — | 61 ms |
  | 26 pages | 721 ms | 136 ms |
  | 52 pages | 4,327 ms | 348 ms |
  | 104 pages | 12,915 ms | 747 ms |
  | 156 pages | — | 1,170 ms |
  | 57 pages, repetitive prose | 13,140 ms | 796 ms |
  | 49 pages, horizontal | 3,455 ms | 779 ms |
  | 332 pages in one file | over 120 s | 8 ms (left alone) |

  Page and break counts are unchanged where a run finishes (52 pages / 47 breaks, 104 / 99).
  Horizontal text still needs many passes; a 96-page horizontal chapter stops at its budget
  after 1.5 s with the rest unbroken.
- `SentenceReadingParityTests.testLongChaptersPaginateQuicklyAndASingleFileBookIsLeftAlone` lays
  out a 57-page chapter with the reader's real rules and requires all breaks in under 3 s
  (1.0 s in the simulator; 13 s with the old rule), and checks that a 280,000-character
  document is left alone.

These are Mac and simulator measurements. Chapter opening has not been timed on the iPad.

### Other findings fixed

Readers:
- **A page whose WebContent process iOS discarded.** No reader handled it. In the paged EPUB
  reader the next swipe got no answer from the blank page, and anything but `"scrolled"`
  counted as the chapter's edge: the reader moved to the next chapter and saved that position.
  The paged and continuous readers and the manga reader now load the page again at the last
  saved place (at most three times in a row), and the paged reader changes chapter only on an
  explicit `"limit"`. Podcast transcripts reload their skeleton and resend the document. The
  manga reader also retries a navigation that failed for the page still wanted, which used to
  leave the reused view hidden.
  `ReaderLifetimeTests.testPagedReaderReturnsToItsPageWhenThePageProcessEndsAndADeadPageCannotTurnTheChapter`
  hosts the real paged reader, turns a page, ends the page's process with WebKit's test-only
  switch, swipes on the dead page and checks that the chapter does not turn and the reader comes
  back on the page read last. Without the guard it fails with one chapter turn.
- A vertical chapter restored to its first page when the target text node began with collapsed
  whitespace (pretty-printed markup); the word boxes made such nodes more common.
  `SentenceReadingParityTests.testVerticalRestoreFindsItsPageWhenParagraphsOpenWithALineBreak`
  restores 25%, 50% and 75% of a 39-page chapter; without the fix all three land on page 0,
  in the iOS simulator as in the reviewer's macOS harness.
- `ReaderWindow` captured itself weakly in the reader's own back action. When the shelf section
  that owned the window disappeared (its only book finished or moved), the reader could not be
  closed.
- An EPUB that failed to load left a full-screen spinner with no way out; it now shows a message
  and a Close button.
- Sentence mode: a tap on a reading resolved to a word in the line above; a book without chapter
  metrics opened on the chapter's last sentence; every return to the app started a second sync
  beside the reader's own.
- Sentence mode and the Chapters sheet resolved every contents entry against every chapter, with
  symbolic-link resolution each time; both resolve once.
- A manga image request could join a read that `setWindow` had just cancelled.
- A lookup popup stayed open over text replaced by a position from another device.

Library and settings:
- **Restore accepted any `.hoshi` file for either collection** and replaced it without asking.
  A dictionary backup picked under Books replaced the whole library. Restore now checks what the
  archive holds, asks for confirmation naming the file, and says why a file was refused.
- Opening an EPUB or Anki file from another app cleared the whole Inbox, including manga archives
  still queued for the background import (contrary to "safe shared-Inbox cleanup" above).
- Interrupted imports left `Books/.MokuroImport-*` and `Dictionaries/*/.import-*` folders
  forever; they are removed at launch.
- The Dictionary tab changed its page identity before the lookup returned, so the first search
  after an empty state loaded an empty page. This was already on `main`.
- UI-test fixtures that replace the sync token, statistics, preferences or books ran in any
  Debug build. They now run only on a simulator, so a test run pointed at a real device by
  mistake cannot overwrite its library. `install.sh` also defaulted to that Debug build; it
  now installs Release, shows the real `devicectl` error and no longer leaks a temp file.

Sync and data:
- A book whose statistics sidecar could not be decoded could not be deleted, and a tombstone for
  it from another device retried a full reconcile every minute. Retention now copies the file to
  `.unreadable/` and keeps what can be read.
- A cancelled sync recorded each position journal it was fetching as failed, with a back-off.
- A listed key such as `books/../epub.manifest` produced a folder outside the library.

AI and popup:
- A reply arriving after its book was deleted recreated the book's folder with only a chat log,
  which blocked re-importing an EPUB and gave a re-imported manga a different sync ID.
- An undecodable chat log was replaced by a one-entry log; it is now kept beside the new one.
- The popup decoded the book's whole chat log, screenshots included, on the main thread at every
  open and every request update; now only when the history is shown.
- An on-device translation waiting for an earlier one showed that one's streaming reply as its
  own.
- `popup.js`: Back/Forward during a redirect render appended entries to the restored view;
  structured content could create any element, `script` included.
- Typing a custom model ID that passes through a listed one lost the text field.

Podcasts and audiobooks:
- Resuming after word audio in Lower Volume or Keep Volume mode left the session mixable.
- Original recordings are opened with precise timing; timestamps keep seconds past an hour.
- The five-second listing check decoded on the main actor, rewrote both listing files on every
  poll and kept running under the transcript.
- An imported audiobook position updated the display but not the loaded player.

Privacy:
- A clock set backward by more than the interval sent the anonymous report at once; the interval
  now restarts from the corrected clock. The app language is sent without its region.
- The privacy manifest declares `ProcessInfo.systemUptime` (35F9.1).
- `PRIVACY.md` now mentions cloud translation, the translation history and prompts that HTTP
  sync carries, and the default sync server that first-launch setup uses. **These are statements
  about what the code does; they need the owner's review as policy text.**

Smaller: playback speed is remembered; the slider seeks once on release; a larger timestamp
touch target; the combined play/pause remote command; Now Playing is no longer republished five
times a second; `UIColor.hexString` clamps wide-gamut components; VoiceOver labels and the
selected trait on the bookshelf's icon-only controls; a dictionary archive with an empty, hidden
or path-like title is refused before it is moved into place (the native importer still writes
under the name it was given first, as noted above); leaving the Backup screen clears a cancelled
archive's overlay; a page turn reuses one `Range` instead of making one per text node; the two
compiler warnings in app code are gone. `docs/CHANGELOG.md` now covers the branch's later
features, which were missing from it.

### Reviewed and not changed

- **On-device translations queue and cannot be cancelled.** Requests now outlive the popup by
  design, so five quick taps run five generations in order, after the reader closes too, and
  the model cannot be unloaded on a memory warning meanwhile. Only the wrong streaming text was
  fixed. Whether a newer on-device request should cancel an older one is a product decision.
- Statistics and usage lanes store a GET's ETag header rather than the listed ETag, and bookmark
  shards are never refetched if a server omits ETags. Both depend on the production server,
  which currently matches. One reader-preference record dated more than a day ahead stalls
  preference sync until the clock catches up.
- A sync token that survives reinstalling the app in the Keychain is used with the default
  server address. The app declares multiple-scene support but presents readers in the first
  connected scene. Bulk selection stores whole metadata values, so a reload can strand one.
- Sentence breaks around block images can add an empty last page. Manga opens on the local page
  while a remote position is in flight, so a swipe in that moment can win over it. A rotation
  during a manga page turn can freeze the old snapshot for two seconds.
- Sentence mode saves no progress for a book without chapter metrics.
- The shelf's progress labels are not refreshed when a poll moves a position; a full shelf
  reload for that would bring back the stall this branch removed.
- The fallback from a failed cloud request to a stored pre-translation never triggers, because
  the clients wrap the URL error. The first-launch dictionary download cannot be skipped while it
  runs. Downloaded podcast lessons cannot be deleted individually.
- Test strength: 53 of the Python regression tests assert that strings exist in Swift source;
  the podcast UI test can pass without audio playing; `StatisticsSyncUITests` performs no sync.
- `FirstLaunchSetup` is created before the migration out of Documents and creates the
  dictionary folders, so an upgrade from a build older than April 2026 would skip migrating
  its dictionaries. This does not affect an installation that has already migrated.
- Smaller suggestions not taken: the AI key is read from the Keychain on every pass of the manga
  toolbar; a popup rebuilds its entries whenever its parent redraws; cloud translation requests
  stop after 90 s; the dictionary search field selects all on every update while focused; a
  failed manual dictionary import removes the dictionary it was replacing; an EPUB that is
  already in the library is skipped without a message; shelves do not remember being expanded;
  shelf titles do not follow Dynamic Type; the day-rollover timer in Statistics is created in
  the view body; one unreadable dictionary image stops a whole AnkiConnect export.

Not read by any reviewer: `Features/News`, the Google Drive handlers, `Core/LookupEngine`,
`Core/LocalFileServer`, `scrollreader.js`, the manga crop views, and the bodies of several hosted
test files. iPad layout, Dynamic Type and VoiceOver were not checked at run time.

### Verification

`build/parity-python/bin/python tools/test_ios_parity.py` exited **0** on `3ebbb31`, the last
code commit of this pass:

- **20** real-server tests and **108** Python regressions passed.
- **339** hosted XCTest cases passed with zero failures or skipped scenarios: the 333 the
  branch had, and six added here.
- **8** UI cases passed: both bookshelf navigation cases, cloud manga download, both podcast
  scenarios, Statistics, zoomed manga selection and thin manga action buttons.
- In that run the poll measured 2.50 ms on its first pass, 2.83 ms over later ones, 1.86 ms in a
  statistics pass and 2.21 ms after a reading save, with heartbeat gaps of 3 ms or less. The
  rendered shelf scrolled through four real polls with 980 display callbacks and a longest gap of
  17 ms. A manga page turn took 6.91 ms CPU / 7.26 ms wall. The 57-page chapter was paginated
  in 969 ms, and the single-file book was left alone in 7 ms.

The gate also passed on the untouched branch and once more before the last small commit. The
page-turn assertion read 8.19 ms once, while a WebKit timing harness was running on the same Mac;
alone it reads 6.5–7.3 ms. Timing tests need an otherwise idle machine.

Tests added, each failing without its fix where it guards one:
`testPagedReaderReturnsToItsPageWhenThePageProcessEndsAndADeadPageCannotTurnTheChapter`,
`testVerticalRestoreFindsItsPageWhenParagraphsOpenWithALineBreak`,
`testLongChaptersPaginateQuicklyAndASingleFileBookIsLeftAlone`,
`testFixedGrammarKeysAgreeWithTheFormatterInEveryZoneAndForMalformedText`,
`testUsageKeysParseWithoutAFormatterAndRejectWhatTheServerMustNotSend`,
`testABackupIsOnlyRestoredOverTheKindOfCollectionItHolds`, and the usage keys in the
large-library poll test.

Not verified here: chapter opening time and recovery from a discarded page on the physical iPad;
the 1–2 px line differences were measured in macOS WebKit and not looked at on a device; the
restore confirmation and refusal messages, the screen for a book that cannot be opened, the
VoiceOver labels and the podcast slider have no UI test and were not tried by hand.

Logs (ignored): `build/claude-baseline-gate.log`, `build/claude-final-gate.log`,
`build/claude-final-gate-2.log`, `build/ios-sync-integration.log`, `build/ios-parity-ui.log`.
