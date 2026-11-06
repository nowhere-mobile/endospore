#!/usr/bin/env bash
# test-bn-guard.sh [<build-device.sh>] [--mutate] -- exercise the build-number guard's ARTIFACT CHOICE.
#
# WHY THIS IS COMMITTED. The guard catches a real and expensive defect: a warm OUT_DIR pins BUILD_NUMBER
# from the day it was created, and seven consecutive releases (2026080400..2026081000) all shipped images
# identifying as 2026072800. But it has now CRIED WOLF THREE TIMES -- twice on 2026-08-20/21, once on
# 2026-09-03 -- and every false refusal was textually identical to a true one:
#
#     image baked build number '2026090202', expected '2026090301'
#
# A guard people learn to override is worse than no guard: it still costs the build and no longer buys the
# confidence. The bug was never in the assertion -- it was in WHICH ARTIFACT got asserted on. So that is
# what this pins down.
#
# The block is extracted from build-device.sh BY ANCHOR, never copied. If the anchors move, extraction is
# empty and every case fails loudly -- a test holding a stale copy would keep passing after the real code
# changed, which is the failure mode worth engineering against.
#
#   bash test-bn-guard.sh            # the behaviour cases
#   bash test-bn-guard.sh --mutate   # ... plus 3 mutations that must each CONVICT the suite
#
# Pure logic -- no build, no tree, no network. Runs anywhere bash does.
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/build-device.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf "  ok    %s\n" "$1"; }
no(){ FAIL=$((FAIL+1)); printf "  FAIL  %s\n" "$1"; }
is(){ [ "$2" = "$3" ] && ok "$1" || no "$1 -- got [$2] want [$3]"; }

# --- extraction -------------------------------------------------------------------------------------
START='/^PROPF=""; PROPPART=""/'
END='/^echo "   image os-ref/'
BLOCK=$(sed -n "$START,$END p" "$SUT" | sed '$d')
case "$BLOCK" in
  *bn_from_prop*SRC=*) ;;
  *) echo "EXTRACTION FAILED -- anchors moved in $SUT" >&2; exit 2 ;;
esac

# --- harness ----------------------------------------------------------------------------------------
# Build a fake $PRODOUT (+ optional $TFI), run the extracted block, report what it CHOSE and what it READ.
#   run <tfi-age-secs|-> [<partition>:<age-secs>:<incremental|->]...
# "-" as the incremental writes only a fingerprint, to exercise bn_from_prop's fallback.
run(){
  local T tfi_age spec part rest age inc dir TFIP out
  T=$(mktemp -d); tfi_age=$1; shift
  dir="$T/out/target/product/lynx"
  mkdir -p "$dir/system/etc/nowhere"; echo os-lynx > "$dir/system/etc/nowhere/os-ref"
  for spec in "$@"; do
    part=${spec%%:*}; rest=${spec#*:}; age=${rest%%:*}; inc=${rest#*:}
    mkdir -p "$dir/$part"
    if [ "$inc" = "-" ]; then
      echo "ro.$part.build.fingerprint=google/lynx/lynx:17/CP2A.260605.012/2026090301:userdebug/release-keys" > "$dir/$part/build.prop"
    else
      echo "ro.$part.build.version.incremental=$inc" > "$dir/$part/build.prop"
    fi
    touch -d "@$(( 2000000000 - age ))" "$dir/$part/build.prop"
  done
  TFIP="$dir/obj/PACKAGING/target_files_intermediates/lynx-target_files.zip"
  mkdir -p "$(dirname "$TFIP")"
  if [ "$tfi_age" != "-" ]; then : > "$TFIP"; touch -d "@$(( 2000000000 - tfi_age ))" "$TFIP"; fi
  # Generate the runner as a FILE. Inlining the block into `bash -c` needs nested quoting that breaks on
  # the block's own quotes, and a test nobody can read is a test nobody will fix.
  {
    echo 'fail(){ echo "FAILCALL:$1" >&2; exit 9; }'
    echo 'unzip(){ return 1; }'   # no real zip; the tfi branch reads nothing, which is the assertion
    echo "DEV=lynx"
    echo "FPRE='s/^ro\.vendor\.build\.fingerprint=.*\/\([^:]*\):.*/\1/p'"
    echo "$BLOCK"
    echo 'printf "%s|%s|%s|%s" "$SRC" "$PROPPART" "$IMG_BN" "$IMG_OSREF" > "$RESULT"'
  } > "$T/run.sh"
  # The block PRINTS progress ("asserting against: ...", the STALE warning) on stdout, so the result has
  # to come out of band or every field is polluted by it. Result -> a file; the prose -> field 5, which
  # is what the warning assertions read.
  RESULT="$T/result" TFI="$TFIP" PRODOUT="$dir" bash "$T/run.sh" > "$T/log" 2>&1
  if [ -s "$T/result" ]; then out="$(cat "$T/result")|$(tr '\n' " " < "$T/log")"
  else out="|||\\|$(tr '\n' " " < "$T/log")"; fi   # fail() ran: no result, keep the prose
  rm -rf "$T"; printf "%s" "$out"
}
f(){ printf "%s" "$1" | cut -d"|" -f"$2"; }

echo "== the regression: TARGETS=systemimage (no vendor prop; stale zip from an earlier release) =="
R=$(run 30000 system:0:2026090301)
is "chooses the flat images, not the stale zip" "$(f "$R" 1)" "prodout"
is "names the partition it read"               "$(f "$R" 2)" "system"
is "reads the CORRECT build number"            "$(f "$R" 3)" "2026090301"
is "reads os-ref from the flat tree"           "$(f "$R" 4)" "os-lynx"

echo "== the dangerous direction is still caught: fresh zip, STALE flat images =="
R=$(run 0 vendor:30000:2026090202 system:30000:2026090202)
is "chooses the zip"                           "$(f "$R" 1)" "tfi"
case "$R" in *STALE*) ok "warns the flat images are stale" ;; *) no "no stale warning: $R" ;; esac

