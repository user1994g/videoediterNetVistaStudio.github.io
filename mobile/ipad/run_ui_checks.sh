#!/bin/bash
# Disposable native simulator checks. Never uses the production app identity.
set -euo pipefail
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
OUTPUT_DIR="${1:-$(mktemp -d /private/tmp/netvista-ios-ui-run.XXXXXX)}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
bash "$SOURCE_DIR/check_ui.sh" "$OUTPUT_DIR"
bash "$SOURCE_DIR/check_shared_core.sh" "$OUTPUT_DIR"
RUNTIME="$(xcrun simctl list runtimes --json | jq -r '[.runtimes[] | select(.isAvailable and (.identifier | contains(".iOS-")))] | sort_by(.version | split(".") | map(tonumber)) | last | .identifier // empty')"
[[ -n "$RUNTIME" ]] || { printf 'No available iOS simulator runtime\n' >&2; exit 1; }
TEST_DEVICE=""
cleanup() {
  # Only remove the exact disposable device created by this invocation.
  if [[ "$TEST_DEVICE" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
    xcrun simctl shutdown "$TEST_DEVICE" >/dev/null 2>&1 || true
    xcrun simctl delete "$TEST_DEVICE" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
for FAMILY in phone tablet; do
  TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro
  [[ "$FAMILY" != tablet ]] || TYPE=com.apple.CoreSimulator.SimDeviceType.iPad-mini-A17-Pro
  TEST_DEVICE="$(xcrun simctl create "NetVista disposable workspace $FAMILY" "$TYPE" "$RUNTIME")"
  xcrun simctl boot "$TEST_DEVICE"
  xcrun simctl bootstatus "$TEST_DEVICE" -b
  # Original Mac engines execute in an isolated UIKit bundle, without accounts
  # or production entry points. Compilation alone cannot validate pixel output.
  xcrun simctl install "$TEST_DEVICE" "$OUTPUT_DIR/NetVistaSharedCoreChecks.app"
  xcrun simctl launch "$TEST_DEVICE" com.netvistastudio.shared-core-checks
  CORE_DATA="$(xcrun simctl get_app_container "$TEST_DEVICE" com.netvistastudio.shared-core-checks data)"
  CORE_RESULT="$CORE_DATA/Documents/shared-core-result.txt"
  for (( ATTEMPT=0; ATTEMPT<60; ATTEMPT++ )); do
    [[ ! -f "$CORE_RESULT" ]] || break
    sleep 2
  done
  mkdir -p "$OUTPUT_DIR/$FAMILY/shared-core"
  cp -R "$CORE_DATA/Documents/." "$OUTPUT_DIR/$FAMILY/shared-core/"
  [[ -f "$CORE_RESULT" ]] || { printf 'Shared native %s engine checks timed out\n' "$FAMILY" >&2; exit 1; }
  sed -n '1,4p' "$CORE_RESULT"
  grep -q '^PASS:' "$CORE_RESULT"
  xcrun simctl install "$TEST_DEVICE" "$OUTPUT_DIR/NetVistaWorkspaceChecks.app"
  xcrun simctl launch "$TEST_DEVICE" com.netvistastudio.workspace-checks
  TEST_DATA="$(xcrun simctl get_app_container "$TEST_DEVICE" com.netvistastudio.workspace-checks data)"
  RESULT="$TEST_DATA/Documents/workspace-result.txt"
  for (( ATTEMPT=0; ATTEMPT<90; ATTEMPT++ )); do
    [[ ! -f "$RESULT" ]] || break
    sleep 2
  done
  mkdir -p "$OUTPUT_DIR/$FAMILY"
  cp -R "$TEST_DATA/Documents/." "$OUTPUT_DIR/$FAMILY/"
  xcrun simctl io "$TEST_DEVICE" screenshot "$OUTPUT_DIR/$FAMILY/screen.png" || true
  [[ -f "$RESULT" ]] || { printf 'Native %s checks timed out\n' "$FAMILY" >&2; exit 1; }
  sed -n '1,12p' "$RESULT"
  grep -q '^PASS:' "$RESULT"
  cleanup
  TEST_DEVICE=""
done
