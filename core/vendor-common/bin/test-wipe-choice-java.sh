#!/usr/bin/env bash
# test-wipe-choice-java.sh [--mutate] -- the erase picker's "Right away, once saved" (Q138), run under javac (NWP-20261106-15).
#
# WHY THIS IS COMMITTED. The picker must offer the choice, highlight it from wipe= + wipesaved=, and write BOTH keys in
# ONE atomic write (wipe=1, the 1-hour bound a gate that does not know wipesaved still applies, plus wipesaved=1). Drop
# any link and a profile that chose "right away" is either not erased early, erased never (wipe=0), or left holding one
# key, with green CI. WipeChoice is pure java.lang; prefsText, prefsUpdated and prefsUpdatedWipe are lifted out of
# ProfileActivity.java by signature (as tests/loc-prefs/run.sh does) and compiled with it, WipeOnSave and MobileData;
# source pins hold showWipePicker and writeWipePref.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-wipe-choice-java.sh            # the cases and the pins
#   bash test-wipe-choice-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
PA="$SRC/ProfileActivity.java"
WC="$SRC/WipeChoice.java"
CASES="$root/core/chooser/tests/wipe-choice/WipeChoiceCases.java"
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

# suite <ProfileActivity.java> <WipeChoice.java> -> 0 pass, 1 a case or pin failed, 2 extraction failed, 3 did not compile.
suite() {
  local pa="$1" wc="$2" d m k out rc
  [ -f "$pa" ] && [ -f "$wc" ] || { echo "  FAIL  a source file does not exist" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  {
    echo "final class Lifted {"
    for k in PREF_NETLOC PREF_GEOCODER; do
      grep -E "^    static final String $k = \"[a-z-]+\";$" "$pa" || true
    done
    for m in prefValueIn locPrefOn prefsText prefsUpdated prefsUpdatedWipe; do
      awk -v m="$m" '
        !on && index($0, "    static ") == 1 && index($0, " " m "(") { on=1; depth=0 }
        on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
      ' "$pa"
    done
    echo "}"
  } > "$d/Lifted.java"
  for k in PREF_NETLOC PREF_GEOCODER; do
    [ "$(grep -c "static final String $k = " "$d/Lifted.java")" = 1 ] || { echo "  FAIL  extraction: $k" >&2; rm -rf "$d"; return 2; }
  done
  for m in prefValueIn locPrefOn prefsText prefsUpdated prefsUpdatedWipe; do
    [ "$(grep -cE "^    static [A-Za-z]+ $m\(" "$d/Lifted.java")" = 1 ] || { echo "  FAIL  extraction: $m" >&2; rm -rf "$d"; return 2; }
  done
  grep -v '^package ' "$wc" > "$d/WipeChoice.java"
  grep -v '^package ' "$SRC/WipeOnSave.java" > "$d/WipeOnSave.java"
  grep -v '^package ' "$SRC/MobileData.java" > "$d/MobileData.java"
  cp "$CASES" "$d/"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" WipeChoiceCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] || return 1
  pins "$pa"
}

# mbody <file> <regex>: a method's body, from its signature to the closing brace at four spaces.
mbody() { RE="$2" awk '$0 ~ ENVIRON["RE"] { on = 1 } on { print } on && /^    }$/ { exit }' "$1"; }
# count <body> <regex>: matching non-comment lines.
count() { printf '%s\n' "$1" | RE="$2" awk '$0 !~ /^[ \t]*(\/\/|\*|\/\*)/ && $0 ~ ENVIRON["RE"] { n++ } END { print n + 0 }'; }

# pins <ProfileActivity.java> -> 0 when the picker's wiring holds, 1 otherwise.
pins() {
  local f="$1" bad=0 sp wp
  sp=$(mbody "$f" 'private void showWipePicker\(')
  wp=$(mbody "$f" 'private boolean writeWipePref\(')
  [ -n "$sp" ] && [ -n "$wp" ] || { echo "  FAIL  pins: showWipePicker or writeWipePref not found" >&2; return 1; }
  [ "$(count "$sp" 'setSingleChoiceItems\(WipeChoice\.LABELS, sel')" -eq 1 ] \
    || { echo "  FAIL  pins: showWipePicker does not offer WipeChoice.LABELS" >&2; bad=1; }
  [ "$(count "$sp" 'WipeChoice\.selected\(readPrefValue\("wipe"\), readPrefValue\(WipeOnSave\.PREF\)\)')" -eq 1 ] \
    || { echo "  FAIL  pins: showWipePicker does not highlight from WipeChoice.selected(" >&2; bad=1; }
  [ "$(count "$sp" 'if \(writeWipePref\(idx\)\) live = sendLivePrefs\(\);')" -eq 1 ] \
    || { echo "  FAIL  pins: showWipePicker does not save with writeWipePref(idx) as the condition of the live send" >&2; bad=1; }
  [ "$(count "$sp" 'int\[\] hours|"After 1 hour"')" -eq 0 ] \
    || { echo "  FAIL  pins: showWipePicker still holds its own hours or labels" >&2; bad=1; }
  [ "$(count "$wp" 'prefsUpdatedWipe\(cur, WipeChoice\.wipeValue\(i\), WipeChoice\.savedValue\(i\),')" -eq 1 ] \
    || { echo "  FAIL  pins: writeWipePref does not compose both keys with prefsUpdatedWipe" >&2; bad=1; }
  [ "$(count "$wp" 'StoreInstaller\.writeAtomic\(new java\.io\.File\(getFilesDir\(\), PREFS_FILE\), text\);')" -eq 1 ] \
    || { echo "  FAIL  pins: writeWipePref does not write the text in one writeAtomic" >&2; bad=1; }
  [ "$(count "$wp" 'setPref\(')" -eq 0 ] \
    || { echo "  FAIL  pins: writeWipePref writes through setPref (two writes)" >&2; bad=1; }
  [ "$bad" -eq 0 ]
}

echo "== $WC"
suite "$PA" "$WC" || { echo "FAILED"; exit 1; }
echo "pins: ok"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not compile proves nothing)"
mut() { # mut <label> <PA|WC> <perl-expr>
  local d pa="$PA" wc="$WC" c rc; d=$(mktemp -d -p "$W") || return 1
  if [ "$2" = PA ]; then c="$d/ProfileActivity.java"; pa="$c"; cp "$PA" "$c"; else c="$d/WipeChoice.java"; wc="$c"; cp "$WC" "$c"; fi
  if ! perl -0pi -e "$3" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if { [ "$2" = PA ] && cmp -s "$PA" "$c"; } || { [ "$2" = WC ] && cmp -s "$WC" "$c"; }; then
    echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  suite "$pa" "$wc" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    1) echo "  CONVICTED $1"; return 0 ;;
    0) echo "  SURVIVED  $1"; return 1 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile or extract (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "P1 choice 0 writes wipe=0 (power-off, the opposite direction)" WC 's/HOURS = \{ 1, 1,/HOURS = { 0, 1,/' || fails=$((fails+1))
mut "P2 wipesaved written in a separate write, before wipe" PA 's/(private boolean writeWipePref\(int i\) \{\n).*?\n    \}\n/$1        setPref(WipeOnSave.PREF, WipeChoice.savedValue(i));\n        setPref("wipe", WipeChoice.wipeValue(i));\n        return true;\n    }\n/s' || fails=$((fails+1))
mut "P3 prefsText drops the wipesaved line" PA 's/\n *if \(WipeOnSave\.on\(wipesaved\)\) sb\.append[^\n]*//' || fails=$((fails+1))
mut "P4 selected ignores wipesaved" WC 's/if \(WipeOnSave\.on\(wipesaved\)\) return 0;//' || fails=$((fails+1))
mut "P5 the label changed" WC 's/"Right away, once saved"/"Right away"/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "PASS: 5 of 5 mutants convicted" || { echo "== $fails mutant(s) not convicted"; exit 1; }
