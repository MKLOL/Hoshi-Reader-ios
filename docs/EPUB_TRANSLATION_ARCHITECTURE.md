# EPUB sync + sentence pre-translation — architecture

Status: **phases 2 and 3 are built; 1, 4 and 5 are in progress** (see §8). The desktop extractor,
the blob, the export/import seam, the CLI and 36 unit tests exist and are verified against a real
book; the device side is being written. This document specifies the whole feature so it can be
built (and reviewed) in one coherent pass. It deliberately mirrors the manga (mokuro) pre-translation
pipeline that already ships, reusing its blob shape, its sync mechanics, its store, its controller
and its popup wherever the shapes are the same.

Companion runbook: [`tools/pretranslate/EPUB.md`](../tools/pretranslate/EPUB.md) — how to actually
translate a book once this exists.

---

## 1. What ships today (the pattern to mirror)

The manga path, end to end:

| Stage | Where |
| --- | --- |
| Desktop tool discovers mokuro volumes on the sync server | `tools/pretranslate/hoshi_pretranslate/pipeline.py: discover_manga` |
| Reads `mokuro.json` out of `books/{syncId}/payload.zip` by HTTP range request | `…/mokuro.py: fetch_mokuro_json` |
| Every bubble gets an address `p{page}b{block}` | `…/mokuro.py: Bubble.block_id` |
| Local GPU (llama.cpp) or a hosted API produces `{translation, explanation}` per bubble, with the page + previous page as context | `…/llm.py`, `…/cloud.py` |
| One blob per volume is uploaded to `books/{syncId}/pretranslations` | `…/blob.py: PretranslationsBlob` |
| Device pulls it during sync and writes `pretranslations.json` into the book dir | `Features/HttpSync/HttpSyncReconciler.swift: applyPretranslationsFromRemote` |
| Reader tags each OCR box with `data-hoshi-block="p{page}b{block}"` | `Features/MangaReader/MangaPageHtml.swift:376` |
| A tap posts `{text, blockId}` to Swift | `MangaReaderWebView.swift:418` |
| The controller serves the cached answer before ever touching the network | `Features/AI/MangaAiController.swift: serveOfflinePretranslation` |
| The store resolves address → entry, verifying a text hash, falling back to a whole-text match | `Features/AI/PretranslationStore.swift` |
| The popup renders translation + explanation as Markdown and offers "Ask ChatGPT instead" | `Features/AI/MangaAiPopupView.swift` |

Two properties of that design are what make it work offline and cross-device, and both carry over
unchanged:

1. **One key per book, not per unit.** The server is behind a ~500 req/min limit; a volume has
   thousands of bubbles. One blob is one GET.
2. **A cache, not a conversation.** A cache hit is never written into `ai_chat_log.json`, so it
   never syncs out as chat history.

## 2. What is missing for EPUB

EPUB reading, importing and bookmark/metadata sync all work today. Three things do not exist:

1. **EPUB content sync.** Payload upload is gated to mokuro on both platforms —
   `HttpSyncReconciler.swift:959` (`if book.contentType == .mokuro`) and the Android mirror at
   `HttpSyncReconciler.kt:1212`, whose comment says the gate is what to widen. So an EPUB imported on
   the iPad never reaches the iPhone.
2. **EPUB translation sync.** The pre-translation format addresses *bubbles*. There is no address
   for a *sentence in a chapter*, no extractor, and no blob.
3. **The in-reader button.** The EPUB reader has a dictionary popup on tap, but nothing that offers a
   whole-sentence translation + explanation.

## 3. The addressing problem — and why it is already solved

A bubble address is easy: mokuro hands us `page` and `block` and both readers parse the same file.
A sentence in an EPUB has no such natural id. Chapter text is XHTML rendered into a DOM; the tool
sees bytes, the reader sees nodes.

**The app already has a shared coordinate system for exactly this: the normalized character offset.**

