#!/usr/bin/env bash
# test-gate-look-java.sh [--mutate] -- the gate's owner-only look switch, the absent Light mode switch, and the call
# and alarm screens drawn from the palette, under javac (NWP-20261115-16, NWP-20261130-13).
#
# WHY THIS IS COMMITTED. docs/product-decisions.md (2026-10-26) gives the gate a light mode: one device-wide setting,
# changed only in Owner settings behind the owner passphrase, persisted with the gate's other user-0 settings, and it
# includes the incoming-call and gate-alarm screens. NWP-20261115-15 built GatePalette and the read; this slice builds
# the write. GateLookCopy.java is pure java, compiled as-is with core/chooser/tests/gate-look/GateLookCases.java, which
# pins its strings byte for byte. The PINS check the wiring the cases cannot see: the Appearance row in buildOwnerMenu
# after Mobile data and before Device passphrase; buildGateLookScreen ends with the Back row and ownerScroll (the
# one-way-door guard); applyGateBars returns at once for a dark palette; applyGateLook ends with applyGateBars; IncomingCallActivity and
# GateAlarmActivity hold no colour literal, read the look first in buildUi and draw every role from it; and
# docs/threat-model.md's nowhere_gate.xml row names gate_look.
#
# NWP-20261124-15 (docs/product-decisions.md, 2026-11-02, "twenty-four answers ...", #11): a second switch on the same
# screen, "Only the owner can change the look", makes the look owner-only. The cases pin its two strings (C8, C9). L13
# pins the second switch's words and its place (below the intro, above the Back row); L14 its state, read from GateLookGlyph.OWNER_ONLY_KEY
# before its listener is set; L15 its write of OWNER_ONLY_KEY with commit() (never apply()) and recreate() only on
# success; L16 its revert without the listener and GateLookCopy.FAILED on a failed commit. L12 also wants
# gate_look_owner_only in the threat-model row.
#
# NWP-20261130-13 (docs/product-decisions.md, 2026-11-06, "Owner settings loses Appearance ..."): the Light mode switch
# is gone, so its pins L3-L6 are gone with it. The gate's sun/moon is the only light/dark control. The Appearance entry
# and its screen stay only because they hold the owner-only switch (2026-11-02 #11), which the slice must keep reachable.
# C10 pins that GateLookCopy holds none of the switch's words. L17 pins that the screen holds one switch, ownerSw, and
# no reference to gate_look. L18 pins that toggleGateLook is the one writer of gate_look in the chooser, with no
# remove() anywhere, so the stored value stays. L19 pins that the threat-model row no longer names the removed writer.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-gate-look-java.sh            # the cases and the pins
#   bash test-gate-look-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRCDIR="$root/core/chooser/src/com/nowhere/chooser"
ACT="$SRCDIR/ChooserActivity.java"
CPY="$SRCDIR/GateLookCopy.java"
INC="$SRCDIR/IncomingCallActivity.java"
PROF="$SRCDIR/ProfileActivity.java"
ALM="$SRCDIR/GateAlarmActivity.java"
TM="$root/docs/threat-model.md"
CASES="$root/core/chooser/tests/gate-look/GateLookCases.java"
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
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "FAIL: this suite needs perl" >&2; exit 2; }

# body <file> <signature-substring> -> the member from its signature line to the brace that closes it
body() {
  awk -v sig="$2" '
    !on && index($0, sig) { on=1; depth=0 }
    on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
  ' "$1"
}

# nocomment <text> -> the text without its // comment lines, its /* */ lines, its trailing " // " comments and its
# blank lines
nocomment() {
  printf '%s\n' "$1" | awk '
    { s=$0; sub(/^[ \t]+/, "", s) }
    s == "" { next }
    s ~ /^(\/\/|\*|\/\*)/ { next }
    { i=index($0, " // "); if (i) $0=substr($0, 1, i-1); print }'
}

# line_of <text> <fixed-string> -> "<count> <first line number>" of the lines holding the string (the string goes
# through the environment: awk -v would turn its \n into a newline)
line_of() {
  printf '%s\n' "$1" | S="$2" awk 'index($0, ENVIRON["S"]) { n++; if (!first) first=NR } END { print n+0, first+0 }'
}

