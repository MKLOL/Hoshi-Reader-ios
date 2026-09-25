"""Sentence addresses compatible with EpubSentenceSegmenter / EpubTranslationStore.

Offsets count the reader's matchable Unicode code points, not Python string offsets,
UTF-16 units, punctuation, whitespace, or ruby readings. Keep the interoperability
test against the actual Kotlin segmenter when changing these rules.
"""

import hashlib
from html.parser import HTMLParser


RANGES = (
    (0x30, 0x39), (0x41, 0x5A), (0x61, 0x7A), (0x3005, 0x3007),
    (0x3041, 0x3096), (0x309D, 0x309E), (0x30A1, 0x30FA),
    (0xFF10, 0xFF19), (0xFF21, 0xFF3A), (0xFF41, 0xFF5A), (0xFF66, 0xFF9D),
    (0x2E80, 0x2EF3), (0x2F00, 0x2FD5), (0x3400, 0x4DBF), (0x4E00, 0x9FFF),
    (0x20000, 0x2A6DF), (0x2A700, 0x2B739), (0x2B740, 0x2B81D),
    (0x2B820, 0x2CEA1), (0x2CEB0, 0x2EBE0), (0x2EBF0, 0x2EE5D),
    (0x30000, 0x3134A), (0x31350, 0x323AF),
)
SINGLE = {0x25CB, 0x25EF, 0x303B, 0x30FC, 0xFA0E, 0xFA0F, 0xFA11, 0xFA13,
          0xFA14, 0xFA1F, 0xFA21, 0xFA23, 0xFA24, 0xFA27, 0xFA28, 0xFA29}
BLOCKS = set("p div br hr li dd dt blockquote pre figcaption figure h1 h2 h3 h4 h5 h6 "
             "section article aside nav header footer main table thead tbody tfoot tr td th "
             "caption ul ol dl".split())
SKIP = {"rt", "rp", "script", "style"}
END = "。！？!?"
TRAILING = "。、！？…‥」』）)】〉》〕｝}］]"


def matchable(char):
    cp = ord(char)
    return cp in SINGLE or any(start <= cp <= end for start, end in RANGES)


def normalize(text):
    return "".join(char for char in text if matchable(char))


def text_hash(text):
    return hashlib.sha256(normalize(text).encode("utf-8")).hexdigest()[:16]


class ChapterText(HTMLParser):
    def __init__(self, html):
        super().__init__(convert_charrefs=True)
        self.in_body = "<body" not in html.lower()
        self.skipping = []
        self.parts = []
        self.feed(html)
        self.close()

    def handle_starttag(self, tag, attrs):
        if tag == "body":
            self.in_body = True
        if tag in SKIP:
            if tag in {"rt", "rp"} and self.skipping and self.skipping[-1] in {"rt", "rp"}:
                self.skipping.pop()
            self.skipping.append(tag)
        elif not self.skipping and tag in BLOCKS:
            self.parts.append(None)

    def handle_startendtag(self, tag, attrs):
        if tag not in SKIP and not self.skipping and tag in BLOCKS:
            self.parts.append(None)

    def handle_endtag(self, tag):
        if tag in SKIP:
            if tag in self.skipping:
                while self.skipping.pop() != tag:
                    pass
            return
        if tag == "ruby":
            while self.skipping and self.skipping[-1] in {"rt", "rp"}:
                self.skipping.pop()
        if self.skipping:
            return
        if tag in BLOCKS:
            self.parts.append(None)
        if tag == "body":
            self.in_body = False

    def handle_data(self, data):
        if self.in_body and not self.skipping:
            self.parts.append(data)


def segment(html, spine=0):
    sentences = []
    count, length, start, soft_break = 0, 0, None, -1
    buffer = []

    def emit(chars, offset):
        text = " ".join("".join(chars).split())
        size = len(normalize(text))
        if size and offset is not None:
            sentences.append(dict(id=f"c{spine}s{offset}", spine=spine, start=offset,
                                  len=size, text=text, hash=text_hash(text)))

    def flush():
        nonlocal buffer, length, start, soft_break
        emit(buffer, start)
        buffer, length, start, soft_break = [], 0, None, -1

    for part in ChapterText(html).parts:
        if part is None:
            flush()
            continue
        pos = 0
        while pos < len(part):
            char = part[pos]
            pos += 1
            buffer.append(char)
            if matchable(char):
                if start is None:
                    start = count
                count += 1
                length += 1
            elif char in "、，,":
                soft_break = len(buffer) - 1
            if char in END:
                while pos < len(part) and part[pos] in TRAILING:
                    buffer.append(part[pos])
                    pos += 1
                flush()
            elif length >= 400:
                end = soft_break + 1 if 1 <= soft_break < len(buffer) - 1 else len(buffer)
                head, tail = buffer[:end], buffer[end:]
                head_length = len(normalize("".join(head)))
                emit(head, start)
                length = len(normalize("".join(tail)))
                start = start + head_length if start is not None and length else None
                buffer, soft_break = tail, -1
    flush()
    return sentences
