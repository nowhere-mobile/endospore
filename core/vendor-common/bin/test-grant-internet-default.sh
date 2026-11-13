#!/usr/bin/env bash
# test-grant-internet-default.sh [<nowhere_roamd.sh>] [--mutate] -- grant_perms_for's INTERNET default
# (DIA-20260813-08, #127), and the in-shell membership match NWP-20260820-19 put in place of its two `grep -qxF`s.
#
# WHY THIS IS COMMITTED. PR #809 (NWP-20260820-19) replaced `grep -qxF "<pkg> android.permission.INTERNET"` and
# `grep -qxF "<pkg> deny:android.permission.INTERNET"` with newline-anchored `case` matches over the file read once,
# and claimed the semantics were preserved exactly. Its docs/backlog.md §A row records that the rewrite has never run
# a non-zero iteration on a device (both logins since logged `+ 0 INTERNET default(s)`), so the claim was never
# compared against what it replaced. This suite makes that comparison: it runs the WHOLE function over generated
# nowhere-perms fixtures (prefix and suffix collisions, first line, an unterminated last line, deny, a trailing
# space, pkgfilter) and checks it against a `grep -qxF` oracle run on the same file. It does NOT close the row --
# its closing condition is still a device login with a third-party package not in nowhere-perms.
#
# The per-line loop above the default issues the same `pm grant --user <u> <pkg> android.permission.INTERNET` for
# every INTERNET line it reads, so the default's grants cannot be told apart by their arguments. Each case therefore
# asserts, per listed package, that the recorded INTERNET grants equal E1 + E2: E1 is the number of INTERNET lines
# the per-line loop honours for that package (declared per fixture: a line `read` returns, honouring pkgfilter), E2
# the oracle's 0 or 1 for the default. The log's `+ N INTERNET default(s)` must equal the sum of E2 -- that is the
# primary check of the rewritten match.
#
# PINNED AS CURRENT BEHAVIOUR, NOT ENDORSED:
#   - with no nowhere-perms file a sign-in call returns early (`-> 0 perms (no file, user`) and grants no INTERNET
#     default (a package-filtered call with no file runs the default, NWP-20261201-19);
#   - an INTERNET line that is the LAST line with no trailing newline is not returned by `read`, so the per-line
#     loop never grants it, while both the oracle and the match see it and skip the default: the package gets no
#     INTERNET grant at all. That is the per-line loop, which predates NWP-20260820-19 and is unchanged by it.
#
# The function is extracted from nowhere_roamd.sh BY ANCHOR, never copied, and its one hardcoded nowhere-perms path
# is rewritten under a scratch root (the rewrite must hit exactly one line, or the harness stops). `pm` and `cmd` are
# stubbed as shell functions that record every call; a `pm` verb the stubs do not model fails the case. Every case
# runs under bash and sh, plus dash and mksh where installed -- roamd is #!/system/bin/sh (mksh on the device).
#
#   bash test-grant-internet-default.sh            # the behaviour cases
#   bash test-grant-internet-default.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

SHELLS="bash sh"
for s in mksh dash; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done

UIDV=15
PFREL="data/user/$UIDV/com.nowhere.chooser/files/nowhere-perms"
INET=android.permission.INTERNET

# POSIX sh: the stubs run unchanged under every shell above. Lines are short appends from the function's
# backgrounded subshells; the suite counts them and never relies on their order.
STUBS='
pm() {
  case "$1 $2" in
    "list packages") cat "$D/pkgs" ;;
    "grant --user")  echo "grant $4 $5"  >> "$D/calls"; return 0 ;;
    "revoke --user") echo "revoke $4 $5" >> "$D/calls"; return 0 ;;
    *) echo "pm $*" >> "$D/unexpected"; return 1 ;;
  esac
}
cmd() { echo "cmd $*" >> "$D/calls"; return 0; }
'

