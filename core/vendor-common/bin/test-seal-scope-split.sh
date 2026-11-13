#!/usr/bin/env bash
# test-seal-scope-split.sh [--mutate] -- NWP-20261123-06: roamd's out op writes $STATE/seal-split, each scope's wall
# time and upload KiB, before every RES write, so the daemon's periodic seal line in login.log can say where a long
# save spent its time (push_stat.go: takeSealSplit, sealSplitSuffixFor).
#
# The out arm, _cause and qn are extracted from nowhere_roamd.sh BY ANCHOR, never copied (a moved anchor stops the
# suite with EXTRACTION FAILED, exit 2). Every /data/ path in the arm points into a temp root. `$AGENT` is a stub
# that records the profile and the NOWHERE_PUSH_STAT it saw and, when that is set, writes a stat line with a KiB
# figure chosen per profile; acct_seal and appcode_seal are stubs that do what their real pushes do with the stat
# file (the source pin below checks the real #apps line). _ms is a constant, so every wall time reads 0. Each case
# runs in a CHILD shell (bash, sh, and dash and mksh where present).
#
#   bash test-seal-scope-split.sh            # the cases under every shell found, and the source pin
#   bash test-seal-scope-split.sh --mutate   # ... plus M1-M3, M8-M9 (each convicted under EACH shell) and M4-M7, M10
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; esac; done
HERE=$(cd "$(dirname "$0")" && pwd)
ROAMD="${ROAMD:-$HERE/nowhere_roamd.sh}"
AGENT_DIR=$(cd "$HERE/../../agent" 2>/dev/null && pwd)
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
case "$ARM" in '  out)'*'_split() {'*'_pstat() {'*'_ssplit() {'*'_push vault "$name" "$USERDIR"'*'acct_seal "$uid"; _sr=$?'*'appcode_seal; _ar=$?'*'OK PARTIAL:$parts'*'    ;;') ;;
  *) echo "EXTRACTION FAILED: the out arm -- anchors moved" >&2; exit 2 ;; esac
ARM=$(printf '%s\n' "$ARM" | sed 's#/data/#$T/data/#g')
[ -z "$(printf '%s\n' "$ARM" | grep -v '^[[:space:]]*#' | grep -E '(^|[^T])/data/')" ] || { echo "EXTRACTION FAILED: a /data/ path escaped the rewrite" >&2; exit 2; }
# S8's probe: at each RES write, record whether the seal split was already there.
ARM=$(printf '%s\n' "$ARM" | sed 's#> "\$RES"$#> "$RES"; [ -f "$STATE/seal-split" ] || echo RES-BEFORE-SPLIT >> "$T/order"#')
n=$(printf '%s\n' "$ARM" | grep -c 'RES-BEFORE-SPLIT' || true)
[ "$n" = 6 ] || { echo "EXTRACTION FAILED: $n RES writes in the out arm, want 6" >&2; exit 2; }
PRINT_SHIM='command -v print >/dev/null 2>&1 || print() { _pn=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) _pn=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$_pn" = 1 ]; then printf "%s\n" "$*"; else printf "%s" "$*"; fi; }'

SHELLS=""
if [ -n "${SEALSPLIT_SHELL:-}" ]; then SHELLS=" $SEALSPLIT_SHELL"
else for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done; fi
[ -n "$SHELLS" ] || { echo "no shell to run under" >&2; exit 2; }

# --- harness ---------------------------------------------------------------------------------------------
# out_run <shell> <vault rc> <de kib|none> <media kib> [tick] -> the case dir. With tick, _ms advances 100 per call
# (a file counter: $(_ms) runs in a subshell) and appcode_seal's push ladder reads 40ms. The case dir holds res (the verdict),
# state/seal-split, agent (one "<profile> <NOWHERE_PUSH_STAT>" line per push), calls, order and log.
out_run(){
  local T
  T=$(mktemp -d -p "$W") || exit 2
  mkdir -p "$T/data/user_de/7" "$T/data/media/7" "$T/state" "$T/user/com.nowhere.chooser/files"
  : > "$T/calls"; : > "$T/agent"; : > "$T/order"
  cat > "$T/agent.sh" <<EOF
#!/bin/sh
echo "\$3 \${NOWHERE_PUSH_STAT:-unset}" >> "$T/agent"
case "\$3" in
  probe) k=11; r=$2 ;;
  'probe#de') k=$3; r=0 ;;
  'probe#media') k=$4; r=0 ;;
  *) k=99; r=0 ;;
