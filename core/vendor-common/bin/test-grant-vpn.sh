#!/usr/bin/env bash
# test-grant-vpn.sh [--mutate] -- the sign-in's first always-on VPN apply rides the grant op (NWP-20261210-06,
# backlog "A nearly empty profile takes about 85 s from submit to home; target under 60 s", cause (6)).
#
# Every vpnup try before the chooser's install-existing answered NOTREADY and cost a worker start, which delayed the
# grant. Now handleRoamIn expects the grant (grantVpn.expect), handleGrantPerms flags it (roam.req line 7 = vpn),
# roamd's grant arm runs vpn_apply LAST and leaves its answer in $STATE/.grantvpn.<uid> before its OK, and
# retryVpnup takes an OK answer with no vpnup run of its own.
#
# The Go half runs grant_vpn_test.go and grant_vpn_signin_test.go (TestGrantVpn*; the second builds on origin/main
# alone, so its assertions fail there by --- FAIL). The shell half extracts the REAL grant arm, _ms and _tlog from
# nowhere_roamd.sh BY ANCHOR and runs it under every shell found (bash sh, plus dash and mksh when installed), with
# every helper it calls stubbed to append to a call log and vpn_apply stubbed to log and print a token. Cases:
#   A  srcunit vpn: vpn_apply runs once, after grant_perms_for and acct_reload
#   B  srcunit vpn: .grantvpn.<uid> holds the token, and it exists when RES is written
#   C  RES is exactly OK
#   D  srcunit '': no vpn_apply, no .grantvpn file
#   E  srcunit '': a stale .grantvpn.<uid> is gone after the run
#   F  a token with junk characters, a second line or more than 40 characters is cut to the safe set
#   G  roam.log carries one TIMING grant-vpn line
# --mutate breaks each guard in turn on a COPY (the roamd script or the Go package); each mutant must be CONVICTED by
# its named assertion (the shell ones under every shell; the Go ones by a real `--- FAIL`). One that fails to apply or
# compile is a failure. A comment edit (the control) must survive.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W"
AGENT=../../agent
. "$AGENT/suite-report.sh"
ROAMD=${ROAMD:-nowhere_roamd.sh}
[ -f "$ROAMD" ] || { echo "no such script: $ROAMD" >&2; exit 2; }
SHELLS="bash sh"
for s in dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done

