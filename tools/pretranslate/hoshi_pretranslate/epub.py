"""Pulls addressable sentences out of an EPUB.

The EPUB counterpart of `mokuro.py`. Where a manga bubble has a natural address handed to us by
the OCR file (`p{page}b{block}`), a sentence in a chapter does not — so we use the coordinate
system the readers already use for bookmarks, highlights and audiobook alignment: the **normalized
character offset** within a chapter.

`normalize()` below must produce the same string as, character for character:

  * Swift  `String.filtered()`               — Util/Extensions.swift
  * JS     `hoshiReader.normalizeText`       — Features/Reader/ReaderWebView/reader.js
                                               (applied to DOM text nodes, `rt`/`rp` rejected)

A sentence's address is then `c{spineIndex}s{normalizedStart}`, which is stable across re-imports
and identical on every device because it is derived from the book's own bytes.

See docs/EPUB_TRANSLATION_ARCHITECTURE.md §3.

Parsing notes
-------------
`container.xml` and the OPF package document are required by the EPUB spec to be well-formed XML,
so `xml.etree` reads them. The *content* documents are not reliably well-formed in the wild, so
they go through `html.parser`, which also decodes character references for us — that matters: the
Swift filter decodes only four named entities, so a numeric entity like `&#12354;` survives it as
the digits `12354`, which ARE matchable characters and would shift every offset after them. The
reader's DOM is the runtime truth, and the DOM decodes it to `あ`, so we match the DOM.
"""

from __future__ import annotations

import hashlib
import html
import posixpath
import urllib.parse
import zipfile
from dataclasses import dataclass, field
from html.parser import HTMLParser
from pathlib import Path
from xml.etree import ElementTree

import regex

# ---------------------------------------------------------------------------------------------
# The shared coordinate system
# ---------------------------------------------------------------------------------------------

# Kana, kanji, radicals, ASCII + fullwidth alphanumerics. Everything else — punctuation,
# whitespace, markup — is dropped. `regex`, not `re`: the stdlib module has no \p{...} support and
# would silently produce a different string (and therefore different offsets, everywhere).
_NOT_MATCHABLE = regex.compile(
    r"[^0-9A-Za-z○◯々-〇〻ぁ-ゖゝ-ゞァ-ヺー０-９Ａ-Ｚａ-ｚｦ-ﾝ\p{Radical}\p{Unified_Ideograph}]+"
)
_MATCHABLE_CHAR = regex.compile(
    r"[0-9A-Za-z○◯々-〇〻ぁ-ゖゝ-ゞァ-ヺー０-９Ａ-Ｚａ-ｚｦ-ﾝ\p{Radical}\p{Unified_Ideograph}]"
)


def normalize(text: str) -> str:
    """The chapter offset space: only 'matchable' characters survive."""
    return _NOT_MATCHABLE.sub("", text)


def is_matchable(char: str) -> bool:
    return bool(_MATCHABLE_CHAR.match(char))


def text_hash(text: str) -> str:
    """Short digest of a sentence, over its NORMALIZED form.

    Deliberately different from the manga blob, which hashes the raw bubble text: both sides of the
    manga path read the same `mokuro.json`, but a sentence is reassembled from DOM nodes at runtime
    and will not match our raw string byte for byte (whitespace, entity decoding, inline markup).
    Hashing the normalized form removes exactly that class of false mismatch while still catching a
    chapter whose actual words changed.
    """
    return hashlib.sha256(normalize(text).encode("utf-8")).hexdigest()[:16]


# ---------------------------------------------------------------------------------------------
# Segmentation rules — must agree with Features/Reader/ReaderWebView/selection.js
# ---------------------------------------------------------------------------------------------

