#!/usr/bin/env bash
# test-tie-copy-java.sh [--mutate] -- NWP-20261112-02: the Tie screen says a reset, lost or broken phone leaves only
# the 12 words, and asks for them to be written down before it ties (docs/product-decisions.md, 2026-10-22). Runs
# core/chooser/tests/tie-copy (TieCopy's two strings and maySend, compiled and EXECUTED) and source checks that
# ProfileActivity.showPhoneTie's OK UNTIED screen lists TieCopy.COST_RESET as its fourth cost point, shows a CheckBox
# given TieCopy.CONFIRM that the tie button waits for, and re-reads it through TieCopy.maySend at the click.
#
# NWP-20261119-23: the cases also execute TieCopy.failText, the words for every reply that is not OK (no answer says
# the tie may still finish, not that it failed). Source checks s5-s7 pin ProfileActivity.runTieVerb: it reads with
# TieCopy.READ_MS and no numeric cap (s5); READ_MS outlasts handleSETie's deadline, seTieSlotWait plus the minutes in
# its conn.SetDeadline, both read from core/agent/se_tie.go and never written here, so raising either on the daemon
# side fails this suite (s6); the reply block words its replies through TieCopy.failText (s7).
#
# It needs a JDK, and it FAILS when there is none. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
# --mutate re-runs the suite against broken copies, each of which must FAIL: a mutant that does not apply (INERT) or
# does not compile (BROKEN) counts as a failure, never a pass.
#
#   bash test-tie-copy-java.sh            # the cases
#   bash test-tie-copy-java.sh --mutate   # ... plus the mutants
set -uo pipefail
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W"
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-tie-copy-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
TC="$ROOT/core/chooser/src/com/nowhere/chooser/TieCopy.java"
PA="$ROOT/core/chooser/src/com/nowhere/chooser/ProfileActivity.java"
SE="$ROOT/core/agent/se_tie.go"

# at <haystack> <needle>: the byte offset of needle's first occurrence, or -1.
at() {
  local pre
  case "$1" in *"$2"*) ;; *) echo -1; return ;; esac
  pre=${1%%"$2"*}
  echo "${#pre}"
}

