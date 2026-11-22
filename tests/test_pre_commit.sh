#!/usr/bin/env bash
# test_pre_commit.sh — Tests for .githooks/pre-commit (staged-file lint hook)
#
# Every scenario runs in a throwaway git repository (mktemp -d) with an
# isolated HOME / global git config: the real repository and the user's git
# configuration are never touched.
#
# Run: bash tests/test_pre_commit.sh

set -euo pipefail

PRE_COMMIT_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/test_helpers.sh
source "${PRE_COMMIT_TEST_DIR}/test_helpers.sh"

HOOK_SRC="${ROOT}/.githooks/pre-commit"
CHECK_CONF_SRC="${ROOT}/scripts/check-conf.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Isolate git from the user's / system configuration and from any outer repo
# (e.g. when this suite is itself run from inside a git hook).
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX
export HOME="${WORK}/home"
mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL="${WORK}/gitconfig"
: > "$GIT_CONFIG_GLOBAL"
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@example.invalid"
export GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@example.invalid"

echo "pre-commit hook tests"
echo "========================================"

assert_true "hook exists and is executable (.githooks/pre-commit)" test -x "$HOOK_SRC"
if [[ ! -x "$HOOK_SRC" ]]; then
    test_summary
fi

# --- fake shellcheck ---------------------------------------------------------
# Records every call and fails for any file containing the marker SC_FAIL, so
# the hook plumbing (which files, which options) is tested deterministically,
# independent of the installed ShellCheck version.
STUB_BIN="${WORK}/stubbin"
STUB_LOG="${WORK}/stub.log"
mkdir -p "$STUB_BIN"
cat > "${STUB_BIN}/shellcheck" <<'EOF'
#!/bin/sh
for last; do :; done
{
  printf 'ARGS: %s\n' "$*"
  if [ -f "$last" ]; then printf 'EXISTS: yes\n'; else printf 'EXISTS: no\n'; fi
} >> "$STUB_LOG"
if grep -q SC_FAIL < "$last" 2>/dev/null; then
  echo "stub-shellcheck: SC_FAIL found in $last" >&2
  exit 1
fi
exit 0
EOF
chmod +x "${STUB_BIN}/shellcheck"
export STUB_LOG

ORIG_PATH="$PATH"
STUB_PATH="${STUB_BIN}:${ORIG_PATH}"

# PATH with the usual tools but NO shellcheck, to exercise the missing case.
NOSC_BIN="${WORK}/nosc-bin"
mkdir -p "$NOSC_BIN"
for tool in bash sh env git head tr mktemp rm dirname basename grep cat sed \
            mkdir sort uname expr cut awk wc ls date; do
    # First real executable on PATH (skip wrapper shims such as a git harness
    # that look for the real tool further down PATH).
    tool_path=""
    IFS=: read -r -a path_dirs <<< "$ORIG_PATH"
    for dir in "${path_dirs[@]}"; do
        case "$dir" in *claude-gh-harness*) continue ;; esac
        if [[ -n "$dir" && -x "${dir}/${tool}" && ! -d "${dir}/${tool}" ]]; then
            tool_path="${dir}/${tool}"
            break
        fi
    done
    if [[ -n "$tool_path" ]]; then
        ln -s "$tool_path" "${NOSC_BIN}/${tool}"
    fi
done

# --- helpers -----------------------------------------------------------------
HOOK_RC=0
HOOK_OUT=""

# Run the hook (as `bash <hook>`) from a working directory with a given PATH.
# Usage: run_hook <cwd> <hook> <path>
run_hook() {
    local cwd="$1" hook="$2" path="$3"
    : > "$STUB_LOG"
    HOOK_RC=0
    HOOK_OUT="$(cd "$cwd" && PATH="$path" bash "$hook" 2>&1)" || HOOK_RC=$?
}

# Predicates below are invoked indirectly through assert_true.
# shellcheck disable=SC2329
out_has() {
    case "$HOOK_OUT" in *"$1"*) return 0 ;; esac
    return 1
}
# shellcheck disable=SC2329
sc_called() { # sc_called <dialect> <file>: shellcheck was run on <file> with -x -s <dialect>
    grep -Eq -- "^ARGS: -x -s $1 -P SCRIPTDIR -P .* -- $2\$" "$STUB_LOG"
}
# shellcheck disable=SC2329
log_has() { grep -Fq -- "$1" "$STUB_LOG"; }

