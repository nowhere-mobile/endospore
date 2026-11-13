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
# lowest _id kept with its owner, other volumes untouched, exact counts, a second run `0 0 0 -`, and a trigger that
# calls an unknown function exits 6 with the db bytes unchanged (the dropped-transaction mutant leaves a half-done db).
# NWP-20261129-01 adds the columns idle maintenance and the albums read: `_user_id` on every row, `bucket_id` against
# a python oracle of Java's String.hashCode() (the suite exits 2 unless the oracle gives Java's own values first) and
# the generation, plus exit 6 with the db bytes unchanged for a `files` without those columns or an empty
# `local_metadata`, and exec_fmt refusing a statement too long for its buffer.
# NWP-20261130-02 adds media-insert, in both journal modes: every column of every new row against a python oracle (I2),
# `_user_id` (I3), `bucket_id` by the same Java-hash oracle, U+0130 and a 4-byte folder included (I4), one generation
# (I5), the rows already present untouched (I6), other types skipped (I7), a second run inserting nothing (I8), a
# file at the storage root (I15), and exit 6 with the db bytes unchanged for a `files` without a needed column, an
# empty `local_metadata`, an unknown trigger function and a list it cannot read or parse (I9, I10, I12).
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
import posixpath, sqlite3, sys
def jhash(s):  # Java's String.hashCode(): over UTF-16 code units, wrapped to a signed 32-bit value
    h = 0
    b = s.encode("utf-16-le")
    for i in range(0, len(b), 2):
        h = (h * 31 + int.from_bytes(b[i:i+2], "little")) & 0xffffffff
    return h - (1 << 32) if h >= (1 << 31) else h
def bucket(path):  # MediaProvider's bucket_id: the hash of the lower-cased parent
    return jhash(posixpath.dirname(path.lower()))
if sys.argv[1] == "oracle":
    print(jhash("hello"), jhash("Hello World"))
    sys.exit(0)
# media-insert's list: (rel, size, mtime, media_type, mime). Type 0 is skipped by the tool. Python's str.lower() is the
# fold Java's toLowerCase(Locale.ROOT) gives these names (U+0130 to i + U+0307, a final capital sigma to its final form).
INS_NEW = [("DCIM/Camera/a.jpg", 111, 1700000001, 1, "image/jpeg"),
           ("Pictures/b.PNG", 222, 1700000002, 1, "image/png"),
           ("Movies/c.mp4", 333, 1700000003, 3, "video/mp4"),
           ("Music/d.mp3", 444, 1700000004, 2, "audio/mpeg"),
           ("Pictures/\u0130stanbul/f.jpg", 555, 1700000005, 1, "image/jpeg"),
           ("Movies/\U0001F3ACclips/g.mp4", 666, 1700000006, 3, "video/mp4"),
           ("Pictures/\u03a3\u0391\u03a3/h.webp", 777, 1700000007, 1, "image/webp"),
           ("Pictures/zero.jpg", 888, 0, 1, "image/jpeg"),
           ("top.jpg", 999, 1700000012, 1, "image/jpeg")]  # the storage root, last: a stale binding would show here
INS_PRESENT = [("DCIM/Camera/present.jpg", 1, 1700000008), ("pictures/case.png", 1, 1700000009)]
INS_SKIPPED = [("Download/e.xyz", 1, 1700000010), ("Download/noext", 1, 1700000011), ("top.xyz", 1, 1700000014)]
def ins_record(rel, size, mtime):
    parent = posixpath.dirname(rel)
    return b"\0".join([b"%d" % size, b"%d" % mtime, parent.lower().encode(), rel.encode()]) + b"\0"
def ins_body():
    out = b"".join(ins_record(r[0], r[1], r[2]) for r in INS_NEW + INS_PRESENT + INS_SKIPPED)
    out += b"1\x001700000013\x00pictures\x00Pictures/\xff.jpg\x00"  # malformed UTF-8: skipped
    # A parent field that disagrees with its rel: skipped, in each direction.
    return out + b"1\x001700000015\x00pictures\x00stray.jpg\x00" + b"1\x001700000016\x00\x00Pictures/stray2.jpg\x00"
if sys.argv[1] == "rootbucket":  # the Java hash of /storage/emulated/<uid>, literally
    print(jhash("/storage/emulated/%s" % sys.argv[2]))
    sys.exit(0)
if sys.argv[1] == "inslist":  # inslist <path> <full|empty|cut|noterm|badsize|negsize>
    good = ins_record(*INS_NEW[0][:3])
    open(sys.argv[2], "wb").write({"full": ins_body(), "empty": b"",
                                   "cut": good + b"1\x001700000013\x00",
                                   "noterm": good + ins_record(*INS_NEW[1][:3])[:-1],
                                   "badsize": good + b"x1\x001700000013\x00movies\x00Movies/x.mp4\x00",
                                   "negsize": good + b"-1\x001700000013\x00movies\x00Movies/x.mp4\x00"}[sys.argv[3]])
    sys.exit(0)
