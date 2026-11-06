#!/usr/bin/env bash
# test-support-end.sh [<build-dir>] [--mutate] -- a build refuses a device past its GrapheneOS full-support date
# (NWP-20261125-02, h55 #2 in docs/product-decisions.md).
#
# h55 #2: editions/endospore/devices/<device>/support-end carries the date full support ends, with its source, and
# build-device.sh refuses to build that device past it. This runs support-end-guard.sh under every shell found (bash, sh,
# dash, mksh) against fixture files (either side of a month and of a day, malformed files, days not on the calendar, a
# missing file for a dev build and a --release, another device's file, bad arguments); reads build-device.sh's call as
# data (once, outside a comment, under no if, after REPO= and before the ring lookup, the verified-commit guard, PREP
# and the log tee); runs build-device.sh from the REPO= line through the call by anchor against a fixture repo; and
# parses every committed support-end file. A missing anchor is a FAIL, never a pass.
#
#   bash test-support-end.sh             # the gates
#   bash test-support-end.sh --mutate    # ... plus mutants that must each CONVICT the suite
set -uo pipefail

MUTATE=no; DIR=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; -*) echo "usage: $0 [<build-dir>] [--mutate]" >&2; exit 2 ;; *) DIR="$a" ;; esac; done
DIR="${DIR:-$(cd "$(dirname "$0")" && pwd)}"
# The committed tree is read from here even when <build-dir> holds a mutant copy.
ROOT="${SE_TEST_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
BD="$DIR/build-device.sh"; GUARD="$DIR/support-end-guard.sh"
[ -f "$BD" ] || { echo "no such file: $BD" >&2; exit 2; }
[ -f "$GUARD" ] || { echo "no such file: $GUARD" >&2; exit 2; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT

SHELLS="${SE_TEST_SHELLS:-}"
if [ -z "$SHELLS" ]; then
  for s in bash sh dash mksh; do
    if command -v "$s" >/dev/null 2>&1; then SHELLS="$SHELLS $s"; else echo "  note  $s not found: its cases run in CI only"; fi
  done
fi

CALL='sh "$REPO/editions/endospore/build/support-end-guard.sh" "$REPO" "$DEV" "$(date -u +%F)" "$( [ "$DO_RELEASE" = 1 ] && echo release || echo dev )" || exit $?'
REPOLINE='REPO="${ENDOSPORE_REPO:-/mnt/build/nowhere-phone}"'
KINDLINE='KIND=dev; [ "$DO_RELEASE" = 1 ] && KIND=release'
SRC='a public page'

# run <shell> <repo> <device> <today> <kind...> -> RC, OUT, ERR
run() {
  local s="$1"; shift
  "$s" "$GUARD" "$@" >"$W/o" 2>"$W/e"; RC=$?
  OUT=$(cat "$W/o"); ERR=$(cat "$W/e")
}
# fx <repo> <device> <body>: write the device's support-end file (body as given, with printf escapes).
fx() { mkdir -p "$1/editions/endospore/devices/$2"; printf "$3" > "$1/editions/endospore/devices/$2/support-end"; }
# want <label> <rc> [<stream> <text>]...: RC is <rc> and each named stream (out|err) holds its text.
want() {
  local label="$1" rc="$2" stream text got; shift 2
  if [ "$RC" != "$rc" ]; then no "$label (rc=$RC, want $rc) $ERR"; return; fi
  while [ "$#" -ge 2 ]; do
    stream="$1"; text="$2"; shift 2
    if [ "$stream" = out ]; then got="$OUT"; else got="$ERR"; fi
    if [[ "$got" != *"$text"* ]]; then no "$label: $stream lacks '$text': $got"; return; fi
  done
  ok "$label"
}

guard_cases() {
  local s R f d
  for s in $SHELLS; do
    R=$(mktemp -d -p "$W")
    fx "$R" fxm "# a comment\nlast-supported 2028-05\nsource $SRC\n"
    f="$R/editions/endospore/devices/fxm/support-end"
    run "$s" "$R" fxm 2028-05-31 release; want "[$s] month: last day of the month -> 0" 0 out "support: fxm full support through 2028-05"
    run "$s" "$R" fxm 2028-05-01 dev; want "[$s] month: first day of the month -> 0" 0
    run "$s" "$R" fxm 2027-12-31 release; want "[$s] month: earlier year -> 0" 0
    run "$s" "$R" fxm 2028-06-01 release
    want "[$s] month: first day of the next month, release -> 3 naming device, date, source" 3 \
      err "refusing: fxm left GrapheneOS's full support after 2028-05 ($f, source: $SRC); releases stop there (docs/product-decisions.md, h55 #2)"
    if [ -z "$OUT" ]; then ok "[$s] a refusal prints nothing on stdout"; else no "[$s] a refusal printed: $OUT"; fi
    run "$s" "$R" fxm 2028-06-01 dev; want "[$s] month: next month, dev -> 3 (every build kind)" 3 err "after 2028-05"
    run "$s" "$R" fxm 2029-01-15 release; want "[$s] month: later year -> 3" 3
    fx "$R" fxy "last-supported 2028-12\nsource $SRC\n"
    run "$s" "$R" fxy 2029-01-01 dev; want "[$s] month: year rollover -> 3" 3 err "after 2028-12"
    fx "$R" fxd "last-supported 2028-05-14\nsource $SRC\n"
    run "$s" "$R" fxd 2028-05-14 release; want "[$s] day: the same day -> 0" 0 out "support: fxd full support through 2028-05-14"
    run "$s" "$R" fxd 2028-05-15 release; want "[$s] day: the day after -> 3" 3 err "fxd left GrapheneOS's full support after 2028-05-14"
    run "$s" "$R" fxd 2028-06-01 dev; want "[$s] day: a later month -> 3" 3
    fx "$R" fxc "# comment\r\n\r\nlast-supported 2031-01\r\n# between\r\nsource $SRC\r\n"
    run "$s" "$R" fxc 2027-01-01 release; want "[$s] CRLF, comments and blank lines -> 0" 0 out "through 2031-01"
    fx "$R" fxn "last-supported 2031-01\nsource $SRC"
    run "$s" "$R" fxn 2027-01-01 release; want "[$s] no final newline -> 0" 0 out "through 2031-01"
    # Malformed: refused for both kinds, naming the file.
    fx "$R" bad1 "last-supported 2028-05\n"
    run "$s" "$R" bad1 2027-01-01 dev; want "[$s] malformed: one data line -> 3" 3 err "$R/editions/endospore/devices/bad1/support-end is malformed"
    fx "$R" bad2 "last-supported 2028-13\nsource $SRC\n"
    run "$s" "$R" bad2 2027-01-01 dev; want "[$s] malformed: month 13 -> 3" 3 err "bad2/support-end is malformed"
    fx "$R" bad3 "last-supported 28-05\nsource $SRC\n"
    run "$s" "$R" bad3 2027-01-01 release; want "[$s] malformed: short year -> 3" 3 err "is malformed"
    fx "$R" bad4 "last-supported 2028-05\nsource $SRC\nsource again\n"
    run "$s" "$R" bad4 2027-01-01 dev; want "[$s] malformed: a third data line -> 3" 3 err "is malformed"
    fx "$R" bad5 ""
    run "$s" "$R" bad5 2027-01-01 dev; want "[$s] malformed: empty file -> 3" 3 err "is malformed"
    fx "$R" bad6 "last-supported 2028-05\nurl https://example.invalid\n"
    run "$s" "$R" bad6 2027-01-01 dev; want "[$s] malformed: unknown key -> 3" 3 err "is malformed"
    fx "$R" bad7 "source $SRC\nlast-supported 2028-05\n"
    run "$s" "$R" bad7 2027-01-01 dev; want "[$s] malformed: lines out of order -> 3" 3 err "is malformed"
    fx "$R" bad8 "# only a comment\n"
    run "$s" "$R" bad8 2027-01-01 dev; want "[$s] malformed: comments only -> 3" 3 err "is malformed"
    fx "$R" bad9 "last-supported 2028-05\nsource  \n"
    run "$s" "$R" bad9 2027-01-01 dev; want "[$s] malformed: empty source -> 3" 3 err "is malformed"
    fx "$R" bada "last-supported 2028-05-32\nsource $SRC\n"
    run "$s" "$R" bada 2027-01-01 dev; want "[$s] malformed: day 32 -> 3" 3 err "is malformed"
    # Days that are not on the calendar (RF-001): month lengths and leap years.
    for d in 2028-02-31 2029-02-29 2030-04-31 2028-02-30 2031-06-31 2031-09-31 2031-11-31 2100-02-29 1900-02-29; do
      fx "$R" badcal "last-supported $d\nsource $SRC\n"
      run "$s" "$R" badcal 2027-01-01 release
      want "[$s] malformed: $d is not on the calendar -> 3" 3 err "last-supported '$d' is not a day on the calendar"
    done
    for d in 2028-02-29 2000-02-29 2400-02-29 2029-02-28 2030-04-30 2030-12-31 2031-01-31; do
      fx "$R" fxcal "last-supported $d\nsource $SRC\n"
      run "$s" "$R" fxcal 1999-01-01 release; want "[$s] control: $d is on the calendar -> 0" 0 out "through $d"
    done
    run "$s" "$R" fxcal 2027-02-29 dev; want "[$s] today 2027-02-29 not on the calendar -> 2" 2 err "usage:"
    run "$s" "$R" fxcal 2027-04-31 dev; want "[$s] today 2027-04-31 not on the calendar -> 2" 2 err "usage:"
    run "$s" "$R" fxcal 2028-02-29 dev; want "[$s] control: today 2028-02-29 -> 0" 0
    fx "$R" badb "last-supported\nsource $SRC\n"
    run "$s" "$R" badb 2027-01-01 dev; want "[$s] malformed: a key with no value -> 3" 3 err "is malformed"
    mkdir -p "$R/editions/endospore/devices/badc/support-end"
    run "$s" "$R" badc 2027-01-01 dev; want "[$s] malformed: a directory -> 3" 3 err "is malformed"
    # Absent.
    run "$s" "$R" fxabsent 2027-01-01 release
    want "[$s] absent, release -> 3" 3 err "refusing --release: fxabsent has no support-end file ($R/editions/endospore/devices/fxabsent/support-end); add its date and source first"
    run "$s" "$R" fxabsent 2027-01-01 dev; want "[$s] absent, dev -> 0 with a WARNING" 0 err "WARNING: fxabsent has no support-end file"
    # Another device's file has no effect.
    fx "$R" fxpast "last-supported 2000-01\nsource $SRC\n"
    fx "$R" fxfut "last-supported 2031-01\nsource $SRC\n"
    run "$s" "$R" fxfut 2030-01-01 release; want "[$s] another device's past date does not refuse this one -> 0" 0 out "fxfut full support through 2031-01"
    run "$s" "$R" fxpast 2030-01-01 release; want "[$s] control: that device itself -> 3" 3 err "fxpast left"
    # Bad arguments.
    run "$s" "$R" Fxm 2027-01-01 dev; want "[$s] device with a capital -> 2" 2 err "usage:"
    run "$s" "$R" fx/m 2027-01-01 dev; want "[$s] device with a slash -> 2" 2
    run "$s" "$R" ../fxm 2027-01-01 dev; want "[$s] device with .. -> 2" 2
    run "$s" "$R" "" 2027-01-01 dev; want "[$s] empty device -> 2" 2
    run "$s" "$R" fxm 2028-5-1 dev; want "[$s] today not YYYY-MM-DD -> 2" 2
    run "$s" "$R" fxm 2028-13-01 dev; want "[$s] today month 13 -> 2" 2
    run "$s" "$R" fxm 2028-05 dev; want "[$s] today a month -> 2" 2
    run "$s" "$R" fxm 2027-01-01 prod; want "[$s] kind prod -> 2" 2
    run "$s" "$R" fxm 2027-01-01; want "[$s] three arguments -> 2" 2
  done
}

# build-device.sh wiring, read as data. A missing anchor is a FAIL, never a pass.
num() { [[ "$2" =~ ^[0-9]+$ ]] || { no "$1: anchor not found"; return 1; }; }
first_code() { grep -n -- "$1" "$BD" | grep -v '^[0-9]*:[[:space:]]*#' | head -1 | cut -d: -f1; }
wiring_data() {
  local n l_repo l_call l x between
  n=$(grep -cxF -- "$CALL" "$BD")
  if [ "$n" = 1 ]; then ok "the guard call occurs once, whole, outside a comment"; else no "the guard call found $n times as a whole line"; return; fi
  n=$(grep -cxF -- "$REPOLINE" "$BD"); [ "$n" = 1 ] || { no "REPO= line found $n times"; return; }
  l_repo=$(grep -nxF -- "$REPOLINE" "$BD" | cut -d: -f1)
  l_call=$(grep -nxF -- "$CALL" "$BD" | cut -d: -f1)
  if [ "$l_repo" -lt "$l_call" ]; then ok "the call follows REPO="; else no "the call precedes REPO="; fi
  for x in "KIND=dev:$(grep -nxF -- "$KINDLINE" "$BD" | head -1 | cut -d: -f1)" \
           "ring-for-build.sh:$(first_code 'ring-for-build\.sh')" \
           "verified-commit-guard.sh:$(first_code 'verified-commit-guard\.sh')" \
           "PREP block:$(grep -nx 'if \[ "\$PREP" = 1 \]; then' "$BD" | head -1 | cut -d: -f1)" \
           "log tee:$(grep -n '^exec > >(tee' "$BD" | head -1 | cut -d: -f1)"; do
    l="${x##*:}"
    num "${x%:*}" "$l" || continue
    if [ "$l_call" -lt "$l" ]; then ok "the call comes before the ${x%:*}"; else no "the call comes after the ${x%:*} (line $l)"; fi
  done
  between=$(sed -n "$((l_repo+1)),$((l_call-1))p" "$BD")
  if [[ "$between" =~ (^|$'\n')[[:space:]]*if[[:space:]] ]]; then no "an if opens between REPO= and the call"; else ok "no if opens between REPO= and the call"; fi
  if [[ "$(sed -n "${l_call}p" "$BD")" == sh\ * ]]; then ok "the call starts its line (under no if or &&)"; else no "the call does not start its line"; fi
}

# build-device.sh from REPO= through the call, run by anchor against a fixture repo.
wiring_run() {
  local F code dr dev
  F=$(mktemp -d -p "$W")
  mkdir -p "$F/editions/endospore/build"
  cp "$GUARD" "$F/editions/endospore/build/support-end-guard.sh"
  fx "$F" fxp "last-supported 2000-01\nsource $SRC\n"
  fx "$F" fxf "last-supported 9999-12\nsource $SRC\n"
  code=$(awk -v a="$REPOLINE" -v b="$CALL" '$0 == a { on=1 } on { print } on && $0 == b { done=1; exit } END { exit !done }' "$BD") \
    || { no "run by anchor: REPO= or the call line moved"; return; }
  printf '%s\n' 'set -uo pipefail' "$code" 'echo reached' > "$W/wired.sh"
  for dr in 0 1; do
    DEV=fxp DO_RELEASE=$dr ENDOSPORE_REPO="$F" bash "$W/wired.sh" >"$W/o" 2>"$W/e"; RC=$?
    OUT=$(cat "$W/o"); ERR=$(cat "$W/e")
    if [ "$RC" = 3 ] && [[ "$OUT" != *reached* && "$ERR" == *"refusing: fxp left GrapheneOS's full support after 2000-01"* ]]; then
      ok "run by anchor: a past date stops the build (DO_RELEASE=$dr)"
    else no "run by anchor: past date, DO_RELEASE=$dr (rc=$RC out='$OUT') $ERR"; fi
    DEV=fxf DO_RELEASE=$dr ENDOSPORE_REPO="$F" bash "$W/wired.sh" >"$W/o" 2>"$W/e"; RC=$?
    OUT=$(cat "$W/o"); ERR=$(cat "$W/e")
    if [ "$RC" = 0 ] && [[ "$OUT" == *reached* ]]; then ok "run by anchor: control, a future date goes on (DO_RELEASE=$dr)"; else no "run by anchor: future date, DO_RELEASE=$dr (rc=$RC out='$OUT') $ERR"; fi
  done
  dev=fxabsent
  DEV=$dev DO_RELEASE=1 ENDOSPORE_REPO="$F" bash "$W/wired.sh" >"$W/o" 2>"$W/e"; RC=$?
  OUT=$(cat "$W/o"); ERR=$(cat "$W/e")
  if [ "$RC" = 3 ] && [[ "$OUT" != *reached* && "$ERR" == *"refusing --release: $dev has no support-end file"* ]]; then ok "run by anchor: a --release with no file stops"; else no "run by anchor: --release, no file (rc=$RC out='$OUT') $ERR"; fi
}

# The committed files.
real_tree() {
  local d f n=0 s1
  s1=$(set -- $SHELLS; echo "$1")
  for d in lynx husky tegu frankel stallion; do
    run "$s1" "$ROOT" "$d" 1970-01-01 release
    want "committed $d support-end is well formed" 0 out "support: $d full support through "
  done
  for f in "$ROOT"/editions/endospore/devices/*/support-end; do
    [ -e "$f" ] || continue
    n=$((n+1)); d="${f%/support-end}"; d="${d##*/}"
    run "$s1" "$ROOT" "$d" 1970-01-01 release
    want "every committed support-end parses: $d" 0
  done
  if [ "$n" -ge 5 ]; then ok "$n committed support-end files"; else no "only $n committed support-end files"; fi
  # h55 #2: the test names the device and the date. If lynx's date changes, this pin changes with it.
  run "$s1" "$ROOT" lynx 2028-05-31 release; want "lynx is built through 2028-05-31" 0
  run "$s1" "$ROOT" lynx 2028-06-01 release; want "lynx is refused from 2028-06-01" 3 err "lynx left GrapheneOS's full support after 2028-05"
}

