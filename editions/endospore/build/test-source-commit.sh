#!/usr/bin/env bash
# test-source-commit.sh [<repo>] [--mutate] -- the Endospore image carries the commit it was staged from
# (NWP-20261104-08, Q094 (c) in docs/product-decisions.md).
#
# stage-vendor.sh writes etc/nowhere-source-commit, endospore.mk bakes it to /system/etc/nowhere/source-commit and
# verify-release.sh check 8 reads it back out of the signed artifact (test-verify-release.sh runs that half). Each
# half is silent when wrong: a stage that wrote the wrong commit, or an .mk that stopped copying the file, builds a
# correct-looking image that cannot say where it came from. This suite pins:
#   (a) the block in stage-vendor.sh, extracted BY ANCHOR (exit 2 if the anchor moves) and run under every shell
#       found, against temp repos: clean -> the sha; a modified or staged tracked file -> sha+modified; only
#       untracked files -> the sha; no repo -> unknown; a plain dir inside an unrelated repo -> unknown
#   (b) endospore.mk copies the file, unconditionally, once (control: the os-ref copy line, once)
#   (c) the three files agree on the path
# --mutate runs six broken copies (S1-S6); each must make this suite fail, and a mutant that does not apply is a
# failure.
#
#   bash test-source-commit.sh             # the cases
#   bash test-source-commit.sh --mutate    # ... plus the mutants
# <repo> is the repository root (default: this script's own); --mutate points the suite at scratch copies holding
# the three files. Pure logic -- no build, no tree, no network.
set -uo pipefail

MUTATE=no; REPO=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) REPO="$a" ;; esac; done
REPO="${REPO:-$(cd "$(dirname "$0")/../../.." && pwd)}"
SV=editions/endospore/build/stage-vendor.sh
MK=editions/endospore/endospore.mk
VR=editions/endospore/build/verify-release.sh
for f in "$SV" "$MK" "$VR"; do [ -f "$REPO/$f" ] || { echo "no such file: $REPO/$f" >&2; exit 2; }; done
command -v git >/dev/null 2>&1 || { echo "test-source-commit.sh needs git" >&2; exit 2; }

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_CEILING_DIRECTORIES="$W"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
is(){ [ "$2" = "$3" ] && ok "$1" || no "$1 -- got [$2] want [$3]"; }

# --- (a) the block, run ------------------------------------------------------------------------------
BLOCK="$W/block.sh"
sed -n '/^# >>> source commit (NWP-20261104-08)$/,/^# <<< source commit$/p' "$REPO/$SV" > "$BLOCK"
if ! grep -q '^# <<< source commit$' "$BLOCK" || ! grep -q 'SRC_COMMIT=' "$BLOCK"; then
  echo "EXTRACTION FAILED: the source-commit block is not in $SV (an anchor moved?)" >&2
  exit 2
fi

SHELLS=""
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "no shell found" >&2; exit 2; }

# mkrepo <dir> : a repo with one tracked file and one commit; sets H.
mkrepo(){
  local d="$1"
  mkdir -p "$d" && git -C "$d" init -q \
    && git -C "$d" config user.name t && git -C "$d" config user.email t@example.invalid \
    && git -C "$d" config commit.gpgsign false \
    && printf 'one\n' > "$d/tracked" && git -C "$d" add tracked && git -C "$d" commit -q -m one \
    || { echo "git setup failed in $d" >&2; exit 2; }
  H=$(git -C "$d" rev-parse HEAD)
}

# runblock <shell> <repo-dir> -> RC, LOG, FILE (the staged file's content)
runblock(){
  local sh="$1" repo="$2" dest pre="set -eu"
  dest=$(mktemp -d -p "$W") || exit 2
  mkdir -p "$dest/etc"
  [ "$sh" = bash ] && pre="set -euo pipefail"
  { echo "$pre"; echo "REPO='$repo'"; echo "DEST='$dest'"; cat "$BLOCK"; } > "$dest/run.sh"
  LOG=$("$sh" "$dest/run.sh" 2>&1); RC=$?
  FILE=$(cat "$dest/etc/nowhere-source-commit" 2>/dev/null; echo x); FILE=${FILE%x}
}

# expect <label> <want> : rc 0, the file exactly "<want>\n", and the log line.
expect(){
  is "$1: rc" "$RC" 0
  is "$1: the file is exactly one line" "$FILE" "$2
"
  case "$LOG" in *"[stage-vendor] source commit $2"*) ok "$1: logged" ;; *) no "$1: log line missing in: $LOG" ;; esac
}

