#!/bin/bash
# Builds Photo Organizer for macOS and installs it into /Applications.
#
#   ./build.sh           build and install (relaunches the app if it was running)
#   ./build.sh --test    run the core tests first (dates, plan, duplicates, moves, undo)
#   ./build.sh --zip     also write dist/PhotoOrganizer-macOS-v<version>.zip for a release
#
# INSTALL_DIR=~/Applications ./build.sh installs somewhere else. Only the Xcode Command Line Tools are needed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
NAME="PhotoOrganizer"
BUNDLE_ID="local.photo-organizer"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
DEST="${INSTALL_DIR:-/Applications}"
TEST=0
ZIP=0
for arg in "$@"; do
  case "$arg" in
    --test) TEST=1 ;;
    --zip)  ZIP=1 ;;
    *) sed -n '2,8p' "$0"; exit 1 ;;
  esac
done

SDK="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun --sdk macosx --find clang)"
CFLAGS=(-fobjc-arc -O2 -Wall -Wno-unused-parameter -mmacosx-version-min=12.0 -isysroot "$SDK")

# Build outside the project: synced folders (iCloud Documents) attach extended
# attributes to everything, and codesign refuses bundles that carry them.
OUT="$(mktemp -d -t photoorganizer)"
trap 'rm -rf "$OUT"' EXIT
APP="$OUT/$NAME.app"

if [ "$TEST" = 1 ]; then
  echo "Running the core tests..."
  # The non-UI core only: it needs no window server.
  CORE=()
  for part in POPhotoItem POScanner POPlan POOrganizer POStrings POSimilarCopies POVKAlbum POManualDates \
              PODateSuggestions POPictureText POScreenshots POMediaTypes; do
    CORE+=("$ROOT/Sources/$part.m")
  done
  "$CLANG" "${CFLAGS[@]}" -I"$ROOT/Sources" \
    -framework Foundation -framework ImageIO -framework CoreGraphics -framework CoreText \
    -framework UniformTypeIdentifiers -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework Vision \
    "${CORE[@]}" "$ROOT/Tests/CoreTests.m" -o "$OUT/core-tests"
  "$OUT/core-tests"
fi

echo "Building Photo Organizer $VERSION..."
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
"$CLANG" "${CFLAGS[@]}" -arch arm64 -arch x86_64 \
  -framework Cocoa -framework Quartz -framework QuickLookThumbnailing -framework UniformTypeIdentifiers \
  -framework ImageIO -framework AVFoundation -framework AVKit -framework CoreMedia -framework Vision \
  -framework CoreML -framework Accelerate -framework WebKit -framework MapKit -framework CoreLocation \
  "$ROOT"/Sources/*.m -o "$APP/Contents/MacOS/$NAME"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER:-$VERSION}" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$ROOT/Resources/AppIcon.icns" "$ROOT/Resources/vit_mlx.py" "$APP/Contents/Resources/"
cp -R "$ROOT"/Resources/*.lproj "$APP/Contents/Resources/"
# Files copied out of iCloud Drive keep its attributes, which codesign refuses.
xattr -cr "$APP"

# Ad-hoc signature: required on Apple Silicon, and keeps the bundle intact in a zip.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1
codesign --verify --strict "$APP"

if [ "$ZIP" = 1 ]; then
  mkdir -p "$ROOT/dist"
  ZIPFILE="$ROOT/dist/$NAME-macOS-v$VERSION.zip"
  rm -f "$ZIPFILE"
  ditto -c -k --norsrc --keepParent "$APP" "$ZIPFILE"
  echo "Release zip: $ZIPFILE"
fi

# Quit a running copy first; if it refuses (a move in progress), leave the installed version alone.
WAS_RUNNING=0
if pgrep -f "$DEST/$NAME.app/Contents/MacOS/" >/dev/null 2>&1; then
  WAS_RUNNING=1
  echo "Quitting the running Photo Organizer..."
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do
    pgrep -f "$DEST/$NAME.app/Contents/MacOS/" >/dev/null 2>&1 || break
    sleep 0.2
  done
  if pgrep -f "$DEST/$NAME.app/Contents/MacOS/" >/dev/null 2>&1; then
    echo "Photo Organizer is still running. Quit it and run the build again." >&2
    exit 1
  fi
fi

mkdir -p "$DEST"
rm -rf "$DEST/$NAME.app"
ditto "$APP" "$DEST/$NAME.app"
echo "Installed: $DEST/$NAME.app"

[ "$WAS_RUNNING" = 1 ] && open "$DEST/$NAME.app"
exit 0
