#!/usr/bin/env bash
# test-netpolicy-release.sh [<nowhere_roamd.sh>] [--mutate] -- roamd's NETPOLICY WI-FI TEMPLATE RESET (NWP-20261210-19),
# run for real against a stubbed `am` (the gate's NetPolicyReceiver) under every shell the runner has, rather than grepped.
#
# WHY THIS IS COMMITTED. netpolicy.xml is device-wide and outside every user, so a Wi-Fi data warning or limit a session
# set there outlives it. Decided 2026-11-14 (docs/product-decisions.md, "five answers to harvest 65", item G06): the gate
# resets netpolicy's Wi-Fi templates through the platform; the owner's mobile limits and per-uid background policy stay.
# roamd asks once per boot (bootsweep fix 15b) and, decided 2026-11-18 ("four answers to harvest 70", item 3), at a reap
# with no other live session. Every way this goes wrong is silent: a malformed or timed-out reply read as a reset logs a removal that
# never happened; an unbounded am hangs the boot sweep; a token appended to _swept changes the sweep's result line; a raw
# reply or reason in the log can carry a name; an unguarded reap clears a parked session's Wi-Fi limit.
# What this pins:
#   C0  the block exists once, between the hotspot block's end and the mobile-data block's begin;
#   C1-C5  the verdict: reset(<n>) | none | failed(<closed reason>) | failed(noreply) for everything else;
#   C6  the broadcast: ONE per call, --user 0, the explicit component and action, no extras, under timeout -k 2 15;
#   C7  ONE log line of fixed tokens and digits that LOG_SCRUB_SED leaves byte-identical;
#   C8  fix 15b: one `np_release boot`, inside the bootsweep op, after fix 15's _swept line and before fix 16; _swept unchanged;
#   C9  roamd never names netpolicy.xml or WifiConfigStore.xml in live code but fix 18's report-only listing;
#   C10 the reap: one guarded call in cleanstorage, right after hs_release and before stop_mediad;
#   C11 the guard: another live (or damaged) marker sends nothing; a missing or own marker asks once.
# `am`, `timeout` and `date` are executable stubs on PATH.
#
# The pieces are extracted from nowhere_roamd.sh BY ANCHOR, never copied; if a fixed anchor moves, extraction fails loudly
# (exit 2) rather than a stale copy passing. The NP block itself is NOT a fixed anchor: its absence is C0's FAIL, so every
# case runs (and fails) against a roamd without it.
#
#   bash test-netpolicy-release.sh            # the behaviour cases, under bash, sh, dash and mksh where present
#   bash test-netpolicy-release.sh --mutate   # ... plus broken copies that must each be CONVICTED, under each shell
set -uo pipefail

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
HERE=$(cd "$(dirname "$0")" && pwd)
SUT="${SUT:-$HERE/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

SHELLS=(); LABELS=()
seen=" "
for s in bash sh dash mksh; do
  p=$(command -v "$s" 2>/dev/null) || { echo "shell not found, not run: $s"; continue; }
  r=$(readlink -f "$p")
  case "$seen" in *" $r "*) continue ;; esac
  seen="$seen$r "; SHELLS+=("$p"); LABELS+=("$s")
done

NP_BEGIN='# ---- NWP-20261210-19: NETPOLICY WI-FI TEMPLATE RESET (begin) ---------------------------------------------------------'
NP_END='# ---- NWP-20261210-19: NETPOLICY WI-FI TEMPLATE RESET (end) -----------------------------------------------------------'
HS_END='# ---- NWP-20261028-10: SESSION HOTSPOT RELEASE (end) ------------------------------------------------------------------'
MD_BEGIN='# ---- NWP-20261026-05: SESSION-SCOPED MOBILE DATA (begin) ------------------------------------------------------------'
LBEGIN_HDR='# ---- NWP-20261016-45: SESSION-SCOPED LOCATION GLOBALS (begin) -------------------------------------------------------'
LEND_HDR='# ---- NWP-20261016-45: SESSION-SCOPED LOCATION GLOBALS (end) ---------------------------------------------------------'
BS_HDR='if [ "$op" = "bootsweep" ]; then'
CS_HDR='if [ "$op" = "cleanstorage" ]; then'
FIX15_HDR='  # --- fix 15: hotspot (NWP-20261028-10) ---'
FIX15_END='  _swept="$_swept hotspot=$_hs"'
FIX16_HDR='  # --- fix 16: keystore-drop (NWP-20261102-04) ---'
RESULT_LINE='  echo "[roamd] bootsweep result:$_swept $(date)" >> "$LOG"'
HS_REAP='  hs_release "$uid" reap   # NWP-20261028-10: the reap'"'"'s backstop for the hotspot; another session'"'"'s is left alone by the gate'
RLO_HDR='reap_live_other() {'
FIX18_NPOL='  _sb_npol=$(_sb_state "/data/system" netpolicy.xml)'
REAP_RE='^  if ! reap_live_other "\$uid" >/dev/null; then np_release reap; fi( |$)'
RECV='com.nowhere.chooser/.NetPolicyReceiver'
ACT='com.nowhere.chooser.action.NETPOLICY_WIFI_RESET'

