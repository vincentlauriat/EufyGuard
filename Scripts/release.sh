#!/usr/bin/env bash
# Build a Release EufyGuard.app, Developer ID sign with Hardened Runtime,
# notarize via Apple, staple the ticket, and package it as a distributable .dmg.
#
# ┌──────────────────────────────────────────────────────────────────────────┐
# │ SPARKLE SIGNING KEY — DO NOT REGENERATE                                    │
# │                                                                            │
# │ Updates are EdDSA-signed with the private key in the login keychain under  │
# │ account "EufyGuard" (used by sign_update below). Its public half is        │
# │ embedded in the app as SUPublicEDKey in app/project.yml:                   │
# │     xV1M6deOtWGENHNEH/GMIbaFmSFM9cJhNOeN9jV1JNE=                           │
# │                                                                            │
# │ NEVER run `generate_keys` again or import a new key into this account, and │
# │ NEVER change SUPublicEDKey. Doing so makes every already-installed app     │
# │ reject all future auto-updates. Back this key up somewhere safe:           │
# │   .sparkle-tools/bin/generate_keys -x backup.txt --account EufyGuard       │
# └──────────────────────────────────────────────────────────────────────────┘
#
# Usage: ./Scripts/release.sh <version>
#   e.g. ./Scripts/release.sh 1.0.0
#
# Prerequisites (one-time setup, shared across all projects):
#   - "Developer ID Application: Vincent LAURIAT (KFLACS69T9)" certificate in
#     the login keychain.
#   - notarytool credentials stored under the keychain profile
#     "AppliMacVincentGithub".
#
# Outputs release/EufyGuard-<version>.dmg, fully notarized, and appcast.xml at
# the repo root. Release notes live in release/release-notes-<version>.md.
# Does NOT push to GitHub — prints the suggested `gh release create` command.

set -euo pipefail

VERSION="${1:?Usage: ./Scripts/release.sh <version>  (e.g. ./Scripts/release.sh 1.0.0)}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/app"
cd "$APP_DIR"

# 1. Sanity check: project.yml must declare the same MARKETING_VERSION
if ! grep -q "MARKETING_VERSION: \"$VERSION\"" project.yml; then
  echo "✗ MARKETING_VERSION in app/project.yml does not match $VERSION" >&2
  grep "MARKETING_VERSION" project.yml | sed 's/^/    /' >&2
  echo "  Bump app/project.yml first, then re-run." >&2
  exit 1
fi

# 2. Regenerate xcodeproj
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "✗ XcodeGen not installed. brew install xcodegen" >&2
  exit 1
fi
echo "→ xcodegen generate"
xcodegen generate >/dev/null

# 3. Build Release
# CODE_SIGNING_ALLOWED=NO works around the macOS `com.apple.provenance` xattr
# that breaks ad-hoc codesign in CLI. We sign manually below after a clean
# xattr scrub.
echo "→ xcodebuild Release"
xcodebuild -project EufyGuard.xcodeproj \
  -scheme EufyGuard \
  -configuration Release \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tail -5

APP="$APP_DIR/build/Build/Products/Release/EufyGuard.app"
if [ ! -d "$APP" ]; then
  echo "✗ Build did not produce $APP" >&2
  exit 1
fi

# 4. Stage to a clean directory, Developer ID sign with Hardened Runtime.
# Direct in-place codesign fails because Xcode's post-build `lsregister`
# adds `com.apple.provenance` xattrs; `ditto --noextattr` copies without them.
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Vincent LAURIAT (KFLACS69T9)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-AppliMacVincentGithub}"

STAGING_DIR="$(mktemp -d)"
STAGING="$STAGING_DIR/EufyGuard.app"
echo "→ Staging to $STAGING_DIR"
ditto --norsrc --noextattr --noacl "$APP" "$STAGING"

# Apple's timestamp server is intermittently flaky — retry up to 5 times.
codesign_ts() {
  local target="$1"
  local attempt
  for attempt in 1 2 3 4 5; do
    if codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$target" 2>&1; then
      return 0
    fi
    if [ "$attempt" -lt 5 ]; then
      echo "  ↻ codesign failed (attempt $attempt/5), retrying in 5s…"
      sleep 5
    fi
  done
  echo "✗ codesign $target failed after 5 attempts" >&2
  return 1
}

echo "→ Codesigning Sparkle.framework nested binaries (deepest first)"
SPARKLE_FW="$STAGING/Contents/Frameworks/Sparkle.framework"
SPARKLE_VER="$SPARKLE_FW/Versions/B"
codesign_ts "$SPARKLE_VER/Autoupdate"
codesign_ts "$SPARKLE_VER/XPCServices/Downloader.xpc"
codesign_ts "$SPARKLE_VER/XPCServices/Installer.xpc"
codesign_ts "$SPARKLE_VER/Updater.app"
codesign_ts "$SPARKLE_FW"

