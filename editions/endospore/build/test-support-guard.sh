#!/usr/bin/env bash
# test-support-guard.sh [--mutate] [<build-dir>] -- no release for a device past GrapheneOS's full support (NWP-20261124-19).
#
# Decided 2026-11-02 (#23, docs/product-decisions.md): releases stop when a device leaves GrapheneOS's full support. A
# committed editions/endospore/support-ended/<device> marker makes support-guard.sh refuse that device, and
# build-device.sh --release, sign-release.sh, e4-ota-publish.sh and e4-ota-promote.sh call it before anything runs.
#
# Guard cases run support-guard.sh under every shell found (bash, sh, dash, mksh; SG_TEST_SHELLS overrides). Executed
# cases run COPIES of the four scripts in scratch worlds with recording stubs (agent, ota-field-guard.sh, openssl, ps,
# tmux, envsetup.sh, generate-release.sh): with a marker each refuses with the guard's message and nothing past the
# guard runs; without one the same run gets past the guard; a dev build of a marked device gets past it too.
# <build-dir> runs the cases against the five scripts in another directory (the mutants use it).
#
#   bash test-support-guard.sh            # the cases
#   bash test-support-guard.sh --mutate   # ... plus mutants, each of which must be CONVICTED
set -uo pipefail

MUTATE=no; DIR=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; -*) echo "usage: $0 [--mutate] [<build-dir>]" >&2; exit 2 ;; *) DIR="$a" ;; esac; done
for t in git unzip python3; do command -v "$t" >/dev/null 2>&1 || { echo "FAIL: $t is required" >&2; exit 1; }; done
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
DIR="${DIR:-$HERE}"
SCRIPTS="support-guard.sh build-device.sh sign-release.sh e4-ota-publish.sh e4-ota-promote.sh"
for f in $SCRIPTS; do [ -s "$DIR/$f" ] || { echo "FAIL: $DIR/$f does not exist or is empty" >&2; exit 1; }; done
SG="$DIR/support-guard.sh"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT
export TMPDIR="$W/tmp"; mkdir -p "$TMPDIR"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_CEILING_DIRECTORIES="$W"
SHELLS="${SG_TEST_SHELLS:-}"
if [ -z "$SHELLS" ]; then for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done; fi

refusal() {   # <dev> <date>: the guard's refusal line, byte for byte
  printf "refusing: %s left GrapheneOS's full support on %s (editions/endospore/support-ended/%s); releases stop there (docs/product-decisions.md, 2026-11-02 #23)" "$1" "$2" "$1"
}
GOOD=$'ended 2027-05-01\nsource GrapheneOS announcement 2027-05-01: fixture\n'
mark() { printf '%s' "$GOOD" > "$1/$2"; }   # <support-ended-dir> <dev>
# empty_ended <dir>: a support-ended dir holding only the README. A world never copies the committed markers, so a
# real marker (lynx's, when GrapheneOS moves it) cannot turn a control case into a refusal; markers come from mark().
empty_ended() { mkdir -p "$1" && cp "$ROOT/editions/endospore/support-ended/README" "$1/"; }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }   # <text> <needle>

# ---- guard cases, under every shell ---------------------------------------------------------------------------------
# g <shell> <label> <want-rc> <dir> <stderr-needle> <args...>: RC, ERR
g() {
  local s="$1" label="$2" want="$3" d="$4" needle="$5" e; shift 5
  e=$(mktemp -p "$W") || return 1
  NOWHERE_SUPPORT_ENDED_DIR="$d" "$s" "$SG" "$@" 2> "$e"; RC=$?
  ERR=$(cat "$e")
  if [ "$want" = nonzero ]; then
    [ "$RC" != 0 ] || { no "[$s] $label: exit 0, want non-zero"; return; }
  else
    [ "$RC" = "$want" ] || { no "[$s] $label: exit $RC, want $want (stderr: $ERR)"; return; }
  fi
  if [ -z "$needle" ]; then
    [ -z "$ERR" ] || { no "[$s] $label: stderr not empty: $ERR"; return; }
  else
    has "$ERR" "$needle" || { no "[$s] $label: stderr lacks '$needle': $ERR"; return; }
  fi
  ok "[$s] $label"
}