# prep <roamd.sh>: extract the pieces into a fresh dir ($R). 0, or 2 (the harness cannot run).
prep() {
  local f="$1" x blk lblk slice rlo reapl scrub
  R=$(mktemp -d -p "$W") || return 2
  for x in "$HS_END" "$MD_BEGIN" "$LBEGIN_HDR" "$LEND_HDR" "$BS_HDR" "$CS_HDR" "$FIX15_HDR" "$FIX15_END" "$FIX16_HDR" \
           "$RESULT_LINE" "$HS_REAP" "$RLO_HDR" "$FIX18_NPOL"; do
    [ "$(grep -cxF -- "$x" "$f")" = 1 ] || { echo "EXTRACTION FAILED: anchor not found exactly once in $f: $x" >&2; return 2; }
  done
  # The NP block: tolerant (C0 judges it). Empty when absent.
  blk=$(awk -v b="$NP_BEGIN" -v e="$NP_END" '$0 == b {on = 1} on {print} $0 == e {exit}' "$f")
  lblk=$(awk -v b="$LBEGIN_HDR" -v e="$LEND_HDR" '$0 == b {on = 1} on {print} $0 == e {exit}' "$f")
  [ "$(grep -c '^loc_why() {' <<< "$lblk")" = 1 ] || { echo "EXTRACTION FAILED: loc_why line" >&2; return 2; }
  # fix 15's header up to (not including) fix 16's header, inside the bootsweep op.
  slice=$(awk -v bs="$BS_HDR" -v h="$FIX15_HDR" -v e="$FIX16_HDR" '$0 == bs {op = 1} op && $0 == e {exit} op && $0 == h {on = 1} on {print}' "$f")
  case "$slice" in *'hs_release -1 boot'*"$FIX15_END"*) ;; *) echo "EXTRACTION FAILED: fix 15 in the bootsweep op" >&2; return 2 ;; esac
  rlo=$(awk -v h="$RLO_HDR" '$0 == h {on = 1} on {print} on && $0 == "}" {exit}' "$f")
  case "$rlo" in *'.roamsession'*'return 0'*'}') ;; *) echo "EXTRACTION FAILED: reap_live_other" >&2; return 2 ;; esac
  # Every live line of the cleanstorage op that calls np_release: what C11 runs (none: a no-op).
  reapl=$(awk -v h="$CS_HDR" '$0 == h {on = 1} on && /^fi$/ {exit} on {print}' "$f" | grep -v '^[[:space:]]*#' | grep 'np_release' || true)
  [ -n "$reapl" ] || reapl=':'
  scrub=$(grep -m1 "^LOG_SCRUB_SED='" "$f"); scrub=${scrub#LOG_SCRUB_SED=\'}; scrub=${scrub%\'}
  [ -n "$scrub" ] || { echo "EXTRACTION FAILED: LOG_SCRUB_SED" >&2; return 2; }
  printf '%s\n' "$scrub" > "$R/scrub.sed"
  grep '^loc_why() {' <<< "$lblk" > "$R/loc.sh"; printf '%s\n' "$blk" > "$R/np.sh"; printf '%s\n' "$slice" > "$R/boot.sh"
  printf '%s\n' "$rlo" > "$R/rlo.sh"; printf '%s\n' "$reapl" > "$R/reap.sh"
  for x in loc np boot rlo reap; do
    bash -n "$R/$x.sh" || { echo "EXTRACTION FAILED: the extracted $x piece does not parse" >&2; return 2; }
  done
  mkdir "$R/bin" || return 2
  # The gate's receiver: one line per call (the whole argv) in $T/am-calls. $T/reply, if present, is the data= of the
  # first `Broadcast completed:` line (a CR ends it, as on the device), $T/reply2 of a second one; absent, am prints no
  # such line. $T/empty-first, if present, puts a completion line WITHOUT data= first. $T/am-rc is its exit code.
  cat > "$R/bin/am" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$T/am-calls"
echo "NOISE-AM" >&2
if [ -f "$T/reply" ]; then
  echo 'Broadcasting: Intent { act=com.nowhere.chooser.action.NETPOLICY_WIFI_RESET }'
  [ -f "$T/empty-first" ] && printf 'Broadcast completed: result=0\r\n'
  printf 'Broadcast completed: result=-1, data="%s"\r\n' "$(cat "$T/reply")"
  [ -f "$T/reply2" ] && printf 'Broadcast completed: result=-1, data="%s"\r\n' "$(cat "$T/reply2")"
fi
[ -f "$T/am-rc" ] && exit "$(cat "$T/am-rc")"
exit 0
STUB
  cat > "$R/bin/timeout" <<'STUB'
#!/bin/sh
echo "$1 $2 $3" >> "$T/timeout-calls"
shift 3
exec "$@"
STUB
  printf '#!/bin/sh\necho DATE\n' > "$R/bin/date"
  chmod +x "$R/bin/am" "$R/bin/timeout" "$R/bin/date"
  return 0
}

