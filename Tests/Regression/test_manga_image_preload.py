"""Exercise the actual Foundation image backend and generated WebKit decode script."""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


class MangaImagePreloadTests(unittest.TestCase):
    def test_current_bytes_budget_reuse_window_and_decode_cancellation(self):
        if not shutil.which("swiftc") or not shutil.which("node"):
            self.skipTest("Swift and Node are needed for image backend behavior")
        root = Path(__file__).resolve().parents[2]
        harness = r'''
import Foundation

@main struct Check {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["0.jpg", "1.jpg", "2.jpg", "quote\" #日本.jpg"] {
            try Data([1,2,3]).write(to: root.appendingPathComponent(path))
        }
        let paths: Set<String> = ["0.jpg", "1.jpg", "2.jpg", "quote\" #日本.jpg", "../outside.jpg"]
        let loader = MangaImageLoader(encodedBudget: 4)
        await loader.configure(root: root, declaredPaths: paths)
        await loader.setWindow(["1.jpg", "0.jpg", "2.jpg"])
        let first = await loader.source(relativePath: "1.jpg")!
        let url = URL(string: first.url)!
        let bytes = try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<4 { group.addTask { try await loader.image(for: url, allowedPaths: paths) } }
            var result: [Data] = []
            for try await data in group { result.append(data) }
            return result
        }
        precondition(bytes == Array(repeating: Data([1,2,3]), count: 4))
        let shared = await loader.snapshot()
        precondition(shared.reads == 1 && shared.hits == 3 && shared.bytes == 3)
        let far = await loader.source(relativePath: "2.jpg")!
        _ = try await loader.image(for: URL(string: far.url)!, allowedPaths: paths)
        let retained = await loader.snapshot()
        precondition(retained.entries == 1 && retained.bytes == 3)
        // Replaced bytes invalidate both the retained entry and the generated image URL.
        try Data([7,8]).write(to: root.appendingPathComponent("1.jpg"))
        let replaced = await loader.source(relativePath: "1.jpg")!
        precondition(first.url != replaced.url)
        let current = try await loader.image(for: URL(string: replaced.url)!, allowedPaths: paths)
        precondition(current == Data([7,8]))
        let replacement = await loader.snapshot()
        precondition(replacement.bytes == 2 && replacement.entries == 1)
        await loader.setWindow(["0.jpg"])
        let pruned = await loader.snapshot()
        precondition(pruned.bytes == 0 && pruned.entries == 0)
        let other = MangaImageLoader(encodedBudget: 0)
        await other.configure(root: root, declaredPaths: paths)
        await other.setWindow(["1.jpg"])
        let otherSource = await other.source(relativePath: "1.jpg")!
        precondition(otherSource.url != replaced.url)
        let uncached = try await other.image(for: URL(string: otherSource.url)!, allowedPaths: paths)
        precondition(uncached == current)
        let zeroBudget = await other.snapshot()
        precondition(zeroBudget.bytes == 0 && zeroBudget.entries == 0)
        let beforeCancel = await loader.snapshot()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await loader.prepare(["0.jpg"])
        }
        await cancelled.value
        let afterCancel = await loader.snapshot()
        precondition(beforeCancel == afterCancel)
        do {
            _ = try await loader.image(for: URL(string: "hoshi-img://other/0.jpg")!, allowedPaths: paths)
            preconditionFailure("Wrong hosts must not serve book bytes")
        } catch {}
        let denied = await loader.source(relativePath: "../outside.jpg")
        precondition(denied == nil)
        let quoted = await loader.source(relativePath: "quote\" #日本.jpg")!
        precondition(URLComponents(string: quoted.url)!.path == "/quote\" #日本.jpg")
        precondition(mangaAdjacentPreloadIndexes(currentIndex: 4, pageCount: 8) == [5,3,6,2,7])
        precondition(mangaAdjacentPreloadIndexes(currentIndex: 0, pageCount: 1).isEmpty)
        precondition(MangaImagePredecode.estimatedBytes(width: Int.max, height: Int.max) == Int.max)
        let candidates = ["one", "broken", "oversize", "two", "three"].map { MangaImageDecodeCandidate(url: $0, width: 1, height: 1) }
        let script = MangaImagePredecode.script(pageIndex: 0, candidates: candidates, budget: 128)
        try script.write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
        await loader.cancelPreparation()
        let cleared = await loader.snapshot()
        precondition(cleared.bytes == 0 && cleared.entries == 0)
    }
}
'''
        js = r'''
const assert = require('node:assert/strict');
const fs = require('node:fs');
const events = new Map();
global.window = global;
window.addEventListener = (name, fn) => events.set(name, fn);
window.removeEventListener = name => events.delete(name);
global.document = {hidden:false, querySelector:()=>({}), addEventListener(){}, removeEventListener(){}};
let active = 0, maximum = 0;
global.Image = class {
  set src(value) {
    this.value = value;
    this.naturalWidth = value === 'oversize' ? 1000 : 4;
    this.naturalHeight = 4;
    queueMicrotask(() => this.onload && this.onload());
  }
  decode() {
    maximum = Math.max(maximum, ++active);
    return new Promise((resolve,reject) => setTimeout(() => {
      active--;
      this.value === 'broken' ? reject(new Error('invalid image')) : resolve();
    },0));
  }
  removeAttribute() { this.value = null; }
};
eval(fs.readFileSync(process.argv[1],'utf8'));
setTimeout(() => {
  const state = window.hoshiMangaImageCache;
  assert.equal(state.done, true);
  assert.deepEqual(state.decoded, ['one','two']);
  assert.deepEqual(state.failed, ['broken','oversize']);
  assert.deepEqual(state.skipped, ['three']);
  assert.equal(state.bytes,128);
  assert.equal(maximum,1);
  events.get('pagehide')();
  assert.equal(state.bytes,0);
  assert.equal(state.images.length,0);
},50);
'''
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            main = folder / "Main.swift"
            main.write_text(harness)
            binary = folder / "check"
            script = folder / "decode.js"
            subprocess.run(["swiftc", "-parse-as-library", str(root / "Features/MangaReader/MangaImageLoader.swift"),
                            str(root / "Features/MangaReader/MangaImagePredecode.swift"), str(main), "-o", str(binary)], check=True, timeout=90)
            subprocess.run([str(binary), str(script)], check=True, timeout=30)
            subprocess.run(["node", "-e", js, str(script)], check=True, timeout=5)


if __name__ == "__main__":
    unittest.main()
