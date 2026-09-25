"""Synthetic developer fixture only; never a translator for real articles."""

import argparse
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from artifacts import build, json_bytes, prepare, read_json, write
from segment import segment

FIXTURES = Path(__file__).with_name("fixtures")


def make_fixture(job):
    prepare(FIXTURES / "article.json", job)
    lessons = read_json(FIXTURES / "lessons.json")
    translations = read_json(job / "translations.json")
    translations["model"] = "synthetic-test-fixture"
    for entry in translations["entries"]:
        entry.update(lessons[entry["text"]])
    write(job / "translations.json", json_bytes(translations))
    build(job)
    # Exercise the real Python segmenter against Kotlin, including normalization ranges,
    # HTML run boundaries, ruby, entities, supplementary code points, and overlong clauses.
    bodies = [
        '<p>「行こう！」と彼は言った。本当に？</p>',
        '<p>「あ！<em>」</em>と<span>言った</span>。</p>',
        '<p>Ver. 2.5 が出た。</p>',
        '<h1>第一章</h1><p>朝だ<br/>起きる</p><div>終わり。</div>',
        '<p><ruby>漢<rt>かん</rt>字<rt>じ</rt></ruby>を読む。</p>',
        '<p><ruby>今<rt>いま</ruby>から行く。</p>',
        '<p>one\n   two&nbsp;&nbsp;three。</p>',
        '<p>山﨑さん。𠀀𱍐々〻〇○◯。次。</p>',
        '<p>caf&eacute; は良い。&yen;100だ。次の文。</p>',
        '<p>a&ampb。&#12354&#x3042;&notit;。&#128;&#0;&#x1;x。</p>',
        '<p>if a < b then。次。</p><p>第一<![CDATA[x > y]]>章。<!-- 。 -->終。</p>',
        '<p>本文。</p><script>if (a < b) {}</script><p>次。</p><style>a>b{}</style><p>三。</p>',
        '<p>' + ('あ' * 250 + '、') * 3 + '。</p>',
        '<p>' + '𠀀' * 801 + '。</p>',
    ]
    vectors = []
    for body in bodies:
        html = '<html><head><title>無視</title></head><body>' + body + '</body></html>'
        vectors.append(dict(html=html, sentences=segment(html, 3)))
    write(job / "segmentation-vectors.json", json_bytes(vectors))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    make_fixture(parser.parse_args().out)
