#!/usr/bin/env bash
# test-support-end-stage.sh [<repo>] [--mutate] -- staging bakes each device's support-end under its own name
# (NWP-20261125-04, h55 #2 in docs/product-decisions.md).
#
# stage-vendor.sh stages editions/endospore/devices/<dev>/support-end as etc/support-end-<dev> for every device that
# has one, and leaves no shared etc/support-end; endospore.mk copies this device's, picked by TARGET_PRODUCT and only
# when it exists, to /system/etc/nowhere/support-end, where the gate and Profile read it. Each half is silent when
# wrong: a shared copy is last-writer-wins across two concurrent stages (the os-ref bug, #627), and an empty
# TARGET_DEVICE resolves to `support-end-`, which the $(wildcard) then quietly drops. This suite pins:
#   (a) the block in stage-vendor.sh, extracted BY ANCHOR (exit 2 if the anchor moves) and run under every shell
#       found, against a fixture repo of three devices (two with a file, one without) and a decoy shared copy:
#       two support-end-<dev> files byte-identical and mode 0644, none for the third, no etc/support-end
#   (b) endospore.mk's copy line, once, with TARGET_PRODUCT and $(wildcard), and no TARGET_DEVICE on a support-end
#       line (control: the os-ref copy line, once)
# --mutate runs three broken copies (M1-M3); each must make this suite fail, and a mutant that does not apply is a
# failure.
#
#   bash test-support-end-stage.sh             # the cases
#   bash test-support-end-stage.sh --mutate    # ... plus the mutants
# <repo> is the repository root (default: this script's own); --mutate points the suite at scratch copies holding
# the two files. Pure logic -- no build, no tree, no network.
set -uo pipefail

MUTATE=no; REPO=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) REPO="$a" ;; esac; done
REPO="${REPO:-$(cd "$(dirname "$0")/../../.." && pwd)}"
SV=editions/endospore/build/stage-vendor.sh
MK=editions/endospore/endospore.mk
for f in "$SV" "$MK"; do [ -f "$REPO/$f" ] || { echo "no such file: $REPO/$f" >&2; exit 2; }; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
is(){ [ "$2" = "$3" ] && ok "$1" || no "$1 -- got [$2] want [$3]"; }

# --- (a) the block, run ------------------------------------------------------------------------------
BLOCK="$W/block.sh"
sed -n '/^# >>> support-end (NWP-20261125-04)$/,/^# <<< support-end$/p' "$REPO/$SV" > "$BLOCK"
if ! grep -q '^# >>> support-end (NWP-20261125-04)$' "$BLOCK" || ! grep -q '^# <<< support-end$' "$BLOCK"; then
  echo "EXTRACTION FAILED: the support-end block is not in $SV (an anchor moved?)" >&2
  exit 2
fi

SHELLS=""
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "no shell found" >&2; exit 2; }

# The fixture repo: alpha and bravo carry a support-end, charlie does not.
FIX="$W/repo"
mkdir -p "$FIX/editions/endospore/devices/alpha" "$FIX/editions/endospore/devices/bravo" \
  "$FIX/editions/endospore/devices/charlie/vendor/etc" || exit 2
printf '# alpha\nlast-supported 2028-05\nsource https://example.invalid/alpha\n' \
  > "$FIX/editions/endospore/devices/alpha/support-end"
printf '# bravo\n\nlast-supported 2030-10-31\nsource https://example.invalid/bravo\n' \
  > "$FIX/editions/endospore/devices/bravo/support-end"
printf 'os-charlie\n' > "$FIX/editions/endospore/devices/charlie/vendor/etc/os-ref"

# runblock <shell> -> RC, LOG, D (the DEST it staged into)
runblock(){
  local sh="$1" pre="set -eu"
  D=$(mktemp -d -p "$W") || exit 2
  mkdir -p "$D/etc"
  printf 'decoy\n' > "$D/etc/support-end"
  [ "$sh" = bash ] && pre="set -euo pipefail"
  { echo "$pre"; echo "REPO='$FIX'"; echo "DEST='$D'"; cat "$BLOCK"; } > "$W/run-$sh.sh"
  LOG=$("$sh" "$W/run-$sh.sh" 2>&1); RC=$?
}

run_cases(){
  local sh dev mode
  for sh in $SHELLS; do
    runblock "$sh"
    is "$sh: rc" "$RC" 0
    for dev in alpha bravo; do
      if cmp -s "$FIX/editions/endospore/devices/$dev/support-end" "$D/etc/support-end-$dev"; then
        ok "$sh: etc/support-end-$dev staged byte-identical"
      else
        no "$sh: etc/support-end-$dev missing or different"
      fi
      mode=$(stat -c %a "$D/etc/support-end-$dev" 2>/dev/null || echo none)
      is "$sh: etc/support-end-$dev mode" "$mode" 644
    done
    [ -e "$D/etc/support-end-charlie" ] && no "$sh: a device without the file staged one" \
      || ok "$sh: no etc/support-end-charlie for the device without the file"
    [ -e "$D/etc/support-end" ] && no "$sh: a shared etc/support-end is left" || ok "$sh: no shared etc/support-end"
    case "$LOG" in *"staged 2 per-device support-end file(s)"*) ok "$sh: logged 2" ;; *) no "$sh: log line missing in: $LOG" ;; esac
  done
}

# --- (b) the mk pin, read as data ---------------------------------------------------------------------
count(){ local n; n=$(grep -cxF -- "$1" "$2"); echo "$n"; }
run_pins(){
  local mk="$REPO/$MK" line osline n
  line='    $(if $(wildcard vendor/endospore/etc/support-end-$(TARGET_PRODUCT)),vendor/endospore/etc/support-end-$(TARGET_PRODUCT):$(TARGET_COPY_OUT_SYSTEM)/etc/nowhere/support-end)'
  osline='    vendor/endospore/etc/os-ref-$(TARGET_PRODUCT):$(TARGET_COPY_OUT_SYSTEM)/etc/nowhere/os-ref'
  is "endospore.mk: the os-ref copy line, once (control)" "$(count "$osline" "$mk")" 1
  is "endospore.mk: the support-end copy line (TARGET_PRODUCT, \$(wildcard)), once" "$(count "$line" "$mk")" 1
  n=$(grep -F 'support-end' "$mk" | grep -c 'TARGET_DEVICE')
  is "endospore.mk: no support-end line names TARGET_DEVICE" "$n" 0
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
# mutate <label> <file> <sed-expr> : a scratch repo with the two files, one edited; the suite must exit 1.
mutate(){
  local label="$1" file="$2" expr="$3" d f rc
  d=$(mktemp -d -p "$W") || exit 2
  for f in "$SV" "$MK"; do mkdir -p "$d/$(dirname "$f")"; cp "$REPO/$f" "$d/$f"; done
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
mutate "M1 the loop removed" "$SV" '/^# >>> support-end (NWP-20261125-04)$/,/^# <<< support-end$/{/^for d in /,/^done$/d}'
mutate "M2 the shared copy written" "$SV" 's#"\$DEST/etc/support-end-\$dev"#"$DEST/etc/support-end"#; /^rm -f "\$DEST\/etc\/support-end"$/d'
mutate "M3 TARGET_DEVICE in the mk line" "$MK" 's/support-end-\$(TARGET_PRODUCT)/support-end-$(TARGET_DEVICE)/g'

echo
echo "cases: passed $PASS, failed $FAIL; mutants: convicted $MPASS, failed $MFAIL"
[ "$FAIL" = 0 ] && [ "$MFAIL" = 0 ]
