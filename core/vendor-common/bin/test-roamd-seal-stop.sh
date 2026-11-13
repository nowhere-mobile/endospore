#!/usr/bin/env bash
# test-roamd-seal-stop.sh [--mutate] -- NWP-20261117-01 (h47 #1 part 1): roamd's out op opts its pushes into the
# agent's stop point (NOWHERE_SEAL_STOPPABLE=1), and a push that exits 7 (exitSealStopped) ends the op: no further
# push, no media-sync hand-off, no claims kick, no #sys or #apps seal, and the verdict SKIP-STOPPED.
#
# The out arm, _cause and qn are extracted from nowhere_roamd.sh BY ANCHOR, never copied (a moved anchor stops the
# suite with EXTRACTION FAILED, exit 2). Every /data/ path in the arm points into a temp root. `$AGENT` is a stub
# script that records the profile it was asked to push and the NOWHERE_SEAL_STOPPABLE it saw, and exits a code
# chosen per profile; acct_seal, appcode_seal, am and bt_reset are stubs that record their call. Each case runs in
# a CHILD shell (bash, sh, and dash and mksh where present), never eval'd here, so a trap the arm sets cannot
# replace this suite's EXIT trap.
#
#   bash test-roamd-seal-stop.sh            # the cases under every shell found, and the source pin
#   bash test-roamd-seal-stop.sh --mutate   # ... plus S8-S10, each of which must be convicted under EACH shell
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; esac; done
HERE=$(cd "$(dirname "$0")" && pwd)
ROAMD="${ROAMD:-$HERE/nowhere_roamd.sh}"
[ ! -e /data/nowhere ] || { echo "refusing to run: /data/nowhere exists on this host" >&2; exit 2; }
[ -f "$ROAMD" ] || { echo "EXTRACTION FAILED: no such file: $ROAMD" >&2; exit 2; }
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

# --- extraction ------------------------------------------------------------------------------------------
CAUSE=$(awk '$0 == "_cause() {" {f=1} f{print} f&&/^\}$/{exit}' "$ROAMD")
case "$CAUSE" in '_cause() {'*'case "$1" in'*'esac'*'}') ;; *) echo "EXTRACTION FAILED: _cause -- anchors moved" >&2; exit 2 ;; esac
QN=$(awk '$0 == "qn() {" {f=1} f{print} f&&/^\}$/{exit}' "$ROAMD")
case "$QN" in 'qn() {'*'}') ;; *) echo "EXTRACTION FAILED: qn -- anchors moved" >&2; exit 2 ;; esac
# The whole out arm: from `  out)` through the first `    ;;` after it.
ARM=$(awk '$0 == "  out)" {f=1} f{print} f&&$0=="    ;;"{exit}' "$ROAMD")
case "$ARM" in '  out)'*'out start user'*'_push vault "$name" "$USERDIR"'*'appcode_seal'*'OK PARTIAL:$parts'*'    ;;') ;;
  *) echo "EXTRACTION FAILED: the out arm -- anchors moved" >&2; exit 2 ;; esac
ARM=$(printf '%s\n' "$ARM" | sed 's#/data/#$T/data/#g')
[ -z "$(printf '%s\n' "$ARM" | grep -v '^[[:space:]]*#' | grep -E '(^|[^T])/data/')" ] || { echo "EXTRACTION FAILED: a /data/ path escaped the rewrite" >&2; exit 2; }
PRINT_SHIM='command -v print >/dev/null 2>&1 || print() { _pn=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) _pn=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$_pn" = 1 ]; then printf "%s\n" "$*"; else printf "%s" "$*"; fi; }'

SHELLS=""
if [ -n "${SEALSTOP_SHELL:-}" ]; then SHELLS=" $SEALSTOP_SHELL"
else for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done; fi
[ -n "$SHELLS" ] || { echo "no shell to run under" >&2; exit 2; }

