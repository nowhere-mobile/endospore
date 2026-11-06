#!/usr/bin/env bash
# test-snapshot-copy-java.sh [--mutate] -- Delete and Restore in "Restore a snapshot": their copy under javac, their
# wiring pinned in ProfileActivity, and handleRollback's reply codes pinned against the copy (NWP-20261027-07,
# NWP-20261116-22).
#
# WHY THIS IS COMMITTED. docs/product-decisions.md 2026-10-19: a user deletes one retained version, never the current
# state, there is no "delete all", the list is redrawn from the daemon, and the screen must not promise a size it cannot
# free. SnapshotCopy.java decides the confirmation and the toast per DELETE-SNAPSHOT reply and is pure Java, so
# tests/snapshot-copy/run.sh compiles it directly; the PINS check the call sites in ProfileActivity: the request is
# built only in doDeleteSnapshot, the list is refreshed on EVERY reply (a refresh behind an OK would leave a stale row
# after NOSNAP), the dialog text comes from SnapshotCopy, and no "delete all" exists.
#
# NWP-20261116-22: doRollback renders every ROLLBACK reply through SnapshotCopy.rolledBack / rollbackReply and holds no
# reply literal of its own. A lost reply ("") to ROLLBACK or DELETE-SNAPSHOT says the change may have landed: the daemon
# can roll the head and queue the unsaved reap after the reply is lost. The code pin reads every reply handleRollback
# (core/agent/main.go) writes to conn, requires exactly the known set, and the cases require each code but ERR to get
# a text other than the default line, so a new reply code fails here until SnapshotCopy renders it.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (exit 2). javac comes from PATH, else the build host's JDK.
#
#   bash test-snapshot-copy-java.sh            # the cases and the pins
#   bash test-snapshot-copy-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

here=$(cd "$(dirname "$0")" && pwd)
DIR="$here/src/com/nowhere/chooser"
SC="$DIR/SnapshotCopy.java"
PA="$DIR/ProfileActivity.java"
MAIN="$here/../agent/main.go"
RUN="$here/tests/snapshot-copy/run.sh"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

# one root for everything this suite makes; run.sh's own mktemp lands in it through TMPDIR
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W"

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip: install a JDK or run it on the" \
       "build VM." >&2
  exit 2
fi
export JAVAC JAVA
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
[ -f "$PA" ] && [ -f "$RUN" ] && [ -f "$MAIN" ] || { echo "FAIL: missing $PA, $MAIN or $RUN" >&2; exit 2; }

# pin <file> <label> <perl-regex>: a textual check on the call sites (anchors, not line numbers).
pin() {
  perl -0ne "exit(/$3/s ? 0 : 1)" "$1" || { echo "  PIN   $2" >&2; return 1; }
}

# body <file> <method signature prefix>: the method's text, signature line to its closing brace.
body() {
  awk -v m="$2" '
    !on && index($0, m) { on=1; depth=0 }
    on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
  ' "$1"
}

# rollback_codes <main.go>: the codes handleRollback writes to conn, sorted, one line. Comments are dropped first (the
# body's string literals hold no "//"). Every line of the body that names conn must be one of the two known write forms;
# any other line prints "BAD <line>" so the caller fails.
rollback_codes() {
  awk '/^func handleRollback\(conn /{on=1; next} on && /^}/{exit} on{print}' "$1" \
    | sed 's#[[:space:]]*//.*$##' \
    | perl -ne '
        next unless /\bconn\b/;
        if (/^\s*fmt\.Fprint\(conn, "([A-Z][A-Z-]*)\\n"\)\s*$/) { $c{$1}=1; next }
        if (/^\s*fmt\.Fprintf\(conn, "OK %d\\n", nv\)\s*$/) { $c{OK}=1; next }
        chomp; print "BAD $_\n"; $bad=1;
        END { print join(" ", sort keys %c), "\n" unless $bad }'
}