# `hoshiSelection.sentenceDelimiters` minus the newlines (block boundaries cover those) and minus
# ASCII `.`, which selection.js does treat as a terminator. Deliberate: the reader places buttons
# from the blob and never re-segments, so parity is cosmetic — and in Japanese prose an ASCII
# period is usually a decimal point, an abbreviation, or a URL that splitting would shatter.
SENTENCE_TERMINATORS = "。！？!?"
# `hoshiSelection.trailingSentenceChars` — swallowed after a terminator so a sentence that ends
# inside quotes keeps its closing bracket, and the reader's button lands after it.
TRAILING_CHARS = "。、！？…‥」』）)】〉》〕｝}］]"
# A comma is where an over-long run is split when it has no terminator at all.
SOFT_BREAK = "、，,"
# Hard ceiling in normalized characters. Protects against a chapter with no sentence punctuation.
MAX_SENTENCE_CHARS = 400

# Elements that end a sentence even without punctuation, so headings and unpunctuated lines of
# dialogue still get their own button.
BLOCK_TAGS = frozenset({
    "p", "div", "br", "hr", "li", "dd", "dt", "blockquote", "pre", "figcaption", "figure",
    "h1", "h2", "h3", "h4", "h5", "h6",
    "section", "article", "aside", "nav", "header", "footer", "main",
    "table", "thead", "tbody", "tfoot", "tr", "td", "th", "caption",
    "ul", "ol", "dl",
})
# Subtrees whose text is not part of the chapter.
#
# `head`/`title` are deliberately NOT here: the `_in_body` gate already excludes everything before
# `<body>`, while skipping them by name would (a) drop `<svg><title>` inside the body, which both
# `String.filtered()` and the DOM walker keep, and (b) let an unclosed `<head>` — legal HTML5 —
# swallow the entire chapter.
#
# `script`/`style` match `String.filtered()` and this design's §3. Note the JS DOM walker does NOT
# exclude them (it rejects only `rt`/`rp`), so a chapter with script or style text inside its body
# is a genuine three-way divergence; `_ChapterTextExtractor` flags it rather than guessing.
SKIP_TAGS = frozenset({"rt", "rp", "script", "style"})
# Furigana containers, whose end tag implicitly closes an open `<rt>`/`<rp>` in every real parser.
RUBY_TAGS = frozenset({"ruby"})
HEADING_TAGS = frozenset({"h1", "h2", "h3", "h4", "h5", "h6"})


# ---------------------------------------------------------------------------------------------
# Model
# ---------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class Sentence:
    spine: int
    start: int
    """Normalized-character offset of the first matchable char, relative to the chapter."""
    length: int
    """Number of matchable characters in the sentence."""
    text: str
    """Raw text including punctuation, whitespace-collapsed."""
    paragraph: int
    """Paragraph ordinal within the chapter — the unit the translator gets as context."""

    @property
    def id(self) -> str:
        return f"c{self.spine}s{self.start}"

    @property
    def hash(self) -> str:
        return text_hash(self.text)


@dataclass(frozen=True)
class Chapter:
    spine: int
    href: str
    heading: str
    normalized: str
    """The whole chapter in the offset space — used to verify every sentence lands where it says."""
    sentences: list[Sentence] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    """Anything that makes this chapter's offsets untrustworthy. Never silently swallowed."""

    @property
    def char_count(self) -> int:
        return len(self.normalized)


@dataclass(frozen=True)
class EpubBook:
    sync_id: str
    title: str
    spine_count: int
    """Total number of spine itemrefs, INCLUDING linear="no" — the reader indexes chapters by this."""
    chapters: list[Chapter]
    warnings: list[str] = field(default_factory=list)

    @property
    def sentences(self) -> list[Sentence]:
        return [s for chapter in self.chapters for s in chapter.sentences]


class EpubError(RuntimeError):
    """The file is not an EPUB we can read."""


# ---------------------------------------------------------------------------------------------
# Container / OPF
# ---------------------------------------------------------------------------------------------

_CONTAINER_PATH = "META-INF/container.xml"
_OPF_NS = "{http://www.idpf.org/2007/opf}"
_DC_NS = "{http://purl.org/dc/elements/1.1/}"
_CONTAINER_NS = "{urn:oasis:names:tc:opendocument:xmlns:container}"


