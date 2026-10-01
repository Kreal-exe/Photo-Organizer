#!/bin/bash
# Builds Photo Organizer with the Xcode Command Line Tools — no Xcode project needed.
#
#   ./build.sh            build ~/Desktop/PhotoOrganizer.app (Apple Silicon + Intel)
#   ./build.sh run        build and open it
#   ./build.sh test       build and run the core tests
#   ./build.sh icon       redraw Resources/AppIcon.icns
#   ./build.sh strings    list interface strings that have no English translation yet
#   ./build.sh zip        build and pack build/PhotoOrganizer-$VERSION.zip for a release
#   ./build.sh clean      delete build/

set -euo pipefail
cd "$(dirname "$0")"

APP="$HOME/Desktop/PhotoOrganizer.app"
EXECUTABLE="PhotoOrganizer"
CFLAGS=(-fobjc-arc -O2 -Wall -Wno-unused-parameter -mmacosx-version-min=12.0)
FRAMEWORKS=(Cocoa Quartz QuickLookThumbnailing UniformTypeIdentifiers ImageIO AVFoundation AVKit CoreMedia
            Vision CoreML Accelerate WebKit MapKit CoreLocation)
# The parts the tests exercise, which need no window server.
CORE=(POPhotoItem POScanner POPlan POOrganizer POStrings POSimilarCopies POVKAlbum POManualDates PODateSuggestions)

framework_flags() {
    for framework in "$@"; do printf -- '-framework\n%s\n' "$framework"; done
}

build() {
    # Assembled and signed outside the project: in a folder synced by iCloud Drive the system keeps adding
    # extended attributes to files, and codesign refuses to sign over them.
    local stage="${TMPDIR:-/tmp}/photo-organizer-build/PhotoOrganizer.app"
    rm -rf "$stage"
    mkdir -p "$stage/Contents/MacOS" "$stage/Contents/Resources"

    echo "Compiling…"
    local flags=()
    while IFS= read -r line; do flags+=("$line"); done < <(framework_flags "${FRAMEWORKS[@]}")
    clang "${CFLAGS[@]}" -arch arm64 -arch x86_64 "${flags[@]}" Sources/*.m -o "$stage/Contents/MacOS/$EXECUTABLE"

    cp Resources/Info.plist "$stage/Contents/Info.plist"
    # VERSION=1.2.0 ./build.sh stamps the version (the release workflow passes the tag); otherwise Info.plist's.
    if [ -n "${VERSION:-}" ]; then
        /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$stage/Contents/Info.plist"
        /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER:-${VERSION}}" "$stage/Contents/Info.plist"
    fi
    printf 'APPL????' > "$stage/Contents/PkgInfo"
    cp Resources/AppIcon.icns Resources/vit_mlx.py "$stage/Contents/Resources/"
    cp -R Resources/*.lproj "$stage/Contents/Resources/"
    codesign --force --sign - "$stage" 2>/dev/null

    rm -rf "$APP"
    mkdir -p build
    ditto "$stage" "$APP"
    rm -rf "$(dirname "$stage")"
    echo "Built $APP"
}

run_tests() {
    mkdir -p build
    local sources=()
    for name in "${CORE[@]}"; do sources+=("Sources/$name.m"); done
    local flags=()
    while IFS= read -r line; do flags+=("$line"); done < <(framework_flags Foundation ImageIO CoreGraphics UniformTypeIdentifiers \
                                                                           AVFoundation CoreMedia CoreVideo)
    clang "${CFLAGS[@]}" -ISources "${flags[@]}" "${sources[@]}" Tests/CoreTests.m -o build/core-tests
    build/core-tests
}

make_icon() {
    local work="build/icon"
    rm -rf "$work"
    mkdir -p "$work/AppIcon.iconset"
    clang -fobjc-arc -framework Cocoa Tools/make_icon.m -o "$work/make-icon"
    "$work/make-icon" "$work/icon-1024.png"
    for size in 16 32 128 256 512; do
        sips -z $size $size "$work/icon-1024.png" --out "$work/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
        sips -z $((size * 2)) $((size * 2)) "$work/icon-1024.png" --out "$work/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$work/AppIcon.iconset" -o Resources/AppIcon.icns
    rm -rf "$work"
    echo "Updated Resources/AppIcon.icns"
}

untranslated() {
    python3 Tools/localize.py keys | python3 -c '
import json, subprocess, sys
table = json.loads(subprocess.run(["plutil", "-convert", "json", "-o", "-", "Resources/en.lproj/Localizable.strings"],
                                  capture_output=True, text=True, check=True).stdout)
missing = [line for line in sys.stdin if json.loads(line) not in table]
print("".join(missing).rstrip("\n") if missing else "Every string has an English translation.")'
}

case "${1:-build}" in
    build)   build ;;
    run)     build && open "$APP" ;;
    test)    run_tests ;;
    icon)    make_icon ;;
    strings) untranslated ;;
    zip)     build && ditto -c -k --keepParent "$APP" "build/PhotoOrganizer-${VERSION:-dev}.zip" && echo "Packed build/PhotoOrganizer-${VERSION:-dev}.zip" ;;
    clean)   rm -rf build && echo "Removed build/" ;;
    *)       sed -n '2,11p' "$0"; exit 1 ;;
esac
