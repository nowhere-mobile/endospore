#!/usr/bin/env bash
# test-new-profile-night-mode-java.sh [--mutate] -- a new profile's Android dark theme starts from the gate's look,
# under javac (NWP-20261124-18).
#
# WHY THIS IS COMMITTED. docs/product-decisions.md (2026-11-02, #14, option A) decided a new profile's Android
# dark-theme setting starts from the gate's look, at creation only; after that the profile's own setting wins.
# NewProfileNightMode.java is pure java.lang and is compiled as-is with GatePalette.java and
# core/chooser/tests/new-profile-night-mode/NewProfileNightModeCases.java; that directory's run.sh then PINS the
# wiring the cases cannot see: roamLogin's tail calls ensureCreateNightMode(uid) exactly once, under if (isCreate),
# after prepRoamedUser(uid) and before the switch-in, and the method reads GatePalette.KEY from the nowhere_gate
# prefs and writes Secure ui_night_mode into THAT user's resolver (createContextAsUser), on the caller's thread,
# catching Throwable and naming no profile.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-new-profile-night-mode-java.sh            # the cases and the pins
#   bash test-new-profile-night-mode-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRCDIR="$root/core/chooser/src/com/nowhere/chooser"
ACT="$SRCDIR/ChooserActivity.java"
CLS="$SRCDIR/NewProfileNightMode.java"
PAL="$SRCDIR/GatePalette.java"
RUN="$root/core/chooser/tests/new-profile-night-mode/run.sh"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip." >&2
  exit 2
fi
export JAVAC JAVA
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "FAIL: this suite needs perl" >&2; exit 2; }
[ -f "$RUN" ] || { echo "FAIL: missing $RUN" >&2; exit 2; }

echo "== $ACT"
bash "$RUN" "$SRCDIR" "$W" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED by a case or a pin: rc 1 only)"
fails=0
# mut <label> <target: cls|act> <perl-expr>
mut() {
  local label="$1" target="$2" expr="$3" d rc a c p
  d=$(mktemp -d -p "$W"); a="$d/ChooserActivity.java"; c="$d/NewProfileNightMode.java"; p="$d/GatePalette.java"
  cp "$ACT" "$a"; cp "$CLS" "$c"; cp "$PAL" "$p"
  if [ "$target" = cls ]; then perl -0pi -e "$expr" "$c"; else perl -0pi -e "$expr" "$a"; fi
  if cmp -s "$c" "$CLS" && cmp -s "$a" "$ACT"; then echo "  INERT     $label"; fails=$((fails+1)); return; fi
  bash "$RUN" "$d" "$W" >/dev/null 2>"$d/err"; rc=$?
  if [ "$rc" = 1 ]; then echo "  CONVICTED $label"
  else echo "  SURVIVED  $label (rc $rc)"; sed 's/^/      /' "$d/err" | head -5; fails=$((fails+1)); fi
}
mut 'N1 the isCreate guard removed (an existing profile rewritten)' act 's/^([ \t]*)if \(isCreate\) (ensureCreateNightMode\(uid\);)/$1$2/m'
mut 'N2 the values swapped' cls 's/\? MODE_NO : MODE_YES/? MODE_YES : MODE_NO/'
mut 'N3 absent read as light' cls 's/GatePalette\.LIGHT_VALUE\.equals\(gateLook\)/(gateLook == null || GatePalette.LIGHT_VALUE.equals(gateLook))/'
mut 'N4 the call moved after the switch-in' act 's/^([ \t]*if \(isCreate\) ensureCreateNightMode\(uid\);[^\n]*\n)((?:.*\n)*?)([ \t]*runOnUiThread\(\(\) -> \{ switchingIn = true;[^\n]*switchToUser\(uid[^\n]*\n)/$2$3$1/m'
mut "N5 the gate's resolver (no createContextAsUser)" act 's/(private void ensureCreateNightMode\(int uid\).*?)createContextAsUser\(android\.os\.UserHandle\.of\(uid\), 0\)\.getContentResolver\(\)/$1getContentResolver()/s'
mut 'N6 another prefs key' act 's/(private void ensureCreateNightMode\(int uid\).*?)GatePalette\.KEY/$1"gate_look_x"/s'
mut 'N7 Settings.Global, not Secure' act 's/(private void ensureCreateNightMode\(int uid\).*?)Settings\.Secure\.putInt/$1Settings.Global.putInt/s'
mut 'N8 MODE_YES is 0 (MODE_NIGHT_AUTO)' cls 's/MODE_YES = 2/MODE_YES = 0/'
mut 'N9 the catch narrowed' act 's/(private void ensureCreateNightMode\(int uid\).*?)catch \(Throwable t\)/$1catch (RuntimeException t)/s'
mut 'N10 the log names the profile' act 's/(private void ensureCreateNightMode\(int uid\) \{\n)/$1        android.util.Log.i("NowhereChooser", "x" + name);\n/'
mut 'N11 the look case-folded' cls 's/LIGHT_VALUE\.equals\(gateLook\)/LIGHT_VALUE.equalsIgnoreCase(gateLook)/'
mut 'N12 the write put on its own Thread' act 's/(private void ensureCreateNightMode\(int uid\) \{\n)(.*?\n    \}\n)/$1        new Thread(() -> {\n$2        }).start();\n    }\n/s'
[ "$fails" = 0 ] || { echo "FAILED: $fails mutant(s) not convicted"; exit 1; }
echo "all mutants convicted"
