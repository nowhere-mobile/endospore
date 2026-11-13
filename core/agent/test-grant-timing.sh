#!/usr/bin/env bash
# test-grant-timing.sh [--mutate] -- the grant op's bundle count and step timings reach an in-session issue report
# (NWP-20261119-07, backlog: 0.5.49's grant op runs the Keystore sweep, at least fifteen execs per restored bundle,
# while the GRANT-PERMS handler holds the daemon's session lock, ...). roam.log's TIMING lines fall outside the
# report's trimmed tail, so roamd's grant arm also writes one line to $STATE/grant-timing
# (v=1 bundles=<n> keystore_ms=<n> perms_ms=<n> total_ms=<n>) and grant_timing.go reads it into four status keys,
# at session scope only.
#
# The Go half runs grant_timing_test.go. The shell half extracts the REAL grant arm, _ms, _tlog and ks_in_dir from
# nowhere_roamd.sh BY ANCHOR and runs them under every shell found (bash sh, plus dash and mksh when installed),
# with every other helper the arm calls stubbed and two bundles planted in keystore-in/<uid>. The keystore_register_all
# stub MOVES the bundles out of keystore-in, as the real sweep does, so a count taken after the sweep reads 0. Cases:
#   A  a full run leaves one line of the exact shape with bundles=2, no .tmp, OK in $RES, and both TIMING lines
#      in roam.log unchanged;
#   B  a run cut off before its end (grant_perms_for exits) leaves no earlier grant-timing file;
#   C  an unset uid counts 0 bundles.
# --mutate breaks each guard in turn on a COPY (the roamd script or the Go package); each mutant must be CONVICTED
# (the shell ones under every shell; the Go ones by a real `--- FAIL`). One that fails to apply or compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
. ./suite-report.sh
TESTS='TestGrantTiming'
ROAMD=../vendor-common/bin/nowhere_roamd.sh
[ -f "$ROAMD" ] || { echo "no such script: $ROAMD" >&2; exit 2; }
SHELLS="bash sh"
for s in dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done

out=$(go test -count=1 -timeout 180s -run "$TESTS" -v . 2>&1); rc=$?
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
  piece=$(sed -n '/^ks_in_dir() {$/,/^}$/p' "$f")
  [ -n "$piece" ] || return 1
  printf '%s\n' "$piece" >> "$out"
  piece=$(sed -n '/^  grant)$/,/^    ;;$/p' "$f" | sed '1d;$d')
  [ -n "$piece" ] || return 1
  printf '%s\n' "$piece" >> "$out"
}