# Create a repo with the hook, check-conf and two locale files committed.
# Prints the repo path.
new_repo() {
    local repo
    repo="$(mktemp -d "${WORK}/repo.XXXXXX")"
    mkdir -p "${repo}/.githooks" "${repo}/scripts" "${repo}/locales" "${repo}/sub/dir"
    git init -q "$repo" 2>/dev/null
    cp "$HOOK_SRC" "${repo}/.githooks/pre-commit"
    cp "$CHECK_CONF_SRC" "${repo}/scripts/check-conf.sh"
    printf 'MSG_A="a"\n' > "${repo}/locales/en.sh"
    printf 'MSG_A="a"\n' > "${repo}/locales/fr.sh"
    printf '#!/usr/bin/env bash\necho ok\n' > "${repo}/ok.sh"
    printf '#!/usr/bin/env bash\necho SC_FAIL\n' > "${repo}/bad.sh"
    (
        cd "$repo"
        git add -A
        git commit -q --no-verify -m init
    )
    printf '%s' "$repo"
}

stage() { # stage <repo> <path...>
    local repo="$1"
    shift
    (cd "$repo" && git add -- "$@")
}

CLEAN_SH=$'#!/usr/bin/env bash\necho "clean"\n'
BAD_SH=$'#!/usr/bin/env bash\necho SC_FAIL\n'
GOOD_CONF=$'# comment\npath|$HOME/.cache/x|regenerable cache\n'
BAD_CONF=$'bogus|nothing|reason\n'

echo ""
echo "--- Staged shell scripts (stub shellcheck) ---"

repo="$(new_repo)"
printf '%s' "$CLEAN_SH" > "${repo}/new.sh"
stage "$repo" new.sh
run_hook "$repo" "${repo}/.githooks/pre-commit" "$STUB_PATH"
assert_eq 0 "$HOOK_RC" "clean staged .sh: exit 0"
assert_true "clean staged .sh: shellcheck called with -x -s bash" sc_called bash "new.sh"

repo="$(new_repo)"
printf '%s' "$BAD_SH" > "${repo}/new.sh"
stage "$repo" new.sh
run_hook "$repo" "${repo}/.githooks/pre-commit" "$STUB_PATH"
assert_eq 1 "$HOOK_RC" "staged .sh failing ShellCheck: exit 1"
assert_true "staged .sh failing ShellCheck: message names the file" out_has "ShellCheck failed for new.sh"

repo="$(new_repo)"
printf '#!/bin/sh\necho posix\n' > "${repo}/posix.sh"
stage "$repo" posix.sh
run_hook "$repo" "${repo}/.githooks/pre-commit" "$STUB_PATH"
assert_true "POSIX-sh shebang script: shellcheck called with -s sh" sc_called sh "posix.sh"

repo="$(new_repo)"
printf '%s' "$BAD_SH" > "${repo}/bad.sh"
printf '%s' "$CLEAN_SH" > "${repo}/other.sh"
stage "$repo" other.sh
run_hook "$repo" "${repo}/.githooks/pre-commit" "$STUB_PATH"
assert_eq 0 "$HOOK_RC" "modified-but-NOT-staged bad .sh is ignored: exit 0"
assert_true "unstaged bad .sh never passed to shellcheck" not log_has "bad.sh"
assert_true "only the staged .sh is passed to shellcheck" log_has "other.sh"

repo="$(new_repo)"
printf '%s' "$BAD_SH" > "${repo}/untracked.sh"
run_hook "$repo" "${repo}/.githooks/pre-commit" "$STUB_PATH"
assert_eq 0 "$HOOK_RC" "untracked bad .sh with empty index: exit 0"
assert_true "empty index: shellcheck never called" not log_has "ARGS"

