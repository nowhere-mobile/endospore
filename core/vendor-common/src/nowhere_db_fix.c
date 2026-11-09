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
//       at /storage/emulated/<uid> with bucket_id moved to the new path, gives every row _user_id <uid> and, when the
//       db has local_metadata, gives every changed row a new generation. Index rows only, never a file. One
//       transaction. Prints `<remapped> <dropped> <reowned> <generation>`, the last `-` when it took no generation.
//       The column readings are AOSP's, to be confirmed on a handset.
//       (roamd, after the CE and #de restores; NWP-20261124-01, NWP-20261129-01.)
//   nowhere_db_fix media-insert <external.db> <uid> <list>
//       In MediaProvider's `files` table: one row for each media file in <list> that has no row yet, every column
//       computed here. The list's values are data, bound through prepared statements, never SQL. One transaction.
//       Prints `<inserted> <present> <skipped> <generation>`, the last `-` when it took no generation.
//       The column readings are AOSP's, to be confirmed on a handset. (roamd, after the #media restore; NWP-20261130-02.)
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
//      any statement failed, rolled back, the db unchanged; media-insert: the same, or a list it cannot read or
//      parse), or while reading (accounts-count / accounts-google:
//      the table cannot be read)

#include <ctype.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>
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
    int n = vsnprintf(sql, sizeof(sql), fmt, ap);
    va_end(ap);
    // A cut statement never runs (NWP-20261129-01). The cast also catches a negative return.
    if ((size_t)n >= sizeof(sql)) {
        fprintf(stderr, "nowhere_db_fix: %s: statement too long\n", what);
        return -1;
    }
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

// nw_rebucket(old_bucket, old_user, new_uid, rest), media-remap's bucket_id for a repointed row (NWP-20261129-01).
// bucket_id is Java's String.hashCode() of the lower-cased parent of `_data` (AOSP FileUtils.computeDataValues, read
// from the source, to be confirmed on a handset). The repoint changes only the parent's prefix P =
// /storage/emulated/<n>, and the hash is a polynomial: H(P+R) = H(P)*31^|R| + H(R) mod 2^32. So
// new = old + (H(P_new) - H(P_old)) * 31^|R| mod 2^32: H(R) cancels, and nothing is lower-cased here.
// R is `rest` up to its last '/' ('' for a file directly under the user root). |R| is R's length in UTF-16 code units
// AFTER Java lower-cases it: a 4-byte UTF-8 sequence is a surrogate pair (2 units), and U+0130 becomes two units.
// P is ASCII. A NULL old_bucket stays NULL. `rest` '' is the user root itself: its parent is above P, so its bucket
// does not move.
static void media_rebucket_fn(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
    (void)argc;
    if (sqlite3_value_type(argv[0]) == SQLITE_NULL) {
        sqlite3_result_null(ctx);
        return;
    }
    const char *old_user = (const char *)sqlite3_value_text(argv[1]);
    const unsigned char *rest = sqlite3_value_text(argv[3]);
    if (!old_user || !rest) {
        sqlite3_result_error_nomem(ctx); // fails the statement: exit 6, rolled back
        return;
    }
    if (*rest == '\0') {
        sqlite3_result_value(ctx, argv[0]);
        return;
    }
    const unsigned char *slash = (const unsigned char *)strrchr((const char *)rest, '/');
    uint32_t scale = 1;
    for (const unsigned char *p = rest; slash && p < slash; p++) {
        if ((*p & 0xC0) == 0x80) continue; // a UTF-8 continuation byte
        scale *= 31u;
        if (*p >= 0xF0) scale *= 31u;
        if (*p == 0xC4 && p[1] == 0xB0) scale *= 31u;
    }
    char new_user[24];
    snprintf(new_user, sizeof(new_user), "%lld", (long long)sqlite3_value_int64(argv[2]));
    uint32_t h_old = 0, h_new = 0;
    for (const char *s = "/storage/emulated/"; *s; s++) {
        h_old = h_old * 31u + (unsigned char)*s;
        h_new = h_new * 31u + (unsigned char)*s;
    }
    for (const char *s = old_user; *s; s++) h_old = h_old * 31u + (unsigned char)*s;
    for (const char *s = new_user; *s; s++) h_new = h_new * 31u + (unsigned char)*s;
    sqlite3_result_int(ctx, (int32_t)((uint32_t)sqlite3_value_int64(argv[0]) + (h_new - h_old) * scale));
}

