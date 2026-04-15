#!/bin/sh
# Central commit message format definition.
# Sourced (not executed) by every hook and the CI validation workflow so
# that the allowed types and validation regex are defined in one place.
#
# Usage (in any POSIX sh script or CI step):
#   REPO=$(git rev-parse --show-toplevel)
#   . "$REPO/.githooks/commit-format.sh"
#   # CC_TYPES and CC_PATTERN are now available.
#
# POSIX sh compliant — no bashisms.

# ---------------------------------------------------------------------------
# Pipe-separated list of allowed Conventional Commits types.
# Used both in the validation regex and in human-readable error messages.
# ---------------------------------------------------------------------------
CC_TYPES='feat|fix|docs|style|refactor|perf|test|chore|ci|build|revert'

# ---------------------------------------------------------------------------
# Full validation regex.
# Requires:
#   - At least one leading non-ASCII byte  (the emoji)
#   - Followed by a space
#   - Then a valid CC type from $CC_TYPES
#   - Optional (scope), optional ! breaking-change marker
#   - ": " separator
#   - A non-empty description with no trailing whitespace
#
# Must be used with LC_ALL=C grep for byte-level matching:
#   LC_ALL=C ensures [^ -~] covers all multi-byte UTF-8 sequences by
#   matching any byte outside the printable ASCII range (0x20–0x7E).
#
# Example usage:
#   printf '%s' "$msg" | LC_ALL=C grep -qE "$CC_PATTERN"
# ---------------------------------------------------------------------------
CC_PATTERN='^[^ -~][^ -~]* ('"$CC_TYPES"')(\([^)]+\))?(!)?: .*[^[:space:]]$'