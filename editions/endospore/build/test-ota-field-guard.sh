#!/usr/bin/env bash
# test-ota-field-guard.sh [--mutate] -- build-device.sh --release refuses an OTA stamp the field already has (NWP-20261101-06).
#
# A second build under a version already published is unreachable over the air (the #732 hotfix, 2026-08-18). These run a
# COPY of ota-field-guard.sh in a scratch repo layout against a stub agent that answers `ota-check` per
# NOWHERE_OTA_VERSION_REF from a fixture table, under every shell found (bash, sh, dash, mksh), and read build-device.sh as
# data to prove the guard sits inside the --release condition and ahead of PREP, finalize and the passphrase prompt.
#
#   bash test-ota-field-guard.sh             # the gates
#   bash test-ota-field-guard.sh --mutate    # ... plus mutants that must each CONVICT the suite under every shell
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="$HERE/ota-field-guard.sh"; BUILD="$HERE/build-device.sh"
[ -f "$GUARD" ] || { echo "no such file: $GUARD (the guard does not exist)" >&2; exit 2; }
[ -f "$BUILD" ] || { echo "no such file: $BUILD" >&2; exit 2; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT

SHELLS=""
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done

# layout <dir> <guard-src> <ring-conf-body>: scratch repo with the guard, one ring conf, a stub agent and a store conf.
layout() {
  local T="$1"
  mkdir -p "$T/editions/endospore/build" "$T/core/vendor-common/etc/rings" "$T/fx"
  cp "$2" "$T/editions/endospore/build/ota-field-guard.sh"
  printf '%s' "$3" > "$T/core/vendor-common/etc/rings/beta.conf"
  printf 'S3_ENDPOINT=x\nS3_REGION=x\nS3_BUCKET=x\nS3_ACCESS_KEY=x\nS3_SECRET_KEY=x\n' > "$T/conf"
  cat > "$T/agent" <<'AGENT'
#!/bin/sh
T=$(dirname "$0")
[ "$1" = ota-check ] || exit 0
f="$T/fx/$(printf '%s' "$NOWHERE_OTA_VERSION_REF" | tr '/' '_')"
[ -f "$f" ] || { echo "ota-check: no published OS version"; exit 3; }
v=$(cat "$f")
case "$v" in
  unreadable) echo "ota-check: store unreachable" >&2; exit 2 ;;
  up:*) echo "ota-check: UPDATE -> ${v#up:}"; exit 0 ;;
  *)    echo "ota-check: UPTODATE (latest $v)"; exit 1 ;;
esac
AGENT
  chmod +x "$T/agent"
}
# fx <dir> <stable> <beta> [<canary>]: a fixture value, "-" or unset for absent.
fx() {
  rm -f "$1/fx/"*
  [ "$2" = - ] || printf '%s' "$2" > "$1/fx/ota_lynx_version"
  [ "$3" = - ] || printf '%s' "$3" > "$1/fx/ota_lynx_version-beta"
  [ "${4:--}" = - ] || printf '%s' "$4" > "$1/fx/ota_lynx_version-canary"
}
# BETA_CONF still names beta (the guard must read it once); NORING_CONF names no ring (beta is read as a retired ring);
# CANARY_CONF names a third ring, the only thing that convicts a guard whose OTA_RING loop adds nothing.
BETA_CONF=$'OTA_RING=beta\nOTHER=1\n'
NORING_CONF=$'OTHER=1\n'
CANARY_CONF=$'OTA_RING=canary\n'

# gate <label> <guard-src> <ring-conf> <stable> <beta> <stamp> <want-rc> <shell> [<canary>]: 0 when the guard exits <want-rc>.
gate() {
  local T="$W/g.$$.$RANDOM" rc out
  layout "$T" "$2" "$3"; fx "$T" "$4" "$5" "${9:--}"
  out=$("$8" "$T/editions/endospore/build/ota-field-guard.sh" lynx "$6" "$T/conf" "$T/agent" 2>&1); rc=$?
  rm -rf "$T"
  GOUT="$out"
  [ "$rc" = "$7" ]
}