# one <text> <fixed-string> <pin> -> the line number of the one line holding the string, or a failure (rc 1)
one() {
  local n l
  read -r n l <<<"$(line_of "$1" "$2")"
  [ "$n" = 1 ] || { echo "--- FAIL $3: $n lines hold: $2 -- want 1" >&2; return 1; }
  echo "$l"
}

# none_re <text> <ERE> <pin> -> rc 1 when any line matches the pattern
none_re() {
  local hits
  hits=$(printf '%s\n' "$1" | grep -nE "$2" || true)
  [ -z "$hits" ] || { echo "--- FAIL $3: $(printf "%s\n" "$hits" | wc -l) lines match $2:" >&2; printf '%s\n' "$hits" | head -5 | sed 's/^/      /' >&2; return 1; }
}

# listener <text> <switch-var> -> the lines from '<var>.setOnCheckedChangeListener(new ' to the first '});' after it
listener() {
  printf '%s\n' "$1" | V="$2.setOnCheckedChangeListener(new " awk '
    !on && index($0, ENVIRON["V"]) { on=1 }
    on { print; s=$0; sub(/^[ \t]+/, "", s); if (s == "});") exit }'
}

# nth <text> <n> -> line n of the text, without its leading and trailing blanks
nth() {
  printf '%s\n' "$1" | awk -v n="$2" 'NR == n { sub(/^[ \t]+/, ""); sub(/[ \t]+$/, ""); print; exit }'
}

# NOWHERE-1222's colour-literal pattern (test-gate-palette-java.sh).
FORBIDDEN='0[xX][0-9A-Fa-f]{8}|parseColor\(|Color\.(BLACK|WHITE|GRAY|DKGRAY|LTGRAY|RED|GREEN|BLUE|YELLOW|CYAN|MAGENTA)\b'
# NWP-20261130-13: a call that changes the stored look.
LOOK_WRITE='(putString|remove)\((GatePalette\.KEY|"gate_look")'
READ_LOOK='pal = GatePalette.forLook(getSharedPreferences("nowhere_gate", MODE_PRIVATE).getString(GatePalette.KEY, null));'
BARS_CALL='ChooserActivity.applyGateBars(getWindow(), pal);'
INC_ROLES='root.setBackgroundColor(pal.callBg);|statusView.setTextColor(pal.callLabel);|numberView.setTextColor(pal.callInk);|timerView.setTextColor(pal.callTimer);|bigBtn("Decline", pal.decline,|bigBtn("Answer", pal.answer,|bigBtn("Mute", pal.neutralBtn,|bigBtn("Speaker", pal.neutralBtn,|bigBtn("Hang up", pal.decline,|b.setTextColor(pal.onBtn);'
ALM_ROLES='root.setBackgroundColor(pal.callBg);|label.setTextColor(pal.callLabel);|time.setTextColor(pal.callInk);|bigBtn("Snooze", pal.neutralBtn,|bigBtn("Dismiss", pal.answer,|btn.setTextColor(pal.onBtn);'

# cases <GateLookCopy.java> -> 0 pass, 1 a case failed, 3 the class or the cases did not compile
cases() {
  local d
  d=$(mktemp -d -p "$W")
  cp "$1" "$d/GateLookCopy.java"; cp "$CASES" "$d/GateLookCases.java"
  "$JAVAC" -encoding UTF-8 -J-Djava.io.tmpdir="$W" -d "$d" "$d/GateLookCopy.java" "$d/GateLookCases.java" >&2 \
    || return 3
  "$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d" com.nowhere.chooser.GateLookCases >&2 || return 1
}

