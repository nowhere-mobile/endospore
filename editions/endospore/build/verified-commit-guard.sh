#!/bin/sh
# verified-commit-guard.sh <repo> <verified-commit> -- refuse a --release unless the checkout IS the verified commit.
#
# 2026090110 and 2026090201 signed an old commit after the build host's pull aborted on a stray file (four merged
# fixes missing the second time), and main moving between the build pass and --release signs code nobody verified
# (Q094, docs/product-decisions.md). build-device.sh --release calls this before anything is written or prompted.
#
#   0  <commit> is HEAD and no tracked file is modified (prints one line on stdout)
#   1  HEAD is not the verified commit, or N tracked file(s) are modified
#   2  usage, <commit> not 7-40 lowercase hex, <repo> not a git checkout, or the commit is unknown to it
#
# Writes nothing. POSIX sh: it runs under bash, dash and mksh.
set -u
[ "$#" -eq 2 ] || { echo "usage: verified-commit-guard.sh <repo> <verified-commit>" >&2; exit 2; }
REPO="$1"; C="$2"
case "$C" in '' | *[!0-9a-f]* ) echo "verified-commit-guard: '$C' is not a 7-40 character lowercase hex commit" >&2; exit 2 ;; esac
if [ "${#C}" -lt 7 ] || [ "${#C}" -gt 40 ]; then echo "verified-commit-guard: '$C' is not a 7-40 character lowercase hex commit" >&2; exit 2; fi
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || { echo "verified-commit-guard: $REPO is not a git checkout" >&2; exit 2; }
FULL=$(git -C "$REPO" rev-parse --verify --quiet "$C^{commit}") || { echo "verified-commit-guard: commit $C is unknown to $REPO (or ambiguous)" >&2; exit 2; }
HEAD=$(git -C "$REPO" rev-parse --verify HEAD) || { echo "verified-commit-guard: cannot read HEAD of $REPO" >&2; exit 2; }
if [ "$FULL" != "$HEAD" ]; then
  echo "REFUSING --release: $REPO is at $HEAD, not the verified commit $FULL." >&2
  echo "    Either main moved after you verified, or the build host's pull aborted (a stray file) and left an old commit." >&2
  echo "    Check out the verified commit, or verify the new HEAD and pass that." >&2
  exit 1
fi
# Untracked files are allowed on purpose: a stray one is what aborts the pull, and HEAD then differs (caught above).
DIRTY=$(git -C "$REPO" status --porcelain --untracked-files=no) || { echo "verified-commit-guard: git status failed in $REPO" >&2; exit 2; }
if [ -n "$DIRTY" ]; then
  N=$(printf '%s\n' "$DIRTY" | wc -l | tr -d ' ')
  echo "REFUSING --release: $N tracked file(s) modified in $REPO -- the signed tree would not be the verified commit." >&2
  exit 1
fi
echo "verified commit $FULL is HEAD, tree clean"
