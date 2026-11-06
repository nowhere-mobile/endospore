#!/usr/bin/env bash
# test-verify-release.sh [--mutate] -- verify-release.sh run WHOLE against a fixture release (NWP-20261026-23).
#
# verify-release.sh is the gate docs/release-runbook.md §3 sends every release through, and every one of its
# checks is silent when wrong. test-release-variant.sh executes only check 1b and the DEVICES default; this suite
# runs the real script, every check, against a fake build tree holding a signed-looking target_files.zip and the
# four shipping artifacts, and asserts the exit code AND the specific FAIL line of each deviation:
#   v0  the good fixture passes, one ok per check
#   v1  incremental != BN                  v2  ro.build.date.utc off by one
#   v3  os-ref names another device        v4  os-ref only at SYSTEM/etc/os-ref (the 2026-09-05 mistake)
#   v5  baked marker missing               v6  baked marker != the repo's (must not claim a refusal)
#   v7  repo has no notes for the marker   v8  baked notes differ from, or absent from, the artifact
#   v9  each of the three wakelock rules missing, one at a time
#   v10 the policy control (sysfs_typec) missing
#   v11 each of the four artifacts missing, and one empty
#   v12 no signed target_files for one device, and the next device is still checked
#   v13 the source commit (check 8): absent, empty, +modified, unknown, abbreviated or uppercase, a mismatch with
#       NOWHERE_VERIFIED_COMMIT, and a match
#   v14 the screen reader's signing (check 9): re-signed with our key, absent from the table, and no table at all
# --mutate edits a copy of the script (thirteen mutants) and requires this suite to fail on each; a mutant that does
# not apply is a failure.
#
#   bash test-verify-release.sh            # the cases
#   bash test-verify-release.sh --mutate   # ... plus the mutants
set -uo pipefail

MUTATE=no; SCRIPT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mutate) MUTATE=yes ;;
    --script) SCRIPT="${2:?--script needs a path}"; shift ;;
    *) echo "usage: $0 [--mutate]" >&2; exit 2 ;;
  esac
  shift
done
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${SCRIPT:-$HERE/verify-release.sh}"
[ -f "$SCRIPT" ] || { echo "no such script: $SCRIPT" >&2; exit 2; }
for t in zip unzip; do
  command -v "$t" >/dev/null 2>&1 || { echo "test-verify-release.sh needs $t, which is not installed" >&2; exit 2; }
done
[ "$(date -u -d 2000-01-01 +%s 2>/dev/null)" = 946684800 ] \
  || { echo "test-verify-release.sh needs GNU date (date -u -d)" >&2; exit 2; }

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
is(){ [ "$2" = "$3" ] && ok "$1" || no "$1 -- got [$2] want [$3]"; }
has(){ case "$2" in *"$3"*) ok "$1" ;; *) no "$1 -- [$3] not in: $2" ;; esac; }
hasnt(){ case "$2" in *"$3"*) no "$1 -- [$3] present in: $2" ;; *) ok "$1" ;; esac; }

BN=2026101902
STAMP=0.9.9
NOTES="what is new in this version"
WANT_UTC=$(( $(date -u -d 2026-10-19 +%s) + 2 ))
SRC=0123456789abcdef0123456789abcdef01234567
OTHER=89abcdef0123456789abcdef0123456789abcdef

# mkroot <dir> <dev>... : the repo layout the script finds from its own path, with the script under test copied in.
mkroot(){
  local r="$1" d; shift
  mkdir -p "$r/editions/endospore/build" "$r/core/vendor-common/etc/ota-notes" "$r/tree"
  cp "$SCRIPT" "$r/editions/endospore/build/verify-release.sh"
  for d in "$@"; do mkdir -p "$r/editions/endospore/devices/$d"; done
  printf '%s\n' "$STAMP" > "$r/core/vendor-common/etc/nowhere-ota-version"
  printf '%s\n' "$NOTES" > "$r/core/vendor-common/etc/ota-notes/$STAMP"
}

