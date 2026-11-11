#!/bin/sh
# Xcode Cloud runs this after cloning the repository (docs/DEPLOYMENT.md, section 3). It fails the
# build unless:
# - the committed Xcode project is exactly what scripts/generate-project.py produces;
# - an archive is built from a vX.Y.Z tag that matches MARKETING_VERSION, on a commit that is
#   already on main;
# - the Xcode Cloud build number is not lower than BUILD in scripts/generate-project.py.
# It reads and prints no credentials. POSIX sh; every tool it needs is checked first.
set -eu

fail() {
  echo "ci_post_clone: $*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || fail "required tool '$1' is not available"
}

need git
need python3
need sed
need diff
need mktemp

# Xcode Cloud runs scripts from ios/ci_scripts; the variable is the documented clone location.
repo=${CI_PRIMARY_REPOSITORY_PATH:-}
if [ -z "$repo" ]; then
  repo=$(cd "$(dirname "$0")/../.." && pwd)
fi
cd "$repo"
[ -f scripts/generate-project.py ] || fail "scripts/generate-project.py not found under $repo"

generator=scripts/generate-project.py
version=$(sed -n "s/^MARKETING_VERSION, BUILD = '\(.*\)', '\(.*\)'$/\1/p" "$generator")
build=$(sed -n "s/^MARKETING_VERSION, BUILD = '\(.*\)', '\(.*\)'$/\2/p" "$generator")
[ -n "$version" ] && [ -n "$build" ] || fail "could not read MARKETING_VERSION and BUILD from $generator"

echo "PageStash $version, BUILD $build in $generator"
echo "Commit ${CI_COMMIT:-$(git rev-parse HEAD)}; tag ${CI_TAG:-none}; branch ${CI_BRANCH:-none}"
echo "Workflow ${CI_WORKFLOW:-none}; action ${CI_XCODEBUILD_ACTION:-unknown}; start ${CI_START_CONDITION:-unknown}; Xcode Cloud build ${CI_BUILD_NUMBER:-none}"

# 1. The committed project must match the generator. The generator rewrites the project in place,
#    so compare against a copy and always put the committed bytes back.
project=ios/OfflineReader.xcodeproj
saved=$(mktemp -d "${TMPDIR:-/tmp}/pagestash-project.XXXXXX")
copied=0
restore() {
  # Only a complete copy is put back: a copy that failed partway must never replace the project.
  if [ "$copied" = 1 ]; then
    rm -rf "$project"
    cp -R "$saved/OfflineReader.xcodeproj" "$project"
  fi
  rm -rf "$saved"
}
trap restore EXIT
# Shells such as dash don't run the EXIT trap on a signal.
trap 'exit 130' INT TERM
cp -R "$project" "$saved/OfflineReader.xcodeproj"
copied=1
python3 "$generator" >/dev/null || fail "scripts/generate-project.py failed with $(python3 --version 2>&1)"
if ! diff -r "$saved/OfflineReader.xcodeproj" "$project" >/dev/null; then
  fail "the committed project doesn't match scripts/generate-project.py; regenerate and commit it"
fi
echo "Project matches scripts/generate-project.py."

# Outside Xcode Cloud (a local dry run) stop here: the release checks need Xcode Cloud's variables.
# Apple documents CI_XCODE_CLOUD as "TRUE". Any of its other variables also counts, so a change
# in that value can't silently skip the release checks.
if [ "${CI_XCODE_CLOUD:-}" != "TRUE" ] && [ -z "${CI_XCODE_CLOUD:-}${CI_BUILD_ID:-}${CI_WORKFLOW:-}" ]; then
  echo "Not running in Xcode Cloud; skipping the release checks."
  exit 0
fi

# Only archives are releases. A test or build workflow added later needs only the project check.
# If the action is unknown, run the release checks anyway (fail closed).
case "${CI_XCODEBUILD_ACTION:-}" in
  archive | '') ;;
  *)
    echo "Action is ${CI_XCODEBUILD_ACTION}, not archive; skipping the release checks."
    exit 0
    ;;
esac

# 2. Archives come only from the release tag for this version.
tag=${CI_TAG:-}
[ -n "$tag" ] || fail "refusing to archive without a tag; releases start from a pushed vX.Y.Z tag"
[ "$tag" = "v$version" ] || fail "tag $tag doesn't match MARKETING_VERSION $version (expected v$version)"
commit=${CI_COMMIT:-$(git rev-parse HEAD)}

# 3. The tagged commit must already be on main (the merged release commit). The repository is
#    public, so fall back to the anonymous URL if the clone's remote can't be fetched.
fetch_main() {
  depth=""
  if [ "$(git rev-parse --is-shallow-repository 2>/dev/null || echo false)" = "true" ]; then
    depth="--depth=500"
  fi
  # $depth is intentionally unquoted: it is empty or one word.
  # shellcheck disable=SC2086
  GIT_TERMINAL_PROMPT=0 git fetch --quiet --no-tags $depth "$1" "+refs/heads/main:refs/remotes/pagestash-release/main"
}
if ! fetch_main origin 2>/dev/null && ! fetch_main https://github.com/akhilvuputuri/PageStash.git; then
  fail "could not fetch main to confirm $commit is on it"
fi
git merge-base --is-ancestor "$commit" refs/remotes/pagestash-release/main ||
  fail "commit $commit (tag $tag) is not on main; tag only the merged release commit"
echo "Tag $tag is $commit, which is on main."

# 4. Xcode Cloud replaces the build number with its own counter (CI_BUILD_NUMBER). Keep it at or
#    above the repository's BUILD so it never goes below a build uploaded earlier.
ci_build=${CI_BUILD_NUMBER:-}
case "$ci_build" in
  '' | *[!0-9]*) fail "CI_BUILD_NUMBER is missing or not an integer: '$ci_build'" ;;
esac
case "$build" in
  *[!0-9]*) fail "BUILD in $generator is not an integer: '$build'" ;;
esac
if [ "$ci_build" -lt "$build" ]; then
  fail "Xcode Cloud build number $ci_build is lower than BUILD $build; raise Next Build Number in App Store Connect (Xcode Cloud > Settings > Build Number)"
fi
echo "Release checks passed: PageStash $version will be uploaded as build $ci_build."