# cases <guard-src> <shell> -> number of failing cases (printed lines when VERBOSE=1).
cases() {
  local g="$1" sh="$2" bad=0
  chk() { # label want-rc stable beta stamp [ring-conf [canary]]
    if gate "$1" "$g" "${6-$BETA_CONF}" "$3" "$4" "$5" "$2" "$sh" "${7:--}"; then [ "${VERBOSE:-0}" = 1 ] && ok "[$sh] $1"
    else bad=$((bad+1)); [ "${VERBOSE:-0}" = 1 ] && { no "[$sh] $1 (want exit $2)"; printf '%s\n' "$GOUT" | sed 's/^/        /'; }; fi
  }
  chk "stamp above every ring -> 0"                      0 0.5.47 0.5.46 0.5.48
  chk "stamp equal to stable -> 1"                       1 0.5.48 0.5.46 0.5.48
  chk "stamp below beta -> 1"                            1 0.5.40 0.5.50 0.5.48
  chk "stamp equal to beta -> 1"                         1 0.5.40 0.5.48 0.5.48
  chk "beta absent, stable below -> 0"                   0 0.5.47 -      0.5.48
  chk "beta absent, stable equal -> 1"                   1 0.5.48 -      0.5.48
  chk "UPDATE line read like UPTODATE -> 1"              1 up:0.5.48 -   0.5.48
  chk "beta unreadable, stamp above stable -> 2"         2 0.5.47 unreadable 0.5.48
  chk "stable unreadable, stamp above beta -> 2"         2 unreadable 0.5.40 0.5.48
  chk "no ring present -> 0"                             0 -      -      0.5.48
  chk "a numeric 0.5.9 vs 0.5.10 compare is semver -> 0" 0 0.5.9 -        0.5.10
  chk "a bad OTA_RING value is refused -> 2"             2 0.5.47 0.5.46 0.5.48 $'OTA_RING=Be-ta\n'
  chk "an OTA_RING value with a space is refused -> 2"   2 0.5.47 0.5.46 0.5.48 $'OTA_RING=beta bad\n'
  chk "an OTA_RING value with a tab is refused -> 2"     2 0.5.47 0.5.46 0.5.48 $'OTA_RING=beta\tbad\n'
  chk "an empty OTA_RING value is refused -> 2"          2 0.5.47 0.5.46 0.5.48 $'OTA_RING=\n'
  chk "a trailing empty OTA_RING after a valid one is refused -> 2" 2 0.5.47 0.5.46 0.5.48 $'OTA_RING=beta\nOTA_RING=\n'
  chk "beta (retired) above stamp, no OTA_RING -> 1"     1 0.5.47 0.5.50 0.5.48 "$NORING_CONF"
  chk "beta (retired) equal to stamp, no OTA_RING -> 1"  1 0.5.40 0.5.48 0.5.48 "$NORING_CONF"
  chk "beta (retired) absent, stable below, no OTA_RING -> 0" 0 0.5.47 -  0.5.48 "$NORING_CONF"
  chk "beta (retired) unreadable, no OTA_RING -> 2"      2 0.5.47 unreadable 0.5.48 "$NORING_CONF"
  chk "canary (OTA_RING=canary) above stamp -> 1"        1 0.5.47 -      0.5.48 "$CANARY_CONF" 0.5.50
  chk "canary (OTA_RING=canary) absent -> 0"             0 0.5.47 -      0.5.48 "$CANARY_CONF" -
  # A conf that still says OTA_RING=beta must not read beta twice.
  local n
  gate "beta read once" "$g" "$BETA_CONF" 0.5.47 0.5.46 0.5.48 0 "$sh"; n=$(printf '%s\n' "$GOUT" | grep -c "'beta' ring publishes")
  if [ "$n" = 1 ]; then [ "${VERBOSE:-0}" = 1 ] && ok "[$sh] beta read once with OTA_RING=beta"
  else bad=$((bad+1)); [ "${VERBOSE:-0}" = 1 ] && no "[$sh] beta read $n times with OTA_RING=beta (want 1)"; fi
  return "$bad"
}

echo "shells: $SHELLS"
for sh in $SHELLS; do
  ( VERBOSE=1 cases "$GUARD" "$sh" ) >"$W/o" 2>&1; cat "$W/o"
  n=$(grep -c '  FAIL  ' "$W/o")
  [ "$n" = 0 ] && ok "[$sh] all guard cases" || no "[$sh] $n guard case(s) failed"
done

