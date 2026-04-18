#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PACKAGE_NAME="${PACKAGE_NAME:-com.ugot.chat}"
ACTIVITY_NAME="${ACTIVITY_NAME:-com.google.ai.edge.gallery.MainActivity}"
APK_PATH="$ROOT_DIR/Android/src/app/build/outputs/apk/debug/app-debug.apk"
FLOW_DIR="${FLOW_DIR:-$ROOT_DIR/.maestro}"
OUT_DIR="${OUT_DIR:-/tmp/ugot_maestro_smoke}"
TOKEN_FIXTURE="${UGOT_TOKEN_FIXTURE:-}"
DEEP_LINK_URI="${DEEP_LINK_URI:-${PACKAGE_NAME}://model/ugot_fortune_mcp_ui/UGOT%20Fortune%20MCP%20Runtime}"
DEEPLINK_FLOW="$FLOW_DIR/signed-in-deeplink.yaml"
SIGNED_OUT_FLOW="$FLOW_DIR/signed-out-auth-gate.yaml"
BUILD_APK="${BUILD_APK:-1}"
BUILD_JAVA_HOME="${BUILD_JAVA_HOME:-/usr/lib/jvm/java-21-openjdk-amd64}"

ADB_ARGS=()
MAESTRO_ARGS=()

if [[ -n "${ANDROID_SERIAL:-}" ]]; then
  ADB_ARGS+=("-s" "$ANDROID_SERIAL")
  MAESTRO_ARGS+=("--device" "$ANDROID_SERIAL")
fi

adb_cmd() {
  adb "${ADB_ARGS[@]}" "$@"
}

maestro_cmd() {
  maestro "${MAESTRO_ARGS[@]}" "$@"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

seed_token_fixture() {
  local fixture="$1"

  adb_cmd push "$fixture" /data/local/tmp/user_data.pb >/dev/null
  adb_cmd shell run-as "$PACKAGE_NAME" mkdir -p files/datastore
  adb_cmd shell run-as "$PACKAGE_NAME" cp /data/local/tmp/user_data.pb files/datastore/user_data.pb
}

start_deep_link() {
  adb_cmd shell am start -W -f 0x10008000 -n "$PACKAGE_NAME/$ACTIVITY_NAME" \
    -a android.intent.action.VIEW -d "$DEEP_LINK_URI" >/dev/null
}

main() {
  require_cmd adb
  require_cmd maestro

  mkdir -p "$OUT_DIR"

  if [[ "$BUILD_APK" == "1" ]]; then
    (cd "$ROOT_DIR" && JAVA_HOME="$BUILD_JAVA_HOME" ./Android/src/gradlew -p Android/src app:assembleDebug)
  fi

  adb_cmd install -r "$APK_PATH" >/dev/null

  if [[ -d "$FLOW_DIR" ]]; then
    while IFS= read -r flow; do
      maestro_cmd check-syntax "$flow"
    done < <(find "$FLOW_DIR" -maxdepth 1 -type f -name '*.yaml' | sort)
  else
    maestro_cmd check-syntax "$FLOW_DIR"
  fi

  echo "[maestro] signed-out auth gate"
  maestro_cmd test --test-output-dir "$OUT_DIR/signed-out-auth-gate" "$SIGNED_OUT_FLOW"

  if [[ -n "$TOKEN_FIXTURE" ]]; then
    [[ -f "$TOKEN_FIXTURE" ]] || {
      echo "UGOT_TOKEN_FIXTURE points to a missing file: $TOKEN_FIXTURE" >&2
      exit 1
    }

    echo "[maestro] signed-in deep link"
    adb_cmd shell pm clear "$PACKAGE_NAME" >/dev/null
    seed_token_fixture "$TOKEN_FIXTURE"
    start_deep_link
    maestro_cmd test --test-output-dir "$OUT_DIR/signed-in-deeplink" "$DEEPLINK_FLOW"
  else
    echo "[maestro] skipping signed-in deep link flow because UGOT_TOKEN_FIXTURE is not set"
  fi

  cat <<EOF
Maestro smoke completed.
Artifacts written to: $OUT_DIR

Flows:
- signed-out-auth-gate
- signed-in-deeplink (expects shared shell markers like Connectors and Open when UGOT_TOKEN_FIXTURE is set)
EOF
}

main "$@"
