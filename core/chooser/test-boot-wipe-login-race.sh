#!/usr/bin/env bash
# test-boot-wipe-login-race.sh [<chooser src dir>] [--mutate] -- the boot wipe must not remove a user that a boot-time
# sign-in is creating or has created (NWP-20261014-22).
#
# WHY THIS IS COMMITTED. BootReceiver.wipeLeftoverRoamedUsers ran removeUser on every secondary user it listed, then
# cleanUserStorage(uid) unconditionally, with no loginInProgress check. The gate is HOME and accepts a sign-in while the
# boot thread runs, so a user created before the wipe listed users was removed and its FBE trees rm -rf'd. The chooser
# has no unit-test harness, so these are source-level checks; CI executes this suite and its --mutate run.
#
# HOW IT CHECKS. wipeLeftoverRoamedUsers is PINNED BYTE FOR BYTE, comments included (see test-orphan-sweep-clean.sh);
# the line checks say WHY each property matters, and each has a mutation that must convict the suite.
#
#   bash test-boot-wipe-login-race.sh            # the invariants
#   bash test-boot-wipe-login-race.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SRC=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SRC="$a" ;; esac; done
SRC="${SRC:-$(dirname "$0")/src/com/nowhere/chooser}"
CA="$SRC/ChooserActivity.java"; BR="$SRC/BootReceiver.java"
[ -f "$CA" ] && [ -f "$BR" ] || { echo "no such file: $CA or $BR" >&2; exit 2; }
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

echo "== the pinned block (byte for byte, comments included) =="
B=$(body "$BR" 'private void wipeLeftoverRoamedUsers(Context context)')
PIN_B=$(cat <<'PIN'
    private void wipeLeftoverRoamedUsers(Context context) {
        try {
            android.app.admin.DevicePolicyManager dpm = (android.app.admin.DevicePolicyManager)
                    context.getSystemService(Context.DEVICE_POLICY_SERVICE);
            if (dpm == null || !dpm.isDeviceOwnerApp(context.getPackageName())) return;
            android.content.ComponentName admin = new android.content.ComponentName(context, AdminReceiver.class);
            for (android.os.UserHandle uh : dpm.getSecondaryUsers(admin)) {
                int uid = uh.getIdentifier();
                if (ChooserActivity.isLoginInProgress()) {
                    android.util.Log.i("NowhereChooser", "boot-wipe: skip user " + uid + " -- a sign-in is in progress; the #73 parked sweep retries");
                    continue;
                }
                if (ChooserActivity.sCreatedThisBoot.contains(uid)) {
                    android.util.Log.i("NowhereChooser", "boot-wipe: skip user " + uid + " -- created by a sign-in this boot; the #73 parked sweep retries");
                    continue;
                }
                boolean ok = dpm.removeUser(admin, uh);
                android.util.Log.i("NowhereChooser", "boot-wipe: removeUser " + uid + " ok=" + ok);
                // removeUser leaves /data/system_ce/<uid> behind; rm it so a reused uid can't inherit the stale,
                // key-mismatched CE and crash system_server on unlock (DIA-20260625-13). Only after an accepted
                // removal: cleanstorage rm's the FBE trees without checking the user is gone (NWP-20261011-38).
                if (ok) ChooserActivity.cleanUserStorage(uid);
                else android.util.Log.w("NowhereChooser", "boot-wipe: removeUser " + uid + " refused -- storage NOT cleaned");
            }
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "boot-wipe", t);
        }
    }
PIN
)
pin "wipeLeftoverRoamedUsers" "$B" "$PIN_B"

Bc=$(printf '%s\n' "$B" | grep -v '^[[:space:]]*//')
R=$(body "$CA" 'private int createRoamUser(String name, String pass)')
Rc=$(printf '%s\n' "$R" | grep -v '^[[:space:]]*//')

echo "== both skips precede removeUser =="
rm_=$(line "$Bc" 'boolean ok = dpm.removeUser(admin, uh);')
a=$(line "$Bc" 'if (ChooserActivity.isLoginInProgress()) {'); b=$(line "$Bc" 'if (ChooserActivity.sCreatedThisBoot.contains(uid)) {')
if [ "$(count "$Bc" 'removeUser(')" = 1 ] && [ "$rm_" -gt 0 ]; then ok "removeUser is called once"; else no "removeUser is not called exactly once"; fi
if [ "$a" -gt 0 ] && [ "$a" -lt "$rm_" ]; then ok "the sign-in-in-progress skip comes before removeUser"; else no "no in-progress skip before removeUser (skip $a, removeUser $rm_)"; fi
if [ "$b" -gt 0 ] && [ "$b" -lt "$rm_" ]; then ok "the created-this-boot skip comes before removeUser"; else no "no created-this-boot skip before removeUser (skip $b, removeUser $rm_)"; fi
if [ "$(count "$Bc" 'continue;')" = 2 ]; then ok "each skip continues past the user"; else no "the skips do not both continue"; fi

echo "== CLEAN-STORAGE runs only for an accepted removal =="
c=$(line "$Bc" 'if (ok) ChooserActivity.cleanUserStorage(uid);')
if [ "$(count "$Bc" 'cleanUserStorage(')" = 1 ] && [ "$c" -gt "$rm_" ] && [ "$rm_" -gt 0 ]; then ok "cleanUserStorage is called once, under if (ok), after removeUser"; else no "cleanUserStorage is unconditional, repeated, or before removeUser"; fi
e=$(line "$Bc" 'else android.util.Log.w("NowhereChooser", "boot-wipe: removeUser " + uid + " refused -- storage NOT cleaned");')
if [ "$e" = $((c + 1)) ]; then ok "a refused removal logs the else of the clean"; else no "refused removal not logged as the else of the clean"; fi

