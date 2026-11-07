#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-build/Build/Products/Release-iphoneos/YZLLauncher.app}"
OUTPUT="${2:-YZLLauncher-unsigned.ipa}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App not found: $APP_PATH" >&2
  exit 1
fi

rm -rf Payload "$OUTPUT"
mkdir -p Payload
cp -R "$APP_PATH" Payload/
zip -qry "$OUTPUT" Payload
rm -rf Payload

echo "Created $OUTPUT"
