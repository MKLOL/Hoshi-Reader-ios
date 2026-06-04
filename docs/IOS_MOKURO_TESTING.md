# iOS Mokuro Reader — Test Status

## Build
- **Builds green** for the iOS Simulator (Xcode 26.5, iOS 26.5 SDK), Debug:
  `xcodebuild -project "Hoshi Reader.xcodeproj" -scheme "Hoshi Reader" -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`
- Note: `Package.resolved` was repinned — `hoshidicts` `main` was force-pushed, so the old commit no
  longer resolves; bumped to the current `main` HEAD.

## Simulator smoke test (headless, automated) — PASS
On a booted iPhone 17 Pro (iOS 26.5) the app was built, installed, and launched:
- App launches with **no crash** (verified live in `launchctl list`, no DiagnosticReports).
- **Manga-first bookshelf** renders: empty state reads *"No Books — Import manga using the + button
  to start reading."*; tabs are Books / Dictionary / Settings.
- A real **Yotsubato vol. 1** (`~/Dropbox/hoshi-manga-bundle/yotsubato/001 [JP] Yotsubato.zip`,
  231 pages) was seeded into the app container in the importer's on-disk format. The shelf then
  shows the **real cover thumbnail** and the **"p. 1 / 231"** page-based progress label — validating
  the mokuro parse/normalize output, cover generation, `BookMetadata`, and the manga shelf cell.

A seeded book is left in the simulator so you can tap straight into the reader.

## Interactive UI test — BLOCKED (needs Accessibility permission)
Driving taps headlessly (open the reader, exercise reveal→lookup→Anki→ChatGPT→screenshot-translate,
HTTP sync round-trip, settings screens) requires synthetic input. Both AppleScript/System Events and
`cliclick` are blocked by macOS TCC: *"osascript is not allowed assistive access (-1719)"* /
*"Accessibility privileges not enabled"*. `idb` is not installed.

To finish interactive testing, either:
1. **Grant Accessibility** to your terminal app (System Settings → Privacy & Security →
   Accessibility), then taps can be automated with `cliclick`; or
2. **Tap through manually** in the open Simulator — the seeded Yotsubato book is already on the shelf.

What to exercise manually (the parts not yet visually verified):
- Open the book → OCR overlay renders over the page; two-tap reveals a bubble; vertical text upright.
- Tap a revealed bubble → dictionary popup (same as EPUB reader); Anki mining.
- Sparkles button → ChatGPT popup (set an API key in Settings → ChatGPT first).
- Screenshot-translate: crop a region → vision translation.
- Settings → ChatGPT and Settings → Sync (HTTP) screens.
- RTL paging (right-swipe = forward), pinch-zoom, e-ink mode, go-to-page.
- HTTP sync round-trip against the server, ideally diffing blobs vs the Android client.

## Reader confidence without a screenshot
The reader (`Features/MangaReader/*`) is a faithful port of Android's production `MangaPageHtml.kt`
renderer, was correctness-reviewed (OCR %-positioning, `cqw` font, vertical-rl, RTL paging, crop
coordinate math all verified), its `hoshi-img://` scheme handler has verified path-traversal
containment, and the whole module compiles — but it has **not** been visually screenshot-tested due
to the tap-automation block above.
