#!/usr/bin/env bash
# test-verified-commit.sh [<build-dir>] [--mutate] -- --release signs only the commit the operator verified (NWP-20261104-03, Q094).
#
# 2026090110 and 2026090201 signed an old commit after the build host's pull aborted; main moving between the build pass and
# --release signs code nobody verified. verified-commit-guard.sh refuses unless HEAD is the verified commit and no tracked file
# is modified. This runs the guard under every shell found (bash, sh, dash, mksh) against a scratch two-commit repo, runs
# build-device.sh's argument parse by anchor (--release with no commit refuses, with the whole refusal text pinned: read the
# commit where you verified, never on the build host) and reads its guard call as data (inside the --release branch, after the
# VARIANT refusal, before the OTA stamp guard, PREP and the log tee) and its three --release hints (each line whole, exactly
# once, in its own block).
# Needs git: with no git it FAILS (no skip).
#
#   bash test-verified-commit.sh             # the gates
#   bash test-verified-commit.sh --mutate    # ... plus mutants that must each CONVICT the suite
set -uo pipefail

MUTATE=no; DIR=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; -*) echo "usage: $0 [<build-dir>] [--mutate]" >&2; exit 2 ;; *) DIR="$a" ;; esac; done
DIR="${DIR:-$(cd "$(dirname "$0")" && pwd)}"
BD="$DIR/build-device.sh"; GUARD="$DIR/verified-commit-guard.sh"
[ -f "$BD" ] || { echo "no such file: $BD" >&2; exit 2; }
[ -f "$GUARD" ] || { echo "no such file: $GUARD" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "git is required" >&2; exit 1; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_CEILING_DIRECTORIES="$W"

SHELLS="${VC_TEST_SHELLS:-}"
if [ -z "$SHELLS" ]; then for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done; fi

R="$W/repo"; PLAIN="$W/plain"; mkdir "$R" "$PLAIN"
g() { git -C "$R" "$@"; }
g init -q || exit 2
g config user.name t; g config user.email t@example.invalid; g config commit.gpgsign false
echo one > "$R/tracked-name.txt"; g add tracked-name.txt; g commit -q -m one; P=$(g rev-parse HEAD)
echo two > "$R/tracked-name.txt"; g commit -q -am two; H=$(g rev-parse HEAD)

# run <shell> <repo> <commit...> -> RC, OUT, ERR
run() {
  local s="$1"; shift
  "$s" "$GUARD" "$@" >"$W/o" 2>"$W/e"; RC=$?
  OUT=$(cat "$W/o"); ERR=$(cat "$W/e")
}
reset() { g reset -q --hard "$H"; g clean -qfdx; }
rc() { if [ "$RC" = "$2" ]; then ok "$1"; else no "$1 (rc=$RC, want $2) $ERR"; fi; }

guard_gates() {
  local s
  for s in $SHELLS; do
    reset; run "$s" "$R" "$H"
    if [ "$RC" = 0 ] && [ "$OUT" = "verified commit $H is HEAD, tree clean" ]; then ok "[$s] HEAD full -> 0"; else no "[$s] HEAD full (rc=$RC out='$OUT') $ERR"; fi
    run "$s" "$R" "${H:0:7}"
    if [ "$RC" = 0 ] && [[ "$OUT" == *"$H"* ]]; then ok "[$s] HEAD abbreviated -> 0, full sha named"; else no "[$s] HEAD abbreviated (rc=$RC out='$OUT') $ERR"; fi
    run "$s" "$R" "$P"
    if [ "$RC" = 1 ] && [[ "$ERR" == *"REFUSING --release"* && "$ERR" == *"$H"* ]]; then ok "[$s] parent -> 1 (moved)"; else no "[$s] parent (rc=$RC) $ERR"; fi
    echo changed > "$R/tracked-name.txt"; run "$s" "$R" "$H"
    if [ "$RC" = 1 ] && [[ "$ERR" == *"1 tracked file(s) modified"* && "$ERR" != *tracked-name.txt* ]]; then ok "[$s] modified tracked -> 1, count only"; else no "[$s] modified tracked (rc=$RC) $ERR"; fi
    g add tracked-name.txt; run "$s" "$R" "$H"; rc "[$s] staged change -> 1" 1
    reset; echo x > "$R/stray.txt"; run "$s" "$R" "$H"; rc "[$s] untracked only -> 0" 0
    reset; run "$s" "$R" xyz; rc "[$s] bad text -> 2" 2
    run "$s" "$R" 0000000; rc "[$s] unknown hex -> 2" 2
    run "$s" "$PLAIN" "$H"; rc "[$s] non-repo -> 2" 2
    run "$s" "$R"; rc "[$s] one argument -> 2" 2
  done
}

# build-device.sh argument parse, run by anchor.
ARGS=$(sed -n '/^DEV="\${1:?usage/,/^TREE=/p' "$BD" | sed '$d')
args_run() {
  printf '%s\n' 'set -u' "$ARGS" 'echo "reached rel=$DO_RELEASE v=$VERIFIED"' > "$W/args.sh"
  bash "$W/args.sh" "$@" >"$W/o" 2>"$W/e"; RC=$?
  OUT=$(cat "$W/o"); ERR=$(cat "$W/e")
}
argparse() {
  case "$ARGS" in *DO_RELEASE=*) ;; *) no "argument parse: anchors moved"; return ;; esac
  args_run lynx 2026110401 --release
  if [ "$RC" = 2 ] && [[ "$OUT" != *reached* && "$ERR" == *"[--release <verified-commit>]"* ]]; then ok "--release with no commit -> 2"; else no "--release with no commit (rc=$RC out='$OUT') $ERR"; fi
  # The whole refusal, word for word: a phrase match passes with the old build-host hint put back beside it.
  local want
  want=$(printf '%s\n' \
    'usage: build-device.sh <device> <build-number> [--release <verified-commit>]' \
    '    --release needs the merge commit you verified, read where you did the verifying: your own checkout of main,' \
    "    or the merge commit of the PR you checked -- never from the build host's checkout you are about to sign" \
    '    (its HEAD is what the guard checks, so a commit read there passes the aborted pull it exists to refuse)')
  if [ "$ERR" = "$want" ]; then ok "the refusal says where the commit is read, and never on the build host"; else no "the refusal text: $ERR"; fi
  args_run lynx 2026110401 --release abc1234
  if [ "$RC" = 0 ] && [ "$OUT" = "reached rel=1 v=abc1234" ]; then ok "--release <commit> parsed"; else no "--release <commit> (rc=$RC out='$OUT') $ERR"; fi
  args_run lynx 2026110401
  if [ "$RC" = 0 ] && [ "$OUT" = "reached rel=0 v=" ]; then ok "no --release parsed"; else no "no --release (rc=$RC out='$OUT') $ERR"; fi
}

