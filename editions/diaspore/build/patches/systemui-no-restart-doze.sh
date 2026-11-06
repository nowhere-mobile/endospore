#!/bin/bash
# NWP-20260825-03 -- the boot AOD clock blink: SystemUI puts the screen BACK TO SLEEP one second into every
# boot, so a freshly booted Nowhere device flashes a full-screen lockscreen clock before the gate appears.
#
# WHY (framework): RestartDozeListener exists to restore AOD across a SystemUI RESTART. It records the dozing
# state into the secure setting `restart_nap_after_start` on every doze change, and DreamMonitor.onStart()
# calls maybeRestartSleep(), which 1000ms later does wakeUp() + goToSleep() if that flag is set. On a normal
# phone that is invisible and correct -- SystemUI crashed while dozing, so put it back. On Nowhere it is
# simply wrong: the device WIPES AT POWER-OFF and must always boot to a visible gate, and the flag survives
# from whenever the device last dozed, so the "restart" is really a fresh boot being dragged back to sleep.
#
# DEVICE-MEASURED on lynx 2026-08-25 (build 2026082408): SystemUI starts ~01:08:50 and
# `PowerManagerService: Going to sleep due to application (uid 10166)` lands at 01:08:51.017 -- 1000ms later,
# uid 10166 = systemui, reason = application, all three matching this call exactly.
#
# WHY A FRAMEWORK PATCH AND NOT A WAKE: an explicit goToSleep OVERRIDES wake locks, so the chooser could only
# ever RACE it -- wake up afterwards and hope the AOD clock had not faded in yet. Three slices tightened that
# race (NWP-20260823-05/-16/-18) and Chester still saw the clock, because a race cannot be tuned to zero. This
# removes the sleep instead, which is the only thing that makes the blink structurally impossible.
#
# The `if` is deliberately LEFT IN PLACE evaluating the setting, so the log line still tells us the path was
# reached; only the wake/sleep pair is removed. That also avoids leaving unreachable code behind.
#
# Tree-agnostic (the class is identical in LineageOS and GrapheneOS) -- run once on the build tree before `m`.
# Endospore: run by editions/endospore/build/build-device.sh (GOS_MANDATED_PATCHES, since NWP-20261019-03). Diaspore: MANUAL.
# Rebuilds SystemUI (an APK in /system_ext), so it needs a `system_ext` reflash, NOT just `system`.
# Idempotent; backs up the original to <file>.diaspore-orig.
#
# Usage: systemui-no-restart-doze.sh [TREE]   (default: /mnt/build/lineage)
set -euo pipefail
TREE="${1:-/mnt/build/lineage}"
F="$TREE/frameworks/base/packages/SystemUI/src/com/android/systemui/flags/RestartDozeListener.kt"
[ -f "$F" ] || { echo "not found: $F" >&2; exit 1; }
if grep -q "NWP-20260825-03" "$F"; then echo "already applied (no change)"; exit 0; fi
cp -n "$F" "$F.diaspore-orig" 2>/dev/null || true
python3 - "$F" <<'PY'
import sys
f = sys.argv[1]
s = open(f).read()
anchor = ('                if (settings.getBool(RESTART_SLEEP_KEY, false)) {\n'
          '                    Log.d("RestartDozeListener", "Restarting sleep state")\n'
          '                    powerManager.wakeUp(\n'
          '                        systemClock.uptimeMillis(),\n'
          '                        PowerManager.WAKE_REASON_APPLICATION,\n'
          '                        "RestartDozeListener"\n'
          '                    )\n'
          '                    powerManager.goToSleep(systemClock.uptimeMillis())\n'
          '                }\n')
assert s.count(anchor) == 1, "anchor count %d -- maybeRestartSleep shape changed, re-check the patch" % s.count(anchor)
repl = ('                if (settings.getBool(RESTART_SLEEP_KEY, false)) {\n'
        '                    // Nowhere (NWP-20260825-03): do NOT put the screen back to sleep. Upstream restores\n'
        '                    // AOD across a SystemUI restart, but this device wipes at power-off and must always\n'
        '                    // boot to a VISIBLE gate -- so at boot this fires on a stale flag and drags a fresh\n'
        '                    // boot back to sleep, which is the full-screen clock the user sees before the gate.\n'
        '                    // An explicit goToSleep overrides wake locks, so waking afterwards can only race it.\n'
        '                    Log.d("RestartDozeListener", "Nowhere: NOT restarting sleep state (NWP-20260825-03)")\n'
        '                }\n')
open(f, "w").write(s.replace(anchor, repl, 1))
print("patched maybeRestartSleep: the boot goToSleep is gone")
PY
echo "applied NWP-20260825-03 systemui-no-restart-doze"
