# Shipping Hoshi Reader to TestFlight

How to get a build from this repo onto a phone via TestFlight, and how to push updates
afterwards with one command.

The repeatable part is `ship.sh` in the repo root. Everything in "One-time setup" happens
once; after that, shipping is `./ship.sh`.

> **Read "Before you ship anything" first.** Two items there are licensing and privacy
> issues that matter more than any build step.

---

## Before you ship anything

### This is a fork, and it is GPLv3

`git` confirms this repo is a fork of `Manhhao/Hoshi-Reader`. `LICENSE` is **stock GPLv3
with no App Store exception**, and 106 source files carry `Copyright © 2026 Manhhao` — you
are not the copyright holder.

Distributing GPL'd code you don't own through the App Store is a known licence/ToS conflict:
the App Store terms impose usage restrictions GPLv3 forbids adding. It's what got GNU Go and
VLC pulled after FSF complaints.

For a **solo internal TestFlight build this is a non-issue in practice** — you're not
distributing to anyone. It becomes a real exposure the moment another person gets a build,
and a genuine problem for a public listing. If you ever want to go beyond yourself, get
written permission from the upstream author for an App Store distribution exception.

Related: upstream already ships this app publicly (App Store `id6758244332`, "Hoshi Reader"
by Manh-Hao Steffen Pham). A public listing of a near-identical fork invites Guideline 4.1
(Copycats) / 4.3 (Spam) scrutiny. Internal TestFlight avoids all of it.

### The fork still points at upstream's infrastructure

`Core/UserConfig.swift:285` defaults word audio to:

```
https://hoshi-reader.manhhaoo-do.workers.dev/?term={term}&reading={reading}
```

Every dictionary audio lookup hits **another developer's Cloudflare Worker**. Fine for you
alone; not fine to ship to other people. Book sync already defaults to your own
`https://dragos.games/api/book_sync`, so that leg is clean.

`PRIVACY.md` also directs support at `github.com/Manhhao/Hoshi-Reader/issues`, and doesn't
mention the LLM providers the app actually talks to (OpenAI, Anthropic, DeepSeek, Qwen,
Moonshot), HuggingFace `.gguf` downloads, or `api.jiten.moe`. It needs a rewrite before it
could serve as the Privacy Policy URL that external testing requires.

---

## One-time setup

### 1. Confirm the paid membership is active