def _zip_member(archive: zipfile.ZipFile, path: str) -> bytes:
    """Reads a member, tolerating percent-encoding, stray leading slashes and `./` segments."""
    unquoted = urllib.parse.unquote(path)
    candidates = []
    for value in (path, unquoted):
        for variant in (value, value.lstrip("/"), posixpath.normpath(value).lstrip("/")):
            if variant not in candidates:
                candidates.append(variant)
    for candidate in candidates:
        try:
            return archive.read(candidate)
        except KeyError:
            continue
        except (RuntimeError, zipfile.BadZipFile) as exc:
            # Encrypted or corrupt member — a real failure, not a "try the next spelling".
            raise EpubError(f"{path}: unreadable ({exc}).") from exc
    raise EpubError(f"{path}: missing from the archive.")


def _resolve_href(content_dir: str, href: str) -> str:
    """Turns a manifest href into a zip member path.

    `normpath` unconditionally — skipping it when the OPF sits at the archive root (which is the
    common layout) silently lost every `./`-prefixed href, a form several converters emit. The
    fragment is stripped because `chapter.xhtml#top` is a location within a document, not a file.
    """
    href = href.split("#", 1)[0]
    joined = posixpath.join(content_dir, href) if content_dir else href
    return posixpath.normpath(joined).lstrip("/")


def _opf_path(archive: zipfile.ZipFile) -> str:
    try:
        root = ElementTree.fromstring(archive.read(_CONTAINER_PATH))
    except (KeyError, ElementTree.ParseError) as exc:
        raise EpubError("No readable META-INF/container.xml — not an EPUB?") from exc
    for rootfile in root.iter(f"{_CONTAINER_NS}rootfile"):
        full_path = rootfile.get("full-path")
        if full_path:
            return full_path
    raise EpubError("container.xml names no rootfile.")


def _parse_opf(raw: bytes) -> tuple[str, dict[str, str], list[str], list[str]]:
    """Returns (title, {manifest id: href}, [spine idrefs in document order], warnings).

    The spine keeps `linear="no"` itemrefs. EPUBKit does too (EPUBSpineParser.swift), and the
    reader indexes chapters by position in that unfiltered list — dropping them here would shift
    every later chapter and break both translations and bookmarks.
    """
    try:
        root = ElementTree.fromstring(raw)
    except ElementTree.ParseError as exc:
        raise EpubError(f"Malformed OPF package document: {exc}") from exc

    title = ""
    for node in root.iter(f"{_DC_NS}title"):
        title = (node.text or "").strip()
        if title:
            break

    manifest: dict[str, str] = {}
    duplicates: list[str] = []
    for item in root.iter(f"{_OPF_NS}item"):
        item_id, href = item.get("id"), item.get("href")
        if item_id and href:
            if item_id in manifest and manifest[item_id] != href:
                duplicates.append(item_id)
            manifest[item_id] = href

    spine: list[str] = []
    for itemref in root.iter(f"{_OPF_NS}itemref"):
        idref = itemref.get("idref")
        if idref:
            spine.append(idref)

    if not spine:
        raise EpubError("OPF has an empty spine.")
    warnings = [f"duplicate manifest id {d!r} — the last one wins" for d in duplicates]
    return title, manifest, spine, warnings


# ---------------------------------------------------------------------------------------------
# Content documents
# ---------------------------------------------------------------------------------------------


