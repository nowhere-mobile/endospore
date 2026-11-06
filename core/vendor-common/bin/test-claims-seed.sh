#!/usr/bin/env bash
# test-claims-seed.sh [<nowhere_roamd.sh>] [--mutate] -- a sign-in installs the claim file the bare-vault restore
# staged, and nothing else does (NWP-20261029-06; backlog §B EVERY LOGIN STARTS WITH THE OTHER HANDSET'S APPS
# TAPPABLE).
#
# WHY THIS IS COMMITTED. The `in)` arm of nowhere_roamd.sh deletes whatever claim file the roam-in restored
# (`rm -f .../nowhere-claims`), so a handset signing in second had NO claim file until its first seal, and every
# app the other handset holds launched for ~40 s. The fix stages the file in $STATE/claims.seed from the head the
# restore already decrypts, and installs it AFTER those deletes, owned by the files dir's owner, mode 600, and
# unlinks the staged copy either way. This suite evals the three real pieces of the arm -- the rm before the
# restore chain, the bare restore line, and the segment from the claims rm to the appheld rm -- under every shell
# found, with the agent and chown/restorecon/stat as stubs that record what was asked of them.
#
#   bash test-claims-seed.sh              # the cases
#   bash test-claims-seed.sh --mutate     # ... plus mutants of roamd that must each CONVICT under every shell
#
# Pure logic -- no device. Exit 0 all pass, 1 a check failed, 2 the harness could not extract (never a pass).
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SELF="$0"
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT   # every case root and mutant copy is made inside it

SHELLS=""
if [ -n "${SEED_SHELLS:-}" ]; then SHELLS="$SEED_SHELLS"
else for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done; fi

arm_of() { awk -v a="  $2)" '$0 == a {f=1} f{print} f&&/^    ;;$/{exit}' "$1"; }
codeonly() { grep -vE '^[[:space:]]*#' ; }

PRE_LINE='    rm -f "$STATE/claims.seed" 2>> "$LOG"'
CLAIMS_RM='      rm -f "$USERDIR/com.nowhere.chooser/files/nowhere-claims" 2>>"$LOG"'
HELD_RM='      rm -f "$USERDIR/com.nowhere.chooser/files/nowhere-appheld.list" 2>>"$LOG"'
INSTALL_IF='      if [ -f "$STATE/claims.seed" ]; then'
RESTORE_PAT='"$AGENT" restore s3 "$name" "$(pw "$pass")" "$USERDIR"'

lineno() {  # lineno <file> <exact line> -> the 1-based numbers of every line equal to it
  awk -v l="$2" '$0 == l {print NR}' "$1"
}

