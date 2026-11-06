#!/usr/bin/env bash
# test-boot-receiver-order.sh [<chooser src dir>] [--mutate] -- BootReceiver.onReceive's order is load-bearing: the
# user-0 guard first, the gate up before goAsync, and in the "nowhere-boot-wipe" thread Bluetooth FIRST and the boot
# sweep LAST (NWP-20261113-34).
#
# WHY THIS IS COMMITTED. Every line of onReceive carries a comment saying why it is where it is, and no suite read any
# of them: test-boot-wipe-login-race.sh pins wipeLeftoverRoamedUsers and nothing else, and no suite or ci/ check named
# btWipe, revertDeviceLocale, clearSessionMessages or bootSweep. A refactor that moved ChooserActivity.bootSweep() above
# wipeLeftoverRoamedUsers(app) compiled and passed every suite, and the sweep then ran before the removeUser calls that
# MINT the dropbox records naming the slots just erased (DIA-20260816-04) -- the residue the amnesia audit found, back
# on every boot with no log line. The chooser has no unit-test harness, so these are source-level checks; CI executes
# this suite and its --mutate run.
#
# HOW IT CHECKS. onReceive is read as text, with comment-only and blank lines dropped so a call left in a // comment
# never counts and "first"/"last" mean adjacent statements. clearSessionMessages is PINNED BYTE FOR BYTE, comments
# included. wipeLeftoverRoamedUsers is NOT pinned here: test-boot-wipe-login-race.sh owns that block.
#
#   bash test-boot-receiver-order.sh            # the invariants
#   bash test-boot-receiver-order.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SRC=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SRC="$a" ;; esac; done
SRC="${SRC:-$(dirname "$0")/src/com/nowhere/chooser}"
BR="$SRC/BootReceiver.java"
[ -f "$BR" ] || { echo "no such file: $BR" >&2; exit 2; }
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
# ⚠ Every match reads its input to the end: `grep -c ... >/dev/null`, never `grep -q` (see test-owner-key.sh).

# body <file> <signature fragment>: the method's lines, from its signature to the first line closing it at the class's
# method indent ("    }") -- or a marker that fails every check when the signature does not occur exactly once.
body(){ [ "$(grep -cF -- "$2" "$1")" = 1 ] || { echo "<signature not exactly once: $2>"; return; }; awk -v sig="$2" 'index($0, sig) { on = 1 } on { print } on && /^    }$/ { exit }' "$1"; }
# line <text> <fixed string>: the 1-based line of its first match, or 0.
line(){ printf '%s\n' "$1" | awk -v s="$2" 'index($0, s) && !n { n = NR } END { print n + 0 }'; }
# count <text> <fixed string>: how many lines contain it.
count(){ printf '%s\n' "$1" | grep -cF -- "$2"; }
# pin <name> <actual> <expected>
pin(){ if [ "$2" = "$3" ]; then ok "$1 is the pinned block"; else no "$1 differs from the pinned block"; fi; }
# before <a> <b>: both anchors were found and a comes first.
before(){ [ "$1" -gt 0 ] && [ "$2" -gt 0 ] && [ "$1" -lt "$2" ]; }

O=$(body "$BR" 'public void onReceive(Context context, Intent intent)')
Oc=$(printf '%s\n' "$O" | grep -v '^[[:space:]]*\(//.*\)\{0,1\}$')

GUARD='if (android.os.UserHandle.myUserId() != 0) return;'
BOOT='if (Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction())) {'
START='app.startActivity(i);'; ASYNC='goAsync()'; THR='new Thread(() -> {'
BT='ChooserActivity.btWipe();'; LOC='ChooserActivity.revertDeviceLocale();'; MSG='clearSessionMessages(app);'
WIPE='wipeLeftoverRoamedUsers(app);'; TEL='TelScrub.all(app);'; SWEEP='ChooserActivity.bootSweep();'
FIN='} finally {'; PRF='pr.finish();'; END='}, "nowhere-boot-wipe").start();'

guard=$(line "$Oc" "$GUARD"); boot=$(line "$Oc" "$BOOT"); start=$(line "$Oc" "$START"); async=$(line "$Oc" "$ASYNC")
thr=$(line "$Oc" "$THR"); bt=$(line "$Oc" "$BT"); loc=$(line "$Oc" "$LOC"); msg=$(line "$Oc" "$MSG")
wipe=$(line "$Oc" "$WIPE"); tel=$(line "$Oc" "$TEL"); sweep=$(line "$Oc" "$SWEEP"); fin=$(line "$Oc" "$FIN")
prf=$(line "$Oc" "$PRF"); end=$(line "$Oc" "$END")

