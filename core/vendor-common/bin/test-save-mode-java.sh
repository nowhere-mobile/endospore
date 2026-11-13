#!/usr/bin/env bash
# test-save-mode-java.sh [--mutate] -- NWP-20261201-05: the Profile screen's "Save automatically" choice. Runs
# core/chooser/tests/save-mode: the chooser's pure option mapping, default and copy, the back-online prompt's text, and,
# read as data, the chooser's half of the daemon contract, compiled and EXECUTED.
#
# It needs a JDK, and it FAILS when there is none: a Java suite that skips without one would read green on a runner
# that never ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
# --mutate re-runs the suite against broken copies of the sources, each of which must FAIL a named case. A mutant that
# does not apply (INERT) or does not compile or fails another case (BROKEN) counts as a failure, never a pass.
#
#   bash test-save-mode-java.sh            # the cases
#   bash test-save-mode-java.sh --mutate   # ... plus the mutants
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
  echo "test-save-mode-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -J-Djava.io.tmpdir="$W" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser
run() { TMPDIR="$W" JAVAC=$JAVAC JAVA=$JAVA bash "$ROOT/core/chooser/tests/save-mode/run.sh" "$1"; }
run "$ROOT" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <SaveMode|ProfileActivity|ChooserActivity> <perl-expr over that file> <case the mutant must fail>
  local d f s out rc
  d=$(mktemp -d -p "$W") || return 1
  # a tree of symlinks to the real files, but for the one mutated copy
  mkdir -p "$d/$CH"
  for s in SaveMode ProfileActivity ChooserActivity; do ln -s "$ROOT/$CH/$s.java" "$d/$CH/$s.java"; done
  f="$d/$CH/$2.java"
  rm -f "$f"
  cp "$ROOT/$CH/$2.java" "$f"
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed"; rm -rf "$d"; return 1; fi
  if cmp -s "$ROOT/$CH/$2.java" "$f"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  out=$(run "$d" 2>&1); rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if ! grep -qF -- "FAIL $4" <<<"$out"; then
    echo "  BROKEN    $1 -- it failed, but not the case '$4' (rc=$rc)"; return 1
  fi
  echo "  convicted $1 (fails '$4')"
}
fails=0
mut "M1 the default is wifi" SaveMode 's/DEFAULT = "always";/DEFAULT = "wifi";/' \
  "the default is always" || fails=$((fails+1))
mut "M2 WAITS_FOR_WIFI chosen on an unmetered network" SaveMode 's/ && !unmetered \?/ ?/' \
  "backNowBody wifi on an unmetered network is today's text" || fails=$((fails+1))
mut "M3 the Off trade-off text dropped" SaveMode 's/case "off": return "Saves only when you sign out[^\n]*\n//' \
  "tradeoff off" || fails=$((fails+1))
mut "M4 the Wi-Fi trade-off loses Back up now" SaveMode 's/only a sign-out or Back up now saves/only a sign-out saves/' \
  "the wifi trade-off names Back up now" || fails=$((fails+1))
mut "M5 unmeteredCtx switched to the Wi-Fi transport" ChooserActivity \
  's/(static boolean unmeteredCtx\(Context ctx\).*?)nc\.hasCapability\(android\.net\.NetworkCapabilities\.NET_CAPABILITY_NOT_METERED\)/$1nc.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI)/s' \
  "unmeteredCtx tests NOT_METERED and not the Wi-Fi transport" || fails=$((fails+1))
mut "M6 SAVE-NET sent only on a change" ChooserActivity \
  's/( +)(if \(unmeteredCtx\(app\)\) pollDaemon\("SAVE-NET-UNMETERED\\n"\); else pollDaemon\("SAVE-NET-METERED\\n"\);)/$1if (uid != sweepNetUid) { $2 }/' \
  "the watcher sends SAVE-NET on every slow tick" || fails=$((fails+1))
mut "M7 the picker gains a Cancel button" ProfileActivity \
  's/(\.setTitle\("Save automatically"\).*?)\.setNegativeButton\("Not now", null\)/$1.setNegativeButton("Cancel", null)/s' \
  "the picker has no Cancel or OK button" || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
