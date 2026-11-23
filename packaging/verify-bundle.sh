#!/usr/bin/env bash
# Verify a built macOS .app bundle or iOS .ipa archive:
# - executable exists and has the expected architectures
# - Info.plist has the expected bundle ID, marketing version, and build number
# - bundled web editor assets exist
# - code signature (and optional notarization ticket) validates cleanly
#
# Usage:
#   packaging/verify-bundle.sh --macos <Ivynote.app> [--universal] [--version <ver>] [--build <num>] [--dmg <Ivynote.dmg>] [--notarized <true|false>]
#   packaging/verify-bundle.sh --ios <Ivynote.ipa|Ivynote.app> [--version <ver>] [--build <num>] [--signed <true|false>]
set -euo pipefail

PLATFORM=""
TARGET=""
UNIVERSAL=false
EXPECTED_VERSION=""
EXPECTED_BUILD=""
SIGNED=false
NOTARIZED=false
DMG_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --macos)
      PLATFORM="macos"
      TARGET=$2
      shift 2
      ;;
    --ios)
      PLATFORM="ios"
      TARGET=$2
      shift 2
      ;;
    --universal)
      UNIVERSAL=true
      shift
      ;;
    --version)
      EXPECTED_VERSION=$2
      shift 2
      ;;
    --build)
      EXPECTED_BUILD=$2
      shift 2
      ;;
    --signed)
      SIGNED=$2
      shift 2
      ;;
    --notarized)
      NOTARIZED=$2
      shift 2
      ;;
    --dmg)
      DMG_PATH=$2
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$PLATFORM" || -z "$TARGET" ]]; then
  echo "Usage: $0 (--macos <app> | --ios <ipa|app>) [options]" >&2
  exit 1
fi

plist_get() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1"
}

check_plist() {
  local plist=$1
  test -f "$plist"

  local bundle_id short_ver build_ver
  bundle_id=$(plist_get "$plist" CFBundleIdentifier)
  short_ver=$(plist_get "$plist" CFBundleShortVersionString)
  build_ver=$(plist_get "$plist" CFBundleVersion)

  echo "Bundle ID: $bundle_id, Version: $short_ver ($build_ver)"

  if [[ "$bundle_id" != "app.ivynote" ]]; then
    echo "::error::Unexpected CFBundleIdentifier: $bundle_id (expected app.ivynote)" >&2
    exit 1
  fi
  if [[ -n "$EXPECTED_VERSION" && "$short_ver" != "$EXPECTED_VERSION" ]]; then
    echo "::error::Unexpected CFBundleShortVersionString: $short_ver (expected $EXPECTED_VERSION)" >&2
    exit 1
  fi
  if [[ -n "$EXPECTED_BUILD" && "$build_ver" != "$EXPECTED_BUILD" ]]; then
    echo "::error::Unexpected CFBundleVersion: $build_ver (expected $EXPECTED_BUILD)" >&2
    exit 1
  fi
}

check_editor_assets() {
  local editor_dir=$1
  for f in index.html main.js editor.css; do
    if [[ ! -s "$editor_dir/$f" ]]; then
      echo "::error::Missing or empty editor asset: $editor_dir/$f" >&2
      exit 1
    fi
  done
  if [[ ! -d "$editor_dir/chunks" ]]; then
    echo "::error::Missing editor chunks directory: $editor_dir/chunks" >&2
    exit 1
  fi
}

if [[ "$PLATFORM" == "macos" ]]; then
  if [[ ! -d "$TARGET" ]]; then
    echo "::error::macOS app bundle not found: $TARGET" >&2
    exit 1
  fi

  BIN="$TARGET/Contents/MacOS/Ivynote"
  test -x "$BIN"

  ARCHS=$(lipo -archs "$BIN")
  echo "macOS binary architectures: $ARCHS"
  if [[ "$UNIVERSAL" == true ]]; then
    for arch in arm64 x86_64; do
      if [[ " $ARCHS " != *" $arch "* ]]; then
        echo "::error::Expected universal binary with $arch slice, found: $ARCHS" >&2
        exit 1
      fi
    done
  fi

  check_plist "$TARGET/Contents/Info.plist"
  check_editor_assets "$TARGET/Contents/Resources/Editor"

  codesign --verify --deep --strict --verbose=2 "$TARGET"

  if [[ -n "$DMG_PATH" ]]; then
    test -s "$DMG_PATH"
    if [[ "$NOTARIZED" == true ]]; then
      xcrun stapler validate "$DMG_PATH"
    fi
  fi

  echo "macOS verification passed: $TARGET"
elif [[ "$PLATFORM" == "ios" ]]; then
  WORK_DIR=""
  cleanup() {
    [[ -n "$WORK_DIR" ]] && rm -rf "$WORK_DIR"
  }
  trap cleanup EXIT

  if [[ "$TARGET" == *.ipa ]]; then
    test -s "$TARGET"
    WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ivynote-ipa.XXXXXX")
    unzip -q "$TARGET" -d "$WORK_DIR"
    APP_DIR="$WORK_DIR/Payload/Ivynote.app"
  else
    APP_DIR="$TARGET"
  fi

  if [[ ! -d "$APP_DIR" ]]; then
    echo "::error::iOS app bundle not found inside $TARGET" >&2
    exit 1
  fi

  BIN="$APP_DIR/Ivynote"
  test -x "$BIN"

  ARCHS=$(lipo -archs "$BIN")
  echo "iOS binary architectures: $ARCHS"
  if [[ " $ARCHS " != *" arm64 "* ]]; then
    echo "::error::Expected arm64 iOS binary, found: $ARCHS" >&2
    exit 1
  fi

  check_plist "$APP_DIR/Info.plist"
  check_editor_assets "$APP_DIR/Editor"

  if [[ "$SIGNED" == true ]]; then
    test -s "$APP_DIR/embedded.mobileprovision"
    codesign --verify --deep --strict --verbose=2 "$APP_DIR"
  fi

  echo "iOS verification passed: $TARGET"
fi
