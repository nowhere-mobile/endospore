#!/usr/bin/env bash
# test-delta-line-java.sh [--mutate] -- Your data's change line counts deleted files, says when a scope's deletions
# could not be checked, and says small app-file deletions are not counted, run under javac (NWP-20261128-11).
#
# WHY THIS IS COMMITTED. loadSealDelta read only changedBytes/changedFiles/blind from SEAL-DELTA-WALK. The agent
# reports deletedBytes, deletedFiles and deletedUnknown since NWP-20261126-06, but a 169 MB video deleted on the phone
# still gave "No new changes since the last save." (lynx 2026102201, NWP-20261024-18; decided h56 #6, 2026-11-03).
# The line is now DeltaLine.line: a deletion is counted with its size, an unchecked scope never yields "No new
# changes since the last save.", and every line carries "Deletions of small app files are not counted.". Drop a
# link (the field not read, the guard gone, the sentence gone) and the screen says the wrong thing again, with green CI.
#
# DeltaLine is pure java.lang and is compiled here with its cases (written below into the suite's temp dir). Source
# pins (comment lines stripped) hold loadSealDelta's SEAL-DELTA-WALK block in ProfileActivity.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-delta-line-java.sh            # the cases and the pins
#   bash test-delta-line-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SUT="$SRC/DeltaLine.java"
PA="$SRC/ProfileActivity.java"
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

CASES=$(mktemp -p "$W") || exit 2
cat > "$CASES" <<'JAVA_END'
package com.nowhere.chooser;

import java.util.function.LongFunction;

final class DeltaLineCases {
    static final LongFunction<String> F = b -> "<" + b + ">";
    static final String SM = "\nDeletions of small app files are not counted.";
    static final String BL = " · some areas couldn’t be read";
    static final String UN = " · some deletions couldn’t be checked";
    static final String NONE = "No new changes since the last save.";
    static int fails = 0;

    static void eq(String name, String got, String want) {
        if (got != null && got.equals(want)) { System.out.println("ok   " + name); return; }
        System.out.println("FAIL " + name + ": got [" + got + "] want [" + want + "]");
        fails++;
    }
    static void yes(String name, boolean v, String why) {
        if (v) { System.out.println("ok   " + name); return; }
        System.out.println("FAIL " + name + ": " + why);
        fails++;
    }
    static String L(long cb, long cf, long bl, long db, long df, boolean du) {
        return DeltaLine.line(cb, cf, bl, db, df, du, F);
    }
    static void small(String name, String got) {
        yes(name, got != null && got.endsWith(SM) && got.indexOf('\n') == got.lastIndexOf('\n'),
                "not one line plus the small-files sentence: [" + got + "]");
    }

