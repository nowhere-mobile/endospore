#!/usr/bin/env bash
# test-telingest-sub-java.sh [--mutate] -- each delivered SMS and MMS is filed under its SIM's subscription, and its
# sealed copy goes only once the session has read it back, under javac (NWP-20261130-01).
#
# WHY THIS IS COMMITTED. GrapheneOS 2026110200 shows a sub_id=-1 row only to user 0, so TelIngest's inserts succeed and a
# session's Messages shows nothing (docs/backlog.md, "On GrapheneOS 2026110200 a session's Messages shows none of the
# SMS and MMS the gate delivered into it"). The decision is two small rules that nothing off a device would catch being
# dropped: the row carries its SIM's subscription, and a row that does not read back is not acknowledged. TelSub holds
# the rules and runs here for real, against TelSubCases; the PINS below check that TelIngest goes through them.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (see test-storage-usage-java.sh). javac comes from PATH, else from
# the build host's JDK below. The version is printed first so the log proves which compiler ran.
#
#   bash test-telingest-sub-java.sh            # the cases and the pins
#   bash test-telingest-sub-java.sh --mutate   # ... plus broken copies of the source that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
TI="$root/core/chooser/src/com/nowhere/chooser/TelIngest.java"
TS="$root/core/chooser/src/com/nowhere/chooser/TelSub.java"
CASES="$root/core/chooser/tests/tel-sub"
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
command -v perl >/dev/null 2>&1 || { echo "FAIL: this suite needs perl for its source pins, and there is none" >&2; exit 2; }
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
[ -f "$TI" ] && [ -f "$TS" ] && [ -f "$CASES/TelSubCases.java" ] || { echo "FAIL: missing a source or the cases" >&2; exit 2; }
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

# code <file>: the file with its comments stripped, so a pin never reads a comment or a superseded sentence.
code() { perl -0pe 's{/\*.*?\*/}{}gs; s{(?<!:)//[^\n]*}{}g' "$1"; }
# method <code> <signature fragment>: one method of stripped code, from its signature to the line closing it.
method() { awk -v sig="$2" 'index($0, sig) { on = 1 } on { print } on && /^    }[ ]*$/ { exit }' <<<"$1"; }
# pin <what> <text> <perl regex>: the regex must match the text.
pin() {
  if ! perl -0e 'my $re = shift; my $t = do { local $/; <STDIN> }; exit($t =~ /$re/s ? 0 : 1)' "$3" <<<"$2"; then
    echo "  PIN   $1" >&2; return 1
  fi
}
# unpin <what> <text> <perl regex>: the regex must not match the text.
unpin() {
  if perl -0e 'my $re = shift; my $t = do { local $/; <STDIN> }; exit($t =~ /$re/s ? 0 : 1)' "$3" <<<"$2"; then
    echo "  PIN   $1" >&2; return 1
  fi
}