`String.filtered()` (`Util/Extensions.swift:14`) reduces a chapter to only "matchable" characters —
kana, kanji, radicals, ASCII/fullwidth alphanumerics — dropping every tag, every ruby reading, all
punctuation and all whitespace. `reader.js` computes the identical sequence over DOM text nodes
(`normalizeText` + `createWalker`, which rejects `rt`/`rp` subtrees).

That offset space is already load-bearing and already cross-platform:

* **Sasayaki (audiobook alignment)** — the load-bearing precedent. `SasayakiMatcher` matches
  transcript cues against `content.filtered()` and emits `{chapterIndex, start, length}`;
  `reader.js collectSasayakiCueRanges` (`reader.js:234-297`) walks those offsets straight back to
  DOM ranges and wraps them in spans. This is exactly the operation sentence buttons need.
* **Bookmarks** — `Bookmark.characterCount` is a book-cumulative normalized count, but it resolves
  only to `(spineIndex, progressFraction)` (`Models/Book.swift:56-86`). It shares the counting rule,
  not the precise placement.
* **Highlights** — persist and re-place by the **raw** code-point offset
  (`highlights.js:20,32`; `collectSegments` counts every code point); the normalized `start` is used
  only for chapter grouping. They share the walker, not the offset space.

So Sasayaki alone proves the round trip. That is still enough — it is shipped, exercised by every
audiobook user, and does precisely `(start, len) → DOM range`. But the §5.4 "no text node"
invariant matters for *both* counts, raw and normalized, because highlights depend on the raw one.

So the mechanism for "given `(spine, start, len)`, find the DOM range and put something there"
**already exists, is shipped, and is exercised by every audiobook user.** Sentence buttons are a
second consumer of it.

### The address

```
c{spineIndex}s{normalizedStart}      e.g.  c3s1204
```

* `spineIndex` — index into `document.spine.items`, **unfiltered**, in OPF `<spine>` document order
  (EPUBKit keeps `linear="no"` itemrefs; see `EPUBSpineParser.swift`). This is the same index the
  reader uses for `loadChapter(index:)` and stores in `Bookmark.chapterIndex`, so it is already a
  cross-device contract.
* `normalizedStart` — count of matchable characters in that chapter before the sentence's first
  matchable character.

Stable across re-imports and across devices, because it is derived from the EPUB's own bytes.

### The normalizer (authoritative definition)

Keep only:

```
[0-9A-Za-z○◯々-〇〻ぁ-ゖゝ-ゞァ-ヺー０-９Ａ-Ｚａ-ｚｦ-ﾝ\p{Radical}\p{Unified_Ideograph}]
```

Applied to the chapter's `<body>` text with `rt`, `rp`, `script` and `style` subtrees removed.
Three implementations must agree:

| | |
| --- | --- |
| Swift | `String.filtered()` — `Util/Extensions.swift:14` |
| JS | `hoshiReader.normalizeText` + `createWalker` — `Features/Reader/ReaderWebView/reader.js` |
| Python (new) | `hoshi_pretranslate/epub.py: normalize()` — uses the `regex` module, which supports `\p{Radical}` and `\p{Unified_Ideograph}` (verified) |

> **They do not agree by construction — only in practice.** `reader.js:42-48` `createWalker` rejects
> only `rt, rp`, so a `<script>` or `<style>` **inside `<body>`** contributes text nodes the DOM
> walker counts, while `Extensions.swift:20` strips them and the Python skips them. Such a chapter
> would shift every DOM offset after it, relative to both other implementations. This is a
> pre-existing hazard for Sasayaki, not something EPUB translation introduces; the tool should warn
> when it sees non-whitespace `script`/`style` text in a body. Verified absent from
> ふしぎ駄菓子屋銭天堂 (all 47 chapters clean).

> **The Python side must parse the XHTML with a real HTML parser, not the Swift regex.**
> `filtered()` decodes only four entities; a numeric entity such as `&#12354;` survives it as the
> literal digits `12354`, which *are* matchable and would shift every offset after it. The DOM
> decodes it to `あ`. The reader's DOM is the runtime truth, so the tool must match the DOM. (This
> is a latent Sasayaki bug too — worth a test, out of scope here.)