class _ChapterTextExtractor(HTMLParser):
    """Collects a chapter's body text the way the reader's DOM walker sees it.

    Emits into `self.parts` a list of strings and `None` markers, where `None` is a block boundary
    (which ends a sentence). `rt`/`rp` subtrees are dropped, matching `createWalker`'s node filter.
    """

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str | None] = []
        self.heading: str = ""
        self.warnings: list[str] = []
        # A STACK, not a counter: `html.parser` implements no implied end tags, so an unclosed
        # `<rt>` used to make every remaining character in the chapter vanish silently. Knowing
        # WHICH tags are open lets `</ruby>` close an `<rt>` the way a browser does.
        self._skip_stack: list[str] = []
        self._in_body = False
        self._heading_depth = 0
        self._heading_chunks: list[str] = []

    @property
    def _skipping(self) -> bool:
        return bool(self._skip_stack)

    def handle_starttag(self, tag: str, attrs) -> None:  # noqa: ANN001 - stdlib signature
        tag = tag.lower()
        if tag == "body":
            self._in_body = True
        if tag in SKIP_TAGS:
            # `<rt>` implicitly closes a previous `<rt>`/`<rp>` sibling.
            if tag in ("rt", "rp") and self._skip_stack and self._skip_stack[-1] in ("rt", "rp"):
                self._skip_stack.pop()
            self._skip_stack.append(tag)
            return
        if self._skipping:
            return
        if tag in BLOCK_TAGS:
            self.parts.append(None)
        if tag in HEADING_TAGS and not self.heading:
            self._heading_depth += 1

    def handle_startendtag(self, tag: str, attrs) -> None:  # noqa: ANN001 - stdlib signature
        # A self-closing skip tag has no content, so it must not open a skip region.
        if not self._skipping and tag.lower() in BLOCK_TAGS:
            self.parts.append(None)

    def handle_endtag(self, tag: str) -> None:
        tag = tag.lower()
        if tag in SKIP_TAGS:
            if tag in self._skip_stack:
                # Unwind to the matching tag, discarding anything left unclosed inside it.
                while self._skip_stack and self._skip_stack.pop() != tag:
                    pass
            return
        if tag in RUBY_TAGS:
            # `</ruby>` closes any `<rt>`/`<rp>` still open, as every browser does.
            while self._skip_stack and self._skip_stack[-1] in ("rt", "rp"):
                self._skip_stack.pop()
        if self._skipping:
            return
        if tag in BLOCK_TAGS:
            self.parts.append(None)
        if tag in HEADING_TAGS and self._heading_depth > 0:
            self._heading_depth -= 1
            if self._heading_depth == 0 and not self.heading:
                self.heading = " ".join("".join(self._heading_chunks).split())
                self._heading_chunks = []

    def handle_data(self, data: str) -> None:
        if self._skipping:
            # The DOM walker counts `<script>`/`<style>` text (it rejects only rt/rp), so a chapter
            # with either inside its body cannot have offsets that agree across all three
            # implementations. Report it instead of producing addresses nobody can resolve.
            if self._skip_stack[-1] in ("script", "style") and self._in_body and data.strip():
                self.warnings.append(
                    f"<{self._skip_stack[-1]}> with text inside <body>: DOM offsets will not match"
                )
            return
        if not self._in_body:
            return
        self.parts.append(data)
        if self._heading_depth > 0:
            self._heading_chunks.append(data)

    def close(self) -> None:
        super().close()
        if self._skip_stack:
            self.warnings.append(
                f"unclosed <{self._skip_stack[0]}> — text after it was dropped"
            )


