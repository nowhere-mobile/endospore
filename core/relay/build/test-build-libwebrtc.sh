#!/usr/bin/env bash
# test-build-libwebrtc.sh [--mutate] [<build-libwebrtc.sh>] -- pins the rules of build-libwebrtc.sh
# (NWP-20261210-12) off the build box: no /mnt/build, no network, no WebRTC checkout.
#
# It sources the script (main does not run when sourced) and calls its functions, with stubs for git, fetch,
# gclient, gn and ninja first in PATH, each logging its argv. The root guard is tested on its decision, by
# calling root_ok with paths under a scratch base.
#   T1  root_ok refuses /, the base, '..' out of it, the home, a symlink into the home and one to /etc;
#       accepts two paths strictly under the base.
#   T1b main calls root_ok with exactly /mnt/build and "$HOME" (source pin, and a dry run outside /mnt/build).
#   T2  the pin reader refuses an empty, short, uppercase, `main` or `HEAD` pin; accepts the committed pins.
#   T3  after the env step, every scratch dir and cache a child process sees is in the work dir, and
#       DEPOT_TOOLS_UPDATE=0; the script never runs a package installer.
#   T4  --dry-run prints the pinned sync line and the android arm64 gn args, and no stub runs.
#   T5  a stage whose stamp holds the current pins is skipped; other pins re-run it; a failure leaves no stamp.
#   T6  the sync stage fails when src is not at the pinned commit.
#   T7  the run's rc is not 0 when the loopback says FAIL or the library is missing.
# --mutate: each mutant must apply, change the file and be CONVICTED by the case it names; the control mutant
# (a comment's wording) must SURVIVE every case.
set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
MUTATE=0
if [ "${1:-}" = --mutate ]; then
  MUTATE=1
  shift
fi
TARGET=${1:-$HERE/build-libwebrtc.sh}

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

if [ ! -f "$TARGET" ]; then
  echo "FAIL: no script at $TARGET"
  exit 1
fi

HEX_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEX_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
HEX_C=cccccccccccccccccccccccccccccccccccccccc

# The stubs: each logs "<name> <argv>" to $STUB_LOG and exits 1 when STUB_FAIL names it. git answers
# rev-parse with $STUB_HEAD; ninja writes one byte to $STUB_NINJA_OUT when it is set.
STUBS="$W/stubs"
mkdir -p "$STUBS"
for name in git fetch gclient gn ninja; do
  cat >"$STUBS/$name" <<EOF
#!/usr/bin/env bash
{ printf '%s' "$name"; printf ' %s' "\$@"; printf '\n'; } >>"\${STUB_LOG:?}"
if [ "\${STUB_FAIL:-}" = "$name" ]; then exit 1; fi
if [ "$name" = git ]; then
  for a in "\$@"; do
    if [ "\$a" = rev-parse ]; then printf '%s\n' "\${STUB_HEAD:-}"; exit 0; fi
  done
fi
if [ "$name" = ninja ] && [ -n "\${STUB_NINJA_OUT:-}" ]; then
  mkdir -p "\$(dirname "\$STUB_NINJA_OUT")" && printf x >"\$STUB_NINJA_OUT"
fi
exit 0
EOF
  chmod +x "$STUBS/$name"
done

# Every case runs in its own subshell, prints one line per failed check and returns 1 when any failed.
bad() { echo "  $*"; FAILED=1; }

case_T1() {
  local s=$1 d mb p out rc
  . "$s" || true
  set +eu
  FAILED=0
  d=$(mktemp -d -p "$W")
  mb="$d/mb"
  mkdir -p "$mb/home"
  ln -s "$mb/home" "$mb/l"
  ln -s /etc "$mb/e"
  for p in / "$mb" "$mb/../etc" "$mb/home/x" "$mb/l" "$mb/e"; do
    out=$(root_ok "$p" "$mb" "$mb/home" 2>&1)
    rc=$?
    if [ "$rc" != 2 ]; then bad "T1: root_ok accepted $p (rc $rc), want a refusal (rc 2)"; continue; fi
    case $out in
      "build-libwebrtc: refused: "*) ;;
      *) bad "T1: the refusal of $p does not name its reason: $out" ;;
    esac
    if [ "$(printf '%s\n' "$out" | wc -l)" != 1 ]; then bad "T1: the refusal of $p is not one line"; fi
  done
  for p in "$mb/relay-libwebrtc" "$mb/a/b"; do
    out=$(root_ok "$p" "$mb" "$mb/home" 2>&1)
    rc=$?
    if [ "$rc" != 0 ]; then bad "T1: root_ok refused $p (rc $rc): $out"; fi
  done
  return "$FAILED"
}

