#!/usr/bin/env bash
# system-userdir-guard.sh <build-tree-root> -- NWP-20261003-01. Framework patch to frameworks/base, BOTH editions.
#
# WHY. A removed user's /data/system/users/<id> came back after the reap: on lynx 2026-10-02 odtest57's users/11
# held settings_secure.xml and settings_ssaid.xml, written after the directory was deleted, with no 11.xml. The
# writers are late writes for the removed user (SettingsProvider's SettingsState; AppIdleHistory, reproduced on
# lynx 2026-10-03 with `am set-standby-bucket --user 11 ...` + `dumpsys usagestats flush`), and both make the
# directory through the parent mkdirs in android.util.AtomicFile.startWrite; package-restrictions goes through the
# unconditional one in ResilientAtomicFile.startWrite. The orphan is cleartext (system DE key), survives reboots,
# and, from GrapheneOS source (not yet seen on a device), the next user given that id loads it as its own state
# inside createAndManageUser, before any Nowhere code runs. docs/backlog.md, "A reaped user's
# `/data/system/users/<id>` is re-created ...".
# WHAT. One invariant: UserManagerService and its UserDataPreparer create /data/system/users/<n> (empty, for a new
# user), and AtomicFile and ResilientAtomicFile never re-create a missing one: they refuse (IOException, logged)
# for n != 0, and a missing subdirectory of an existing users/<n> is still created. Writers that mkdir by hand
# (wallpaper, user photo, instant apps, IME subtypes) can still make one; the discards below, and roamd, remove
# what they leave. BiometricUserState drops the refusal instead of rethrowing it on an AsyncTask thread, which would
# kill system_server. UserDataPreparer re-creates users/<n> after its new-user recovery deleted it, because that
# user stays alive, and logs when it cannot. UserManagerService discards a stale users/<n> when it allocates id n,
# and at boot discards every numeric users/<n> whose user it did not read, with its own delete that logs nothing;
# what it cannot discard refuses that creation, and in both cases keeps the id out of use until the next boot.
# Logs carry counts, user ids and allowlisted file names only (a fixed list, plus the biometric settings files,
# whose names carry at most a sensor id): an application-restrictions file is named res_<package>.xml. Seven
# anchors in five files, all whole lines, each unique and pristine in the GrapheneOS and the LineageOS tree; no
# other Nowhere patch touches these files.
# ARTIFACT. framework.jar (AtomicFile) and services.jar (the other four) -> /system/framework -> reflash `system`.
# VERIFY. In the built jars' dex: framework.jar holds "nowhere: refused to re-create the missing system dir of
# user " with the control "Failed to create directory for "; services.jar holds that literal, " starts with an
# empty system dir, " and " orphan system dir(s) of removed users at boot (NWP-20261003-01)", with the control
# "Duplicate startWrite call?". On a device: logcat "UserManagerService: nowhere: discarded <k> orphan system
# dir(s) of removed users at boot" once per boot, and "nowhere: user <N> starts with an empty system dir, <k>
# stale entries discarded" at every sign-in. The "ok" this script's run prints in the build log is NOT evidence.
# Endospore: run by editions/endospore/build/build-device.sh (GOS_MANDATED_PATCHES). Diaspore: MANUAL.
# Register: docs/framework-patches.md. Suite: editions/diaspore/build/test-system-userdir-guard.sh.
# Exit: 0 applied, or already applied; 1 usage, missing file, or failed self-check; 2 anchor drift;
#       3 an older or partial copy of this patch is present (prints the revert command).
# Nothing is written unless every anchor in every file matches exactly once.
set -euo pipefail
T="${1:?usage: system-userdir-guard.sh <build-tree-root>}"
PROJ="$T/frameworks/base"
AF=core/java/android/util/AtomicFile.java
RAF=services/core/java/com/android/server/pm/ResilientAtomicFile.java
BUS=services/core/java/com/android/server/biometrics/sensors/BiometricUserState.java
UDP=services/core/java/com/android/server/pm/UserDataPreparer.java
UMS=services/core/java/com/android/server/pm/UserManagerService.java
for REL in $AF $RAF $BUS $UDP $UMS; do
  [ -f "$PROJ/$REL" ] || { echo "[system-userdir-guard] MISSING $PROJ/$REL"; exit 1; }
