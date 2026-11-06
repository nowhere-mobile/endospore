#!/usr/bin/env bash
# test-bindings-repair-java.sh [--mutate] -- owner mode's "Repair SIM bindings", run under javac (NWP-20261110-06).
#
# WHY THIS IS COMMITTED. Q031 (docs/product-decisions.md, 2026-10-20) decided one "Repair SIM bindings" in owner mode,
# and that a repair that fails says so and points at a reset. The daemon half is REPAIR-BINDINGS (NWP-20261110-02).
# BindingsRepair (a pure class, no android import) holds the confirmation copy and maps the daemon's reply to the line
# the owner sees; it is compiled here with its cases (O1-O4). The SOURCE CHECKS (F1-F5) hold ChooserActivity, on its
# code with the comments stripped: fillSimRows offers the row in both damage states (before the unreadable file's
# early return, and not in the busy state), the tap asks with BindingsRepair.CONFIRM before the only REPAIR-BINDINGS
# send, the send runs on a worker thread, the reply goes through BindingsRepair.outcome, and an OK re-runs a live
# session's owner verdict on that thread before the UI reloads. Source checks run first and each failure is printed;
# the helper's absence is reported after them.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-bindings-repair-java.sh            # the cases + source checks
#   bash test-bindings-repair-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
COPY="$root/core/chooser/src/com/nowhere/chooser/BindingsRepair.java"
ACT="$root/core/chooser/src/com/nowhere/chooser/ChooserActivity.java"
CASES="$root/core/chooser/tests/bindings-repair/BindingsRepairCases.java"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
[ -f "$ACT" ] && [ -f "$CASES" ] || { echo "FAIL: missing $ACT or $CASES" >&2; exit 2; }

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

ROWLINE='if (sums != null) rows.addView(settingsRow(BindingsRepair.ROW, BindingsRepair.ROW_SUMMARY, v -> confirmRepairBindings(err)), new LinearLayout.LayoutParams(MATCH, WRAP));'
DAMAGE='if (sums == null || sums == TelArrival.DAMAGED_BINDINGS || sums.contains(TelArrival.DAMAGED_ROW)) {'
EARLY='if (sums == null || sums == TelArrival.DAMAGED_BINDINGS) return;'
SEND='final String r = sendDaemon("REPAIR-BINDINGS\n");'
VERDICT='if (BindingsRepair.ok(r)) reapplyLiveTelVerdict();'

