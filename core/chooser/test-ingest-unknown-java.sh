#!/usr/bin/env bash
# test-ingest-unknown-java.sh [<Ingest.java>] [--mutate] -- Ingest's dedup read-backs, run under javac (NWP-20261112-16).
#
# WHY THIS IS COMMITTED. Ingest.run() decides per entry whether to insert from a read-back of the provider, three times:
# pass 1, the two re-verify passes that exist because the provider churns during the sign-in bring-up, and the
# finalize count. The read-backs answered a FAILED query as "not there": rawContactId gave -1 for a null cursor and for
# any Throwable, eventExists false, and ensureLocalCalendar logged the failed query and then created a new "Imported"
# calendar. So a contacts provider restarting during a re-verify pass got every contact inserted a second time, and a
# failed Calendars query at the next sign-in made a second calendar and inserted every event of an unsettled file again.
# The rule now: a lookup that did not complete is UNKNOWN (null); only a completed lookup answers present or absent,
# only "absent" inserts, and a file with an unknown entry stays unfinished and is retried.
#
# core/chooser/tests/ingest-unknown/run.sh lifts LOOKUP_FAILED, the STEP_* constants, ingestStep, contactPresence,
# eitherPresent, rawContactId, eventExists and ensureLocalCalendar by signature, compiles them against stubs of the
# Android classes they touch, and runs IngestUnknownCases: the step and presence tables, each read-back against a
# resolver that throws, gives no cursor, gives an empty one or a row, and source checks on run()'s three call sites,
# which cannot be lifted on their own. On a tree without these members the extraction fails and so does this suite.
#
# NWP-20261123-17: the attempt cap (MAX_TRIES) counts only runs that could see the provider. run() counts each file's
# read-backs that did not complete (StagedFile.unknownReads); ensureLocalCalendar answers LOOKUP_FAILED for a query that
# did not complete and -1 for a failed create, and parseIcsInto counts only LOOKUP_FAILED as unknown. countsAsAttempt
# decides whether an incomplete file spends a try, so a provider that never answered cannot settle a file that was never
# imported. The suite lifts countsAsAttempt too; source checks S9-S12 pin the call sites and mutants M12-M17 break them.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (exit 2), like the other javac suites.
#
#   bash test-ingest-unknown-java.sh            # the cases
#   bash test-ingest-unknown-java.sh --mutate   # ... plus broken copies that must each FAIL the cases
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/src/com/nowhere/chooser/Ingest.java"
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SRC="$a" ;; esac; done
RUN="$HERE/tests/ingest-unknown/run.sh"
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
export JAVAC JAVA
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
[ -f "$SRC" ] && [ -f "$RUN" ] || { echo "FAIL: missing $SRC or $RUN" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: run.sh extracts with python3, and there is none" >&2; exit 2; }

# The one temp root: run.sh and every mutant live inside it, and the EXIT trap removes it on every path.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export W

# suite <Ingest.java> -> run.sh's code: 0 pass, 1 a case failed (only this may convict a mutant), 2 a member did not
# extract, 3 the lifted class did not compile.
suite() { bash "$RUN" "$1"; }

echo "== $SRC"
suite "$SRC"; rc=$?
if [ "$rc" -ne 0 ]; then echo "FAILED (rc=$rc)"; [ "$rc" -eq 1 ] && exit 1 || exit 2; fi
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED; one that does not apply or compile is a failure)"
mut() { # mut <label> <perl-expr>: the expression must match exactly once and change exactly one line
  local d m rc changed; d=$(mktemp -d -p "$W"); m="$d/Ingest.java"
  if ! perl -0pe "$2" "$SRC" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$SRC" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  changed=$(diff "$SRC" "$m" | grep -c '^>')
  if [ "$changed" -ne 1 ]; then
    echo "  ERROR     $1 -- the mutation changed $changed line(s), expected 1"; rm -rf "$d"; return 1; fi
  suite "$m" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not extract or compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "M1 ingestStep maps null to INSERT" \
  's/if \(present == null\) return STEP_WAIT;/if (present == null) return STEP_INSERT;/' || fails=$((fails+1))
mut "M2 a failed rawContactId returns -1 again" \
  's/(catch \(Throwable t\) \{\n\s+)return LOOKUP_FAILED;/${1}return -1;/' || fails=$((fails+1))
mut "M3 the re-verify pass inserts on null" \
  's/if \(step == STEP_WAIT\) \{ unknown\+\+; sf\.unknownReads\+\+; \}/if (step == STEP_WAIT) e.insert(ctx);/' || fails=$((fails+1))
mut "M4 finalize counts null as present" \
  's/if \(Boolean\.TRUE\.equals\(p\)\) present\+\+;/if (!Boolean.FALSE.equals(p)) present++;/' || fails=$((fails+1))
mut "M5 ensureLocalCalendar falls through to the insert after a failed query" \
  's/(calendar query -- not creating one", t\);\n\s+)return LOOKUP_FAILED;/${1};/' || fails=$((fails+1))
mut "M6 the two-key combination answers FALSE for FALSE/null" \
  's/if \(Boolean\.FALSE\.equals\(a\) && Boolean\.FALSE\.equals\(b\)\)/if (Boolean.FALSE.equals(a) || Boolean.FALSE.equals(b))/' \
  || fails=$((fails+1))
mut "M7 a failed eventExists answers false again" \
  's/(return c\.moveToFirst\(\);\n\s+\} catch \(Throwable t\) \{\n\s+)return null;/${1}return false;/' || fails=$((fails+1))
mut "M8 a null cursor in rawContactId reads as no row" \
  's/if \(c == null\) return LOOKUP_FAILED;/if (c == null) return -1;/' || fails=$((fails+1))
mut "M9 ensureLocalCalendar's null-cursor guard no longer returns" \
  's/(gave no cursor -- not creating one"\);\n\s+)return LOOKUP_FAILED;/${1};/' || fails=$((fails+1))
mut "M10 pass 1 merges on an unknown" \
  's/else \{ unknown\+\+; sf\.unknownReads\+\+; \}/else e.merge(ctx);/' || fails=$((fails+1))
mut "M11 a null cursor in eventExists reads as absent" \
  's/if \(c == null\) return null;/if (c == null) return false;/' || fails=$((fails+1))
mut "M12 countsAsAttempt ignores the unknown read-backs" \
  's/return !complete && unknownReads == 0;/return !complete;/' || fails=$((fails+1))
mut "M13 finalize spends a try unconditionally" \
  's/if \(countsAsAttempt\(false, sf\.unknownReads\)\) \{/if (true) {/' || fails=$((fails+1))
mut "M14 parseIcsInto no longer counts a calendar lookup that did not answer" \
  's/if \(calId == LOOKUP_FAILED\) sf\.unknownReads\+\+;//' || fails=$((fails+1))
mut "M15 parseIcsInto counts a failed create as unknown too" \
  's/if \(calId == LOOKUP_FAILED\) sf\.unknownReads\+\+;/sf.unknownReads++;/' || fails=$((fails+1))
mut "M16 finalize's unknown read-back no longer counts against its file" \
  's/(else if \(p == null\) \{ unknown\+\+; )sf\.unknownReads\+\+; /$1/' || fails=$((fails+1))
mut "M17 a failed calendar create returns LOOKUP_FAILED" \
  's/return u == null \? -1 : /return u == null ? LOOKUP_FAILED : /' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