guard_cases() {
  local s d m bad f x
  for s in $SHELLS; do
    d=$(mktemp -d -p "$W") || return 1
    cp "$ROOT/editions/endospore/support-ended/README" "$d/"
    g "$s" "G1 no marker for lynx -> 0, silent" 0 "$d" "" lynx
    mark "$d" lynx
    g "$s" "G2 a good marker -> 2, the refusal" 2 "$d" "$(refusal lynx 2027-05-01)" lynx
    [ "$ERR" = "$(refusal lynx 2027-05-01)" ] && ok "[$s] G2 the refusal is exactly one line" || no "[$s] G2 stderr is not exactly the refusal: $ERR"
    g "$s" "G8 a marker for lynx only, asked about tegu -> 0" 0 "$d" "" tegu
    m=0
    for bad in $'ended 2027-05-01\n' $'ended 2027-13-01\nsource x\n' $'ended 27-05-01\nsource x\n' \
               $'ended 2027-05-01\nsource x\nthird\n' '' $'ended 2027-05-01\nsource \n' $'ended 2027-05-01\r\nsource x\n' \
               $'source x\nended 2027-05-01\n'; do
      m=$((m+1)); f="$d/lynx"; printf '%s' "$bad" > "$f"
      g "$s" "G3-7 malformed marker #$m -> 2, names the file" 2 "$d" "malformed support-ended marker $f" lynx
    done
    rm -f "$d/lynx"; mkdir "$d/lynx"
    g "$s" "G7b a marker that is a directory -> 2" 2 "$d" "not a regular file" lynx
    rmdir "$d/lynx"
    g "$s" "G9 the directory missing -> refuses, names it" nonzero "$W/none" "no support-ended directory at $W/none" lynx
    for x in Lynx ../lynx "" "lynx/x"; do
      g "$s" "G10 bad device '$x' -> 2" 2 "$d" "bad device" "$x"
    done
    g "$s" "G10 two arguments -> 2" 2 "$d" "usage" lynx tegu
    # G11: unset, it reads ../support-ended beside its own dir.
    x=$(mktemp -d -p "$W") || return 1
    mkdir -p "$x/build" "$x/support-ended"; cp "$SG" "$x/build/"; mark "$x/support-ended" lynx
    ERR=$(env -u NOWHERE_SUPPORT_ENDED_DIR "$s" "$x/build/support-guard.sh" lynx 2>&1); RC=$?
    { [ "$RC" = 2 ] && has "$ERR" "$(refusal lynx 2027-05-01)"; } && ok "[$s] G11 the default dir is <guard>/../support-ended" \
      || no "[$s] G11 default dir: exit $RC: $ERR"
  done
}

# ---- executed cases: the four scripts in scratch worlds -------------------------------------------------------------
# e4-ota-publish.sh, in test-ota-publish-ring.sh's layout. publish_world <marker-dev|-> -> prints its dir.
publish_world() {
  local T B
  T=$(mktemp -d -p "$W" pub.XXXXXX) || return 1; B="$T/editions/endospore/build"
  mkdir -p "$B" "$T/editions/endospore/ota-mandatory" "$T/core/vendor-common/etc/ota-notes" "$T/rel" "$T/img/SYSTEM/etc"
  cp "$DIR/e4-ota-publish.sh" "$DIR/support-guard.sh" "$B/"
  empty_ended "$T/editions/endospore/support-ended"
  [ "$1" = - ] || mark "$T/editions/endospore/support-ended" "$1"
  printf '#!/bin/sh\nexit 0\n' > "$B/check-agent-fresh.sh"; chmod +x "$B/check-agent-fresh.sh"
  echo 0.5.43 > "$T/core/vendor-common/etc/nowhere-ota-version"; echo 0.5.43 > "$T/img/SYSTEM/etc/nowhere-ota-version"
  printf 'version 0.5.43\nprevious 0.5.42\n- A point.\n' > "$T/core/vendor-common/etc/ota-notes/0.5.43"
  cp "$T/core/vendor-common/etc/ota-notes/0.5.43" "$T/img/SYSTEM/etc/nowhere-ota-notes"
  (cd "$T/img" && zip -qr "$T/rel/lynx-target_files.zip" SYSTEM)
  printf 'p' > "$T/payload.bin"; printf 'q' > "$T/payload_properties.txt"
  (cd "$T" && zip -q "$T/rel/lynx-ota_update-1.zip" payload.bin payload_properties.txt)
  printf 'S3_ENDPOINT=x\nS3_REGION=x\nS3_BUCKET=x\nS3_ACCESS_KEY=x\nS3_SECRET_KEY=x\n' > "$T/conf"
  printf '#!/bin/sh\necho "agent $*" >> "$(dirname "$0")/rec"\n[ "$1" = ota-check ] && { echo "ota-check: no published OS version"; exit 3; }\nexit 0\n' > "$T/agent"
  chmod +x "$T/agent"
  printf '%s\n' "$T"
}
promote_world() {   # <marker-dev|-> -> prints its dir; the script copy is in <dir>/build
  local T
  T=$(mktemp -d -p "$W" pro.XXXXXX) || return 1
  mkdir -p "$T/build"; cp "$DIR/e4-ota-promote.sh" "$DIR/support-guard.sh" "$T/build/"
  printf '#!/bin/sh\nexit 0\n' > "$T/build/check-agent-fresh.sh"; chmod +x "$T/build/check-agent-fresh.sh"
  empty_ended "$T/support-ended"
  [ "$1" = - ] || mark "$T/support-ended" "$1"
  printf 'S3_ENDPOINT=x\nS3_REGION=x\nS3_BUCKET=x\nS3_ACCESS_KEY=x\nS3_SECRET_KEY=x\n' > "$T/conf"
  printf '#!/bin/sh\necho "agent $*" >> "$(dirname "$0")/rec"\n[ "$1" = ota-check ] && { echo "ota-check: no published OS version"; exit 3; }\nexit 0\n' > "$T/agent"
  chmod +x "$T/agent"
  printf '%s\n' "$T"
}

