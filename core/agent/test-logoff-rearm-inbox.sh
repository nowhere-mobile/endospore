#!/usr/bin/env bash
# test-logoff-rearm-inbox.sh [--mutate] -- runs logoff_rearm_inbox_test.go (NWP-20261019-04); --mutate re-runs it
# against main.go with each part of the fix broken in turn, restoring the file on exit. Each mutant must be
# CONVICTED by a test failure; one that fails to apply, or fails to compile, counts as a failure.
# NWP-20261123-16: every wait in the test file that bounds real work is rearmHang (2 minutes), so it fails only as a
# hang, never on a slow lane. A source check runs first and refuses any other deadline; --mutate also runs it on a
# copy with one deadline shortened (S1) and on copies with rearmHang weakened to 1 minute (S2-S4). M3 removes the
# event two tests wait for, so it is convicted at the rearmHang bound: a mutant that removes the event can only show
# as a hang.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
MAIN=main.go
TESTF=logoff_rearm_inbox_test.go
RUN=(go test -count=1 -timeout 15m -run 'TestLogoffRearmInbox_' .)
W=$(mktemp -d) || exit 2
trap 'if [ -f "$W/main.go.orig" ]; then cp -f "$W/main.go.orig" "$MAIN"; fi; rm -rf "$W"' EXIT

