#!/usr/bin/env bash
# sms-raw-no-sim-filter.sh <build-tree-root> -- NWP-20260929-02, rev 3 NWP-20261123-27. Framework patch to
# TelephonyProvider, BOTH editions.
#
# WHY. SmsProvider filters every query to the SIMs associated with the calling user, and the `raw` table -- the
# framework's own multipart reassembly buffer -- is no exception. The phone process queries `raw` as user 0, and
# with enforce_subscription_user_filter off (both trees build it off) user 0's list is the SIMs linked to user 0,
# or the unlinked ones only when none is. The #176 outbound lock (core/chooser, lockOwnerSimsToBound) links the SIM
# a signed-in profile does not own to user 0; reclaimSimsToGate never clears a user-0 link, and the framework keeps
# a removed SIM's link. While any SIM is linked, every multi-part SMS and MMS notice on an unlinked SIM is stored in
# `raw` and never reassembled; the duplicate check and the unlock and day-in-service scans cannot see its rows
# either. Our subscription-user-filter.sh exempts user 0 only on the path getActiveSubscriptionInfoList takes, not
# this one. docs/backlog.md, "While one SIM is linked to the gate user, the phone never reassembles ...".
# The gate's raw scrub (core/chooser TelScrub.rawSegmentAge, NWP-20261108-10) reads `raw` as the chooser on user 0.
# Filtered, it never sees a segment on a SIM hidden from user 0, so that segment's cleartext has no bound. Decision
# h49 #6 (docs/product-decisions.md, 2026-10-31) widens the scope by that one app: docs/backlog.md, "A multipart
# segment whose siblings never arrive keeps its cleartext on user 0, across power-offs, until the framework ...".
# WHAT. In SmsProvider's query, `raw` is not filtered by SIM links when the caller is the phone or the system
# (TelephonyPermissions.isSystemOrPhone), and from rev 3 when the caller is the gate app: its uid is on user 0, the
# uid's only package is exactly com.nowhere.chooser, and checkSignatures(uid, SYSTEM_UID) is SIGNATURE_MATCH (the
# platform key). Any exception keeps the filter. Every other caller, and every other table, is filtered as before. Not
# canReadRawTable's wider set: LineageOS has no such gate, so any app holding READ_SMS on user 0 would see every
# SIM's in-flight segments. ONE anchor, byte-identical in the GrapheneOS tree (queryInternal) and the LineageOS
# tree (query).
# ARTIFACT. TelephonyProvider.apk -> /system/priv-app -> reflash `system`.
# VERIFY. The literals "Nowhere: raw query not filtered by SIM links" and, from rev 3, "Nowhere: raw query not
# filtered for the gate app (h49 #6)" in the built APK's classes.dex, with the control "raw/permanentDelete" (present
# in every build). On a device, `setprop log.tag.SmsProvider VERBOSE` prints the first at the next inbound text and
# the second at the gate's raw scrub. The "ok" this script's run prints in the build log is NOT evidence.
# A tree that carries rev 2 exits 3: revert SmsProvider.java with the printed command, then re-run.
# Endospore: run by editions/endospore/build/build-device.sh (GOS_MANDATED_PATCHES). Diaspore: run by
# editions/diaspore/build/apply-patches.sh.
# Register: docs/framework-patches.md. Suite: editions/diaspore/build/test-sms-raw-no-sim-filter.sh.
# Exit: 0 applied, or already applied; 1 usage, missing file, or failed self-check; 2 anchor drift;
#       3 an older or partial copy of this patch is present (prints the revert command).
set -euo pipefail
T="${1:?usage: sms-raw-no-sim-filter.sh <build-tree-root>}"
PROJ="$T/packages/providers/TelephonyProvider"
REL=src/com/android/providers/telephony/SmsProvider.java
F="$PROJ/$REL"
[ -f "$F" ] || { echo "[sms-raw-no-sim-filter] MISSING $F"; exit 1; }

python3 - "$F" "git -C $PROJ checkout -- $REL" <<'PY'
import os, shutil, sys

path, revert = sys.argv[1], sys.argv[2]
TAG = "[sms-raw-no-sim-filter]"
REV = "3"
MARK = "Nowhere (sms-raw-no-sim-filter rev "
VAR = "nowhereRawUnfiltered"

# Pristine upstream text: GrapheneOS SmsProvider.queryInternal, LineageOS SmsProvider.query.
ANCHOR = """\
        if (qb.getTables().equals(smsTable)) {
            if (selectionBySubIds == null && selectionByEmergencyNumbers == null) {
                // No subscriptions associated with user
                // and no emergency numbers return empty cursor.
                return emptyCursor;
            }
        } else {
            if (selectionBySubIds == null) {
                // No subscriptions associated with user return empty cursor.
                return emptyCursor;
            }
        }
"""