# suite <SnapshotCopy.java> <ProfileActivity.java> <main.go> -> 0 pass, 1 a case or a pin failed, 3 compile.
suite() {
  local sc="$1" pa="$2" go="$3" db cdb rb n codes
  [ -f "$sc" ] || { echo "  PIN   SnapshotCopy.java does not exist" >&2; return 1; }
  n=$(grep -c 'DELETE-SNAPSHOT\\n' "$pa")
  [ "$n" -eq 1 ] || { echo "  PIN   (a) DELETE-SNAPSHOT is built $n times, want once" >&2; return 1; }
  db=$(body "$pa" 'private void doDeleteSnapshot(')
  case "$db" in *'DELETE-SNAPSHOT\n'*) ;; *) echo "  PIN   (a) the request is not built in doDeleteSnapshot" >&2; return 1 ;; esac
  case "$db" in *'startsWith("OK")'*) echo "  PIN   (b) doDeleteSnapshot branches on OK" >&2; return 1 ;; esac
  printf '%s\n' "$db" | perl -0ne 'exit(/runOnUiThread\(\(\) -> \{\s*android\.widget\.Toast\.makeText\(this, SnapshotCopy\.deleteReply\(r\)[^\n]*\n\s*showSnapshots\(\);/ ? 0 : 1)' \
    || { echo "  PIN   (b) doDeleteSnapshot does not refresh the list after the toast on every reply" >&2; return 1; }
  cdb=$(body "$pa" 'private void confirmDeleteSnapshot(')
  case "$cdb" in *'setTitle(SnapshotCopy.confirmTitle())'*) ;; *) echo "  PIN   (c) title not from SnapshotCopy" >&2; return 1 ;; esac
  case "$cdb" in *'setMessage(SnapshotCopy.confirmMessage(label))'*) ;; *) echo "  PIN   (c) message not from SnapshotCopy" >&2; return 1 ;; esac
  case "$cdb" in *'doDeleteSnapshot(version)'*) ;; *) echo "  PIN   (c) Delete does not call doDeleteSnapshot" >&2; return 1 ;; esac
  pin "$pa" "(c) the Restore a snapshot rows do not wire confirmDeleteSnapshot(ver, when)" \
    'private void showSnapshots\(\).*?confirmDeleteSnapshot\(ver, when\).*?private static String snapDate' || return 1
  n=$(grep -ci 'delete all' "$pa")
  [ "$n" -eq 0 ] || { echo "  PIN   (d) 'delete all' appears $n time(s)" >&2; return 1; }
  rb=$(body "$pa" 'private void doRollback(')
  case "$rb" in *'ROLLBACK\n'*) ;; *) echo "  PIN   (e) doRollback not found, or it no longer sends ROLLBACK" >&2; return 1 ;; esac
  n=$(grep -o 'SnapshotCopy\.rolledBack(r)' <<<"$rb" | wc -l)
  [ "$n" -eq 2 ] || { echo "  PIN   (e) doRollback calls SnapshotCopy.rolledBack(r) $n times, want 2" >&2; return 1; }
  n=$(grep -o 'SnapshotCopy\.rollbackReply(r)' <<<"$rb" | wc -l)
  [ "$n" -eq 1 ] || { echo "  PIN   (e) doRollback calls SnapshotCopy.rollbackReply(r) $n times, want 1" >&2; return 1; }
  n=$(grep -o -e '"LOCAL"' -e '"BUSY"' -e '"NOSNAP"' -e 'startsWith("OK")' <<<"$rb" | wc -l)
  [ "$n" -eq 0 ] || { echo "  PIN   (e) doRollback holds $n reply literal(s) of its own" >&2; return 1; }
  codes=$(rollback_codes "$go")
  [ -n "$codes" ] || { echo "  PIN   (f) handleRollback not found in $go, or it writes no reply" >&2; return 1; }
  case "$codes" in *BAD*) printf '  PIN   (f) an unrecognised write to conn in handleRollback:\n%s\n' "$codes" >&2; return 1 ;; esac
  [ "$codes" = "BUSY ERR LOCAL NONE NOSNAP OK" ] \
    || { echo "  PIN   (f) handleRollback writes {$codes}, want {BUSY ERR LOCAL NONE NOSNAP OK}" >&2; return 1; }
  SNAPSHOT_ROLLBACK_CODES="$codes" bash "$RUN" "$sc"
}

