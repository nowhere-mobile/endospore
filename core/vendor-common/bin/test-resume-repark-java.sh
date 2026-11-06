#!/usr/bin/env bash
# test-resume-repark-java.sh [--mutate] -- a resume whose user switch fails re-parks the session (Q087, NWP-20261111-12).
#
# WHY THIS IS COMMITTED. After the daemon answers RESUME with "OK <uid>" it has already opened the profile's CE and
# re-written .roamsession. If ChooserActivity.resume()'s switchToUser then fails, the gate re-locks and says "try
# again" -- and nothing told the daemon, so the user stayed RUNNING_UNLOCKED behind the gate with no idle bound (the
# hand-switch watcher never fires: no switch happened). Any Create in between is refused ERR-LIVE and the next onResume
# sweep can reap the session unsaved. Q087 (docs/product-decisions.md 2026-10-20) decided the gate parks it again with
# the daemon's COLD-LOCK, as the hand-switch watcher does. This suite
#  (a) compiles the real ResumeRepark.java (pure java.lang) with core/chooser/tests/resume-repark/ResumeReparkCases.java
#      and runs the cases: landed() is true only for exactly "OK LOCKING" (after trim), and the two failed-switch lines;
#  (b) PINS ChooserActivity: reparkAfterFailedResume sends exactly "COLD-LOCK\n" (never COLD-LOCK-IDLE) once, holds the
#      cold wake and reads the reply through ResumeRepark.landed; the switchToUser-false arm calls it after
#      lockGate(true), guarding its paint with resumeMode; and no other ResumeReply arm (GONE, NEEDKEY, WRONG,
#      RESTORE_FAILED, RETRY) calls it.
#
# FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-resume-repark-java.sh            # the cases and the pins
#   bash test-resume-repark-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser/ChooserActivity.java"
PARSE="$root/core/chooser/src/com/nowhere/chooser/ResumeRepark.java"
CASES="$root/core/chooser/tests/resume-repark/ResumeReparkCases.java"
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
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "FAIL: this suite needs perl for its mutants" >&2; exit 2; }
[ -f "$SRC" ] && [ -f "$CASES" ] || { echo "FAIL: missing $SRC or $CASES" >&2; exit 2; }

# body <file> <signature-substring> -> the member from its signature line to the brace that closes it
body() {
  awk -v sig="$2" '
    !on && index($0, sig) { on=1; depth=0 }
    on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
  ' "$1"
}

# cnt <text> <fixed-string> -> how many lines of text hold the string
cnt() { printf '%s\n' "$1" | grep -cF -- "$2" || true; }