done

python3 - "$PROJ" "git -C $PROJ checkout -- $AF $RAF $BUS $UDP $UMS" $AF $RAF $BUS $UDP $UMS <<'PY'
import os, shutil, sys

proj, revert = sys.argv[1], sys.argv[2]
AF, RAF, BUS, UDP, UMS = sys.argv[3:8]
FILES = [AF, RAF, BUS, UDP, UMS]
TAG = "[system-userdir-guard]"
REV = "1"
MARK = "nowhere-userdir-guard rev "
CUR = MARK + REV
TOKENS = ("nowhere-userdir-guard", "NWP-20261003-01", "nowhereGuard")

AF_BLOCK = """\
            // nowhere-userdir-guard rev 1 (NWP-20261003-01): UserManagerService and its
            // UserDataPreparer create a user's /data/system/users/<id>, removing the user deletes
            // it, and this class never re-creates a missing one: a write that finds it missing is
            // a late write for a removed user, and the mkdirs below would re-create it as a
            // cleartext orphan (system DE key) that survives reboots and is loaded by the next
            // user given that id. Refuse it the way a failed mkdirs is refused: the callers catch
            // the IOException (BiometricUserState, which would rethrow it on an AsyncTask thread,
            // drops it). User 0 is exempt, and a missing subdirectory of an existing users/<id> is
            // still created. The message must stay clear of SettingsState's mkdir-retry text, and
            // the log names a writer only from a fixed list or as a biometric settings file, whose
            // name carries at most a sensor id: a restrictions file name carries a package name.
            for (File nowhereGuardDir = parent; nowhereGuardDir != null;
                    nowhereGuardDir = nowhereGuardDir.getParentFile()) {
                if (!"/data/system/users".equals(nowhereGuardDir.getParent())) {
                    continue;
                }
                final String nowhereGuardId = nowhereGuardDir.getName();
                if (!"0".equals(nowhereGuardId) && nowhereGuardId.matches("[0-9]+")
                        && !nowhereGuardDir.isDirectory()) {
                    final String nowhereGuardName = mBaseName.getName();
                    final boolean nowhereGuardListed = java.util.Set.of("settings_secure.xml",
                            "settings_system.xml", "settings_ssaid.xml", "settings_config.xml",
                            "app_idle_stats.xml", "package-restrictions.xml", "appwidgets.xml",
                            "wallpaper_info.xml").contains(nowhereGuardName)
                            || nowhereGuardName.matches(
                                    "settings_(fingerprint|face)(_[0-9]+)?[.]xml");
                    final String nowhereGuardWriter =
                            nowhereGuardListed ? nowhereGuardName : "other";
                    Log.w(LOG_TAG, "nowhere: refused to re-create the missing system dir of user "
                            + nowhereGuardId + " for " + nowhereGuardWriter + " via "
                            + android.os.Debug.getCallers(5) + " (NWP-20261003-01)");
                    throw new IOException(
                            "nowhere: missing user system dir not re-created (NWP-20261003-01)");
                }
                break;
            }
"""

