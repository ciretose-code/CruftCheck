#!/bin/bash
# Scripts/release.sh — Test, archive, notarize, staple, package a DMG, and publish to GitHub.
#
# One-time credential setup (stored in the keychain, never repeated):
#   xcrun notarytool store-credentials "cruftcheck-notary" \
#     --key ~/.private_keys/AuthKey_<KEY_ID>.p8 \
#     --key-id <KEY_ID> \
#     --issuer <ISSUER_ID>
#
# You also need a "Developer ID Application" certificate in the login keychain. An
# "Apple Development" certificate is not enough — it can't be notarized, and Gatekeeper
# will refuse the result on any Mac but this one.
#
# Usage:
#   ./Scripts/release.sh              # bump the build number, keep the version
#   ./Scripts/release.sh 0.2          # set the version to 0.2 and bump the build
#   ./Scripts/release.sh --dry-run    # everything except notarize, publish, and push
#
# Env:
#   NOTARY_PROFILE=eyeballs-notary ./Scripts/release.sh   # reuse another project's creds
#
set -euo pipefail

# ── Config ─────────────────────────────────────────────────────────────────────
SCHEME="CruftCheck"
PROJECT="CruftCheck.xcodeproj"
PROJECT_YML="project.yml"
EXPORT_OPTIONS="build/ExportOptions.plist"   # generated; see "Export options" below
APP_NAME="CruftCheck"
NOTARY_PROFILE="${NOTARY_PROFILE:-cruftcheck-notary}"
RELEASE_BRANCH="main"

ARCHIVE_PATH="build/${SCHEME}.xcarchive"
EXPORT_PATH="build/export"
STAGING_DMG="build/staging.dmg"
MOUNT_DIR="/Volumes/${APP_NAME}-staging"

DRY_RUN=false
NEW_VERSION=""

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    -*) echo "error: unknown option ${arg}" >&2; exit 2 ;;
    *)  NEW_VERSION="$arg" ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }
step() { echo ""; echo "▶ $*"; }

# Any failure past the mount must not leave a volume attached, or the next run trips over
# its own leftovers before it reaches the cleanup that would have removed them.
cleanup() {
  if [ -d "$MOUNT_DIR" ]; then
    hdiutil detach "$MOUNT_DIR" -quiet -force 2>/dev/null || true
  fi
}
trap cleanup EXIT

cd "$(dirname "$0")/.."

# ── 1. Preflight ───────────────────────────────────────────────────────────────
# Everything below is checked before the first expensive step. Archiving takes minutes;
# discovering a missing certificate afterwards wastes all of them.
step "Preflight"

for tool in xcodegen gh xcrun hdiutil; do
  command -v "$tool" >/dev/null || die "${tool} is not installed"
done

BRANCH=$(git rev-parse --abbrev-ref HEAD)
[ "$BRANCH" = "$RELEASE_BRANCH" ] || die "on branch ${BRANCH}, expected ${RELEASE_BRANCH}"

[ -z "$(git status --porcelain)" ] || die "working tree is dirty — commit or stash first"

git fetch --quiet origin "$RELEASE_BRANCH"
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse "origin/${RELEASE_BRANCH}")
[ "$LOCAL" = "$REMOTE" ] || die "local ${RELEASE_BRANCH} differs from origin — pull or push first"

# A Developer ID Application certificate is the one prerequisite that cannot be worked
# around: Apple Development certificates are rejected by notarization.
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  die "no 'Developer ID Application' certificate in the keychain.
       Xcode › Settings › Accounts › Manage Certificates › + › Developer ID Application.
       Requires the Account Holder or an Admin on the team."
fi

# The team is read back out of the resolved build settings rather than written down here.
# Config/Signing.xcconfig ships with no team so a fresh clone can build and test; a release
# needs a real one, which comes from the gitignored Config/Signing.local.xcconfig.
TEAM_ID=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showBuildSettings 2>/dev/null \
  | awk '/[[:space:]]DEVELOPMENT_TEAM = /{print $3; exit}')
[ -n "${TEAM_ID:-}" ] || die "DEVELOPMENT_TEAM is empty.
       Releases need a real team. Create Config/Signing.local.xcconfig with:
         CODE_SIGN_STYLE = Automatic
         CODE_SIGN_IDENTITY = Apple Development
         DEVELOPMENT_TEAM = <YOUR_TEAM_ID>"

if [ "$DRY_RUN" = false ]; then
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || die \
    "no notary keychain profile named '${NOTARY_PROFILE}'.
       Create it with 'xcrun notarytool store-credentials', or reuse another project's
       with NOTARY_PROFILE=<name> $0"
fi

echo "  branch ${BRANCH}, tree clean, in sync with origin"
echo "  Developer ID certificate present, team ${TEAM_ID}"

