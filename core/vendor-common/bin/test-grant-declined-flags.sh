#!/usr/bin/env bash
# test-grant-declined-flags.sh [<nowhere_roamd.sh>] [--mutate] -- grant_perms_for re-declines what the profile
# declined (NWP-20261012-05).
#
# WHY THIS IS COMMITTED. Chester, 2026-10-12: "some app are popping up to accept notification after roam, why is
# that?". The platform re-prompts for a permission that is not granted and carries neither USER_SET nor USER_FIXED,
# and a fresh user's not-granted permission carries neither, so a declined permission asked again after every roam.
# docs/product-decisions.md (2026-10-12): a permission the user declined stays declined with the profile, and the
# mechanism only ever withholds a grant. capturePerms now writes `<pkg> flags:<user-set|user-fixed|
# user-set,user-fixed>:<perm>`; grant_perms_for sets the flags back and then revokes the permission. Each way that
# breaks is silent on the device -- the app just asks again, is killed for a revoke nobody wanted, or worse, is granted
# something the user refused:
#   - a `flags:` line falling through to the per-line `pm grant` (it fails, quietly);
#   - a grant line for the same pair outliving the decline, in any of the three flag forms (a tampered file);
#   - the decline applied BEFORE a grant of this function, which a later grant could undo;
#   - the revoke before the flags (a non-overriding default grant can land between the two);
#   - the decline pass on a package-filtered call that is NOT a first materialise: the install-heal sends those for
#     every UPDATE, with the login-time file, and a revoke there takes back a permission the user granted mid-session
#     and kills the app. odrestore must pass its hold probe as DECLINES, and since odrestore KEEPS a hold on its
#     failure paths while the app stays installed, a package already declined this session ($STATE/.declined.<uid>,
#     cleared at roam-in) must not be declined again;
#   - the chooser itself accepted as a decline target;
#   - the allowlist widened, so a sealed file could set review-required / revoked-compat / anything else;
#   - INTERNET accepted here, where the INTERNET default would race it (its channel is `deny:`);
#   - a package or permission that pm would read as an option;
#   - more than 6 `pm` calls in flight during a login that is already contended;
#   - (NWP-20261012-08, Chester 2026-10-12: "yes keep the read_sms access"; 2026-10-13: "All six") a decline of one
#     of the six permissions the SMS role grants (READ_SMS, RECEIVE_SMS, RECEIVE_MMS, RECEIVE_WAP_PUSH, SEND_SMS,
#     READ_CELL_BROADCASTS) applied to an app that can hold the SMS role after the sign-in apply --
#     Messaging, or the app the chooser's nowhere-sms names -- which this pass, run before the role step, would revoke
#     where no role add re-grants it; or that exemption reaching any other app or permission, or the record read
#     differently from PermDeclines.recordedSmsApp + SmsRoleRoam.parseSmsRecord (the 4096-byte cap, String.trim's
#     control characters). P1 holds the six to PermDeclines.SMS_ROLE_PERMS.
#
# The function is extracted from nowhere_roamd.sh BY ANCHOR, never copied, with its one nowhere-perms path rewritten
# under a scratch root (same harness as test-grant-internet-default.sh). `pm` and `cmd` are stubbed as shell
# functions that record every call; a `pm` verb the stubs do not model fails the case. Every case runs under bash and
# sh, plus dash and mksh where installed -- roamd is #!/system/bin/sh (mksh on the device). The two call sites are
# checked in the script itself (W1).
#
#   bash test-grant-declined-flags.sh            # the behaviour cases
#   bash test-grant-declined-flags.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
# Every temp of the run lives inside W.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

PDJ="$(cd "$(dirname "$0")" && pwd)/../../chooser/src/com/nowhere/chooser/PermDeclines.java"   # P1's other side

SHELLS="bash sh"
for s in mksh dash; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done

UIDV=15
PFREL="data/user/$UIDV/com.nowhere.chooser/files/nowhere-perms"
NOTIF=android.permission.POST_NOTIFICATIONS
CAM=android.permission.CAMERA
LOC=android.permission.ACCESS_FINE_LOCATION
INET=android.permission.INTERNET
# NWP-20261012-08: the six the SMS role grants, which its holder keeps, and a non-SMS permission of the same app.
RS=android.permission.READ_SMS RV=android.permission.RECEIVE_SMS RM=android.permission.RECEIVE_MMS
RW=android.permission.RECEIVE_WAP_PUSH SS=android.permission.SEND_SMS RC=android.permission.READ_CONTACTS
CB=android.permission.READ_CELL_BROADCASTS
MSG=com.android.messaging

# POSIX sh. Every pm call is one appended line, so the ORDER of the file is the order the calls finished in: calls
# within one backgrounded subshell are ordered, calls across a `wait` are ordered, nothing else is.
# A revoke of android.permission.FIXED_X fails, as pm does for a system-fixed permission. set-permission-flags records
# how many of its calls are in flight at once (a file per call, held for SLOW seconds) in $D/conc.
STUBS='
pm() {
  case "$1 $2" in
    "list packages") cat "$D/pkgs" ;;
    "grant --user")  echo "grant $4 $5"  >> "$D/calls"; return 0 ;;
    "revoke --user") echo "revoke $4 $5" >> "$D/calls"; [ "$5" != android.permission.FIXED_X ] ;;
    "set-permission-flags --user")
      _s=$(mktemp "$D/run/c.XXXXXX"); ls "$D/run" | wc -l >> "$D/conc"
      [ -n "$SLOW" ] && sleep "$SLOW"
      shift 3; echo "flags $*" >> "$D/calls"; rm -f "$_s"; return 0 ;;
    *) echo "pm $*" >> "$D/unexpected"; return 1 ;;
  esac
}
cmd() { echo "cmd $*" >> "$D/calls"; return 0; }
'

