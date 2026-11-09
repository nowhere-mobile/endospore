#!/usr/bin/env bash
# test-signin-summary.sh [--mutate] -- a sign-in's restore and parked summary reach an in-session issue report
# (NWP-20261122-09, backlog: An issue report's logs sections keep only the last 299 lines of each log, so a sign-in's
# own summary lines ... roll out under the Auto sweep's per-app lines before the report is sent). The `in` arm exports
# NOWHERE_SIGNIN_SUMMARY=$STATE/signin-summary.<uid>; each CDC restore (signinSummaryAppend), od_parked_report and each
# timed step of the arm (_ssum, NWP-20261130-08) append one line to it; signin_summary.go reads it into signin_* status
# keys, digits only, at session scope only, for the report's own uid only.
#
# The Go half runs signin_summary_test.go (the writer, the reader, the merge and the two call-site pins). The shell
# half extracts the REAL head of the `in` arm from nowhere_roamd.sh BY ANCHOR (from `  in)` to the line that exports
# NOWHERE_SIGNIN_SUMMARY) and runs it under every shell found (bash sh, plus dash and mksh when installed):
#   A  uid=10: an old signin-summary.10 is removed, signin-summary.11 is untouched, the export names .10;
#   B  uid='' and uid=1a: no export, and no file is removed;
#   C  _ssum, extracted BY NAME: the exact line for an ordinary and a 13-digit start (both signs of mksh's 32-bit wrap),
#      and no line and nothing on stderr for no variable, a bad start, a bad end or an end before the start;
#   D  the whole arm and the script head: each bracket sits around its step (signin_in_ms, reap, acct and the three reown);
#   E  the real timer lines in file order behind a stub clock: 35 s of work before the arm and 1 s after it give
#      phase=reap ms=35000 and phase=in ms=36000.
# test-od-parked-report.sh pins od_parked_report's own append.
# --mutate breaks each guard in turn on a COPY (the roamd script or the Go package); each mutant must be CONVICTED
# (the shell one under every shell; the Go ones by a real `--- FAIL`). One that fails to apply or compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
. ./suite-report.sh
TESTS='TestSigninSummary'
ROAMD=../vendor-common/bin/nowhere_roamd.sh
[ -f "$ROAMD" ] || { echo "no such script: $ROAMD" >&2; exit 2; }
SHELLS="bash sh"
for s in dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done

out=$(go test -count=1 -timeout 180s -run "$TESTS" -v . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1

# extract <script> <out> -> 0 when the arm head was found and holds both exports
extract() {
  local f="$1" out="$2" piece
  rm -f "$out"
  piece=$(awk '$0 == "  in)" {f=1; next} f{print} f&&/export NOWHERE_SIGNIN_SUMMARY=/{exit}' "$f")
  case "$piece" in *'export NOWHERE_HEAL_UNTIL'*'export NOWHERE_SIGNIN_SUMMARY='*) ;; *) return 1 ;; esac
  printf '%s\n' "$piece" > "$out"
}