[developer.apple.com/account](https://developer.apple.com/account) → Membership. Copy the
10-character **Team ID**. If it still says "enrollment pending", wait — activation can lag
payment by a few hours.

A free Personal Team cannot upload to TestFlight at all: the Validate and Distribute buttons
are simply unavailable ([QA1915](https://developer.apple.com/library/archive/qa/qa1915/_index.html)).
That's the whole reason this step exists.

### 2. Point the project at the paid team

There are currently **two** stale team IDs in `project.pbxproj`:

| Where | Value |
| --- | --- |
| Project level (lines 456, 524) | `GPLBDQ2MBT` |
| App target + ShareExtension (557, 599, 640, 669) | `XR83Z84FJZ` — your free Personal Team |
| `HoshiReaderUITests` | no override → inherits `GPLBDQ2MBT` |

In Xcode: select the project → for **each** of the three targets → Signing & Capabilities →
set Team to the paid team. Note the GUI won't clear the stale *project-level* `GPLBDQ2MBT`;
edit that out of `project.pbxproj` directly if you want it tidy.

This step only really matters for the one-time GUI archive in step 3 — `ship.sh` passes
`DEVELOPMENT_TEAM=$TEAM_ID` on the command line, which overrides all of the above.

### 3. Request App Store Connect API access — do this early, it has a wait

App Store Connect → Users and Access → Integrations → App Store Connect API. On a brand-new
membership there is a **Request Access** button where you expect a Generate button. Apple
reviews the request "on a case-by-case basis"
([docs](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api)).

Kick this off before anything else, because step 6 is blocked until it clears.

### 4. First archive + app record — do this one through the Xcode GUI

Product → Archive, then Distribute App → TestFlight.

Xcode registers the App IDs (`com.dragosristache.hoshi` and
`com.dragosristache.hoshi.ShareExtension`), creates the distribution certificate and
provisioning profiles, and offers to create the App Store Connect record.

This is genuinely mandatory, not a convenience. Right now this machine has exactly one
signing identity — `Apple Development` — **no distribution certificate**, and zero
provisioning profiles. `ship.sh` will fail until that changes.

Creating the app record by hand instead: [appstoreconnect.apple.com](https://appstoreconnect.apple.com)
→ Apps → **+** → New App, bundle ID `com.dragosristache.hoshi`, SKU anything (e.g.
`hoshi-reader`). The app *name* must be unique across the App Store — upstream already holds
"Hoshi Reader", so pick something else.

### 5. Generate the API key

Once access is granted, generate a key. **Developer** role is sufficient to upload builds —
Apple lists "Account Holder, Admin, App Manager, or Developer", and the role matrix gives App
Manager and Developer identical rights on the Upload Builds row
([roles](https://developer.apple.com/support/roles/)). Pick **App Manager** anyway if you
might do external testing later, since Developer is read-only on external groups.

Download the `.p8` — Apple only lets you download it once.

```bash
mkdir -p ~/.appstoreconnect/private_keys
mv ~/Downloads/AuthKey_XXXXXXXXXX.p8 ~/.appstoreconnect/private_keys/
```

`altool` searches four locations: `./private_keys`, `~/private_keys`, `~/.private_keys`,
`~/.appstoreconnect/private_keys`. **Do not use the first one** — `ship.sh` runs from the
repo root, so `./private_keys` is inside the repo. `.gitignore` now blocks `*.p8` regardless,
but don't rely on that.

### 6. Create `.shipenv`

In the repo root, before the first `./ship.sh` run — the script requires it and exits if it's
missing. Gitignored.

```bash
TEAM_ID=YOURPAIDTEAM
ASC_KEY_ID=XXXXXXXXXX
ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
# optional, if you keep the key somewhere else:
# ASC_KEY_PATH=/custom/path/AuthKey_XXXXXXXXXX.p8
```

`ASC_ISSUER_ID` is shown once at the top of the API keys page and is shared across all your
keys.

### 7. Add yourself as an internal tester

App Store Connect → the app → TestFlight → Internal Testing → add your Apple ID. Install the
TestFlight app on the phone.

Internal builds skip Beta App Review and appear within roughly ten minutes of processing.
Limit is 100 internal testers.

---

## Shipping an update

```bash
./ship.sh
```

Bumps the build number, archives Release, exports a signed `.ipa`, uploads it.

| Flag | Effect |
| --- | --- |
| `--validate` | Run `altool --validate-app` first. Slower — it uploads the whole `.ipa` twice. Worth it on the first ship. |
| `--no-bump` | Reuse the current build number (upload is rejected if that build already exists) |
| `--build-only` | Archive and export the `.ipa` only. Does **not** bump the build number and does **not** upload. |

Artifacts land in `build/testflight/` (gitignored). Apple-side processing takes ~5–15 minutes.

If the archive, export or upload fails, `ship.sh` restores the original build number rather
than leaving an inflated one in the tracked `project.pbxproj`. After a successful ship, commit
the bump — the script prints the exact command.

---

## Project-specific notes

**Build numbers.** `CURRENT_PROJECT_VERSION` and `MARKETING_VERSION` live at *project* level
in `project.pbxproj`, so the app and ShareExtension always match. `ship.sh` asserts both the
Debug and Release configs agree before bumping, and refuses if they've diverged. A mismatched
extension version produces an **ITMS-90473 warning email**, not usually a hard rejection — but
keep them in sync anyway.

Do **not** add `CFBundleVersion` or `CFBundleShortVersionString` to `HoshiReader-Info.plist`.
They're absent by design; the build settings drive them via `GENERATE_INFOPLIST_FILE`.

**Encryption compliance — already handled, don't touch it.**
`INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO` is already set on the app target
(`project.pbxproj:562` and `:604`), and the built `Info.plist` reads `false`. You will not get
the per-upload encryption prompt. Adding `ITSAppUsesNonExemptEncryption` to
`HoshiReader-Info.plist` would create a competing declaration across the plist merge — don't.

`false` is Apple's documented answer for apps using only exempt encryption, which HTTPS is.

Note that export compliance gates **internal** testers too, not just external — an unanswered
build is greyed out for every group. Already answered here, so it's a non-issue.

**`UIBackgroundModes: audio` is legitimate — but a reviewer can't find it.** The justification
is Sasayaki (`Features/Sasayaki/SasayakiPlayer.swift`): audiobook playback synced to EPUB
text, using `AVPlayer` with `.playback`/`.spokenAudio`, `MPNowPlayingSession` and
`MPRemoteCommandCenter`. Textbook background audio. (There is no TTS anywhere in this app.)

The risk isn't the merits, it's discoverability: Sasayaki is behind Settings → Advanced →
Sasayaki and needs a user-supplied `.mp3`/`.m4b` **plus** a SubPlz `.srt` **plus** a matching
`.epub`. A Beta App Review reviewer will never reach it unaided. If you ever submit for
external testing, put a demo audiobook + srt and step-by-step instructions in "Notes for
Review". Irrelevant for internal testing.

**`com.apple.developer.kernel.increased-memory-limit`.** Works under automatic signing with no
special request (`distributionApprovalRequired: false`). It is *not* paid-only — Xcode's own
capability database lists it among the 11 of 196 capabilities valid for `XCODE_FREE_PROGRAM`.
So it's fine, and it isn't a reason you needed the paid account. (Don't confuse it with
Extended Virtual Addressing or Increased *Debugging* Memory Limit, which are paid-only.)

**`NSAllowsLocalNetworking`.** Kept for AnkiConnect over the LAN. Only `NSAllowsArbitraryLoads`
triggers the ATS justification path, so this is clean.

**Privacy manifest.** `PrivacyInfo.xcprivacy` now declares four required-reason API categories:
UserDefaults (CA92.1), ActiveKeyboards (54BD.1), DiskSpace (85F4.1 — `HttpSyncReconciler`
checks free space before writing), and FileTimestamp (C617.1 — `MokuroBookParser` and
`HttpSyncReconciler` read mtime inside the app's own container). The last two were added
because their absence triggers an **ITMS-91053** bounce email on upload. If you add new
filesystem or system-info calls, extend this file.

---

## What does *not* block internal TestFlight

Useful to know so you don't burn time on them:

- **App Privacy questionnaire** (the "nutrition label") — not required for internal testing.
  Required for external testing and for the App Store.
- **Test Information / "What to Test" / beta app description** — not required for internal.
  Required for external.
- **Beta App Review** — internal only, so skipped entirely.

For external testing later: you must create an internal group *before* you can create an
external one, the first build of each version gets a full review (later builds of the same
version often don't), and there's a cap of **6 builds submitted for review per 24 hours**.
External limit is 10,000 testers.

---

## Troubleshooting

**"No profiles for 'com.dragosristache.hoshi' were found"** — the App ID isn't registered on
the paid team yet, or Xcode hasn't refreshed. `ship.sh` passes `-allowProvisioningUpdates`
*with* your API key, which normally resolves it; otherwise Xcode → Settings → Accounts →
Download Manual Profiles.

**"The bundle version must be higher than the previously uploaded version"** — that build
number already exists. Run `./ship.sh` without `--no-bump`.

**ITMS-91053 (missing API reason)** — a required-reason API is used but undeclared in
`PrivacyInfo.xcprivacy`. Arrives by email after upload. Add the category + reason code.

**ITMS-90717 (invalid app icon / alpha channel)** — the icon assets are correct
(`AppIcon1024.png` is 1024×1024 with no alpha), but `HoshiIcon.icon` sits in the target's Copy
Resources phase while `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`. That combination has
produced spurious alpha-channel failures on Xcode 26. If you hit it, remove `HoshiIcon.icon`
from the Copy Resources build phase.

**Upload authentication failures** — confirm the `.p8` filename still matches
`AuthKey_<ASC_KEY_ID>.p8` and that `ASC_ISSUER_ID` is the issuer ID, not the key ID.

**"error: Debug and Release build numbers diverge"** — `ship.sh` refusing to bump because the
two project-level configs disagree. Set them both to the same value and re-run.
