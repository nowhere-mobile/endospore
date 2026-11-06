#!/usr/bin/env bash
# test-create-live-java.sh [--mutate] -- NWP-20261116-09 (h46 #5): a create the daemon refuses with ERR-LIVE (a roamed
# session is still open) says so, in the decided words, and offers Restart and Cancel, never the blank a wrong
# passphrase shows. Runs core/chooser/tests/create-live: the chooser's reading of ERR-LIVE, its words (against
# docs/product-decisions.md), the place of its branch in roamLogin, and its Restart, compiled and EXECUTED.
# NWP-20261117-11 (#54): also the gate's reading of ERR-NAME (a name holding '#'), its branch and its words (M7-M11).
#
# It needs a JDK, and it FAILS when there is none. javac/java come from PATH, then the build VM's prebuilt JDK 21.
# --mutate re-runs the suite against broken copies of ChooserActivity.java, each of which must FAIL a named case; a
# mutant that does not apply (INERT) or does not compile/extract (BROKEN) counts as a failure, never a pass.
set -uo pipefail
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-create-live-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
SRC="$ROOT/core/chooser/src/com/nowhere/chooser/ChooserActivity.java"
run() { TMPDIR=$W JAVAC=$JAVAC JAVA=$JAVA bash "$ROOT/core/chooser/tests/create-live/run.sh" "$1" "$ROOT"; }
run "$SRC" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <perl-expr> <case the mutant must fail>
  local d f out rc
  d=$(mktemp -d -p "$W"); f="$d/ChooserActivity.java"
  cp "$SRC" "$f"
  if ! perl -0pi -e "$2" "$f"; then echo "  ERROR     $1 -- perl failed"; return 1; fi
  if cmp -s "$SRC" "$f"; then echo "  INERT     $1 -- the mutation changed nothing"; return 1; fi
  out=$(run "$f" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if ! grep -qF -- "FAIL $3" <<<"$out"; then
    echo "  BROKEN    $1 -- it failed, but not the case '$3' (rc=$rc)"; return 1
  fi
  echo "  convicted $1 (fails '$3')"
}
fails=0
BRANCH='                if \(createReplyLive\(cr\)\) \{\n.*?\n                \}\n'
mut "M1 createReplyLive is always false" 's/(private static boolean createReplyLive\(String cr\) \{\n)/$1        if (true) return false;\n/' \
  "L1 createReplyLive" || fails=$((fails+1))
mut "M2 createReplyLive is a prefix match" 's/(private static boolean createReplyLive\(String cr\) \{\n)/$1        if (true) return cr != null \&\& cr.trim().startsWith("ERR-LIVE");\n/' \
  "L1 createReplyLive: \"ERR-LIVEX\" is not ERR-LIVE" || fails=$((fails+1))
mut "M3 the ERR-LIVE branch is deleted" "s/$BRANCH//s" \
  "L3 the ERR-LIVE branch is after" || fails=$((fails+1))
mut "M4 the ERR-LIVE branch moved below the blank failure" "s/($BRANCH)(.*?)(                if \\(!cr\\.startsWith\\(\"OK\"\\)\\) \\{ hideRestore\\(\\); showBlank\\(\\); return; \\}\\n)/\$2\$3\$1/s" \
  "L3 the ERR-LIVE branch is after" || fails=$((fails+1))
mut "M5 the words say reboot, not restart" 's/restart the phone\. Anything that session/reboot the phone. Anything that session/' \
  "L2 createLiveText is the decided h46 #5 words" || fails=$((fails+1))
mut "M6 Restart no longer calls rebootForCreateOverLive" 's/setPositiveButton\("Restart", \(d, w\) -> rebootForCreateOverLive\(\)\)/setPositiveButton("Restart", (d, w) -> {})/' \
  "L4 showCreateOverLiveSession's Restart calls rebootForCreateOverLive" || fails=$((fails+1))
NBRANCH='                if \(createReplyBadName\(cr\)\) \{.*?\n                \}\n'
mut "M7 createReplyBadName is always false" 's/(private static boolean createReplyBadName\(String cr\) \{\n)/$1        if (true) return false;\n/' \
  "N1 createReplyBadName: \"ERR-NAME\" is ERR-NAME" || fails=$((fails+1))
mut "M8 createReplyBadName is a prefix match" 's/(private static boolean createReplyBadName\(String cr\) \{\n)/$1        if (true) return cr != null \&\& cr.trim().startsWith("ERR-NAME");\n/' \
  "N1 createReplyBadName: \"ERR-NAMEX\" is not ERR-NAME" || fails=$((fails+1))
mut "M9 the ERR-NAME branch is deleted" "s/$NBRANCH//s" \
  "N2 the ERR-NAME branch is after" || fails=$((fails+1))
mut "M10 the ERR-NAME branch moved below the blank failure" "s/($NBRANCH)(.*?)(                if \\(!cr\\.startsWith\\(\"OK\"\\)\\) \\{ hideRestore\\(\\); showBlank\\(\\); return; \\}\\n)/\$2\$3\$1/s" \
  "N2 the ERR-NAME branch is after" || fails=$((fails+1))
mut "M11 the ERR-NAME words lose their full stop" 's/showMsg\("Names can\x27t contain #\."\);/showMsg("Names can\x27t contain #");/' \
  "N2 the ERR-NAME branch re-enables the form, says the #54 words and returns" || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
