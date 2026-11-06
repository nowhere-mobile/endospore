#!/usr/bin/env bash
# test-keystore-push-merge.sh [<nowhere_roamd.sh>] [--mutate] -- keystore_push's #keys MERGE, its precedence and its
# nothing-fresh early return (#632, "keep me signed in").
#
# WHY THIS IS COMMITTED. keystore_push seals `agent push <name>#keys <stage>`, and the agent seals the DIRECTORY as the
# whole scope: anything missing from the stage is DESTROYED in the store. The stage is therefore a merge -- KS_IN (restored,
# app never opened), then KS_IMPORT (named through KS_MAP), then KS_EXPORT (this session's fresh dump, which wins) -- and
# that merge is the only thing keeping an unopened app's carried keys in the store. Losing it broke "keep me signed in"
# irreversibly the first time a session skipped an app. Until this suite nothing executed the merge, its precedence, or
# the early return that leaves the head untouched when nothing is fresh; the backlog row stays NEEDS-DEVICE (its closing
# condition is a real session that skips the app) but the merge is pinned off-device here.
#
# The function is extracted from nowhere_roamd.sh BY ANCHOR, never copied, and its one stage path ($STATE/keystore-stage)
# is rewritten under a scratch root (the rewrite must hit exactly one line, or the harness stops). pw/qn/print/timeout are
# stubbed and AGENT is a script that records `ls -1` and the contents of its stage-dir argument, then exits $AGENT_RC.
# Each case runs under bash and sh, plus dash and mksh where installed -- roamd is #!/system/bin/sh (mksh on the device).
#
# ASSERTED (NWP-20261016-30): the sealed line's "dropped" field counts every namespace the merge drops for want of a KS_MAP
# package, in the export loop (K5) and the KS_IMPORT loop (K8), each logged; an ordinary merge still says `0 dropped` (K16);
# and an unmapped drop alone pushes nothing -- the early return still fires and the carried bundle is untouched (K9).
#
# ASSERTED (NWP-20261102-05, Q049): the DROP filter. A package named in $KS_DROP (first line exactly `# <uid of this op>`) has its
# bundle removed from the stage whichever source put it there -- KS_IN, KS_IMPORT or KS_EXPORT -- the others stay, and the sealed
# line counts the removals (K10). Another uid's list filters nothing and pushes nothing (K11), an absent or header-only list
# filters nothing (K12), a drop with no fresh dump pushes NOTHING and logs the deferral because a consumed bundle may live only
# inside keystore2 (K13), an empty uid pushes nothing at all (K14, NWP-20261114-08), and the nothing-fresh early return answers `nothing` rather than
# `notsealed` when there is no dump and no list (K15). Mutants D1-D5 and D7 each have to be convicted.
#
# ASSERTED (NWP-20261112-01): KS_IN holds one dir per Android user (<uid>/<pkg>.keys, ks_in_dir, extracted with
# keystore_push), and the merge carries only THIS op's user's restored bundles: another user's are never sealed into this
# profile's #keys (K1). Mutant K1m (the carry loop reads every user's dir) has to be convicted.
#
# ASSERTED (NWP-20261114-08): KS_IMPORT and KS_EXPORT are flat dirs of every Android user's <ns>.keys, ns = uid*100000 +
# appId, and a reap stages, waits for and removes only its own uid's (ks_ns_mine, extracted with keystore_push). Another
# user's import for the same package is not staged over this user's (K17); another user's dump is neither staged nor
# removed (K18), alone it pushes nothing (K19) and does not end the wait (K20; K20b: this user's dump means no wait); a
# name that is not <uid><5 digits> is never staged (K21); an empty uid owns nothing and pushes nothing (K14). The fixtures
# use real uid-10 namespaces (1010001, ...) for that reason. `keystore_push wait` runs with sleep stubbed to a counter.
# Mutants R1-R6 each have to be convicted; D6 is retired (an equivalent mutant since ks_ns_mine, see the mutant list).
#
# ASSERTED (NWP-20261116-08, h46 #2 (1)): keystore_push stages under $STATE (the state tmpfs), never under /data/nowhere
# (T1, a static check on the unrewritten function). Mutant T1m (the old f2fs path) has to be convicted.
#
# ASSERTED (NWP-20261119-06): the #keys stage is whole, or nothing is pushed. Each of the three stage copies (KS_IN,
# KS_IMPORT, KS_EXPORT) counts only when cmp finds the copy identical to its source. A copy that fails (K-W1 KS_IN, K-W2
# KS_IMPORT, K-W3 KS_EXPORT) or lands short with rc 0 (K-W4) makes keystore_push log one count-only line, remove the stage
# and return 1 with verdict notsealed, without an agent call; every source file stays. An all-whole merge seals as before
# (K-W0). A `cp` stub in the extracted script does this: CPFAIL=<dest basename> fails that copy, CPSHORT=<dest basename>
# writes its first byte only and returns 0. The recording AGENT keeps the real cp. Mutants W1-W5 have to be convicted.
#
#   bash test-keystore-push-merge.sh            # the behaviour cases
#   bash test-keystore-push-merge.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

W=$(mktemp -d) || exit 2          # the ONE scratch root: every other temp is made inside it
trap 'rm -rf "$W"' EXIT

SHELLS="bash sh"
for s in mksh dash; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done

# mksh's builtin, as these scripts use it: print -r -- / print -rn --.
PRINT_SHIM='print() { local nl=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) nl=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$nl" = 1 ]; then printf "%s\n" "$*"; else printf "%s" "$*"; fi; }'

STUBS="$PRINT_SHIM"'
pw() { printf "%s" "$1"; }
qn() { printf "%s" "$1"; }
timeout() { shift 3; "$@"; }
ks_prog() { :; }
cp() { case "${2##*/}" in "${CPFAIL:-/}") return 1 ;; "${CPSHORT:-/}") head -c 1 "$1" > "$2"; return 0 ;; esac; command cp "$@"; }
'