if sys.argv[1] == "inscheck":  # inscheck <db> <uid> <has generation columns>: the new rows whose columns are not the oracle's
    c = sqlite3.connect(sys.argv[2])
    uid = int(sys.argv[3])
    gen = sys.argv[4] == "yes"
    wrong = []
    for rel, size, mtime, mt, mime in INS_NEW:
        data = "/storage/emulated/%d/%s" % (uid, rel)
        parent = posixpath.dirname(rel)
        want = (data, posixpath.basename(rel), parent + "/", posixpath.basename(parent) or None, mt, mime, size, mtime,
                mtime * 1000 if mtime else None, "external_primary", 0)
        got = c.execute("SELECT _data, _display_name, relative_path, bucket_display_name, media_type, mime_type, _size, "
                        "date_modified, datetaken, volume_name, is_pending FROM files WHERE _data = ?", (data,)).fetchall()
        if got != [want]:
            wrong.append(ascii(rel))
    print("checked=%d wrong=%s" % (len(INS_NEW), wrong))
    sys.exit(0)
if sys.argv[1] == "buckets":  # the ids whose bucket_id is not the oracle's for the row's CURRENT _data
    rows = sqlite3.connect(sys.argv[2]).execute("SELECT _id, _data, bucket_id FROM files WHERE bucket_id IS NOT NULL").fetchall()
    print("checked=%d wrong=%s" % (len(rows), [r[0] for r in rows if r[2] != bucket(r[1])]))
    sys.exit(0)
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
        "acctg": [(7, "zeta.planted@example.com", "com.google"), (2, "work@example.org", "com.example.exchange"),
                  (4, "alpha.planted@example.com", "com.google")],
        "acctg0": [],
        "acctgodd": [(1, "a\nb", "com.google"), (2, "", "com.google"), (3, None, "com.google"),
                     (4, "del\x7fx", "com.google"), (5, "tab\tx", "com.google"),
                     (6, "jos\u00e9@example.com", "com.google"), (7, "other\nname", "com.example.exchange")],
    }[kind]
    for r in rows:
        c.execute("INSERT INTO accounts(_id, name, type) VALUES (?,?,?)", r)
elif kind in ("media", "mediabad", "medianolm", "medianobucket", "medianogen", "mediaemptylm"):
    # MediaProvider's `files`, cut to the columns media-remap touches, and its one-row `local_metadata`. Each row's
    # generation_modified is 7 + (_id - 1); its bucket_id is the oracle's, except the row named nobucket. The triggers
    # are created AFTER the rows: this connection has no _INSERT, and CREATE TRIGGER does not resolve function names.
    cols = "_id INTEGER PRIMARY KEY AUTOINCREMENT, _data TEXT UNIQUE COLLATE NOCASE, owner_package_name TEXT, _user_id INTEGER"
    if kind != "medianobucket":
        cols += ", bucket_id INTEGER"
    if kind != "medianogen":
        cols += ", generation_modified INTEGER"
    c.execute("CREATE TABLE files (%s)" % cols)
    if kind != "medianolm":
        c.execute("CREATE TABLE local_metadata (generation INTEGER)")
        if kind != "mediaemptylm":
            c.execute("INSERT INTO local_metadata VALUES (41)")
    rows = [("/storage/emulated/10/DCIM/Camera/IMG_1.jpg", "com.example.camera", 10),
            ("/storage/emulated/11/DCIM/Camera/IMG_1.jpg", None, 11),
            ("/storage/emulated/12/DCIM/Camera/IMG_1.jpg", None, 12),
            ("/storage/emulated/13/Download/doc.pdf", "com.example.files", 10),
            ("/storage/emulated/10/Pictures/Mixed.PNG", "com.example.gallery", 10),
            ("/storage/emulated/11/pictures/mixed.png", None, 11),
            ("/storage/ABCD-1234/DCIM/x.jpg", "com.example.sd", 10),
            ("/storage/emulated/10", None, 10),
            ("/storage/emulated/obb/x", None, 13),
            ("/storage/emulated/13/Music/here.mp3", "com.example.music", 13),
            ("/storage/emulated/9/Pictures/\u0130stanbul/a.jpg", "com.example.p", 9),
            ("/storage/emulated/123/Movies/\U0001F3ACclips/\u0130\U0001F3AC.mp4", "com.example.m", 123),
            ("/storage/emulated/10/Alarms/nobucket.ogg", None, 10),
            ("/storage/emulated/10/top.txt", None, None),
            ("/storage/emulated/10/Podcasts/p.mp3", None, 13)]
    for i, (p, o, u) in enumerate(rows):
        c.execute("INSERT INTO files(_data, owner_package_name, _user_id) VALUES (?,?,?)", (p, o, u))
        if kind != "medianobucket":
            c.execute("UPDATE files SET bucket_id = ? WHERE _id = ?", (None if "nobucket" in p else bucket(p), i + 1))
        if kind != "medianogen":
            c.execute("UPDATE files SET generation_modified = ? WHERE _id = ?", (7 + i, i + 1))
