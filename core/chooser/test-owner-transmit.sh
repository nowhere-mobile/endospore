#!/usr/bin/env bash
# test-owner-transmit.sh [<ChooserActivity.java>] [--mutate] -- owner-mode transmit (637) invariants.
#
# WHY COMMITTED. Owner-mode transmit (637) lets owner mode place a call / send a text on a SIM bound to NO
# profile -- the owner's line (T1/T2 gate cleared, NWP-20261001-03). The ONE security-critical invariant is
# that it NEVER offers a BOUND SIM (a profile's line) to transmit on: unboundSims() must FAIL CLOSED when it
# cannot read the bindings (daemon unreachable, or a damaged bindings.conf), returning no SIM rather than
# guessing -- otherwise the owner could text/call on a profile's SIM, an ownership leak. A "simplifying"
# refactor that drops the guard is exactly what a later pass does in good faith. The chooser has no unit-test
# harness, so these are source-level checks on the FUNCTIONAL form (never comment text), in the committed
# style of test-owner-mandatory.sh. Outbound is also pinned fire-and-forget (product-decisions.md 2026-10-01):
# no sent-record store, and the owner's placed call surfaces control UI via NowhereInCallService without a
# Recorder, so it is never sealed. The call path must also fail closed (no default-SIM fallback).
#
#   bash test-owner-transmit.sh            # the invariants
#   bash test-owner-transmit.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail
MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/src/com/nowhere/chooser/ChooserActivity.java}"
[ -f "$SUT" ] || { echo "no such file: $SUT" >&2; exit 2; }
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
# ⚠ Every match below reads its input to the end: a here-string (`grep -q PAT <<<"$var"`) or
# `grep -c PAT >/dev/null` on a pipe, never `cmd | grep -q`. Under pipefail grep -q exits at its first match,
# the producer can die of SIGPIPE, and the pipeline fails: an absence check then passes on the code it exists
# to reject, a presence check goes red at random (docs/backlog.md, "pipes into grep -q under pipefail").
sk(){ printf '  --    %s\n' "$1"; } # informational; neither PASS nor FAIL (a sibling file isn't present)

echo "== unboundSims fails CLOSED on ANY binding damage =="
# Whole-file damage (null / DAMAGED_BINDINGS) AND a single damaged line (a DAMAGED_ROW in the list) must all
# return empty. A DAMAGED_ROW means the daemon could not read one SIM's binding; treating it as unbound would
# offer that profile's bound SIM for owner transmit. The sibling fillSimRows (NWP-20260930-05) guards all three;
# unboundSims must too (the P0 the review caught: the original guard missed the DAMAGED_ROW clause).
if grep -q 'if (bindings == null || bindings == TelArrival.DAMAGED_BINDINGS || bindings.contains(TelArrival.DAMAGED_ROW)) return out;' "$SUT"; then
  ok "unboundSims returns empty when bindings are unreadable, whole-file-damaged, OR carry a damaged row"
else
  no "unboundSims has no 3-clause fail-closed guard -- a partially-damaged file could offer a bound SIM"
fi
G=$(grep -n 'bindings == null || bindings == TelArrival.DAMAGED_BINDINGS' "$SUT" | head -1 | cut -d: -f1)
E=$(grep -n 'for (SimInfo s : activeSims())' "$SUT" | head -1 | cut -d: -f1)
if [ -n "$G" ] && [ -n "$E" ] && [ "$G" -lt "$E" ]; then ok "the guard runs before the SIM enumeration"; else no "the guard does not precede the enumeration ($G vs $E)"; fi
if grep -q 'for (String\[\] b : bindings) { if (iccEq(s.iccid, b\[1\])) { bound = true; break; } }' "$SUT"; then
  ok "a SIM matching a binding (by ICCID) is excluded from the unbound set"
else
  no "the bound-SIM exclusion (iccEq) is gone -- a bound SIM could be offered"
fi
if grep -q 'String.valueOf(s.subId).equals(b\[0\])' "$SUT"; then
  ok "a bound SIM reporting an empty ICCID is still excluded via its subId"
else
  no "the subId fallback is gone -- a bound SIM with no readable ICCID would be offered"
fi
# NWP-20261110-07 (Q031): in a rebuilt bindings file a SIM no line names is offered only when the owner marked it as
# this phone's own line. The marks come from the same GET-BINDINGS read as the rows, parsed after the guard.
if grep -qF 'if (!bound && marks.ownersLine(s.iccid)) out.add(s);' "$SUT" && ! grep -qF 'if (!bound) out.add(s);' "$SUT" \
   && grep -qF 'final BindingMarks marks = BindingMarks.parse(lines);' "$SUT"; then
  ok "in a rebuilt file only a SIM the owner marked as this phone's own line is offered (BindingMarks.ownersLine)"
