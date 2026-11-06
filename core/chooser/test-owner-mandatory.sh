#!/usr/bin/env bash
# test-owner-mandatory.sh [<ChooserActivity.java>] [--mutate] -- the mandatory-owner-secret invariants.
#
# WHY THIS IS COMMITTED. NWP-20260903-10 closed the FRP/ownership P0: a device with no owner secret handed
# ownership -- System settings, Leave Nowhere, OEM unlocking -- to whoever tapped the shield first, and BOTH
# exits that produced such devices were single lines ("Set up later" on the enrol step; "Skip setup" jumping
# straight to finishFirstRun). Single lines are exactly what a later UX pass re-adds in good faith: skip
# buttons read as kindness. This suite pins the four functional invariants so that re-adding any of them
# fails a test naming the P0, not a review comment three weeks later. The chooser has no unit-test harness,
# so these are source-level checks on the FUNCTIONAL forms (never comment text), in the same committed style
# as test-worker-lanes.sh and test-progress-units.sh.
#
# NWP-20261005-18 removed the OPTIONAL enrol form (the shield's, with its "Not now") outright: the shield opens
# verify only, so there is ONE enrol form and it is always the required one. NWP-20261006-06 moved these checks from
# that form's `required` flag to its whole body; they had failed on main since that merge.
# NWP-20261113-36 also pins the enrol subtitle's copy: "no recovery" stated once, the "Required" reason kept.
#
#   bash test-owner-mandatory.sh            # the invariants
#   bash test-owner-mandatory.sh --mutate   # ... plus mutations that must each CONVICT the suite
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

# ENROL: the one enrol form's body, from its signature to the method's closing brace.
ENROL=$(awk 'index($0, "private View buildOwnerEnrollScreen(final boolean firstRun) {") { on = 1 } on { print } on && /^    }$/ { exit }' "$SUT")

echo "== the enrol step cannot be skipped =="
if [ "$(grep -c 'private View buildOwnerEnrollScreen(' "$SUT")" = 1 ] && [ -n "$ENROL" ]; then
  ok "there is exactly one enrol form, buildOwnerEnrollScreen(firstRun)"
else
  no "the enrol form is missing or has a second variant -- an optional form was the shield's way to own the phone"
fi
if [ "$(grep -c 'cancel.setText(firstRun ? "Set up later"' "$SUT")" = 0 ]; then
  ok "no firstRun skip control on the enrol step"
else
  no "the enrol step has a firstRun skip again -- that control WAS the P0"
fi
# Code only (a // comment may quote the old labels). The form returns to the gate exactly once: after a successful set.
ENROL_CODE=$(printf '%s\n' "$ENROL" | sed 's|//.*$||')
if grep -qE '"Not now"|"Set up later"|"Skip"' <<<"$ENROL_CODE"; then
  no 'the enrol form has a skip control again -- that WAS the P0'
else
  ok 'the enrol form has no skip control'
fi
GATE_BACK=$(printf '%s\n' "$ENROL_CODE" | grep -c 'setContentView(gateView)')
if [ "$GATE_BACK" = 1 ] && grep -qE '^ +else \{ setContentView\(gateView\); result\.setTextColor\(ACCENT\); result\.setText\("device passphrase set"\); \}$' <<<"$ENROL_CODE"; then
  ok 'the enrol form returns to the gate only after a successful set'
else
  no "the enrol form returns to the gate $GATE_BACK time(s), not only after a successful set -- a way out without a secret"
fi

echo "== welcome's Skip setup skips the tour, not the requirement =="
if grep -q 'skip.setOnClickListener(v -> showFirstRunOwner());' "$SUT"; then
  ok "Skip setup routes to the owner step"
else
  no "Skip setup does not route to the owner step -- if it reaches finishFirstRun the P0 is back"
fi
if grep -q 'skip.setOnClickListener(v -> finishFirstRun());' "$SUT"; then
  no "a skip listener still jumps straight to finishFirstRun"
else
  ok "no skip listener jumps straight to finishFirstRun"
fi