# shellsuite <roamd> <shell> [quiet] -> 0 when every case behaved
shellsuite() {
  local f="$1" sh_="$2" quiet="${3:-}" p=0 x=0 body T u got fn arm c
  ok() { p=$((p+1)); [ -n "$quiet" ] || printf '  ok    [%s] %s\n' "$sh_" "$1"; }
  no() { x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  [%s] %s\n' "$sh_" "$1"; }
  body=$(mktemp -p "$W") || return 2
  extract "$f" "$body" || { no "EXTRACTION FAILED -- the in arm head or its NOWHERE_SIGNIN_SUMMARY export is missing in $f"; return 1; }

  # prep <dir> <uid> -> <dir>/run.sh: the arm head behind its variables and stubs, then the export it left
  prep() {
    local d="$1"
    mkdir -p "$d/state"
    printf 'old\n' > "$d/state/signin-summary.10"
    printf 'other\n' > "$d/state/signin-summary.11"
    printf 'shared\n' > "$d/state/signin-summary."
    printf 'odd\n' > "$d/state/signin-summary.1a"
    {
      printf "uid='%s'; STATE='%s'; LOG='%s'\n" "$2" "$d/state" "$d/log"
      printf '%s\n' 'unset NOWHERE_SIGNIN_SUMMARY; uiderrors_floor_take() { :; }'
      cat "$body"
      printf 'printf "%%s\\n" "${NOWHERE_SIGNIN_SUMMARY:-unset}" > "%s"\n' "$d/env"
    } > "$d/run.sh"
  }

  # ---- A: uid=10 ----
  T=$(mktemp -d -p "$W") || return 2
  prep "$T" 10
  "$sh_" "$T/run.sh" >/dev/null 2>"$T/err"
  [ ! -e "$T/state/signin-summary.10" ] && ok "A the old signin-summary.10 is removed" \
    || no "A signin-summary.10 survived the arm head: '$(cat "$T/state/signin-summary.10" 2>/dev/null)'"
  [ "$(cat "$T/state/signin-summary.11" 2>/dev/null)" = other ] && ok "A signin-summary.11 is untouched" \
    || no "A another uid's signin-summary.11 was touched"
  got=$(cat "$T/env" 2>/dev/null)
  [ "$got" = "$T/state/signin-summary.10" ] && ok "A the export names this uid's file" \
    || no "A NOWHERE_SIGNIN_SUMMARY is '$got', want $T/state/signin-summary.10"
  [ ! -s "$T/err" ] && ok "A the head ran with nothing on stderr" || no "A stderr: $(head -n 2 "$T/err")"

  # ---- B: a uid that is empty or not all digits ----
  for u in '' 1a; do
    T=$(mktemp -d -p "$W") || return 2
    prep "$T" "$u"
    "$sh_" "$T/run.sh" >/dev/null 2>/dev/null
    got=$(cat "$T/env" 2>/dev/null)
    [ "$got" = unset ] && ok "B uid='$u': no export" || no "B uid='$u': NOWHERE_SIGNIN_SUMMARY is '$got', want unset"
    if [ -e "$T/state/signin-summary." ] && [ -e "$T/state/signin-summary.1a" ] && [ -e "$T/state/signin-summary.10" ]; then
      ok "B uid='$u': no file removed"
    else
      no "B uid='$u': a signin-summary file was removed"
    fi
  done

  # ---- C: _ssum ----
  fn=$(mktemp -p "$W") || return 2
  awk '$0 == "_ssum() {" {f=1} f{print} f&&/^}$/{exit}' "$f" > "$fn"
  if [ ! -s "$fn" ]; then
    no "C EXTRACTION FAILED -- no _ssum in $f"
  else
    # ssum_run <dir> <now> <word> <start>: _ssum behind a stub clock, under this shell
    ssum_run() {
      { cat "$fn"; printf '_ms() { echo %s; }\n_ssum "%s" "%s"\necho "rc=$?"\n' "$2" "$3" "$4"; } > "$1/run.sh"
      "$sh_" "$1/run.sh" >"$1/out" 2>"$1/err"
    }
    T=$(mktemp -d -p "$W") || return 2
    export NOWHERE_SIGNIN_SUMMARY="$T/s"
    ssum_run "$T" 1250 reap 1000
    got=$(cat "$T/s" 2>/dev/null)
    [ "$got" = "v=1 phase=reap ms=250" ] && ok "C start 1000, end 1250: the exact line" || no "C start 1000, end 1250: '$got'"
    # The second start's low 32 bits have the sign bit set: on mksh a raw numeric test reads it as negative.
    for c in 1762000000000 1764147483648; do
      rm -f "$T/s"
      ssum_run "$T" "$((c + 250))" in "$c"
      got=$(cat "$T/s" 2>/dev/null)
      [ "$got" = "v=1 phase=in ms=250" ] && ok "C the 13-digit start $c: 250" || no "C the 13-digit start $c: '$got'"
      [ ! -s "$T/err" ] && ok "C the 13-digit start $c: nothing on stderr" || no "C the 13-digit start $c: stderr: $(head -n 1 "$T/err")"
    done
    for c in '1250 reap ' '1250 reap 0' '1250 reap x' '1250 reap 5+5' '0 reap 1000' '999 reap 1000'; do
      rm -f "$T/s"
      # shellcheck disable=SC2086
      set -- $c
      ssum_run "$T" "$1" "$2" "${3:-}"
      [ ! -e "$T/s" ] && ok "C now=$1 start='${3:-}': no line" || no "C now=$1 start='${3:-}': wrote '$(cat "$T/s")'"
      [ ! -s "$T/err" ] && ok "C now=$1 start='${3:-}': nothing on stderr" || no "C now=$1 start='${3:-}': stderr: $(head -n 1 "$T/err")"
      got=$(cat "$T/out" 2>/dev/null)
      [ "$got" = rc=0 ] && ok "C now=$1 start='${3:-}': returns 0" || no "C now=$1 start='${3:-}': '$got', want rc=0"
    done
    unset NOWHERE_SIGNIN_SUMMARY
    rm -f "$T/s"; ssum_run "$T" 1250 reap 1000
    [ ! -e "$T/s" ] && ok "C no NOWHERE_SIGNIN_SUMMARY: no file" || no "C no NOWHERE_SIGNIN_SUMMARY: a file was written"
  fi

  # ---- D: the brackets in the whole arm ----
  arm=$(mktemp -p "$W") || return 2
  awk '$0 == "  in)" {f=1} f{print} f&&/^    ;;$/{exit}' "$f" > "$arm"
  # adj <label> <regex of a line> <regex of the next line>: exactly one such pair of lines in the arm
  adj() {
    local got_
    got_=$(A_="$2" B_="$3" awk 'p && $0 ~ ENVIRON["B_"] {n++} {p = ($0 ~ ENVIRON["A_"])} END {print n+0}' "$arm")
    [ "$got_" = 1 ] && ok "D $1" || no "D $1 ($got_ such pairs of lines, want 1)"
  }
  adj "the pre-arm reap line follows the file's export" '^      export NOWHERE_SIGNIN_SUMMARY=' '^    _ssum reap "\$_sumt"'
  adj "signin_in_ms ends right before the commit of the OK reply" '^      _ssum in "\$_sum0"$' '^      uiderrors_floor_commit "\$_uefloor"'
  adj "the OK reply is next" '^      uiderrors_floor_commit "\$_uefloor"' '^      echo "OK \$uid" > "\$RES"; _inres=OK$'
  adj "the CE reown starts at the vault restore's success" '^      _ceok=1$' '^      _sumt=\$\(_ms\)$'
  adj "the CE reown ends after its restorecon" '_tlog restorecon-ce ' '^      _ssum reown "\$_sumt"$'
  adj "the #de reown starts in its success branch" '^      if \[ "\$_derc" = 0 \]; then$' '^        _sumt=\$\(_ms\)$'
  adj "the #de reown ends after its restorecon" '_tlog restorecon-de ' '^        _ssum reown "\$_sumt"$'
  adj "the #media reown starts before the tail" '^        if \[ "\$_mdrc" = 0 \]; then$' '^          _sumt=\$\(_ms\)$'
  adj "the #media tail is next" '^          _sumt=\$\(_ms\)$' '^          restore_media_tail "\$MEDIADIR"$'
  adj "the #media reown ends after the tail" '^          restore_media_tail "\$MEDIADIR"$' '^          _ssum reown "\$_sumt"$'
  adj "acct starts right before acct_restore" '^        _sumt=\$\(_ms\)$' '^        acct_restore "\$uid"'
  adj "acct ends after acct_restore" '^        acct_restore "\$uid"' '^        _ssum acct "\$_sumt"$'
  adj "reap ends after reap_orphan_provisioned" '^      reap_orphan_provisioned "\$CHOOSER0' '^      _ssum reap "\$_sumt"$'
  adj "reap starts right before reap_stale_ondemand" '^      _sumt=\$\(_ms\)$' '^      reap_stale_ondemand "\$CHOOSER0'
  c=$(grep -c '_ssum reown "\$_sumt"' "$arm")
  [ "$c" = 3 ] && ok "D the arm holds exactly three reown lines" || no "D the arm holds $c reown lines, want 3"
  got=$(awk '/^_ms\(\) \{/{a=NR} /^ *_sum0=/{n++; b=NR} /^\[ -f "\$REQ" \]/{c=NR} END{print (n==1 && a && a<b && b<c)}' "$f")
  [ "$got" = 1 ] && ok "D _sum0 is set once, after _ms and before the request is read" \
    || no "D _sum0 is not set once, between _ms and the request read"

  # ---- E: work before the arm is in the total and in the reap key ----
  if [ -s "$fn" ]; then
    T=$(mktemp -d -p "$W") || return 2
    echo 1000000 > "$T/clock"
    {
      cat "$fn"
      printf 'CLOCK=%s\nLANE=rw\nNOWHERE_SIGNIN_SUMMARY=%s\n' "$T/clock" "$T/s"
      cat <<'EOS'
export NOWHERE_SIGNIN_SUMMARY
_ms() { cat "$CLOCK"; }
advance() { echo $(( $(cat "$CLOCK") + $1 )) > "$CLOCK"; }
reap_retry_run() { advance 30000; }
userdir_recheck() { advance 5000; }
EOS
      # The real lines, in the script's own order, so a start moved past the two steps gives a short total.
      awk '/^ *_sum0=\$\(_ms\)/ || /^_sumt=\$\(_ms\)/ || /^\[ "\$LANE" = rw \] && (reap_retry_run|userdir_recheck)$/ || /^    _ssum reap "\$_sumt"/ {print}
           /^      _ssum in "\$_sum0"$/ {print "advance 1000"; print}' "$f"
    } > "$T/run.sh"
    "$sh_" "$T/run.sh" >/dev/null 2>"$T/err"
    got=$(tr '\n' ';' < "$T/s" 2>/dev/null)
    [ "$got" = "v=1 phase=reap ms=35000;v=1 phase=in ms=36000;" ] && ok "E 35 s before the arm: reap 35000, in 36000" \
      || no "E 35 s before the arm and 1 s after it: '$got', want reap 35000 and in 36000"
    [ ! -s "$T/err" ] && ok "E nothing on stderr" || no "E stderr: $(head -n 1 "$T/err")"
  fi

  [ -n "$quiet" ] || printf '  [%s] (%d ok, %d failed)\n' "$sh_" "$p" "$x"
  [ "$x" = 0 ]
}

SRC=0
echo "shells: $SHELLS"
for s in $SHELLS; do
  echo "== in arm head [$s] =="
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
  local label=$1 file=$2 P res mrc
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
  res=$(cd "$P" && go test -count=1 -timeout 180s -run "$TESTS" -v . 2>&1); mrc=$?
  score_mutant "$label" "$mrc" "$res" || fails=$((fails+1))
  rm -rf "$P"
}

