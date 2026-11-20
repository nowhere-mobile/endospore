#!/usr/bin/env bash
# test-session-claims.sh [<nowhere_roamd.sh>] [--mutate] -- roamd's sessclaim op makes a session's three claims in ONE
# worker run (NWP-20261210-05), and the daemon asks for it once per session start.
#
# WHY THIS IS COMMITTED. Backlog row "A nearly empty profile takes about 85 s from submit to home; target under 60 s",
# cause (4): each sign-in, offline sign-in and resume started three RW worker runs (locapply, mdapply, dtclaim), and
# every run re-sources both confs and queues for the one RW slot. sessclaim runs the three single arms' claim bodies,
# once each and in the order loc, md (with dr), dt, and answers `<loc>;<md>;<dt>` in ONE redirect, because the daemon's
# poller returns at the first byte it reads. The single arms stay for the live switches and every release.
#
# The sessclaim arm is extracted BY ANCHOR (its begin/end block lines) and the locapply arm by its header line through
# the first `fi`, as a control. loc_claim, md_claim, dr_claim and dt_claim are STUBBED: each appends its name to a call
# log and sets the verdict global its real body sets. Each case runs in a CHILD of each shell found among bash, sh, dash
# and mksh (the device's /system/bin/sh), so the arm's own `exit 0` ends the run file, never the suite. A case whose run
# file never started is a HARNESS error (exit 2), never a FAIL. A missing anchor is a harness error too.
#
# --mutate also breaks the daemon's half (G1-G4, against copies of the Go files, restored on exit) and the arm (S1-S5,
# against a copy of roamd). Each mutant must be CONVICTED by the assertion it names: a Go mutant by a `--- FAIL` of that
# test (one that fails to apply or to compile is a failure), a shell mutant by that case's FAIL line under EVERY shell.
#
#   bash test-session-claims.sh            # the cases
#   bash test-session-claims.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
HERE=$(cd "$(dirname "$0")" && pwd)
SUT="${SUT:-$HERE/nowhere_roamd.sh}"
AGENT_DIR="$HERE/../../agent"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
# Every temp of the run lives inside W. The Go files a mutant edits are restored from W on exit.
W=$(mktemp -d) || exit 2
GOFILES=(main.go session_claims.go)
restore_go() { local g; for g in "${GOFILES[@]}"; do [ -f "$W/go.$g" ] && cp -f "$W/go.$g" "$AGENT_DIR/$g"; done; return 0; }
trap 'restore_go; rm -rf "$W"' EXIT

SHELLS=(); LABELS=(); seen=" "
for s in bash sh dash mksh; do
  p=$(command -v "$s" 2>/dev/null) || continue
  r=$(readlink -f "$p")
  case "$seen" in *" $r "*) continue ;; esac
  seen="$seen$r "; SHELLS+=("$p"); LABELS+=("$s")
done
[ "${#SHELLS[@]}" -gt 0 ] || { echo "no shell to run under" >&2; exit 2; }
case " ${LABELS[*]} " in *" mksh "*) ;; *) echo "note: no mksh on this host -- the device shell is not covered here" ;; esac