# pins <TelIngest.java> -> 0 or 1.
pins() {
  local c d m r a b
  c=$(code "$1")
  d=$(method "$c" 'private static boolean deliver(')
  m=$(method "$c" 'private static boolean deliverMms(')
  r=$(method "$c" 'static void run(Context ctx, boolean live)')
  a=$(method "$c" 'private static void ackLanded(')
  b=$(method "$c" 'private static void readBackRows(')
  unpin "TelIngest writes sub_id itself -- every row must go through TelSub.file" "$c" 'put\("sub_id"' || return 1
  pin "deliver files an SMS through TelSub.file" "$d" 'sub = TelSub\.file\(v, TelSub\.rowTag\(f\), sims\);.*insert\(uri, v\)' || return 1
  pin "deliverMms files an MMS through TelSub.file" "$m" 'int sub = TelSub\.file\(pdu, TelSub\.rowTag\(f\), sims\);.*insert\(Uri\.parse\("content://mms"\), pdu\)' || return 1
  pin "deliver counts a row the provider took" "$d" 'if \(ins != null && !isCall\) tally\.inserted\(sub\);' || return 1
  pin "deliverMms counts a row the provider took" "$m" 'if \(mmsUri == null\) return false;\s*(?:seen\.inserted\("mms", when\);\s*)?tally\.inserted\(sub\);' || return 1
  pin "an SMS lookup goes through TelSub.lookup before the insert" "$d" 'Boolean found = exists\(ctx, uri, when\);\s*int step = rowStep\(isCall \? found : TelSub\.lookup\(canReadMessages\(ctx\), found\)\);\s*if \(step == DONE\) return true;.*insert\(uri, v\)' || return 1
  pin "an MMS lookup goes through TelSub.lookup before the insert" "$m" 'int step = rowStep\(TelSub\.lookup\(canReadMessages\(ctx\), mmsExists\(ctx, when\)\)\);\s*if \(step == DONE\) return true;.*insert\(Uri\.parse\("content://mms"\), pdu\)' || return 1
  pin "the read-back asks both providers through TelSub.lookup" "$b" 'TelSub\.lookup\(canRead, mms \? mmsExists\(ctx, when\)\s*: exists\(ctx, android\.provider\.Telephony\.Sms\.Inbox\.CONTENT_URI, when\)\);\s*readOk\[i\] = readBack\(present, unknown\);' || return 1
  pin "ackLanded asks TelSub.ackable" "$a" 'if \(f\.length < 2 \|\| !TelSub\.ackable\(f\[0\], everOk\[i\], readOk\[i\]\)\) continue;.*keys\.append\(f\[0\]\)' || return 1
  pin "each pass delivers, reads back, then acknowledges" "$r" 'deliver\(ctx, reply\.get\(i\), insertedThisRun, notified, unknown, sims, tally, seen\).*?readBackRows\(ctx, reply, everOk, readOk, unknown\);\s*ackLanded\(ctx, reply, everOk, readOk, acked, false, unknown\);' || return 1
  pin "the run's final acknowledgement takes readOk" "$r" 'ackLanded\(ctx, reply, everOk, readOk, acked, true, unknown\);' || return 1
  unpin "readOk is set anywhere but readBackRows" "$(perl -0pe 's/\QreadOk[i] = readBack(present, unknown);\E//' <<<"$c")" 'readOk\[[^\]]*\]\s*=[^=]' || return 1
  pin "the batch logs its one line, built only by the tally" "$r" 'Log\.i\("NowhereChooser", tally\.line\(live, TelSub\.notReadBack\(reply, everOk, readOk\)\)\);' || return 1
  if [ "$(grep -o 'tally\.line(' <<<"$c" | grep -c .)" != 1 ]; then echo "  PIN   more than one batch line" >&2; return 1; fi
}

# suite <TelIngest.java> <TelSub.java> -> 0 pass, 1 a case or a pin failed, 3 the classes did not compile. Only 1 may
# convict a mutant. Each run has its own directory inside the one root.
suite() {
  local d rc
  d=$(mktemp -d -p "$W") || return 3
  pins "$1" || return 1
  if ! "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d" "$2" "$CASES/TelSubCases.java" \
      "$CASES/android/content/ContentValues.java"; then
    return 3
  fi
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d" com.nowhere.chooser.TelSubCases; rc=$?
  return "$rc"
}