elif kind == "mediaold":
    # The shape before NWP-20261129-01: no _user_id, bucket_id or generation_modified, no local_metadata.
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
elif kind == "medianodata":
    c.execute("CREATE TABLE files (_id INTEGER PRIMARY KEY, x TEXT)")
    c.execute("INSERT INTO files(x) VALUES ('/storage/emulated/10/a')")
elif kind.startswith("mediains"):
    # MediaProvider's `files`, cut to what media-insert writes, plus two columns it leaves alone. The variants drop
    # what the op needs. Two rows are already present, one in another letter case than the list names it.
    nogen = kind == "mediainsnolm"
    drop = {"mediainsnouser": "_user_id", "mediainsnobucket": "bucket_id", "mediainsnogenadd": "generation_added",
            "mediainsnogenmod": "generation_modified"}.get(kind)
    names = ["_data TEXT UNIQUE COLLATE NOCASE", "_user_id INTEGER", "bucket_id INTEGER", "bucket_display_name TEXT",
             "relative_path TEXT", "_display_name TEXT", "media_type INTEGER", "mime_type TEXT", "_size INTEGER",
             "date_modified INTEGER", "date_added INTEGER", "datetaken INTEGER", "volume_name TEXT", "is_pending INTEGER",
             "owner_package_name TEXT", "title TEXT"]
    if not nogen:
        names += ["generation_added INTEGER", "generation_modified INTEGER"]
    names = [n for n in names if n.split()[0] != drop]
    c.execute("CREATE TABLE files (_id INTEGER PRIMARY KEY AUTOINCREMENT, %s)" % ", ".join(names))
    if not nogen:
        c.execute("CREATE TABLE local_metadata (generation INTEGER)")
        if kind != "mediainsemptylm":
            c.execute("INSERT INTO local_metadata VALUES (41)")
    for p in ("/storage/emulated/13/DCIM/Camera/present.jpg", "/storage/emulated/13/Pictures/Case.PNG"):
        c.execute("INSERT INTO files(_data, owner_package_name) VALUES (?, 'com.example.camera')", (p,))
        if drop != "bucket_id":
            c.execute("UPDATE files SET bucket_id = ? WHERE _data = ?", (bucket(p), p))
        if drop != "_user_id":
            c.execute("UPDATE files SET _user_id = 13 WHERE _data = ?", (p,))
        if not nogen and drop != "generation_modified":
            c.execute("UPDATE files SET generation_modified = 5 WHERE _data = ?", (p,))
elif kind == "notable":
    c.execute("CREATE TABLE other (x INTEGER)")
elif kind == "analytics":
    c.execute("CREATE TABLE SmsMmsDataLogs (d TEXT, n INTEGER)")
    c.execute("CREATE TABLE ServiceStateLogs (d TEXT, n INTEGER)")
    c.execute("INSERT INTO SmsMmsDataLogs VALUES ('2026-07-31', 1)")
    c.execute("INSERT INTO ServiceStateLogs VALUES ('2026-07-31', 1)")
if kind.startswith("media") and kind != "medianodata":
    upd = "_NW_UNKNOWN(old._id)" if kind == "mediabad" else "_UPDATE(old._id, new._data)"
    ins = "_NW_UNKNOWN(new._id)" if kind == "mediainsbad" else "_INSERT(new._id, new._data)"
    c.execute("CREATE TRIGGER files_insert AFTER INSERT ON files BEGIN SELECT %s; END" % ins)
    c.execute("CREATE TRIGGER files_update AFTER UPDATE ON files BEGIN SELECT %s; END" % upd)
    c.execute("CREATE TRIGGER files_delete AFTER DELETE ON files BEGIN SELECT _DELETE(old._id, old._data); END")