esac
[ -n "\${NOWHERE_PUSH_STAT:-}" ] && [ "\$k" != none ] && echo "kib=\$k up=1 local=2" > "\$NOWHERE_PUSH_STAT"
exit \$r
EOF
  chmod +x "$T/agent.sh"
  {
    printf '%s\n%s\n%s\n' "$PRINT_SHIM" "$QN" "$CAUSE"
    printf 'T=%s; STATE=$T/state; LOG=$T/log; RES=$T/res; USERDIR=$T/user; name=probe; pass=x; uid=7; skind=periodic\n' "$T"
    printf 'AGENT=$T/agent.sh\n'
    printf 'unset NOWHERE_PUSH_STAT APPCODE_PUSH_MS\n'
    for f in bt_seal_capture nav_seal_capture aod_seal_capture a11y_seal_capture autofill_seal_capture tz_seal_capture \
             vpn_deferred_retry vpn_seal_capture sync_apply_retry sync_seal_capture sroam_seal_capture ks_stage_drop restorecon chown \
             seal_wl_release seal_susp seal_wl_end bt_reset am; do
      printf '%s(){ :; }\n' "$f"
    done
    printf 'pw(){ echo pw; }\n'
    printf 'od_unf_path(){ echo "$STATE/odfetch.$1/unfetched.$2"; }\n'   # NWP-20261130-03
    if [ "${5:-}" = tick ]; then
      printf '_ms(){ local _n; _n=$(cat "$T/clock" 2>/dev/null || echo 0); _n=$((_n + 100)); echo "$_n" > "$T/clock"; echo "$_n"; }\n'
      printf 'APM=40\n'
    else
      printf '_ms(){ echo 1000; }\n'
      printf 'APM=0\n'
    fi
    # acct_seal's one push reads NOWHERE_PUSH_STAT from the environment, as the real one does.
    # SYSM / APPSM (default push): push = the helper pushes and its push writes a stat file; nostat = it pushes but
    # leaves no stat file; skip = it returns before its push, as the real ones do with nothing to seal (S11-S12).
    printf 'SYSM=%s; APPSM=%s\n' "${SYSM:-push}" "${APPSM:-push}"
    printf 'acct_seal(){ echo "acct_seal ${NOWHERE_PUSH_STAT:-unset}" >> "$T/calls"; [ "$SYSM" = skip ] && return 0; ACCT_PUSHED=1; [ "$SYSM" = push ] && [ -n "${NOWHERE_PUSH_STAT:-}" ] && echo "kib=44 up=1 local=2" > "$NOWHERE_PUSH_STAT"; return 0; }\n'
    printf 'appcode_seal(){ echo "appcode_seal ${NOWHERE_PUSH_STAT:-unset}" >> "$T/calls"; [ "$APPSM" = skip ] && return 0; [ "$APPSM" = push ] && echo "kib=55 up=1 local=2" > "$STATE/pushstat.apps"; APPCODE_PUSH_MS=$APM; return 0; }\n'
    printf 'op=out\ncase "$op" in\n%s\nesac\n' "$ARM"
  } > "$T/run.sh"
  "$1" "$T/run.sh" >/dev/null 2>&1
  echo "$T"
}
split_of(){ cat "$1/state/seal-split" 2>/dev/null; }
res_of(){ cat "$1/res" 2>/dev/null; }