# mkstage <stage-dir> <dev> : the files of a good signed target_files.zip.
mkstage(){
  local s="$1" dev="$2"
  mkdir -p "$s/SYSTEM/etc/nowhere" "$s/SYSTEM_EXT/etc/selinux" "$s/META"
  { echo 'name="AppStore.apk" certificate="PRESIGNED" private_key="" partition="system"'
    echo 'name="talkback.apk" certificate="PRESIGNED" private_key="" partition="product"'
    echo 'name="NowhereChooser.apk" certificate="build/make/target/product/security/platform.x509.pem" private_key="build/make/target/product/security/platform.pk8" partition="system"'
  } > "$s/META/apkcerts.txt"
  printf 'ro.build.tags=release-keys\nro.system.build.type=user\nro.build.version.incremental=%s\nro.build.date.utc=%s\n' \
    "$BN" "$WANT_UTC" > "$s/SYSTEM/build.prop"
  printf '%s\n' "$STAMP" > "$s/SYSTEM/etc/nowhere-ota-version"
  printf '%s\n' "$NOTES" > "$s/SYSTEM/etc/nowhere-ota-notes"
  printf 'os-%s\n' "$dev" > "$s/SYSTEM/etc/nowhere/os-ref"
  printf '%s\n' "$SRC" > "$s/SYSTEM/etc/nowhere/source-commit"
  { echo '(allow endospore_priv sysfs_wake_lock (file (read write)))'
    echo '(allow endospore_priv self (capability2 (block_suspend)))'
    echo '(allow endospore_priv sysfs_suspend_stats (file (read)))'
    echo '(allow endospore_priv sysfs_typec (dir (search)))'
  } > "$s/SYSTEM_EXT/etc/selinux/system_ext_sepolicy.cil"
}

# pack <root> <dev> : zip the device's stage as the signed artifact and write the four shipping files.
pack(){
  local r="$1" dev="$2" rel f
  rel="$r/tree/releases/$BN/release-$dev-$BN"
  mkdir -p "$rel"
  rm -f "${rel:?}/${dev:?}-target_files.zip"
  ( cd "$r/stage/$dev" && zip -qr "$rel/$dev-target_files.zip" . ) || { echo "zip failed" >&2; exit 2; }
  for f in "$dev-factory-$BN.zip" "$dev-webfactory-$BN.zip" "$dev-ota_update-$BN.zip" "$dev-manifest-$BN.json"; do
    [ -e "$rel/$f" ] || printf 'payload\n' > "$rel/$f"
  done
}

# fixture <name> <dev>... : a good release for each device; sets R (the root). Stages live in $R/stage/<dev>.
fixture(){
  local name="$1" d; shift
  R="$W/$name"; mkroot "$R" "$@"
  for d in "$@"; do mkstage "$R/stage/$d" "$d"; pack "$R" "$d"; done
}

# runvr <root> [dev...] -> OUT, RC. NOWHERE_VERIFIED_COMMIT is unset so a CI environment cannot leak into a case.
runvr(){
  local r="$1"; shift
  OUT=$(env -u NOWHERE_VERIFIED_COMMIT TREE="$r/tree" bash "$r/editions/endospore/build/verify-release.sh" "$BN" "$@" 2>&1); RC=$?
}
# runvr_vc <root> <commit> [dev...] : the same with NOWHERE_VERIFIED_COMMIT=<commit>.
runvr_vc(){
  local r="$1" vc="$2"; shift 2
  OUT=$(NOWHERE_VERIFIED_COMMIT="$vc" TREE="$r/tree" bash "$r/editions/endospore/build/verify-release.sh" "$BN" "$@" 2>&1); RC=$?
}
failcount(){ printf '%s\n' "$OUT" | grep -c '^    FAIL'; }

# expect_fail <label> <fragment> : exit 1, a FAIL line carrying the fragment, and no other FAIL.
expect_fail(){
  local line
  is "$1: exit code" "$RC" 1
  line=$(printf '%s\n' "$OUT" | grep '^    FAIL' | grep -F -- "$2")
  if [ -n "$line" ]; then ok "$1: FAIL line [$2]"; else no "$1: no FAIL line with [$2] in: $OUT"; fi
  is "$1: exactly one FAIL" "$(failcount)" 1
}

# strip_cil <root> <pattern> : drop the policy lines matching the pattern from d1's stage, and re-pack.
strip_cil(){
  local f="$1/stage/d1/SYSTEM_EXT/etc/selinux/system_ext_sepolicy.cil"
  grep -v "$2" "$f" > "$1/cil.new"
  mv "$1/cil.new" "$f"
  pack "$1" d1
}