# prep_fn <roamd.sh> <out> -- extract grant_perms_for and point its nowhere-perms under $TROOT. 0 ok, 2 harness error.
prep_fn() {
  local sut="$1" out="$2" raw
  raw=$(mktemp -p "$W")
  sed -n '/^grant_perms_for() {$/,/^}$/p' "$sut" > "$raw"
  if [ ! -s "$raw" ] || [ "$(head -1 "$raw")" != 'grant_perms_for() {' ] || [ "$(tail -1 "$raw")" != '}' ]; then
    echo "EXTRACTION FAILED: grant_perms_for() { ... } not found in $sut" >&2; command rm -f "$raw"; return 2
  fi
  sed 's#PF="/data/user/#PF="$TROOT/data/user/#' "$raw" > "$out"
  command rm -f "$raw"
  if [ "$(grep -c 'PF="\$TROOT/data/user/' "$out")" != 1 ] || [ "$(grep -c '/data/user/' "$out")" != 1 ]; then
    echo "REWRITE FAILED: want exactly one PF=\"/data/user/ assignment in grant_perms_for of $sut" >&2; return 2
  fi
  if ! bash -n "$out" || ! sh -n "$out"; then
    echo "EXTRACTION FAILED: grant_perms_for does not parse ($sut)" >&2; return 2
  fi
  return 0
}

# run <fn> <shell> <pkgfilter> <declines> <content> <pkg>... -- run the function once in a fresh dir; sets D (the
# caller removes it). <declines> is the third argument as a caller passes it; "-" passes none at all. With CALLS set,
# its lines are the calls instead (several calls in one session share $STATE, as on the device). With UNW set, a
# directory stands at $STATE/$UNW, so a truncation of it fails; with POSIXB set, a bash child runs as `bash --posix`.
# The child's exit code is left in RRC.
run() {
  local fn="$1" sh="$2" filt="$3" dcl="$4" content="$5" pf
  shift 5
  D=$(mktemp -d -p "$W"); pf="$D/root/$PFREL"
  mkdir -p "$D/state" "$D/run" "${pf%/*}"
  [ -n "${UNW:-}" ] && mkdir -p "$D/state/$UNW"
  printf '%s' "$content" > "$pf"
  [ -n "${SMSREC+x}" ] && printf '%s' "$SMSREC" > "${pf%/*}/nowhere-sms"   # the chooser's SMS-app record, when set
  printf 'package:%s\n' "$@" > "$D/pkgs"
  {
    printf 'D=%s\nTROOT=%s\nSTATE=%s\nLOG=%s\nSLOW=%s\n' "$D" "$D/root" "$D/state" "$D/log" "${SLOW:-}"
    printf '%s\n' "$STUBS"
    cat "$fn"
    if [ -n "${CALLS:-}" ]; then printf '%s\n' "$CALLS"
    elif [ "$dcl" = - ]; then printf 'grant_perms_for %s "%s"\n' "$UIDV" "$filt"
    else printf 'grant_perms_for %s "%s" "%s"\n' "$UIDV" "$filt" "$dcl"; fi
  } > "$D/run.sh"
  if [ "$sh" = bash ] && [ -n "${POSIXB:-}" ]; then bash --posix "$D/run.sh"; else "$sh" "$D/run.sh"; fi >/dev/null 2>&1
  RRC=$?
  touch "$D/calls" "$D/log" "$D/unexpected" "$D/conc" "$D/reached"
}

# Assertion helpers: each appends to $why on failure.
has()   { grep -qxF -- "$1" "$D/calls" || why="$why missing '$1';"; }
hasnt() { ! grep -qxF -- "$1" "$D/calls" || why="$why unexpected '$1';"; }
count() { [ "$(grep -cxF -- "$2" "$D/calls")" = "$1" ] || why="$why want $1 x '$2', got $(grep -cxF -- "$2" "$D/calls");"; }
# line number of the first / last call matching a regex (0 when none)
first() { local l; l=$(grep -n -- "$1" "$D/calls" | head -1 | cut -d: -f1); echo "${l:-0}"; }
last()  { local l; l=$(grep -n -- "$1" "$D/calls" | tail -1 | cut -d: -f1); echo "${l:-0}"; }
before() {  # before <regex a> <regex b>: every call matching a precedes every call matching b; both must exist
  local la fb; la=$(last "$1"); fb=$(first "$2")
  { [ "$la" -gt 0 ] && [ "$fb" -gt 0 ] && [ "$la" -lt "$fb" ]; } || why="$why want every /$1/ before every /$2/ (last $la, first $fb);"
}
nodecline() { ! grep -q '^flags \|^revoke ' "$D/calls" || why="$why declined something: $(grep '^flags \|^revoke ' "$D/calls" | tr '\n' ';');"; }
logsays() { grep -qF -- "$1" "$D/log" || why="$why log '$(cat "$D/log")' lacks '$1';"; }
# the child returned past the call: it ended rc 0 AND printed REACHED after it (rc alone never counts)
reached() { [ "$RRC" = 0 ] && grep -qx REACHED "$D/reached" || why="$why the child ended rc $RRC before REACHED (the shell exited);"; }
# the Nth summary line of the log (a skipped grant phase logs a line of its own between them, NWP-20261025-10)
slog()    { grep -F ' declined kept ' "$D/log" | sed -n "$1p"; }
clean()   { [ -s "$D/unexpected" ] && why="$why unmodelled: $(tr '\n' ';' < "$D/unexpected");"; command rm -rf "$D"; }

suite() {  # suite <roamd.sh> [quiet] -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" quiet="${2:-}" fn p=0 x=0 sh rc NL why i many mx CR L255 sms6 q rec lbl rv want pk TAB SOH VT US DEL F4083
  local gcont gcall gref t tn tag
  ok() { p=$((p+1)); [ -n "$quiet" ] || printf '  ok    %s\n' "$1"; }
  no() { x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  %s\n' "$1"; }
  verdict() { if [ -z "$why" ]; then ok "$1 [$sh]"; else no "$1 [$sh] --$why"; fi; }
  fn=$(mktemp -p "$W")
  prep_fn "$f" "$fn"; rc=$?
  [ "$rc" = 0 ] || { command rm -f "$fn"; return 2; }
  NL=$'\n'; CR=$(printf '\r'); L255="com.$(printf '%0251d' 0)"
  TAB=$(printf '\t'); SOH=$(printf '\001'); VT=$(printf '\013'); US=$(printf '\037'); DEL=$(printf '\177')
  F4083=$(printf '%4083s' '' | tr ' ' '#')
  # T0-T3: one grant line, one decline and a package with no lines, so the grant loop, the INTERNET default and the
  # declines pass all run. REACHED is the statement after the call.
  gcont="com.foo $CAM${NL}com.foo flags:user-set:$NOTIF$NL"
  gcall="grant_perms_for $UIDV \"\"${NL}echo REACHED >> \"\$D/reached\""

  # W1: the call sites, once. Login declines (no filter); odrestore passes its first-install flag; nothing else declines.
  sh=script; why=""
  [ "$(grep -c '^    _tt=$(_ms); grant_perms_for "$uid"; _tlog grant-135 "$_tt"$' "$f")" = 1 ] \
    || why="$why the login call is not 'grant_perms_for \"\$uid\"';"
  [ "$(grep -c '^      grant_perms_for "$uid" "$pkg" "$_first" ${odbatch:+"$odbatch"}$' "$f")" = 1 ] \
    || why="$why odrestore does not pass its first-install flag as DECLINES;"
  [ "$(grep -c '^    \[ "$_first" = 1 \] || { grep -qxF -- "$pkg" "$USERDIR/com.nowhere.chooser/files/nowhere-od-materialised" 2>/dev/null && _first=1; }$' "$f")" = 1 ] \
    || why="$why odrestore's materialised-record probe moved;"
  [ "$(grep -c '^      rm -f "$USERDIR/com.nowhere.chooser/files/nowhere-od-materialised" 2>>"$LOG"$' "$f")" = 1 ] \
    || why="$why roam-in no longer clears the session's materialised record;"
  [ "$(grep -c 'grant_perms_for "' "$f")" = 2 ] || why="$why a third grant_perms_for call site appeared;"
  [ "$(grep -c '^      \[ -d "$vol/com.nowhere.chooser/$ODHOLD/$pkg" \] && { _hold=1; break; }$' "$f")" = 1 ] \
    || why="$why odrestore's hold probe moved;"
  [ "$(grep -c '^      rm -f "$STATE/.declined.$uid" 2>>"$LOG"$' "$f")" = 1 ] \
    || why="$why roam-in no longer clears the declined-this-session list;"
  verdict "W1 login declines; odrestore declines only on a first install (a hold or the session's materialised record)"

  # P1 (NWP-20261012-08): roamd's six SMS-role permissions are exactly the chooser's PermDeclines.SMS_ROLE_PERMS. The
  # chooser re-declines a candidate's six, and its capture carries their decline; a name on one side only is a
  # permission one half leaves to the role and the other does not.
  why=""
  if [ -f "$PDJ" ]; then
    local rl jl
    rl=$(grep -E '^ +android\.permission\.READ_SMS\|' "$fn" | tr -d ' )' | tr '|' '\n' | sort)
    jl=$(sed -n '/static final String\[\] SMS_ROLE_PERMS = {/,/};/p' "$PDJ" | grep -o '"android\.permission\.[A-Z_]*"' | tr -d '"' | sort)
    [ -n "$rl" ] && [ "$rl" = "$jl" ] || why="$why roamd [$(echo $rl)] != PermDeclines.SMS_ROLE_PERMS [$(echo $jl)];"
    [ "$(printf '%s\n' "$rl" | grep -c .)" = 6 ] || why="$why roamd's list is not six names;"
  else
    why="$why no PermDeclines.java at $PDJ;"
  fi
  verdict "P1 roamd's SMS-role permissions are PermDeclines.SMS_ROLE_PERMS, all six"

  for sh in $SHELLS; do
    why=""; run "$fn" "$sh" "" - "com.foo flags:user-set:$NOTIF$NL" com.foo
    has "revoke com.foo $NOTIF"; has "flags com.foo $NOTIF user-set"; before "^flags com.foo $NOTIF " "^revoke com.foo $NOTIF\$"
    hasnt "grant com.foo $NOTIF"; hasnt "grant com.foo flags:user-set:$NOTIF"
    logsays "+ 1 declined kept (0 refused, 0 grant(s) withheld, declines on)"; clean
    verdict "D1 a declined permission: user-set FIRST, then revoked, never granted"

    why=""; run "$fn" "$sh" "" - "com.foo flags:user-set,user-fixed:$NOTIF${NL}com.foo flags:user-fixed:$CAM$NL" com.foo
    has "flags com.foo $NOTIF user-set user-fixed"; has "flags com.foo $CAM user-fixed"
    count 1 "revoke com.foo $NOTIF"; count 1 "revoke com.foo $CAM"
    logsays "+ 2 declined kept"; clean
    verdict "D2 user-set,user-fixed and user-fixed alone pass as pm flag words"

    why=""; run "$fn" "$sh" "" - "com.foo $LOC${NL}com.foo $CAM${NL}com.bar $CAM${NL}com.foo flags:user-set:$NOTIF${NL}com.bar $NOTIF$NL" com.foo com.bar
    before '^grant ' '^flags '; before '^grant ' '^revoke com.foo'
    has "grant com.foo $LOC"; has "cmd appops set --user $UIDV com.foo FINE_LOCATION foreground"
    has "grant com.bar $NOTIF"; hasnt "revoke com.bar $NOTIF"
    clean
    verdict "D3 every grant (lines AND the INTERNET default) runs before any decline"

    why=""; run "$fn" "$sh" "" - "com.foo $NOTIF${NL}com.foo flags:user-set:$NOTIF${NL}com.foo $NOTIF$NL" com.foo
    hasnt "grant com.foo $NOTIF"; has "flags com.foo $NOTIF user-set"
    logsays "2 grant(s) withheld"
    clean
    verdict "D4 a grant line for a declined pair, before or after it, is withheld"

    why=""; run "$fn" "$sh" "" - "com.foo $CAM${NL}com.foo flags:user-set:$NOTIF$NL" com.foo
    has "grant com.foo $CAM"; has "cmd appops set --user $UIDV com.foo CAMERA foreground"
    hasnt "revoke com.foo $CAM"; ! grep -q "^flags com.foo $CAM" "$D/calls" || why="$why CAMERA got flags;"
    clean
    verdict "D5 a granted permission beside a declined one is unchanged"

    why=""; run "$fn" "$sh" "" - "com.foo flags:review-required:$NOTIF${NL}com.foo flags:user-set,revoked-compat:$CAM${NL}com.foo flags:user-set:$INET${NL}com.foo flags:user-set:--user${NL}-x flags:user-set:$NOTIF${NL}com.foo flags:user-set${NL}com.foo flags:user-set:a\$b${NL}com.foo flags::$NOTIF${NL}com.foo flags:user-set:$LOC$NL" com.foo
    count 1 "flags com.foo $LOC user-set"; count 1 "revoke com.foo $LOC"
    [ "$(grep -c '^flags ' "$D/calls")" = 1 ] || why="$why want only the LOC flags call, got: $(grep '^flags ' "$D/calls" | tr '\n' ';');"
    [ "$(grep -c '^revoke ' "$D/calls")" = 1 ] || why="$why want only the LOC revoke, got: $(grep '^revoke ' "$D/calls" | tr '\n' ';');"
    hasnt "revoke com.foo $INET"; has "grant com.foo $INET"
    logsays "+ 1 declined kept (8 refused,"; clean
    verdict "D6 the allowlist refuses other flags, INTERNET, option-shaped and malformed names"

    why=""; run "$fn" "$sh" "com.foo" 1 "com.bar flags:user-set:$NOTIF${NL}com.foo flags:user-set:$CAM$NL" com.foo com.bar
    has "flags com.foo $CAM user-set"; has "revoke com.foo $CAM"; hasnt "revoke com.bar $NOTIF"
    ! grep -q '^flags com.bar' "$D/calls" || why="$why com.bar declined under a com.foo filter;"
    logsays "[roamd] GRANT (com.foo) -> 0 perms + 1 INTERNET default(s) + 1 declined kept (0 refused, 0 grant(s) withheld, declines on)"; clean
    verdict "D7 pkgfilter + DECLINES=1 (odrestore, a first materialise): only that package is declined"

    why=""; run "$fn" "$sh" "" - "com.foo flags:user-set:android.permission.FIXED_X$NL" com.foo
    has "revoke com.foo android.permission.FIXED_X"; has "flags com.foo android.permission.FIXED_X user-set"
    hasnt "grant com.foo android.permission.FIXED_X"; logsays "+ 1 declined kept"; clean
    verdict "D8 a refused revoke still leaves the flag (it only suppresses a prompt)"

    why=""; run "$fn" "$sh" "" - "com.foo $CAM$NL" com.foo
    nodecline
    logsays "-> 1 perms + 1 INTERNET default(s) + 0 declined kept (0 refused, 0 grant(s) withheld, declines on)"; clean
    verdict "D9 no flags line: no revoke, no flags, the log says 0"

    why=""; run "$fn" "$sh" "com.foo" - "com.foo flags:user-set:$NOTIF${NL}com.foo $CAM$NL" com.foo
    nodecline; has "grant com.foo $CAM"; hasnt "grant com.foo $NOTIF"
    logsays "(0 refused, 0 grant(s) withheld, declines off)"; clean
    verdict "D10 pkgfilter with no DECLINES (an install-heal, an update): no revoke, no flags"

    why=""; run "$fn" "$sh" "com.foo" 0 "com.foo flags:user-set:$NOTIF$NL" com.foo
    nodecline; logsays "declines off"; clean
    verdict "D11 pkgfilter + DECLINES=0 (odrestore found no hold): no revoke, no flags"

    why=""; run "$fn" "$sh" "" - "com.foo $NOTIF${NL}com.foo flags:user-fixed:$NOTIF${NL}com.foo $CAM${NL}com.foo flags:user-set,user-fixed:$CAM$NL" com.foo
    hasnt "grant com.foo $NOTIF"; hasnt "grant com.foo $CAM"
    has "flags com.foo $NOTIF user-fixed"; has "flags com.foo $CAM user-set user-fixed"
    logsays "2 grant(s) withheld"; clean
    verdict "D12 a grant line is withheld by the user-fixed and user-set,user-fixed forms too"

    many=""; i=0
    while [ "$i" -lt 14 ]; do many="${many}com.foo flags:user-set:android.permission.P$i$NL"; i=$((i+1)); done
    why=""; SLOW=0.3 run "$fn" "$sh" "" - "$many" com.foo
    [ "$(grep -c '^flags com.foo android.permission.P[0-9]* user-set$' "$D/calls")" = 14 ] || why="$why not all 14 declines applied;"
    mx=$(sort -n "$D/conc" | tail -1); mx=${mx:-0}
    [ "$mx" -ge 1 ] && [ "$mx" -le 6 ] || why="$why $mx set-permission-flags in flight at once, the cap is 6;"
    logsays "+ 14 declined kept"; clean
    verdict "D13 at most 6 declines in flight"

    why=""; CALLS="grant_perms_for $UIDV com.foo 1${NL}grant_perms_for $UIDV com.foo 1" \
      run "$fn" "$sh" "" - "com.foo flags:user-set:$NOTIF${NL}com.foo $CAM$NL" com.foo
    count 1 "flags com.foo $NOTIF user-set"; count 1 "revoke com.foo $NOTIF"; count 1 "grant com.foo $CAM"
    [ "$(grep -c 'declines on' "$D/log")" = 1 ] && [ "$(slog 2 | grep -c 'declines off')" = 1 ] \
      || why="$why want 'declines on' then 'declines off', log: $(tr '\n' ';' < "$D/log");"
    clean
    verdict "D14 an update that finds a KEPT hold (DECLINES=1 again) does not decline a second time"

    why=""; CALLS="grant_perms_for $UIDV com.foo 1${NL}grant_perms_for $UIDV com.foo 1${NL}grant_perms_for $UIDV com.bar 1" \
      run "$fn" "$sh" "" - "com.foo $CAM${NL}com.bar flags:user-set:$NOTIF$NL" com.foo com.bar
    [ "$(slog 2 | grep -c 'declines off')" = 1 ] || why="$why a first pass with no flags line was not recorded;"
    [ "$(slog 3 | grep -c 'declines on')" = 1 ] || why="$why another package's first pass was skipped;"
    count 1 "flags com.bar $NOTIF user-set"
    clean
    verdict "D15 a first pass is recorded even with no flags line, and only for its own package"

    why=""; CALLS="grant_perms_for $UIDV${NL}grant_perms_for $UIDV com.foo 1" \
      run "$fn" "$sh" "" - "com.foo flags:user-set:$NOTIF$NL" com.foo
    count 2 "flags com.foo $NOTIF user-set"
    [ "$(slog 2 | grep -c 'declines on')" = 1 ] || why="$why the login pass marked the package (a placeholder at login has nothing to decline);"
    clean
    verdict "D16 the login pass records nothing: the first materialise still declines"

    why=""; run "$fn" "$sh" "" - "com.nowhere.chooser flags:user-set:$NOTIF${NL}com.foo flags:user-set:$NOTIF$NL" com.foo
    ! grep -q '^flags com.nowhere.chooser\|^revoke com.nowhere.chooser' "$D/calls" || why="$why the chooser was declined;"
    has "flags com.foo $NOTIF user-set"; logsays "(1 refused,"; clean
    verdict "D17 the chooser itself is never a decline target"

    # NWP-20261012-08: the six the SMS role grants are left alone for the two apps that can hold the role after the sign-in
    # apply -- Messaging and the recorded app -- and declined for everyone else; their other declines are applied.
    sms6="flags:user-set:$RS${NL}PKG flags:user-fixed:$RV${NL}PKG flags:user-set,user-fixed:$RM${NL}PKG flags:user-set:$RW${NL}PKG flags:user-set:$SS${NL}PKG flags:user-set:$CB$NL"
    why=""; run "$fn" "$sh" "" - "$MSG ${sms6//PKG/$MSG}$MSG flags:user-set:$NOTIF${NL}$MSG flags:user-fixed:$RC${NL}com.bar ${sms6//PKG/com.bar}" $MSG com.bar
    for q in $RS $RV $RM $RW $SS $CB; do
      ! grep -q "^flags $MSG $q \|^revoke $MSG $q\$" "$D/calls" || why="$why Messaging's $q declined;"
      grep -q "^flags com.bar $q " "$D/calls" && grep -qx "revoke com.bar $q" "$D/calls" || why="$why com.bar's $q not declined;"
    done
    has "flags $MSG $NOTIF user-set"; has "revoke $MSG $NOTIF"; has "flags $MSG $RC user-fixed"; has "revoke $MSG $RC"
    logsays "+ 8 declined kept (0 refused, 0 grant(s) withheld, declines on) + 6 left to the SMS role (user $UIDV)"; clean
    verdict "D18 no SMS record: Messaging keeps the six SMS permissions, not its other declines; another app keeps none"

    why=""; SMSREC="app=com.foo$NL" run "$fn" "$sh" "" - "com.foo ${sms6//PKG/com.foo}com.foo flags:user-set:$CAM${NL}$MSG flags:user-set:$RS${NL}com.bar flags:user-set:$RS${NL}com.dialer flags:user-set:$RS$NL" com.foo $MSG com.bar com.dialer
    for q in $RS $RV $RM $RW $SS $CB; do
      ! grep -q "^flags com.foo $q \|^revoke com.foo $q\$" "$D/calls" || why="$why the recorded app's $q declined;"
    done
    hasnt "revoke $MSG $RS"; has "flags com.foo $CAM user-set"; has "revoke com.foo $CAM"
    has "revoke com.bar $RS"; has "revoke com.dialer $RS"
    logsays "+ 3 declined kept (0 refused, 0 grant(s) withheld, declines on) + 7 left to the SMS role"; clean
    verdict "D19 the recorded SMS app AND Messaging (its stand-in) keep the six; nobody else, the dialer included"

    why=""; SMSREC="app=com.foo$NL" run "$fn" "$sh" "com.foo" 1 "com.foo flags:user-set:$RS${NL}com.foo flags:user-set:$CAM$NL" com.foo
    hasnt "revoke com.foo $RS"; ! grep -q "^flags com.foo $RS" "$D/calls" || why="$why READ_SMS flagged;"
    has "revoke com.foo $CAM"; logsays "declines on) + 1 left to the SMS role"; clean
    verdict "D20 a first materialise of the recorded SMS app leaves its SMS permissions to the role too"

    why=""; SMSREC="app=com.foo$NL" run "$fn" "$sh" "" - "com.foo $RS${NL}com.foo flags:user-set:$RS$NL" com.foo
    hasnt "grant com.foo $RS"; nodecline; logsays "1 grant(s) withheld, declines on) + 1 left to the SMS role"; clean
    verdict "D21 a grant line beside an exempt decline is still withheld: the exemption only leaves it to the role"

    # The record is read as PermDeclines.recordedSmsApp + SmsRoleRoam.parseSmsRecord read it: nothing over 4096
    # bytes, the first `app=` line, trimmed of every char <= U+0020 (String.trim), isPackageName. Each case:
    # <label>|<record>|<package that declined READ_SMS>|<exempt: yes/no>.
    for rec in "blanks and CR trimmed|app= com.foo $CR$NL|com.foo|yes" \
               "TABs trimmed|app=${TAB}com.foo$TAB$NL|com.foo|yes" \
               "other control characters trimmed (U+0001, U+000B, U+001F)|app=${SOH}com.foo$VT$US$NL|com.foo|yes" \
               "DEL is not trimmed: the name is invalid|app=com.foo$DEL$NL|com.foo|no" \
               "4096 bytes is read|app=com.foo$NL$F4083$NL|com.foo|yes" \
               "4097 bytes is no record|app=com.foo$NL$F4083#$NL|com.foo|no" \
               "an unterminated line after another key|x=1${NL}app=com.foo|com.foo|yes" \
               "the FIRST app= line decides, an invalid one is none|app=com..foo${NL}app=com.foo$NL|com.foo|no" \
               "no dot|app=foo$NL|foo|no" "an empty segment|app=com..foo$NL|com..foo|no" \
               "a trailing dot|app=com.foo.$NL|com.foo.|no" "255 characters|app=$L255$NL|$L255|yes" \
               "256 characters|app=${L255}0$NL|${L255}0|no" "a commented line|#app=com.foo$NL|com.foo|no" \
               "another key's value|xapp=com.foo$NL|com.foo|no" "an empty file||com.foo|no"; do
      lbl="${rec%%|*}"; rv="${rec#*|}"; want="${rv##*|}"; rv="${rv%|*}"; pk="${rv##*|}"; rv="${rv%|*}"
      why=""; SMSREC="$rv" run "$fn" "$sh" "" - "$pk flags:user-set:$RS$NL" "$pk"
      if [ "$want" = yes ]; then nodecline; else has "revoke $pk $RS"; fi
      clean
      verdict "D22 the SMS record: $lbl -> exempt=$want"
    done

    # T0-T3 (NWP-20261121-07): NWP-20261114-09 put each truncation of this function in a subshell, because a failed
    # redirection on the special builtin `:` ends a POSIX shell (mksh on the device), and roamd's grant op then ends
    # before its reply is written. Each case puts a DIRECTORY at one target, which refuses the truncation as root too,
    # and shows the function returns past it, logs its outcome line and grants as the writable control does. bash
    # runs as `bash --posix`: it obeys that rule only in POSIX mode.
    why=""; POSIXB=1 CALLS="$gcall" run "$fn" "$sh" "" - "$gcont" com.foo com.bar
    reached; logsays "[roamd] GRANT -> 1 perms + 2 INTERNET default(s) + 1 declined kept"
    has "grant com.foo $CAM"; has "grant com.bar $INET"; has "flags com.foo $NOTIF user-set"; has "revoke com.foo $NOTIF"
    gref=$(sort "$D/calls")
    clean
    verdict "T0 control, every target writable: grant_perms_for returns, logs and grants"

    for t in ".grantn T1" ".grantok T2" ".grantd T3"; do
      tn="${t% *}"; tag="${t#* }"
      why=""; UNW="$tn" POSIXB=1 CALLS="$gcall" run "$fn" "$sh" "" - "$gcont" com.foo com.bar
      reached; logsays "[roamd] GRANT -> "; logsays " perms + "
      [ "$(sort "$D/calls")" = "$gref" ] || why="$why the calls [$(sort "$D/calls" | tr '\n' ';')] are not the control's [$(printf '%s' "$gref" | tr '\n' ';')];"
      clean
      verdict "$tag \$STATE/$tn cannot be written: grant_perms_for returns, logs and grants as the control does"
    done

    why=""; UNW=.grantn POSIXB=1 CALLS="rm -f \"\$TROOT/$PFREL\"${NL}$gcall" run "$fn" "$sh" "" - "$gcont" com.foo com.bar
    reached; logsays "[roamd] GRANT -> 0 perms (no file, user $UIDV)"
    clean
    verdict "T1n \$STATE/.grantn cannot be written and there is no nowhere-perms: the no-file branch returns"
  done
  command rm -f "$fn"
  [ -n "$quiet" ] || printf '  -- %d ok, %d failed\n' "$p" "$x"
  [ "$x" -eq 0 ] && return 0 || return 1
}

echo "grant_perms_for declined permissions: $SUT"
echo "shells: $SHELLS"
suite "$SUT"; rc=$?
[ "$rc" = 2 ] && exit 2          # the harness could not extract, rewrite or parse the function
[ "$rc" = 0 ] || FAILED=1

if [ "$MUTATE" = yes ]; then
  echo
  echo "mutations (each must CONVICT):"
  mtmp=$(mktemp -d -p "$W")
  mutate() {  # <label> <sed program>
    local label="$1" prog="$2" mf="$mtmp/r.sh" r
    if ! sed "$prog" "$SUT" > "$mf"; then printf '  ERR   %-64s sed program failed\n' "$label"; MFAIL=1; return; fi
    if cmp -s "$SUT" "$mf"; then printf '  SKIP  %-64s mutation was a NO-OP\n' "$label"; MFAIL=1; return; fi
    suite "$mf" quiet >/dev/null 2>&1; r=$?
    case "$r" in
      0) printf '  XX    %-64s SURVIVED\n' "$label"; MFAIL=1 ;;
      1) printf '  ok    %-64s convicted\n' "$label" ;;
      *) printf '  ERR   %-64s harness error (rc=%s), not a conviction\n' "$label" "$r"; MFAIL=1 ;;
    esac
  }
  # mutate_each <label> <tags> <sed program>: one line changed, and every tag has its own FAIL line under every shell.
  mutate_each() {
    local label="$1" tags="$2" prog="$3" mf="$mtmp/e.sh" of="$mtmp/e.out" r s tg alive=""
    if ! sed "$prog" "$SUT" > "$mf"; then printf '  ERR   %-64s sed program failed\n' "$label"; MFAIL=1; return; fi
    if cmp -s "$SUT" "$mf"; then printf '  SKIP  %-64s mutation was a NO-OP\n' "$label"; MFAIL=1; return; fi
    r=$(diff "$SUT" "$mf" | grep -c '^>')
    [ "$r" = 1 ] || { printf '  ERR   %-64s changed %s lines, want 1\n' "$label" "$r"; MFAIL=1; return; }
    suite "$mf" > "$of" 2>&1; r=$?
    [ "$r" = 1 ] || { printf '  ERR   %-64s suite rc=%s, not a conviction\n' "$label" "$r"; MFAIL=1; return; }
    for tg in $tags; do
      for s in $SHELLS; do
        grep -q "^  FAIL  $tg .*\[$s\] --" "$of" || alive="$alive $tg[$s]"
      done
    done
    if [ -n "$alive" ]; then printf '  XX    %-64s SURVIVED:%s\n' "$label" "$alive"; MFAIL=1
    else printf '  ok    %-64s convicted [%s] under [%s]\n' "$label" "$tags" "$(echo $SHELLS)"; fi
  }
  # NWP-20261121-07: each truncation back in its bare form, scoped to grant_perms_for and its one line.
  mutate_each 't1 the .grantn truncation is bare again' 'T1 T1n' \
    '/^grant_perms_for() {$/,/^}$/s/^  _gn="\$STATE\/\.grantn"; ( : > "\$_gn" ) 2>\/dev\/null$/  _gn="$STATE\/.grantn"; : > "$_gn" 2>\/dev\/null/'
  mutate_each 't2 the .grantok truncation is bare again' 'T2' \
    '/^grant_perms_for() {$/,/^}$/s/^  ( : > "\$_gok" ) 2>\/dev\/null$/  : > "$_gok" 2>\/dev\/null/'
  mutate_each 't3 the .grantd truncation is bare again' 'T3' \
    '/^grant_perms_for() {$/,/^}$/s/^  _gd="\$STATE\/\.grantd"; ( : > "\$_gd" ) 2>\/dev\/null; _gbg=0$/  _gd="$STATE\/.grantd"; : > "$_gd" 2>\/dev\/null; _gbg=0/'
  mutate 'm1 the per-line loop has no flags: arm (falls through to pm grant)' \
    '/^      flags:\*)$/,/^        continue;;$/d'
  mutate 'm2 the grant-withhold match is deleted' \
    '/^      \*"\${NL}\${gpkg} flags:user-set:\${gperm}\${NL}"\*|/,/^        _dskip=/d'
  mutate 'm3 the flag-name allowlist accepts anything' \
    's/^    case "\$_dfl" in user-set|user-fixed|user-set,user-fixed) ;; \*)/    case "$_dfl" in *) ;; __never)/'
  mutate 'm4 INTERNET is no longer refused' \
    's/|\*\[!A-Za-z0-9._\]\*|android.permission.INTERNET)/|*[!A-Za-z0-9._]*)/'
  mutate 'm5 the package-name check is deleted' \
    '/^    case "\$gpkg" in ""|\[!A-Za-z\]\*|\*\[!A-Za-z0-9._\]\*|com.nowhere.chooser) _drej=/d'
  mutate 'm6 the revoke after the flags is deleted' \
    '/^      pm revoke --user "\$uid" "\$gpkg" "\$_dperm" <\/dev\/null >\/dev\/null 2>&1$/d'
  mutate 'm7 the declined pass ignores pkgfilter' \
    '/^    case "\$gperm" in flags:\*) ;; \*) continue;; esac$/{n;d;}'
  mutate 'm8 the revoke runs BEFORE the flags' \
    '/^      pm revoke --user "\$uid" "\$gpkg" "\$_dperm" <\/dev\/null >\/dev\/null 2>&1$/d; s/^    { if \[ "\$_dfl" = user-set,user-fixed \]; then$/    { pm revoke --user "$uid" "$gpkg" "$_dperm" <\/dev\/null >\/dev\/null 2>\&1\n      if [ "$_dfl" = user-set,user-fixed ]; then/'
  mutate 'm9 the declined pass runs BEFORE the grants (inside the per-line loop)' \
    's/^        # NWP-20261012-05: a DECLINED permission. Applied in its own pass at the end of this function, after every$/        pm set-permission-flags --user "$uid" "$gpkg" "${gperm##*:}" user-set <\/dev\/null >\/dev\/null 2>\&1\n&/'
  mutate 'm10 DECLINES is ignored: every package-filtered call declines' \
    's/^  elif \[ "\${3:-}" = 1 \]; then$/  elif true; then/'
  mutate 'm11 a package-filtered call never declines, even a first materialise' \
    's/^  elif \[ "\${3:-}" = 1 \]; then$/  elif false; then/'
  mutate 'm12 odrestore stops passing its first-install flag' \
    's/^      grant_perms_for "\$uid" "\$pkg" "\$_first" \${odbatch:+"\$odbatch"}$/      grant_perms_for "$uid" "$pkg"/'
  mutate 'm13 the declined-this-session list is not consulted' \
    's/^    if grep -qxF -- "\$pkgfilter" "\$_dmark" 2>\/dev\/null; then$/    if false; then/'
  mutate 'm14 the declined-this-session list is not written' \
    's/^      _dok=1; echo "\$pkgfilter" >> "\$_dmark" 2>\/dev\/null /      _dok=1 /'
  mutate 'm15 roam-in no longer clears the list' \
    '/^      rm -f "\$STATE\/.declined.\$uid" 2>>"\$LOG"$/d'
  mutate 'm16 the chooser is accepted as a decline target' \
    's/|\*\[!A-Za-z0-9._\]\*|com.nowhere.chooser) _drej=/|*[!A-Za-z0-9._]*) _drej=/'
  mutate 'm17 roam-in no longer clears the session materialised record' \
    '/^      rm -f "\$USERDIR\/com.nowhere.chooser\/files\/nowhere-od-materialised" 2>>"\$LOG"$/d'
  mutate 'X1 the withhold match loses its user-fixed form' \
    's/|\*"\${NL}\${gpkg} flags:user-fixed:\${gperm}\${NL}"\*|/|/'
  mutate 'X2 the withhold match loses its user-set,user-fixed form' \
    's/|\*"\${NL}\${gpkg} flags:user-set,user-fixed:\${gperm}\${NL}"\*)$/)/'
  mutate 'X3 the declined pass is not capped at 6 in flight' \
    '/^  _gd="\$STATE\/.grantd"/,/^  done < "\$PF"$/s/\[ "\$_gbg" -ge 6 \]/[ "$_gbg" -ge 60 ]/'
  # NWP-20261012-08: the SMS app keeps its SMS permissions.
  mutate 's1 the SMS-role exemption is deleted' \
    '/^    if \[ "\$gpkg" = com.android.messaging \] || \[ "\$gpkg" = "\$_smsapp" \]; then$/,/^    fi$/d'
  mutate 's2 Messaging (the default and stand-in) is not exempt' \
    's/^    if \[ "\$gpkg" = com.android.messaging \] || \[ "\$gpkg" = "\$_smsapp" \]; then$/    if [ "$gpkg" = "$_smsapp" ]; then/'
  mutate 's3 the recorded SMS app is not exempt' \
    's/^    if \[ "\$gpkg" = com.android.messaging \] || \[ "\$gpkg" = "\$_smsapp" \]; then$/    if [ "$gpkg" = com.android.messaging ]; then/'
  mutate 's4 every app is exempt (the dialer and any READ_SMS app too)' \
    's/^    if \[ "\$gpkg" = com.android.messaging \] || \[ "\$gpkg" = "\$_smsapp" \]; then$/    if true; then/'
  mutate 's5 SEND_SMS is not exempt' \
    's/|android.permission.RECEIVE_WAP_PUSH|android.permission.SEND_SMS|/|android.permission.RECEIVE_WAP_PUSH|/'
  mutate 's5b READ_CELL_BROADCASTS is not exempt' \
    's/|android.permission.SEND_SMS|android.permission.READ_CELL_BROADCASTS)$/|android.permission.SEND_SMS)/'
  mutate 's6 READ_CONTACTS is exempt too (the scope widened)' \
    's/|android.permission.READ_CELL_BROADCASTS)$/|android.permission.READ_CELL_BROADCASTS|android.permission.READ_CONTACTS)/'
  mutate 's7 the LAST app= line wins' \
    's/app=\*) _smsapp="\${_sl#app=}"; break;;/app=*) _smsapp="${_sl#app=}";;/'
  mutate 's8 the record is not trimmed' \
    '/_smsapp="\${_smsapp#?}";;$/d; /_smsapp="\${_smsapp%?}";;$/d'
  mutate 's9 a record with no dot is accepted' \
    '/^  case "\$_smsapp" in \*\.\*) ;; \*) _smsapp="";; esac$/d'
  mutate 's10 the record name check is deleted' \
    '/^  case "\$_smsapp" in \.\*|\*\.|\*\.\.\*|\*\[!A-Za-z0-9._\]\*) _smsapp="";; esac$/d'
  mutate 's11 the record has no length limit' \
    '/^  \[ "\${#_smsapp}" -le 255 \] || _smsapp=""$/d'
  mutate 's12 the record is read from the wrong file' \
    's#_smsf="\${PF%/\*}/nowhere-sms"#_smsf="${PF%/*}/nowhere-sms.x"#'
  mutate 's14 TAB is not trimmed (M13)' \
    's/\\010\\011\\012/\\010\\012/'
  mutate 's15 only blanks are trimmed, not the other control characters' \
    's/^  _ws=\$(printf .*$/  _ws=$(printf " \\011\\015")/'
  mutate 's16 a record over 4096 bytes is read' \
    's/ && \[ "\$((_sz + 0))" -le 4096 \]; then$/; then/'
  mutate 's17 the cap is one byte short' \
    's/\[ "\$((_sz + 0))" -le 4096 \]/[ "$((_sz + 0))" -lt 4096 ]/'
  mutate 's13 an unterminated record line is ignored' \
    's/while IFS= read -r _sl || \[ -n "\$_sl" \]; do/while IFS= read -r _sl; do/'
  echo
  [ "${MFAIL:-0}" = 0 ] && echo "ALL MUTATIONS BEHAVED" || { echo "PROBLEM: a mutation did not behave"; FAILED=1; }
  command rm -rf "$mtmp"
fi

exit "${FAILED:-0}"
