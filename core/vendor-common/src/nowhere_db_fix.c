// nowhere_db_fix -- the fixed database repairs roamd and the gate used to shell out to /system/bin/sqlite3
// for. Sibling of nowhere_seed_home, and it exists for the same reason that tool does (DIA-20260810-01):
// sqlite3 is a USERDEBUG-ONLY binary, so every one of these repairs silently never ran on a `user` build
// while working on lynx, the one device built userdebug.
//
// The account casualty is what surfaced it (#732, DIA-20260817-01): acct_reload's strip of stale
// auth_uid_for_type meta was one of these dead call sites, and without it AccountManagerService's
// validateAccountsInternal DESTRUCTIVELY DELETES the roamed Google account -- proven by same-device
// same-profile A/B on frankel (userdebug-relocked roams; user destroys) and by the device's own issue
// report: `nowhere_roamd.sh[2985]: sqlite3: inaccessible or not found`. THAT repair moved in-process into
// the AMS reload-user patch (endospore-ams-account-reload.sh), where the db already lives; this tool takes
// the four script-side survivors.
//
// Same design contract as nowhere_seed_home: a general SQL shell is a capability a hardened release image
// must not contain, so this binary accepts NO SQL from its caller -- subcommands are fixed statements,
// numeric arguments are validated as numbers, and table names (telscrub only) are validated as bare
// identifiers before being quoted. file_contexts labels it nowhere_exec, same as seed_home, so only the
// privileged daemons may exec it.
//
// One deliberate improvement over the sqlite3 call sites: every connection sets busy_timeout=4000. The old
// CLI calls for the launcher and MMS repairs set NO timeout, so a repair racing a live provider write could
// return SQLITE_BUSY and silently no-op even on userdebug. (The gate's janitor already set it per
// invocation because each CLI run was a fresh process; here one PRAGMA per open suffices -- the setting is
// per-connection, and each subcommand is one connection.)
//
// Usage:
//   nowhere_db_fix launcher-relabel <launcher.db> <serial>
//       UPDATE favorites SET profileId=<serial>
//       Roamed favorites carry the previous session's user serial; Launcher3 drops rows whose profileId it
//       does not recognise, so without this the restored home layout is invisible. (roamd, at restore.)
//   nowhere_db_fix launcher-widgets <launcher.db>
//       UPDATE favorites SET restored=15 WHERE itemType=4
//       Marks roamed widgets as pending so Launcher3's WidgetInflater self-heal re-binds them. (roamd.)
//   nowhere_db_fix mms-remap <mmssms.db> <uid>
//       Rewrites part._data paths that point into a PREVIOUS user's telephony dir so restored MMS
//       attachments resolve under the current user. (roamd, at restore; best-effort.)
//   nowhere_db_fix media-remap <external.db> <uid>
//       In MediaProvider's `files` table: drops the later duplicates of a file under /storage/emulated/<any user>
//       (case-insensitive, keeping the lowest _id), then repoints every remaining /storage/emulated/<old user> row
//       at /storage/emulated/<uid>. Index rows only, never a file. One transaction. Prints `<remapped> <dropped>`.
//       (roamd, after the CE and #de restores; NWP-20261124-01.)
//   nowhere_db_fix telscrub <db> <table>...
//       DELETE FROM "<table>" for each named table (missing tables are skipped, never abort the batch --
//       legacy schemas lack attachments/drm), then VACUUM so the freed pages are actually overwritten, then
//       a WAL checkpoint(TRUNCATE) so a WAL-mode db does not keep the old pages under the rewrite.
//       Table names must be bare identifiers. (the gate's boot janitor; crash-residue backstop.)
//   nowhere_db_fix accounts-count <accounts_ce.db>
//       Prints the number of rows in `accounts`, or -1 when the table cannot be read. (roamd, the #sys seal guard.)
//   nowhere_db_fix accounts-google <accounts_ce.db>
//       Line 1: the number of rows in `accounts` (every type). Then, in _id order, one line per com.google row:
//       its name, or `?` when the name is NULL, empty, or holds a byte below 0x20 or 0x7f. Read-only. roamd
//       hashes the names into the account arrival record at placement (NWP-20261104-05; #743, dn-1025 #2).
//
// Exit codes are DISTINCT so the callers can log a truthful reason (the whole lesson of the sqlite3 era was
// silent failure):
//   0  done (rows-changed count on stdout; telscrub prints tables-cleared count)
//   2  bad usage / invalid argument
//   3  cannot open the database
//   6  a database error while writing (telscrub: the VACUUM or the closing WAL checkpoint failed; media-remap:
//      any statement failed, rolled back, the db unchanged), or while reading (accounts-count / accounts-google:
//      the table cannot be read)