def _segment(spine: int, parts: list[str | None]) -> tuple[str, list[Sentence]]:
    """Turns a chapter's text runs into addressable sentences.

    Returns the chapter's normalized string (for verification) and its sentences. Offsets are
    counted in matchable characters only, so they are independent of markup and whitespace.
    """
    sentences: list[Sentence] = []
    normalized_chars: list[str] = []

    buffer: list[str] = []
    buffer_start: int | None = None   # normalized offset of the sentence's first matchable char
    buffer_len = 0                    # matchable chars in the current sentence
    paragraph = 0
    # Index into `buffer` of the last soft-break character, for splitting an over-long run.
    last_soft_break = -1

    def flush() -> None:
        nonlocal buffer, buffer_start, buffer_len, last_soft_break
        if buffer_start is not None and buffer_len > 0:
            text = " ".join("".join(buffer).split())
            if text:
                sentences.append(Sentence(
                    spine=spine,
                    start=buffer_start,
                    length=buffer_len,
                    text=text,
                    paragraph=paragraph,
                ))
        buffer = []
        buffer_start = None
        buffer_len = 0
        last_soft_break = -1

    def split_overlong() -> None:
        """Force-ends a run that has no terminator, preferring the last comma."""
        nonlocal buffer, buffer_start, buffer_len, last_soft_break
        # `last_soft_break > 0`: a break at index 0 would emit nothing (head_len == 0) and leave the
        # buffer unchanged, so the next character pushes one past the cap.
        if 0 < last_soft_break < len(buffer) - 1:
            head, tail = buffer[:last_soft_break + 1], buffer[last_soft_break + 1:]
        else:
            head, tail = buffer[:], []
        head_len = sum(1 for c in head if is_matchable(c))
        text = " ".join("".join(head).split())
        if text and head_len > 0 and buffer_start is not None:
            sentences.append(Sentence(
                spine=spine, start=buffer_start, length=head_len, text=text, paragraph=paragraph,
            ))
        tail_matchable = [c for c in tail if is_matchable(c)]
        buffer = tail
        buffer_len = len(tail_matchable)
        buffer_start = (buffer_start + head_len) if (buffer_start is not None and tail_matchable) else None
        last_soft_break = -1

    index = 0
    while index < len(parts):
        part = parts[index]
        index += 1
        if part is None:
            flush()
            paragraph += 1
            continue

        position = 0
        while position < len(part):
            char = part[position]
            position += 1
            buffer.append(char)
            if is_matchable(char):
                if buffer_start is None:
                    buffer_start = len(normalized_chars)
                normalized_chars.append(char)
                buffer_len += 1
            elif char in SOFT_BREAK:
                last_soft_break = len(buffer) - 1

            if char in SENTENCE_TERMINATORS:
                # Swallow the closing brackets / ellipses that belong to this sentence, exactly as
                # selection.js does when the user taps inside it.
                while position < len(part) and part[position] in TRAILING_CHARS:
                    trailing = part[position]
                    position += 1
                    buffer.append(trailing)
                    if is_matchable(trailing):
                        normalized_chars.append(trailing)
                        buffer_len += 1
                flush()
            elif buffer_len >= MAX_SENTENCE_CHARS:
                split_overlong()

    flush()
    return "".join(normalized_chars), sentences


# ---------------------------------------------------------------------------------------------
# Entry points
# ---------------------------------------------------------------------------------------------


def parse_epub(raw: bytes, sync_id: str, fallback_title: str = "") -> EpubBook:
    """Reads EPUB bytes into addressable sentences."""
    import io

    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
        return _parse_archive(archive, sync_id, fallback_title)


def load_epub(path: Path, sync_id: str, fallback_title: str = "") -> EpubBook:
    """Reads an EPUB from disk."""
    with zipfile.ZipFile(path) as archive:
        return _parse_archive(archive, sync_id, fallback_title or path.stem)


def _parse_archive(archive: zipfile.ZipFile, sync_id: str, fallback_title: str) -> EpubBook:
    opf_path = _opf_path(archive)
    content_dir = posixpath.dirname(opf_path)
    title, manifest, spine, book_warnings = _parse_opf(_zip_member(archive, opf_path))

    chapters: list[Chapter] = []
    for spine_index, idref in enumerate(spine):
        href = manifest.get(idref)
        if href is None:
            # A dangling idref still occupies a spine slot on the device, so the index must not
            # shift — record an empty chapter rather than skipping it. But say so: a spine item we
            # cannot read is a chapter whose sentences will all be missing.
            chapters.append(Chapter(spine=spine_index, href="", heading="", normalized="",
                                    warnings=[f"spine item {idref!r} is not in the manifest"]))
            continue
        member = _resolve_href(content_dir, href)
        try:
            raw = _zip_member(archive, member)
        except EpubError as exc:
            chapters.append(Chapter(spine=spine_index, href=href, heading="", normalized="",
                                    warnings=[str(exc)]))
            continue

        text = raw.decode("utf-8", errors="replace")
        extractor = _ChapterTextExtractor()
        extractor.feed(text)
        extractor.close()
        normalized, sentences = _segment(spine_index, extractor.parts)
        warnings = list(dict.fromkeys(extractor.warnings))
        warnings.extend(_cross_check(text, normalized))
        chapters.append(Chapter(
            spine=spine_index,
            href=href,
            heading=extractor.heading,
            normalized=normalized,
            sentences=sentences,
            warnings=warnings,
        ))

    return EpubBook(
        sync_id=sync_id,
        title=(title or fallback_title or sync_id).strip(),
        spine_count=len(spine),
        chapters=chapters,
        warnings=book_warnings,
    )


