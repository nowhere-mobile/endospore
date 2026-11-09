#!/usr/bin/env bash
# test-profile-home-fit-java.sh [--mutate] -- the Profile app's main screen fits one screen at default display and font
# size on the smallest release device, and still scrolls past that size, run under javac (NWP-20261130-10).
#
# WHY THIS IS COMMITTED. On a Pixel on 0.5.53 the main screen scrolled and "Done" sat below the fold (docs/backlog.md,
# "The Profile app's main screen scrolls: ..."). ProfileHomeFit.java holds the spacings. This suite compiles it with
# PresetPicker.java, adds up the screen's height with a model, and pins that ProfileActivity reads those spacings.
#
# THE BUDGET. Pixel 7a (lynx) and Pixel 8 are 1080x2400 at density 420, so 914dp high. Pixel 10 (frankel) is 1080x2424,
# so 923dp. 914 less a 52dp status bar is 838 with a 24dp gesture bar and 814 with a 48dp three-button bar. The bars and
# the text heights (1.33 x sp, rounded up) are allowances, not measurements: only a handset proves the fit.
#
#   F1 each spacing has its exact value            F2 the Standard level fits 838dp
#   F3 every level fits 814dp, row text included   F4 control: the old spacings exceed 838dp, so the model can fail
#   F5 a tap target is at least 48dp               F6 the totals in ProfileHomeFit's comment: 789dp now, 882dp before
#   S1 showConfirm's top and bottom padding        S2 its gaps: name, status, Lock to Log off, above the menu
#   S3 Delete and Done: padding and minimum height S4 addPrivacyLevelCard's spacings and its row's minimum height
#   S5 the ScrollView stays and nothing hides it   S6 nothing is removed, and Lock stays the accent button
#   S7 other screens do not move                   S8 the text sizes the model assumes
#   S9 the status line is a tap target at least 48dp high
#
# F4, S5, S6, S8, four of S7's six lines and three of S9's four pin what must not change, so they hold on the tree before
# this slice; --mutate proves S5, S6, S7, S8 and S9 can fail, and M15 proves through F2 that the model can.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK; the version
# is printed first so the log proves which compiler ran.
#
#   bash test-profile-home-fit-java.sh            # the cases and the pins
#   bash test-profile-home-fit-java.sh --mutate   # ... plus broken copies that must each FAIL
# PROFILE_ACTIVITY=<file> / PROFILE_HOME_FIT=<file> / PRESET_PICKER=<file> point the suite at other copies.
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
SRC="$here/src/com/nowhere/chooser"
PA="${PROFILE_ACTIVITY:-$SRC/ProfileActivity.java}"
HF="${PROFILE_HOME_FIT:-$SRC/ProfileHomeFit.java}"
PP="${PRESET_PICKER:-$SRC/PresetPicker.java}"
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
command -v python3 >/dev/null 2>&1 || { echo "FAIL: no python3, the source pins need it" >&2; exit 2; }
[ -f "$PA" ] || { echo "FAIL: missing $PA" >&2; exit 2; }
[ -f "$PP" ] || { echo "FAIL: missing $PP" >&2; exit 2; }

CASES="$W/ProfileHomeFitCases.java"
cat > "$CASES" <<'JAVA'
package com.nowhere.chooser;

import java.util.List;

public final class ProfileHomeFitCases {
    static final int GESTURE_BUDGET = 838, BUTTONS_BUDGET = 814;
    /** The inner width of the card on a 411dp wide screen, the width of a character at 15sp, and a line's height. */
    static final double ROW_WIDTH = 335, CHAR_WIDTH = 7.6;
    static final int ROW_LINE = 20;
    /** Six 54dp rows and five 1px dividers. */
    static final int MENU = 326;
    /** The name at 30sp, the status text and the level at 13sp, the card's title at 16sp, Delete and Done at 14sp. */
    static final int NAME = 40, SMALL = 18, TITLE = 21, LINK = 19;
    static final int BUTTON = 48, SCALE = 6;
    static int fails = 0;

    static void check(String tag, boolean ok, String what) {
        System.out.println((ok ? "  ok    " : "  FAIL  ") + tag + " " + what);
        if (!ok) fails++;
    }

    static int lines(String row) {
        return (int) Math.ceil((row + "  ▾").length() * CHAR_WIDTH / ROW_WIDTH);
    }