echo "== $TI, $TS"
suite "$TI" "$TS" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED -- a mutant that does not compile proves nothing)"
fails=0
# mut <label> <the assertion that convicts it> <ti|ts> <perl-expr>
mut() {
  local d f out rc ti="$TI" ts="$TS"
  d=$(mktemp -d -p "$W") || return 1
  if [ "$3" = ti ]; then f="$TI"; ti="$d/TelIngest.java"; else f="$TS"; ts="$d/TelSub.java"; fi
  if ! perl -0pe "$4" "$f" > "$d/$(basename "$f")"; then echo "  ERROR     $1 -- perl failed on the mutation"; fails=$((fails+1)); return; fi
  if cmp -s "$f" "$d/$(basename "$f")"; then echo "  INERT     $1 -- the mutation changed nothing"; fails=$((fails+1)); return; fi
  out=$(suite "$ti" "$ts" 2>&1); rc=$?
  case "$rc" in
    1)
      if [[ "$out" == *"$2"* ]]; then echo "  convicted $1"
      else echo "  WRONG     $1 -- failed, but not on: $2"; printf '%s\n' "$out" | grep -E 'FAIL|PIN' | head -5; fails=$((fails+1)); fi ;;
    0) echo "  SURVIVED  $1"; fails=$((fails+1)) ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; fails=$((fails+1)) ;;
  esac
}
mut "m1 sub_id forced back to -1 in TelSub.file" "FAIL file puts the mapped sub" ts 's/v\.put\("sub_id", sub\);/v.put("sub_id", NO_SUB);/'
mut "m2 sub_id forced back to -1 at the SMS insert" "TelIngest writes sub_id itself" ti 's/sub = TelSub\.file\(v, TelSub\.rowTag\(f\), sims\);/v.put("sub_id", -1);/'
mut "m3 sub_id forced back to -1 at the MMS insert" "TelIngest writes sub_id itself" ti 's/int sub = TelSub\.file\(pdu, TelSub\.rowTag\(f\), sims\);/int sub = -1; pdu.put("sub_id", -1);/'
mut "m4 ack before read-back: ackable takes landed" "FAIL sms landed, not read back" ts 's/\? readOk : landed;/? landed : landed;/'
mut "m5 ack before read-back: the read-back moved after the ack" "each pass delivers, reads back, then acknowledges" ti 's/(            readBackRows\(ctx, reply, everOk, readOk, unknown\);\n)((?:.*\n){3}            ackLanded\(ctx, reply, everOk, readOk, acked, false, unknown\);\n)/$2$1/'
mut "m6 ack before read-back: readOk set from everOk" "readOk is set anywhere but readBackRows" ti 's/verified\+\+; everOk\[i\] = true; \}/verified++; everOk[i] = true; readOk[i] = true; }/'
mut "m7 ackLanded goes back to everOk" "ackLanded asks TelSub.ackable" ti 's/!TelSub\.ackable\(f\[0\], everOk\[i\], readOk\[i\]\)/!everOk[i]/'
mut "m8 duplicate check: a blind reader reads as absent" "FAIL blind, empty cursor" ts 's/return canRead \? present : null;/return present;/'
mut "m9 duplicate check removed from the SMS insert" "an SMS lookup goes through TelSub.lookup" ti 's/int step = rowStep\(isCall \? found : TelSub\.lookup\(canReadMessages\(ctx\), found\)\);/int step = isCall ? rowStep(found) : INSERT;/'
mut "m10 duplicate check removed from the MMS insert" "an MMS lookup goes through TelSub.lookup" ti 's/int step = rowStep\(TelSub\.lookup\(canReadMessages\(ctx\), mmsExists\(ctx, when\)\)\);/int step = INSERT;/'
mut "m11 fallback removed: no sub_id on no match" "FAIL fallback: file puts -1" ts 's/v\.put\("sub_id", sub\);/if (sub != NO_SUB) v.put("sub_id", sub);/'
mut "m12 subFor answers the first SIM" "FAIL two SIMs, the other tag" ts 's/ && tag\.equals\(simTag\(iccid\)\)\) return/) return/'
mut "m13 simTag keeps the f filler" "FAIL golden, f filler" ts 's/return s\.endsWith\("f"\) \? s\.substring\(0, s\.length\(\) - 1\) : s;/return s;/'
mut "m14 an unread ICCID matches its own tag" "FAIL an empty ICCID" ts 's/iccid != null && !norm\(iccid\)\.isEmpty\(\) && /iccid != null && /'
mut "m15 the tally counts -1 as real" "FAIL tally fell back" ts 's/if \(sub == NO_SUB\) fellBack\+\+; else real\+\+;/real++;/'
mut "m16 rowTag ignores the slot position" "FAIL sms, the slot after a retry" ts 's/int slot = "sms"\.equals\(f\[0\]\) \? 6 : "mms"\.equals\(f\[0\]\) \? 3 : -1;/int slot = "sms".equals(f[0]) || "mms".equals(f[0]) ? f.length - 1 : -1;/'
mut "m17 the MMS read-back skips the row" "the read-back asks both providers" ti 's/mms \? mmsExists\(ctx, when\)\n\s*: exists\(ctx, android\.provider\.Telephony\.Sms\.Inbox\.CONTENT_URI, when\)/exists(ctx, android.provider.Telephony.Sms.Inbox.CONTENT_URI, when)/'
mut "m18 the batch line is gone" "the batch logs its one line" ti 's/android\.util\.Log\.i\("NowhereChooser", tally\.line\(live, TelSub\.notReadBack\(reply, everOk, readOk\)\)\);//'
mut "m19 a call row needs a read-back" "FAIL call landed" ts 's/"sms"\.equals\(kind\) \|\| "mms"\.equals\(kind\) \? readOk : landed;/readOk;/'
mut "m20 the SMS insert ignores the row's tag" "deliver files an SMS" ti 's/sub = TelSub\.file\(v, TelSub\.rowTag\(f\), sims\);/sub = TelSub.file(v, null, sims);/'
mut "m21 the MMS insert ignores the row's tag" "deliverMms files an MMS" ti 's/int sub = TelSub\.file\(pdu, TelSub\.rowTag\(f\), sims\);/int sub = TelSub.file(pdu, null, sims);/'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