# ── 2. Version ─────────────────────────────────────────────────────────────────
# project.yml is the source of truth, not project.pbxproj. agvtool writes to the pbxproj,
# which the next `xcodegen generate` overwrites — so the bump would silently disappear.
step "Version"

read_yml() { grep -E "^[[:space:]]*$1:" "$PROJECT_YML" | head -1 | sed -E 's/.*"([^"]*)".*/\1/'; }

VERSION=$(read_yml "MARKETING_VERSION")
BUILD=$(read_yml "CFBundleVersion")
[ -n "$VERSION" ] || die "could not read MARKETING_VERSION from ${PROJECT_YML}"
[ -n "$BUILD" ]   || die "could not read CFBundleVersion from ${PROJECT_YML}"

[ -n "$NEW_VERSION" ] && VERSION="$NEW_VERSION"
BUILD=$((BUILD + 1))
TAG="v${VERSION}.${BUILD}"

git rev-parse "$TAG" >/dev/null 2>&1 && die "tag ${TAG} already exists"

# Marketing version lives in two places that must not drift: the build setting and the
# generated Info.plist key.
sed -i '' -E "s/^([[:space:]]*MARKETING_VERSION: )\"[^\"]*\"/\1\"${VERSION}\"/" "$PROJECT_YML"
sed -i '' -E "s/^([[:space:]]*CFBundleShortVersionString: )\"[^\"]*\"/\1\"${VERSION}\"/" "$PROJECT_YML"
sed -i '' -E "s/^([[:space:]]*CFBundleVersion: )\"[^\"]*\"/\1\"${BUILD}\"/" "$PROJECT_YML"

xcodegen generate >/dev/null

# Trust the generated artefact rather than the edit that was meant to produce it.
GENERATED_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" CruftCheck/Info.plist)
GENERATED_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" CruftCheck/Info.plist)
[ "$GENERATED_VERSION" = "$VERSION" ] || die "Info.plist says version ${GENERATED_VERSION}, expected ${VERSION}"
[ "$GENERATED_BUILD" = "$BUILD" ]     || die "Info.plist says build ${GENERATED_BUILD}, expected ${BUILD}"

echo "  ${APP_NAME} ${VERSION} (build ${BUILD}) → ${TAG}"

DMG_PATH="build/${APP_NAME}-${VERSION}.dmg"
mkdir -p build

# ── 3. Tests ───────────────────────────────────────────────────────────────────
# This app moves files to the Trash. Shipping it without running the suite that guards
# that would defeat the point of having the suite.
step "Tests"
# Piping into grep would report grep's status, not xcodebuild's, and a failing suite would
# sail through. PIPESTATUS keeps the real one; errexit is lifted only across the pipeline.
set +e
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -destination 'platform=macOS' test 2>&1 \
  | tee build/test.log \
  | grep -E "Test run with|TEST SUCCEEDED|TEST FAILED|error:" | tail -3
TEST_STATUS=${PIPESTATUS[0]}
set -e
[ "$TEST_STATUS" -eq 0 ] || die "tests failed — not releasing. Full log: build/test.log"

# ── 4. Archive ─────────────────────────────────────────────────────────────────
step "Archiving"
rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -destination "generic/platform=macOS" \
  -allowProvisioningUpdates \
  | grep -E "^(error:|warning:|Archive succeeded)" || true

[ -d "$ARCHIVE_PATH" ] || die "archive not produced"

# ── 5. Export ──────────────────────────────────────────────────────────────────
# Export options are generated rather than committed, so the repository carries no team
# identifier at all. Distribution is outside the Mac App Store — the App Sandbox is off by
# design — which makes developer-id the only applicable method.
step "Exporting (Developer ID, team ${TEAM_ID})"
cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>${TEAM_ID}</string>
    <key>signingStyle</key><string>automatic</string>
    <key>stripSwiftSymbols</key><true/>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -allowProvisioningUpdates \
  | grep -E "^(error:|Export succeeded)" || true

APP_PATH=$(find "$EXPORT_PATH" -maxdepth 1 -name "*.app" | head -1)
[ -n "$APP_PATH" ] || die "no .app found in ${EXPORT_PATH}"

# ── 6. Verify the signature before spending minutes on notarization ────────────
step "Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1 | tail -2

# Read the signature once and assert on the text, so that codesign failing to read the
# bundle at all reports itself as that, rather than as a missing hardened runtime — a
# grep that finds nothing looks identical either way, and blames the artefact wrongly.
CS_INFO=$(codesign -dv --verbose=4 "$APP_PATH" 2>&1) \
  || die "codesign could not read ${APP_PATH}:
${CS_INFO}"

grep -qE "flags=.*runtime" <<<"$CS_INFO" \
  || die "hardened runtime is not enabled — notarization will reject this"

