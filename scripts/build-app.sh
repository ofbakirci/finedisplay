#!/bin/zsh
# Builds FineDisplay.app + finedisplay CLI, signs them, and zips them into dist/.
#
#   scripts/build-app.sh                 # ad-hoc signed (local use)
#   SIGN_ID="Developer ID Application: Name (TEAMID)" scripts/build-app.sh
#   SIGN_ID=... NOTARY_PROFILE=finedisplay-notary scripts/build-app.sh   # also notarize + staple
#
# One-time setup for notarization:
#   xcrun notarytool store-credentials finedisplay-notary --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(grep -m1 'public static let version' Sources/FineDisplayKit/FineDisplayKit.swift | sed -E 's/.*"([^"]+)".*/\1/')"
BUNDLE_ID="co.nousworks.finedisplay"
APP_NAME="FineDisplay"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
SIGN_ID="${SIGN_ID:--}"           # "-" = ad-hoc
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
ARCHS="${ARCHS:---arch arm64 --arch x86_64}"

echo "▸ building $APP_NAME $VERSION (release, ${ARCHS})"
swift build -c release ${=ARCHS} --product FineDisplayApp
swift build -c release ${=ARCHS} --product finedisplay
BIN_DIR="$(swift build -c release ${=ARCHS} --show-bin-path)"

echo "▸ assembling bundle"
rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp "$BIN_DIR/FineDisplayApp" "$APP/Contents/MacOS/$APP_NAME"
cp "$BIN_DIR/finedisplay" "$APP/Contents/Resources/bin/finedisplay"
cp "$BIN_DIR/finedisplay" "$DIST/finedisplay"

# Icon
ICONSET="$DIST/AppIcon.iconset"
swift "$ROOT/scripts/make-icon.swift" "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 nousworks. MIT License.</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▸ signing with: $SIGN_ID"
if [[ "$SIGN_ID" == "-" ]]; then
  codesign --force --deep --sign - "$APP/Contents/Resources/bin/finedisplay"
  codesign --force --deep --sign - "$DIST/finedisplay"
  codesign --force --deep --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP/Contents/Resources/bin/finedisplay"
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$DIST/finedisplay"
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"

echo "▸ zipping"
ZIP="$DIST/FineDisplay-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
CLI_ZIP="$DIST/finedisplay-cli-$VERSION.zip"
ditto -c -k "$DIST/finedisplay" "$CLI_ZIP"

if [[ -n "$NOTARY_PROFILE" && "$SIGN_ID" != "-" ]]; then
  echo "▸ notarizing (profile $NOTARY_PROFILE)"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "▸ stapled + re-zipped"
fi

shasum -a 256 "$ZIP" "$CLI_ZIP" | tee "$DIST/SHA256SUMS"
echo "✓ done: $ZIP"
