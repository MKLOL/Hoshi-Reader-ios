# What was done: branch `codex/ios-android-parity`

None of this is pushed. This file is not committed.

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
