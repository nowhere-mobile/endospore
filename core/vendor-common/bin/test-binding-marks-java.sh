#!/usr/bin/env bash
# test-binding-marks-java.sh [--mutate] -- owner mode marks a SIM "this phone's own line", run under javac (NWP-20261110-07).
#
# WHY THIS IS COMMITTED. Q031 (docs/product-decisions.md, 2026-10-20) decided that in a rebuilt bindings file a SIM no
# line names stays unresolved until the owner binds it or marks it "mine". The daemon half is GET-BINDINGS' marks
# (REBUILT, MINE <iccid>) and SET-SIM-MINE (NWP-20261110-02). BindingMarks (a pure class, no android import) reads the
# marks, says whether a SIM is the owner's line, and maps SET-SIM-MINE's reply to the line the owner sees; it is
# compiled here with BindFormFields (its iccEq) and its cases (K1-K5). The SOURCE CHECKS (U1-U6) hold ChooserActivity,
# on its code with the comments stripped: unboundSims offers a SIM only through marks.ownersLine (U1), its fail-closed
# guard still comes right after the read (U2), the only SET-SIM-MINE send runs on a started worker thread (U3),
# unboundSims and the SIM lines loader take their marks from the same read as their rows (U4), the row maps the reply
# through BindingMarks and shows only for a rebuilt file's unnamed SIM with an ICCID (U5), and fillSimRows labels such a
# SIM and clears the marks of a bound one (U6). Source checks run first and each failure is printed; the helper's
# absence is reported after them.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-binding-marks-java.sh            # the cases + source checks
#   bash test-binding-marks-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
COPY="$root/core/chooser/src/com/nowhere/chooser/BindingMarks.java"
BFF="$root/core/chooser/src/com/nowhere/chooser/BindFormFields.java"
ACT="$root/core/chooser/src/com/nowhere/chooser/ChooserActivity.java"
CASES="$root/core/chooser/tests/binding-marks/BindingMarksCases.java"
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

READ='final java.util.List<String> lines = bindingReply();'
ROWS='java.util.List<String[]> bindings = bindingSummaries(lines);'
GUARD='if (bindings == null || bindings == TelArrival.DAMAGED_BINDINGS || bindings.contains(TelArrival.DAMAGED_ROW)) return out;'
MARKS='final BindingMarks marks = BindingMarks.parse(lines);'
ADD='if (!bound && marks.ownersLine(s.iccid)) out.add(s);'
STAMP='for (SimInfo a : sims) { a.rebuilt = marks.rebuilt; a.mine = marks.rebuilt && marks.ownersLine(a.iccid); }'
CLEAR='fs.rebuilt = false; fs.mine = false;'
LABEL='} else if (fs.rebuilt) bound = fs.mine ? BindingMarks.OWN_LINE : BindingMarks.NOT_OWN_LINE;'

