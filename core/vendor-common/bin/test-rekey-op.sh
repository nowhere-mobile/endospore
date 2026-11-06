#!/usr/bin/env bash
# test-rekey-op.sh [<nowhere_roamd.sh>] [--mutate] -- roamd's `rekey` op (NWP-20261019-14), run for real.
#
# rekey re-keys a live session's keyguard credential. It is the credential step of five agent paths (the passphrase
# rotation, PROMOTE and its revert, the cold-lock forward rekey and its revoke unwind, resume), each of which compares
# the reply to exactly "OK". No other suite executed it. The op must:
#   - reply ERR-ARGS, and call nothing, when the new credential (roam.req line 5) or the uid is empty;
#   - reply ERR-UID, and call nothing, for a uid that is not digits, has a leading zero, or is under 10 (user 0 is the
#     gate, NWP-20261116-17);
#   - try the no-credential rung first (`set-* --user U NEW`), then the `--old OLD` rung, and reply exactly OK or ERR-REKEY;
#   - pick set-pin for an all-numeric credential and set-password for any non-digit;
#   - hand the new credential to cmd as ONE argument;
#   - never print either credential to the log, and keep RES mode 600;
#   - redirect both cmd lines `</dev/null >/dev/null 2>&1` (the su:s0 fd-passing denial, DIA-56).
#
# The block is extracted from nowhere_roamd.sh BY ANCHOR (`if [ "$op" = "rekey" ]; then` to its column-0 `fi`; the block
# also holds indented fi's), never copied; if the anchors move, extraction fails loudly.
#
#   bash test-rekey-op.sh            # the behaviour cases
#   bash test-rekey-op.sh --mutate   # ... plus mutations that must each CONVICT the suite
# The harness is bash (`sh test-rekey-op.sh` re-execs under bash). Every case writes the block, its variables and the
# cmd stub into a run file and executes that file in a CHILD of each shell found among bash, sh, dash and mksh -- mksh is
# the device's /system/bin/sh. Each run file records the identity of the shell that ran it, and the suite asserts it is
# the shell the case launched. A mutant is convicted only when it fails under EVERY shell found.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

SHELLS=""; for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "no shell to run under" >&2; exit 2; }
IDPROBE='_id="${KSH_VERSION:+ksh:$KSH_VERSION}${BASH_VERSION:+bash:$BASH_VERSION}"; [ -n "$_id" ] || _id=posix; _pr=none; command -v print >/dev/null 2>&1 && _pr=builtin'
REF_SH=""; command -v sh >/dev/null 2>&1 && REF_SH=$(sh -c "$IDPROBE; printf '%s|%s\n' \"\$_id\" \"\$_pr\"")
echo "shells:$SHELLS"
echo "sh identity: $REF_SH"
sq(){ printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
runsh(){ "$1" "$2" >/dev/null 2>&1; }
# idok <shell> <id file> -> 0 iff the file holds at least one line and every line is that shell's identity
idok(){
  local s="$1" f="$2" l n=0
  [ -s "$f" ] || return 1
  while IFS= read -r l; do
    n=$((n+1))
    case "$s" in
      bash) case "$l" in bash:*'|none') ;; *) return 1 ;; esac ;;
      dash) [ "$l" = 'posix|none' ] || return 1 ;;
      mksh) case "$l" in 'ksh:|'*) return 1 ;; ksh:?*'|builtin') ;; *) return 1 ;; esac ;;
      sh)   [ "$l" = "$REF_SH" ] || return 1 ;;
      *)    return 1 ;;
    esac
  done < "$f"
  [ "$n" -gt 0 ]
}

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

BLOCK=$(awk '
  $0 == "if [ \"$op\" = \"rekey\" ]; then" { on = 1 }
  on { print }
  on && $0 == "fi" { exit }' "$SUT")
case "$BLOCK" in *ERR-ARGS*) ;; *) echo "EXTRACTION FAILED: the rekey op (no ERR-ARGS)" >&2; exit 2 ;; esac
case "$BLOCK" in *ERR-REKEY*) ;; *) echo "EXTRACTION FAILED: the rekey op (no ERR-REKEY)" >&2; exit 2 ;; esac
case "$BLOCK" in *lock_settings*) ;; *) echo "EXTRACTION FAILED: the rekey op (no lock_settings)" >&2; exit 2 ;; esac

OLD='OLDpass-7Qz'