ALL='vault=0ms/11KiB,de=0ms/22KiB,media=0ms/33KiB,sys=0ms/44KiB,apps=stage 0ms+push 0ms/55KiB'
for s in $SHELLS; do
  echo "== $s =="
  # S1: every scope clean -> every scope in order, the KiB from each push's stat file; S7: RES is OK.
  T=$(out_run "$s" 0 22 33)
  got=$(split_of "$T")
  [ "$got" = "$ALL" ] && ok "$s: S1 seal-split holds vault, de, media, sys, apps in order with each push's KiB" \
    || no "$s: S1 seal-split = [$got], want [$ALL]"
  got=$(res_of "$T")
  [ "$got" = OK ] && ok "$s: S7 RES is OK, as before" || no "$s: S7 RES = [$got], want OK"
  # S2: nothing left behind in $STATE but the split itself.
  left=$(cd "$T/state" && ls -A | grep -v '^seal-split$' | tr '\n' ' ')
  [ -z "$left" ] && ok "$s: S2 no pushstat.* or seal-split.tmp left in \$STATE" || no "$s: S2 left in \$STATE: $left"
  bad=$(grep -v -e '^probe .*/state/pushstat\.vault$' -e '^probe#de .*/state/pushstat\.de$' -e '^probe#media .*/state/pushstat\.media$' "$T/agent" | tr '\n' ' ')
  [ -z "$bad" ] && ok "$s: S1 each _push names its own pushstat.<label>" || no "$s: S1 pushes without their own stat path: $bad"
  got=$(grep '^appcode_seal ' "$T/calls")
  [ "$got" = "appcode_seal unset" ] && ok "$s: S1 NOWHERE_PUSH_STAT is unset again after acct_seal" \
    || no "$s: S1 appcode_seal saw [$got], want NOWHERE_PUSH_STAT unset"

  # S3: a push that leaves no stat file reads ?KiB, the other scopes unchanged.
  T=$(out_run "$s" 0 none 33)
  got=$(split_of "$T")
  want='vault=0ms/11KiB,de=0ms/?KiB,media=0ms/33KiB,sys=0ms/44KiB,apps=stage 0ms+push 0ms/55KiB'
  [ "$got" = "$want" ] && ok "$s: S3 a push with no stat file reads de=0ms/?KiB" || no "$s: S3 seal-split = [$got], want [$want]"

  # S9 (NOWHERE-1442): a no-change #media push writes kib=0 -> media=<ms>ms/0KiB, never /?KiB.
  T=$(out_run "$s" 0 22 0)
  got=$(split_of "$T")
  case "$got" in *',media=0ms/0KiB,'*) ok "$s: S9 a no-change #media push reads media=0ms/0KiB" ;;
    *) no "$s: S9 seal-split = [$got], want media=0ms/0KiB" ;; esac

  # S4: the vault push stops -> SKIP-STOPPED, the later scopes absent; S8 for that branch.
  T=$(out_run "$s" 7 22 33)
  got=$(split_of "$T"); r=$(res_of "$T")
  [ "$got" = 'vault=0ms/11KiB' ] && ok "$s: S4 a stopped seal's split holds only the vault" || no "$s: S4 seal-split = [$got], want [vault=0ms/11KiB]"
  [ "$r" = SKIP-STOPPED ] && ok "$s: S7 RES is SKIP-STOPPED, as before" || no "$s: S7 RES = [$r], want SKIP-STOPPED"
  [ ! -s "$T/order" ] && [ -f "$T/state/seal-split" ] && ok "$s: S8 SKIP-STOPPED: the split was written before RES" \
    || no "$s: S8 SKIP-STOPPED: RES written before the split"

  # S5 / S6: a refused or an out-of-credit vault push -> the same verdicts, the split still written.
  T=$(out_run "$s" 4 22 33)
  got=$(split_of "$T"); r=$(res_of "$T")
  [ "$r" = 'ERR-REFUSED PARTIAL:vault=refused' ] && ok "$s: S5 RES is ERR-REFUSED PARTIAL:vault=refused, as before" \
    || no "$s: S5 RES = [$r], want ERR-REFUSED PARTIAL:vault=refused"
  [ "$got" = "$ALL" ] && ok "$s: S5 a refused seal still writes the split" || no "$s: S5 seal-split = [$got], want [$ALL]"
  [ ! -s "$T/order" ] && ok "$s: S8 ERR-REFUSED: the split was written before RES" || no "$s: S8 ERR-REFUSED: RES written before the split"
  T=$(out_run "$s" 3 22 33)
  got=$(split_of "$T"); r=$(res_of "$T")
  [ "$r" = 'ERR-NOCREDIT PARTIAL:vault=nocredit' ] && ok "$s: S6 RES is ERR-NOCREDIT PARTIAL:vault=nocredit, as before" \
    || no "$s: S6 RES = [$r], want ERR-NOCREDIT PARTIAL:vault=nocredit"
  [ "$got" = "$ALL" ] && ok "$s: S6 an out-of-credit seal still writes the split" || no "$s: S6 seal-split = [$got], want [$ALL]"

  # S10: the wall times are each scope's own (_ms after - before), and #apps splits into its staging and its push.
  T=$(out_run "$s" 0 22 33 tick)
  got=$(split_of "$T")
  want='vault=100ms/11KiB,de=100ms/22KiB,media=100ms/33KiB,sys=100ms/44KiB,apps=stage 60ms+push 40ms/55KiB'
  [ "$got" = "$want" ] && ok "$s: S10 each scope's wall time, and #apps as stage + push" || no "$s: S10 seal-split = [$got], want [$want]"

  # S11: a helper that returns before its push leaves its scope ABSENT, never sys=<ms>ms/?KiB; RES is unchanged.
  T=$(SYSM=skip out_run "$s" 0 22 33)
  got=$(split_of "$T"); r=$(res_of "$T")
  want='vault=0ms/11KiB,de=0ms/22KiB,media=0ms/33KiB,apps=stage 0ms+push 0ms/55KiB'
  [ "$got" = "$want" ] && ok "$s: S11 acct_seal returning before its push leaves sys absent" || no "$s: S11 seal-split = [$got], want [$want]"
  [ "$r" = OK ] && ok "$s: S11 RES is OK, as before" || no "$s: S11 RES = [$r], want OK"
  T=$(APPSM=skip out_run "$s" 0 22 33)
  got=$(split_of "$T")
  want='vault=0ms/11KiB,de=0ms/22KiB,media=0ms/33KiB,sys=0ms/44KiB'
  [ "$got" = "$want" ] && ok "$s: S11 appcode_seal returning before its push leaves apps absent" || no "$s: S11 seal-split = [$got], want [$want]"
  T=$(SYSM=skip APPSM=skip out_run "$s" 0 22 33)
  got=$(split_of "$T")
  [ "$got" = 'vault=0ms/11KiB,de=0ms/22KiB,media=0ms/33KiB' ] && ok "$s: S11 both helpers skipped: only vault, de, media" \
    || no "$s: S11 seal-split = [$got], want [vault=0ms/11KiB,de=0ms/22KiB,media=0ms/33KiB]"
  # S12: a helper that pushed but left no stat file keeps its entry, read as ?KiB.
  T=$(SYSM=nostat APPSM=nostat out_run "$s" 0 22 33)
  got=$(split_of "$T")
  want='vault=0ms/11KiB,de=0ms/22KiB,media=0ms/33KiB,sys=0ms/?KiB,apps=stage 0ms+push 0ms/?KiB'
  [ "$got" = "$want" ] && ok "$s: S12 a sys or apps push with no stat file reads /?KiB" || no "$s: S12 seal-split = [$got], want [$want]"

  # S8 for the OK branch.
  T=$(out_run "$s" 0 22 33)
  [ ! -s "$T/order" ] && [ -f "$T/state/seal-split" ] && ok "$s: S8 OK: the split was written before RES" \
    || no "$s: S8 OK: RES written before the split"