BEGIN_HDR='# ---- NWP-20261210-05: SESSION CLAIMS IN ONE RUN (begin) --------------------------------------------------------------'
END_HDR='# ---- NWP-20261210-05: SESSION CLAIMS IN ONE RUN (end) ----------------------------------------------------------------'
LOC_HDR='if [ "$op" = "locapply" ] || [ "$op" = "locrelease" ]; then'
PUBLISH='  printf '"'"'%s;%s;%s\n'"'"' "$_lv" "$_mv" "$_dv" > "$RES"; chmod 600 "$RES"; exit 0'
sq(){ printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# prep <roamd.sh>: extract the two arms into $R. 0, or 2 (the harness cannot run).
prep() {
  local f="$1" arm loc
  R=$(mktemp -d -p "$W") || return 2
  [ "$(grep -cxF "$BEGIN_HDR" "$f")" = 1 ] && [ "$(grep -cxF "$END_HDR" "$f")" = 1 ] \
    || { echo "EXTRACTION FAILED: the sessclaim block's begin/end anchors in $f" >&2; return 2; }
  [ "$(grep -cxF "$LOC_HDR" "$f")" = 1 ] || { echo "EXTRACTION FAILED: the locapply arm's header in $f" >&2; return 2; }
  arm=$(awk -v b="$BEGIN_HDR" -v e="$END_HDR" '$0 == b {on = 1} on {print} $0 == e {exit}' "$f")
  # Only the header and the three part claims are checked here, in no order: the order and dr_claim are cases (S1, S2).
  case "$arm" in *'if [ "$op" = "sessclaim" ]; then'*) ;;
    *) echo "EXTRACTION FAILED: the sessclaim arm's header" >&2; return 2 ;; esac
  case "$arm" in *'loc_claim '*) ;; *) echo "EXTRACTION FAILED: no loc_claim in the sessclaim arm" >&2; return 2 ;; esac
  case "$arm" in *'md_claim '*) ;; *) echo "EXTRACTION FAILED: no md_claim in the sessclaim arm" >&2; return 2 ;; esac
  case "$arm" in *'dt_claim '*) ;; *) echo "EXTRACTION FAILED: no dt_claim in the sessclaim arm" >&2; return 2 ;; esac
  loc=$(awk -v h="$LOC_HDR" '$0 == h {on = 1} on {print} on && $0 == "fi" {exit}' "$f")
  case "$loc" in *'loc_claim '*'echo "$LOC_VERDICT" > "$RES"'*) ;;
    *) echo "EXTRACTION FAILED: the locapply arm's body" >&2; return 2 ;; esac
  printf '%s\n' "$arm" > "$R/arm.sh"; printf '%s\n' "$loc" > "$R/loc.sh"
  bash -n "$R/arm.sh" && bash -n "$R/loc.sh" || { echo "EXTRACTION FAILED: an extracted arm does not parse" >&2; return 2; }
  cat > "$R/stubs.sh" <<'EOF'
_ms() { echo 1000; }
_tlog() { echo "TIMING $1 $2" >> "$T/tlog"; }
loc_claim() { echo loc >> "$T/calls"; echo "loc $1|$2|$3" >> "$T/args"; LOC_VERDICT="$V_LOC"; }
md_claim() { echo md >> "$T/calls"; echo "md $1|$2|$3" >> "$T/args"; MD_VERDICT="$V_MD"; }
dr_claim() { echo dr >> "$T/calls"; echo "dr $1|$2|$3" >> "$T/args"; DR_SEEN="$V_DR"; }
dt_claim() { echo dt >> "$T/calls"; echo "dt $1|$2" >> "$T/args"; DT_VERDICT="$V_DT"; }
EOF
}

# run <shell> <arm file> <op> <uid> <parts> [V_LOC V_MD V_DR V_DT] -> T names the case dir; 2 if the run never started
run() {
  local sh="$1" armf="$2"
  T=$(mktemp -d -p "$W") || exit 2
  {
    printf 'T=%s; RES=%s; LOG=%s; LOC_USER_ROOT=%s\n' "$(sq "$T")" "$(sq "$T/res")" "$(sq "$T/log")" "$(sq "$T/user")"
    printf 'op=%s; uid=%s; name=signin; srcunit=%s\n' "$(sq "$3")" "$(sq "$4")" "$(sq "$5")"
    printf 'V_LOC=%s; V_MD=%s; V_DR=%s; V_DT=%s\n' "$(sq "${6:-OK APPLIED}")" "$(sq "${7:-OK APPLIED mobile_data=1}")" \
      "$(sq "${8:-0}")" "$(sq "${9:-OK CLAIMED 4}")"
    printf '. %s\n' "$(sq "$R/stubs.sh")"
    printf 'echo ran > "$T/ran"\n'
    cat "$armf"
    printf 'echo FELL-THROUGH > "$RES"\n'
  } > "$T/run.sh"
  "$sh" "$T/run.sh" >/dev/null 2>&1
  [ -f "$T/ran" ] || return 2
}
calls() { [ -f "$T/calls" ] || return 0; tr '\n' ' ' < "$T/calls" | sed 's/ $//'; }
res() { cat "$T/res" 2>/dev/null; }
lines() { if [ -f "$T/res" ]; then wc -l < "$T/res" | tr -d ' '; else echo 0; fi; }
mode() { stat -c %a "$T/res" 2>/dev/null; }