# run <shell> <rung1-rc> <rung2-rc> <new-credential> <uid> -> sets T (case dir with log/res/argv/shell.id)
# argv: one argument per line, each call closed by a `--` line.
run(){
  T=$(mktemp -d -p "$W") || exit 2
  mkdir "$T/state"; : > "$T/log"; : > "$T/argv"
  {
    printf '%s; printf "%%s|%%s\\n" "$_id" "$_pr" >> %s\n' "$IDPROBE" "$(sq "$T/shell.id")"
    printf 'CALLS=%s; R1=%s; R2=%s; STATE=%s; LOG=%s; RES=%s; op=rekey; uid=%s; pass=%s; sesec=%s\n' \
      "$(sq "$T/argv")" "$(sq "$2")" "$(sq "$3")" "$(sq "$T/state")" "$(sq "$T/log")" "$(sq "$T/res")" \
      "$(sq "$5")" "$(sq "$OLD")" "$(sq "$4")"
    cat <<'STUB'
cmd(){ local a; for a in "$@"; do printf '%s\n' "$a" >> "$CALLS"; done; printf '%s\n' -- >> "$CALLS"
       case " $* " in *" --old "*) return "$R2" ;; *) return "$R1" ;; esac; }
STUB
    printf '%s\n' "$BLOCK"
  } > "$T/run.sh"
  # a run file that does not parse under the shell is a HARNESS error (exit 2), never a behavioural FAIL: a mutant
  # that breaks the syntax must not count as convicted when the arm never ran
  "$1" -n "$T/run.sh" >/dev/null 2>&1 || { echo "HARNESS ERROR: the run file does not parse under $1" >&2; exit 2; }
  runsh "$1" "$T/run.sh"
  # the run file's first act is to record the shell's identity: a file with none means the child never ran (a launch
  # failure), which is a HARNESS error (exit 2). Left to the assertions it would read as a behavioural FAIL, and a
  # mutant would count as convicted when no mutated arm ran. A WRONG identity is still an ordinary FAIL (ran).
  [ -s "$T/shell.id" ] || { echo "HARNESS ERROR: the run file left no identity: $1 did not launch it" >&2; exit 2; }
}
# ran <shell> <label>: the case's run file recorded the identity of the shell it launched
ran(){ idok "$1" "$T/shell.id" && ok "[$1] $2: ran under $1" || no "[$1] $2: block did not run under $1 (id '$(cat "$T/shell.id" 2>/dev/null)')"; }
calls(){ grep -c '^--$' "$T/argv"; }
# call <n> -> the n-th call's arguments, one per line
call(){ awk -v n="$1" '$0 == "--" { i++; next } i == n - 1 { print }' "$T/argv"; }
res(){ cat "$T/res" 2>/dev/null; }
# nocred <new>: neither credential reached the log (file grep, not a pipe)
nocred(){ if grep -qF -e "$1" -e "$OLD" "$T/log"; then no "$2: a credential reached the log"; else ok "$2: no credential in the log"; fi; }
mode(){ [ "$(stat -c %a "$T/res" 2>/dev/null)" = 600 ] && ok "$1: RES mode 600" || no "$1: RES mode '$(stat -c %a "$T/res" 2>/dev/null)'"; }

for s in $SHELLS; do
t="[$s]"
echo "== R1: rung 1 sets a fresh credential =="
run "$s" 0 1 '482913' 12
ran "$s" R1
[ "$(res)" = OK ] && ok "$t R1: replies exactly OK" || no "$t R1: reply '$(res)'"
[ "$(calls)" -eq 1 ] && ok "$t R1: one call" || no "$t R1: $(calls) calls"
[ "$(call 1)" = "$(printf 'lock_settings\nset-pin\n--user\n12\n482913')" ] && ok "$t R1: args exact" || no "$t R1: args '$(call 1 | tr '\n' ' ')'"
grep -qF 'rekey user 12 OK (no prior credential)' "$T/log" && ok "$t R1: logs the no-prior rung" || no "$t R1: log '$(cat "$T/log")'"
nocred 482913 "$t R1"; mode "$t R1"; rm -rf "$T"

echo "== R2: rung 1 fails, rung 2 re-keys =="
run "$s" 1 0 'Tr0ub4dor x' 12
ran "$s" R2
[ "$(res)" = OK ] && ok "$t R2: replies exactly OK" || no "$t R2: reply '$(res)'"
[ "$(calls)" -eq 2 ] && ok "$t R2: two calls" || no "$t R2: $(calls) calls"
[ "$(call 2)" = "$(printf 'lock_settings\nset-password\n--old\n%s\n--user\n12\nTr0ub4dor x' "$OLD")" ] && ok "$t R2: args exact, new credential one argument" || no "$t R2: args '$(call 2 | tr '\n' '|')'"
grep -qF 'rekey user 12 OK (re-keyed from old)' "$T/log" && ok "$t R2: logs the old rung" || no "$t R2: log '$(cat "$T/log")'"
nocred 'Tr0ub4dor x' "$t R2"; mode "$t R2"; rm -rf "$T"

