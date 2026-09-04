# Sync test server

`sync_test_server.py` is a dependency-free Python 3 implementation of the KV sync API in
`docs/HTTP_SYNC_KV.md` — the same routes, status codes, `sha256:` etags and RFC 3339 stamps the
production server returns. Both platforms' integration tests boot it and drive their **real**
sync engines and HTTP clients against it, so nothing about the wire protocol is faked.

```
python3 tools/sync-test-server/sync_test_server.py --port 0 --token secret
SYNC_TEST_SERVER_READY port=51234
```

Test-only routes (`/_test/health`, `/_test/reset`, `/_test/dump`, `/_test/load`,
`/_test/requests`, `/_test/requests/clear`, and `/_test/fail_next` to make the next matching
API requests fail with a chosen status) let a test inspect or shape server state from outside the
client under test. `test_sync_test_server.py` pins the server's own contract.

A green suite proves the clients agree with *this* implementation of the documented contract; it
says nothing about the production deployment, which is only covered by the live smoke test.

## Where it is used

- **Android** — `app/src/test/java/moe/antimony/hoshi/features/sync/integration/`:
  `RealServerKvClientTest` (the production `HttpSyncKvClient`), `SyncIntegrationTest` (two
  simulated installs, every engine combination: fresh sync, resync, bookmarks, payload
  replacement, corrupt/legacy manifests, tombstones, multipart), and `SyncCorpusSnapshotTest`,
  which publishes the shared corpus. These run in the normal `./gradlew :app:testDebugUnitTest`
  and require `python3` (or `HOSHI_PYTHON`). Set `HOSHI_SYNC_CORPUS_OUT=<file>` to regenerate
  the iOS fixture from what Android actually uploads.
- **iOS** — the same server lives at `tools/sync-test-server/` in the iOS repo;
  `Tests/Regression/test_sync_integration.py` boots it, loads `Tests/Fixtures/sync-corpus.json`
  (the Android-published corpus) and runs the `HoshiReaderTests` XCTest bundle, which drives the
  production `HttpSyncManager` against it in the simulator.

Keep the two copies of `sync_test_server.py` identical.