RAF_BLOCK = """\
        // nowhere-userdir-guard rev 1 (NWP-20261003-01): UserManagerService and its
        // UserDataPreparer create a user's /data/system/users/<id>, removing the user deletes it,
        // and this class never re-creates a missing one. The mkdirs below runs on every write, so
        // a late package-restrictions write for a removed user would re-create it as a cleartext
        // orphan (system DE key) that the next user given that id loads. Refuse it the same way
        // android.util.AtomicFile does: user 0 is exempt, and nothing changes while the directory
        // exists. Settings.writePackageRestrictions catches the IOException.
        for (File nowhereGuardDir = mFile.getParentFile(); nowhereGuardDir != null;
                nowhereGuardDir = nowhereGuardDir.getParentFile()) {
            if (!"/data/system/users".equals(nowhereGuardDir.getParent())) {
                continue;
            }
            final String nowhereGuardId = nowhereGuardDir.getName();
            if (!"0".equals(nowhereGuardId) && nowhereGuardId.matches("[0-9]+")
                    && !nowhereGuardDir.isDirectory()) {
                final String nowhereGuardName = mFile.getName();
                final boolean nowhereGuardListed = java.util.Set.of("settings_secure.xml",
                        "settings_system.xml", "settings_ssaid.xml", "settings_config.xml",
                        "app_idle_stats.xml", "package-restrictions.xml", "appwidgets.xml",
                        "wallpaper_info.xml").contains(nowhereGuardName)
                        || nowhereGuardName.matches(
                                "settings_(fingerprint|face)(_[0-9]+)?[.]xml");
                final String nowhereGuardWriter =
                        nowhereGuardListed ? nowhereGuardName : "other";
                Slog.w(LOG_TAG, "nowhere: refused to re-create the missing system dir of user "
                        + nowhereGuardId + " for " + nowhereGuardWriter + " via "
                        + android.os.Debug.getCallers(5) + " (NWP-20261003-01)");
                throw new IOException(
                        "nowhere: missing user system dir not re-created (NWP-20261003-01)");
            }
            break;
        }
"""

BUS_BLOCK = """\
            // nowhere-userdir-guard rev 1 (NWP-20261003-01): android.util.AtomicFile refuses to
            // re-create a removed user's /data/system/users/<id>. This runs on an AsyncTask thread,
            // where the rethrow below would kill system_server, and a biometric removal callback
            // can land after the user's directory is gone (LockSettingsService waits for the HAL
            // for a bounded time only). That refusal is logged and dropped; every other failure is
            // rethrown as before.
            final String nowhereGuardRefusal =
                    "nowhere: missing user system dir not re-created (NWP-20261003-01)";
            if (t instanceof IOException && nowhereGuardRefusal.equals(t.getMessage())) {
                Slog.w(TAG, "nowhere: dropped a biometric state write for the missing system dir "
                        + mFile.getParent() + " (NWP-20261003-01)");
                return;
            }
"""

UDP_BLOCK = """\
                // nowhere-userdir-guard rev 1 (NWP-20261003-01): for a DE prepare, that destroy
                // deleted /data/system/users/<id> of a user who stays alive. AtomicFile and
                // ResilientAtomicFile never re-create a missing one (to them its absence means a
                // removed user), so re-create it here, empty, as user creation does, and say so
                // when that fails: the user would then run without saving its settings.
                if ((flags & StorageManager.FLAG_STORAGE_DE) != 0
                        && Objects.equals(volumeUuid, StorageManager.UUID_PRIVATE_INTERNAL)) {
                    final File nowhereGuardDir = getUserSystemDirectory(userId);
                    if (nowhereGuardDir.mkdirs()) {
                        Slog.w(TAG, "nowhere: re-created the system dir of new user " + userId
                                + " after a failed prepare (NWP-20261003-01)");
                    } else if (!nowhereGuardDir.isDirectory()) {
                        Slog.e(TAG, "nowhere: could not re-create the system dir of new user "
                                + userId + " after a failed prepare (NWP-20261003-01)");
                    }
                }
"""