case_T1b() {
  local s=$1 d out rc n
  FAILED=0
  d=$(mktemp -d -p "$W")
  n=$(grep -c 'root_ok "\$root" ' "$s")
  if [ "$n" != 1 ] || ! grep -qF 'root_ok "$root" /mnt/build "$HOME" || exit 2' "$s"; then
    bad 'T1b: main does not call root_ok "$root" /mnt/build "$HOME" exactly once'
  fi
  out=$(HOME="$d/h" RELAY_BUILD_ROOT=/mnt/nowhere-t1b PATH="$STUBS:$PATH" STUB_LOG="$d/log" bash "$s" --dry-run 2>&1)
  rc=$?
  if [ "$rc" != 2 ]; then bad "T1b: RELAY_BUILD_ROOT=/mnt/nowhere-t1b was accepted (rc $rc), want rc 2"; fi
  case $out in *"refused: not-under-base"*) ;; *) bad "T1b: /mnt/nowhere-t1b was not refused as not-under-base" ;; esac
  out=$(HOME=/mnt/build/t1b-home RELAY_BUILD_ROOT=/mnt/build/t1b-home/x PATH="$STUBS:$PATH" STUB_LOG="$d/log" bash "$s" --dry-run 2>&1)
  rc=$?
  if [ "$rc" != 2 ]; then bad "T1b: a root inside \$HOME was accepted (rc $rc), want rc 2"; fi
  case $out in *"refused: under-home"*) ;; *) bad "T1b: a root inside \$HOME was not refused as under-home" ;; esac
  return "$FAILED"
}

case_T2() {
  local s=$1 d v key f rc pin
  . "$s" || true
  set +eu
  FAILED=0
  d=$(mktemp -d -p "$W")
  for key in WEBRTC_REV DEPOT_TOOLS_REV; do
    for v in '' "${HEX_A:0:39}" AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA main HEAD; do
      f=$(mktemp -p "$d")
      if [ "$key" = WEBRTC_REV ]; then
        printf 'WEBRTC_REV=%s\nDEPOT_TOOLS_REV=%s\n' "$v" "$HEX_B" >"$f"
      else
        printf 'WEBRTC_REV=%s\nDEPOT_TOOLS_REV=%s\n' "$HEX_A" "$v" >"$f"
      fi
      (read_pins "$f") >/dev/null 2>&1
      rc=$?
      if [ "$rc" != 2 ]; then bad "T2: read_pins accepted $key='$v' (rc $rc), want rc 2"; fi
    done
  done
  pin="$(dirname -- "$s")/libwebrtc.pin"
  WEBRTC_REV= DEPOT_TOOLS_REV=
  read_pins "$pin" >/dev/null 2>&1
  rc=$?
  if [ "$rc" != 0 ]; then bad "T2: read_pins refused the committed $pin (rc $rc)"; fi
  if ! [[ $WEBRTC_REV =~ ^[0-9a-f]{40}$ ]] || ! [[ $DEPOT_TOOLS_REV =~ ^[0-9a-f]{40}$ ]]; then
    bad "T2: the committed pins are not both 40 lowercase hex"
  fi
  return "$FAILED"
}

