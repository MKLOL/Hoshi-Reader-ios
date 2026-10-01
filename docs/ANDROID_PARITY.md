# Android → iOS parity (October 2026)

Android target: `2cf591e0`, including 0.11.18–0.12.0 and the subsequent podcast transcript, sync, and reading-day fixes. iOS starting point: `980619f`. The September audit below remains the baseline.

| Android changes | iOS behavior |
| --- | --- |
| `0d6524f4` | Original podcast recording with timed Japanese transcript; tap a timestamp to play there, tap a word to pause and open the reader's dictionary, following highlight, optional English, independent lesson/original resume positions. Bounded transcript validation precedes the background audio download. |
| `a773b55e`, `5092583b`, `2cf591e0` | 1–120-minute streak goal and adjustable reading-day boundary, default 3am. Today, history, heatmaps, per-book/device days, reader sheets and usage/trends share the boundary. Android-compatible hourly evidence allows recalculation; uncertain old history receives optimistic streak credit without inflating displayed reading totals. |
| `ca507c53`, `a88f3917` | Statistics preserve richer hourly evidence, compare ETags, re-read local changes around network awaits, and recover missing local history before an unchanged-sync fast return. Manual sync waits for an older background pass before making a fresh check. Server URL drafts and account-scoped cursors remain correct while editing. |
| `0977fa16`, `78b17dca`, `0f6b3f80` | OS-owned background book downloads, durable resume checkpoints and verified archive reuse; MB/s and per-file ETA; cancellation; inactive interrupted-download cleanup; lazy pretranslation badges on novels, manga and collapsed shelves. |
| `a15a0388`, `3231c87b` | Enlarge Small Text toggle for manga and a solo Translate action about 30% larger in area than a paired action. Existing native popup sizing and action clearance already provide the earlier tablet behavior. |
| `7fed544a` | Live dictionary/translation card controls were already ported in iOS `980619f`. |
| `a88f3917` remaining safety fixes | Strict AnkiConnect success/media responses and cancellation before backup restoration commits. Existing iOS atomic sidecars, content-derived media names, canonical Unicode equality, 64-bit TTU IDs, native literal filename handling and single EPUB parsing already supply the corresponding behavior. |
| Android release/build/BOOX internals | APK signing/updating, WorkManager/UIDT plumbing and Android density policies do not transfer to iOS. iOS uses Foundation background URLSession/AVPlayer. The release regression gate is ported to `ship.sh` with a disposable simulator. |

## Current verification

Run `python3 tools/test_ios_parity.py` for the full regression gate with Xcode, Node.js and the pretranslation tool's `regex` Python dependency available. For an isolated Python setup, create `build/parity-python` with `python3 -m venv build/parity-python`, install `regex>=2024.5.15` there, then activate it before invoking the gate or `ship.sh`.

The gate creates and deletes its own iPhone simulator, runs the KV server's contract tests, and runs all hosted XCTest cases against the real local server plus the existing Python/Swift/JavaScript regressions. It then requires both the clickable podcast transcript and its Appearance UI scenarios to pass. `ship.sh` invokes this gate before a version bump or archive. Direct integration-runner use requires an explicitly selected disposable simulator; missing prerequisites and omitted critical scenarios fail the gate.

The suites cover transcript validation and staged publication, authenticated background downloads, playback identities and seeks, WebKit selection and dictionary context, reading-day reconstruction, statistics recovery, book-transfer resume, badges, manga sizing, Anki responses and restore cancellation. Transcript tests host the production WKWebView with its bundled EPUB selection and shared furigana code. They verify native ruby layout, okurigana alignment, wrapping, live appearance changes, timestamp isolation, following and font-load scroll races. Podcast XCUITests use synthetic local content and exercise the actual controls.

The complete gate passed: 19 KV-server contract tests, 100 regression checks (including the hosted runner), 147 hosted XCTest cases, and both required podcast UI scenarios, with no failures or skips. Both UI scenarios also passed separately on an iPad simulator. Screenshots were inspected on both screen sizes. The retained full-screen sentence reader also has a hosted regression for initialization, centering, Unicode glyph taps and long-text scrolling. Three reviewers checked shared EPUB typography, furigana alignment, selection and playback interactions, test coverage and rendered screenshots. Confirmed findings included preserving paragraph identity during asynchronous selection, safely injecting CSS containing escaped font names, and preventing delayed font completion from overriding a newer scroll.

