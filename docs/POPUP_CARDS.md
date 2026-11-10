# Popup Cards on iOS

Settings → Popup Cards (also EPUB → Related settings → Popup Cards and Manga → Popup Cards) edits dictionary and translation cards independently. Width, height, content scale, and font size save immediately; the actual-size sample updates live and Full preview shows the bounded card on the current display. Reset restores one card only.

Unedited fields remain responsive: dictionary cards retain existing width/height preferences and the original phone/iPad floors and caps; translations retain the original 680 pt iPad / 520 pt phone width limits and responsive height. Explicit dimensions replace those defaults, while placement still protects the selected text and screen edges. Changing dictionary width turns off Full-width mode. Scale changes the complete rendered content; font size includes the dictionary headword and ruby as well as translation Markdown. The existing uniform Markdown text-size toggle remains in the translation header.

The shared popup views apply to EPUB and manga. Previews use inert sample entries and the production WebKit/Textual renderers; their actions cannot mine cards, request pronunciation, or send AI requests.

## Verification

- Simulator builds for Hoshi Reader and HoshiReaderUITests pass.
- `PopupCardStyleTests`: two hosted tests pass for responsive unset fields, viewport limits, JSON round trip, and explicit height overrides.
- `ZoomPopupUITests/testPopupCardsLivePreview` passes on iPhone 17 and 13-inch iPad Pro M5: headwords visibly grow, independent resets work, and dictionary preferences survive relaunch. Captures use actual simulator output.
- Evidence: `build/reader-cards-unit.xcresult`, `build/reader-cards-phone-gallery.xcresult`, `build/reader-cards-ipad-gallery.xcresult`. Screenshots: `build/cards-screenshots/`.
- No physical-device installation or TestFlight release was performed.
