#!/usr/bin/env bash
# test-keystore-keys-retry.sh [<nowhere_roamd.sh>] [--mutate] -- the #keys push retry ladder in keystore_push
# (NWP-20261116-10, h46 #2 (2)-(3) in docs/product-decisions.md, over the 2026-10-22 #72 bullet).
#
# WHY THIS IS COMMITTED. Before this slice a failed #keys push set KS_VERDICT=notsealed at once, and the reap
# (cleanstorage) then destroyed this uid's Keystore dump. A sign-out during a 20 s store outage therefore signed out
# every app that kept its sign-in in a Keystore key, although a push 30 s later would have landed. The decided rule:
# a failed push is tried three more times, after 5 s, 30 s and 2 min, within the same reap, from the SAME stage; "the
# retry writes no key material to /data that a single push does not already write, and the export dump does not
# outlive the reap (destroyed after the third failure, or by the boot sweep after a crash)".
#
# The RW worker answers ERR-TIMEOUT after roamStallTicks (150 s) with no new line in $NOWHERE_PROGRESS, so every wait
# sleeps in slices of at most 5 s, with a NEW progress line (ks_prog) before each slice. ks_prog is defined beside
# keystore_push and is not cutoff_prog: cleanstorage runs from the early op dispatch, above cutoff_prog's definition,
# so cutoff_prog is undefined there (the forward-reference trap). R7 checks that order on the unrewritten roamd.
#
# ks_in_dir, ks_ns_mine, ks_prog and keystore_push are extracted from nowhere_roamd.sh BY NAME, never copied, and the one
# stage path ($STATE/keystore-stage) is rewritten under a scratch root (the rewrite must hit exactly one line).
# pw/qn/print/timeout are stubbed; `sleep` records its argument and the progress file's content at that slice; AGENT is
# a script that records `ls -1` of its stage argument and fails $FAILS times, then succeeds.
# Each case runs under bash and sh, plus dash and mksh where installed -- roamd is #!/system/bin/sh (mksh on the device).
#
# CASES
#   R1 fails once, then succeeds: sealed, the export dump removed, 2 pushes, one sleep of 5 s.
#   R2 always fails: 4 pushes, slices summing to 5+30+120, notsealed, the stage gone, one attempt line per push.
#   R3 a progress line before every sleep slice: the progress content differs at each slice; no slice over 5 s.
#   R4 no credentials (no pass; no name): no push, no sleep, `deferred (no creds on this op)`.
#   R5 succeeds first time: one push, no sleep.
#   R6 the stage holds the same bundles at every attempt.
#   R7 static: one #keys push site, and ks_prog is defined above the early op dispatch.
#   R8 ks_prog with NOWHERE_PROGRESS unset writes nothing and answers 0.
#
#   bash test-keystore-keys-retry.sh            # the behaviour cases
#   bash test-keystore-keys-retry.sh --mutate   # ... plus mutations that must each CONVICT the suite under every shell
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

# sleep records its argument and what the RW worker would read in the progress file at that moment.
STUBS="$PRINT_SHIM"'
pw() { printf "%s" "$1"; }
qn() { printf "%s" "$1"; }
timeout() { shift 3; "$@"; }
sleep() { echo "$1" >> "$D/sleeps"; if [ -n "${NOWHERE_PROGRESS:-}" ] && [ -f "$NOWHERE_PROGRESS" ]; then cat "$NOWHERE_PROGRESS" >> "$D/prog-at-sleep"; else echo NONE >> "$D/prog-at-sleep"; fi; }
'

# extract <roamd.sh> <fn name> <out> -- one function by name. 0 ok, 2 not found.
extract() {
  local sut="$1" nm="$2" out="$3"
  sed -n "/^$nm() {\$/,/^}\$/p" "$sut" > "$out"
  if [ ! -s "$out" ] || [ "$(head -1 "$out")" != "$nm() {" ] || [ "$(tail -1 "$out")" != '}' ]; then
    echo "EXTRACTION FAILED: $nm() { ... } not found in $sut" >&2; return 2
  fi
  return 0
}