case_T3() {
  local s=$1 d work child i v
  local names=(HOME TMPDIR XDG_CACHE_HOME GIT_CACHE_PATH CIPD_CACHE_DIR VPYTHON_VIRTUALENV_ROOT)
  . "$s" || true
  set +eu
  FAILED=0
  d=$(mktemp -d -p "$W")
  work="$d/work"
  # Not exported beforehand, so only the env step can export them.
  unset TMPDIR XDG_CACHE_HOME GIT_CACHE_PATH CIPD_CACHE_DIR VPYTHON_VIRTUALENV_ROOT DEPOT_TOOLS_UPDATE
  export HOME="$d/real-home"
  mkdir -p "$HOME"
  (setup_env "$work") >/dev/null 2>&1 || bad "T3: setup_env failed"
  setup_env "$work" >/dev/null 2>&1
  child=$(env -u BASH_ENV bash -c 'for n in HOME TMPDIR XDG_CACHE_HOME GIT_CACHE_PATH CIPD_CACHE_DIR VPYTHON_VIRTUALENV_ROOT; do printf "%s\n" "${!n:-}"; done; printf "%s\n" "${DEPOT_TOOLS_UPDATE:-}"')
  i=0
  while IFS= read -r v; do
    if [ "$i" -lt 6 ]; then
      case $v in
        "$work"/*) [ -d "$v" ] || bad "T3: ${names[$i]}=$v was not created" ;;
        *) bad "T3: a child process sees ${names[$i]}='$v', outside the work dir $work" ;;
      esac
    elif [ "$v" != 0 ]; then
      bad "T3: a child process sees DEPOT_TOOLS_UPDATE='$v', want 0"
    fi
    i=$((i + 1))
  done <<<"$child"
  if grep -nE 'sudo|install-build-deps' "$s" >/dev/null; then bad "T3: the script names sudo or install-build-deps"; fi
  return "$FAILED"
}

case_T4() {
  local s=$1 d out rc rev gnline
  FAILED=0
  d=$(mktemp -d -p "$W")
  rev=$(sed -n 's/^WEBRTC_REV=//p' "$(dirname -- "$s")/libwebrtc.pin")
  out=$(HOME="$d/h" PATH="$STUBS:$PATH" STUB_LOG="$d/log" bash "$s" --dry-run 2>&1)
  rc=$?
  if [ "$rc" != 0 ]; then bad "T4: --dry-run exited $rc: $(printf '%s\n' "$out" | tail -n 3)"; fi
  if ! grep -qF "gclient sync -r src@$rev -D --no-history" <<<"$out"; then
    bad "T4: the dry run's sync line does not name src@$rev"
  fi
  gnline=$(grep -E '^\+ \(cd [^)]*\) gn gen out/android-arm64 ' <<<"$out")
  if ! grep -qF 'target_os="android" target_cpu="arm64"' <<<"$gnline"; then
    bad 'T4: the dry run has no android-arm64 gn gen line with target_os="android" target_cpu="arm64"'
  fi
  if ! grep -qF 'fetch --nohooks webrtc_android' <<<"$out"; then bad "T4: the dry run does not print the fetch line"; fi
  if ! grep -qE -- '--role answer .*--seconds 10 ' <<<"$out" || ! grep -qE -- '--role offer ' <<<"$out"; then
    bad "T4: the dry run does not print the two loopback-run lines"
  fi
  if [ -s "$d/log" ]; then bad "T4: the dry run ran a tool: $(head -n 1 "$d/log")"; fi
  return "$FAILED"
}

# T5 and T6 call run_stage the way main does: plainly, in a subshell with errexit on.
case_T5() {
  local s=$1 d rc stamp
  . "$s" || true
  set +eu
  FAILED=0
  d=$(mktemp -d -p "$W")
  WORK="$d/work"
  set_paths
  mkdir -p "$SRC"
  WEBRTC_REV=$HEX_A DEPOT_TOOLS_REV=$HEX_B DRY_RUN=0
  export PATH="$STUBS:$PATH" STUB_LOG="$d/log" STUB_NINJA_OUT="$LIB"
  : >"$STUB_LOG"
  stamp="$WORK/.stage-android-arm64.done"

  stamp_body >"$stamp"
  (set -e; run_stage android-arm64 stage_android_arm64) >/dev/null 2>&1
  rc=$?
  if [ "$rc" != 0 ] || [ -s "$STUB_LOG" ]; then bad "T5: a stamp holding the current pins did not skip the stage (rc $rc)"; fi

  printf 'WEBRTC_REV=%s\nDEPOT_TOOLS_REV=%s\n' "$HEX_C" "$HEX_B" >"$stamp"
  (set -e; run_stage android-arm64 stage_android_arm64) >/dev/null 2>&1
  rc=$?
  if [ "$rc" != 0 ] || ! grep -q '^gn gen out/android-arm64 ' "$STUB_LOG" || ! grep -q '^ninja ' "$STUB_LOG"; then
    bad "T5: a stamp holding other pins did not re-run the stage (rc $rc)"
  fi
  if [ "$(cat "$stamp")" != "$(stamp_body)" ]; then bad "T5: the re-run did not stamp the current pins"; fi

  rm -f "$stamp" "$LIB"
  : >"$STUB_LOG"
  (set -e; STUB_FAIL=gn run_stage android-arm64 stage_android_arm64) >/dev/null 2>&1
  rc=$?
  if [ "$rc" = 0 ]; then bad "T5: the stage passed with a failing gn"; fi
  if [ -e "$stamp" ] || [ -e "$stamp.tmp" ]; then bad "T5: a failed stage left a stamp"; fi
  if grep -q '^ninja ' "$STUB_LOG"; then bad "T5: the stage went on to ninja after gn failed"; fi
  return "$FAILED"
}

case_T6() {
  local s=$1 d rc stamp
  . "$s" || true
  set +eu
  FAILED=0
  d=$(mktemp -d -p "$W")
  WORK="$d/work"
  set_paths
  mkdir -p "$SRC"
  WEBRTC_REV=$HEX_A DEPOT_TOOLS_REV=$HEX_B DRY_RUN=0
  export PATH="$STUBS:$PATH" STUB_LOG="$d/log"
  : >"$STUB_LOG"
  stamp="$WORK/.stage-sync.done"
  (set -e; STUB_HEAD=$HEX_C run_stage sync stage_sync) >/dev/null 2>&1
  rc=$?
  if [ "$rc" = 0 ]; then bad "T6: sync passed with src at another commit"; fi
  if [ -e "$stamp" ]; then bad "T6: the failed sync left a stamp"; fi
  if ! grep -qF "gclient sync -r src@$HEX_A -D --no-history" "$STUB_LOG"; then bad "T6: gclient was not asked for src@$HEX_A"; fi
  (set -e; STUB_HEAD=$HEX_A run_stage sync stage_sync) >/dev/null 2>&1
  rc=$?
  if [ "$rc" != 0 ] || [ ! -e "$stamp" ]; then bad "T6: sync failed with src at the pin (rc $rc)"; fi
  return "$FAILED"
}

case_T7() {
  local s=$1 d out rc
  . "$s" || true
  set +eu
  FAILED=0
  d=$(mktemp -d -p "$W")
  WORK="$d/work"
  set_paths
  mkdir -p "$(dirname "$LIB")" "$(dirname "$LINKED")" "$RUN_DIR"
  printf 'lib' >"$LIB"
  printf 'exe' >"$LINKED"

  printf 'LOOPBACK PASS level=-9.1 freq=1000.0\n' >"$LOOPBACK_RESULT"
  out=$(report 2>&1)
  rc=$?
  if [ "$rc" != 0 ]; then bad "T7: a complete PASS run returned rc $rc"; fi
  if [ "$(printf '%s\n' "$out" | sed -n 1p)" != "LIB $LIB 3" ] || [ "$(printf '%s\n' "$out" | sed -n 2p)" != "LINKED $LINKED 3" ] ||
    [ "$(printf '%s\n' "$out" | sed -n 3p)" != "LOOPBACK PASS level=-9.1 freq=1000.0" ]; then
    bad "T7: a complete PASS run did not print the LIB, LINKED and LOOPBACK lines"
  fi

  printf 'LOOPBACK FAIL level=-120.0 freq=0.0\n' >"$LOOPBACK_RESULT"
  out=$(report 2>&1)
  rc=$?
  if [ "$rc" = 0 ]; then bad "T7: a FAIL loopback returned rc 0"; fi

  printf 'LOOPBACK PASS level=-9.1 freq=1000.0\n' >"$LOOPBACK_RESULT"
  rm -f "$LIB"
  out=$(report 2>&1)
  rc=$?
  if [ "$rc" = 0 ]; then bad "T7: a run with no library returned rc 0"; fi
  case $out in *"LIB "*) bad "T7: a run with no library printed a LIB line" ;; esac
  return "$FAILED"
}

CASES="T1 T1b T2 T3 T4 T5 T6 T7"

# run_case <case> <script>: 0 when the case passed; its failure lines go to stdout.
run_case() {
  local c=$1 s=$2 out rc
  out=$( ("case_$c" "$s") 2>&1)
  rc=$?
  if [ "$rc" != 0 ] && [ -n "$out" ]; then printf '%s\n' "$out"; fi
  return "$rc"
}

# Never call run_case from a conditional context (if, ||, &&, !): that switches errexit off in every subshell
# under it, and T5/T6 run stages the way main does, with errexit on.
plain() {
  local s=$1 c rc fails=0
  for c in $CASES; do
    run_case "$c" "$s"
    rc=$?
    if [ "$rc" = 0 ]; then echo "ok   $c"; else echo "FAIL $c"; fails=$((fails + 1)); fi
  done
  return "$fails"
}

# mutant <name> <case> <old> <new>: apply one literal replacement to a copy beside its pin file and loopback.
MUT_FAILS=0
mutant() {
  local name=$1 c=$2 old=$3 new=$4 m dir rc out
  dir=$(mktemp -d -p "$W")
  mkdir -p "$dir/build" "$dir/loopback"
  m="$dir/build/build-libwebrtc.sh"
  cp -- "$TARGET" "$m"
  cp -- "$(dirname -- "$TARGET")/libwebrtc.pin" "$dir/build/"
  cp -- "$(dirname -- "$TARGET")"/../loopback/* "$dir/loopback/" 2>/dev/null || true
  if ! OLD=$old NEW=$new python3 -c '
import os, sys
p = sys.argv[1]
s = open(p).read()
old, new = os.environ["OLD"], os.environ["NEW"]
if s.count(old) != 1:
    sys.exit(1)
open(p, "w").write(s.replace(old, new))
' "$m"; then
    echo "FAIL mutant $name: its text is not in the script exactly once (it did not apply)"
    MUT_FAILS=$((MUT_FAILS + 1))
    return
  fi
  if cmp -s "$TARGET" "$m"; then
    echo "FAIL mutant $name: it did not change the file"
    MUT_FAILS=$((MUT_FAILS + 1))
    return
  fi
  if [ "$c" = control ]; then
    out=$(plain "$m")
    rc=$?
    if [ "$rc" = 0 ]; then echo "SURVIVED (control) $name"; else echo "FAIL control $name was convicted:"; printf '%s\n' "$out"; MUT_FAILS=$((MUT_FAILS + 1)); fi
    return
  fi
  out=$(run_case "$c" "$m")
  rc=$?
  if [ "$rc" != 0 ]; then
    echo "CONVICTED $name by $c: $(printf '%s\n' "$out" | head -n 1 | sed 's/^ *//')"
  else
    echo "FAIL mutant $name SURVIVED $c"
    MUT_FAILS=$((MUT_FAILS + 1))
  fi
}