echo "== a full image build: every partition present and fresher than the zip =="
R=$(run 30000 vendor:0:2026090301 system:0:2026090301 system_ext:0:2026090301 product:0:2026090301)
is "chooses the flat images"                   "$(f "$R" 1)" "prodout"
is "reads the correct build number"            "$(f "$R" 3)" "2026090301"

echo "== only a zip exists (a release build, no flat images) =="
R=$(run 0)
is "falls back to the zip"                     "$(f "$R" 1)" "tfi"

echo "== neither artifact exists -- unverifiable is NOT the same as correct =="
R=$(run -)
case "$R" in *FAILCALL*) ok "refuses loudly instead of asserting on nothing" ;; *) no "did not refuse: $R" ;; esac

echo "== bn_from_prop falls back to the fingerprint when the explicit key is absent =="
R=$(run 30000 system:0:-)
is "digs the incremental out of the fingerprint" "$(f "$R" 3)" "2026090301"

if [ "$MUTATE" = yes ]; then
  echo; echo "== mutations (each MUST be convicted) =="
  M=$(mktemp -d)
  # A BROKEN mutation that never applied would make the suite exit non-zero and read as "convicted" --
  # a false green in the one place whose whole job is detecting false greens. So prove each mutation
  # actually applied before believing its verdict.
  mutate(){
    if ! sed "$2" "$SUT" > "$M/m.sh" 2>"$M/err"; then
      no "MUTATION BROKEN (sed failed), verdict meaningless: $1 -- $(cat "$M/err")"; return; fi
    if cmp -s "$SUT" "$M/m.sh"; then
      no "MUTATION INERT (matched nothing), verdict meaningless: $1"; return; fi
    if bash "$0" "$M/m.sh" >/dev/null 2>&1; then no "NOT CONVICTED: $1 -- suite passes on broken code"
    else ok "convicted: $1"; fi; }
  mutate "vendor/build.prop hardcoded again (the 2026-09-03 false refusal)" \
    's@^PROPF=""; PROPPART=""@PROPF="$PRODOUT/vendor/build.prop"; PROPPART=vendor@'
  mutate "build number read with the vendor-only regex" \
    's@^  IMG_BN=$(bn_from_prop.*@  IMG_BN=$(sed -n "$FPRE" "$PROPF" 2>/dev/null | head -1)@'
  mutate "no-artifact case stops refusing and asserts on nothing" \
    's@^  fail "no target-files zip.*@  SRC=prodout@'
  rm -rf "$M"
fi

echo; echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