mut "m1 the scope table accepts any phase" signin_summary.go \
  'if !ok \{\n\t\treturn\n\t\}\n(\tms := restMs)' 'if !ok {\n\t\tword = os.Getenv("NOWHERE_PHASE")\n\t}\n\1'
mut "m2 the reader accepts a non-digit value" signin_summary.go 'ms=\(\[0-9\]\{1,12\}\)' 'ms=([^ ]{1,12})'
mut "m3 the merge runs at device scope" signin_summary.go 'if deviceScope \|\| status == nil' 'if status == nil'
mut "m4 the writer call removed" main.go '\n\t+signinSummaryAppend\(m, restMs, hr\.ms\)[^\n]*' '\n\t\t\t_ = hr'
mut "m5 the merge ignores the uid" signin_summary.go 'signinSummaryPrefix\+uid' '"signin-summary"'
smut "m6 the in arm's per-uid rm removed" -e 's#rm -f "\$STATE/signin-summary\.\$uid" 2>/dev/null##'
# NWP-20261130-08. Each names the assertion that convicts it.
# m7, m8, m9: the heal counted twice. TestSigninSummaryAppendHeal and TestSigninSummaryHealCountsOnce; TestSigninSummaryStatusHeal; TestSigninSummarySourcePins.
mut "m7 the writer keeps the heal in ms" signin_summary.go 'ms := restMs - healMs' 'ms := restMs'
mut "m8 the reader adds the heal per line, not last per scope" signin_summary.go \
  'heal\[s\], _ = strconv\.ParseInt\(m\[6\], 10, 64\)' 'hv, _ := strconv.ParseInt(m[6], 10, 64)\n\t\t\theal[s] += hv'
