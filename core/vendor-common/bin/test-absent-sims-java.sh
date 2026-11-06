#!/usr/bin/env bash
# test-absent-sims-java.sh [--mutate] -- owner mode's SIM lines list a stored binding whose SIM is not in the phone, run
# under javac (NWP-20261116-20).
#
# WHY THIS IS COMMITTED. #73 (Q118, docs/product-decisions.md 2026-10-22) decided that owner mode's SIM lines also list
# the stored bindings for SIMs not in the phone, each with its own Unbind: an operator who pulls a bound SIM before
# unassigning it otherwise left a binding, with its pending texts and calls, that nothing in owner mode showed. The
# agent half was already built: GET-BINDINGS lists every stored line, present SIM or not, and DELETE-BINDING works by
# ICCID with no presence check. AbsentSims (a pure class, no android import) picks the stored lines no active SIM
# matches; it is compiled here with BindFormFields (its iccEq) and its cases (A1-A9). The SOURCE CHECKS (S1-S6) hold
# ChooserActivity.fillSimRows, on its code with the comments stripped: it calls AbsentSims.rows with lists built from
# `sims`, after the active-SIM row loop and before esimNote( (S1); each absent row opens buildBindSimScreen with a
# SimInfo whose iccid is the stored one, never buildBindSimScreen(null) (S2); no Log. statement concatenates an ICCID
# value -- `.iccid.length()` and `.iccid == null` are allowed -- and the absent line logs a count (S3); nothing is added
# on the unreadable-file return (S4); the bound-SIM CLEAR string stays exactly once (S5); AbsentSims stays java.* and
# compares through BindFormFields.iccEq (S6). Source checks run first and each failure is printed; the class's absence
# is reported after them.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-absent-sims-java.sh            # the cases + source checks
#   bash test-absent-sims-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
COPY="$root/core/chooser/src/com/nowhere/chooser/AbsentSims.java"
BFF="$root/core/chooser/src/com/nowhere/chooser/BindFormFields.java"
ACT="$root/core/chooser/src/com/nowhere/chooser/ChooserActivity.java"
CASES="$root/core/chooser/tests/absent-sims/AbsentSimsCases.java"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
[ -f "$ACT" ] && [ -f "$BFF" ] && [ -f "$CASES" ] || { echo "FAIL: missing $ACT, $BFF or $CASES" >&2; exit 2; }

JAVAC=""; JAVA=""
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
fi