# ---------------------------------------------------------------------------------------------
# Independent cross-check
# ---------------------------------------------------------------------------------------------

_COMMENT_RE = regex.compile(r"(?s)<!--.*?-->")
_BODY_RE = regex.compile(r"(?s)<body.*?</body>")
_RT_RE = regex.compile(r"(?s)<rt[^>]*>.*?</rt>")
_SCRIPT_STYLE_RE = regex.compile(r"(?s)<(script|style)[^>]*>.*?</\1>")
_TAG_RE = regex.compile(r"<[^>]+>")


def filtered_oracle(raw: str) -> str:
    """A second, independent normalizer: the app's `String.filtered()` algorithm, in Python.

    Deliberately markup-regex-based rather than parser-based, because that is the whole point — it
    shares no code with `_ChapterTextExtractor`, so comparing the two catches the failures a
    self-comparison cannot: a subtree wrongly skipped, a `<script>` leaking text, an unclosed tag
    swallowing the rest of a chapter.

    One deliberate difference from Swift: entities are decoded in full rather than the four named
    ones `filtered()` handles, so a numeric entity does not show up as a spurious divergence. That
    is a real Swift bug (it leaves `&#12354;` as the matchable digits `12354`) but it belongs to
    `bookinfo.characterCount`, not here.
    """
    text = _COMMENT_RE.sub("", raw)
    body = _BODY_RE.search(text)
    if body:
        text = body.group(0)
    text = _RT_RE.sub("", text)
    text = _SCRIPT_STYLE_RE.sub("", text)
    text = _TAG_RE.sub("", text)
    return normalize(html.unescape(text))


def _cross_check(raw: str, normalized: str) -> list[str]:
    """Compares the parsed chapter against the oracle. Returns a warning per divergence."""
    expected = filtered_oracle(raw)
    if expected == normalized:
        return []
    # Report where they part company — that is what tells you which element is responsible.
    limit = min(len(expected), len(normalized))
    at = next((i for i in range(limit) if expected[i] != normalized[i]), limit)
    return [
        f"parser and String.filtered() disagree ({len(normalized)} vs {len(expected)} chars, "
        f"first difference at offset {at}: {normalized[at:at + 12]!r} vs {expected[at:at + 12]!r})"
    ]


def verify(book: EpubBook) -> list[str]:
    """Checks every sentence resolves to exactly where its address says. Returns problem strings.

    This is the invariant the reader relies on: it walks the DOM counting matchable characters and
    expects `[start, start + length)` to be this sentence. A failure here means buttons would be
    placed on the wrong text — the reader would catch it via the hash and silently drop them.
    """
    problems: list[str] = list(book.warnings)
    for chapter in book.chapters:
        # The parser-vs-oracle divergences and unclosed-tag reports. Without these, `verify` only
        # proves `_segment` is self-consistent — which it is even when the text it was handed is
        # missing half the chapter.
        problems.extend(f"c{chapter.spine}: {w}" for w in chapter.warnings)
        seen: set[int] = set()
        for sentence in chapter.sentences:
            window = chapter.normalized[sentence.start:sentence.start + sentence.length]
            expected = normalize(sentence.text)
            if window != expected:
                problems.append(
                    f"{sentence.id}: chapter text {window[:24]!r} != sentence {expected[:24]!r}"
                )
            if sentence.start in seen:
                problems.append(f"{sentence.id}: duplicate address")
            seen.add(sentence.start)
    return problems