mut "m9 the restore verb passes no heal" main.go 'signinSummaryAppend\(m, restMs, hr\.ms\)' 'signinSummaryAppend(m, restMs, 0*hr.ms)'
# m10-m13: a key dropped. TestSigninSummaryStatusFull's exact map.
mut "m10 signin_<scope>_store_reads dropped" signin_summary.go \
  'out\["signin_"\+s\+"_store_reads"\], out\["signin_"\+s\+"_cap_calls"\] = m\[7\], m\[8\]' 'out["signin_"+s+"_cap_calls"] = m[8]'
mut "m11 signin_<scope>_cap_calls dropped" signin_summary.go \
  'out\["signin_"\+s\+"_store_reads"\], out\["signin_"\+s\+"_cap_calls"\] = m\[7\], m\[8\]' 'out["signin_"+s+"_store_reads"] = m[7]'
mut "m12 signin_heal_ms dropped" signin_summary.go 'out\["signin_heal_ms"\] = strconv\.FormatInt\(sum, 10\)' '_ = sum'
mut "m13 the phase keys dropped" signin_summary.go 'out\["signin_"\+w\+"_ms"\] = strconv\.FormatInt\(n, 10\)' '_, _ = w, n'
# m14: TestSigninSummaryAppendEachPhase's exact line. m15: TestSigninSummaryPrefetchCountsCapCalls. m16: TestSigninSummaryRestoreHealTime.
mut "m14 the writer puts the cap count in store_reads" signin_summary.go \
  'healMs, atomic\.LoadInt64\(&traceGetN\)' 'healMs, atomic.LoadInt64(&traceCapN)'
