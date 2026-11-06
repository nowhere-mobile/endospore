#!/usr/bin/env bash
# test-free-on-phone-java.sh [--mutate] -- NWP-20261125-11 (h51 #4 B2): "Free on this phone" for a downloaded
# On-demand app on the "What's using your space" screen. Runs core/chooser/tests/free-on-phone: the chooser's pure
# FreeOnPhone (offer: which row shows the link; verdict: which result lets the free archive), compiled against its
# cases ALONE and EXECUTED, plus source checks (pins.py) that storageAppRow asks FreeOnPhone.offer, that
# ReArchiveReceiver.freeNow archives only under an "ok" verdict, that the tap neither repaints nor touches a finished
# activity, and that the sweep's archive call is still the idle reclaim.
#
# It needs a JDK, and it FAILS when there is none: a Java suite that skips without one would read green on a runner
# that never ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21. The pins need python3.
#
# --mutate re-runs the cases and the pins against broken copies of FreeOnPhone.java, ReArchiveReceiver.java and
# ProfileActivity.java, each of which must FAIL a named case or pin. A mutant that does not apply (INERT) or does
# not compile (BROKEN) counts as a failure, never a pass. The suite compiles FreeOnPhone and its cases only, never
# ProfileActivity or ReArchiveReceiver (they need the Android SDK); their mutants are convicted by the pins.
#
#   bash test-free-on-phone-java.sh            # the cases and the pins
#   bash test-free-on-phone-java.sh --mutate   # ... plus the mutants
set -uo pipefail
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-free-on-phone-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
# ONE temp root: every class dir and mutant tree lives under it, and the EXIT trap removes it however this ends.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser
T=$ROOT/core/chooser/tests/free-on-phone
command -v python3 >/dev/null 2>&1 || { echo "test-free-on-phone-java: FAIL -- no python3 for the pins" >&2; exit 2; }
run() { JAVAC=$JAVAC JAVA=$JAVA bash "$T/run.sh" "$1" "$(mktemp -d -p "$W")"; }
pins() { python3 -I -B "$T/pins.py" "$1"; }
# Both legs always run, so a red case does not hide a red pin.
rc=0
run "$ROOT" || rc=1
pins "$ROOT" || rc=1
[ "$rc" -eq 0 ] || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
SRCS="FreeOnPhone.java ReArchiveReceiver.java ProfileActivity.java"
mut() { # mut <label> <file under $CH> <perl-expr over it> <case or pin the mutant must fail>
  local d f out rc s
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/$CH"
  for s in $SRCS; do cp "$ROOT/$CH/$s" "$d/$CH/$s"; done
  f="$d/$CH/$2"
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed"; rm -rf "$d"; return 1; fi
  if cmp -s "$ROOT/$CH/$2" "$f"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  rc=0
  out=$(run "$d" 2>&1) || rc=1
  out+=$'\n'$(pins "$d" 2>&1) || rc=1
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if grep -qF -- "error:" <<<"$out"; then echo "  BROKEN    $1 -- it did not compile"; return 1; fi
  if ! grep -qF -- "FAIL $4" <<<"$out"; then
    echo "  BROKEN    $1 -- it failed, but not '$4'"; return 1
  fi
  echo "  convicted $1 (fails '$4')"
}
fails=0
mut "F1 the code check dropped" FreeOnPhone.java 's/ && code && / && /' \
  "ondemand without code is not offered" || fails=$((fails+1))
mut "F2 auto accepted" FreeOnPhone.java \
  's/"ondemand"\.equals\(mode\)/("ondemand".equals(mode) || "auto".equals(mode))/' \
  "auto is not offered" || fails=$((fails+1))
mut "F3 the installed check dropped" FreeOnPhone.java 's/ && installedNow//' \
  "not installed is not offered" || fails=$((fails+1))
mut "F4 a held job reads ok" FreeOnPhone.java 's/holdsJob \? "job" : "ok"/holdsJob ? "ok" : "ok"/' \
  "a held job is kept" || fails=$((fails+1))
mut "F5 verdict ignores failedSource" FreeOnPhone.java 's/\n[ \t]*if \(failedSource != null\) return "unread";//' \
  "unread source with a job is unread" || fails=$((fails+1))
mut "F6 freeNow archives unconditionally" ReArchiveReceiver.java 's/if \("ok"\.equals\(v\)\) \{/if (true) {/' \
  'p2 freeNow archives only under an "ok" verdict' || fails=$((fails+1))
mut "F7 the Play stack check dropped" FreeOnPhone.java 's/ && !playStack//' \
  "Play stack is not offered" || fails=$((fails+1))
mut "F8 the tap repaints" ProfileActivity.java 's/(free\.setEnabled\(false\);)/$1 repaint.run();/' \
  "p3 the Free tap handler does not repaint" || fails=$((fails+1))
mut "F9 the row no longer asks offer" ProfileActivity.java 's/FreeOnPhone\.offer\(/FreeOnPhone.offerX(/' \
  "p1 storageAppRow calls FreeOnPhone.offer" || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