    static int total(int rowLines) {
        int row = Math.max(ProfileHomeFit.MIN_TOUCH, rowLines * ROW_LINE + 2 * ProfileHomeFit.PICK_PAD);
        int link = Math.max(ProfileHomeFit.MIN_TOUCH, LINK + 2 * ProfileHomeFit.LINK_PAD);
        int status = Math.max(ProfileHomeFit.MIN_TOUCH, SMALL);
        return ProfileHomeFit.PAD_TOP + NAME + ProfileHomeFit.NAME_TO_STATUS + status + ProfileHomeFit.STATUS_TO_LOCK
                + BUTTON + ProfileHomeFit.LOCK_TO_LOGOFF + BUTTON
                + ProfileHomeFit.CARD_GAP + ProfileHomeFit.CARD_PAD_TOP + TITLE + ProfileHomeFit.SCALE_GAP + SCALE
                + ProfileHomeFit.LEVEL_GAP + SMALL + row + ProfileHomeFit.CARD_PAD_BOTTOM
                + ProfileHomeFit.MENU_GAP + MENU + ProfileHomeFit.LINK_GAP + link + link + ProfileHomeFit.PAD_BOTTOM;
    }

    /** The values before NWP-20261130-10: no minimum heights, Delete 30 + 19 + 8, Done 18 + 19 + 8. */
    static int oldTotal(int rowLines) {
        return 44 + NAME + 5 + SMALL + 26 + BUTTON + 10 + BUTTON
                + 20 + 14 + TITLE + 12 + SCALE + 6 + SMALL + (10 + rowLines * ROW_LINE + 4) + 14
                + 20 + MENU + (30 + LINK + 8) + (18 + LINK + 8) + 30;
    }

    static void exact(String name, int got, int want) {
        check("F1", got == want, name + " = " + got + ", want " + want);
    }

    public static void main(String[] a) {
        exact("PAD_TOP", ProfileHomeFit.PAD_TOP, 16);
        exact("PAD_BOTTOM", ProfileHomeFit.PAD_BOTTOM, 8);
        exact("NAME_TO_STATUS", ProfileHomeFit.NAME_TO_STATUS, 0);
        exact("STATUS_TO_LOCK", ProfileHomeFit.STATUS_TO_LOCK, 0);
        exact("LOCK_TO_LOGOFF", ProfileHomeFit.LOCK_TO_LOGOFF, 8);
        exact("CARD_GAP", ProfileHomeFit.CARD_GAP, 12);
        exact("CARD_PAD_TOP", ProfileHomeFit.CARD_PAD_TOP, 12);
        exact("CARD_PAD_BOTTOM", ProfileHomeFit.CARD_PAD_BOTTOM, 2);
        exact("SCALE_GAP", ProfileHomeFit.SCALE_GAP, 8);
        exact("LEVEL_GAP", ProfileHomeFit.LEVEL_GAP, 4);
        exact("PICK_PAD", ProfileHomeFit.PICK_PAD, 6);
        exact("MENU_GAP", ProfileHomeFit.MENU_GAP, 12);
        exact("LINK_GAP", ProfileHomeFit.LINK_GAP, 4);
        exact("LINK_PAD", ProfileHomeFit.LINK_PAD, 8);
        exact("MIN_TOUCH", ProfileHomeFit.MIN_TOUCH, 48);

        int standard = total(lines(PresetPicker.rowOf(ProfilePresets.STANDARD)));
        check("F2", standard <= GESTURE_BUDGET, "Standard is " + standard + "dp, budget " + GESTURE_BUDGET + "dp");

        List<String> rows = PresetPicker.dropdownRows(true);
        check("F3", rows.size() == 6, "control: 6 rows, got " + rows.size());
        for (String row : rows) {
            int t = total(lines(row));
            check("F3", t <= BUTTONS_BUDGET, row.split(" ")[0] + " is " + t + "dp, budget " + BUTTONS_BUDGET + "dp");
        }

        int old = oldTotal(2);
        check("F4", old > GESTURE_BUDGET, "control: the old spacings are " + old + "dp, over " + GESTURE_BUDGET + "dp");
        check("F5", ProfileHomeFit.MIN_TOUCH >= 48, "MIN_TOUCH is " + ProfileHomeFit.MIN_TOUCH + "dp");
        check("F6", total(2) == 789, "a two-line row totals " + total(2) + "dp, ProfileHomeFit's comment says 789dp");
        check("F6", old == 882, "the old total is " + old + "dp, ProfileHomeFit's comment says 882dp");

        if (fails > 0) System.exit(1);
    }
}
JAVA