repo="$(new_repo)"
(cd "$repo" && git rm -q bad.sh)
run_hook "$repo" "${repo}/.githooks/pre-commit" "$STUB_PATH"
assert_eq 0 "$HOOK_RC" "staged DELETION of a bad .sh is ignored: exit 0"
assert_true "deleted file never passed to shellcheck" not log_has "bad.sh"

repo="$(new_repo)"
(cd "$repo" && git mv ok.sh renamed.sh)
run_hook "$repo" "${repo}/.githooks/pre-commit" "$STUB_PATH"
assert_eq 0 "$HOOK_RC" "staged rename: exit 0"
assert_true "staged rename: new name is checked" sc_called bash "renamed.sh"

repo="$(new_repo)"
printf '%s' "$CLEAN_SH" > "${repo}/my script.sh"
printf '%s' "$BAD_SH" > "${repo}/-dash.sh"
stage "$repo" "my script.sh" "-dash.sh"
run_hook "$repo" "${repo}/.githooks/pre-commit" "$STUB_PATH"
assert_eq 1 "$HOOK_RC" "file names with a space / leading dash handled (bad one fails)"
assert_true "name with a space reaches shellcheck intact" sc_called bash "my script.sh"
assert_true "leading-dash name reaches shellcheck after --" sc_called bash "-dash.sh"
assert_true "every checked file exists for shellcheck" not log_has "EXISTS: no"

repo="$(new_repo)"
nl_name=$'we\nird.sh'
printf '%s' "$CLEAN_SH" > "${repo}/${nl_name}"
stage "$repo" "$nl_name"
run_hook "$repo" "${repo}/.githooks/pre-commit" "$STUB_PATH"
assert_eq 0 "$HOOK_RC" "file name containing a newline: exit 0"
assert_true "newline name passed as ONE existing file" log_has "EXISTS: yes"
assert_true "newline name is not split into fragments" not log_has "EXISTS: no"

echo ""
echo "--- Staged config files ---"

repo="$(new_repo)"
mkdir -p "${repo}/config"
printf '%s' "$GOOD_CONF" > "${repo}/config/x.conf"
stage "$repo" config/x.conf
run_hook "$repo" "${repo}/.githooks/pre-commit" "$STUB_PATH"
assert_eq 0 "$HOOK_RC" "valid staged .conf: exit 0"

repo="$(new_repo)"
mkdir -p "${repo}/config"
printf '%s' "$BAD_CONF" > "${repo}/config/x.conf"
stage "$repo" config/x.conf
run_hook "$repo" "${repo}/.githooks/pre-commit" "$STUB_PATH"
assert_eq 1 "$HOOK_RC" "invalid staged .conf: exit 1"
assert_true "invalid .conf: validator error with file:line shown" out_has "config/x.conf:1: error"
assert_true "invalid .conf: summary message shown" out_has "config validation failed"

repo="$(new_repo)"
mkdir -p "${repo}/config"
printf '%s' "$BAD_CONF" > "${repo}/config/x.conf"
run_hook "$repo" "${repo}/.githooks/pre-commit" "$STUB_PATH"
assert_eq 0 "$HOOK_RC" "invalid but NOT staged .conf is ignored: exit 0"

repo="$(new_repo)"
printf '%s' "$GOOD_CONF" > "${repo}/my conf.conf"
printf '%s' "$BAD_CONF" > "${repo}/other.conf"
stage "$repo" "my conf.conf"
run_hook "$repo" "${repo}/.githooks/pre-commit" "$STUB_PATH"
assert_eq 0 "$HOOK_RC" ".conf with a space staged, bad one unstaged: exit 0"

echo ""
echo "--- Locale sync reminder ---"

repo="$(new_repo)"
printf 'MSG_A="a"\nMSG_B="b"\n' > "${repo}/locales/en.sh"
stage "$repo" locales/en.sh
run_hook "$repo" "${repo}/.githooks/pre-commit" "$STUB_PATH"
assert_eq 0 "$HOOK_RC" "only locales/en.sh staged: exit 0 (reminder never blocks)"
assert_true "reminder names the missing sibling locale" out_has "locales/fr.sh"
assert_true "reminder points to make check-i18n" out_has "make check-i18n"
assert_true "locale files are not run through shellcheck" not log_has "locales/"

