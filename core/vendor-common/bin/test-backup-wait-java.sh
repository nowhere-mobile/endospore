#!/usr/bin/env bash
# test-backup-wait-java.sh [--mutate] -- Back up now shows DRAFT words while a re-key batch runs (NWP-20261206-20).
#
# WHY THIS IS COMMITTED. During a background re-key batch the daemon answers BACKUP with "OK" and a second line
# "WAIT rekey-batch" (F10a, NOWHERE-1891). The chooser used to read one line, so the user saw "Backing up…" with no
# reason while the save waited for the batch (docs/backlog.md, "Back up now during a background re-key waits for the
# batch already running; it answers BUSY only while a user op is queued behind that batch"). BackupWait.java decides
# the words and is pure Java, so this suite compiles it and runs core/chooser/tests/backup-wait/BackupWaitCases.java.
# The PINS check, on ProfileActivity.java with comments stripped, that:
#   P1 the one-arg sendDaemonReply only delegates to the two-arg form (one copy of the error handling);
#   P2 the two-arg form reads a second line only when the caller asks AND line 1 trimmed is exactly "OK", inside its
#      own catch of IOException (a slow or failed second read never turns an answered OK into timedOut/unreachable);
#   P3 doBackup sends BACKUP through the two-arg form and, right after the OK-or-joined line, shows
#      BackupWait.text(wait[0]) on the UI thread, never for a joined reply.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (see test-reply-copy-java.sh). javac comes from PATH, else from
# the build host's JDK; the version is printed first so the log proves which compiler ran.
#
#   bash test-backup-wait-java.sh            # the cases and the pins
#   bash test-backup-wait-java.sh --mutate   # ... plus broken copies that must each FAIL on the named assertion
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
# One temp root: every compile dir and mutant dir is made inside it and goes with it on exit.
W=$(mktemp -d) || exit 2
export TMPDIR="$W"
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
DIR="$root/core/chooser/src/com/nowhere/chooser"
BW="$DIR/BackupWait.java"
PA="$DIR/ProfileActivity.java"
CASES="$root/core/chooser/tests/backup-wait/BackupWaitCases.java"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip: install a JDK or run it on the" \
       "build VM." >&2
  exit 2
fi
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "FAIL: this suite needs perl, and there is none" >&2; exit 2; }
[ -f "$PA" ] && [ -f "$CASES" ] || { echo "FAIL: missing $PA or $CASES" >&2; exit 2; }

# strip <file>: the file with /* */ and // comments removed. The (^|[ \t]) lead keeps "https://" inside strings.
strip() {
  perl -0pe 's{/\*.*?\*/}{}gs; s{(^|[ \t])//[^\n]*}{$1}gm' "$1"
}

# pin <file> <label> <perl-regex>: a textual check on the call sites (anchors, not line numbers).
pin() {
  perl -0ne "exit(/$3/s ? 0 : 1)" "$1" || { echo "  PIN   $2" >&2; return 1; }
}

# cases <BackupWait.java> -> 0 pass, 1 a case failed, 3 compile error.
cases() {
  local d; d=$(mktemp -d -p "$W")
  mkdir -p "$d/src/com/nowhere/chooser" "$d/out"
  cp "$1" "$d/src/com/nowhere/chooser/BackupWait.java"
  sed '1i package com.nowhere.chooser;' "$CASES" > "$d/src/com/nowhere/chooser/BackupWaitCases.java"
  "$JAVAC" -encoding UTF-8 -d "$d/out" "$d/src/com/nowhere/chooser/BackupWait.java" \
    "$d/src/com/nowhere/chooser/BackupWaitCases.java" || return 3
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d/out" com.nowhere.chooser.BackupWaitCases || return 1
}