## 4. Wire format

### Keys

| Key | Content-Type | Direction | Who reads it |
| --- | --- | --- | --- |
| `books/{syncId}/epub.zip` | `application/zip` | iOS ⇄ server | iOS, desktop tool |
| `books/{syncId}/epub.manifest` | `application/json` | iOS ⇄ server | iOS, desktop tool |
| `books/{syncId}/sentences` | `application/json` | tool → server → iOS | iOS |

**Why new key names instead of the existing `payload.zip` / `payload.manifest` / `pretranslations`:**
this is what keeps Android out of it. `HttpSyncReconciler.kt: parseBookKey` matches a closed set of
suffixes and returns `null` for anything else; a `null` parse is `markHandled(meta)` — listed, ignored,
never fetched. So an Android device syncing the same account:

* never downloads an EPUB payload (it would otherwise import one — its Pass 3 does **not** check
  `manifest.format`, and it stores EPUBs as unpacked directories just like iOS, so the book *would*
  appear on the phone);
* never downloads a sentence blob into a book directory nothing reads;
* needs **zero code changes**, and nothing new appears in its UI.

The existing `books/{syncId}/metadata` key stays shared. Android already receives EPUB metadata today
(iOS pushes it for every book at `HttpSyncReconciler.swift:931`) and already parks it as
`MissingLocal` because there is no local root. Unchanged behaviour.

If unified EPUB sync across both platforms is ever wanted, it is one gate on each side plus pointing
these keys at `payload.*`. Deliberately not done now.

### `epub.manifest`

Byte-identical to the existing `HttpSyncPayloadManifest` — `{sha256, sizeBytes, originalName, format}`
with `format: "epub"`. Same codec (`HttpSyncPayloadCodec`), same sha-verify-then-unpack, same
manifest-exists-means-never-re-upload policy. Only the key functions differ.

### `sentences` — the blob

```jsonc
{
  "version": 1,
  "kind": "epub",                       // absent/"mokuro" ⇒ the bubble blob; guards a mis-typed read
  "syncId": "yotsubato-01",
  "title": "よつばと！ 1",
  "model": "gemini-3.6-flash",
  "promptId": "sha256:1f0c…",           // same prompt-change invalidation as manga
  "generatedAt": "2026-08-22T09:14:00Z",
  "spineCount": 42,                     // sanity check against the reader's spine
  "entries": {
    "c3s1204": {
      "spine": 3,
      "start": 1204,                    // normalized chars from the start of chapter 3
      "len": 14,                        // normalized chars in the sentence
      "text": "その日、彼は何も言わなかった。",   // raw, for display + verification
      "hash": "9f2a4c81b0e7d3a5",       // sha256(normalize(text))[:16]
      "translation": "That day, he said nothing.",
      "explanation": "…"
    }
  }
}
```

Mirrors `HttpSyncPretranslationsBlob` field for field, with `spine`/`start`/`len` added and the entry
key in the chapter address space.

**One deliberate difference from the manga blob:** `hash` digests the *normalized* text, not the raw
text. A bubble's raw OCR string is identical on both sides because both read the same `mokuro.json`;
a sentence's raw string is reassembled from DOM nodes and can differ from the tool's by whitespace or
entity decoding. Normalizing before hashing removes exactly that class of false mismatch.

**Size.** A novel is 5,000–15,000 sentences ⇒ roughly 1.5–5 MB of JSON (manga volumes are a few
hundred KB). Still one GET, but the device must parse it off the main thread and index it by spine
on load. If a book ever exceeds ~8 MB, split by spine range under `books/{syncId}/sentences/{part}`;
not built now, and the `version` field is how a reader would learn about it.

## 5. Device side

### 5.1 Sync (`Features/HttpSync/`)

`SyncCore.swift` — three key functions next to `pretranslations(_:)`:

```swift
static func epubZip(_ syncId: String) -> String       { "books/\(syncId)/epub.zip" }
static func epubManifest(_ syncId: String) -> String  { "books/\(syncId)/epub.manifest" }
static func sentences(_ syncId: String) -> String     { "books/\(syncId)/sentences" }
```

