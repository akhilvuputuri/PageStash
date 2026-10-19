#!/bin/sh
# Archives the merged release commit as a Release build and uploads it to App Store Connect for
# internal TestFlight testing only. Signing and upload use the Apple account signed in to Xcode;
# this script reads and stores no credentials. Each upload needs a new build number
# (scripts/generate-project.py).
set -eu
cd "$(dirname "$0")/.."
status=$(git status --porcelain)
if [ -n "$status" ]; then
  echo "Refusing to upload: the working tree has uncommitted changes." >&2
  exit 1
fi
# Only the merged release commit may be uploaded, never a branch.
git fetch --quiet origin main
head=$(git rev-parse HEAD)
main=$(git rev-parse origin/main)
if [ "$head" != "$main" ]; then
  echo "Refusing to upload: HEAD ($head) is not origin/main ($main)." >&2
  exit 1
fi
# The committed project must be exactly what the generator produces for this version and build.
python3 scripts/generate-project.py >/dev/null
status=$(git status --porcelain)
if [ -n "$status" ]; then
  git checkout -- ios/OfflineReader.xcodeproj
  echo "Refusing to upload: the project doesn't match scripts/generate-project.py." >&2
  exit 1
fi
# Archiving rewrites the shared scheme in Xcode's own format. Always put the committed project
# back, even if the archive or upload fails, so the next run's clean-tree check passes.
trap 'git checkout -- ios/OfflineReader.xcodeproj' EXIT
release=$(sed -n "s/^MARKETING_VERSION, BUILD = '\(.*\)', '\(.*\)'$/\1 (\2)/p" scripts/generate-project.py)
work="work/testflight-$(git rev-parse --short HEAD)"
rm -rf "$work"
xcodebuild -project ios/OfflineReader.xcodeproj -scheme OfflineReader -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$work/OfflineReader.xcarchive" \
  -allowProvisioningUpdates archive
xcodebuild -exportArchive -archivePath "$work/OfflineReader.xcarchive" \
  -exportOptionsPlist ios/ExportOptions-TestFlight.plist -exportPath "$work/export" \
  -allowProvisioningUpdates
echo "Uploaded PageStash $release from $(git rev-parse --short HEAD) for internal TestFlight testing."
