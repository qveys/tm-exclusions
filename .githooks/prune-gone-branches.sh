#!/bin/sh
# prune-gone-branches.sh — remove local branches tracking deleted remotes.
#
# Behavior:
# - Deletes only branches whose upstream state is "[gone]".
# - Never touches the currently checked out branch.
# - Uses safe delete (-d): unmerged branches are kept.

set -u

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

current_branch=$(git branch --show-current 2>/dev/null || printf '')

git for-each-ref --format='%(refname:short) %(upstream:track)' refs/heads 2>/dev/null | while read -r line; do
  case "$line" in
    *' [gone]')
      branch="${line% [gone]}"
      ;;
    *)
      continue
      ;;
  esac

  if [ "$branch" = "$current_branch" ]; then
    continue
  fi

  if git branch -d -- "$branch" >/dev/null 2>&1; then
    printf '🧹 pruned local gone branch: %s\n' "$branch"
  else
    printf '⚠️  skipped unmerged gone branch: %s\n' "$branch" >&2
  fi
done
exit 0