Physical-device suspension/relaunch and lock-screen audio still require a device check; simulator results do not claim to verify those OS conditions. Book downloads use the durable background session; multipart uploads retain the existing foreground session and brief background execution allowance.

---

# September 2026 baseline

Android target: `8d099345` (0.11.17). iOS starting point: `0fc98d1`.
The shared September 9 sync shortcut/zoom reset is the baseline. Earlier fork additions are also checked for missed ports.

All 52 Android commits in the target range, including both merges, are accounted for below. Follow-up fixes are implemented with the feature they correct; release numbers and Android platform plumbing do not transfer to iOS.

| Android commit | Date | Change | iOS disposition |
| --- | --- | --- | --- |
| `d03cc3d9` | 2026-09-09 | docs: record iOS archive import issue found during sync checks | Documentation: reviewed with related feature |
| `52995287` | 2026-09-10 | fix: resolve review findings and release 0.11.9 | Ported/reviewed: contained EPUB URLs and nested contents, Anki refresh mappings, shelf idempotence and incomplete reruns. iOS ZIP64/backup staging, serialized history and chronological settings already present; APK updater/Android audio copies do not apply. |
| `387e8c84` | 2026-09-10 | fix: restore fitted manga swipes and show current news | Ported: current sources, dated ordering, dedupe, OCR overflow containment |
| `66705e69` | 2026-09-12 | docs: keep the validation handoff short and clarify the Watanoc default | Documentation: reviewed with related feature |
| `595167fc` | 2026-09-12 | chore: release 0.11.10 | No app port: release metadata |
| `30d538d5` | 2026-09-12 | feat(statistics): track reading time automatically and list it per book | Ported: automatic tracking, device rows, statistics UI/sync and opening budget; 24 statistics tests pass |
| `1f3fce8b` | 2026-09-12 | chore: release 0.11.11 | No app port: release metadata |
| `034dbc82` | 2026-09-12 | feat(statistics): count the characters of manga text read | Ported: automatic tracking, device rows, statistics UI/sync and opening budget; 24 statistics tests pass |
| `b9519803` | 2026-09-12 | chore: release 0.11.12 | No app port: release metadata |
| `08349cad` | 2026-09-12 | fix(statistics): read the same totals everywhere and reload on every change | Ported: automatic tracking, device rows, statistics UI/sync and opening budget; 24 statistics tests pass |
| `34182480` | 2026-09-12 | feat(statistics): Statistics screens with streak, heatmap, per-book detail | Ported: automatic tracking, device rows, statistics UI/sync and opening budget; 24 statistics tests pass |
| `ac997538` | 2026-09-12 | feat(sync): merge reading statistics between devices over HTTP sync | Ported: automatic tracking, device rows, statistics UI/sync and opening budget; 24 statistics tests pass |
| `641e6163` | 2026-09-12 | style(statistics): drop seconds from hour-long durations and group digits in the manga sheet | Ported: automatic tracking, device rows, statistics UI/sync and opening budget; 24 statistics tests pass |
| `f0311968` | 2026-09-12 | fix(statistics): sync stale-check by stamp, Drive options back, lazy book rows | Ported: automatic tracking, device rows, statistics UI/sync and opening budget; 24 statistics tests pass |
| `22f52731` | 2026-09-12 | fix(sync): deterministic statistics tie-break, no idle GETs, scheduler edge cases | Ported: automatic tracking, device rows, statistics UI/sync and opening budget; 24 statistics tests pass |
| `93ad8e4d` | 2026-09-12 | fix(statistics): survive clock skew and reader hand-offs without losing a session | Ported: automatic tracking, device rows, statistics UI/sync and opening budget; 24 statistics tests pass |
| `3f6cfc9d` | 2026-09-12 | perf(reader): open manga and books without waiting on the sync server | Ported: automatic tracking, device rows, statistics UI/sync and opening budget; 24 statistics tests pass |
| `c75b955b` | 2026-09-12 | feat(statistics): keep reading statistics per device | Ported: automatic tracking, device rows, statistics UI/sync and opening budget; 24 statistics tests pass |
| `9ac6464c` | 2026-09-13 | chore: release 0.11.13 | No app port: release metadata |
| `ab74ab90` | 2026-09-21 | feat(podcasts): add authenticated NHK learning lessons | Ported: native iOS podcast catalogue, account isolation, downloads, playback and final server contract; 13 podcast tests pass |
| `0611f589` | 2026-09-21 | fix(news): keep headline furigana and upright digits in saved articles | Ported: headline ruby, upright Japanese digits, remembered cloud instructions; 18 news tests pass |
| `88bd2ca4` | 2026-09-21 | feat(news): let the user write the pre-translation instructions | Ported: headline ruby, upright Japanese digits, remembered cloud instructions; 18 news tests pass |
| `bfd78d89` | 2026-09-21 | merge news typesetting and custom prompts | Merge reviewed: constituent news changes are covered above; combined diff only reconciles the changelog. |
| `d505d02e` | 2026-09-21 | fix(podcasts): list episodes over an hour and unknown lengths | Ported: native iOS podcast catalogue, account isolation, downloads, playback and final server contract; 13 podcast tests pass |
| `d5b181a5` | 2026-09-21 | fix(podcasts): remember where a seek landed, not where it left | Ported: native iOS podcast catalogue, account isolation, downloads, playback and final server contract; 13 podcast tests pass |
| `f29fd479` | 2026-09-21 | fix(podcasts): drop a replaced or rejected account's lessons and keep its marker off backups | Ported: native iOS podcast catalogue, account isolation, downloads, playback and final server contract; 13 podcast tests pass |
| `9b499ac7` | 2026-09-21 | fix(podcasts): let deferred and retried downloads run from the background | Ported: native iOS podcast catalogue, account isolation, downloads, playback and final server contract; 13 podcast tests pass |
| `2927f1ec` | 2026-09-21 | fix(podcasts): keep the list across stop and start, show waiting downloads, handle a vanished file | Ported: native iOS podcast catalogue, account isolation, downloads, playback and final server contract; 13 podcast tests pass |
| `c9c2f6f1` | 2026-09-21 | fix(podcasts): construct the repository lazily | Ported: native iOS podcast catalogue, account isolation, downloads, playback and final server contract; 13 podcast tests pass |
| `159134d5` | 2026-09-21 | docs(podcasts): state the verification honestly and pin the tab order and route | Documentation: reviewed with related feature |
| `c834112e` | 2026-09-21 | fix(podcasts): retire other accounts' lessons only after the new pair validates | Ported: native iOS podcast catalogue, account isolation, downloads, playback and final server contract; 13 podcast tests pass |
| `f287d50d` | 2026-09-21 | feat(podcasts): show why a lesson, download or playback failed and whether the worker is up | Ported: native iOS podcast catalogue, account isolation, downloads, playback and final server contract; 13 podcast tests pass |
| `afbe936e` | 2026-09-21 | fix(podcasts): localize failure reasons, bound server text, and trust only what the server states | Ported: native iOS podcast catalogue, account isolation, downloads, playback and final server contract; 13 podcast tests pass |
| `8d32636a` | 2026-09-21 | fix(podcasts): collapse Unicode separators and control characters in server text | Ported: native iOS podcast catalogue, account isolation, downloads, playback and final server contract; 13 podcast tests pass |
| `7b4b73cd` | 2026-09-21 | merge statistics and reader updates with podcasts | Merge reviewed: constituent commits are covered above; combined navigation wires Statistics alongside News/Podcasts, covered by the native bookshelf Statistics route. |
| `31dd71e8` | 2026-09-21 | test(statistics): compare canonical paths so macOS temp directories pass | Covered by iOS canonical-path migration and payload regression tests; Android test fixture-only fix. |
| `d50731bb` | 2026-09-21 | chore: release 0.11.14 | No app port: release metadata |
| `d8f787d9` | 2026-09-22 | feat(tools): add agent-authored news EPUB publisher | Ported tools/news and hoshi-news instructions; 19 isolated publisher tests pass. No publishing performed. |
| `5399683b` | 2026-09-23 | feat(ai): expand the default manga tutor prompt | Ported: expanded tutor prompt, optional Copy button, private usage log, Today and Trends; 8 usage tests pass |
| `f0bcfec5` | 2026-09-23 | feat(manga): hide the bubble Copy button by default and enlarge Translate | Ported: expanded tutor prompt, optional Copy button, private usage log, Today and Trends; 8 usage tests pass |
| `d988d908` | 2026-09-23 | feat(statistics): log reader usage events for timeline reconstruction | Ported: expanded tutor prompt, optional Copy button, private usage log, Today and Trends; 8 usage tests pass |
| `5fe395a2` | 2026-09-23 | feat(statistics): lead with a Today card and add 3-day-average trend charts | Ported: expanded tutor prompt, optional Copy button, private usage log, Today and Trends; 8 usage tests pass |
| `c4b42a4a` | 2026-09-23 | feat(statistics): list only words looked up more than once on the Today card | Ported: expanded tutor prompt, optional Copy button, private usage log, Today and Trends; 8 usage tests pass |
| `ba78936d` | 2026-09-23 | feat(statistics): move charts to a Trends tab and add per-bubble trends | Ported: expanded tutor prompt, optional Copy button, private usage log, Today and Trends; 8 usage tests pass |
| `24d80938` | 2026-09-23 | fix(statistics): address review findings on the usage log and trends | Ported: expanded tutor prompt, optional Copy button, private usage log, Today and Trends; 8 usage tests pass |
| `2b15b3c9` | 2026-09-23 | chore: release 0.11.15 | No app port: release metadata |
| `8f7ea378` | 2026-09-24 | fix(statistics): drop today's rows from the totals card | Ported: expanded tutor prompt, optional Copy button, private usage log, Today and Trends; 8 usage tests pass |
| `12d283b5` | 2026-09-24 | feat(podcasts): filter the episode list by show | Ported: native iOS podcast catalogue, account isolation, downloads, playback and final server contract; 13 podcast tests pass |
| `cf9c3fbf` | 2026-09-24 | chore: release 0.11.16 | No app port: release metadata |
| `1c9b9f12` | 2026-09-24 | feat(podcasts): show what the server is doing while a lesson is prepared | Ported: native iOS podcast catalogue, account isolation, downloads, playback and final server contract; 13 podcast tests pass |
| `653a8819` | 2026-09-24 | fix(podcasts): retain offline lessons and expire stale generation state | Ported: native iOS podcast catalogue, account isolation, downloads, playback and final server contract; 13 podcast tests pass |
| `8d099345` | 2026-09-24 | chore: release 0.11.17 | No app port: release metadata |