echo "== the sign-in side feeds the skip =="
if [ "$(count "$Rc" 'sCreatedThisBoot.add(uh.getIdentifier());')" = 1 ]; then ok "createRoamUser records the new uid"; else no "createRoamUser does not record the new uid exactly once"; fi
nl=$(line "$Rc" 'if (uh == null) return -1;'); ad=$(line "$Rc" 'sCreatedThisBoot.add('); sd=$(line "$Rc" 'SEED-SSAID')
if [ "$nl" -gt 0 ] && [ "$ad" = $((nl + 1)) ]; then ok "the add is the first statement after the null check"; else no "the add is not right after the null check (null $nl, add $ad)"; fi
if [ "$ad" -gt 0 ] && [ "$sd" -gt "$ad" ]; then ok "...and before the SSAID seed"; else no "the add is not before the SSAID seed (add $ad, seed $sd)"; fi
if [ "$(count "$(cat "$CA")" 'static final java.util.Set<Integer> sCreatedThisBoot = java.util.concurrent.ConcurrentHashMap.newKeySet();')" = 1 ] \
   && [ "$(count "$(cat "$CA")" 'static boolean isLoginInProgress() { return loginInProgress; }')" = 1 ]; then
  ok "ChooserActivity declares sCreatedThisBoot and isLoginInProgress()"
else
  no "sCreatedThisBoot / isLoginInProgress() declaration missing"
fi

# --- mutations ------------------------------------------------------------------------------------------
if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each MUST be convicted) =="
  M2=$(mktemp -d)
  mutate(){ # mutate <label> <sed script>
        # $3 = the file to mutate (CA default | BR); both are copied so the suite runs on the pair.
    rm -rf "$M2/src"; mkdir "$M2/src" || { no "MUTATION BROKEN (mkdir): $1"; return; }
    if ! cp "$CA" "$M2/src/ChooserActivity.java" || ! cp "$BR" "$M2/src/BootReceiver.java"; then no "MUTATION BROKEN (copy): $1"; return; fi
    local orig="$CA" f="$M2/src/ChooserActivity.java"
    [ "${3:-}" = BR ] && { orig="$BR"; f="$M2/src/BootReceiver.java"; }
    if ! sed -i "$2" "$f" 2>"$M2/err"; then no "MUTATION BROKEN (sed): $1"; return; fi
    if cmp -s "$f" "$orig"; then no "MUTATION INERT: $1"; return; fi
    if bash "$0" "$M2/src" >/dev/null 2>&1; then no "NOT CONVICTED: $1 -- suite passes on broken code"
    else ok "convicted: $1"; fi
  }
  mutate "the in-progress skip is dropped"            '/if (ChooserActivity.isLoginInProgress()) {/,/^                }$/d' BR
  mutate "the created-this-boot skip is dropped"      '/if (ChooserActivity.sCreatedThisBoot.contains(uid)) {/,/^                }$/d' BR
  mutate "the in-progress skip moved after removeUser" 's/^\(                \)boolean ok = dpm.removeUser(admin, uh);/\1boolean ok = dpm.removeUser(admin, uh);\n\1if (ChooserActivity.isLoginInProgress()) { continue; }/;/if (ChooserActivity.isLoginInProgress()) {$/,/^                }$/d' BR
  mutate "the created-this-boot skip moved after removeUser" 's/^\(                \)boolean ok = dpm.removeUser(admin, uh);/\1boolean ok = dpm.removeUser(admin, uh);\n\1if (ChooserActivity.sCreatedThisBoot.contains(uid)) { continue; }/;/if (ChooserActivity.sCreatedThisBoot.contains(uid)) {$/,/^                }$/d' BR
  mutate "cleanUserStorage is unconditional again"    's/^\(                \)if (ok) ChooserActivity.cleanUserStorage(uid);/\1ChooserActivity.cleanUserStorage(uid); if (!ok) { }/' BR
  mutate "the clean guard is inverted"                's/^\(                \)if (ok) ChooserActivity.cleanUserStorage(uid);/\1if (!ok) ChooserActivity.cleanUserStorage(uid);/' BR
  mutate "the refused log line is dropped"            's/^\(                \)else android.util.Log.w("NowhereChooser", "boot-wipe: removeUser .*refused.*$/\1else { }/' BR
  mutate "the set add moved after the SSAID seed"     '/sCreatedThisBoot.add(uh.getIdentifier());/d;s/^\(            \)long tStart = android.os.SystemClock.elapsedRealtime();/\1sCreatedThisBoot.add(uh.getIdentifier());\n&/'
  mutate "the set add is deleted"                     '/sCreatedThisBoot.add(uh.getIdentifier());/d'
  mutate "isLoginInProgress is deleted"               '/static boolean isLoginInProgress()/d'
  mutate "a dead copy of the method left in a comment" 's/^\(    \)private void wipeLeftoverRoamedUsers(Context context) {$/\1\/* private void wipeLeftoverRoamedUsers(Context context) { } *\/\n&/' BR
  rm -rf "$M2"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
