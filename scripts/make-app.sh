#!/bin/zsh
# Bundles the swift-build output into Olaz.app
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
# Bundle id. Cookies, WebKit storage (the synced message DB), preferences and privacy permissions are keyed by it;
# LegacyMigration.swift brings the session over from the SwiftZalo builds' `dev.swiftzalo.app`.
BUNDLE_ID="app.olaz.mac"
# Marketing version and build number; scripts/release.sh sets them for a tagged release.
VERSION="${OLAZ_VERSION:-1.0}"
BUILD_NUMBER="${OLAZ_BUILD:-$VERSION}"
SDK_ARGS=()
if [[ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" ]]; then
    SDK_ARGS=(--sdk "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk")
fi
swift build --build-system native "${SDK_ARGS[@]}" -c "$CONFIG"
BIN=".build/${CONFIG}/Olaz"

# The fingerprint helper (Chromium's TLS/HTTP2 for all requests); its absence is survivable —
# Olaz falls back to URLSession — but releases always carry it.
scripts/build-fingerprint-helper.sh

APP="build/Olaz.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/Olaz"
if [[ -x FingerprintHelper/build/olaz-fingerprint-helper ]]; then
    cp FingerprintHelper/build/olaz-fingerprint-helper "$APP/Contents/MacOS/olaz-fingerprint-helper"
else
    echo "warning: fingerprint helper missing — the app will use URLSession" >&2
fi
cp Assets/olaz.icns "$APP/Contents/Resources/AppIcon.icns"

# SwiftPM resource bundle (JSModules/, Resources/) — found via ResourceLocator.
RES_BUNDLE=".build/${CONFIG}/Olaz_Olaz.bundle"
if [[ -d "$RES_BUNDLE" ]]; then
    cp -R "$RES_BUNDLE" "$APP/Contents/Resources/"
else
    echo "warning: $RES_BUNDLE missing — JS modules will not load" >&2
fi

cat > "$APP/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Olaz</string>
    <key>CFBundleDisplayName</key><string>Olaz</string>
    <key>CFBundleExecutable</key><string>Olaz</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.social-networking</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <!-- Calls: the native call helper (ZaloCall, from the Zalo runtime Olaz installs) is started by Olaz, so macOS attributes
         its microphone / camera access to Olaz and shows these texts in the permission prompts. -->
    <key>NSMicrophoneUsageDescription</key>
    <string>Olaz cần dùng micro để bạn nói chuyện trong cuộc gọi Zalo. / Olaz needs the microphone so people can hear you in Zalo calls.</string>
    <key>NSCameraUsageDescription</key>
    <string>Olaz cần dùng camera để người khác nhìn thấy bạn trong cuộc gọi video Zalo. / Olaz needs the camera so people can see you in Zalo video calls.</string>
</dict>
</plist>
PLIST

# Sign with the JIT entitlement so JavaScriptCore can JIT the JS modules.
# Signing identity: OLAZ_SIGN_IDENTITY, or auto-detect a local certificate (Apple Development, OlazDev),
# or fall back to ad-hoc signing (`-`).
SIGN_IDENTITY="${OLAZ_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -E 'Apple Development|OlazDev|LocalDev' | head -n1 | sed -E 's/.*"([^"]+)".*/\1/' || true)
fi

if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "Signing with identity: $SIGN_IDENTITY"
    SIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
    if [[ "$SIGN_IDENTITY" == *"Developer ID"* ]]; then
        SIGN_ARGS=(--force --timestamp --options runtime --sign "$SIGN_IDENTITY")
    fi
    if [[ -x "$APP/Contents/MacOS/olaz-fingerprint-helper" ]]; then
        codesign "${SIGN_ARGS[@]}" "$APP/Contents/MacOS/olaz-fingerprint-helper"
    fi
    codesign "${SIGN_ARGS[@]}" --entitlements scripts/Olaz.entitlements "$APP"
else
    if [[ -x "$APP/Contents/MacOS/olaz-fingerprint-helper" ]]; then
        codesign --force --sign - "$APP/Contents/MacOS/olaz-fingerprint-helper"
    fi
    codesign --force --sign - --entitlements scripts/Olaz.entitlements "$APP"
fi

echo "Bundled $APP"
echo "Launch with: open $APP"
