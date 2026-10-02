#!/bin/bash
# CI: run the Maestro flows with maestro-runner (https://github.com/devicelab-dev/maestro-runner).
#
# Mirrors .maestro/scripts/run-tests.sh after its device setup (which creates
# and boots a local simulator/emulator, and uses macOS-only sed on Android):
# build and install the example app, then the same two passes over the same
# flows (regular flows, then accessibility flows with the system text size
# enlarged), the same tag exclusions and the same --env values. Each pass is
# one maestro-runner process for all its flows.
#
# Usage: run-maestro-runner.sh --platform <ios|android> --device <id> [--update-screenshots]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MAESTRO_ROOT="$REPO_ROOT/.maestro"
SCREENSHOT_ROOT="$MAESTRO_ROOT"
BUNDLE_ID="swmansion.enriched.example"
REPORTS="$REPO_ROOT/reports"
RUNNER="${MAESTRO_RUNNER:-$HOME/.maestro-runner/bin/maestro-runner}"

PLATFORM=""
DEVICE_ID=""
UPDATE_SCREENSHOTS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --platform)           PLATFORM="$2"; shift 2 ;;
    --device)             DEVICE_ID="$2"; shift 2 ;;
    --update-screenshots) UPDATE_SCREENSHOTS="true"; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
case "$PLATFORM" in ios|android) ;; *) echo "--platform must be ios or android" >&2; exit 1 ;; esac
[ -n "$DEVICE_ID" ] || { echo "--device is required" >&2; exit 1; }

"$RUNNER" --version

set_font_scale() {
  case "$1" in
    default) ios_size="large";               android_scale="1.0" ;;
    large)   ios_size="accessibility-large"; android_scale="1.5" ;;
  esac
  if [ "$PLATFORM" = ios ]; then
    xcrun simctl ui "$DEVICE_ID" content_size "$ios_size"
  else
    adb -s "$DEVICE_ID" shell settings put system font_scale "$android_scale"
  fi
}
trap 'set_font_scale default' EXIT

echo "=== Building and installing the example app ==="
cd "$REPO_ROOT"
if [ "$PLATFORM" = ios ]; then
  # The React Native CLI's own install step can fail on CI ("The specified
  # device was not found") after a good build; install the built app with
  # simctl as well, so the app is on the simulator either way.
  yarn example ios --udid "$DEVICE_ID" || true
  APP=$(ls -dt "$HOME"/Library/Developer/Xcode/DerivedData/EnrichedTextInputExample-*/Build/Products/Debug-iphonesimulator/EnrichedTextInputExample.app 2>/dev/null | head -1)
  [ -n "$APP" ] || { echo "Error: built app not found" >&2; exit 1; }
  xcrun simctl install "$DEVICE_ID" "$APP"
else
  yarn example android --device "$DEVICE_ID"
fi

FLOWS=".maestro/enrichedInput/flows .maestro/enrichedText/flows"
[ -d "$MAESTRO_ROOT/assets" ] && FLOWS="$MAESTRO_ROOT/assets $FLOWS"

EXTRA=(--env "SCREENSHOT_ROOT=$SCREENSHOT_ROOT")
[ -n "$UPDATE_SCREENSHOTS" ] && EXTRA+=(--env UPDATE_SCREENSHOTS=true)
case "$PLATFORM" in
  ios)     EXTRA+=(--exclude-tags android-only) ;;
  android) EXTRA+=(--exclude-tags ios-only) ;;
esac

# Like run-tests.sh: a tag filter that matches no flows is not a failure
# (maestro-runner says "no test flows found" where Maestro says "did not
# match any Flows").
run_pass() {
  local name=$1; shift
  local log rc=0
  log=$(mktemp)
  # shellcheck disable=SC2086
  "$RUNNER" --platform "$PLATFORM" --device "$DEVICE_ID" test "$@" "${EXTRA[@]}" \
    --output "$REPORTS/$PLATFORM-$name" --flatten $FLOWS > >(tee "$log") 2>&1 || rc=$?
  wait
  if [ "$rc" -ne 0 ] && grep -q "no test flows found" "$log"; then
    echo "warn: no flows matched the tag filter, treating as success" >&2
    rc=0
  fi
  rm -f "$log"
  return "$rc"
}

set_font_scale default
EXIT_REGULAR=0
EXIT_A11Y=0
echo "=== Running maestro-runner tests ==="
run_pass regular --exclude-tags accessibility || EXIT_REGULAR=$?
echo "=== Running maestro-runner accessibility tests ==="
set_font_scale large
run_pass accessibility --include-tags accessibility || EXIT_A11Y=$?

exit $(( EXIT_REGULAR != 0 || EXIT_A11Y != 0 ))