run_cases(){
  local rule f n rel

  # v0 the good fixture
  fixture v0 d1; runvr "$R" d1
  is "v0: exit code" "$RC" 0
  has "v0: failed 0" "$OUT" "failed 0"
  is "v0: one ok per check" "$(printf '%s\n' "$OUT" | grep -c '^    ok ')" 17
  has "v0: the source commit is printed" "$OUT" "ok    source commit = $SRC"
  has "v0: says the commit was not compared" "$OUT" "note  NOWHERE_VERIFIED_COMMIT unset"
  hasnt "v0: no FAIL" "$OUT" "FAIL"

  # v1 check 3
  fixture v1 d1
  sed -i "s/^ro.build.version.incremental=.*/ro.build.version.incremental=2026101901/" "$R/stage/d1/SYSTEM/build.prop"
  pack "$R" d1; runvr "$R" d1
  expect_fail "v1 incremental" "incremental=2026101901, want $BN"

  # v2 check 4
  fixture v2 d1
  sed -i "s/^ro.build.date.utc=.*/ro.build.date.utc=$((WANT_UTC - 1))/" "$R/stage/d1/SYSTEM/build.prop"
  pack "$R" d1; runvr "$R" d1
  expect_fail "v2 date.utc" "ro.build.date.utc=$((WANT_UTC - 1)), want $WANT_UTC"

  # v3 check 5, another device's feed
  fixture v3 d1
  printf 'os-other\n' > "$R/stage/d1/SYSTEM/etc/nowhere/os-ref"
  pack "$R" d1; runvr "$R" d1
  expect_fail "v3 os-ref" "os-ref=os-other, want os-d1"

  # v4 check 5, the right value in the wrong place
  fixture v4 d1
  mv "$R/stage/d1/SYSTEM/etc/nowhere/os-ref" "$R/stage/d1/SYSTEM/etc/os-ref"
  pack "$R" d1; runvr "$R" d1
  expect_fail "v4 os-ref at SYSTEM/etc/os-ref" "os-ref=, want os-d1"

  # v5 no baked marker (the notes check then has no stamp to look up, so it fails too)
  fixture v5 d1
  rm -f "${R:?}/stage/d1/SYSTEM/etc/nowhere-ota-version"
  pack "$R" d1; runvr "$R" d1
  is "v5: exit code" "$RC" 1
  has "v5: FAIL no baked marker" "$OUT" "FAIL  no SYSTEM/etc/nowhere-ota-version in the artifact"

  # v6 baked marker differs from the repo's
  fixture v6 d1
  printf '0.9.8\n' > "$R/stage/d1/SYSTEM/etc/nowhere-ota-version"
  printf '%s\n' "$NOTES" > "$R/core/vendor-common/etc/ota-notes/0.9.8"
  pack "$R" d1; runvr "$R" d1
  expect_fail "v6 marker != repo" "baked 0.9.8 but the repo says $STAMP"
  has "v6: says the publish only notes it" "$OUT" "only notes this"
  hasnt "v6: does not claim a refusal" "$OUT" "will refuse"

  # v7 the repo has no notes for the marker
  fixture v7 d1
  rm -f "${R:?}/core/vendor-common/etc/ota-notes/$STAMP"
  runvr "$R" d1
  expect_fail "v7 repo notes missing" "no OTA notes in the repo for $STAMP"

  # v8 baked notes differ, or are absent
  fixture v8 d1
  printf 'something else\n' > "$R/stage/d1/SYSTEM/etc/nowhere-ota-notes"
  pack "$R" d1; runvr "$R" d1
  expect_fail "v8 notes differ" "SYSTEM/etc/nowhere-ota-notes is missing or differs"
  fixture v8b d1
  rm -f "${R:?}/stage/d1/SYSTEM/etc/nowhere-ota-notes"
  pack "$R" d1; runvr "$R" d1
  expect_fail "v8b notes absent" "SYSTEM/etc/nowhere-ota-notes is missing or differs"

  # v9 each wakelock rule missing in turn
  for rule in sysfs_wake_lock block_suspend sysfs_suspend_stats; do
    fixture "v9-$rule" d1
    strip_cil "$R" "$rule"; runvr "$R" d1
    expect_fail "v9 $rule missing" "policy is MISSING the OTA wakelock grant"
  done

  # v10 the control
  fixture v10 d1
  strip_cil "$R" sysfs_typec; runvr "$R" d1
  expect_fail "v10 control missing" "control FAILED"

  # v11 the shipping set
  for f in factory webfactory ota_update manifest; do
    fixture "v11-$f" d1
    rel="$R/tree/releases/$BN/release-d1-$BN"
    case "$f" in manifest) f="manifest-$BN.json" ;; *) f="$f-$BN.zip" ;; esac
    rm -f "${rel:?}/d1-$f"; runvr "$R" d1
    expect_fail "v11 $f missing" "missing or empty: d1-$f"
  done
  fixture v11-empty d1
  : > "$R/tree/releases/$BN/release-d1-$BN/d1-webfactory-$BN.zip"; runvr "$R" d1
  expect_fail "v11 empty webfactory" "missing or empty: d1-webfactory-$BN.zip"

  # v12 no signed artifact for the first device; the second is still checked (default list = both device dirs)
  fixture v12 d1 d2
  rm -f "${R:?}/tree/releases/$BN/release-d1-$BN/d1-target_files.zip"
  runvr "$R"
  is "v12: exit code" "$RC" 1
  has "v12: FAIL for d1" "$OUT" "FAIL  d1: no SIGNED target_files"
  has "v12: d2 is still checked" "$OUT" "== d2 =="
  n=$(printf '%s\n' "$OUT" | grep -c '^    ok ')
  is "v12: d2's 17 checks ran" "$n" 17
  is "v12: only d1 failed" "$(failcount)" 1

  # v13 check 8, the source commit
  fixture v13a d1
  rm -f "${R:?}/stage/d1/SYSTEM/etc/nowhere/source-commit"
  pack "$R" d1; runvr "$R" d1
  expect_fail "v13a absent" "no SYSTEM/etc/nowhere/source-commit in the artifact"
  fixture v13b d1
  : > "$R/stage/d1/SYSTEM/etc/nowhere/source-commit"
  pack "$R" d1; runvr "$R" d1
  expect_fail "v13b empty" "SYSTEM/etc/nowhere/source-commit is empty"
  fixture v13c d1
  printf '%s+modified\n' "$SRC" > "$R/stage/d1/SYSTEM/etc/nowhere/source-commit"
  pack "$R" d1; runvr "$R" d1
  expect_fail "v13c +modified" "source commit $SRC+modified"
  runvr_vc "$R" "$SRC" d1
  expect_fail "v13c +modified, even with the verified commit set" "source commit $SRC+modified"
  fixture v13d d1
  printf 'unknown\n' > "$R/stage/d1/SYSTEM/etc/nowhere/source-commit"
  pack "$R" d1; runvr "$R" d1
  expect_fail "v13d unknown" "source commit is 'unknown'"
  fixture v13e d1
  printf '%s\n' "${SRC:0:7}" > "$R/stage/d1/SYSTEM/etc/nowhere/source-commit"
  pack "$R" d1; runvr "$R" d1
  expect_fail "v13e abbreviated" "is not a 40-character lowercase hex commit"
  fixture v13e2 d1
  printf '%s\n' "$(printf '%s' "$SRC" | tr a-f A-F)" > "$R/stage/d1/SYSTEM/etc/nowhere/source-commit"
  pack "$R" d1; runvr "$R" d1
  expect_fail "v13e2 uppercase" "is not a 40-character lowercase hex commit"
  fixture v13f d1
  runvr_vc "$R" "$OTHER" d1
  expect_fail "v13f mismatch" "source commit $SRC != NOWHERE_VERIFIED_COMMIT $OTHER"
  fixture v13g d1
  runvr_vc "$R" "$SRC" d1
  is "v13g: exit code" "$RC" 0
  has "v13g: matches" "$OUT" "ok    source commit = NOWHERE_VERIFIED_COMMIT"
  hasnt "v13g: no note" "$OUT" "note  "
  is "v13g: one ok per check" "$(printf '%s\n' "$OUT" | grep -c '^    ok ')" 18

  # v14 check 9, the screen reader's signing
  fixture v14a d1
  sed -i 's|^name="talkback.apk" certificate="PRESIGNED" private_key=""|name="talkback.apk" certificate="releasekey.x509.pem" private_key="releasekey.pk8"|' "$R/stage/d1/META/apkcerts.txt"
  pack "$R" d1; runvr "$R" d1
  expect_fail "v14a re-signed with our key" "talkback.apk is not PRESIGNED"
  fixture v14b d1
  sed -i '/name="talkback.apk"/d' "$R/stage/d1/META/apkcerts.txt"
  pack "$R" d1; runvr "$R" d1
  expect_fail "v14b absent from the table" "talkback.apk is not PRESIGNED"
  fixture v14c d1
  rm -f "${R:?}/stage/d1/META/apkcerts.txt"
  pack "$R" d1; runvr "$R" d1
  is "v14c: exit code" "$RC" 1
  has "v14c: the control fails" "$OUT" "FAIL  control FAILED -- no META/apkcerts.txt entries"
  has "v14c: and so does the check" "$OUT" "FAIL  talkback.apk is not PRESIGNED"
  is "v14c: exactly two FAILs" "$(failcount)" 2
}