# pins <ChooserActivity.java> -> 0 all hold, 1 one failed
pins() {
  local f="$1" r h arm n order
  r=$(body "$f" 'private void resume(final String pass, final boolean keyAlreadyAsserted) {')
  [ -n "$r" ] || { echo "  PIN P0 no resume(String, boolean) in $f" >&2; return 1; }
  h=$(body "$f" 'private static void reparkAfterFailedResume(')
  [ -n "$h" ] || { echo "  PIN P0 no reparkAfterFailedResume in $f" >&2; return 1; }
  # P1: the helper sends the plain COLD-LOCK verb, once, and nothing else.
  n=$(cnt "$h" 'pollDaemon("COLD-LOCK\n")')
  [ "$n" = 1 ] || { echo "  PIN P1 reparkAfterFailedResume sends pollDaemon(\"COLD-LOCK\\n\") $n times, want 1" >&2; return 1; }
  n=$(cnt "$h" 'COLD-LOCK-IDLE')
  [ "$n" = 0 ] || { echo "  PIN P1 reparkAfterFailedResume names COLD-LOCK-IDLE ($n): the re-park is an explicit lock" >&2; return 1; }
  n=$(cnt "$h" 'pollDaemon(')
  [ "$n" = 1 ] || { echo "  PIN P1 reparkAfterFailedResume calls pollDaemon $n times, want 1" >&2; return 1; }
  n=$(cnt "$h" 'coldWakeAcquire(app)')
  [ "$n" = 1 ] || { echo "  PIN P1 reparkAfterFailedResume does not hold the cold wake (coldWakeAcquire(app): $n)" >&2; return 1; }
  n=$(cnt "$h" 'ResumeRepark.landed(')
  [ "$n" = 1 ] || { echo "  PIN P1 reparkAfterFailedResume does not read the reply through ResumeRepark.landed ($n)" >&2; return 1; }
  n=$(cnt "$h" 'markColdLockIncoming(')
  [ "$n" = 0 ] || { echo "  PIN P1 reparkAfterFailedResume calls markColdLockIncoming: the gate is already in front" >&2; return 1; }
  # P2: the switchToUser-false arm calls it, after the re-kiosk, and paints only in resume mode.
  arm=$(printf '%s\n' "$r" | awk 'index($0, "if (switchToUser(fuid, ownedLbls)) {"){on=1} on{print} on && index($0, "armCredentialOnScreenOff(appCtx, fuid, pass);"){exit}')
  [ -n "$arm" ] || { echo "  PIN P2 no switchToUser(fuid, ownedLbls) arm in resume()" >&2; return 1; }
  n=$(printf '%s\n' "$arm" | grep -cE '^\s*reparkAfterFailedResume\(appCtx,' || true)
  [ "$n" = 1 ] || { echo "  PIN P2 the switchToUser arm calls reparkAfterFailedResume(appCtx, ...) $n times, want 1" >&2; return 1; }
  order=$(printf '%s\n' "$arm" | awk '
    index($0, "} else {") && !e {e=NR}
    index($0, "lockGate(true);") && !l {l=NR}
    /^[ \t]*reparkAfterFailedResume\(appCtx,/ && !c {c=NR}
    END { print (e && l && c && e < l && l < c) ? "ok" : "bad" }')
  [ "$order" = ok ] || { echo "  PIN P2 reparkAfterFailedResume is not in the switch-false arm after lockGate(true)" >&2; return 1; }
  n=$(printf '%s\n' "$arm" | grep -F 'ResumeRepark.failedSwitchLine(' | grep -cF 'if (resumeMode)' || true)
  [ "$n" = 1 ] || { echo "  PIN P2 the re-park's paint (ResumeRepark.failedSwitchLine) is not guarded by if (resumeMode)" >&2; return 1; }
  # P3: no other arm calls it -- one call in resume(), and the file holds only the declaration and that call.
  n=$(cnt "$r" 'reparkAfterFailedResume(')
  [ "$n" = 1 ] || { echo "  PIN P3 resume() calls reparkAfterFailedResume $n times, want 1 (the switch-false arm only)" >&2; return 1; }
  n=$(grep -cF 'reparkAfterFailedResume(' "$f" || true)
  [ "$n" = 2 ] || { echo "  PIN P3 ChooserActivity names reparkAfterFailedResume( $n times, want 2 (declaration + one call)" >&2; return 1; }
  return 0
}

# cases <ResumeRepark.java> -> 0 pass, 1 a case failed, 2 the source is missing, 3 it did not compile
cases() {
  local o rc=0
  [ -f "$1" ] || { echo "  missing $1" >&2; return 2; }
  o=$(mktemp -d -p "$W")
  cp "$1" "$o/ResumeRepark.java" && cp "$CASES" "$o/" || return 2
  "$JAVAC" -encoding UTF-8 -J-Djava.io.tmpdir="$W" -d "$o" "$o/ResumeRepark.java" "$o/ResumeReparkCases.java" || return 3
  "$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$o" com.nowhere.chooser.ResumeReparkCases || rc=$?
  rm -rf "$o"
  [ "$rc" = 0 ] || return 1
  return 0
}

# suite <ChooserActivity.java> <ResumeRepark.java> -> 0 pass, 1 a case or pin failed, >=2 broken
suite() {
  pins "$1" || return 1
  cases "$2" || return $?
}

echo "== $SRC"
suite "$SRC" "$PARSE" || { echo "FAILED"; exit 1; }
echo "== cases and pins hold"
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED -- by a case or a pin: a mutant that does not apply or compile proves nothing)"
# mut <label> <which: parse|activity> <perl-expr>
mut() {
  local d m rc a p src; d=$(mktemp -d -p "$W"); a="$SRC"; p="$PARSE"
  case "$2" in
    parse) m="$d/ResumeRepark.java"; p="$m"; src="$PARSE" ;;
    *) m="$d/ChooserActivity.java"; a="$m"; src="$SRC" ;;
  esac
  if ! perl -0pe "$3" "$src" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$src" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  suite "$a" "$p" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not apply or compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "R1 the switch-false arm's call removed" activity 's/\n[ \t]*reparkAfterFailedResume\(appCtx, landed -> \{\n.*?\n[ \t]*\}\);\n/\n/s' || fails=$((fails+1))
mut "R2 the RETRY (else) arm calls it"       activity 's/(else \{ \/\/ RESTORE_FAILED and RETRY\.\n)/$1                        reparkAfterFailedResume(appCtx, null);\n/' || fails=$((fails+1))
mut "R3 COLD-LOCK-IDLE sent"                 activity 's/final String rep = pollDaemon\("COLD-LOCK\\n"\)/final String rep = pollDaemon("COLD-LOCK-IDLE\\n0\\n")/' || fails=$((fails+1))
mut "R4 landed() true for NOSESSION"         parse    's/"OK LOCKING"\.equals\(coldLockReply\.trim\(\)\)/("OK LOCKING".equals(coldLockReply.trim()) || "OK NOSESSION".equals(coldLockReply.trim()))/' || fails=$((fails+1))
mut "R5 the WRONG arm calls it"              activity 's/(else if \(v\.kind == ResumeReply\.WRONG\) \{[^\n]*\n)/$1                        reparkAfterFailedResume(appCtx, null);\n/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