out=$(cd "$AGENT" && go test -count=1 -timeout 180s -run 'TestGrantVpn' -v . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1

# extract <script> <out> -> 0 when every anchor was found
extract() {
  local f="$1" out="$2" piece fn
  rm -f "$out"
  for fn in _ms _tlog; do
    piece=$(sed -n "/^$fn() /p" "$f")
    [ -n "$piece" ] || return 1
    printf '%s\n' "$piece" >> "$out"
  done
  piece=$(sed -n '/^  grant)$/,/^    ;;$/p' "$f" | sed '1d;$d')
  [ -n "$piece" ] || return 1
  printf '%s\n' "$piece" >> "$out"
}

# shellsuite <roamd> <shell> [quiet] [only] -> 0 when every case (or only the cases named in <only>) behaved
shellsuite() {
  local f="$1" sh_="$2" quiet="${3:-}" only="${4:-ABCDEFG}" p=0 x=0 body T got n a b c
  ok() { p=$((p+1)); [ -n "$quiet" ] || printf '  ok    [%s] %s\n' "$sh_" "$1"; }
  no() {
    case "$only" in *"${1%% *}"*) x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  [%s] %s\n' "$sh_" "$1" ;; esac
  }
  body=$(mktemp -p "$W") || return 2
  extract "$f" "$body" || { x=1; [ -n "$quiet" ] || echo "  FAIL  EXTRACTION -- _ms, _tlog or the grant arm is missing in $f"; return 1; }

  # prep <dir> <srcunit> <vpn token> -> <dir>/run.sh, the re-rooted arm behind its variables and stubs. The RES write
  # is instrumented to note whether .grantvpn.<uid> exists at that moment.
  prep() {
    local d="$1" fn
    mkdir -p "$d/state" "$d/data/user/10"
    {
      printf "uid=10; srcunit='%s'; LOG='%s'; STATE='%s'; RES='%s'; CALLS='%s'; TOKEN='%s'\n" "$2" "$d/log" "$d/state" \
        "$d/res" "$d/calls" "$3"
      printf '%s\n' "ACCT_AUTH_PKG=com.google.android.gms; PLAY_STORE_PKG=com.android.vending"
      for fn in home_pin nav_apply aod_apply a11y_apply autofill_apply shortcut_apply ks_in_dir keystore_register_all \
        grant_perms_for acct_reload sync_apply am pm; do
        printf '%s() { echo %s >> "$CALLS"; return 0; }\n' "$fn" "$fn"
      done
      printf '%s\n' 'vpn_apply() { echo "vpn_apply $1" >> "$CALLS"; printf "%b" "$TOKEN"; }'
      sed -e "s#/data/#$d/data/#g" \
        -e 's#^    echo "OK" > "\$RES"$#&; if [ -e "$STATE/.grantvpn.$uid" ]; then : > "$STATE/../seen-at-res"; fi#' "$body"
    } > "$d/run.sh"
  }

  # ---- flagged: srcunit vpn ----
  T=$(mktemp -d -p "$W") || return 2
  prep "$T" vpn 'OK APPLIED'
  "$sh_" "$T/run.sh" >/dev/null 2>&1
  n=$(grep -c '^vpn_apply 10$' "$T/calls" 2>/dev/null)
  a=$(grep -n '^grant_perms_for$' "$T/calls" 2>/dev/null | cut -d: -f1)
  b=$(grep -n '^acct_reload$' "$T/calls" 2>/dev/null | cut -d: -f1)
  c=$(grep -n '^vpn_apply 10$' "$T/calls" 2>/dev/null | cut -d: -f1)
  if [ "$n" = 1 ] && [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ "$c" -gt "$a" ] && [ "$c" -gt "$b" ]; then
    ok "A vpn_apply ran once, after grant_perms_for and acct_reload"
  else
    no "A vpn_apply ran ${n:-0} time(s) at call ${c:-none} (grant_perms_for ${a:-none}, acct_reload ${b:-none})"
  fi
  got=$(cat "$T/state/.grantvpn.10" 2>/dev/null)
  if [ "$got" = 'OK APPLIED' ] && [ -e "$T/seen-at-res" ] && [ ! -e "$T/state/.grantvpn.10.tmp" ]; then
    ok "B .grantvpn.10 holds the token and existed when RES was written"
  else
    no "B .grantvpn.10 is '$got', at RES: $([ -e "$T/seen-at-res" ] && echo present || echo absent), want the token, present"
  fi
  got=$(cat "$T/res" 2>/dev/null)
  [ "$got" = OK ] && ok "C RES is exactly OK" || no "C RES is '$got', want OK"
  n=$(grep -cE '^\[roamd\] TIMING grant-vpn [0-9]+ms \(user 10\) ' "$T/log" 2>/dev/null)
  [ "$n" = 1 ] && ok "G roam.log has one TIMING grant-vpn line" || no "G ${n:-0} TIMING grant-vpn lines, want 1"

  # ---- unflagged: srcunit '' over a stale answer ----
  T=$(mktemp -d -p "$W") || return 2
  prep "$T" '' 'OK APPLIED'
  "$sh_" "$T/run.sh" >/dev/null 2>&1
  n=$(grep -c '^vpn_apply' "$T/calls" 2>/dev/null)
  if [ "$n" = 0 ] && [ ! -e "$T/state/.grantvpn.10" ] && [ "$(cat "$T/res" 2>/dev/null)" = OK ]; then
    ok "D srcunit '': no vpn_apply, no .grantvpn file, OK"
  else
    no "D srcunit '': vpn_apply ran ${n:-0} time(s), .grantvpn.10 $([ -e "$T/state/.grantvpn.10" ] && echo exists || echo absent)"
  fi
  T=$(mktemp -d -p "$W") || return 2
  prep "$T" '' 'OK APPLIED'
  printf 'OK STALE\n' > "$T/state/.grantvpn.10"
  "$sh_" "$T/run.sh" >/dev/null 2>&1
  [ ! -e "$T/state/.grantvpn.10" ] && ok "E a stale .grantvpn.10 is gone after an unflagged grant" \
    || no "E the stale .grantvpn.10 survived: '$(cat "$T/state/.grantvpn.10" 2>/dev/null)'"

  # ---- the token is cut to the safe set ----
  T=$(mktemp -d -p "$W") || return 2
  prep "$T" vpn 'OK AP;PL$I`ED/\nsecond line'
  "$sh_" "$T/run.sh" >/dev/null 2>&1
  got=$(cat "$T/state/.grantvpn.10" 2>/dev/null)
  T=$(mktemp -d -p "$W") || return 2
  prep "$T" vpn 'OK AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
  "$sh_" "$T/run.sh" >/dev/null 2>&1
  n=$(cat "$T/state/.grantvpn.10" 2>/dev/null)
  if [ "$got" = 'OK APPLIED' ] && [ "${#n}" = 40 ] && [ "$(printf '%s' "$n" | cut -c 1-3)" = 'OK ' ]; then
    ok "F junk cut: '$got'; a long token cut to 40 characters"
  else
    no "F the token is '$got' (want 'OK APPLIED'); the long one has ${#n} characters (want 40)"
  fi

  [ -n "$quiet" ] || printf '  [%s] (%d ok, %d failed)\n' "$sh_" "$p" "$x"
  [ "$x" = 0 ]
}

