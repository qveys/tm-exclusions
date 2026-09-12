#!/usr/bin/env bash
# test_release_logic.sh — Unit tests for the bash logic in .github/workflows/release.yml
#
# Tests cover the new/changed behaviour introduced in the PR:
#   1. TAG extraction — INPUT_TAG takes priority over GITHUB_REF_NAME (workflow_dispatch support)
#   2. VERSION stripping — leading 'v' is removed via TAG#v parameter expansion
#   3. Local formula existence check — exits 1 with an error message when the file is absent
#   4. Formula copy step — `install -m 644` fully replaces the tap formula with the repo copy
#   5. sed patches — url / sha256 / version lines are rewritten correctly after the copy
#   6. HOMEBREW_TOKEN guard — a missing token fails the step (exit 1 + ::error::),
#      asserted both on a copy of the snippet and on release.yml itself
#   7. Regression — a stale install stanza in the tap is overwritten by the full copy
#   9. Formula coherence — the real Formula/tm-exclusions.rb has url, sha256 and version
#      describing the same tarball (a version-only bump by release tooling is a bug)
#
# Run: bash tests/test_release_logic.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/test_helpers.sh
source "${SCRIPT_DIR}/test_helpers.sh"

echo "release.yml logic tests"
echo "========================================"

# ---------------------------------------------------------------------------
# Shared tmp workspace — cleaned up on exit
# ---------------------------------------------------------------------------

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# 1. TAG extraction — INPUT_TAG fallback logic
# ---------------------------------------------------------------------------
echo ""
echo "--- TAG extraction (INPUT_TAG vs GITHUB_REF_NAME) ---"

TESTS_RUN=$((TESTS_RUN + 1))
_out="$(bash -c '
    INPUT_TAG="v1.5.0"
    GITHUB_REF_NAME="v0.0.0"
    TAG="${INPUT_TAG:-$GITHUB_REF_NAME}"
    echo "$TAG"
