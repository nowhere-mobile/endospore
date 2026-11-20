#!/usr/bin/env bash
# test-roamd-secret-env.sh [<nowhere_roamd.sh>] [--mutate] -- roamd hands the chip secret (NOWHERE_SE_SECRET) and the
# security-key hmac (NOWHERE_FIDO2_HMAC) to each agent call as its OWN staged @file:, never as a value in the
# environment (NWP-20261205-18; docs/product-decisions.md 2026-11-04, h57 #9 option 1).
#
# WHY PER CALL. The agent reads a staged file and UNLINKS it at start (resolveArgFiles, adoptStagedSESecret). mediad
# execs one agent, so one export of a staged path serves it. roamd makes many agent calls in one run: one export
# would serve the FIRST call and make every later one die on "cannot read @file: value" -- a seal or a restore lost.
# So roamd holds both values in the unexported _se_v / _fh_v and puts two prefix assignments on every agent call:
#   NOWHERE_SE_SECRET="$(pwv "$_se_v")" NOWHERE_FIDO2_HMAC="$(pwv "$_fh_v")"
# pwv is pw for a value that may be absent: empty in, nothing staged, nothing printed (seDK and fido2HMAC read an
# empty variable as absent).
#
#   A (source, comments stripped; shell-independent):
#     A1 no `export` names either variable;
#     A2 neither name appears anywhere but in the exact prefix pair, and a line holding the pair calls "$AGENT";
#     A3 every line holding "$AGENT" and "$(pw " carries the pair immediately before "$AGENT" or before the
#        `timeout` that wraps it. CONTROL: at least 16 such lines (the count is printed).
#   B (executed under every shell found among bash, sh, dash and mksh): pw and pwv extracted BY ANCHOR (exit 2 when
#     an anchor moves), a stub agent that dumps its environment:
#     B1 one prefixed call: each variable is @file:$STATE/.pw.roamd.*, each file holds its value byte for byte, the
#        dump holds neither raw value, and neither variable persists in the shell after the call;
#     B2 two consecutive calls get two DIFFERENT files for each variable (the trap above);
#     B3 _fh_v empty: NOWHERE_FIDO2_HMAC reaches the agent empty and no file is staged for it.
#
#   bash test-roamd-secret-env.sh            # A, then B under every shell found
#   bash test-roamd-secret-env.sh --mutate   # ... plus R1-R6, each CONVICTED only when the suite fails under each shell
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
# Every temp of the run lives inside W.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

