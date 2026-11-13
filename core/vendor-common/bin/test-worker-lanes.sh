#!/usr/bin/env bash
# test-worker-lanes.sh [<nowhere_roamd.sh>] [--mutate] -- the worker's lane gates, script side.
#
# WHY THIS IS COMMITTED. The lane system is a TWO-SIDED contract enforced twice on purpose: the daemon's
# laneFor decides where an op is sent (guarded by lane_cred_test.go), and the script's allowlists decide
# what each lane will accept -- the script's copy is the one that actually protects the seal, and it holds
# even if a future caller gets the other side wrong (nowhere_roamd.sh says exactly this about the RO lane).
# This file is the script side's guard: the RO lane must refuse credential ops, passphrases and the session's
# chip secret (NWP-20261110-17), the CRED
# lane (NWP-20260903-09, #147) must refuse everything except armcred/rekey, and each lane must keep its OWN
# req/res files -- a shared file re-couples the lanes, which is the defect (a 73.7s keyguard arm behind a
# 125s seal, NW-600f775808fc) reintroduced quietly.
#
# Blocks are extracted from nowhere_roamd.sh BY ANCHOR, never copied; if the anchors move, extraction fails
# loudly rather than a stale copy passing forever.
#
#   bash test-worker-lanes.sh            # the behaviour cases, under every shell found (bash sh dash mksh)
#   bash test-worker-lanes.sh --mutate   # ... plus mutations that must each CONVICT the suite under each shell
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT   # every temp of this run lives under $W

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

# --- extraction -----------------------------------------------------------------------------------------
LANE_CASE=$(sed -n '/^LANE="\${1:-rw}"$/,/^esac$/p' "$SUT")
CRED_GATE=$(sed -n '/^if \[ "\$LANE" = "cred" \]; then$/,/^fi$/p' "$SUT")
RO_GATE=$(sed -n '/^if \[ "\$LANE" = "ro" \]; then$/,/^fi$/p' "$SUT")
case "$LANE_CASE" in *"  cred) REQ="*) ;; *) echo "EXTRACTION FAILED: lane case has no cred entry" >&2; exit 2 ;; esac
case "$CRED_GATE" in *armcred*) ;; *) echo "EXTRACTION FAILED: cred gate" >&2; exit 2 ;; esac
case "$RO_GATE" in *storagebreakdown*) ;; *) echo "EXTRACTION FAILED: ro gate" >&2; exit 2 ;; esac

SHELLS=""
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "no shell to run under" >&2; exit 2; }

