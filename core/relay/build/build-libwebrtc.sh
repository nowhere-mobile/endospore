#!/usr/bin/env bash
# build-libwebrtc.sh [--dry-run] -- build libwebrtc for Android arm64 at a pinned revision, and prove it with a
# two-process loopback Opus call over DTLS-SRTP (NWP-20261210-12; docs/call-relay.md section 5.2, slice R1).
#
# WHERE IT RUNS: the build box only, as a box job (hours, tens of GB). The farm never runs it. CI runs
# test-build-libwebrtc.sh beside it, which sources this file and tests its guards with stubs.
#
# WHAT IT WRITES, AND WHERE:
#   RELAY_BUILD_ROOT (default /mnt/build/relay-libwebrtc) must resolve (realpath -m: '..' and symlinks resolved)
#   strictly under /mnt/build/ and not under the operator's HOME; root_ok refuses anything else with exit 2.
#   The box's 98 GB root disk cannot grow (see editions/endospore/build/build-device.sh, the TMPDIR comment),
#   so EVERY scratch dir and cache goes under the work dir "$ROOT/<first 12 of WEBRTC_REV>": a new pin never
#   reuses an old tree. Before any tool runs, TMPDIR, XDG_CACHE_HOME, GIT_CACHE_PATH, CIPD_CACHE_DIR,
#   VPYTHON_VIRTUALENV_ROOT and HOME are exported into the work dir (HOME="$WORK/home", so no tool writes the
#   shared box's real HOME), and DEPOT_TOOLS_UPDATE=0 (depot_tools stays at DEPOT_TOOLS_REV).
#   The script never installs a host package and never asks for root: a missing tool is named and the run stops.
#
# THE PINS: libwebrtc.pin beside this file, read as data (never sourced). WEBRTC_REV and DEPOT_TOOLS_REV must
# each be 40 lowercase hex; a branch name, HEAD or a short hash is refused.
#
# STAGES (in order; each resumable): depot_tools, fetch, sync, android-arm64, loopback-host, loopback-arm64,
# loopback-run. A stage writes "$WORK/.stage-<name>.done" holding the two pins only when it succeeded, and is
# skipped when that stamp holds the current pins. A failed stage leaves no stamp, so a re-run resumes there.
# The loopback stamps are also dropped when ../loopback/relay_loopback.cc or ../loopback/BUILD.gn change
# (their sha256 is kept in "$WORK/.loopback-src.sha256"); the upstream stages are kept.
# One build per work dir at a time: "$WORK/.lock" (flock).
#
# HOW THE LOOPBACK ENTERS THE GN BUILD: the loopback-* stages copy ../loopback (BUILD.gn + relay_loopback.cc)
# to src/nowhere_relay_loopback, replacing any earlier copy (idempotent), then run
# `gn gen <out> --root-target=//nowhere_relay_loopback:relay_loopback`, so GN starts loading from our BUILD.gn
# and no upstream file is edited, and build it by name: `ninja -C <out> nowhere_relay_loopback:relay_loopback`.
#
# OUTPUT, LAST: `LIB <path> <bytes>` (the arm64 libwebrtc.a), `LINKED <path> <bytes>` (the stripped arm64
# loopback: the per-ABI cost section 5.2 names), `LOOPBACK <PASS|FAIL> level=<dBFS> freq=<Hz>`. rc 0 only when
# all three are there and the loopback passed. --dry-run prints each stage's command lines and runs none of them
# (it also creates no directory, so it runs off the box).
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PIN_FILE="$SCRIPT_DIR/libwebrtc.pin"
LOOPBACK_SRC="$SCRIPT_DIR/../loopback"
DEFAULT_ROOT=/mnt/build/relay-libwebrtc
DEPOT_TOOLS_URL=https://chromium.googlesource.com/chromium/tools/depot_tools.git
LOOPBACK_SECONDS=10
LOOPBACK_LABEL=//nowhere_relay_loopback:relay_loopback
LOOPBACK_NINJA=nowhere_relay_loopback:relay_loopback
STAGES="depot_tools fetch sync android-arm64 loopback-host loopback-arm64 loopback-run"

GN_ARGS_ANDROID='target_os="android" target_cpu="arm64" is_debug=false rtc_include_tests=false rtc_build_examples=false rtc_build_tools=false use_siso=false'
GN_ARGS_LOOPBACK_HOST='target_os="linux" target_cpu="x64" is_debug=false rtc_include_tests=false rtc_build_examples=false rtc_build_tools=false rtc_use_x11=false rtc_include_pulse_audio=false use_siso=false treat_warnings_as_errors=false'
GN_ARGS_LOOPBACK_ARM64="$GN_ARGS_ANDROID treat_warnings_as_errors=false"