SHELLS=""; for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "no shell to run under" >&2; exit 2; }
PRINT_SHIM='command -v print >/dev/null 2>&1 || print() { _pn=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) _pn=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$_pn" = 1 ]; then command printf "%s\n" "$*"; else command printf "%s" "$*"; fi; }'
sq(){ printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

PAIR='NOWHERE_SE_SECRET="$(pwv "$_se_v")" NOWHERE_FIDO2_HMAC="$(pwv "$_fh_v")"'
SE_HEX=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
FH_HEX=fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210

# codeonly <file>: comment lines and trailing ` # ...` comments blanked, line numbers kept
codeonly(){ sed -E 's/^[[:space:]]*#.*$//; s/[[:space:]]#[[:space:]].*$//' "$1"; }

# scan_a <roamd.sh> -> FAIL/ok lines on stdout; rc 0 all held, 1 a check failed, 2 the control did not match
scan_a(){
  local f="$1" c="$W/code.sh" n bad
  codeonly "$f" > "$c"
  n=$(grep -cE 'export[^#;&|]*(NOWHERE_SE_SECRET|NOWHERE_FIDO2_HMAC)([^A-Za-z0-9_]|$)' "$c")
  [ "$n" = 0 ] && echo "  ok    A1 no export names NOWHERE_SE_SECRET or NOWHERE_FIDO2_HMAC" \
    || { echo "  FAIL  A1 $n export(s) name NOWHERE_SE_SECRET or NOWHERE_FIDO2_HMAC"; bad=1; }
  n=$(awk -v p="$PAIR" '{ l = $0; while ((i = index(l, p)) > 0) l = substr(l, 1, i - 1) substr(l, i + length(p))
                          if (l ~ /NOWHERE_SE_SECRET|NOWHERE_FIDO2_HMAC/) { print NR; next }
                          if (index($0, p) && !index($0, "\"$AGENT\"")) print NR }' "$c" | wc -l | tr -d ' ')
  [ "$n" = 0 ] && echo "  ok    A2 neither name appears outside the prefix pair, and every pair is on an \"\$AGENT\" line" \
    || { echo "  FAIL  A2 $n line(s) name either variable outside the prefix pair, or carry the pair with no \"\$AGENT\""; bad=1; }
  # A3: the pair sits immediately before "$AGENT", or before the `timeout` that precedes "$AGENT" on the line
  n=$(awk -v p="$PAIR" 'index($0, "\"$AGENT\"") && index($0, "\"$(pw ") {
        a = index($0, "\"$AGENT\""); t = index($0, "timeout "); w = (t > 0 && t < a) ? p " timeout " : p " \"$AGENT\""
        if (!index($0, w)) print NR }' "$c" | wc -l | tr -d ' ')
  [ "$n" = 0 ] && echo "  ok    A3 every staged agent call carries both prefixes, before \"\$AGENT\" (or its timeout)" \
    || { echo "  FAIL  A3 $n staged agent call(s) lack the prefix pair in place"; bad=1; }
  n=$(awk 'index($0, "\"$AGENT\"") && index($0, "\"$(pw ") { k++ } END { print k + 0 }' "$c")
  echo "  A control: $n staged agent calls"
  [ "$n" -ge 16 ] || { echo "  CONTROL FAILED: fewer than 16 lines hold \"\$AGENT\" and \"\$(pw \" in $f" >&2; return 2; }
  [ -z "${bad:-}" ]
}

# extract <roamd.sh> -> $W/fns.sh holds pw and pwv; rc 2 when an anchor moved
extract(){
  local f="$1" pwf pwvl
  pwf=$(awk '$0 == "pw() {" { on = 1 } on { print } on && $0 == "}" { exit }' "$f")
  pwvl=$(awk 'index($0, "pwv() {") == 1 { print; exit }' "$f")
  case "$pwf" in 'pw() {'*'@file:'*'}') ;; *) echo "EXTRACTION FAILED: pw() in $f" >&2; return 2 ;; esac
  case "$pwvl" in 'pwv() {'*'}') ;; *) echo "EXTRACTION FAILED: pwv() in $f" >&2; return 2 ;; esac
  printf '%s\n%s\n' "$pwf" "$pwvl" > "$W/fns.sh"
}

# run_b <shell> -> sets D (the case dir); the stub agent writes <call>.env, <call>.se / <call>.fh (the variable as
# seen), <call>.se.val / <call>.fh.val (a staged file's bytes, copied, the file left in place) and <call>.n (staged
# files in STATE at the call)
run_b(){
  local sh="$1" r
  D=$(mktemp -d -p "$W") || exit 2; mkdir -p "$D/state"
  cat > "$D/agent" <<'STUB'
#!/bin/sh
env > "$D/$1.env"
printf '%s' "${NOWHERE_SE_SECRET-<unset>}" > "$D/$1.se"
printf '%s' "${NOWHERE_FIDO2_HMAC-<unset>}" > "$D/$1.fh"
case "${NOWHERE_SE_SECRET-}" in @file:*) cat "${NOWHERE_SE_SECRET#@file:}" > "$D/$1.se.val" ;; esac
case "${NOWHERE_FIDO2_HMAC-}" in @file:*) cat "${NOWHERE_FIDO2_HMAC#@file:}" > "$D/$1.fh.val" ;; esac
ls -a "$D/state" | grep -c '^\.pw\.roamd\.' > "$D/$1.n"
exit 0
STUB
  chmod +x "$D/agent"
  r="$D/run.sh"
  {
    printf '%s\n' "$PRINT_SHIM"
    printf 'D=%s; STATE=%s; LOG=%s; LANE=rw; AGENT=%s; export D\n' "$(sq "$D")" "$(sq "$D/state")" "$(sq "$D/log")" "$(sq "$D/agent")"
    printf 'unset NOWHERE_SE_SECRET NOWHERE_FIDO2_HMAC\n'
    cat "$W/fns.sh"
    printf '_se_v=%s; _fh_v=%s\n' "$SE_HEX" "$FH_HEX"
    printf '%s "$AGENT" c1\n' "$PAIR"
    printf 'printf "%%s|%%s" "${NOWHERE_SE_SECRET-<unset>}" "${NOWHERE_FIDO2_HMAC-<unset>}" > "$D/after"\n'
    printf '%s "$AGENT" c2\n' "$PAIR"
    printf '_fh_v=""\n'
    printf '%s "$AGENT" c3\n' "$PAIR"
    printf ': > "$D/reached"\n'
  } > "$r"
  "$sh" "$r" > "$D/out" 2>&1 </dev/null
}

