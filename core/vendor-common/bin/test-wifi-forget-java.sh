#!/usr/bin/env bash
# test-wifi-forget-java.sh [--mutate] -- the gate's Forget network, run under javac (NWP-20261023-11).
#
# WHY THIS IS COMMITTED. forgetWifi used to ignore removeNetwork's result (a refused removal read OK and the
# button was hidden while the network stayed saved) and ended with the deprecated saveConfiguration(), which may
# throw and report a failure after the removal landed. The verdict now lives in WifiForget.run, a pure class with
# no android.* import, compiled here with its cases; a source guard checks ChooserActivity.forgetWifi goes through
# it and that nothing in the chooser calls saveConfiguration.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-wifi-forget-java.sh            # the cases + source guard
#   bash test-wifi-forget-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src"
COPY="$SRC/com/nowhere/chooser/WifiForget.java"
ACT="$SRC/com/nowhere/chooser/ChooserActivity.java"
CASES="$root/core/chooser/tests/wifi-forget/WifiForgetCases.java"
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
command -v perl >/dev/null 2>&1 || { echo "FAIL: this suite needs perl, and there is none" >&2; exit 2; }
[ -f "$ACT" ] && [ -f "$CASES" ] || { echo "FAIL: missing $ACT or $CASES" >&2; exit 2; }

# guard <ChooserActivity.java> -> 0 clean, 1 a guard failed. Output is captured into variables (no pipe into grep -q).
guard() {
  local act="$1" bad=0 hits ctl body calls
  hits=$(grep -rn 'saveConfiguration(' "$SRC" --include='*.java' | grep -v -F "$ACT"; grep -n 'saveConfiguration(' "$act")
  ctl=$(grep -rn 'removeNetwork(' "$SRC" --include='*.java')
  if [ -z "$ctl" ]; then echo "  GUARD control: the search does not find removeNetwork( -- it cannot see the source" >&2; bad=1; fi
  if [ -n "$hits" ]; then echo "  GUARD saveConfiguration( is called in the chooser:" >&2; echo "$hits" >&2; bad=1; fi
  body=$(perl -0ne 'print $1 if /(^[^\n]*private String forgetWifi\(\).*?)(?=^[^\n]*\bprivate [^\n]*\()/ms' "$act")
  if [ -z "$body" ]; then echo "  GUARD could not extract forgetWifi's body" >&2; bad=1
  else
    calls=$(printf '%s\n' "$body" | grep -c 'WifiForget\.run(')
    [ "$calls" = 1 ] || { echo "  GUARD forgetWifi calls WifiForget.run( $calls times, want exactly 1" >&2; bad=1; }
  fi
  return "$bad"
}

# suite <WifiForget.java> <ChooserActivity.java> -> 0 pass, 1 a case or guard failed (the only code that convicts a
# mutant), 3 the class or the cases did not compile.
suite() {
  local copy="$1" act="$2" d out rc bad=0
  guard "$act" || bad=1
  [ -f "$copy" ] || { echo "  FAIL  WifiForget.java does not exist" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$copy" "$d/src/com/nowhere/chooser/WifiForget.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/WifiForgetCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.WifiForgetCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && [ "$bad" -eq 0 ] && return 0
  return 1
}

echo "== $COPY"
suite "$COPY" "$ACT" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED -- a mutant that does not compile proves nothing)"
mut() { # mut <label> <copy|act> <perl-expr>
  local d c a rc target; d=$(mktemp -d -p "$W"); c="$d/WifiForget.java"; a="$d/ChooserActivity.java"
  cp "$COPY" "$c"; cp "$ACT" "$a"
  target="$c"; [ "$2" = act ] && target="$a"
  if ! perl -0pi -e "$3" "$target"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$COPY" "$c" && cmp -s "$ACT" "$a"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  suite "$c" "$a" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "M1 remove's result ignored"             copy 's/if \(!ops\.remove\(netId\)\) return "ERR refused";/ops.remove(netId);/' || fails=$((fails+1))
mut "M2 disconnect before the remove check"  copy 's/if \(!ops\.remove\(netId\)\) return "ERR refused";/ops.disconnect(); if (!ops.remove(netId)) return "ERR refused";/' || fails=$((fails+1))
mut "M3 the -1 check removed"                copy 's/if \(netId == -1\) return "ERR not connected";//' || fails=$((fails+1))
mut "M4 disconnect's own try removed"        copy 's/try \{\s*ops\.disconnect\(\);\s*\} catch \(RuntimeException e\) \{[^}]*\}/ops.disconnect();/' || fails=$((fails+1))
mut "M5 the catch answers OK"                copy 's/return "ERR " \+ \(e\.getMessage\(\) == null \? "failed" : e\.getMessage\(\)\);/return "OK";/' || fails=$((fails+1))
mut "M6 saveConfiguration re-added"          act  's/(return WifiForget\.run\(new WifiForget\.Ops\(\) \{)/wm.saveConfiguration();\n            $1/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