if [ "$MUTATE" = no ]; then
  run_cases
  echo
  echo "passed $PASS, failed $FAIL"
  [ "$FAIL" = 0 ]
  exit
fi

# --- mutants -----------------------------------------------------------------------------------------
# mutate <label> <sed-expr> : the real script with one edit, which must apply and must make the suite fail.
MPASS=0; MFAIL=0
mutate(){
  local label="$1" expr="$2" m rc
  m="$W/mut-${label%% *}.sh"
  sed "$expr" "$SCRIPT" > "$m"
  if cmp -s "$m" "$SCRIPT"; then
    MFAIL=$((MFAIL+1)); echo "  FAIL  $label: the mutant did not apply"; return
  fi
  TMPDIR="$W" bash "$0" --script "$m" >/dev/null 2>&1; rc=$?
  if [ "$rc" = 1 ]; then
    MPASS=$((MPASS+1)); echo "  ok    $label: convicted"
  else
    MFAIL=$((MFAIL+1)); echo "  FAIL  $label: suite exited $rc, want 1"
  fi
}

echo "== the cases =="
run_cases
echo "== the mutants =="
mutate "M1 check 3 always ok" 's/\[ "\$inc" = "\$BN" \]/true/'
mutate "M2 WANT_UTC drops the NN" 's/ + 10#\$BN_NN//'
mutate "M3 os-ref read from SYSTEM/etc/os-ref" 's#SYSTEM/etc/nowhere/os-ref#SYSTEM/etc/os-ref#'
mutate "M4 wakelock tests reduced to one rule" 's/ && \[ "\$bs" -ge 1 \] && \[ "\$ss" -ge 1 \]//'
mutate "M5 control check always passes" "s/sysfs_typec')\" -ge 1 \\]/sysfs_typec')\" -ge 0 ]/"
mutate "M6 check 7 -s becomes -e" 's/\[ -s "\$REL\/\$f" \]/[ -e "$REL\/$f" ]/'
mutate "M7 notes cmp removed" 's/| cmp -s - "\$notes_src"/| true/'
mutate "M9 the 40-hex check accepts +modified" 's/\^\[0-9a-f\]{40}\$/^[0-9a-f]{40}/'
mutate "M10 the equality check skipped" 's/\[ "\$src" = "\$NOWHERE_VERIFIED_COMMIT" \]/true/'
mutate "M11 source commit read from the wrong path" 's#SYSTEM/etc/nowhere/source-commit#SYSTEM/etc/nowhere-source-commit#g'
mutate "M12 check 9 always ok" 's/| grep -cF '"'"'certificate="PRESIGNED"'"'"' >\/dev\/null; then/| true; then/'
mutate "M13 check 9 control always ok" 's/\[ "\$nc" -ge 1 \]/[ "$nc" -ge 0 ]/'
mutate "M8 check 2 message reverted" 's/e4-ota-publish.sh only notes this (the image is authoritative)/e4-ota-publish.sh will refuse this/'

echo
echo "cases: passed $PASS, failed $FAIL; mutants: convicted $MPASS, failed $MFAIL"
[ "$FAIL" = 0 ] && [ "$MFAIL" = 0 ]