PINS="$W/pins.py"
cat > "$PINS" <<'PY'
import sys

def strip_comments(s):
    out, i, n = [], 0, len(s)
    while i < n:
        c = s[i]
        if c in '"\'':
            j = i + 1
            while j < n and s[j] != c:
                j += 2 if s[j] == '\\' else 1
            out.append(s[i:j + 1]); i = j + 1
        elif s.startswith('//', i):
            i = s.find('\n', i)
            if i < 0: break
        elif s.startswith('/*', i):
            i = s.find('*/', i) + 2
        else:
            out.append(c); i += 1
    return ''.join(out)

def body(s, sig):
    i = s.find(sig)
    if i < 0: return ''
    i = s.index('{', i); j = i; depth = 0; n = len(s)
    while j < n:
        c = s[j]
        if c in '"\'':
            k = j + 1
            while k < n and s[k] != c:
                k += 2 if s[k] == '\\' else 1
            j = k
        elif c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0: return s[i:j + 1]
        j += 1
    return ''

s = strip_comments(open(sys.argv[1], encoding='utf-8').read())
home = body(s, 'private void showConfirm()')
card = body(s, 'private void addPrivacyLevelCard(LinearLayout parent)')
five = body(s, 'private void sectionCard(LinearLayout parent, String header, String[] labels, Runnable[] actions, boolean danger) {')
six = body(s, 'private void sectionCard(LinearLayout parent, String header, String[] labels, Runnable[] actions, boolean danger, int gapDp)')
row = body(s, 'private LinearLayout cardRow(')
menu = body(s, 'private LinearLayout menuScreen(')
accent = body(s, 'private Button accentBtn(')
second = body(s, 'private Button secondaryButton(')
fails = 0

def ok(tag, cond, what):
    global fails
    print(('  ok    ' if cond else '  FAIL  ') + tag + ' ' + what)
    if not cond: fails += 1

def has(tag, text, want, n=1):
    ok(tag, text.count(want) == n, want + (' (want %d)' % n if n != 1 else ''))

def hasnot(tag, text, want):
    ok(tag, want not in text, 'no ' + want)

ok('S1', home != '', 'control: showConfirm is found')
has('S1', home, 'll.setPadding(dp(22), dp(ProfileHomeFit.PAD_TOP), dp(22), dp(ProfileHomeFit.PAD_BOTTOM));')
hasnot('S1', home, 'dp(44)')
hasnot('S1', home, 'dp(30)')

has('S2', home, 'stlp.topMargin = dp(ProfileHomeFit.NAME_TO_STATUS);')
has('S2', home, 'stlp.bottomMargin = dp(ProfileHomeFit.STATUS_TO_LOCK);')
has('S2', home, 'll.addView(secondaryButton(logoffLabel, () -> doLogoff()), btnLp(dp(ProfileHomeFit.LOCK_TO_LOGOFF)));')
has('S2', home, '}, false, ProfileHomeFit.MENU_GAP);', 2)

has('S3', home, 'del.setPadding(dp(8), dp(ProfileHomeFit.LINK_PAD), dp(8), dp(ProfileHomeFit.LINK_PAD));')
has('S3', home, 'del.setMinHeight(dp(ProfileHomeFit.MIN_TOUCH));')
has('S3', home, 'll.addView(del, btnLp(dp(ProfileHomeFit.LINK_GAP)));')
has('S3', home, 'done.setPadding(dp(8), dp(ProfileHomeFit.LINK_PAD), dp(8), dp(ProfileHomeFit.LINK_PAD));')
has('S3', home, 'done.setMinHeight(dp(ProfileHomeFit.MIN_TOUCH));')

ok('S4', card != '', 'control: addPrivacyLevelCard is found')
has('S4', card, 'card.setPadding(dp(16), dp(ProfileHomeFit.CARD_PAD_TOP), dp(16), dp(ProfileHomeFit.CARD_PAD_BOTTOM));')
has('S4', card, 'clp.topMargin = dp(ProfileHomeFit.CARD_GAP);')
has('S4', card, 'sclp.topMargin = dp(ProfileHomeFit.SCALE_GAP);')
has('S4', card, 'llp.topMargin = dp(ProfileHomeFit.LEVEL_GAP);')
has('S4', card, 'pick.setPadding(0, dp(ProfileHomeFit.PICK_PAD), 0, dp(ProfileHomeFit.PICK_PAD));')
has('S4', card, 'pick.setMinHeight(dp(ProfileHomeFit.MIN_TOUCH));')
has('S4', card, 'pick.setGravity(Gravity.CENTER_VERTICAL);')

