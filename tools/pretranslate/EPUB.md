# Pre-translating an EPUB

Companion to [`README.md`](README.md), which covers manga. Same tool, same server, same blob idea —
the unit is a **sentence in a chapter** instead of a **speech bubble on a page**.

The architecture and every wire format are specified in
[`docs/EPUB_TRANSLATION_ARCHITECTURE.md`](../../docs/EPUB_TRANSLATION_ARCHITECTURE.md). Read §3
(addressing) and §4 (wire format) before writing code — the offsets are the part that has to be
exactly right, and the reason they can be is that the app already uses them for bookmarks,
highlights and audiobook alignment.

> **Status: the extraction and translation side is built and tested.** `epub.py`, `epub_blob.py`,
> `epub_pipeline.py`, the CLI flags and `tests/test_epub_pretranslate.py` (36 tests) all exist.
> The **device** side — the button in the reader and the sync of the finished blob — is still being
> built, so a blob you upload today will sit on the server until the app ships. Translating now is
> safe and nothing is wasted: the blob format is fixed.

---

## What you are producing

One file per book, uploaded to `books/{syncId}/sentences`:

```jsonc
{
  "version": 1, "kind": "epub",
  "syncId": "…", "title": "…", "model": "…", "promptId": "sha256:…", "generatedAt": "…",
  "spineCount": 42,
  "entries": {
    "c3s1204": {
      "spine": 3, "start": 1204, "len": 14,
      "text": "その日、彼は何も言わなかった。",
      "hash": "9f2a4c81b0e7d3a5",
      "translation": "That day, he said nothing.",
      "explanation": "…"
    }
  }
}
```

The reader downloads it during sync, places a small button after each sentence's `。`, and answers a
press instantly — offline, no API key, no waiting.

---

## How it is built (reference)

Already implemented; this section is here so you can check the reasoning, not so you can redo it.

**`hoshi_pretranslate/epub.py`** — `normalize()`, spine enumeration, chapter text extraction and
sentence segmentation.

`normalize()` is the shared coordinate system and must produce the same string as Swift's
`String.filtered()` (`Util/Extensions.swift`) and JS `hoshiReader.normalizeText`:

```python
import regex   # NOT re — stdlib re has no \p{...}

_NOT_MATCHABLE = regex.compile(
    r"[^0-9A-Za-z○◯々-〇〻ぁ-ゖゝ-ゞァ-ヺー０-９Ａ-Ｚａ-ｚｦ-ﾝ\p{Radical}\p{Unified_Ideograph}]+"
)

def normalize(text: str) -> str:
    return _NOT_MATCHABLE.sub("", text)
```

Parsing: `container.xml` and the OPF are required by spec to be well-formed XML, so `xml.etree`
reads them; content documents are not reliably well-formed in the wild, so they go through
`html.parser`, which also decodes character references. That last part matters — the Swift filter
decodes only four named entities, so `&#12354;` survives it as the digits `12354`, which *are*
matchable and would shift every offset after them. The DOM decodes it to `あ`, and the DOM is the
runtime truth. `regex` is the only new dependency.

The spine keeps `linear="no"` itemrefs, matching `EPUBSpineParser.swift`. The reader indexes
chapters by position in that unfiltered list, so dropping them would shift every later chapter and
break bookmarks as well as translations.

Segmentation, matching `Features/Reader/ReaderWebView/selection.js`: break after `。！？!?`, swallow
any trailing `。、！？…‥」』）)】〉》〕｝}］]`, also break at a block-element boundary so headings and
unpunctuated dialogue get their own button, drop runs with no matchable characters, and hard-cap 400
normalized characters (splitting at the last `、`).

**Verified against the real thing.** For ふしぎ駄菓子屋銭天堂, all 47 chapters and 42,064 normalized
characters match `String.filtered()` **exactly** — two independent routes (raw markup vs. parsed
DOM) converging on the same count. Re-run that check for any book whose offsets you doubt:

```bash
# in a copy of the unpacked epub, with a Swift replica of String.filtered()
swiftc -O filtered.swift -o filt && ./filt text/*.html
```

**Tests** — `tests/test_epub_pretranslate.py`, no GPU and no network:

```bash
~/hoshi-work/venv-epub/bin/python tests/test_epub_pretranslate.py
```

Covers normalization, ruby exclusion, entity decoding, non-linear spine items, address
round-tripping, over-long splits, blob round-trip, export/import/resume, and the verifier.

## The commands

For Google's asynchronous Gemini Batch API (including the resumable 10% book-two trial), see
[`GEMINI_BATCH.md`](GEMINI_BATCH.md).

All of these run from `tools/pretranslate/`. On macOS use the venv that has `regex` + `requests`:

```bash
PY=~/hoshi-work/venv-epub/bin/python
```

On Windows the bundled interpreter is `%LOCALAPPDATA%\HoshiPretranslate\python\python.exe`; add
`regex` to it (`requirements.txt` lists it).

Every EPUB command takes `--novel` (or, equivalently, is implied by `--epub` / `--list-epubs`) and a
`--book {syncId}`. Passing `--epub FILE` reads the book from a local file and needs no server;
without it the book is fetched from `books/{syncId}/epub.zip`.

### 1. Pick the book

```bash
$PY -m hoshi_pretranslate --list-epubs --token XXX
```