publish_cases() {
  local T out rc
  T=$(publish_world lynx) || { no "publish world"; return; }
  out=$(bash "$T/editions/endospore/build/e4-ota-publish.sh" --device lynx "$T/rel/lynx-ota_update-1.zip" 0.5.43 "$T/conf" "$T/agent" 2>&1); rc=$?
  [ "$rc" = 2 ] && ok "P1 e4-ota-publish.sh refuses a marked device: exit 2" || no "P1 e4-ota-publish.sh exit $rc, want 2: $out"
  has "$out" "$(refusal lynx 2027-05-01)" && ok "P1 ... with the guard's message" || no "P1 no refusal line: $out"
  [ ! -e "$T/rec" ] && ok "P1 ... and no agent (store) call ran" || no "P1 the agent ran past the guard: $(cat "$T/rec")"
  T=$(publish_world -) || { no "publish world"; return; }
  out=$(bash "$T/editions/endospore/build/e4-ota-publish.sh" --device lynx "$T/rel/lynx-ota_update-1.zip" 0.5.43 "$T/conf" "$T/agent" 2>&1)
  { [ -s "$T/rec" ] && ! has "$out" "refusing: lynx left"; } && ok "P2 control: no marker -> publish gets past the guard (the agent ran)" \
    || no "P2 control: publish did not get past the guard: $out"
  T=$(publish_world tegu) || { no "publish world"; return; }
  out=$(bash "$T/editions/endospore/build/e4-ota-publish.sh" --device lynx "$T/rel/lynx-ota_update-1.zip" 0.5.43 "$T/conf" "$T/agent" 2>&1)
  { [ -s "$T/rec" ] && ! has "$out" "refusing:"; } && ok "P3 a marker for another device -> publish gets past the guard" \
    || no "P3 a marker for tegu stopped lynx's publish: $out"
}

promote_cases() {
  local T out rc
  T=$(promote_world lynx) || { no "promote world"; return; }
  out=$(bash "$T/build/e4-ota-promote.sh" "$T/conf" --device lynx "$T/agent" --yes 2>&1); rc=$?
  [ "$rc" = 2 ] && ok "R1 e4-ota-promote.sh refuses a marked device: exit 2" || no "R1 e4-ota-promote.sh exit $rc, want 2: $out"
  has "$out" "$(refusal lynx 2027-05-01)" && ok "R1 ... with the guard's message" || no "R1 no refusal line: $out"
  [ ! -e "$T/rec" ] && ok "R1 ... and no agent (store) call ran" || no "R1 the agent ran past the guard: $(cat "$T/rec")"
  T=$(promote_world -) || { no "promote world"; return; }
  out=$(bash "$T/build/e4-ota-promote.sh" "$T/conf" --device lynx "$T/agent" --yes 2>&1)
  { [ -s "$T/rec" ] && ! has "$out" "refusing: lynx left"; } && ok "R2 control: no marker -> promote gets past the guard (the agent ran)" \
    || no "R2 control: promote did not get past the guard: $out"
}