# prep_fn <roamd.sh> <out> -- extract ks_in_dir + ks_ns_mine + keystore_push and point its stage under $TROOT. 0 ok, 2 harness error.
prep_fn() {
  local sut="$1" out="$2" raw ksd ksn
  ksd=$(mktemp -p "$W"); ksn=$(mktemp -p "$W")
  sed -n '/^ks_in_dir() {$/,/^}$/p' "$sut" > "$ksd"
  if [ ! -s "$ksd" ] || [ "$(head -1 "$ksd")" != 'ks_in_dir() {' ] || [ "$(tail -1 "$ksd")" != '}' ]; then
    echo "EXTRACTION FAILED: ks_in_dir() { ... } not found in $sut" >&2; command rm -f "$ksd" "$ksn"; return 2
  fi
  sed -n '/^ks_ns_mine() {$/,/^}$/p' "$sut" > "$ksn"
  if [ ! -s "$ksn" ] || [ "$(head -1 "$ksn")" != 'ks_ns_mine() {' ] || [ "$(tail -1 "$ksn")" != '}' ]; then
    echo "EXTRACTION FAILED: ks_ns_mine() { ... } not found in $sut" >&2; command rm -f "$ksd" "$ksn"; return 2
  fi
  raw=$(mktemp -p "$W")
  sed -n '/^keystore_push() {$/,/^}$/p' "$sut" > "$raw"
  if [ ! -s "$raw" ] || [ "$(head -1 "$raw")" != 'keystore_push() {' ] || [ "$(tail -1 "$raw")" != '}' ]; then
    echo "EXTRACTION FAILED: keystore_push() { ... } not found in $sut" >&2; command rm -f "$raw" "$ksd" "$ksn"; return 2
  fi
  { cat "$ksd" "$ksn"; sed 's#^  KSTAGE="\$STATE/keystore-stage"$#  KSTAGE="$TROOT/keystore-stage"#' "$raw"; } > "$out"
  command rm -f "$raw" "$ksd" "$ksn"
  if [ "$(grep -c 'KSTAGE="\$TROOT/keystore-stage"' "$out")" != 1 ] || [ "$(grep -c '/data/nowhere' "$out")" != 0 ]; then
    echo "REWRITE FAILED: want exactly one KSTAGE="$STATE/keystore-stage" line in keystore_push of $sut" >&2; return 2
  fi
  if ! bash -n "$out" || ! sh -n "$out"; then
    echo "EXTRACTION FAILED: keystore_push does not parse ($sut)" >&2; return 2
  fi
  return 0
}