c.commit()
c.close()
PY
[ "$(python3 "$W/fixture.py" oracle)" = "99162322 -862545276" ] || { echo "FAIL: the bucket_id oracle does not give Java's String.hashCode() values -- the suite did NOT run" >&2; exit 2; }
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
q() { python3 -c 'import sqlite3,sys; print(ascii(sqlite3.connect(sys.argv[1]).execute(sys.argv[2]).fetchall()))' "$1" "$2"; }

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
  eq "refused uids left the db untouched" "$(q "$d/mu.db" 'SELECT count(*) FROM files')" "[(15,)]"
  "$T" media-remap "$d/mgone.db" 13 >/dev/null 2>&1; eq "media-remap on a missing file exits 3" "$?" 3
  [ ! -e "$d/mgone.db" ] && ok "media-remap did not create the missing file" || no "media-remap created the missing file"
  fx notable "$d/mnt.db"
  "$T" media-remap "$d/mnt.db" 13 >/dev/null 2>&1; eq "media-remap without a files table exits 6" "$?" 6
  fx medianodata "$d/mnd.db"
  "$T" media-remap "$d/mnd.db" 13 >/dev/null 2>&1; eq "media-remap without a _data column exits 6" "$?" 6
  eq "media-remap without a _data column left the rows" "$(q "$d/mnd.db" 'SELECT x FROM files')" "[('/storage/emulated/10/a',)]"

  echo "== media-insert: rollback-journal mode =="
  media_insert_case "$T" "$d" delete
  echo "== media-insert: WAL mode =="
  media_insert_case "$T" "$d" wal
  echo "== media-insert: arguments =="
  fx mediains "$d/iu.db"; fx inslist "$d/iu.rows" full
  "$T" media-insert "$d/iu.db" x "$d/iu.rows" >/dev/null 2>&1; eq "media-insert uid 'x' exits 2" "$?" 2
  "$T" media-insert "$d/iu.db" -1 "$d/iu.rows" >/dev/null 2>&1; eq "media-insert uid '-1' exits 2" "$?" 2
  "$T" media-insert "$d/iu.db" 13 >/dev/null 2>&1; eq "media-insert without a list exits 2" "$?" 2
  "$T" media-insert "$d/iu.db" 13 "$d/iu.rows" extra >/dev/null 2>&1; eq "media-insert with an extra argument exits 2" "$?" 2
  eq "refused arguments left the db untouched" "$(q "$d/iu.db" 'SELECT count(*) FROM files')" "[(2,)]"
  "$T" media-insert "$d/igone.db" 13 "$d/iu.rows" >/dev/null 2>&1; eq "media-insert on a missing file exits 3" "$?" 3
  [ ! -e "$d/igone.db" ] && ok "media-insert did not create the missing file" || no "media-insert created the missing file"

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
  eq "accounts-google: every type counted, Google names in _id order" "$out" "$(printf '3\nalpha.planted@example.com\nzeta.planted@example.com')"
  eq "accounts-google: exits 0" "$rc" 0
  out="$("$T" accounts-google "$d/g0.db")"; rc=$?; eq "accounts-google: no rows prints 0 alone" "$out" 0; eq "accounts-google: no rows exits 0" "$rc" 0
  out="$("$T" accounts-google "$d/godd.db")"; rc=$?
  eq "accounts-google: newline, empty, NULL, DEL and tab names print ?, UTF-8 passes" "$out" "$(printf '7\n?\n?\n?\n?\n?\njos\303\251@example.com')"
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

  echo "== exec_fmt: a statement too long for its buffer =="
  fx mms "$d/long.db" x
  out="$("$T" telscrub "$d/long.db" "$(printf 'a%.0s' $(seq 600))" 2>"$d/long.err")"; rc=$?
  eq "a 600-character table name: telscrub skips it and exits 0" "$rc" 0
  eq "a 600-character table name: nothing cleared" "$out" 0
  case "$(cat "$d/long.err")" in
    *"nowhere_db_fix: aaa"*": statement too long"*) ok "a cut statement is refused, not run" ;;
    *) no "a cut statement is refused, not run (stderr did not say 'statement too long')" ;;
  esac

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
MEDIA_ROWS="SELECT _id, _data, owner_package_name, _user_id, generation_modified FROM files ORDER BY _id"
MEDIA_WANT="[(1, '/storage/emulated/13/DCIM/Camera/IMG_1.jpg', 'com.example.camera', 13, 42), (4, '/storage/emulated/13/Download/doc.pdf', 'com.example.files', 13, 42), (5, '/storage/emulated/13/Pictures/Mixed.PNG', 'com.example.gallery', 13, 42), (7, '/storage/ABCD-1234/DCIM/x.jpg', 'com.example.sd', 13, 42), (8, '/storage/emulated/13', None, 13, 42), (9, '/storage/emulated/obb/x', None, 13, 15), (10, '/storage/emulated/13/Music/here.mp3', 'com.example.music', 13, 16), (11, '/storage/emulated/13/Pictures/\u0130stanbul/a.jpg', 'com.example.p', 13, 42), (12, '/storage/emulated/13/Movies/\U0001f3acclips/\u0130\U0001f3ac.mp4', 'com.example.m', 13, 42), (13, '/storage/emulated/13/Alarms/nobucket.ogg', None, 13, 42), (14, '/storage/emulated/13/top.txt', None, 13, 42), (15, '/storage/emulated/13/Podcasts/p.mp3', None, 13, 42)]"
# The rows the repoint does not move keep their bucket_id; the user-root row moves but its parent is above the prefix.
MEDIA_SAME_BUCKET="SELECT _id, bucket_id FROM files WHERE _id IN (4, 7, 8, 9, 10) ORDER BY _id"
media_bytes() { cat "$1" "$1-wal" 2>/dev/null | sha256sum; }
media_case() {
  local T="$1" d="$2" mode="$3" db bad out rc before after rows0 k f b1
  db="$d/media-$mode.db"; bad="$d/mediabad-$mode.db"
  fx media "$db" "$mode"; fx mediabad "$bad" "$mode"
  eq "[$mode] control: the fixture's journal mode" "$(q "$db" 'PRAGMA journal_mode')" "[('$mode',)]"
  eq "[$mode] control: every bucket_id is the oracle's before the run" "$(python3 "$W/fixture.py" buckets "$db")" "checked=14 wrong=[]"
  b1="$(q "$db" 'SELECT bucket_id FROM files WHERE _id = 1')"
  before="$(q "$db" "$MEDIA_SAME_BUCKET")"
  out="$("$T" media-remap "$db" 13 2>"$d/media.err")"; rc=$?
  eq "[$mode] media-remap exits 0 past the _INSERT/_UPDATE/_DELETE triggers" "$rc" 0
  eq "[$mode] media-remap prints '<remapped> <dropped> <reowned> <generation>' exactly" "$out" "8 3 9 42"
  eq "[$mode] one row per file under the new user, the lowest _id kept with its owner, every _user_id 13, changed rows at generation 42, other rows untouched" \
     "$(q "$db" "$MEDIA_ROWS")" "$MEDIA_WANT"
  eq "[$mode] no file has two rows (case-insensitive)" \
     "$(q "$db" "SELECT lower(substr(_data, 21)), count(*) FROM files WHERE _data LIKE '/storage/emulated/13%' GROUP BY 1 HAVING count(*) > 1")" "[]"
  eq "[$mode] no row names an old user" "$(q "$db" "SELECT count(*) FROM files WHERE _data GLOB '/storage/emulated/[0-9]*' AND _data NOT GLOB '/storage/emulated/13*'")" "[(0,)]"
  eq "[$mode] every kept bucket_id is the oracle's for its NEW path" "$(python3 "$W/fixture.py" buckets "$db")" "checked=11 wrong=[]"
  if [ "$(q "$db" 'SELECT bucket_id FROM files WHERE _id = 1')" != "$b1" ]; then ok "[$mode] control: the repoint moved a row's bucket_id"; else no "[$mode] control: row 1's bucket_id did not move"; fi
  eq "[$mode] the rows the repoint does not move keep their bucket_id" "$(q "$db" "$MEDIA_SAME_BUCKET")" "$before"
  eq "[$mode] a NULL bucket_id stays NULL" "$(q "$db" 'SELECT bucket_id FROM files WHERE _id = 13')" "[(None,)]"
  eq "[$mode] every row has the session's _user_id" "$(q "$db" 'SELECT DISTINCT _user_id FROM files')" "[(13,)]"
  eq "[$mode] local_metadata took one new generation" "$(q "$db" 'SELECT generation FROM local_metadata')" "[(42,)]"
  rows0="$(q "$db" "$MEDIA_ROWS")"
  before="$(media_bytes "$db")"
  out="$("$T" media-remap "$db" 13 2>/dev/null)"; rc=$?
  eq "[$mode] a second run exits 0" "$rc" 0
  eq "[$mode] a second run changes nothing ('0 0 0 -')" "$out" "0 0 0 -"
  eq "[$mode] a second run leaves the rows" "$(q "$db" "$MEDIA_ROWS")" "$rows0"
  eq "[$mode] a second run takes no generation" "$(q "$db" 'SELECT generation FROM local_metadata')" "[(42,)]"
  eq "[$mode] a second run leaves the db bytes unchanged (sha256)" "$(media_bytes "$db")" "$before"
  # A trigger calling a function the tool does not define: the DELETE succeeds, the UPDATE fails at prepare, and the
  # whole transaction must roll back.
  rows0="$(q "$bad" "$MEDIA_ROWS")"
  before="$(media_bytes "$bad")"
  "$T" media-remap "$bad" 13 >/dev/null 2>&1; rc=$?
  eq "[$mode] an unknown trigger function exits 6" "$rc" 6
  after="$(media_bytes "$bad")"
  eq "[$mode] an unknown trigger function leaves the db bytes unchanged (sha256)" "$after" "$before"
  eq "[$mode] an unknown trigger function leaves every row" "$(q "$bad" "$MEDIA_ROWS")" "$rows0"
  # No local_metadata: repointed and re-owned, generations untouched.
  f="$d/medianolm-$mode.db"
  fx medianolm "$f" "$mode"
  rows0="$(q "$f" 'SELECT _id, generation_modified FROM files WHERE _id NOT IN (2, 3, 6) ORDER BY _id')"
  out="$("$T" media-remap "$f" 13 2>/dev/null)"; rc=$?
  eq "[$mode] no local_metadata: exits 0" "$rc" 0
  eq "[$mode] no local_metadata: the output ends '-'" "$out" "8 3 9 -"
  eq "[$mode] no local_metadata: every bucket_id is the oracle's" "$(python3 "$W/fixture.py" buckets "$f")" "checked=11 wrong=[]"
  eq "[$mode] no local_metadata: every row re-owned" "$(q "$f" 'SELECT DISTINCT _user_id FROM files')" "[(13,)]"
  eq "[$mode] no local_metadata: generations untouched" "$(q "$f" 'SELECT _id, generation_modified FROM files ORDER BY _id')" "$rows0"
  # Fail closed: today's shape, a missing column, an empty local_metadata.
  for k in mediaold medianobucket medianogen mediaemptylm; do
    f="$d/$k-$mode.db"
    fx "$k" "$f" "$mode"
    before="$(media_bytes "$f")"
    "$T" media-remap "$f" 13 >/dev/null 2>&1; rc=$?
    eq "[$mode] $k exits 6" "$rc" 6
    eq "[$mode] $k leaves the db bytes unchanged (sha256)" "$(media_bytes "$f")" "$before"
  done
}