// The trigger functions' no-ops, for a connection that writes `files` (media-remap, media-insert). 0 on success.
static int media_register_noops(sqlite3 *db, const char *what) {
    static const char *const media_fns[] = {"_INSERT", "_UPDATE", "_DELETE"};
    for (int f = 0; f < 3; f++)
        if (sqlite3_create_function(db, media_fns[f], -1, SQLITE_UTF8 | SQLITE_INNOCUOUS, NULL, media_noop_fn,
                                    NULL, NULL) != SQLITE_OK) {
            fprintf(stderr, "nowhere_db_fix: %s: %s\n", what, sqlite3_errmsg(db));
            return -1;
        }
    return 0;
}

// media-insert's type table (NWP-20261130-02): media_type 1 image, 2 audio, 3 video, 0 for anything else, which is
// skipped. Case-insensitive on the extension. The MIME strings are AOSP's mapping as read, to be confirmed on a handset.
static int media_type_of(const char *base, const char **mime) {
    static const struct {
        const char *ext, *mime;
        int type;
    } types[] = {
        {"jpg", "image/jpeg", 1},        {"jpeg", "image/jpeg", 1},      {"png", "image/png", 1},
        {"gif", "image/gif", 1},         {"webp", "image/webp", 1},      {"heic", "image/heic", 1},
        {"heif", "image/heif", 1},       {"bmp", "image/x-ms-bmp", 1},   {"dng", "image/x-adobe-dng", 1},
        {"avif", "image/avif", 1},       {"mp3", "audio/mpeg", 2},       {"m4a", "audio/mp4", 2},
        {"flac", "audio/flac", 2},       {"ogg", "audio/ogg", 2},        {"opus", "audio/ogg", 2},
        {"wav", "audio/x-wav", 2},       {"aac", "audio/aac", 2},        {"mp4", "video/mp4", 3},
        {"m4v", "video/x-m4v", 3},       {"mkv", "video/x-matroska", 3}, {"webm", "video/webm", 3},
        {"3gp", "video/3gpp", 3},        {"mov", "video/quicktime", 3},  {"avi", "video/avi", 3},
    };
    *mime = NULL;
    const char *dot = strrchr(base, '.');
    if (!dot) return 0;
    for (size_t i = 0; i < sizeof(types) / sizeof(types[0]); i++)
        if (strcasecmp(dot + 1, types[i].ext) == 0) {
            *mime = types[i].mime;
            return types[i].type;
        }
    return 0;
}

// Extends Java's String.hashCode() *h over the UTF-8 string s, by UTF-16 code unit: a 4-byte sequence is a surrogate
// pair. Malformed UTF-8 returns -1.
static int java_hash_utf8(const unsigned char *s, uint32_t *h) {
    uint32_t v = *h;
    while (*s) {
        uint32_t cp;
        int more;
        if (*s < 0x80) { cp = *s; more = 0; }
        else if (*s >= 0xC2 && *s < 0xE0) { cp = *s & 0x1Fu; more = 1; }
        else if (*s >= 0xE0 && *s < 0xF0) { cp = *s & 0x0Fu; more = 2; }
        else if (*s >= 0xF0 && *s < 0xF5) { cp = *s & 0x07u; more = 3; }
        else return -1;
        s++;
        for (int i = 0; i < more; i++, s++) {
            if ((*s & 0xC0) != 0x80) return -1;
            cp = (cp << 6) | (*s & 0x3Fu);
        }
        if (more == 2 && (cp < 0x800 || (cp >= 0xD800 && cp < 0xE000))) return -1;
        if (more == 3 && (cp < 0x10000 || cp > 0x10FFFF)) return -1;
        if (cp >= 0x10000) {
            cp -= 0x10000;
            v = v * 31u + (0xD800u + (cp >> 10));
            v = v * 31u + (0xDC00u + (cp & 0x3FFu));
        } else {
            v = v * 31u + cp;
        }
    }
    *h = v;
    return 0;
}