suite() {  # suite <roamd.sh> <quiet|""> -> 0 all ok, 1 a check failed, 2 the harness could not extract
  local f="$1" quiet="${2:-}" p=0 x=0 IN CODE n rl cl hl il pl start sh
  say() { [ -n "$quiet" ] || printf '%s\n' "$1"; }
  chk() {
    local l="$1"; shift
    if "$@"; then p=$((p+1)); say "  ok    $l"; else x=$((x+1)); say "  FAIL  $l"; fi
  }

  IN=$(arm_of "$f" in)
  [ -n "$IN" ] || { echo "EXTRACTION FAILED: the in arm in $f" >&2; return 2; }
  CODE=$(printf '%s\n' "$IN" | codeonly)
  for a in "$CLAIMS_RM" "$HELD_RM"; do
    n=$(printf '%s\n' "$CODE" | grep -cxF -- "$a")
    [ "$n" = 1 ] || { echo "EXTRACTION FAILED: anchor '$a' matches $n times in the in arm" >&2; return 2; }
  done
  n=$(printf '%s\n' "$CODE" | grep -cF -- "$RESTORE_PAT")
  [ "$n" = 1 ] || { echo "EXTRACTION FAILED: the bare restore line matches $n times in the in arm" >&2; return 2; }

  rl=$(printf '%s\n' "$CODE" | grep -nF -- "$RESTORE_PAT" | cut -d: -f1)
  cl=$(lineno <(printf '%s\n' "$CODE") "$CLAIMS_RM")
  hl=$(lineno <(printf '%s\n' "$CODE") "$HELD_RM")
  il=$(lineno <(printf '%s\n' "$CODE") "$INSTALL_IF" | head -1)
  pl=$(lineno <(printf '%s\n' "$CODE") "$PRE_LINE" | head -1)
  # the restore line, made runnable: no leading elif/if, no trailing "; then"
  RUNRESTORE=$(printf '%s\n' "$CODE" | sed -n "${rl}p" | sed -E 's/^[[:space:]]*(el)?if //; s/; then$//')
  start=$cl; [ -n "$il" ] && [ "$il" -lt "$start" ] && start=$il
  printf '%s\n' "$CODE" | sed -n "${start},${hl}p" > "$W/seg.sh"
  : > "$W/pre.sh"
  [ -n "$pl" ] && [ "$pl" -lt "$rl" ] && printf '%s\n' "$PRE_LINE" > "$W/pre.sh"
  printf '%s\n' "$RUNRESTORE" > "$W/restore.sh"

  # run_case <shell> <simseed 0|1> <failchown 0|1> <stale-seed 0|1> -> ROOT is set to the case root
  run_case() {
    local s="$1"
    ROOT=$(mktemp -d -p "$W")
    mkdir -p "$ROOT/state" "$ROOT/user/com.nowhere.chooser/files"
    printf 'stale.pkg\tunitX\n' > "$ROOT/user/com.nowhere.chooser/files/nowhere-claims"
    [ "$4" = 1 ] && printf 'stale.seed\tunitZ\n' > "$ROOT/state/claims.seed"
    cat > "$ROOT/case.sh" <<CASE
umask 022
ROOT="$ROOT"; STATE="\$ROOT/state"; USERDIR="\$ROOT/user"; LOG="\$ROOT/log"; uid=11; name=prof; pass=pw
SIM_SEED=$2; FAILCHOWN=$3; AGENT=agent_sim
pw() { printf '%s\n' x; }
agent_sim() {
  echo "env-seed=\${NOWHERE_CLAIMS_SEED:-}" >> "\$ROOT/calls"
  if [ -n "\${NOWHERE_CLAIMS_SEED:-}" ] && [ "\$SIM_SEED" = 1 ]; then
    printf '# header\npkgA\tunitB\n' > "\$NOWHERE_CLAIMS_SEED"
  fi
  return 0
}
stat() { echo "stat \$*" >> "\$ROOT/calls"; echo 4321:8765; }
chown() { echo "chown \$*" >> "\$ROOT/calls"; [ "\$FAILCHOWN" != 1 ]; }
restorecon() { echo "restorecon \$*" >> "\$ROOT/calls"; return 0; }
: > "\$LOG"
. "$W/pre.sh"
. "$W/restore.sh"
. "$W/seg.sh"
CASE
    "$s" "$ROOT/case.sh" > "$ROOT/out" 2>&1
  }
  fs() { echo "$ROOT/user/com.nowhere.chooser/files"; }
  logs() { grep -qF -- "$1" "$ROOT/log"; }
  called() { grep -qF -- "$1" "$ROOT/calls"; }
  absent() { [ ! -e "$1" ]; }
  mode_is() { [ "$(command stat -c %a "$1" 2>/dev/null)" = "$2" ]; }
  same() { [ -f "$1" ] && [ "$(cat "$1")" = "$2" ]; }

  for sh in $SHELLS; do
    say "== $sh"
    run_case "$sh" 1 0 0
    chk "R1 [$sh] the seed is installed as nowhere-claims, not the restored copy" same "$(fs)/nowhere-claims" "$(printf '# header\npkgA\tunitB')"
    chk "R1 [$sh] it is chowned to the files dir's owner before the mv, restorecon'd, mode 600" \
      bash -c "grep -qF 'chown 4321:8765 $(fs)/nowhere-claims.tmp' '$ROOT/calls' && grep -qF restorecon '$ROOT/calls'"
    chk "R1 [$sh] mode 600" mode_is "$(fs)/nowhere-claims" 600
    chk "R1 [$sh] no tmp is left and the staged seed is gone" bash -c "[ ! -e '$(fs)/nowhere-claims.tmp' ] && [ ! -e '$ROOT/state/claims.seed' ]"
    chk "R1 [$sh] the log counts it" logs "claims seed: 1 package(s) held elsewhere -> installed for user 11"
    chk "R5 [$sh] the seed path reached the bare restore's environment" called "env-seed=$ROOT/state/claims.seed"

    run_case "$sh" 0 0 0
    chk "R2 [$sh] no seed written -> no nowhere-claims (the restored copy is gone)" absent "$(fs)/nowhere-claims"
    chk "R2 [$sh] no tmp" absent "$(fs)/nowhere-claims.tmp"
    chk "R2 [$sh] the log says none" logs "claims seed: none"

    run_case "$sh" 0 0 1
    chk "R3 [$sh] a stale seed is not installed when the agent writes none" absent "$(fs)/nowhere-claims"
    chk "R3 [$sh] the stale seed is gone" absent "$ROOT/state/claims.seed"
    chk "R3 [$sh] the log says none" logs "claims seed: none"

    run_case "$sh" 1 1 0
    chk "R4 [$sh] a failing chown leaves no nowhere-claims" absent "$(fs)/nowhere-claims"
    chk "R4 [$sh] ... and no tmp" absent "$(fs)/nowhere-claims.tmp"
    chk "R4 [$sh] ... and the seed is gone" absent "$ROOT/state/claims.seed"
    chk "R4 [$sh] the log says NOT installed" logs "claims seed: NOT installed for user 11"
  done

  # R5: text checks over the whole script, comments dropped
  local ALL
  ALL=$(codeonly < "$f")
  n=$(printf '%s\n' "$ALL" | grep -F -- "$RESTORE_PAT" | grep -cF "NOWHERE_CLAIMS_SEED=\"\$STATE/claims.seed\" \"\$AGENT\" restore s3")
  chk "R5 the seed is inline on the bare restore line" [ "$n" = 1 ]
  n=$(printf '%s\n' "$ALL" | grep -cE 'export[^#]*NOWHERE_CLAIMS_SEED')
  chk "R5 it is never exported" [ "$n" = 0 ]
  n=$(printf '%s\n' "$ALL" | grep -E 'restore s3 .*#(de|media|apps|sys|keys)' | grep -cF NOWHERE_CLAIMS_SEED)
  chk "R5 the #de/#media/#apps/#sys/#keys restores do not carry it" [ "$n" = 0 ]
  n=$(printf '%s\n' "$ALL" | grep -F NOWHERE_CLAIMS_SEED | grep -cvF -- "$RESTORE_PAT")
  chk "R5 no other line names it" [ "$n" = 0 ]
  # ordering: the install comes after both claim rms and before OK
  local okl al
  okl=$(printf '%s\n' "$CODE" | awk '$0 == "      echo \"OK $uid\" > \"$RES\"; _inres=OK" {print NR; exit}')
  al=$(printf '%s\n' "$CODE" | awk '/nowhere-appclaim" 2>>"\$LOG"$/ {print NR; exit}')
  chk "R6 the install follows the claims and appclaim rms and precedes OK" \
    bash -c '[ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ] && [ -n "$4" ] && [ "$1" -gt "$2" ] && [ "$1" -gt "$3" ] && [ "$1" -lt "$4" ]' _ "$il" "$cl" "$al" "$okl"
  chk "R3 the pre-restore rm is present, before the restore" [ -s "$W/pre.sh" ]

  [ -z "$quiet" ] && printf '%s: passed %d, failed %d\n' "$f" "$p" "$x"
  [ "$x" = 0 ]
}