    public static void main(String[] a) {
        // C1: a deletion alone (the lynx 169 MB video) is counted, in the accent colour.
        String c1 = L(0, 0, 0, 177209344, 1, false);
        eq("C1 deletion alone", c1, "Deleted on this phone since the last save: ~<177209344> across 1 file" + SM);
        yes("C1 not 'No new changes'", !c1.contains("No new changes"), c1);
        yes("C1 active", DeltaLine.active(0, 0, 1), "active(0,0,1) is false");

        // C2: changed and deleted together carry both figures.
        eq("C2 changed + deleted", L(2048, 3, 0, 5000, 2, false),
                "Changed on this phone since the last save: ~<2048> across 3 files · 2 deleted (~<5000>)" + SM);
        yes("C2 active", DeltaLine.active(2048, 3, 2), "active(2048,3,2) is false");

        // C3: changed only is today's text, plus the second sentence.
        eq("C3 changed only", L(2048, 3, 0, 0, 0, false),
                "Changed on this phone since the last save: ~<2048> across 3 files" + SM);
        eq("C3 changed only, blind", L(2048, 3, 1, 0, 0, false),
                "Changed on this phone since the last save: ~<2048> across 3 files" + BL + SM);
        eq("C3 nothing", L(0, 0, 0, 0, 0, false), NONE + SM);

        // C4: an unchecked scope never yields "No new changes since the last save.".
        eq("C4 nothing, unknown", L(0, 0, 0, 0, 0, true), "No new changes found since the last save." + UN + SM);
        for (int c = 0; c < 2; c++) for (int d = 0; d < 2; d++) for (int b = 0; b < 2; b++) {
            String g = L(c * 4096, c * 2, b, d * 8192, d * 3, true);
            String n = "C4 unknown c=" + c + " d=" + d + " b=" + b;
            yes(n + " no 'No new changes since'", !g.contains(NONE), g);
            yes(n + " unknown suffix", g.endsWith(UN + SM), g);
            small("C6 " + n, g);
        }

        // C5: the blind suffix is kept.
        eq("C5 deleted, blind", L(0, 0, 2, 9000, 1, false),
                "Deleted on this phone since the last save: ~<9000> across 1 file" + BL + SM);
        eq("C5 changed + deleted, blind", L(10, 1, 2, 9000, 1, false),
                "Changed on this phone since the last save: ~<10> across 1 file · 1 deleted (~<9000>)" + BL + SM);
        eq("C5 blind only", L(0, 0, 2, 0, 0, false), "Couldn’t read some areas to check for changes." + SM);

        // C6: the small-files sentence is on every line.
        long[][] in = {{0, 0, 0, 177209344, 1}, {2048, 3, 0, 5000, 2}, {2048, 3, 0, 0, 0}, {2048, 3, 1, 0, 0},
                {0, 0, 0, 0, 0}, {0, 0, 2, 9000, 1}, {10, 1, 2, 9000, 1}, {0, 0, 2, 0, 0}};
        for (long[] r : in) for (int u = 0; u < 2; u++) {
            small("C6 " + java.util.Arrays.toString(r) + " u=" + u, L(r[0], r[1], r[2], r[3], r[4], u == 1));
        }

        // C7: singular and plural.
        eq("C7 one changed", L(5, 1, 0, 0, 0, false), "Changed on this phone since the last save: ~<5> across 1 file" + SM);
        eq("C7 two changed", L(5, 2, 0, 0, 0, false), "Changed on this phone since the last save: ~<5> across 2 files" + SM);
        eq("C7 one deleted", L(0, 0, 0, 7, 1, false), "Deleted on this phone since the last save: ~<7> across 1 file" + SM);
        eq("C7 two deleted", L(0, 0, 0, 7, 2, false), "Deleted on this phone since the last save: ~<7> across 2 files" + SM);
        eq("C7 '1 deleted'", L(5, 2, 0, 7, 1, false),
                "Changed on this phone since the last save: ~<5> across 2 files · 1 deleted (~<7>)" + SM);

        // active(): the accent colour.
        yes("active none", !DeltaLine.active(0, 0, 0), "active(0,0,0) is true");
        yes("active bytes", DeltaLine.active(1, 0, 0), "active(1,0,0) is false");
        yes("active files", DeltaLine.active(0, 1, 0), "active(0,1,0) is false");

        if (fails > 0) { System.out.println(fails + " case(s) failed"); System.exit(1); }
    }
}
JAVA_END