has('S5', home, 'android.widget.ScrollView sc = new android.widget.ScrollView(this);')
has('S5', home, 'sc.addView(ll);')
has('S5', home, 'confirmView = sc;')
has('S5', home, 'setContentView(sc);')
hasnot('S5', home, 'setFillViewport')
hasnot('S5', home, 'setVerticalScrollBarEnabled')
hasnot('S5', home, 'setScrollbarFadingEnabled')

has('S6', home, '"Storage", "Security", "Preferences", "Your data", "Report an issue", "Help"')
has('S6', home, '() -> showStorage(), () -> showSecurity(), () -> showPreferences(),')
has('S6', home, '() -> showYourData(), () -> showReportIssue(), () -> showHelp()}')
has('S6', home, 'del.setText("Delete this profile");')
has('S6', home, 'done.setText("Done");')
has('S6', home, 'addPrivacyLevelCard(ll);')
has('S6', home, 'll.addView(nameTv, new LinearLayout.LayoutParams(MATCH, WRAP));')
has('S6', home, 'll.addView(status, stlp);')
has('S6', home, 'll.addView(accentButton("Lock — keep on this device", () -> doColdLock()), btnLp(0));')

has('S7', row, 'row.setPadding(dp(16), dp(15), dp(16), dp(15));')
has('S7', menu, 'll.setPadding(dp(22), dp(44), dp(22), dp(30));')
has('S7', five, 'sectionCard(parent, header, labels, actions, danger, 20);')
has('S7', six, 'parent.addView(sp, new LinearLayout.LayoutParams(MATCH, dp(gapDp)));')
has('S7', accent, 'b.setPadding(0, dp(14), 0, dp(14));')
has('S7', second, 'b.setPadding(0, dp(13), 0, dp(13));')

has('S8', home, 'nameTv.setTextSize(TypedValue.COMPLEX_UNIT_SP, 30);')
has('S8', home, 'status.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);')
has('S8', home, 'del.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);')
has('S8', home, 'done.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);')
has('S8', card, 'title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);')
has('S8', card, 'level.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);')
has('S8', card, 'pick.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);')
has('S8', card, 'new LinearLayout.LayoutParams(0, dp(6), 1f)')

has('S9', home, 'status.setOnClickListener(v -> probeSession());')
has('S9', home, 'stv.setOnClickListener(v -> showYourData());')
has('S9', home, 'status.setMinHeight(dp(ProfileHomeFit.MIN_TOUCH));')
has('S9', home, 'status.setGravity(Gravity.CENTER);')
sys.exit(1 if fails else 0)
PY

