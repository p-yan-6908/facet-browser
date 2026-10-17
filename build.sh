#!/bin/bash
# Build Facet into a runnable .app bundle. No dependencies, no package manager.
set -euo pipefail
cd "$(dirname "$0")"

APP="Facet.app"
NAME="Facet"
BUNDLE_ID="com.facet.browser"
VERSION="${FACET_VERSION:-1.0.0}"
BUILD_NUMBER="${FACET_BUILD_NUMBER:-$VERSION}"
ARCHS="${FACET_ARCHS:-arm64}"
SIGN_IDENTITY="${FACET_SIGN_IDENTITY:--}"
DEST="${1:-.}"

echo "==> Compiling ($(ls Sources/*.swift | wc -l | tr -d ' ') files) for $ARCHS"
rm -rf "$APP"
mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources"

bins=()
for arch in $ARCHS; do
  out="build/$NAME-$arch"
  swiftc \
    -O -whole-module-optimization -swift-version 5 \
    -target "$arch-apple-macos13.0" \
    -framework AppKit -framework WebKit -framework Security -lsqlite3 \
    -o "$out" \
    Sources/*.swift
  bins+=("$out")
done
if [ "${#bins[@]}" -eq 1 ]; then
  cp "${bins[0]}" "$APP/Contents/MacOS/$NAME"
else
  lipo -create "${bins[@]}" -output "$APP/Contents/MacOS/$NAME"
fi

cp Resources/blocked-domains.txt "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAppleScriptEnabled</key><false/>
  <key>NSCameraUsageDescription</key><string>Websites you allow can use the camera.</string>
  <key>NSMicrophoneUsageDescription</key><string>Websites you allow can use the microphone.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>Websites you allow can use your location.</string>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>Web site URL</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>CFBundleURLSchemes</key>
      <array><string>http</string><string>https</string></array>
    </dict>
    <dict>
      <key>CFBundleURLName</key><string>Facet OAuth Callback</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>CFBundleURLSchemes</key>
      <array><string>facet</string></array>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>HTML Document</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key>
      <array><string>public.html</string><string>public.xhtml</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Build the app icon from the checked-in facet.png artwork, reusing the last one when
# neither the artwork nor the tool has changed.
if [ ! build/AppIcon.icns -nt facet.png ] || [ ! build/AppIcon.icns -nt tools/make_icon.swift ]; then
  swiftc -O -swift-version 5 -o build/make_icon tools/make_icon.swift
  build/make_icon facet.png build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --sign - "$APP"
  echo "==> Ad-hoc signed"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
  echo "==> Developer ID signed with hardened runtime"
fi
codesign --verify --strict --verbose=2 "$APP"
touch "$APP"

if [ "$DEST" != "." ]; then
  rm -rf "$DEST/$APP"
  cp -R "$APP" "$DEST/"
  echo "==> Installed to $DEST/$APP"
fi
SIZE=$(du -sh "$APP" | cut -f1)
echo "==> Built $APP ($SIZE)"