grep -q "Developer ID Application" <<<"$CS_INFO" \
  || die "app is not signed with Developer ID Application"

echo "  signed, hardened runtime on"

# ── 7. Notarize the app before it goes into the DMG ────────────────────────────
# Stapling only the DMG leaves the installed copy without a ticket: the ticket lives on
# the disk image, and the user drags the bundle out of it. Gatekeeper then has to ask
# Apple on first launch, which is a failure on a machine that is offline. The app must
# therefore be stapled before it is copied into the image, which means notarizing it on
# its own first — the DMG built from an already-stapled app is a different file, so the
# image needs its own submission afterwards either way.
if [ "$DRY_RUN" = false ]; then
  step "Notarizing the app (takes a few minutes)"
  APP_ZIP="build/${APP_NAME}-app.zip"
  rm -f "$APP_ZIP"
  ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"
  xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  rm -f "$APP_ZIP"

  step "Stapling the app"
  xcrun stapler staple "$APP_PATH"
  xcrun stapler validate "$APP_PATH" \
    || die "the app has no stapled ticket — it would not launch offline"
fi

# ── 8. DMG with drag-to-Applications layout ────────────────────────────────────
step "Creating DMG"
APP_BUNDLE=$(basename "$APP_PATH")
rm -f "$STAGING_DMG"
cleanup

APP_SIZE_MB=$(du -sm "$APP_PATH" | awk '{print $1}')
hdiutil create \
  -megabytes $((APP_SIZE_MB + 20)) \
  -volname "${APP_NAME} ${VERSION}" \
  -fs HFS+ -ov "$STAGING_DMG" >/dev/null

hdiutil attach "$STAGING_DMG" -mountpoint "$MOUNT_DIR" -noautoopen -readwrite >/dev/null
cp -R "$APP_PATH" "$MOUNT_DIR/"

# The background is optional; without it the window still gets the icon layout below.
BACKGROUND_CLAUSE=""
if [ -f "Assets/DMGBackground.png" ]; then
  mkdir -p "$MOUNT_DIR/.background"
  cp "Assets/DMGBackground.png" "$MOUNT_DIR/.background/DMGBackground.png"
  [ -f "Assets/DMGBackground@2x.png" ] && \
    cp "Assets/DMGBackground@2x.png" "$MOUNT_DIR/.background/DMGBackground@2x.png"
  BACKGROUND_CLAUSE='set background picture of viewOptions to file ".background:DMGBackground.png"'
fi

osascript <<APPLESCRIPT >/dev/null
tell application "Finder"
  set theDisk to disk "${APP_NAME}-staging"
  make new alias file to folder "Applications" of startup disk at theDisk
  tell theDisk
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {100, 100, 540, 400}
    set viewOptions to icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    ${BACKGROUND_CLAUSE}
    set position of item "${APP_BUNDLE}" of container window to {130, 160}
    set position of item "Applications" of container window to {370, 160}
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT

sync
sleep 1
hdiutil detach "$MOUNT_DIR" -quiet
hdiutil convert "$STAGING_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" -ov >/dev/null
rm -f "$STAGING_DMG"
echo "  ${DMG_PATH}"

if [ "$DRY_RUN" = true ]; then
  echo ""
  echo "✅ Dry run complete — built and signed, nothing published."
  echo "   DMG: ${DMG_PATH}"
  echo "   Revert the version bump with: git checkout ${PROJECT_YML} && xcodegen generate"
  exit 0
fi

# ── 9. Notarize the image, staple, verify ──────────────────────────────────────
step "Notarizing the DMG (takes a few minutes)"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

step "Stapling the DMG"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

# The real test: what Gatekeeper says about the app a user would actually launch.
spctl --assess --type execute --verbose=2 "$APP_PATH" 2>&1 | tail -2

# Publish the checksum beside the DMG so downloaders and Hash/Check can verify the exact
# image that was notarized and stapled above.
step "Calculating SHA-256"
CHECKSUM_PATH="${DMG_PATH}.sha256"
shasum -a 256 "$DMG_PATH" > "$CHECKSUM_PATH"
echo "  ${CHECKSUM_PATH}"

# ── 10. Commit the bump, then tag it ───────────────────────────────────────────
# Committing before publishing means the tag points at the commit that declares the
# version it claims, rather than at the one before it.
step "Committing ${TAG}"
git add "$PROJECT_YML" "$PROJECT/project.pbxproj" CruftCheck/Info.plist
git commit -q -m "Release ${TAG}"
git push -q origin "$RELEASE_BRANCH"

step "Publishing GitHub release"
gh release create "$TAG" \
  "$DMG_PATH" \
  "$CHECKSUM_PATH" \
  --title "${APP_NAME} ${VERSION}" \
  --generate-notes

echo ""
echo "✅ Released ${TAG}"
echo "   DMG: ${DMG_PATH}"