# suite <roamd.sh> [quiet] -> 0 all ok, 1 a case failed, 2 the harness could not run
suite() {
  local f="$1" quiet="${2:-}" i sh lb p=0 x=0 u pl n want
  ok(){ p=$((p+1)); [ -n "$quiet" ] || printf '  ok    [%s] %s\n' "$lb" "$1"; }
  no(){ x=$((x+1)); printf '  FAIL  [%s] %s\n' "$lb" "$1"; }
  prep "$f" || return 2
  # S5's assertion is a property of the text: exactly one write to $RES past the guards, and it is the publish line.
  n=$(grep -v 'ERR-' "$R/arm.sh" | grep -c '>>* *"\$RES"')
  for i in "${!SHELLS[@]}"; do
    sh="${SHELLS[$i]}"; lb="${LABELS[$i]}"
    if [ "$n" = 1 ] && grep -qxF -- "$PUBLISH" "$R/arm.sh"; then ok "C7 one redirect publishes the reply"
    else no "C7 one redirect publishes the reply (found $n writes past the guards)"; fi

    run "$sh" "$R/arm.sh" sessclaim 12 loc,md,dt || { echo "HARNESS: the run file did not start under $lb" >&2; return 2; }
    want="OK APPLIED;OK APPLIED mobile_data=1 data_roaming=0;OK CLAIMED 4"
    if [ "$(calls)" = "loc md dr dt" ]; then ok "C1 loc,md,dt calls loc md dr dt once each, in order"
    else no "C1 loc,md,dt calls loc md dr dt once each, in order (got '$(calls)')"; fi
    if [ "$(res)" = "$want" ] && [ "$(lines)" = 1 ] && [ "$(mode)" = 600 ]; then ok "C1 one line, three fields, mode 600"
    else no "C1 one line, three fields, mode 600 (got '$(res)', $(lines) lines, mode $(mode))"; fi
    if [ "$(grep -c '' "$T/tlog" 2>/dev/null)" = 1 ] && grep -qx 'TIMING sessclaim 1000' "$T/tlog"; then
      ok "C1 one TIMING sessclaim line"
    else no "C1 one TIMING sessclaim line (got '$(cat "$T/tlog" 2>/dev/null)')"; fi
    pl="$T/user/12/com.nowhere.chooser/files/nowhere-prefs"
    if [ "$(cat "$T/args")" = "loc 12|$pl|signin"$'\n'"md 12|$pl|signin"$'\n'"dr 12|$pl|signin"$'\n'"dt 12|signin" ]; then
      ok "C1 each claim gets the single arm's arguments"
    else no "C1 each claim gets the single arm's arguments"; fi

    run "$sh" "$R/arm.sh" sessclaim 12 md "" "OK BASELINE" 1 || return 2
    if [ "$(calls)" = "md dr" ] && [ "$(res)" = "-;OK BASELINE data_roaming=1;-" ]; then
      ok "C2 md alone runs md and dr, the other fields -"
    else no "C2 md alone runs md and dr, the other fields - (calls '$(calls)', res '$(res)')"; fi

    for u in 9 010 0100 0x ''; do
      run "$sh" "$R/arm.sh" sessclaim "$u" loc,md,dt || return 2
      if [ "$(res)" = ERR-UID ] && [ -z "$(calls)" ]; then ok "C3 uid '$u' is ERR-UID and nothing runs"
      else no "C3 uid '$u' is ERR-UID and nothing runs (res '$(res)', calls '$(calls)')"; fi
    done

    for u in loc,xx md,loc loc,loc 'loc,' '' dt,md,loc; do
      run "$sh" "$R/arm.sh" sessclaim 12 "$u" || return 2
      if [ "$(res)" = ERR-ARGS ] && [ -z "$(calls)" ]; then ok "C4 parts '$u' is ERR-ARGS and nothing runs"
      else no "C4 parts '$u' is ERR-ARGS and nothing runs (res '$(res)', calls '$(calls)')"; fi
    done

    run "$sh" "$R/arm.sh" sessclaim 12 loc,md,dt "OK a;b" "FAILED(x)"$'\n'"y" 0 "OK;" || return 2
    if [ "$(res)" = "OK a,b;FAILED(x),y data_roaming=0;OK," ] && [ "$(lines)" = 1 ]; then
      ok "C5 a ; or a newline in a verdict comes back as ,"
    else no "C5 a ; or a newline in a verdict comes back as , (got '$(res)', $(lines) lines)"; fi

    run "$sh" "$R/loc.sh" locapply 12 "" "OK APPLIED network_location=2 geocoder=0" || return 2
    if [ "$(res)" = "OK APPLIED network_location=2 geocoder=0" ] && [ "$(calls)" = loc ]; then
      ok "C6 control: the single locapply arm answers as before"
    else no "C6 control: the single locapply arm answers as before (res '$(res)', calls '$(calls)')"; fi
  done
  [ -n "$quiet" ] || echo "  -- $p ok, $x failed"
  [ "$x" -eq 0 ]
}

