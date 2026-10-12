# Changelog

## [Unreleased]

### Added

- HTTP sync keeps reading history for every book, including books never downloaded here and books deleted from any device. Statistics shows when other devices were checked and marks books that are no longer installed.
- Streak goals, day reset settings and reading time zones sync across devices. Every device counts the same Eastern Time days by default, including recoverable older readings recorded in another zone. Reading time is sent while you read, with independent bookmark transfers and a final flush when leaving the reader.

- Listen to a podcast's original recording with a following Japanese transcript and offline furigana. Tap a timestamp to play from that line, tap a word to pause and look it up, and optionally reveal English. The transcript uses the EPUB reader's text layout and font settings. Furigana sits above its kanji without repeating kana endings, and Appearance provides the shared font and furigana controls. Lessons and original recordings remember separate positions.
- Set the daily reading goal from 1 to 120 minutes and choose when the reading day resets, defaulting to 3am. Statistics use the same boundary throughout, with optimistic streak reconstruction for older history.
- See pretranslation badges on books, manga and collapsed shelves.
- See transfer speed and estimated remaining time during HTTP sync, cancel a sync, and remove inactive interrupted downloads from HTTP settings.
- Choose whether manga enlarges small OCR text. The Translate button is slightly larger when displayed alone.

### Fixed

- Downloaded font collections use the selected reading face in native sentence text, including regular Klee and the horizontal Kyokasho variant.
- Book downloads continue through background suspension and retain resumable progress after interruptions.
- Recover missing reading history even when the library otherwise appears unchanged, and preserve updates made while statistics are syncing.
- AnkiConnect no longer reports a card as added when media storage or the returned note result failed.
- Cancelling a backup restore before it commits preserves the current collection.
