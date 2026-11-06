#!/usr/bin/env bash
# test-progress-units.sh [--mutate] -- guard the seal progress channel's UNIT CONTRACT.
#
# WHY THIS IS COMMITTED. writeProg's wire format is "<phase> <done> <total> [scope]" and carries NO UNIT.
# Almost every frame in it is bytes, so the gate byte-renders the pair through fmtBytes. One frame is not:
# pushProfile's one-time #85 chunk-size migration reports CHUNK INDICES. Rendered as bytes that became
#
#     "Backing up your data...  1 KB of 3 KB"
#
# while the seal was moving gigabytes -- on the screen whose entire job is telling the owner whether it is
# safe to power off, a number that reads as "nearly nothing left to do" (NWP-20260903-07).
#
# The repair is a LABEL, not new numbers: the agent marks that stretch with the "sizes" phase and the gate
# renders that phase without byte text. Nothing enforces the two halves agree -- they are different
# languages, in different build systems, and NEITHER COMPILER CAN SEE THE OTHER. A rename on one side alone
# restores the lie silently, which is precisely how the sibling defect NWP-20260903-04 shipped: a predicate
# matching a string literal that someone reworded twenty lines away.
#
#   bash test-progress-units.sh            # the contract cases
#   bash test-progress-units.sh --mutate   # ... plus mutations that must each CONVICT the suite
#
# Pure text analysis -- no build, no device. Runs anywhere bash does.
set -uo pipefail

MUTATE=no; ROOT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) ROOT="$a" ;; esac; done
ROOT="${ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"

AGENT="$ROOT/core/agent/main.go"
GATE="$ROOT/core/chooser/src/com/nowhere/chooser/ProfileActivity.java"
for f in "$AGENT" "$GATE"; do
  [ -f "$f" ] || { echo "missing: $f" >&2; exit 2; }
done

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

# --- the non-byte phase name, read from the AGENT and then required of the GATE -------------------------
# Deliberately EXTRACTED, not hardcoded here: a test that hardcoded "sizes" would keep passing if someone
# renamed the phase on both sides, and would fail confusingly if they renamed it correctly on both. What
# must hold is that the two sides agree -- so read one side and demand the other.
PHASE=$(sed -n 's/.*setProgPhase("\([a-z]*\)").*chunk.*/\1/p' "$AGENT" | head -1)
[ -n "$PHASE" ] || PHASE=$(grep -oE 'setProgPhase\("sizes"\)' "$AGENT" | head -1 | sed 's/.*("\(.*\)").*/\1/')
[ -n "$PHASE" ] || PHASE=sizes

echo "== the agent labels its chunk-index frames with a non-byte phase =="
if grep -q "setProgPhase(\"$PHASE\")" "$AGENT"; then
  ok "agent sets the \"$PHASE\" phase"
else
  no "agent never sets a non-byte phase -- chunk indices go out labelled as bytes"
fi

# The index emitter must sit BETWEEN the phase switch and its restore. Checked by line order rather than by
# proximity, because the loop between them is long and will grow.
SET_LN=$(grep -n "setProgPhase(\"$PHASE\")" "$AGENT" | head -1 | cut -d: -f1)
EMIT_LN=$(grep -n 'writeProg(i+1, nchunks)' "$AGENT" | head -1 | cut -d: -f1)
RESTORE_LN=$(grep -n 'setProgPhase(prevPhase)' "$AGENT" | head -1 | cut -d: -f1)
if [ -n "$SET_LN" ] && [ -n "$EMIT_LN" ] && [ -n "$RESTORE_LN" ] \
   && [ "$SET_LN" -lt "$EMIT_LN" ] && [ "$EMIT_LN" -lt "$RESTORE_LN" ]; then
  ok "the chunk-index emitter is inside the labelled stretch (set $SET_LN < emit $EMIT_LN < restore $RESTORE_LN)"
else
  no "the chunk-index emitter is NOT enclosed by the phase switch (set=$SET_LN emit=$EMIT_LN restore=$RESTORE_LN)"
fi

if [ -n "$RESTORE_LN" ]; then
  ok "the phase is restored afterwards (a leaked phase would mislabel every later frame)"
else
  no "setProgPhase is never restored -- every frame after the migration inherits the wrong label"
fi

echo "== the gate refuses to byte-render that phase =="
# Every site that renders a seal frame through fmtBytes must exclude the non-byte phase.
SITES=$(grep -c 'fmtBytes(dt\[0\])' "$GATE")
GUARDED=$(grep -c "\"$PHASE\"\.equals(sealPhase(" "$GATE")
if [ "$SITES" -gt 0 ] && [ "$GUARDED" -ge 1 ]; then
  ok "gate guards on sealPhase (\"$PHASE\") at $GUARDED site(s)"
else
  no "gate byte-renders seal frames at $SITES site(s) with $GUARDED guard(s) -- the \"$PHASE\" frame is a lie"
fi
# Count-based, so a NEW byte-rendering site added later without a guard fails here.
if [ "$GUARDED" -ge "$SITES" ]; then
  ok "every byte-rendering site is guarded ($GUARDED >= $SITES)"
else
  no "$SITES byte-rendering site(s) but only $GUARDED guarded -- an unguarded site renders chunk indices as KB"
fi

echo "== the two languages agree on the phase name =="
if grep -q "\"$PHASE\"\.equals(sealPhase(" "$GATE"; then
  ok "gate matches the exact phase the agent emits (\"$PHASE\")"
else
  no "the gate does not test for \"$PHASE\" -- the halves have drifted apart and the lie is back"
fi

# --- mutations ------------------------------------------------------------------------------------------
if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each MUST be convicted) =="
  M=$(mktemp -d)
  mkdir -p "$M/core/agent" "$M/core/chooser/src/com/nowhere/chooser"
  mutate(){ # <name> <agent-sed> <gate-sed>
    cp "$AGENT" "$M/core/agent/main.go"
    cp "$GATE"  "$M/core/chooser/src/com/nowhere/chooser/ProfileActivity.java"
    [ -n "$2" ] && { sed -i "$2" "$M/core/agent/main.go" || { no "MUTATION BROKEN (agent sed): $1"; return; }; }
    [ -n "$3" ] && { sed -i "$3" "$M/core/chooser/src/com/nowhere/chooser/ProfileActivity.java" || { no "MUTATION BROKEN (gate sed): $1"; return; }; }
    if cmp -s "$AGENT" "$M/core/agent/main.go" && cmp -s "$GATE" "$M/core/chooser/src/com/nowhere/chooser/ProfileActivity.java"; then
      no "MUTATION INERT (changed nothing): $1"; return
    fi
    if bash "$0" "$M" >/dev/null 2>&1; then
      no "NOT CONVICTED: $1 -- the suite passes on broken code"
    else
      ok "convicted: $1"
    fi
  }
  mutate "agent stops labelling the phase (chunk indices ship as bytes again)" \
         's@^\tsetProgPhase("sizes")@\t// removed@' ''
  mutate "agent never restores the phase (every later frame mislabelled)" \
         's@^\tsetProgPhase(prevPhase)@\t// removed@' ''
  mutate "gate drops its guard and byte-renders every frame" \
         '' 's@"sizes"\.equals(sealPhase(@false \&\& "x".equals(sealPhase(@'
  mutate "the two sides drift apart (phase renamed on the gate only)" \
         '' 's@"sizes"\.equals(sealPhase(@"chunks".equals(sealPhase(@'
  rm -rf "$M"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