# prep_fn <roamd.sh> <out> -- extract grant_perms_for and point its nowhere-perms under $TROOT. 0 ok, 2 harness error.
prep_fn() {
  local sut="$1" out="$2" raw
  raw=$(mktemp)
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

# oracle <pf> <pkgfilter> <pkg> -> 0/1: the INTERNET default as the pre-#809 `grep -qxF` code decided it. With no file,
# since NWP-20261201-19: a package-filtered call runs the default for its package, and a sign-in call runs none.
oracle() {
  local pf="$1" filt="$2" pkg="$3"
  [ -n "$filt" ] && [ "$pkg" != "$filt" ] && { echo 0; return; }
  [ -f "$pf" ] || { if [ -n "$filt" ]; then echo 1; else echo 0; fi; return; }
  grep -qxF "$pkg $INET" "$pf" && { echo 0; return; }
  grep -qxF "$pkg deny:$INET" "$pf" && { echo 0; return; }
  echo 1
}

# fixture <fn> <shell> <label> <pkgfilter> <content|NOFILE> <e1: pkg=n,...> <extra> <pkg>...
# Runs the function once and asserts (a) the log's default count == sum(E2), (b) per pkg INTERNET grants == E1+E2,
# (c) the case's extra check, (d) no unmodelled pm verb. Calls are read only after the shell has exited: the
# function's own `wait` drains the backgrounded grants before it returns.
fixture() {
  local fn="$1" sh="$2" label="$3" filt="$4" content="$5" e1spec="$6" extra="$7" d pf pkg e1 e2 sum=0 got n why=""
  shift 7
  d=$(mktemp -d); pf="$d/root/$PFREL"
  mkdir -p "$d/state" "${pf%/*}"
  [ "$content" = NOFILE ] || printf '%s' "$content" > "$pf"
  printf 'package:%s\n' "$@" > "$d/pkgs"
  {
    printf 'D=%s\nTROOT=%s\nSTATE=%s\nLOG=%s\n' "$d" "$d/root" "$d/state" "$d/log"
    printf '%s\n' "$STUBS"
    cat "$fn"
    printf 'grant_perms_for %s "%s"\n' "$UIDV" "$filt"
  } > "$d/run.sh"
  "$sh" "$d/run.sh" >/dev/null 2>&1
  touch "$d/calls" "$d/log"
  for pkg in "$@"; do
    e2=$(oracle "$pf" "$filt" "$pkg"); sum=$((sum + e2))
    e1=$(printf ',%s,' "$e1spec" | sed -n "s/.*,$pkg=\([0-9]*\),.*/\1/p"); e1=${e1:-0}
    got=$(grep -cxF "grant $pkg $INET" "$d/calls")
    [ "$got" = $((e1 + e2)) ] || why="$why $pkg: $got INTERNET grant(s), want E1 $e1 + E2 $e2;"
  done
  if [ "$content" = NOFILE ] && [ -z "$filt" ]; then
    grep -q -- "-> 0 perms (no file, user $UIDV)" "$d/log" || why="$why log '$(cat "$d/log")' lacks the no-file return;"
  elif [ "$content" = NOFILE ]; then
    n=$(sed -n 's/.*-> 0 perms (no file) + \([0-9]*\) INTERNET default(s) (user .*/\1/p' "$d/log")
    [ "$n" = "$sum" ] || why="$why log says '${n:-<no line>}' INTERNET default(s) on the no-file path, oracle says $sum;"
  else
    n=$(sed -n 's/.*-> [0-9]* perms + \([0-9]*\) INTERNET default(s).*/\1/p' "$d/log")
    [ "$n" = "$sum" ] || why="$why log says '${n:-<no line>}' INTERNET default(s), grep -qxF oracle says $sum;"
  fi
  case "$extra" in
    "") ;;
    revoke1:*)  [ "$(grep -cxF "revoke ${extra#revoke1:} $INET" "$d/calls")" = 1 ] || why="$why want exactly one revoke of ${extra#revoke1:};" ;;
    nogrant)    ! grep -q '^grant ' "$d/calls" || why="$why want no grant at all, got: $(tr '\n' ';' < "$d/calls");" ;;
    logpfx:*)   grep -qF -- "${extra#logpfx:}" "$d/log" || why="$why log '$(cat "$d/log")' lacks '${extra#logpfx:}';" ;;
  esac
  [ -s "$d/unexpected" ] && why="$why unmodelled: $(tr '\n' ';' < "$d/unexpected");"
  command rm -rf "$d"
  if [ -z "$why" ]; then ok "$label [$sh]"; else no "$label [$sh] --$why"; fi
}

