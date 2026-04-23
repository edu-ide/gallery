#!/usr/bin/env bash
set -euo pipefail
ROOT="${1:-$(pwd)}"
FILES=(
  "$ROOT/iosApp/Sources/GalleryIOS/UgotMCPToolSearchIndex.swift"
  "$ROOT/iosApp/Sources/GalleryIOS/UgotMCPActionRunner.swift"
)
# Domain words that must not be introduced into generic mobile MCP core.
# Existing violations are reported so the fix can move them to server metadata or connector adapters.
PATTERN='오늘|운세|사주|궁합|띠별|명식|금일|saju|fortune|zodiac|horoscope|compatibility|show_today_fortune|show_saju|saved user|default saved user'
status=0
for file in "${FILES[@]}"; do
  [[ -f "$file" ]] || continue
  if grep -nE "$PATTERN" "$file"; then
    echo "mcp-thin-host-boundary: connector-domain terms found in generic MCP core: $file" >&2
    status=1
  fi
done
exit "$status"