# body <file> <signature fragment>: from the signature to the first line that is exactly "    }" -- or a marker that
# fails every check when the signature does not occur exactly once (lifted from core/chooser/test-tel-seal.sh).
body(){ [ "$(grep -cF -- "$2" "$1")" = 1 ] || { echo "<signature not exactly once: $2>"; return; }; awk -v sig="$2" -v end="    }" 'index($0, sig) { on = 1 } on { print } on && $0 == end { exit }' "$1"; }
# code: stdin without its comments -- // to the end of a line and /* */ across lines, but not inside a string or char
# literal -- and without the lines that leave blank (lifted from core/chooser/test-tel-seal.sh).
code(){ awk '
{ out = ""; n = length($0); i = 1; str = 0; chr = 0
  while (i <= n) {
    c = substr($0, i, 1); d = substr($0, i, 2)
    if (blk) { if (d == "*/") { blk = 0; i += 2 } else i++; continue }
    if (str || chr) {
      out = out c
      if (c == "\\") { out = out substr($0, i + 1, 1); i += 2; continue }
      if ((str && c == "\"") || (chr && c == "\047")) { str = 0; chr = 0 }
      i++; continue
    }
    if (d == "/*") { blk = 1; i += 2; continue }
    if (d == "//") break
    if (c == "\"") str = 1; else if (c == "\047") chr = 1
    out = out c; i++
  }
  if (out ~ /[^[:space:]]/) print out
}'; }
# cnt <text> <fixed string>: how many lines of <text> hold it. at <text> <fixed string>: the line of its first match,
# or 0. Both on a captured variable, never a pipe into grep -q.
cnt(){ local n; n=$(printf '%s\n' "$1" | grep -cF -- "$2"); echo "${n:-0}"; }
at(){ local n; n=$(printf '%s\n' "$1" | grep -nF -- "$2" | head -1 | cut -d: -f1); echo "${n:-0}"; }

SIG='private void fillSimRows(LinearLayout rows, java.util.List<String[]> sums, java.util.List<SimInfo> sims, int inactiveEsims)'
EARLY='if (sums == null || sums == TelArrival.DAMAGED_BINDINGS) return;'
LOOP='for (SimInfo s : sims) {'
CALL='final java.util.List<String[]> absent = AbsentSims.rows(sums, activeIccids, activeSubIdsWithoutIccid);'
ICCS='activeIccids.add(s.iccid);'
IDS='activeSubIdsWithoutIccid.add(s.subId);'
ROW='rows.addView(settingsRow(AbsentSims.TITLE, AbsentSims.summary(e), v -> setContentView(buildBindSimScreen(fs))), new LinearLayout.LayoutParams(MATCH, WRAP));'
FSNEW='final SimInfo fs = new SimInfo();'
FSICC='fs.iccid = e[1];'
ABSLOG='"SIM-lines absent=" + absent.size()'
CLEAR='fs.rebuilt = false; fs.mine = false;'

# suite <AbsentSims.java> <ChooserActivity.java> -> 0 pass, 1 a case or source check failed (the only code that
# convicts a mutant), 2 no javac, 3 the class or the cases did not compile.
suite() {
  local copy="$1" act="$2" d out rc fs logs left early loop2 call esim a b c n
  local bad=0
  fs=$(body "$act" "$SIG" | code)
  early=$(at "$fs" "$EARLY"); call=$(at "$fs" "$CALL"); esim=$(at "$fs" 'esimNote(')
  # the second `for (SimInfo s : sims) {` line: the loop that builds the two lists (the first is the row loop)
  loop2=$(printf '%s\n' "$fs" | grep -nF -- "$LOOP" | sed -n 2p | cut -d: -f1); loop2=${loop2:-0}
  # S1: one call, built from `sims`, after the row loop and before esimNote(.
  a=$(at "$fs" "$LOOP"); b=$(at "$fs" "$ICCS"); c=$(at "$fs" "$IDS")
  if [ "$(cnt "$fs" 'AbsentSims.rows(')" != 1 ] || [ "$call" -eq 0 ] || [ "$a" -eq 0 ] || [ "$loop2" -le "$a" ] \
     || [ "$b" -le "$loop2" ] || [ "$c" -le "$loop2" ] || [ "$call" -le "$b" ] || [ "$call" -le "$c" ] \
     || [ "$esim" -le "$call" ]; then
    echo "  CHECK S1 fillSimRows does not call AbsentSims.rows once, with lists built from sims, after the row loop and before esimNote(" >&2; bad=1; fi
  # S2: each absent row opens buildBindSimScreen(fs), fs a new SimInfo with the stored ICCID; never the manual form.
  a=$(at "$fs" 'for (String[] e : absent) {'); b=$(at "$fs" "$FSNEW"); c=$(at "$fs" "$FSICC"); n=$(at "$fs" "$ROW")
  if [ "$(cnt "$fs" "$ROW")" != 1 ] || [ "$a" -le "$call" ] || [ "$b" -le "$a" ] || [ "$c" -le "$b" ] || [ "$n" -le "$c" ] \
     || [ "$(cnt "$fs" 'buildBindSimScreen(null)')" != 0 ]; then
    echo "  CHECK S2 an absent row does not open buildBindSimScreen with a SimInfo whose iccid is e[1], or a row opens buildBindSimScreen(null)" >&2; bad=1; fi
  # S3: every Log. statement, joined to its ';', with its string literals and the allowed .iccid terms removed, holds
  # no iccid, e[1] or hit[1]. The iccidLen= line stays, and the absent line logs a count.
  logs=$(printf '%s\n' "$fs" | awk '/Log\./ { on = 1; buf = "" } on { buf = buf $0 } on && /;[[:space:]]*$/ { print buf; on = 0 }')
  left=$(printf '%s\n' "$logs" | sed -e 's/"[^"]*"//g' -e 's/\.iccid\.length()//g' -e 's/\.iccid == null//g')
  n=$(printf '%s\n' "$left" | grep -cE 'iccid|e\[1\]|hit\[1\]'); n=${n:-0}
  if [ "$n" != 0 ] || [ "$(cnt "$fs" 'iccidLen=')" != 1 ] || [ "$(cnt "$fs" "$ABSLOG")" != 1 ]; then
    echo "  CHECK S3 a Log. line in fillSimRows prints an ICCID value, or the iccidLen= / absent count line is gone" >&2; bad=1; fi
  # S4: nothing of the absent rows comes before the unreadable-file return.
  a=$(at "$fs" 'AbsentSims.'); b=$(at "$fs" 'activeIccids')
  if [ "$early" -eq 0 ] || [ "$a" -le "$early" ] || [ "$b" -le "$early" ]; then
    echo "  CHECK S4 fillSimRows lists absent SIMs before its null / DAMAGED_BINDINGS return" >&2; bad=1; fi
  # S5: the bound-SIM CLEAR string stays exactly once (test-binding-marks-java.sh U6).
  if [ "$(cnt "$fs" "$CLEAR")" != 1 ]; then
    echo "  CHECK S5 fillSimRows does not hold '$CLEAR' exactly once" >&2; bad=1; fi
  # F0: the class itself -- missing (origin/main) is reported AFTER the source checks, so all failures show.
  [ -f "$copy" ] || { echo "  FAIL  AbsentSims.java does not exist" >&2; return 1; }
  # S6: java.* only, and the ICCID comparisons go through BindFormFields.iccEq.
  if grep -q 'android\.' "$copy" || [ "$(grep -c 'BindFormFields\.iccEq(' "$copy")" -lt 1 ]; then
    echo "  CHECK S6 AbsentSims.java mentions android. or does not compare through BindFormFields.iccEq" >&2; bad=1; fi
  [ "$bad" -eq 0 ] || return 1
  if [ -z "$JAVAC" ]; then
    echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip: install a JDK or run it on the build VM." >&2
    return 2
  fi
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$copy" "$d/src/com/nowhere/chooser/AbsentSims.java"
  cp "$BFF" "$d/src/com/nowhere/chooser/BindFormFields.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/AbsentSimsCases.java"
  if ! "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.AbsentSimsCases 2>&1); rc=$?
  echo "$out"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

[ -z "$JAVAC" ] || "$JAVAC" -J-Djava.io.tmpdir="$W" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
echo "== $COPY"
suite "$COPY" "$ACT"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAILED (rc=$rc)"; exit "$rc"; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not apply or does not compile proves nothing)"
mut() { # mut <label> <copy|act> <perl-expr>
  local md mc ma mrc mtarget; md=$(mktemp -d -p "$W"); mc="$md/AbsentSims.java"; ma="$md/ChooserActivity.java"
  cp "$COPY" "$mc"; cp "$ACT" "$ma"
  mtarget="$mc"; [ "$2" = act ] && mtarget="$ma"
  if ! perl -0pi -e "$3" "$mtarget"; then echo "  ERROR     $1 -- perl failed on the mutation"; return 1; fi
  if cmp -s "$COPY" "$mc" && cmp -s "$ACT" "$ma"; then echo "  INERT     $1 -- the mutation changed nothing"; return 1; fi
  suite "$mc" "$ma" >/dev/null 2>&1; mrc=$?
  case "$mrc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile or run (rc=$mrc)"; return 1 ;;
  esac
}
fails=0
mut "M1 the active-ICCID test by equals, not iccEq"  copy 's/BindFormFields\.iccEq\(a, e\[1\]\)/a.equals(e[1])/' || fails=$((fails+1))
mut "M2 the subId fallback dropped"                  copy 's/\n[ ]*if \(shownBySubId\(e, activeSubIdsWithoutIccid\)\) continue;//' || fails=$((fails+1))
mut "M3 an empty-ICCID entry listed"                 copy 's/\n[ ]*if \(e\[1\] == null \|\| e\[1\]\.trim\(\)\.isEmpty\(\)\) continue;[^\n]*//' || fails=$((fails+1))
mut "M4 the row opens buildBindSimScreen(null)"      act  's/(AbsentSims\.summary\(e\), v -> setContentView\(buildBindSimScreen\()fs\)/${1}null)/' || fails=$((fails+1))
mut "M5 the summary without the last four"           copy 's/"ends " \+ last4\(e\[1\]\) \+ " · " \+ e\[2\]/"ends " + e[2]/' || fails=$((fails+1))
mut "M6 the absent loop logs e[1]"                   act  's/(\n(\s*)for \(String\[\] e : absent\) \{\n)/$1$2    android.util.Log.i("NowhereChooser", "SIM-lines absent icc=" + e[1]);\n/' || fails=$((fails+1))
mut "M7 the absent-row loop removed"                 act  's/\n[ ]*for \(String\[\] e : absent\) \{.*?\n[ ]*\}(\n[ ]*android\.util\.Log\.i\("NowhereChooser", "SIM-lines absent=)/$1/s' || fails=$((fails+1))
mut "M8 a duplicate ICCID listed twice"              copy 's/\n[ ]*if \(seen\(e, out\)\) continue;//' || fails=$((fails+1))
mut "M9 the absent block above the early return"     act  's/(\n[ ]*if \(sums == null \|\| sums == TelArrival\.DAMAGED_BINDINGS\) return;[^\n]*)/\n            AbsentSims.rows(sums, new java.util.ArrayList<String>(), new java.util.ArrayList<Integer>());$1/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