# newcase -> prints a fresh scratch dir holding empty in/10/ (uid 10's keystore-in) imp/ exp/ dirs, an empty map and the recording AGENT.
newcase() {
  local d; d=$(mktemp -d -p "$W")
  mkdir -p "$d/in/10" "$d/imp" "$d/exp" "$d/seen"
  : > "$d/map"
  cat > "$d/agent.sh" <<'AG'
#!/bin/sh
echo "$*" >> "$D/agent.calls"
ls -1 "$5" > "$D/agent.ls"
for f in "$5"/*; do [ -e "$f" ] && cp "$f" "$D/seen/$(basename "$f")"; done
exit "$AGENT_RC"
AG
  printf '%s\n' "$d"
}

# put <dir> <file> <content>
put() { printf '%s' "$3" > "$1/$2"; }

# runcase <fn> <shell> <dir> [name] [pass] [agent_rc] -- runs keystore_push once; leaves rc/verdict in <dir>/res.
# A case that writes `wait` to <dir>/mode runs `keystore_push wait`; each stubbed sleep adds a line to <dir>/sleeps.
runcase() {
  local fn="$1" sh="$2" d="$3" nm="${4-prof}" pa="${5-secret}" arc="${6:-0}" mode=""
  [ -e "$d/mode" ] && mode=$(cat "$d/mode")
  {
    printf 'D=%s\nTROOT=%s\nLOG=%s\nKS_IN=%s\nKS_IMPORT=%s\nKS_EXPORT=%s\nKS_MAP=%s\nKS_DROP=%s\n' \
      "$d" "$d" "$d/log" "$d/in" "$d/imp" "$d/exp" "$d/map" "$d/drop"
    # The op's uid: 10 unless the case wrote $d/uid (an empty file = no uid in scope).
    printf "uid='%s'\n" "$( [ -e "$d/uid" ] && cat "$d/uid" || printf 10 )"
    printf 'AGENT=%s\nAGENT_RC=%s\nname=%s\npass=%s\nexport D AGENT_RC\n' "$d/agent.sh" "$arc" "'$nm'" "'$pa'"
    # NWP-20261119-06: the cp stub's targets, from <dir>/cpfail and <dir>/cpshort (absent = no target).
    printf "CPFAIL='%s'\nCPSHORT='%s'\n" "$( [ -e "$d/cpfail" ] && cat "$d/cpfail" )" "$( [ -e "$d/cpshort" ] && cat "$d/cpshort" )"
    printf '%s\n' "$STUBS"
    # wait mode (NWP-20261114-08): `keystore_push wait`, with sleep recorded instead of slept, so the 30 s bound costs nothing.
    # Otherwise (NWP-20261116-10) sleep is a no-op, so the #keys retry ladder after a failed push (K7) costs nothing.
    if [ "$mode" = wait ]; then printf '%s\n' 'sleep() { echo s >> "$D/sleeps"; }'; else printf '%s\n' 'sleep() { :; }'; fi
    cat "$fn"
    printf 'keystore_push %s\nprintf "rc=%%s verdict=%%s\\n" "$?" "$KS_VERDICT" > "$D/res"\n' "$mode"
  } > "$d/run.sh"
  chmod +x "$d/agent.sh"
  "$sh" "$d/run.sh" >/dev/null 2>&1
  touch "$d/log" "$d/agent.calls" "$d/agent.ls" "$d/sleeps"
}

SKIPLINE='bundle(s) not named for this user left in place'   # keystore_push's count-only skip line (NWP-20261114-08)
# wfix <dir> -- the K-W fixture: uid 10 carries com.a and com.b (KS_IN), and com.c (ns 1010001) has a fresh dump.
wfix() {
  local d="$1"
  put "$d/in/10" com.a.keys carried-a; put "$d/in/10" com.b.keys carried-b
  echo '1010001 com.c' >> "$d/map"; put "$d/exp" 1010001.keys fresh-c
}

staged() { tr '\n' ' ' < "$1/agent.ls" | sed 's/ $//'; }
exported() { ls "$1"/exp/*.keys 2>/dev/null | wc -l | tr -d ' '; }

suite() {  # suite <roamd.sh> [quiet] -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" quiet="${2:-}" fn p=0 x=0 sh rc d why m n
  ok() { p=$((p+1)); [ -n "$quiet" ] || printf '  ok    %s\n' "$1"; }
  no() { x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  %s\n' "$1"; }
  fin() {  # fin <label> <dir> -- report the accumulated $why, drop the scratch dir
    if [ -z "$why" ]; then ok "$1 [$sh]"; else no "$1 [$sh] --$why"; fi
    command rm -rf "$2"
  }
  wrefused() {  # wrefused <dir> -- NWP-20261119-06: a stage that is not whole is refused, and every source stays
    local d="$1" n
    [ ! -s "$d/agent.calls" ] || why="$why AGENT was called;"
    [ "$(cat "$d/res")" = "rc=1 verdict=notsealed" ] || why="$why $(cat "$d/res");"
    n=$(grep -c 'keystore_push: 1 bundle(s) could not be staged whole -- #keys NOT pushed' "$d/log")
    [ "$n" = 1 ] || why="$why $n refusal line(s), want 1;"
    ! grep -qF 'com.' "$d/log" || why="$why a package name reached the log;"
    [ ! -e "$d/keystore-stage" ] || why="$why the stage was left;"
    [ "$(cat "$d/in/10/com.a.keys" 2>/dev/null)" = carried-a ] || why="$why in/10/com.a.keys disturbed;"
    [ "$(cat "$d/in/10/com.b.keys" 2>/dev/null)" = carried-b ] || why="$why in/10/com.b.keys disturbed;"
    [ "$(cat "$d/exp/1010001.keys" 2>/dev/null)" = fresh-c ] || why="$why exp/1010001.keys disturbed;"
  }
  # T1 (NWP-20261116-08, h46 #2 (1)): the RAW function stages on the state tmpfs, never on /data/nowhere (f2fs). It runs
  # before prep_fn, so the old-path mutant is a conviction (rc 1) and not a REWRITE FAILED harness error (rc 2).
  local t1raw t1n t1line t1dn
  t1raw=$(mktemp -p "$W")
  sed -n '/^keystore_push() {$/,/^}$/p' "$f" > "$t1raw"
  t1n=$(grep -c '^[[:space:]]*KSTAGE=' "$t1raw")
  t1line=$(grep '^[[:space:]]*KSTAGE=' "$t1raw")
  t1dn=$(grep -c '/data/nowhere' "$t1raw")
  command rm -f "$t1raw"
  if [ "$t1n" = 1 ] && [ "$t1line" = '  KSTAGE="$STATE/keystore-stage"' ] && [ "$t1dn" = 0 ]; then
    ok 'T1 keystore_push stages under $STATE, never /data/nowhere'
  else
    no "T1 keystore_push stages under \$STATE, never /data/nowhere -- $t1n KSTAGE= line(s): '$t1line'; $t1dn /data/nowhere line(s)"
    return 1
  fi
  fn=$(mktemp -p "$W")
  prep_fn "$f" "$fn"; rc=$?
  [ "$rc" = 0 ] || { command rm -f "$fn"; return 2; }
  for sh in $SHELLS; do
    # K1 (NWP-20261112-01): only this op's user's keystore-in dir is carried; another user's restored bundle is not staged
    d=$(newcase); why=""
    echo "1010001 com.x" > "$d/map"; put "$d/exp" 1010001.keys fx; put "$d/in/10" a.keys a
    mkdir "$d/in/11"; put "$d/in/11" b.keys b
    runcase "$fn" "$sh" "$d"
    [ "$(staged "$d")" = "a.keys com.x.keys" ] || why="$why staged '$(staged "$d")', want 'a.keys com.x.keys' (no b.keys);"
    grep -qF '#keys sealed (2 pkg, 1 fresh, 0 dropped)' "$d/log" || why="$why sealed line missing: $(cat "$d/log");"
    [ "$(cat "$d/in/11/b.keys" 2>/dev/null)" = b ] || why="$why user 11's bundle disturbed;"
    fin "K1 uid 10: keystore-in/10's a.keys staged, keystore-in/11's b.keys not" "$d"

    # K16: a fresh dump is merged with the carried bundle; sealed line counts the TOTAL; export is emptied
    d=$(newcase); why=""
    echo "1010001 com.a" > "$d/map"; put "$d/exp" 1010001.keys fresh; put "$d/in/10" com.b.keys carried
    runcase "$fn" "$sh" "$d"
    [ "$(staged "$d")" = "com.a.keys com.b.keys" ] || why="$why staged '$(staged "$d")', want 'com.a.keys com.b.keys';"
    grep -qF '#keys sealed (2 pkg, 1 fresh, 0 dropped)' "$d/log" || why="$why sealed line missing: $(cat "$d/log");"
    [ "$(exported "$d")" = 0 ] || why="$why export not emptied;"
    [ "$(cat "$d/res")" = "rc=0 verdict=sealed" ] || why="$why $(cat "$d/res");"
    [ ! -e "$d/keystore-stage" ] || why="$why stage dir left behind;"
    fin "K16 export 1010001->com.a + KS_IN com.b -> both staged, sealed total 2" "$d"

    # K2: precedence -- KS_IN < KS_IMPORT < KS_EXPORT, per package
    d=$(newcase); why=""
    printf '1010002 com.a\n1010003 com.a\n' > "$d/map"; put "$d/in/10" com.a.keys old; put "$d/imp" 1010002.keys mid
    put "$d/exp" 1010009.keys x; echo "1010009 com.z" >> "$d/map"
    runcase "$fn" "$sh" "$d"
    [ "$(cat "$d/seen/com.a.keys" 2>/dev/null)" = mid ] || why="$why KS_IMPORT did not beat KS_IN: '$(cat "$d/seen/com.a.keys" 2>/dev/null)';"
    command rm -rf "$d/seen"; mkdir "$d/seen"; command rm -f "$d/agent.calls"
    put "$d/exp" 1010003.keys new
    runcase "$fn" "$sh" "$d"
    [ "$(cat "$d/seen/com.a.keys" 2>/dev/null)" = new ] || why="$why KS_EXPORT did not win: '$(cat "$d/seen/com.a.keys" 2>/dev/null)';"
    fin "K2 precedence: KS_IMPORT beats KS_IN, a fresh dump beats both" "$d"

    # K3: no fresh dump -> nothing sealed, stage gone, carried bundle untouched
    d=$(newcase); why=""
    put "$d/in/10" com.b.keys carried; rmdir "$d/exp"
    runcase "$fn" "$sh" "$d"
    [ ! -s "$d/agent.calls" ] || why="$why AGENT was called: $(cat "$d/agent.calls");"
    [ ! -e "$d/keystore-stage" ] || why="$why stage dir left behind;"
    [ "$(cat "$d/in/10/com.b.keys" 2>/dev/null)" = carried ] || why="$why KS_IN bundle disturbed;"
    [ "$(cat "$d/res")" = "rc=0 verdict=nothing" ] || why="$why $(cat "$d/res");"
    fin "K3 no fresh dump: no AGENT call, stage removed, KS_IN untouched" "$d"

    # K4: an empty export dir (literal glob) must not log a mapping line
    d=$(newcase); why=""
    put "$d/in/10" com.b.keys carried
    runcase "$fn" "$sh" "$d"
    ! grep -qF 'has no package mapping' "$d/log" || why="$why false mapping line: $(cat "$d/log");"
    [ ! -s "$d/agent.calls" ] || why="$why AGENT was called;"
    ! grep -qF "$SKIPLINE" "$d/log" || why="$why the literal glob was counted as a skip: $(cat "$d/log");"
    fin "K4 empty export dir: no 'has no package mapping' line" "$d"
    # ... and on the path that still reaches the export loop with nothing exported (a drop list of this uid that
    # names a package nobody carries): the loop's guard is what keeps the literal glob out of the log.
    d=$(newcase); why=""
    put "$d/in/10" com.b.keys carried; printf '# 10\ncom.q\n' > "$d/drop"
    runcase "$fn" "$sh" "$d"
    ! grep -qF 'has no package mapping' "$d/log" || why="$why false mapping line: $(cat "$d/log");"
    [ ! -s "$d/agent.calls" ] || why="$why AGENT was called;"
    ! grep -qF "$SKIPLINE" "$d/log" || why="$why the literal glob was counted as a skip: $(cat "$d/log");"
    fin "K4b empty export dir, drop list naming nothing carried: no 'has no package mapping' line" "$d"

    # K5: an unmapped export namespace is dropped and logged; the others still seal
    d=$(newcase); why=""
    echo "1010001 com.a" > "$d/map"; put "$d/exp" 1010001.keys fresh; put "$d/exp" 1010099.keys orphan
    runcase "$fn" "$sh" "$d"
    grep -qF 'ns 1010099 has no package mapping, dropped' "$d/log" || why="$why no drop line: $(cat "$d/log");"
    [ "$(staged "$d")" = "com.a.keys" ] || why="$why staged '$(staged "$d")', want 'com.a.keys';"
    grep -qF '#keys sealed (1 pkg, 1 fresh, 1 dropped)' "$d/log" || why="$why sealed line missing: $(cat "$d/log");"
    fin "K5 unmapped export ns is dropped, logged and counted, the rest seal" "$d"

    # K8: an unmapped KS_IMPORT bundle is dropped with a log line and counted; the mapped fresh export still seals
    d=$(newcase); why=""
    echo "1010001 com.a" > "$d/map"; put "$d/exp" 1010001.keys fresh; put "$d/imp" 1010098.keys staged
    runcase "$fn" "$sh" "$d"
    grep -qF 'staged import ns 1010098 has no package mapping, dropped' "$d/log" || why="$why no import drop line: $(cat "$d/log");"
    [ "$(staged "$d")" = "com.a.keys" ] || why="$why staged '$(staged "$d")', want 'com.a.keys';"
    grep -qF '#keys sealed (1 pkg, 1 fresh, 1 dropped)' "$d/log" || why="$why sealed line missing: $(cat "$d/log");"
    fin "K8 unmapped import ns is dropped, logged and counted, the rest seal" "$d"

    # K9: an unmapped drop alone pushes nothing -- the early return still fires and the carried bundle is untouched
    d=$(newcase); why=""
    put "$d/exp" 1010099.keys orphan; put "$d/in/10" com.b.keys carried
    runcase "$fn" "$sh" "$d"
    grep -qF 'ns 1010099 has no package mapping, dropped' "$d/log" || why="$why no drop line: $(cat "$d/log");"
    [ ! -s "$d/agent.calls" ] || why="$why AGENT was called: $(cat "$d/agent.calls");"
    [ "$(cat "$d/in/10/com.b.keys" 2>/dev/null)" = carried ] || why="$why KS_IN bundle disturbed;"
    [ ! -e "$d/keystore-stage" ] || why="$why stage dir left behind;"
    fin "K9 unmapped drop and nothing fresh: no AGENT call, KS_IN untouched" "$d"

    # K6: no creds on this op -> deferred, notsealed, dump kept
    for cred in "name" "pass"; do
      d=$(newcase); why=""
      echo "1010001 com.a" > "$d/map"; put "$d/exp" 1010001.keys fresh
      if [ "$cred" = name ]; then runcase "$fn" "$sh" "$d" "" secret; else runcase "$fn" "$sh" "$d" prof ""; fi
      grep -qF 'keystore_push deferred (no creds on this op)' "$d/log" || why="$why no deferred line;"
      [ "$(cat "$d/res")" = "rc=0 verdict=notsealed" ] || why="$why $(cat "$d/res");"
      [ "$(exported "$d")" = 1 ] || why="$why export not kept;"
      [ ! -s "$d/agent.calls" ] || why="$why AGENT was called;"
      fin "K6 empty $cred: deferred, notsealed, export kept" "$d"
    done

    # K7: the agent's failure is returned and the dump is not deleted
    d=$(newcase); why=""
    echo "1010001 com.a" > "$d/map"; put "$d/exp" 1010001.keys fresh
    runcase "$fn" "$sh" "$d" prof secret 3
    [ "$(cat "$d/res")" = "rc=3 verdict=notsealed" ] || why="$why $(cat "$d/res");"
    [ "$(exported "$d")" = 1 ] || why="$why export deleted after a failed push;"
    [ ! -e "$d/keystore-stage" ] || why="$why stage dir left behind;"
    fin "K7 AGENT_RC=3 -> return 3, notsealed, export kept" "$d"

    # K10: the drop list removes a listed package's bundle from KS_IN, KS_IMPORT and KS_EXPORT alike; the others stay
    d=$(newcase); why=""
    printf '1010001 com.x\n1010002 com.y\n1010003 com.k\n' > "$d/map"
    put "$d/exp" 1010001.keys fx; put "$d/exp" 1010003.keys fk; put "$d/imp" 1010002.keys iy
    put "$d/in/10" com.z.keys cz; put "$d/in/10" com.b.keys cb
    printf '# 10\ncom.x\ncom.y\ncom.z\n' > "$d/drop"
    runcase "$fn" "$sh" "$d"
    [ "$(staged "$d")" = "com.b.keys com.k.keys" ] || why="$why staged '$(staged "$d")', want 'com.b.keys com.k.keys';"
    grep -qF '#keys sealed (2 pkg, 2 fresh, 3 dropped)' "$d/log" || why="$why sealed line missing: $(cat "$d/log");"
    ! grep -qE 'com\.(x|y|z)' "$d/log" || why="$why a dropped package name reached the log;"
    [ "$(cat "$d/res")" = "rc=0 verdict=sealed" ] || why="$why $(cat "$d/res");"
    [ ! -e "$d/keystore-stage" ] || why="$why stage dir left behind;"
    fin "K10 drop list removes KS_IN, KS_IMPORT and KS_EXPORT bundles, keeps the rest, counts 3" "$d"

    # K11: another uid's list filters nothing and, on its own, pushes nothing
    d=$(newcase); why=""
    echo "1010001 com.x" > "$d/map"; put "$d/exp" 1010001.keys fx; put "$d/in/10" com.b.keys cb
    printf '# 11\ncom.x\n' > "$d/drop"
    runcase "$fn" "$sh" "$d"
    [ "$(staged "$d")" = "com.b.keys com.x.keys" ] || why="$why staged '$(staged "$d")', want 'com.b.keys com.x.keys';"
    grep -qF '#keys sealed (2 pkg, 1 fresh, 0 dropped)' "$d/log" || why="$why sealed line missing: $(cat "$d/log");"
    fin "K11a another uid's list with a fresh dump: nothing filtered" "$d"
    d=$(newcase); why=""
    put "$d/in/10" com.x.keys cx; printf '# 11\ncom.x\n' > "$d/drop"
    runcase "$fn" "$sh" "$d"
    [ ! -s "$d/agent.calls" ] || why="$why AGENT was called: $(cat "$d/agent.calls");"
    ! grep -qF 'deferred: no dump landed' "$d/log" || why="$why a foreign list deferred a drop;"
    [ "$(cat "$d/in/10/com.x.keys" 2>/dev/null)" = cx ] || why="$why KS_IN bundle disturbed;"
    [ "$(cat "$d/res")" = "rc=0 verdict=nothing" ] || why="$why $(cat "$d/res");"
    fin "K11b another uid's list, no dump: no AGENT call, no deferral line, KS_IN untouched" "$d"

    # K12: an absent list, and a header-only one, filter nothing
    for lst in absent header; do
      d=$(newcase); why=""
      echo "1010001 com.x" > "$d/map"; put "$d/exp" 1010001.keys fx; put "$d/in/10" com.b.keys cb
      [ "$lst" = header ] && printf '# 10\n' > "$d/drop"
      runcase "$fn" "$sh" "$d"
      [ "$(staged "$d")" = "com.b.keys com.x.keys" ] || why="$why staged '$(staged "$d")';"
      grep -qF '#keys sealed (2 pkg, 1 fresh, 0 dropped)' "$d/log" || why="$why sealed line missing: $(cat "$d/log");"
      fin "K12 $lst list: nothing filtered, 0 dropped" "$d"
    done

    # K13: a drop with no fresh dump pushes nothing -- a consumed bundle may live only inside keystore2
    d=$(newcase); why=""
    put "$d/in/10" com.z.keys cz; put "$d/in/10" com.b.keys cb; printf '# 10\ncom.z\n' > "$d/drop"
    runcase "$fn" "$sh" "$d"
    [ ! -s "$d/agent.calls" ] || why="$why AGENT was called: $(cat "$d/agent.calls");"
    grep -qF '#keys drop of 1 deferred: no dump landed' "$d/log" || why="$why no deferral line: $(cat "$d/log");"
    ! grep -qF 'com.z' "$d/log" || why="$why a dropped package name reached the log;"
    [ "$(cat "$d/in/10/com.z.keys" 2>/dev/null)" = cz ] || why="$why KS_IN bundle disturbed;"
    [ ! -e "$d/keystore-stage" ] || why="$why stage dir left behind;"
    [ "$(cat "$d/res")" = "rc=0 verdict=nothing" ] || why="$why $(cat "$d/res");"
    fin "K13 drop, no fresh dump: deferred, no AGENT call, KS_IN untouched" "$d"

    # K14 (NWP-20261114-08): no uid in scope owns no bundle -- even a list whose header is the empty uid pushes nothing
    d=$(newcase); why=""
    echo "1010001 com.x" > "$d/map"; put "$d/exp" 1010001.keys fx; : > "$d/uid"
    printf '# \ncom.x\n' > "$d/drop"
    runcase "$fn" "$sh" "$d"
    [ ! -s "$d/agent.calls" ] || why="$why AGENT was called: $(cat "$d/agent.calls");"
    [ "$(cat "$d/res")" = "rc=0 verdict=nothing" ] || why="$why $(cat "$d/res");"
    [ "$(cat "$d/exp/1010001.keys" 2>/dev/null)" = fx ] || why="$why the export file was disturbed;"
    fin "K14 empty uid: no AGENT call, verdict nothing, export untouched" "$d"

    # K17 (NWP-20261114-08): another user's import for the same package is never staged; this user's bytes are sealed
    d=$(newcase); why=""
    printf '1010234 com.ex\n1110234 com.ex\n1010001 com.y\n' > "$d/map"
    put "$d/imp" 1010234.keys A; put "$d/imp" 1110234.keys B; put "$d/exp" 1010001.keys fy
    runcase "$fn" "$sh" "$d"
    [ "$(cat "$d/seen/com.ex.keys" 2>/dev/null)" = A ] || why="$why staged com.ex.keys is '$(cat "$d/seen/com.ex.keys" 2>/dev/null)', want A;"
    [ "$(cat "$d/imp/1110234.keys" 2>/dev/null)" = B ] || why="$why user 11's import disturbed;"
    grep -qF '#keys sealed (2 pkg, 1 fresh, 0 dropped)' "$d/log" || why="$why sealed line missing: $(cat "$d/log");"
    [ "$(grep -c "$SKIPLINE" "$d/log")" = 1 ] || why="$why want one skip line: $(cat "$d/log");"
    grep -qF "keystore_push: 1 $SKIPLINE" "$d/log" || why="$why skip line does not count 1: $(cat "$d/log");"
    ! grep -qF 1110234 "$d/log" || why="$why the other user's ns reached the log;"
    fin "K17 uid 10: import 1010234 (A) staged as com.ex, 1110234 (B) left in place" "$d"

    # K18: another user's dump is neither staged nor removed; this user's dump is removed after the seal
    d=$(newcase); why=""
    printf '1010001 com.a\n1210002 com.b\n' > "$d/map"; put "$d/exp" 1010001.keys fa; put "$d/exp" 1210002.keys fb
    runcase "$fn" "$sh" "$d"
    [ "$(staged "$d")" = "com.a.keys" ] || why="$why staged '$(staged "$d")', want 'com.a.keys';"
    [ "$(cat "$d/exp/1210002.keys" 2>/dev/null)" = fb ] || why="$why user 12's dump was removed or changed;"
    [ ! -e "$d/exp/1010001.keys" ] || why="$why this user's dump was not removed;"
    [ "$(cat "$d/res")" = "rc=0 verdict=sealed" ] || why="$why $(cat "$d/res");"
    fin "K18 dumps 1010001 + 1210002: only com.a staged, 1210002.keys survives the seal" "$d"

    # K19: the only dump is another user's -- nothing to push, nothing removed
    d=$(newcase); why=""
    echo "1210002 com.b" > "$d/map"; put "$d/exp" 1210002.keys fb; put "$d/in/10" com.c.keys cc
    runcase "$fn" "$sh" "$d"
    [ ! -s "$d/agent.calls" ] || why="$why AGENT was called: $(cat "$d/agent.calls");"
    [ "$(cat "$d/res")" = "rc=0 verdict=nothing" ] || why="$why $(cat "$d/res");"
    [ "$(cat "$d/exp/1210002.keys" 2>/dev/null)" = fb ] || why="$why user 12's dump was removed or changed;"
    ! grep -qF 'has no package mapping' "$d/log" || why="$why a mapping line for another user's dump: $(cat "$d/log");"
    fin "K19 only user 12's dump: no AGENT call, verdict nothing, file untouched" "$d"

    # K20 (wait mode): another user's dump does not end the wait for this user's
    d=$(newcase); why=""
    echo wait > "$d/mode"; echo "1210002 com.b" > "$d/map"; put "$d/exp" 1210002.keys fb
    runcase "$fn" "$sh" "$d"
    [ ! -s "$d/agent.calls" ] || why="$why AGENT was called: $(cat "$d/agent.calls");"
    [ -s "$d/sleeps" ] || why="$why the wait never slept: another user's dump ended it;"
    [ "$(cat "$d/exp/1210002.keys" 2>/dev/null)" = fb ] || why="$why user 12's dump was removed or changed;"
    fin "K20 wait, only user 12's dump: the wait sleeps, no AGENT call" "$d"
    # K20b: this user's dump present at the start -- no wait at all
    d=$(newcase); why=""
    echo wait > "$d/mode"; echo "1010001 com.a" > "$d/map"; put "$d/exp" 1010001.keys fa
    runcase "$fn" "$sh" "$d"
    [ ! -s "$d/sleeps" ] || why="$why slept $(wc -l < "$d/sleeps") time(s) with this user's dump present;"
    [ "$(cat "$d/res")" = "rc=0 verdict=sealed" ] || why="$why $(cat "$d/res");"
    fin "K20b wait, this user's dump present: no sleep, sealed" "$d"

    # K21: a name that is not <uid><5 digits> is never staged, from either dir, and never removed
    d=$(newcase); why=""
    printf 'x com.p1\n10 com.p2\n10123456 com.p3\n1010001 com.a\n' > "$d/map"
    for m in x 10 10123456; do put "$d/imp" "$m.keys" "i$m"; put "$d/exp" "$m.keys" "e$m"; done
    put "$d/exp" 1010001.keys fa
    runcase "$fn" "$sh" "$d"
    [ "$(staged "$d")" = "com.a.keys" ] || why="$why staged '$(staged "$d")', want 'com.a.keys';"
    for m in x 10 10123456; do
      [ "$(cat "$d/imp/$m.keys" 2>/dev/null)" = "i$m" ] || why="$why imp/$m.keys disturbed;"
      [ "$(cat "$d/exp/$m.keys" 2>/dev/null)" = "e$m" ] || why="$why exp/$m.keys disturbed;"
    done
    fin "K21 x.keys, 10.keys, 10123456.keys (mapped, both dirs): never staged, never removed" "$d"

    # K15: no dump and no list on a credless op is `nothing`, not a deferred-unsealed dump
    d=$(newcase); why=""
    put "$d/in/10" com.b.keys cb
    runcase "$fn" "$sh" "$d" "" ""
    ! grep -qF 'deferred (no creds' "$d/log" || why="$why a credless op deferred with no dump;"
    [ "$(cat "$d/res")" = "rc=0 verdict=nothing" ] || why="$why $(cat "$d/res");"
    fin "K15 no dump, no list, no creds: verdict nothing" "$d"

    # K-W0 (NWP-20261119-06): an all-whole merge seals as before (the cp stub's target matches no copy)
    d=$(newcase); why=""
    wfix "$d"; echo com.none.keys > "$d/cpfail"
    runcase "$fn" "$sh" "$d"
    [ "$(staged "$d")" = "com.a.keys com.b.keys com.c.keys" ] || why="$why staged '$(staged "$d")';"
    n=$(grep -c '#keys sealed (3 pkg, 1 fresh, 0 dropped)' "$d/log")
    [ "$n" = 1 ] || why="$why $n sealed line(s), want 1;"
    [ "$(cat "$d/res")" = "rc=0 verdict=sealed" ] || why="$why $(cat "$d/res");"
    fin "K-W0 an all-whole stage seals 3 pkg, 1 fresh" "$d"

    # K-W1: the copy of a KS_IN bundle fails
    d=$(newcase); why=""
    wfix "$d"; echo com.a.keys > "$d/cpfail"
    runcase "$fn" "$sh" "$d"
    wrefused "$d"
    fin "K-W1 a KS_IN copy fails: nothing pushed, notsealed, stage removed" "$d"

    # K-W2: the copy of a KS_IMPORT bundle (named through KS_MAP) fails
    d=$(newcase); why=""
    wfix "$d"; put "$d/imp" 1010002.keys import-i; echo '1010002 com.i' >> "$d/map"; echo com.i.keys > "$d/cpfail"
    runcase "$fn" "$sh" "$d"
    wrefused "$d"
    [ "$(cat "$d/imp/1010002.keys" 2>/dev/null)" = import-i ] || why="$why imp/1010002.keys disturbed;"
    fin "K-W2 a KS_IMPORT copy fails: nothing pushed, notsealed, stage removed" "$d"

    # K-W3: the copy of the KS_EXPORT dump itself fails
    d=$(newcase); why=""
    wfix "$d"; echo com.c.keys > "$d/cpfail"
    runcase "$fn" "$sh" "$d"
    wrefused "$d"
    fin "K-W3 a KS_EXPORT copy fails: nothing pushed, notsealed, stage removed" "$d"

    # K-W4: a KS_IN copy exits 0 with short bytes
    d=$(newcase); why=""
    wfix "$d"; echo com.a.keys > "$d/cpshort"
    runcase "$fn" "$sh" "$d"
    wrefused "$d"
    fin "K-W4 a KS_IN copy lands short with rc 0: refused as K-W1" "$d"
  done
  command rm -f "$fn"
  [ -n "$quiet" ] || printf '  -- %d ok, %d failed\n' "$p" "$x"
  [ "$x" -eq 0 ] && return 0 || return 1
}

echo "keystore_push #keys merge: $SUT"
echo "shells: $SHELLS"
suite "$SUT"; rc=$?
[ "$rc" = 2 ] && exit 2          # the harness could not extract, rewrite or parse the function
[ "$rc" = 0 ] || FAILED=1

if [ "$MUTATE" = yes ]; then
  echo
  echo "mutations (each must CONVICT):"
  mtmp=$(mktemp -d -p "$W")
  ALLSHELLS="$SHELLS"
  mutate() {  # <label> <sed program>   -- or, with an `awk:` prefix, an awk program
    local label="$1" prog="$2" mf="$mtmp/r.sh" r s1
    if [ "${prog#awk:}" != "$prog" ]; then awk "${prog#awk:}" "$SUT" > "$mf"; else sed "$prog" "$SUT" > "$mf"; fi
    if [ $? -ne 0 ]; then printf '  ERR   %-56s mutation program failed\n' "$label"; MFAIL=1; return; fi
    if cmp -s "$SUT" "$mf"; then printf '  SKIP  %-56s mutation was a NO-OP\n' "$label"; MFAIL=1; return; fi
    # One suite run PER shell: the suite sums failures across shells, so a single run would let one shell's
    # conviction hide a survivor on another (mksh is the device's shell).
    for s1 in $ALLSHELLS; do
      SHELLS="$s1"; suite "$mf" quiet >/dev/null 2>&1; r=$?
      case "$r" in
        0) printf '  XX    %-48s SURVIVED [%s]\n' "$label" "$s1"; MFAIL=1 ;;
        1) printf '  ok    %-48s convicted [%s]\n' "$label" "$s1" ;;
        *) printf '  ERR   %-48s harness error (rc=%s) [%s], not a conviction\n' "$label" "$r" "$s1"; MFAIL=1 ;;
      esac
    done
    SHELLS="$ALLSHELLS"
  }
  mutate 'm1 the KS_IN carry loop is deleted' \
    '/^  for f in "\$_kin"\/\*\.keys; do$/,/^  done$/d'
  # Moves the KS_IN loop below the export loop: a carried bundle then overwrites this session's fresh dump.
  mutate 'm2 the export loop runs above KS_IN' 'awk:
    /^keystore_push\(\) \{$/ { inf=1 }
    inf && /^  for f in "\$_kin"\/\*\.keys; do$/ { hold=1 }
    hold { buf = buf $0 "\n"; if ($0 == "  done") hold=0; next }
    { print }
    inf && /^  for f in "\$KS_EXPORT"\/\*\.keys; do$/ { inexp=1 }
    inexp && $0 == "  done" { printf "%s", buf; inexp=0; inf=0 }'
  mutate 'm3 the export loop loses its [ -e "$f" ] guard' \
    '/^  for f in "\$KS_EXPORT"\/\*\.keys; do$/,/^  done$/{/\[ -e "\$f" \] || continue/d}'
  mutate 'm4 the push result is no longer returned' \
    's/^  return "\$kret"$/  return 0/'
  mutate 'm5 the nothing-fresh early return is deleted' \
    '/^  if \[ "\$_kn" = 0 \] && \[ "\$_kdrop" = 0 \]; then rm -rf "\$KSTAGE"/d'
  mutate 'm6 the export-arm unmapped increment is deleted' \
    '/has no package mapping, dropped \$(date)" >> "\$LOG"; _knomap=/{/staged import/!s/ _knomap=\$((_knomap + 1));//}'
  mutate 'm7 the import-arm unmapped increment is deleted' \
    '/staged import ns/s/ _knomap=\$((_knomap + 1));//'
  mutate 'm8 the sealed line reverts to $_kdrop dropped' \
    's/\$((_kdrop + _knomap)) dropped/$_kdrop dropped/'
  mutate 'm9 the early return is widened to _knomap' \
    's/^  if \[ "\$_kn" = 0 \] \&\& \[ "\$_kdrop" = 0 \]; then/  if [ "$_kn" = 0 ] \&\& [ "$_kdrop" = 0 ] \&\& [ "$_knomap" = 0 ]; then/'
  # NWP-20261112-01: the carry loop reads every user's keystore-in dir, not this op's.
  mutate 'K1m the KS_IN carry loop reads every user'"'"'s dir' \
    's#^  for f in "\$_kin"/\*\.keys; do$#  for f in "$KS_IN"/*/*.keys; do#'
  # NWP-20261102-05: the drop filter's mutants.
  mutate 'D1 the uid check on the drop list is removed' \
    's| \&\& \[ "\$(sed -n 1p "\$KS_DROP" 2>/dev/null)" = "# \$uid" \]| \&\& :|'
  mutate 'D2 the filter loop is removed' \
    '/^    while IFS= read -r _kp; do$/,/^KSDROP_EOF$/c\
    :'
  mutate 'D3 the early-out ignores the drop list' \
    's/^    \[ "\$_kdn" = 1 \] || return 0$/    return 0/'
  mutate 'D4 _kdrop is left 0' \
    's/ || _kdrop=\$((_kdrop + 1))$/ || :/'
  mutate 'D5 a drop with no fresh dump pushes regardless' \
    '/^  if \[ "\$_kn" = 0 \] \&\& \[ "\$_kdrop" != 0 \]; then$/,/^  fi$/d'
  # D6 (the drop list's empty-uid guard removed) is retired by NWP-20261114-08: with no uid ks_ns_mine refuses every file, so the early-outs return before the list matters -- an equivalent mutant.
  mutate 'D7 the early-out no longer needs a drop list' \
    's/^    \[ "\$_kdn" = 1 \] || return 0$/    :/'
  # NWP-20261114-08: a reap stages, waits for and removes only its own uid's <uid><5 digits>.keys.
  mutate 'R1 the import loop stages every user'"'"'s file' \
    '/^  for f in "\$KS_IMPORT"\/\*\.keys; do$/,/^  done$/{/^    ks_ns_mine "\$f" || /d}'
  mutate 'R2 the export loop stages every user'"'"'s file' \
    '/^  for f in "\$KS_EXPORT"\/\*\.keys; do$/,/^  done$/{/^    ks_ns_mine "\$f" || /d}'
  mutate 'R3 the sealed branch removes every user'"'"'s dump' \
    's#^    rm -f "\$KS_EXPORT/\$uid"\[0-9\]\[0-9\]\[0-9\]\[0-9\]\[0-9\]\.keys$#    rm -f "$KS_EXPORT"/*.keys#'
  mutate 'R4 ks_ns_mine accepts any all-digit name' \
    '/^ks_ns_mine() {$/,/^}$/s/^  case "\$_n" in .*$/  case "$_n" in '"''"'|*[!0-9]*) return 1 ;; *) return 0 ;; esac/'
  mutate 'R5 the wait loop waits for any dump' \
    '/^      for f in "\$KS_EXPORT"\/\*\.keys; do /s/ ks_ns_mine "\$f" \&\&//'
  mutate 'R6 ks_ns_mine accepts an empty uid' \
    '/^ks_ns_mine() {$/,/^}$/s/^  case "\$_mu" in '"''"'|\*\[!0-9\]\*) return 1 ;; esac$/  case "$_mu" in '"''"') return 0 ;; *[!0-9]*) return 1 ;; esac/'
  # NWP-20261116-08: the stage goes back to f2fs.
  mutate 'T1m the stage is back on /data/nowhere (f2fs)' \
    's#^  KSTAGE="\$STATE/keystore-stage"$#  KSTAGE=/data/nowhere/keystore-stage#'
  # NWP-20261119-06: the #keys stage must be whole, or nothing is pushed.
  mutate 'W1 the KS_IN copy loses its cmp' \
    '/^keystore_push() {$/,/^}$/s/^    if cp "\$f" "\$_kd" 2>>"\$LOG" \&\& cmp -s "\$f" "\$_kd"; then/    if cp "$f" "$_kd" 2>>"$LOG"; then/'
  mutate 'W2 the KS_IN copy ignores a failure' \
    '/^keystore_push() {$/,/^}$/s/; else rm -f "\$_kd" 2>\/dev\/null; _kcf=\$((_kcf + 1)); fi$/; fi/'
  mutate 'W3 the KS_IMPORT copy ignores a failure' \
    '/^keystore_push() {$/,/^}$/{/then _kc=\$((_kc + 1)); else rm -f "\$KSTAGE\/\$_pkg\.keys"/s/; else rm -f "\$KSTAGE\/\$_pkg\.keys" 2>\/dev\/null; _kcf=\$((_kcf + 1)); fi$/; fi/;}'
  mutate 'W4 the KS_EXPORT copy ignores a failure' \
    '/^keystore_push() {$/,/^}$/{/then _kn=\$((_kn + 1)); else/s/; else rm -f "\$KSTAGE\/\$_pkg\.keys" 2>\/dev\/null; _kcf=\$((_kcf + 1)); fi$/; fi/;}'
  mutate 'W5 the refusal block no longer returns' \
    '/^keystore_push() {$/,/^}$/{/could not be staged whole/,/^  fi$/{/^    return 1$/d;};}'
  echo
  [ "${MFAIL:-0}" = 0 ] && echo "ALL MUTATIONS BEHAVED" || { echo "PROBLEM: a mutation did not behave"; FAILED=1; }
  command rm -rf "$mtmp"
fi

exit "${FAILED:-0}"
