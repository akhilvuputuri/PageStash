#!/bin/sh
# Archives the current checkout as a Release build and uploads it to App Store Connect for
# internal TestFlight testing only. Run from the repository root on the exact merged release
# commit. Signing and upload use the Apple account signed in to Xcode; this script reads and
# stores no credentials. Each upload needs a new build number (scripts/generate-project.py).
set -eu
cd "$(dirname "$0")/.."
if [ -n "$(git status --porcelain)" ]; then
  echo "Refusing to upload: the working tree has uncommitted changes." >&2
  exit 1
fi
work="work/testflight-$(git rev-parse --short HEAD)"
rm -rf "$work"
xcodebuild -project ios/OfflineReader.xcodeproj -scheme OfflineReader -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$work/OfflineReader.xcarchive" \
  -allowProvisioningUpdates archive
xcodebuild -exportArchive -archivePath "$work/OfflineReader.xcarchive" \
  -exportOptionsPlist ios/ExportOptions-TestFlight.plist -exportPath "$work/export" \
  -allowProvisioningUpdates
echo "Uploaded $(git rev-parse --short HEAD) for internal TestFlight testing."
