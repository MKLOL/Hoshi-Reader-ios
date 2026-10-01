#!/usr/bin/env bash
# Build Hoshi Reader and push a new build to TestFlight.
#
# One-time setup: create .shipenv next to this script (it is gitignored):
#
#   TEAM_ID=ABCDE12345          # paid team, from developer.apple.com/account -> Membership
#   APPLE_ID=you@example.com     # Apple ID for upload
#   KEYCHAIN_ITEM=HOSHI_SHIP    # keychain item holding an app-specific password
#   # optional instead: ASC_KEY_ID + ASC_ISSUER_ID for an App Store Connect API key
#
# Create the keychain item once with:
#   xcrun altool --store-password-in-keychain-item --item HOSHI_SHIP -u <appleid> -p <pw>
#
# Usage:
#   ./ship.sh              # bump build number, archive, upload
#   ./ship.sh --validate   # also run altool --validate-app first (slower: uploads twice)
#   ./ship.sh --no-bump    # reuse current build number
#   ./ship.sh --build-only # archive + export .ipa only; does NOT bump, does NOT upload

set -euo pipefail

cd "$(dirname "$0")"

PROJECT="Hoshi Reader.xcodeproj"
SCHEME="Hoshi Reader"
PBXPROJ="$PROJECT/project.pbxproj"
BUILD_DIR="build/testflight"
ARCHIVE="$BUILD_DIR/HoshiReader.xcarchive"

BUMP=1
UPLOAD=1
VALIDATE=0
for arg in "$@"; do
	case "$arg" in
		--no-bump)    BUMP=0 ;;
		--validate)   VALIDATE=1 ;;
		# A local test build must not consume a build number or dirty the tree.
		--build-only) UPLOAD=0; BUMP=0 ;;
		*) echo "unknown flag: $arg" >&2; exit 2 ;;
	esac
done

[[ -f .shipenv ]] || { echo "error: .shipenv not found — see header of this script" >&2; exit 1; }
# shellcheck disable=SC1091
source .shipenv
: "${TEAM_ID:?TEAM_ID missing from .shipenv}"

# --- Upload credentials ------------------------------------------------------
# Two supported auth modes, checked in this order:
#   1. App-specific password held in the login keychain (APPLE_ID + KEYCHAIN_ITEM).
#      Generated instantly at account.apple.com, no Apple review. This is the default.
#   2. App Store Connect API key (ASC_KEY_ID + ASC_ISSUER_ID), if you ever request one.
# xcodebuild's -allowProvisioningUpdates works off the Xcode-registered account, so
# it only needs explicit auth args in API-key mode.
AUTH_ARGS=()
if [[ -n "${ASC_KEY_ID:-}" ]]; then
	ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
	if [[ -f "$ASC_KEY_PATH" && -n "${ASC_ISSUER_ID:-}" ]]; then
		AUTH_ARGS=(
			-authenticationKeyPath "$ASC_KEY_PATH"
			-authenticationKeyID "$ASC_KEY_ID"
			-authenticationKeyIssuerID "$ASC_ISSUER_ID"
		)
	fi
fi

# altool arguments for whichever mode is configured.
ALTOOL_AUTH=()
if [[ -n "${APPLE_ID:-}" && -n "${KEYCHAIN_ITEM:-}" ]]; then
	ALTOOL_AUTH=(-u "$APPLE_ID" -p "@keychain:$KEYCHAIN_ITEM")