# media_insert_case <tool> <dir> <delete|wal>
INS_NEWW="_data NOT IN ('/storage/emulated/13/DCIM/Camera/present.jpg', '/storage/emulated/13/Pictures/Case.PNG')"
INS_OLDR="SELECT * FROM files WHERE _id IN (1, 2) ORDER BY _id"
media_insert_case() {
  local T="$1" d="$2" mode="$3" db l out rc err rows0 before t0 t1 k v
  db="$d/ins-$mode.db"; l="$d/ins-$mode.rows"
  fx mediains "$db" "$mode"; fx inslist "$l" full
  eq "[$mode] control: the fixture's journal mode" "$(q "$db" 'PRAGMA journal_mode')" "[('$mode',)]"
  rows0="$(q "$db" "$INS_OLDR")"
  t0="$(date +%s)"
  out="$("$T" media-insert "$db" 13 "$l" 2>"$d/ins.err")"; rc=$?
  t1="$(date +%s)"
  eq "I1 [$mode] exits 0 past the triggers" "$rc" 0
  eq "I1 [$mode] prints '<inserted> <present> <skipped> <generation>' exactly" "$out" "9 2 6 42"
  eq "I2 [$mode] every column of every new row is the oracle's" "$(python3 "$W/fixture.py" inscheck "$db" 13 yes)" "checked=9 wrong=[]"
  eq "I3 [$mode] every new row has the session's _user_id" "$(q "$db" "SELECT DISTINCT _user_id FROM files WHERE $INS_NEWW")" "[(13,)]"
  eq "I4 [$mode] every bucket_id is set and the oracle's, U+0130, final sigma and a 4-byte folder included" "$(python3 "$W/fixture.py" buckets "$db")" "checked=11 wrong=[]"
  eq "I5 [$mode] local_metadata took exactly one new generation" "$(q "$db" 'SELECT generation FROM local_metadata')" "[(42,)]"
  eq "I5 [$mode] generation_added and generation_modified hold it on every new row" "$(q "$db" "SELECT DISTINCT generation_added, generation_modified FROM files WHERE $INS_NEWW")" "[(42, 42)]"
  eq "I6 [$mode] the rows already present are unchanged, the one in another letter case too" "$(q "$db" "$INS_OLDR")" "$rows0"
  eq "I7 [$mode] no row for another type, no extension, a parent that disagrees or malformed UTF-8" "$(q "$db" "SELECT count(*) FROM files WHERE _data LIKE '%.xyz' OR _data LIKE '%/noext' OR _data LIKE '%stray%' OR media_type = 0 OR mime_type IS NULL AND _id > 2")" "[(0,)]"
  eq "I7 [$mode] the table holds exactly the new rows and the present ones" "$(q "$db" 'SELECT count(*) FROM files')" "[(11,)]"
  eq "I15 [$mode] a file at the storage root: its row, '/' and no bucket name" "$(q "$db" "SELECT _data, relative_path, bucket_display_name FROM files WHERE _display_name = 'top.jpg'")" "[('/storage/emulated/13/top.jpg', '/', None)]"
  eq "I15 [$mode] a file at the storage root: its bucket hashes the user root with no trailing slash" "$(q "$db" "SELECT bucket_id FROM files WHERE _display_name = 'top.jpg'")" "[($(python3 "$W/fixture.py" rootbucket 13),)]"
  eq "I14 [$mode] mtime 0: date_modified 0, datetaken NULL" "$(q "$db" "SELECT date_modified, datetaken FROM files WHERE _data LIKE '%/zero.jpg'")" "[(0, None)]"
  v="$(q "$db" "SELECT date_added FROM files WHERE _data LIKE '%/zero.jpg'" | tr -cd '0-9')"
  if [ -n "$v" ] && [ "$v" -ge "$t0" ] && [ "$v" -le "$t1" ]; then ok "I14 [$mode] mtime 0: date_added is the run's time"; else no "I14 [$mode] mtime 0: date_added '$v' is not within $t0..$t1"; fi
  eq "I14 [$mode] any other row: date_added is its mtime" "$(q "$db" "SELECT date_added FROM files WHERE _data LIKE '%/a.jpg'")" "[(1700000001,)]"
  rows0="$(q "$db" 'SELECT * FROM files ORDER BY _id')"; before="$(media_bytes "$db")"
  out="$("$T" media-insert "$db" 13 "$l" 2>/dev/null)"; rc=$?
  eq "I8 [$mode] a second run exits 0" "$rc" 0
  eq "I8 [$mode] a second run inserts nothing and takes no generation" "$out" "0 11 6 -"
  eq "I8 [$mode] a second run leaves the rows" "$(q "$db" 'SELECT * FROM files ORDER BY _id')" "$rows0"
  eq "I8 [$mode] a second run leaves the db bytes unchanged (sha256)" "$(media_bytes "$db")" "$before"
  # An empty list: nothing to do, no generation.
  k="$d/insempty-$mode.db"; fx mediains "$k" "$mode"; fx inslist "$d/empty.rows" empty
  out="$("$T" media-insert "$k" 13 "$d/empty.rows" 2>/dev/null)"; rc=$?
  eq "I8 [$mode] an empty list prints '0 0 0 -'" "$rc $out" "0 0 0 0 -"
  eq "I8 [$mode] an empty list takes no generation" "$(q "$k" 'SELECT generation FROM local_metadata')" "[(41,)]"
  # Fail closed, the statements prepared before the first record: the empty list must still refuse these schemas.
  for k in mediainsnouser mediainsnobucket mediainsnogenadd mediainsnogenmod notable; do
    for v in full empty; do
      fx "$k" "$d/$k-$mode.db" "$mode"; fx inslist "$d/$v.rows" "$v"
      before="$(media_bytes "$d/$k-$mode.db")"
      "$T" media-insert "$d/$k-$mode.db" 13 "$d/$v.rows" >/dev/null 2>&1; rc=$?
      eq "I9 [$mode] $k, $v list: exits 6" "$rc" 6
      eq "I9 [$mode] $k, $v list: the db bytes are unchanged (sha256)" "$(media_bytes "$d/$k-$mode.db")" "$before"
      rm -f "$d/$k-$mode.db"
    done
  done
  k="$d/insbad-$mode.db"; fx mediainsbad "$k" "$mode"; before="$(media_bytes "$k")"
  "$T" media-insert "$k" 13 "$l" >/dev/null 2>&1; rc=$?
  eq "I9 [$mode] an unknown trigger function exits 6" "$rc" 6
  eq "I9 [$mode] an unknown trigger function leaves the db bytes unchanged (sha256)" "$(media_bytes "$k")" "$before"
  k="$d/insemptylm-$mode.db"; fx mediainsemptylm "$k" "$mode"; before="$(media_bytes "$k")"
  "$T" media-insert "$k" 13 "$l" >/dev/null 2>&1; rc=$?
  eq "I10 [$mode] an empty local_metadata exits 6" "$rc" 6
  eq "I10 [$mode] an empty local_metadata adds no row (db bytes unchanged)" "$(media_bytes "$k")" "$before"
  k="$d/insnolm-$mode.db"; fx mediainsnolm "$k" "$mode"
  out="$("$T" media-insert "$k" 13 "$l" 2>/dev/null)"; rc=$?
  eq "I11 [$mode] no local_metadata: exits 0, the last field '-'" "$rc $out" "0 9 2 6 -"
  eq "I11 [$mode] no local_metadata: the columns are the oracle's" "$(python3 "$W/fixture.py" inscheck "$k" 13 no)" "checked=9 wrong=[]"
  # The bad records come after a good one, so a run without its transaction would leave that row behind.
  for v in cut noterm badsize negsize; do
    k="$d/ins$v-$mode.db"; fx mediains "$k" "$mode"; fx inslist "$d/$v.rows" "$v"
    before="$(media_bytes "$k")"
    out="$("$T" media-insert "$k" 13 "$d/$v.rows" 2>"$d/ins.err")"; rc=$?
    eq "I12 [$mode] list '$v': exits 6, no counts" "$rc:$out" "6:"
    eq "I12 [$mode] list '$v': the db bytes are unchanged (sha256)" "$(media_bytes "$k")" "$before"
    case "$(cat "$d/ins.err")" in *.jpg*|*.mp4*|*Camera*|*Movies*) no "I13 [$mode] list '$v': stderr holds a list value" ;; *) ok "I13 [$mode] list '$v': stderr holds no list value" ;; esac
  done
  k="$d/insnolist-$mode.db"; fx mediains "$k" "$mode"; before="$(media_bytes "$k")"
  "$T" media-insert "$k" 13 "$d/no-such.rows" >/dev/null 2>&1; rc=$?
  eq "I12 [$mode] a missing list exits 6" "$rc" 6
  eq "I12 [$mode] a missing list leaves the db bytes unchanged (sha256)" "$(media_bytes "$k")" "$before"
  k="$d/insplant-$mode.db"; fx mediains "$k" "$mode"
  out="$("$T" media-insert "$k" 13 "$l" 2>&1)"
  eq "I13 [$mode] stdout and stderr together are the counts alone, never a path" "$out" "9 2 6 42"
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
    "media-remap _user_id update removed|\"UPDATE files SET _user_id = %lld WHERE _user_id IS NOT %lld;\"|\"SELECT %lld, %lld;\""
    "media-remap bucket assignment removed|bucket_id = (SELECT nw_rebucket(files.bucket_id, usr, %lld, rest) FROM nw_media WHERE id = files._id) |bucket_id = (SELECT files.bucket_id + 0 * %lld) "
    "nw_rebucket drops the 31^R factor|(h_new - h_old) * scale|(h_new - h_old) * (scale / scale)"
    "nw_rebucket counts U+0130 once|if (*p == 0xC4 && p[1] == 0xB0) scale *= 31u;|if (0) scale *= 31u;"
    "nw_rebucket counts a 4-byte sequence once|if (*p >= 0xF0) scale *= 31u;|if (0) scale *= 31u;"
    "nw_rebucket root-row guard dropped|if (*rest == '\\0') {|if (0) {"
    "media-remap generation bump removed|\"UPDATE local_metadata SET generation = generation + 1;\"|\"SELECT 1;\""
    "media-remap rows' generation_modified not set|SET generation_modified = (SELECT MAX(generation) FROM local_metadata)|SET generation_modified = generation_modified"
    "exec_fmt cut-statement check off|if ((size_t)n >= sizeof(sql)) {|if ((size_t)n >= sizeof(sql) * 2) {"
    "media-remap nw_chg misses the repointed rows|\"INSERT INTO temp.nw_chg SELECT id FROM nw_media WHERE usr <> '%lld' AND id IN (SELECT _id FROM files) \"|\"INSERT INTO temp.nw_chg SELECT id FROM nw_media WHERE usr <> '%lld' AND 0 \""
    "media-remap empty local_metadata writes NULL|if (sqlite3_column_type(st, 0) == SQLITE_NULL) {|if (sqlite3_column_type(st, 0) == SQLITE_NULL && 0) {"
    "I3 media-insert _user_id not set|sqlite3_bind_int64(ins, 2, uid);|sqlite3_bind_null(ins, 2);"
    "I4 media-insert bucket not set|sqlite3_bind_int(ins, 3, (int32_t)bucket);|sqlite3_bind_null(ins, 3);"
    "I4 media-insert hash takes a surrogate pair as one unit|v = v * 31u + (0xDC00u + (cp & 0x3FFu));|;"
    "I4 media-insert hashes the parent as given, not the agent's fold|java_hash_utf8((const unsigned char *)flower, &bucket) != 0|java_hash_utf8((const unsigned char *)frel, &bucket) != 0"
    "I5 media-insert generation not bumped|\"media-insert\", \"UPDATE local_metadata SET generation = generation + 1;\"|\"media-insert\", \"SELECT 1;\""
    "I5 media-insert bumps for every row|if (has_meta && !bumped) {|if (has_meta) {"
    "I5 media-insert generation_added not set|sqlite3_bind_int64(ins, 13, generation);|sqlite3_bind_null(ins, 13);"
    "I5 media-insert generation_modified not set|sqlite3_bind_int64(ins, 14, generation);|sqlite3_bind_null(ins, 14);"
    "I8 media-insert duplicate check removed|if (sr == SQLITE_ROW) {|if (0) {"
    "I7 media-insert unknown type inserted|if (mt == 0) {|if (0) {"
    "I7 media-insert malformed UTF-8 inserted|else return -1;|else { cp = *s; more = 0; }"
    "I12 media-insert without its transaction|\"media-insert\", \"BEGIN IMMEDIATE;\"|\"media-insert\", \"SELECT 1;\"|\"media-insert\", \"COMMIT;\"|\"media-insert\", \"SELECT 1;\""
    "I12 media-insert accepts a last field with no terminator|return (*buf)[n - 1] == '\\0' ? 1 : -1;|return 1;"
    "I12 media-insert accepts a negative size|size < 0|(size < 0 && 0)"
    "I2 media-insert datetaken in seconds|sqlite3_bind_int64(ins, 12, mtime * 1000);|sqlite3_bind_int64(ins, 12, mtime);"
    "I2 media-insert relative_path without its slash|sqlite3_mprintf(\"%s/\", frel)|sqlite3_mprintf(\"%s\", frel)"
    "I14 media-insert date_added 0 for mtime 0|mtime ? mtime : now|mtime ? mtime : now * 0"
    "I15 media-insert skips a file at the storage root|if (slash == frel |if (!slash "
    "I15 media-insert root bucket with a trailing slash|(slash && (java_hash_utf8((const unsigned char *)\"/\", &bucket) != 0|(java_hash_utf8((const unsigned char *)\"/\", &bucket) != 0 ? 1 : slash && (0"
    "I15 media-insert root relative_path empty|sqlite3_mprintf(\"/\")|sqlite3_mprintf(\"\")"
    "I15 media-insert root bucket name not NULL|sqlite3_bind_null(ins, 4);|sqlite3_bind_text(ins, 4, \"\", -1, SQLITE_STATIC);"
    "I15 media-insert root bucket name a stale binding|sqlite3_bind_null(ins, 4);|;"
    "I7 media-insert takes a parent field that disagrees|!slash != !*flower|0"
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
