#!/usr/bin/env bash
# Endospore / Pixel 10a (stallion): smooth the #129 offline-media prefetch progress ring (#128 / #172 issue 4).
#
# The ring (drawMediaRingIfNecessary in BubbleTextView) draws its arc DIRECTLY at the pkg->pct value in the
# static sMediaProgress map, which the Launcher MEDIA_PROGRESS receiver replaces wholesale on each cross-user
# broadcast. So the arc HOPS from one coarse progress value to the next (e.g. 20% -> 45% -> 70%) with no
# tweening -- visibly janky. Fix: give each BubbleTextView an eased displayed angle (mMediaRingShownPct) that
# chases the target a fraction per frame and self-schedules the next frame (postInvalidateOnAnimation) until it
# converges -- a coarse step then animates as a smooth sweep. Reset to -1 on the idle/complete paths so a fresh
# prefetch eases UP from 0 instead of animating DOWN from a stale value.
#
# Idempotent (skips if mMediaRingShownPct is already present). Requires the #129 ring to already be present
# (drawMediaRingIfNecessary). The ring is added by launcher3-media-progress-ring.sh in this same dir, which
# build-device.sh applies first (its per-device *.sh glob is alphabetical). If the ring is absent this FAILS
# (stderr 'ring not present', exit 3) instead of no-op'ing, so a build whose ring patch did not apply stops
# here rather than printing ok. Exit 2 = the ring's anchors drifted. Run after a fresh Launcher3 checkout, before `m`.
# Usage: launcher3-media-ring-smooth.sh <graphene-tree-root>
set -euo pipefail
TREE="${1:?usage: launcher3-media-ring-smooth.sh <graphene-tree-root>}"
F="$TREE/packages/apps/Launcher3/src/com/android/launcher3/BubbleTextView.java"
[ -f "$F" ] || { echo "[ring-smooth] no BubbleTextView.java at $F" >&2; exit 1; }
python3 - "$F" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
if "mMediaRingShownPct" in s:
    print("[ring-smooth] already applied"); sys.exit(0)
if "drawMediaRingIfNecessary" not in s:
    print("[ring-smooth] ERROR: #129 ring not present -- launcher3-media-progress-ring.sh must apply first", file=sys.stderr); sys.exit(3)

# 1 (critical): per-view eased displayed angle.
s = s.replace(
    "    private Paint mMediaRingPaint;\n",
    "    private Paint mMediaRingPaint;\n    private float mMediaRingShownPct = -1f; // #128: eased displayed ring angle (see drawMediaRingIfNecessary)\n", 1)
# 2 (critical): tween the drawn angle toward the target instead of jumping to the map value.
s = s.replace(
    "        canvas.drawArc(oval, -90f, 360f * pct / 100f, false, mMediaRingPaint);",
    "        // #128: ease the drawn angle toward the target so a coarse progress step animates instead of jumping.\n"
    "        if (mMediaRingShownPct < 0f) mMediaRingShownPct = 0f;\n"
    "        float delta = pct - mMediaRingShownPct;\n"
    "        if (Math.abs(delta) > 0.5f) { mMediaRingShownPct += delta * 0.18f; postInvalidateOnAnimation(); }\n"
    "        else { mMediaRingShownPct = pct; }\n"
    "        canvas.drawArc(oval, -90f, 360f * mMediaRingShownPct / 100f, false, mMediaRingPaint);", 1)
if "mMediaRingShownPct = -1f;" not in s or "mMediaRingShownPct += delta" not in s:
    print("[ring-smooth] ERROR: anchors not found -- ring source changed; aborting", file=sys.stderr); sys.exit(2)

# 3 (best-effort): reset the eased angle on the idle/complete return paths so a fresh prefetch sweeps up from 0.
s = s.replace(
    "        if (prog.isEmpty() || !(getTag() instanceof ItemInfoWithIcon)) {\n            return;\n        }",
    "        if (prog.isEmpty() || !(getTag() instanceof ItemInfoWithIcon)) {\n            mMediaRingShownPct = -1f;\n            return;\n        }", 1)
s = s.replace(
    "        if (pkg == null) {\n            return;\n        }",
    "        if (pkg == null) {\n            mMediaRingShownPct = -1f;\n            return;\n        }", 1)
s = s.replace(
    "        if (pct == null || pct <= 0 || pct >= 100) {\n            return; // no ring when idle or complete\n        }",
    "        if (pct == null || pct <= 0 || pct >= 100) {\n            mMediaRingShownPct = -1f; // reset so the next prefetch eases up from 0\n            return; // no ring when idle or complete\n        }", 1)

open(p, "w", encoding="utf-8").write(s)
print("[ring-smooth] eased the #129 media ring (jump -> tween) in", p)
PY
