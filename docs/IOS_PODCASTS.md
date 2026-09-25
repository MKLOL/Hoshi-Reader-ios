# iOS podcast lessons

The Podcasts tab uses the existing HTTP book-sync token and appears after `/v1/podcasts/access` validates it. A previously validated unchanged account can use saved lessons offline. Authentication rejection hides lessons and stops playback/downloads; files are retained until another account validates. Tokens remain in Keychain. Account markers, metadata, audio and positions live outside Books and are excluded from OS backup.

The app follows Android through `653a8819`: server-provided shows, original-duration filters including unknown and hour-long episodes, preparation/retry and administrator errors, worker health, and progress that expires after 90 seconds including elapsed time on the device. Cached catalogues contain no live telemetry. Download metadata is kept separately so archived shows retain saved lessons.

Downloads use a background URLSession; playback uses AVPlayer with seek, speed and lock-screen controls. API and audio redirects are refused. JSON is bounded at 2 MiB; MP3 transfers at 512 MiB. Successful downloads publish atomically.

Validation: simulator build and seven PodcastParityTests pass. Production server generation, physical-device background relaunch and lock-screen behavior have not yet been exercised. No production lesson generation was requested during this port.