run_cases(){
  local sh n=0 r
  for sh in $SHELLS; do
    n=$((n+1)); r="$W/c$n"
    mkrepo "$r/clean"; runblock "$sh" "$r/clean"; expect "$sh clean" "$H"
    mkrepo "$r/mod"; printf 'two\n' > "$r/mod/tracked"; runblock "$sh" "$r/mod"; expect "$sh modified tracked" "$H+modified"
    mkrepo "$r/staged"; printf 'two\n' > "$r/staged/tracked"; git -C "$r/staged" add tracked
    runblock "$sh" "$r/staged"; expect "$sh staged only" "$H+modified"
    mkrepo "$r/untracked"; printf 'x\n' > "$r/untracked/stray"; runblock "$sh" "$r/untracked"; expect "$sh untracked only" "$H"
    mkdir -p "$r/norepo"; runblock "$sh" "$r/norepo"; expect "$sh no repo" "unknown"
    mkrepo "$r/outer"; mkdir -p "$r/outer/sub"; runblock "$sh" "$r/outer/sub"; expect "$sh subdir of another repo" "unknown"
  done
}

# --- (b) (c) the pins, read as data -------------------------------------------------------------------
count(){ local n; n=$(grep -cxF -- "$1" "$2"); echo "$n"; }
run_pins(){
  local mk="$REPO/$MK" line osline n
  line='    vendor/endospore/etc/nowhere-source-commit:$(TARGET_COPY_OUT_SYSTEM)/etc/nowhere/source-commit'
  osline='    vendor/endospore/etc/os-ref-$(TARGET_PRODUCT):$(TARGET_COPY_OUT_SYSTEM)/etc/nowhere/os-ref'
  is "endospore.mk: the os-ref copy line, once (control)" "$(count "$osline" "$mk")" 1
  is "endospore.mk: the source-commit copy line, once" "$(count "$line" "$mk")" 1
  n=$(grep -F 'nowhere-source-commit' "$mk" | grep -c 'wildcard')
  is "endospore.mk: the copy is unconditional" "$n" 0
  n=$(grep -cF '"$DEST/etc/nowhere-source-commit"' "$BLOCK")
  [ "$n" -ge 1 ] && ok "stage-vendor.sh writes etc/nowhere-source-commit" || no "stage-vendor.sh does not write etc/nowhere-source-commit"
  n=$(grep -cF 'SYSTEM/etc/nowhere/source-commit' "$REPO/$VR")
  [ "$n" -ge 1 ] && ok "verify-release.sh reads SYSTEM/etc/nowhere/source-commit" || no "verify-release.sh does not read SYSTEM/etc/nowhere/source-commit"
}

if [ "$MUTATE" = no ]; then
  echo "== shells:$SHELLS =="
  run_cases; run_pins
  echo
  echo "passed $PASS, failed $FAIL"
  [ "$FAIL" = 0 ]
  exit
fi

# --- mutants --------------------------------------------------------------------------------------------
MPASS=0; MFAIL=0
# mutate <label> <file> <sed-expr> : a scratch repo with the three files, one edited; the suite must exit 1.
mutate(){
  local label="$1" file="$2" expr="$3" d f rc
  d=$(mktemp -d -p "$W") || exit 2
  for f in "$SV" "$MK" "$VR"; do mkdir -p "$d/$(dirname "$f")"; cp "$REPO/$f" "$d/$f"; done
  sed -i "$expr" "$d/$file"
  if cmp -s "$d/$file" "$REPO/$file"; then
    MFAIL=$((MFAIL+1)); echo "  FAIL  $label: the mutant did not apply"; return
  fi
  TMPDIR="$W" bash "$0" "$d" >/dev/null 2>&1; rc=$?
  if [ "$rc" = 1 ]; then MPASS=$((MPASS+1)); echo "  ok    $label: convicted"
  else MFAIL=$((MFAIL+1)); echo "  FAIL  $label: suite exited $rc, want 1"; fi
}

echo "== shells:$SHELLS =="
echo "== the cases =="
run_cases; run_pins
echo "== the mutants =="
mutate "S1 untracked counted as modified" "$SV" 's/--untracked-files=no/--untracked-files=all/'
mutate "S2 modified not marked" "$SV" 's/SRC_COMMIT="\$SRC_HEAD+modified"/SRC_COMMIT="$SRC_HEAD"/'
mutate "S3 checkout-root guard dropped" "$SV" 's/^if \[ "\$(git -C "\$REPO" rev-parse --show-toplevel .*= "\$(cd "\$REPO" \&\& pwd -P)" \]/if true/'
mutate "S4 copy line removed from endospore.mk" "$MK" '/^    vendor\/endospore\/etc\/nowhere-source-commit:/d'
mutate "S5 copy line made conditional" "$MK" 's#^    \(vendor/endospore/etc/nowhere-source-commit:.*\)$#    $(if $(wildcard vendor/endospore/etc/nowhere-source-commit),\1)#'
mutate "S6 block writes another filename" "$SV" 's#"\$DEST/etc/nowhere-source-commit"#"$DEST/etc/source-commit"#'

echo
echo "cases: passed $PASS, failed $FAIL; mutants: convicted $MPASS, failed $MFAIL"
[ "$FAIL" = 0 ] && [ "$MFAIL" = 0 ]
