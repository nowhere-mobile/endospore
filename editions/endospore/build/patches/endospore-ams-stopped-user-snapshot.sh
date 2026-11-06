#!/usr/bin/env bash
# endospore-ams-stopped-user-snapshot.sh -- AccountManagerService answers the system's all-users account
# enumerations for a STOPPED user from an in-memory snapshot, and never opens that user's accounts_de.db while it is
# stopped (NWP-20261005-22, the plaintext-email P0, docs/backlog.md "A COLD-LOCKED PHONE SHOWS THE ROAMED
# IDENTITY'S GOOGLE EMAIL IN PLAINTEXT").
#
# WHY. A cold lock stops the user, and AMS closes its databases at onUserStopped (purgeUserData). Traced on lynx
# 2026100503 (NWP-20261005-20): within 236 ms SyncManager's ACTION_USER_STOPPED handler runs updateRunningAccountsH,
# whose cleanup calls getAllAccountsForSystemProcess() over every ALIVE user, and removeStaleAccounts() calls
# getAccounts(userId) for each. Both rebuild the stopped user's UserAccounts over /data/system_de/<n>/accounts_de.db
# and WRITE it. So the DE file, which holds the account names (the email) in plaintext and is readable on a locked
# phone by design, cannot be sealed away at the lock: the next enumeration would recreate it EMPTY, and at resume
# syncDeCeAccountsLocked would delete the CE accounts as removed-while-locked. Simply leaving a stopped user out of
# the enumerations is no better (NWP-20261005-21): SyncStorageEngine.removeStaleAccounts would delete that session's
# per-app sync settings and periodic syncs at every lock.
#
# WHAT. (1) Lifecycle.onUserStopped snapshots the user's cached accounts BEFORE purgeUserData drops the cache.
# (2) getAccountsForSystem and the system-caller path of getAccounts(userId, pkg) answer a snapshotted user from the
# snapshot, so SyncManager sees exactly the accounts it saw before and the database is never opened. (3) A new
# Lifecycle.onUserStarting drops the snapshot and purges any UserAccounts some other caller opened during the lock,
# so the start reads the (restored) file fresh -- a connection left open on a replaced file would see the old inode.
# (4) User removal drops the snapshot. Account names live in system_server RAM only, never on disk; Chester accepted
# that on 2026-10-05 ("memory is fine"). This patch alone moves no file: roamd's seal-at-lock / restore-at-resume
# does that, and depends on it.
#
# Lands in services.jar -> full `m`, system reflash. To verify a build carries it: logcat shows
#   AccountManagerService: nowhere: snapshot <k> account(s) of stopped user <n> (NWP-20261005-22)
# right after "onUserStopped <n>", and no system_server fd under /data/system_de/<n>/ during the lock.
# Idempotent. Endospore (GrapheneOS) tree. See docs/framework-patches.md.
set -euo pipefail
T="${1:?usage: endospore-ams-stopped-user-snapshot.sh <graphene-tree>}"
AMS="$T/frameworks/base/services/core/java/com/android/server/accounts/AccountManagerService.java"
[ -f "$AMS" ] || { echo "[ams-stopped-snapshot] MISSING $AMS"; exit 1; }

python3 - "$AMS" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
MARK = 'NWP-20261005-22 (nowhere/endospore)'
if MARK in s:
    print("[ams-stopped-snapshot] already patched -- skipped"); sys.exit(0)

def sub(anchor, repl, what):
    global s
    if s.count(anchor) != 1:
        print("[ams-stopped-snapshot] %s ANCHOR NOT FOUND exactly once (upstream changed?) -- aborting" % what)
        sys.exit(2)
    s = s.replace(anchor, repl, 1)

# 1. Lifecycle: snapshot at stop, drop at start.
sub('''        @Override
        public void onUserStopped(@NonNull TargetUser user) {
            Slog.i(TAG, "onUserStopped " + user);
            mService.purgeUserData(user.getUserIdentifier());
        }
''', '''        @Override
        public void onUserStopped(@NonNull TargetUser user) {
            Slog.i(TAG, "onUserStopped " + user);
            // NWP-20261005-22 (nowhere/endospore): keep the stopped user's accounts in memory, so the system's
            // all-users enumerations never reopen (and rewrite) its accounts_de.db while it is stopped.
            mService.nowhereSnapshotStoppedUser(user.getUserIdentifier());
            mService.purgeUserData(user.getUserIdentifier());
        }

        @Override
        public void onUserStarting(@NonNull TargetUser user) {
            // NWP-20261005-22: the user is coming back -- read its accounts from disk again.
            mService.nowhereDropStoppedSnapshot(user.getUserIdentifier());
        }
''', 'Lifecycle.onUserStopped')

