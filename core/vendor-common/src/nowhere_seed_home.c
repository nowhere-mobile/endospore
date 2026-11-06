// nowhere_seed_home -- seed a FRESH roamed profile's launcher page 2.
//
// WHY THIS EXISTS AT ALL. Launcher3's default-layout importer takes only the DOCK (hotseat) from
// default_workspace and silently drops multi-screen DESKTOP items, so the second page has to be written
// into launcher.db after the launcher has created it. roamd used to do that by shelling out to
// /system/bin/sqlite3 -- which is a USERDEBUG-ONLY binary. On a `user` build it is absent, all three
// queries returned empty, and seeding silently never happened: page 2 was missing on every release device
// while working perfectly on lynx, the one device we build userdebug. (Found 2026-08-10.)
//
// WHY A PURPOSE-BUILT TOOL RATHER THAN SHIPPING THE SQLITE SHELL. A general SQL shell in a hardened
// release image is a capability we do not want present, whatever the file mode says. This binary does one
// job, takes no SQL from its caller, and is SELinux-labelled so only endospore_priv may exec it.
//
// Usage:  nowhere_seed_home <launcher.db> <default-home>
//
// Exit codes are DISTINCT so roamd can log a truthful reason -- the old shell path reported a missing
// sqlite3 as "no serial from launcher.db", which blamed the launcher for a build-configuration problem on
// a device whose logs cannot be read.
//
//   0  seeded (count on stdout), or nothing to do (workspace already populated)
//   2  bad usage
//   3  cannot open launcher.db
//   4  cannot read the default-home descriptor
//   5  no profile serial in launcher.db (the launcher has not imported its dock yet)
//   6  a database error while writing

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sqlite3.h>

#define MAX_LINE 1024

// The launcher's own containers: -100 is the desktop (what we seed), -101 the hotseat (what the launcher
// imported for us, and where we read the profile serial from).
#define CONTAINER_DESKTOP (-100)
#define CONTAINER_HOTSEAT (-101)