# suite <BindingsRepair.java> <ChooserActivity.java> -> 0 pass, 1 a case or source check failed (the only code that
# convicts a mutant), 2 no javac, 3 the class or the cases did not compile.
suite() {
  local copy="$1" act="$2" d out rc fs m all a b c e
  local bad=0
  fs=$(body "$act" 'private void fillSimRows(LinearLayout rows, java.util.List<String[]> sums, java.util.List<SimInfo> sims, int inactiveEsims)' | code)
  m=$(body "$act" 'private void confirmRepairBindings(TextView status)' | code)
  all=$(code < "$act")
  # F1: the row, once, inside the damage branch and before the unreadable file's early return; not in the busy state.
  a=$(at "$fs" "$DAMAGE"); b=$(at "$fs" "$ROWLINE"); c=$(at "$fs" "$EARLY")
  if [ "$(cnt "$fs" "$ROWLINE")" != 1 ] || [ "$a" -eq 0 ] || [ "$b" -le "$a" ] || [ "$c" -le "$b" ]; then
    echo "  CHECK F1 fillSimRows does not add the Repair row (guarded by sums != null) exactly once between the damage test and the early return" >&2; bad=1; fi
  # F2: the dialog, with CONFIRM and its Repair button, comes before the send -- and the send is the file's only one.
  a=$(at "$m" 'new android.app.AlertDialog.Builder(this)'); b=$(at "$m" '.setMessage(BindingsRepair.CONFIRM)')
  c=$(at "$m" '.setPositiveButton("Repair",'); e=$(at "$m" "$SEND")
  if [ "$a" -eq 0 ] || [ "$b" -le "$a" ] || [ "$c" -le "$b" ] || [ "$e" -le "$c" ] || [ "$(cnt "$m" '.setNegativeButton("Cancel", null)')" != 1 ]; then
    echo "  CHECK F2 confirmRepairBindings does not ask with BindingsRepair.CONFIRM (Repair / Cancel) before the REPAIR-BINDINGS send" >&2; bad=1; fi
  if [ "$(cnt "$all" 'REPAIR-BINDINGS')" != 1 ]; then
    echo "  CHECK F2 REPAIR-BINDINGS is not sent from exactly one place in ChooserActivity's code" >&2; bad=1; fi
  # F3: the send is the first thing a started worker thread does.
  perl -0e 'my $m = $ARGV[0]; exit($m =~ /new Thread\(\(\) -> \{\s*final String r = sendDaemon\("REPAIR-BINDINGS\\n"\);.*\}, "nowhere-bindings-repair"\)\.start\(\);/s ? 0 : 1)' "$m" || {
    echo "  CHECK F3 the REPAIR-BINDINGS send does not run inside a started new Thread(" >&2; bad=1; }
  # F4: the reply goes through BindingsRepair: an OK reloads the SIM lines, anything else stays on the status line.
  perl -0e 'my $m = $ARGV[0]; exit($m =~ /final String line = BindingsRepair\.outcome\(r\);/ && $m =~ /if \(BindingsRepair\.ok\(r\)\) \{\s*setContentView\(buildBindingScreen\(\)\);/ && $m =~ /StatusLine\.error\(status, line\);/ ? 0 : 1)' "$m" || {
    echo "  CHECK F4 the reply does not go through BindingsRepair.outcome / ok, or an OK does not reload, or a failure is not shown" >&2; bad=1; }
  # F5: an OK re-runs the live session's owner verdict on the worker thread, before the UI reload (NWP-20261005-12).
  a=$(at "$m" "$SEND"); b=$(at "$m" "$VERDICT"); c=$(at "$m" 'runOnUiThread(')
  if [ "$(cnt "$m" "$VERDICT")" != 1 ] || [ "$a" -eq 0 ] || [ "$b" -le "$a" ] || [ "$c" -le "$b" ]; then
    echo "  CHECK F5 an OK does not call reapplyLiveTelVerdict() on the worker thread between the send and runOnUiThread" >&2; bad=1; fi
  # F0: the helper itself -- missing (origin/main) is reported AFTER the source checks, so all failures show.
  [ -f "$copy" ] || { echo "  FAIL  BindingsRepair.java does not exist" >&2; return 1; }
  if grep -q 'android\.' "$copy"; then echo "  FAIL  BindingsRepair.java mentions android. -- it must stay java.* only" >&2; bad=1; fi
  [ "$bad" -eq 0 ] || return 1
  if [ -z "$JAVAC" ]; then
    echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip: install a JDK or run it on the build VM." >&2
    return 2
  fi
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$copy" "$d/src/com/nowhere/chooser/BindingsRepair.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/BindingsRepairCases.java"
  if ! "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.BindingsRepairCases 2>&1); rc=$?
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
  local md mc ma mrc mtarget; md=$(mktemp -d -p "$W"); mc="$md/BindingsRepair.java"; ma="$md/ChooserActivity.java"
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
mut "M1 the row added after the early return"   act  's/(\n[ ]*if \(sums != null\) rows\.addView\(settingsRow\(BindingsRepair\.ROW,[^\n]*)(\n[ ]*if \(sums == null \|\| sums == TelArrival\.DAMAGED_BINDINGS\) return;[^\n]*)/$2$1/' || fails=$((fails+1))
mut "M2 the send without the dialog"            act  's/v -> confirmRepairBindings\(err\)/v -> new Thread(() -> sendDaemon("REPAIR-BINDINGS\\n")).start()/' || fails=$((fails+1))
mut "M2b the dialog without CONFIRM"            act  's/\.setMessage\(BindingsRepair\.CONFIRM\)/.setMessage(BindingsRepair.ROW_SUMMARY)/' || fails=$((fails+1))
mut "M3 the send on the UI thread"              act  's/new Thread\(\(\) -> \{(\s*final String r = sendDaemon\("REPAIR-BINDINGS)/((Runnable) () -> {$1/; s/\}, "nowhere-bindings-repair"\)\.start\(\);/}).run();/' || fails=$((fails+1))
mut "M4 outcome maps ERR io to success"         copy 's/(t\.startsWith\("ERR io "\)\) return )IO;/${1}CLEAN;/' || fails=$((fails+1))
mut "M5 outcome maps BUSY to success"           copy 's/if \(t\.equals\("BUSY"\)\) return BUSY;/if (t.equals("BUSY")) return CLEAN;/' || fails=$((fails+1))
mut "M6 CONFIRM drops the own-line sentence"    copy 's/a SIM with no binding is not this phone\x27s own line until you mark it so, and //' || fails=$((fails+1))
mut "M7 the row shown in the busy state too"    act  's/if \(sums != null\) (rows\.addView\(settingsRow\(BindingsRepair\.ROW)/$1/' || fails=$((fails+1))
mut "M8 the re-verdict deleted"                 act  's/\n[ ]*if \(BindingsRepair\.ok\(r\)\) reapplyLiveTelVerdict\(\);[^\n]*//' || fails=$((fails+1))
mut "M9 the re-verdict on the UI thread"        act  's/\n([ ]*if \(BindingsRepair\.ok\(r\)\) reapplyLiveTelVerdict\(\);[^\n]*)(\n[ ]*runOnUiThread\(\(\) -> \{)/$2\n$1/' || fails=$((fails+1))
mut "M10 an OK left unreloaded"                 act  's/(if \(BindingsRepair\.ok\(r\)\) \{\s*)setContentView\(buildBindingScreen\(\)\);/$1/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