echo "→ Codesigning the app itself with Developer ID + Hardened Runtime"
codesign_ts "$STAGING"
codesign --verify --strict --deep "$STAGING"

RELEASE_DIR="$ROOT/release"
mkdir -p "$RELEASE_DIR"
DMG="$RELEASE_DIR/EufyGuard-$VERSION.dmg"
rm -f "$DMG"

# 4b. Installer layout: signed .app on the left, /Applications alias on the
# right, background image with an arrow between them.
DMG_VOLNAME="EufyGuard $VERSION"
DMG_LAYOUT_DIR="$STAGING_DIR/dmg-layout"
mkdir -p "$DMG_LAYOUT_DIR/.background"
ditto --norsrc --noextattr --noacl "$STAGING" "$DMG_LAYOUT_DIR/EufyGuard.app"
ln -s /Applications "$DMG_LAYOUT_DIR/Applications"
"$ROOT/Scripts/make-dmg-background.swift" "$DMG_LAYOUT_DIR/.background/background.png" >/dev/null

echo "→ Creating writable DMG to configure Finder layout"
RW_DMG="$STAGING_DIR/temp.dmg"
hdiutil create -volname "$DMG_VOLNAME" -srcfolder "$DMG_LAYOUT_DIR" \
  -fs HFS+ -format UDRW -ov "$RW_DMG" >/dev/null

DMG_MOUNT=$(hdiutil attach -nobrowse -noverify -noautoopen "$RW_DMG" \
  | awk -F '\t' 'END {print $NF}')
echo "→ Mounted at $DMG_MOUNT — applying Finder layout via AppleScript"

osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$DMG_VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 100, 740, 480}
        set view_options to the icon view options of container window
        set arrangement of view_options to not arranged
        set icon size of view_options to 128
        set background picture of view_options to file ".background:background.png"
        set position of item "EufyGuard.app" of container window to {140, 200}
        set position of item "Applications" of container window to {400, 200}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$DMG_MOUNT" -quiet

echo "→ Converting RW DMG to compressed read-only $DMG"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG" >/dev/null

rm -rf "$STAGING_DIR"

# 5. Notarize the DMG with Apple, then staple the ticket.
echo "→ Submitting $DMG to Apple notary service (this takes 2–5 min)"
xcrun notarytool submit "$DMG" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

echo "→ Stapling notarization ticket to the DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# 6. Sign the DMG with the Sparkle EdDSA key and generate / refresh
# `appcast.xml` so the in-app updater (Sparkle 2) can serve this version.
SPARKLE_VERSION="2.9.1"
SPARKLE_TOOLS="$ROOT/.sparkle-tools"
if [ ! -x "$SPARKLE_TOOLS/bin/sign_update" ]; then
  echo "→ Fetching Sparkle $SPARKLE_VERSION tools (one-time setup)"
  mkdir -p "$SPARKLE_TOOLS"
  curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
    | tar -xJ -C "$SPARKLE_TOOLS"
fi

echo "→ Signing $DMG with Sparkle EdDSA key"
# `sign_update` returns: sparkle:edSignature="..." length="<bytes>"
SPARKLE_SIG_LINE=$("$SPARKLE_TOOLS/bin/sign_update" --account "EufyGuard" "$DMG")

# Sparkle compares <sparkle:version> against the running app's CFBundleVersion
# (the build number), NOT the marketing version. Read the real value.
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")

echo "→ Writing $ROOT/appcast.xml (sparkle:version=$BUILD_NUMBER, shortVersionString=$VERSION)"
PUB_DATE=$(date -R)
cat > "$ROOT/appcast.xml" <<APPCAST
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>EufyGuard</title>
    <link>https://raw.githubusercontent.com/vincentlauriat/EufyGuard/main/appcast.xml</link>
    <description>EufyGuard release feed</description>
    <language>en</language>
    <item>
      <title>v$VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/vincentlauriat/EufyGuard/releases/tag/v$VERSION</sparkle:releaseNotesLink>
      <enclosure
        url="https://github.com/vincentlauriat/EufyGuard/releases/download/v$VERSION/EufyGuard-$VERSION.dmg"
        type="application/octet-stream"
        $SPARKLE_SIG_LINE />
    </item>
  </channel>
</rss>
APPCAST

DMG_SIZE=$(ls -lh "$DMG" | awk '{print $5}')
echo ""
echo "✅ Built, signed, notarized, stapled and Sparkle-signed: $DMG ($DMG_SIZE)"
echo "✅ appcast.xml written for v$VERSION"
echo ""
echo "Next steps to publish on GitHub:"
echo "  1. gh release create v$VERSION ./release/EufyGuard-$VERSION.dmg --title \"v$VERSION\" --notes-file release/release-notes-$VERSION.md"
echo "  2. git add appcast.xml && git commit -m 'docs: appcast for v$VERSION' && git push"