`syncId<TAB>title` for every non-deleted EPUB on the server. If the book is not there yet, sync it
from the device — or just point at the local file and choose the syncId yourself.

### 2. Extract and sanity-check

```bash
$PY -m hoshi_pretranslate --book zenitendou-01 \
    --epub ~/Downloads/ふしぎ駄菓子屋銭天堂.epub --extract-only
```

Prints sentences and characters per chapter and writes nothing. A 300-page novel is roughly
5,000–15,000 sentences; ten means the segmentation found no text, 200,000 means it is splitting on
something it should not. **This step refuses to continue if any address fails to resolve** — a
wrong offset would put a button on the wrong sentence, so it is a hard stop, not a warning.

### 3. Export the work

```bash
$PY -m hoshi_pretranslate --book zenitendou-01 --epub … \
    --export-sentences ~/hoshi-work/zenitendou-01/todo
```

One file per chapter (`c007.json`, …) plus an `index.json`, holding only sentences that are not
already in the checkpoint — so this composes with a partial run. Each paragraph carries the 6
sentences before it and the 2 after it as context:

```jsonc
{ "syncId": "…", "spine": 7, "remaining": 113,
  "paragraphs": [{
    "context_before": [{"id": "c7s61", "jp": "真由美はまったく泳げなかった。"}],
    "translate":      [{"id": "c7s159", "jp": "そんな考えが、うわっと頭にわいてしまう。"}],
    "context_after":  [{"id": "c7s221", "jp": "…"}]
  }]}
```

One file per chapter rather than one big file: a novel is more than a translator can do well in a
single pass, and a chapter is a natural place to stop and resume.

### 4. Translate

Anything that can write `{"c7s159": {"translation": "…", "explanation": "…"}}` per chapter into a
`done/` directory. For an agent, hand it a brief like
`~/hoshi-work/zenitendou-01/CODEX.md` — it covers the output shape, the quality bar, and the
self-check.

`translation` is natural English, one sentence for one sentence. `explanation` is two or three lines
on whatever is actually hard — a grammar pattern, an idiom, a mimetic word, an implied subject — and
an empty string when nothing is. The reader renders Markdown, so `**bold**` and short bullets work.

(The local-GPU and hosted-API engines that `pipeline.py` gives manga are not wired up for novels
yet: `--engine local` / `--engine cloud` still run the manga path. The export/import seam is the
supported route for now.)

### 5. Merge

```bash
$PY -m hoshi_pretranslate --book zenitendou-01 --epub … \
    --import-translations ~/hoshi-work/zenitendou-01/done \
    --model-name codex --no-upload
```

Accepts a directory or a single file, and either `{id: {...}}` or `{syncId: {id: {...}}}`. Ids that
are not in the book and empty translations are skipped with a count. Idempotent and resumable — the
checkpoint at `--out/{syncId}.json` accumulates across runs, and is discarded only if the model name
or the prompt changed.

The stored `text` is always the book's own sentence, never the translator's echo of it: the device
verifies a hash of that text against what it finds in the DOM.

### 6. Verify

```bash
$PY -m hoshi_pretranslate --book zenitendou-01 --epub … --verify
```

Every id resolves, every address still matches the book, every hash matches, nothing is empty,
nothing is missing. Exits non-zero if not. A bad hash means the device will *silently drop* that
button rather than show a translation it cannot verify, so treat anything reported here as a real
defect.

### 7. Upload

```bash
$PY -m hoshi_pretranslate --book zenitendou-01 --epub … --upload-only --token XXX
```

One PUT to `books/{syncId}/sentences`. Idempotent. It refuses to upload a book that does not pass
step 6 — a partial blob just means most buttons are missing.

### 8. On the phone

1. Settings → Sync → **Sync now**. The summary reports the translation set coming down.
2. Open the book. A small button sits after each `。`.
3. Airplane mode, press one: translation + explanation, instantly.
4. "Ask ChatGPT instead" runs the live model when a cached answer is not enough.

If the buttons are missing, the book on the device is a different EPUB build from the one you
translated (hash mismatch ⇒ buttons suppressed, by design). Re-run step 2 against the file the
device actually has.

---

## Things that will bite you

* **`re` instead of `regex`.** The stdlib module has no `\p{Radical}` / `\p{Unified_Ideograph}`.
  Silently different offsets, everywhere.
* **Filtering non-linear spine items.** Front matter with `linear="no"` still occupies a spine index
  on the device. Drop it and every later chapter is off by one.
* **Regexing the tags out of the XHTML** instead of parsing it. Works until the first numeric entity
  or a `<rt>` you did not strip, then the whole chapter is misaligned.
* **Hashing the raw text instead of the normalized text.** The reader reassembles a sentence from DOM
  nodes; whitespace will not match byte for byte. `hash` is over `normalize(text)` — this differs
  from the manga blob on purpose (see the architecture doc §4).
* **Uploading a part-finished book.** Don't. The checkpoint on disk is the resume point; a partial
  blob on the server just means most buttons are missing.
* **Touching Android.** Nothing here should require an Android change. The keys `epub.zip`,
  `epub.manifest` and `sentences` are invisible to it by construction — its `parseBookKey` returns
  `null` for unknown suffixes and the key is skipped without a fetch. If you find yourself editing
  the Android repo, stop: that means a key was reused that shouldn't have been.
