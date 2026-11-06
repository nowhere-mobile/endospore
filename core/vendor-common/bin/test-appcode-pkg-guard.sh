#!/usr/bin/env bash
# test-appcode-pkg-guard.sh [<nowhere_roamd.sh>] [--mutate] -- roamd refuses "." and ".." (and any name that is not an
# Android package name) before it builds a path from a package name (NWP-20261014-20). Three callers share one check,
# pkgname_ok: the materializeapp and stageapp ops, and hold_ondemand (names read from the roaming nowhere-appkeep).
#
# WHY THIS IS COMMITTED. All three joined the package into a path and ran `rm -rf` (or `cp -a` then `rm -rf`) on it
# after refusing only "", "/" and a space. ".." passed: materializeapp then removed the roamed chooser's whole files/
# tree ("$APPCODE/.."), and in hold_ondemand ".." made the source /data/user, so the merge branch copied /data/user
# into the chooser's dir and, on a clean copy, removed /data/user. The Go handlers now refuse such names first
# (validPkgName, core/agent/pkgname.go), so for the two ops this is defence in depth -- but it is the second lock on a
# door whose blast radius is the daemon's state, and it is silent when it regresses. hold_ondemand has no Go guard in
# front of it: the file it reads roams with the profile.
#
# pkgname_ok, hold_ondemand and each arm are extracted BY ANCHOR (a function from `<name>() {` to its first `}` line;
# an arm from `  <op>)` to the arm-closing `    ;;` line). stageapp's hardcoded /data/nowhere/fetchapp and
# hold_ondemand's /data/ are rewritten to a temp root, and each runs with stubbed $AGENT/stat/chown/restorecon and
# sentinels around the paths a bad name would reach. Every bad name below is the ONLY one some rule refuses, and every
# good name is one an over-tightened rule would refuse, so --mutate convicts each rule separately.
# The odrestore arm's own guard is NOT covered: the Go guard blocks the only door to it (see docs/backlog.md).
#
# Each case writes its extracted text, variables and stubs into a run file and executes that file in a CHILD of each
# shell found among bash, sh, dash and mksh (the device's /system/bin/sh): pkgname_ok's `${#p}`, its bracket classes and
# its `[!...]` negations are parsed by the shell that runs them, so a bash run proves nothing about mksh. Each run file
# records the identity of the shell that ran it and the suite asserts it is the shell the case launched. A shell mutant
# is convicted only when it fails under EVERY shell found (NWP-20261113-25).
#
#   bash test-appcode-pkg-guard.sh            # the cases, under every shell found
#   bash test-appcode-pkg-guard.sh --mutate   # ... plus mutations that must each CONVICT the suite under every shell
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
AGENT_DIR="$(cd "$(dirname "$0")/../../agent" 2>/dev/null && pwd)"
# Every temp of the run is made inside W.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

