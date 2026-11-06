#!/usr/bin/env bash
# keyguard-roaming-noocclude.sh <build-tree-root> -- #112 (DIA-20260705-84), revised by NWP-20261013-08. Framework
# patch to frameworks/base, BOTH editions.
#
# WHY (#112). An amnesiac ROAMED session (a secondary user) drew over its OWN SECURE keyguard, so a screen-off/wake
# revealed session content (the map, a permission prompt, ...) WITHOUT unlocking. Android's keyguard, BY DESIGN, lets
# any activity that requests showWhenLocked draw over the lock: ActivityRecord.canShowWhenLockedInner returns true
# for mShowWhenLocked || a showWhenLocked window || an always-visible user. Our roamed user is a normal
# FULL_SECONDARY (alwaysVisible=false -- confirmed via dumpsys user), and there is no config toggle. So a SECONDARY
# (roaming) user's activities never occlude the keyguard. User 0 (the gate) is UNAFFECTED -- it keeps its own
# show-over-keyguard (setShowWhenLocked) to get past user 0's insecure swipe keyguard at boot/forced-wake. Proven on
# FP3: pre-patch mKeyguardOccluded=true and the app was visible + interactive after a warm lock; post-patch
# mKeyguardOccluded=false and a real secure lockscreen covers it.
# WHY (NWP-20261013-08). That guard also blocked the dialer's in-call screen: in a warm-locked session an incoming
# call on the session's SIM rang, but it could be neither answered nor declined -- tapping it led to the unlock
# screen (Chester, frankel, 0.5.46, 2026-10-13). Decided the same day (docs/product-decisions.md): exempt ONLY the
# in-call screen of the session's default dialer, and only while a call is ringing or in progress.
# WHAT. Four edits, two files, all in com.android.server.wm:
#   ActivityRecord.canShowWhenLockedInner: a secondary user's activity returns false unless its package is that
#     user's entry in ActivityTaskManagerService.mNowhereInCallDialers; then the stock checks still apply (the
#     Dialer's InCallActivity adds FLAG_SHOW_WHEN_LOCKED). canShowWhenLocked is evaluated under the WM global lock,
#     so this edit only READS a volatile: no binder call, no other service's lock. The exemption is per PACKAGE:
#     any show-when-locked activity of that dialer, during a call.
#   ActivityRecord.canShowWhenLocked, its inheritShowWhenLocked branch: the same package check on the INHERITING
#     activity, so another package's activity sitting above the dialer in its task cannot borrow the exemption.
#   ActivityTaskManagerService (outer class): mNowhereInCallDialers and the code that writes it. A TelephonyCallback,
#     held in a final field (the registry's stub keeps only a WeakReference to it, TelephonyCallback.java:2090-2094,
#     and drops an event once it is collected), on the DEFAULT TelephonyManager receives Telecom's consolidated call state (TelephonyRegistry
#     .notifyCallStateForAllSubs, fed by Telecom's PhoneStateBroadcaster: RINGING if any call rings, OFFHOOK if one
#     is dialing, active or held). On RINGING/OFFHOOK it asks RoleService for every secondary user's ROLE_DIALER
#     holder, on the background thread with no lock held, publishes the map, and only then takes the WM lock to
#     re-evaluate the keyguard (notifyKeyguardFlagsChanged on every display). On IDLE it publishes null, so the
#     lock is back over a lingering in-call screen as soon as the call ends. Every failure leaves it null: the
#     exemption fails CLOSED, to the #112 behaviour.
#   ActivityTaskManagerService.Lifecycle.onBootPhase: registers the callback at PHASE_ACTIVITY_MANAGER_READY, which
#     SystemServer dispatches with no lock held, after TelephonyRegistry and RoleService have started.
# Anchors are whole lines, each matching exactly once, pristine in the GrapheneOS and the LineageOS tree; no other
# Nowhere patch touches these two files.
# ARTIFACT. services.jar -> /system/framework -> reflash `system`.
# VERIFY. services.jar's dex holds "nowhere: in-call lock exemption on (NWP-20261013-08)" and "... off (...)",
# with the control "Duplicate startWrite call?" (docs/framework-patches.md says how). On a device: logcat
# "ActivityTaskManager: nowhere: in-call lock exemption on (NWP-20261013-08)" when a call rings and "... off ..."
# when it ends. The "ok" this script's run prints in the build log is NOT evidence.
# REVERT. git -C <tree>/frameworks/base checkout -- <both files>, and rm -f ActivityRecord.java.diaspore-orig, the
# untracked backup the pre-NWP-20261013-08 script left beside it (the script prints the exact command).
# ⚠ PATCH_VERSION. Every anchor is matched against PRISTINE text, so this script cannot re-apply over an older copy
# of itself, and REFUSES (exit 3) when it finds one -- including the pre-NWP-20261013-08 guard, marked
# "Diaspore (#112)" -- printing the revert. Skipping instead would ship the older patch from a shared tree with a
# build log that says "ok". Bump PATCH_VERSION, and the marker in the blocks below, whenever a block changes.
# Endospore: run by editions/endospore/build/build-device.sh (GOS_MANDATED_PATCHES). Diaspore: MANUAL.
# Register: docs/framework-patches.md. Suite: editions/diaspore/build/test-keyguard-roaming-noocclude.sh.
# Exit: 0 applied, or already applied at PATCH_VERSION; 1 usage, missing file, or failed self-check; 2 anchor drift;
#       3 an older or partial copy of this patch is present (prints the revert command).
# Nothing is written unless every anchor in both files matches exactly once.
set -euo pipefail
PATCH_VERSION="NWP-20261013-08"
T="${1:?usage: keyguard-roaming-noocclude.sh <build-tree-root>}"
PROJ="$T/frameworks/base"
AR=services/core/java/com/android/server/wm/ActivityRecord.java
ATMS=services/core/java/com/android/server/wm/ActivityTaskManagerService.java
for REL in $AR $ATMS; do
  [ -f "$PROJ/$REL" ] || { echo "[keyguard-roaming-noocclude] MISSING $PROJ/$REL"; exit 1; }