echo "== test-build-libwebrtc: $TARGET"
plain "$TARGET"
PLAIN_FAILS=$?
if [ "$PLAIN_FAILS" != 0 ]; then
  echo "FAIL: $PLAIN_FAILS case(s) failed"
  exit 1
fi
if [ "$MUTATE" = 0 ]; then
  echo "PASS: all cases"
  exit 0
fi

NL=$'\n'
mutant base-prefix-check-removed T1 \
  "  case \"\$p/\" in${NL}    \"\$b\"/?*/) ;;${NL}    *) refuse \"not-under-base (\$1 resolves to \$p, which is not strictly under \$b/)\"; return 2 ;;${NL}  esac${NL}" ''
mutant home-refusal-removed T1 \
  "  case \"\$p/\" in${NL}    \"\$h\"/*) refuse \"under-home (\$1 resolves to \$p, inside the home \$h)\"; return 2 ;;${NL}  esac${NL}" ''
mutant main-base-is-mnt T1b \
  'root_ok "$root" /mnt/build "$HOME"' 'root_ok "$root" /mnt "$HOME"'
mutant hex-check-loosened T2 \
  'pin_ok() { [[ $1 =~ ^[0-9a-f]{40}$ ]]; }' 'pin_ok() { [ -n "$1" ]; }'