static int scalar(sqlite3 *db, const char *sql, long long *out) {
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) != SQLITE_OK) return -1;
    int rc = sqlite3_step(st);
    int found = 0;
    if (rc == SQLITE_ROW) { *out = sqlite3_column_int64(st, 0); found = 1; }
    sqlite3_finalize(st);
    return found ? 0 : -1;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s <launcher.db> <default-home>\n", argv[0]);
        return 2;
    }
    const char *dbpath = argv[1], *descpath = argv[2];

    sqlite3 *db = NULL;
    if (sqlite3_open_v2(dbpath, &db, SQLITE_OPEN_READWRITE, NULL) != SQLITE_OK) {
        fprintf(stderr, "seed-home: cannot open %s: %s\n", dbpath, db ? sqlite3_errmsg(db) : "?");
        if (db) sqlite3_close(db);
        return 3;
    }

    // ONLY seed a genuinely empty workspace. A profile that already has desktop items is either not fresh
    // or has been arranged by its owner, and stamping defaults over that would be worse than doing nothing.
    long long ndesk = 0;
    if (scalar(db, "SELECT COUNT(*) FROM favorites WHERE container=-100;", &ndesk) != 0) {
        fprintf(stderr, "seed-home: cannot count workspace items\n");
        sqlite3_close(db);
        return 6;
    }
    if (ndesk != 0) {
        printf("skip: workspace already has %lld item(s)\n", ndesk);
        sqlite3_close(db);
        return 0;
    }

    // The serial comes from the launcher's OWN hotseat rows: it is exactly the profileId this user's items
    // carry, and reading it here avoids `dumpsys user`, which the enforcing endospore_priv domain cannot
    // pipe-read (system_server -> endospore_priv fifo write is AVC-denied).
    long long serial = 0;
    if (scalar(db, "SELECT profileId FROM favorites WHERE container=-101 LIMIT 1;", &serial) != 0) {
        fprintf(stderr, "seed-home: no profile serial (launcher has not imported its dock yet)\n");
        sqlite3_close(db);
        return 5;
    }

    FILE *f = fopen(descpath, "r");
    if (!f) {
        fprintf(stderr, "seed-home: cannot read %s\n", descpath);
        sqlite3_close(db);
        return 4;
    }

    // One transaction: a half-seeded page is worse than an unseeded one, because the empty-workspace guard
    // above would then refuse to try again.
    if (sqlite3_exec(db, "BEGIN", NULL, NULL, NULL) != SQLITE_OK) {
        fclose(f); sqlite3_close(db);
        return 6;
    }

    const char *ins =
        "INSERT INTO favorites (title,intent,container,screen,cellX,cellY,spanX,spanY,itemType,profileId,restored)"
        " VALUES ('',?,?,?,?,?,1,1,0,?,0);";
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db, ins, -1, &st, NULL) != SQLITE_OK) {
        sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL);
        fclose(f); sqlite3_close(db);
        return 6;
    }

    char line[MAX_LINE];
    int rows = 0, bad = 0;
    while (fgets(line, sizeof line, f)) {
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '\0' || *p == '\n' || *p == '\r' || *p == '#') continue;   // blank / comment

        // screen|cellX|cellY|pkg|cls -- tokenized one past that, so a sixth field is SEEN and the line refused
        // rather than cut off silently.
        char *fields[6]; int n = 0;
        for (char *tok = p; n < 6; ) {
            fields[n++] = tok;
            char *bar = strchr(tok, '|');
            if (!bar) break;
            *bar = '\0';
            tok = bar + 1;
        }
        if (n != 5) { bad++; continue; }
        for (char *e = fields[4] + strlen(fields[4]); e > fields[4] && (e[-1] == '\n' || e[-1] == '\r'); ) *--e = '\0';
        if (!*fields[3] || !*fields[4]) { bad++; continue; }

        // strtol("") consumes nothing and leaves `end` on the NUL, so an EMPTY numeric field must be refused
        // before the parse or "||1|pkg|cls" would land on screen 0.
        if (!*fields[0] || !*fields[1] || !*fields[2]) { bad++; continue; }
        char *end = NULL;
        long screen = strtol(fields[0], &end, 10); if (!end || *end) { bad++; continue; }
        long cx     = strtol(fields[1], &end, 10); if (!end || *end) { bad++; continue; }
        long cy     = strtol(fields[2], &end, 10); if (!end || *end) { bad++; continue; }
        if (screen < 0 || cx < 0 || cy < 0) { bad++; continue; }

        char intent[MAX_LINE * 2];
        snprintf(intent, sizeof intent,
                 "#Intent;action=android.intent.action.MAIN;category=android.intent.category.LAUNCHER;"
                 "launchFlags=0x10200000;component=%s/%s;end", fields[3], fields[4]);

        sqlite3_reset(st);
        sqlite3_bind_text(st, 1, intent, -1, SQLITE_TRANSIENT);
        sqlite3_bind_int(st, 2, CONTAINER_DESKTOP);
        sqlite3_bind_int64(st, 3, screen);
        sqlite3_bind_int64(st, 4, cx);
        sqlite3_bind_int64(st, 5, cy);
        sqlite3_bind_int64(st, 6, serial);
        if (sqlite3_step(st) != SQLITE_DONE) {
            fprintf(stderr, "seed-home: insert failed: %s\n", sqlite3_errmsg(db));
            sqlite3_finalize(st);
            sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL);
            fclose(f); sqlite3_close(db);
            return 6;
        }
        rows++;
    }
    sqlite3_finalize(st);
    fclose(f);

    if (rows == 0) {
        // Nothing usable in the descriptor: roll back rather than commit an empty transaction, and say so.
        sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL);
        fprintf(stderr, "seed-home: descriptor yielded no rows (%d malformed)\n", bad);
        sqlite3_close(db);
        return 0;
    }
    if (sqlite3_exec(db, "COMMIT", NULL, NULL, NULL) != SQLITE_OK) {
        fprintf(stderr, "seed-home: commit failed: %s\n", sqlite3_errmsg(db));
        sqlite3_close(db);
        return 6;
    }
    printf("seeded %d\n", rows);
    if (bad) fprintf(stderr, "seed-home: %d malformed line(s) skipped\n", bad);
    sqlite3_close(db);
    return 0;
}