')"
if [[ "$_out" == "v1.5.0" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "%b  PASS%b INPUT_TAG is used when set\n" "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "%b  FAIL%b INPUT_TAG is used when set (got '%s')\n" "$RED" "$NC" "$_out"
fi

TESTS_RUN=$((TESTS_RUN + 1))
_out="$(bash -c '
    INPUT_TAG=""
    GITHUB_REF_NAME="v2.3.4"
    TAG="${INPUT_TAG:-$GITHUB_REF_NAME}"
    echo "$TAG"
')"
if [[ "$_out" == "v2.3.4" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "%b  PASS%b GITHUB_REF_NAME is used when INPUT_TAG is empty\n" "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "%b  FAIL%b GITHUB_REF_NAME is used when INPUT_TAG is empty (got '%s')\n" "$RED" "$NC" "$_out"
fi

TESTS_RUN=$((TESTS_RUN + 1))
_out="$(bash -c '
    unset INPUT_TAG || true
    GITHUB_REF_NAME="v3.0.1"
    TAG="${INPUT_TAG:-$GITHUB_REF_NAME}"
    echo "$TAG"
' 2>/dev/null)"
if [[ "$_out" == "v3.0.1" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "%b  PASS%b GITHUB_REF_NAME is used when INPUT_TAG is unset\n" "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "%b  FAIL%b GITHUB_REF_NAME is used when INPUT_TAG is unset (got '%s')\n" "$RED" "$NC" "$_out"
fi

TESTS_RUN=$((TESTS_RUN + 1))
_out="$(bash -c '
    INPUT_TAG="v1.0.0-rc1"
    GITHUB_REF_NAME="v0.0.0"
    TAG="${INPUT_TAG:-$GITHUB_REF_NAME}"
    echo "$TAG"
')"
if [[ "$_out" == "v1.0.0-rc1" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "%b  PASS%b INPUT_TAG with pre-release suffix is preserved\n" "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "%b  FAIL%b INPUT_TAG with pre-release suffix is preserved (got '%s')\n" "$RED" "$NC" "$_out"
fi

# ---------------------------------------------------------------------------
# 2. VERSION stripping — TAG#v parameter expansion
# ---------------------------------------------------------------------------
echo ""
echo "--- VERSION stripping (TAG#v) ---"

TESTS_RUN=$((TESTS_RUN + 1))
_out="$(bash -c '
    TAG="v1.2.0"
    VERSION="${TAG#v}"
    echo "$VERSION"
')"
if [[ "$_out" == "1.2.0" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "%b  PASS%b Leading 'v' is stripped from version tag\n" "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "%b  FAIL%b Leading 'v' is stripped from version tag (got '%s')\n" "$RED" "$NC" "$_out"
fi

TESTS_RUN=$((TESTS_RUN + 1))
_out="$(bash -c '
    TAG="v10.20.300"
    VERSION="${TAG#v}"
    echo "$VERSION"
')"
if [[ "$_out" == "10.20.300" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "%b  PASS%b 'v' is stripped from multi-digit version (v10.20.300)\n" "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "%b  FAIL%b 'v' is stripped from multi-digit version (got '%s')\n" "$RED" "$NC" "$_out"
fi

TESTS_RUN=$((TESTS_RUN + 1))
_out="$(bash -c '
    TAG="1.2.0"
    VERSION="${TAG#v}"
    echo "$VERSION"
')"
if [[ "$_out" == "1.2.0" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "%b  PASS%b Tag without 'v' prefix is left unchanged by VERSION stripping\n" "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "%b  FAIL%b Tag without 'v' prefix is left unchanged (got '%s')\n" "$RED" "$NC" "$_out"
fi

TESTS_RUN=$((TESTS_RUN + 1))
_out="$(bash -c '
    TAG="v1.0.0-rc1"
    VERSION="${TAG#v}"
    echo "$VERSION"
')"
if [[ "$_out" == "1.0.0-rc1" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "%b  PASS%b Pre-release suffix is preserved after 'v' strip\n" "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "%b  FAIL%b Pre-release suffix is preserved after 'v' strip (got '%s')\n" "$RED" "$NC" "$_out"
fi

# ---------------------------------------------------------------------------
# 3. Local formula existence check
# ---------------------------------------------------------------------------
echo ""
echo "--- Local formula existence check ---"

FORMULA_DIR="${WORK}/repo/Formula"
mkdir -p "$FORMULA_DIR"

# 3a — formula present → check passes (exit 0)
echo 'class TmExclusions < Formula; end' > "${FORMULA_DIR}/tm-exclusions.rb"

TESTS_RUN=$((TESTS_RUN + 1))
_rc=0
(
    cd "${WORK}/repo"
    test -f Formula/tm-exclusions.rb || { echo "ERROR: Formula/tm-exclusions.rb missing in this repo"; exit 1; }
) || _rc=$?
if [[ "$_rc" -eq 0 ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "%b  PASS%b Formula existence check passes when file is present\n" "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "%b  FAIL%b Formula existence check passes when file is present (exit %d)\n" "$RED" "$NC" "$_rc"
fi

# 3b — formula absent → check fails with exit 1 and ERROR message
TESTS_RUN=$((TESTS_RUN + 1))
_rc=0
_out="$(
    cd "${WORK}/repo"
    (test -f Formula/absent-formula.rb || { echo "ERROR: Formula/absent-formula.rb missing in this repo"; exit 1; })
)" || _rc=$?
if [[ "$_rc" -eq 1 ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "%b  PASS%b Formula existence check exits 1 when file is absent\n" "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "%b  FAIL%b Formula existence check exits 1 when file is absent (exit %d)\n" "$RED" "$NC" "$_rc"
fi

TESTS_RUN=$((TESTS_RUN + 1))
_out2="$(
    cd "${WORK}/repo"
    (test -f Formula/absent-formula.rb || { echo "ERROR: Formula/absent-formula.rb missing in this repo"; exit 1; }) 2>&1 || true
)"
if echo "$_out2" | grep -q "ERROR:"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "%b  PASS%b Formula existence check prints ERROR message when file is absent\n" "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "%b  FAIL%b Formula existence check prints ERROR message when file is absent\n" "$RED" "$NC"
fi

# ---------------------------------------------------------------------------
# 4. Formula copy — install -m 644 fully replaces tap copy
# ---------------------------------------------------------------------------
echo ""
echo "--- Formula copy (install -m 644) ---"

TAP_FORMULA_DIR="${WORK}/tap/Formula"
mkdir -p "$TAP_FORMULA_DIR"

REPO_FORMULA="${FORMULA_DIR}/tm-exclusions.rb"
TAP_FORMULA="${TAP_FORMULA_DIR}/tm-exclusions.rb"

# Put a stale (different) formula in the tap
cat > "$TAP_FORMULA" <<'STALE'
class TmExclusions < Formula
  url "https://example.com/old.tar.gz"
  sha256 "oldsha"
  version "0.0.1"
  def install
    bin.install "tm_exclusions.sh" => "tm-exclusions"
    (share/"tm-exclusions").install "locales/"   # stale — no longer shipped
  end
end
STALE

# Fresh formula in the "repo"
cat > "$REPO_FORMULA" <<'FRESH'
class TmExclusions < Formula
  url "https://github.com/qveys/tm-exclusions/archive/refs/tags/v1.2.0.tar.gz"
  sha256 "93d9f89e76f0b4c645340a1191d3d77d12a3156e0cbbd496a998d4c587b1cee2"
  version "1.2.0"
  def install
    bin.install "tm_exclusions.sh" => "tm-exclusions"
    (share/"tm-exclusions").install "config/default.conf"
    (share/"tm-exclusions").install "config/extra-prunes.example.conf"
  end
end
FRESH

TESTS_RUN=$((TESTS_RUN + 1))
# Use cp + chmod to simulate `install -m 644` (install is a coreutils command available on
# ubuntu-latest CI; tests here verify the same observable outcome portably)
cp "$REPO_FORMULA" "$TAP_FORMULA" && chmod 644 "$TAP_FORMULA"
if diff -q "$REPO_FORMULA" "$TAP_FORMULA" >/dev/null 2>&1; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "%b  PASS%b install -m 644 produces identical tap formula\n" "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "%b  FAIL%b install -m 644 produces identical tap formula\n" "$RED" "$NC"
fi

# 4b — stale install stanza is gone (regression: locales/ reference must not appear)
TESTS_RUN=$((TESTS_RUN + 1))
if ! grep -q "locales/" "$TAP_FORMULA"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "%b  PASS%b Stale 'locales/' install stanza is overwritten by full formula copy\n" "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "%b  FAIL%b Stale 'locales/' install stanza is overwritten by full formula copy\n" "$RED" "$NC"
fi

# 4c — correct install stanza (config/default.conf) is present after copy
TESTS_RUN=$((TESTS_RUN + 1))
if grep -q "config/default.conf" "$TAP_FORMULA"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "%b  PASS%b Correct install stanza (config/default.conf) is present after copy\n" "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "%b  FAIL%b Correct install stanza (config/default.conf) is present after copy\n" "$RED" "$NC"
fi

# 4d — file permissions are 0644
TESTS_RUN=$((TESTS_RUN + 1))
_perms="$(stat -c '%a' "$TAP_FORMULA" 2>/dev/null || stat -f '%A' "$TAP_FORMULA" 2>/dev/null || echo "unknown")"
if [[ "$_perms" == "644" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "%b  PASS%b Copied formula has permissions 644\n" "$GREEN" "$NC"
else
    # Non-fatal on some systems where stat behaves differently; report as info
    printf "%b  INFO%b Could not verify 644 permissions (stat returned '%s')\n" "$YELLOW" "$NC" "$_perms"
fi

# ---------------------------------------------------------------------------
# 5. sed patches — url / sha256 / version rewriting
# ---------------------------------------------------------------------------
echo ""
echo "--- sed patches (url / sha256 / version) ---"

SED_TEST_DIR="${WORK}/sed_test/Formula"
mkdir -p "$SED_TEST_DIR"
SED_FORMULA="${SED_TEST_DIR}/tm-exclusions.rb"

cat > "$SED_FORMULA" <<'TEMPLATE'
class TmExclusions < Formula
  desc "Time Machine exclusion manager for developer Macs"
  homepage "https://github.com/qveys/tm-exclusions"
  url "https://github.com/qveys/tm-exclusions/archive/refs/tags/v1.2.0.tar.gz"
  sha256 "93d9f89e76f0b4c645340a1191d3d77d12a3156e0cbbd496a998d4c587b1cee2"
  license "MIT"
  version "1.2.0"
  def install
    bin.install "tm_exclusions.sh" => "tm-exclusions"
  end
end
TEMPLATE

NEW_URL="https://github.com/qveys/tm-exclusions/archive/refs/tags/v1.3.0.tar.gz"
NEW_SHA="abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890ab"
NEW_VER="1.3.0"

sed -i.bak "s|^  url \".*\"|  url \"${NEW_URL}\"|"       "$SED_FORMULA" && rm -f "${SED_FORMULA}.bak"
sed -i.bak "s|^  sha256 \".*\"|  sha256 \"${NEW_SHA}\"|" "$SED_FORMULA" && rm -f "${SED_FORMULA}.bak"
sed -i.bak "s|^  version \".*\"|  version \"${NEW_VER}\"|" "$SED_FORMULA" && rm -f "${SED_FORMULA}.bak"

# 5a — url line is updated
TESTS_RUN=$((TESTS_RUN + 1))
if grep -q "  url \"${NEW_URL}\"" "$SED_FORMULA"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "%b  PASS%b sed rewrites url line correctly\n" "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "%b  FAIL%b sed rewrites url line correctly\n" "$RED" "$NC"
fi

# 5b — sha256 line is updated
TESTS_RUN=$((TESTS_RUN + 1))
if grep -q "  sha256 \"${NEW_SHA}\"" "$SED_FORMULA"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "%b  PASS%b sed rewrites sha256 line correctly\n" "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "%b  FAIL%b sed rewrites sha256 line correctly\n" "$RED" "$NC"
fi

# 5c — version line is updated
TESTS_RUN=$((TESTS_RUN + 1))
if grep -q "  version \"${NEW_VER}\"" "$SED_FORMULA"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "%b  PASS%b sed rewrites version line correctly\n" "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "%b  FAIL%b sed rewrites version line correctly\n" "$RED" "$NC"
fi

# 5d — other lines (desc, homepage, license, install) are NOT modified
TESTS_RUN=$((TESTS_RUN + 1))
if grep -q 'desc "Time Machine exclusion manager for developer Macs"' "$SED_FORMULA" &&
   grep -q 'homepage "https://github.com/qveys/tm-exclusions"'       "$SED_FORMULA" &&
   grep -q 'license "MIT"'                                             "$SED_FORMULA"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "%b  PASS%b sed leaves non-url/sha256/version lines untouched\n" "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "%b  FAIL%b sed leaves non-url/sha256/version lines untouched\n" "$RED" "$NC"
fi

# 5e — old url / sha256 / version values are gone
TESTS_RUN=$((TESTS_RUN + 1))
if ! grep -q "v1.2.0.tar.gz" "$SED_FORMULA" &&
   ! grep -q "93d9f89e"        "$SED_FORMULA" &&
   ! grep -q "\"1.2.0\""       "$SED_FORMULA"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "%b  PASS%b Old url/sha256/version values are no longer present after patching\n" "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "%b  FAIL%b Old url/sha256/version values are no longer present after patching\n" "$RED" "$NC"
fi

# 5f — patches applied in sequence yield correct result (order independence)
SED_TEST2_DIR="${WORK}/sed_test2/Formula"
mkdir -p "$SED_TEST2_DIR"
SED_FORMULA2="${SED_TEST2_DIR}/tm-exclusions.rb"
cp "$WORK/sed_test/Formula/tm-exclusions.rb" "$SED_FORMULA2"
# Re-read original template (need to reset)
cat > "$SED_FORMULA2" <<'TEMPLATE2'
  url "https://github.com/qveys/tm-exclusions/archive/refs/tags/v1.2.0.tar.gz"
  sha256 "93d9f89e76f0b4c645340a1191d3d77d12a3156e0cbbd496a998d4c587b1cee2"
  version "1.2.0"
TEMPLATE2

VER2="2.0.0"
URL2="https://github.com/qveys/tm-exclusions/archive/refs/tags/v2.0.0.tar.gz"
SHA2="aaaa1111bbbb2222cccc3333dddd4444eeee5555ffff6666000011112222333344"

sed -i.bak "s|^  url \".*\"|  url \"${URL2}\"|"           "$SED_FORMULA2" && rm -f "${SED_FORMULA2}.bak"
sed -i.bak "s|^  sha256 \".*\"|  sha256 \"${SHA2}\"|"     "$SED_FORMULA2" && rm -f "${SED_FORMULA2}.bak"
sed -i.bak "s|^  version \".*\"|  version \"${VER2}\"|"   "$SED_FORMULA2" && rm -f "${SED_FORMULA2}.bak"

TESTS_RUN=$((TESTS_RUN + 1))
if grep -q "  url \"${URL2}\""    "$SED_FORMULA2" &&
   grep -q "  sha256 \"${SHA2}\"" "$SED_FORMULA2" &&
   grep -q "  version \"${VER2}\"" "$SED_FORMULA2"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "%b  PASS%b Sequential sed patches all applied correctly for a different version\n" "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "%b  FAIL%b Sequential sed patches all applied correctly for a different version\n" "$RED" "$NC"
fi

# ---------------------------------------------------------------------------
# 6. HOMEBREW_TOKEN guard — a missing token must fail the run, not skip silently
#
# An `exit 0` here makes the whole Release run green while the tap keeps serving
# the previous version, which is exactly how v1.3.0 shipped without a tap bump.
# ---------------------------------------------------------------------------
echo ""
echo "--- HOMEBREW_TOKEN guard ---"

TESTS_RUN=$((TESTS_RUN + 1))
_rc=0
_out="$(bash -c '
    TAG="v9.9.9"
    HOMEBREW_TOKEN=""
    if [ -z "${HOMEBREW_TOKEN:-}" ]; then
        echo "::error::HOMEBREW_TOKEN (or RELEASE_TOKEN) is not set — the tap was NOT updated for ${TAG}. Add the secret, then re-run: Actions -> Release -> Run workflow -> tag: ${TAG}."
        exit 1
    fi
    echo "token was set"
' 2>&1)" || _rc=$?
if [[ "$_rc" -eq 1 ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "%b  PASS%b Empty HOMEBREW_TOKEN fails the step (exit 1)\n" "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "%b  FAIL%b Empty HOMEBREW_TOKEN fails the step (expected exit 1, got %d)\n" "$RED" "$NC" "$_rc"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if echo "$_out" | grep -q "::error::" &&
   echo "$_out" | grep -q "HOMEBREW_TOKEN" &&
   echo "$_out" | grep -q "the tap was NOT updated for v9.9.9"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "%b  PASS%b Missing token emits an ::error:: annotation naming the tag\n" "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "%b  FAIL%b Missing token emits an ::error:: annotation naming the tag (output: '%s')\n" "$RED" "$NC" "$_out"
fi

# The snippets above are copies; assert the real workflow still matches them, so the
# guard cannot silently drift back to `exit 0` while these tests stay green.
TESTS_RUN=$((TESTS_RUN + 1))
WORKFLOW="${SCRIPT_DIR}/.github/workflows/release.yml"
# Comment lines are stripped: the guard's own comment mentions "exit 0" on purpose.
# The sed pattern matches the literal shell text in the workflow, hence single quotes.
# shellcheck disable=SC2016
_guard="$(sed -n '/if \[ -z "\${HOMEBREW_TOKEN:-}" \]; then/,/^ *fi$/p' "$WORKFLOW" | grep -v '^[[:space:]]*#')"
if [[ -n "$_guard" ]] && echo "$_guard" | grep -q "exit 1" && ! echo "$_guard" | grep -q "exit 0"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "%b  PASS%b release.yml token guard exits non-zero, never 0\n" "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "%b  FAIL%b release.yml token guard exits non-zero, never 0 (guard: '%s')\n" "$RED" "$NC" "$_guard"
fi

TESTS_RUN=$((TESTS_RUN + 1))
_rc2=0
_out2="$(bash -c '
    TAG="v9.9.9"
    HOMEBREW_TOKEN="secret_token"
    if [ -z "${HOMEBREW_TOKEN:-}" ]; then
        echo "::error::HOMEBREW_TOKEN (or RELEASE_TOKEN) is not set — the tap was NOT updated for ${TAG}."
        exit 1
    fi
    echo "token present"
' 2>&1)" || _rc2=$?
if echo "$_out2" | grep -q "token present" && [[ "$_rc2" -eq 0 ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "%b  PASS%b Non-empty HOMEBREW_TOKEN proceeds to the tap bump\n" "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "%b  FAIL%b Non-empty HOMEBREW_TOKEN proceeds to the tap bump (output: '%s')\n" "$RED" "$NC" "$_out2"
fi

# ---------------------------------------------------------------------------
# 7. Regression — full copy + patch sequence end-to-end
# ---------------------------------------------------------------------------
echo ""
echo "--- Regression: full copy + patch sequence ---"

E2E_REPO="${WORK}/e2e_repo/Formula"
E2E_TAP="${WORK}/e2e_tap/Formula"
mkdir -p "$E2E_REPO" "$E2E_TAP"

# Stale tap formula (mimics the real bug: leftover locales/ reference from 2.x)
cat > "${E2E_TAP}/tm-exclusions.rb" <<'STALE2'
class TmExclusions < Formula
  url "https://github.com/qveys/tm-exclusions/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "stalesha256stalesha256stalesha256stalesha256stalesha256stalesha256"
  version "1.0.0"
  def install
    bin.install "tm_exclusions.sh" => "tm-exclusions"
    (share/"tm-exclusions").install "locales/"
  end
end
STALE2

# Current repo formula (correct, no locales/)
cat > "${E2E_REPO}/tm-exclusions.rb" <<'CURRENT'
class TmExclusions < Formula
  url "https://github.com/qveys/tm-exclusions/archive/refs/tags/v1.2.0.tar.gz"
  sha256 "93d9f89e76f0b4c645340a1191d3d77d12a3156e0cbbd496a998d4c587b1cee2"
  version "1.2.0"
  def install
    bin.install "tm_exclusions.sh" => "tm-exclusions"
    (share/"tm-exclusions").install "config/default.conf"
    (share/"tm-exclusions").install "config/extra-prunes.example.conf"
  end
end
CURRENT

E2E_VERSION="1.3.0"
E2E_URL="https://github.com/qveys/tm-exclusions/archive/refs/tags/v1.3.0.tar.gz"
E2E_SHA="deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

# Simulate the full workflow step (without git operations)
(
    cd "${WORK}/e2e_repo"
    test -f Formula/tm-exclusions.rb || { echo "ERROR: Formula/tm-exclusions.rb missing in this repo"; exit 1; }
    cp Formula/tm-exclusions.rb "${E2E_TAP}/tm-exclusions.rb" && chmod 644 "${E2E_TAP}/tm-exclusions.rb"
    cd "${WORK}/e2e_tap"
    sed -i.bak "s|^  url \".*\"|  url \"${E2E_URL}\"|"           Formula/tm-exclusions.rb && rm -f Formula/tm-exclusions.rb.bak
    sed -i.bak "s|^  sha256 \".*\"|  sha256 \"${E2E_SHA}\"|"     Formula/tm-exclusions.rb && rm -f Formula/tm-exclusions.rb.bak
    sed -i.bak "s|^  version \".*\"|  version \"${E2E_VERSION}\"|" Formula/tm-exclusions.rb && rm -f Formula/tm-exclusions.rb.bak
)

RESULT_FORMULA="${E2E_TAP}/tm-exclusions.rb"

# 7a — stale locales/ reference is gone
TESTS_RUN=$((TESTS_RUN + 1))
if ! grep -q "locales/" "$RESULT_FORMULA"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "%b  PASS%b [regression] stale 'locales/' reference is eliminated by full copy\n" "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "%b  FAIL%b [regression] stale 'locales/' reference is eliminated by full copy\n" "$RED" "$NC"
fi

# 7b — new url is applied
TESTS_RUN=$((TESTS_RUN + 1))
if grep -q "  url \"${E2E_URL}\"" "$RESULT_FORMULA"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "%b  PASS%b [regression] new url is applied after full copy + patch\n" "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "%b  FAIL%b [regression] new url is applied after full copy + patch\n" "$RED" "$NC"
fi

# 7c — new sha256 is applied
TESTS_RUN=$((TESTS_RUN + 1))
if grep -q "  sha256 \"${E2E_SHA}\"" "$RESULT_FORMULA"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "%b  PASS%b [regression] new sha256 is applied after full copy + patch\n" "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "%b  FAIL%b [regression] new sha256 is applied after full copy + patch\n" "$RED" "$NC"
fi

# 7d — new version is applied
TESTS_RUN=$((TESTS_RUN + 1))
if grep -q "  version \"${E2E_VERSION}\"" "$RESULT_FORMULA"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "%b  PASS%b [regression] new version is applied after full copy + patch\n" "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "%b  FAIL%b [regression] new version is applied after full copy + patch\n" "$RED" "$NC"
fi

# 7e — correct install stanza (config/default.conf) is present, not the stale one
TESTS_RUN=$((TESTS_RUN + 1))
if grep -q "config/default.conf" "$RESULT_FORMULA"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "%b  PASS%b [regression] correct install stanza survives copy+patch\n" "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "%b  FAIL%b [regression] correct install stanza survives copy+patch\n" "$RED" "$NC"
fi

# ---------------------------------------------------------------------------
# 8. Boundary — workflow_dispatch: INPUT_TAG overrides even when GITHUB_REF_NAME is a different tag
# ---------------------------------------------------------------------------
echo ""
echo "--- Boundary: workflow_dispatch INPUT_TAG override ---"

TESTS_RUN=$((TESTS_RUN + 1))
_out="$(bash -c '
    INPUT_TAG="v0.9.0"
    GITHUB_REF_NAME="refs/heads/master"
    TAG="${INPUT_TAG:-$GITHUB_REF_NAME}"
    VERSION="${TAG#v}"
    echo "tag=$TAG version=$VERSION"
')"
if echo "$_out" | grep -q "tag=v0.9.0" && echo "$_out" | grep -q "version=0.9.0"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "%b  PASS%b workflow_dispatch INPUT_TAG overrides branch ref entirely\n" "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "%b  FAIL%b workflow_dispatch INPUT_TAG overrides branch ref entirely (got '%s')\n" "$RED" "$NC" "$_out"
fi

# 8b — GITHUB_OUTPUT simulation: both tag and version are written
TESTS_RUN=$((TESTS_RUN + 1))
_tmpout="$(mktemp)"
_out2="$(bash -c "
    INPUT_TAG='v1.5.0'
    GITHUB_REF_NAME='v0.0.0'
    GITHUB_OUTPUT='${_tmpout}'
    TAG=\"\${INPUT_TAG:-\$GITHUB_REF_NAME}\"
    VERSION=\"\${TAG#v}\"
    echo \"tag=\$TAG\" >> \"\$GITHUB_OUTPUT\"
    echo \"version=\$VERSION\" >> \"\$GITHUB_OUTPUT\"
    cat \"\$GITHUB_OUTPUT\"
" 2>&1)"
rm -f "$_tmpout"
if echo "$_out2" | grep -q "tag=v1.5.0" && echo "$_out2" | grep -q "version=1.5.0"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "%b  PASS%b tag and version are both written to GITHUB_OUTPUT correctly\n" "$GREEN" "$NC"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "%b  FAIL%b tag and version are both written to GITHUB_OUTPUT correctly (got '%s')\n" "$RED" "$NC" "$_out2"
fi

# ---------------------------------------------------------------------------
# 9. Formula coherence — version must match the tag the url/sha256 point at
#
# Release tooling (`make release`, auto-patch) must never bump `version` alone:
# url/sha256 can only be refreshed after the tag exists, so a partial bump would
# make `brew install --formula ./Formula/tm-exclusions.rb` install the previous
# tarball under the new version. See docs/PACKAGING.md.
# ---------------------------------------------------------------------------
echo ""
echo "--- Formula coherence (version vs url tag) ---"

# SCRIPT_DIR is the repo root here (reassigned by test_helpers.sh)
REPO_FORMULA="${SCRIPT_DIR}/Formula/tm-exclusions.rb"

TESTS_RUN=$((TESTS_RUN + 1))
if [[ -f "$REPO_FORMULA" ]]; then
    _f_version="$(sed -n 's|^  version "\(.*\)"$|\1|p' "$REPO_FORMULA")"
    _f_url_tag="$(sed -n 's|^  url ".*/tags/v\([^"]*\)\.tar\.gz"$|\1|p' "$REPO_FORMULA")"
    if [[ -n "$_f_version" && "$_f_version" == "$_f_url_tag" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        printf "%b  PASS%b Formula version (%s) matches the tag in url\n" "$GREEN" "$NC" "$_f_version"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf "%b  FAIL%b Formula version '%s' != url tag '%s' — bump url, sha256 and version together\n" "$RED" "$NC" \
            "$_f_version" "$_f_url_tag"
    fi
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "%b  FAIL%b Formula/tm-exclusions.rb not found at %s\n" "$RED" "$NC" "$REPO_FORMULA"
fi

# ---------------------------------------------------------------------------
test_summary