# cases <ProfileHomeFit.java> <PresetPicker.java> -> 0 pass, 1 a case failed or the class is missing (the only codes that
# convict a mutant), 3 it did not compile.
cases() {
  local hf="$1" pp="$2" d f rc
  if [ ! -f "$hf" ]; then
    echo "  FAIL  F1 F2 F3 F5 F6 ProfileHomeFit.java does not exist: $hf"
    return 1
  fi
  d=$(mktemp -d -p "$W") || return 3
  for f in ProfilePresets WipeChoice WipeOnSave SettingsText; do cp "$SRC/$f.java" "$d/"; done
  cp "$hf" "$d/ProfileHomeFit.java"; cp "$pp" "$d/PresetPicker.java"; cp "$CASES" "$d/"
  if ! "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d/out" "$d"/*.java; then rm -rf "$d"; return 3; fi
  "$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.ProfileHomeFitCases; rc=$?
  rm -rf "$d"
  return "$rc"
}

# suite <ProfileHomeFit.java> <PresetPicker.java> <ProfileActivity.java> -> 0 pass, 1 a check failed, 3 no compile.
suite() {
  local rc=0 c
  cases "$1" "$2"; c=$?
  [ "$c" -eq 3 ] && return 3
  [ "$c" -eq 0 ] || rc=1
  python3 -I "$PINS" "$3"; c=$?
  [ "$c" -eq 0 ] || [ "$c" -eq 1 ] || return 3
  [ "$c" -eq 0 ] || rc=1
  return "$rc"
}

suite "$HF" "$PP" "$PA"; rc=$?
if [ "$rc" -ne 0 ]; then echo "FAIL: the Profile main screen's spacings (rc $rc)" >&2; exit 1; fi
[ "$MUTATE" = yes ] || { echo "PASS"; exit 0; }

# mutant <name> <the assertions that must convict it, space-separated> <hf|pp|pa> <perl substitution>
mutfails=0
mutant() {
  local name="$1" tags="$2" which="$3" expr="$4" d f t out rc miss=""
  local mhf="$HF" mpp="$PP" mpa="$PA"
  d=$(mktemp -d -p "$W") || { mutfails=$((mutfails+1)); return; }
  case "$which" in
    hf) cp "$HF" "$d/m.java"; mhf="$d/m.java" ;;
    pp) cp "$PP" "$d/m.java"; mpp="$d/m.java" ;;
    pa) cp "$PA" "$d/m.java"; mpa="$d/m.java" ;;
  esac
  f="$d/m.java"
  perl -0pi -e "$expr" "$f"
  case "$which" in hf) t="$HF" ;; pp) t="$PP" ;; pa) t="$PA" ;; esac
  if cmp -s "$f" "$t"; then
    echo "  MUTANT $name: DID NOT APPLY"; mutfails=$((mutfails+1)); rm -rf "$d"; return
  fi
  out=$(suite "$mhf" "$mpp" "$mpa" 2>&1); rc=$?
  rm -rf "$d"
  if [ "$rc" -ne 1 ]; then
    echo "  MUTANT $name: NOT CONVICTED (rc $rc)"; mutfails=$((mutfails+1)); return
  fi
  for t in $tags; do
    case "$out" in *"FAIL  $t "*) ;; *) miss="$miss $t" ;; esac
  done
  if [ -n "$miss" ]; then
    echo "  MUTANT $name: failed, but not through$miss"; mutfails=$((mutfails+1)); return
  fi
  echo "  convicted by $tags: $name"
}

echo "== mutants =="
mutant "M1 PAD_TOP back to 44"          F1 hf 's/PAD_TOP = 16;/PAD_TOP = 44;/'
mutant "M2 PAD_BOTTOM back to 30"       F1 hf 's/PAD_BOTTOM = 8;/PAD_BOTTOM = 30;/'
mutant "M3 NAME_TO_STATUS back to 5"    F1 hf 's/NAME_TO_STATUS = 0;/NAME_TO_STATUS = 5;/'
mutant "M4 STATUS_TO_LOCK back to 26"   F1 hf 's/STATUS_TO_LOCK = 0;/STATUS_TO_LOCK = 26;/'
mutant "M5 LOCK_TO_LOGOFF back to 10"   F1 hf 's/LOCK_TO_LOGOFF = 8;/LOCK_TO_LOGOFF = 10;/'
mutant "M6 CARD_GAP back to 20"         F1 hf 's/CARD_GAP = 12;/CARD_GAP = 20;/'
mutant "M7 CARD_PAD_TOP back to 14"     F1 hf 's/CARD_PAD_TOP = 12;/CARD_PAD_TOP = 14;/'
mutant "M8 CARD_PAD_BOTTOM back to 14"  F1 hf 's/CARD_PAD_BOTTOM = 2;/CARD_PAD_BOTTOM = 14;/'
mutant "M9 SCALE_GAP back to 12"        F1 hf 's/SCALE_GAP = 8;/SCALE_GAP = 12;/'
mutant "M10 LEVEL_GAP back to 6"        F1 hf 's/LEVEL_GAP = 4;/LEVEL_GAP = 6;/'
mutant "M11 PICK_PAD back to 10"        F1 hf 's/PICK_PAD = 6;/PICK_PAD = 10;/'
mutant "M12 MENU_GAP back to 20"        F1 hf 's/MENU_GAP = 12;/MENU_GAP = 20;/'
mutant "M13 LINK_GAP back to 30"        F1 hf 's/LINK_GAP = 4;/LINK_GAP = 30;/'
mutant "M14 LINK_PAD back to 18"        F1 hf 's/LINK_PAD = 8;/LINK_PAD = 18;/'
mutant "M15 every old value at once"    "F1 F2 F3 F6" hf 's/PAD_TOP = 16;/PAD_TOP = 44;/; s/PAD_BOTTOM = 8;/PAD_BOTTOM = 30;/; s/NAME_TO_STATUS = 0;/NAME_TO_STATUS = 5;/; s/STATUS_TO_LOCK = 0;/STATUS_TO_LOCK = 26;/; s/LOCK_TO_LOGOFF = 8;/LOCK_TO_LOGOFF = 10;/; s/CARD_GAP = 12;/CARD_GAP = 20;/; s/CARD_PAD_TOP = 12;/CARD_PAD_TOP = 14;/; s/CARD_PAD_BOTTOM = 2;/CARD_PAD_BOTTOM = 14;/; s/SCALE_GAP = 8;/SCALE_GAP = 12;/; s/LEVEL_GAP = 4;/LEVEL_GAP = 6;/; s/PICK_PAD = 6;/PICK_PAD = 10;/; s/MENU_GAP = 12;/MENU_GAP = 20;/; s/LINK_GAP = 4;/LINK_GAP = 30;/; s/LINK_PAD = 8;/LINK_PAD = 18;/'
mutant "M16 MIN_TOUCH down to 44"       "F1 F5" hf 's/MIN_TOUCH = 48;/MIN_TOUCH = 44;/'
mutant "M17 a level's row grows past the budget" F3 pp 's/(d\.put\(ProfilePresets\.UNSHIELDED,\s*")/$1 . ("many more words " x 8)/e'
mutant "M18 showConfirm's top padding back to dp(44)"    S1 pa 's/ll\.setPadding\(dp\(22\), dp\(ProfileHomeFit\.PAD_TOP\),/ll.setPadding(dp(22), dp(44),/'
mutant "M19 showConfirm's bottom padding back to dp(30)" S1 pa 's/dp\(ProfileHomeFit\.PAD_BOTTOM\)\);/dp(30));/'
mutant "M20 name to status back to dp(5)"     S2 pa 's/stlp\.topMargin = dp\(ProfileHomeFit\.NAME_TO_STATUS\);/stlp.topMargin = dp(5);/'
mutant "M21 status to Lock back to dp(26)"    S2 pa 's/stlp\.bottomMargin = dp\(ProfileHomeFit\.STATUS_TO_LOCK\);/stlp.bottomMargin = dp(26);/'
mutant "M22 Lock to Log off back to dp(10)"   S2 pa 's/btnLp\(dp\(ProfileHomeFit\.LOCK_TO_LOGOFF\)\)/btnLp(dp(10))/'
mutant "M23 one menu back to the 20dp gap"    S2 pa 's/\}, false, ProfileHomeFit\.MENU_GAP\);/}, false);/'
mutant "M24 Delete back to its 30dp padding"  S3 pa 's/del\.setPadding\(dp\(8\), dp\(ProfileHomeFit\.LINK_PAD\),/del.setPadding(dp(8), dp(30),/'
mutant "M25 Done back to its 18dp padding"    S3 pa 's/done\.setPadding\(dp\(8\), dp\(ProfileHomeFit\.LINK_PAD\),/done.setPadding(dp(8), dp(18),/'
mutant "M26 Delete loses its minimum height"  S3 pa 's/\s*del\.setMinHeight\(dp\(ProfileHomeFit\.MIN_TOUCH\)\);//'
mutant "M27 Done loses its minimum height"    S3 pa 's/\s*done\.setMinHeight\(dp\(ProfileHomeFit\.MIN_TOUCH\)\);//'
mutant "M28 no gap above Delete"              S3 pa 's/ll\.addView\(del, btnLp\(dp\(ProfileHomeFit\.LINK_GAP\)\)\);/ll.addView(del, btnLp(0));/'
mutant "M29 the card's padding back to dp(14)" S4 pa 's/card\.setPadding\(dp\(16\), dp\(ProfileHomeFit\.CARD_PAD_TOP\), dp\(16\), dp\(ProfileHomeFit\.CARD_PAD_BOTTOM\)\);/card.setPadding(dp(16), dp(14), dp(16), dp(14));/'
mutant "M30 above the card back to dp(20)"    S4 pa 's/clp\.topMargin = dp\(ProfileHomeFit\.CARD_GAP\);/clp.topMargin = dp(20);/'
mutant "M31 above the scale back to dp(12)"   S4 pa 's/sclp\.topMargin = dp\(ProfileHomeFit\.SCALE_GAP\);/sclp.topMargin = dp(12);/'
mutant "M32 above the level back to dp(6)"    S4 pa 's/llp\.topMargin = dp\(ProfileHomeFit\.LEVEL_GAP\);/llp.topMargin = dp(6);/'
mutant "M33 the row's padding back to 10 and 4" S4 pa 's/pick\.setPadding\(0, dp\(ProfileHomeFit\.PICK_PAD\), 0, dp\(ProfileHomeFit\.PICK_PAD\)\);/pick.setPadding(0, dp(10), 0, dp(4));/'
mutant "M34 the row loses its minimum height" S4 pa 's/\s*pick\.setMinHeight\(dp\(ProfileHomeFit\.MIN_TOUCH\)\);//'
mutant "M35 a plain container, no ScrollView" S5 pa 's/android\.widget\.ScrollView sc = new android\.widget\.ScrollView\(this\);/android.widget.FrameLayout sc = new android.widget.FrameLayout(this);/'
mutant "M36 the scrollbar is hidden, not fixed" S5 pa 's/(sc\.addView\(ll\);)/sc.setVerticalScrollBarEnabled(false);\n        $1/'
mutant "M37 the content is stretched to the window" S5 pa 's/(sc\.addView\(ll\);)/sc.setFillViewport(true);\n        $1/'
mutant "M38 the Help row is removed"          S6 pa 's/"Report an issue", "Help"\},/"Report an issue"},/'
mutant "M39 Delete this profile is removed"   S6 pa 's/del\.setText\("Delete this profile"\);/del.setText("");/'
mutant "M40 Done is removed"                  S6 pa 's/done\.setText\("Done"\);/done.setText("");/'
mutant "M41 Lock loses its accent emphasis"   S6 pa 's/ll\.addView\(accentButton\("Lock — keep/ll.addView(secondaryButton("Lock — keep/'
mutant "M42 menu rows lowered in every screen" S7 pa 's/row\.setPadding\(dp\(16\), dp\(15\), dp\(16\), dp\(15\)\);/row.setPadding(dp(16), dp(12), dp(16), dp(12));/'
mutant "M43 sub-screens lose their top padding" S7 pa 's/(private LinearLayout menuScreen\(.*?ll\.setPadding\(dp\(22\), )dp\(44\)/$1dp(16)/s'
mutant "M44 other cards lose the 20dp gap"    S7 pa 's/danger, 20\);/danger, 12);/'
mutant "M45 the Lock button lowered"          S7 pa 's/(private Button accentBtn\(.*?)b\.setPadding\(0, dp\(14\), 0, dp\(14\)\);/$1b.setPadding(0, dp(8), 0, dp(8));/s'
mutant "M46 the Log off button lowered"       S7 pa 's/(private Button secondaryButton\(.*?)b\.setPadding\(0, dp\(13\), 0, dp\(13\)\);/$1b.setPadding(0, dp(8), 0, dp(8));/s'
mutant "M47 the name's size grows, the model does not" S8 pa 's/nameTv\.setTextSize\(TypedValue\.COMPLEX_UNIT_SP, 30\);/nameTv.setTextSize(TypedValue.COMPLEX_UNIT_SP, 44);/'
mutant "M48 the status line loses its 48dp tap target" S9 pa 's/\s*status\.setMinHeight\(dp\(ProfileHomeFit\.MIN_TOUCH\)\);//'
mutant "M49 the status line's tap target is only 18dp" S9 pa 's/status\.setMinHeight\(dp\(ProfileHomeFit\.MIN_TOUCH\)\);/status.setMinHeight(dp(18));/'
mutant "M50 the status text leaves the middle of its target" S9 pa 's/status\.setGravity\(Gravity\.CENTER\);/status.setGravity(Gravity.TOP);/'
mutant "M51 the status line no longer checks again" S9 pa 's/\s*if \(unknown && !checking && !offline\) status\.setOnClickListener\(v -> probeSession\(\)\);//'
mutant "M52 the status line no longer opens Your data" S9 pa 's/\s*stv\.setOnClickListener\(v -> showYourData\(\)\);//'

if [ "$mutfails" -ne 0 ]; then echo "FAIL: $mutfails mutant(s) not convicted" >&2; exit 1; fi
echo "PASS (with --mutate)"
