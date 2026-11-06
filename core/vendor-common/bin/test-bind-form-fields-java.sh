#!/usr/bin/env bash
# test-bind-form-fields-java.sh [--mutate] -- the owner-mode bind form's label + visibility, run under javac (NWP-20261021-04).
#
# WHY THIS IS COMMITTED. setBindingOwner rewrites a line's label and visibility on every bind, and "Enter a SIM
# manually" starts from no SIM row, so a manual bind of an already-bound ICCID sent a blank label and "open". Now
# BindFormFields.forBind (a pure class, no android.* import) picks the line's stored values unless the owner edited
# them, and is compiled here with its cases. The PINS check that buildBindSimScreen calls it before the SET-BINDING
# send on the manual form, tracks edits after the pre-fill, and shows what was kept. Pins run first and each failure
# is printed; the helper's absence is reported after them.
#
# NWP-20261105-05 (Q103) adds BindFormFields.lineLabels and owner mode's "Clear notices" row. Pins P6-P9 hold its listener
# (bounded to its own body, since the Unbind listener above it sends DELETE-BINDING): it reads GET-BINDINGS on a worker
# thread, clears only by a non-null, non-empty label set, deletes nothing, and tells a damaged line from an unbound one.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-bind-form-fields-java.sh            # the cases + pins
#   bash test-bind-form-fields-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
COPY="$root/core/chooser/src/com/nowhere/chooser/BindFormFields.java"
ACT="$root/core/chooser/src/com/nowhere/chooser/ChooserActivity.java"
CASES="$root/core/chooser/tests/bind-form-fields/BindFormCases.java"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
[ -f "$ACT" ] && [ -f "$CASES" ] || { echo "FAIL: missing $ACT or $CASES" >&2; exit 2; }

JAVAC=""; JAVA=""
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
fi