gates() { guard_cases; wiring_data; wiring_run; real_tree; }

if [ "$MUTATE" = yes ]; then
  [ "$PASS" -eq 0 ] || exit 2
  M=$(mktemp -d -p "$W"); BAD=0
  # verdict <id> <shells>: re-run the suite against $M under each shell; it must fail.
  verdict() {
    local id="$1" s rc; shift
    for s in "$@"; do
      SE_TEST_ROOT="$ROOT" SE_TEST_SHELLS=$s bash "$0" "$M" >/dev/null 2>&1; rc=$?
      if [ "$rc" != 0 ]; then echo "  ok    convicted $id [$s]"; else echo "  FAIL  NOT CONVICTED $id [$s]"; BAD=$((BAD+1)); fi
    done
  }
  # mut <id> <file> <sed-script>  (guard mutants must be convicted under every shell)
  mut() {
    local id="$1" f="$2" sc="$3"
    cp "$BD" "$M/build-device.sh"; cp "$GUARD" "$M/support-end-guard.sh"
    sed -E "$sc" "$DIR/$f" > "$M/$f"
    if cmp -s "$DIR/$f" "$M/$f"; then echo "  FAIL  MUTANT DID NOT APPLY: $id"; BAD=$((BAD+1)); return; fi
    if [ "$f" = build-device.sh ]; then verdict "$id" bash; else verdict "$id" $SHELLS; fi
  }
  mut V1-call-removed build-device.sh '/^sh "\$REPO\/editions\/endospore\/build\/support-end-guard\.sh" /d'
  mut V2-comparison-inverted support-end-guard.sh 's/LC_ALL=C sort \| tail -n 1\)" = "\$T" \]; then$/LC_ALL=C sort | tail -n 1)" = "$L" ]; then/'
  mut V3-month-compared-as-a-day support-end-guard.sh 's/^case "\$L" in \?\?\?\?-\?\?\) T="\$\{TODAY%-\?\?\}" ;;/case "$L" in ????-??) T="$TODAY" ;;/'
  mut V4-malformed-exits-0 support-end-guard.sh '/is malformed \(\$1\)/{n;s/^  exit 3$/  exit 0/}'
  mut V5-absent-release-exits-0 support-end-guard.sh '/refusing --release: \$DEV has no support-end file/{n;s/^    exit 3$/    exit 0/}'
  mut V6-call-under-if-release build-device.sh 's/^(sh "\$REPO\/editions\/endospore\/build\/support-end-guard\.sh" .*)$/if [ "$DO_RELEASE" = 1 ]; then\n\1\nfi/'
  mut V7-calendar-not-checked support-end-guard.sh 's/^on_calendar\(\) \{$/on_calendar() { return 0/'
  mut V8-leap-year-every-fourth support-end-guard.sh 's/^        \?\?00-\*\) case .*$/        ??00-*) return 0 ;;/'
  [ "$BAD" = 0 ] && echo "all mutants convicted" || echo "$BAD mutant problem(s)"
  [ "$BAD" = 0 ]; exit $?
fi

gates
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