# --- harness --------------------------------------------------------------------------------------------
# Run the lane case + both gates under a chosen shell with a chosen lane/op/pass/sesec. The gates refuse by
# writing ERR-LANE to $RES and exiting 0, so they run as their own script; the verdict is read from the RES
# file afterwards. The lane, op and both credentials reach the script as arguments, never spliced into its
# text. The run's log is kept in $W/gate.log and the RES mode in $W/gate.mode (empty when none was written).
gate(){   # gate <shell> <lane> <op> <pass> [<sesec>]  -> prints REFUSED | ALLOWED, plus the REQ basename on line 2
  local T; T=$(mktemp -d -p "$W") && [ -n "$T" ] && [ -d "$T" ] || exit 2
  {
    printf 'cd "$5" || exit 9\n'
    printf 'STATE="$5"; LOG="$5/log"; op="$2"; pass="$3"; sesec="$4"\n'
    printf 'set -- "$1"\n'                       # the script reads its lane from $1
    printf '%s\n' "$LANE_CASE"
    printf 'echo "${REQ##*/}" > "$STATE/reqname"\n'
    printf '%s\n' "$CRED_GATE" "$RO_GATE"
    printf 'echo ran > "$STATE/ran"\n'
  } > "$T/run.sh"
  "$1" "$T/run.sh" "$2" "$3" "$4" "${5:-}" "$T" >/dev/null 2>&1
  local res=""; for f in "$T"/*.res; do [ -f "$f" ] && res=$(cat "$f"); done
  if [ "$res" = ERR-LANE ]; then echo REFUSED; elif [ -f "$T/ran" ]; then echo ALLOWED; else echo BROKEN; fi
  cat "$T/reqname" 2>/dev/null || echo none
  if [ -f "$T/log" ]; then cp "$T/log" "$W/gate.log"; else : > "$W/gate.log"; fi
  : > "$W/gate.mode"; for f in "$T"/*.res; do [ -f "$f" ] && stat -c %a "$f" > "$W/gate.mode"; done
  rm -rf "$T"
}

echo "shells:$SHELLS"
for s in $SHELLS; do
t="[$s]"
is(){ local got; got=$(gate "$s" "$2" "$3" "$4" "${6:-}" | sed -n 1p)   # is <want> <lane> <op> <pass> <label> [<sesec>]
      [ "$got" = "$1" ] && ok "$t $5" || no "$t $5 -- got $got, want $1"; }

echo "== $t the CRED lane accepts exactly its two ops =="
is ALLOWED cred armcred ""  "cred lane accepts armcred"
is ALLOWED cred rekey   ""  "cred lane accepts rekey"
is REFUSED cred out     ""  "cred lane refuses a seal op (out)"
is REFUSED cred in      ""  "cred lane refuses a restore op (in)"
is REFUSED cred storagebreakdown "" "cred lane refuses an RO-lane member"

echo "== $t the RO lane is unchanged =="
is REFUSED ro  armcred ""   "ro lane still refuses armcred (it carries a credential)"
is REFUSED ro  storagebreakdown "x" "ro lane still refuses a passphrase outright"
is ALLOWED ro  storagebreakdown ""  "ro lane still accepts its own member"
is ALLOWED ro  uiderrors ""         "ro lane accepts uiderrors (NWP-20261010-06: the issue report's framework-log read)"
is REFUSED cred uiderrors ""        "cred lane refuses uiderrors (no credential, so it is not that lane's)"
is ALLOWED ro  alarmrelay ""        "ro lane accepts alarmrelay (NWP-20261108-02: a cold lock behind an abandoned RW op still relays)"
is REFUSED ro  alarmrelay "x"       "ro lane refuses a passphrase on alarmrelay (it needs only the uid)"
is REFUSED cred alarmrelay ""       "cred lane refuses alarmrelay (no credential, so it is not that lane's)"
is ALLOWED ro  playrestart ""       "ro lane accepts playrestart (NWP-20261201-10: a health notice's Fix)"
is REFUSED ro  playrestart "x"      "ro lane refuses a passphrase on playrestart (it needs only the uid)"
is REFUSED cred playrestart ""      "cred lane refuses playrestart (no credential, so it is not that lane's)"
is ALLOWED ro  gmsstate ""          "ro lane accepts gmsstate (NWP-20261201-01: the issue report's Play services dumps)"
is REFUSED ro  gmsstate "x"         "ro lane refuses a passphrase on gmsstate (it needs only the uid)"
is REFUSED cred gmsstate ""         "cred lane refuses gmsstate (no credential, so it is not that lane's)"
is ALLOWED ro  gmsexits ""          "ro lane accepts gmsexits (NWP-20261201-02: the issue report's Play services exit records)"
is REFUSED ro  gmsexits "x"         "ro lane refuses a passphrase on gmsexits (it needs only the uid)"
is REFUSED cred gmsexits ""         "cred lane refuses gmsexits (no credential, so it is not that lane's)"
is ALLOWED ro  healthprobe ""       "ro lane accepts healthprobe (NWP-20261201-08: the health checks' one dumpsys read)"
is REFUSED ro  healthprobe "x"      "ro lane refuses a passphrase on healthprobe (it needs only the uid)"
is REFUSED cred healthprobe ""      "cred lane refuses healthprobe (no credential, so it is not that lane's)"
is ALLOWED ro  vpnstate ""          "ro lane accepts vpnstate (NWP-20261202-43: the issue report's always-on VPN read)"
is REFUSED ro  vpnstate "x"         "ro lane refuses a passphrase on vpnstate (it needs only the uid)"
is REFUSED cred vpnstate ""         "cred lane refuses vpnstate (no credential, so it is not that lane's)"

echo "== $t no credential reaches the RO lane: not the passphrase, not the chip secret (NWP-20261110-17) =="
# Line 5 carries the session's SE secret, which opens a TIED profile's vault, #de and #sys exactly as the
# passphrase does (docs/se-binding.md). SECRET is a fixture, not key material.
SECRET=5ec0e7f1c7ec0ffee5ec0e7f1c7ec0ffee5ec0e7f1c7ec0ffee5ec0e7f1c7ec0
is REFUSED ro  storagebreakdown "" "W1 ro lane refuses the session's chip secret on storagebreakdown" "$SECRET"
is REFUSED ro  uiderrors        "" "W2 ro lane refuses the session's chip secret on uiderrors" "$SECRET"
is ALLOWED ro  sealdelta        "" "W3 ro lane accepts sealdelta carrying neither credential"
is ALLOWED cred armcred         "" "W4 cred lane still accepts armcred with line 5 set (it is not narrowed)" "$SECRET"
v=$(gate "$s" ro storagebreakdown "" "$SECRET" | sed -n 1p); lg=$(cat "$W/gate.log" 2>/dev/null); md=$(cat "$W/gate.mode" 2>/dev/null)
case "$lg" in
  *"$SECRET"*)                                                no "$t W5 the chip-secret refusal line prints the secret" ;;
  *"ro-lane REFUSED op=storagebreakdown -- a chip secret"*)
    if [ "$v" = REFUSED ] && [ "$md" = 600 ]; then ok "$t W5 the chip-secret refusal is logged without the secret, RES ERR-LANE mode 600"
    else no "$t W5 the chip-secret refusal answered [$v] with RES mode [$md], want REFUSED and 600"; fi ;;
  *)                                                          no "$t W5 no chip-secret refusal was logged -- got '$lg'" ;;
esac

echo "== $t the RW lane gates nothing here =="
is ALLOWED rw  out ""       "rw lane accepts a seal op (its slot is the guard, not a gate)"

echo "== $t each lane keeps its OWN req file =="
q=$(gate "$s" cred armcred "" | sed -n 2p)
[ "$q" = "roamcred.req" ] && ok "$t cred lane uses roamcred.req" || no "$t cred lane REQ is '$q' -- a shared req file re-couples the lanes"
q=$(gate "$s" ro storagebreakdown "" | sed -n 2p)
[ "$q" = "roamro.req" ] && ok "$t ro lane uses roamro.req" || no "$t ro lane REQ is '$q'"
done

echo "== [static] userdir_recheck's guard comment names exactly the RO allowlist =="
# The comment is why the call is guarded to the RW lane; an RO op it does not name reads as safe to run unguarded.
# It is text, not behaviour, so it is read once rather than per shell.
ro_ops=$(printf '%s\n' "$RO_GATE" | sed -n 's/^    \([a-z|]*\)) ;;$/\1/p' | tr '|' '\n' | sort)
cm_ops=$(sed -n "/^#/s/.*the read-only lane's ops (\([^)]*\)) are arms of that.*/\1/p" "$SUT" | tr -d ' ' | tr ',' '\n' | sort)
if [ -n "$ro_ops" ] && [ "$ro_ops" = "$cm_ops" ]; then ok "[static] the comment lists $(echo $ro_ops)"
else no "[static] the comment lists '$(echo $cm_ops)', the RO allowlist is '$(echo $ro_ops)'"; fi

# --- mutations ------------------------------------------------------------------------------------------
if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each MUST be convicted) =="
  M=$(mktemp -d -p "$W")
  mutate(){   # mutate <label> <sed script> [static] -- a behaviour mutant must FAIL a line under EACH shell
    local rc sh bad=""
    if ! sed "$2" "$SUT" > "$M/m.sh" 2>"$M/err"; then no "MUTATION BROKEN (sed): $1"; return; fi
    if cmp -s "$SUT" "$M/m.sh"; then no "MUTATION INERT: $1"; return; fi
    bash "$0" "$M/m.sh" > "$M/out" 2>&1; rc=$?
    if [ "${3:-}" = static ]; then
      grep -q 'FAIL  \[static\]' "$M/out" || bad=" static"
    else
      for sh in $SHELLS; do grep -q "FAIL  \[$sh\]" "$M/out" || bad="$bad $sh"; done
    fi
    if [ "$rc" = 1 ] && [ -z "$bad" ]; then ok "convicted${3:+ ($3)}: $1"
    else no "NOT CONVICTED (rc $rc, no FAIL line under:$bad): $1"; fi
  }
  mutate "cred allowlist opened to every op (any op can ride past a running seal)" \
         's@^    armcred|rekey) ;;@    armcred|rekey|*) ;;@'
  mutate "cred allowlist widened to a seal op" \
         's@^    armcred|rekey) ;;@    armcred|rekey|out) ;;@'
  mutate "cred lane pointed at the SHARED req file" \
         's@REQ="\$STATE/roamcred.req"@REQ="$STATE/roam.req"@'
  mutate "ro lane opened to armcred" \
         's@^    storagebreakdown|sealdelta|uiderrors|alarmrelay@&|armcred@'
  mutate "ro lane closed to uiderrors (every issue report says NOT collected: ERR-LANE)" \
         's@^    storagebreakdown|sealdelta|uiderrors|alarmrelay@    storagebreakdown|sealdelta|alarmrelay@'
  mutate "ro lane closed to alarmrelay (a cold lock behind an abandoned op relays no alarm: ERR-LANE)" \
         's@^    storagebreakdown|sealdelta|uiderrors|alarmrelay@    storagebreakdown|sealdelta|uiderrors@'
  mutate "ro lane closed to playrestart (a health notice's Fix answers ERR-LANE and restarts nothing)" \
         's@^\(    storagebreakdown|sealdelta|uiderrors|alarmrelay.*\)|playrestart@\1@'
  mutate "ro lane closed to gmsstate (every issue report says NOT collected: ERR-LANE)" \
         's@^\(    storagebreakdown|sealdelta|uiderrors|alarmrelay.*\)|gmsstate@\1@'
  mutate "ro lane closed to gmsexits (every session report says not-collected-lane: ERR-LANE)" \
         's@^\(    storagebreakdown|sealdelta|uiderrors|alarmrelay.*\)|gmsexits@\1@'
  mutate "ro lane closed to healthprobe (every health check is unmeasured: ERR-LANE)" \
         's@^\(    storagebreakdown|sealdelta|uiderrors|alarmrelay.*\)|healthprobe@\1@'
  mutate "ro lane closed to vpnstate (every in-session report says vpn_state=unavailable: ERR-LANE)" \
         's@^\(    storagebreakdown|sealdelta|uiderrors|alarmrelay.*\)|vpnstate@\1@'
  mutate "userdir_recheck's guard comment drops vpnstate from the read-only lane's ops" \
         's@, healthprobe, vpnstate) are arms of that@, healthprobe) are arms of that@' static
  mutate "userdir_recheck's guard comment drops alarmrelay from the read-only lane's ops" \
         's@ops (sealdelta, storagebreakdown, uiderrors, alarmrelay@ops (sealdelta, storagebreakdown, uiderrors@' static
  mutate "S1 ro lane's chip-secret refusal deleted (the secret rides into storagebreakdown's environment)" \
         '/^  if \[ -n "\$sesec" \]; then$/,/^  fi$/d'
  mutate "S2 ro lane's chip-secret refusal tests \$pass twice instead of \$sesec" \
         's@^  if \[ -n "\$sesec" \]; then$@  if [ -n "$pass" ]; then@'
  mutate "S3 ro lane's chip-secret refusal prints the secret in its log line" \
         's@a chip secret must never reach this lane@a chip secret ($sesec) must never reach this lane@'
  rm -rf "$M"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