done

# P1: the source pin on the real appcode_seal: its #apps push names pushstat.apps, and the ladder is timed.
if [ "${SEALSPLIT_SKIP_PIN:-0}" != 1 ]; then
  echo "== source pin =="
  # P2: the real acct_seal sets ACCT_PUSHED on the line just above its #sys push (two lines: the env prefix, the push).
  AS=$(awk '$0 == "acct_seal() {" {f=1} f{print} f&&/^\}$/{exit}' "$ROAMD")
  case "$AS" in 'acct_seal() {'*'"${name}#sys"'*'}') ;; *) echo "EXTRACTION FAILED: acct_seal -- anchors moved" >&2; exit 2 ;; esac
  pos=$(printf '%s\n' "$AS" | awk '/^  ACCT_PUSHED=1( |$)/ {a=NR} /"\$AGENT" push s3 "\$\{name\}#sys"/ {p=NR} END {print a+0, p+0}')
  set -- $pos
  if [ "$1" -gt 0 ] && [ "$2" = $(( $1 + 2 )) ]; then ok "acct_seal sets ACCT_PUSHED just before its #sys push"
  else no "acct_seal does not set ACCT_PUSHED just before its #sys push (lines: set $1, push $2)"; fi
  AC=$(awk '$0 == "appcode_seal() {" {f=1} f{print} f&&/^\}$/{exit}' "$ROAMD")
  case "$AC" in 'appcode_seal() {'*'"${name}#apps"'*'}') ;; *) echo "EXTRACTION FAILED: appcode_seal -- anchors moved" >&2; exit 2 ;; esac
  pos=$(printf '%s\n' "$AC" | awk '
    /^  _apt0=\$\(_ms\)/ && !t {t=NR}
    /^  for lim in / && !l {l=NR}
    /^      NOWHERE_PUSH_STAT="\$STATE\/pushstat\.apps" \\$/ {e=NR}
    /"\$AGENT" push s3 "\$\{name\}#apps"/ {p=NR}
    /^  done$/ && l && !d {d=NR}
    /^  APPCODE_PUSH_MS=\$\(\( \$\(_ms\) - _apt0 \)\)/ {m=NR}
    END {print t+0, l+0, e+0, p+0, d+0, m+0}')
  set -- $pos
  if [ "$3" -gt 0 ] && [ "$4" = $(( $3 + 1 )) ]; then ok "the #apps push carries NOWHERE_PUSH_STAT=\"\$STATE/pushstat.apps\""
  else no "the #apps push does not carry NOWHERE_PUSH_STAT=\"\$STATE/pushstat.apps\" (lines: stat $3, push $4)"; fi
  if [ "$1" -gt 0 ] && [ "$2" -gt "$1" ] && [ "$5" -gt "$4" ] && [ "$6" = $(( $5 + 1 )) ]; then ok "the push ladder is timed into APPCODE_PUSH_MS"
  else no "the push ladder is not timed into APPCODE_PUSH_MS (lines: t0 $1, for $2, done $5, set $6)"; fi
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
    then no "MUTANT DID NOT APPLY: $label"; rm -f "$m"; return; fi
    for s in $SHELLS; do
      ROAMD="$m" SEALSPLIT_SHELL="$s" SEALSPLIT_SKIP_PIN=1 bash "$0" > "$W/mut.out" 2>&1; rc=$?
      case $rc in
        1) ok "convicted under $s: $label" ;;
        0) no "SURVIVED under $s: $label" ;;
        *) no "NOT CONVICTED under $s (rc $rc, extraction?): $label"; sed 's/^/      /' "$W/mut.out" | tail -3 ;;
      esac
    done
    rm -f "$m"
  }
  mut "M1 _push's agent call without NOWHERE_PUSH_STAT" '^        NOWHERE_PUSH_STAT="\$STATE/pushstat\.\$1" \\\n' ''
  mut "M2 the OK branch writes the split after RES" '^( +)_ssplit\n( +echo "OK" > "\$RES"\n)' '\2\1_ssplit\n'
  mut "M3 _pstat does not remove the stat file" '^      rm -f "\$1"\n      echo "\$_k"\n' '      echo "$_k"\n'
  mut "M8 the sys entry is written whether or not acct_seal pushed" '^      \[ -z "\$ACCT_PUSHED" \] \|\| _split ' '      _split '
  mut "M9 the apps entry is written whether or not appcode_seal pushed" '^      if \[ -n "\$_tp" \]; then$' '      if :; then'
  # M7: the pin, on the source copy (SEALSPLIT_SKIP_PIN unset).
  m="$W/roamd.mut.sh"
  if python3 - "$ROAMD" "$m" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