# screen <file> <label> <roles> -> rc 1 when the call or alarm screen keeps a literal or does not draw from the look
screen() {
  local f="$1" label="$2" roles="$3" b r fails=0 IFS_SAVE
  none_re "$(cat "$f")" "$FORBIDDEN" "L10 a colour literal in $label" || fails=1
  none_re "$(cat "$f")" '^import android\.graphics\.Color;' "L10 $label still imports Color" || fails=1
  one "$(nocomment "$(cat "$f")")" '    private GatePalette pal = GatePalette.DARK;' "L10 $label" >/dev/null || fails=1
  b=$(nocomment "$(body "$f" 'private View buildUi() {')")
  if [ -z "$b" ]; then echo "--- FAIL L10: no buildUi() in $label" >&2; fails=1
  else
    [ "$(nth "$b" 2)" = "$READ_LOOK" ] || { echo "--- FAIL L10: $label buildUi does not read the look first: $(nth "$b" 2)" >&2; fails=1; }
    [ "$(nth "$b" 3)" = "$BARS_CALL" ] || { echo "--- FAIL L10: $label buildUi does not call applyGateBars second: $(nth "$b" 3)" >&2; fails=1; }
  fi
  IFS_SAVE=$IFS; IFS='|'
  for r in $roles; do
    IFS=$IFS_SAVE
    one "$(nocomment "$(cat "$f")")" "$r" "L11 $label" >/dev/null || fails=1
    IFS='|'
  done
  IFS=$IFS_SAVE
  return "$fails"
}