SHELLS=""; for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "no shell to run under" >&2; exit 2; }
IDPROBE='_id="${KSH_VERSION:+ksh:$KSH_VERSION}${BASH_VERSION:+bash:$BASH_VERSION}"; [ -n "$_id" ] || _id=posix; _pr=none; command -v print >/dev/null 2>&1 && _pr=builtin'
REF_SH=""; command -v sh >/dev/null 2>&1 && REF_SH=$(sh -c "$IDPROBE; printf '%s|%s\n' \"\$_id\" \"\$_pr\"")
PRINT_SHIM='command -v print >/dev/null 2>&1 || print() { _pn=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) _pn=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$_pn" = 1 ]; then printf "%s\n" "$*"; else printf "%s" "$*"; fi; }'
sq(){ printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
runsh(){ "$1" "$2" 2>&1 </dev/null; }
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
# notrun <shell> <case dir>: a run file that recorded no identity never launched -- a HARNESS error (noted in
# $W/harness, which suite turns into exit 2), never a behavioural FAIL a mutant could be convicted by. One that recorded
# the WRONG shell is noted in $W/notrun for suite's per-shell FAIL line.
notrun() {
  [ -s "$2/shell.id" ] || { echo "$1" >> "$W/harness"; return 1; }
  idok "$1" "$2/shell.id" || { echo "$1" >> "$W/notrun"; return 1; }
}

LONG255="$(printf 'a%.0s' $(seq 1 253)).b"              # 255 bytes: the longest legal name
LONG256="$(printf 'a%.0s' $(seq 1 254)).b"              # 256 bytes: one over
LONGDOT="org.example.$(printf 'seg%.0s.' $(seq 1 40))app"  # many segments, well under 255
# a.b. / a..b / a._b / a.1b / a.b;x / _a.b / single / LONG256 are each refused by exactly one rule of pkgname_ok;
# A.B_c9 / com.example.App_1 / LONG255 are each refused by some over-tightened rule (see the mutants below).
BAD=(.. . .a a. a.b. a..b a/b "a b" a.b/../c com.x/.. 'a.b;x' a.b-c a._b a.1b _a.b 1a.b -a.b single "" 'é.b'
     "$LONG256")
GOOD=(org.fossify.math com.example.App_1 A.B_c9 "$LONGDOT" "$LONG255")

extract_arm() { # <script> <op> -> the arm text, or nothing
  awk -v start="  $2)" '
    $0 == start { on = 1 }
    on { print }
    on && $0 == "    ;;" { exit }' "$1"
}
extract_fn() { # <script> <name> -> the function text, or nothing
  awk -v start="$2() {" '
    $0 == start { on = 1 }
    on { print }
    on && $0 == "}" { exit }' "$1"
}

# write_arm <file> <root> <op> <pkg> <helper> <arm-text>: the run file of one op case. The identity line comes first,
# so the arm's early `exit 0` cannot skip it; every value reaches the file single-quoted (sq).
write_arm() {
  local f="$1" root="$2" op="$3" pkg="$4" helper="$5" arm="$6"
  {
    printf '%s; printf "%%s|%%s\\n" "$_id" "$_pr" >> %s\n' "$IDPROBE" "$(sq "$root/shell.id")"
    printf '%s\n' "$PRINT_SHIM"
    printf 'ROOT=%s; OP=%s; uid=12; name=x; pass=y; srcunit=%s\n' "$(sq "$root")" "$(sq "$op")" "$(sq "$pkg")"
    cat <<'STUB'
LOG="$ROOT/log"; RES="$ROOT/res"; STATE="$ROOT/state"; mkdir -p "$STATE"
AGENT="$ROOT/agent"; printf '#!/bin/sh\nexit 1\n' > "$AGENT"; chmod +x "$AGENT"
USERDIR="$ROOT/user/12"
pw() { printf "%s" "$1"; }
stat() { echo 0; }; chown() { :; }; restorecon() { :; }
STUB
    printf '%s\n' "$helper"
    printf 'case "$OP" in\n%s\nesac\n' "$arm"
  } > "$f"
}

# write_hold <file> <root> <helper> <hold_ondemand-text> <odhold-line>: the run file of one hold_ondemand case.
write_hold() {
  local f="$1" root="$2" helper="$3" fn="$4" odl="$5"
  {
    printf '%s; printf "%%s|%%s\\n" "$_id" "$_pr" >> %s\n' "$IDPROBE" "$(sq "$root/shell.id")"
    printf '%s\n' "$PRINT_SHIM"
    printf 'ROOT=%s\n' "$(sq "$root")"
    cat <<'STUB'
LOG="$ROOT/log"; restorecon() { :; }
STUB
    printf '%s\n' "$odl" "$helper" "$fn" 'hold_ondemand 12'
  } > "$f"
}

# run_arm <shell> <helper> <arm-text> <op> <pkg> -> prints the reply, then SENT-C / SENT-N for each surviving sentinel
run_arm() {
  local sh="$1" helper="$2" arm="$3" op="$4" pkg="$5" root out
  root=$(mktemp -d -p "$W") || exit 2
  mkdir -p "$root/user/12/com.nowhere.chooser/files/.appcode" "$root/nowhere/fetchapp"
  : > "$root/user/12/com.nowhere.chooser/files/sentinel"
  : > "$root/nowhere/sentinel"
  arm=${arm//\/data\/nowhere\/fetchapp/$root/nowhere/fetchapp}
  write_arm "$root/run.sh" "$root" "$op" "$pkg" "$helper" "$arm"
  out=$(runsh "$sh" "$root/run.sh")
  [ -n "${DEBUG:-}" ] && printf "inner: %s\n" "$out" >&2
  notrun "$sh" "$root"
  printf 'reply=%s\n' "$(cat "$root/res" 2>/dev/null)"
  [ -e "$root/user/12/com.nowhere.chooser/files/sentinel" ] && echo SENT-C
  [ -e "$root/nowhere/sentinel" ] && echo SENT-N
  command rm -rf "$root"
  return 0
}

# run_hold <shell> <helper> <hold_ondemand-text> <odhold-line> <pkg> -> HELD if <pkg>'s planted data moved into the
# hold, TOUCHED if any .nowhere-odhold dir was created, SENT-ALL if every sentinel survived.
run_hold() {
  local sh="$1" helper="$2" fn="$3" odl="$4" pkg="$5" root out d n
  root=$(mktemp -d -p "$W") || exit 2
  for d in user/12 user_de/12 media/12/Android/data media/12/Android/obb; do
    mkdir -p "$root/data/$d"; : > "$root/data/$d/sentinel"; : > "$root/data/${d%/*}/sentinel"
  done
  mkdir -p "$root/data/user/12/com.nowhere.chooser/files"
  printf '%s\tondemand\n' "$pkg" > "$root/data/user/12/com.nowhere.chooser/files/nowhere-appkeep"
  # The good-name path: plant real data for the package (mkdir fails harmlessly for a bad name like "a/b").
  mkdir -p "$root/data/user/12/$pkg" 2>/dev/null && : > "$root/data/user/12/$pkg/payload" 2>/dev/null
  fn=${fn//\/data\//$root/data/}
  write_hold "$root/run.sh" "$root" "$helper" "$fn" "$odl"
  out=$(runsh "$sh" "$root/run.sh")
  [ -n "${DEBUG:-}" ] && printf "inner: %s\n" "$out" >&2
  notrun "$sh" "$root"
  [ -e "$root/data/user/12/com.nowhere.chooser/.nowhere-odhold/$pkg/payload" ] && echo HELD
  [ -n "$(find "$root" -name .nowhere-odhold 2>/dev/null)" ] && echo TOUCHED
  n=0
  for d in user/12 user_de/12 media/12/Android/data media/12/Android/obb; do
    [ -e "$root/data/$d/sentinel" ] && [ -e "$root/data/${d%/*}/sentinel" ] && n=$((n+1))
  done
  [ "$n" = 4 ] && echo SENT-ALL
  command rm -rf "$root"
  return 0
}

shown() { # a name as it is printed: the long ones by length
  if [ "${#1}" -gt 40 ]; then printf '<%d-byte name>' "${#1}"; else printf "'%s'" "$1"; fi
}

suite() { # suite <roamd.sh> <shell> [quiet] -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" s="$2" quiet="${3:-}" p=0 x=0 op arm out bad good helper fn odl pf pr
  ok(){ p=$((p+1)); [ -n "$quiet" ] || printf '  ok    [%s] %s\n' "$s" "$1"; }
  no(){ x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  [%s] %s\n' "$s" "$1"; }
  helper=$(extract_fn "$f" pkgname_ok)
  case "$helper" in *'return 1'*'return 0'*) ;; *) echo "EXTRACTION FAILED -- pkgname_ok moved in $f" >&2; return 2 ;; esac
  fn=$(extract_fn "$f" hold_ondemand)
  odl=$(grep -m1 '^ODHOLD=' "$f")
  case "$fn" in *'nowhere-appkeep'*'rm -rf'*) ;; *) echo "EXTRACTION FAILED -- hold_ondemand moved in $f" >&2; return 2 ;; esac
  [ -n "$odl" ] || { echo "EXTRACTION FAILED -- ODHOLD= not found in $f" >&2; return 2; }
  # Parse check: each run file, as the cases write it, must parse under the shell that will run it.
  pf=$(mktemp -p "$W") && pr=$(mktemp -d -p "$W") || return 2
  for op in materializeapp stageapp; do
    arm=$(extract_arm "$f" "$op")
    case "$arm" in *'bad pkg'*'rm -rf'*) ;; *) echo "EXTRACTION FAILED -- the $op arm moved in $f" >&2; rm -rf "$pf" "$pr"; return 2 ;; esac
    write_arm "$pf" "$pr" "$op" org.fossify.math "$helper" "$arm"
    "$s" -n "$pf" || { echo "EXTRACTION FAILED -- the $op run file does not parse under $s ($f)" >&2; rm -rf "$pf" "$pr"; return 2; }
  done
  write_hold "$pf" "$pr" "$helper" "$fn" "$odl"
  "$s" -n "$pf" || { echo "EXTRACTION FAILED -- the hold_ondemand run file does not parse under $s ($f)" >&2; rm -rf "$pf" "$pr"; return 2; }
  rm -rf "$pf" "$pr"
  : > "$W/notrun"; : > "$W/harness"
  for op in materializeapp stageapp; do
    arm=$(extract_arm "$f" "$op")
    for bad in "${BAD[@]}"; do
      out=$(run_arm "$s" "$helper" "$arm" "$op" "$bad")
      case "$out" in
        *'reply=ERR-PKG'*) ok "$op: $(shown "$bad") -> ERR-PKG" ;;
        *) no "$op: $(shown "$bad") answered [$(head -n1 <<<"$out")], want ERR-PKG" ;;
      esac
      case "$out" in
        *SENT-C*SENT-N*) ok "$op: $(shown "$bad") leaves both sentinels" ;;
        *) no "$op: $(shown "$bad") destroyed a sentinel [$(tr '\n' ' ' <<<"$out")]" ;;
      esac
    done
    for good in "${GOOD[@]}"; do
      out=$(run_arm "$s" "$helper" "$arm" "$op" "$good")
      case "$out" in
        *'reply=ERR-PKG'*) no "$op: $(shown "$good") was refused" ;;
        *'reply='?*) ok "$op: $(shown "$good") passes the guard [$(head -n1 <<<"$out")]" ;;
        *) no "$op: $(shown "$good") gave no reply" ;;
      esac
    done
  done
  for bad in "${BAD[@]}"; do
    out=$(run_hold "$s" "$helper" "$fn" "$odl" "$bad")
    case "$out" in
      *TOUCHED*) no "hold_ondemand: $(shown "$bad") created a hold [$(tr '\n' ' ' <<<"$out")]" ;;
      *) ok "hold_ondemand: $(shown "$bad") is skipped" ;;
    esac
    case "$out" in
      *SENT-ALL*) ok "hold_ondemand: $(shown "$bad") leaves every sentinel" ;;
      *) no "hold_ondemand: $(shown "$bad") destroyed a sentinel" ;;
    esac
  done
  for good in "${GOOD[@]}"; do
    out=$(run_hold "$s" "$helper" "$fn" "$odl" "$good")
    case "$out" in
      *HELD*SENT-ALL*) ok "hold_ondemand: $(shown "$good") is held" ;;
      *) no "hold_ondemand: $(shown "$good") was not held [$(tr '\n' ' ' <<<"$out")]" ;;
    esac
  done
  if [ -s "$W/harness" ]; then echo "HARNESS ERROR: a run file left no identity: $s did not launch it" >&2; return 2; fi
  # run_arm and run_hold run inside $( ), so a case that did not run under $s says so through $W/notrun
  if grep -qx "$s" "$W/notrun"; then no "identity: a case did not run under $s"; else ok "identity: every case ran under $s"; fi
  [ -n "$quiet" ] || printf '  -- [%s] %d passed, %d failed\n' "$s" "$p" "$x"
  [ "$x" = 0 ] && return 0 || return 1
}

