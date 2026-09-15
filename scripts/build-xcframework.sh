#!/usr/bin/env bash
# Builds build/SwiftOSLogger.xcframework (static frameworks) plus a zip and its SwiftPM checksum.
#
# Usage: scripts/build-xcframework.sh [platform ...]
# Platforms: ios ios-simulator maccatalyst macos tvos tvos-simulator watchos watchos-simulator visionos visionos-simulator
# With no arguments every platform is attempted; platforms whose SDK is not installed are skipped.
set -euo pipefail

MODULE="SwiftOSLogger"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
OUTPUT="$BUILD/$MODULE.xcframework"
ALL_PLATFORMS=(ios ios-simulator maccatalyst macos tvos tvos-simulator watchos watchos-simulator visionos visionos-simulator)
if [ "$#" -gt 0 ]; then PLATFORMS=("$@"); else PLATFORMS=("${ALL_PLATFORMS[@]}"); fi

VERSION="$(sed -n 's/.*static let current = "\(.*\)".*/\1/p' "$ROOT/Sources/$MODULE/Support/Version.swift")"

destination_for() {
  case "$1" in
    ios) echo "generic/platform=iOS" ;;
    ios-simulator) echo "generic/platform=iOS Simulator" ;;
    maccatalyst) echo "generic/platform=macOS,variant=Mac Catalyst" ;;
    macos) echo "generic/platform=macOS" ;;
    tvos) echo "generic/platform=tvOS" ;;
    tvos-simulator) echo "generic/platform=tvOS Simulator" ;;
    watchos) echo "generic/platform=watchOS" ;;
    watchos-simulator) echo "generic/platform=watchOS Simulator" ;;
    visionos) echo "generic/platform=visionOS" ;;
    visionos-simulator) echo "generic/platform=visionOS Simulator" ;;
    *) echo "Unknown platform '$1'. Valid: ${ALL_PLATFORMS[*]}" >&2; exit 2 ;;
  esac
}

write_info_plist() {
  cat > "$1" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$MODULE</string>
  <key>CFBundleIdentifier</key><string>com.swiftoslogger.$MODULE</string>
  <key>CFBundleName</key><string>$MODULE</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
</dict>
</plist>
PLIST
}

# Assembles a static <MODULE>.framework from an archived object file and module interfaces.
make_framework() {
  local platform="$1" object="$2" swiftmodule="$3" framework="$4"
  rm -rf "$framework"
  local contents="$framework"
  if [ "$platform" = "macos" ] || [ "$platform" = "maccatalyst" ]; then
    contents="$framework/Versions/A"
    mkdir -p "$contents/Resources"
    write_info_plist "$contents/Resources/Info.plist"
  else
    mkdir -p "$contents"
    write_info_plist "$contents/Info.plist"
  fi
  mkdir -p "$contents/Modules"
  libtool -static -o "$contents/$MODULE" "$object"
  cp -R "$swiftmodule" "$contents/Modules/"
  # Ship only textual interfaces so any compiler version can import the module.
  find "$contents/Modules" \( -name "*.swiftmodule" -type f -o -name "Project" -type d \) -prune -exec rm -rf {} +
  if [ "$contents" != "$framework" ]; then
    ln -s A "$framework/Versions/Current"
    ln -s "Versions/Current/$MODULE" "$framework/$MODULE"
    ln -s Versions/Current/Modules "$framework/Modules"
    ln -s Versions/Current/Resources "$framework/Resources"
  fi
}

rm -rf "$BUILD/archives" "$BUILD/frameworks" "$BUILD/logs" "$OUTPUT" "$OUTPUT.zip"
mkdir -p "$BUILD/archives" "$BUILD/frameworks" "$BUILD/logs"

FRAMEWORK_ARGS=()
cd "$ROOT"
for platform in "${PLATFORMS[@]}"; do
  destination="$(destination_for "$platform")"
  archive="$BUILD/archives/$platform.xcarchive"
  derived="$BUILD/DerivedData/$platform"
  log="$BUILD/logs/$platform.log"
  echo "==> Archiving $platform"
  if ! xcodebuild archive \
      -scheme "$MODULE" \
      -destination "$destination" \
      -archivePath "$archive" \
      -derivedDataPath "$derived" \
      SKIP_INSTALL=NO \
      BUILD_LIBRARY_FOR_DISTRIBUTION=YES > "$log" 2>&1; then
    if grep -qE "is not installed|Unable to find a destination" "$log"; then
      echo "warning: skipping $platform (SDK/platform not installed, see $log)"
      continue
    fi
    echo "error: archive failed for $platform, see $log" >&2
    tail -n 30 "$log" >&2
    exit 1
  fi

  object="$(find "$archive/Products" -name "$MODULE.o" | head -n 1)"
  swiftmodule="$(find "$derived/Build/Intermediates.noindex/ArchiveIntermediates" -type d -name "$MODULE.swiftmodule" -path "*BuildProductsPath*" | head -n 1)"
  if [ -z "$object" ] || [ -z "$swiftmodule" ]; then
    echo "error: could not find $MODULE.o or $MODULE.swiftmodule for $platform" >&2
    exit 1
  fi

  framework="$BUILD/frameworks/$platform/$MODULE.framework"
  make_framework "$platform" "$object" "$swiftmodule" "$framework"
  FRAMEWORK_ARGS+=(-framework "$framework")
done

if [ "${#FRAMEWORK_ARGS[@]}" -eq 0 ]; then
  echo "error: no platform could be built" >&2
  exit 1
fi

echo "==> Creating $OUTPUT"
xcodebuild -create-xcframework "${FRAMEWORK_ARGS[@]}" -output "$OUTPUT"

(cd "$BUILD" && ditto -c -k --sequesterRsrc --keepParent "$MODULE.xcframework" "$MODULE.xcframework.zip")
echo "==> $OUTPUT.zip"
echo "checksum: $(swift package compute-checksum "$OUTPUT.zip")"