done

python3 - "$PROJ" "$PATCH_VERSION" "git -C $PROJ checkout -- $AR $ATMS && rm -f $PROJ/$AR.diaspore-orig" $AR $ATMS <<'PY'
import os, shutil, sys

proj, version, revert = sys.argv[1], sys.argv[2], sys.argv[3]
AR, ATMS = sys.argv[4:6]
FILES = [AR, ATMS]
TAG = "[keyguard-roaming-noocclude]"
MARK = "nowhere-noocclude "
CUR = MARK + version
# Any of these anywhere in either file is a trace of this patch, of any version ("Diaspore (#112)" marks the
# pre-NWP-20261013-08 guard).
TOKENS = ("nowhere-noocclude", "Diaspore (#112)", "nowhereInCall", "NowhereInCall", "nowhereWatchCallState",
          "nowhereOnCallState", "nowhereInherit", version)

AR_BLOCK = """\
        // nowhere-noocclude NWP-20261013-08 (#112): an amnesiac roaming session runs as a
        // SECONDARY user, and nothing in it may draw over its warm-lock keyguard: Android
        // otherwise honours showWhenLocked (permission prompts, navigation, alarms, calls,
        // always-visible users) and leaks session content on a screen-off/wake. One exemption,
        // decided 2026-10-13: that user's default dialer while Telecom reports a call ringing
        // or in progress, so an incoming call can be answered or declined from the lock. The
        // stock checks below still apply to it, and the exemption ends with the call. This runs
        // under the WM lock, so it only reads mNowhereInCallDialers, which
        // ActivityTaskManagerService computes off that lock; null (no call, or not known) keeps
        // every activity of the user out. User 0 (the gate) is unaffected.
        if (r.mUserId != android.os.UserHandle.USER_SYSTEM) {
            final java.util.Map<Integer, String> nowhereInCallDialers =
                    r.mAtmService.mNowhereInCallDialers;
            if (nowhereInCallDialers == null || r.packageName == null
                    || !r.packageName.equals(nowhereInCallDialers.get(r.mUserId))) {
                return false;
            }
        }
"""

AR_INHERIT_BLOCK = """\
            // NWP-20261013-08 (#112, see canShowWhenLockedInner): an activity that inherits
            // showWhenLocked from the one below it must itself be the user's in-call dialer, or
            // another package's activity above the dialer would show over the lock during a call.
            if (r.mUserId != android.os.UserHandle.USER_SYSTEM) {
                final java.util.Map<Integer, String> nowhereInheritDialers =
                        r.mAtmService.mNowhereInCallDialers;
                if (nowhereInheritDialers == null || r.packageName == null
                        || !r.packageName.equals(nowhereInheritDialers.get(r.mUserId))) {
                    return false;
                }
            }
"""