echo "package-name guard: $SUT"
echo "shells:$SHELLS"
echo "sh identity: $REF_SH"
HARN=0; FAILED=0
for s in $SHELLS; do
  suite "$SUT" "$s"; rc=$?
  case "$rc" in 0) ;; 1) FAILED=1 ;; *) HARN=1 ;; esac
done
if [ "$MUTATE" = no ]; then [ "$HARN" = 0 ] || exit 2; exit "$FAILED"; fi

[ "$HARN" = 0 ] || { echo "baseline suite: harness error; fix it before mutating" >&2; exit 2; }
[ "$FAILED" = 0 ] || { echo "baseline suite fails; fix it before mutating" >&2; exit 1; }
echo "-- mutations (each must be CONVICTED under every shell found) --"
fail=0; tmp=$(mktemp -d -p "$W") || exit 2
convict() { # <label> <mutant script>: convicted only when the suite FAILS (rc 1) under each shell found
  local s r alive="" err=""
  if cmp -s "$2" "$SUT"; then echo "  MUTANT FAILED TO APPLY: $1" >&2; fail=1; return; fi
  for s in $SHELLS; do
    suite "$2" "$s" quiet >/dev/null 2>&1; r=$?
    case "$r" in
      0) alive="$alive $s" ;;
      1) ;;
      *) err="$err $s" ;;
    esac
  done
  if [ -n "$alive" ]; then echo "  SURVIVED  $1 under:$alive"; fail=1
  elif [ -n "$err" ]; then echo "  HARNESS ERROR (not a conviction) $1 under:$err"; fail=1
  else echo "  convicted $1 under every shell"; fi
}
# mut_fn <label> <function> <from> <to>: replace the first literal <from> inside <function> with <to>
# (<to> = "DELETE" drops the line holding <from>).
mut_fn() {
  local m="$tmp/m.sh"
  awk -v start="$2() {" -v from="$3" -v to="$4" '
    $0 == start { on = 1 }
    on && !done && index($0, from) {
      done = 1
      if (to == "DELETE") next
      i = index($0, from); $0 = substr($0, 1, i - 1) to substr($0, i + length(from))
    }
    on && $0 == "}" { on = 0 }
    { print }' "$SUT" > "$m"
  convict "$1" "$m"
}