// The next NUL-terminated field of media-insert's list into *buf. Returns 1 for a field, 0 at a clean end of the file,
// -1 for a read error or a last field with no terminator.
static int mins_field(FILE *f, char **buf, size_t *cap) {
    ssize_t n = getdelim(buf, cap, '\0', f);
    if (n < 0) return ferror(f) ? -1 : 0;
    return (*buf)[n - 1] == '\0' ? 1 : -1;
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
     * database unchanged. No `files` table or no `_data` column fails the first INSERT, so it is exit 6 too. The same
     * for a `files` without `_user_id` or `bucket_id` or, when `local_metadata` exists, `generation_modified`, and for
     * a `local_metadata` that holds no generation: fail closed.
     *
     * NWP-20261129-01: a repoint of `_data` alone left three columns of a removed user. Read from AOSP's MediaProvider,
     * to be confirmed on a handset: `_user_id` is set only on insert, and idle maintenance (job -200) deletes every row
     * whose `_user_id` is not the running user, so the whole roamed index went and the emptied index was sealed;
     * `bucket_id` hashes the parent path, so an old value beside a new photo splits an album in two;
     * `generation_modified` kept the old session's value.
     *
     * a. Group the rows under /storage/emulated/<digits> by the lower-cased remainder after the user segment, and
     *    in each group keep the LOWEST _id. That is the row the creating app inserted, with its owner_package_name
     *    and date_added; the later rows are the mount-time scan's copies of stale paths. Only INDEX ROWS are
     *    deleted: this is a statement on the database, never on a file.
     * b. Repoint every remaining such row whose user segment is not <uid> at /storage/emulated/<uid>. After (a)
     *    each remainder is unique under lower(), the same ASCII fold as the column's COLLATE NOCASE, so (b)
     *    cannot hit the UNIQUE constraint on _data. bucket_id moves with the path (nw_rebucket).
     * c. Give every row _user_id <uid>, every volume too: in a session only that user's rows survive maintenance.
     * d. Only when (b) or (c) changed a row AND the database has `local_metadata`: take one new generation and put it
     *    in generation_modified of those rows (temp.nw_chg, read before (b) and (c) destroy what it reads).
     * The paths of any other volume, a non-numeric segment (obb) and rows already under <uid> with no copy are left
     * alone. Prints `<remapped> <dropped> <reowned> <generation>`, the last `-` when (d) did not run: counts and the
     * generation only, never a path. */
    if (strcmp(op, "media-remap") == 0) {
        long long uid;
        if (argc != 4 || parse_ll(argv[3], &uid) != 0 || uid < 0) goto usage;
        if (open_db(argv[2], &db) != 0) return 3;
        if (media_register_noops(db, "media-remap") != 0) {
            sqlite3_close(db);
            return 6;
        }
        if (sqlite3_create_function(db, "nw_rebucket", 4, SQLITE_UTF8 | SQLITE_DETERMINISTIC | SQLITE_INNOCUOUS, NULL,
                                    media_rebucket_fn, NULL, NULL) != SQLITE_OK) {
            fprintf(stderr, "nowhere_db_fix: media-remap: %s\n", sqlite3_errmsg(db));
            sqlite3_close(db);
            return 6;
        }
        int dropped = 0, remapped = 0, reowned = 0, bump = 0;
        long long generation = -1;
        sqlite3_stmt *st = NULL;
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
        if (exec_fmt(db, "media-remap", "CREATE TEMP TABLE nw_chg(id INTEGER PRIMARY KEY);") != 0 ||
            exec_fmt(db, "media-remap",
                     "INSERT INTO temp.nw_chg SELECT id FROM nw_media WHERE usr <> '%lld' AND id IN (SELECT _id FROM files) "
                     "UNION SELECT _id FROM files WHERE _user_id IS NOT %lld;", uid, uid) != 0)
            goto media_fail;
        if (exec_fmt(db, "media-remap",
                     "UPDATE files SET _data = '/storage/emulated/%lld' || "
                     "(SELECT rest FROM nw_media WHERE id = files._id), "
                     "bucket_id = (SELECT nw_rebucket(files.bucket_id, usr, %lld, rest) FROM nw_media WHERE id = files._id) "
                     "WHERE _id IN (SELECT id FROM nw_media WHERE usr <> '%lld');", uid, uid, uid) != 0)
            goto media_fail;
        remapped = sqlite3_changes(db);
        if (exec_fmt(db, "media-remap",
                     "UPDATE files SET _user_id = %lld WHERE _user_id IS NOT %lld;", uid, uid) != 0)
            goto media_fail;
        reowned = sqlite3_changes(db);
        if (sqlite3_prepare_v2(db,
                               "SELECT EXISTS(SELECT 1 FROM temp.nw_chg) AND EXISTS(SELECT 1 FROM sqlite_master "
                               "WHERE type = 'table' AND name = 'local_metadata');",
                               -1, &st, NULL) != SQLITE_OK ||
            sqlite3_step(st) != SQLITE_ROW) {
            fprintf(stderr, "nowhere_db_fix: media-remap: %s\n", sqlite3_errmsg(db));
            sqlite3_finalize(st);
            goto media_fail;
        }
        bump = sqlite3_column_int(st, 0);
        sqlite3_finalize(st);
        if (bump) {
            if (exec_fmt(db, "media-remap", "UPDATE local_metadata SET generation = generation + 1;") != 0 ||
                exec_fmt(db, "media-remap",
                         "UPDATE files SET generation_modified = (SELECT MAX(generation) FROM local_metadata) "
                         "WHERE _id IN (SELECT id FROM temp.nw_chg);") != 0)
                goto media_fail;
            if (sqlite3_prepare_v2(db, "SELECT MAX(generation) FROM local_metadata;", -1, &st, NULL) != SQLITE_OK ||
                sqlite3_step(st) != SQLITE_ROW) {
                fprintf(stderr, "nowhere_db_fix: media-remap: %s\n", sqlite3_errmsg(db));
                sqlite3_finalize(st);
                goto media_fail;
            }
            // AOSP always inserts the one row, so none is a damaged database: never write a NULL generation.
            if (sqlite3_column_type(st, 0) == SQLITE_NULL) {
                fprintf(stderr, "nowhere_db_fix: media-remap: local_metadata holds no generation\n");
                sqlite3_finalize(st);
                goto media_fail;
            }
            generation = sqlite3_column_int64(st, 0);
            sqlite3_finalize(st);
        }
        if (exec_fmt(db, "media-remap", "DROP TABLE temp.nw_chg;") != 0 ||
            exec_fmt(db, "media-remap", "DROP TABLE temp.nw_media;") != 0 ||
            exec_fmt(db, "media-remap", "COMMIT;") != 0)
            goto media_fail;
        if (bump)
            printf("%d %d %d %lld\n", remapped, dropped, reowned, generation);
        else
            printf("%d %d %d -\n", remapped, dropped, reowned);
        sqlite3_close(db);
        return 0;
    media_fail:
        sqlite3_exec(db, "ROLLBACK;", NULL, NULL, NULL);
        sqlite3_close(db);
        return 6;
    }

    /* media-insert <external.db> <uid> <list> (NWP-20261130-02; docs/product-decisions.md, 2026-11-06): on the default
     * tier MediaStore never learns that a file not yet downloaded exists, so the Gallery is empty. After the #media
     * restore roamd hands this op the list the agent wrote (core/agent/media_rows.go), and it writes the rows MediaProvider
     * would have written. No change notification goes out, so an open Gallery shows them after a refresh.
     *
     * A record is four NUL-terminated fields: <size>, <mtime seconds>, <Java-lower-cased parent of rel>, <rel>. The fold
     * comes from the agent because this tool has no Unicode table; every column is computed here. Values are bound,
     * never SQL.
     *
     * What keeps a row through idle maintenance (job -200), read from AOSP's MediaProvider, to be confirmed on a handset:
     * the session's _user_id, the current bucket_id and a current generation. bucket_id is the Java hash of
     * /storage/emulated/<uid>/<lower parent>, as nw_rebucket reads it. A file at the storage root has an empty parent
     * field: its bucket_id hashes /storage/emulated/<uid> with no trailing slash, its relative_path is "/" and its
     * bucket_display_name is NULL (AOSP's computeDataValues, to be confirmed on a handset).
     *
     * One transaction: any error rolls back and exits 6 with the database unchanged, and that includes a malformed record
     * or a list it cannot read. Both statements are prepared before the first record, so a `files` without a needed
     * column exits 6 even with nothing to insert. A file that already has a row (the column's COLLATE NOCASE applies) is
     * only counted, so a second run inserts nothing, and a row whose file is downloaded later keeps its `_data`. A rel
     * whose parent field disagrees with it, in malformed UTF-8 or of another type is skipped and counted. The generation
     * is taken at the first insert, once, when the database has `local_metadata`. Prints `<inserted> <present> <skipped> <generation>`, the
     * last `-` when it took none: counts and the generation only, never a path. */
    if (strcmp(op, "media-insert") == 0) {
        long long uid;
        if (argc != 5 || parse_ll(argv[3], &uid) != 0 || uid < 0) goto usage;
        if (open_db(argv[2], &db) != 0) return 3;
        if (media_register_noops(db, "media-insert") != 0) {
            sqlite3_close(db);
            return 6;
        }
        int inserted = 0, present = 0, skipped = 0, has_meta = 0, bumped = 0;
        long long generation = -1;
        long long now = (long long)time(NULL);
        FILE *list = NULL;
        sqlite3_stmt *sel = NULL, *ins = NULL, *st = NULL;
        char *fsize = NULL, *fmtime = NULL, *flower = NULL, *frel = NULL, *data = NULL;
        size_t csize = 0, cmtime = 0, clower = 0, crel = 0;
        if (exec_fmt(db, "media-insert", "BEGIN IMMEDIATE;") != 0) goto mins_fail;
        if (sqlite3_prepare_v2(db,
                               "SELECT EXISTS(SELECT 1 FROM sqlite_master "
                               "WHERE type = 'table' AND name = 'local_metadata');",
                               -1, &st, NULL) != SQLITE_OK ||
            sqlite3_step(st) != SQLITE_ROW)
            goto mins_err;
        has_meta = sqlite3_column_int(st, 0);
        sqlite3_finalize(st);
        st = NULL;
        if (sqlite3_prepare_v2(db, "SELECT 1 FROM files WHERE _data = ?;", -1, &sel, NULL) != SQLITE_OK ||
            sqlite3_prepare_v2(db,
                               has_meta
                                   ? "INSERT INTO files(_data, _user_id, bucket_id, bucket_display_name, relative_path, "
                                     "_display_name, media_type, mime_type, _size, date_modified, date_added, datetaken, "
                                     "volume_name, is_pending, generation_added, generation_modified) "
                                     "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,'external_primary',0,?,?);"
                                   : "INSERT INTO files(_data, _user_id, bucket_id, bucket_display_name, relative_path, "
                                     "_display_name, media_type, mime_type, _size, date_modified, date_added, datetaken, "
                                     "volume_name, is_pending) "
                                     "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,'external_primary',0);",
                               -1, &ins, NULL) != SQLITE_OK)
            goto mins_err;
        list = fopen(argv[4], "r");
        if (!list) {
            fprintf(stderr, "nowhere_db_fix: media-insert: cannot read the list\n");
            goto mins_fail;
        }
        for (;;) {
            long long size, mtime;
            const char *mime;
            int fr = mins_field(list, &fsize, &csize);
            if (fr == 0) break;
            if (fr < 0 || mins_field(list, &fmtime, &cmtime) != 1 || mins_field(list, &flower, &clower) != 1 ||
                mins_field(list, &frel, &crel) != 1 || parse_ll(fsize, &size) != 0 || size < 0 ||
                parse_ll(fmtime, &mtime) != 0 || mtime < 0 || mtime > INT64_MAX / 1000) {
                fprintf(stderr, "nowhere_db_fix: media-insert: malformed list\n");
                goto mins_fail;
            }
            char *slash = strrchr(frel, '/');
            uint32_t unused = 0; // java_hash_utf8 here is only the UTF-8 check
            if (slash == frel || !slash != !*flower || java_hash_utf8((const unsigned char *)frel, &unused) != 0) {
                skipped++;
                continue;
            }
            const char *base = slash ? slash + 1 : frel;
            int mt = media_type_of(base, &mime);
            if (mt == 0) {
                skipped++;
                continue;
            }
            char user_root[48];
            snprintf(user_root, sizeof(user_root), "/storage/emulated/%lld", uid);
            uint32_t bucket = 0;
            if (java_hash_utf8((const unsigned char *)user_root, &bucket) != 0 ||
                (slash && (java_hash_utf8((const unsigned char *)"/", &bucket) != 0 ||
                           java_hash_utf8((const unsigned char *)flower, &bucket) != 0))) {
                skipped++;
                continue;
            }
            sqlite3_free(data);
            data = sqlite3_mprintf("%s/%s", user_root, frel);
            if (!data) goto mins_fail;
            sqlite3_reset(sel);
            sqlite3_bind_text(sel, 1, data, -1, SQLITE_STATIC);
            int sr = sqlite3_step(sel);
            if (sr != SQLITE_ROW && sr != SQLITE_DONE) goto mins_err;
            if (sr == SQLITE_ROW) {
                present++;
                continue;
            }
            if (has_meta && !bumped) {
                if (exec_fmt(db, "media-insert", "UPDATE local_metadata SET generation = generation + 1;") != 0)
                    goto mins_fail;
                if (sqlite3_prepare_v2(db, "SELECT MAX(generation) FROM local_metadata;", -1, &st, NULL) != SQLITE_OK ||
                    sqlite3_step(st) != SQLITE_ROW)
                    goto mins_err;
                // As in media-remap: an empty local_metadata is a damaged database, never a NULL generation.
                if (sqlite3_column_type(st, 0) == SQLITE_NULL) {
                    fprintf(stderr, "nowhere_db_fix: media-insert: local_metadata holds no generation\n");
                    goto mins_fail;
                }
                generation = sqlite3_column_int64(st, 0);
                sqlite3_finalize(st);
                st = NULL;
                bumped = 1;
            }
            const char *leaf = NULL; // stays NULL for a file at the storage root
            if (slash) {
                *slash = '\0'; // frel is now the parent
                leaf = strrchr(frel, '/');
                leaf = leaf ? leaf + 1 : frel;
            }
            char *relpath = slash ? sqlite3_mprintf("%s/", frel) : sqlite3_mprintf("/");
            if (!relpath) goto mins_fail;
            sqlite3_reset(ins);
            sqlite3_bind_text(ins, 1, data, -1, SQLITE_STATIC);
            sqlite3_bind_int64(ins, 2, uid);
            sqlite3_bind_int(ins, 3, (int32_t)bucket);
            if (leaf)
                sqlite3_bind_text(ins, 4, leaf, -1, SQLITE_STATIC);
            else
                sqlite3_bind_null(ins, 4);
            sqlite3_bind_text(ins, 5, relpath, -1, sqlite3_free);
            sqlite3_bind_text(ins, 6, base, -1, SQLITE_STATIC);
            sqlite3_bind_int(ins, 7, mt);
            sqlite3_bind_text(ins, 8, mime, -1, SQLITE_STATIC);
            sqlite3_bind_int64(ins, 9, size);
            sqlite3_bind_int64(ins, 10, mtime);
            sqlite3_bind_int64(ins, 11, mtime ? mtime : now);
            if (mtime)
                sqlite3_bind_int64(ins, 12, mtime * 1000);
            else
                sqlite3_bind_null(ins, 12);
            if (has_meta) {
                sqlite3_bind_int64(ins, 13, generation);
                sqlite3_bind_int64(ins, 14, generation);
            }
            if (sqlite3_step(ins) != SQLITE_DONE) goto mins_err;
            inserted++;
        }
        sqlite3_finalize(sel);
        sel = NULL;
        sqlite3_finalize(ins);
        ins = NULL;
        if (exec_fmt(db, "media-insert", "COMMIT;") != 0) goto mins_fail;
        if (bumped)
            printf("%d %d %d %lld\n", inserted, present, skipped, generation);
        else
            printf("%d %d %d -\n", inserted, present, skipped);
        fclose(list);
        free(fsize);
        free(fmtime);
        free(flower);
        free(frel);
        sqlite3_free(data);
        sqlite3_close(db);
        return 0;
    mins_err:
        fprintf(stderr, "nowhere_db_fix: media-insert: %s\n", sqlite3_errmsg(db));
    mins_fail:
        sqlite3_finalize(st);
        sqlite3_finalize(sel);
        sqlite3_finalize(ins);
        sqlite3_exec(db, "ROLLBACK;", NULL, NULL, NULL);
        if (list) fclose(list);
        free(fsize);
        free(fmtime);
        free(flower);
        free(frel);
        sqlite3_free(data);
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
            "       nowhere_db_fix media-insert <external.db> <uid> <list>\n"
            "       nowhere_db_fix telscrub <db> <table>...\n"
            "       nowhere_db_fix accounts-count <accounts_ce.db>\n"
            "       nowhere_db_fix accounts-google <accounts_ce.db>\n");
    return 2;
}
