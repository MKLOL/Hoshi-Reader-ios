# Android → iOS parity (September 2026)

Android target: `8d099345` (0.11.17). iOS starting point: `0fc98d1`.
The shared September 9 sync shortcut/zoom reset is the baseline. Earlier fork additions are also checked for missed ports.

Each Android commit is accounted for below. Follow-up fixes are implemented with the feature they correct; release numbers and Android platform plumbing do not transfer to iOS.

| Android commit | Date | Change | iOS disposition |
| --- | --- | --- | --- |
| `d03cc3d9` | 2026-09-09 | docs: record iOS archive import issue found during sync checks | Documentation: reviewed with related feature |
| `52995287` | 2026-09-10 | fix: resolve review findings and release 0.11.9 | Pending review/port |
| `387e8c84` | 2026-09-10 | fix: restore fitted manga swipes and show current news | Ported: current sources, dated ordering, dedupe, OCR overflow containment |
| `66705e69` | 2026-09-12 | docs: keep the validation handoff short and clarify the Watanoc default | Documentation: reviewed with related feature |
| `595167fc` | 2026-09-12 | chore: release 0.11.10 | No app port: release metadata |
| `30d538d5` | 2026-09-12 | feat(statistics): track reading time automatically and list it per book | Ported: automatic tracking, device rows, statistics UI/sync and opening budget; 9 behavior tests pass |
| `1f3fce8b` | 2026-09-12 | chore: release 0.11.11 | No app port: release metadata |
| `034dbc82` | 2026-09-12 | feat(statistics): count the characters of manga text read | Ported: automatic tracking, device rows, statistics UI/sync and opening budget; 9 behavior tests pass |
| `b9519803` | 2026-09-12 | chore: release 0.11.12 | No app port: release metadata |
| `08349cad` | 2026-09-12 | fix(statistics): read the same totals everywhere and reload on every change | Ported: automatic tracking, device rows, statistics UI/sync and opening budget; 9 behavior tests pass |
| `34182480` | 2026-09-12 | feat(statistics): Statistics screens with streak, heatmap, per-book detail | Ported: automatic tracking, device rows, statistics UI/sync and opening budget; 9 behavior tests pass |
| `ac997538` | 2026-09-12 | feat(sync): merge reading statistics between devices over HTTP sync | Ported: automatic tracking, device rows, statistics UI/sync and opening budget; 9 behavior tests pass |
| `641e6163` | 2026-09-12 | style(statistics): drop seconds from hour-long durations and group digits in the manga sheet | Ported: automatic tracking, device rows, statistics UI/sync and opening budget; 9 behavior tests pass |
| `f0311968` | 2026-09-12 | fix(statistics): sync stale-check by stamp, Drive options back, lazy book rows | Ported: automatic tracking, device rows, statistics UI/sync and opening budget; 9 behavior tests pass |
| `22f52731` | 2026-09-12 | fix(sync): deterministic statistics tie-break, no idle GETs, scheduler edge cases | Ported: automatic tracking, device rows, statistics UI/sync and opening budget; 9 behavior tests pass |
| `93ad8e4d` | 2026-09-12 | fix(statistics): survive clock skew and reader hand-offs without losing a session | Ported: automatic tracking, device rows, statistics UI/sync and opening budget; 9 behavior tests pass |
| `3f6cfc9d` | 2026-09-12 | perf(reader): open manga and books without waiting on the sync server | Ported: automatic tracking, device rows, statistics UI/sync and opening budget; 9 behavior tests pass |
| `c75b955b` | 2026-09-12 | feat(statistics): keep reading statistics per device | Ported: automatic tracking, device rows, statistics UI/sync and opening budget; 9 behavior tests pass |
| `9ac6464c` | 2026-09-13 | chore: release 0.11.13 | No app port: release metadata |
| `ab74ab90` | 2026-09-21 | feat(podcasts): add authenticated NHK learning lessons | Ported: native iOS podcast catalogue, account isolation, downloads, playback and final server contract; 7 behavior tests pass |
| `0611f589` | 2026-09-21 | fix(news): keep headline furigana and upright digits in saved articles | Pending review/port |
| `88bd2ca4` | 2026-09-21 | feat(news): let the user write the pre-translation instructions | Pending review/port |
| `d505d02e` | 2026-09-21 | fix(podcasts): list episodes over an hour and unknown lengths | Ported: native iOS podcast catalogue, account isolation, downloads, playback and final server contract; 7 behavior tests pass |
| `d5b181a5` | 2026-09-21 | fix(podcasts): remember where a seek landed, not where it left | Ported: native iOS podcast catalogue, account isolation, downloads, playback and final server contract; 7 behavior tests pass |
| `f29fd479` | 2026-09-21 | fix(podcasts): drop a replaced or rejected account's lessons and keep its marker off backups | Ported: native iOS podcast catalogue, account isolation, downloads, playback and final server contract; 7 behavior tests pass |
| `9b499ac7` | 2026-09-21 | fix(podcasts): let deferred and retried downloads run from the background | Ported: native iOS podcast catalogue, account isolation, downloads, playback and final server contract; 7 behavior tests pass |
| `2927f1ec` | 2026-09-21 | fix(podcasts): keep the list across stop and start, show waiting downloads, handle a vanished file | Ported: native iOS podcast catalogue, account isolation, downloads, playback and final server contract; 7 behavior tests pass |
| `c9c2f6f1` | 2026-09-21 | fix(podcasts): construct the repository lazily | Ported: native iOS podcast catalogue, account isolation, downloads, playback and final server contract; 7 behavior tests pass |
| `159134d5` | 2026-09-21 | docs(podcasts): state the verification honestly and pin the tab order and route | Documentation: reviewed with related feature |
| `c834112e` | 2026-09-21 | fix(podcasts): retire other accounts' lessons only after the new pair validates | Ported: native iOS podcast catalogue, account isolation, downloads, playback and final server contract; 7 behavior tests pass |
| `f287d50d` | 2026-09-21 | feat(podcasts): show why a lesson, download or playback failed and whether the worker is up | Ported: native iOS podcast catalogue, account isolation, downloads, playback and final server contract; 7 behavior tests pass |
| `afbe936e` | 2026-09-21 | fix(podcasts): localize failure reasons, bound server text, and trust only what the server states | Ported: native iOS podcast catalogue, account isolation, downloads, playback and final server contract; 7 behavior tests pass |
| `8d32636a` | 2026-09-21 | fix(podcasts): collapse Unicode separators and control characters in server text | Ported: native iOS podcast catalogue, account isolation, downloads, playback and final server contract; 7 behavior tests pass |
| `31dd71e8` | 2026-09-21 | test(statistics): compare canonical paths so macOS temp directories pass | Pending review/port |
| `d50731bb` | 2026-09-21 | chore: release 0.11.14 | No app port: release metadata |
| `d8f787d9` | 2026-09-22 | feat(tools): add agent-authored news EPUB publisher | Pending review/port |
| `5399683b` | 2026-09-23 | feat(ai): expand the default manga tutor prompt | Pending review/port |
| `f0bcfec5` | 2026-09-23 | feat(manga): hide the bubble Copy button by default and enlarge Translate | Pending review/port |
| `d988d908` | 2026-09-23 | feat(statistics): log reader usage events for timeline reconstruction | Pending review/port |
| `5fe395a2` | 2026-09-23 | feat(statistics): lead with a Today card and add 3-day-average trend charts | Pending review/port |
| `c4b42a4a` | 2026-09-23 | feat(statistics): list only words looked up more than once on the Today card | Pending review/port |
| `ba78936d` | 2026-09-23 | feat(statistics): move charts to a Trends tab and add per-bubble trends | Pending review/port |
| `24d80938` | 2026-09-23 | fix(statistics): address review findings on the usage log and trends | Pending review/port |
| `2b15b3c9` | 2026-09-23 | chore: release 0.11.15 | No app port: release metadata |
| `8f7ea378` | 2026-09-24 | fix(statistics): drop today's rows from the totals card | Pending review/port |
| `12d283b5` | 2026-09-24 | feat(podcasts): filter the episode list by show | Ported: native iOS podcast catalogue, account isolation, downloads, playback and final server contract; 7 behavior tests pass |
| `cf9c3fbf` | 2026-09-24 | chore: release 0.11.16 | No app port: release metadata |
| `1c9b9f12` | 2026-09-24 | feat(podcasts): show what the server is doing while a lesson is prepared | Ported: native iOS podcast catalogue, account isolation, downloads, playback and final server contract; 7 behavior tests pass |
| `653a8819` | 2026-09-24 | fix(podcasts): retain offline lessons and expire stale generation state | Ported: native iOS podcast catalogue, account isolation, downloads, playback and final server contract; 7 behavior tests pass |
| `8d099345` | 2026-09-24 | chore: release 0.11.17 | No app port: release metadata |

## Validation

Pending: simulator build, behavioral regression tests, and three independent reviews.
