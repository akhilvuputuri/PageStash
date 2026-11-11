#!/bin/sh
# Xcode Cloud runs this after xcodebuild, even when it failed. It only prints the facts the release
# record needs (docs/DEPLOYMENT.md, section 3) and never changes the result.
echo "xcodebuild ${CI_XCODEBUILD_ACTION:-unknown} exit code: ${CI_XCODEBUILD_EXIT_CODE:-unknown}"
echo "Commit ${CI_COMMIT:-unknown}; tag ${CI_TAG:-none}; workflow ${CI_WORKFLOW:-none}"
echo "Xcode Cloud build number: ${CI_BUILD_NUMBER:-unknown}"
if [ -n "${CI_APP_STORE_SIGNED_APP_PATH:-}" ]; then
  echo "CI_APP_STORE_SIGNED_APP_PATH is set."
else
  echo "CI_APP_STORE_SIGNED_APP_PATH is not set."
fi
exit 0