echo "== R3: both rungs fail =="
run "$s" 1 1 'Tr0ub4dor x' 12
ran "$s" R3
[ "$(res)" = ERR-REKEY ] && ok "$t R3: replies ERR-REKEY" || no "$t R3: reply '$(res)'"
[ "$(calls)" -eq 2 ] && ok "$t R3: two calls" || no "$t R3: $(calls) calls"
grep -qF 'rekey user 12 FAILED' "$T/log" && ok "$t R3: logs FAILED" || no "$t R3: log '$(cat "$T/log")'"
nocred 'Tr0ub4dor x' "$t R3"; mode "$t R3"; rm -rf "$T"

echo "== R4: empty new credential or uid =="
run "$s" 0 0 '' 12
ran "$s" R4
[ "$(res)" = ERR-ARGS ] && ok "$t R4: empty sesec -> ERR-ARGS" || no "$t R4: empty sesec reply '$(res)'"
[ ! -s "$T/argv" ] && ok "$t R4: empty sesec -> no call" || no "$t R4: cmd ran with no credential"
mode "$t R4a"; rm -rf "$T"
run "$s" 0 0 '482913' ''
ran "$s" R4
[ "$(res)" = ERR-ARGS ] && ok "$t R4: empty uid -> ERR-ARGS" || no "$t R4: empty uid reply '$(res)'"
[ ! -s "$T/argv" ] && ok "$t R4: empty uid -> no call" || no "$t R4: cmd ran with no uid"
mode "$t R4b"; nocred 482913 "$t R4"; rm -rf "$T"

echo "== R5: the verb follows the new credential's type =="
for c in 0000:set-pin 12a4:set-password -123:set-password ' 123:set-password'; do
  cred="${c%:*}"; want="${c##*:}"
  run "$s" 0 0 "$cred" 12
  ran "$s" R5
  [ "$(call 1 | sed -n 2p)" = "$want" ] && ok "$t R5: '$cred' -> $want" || no "$t R5: '$cred' used '$(call 1 | sed -n 2p)', want $want"
  [ "$(call 1 | tail -n 1)" = "$cred" ] && ok "$t R5: '$cred' passed intact" || no "$t R5: '$cred' became '$(call 1 | tail -n 1)'"
  nocred "$cred" "$t R5"; rm -rf "$T"
done

echo "== K2-K5: a uid under 10, non-numeric or with a leading zero is refused before any cmd call (NWP-20261116-17) =="
for k in 'K2:0' 'K3:9' 'K4:1x' 'K4b:12 ' 'K5:0123'; do
  kid="${k%%:*}"; u="${k#*:}"
  run "$s" 0 0 '482913' "$u"
  ran "$s" "$kid"
  [ "$(res)" = ERR-UID ] && ok "$t $kid: uid '$u' -> ERR-UID" || no "$t $kid: uid '$u' reply '$(res)'"
  [ ! -s "$T/argv" ] && ok "$t $kid: uid '$u' -> no cmd call" || no "$t $kid: uid '$u' -> cmd ran: '$(tr '\n' ' ' < "$T/argv")'"
  mode "$t $kid"; nocred 482913 "$t $kid"; rm -rf "$T"
done

echo "== R8: both cmd lines redirect </dev/null >/dev/null 2>&1 =="
CMDLINES=$(printf '%s\n' "$BLOCK" | grep -E '^ *(if|elif) cmd lock_settings')
[ "$(printf '%s\n' "$CMDLINES" | grep -c .)" -eq 2 ] && ok "$t R8: two cmd lines" || no "$t R8: found $(printf '%s\n' "$CMDLINES" | grep -c .) cmd lines"
[ "$(printf '%s\n' "$CMDLINES" | grep -cF '</dev/null >/dev/null 2>&1')" -eq 2 ] && ok "$t R8: both redirect" || no "$t R8: a cmd line lacks the redirect"
done