# The old guard back in each caller.
for op in materializeapp stageapp; do
  m="$tmp/$op.sh"
  awk -v op="  $op)" -v want="    pkgname_ok \"\$pkg\" || { echo \"[roamd] $op bad pkg" \
      -v old="    case \"\$pkg\" in \"\"|*/*|*\" \"*) echo \"[roamd] $op bad pkg \$(date)\" >> \"\$LOG\"; echo \"ERR-PKG\" > \"\$RES\"; chmod 600 \"\$RES\"; exit 0;; esac" '
    $0 == op { on = 1 }
    on && index($0, want) == 1 { $0 = old }
    on && $0 == "    ;;" { on = 0 }
    { print }' "$SUT" > "$m"
  convict "old guard in $op" "$m"
done
mut_fn "old guard in hold_ondemand" hold_ondemand '    pkgname_ok "$pkg" || continue' \
  "    case \"\$pkg\" in ''|*/*|*\" \"*) continue;; esac"

# Each rule of pkgname_ok dropped, loosened or over-tightened.
mut_fn "pkgname_ok: no-dot rule dropped"       pkgname_ok 'case "$p" in *.*) ;; *) return 1;; esac' DELETE
mut_fn "pkgname_ok: length rule dropped"       pkgname_ok '[ "${#p}" -le 255 ] || return 1' DELETE
mut_fn "pkgname_ok: limit lowered to 254"      pkgname_ok '-le 255' '-le 254'
mut_fn "pkgname_ok: limit raised to 256"       pkgname_ok '-le 255' '-le 256'
mut_fn "pkgname_ok: length compares a non-number" pkgname_ok '[ "${#p}" -le 255 ]' '[ "x${#p}" -le 255 ]'
mut_fn "pkgname_ok: trailing-dot rule dropped" pkgname_ok 'in *.|' 'in '
mut_fn "pkgname_ok: empty-segment rule dropped" pkgname_ok '*..*|' ''
mut_fn "pkgname_ok: ._ rule dropped"           pkgname_ok '*._*|' ''
mut_fn "pkgname_ok: .<digit> rule dropped"     pkgname_ok '*.[0-9]*|' ''
mut_fn "pkgname_ok: charset rule dropped"      pkgname_ok '*[!A-Za-z0-9._]*|' ''
mut_fn "pkgname_ok: first-byte rule dropped"   pkgname_ok '|[!A-Za-z]*)' ')'
mut_fn "pkgname_ok: charset loses A-Z"         pkgname_ok '[!A-Za-z0-9._]' '[!a-z0-9._]'
mut_fn "pkgname_ok: charset loses 0-9"         pkgname_ok '[!A-Za-z0-9._]' '[!A-Za-z._]'
mut_fn "pkgname_ok: charset loses _"           pkgname_ok '[!A-Za-z0-9._]' '[!A-Za-z0-9.]'
mut_fn "pkgname_ok: first byte must be a-z"    pkgname_ok '[!A-Za-z]*)' '[!a-z]*)'