# 2. The snapshot itself, beside purgeUserData.
sub('''    private void purgeUserData(int userId) {
''', '''    // NWP-20261005-22 (nowhere/endospore): a stopped user's accounts, served to the system's all-users enumerations
    // (getAccountsForSystem, and getAccounts(userId, pkg) for a system caller) while the user is stopped. Guarded by
    // mUsers. Names in system_server RAM only; nothing here is written to disk.
    private final SparseArray<Account[]> mNowhereStoppedAccounts = new SparseArray<>();

    void nowhereSnapshotStoppedUser(int userId) {
        synchronized (mUsers) {
            UserAccounts accounts = mUsers.get(userId);
            if (accounts == null) {
                return; // never loaded this run: nothing cached, and no stopped-user answer to give
            }
            ArrayList<Account> all = new ArrayList<>();
            synchronized (accounts.cacheLock) {
                for (Account[] byType : accounts.accountCache.values()) {
                    for (Account a : byType) all.add(a);
                }
            }
            mNowhereStoppedAccounts.put(userId, all.toArray(new Account[0]));
            Slog.i(TAG, "nowhere: snapshot " + all.size() + " account(s) of stopped user " + userId
                    + " (NWP-20261005-22)");
        }
    }

    void nowhereDropStoppedSnapshot(int userId) {
        boolean had;
        synchronized (mUsers) {
            had = mNowhereStoppedAccounts.get(userId) != null;
            mNowhereStoppedAccounts.remove(userId);
        }
        if (had) {
            // Anything another caller opened while the user was stopped points at the file as it was then; the
            // start must read the file as it is now (restored at resume).
            purgeUserData(userId);
            Slog.i(TAG, "nowhere: user " + userId + " starting -- stopped-user snapshot dropped (NWP-20261005-22)");
        }
    }

    /** The snapshot of a stopped user, or null when the user is not in that state. */
    private Account[] nowhereStoppedAccounts(int userId) {
        synchronized (mUsers) {
            return mNowhereStoppedAccounts.get(userId);
        }
    }

    private void purgeUserData(int userId) {
''', 'purgeUserData')

# 3. User removal drops it.
sub('''                    Slog.i(TAG, "User " + userId + " removed");
                    purgeUserData(userId);
''', '''                    Slog.i(TAG, "User " + userId + " removed");
                    synchronized (mUsers) {
                        mNowhereStoppedAccounts.remove(userId); // NWP-20261005-22
                    }
                    purgeUserData(userId);
''', 'ACTION_USER_REMOVED')

# 4. getAccounts(userId, pkg) for a system caller (SyncManager.removeStaleAccounts).
sub('''    public Account[] getAccounts(int userId, String opPackageName) {
        int callingUid = Binder.getCallingUid();
        mAppOpsManager.checkPackage(callingUid, opPackageName);
        List<String> visibleAccountTypes = getTypesVisibleToCaller(callingUid, userId,
                opPackageName);
        if (visibleAccountTypes.isEmpty()) {
            return EMPTY_ACCOUNT_ARRAY;
        }
''', '''    public Account[] getAccounts(int userId, String opPackageName) {
        int callingUid = Binder.getCallingUid();
        mAppOpsManager.checkPackage(callingUid, opPackageName);
        List<String> visibleAccountTypes = getTypesVisibleToCaller(callingUid, userId,
                opPackageName);
        if (visibleAccountTypes.isEmpty()) {
            return EMPTY_ACCOUNT_ARRAY;
        }
        // NWP-20261005-22 (nowhere/endospore): a STOPPED user is answered from its snapshot for the system (this is
        // how SyncManager.removeStaleAccounts asks) -- opening the database here would rewrite accounts_de.db, and
        // an empty answer would make SyncManager delete the user's sync settings.
        if (UserHandle.isSameApp(callingUid, Process.SYSTEM_UID)) {
            Account[] stopped = nowhereStoppedAccounts(userId);
            if (stopped != null) {
                ArrayList<Account> out = new ArrayList<>();
                for (Account a : stopped) {
                    if (visibleAccountTypes.contains(a.type)) out.add(a);
                }
                return out.toArray(new Account[0]);
            }
        }
''', 'getAccounts(int, String)')

# 5. getAccountsForSystem (getAllAccountsForSystemProcess / getRunningAccountsForSystem).
sub('''        for (int userId : userIds) {
            UserAccounts userAccounts = getUserAccounts(userId);
            if (userAccounts == null) continue;
''', '''        for (int userId : userIds) {
            // NWP-20261005-22 (nowhere/endospore): a STOPPED user comes from its snapshot, never the database.
            Account[] stopped = nowhereStoppedAccounts(userId);
            if (stopped != null) {
                for (Account account : stopped) {
                    runningAccounts.add(new AccountAndUser(account, userId));
                }
                continue;
            }
            UserAccounts userAccounts = getUserAccounts(userId);
            if (userAccounts == null) continue;
''', 'getAccountsForSystem')

# The marker, so a re-run is a no-op.
s = s.replace('    private final SparseArray<Account[]> mNowhereStoppedAccounts',
              '    // ' + MARK + '\n    private final SparseArray<Account[]> mNowhereStoppedAccounts', 1)
open(p, 'w', encoding='utf-8').write(s)
print("[ams-stopped-snapshot] AccountManagerService: stopped users served from a snapshot (NWP-20261005-22)")
PY