# build-device.sh wiring, read as data. A missing anchor is a FAIL, never a pass.
num() { [[ "$2" =~ ^[0-9]+$ ]] || { no "$1: anchor not found"; return 1; }; }
first_line() { grep -n "$@" "$BD" | head -1 | cut -d: -f1; }
# once <label> <block> <line>: <line> occurs whole, exactly once, in <block>.
once() {
  local n; n=$(grep -cxF -- "$3" <<<"$2")
  if [ "$n" = 1 ]; then ok "$1 carries --release <verified-commit>"; else no "$1 found $n times"; fi
}
wiring() {
  local anchor='# NWP-20261104-03: --release signs only the commit the operator verified (Q094)'
  local var='if [ "$DO_RELEASE" = 1 ] && [ "$VARIANT" != user ]; then'
  local call='sh "$REPO/editions/endospore/build/verified-commit-guard.sh" "$REPO" "$VERIFIED" || exit $?'
  local l_var l_anc l_call l_ota l_prep l_tee l_if l_fi text n
  n=$(grep -cxF -- "$var" "$BD"); [ "$n" = 1 ] && l_var=$(grep -nxF -- "$var" "$BD" | cut -d: -f1) || { no "control pin: VARIANT refusal line found $n times"; return; }
  n=$(grep -cxF -- "$anchor" "$BD"); [ "$n" = 1 ] && l_anc=$(grep -nxF -- "$anchor" "$BD" | cut -d: -f1) || { no "guard block comment found $n times"; return; }
  if [ "$l_var" -lt "$l_anc" ]; then ok "guard block follows the VARIANT refusal"; else no "guard block precedes the VARIANT refusal"; fi
  l_call=$(grep -n 'verified-commit-guard\.sh' "$BD" | grep -v '^[0-9]*:[[:space:]]*#' | head -1 | cut -d: -f1)
  num "guard call" "$l_call" || return
  text=$(sed -n "${l_call}p" "$BD" | sed 's/^[[:space:]]*//')
  if [ "$text" = "$call" ]; then ok "guard call text"; else no "guard call text: $text"; fi
  l_if=$(head -n "$l_call" "$BD" | grep -n '^if ' | tail -1 | cut -d: -f1)
  num "guard call's enclosing if" "$l_if" || return
  if [ "$(sed -n "${l_if}p" "$BD")" = 'if [ "$DO_RELEASE" = 1 ]; then' ] && [ "$l_if" -gt "$l_anc" ]; then ok "guard call sits inside if DO_RELEASE"; else no "guard call's enclosing if is line $l_if"; fi
  l_fi=$(sed -n "${l_if},${l_call}p" "$BD" | grep -c '^fi')
  if [ "$l_fi" = 0 ]; then ok "no fi between the if and the call"; else no "an fi closes the if before the call"; fi
  l_ota=$(grep -n 'ota-field-guard\.sh' "$BD" | grep -v '^[0-9]*:[[:space:]]*#' | head -1 | cut -d: -f1)
  l_prep=$(first_line -x 'if \[ "\$PREP" = 1 \]; then')
  l_tee=$(first_line '^exec > >(tee')
  num "ota-field-guard call" "$l_ota" && { if [ "$l_call" -lt "$l_ota" ]; then ok "guard before the OTA stamp guard"; else no "guard after the OTA stamp guard"; fi; }
  num "PREP block" "$l_prep" && { if [ "$l_call" -lt "$l_prep" ]; then ok "guard before PREP"; else no "guard after PREP"; fi; }
  num "log tee" "$l_tee" && { if [ "$l_call" -lt "$l_tee" ]; then ok "guard before the log tee"; else no "guard after the log tee"; fi; }
  # Each --release hint whole, exactly once, in its own block: a count over the file is met by the header and the
  # ${1:?usage} lines with no hint updated.
  text=$(sed -n "${l_var},/^fi\$/p" "$BD")
  once "VARIANT-refusal hint" "$text" '  echo "    VARIANT=user OUT_DIR=out-$DEV-user $0 $DEV $BN --release <verified-commit>" >&2'
  text=$(sed -n '/^if \[ "\$DO_RELEASE" -eq 0 \]; then/,/^fi$/p' "$BD")
  once "Sign-with hint" "$text" '    echo "     OUT_DIR=$OUT_DIR VARIANT=user $0 $DEV $BN --release <verified-commit>        # prompts ONCE for the key passphrase"'
  once "user-tree hint" "$text" '    echo "     VARIANT=user OUT_DIR=out-$DEV-user $0 $DEV <next BN> --release <verified-commit>        # prompts ONCE for the key passphrase"'
}