# suite <DeltaLine.java> -> 0 pass, 1 a case failed or the class is missing, 3 did not compile.
suite() {
  local src="$1" d out rc
  [ -f "$src" ] || { echo "  FAIL  DeltaLine.java does not exist" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$src" "$d/src/com/nowhere/chooser/DeltaLine.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/DeltaLineCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.DeltaLineCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# wblock <ProfileActivity.java>: the SEAL-DELTA-WALK block, from its read to its repaint, comment lines dropped.
wblock() {
  awk 'index($0, "daemonLenReply(\"SEAL-DELTA-WALK\\n\"") { on = 1 }
       on && $0 !~ /^[ \t]*(\/\/|\*|\/\*)/ { print }
       on && index($0, "changedTv.setVisibility(View.VISIBLE);") { exit }' "$1"
}
# fcount <body> <literal>: lines holding the fixed string.
fcount() { printf '%s\n' "$1" | S="$2" awk 'index($0, ENVIRON["S"]) { n++ } END { print n + 0 }'; }

# pins <ProfileActivity.java> -> 0 when the wiring holds, 1 otherwise.
pins() {
  local pa="$1" bad=0 blk s
  blk=$(wblock "$pa")
  [ -n "$blk" ] || { echo "  FAIL  pins: the SEAL-DELTA-WALK block was not found" >&2; return 1; }
  [ "$(fcount "$blk" 'changedTv.setVisibility(View.VISIBLE);')" -eq 1 ] \
    || { echo "  FAIL  pins: the SEAL-DELTA-WALK block does not end at its repaint" >&2; bad=1; }
  for s in 'DeltaLine.line(' 'DeltaLine.active('; do
    [ "$(fcount "$blk" "$s")" -eq 1 ] || { echo "  FAIL  P1 the SEAL-DELTA-WALK block does not call $s once" >&2; bad=1; }
  done
  for s in '"deletedFiles"' '"deletedBytes"' '"deletedUnknown"' 'ProfileActivity::fmtBytes'; do
    [ "$(fcount "$blk" "$s")" -ge 1 ] || { echo "  FAIL  P2 the SEAL-DELTA-WALK block does not hold $s" >&2; bad=1; }
  done
  [ "$(fcount "$blk" '"No new changes since the last save."')" -eq 0 ] \
    || { echo "  FAIL  P3 the SEAL-DELTA-WALK block still writes its own 'No new changes' line" >&2; bad=1; }
  [ "$bad" -eq 0 ]
}

echo "== $SUT"
suite "$SUT" || { echo "FAILED"; exit 1; }
pins "$PA" || { echo "FAILED (pins)"; exit 1; }
echo "pins: ok"
[ "$MUTATE" = yes ] || { echo "PASS"; exit 0; }

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not compile or does not apply proves nothing)"
mut() { # mut <label> <perl-expr>   (mutates DeltaLine.java; the cases must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/DeltaLine.java"
  cp "$SUT" "$c"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$SUT" "$c"; then echo "  INERT     $1 -- the mutation did not apply"; rm -rf "$d"; return 1; fi
  suite "$c" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  CONVICTED $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
mutpin() { # mutpin <label> <perl-expr>   (mutates ProfileActivity.java; the pins must fail)
  local d c rc why
  d=$(mktemp -d -p "$W") || return 1; c="$d/ProfileActivity.java"
  cp "$PA" "$c"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$PA" "$c"; then echo "  INERT     $1 -- the mutation did not apply"; rm -rf "$d"; return 1; fi
  why=$(pins "$c" 2>&1); rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  echo "  CONVICTED $1 --$(printf '%s\n' "$why" | grep -m1 'FAIL' | sed 's/^ *FAIL//')"
}
fails=0
mut "M1 deletedFiles ignored" 's/boolean deleted = deletedFiles > 0;/boolean deleted = false;/' || fails=$((fails+1))
mut "M2 the deletedUnknown guard on 'No new changes' removed" \
  's/\} else if \(deletedUnknown\) \{\n *s\.append\("No new changes found since the last save\."\);\n *//' \
  || fails=$((fails+1))
mut "M3 the small-files sentence dropped" "s/\\.append\\('\\\\n'\\)\\.append\\(SMALL\\)//" || fails=$((fails+1))
mut "M4 active() ignores deletions" 's/ \|\| deletedFiles > 0;/;/' || fails=$((fails+1))
mutpin "M5 loadSealDelta does not call DeltaLine.line" \
  's/line = DeltaLine\.line\(cb, cf, bl, db, df, dun, ProfileActivity::fmtBytes\);/line = "No new changes since the last save.";/' \
  || fails=$((fails+1))
mutpin "M6 loadSealDelta does not read deletedFiles" \
  's/long df = w\.optLong\("deletedFiles", 0\);/long df = 0;/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "PASS: 6 of 6 mutants convicted" || { echo "== $fails mutant(s) not convicted"; exit 1; }
