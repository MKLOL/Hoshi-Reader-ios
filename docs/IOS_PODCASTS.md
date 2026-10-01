# iOS podcasts and clickable transcripts

The Podcasts tab uses the existing HTTP book-sync token and appears after `/v1/podcasts/access` validates it. A previously validated unchanged account can use saved lessons offline. Authentication rejection hides lessons and stops playback/downloads; files are retained until another account validates. Tokens remain in Keychain. Account markers, metadata, audio and positions live outside Books and are excluded from OS backup.

The app follows Android through `0d6524f4`: server-provided shows, original-duration filters including unknown and hour-long episodes, preparation/retry and administrator errors, worker health, and progress that expires after 90 seconds including elapsed time on the device. Cached catalogues contain no live telemetry. Download metadata is kept separately so archived shows retain saved lessons.

Downloads use a background URLSession; playback uses AVPlayer with seek, speed and lock-screen controls. API redirects are refused. Apple background URLSession always follows redirects and does not call the redirect delegate; completed audio is rejected if its final absolute URL differs from the requested endpoint. This platform limit preserves downloads while the app is suspended or relaunched. JSON is bounded at 2 MiB; accepted MP3 files at 512 MiB, with oversized transfers cancelled when progress is delivered. Successful downloads publish atomically. Transport failures and HTTP 429/503 receive at most two deferred retries.

Validated account state is restored before background callbacks, without depending on a visible SwiftUI scene. Leaving Podcasts cancels polling and prevents late responses from restoring live telemetry. Transfer identities and account generations isolate cancellation from a restarted download. Podcasts and Sasayaki hand audio ownership to each other, and dictionary audio cannot deactivate their active audio session.

A local macOS Foundation probe using a temporary app bundle and synthetic credentials confirmed that a background redirect from `127.0.0.1` to `localhost` did not forward the Authorization header; the redirect delegate was not called. This is a transport probe, not an iOS physical-device check.

Platform reference: [Apple background transfer limitations](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background).

Validation: all 13 existing podcast cases, 11 transcript data cases, 5 playback/lookup cases and the real-server transcript/original download case passed in the simulator. UI automation passed on both iPhone and iPad: quiet opening, English visibility, timestamp playback, Japanese word lookup, dragging away and returning to the active line. These checks are part of the complete gate documented in [Android parity](ANDROID_PARITY.md). Production server generation, physical-device background relaunch and lock-screen behavior have not yet been exercised. No production lesson generation was requested during this port.

## Original audio and timed transcripts

When a ready episode advertises a transcript, **Get transcript** downloads `/v1/podcasts/<id>/transcript`, validates its episode ID and ordered finite timings, then downloads `/v1/podcasts/<id>/original`. A pending JSON checkpoint survives the background transfer; the final JSON becomes available only after the recording is saved. A corrupt final transcript enables another download. Either saved audio kind keeps an archived episode and its show discoverable offline.

**Transcript** opens quietly at the original recording's saved position. Its position is separate from the lesson. Tapping a timestamp starts the original from that line. The current Japanese line is highlighted at 200ms cadence and follows playback until the reader drags away; **Follow playback** returns to it. English starts hidden and is available only when the server provides it.

Tapping Japanese text pauses playback before looking up the word. The native sentence reader's TextKit hit testing and recursive dictionary cards are reused; dictionary dismissal does not automatically restart the recording. Lookups cancelled by another tap or leaving the screen cannot reopen stale cards. Playback controls, speed, audio handoff and lock-screen commands remain shared with lessons.

Apple API references: [AVPlayer periodic time observation](https://developer.apple.com/documentation/avfoundation/avplayer/addperiodictimeobserver(forinterval:queue:using:)), [sizing native SwiftUI text rows](https://developer.apple.com/documentation/swiftui/uiviewrepresentable/sizethatfits(_:uiview:context:)).