repo="$(new_repo)"
printf 'MSG_A="a"\nMSG_B="b"\n' > "${repo}/locales/en.sh"
printf 'MSG_A="a"\nMSG_B="b"\n' > "${repo}/locales/fr.sh"
stage "$repo" locales/en.sh locales/fr.sh
run_hook "$repo" "${repo}/.githooks/pre-commit" "$STUB_PATH"
assert_eq 0 "$HOOK_RC" "both locales staged: exit 0"
assert_true "both locales staged: no reminder" not out_has "reminder"

repo="$(new_repo)"
printf 'MSG_A="unterminated\n' > "${repo}/locales/en.sh"
printf 'MSG_A="a"\nMSG_B="b"\n' > "${repo}/locales/fr.sh"
stage "$repo" locales/en.sh locales/fr.sh
run_hook "$repo" "${repo}/.githooks/pre-commit" "$STUB_PATH"
assert_eq 1 "$HOOK_RC" "staged locale with a syntax error: exit 1 (bash -n)"

echo ""
echo "--- Staged content, not the working tree (stub shellcheck) ---"

# Index clean, working tree dirty: the commit would contain the clean blob.
repo="$(new_repo)"
printf '%s' "$CLEAN_SH" > "${repo}/new.sh"
stage "$repo" new.sh
printf '%s' "$BAD_SH" > "${repo}/new.sh"
run_hook "$repo" "${repo}/.githooks/pre-commit" "$STUB_PATH"
assert_eq 0 "$HOOK_RC" "clean index + dirty working tree: exit 0 (staged blob is clean)"

# Index dirty, working tree fixed: the commit would contain the bad blob.
repo="$(new_repo)"
printf '%s' "$BAD_SH" > "${repo}/new.sh"
stage "$repo" new.sh
printf '%s' "$CLEAN_SH" > "${repo}/new.sh"
run_hook "$repo" "${repo}/.githooks/pre-commit" "$STUB_PATH"
assert_eq 1 "$HOOK_RC" "dirty index + fixed working tree: exit 1 (staged blob is bad)"
assert_true "dirty index: message names the file" out_has "ShellCheck failed for new.sh"

# Staged file removed from the working tree afterwards: still checked.
repo="$(new_repo)"
printf '%s' "$BAD_SH" > "${repo}/new.sh"
stage "$repo" new.sh
rm -f "${repo}/new.sh"
run_hook "$repo" "${repo}/.githooks/pre-commit" "$STUB_PATH"
assert_eq 1 "$HOOK_RC" "staged .sh deleted from the working tree is still checked from the index"

# Same for config files and locale tables.
repo="$(new_repo)"
mkdir -p "${repo}/config"
printf '%s' "$BAD_CONF" > "${repo}/config/x.conf"
stage "$repo" config/x.conf
printf '%s' "$GOOD_CONF" > "${repo}/config/x.conf"
run_hook "$repo" "${repo}/.githooks/pre-commit" "$STUB_PATH"
assert_eq 1 "$HOOK_RC" "dirty staged .conf + fixed working tree: exit 1"

repo="$(new_repo)"
mkdir -p "${repo}/config"
printf '%s' "$GOOD_CONF" > "${repo}/config/x.conf"
stage "$repo" config/x.conf
printf '%s' "$BAD_CONF" > "${repo}/config/x.conf"
run_hook "$repo" "${repo}/.githooks/pre-commit" "$STUB_PATH"
assert_eq 0 "$HOOK_RC" "valid staged .conf + dirty working tree: exit 0"

repo="$(new_repo)"
printf 'MSG_A="unterminated\n' > "${repo}/locales/en.sh"
printf 'MSG_A="a"\n' > "${repo}/locales/fr.sh"
stage "$repo" locales/en.sh locales/fr.sh
printf 'MSG_A="a"\n' > "${repo}/locales/en.sh"
run_hook "$repo" "${repo}/.githooks/pre-commit" "$STUB_PATH"
assert_eq 1 "$HOOK_RC" "staged locale with a syntax error + fixed working tree: exit 1"

