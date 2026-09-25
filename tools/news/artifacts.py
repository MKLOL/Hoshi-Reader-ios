"""Build a one-chapter news EPUB and the existing Hoshi sentence sidecar."""

import datetime as dt
import hashlib
import html
import io
import json
from pathlib import Path
import re
import struct
import unicodedata
from urllib.parse import urlsplit, urlunsplit
import xml.etree.ElementTree as ET
import zipfile

from segment import normalize, segment


PROMPT_ID = "news-tutor-v1"
MAX_BYTES = 16 * 1024 * 1024
ALLOWED = set("p h1 h2 h3 h4 h5 h6 ul ol li blockquote ruby rt rp rb br strong em b i "
              "table thead tbody tr td th div figure figcaption".split())
DROPPED = set("script style nav header footer aside iframe form button input select textarea "
              "svg noscript video audio canvas object embed template head link meta img".split())
DIGITS = str.maketrans("0123456789", "０１２３４５６７８９")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def string(obj, key):
    value = obj.get(key) if isinstance(obj, dict) else None
    require(isinstance(value, str) and bool(value.strip()), f"{key} must be a nonempty string")
    return value


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n").encode("utf-8")


def reject_duplicate_keys(pairs):
    value = {}
    for key, item in pairs:
        require(key not in value, f"Duplicate JSON key: {key}")
        value[key] = item
    return value


def read_json(path):
    require(path.stat().st_size <= MAX_BYTES, "JSON file is too large")
    return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=reject_duplicate_keys)


def write(path, body):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_bytes(body)
    temporary.replace(path)


def sha(body):
    return "sha256:" + hashlib.sha256(body).hexdigest()


def canonical_url(url):
    parts = urlsplit(url.strip())
    require(parts.scheme in {"http", "https"} and parts.hostname and not parts.username
            and not parts.password, "sourceUrl must be an http(s) article URL without credentials")
    require(not any(c.isspace() for c in url), "sourceUrl must not contain whitespace")
    return urlunsplit((parts.scheme.lower(), parts.netloc.lower(), parts.path or "/", parts.query, ""))


def escape(text):
    return html.escape(text, quote=True)


def sanitize(fragment, inline=False):
    require(isinstance(fragment, str), "bodyXhtml/titleXhtml must be a string")
    require(not re.search(r"<!\s*(DOCTYPE|ENTITY)", fragment, re.I), "XML declarations are not allowed")
    try:
        root = ET.fromstring("<div>" + fragment + "</div>")
    except ET.ParseError as error:
        raise ValueError("Article fragment must be well-formed XHTML; alternatively use paragraphs") from error

    def children(node):
        output = escape((node.text or "").translate(DIGITS))
        for child in node:
            tag = child.tag.split("}")[-1].lower()
            if tag not in DROPPED:
                inside = children(child)
                keep = tag in ALLOWED and (not inline or tag in {"ruby", "rt", "rp", "rb", "strong", "em", "b", "i"})
                output += ("<br/>" if tag == "br" else f"<{tag}>{inside}</{tag}>") if keep else inside
            output += escape((child.tail or "").translate(DIGITS))
        return output

    return children(root)


def content_hash(files):
    digest = hashlib.sha256()
    for name, body in sorted(files.items(), key=lambda item: unicodedata.normalize("NFC", item[0]).encode()):
        name_bytes = unicodedata.normalize("NFC", name).encode("utf-8")
        digest.update(struct.pack(">I", len(name_bytes)))
        digest.update(name_bytes)
        digest.update(struct.pack(">Q", len(body)))
        digest.update(body)
    return "sha256:" + digest.hexdigest()


