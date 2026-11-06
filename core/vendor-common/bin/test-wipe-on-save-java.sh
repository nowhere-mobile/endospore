#!/usr/bin/env bash
# test-wipe-on-save-java.sh [--mutate] -- the gate half of "erase once saved" (Q138), run under javac (NWP-20261106-14).
#
# WHY THIS IS COMMITTED. A profile that chose "once saved" roams wipesaved=1 beside wipe=1. The gate must read it
# (applyRoamedPrefs -> RoamedPrefs.parse -> sWipeOnSave; NWP-20261119-21 moved the parse into RoamedPrefs), read it
# ONCE per cold lock (doColdLock) and ask the daemon EVICT-RECHECK-SAVED
# through evictRecheck, built from WipeOnSave.recheckVerb. Drop any link and the profile keeps its ciphertext for the
# whole fallback hour after every clean lock, with green CI. WipeOnSave is pure java.lang and is compiled here with its
# cases; source pins over ChooserActivity.java hold the wiring.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-wipe-on-save-java.sh            # the cases and the pins
#   bash test-wipe-on-save-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SUT="$SRC/WipeOnSave.java"
CHOOSER="$SRC/ChooserActivity.java"
ROAMED="$SRC/RoamedPrefs.java"
CASES="$root/core/chooser/tests/wipe-on-save/WipeOnSaveCases.java"
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
[ -f "$CASES" ] || { echo "FAIL: missing $CASES" >&2; exit 2; }

