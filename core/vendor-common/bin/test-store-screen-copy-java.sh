#!/usr/bin/env bash
# test-store-screen-copy-java.sh [--mutate] -- the Store settings screen's status message (StoreScreenCopy), run under
# javac (NWP-20261113-21), and the S3 fields it hides on a managed phone (NWP-20261124-16).
#
# WHY THIS IS COMMITTED. Backlog row "Store settings on a managed (gateway) device says "no store yet — set one up" under
# its own "Managed store — connected" banner": the message was chosen from GET-STORE's keyset= alone, and a managed device
# has no keys, so it read as having no store. GET-STORE now ends with managed=; core/chooser/tests/store-screen-copy/run.sh
# runs StoreScreenCopyCases against StoreScreenCopy (managed never says "no store yet" nor mentions keys; the key-set and
# no-store strings are byte-identical to before; isError only for the key-set state) and pins that the store screen's
# GET-STORE thread renders through StoreScreenCopy with managed= and holds neither old literal itself.
# NWP-20261124-16 (decision #15, 2026-11-02, option A): a managed phone still showed empty S3 fields, Save store and
# Test connection under "This phone saves to the managed Nowhere store.", so the owner could save an endpoint over the
# managed configuration. StoreScreenCopy.showS3Fields / subtitle now decide it; run.sh pins that the GET-STORE thread
# hides the four plain fields, the secret's reveal wrapper, Save store and Test connection and sets the managed subtitle
# when showS3Fields(managed) is false, and that the initial build still shows every field (first run is unchanged).
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (exit 2), like the other javac suites.
#
# Mutants: S1 managed ignored in message(); S2 the store screen keeps the "no store yet" literal; S3 isError true for
# managed; S4 the store screen no longer reads managed=; S5 showS3Fields always true; S6 the secret's wrapper left
# visible (the bare field hidden instead); S7 Save store left visible; S8 Test connection left visible; S9 the
# visibility read from keyset, not managed; S10 the managed subtitle names the S3 store.
#
#   bash test-store-screen-copy-java.sh            # the cases
#   bash test-store-screen-copy-java.sh --mutate   # ... plus broken copies that must each FAIL the cases
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SC="$root/core/chooser/src/com/nowhere/chooser/StoreScreenCopy.java"
CH="$root/core/chooser/src/com/nowhere/chooser/ChooserActivity.java"
RUN="$root/core/chooser/tests/store-screen-copy/run.sh"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip: install a JDK or run it on the" \
       "build VM." >&2
  exit 2
fi
export JAVAC JAVA
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
[ -f "$SC" ] && [ -f "$CH" ] && [ -f "$RUN" ] || { echo "FAIL: missing $SC, $CH or $RUN" >&2; exit 2; }

# suite <StoreScreenCopy.java> <ChooserActivity.java> -> run.sh's code: 0 pass, 1 a case or pin failed (only this may
# convict a mutant), 2 the store screen did not extract, 3 the class or the cases did not compile.
suite() { TMPDIR="$W" bash "$RUN" "$1" "$2"; }

echo "== $SC + $CH"
suite "$SC" "$CH"; rc=$?
if [ "$rc" -ne 0 ]; then echo "FAILED (rc=$rc)"; [ "$rc" -eq 1 ] && exit 1 || exit 2; fi
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by behaviour; one that does not apply or compile is a failure)"
mut() { # mut <label> <sc|ch> <perl-expr>  -- the expression must change exactly one line of that file
  local d m src sc ch rc changed; d=$(mktemp -d -p "$W")
  case "$2" in sc) src="$SC"; m="$d/StoreScreenCopy.java" ;; ch) src="$CH"; m="$d/ChooserActivity.java" ;;
    *) echo "  ERROR     $1 -- unknown target $2"; rm -rf "$d"; return 1 ;; esac
  if ! perl -0pe "$3" "$src" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$src" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  changed=$(diff "$src" "$m" | grep -c '^>')
  if [ "$changed" -ne 1 ]; then echo "  ERROR     $1 -- the mutation changed $changed line(s), expected 1"; rm -rf "$d"; return 1; fi
  sc="$SC"; ch="$CH"; [ "$2" = sc ] && sc="$m" || ch="$m"
  suite "$sc" "$ch" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not extract or compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "S1 managed ignored in message()" sc 's/if \(managed\) return "This phone saves/if (false) return "This phone saves/' || fails=$((fails+1))
mut "S2 the store screen keeps the no-store literal" ch 's/final String sm = StoreScreenCopy\.message\(configured, managed, keyset\);/final String sm = keyset ? StoreScreenCopy.message(configured, managed, keyset) : "no store yet - set one up to create or unlock a profile";/' || fails=$((fails+1))
mut "S3 isError true for managed" sc 's/return !managed && keyset;/return managed || keyset;/' || fails=$((fails+1))
mut "S4 the store screen no longer reads managed=" ch 's/final boolean managed = "yes"\.equals\(m\.get\("managed"\)\);/final boolean managed = false;/' || fails=$((fails+1))
mut "S5 showS3Fields always true" sc 's/return !managed;/return true;/' || fails=$((fails+1))
mut "S6 the secret's wrapper left visible" ch 's/\(\(View\) secretF\.getParent\(\)\)\.setVisibility\(View\.GONE\);/secretF.setVisibility(View.GONE);/' || fails=$((fails+1))
mut "S7 Save store left visible" ch 's/save\.setVisibility\(View\.GONE\);/save.setVisibility(View.VISIBLE);/' || fails=$((fails+1))
mut "S8 Test connection left visible" ch 's/test\.setVisibility\(View\.GONE\);/test.setVisibility(View.VISIBLE);/' || fails=$((fails+1))
mut "S9 the visibility read from keyset" ch 's/if \(!StoreScreenCopy\.showS3Fields\(managed\)\) \{/if (!StoreScreenCopy.showS3Fields(!keyset)) {/' || fails=$((fails+1))
mut "S10 the managed subtitle names the S3 store" sc 's/if \(managed\) return "Where your encrypted data is saved\.";/if (managed) return "Where your encrypted data is saved. Point this device at an S3-compatible store.";/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
