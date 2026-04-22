#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GALLERY_ROOT="$(cd "$IOS_APP_DIR/.." && pwd)"
DEFAULT_MONOREPO="$HOME/workspace/monorepo"
MAIL_MCP_RS_ROOT="${MAIL_MCP_RS_ROOT:-$DEFAULT_MONOREPO/services/ilhae-agent/mail-mcp-rs}"
MANIFEST="$MAIL_MCP_RS_ROOT/ios-ffi/Cargo.toml"
VENDOR_DIR="$IOS_APP_DIR/Vendor/MailMCPRS"
TARGET_DIR="${CARGO_TARGET_DIR:-$GALLERY_ROOT/tmp/mail-mcp-rs-ios-target}"
PLATFORM="${PLATFORM_NAME:-iphoneos}"
ARCHS_VALUE="${ARCHS:-arm64}"

if [[ ! -f "$MANIFEST" ]]; then
  echo "warning: mail-mcp-rs iOS FFI manifest not found at $MANIFEST; skipping embedded MailMCP Rust build" >&2
  exit 0
fi

mkdir -p "$VENDOR_DIR/include" "$VENDOR_DIR/lib/$PLATFORM"
cp "$MAIL_MCP_RS_ROOT/ios-ffi/include/MailMCPRS.h" "$VENDOR_DIR/include/MailMCPRS.h" 2>/dev/null || true
if [[ ! -f "$VENDOR_DIR/include/MailMCPRS.h" ]]; then
  cat > "$VENDOR_DIR/include/MailMCPRS.h" <<'HDR'
#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
char *mail_mcp_rs_embedded_init(const char *db_path);
char *mail_mcp_rs_embedded_list_tools(void);
char *mail_mcp_rs_embedded_call_tool(const char *name, const char *args_json);
void mail_mcp_rs_embedded_free_string(char *ptr);
#ifdef __cplusplus
}
#endif
HDR
fi

build_target() {
  local target="$1"
  CARGO_TARGET_DIR="$TARGET_DIR" cargo build --manifest-path "$MANIFEST" --target "$target" --release
  echo "$TARGET_DIR/$target/release/libmail_mcp_rs_ios.a"
}

libs=()
if [[ "$PLATFORM" == "iphonesimulator" ]]; then
  if [[ "$ARCHS_VALUE" == *"arm64"* ]]; then
    libs+=("$(build_target aarch64-apple-ios-sim)")
  fi
  if [[ "$ARCHS_VALUE" == *"x86_64"* ]]; then
    libs+=("$(build_target x86_64-apple-ios)")
  fi
else
  libs+=("$(build_target aarch64-apple-ios)")
fi

out="$VENDOR_DIR/lib/$PLATFORM/libmail_mcp_rs_ios.a"
if [[ ${#libs[@]} -eq 1 ]]; then
  cp "${libs[0]}" "$out"
else
  lipo -create "${libs[@]}" -output "$out"
fi

echo "Built embedded mail-mcp-rs static library: $out"
