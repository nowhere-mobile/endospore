#!/bin/bash
# NWP-20260925-02: arm a VPN's "Block connections without VPN" at its FIRST CONNECTION, not at the permission tap.
#
# WHY. GrapheneOS arms always-on WITH lockdown the moment a VPN app's consent is approved (frameworks/base commit
# 362020040a3c, "Set always-on and lockdown on by default on first vpn connection at system_server side", the hunk
# in VpnManagerService.setVpnPackageAuthorization). A VPN that signs in through the browser asks for that consent
# BEFORE it can connect -- Tailscale does so by itself when opened signed out -- so the user approves a kill switch no
# tunnel can satisfy yet. Its sign-in page is then blocked along with every other app in the session, and nothing on
# screen says why. Found on frankel, user build 2026092405, 2026-09-25 (NWP-20260925-01). Chester decided the same
# day: arm the block at the first connection instead (docs/product-decisions.md).
#
# WHAT IT CHANGES, in two files:
#   Vpn.java
#     1. A static hook, sNowhereOnConnected, called with the user id right after agentConnect() reaches CONNECTED.
#        agentConnect() is the one point EVERY VPN kind passes through on connecting: a VpnService app via
#        establish(), a platform (VpnManager IKEv2) profile via its runner, and the agent restart a lockdown change
#        causes. The hook only posts; it runs with the Vpn monitor held.
#   VpnManagerService.java
#     2. The constructor points the hook at nowhereArmPendingLockdown, posted to mHandler.
#     3. setVpnPackageAuthorization: the consent sets always-on WITHOUT lockdown and records the package in the
#        per-user Secure setting `nowhere_vpn_lockdown_pending`, both under mVpns, so no explicit always-on call can
#        land between the two; if the setting cannot be written it fails closed and arms the block at once, as
#        upstream does. Then it posts one arm attempt (an app prepared earlier may already be connected).
#     4. setAlwaysOnVpnPackage (the binder entry Settings, DevicePolicyManager and Nowhere's #159 np.VpnAlwaysOn all
#        use) clears the pending state once its own setting has SUCCEEDED, under mVpns, so an explicit choice is
#        never overridden and a failed call leaves the deferred block armed-to-be.
#     5. nowhereArmPendingLockdown, under mVpns: sets lockdown only while always-on is still that package, the block
#        is still off and the VPN is connected; clears a pending state that no longer applies; keeps one that is
#        merely early. Guarded, so a throw cannot take down system_server.
# The pending state is a Secure setting, not memory, so it survives a user stop (a Nowhere cold-lock) between the
# consent and the first connection; it dies with the user.
#
# Lands in services.jar -> a full `m` and a `system` reflash. Verify a build carries it: logcat shows
# `VpnManagerService: Nowhere: always-on VPN set for user <N>; the block waits for its first connection` at the
# consent, and `Nowhere: VPN block armed at the first connection for user <N>` when the tunnel comes up; and
# `settings get --user <N> secure always_on_vpn_lockdown` reads 0 between the two and 1 after. Absent, the consent
# arms the block at once (always_on_vpn_lockdown=1 straight after the permission tap). Register:
# docs/framework-patches.md.
#
# Idempotent by marker; a tree carrying an OLDER cut (the current revision missing from either file) or only one
# patched file is refused with the revert command.
#
# Usage: vpn-lockdown-on-first-connect.sh <tree>   (auto-run by build-device.sh's patch pass)
set -e
TREE="${1:?usage: $0 <tree>}"
F="$TREE/frameworks/base/services/core/java/com/android/server/VpnManagerService.java"
V="$TREE/frameworks/base/services/core/java/com/android/server/connectivity/Vpn.java"
[ -f "$F" ] || { echo "no VpnManagerService.java at $F" >&2; exit 1; }
[ -f "$V" ] || { echo "no Vpn.java at $V" >&2; exit 1; }

# The marker names the patch; REV names this cut of it. Bump REV whenever the injected code changes: a tree that
# carries an older cut is then REFUSED with the revert command, never reported "already applied" while it ships the
# older code (the keystore-roam.sh PATCH_VERSION lesson). REV is stamped into BOTH files -- the Vpn.java hook comment
# and the VpnManagerService constructor comment -- and required in both, so no mix of cuts reads as applied.
M="nowhere-vpn-first-connect (NWP-20260925-02)"
REV="nowhere-vpn-first-connect (NWP-20260925-02) rev 4"
REVERT="git -C $TREE/frameworks/base checkout -- services/core/java/com/android/server/VpnManagerService.java services/core/java/com/android/server/connectivity/Vpn.java"
hf=0; hv=0
grep -q "$M" "$F" && hf=1
grep -q "$M" "$V" && hv=1
if [ "$hf$hv" = 11 ]; then
  if grep -q "$REV" "$F" && grep -q "$REV" "$V"; then echo "already applied (no change)"; exit 0; fi
  echo "tree carries an OLDER cut of vpn-lockdown-on-first-connect -- revert with: $REVERT ; then re-run" >&2; exit 1