elif [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]]; then
	ALTOOL_AUTH=(--apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID")
fi

if (( UPLOAD )); then
	(( ${#ALTOOL_AUTH[@]} > 0 )) || {
		echo "error: no upload credentials in .shipenv" >&2
		echo "       set APPLE_ID + KEYCHAIN_ITEM (app-specific password), or" >&2
		echo "       ASC_KEY_ID + ASC_ISSUER_ID (App Store Connect API key)" >&2
		exit 1
	}
	if [[ -n "${KEYCHAIN_ITEM:-}" ]]; then
		security find-generic-password -l "$KEYCHAIN_ITEM" >/dev/null 2>&1 || {
			echo "error: keychain item '$KEYCHAIN_ITEM' not found" >&2
			echo "       xcrun altool --store-password-in-keychain-item --item $KEYCHAIN_ITEM \\" >&2
			echo "                    -u $APPLE_ID -p <app-specific-password>" >&2
			exit 1
		}
	fi
fi

# bash 3.2 (the system bash) errors on "${arr[@]}" when the array is empty under
# set -u, hence the ${arr[@]+...} guard at each use site below.

# The same production-client/real-server gate runs before any version mutation or archive.
# It owns a disposable simulator and never wipes a developer's existing device.
python3 tools/test_ios_parity.py

# --- version -----------------------------------------------------------------
# CURRENT_PROJECT_VERSION and MARKETING_VERSION live at PROJECT level, so the app
# and the ShareExtension always share them. There are exactly two occurrences of
# each (Debug and Release). Bail out if that stops being true rather than guessing.
VERSION_COUNT=$(grep -c 'CURRENT_PROJECT_VERSION = ' "$PBXPROJ")
[[ "$VERSION_COUNT" == "2" ]] || {
	echo "error: expected 2 CURRENT_PROJECT_VERSION entries, found $VERSION_COUNT" >&2
	echo "       the version layout changed; update ship.sh before shipping" >&2
	exit 1
}
DISTINCT=$(grep -o 'CURRENT_PROJECT_VERSION = [0-9]*' "$PBXPROJ" | sort -u | wc -l | tr -d ' ')
[[ "$DISTINCT" == "1" ]] || {
	echo "error: Debug and Release build numbers diverge — refusing to bump" >&2
	grep -n 'CURRENT_PROJECT_VERSION = ' "$PBXPROJ" >&2
	exit 1
}

current_build() {
	grep -m1 -o 'CURRENT_PROJECT_VERSION = [0-9]*' "$PBXPROJ" | grep -o '[0-9]*'
}
MARKETING=$(grep -m1 -o 'MARKETING_VERSION = [^;]*' "$PBXPROJ" | sed 's/MARKETING_VERSION = //')

if (( BUMP )); then
	NEXT=$(( $(current_build) + 1 ))
	# Restore the original pbxproj if anything below fails, so a failed ship does
	# not leave an inflated build number in a tracked file.
	cp -p "$PBXPROJ" "$PBXPROJ.shipbak"
	trap 'if [[ -f "$PBXPROJ.shipbak" ]]; then mv -f "$PBXPROJ.shipbak" "$PBXPROJ"; echo "==> rolled back build number" >&2; fi' EXIT
	/usr/bin/sed -i '' -E "s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = ${NEXT};/g" "$PBXPROJ"
	# sed exits 0 even when it matches nothing; verify the edit actually landed.
	[[ "$(current_build)" == "$NEXT" ]] || {
		echo "error: build number bump did not apply (still $(current_build))" >&2
		exit 1
	}
fi
BUILD_NUM=$(current_build)
echo "==> Hoshi Reader ${MARKETING} (${BUILD_NUM})  team ${TEAM_ID}"

# --- archive -----------------------------------------------------------------
rm -rf "$ARCHIVE"
mkdir -p "$BUILD_DIR"

xcodebuild archive \
	-project "$PROJECT" \
	-scheme "$SCHEME" \
	-configuration Release \
	-destination 'generic/platform=iOS' \
	-archivePath "$ARCHIVE" \
	-allowProvisioningUpdates \
	${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} \
	DEVELOPMENT_TEAM="$TEAM_ID" \
	CODE_SIGN_STYLE=Automatic

# --- export ------------------------------------------------------------------
EXPORT_OPTS="$BUILD_DIR/ExportOptions.generated.plist"
cp ExportOptions.plist "$EXPORT_OPTS"
# Set first (fails cleanly rc=1 if absent), then Add. PlistBuddy exits 0 on some
# real errors, so assert the value afterwards instead of trusting the exit code.
/usr/libexec/PlistBuddy -c "Set :teamID ${TEAM_ID}" "$EXPORT_OPTS" 2>/dev/null \
	|| /usr/libexec/PlistBuddy -c "Add :teamID string ${TEAM_ID}" "$EXPORT_OPTS" >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :teamID' "$EXPORT_OPTS" 2>/dev/null)" == "$TEAM_ID" ]] || {
	echo "error: teamID was not injected into $EXPORT_OPTS" >&2
	exit 1
}

rm -rf "$BUILD_DIR/export"
xcodebuild -exportArchive \
	-archivePath "$ARCHIVE" \
	-exportPath "$BUILD_DIR/export" \
	-exportOptionsPlist "$EXPORT_OPTS" \
	-allowProvisioningUpdates \
	${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"}

IPA=$(/usr/bin/find "$BUILD_DIR/export" -maxdepth 1 -name '*.ipa' -print -quit)
[[ -n "$IPA" ]] || { echo "error: no .ipa produced" >&2; exit 1; }
echo "==> exported $IPA"

if (( ! UPLOAD )); then
	echo "==> --build-only, stopping here"
	exit 0
fi

# --- upload ------------------------------------------------------------------
if (( VALIDATE )); then
	xcrun altool --validate-app \
		-f "$IPA" -t ios \
		"${ALTOOL_AUTH[@]}"
fi

xcrun altool --upload-app \
	-f "$IPA" -t ios \
	"${ALTOOL_AUTH[@]}"

# Ship succeeded — keep the bumped version instead of rolling it back.
if (( BUMP )); then
	trap - EXIT
	rm -f "$PBXPROJ.shipbak"
fi

echo "==> uploaded ${MARKETING} (${BUILD_NUM}). Processing takes ~5-15 min, then it shows in TestFlight."
echo "==> commit the build bump:  git add \"$PBXPROJ\" && git commit -m \"Build ${BUILD_NUM}\""
