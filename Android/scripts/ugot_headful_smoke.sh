#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APK_PATH="$ROOT_DIR/Android/src/app/build/outputs/apk/debug/app-debug.apk"
PACKAGE_NAME="${PACKAGE_NAME:-com.ugot.chat}"
ACTIVITY_NAME="${ACTIVITY_NAME:-com.google.ai.edge.gallery.MainActivity}"
DEEP_LINK_URI="${DEEP_LINK_URI:-${PACKAGE_NAME}://model/ugot_fortune_mcp_ui/UGOT%20Fortune%20MCP%20Runtime}"
OUT_DIR="${OUT_DIR:-/tmp/ugot_headful_smoke}"
TOKEN_FIXTURE="${UGOT_TOKEN_FIXTURE:-}"
BUILD_APK="${BUILD_APK:-1}"
BUILD_JAVA_HOME="${BUILD_JAVA_HOME:-/usr/lib/jvm/java-21-openjdk-amd64}"

ADB_ARGS=()
if [[ -n "${ANDROID_SERIAL:-}" ]]; then
  ADB_ARGS+=("-s" "$ANDROID_SERIAL")
fi

adb_cmd() {
  adb "${ADB_ARGS[@]}" "$@"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

dump_state() {
  local scenario="$1"

  adb_cmd shell uiautomator dump "/sdcard/${scenario}.xml" >/dev/null
  adb_cmd pull "/sdcard/${scenario}.xml" "$OUT_DIR/${scenario}.xml" >/dev/null
  adb_cmd exec-out screencap -p >"$OUT_DIR/${scenario}.png"
}

capture_log() {
  local scenario="$1"
  local pattern="$2"

  adb_cmd logcat -d | rg "$pattern" >"$OUT_DIR/${scenario}.log" || true
}

summarize_ui() {
  local scenario="$1"
  python3 - "$OUT_DIR/${scenario}.xml" <<'PY'
from pathlib import Path
import sys

ui = Path(sys.argv[1]).read_text(errors="ignore")
  tokens = [
    "UGOT Fortune",
    "Connectors",
    "Open",
    "android.webkit.WebView",
    "WebView",
    "Sign in to UGOT Chat",
    "Continue with Google",
]
found = [token for token in tokens if token in ui]
print(", ".join(found) if found else "no known markers found")
PY
}

find_button_center() {
  local text="$1"
  local xml_path="$2"

  python3 - "$text" "$xml_path" <<'PY'
from pathlib import Path
import re
import sys

label = re.escape(sys.argv[1])
ui = Path(sys.argv[2]).read_text(errors="ignore")
match = re.search(rf'text="{label}".*?bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', ui)
if not match:
    raise SystemExit(1)
left, top, right, bottom = map(int, match.groups())
print((left + right) // 2, (top + bottom) // 2)
PY
}

start_activity() {
  adb_cmd shell am start -W -n "$PACKAGE_NAME/$ACTIVITY_NAME" >/dev/null
}

start_deep_link() {
  adb_cmd shell am start -W -f 0x10008000 -n "$PACKAGE_NAME/$ACTIVITY_NAME" \
    -a android.intent.action.VIEW -d "$DEEP_LINK_URI" >/dev/null
}

seed_token_fixture() {
  local fixture="$1"

  adb_cmd push "$fixture" /data/local/tmp/user_data.pb >/dev/null
  adb_cmd shell run-as "$PACKAGE_NAME" mkdir -p files/datastore
  adb_cmd shell run-as "$PACKAGE_NAME" cp /data/local/tmp/user_data.pb files/datastore/user_data.pb
}

scenario_signed_in_deeplink() {
  [[ -n "$TOKEN_FIXTURE" ]] || return 0
  [[ -f "$TOKEN_FIXTURE" ]] || {
    echo "UGOT_TOKEN_FIXTURE points to a missing file: $TOKEN_FIXTURE" >&2
    exit 1
  }

  echo "[signed-in-deeplink] running"
  adb_cmd shell pm clear "$PACKAGE_NAME" >/dev/null
  seed_token_fixture "$TOKEN_FIXTURE"
  adb_cmd logcat -c
  start_deep_link
  sleep 8
  capture_log "signed_in_deeplink" 'AGGalleryNavGraph|AGModelManagerViewModel|startup|UGOT Fortune MCP Runtime'
  dump_state "signed_in_deeplink"
  echo "[signed-in-deeplink] ui markers: $(summarize_ui signed_in_deeplink)"
}

scenario_signed_out_auth_gate() {
  echo "[signed-out-auth-gate] running"
  adb_cmd shell pm clear "$PACKAGE_NAME" >/dev/null
  adb_cmd logcat -c
  start_activity
  sleep 5
  capture_log "signed_out_auth_gate" 'AGGalleryNavGraph|startup|auth_login'
  dump_state "signed_out_auth_gate"
  echo "[signed-out-auth-gate] ui markers: $(summarize_ui signed_out_auth_gate)"
}

main() {
  require_cmd adb
  require_cmd python3
  require_cmd rg

  mkdir -p "$OUT_DIR"

  adb_cmd devices -l >/dev/null

  if [[ "$BUILD_APK" == "1" ]]; then
    (cd "$ROOT_DIR" && JAVA_HOME="$BUILD_JAVA_HOME" ./Android/src/gradlew -p Android/src app:assembleDebug)
  fi

  adb_cmd install -r "$APK_PATH" >/dev/null

  scenario_signed_in_deeplink
  scenario_signed_out_auth_gate

  cat <<EOF
Artifacts written to: $OUT_DIR

Expected headful checks:
- signed_in_deeplink.png shows the shared chat shell with the Fortune widget markers when a valid token fixture is supplied
- signed_out_auth_gate.png shows the UGOT sign-in screen
EOF
}

main "$@"
