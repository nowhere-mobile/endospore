#!/usr/bin/env bash
# test-ics-export-java.sh [--mutate] -- "Export a copy"'s calendar.ics rules, run under javac (NWP-20261109-03).
#
# WHY THIS IS COMMITTED. buildCalendarICal wrote a recurring event as DTSTART + RRULE with no length (a series stores
# DURATION, not DTEND) and never read EXDATE / ORIGINAL_ID / ORIGINAL_INSTANCE_TIME / DELETED / STATUS, so every week of
# a series was zero-length, a moved occurrence showed twice and a deleted one came back. The rows -> iCalendar rules now
# live in IcsExport.java (pure java.*), which core/chooser/tests/ics-export/run.sh compiles and runs against
# IcsExportCases; the PINS below check the wiring cases cannot see: buildCalendarICal calls IcsExport.build, holds no
# VEVENT literal of its own, and ProfileActivity no longer declares the ical helpers.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (a suite that quietly passes because its tool is missing reads
# exactly like one that ran). javac comes from PATH, else from the build host's JDK below; the version is printed first.
#
#   bash test-ics-export-java.sh            # the cases and the pins
#   bash test-ics-export-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser/ProfileActivity.java"
ICS="$root/core/chooser/src/com/nowhere/chooser/IcsExport.java"
RUN="$root/core/chooser/tests/ics-export/run.sh"
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
command -v perl >/dev/null 2>&1 || { echo "FAIL: this suite needs perl for its mutants" >&2; exit 2; }
[ -f "$SRC" ] && [ -f "$RUN" ] || { echo "FAIL: missing $SRC or $RUN" >&2; exit 2; }

# body <file> <signature-substring> -> the member from its signature line to the brace that closes it
body() {
  awk -v sig="$2" '
    !on && index($0, sig) { on=1; depth=0 }
    on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
  ' "$1"
}

# pins <ProfileActivity.java> -> 0 all hold, 1 one failed
pins() {
  local f="$1" b h
  b=$(body "$f" 'private byte[] buildCalendarICal(')
  [ -n "$b" ] || { echo "  PIN P4 buildCalendarICal was not found" >&2; return 1; }
  [[ "$b" == *'IcsExport.build('* ]] || { echo "  PIN P1 buildCalendarICal does not call IcsExport.build" >&2; return 1; }
  [[ "$b" != *'BEGIN:VEVENT'* ]] || { echo "  PIN P2 buildCalendarICal builds VEVENTs itself again" >&2; return 1; }
  for h in 'static String icalUtc(' 'static String icalDate(' 'static String icalEscape('; do
    [[ "$(cat "$f")" != *"$h"* ]] || { echo "  PIN P3 ProfileActivity declares $h again" >&2; return 1; }
  done
  return 0
}

# suite <ProfileActivity.java> <IcsExport.java> -> 0 pass, 1 a case or a pin failed, 2 the source is missing, 3 it did
# not compile. Only 1 may convict a mutant.
suite() {
  pins "$1" || return 1
  bash "$RUN" "$2" "$W"
}

echo "== $SRC"
suite "$SRC" "$ICS" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED -- by behaviour or a pin: a mutant that does not apply or compile proves nothing)"
# mut <label> <which: ics|activity> <perl-expr>
mut() {
  local d m rc a p src; d=$(mktemp -d -p "$W"); a="$SRC"; p="$ICS"
  if [ "$2" = ics ]; then m="$d/IcsExport.java"; p="$m"; src="$ICS"; else m="$d/ProfileActivity.java"; a="$m"; src="$SRC"; fi
  if ! perl -0pe "$3" "$src" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$src" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  suite "$a" "$p" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not apply or compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "X1 DURATION never written"                      ics      's/if \(r\.duration != null && !r\.duration\.isEmpty\(\)\)/if (false)/' || fails=$((fails+1))
mut "X2 exception map from non-deleted rows only"    ics      's/if \(r\.originalId != null && r\.originalInstanceTime != null\)/if (!r.deleted && r.originalId != null && r.originalInstanceTime != null)/' || fails=$((fails+1))
mut "X3 the status != 2 filter dropped"              ics      's/ \|\| r\.status == STATUS_CANCELED//' || fails=$((fails+1))
mut "X4 the deleted filter dropped"                  ics      's/if \(r\.deleted \|\| /if (/' || fails=$((fails+1))
mut "X5 all-day exception EXDATE in the UTC form"    ics      's/r\.allDay \? "EXDATE;VALUE=DATE:" \+ icalDate\(t\)/r.allDay ? "EXDATE:" + icalUtc(t)/' || fails=$((fails+1))
mut "X6 a recurring row also writes DTEND"           ics      's/!recurring && r\.dtend != null/r.dtend != null/g' || fails=$((fails+1))
mut "X7 own-exdate pattern checks removed"           ics      's/EXDATE_DATES\.matcher\(own\)\.matches\(\)/true/; s/EXDATE_UTC\.matcher\(own\)\.matches\(\)/true/' || fails=$((fails+1))
mut "X8 buildCalendarICal does not call IcsExport"   activity 's/IcsExport\.build\(rows\)/null/' || fails=$((fails+1))
mut "X9 all-day own column written as plain EXDATE:" ics      's/(r\.allDay && EXDATE_DATES[^\n]*\n\s*)ics\.append\("EXDATE;VALUE=DATE:"\)/$1ics.append("EXDATE:")/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