# The secret never reaches the output: a store conf with a recognisable secret, a refusal and a pass.
T="$W/sec"; layout "$T" "$GUARD" "$BETA_CONF"; fx "$T" 0.5.48 -
printf 'S3_ACCESS_KEY=ACCESSMARK\nS3_SECRET_KEY=SECRETMARK\nS3_ENDPOINT=x\nS3_REGION=x\nS3_BUCKET=x\n' > "$T/conf"
out=$(bash "$T/editions/endospore/build/ota-field-guard.sh" lynx 0.5.48 "$T/conf" "$T/agent" 2>&1)
case "$out" in *ACCESSMARK*|*SECRETMARK*) no "the store conf's secrets reach the output" ;; *) ok "the store conf's secrets do not reach the output" ;; esac

# build-device.sh source check: <build-device.sh> -> 0 when the guard call is inside --release and ahead of PREP/finalize.
src_check() {
  local f="$1" call prep fin cond
  call=$(grep -n 'ota-field-guard.sh' "$f" | grep -v '^[0-9]*:#' | head -1 | cut -d: -f1)
  [ -n "$call" ] || return 1
  prep=$(grep -n '^if \[ "\$PREP" = 1 \]; then' "$f" | head -1 | cut -d: -f1)
  fin=$(grep -n 'script/finalize.sh' "$f" | grep -v '^[0-9]*:#' | head -1 | cut -d: -f1)
  [ -n "$prep" ] && [ -n "$fin" ] && [ "$call" -lt "$prep" ] && [ "$call" -lt "$fin" ] || return 1
  cond=$(head -n "$call" "$f" | grep -n '^if ' | tail -1)
  case "$cond" in *'"$DO_RELEASE" = 1 ]; then') ;; *) return 1 ;; esac
  # ...and the block that holds the call is still open at the call (no `fi` at column 0 between it and the call).
  local from=${cond%%:*}
  [ -z "$(sed -n "$((from+1)),${call}p" "$f" | grep -n '^fi')" ]
}
if src_check "$BUILD"; then ok "build-device.sh: guard call inside --release, before PREP and finalize"
else no "build-device.sh: guard call missing, outside --release, or after PREP/finalize"; fi
refuse=$(grep -c 'NOWHERE_OTA_STORE_CONF' "$BUILD")
[ "$refuse" -ge 2 ] && ok "build-device.sh names NOWHERE_OTA_STORE_CONF in its refusal" || no "build-device.sh does not name NOWHERE_OTA_STORE_CONF"

if [ "$MUTATE" = yes ]; then
  echo "-- mutants (each must CONVICT the suite, under every shell) --"
  mut_guard() { # label sed-expr
    local label="$1" expr="$2" m="$W/mut.sh" sh convicted
    sed "$expr" "$GUARD" > "$m"
    if cmp -s "$GUARD" "$m"; then no "$label: mutant did not apply"; return; fi
    for sh in $SHELLS; do
      convicted=no
      ( VERBOSE=1 cases "$m" "$sh" ) >"$W/mo" 2>&1
      grep -q '  FAIL  ' "$W/mo" && convicted=yes
      [ "$convicted" = yes ] && ok "$label convicted under $sh" || no "$label SURVIVED under $sh"
    done
  }
  mut_guard "V1 '>=' instead of strictly above" 's/^if \[ -n "\$MAX" \] && ! vlt "\$MAX" "\$STAMP"; then$/if [ -n "$MAX" ] \&\& vlt "$STAMP" "$MAX"; then/'
  mut_guard "V2 an unreadable ring skipped as absent"  's/^      3) echo "ota-field-guard: \$DEV/      3|4) echo "ota-field-guard: $DEV/'
  mut_guard "V3 an OTA_RING ring not read"                    's/^    case " \$RINGS " in \*" \$r "\*) ;; \*) RINGS="\$RINGS \$r" ;; esac$/    case " $RINGS " in *" $r "*) ;; *) ;; esac/'
  mut_guard "V5 the retired beta ring not read"         's/^RETIRED_RINGS="beta"$/RETIRED_RINGS=""/'
  # V4: the build-device.sh call removed.
  m="$W/mut-build.sh"
  grep -v 'ota-field-guard.sh\|"\$(tr -d .\[:space:\]. < "\$REPO/core/vendor-common/etc/nowhere-ota-version")"' "$BUILD" > "$m"
  if cmp -s "$BUILD" "$m"; then no "V4 mutant did not apply"
  elif src_check "$m"; then no "V4 the build-device.sh call removed SURVIVED"
  else ok "V4 the build-device.sh call removed convicted"; fi
fi

echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" = 0 ]