fi
if [ "$hf$hv" = 10 ]; then
  # Rev 1 (commit ca0d8933) patched VpnManagerService.java alone, so this is most likely that older cut, not a
  # half-applied run. Either way the cure is the same revert.
  echo "tree carries an OLDER cut (rev 1 patched VpnManagerService.java only) or is HALF-APPLIED -- revert with: $REVERT ; then re-run" >&2; exit 1
fi
if [ "$hf$hv" = 01 ]; then
  echo "HALF-APPLIED (Vpn.java patched, VpnManagerService.java not) -- revert with: $REVERT ; then re-run" >&2; exit 1
fi

python3 - "$F" "$V" <<'PY'
import io, sys
fpath, vpath = sys.argv[1], sys.argv[2]
files = {fpath: io.open(fpath, encoding='utf-8').read(), vpath: io.open(vpath, encoding='utf-8').read()}


def once(path, anchor, repl, what):
    n = files[path].count(anchor)
    if n != 1:
        sys.exit("%s anchor found %d times, need exactly 1 -- upstream changed, patch by hand" % (what, n))
    files[path] = files[path].replace(anchor, repl, 1)


# ---- Vpn.java 1a: the hook ------------------------------------------------------------------------------------
once(vpath, "    @VisibleForTesting protected boolean mLockdown = false;\n",
     """    @VisibleForTesting protected boolean mLockdown = false;

    // nowhere-vpn-first-connect (NWP-20260925-02) rev 4: set once by VpnManagerService; told the user id each time a
    // VPN of that user reaches CONNECTED, so a block deferred at consent can be armed at the first connection. Placed
    // AFTER mLockdown so upstream's javadoc and @GuardedBy("this") stay on that field.
    public static volatile java.util.function.IntConsumer sNowhereOnConnected;
""", "Vpn field")

# ---- Vpn.java 1b: every VPN kind reaches CONNECTED here ------------------------------------------------------
once(vpath, '        updateState(DetailedState.CONNECTED, "agentConnect");\n',
     '''        updateState(DetailedState.CONNECTED, "agentConnect");
        // nowhere-vpn-first-connect (NWP-20260925-02): the one point every VPN kind passes through on connecting.
        // The hook only posts to VpnManagerService's handler; this runs with the Vpn monitor held.
        final java.util.function.IntConsumer nowhereOnConnected = sNowhereOnConnected;
        if (nowhereOnConnected != null) {
            nowhereOnConnected.accept(mUserId);
        }
''', "agentConnect")

# ---- VpnManagerService.java: import ---------------------------------------------------------------------------
once(fpath, "import android.os.UserManager;\n",
     "import android.os.UserManager;\nimport android.provider.Settings;\n", "import")

# ---- 2. the constructor points the hook at the arm -----------------------------------------------------------
once(fpath, "        mHandler = mHandlerThread.getThreadHandler();\n",
     """        mHandler = mHandlerThread.getThreadHandler();
        // nowhere-vpn-first-connect (NWP-20260925-02) rev 4: a VPN reaching CONNECTED arms a block its consent deferred.
        Vpn.sNowhereOnConnected = user -> mHandler.post(() -> nowhereArmPendingLockdown(user));
""", "constructor")

# ---- 3. the consent: always-on now, the block at the first connection ----------------------------------------
once(fpath, """            if (vpnType != VpnManager.TYPE_VPN_NONE && packageName != null
                    && !packageName.equals(getAlwaysOnVpnPackage(userId))) {
                setAlwaysOnVpnPackage(userId, packageName, true, null);
            }
""", """            // nowhere-vpn-first-connect (NWP-20260925-02): always-on now, the block at the VPN's first connection.
            // The check, the set and the pending write are ONE step under mVpns, so an explicit always-on call can
            // land only wholly before it (and then this skips) or wholly after it (and then that call wins).
            boolean nowhereDeferred = false;
            synchronized (mVpns) {
                if (vpnType != VpnManager.TYPE_VPN_NONE && packageName != null
                        && !packageName.equals(getAlwaysOnVpnPackage(userId))
                        && setAlwaysOnVpnPackage(userId, packageName, false, null)) {
                    if (nowherePutPendingLockdown(userId, packageName)) {
                        nowhereDeferred = true;
                        log("Nowhere: always-on VPN set for user " + userId
                                + "; the block waits for its first connection");
                    } else {
                        // Could not record the deferral: fail closed, exactly as upstream -- block now.
                        logw("Nowhere: could not record the deferred VPN block for user " + userId
                                + "; blocking now");
                        setAlwaysOnVpnPackage(userId, packageName, true, null);
                    }
                }
            }
            if (nowhereDeferred) {
                // An app prepared earlier may already be connected: arm now if so.
                mHandler.post(() -> nowhereArmPendingLockdown(userId));
            }
""", "setVpnPackageAuthorization")