# --- harness ---------------------------------------------------------------------------------------------
# out_run <shell> <vault rc> <de rc> <media rc> <acct_seal rc> <appcode_seal rc> <skind> -> the case dir.
# The case dir holds res (the verdict), agent (one "<profile> <NOWHERE_SEAL_STOPPABLE>" line per push), calls (the
# stubbed helpers, one per call), log, and state/.btlogoff when it survived.
out_run(){
  local T
  T=$(mktemp -d -p "$W") || exit 2
  mkdir -p "$T/data/user_de/7" "$T/data/media/7" "$T/state" "$T/user/com.nowhere.chooser/files"
  : > "$T/calls"; : > "$T/agent"
  : > "$T/user/com.nowhere.chooser/files/nowhere-claims"   # the claims kick would run on a whole seal
  : > "$T/state/.btlogoff"
  cat > "$T/agent.sh" <<EOF
#!/bin/sh
echo "\$3 \${NOWHERE_SEAL_STOPPABLE:-unset}" >> "$T/agent"
case "\$3" in
  probe) exit $2 ;;
  'probe#de') exit $3 ;;
  'probe#media') [ -n "\${NOWHERE_MEDIA_SYNC_OUT:-}" ] && echo "/data/media/7/DCIM/a.jpg" > "\$NOWHERE_MEDIA_SYNC_OUT"; exit $4 ;;
esac
exit 0
EOF
  chmod +x "$T/agent.sh"
  {
    printf '%s\n%s\n%s\n' "$PRINT_SHIM" "$QN" "$CAUSE"
    printf 'T=%s; STATE=$T/state; LOG=$T/log; RES=$T/res; USERDIR=$T/user; name=probe; pass=x; uid=7; skind=%s\n' "$T" "$7"
    printf 'AGENT=$T/agent.sh\n'
    printf 'unset NOWHERE_SEAL_STOPPABLE\n'
    for f in bt_seal_capture nav_seal_capture aod_seal_capture a11y_seal_capture autofill_seal_capture shortcut_seal_capture tz_seal_capture \
             vpn_deferred_retry vpn_seal_capture sync_apply_retry sync_seal_capture sroam_seal_capture ks_stage_drop restorecon chown \
             seal_wl_release seal_susp seal_wl_end; do
      printf '%s(){ :; }\n' "$f"
    done
    printf 'pw(){ echo pw; }\n'
    printf '%s\n' 'od_fetch_data() { return 0; }; od_listed() { return 1; }; od_block_app() { return 0; }; od_unblock_app() { :; }; od_pending_clear() { :; }; od_block_installed() { :; }; od_shipped_prep() { return 0; }; od_park_var() { :; }; od_unf_path() { echo "$STATE/odfetch.$1/unfetched.$2"; }   # NWP-20261130-03'
    printf '_ms(){ echo 0; }\n'   # NWP-20261123-06: the seal split times each scope; dash and mksh abort on $(( - ))
    printf 'am(){ echo "am $1" >> "$T/calls"; }\n'
    printf 'bt_reset(){ echo bt_reset >> "$T/calls"; return 0; }\n'
    printf 'acct_seal(){ echo acct_seal >> "$T/calls"; return %s; }\n' "$5"
    printf 'appcode_seal(){ echo appcode_seal >> "$T/calls"; return %s; }\n' "$6"
    printf 'op=out\ncase "$op" in\n%s\nesac\n' "$ARM"
  } > "$T/run.sh"
  "$1" "$T/run.sh" >/dev/null 2>&1
  echo "$T"
}
lines(){ grep -c . "$1" 2>/dev/null || true; }
has(){ grep -qx "$2" "$1" 2>/dev/null; }