NEW = """\
        // Nowhere (sms-raw-no-sim-filter rev """ + REV + """, NWP-20260929-02, NWP-20261123-27): the raw
        // table is not filtered by SIM links for the phone, the system and the gate's own app. It is
        // the framework's multipart reassembly buffer, and the phone process queries it as user 0.
        // While any SIM is linked to user 0, user 0's view hides every unlinked SIM, so its
        // reassembly, duplicate check and undelivered-message scans cannot see that SIM's rows for as
        // long as it stays hidden. The gate's raw scrub (h49 #6) has the same blind spot. The gate app
        // is the uid on user 0 whose only package is com.nowhere.chooser, signed with the platform key.
        // Any exception keeps the filter. Every other caller, and every other table, is filtered as before.
        final boolean nowhereSystemOrPhone =
                com.android.internal.telephony.TelephonyPermissions.isSystemOrPhone(callingUid);
        boolean nowhereGateApp = false;
        if (match == SMS_RAW_MESSAGE && !nowhereSystemOrPhone
                && android.os.UserHandle.getUserId(callingUid) == android.os.UserHandle.USER_SYSTEM) {
            try {
                final android.content.pm.PackageManager nowherePm = getContext().getPackageManager();
                final String[] nowherePkgs = nowherePm.getPackagesForUid(callingUid);
                nowhereGateApp = nowherePkgs != null && nowherePkgs.length == 1
                        && "com.nowhere.chooser".equals(nowherePkgs[0])
                        && nowherePm.checkSignatures(callingUid, android.os.Process.SYSTEM_UID)
                                == android.content.pm.PackageManager.SIGNATURE_MATCH;
            } catch (Exception e) {
                nowhereGateApp = false;
            }
        }
        final boolean nowhereRawUnfiltered = match == SMS_RAW_MESSAGE
                && (nowhereSystemOrPhone || nowhereGateApp);
        if (nowhereRawUnfiltered) {
            selectionBySubIds = null;
            if (Log.isLoggable(TAG, Log.VERBOSE)) {
                if (nowhereGateApp) {
                    Log.v(TAG, "Nowhere: raw query not filtered for the gate app (h49 #6)");
                } else {
                    Log.v(TAG, "Nowhere: raw query not filtered by SIM links (NWP-20260929-02)");
                }
            }
        }
        if (qb.getTables().equals(smsTable)) {
            if (selectionBySubIds == null && selectionByEmergencyNumbers == null) {
                // No subscriptions associated with user
                // and no emergency numbers return empty cursor.
                return emptyCursor;
            }
        } else if (!nowhereRawUnfiltered) {
            if (selectionBySubIds == null) {
                // No subscriptions associated with user return empty cursor.
                return emptyCursor;
            }
        }
"""

with open(path, encoding="utf-8", newline="") as f:
    s = f.read()

if s.count(MARK) or s.count(VAR):
    if s.count(NEW) == 1 and s.count(MARK) == 1 and s.count(VAR) == NEW.count(VAR):
        print(TAG, "already applied (rev " + REV + ") -- skipped")
        sys.exit(0)
    print(TAG, "an older or partial copy of this patch is in", path, "-- refusing to apply over it")
    print(TAG, "revert, then re-run:", revert)
    sys.exit(3)

n = s.count(ANCHOR)
if n != 1:
    print(TAG, "PATCH ANCHOR matched %d times (want 1) -- upstream changed? aborting" % n)
    sys.exit(2)

out = s.replace(ANCHOR, NEW, 1)
tmp = path + ".nowhere-tmp"
with open(tmp, "w", encoding="utf-8", newline="") as f:
    f.write(out)
with open(tmp, encoding="utf-8", newline="") as f:
    chk = f.read()
if (chk.count(NEW) != 1 or chk.count(ANCHOR) != 0 or chk.count(MARK) != 1
        or chk.count(VAR) != NEW.count(VAR) or len(chk) != len(s) - len(ANCHOR) + len(NEW)):
    os.remove(tmp)
    print(TAG, "self-check failed -- file left untouched")
    sys.exit(1)
shutil.copymode(path, tmp)
os.replace(tmp, path)
print(TAG, "patched SmsProvider query: raw not filtered by SIM links for the phone/system and the gate app (rev " + REV + ")")
PY