DRY_RUN=0
CURRENT_STAGE=
LOOPBACK_PIDS=()
LOOPBACK_SOCK=

fail() { echo "build-libwebrtc: FAILED: $*" >&2; exit 1; }
refuse() { echo "build-libwebrtc: refused: $*" >&2; return 2; }

# root_ok <path> <base> <home>: 0 when <path> resolves strictly under <base>/ and not under <home>; else 2 and
# one line naming the reason class. main calls it with exactly /mnt/build and the real $HOME.
root_ok() {
  local p b h
  if [ -z "${1:-}" ] || [ -z "${2:-}" ] || [ -z "${3:-}" ]; then refuse "empty-path (root, base and home must all be set)"; return 2; fi
  p=$(realpath -m -- "$1") || { refuse "unresolvable-path ($1)"; return 2; }
  b=$(realpath -m -- "$2") || { refuse "unresolvable-path ($2)"; return 2; }
  h=$(realpath -m -- "$3") || { refuse "unresolvable-path ($3)"; return 2; }
  if [ "$p" = / ]; then refuse "filesystem-root ($1 resolves to /)"; return 2; fi
  case "$p/" in
    "$b"/?*/) ;;
    *) refuse "not-under-base ($1 resolves to $p, which is not strictly under $b/)"; return 2 ;;
  esac
  case "$p/" in
    "$h"/*) refuse "under-home ($1 resolves to $p, inside the home $h)"; return 2 ;;
  esac
  return 0
}

# pin_ok <value>: a full commit id, 40 lowercase hex.
pin_ok() { [[ $1 =~ ^[0-9a-f]{40}$ ]]; }

# read_pins <file>: set WEBRTC_REV and DEPOT_TOOLS_REV from the pin file (data only; each key exactly once).
read_pins() {
  local f=$1 line key val w= d= nw=0 nd=0
  if [ ! -r "$f" ]; then refuse "pin-file-unreadable ($f)"; return 2; fi
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in '' | '#'*) continue ;; esac
    key=${line%%=*}
    val=${line#*=}
    case $key in
      WEBRTC_REV) w=$val; nw=$((nw + 1)) ;;
      DEPOT_TOOLS_REV) d=$val; nd=$((nd + 1)) ;;
      *) refuse "pin-file-unknown-line (only WEBRTC_REV= and DEPOT_TOOLS_REV= lines and # comments)"; return 2 ;;
    esac
  done <"$f"
  if [ "$nw" != 1 ] || [ "$nd" != 1 ]; then refuse "pin-missing (WEBRTC_REV and DEPOT_TOOLS_REV must each appear once)"; return 2; fi
  if ! pin_ok "$w"; then refuse "bad-pin (WEBRTC_REV is not 40 lowercase hex)"; return 2; fi
  if ! pin_ok "$d"; then refuse "bad-pin (DEPOT_TOOLS_REV is not 40 lowercase hex)"; return 2; fi
  WEBRTC_REV=$w
  DEPOT_TOOLS_REV=$d
}

# set_paths: every path the stages use, from WORK.
set_paths() {
  DT="$WORK/depot_tools"
  GCLIENT_ROOT="$WORK/webrtc"
  SRC="$GCLIENT_ROOT/src"
  LIB="$SRC/out/android-arm64/obj/libwebrtc.a"
  HOST_BIN="$SRC/out/loopback-host/relay_loopback"
  ARM64_BIN="$SRC/out/loopback-arm64/relay_loopback"
  LINKED="$WORK/out/relay_loopback-android-arm64"
  LLVM_STRIP="$SRC/third_party/llvm-build/Release+Asserts/bin/llvm-strip"
  RUN_DIR="$WORK/run"
  LOOPBACK_RESULT="$RUN_DIR/loopback.result"
}

# export_env <work>: point every scratch dir and cache into the work dir. Runs before any tool.
export_env() {
  local w=$1
  export TMPDIR="$w/tmp"
  export XDG_CACHE_HOME="$w/cache/xdg"
  export GIT_CACHE_PATH="$w/cache/git"
  export CIPD_CACHE_DIR="$w/cache/cipd"
  export VPYTHON_VIRTUALENV_ROOT="$w/cache/vpython"
  export HOME="$w/home"
  export DEPOT_TOOLS_UPDATE=0
  export DEPOT_TOOLS_METRICS=0
  export PATH="$w/depot_tools:$PATH"
}

# setup_env <work>: export_env, then create those directories.
setup_env() {
  export_env "$1"
  mkdir -p -- "$TMPDIR" "$XDG_CACHE_HOME" "$GIT_CACHE_PATH" "$CIPD_CACHE_DIR" "$VPYTHON_VIRTUALENV_ROOT" "$HOME"
}

check_host_tools() {
  local t missing=()
  for t in git python3 curl tar xz flock timeout realpath stat sha256sum; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "build-libwebrtc: refused: missing-host-package (install the package that provides: ${missing[*]}; this script installs nothing)" >&2
    exit 2
  fi
}

take_lock() {
  exec 9>"$WORK/.lock"
  if ! flock -n 9; then
    echo "build-libwebrtc: refused: busy (another build holds $WORK/.lock)" >&2
    exit 2
  fi
}

# quote_arg <arg>: print one argument so the printed line can be pasted into a shell.
quote_arg() {
  case $1 in
    '') printf "''" ;;
    *[!A-Za-z0-9_./@:=,+%-]*) printf "'%s'" "${1//\'/\'\\\'\'}" ;;
    *) printf '%s' "$1" ;;
  esac
}

print_cmd() {
  local a
  printf '+'
  for a in "$@"; do
    printf ' '
    quote_arg "$a"
  done
  printf '\n'
}

# run <cmd...>: print the command line; run it unless this is a dry run. Dry runs and real runs share it.
run() {
  print_cmd "$@"
  if [ "$DRY_RUN" = 1 ]; then return 0; fi
  "$@"
}

# run_in <dir> <cmd...>: the same, with <dir> as the working directory.
run_in() {
  local dir=$1
  shift
  printf '+ (cd %s)' "$(quote_arg "$dir")"
  print_cmd "$@" | cut -c2-
  if [ "$DRY_RUN" = 1 ]; then return 0; fi
  (cd -- "$dir" && "$@")
}

stamp_body() { printf 'WEBRTC_REV=%s\nDEPOT_TOOLS_REV=%s\n' "$WEBRTC_REV" "$DEPOT_TOOLS_REV"; }

# stamp_current <stamp>: 0 when the stamp exists and holds exactly the current pins.
stamp_current() { [ -f "$1" ] && [ "$(cat -- "$1")" = "$(stamp_body)" ]; }

# run_stage <name> <function>: call it plainly (never from a conditional context, which would switch off
# errexit inside the stage), so a failing command ends the run before the stamp is written.
run_stage() {
  local name=$1 fn=$2 stamp="$WORK/.stage-$1.done" t0
  if [ "$DRY_RUN" = 1 ]; then
    echo "== stage $name (dry run: printed, not run)"
    "$fn"
    return 0
  fi
  if stamp_current "$stamp"; then
    echo "== stage $name: skipped (its stamp holds these pins)"
    return 0
  fi
  rm -f -- "$stamp"
  CURRENT_STAGE=$name
  t0=$(date +%s)
  echo "== stage $name: start $(date -u +%FT%TZ)"
  "$fn"
  stamp_body >"$stamp.tmp"
  mv -f -- "$stamp.tmp" "$stamp"
  echo "== stage $name: done in $(($(date +%s) - t0))s" | tee -a "$WORK/stage-times.log"
  CURRENT_STAGE=
}

loopback_digest() { cat -- "$LOOPBACK_SRC/relay_loopback.cc" "$LOOPBACK_SRC/BUILD.gn" | sha256sum | cut -d' ' -f1; }

# invalidate_loopback_stamps: a changed loopback source re-runs the three loopback stages, not the upstream ones.
invalidate_loopback_stamps() {
  local d f="$WORK/.loopback-src.sha256" s
  d=$(loopback_digest)
  if [ ! -f "$f" ] || [ "$(cat -- "$f")" != "$d" ]; then
    for s in loopback-host loopback-arm64 loopback-run; do rm -f -- "$WORK/.stage-$s.done"; done
    printf '%s\n' "$d" >"$f"
  fi
}

# gclient_target_os <.gclient>: make the checkout carry the android and linux deps (idempotent).
gclient_target_os() {
  local f=$1 tmp
  [ -f "$f" ] || fail "fetch: $f is missing after fetch"
  tmp=$(mktemp -p "$TMPDIR")
  grep -v '^target_os[[:space:]]*=' -- "$f" >"$tmp" || true
  printf 'target_os = ["android", "linux"]\n' >>"$tmp"
  mv -f -- "$tmp" "$f"
}

# copy_loopback: replace src/nowhere_relay_loopback with the committed loopback source (idempotent).
copy_loopback() {
  local dst="$SRC/nowhere_relay_loopback"
  rm -rf -- "$dst"
  mkdir -p -- "$dst"
  cp -- "$LOOPBACK_SRC/BUILD.gn" "$LOOPBACK_SRC/relay_loopback.cc" "$dst/"
}

stage_depot_tools() {
  local head
  if [ "$DRY_RUN" = 1 ] || [ ! -d "$DT/.git" ]; then
    # A clone cut short leaves only the .partial dir, which the next run replaces.
    run rm -rf -- "$DT.partial"
    run git clone --no-checkout "$DEPOT_TOOLS_URL" "$DT.partial"
    run mv -- "$DT.partial" "$DT"
  fi
  run git -C "$DT" checkout --force --detach "$DEPOT_TOOLS_REV"
  if [ "$DRY_RUN" = 1 ]; then return 0; fi
  head=$(git -C "$DT" rev-parse HEAD)
  if [ "$head" != "$DEPOT_TOOLS_REV" ]; then fail "depot_tools: checkout is at $head, not the pin $DEPOT_TOOLS_REV"; fi
}

stage_fetch() {
  run mkdir -p -- "$GCLIENT_ROOT"
  if [ "$DRY_RUN" = 0 ] && [ -f "$GCLIENT_ROOT/.gclient" ]; then
    # fetch refuses a directory that already holds a .gclient; the sync stage completes a cut-short fetch.
    echo "fetch: $GCLIENT_ROOT/.gclient exists, so fetch is not run again"
  else
    run_in "$GCLIENT_ROOT" fetch --nohooks webrtc_android
  fi
  run gclient_target_os "$GCLIENT_ROOT/.gclient"
}

stage_sync() {
  local head
  run_in "$GCLIENT_ROOT" gclient sync -r "src@$WEBRTC_REV" -D --no-history
  if [ "$DRY_RUN" = 1 ]; then return 0; fi
  head=$(git -C "$SRC" rev-parse HEAD)
  if [ "$head" != "$WEBRTC_REV" ]; then
    fail "sync: src is at $head, not the pin $WEBRTC_REV"
  fi
}

stage_android_arm64() {
  run_in "$SRC" gn gen out/android-arm64 "--args=$GN_ARGS_ANDROID"
  run_in "$SRC" ninja -C out/android-arm64 webrtc
  if [ "$DRY_RUN" = 1 ]; then return 0; fi
  [ -s "$LIB" ] || fail "android-arm64: ninja finished but $LIB is missing or empty"
}

stage_loopback_host() {
  run copy_loopback
  run_in "$SRC" gn gen out/loopback-host "--root-target=$LOOPBACK_LABEL" "--args=$GN_ARGS_LOOPBACK_HOST"
  run_in "$SRC" ninja -C out/loopback-host "$LOOPBACK_NINJA"
  if [ "$DRY_RUN" = 1 ]; then return 0; fi
  [ -x "$HOST_BIN" ] || fail "loopback-host: ninja finished but $HOST_BIN is missing"
}

stage_loopback_arm64() {
  run copy_loopback
  run_in "$SRC" gn gen out/loopback-arm64 "--root-target=$LOOPBACK_LABEL" "--args=$GN_ARGS_LOOPBACK_ARM64"
  run_in "$SRC" ninja -C out/loopback-arm64 "$LOOPBACK_NINJA"
  run mkdir -p -- "$WORK/out"
  run "$LLVM_STRIP" -o "$LINKED" "$ARM64_BIN"
  if [ "$DRY_RUN" = 1 ]; then return 0; fi
  [ -s "$LINKED" ] || fail "loopback-arm64: $LINKED is missing or empty after the strip"
}

# stage_loopback_run: the answer side first (it listens), then the offer side, each under a timeout.
stage_loopback_run() {
  local sock="$RUN_DIR/signal.sock" limit=$((LOOPBACK_SECONDS + 60)) apid orc=0 arc=0 i=0 line
  local answer=(timeout "$limit" "$HOST_BIN" --role answer --sock "$sock" --seconds "$LOOPBACK_SECONDS" --out "$RUN_DIR/answer-received.wav")
  local offer=(timeout "$limit" "$HOST_BIN" --role offer --sock "$sock" --seconds "$LOOPBACK_SECONDS" --out "$RUN_DIR/offer-received.wav")
  run mkdir -p -- "$RUN_DIR"
  if [ "$DRY_RUN" = 1 ]; then
    print_cmd "${answer[@]}"
    print_cmd "${offer[@]}"
    return 0
  fi
  rm -f -- "$sock" "$LOOPBACK_RESULT" "$RUN_DIR/answer.out" "$RUN_DIR/offer.out"
  LOOPBACK_SOCK=$sock
  print_cmd "${answer[@]}"
  "${answer[@]}" >"$RUN_DIR/answer.out" 2>&1 &
  apid=$!
  LOOPBACK_PIDS=("$apid")
  while [ ! -S "$sock" ] && kill -0 "$apid" 2>/dev/null && [ "$i" -lt 150 ]; do
    sleep 0.2
    i=$((i + 1))
  done
  print_cmd "${offer[@]}"
  "${offer[@]}" >"$RUN_DIR/offer.out" 2>&1 || orc=$?
  wait "$apid" || arc=$?
  LOOPBACK_PIDS=()
  rm -f -- "$sock"
  sed 's/^/answer: /' "$RUN_DIR/answer.out"
  sed 's/^/offer: /' "$RUN_DIR/offer.out"
  line=$(grep -E '^LOOPBACK (PASS|FAIL) ' "$RUN_DIR/answer.out" | tail -n 1) || line=
  printf '%s\n' "$line" >"$LOOPBACK_RESULT"
  if [ "$arc" != 0 ] || [ "$orc" != 0 ]; then
    report || true
    fail "loopback-run: answer rc=$arc, offer rc=$orc"
  fi
}

# report: the three output lines, last. 0 only when the library and the stripped loopback exist and are not
# empty and the loopback passed.
report() {
  local rc=0 size line=
  if [ -f "$LIB" ] && size=$(stat -c %s -- "$LIB") && [ "$size" -gt 0 ]; then
    echo "LIB $LIB $size"
  else
    echo "build-libwebrtc: no library at $LIB" >&2
    rc=1
  fi
  if [ -f "$LINKED" ] && size=$(stat -c %s -- "$LINKED") && [ "$size" -gt 0 ]; then
    echo "LINKED $LINKED $size"
  else
    echo "build-libwebrtc: no stripped loopback at $LINKED" >&2
    rc=1
  fi
  if [ -f "$LOOPBACK_RESULT" ]; then line=$(head -n 1 -- "$LOOPBACK_RESULT"); fi
  if [[ $line =~ ^LOOPBACK\ (PASS|FAIL)\ level=-?[0-9]+(\.[0-9]+)?\ freq=[0-9]+(\.[0-9]+)?$ ]]; then
    echo "$line"
  else
    echo "build-libwebrtc: no LOOPBACK line in $LOOPBACK_RESULT" >&2
    rc=1
  fi
  if [[ $line != "LOOPBACK PASS "* ]]; then rc=1; fi
  return "$rc"
}

cleanup() {
  local rc=$? p
  for p in "${LOOPBACK_PIDS[@]}"; do
    kill "$p" 2>/dev/null || true
  done
  if [ -n "$LOOPBACK_SOCK" ]; then rm -f -- "$LOOPBACK_SOCK"; fi
  if [ "$rc" != 0 ] && [ -n "$CURRENT_STAGE" ]; then
    echo "build-libwebrtc: stage $CURRENT_STAGE FAILED (rc $rc); it wrote no stamp, so a re-run resumes there" >&2
  fi
}

usage() { echo "usage: build-libwebrtc.sh [--dry-run]" >&2; exit 2; }

main() {
  local root t0 s fn
  if [ "$#" -gt 1 ]; then usage; fi
  if [ "$#" = 1 ]; then
    if [ "$1" = --dry-run ]; then DRY_RUN=1; else usage; fi
  fi
  root="${RELAY_BUILD_ROOT:-$DEFAULT_ROOT}"
  root_ok "$root" /mnt/build "$HOME" || exit 2
  read_pins "$PIN_FILE" || exit 2
  WORK="$(realpath -m -- "$root")/${WEBRTC_REV:0:12}"
  set_paths
  echo "== build-libwebrtc: WEBRTC_REV=$WEBRTC_REV DEPOT_TOOLS_REV=$DEPOT_TOOLS_REV work=$WORK dry_run=$DRY_RUN"
  t0=$(date +%s)
  if [ "$DRY_RUN" = 1 ]; then
    export_env "$WORK"
  else
    check_host_tools
    mkdir -p -- "$WORK"
    take_lock
    setup_env "$WORK"
    trap cleanup EXIT
    invalidate_loopback_stamps
  fi
  for s in $STAGES; do
    fn="stage_${s//-/_}"
    run_stage "$s" "$fn"
  done
  if [ "$DRY_RUN" = 1 ]; then
    echo "== dry run: no stage ran"
    return 0
  fi
  echo "== build-libwebrtc: this run took $(($(date +%s) - t0))s (per-stage times: $WORK/stage-times.log)"
  report
}

[ "${BASH_SOURCE[0]}" = "$0" ] && main "$@"