for s in $SHELLS; do
  echo "== $s =="
  # C1: the vault push stops -> nothing more runs, and the verdict is SKIP-STOPPED.
  T=$(out_run "$s" 7 0 0 0 0 periodic)
  res=$(cat "$T/res" 2>/dev/null)
  [ "$res" = SKIP-STOPPED ] && ok "$s: a vault push exiting 7 -> SKIP-STOPPED" || no "$s: a vault push exiting 7 -> [$res], want SKIP-STOPPED"
  n=$(lines "$T/agent")
  [ "$n" = 1 ] && ok "$s: the agent ran once (no #de or #media push after the stop)" || no "$s: the agent ran $n times after a stop on the vault push, want 1"
  if has "$T/calls" acct_seal || has "$T/calls" appcode_seal; then no "$s: acct_seal or appcode_seal ran after a stop: $(tr '\n' ' ' < "$T/calls")"
  else ok "$s: neither acct_seal nor appcode_seal ran after a stop"; fi
  log=$(cat "$T/log" 2>/dev/null)
  case "$log" in *'[roamd] OUT "probe" SKIP-STOPPED -- a sign-out asked this seal to stop; no head after the last whole scope'*) ok "$s: the log names SKIP-STOPPED" ;;
    *) no "$s: no SKIP-STOPPED line in the log" ;; esac

  # C2: control -- every push clean -> OK, three pushes, both helpers; C7: every push saw the opt-in.
  T=$(out_run "$s" 0 0 0 0 0 periodic)
  res=$(cat "$T/res" 2>/dev/null); n=$(lines "$T/agent")
  [ "$res" = OK ] && [ "$n" = 3 ] && has "$T/calls" acct_seal && has "$T/calls" appcode_seal \
    && ok "$s: control: every push clean -> OK, 3 pushes, both helpers ran" \
    || no "$s: control: every push clean -> [$res], $n pushes, calls: $(tr '\n' ' ' < "$T/calls")"
  n=$(grep -c '^am ' "$T/calls" || true)
  [ "$n" = 2 ] && ok "$s: control: a whole seal hands off the media-sync list and kicks the claims (am twice)" \
    || no "$s: control: a whole seal ran am $n times, want 2 (the media scan and the claims kick)"
  n=$(lines "$T/agent")
  bad=$(grep -cv ' 1$' "$T/agent" || true)
  [ "$n" -gt 0 ] && [ "$bad" = 0 ] && ok "$s: every push the out op ran saw NOWHERE_SEAL_STOPPABLE=1" \
    || no "$s: $bad of $n push(es) did not see NOWHERE_SEAL_STOPPABLE=1: $(tr '\n' ' ' < "$T/agent")"

  # C3: the #media push stops after writing its media-sync list -> no scan hand-off, no claims kick, no helper.
  T=$(out_run "$s" 0 0 7 0 0 periodic)
  res=$(cat "$T/res" 2>/dev/null)
  [ "$res" = SKIP-STOPPED ] && ok "$s: a #media push exiting 7 -> SKIP-STOPPED" || no "$s: a #media push exiting 7 -> [$res], want SKIP-STOPPED"
  if grep -q '^am ' "$T/calls"; then no "$s: am ran after a stop (media scan or claims kick): $(tr '\n' ' ' < "$T/calls")"
  else ok "$s: no media-sync hand-off and no claims kick after a stop"; fi
  if has "$T/calls" acct_seal || has "$T/calls" appcode_seal; then no "$s: a helper ran after a #media stop"
  else ok "$s: no helper ran after a #media stop"; fi

  # C4 / C5: a helper's own push stops.
  T=$(out_run "$s" 0 0 0 7 0 periodic)
  res=$(cat "$T/res" 2>/dev/null)
  [ "$res" = SKIP-STOPPED ] && ! has "$T/calls" appcode_seal && ok "$s: acct_seal returning 7 -> SKIP-STOPPED, appcode_seal not run" \
    || no "$s: acct_seal returning 7 -> [$res], calls: $(tr '\n' ' ' < "$T/calls")"
  T=$(out_run "$s" 0 0 0 0 7 periodic)
  res=$(cat "$T/res" 2>/dev/null)
  [ "$res" = SKIP-STOPPED ] && ok "$s: appcode_seal returning 7 -> SKIP-STOPPED" || no "$s: appcode_seal returning 7 -> [$res], want SKIP-STOPPED"

  # C6: a stopped logoff seal never clears Bluetooth and keeps the marker.
  T=$(out_run "$s" 7 0 0 0 0 logoff)
  if ! has "$T/calls" bt_reset && [ -f "$T/state/.btlogoff" ]; then ok "$s: a stopped logoff seal leaves Bluetooth and its marker alone"
  else no "$s: a stopped logoff seal ran bt_reset or dropped .btlogoff"; fi
  # Control for C6: the whole logoff seal does clear it.
  T=$(out_run "$s" 0 0 0 0 0 logoff)
  has "$T/calls" bt_reset && ok "$s: control: a whole logoff seal clears Bluetooth" || no "$s: control: a whole logoff seal did not run bt_reset"

  # C8: the vocabulary.
  printf '%s\n_cause 7\n' "$CAUSE" > "$W/cause.sh"
  got=$("$s" "$W/cause.sh" 2>&1)
  [ "$got" = stopped ] && ok "$s: _cause 7 -> stopped" || no "$s: _cause 7 -> [$got], want stopped"