# suite <ChooserActivity.java> <GateLookCopy.java> <IncomingCallActivity.java> <GateAlarmActivity.java> <threat-model.md>
#       <ProfileActivity.java>
# -> 0 pass, 1 a case or a pin failed, 2 a source is missing, 3 the class did not compile. Only 1 convicts a mutant.
suite() {
  local f="$1" cpy="$2" inc="$3" alm="$4" tm="$5" prof="$6" rc x b ob ln lmd lpass lset llis l1 l2 l3 l4 last prev next n fails=0
  for x in "$f" "$cpy" "$inc" "$alm" "$tm" "$prof" "$CASES"; do [ -f "$x" ] || { echo "  missing $x" >&2; return 2; }; done
  cases "$cpy"; rc=$?
  case "$rc" in 0) ;; 1) fails=1 ;; 3) echo "  the class or the cases did not compile" >&2; return 3 ;; *) return 2 ;; esac

  # L1 one Appearance row in buildOwnerMenu, after the Mobile data row and before the Device passphrase row.
  b=$(nocomment "$(body "$f" 'private View buildOwnerMenu() {')")
  if [ -z "$b" ]; then echo "--- FAIL L1: no buildOwnerMenu() in $f" >&2; fails=1
  elif ln=$(one "$b" 'll.addView(settingsRow(GateLookCopy.ROW, GateLookCopy.ROW_SUB, v -> setContentView(buildGateLookScreen())), new LinearLayout.LayoutParams(MATCH, WRAP));' L1) \
       && lmd=$(one "$b" 'settingsRow(GateMobileData.ROW, GateMobileData.ROW_SUB,' L1) \
       && lpass=$(one "$b" 'settingsRow("Device passphrase"' L1); then
    [ "$ln" -gt "$lmd" ] && [ "$ln" -lt "$lpass" ] || {
      echo "--- FAIL L1: order: Mobile data at $lmd, Appearance at $ln, Device passphrase at $lpass" >&2; fails=1; }
  else fails=1
  fi

  # L2-L7 buildGateLookScreen.
  b=$(nocomment "$(body "$f" 'private View buildGateLookScreen() {')")
  if [ -z "$b" ]; then echo "--- FAIL L2: no buildGateLookScreen() in $f" >&2; fails=1
  else
    for x in 'ownerColumn(GateLookCopy.ROW)' 'setText(GateLookCopy.INTRO)'; do
      one "$b" "$x" L2 >/dev/null || fails=1
    done
    # L17 no Light mode switch: the one switch here is the owner-only one, and nothing here touches gate_look.
    none_re "$b" 'lookSw|GatePalette\.KEY|GateLookCopy\.(SWITCH|NOTE)|putString\(' 'L17 the light switch in buildGateLookScreen' || fails=1
    one "$b" 'new android.widget.Switch(' L17 >/dev/null || fails=1
    ob=$(listener "$b" ownerSw)
    [ -n "$ob" ] || { echo "--- FAIL L14: no listener on ownerSw" >&2; fails=1; }
    none_re "$b" '\.apply\(\)' 'L15 apply() in buildGateLookScreen' || fails=1
    # L13 the owner-only switch's words, below the intro and above the Back row.
    one "$b" 'ownerSw.setText(GateLookCopy.OWNER_ONLY);' L13 >/dev/null || fails=1
    one "$b" 'setText(GateLookCopy.OWNER_ONLY_NOTE)' L13 >/dev/null || fails=1
    if l1=$(one "$b" 'll.addView(intro, ip);' L13) && l2=$(one "$b" 'll.addView(ownerSw, op);' L13) \
       && l3=$(one "$b" 'll.addView(ownerNote, onp);' L13) && l4=$(one "$b" 'll.addView(ownerBack(' L13); then
      [ "$l1" -lt "$l2" ] && [ "$l2" -lt "$l3" ] && [ "$l3" -lt "$l4" ] || {
        echo "--- FAIL L13: order: intro at $l1, owner-only switch at $l2, its note at $l3, Back at $l4" >&2; fails=1; }
    else fails=1
    fi
    # L14 the owner-only state, from OWNER_ONLY_KEY, before its listener.
    if lset=$(one "$b" 'ownerSw.setChecked(getSharedPreferences("nowhere_gate", MODE_PRIVATE).getBoolean(GateLookGlyph.OWNER_ONLY_KEY, false));' L14) \
       && llis=$(one "$b" 'ownerSw.setOnCheckedChangeListener(new ' L14); then
      [ "$lset" -lt "$llis" ] || { echo "--- FAIL L14: ownerSw.setChecked at $lset is not before its listener at $llis" >&2; fails=1; }
    else fails=1
    fi
    # L15 the owner-only write with commit(), never apply(); recreate() only on success; never GatePalette.KEY.
    one "$ob" 'boolean ok = getSharedPreferences("nowhere_gate", MODE_PRIVATE).edit().putBoolean(GateLookGlyph.OWNER_ONLY_KEY, c).commit();' L15 >/dev/null || fails=1
    none_re "$ob" '\.apply\(\)' 'L15 apply() in the owner-only listener' || fails=1
    if ln=$(one "$ob" 'recreate();' L15); then
      prev=$(nth "$ob" $((ln - 1))); next=$(nth "$ob" $((ln + 1)))
      [ "$prev" = 'if (ok) {' ] && [ "$next" = 'return;' ] || {
        echo "--- FAIL L15: the owner-only recreate() is not alone in 'if (ok) { ... return; }': before '$prev', after '$next'" >&2; fails=1; }
    else fails=1
    fi
    n=$(printf '%s\n' "$ob" | grep -c 'GatePalette\.KEY' || true)
    [ "$n" = 0 ] || { echo "--- FAIL L15: the owner-only listener touches GatePalette.KEY" >&2; fails=1; }
    # L16 a failed owner-only commit puts the switch back without firing the listener, then says so.
    if l1=$(one "$ob" 'b.setOnCheckedChangeListener(null);' L16) && l2=$(one "$ob" 'b.setChecked(!c);' L16) \
       && l3=$(one "$ob" 'b.setOnCheckedChangeListener(this);' L16) && l4=$(one "$ob" 'GateLookCopy.FAILED' L16); then
      [ "$l1" -lt "$l2" ] && [ "$l2" -lt "$l3" ] && [ "$l3" -lt "$l4" ] || {
        echo "--- FAIL L16: the owner-only revert is out of order ($l1 $l2 $l3, FAILED at $l4)" >&2; fails=1; }
    else fails=1
    fi
    # L7 the one-way-door guard: the Back row, then ownerScroll, as the last two statements.
    n=$(printf '%s\n' "$b" | wc -l)
    [ "$(nth "$b" $((n - 2)))" = 'll.addView(ownerBack("Back", v -> setContentView(buildOwnerMenu())), new LinearLayout.LayoutParams(MATCH, WRAP));' ] \
      && [ "$(nth "$b" $((n - 1)))" = 'return ownerScroll(ll);' ] || {
      echo "--- FAIL L7: buildGateLookScreen does not end with the Back row and ownerScroll: '$(nth "$b" $((n - 2)))' '$(nth "$b" $((n - 1)))'" >&2; fails=1; }
  fi

  # L8 applyGateBars: a dark palette returns at once; every bar call is guarded.
  b=$(nocomment "$(body "$f" 'static void applyGateBars(android.view.Window w, GatePalette p) {')")
  if [ -z "$b" ]; then echo "--- FAIL L8: no applyGateBars(Window, GatePalette) in $f" >&2; fails=1
  else
    [ "$(nth "$b" 2)" = 'if (!p.lightBars) return;' ] || { echo "--- FAIL L8: the first statement of applyGateBars is not the dark return: $(nth "$b" 2)" >&2; fails=1; }
    for x in 'setStatusBarColor(p.bg)' 'setNavigationBarColor(p.bg)' 'APPEARANCE_LIGHT_STATUS_BARS' 'APPEARANCE_LIGHT_NAVIGATION_BARS' 'SDK_INT >= 30'; do
      one "$b" "$x" L8 >/dev/null || fails=1
    done
    n=$(printf '%s\n' "$b" | grep -c 'catch (Throwable' || true)
    [ "$n" -ge 3 ] || { echo "--- FAIL L8: $n catch (Throwable in applyGateBars, want 3 or more" >&2; fails=1; }
  fi

  # L9 applyGateLook ends with applyGateBars.
  b=$(nocomment "$(body "$f" 'private void applyGateLook() {')")
  n=$(printf '%s\n' "$b" | wc -l)
  last=$(nth "$b" $((n - 1)))
  [ -n "$b" ] && [ "$last" = 'applyGateBars(getWindow(), p);' ] || {
    echo "--- FAIL L9: applyGateLook does not end with applyGateBars(getWindow(), p): '$last'" >&2; fails=1; }

  # L10, L11 the call and alarm screens.
  screen "$inc" IncomingCallActivity "$INC_ROLES" || fails=1
  screen "$alm" GateAlarmActivity "$ALM_ROLES" || fails=1

  # L12 the threat-model row names the key.
  b=$(grep -F '| `shared_prefs/nowhere_gate.xml` |' "$tm" || true)
  n=$(printf '%s' "$b" | grep -c '^' || true)
  if [ "$n" != 1 ]; then echo "--- FAIL L12: $n nowhere_gate.xml rows in $tm, want 1" >&2; fails=1
  else
    for x in '`gate_look`' 'buildGateLookScreen' 'DURABLE-EXEMPT' '`gate_look_owner_only`'; do
      case "$b" in *"$x"*) ;; *) echo "--- FAIL L12: the nowhere_gate.xml row does not hold $x" >&2; fails=1 ;; esac
    done
  fi

  # L18 the sun/moon is the chooser's one writer of gate_look, and nothing removes the stored value.
  b=$(nocomment "$(cat "$f")")
  n=$(printf '%s\n' "$b" | grep -cE "$LOOK_WRITE" || true)
  [ "$n" = 1 ] || { echo "--- FAIL L18: $n lines change gate_look in ChooserActivity, want 1" >&2; fails=1; }
  b=$(nocomment "$(body "$f" 'private void toggleGateLook() {')")
  one "$b" 'boolean ok = getSharedPreferences("nowhere_gate", MODE_PRIVATE).edit().putString(GatePalette.KEY, GateLookGlyph.next(stored)).commit();' L18 >/dev/null || fails=1
  b=$(grep -nE "$LOOK_WRITE" "$prof" || true)
  x=$(grep -rnE --include='*.java' --exclude=ChooserActivity.java --exclude=ProfileActivity.java "$LOOK_WRITE" "$SRCDIR" || true)
  [ -z "$b$x" ] || { echo "--- FAIL L18: another class changes gate_look: $b$x" >&2; fails=1; }

  # L19 the threat-model row does not name the removed writer. (L12 has already refused a row count that is not 1.)
  b=$(grep -F '| `shared_prefs/nowhere_gate.xml` |' "$tm" || true)
  for x in 'Light mode' 'by the owner in Owner settings'; do
    case "$b" in *"$x"*) echo "--- FAIL L19: the nowhere_gate.xml row still holds $x" >&2; fails=1 ;; esac
  done

  [ "$fails" = 0 ] || return 1
  echo "  pins ok"
}

