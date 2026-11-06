#!/usr/bin/env bash
# endospore-ams-account-reload.sh -- roam the signed-in account (DIA-20260802).
#
# The amnesiac roam restores a user's account dbs (/data/system_ce|de/<uid>/accounts_ce|de.db) UNDER
# AccountManagerService's OPEN connection, which caches the empty snapshot it read at unlock and never
# re-reads. Add two shell commands so the roam daemon can force AMS to re-read after it swaps the dbs:
#   cmd account detach-user <uid>  -- drop + close the cached UserAccounts + db connection, KEEPING the
#                                     CE-unlocked flag (unlike purgeUserData) so the reopen re-attaches CE
#   cmd account reload-user <uid>  -- re-open + re-read + re-validate + broadcast ACCOUNTS_CHANGED
# roamd brackets the db placement with detach/reload so the swap happens while the connection is closed
# (else a close-time WAL checkpoint clobbers the restored rows). Both shell/root only. Without this patch
# the roamed account db is on disk but AMS keeps serving the empty snapshot (Accounts: 0). Idempotent.
# See docs/sandboxed-play-roam.md and nowhere_roamd.sh acct_reload.
set -euo pipefail
T="${1:?usage: endospore-ams-account-reload.sh <graphene-tree>}"
AMS="$T/frameworks/base/services/core/java/com/android/server/accounts/AccountManagerService.java"
SHL="$T/frameworks/base/services/core/java/com/android/server/accounts/AccountManagerServiceShellCommand.java"
[ -f "$AMS" ] || { echo "[ams-reload] MISSING $AMS"; exit 1; }
[ -f "$SHL" ] || { echo "[ams-reload] MISSING $SHL"; exit 1; }

python3 - "$AMS" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
anchor = '''                    accounts.accountsDb.closeDebugStatement();
                    accounts.accountsDb.close();
                }
            }
        }
    }

    @VisibleForTesting
    void onUserUnlocked(Intent intent) {'''