# The runner ignores its shell argument and always runs bash: the identity check must convict it under every non-bash
# shell found.
mutate_runner() {
  local s bad="" want="" cp="$tmp/suite-runner.sh"
  sed 's/^runsh(){ "\$1" "\$2"/runsh(){ bash "$2"/' "$0" > "$cp"
  if cmp -s "$0" "$cp"; then echo "  MUTANT FAILED TO APPLY: the runner always runs bash" >&2; fail=1; return; fi
  for s in $SHELLS; do
    case "$s" in
      bash) ;;
      sh) case "$REF_SH" in bash:*) ;; *) want="$want $s" ;; esac ;;
      *) want="$want $s" ;;
    esac
  done
  [ -n "$want" ] || { echo "  n/a       the runner always runs bash: no non-bash shell on this host (CI has dash and mksh)"; return; }
  TMPDIR="$tmp" bash "$cp" "$SUT" > "$tmp/runner.out" 2>&1
  for s in $want; do grep -q "FAIL  \[$s\]" "$tmp/runner.out" || bad="$bad $s"; done
  if [ -z "$bad" ]; then echo "  convicted the runner always runs bash under:$want"
  else echo "  SURVIVED  the runner always runs bash under:$bad"; fail=1; fi
}
# A run file that never launches must end the suite with exit 2 and HARNESS ERROR -- not exit 1 with FAIL lines, which
# a mutation run would count as a conviction.
probe() { # probe <label> <sed program over this suite>
  local cp="$tmp/suite-probe.sh" rc
  sed "$2" "$0" > "$cp"
  if cmp -s "$0" "$cp"; then echo "  MUTANT FAILED TO APPLY: $1" >&2; fail=1; return; fi
  TMPDIR="$tmp" bash "$cp" "$SUT" > "$tmp/probe.out" 2>&1; rc=$?
  if [ "$rc" -eq 2 ] && grep -q 'HARNESS ERROR' "$tmp/probe.out"; then echo "  harness error, not a conviction: $1"
  else echo "  HARNESS ERROR NOT RAISED (rc $rc): $1"; fail=1; fi
}
probe 'the child never launches' 's/^runsh(){ .*$/runsh(){ return 127; }/'
mutate_runner