SRC=0
echo "shells: $SHELLS"
for s in $SHELLS; do
  echo "== grant arm [$s] =="
  shellsuite "$ROAMD" "$s" || SRC=1
done
[ "$SRC" = 0 ] || { echo "shell half FAILED"; exit 1; }
echo "shell half passed"
[ "${1:-}" = --mutate ] || exit 0

echo; echo "== mutants (each MUST be convicted by its named assertion) =="
fails=0
# edit <file> <regex> <replacement>: exactly one substitution in place; nonzero when it did not apply
edit() {
  python3 - "$1" "$2" "$3" <<'PY'
import re, sys
p, pat, repl = sys.argv[1:4]
s = open(p).read()
n, k = re.subn(pat, lambda m: m.expand(repl), s, count=1, flags=re.S)
if k != 1 or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
}
# smut <label> <cases> <regex> <replacement>: a COPY of roamd; convicted under EVERY shell by the named case(s)
smut() {
  local label="$1" cases="$2" m s_
  m=$(mktemp -p "$W") || { fails=$((fails+1)); return; }
  cp "$ROAMD" "$m"
  edit "$m" "$3" "$4" || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
  for s_ in $SHELLS; do
    if shellsuite "$m" "$s_" quiet "$cases"; then echo "  SURVIVED  [$s_] $label"; fails=$((fails+1)); else echo "  convicted [$s_] $label"; fi
  done
}
# mut <label> <test> <file> <regex> <replacement>: one substitution in a copy of the agent package; needs `--- FAIL: <test>`
mut() {
  local label=$1 test=$2 file=$3 P res rc
  P=$(mktemp -d -p "$W") || { fails=$((fails+1)); return; }
  cp -a "$AGENT/." "$P" || { fails=$((fails+1)); return; }
  edit "$P/$file" "$4" "$5" || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
  res=$(cd "$P" && go test -count=1 -timeout 180s -run "^$test\$" -v . 2>&1); rc=$?
  if [[ "$res" == *"--- FAIL: $test "* ]]; then echo "  convicted $label ($test)"
  elif [[ "$res" == *'build failed'* ]] || [[ "$res" == *'[setup failed]'* ]]; then
    echo "  BROKEN    $label -- the mutant did not compile"; fails=$((fails+1))
  else echo "  SURVIVED  $label ($test, rc=$rc)"; fails=$((fails+1)); fi
}