if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each must CONVICT the suite) =="
  M=$(mktemp -d -p "$W") || exit 2
  # mutate <label> <sed> [<case>...]: with case labels, each named case must FAIL under every shell, not just any case
  mutate(){
    local s c bad="" rc label="$1" expr="$2"
    shift 2
    if ! sed "$expr" "$SUT" > "$M/m.sh" 2>"$M/err"; then no "MUTATION BROKEN (sed): $label"; return; fi
    if cmp -s "$SUT" "$M/m.sh"; then no "MUTATION INERT: $label"; return; fi
    bash "$0" "$M/m.sh" > "$M/out" 2>&1; rc=$?
    for s in $SHELLS; do
      grep -q "FAIL  \[$s\]" "$M/out" || bad="$bad $s"
      for c in "$@"; do grep -qF "FAIL  [$s] $c:" "$M/out" || bad="$bad $s($c)"; done
    done
    if [ "$rc" -eq 1 ] && [ -z "$bad" ]; then ok "convicted under every shell:$SHELLS${1:+ by $*}: $label"
    else no "NOT CONVICTED (rc $rc, shells with no FAIL line:$bad): $label -- suite passes on broken code"; fi
  }
  # the runner ignores its shell argument and always runs bash: the identity check must convict it under every non-bash shell
  mutate_runner(){
    local s bad="" want=""
    sed 's/^runsh(){ "\$1" "\$2"/runsh(){ bash "$2"/' "$0" > "$M/runner.sh"
    if cmp -s "$0" "$M/runner.sh"; then no "MUTATION INERT: the runner always runs bash"; return; fi
    for s in $SHELLS; do
      case "$s" in
        bash) ;;
        sh) case "$REF_SH" in bash:*) ;; *) want="$want $s" ;; esac ;;
        *) want="$want $s" ;;
      esac
    done
    [ -n "$want" ] || { echo "  n/a   the runner always runs bash: no non-bash shell on this host (CI has dash and mksh)"; return; }
    bash "$M/runner.sh" "$SUT" > "$M/runner.out" 2>&1
    for s in $want; do grep -q "FAIL  \[$s\]" "$M/runner.out" || bad="$bad $s"; done
    if [ -z "$bad" ]; then ok "convicted under every non-bash shell:$want: the runner always runs bash"
    else no "NOT CONVICTED under:$bad: the runner always runs bash"; fi
  }
  mutate "set-pin/set-password arms swapped" 's@\*\[!0-9\]\*) _kscmd=set-password ;; \*) _kscmd=set-pin ;; esac@*[!0-9]*) _kscmd=set-pin ;; *) _kscmd=set-password ;; esac@'
  mutate "--old dropped from rung 2" '/^  elif cmd lock_settings/s@--old "\$pass" @@'
  mutate "rungs swapped" '/^  if cmd lock_settings/s@--user "\$uid"@--old "$pass" --user "$uid"@;/^  elif cmd lock_settings/s@--old "\$pass" @@'
  mutate "ERR-REKEY replaced by OK" 's@^    echo "ERR-REKEY" > "\$RES"$@    echo "OK" > "$RES" # ERR-REKEY@'
  mutate "new credential in the FAILED log" 's@rekey user \$uid FAILED@rekey user $uid FAILED $newp@'
  mutate "</dev/null dropped from rung 1" '/^  if cmd lock_settings/s@</dev/null @@'
  mutate "ERR-ARGS guard removed" 's@^  if \[ -z "\$newp" \] || \[ -z "\$uid" \]; then echo "ERR-ARGS".*$@  : # ERR-ARGS@'
  mutate "--user dropped from rung 1" '/^  if cmd lock_settings/s@--user "\$uid" @@'
  mutate "G1 rekey floor deleted" '/rekey: uid under 10 refused/d' K2 K3
  mutate "G2 rekey leading-zero/non-numeric case deleted" '/rekey: bad uid/d' K4b K5
  mutate "G5 rekey floor moved below the first cmd line" '/rekey: bad uid/{h;d};/rekey: uid under 10 refused/{H;d};/^  if cmd lock_settings "\$_kscmd" --user/{p;x}' K2
  # harness-error probes: a child that never launches, and a run file that does not parse, must end the suite with
  # exit 2 and HARNESS ERROR -- not exit 1 with FAIL lines, which a mutation run would count as a conviction
  probe(){  # probe <label> <sed program over this suite>
    local rc
    sed "$2" "$0" > "$M/probe.sh"
    if cmp -s "$0" "$M/probe.sh"; then no "MUTATION INERT: $1"; return; fi
    bash "$M/probe.sh" "$SUT" > "$M/probe.out" 2>&1; rc=$?
    if [ "$rc" -eq 2 ] && grep -q 'HARNESS ERROR' "$M/probe.out"; then ok "harness error (exit 2), not a conviction: $1"
    else no "HARNESS ERROR NOT RAISED (rc $rc): $1"; fi
  }
  probe "the child never launches" 's/^runsh(){ .*$/runsh(){ return 127; }/'
  probe "the run file does not parse" 's/^    printf .%s\\n. "\$BLOCK"$/    printf "%s\\n" "$BLOCK" ")"/'
  mutate_runner
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
