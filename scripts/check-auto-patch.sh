#!/usr/bin/env bash
# scripts/check-auto-patch.sh
#
# Checks if the number of merged PRs since the last release tag (v*) reaches
# the threshold (default: 5). If reached, directly applies the next PATCH
# version on master (updates version, changelog, commits, tags, and pushes)
# without creating an intermediate PR.
#
# Bash 3.2+ compatible (macOS stock bash).
set -euo pipefail

THRESHOLD="${AUTO_PATCH_THRESHOLD:-5}"
DRY_RUN=0
BASE_BRANCH="master"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --threshold <N>   Set the PR count threshold (default: 5)
  --dry-run         Compute and display status without modifying or pushing
  -h, --help        Show this help message
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --threshold)
      shift
      [ $# -gt 0 ] || { echo "Error: --threshold requires a number" >&2; exit 1; }
      THRESHOLD="$1"
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown argument '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

# Validate THRESHOLD (from --threshold or AUTO_PATCH_THRESHOLD): must be a positive integer
case "$THRESHOLD" in
  ''|*[!0-9]*)
    echo "Error: threshold '$THRESHOLD' is not a positive integer" >&2
    exit 1
    ;;
esac
[ "$THRESHOLD" -gt 0 ] || { echo "Error: threshold must be greater than 0" >&2; exit 1; }

# Ensure git is available
command -v git >/dev/null 2>&1 || { echo "Error: git not found" >&2; exit 1; }

# Find latest release tag
LAST_TAG="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || echo "")"
if [ -z "$LAST_TAG" ]; then
  LAST_TAG="$(git tag -l 'v*' --sort=-version:refname | head -n1)"
fi

if [ -z "$LAST_TAG" ]; then
  echo "No previous v* release tag found. Auto-patch requires at least one base tag." >&2
  exit 0
fi

CURRENT_VERSION="${LAST_TAG#v}"

# Validate SemVer format X.Y.Z
if ! echo "$CURRENT_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "Error: Tag '$LAST_TAG' does not follow SemVer X.Y.Z format." >&2
  exit 1
fi

# Skip if tm_exclusions.sh's VERSION already differs from LAST_TAG: a manual
# release (make release) may have merged without its tag being pushed yet.
SCRIPT_VERSION="$(sed -n 's/^readonly VERSION="\(.*\)"$/\1/p' tm_exclusions.sh)"
if [ -n "$SCRIPT_VERSION" ] && [ "$SCRIPT_VERSION" != "$CURRENT_VERSION" ]; then
  echo "Status: tm_exclusions.sh VERSION ($SCRIPT_VERSION) differs from last tag ($CURRENT_VERSION); a manual release may be pending. Skipping auto-patch." >&2
  exit 0
fi

# Count merged PRs / squash commits since LAST_TAG on BASE_BRANCH
COMMITS="$(git log "${LAST_TAG}..HEAD" --format=%s)"
if [ -z "$COMMITS" ]; then
  PR_COUNT=0
else
  # Count commits ending with PR reference like (#42) or merge commits
  PR_COUNT="$(printf "%s\n" "$COMMITS" | grep -cE '(\(#[0-9]+\)$|^Merge pull request)' || true)"
  if [ "$PR_COUNT" -eq 0 ]; then
    PR_COUNT="$(printf "%s\n" "$COMMITS" | grep -c . || true)"
  fi
fi

# Calculate next patch version
MAJOR="$(echo "$CURRENT_VERSION" | cut -d. -f1)"
MINOR="$(echo "$CURRENT_VERSION" | cut -d. -f2)"
PATCH="$(echo "$CURRENT_VERSION" | cut -d. -f3)"
NEXT_PATCH="${MAJOR}.${MINOR}.$((PATCH + 1))"

echo "Latest tag:           ${LAST_TAG} (v${CURRENT_VERSION})"
echo "Merged PRs since:     ${PR_COUNT} (threshold: ${THRESHOLD})"
echo "Next patch candidate: v${NEXT_PATCH}"

if [ "$PR_COUNT" -lt "$THRESHOLD" ]; then
  echo "Status: Threshold not reached (${PR_COUNT}/${THRESHOLD}). No auto-patch needed."
  exit 0