# Partially staged file via a real `git commit -a` (alternate index file).
repo="$(new_repo)"
git -C "$repo" config core.hooksPath .githooks
printf '%s' "$BAD_SH" > "${repo}/ok.sh"
commit_rc=0
(cd "$repo" && PATH="$STUB_PATH" git commit -q -a -m "bad via -a" >/dev/null 2>&1) || commit_rc=$?
assert_eq 1 "$commit_rc" "git commit -a: modified tracked bad .sh is checked and blocks"
assert_eq "init" "$(git -C "$repo" log -1 --format=%s)" "git commit -a: HEAD untouched after the block"

echo ""
echo "--- Nothing relevant staged ---"

repo="$(new_repo)"
printf 'hello\n' > "${repo}/README.md"
stage "$repo" README.md
run_hook "$repo" "${repo}/.githooks/pre-commit" "$STUB_PATH"
assert_eq 0 "$HOOK_RC" "only a non-.sh/.conf file staged: exit 0"
assert_true "no relevant file: silent" test -z "$HOOK_OUT"
assert_true "no relevant file: shellcheck never called" not log_has "ARGS"

echo ""
echo "--- ShellCheck missing (non-blocking warning) ---"

repo="$(new_repo)"
printf '%s' "$BAD_SH" > "${repo}/new.sh"
stage "$repo" new.sh
run_hook "$repo" "${repo}/.githooks/pre-commit" "$NOSC_BIN"
assert_eq 0 "$HOOK_RC" "shellcheck absent: exit 0 (does not block)"
assert_true "shellcheck absent: clear warning" out_has "shellcheck not installed"

repo="$(new_repo)"
mkdir -p "${repo}/config"
printf '%s' "$BAD_CONF" > "${repo}/config/x.conf"
stage "$repo" config/x.conf
run_hook "$repo" "${repo}/.githooks/pre-commit" "$NOSC_BIN"
assert_eq 1 "$HOOK_RC" "shellcheck absent: invalid .conf still blocks"

echo ""
echo "--- Working directory and worktree ---"

repo="$(new_repo)"
printf '%s' "$BAD_SH" > "${repo}/new.sh"
stage "$repo" new.sh
run_hook "${repo}/sub/dir" "${repo}/.githooks/pre-commit" "$STUB_PATH"
assert_eq 1 "$HOOK_RC" "run from a repo subdirectory: still finds staged files"
assert_true "subdirectory run: path is repo-root relative" sc_called bash "new.sh"

repo="$(new_repo)"
WT="${repo}-wt"
(cd "$repo" && git worktree add -q -b wt-branch "$WT" 2>/dev/null)
mkdir -p "${WT}/sub/dir"
printf '%s' "$BAD_SH" > "${WT}/new.sh"
stage "$WT" new.sh
run_hook "${WT}/sub/dir" "${WT}/.githooks/pre-commit" "$STUB_PATH"
assert_eq 1 "$HOOK_RC" "linked worktree, run from a subdirectory: blocks bad .sh"
assert_true "worktree: staged file reached shellcheck" sc_called bash "new.sh"

echo ""
echo "--- Through a real 'git commit' (core.hooksPath) ---"

repo="$(new_repo)"
git -C "$repo" config core.hooksPath .githooks
printf '%s' "$BAD_SH" > "${repo}/new.sh"
stage "$repo" new.sh
commit_rc=0
(cd "$repo" && PATH="$STUB_PATH" git commit -q -m "add bad script" >/dev/null 2>&1) || commit_rc=$?
assert_eq 1 "$commit_rc" "git commit is blocked when the hook fails"
assert_eq "init" "$(git -C "$repo" log -1 --format=%s)" "blocked commit left HEAD untouched"
commit_rc=0
(cd "$repo" && PATH="$STUB_PATH" git commit -q --no-verify -m "add bad script" >/dev/null 2>&1) || commit_rc=$?
assert_eq 0 "$commit_rc" "git commit --no-verify bypasses the hook"
assert_eq "add bad script" "$(git -C "$repo" log -1 --format=%s)" "--no-verify commit was created"