DRIVER='
STATE="$T/state"; LOG="$T/log"; RES="$T/res"
hs_release() { HS_VERDICT="OK RELEASED"; }   # NWP-20261028-10: the hotspot is test-hotspot-release.sh, not this suite
. "$R/loc.sh"; . "$R/np.sh"
case "$MODE" in
  np) np_release "$WHYV"; printf "%s" "${NP_VERDICT-UNSET}" > "$T/verdict" ;;
  boot) op=bootsweep; uid=12; _swept=""; . "$R/boot.sh"; printf "%s" "$_swept" > "$T/swept" ;;
  reap) op=cleanstorage; uid="$UIDV"; name=x; . "$R/rlo.sh"; . "$R/reap.sh" ;;
esac'

# suite <roamd.sh> <shell path> <label> [quiet]: 0 all ok, 1 an assertion failed (the only verdict that convicts a
# mutant), 2 the harness could not run. prep must have run ($R).
suite() {
  local f="$1" SH="$2" LB="$3" quiet="${4:-}" PASS=0 FAIL=0 T out at x v n want mk k
  ok() { PASS=$((PASS+1)); [ -n "$quiet" ] || printf '  ok    [%s] %s\n' "$LB" "$1"; }
  no() { FAIL=$((FAIL+1)); [ -n "$quiet" ] || printf '  FAIL  [%s] %s\n' "$LB" "$1"; }

  mkdev() { T=$(mktemp -d -p "$W"); mkdir -p "$T/state"; }
  reply() { printf '%s' "$1" > "$T/reply"; }
  ncalls() { if [ -f "$T/am-calls" ]; then grep -c . "$T/am-calls" || true; else echo 0; fi; }
  lastcall() { tail -n 1 "$T/am-calls" 2>/dev/null; }
  drive() {  # drive <mode> <why> <uid>
    env LC_ALL=C PATH="$R/bin:$PATH" T="$T" R="$R" MODE="$1" WHYV="${2:-}" UIDV="${3:-}" "$SH" -c "$DRIVER" >/dev/null 2>>"$T/stderr"
  }
  np() { drive np "$1"; cat "$T/verdict" 2>/dev/null; }
  logn() { if [ -f "$T/log" ]; then grep -c . "$T/log" || true; else echo 0; fi; }
  clean() {  # no harness error may hide behind a passing case
    if [ -s "$T/stderr" ] && grep -qE 'not found|unbound|[Ss]yntax error|bad substitution|parameter not set' "$T/stderr"; then
      no "$1: the harness reported $(head -n 1 "$T/stderr")"
    fi
    if [ -f "$T/log" ] && grep -q 'NOISE-' "$T/log"; then no "$1: am output reached the log"; fi
    rm -rf "$T"
  }
  verdict_is() {  # verdict_is <case> <reply|-> <want>
    local c="$1" rp="$2" w="$3" got
    mkdev; [ "$rp" = - ] || reply "$rp"
    got=$(np boot)
    [ "$got" = "$w" ] && ok "$c reply '$rp' -> $w" || no "$c reply '$rp' -> '$got', want $w"
    clean "$c $rp"
  }

  # --- C0: the block -------------------------------------------------------------------------------------------
  at=$(awk -v h="$HS_END" -v b="$NP_BEGIN" -v e="$NP_END" -v m="$MD_BEGIN" '$0 == h {hl = NR} $0 == b {bl = NR; nb++} $0 == e {el = NR; ne++}
    $0 == m {ml = NR} END {print (nb == 1 && ne == 1 && hl && bl == hl + 1 && el > bl && ml == el + 1) ? "ok" : "no"}' "$f")
  [ "$at" = ok ] && ok "C0 the NP block exists once, right after the hotspot block and right before mobile data" \
    || no "C0 the NP block (np_release) is missing or misplaced"

  # --- C1-C5: the verdict ---------------------------------------------------------------------------------------
  verdict_is C1 'OK RESET 3' 'reset(3)'
  verdict_is C1 'OK RESET 12' 'reset(12)'
  verdict_is C2 'OK NONE' 'none'
  for v in user denied failed noservice; do verdict_is C3 "ERR-NP $v" "failed($v)"; done
  for v in 'ERR-NP wat' 'OK RESET 3x' 'OK RESET ' 'OK RESET -3' 'OK RESET 3 4' 'OK RESET +3' 'OK RESET 0' 'OK RESET 00' \
           'ERR-NP ' 'ERR-NP denied x' 'ERR-NP Denied' 'OK NONE x' 'ok none' 'OK RELEASED' ''; do
    verdict_is C4 "$v" 'failed(noreply)'
  done
  mkdev; reply 'OK RESET 3x'; printf 'OK RESET 3' > "$T/reply2"
  x=$(np boot)
  [ "$x" = 'failed(noreply)' ] && ok "C4 only the FIRST completion line counts (malformed first, good second -> failed(noreply))" \
    || no "C4 two completion lines, malformed first -> '$x'"
  clean C4two
  mkdev; reply 'OK NONE'; printf 'ERR-NP wat' > "$T/reply2"
  x=$(np boot)
  [ "$x" = none ] && ok "C4 a later completion line does not override the first" || no "C4 two lines, good first -> '$x'"
  clean C4two2
  mkdev; reply 'OK RESET 3'; : > "$T/empty-first"
  x=$(np boot)
  [ "$x" = 'failed(noreply)' ] && ok "C4 a first completion line without data= is no reply (a good second -> failed(noreply))" \
    || no "C4 two lines, first without data= -> '$x'"
  clean C4two3
  verdict_is C5 - 'failed(noreply)'
  mkdev; reply 'OK RESET 3'; echo 124 > "$T/am-rc"
  x=$(np boot)
  [ "$x" = 'failed(noreply)' ] && ok "C5 a well-formed reply from an am that exited 124 -> failed(noreply)" || no "C5 rc 124 -> '$x'"
  clean C5rc
  mkdev; reply 'OK NONE'; echo 1 > "$T/am-rc"
  x=$(np boot)
  [ "$x" = 'failed(noreply)' ] && ok "C5 a reply from an am that exited 1 -> failed(noreply)" || no "C5 rc 1 -> '$x'"
  clean C5rc1

  # --- C6: the broadcast ----------------------------------------------------------------------------------------
  mkdev; reply 'OK NONE'
  np boot >/dev/null
  want="broadcast --user 0 -n $RECV -a $ACT"
  [ "$(ncalls)" = 1 ] && [ "$(lastcall)" = "$want" ] \
    && ok "C6 one broadcast: --user 0, the explicit component and action, no extras" \
    || no "C6 $(ncalls) call(s), last '$(lastcall)', want '$want'"
  [ "$(cat "$T/timeout-calls" 2>/dev/null)" = "-k 2 15" ] && ok "C6 under timeout -k 2 15" \
    || no "C6 timeout calls: '$(cat "$T/timeout-calls" 2>/dev/null)'"
  clean C6

  # --- C7: the log line -----------------------------------------------------------------------------------------
  mkdev; reply 'OK RESET 3'
  np boot >/dev/null
  want='[roamd] netpolicy wifi templates (boot): reset(3) (NWP-20261210-19) DATE'
  x=$(cat "$T/log" 2>/dev/null)
  [ "$(logn)" = 1 ] && [ "$x" = "$want" ] && ok "C7 exactly one line: $want" || no "C7 log: '$x'"
  v=$(printf '%s\n' "$x" | sed -E -f "$R/scrub.sed")
  [ -n "$x" ] && [ "$v" = "$x" ] && ok "C7 LOG_SCRUB_SED leaves it byte-identical" || no "C7 scrubbed: '$v'"
  clean C7a
  mkdev; reply 'ERR-NP Alice Smith'
  np 'a b' >/dev/null
  want='[roamd] netpolicy wifi templates (other): failed(noreply) (NWP-20261210-19) DATE'
  x=$(cat "$T/log" 2>/dev/null)
  if [ "$(logn)" = 1 ] && [ "$x" = "$want" ] && ! grep -q 'Alice' "$T/log"; then
    ok "C7 a reason with a space logs (other); a reply carrying a name is never logged"
  else no "C7 log: '$x'"; fi
  clean C7b
  for v in 'OK RESET 7' 'OK NONE' 'ERR-NP noservice' 'garbage "q"'; do
    mkdev; reply "$v"
    np reap >/dev/null
    x=$(cat "$T/log" 2>/dev/null)
    if [ "$(logn)" = 1 ] && printf '%s\n' "$x" | grep -qxE '\[roamd\] netpolicy wifi templates \([a-z]+\): (reset\([0-9]+\)|none|failed\([a-z]+\)) \(NWP-20261210-19\) DATE' \
       && [ "$(printf '%s\n' "$x" | sed -E -f "$R/scrub.sed")" = "$x" ]; then
      ok "C7 reply '$v': one line of fixed tokens and digits, scrub-stable"
    else no "C7 reply '$v' log: '$x'"; fi
    clean "C7 $v"
  done

  # --- C8: fix 15b ------------------------------------------------------------------------------------------------
  at=$(awk -v bs="$BS_HDR" -v f15="$FIX15_END" -v f16="$FIX16_HDR" -v res="$RESULT_LINE" '
    $0 == bs {op = NR} op && !end && NR > op && /^fi$/ {end = NR}
    $0 == f15 {p = NR} $0 == f16 {q = NR} $0 == res {rl = NR}
    /^[[:space:]]*np_release boot([[:space:]]|$)/ {n++; c = NR}
    END {print (n == 1 && op && p > op && c > p && c < q && q < rl && (!end || rl < end)) ? "in" : "out(" n ")"}' "$f")
  [ "$at" = in ] && ok "C8 one np_release boot, inside the bootsweep op, after fix 15's _swept line and before fix 16" \
    || no "C8 the boot call is missing or misplaced: $at"
  x=$(grep -nE '_swept=.*(netpolicy|NP_VERDICT|np_)' "$f" || true)
  [ -z "$x" ] && ok "C8 no _swept assignment names netpolicy" || no "C8 _swept names netpolicy: $x"
  mkdev; reply 'OK RESET 2'
  out=$(drive boot; cat "$T/swept" 2>/dev/null)
  if [ "$out" = " hotspot=released" ] && [ "$(ncalls)" = 1 ] && [ "$(grep -c '^\[roamd\] netpolicy wifi templates (boot): reset(2) ' "$T/log" 2>/dev/null)" = 1 ]; then
    ok "C8 fix 15..16 run: one reset request logged as (boot), _swept stays ' hotspot=released'"
  else no "C8 fix 15..16 run: _swept '$out', $(ncalls) call(s), log '$(cat "$T/log" 2>/dev/null)'"; fi
  clean C8

  # --- C9: never a file ---------------------------------------------------------------------------------------------
  x=$(grep -nE 'netpolicy\.xml|WifiConfigStore\.xml' "$f" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -vxF "$(grep -nxF "$FIX18_NPOL" "$f")" || true)
  [ -z "$x" ] && ok "C9 live code names netpolicy.xml / WifiConfigStore.xml only in fix 18's report-only listing" \
    || no "C9 live code names a store file: $x"
  x=$(grep -v '^[[:space:]]*#' "$R/np.sh" | grep -n '>' | grep -vE '>> "\$LOG"|2>/dev/null|</dev/null' || true)
  [ -z "$x" ] && ok "C9 the block's only redirection is the log append" || no "C9 redirection in live code: $x"

  # --- C10: the reap call ---------------------------------------------------------------------------------------
  at=$(RE="$REAP_RE" awk -v cs="$CS_HDR" -v hs="$HS_REAP" '
    $0 == cs {op = NR} op && !end && NR > op && /^fi$/ {end = NR}
    op && !end && $0 == hs {hl = NR}
    op && !end && !mm && /^  stop_mediad / {mm = NR}
    op && !end && !/^[[:space:]]*#/ && /np_release/ {n++; nl = NR; good = ($0 ~ ENVIRON["RE"])}
    END {print (n == 1 && good && hl && nl == hl + 1 && mm > nl) ? "ok" : "no(" n ")"}' "$f")
  [ "$at" = ok ] && ok "C10 cleanstorage: one guarded np_release reap, right after hs_release and before stop_mediad" \
    || no "C10 the reap call is missing, unguarded or misplaced: $at"

  # --- C11: the guard ---------------------------------------------------------------------------------------------
  for v in other:14:0 damaged:abc:0 own:13:1 missing:-:1; do
    mk=${v#*:}; k=${mk#*:}; mk=${mk%%:*}; set -- "${v%%:*}" "$mk" "$k"
    mkdev; reply 'OK RESET 1'
    if [ "$2" != - ]; then printf 'p-name\np-pass\n%s\n' "$2" > "$T/state/.roamsession"; fi
    drive reap '' 13
    n=$(if [ -f "$T/log" ]; then grep -c '^\[roamd\] netpolicy wifi templates (reap): reset(1) ' "$T/log" || true; else echo 0; fi)
    if [ "$(ncalls)" = "$3" ] && [ "$n" = "$3" ] && [ "$(logn)" = "$3" ]; then
      ok "C11 reap of 13, marker $1: $3 request(s), $3 (reap) line(s)"
    else no "C11 reap of 13, marker $1: $(ncalls) call(s), log '$(cat "$T/log" 2>/dev/null)', want $3"; fi
    if [ -f "$T/log" ] && grep -qE 'p-name|p-pass' "$T/log"; then no "C11 marker $1: a marker line reached the log"; fi
    clean "C11 $1"
  done

  [ -n "$quiet" ] || printf '  -- [%s] %d ok, %d failed\n' "$LB" "$PASS" "$FAIL"
  [ "$FAIL" = 0 ] && return 0 || return 1
}

# runall <roamd.sh> [quiet] -> the worst verdict over the shells
runall() {
  local f="$1" q="${2:-}" i rc worst=0
  prep "$f" || return 2
  for i in "${!SHELLS[@]}"; do
    suite "$f" "${SHELLS[$i]}" "${LABELS[$i]}" "$q"; rc=$?
    [ "$rc" -gt "$worst" ] && worst=$rc
  done
  rm -rf "$R"
  return "$worst"
}

echo "== $SUT"
echo "shells: ${LABELS[*]}"
runall "$SUT"; rc=$?
if [ "$rc" != 0 ]; then echo "FAILED (rc=$rc)"; exit "$rc"; fi
[ "$MUTATE" = yes ] || exit 0

echo
echo "== mutations (each must be CONVICTED by its named assertion under EACH shell; one that does not apply or breaks the harness is a failure)"
fails=0; nmut=0
# mut <label> <the case that must FAIL, e.g. C4> <perl -0pe program> [control]: a control must PASS instead.
mut() {
  local lb="$1" want="$2" prog="$3" ctl="${4:-}" i rc m="$W/mutant.sh" o
  nmut=$((nmut+1))
  if ! perl -0pe "$prog" "$SUT" > "$m"; then echo "  ERROR     $lb -- perl failed"; fails=$((fails+1)); return; fi
  if cmp -s "$SUT" "$m"; then echo "  INERT     $lb -- the mutation changed nothing"; fails=$((fails+1)); return; fi
  if ! bash -n "$m" 2>/dev/null; then echo "  BROKEN    $lb -- the mutant does not parse"; fails=$((fails+1)); return; fi
  prep "$m"; rc=$?
  [ "$rc" = 0 ] || { echo "  BROKEN    $lb -- the mutant could not be extracted"; fails=$((fails+1)); return; }
  for i in "${!SHELLS[@]}"; do
    o=$(suite "$m" "${SHELLS[$i]}" "${LABELS[$i]}" 2>&1); rc=$?
    if [ -n "$ctl" ]; then
      [ "$rc" = 0 ] && echo "  passed    [${LABELS[$i]}] $lb (control)" \
        || { echo "  FAILED    [${LABELS[$i]}] $lb (control, rc=$rc)"; fails=$((fails+1)); }
      continue
    fi
    case "$rc" in
      1) if printf '%s\n' "$o" | grep -q "^  FAIL  \[${LABELS[$i]}\] $want "; then echo "  convicted [${LABELS[$i]}] $lb (by $want)"
         else echo "  WRONG     [${LABELS[$i]}] $lb -- failed, but not by $want"; fails=$((fails+1)); fi ;;
      0) echo "  SURVIVED  [${LABELS[$i]}] $lb"; fails=$((fails+1)) ;;
      *) echo "  BROKEN    [${LABELS[$i]}] $lb -- the harness could not run it (rc=$rc), which is not a conviction"; fails=$((fails+1)) ;;
    esac
  done
  rm -rf "$R"
}
mut "N1 the digits check is dropped"           C4 's/        \x27\x27\|\*\[!0-9\]\*\) NP_VERDICT="failed\(noreply\)" ;;\n//'
mut "N2 the am rc check is dropped"            C5 's/^  \[ "\$_rc" -eq 0 \] \|\| _d=""[^\n]*\n(  case "\$_d" in\n    "OK NONE")/$1/m'
mut "N3 the closed reason set is dropped"      C4 's/"ERR-NP user"\|"ERR-NP denied"\|"ERR-NP failed"\|"ERR-NP noservice"\)/"ERR-NP "*)/'
mut "N4 --user 0 is removed"                   C6 's/am broadcast --user 0 -n "\$NP_RECEIVER"/am broadcast -n "\$NP_RECEIVER"/'
mut "N5 the timeout is removed"                C6 's/timeout -k 2 15 am broadcast --user 0 -n "\$NP_RECEIVER"/am broadcast --user 0 -n "\$NP_RECEIVER"/'
mut "N6 the boot call moves before fix 15"     C8 's/^  np_release boot\n//m; s/^(  # --- fix 15: hotspot \(NWP-20261028-10\) ---\n)/  np_release boot\n$1/m'
mut "N7 _swept names netpolicy"                C8 's/^(  np_release boot\n)/$1  _swept="\$_swept netpolicy=\$NP_VERDICT"\n/m'
mut "N8 the log line prints the raw reply"     C7 's/\): \$NP_VERDICT \(NWP-20261210-19\)/): \$_d (NWP-20261210-19)/'
mut "N9 loc_why is dropped from the log line"  C7 's/templates \(\$\(loc_why "\$1"\)\): /templates (\$1): /'
mut "N10 the reap call is removed"             C10 's/^  if ! reap_live_other "\$uid" >\/dev\/null; then np_release reap; fi[^\n]*\n//m'
mut "N11 the reap guard is removed"            C11 's/^  if ! reap_live_other "\$uid" >\/dev\/null; then np_release reap; fi/  np_release reap/m'
mut "N12 data= is read before the first line"  C4 's/sed -n \x27\/\^Broadcast completed:\/p\x27 \| head -n 1 \| //'
mut "control: a comment edit"                  - 's/^# np_release <why>: ask the gate to remove/# np_release <why>: ask the gate, once, to remove/m' control
[ "$fails" = 0 ] && echo "== all $nmut mutation outcomes as required (shells: ${LABELS[*]})" || { echo "== $fails mutation outcome(s) not as required"; exit 1; }