## Earlier fork audit

The earlier Android history was checked against the existing iOS port, including:

| Android commits | iOS result |
| --- | --- |
| `1b0bcfa4`, `0261e823`, `86bc98bb`, `09ab9509`, `1b0cce34`, `ef5075ba` | Native dictionary work now runs on a serial worker with locked query/media lifetime, owned media bytes, cancellable/stale-result-safe reader callbacks, and code-point-safe selection. Fractional OCR font search fixed. |
| `940230b5`, `6b4f43de`, `fae05632`, `6b7656e2` | Ported CSS Highlight cue ranges without text reflow, whole-ruby highlighting, continuous range scrolling aligned to the leading edge, and nested column-count reset. Keep wrapper fallback for text emphasis/older WebKit; refresh cue ranges after highlights/translations mutate the DOM. |
| `2dd0fbbe` | Chromium vertical-ruby line-breaking workaround evaluated separately; WebKit pagination retains its existing layout. The workaround splits adjacent Japanese text nodes without adding a user-facing feature. |
| `9779258b` | Existing iOS appearance/custom font controls. |
| `939f0fc3`, `5e3c3a06`, `fbe61877` | Android e-ink/system language features; iOS already intentionally removed e-ink controls in `8454f62`, uses native platform language handling. |
| `1022b0b5`, `f76da44b`, `6ce92d75`, `8fac3812`, `c1c10185`, `f6cad585`, `f33b3ce5`, `139a49ef` | Existing native GGUF downloads/resume/storage/streaming/reasoning controls and legacy catalog retention; added missing Qwen3.5 0.8B. Preserve iPad-safe 9B quantization. |
| `648b964c` | Android KleidiAI acceleration; iOS already uses Metal/llama.cpp. |
| `c913b4f4` | Existing iOS version/build display; Android release metadata does not transfer. |
| `7796e068`, `3c9cb536`, `071cbc75`, `463303d2`, `72d6b825`, `819d3e1f` | Existing Sui tutor, providers, popup sizing/anchors and high-resolution screenshots (`c9e1dfe`, `eafdbda`, `376bae0`); new default prompt supersedes Sui text. |
| `490a9e53` | Always-on HTTP auto-push ported; configured endpoint/token determines activation. |
| `ff0d188b`, `7817869f`, `7c0552c2`, `c1c43b69`, `d6230cea`, `aed6f1bb` | Existing bubble/sentence pretranslations, Textual Markdown tables, EPUB restoration/import and payload sync (`7413ff6`, `ec04a62`, `61da9e7`). |
| `fae2449d`, `66782469`, `bf1cad71`, `895920f8`, `671f58eb`, `cbcd75fc` | Existing bookmark maps, chronological conflict handling, atomic sidecars and payload hashing (`fd79a86`, `a3cd144`, `8800411`, `34260f3`). |
| `3a725ce1`, `f66bd69d` | Existing sentence furigana and News pipeline (`b78690e`, `ac1b88b`, `448ed7a`), updated by later news commits above. |