ATMS_BLOCK = """\
    // nowhere-noocclude NWP-20261013-08: the one exemption from the #112 guard in
    // ActivityRecord.canShowWhenLockedInner. While Telecom's consolidated call state is
    // CALL_STATE_RINGING or CALL_STATE_OFFHOOK, this maps each secondary user to its default
    // dialer (ROLE_DIALER), whose in-call screen may then show over that user's lock; otherwise
    // it is null. The guard reads it under the WM lock and never computes it: it is written only
    // by nowhereOnCallState, on the background thread, which holds no lock while it asks
    // UserManager and RoleService, and takes the WM lock only afterwards, to re-evaluate the
    // keyguard. Every failure leaves it null, which is the #112 behaviour.
    volatile java.util.Map<Integer, String> mNowhereInCallDialers;

    // Held here for the life of the service: TelephonyCallback's registry stub keeps only a
    // WeakReference to it, and a collected listener's events are silently dropped.
    private final NowhereInCallListener mNowhereInCallListener = new NowhereInCallListener();

    void nowhereWatchCallState() {
        try {
            final android.telephony.TelephonyManager nowhereTelephony =
                    mContext.getSystemService(android.telephony.TelephonyManager.class);
            if (nowhereTelephony == null) {
                Slog.w(TAG, "nowhere: no telephony, in-call lock exemption off (NWP-20261013-08)");
                return;
            }
            // The DEFAULT TelephonyManager, never createForSubscriptionId: Telecom's consolidated
            // call state (TelephonyRegistry.notifyCallStateForAllSubs) reaches only listeners
            // registered on the default subscription, not one SIM's.
            nowhereTelephony.registerTelephonyCallback(
                    com.android.internal.os.BackgroundThread.getExecutor(),
                    mNowhereInCallListener);
        } catch (RuntimeException e) {
            Slog.w(TAG, "nowhere: call-state watch failed, in-call lock exemption off"
                    + " (NWP-20261013-08)", e);
        }
    }

    private final class NowhereInCallListener extends android.telephony.TelephonyCallback
            implements android.telephony.TelephonyCallback.CallStateListener {
        @Override
        public void onCallStateChanged(int state) {
            nowhereOnCallState(state);
        }
    }

    private void nowhereOnCallState(int state) {
        java.util.Map<Integer, String> nowhereDialers = null;
        if (state == android.telephony.TelephonyManager.CALL_STATE_RINGING
                || state == android.telephony.TelephonyManager.CALL_STATE_OFFHOOK) {
            final android.app.role.RoleManager nowhereRoles =
                    mContext.getSystemService(android.app.role.RoleManager.class);
            final UserManagerInternal nowhereUsers =
                    LocalServices.getService(UserManagerInternal.class);
            if (nowhereRoles != null && nowhereUsers != null) {
                final java.util.HashMap<Integer, String> nowhereFound = new java.util.HashMap<>();
                for (int nowhereUser : nowhereUsers.getUserIds()) {
                    if (nowhereUser == UserHandle.USER_SYSTEM) {
                        continue;
                    }
                    try {
                        final java.util.List<String> nowhereHolders =
                                nowhereRoles.getRoleHoldersAsUser(
                                        android.app.role.RoleManager.ROLE_DIALER,
                                        UserHandle.of(nowhereUser));
                        if (nowhereHolders.size() == 1) {
                            nowhereFound.put(nowhereUser, nowhereHolders.get(0));
                        }
                    } catch (RuntimeException e) {
                        Slog.w(TAG, "nowhere: no default dialer read for a user, it stays locked"
                                + " (NWP-20261013-08)", e);
                    }
                }
                nowhereDialers = java.util.Map.copyOf(nowhereFound);
            }
        }
        mNowhereInCallDialers = nowhereDialers;
        Slog.i(TAG, nowhereDialers != null
                ? "nowhere: in-call lock exemption on (NWP-20261013-08)"
                : "nowhere: in-call lock exemption off (NWP-20261013-08)");
        synchronized (mGlobalLock) {
            mRootWindowContainer.forAllDisplays(DisplayContent::notifyKeyguardFlagsChanged);
        }
    }

"""