echo "== the boot-time heal: the gate does not stand with no owner secret =="
HEAL=$(grep -n 'if (!switchingIn && !ownerSecretSet())' "$SUT" | head -1 | cut -d: -f1)
if [ -n "$HEAL" ]; then
  ok "the heal check exists (line $HEAL)"
  NXT=$(sed -n "$((HEAL+1))p" "$SUT")
  case "$NXT" in
    *'setContentView(buildOwnerEnrollScreen(false));'*) ok "…and it presents the (required) enrol form" ;;
    *) no "…but it does not present the required enrol form (next line: ${NXT})" ;;
  esac
  STORE=$(grep -n 'GET-STORE' "$SUT" | head -1 | cut -d: -f1)
  if [ -n "$STORE" ] && [ "$HEAL" -lt "$STORE" ]; then
    ok "…and it runs BEFORE the first-run store check (heal $HEAL < store $STORE)"
  else
    no "…but it runs after the store check ($HEAL vs $STORE) -- managed units would reach the gate first"
  fi
else
  no "the boot-time heal is GONE -- managed units (which never see first-run) stand at the gate with no secret"
fi

echo "== the required screen keeps 911 reachable =="
if grep -q '^        ll.addView(emergencyLink(), ' <<<"$ENROL"; then
  ok "the required enrol screen carries the emergency-dialer link"
else
  no "the required enrol screen has no emergency link -- it stands where the gate stands and blocks 911"
fi

echo "== the enrol subtitle states no recovery once =="
# NWP-20261113-36: NWP-20260903-10 appended "Required — ..." plus a second "There's no recovery: forgetting it means a
# factory reset." to a subtitle that already said "there's no recovery: if you forget it, only a factory reset clears
# it", so the screen said it twice in one paragraph. Counted on the form's code (comments stripped), case-insensitive.
NR=$(grep -oi 'no recovery' <<<"$ENROL_CODE" | wc -l)
if [ "$NR" -eq 1 ]; then
  ok 'the enrol subtitle states no recovery once'
else
  no "the enrol subtitle states \"no recovery\" $NR time(s), not once -- the screen repeats itself (NWP-20261113-36)"
fi
RQ=$(grep -oF "Required — it's what stops someone else becoming this phone's owner." <<<"$ENROL_CODE" | wc -l)
if [ "$RQ" -eq 1 ]; then
  ok 'the enrol subtitle keeps the Required reason'
else
  no "the enrol subtitle's \"Required — it's what stops someone else becoming this phone's owner.\" appears $RQ time(s), not once"
fi

# --- mutations ------------------------------------------------------------------------------------------
if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each MUST be convicted) =="
  M=$(mktemp -d)
  mutate(){
    if ! sed "$2" "$SUT" > "$M/m.java" 2>"$M/err"; then no "MUTATION BROKEN (sed): $1"; return; fi
    if cmp -s "$SUT" "$M/m.java"; then no "MUTATION INERT: $1"; return; fi
    if bash "$0" "$M/m.java" >/dev/null 2>&1; then no "NOT CONVICTED: $1 -- suite passes on broken code"
    else ok "convicted: $1"; fi
  }
  mutate "a Not-now control re-added to the enrol form (a way past it)" \
         's|^        // NWP-20260903-10: NO way past this screen.*$|&\n        TextView cancel = new TextView(this); cancel.setText("Not now"); cancel.setOnClickListener(v -> setContentView(gateView));|'
  mutate "an unlabelled way back to the gate (a tap outside the fields)" \
         's|^        // NWP-20260903-10: NO way past this screen.*$|&\n        ll.setOnClickListener(v -> setContentView(gateView));|'
  mutate "an optional second enrol form re-added" \
         's|^    private View buildOwnerEnrollScreen(final boolean firstRun) {$|    private View buildOwnerEnrollScreen() { return buildOwnerEnrollScreen(false); }\n&|'
  mutate "the heal opens something other than the enrol form" \
         's/setContentView(buildOwnerEnrollScreen(false));/setContentView(gateView);/'
  mutate "Skip setup jumps straight past the owner step again" \
         's/skip.setOnClickListener(v -> showFirstRunOwner());/skip.setOnClickListener(v -> finishFirstRun());/'
  mutate "the boot-time heal deleted" \
         '/if (!switchingIn \&\& !ownerSecretSet())/,+2d'
  mutate "the emergency link dropped from the required screen" \
         's/^        ll.addView(emergencyLink(), /        if (false) ll.addView(emergencyLink(), /'
  mutate "the dropped second no-recovery sentence re-added to the enrol subtitle" \
         "s|becoming this phone's owner.\");\$|becoming this phone's owner. There's no recovery: forgetting it means a factory reset.\");|"
  mutate "the Required sentence removed from the enrol subtitle" \
         "s| Required — it's what stops someone else becoming this phone's owner.||"
  rm -rf "$M"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
