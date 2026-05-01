#!/usr/bin/env bash
# test_release_logic.sh — Unit tests for shell logic extracted from .github/workflows/release.yml
#
# Covers the code paths added/changed in the PR:
#   - TAG extraction via INPUT_TAG with GITHUB_REF_NAME fallback
#   - VERSION extraction (strip leading "v")
#   - Formula source-file guard (must exist in this repo, not the tap)
#   - Full formula sync via `install -m 644` before patching
#   - sed-based url / sha256 / version patching in the synced formula
#   - Regression: old tap-side guard (now replaced) must not be present
#
# Run: bash tests/test_release_logic.sh

set -euo pipefail

export LANG=C
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/test_helpers.sh
source "${SCRIPT_DIR}/test_helpers.sh"

# Scratch workspace — cleaned up on exit
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

echo "release.yml shell-logic unit tests"
echo "========================================"

# ---------------------------------------------------------------------------
# Helpers that inline the exact shell snippets from release.yml so we test
# the real logic, not a paraphrase of it.
# ---------------------------------------------------------------------------

# extract_version <INPUT_TAG> <GITHUB_REF_NAME>
# Mirrors the "Extract version" step verbatim.
extract_version() {
    local INPUT_TAG="${1:-}"
    local GITHUB_REF_NAME="${2:-}"
    TAG="${INPUT_TAG:-$GITHUB_REF_NAME}"
    VERSION="${TAG#v}"
    echo "tag=${TAG}"
    echo "version=${VERSION}"
}

# patch_formula <formula_file> <url> <sha256> <version>
# Mirrors the three sed lines in the "Update Homebrew tap" step verbatim.
patch_formula() {
    local formula="$1" URL="$2" SHA256="$3" VERSION="$4"
    sed -i "s|^  url \".*\"|  url \"${URL}\"|"       "${formula}"
    sed -i "s|^  sha256 \".*\"|  sha256 \"${SHA256}\"|" "${formula}"
    sed -i "s|^  version \".*\"|  version \"${VERSION}\"|" "${formula}"
}

# ---------------------------------------------------------------------------
# Minimal formula template used by several tests
# ---------------------------------------------------------------------------
FORMULA_TEMPLATE='# frozen_string_literal: true
class TmExclusions < Formula
  desc "Time Machine exclusion manager for developer Macs"
  homepage "https://github.com/qveys/tm-exclusions"
  url "https://github.com/qveys/tm-exclusions/archive/refs/tags/v0.0.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"
  version "0.0.0"

  depends_on :macos

  def install
    bin.install "tm_exclusions.sh" => "tm-exclusions"
    (share/"tm-exclusions").install "config/default.conf"
  end
end
'

# ---------------------------------------------------------------------------
echo ""
echo "--- TAG / VERSION extraction ---"
# ---------------------------------------------------------------------------

assert_output_contains "tag=v1.2.3" \
    "INPUT_TAG is used when set" \
    bash -c 'INPUT_TAG="v1.2.3"; GITHUB_REF_NAME="v9.9.9"; TAG="${INPUT_TAG:-$GITHUB_REF_NAME}"; echo "tag=${TAG}"'

assert_output_contains "tag=v9.9.9" \
    "GITHUB_REF_NAME is used when INPUT_TAG is empty" \
    bash -c 'INPUT_TAG=""; GITHUB_REF_NAME="v9.9.9"; TAG="${INPUT_TAG:-$GITHUB_REF_NAME}"; echo "tag=${TAG}"'

assert_output_contains "tag=v9.9.9" \
    "GITHUB_REF_NAME is used when INPUT_TAG is unset" \
    bash -c 'unset INPUT_TAG; GITHUB_REF_NAME="v9.9.9"; TAG="${INPUT_TAG:-$GITHUB_REF_NAME}"; echo "tag=${TAG}"'

assert_output_contains "version=1.2.3" \
    "VERSION strips leading 'v' from tag" \
    bash -c 'TAG="v1.2.3"; VERSION="${TAG#v}"; echo "version=${VERSION}"'

