# Agent-authored news for Hoshi

Python 3.10+; standard library only. The agent finds and reads an article, writes
its English lesson, and uses these tools to package and publish it. No model API
key or Android/server change is needed. Start with the repository skill
[hoshi-news](../../.agents/skills/hoshi-news/SKILL.md).

## Local workflow

Run from the repository root. Keep source snapshots and generated jobs in
`.hoshi-news/` (gitignored). Supply `article.json` with:

```json
{
  "title": "天気のニュース",
  "sourceName": "Original example",
  "sourceUrl": "https://example.com/weather",
  "publishedAt": "2026-09-22",
  "bodyXhtml": "<p><ruby>今日<rt>きょう</rt></ruby>は雨です。</p>"
}
```

`publishedAt` is optional, in `YYYY-MM-DD` format. `titleXhtml` is optional inline
XHTML retaining headline ruby; its base text must match `title`. Supply exactly
one of `bodyXhtml` (well-formed XHTML fragment) or `paragraphs` (a list of plain
text strings). The fragment is sanitized; ruby is preserved, attributes and
active content are removed. ASCII digits become full-width, matching the apps'
news imports. Headline and body appear in the book; source attribution and date
are in EPUB metadata, and the URL is also in the lesson preview.

Extraction is agent-managed: use the full rendered article, not a search/feed
snippet. There is no generic URL scraper here; NHK's client-rendered pages and
regional access need a working browser session. This version is text-only and
omits images, audio, and video.

```bash
python3 tools/news/hoshi_news.py prepare --article .hoshi-news/article.json --out .hoshi-news/weather
```

The new job contains `book/` (final EPUB tree), `article.json` (source snapshot),
`plan.json` (sentence IDs/addresses), `prompt.md`, and `translations.json`.
Preparation refuses an existing directory. Read the [tutor prompt](tutor-prompt.md)
and fill every entry in `translations.json`:

```json
{
  "id": "c0s7",
  "text": "今日は雨です。",
  "translation": "It's rainy today.",
  "words": [
    {"surface": "今日", "reading": "きょう", "romaji": "kyō", "meaning": "today"},
    {"surface": "は", "reading": "は", "romaji": "wa", "meaning": "topic marker"},
    {"surface": "雨", "reading": "あめ", "romaji": "ame", "meaning": "rain"},
    {"surface": "です", "reading": "です", "romaji": "desu", "meaning": "is; polite copula"}
  ],
  "grammar": "は marks 今日 as the topic. Noun + です makes a polite statement."
}
```

This is one entry, not the entire file. Keep the generated top-level `version`,
`syncId` and `entries`; label `model` honestly (`agent-authored` is the default).
Do not edit generated IDs/text or the book after preparation. Tables must cover
all source text in order, ignoring punctuation and whitespace. Include particles,
repetitions, names and numbers. Each row needs a reading, romaji and meaning.
Inflected words can be one row, with the endings explained under grammar.
The validator checks coverage and alignment, not linguistic accuracy.

```bash
python3 tools/news/hoshi_news.py build --job .hoshi-news/weather
python3 tools/news/hoshi_news.py publish --job .hoshi-news/weather --dry-run
```

`build` writes `article.epub`, `epub.manifest.json`, `metadata.json`,
`sentence_translations.json`, and the human-readable `preview.md`. Review that
preview before upload. `publish` defaults to dry run even without `--dry-run`:
it validates all artifacts and reports planned keys, sizes and hashes without
reading credentials or making **any network requests**. It cannot detect server
conflicts while offline. Editing translations requires another `build`.

## Publishing

Use `HOSHI_KV_BASE_URL` and `HOSHI_KV_TOKEN` in the environment, or the repo's
gitignored `.hoshi-sync-secret.env` (see [.env example](../../.hoshi-sync-secret.env.example)).
There is no token command-line flag. The env file is parsed as data, never run as
shell code; environment variables take precedence. HTTPS is required except for
loopback development servers, and authenticated redirects are refused.

```bash
python3 tools/news/hoshi_news.py publish --job .hoshi-news/weather --upload --env-file .hoshi-sync-secret.env
```

The existing [KV protocol](../../docs/HTTP_SYNC_KV.md) receives, in order:

1. `books/{syncId}/epub.zip` — `article.epub` bytes, with EPUB files at the ZIP root.
2. `books/{syncId}/sentences` — translations and tutor tables/grammar.
3. `books/{syncId}/metadata` — title, EPUB type and initial News shelf placement.
4. `books/{syncId}/epub.manifest` — hashes and size; published last so a fresh
   device can import only after the other files have been uploaded.

The ID is `news_` plus a hash of the canonical article URL (fragment removed).
Use the site's canonical URL consistently; meaningful query parameters are kept.
The ZIP is deterministic for a prepared job, and its static-content hash follows
the Android/iOS path/length/bytes convention. Sentence offsets count normalized
Unicode code points, omit ruby readings, and match the Android segmenter.

The publisher preflights all four keys, checks upload receipts and reads writes
back. Identical uploads are skipped, interrupted jobs resume, device shelf/title
changes are preserved, and deletion tombstones or different EPUB content stop the
upload. Reuse the original job on retry; preparing again creates new EPUB metadata
and is not a way to replace published content. Different translations require
`--replace-translations` after review; this never permits changing the EPUB.
Transient failures retry at most three times per request. The KV server has no
transaction/CAS, so run only one publisher for an article at a time. No book map,
bookmark, statistics, chat or unrelated book is written. Individual files are
limited to 16 MiB; large books/media need the app's multipart path.

After publishing, tap Sync on iOS or Android. The article appears on the **News shelf in
Books**, with stored sentence translations usable offline in the reader. It does
not populate the News tab's separate on-device saved list.

## Verification

```bash
python3 -m unittest discover -s tools/news/tests -v

```

The Python tests use synthetic original Japanese text and an isolated loopback KV
server. The JVM test runs the Python publisher, then the real Android sync engines,
EPUB parser, content hashing and sentence-translation lookup; it also compares
Python segmentation against Kotlin across ruby/Unicode/punctuation edge cases.
They do not use production credentials, an emulator, or existing app data.
