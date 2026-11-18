#!/bin/bash
# Build Pixlok without Xcode (Command Line Tools only).
#   ./build.sh            debug build  -> build/Pixlok.app
#   ./build.sh release    optimized universal (arm64 + x86_64) build
#   ./build.sh dist       release build, ad-hoc signed and zipped -> build/dist/Pixlok-<version>.zip
#   ./build.sh typecheck  type-check all sources only (fast feedback)
#   ./build.sh run [file] build debug, then open the app (optionally with a file)
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-debug}"
APP_NAME="Pixlok"
EXE="Pixlok"
BUILD="build"
APP="$BUILD/$APP_NAME.app"
TARGET="arm64-apple-macos14.0"
mkdir -p "$BUILD/ModuleCache"

SOURCES=()
while IFS= read -r -d '' f; do SOURCES+=("$f"); done < <(find Sources -name '*.swift' -print0 | sort -z)

# Workaround: some Command Line Tools installs ship both module.modulemap and
# bridging.modulemap defining `SwiftBridging`, which breaks every `import AppKit`
# ("redefinition of module 'SwiftBridging'"). Hide the duplicate via a VFS overlay.
FLAGS=(-swift-version 5 -module-name "$EXE" -module-cache-path "$BUILD/ModuleCache")
CLT_SWIFT_INC="$(dirname "$(dirname "$(xcrun --find swiftc)")")/include/swift"
if [ -f "$CLT_SWIFT_INC/bridging.modulemap" ] && [ -f "$CLT_SWIFT_INC/module.modulemap" ] \
   && grep -q 'module SwiftBridging' "$CLT_SWIFT_INC/bridging.modulemap" \
   && grep -q 'module SwiftBridging' "$CLT_SWIFT_INC/module.modulemap"; then
  : > "$BUILD/empty.modulemap"
  cat > "$BUILD/vfs-overlay.yaml" <<YAML
{ "version": 0, "case-sensitive": "false", "roots": [ { "type": "directory", "name": "$CLT_SWIFT_INC",
  "contents": [ { "type": "file", "name": "bridging.modulemap", "external-contents": "$PWD/$BUILD/empty.modulemap" } ] } ] }
YAML
  FLAGS+=(-vfsoverlay "$BUILD/vfs-overlay.yaml" -Xcc -ivfsoverlay -Xcc "$BUILD/vfs-overlay.yaml")
fi

case "$MODE" in
  typecheck)
    exec xcrun swiftc -typecheck "${FLAGS[@]}" -target "$TARGET" "${SOURCES[@]}" ;;
  release|dist) OPT=(-O -whole-module-optimization) ;;
  debug|run) OPT=(-Onone -g) ;;
  *) echo "unknown mode: $MODE" >&2; exit 2 ;;
esac

if [ "$MODE" = release ] || [ "$MODE" = dist ]; then
  # Universal binary: Apple silicon + Intel (macOS 14 still runs on Intel Macs).
  for ARCH in arm64 x86_64; do
    xcrun swiftc "${FLAGS[@]}" -target "$ARCH-apple-macos14.0" "${OPT[@]}" -o "$BUILD/$EXE-$ARCH" "${SOURCES[@]}"
  done
  xcrun lipo -create -output "$BUILD/$EXE" "$BUILD/$EXE-arm64" "$BUILD/$EXE-x86_64"
else
  xcrun swiftc "${FLAGS[@]}" -target "$TARGET" "${OPT[@]}" -o "$BUILD/$EXE" "${SOURCES[@]}"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/$EXE" "$APP/Contents/MacOS/$EXE"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "warning: ad-hoc codesign failed" >&2

if [ "$MODE" = dist ]; then
  # Ad-hoc deep signature (no Developer ID), verified before packaging.
  codesign --force --deep --sign - "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
  DIST="$BUILD/dist"
  ZIP="$DIST/$APP_NAME-$VERSION.zip"
  mkdir -p "$DIST"
  rm -f "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
  echo "Zip:    $ZIP"
  echo "SHA256: $(shasum -a 256 "$ZIP" | awk '{print $1}')"
  exit 0
fi

# Register with Launch Services so Finder's "Open With" sees it.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
echo "Built: $APP"

if [ "$MODE" = run ]; then
  shift || true
  if [ $# -gt 0 ]; then open -a "$PWD/$APP" "$@"; else open "$APP"; fi
fi