# suite <roamd.sh> <shell> [quiet] -> 0 all ok, 1 a check failed, 2 the harness could not run
suite(){
  local f="$1" s="$2" quiet="${3:-}" p=0 x=0 out rc v
  ok(){ p=$((p+1)); [ -n "$quiet" ] || printf '  ok    [%s] %s\n' "$s" "$1"; }
  no(){ x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  [%s] %s\n' "$s" "$1"; }
  out=$(scan_a "$f"); rc=$?
  [ -n "$quiet" ] || printf '%s\n' "$out" | sed "s/^  ok    /  ok    [$s] /; s/^  FAIL  /  FAIL  [$s] /"
  [ "$rc" = 2 ] && return 2
  [ "$rc" = 0 ] || x=$((x+1))
  extract "$f" || return 2

  run_b "$s"
  [ -e "$D/reached" ] || { echo "HARNESS ERROR [$s]: the run did not reach its end: $(head -3 "$D/out")" >&2; return 2; }
  if [ "$(grep -cE 'not found|syntax error|bad substitution|unbound variable|parameter not set' "$D/out")" != 0 ]; then
    echo "HARNESS ERROR [$s]: $(head -3 "$D/out")" >&2; return 2
  fi
  case "$(cat "$D/c1.se")" in "@file:$D/state/.pw.roamd."*) ok "B1 NOWHERE_SE_SECRET reaches the agent as @file:\$STATE/.pw.roamd.*" ;; *) no "B1 NOWHERE_SE_SECRET reaches the agent as @file:\$STATE/.pw.roamd.* (got '$(cat "$D/c1.se")')" ;; esac
  case "$(cat "$D/c1.fh")" in "@file:$D/state/.pw.roamd."*) ok "B1 NOWHERE_FIDO2_HMAC reaches the agent as @file:\$STATE/.pw.roamd.*" ;; *) no "B1 NOWHERE_FIDO2_HMAC reaches the agent as @file:\$STATE/.pw.roamd.* (got '$(cat "$D/c1.fh")')" ;; esac
  # pw writes the value and one newline, which the agent's resolveArgFiles strips
  printf '%s\n' "$SE_HEX" > "$W/want.se"; printf '%s\n' "$FH_HEX" > "$W/want.fh"
  cmp -s "$W/want.se" "$D/c1.se.val" 2>/dev/null && ok "B1 the chip secret's file holds it byte for byte" || no "B1 the chip secret's file holds it byte for byte"
  cmp -s "$W/want.fh" "$D/c1.fh.val" 2>/dev/null && ok "B1 the key hmac's file holds it byte for byte" || no "B1 the key hmac's file holds it byte for byte"
  v=$(cat "$D"/c1.env "$D"/c2.env "$D"/c3.env | grep -cF -e "$SE_HEX" -e "$FH_HEX")
  [ "$v" = 0 ] && ok "B1 no agent environment holds either raw value" || no "B1 no agent environment holds either raw value ($v line(s) do)"
  [ "$(cat "$D/after")" = '<unset>|<unset>' ] && ok "B1 neither variable persists in the shell after the call" \
    || no "B1 neither variable persists in the shell after the call (got '$(cat "$D/after")')"
  [ "$(cat "$D/c2.se")" != "$(cat "$D/c1.se")" ] && [ -s "$D/c2.se.val" ] && ok "B2 a second call stages its OWN chip-secret file" \
    || no "B2 a second call stages its OWN chip-secret file (c1 '$(cat "$D/c1.se")', c2 '$(cat "$D/c2.se")')"
  [ "$(cat "$D/c2.fh")" != "$(cat "$D/c1.fh")" ] && [ -s "$D/c2.fh.val" ] && ok "B2 a second call stages its OWN key-hmac file" \
    || no "B2 a second call stages its OWN key-hmac file (c1 '$(cat "$D/c1.fh")', c2 '$(cat "$D/c2.fh")')"
  [ "$(cat "$D/c3.fh")" = "" ] && ok "B3 _fh_v empty: NOWHERE_FIDO2_HMAC reaches the agent empty" \
    || no "B3 _fh_v empty: NOWHERE_FIDO2_HMAC reaches the agent empty (got '$(cat "$D/c3.fh")')"
  [ "$(( $(cat "$D/c3.n") - $(cat "$D/c2.n") ))" = 1 ] && ok "B3 _fh_v empty: one file staged, the chip secret's, none for the hmac" \
    || no "B3 _fh_v empty: one file staged, the chip secret's, none for the hmac (staged $(( $(cat "$D/c3.n") - $(cat "$D/c2.n") )))"
  rm -rf "$D"
  [ -n "$quiet" ] || printf '  -- [%s] %d ok, %d failed\n' "$s" "$p" "$x"
  [ "$x" -eq 0 ]
}