# suite <BindingMarks.java> <ChooserActivity.java> -> 0 pass, 1 a case or source check failed (the only code that
# convicts a mutant), 2 no javac, 3 the class or the cases did not compile.
suite() {
  local copy="$1" act="$2" d out rc u ld fs bs br all a b c
  local bad=0
  u=$(body "$act" 'private java.util.List<SimInfo> unboundSims()' | code)
  ld=$(body "$act" 'private View buildBindingScreen()' | code | awk '/new Thread\(\(\) -> \{/ { buf=""; on=1 } on { buf = buf $0 "\n" } on && /"nowhere-sim-lines"/ { printf "%s", buf; exit }')
  fs=$(body "$act" 'private void fillSimRows(LinearLayout rows, java.util.List<String[]> sums, java.util.List<SimInfo> sims, int inactiveEsims)' | code)
  bs=$(body "$act" 'private View buildBindSimScreen(final SimInfo sim0)' | code)
  br=$(body "$act" 'private java.util.List<String> bindingReply()' | code)
  all=$(code < "$act")
  # U1: unboundSims adds a SIM only through marks.ownersLine, and never by the bare unbound test.
  if [ "$(cnt "$u" "$ADD")" != 1 ] || [ "$(cnt "$u" 'if (!bound) out.add(s);')" != 0 ]; then
    echo "  CHECK U1 unboundSims does not offer a SIM only when marks.ownersLine(s.iccid) holds" >&2; bad=1; fi
  # U2: the read, the rows, then the three-clause guard, line after line; the marks are parsed after the guard.
  a=$(at "$u" "$READ"); b=$(at "$u" "$ROWS"); c=$(at "$u" "$GUARD")
  if [ "$a" -eq 0 ] || [ "$b" -ne $((a + 1)) ] || [ "$c" -ne $((b + 1)) ] || [ "$(at "$u" "$MARKS")" -le "$c" ]; then
    echo "  CHECK U2 unboundSims' fail-closed guard is not the first statement after the GET-BINDINGS read" >&2; bad=1; fi
  # U3: the only SET-SIM-MINE send is the first thing a started worker thread does.
  if [ "$(cnt "$all" 'SET-SIM-MINE')" != 1 ]; then
    echo "  CHECK U3 SET-SIM-MINE is not sent from exactly one place in ChooserActivity's code" >&2; bad=1; fi
  perl -0e 'my $m = $ARGV[0]; exit($m =~ /new Thread\(\(\) -> \{\s*final String r = sendDaemon\("SET-SIM-MINE\\n" \+ sim\.iccid \+ "\\n" \+ \(markIt \? "1" : "0"\) \+ "\\n"\);.*?\}, "nowhere-sim-mine"\)\.start\(\);/s ? 0 : 1)' "$bs" || {
    echo "  CHECK U3 the SET-SIM-MINE send does not run inside a started new Thread(" >&2; bad=1; }
  # U4: one read serves the rows and the marks, in unboundSims and in the SIM lines loader.
  if [ "$(cnt "$u" "$READ")" != 1 ] || [ "$(cnt "$u" 'bindingReply()')" != 1 ] || [ "$(cnt "$u" 'bindingSummaries()')" != 0 ] || [ "$(cnt "$u" "$MARKS")" != 1 ]; then
    echo "  CHECK U4 unboundSims does not take its rows and its marks from one bindingReply() read" >&2; bad=1; fi
  a=$(at "$ld" "$READ"); b=$(at "$ld" 'final BindingMarks marks = BindingMarks.parse(lines);'); c=$(at "$ld" "$STAMP")
  if [ "$(cnt "$ld" 'bindingReply()')" != 1 ] || [ "$(cnt "$ld" 'bindingSummaries()')" != 0 ] || [ "$(cnt "$ld" 'final java.util.List<String[]> sums = bindingSummaries(lines);')" != 1 ] \
     || [ "$a" -eq 0 ] || [ "$b" -le "$a" ] || [ "$c" -le "$b" ] || [ "$(at "$ld" 'fillSimRows(rows, sums, sims, inactiveEsims)')" -le "$c" ]; then
    echo "  CHECK U4 the nowhere-sim-lines loader does not stamp the marks of its rows' own read onto the SIMs it passes to fillSimRows" >&2; bad=1; fi
  if [ "$(cnt "$all" '"GET-BINDINGS\n"')" != 1 ] || [ "$(cnt "$br" '"GET-BINDINGS\n"')" != 1 ]; then
    echo "  CHECK U4 GET-BINDINGS is not read from bindingReply() alone" >&2; bad=1; fi
  # U5: the row shows only for a rebuilt file's unnamed SIM with an ICCID, and maps the reply through BindingMarks.
  if [ "$(cnt "$bs" 'if (sim.rebuilt && !sim.iccid.isEmpty()) {')" != 1 ] || [ "$(cnt "$bs" 'final String out = BindingMarks.mineOutcome(r);')" != 1 ] \
     || [ "$(cnt "$bs" 'final String line = BindingMarks.DAMAGED.equals(out) ? TelArrival.BINDINGS_DAMAGED : out;')" != 1 ]; then
    echo "  CHECK U5 the own-line row is not guarded by sim.rebuilt and an ICCID, or its reply does not go through BindingMarks" >&2; bad=1; fi
  perl -0e 'my $m = $ARGV[0]; exit($m =~ /if \(BindingMarks\.mineBack\(r\)\) \{\s*setContentView\(buildBindingScreen\(\)\);/ && $m =~ /StatusLine\.error\(msg, line\);/ ? 0 : 1)' "$bs" || {
    echo "  CHECK U5 a written mark does not reload the SIM lines, or a failure is not shown" >&2; bad=1; }
  # U6: fillSimRows clears a bound SIM's marks and labels a rebuilt file's unnamed SIM.
  if [ "$(cnt "$fs" "$CLEAR")" != 1 ] || [ "$(cnt "$fs" "$LABEL")" != 1 ] || [ "$(at "$fs" "$LABEL")" -le "$(at "$fs" "$CLEAR")" ]; then
    echo "  CHECK U6 fillSimRows does not clear a bound SIM's marks and label an unnamed SIM of a rebuilt file" >&2; bad=1; fi
  # F0: the helper itself -- missing (origin/main) is reported AFTER the source checks, so all failures show.
  [ -f "$copy" ] || { echo "  FAIL  BindingMarks.java does not exist" >&2; return 1; }
  if grep -q 'android\.' "$copy"; then echo "  FAIL  BindingMarks.java mentions android. -- it must stay java.* only" >&2; bad=1; fi
  [ "$bad" -eq 0 ] || return 1
  if [ -z "$JAVAC" ]; then
    echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip: install a JDK or run it on the build VM." >&2
    return 2
  fi
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$copy" "$d/src/com/nowhere/chooser/BindingMarks.java"
  cp "$BFF" "$d/src/com/nowhere/chooser/BindFormFields.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/BindingMarksCases.java"
  if ! "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.BindingMarksCases 2>&1); rc=$?
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
  local md mc ma mrc mtarget; md=$(mktemp -d -p "$W"); mc="$md/BindingMarks.java"; ma="$md/ChooserActivity.java"
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
mut "M1 ownersLine ignores rebuilt"                  copy 's/\n[ ]*if \(!rebuilt\) return true;//' || fails=$((fails+1))
mut "M2 ownersLine matches without iccEq"            copy 's/BindFormFields\.iccEq\(iccid, m\)/iccid.equals(m)/' || fails=$((fails+1))
mut "M3 unboundSims drops the ownersLine test"       act  's/if \(!bound && marks\.ownersLine\(s\.iccid\)\) out\.add\(s\);/if (!bound) out.add(s);/' || fails=$((fails+1))
mut "M4 an empty ICCID is the owner's line"          copy 's/(if \(iccid == null \|\| iccid\.trim\(\)\.isEmpty\(\)\) return )false;/${1}true;/' || fails=$((fails+1))
mut "M5 mineOutcome maps ERR repair to done"         copy 's/if \(t\.equals\("ERR repair"\)\) return REPAIR_FIRST;/if (t.equals("ERR repair")) return DONE;/' || fails=$((fails+1))
mut "M6 the send on the UI thread"                   act  's/new Thread\(\(\) -> \{(\s*final String r = sendDaemon\("SET-SIM-MINE)/((Runnable) () -> {$1/; s/\}, "nowhere-sim-mine"\)\.start\(\);/}).run();/' || fails=$((fails+1))
mut "M7 the loader reads the marks a second time"    act  's/(final BindingMarks marks = BindingMarks\.parse\()lines(\); \/\/ NWP-20261110-07)/${1}bindingReply()$2/' || fails=$((fails+1))
mut "M8 a bound SIM keeps its marks"                 act  's/\n[ ]*fs\.rebuilt = false; fs\.mine = false;[^\n]*//' || fails=$((fails+1))
mut "M9 the marks parsed before the guard"           act  's/(\n[ ]*if \(bindings == null \|\| bindings == TelArrival\.DAMAGED_BINDINGS[^\n]*)(\n[ ]*final BindingMarks marks = BindingMarks\.parse\(lines\);)/$2$1/' || fails=$((fails+1))
mut "M10 the row shown for a manual SIM"             act  's/if \(sim\.rebuilt && !sim\.iccid\.isEmpty\(\)\) \{/if (sim.rebuilt) {/' || fails=$((fails+1))
mut "M11 ERR damaged shown as the key"               act  's/final String line = BindingMarks\.DAMAGED\.equals\(out\) \? TelArrival\.BINDINGS_DAMAGED : out;/final String line = out;/' || fails=$((fails+1))
mut "M12 parse takes a binding line as a mark"       copy 's/ && t\.indexOf\(\x27\|\x27\) < 0//' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