echo "== sessclaim arm: $SUT"
suite "$SUT"; rc=$?
[ "$rc" -eq 2 ] && exit 2
[ "$rc" -eq 0 ] || { echo "FAILED"; exit 1; }
echo "== all cases passed"
[ "$MUTATE" = yes ] || exit 0

fails=0
# smut <label> <the case that must convict it> <python-regex> <replacement>: applied once, inside the sessclaim block
smut() {
  local label="$1" case_id="$2" m="$W/mut.sh" out rc lb
  python3 - "$SUT" "$m" "$BEGIN_HDR" "$END_HDR" "$3" "$4" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
import re, sys
src, dst, b, e, pat, rep = sys.argv[1:7]
s = open(src).read()
i = s.index(b + "\n"); j = s.index(e + "\n", i)
arm, c = re.subn(pat, rep, s[i:j], count=1, flags=re.S)
if c != 1 or arm == s[i:j]:
    sys.exit(1)
open(dst, "w").write(s[:i] + arm + s[j:])
PY
  out=$(suite "$m" quiet 2>&1); rc=$?
  if [ "$rc" -eq 2 ]; then echo "  BROKEN    $label -- the harness could not run it: $out"; fails=$((fails+1)); return; fi
  if [ "$case_id" = control ]; then
    if [ "$rc" -eq 0 ]; then echo "  survived  $label (as it must)"; else echo "  FAILED    $label -- a control was convicted:"; printf '%s\n' "$out"; fails=$((fails+1)); fi
    return
  fi
  for lb in "${LABELS[@]}"; do
    case "$out" in *"FAIL  [$lb] $case_id"*) ;;
      *) echo "  SURVIVED  $label under $lb (no FAIL of $case_id)"; printf '%s\n' "$out"; fails=$((fails+1)); return ;; esac
  done
  echo "  convicted $label (by $case_id under ${LABELS[*]})"
}
echo "== shell mutants (each must be convicted under every shell)"
smut "S1 dt runs before loc" "C1 loc,md,dt calls loc md dr dt once each, in order" \
  '(  case ",\$srcunit," in \*,loc,\*\)\n.*?  esac\n)(.*?)(  case ",\$srcunit," in \*,dt,\*\)\n.*?  esac\n)' '\3\1\2'