mut "V1 expect() not called at sign-in" TestGrantVpnExpectedAtSignIn main.go \
  '\t\tgrantVpn\.expect\(uid\)\n' ''
mut "V2 retryVpnup ignores the grant's answer and runs the loop" TestGrantVpnFirstApplyRidesTheGrant main.go \
  '\} else if ok && strings\.HasPrefix\(ans, "OK"\) \{' '} else if false && ok && strings.HasPrefix(ans, "OK") {'
mut "V3 the wait does not remove the entry" TestGrantVpnTimesOut grant_vpn.go \
  '(if g\.m\[uid\] == e \{\n)\t\tdelete\(g\.m, uid\)\n' '\1\t\t_ = 0\n'
mut "V4 claim() is true without expect" TestGrantVpnNotFlaggedWithoutExpect grant_vpn.go \
  'if e == nil \|\| e\.claimed \|\| e\.delivered \{\n\t\treturn false\n\t\}' \
  'if e == nil {\n\t\treturn true\n\t}\n\tif e.claimed || e.delivered {\n\t\treturn false\n\t}'
mut "V5 the marker re-check after the answer dropped" TestGrantVpnSessionGoneAfterGrant grant_vpn.go \
  'if ok && vpnupSessionGone\(dest, uid\) \{' 'if false && ok {'
smut "R1 the step ignores the flag" D \
  'if \[ "\$\{srcunit:-\}" = vpn \] && (\[ -n "\$\{STATE:-\}" \]; then\n      _tt=\$\(_ms\); _gv=\$\(vpn_apply)' 'if \1'
smut "R2 the answer written after RES" B \
  '(    if \[ "\$\{srcunit:-\}" = vpn \].*?\n    fi\n)(    echo "OK" > "\$RES"\n)' '\2\1'
smut "R3 vpn_apply moved before grant_perms_for" A \
  '(    _tt=\$\(_ms\); grant_perms_for "\$uid"; _tlog grant-135 "\$_tt"\n)(.*?)(    if \[ "\$\{srcunit:-\}" = vpn \].*?\n    fi\n)(    echo "OK" > "\$RES"\n)' \
  '\3\1\2\4'
smut "R4 the stale-file removal dropped" E \
  '    if \[ -n "\$\{STATE:-\}" \]; then rm -f "\$STATE/\.grantvpn\.\$uid" 2>/dev/null; fi\n' ''
smut "R5 RES becomes the token" C \
  '(    fi\n)    echo "OK" > "\$RES"\n(    ;;\n  seedssaid\))' '\1    printf "%s\\n" "${_gv:-OK}" > "$RES"\n\2'
# The control: a comment edit must survive under every shell.
m=$(mktemp -p "$W") || exit 2
cp "$ROAMD" "$m"
if edit "$m" '(    # NWP-20261210-06 \(backlog: A nearly empty profile)' '\1 (control)'; then
  for s_ in $SHELLS; do
    if shellsuite "$m" "$s_" quiet; then echo "  survived  [$s_] control: a comment edit"
    else echo "  FALSE CONVICTION [$s_] control: a comment edit"; fails=$((fails+1)); fi
  done
else
  echo "  INERT     control -- the comment edit did not apply"; fails=$((fails+1))
fi
[ "$fails" -eq 0 ] && echo "== all 10 mutations convicted, the control survived" \
  || { echo "== $fails mutation(s) not convicted (or the control failed)"; exit 1; }