# sign-release.sh, in test-sign-release.sh's world shape (cut down to the preflight).
sign_world() {   # <marker-dev|-> <dev>... -> prints its dir
  local X RB d mk="$1"; shift
  X=$(mktemp -d -p "$W" sign.XXXXXX) || return 1
  RB="$X/repo/editions/endospore/build"
  mkdir -p "$RB" "$X/repo/core/vendor-common/etc/rings" "$X/bin" "$X/tree/build" "$X/tree/script" "$X/shm"
  cp "$DIR/sign-release.sh" "$DIR/support-guard.sh" "$RB/"
  for d in sitting-guard.sh verified-commit-guard.sh ring-for-build.sh ring-record.tsv assert-baked-ring.sh keys-home.sh; do cp "$HERE/$d" "$RB/"; done
  cp "$ROOT"/core/vendor-common/etc/rings/*.conf "$X/repo/core/vendor-common/etc/rings/"
  empty_ended "$X/repo/editions/endospore/support-ended"
  [ "$mk" = - ] || mark "$X/repo/editions/endospore/support-ended" "$mk"
  echo 0.9.9 > "$X/repo/core/vendor-common/etc/nowhere-ota-version"
  printf '#!/bin/sh\necho "ofg $1 $2" >> "$FX_REC"\nexit 0\n' > "$RB/ota-field-guard.sh"
  printf '#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n' > "$RB/check-patch-markers.py"; : > "$RB/patch-markers.tsv"
  printf 'echo envsetup >> "$FX_REC"\n' > "$X/tree/build/envsetup.sh"
  printf '#!/bin/bash\nif [[ ! -v password ]]; then\n  read -rsp "Enter key passphrase: " password\nfi\necho decrypt-keys >> "$FX_REC"\n' > "$X/tree/script/decrypt-keys"
  printf '#!/bin/bash\n# K=/dev/shm/release_keys.XXXXXXXXXX\necho "generate-release $*" >> "$FX_REC"\n' > "$X/tree/script/generate-release.sh"
  for d in openssl ps tmux; do printf '#!/bin/sh\necho "%s $*" >> "$FX_REC"\nexit 1\n' "$d" > "$X/bin/$d"; done
  chmod +x "$RB"/*.sh "$RB/check-patch-markers.py" "$X/tree/script/"* "$X/bin/"*
  git -C "$X/repo" init -q && git -C "$X/repo" add -A \
    && git -C "$X/repo" -c user.name=fx -c user.email=fx@invalid commit -qm fixture || return 1
  : > "$X/conf"; printf '#!/bin/sh\necho "agent $*" >> "$FX_REC"\nexit 0\n' > "$X/agent"; chmod +x "$X/agent"
  for d in "$@"; do sign_dev "$X" "$d"; done
  printf '%s\n' "$X"
}
sign_dev() {   # <X> <dev>: a target-files zip the preflight accepts, and the key files
  local X="$1" DEV="$2" Z K RING
  Z="$X/tree/out-$DEV/target/product/$DEV/obj/PACKAGING/target_files_intermediates/$DEV-target_files.zip"
  RING=$(env -u NOWHERE_RING -u NOWHERE_RING_OVERRIDE sh "$X/repo/editions/endospore/build/ring-for-build.sh" "$DEV" release)
  mkdir -p "$(dirname "$Z")"
  python3 -I - "$Z" "$DEV" "$SBN" "$(git -C "$X/repo" rev-parse HEAD)" "$RING" "$X/repo/core/vendor-common/etc/rings" <<'PY'
import sys, zipfile
z, dev, bn, commit, ring, rings = sys.argv[1:7]
with zipfile.ZipFile(z, "w") as f:
    f.writestr("VENDOR/build.prop", "ro.vendor.build.fingerprint=google/%s/%s:15/AP4A/%s:user/release-keys\n" % (dev, dev, bn))
    f.writestr("SYSTEM/build.prop", "ro.build.type=user\n")
    f.writestr("SYSTEM/etc/nowhere/os-ref", "os-%s\n" % dev)
    f.writestr("SYSTEM/etc/nowhere/source-commit", commit + "\n")
    if ring and ring != "none":
        f.writestr("SYSTEM/etc/nowhere/nowhere.conf", open("%s/%s.conf" % (rings, ring)).read())
PY
  K="$X/tree/keys/$DEV"; mkdir -p "$K"
  : > "$K/releasekey.pk8"; : > "$K/avb.pem"; : > "$K/avb_pkmd.bin"; : > "$K/id_ed25519"
}
SBN=2026112401
sign_run() {   # <X> <dev>...: RC, OUT, ERR
  local X="$1"; shift
  : > "$X/rec"
  env -u TMUX -u NOWHERE_RING -u NOWHERE_RING_OVERRIDE -u BUILD_DATETIME -u BUILD_NUMBER -u OUT_DIR -u password \
    PATH="$X/bin:$PATH" ENDOSPORE_TREE="$X/tree" ENDOSPORE_REPO="$X/repo" SIGN_SHM_DIR="$X/shm" TMPDIR="$TMPDIR" \
    SIGN_MIN_TMP_GIB=0 NOWHERE_OTA_STORE_CONF="$X/conf" NOWHERE_AGENT="$X/agent" FX_REC="$X/rec" NOWHERE_KEYS_HOME="$X/keyshome" \
    bash "$X/repo/editions/endospore/build/sign-release.sh" "$SBN" "$(git -C "$X/repo" rev-parse HEAD)" "$@" \
    < /dev/null > "$X/out" 2> "$X/err"
  RC=$?; OUT=$(cat "$X/out"); ERR=$(cat "$X/err")
}
sign_cases() {
  local X rec
  X=$(sign_world lynx lynx) || { no "sign world"; return; }
  sign_run "$X" lynx; rec=$(cat "$X/rec")
  [ "$RC" = 1 ] && ok "S1 sign-release.sh refuses a marked device: exit 1" || no "S1 sign-release.sh exit $RC, want 1: $ERR"
  has "$ERR" "preflight refused" && ok "S1 ... 'preflight refused'" || no "S1 no 'preflight refused': $ERR"
  has "$ERR" "$(refusal lynx 2027-05-01)" && ok "S1 ... with the guard's message" || no "S1 no refusal line: $ERR"
  has "$ERR" "REFUSING: lynx: past GrapheneOS's full support" && ok "S1 ... and its own refusal naming the device" || no "S1 no 'REFUSING: lynx: past ...': $ERR"
  has "$ERR$OUT" "passphrase for the release keys" && no "S1 the passphrase prompt ran: $ERR" || ok "S1 no passphrase prompt"
  # The preflight collects every refusal, so the loop's own OTA stamp check (a stub here) still runs beside the guard.
  rec=$(printf '%s\n' "$rec" | grep -v '^ofg ')
  [ -z "$rec" ] && ok "S1 nothing past the preflight ran (no openssl, ps, tmux, envsetup, decrypt-keys or generate-release)" \
    || no "S1 something ran past the preflight: $rec"
  X=$(sign_world - lynx) || { no "sign world"; return; }
  sign_run "$X" lynx
  { has "$OUT" "preflight passed for lynx" && ! has "$ERR" "preflight refused" && ! has "$ERR" "full support"; } \
    && ok "S2 control: no marker -> the preflight passes" || no "S2 control: the preflight did not pass: $ERR"
  X=$(sign_world husky lynx husky) || { no "sign world"; return; }
  sign_run "$X" lynx husky
  { [ "$RC" = 1 ] && has "$ERR" "REFUSING: husky: past GrapheneOS's full support" && ! has "$ERR" "REFUSING: lynx: past" \
    && has "$ERR" "preflight refused"; } && ok "S3 two devices, marker on husky: refused, naming husky only" \
    || no "S3 two devices, marker on husky: exit $RC: $ERR"
}

# build-device.sh: a git world up to the guard; the stubs record anything that runs past it.
build_world() {   # <marker-dev|-> -> prints its dir
  local X RB d
  X=$(mktemp -d -p "$W" bd.XXXXXX) || return 1
  RB="$X/repo/editions/endospore/build"
  mkdir -p "$RB" "$X/repo/core/vendor-common/etc/rings" "$X/tree/build" "$X/tmp"
  cp "$DIR/build-device.sh" "$DIR/support-guard.sh" "$RB/"
  for d in ring-for-build.sh ring-record.tsv verified-commit-guard.sh assert-baked-ring.sh support-end-guard.sh; do cp "$HERE/$d" "$RB/"; done
  # build-device.sh runs support-end-guard.sh first (NWP-20261125-02): lynx gets a date no run reaches.
  mkdir -p "$X/repo/editions/endospore/devices/lynx"
  printf 'last-supported 2099-12\nsource fixture\n' > "$X/repo/editions/endospore/devices/lynx/support-end"
  cp "$ROOT"/core/vendor-common/etc/rings/*.conf "$X/repo/core/vendor-common/etc/rings/"
  empty_ended "$X/repo/editions/endospore/support-ended"
  [ "$1" = - ] || mark "$X/repo/editions/endospore/support-ended" "$1"
  echo 0.9.9 > "$X/repo/core/vendor-common/etc/nowhere-ota-version"
  printf '#!/bin/sh\necho "ota-field-guard $*" >> "$FX_REC"\nexit 0\n' > "$RB/ota-field-guard.sh"
  printf 'echo envsetup >> "$FX_REC"\n' > "$X/tree/build/envsetup.sh"
  git -C "$X/repo" init -q && git -C "$X/repo" add -A \
    && git -C "$X/repo" -c user.name=fx -c user.email=fx@invalid commit -qm fixture || return 1
  : > "$X/conf"; printf '#!/bin/sh\necho "agent $*" >> "$FX_REC"\nexit 0\n' > "$X/agent"; chmod +x "$X/agent"
  printf '%s\n' "$X"
}
build_run() {   # <X> <args...>: RC, OUT (stdout+stderr, through the script's own tee)
  local X="$1"; shift
  : > "$X/rec"
  OUT=$(env -u NOWHERE_RING -u NOWHERE_RING_OVERRIDE -u BUILD_NUMBER -u BUILD_DATETIME -u OUT_DIR -u VARIANT \
    ENDOSPORE_REPO="$X/repo" ENDOSPORE_TREE="$X/tree" LOG="$X/log" TMPDIR="$X/tmp" PREP=0 \
    NOWHERE_OTA_STORE_CONF="$X/conf" NOWHERE_AGENT="$X/agent" FX_REC="$X/rec" "${BENV[@]}" \
    bash "$X/repo/editions/endospore/build/build-device.sh" "$@" 2>&1 < /dev/null); RC=$?
}
BENV=()
build_cases() {
  local X
  X=$(build_world lynx) || { no "build world"; return; }
  BENV=(VARIANT=user); build_run "$X" lynx 2026112401 --release "$(git -C "$X/repo" rev-parse HEAD)"; BENV=()
  [ "$RC" != 0 ] && ok "B1 build-device.sh --release refuses a marked device: exit $RC" || no "B1 build-device.sh --release exit 0"
  has "$OUT" "$(refusal lynx 2027-05-01)" && ok "B1 ... with the guard's message" || no "B1 no refusal line: $OUT"
  { [ ! -s "$X/rec" ] && [ ! -e "$X/log" ]; } && ok "B1 ... before the OTA stamp guard, the agent, the log and envsetup" \
    || no "B1 something ran past the guard: $(cat "$X/rec" 2>/dev/null) log=$([ -e "$X/log" ] && echo yes || echo no)"
  X=$(build_world -) || { no "build world"; return; }
  BENV=(VARIANT=user); build_run "$X" lynx 2026112401 --release "$(git -C "$X/repo" rev-parse HEAD)"; BENV=()
  { has "$(cat "$X/rec")" "ota-field-guard lynx" && ! has "$OUT" "left GrapheneOS's full support"; } \
    && ok "B2 control: no marker -> --release gets past the guard (the OTA stamp guard ran)" || no "B2 control: --release stopped before the OTA stamp guard: $OUT"
  X=$(build_world lynx) || { no "build world"; return; }
  build_run "$X" lynx 2026112401
  { has "$OUT" "no os-ref-lynx staged" && ! has "$OUT" "left GrapheneOS's full support"; } \
    && ok "B3 a dev build (no --release) of a marked device gets past the guard" || no "B3 a dev build of a marked device was stopped: $OUT"
}

# Source pin: the call sits in an `if [ "$DO_RELEASE" = 1 ]; then` block of its own, after the verified-commit guard
# and before the OTA stamp guard.
build_pin() {
  local BD="$DIR/build-device.sh" n v o i ifl
  n=$(grep -n 'support-guard\.sh' "$BD" | grep -v '^[0-9]*:#' | cut -d: -f1)
  v=$(grep -n '^  sh .*verified-commit-guard\.sh' "$BD" | cut -d: -f1)
  o=$(grep -n '^  bash .*ota-field-guard\.sh' "$BD" | cut -d: -f1)
  case "$n" in ''|*[!0-9]*) no "B4 build-device.sh calls support-guard.sh exactly once (found: '$n')"; return ;; esac
  case "$v$o" in *[!0-9]*|'') no "B4 the verified-commit / OTA guard calls were not found"; return ;; esac
  { [ "$v" -lt "$n" ] && [ "$n" -lt "$o" ]; } && ok "B4 the call is after the verified-commit guard and before the OTA stamp guard" \
    || no "B4 the call (line $n) is not between the verified-commit guard ($v) and the OTA stamp guard ($o)"
  ifl=""; for i in $(seq "$n" -1 1); do case "$(sed -n "${i}p" "$BD")" in 'if '*) ifl=$i; break ;; fi) break ;; esac; done
  { [ -n "$ifl" ] && [ "$(sed -n "${ifl}p" "$BD")" = 'if [ "$DO_RELEASE" = 1 ]; then' ] \
    && [ "$(sed -n "$((n+1))p" "$BD")" = fi ]; } && ok "B4 the call sits inside an if [ \"\$DO_RELEASE\" = 1 ] block" \
    || no "B4 the call is not inside its own DO_RELEASE block"
}

guard_cases
publish_cases
promote_cases
sign_cases
build_cases
build_pin

if [ "$MUTATE" = yes ]; then
  [ "$FAIL" -eq 0 ] || { echo "$PASS passed, $FAIL failed -- not mutating a failing suite"; exit 1; }
  echo "== mutants =="
  # mut <id> <file> <awk program over the file>: the mutant replaces one script in a copy of the five.
  mut() {
    local id="$1" f="$2" prog="$3" M s rc f2
    M=$(mktemp -d -p "$W" mut.XXXXXX) || return 1
    for f2 in $SCRIPTS; do cp "$DIR/$f2" "$M/"; done
    awk "$prog" "$DIR/$f" > "$M/$f"
    if cmp -s "$DIR/$f" "$M/$f"; then no "MUTANT DID NOT APPLY: $id"; return; fi
    if [ "$f" = support-guard.sh ]; then
      for s in $SHELLS; do
        SG_TEST_SHELLS=$s bash "$0" "$M" >/dev/null 2>&1; rc=$?
        [ "$rc" != 0 ] && ok "convicted $id [$s]" || no "NOT CONVICTED $id [$s]"
      done
    else
      SG_TEST_SHELLS=sh bash "$0" "$M" >/dev/null 2>&1; rc=$?
      [ "$rc" != 0 ] && ok "convicted $id" || no "NOT CONVICTED $id"
    fi
  }
  mut S1a-build-device-call-removed build-device.sh '!/^  sh .*support-guard\.sh/'
  mut S1b-sign-release-call-removed sign-release.sh '!/^  sh .*support-guard\.sh/'
  mut S1c-publish-call-removed e4-ota-publish.sh '!/^sh .*support-guard\.sh/'
  mut S1d-promote-call-removed e4-ota-promote.sh '!/^sh .*support-guard\.sh/'
  mut S2-malformed-exits-0 support-guard.sh '/^bad\(\) \{/{inb=1} inb && /^  exit 2$/{sub(/exit 2/,"exit 0")} /^\}/{inb=0} {print}'
  mut S3-tests-the-directory support-guard.sh '{sub(/^\[ -e "\$F" \] \|\| exit 0$/,"[ -e \"$DIR\" ] || exit 0")} {print}'
  # S4: the if/fi lines around the call deleted, so the call runs for a dev build too.
  mut S4-call-outside-release build-device.sh '{l[NR]=$0} /^  sh .*support-guard\.sh/{c=NR} END{for(i=1;i<=NR;i++) if(i!=c-1 && i!=c+1) print l[i]}'
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
