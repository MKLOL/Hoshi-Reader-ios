*Last updated: November 9 2026*
# Privacy Policy

Your data stays on your device unless you use the features below.

**Google Drive Sync** - If enabled and when syncing a book, the book title, reading progress, statistics, and book cover can be uploaded to your Google Drive. The app can only access files that were created by the Google Cloud Project and cannot read any other files in your Drive. 

**HTTP Sync** - When configured, books, per-device navigation histories, reading progress, reading preferences, reading statistics, streak settings, reading activity, translation history and translation prompts are sent to your chosen sync server. Activity includes reading sessions, looked-up words and manga bubble text used for translation. Device logs are excluded from system backups. Other devices’ cached activity is removed when switching sync accounts. A token pasted during first-launch setup is used with the Hoshi sync server at `dragos.games` unless you have set another address; you can change it in Settings → Advanced → HTTP Sync.

**AI translation** - When you ask a cloud model for a translation, the text of the bubble or sentence, your prompt and any screenshot you selected are sent to the AI provider you configured, using your own API key. Keys are kept in the device Keychain and are never synced. Stored pre-translations and on-device models send nothing.

**Audio** - When you play word audio or have Anki audio export configured, the word and reading are sent to a Cloudflare Worker by default. The default audio source can be disabled, and additional user-configurable audio sources can be added.

**AnkiMobile** - When you export a word to AnkiMobile, user-configurable word data is shared via URL schemes.

**Third-Party Services** - Google Drive and Cloudflare are used as described above. Both services are governed by their respective privacy policies.

**Data Deletion** - All local data is deleted when you uninstall the app. Google Drive data can be deleted directly from your Google Drive. You can sign out at any time to remove stored authentication tokens.

**Anonymous usage statistics** - Enabled by default, this feature sends a random installation ID, app/iOS versions, hardware family, screen dimensions, language, book/dictionary counts and a few reading/sync switches to the Hoshi statistics service at `dragos.games`. Reports contain no book titles, reading text, looked-up words, sync server address, tokens, device name or vendor identifier. The first report waits at least 20 hours; later reports are separated by at least 20 hours. You can turn this off in Settings → Advanced → Share anonymous usage statistics before the first report. Turning it off deletes the local installation ID and cancels a pending report. Debug builds, simulators and automated tests do not send reports.

**Diagnostics** - The app keeps a record on your device of crashes, unresponsive periods and exits that iOS reports for it, of reader pages that had to be loaded again, and of times it stopped while open. The record holds app and iOS versions, the hardware family, times and call stacks; it holds no book titles, reading text, account or sync token. It is never sent anywhere by the app and leaves the device only if you share it from Settings → Diagnostics.

No advertising or cross-app tracking is used.

For questions, open an issue on [GitHub](https://github.com/Manhhao/Hoshi-Reader/issues).