echo "roamd hands the chip secret and the key hmac per agent call: $SUT"
echo "shells:$SHELLS"
FAILED=0
for s in $SHELLS; do
  suite "$SUT" "$s"; rc=$?
  [ "$rc" = 0 ] || FAILED=$(( rc > FAILED ? rc : FAILED ))
  [ "$rc" = 2 ] && break
done
[ "$FAILED" = 0 ] || { echo "FAILED (rc=$FAILED)"; exit "$FAILED"; }
[ "$MUTATE" = yes ] || { echo "== all cases passed"; exit 0; }

echo
echo "== mutations (each must CONVICT the suite under every shell found) =="
MFAIL=0
# mutate <label> <convicting check> <sed program over roamd>
mutate(){
  local label="$1" by="$2" prog="$3" mf r s alive="" err=""
  mf=$(mktemp -p "$W") || exit 2
  if ! sed "$prog" "$SUT" > "$mf" 2>/dev/null; then printf '  ERR   %-58s MUTATION BROKEN (sed)\n' "$label"; MFAIL=1; return; fi
  if cmp -s "$SUT" "$mf"; then printf '  SKIP  %-58s MUTATION INERT\n' "$label"; MFAIL=1; return; fi
  for s in $SHELLS; do
    r=$(suite "$mf" "$s" 2>/dev/null); case $? in
      0) alive="$alive $s" ;;
      1) [ "$(printf '%s\n' "$r" | grep -cF "FAIL  [$s] $by")" -ge 1 ] || alive="$alive $s(not-$by)" ;;
      *) err="$err $s" ;;
    esac
  done
  rm -f "$mf"
  if [ -n "$alive" ]; then printf '  XX    %-58s NOT CONVICTED by %s under:%s\n' "$label" "$by" "$alive"; MFAIL=1
  elif [ -n "$err" ]; then printf '  ERR   %-58s harness error (not a conviction) under:%s\n' "$label" "$err"; MFAIL=1
  else printf '  ok    %-58s convicted by %s under every shell (%s )\n' "$label" "$by" "$SHELLS"; fi
}
mutate "R1 one site's pwv removed (raw \"\$_se_v\", the _push helper)" A2 \
  '/"\$AGENT" push s3 "\$2"/s/NOWHERE_SE_SECRET="\$(pwv "\$_se_v")"/NOWHERE_SE_SECRET="$_se_v"/'
mutate "R2 export NOWHERE_SE_SECRET=\"\$sesec\" put back at line 5" A1 \
  's/^\(\[ -n "\$sesec" \] && _se_v="\$sesec".*\)$/\1\n[ -n "$sesec" ] \&\& export NOWHERE_SE_SECRET="$sesec"/'
mutate "R3 the prefix dropped from the in CE restore" A3 \
  '/NOWHERE_CLAIMS_SEED="\$STATE\/claims.seed" NOWHERE_SE_SECRET/s/NOWHERE_SE_SECRET="\$(pwv "\$_se_v")" NOWHERE_FIDO2_HMAC="\$(pwv "\$_fh_v")" //'
mutate "R4 pwv stages an empty value" B3 \
  's/^pwv() { \[ -z "\$1" \] || pw "\$1"; }$/pwv() { pw "$1"; }/'
mutate "R5 pwv prints the raw value" B1 \
  's/^pwv() { \[ -z "\$1" \] || pw "\$1"; }$/pwv() { [ -z "$1" ] || print -r -- "$1"; }/'
mutate "R6 one process-wide export of a staged path, no prefixes" A1 \
  's/NOWHERE_SE_SECRET="\$(pwv "\$_se_v")" NOWHERE_FIDO2_HMAC="\$(pwv "\$_fh_v")" //; s/^\(\[ -n "\$sesec" \] && _se_v="\$sesec".*\)$/\1\nexport NOWHERE_SE_SECRET="$(pw "$_se_v")"/'
if [ "$MFAIL" = 0 ]; then echo "== all mutations convicted"; else echo "== a mutation was not convicted"; exit 1; fi
