#!/usr/bin/env python3
"""Seed the "IDB Zoom Fixture" manga book into a simulator app container.

The UITests in UITests/ZoomPopupUITests.swift are non-hermetic: they expect a mokuro book titled
"IDB Zoom Fixture" already present in the app's data container. This writes a minimal one
(3 blank pages at 1179x2556, two OCR blocks on page 1: 「日本語のテキスト」 near the top and
「二回目のテスト」 lower down) that is sufficient for the AI-popup tests
(testNearTopAiButtonRespondsAndSecondTapDoesNotCrash, testLongPressOnTranslationWordDoesNotCrash).
The action-toolbar layout tests were written against a richer original fixture and may need it.

Usage:
    python3 tools/seed_zoom_fixture.py "$(xcrun simctl get_app_container <udid> com.dragosristache.hoshireader data)"

`xcodebuild test` can rotate the container UUID, so re-query the path if the shelf comes up empty.
No third-party modules: the PNGs are written with zlib.
"""

container = sys.argv[1]
title = "IDB Zoom Fixture"
root = os.path.join(container, "Library", "Application Support", "Books", title)
os.makedirs(os.path.join(root, "images"), exist_ok=True)

def png(width, height, rects):
    # rects: list of (x0,y0,x1,y1,(r,g,b)) painted over a white page
    rows = []
    for y in range(height):
        row = bytearray(b"\xff" * (width * 3))
        for (x0, y0, x1, y1, c) in rects:
            if y0 <= y < y1:
                row[x0*3:x1*3] = bytes(c) * (x1 - x0)
        rows.append(b"\x00" + bytes(row))
    raw = b"".join(rows)
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))

W, H = 1179, 2556
blocks = [
    {"box": [200, 120, 760, 190], "vertical": False, "font_size": 56,
     "lines": ["日本語のテキスト"], "lines_coords": [[[200,120],[760,120],[760,190],[200,190]]]},
    {"box": [200, 1200, 700, 1270], "vertical": False, "font_size": 56,
     "lines": ["二回目のテスト"], "lines_coords": [[[200,1200],[700,1200],[700,1270],[200,1270]]]},
]
rects = [(b["box"][0], b["box"][1], b["box"][2], b["box"][3], (200, 200, 200)) for b in blocks]
rects.append((0, 0, W, 60, (120, 160, 220)))  # top band so the page is visibly a page
pages = []
for i in range(3):
    name = f"images/page{i+1:03d}.png"
    with open(os.path.join(root, name), "wb") as f:
        f.write(png(W, H, rects if i == 0 else [(0, 0, W, 60, (220, 160, 120))]))
    pages.append({"img_width": W, "img_height": H, "img_path": name, "blocks": blocks if i == 0 else []})

with open(os.path.join(root, "mokuro.json"), "w") as f:
    json.dump({"title": title, "volume": title, "pages": pages}, f, ensure_ascii=False)
with open(os.path.join(root, "cover.png"), "wb") as f:
    f.write(png(120, 180, [(0, 0, 120, 40, (120, 160, 220))]))
ref = datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc).timestamp()
meta = {"id": str(uuid.uuid4()).upper(), "title": title, "cover": f"Books/{title}/cover.png",
        "folder": title, "lastAccess": time.time() - ref, "contentType": "mokuro",
        "importedAt": "2026-09-01T00:00:00Z", "syncId": "book_idbzoomfixture"}
with open(os.path.join(root, "metadata.json"), "w") as f:
    json.dump(meta, f, ensure_ascii=False, indent=2)
with open(os.path.join(root, "bookmark.json"), "w") as f:
    json.dump({"chapterIndex": 0, "progress": 0, "characterCount": 0}, f)
print("seeded", root)