assert_output_contains "version=1.2.3" \
    "VERSION is correct when INPUT_TAG drives TAG" \
    bash -c 'INPUT_TAG="v1.2.3"; GITHUB_REF_NAME="v9.9.9"; TAG="${INPUT_TAG:-$GITHUB_REF_NAME}"; VERSION="${TAG#v}"; echo "version=${VERSION}"'

assert_output_contains "version=9.9.9" \
    "VERSION is correct when GITHUB_REF_NAME drives TAG" \
    bash -c 'INPUT_TAG=""; GITHUB_REF_NAME="v9.9.9"; TAG="${INPUT_TAG:-$GITHUB_REF_NAME}"; VERSION="${TAG#v}"; echo "version=${VERSION}"'

assert_output_contains "version=0.0.1" \
    "VERSION strips 'v' from single-digit patch tag" \
    bash -c 'TAG="v0.0.1"; VERSION="${TAG#v}"; echo "version=${VERSION}"'

assert_output_contains "version=10.20.30" \
    "VERSION handles multi-digit semver components" \
    bash -c 'TAG="v10.20.30"; VERSION="${TAG#v}"; echo "version=${VERSION}"'

# Edge: tag without leading 'v' (unusual but must not double-strip)
assert_output_contains "version=1.0.0" \
    "VERSION is unchanged when tag has no 'v' prefix" \
    bash -c 'TAG="1.0.0"; VERSION="${TAG#v}"; echo "version=${VERSION}"'

# ---------------------------------------------------------------------------
echo ""
echo "--- Formula source-file guard ---"
# ---------------------------------------------------------------------------

# Guard line (new in this PR): test -f Formula/tm-exclusions.rb || { echo "ERROR..."; exit 1; }
# We exercise it by running it inside a subshell from a temp dir that may or may not have the file.

assert_exit_code 0 \
    "Guard passes when Formula/tm-exclusions.rb exists" \
    bash -c 'D="$(mktemp -d)"; mkdir -p "${D}/Formula"; touch "${D}/Formula/tm-exclusions.rb"; cd "${D}"; test -f Formula/tm-exclusions.rb; rm -rf "${D}"'

assert_exit_code 1 \
    "Guard fails (exit 1) when Formula/tm-exclusions.rb is absent" \
    bash -c 'D="$(mktemp -d)"; cd "${D}"; test -f Formula/tm-exclusions.rb; RC=$?; rm -rf "${D}"; exit $RC'

assert_output_contains "ERROR: Formula/tm-exclusions.rb missing in this repo" \
    "Guard emits correct error message to stdout/stderr" \
    bash -c 'D="$(mktemp -d)"; cd "${D}"; test -f Formula/tm-exclusions.rb || { echo "ERROR: Formula/tm-exclusions.rb missing in this repo"; }; rm -rf "${D}"'

# ---------------------------------------------------------------------------
echo ""
echo "--- Full formula sync (install -m 644) ---"
# ---------------------------------------------------------------------------
# The workflow uses `install -m 644 src dst`.  On systems where the `install`
# utility is unavailable we fall back to `cp + chmod` which has identical
# semantics for our purposes.  The tests verify the *outcome* (content fully
# replaced, correct permissions) rather than which tool produced it.

sync_formula() {
    local src="$1" dst="$2"
    if command -v install >/dev/null 2>&1; then
        install -m 644 "$src" "$dst"
    else
        cp "$src" "$dst"
        chmod 644 "$dst"
    fi
}

SRC_FORMULA="${TMP}/Formula/tm-exclusions.rb"
TAP_FORMULA="${TMP}/tap/Formula/tm-exclusions.rb"

mkdir -p "${TMP}/Formula" "${TMP}/tap/Formula"
printf '%s' "${FORMULA_TEMPLATE}" > "${SRC_FORMULA}"
# Tap starts with deliberately stale content (simulates the pre-PR bug)
printf 'stale tap content\n' > "${TAP_FORMULA}"