echo ""
echo "--- make bootstrap / make setup (core.hooksPath) ---"

# A throwaway repo carrying the real Makefile and .githooks directory.
new_make_repo() {
    local repo
    repo="$(mktemp -d "${WORK}/mk.XXXXXX")"
    git init -q "$repo" 2>/dev/null
    cp "${ROOT}/Makefile" "${repo}/Makefile"
    cp -R "${ROOT}/.githooks" "${repo}/.githooks"
    printf '%s' "$repo"
}

# Run `make <target>` and capture only stderr in MK_ERR.
# Usage: run_make <repo> [VAR=value ...] <target>
MK_ERR=""
run_make() {
    local repo="$1"
    shift
    MK_ERR="$(cd "$repo" && PATH="$ORIG_PATH" make "$@" 2>&1 >/dev/null)" || true
}
# shellcheck disable=SC2329
mk_err_has() {
    case "$MK_ERR" in *"$1"*) return 0 ;; esac
    return 1
}
hooks_path() { git -C "$1" config --local --get core.hooksPath 2>/dev/null || true; }

if PATH="$ORIG_PATH" command -v make >/dev/null 2>&1; then
    # (1) A different local value is reported, then replaced; second pass is silent.
    mk="$(new_make_repo)"
    git -C "$mk" config core.hooksPath /tmp/custom-hooks-before
    run_make "$mk" help
    assert_eq ".githooks" "$(hooks_path "$mk")" "make: different local core.hooksPath is replaced by .githooks"
    assert_true "make: the previous value is reported on stderr" mk_err_has "/tmp/custom-hooks-before"
    run_make "$mk" help
    assert_true "make: second invocation is silent (idempotent)" test -z "$MK_ERR"
    run_make "$mk" setup
    assert_true "make setup: silent once core.hooksPath is .githooks" test -z "$MK_ERR"
    assert_eq ".githooks" "$(hooks_path "$mk")" "make setup: core.hooksPath stays .githooks"

    # (2) First bootstrap of a fresh repo is silent too.
    mk="$(new_make_repo)"
    run_make "$mk" help
    assert_true "make: fresh repo bootstrap is silent" test -z "$MK_ERR"
    assert_eq ".githooks" "$(hooks_path "$mk")" "make: fresh repo gets core.hooksPath = .githooks"

    # (3) The global configuration is never touched, and does not trigger a report.
    mk="$(new_make_repo)"
    printf '[core]\n\thooksPath = /global/hooks\n' > "$GIT_CONFIG_GLOBAL"
    cp "$GIT_CONFIG_GLOBAL" "${WORK}/gitconfig.before"
    run_make "$mk" help
    assert_true "make: global config file left byte-identical" cmp -s "$GIT_CONFIG_GLOBAL" "${WORK}/gitconfig.before"
    assert_eq ".githooks" "$(hooks_path "$mk")" "make: local core.hooksPath set despite a global value"
    assert_true "make: a global value is not reported as a replaced one" test -z "$MK_ERR"
    : > "$GIT_CONFIG_GLOBAL"

    # (4) Any make call re-enables the hooks after an unset (documented limit),
    #     unless TM_EXCLUSIONS_NO_HOOKS=1 skips the bootstrap.
    mk="$(new_make_repo)"
    run_make "$mk" help
    git -C "$mk" config --local --unset core.hooksPath
    run_make "$mk" help
    assert_eq ".githooks" "$(hooks_path "$mk")" "unset + any make call: core.hooksPath comes back (not a permanent opt-out)"
    git -C "$mk" config --local --unset core.hooksPath
    run_make "$mk" TM_EXCLUSIONS_NO_HOOKS=1 help
    assert_eq "" "$(hooks_path "$mk")" "TM_EXCLUSIONS_NO_HOOKS=1 make: bootstrap skipped"
    run_make "$mk" TM_EXCLUSIONS_NO_HOOKS=1 setup
    assert_eq ".githooks" "$(hooks_path "$mk")" "explicit make setup still installs the hooks under TM_EXCLUSIONS_NO_HOOKS=1"
