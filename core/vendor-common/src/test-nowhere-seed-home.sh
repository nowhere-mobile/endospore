#!/usr/bin/env bash
# test-nowhere-seed-home.sh [--mutate] -- compiles core/vendor-common/src/nowhere_seed_home.c on the host and RUNS it
# against real SQLite (NWP-20261015-26).
#
# WHY THIS IS COMMITTED. nowhere_seed_home writes page 2 of every fresh Endospore profile's launcher as root and had
# never been executed off the device. Pinned here: the exit-code contract (0 seeded / skipped, 3, 4, 5, 6), the
# empty-workspace guard, the profile serial read from the HOTSEAT rows, the one-transaction rule (a failing row
# mid-file commits nothing), the "no rows -> rollback, exit 0, empty stdout" path, the descriptor parser (an EMPTY
# numeric field and a sixth field are malformed), and that every committed Endospore default-home descriptor seeds
# with zero malformed lines.
#
# Same toolchain checks as test-nowhere-db-fix.sh (NWP-20261015-23): no skip arm -- a host without cc, python3 or the
# SQLite headers FAILS (exit 2). Fixtures are built with python3's sqlite3 module.
#
#   bash test-nowhere-seed-home.sh            # the invariants
#   bash test-nowhere-seed-home.sh --mutate   # ... plus mutants of the C file that must each be CONVICTED
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/nowhere_seed_home.c"
ROOT="$(cd "$HERE/../../.." && pwd)"
[ -f "$SRC" ] || { echo "no nowhere_seed_home.c beside: $HERE" >&2; exit 2; }
command -v cc >/dev/null 2>&1 || { echo "FAIL: no C compiler (cc) on this host -- the suite did NOT run" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: no python3 on this host -- the suite did NOT run" >&2; exit 2; }
cc --version | head -1
python3 -c 'import sqlite3; print("python sqlite3 module: SQLite", sqlite3.sqlite_version)' || exit 2

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

build() { # $1=source $2=output
  cc -O2 -Wall -Werror "$1" -o "$2" -lsqlite3 2> "$W/cc.err" || { cat "$W/cc.err" >&2; return 1; }
}
build "$SRC" "$W/real" || { echo "FAIL: nowhere_seed_home.c does not build here (missing sqlite3.h / libsqlite3?) -- the suite did NOT run" >&2; exit 2; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
eq(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3', got '$2')"; fi; }

# fixture.py <db> <kind> [serial]: kind = empty (hotseat only) | populated (a desktop item too) | nohotseat |
# check (a CHECK on cellX < 5 so a row can fail mid-file) | noserial_desk (serial only on a DESKTOP row, which
# is populated, so use `deskonly` to make a hotseat-free, desktop-free db whose only row is elsewhere).
cat > "$W/fixture.py" <<'PY'
import sqlite3, sys
path, kind = sys.argv[1], sys.argv[2]
serial = int(sys.argv[3]) if len(sys.argv) > 3 else 7
c = sqlite3.connect(path)
chk = ", CHECK (cellX < 5)" if kind == "check" else ""
c.execute("CREATE TABLE favorites (_id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL DEFAULT '', "
          "intent TEXT, container INTEGER, screen INTEGER, cellX INTEGER NOT NULL, cellY INTEGER, spanX INTEGER, "
          "spanY INTEGER, itemType INTEGER, profileId INTEGER, restored INTEGER" + chk + ")")
def row(container, screen, x, y, prof):
    c.execute("INSERT INTO favorites(title,intent,container,screen,cellX,cellY,spanX,spanY,itemType,profileId,restored) "
              "VALUES ('','dock',?,?,?,?,1,1,0,?,0)", (container, screen, x, y, prof))
if kind != "nohotseat":
    row(-101, 0, 0, 0, serial)
    row(-101, 1, 1, 0, serial + 100)   # a second hotseat row with ANOTHER serial: the first one wins
if kind == "populated":
    row(-100, 0, 2, 2, serial)
if kind == "deskonly":
    c.execute("DELETE FROM favorites")
    row(-102, 0, 0, 0, 55)             # a folder row: neither desktop nor hotseat
c.commit()
PY
fixture() { python3 "$W/fixture.py" "$@" || { echo "fixture failed: $*" >&2; exit 2; }; }
q() { python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute(sys.argv[2]).fetchall())' "$1" "$2"; }

run_suite() { # $1=binary
  local T="$1" db out err rc d
  d="$W/case"; rm -rf "$d"; mkdir -p "$d"
  db="$d/launcher.db"

  # ---- seeding -------------------------------------------------------------------------------------------------
  printf '# header\n\n1|0|0|app.one|app.one.Main\n 1|1|0|app.two|app.two.Main\n1|2|3|app.three|app.three.Main\n' > "$d/desc"
  fixture "$db" empty 7
  out="$("$T" "$db" "$d/desc" 2>"$d/err")"; rc=$?
  eq "empty workspace: exit 0" "$rc" 0
  eq "empty workspace: stdout is 'seeded 3'" "$out" "seeded 3"
  eq "empty workspace: stderr is empty" "$(cat "$d/err")" ""
  eq "three rows at container -100" "$(q "$db" 'SELECT count(*) FROM favorites WHERE container=-100')" "[(3,)]"
  eq "rows carry the FIRST hotseat row's profileId" "$(q "$db" 'SELECT DISTINCT profileId FROM favorites WHERE container=-100')" "[(7,)]"
  eq "rows carry the screen/cell and span 1x1, itemType 0, restored 0" \
     "$(q "$db" 'SELECT screen,cellX,cellY,spanX,spanY,itemType,restored FROM favorites WHERE container=-100 ORDER BY _id')" \
     "[(1, 0, 0, 1, 1, 0, 0), (1, 1, 0, 1, 1, 0, 0), (1, 2, 3, 1, 1, 0, 0)]"
  eq "the exact intent string" "$(q "$db" "SELECT intent FROM favorites WHERE cellX=2 AND container=-100")" \
     "[('#Intent;action=android.intent.action.MAIN;category=android.intent.category.LAUNCHER;launchFlags=0x10200000;component=app.three/app.three.Main;end',)]"
  eq "the hotseat rows are untouched" "$(q "$db" 'SELECT count(*) FROM favorites WHERE container=-101')" "[(2,)]"

  fixture "$d/p.db" populated 7
  out="$("$T" "$d/p.db" "$d/desc" 2>"$d/err")"; rc=$?
  eq "populated workspace: exit 0" "$rc" 0
  eq "populated workspace: skip line" "$out" "skip: workspace already has 1 item(s)"
  eq "populated workspace: no rows added" "$(q "$d/p.db" 'SELECT count(*) FROM favorites')" "[(3,)]"

  # ---- the exit-code contract ------------------------------------------------------------------------------------
  fixture "$d/n.db" nohotseat
  "$T" "$d/n.db" "$d/desc" >"$d/out" 2>"$d/err"; rc=$?
  eq "no hotseat: exit 5" "$rc" 5
  eq "no hotseat: no stdout" "$(cat "$d/out")" ""
  fixture "$d/o.db" deskonly
  "$T" "$d/o.db" "$d/desc" >/dev/null 2>&1; rc=$?
  eq "a serial only on a non-hotseat row: exit 5" "$rc" 5
  fixture "$d/m.db" empty 7
  "$T" "$d/m.db" "$d/none" >/dev/null 2>&1; rc=$?
  eq "missing descriptor: exit 4" "$rc" 4
  eq "missing descriptor: nothing written" "$(q "$d/m.db" 'SELECT count(*) FROM favorites WHERE container=-100')" "[(0,)]"
  "$T" "$d/nodir/launcher.db" "$d/desc" >/dev/null 2>&1; rc=$?
  eq "db inside a directory that does not exist: exit 3" "$rc" 3
  "$T" "$d/missing.db" "$d/desc" >/dev/null 2>&1; rc=$?
  eq "missing launcher.db in an existing dir: exit 3" "$rc" 3
  [ ! -e "$d/missing.db" ] && ok "... and no db file was created" \
                           || no "... a stray db file was created for the missing launcher.db"
  "$T" >/dev/null 2>&1; rc=$?
  eq "no arguments: exit 2" "$rc" 2
  "$T" a b c >/dev/null 2>&1; rc=$?
  eq "three arguments: exit 2" "$rc" 2

  # ---- the descriptor parser ---------------------------------------------------------------------------------------
  printf '# only a comment\n||1|p|c\n\n' > "$d/dead"
  fixture "$d/z.db" empty 7
  out="$("$T" "$d/z.db" "$d/dead" 2>"$d/err")"; rc=$?
  eq "no usable line: exit 0" "$rc" 0
  eq "no usable line: empty stdout" "$out" ""
  eq "no usable line: stderr says so, with the malformed count" "$(cat "$d/err")" "seed-home: descriptor yielded no rows (1 malformed)"
  eq "no usable line: nothing committed" "$(q "$d/z.db" 'SELECT count(*) FROM favorites')" "[(2,)]"

  printf '1|0|0|app.good|app.good.Main\n1|bad|0|app.bad|app.bad.Main\n' > "$d/mix"
  fixture "$d/x.db" empty 7
  out="$("$T" "$d/x.db" "$d/mix" 2>"$d/err")"; rc=$?
  eq "one good + one malformed: exit 0" "$rc" 0
  eq "one good + one malformed: stdout 'seeded 1' only" "$out" "seeded 1"
  eq "one good + one malformed: the count is on stderr" "$(cat "$d/err")" "seed-home: 1 malformed line(s) skipped"

  local line
  for line in '||1|p|c' '1||2|p|c' '1|2||p|c' '1|2|3|p|c|x' '1|2|3|p|c|' '1|2|p|c' '-1|0|0|p|c' '1|x|0|p|c'; do
    printf '%s\n' "$line" > "$d/one"
    rm -f "$d/l.db"; fixture "$d/l.db" empty 7
    out="$("$T" "$d/l.db" "$d/one" 2>"$d/err")"; rc=$?
    eq "'$line' is malformed (exit 0, empty stdout)" "$rc/$out" "0/"
    eq "'$line' commits no row" "$(q "$d/l.db" 'SELECT count(*) FROM favorites WHERE container=-100')" "[(0,)]"
    eq "'$line' is counted in stderr" "$(cat "$d/err")" "seed-home: descriptor yielded no rows (1 malformed)"
  done

  # ---- one transaction ---------------------------------------------------------------------------------------------
  printf '1|0|0|app.a|app.a.M\n1|1|0|app.b|app.b.M\n1|9|0|app.c|app.c.M\n1|2|0|app.d|app.d.M\n' > "$d/tx"
  fixture "$d/c.db" check 7
  "$T" "$d/c.db" "$d/tx" >"$d/out" 2>"$d/err"; rc=$?
  eq "a row violating a CHECK mid-file: exit 6" "$rc" 6
  eq "... no stdout" "$(cat "$d/out")" ""
  eq "... ZERO rows committed" "$(q "$d/c.db" 'SELECT count(*) FROM favorites WHERE container=-100')" "[(0,)]"

  # ---- every committed Endospore descriptor ------------------------------------------------------------------------
  local f dev n
  n=0
  for f in "$ROOT"/editions/endospore/devices/*/vendor/etc/default-home; do
    [ -f "$f" ] || continue
    n=$((n+1)); dev="$(basename "$(dirname "$(dirname "$(dirname "$f")")")")"
    rm -f "$d/r.db"; fixture "$d/r.db" empty 7
    out="$("$T" "$d/r.db" "$f" 2>"$d/err")"; rc=$?
    eq "[$dev] default-home exits 0" "$rc" 0
    eq "[$dev] default-home reports no malformed line" "$(cat "$d/err")" ""
    case "$out" in "seeded "[1-9]*) ok "[$dev] default-home seeds rows ($out)" ;; *) no "[$dev] default-home seeded nothing ('$out')" ;; esac
    eq "[$dev] every seeded row is on screen 1 or later" "$(q "$d/r.db" 'SELECT count(*) FROM favorites WHERE container=-100 AND screen<1')" "[(0,)]"
  done
  eq "five committed default-home descriptors found" "$n" 5
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
src, dst, old, new = sys.argv[1:5]
t = open(src).read()
if t.count(old) < 1:
    sys.exit("mutant did not apply: %r" % old)
open(dst, "w").write(t.replace(old, new, 1))
PY
  # ROLLBACK -> COMMIT on rows==0 alone is an EQUIVALENT mutant (no statement ran in the transaction, so both leave
  # the file identical); the regression worth convicting is the path falling through to COMMIT + "seeded 0".
  mutants=(
    "empty-field check removed@@if (!*fields[0] || !*fields[1] || !*fields[2]) { bad++; continue; }@@"
    "sixth field tolerated@@if (n != 5) { bad++; continue; }@@if (n < 5) { bad++; continue; }"
    "rows==0 falls through to COMMIT and 'seeded 0'@@if (rows == 0) {@@if (0) {"
    "serial read from container -100@@WHERE container=-101 LIMIT 1;@@WHERE container=-100 LIMIT 1;"
    "empty-workspace guard removed@@if (ndesk != 0) {@@if (0) {"
    "open reverted to plain sqlite3_open@@sqlite3_open_v2(dbpath, &db, SQLITE_OPEN_READWRITE, NULL)@@sqlite3_open(dbpath, &db)"
    "open flags widened with SQLITE_OPEN_CREATE@@SQLITE_OPEN_READWRITE, NULL)@@SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL)"
    "rollback on a failed insert replaced by commit@@sqlite3_finalize(st);
            sqlite3_exec(db, \"ROLLBACK\", NULL, NULL, NULL);@@sqlite3_finalize(st);
            sqlite3_exec(db, \"COMMIT\", NULL, NULL, NULL);"
  )
  CONVICTED=0; MFAIL=0
  for m in "${mutants[@]}"; do
    name="${m%%@@*}"; rest="${m#*@@}"; old="${rest%%@@*}"; new="${rest#*@@}"
    if ! python3 "$W/mutate.py" "$SRC" "$W/mut.c" "$old" "$new"; then no "mutant '$name' did not apply"; MFAIL=$((MFAIL+1)); continue; fi
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