def epub_files(article, generated_at):
    title = string(article, "title").strip()
    url = canonical_url(string(article, "sourceUrl"))
    source = string(article, "sourceName").strip()
    published = article.get("publishedAt")
    if published is not None:
        require(isinstance(published, str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}", published),
                "publishedAt must be YYYY-MM-DD or omitted")
        dt.date.fromisoformat(published)
    require(("bodyXhtml" in article) != ("paragraphs" in article), "Provide exactly one of bodyXhtml or paragraphs")
    if "paragraphs" in article:
        paragraphs = article["paragraphs"]
        require(isinstance(paragraphs, list) and paragraphs and all(isinstance(p, str) and p.strip() for p in paragraphs),
                "paragraphs must be a nonempty list of nonempty strings")
        body = "\n".join(f"<p>{escape(p.translate(DIGITS))}</p>" for p in paragraphs)
    else:
        body = sanitize(article["bodyXhtml"])
    require(segment(body), "Article has no readable text")
    headline = sanitize(article["titleXhtml"], inline=True) if "titleXhtml" in article else escape(title.translate(DIGITS))
    headline_text = "".join(s["text"] for s in segment(headline))
    require(normalize(headline_text) == normalize(title.translate(DIGITS)), "titleXhtml must match title (excluding ruby readings)")
    identifier = "urn:hoshi-news:" + hashlib.sha256(url.encode()).hexdigest()[:32]
    package = f'''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="pub-id" xml:lang="ja">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="pub-id">{identifier}</dc:identifier>
    <dc:title>{escape(title)}</dc:title><dc:language>ja</dc:language>
    <dc:publisher>{escape(source)}</dc:publisher><dc:source>{escape(url)}</dc:source>
    {f"<dc:date>{published}</dc:date>" if published else ""}
    <meta property="dcterms:modified">{generated_at}</meta>
  </metadata>
  <manifest>
    <item id="article" href="article.xhtml" media-type="application/xhtml+xml"/>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="style" href="style.css" media-type="text/css"/>
  </manifest>
  <spine toc="ncx"><itemref idref="article"/></spine>
</package>
'''
    files = {
        "mimetype": "application/epub+zip",
        "META-INF/container.xml": '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
        "OEBPS/content.opf": package,
        "OEBPS/article.xhtml": f'''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="ja" lang="ja"><head><meta charset="utf-8"/>
<title>{escape(title)}</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
<body><h1>{headline}</h1>\n{body}\n</body></html>''',
        "OEBPS/style.css": "body { line-height: 1.8; } h1 { font-size: 1.4em; line-height: 1.4; }\n",
        "OEBPS/nav.xhtml": f'''<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>{escape(title)}</title></head><body><nav epub:type="toc"><ol><li><a href="article.xhtml">{escape(title)}</a></li></ol></nav></body></html>''',
        "OEBPS/toc.ncx": f'''<?xml version="1.0"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head><meta name="dtb:uid" content="{identifier}"/><meta name="dtb:depth" content="1"/></head><docTitle><text>{escape(title)}</text></docTitle><navMap><navPoint id="article" playOrder="1"><navLabel><text>{escape(title)}</text></navLabel><content src="article.xhtml"/></navPoint></navMap></ncx>''',
    }
    encoded = {name: body.encode("utf-8") for name, body in files.items()}
    for name, body in encoded.items():
        if name.endswith((".xml", ".xhtml", ".opf", ".ncx")):
            try:
                ET.fromstring(body)
            except ET.ParseError as error:
                raise ValueError(f"Invalid XML characters in {name}; correct the source snapshot") from error
    return encoded


def prepare(article_path, job):
    article = read_json(article_path)
    url = canonical_url(string(article, "sourceUrl"))
    generated_at = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    files = epub_files(article, generated_at)
    sync_id = "news_" + hashlib.sha256(url.encode()).hexdigest()[:24]
    sentences = segment(files["OEBPS/article.xhtml"].decode())
    plan = dict(version=1, syncId=sync_id, title=article["title"].strip(), sourceUrl=url,
                sourceName=article["sourceName"], generatedAt=generated_at, promptId=PROMPT_ID,
                spineCount=1, contentSha256=content_hash(files), sentences=sentences)
    # A new directory is required: an accidental second prepare must not erase agent work.
    job.mkdir(parents=True, exist_ok=False)
    for name, body in files.items():
        write(job / "book" / name, body)
    write(job / "article.json", json_bytes(article))
    write(job / "plan.json", json_bytes(plan))
    write(job / "translations.json", json_bytes(dict(
        version=1, syncId=sync_id, model="agent-authored", entries=[
            dict(id=s["id"], text=s["text"], translation="", words=[], grammar="") for s in sentences
        ])))
    write(job / "prompt.md", Path(__file__).with_name("tutor-prompt.md").read_bytes())
    return plan


def coverage_text(text):
    # Unlike address normalization, this also checks non-Japanese letters and symbols.
    return "".join(c for c in text if not c.isspace() and not unicodedata.category(c).startswith("P"))


def cell(text):
    # Markdown tables are supported by the existing AI popup. Escape embedded markup.
    return escape(" ".join(text.split())).replace("\\", "\\\\").replace("|", "&#124;").replace("*", "&#42;").replace("_", "&#95;").replace("`", "&#96;")


