#!/usr/bin/env bash
# test-sms-marker-reset.sh [<nowhere_roamd.sh>] [--mutate] -- NWP-20261010-13: roamd's roam-in clears the SMS-app apply
# marker, and never the SMS-app record.
#
# WHY THIS IS COMMITTED. The chooser records the profile's SMS app (nowhere-sms) only once this session's sign-in apply
# wrote nowhere-sms-applied (SmsRoleRoam). Both live in the chooser's CE dir, so both seal, roam and are restored. The
# marker names its session by the user's serial number, a per-DEVICE counter: one sealed on another handset can carry
# the serial this handset just minted, and would forge "applied" before this session applied anything -- the capture
# would then record the fresh user's Messaging over the profile's choice. The `in` op's rm is the primary defence. And
# the RECORD must never be reaped there: it is the profile's choice, and removing it at roam-in would reset every user
# to Messaging at every sign-in, which is exactly what the 2026-10-11 decision ended.
#
# The `in` op is extracted BY ANCHOR (`  in)` to its first `    ;;`) and read without its comment lines, so an rm that
# survives only in a comment reads as absent. The rm line itself is EXECUTED against a scratch CE dir: it must remove a
# planted marker and leave a planted record.
#
#   bash test-sms-marker-reset.sh            # the checks
#   bash test-sms-marker-reset.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail
MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

RM='      rm -f "$USERDIR/com.nowhere.chooser/files/nowhere-sms-applied" 2>>"$LOG"'
OKL='      echo "OK $uid" > "$RES"; _inres=OK'
# the CE vault restore: the rm must come AFTER it, or the restore untars the marker straight back
RESTORE='    elif od_shipped_prep && NOWHERE_PARK_KEEP="$(od_park_var keep)" NOWHERE_PARK_SHIPPED="$(od_park_var shipped)" NOWHERE_UNFETCHED_LIST="$(od_park_var ce)" NOWHERE_PHASE=apps NOWHERE_CLAIMS_SEED="$STATE/claims.seed" "$AGENT" restore s3 "$name" "$(pw "$pass")" "$USERDIR" >> "$LOG" 2>&1; then'
# the `in` op, numbered, comment lines dropped (a line whose first non-blank character is #)
IN=$(awk '/^  in\)$/{on=1} on{print NR": "$0} on && /^    ;;$/{exit}' "$SUT" | grep -vE '^[0-9]+: [[:space:]]*#')
CODE=$(printf '%s\n' "$IN" | sed -E 's/^[0-9]+: //')
# lineof <exact line>: the roamd line number of that exact code line in the in op, or empty
lineof(){ printf '%s\n' "$IN" | awk -v want="$1" '{ n = $0; sub(/^[0-9]+: /, "", n); if (n == want) { split($0, a, ":"); print a[1]; exit } }'; }
L_RM=$(lineof "$RM")
L_OK=$(lineof "$OKL")
L_RESTORE=$(lineof "$RESTORE")

echo "== the in op clears the marker =="
if [ "$(printf '%s\n' "$CODE" | grep -cxF -- "$RM")" = 1 ]; then ok "the in op removes nowhere-sms-applied (once, as code)"; else no "the in op does not remove nowhere-sms-applied as code -- a marker from another handset forges 'applied'"; fi
if [ "$(printf '%s\n' "$CODE" | grep -cxF -- "$RESTORE")" = 1 ] && [ -n "$L_RM" ] && [ "$L_RM" -gt "$L_RESTORE" ]; then ok "it is removed AFTER the CE vault restore (line $L_RESTORE < $L_RM), which would otherwise untar it straight back"; else no "the marker is removed before the CE restore, or the restore anchor is not there exactly once (restore ${L_RESTORE:-none}, rm ${L_RM:-none})"; fi
if [ -n "$L_RM" ] && [ -n "$L_OK" ] && [ "$L_RM" -lt "$L_OK" ]; then ok "it is removed before the in op answers OK (line $L_RM < $L_OK), so before the chooser can capture"; else no "the marker is removed after the OK, or not at all (rm ${L_RM:-none}, OK ${L_OK:-none})"; fi

