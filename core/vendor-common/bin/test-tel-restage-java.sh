#!/usr/bin/env bash
# test-tel-restage-java.sh [--mutate] -- TelIngest's re-stage kind filter and line builder, run under javac
# (NWP-20261019-27).
#
# WHY THIS IS COMMITTED. TelIngest.run re-stages a claimed row the session could not insert (docs/backlog.md, "An SMS
# whose insert into the session fails is acknowledged and lost"). Which rows each loop takes (restageBase) and the line
# it hands back (restageLine: the row's fields, retry + 1, the cap) were built by hand in two loops, and nothing off a
# device executed them. A wrong SMS base writes the counter over the body; a wrong MMS base drops its JSON; a retry
# never incremented re-stages on every kick; a flipped cap compare gives one try too many; a kind filter that lets a
# call into the SMS/MMS loop logs the call twice. All of them build and pass every other suite.
# core/chooser/tests/tel-restage/run.sh lifts the two helpers into a plain class and runs RestageCases against them;
# the PINS below check that both loops actually go through them.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (see test-storage-usage-java.sh). javac comes from PATH, else from
# the build host's JDK below. The version is printed first so the log proves which compiler ran.
#
#   bash test-tel-restage-java.sh            # the cases
#   bash test-tel-restage-java.sh --mutate   # ... plus broken copies of the source that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser/TelIngest.java"
RUN="$root/core/chooser/tests/tel-restage/run.sh"
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
command -v perl >/dev/null 2>&1 || { echo "FAIL: this suite needs perl for its source pins, and there is none" >&2; exit 2; }

# suite <TelIngest.java> -> 0 pass, 1 a case failed (behaviour) or a source pin failed (textual: it is how M8 convicts),
# 2 a helper did not extract, 3 the lifted class did not compile. Only 1 may convict a mutant.
suite() {
  local f="$1"
  # PIN 1: the call loop asks restageBase(f, true), builds its line with restageLine(f, 6, ...) and sends THAT line.
  perl -0ne 'exit(/if \(restageBase\(f, true\) >= 0\) \{(?:(?!\n        \}\n).)*?String line = restageLine\(f, 6, MAX_TEL_RETRIES\);(?:(?!\n        \}\n).)*?DaemonSocket\.roundTrip\("RESTAGE-TELINGEST\\n" \+ line \+ "\\n", 5_000\)/s ? 0 : 1)' "$f" || {
    echo "  PIN   the call loop no longer goes through restageBase(f, true) / restageLine(f, 6, MAX_TEL_RETRIES)" >&2; return 1; }
  # PIN 2: the SMS/MMS loop does the same with the base restageBase(f, false) returned.
  perl -0ne 'exit(/int base = restageBase\(f, false\);\n\s*if \(base < 0\) continue;(?:(?!\n        \}\n).)*?String line = restageLine\(f, base, MAX_TEL_RETRIES\);(?:(?!\n        \}\n).)*?DaemonSocket\.roundTrip\("RESTAGE-TELINGEST\\n" \+ line \+ "\\n", 5_000\)/s ? 0 : 1)' "$f" || {
    echo "  PIN   the SMS/MMS loop no longer goes through restageBase(f, false) / restageLine(f, base, MAX_TEL_RETRIES)" >&2; return 1; }
  bash "$RUN" "$f"
}

echo "== $SRC"
suite "$SRC" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED -- a mutant that does not extract or compile proves nothing)"
mut() { # mut <label> <perl-expr>
  local d m rc; d=$(mktemp -d); m="$d/TelIngest.java"
  if ! perl -0pe "$2" "$SRC" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$SRC" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  suite "$m" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not extract or compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "M1 the retry is not incremented"                 's/append\(retry \+ 1\)\.toString/append(retry).toString/' || fails=$((fails+1))
mut "M2 the cap compare is > (one try too many)"       's/if \(retry >= maxRetries\) return null;/if (retry > maxRetries) return null;/' || fails=$((fails+1))
mut "M3 the sms base is 5"                            's/(f\.length > 6 && f\[6\]\.startsWith\("sim:"\) \? 7 : )6;/${1}5;/' || fails=$((fails+1))
mut "M4 the mms base is 2"                            's/(f\.length > 3 && f\[3\]\.startsWith\("sim:"\) \? 4 : )3;/${1}2;/' || fails=$((fails+1))
mut "M5 the call row's f[5] is dropped"               's/for \(int k = 1; k < base; k\+\+\)/for (int k = 1; k < base - 1; k++)/' || fails=$((fails+1))
mut "M6 the SMS/MMS loop accepts a call row"          's/if \("sms"\.equals\(f\[0\]\) && f\.length >= 6\)/if (("sms".equals(f[0]) || "call".equals(f[0])) \&\& f.length >= 6)/' || fails=$((fails+1))
mut "M7 an unparseable retry counts as max"           's/(retry = Integer\.parseInt\(f\[base\]\);) \} catch \(Throwable ignore\) \{\}/$1 } catch (Throwable ignore) { retry = maxRetries; }/' || fails=$((fails+1))
mut "M9 the sms SIM slot is not counted in the base"   's/return f\.length > 6 && f\[6\]\.startsWith\("sim:"\) \? 7 : 6;/return 6;/' || fails=$((fails+1))
mut "M10 the mms SIM slot is not counted in the base"  's/return f\.length > 3 && f\[3\]\.startsWith\("sim:"\) \? 4 : 3;/return 3;/' || fails=$((fails+1))
mut "M8 the SMS/MMS loop bypasses restageLine"        's/String line = restageLine\(f, base, MAX_TEL_RETRIES\);/String line = String.join(" ", f);/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