# suite <WipeOnSave.java> -> 0 pass, 1 a case failed or the class is missing, 3 did not compile.
suite() {
  local src="$1" d out rc
  [ -f "$src" ] || { echo "  FAIL  WipeOnSave.java does not exist" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$src" "$d/src/com/nowhere/chooser/WipeOnSave.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/WipeOnSaveCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.WipeOnSaveCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# mbody <file> <regex>: a method's body, from its signature to the closing brace at four spaces.
mbody() { RE="$2" awk '$0 ~ ENVIRON["RE"] { on = 1 } on { print } on && /^    }$/ { exit }' "$1"; }
# count <body> <regex>: matching non-comment lines.
count() { printf '%s\n' "$1" | RE="$2" awk '$0 !~ /^[ \t]*(\/\/|\*|\/\*)/ && $0 ~ ENVIRON["RE"] { n++ } END { print n + 0 }'; }
# first_line <body> <regex>: the first matching non-comment line number, empty when none.
first_line() { printf '%s\n' "$1" | RE="$2" awk '$0 !~ /^[ \t]*(\/\/|\*|\/\*)/ && $0 ~ ENVIRON["RE"] { print NR; exit }'; }

# pins <ChooserActivity.java> [<RoamedPrefs.java>] -> 0 when the wiring holds, 1 otherwise.
pins() {
  local f="$1" rpf="${2:-$ROAMED}" bad=0 arp dcl er callers os th n
  arp=$(mbody "$f" 'private void applyRoamedPrefs\(')
  dcl=$(mbody "$f" 'private static void doColdLock\(')
  er=$(mbody "$f" 'private static void evictRecheck\(')
  for n in arp dcl er; do [ -n "${!n}" ] || { echo "  FAIL  pins: $n body not found in $f" >&2; return 1; }; done
  [ "$(count "$arp" 'l\.startsWith\(WipeOnSave\.PREF')" -eq 1 ] \
    || { echo "  FAIL  pins: applyRoamedPrefs does not read WipeOnSave.PREF" >&2; bad=1; }
  # NWP-20261119-21: the parse is RoamedPrefs.parse's, and its wipeOnSave is WipeOnSave.on(wipesaved).
  [ "$(count "$arp" 'RoamedPrefs\.parse\(idle, wipe, wipesaved, holdlock,')" -eq 1 ] \
    || { echo "  FAIL  pins: applyRoamedPrefs does not parse wipesaved through RoamedPrefs.parse once" >&2; bad=1; }
  [ "$(count "$arp" 'sWipeOnSave = rp\.wipeOnSave;')" -eq 1 ] \
    || { echo "  FAIL  pins: applyRoamedPrefs does not assign sWipeOnSave from RoamedPrefs' result" >&2; bad=1; }
  [ "$(count "$(cat "$rpf" 2>/dev/null)" 'WipeOnSave\.on\(wipesaved\)')" -eq 1 ] \
    || { echo "  FAIL  pins: RoamedPrefs.parse does not read wipesaved with WipeOnSave.on(" >&2; bad=1; }
  os=$(first_line "$dcl" 'final boolean onSave = sWipeOnSave;')
  th=$(first_line "$dcl" 'new Thread\(\(\) -> \{')
  if [ -z "$os" ]; then echo "  FAIL  pins: doColdLock does not capture sWipeOnSave in a final local" >&2; bad=1
  elif [ -z "$th" ] || [ "$os" -ge "$th" ]; then echo "  FAIL  pins: doColdLock captures onSave after its thread starts" >&2; bad=1; fi
  [ "$(count "$dcl" 'evictRecheck\(app, uid, lockGen, stoppedAt, onSave\);')" -eq 1 ] \
    || { echo "  FAIL  pins: doColdLock does not pass the captured onSave as evictRecheck's fifth argument" >&2; bad=1; }
  callers=$(awk '$0 !~ /^[ \t]*(\/\/|\*|\/\*)/ && /evictRecheck\(/ && !/private static void evictRecheck/ { n++ } END { print n + 0 }' "$f")
  [ "$callers" -eq 1 ] || { echo "  FAIL  pins: evictRecheck has $callers callers, want exactly 1 (doColdLock)" >&2; bad=1; }
  [ "$(count "$er" 'DaemonSocket\.roundTrip\(WipeOnSave\.recheckVerb\(onSave\)')" -eq 1 ] \
    || { echo "  FAIL  pins: evictRecheck's roundTrip is not built from WipeOnSave.recheckVerb(onSave)" >&2; bad=1; }
  [ "$(count "$er" '"EVICT-RECHECK(-SAVED)?\\n"')" -eq 0 ] \
    || { echo "  FAIL  pins: evictRecheck still holds an EVICT-RECHECK literal" >&2; bad=1; }
  [ "$bad" -eq 0 ]
}

echo "== $SUT"
suite "$SUT" || { echo "FAILED"; exit 1; }
pins "$CHOOSER" || { echo "FAILED (pins)"; exit 1; }
echo "pins: ok"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not compile proves nothing)"
mut() { # mut <label> <perl-expr>   (mutates WipeOnSave.java; the cases must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/WipeOnSave.java"
  cp "$SUT" "$c"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$SUT" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  suite "$c" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  CONVICTED $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
mutpin() { # mutpin <label> <perl-expr>   (mutates ChooserActivity.java; the pins must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/ChooserActivity.java"
  cp "$CHOOSER" "$c"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$CHOOSER" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  pins "$c" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  echo "  CONVICTED $1"
}
fails=0
mut "W1 on() true for any non-empty value" 's/return v != null && "1"\.equals\(v\.trim\(\)\);/return v != null && !v.trim().isEmpty();/' || fails=$((fails+1))
mut "W2 recheckVerb inverted" 's/onSave \? "EVICT-RECHECK-SAVED" : "EVICT-RECHECK"/onSave ? "EVICT-RECHECK" : "EVICT-RECHECK-SAVED"/' || fails=$((fails+1))
mutpin "W3 doColdLock passes false" 's/evictRecheck\(app, uid, lockGen, stoppedAt, onSave\);/evictRecheck(app, uid, lockGen, stoppedAt, false);/' || fails=$((fails+1))
mutpin "W4 evictRecheck back to the EVICT-RECHECK literal" 's/DaemonSocket\.roundTrip\(WipeOnSave\.recheckVerb\(onSave\) \+ "\\n"/DaemonSocket.roundTrip("EVICT-RECHECK\\n"/' || fails=$((fails+1))
mutpin "W5 sWipeOnSave never assigned from RoamedPrefs' result" 's/\n[^\n]*sWipeOnSave = rp\.wipeOnSave;//' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "PASS: 5 of 5 mutants convicted" || { echo "== $fails mutant(s) not convicted"; exit 1; }
