#!/usr/bin/env bash
# test-nowhere-db-fix.sh [--mutate] -- compiles core/vendor-common/src/nowhere_db_fix.c on the host and RUNS it
# (NWP-20261015-23).
#
# WHY THIS IS COMMITTED. nowhere_db_fix is the only thing between a `user` build (no sqlite3 binary) and the four
# repairs sqlite3 used to do -- launcher-relabel, launcher-widgets, mms-remap, telscrub -- plus #743's
# accounts-count seal guard, accounts-google arrival record and media-remap (NWP-20261124-01), and it runs as root from roamd and the gate. Every other suite that mentions it
# substitutes a stub or pins the call text; nothing executed it off the device. This one builds the real C file
# with `cc -O2 -Wall -Werror ... -lsqlite3` and pins what the callers rely on: exit codes 0/2/3/6, accounts-count's
# `-1` versus `0`, accounts-google's type filter, `_id` order and `?` for a name that could split a line,
# ident_ok refusing non-identifier table names, telscrub continuing past a missing legacy table,
# and the gate's secure-erase claim measured on FILE BYTES (a sentinel planted in sms.body and the FTS `words`
# table must be absent from the db -- and the -wal -- after the scrub, with a control finding it before), in
# rollback-journal mode AND in WAL mode. media-remap (NWP-20261124-01) runs on a MediaProvider-shaped `files` table
# whose triggers call _INSERT/_UPDATE/_DELETE, in both journal modes: one row per file under the new user, the
# lowest _id kept with its owner, other volumes untouched, exact counts, a second run `0 0`, and a trigger that calls
# an unknown function exits 6 with the db bytes unchanged (the dropped-transaction mutant leaves a half-done db).
#
# No skip arm: a host without a compiler or the SQLite headers FAILS (exit 2). Fixtures are built with python3's
# sqlite3 module. The gate's table lists are extracted from nowhere_gate.sh by anchor, not retyped.
#
#   bash test-nowhere-db-fix.sh            # the invariants
#   bash test-nowhere-db-fix.sh --mutate   # ... plus mutants of the C file that must each be CONVICTED
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/nowhere_db_fix.c"
GATE="$HERE/../bin/nowhere_gate.sh"
[ -f "$SRC" ] || { echo "no nowhere_db_fix.c beside: $HERE" >&2; exit 2; }
[ -f "$GATE" ] || { echo "no bin/nowhere_gate.sh beside: $HERE" >&2; exit 2; }
command -v cc >/dev/null 2>&1 || { echo "FAIL: no C compiler (cc) on this host -- the suite did NOT run" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: no python3 on this host -- the suite did NOT run" >&2; exit 2; }
cc --version | head -1
python3 -c 'import sqlite3; print("python sqlite3 module: SQLite", sqlite3.sqlite_version)' || exit 2

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

build() { # $1=source $2=output
  cc -O2 -Wall -Werror "$1" -o "$2" -lsqlite3 2> "$W/cc.err" || { cat "$W/cc.err" >&2; return 1; }
}
build "$SRC" "$W/real" || { echo "FAIL: nowhere_db_fix.c does not build here (missing sqlite3.h / libsqlite3?) -- the suite did NOT run" >&2; exit 2; }

# The gate's own table lists, by anchor: the scrub_db call for a db, plus its continuation lines, minus the first
# two words (scrub_db and the path).
gate_tables() { # $1=db basename
  awk -v pat="databases/$1\"" '
    index($0, "scrub_db \"") && index($0, pat) { on = 1 }
    on { line = $0; sub(/^[ \t]+/, "", line); cont = (line ~ /\\$/); sub(/[ \t]*\\$/, "", line); acc = acc " " line; if (!cont) { print acc; exit } }' "$GATE" |
    awk '{ for (i = 3; i <= NF; i++) printf "%s ", $i; print "" }'
}
MMS_TABLES="$(gate_tables mmssms.db)"
ANA_TABLES="$(gate_tables telephony_analytics.db)"
for t in sms pdu part addr canonical_addresses threads pending_msgs sr_pending attachments drm words; do
  case " $MMS_TABLES" in *" $t "*) ;; *) echo "FAIL: gate table list for mmssms.db lacks $t (got: $MMS_TABLES)" >&2; exit 2 ;; esac
