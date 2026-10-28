#!/bin/zsh
# Archives MyGuide (phone, widget and watch app) and uploads it to App Store Connect for TestFlight.
# Signing and upload use the Apple account signed in to Xcode. The build number is the commit count, so every
# upload from a newer commit is accepted. Build products go to a temporary folder, never into the repo.
set -euo pipefail

cd "$(dirname "$0")/.."
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Commit or stash your changes first: the build number comes from the commit count." >&2
  exit 1
fi

build_number=$(git rev-list --count HEAD)
work=$(mktemp -d -t myguide-testflight)
archive="$work/MyGuide.xcarchive"

if ! grep -qE '^[[:space:]]*OPENAI_BUNDLED_KEY[[:space:]]*=[[:space:]]*[^[:space:]]' Config/Local.xcconfig 2>/dev/null; then
  echo "Note: no OPENAI_BUNDLED_KEY in Config/Local.xcconfig, so testers must enter their own key." >&2
fi

xcodegen generate --quiet
xcodebuild archive \
  -project MyGuide.xcodeproj -scheme MyGuide -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive" \
  -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$build_number" -quiet
xcodebuild -exportArchive \
  -archivePath "$archive" -exportOptionsPlist scripts/ExportOptions-TestFlight.plist \
  -exportPath "$work/export" -allowProvisioningUpdates -quiet

echo "Uploaded build $build_number. It shows up in TestFlight after Apple has processed it (usually 5-15 minutes)."
rm -rf "$work"