mut "m15 the batch prefetch is not counted" main.go \
  'traceSince\(&traceCapN, &traceCapNs, func\(\) \{\n\t\t\tcaps, ttl, err = gw\.readCaps\(keys\[i:end\]\)\n\t\t\}\)' 'caps, ttl, err = gw.readCaps(keys[i:end])'
mut "m16 restoreHeal does not time the heal" media_heal.go 'hr\.ms = time\.Since\(hStart\)\.Milliseconds\(\)' '_ = hStart'
# m17-m23: shell half case D (m23: its "_sum0 is set once"). m24: case C, the sign-bit start under mksh and the non-digit starts under bash and dash.
smut "m17 _ssum in removed" -e '/^      _ssum in "\$_sum0"$/d'
smut "m18 _ssum reap removed" -e '/^      _ssum reap "\$_sumt"$/d'
smut "m19 _ssum acct removed" -e '/^        _ssum acct "\$_sumt"$/d'
smut "m20 the CE _ssum reown removed" -e '/_tlog restorecon-ce /{n;/_ssum reown/d;}'
smut "m21 the #de _ssum reown removed" -e '/_tlog restorecon-de /{n;/_ssum reown/d;}'
smut "m22 the #media _ssum reown removed" -e '/^          restore_media_tail "\$MEDIADIR"$/{n;/_ssum reown/d;}'
smut "m23 _sum0 removed" -e '/^_sum0=\$(_ms)$/d'
smut "m24 _ssum guards the raw start with a numeric test" -e 's/^  case "\${2:-}" in .*) return 0 ;; esac$/  [ "${2:-0}" -gt 0 ] || return 0/'
# m25-m28: the start of signin_in_ms and the pre-arm reap line. Each names the case that convicts it.
# m25, m26: case E's exact lines, the total short by the 35 s. m27: case E, no reap line. m28: case D's "pre-arm reap line".
smut "m25 _sum0 starts on the arm's first line" -e '/^_sum0=\$(_ms)$/d' -e '/^  in)$/a\    _sum0=$(_ms)'
smut "m26 _sum0 starts after the two steps" -e '/^_sum0=\$(_ms)$/d' -e '/^\[ "\$LANE" = rw \] \&\& userdir_recheck$/a\_sum0=$(_ms)'
smut "m27 the pre-arm reap line removed" -e '/^    _ssum reap "\$_sumt"/d'
smut "m28 the pre-arm reap line before the file's rm" -e '/^    _ssum reap "\$_sumt"/d' \
  -e '/^    case "\$uid" in .*rm -f "\$STATE\/signin-summary\.\$uid"/i\    _ssum reap "$_sumt"'
[ "$fails" -eq 0 ] && echo "== all 28 mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
