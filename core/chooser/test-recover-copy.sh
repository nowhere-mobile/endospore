#!/usr/bin/env bash
# test-recover-copy.sh [<ChooserActivity.java> <recovery.md>] [--mutate] -- the Reset passphrase screen says a reset
# is for a FORGOTTEN passphrase and does not lock out the old one, and docs/recovery.md no longer calls the old
# ref_pass "orphaned and harmless" (decided 2026-09-15, docs/product-decisions.md; backlog row "A passphrase
# recovery CANNOT revoke the old passphrase"). The screen names no profile.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MUTATE=0; args=()
for a in "$@"; do [ "$a" = "--mutate" ] && MUTATE=1 || args+=("$a"); done
JAVA="${args[0]:-$here/src/com/nowhere/chooser/ChooserActivity.java}"
DOC="${args[1]:-$here/../../docs/recovery.md}"
SENT="This is for a forgotten passphrase. If someone else may know your passphrase, sign in and change it instead — a reset does not lock out the old one."

# check <java> <doc>: prints failures, returns non-zero if any.
check() {
  local java="$1" doc="$2" fail=0 body joined
  body="$(awk '/private View buildRecoverScreen\(\)/{f=1} f{print} f&&/^    }$/{exit}' "$java")"
  # join adjacent string literals ("a " + "b") so the sentence may be wrapped across source lines
  joined="$(printf '%s\n' "$body" | tr -d '\n' | sed 's/"[[:space:]]*+[[:space:]]*"//g')"
  case "$joined" in *"$SENT"*) ;; *) echo "FAIL: buildRecoverScreen lacks the forgotten-passphrase sentence"; fail=1;; esac
  if grep -q 'orphaned and harmless' "$doc"; then echo "FAIL: recovery.md still says 'orphaned and harmless'"; fail=1; fi
  grep -q 'Recovery is for a FORGOTTEN passphrase only' "$doc" || { echo "FAIL: recovery.md lacks the forgotten-only statement"; fail=1; }
  return $fail
}

if [ "$MUTATE" = 0 ]; then
  out="$(check "$JAVA" "$DOC")" && { echo "ok: recover copy pinned"; exit 0; }
  echo "$out"; exit 1
fi

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
bad=0
run_mutant() { # name java doc
  local out
  if out="$(check "$2" "$3")"; then echo "SURVIVED: $1"; bad=1; else echo "convicted: $1"; fi
}
sed 's/a reset does not lock out the old one/a reset is fine/' "$JAVA" > "$tmp/j1.java"
run_mutant "screen sentence altered" "$tmp/j1.java" "$DOC"
sed 's/This is for a forgotten passphrase\. //' "$JAVA" > "$tmp/j2.java"
run_mutant "screen forgotten-only clause dropped" "$tmp/j2.java" "$DOC"
{ cat "$DOC"; echo "The old ref_pass is orphaned and harmless."; } > "$tmp/d1.md"
run_mutant "doc regains 'orphaned and harmless'" "$JAVA" "$tmp/d1.md"
sed 's/Recovery is for a FORGOTTEN passphrase only/Recovery is for anything/' "$DOC" > "$tmp/d2.md"
run_mutant "doc forgotten-only statement dropped" "$JAVA" "$tmp/d2.md"
for f in j1.java j2.java; do cmp -s "$tmp/$f" "$JAVA" && { echo "FAIL: mutant $f did not apply"; bad=1; }; done
cmp -s "$tmp/d2.md" "$DOC" && { echo "FAIL: mutant d2.md did not apply"; bad=1; }
exit $bad