LIFECYCLE_BLOCK = """\
        // NWP-20261013-08 (the #112 in-call exemption, see mNowhereInCallDialers): the call-state
        // watch starts once the activity manager is ready, after TelephonyRegistry and
        // RoleService have started. SystemServer dispatches boot phases with no lock held, so the
        // registration is never made under the WM lock.
        @Override
        public void onBootPhase(int phase) {
            if (phase == PHASE_ACTIVITY_MANAGER_READY) {
                mService.nowhereWatchCallState();
            }
        }

"""

# (file, anchor line, where the block goes, block)
EDITS = [
    (AR, "    private static boolean canShowWhenLockedInner(@NonNull ActivityRecord r) {", "after", AR_BLOCK),
    (AR, "            return activity != null && canShowWhenLockedInner(activity);", "before", AR_INHERIT_BLOCK),
    (ATMS, "    public static final class Lifecycle extends SystemService {", "before", ATMS_BLOCK),
    (ATMS, "        public ActivityTaskManagerService getService() {", "before", LIFECYCLE_BLOCK),
]


def edits(rel):
    return [e for e in EDITS if e[0] == rel]


def segment(anchor, where, block):
    return anchor + "\n" + block if where == "after" else block + anchor + "\n"


def current(rel, s):
    # This version exactly: one marker, every block next to its anchor, and no token anywhere else.
    if s.count(MARK) != 1 or s.count(CUR) != 1:
        return False
    for _, anchor, where, block in edits(rel):
        if ("\n" + s).count("\n" + segment(anchor, where, block)) != 1:
            return False
    return all(s.count(t) == sum(e[3].count(t) for e in edits(rel)) for t in TOKENS)


text = {}
for rel in FILES:
    try:
        with open(os.path.join(proj, rel), encoding="utf-8", newline="") as f:
            text[rel] = f.read()
    except UnicodeDecodeError:
        print(TAG, rel, "is not UTF-8 -- aborting, nothing written")
        sys.exit(1)

# 1. Any trace of this patch, in either file: it must be PATCH_VERSION in BOTH, or nothing is touched.
touched = [rel for rel in FILES if any(text[rel].count(t) for t in TOKENS)]
if touched:
    if all(current(rel, text[rel]) for rel in FILES):
        print(TAG, "already applied (" + version + ") -- skipped")
        sys.exit(0)
    print(TAG, "ERROR: an OLDER or partial copy of this patch (not " + version + ") is in", ", ".join(touched),
          "-- refusing to apply over it")
    print(TAG, "revert, then re-run:", revert)
    sys.exit(3)

# 2. Every anchor, in both files, before anything is written. Counted on the pristine text, as whole lines.
out = {}
for rel in FILES:
    lines = text[rel].split("\n")
    for _, anchor, where, block in edits(rel):
        n = text[rel].split("\n").count(anchor)
        if n != 1:
            print(TAG, "PATCH ANCHOR matched %d times (want 1) in %s: %s -- upstream changed? aborting, nothing"
                  " written" % (n, rel, anchor.strip()))
            sys.exit(2)
        i = lines.index(anchor)
        new = block.split("\n")[:-1]
        lines = lines[:i + 1] + new + lines[i + 1:] if where == "after" else lines[:i] + new + lines[i:]
    out[rel] = "\n".join(lines)

# 3. Write each file to a temp copy and check every copy; only then replace the originals.
tmps = []
ok = True
for rel in FILES:
    path = os.path.join(proj, rel)
    tmp = path + ".nowhere-tmp"
    with open(tmp, "w", encoding="utf-8", newline="") as f:
        f.write(out[rel])
    tmps.append(tmp)
    with open(tmp, encoding="utf-8", newline="") as f:
        chk = f.read()
    grow = sum(len(e[3]) for e in edits(rel))
    if (not current(rel, chk) or len(chk) != len(text[rel]) + grow
            or any(chk.split("\n").count(e[1]) != 1 for e in edits(rel))):
        ok = False
if not ok:
    for tmp in tmps:
        os.remove(tmp)
    print(TAG, "self-check failed -- both files left untouched")
    sys.exit(1)
for rel, tmp in zip(FILES, tmps):
    path = os.path.join(proj, rel)
    shutil.copymode(path, tmp)
    os.replace(tmp, path)
print(TAG, "patched ActivityRecord, ActivityTaskManagerService: a secondary user's activities never show over"
      " its lock, except its default dialer's during a call (" + version + ")")
PY