# suite <BackupWait.java> <ProfileActivity.java> -> 0 pass, 1 a case or a pin failed, 3 compile error.
suite() {
  local bw="$1" pa="$2" s body n
  [ -f "$bw" ] || { echo "  PIN   BackupWait.java does not exist" >&2; return 1; }
  s=$(mktemp -p "$W"); strip "$pa" > "$s"
  pin "$s" "P1 the one-arg sendDaemonReply does not only delegate to the two-arg form" \
    'private DaemonReply sendDaemonReply\(String msg\) \{\s*return sendDaemonReply\(msg, null\);\s*\}' || return 1
  body=$(mktemp -p "$W")
  perl -0ne 'print $1 if /(private DaemonReply sendDaemonReply\(String msg, String\[\] second\) \{.*?\n    \}\n)/s' "$s" > "$body"
  [ -s "$body" ] || { echo "  PIN   P2 there is no two-arg sendDaemonReply(String msg, String[] second)" >&2; return 1; }
  pin "$body" "P2 the second line is not read only after an exact OK, inside its own catch of IOException" \
    'if \(second != null && line != null && line\.trim\(\)\.equals\("OK"\)\) \{\s*try \{\s*second\[0\] = br\.readLine\(\);\s*\} catch \(java\.io\.IOException \w+\) \{\s*\}\s*\}' || return 1
  n=$(grep -o 'readLine()' "$body" | wc -l)
  [ "$n" -eq 2 ] || { echo "  PIN   P2 the two-arg sendDaemonReply reads $n lines, want 2 (one unguarded)" >&2; return 1; }
  body=$(mktemp -p "$W")
  perl -0ne 'print $1 if /(private void doBackup\(\) \{.*?\n    \}\n)/s' "$s" > "$body"
  [ -s "$body" ] || { echo "  PIN   P3 there is no doBackup()" >&2; return 1; }
  pin "$body" "P3 doBackup does not send BACKUP through sendDaemonReply(\"BACKUP\\\\n\", wait)" \
    'final String\[\] wait = new String\[1\];\s*final DaemonReply br = sendDaemonReply\("BACKUP\\n", wait\);' || return 1
  pin "$body" "P3 doBackup does not show BackupWait.text(wait[0]) on the UI thread after the OK-or-joined line, never when joined" \
    'if \(r\.startsWith\("OK"\) \|\| joined\) \{\s*final String waitText = joined \? null : BackupWait\.text\(wait\[0\]\);\s*if \(waitText != null\) runOnUiThread\(\(\) -> st\.setText\(waitText\)\);' || return 1
  cases "$bw"
}

echo "== $BW"
suite "$BW" "$PA" || { echo "FAILED"; exit 1; }
echo "PASS: BackupWait cases and pins P1-P3"
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED by its named assertion -- a mutant that does not apply or compile proves nothing)"
# mut <label> <which: bw|pa> <convicting assertion, a substring of the suite's output> <perl-expr>
mut() {
  local d src bwf paf m rc out; d=$(mktemp -d -p "$W")
  bwf="$BW"; paf="$PA"
  case "$2" in bw) src="$BW" ;; pa) src="$PA" ;; esac
  m="$d/$(basename "$src")"
  if ! perl -0pe "$4" "$src" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; return 1; fi
  if cmp -s "$src" "$m"; then echo "  INERT     $1 -- the mutation changed nothing (DID NOT APPLY)"; return 1; fi
  [ "$2" = bw ] && bwf="$m"; [ "$2" = pa ] && paf="$m"
  suite "$bwf" "$paf" >"$d/out" 2>&1; rc=$?
  out=$(cat "$d/out")
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) case "$out" in
         *"$3"*) echo "  convicted $1 -- by: $3"; return 0 ;;
         *) echo "  WRONG     $1 -- failed, but not on: $3"; printf '%s\n' "$out" | grep -E 'PIN|FAIL' | sed 's/^/            /'
            return 1 ;;
       esac ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "B1 text ignores the line"                  bw '--- FAIL text(null) is null' \
  's/(static String text\(String line\) \{).*?\n    \}/$1\n        return REKEY_BATCH;\n    }/s' || fails=$((fails+1))
mut "B2 equals becomes startsWith"              bw '--- FAIL text("WAIT rekey-batchx") is null' \
  's/line\.trim\(\)\.equals\("WAIT rekey-batch"\)/line.trim().startsWith("WAIT rekey-batch")/' || fails=$((fails+1))
mut "B3 REKEY_BATCH loses its Backing up lead"  bw '--- FAIL REKEY_BATCH starts with' \
  's/"Backing up\x{e2}\x{80}\x{a6} your save starts/"Your save starts/' || fails=$((fails+1))
mut "B4 the OK check dropped from the second read" pa 'PIN   P2 the second line is not read only after an exact OK' \
  's/ && line != null && line\.trim\(\)\.equals\("OK"\)\) \{\n(\s*)try \{ second/) {\n$1try { second/' || fails=$((fails+1))
mut "B5 the second read loses its own catch"    pa 'PIN   P2 the second line is not read only after an exact OK' \
  's/try \{ second\[0\] = br\.readLine\(\); \} catch \(java\.io\.IOException \w+\) \{\}/second[0] = br.readLine();/' || fails=$((fails+1))
mut "B6 doBackup no longer asks BackupWait"     pa 'PIN   P3 doBackup does not show BackupWait.text' \
  's/\n[^\n]*final String waitText = joined[^\n]*\n[^\n]*if \(waitText != null\)[^\n]*//' || fails=$((fails+1))
mut "B7 the joined guard is removed"            pa 'PIN   P3 doBackup does not show BackupWait.text' \
  's/joined \? null : BackupWait\.text/BackupWait.text/' || fails=$((fails+1))
if [ "$fails" -ne 0 ]; then echo "FAIL: $fails mutant(s) not convicted"; exit 1; fi
echo "PASS: 7 mutants convicted"