gates() { guard_gates; argparse; wiring; }

if [ "$MUTATE" = yes ]; then
  [ "$PASS" -eq 0 ] || exit 2
  M=$(mktemp -d -p "$W"); GOT=0; BAD=0
  # mut <id> <file> <sed-script>  (guard mutants must be convicted under every shell)
  mut() {
    local id="$1" f="$2" sc="$3" s rc
    cp "$BD" "$M/build-device.sh"; cp "$GUARD" "$M/verified-commit-guard.sh"
    sed -E "$sc" "$DIR/$f" > "$M/$f"
    if cmp -s "$DIR/$f" "$M/$f"; then echo "  FAIL  MUTANT DID NOT APPLY: $id"; BAD=$((BAD+1)); return; fi
    if [ "$f" = build-device.sh ]; then
      VC_TEST_SHELLS=bash bash "$0" "$M" >/dev/null 2>&1; rc=$?
      if [ "$rc" != 0 ]; then echo "  ok    convicted $id"; else echo "  FAIL  NOT CONVICTED $id"; BAD=$((BAD+1)); fi
    else
      for s in $SHELLS; do
        VC_TEST_SHELLS=$s bash "$0" "$M" >/dev/null 2>&1; rc=$?
        if [ "$rc" != 0 ]; then echo "  ok    convicted $id [$s]"; else echo "  FAIL  NOT CONVICTED $id [$s]"; BAD=$((BAD+1)); fi
      done
    fi
  }
  mut G1-untracked-counted verified-commit-guard.sh 's/--untracked-files=no/--untracked-files=normal/'
  mut G2-abbreviated-as-text verified-commit-guard.sh 's/^if \[ "\$FULL" != "\$HEAD" \]; then$/if [ "$C" != "$HEAD" ]; then/'
  mut G3-status-dropped verified-commit-guard.sh 's/^DIRTY=\$\(git -C "\$REPO" status --porcelain --untracked-files=no\)/DIRTY=$(true)/'
  mut B3-variant-hint-bare build-device.sh 's/^(  echo "    VARIANT=user OUT_DIR=out-\$DEV-user \$0 \$DEV \$BN --release) <verified-commit>"/\1"/'
  mut B4-sign-with-hint-bare build-device.sh 's/(\$0 \$DEV \$BN --release) <verified-commit>( +# prompts)/\1\2/'
  mut B5-user-tree-hint-bare build-device.sh 's/(<next BN> --release) <verified-commit>/\1/'
  mut B6-refusal-says-not-where build-device.sh '/never from the build host.s checkout/d'
  mut B7-buildhost-hint-readded build-device.sh '/^  echo "usage: build-device.sh <device> <build-number> \[--release <verified-commit>\]" >&2$/a\  echo "    --release needs the merge commit you verified: git -C <repo> rev-parse HEAD on the verified checkout" >&2'
  mut B8-where-to-read-dropped build-device.sh '/read where you did the verifying: your own checkout of main,/d'
  # B1: call block moved after the PREP block
  cp "$GUARD" "$M/verified-commit-guard.sh"
  awk '
    /^# NWP-20261104-03: --release signs only/ { inanc=1 }
    inanc && /^if \[ "\$DO_RELEASE" = 1 \]; then$/ { cap=1 }
    cap { held = held $0 "\n"; if ($0 == "fi") { cap=0; inanc=0 }; next }
    { print }
    /^if \[ "\$PREP" = 1 \]; then$/ { inprep=1 }
    inprep && /^fi$/ { printf "%s", held; inprep=0 }
  ' "$BD" > "$M/build-device.sh"
  if cmp -s "$BD" "$M/build-device.sh"; then echo "  FAIL  MUTANT DID NOT APPLY: B1"; BAD=$((BAD+1))
  else VC_TEST_SHELLS=bash bash "$0" "$M" >/dev/null 2>&1; if [ $? != 0 ]; then echo "  ok    convicted B1-call-after-PREP"; else echo "  FAIL  NOT CONVICTED B1-call-after-PREP"; BAD=$((BAD+1)); fi; fi
  # B2: the missing-commit refusal removed
  cp "$GUARD" "$M/verified-commit-guard.sh"
  sed '/^if \[ "\$DO_RELEASE" = 1 \] && \[ -z "\$VERIFIED" \]; then/,/^fi/d' "$BD" > "$M/build-device.sh"
  if cmp -s "$BD" "$M/build-device.sh"; then echo "  FAIL  MUTANT DID NOT APPLY: B2"; BAD=$((BAD+1))
  else VC_TEST_SHELLS=bash bash "$0" "$M" >/dev/null 2>&1; if [ $? != 0 ]; then echo "  ok    convicted B2-no-commit-refusal"; else echo "  FAIL  NOT CONVICTED B2-no-commit-refusal"; BAD=$((BAD+1)); fi; fi
  [ "$BAD" = 0 ] && echo "all mutants convicted" || echo "$BAD mutant problem(s)"
  [ "$BAD" = 0 ]; exit $?
fi

gates
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
