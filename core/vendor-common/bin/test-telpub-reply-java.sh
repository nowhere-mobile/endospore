#!/usr/bin/env bash
# test-telpub-reply-java.sh [--mutate] -- GET-TELPUB's reply as the Bind profile form reads it, under javac (NWP-20261120-13).
#
# WHY THIS IS COMMITTED. GET-TELPUB answered nothing when its store read failed in transport, and the Bind form read
# the silence as "no profile matched that name and passphrase". The daemon now answers ERR-NET for that failure, and
# TelPubReply.classify (a pure class, no android.* import) maps it to NET; every other reply maps as the lambda did
# before: OK, NOKEY, and NONE for the rest (blind: NONE, NOSTORE, BLANK, no reply and anything unknown). The class is
# compiled here with its cases. The PINS check that the bind lambda calls classify and shows the store line for NET.
# Pins run first and each failure is printed; the class's absence is reported after them.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-telpub-reply-java.sh            # the cases + pins
#   bash test-telpub-reply-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
COPY="$root/core/chooser/src/com/nowhere/chooser/TelPubReply.java"
ACT="$root/core/chooser/src/com/nowhere/chooser/ChooserActivity.java"
CASES="$root/core/chooser/tests/telpub-reply/TelPubReplyCases.java"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
[ -f "$ACT" ] && [ -f "$CASES" ] || { echo "FAIL: missing $ACT or $CASES" >&2; exit 2; }

JAVAC=""; JAVA=""
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
fi

# suite <TelPubReply.java> <ChooserActivity.java> -> 0 pass, 1 a case or pin failed (the only code that convicts a
# mutant), 2 no javac, 3 the class or the cases did not compile.
suite() {
  local copy="$1" act="$2" d out rc
  local bad=0
  # P1: the bind lambda classifies the GET-TELPUB reply with TelPubReply, and the old inline chain is gone.
  perl -0ne 'exit(/String r = sendDaemon\("GET-TELPUB\\n" \+ name \+ "\\n" \+ pass \+ "\\n"\);\s*final String result;\s*final String kind = TelPubReply\.classify\(r\);[^\n]*\n\s*if \("OK"\.equals\(kind\)\) \{/ ? 0 : 1)' "$act" || {
    echo "  PIN   the bind lambda no longer classifies the GET-TELPUB reply with TelPubReply.classify(r)" >&2; bad=1; }
  perl -0ne 'exit(/else if \("NOKEY"\.equals\(kind\)\) result = "NOKEY";\s*else if \("NET"\.equals\(kind\)\) result = "NET";[^\n]*\n\s*else result = "NONE";/ ? 0 : 1)' "$act" || {
    echo "  PIN   the bind lambda no longer maps NOKEY, NET and the rest (NONE) from the classified reply" >&2; bad=1; }
  if perl -0ne 'exit(/r\.startsWith\("NOKEY"\)/ ? 0 : 1)' "$act"; then
    echo "  PIN   the old inline r.startsWith(\"NOKEY\") chain is back in ChooserActivity.java" >&2; bad=1; fi
  # P2: NET shows the store line.
  perl -0ne 'exit(/else if \("NET"\.equals\(result\)\) StatusLine\.error\(msg, "couldn\x27t reach the store — check the network and try again"\);/ ? 0 : 1)' "$act" || {
    echo "  PIN   the bind lambda no longer shows \"couldn't reach the store\" for NET" >&2; bad=1; }
  # The class itself: missing (origin/main) is a failure reported AFTER the pins, so all failures show.
  [ -f "$copy" ] || { echo "  FAIL  TelPubReply.java does not exist (classify is missing)" >&2; return 1; }
  if grep -q 'android\.' "$copy"; then echo "  FAIL  TelPubReply.java mentions android. -- it must stay java.* only" >&2; bad=1; fi
  [ "$bad" -eq 0 ] || return 1
  if [ -z "$JAVAC" ]; then
    echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip: install a JDK or run it on the build VM." >&2
    return 2
  fi
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$copy" "$d/src/com/nowhere/chooser/TelPubReply.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/TelPubReplyCases.java"
  if ! "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.TelPubReplyCases 2>&1); rc=$?
  echo "$out"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

[ -z "$JAVAC" ] || "$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
echo "== $COPY"
suite "$COPY" "$ACT"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAILED (rc=$rc)"; exit "$rc"; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not compile proves nothing)"
mut() { # mut <label> <copy|act> <perl-expr>
  local md mc ma mrc mtarget; md=$(mktemp -d -p "$W"); mc="$md/TelPubReply.java"; ma="$md/ChooserActivity.java"
  cp "$COPY" "$mc"; cp "$ACT" "$ma"
  mtarget="$mc"; [ "$2" = act ] && mtarget="$ma"
  if ! perl -0pi -e "$3" "$mtarget"; then echo "  ERROR     $1 -- perl failed on the mutation"; return 1; fi
  if cmp -s "$COPY" "$mc" && cmp -s "$ACT" "$ma"; then echo "  INERT     $1 -- the mutation changed nothing"; return 1; fi
  suite "$mc" "$ma" >/dev/null 2>&1; mrc=$?
  case "$mrc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile or run (rc=$mrc)"; return 1 ;;
  esac
}
fails=0
mut "M1 ERR-NET arm removed"          copy 's/\n\s*if \("ERR-NET"\.equals\(reply\.trim\(\)\)\) return "NET";//' || fails=$((fails+1))
mut "M2 NET for null"                 copy 's/if \(reply == null\) return "NONE";/if (reply == null) return "NET";/' || fails=$((fails+1))
mut "M3 NOSTORE mapped to NET"        copy 's/(\n(\s*)if \("ERR-NET"\.equals)/\n$2if (reply.startsWith("NOSTORE")) return "NET";$1/' || fails=$((fails+1))
mut "M4 OK prefix loosened to OK"     copy 's/reply\.startsWith\("OK "\)/reply.startsWith("OK")/' || fails=$((fails+1))
mut "M5 NET loosened to startsWith"   copy 's/"ERR-NET"\.equals\(reply\.trim\(\)\)/reply.startsWith("ERR-NET")/' || fails=$((fails+1))
mut "M6 lambda skips classify"        act  's/TelPubReply\.classify\(r\)/"NONE"/' || fails=$((fails+1))
mut "M7 NET line removed"             act  's/\n\s*else if \("NET"\.equals\(result\)\) StatusLine\.error\(msg, "couldn\x27t reach the store[^\n]*//' || fails=$((fails+1))
mut "M8 NET result dropped to NONE"   act  's/else if \("NET"\.equals\(kind\)\) result = "NET";/else if ("NET".equals(kind)) result = "NONE";/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