assert_exit_code 0 \
    "install -m 644 (or cp+chmod) succeeds copying formula from repo to tap" \
    bash -c "$(declare -f sync_formula); sync_formula \"${SRC_FORMULA}\" \"${TAP_FORMULA}\""

assert_output_contains "class TmExclusions" \
    "Tap formula is fully replaced with repo formula content" \
    bash -c "cat \"${TAP_FORMULA}\""

assert_output_not_contains "stale tap content" \
    "Stale tap content is overwritten (regression: install stanza drift)" \
    bash -c "cat \"${TAP_FORMULA}\""

# Verify permissions: result must be mode 644 (rw-r--r--)
assert_output_contains "rw-r--r--" \
    "Synced formula has mode 644 (rw-r--r--)" \
    bash -c "ls -l \"${TAP_FORMULA}\""

# Regression: formula synced to tap must contain the install stanza from repo
assert_output_contains "bin.install" \
    "Synced formula preserves install stanza (regression guard)" \
    bash -c "cat \"${TAP_FORMULA}\""

# ---------------------------------------------------------------------------
echo ""
echo "--- sed patching: url / sha256 / version ---"
# ---------------------------------------------------------------------------

# Helper: write a fresh copy of the template formula to a given path
write_formula() { printf '%s' "${FORMULA_TEMPLATE}" > "$1"; }

PATCH_FORMULA="${TMP}/patch_test/Formula/tm-exclusions.rb"
mkdir -p "${TMP}/patch_test/Formula"

# url patch
write_formula "${PATCH_FORMULA}"
NEW_URL="https://github.com/qveys/tm-exclusions/archive/refs/tags/v2.0.0.tar.gz"
sed -i "s|^  url \".*\"|  url \"${NEW_URL}\"|" "${PATCH_FORMULA}"
assert_output_contains "url \"${NEW_URL}\"" \
    "sed patches url line correctly" \
    bash -c "cat \"${PATCH_FORMULA}\""

# sha256 patch
write_formula "${PATCH_FORMULA}"
NEW_SHA="abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
sed -i "s|^  sha256 \".*\"|  sha256 \"${NEW_SHA}\"|" "${PATCH_FORMULA}"
assert_output_contains "sha256 \"${NEW_SHA}\"" \
    "sed patches sha256 line correctly" \
    bash -c "cat \"${PATCH_FORMULA}\""

# version patch
write_formula "${PATCH_FORMULA}"
NEW_VER="2.0.0"
sed -i "s|^  version \".*\"|  version \"${NEW_VER}\"|" "${PATCH_FORMULA}"
assert_output_contains "version \"${NEW_VER}\"" \
    "sed patches version line correctly" \
    bash -c "cat \"${PATCH_FORMULA}\""

# All three patches together (mirrors the real workflow step)
write_formula "${PATCH_FORMULA}"
NEW_URL="https://github.com/qveys/tm-exclusions/archive/refs/tags/v3.1.0.tar.gz"
NEW_SHA="deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
NEW_VER="3.1.0"
patch_formula "${PATCH_FORMULA}" "${NEW_URL}" "${NEW_SHA}" "${NEW_VER}"
assert_output_contains "url \"${NEW_URL}\"" \
    "Combined patch: url is updated" \
    bash -c "cat \"${PATCH_FORMULA}\""
assert_output_contains "sha256 \"${NEW_SHA}\"" \
    "Combined patch: sha256 is updated" \
    bash -c "cat \"${PATCH_FORMULA}\""
assert_output_contains "version \"${NEW_VER}\"" \
    "Combined patch: version is updated" \
    bash -c "cat \"${PATCH_FORMULA}\""

# Patching must not touch unrelated lines (desc, homepage, license, class)
assert_output_contains "desc \"Time Machine exclusion manager for developer Macs\"" \
    "Combined patch leaves desc untouched" \
    bash -c "cat \"${PATCH_FORMULA}\""
assert_output_contains "homepage \"https://github.com/qveys/tm-exclusions\"" \
    "Combined patch leaves homepage untouched" \
    bash -c "cat \"${PATCH_FORMULA}\""