# check <TieCopy.java> <ProfileActivity.java> <se_tie.go>: the cases, then the seven source checks.
check() {
  local tc=$1 pa=$2 se=$3 body untied fair cost again cb lines l n=0
  local run rt rl k=0 readms slot unit mins slot_s limit_ms
  JAVAC=$JAVAC JAVA=$JAVA bash "$ROOT/core/chooser/tests/tie-copy/run.sh" "$tc" || return 1
  # showPhoneTie, up to the next method; its OK UNTIED branch, up to the OK TIED one.
  body=$(awk '/^    private void showPhoneTie\(\) \{/{on=1; print; next} on && /^    private void /{exit} on' "$pa")
  [ -n "$body" ] || { echo "FAIL: showPhoneTie is gone"; return 1; }
  untied=$(awk '/if \("OK UNTIED"\.equals\(st\)\) \{/{on=1} on && /\} else if \("OK TIED"\.equals\(st\)\)/{exit} on' <<<"$body")
  [ -n "$untied" ] || { echo "FAIL: showPhoneTie has no OK UNTIED branch"; return 1; }
  # (s1) TieCopy.COST_RESET is the fourth cost point: after the Fairphone one, before "You can untie it again here."
  fair=$(at "$untied" "A Fairphone can't open a tied profile at all.")
  cost=$(at "$untied" "+ TieCopy.COST_RESET")
  again=$(at "$untied" "You can untie it again here.")
  if [ "$fair" -lt 0 ] || [ "$cost" -lt 0 ] || [ "$again" -lt 0 ] || [ "$cost" -lt "$fair" ] || [ "$again" -lt "$cost" ]; then
    echo "FAIL s1: the OK UNTIED text does not list TieCopy.COST_RESET between the Fairphone point and \"You can untie it again here.\" (offsets $fair $cost $again)"
    return 1
  fi
  # (s2) a CheckBox in showPhoneTie is given TieCopy.CONFIRM
  cb=$(sed -n 's/.*final android\.widget\.CheckBox \([A-Za-z_][A-Za-z0-9_]*\) = new android\.widget\.CheckBox(this);.*/\1/p' <<<"$body" | head -1)
  [ -n "$cb" ] || { echo "FAIL s2: showPhoneTie makes no CheckBox"; return 1; }
  case "$body" in *"$cb.setText(TieCopy.CONFIRM);"*) ;; *) echo "FAIL s2: the CheckBox $cb is not given TieCopy.CONFIRM"; return 1 ;; esac
  # (s3) every click that runs the act button's verb asks TieCopy.maySend first, on the box
  lines=$(grep -F 'runTieVerb(verb, pass, msg, act' <<<"$body")
  [ -n "$lines" ] || { echo "FAIL s3: no click runs runTieVerb(verb, pass, msg, act...)"; return 1; }
  while IFS= read -r l; do
    n=$((n+1))
    case "$l" in *"TieCopy.maySend(verb, $cb.isChecked())"*"runTieVerb("*) ;;
      *) echo "FAIL s3: a click runs runTieVerb without TieCopy.maySend(verb, $cb.isChecked()) first: $l"; return 1 ;; esac
  done <<<"$lines"
  # (s4) on the OK UNTIED screen the tie button starts disabled and follows the box
  case "$untied" in *"act.setEnabled(false);"*) ;; *) echo "FAIL s4: the tie button is not disabled until the box is ticked"; return 1 ;; esac
  case "$untied" in *"$cb.setOnCheckedChangeListener((b, on) -> act.setEnabled(on));"*) ;;
    *) echo "FAIL s4: the tie button does not follow the box"; return 1 ;; esac
  # runTieVerb, up to the next method.
  run=$(awk '/^    private void runTieVerb\(/{on=1; print; next} on && /^    private /{exit} on' "$pa")
  [ -n "$run" ] || { echo "FAIL s5: runTieVerb is gone"; return 1; }
  # (s5) every roundTrip in runTieVerb reads for TieCopy.READ_MS, and none for a number
  rt=$(grep -F 'roundTrip(' <<<"$run")
  [ -n "$rt" ] || { echo "FAIL s5: runTieVerb makes no roundTrip"; return 1; }
  while IFS= read -r rl; do
    k=$((k+1))
    case "$rl" in *", TieCopy.READ_MS)"*) ;; *) echo "FAIL s5: runTieVerb reads without TieCopy.READ_MS: $rl"; return 1 ;; esac
    if [[ "$rl" =~ ,\ *[0-9] ]]; then echo "FAIL s5: runTieVerb holds a numeric read cap: $rl"; return 1; fi
  done <<<"$rt"
  # (s6) READ_MS outlasts the daemon's deadline: seTieSlotWait + M*time.Minute, both read from se_tie.go
  readms=$(sed -n 's/^ *static final int READ_MS = \([0-9_]*\);.*/\1/p' "$tc" | head -1); readms=${readms//_/}
  slot=$(sed -n 's/^var seTieSlotWait = \([0-9]*\) \* time\.\(Second\|Minute\)$/\1/p' "$se" | head -1)
  unit=$(sed -n 's/^var seTieSlotWait = \([0-9]*\) \* time\.\(Second\|Minute\)$/\2/p' "$se" | head -1)
  mins=$(sed -n 's/^\tconn\.SetDeadline(time\.Now()\.Add(seTieSlotWait + \([0-9]*\)\*time\.Minute))$/\1/p' "$se" | head -1)
  case "$readms" in ''|*[!0-9]*) echo "FAIL s6: no 'static final int READ_MS = <n>;' in TieCopy"; return 1 ;; esac
  case "$slot" in ''|*[!0-9]*) echo "FAIL s6: no 'var seTieSlotWait = <n> * time.Second|Minute' in $se"; return 1 ;; esac
  case "$mins" in ''|*[!0-9]*) echo "FAIL s6: no 'conn.SetDeadline(time.Now().Add(seTieSlotWait + <n>*time.Minute))' in $se"; return 1 ;; esac
  slot_s=$slot; [ "$unit" = Minute ] && slot_s=$((slot*60))
  limit_ms=$(( (slot_s + mins*60) * 1000 ))
  if [ "$readms" -le "$limit_ms" ]; then
    echo "FAIL s6: TieCopy.READ_MS ($readms ms) does not outlast handleSETie's deadline (seTieSlotWait ${slot_s} s + $mins min = $limit_ms ms)"
    return 1
  fi
  # (s7) the reply block words its replies through TieCopy.failText, in the status line and in the toast
  case "$run" in *"StatusLine.error(msg, TieCopy.failText(r));"*) ;; *) echo "FAIL s7: runTieVerb does not show TieCopy.failText(r) in the status line"; return 1 ;; esac
  case "$run" in *"Toast.makeText(this, TieCopy.failText(r),"*) ;; *) echo "FAIL s7: runTieVerb does not toast TieCopy.failText(r)"; return 1 ;; esac
  case "$run" in *'"Couldn'"'"'t change it'*) echo "FAIL s7: runTieVerb words a reply itself (\"Couldn't change it\")"; return 1 ;; esac
  echo "  ok   source checks s1 s2 s3 ($n click line(s)) s4 s5 ($k read(s)) s6 ($readms > $limit_ms ms) s7"
}
check "$TC" "$PA" "$SE" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <tc|pa|se> <perl-expr> <text the failure must contain>
  local d f o tc pa se out rc
  d=$(mktemp -d -p "$W"); tc=$TC; pa=$PA; se=$SE
  case "$2" in
    tc) o=$TC; f="$d/TieCopy.java"; tc=$f ;;
    pa) o=$PA; f="$d/ProfileActivity.java"; pa=$f ;;
    se) o=$SE; f="$d/se_tie.go"; se=$f ;;
    *) echo "  ERROR     $1 -- unknown kind $2"; return 1 ;;
  esac
  cp "$o" "$f"
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed"; return 1; fi
  if cmp -s "$o" "$f"; then echo "  INERT     $1"; return 1; fi
  out=$(check "$tc" "$pa" "$se" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  case "$out" in *"$4"*) ;; *) echo "  BROKEN    $1 -- it failed, but not with '$4' (rc=$rc)"; return 1 ;; esac
  echo "  convicted $1"
}
fails=0
mut "M1 maySend always true" tc 's/return !"SE-TIE"\.equals\(verb\) \|\| confirmed;/return true;/' "FAIL a tie is not sent unconfirmed" || fails=$((fails+1))
mut "M2 COST_RESET drops \"including us.\"" tc 's/, including us\."/."/' "FAIL the fourth cost point" || fails=$((fails+1))
mut "M3 CONFIRM shortened" tc 's/"I have my 12-word recovery code written down"/"I have my recovery code"/' "FAIL the confirmation" || fails=$((fails+1))
mut "M4 the maySend guard removed from the click" pa 's/if \(TieCopy\.maySend\(verb, confirm\.isChecked\(\)\)\) (runTieVerb\(verb, pass, msg, act, confirm\);)\n\s*else StatusLine\.error\(msg, "tick the box above to confirm you have your recovery code"\);/$1/' "FAIL s3" || fails=$((fails+1))
mut "M5 COST_RESET removed from the OK UNTIED body" pa 's/\n\s*\+ TieCopy\.COST_RESET \+ "\\n\\n"/ + "\\n"/' "FAIL s1" || fails=$((fails+1))
mut "M6 the tie button starts enabled" pa 's/(verb = "SE-TIE";\n\s*)act\.setEnabled\(false\);[^\n]*\n/$1/' "FAIL s4" || fails=$((fails+1))
mut "M7 READ_MS = 600_000" tc 's/static final int READ_MS = 690_000;/static final int READ_MS = 600_000;/' "FAIL s6" || fails=$((fails+1))
mut "M8 runTieVerb reads for the literal 600_000" pa 's/(roundTrip\(verb \+ "\\n" \+ p \+ "\\n", )TieCopy\.READ_MS\)/${1}600_000)/' "FAIL s5" || fails=$((fails+1))
mut "M9 failText(\"\") falls to the default line" tc 's/\n\s*if \(r\.isEmpty\(\)\) return "The phone[^;]*;//s' 'FAIL no answer ("")' || fails=$((fails+1))
mut "M10 failText matches ERR-PASS by startsWith" tc 's/"ERR-PASS"\.equals\(r\)/r.startsWith("ERR-PASS")/' "FAIL ERR-PASSWORD is not ERR-PASS" || fails=$((fails+1))
mut "M11 se_tie.go's deadline raised to 20 minutes (copy)" se 's/seTieSlotWait \+ 10\*time\.Minute/seTieSlotWait + 20*time.Minute/' "FAIL s6" || fails=$((fails+1))
mut "M12 seTieSlotWait raised to 5 minutes (copy)" se 's/^var seTieSlotWait = 60 \* time\.Second$/var seTieSlotWait = 5 * time.Minute/m' "FAIL s6" || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
