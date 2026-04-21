#!/usr/bin/env bash
# Builds local LiteRT-LM iOS XCFrameworks for GalleryIOS.
# Pattern adapted from songhieu/flutter_litert_lm (Apache-2.0), but scoped to
# iOS device + Apple Silicon simulator slices used by this app.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$IOS_ROOT/.." && pwd)"
WORKDIR="${GALLERY_LITERTLM_WORKDIR:-$REPO_ROOT/tmp/litertlm-minimal-build}"
DEST="${GALLERY_LITERTLM_VENDOR_DIR:-$IOS_ROOT/Vendor/LiteRTLM}"
MINIMAL_REPO="https://github.com/scriptease/LiteRTLMMinimal.git"

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

if [ -d "$DEST/LiteRTLM.xcframework" ] && [ -d "$DEST/GemmaModelConstraintProvider.xcframework" ]; then
  echo "LiteRT-LM iOS XCFrameworks already exist in $DEST"
  exit 0
fi

if ! command -v bazelisk >/dev/null 2>&1 && ! command -v bazel >/dev/null 2>&1; then
  echo "error: bazelisk or bazel is required to build LiteRT-LM iOS frameworks." >&2
  echo "Install with: brew install bazelisk git-lfs" >&2
  exit 1
fi
if command -v git-lfs >/dev/null 2>&1 || git lfs version >/dev/null 2>&1; then
  git lfs install --skip-smudge >/dev/null 2>&1 || true
fi

mkdir -p "$(dirname "$WORKDIR")" "$DEST"

if [ ! -d "$WORKDIR/.git" ]; then
  echo "==> Cloning $MINIMAL_REPO into $WORKDIR"
  git clone --depth 1 "$MINIMAL_REPO" "$WORKDIR"
fi
if [ ! -d "$WORKDIR/LiteRT-LM/c" ]; then
  echo "==> Initializing LiteRT-LM submodule"
  (cd "$WORKDIR" && git submodule update --init --depth 1)
fi

if [ ! -f "$WORKDIR/build/lib/ios_arm64/libc_engine.a" ]; then
  echo "==> Building LiteRT-LM ios_arm64 static engine"
  (cd "$WORKDIR" && bash scripts/build-litert-macos.sh ios_arm64)
fi
if [ ! -f "$WORKDIR/build/lib/ios_sim_arm64/libc_engine.a" ]; then
  echo "==> Building LiteRT-LM ios_sim_arm64 static engine"
  (cd "$WORKDIR" && bash scripts/build-litert-macos.sh ios_sim_arm64)
fi

WRAP_DIR="$WORKDIR/build/gallery-ios-wrapped-frameworks"
rm -rf "$WRAP_DIR"
mkdir -p "$WRAP_DIR"

wrap_static_litertlm_framework() {
  local platform="$1"
  local plist_platform="$2"
  local min_os="13.0"
  local name="LiteRTLM"
  local src="$WORKDIR/build/lib/$platform/libc_engine.a"
  local out="$WRAP_DIR/$platform/$name.framework"
  mkdir -p "$out/Headers"
  cp "$src" "$out/$name"
  cp "$WORKDIR/LiteRT-LM/c/engine.h" "$out/Headers/"
  cat > "$out/Headers/module.modulemap" <<MODULEMAP
framework module $name {
  umbrella header "engine.h"
  export *
  module * { export * }
}
MODULEMAP
  cat > "$out/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>$name</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$plist_platform</string></array>
  <key>MinimumOSVersion</key><string>$min_os</string>
</dict></plist>
PLIST
}

wrap_dynamic_gemma_framework() {
  local platform="$1"
  local plist_platform="$2"
  local min_os="13.0"
  local name="GemmaModelConstraintProvider"
  local src="$WORKDIR/build/lib/$platform/libGemmaModelConstraintProvider.dylib"
  local out="$WRAP_DIR/$platform/$name.framework"
  mkdir -p "$out"
  cp "$src" "$out/$name"
  install_name_tool -id "@rpath/$name.framework/$name" "$out/$name" 2>/dev/null || true
  cat > "$out/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>$name</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$plist_platform</string></array>
  <key>MinimumOSVersion</key><string>$min_os</string>
</dict></plist>
PLIST
}

wrap_static_litertlm_framework ios_arm64 iPhoneOS
wrap_static_litertlm_framework ios_sim_arm64 iPhoneSimulator
wrap_dynamic_gemma_framework ios_arm64 iPhoneOS
wrap_dynamic_gemma_framework ios_sim_arm64 iPhoneSimulator

rm -rf "$WORKDIR/build/gallery-ios-xcframeworks"
mkdir -p "$WORKDIR/build/gallery-ios-xcframeworks"

xcodebuild -create-xcframework \
  -framework "$WRAP_DIR/ios_arm64/LiteRTLM.framework" \
  -framework "$WRAP_DIR/ios_sim_arm64/LiteRTLM.framework" \
  -output "$WORKDIR/build/gallery-ios-xcframeworks/LiteRTLM.xcframework"

xcodebuild -create-xcframework \
  -framework "$WRAP_DIR/ios_arm64/GemmaModelConstraintProvider.framework" \
  -framework "$WRAP_DIR/ios_sim_arm64/GemmaModelConstraintProvider.framework" \
  -output "$WORKDIR/build/gallery-ios-xcframeworks/GemmaModelConstraintProvider.xcframework"

rm -rf "$DEST/LiteRTLM.xcframework" "$DEST/GemmaModelConstraintProvider.xcframework"
cp -R "$WORKDIR/build/gallery-ios-xcframeworks/LiteRTLM.xcframework" "$DEST/"
cp -R "$WORKDIR/build/gallery-ios-xcframeworks/GemmaModelConstraintProvider.xcframework" "$DEST/"

echo "==> LiteRT-LM iOS frameworks ready:"
du -sh "$DEST"/*.xcframework
