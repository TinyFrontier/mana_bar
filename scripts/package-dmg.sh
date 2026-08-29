#!/usr/bin/env bash
#
# Build, sign, and package Mana as a distributable .dmg (ТЗ §2: distribution
# outside the Mac App Store via a signed + notarized .dmg).
#
# Usage:
#   scripts/package-dmg.sh
#
# Env overrides:
#   MANA_SIGN_IDENTITY   Explicit codesign identity (name or SHA-1 hash).
#                         Skips the automatic identity lookup below.
#   MANA_NOTARY_PROFILE  Name of a `xcrun notarytool store-credentials`
#                         keychain profile. When set, the .dmg is submitted
#                         for notarization and stapled. When unset,
#                         notarization is skipped (not an error).
#
# Identity selection order (when MANA_SIGN_IDENTITY is not set):
#   1. First "Developer ID Application" identity in the keychain
#      (real distribution certificate — required for a .dmg that runs
#      cleanly on machines other than this one).
#   2. First "Apple Development" identity in the keychain (only good for
#      running the build on *this* machine; Gatekeeper will refuse it
#      elsewhere).
#   3. Ad-hoc ("-") as a last resort — unsigned-for-all-practical-purposes,
#      Gatekeeper will refuse it everywhere, including this machine, unless
#      quarantine is stripped or the user right-click → Opens it.
#
# codesign --force --deep is deliberately NOT used (it's a footgun that
# masks nested-code signing problems); the app has no embedded frameworks
# or plugins, so a single, explicit codesign of the .app bundle is correct.

set -euo pipefail

# --- Paths -------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PROJECT="Mana.xcodeproj"
SCHEME="Mana"
APP_NAME="Mana"
CONFIGURATION="Release"
ENTITLEMENTS="$ROOT_DIR/Mana.entitlements"

DIST_DIR="$ROOT_DIR/dist"
WORK_DIR="$DIST_DIR/work"
BUILD_DIR="$WORK_DIR/build"
STAGING_DIR="$WORK_DIR/dmg-staging"
LOG_FILE="$WORK_DIR/package-dmg.log"

mkdir -p "$DIST_DIR" "$WORK_DIR"
: > "$LOG_FILE"
# Mirror everything (stdout+stderr) to a log file as well as the console.
exec > >(tee -a "$LOG_FILE") 2>&1

section() {
  echo
  echo "=== $1 ==="
}

# --- 1. Generate project + build -------------------------------------

section "xcodegen generate"
cd "$ROOT_DIR"
xcodegen generate

section "xcodebuild ($CONFIGURATION)"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS' \
  CONFIGURATION_BUILD_DIR="$BUILD_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  build

APP_PATH="$BUILD_DIR/$APP_NAME.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "error: build did not produce $APP_PATH" >&2
  exit 1
fi

# --- 2. Resolve signing identity ---------------------------------------

section "Resolve signing identity"

resolve_identity() {
  if [[ -n "${MANA_SIGN_IDENTITY:-}" ]]; then
    echo "$MANA_SIGN_IDENTITY"
    return
  fi

  local ids dev_id apple_dev
  ids="$(security find-identity -v -p codesigning 2>/dev/null || true)"

  dev_id="$(printf '%s\n' "$ids" | grep -o '"Developer ID Application[^"]*"' | head -n1 | tr -d '"' || true)"
  if [[ -n "$dev_id" ]]; then
    echo "$dev_id"
    return
  fi

  apple_dev="$(printf '%s\n' "$ids" | grep -o '"Apple Development[^"]*"' | head -n1 | tr -d '"' || true)"
  if [[ -n "$apple_dev" ]]; then
    echo "$apple_dev"
    return
  fi

  echo "-"
}

IDENTITY="$(resolve_identity)"

IDENTITY_KIND="ad-hoc"
if [[ "$IDENTITY" != "-" ]]; then
  case "$IDENTITY" in
    "Developer ID Application"*) IDENTITY_KIND="developer-id" ;;
    "Apple Development"*)        IDENTITY_KIND="apple-development" ;;
    *)                            IDENTITY_KIND="custom" ;;
  esac
fi

echo "identity: $IDENTITY"
echo "identity kind: $IDENTITY_KIND"

# --- 3. Sign the .app ----------------------------------------------------

section "Sign $APP_NAME.app"

if [[ "$IDENTITY" == "-" ]]; then
  # Ad-hoc: no hardened runtime (meaningless without a real cert — it just
  # gets in the way of local iteration) and no timestamp (nothing trusted
  # to timestamp).
  codesign --force \
    --sign "-" \
    --entitlements "$ENTITLEMENTS" \
    "$APP_PATH"
else
  codesign --force \
    --options runtime \
    --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$IDENTITY" \
    "$APP_PATH"
fi

