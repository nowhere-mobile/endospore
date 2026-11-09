#!/usr/bin/env bash
# test-settings-text-java.sh [--mutate] -- the Profile settings writers read their file strictly, under javac
# (NWP-20261111-17).
#
# WHY THIS IS COMMITTED. cfgPut (nowhere-config), setTierOverride (nowhere-media-tiers) and setPinned (nowhere-pins)
# read their file, change one entry and rewrite the whole file. They used to read through readConfig / readTiers /
# readPins, which return empty on ANY failure, so a file that exists and cannot be opened (EIO, a wrong owner after a
# restore) was rewritten with the one change -- every other default, choice or pin gone -- and setTierOverride
# DELETED nowhere-media-tiers when the removal left the map empty. The next seal carried the loss. SettingsText.read
# tells absent ("") from unreadable (null); the three writers log and return on null before any writeAtomic or delete.
# SettingsText is java.* only and compiled here with its cases (core/chooser/tests/settings-text); the same run holds
# the source checks on the real ProfileActivity.java (comments stripped).
#
# NWP-20261129-15: setPref and writeWipePref read nowhere-prefs the same way (S7, S8). They composed from readPrefsText,
# which returns "" on any failure, and capturePrefs calls setPref at every sign-out, so one sign-out over an unreadable
# file kept only tz= (empty) and locale=. readPrefsText stays lenient for the screens.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-settings-text-java.sh            # the cases and the source checks
#   bash test-settings-text-java.sh --mutate   # ... plus M1-M8, each of which must be CONVICTED
#
# SETTINGS_TEXT_SRC / PROFILE_SRC override the two sources (to prove the suite red on an older tree).
# Exit: 0 all pass, 1 a check failed or a mutant was not convicted, 2 the suite itself could not run.
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export ST_ROOT="$W"

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
ST="${SETTINGS_TEXT_SRC:-$SRC/SettingsText.java}"
PA="${PROFILE_SRC:-$SRC/ProfileActivity.java}"
RUN="$root/core/chooser/tests/settings-text/run.sh"
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
[ -f "$RUN" ] || { echo "FAIL: missing $RUN" >&2; exit 2; }

echo "== $ST against $PA"
bash "$RUN" "$ST" "$PA"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAILED (rc=$rc)"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not apply or does not compile proves nothing)"
# mut <label> st|pa <perl-expr>: mutate a copy of SettingsText.java or ProfileActivity.java; the run must fail (rc 1).
mut() {
  local label="$1" which="$2" expr="$3" d orig c rc
  d=$(mktemp -d -p "$W") || return 1
  case "$which" in st) orig="$ST" ;; pa) orig="$PA" ;; *) rm -rf "$d"; return 1 ;; esac
  c="$d/$(basename "$orig")"
  cp "$orig" "$c"
  if ! perl -0pi -e "$expr" "$c"; then echo "  ERROR     $label -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$c"; then echo "  INERT     $label -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  if [ "$which" = st ]; then bash "$RUN" "$c" "$PA" >/dev/null 2>&1; rc=$?
  else bash "$RUN" "$ST" "$c" >/dev/null 2>&1; rc=$?; fi
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $label"; return 1 ;;
    1) echo "  convicted $label"; return 0 ;;
    *) echo "  BROKEN    $label -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "M1 read returns \"\" for a file it cannot read (R3)" st \
  's/catch \(Throwable t\) \{\s*return null;/catch (Throwable t) {\n            return "";/' || fails=$((fails+1))
mut "M2 setTierOverride's null branch moved below the delete (S2)" pa \
  's/(\n[ \t]*if \(text == null\) \{\n[^\n]*"nowhere-media-tiers unreadable[^\n]*\n[ \t]*return(?: false)?;\n[ \t]*\})(.*?\n([ \t]*)if \(m\.isEmpty\(\)\) \{ f\.delete\(\); return(?: !f\.exists\(\))?; \})/$2$1/s' \
  || fails=$((fails+1))
mut "M3 cfgPut's null branch removed (S1)" pa \
  's/\n[ \t]*if \(text == null\) \{\n[^\n]*"nowhere-config unreadable[^\n]*\n[ \t]*return;\n[ \t]*\}//' || fails=$((fails+1))
mut "M4 parseConfig stops skipping # lines (P1)" st \
  's/if \(ln\.isEmpty\(\) \|\| ln\.startsWith\("#"\) \|\| eq <= 0\)/if (ln.isEmpty() || eq <= 0)/' || fails=$((fails+1))
mut "M5 parseTiers splits on the last space (P2)" st \
  's/int sp = ln\.indexOf\(\x27 \x27\);/int sp = ln.lastIndexOf(\x27 \x27);/' || fails=$((fails+1))
mut "M6 setPref composes from readPrefsText() again (S7)" pa \
  's/prefsUpdated\(cur, key, value,/prefsUpdated(readPrefsText(), key, value,/' || fails=$((fails+1))
mut "M7 writeWipePref's null branch removed (S8)" pa \
  's/(private boolean writeWipePref\(int i\) \{\n[^\n]*\n)[ \t]*if \(cur == null\) \{\n[^\n]*\n[ \t]*return false;\n[ \t]*\}\n/$1/' || fails=$((fails+1))
mut "M8 setPref's null branch returns true (S7)" pa \
  's/(private boolean setPref\(String key, String value\) \{\n[^\n]*\n[ \t]*if \(cur == null\) \{\n[^\n]*\n[ \t]*)return false;/$1return true;/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