# prep_fn <roamd.sh> <out> -- ks_in_dir + ks_ns_mine + ks_prog + keystore_push, the stage under $TROOT. 0 ok, 2 harness error.
prep_fn() {
  local sut="$1" out="$2" fnm part all
  all=$(mktemp -p "$W")
  for fnm in ks_in_dir ks_ns_mine ks_prog; do
    part=$(mktemp -p "$W")
    extract "$sut" "$fnm" "$part" || return 2
    cat "$part" >> "$all"
  done
  part=$(mktemp -p "$W")
  extract "$sut" keystore_push "$part" || return 2
  { cat "$all"; sed 's#^  KSTAGE="\$STATE/keystore-stage"$#  KSTAGE="$TROOT/keystore-stage"#' "$part"; } > "$out"
  if [ "$(grep -c 'KSTAGE="\$TROOT/keystore-stage"' "$out")" != 1 ]; then
    echo "REWRITE FAILED: want exactly one KSTAGE=\"\$STATE/keystore-stage\" line in keystore_push of $sut" >&2; return 2
  fi
  if ! bash -n "$out" || ! sh -n "$out"; then
    echo "EXTRACTION FAILED: the extracted functions do not parse ($sut)" >&2; return 2
  fi
  return 0
}

# newcase -> a fresh scratch dir: uid 10's fresh dump 1010001 (-> com.a) and a carried com.b bundle, the recording AGENT.
newcase() {
  local d; d=$(mktemp -d -p "$W")
  mkdir -p "$d/in/10" "$d/imp" "$d/exp" "$d/state"
  echo "1010001 com.a" > "$d/map"
  printf fresh > "$d/exp/1010001.keys"
  printf carried > "$d/in/10/com.b.keys"
  cat > "$d/agent.sh" <<'AG'
#!/bin/sh
echo "$*" >> "$D/agent.calls"
{ echo "--"; if [ -d "$5" ]; then ls -1 "$5"; else echo "NO-STAGE"; fi; } >> "$D/agent.ls"
n=$(cat "$D/n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$D/n"
[ "$n" -le "$FAILS" ] && exit 1
exit 0
AG
  chmod +x "$d/agent.sh"
  printf '%s\n' "$d"
}

# runcase <fn> <shell> <dir> <fails> [name] [pass] [progress: yes|no] -- runs `keystore_push wait` once.
runcase() {
  local fn="$1" sh="$2" d="$3" fl="$4" nm="${5-prof}" pa="${6-secret}" pg="${7:-yes}"
  {
    printf 'D=%s\nTROOT=%s\nSTATE=%s\nLOG=%s\nKS_IN=%s\nKS_IMPORT=%s\nKS_EXPORT=%s\nKS_MAP=%s\nKS_DROP=%s\nuid=10\n' \
      "$d" "$d" "$d/state" "$d/log" "$d/in" "$d/imp" "$d/exp" "$d/map" "$d/drop"
    printf 'AGENT=%s\nFAILS=%s\nname=%s\npass=%s\nexport D FAILS\n' "$d/agent.sh" "$fl" "'$nm'" "'$pa'"
    if [ "$pg" = yes ]; then printf 'NOWHERE_PROGRESS=%s\n' "$d/roam.progress"; else printf 'unset NOWHERE_PROGRESS\n'; fi
    printf '%s\n' "$STUBS"
    cat "$fn"
    printf 'keystore_push wait\nprintf "rc=%%s verdict=%%s\\n" "$?" "$KS_VERDICT" > "$D/res"\n'
  } > "$d/run.sh"
  "$sh" "$d/run.sh" >/dev/null 2>&1
  touch "$d/log" "$d/agent.calls" "$d/agent.ls" "$d/sleeps" "$d/prog-at-sleep" "$d/res"
}

lines() { wc -l < "$1" | tr -d ' '; }
sumf() { awk '{ s += $1 } END { print s + 0 }' "$1"; }
maxf() { awk 'BEGIN { m = 0 } { if ($1 + 0 > m) m = $1 + 0 } END { print m }' "$1"; }
# one stage listing per AGENT call, joined: "a b|a b|..."
stages() { awk '/^--$/ { if (n++) printf "|"; sep=""; next } { printf "%s%s", sep, $0; sep=" " }' "$1/agent.ls"; }

suite() {  # suite <roamd.sh> [quiet] -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" quiet="${2:-}" fn p=0 x=0 sh rc d why n raw early kp
  ok() { p=$((p+1)); [ -n "$quiet" ] || printf '  ok    %s\n' "$1"; }
  no() { x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  %s\n' "$1"; }
  fin() {  # fin <label> <dir> -- report the accumulated $why, drop the scratch dir
    if [ -z "$why" ]; then ok "$1 [$sh]"; else no "$1 [$sh] --$why"; fi
    command rm -rf "$2"
  }
  # R7 (static, the unrewritten roamd): one #keys push site (conf_flags_scoped_test refuses a profile at two), and
  # ks_prog defined above the early op dispatch that runs cleanstorage.
  why=""; sh=static
  raw=$(mktemp -p "$W")
  extract "$f" keystore_push "$raw" >/dev/null 2>&1
  n=$(grep -c '"\$AGENT" push s3 "\${name}#keys"' "$raw")
  [ "$n" = 1 ] || why="$why $n #keys push site(s) in keystore_push, want 1;"
  kp=$(grep -n '^ks_prog() {$' "$f" | head -1 | cut -d: -f1)
  early=$(grep -n '^if \[ "\$op" = "cleanstorage" \]; then$' "$f" | head -1 | cut -d: -f1)
  if [ -z "$kp" ] || [ -z "$early" ] || [ "$kp" -ge "$early" ]; then
    why="$why ks_prog at line '${kp}', the cleanstorage dispatch at line '${early}': ks_prog must come first;"
  fi
  fin "R7 one #keys push site; ks_prog defined above the cleanstorage dispatch" "$raw"
  fn=$(mktemp -p "$W")
  prep_fn "$f" "$fn"; rc=$?
  [ "$rc" = 0 ] || { command rm -f "$fn"; return 2; }
  for sh in $SHELLS; do
    # R1: one failure, then success -> sealed, dump removed, 2 pushes, one 5 s slice
    d=$(newcase); why=""
    runcase "$fn" "$sh" "$d" 1
    [ "$(cat "$d/res")" = "rc=0 verdict=sealed" ] || why="$why res '$(cat "$d/res")', want rc=0 verdict=sealed;"
    [ "$(lines "$d/agent.calls")" = 2 ] || why="$why $(lines "$d/agent.calls") push(es), want 2;"
    [ "$(tr '\n' ' ' < "$d/sleeps")" = "5 " ] || why="$why sleeps '$(tr '\n' ' ' < "$d/sleeps")', want one 5;"
    [ ! -e "$d/exp/1010001.keys" ] || why="$why the export dump was not removed;"
    [ ! -e "$d/keystore-stage" ] || why="$why the stage is left behind;"
    [ "$(grep -c '#keys push attempt 1 rc=1' "$d/log")" = 1 ] || why="$why no single 'attempt 1 rc=1' line;"
    [ "$(grep -c 'attempt 2' "$d/log")" = 0 ] || why="$why an attempt line for the push that succeeded;"
    grep -qF '#keys sealed (2 pkg, 1 fresh, 0 dropped)' "$d/log" || why="$why no sealed line: $(tr '\n' ' ' < "$d/log");"
    fin "R1 fails once, then succeeds: sealed, dump removed, 2 pushes, one 5 s sleep" "$d"

    # R2: always fails -> 4 pushes, slices summing to 155, notsealed, stage gone
    d=$(newcase); why=""
    runcase "$fn" "$sh" "$d" 99
    [ "$(lines "$d/agent.calls")" = 4 ] || why="$why $(lines "$d/agent.calls") push(es), want 4;"
    [ "$(sumf "$d/sleeps")" = 155 ] || why="$why waits sum to $(sumf "$d/sleeps") s, want 5+30+120;"
    [ "$(lines "$d/sleeps")" = 31 ] || why="$why $(lines "$d/sleeps") slice(s), want 1+6+24;"
    [ "$(cat "$d/res")" = "rc=1 verdict=notsealed" ] || why="$why res '$(cat "$d/res")', want rc=1 verdict=notsealed;"
    [ ! -e "$d/keystore-stage" ] || why="$why the stage is left behind;"
    for n in 1 2 3 4; do
      [ "$(grep -c "#keys push attempt $n rc=1" "$d/log")" = 1 ] || why="$why no single 'attempt $n rc=1' line;"
    done
    [ "$(grep -c -- '-- NOT SEALED' "$d/log")" = 1 ] || why="$why not one NOT SEALED line;"
    ! grep -qF '#keys sealed' "$d/log" || why="$why a sealed line after four failures;"
    # keystore_push never removes the dump on failure: cleanstorage destroys it on the notsealed verdict.
    [ -e "$d/exp/1010001.keys" ] || why="$why keystore_push removed the export dump itself;"
    fin "R2 always fails: 4 pushes, 155 s in slices, notsealed, stage gone" "$d"

    # R3: a new progress line before every sleep slice, no slice over 5 s
    d=$(newcase); why=""
    runcase "$fn" "$sh" "$d" 99
    n=$(lines "$d/sleeps")
    [ "$n" -gt 0 ] || why="$why no sleep at all;"
    [ "$(lines "$d/prog-at-sleep")" = "$n" ] || why="$why $(lines "$d/prog-at-sleep") progress reading(s) for $n sleep(s);"
    ! grep -q '^NONE$' "$d/prog-at-sleep" || why="$why a slice with no progress file;"
    [ "$(sort -u "$d/prog-at-sleep" | wc -l | tr -d ' ')" = "$n" ] || why="$why the progress line did not change at every slice;"
    [ "$(grep -c '^keys keys-retry [0-9][0-9]*$' "$d/prog-at-sleep")" = "$n" ] || why="$why a progress line not 'keys keys-retry <n>': $(sort -u "$d/prog-at-sleep" | head -3 | tr '\n' ' ');"
    [ "$(maxf "$d/sleeps")" -le 5 ] || why="$why a slice of $(maxf "$d/sleeps") s, want at most 5;"
    fin "R3 a new progress line before every slice of at most 5 s" "$d"

    # R4: no credentials -> no push, no sleep, deferred as today (no pass; then no name)
    for n in pass name; do
      d=$(newcase); why=""
      if [ "$n" = pass ]; then runcase "$fn" "$sh" "$d" 99 prof ""; else runcase "$fn" "$sh" "$d" 99 "" secret; fi
      [ ! -s "$d/agent.calls" ] || why="$why a push with no credentials;"
      [ ! -s "$d/sleeps" ] || why="$why slept $(lines "$d/sleeps") time(s) with no credentials;"
      [ "$(cat "$d/res")" = "rc=0 verdict=notsealed" ] || why="$why res '$(cat "$d/res")';"
      grep -qF 'keystore_push deferred (no creds on this op)' "$d/log" || why="$why no deferred line;"
      fin "R4 no $n: no push, no sleep, deferred" "$d"
    done

    # R5: succeeds first time -> one push, no sleep
    d=$(newcase); why=""
    runcase "$fn" "$sh" "$d" 0
    [ "$(lines "$d/agent.calls")" = 1 ] || why="$why $(lines "$d/agent.calls") push(es), want 1;"
    [ ! -s "$d/sleeps" ] || why="$why slept $(lines "$d/sleeps") time(s);"
    [ "$(cat "$d/res")" = "rc=0 verdict=sealed" ] || why="$why res '$(cat "$d/res")';"
    ! grep -q 'attempt' "$d/log" || why="$why an attempt line with no failure;"
    fin "R5 succeeds first time: one push, no sleep" "$d"

    # R6: the same stage at every attempt
    d=$(newcase); why=""
    runcase "$fn" "$sh" "$d" 3
    [ "$(stages "$d")" = "com.a.keys com.b.keys|com.a.keys com.b.keys|com.a.keys com.b.keys|com.a.keys com.b.keys" ] \
      || why="$why stages '$(stages "$d")', want com.a.keys com.b.keys at each of 4 pushes;"
    [ "$(cat "$d/res")" = "rc=0 verdict=sealed" ] || why="$why res '$(cat "$d/res")';"
    fin "R6 the stage keeps the same bundles at every attempt" "$d"

    # R8: ks_prog with NOWHERE_PROGRESS unset writes nothing and answers 0 (and a push with no progress file still retries)
    d=$(newcase); why=""
    runcase "$fn" "$sh" "$d" 1 prof secret no
    [ "$(cat "$d/res")" = "rc=0 verdict=sealed" ] || why="$why res '$(cat "$d/res")';"
    [ "$(tr '\n' ' ' < "$d/prog-at-sleep")" = "NONE " ] || why="$why progress '$(tr '\n' ' ' < "$d/prog-at-sleep")', want none written;"
    [ -z "$(ls "$d" | grep 'progress')" ] || why="$why a progress file was written with NOWHERE_PROGRESS unset;"
    fin "R8 NOWHERE_PROGRESS unset: ks_prog writes nothing, the retry still lands" "$d"
  done
  command rm -f "$fn"
  [ -n "$quiet" ] || printf '  -- %d ok, %d failed\n' "$p" "$x"
  [ "$x" -eq 0 ] && return 0 || return 1
}

echo "keystore_push #keys retry ladder: $SUT"
echo "shells: $SHELLS"
suite "$SUT"; rc=$?
[ "$rc" = 2 ] && exit 2          # the harness could not extract, rewrite or parse the functions
[ "$rc" = 0 ] || FAILED=1

if [ "$MUTATE" = yes ]; then
  echo
  echo "mutations (each must CONVICT under every shell):"
  mtmp=$(mktemp -d -p "$W")
  ALLSHELLS="$SHELLS"
  mutate() {  # <label> <sed program>
    local label="$1" prog="$2" mf="$mtmp/r.sh" r s1
    if ! sed "$prog" "$SUT" > "$mf"; then printf '  ERR   %-56s mutation program failed\n' "$label"; MFAIL=1; return; fi
    if cmp -s "$SUT" "$mf"; then printf '  SKIP  %-56s mutation was a NO-OP\n' "$label"; MFAIL=1; return; fi
    # One suite run PER shell: the suite sums failures across shells, so a single run would let one shell's
    # conviction hide a survivor on another (mksh is the device's shell).
    for s1 in $ALLSHELLS; do
      SHELLS="$s1"; suite "$mf" quiet >/dev/null 2>&1; r=$?
      case "$r" in
        0) printf '  XX    %-56s SURVIVED [%s]\n' "$label" "$s1"; MFAIL=1 ;;
        1) printf '  ok    %-56s convicted [%s]\n' "$label" "$s1" ;;
        *) printf '  ERR   %-56s harness error (rc=%s) [%s], not a conviction\n' "$label" "$r" "$s1"; MFAIL=1 ;;
      esac
    done
    SHELLS="$ALLSHELLS"
  }
  mutate 'M1 the ladder is removed (one push only)' \
    's/^  for _kw in 0 5 30 120; do$/  for _kw in 0; do/'
  mutate 'M2 a retry on the no-credentials arm' \
    '/^    echo "\[roamd\] keystore_push deferred (no creds on this op)/i\
    ks_prog keys-retry; sleep 5'
  mutate 'M3 the stage is removed between attempts' \
    '/^    \[ "\$kret" = 0 \] && break$/a\
    rm -rf "$KSTAGE"'
  mutate 'M4 no ks_prog in the wait' \
    '/^      ks_prog keys-retry$/d'
  mutate 'M5 a single 120 s sleep (no slices)' \
    's/^      _ksl=5; \[ "\$_kw" -lt 5 \] && _ksl=\$_kw$/      _ksl=$_kw/'
  mutate 'M6 cutoff_prog (undefined in the early dispatch) for ks_prog' \
    's/^      ks_prog keys-retry$/      cutoff_prog keys-retry/'
  echo
  [ "${MFAIL:-0}" = 0 ] && echo "ALL MUTATIONS BEHAVED" || { echo "PROBLEM: a mutation did not behave"; FAILED=1; }
  command rm -rf "$mtmp"
fi

exit "${FAILED:-0}"