section "Verify $APP_NAME.app signature"
codesign --verify --strict --verbose=2 "$APP_PATH"
codesign -dv --verbose=4 "$APP_PATH"

# --- 4. Resolve version --------------------------------------------------

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")"
echo "version: $VERSION"

DMG_NAME="Mana-$VERSION.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"

# --- 5. Build the .dmg ----------------------------------------------------

section "Stage .dmg contents"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

section "hdiutil create"
rm -f "$DMG_PATH"
hdiutil create \
  -volname "Mana" \
  -srcfolder "$STAGING_DIR" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG_PATH"

DMG_SIGNED="no"
if [[ "$IDENTITY" != "-" ]]; then
  section "Sign .dmg"
  codesign --force --timestamp --sign "$IDENTITY" "$DMG_PATH"
  DMG_SIGNED="yes"
  codesign -dv --verbose=4 "$DMG_PATH"
else
  echo
  echo "Skipping .dmg signing: ad-hoc identity only signs the .app, not the disk image."
fi

section "Checksum"
(
  cd "$DIST_DIR"
  shasum -a 256 "$DMG_NAME" | tee "$DMG_NAME.sha256"
)

# --- 6. Notarization (optional) ------------------------------------------

NOTARIZED="no"
if [[ -n "${MANA_NOTARY_PROFILE:-}" ]]; then
  section "Notarize .dmg"
  xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$MANA_NOTARY_PROFILE" \
    --wait
  section "Staple .dmg"
  xcrun stapler staple "$DMG_PATH"
  NOTARIZED="yes"
else
  section "Notarization skipped"
  cat <<'EOF'
MANA_NOTARY_PROFILE is not set, so notarization was skipped (this is not an
error — a locally-run/signed .dmg is still useful during development).

To enable it:
  1. Get a paid Apple Developer Program membership and a "Developer ID
     Application" certificate (System Settings won't grant one on a free
     account; MANA_SIGN_IDENTITY also needs this cert to produce a .dmg
     Gatekeeper accepts on other machines).
  2. Create an app-specific password at appleid.apple.com, then store
     notarytool credentials once:
       xcrun notarytool store-credentials "mana-notary" \
         --apple-id "<your Apple ID email>" \
         --team-id "<TEAMID>" \
         --password "<app-specific password>"
  3. Re-run this script with:
       MANA_NOTARY_PROFILE=mana-notary scripts/package-dmg.sh
EOF
fi

# --- 7. Gatekeeper verdict -------------------------------------------------

section "Gatekeeper assessment (spctl)"
set +e
SPCTL_OUTPUT="$(spctl -a -t open --context context:primary-signature -v "$DMG_PATH" 2>&1)"
SPCTL_STATUS=$?
set -e
echo "$SPCTL_OUTPUT"

# --- 8. Summary -------------------------------------------------------------

section "Summary"
DMG_SIZE="$(du -h "$DMG_PATH" | cut -f1)"
SHA256="$(shasum -a 256 "$DMG_PATH" | cut -d' ' -f1)"

echo "dmg path:        $DMG_PATH"
echo "dmg size:        $DMG_SIZE"
echo "sha256:          $SHA256"
echo "signed with:     $IDENTITY ($IDENTITY_KIND)"
echo "dmg signed:      $DMG_SIGNED"
echo "notarized:       $NOTARIZED"
if [[ $SPCTL_STATUS -eq 0 ]]; then
  echo "gatekeeper:      accepted"
else
  echo "gatekeeper:      REJECTED (exit $SPCTL_STATUS)"
fi

if [[ "$IDENTITY_KIND" == "apple-development" ]]; then
  echo
  echo "WARNING: signed with an 'Apple Development' identity, not 'Developer"
  echo "ID Application'. The spctl check above simulates Gatekeeper's"
  echo "as-if-downloaded assessment and REJECTS Apple Development / ad-hoc"
  echo "signatures on every machine, this one included — that path is only"
  echo "cleared by a real 'Developer ID Application' cert + notarization."
  echo "In practice this .dmg still runs fine on THIS machine as long as it"
  echo "never picks up the com.apple.quarantine xattr (e.g. copied locally,"
  echo "not downloaded via a browser) — macOS only runs the Gatekeeper check"
  echo "on quarantined files. On another machine, or once quarantined here,"
  echo "opening it needs right-click -> Open (still Apple-Development-signed,"
  echo "so it must additionally be a trusted user on that Mac) or"
  echo "'xattr -d com.apple.quarantine'."
elif [[ "$IDENTITY_KIND" == "ad-hoc" ]]; then
  echo
  echo "WARNING: ad-hoc signature ('-'). Same as above but stricter — nothing"
  echo "about the signer is verifiable at all, so once quarantined this needs"
  echo "right-click -> Open or 'xattr -d com.apple.quarantine' on every"
  echo "machine, including this one."
fi