mutant tmpdir-not-exported T3 \
  '  export TMPDIR="$w/tmp"' '  TMPDIR="$w/tmp"'
mutant home-not-redirected T3 \
  "  export HOME=\"\$w/home\"${NL}" ''
mutant sync-pin-dropped T4 \
  'gclient sync -r "src@$WEBRTC_REV" -D --no-history' 'gclient sync -D --no-history'
mutant stamp-without-pins T5 \
  'stamp_current() { [ -f "$1" ] && [ "$(cat -- "$1")" = "$(stamp_body)" ]; }' 'stamp_current() { [ -f "$1" ]; }'
mutant rev-parse-check-removed T6 \
  "  if [ \"\$head\" != \"\$WEBRTC_REV\" ]; then${NL}    fail \"sync: src is at \$head, not the pin \$WEBRTC_REV\"${NL}  fi${NL}" ''
mutant fail-loopback-rc0 T7 \
  "  if [[ \$line != \"LOOPBACK PASS \"* ]]; then rc=1; fi${NL}" ''
mutant comment-wording control \
  '# pin_ok <value>: a full commit id, 40 lowercase hex.' '# pin_ok <value>: one full commit id of 40 lowercase hex digits.'

if [ "$MUT_FAILS" != 0 ]; then
  echo "FAIL: $MUT_FAILS mutant check(s) failed"
  exit 1
fi
echo "PASS: all cases; 10 mutants convicted, the control survived"