# suite <BindFormFields.java> <ChooserActivity.java> -> 0 pass, 1 a case or pin failed (the only code that convicts a
# mutant), 2 no javac, 3 the class or the cases did not compile.
suite() {
  local copy="$1" act="$2" d out rc
  local bad=0
  # P1: the manual form asks forBind before the send, and a null answer sends nothing.
  perl -0ne 'exit(/final java\.util\.List<String\[\]> sums = manual \? bindingSummaries\(\) : null;\s*final String\[\] f = manual \? BindFormFields\.forBind\(iccid, label, labelEd, visNow, visEd, sums\) : new String\[\]\{label, visNow, "0"\};\s*if \(f == null\) result = "NOCHECK";\s*else \{\s*(?:\/\/[^\n]*\n\s*)?String sr = sendDaemon\("SET-BINDING\\n" \+ sim\.subId \+ "\\n" \+ iccid \+ "\\n" \+ android\.util\.Base64\.encodeToString\(f\[0\]\.getBytes/ ? 0 : 1)' "$act" || {
    echo "  PIN   the bind listener no longer calls BindFormFields.forBind on the manual form before the SET-BINDING send, or no longer sends nothing on null" >&2; bad=1; }
  perl -0ne 'exit(/TelArrival\.rememberDial\(iccid, f\[1\]\)/ ? 0 : 1)' "$act" || {
    echo "  PIN   rememberDial no longer gets the vis that was sent" >&2; bad=1; }
  # P2: the label watcher goes on AFTER the pre-fill, or the pre-fill would count as an edit.
  perl -0ne 'exit(/labelF\.setText\(sim\.label\);[^\n]*\n\s*labelF\.addTextChangedListener\(new android\.text\.TextWatcher\(\) \{[^\n]*afterTextChanged\(android\.text\.Editable s\) \{ labelEdited\[0\] = true; \}/ ? 0 : 1)' "$act" || {
    echo "  PIN   labelF's TextWatcher is not added directly after labelF.setText(sim.label)" >&2; bad=1; }
  # P3: a chip tap is an edit.
  perl -0ne 'exit(/chip\.setOnClickListener\(v -> \{ vis\[0\] = val; visEdited\[0\] = true; / ? 0 : 1)' "$act" || {
    echo "  PIN   a chip click no longer sets the vis-edited flag" >&2; bad=1; }
  # P4: when forBind kept the line's values the form shows them.
  perl -0ne 'exit(/if \("1"\.equals\(sent\[2\]\)\) \{[^\n]*\n\s*labelF\.setText\(sent\[0\]\); vis\[0\] = sent\[1\];.*?labelEdited\[0\] = false; visEdited\[0\] = false;/s ? 0 : 1)' "$act" || {
    echo "  PIN   the OK branch no longer reflects the kept label and vis back onto the form" >&2; bad=1; }
  # P5: the activity's iccEq is the helper's.
  perl -0ne 'exit(/private static boolean iccEq\(String a, String b\) \{ return BindFormFields\.iccEq\(a, b\); \}/ ? 0 : 1)' "$act" || {
    echo "  PIN   ChooserActivity.iccEq no longer delegates to BindFormFields.iccEq" >&2; bad=1; }
  # P6-P9 (NWP-20261105-05): the Clear notices listener, each bounded to its own body. P6, P7 and P9 copy the body
  # into my $b before checking it: a check that matches leaves $1 undef (it has no capture group), so a later check
  # on $1 tests an empty string, not the body (a later $1 !~ /X/ always passes, a later $1 =~ /X/ always fails).
  local cn
  cn='settingsRow\("Clear notices", "[^"]*", v -> \{(.*?)\n        \}\);'
  perl -0ne '/'"$cn"'/s or exit 1; my $b = $1; exit($b =~ /new Thread\(\(\) -> \{\s*final java\.util\.List<String\[\]> sums = bindingSummaries\(\);/ ? 0 : 1)' "$act" || {
    echo "  PIN   the Clear notices listener no longer reads bindingSummaries() inside new Thread(" >&2; bad=1; }
  perl -0ne '/'"$cn"'/s or exit 1; my $b = $1; exit($b =~ /labels == null \?.*labels\.isEmpty\(\) \?.*if \(err == null\) cancelTelNotices\(labels\);/s && $b !~ /DELETE-BINDING/ && $b !~ /cancelTelNotices\(null\)/ ? 0 : 1)' "$act" || {
    echo "  PIN   the Clear notices listener clears before both the null and the empty check, sends DELETE-BINDING, or clears every line" >&2; bad=1; }
  perl -0ne 'exit(/ll\.addView\(unbind, ulp\);\s*(?:\/\/[^\n]*\n\s*)*View clearNotices = settingsRow\("Clear notices"/ ? 0 : 1)' "$act" || {
    echo "  PIN   the Clear notices row is not added directly after the Unbind all row" >&2; bad=1; }
  perl -0ne '/'"$cn"'/s or exit 1; my $b = $1; exit($b =~ /labels\.isEmpty\(\) \? \(sums\.contains\(TelArrival\.DAMAGED_ROW\) \? TelArrival\.BINDING_LINE_DAMAGED : / ? 0 : 1)' "$act" || {
    echo "  PIN   the Clear notices empty branch no longer tells a damaged line (DAMAGED_ROW) from an unbound one" >&2; bad=1; }
  # The helper itself: missing (origin/main) is a failure reported AFTER the pins, so all failures show.
  [ -f "$copy" ] || { echo "  FAIL  BindFormFields.java does not exist (forBind and iccEq are missing)" >&2; return 1; }
  if grep -q 'android\.' "$copy"; then echo "  FAIL  BindFormFields.java mentions android. -- it must stay java.* only" >&2; bad=1; fi
  [ "$bad" -eq 0 ] || return 1
  if [ -z "$JAVAC" ]; then
    echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip: install a JDK or run it on the build VM." >&2
    return 2
  fi
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$copy" "$d/src/com/nowhere/chooser/BindFormFields.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/BindFormCases.java"
  if ! "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.BindFormCases 2>&1); rc=$?
  echo "$out"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

[ -z "$JAVAC" ] || "$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
echo "== $COPY"
suite "$COPY" "$ACT"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAILED (rc=$rc)"; exit "$rc"; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not compile proves nothing)"
mut() { # mut <label> <copy|act> <perl-expr>
  local md mc ma mrc mtarget; md=$(mktemp -d -p "$W"); mc="$md/BindFormFields.java"; ma="$md/ChooserActivity.java"
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
mut "M1 labelEdited ignored"          copy 's/label = labelEdited \? typedLabel : line\[3\];/label = line[3];/' || fails=$((fails+1))
mut "M2 visEdited ignored"            copy 's/vis = visEdited \? typedVis : /vis = /' || fails=$((fails+1))
mut "M3 exact ICCID match"            copy 's/iccEq\(typedIccid, e\[1\]\)/typedIccid.equals(e[1])/' || fails=$((fails+1))
mut "M4 null sums answered typed"     copy 's/if \(sums == null\) return null;/if (sums == null) return new String[]{ typedLabel, typedVis, "0" };/' || fails=$((fails+1))
mut "M5 short-entry skip removed"     copy 's/e\.length >= 5 && //' || fails=$((fails+1))
mut "M6 kept always 0"                copy 's/\? "0" : "1" \}/? "0" : "0" }/' || fails=$((fails+1))
mut "M7 kept always 1"                copy 's/\? "0" : "1" \}/? "1" : "1" }/' || fails=$((fails+1))
mut "M8 forBind call removed"         act  's/final String\[\] f = manual \? BindFormFields\.forBind\(iccid, label, labelEd, visNow, visEd, sums\) : /final String[] f = /' || fails=$((fails+1))
mut "M9 watcher before setText"       act  's/(        labelF\.setText\(sim\.label\);[^\n]*\n)(        labelF\.addTextChangedListener[^\n]*\n)/$2$1/' || fails=$((fails+1))
mut "M10 reflect-back removed"        act  's/labelF\.setText\(sent\[0\]\); vis\[0\] = sent\[1\];//' || fails=$((fails+1))
mut "M11 lineLabels exact ICCID match"  copy 's/e\.length >= 5 && iccEq\(iccid, e\[1\]\)\) out\.add/e.length >= 5 \&\& iccid.equals(e[1])) out.add/' || fails=$((fails+1))
mut "M12 null sums answered empty"      copy 's/if \(sums == null\) return null;(\s*java\.util\.Set<String> out)/if (sums == null) return new java.util.HashSet<>();$1/' || fails=$((fails+1))
mut "M13 lineLabels short-entry skip removed" copy 's/e\.length >= 5 && (iccEq\(iccid, e\[1\]\)\) out\.add)/$1/' || fails=$((fails+1))
mut "M14 listener clears every line"    act  's/(settingsRow\("Clear notices".*?)cancelTelNotices\(labels\)/$1cancelTelNotices(null)/s' || fails=$((fails+1))
mut "M15 listener sends DELETE-BINDING" act  's/(settingsRow\("Clear notices".*?final java\.util\.List<String\[\]> sums = bindingSummaries\(\);)/$1 sendDaemon("DELETE-BINDING\\n" + iccid + "\\n\\n");/s' || fails=$((fails+1))
mut "M16 DAMAGED_ROW check removed"     act  's/sums\.contains\(TelArrival\.DAMAGED_ROW\) \? TelArrival\.BINDING_LINE_DAMAGED : //' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
