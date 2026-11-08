# Changelog

## [Unreleased]

### Added

- First-launch setup can save a shared sync token and install the recommended JMdict and Jiten dictionaries. Missing setup is offered again after a restore.
- Manga available on your sync server appear under **Not downloaded**. Tap covers to download them one after another: each shows Waiting, a filling ring and Finishing, then moves onto its shelf as soon as its own download is done. Downloads can be cancelled individually and retried; interrupted downloads resume, and the reading position arrives before the manga opens. Chats, translations or statistics that cannot be read never block the download; they follow with a later sync.
- Manga OCR bubbles show offline furigana by default. Long text scrolls inside its bubble, and nearby pages prepare three ahead and two behind for faster turns.
- Sentence reading offers stacked and side-by-side Japanese/English panes. Sentence turns update the regular bookmark and reading statistics, and **Finish book** records completion.
- Manga, EPUB, shared appearance, Popup Cards and Sasayaki reading preferences sync across devices, including resets to defaults. Custom font files still need importing on each device.
- Optional anonymous usage reporting has a 20-hour first-report delay and a switch in **Settings → Advanced**. Reports exclude reading content, titles, credentials and sync addresses; turning it off removes the local report identifier.

- Today, repeated words, manga bubble and translation counts, reading timelines and trends include activity from every device using HTTP sync. Logs upload as compressed daily files and compact older months automatically.

- HTTP sync keeps reading history for every book, including books never downloaded here and books deleted from any device. Statistics shows when other devices were checked and marks books that are no longer installed.
- Streak goals, day reset settings and reading time zones sync across devices. Every device counts the same Eastern Time days by default, including recoverable older readings recorded in another zone. Reading time is sent while you read, with independent bookmark transfers and a final flush when leaving the reader.

- Listen to a podcast's original recording with a following Japanese transcript and offline furigana. Tap a timestamp to play from that line, tap a word to pause and look it up, and optionally reveal English. The transcript uses the EPUB reader's text layout and font settings. Furigana sits above its kanji without repeating kana endings, and Appearance provides the shared font and furigana controls. Lessons and original recordings remember separate positions.
- Set the daily reading goal from 1 to 120 minutes and choose when the reading day resets, defaulting to 3am. Statistics use the same boundary throughout, with optimistic streak reconstruction for older history.
- See pretranslation badges on books, manga and collapsed shelves.
- See transfer speed and estimated remaining time during HTTP sync, cancel a sync, and remove inactive interrupted downloads from HTTP settings.
- Choose whether manga enlarges small OCR text. The Translate button is slightly larger when displayed alone.

### Changed

- Manga Statistics shows saved All Time totals first. Time to finish uses the median time of completed pages, so a page left open does not skew it; the pace is kept after closing the book and syncs across devices. Jumps, backward turns and time in the background add no samples.
- Reading options are grouped under **App & reading**, **Manga**, **EPUB** and **Popup Cards**.
- Closing a translation popup or leaving its reader keeps the request running and saves its reply to history. The history button shows running or unseen replies, and failed requests offer Retry. iOS background execution remains subject to the system's time allowance.
- Reading positions retain recent navigation and causal heads from each device. Reopening a book preserves its timestamp; backward moves, offline navigation and explicit ッツ imports survive synchronization.
- Normal EPUB pages keep Japanese words and ruby together and prefer sentence boundaries while preserving publisher line breaks and illustrations.

### Fixed

- Covers whose image is not book-shaped, such as a two-page spread, fill their place on the shelf instead of being stretched.
- Manga reading time no longer counts while the app is in the background after a slow book load. Reading days whose midnight is skipped or repeated by daylight saving time keep their reading and streak, and the goal bar matches the streak.
- The first tap outside a dictionary popup closes it before another word or reader control acts.
- Audiobooks keep playing through chapter restoration, and a playing audiobook keeps its page when another device's position arrives or the app returns to the foreground; Anki audio preparation runs off the main thread.
- Importing the same ッツ statistics on multiple devices counts the shared history once. Imports preserve current reading, cleared imported history stays cleared after sync, and finished books retain 100% progress.

- Statistics stays responsive while browsing per-device reading history.
- Downloaded font collections use the selected reading face in native sentence text, including regular Klee and the horizontal Kyokasho variant.
- Book downloads continue through background suspension and retain resumable progress after interruptions.
- Recover missing reading history even when the library otherwise appears unchanged, and preserve updates made while statistics are syncing.
- AnkiConnect no longer reports a card as added when media storage or the returned note result failed.
- Cancelling a backup restore before it commits preserves the current collection.
