#!/usr/bin/env bash
# test-owner-sim-pick-java.sh [--mutate] -- owner Compose asks which unassigned SIM to use, run under javac (NWP-20261111-20).
#
# WHY THIS IS COMMITTED. Backlog row "Owner-mode transmit picks the FIRST unbound SIM — no arrival-SIM selection on a
# 2+-unbound-SIM phone": when the arrival line was not known, buildOwnerComposeScreen sent on unboundSims().get(0), and
# its only disclosure was "(first of N unassigned SIMs)". The owner could not choose another SIM, so the recipient saw
# the wrong number and the wrong line was billed. OwnerSimPick (a pure class, no android import) decides which SIM
# Compose starts on (initial) and names a picker row (rowLabel); it is compiled here with its cases (P1-P4). The SOURCE
# CHECKS (C1-C8) hold ChooserActivity, on its code with the comments stripped: no first-SIM fallback (C1), sim[0] set
# only from OwnerSimPick.initial or a picker tap (C2), Send and Call refuse with no SIM chosen (C3), the picker rows
# read no ICCID (C4), the arrival match stays (C5), the picker shows only for two or more SIMs (C6), SimInfo carries
# the slot and activeSims sets it (C7), and OwnerSimPick.java stays java.* only (C8). Source checks run first and each
# failure is printed; the helper's absence is reported after them.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-owner-sim-pick-java.sh            # the cases + source checks
#   bash test-owner-sim-pick-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
COPY="$root/core/chooser/src/com/nowhere/chooser/OwnerSimPick.java"
ACT="$root/core/chooser/src/com/nowhere/chooser/ChooserActivity.java"
CASES="$root/core/chooser/tests/owner-sim-pick/OwnerSimPickCases.java"
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

SIG='private View buildOwnerComposeScreen(final String prefill, final int arrivedSub, final long arrivedWhen) {'
PICK='final int pick = OwnerSimPick.initial(u.size(), at);'
INIT='sim[0] = pick >= 0 ? u.get(pick) : null;'
TAP='sim[0] = s;'
REFUSE='if (sim[0] == null) {'
LABEL='OwnerSimPick.rowLabel(s.carrier, s.slot)'
ARRIVAL='ownerSimIndexFor(u, arrivedSub, arrivedWhen'
SLOT='try { s.slot = si.getSimSlotIndex(); } catch (Throwable ig) {}'