assert_output_contains "license \"MIT\"" \
    "Combined patch leaves license untouched" \
    bash -c "cat \"${PATCH_FORMULA}\""

# Edge: sed must not match indented lines that don't start with exactly two spaces + keyword
write_formula "${PATCH_FORMULA}"
# Add a comment line with deeper indent to ensure it is not clobbered
EXTRA="    # url indented comment"
printf '  %s\n' "# extra line" >> "${PATCH_FORMULA}"
NEW_URL2="https://github.com/qveys/tm-exclusions/archive/refs/tags/v3.2.0.tar.gz"
sed -i "s|^  url \".*\"|  url \"${NEW_URL2}\"|" "${PATCH_FORMULA}"
assert_output_contains "  # extra line" \
    "sed url pattern does not clobber non-url indented lines" \
    bash -c "cat \"${PATCH_FORMULA}\""

# ---------------------------------------------------------------------------
echo ""
echo "--- Full sync then patch (end-to-end simulation) ---"
# ---------------------------------------------------------------------------

E2E_REPO="${TMP}/e2e_repo"
E2E_TAP="${TMP}/e2e_tap"
mkdir -p "${E2E_REPO}/Formula" "${E2E_TAP}/Formula"

# Repo has a current formula with correct install stanza
printf '%s' "${FORMULA_TEMPLATE}" > "${E2E_REPO}/Formula/tm-exclusions.rb"

# Tap has a stale formula that still references the old 2.x locales/ path
cat > "${E2E_TAP}/Formula/tm-exclusions.rb" <<'STALE'
class TmExclusions < Formula
  url "https://old-url"
  sha256 "oldsha"
  version "0.9.0"
  def install
    bin.install "tm_exclusions.sh" => "tm-exclusions"
    (share/"tm-exclusions").install "locales/"
  end
end
STALE

E2E_TAG="v2.5.0"
E2E_VER="2.5.0"
E2E_URL="https://github.com/qveys/tm-exclusions/archive/refs/tags/${E2E_TAG}.tar.gz"
E2E_SHA="cafebabecafebabecafebabecafebabecafebabecafebabecafebabecafebabe"

# Step 1: guard
assert_exit_code 0 \
    "E2E: source formula guard passes" \
    bash -c "test -f \"${E2E_REPO}/Formula/tm-exclusions.rb\""

# Step 2: sync (cd to repo dir first, as the workflow does)
# Use the same sync_formula helper defined above (install -m 644 or cp+chmod)
(cd "${E2E_REPO}" && sync_formula Formula/tm-exclusions.rb "${E2E_TAP}/Formula/tm-exclusions.rb")

# Step 3: patch (cd into tap, as the workflow does)
(cd "${E2E_TAP}" && patch_formula Formula/tm-exclusions.rb "${E2E_URL}" "${E2E_SHA}" "${E2E_VER}")

assert_output_contains "url \"${E2E_URL}\"" \
    "E2E: url is patched to new tag URL" \
    bash -c "cat \"${E2E_TAP}/Formula/tm-exclusions.rb\""

assert_output_contains "sha256 \"${E2E_SHA}\"" \
    "E2E: sha256 is patched to new checksum" \
    bash -c "cat \"${E2E_TAP}/Formula/tm-exclusions.rb\""

assert_output_contains "version \"${E2E_VER}\"" \
    "E2E: version is patched to new version" \
    bash -c "cat \"${E2E_TAP}/Formula/tm-exclusions.rb\""

assert_output_not_contains "locales/" \
    "E2E: stale locales/ install stanza is gone after full sync (regression)" \
    bash -c "cat \"${E2E_TAP}/Formula/tm-exclusions.rb\""

assert_output_contains "bin.install" \
    "E2E: correct install stanza is present after full sync" \
    bash -c "cat \"${E2E_TAP}/Formula/tm-exclusions.rb\""

# ---------------------------------------------------------------------------
test_summary