# Go side: validPkgName dropped from each handler -> the Go tests must FAIL (a mutant that does not compile proves
# nothing, so it is reported as such and fails the run).
if [ -z "$AGENT_DIR" ] || ! command -v go >/dev/null 2>&1; then
  echo "  SKIPPED Go mutants: no go toolchain or core/agent here" >&2; fail=1
else
  for fn in handleMaterializeApp handleRestoreOdData handleFetchApp; do
    g="$tmp/go-$fn"; mkdir -p "$g"; cp -r "$AGENT_DIR"/. "$g"/
    file=app_code.go; [ "$fn" = handleFetchApp ] && file=catalog.go
    awk -v fn="func $fn(" '
      index($0, fn) == 1 { on = 1 }
      on && /validPkgName/ { sub(/!validPkgName\([^)]*\)/, "false"); on = 0 }
      { print }' "$AGENT_DIR/$file" > "$g/$file"
    cmp -s "$g/$file" "$AGENT_DIR/$file" && { echo "  MUTANT FAILED TO APPLY: $fn without validPkgName" >&2; fail=1; continue; }
    # $g is a new path every run: without -trimpath that path is in every compile's cache key, so each run would add
    # a full set of GOCACHE entries that are never hit again. TMPDIR keeps the tests' temp dirs inside W.
    out=$(cd "$g" && TMPDIR="$tmp" GOTOOLCHAIN=auto go test -trimpath -count=1 \
      -run 'TestAppCodeVerbsRefuseDotNames|TestRestoreOdDataGuards' . 2>&1)
    case "$out" in
      *'--- FAIL'*) echo "  convicted $fn without validPkgName" ;;
      ok*) echo "  SURVIVED  $fn without validPkgName"; fail=1 ;;
      *) echo "  DID NOT RUN (compile or setup failure) $fn without validPkgName:"; printf '%s\n' "$out" | head -n 20; fail=1 ;;
    esac
  done
fi
[ "$fail" = 0 ] && echo "all mutants convicted" || { echo "SOME MUTANTS SURVIVED OR FAILED"; exit 1; }