methods = '''                    accounts.accountsDb.closeDebugStatement();
                    accounts.accountsDb.close();
                }
            }
        }
    }

    // DIA-20260802-05 (nowhere/endospore): re-read a user's on-disk account dbs after the amnesiac roam
    // restores accounts_ce.db/accounts_de.db under AMS's open connection. detachUserAccounts drops the
    // cached UserAccounts + closes its SQLite connection but KEEPS the CE-unlocked flag (unlike
    // purgeUserData, which clears mLocalUnlockedUsers and would leave CE un-attached). The roam daemon
    // detaches BEFORE it replaces the files (so the close-time WAL checkpoint writes into the still-empty
    // db, never over the restored rows), then reloadUserAccounts re-opens + re-reads + re-validates +
    // broadcasts. Shell/root only.
    void detachUserAccounts(int userId) {
        final int uid = Binder.getCallingUid();
        if (uid != Process.ROOT_UID && uid != Process.SHELL_UID && uid != Process.SYSTEM_UID) {
            throw new SecurityException("detachUserAccounts is shell/root only");
        }
        UserAccounts accounts;
        synchronized (mUsers) {
            accounts = mUsers.get(userId);
            mUsers.remove(userId);
            // NB do NOT touch mLocalUnlockedUsers: the user stays unlocked so the reopen re-attaches CE.
            AccountManager.invalidateLocalAccountsDataCaches();
        }
        if (accounts != null) {
            synchronized (accounts.dbLock) {
                synchronized (accounts.cacheLock) {
                    accounts.accountsDb.closeDebugStatement();
                    accounts.accountsDb.close();
                }
            }
        }
        Log.i(TAG, "detachUserAccounts: closed + dropped cached accounts for user " + userId);
    }

    void reloadUserAccounts(int userId) {
        final int uid = Binder.getCallingUid();
        if (uid != Process.ROOT_UID && uid != Process.SHELL_UID && uid != Process.SYSTEM_UID) {
            throw new SecurityException("reloadUserAccounts is shell/root only");
        }
        // DIA-20260818-02 (#732 round 2): STRIP BEFORE CONSTRUCTING UserAccounts.
        //
        // The first attempt stripped after getUserAccountsNotChecked() and was six milliseconds too late --
        // measured on lynx 2026081611:
        //     01:15:17.098  deleting account ... type com.google's registered authenticator no longer exist
        //     01:15:17.103  validateAccountsInternal#Deleted UserId=12, AccountId=1
        //     01:15:17.104  reloadUserAccounts: stripped 1 stale auth-uid mapping(s)
        // because getUserAccountsNotChecked VALIDATES ON CONSTRUCTION:
        //     if (accounts == null) { accounts = new UserAccounts(...); ...; validateAccounts = true; }
        // and detachUserAccounts (which the roam calls first, so the db can be swapped) removes the cached
        // entry -- guaranteeing that construction path every time. The strip was cleaning up after the fact.
        //
        // So do it here, in the detached window, straight on the DE database with the same AccountsDb.create
        // the UserAccounts constructor uses. Then construction-time validation reads an EMPTY TABLE_META:
        // validateAccountsInternal builds obsoleteAuthType by iterating that map, so an empty map means the
        // loop body never runs, nothing is marked obsolete, and no account is deleted. Validation then
        // repopulates the meta with the CURRENT authenticator uids, which is the self-healing property the
        // first attempt was also relying on.
        //
        // Failure here is deliberately non-fatal and LOUD: a roam that cannot strip is exactly the situation
        // that silently destroyed accounts for weeks, so it must not fail quietly again.
        try {
            File preNDbFile = new File(mInjector.getPreNDatabaseName(userId));
            File deDbFile = new File(mInjector.getDeDatabaseName(userId));
            AccountsDb preDb = AccountsDb.create(mContext, userId, preNDbFile, deDbFile);
            try {
                final Map<String, Integer> stale = preDb.findMetaAuthUid();
                for (Map.Entry<String, Integer> e : stale.entrySet()) {
                    preDb.deleteMetaByAuthTypeAndUid(e.getKey(), e.getValue());
                }
                Log.i(TAG, "reloadUserAccounts: pre-strip removed " + stale.size()
                        + " stale auth-uid mapping(s) before UserAccounts construction (roam #732)");
            } finally {
                preDb.close();
            }
        } catch (Throwable t) {
            Log.e(TAG, "reloadUserAccounts: PRE-STRIP FAILED for user " + userId
                    + " -- validate may delete the roamed account (#732)", t);
        }
        UserAccounts accounts = getUserAccountsNotChecked(userId); // re-creates -> re-reads DE + (unlocked) CE
        // Belt and braces: the pre-strip above is what prevents the deletion. This second pass only clears
        // anything validation re-added that is already stale again (appIds drift between materializes), and
        // costs nothing when there is nothing to remove. The
        // roamed accounts_de.db carries auth_uid_for_type rows minted under the PREVIOUS session's app ids;
        // validateAccountsInternal treats an unknown stored uid as an obsolete authenticator and
        // DESTRUCTIVELY DELETES the account. roamd used to strip these rows by shelling out to sqlite3 --
        // a USERDEBUG-ONLY binary, so on every `user` build the strip silently never ran and the roamed
        // Google account died seconds after placement (issue #732; captured verbatim by the device's own
        // report: "sqlite3: inaccessible or not found"). Doing it here, with the same AccountsDb methods
        // validate itself uses and under the same locks, works identically on every build type and closes
        // the window the external strip had. Validate then re-adopts the CURRENT authenticator uids and
        // rewrites the rows, so this is self-healing by design -- reload-user is shell/root only and is
        // called exactly once per roam placement, never on a db whose meta is live truth.
        synchronized (accounts.dbLock) {
            synchronized (accounts.cacheLock) {
                final Map<String, Integer> staleAuthUids = accounts.accountsDb.findMetaAuthUid();
                for (Map.Entry<String, Integer> e : staleAuthUids.entrySet()) {
                    accounts.accountsDb.deleteMetaByAuthTypeAndUid(e.getKey(), e.getValue());
                }
                if (!staleAuthUids.isEmpty()) {
                    Log.i(TAG, "reloadUserAccounts: stripped " + staleAuthUids.size()
                            + " stale auth-uid mapping(s) before validate (roam #732)");
                }
            }
        }
        validateAccountsInternal(accounts, true /* invalidateAuthenticatorCache */);
        AccountManager.invalidateLocalAccountUserDataCaches();
        sendAccountsChangedBroadcast(userId, null /* accountType */, "roam-reload");
        Log.i(TAG, "reloadUserAccounts: re-read on-disk accounts for user " + userId);
    }

    @VisibleForTesting
    void onUserUnlocked(Intent intent) {'''