## Validation

Three independent reviewers completed the coverage/reader/news, statistics/usage/sync, and podcast reviews. All confirmed findings were fixed and regression-tested. These included EPUB extraction and resource containment, dictionary concurrency and Unicode offsets, Anki mapping refresh, statistics migration and deterministic merges, corrupt-statistics isolation, podcast account restoration, cancellation/retry races, and playback/audio ownership.

Two additional independent reviewers then rechecked completeness and runtime behavior before the push to `main`. Their findings were fixed: manga reveal messages now carry the actual page/block ID and OCR text, so bubble totals and per-bubble trends count each bubble; opening sentence mode no longer closes the usage session or releases the active-book reservation. Reading-time updates continue while covered, pause in the background, and stop when the reader window closes. Closing that window also dismisses a nested sentence mode. The added regressions execute the production manga JavaScript and present the actual native reader/sentence views.

Final validation on September 25, 2026:

| Check | Result |
| --- | --- |
| Release simulator build | Passed for arm64 and x86_64 with the final review fixes |
| iOS simulator XCTest suite | 76 passed: 7 feature parity, 18 news, 13 podcasts, 24 statistics, 6 real-server sync, 8 usage |
| Simulator UI checks | 4 passed: translation long press, repeated AI button, page-jump zoom/swipe, Translate-only bubble and statistics tabs; screenshots inspected |
| EPUBKit package | 68 passed, including concurrent extraction and corrupt-archive regressions |
| Source/behavior regressions (Python, Node, Swift) | 84 passed, 1 skipped because the legacy external whole-EPUB fixture is unavailable |
| News publisher | 19 passed |
| Local HTTP sync server | 15 passed |