# check_deadlines <file>: every duration literal in <file> is on the allow list below, every logoffDone(, tr.wait(
# and time.Now().Add( takes exactly rearmHang, and rearmHang is declared once, at 2 minutes or more. It prints each
# offending line and returns non-zero.
check_deadlines() {
  local f=$1 bad=0 hits line text n
  hits=$(grep -nE 'time\.(Hour|Minute|Second|Millisecond|Microsecond|Nanosecond)' "$f" || true)
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    text=${line#*:}
    text=$(printf '%s' "$text" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    # The declaration is matched whole: one decimal count of minutes, then only an optional comment, so no
    # expression (2 / 2 * time.Minute) can pass as 2 minutes.
    if [[ "$text" =~ ^const\ rearmHang\ =\ ([1-9][0-9]{0,5})\ \*\ time\.Minute(\ //.*)?$ ]]; then
      n=${BASH_REMATCH[1]}
      if [ "$n" -ge 2 ]; then continue; fi
    fi
    case $text in
      'logoffStallLimit, logoffStallHardCap, logoffStallTick = limit, time.Hour, 50*time.Millisecond') continue ;;
      'shortStall(t, 2500*time.Millisecond)') continue ;;
      'time.Sleep(20 * time.Millisecond)') continue ;;
      'logoffStallLimit = time.Hour //'*) continue ;;
    esac
    echo "FAIL source check: a duration that is not rearmHang: $line"; bad=1
  done <<< "$hits"
  hits=$(grep -nE 'logoffDone\(|tr\.wait\(|time\.Now\(\)\.Add\(' "$f" || true)
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    text=${line//'logoffDone(t, uid, rearmHang)'/}
    text=${text//'tr.wait(t, rearmHang)'/}
    text=${text//'time.Now().Add(rearmHang)'/}
    case $text in
      *'logoffDone('*|*'tr.wait('*|*'time.Now().Add('*)
        echo "FAIL source check: a deadline that is not rearmHang: $line"; bad=1 ;;
    esac
  done <<< "$hits"
  n=$(grep -c '^const rearmHang = ' "$f" || true)
  if [ "$n" != 1 ]; then echo "FAIL source check: $f declares rearmHang $n time(s), want 1"; bad=1; fi
  # Nothing else may bind the name: a shadowing rearmHang := ... or var rearmHang would bypass the declaration check.
  hits=$(grep -nE '(^|[^[:alnum:]_])rearmHang[[:space:]]*(:=|=[^=])|var[[:space:]]+rearmHang' "$f" | grep -v ':const rearmHang = ' || true)
  if [ -n "$hits" ]; then
    printf 'FAIL source check: rearmHang bound outside its const declaration:\n%s\n' "$hits"; bad=1
  fi
  [ "$bad" -eq 0 ] && echo "source check: ok"
  return "$bad"
}

check_deadlines "$TESTF" || exit 1
out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$MAIN" "$W/main.go.orig"
fails=0
# S1: the source check on a copy of the test file with one rearmHang deadline shortened to 20 s.
src=$(mktemp -p "$W") || exit 2
if python3 - "$TESTF" "$src" <<'PY'
import sys
s=open(sys.argv[1]).read()
old='logoffDone(t, uid, rearmHang)'
if old not in s: sys.exit(1)
open(sys.argv[2],'w').write(s.replace(old,'logoffDone(t, uid, 20*time.Second)',1))
PY
then
  if check_deadlines "$src" >/dev/null; then echo "  SURVIVED  S1 one rearmHang deadline shortened to 20*time.Second"; fails=$((fails+1))
  else echo "  convicted S1 one rearmHang deadline shortened to 20*time.Second"; fi
else echo "  INERT     S1 -- the mutation did not apply"; fails=$((fails+1)); fi
# S2-S4: the declaration weakened to 1 minute, by an expression, by a plain count, and by a shadowing rebind.
srcmut() { # srcmut <label> <old text> <new text>
  local m
  m=$(mktemp -p "$W") || exit 2
  if ! python3 - "$TESTF" "$m" "$2" "$3" <<'PY'
import sys
f,o,old,new=sys.argv[1:5]
s=open(f).read()
if old not in s: sys.exit(1)
open(o,'w').write(s.replace(old,new,1))
PY
  then echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; fi
  if check_deadlines "$m" >/dev/null; then echo "  SURVIVED  $1"; fails=$((fails+1))
  else echo "  convicted $1"; fi
}
srcmut "S2 const rearmHang = 2 / 2 * time.Minute" 'const rearmHang = 2 * time.Minute' 'const rearmHang = 2 / 2 * time.Minute'
srcmut "S3 const rearmHang = 1 * time.Minute" 'const rearmHang = 2 * time.Minute' 'const rearmHang = 1 * time.Minute'
srcmut "S4 rearmHang shadowed inside a test" $'\tlogoffDone(t, uid, rearmHang)' $'\trearmHang := rearmHang / 60\n\tlogoffDone(t, uid, rearmHang)'
mut() { # mut <label> <python-regex pattern> <replacement>
  python3 - "$MAIN" "$2" "$3" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *'--- FAIL'* ]]; then echo "  convicted $1"
  elif [[ "$res" == *'build failed'* ]]; then echo "  BROKEN    $1 -- did not compile"; fails=$((fails+1))
  else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  cp "$W/main.go.orig" "$MAIN"
}
CALL='\t\t\tlogoffStageInbox\("s3", name, pass, uid, seFromHex\(seSecret\)\)\n'
SAY='\t\t\t// NWP-20261019-04: [^\n]*\n'
REARM_F='(\t\t\trearmRoamSession\(dest, name, pass, uid, seSecret, "logout seal failed, re-arm"\)\n\t\t\tdropLogoffBTMarker\(dest\)[^\n]*\n)'
mut "M1 the call removed from the failed arm" "$REARM_F$SAY$CALL" '\1'
mut "M2 the call removed from the sweep arm" '(\t\t\trearmRoamSession\(dest, name, pass, uid, seSecret, "logout media sweep did not verify, re-arm"\)\n)'"$SAY$CALL" '\1'
mut "M3 the call removed from the stall arm" '(\t\t\trearmRoamSession\(dest, name, pass, uid, seSecret, "logout seal stalled, re-arm"\)[^\n]*\n)'"$SAY$CALL" '\1'
mut "M4 the call moved above the re-arm in the failed arm" "$REARM_F$SAY$CALL" '\t\t\tlogoffStageInbox("s3", name, pass, uid, seFromHex(seSecret))\n\1'
mut "M5 seFromSession(dest) instead of the captured secret" "$REARM_F$SAY"'(\t\t\tlogoffStageInbox\("s3", name, pass, uid, )seFromHex\(seSecret\)\)\n' '\1\2seFromSession(dest))\n'
mut "M6 nil instead of the captured secret" "$REARM_F$SAY"'\t\t\tlogoffStageInbox\("s3", name, pass, uid, seFromHex\(seSecret\)\)' '\1\t\t\tlogoffStageInbox("s3", name, pass, uid, nil)'
mut "M7 a call before recordSeal(out) in the superseded return" '(logoffVerdictSuperseded\(uid, logoffClaim, "seal", sealVerdictLog\(out\)\) \{\n)(\t\t\t\trecordSeal\(out\)\n)' '\1\t\t\t\tlogoffStageInbox("s3", name, pass, uid, seFromHex(seSecret))\n\2'
mut "M8 a call on the success path before reapOrReboot" '(\n)(\t\treapOrReboot\(uid\))' '\1\t\tlogoffStageInbox("s3", name, pass, uid, seFromHex(seSecret))\n\2'
mut "M9 a call in the late-verdict arm after its re-arm" '(\t\t\trearmRoamSession\(dest, name, pass, uid, seSecret, "late logout verdict after unstick, re-arm"\)[^\n]*\n)' '\1\t\t\tlogoffStageInbox("s3", name, pass, uid, seFromHex(seSecret))\n'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