else
  no "unboundSims offers a SIM without BindingMarks.ownersLine -- a profile's former line could be offered after a repair"
fi

echo "== the call path fails CLOSED on no matching phone account =="
if grep -q 'if (chosen == null) {' "$SUT" && grep -q 'no phone account for the unassigned SIM' "$SUT"; then
  ok "placeOwnerCall refuses when no account matches the unbound SIM (never routes to the default/bound SIM)"
else
  no "placeOwnerCall has no null-account guard -- an owner call could route to the default (possibly bound) SIM"
fi

echo "== transmit is two-way and reachable =="
grep -q 'setContentView(buildMessagesCallsMenu())' "$SUT" && ok "the owner menu opens the Messages & calls submenu" || no "no Messages & calls submenu entry"
grep -q 'setContentView(buildOwnerComposeScreen(null, -1))' "$SUT" && ok "Compose is an owner-menu entry (initiate)" || no "no Compose owner-menu entry"
grep -q 'setContentView(buildOwnerComposeScreen(from, arrivedSub, when))' "$SUT" && ok "Reply opens Compose pre-filled with the sender" || no "no Reply-to-Compose wiring"
grep -q 'createForSubscriptionId(sim.subId)' "$SUT" && ok "the text is sent on the unbound SIM's own subId" || no "SMS not pinned to the unbound SIM's subId"

echo "== outbound is fire-and-forget (product-decisions.md 2026-10-01): no sent record kept =="
if grep -qiE 'OWNER-OUTBOUND|sealOwnerOutbound|ownerOutbound' "$SUT"; then
  no "a sent-record store crept in -- outbound must leave no trace (2026-10-01 decision)"
else
  ok "no sent-record store -- outbound leaves no trace"
fi

echo "== the owner's placed call gets control UI but is NEVER sealed =="
# A call the owner cannot end is a trap, so placeOwnerCall must arm a control surface (Hang up / Mute / Speaker).
# The arm lives in ChooserActivity (pinned + mutation-tested here). The no-seal half lives in
# NowhereInCallService.adoptOutgoingForUi, which must surface UI WITHOUT a Recorder -- a Recorder seals the call,
# which is a sent record and breaks the 2026-10-01 fire-and-forget decision. The $ICS checks skip when the
# sibling is absent (the generic mutate reruns below copy only ChooserActivity); a dedicated sibling mutation
# under --mutate convicts a Recorder creeping into the outgoing-adopt path.
grep -q 'NowhereInCallService.armOwnerOutgoing()' "$SUT" \
  && ok "placeOwnerCall arms the control UI for the owner's call (so it can be ended)" \
  || no "placeOwnerCall does not arm the control UI -- a placed call could not be hung up"
ICS="$(dirname "$SUT")/NowhereInCallService.java"
if [ -f "$ICS" ]; then
  BODY=$(awk '/private void adoptOutgoingForUi\(/{f=1} f{print} f&&/^    }/{exit}' "$ICS")
  if [ -n "$BODY" ] && ! grep -qE 'new Recorder|recorders\.put' <<<"$BODY"; then
    ok "adoptOutgoingForUi surfaces UI with NO Recorder -- the owner's outbound call is never sealed"
  else
    no "adoptOutgoingForUi is missing or registers a Recorder -- outbound would be sealed (breaks fire-and-forget)"
  fi
  grep -q 'if (consumeOwnerOutgoing()) adoptOutgoingForUi(call);' "$ICS" \
    && ok "onCallAdded routes ONLY an armed owner outgoing call to the no-seal UI (emergency path untouched)" \
    || no "onCallAdded does not scope the outgoing-UI adoption to an armed owner call"
else
  sk "NowhereInCallService.java not beside the SUT -- no-seal checks skipped (expected in mutate reruns)"
fi