if 'pre-strip removed ' in s:
    print("[ams-reload] AccountManagerService already patched (with the #732 PRE-strip) -- skipped"); sys.exit(0)
def extract_method(text, sig):
    # Return (start, end) spanning the whole method, by brace matching from its opening '{'.
    i = text.find(sig)
    if i < 0:
        return None
    b = text.find('{', i)
    if b < 0:
        return None
    depth, k = 0, b
    while k < len(text):
        if text[k] == '{':
            depth += 1
        elif text[k] == '}':
            depth -= 1
            if depth == 0:
                return (i, k + 1)
        k += 1
    return None

SIG = 'void reloadUserAccounts(int userId)'
if SIG in s:
    # DIA-20260818-02: VERSION-AGNOSTIC upgrade. Round 1 keyed this to one exact previous body and aborted
    # the moment a second revision existed. Replace the whole method instead, sourced from the same `methods`
    # blob the fresh-install path uses, so any prior version upgrades and there is one source of truth.
    span_tree = extract_method(s, SIG)
    span_new  = extract_method(methods, SIG)
    if not span_tree or not span_new:
        print("[ams-reload] could not brace-match reloadUserAccounts (upstream changed?) -- aborting"); sys.exit(2)
    canonical = methods[span_new[0]:span_new[1]]
    out = s[:span_tree[0]] + canonical + s[span_tree[1]:]
    open(p, 'w', encoding='utf-8').write(out)
    print("[ams-reload] UPGRADED reloadUserAccounts to the #732 PRE-construction strip"); sys.exit(0)
if anchor not in s:
    print("[ams-reload] AccountManagerService ANCHOR NOT FOUND (upstream changed?) -- aborting"); sys.exit(2)
open(p, 'w', encoding='utf-8').write(s.replace(anchor, methods, 1))
print("[ams-reload] added detachUserAccounts/reloadUserAccounts to AccountManagerService (#732 strip included)")
PY

python3 - "$SHL" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if 'runReloadUser' in s:
    print("[ams-reload] ShellCommand already patched -- skipped"); sys.exit(0)
reps = [
 ('''            case "set-bind-instant-service-allowed": {
                return runSetBindInstantServiceAllowed();
            }
        }
        return -1;''',
 '''            case "set-bind-instant-service-allowed": {
                return runSetBindInstantServiceAllowed();
            }
            case "detach-user": {
                return runDetachUser();
            }
            case "reload-user": {
                return runReloadUser();
            }
        }
        return -1;'''),
 ('''    private Integer parseUserId() {
        final String option = getNextOption();''',
 '''    // DIA-20260802-05 (nowhere/endospore): roam account re-read. `cmd account detach-user N` / `reload-user N`.
    private int runDetachUser() {
        final Integer userId = parsePositionalUserId();
        if (userId == null) return -1;
        mService.detachUserAccounts(userId);
        getOutPrintWriter().println("detached accounts for user " + userId);
        return 0;
    }

    private int runReloadUser() {
        final Integer userId = parsePositionalUserId();
        if (userId == null) return -1;
        mService.reloadUserAccounts(userId);
        getOutPrintWriter().println("reloaded accounts for user " + userId);
        return 0;
    }

    private Integer parsePositionalUserId() {
        final String arg = getNextArgRequired();
        try {
            return Integer.parseInt(arg);
        } catch (NumberFormatException e) {
            getErrPrintWriter().println("Error: bad user id '" + arg + "'");
            return null;
        }
    }

    private Integer parseUserId() {
        final String option = getNextOption();'''),
 ('''        pw.println("    Get whether binding to services provided by instant apps is allowed.");
    }
}''',
 '''        pw.println("    Get whether binding to services provided by instant apps is allowed.");
        pw.println("  detach-user USER_ID");
        pw.println("    Close + drop AMS's cached accounts for USER_ID (roam internal).");
        pw.println("  reload-user USER_ID");
        pw.println("    Re-read USER_ID's on-disk account dbs + re-validate (roam internal).");
    }
}'''),
]
for old, new in reps:
    if old not in s:
        print("[ams-reload] ShellCommand ANCHOR NOT FOUND (upstream changed?) -- aborting"); sys.exit(2)
    s = s.replace(old, new, 1)
open(p, 'w', encoding='utf-8').write(s)
print("[ams-reload] added detach-user/reload-user commands to AccountManagerServiceShellCommand")
PY