else
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '%b  FAIL%b make is not installed: the bootstrap scenarios cannot run\n' "$RED" "$NC"
fi

echo ""
echo "--- Documentation of the opt-out limits ---"
for doc in README.md CONTRIBUTING.md CHANGELOG.md; do
    assert_file_lacks_regex "${ROOT}/${doc}" 'disable (it )?for good' "${doc}: no 'disable for good' claim"
done
for doc in README.md CONTRIBUTING.md CHANGELOG.md Makefile .githooks/pre-commit; do
    assert_file_contains "${ROOT}/${doc}" "TM_EXCLUSIONS_NO_HOOKS" "${doc}: documents the make-bootstrap limit and opt-out variable"
done
assert_file_lacks_regex "${ROOT}/.githooks/pre-commit" 'disable for good' "pre-commit header: no 'disable for good' claim"
assert_file_lacks_regex "${ROOT}/Makefile" 'disable: git config --unset' "make setup message: no unset-as-disable claim"

echo ""
echo "--- Real ShellCheck (when installed) ---"

if PATH="$ORIG_PATH" command -v shellcheck >/dev/null 2>&1; then
    repo="$(new_repo)"
    printf '%s' "$CLEAN_SH" > "${repo}/new.sh"
    stage "$repo" new.sh
    run_hook "$repo" "${repo}/.githooks/pre-commit" "$ORIG_PATH"
    assert_eq 0 "$HOOK_RC" "real shellcheck: clean staged .sh passes"

    repo="$(new_repo)"
    # shellcheck disable=SC2016
    printf '#!/usr/bin/env bash\necho $1\n' > "${repo}/new.sh"
    stage "$repo" new.sh
    run_hook "$repo" "${repo}/.githooks/pre-commit" "$ORIG_PATH"
    assert_eq 1 "$HOOK_RC" "real shellcheck: unquoted variable blocks the commit"
    assert_true "real shellcheck: diagnostic is shown" out_has "SC2086"

    # Staged content vs working tree, with the real ShellCheck (SC2086).
    repo="$(new_repo)"
    # shellcheck disable=SC2016
    printf '#!/usr/bin/env bash\necho "$1"\n' > "${repo}/new.sh"
    stage "$repo" new.sh
    # shellcheck disable=SC2016
    printf '#!/usr/bin/env bash\necho $1\n' > "${repo}/new.sh"
    run_hook "$repo" "${repo}/.githooks/pre-commit" "$ORIG_PATH"
    assert_eq 0 "$HOOK_RC" "real shellcheck: clean index + dirty working tree passes"

    repo="$(new_repo)"
    # shellcheck disable=SC2016
    printf '#!/usr/bin/env bash\necho $1\n' > "${repo}/new.sh"
    stage "$repo" new.sh
    # shellcheck disable=SC2016
    printf '#!/usr/bin/env bash\necho "$1"\n' > "${repo}/new.sh"
    run_hook "$repo" "${repo}/.githooks/pre-commit" "$ORIG_PATH"
    assert_eq 1 "$HOOK_RC" "real shellcheck: dirty index + fixed working tree blocks"
    assert_true "real shellcheck: SC2086 reported for the staged blob" out_has "SC2086"

    # A staged script sourcing a sibling file that is not staged (working tree).
    repo="$(new_repo)"
    printf 'helper() { echo helper; }\n' > "${repo}/lib.sh"
    printf '#!/usr/bin/env bash\n# shellcheck source=lib.sh\nsource ./lib.sh\nhelper\n' > "${repo}/uses-lib.sh"
    stage "$repo" uses-lib.sh
    run_hook "$repo" "${repo}/.githooks/pre-commit" "$ORIG_PATH"
    assert_eq 0 "$HOOK_RC" "real shellcheck: sourced non-staged file still resolves (-x)"
else
    echo "  SKIP real ShellCheck scenarios (shellcheck not installed; stubbed scenarios above still ran)"
fi

if [[ "$TESTS_RUN" -lt 70 ]]; then
    printf "${RED}  FAIL${NC} suite ran only %d assertions (expected at least 70)\n" "$TESTS_RUN"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

test_summary
