#!/usr/bin/env bash
# test-signin-summary.sh [--mutate] -- a sign-in's restore and parked summary reach an in-session issue report
# (NWP-20261122-09, backlog: An issue report's logs sections keep only the last 299 lines of each log, so a sign-in's
# own summary lines ... roll out under the Auto sweep's per-app lines before the report is sent). The `in` arm exports
# NOWHERE_SIGNIN_SUMMARY=$STATE/signin-summary.<uid>; each CDC restore (signinSummaryAppend) and od_parked_report
# append one line to it; signin_summary.go reads it into signin_* status keys, digits only, at session scope only,
# for the report's own uid only.
#
# The Go half runs signin_summary_test.go (the writer, the reader, the merge and the two call-site pins). The shell
# half extracts the REAL head of the `in` arm from nowhere_roamd.sh BY ANCHOR (from `  in)` to the line that exports
# NOWHERE_SIGNIN_SUMMARY) and runs it under every shell found (bash sh, plus dash and mksh when installed):
#   A  uid=10: an old signin-summary.10 is removed, signin-summary.11 is untouched, the export names .10;
#   B  uid='' and uid=1a: no export, and no file is removed.
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
  local f="$1" sh_="$2" quiet="${3:-}" p=0 x=0 body T u got
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
  'if !ok \{\n\t\treturn\n\t\}\n(\tline := )' 'if !ok {\n\t\tword = os.Getenv("NOWHERE_PHASE")\n\t}\n\1'
mut "m2 the reader accepts a non-digit value" signin_summary.go 'ms=\(\[0-9\]\{1,12\}\)' 'ms=([^ ]{1,12})'
mut "m3 the merge runs at device scope" signin_summary.go 'if deviceScope \|\| status == nil' 'if status == nil'
mut "m4 the writer call removed" main.go '\n\t+signinSummaryAppend\(m, restMs\)[^\n]*' ''
mut "m5 the merge ignores the uid" signin_summary.go 'signinSummaryPrefix\+uid' '"signin-summary"'
smut "m6 the in arm's per-uid rm removed" -e 's#rm -f "\$STATE/signin-summary\.\$uid" 2>/dev/null##'
[ "$fails" -eq 0 ] && echo "== all 6 mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
