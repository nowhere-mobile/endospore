#!/usr/bin/env bash
# test-relogin-copy-java.sh [--mutate] -- the reconnect prompt's copy and the verdict of RELOGIN's reply, run under
# javac (NWP-20261103-09, Q068).
#
# WHY THIS IS COMMITTED. The "You're back online" prompt is posted before anything checks whether the offline
# session's name has a stored profile, so it must not promise saved data (Q068: "if this name has saved data..."), and
# the tap's reply now arrives only after the daemon has read the store, so the receiver's read cap must outlast that
# check. core/chooser/tests/relogin-copy/run.sh compiles ReloginCopy verbatim against Cases and pins the wiring:
# postReconnectNotice posts ReloginCopy.RECONNECT_BODY, ReloginReceiver's caps are 30000/40000 and it classifies the
# reply through ReloginCopy.verdict.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (exit 2), like the other javac suites.
#
# Mutants: C1 NOSTORED classified as loading; C2 the old unconditional body restored; C3 READ_CAP_MS back to 5000;
# C4 ERR-STORE classified as loading; C5 postReconnectNotice's body inlined again; C6 CONNECT_CAP_MS back to 15000.
#
#   bash test-relogin-copy-java.sh            # the cases
#   bash test-relogin-copy-java.sh --mutate   # ... plus broken copies that must each FAIL the cases
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRCDIR="$root/core/chooser/src/com/nowhere/chooser"
COPY="$SRCDIR/ReloginCopy.java"
CHOOSER="$SRCDIR/ChooserActivity.java"
RECV="$SRCDIR/ReloginReceiver.java"
RUN="$root/core/chooser/tests/relogin-copy/run.sh"
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
for f in "$COPY" "$CHOOSER" "$RECV" "$RUN"; do
  [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 2; }
done

# suite <ReloginCopy.java> <ChooserActivity.java> <ReloginReceiver.java> -> run.sh's code: 0 pass, 1 a case or pin
# failed (only this may convict a mutant), 2 a file or method did not extract, 3 the cases did not compile.
suite() { TMPDIR="$W" bash "$RUN" "$1" "$2" "$3"; }

echo "== $COPY"
suite "$COPY" "$CHOOSER" "$RECV"; rc=$?
if [ "$rc" -ne 0 ]; then echo "FAILED (rc=$rc)"; [ "$rc" -eq 1 ] && exit 1 || exit 2; fi
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by behaviour; one that does not apply or compile is a failure)"
mut() { # mut <label> <copy|chooser|receiver> <perl-expr> [<lines-that-must-change>]
  local d m rc changed src c ch r
  d=$(mktemp -d -p "$W")
  c="$COPY"; ch="$CHOOSER"; r="$RECV"
  case "$2" in
    copy) src="$COPY"; m="$d/ReloginCopy.java"; c="$m" ;;
    chooser) src="$CHOOSER"; m="$d/ChooserActivity.java"; ch="$m" ;;
    receiver) src="$RECV"; m="$d/ReloginReceiver.java"; r="$m" ;;
    *) echo "  ERROR     $1 -- unknown target $2"; rm -rf "$d"; return 1 ;;
  esac
  if ! perl -0pe "$3" "$src" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$src" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  changed=$(diff "$src" "$m" | grep -c '^>')
  if [ "$changed" -ne "${4:-1}" ]; then
    echo "  ERROR     $1 -- the mutation changed $changed line(s), expected ${4:-1}"; rm -rf "$d"; return 1; fi
  suite "$c" "$ch" "$r" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not extract or compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "C1 NOSTORED classified as loading" copy \
    's/r\.equals\("NOSTORED"\)\) return Verdict\.KEPT;/r.equals("NOSTORED")) return Verdict.LOADING;/' || fails=$((fails+1))
mut "C2 the old unconditional body restored" copy \
    's/(RECONNECT_BODY =\n).*?";\n/$1            "Your saved data isn\x27t loaded yet. Tap \\"Load my saved data\\" to switch - anything you did in this offline session will be discarded.";\n/s' \
    1 || fails=$((fails+1))
mut "C3 READ_CAP_MS back to 5000" receiver 's/READ_CAP_MS = 30000;/READ_CAP_MS = 5000;/' || fails=$((fails+1))
mut "C4 ERR-STORE classified as loading" copy \
    's/(        return Verdict\.RETRY;\n    \}\n\}\n)\z/        if (r.equals("ERR-STORE")) return Verdict.LOADING;\n$1/' || fails=$((fails+1))
mut "C5 postReconnectNotice's body inlined again" chooser \
    's/String body = ReloginCopy\.RECONNECT_BODY;/String body = "Your saved data isn\x27t loaded yet; anything you did in this offline session will be discarded.";/' || fails=$((fails+1))
mut "C6 CONNECT_CAP_MS back to 15000" receiver 's/CONNECT_CAP_MS = 40000;/CONNECT_CAP_MS = 15000;/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