fi

# Check if tag already exists
if git rev-parse --verify --quiet "v${NEXT_PATCH}" >/dev/null || \
   git ls-remote --exit-code --tags origin "v${NEXT_PATCH}" >/dev/null 2>&1; then
  echo "Status: Tag 'v${NEXT_PATCH}' already exists. Skipping."
  exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "Dry-run: Threshold met (${PR_COUNT} >= ${THRESHOLD}). Would apply v${NEXT_PATCH} directly on ${BASE_BRANCH}, tag v${NEXT_PATCH}, and push (NO PR)."
  exit 0
fi

# Require a clean worktree with HEAD at origin/BASE_BRANCH before mutating
# release files: refuses to publish a tag built from a feature branch or a
# stale local master ref.
git fetch origin "$BASE_BRANCH" --quiet
HEAD_SHA="$(git rev-parse HEAD)"
REMOTE_SHA="$(git rev-parse "origin/${BASE_BRANCH}")"
if [ "$HEAD_SHA" != "$REMOTE_SHA" ]; then
  echo "Error: HEAD (${HEAD_SHA}) is not origin/${BASE_BRANCH} (${REMOTE_SHA}). Refusing to auto-patch." >&2
  exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "Error: working tree is not clean. Refusing to auto-patch." >&2
  exit 1
fi

# Execute direct release on master without PR
echo "Applying patch release v${NEXT_PATCH} directly on ${BASE_BRANCH}..."

# Update tm_exclusions.sh
TMP_SCRIPT="$(mktemp)"
sed "s|^readonly VERSION=\".*\"|readonly VERSION=\"${NEXT_PATCH}\"|" tm_exclusions.sh > "$TMP_SCRIPT"
mv "$TMP_SCRIPT" tm_exclusions.sh

# Update Formula/tm-exclusions.rb
if [ -f "Formula/tm-exclusions.rb" ]; then
  TMP_FORMULA="$(mktemp)"
  sed "s|^  version \".*\"|  version \"${NEXT_PATCH}\"|" Formula/tm-exclusions.rb > "$TMP_FORMULA"
  mv "$TMP_FORMULA" Formula/tm-exclusions.rb
fi

# Update CHANGELOG.md
TMP_CHANGELOG="$(mktemp)"
if grep -q '^## Unreleased$' CHANGELOG.md; then
  awk -v ver="$NEXT_PATCH" '/^## Unreleased$/{print; print ""; print "## v" ver; next}1' CHANGELOG.md > "$TMP_CHANGELOG"
  mv "$TMP_CHANGELOG" CHANGELOG.md
else
  {
    echo "## Unreleased"
    echo ""
    echo "## v${NEXT_PATCH}"
    echo ""
    echo "Automated patch release after ${PR_COUNT} merged PRs:"
    printf "%s\n" "$COMMITS" | sed 's/^/- /'
    echo ""
    cat CHANGELOG.md
  } > "$TMP_CHANGELOG"
  mv "$TMP_CHANGELOG" CHANGELOG.md
fi

# Configure author if unset
if [ -z "$(git config --get user.name 2>/dev/null || true)" ]; then
  git config user.name "github-actions[bot]"
  git config user.email "github-actions[bot]@users.noreply.github.com"
fi

git add tm_exclusions.sh CHANGELOG.md
if [ -f "Formula/tm-exclusions.rb" ]; then
  git add Formula/tm-exclusions.rb
fi
git commit -m "🔖 chore(release): v${NEXT_PATCH} [auto-patch ${PR_COUNT} PRs]"

# Tag directly (signed if signing key available)
if [ -n "$(git config --get user.signingkey 2>/dev/null || true)" ]; then
  git tag -s "v${NEXT_PATCH}" -m "Release v${NEXT_PATCH}"
else
  git tag -a "v${NEXT_PATCH}" -m "Release v${NEXT_PATCH}"
fi

# Push commit and tag directly
git push origin "${BASE_BRANCH}"
git push origin "v${NEXT_PATCH}"

echo "Successfully applied and published v${NEXT_PATCH} directly on ${BASE_BRANCH} without PR."