echo "== $ACT"
suite "$ACT" "$CPY" "$INC" "$ALM" "$TM" "$PROF" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED: rc 1 with a --- FAIL line)"
fails=0
# mut <label> <target: act|copy|inc|alarm|tm|prof> <perl-expr> [<substring the failure output must hold>]
mut() {
  local label="$1" target="$2" expr="$3" expect="${4:-}" d rc src copy
  d=$(mktemp -d -p "$W")
  cp "$ACT" "$d/ChooserActivity.java"; cp "$CPY" "$d/GateLookCopy.java"; cp "$INC" "$d/IncomingCallActivity.java"
  cp "$ALM" "$d/GateAlarmActivity.java"; cp "$TM" "$d/threat-model.md"; cp "$PROF" "$d/ProfileActivity.java"
  case "$target" in
    act) src="$ACT"; copy="$d/ChooserActivity.java" ;;
    copy) src="$CPY"; copy="$d/GateLookCopy.java" ;;
    inc) src="$INC"; copy="$d/IncomingCallActivity.java" ;;
    alarm) src="$ALM"; copy="$d/GateAlarmActivity.java" ;;
    tm) src="$TM"; copy="$d/threat-model.md" ;;
    prof) src="$PROF"; copy="$d/ProfileActivity.java" ;;
  esac
  perl -0pi -e "$expr" "$copy"
  if cmp -s "$copy" "$src"; then echo "  INERT     $label"; fails=$((fails+1)); return; fi
  suite "$d/ChooserActivity.java" "$d/GateLookCopy.java" "$d/IncomingCallActivity.java" "$d/GateAlarmActivity.java" \
    "$d/threat-model.md" "$d/ProfileActivity.java" >"$d/out" 2>&1; rc=$?
  if [ "$rc" = 1 ] && grep -q -- '--- FAIL' "$d/out" && { [ -z "$expect" ] || grep -qF -- "$expect" "$d/out"; }; then
    echo "  CONVICTED $label"
    grep -m1 -- '--- FAIL' "$d/out" | sed 's/^/      /'
  else
    echo "  SURVIVED  $label (rc $rc)"; sed 's/^/      /' "$d/out" | head -5; fails=$((fails+1))
  fi
}
mut 'M1 the Appearance row removed' act 's/\n[ \t]*ll\.addView\(settingsRow\(GateLookCopy\.ROW[^\n]*//' 'L1'
mut 'M5 applyGateBars without its dark early return' act 's/\n[ \t]*if \(!p\.lightBars\) return;//' 'L8'
mut "M6 GateAlarmActivity's Dismiss back to its literal" alarm 's/bigBtn\("Dismiss", pal\.answer,/bigBtn("Dismiss", 0xFF2FA84F,/' 'L10'
mut "M7 IncomingCallActivity's buildUi with no look read" inc 's/\n[ \t]*pal = GatePalette\.forLook\([^\n]*//' 'L10'
mut 'M8 gate_look dropped from the threat-model row' tm 's/^(\| `shared_prefs\/nowhere_gate\.xml` \|[^\n]*)$/my $r = $1; $r =~ s{`gate_look`}{}g; $r/me' 'L12'
mut 'M9 a GateLookCopy string changed' copy "s/Who can change this phone's look/Who can change the look/" 'C2'
mut 'M10 the Back row removed from buildGateLookScreen' act 's/(GateLookCopy\.FAILED.*?)\n[ \t]*ll\.addView\(ownerBack\([^\n]*/$1/s' 'L7'
mut 'M11 applyGateLook without applyGateBars' act 's/\n[ \t]*applyGateBars\(getWindow\(\), p\);//' 'L9'
mut 'M12 (G3) the owner-only switch writes with apply()' act 's/putBoolean\(GateLookGlyph\.OWNER_ONLY_KEY, c\)\.commit\(\);/putBoolean(GateLookGlyph.OWNER_ONLY_KEY, c).apply();/' 'L15'
mut 'M13 (G4) the owner-only switch state read from GatePalette.KEY' act 's/ownerSw\.setChecked\(getSharedPreferences\("nowhere_gate", MODE_PRIVATE\)\.getBoolean\(GateLookGlyph\.OWNER_ONLY_KEY/ownerSw.setChecked(getSharedPreferences("nowhere_gate", MODE_PRIVATE).getBoolean(GatePalette.KEY/' 'L14'
mut 'M14 the owner-only listener set before setChecked' act 's/(\n[ \t]*ownerSw\.setChecked\([^\n]*)(\n[ \t]*ownerSw\.setOnCheckedChangeListener\(new .*?\n        \}\);)/$2$1/s' 'L14'
mut 'M15 recreate() also on a failed owner-only commit' act 's/(ownerSw\.setOnCheckedChangeListener\(new .*?\n[^\n]*GateLookCopy\.FAILED[^\n]*)/$1\n                recreate();/s' 'L15'
mut 'M16 the owner-only revert removed' act 's/(ownerSw\.setOnCheckedChangeListener\(new .*?)\n[ \t]*b\.setChecked\(!c\);/$1/s' 'L16'
mut 'M17 gate_look_owner_only dropped from the threat-model row' tm 's/^(\| `shared_prefs\/nowhere_gate\.xml` \|[^\n]*)$/my $r = $1; $r =~ s{`gate_look_owner_only`}{}g; $r/me' 'L12'
mut 'M18 the OWNER_ONLY string changed' copy 's/Only the owner can change the look/Only the owner changes the look/' 'C8'
mut 'M19 a Light mode switch back on the Appearance screen' act 's/(private View buildGateLookScreen\(\) \{.*?ll\.addView\(intro, ip\);)/$1\n        final android.widget.Switch lookSw = GateSwitch.style(new android.widget.Switch(this), GatePalette.active());\n        ll.addView(lookSw, ip);/s' 'L17'
mut 'M20 the owner-only listener also writes gate_look' act 's/(boolean ok = [^\n]*putBoolean\(GateLookGlyph\.OWNER_ONLY_KEY, c\)\.commit\(\);)/$1\n                getSharedPreferences("nowhere_gate", MODE_PRIVATE).edit().putString(GatePalette.KEY, "dark").commit();/' 'L18'
mut 'M21 the sun/moon no longer writes gate_look' act 's/boolean ok = [^\n]*putString\(GatePalette\.KEY, GateLookGlyph\.next\(stored\)\)\.commit\(\);/boolean ok = true;/' 'L18'
mut 'M22 the Light mode string back in GateLookCopy' copy 's/(static final String FAILED)/static final String SWITCH = "Light mode";\n    $1/' 'C10'
mut 'M23 Light mode back in the threat-model row' tm 's/^(\| `shared_prefs\/nowhere_gate\.xml` \|)/$1 Light mode/m' 'L19'
mut 'M24 ProfileActivity writes gate_look' prof 's/(\n[^\n]*\bclass ProfileActivity\b[^\n]*\{)/$1\n    private void x() { getSharedPreferences("nowhere_gate", MODE_PRIVATE).edit().putString(GatePalette.KEY, "light").commit(); }/' 'L18'
mut 'M25 the gate start clears the stored look' act 's/(\n[ \t]*private void applyGateLook\(\) \{)/$1\n        getSharedPreferences("nowhere_gate", MODE_PRIVATE).edit().remove(GatePalette.KEY).commit();/' 'L18'
[ "$fails" = 0 ] || { echo "FAILED: $fails mutant(s) not convicted"; exit 1; }
echo "all mutants convicted"
