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
- On iPad the tabs have their own bar at the bottom, so all five stay reachable beside the bookshelf's actions in both orientations. **Add manga** is a plus button that opens Files directly; sorting, selection, shelves and EPUB import are under Bookshelf options.
- Manga imports run in the background, one volume after another with progress, and a volume appears on the shelf only when it is complete. **Mark Read** works for manga.
- Podcasts remember the playback speed. Headsets and remotes that send a single play/pause command control podcast playback.
- Restoring a backup asks for confirmation, naming the file, before it replaces anything.

### Changed

- Statistics is redesigned. Today leads with your reading time and shows activity as tiles (manga counts only when you read manga), an hour-by-hour chart of the reading day coloured by book, the day's sessions and wrapping chips of words you looked up more than once. The streak shows a flame, today's progress toward the goal and what is left to keep it, and notes a new record. The goal is saved when you let go of the slider; reading day settings explain themselves and offer this device's time zone only when it differs. The heatmap has month labels and a Less/More legend, weekdays and devices read as labelled rows, and each book shows when it was last read. Trend charts show units, a legend and the selected day's values, tap to select without stealing scrolls, and every date follows the statistics time zone. Reading time reads like "2h 14m" or "45s", empty statistics show a clear message instead of zero charts, and large text sizes stack instead of truncating.
- Manga Statistics shows saved All Time totals first. Time to finish uses the median time of completed pages, so a page left open does not skew it; the pace is kept after closing the book and syncs across devices. Jumps, backward turns and time in the background add no samples.
- Reading options are grouped under **App & reading**, **Manga**, **EPUB** and **Popup Cards**.
- Closing a translation popup or leaving its reader keeps the request running and saves its reply to history. The history button shows running or unseen replies, and failed requests offer Retry. iOS background execution remains subject to the system's time allowance.
- Reading positions retain recent navigation and causal heads from each device. Reopening a book preserves its timestamp; backward moves, offline navigation and explicit ッツ imports survive synchronization.
- Normal EPUB pages keep Japanese words and ruby together and prefer sentence boundaries while preserving publisher line breaks and illustrations.
- Chapters with that layout open quickly: a 50-page vertical chapter is ready in about a third of a second instead of over four seconds, and a 100-page one in under a second instead of thirteen. With the default line height, text and furigana are laid out as before. With a custom line height, a line with furigana after a paragraph's first is 1–3 px tighter, now the same as the first, and lines that hold enlarged inline text or superscripts can be a pixel or two taller. If a very long chapter cannot be finished within its time budget, the rest of it keeps ordinary page breaks, and a whole book in a single file keeps the publisher's layout.
- Manga opens on its saved page at once instead of waiting for sync; a newer position from another device still arrives a moment later.
- The first-launch dictionary download retries, falls back to GitHub's release service when the direct download fails, and reports the step that failed. A dictionary import that was interrupted is no longer listed as installed.
- Podcast playback: dragging the position slider seeks once when released, timestamps keep their seconds past the first hour and are easier to tap, and original recordings are timed precisely so the highlighted line stays with the sound.
- A translation shown from the stored pre-translation offers **Get a fresh translation**. An on-device translation waiting for an earlier one says so instead of showing the other bubble's reply.
- `install.sh` installs the optimised Release build by default; `CONFIG=Debug` selects the unoptimised one.

### Fixed

- Scrolling no longer stutters while HTTP sync is set up. When nothing changed, the five-second sync check and the reading-history sync (once a minute, and every 30 seconds while reading) now do almost no work on the main thread and write no files. Books whose position Android last saved were rewritten and announced as moved every five seconds; they are left alone. A sync that changes nothing no longer reloads the whole bookshelf.
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
- Scrolling no longer stalls for longer each day of the month once several devices publish reading activity. Every reading-history sync re-read the dates of all activity files inside nested loops on the main thread, which reached half a second and more with three devices late in a month; it now takes about two milliseconds.
- A page that iOS discarded while the app was in the background is loaded again at the saved place when you come back, in EPUB, manga and podcast transcripts. Before, the page stayed blank, and a swipe on a blank EPUB page moved to the next chapter and saved that as the reading position.
- A part of an EPUB that is not an HTML page, such as a standalone SVG image, is shown and can be swiped past instead of leaving an empty page.
- A book whose title starts with a dot, such as ".hack//SIGN", appears on the shelf after import instead of landing in a hidden folder.
- The local server that hands a card's cover and audio to AnkiMobile accepts connections from this device only.
- A vertical EPUB whose markup starts a paragraph on a new line no longer reopens at the chapter's first page.
- The reader can always be closed. It could not when the shelf section it was opened from disappeared meanwhile, for example after finishing the only book under Reading.
- A book that cannot be opened shows a message with a Close button instead of an endless spinner.
- The first search in the Dictionary tab shows its results instead of an empty page.
- A backup of dictionaries can no longer be restored over the books, or the reverse; both are `.hoshi` files, and the mistake replaced the whole collection.
- Opening an EPUB or Anki file from another app no longer deletes manga archives that are still waiting to be imported.
- Manga and dictionary imports that were interrupted by the app closing no longer leave their unpacked files behind.
- A book with a damaged statistics file can be deleted, here and from another device; the file is kept for recovery.
- A translation that arrives after its book was deleted no longer recreates the book's folder, which blocked importing the book again. A damaged translation history is kept beside the new one instead of being overwritten.
- Opening a translation popup no longer reads the book's whole translation history unless the history is shown.
- Sentence mode: tapping a reading looks up its own word rather than one in the line above, and a book without chapter sizes opens at its saved sentence instead of the chapter's last one.
- Podcast transcripts no longer go blank after long background listening; resuming after playing a word's audio keeps the lock-screen controls; an imported audiobook position is applied to an audiobook that is already loaded.
- The Podcasts tab checks its listing off the main thread, rewrites its saved listing only when it changed, and stops checking while a transcript covers it.
- A custom AI model name can be typed even when it starts with the name of a listed model.
- Anonymous usage statistics keep their twenty-hour interval after the device clock is set back, and report the app language without the region.
- Dictionary entries can only create the elements dictionaries are defined to use.
- Cancelling a sync no longer makes the reading-position history of a book wait before it is tried again.
- A sync server cannot name a book in a way that unpacks it outside the library.
- Selected books, and the icon-only buttons for moving and deleting them, importing dictionaries and deleting fonts, are announced by VoiceOver.
- A dictionary whose archive gives it an empty, hidden or path-like name is refused with a message instead of being installed where it cannot be listed.
- Leaving the Backup screen while an archive is being made no longer leaves "Archiving…" on it.
- Turning a page in a long EPUB chapter does less work to record the reading position.