smut "S2 dr_claim dropped" "C2 md alone runs md and dr" '    dr_claim [^\n]*\n' ''
smut "S3 the uid guard removed" "C3 uid" '  case "\$uid" in [^\n]*\n  \[ "\$uid" -ge 10 \][^\n]*\n' ''
smut "S4 the part-list check removed" "C4 parts" '  case "\$srcunit" in\n.*?  esac\n' ''
S5_PAT=$(cat <<'EOF'
  printf '%s;%s;%s\\n' "\$_lv" "\$_mv" "\$_dv" > "\$RES"; chmod
EOF
)
S5_REP=$(cat <<'EOF'
  printf '%s;' "$_lv" > "$RES"; printf '%s;%s\\n' "$_mv" "$_dv" >> "$RES"; chmod
EOF
)
smut "S5 the reply in two redirects" "C7 one redirect publishes the reply" "$S5_PAT" "$S5_REP"
smut "control: a comment edit" control '# The single arms stay for the live' '# The single arms remain for the live'

# The daemon's half. Each runs only the test that must convict it.
. "$AGENT_DIR/suite-report.sh"
gmut() { # gmut <label> <test> <file> <python-regex> <replacement> [control]
  local label="$1" test="$2" file="$3" o r
  [ -f "$W/go.$file" ] || cp "$AGENT_DIR/$file" "$W/go.$file"
  python3 - "$AGENT_DIR/$file" "$4" "$5" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); restore_go; return; }
import re, sys
p, pat, rep = sys.argv[1:4]
s = open(p).read()
n, c = re.subn(pat, rep, s, count=1, flags=re.S)
if c != 1 or n == s:
    sys.exit(1)
open(p, "w").write(n)
PY
  o=$(cd "$AGENT_DIR" && go test -count=1 -run "^$test\$" . 2>&1); r=$?
  if [ "${6:-}" = control ]; then
    if [ "$r" -eq 0 ] && [[ "$o" == *$'\n'ok* || "$o" == ok* ]]; then echo "  survived  $label (as it must)"
    else echo "  FAILED    $label -- a control was convicted (rc=$r)"; tail -n 15 <<<"$o"; fails=$((fails+1)); fi
  elif [[ "$o" == *"--- FAIL: $test "* ]]; then score_mutant "$label (by $test)" "$r" "$o" || fails=$((fails+1))
  else echo "  SURVIVED  $label (no --- FAIL of $test, rc=$r)"; tail -n 15 <<<"$o"; fails=$((fails+1)); fi
  restore_go
}
echo "== Go mutants (each must be convicted by the test it names)"
command -v go >/dev/null 2>&1 || { echo "no go on this host -- the Go mutants cannot run" >&2; exit 2; }
gmut "G1 runWorkerHeld does not refuse sessclaim" TestSessionClaimDroppedUnderTheSlot main.go \
  'op == "dtclaim" \|\| op == "sessclaim"' 'op == "dtclaim"'
gmut "G2 the sign-in keeps the old mobile-data claim" TestSessionClaimOneRunPerSignIn main.go \
  '(\t\tclaimSessionGlobalsAsync\(dest, uid, "signin"\)\n)' '\1\t\tclaimMobileData(dest, uid, "signin")\n'
gmut "G3 the md part ignores mobileDataSupported" TestSessionClaimPartsFollowSupport session_claims.go \
  'if mobileDataSupported\(\) \{' 'if true {'
gmut "G4 the md field index off by one" TestSessionClaimLogsEachNonOK session_claims.go \
  'HasPrefix\(f\[1\], "OK"\)(.*?)locReplyToken\(f\[1\]\)' 'HasPrefix(f[2], "OK")\1locReplyToken(f[2])'
gmut "control: a comment edit" TestSessionClaimOneRunPerSignIn session_claims.go \
  '// sessionClaimParts is the part list' '// sessionClaimParts is the parts list' control
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