#include <ctype.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sqlite3.h>

static int open_db(const char *path, sqlite3 **db) {
    if (sqlite3_open_v2(path, db, SQLITE_OPEN_READWRITE, NULL) != SQLITE_OK) {
        fprintf(stderr, "nowhere_db_fix: cannot open %s: %s\n", path, *db ? sqlite3_errmsg(*db) : "?");
        if (*db) sqlite3_close(*db);
        return -1;
    }
    // Per-connection, so once is enough (unlike the old per-process sqlite3 CLI calls). A live provider
    // holding the write lock makes us wait up to 4s and then fail LOUDLY instead of no-opping.
    sqlite3_exec(*db, "PRAGMA busy_timeout=4000;", NULL, NULL, NULL);
    return 0;
}

static int parse_ll(const char *s, long long *out) {
    char *end = NULL;
    if (!s || !*s) return -1;
    *out = strtoll(s, &end, 10);
    return (end && *end == '\0') ? 0 : -1;
}

// A bare SQL identifier: [A-Za-z_][A-Za-z0-9_]*. Anything else is refused -- table names are the one place
// caller data reaches this binary, and the contract is that no caller input is ever interpretable as SQL.
static int ident_ok(const char *s) {
    if (!s || !(isalpha((unsigned char)*s) || *s == '_')) return 0;
    for (s++; *s; s++)
        if (!(isalnum((unsigned char)*s) || *s == '_')) return 0;
    return 1;
}