# shellsuite <roamd> <shell> [quiet] -> 0 when every case behaved
shellsuite() {
  local f="$1" sh_="$2" quiet="${3:-}" p=0 x=0 body T line n
  ok() { p=$((p+1)); [ -n "$quiet" ] || printf '  ok    [%s] %s\n' "$sh_" "$1"; }
  no() { x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  [%s] %s\n' "$sh_" "$1"; }
  body=$(mktemp -p "$W") || return 2
  extract "$f" "$body" || { no "EXTRACTION FAILED -- _ms, _tlog, ks_in_dir or the grant arm is missing in $f"; return 1; }

  # prep <dir> <uid> <grant_perms_for body> -> <dir>/run.sh, the re-rooted arm behind its variables and stubs
  prep() {
    local d="$1"
    mkdir -p "$d/data/nowhere/keystore-in/10" "$d/state"
    printf 'k\n' > "$d/data/nowhere/keystore-in/10/com.ex.a.keys"
    printf 'k\n' > "$d/data/nowhere/keystore-in/10/com.ex.b.keys"
    {
      printf "uid=%s; LOG='%s'; STATE='%s'; RES='%s'; KS_IN='%s'; MOVED='%s'\n" "$2" "$d/log" "$d/state" "$d/res" \
        "$d/data/nowhere/keystore-in" "$d/moved"
      printf '%s\n' "ACCT_AUTH_PKG=com.google.android.gms; PLAY_STORE_PKG=com.android.vending"
      printf '%s\n' 'home_pin() { :; }; nav_apply() { :; }; aod_apply() { :; }; a11y_apply() { :; }; autofill_apply() { :; }; shortcut_apply() { :; }'
      printf '%s\n' 'acct_reload() { :; }; sync_apply() { :; }; am() { :; }; pm() { :; }'
      printf 'grant_perms_for() { %s; }\n' "$3"
      printf '%s\n' 'keystore_register_all() { mkdir -p "$MOVED"; mv "$KS_IN/10"/*.keys "$MOVED/" 2>/dev/null; return 0; }'
      sed "s#/data/#$d/data/#g" "$body"
    } > "$d/run.sh"
  }

  # ---- A: a full run ----
  T=$(mktemp -d -p "$W") || return 2
  prep "$T" 10 ':'
  "$sh_" "$T/run.sh" >/dev/null 2>&1
  line=$(cat "$T/state/grant-timing" 2>/dev/null)
  n=$(awk 'END { print NR }' "$T/state/grant-timing" 2>/dev/null)
  if [[ "$line" =~ ^v=1\ bundles=2\ keystore_ms=[0-9]+\ perms_ms=[0-9]+\ total_ms=[0-9]+$ ]] && [ "$n" = 1 ]; then
    ok "A one line of the shape, bundles=2: $line"
  else
    no "A grant-timing is '$line' ($n line(s)), want one line v=1 bundles=2 keystore_ms=<n> perms_ms=<n> total_ms=<n>"
  fi
  [ ! -e "$T/state/grant-timing.tmp" ] && ok "A no grant-timing.tmp left" || no "A grant-timing.tmp left behind"
  [ "$(cat "$T/res" 2>/dev/null)" = OK ] && ok "A the arm answered OK" || no "A the arm did not answer OK"
  n=$(grep -cE '^\[roamd\] TIMING grant-keystore [0-9]+ms \(user 10\) ' "$T/log" 2>/dev/null)
  [ "$n" = 1 ] && ok "A roam.log keeps one TIMING grant-keystore line" || no "A ${n:-0} TIMING grant-keystore lines, want 1"
  n=$(grep -cE '^\[roamd\] TIMING grant-135 [0-9]+ms \(user 10\) ' "$T/log" 2>/dev/null)
  [ "$n" = 1 ] && ok "A roam.log keeps one TIMING grant-135 line" || no "A ${n:-0} TIMING grant-135 lines, want 1"

  # ---- B: cut off before its end, over an earlier session's file ----
  T=$(mktemp -d -p "$W") || return 2
  prep "$T" 10 'exit 0'
  printf 'v=1 bundles=9 keystore_ms=1 perms_ms=1 total_ms=1\n' > "$T/state/grant-timing"
  "$sh_" "$T/run.sh" >/dev/null 2>&1
  [ ! -e "$T/state/grant-timing" ] && ok "B a grant cut off before its end leaves no earlier grant-timing" \
    || no "B the earlier grant-timing survived: '$(cat "$T/state/grant-timing" 2>/dev/null)'"
  [ "$(cat "$T/res" 2>/dev/null)" != OK ] && ok "B the cut-off arm did not answer OK" || no "B the stub did not cut the arm off"

  # ---- C: an unset uid counts 0 ----
  T=$(mktemp -d -p "$W") || return 2
  prep "$T" '' ':'
  "$sh_" "$T/run.sh" >/dev/null 2>&1
  line=$(cat "$T/state/grant-timing" 2>/dev/null)
  if [[ "$line" =~ ^v=1\ bundles=0\ keystore_ms=[0-9]+\ perms_ms=[0-9]+\ total_ms=[0-9]+$ ]]; then
    ok "C an unset uid counts bundles=0"
  else
    no "C an unset uid wrote '$line', want bundles=0"
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

echo; echo "== mutants (each MUST be convicted) =="
fails=0
# smut <label> <sed args...>: a COPY of roamd, refused when the sed changed nothing; convicted under EVERY shell
smut() {
  local label="$1" m s_; shift
  m=$(mktemp -p "$W") || { fails=$((fails+1)); return; }
  sed "$@" "$ROAMD" > "$m"
  if cmp -s "$ROAMD" "$m"; then echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); rm -f "$m"; return; fi
  for s_ in $SHELLS; do
    if shellsuite "$m" "$s_" quiet; then echo "  SURVIVED  [$s_] $label"; fails=$((fails+1)); else echo "  convicted [$s_] $label"; fi
  done
  rm -f "$m"
}
# mut <label> <file> <regex> <replacement>: exactly one substitution in a package copy; needs a real `--- FAIL`
mut() {
  local label=$1 file=$2 P res
  P=$(mktemp -d -p "$W") || { fails=$((fails+1)); return; }
  cp -a . "$P" || { fails=$((fails+1)); return; }
  python3 - "$P/$file" "$3" "$4" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); rm -rf "$P"; return; }
import re, sys
p, pat, repl = sys.argv[1:4]
s = open(p).read()
n, k = re.subn(pat, lambda m: m.expand(repl), s, count=1)
if k != 1 or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
  res=$(cd "$P" && go test -count=1 -timeout 180s -run "$TESTS" -v . 2>&1)
  if grep -qE '^\s*--- FAIL' <<<"$res"; then echo "  convicted $label"
  elif grep -q 'build failed' <<<"$res"; then echo "  BROKEN    $label -- the mutant did not compile"; fails=$((fails+1))
  else echo "  SURVIVED  $label"; fails=$((fails+1)); fi
  rm -rf "$P"
}

smut "m1 the write removed" -e '/^           printf .v=1 bundles=/,/ "\$STATE\/grant-timing" 2>\/dev\/null$/c\           :'
smut "m2 bundles counted after the sweep" \
  -e '/^    _gtb=0; /{h;d;}' -e '/^    _tt=\$(_ms); keystore_register_all; _tlog grant-keystore "\$_tt"$/G'
mut "m3 the deviceScope guard dropped" report_issue.go 'if !deviceScope \{(\n\t+for k, v := range grantTimingStatus)' 'if true {\1'
mut "m4 the reader accepts a non-digit value" grant_timing.go 'bundles=\(\[0-9\]\{1,9\}\)' 'bundles=([^ ]{1,9})'
smut "m5 the top-of-arm rm removed" -e '/^    if \[ -n "\${STATE:-}" \]; then rm -f "\$STATE\/grant-timing" 2>\/dev\/null; fi$/d'
[ "$fails" -eq 0 ] && echo "== all 5 mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