The real-server suite used the production iOS sync stack, a local HTTP server and the Android conformance corpus. It also verified that corrupt statistics do not block bookmarks, settings or another book's statistics, and do not acknowledge convergence. Tests ran on a dedicated disposable iPhone simulator (iOS 27, Xcode 27 beta); no user simulator data was erased.

Reproduce the simulator/integration run from the iOS repository, substituting an available disposable simulator name:

```sh
HOSHI_IOS_SIMULATOR='Hoshi Parity Review iPhone' \
HOSHI_XCODEBUILD_ARGS='-IDEPackageEnablePrebuilts=NO CODE_SIGN_IDENTITY=- -parallel-testing-enabled NO -collect-test-diagnostics never' \
python3 -m unittest discover -s Tests/Regression -p test_sync_integration.py -v
```

The extra Xcode arguments avoid beta SwiftSyntax prebuilt-module and post-test diagnostic-collection issues and use local signing. The runner writes `build/ios-sync-integration.log` while tests execute.

Physical-device background relaunch/lock-screen playback and production podcast generation remain unverified. No production credentials, publishing or device deployment were used. iOS background URLSession follows redirects automatically; redirected audio is rejected before publication, as detailed in [IOS_PODCASTS.md](IOS_PODCASTS.md). These checks establish the tested behavior, not an absence of all possible bugs.