# suite <OwnerSimPick.java> <ChooserActivity.java> -> 0 pass, 1 a case or source check failed (the only code that
# convicts a mutant), 2 no javac, 3 the class or the cases did not compile.
suite() {
  local copy="$1" act="$2" d out rc cb as sets want line
  local bad=0
  cb=$(body "$act" "$SIG" | code)
  as=$(body "$act" 'private java.util.List<SimInfo> activeSims() {' | code)
  # C1: no first-SIM fallback and no "first of N" disclosure.
  if [ "$(cnt "$cb" 'u.get(0)')" != 0 ] || [ "$(cnt "$cb" 'first of')" != 0 ]; then
    echo "  CHECK C1 buildOwnerComposeScreen still falls back to the first unassigned SIM (u.get(0) / \"first of\")" >&2; bad=1; fi
  # C2: every write of sim[0] is the initial pick or the picker tap, each once; the pick comes from OwnerSimPick.initial.
  sets=$(printf '%s\n' "$cb" | grep -F 'sim[0] =' | grep -vF 'sim[0] ==' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sort)
  want=$(printf '%s\n%s\n' "$INIT" "$TAP" | sort)
  if [ "$sets" != "$want" ] || [ "$(cnt "$cb" "$PICK")" != 1 ] || [ "$(at "$cb" "$PICK")" -ge "$(at "$cb" "$INIT")" ]; then
    echo "  CHECK C2 sim[0] is set other than from OwnerSimPick.initial or a picker tap" >&2; bad=1; fi
  # C3: Send and Call both refuse when no SIM is chosen, with the three texts.
  if [ "$(cnt "$cb" "$REFUSE")" != 2 ]; then
    echo "  CHECK C3 Send and Call do not both refuse when sim[0] is null" >&2; bad=1
  else
    while IFS= read -r line; do
      case "$line" in *'"Choose a SIM first."'*) ;; *) echo "  CHECK C3 a refusal does not say \"Choose a SIM first.\"" >&2; bad=1 ;; esac
      case "$line" in *'"Still finding your line — try again."'*) ;; *) echo "  CHECK C3 a refusal lost \"Still finding your line — try again.\"" >&2; bad=1 ;; esac
      case "$line" in *'return; }'*) ;; *) echo "  CHECK C3 a refusal does not return" >&2; bad=1 ;; esac
    done <<<"$(printf '%s\n' "$cb" | grep -F -- "$REFUSE")"
  fi
  # C4: the picker rows name a SIM through rowLabel and read no ICCID.
  if [ "$(cnt "$cb" '.iccid')" != 0 ] || [ "$(cnt "$cb" "$LABEL")" -lt 1 ]; then
    echo "  CHECK C4 the picker rows read .iccid, or do not use $LABEL" >&2; bad=1; fi
  # C5: the arrival match (NWP-20261014-31) stays.
  if [ "$(cnt "$cb" "$ARRIVAL")" != 1 ]; then
    echo "  CHECK C5 buildOwnerComposeScreen no longer calls $ARRIVAL" >&2; bad=1; fi
  # C6: the picker is shown only for two or more SIMs, and asks for a choice when nothing is chosen.
  if [ "$(cnt "$cb" 'if (u.size() > 1)')" -lt 1 ] || [ "$(cnt "$cb" '"Choose which unassigned SIM to use."')" -lt 1 ]; then
    echo "  CHECK C6 no picker guarded by u.size() > 1, or no \"Choose which unassigned SIM to use.\"" >&2; bad=1; fi
  # C7: SimInfo carries the slot and activeSims sets it.
  line=$(grep -F 'private static class SimInfo {' "$act")
  case "$line" in *'int slot = -1;'*) ;; *) echo "  CHECK C7 SimInfo has no int slot = -1" >&2; bad=1 ;; esac
  if [ "$(cnt "$as" "$SLOT")" != 1 ]; then
    echo "  CHECK C7 activeSims does not set s.slot from si.getSimSlotIndex() once" >&2; bad=1; fi
  # F0: the helper itself -- missing (origin/main) is reported AFTER the source checks, so all failures show.
  [ -f "$copy" ] || { echo "  FAIL  OwnerSimPick.java does not exist" >&2; return 1; }
  # C8: the helper stays java.* only, so this suite can run it.
  if grep -q 'android\.' "$copy"; then echo "  CHECK C8 OwnerSimPick.java mentions android. -- it must stay java.* only" >&2; bad=1; fi
  [ "$bad" -eq 0 ] || return 1
  if [ -z "$JAVAC" ]; then
    echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip: install a JDK or run it on the build VM." >&2
    return 2
  fi
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$copy" "$d/src/com/nowhere/chooser/OwnerSimPick.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/OwnerSimPickCases.java"
  if ! "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.OwnerSimPickCases 2>&1); rc=$?
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
  local md mc ma mrc mtarget; md=$(mktemp -d -p "$W"); mc="$md/OwnerSimPick.java"; ma="$md/ChooserActivity.java"
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
mut "S1 initial picks SIM 0 of two with no arrival"  copy 's/if \(unboundCount == 1\) return 0;/if (unboundCount >= 1) return 0;/' || fails=$((fails+1))
mut "S2 initial ignores a known arrival"             copy 's/if \(arrivalIndex >= 0 && arrivalIndex < unboundCount\) return arrivalIndex;/if (false) return arrivalIndex;/' || fails=$((fails+1))
mut "S3 the u.get(0) fallback restored"              act  's/sim\[0\] = pick >= 0 \? u\.get\(pick\) : null;/sim[0] = pick >= 0 ? u.get(pick) : u.get(0);/' || fails=$((fails+1))
mut "S4 a picker row shows the ICCID"                act  's/OwnerSimPick\.rowLabel\(s\.carrier, s\.slot\)/OwnerSimPick.rowLabel(s.carrier + " " + s.iccid, s.slot)/g' || fails=$((fails+1))
mut "S5 rowLabel drops the slot"                     copy 's/carrier \+ " — SIM " \+ \(slot \+ 1\)/carrier/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