`HttpSyncPayload.swift` — `HttpSyncPayloadCodec` takes the two key strings as parameters instead of
deriving them, so one codec serves both formats. Add `sentence_translations.json` to
`httpSyncPayloadExcludedFiles` (it syncs through its own key and must not churn the payload sha).

`HttpSyncReconciler.swift`:

* `BookKeyKind` gains `.epubManifest`, `.epubZip`, `.sentences`; `parseBookKey` maps the three
  suffixes; `kindLabel` gets human strings.
* Pass 1 buffers `.epubManifest` alongside `payloadManifests`, and `.sentences` alongside
  `bookmark`/`chat`/`pretranslations` (same applied-key ledger, same download-only semantics).
* Pass 3 (remote-only import) handles an EPUB manifest: same free-space preflight, same
  download → sha-verify → unpack, then **`BookProcessor.process` on the unpacked document to write
  `bookinfo.json`**. Today that sidecar is written for mokuro only
  (`HttpSyncReconciler.swift:742`); without it an EPUB arrives with `characterCount == 0`, the
  shelf shows no progress and `resolveCharacterPosition` cannot place an incoming bookmark. This is
  the one genuinely new step in the inbound path.
* Pass 5 applies a `.sentences` blob → `sentence_translations.json` in the book dir, then
  `EpubTranslationStore.invalidate(root:)`. Straight copy of `applyPretranslationsFromRemote`,
  including the `version <= supportedVersion` guard.
* Outbound: widen the payload gate from `contentType == .mokuro` to both, routing EPUB books to the
  `epub.*` keys. Chat push stays mokuro-only for now (nothing in the EPUB reader writes chat yet).

**Five things the first draft of this plan missed** (found in review; all confirmed in code):

1. **The cover is silently lost on a synced EPUB import.** `resolveImportedCoverPath`
   (`HttpSyncReconciler.swift:770-776`) looks only for a literal `cover.jpg`, and
   `generateMokuroCoverIfMissing` bails for non-mokuro. A local import instead copies the cover
   under its manifest href's basename (`BookshelfViewModel.swift:518-522`) — `00023.jpeg` for this
   book. The file *is* in the payload zip, but `metadata.cover` stays nil and the shelf tile is
   blank. Free fix: we already parse the document for `BookProcessor`, so run `findCoverInManifest`
   on it. (Android hit and fixed the identical bug — `HttpSyncReconciler.kt:1500-1504`.)
2. **Do not copy `applyPretranslationsFromRemote` verbatim.** It fully `JSONDecoder.decode`s the
   body just to validate it, then writes the raw bytes — and the reconciler is `@MainActor`. That is
   fine for a few hundred KB of manga; a 1.5–5 MB `sentences` blob will visibly hitch "Sync now".
   Validate off the main actor (or validate only the header fields).