done

# P1: the source pin. The export is in the out arm, after its `out start` line, above its first push, and nowhere
# else: not in keystore_push (cleanstorage's #keys push must never stop), nor in another daemon script.
if [ "${SEALSTOP_SKIP_PIN:-0}" != 1 ]; then
  echo "== source pin =="
  n=$(grep -c '^ *export NOWHERE_SEAL_STOPPABLE=1$' "$ROAMD" || true)
  [ "$n" = 1 ] && ok "the export occurs once in nowhere_roamd.sh" || no "the export occurs $n times in nowhere_roamd.sh, want 1"
  pos=$(printf '%s\n' "$ARM" | awk '
    /out start user/ && !s {s=NR}
    /^ *export NOWHERE_SEAL_STOPPABLE=1$/ && !e {e=NR}
    !/^[[:space:]]*#/ && (/_push [a-z]/ || /"\$AGENT" push/) && !/_push\(\)/ && !p {p=NR}
    END {print s+0, e+0, p+0}')
  set -- $pos
  if [ "$1" -gt 0 ] && [ "$2" -gt "$1" ] && [ "$3" -gt "$2" ]; then ok "the export sits after the out start line and above the arm's first push"
  else no "the export is not between the out start line and the first push (lines: start $1, export $2, first push $3)"; fi
  ks=$(awk '$0 == "keystore_push() {" {f=1} f{print} f&&/^\}$/{exit}' "$ROAMD")
  [ -n "$ks" ] || { echo "EXTRACTION FAILED: keystore_push -- anchors moved" >&2; exit 2; }
  case "$ks" in *NOWHERE_SEAL_STOPPABLE*) no "keystore_push names NOWHERE_SEAL_STOPPABLE" ;; *) ok "keystore_push never sees the opt-in" ;; esac
  for d in gate login mediad otad provision; do
    f="$HERE/nowhere_$d.sh"
    [ -f "$f" ] || { echo "EXTRACTION FAILED: no such file: $f" >&2; exit 2; }
    if grep -q NOWHERE_SEAL_STOPPABLE "$f"; then no "nowhere_$d.sh names NOWHERE_SEAL_STOPPABLE"; else ok "nowhere_$d.sh does not opt in"; fi
  done
fi

if [ "$MUTATE" = yes ]; then
  echo "mutations (each must be convicted under EACH shell -- exit 1, never an extraction failure):"
  # mut <label> <python re.sub pattern> <replacement>: one substitution, or the mutant fails as INERT.
  mut(){
    local label="$1" m="$W/roamd.mut.sh" s rc
    if ! python3 - "$ROAMD" "$m" "$2" "$3" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
out, n = re.subn(sys.argv[3], sys.argv[4], src, count=1, flags=re.M | re.S)
open(sys.argv[2], "w").write(out)
sys.exit(0 if n == 1 and out != src else 1)
PY
    then no "MUTANT DID NOT APPLY: $label"; return; fi
    for s in $SHELLS; do
      ROAMD="$m" SEALSTOP_SHELL="$s" SEALSTOP_SKIP_PIN=1 bash "$0" > "$W/mut.out" 2>&1; rc=$?
      case $rc in
        1) ok "convicted under $s: $label" ;;
        0) no "SURVIVED under $s: $label" ;;
        *) no "NOT CONVICTED under $s (rc $rc, extraction?): $label"; sed 's/^/      /' "$W/mut.out" | tail -3 ;;
      esac
    done
    rm -f "$m"
  }
  mut "S8 _push runs the next push after a 7" '^      \[ "\$stopped" = 1 \] && return 0[^\n]*\n' ''
  mut "S9 the verdict writes OK/ERR instead of SKIP-STOPPED" '^    if \[ "\$stopped" = 1 \]; then\n.*?\n    elif \[ "\$rc" = 0 \]; then$' '    if [ "$rc" = 0 ]; then'
  mut "S10 the export removed" '^    export NOWHERE_SEAL_STOPPABLE=1\n' ''
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
