# iOS podcast lessons

The Podcasts tab uses the existing HTTP book-sync token and appears after `/v1/podcasts/access` validates it. A previously validated unchanged account can use saved lessons offline. Authentication rejection hides lessons and stops playback/downloads; files are retained until another account validates. Tokens remain in Keychain. Account markers, metadata, audio and positions live outside Books and are excluded from OS backup.

The app follows Android through `653a8819`: server-provided shows, original-duration filters including unknown and hour-long episodes, preparation/retry and administrator errors, worker health, and progress that expires after 90 seconds including elapsed time on the device. Cached catalogues contain no live telemetry. Download metadata is kept separately so archived shows retain saved lessons.

Downloads use a background URLSession; playback uses AVPlayer with seek, speed and lock-screen controls. API redirects are refused. Apple background URLSession always follows redirects and does not call the redirect delegate; completed audio is rejected if its final absolute URL differs from the requested endpoint. This platform limit preserves downloads while the app is suspended or relaunched. JSON is bounded at 2 MiB; accepted MP3 files at 512 MiB, with oversized transfers cancelled when progress is delivered. Successful downloads publish atomically. Transport failures and HTTP 429/503 receive at most two deferred retries.

Validated account state is restored before background callbacks, without depending on a visible SwiftUI scene. Leaving Podcasts cancels polling and prevents late responses from restoring live telemetry. Transfer identities and account generations isolate cancellation from a restarted download. Podcasts and Sasayaki hand audio ownership to each other, and dictionary audio cannot deactivate their active audio session.

A local macOS Foundation probe using a temporary app bundle and synthetic credentials confirmed that a background redirect from `127.0.0.1` to `localhost` did not forward the Authorization header; the redirect delegate was not called. This is a transport probe, not an iOS physical-device check.

Platform reference: [Apple background transfer limitations](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background).

Validation: all 13 PodcastParityTests passed in the simulator, including cold-start access, hidden-screen responses, cancellation, older progress JSON, safe error text and audio handoff. Production server generation, physical-device background relaunch and lock-screen behavior have not yet been exercised. No production lesson generation was requested during this port.