def make_sidecar(plan, translations):
    require(isinstance(translations, dict) and translations.get("version") == 1, "Unsupported translations version")
    require(translations.get("syncId") == plan["syncId"], "Translations belong to another job")
    model = string(translations, "model")
    rows = translations.get("entries")
    require(isinstance(rows, list), "Translation entries must be a list")
    by_id = {}
    for row in rows:
        sentence_id = string(row, "id")
        require(sentence_id not in by_id, f"Duplicate sentence {sentence_id}")
        by_id[sentence_id] = row
    require(set(by_id) == {s["id"] for s in plan["sentences"]}, "Translations must cover every planned sentence exactly once")
    entries = {}
    for sentence in plan["sentences"]:
        row = by_id[sentence["id"]]
        require(row.get("text") == sentence["text"], f"{sentence['id']}: source text changed")
        translation, grammar = string(row, "translation"), string(row, "grammar")
        words = row.get("words")
        require(isinstance(words, list) and words, f"{sentence['id']}: complete word table required")
        table = ["| Word | Furigana / reading | Romaji | Meaning |", "| --- | --- | --- | --- |"]
        surfaces = []
        for word in words:
            fields = [string(word, key) for key in ("surface", "reading", "romaji", "meaning")]
            surfaces.append(fields[0])
            table.append("| " + " | ".join(cell(field) for field in fields) + " |")
        require(coverage_text("".join(surfaces)) == coverage_text(sentence["text"]),
                f"{sentence['id']}: word table skips, repeats, changes, or reorders source words")
        explanation = "**Word by word**\n\n" + "\n".join(table) + "\n\n**Grammar**\n\n" + grammar.strip()
        entries[sentence["id"]] = {k: v for k, v in sentence.items() if k != "id"}
        entries[sentence["id"]].update(translation=translation.strip(), explanation=explanation)
    return dict(version=1, kind="epub", syncId=plan["syncId"], title=plan["title"], model=model,
                promptId=PROMPT_ID, generatedAt=plan["generatedAt"], spineCount=1, entries=entries)


def bundle(job):
    plan = read_json(job / "plan.json")
    require(isinstance(plan, dict) and plan.get("version") == 1 and plan.get("promptId") == PROMPT_ID,
            "Unsupported job; prepare it with this tool version")
    article = read_json(job / "article.json")
    expected = epub_files(article, string(plan, "generatedAt"))
    actual = {}
    for path in (job / "book").rglob("*"):
        require(not path.is_symlink(), "Book cannot contain symlinks")
        if path.is_file():
            require(path.stat().st_size <= MAX_BYTES, "Book file too large")
            actual[path.relative_to(job / "book").as_posix()] = path.read_bytes()
    require(actual == expected and content_hash(actual) == plan.get("contentSha256"),
            "EPUB changed after preparation; prepare a new job before translating")
    require(plan.get("sentences") == segment(actual["OEBPS/article.xhtml"].decode()), "Sentence plan changed")
    source_url = canonical_url(string(article, "sourceUrl"))
    require(plan.get("syncId") == "news_" + hashlib.sha256(source_url.encode()).hexdigest()[:24]
            and plan.get("title") == article["title"].strip() and plan.get("sourceUrl") == source_url
            and plan.get("spineCount") == 1, "Job identity changed")
    sidecar = make_sidecar(plan, read_json(job / "translations.json"))
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, "w") as archive:
        for name in ["mimetype"] + sorted(set(actual) - {"mimetype"}):
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_STORED if name == "mimetype" else zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, actual[name])
    epub = stream.getvalue()
    manifest = dict(sha256=sha(epub), sizeBytes=len(epub), originalName=plan["syncId"],
                    format="epub", contentSha256=plan["contentSha256"])
    metadata = dict(title=plan["title"], contentType="epub", shelfName="News",
                    shelfUpdatedAt=plan["generatedAt"], importedAt=plan["generatedAt"])
    preview = f"# {plan['title']}\n\nSource: {plan['sourceUrl']}\n\n"
    for sentence_id, entry in sidecar["entries"].items():
        preview += f"## {sentence_id}\n\n{entry['text']}\n\n{entry['translation']}\n\n{entry['explanation']}\n\n"
    outputs = {"article.epub": epub, "epub.manifest.json": json_bytes(manifest),
               "metadata.json": json_bytes(metadata), "sentence_translations.json": json_bytes(sidecar),
               "preview.md": preview.encode("utf-8")}
    require(all(len(value) <= MAX_BYTES for value in outputs.values()), "Article bundle exceeds the 16 MiB per-file limit")
    return plan, outputs


def build(job):
    plan, outputs = bundle(job)
    for name, body in outputs.items():
        write(job / name, body)
    return plan


def validated_uploads(job):
    plan, outputs = bundle(job)
    for name, expected in outputs.items():
        path = job / name
        require(path.is_file() and path.read_bytes() == expected,
                f"{name} is missing or stale; run build before publishing")
    # Manifest is last: its presence lets Android import a remote-only book.
    specs = [("epub.zip", "article.epub", "application/zip"),
             ("sentences", "sentence_translations.json", "application/json; charset=utf-8"),
             ("metadata", "metadata.json", "application/json; charset=utf-8"),
             ("epub.manifest", "epub.manifest.json", "application/json; charset=utf-8")]
    uploads = [(f"books/{plan['syncId']}/{suffix}", mime, outputs[file]) for suffix, file, mime in specs]
    return plan, uploads