suite() {  # suite <roamd.sh> [quiet] -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" quiet="${2:-}" fn p=0 x=0 sh rc NL
  ok() { p=$((p+1)); [ -n "$quiet" ] || printf '  ok    %s\n' "$1"; }
  no() { x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  %s\n' "$1"; }
  fn=$(mktemp)
  prep_fn "$f" "$fn"; rc=$?
  [ "$rc" = 0 ] || { command rm -f "$fn"; return 2; }
  NL=$'\n'
  for sh in $SHELLS; do
    fixture "$fn" "$sh" "F1 prefix collision: com.foobar's line does not skip com.foo" "" \
      "com.foobar $INET$NL" "com.foobar=1" "" com.foo com.foobar
    fixture "$fn" "$sh" "F2 suffix collision: xcom.foo's line does not skip com.foo" "" \
      "xcom.foo $INET$NL" "xcom.foo=1" "" com.foo xcom.foo
    fixture "$fn" "$sh" "F3 the package's INTERNET line is the FIRST line" "" \
      "com.foo $INET${NL}com.bar android.permission.CAMERA$NL" "com.foo=1" "" com.foo com.bar
    fixture "$fn" "$sh" "F4 ... the LAST line, no trailing newline -> no INTERNET grant (pinned quirk)" "" \
      "com.bar android.permission.CAMERA${NL}com.foo $INET" "" "" com.foo com.bar
    fixture "$fn" "$sh" "F5 a deny line: no default, and the deny loop revokes once" "" \
      "com.foo deny:$INET$NL" "" "revoke1:com.foo" com.foo
    fixture "$fn" "$sh" "F6 other perms but no INTERNET line -> default granted" "" \
      "com.foo android.permission.CAMERA${NL}com.foo android.permission.RECORD_AUDIO$NL" "" "" com.foo
    fixture "$fn" "$sh" "F7 no lines at all for the package -> default granted" "" \
      "com.bar android.permission.CAMERA$NL" "" "" com.foo com.bar
    fixture "$fn" "$sh" "F8 pkgfilter: only the filtered package is considered" "com.foo" \
      "com.bar android.permission.CAMERA$NL" "" "logpfx:[roamd] GRANT (com.foo) -> 0 perms + 1 INTERNET default(s)" com.foo com.bar
    fixture "$fn" "$sh" "F9 a trailing space: read grants it, grep -x does not match -> granted twice" "" \
      "com.foo $INET $NL" "com.foo=1" "" com.foo
    fixture "$fn" "$sh" "F10 a permission-suffix collision (INTERNET_X) does not skip the default" "" \
      "com.foo ${INET}_X$NL" "" "" com.foo
    fixture "$fn" "$sh" "F11 no nowhere-perms file: early return, no default (pinned, not endorsed)" "" \
      NOFILE "" "nogrant" com.foo
    fixture "$fn" "$sh" "F12 an empty nowhere-perms -> default granted" "" \
      "" "" "" com.foo
    fixture "$fn" "$sh" "F13 no nowhere-perms file, pkgfilter: the default for that package only" "com.foo" \
      NOFILE "" "" com.foo com.bar
  done
  command rm -f "$fn"
  [ -n "$quiet" ] || printf '  -- %d ok, %d failed\n' "$p" "$x"
  [ "$x" -eq 0 ] && return 0 || return 1
}

echo "grant_perms_for INTERNET default vs grep -qxF: $SUT"
echo "shells: $SHELLS"
suite "$SUT"; rc=$?
[ "$rc" = 2 ] && exit 2          # the harness could not extract, rewrite or parse the function
[ "$rc" = 0 ] || FAILED=1

if [ "$MUTATE" = yes ]; then
  echo
  echo "mutations (each must CONVICT):"
  mtmp=$(mktemp -d)
  mutate() {  # <label> <sed program>
    local label="$1" prog="$2" mf="$mtmp/r.sh" r
    if ! sed "$prog" "$SUT" > "$mf"; then printf '  ERR   %-56s sed program failed\n' "$label"; MFAIL=1; return; fi
    if cmp -s "$SUT" "$mf"; then printf '  SKIP  %-56s mutation was a NO-OP\n' "$label"; MFAIL=1; return; fi
    suite "$mf" quiet >/dev/null 2>&1; r=$?
    case "$r" in
      0) printf '  XX    %-56s SURVIVED\n' "$label"; MFAIL=1 ;;
      1) printf '  ok    %-56s convicted\n' "$label" ;;
      *) printf '  ERR   %-56s harness error (rc=%s), not a conviction\n' "$label" "$r"; MFAIL=1 ;;
    esac
  }
  mutate 'm1 the INTERNET match loses its leading ${NL}' \
    's/\*"\${NL}\${dpkg} android.permission.INTERNET\${NL}"\*/*"${dpkg} android.permission.INTERNET${NL}"*/'
  mutate 'm2 the INTERNET match loses its trailing ${NL}' \
    's/\*"\${NL}\${dpkg} android.permission.INTERNET\${NL}"\*/*"${NL}${dpkg} android.permission.INTERNET"*/'
  mutate 'm3 the deny case line is deleted' \
    '/^    case "\$_pfx" in \*"\${NL}\${dpkg} deny:android.permission.INTERNET\${NL}"\*) continue;; esac$/d'
  mutate 'm4 the default loop ignores pkgfilter' \
    '/^    \[ -n "\$pkgfilter" \] && \[ "\$dpkg" != "\$pkgfilter" \] && continue$/d'
  echo
  [ "${MFAIL:-0}" = 0 ] && echo "ALL MUTATIONS BEHAVED" || { echo "PROBLEM: a mutation did not behave"; FAILED=1; }
  command rm -rf "$mtmp"
fi

exit "${FAILED:-0}"
