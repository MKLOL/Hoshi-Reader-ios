# Changelog

## [Unreleased]

### Added

- Listen to a podcast's original recording with a following Japanese transcript. Tap a timestamp to play from that line, tap a word to pause and look it up, and optionally reveal English. Lessons and original recordings remember separate positions.
- Set the daily reading goal from 1 to 120 minutes and choose when the reading day resets, defaulting to 3am. Statistics use the same boundary throughout, with optimistic streak reconstruction for older history.
- See pretranslation badges on books, manga and collapsed shelves.
- See transfer speed and estimated remaining time during HTTP sync, cancel a sync, and remove inactive interrupted downloads from HTTP settings.
- Choose whether manga enlarges small OCR text. The Translate button is slightly larger when displayed alone.

### Fixed

- Book downloads continue through background suspension and retain resumable progress after interruptions.
- Recover missing reading history even when the library otherwise appears unchanged, and preserve updates made while statistics are syncing.
- AnkiConnect no longer reports a card as added when media storage or the returned note result failed.
- Cancelling a backup restore before it commits preserves the current collection.