echo "== the rm, executed =="
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/u/com.nowhere.chooser/files"
printf 'session=7\nstate=applied\napplied=a.b\ntarget=a.b\n' > "$T/u/com.nowhere.chooser/files/nowhere-sms-applied"
printf 'app=a.b\n' > "$T/u/com.nowhere.chooser/files/nowhere-sms"
line=$(printf '%s\n' "$CODE" | grep -F 'nowhere-sms' | grep -E '^[[:space:]]*rm ' | head -1)
( USERDIR="$T/u"; LOG="$T/log"; eval "$line" )
if [ ! -e "$T/u/com.nowhere.chooser/files/nowhere-sms-applied" ]; then ok "the marker is gone"; else no "the rm left the marker"; fi
if [ -f "$T/u/com.nowhere.chooser/files/nowhere-sms" ] && [ "$(cat "$T/u/com.nowhere.chooser/files/nowhere-sms")" = "app=a.b" ]; then ok "the record is untouched"; else no "the rm took the profile's SMS-app record"; fi

echo "== the record is never reaped =="
# Never `| grep -q` under pipefail: grep -q exits at its first match, the writer upstream takes SIGPIPE, and the
# pipeline answers 141 -- which made the control below fail and, here, would read as "no match" (fail OPEN).
if ! grep -vE '^[[:space:]]*#' "$SUT" | grep -E 'rm |mv |truncate|: >' | grep -E 'nowhere-sms("|[[:space:]]|$|\*)' >/dev/null; then
  ok "no code line in roamd removes, moves or truncates nowhere-sms (the record)"
else
  no "a roamd code line removes nowhere-sms, the profile's SMS-app record: $(grep -vE '^[[:space:]]*#' "$SUT" | grep -E 'rm |mv |truncate|: >' | grep -E 'nowhere-sms("|[[:space:]]|$|\*)' | head -1)"
fi
# control: the scanner must see the marker's own rm, else "no line removes the record" proves nothing
if grep -vE '^[[:space:]]*#' "$SUT" | grep -E 'rm ' | grep 'nowhere-sms-applied' >/dev/null; then ok "control: the scan sees the marker's rm"; else no "control: the scan does not even see the marker's rm"; fi

if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each MUST be convicted) =="
  M=$(mktemp -d)
  mutate(){
    if ! sed "$2" "$SUT" > "$M/r.sh" 2>"$M/err"; then no "MUTATION BROKEN (sed): $1"; return; fi
    if cmp -s "$SUT" "$M/r.sh"; then no "MUTATION INERT: $1"; return; fi
    if bash "$0" "$M/r.sh" >/dev/null 2>&1; then no "NOT CONVICTED: $1 -- suite passes on broken code"; else ok "convicted: $1"; fi
  }
  mutate "the marker rm dropped"            '/^      rm -f "\$USERDIR\/com.nowhere.chooser\/files\/nowhere-sms-applied" 2>>"\$LOG"$/d'
  mutate "the marker rm commented out"      's/^      rm -f "\$USERDIR\/com.nowhere.chooser\/files\/nowhere-sms-applied" 2>>"\$LOG"$/      # &/'
  mutate "the marker rm after the OK"       '/^      rm -f "\$USERDIR\/com.nowhere.chooser\/files\/nowhere-sms-applied" 2>>"\$LOG"$/d; s/^      echo "OK \$uid" > "\$RES"; _inres=OK$/&\n      rm -f "$USERDIR\/com.nowhere.chooser\/files\/nowhere-sms-applied" 2>>"$LOG"/'
  mutate "the record removed instead"       's/nowhere-sms-applied" 2>>"\$LOG"$/nowhere-sms" 2>>"$LOG"/'
  mutate "the record removed as well"       's/^      rm -f "\$USERDIR\/com.nowhere.chooser\/files\/nowhere-sms-applied" 2>>"\$LOG"$/&\n      rm -f "$USERDIR\/com.nowhere.chooser\/files\/nowhere-sms" 2>>"$LOG"/'
  mutate "the rm moved to the top of the in op, before the restore" '/^      rm -f "\$USERDIR\/com.nowhere.chooser\/files\/nowhere-sms-applied" 2>>"\$LOG"$/d; s/^  in)$/&\n      rm -f "$USERDIR\/com.nowhere.chooser\/files\/nowhere-sms-applied" 2>>"$LOG"/'
  mutate "the rm moved out of the in op"    '/^      rm -f "\$USERDIR\/com.nowhere.chooser\/files\/nowhere-sms-applied" 2>>"\$LOG"$/d; s/^case "\$op" in$/rm -f "$USERDIR\/com.nowhere.chooser\/files\/nowhere-sms-applied" 2>>"$LOG"\n&/'
  rm -rf "$M"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
