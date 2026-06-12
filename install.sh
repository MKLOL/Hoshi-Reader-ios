#!/usr/bin/env bash
#
# install.sh — build Hoshi Reader and install it onto your connected iPhone/iPad.
#
# Usage:
#   ./install.sh                 # install to ALL paired iPhones/iPads
#   ./install.sh iphone          # only devices whose name/udid matches "iphone"
#   ./install.sh ipad            # only the iPad
#   ./install.sh 00008150-...    # a specific UDID
#
# Env overrides:
#   CONFIG=Release ./install.sh  # leaner build (default: Debug, the proven config)
#   NO_LAUNCH=1 ./install.sh     # install but don't auto-launch
#
# Notes:
#   * Free Apple ID signing → the app expires ~7 days after install. Re-run this to refresh.
#   * First time on a NEW device: plug it in, tap "Trust" on the device, run this, then on the
#     device go Settings → General → VPN & Device Management → trust the Apple Development cert.
#
set -euo pipefail
cd "$(dirname "$0")"

PROJECT="Hoshi Reader.xcodeproj"
SCHEME="Hoshi Reader"
CONFIG="${CONFIG:-Debug}"
BUNDLE_ID="com.dragosristache.hoshi"
DERIVED="build/DD"
APP="$DERIVED/Build/Products/${CONFIG}-iphoneos/Hoshi Reader.app"
FILTER="${1:-}"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
err()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# --- 1. Discover paired iPhones/iPads --------------------------------------
DEVJSON="$(mktemp -t hoshi-devs).json"
xcrun devicectl list devices --json-output "$DEVJSON" >/dev/null 2>&1 || true

DEVICES=()
while IFS= read -r _line; do
  [ -n "$_line" ] && DEVICES+=("$_line")
done < <(/usr/bin/python3 - "$DEVJSON" "$FILTER" <<'PY'
import json, sys
path, flt = sys.argv[1], sys.argv[2].lower()
try:
    devs = json.load(open(path))["result"]["devices"]
except Exception:
    devs = []
for d in devs:
    hp, dp = d.get("hardwareProperties", {}), d.get("deviceProperties", {})
    cp = d.get("connectionProperties", {})
    if hp.get("deviceType") not in ("iPhone", "iPad"):
        continue
    if cp.get("pairingState") != "paired":
        continue
    udid, name = hp.get("udid", ""), dp.get("name", "?")
    if flt and flt not in udid.lower() and flt not in name.lower():
        continue
    print(f"{udid}\t{name}")
PY
)
rm -f "$DEVJSON"

if [ "${#DEVICES[@]}" -eq 0 ]; then
  err "No matching paired iPhone/iPad found."
  err "Plug a device in (and tap Trust), then re-run. Current devices:"
  xcrun devicectl list devices 2>/dev/null || true
  exit 1
fi

bold "Targets (${#DEVICES[@]}):"
for d in "${DEVICES[@]}"; do printf '  • %s  [%s]\n' "${d#*$'\t'}" "${d%%$'\t'*}"; done

# --- 2. Build + install + launch, per device -------------------------------
# Per-device build is incremental after the first (just re-signs for that device),
# and guarantees a brand-new device gets registered in the free-team profile.
FAILED=0
for d in "${DEVICES[@]}"; do
  UDID="${d%%$'\t'*}"; NAME="${d#*$'\t'}"
  echo
  bold "▶ $NAME ($UDID)"

  echo "  building ($CONFIG)…"
  if ! xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
        -destination "platform=iOS,id=$UDID" -derivedDataPath "$DERIVED" \
        -allowProvisioningUpdates -skipMacroValidation build \
        >/tmp/hoshi-build.log 2>&1; then
    err "  ✗ build failed — see /tmp/hoshi-build.log (last lines):"
    tail -n 15 /tmp/hoshi-build.log >&2
    FAILED=1; continue
  fi

  echo "  installing…"
  if ! xcrun devicectl device install app --device "$UDID" "$APP" >/dev/null 2>&1; then
    err "  ✗ install failed (device unreachable, or needs Trust on-device?)"
    FAILED=1; continue
  fi

  if [ -z "${NO_LAUNCH:-}" ]; then
    echo "  launching…"
    xcrun devicectl device process launch --device "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 \
      || err "  (installed OK, but couldn't auto-launch — open it on the device)"
  fi
  bold "  ✓ done"
done

echo
if [ "$FAILED" -eq 0 ]; then
  bold "All installs succeeded."
else
  err "Some installs failed (see above)."
fi
echo "Reminder: free-team builds expire ~7 days — just re-run ./install.sh to refresh."
exit "$FAILED"