static int exec_fmt(sqlite3 *db, const char *what, const char *fmt, ...) {
    char sql[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(sql, sizeof(sql), fmt, ap);
    va_end(ap);
    char *err = NULL;
    if (sqlite3_exec(db, sql, NULL, NULL, &err) != SQLITE_OK) {
        fprintf(stderr, "nowhere_db_fix: %s: %s\n", what, err ? err : "?");
        sqlite3_free(err);
        return -1;
    }
    return 0;
}

// accounts-google's line rule (NWP-20261104-05): a name is printed only when it cannot split or forge a line --
// not NULL, not empty, no byte below 0x20 and no 0x7f. Anything else prints as `?`. UTF-8 (bytes >= 0x80) passes.
static int acct_name_printable(const unsigned char *s, int n) {
    if (!s || n <= 0) return 0;
    for (int i = 0; i < n; i++)
        if (s[i] < 0x20 || s[i] == 0x7f) return 0;
    return 1;
}

// media-remap's no-op for MediaProvider's trigger functions (NWP-20261124-01). AOSP MediaProvider's DatabaseHelper
// creates triggers on `files` that call _INSERT/_UPDATE/_DELETE, functions it registers in its own process only, so
// on a plain connection an UPDATE or DELETE of `files` fails with "no such function". Read from the AOSP source, to
// be confirmed on a handset. The provider rebuilds what those callbacks feed at its next scan.
static void media_noop_fn(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
    (void)argc;
    (void)argv;
    sqlite3_result_null(ctx);
}

int main(int argc, char **argv) {
    if (argc < 3) goto usage;
    const char *op = argv[1];
    sqlite3 *db = NULL;

    if (strcmp(op, "launcher-relabel") == 0) {
        long long serial;
        if (argc != 4 || parse_ll(argv[3], &serial) != 0) goto usage;
        if (open_db(argv[2], &db) != 0) return 3;
        if (exec_fmt(db, "launcher-relabel",
                     "UPDATE favorites SET profileId=%lld;", serial) != 0) {
            sqlite3_close(db);
            return 6;
        }
        printf("%d\n", sqlite3_changes(db));
        sqlite3_close(db);
        return 0;
    }

    /* accounts-count <accounts_ce.db>: print the number of rows in `accounts`, or -1 if unreadable. #743:
     * roamd guarded the #sys seal with `[ ! -s accounts_ce.db ]`, but SQLite never shrinks a file when rows
     * are deleted -- measured on lynx: 12288 bytes with one account, 12288 with none -- so the guard could
     * only ever catch a MISSING file, never the case it was written for. A rowless db therefore sealed over a
     * good head and made the loss permanent: that is what turned #732 from a bad session into an
     * unrecoverable one. Lives here rather than in a shell sqlite3 call because `sqlite3` does not exist on a
     * `user` build -- the exact trap that caused #732 itself.
     *
     * Read-only: opens, counts, prints. Never writes, so it cannot damage the db it inspects. -1 distinguishes
     * "unreadable/no such table" from "zero rows"; conflating those is how a guard ends up refusing every seal
     * on an unrelated schema change. */
    if (strcmp(op, "accounts-count") == 0) {
        if (argc != 3) goto usage;
        if (open_db(argv[2], &db) != 0) return 3;
        sqlite3_stmt *st = NULL;
        if (sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM accounts;", -1, &st, NULL) != SQLITE_OK) {
            /* Trailing newline matters: roamd redirects our stderr into roam.log, and without it this ran
             * straight into the next line ("accounts-1" on lynx 2026081814) -- unreadable in a file that is
             * read by grepping. */
            fprintf(stderr, "accounts-count: %s\n", sqlite3_errmsg(db));
            printf("-1\n");
            sqlite3_finalize(st);
            sqlite3_close(db);
            return 6;
        }
        long long n = (sqlite3_step(st) == SQLITE_ROW) ? sqlite3_column_int64(st, 0) : -1;
        printf("%lld\n", n);
        sqlite3_finalize(st);
        sqlite3_close(db);
        return 0;
    }

    /* accounts-google <accounts_ce.db> (NWP-20261104-05; #743, dn-1025 #2): line 1 the total number of rows in
     * `accounts` (every type, the number accounts-count prints), then, in _id order, one line per com.google row:
     * its name, or `?` (acct_name_printable). roamd hashes those names into the arrival record at placement and
     * never logs or stores one. Read-only like accounts-count. BOTH statements are prepared before anything is
     * printed, so a prepare failure (no table, no `type` column) prints `-1` alone, as accounts-count does; a
     * step error exits 6 too, and roamd uses the output only on exit 0. */
    if (strcmp(op, "accounts-google") == 0) {
        if (argc != 3) goto usage;
        if (open_db(argv[2], &db) != 0) return 3;
        sqlite3_stmt *tot = NULL, *goo = NULL;
        if (sqlite3_prepare_v2(db, "SELECT COUNT(*) AS total FROM accounts;", -1, &tot, NULL) != SQLITE_OK ||
            sqlite3_prepare_v2(db, "SELECT name FROM accounts WHERE type = 'com.google' ORDER BY _id;", -1, &goo,
                               NULL) != SQLITE_OK ||
            sqlite3_step(tot) != SQLITE_ROW) {
            fprintf(stderr, "accounts-google: %s\n", sqlite3_errmsg(db));
            printf("-1\n");
            sqlite3_finalize(tot);
            sqlite3_finalize(goo);
            sqlite3_close(db);
            return 6;
        }
        printf("%lld\n", sqlite3_column_int64(tot, 0));
        int rc;
        while ((rc = sqlite3_step(goo)) == SQLITE_ROW) {
            const unsigned char *nm = sqlite3_column_text(goo, 0);
            int n = sqlite3_column_bytes(goo, 0);
            if (acct_name_printable(nm, n)) {
                fwrite(nm, 1, (size_t)n, stdout);
                fputc('\n', stdout);
            } else {
                fputs("?\n", stdout);
            }
        }
        int bad = (rc != SQLITE_DONE);
        if (bad) fprintf(stderr, "accounts-google: %s\n", sqlite3_errmsg(db));
        sqlite3_finalize(tot);
        sqlite3_finalize(goo);
        sqlite3_close(db);
        return bad ? 6 : 0;
    }

    if (strcmp(op, "launcher-widgets") == 0) {
        if (argc != 3) goto usage;
        if (open_db(argv[2], &db) != 0) return 3;
        if (exec_fmt(db, "launcher-widgets",
                     "UPDATE favorites SET restored=15 WHERE itemType=4;") != 0) {
            sqlite3_close(db);
            return 6;
        }
        printf("%d\n", sqlite3_changes(db));
        sqlite3_close(db);
        return 0;
    }

    if (strcmp(op, "mms-remap") == 0) {
        long long uid;
        if (argc != 4 || parse_ll(argv[3], &uid) != 0) goto usage;
        if (open_db(argv[2], &db) != 0) return 3;
        // Byte-for-byte the statement roamd's sqlite3 call ran (DIA-20260812 MMS remap): repoint another
        // user's telephony part paths at the current user, leaving already-correct rows alone.
        if (exec_fmt(db, "mms-remap",
                     "UPDATE part SET _data='/data/user_de/%lld/'||"
                     "substr(_data,instr(_data,'com.android.providers.telephony/')) "
                     "WHERE _data LIKE '/data/user_de/%%/com.android.providers.telephony/%%' "
                     "AND _data NOT LIKE '/data/user_de/%lld/%%';", uid, uid) != 0) {
            sqlite3_close(db);
            return 6;
        }
        printf("%d\n", sqlite3_changes(db));
        sqlite3_close(db);
        return 0;
    }

    /* media-remap <external.db> <uid> (NWP-20261124-01): the CE and #de seals carry MediaProvider's own database with
     * its absolute `_data` paths, as they carry mmssms.db (mms-remap above). After a sign-in as a new user id every
     * row still names /storage/emulated/<old user>/..., so the app that took a photo calls it inaccessible, and the
     * mount-time scan adds a second row for the real path: every folder shows twice, three times after a third
     * session.
     *
     * Fixed statements on table `files` only, in ONE transaction: any error rolls back and exits 6 with the
     * database unchanged. No `files` table or no `_data` column fails the first INSERT, so it is exit 6 too.
     *
     * a. Group the rows under /storage/emulated/<digits> by the lower-cased remainder after the user segment, and
     *    in each group keep the LOWEST _id. That is the row the creating app inserted, with its owner_package_name
     *    and date_added; the later rows are the mount-time scan's copies of stale paths. Only INDEX ROWS are
     *    deleted: this is a statement on the database, never on a file.
     * b. Repoint every remaining such row whose user segment is not <uid> at /storage/emulated/<uid>. After (a)
     *    each remainder is unique under lower(), the same ASCII fold as the column's COLLATE NOCASE, so (b)
     *    cannot hit the UNIQUE constraint on _data.
     * Rows of any other volume, a non-numeric segment (obb) and rows already under <uid> with no copy are left
     * alone. Prints `<remapped> <dropped>`: counts only, never a path. */
    if (strcmp(op, "media-remap") == 0) {
        long long uid;
        if (argc != 4 || parse_ll(argv[3], &uid) != 0 || uid < 0) goto usage;
        if (open_db(argv[2], &db) != 0) return 3;
        static const char *const media_fns[] = {"_INSERT", "_UPDATE", "_DELETE"};
        for (int f = 0; f < 3; f++)
            if (sqlite3_create_function(db, media_fns[f], -1, SQLITE_UTF8 | SQLITE_INNOCUOUS, NULL, media_noop_fn,
                                        NULL, NULL) != SQLITE_OK) {
                fprintf(stderr, "nowhere_db_fix: media-remap: %s\n", sqlite3_errmsg(db));
                sqlite3_close(db);
                return 6;
            }
        int dropped = 0, remapped = 0;
        if (exec_fmt(db, "media-remap", "BEGIN IMMEDIATE;") != 0) goto media_fail;
        if (exec_fmt(db, "media-remap", "CREATE TEMP TABLE nw_media(id INTEGER PRIMARY KEY, usr TEXT, rest TEXT);") != 0 ||
            exec_fmt(db, "media-remap",
                     "INSERT INTO nw_media SELECT _id, u, substr(s, length(u) + 1) FROM "
                     "(SELECT _id, s, CASE WHEN instr(s, '/') > 0 THEN substr(s, 1, instr(s, '/') - 1) ELSE s END AS u "
                     "FROM (SELECT _id, substr(_data, 19) AS s FROM files "
                     "WHERE substr(_data, 1, 18) = '/storage/emulated/' COLLATE BINARY)) "
                     "WHERE u <> '' AND u NOT GLOB '*[^0-9]*';") != 0)
            goto media_fail;
        if (exec_fmt(db, "media-remap",
                     "DELETE FROM files WHERE _id IN (SELECT id FROM nw_media) "
                     "AND _id NOT IN (SELECT MIN(id) FROM nw_media GROUP BY lower(rest));") != 0)
            goto media_fail;
        dropped = sqlite3_changes(db);
        if (exec_fmt(db, "media-remap",
                     "UPDATE files SET _data = '/storage/emulated/%lld' || "
                     "(SELECT rest FROM nw_media WHERE id = files._id) "
                     "WHERE _id IN (SELECT id FROM nw_media WHERE usr <> '%lld');", uid, uid) != 0)
            goto media_fail;
        remapped = sqlite3_changes(db);
        if (exec_fmt(db, "media-remap", "DROP TABLE temp.nw_media;") != 0 ||
            exec_fmt(db, "media-remap", "COMMIT;") != 0)
            goto media_fail;
        printf("%d %d\n", remapped, dropped);
        sqlite3_close(db);
        return 0;
    media_fail:
        sqlite3_exec(db, "ROLLBACK;", NULL, NULL, NULL);
        sqlite3_close(db);
        return 6;
    }

    if (strcmp(op, "telscrub") == 0) {
        if (argc < 4) goto usage;
        for (int i = 3; i < argc; i++)
            if (!ident_ok(argv[i])) {
                fprintf(stderr, "nowhere_db_fix: bad table name %s\n", argv[i]);
                return 2;
            }
        if (open_db(argv[2], &db) != 0) return 3;
        // Per-table, failures skipped: a legacy schema without attachments/drm must not abort the batch
        // before VACUUM -- same rule the gate's old per-invocation CLI loop enforced. The FTS `words`
        // virtual table is deletable and purges its own shadow tables; VACUUM then collapses the pages.
        int cleared = 0;
        for (int i = 3; i < argc; i++)
            if (exec_fmt(db, argv[i], "DELETE FROM \"%s\";", argv[i]) == 0) cleared++;
        if (exec_fmt(db, "VACUUM", "VACUUM;") != 0) {
            sqlite3_close(db);
            return 6; // the scrub is the DELETEs, but an unvacuumed db still holds the bytes -- say so
        }
        // In WAL mode VACUUM's rewrite lands in the -wal file and the db file keeps the old pages (the deleted
        // bytes) until a checkpoint copies the new ones over them. Nothing else guarantees that: the provider
        // holds its own connection, so ours is not the last one and its close checkpoints nothing. TRUNCATE
        // also empties the -wal. In rollback-journal mode this is a no-op that reports success. A busy
        // checkpoint (a live reader pinning the log) means the old bytes may still be there -- say so.
        int wal_log = 0, wal_done = 0;
        if (sqlite3_wal_checkpoint_v2(db, NULL, SQLITE_CHECKPOINT_TRUNCATE, &wal_log, &wal_done) != SQLITE_OK) {
            fprintf(stderr, "nowhere_db_fix: wal_checkpoint(TRUNCATE): %s\n", sqlite3_errmsg(db));
            sqlite3_close(db);
            return 6;
        }
        printf("%d\n", cleared);
        sqlite3_close(db);
        return 0;
    }

usage:
    fprintf(stderr,
            "usage: nowhere_db_fix launcher-relabel <launcher.db> <serial>\n"
            "       nowhere_db_fix launcher-widgets <launcher.db>\n"
            "       nowhere_db_fix mms-remap <mmssms.db> <uid>\n"
            "       nowhere_db_fix media-remap <external.db> <uid>\n"
            "       nowhere_db_fix telscrub <db> <table>...\n"
            "       nowhere_db_fix accounts-count <accounts_ce.db>\n"
            "       nowhere_db_fix accounts-google <accounts_ce.db>\n");
    return 2;
}
