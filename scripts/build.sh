#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
app="$PWD/build/Framecast Studio.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
swift scripts/make-icon.swift Resources/Framecast.iconset
iconutil -c icns Resources/Framecast.iconset -o "$app/Contents/Resources/Framecast.icns"
cp .build/release/VidystReconstructed "$app/Contents/MacOS/VidystReconstructed"
# SwiftPM resource bundles must accompany their package at runtime.
for resource_bundle in .build/release/*.bundle; do
  [ -d "$resource_bundle" ] || continue
  ditto "$resource_bundle" "$app/Contents/Resources/$(basename "$resource_bundle")"
done
cp Resources/ThirdPartyNotices.txt "$app/Contents/Resources/ThirdPartyNotices.txt"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>VidystReconstructed</string>
<key>CFBundleIdentifier</key><string>local.vidyst.reconstructed</string>
<key>CFBundleName</key><string>Framecast Studio</string>
<key>CFBundleDisplayName</key><string>Framecast Studio</string>
<key>CFBundleShortVersionString</key><string>2.0.0</string>
<key>CFBundleVersion</key><string>200</string>
<key>CFBundleIconFile</key><string>Framecast</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.2</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSCameraUsageDescription</key><string>Show your camera in your studio scenes.</string>
<key>NSMicrophoneUsageDescription</key><string>Read microphone levels and include your voice in recordings and streams.</string>
<key>NSScreenCaptureUsageDescription</key><string>Share a display, window or application in your studio, with optional captured audio.</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
# Keep the signer and designated requirement stable between personal builds.
# Apple Developer ID may be supplied for distribution; local signing never changes trust stores.
signing_identity="${FRAMECAST_SIGN_IDENTITY:-}"
if [ -z "$signing_identity" ]; then
  if security find-identity -p codesigning | grep -Fq '"Framecast Studio Local Signing"'; then
    signing_identity='Framecast Studio Local Signing'
  else
    signing_identity='-'
    printf 'Using ad-hoc development signing; permission grants may reset after rebuilds.\n'
  fi
fi
codesign --force --sign "$signing_identity" "$app"
printf 'Built: %s\n' "$app"
if [ "${1:-}" = "--install" ]; then
  install_target="/Applications/Framecast Studio.app"
  rm -rf "$install_target"
  ditto "$app" "$install_target"
  touch "$install_target"
  printf 'Installed to: %s\n' "$install_target"
fi