echo "== owner-mode perms are self-granted (default-permissions miss an OTA'd user 0) =="
# SEND_SMS/CALL_PHONE are DANGEROUS runtime perms; default-permissions grant them only at fresh user-0 creation,
# and neither a package update nor the already-held SMS/dialer roles re-grant on boot -- so an OTA'd device would
# have transmit SILENTLY fail. The device owner self-grants them at gate launch (ensureTransmitPerms).
grep -q 'ensureTransmitPerms();' "$SUT" && ok "ensureTransmitPerms runs at gate launch" || no "ensureTransmitPerms not called at gate launch"
if grep -q 'android.Manifest.permission.SEND_SMS, android.Manifest.permission.CALL_PHONE' "$SUT" && grep -q 'PERMISSION_GRANT_STATE_GRANTED' "$SUT"; then
  ok "the device owner self-grants SEND_SMS + CALL_PHONE (works on fresh AND OTA'd devices)"
else
  no "the SEND_SMS/CALL_PHONE self-grant is gone -- transmit would fail on an OTA'd device"
fi

if [ "$MUTATE" = yes ]; then
  echo; echo "== mutations (each MUST be convicted) =="
  M=$(mktemp -d)
  mutate(){
    if ! sed "$2" "$SUT" > "$M/m.java" 2>"$M/err"; then no "MUTATION BROKEN (sed): $1"; return; fi
    if cmp -s "$SUT" "$M/m.java"; then no "MUTATION INERT: $1"; return; fi
    if bash "$0" "$M/m.java" >/dev/null 2>&1; then no "NOT CONVICTED: $1 -- suite passes on broken code"; else ok "convicted: $1"; fi
  }
  mutate "the 3-clause fail-closed guard removed (would offer SIMs on an unreadable/damaged bindings file)" \
         '/if (bindings == null || bindings == TelArrival.DAMAGED_BINDINGS || bindings.contains(TelArrival.DAMAGED_ROW)) return out;/d'
  mutate "only the DAMAGED_ROW clause dropped (a partially-damaged file would offer a bound SIM)" \
         's/ || bindings.contains(TelArrival.DAMAGED_ROW)//'
  mutate "the bound-SIM ICCID exclusion neutered (every SIM treated as unbound)" \
         's/if (iccEq(s.iccid, b\[1\])) { bound = true; break; }/if (false) { bound = true; break; }/'
  mutate "the subId fallback neutered (a bound SIM with no ICCID treated as unbound)" \
         's/String.valueOf(s.subId).equals(b\[0\])/false/'
  mutate "the own-line test dropped (a rebuilt file's unmarked SIM offered as the owner's line)" \
         's/if (!bound \&\& marks.ownersLine(s.iccid)) out.add(s);/if (!bound) out.add(s);/'
  mutate "the call-path null-account guard removed (owner call could route to the default/bound SIM)" \
         '/if (chosen == null) { android.util.Log.w("NowhereChooser", "owner call: no phone account for the unassigned SIM (sub " + sim.subId + ")"); return false; }/d'
  mutate "Reply no longer pre-fills the sender" \
         's/setContentView(buildOwnerComposeScreen(from, arrivedSub, when))/setContentView(buildOwnerComposeScreen(null, -1))/'
  mutate "placeOwnerCall no longer arms the control UI (a placed call could not be ended)" \
         '/NowhereInCallService.armOwnerOutgoing();/d'
  mutate "ensureTransmitPerms no longer called at gate launch (OTA'd devices lose transmit)" \
         's/        ensureTransmitPerms();.*$//'
  mutate "the transmit perm self-grant list emptied (SEND_SMS/CALL_PHONE not granted)" \
         's/android.Manifest.permission.SEND_SMS, android.Manifest.permission.CALL_PHONE/REMOVED/'
  # The no-seal invariant lives in NowhereInCallService; mutate a COPY of it (inject a Recorder into the
  # outgoing-adopt path) beside an unmutated ChooserActivity and assert the $ICS no-seal check convicts.
  if [ -f "$ICS" ]; then
    D="$M/sib/src/com/nowhere/chooser"; mkdir -p "$D"
    cp "$SUT" "$D/ChooserActivity.java"
    awk '{print} /private void adoptOutgoingForUi\(/{inm=1} inm && /if \(current != null\) return;/{print "        recorders.put(call, new Recorder(getApplicationContext()));"; inm=0}' \
        "$ICS" > "$D/NowhereInCallService.java"
    if bash "$0" "$D/ChooserActivity.java" >/dev/null 2>&1; then
      no "NOT CONVICTED: a Recorder in adoptOutgoingForUi -- suite passes on code that would seal the owner's call"
    else
      ok "convicted: a Recorder in the outgoing-adopt path (would seal the owner's outbound call)"
    fi
  else
    sk "no-seal sibling mutation skipped (NowhereInCallService.java not beside the SUT)"
  fi
  rm -rf "$M"
fi

echo; echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
