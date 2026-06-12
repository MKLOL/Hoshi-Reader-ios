# Cross-platform sync conformance vectors.
#
# The SAME decision table lives in the Android repo at
# app/src/test/java/moe/antimony/hoshi/features/sync/http/SyncConformanceTest.kt and runs against
# the real Kotlin implementation. Here the table runs against a Python re-implementation of the
# spec (this repo has no Swift test target), plus source assertions pinning the Swift
# implementation to the exact same decision lines. If either platform's behavior drifts, one of
# the two suites breaks.
#
# Spec (SyncCore.swift `compareRevisioned` / HttpSyncBlobs.kt):
#   - rev (edit depth, Lamport counter) first; nil == 0
#   - RFC 3339 timestamps break rev ties
#   - equal rev + equal stamp -> tie

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def read(relative_path: str) -> str:
    return (ROOT / relative_path).read_text(encoding="utf-8")


def compare_rfc3339(a, b):
    sa, sb = a or "", b or ""
    # Lexicographic stand-in: valid ONLY for same-precision Z-suffixed stamps, which is
    # all both clients emit (the real impls parse to instants). Keep vectors same-precision.
    return (sa > sb) - (sa < sb)


def compare_revisioned(local_rev, remote_rev, local_stamp, remote_stamp):
    lr = local_rev or 0
    rr = remote_rev or 0
    if lr != rr:
        return "local" if lr > rr else "remote"
    cmp = compare_rfc3339(local_stamp, remote_stamp)
    if cmp > 0:
        return "local"
    if cmp < 0:
        return "remote"
    return "tie"


def should_apply_remote_shelf_placement(remote_updated_at, local_updated_at):
    if local_updated_at is None:
        return True
    if remote_updated_at is None:
        return False
    return compare_rfc3339(remote_updated_at, local_updated_at) >= 0


OLD = "2026-01-01T00:00:00Z"
NEW = "2026-06-01T00:00:00Z"

# (localRev, remoteRev, localStamp, remoteStamp) -> winner. Mirrors SyncConformanceTest.kt.
COMPARE_VECTORS = [
    # All four nil/0 combos: legacy blobs degrade to pure stamp LWW. NOTE: a deliberate edit
    # (rev >= 1) intentionally beats ANY legacy rev-less blob regardless of stamps — each
    # pre-rollout server key is exposed to that once, until its first revisioned write.
    ((None, None, OLD, NEW), "remote"),
    ((0, 0, NEW, OLD), "local"),
    ((0, None, NEW, OLD), "local"),
    ((None, 0, OLD, NEW), "remote"),
    ((2, 1, OLD, NEW), "local"),         # deeper local chain beats newer remote stamp
    ((1, 2, NEW, OLD), "remote"),        # deeper remote chain beats newer local stamp
    ((3, 3, NEW, OLD), "local"),         # rev tie -> stamps
    ((3, 3, OLD, NEW), "remote"),
    ((3, 3, NEW, NEW), "tie"),
    ((None, 3, NEW, OLD), "remote"),     # nil == 0 loses to any real depth
    ((3, None, OLD, NEW), "local"),
]

# (remoteShelfUpdatedAt, localShelvesUpdatedAt) -> apply remote?
SHELF_VECTORS = [
    ((NEW, None), True),    # never set locally -> remote wins
    ((None, OLD), False),   # never set remotely -> local wins
    ((NEW, OLD), True),     # remote fresher
    ((NEW, NEW), True),     # tie -> remote
    ((OLD, NEW), False),    # remote staler
]


class SyncConformanceTests(unittest.TestCase):
    def test_compare_revisioned_vectors(self):
        for args, expected in COMPARE_VECTORS:
            self.assertEqual(compare_revisioned(*args), expected, f"compareRevisioned{args}")

    def test_shelf_placement_vectors(self):
        for args, expected in SHELF_VECTORS:
            self.assertEqual(should_apply_remote_shelf_placement(*args), expected, f"shelf{args}")

    def test_swift_implementation_matches_spec(self):
        core = read("Features/HttpSync/SyncCore.swift")
        # rev-first, nil==0
        self.assertIn("let lr = localRev ?? 0", core)
        self.assertIn("let rr = remoteRev ?? 0", core)
        self.assertIn("if lr != rr { return lr > rr ? .localWins : .remoteWins }", core)
        # stamps break ties
        self.assertIn("let cmp = compareRfc3339(localStamp, remoteStamp)", core)
        # shelf LWW: ties go to remote
        self.assertIn("compareRfc3339(remoteShelfUpdatedAt, localShelvesUpdatedAt) >= 0", core)

    def test_blobs_carry_rev_and_legacy_decodes(self):
        blobs = read("Features/HttpSync/SyncBlobs.swift")
        # All three mutable blobs have a tolerant rev decode and always-emitted encode.
        self.assertEqual(blobs.count("rev = try? c.decodeIfPresent(Int.self, forKey: .rev)"), 3)
        self.assertEqual(blobs.count("try c.encode(rev, forKey: .rev)"), 3)

    def test_only_edits_bump_revs(self):
        # The reconciler merges; it must never bump (only the fire-and-forget hooks do).
        reconciler = read("Features/HttpSync/HttpSyncReconciler.swift")
        self.assertNotIn("bumpForLocalEdit", reconciler)
        manager = read("Features/HttpSync/HttpSyncManager.swift")
        self.assertIn("bumpForLocalEdit", manager)

    def test_bookmark_edits_bump_before_auto_push_gate(self):
        manager = read("Features/HttpSync/HttpSyncManager.swift")
        body = manager[
            manager.index("func onPageTurnPersisted(book: BookMetadata)"):
            manager.index("/// Call after the user moves", manager.index("func onPageTurnPersisted(book: BookMetadata)"))
        ]
        self.assertLess(body.index("bumpForLocalEdit"), body.index("autoPushReady"))
        self.assertNotIn("settings.enabled, settings.isConfigured", body)

    def test_epub_sync_push_flushes_on_reader_exit(self):
        view_model = read("Features/Reader/ReaderView/ReaderViewModel.swift")
        flush_body = view_model[
            view_model.index("func flushAutoSync() async"):
            view_model.index("func updateProgress", view_model.index("func flushAutoSync() async"))
        ]
        self.assertIn("flushSyncPush()", flush_body)
        self.assertIn("private var pendingSyncPush = false", view_model)


if __name__ == "__main__":
    unittest.main()