3. **Key parameterization has four call sites, not two:** `HttpSyncPayload.swift:75`
   (`uploadIfChanged`'s manifest probe), `:118` and `:125` (`downloadAndUnpack`), `:148-149`
   (`fetchManifest`) — plus `importRemoteOnlyBook`'s free-space preflight
   (`HttpSyncReconciler.swift:704-706`), which calls `fetchManifest` separately. Miss one and an
   EPUB silently reads or writes the mokuro keys.
4. **`payloadBookCount` (`HttpSyncReconciler.swift:893-894`) is computed mokuro-only.** Widening the
   gate at `:959` without widening the counter makes the progress bar run past its total.
5. **EPUB chat becomes silently device-local once `askSentence` ships.** Its live and on-device
   paths persist (`MangaAiController.swift:171,247,283`), `ai_chat_log.json` is excluded from the
   payload zip, and both the chat push (`:976`) and apply (`:554`) gate on `.mokuro`. Not
   corruption, but "nothing in the EPUB reader writes chat yet" stops being true, so either widen
   those gates too or accept it deliberately.

### 5.2 Store (`Features/AI/EpubTranslationStore.swift`, new)

A near-copy of `PretranslationStore` — `nonisolated final class … @unchecked Sendable`, `NSLock`,
per-folder cache, invalidated by the reconciler off the main actor. Differences:

* reads `sentence_translations.json`;
* rejects a blob whose `kind` is not `"epub"`;
* builds `[spineIndex: [Anchor]]` where `Anchor = {id, start, len, hash}`, sorted by `start`, so the
  reader asks one question per chapter load: *"what anchors are in chapter N?"*;
* keeps a `byHash` secondary index for the stale-offset fallback (§5.4);
* `lookup(id:) -> Pretranslation` for the tap.

Loaded off the main thread when the reader opens (Android already does this for manga —
`MangaReaderScreen.kt:248`).

### 5.3 Reader plumbing

`ReaderViewModel.loadChapter` already ships per-chapter side data to the web view (Sasayaki cues,
highlights). Sentence anchors ride the same path:

```swift
case loadChapter(url:progress:fragment:sasayakiCues:highlights:sentenceAnchors:)
```

serialized as `[{id, start, len, hash}]`, chapter-relative, ordered.

`ReaderWebView` gains one message handler, `sentenceTranslate`, receiving `{id}`.

### 5.4 Placing the buttons (`Features/Reader/ReaderWebView/translations.js`, new)

`window.hoshiTranslations.apply(anchors)`, run **after** highlights and Sasayaki cues (both mutate
the DOM and rebuild the offset map) and followed by `hoshiReader.buildNodeOffsets()`.

Algorithm, reusing the walk `collectSasayakiCueRanges` already performs:

1. Walk text nodes with `hoshiReader.createWalker()`, counting matchable characters.
2. For each anchor, capture the raw `(node, offset)` just past its **last** matchable character
   (`start + len - 1`).
3. From there, consume trailing sentence punctuation using selection.js's existing
   `trailingSentenceChars` (`。、！？…‥」』）)】〉》〕｝}］]`). This is what puts the button *after the
   `。`*, and after a closing 」 when the sentence ends inside quotes.
4. Verify: hash the normalized text of `[start, start+len)` and compare to `anchor.hash`.
   * match → insert the button;
   * mismatch → the chapter is not what the tool saw (a re-import from a different EPUB build).
     Look the entry's normalized text up in the chapter's normalized string; place the button if it
     occurs exactly once, otherwise skip that sentence. Never show an unverified translation.
5. Insert `<span class="hoshi-tl" data-tl="c3s1204" role="button" tabindex="0"></span>`.

**DOM invariants that must hold** (breaking any of them corrupts bookmarks, highlights and Sasayaki
alignment, all of which share the offset space):

* the button element contains **no text node** — its glyph comes from CSS `content` on `::before`,
  so `TreeWalker(SHOW_TEXT)` cannot see it;
* additionally, `hoshiReader.createWalker` / `hoshiSelection.createWalker` reject
  `closest('.hoshi-tl')`, the same way they already reject `rt, rp` — belt and braces;
* buttons are removed and re-applied on chapter load, never left behind;
* `hoshiSelection.getSentence` must skip the element so a dictionary tap next to a button still
  returns a clean sentence.

**Styling.** Inline-block, `~0.62em`, muted, `user-select: none`, `vertical-align` set per writing
mode; a `::before` with negative insets (about −8px) enlarges the tap target *without* changing
layout, so pagination is unaffected. Works in `vertical-rl` because the box is square and inline.
A reader setting turns the buttons off (they should not be forced on a book you are reading cold).

Tap → `webkit.messageHandlers.sentenceTranslate.postMessage({id})`.

### 5.5 Popup

`MangaAiPopupView` is already generic — it takes `MangaAiController`, `BookMetadata`, `UserConfig`,
an optional cover, and renders Markdown. Present it from the EPUB reader unchanged.

`MangaAiController.ask` gains a sibling entry point:

```swift
func askSentence(id: String, sentenceText: String, book: BookMetadata, forceLive: Bool = false)
```

identical in shape to `ask(bubbleText:blockId:book:forceLive:)` — cache first, then on-device, then
cloud; never persists a cache hit to `ai_chat_log.json`; `isShowingPretranslation` drives the
"Ask ChatGPT instead" button. The offline-first ordering is the whole point of the feature: pressing
a button on a plane must answer instantly.

## 6. Desktop tool (`tools/pretranslate/`)

New modules, alongside `mokuro.py` rather than replacing it:

| File | Role |
| --- | --- |
| `hoshi_pretranslate/epub.py` | `normalize()`, spine enumeration, per-chapter text extraction, sentence segmentation, `Sentence` / `Book` dataclasses |
| `hoshi_pretranslate/epub_blob.py` | the `sentences` blob writer/reader (or a `kind`-aware extension of `blob.py`) |
| `hoshi_pretranslate/epub_pipeline.py` | `discover_epubs`, `load_book`, `translate_book`, `upload_book` — the same resumable, checkpoint-per-chapter shape as `pipeline.py` |

**Dependencies.** `lxml` (XHTML parsing) and `regex` (Unicode property classes) join `requests` and
`remotezip`. Both are maintained and ship Windows wheels, so the bundled-Python bootstrap is
unaffected. Per `AGENTS.md`, no hand-rolled XML or HTML parsing — the only hand-written logic is
sentence segmentation, which is a Hoshi-specific rule set (it must match `selection.js`), not a
solved standard format.

**Segmentation** (the tool owns it; the reader never re-segments):

* terminators: `。！？!?`. `selection.js:12` also treats ASCII `.` as one; we deliberately do not.
  Nothing depends on exact parity — the reader places buttons from the blob and never re-segments,
  so a divergence only changes how much text one button covers. And in Japanese prose an ASCII
  period is far more often a decimal point, an abbreviation or a URL than a sentence end: in
  ふしぎ駄菓子屋銭天堂 the only two occurrences are inside URLs, which splitting would shatter;
* after a terminator, consume `trailingSentenceChars`;
* a block-level element boundary (`p`, `div`, `h1`–`h6`, `li`, `blockquote`, `br`, `td`, `section`,
  `figcaption`, …) also ends a sentence, so a heading or a line of dialogue with no `。` still gets
  one button;
* drop sentences with zero matchable characters (a lone image or an ornament);
* hard cap 400 normalized characters, splitting at the last `、` before the cap — protects against a
  chapter with no punctuation at all.

**Context.** Manga sends the current page plus the previous one. The sentence equivalent: the
preceding 6 and the following 2 sentences, plus the chapter heading, with only the target sentence
asked for. Two modes matching `focused` / `page`:

* `sentence` (default) — one request per sentence with the window as a shared prefix, so llama.cpp's
  prefix cache is reused down a paragraph;
* `paragraph` — one request per paragraph, all its sentences at once. Faster, blunter.

Everything else is reused verbatim: `kv.py`, the prompt fetch from `app/ai_chat_settings`, the
`promptId` invalidation rule, checkpoint-per-unit resume, `--no-upload`, and the
`--export-…`/`--import-translations` seam that lets any translator (including an agent) do the work.

**Getting the text.** Two sources, both supported:

* `--epub path/to/book.epub` — the local file. Fastest, and the natural path for "translate this one
  book". Offsets are identical to the device's because the device unpacked those same bytes.
* the server — range-read the XHTML members out of `books/{syncId}/epub.zip`, exactly as
  `fetch_mokuro_json` range-reads `mokuro.json` today. Needed for the overnight-everything run.

## 7. Failure modes and what stops them

| Failure | Guard |
| --- | --- |
| Offsets computed against a different EPUB build than the reader renders | per-entry hash verification at button-placement time; unverified anchors are dropped, never shown |
| Entity decoding / whitespace divergence between tool and DOM | tool parses with a real HTML parser; hashes are over normalized text |
| A button's element shifts the offsets the whole app depends on | button holds no text node **and** the walkers reject it; offsets rebuilt after insertion |
| Android picks up EPUB books or blobs | new key suffixes; `parseBookKey` returns `null` and the key is marked handled without a fetch |
| Blob written by a newer tool | `version` gate, same as `HttpSyncPretranslationsBlob.supportedVersion` |
| Prompt changed since the run | `promptId` mismatch ⇒ the tool redoes the book; the device still serves what it has |
| A cached answer pollutes chat history | the cache path bypasses `persist` entirely, exactly as manga does |
| A synced EPUB arrives with no `bookinfo.json` | Pass 3 runs `BookProcessor.process` after unpacking |
| Multi-MB blob parsed on the main thread | store preloads off-main on reader open and indexes by spine |

## 8. Implementation order

Each phase is independently shippable and testable.

1. **EPUB payload sync.** Key funcs, parameterize the codec, reconciler kinds + passes, `bookinfo`
   on import, widen the outbound gate. Verifiable on its own: import an EPUB on one device, sync,
   read it on the other with the bookmark following.
2. **Extractor + blob, offline.** ✅ `epub.py` + `epub_blob.py` + `tests/test_epub_pretranslate.py`.
   Cross-checked against `String.filtered()` on ふしぎ駄菓子屋銭天堂: all 47 chapters and 42,064
   normalized characters agree exactly, by two independent routes (raw markup vs. parsed DOM).
3. **Translation pipeline.** ✅ `epub_pipeline.py`, CLI flags, export/import seam, resume, verifier.
   Produces a blob on disk. The local-GPU / hosted-API engines are not wired to the novel path yet —
   the export/import seam is the supported route.
4. **Device read path.** `EpubTranslationStore`, anchors through the bridge, `translations.js`,
   the message handler, `askSentence`, popup, reader setting.
5. **Upload + end to end.** Tool uploads; device syncs; airplane mode; press a button; answer.

Regression coverage follows the existing pattern in `Tests/Regression/` (the Python conformance
tests) plus Swift unit tests for the store and the anchor serializer, mirroring
`Tests/MangaViewportGestureMathTest.swift`.

## 9. Decisions taken (and the alternatives rejected)

* **Normalized character offsets, not CFI or XPath.** EPUB CFI is the standard answer and is what a
  general reader would use — but nothing in this app speaks it, whereas the normalized offset is
  already how bookmarks, highlights and audiobook alignment address text on both platforms. Adding
  CFI would mean a second coordinate system and a second set of bugs.
* **The tool segments; the reader places.** One segmentation implementation, in Python, where it can
  be tested. Re-implementing `getSentence`'s bracket balancing in two languages and keeping them
  byte-identical is the kind of thing that silently drifts.
* **Separate `epub.*` / `sentences` keys.** Costs a little duplication in the reconciler; buys a
  hard guarantee that the Android app is untouched, with no coordination between the two codebases.
* **One blob per book.** Matches manga, one GET, works offline. Per-chapter keys would be ~50 GETs
  per book against a rate-limited server for no user-visible gain.
* **Reuse `MangaAiController` and `MangaAiPopupView`.** They are already format-agnostic; a parallel
  EPUB controller would duplicate the provider routing, the on-device path, the error taxonomy and
  the history browser. (Their *names* become slightly wrong — renaming to `AiTutorController` /
  `AiTutorPopupView` is a mechanical follow-up, kept out of the feature diff.)


## In-app writer: News pre-translation

Since the News tab (`Features/News/`) the app itself can produce `sentence_translations.json`:
`Pretranslate/PretranslationPlanner` segments a saved article with `EpubSentenceSegmenter`,
`PretranslationRunner` batches the sentences through `CloudChat` or the on-device model,
`SentenceTranslationsWriter` builds an `HttpSyncSentencesBlob` (same `promptId`/hash/`len` rules
as the Python tool), validates it with `validationError(expectedSyncId:spineCount:)` before writing,
and `SentenceTranslationsUploader` PUTs `books/{syncId}/sentences`. The sync engines stay
download-only for that key; a blob written on one device reaches the others through the normal
sentences import. Partial results are kept on failure or cancel unless a complete sidecar from
another model or prompt already exists. The Android app writes the identical format.