UMS_BOOT_BLOCK = """\
            // nowhere-userdir-guard rev 1 (NWP-20261003-01): this service and its UserDataPreparer
            // create a user's /data/system/users/<id> (empty, for a new user), and
            // android.util.AtomicFile and ResilientAtomicFile never re-create a missing one; a
            // writer that makes the directory by hand still can. A directory whose user is not in
            // the list just read was left by a removed user (a write that beat the removal, such a
            // writer, or an older build) and is cleartext at rest (system DE key): discard it
            // before anything can load it. One that cannot be discarded keeps its id out of use
            // until the next boot, so no new user is given it. Partial users are in the list, and
            // cleanupPartialUsers removes them. Counts and user ids only: a file name can carry a
            // package name.
            final ArrayList<Integer> nowhereGuardDiscarded = new ArrayList<>();
            final ArrayList<Integer> nowhereGuardKept = new ArrayList<>();
            int nowhereGuardLeft = 0;
            final File[] nowhereGuardDirs = mUsersDir.listFiles();
            if (nowhereGuardDirs != null) {
                for (File nowhereGuardDir : nowhereGuardDirs) {
                    final String nowhereGuardId = nowhereGuardDir.getName();
                    if ("0".equals(nowhereGuardId) || !nowhereGuardId.matches("[0-9]{1,9}")
                            || !nowhereGuardDir.isDirectory()) {
                        continue;
                    }
                    final int nowhereGuardUser = Integer.parseInt(nowhereGuardId);
                    synchronized (mUsersLock) {
                        if (mUsers.get(nowhereGuardUser) != null) {
                            continue;
                        }
                    }
                    final int nowhereGuardEntries = nowhereGuardDelete(nowhereGuardDir);
                    if (nowhereGuardEntries == 0) {
                        nowhereGuardDiscarded.add(nowhereGuardUser);
                    } else {
                        nowhereGuardLeft += nowhereGuardEntries;
                        nowhereGuardKept.add(nowhereGuardUser);
                        synchronized (mUsersLock) {
                            mRemovingUserIds.put(nowhereGuardUser, true);
                        }
                    }
                }
            }
            Slog.i(LOG_TAG, "nowhere: discarded " + nowhereGuardDiscarded.size()
                    + " orphan system dir(s) of removed users at boot (NWP-20261003-01): user ids "
                    + nowhereGuardDiscarded);
            if (nowhereGuardLeft > 0) {
                Slog.w(LOG_TAG, "nowhere: " + nowhereGuardLeft + " entries of orphan system dirs"
                        + " could not be discarded at boot; their ids stay unused until the next"
                        + " boot (NWP-20261003-01): user ids " + nowhereGuardKept);
            }
"""

UMS_CREATE_BLOCK = """\
                // NWP-20261003-01 (nowhere-userdir-guard, see the constructor): a new user starts
                // with an EMPTY /data/system/users/<id>. The id was just allocated, so anything
                // there was left by an earlier user given the same id, and services would load it
                // lazily as this user's own state: SettingsProvider's SECURE and SSAID during
                // createAndManageUser, before any Nowhere code runs. Discard it. If any of it
                // stays, refuse the creation and keep the id out of use until the next boot, so
                // the next creation is given another id. Counts only: a file name can carry a
                // package name.
                final File nowhereGuardDir = Environment.getUserSystemDirectory(userId);
                final String[] nowhereGuardStale = nowhereGuardDir.list();
                final int nowhereGuardCount =
                        nowhereGuardStale == null ? 0 : nowhereGuardStale.length;
                final int nowhereGuardLeft = nowhereGuardDelete(nowhereGuardDir);
                if (nowhereGuardLeft > 0) {
                    synchronized (mUsersLock) {
                        mRemovingUserIds.put(userId, true);
                    }
                    throwCheckedUserOperationException("nowhere: the stale system dir of user "
                            + userId + " could not be discarded, " + nowhereGuardLeft
                            + " entries left (NWP-20261003-01)", USER_OPERATION_ERROR_UNKNOWN);
                }
                Slog.i(LOG_TAG, "nowhere: user " + userId + " starts with an empty system dir, "
                        + nowhereGuardCount + " stale entries discarded (NWP-20261003-01)");
"""