echo "== $SC"
suite "$SC" "$PA" "$MAIN"; rc=$?
if [ "$rc" -ne 0 ]; then echo "FAILED (rc=$rc)"; [ "$rc" -eq 1 ] && exit 1 || exit 2; fi
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED; one that does not apply or compile is a failure)"
mut() { # mut <label> <sc|pa|go> <perl-expr>
  local d src m rc; d=$(mktemp -d -p "$W")
  case "$2" in
    sc) src="$SC"; m="$d/SnapshotCopy.java" ;;
    pa) src="$PA"; m="$d/ProfileActivity.java" ;;
    go) src="$MAIN"; m="$d/main.go" ;;
    *) echo "  ERROR     $1 -- unknown kind $2"; rm -rf "$d"; return 1 ;;
  esac
  if ! perl -0pe "$3" "$src" > "$m"; then echo "  ERROR     $1 -- perl failed"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$src" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  case "$2" in
    sc) suite "$m" "$PA" "$MAIN" >/dev/null 2>&1; rc=$? ;;
    pa) suite "$SC" "$m" "$MAIN" >/dev/null 2>&1; rc=$? ;;
    go) suite "$SC" "$PA" "$m" >/dev/null 2>&1; rc=$? ;;
  esac
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "D1 ERR read as OK" sc 's/first\.equals\("OK"\)/first.equals("OK") || first.equals("ERR")/' || fails=$((fails+1))
mut "D2 NOSNAP read as a connection error" sc 's/        if \(first\.equals\("NOSNAP"\)\)[^\n]*\n//' || fails=$((fails+1))
mut "D3 the message drops \"can't be undone\"" sc 's/This can.t be undone, and you/You/' || fails=$((fails+1))
mut "D4 the list is refreshed only on OK" pa 's/(SnapshotCopy\.deleteReply\(r\)[^\n]*\n\s*)showSnapshots\(\);/$1if (r.startsWith("OK")) showSnapshots();/' || fails=$((fails+1))
mut "D5 a size phrase in the message" sc 's/not affected\."/not affected. This frees up to 2 GB."/' || fails=$((fails+1))
mut "R1 a lost ROLLBACK reply read as a connection failure" sc 's/"The phone didn.t answer, so the restore may or may not have happened\.[^;]*;/"Couldn'"'"'t restore — check your connection and try again.";/' || fails=$((fails+1))
mut "R2 NONE falls to the restore default" sc 's/(static String rollbackReply\([^}]*?)\n[^\n]*first\.equals\("NONE"\)[^\n]*/$1/' || fails=$((fails+1))
mut "R3 rolledBack by startsWith(\"OK\")" sc 's/(static boolean rolledBack\(String r\) \{\n\s*return )[^\n]*/$1r != null && r.trim().startsWith("OK");/' || fails=$((fails+1))
mut "R4 doRollback renders a reply literal again" pa 's/SnapshotCopy\.rollbackReply\(r\)/(r.startsWith("BUSY") ? "A save is running — try again in a moment." : SnapshotCopy.rollbackReply(r))/' || fails=$((fails+1))
mut "R5 handleRollback writes a new reply code" go 's/(func handleRollback\(conn [^\n]*\n)/$1\tif verStr == "x" {\n\t\tfmt.Fprint(conn, "ERR-NEW\\n")\n\t\treturn\n\t}\n/' || fails=$((fails+1))
mut "R6 a lost DELETE-SNAPSHOT reply read as a connection failure" sc 's/"The phone didn.t answer, so the delete may or may not have happened\.[^;]*;/"Couldn'"'"'t delete it — check your connection and try again.";/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
