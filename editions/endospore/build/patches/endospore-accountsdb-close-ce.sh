#!/usr/bin/env bash
# endospore-accountsdb-close-ce.sh -- AccountsDb.close() closes the CE accounts database too (NWP-20261004-01, L318).
#
# Android 17 split the CE accounts database into its own SQLiteOpenHelper with WAL (upstream 083147324f7b), but
# AccountsDb.close() still closes only the DE helper. So when a user stops, AccountManagerService.purgeUserData
# closes accounts_de.db and LEAKS the open accounts_ce.db (+ -wal, -shm) in system_server. vold's key removal
# then finds files in use: the CE key leaves the keyring but the busy inodes stay decryptable, vold retries for
# ~99 s and gives up. Device-measured on lynx 2026-10-04 (2026100401): user 15 stopped cleanly at 16:13:52, vold
# logged "Waiting for files to close never completed" at 16:15:34, and twenty minutes later system_server still
# held five fds under /data/system_ce/15/ and accounts_ce.db still read as plaintext SQLite -- the file the
# account seal roams real Google account rows through.
#
# The same leak defeated the roam's own detach bracket (endospore-ams-account-reload.sh): detach-user closes the
# DB "so the close-time WAL checkpoint writes into the still-empty db", but the CE half was never closed, so roamd
# replaced accounts_ce.db under a live connection.
#
# The fix closes the CE helper alongside the DE one and marks CE detached, so a caller still holding this
# AccountsDb gets the existing "CE database is not attached" refusal instead of silently reopening the file and
# leaking it again. Endospore only: LineageOS 22.2 still ATTACHes the CE file to the DE connection, so closing
# the DE helper closes both there and this anchor does not exist.
#
# Lands in services.jar -> full `m`, system reflash. To verify a build carries it: logcat shows
#   AccountsDb: nowhere: closed the CE accounts db with the DE one (NWP-20261004-01)
# right after "AccountManagerService: onUserStopped <n>", and no system_server fd under /data/system_ce/<n>/.
# Idempotent. See docs/framework-patches.md.
set -euo pipefail
T="${1:?usage: endospore-accountsdb-close-ce.sh <graphene-tree>}"
ADB="$T/frameworks/base/services/core/java/com/android/server/accounts/AccountsDb.java"
[ -f "$ADB" ] || { echo "[accountsdb-close-ce] MISSING $ADB"; exit 1; }

python3 - "$ADB" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
MARK = 'NWP-20261004-01 (nowhere/endospore)'
if MARK in s:
    print("[accountsdb-close-ce] already patched -- skipped"); sys.exit(0)
# The CE helper this closes, and the flag it resets, must both exist as this patch expects them -- a tree where
# either moved needs a human, not a guess.
for need in ('    private CeDatabaseHelper mCeDatabase;\n', '        private volatile boolean mCeAttached;\n'):
    if s.count(need) != 1:
        print("[accountsdb-close-ce] expected exactly one %r (upstream changed?) -- aborting" % need.strip()); sys.exit(2)
anchor = '''    @Override
    public void close() {
        mDeDatabase.close();
    }
'''
patched = '''    @Override
    public void close() {
        mDeDatabase.close();
        // NWP-20261004-01 (nowhere/endospore): close the CE helper too. Since the CE database got its own WAL helper
        // (083147324f7b) this method closed only DE, so purgeUserData left accounts_ce.db open in system_server
        // across the user stop and vold's key removal found it busy: the CE stayed decryptable after a completed
        // stop. Detach CE as well, so a caller still holding this AccountsDb is refused ("CE database is not
        // attached") rather than silently reopening the file.
        if (mCeDatabase != null) {
            mCeDatabase.close();
            mDeDatabase.mCeAttached = false;
            Slog.i(TAG, "nowhere: closed the CE accounts db with the DE one (NWP-20261004-01)");
        }
    }
'''
if s.count(anchor) != 1:
    print("[accountsdb-close-ce] AccountsDb.close() ANCHOR NOT FOUND (upstream changed?) -- aborting"); sys.exit(2)
open(p, 'w', encoding='utf-8').write(s.replace(anchor, patched, 1))
print("[accountsdb-close-ce] AccountsDb.close() now closes the CE helper (NWP-20261004-01)")
PY