UMS_DELETE_BLOCK = """\
    // NWP-20261003-01 (nowhere-userdir-guard, see the constructor): deletes a stale
    // /data/system/users/<id> and returns how many entries it could not remove, the directory
    // itself included (0: it is gone). Unlike FileUtils.deleteContentsAndDir it logs nothing,
    // since a file name can carry a package name, and it never follows a symbolic link out of
    // the directory. No filesystem error escapes it: the constructor runs it at every boot.
    private static int nowhereGuardDelete(File nowhereGuardFile) {
        final java.nio.file.Path nowhereGuardPath;
        try {
            nowhereGuardPath = nowhereGuardFile.toPath();
        } catch (RuntimeException nowhereGuardError) {
            return 1;
        }
        int nowhereGuardLeft = 0;
        if (java.nio.file.Files.isDirectory(nowhereGuardPath,
                java.nio.file.LinkOption.NOFOLLOW_LINKS)) {
            final File[] nowhereGuardChildren = nowhereGuardFile.listFiles();
            if (nowhereGuardChildren != null) {
                for (File nowhereGuardChild : nowhereGuardChildren) {
                    nowhereGuardLeft += nowhereGuardDelete(nowhereGuardChild);
                }
            }
        }
        try {
            java.nio.file.Files.deleteIfExists(nowhereGuardPath);
        } catch (IOException | RuntimeException nowhereGuardError) {
            nowhereGuardLeft++;
        }
        return nowhereGuardLeft;
    }

"""

# (file, anchor line -- pristine and whole in both trees, where the block goes, block). Each file's edits are
# listed in file order.
EDITS = [
    (AF, "            File parent = mNewName.getParentFile();", "after", AF_BLOCK),
    (RAF, "        new File(mFile.getParent()).mkdirs();", "before", RAF_BLOCK),
    (BUS, '            Slog.e(TAG, "Failed to write settings, restoring backup", t);', "before", BUS_BLOCK),
    (UDP, "                destroyUserDataLI(volumeUuid, userId, flags);", "after", UDP_BLOCK),
    (UMS, "            readUserListLP();", "after", UMS_BOOT_BLOCK),
    (UMS, "                Environment.getUserSystemDirectory(userId).mkdirs();", "before", UMS_CREATE_BLOCK),
    (UMS, "    private static String packageToRestrictionsFileName(String packageName) {", "before",
     UMS_DELETE_BLOCK),
]


def edits(rel):
    return [e for e in EDITS if e[0] == rel]


def segment(anchor, where, block):
    return anchor + "\n" + block if where == "after" else block + anchor + "\n"


def current(rel, s):
    # This revision exactly: one marker, every block next to its anchor, and no token anywhere else.
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

# 1. Any trace of this patch, in any file: it must be this revision in ALL of them, or nothing is touched.
touched = [rel for rel in FILES if any(text[rel].count(t) for t in TOKENS)]
if touched:
    if all(current(rel, text[rel]) for rel in FILES):
        print(TAG, "already applied (rev " + REV + ") -- skipped")
        sys.exit(0)
    print(TAG, "an older or partial copy of this patch is in", ", ".join(touched), "-- refusing to apply over it")
    print(TAG, "revert, then re-run:", revert)
    sys.exit(3)

# 2. Every anchor, in every file, before anything is written. Counted on the pristine text, as whole lines.
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

# 3. Write every file to a temp copy and check every copy; only then replace the originals.
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
    print(TAG, "self-check failed -- every file left untouched")
    sys.exit(1)
for rel, tmp in zip(FILES, tmps):
    path = os.path.join(proj, rel)
    shutil.copymode(path, tmp)
    os.replace(tmp, path)
print(TAG, "patched AtomicFile, ResilientAtomicFile, BiometricUserState, UserDataPreparer, UserManagerService:"
      " a removed user's /data/system/users/<id> is not re-created, a new user's starts empty, orphans are"
      " discarded at boot (rev " + REV + ")")
PY