out, n = re.subn(r'^      NOWHERE_PUSH_STAT="\$STATE/pushstat\.apps" \\\n', '', src, count=1, flags=re.M)
open(sys.argv[2], "w").write(out)
sys.exit(0 if n == 1 and out != src else 1)
PY
  then
    ROAMD="$m" SEALSPLIT_SHELL=bash bash "$0" > "$W/mut.out" 2>&1; rc=$?
    case $rc in 1) ok "convicted: M7 the #apps push without NOWHERE_PUSH_STAT" ;; 0) no "SURVIVED: M7 the #apps push without NOWHERE_PUSH_STAT" ;;
      *) no "NOT CONVICTED (rc $rc): M7 the #apps push without NOWHERE_PUSH_STAT" ;; esac
  else no "MUTANT DID NOT APPLY: M7 the #apps push without NOWHERE_PUSH_STAT"; fi
  rm -f "$m"
  # M10: the P2 pin, on the source copy: acct_seal without ACCT_PUSHED=1 would leave every sys entry absent.
  if python3 - "$ROAMD" "$m" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
out, n = re.subn(r'^  ACCT_PUSHED=1 [^\n]*\n', '', src, count=1, flags=re.M)
open(sys.argv[2], "w").write(out)
sys.exit(0 if n == 1 and out != src else 1)
PY
  then
    ROAMD="$m" SEALSPLIT_SHELL=bash bash "$0" > "$W/mut.out" 2>&1; rc=$?
    case $rc in 1) ok "convicted: M10 acct_seal without ACCT_PUSHED=1" ;; 0) no "SURVIVED: M10 acct_seal without ACCT_PUSHED=1" ;;
      *) no "NOT CONVICTED (rc $rc): M10 acct_seal without ACCT_PUSHED=1" ;; esac
  else no "MUTANT DID NOT APPLY: M10 acct_seal without ACCT_PUSHED=1"; fi
  rm -f "$m"

  # Go side: one copy of core/agent; each mutant restores its file from the source first. Only `--- FAIL` convicts:
  # a mutant that does not compile proves nothing, so it fails the run.
  if [ -z "$AGENT_DIR" ] || ! command -v go >/dev/null 2>&1; then
    no "SKIPPED Go mutants M4-M6: no go toolchain or core/agent here"
  else
    g=$(mktemp -d -p "$W") && gt=$(mktemp -d -p "$W") || exit 2
    cp -r "$AGENT_DIR"/. "$g"/
    gomut(){ # <label> <file> <python re.sub pattern> <replacement>
      local label="$1" file="$2" out
      cp "$AGENT_DIR/$file" "$g/$file"
      if ! python3 - "$AGENT_DIR/$file" "$g/$file" "$3" "$4" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
out, n = re.subn(sys.argv[3], sys.argv[4], src, count=1, flags=re.M)
open(sys.argv[2], "w").write(out)
sys.exit(0 if n == 1 and out != src else 1)
PY
      then no "MUTANT DID NOT APPLY: $label"; cp "$AGENT_DIR/$file" "$g/$file"; return; fi
      # -trimpath: $g is a new path every run, and without it each run would add GOCACHE entries never hit again.
      out=$(cd "$g" && TMPDIR="$gt" GOTOOLCHAIN=auto go test -trimpath -count=1 -run 'SealSplit' . 2>&1)
      case "$out" in
        *'--- FAIL'*) ok "convicted: $label" ;;
        ok*) no "SURVIVED: $label" ;;
        *) no "DID NOT RUN (compile or setup failure): $label"; printf '%s\n' "$out" | head -n 10 | sed 's/^/      /' ;;
      esac
      cp "$AGENT_DIR/$file" "$g/$file"
    }
    gomut "M4 the daemon does not remove seal-split" push_stat.go '^\tos\.Remove\(filepath\.Join\(dest, sealSplitFile\)\)\n' ''
    gomut "M5 the split prints beside any verdict" push_stat.go \
      '^\tif split == "" \|\| !sealSplitVerdicts\[sealVerb\(out\)\] \{$' '	if split == "" {'
    gomut "M6 syncLoop does not discard an earlier run's split" main.go '^\t\ttakeSealSplit\(dest\)\n' ''
  fi
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
