#!/usr/bin/env bash
# Package a built macOS .app bundle into a compressed DMG containing the app
# and an /Applications symlink, then mount-verify the resulting DMG.
#
# Usage: packaging/create-dmg.sh <path/to/Ivynote.app> <output.dmg> [volume-name]
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 <app-path> <output-dmg> [volume-name]" >&2
  exit 1
fi

APP_PATH=$1
OUTPUT_DMG=$2
VOLUME_NAME=${3:-Ivynote}

if [[ ! -d "$APP_PATH" ]]; then
  echo "::error::App bundle not found: $APP_PATH" >&2
  exit 1
fi

APP_NAME=$(basename "$APP_PATH")
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ivynote-dmg.XXXXXX")
STAGE_DIR="$WORK_DIR/stage"
MOUNT_DIR="$WORK_DIR/mount"
MOUNTED=0

cleanup() {
  if [[ "$MOUNTED" -eq 1 ]]; then
    hdiutil detach "$MOUNT_DIR" -quiet || hdiutil detach "$MOUNT_DIR" -force -quiet || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$STAGE_DIR" "$(dirname "$OUTPUT_DMG")"
# ditto preserves symlinks, resource forks, extended attributes, and code signatures.
ditto "$APP_PATH" "$STAGE_DIR/$APP_NAME"
ln -s /Applications "$STAGE_DIR/Applications"

rm -f "$OUTPUT_DMG"

# GitHub Actions macOS runners occasionally hit transient "Resource busy" errors
# from Spotlight indexing the temporary image; retry a few times.
attempt=1
max_attempts=3
while true; do
  if hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGE_DIR" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$OUTPUT_DMG"; then
    break
  fi
  if [[ "$attempt" -ge "$max_attempts" ]]; then
    echo "::error::hdiutil create failed after $max_attempts attempts" >&2
    exit 1
  fi
  echo "hdiutil create failed (attempt $attempt/$max_attempts); retrying in 5s..." >&2
  rm -f "$OUTPUT_DMG"
  sleep 5
  attempt=$((attempt + 1))
done

# Mount-verify the DMG to make sure the image is intact and readable.
mkdir -p "$MOUNT_DIR"
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_DIR" "$OUTPUT_DMG" >/dev/null
MOUNTED=1

test -d "$MOUNT_DIR/$APP_NAME"
test -L "$MOUNT_DIR/Applications"
codesign --verify --deep --strict "$MOUNT_DIR/$APP_NAME"

hdiutil detach "$MOUNT_DIR" -quiet || hdiutil detach "$MOUNT_DIR" -force -quiet
MOUNTED=0

echo "Created and verified $OUTPUT_DMG ($(du -h "$OUTPUT_DMG" | awk '{print $1}'))"