done
[ -n "$ANA_TABLES" ] || { echo "FAIL: no table list for telephony_analytics.db in the gate" >&2; exit 2; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
eq(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3', got '$2')"; fi; }

SENT="NWSENTINEL-9f3a71c2e84b"
cat > "$W/fixture.py" <<'PY'
import sqlite3, sys
kind, path = sys.argv[1], sys.argv[2]
wal = len(sys.argv) > 3 and sys.argv[3] == "wal"
c = sqlite3.connect(path)
if wal:
    c.execute("PRAGMA journal_mode=WAL")
if kind == "launcher":
    c.execute("CREATE TABLE favorites (_id INTEGER PRIMARY KEY, itemType INTEGER, profileId INTEGER, restored INTEGER DEFAULT 0)")
    for i, (t, p) in enumerate([(0, 7), (4, 7), (4, 3), (0, 3), (1, 9)]):
        c.execute("INSERT INTO favorites(itemType, profileId) VALUES (?,?)", (t, p))
elif kind == "mms":
    sent = sys.argv[4] if len(sys.argv) > 4 else "x"
    c.execute("CREATE TABLE sms (_id INTEGER PRIMARY KEY, address TEXT, body TEXT)")
    c.execute("CREATE TABLE pdu (_id INTEGER PRIMARY KEY, sub TEXT)")
    c.execute("CREATE TABLE part (_id INTEGER PRIMARY KEY, _data TEXT)")
    c.execute("CREATE TABLE addr (_id INTEGER PRIMARY KEY, address TEXT)")
    c.execute("CREATE TABLE canonical_addresses (_id INTEGER PRIMARY KEY, address TEXT)")
    c.execute("CREATE TABLE threads (_id INTEGER PRIMARY KEY, snippet TEXT)")
    c.execute("CREATE TABLE pending_msgs (_id INTEGER PRIMARY KEY, err INTEGER)")
    c.execute("CREATE TABLE sr_pending (_id INTEGER PRIMARY KEY, x INTEGER)")
    c.execute("CREATE VIRTUAL TABLE words USING FTS3(index_text, source_id, table_to_use)")
    for i in range(40):
        c.execute("INSERT INTO sms(address, body) VALUES (?,?)", ("+1555000%04d" % i, "hello %d %s %s" % (i, sent, "pad" * 20)))
        c.execute("INSERT INTO words(index_text, source_id, table_to_use) VALUES (?,?,1)", ("hello %d %s" % (i, sent), i))
    c.execute("INSERT INTO pdu(sub) VALUES ('s')")
    c.execute("INSERT INTO threads(snippet) VALUES (?)", (sent,))
    for p in ("/data/user_de/0/com.android.providers.telephony/app_parts/PART_1",
              "/data/user_de/100/com.android.providers.telephony/app_parts/PART_2",
              "/data/user_de/10/com.android.providers.telephony/app_parts/PART_3",
              "/data/user_de/0/com.example/x"):
        c.execute("INSERT INTO part(_data) VALUES (?)", (p,))
elif kind == "acct1":
    c.execute("CREATE TABLE accounts (_id INTEGER PRIMARY KEY, name TEXT)")
    c.execute("INSERT INTO accounts(name) VALUES ('a')")
elif kind == "acct0":
    c.execute("CREATE TABLE accounts (_id INTEGER PRIMARY KEY, name TEXT)")
elif kind in ("acctg", "acctg0", "acctgodd"):
    c.execute("CREATE TABLE accounts (_id INTEGER PRIMARY KEY, name TEXT, type TEXT)")
    rows = {
        "acctg": [(7, "zeta.planted@gmail.com", "com.google"), (2, "work@example.org", "com.example.exchange"),
                  (4, "alpha.planted@gmail.com", "com.google")],
        "acctg0": [],
        "acctgodd": [(1, "a\nb", "com.google"), (2, "", "com.google"), (3, None, "com.google"),
                     (4, "del\x7fx", "com.google"), (5, "tab\tx", "com.google"),
                     (6, "jos\u00e9@gmail.com", "com.google"), (7, "other\nname", "com.example.exchange")],
    }[kind]
    for r in rows:
        c.execute("INSERT INTO accounts(_id, name, type) VALUES (?,?,?)", r)
elif kind in ("media", "mediabad"):
    # MediaProvider's `files`, cut to the columns media-remap touches. The triggers are created AFTER the rows: this
    # connection has no _INSERT, and CREATE TRIGGER does not resolve function names.
    c.execute("CREATE TABLE files (_id INTEGER PRIMARY KEY AUTOINCREMENT, _data TEXT UNIQUE COLLATE NOCASE, owner_package_name TEXT)")
    for r in [("/storage/emulated/10/DCIM/Camera/IMG_1.jpg", "com.example.camera"),
              ("/storage/emulated/11/DCIM/Camera/IMG_1.jpg", None),
              ("/storage/emulated/12/DCIM/Camera/IMG_1.jpg", None),
              ("/storage/emulated/13/Download/doc.pdf", "com.example.files"),
              ("/storage/emulated/10/Pictures/Mixed.PNG", "com.example.gallery"),
              ("/storage/emulated/11/pictures/mixed.png", None),
              ("/storage/ABCD-1234/DCIM/x.jpg", "com.example.sd"),
              ("/storage/emulated/10", None),
              ("/storage/emulated/obb/x", None)]:
        c.execute("INSERT INTO files(_data, owner_package_name) VALUES (?,?)", r)
    upd = "_NW_UNKNOWN(old._id)" if kind == "mediabad" else "_UPDATE(old._id, new._data)"
    c.execute("CREATE TRIGGER files_insert AFTER INSERT ON files BEGIN SELECT _INSERT(new._id, new._data); END")
    c.execute("CREATE TRIGGER files_update AFTER UPDATE ON files BEGIN SELECT %s; END" % upd)
    c.execute("CREATE TRIGGER files_delete AFTER DELETE ON files BEGIN SELECT _DELETE(old._id, old._data); END")
elif kind == "medianodata":
    c.execute("CREATE TABLE files (_id INTEGER PRIMARY KEY, x TEXT)")
    c.execute("INSERT INTO files(x) VALUES ('/storage/emulated/10/a')")
elif kind == "notable":
    c.execute("CREATE TABLE other (x INTEGER)")
elif kind == "analytics":
    c.execute("CREATE TABLE SmsMmsDataLogs (d TEXT, n INTEGER)")
    c.execute("CREATE TABLE ServiceStateLogs (d TEXT, n INTEGER)")
    c.execute("INSERT INTO SmsMmsDataLogs VALUES ('2026-07-31', 1)")
    c.execute("INSERT INTO ServiceStateLogs VALUES ('2026-07-31', 1)")
c.commit()
c.close()
PY
# Holds a second connection open on a db until told to stop, so the tool's close is NOT the last one.
cat > "$W/holder.py" <<'PY'
import sqlite3, sys, os, time
c = sqlite3.connect(sys.argv[1])
c.execute("SELECT count(*) FROM sqlite_master").fetchall()
open(sys.argv[2], "w").close()
for _ in range(600):
    if os.path.exists(sys.argv[3]):
        break
    time.sleep(0.1)
c.close()
PY
fx() { python3 "$W/fixture.py" "$@"; }
q() { python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute(sys.argv[2]).fetchall())' "$1" "$2"; }

# run_suite <tool>: every assertion, against one built binary. Used for the real tool and, with the verdict
# inverted, for each mutant.
run_suite() {
  local T="$1" d out rc n
  d="$W/run.$$.$RANDOM"; mkdir -p "$d"

  echo "== usage and identifier checks =="
  "$T" >/dev/null 2>&1; eq "no args exits 2" "$?" 2
  "$T" launcher-relabel "$d/none.db" >/dev/null 2>&1; eq "launcher-relabel missing serial exits 2" "$?" 2
  "$T" launcher-relabel "$d/none.db" abc >/dev/null 2>&1; eq "launcher-relabel non-numeric serial exits 2" "$?" 2
  "$T" accounts-count a b >/dev/null 2>&1; eq "accounts-count extra arg exits 2" "$?" 2
  "$T" telscrub "$d/none.db" >/dev/null 2>&1; eq "telscrub with no table exits 2" "$?" 2
  "$T" bogus-op x >/dev/null 2>&1; eq "unknown op exits 2" "$?" 2
  fx mms "$d/id.db" x
  "$T" telscrub "$d/id.db" 'sms; DROP TABLE x' >/dev/null 2>&1; eq "table 'sms; DROP TABLE x' exits 2" "$?" 2
  "$T" telscrub "$d/id.db" 1abc >/dev/null 2>&1; eq "table '1abc' exits 2" "$?" 2
  "$T" telscrub "$d/id.db" sms 'a"b' >/dev/null 2>&1; eq "a bad name after a good one exits 2" "$?" 2
  eq "refused names left the db untouched" "$(q "$d/id.db" 'SELECT count(*) FROM sms')" "[(40,)]"
  "$T" telscrub "$d/missing.db" sms >/dev/null 2>&1; eq "telscrub on a missing file exits 3" "$?" 3
  [ ! -e "$d/missing.db" ] && ok "telscrub did not create the missing file" || no "telscrub created the missing file"

  echo "== launcher =="
  fx launcher "$d/l.db"
  out="$("$T" launcher-relabel "$d/l.db" 42)"; rc=$?
  eq "launcher-relabel exits 0" "$rc" 0
  eq "launcher-relabel prints the row count" "$out" 5
  eq "launcher-relabel set every profileId" "$(q "$d/l.db" 'SELECT DISTINCT profileId FROM favorites')" "[(42,)]"
  out="$("$T" launcher-widgets "$d/l.db")"; rc=$?
  eq "launcher-widgets exits 0" "$rc" 0
  eq "launcher-widgets prints only the widget rows" "$out" 2
  eq "launcher-widgets restored=15 on itemType 4 only" "$(q "$d/l.db" 'SELECT itemType, restored FROM favorites ORDER BY _id')" "[(0, 0), (4, 15), (4, 15), (0, 0), (1, 0)]"
  "$T" launcher-relabel "$d/none.db" 1 >/dev/null 2>&1; eq "launcher-relabel on a missing file exits 3" "$?" 3
  [ ! -e "$d/none.db" ] && ok "launcher-relabel did not create the missing file" || no "launcher-relabel created the missing file"
  fx notable "$d/nl.db"
  "$T" launcher-relabel "$d/nl.db" 1 >/dev/null 2>&1; eq "launcher-relabel without a favorites table exits 6" "$?" 6

  echo "== mms-remap =="
  fx mms "$d/m.db" x
  out="$("$T" mms-remap "$d/m.db" 10)"; rc=$?
  eq "mms-remap exits 0" "$rc" 0
  eq "mms-remap prints the changed-row count" "$out" 2
  eq "mms-remap repoints user 0 and user 100 paths, leaves 10/ and non-telephony alone" \
     "$(q "$d/m.db" 'SELECT _data FROM part ORDER BY _id')" \
     "[('/data/user_de/10/com.android.providers.telephony/app_parts/PART_1',), ('/data/user_de/10/com.android.providers.telephony/app_parts/PART_2',), ('/data/user_de/10/com.android.providers.telephony/app_parts/PART_3',), ('/data/user_de/0/com.example/x',)]"
  out="$("$T" mms-remap "$d/m.db" 10)"; eq "mms-remap is idempotent (second run changes 0)" "$out" 0
  "$T" mms-remap "$d/m.db" ten >/dev/null 2>&1; eq "mms-remap non-numeric uid exits 2" "$?" 2

  echo "== media-remap: rollback-journal mode =="
  media_case "$T" "$d" delete
  echo "== media-remap: WAL mode =="
  media_case "$T" "$d" wal
  echo "== media-remap: arguments and schema =="
  fx media "$d/mu.db"
  "$T" media-remap "$d/mu.db" x >/dev/null 2>&1; eq "media-remap uid 'x' exits 2" "$?" 2
  "$T" media-remap "$d/mu.db" -1 >/dev/null 2>&1; eq "media-remap uid '-1' exits 2" "$?" 2
  "$T" media-remap "$d/mu.db" >/dev/null 2>&1; eq "media-remap without a uid exits 2" "$?" 2
  eq "refused uids left the db untouched" "$(q "$d/mu.db" 'SELECT count(*) FROM files')" "[(9,)]"
  "$T" media-remap "$d/mgone.db" 13 >/dev/null 2>&1; eq "media-remap on a missing file exits 3" "$?" 3
  [ ! -e "$d/mgone.db" ] && ok "media-remap did not create the missing file" || no "media-remap created the missing file"
  fx notable "$d/mnt.db"
  "$T" media-remap "$d/mnt.db" 13 >/dev/null 2>&1; eq "media-remap without a files table exits 6" "$?" 6
  fx medianodata "$d/mnd.db"
  "$T" media-remap "$d/mnd.db" 13 >/dev/null 2>&1; eq "media-remap without a _data column exits 6" "$?" 6
  eq "media-remap without a _data column left the rows" "$(q "$d/mnd.db" 'SELECT x FROM files')" "[('/storage/emulated/10/a',)]"

  echo "== accounts-count =="
  fx acct1 "$d/a1.db"; fx acct0 "$d/a0.db"; fx notable "$d/an.db"
  out="$("$T" accounts-count "$d/a1.db")"; rc=$?; eq "one account: prints 1" "$out" 1; eq "one account: exits 0" "$rc" 0
  out="$("$T" accounts-count "$d/a0.db")"; rc=$?; eq "no accounts: prints 0" "$out" 0; eq "no accounts: exits 0" "$rc" 0
  out="$("$T" accounts-count "$d/an.db" 2>/dev/null)"; rc=$?
  eq "no accounts table: prints -1 (not 0)" "$out" -1; eq "no accounts table: exits 6" "$rc" 6
  eq "the roamd parse (tr -cd '0-9-') keeps the -1" "$(printf '%s\n' "$out" | tr -cd '0-9-')" -1
  "$T" accounts-count "$d/gone.db" >/dev/null 2>&1; eq "missing file exits 3" "$?" 3
  [ ! -e "$d/gone.db" ] && ok "accounts-count did not create the missing file" || no "accounts-count created the missing file"
  eq "accounts-count never wrote the db" "$(q "$d/a1.db" 'SELECT count(*) FROM accounts')" "[(1,)]"

  echo "== accounts-google =="
  fx acctg "$d/g1.db"; fx acctg0 "$d/g0.db"; fx acctgodd "$d/godd.db"
  out="$("$T" accounts-google "$d/g1.db")"; rc=$?
  eq "accounts-google: every type counted, Google names in _id order" "$out" "$(printf '3\nalpha.planted@gmail.com\nzeta.planted@gmail.com')"
  eq "accounts-google: exits 0" "$rc" 0
  out="$("$T" accounts-google "$d/g0.db")"; rc=$?; eq "accounts-google: no rows prints 0 alone" "$out" 0; eq "accounts-google: no rows exits 0" "$rc" 0
  out="$("$T" accounts-google "$d/godd.db")"; rc=$?
  eq "accounts-google: newline, empty, NULL, DEL and tab names print ?, UTF-8 passes" "$out" "$(printf '7\n?\n?\n?\n?\n?\njos\303\251@gmail.com')"
  eq "accounts-google: odd names exit 0" "$rc" 0
  out="$("$T" accounts-google "$d/a1.db" 2>/dev/null)"; rc=$?
  eq "accounts-google: no type column prints -1 alone" "$out" -1; eq "accounts-google: no type column exits 6" "$rc" 6
  out="$("$T" accounts-google "$d/an.db" 2>"$d/g.err")"; rc=$?
  eq "accounts-google: no accounts table prints -1 alone" "$out" -1; eq "accounts-google: no accounts table exits 6" "$rc" 6
  [ -s "$d/g.err" ] && [ -z "$(tail -c1 "$d/g.err")" ] && ok "accounts-google: stderr names the error and ends with a newline" || no "accounts-google: stderr empty or unterminated"
  "$T" accounts-google "$d/gone.db" >/dev/null 2>&1; eq "accounts-google: missing file exits 3" "$?" 3
  [ ! -e "$d/gone.db" ] && ok "accounts-google did not create the missing file" || no "accounts-google created the missing file"
  "$T" accounts-google "$d/g1.db" extra >/dev/null 2>&1; eq "accounts-google: extra arg exits 2" "$?" 2
  eq "accounts-google never wrote the db" "$(q "$d/g1.db" 'SELECT count(*) FROM accounts')" "[(3,)]"

  echo "== telscrub: the gate's table list, rollback-journal mode =="
  scrub_case "$T" "$d" delete
  echo "== telscrub: the gate's table list, WAL mode (second connection held open) =="
  scrub_case "$T" "$d" wal

  echo "== telscrub: the analytics list =="
  fx analytics "$d/an2.db"
  # shellcheck disable=SC2086
  out="$("$T" telscrub "$d/an2.db" $ANA_TABLES)"; rc=$?
  eq "analytics telscrub exits 0 past the missing CallDataLogs" "$rc" 0
  eq "analytics telscrub prints the cleared count" "$out" 2
  eq "analytics tables are empty" "$(q "$d/an2.db" 'SELECT (SELECT count(*) FROM SmsMmsDataLogs)+(SELECT count(*) FROM ServiceStateLogs)')" "[(0,)]"
  rm -rf "$d"
}

# scrub_case <tool> <dir> <delete|wal>
scrub_case() {
  local T="$1" d="$2" mode="$3" db hp out rc
  db="$d/s-$mode.db"
  if [ "$mode" = wal ]; then fx mms "$db" wal "$SENT"; else fx mms "$db" delete "$SENT"; fi
  eq "[$mode] fixture has no attachments/drm table" "$(q "$db" "SELECT count(*) FROM sqlite_master WHERE name IN ('attachments','drm')")" "[(0,)]"
  n="$(cat "$db" "$db-wal" 2>/dev/null | grep -a -c "$SENT")"
  [ "$n" -gt 0 ] && ok "[$mode] control: the sentinel is in the db bytes BEFORE the scrub" || no "[$mode] control: sentinel not found before the scrub"
  if [ "$mode" = wal ]; then
    rm -f "$d/ready" "$d/stop"
    python3 "$W/holder.py" "$db" "$d/ready" "$d/stop" & hp=$!
    for _ in $(seq 100); do [ -e "$d/ready" ] && break; sleep 0.1; done
    [ -e "$d/ready" ] && ok "[wal] the second connection is open" || no "[wal] the holder never opened"
  fi
  # shellcheck disable=SC2086
  out="$("$T" telscrub "$db" $MMS_TABLES)"; rc=$?
  eq "[$mode] telscrub exits 0 (skips the missing attachments/drm)" "$rc" 0
  eq "[$mode] telscrub prints the cleared count (9 of 11)" "$out" 9
  eq "[$mode] the content tables are empty" "$(q "$db" 'SELECT (SELECT count(*) FROM sms)+(SELECT count(*) FROM part)+(SELECT count(*) FROM threads)+(SELECT count(*) FROM pdu)+(SELECT count(*) FROM words)')" "[(0,)]"
  if [ "$mode" = wal ]; then
    [ -e "$db-wal" ] && ok "[wal] control: the -wal file still exists when its bytes are read" || no "[wal] control: -wal is gone -- the -wal half of the byte check is vacuous"
  fi
  n="$(cat "$db" "$db-wal" 2>/dev/null | grep -a -c "$SENT")"
  # The byte check alone cannot convict a missing VACUUM on a SQLite built with SQLITE_SECURE_DELETE (which zeroes
  # freed pages itself), so also pin what VACUUM guarantees on any build: no free pages are left in the file.
  eq "[$mode] no free pages remain (VACUUM ran)" "$(q "$db" 'PRAGMA freelist_count')" "[(0,)]"
  eq "[$mode] the sentinel is absent from the db$([ "$mode" = wal ] && echo ' and -wal') bytes" "$n" 0
  if [ "$mode" = wal ]; then touch "$d/stop"; wait "$hp"; fi
}

# media_case <tool> <dir> <delete|wal>
MEDIA_ROWS="SELECT _id, _data, owner_package_name FROM files ORDER BY _id"
MEDIA_WANT="[(1, '/storage/emulated/13/DCIM/Camera/IMG_1.jpg', 'com.example.camera'), (4, '/storage/emulated/13/Download/doc.pdf', 'com.example.files'), (5, '/storage/emulated/13/Pictures/Mixed.PNG', 'com.example.gallery'), (7, '/storage/ABCD-1234/DCIM/x.jpg', 'com.example.sd'), (8, '/storage/emulated/13', None), (9, '/storage/emulated/obb/x', None)]"
media_case() {
  local T="$1" d="$2" mode="$3" db bad out rc before after rows0
  db="$d/media-$mode.db"; bad="$d/mediabad-$mode.db"
  fx media "$db" "$mode"; fx mediabad "$bad" "$mode"
  eq "[$mode] control: the fixture's journal mode" "$(q "$db" 'PRAGMA journal_mode')" "[('$mode',)]"
  out="$("$T" media-remap "$db" 13 2>"$d/media.err")"; rc=$?
  eq "[$mode] media-remap exits 0 past the _INSERT/_UPDATE/_DELETE triggers" "$rc" 0
  eq "[$mode] media-remap prints '<remapped> <dropped>' exactly" "$out" "3 3"
  eq "[$mode] one row per file under the new user, the lowest _id kept with its owner, other rows untouched" \
     "$(q "$db" "$MEDIA_ROWS")" "$MEDIA_WANT"
  eq "[$mode] no file has two rows (case-insensitive)" \
     "$(q "$db" "SELECT lower(substr(_data, 21)), count(*) FROM files WHERE _data LIKE '/storage/emulated/13%' GROUP BY 1 HAVING count(*) > 1")" "[]"
  eq "[$mode] no row names an old user" "$(q "$db" "SELECT count(*) FROM files WHERE _data GLOB '/storage/emulated/1[0-2]*'")" "[(0,)]"
  rows0="$(q "$db" "$MEDIA_ROWS")"
  out="$("$T" media-remap "$db" 13 2>/dev/null)"; rc=$?
  eq "[$mode] a second run exits 0" "$rc" 0
  eq "[$mode] a second run changes nothing ('0 0')" "$out" "0 0"
  eq "[$mode] a second run leaves the rows" "$(q "$db" "$MEDIA_ROWS")" "$rows0"
  # A trigger calling a function the tool does not define: the DELETE succeeds, the UPDATE fails at prepare, and the
  # whole transaction must roll back.
  rows0="$(q "$bad" "$MEDIA_ROWS")"
  before="$(cat "$bad" "$bad-wal" 2>/dev/null | sha256sum)"
  "$T" media-remap "$bad" 13 >/dev/null 2>&1; rc=$?
  eq "[$mode] an unknown trigger function exits 6" "$rc" 6
  after="$(cat "$bad" "$bad-wal" 2>/dev/null | sha256sum)"
  eq "[$mode] an unknown trigger function leaves the db bytes unchanged (sha256)" "$after" "$before"
  eq "[$mode] an unknown trigger function leaves every row" "$(q "$bad" "$MEDIA_ROWS")" "$rows0"
}

echo "== the real tool =="
run_suite "$W/real"
echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

if [ "$MUTATE" = yes ]; then
  echo "== mutants =="
  cat > "$W/mutate.py" <<'PY'
import sys
# mutate.py <src> <dst> <old1> <new1> [<old2> <new2> ...]: every pair must apply (first match replaced).
src, dst, pairs = sys.argv[1], sys.argv[2], sys.argv[3:]
if not pairs or len(pairs) % 2:
    sys.exit("mutant needs old/new pairs")
t = open(src).read()
for old, new in zip(pairs[0::2], pairs[1::2]):
    if t.count(old) < 1:
        sys.exit("mutant did not apply: %r" % old)
    t = t.replace(old, new, 1)
open(dst, "w").write(t)
PY
  mutants=(
    "ident_ok always true|static int ident_ok(const char *s) {|static int ident_ok(const char *s) { return 1;"
    "VACUUM removed|\"VACUUM;\"|\"SELECT 1;\""
    "accounts-count prints 0 on prepare failure|printf(\"-1\\n\");|printf(\"0\\n\");"
    "accounts-google type filter dropped|WHERE type = 'com.google' ORDER BY _id;|ORDER BY _id;"
    "accounts-google line 1 counts only Google rows|SELECT COUNT(*) AS total FROM accounts;|SELECT COUNT(*) AS total FROM accounts WHERE type = 'com.google';"
    "accounts-google ? substitution removed|static int acct_name_printable(const unsigned char *s, int n) {|static int acct_name_printable(const unsigned char *s, int n) { return 1;"
    "launcher-widgets WHERE dropped|SET restored=15 WHERE itemType=4;|SET restored=15;"
    "WAL checkpoint removed|if (sqlite3_wal_checkpoint_v2(|if (0 && sqlite3_wal_checkpoint_v2("
    "media-remap registers no trigger functions|if (sqlite3_create_function(db, media_fns[f]|if (0 && sqlite3_create_function(db, media_fns[f]"
    "media-remap keeps the highest _id (MAX for MIN)|(SELECT MIN(id) FROM nw_media GROUP BY|(SELECT MAX(id) FROM nw_media GROUP BY"
    "media-remap without its transaction|\"BEGIN IMMEDIATE;\"|\"SELECT 1;\"|\"COMMIT;\"|\"SELECT 1;\""
    "media-remap dedupe not case-insensitive|GROUP BY lower(rest));|GROUP BY rest);"
    "media-remap groups on the whole _data (user segment included)|GROUP BY lower(rest));|GROUP BY lower((SELECT _data FROM files WHERE files._id = nw_media.id)));"
    "telscrub aborts on the first failed DELETE|if (exec_fmt(db, argv[i], \"DELETE FROM \\\"%s\\\";\", argv[i]) == 0) cleared++;|if (exec_fmt(db, argv[i], \"DELETE FROM \\\"%s\\\";\", argv[i]) != 0) { sqlite3_close(db); return 6; } else cleared++;"
  )
  CONVICTED=0; MFAIL=0
  for m in "${mutants[@]}"; do
    # name|old1|new1[|old2|new2...]: a mutant may need more than one replacement (the dropped transaction).
    IFS='|' read -r -a parts <<< "$m"
    name="${parts[0]}"
    if ! python3 "$W/mutate.py" "$SRC" "$W/mut.c" "${parts[@]:1}"; then no "mutant '$name' did not apply"; MFAIL=$((MFAIL+1)); continue; fi
    if ! build "$W/mut.c" "$W/mut"; then no "mutant '$name' does not compile"; MFAIL=$((MFAIL+1)); continue; fi
    b0=$FAIL
    run_suite "$W/mut" >"$W/mut.log" 2>&1
    if [ "$FAIL" -gt "$b0" ]; then echo "  convicted: $name"; CONVICTED=$((CONVICTED+1))
    else echo "  SURVIVED: $name"; MFAIL=$((MFAIL+1)); fi
  done
  echo "mutants convicted: $CONVICTED of ${#mutants[@]}"
  [ "$MFAIL" -eq 0 ] || exit 1
fi
echo "OK"