mutate_to() {  # mutate_to <mutant name> <out file> -- transform $SUT; sets nothing
  case "$1" in
  N1) awk -v ifl="$INSTALL_IF" -v crm="$CLAIMS_RM" '
        NR==FNR { if (!d && $0 == ifl) in_b=1; if (in_b) { blk[++nb]=$0; if ($0 == "      fi") { in_b=0; d=1 } } next }
        { if (!d2 && $0 == ifl) { in_s=1 }
          if (in_s) { if ($0 == "      fi") { in_s=0; d2=1 } next }
          if ($0 == crm) for (i=1;i<=nb;i++) print blk[i]
          print }' "$SUT" "$SUT" > "$2" ;;
  N2) awk '$0 == "      rm -f \"$STATE/claims.seed\" 2>> \"$LOG\"" {next} {print}' "$SUT" > "$2" ;;
  N3) awk -v l="$PRE_LINE" '$0 == l {next} {print}' "$SUT" > "$2" ;;
  N4) awk 'BEGIN{p="chown \"$_csown\" \"$_csdst.tmp\" 2>> \"$LOG\" && "} {i=index($0,p); if (i) $0=substr($0,1,i-1) substr($0,i+length(p))} {print}' "$SUT" > "$2" ;;
  N5) awk -v l="$PRE_LINE" 'BEGIN{p="NOWHERE_CLAIMS_SEED=\"$STATE/claims.seed\" "}
        $0 == l {print "    export NOWHERE_CLAIMS_SEED=\"$STATE/claims.seed\""}
        {i=index($0,p); if (i && index($0,"restore s3")) $0=substr($0,1,i-1) substr($0,i+length(p))} {print}' "$SUT" > "$2" ;;
  esac
}

run_mutants() {
  local m c sh rc bad=0 desc
  for m in N1 N2 N3 N4 N5; do
    case "$m" in
      N1) desc="the install moved before the claims rm" ;;
      N2) desc="the seed's final rm removed" ;;
      N3) desc="the pre-restore rm removed" ;;
      N4) desc="install with no chown" ;;
      N5) desc="the variable exported instead of inline" ;;
    esac
    c=$(mktemp -p "$W")
    mutate_to "$m" "$c"
    if cmp -s "$c" "$SUT"; then echo "  FAIL  $m did not apply: $desc"; bad=1; rm -f "$c"; continue; fi
    for sh in $SHELLS; do
      SEED_SHELLS="$sh" bash "$SELF" "$c" >/dev/null 2>&1; rc=$?
      if [ "$rc" = 1 ]; then echo "  ok    $m CONVICTED under $sh: $desc"
      else echo "  FAIL  $m rc=$rc under $sh (want 1): $desc"; bad=1; fi
    done
    rm -f "$c"
  done
  return $bad
}

[ -n "$SHELLS" ] || { echo "no shell found" >&2; exit 2; }
suite "$SUT" ""; rc=$?
[ "$rc" = 0 ] || exit "$rc"
if [ "$MUTATE" = yes ]; then
  run_mutants || exit 1
  echo "all mutants convicted"
fi
exit 0