# ---- 4. a SUCCESSFUL explicit always-on call clears the pending state ----------------------------------------
once(fpath, """            if (!startAlwaysOnVpn(userId)) {
                vpn.setAlwaysOnPackage(null, false, null);
                return false;
            }
        }
        return true;
    }
""", """            if (!startAlwaysOnVpn(userId)) {
                vpn.setAlwaysOnPackage(null, false, null);
                return false;
            }
            // nowhere-vpn-first-connect (NWP-20260925-02): an explicit always-on choice that took effect -- Settings,
            // a device policy, Nowhere's own #159 helper -- supersedes a block the consent deferred. Under mVpns, where
            // the arm reads it too; a failed call returned above and leaves the deferred block to arm.
            nowherePutPendingLockdown(userId, null);
        }
        return true;
    }

    // nowhere-vpn-first-connect (NWP-20260925-02). GrapheneOS arms always-on WITH lockdown the moment a VPN app's
    // consent is approved (frameworks/base 362020040a3c). A VPN that signs in through the browser asks for that
    // consent before it can connect, so the block then stops its own sign-in page and every app in the session.
    // Decided 2026-09-25: the block arms at the VPN's FIRST CONNECTION instead. The pending package is a per-user
    // Secure setting, not memory, so it survives a user stop (a Nowhere cold-lock) between the consent and the first
    // connection, and it dies with the user.
    private static final String NOWHERE_LOCKDOWN_PENDING = "nowhere_vpn_lockdown_pending";

    // Never throws: an always-on call for a user without settings must keep returning upstream's answer. Returns
    // whether the setting now holds packageName, so the consent can fail closed when it could not record one.
    private boolean nowherePutPendingLockdown(int userId, String packageName) {
        final long token = Binder.clearCallingIdentity();
        try {
            if (packageName == null && Settings.Secure.getStringForUser(
                    mContext.getContentResolver(), NOWHERE_LOCKDOWN_PENDING, userId) == null) {
                return true;
            }
            return Settings.Secure.putStringForUser(
                    mContext.getContentResolver(), NOWHERE_LOCKDOWN_PENDING, packageName, userId);
        } catch (RuntimeException e) {
            logw("Nowhere: could not record the deferred VPN block for user " + userId + ": " + e);
            return false;
        } finally {
            Binder.restoreCallingIdentity(token);
        }
    }

    // Runs on mHandler, posted by the consent and by every VPN connection. Arms the block only while always-on is
    // still the consented package, the block is still off and the VPN is connected; clears a pending state that no
    // longer applies; keeps one that is merely early for the next connection. Guarded: it runs on system_server's
    // VpnManagerService handler thread, where an uncaught throw would take the whole process down.
    private void nowhereArmPendingLockdown(int userId) {
        try {
            synchronized (mVpns) {
                final String pending = Settings.Secure.getStringForUser(
                        mContext.getContentResolver(), NOWHERE_LOCKDOWN_PENDING, userId);
                if (pending == null) {
                    return;
                }
                final Vpn vpn = mVpns.get(userId);
                if (vpn == null) {
                    return; // user not running: the setting waits for its next start
                }
                if (!pending.equals(vpn.getAlwaysOnPackage()) || vpn.getLockdown()) {
                    nowherePutPendingLockdown(userId, null); // always-on moved on, or the block is already on
                    return;
                }
                if (isLockdownVpnEnabled() || !vpn.getNetworkInfo().isConnected()) {
                    return; // not connected yet: keep waiting
                }
                if (vpn.setAlwaysOnPackage(pending, true, null)) {
                    nowherePutPendingLockdown(userId, null);
                    log("Nowhere: VPN block armed at the first connection for user " + userId);
                } else {
                    logw("Nowhere: could not arm the deferred VPN block for user " + userId
                            + "; retrying at the next connection");
                }
            }
        } catch (RuntimeException e) {
            logw("Nowhere: arming the deferred VPN block failed for user " + userId + ": " + e);
        }
    }
""", "setAlwaysOnVpnPackage")

for path, text in files.items():
    io.open(path, 'w', encoding='utf-8', newline='\n').write(text)
print("vpn-lockdown-on-first-connect: applied")
PY
grep -q "$REV" "$F" && grep -q "$REV" "$V" || { echo "marker missing after apply" >&2; exit 1; }