echo "== control: the extraction found the boot-wipe thread =="
if [ "$(count "$O" 'nowhere-boot-wipe')" -ge 1 ] && [ "$thr" -gt 0 ] && [ "$fin" -gt 0 ] && [ "$end" -gt 0 ]; then
  ok "onReceive's body holds the nowhere-boot-wipe thread, its try/finally and its start"
else
  no "onReceive's body was not extracted (no nowhere-boot-wipe thread found) -- every check below would read a broken body"
fi

echo "== 2a: the user-0 guard is the first statement (#50/#96) =="
if [ "$(count "$Oc" "$GUARD")" = 1 ] && [ "$guard" = 2 ]; then
  ok "the user-0 guard is onReceive's first statement"
else
  no "the user-0 guard is missing, repeated or not first (line $guard) -- BOOT_COMPLETED reaches every user at every login and launched the gate over the session (#50/#96)"
fi
if before "$guard" "$boot" && before "$guard" "$start"; then ok "...before the BOOT_COMPLETED check and the gate start"
else no "the user-0 guard is not before the BOOT_COMPLETED check and the gate start (guard $guard, check $boot, start $start)"; fi

echo "== 2b: the gate comes up before goAsync =="
if [ "$(count "$Oc" "$START")" = 1 ] && [ "$(count "$Oc" "$ASYNC")" = 1 ] && before "$start" "$async" && before "$async" "$thr"; then
  ok "app.startActivity(i) runs before goAsync() and the wipe thread"
else
  no "the gate start is not once, before goAsync() (start $start, goAsync $async, thread $thr) -- the gate must never wait on the wipe (no home-flash, and no ANR if it stalls)"
fi

echo "== 2c: the boot-wipe thread's clears, once each, in order =="
n=0
for s in "$BT" "$LOC" "$MSG" "$WIPE" "$SWEEP"; do [ "$(count "$Oc" "$s")" = 1 ] || { no "$s is not called exactly once in onReceive"; n=1; }; done
[ "$n" = 0 ] && ok "btWipe, revertDeviceLocale, clearSessionMessages, wipeLeftoverRoamedUsers and bootSweep are each called once"
if before "$thr" "$bt" && before "$bt" "$loc" && before "$bt" "$wipe"; then ok "Bluetooth FIRST in the thread (DIA-20260807-09)"
else no "btWipe is not the thread's first clear (thread $thr, bt $bt, locale $loc, wipe $wipe) -- DIA-20260807-09: Bluetooth FIRST, and unconditionally, not as a late side effect of removeUser"; fi
if before "$loc" "$msg"; then ok "the device locale is reverted before the session messages are cleared (DIA-20260807-15)"
else no "revertDeviceLocale is not before clearSessionMessages (locale $loc, messages $msg) -- DIA-20260807-15: after a battery death no reap ran, so the gate would come up in the departed language"; fi
if before "$msg" "$wipe"; then ok "the session messages are cleared before the user wipe (DIA-20260815-12)"
else no "clearSessionMessages is not before wipeLeftoverRoamedUsers (messages $msg, wipe $wipe) -- DIA-20260815-12: they live OUTSIDE every user, so the user wipe has never reached them"; fi
if before "$wipe" "$sweep" && before "$sweep" "$fin"; then ok "the boot sweep runs after the user wipe, inside the try (DIA-20260816-04)"
else no "bootSweep is not after wipeLeftoverRoamedUsers inside the try (wipe $wipe, sweep $sweep, finally $fin) -- DIA-20260816-04: removeUser MINTS the dropbox entries the sweep removes"; fi

echo "== 2d: the telephony scrub runs in the thread, before the sweep (#135 B5) =="
if [ "$(count "$Oc" "$TEL")" = 1 ] && before "$thr" "$tel" && before "$tel" "$sweep"; then
  ok "TelScrub.all(app) is called once in the thread, before bootSweep"
else
  no "TelScrub.all(app) is not once in the thread before bootSweep (thread $thr, tel $tel, sweep $sweep) -- #135 B5: the telephony amnesia backstop"
fi

echo "== 2e: the sweep is LAST, and the finish is in the finally =="
if [ "$sweep" -gt 0 ] && [ "$fin" = $((sweep + 1)) ]; then ok "bootSweep is the try's last statement"
else no "bootSweep is not the last statement before } finally { (sweep $sweep, finally $fin) -- DIA-20260816-04: LAST, and that ordering is the point"; fi
if [ "$(count "$Oc" "$PRF")" = 1 ] && [ "$fin" -gt 0 ] && [ "$prf" = $((fin + 1)) ] && before "$prf" "$end"; then
  ok "pr.finish() is in the finally"
else
  no "pr.finish() is not once in the finally (finally $fin, finish $prf, end $end) -- goAsync keeps the process alive until the wipe finishes (#47), so the finish must run whatever the wipe throws"
fi

echo "== 2f: the boot-wipe thread is started =="
if [ "$(count "$Oc" "$END")" = 1 ] && before "$fin" "$end"; then ok "the nowhere-boot-wipe thread is started"
else no "the nowhere-boot-wipe thread is not started after its finally (finally $fin, start $end) -- an unstarted thread runs no wipe at all"; fi

echo "== 3: clearSessionMessages, pinned (byte for byte, comments included) =="
C=$(body "$BR" 'private void clearSessionMessages(Context context)')
PIN_C=$(cat <<'PIN'
    private void clearSessionMessages(Context context) {
        try {
            android.app.admin.DevicePolicyManager dpm = (android.app.admin.DevicePolicyManager)
                    context.getSystemService(Context.DEVICE_POLICY_SERVICE);
            if (dpm == null || !dpm.isDeviceOwnerApp(context.getPackageName())) return;
            android.content.ComponentName admin = new android.content.ComponentName(context, AdminReceiver.class);
            dpm.setStartUserSessionMessage(admin, null);
            dpm.setEndUserSessionMessage(admin, null);
            android.util.Log.i("NowhereChooser", "boot-wipe: cleared session messages (#110)");
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "clearSessionMessages", t);
        }
    }
PIN
)
pin "clearSessionMessages (its device-owner guard and both null setters clear a pre-#110 name)" "$C" "$PIN_C"

# --- mutations ------------------------------------------------------------------------------------------
if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each MUST be convicted) =="
  mutate(){ # mutate <label> <sed script> [baseline]
    local d f
    d=$(mktemp -d -p "$W") || { no "MUTATION BROKEN (mktemp): $1"; return; }
    f="$d/BootReceiver.java"
    cp "$BR" "$f" || { no "MUTATION BROKEN (copy): $1"; return; }
    if [ "${3:-}" = baseline ]; then
      if bash "$0" "$d" >/dev/null 2>&1; then ok "baseline: an unmodified copy passes"; else no "baseline: an unmodified copy FAILS -- the harness, not the mutants, decides"; fi
      return
    fi
    if ! sed -i "$2" "$f" 2>/dev/null; then no "MUTATION BROKEN (sed): $1"; return; fi
    if cmp -s "$f" "$BR"; then no "MUTATION INERT: $1"; return; fi
    if bash "$0" "$d" >/dev/null 2>&1; then no "NOT CONVICTED: $1 -- suite passes on broken code"
    else ok "convicted: $1"; fi
  }
  mutate "baseline" '' baseline
  mutate "M1 bootSweep moved above wipeLeftoverRoamedUsers" '/^ *ChooserActivity\.bootSweep();$/d;s/^\( *\)wipeLeftoverRoamedUsers(app);/\1ChooserActivity.bootSweep();\n&/'
  mutate "M2 TelScrub.all(app) deleted"                      '/^ *TelScrub\.all(app);$/d'
  mutate "M3 clearSessionMessages(app) deleted"              '/^ *clearSessionMessages(app);$/d'
  mutate "M4 btWipe moved below wipeLeftoverRoamedUsers"     '/^ *ChooserActivity\.btWipe();$/d;s/^\( *\)wipeLeftoverRoamedUsers(app);.*$/&\n\1ChooserActivity.btWipe();/'
  mutate "M5 the user-0 guard deleted"                       '/^ *if (android\.os\.UserHandle\.myUserId() != 0) return;$/d'
  mutate "M6 pr.finish() moved to the end of the try"        '/^ *pr\.finish();$/d;s/^\( *\)ChooserActivity\.bootSweep();$/&\n\1pr.finish();/'
  mutate "M7 app.startActivity(i) moved below goAsync()"     '/^ *app\.startActivity(i);$/d;s/^\( *\)final PendingResult pr = goAsync();$/&\n\1app.startActivity(i);/'
  mutate "M8 a null setter dropped from clearSessionMessages" '/^ *dpm\.setEndUserSessionMessage(admin, null);$/d'
  mutate "M9 TelScrub.all moved below bootSweep"             '/^ *TelScrub\.all(app);$/d;s/^\( *\)ChooserActivity\.bootSweep();$/&\n\1TelScrub.all(app);/'
  mutate "M10 bootSweep moved above the wipe, a // copy left in its place" 's/^\( *\)ChooserActivity\.bootSweep();$/\1\/\/ ChooserActivity.bootSweep();/;s/^\( *\)wipeLeftoverRoamedUsers(app);/\1ChooserActivity.bootSweep();\n&/'
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
