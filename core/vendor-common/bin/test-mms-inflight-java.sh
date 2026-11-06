#!/usr/bin/env bash
# test-mms-inflight-java.sh [--mutate] -- the gate MMS download bookkeeping, run under javac (NWP-20261110-10).
#
# WHY THIS IS COMMITTED. The per-SIM count of live MMS downloads used to be a ConcurrentHashMap whose atomic merge
# was followed, OUTSIDE any lock, by the call that switches the SIM's MMS data policy: download A's "off" could land
# after download B's "on", B ran with the policy off and timed out silently. And the download timeout freed the txn
# of a download the completion callback had just finished. MmsInFlight (java.* only) now holds the tokens, the
# per-SIM count and the txn claims, and calls the policy under its lock; it is compiled here with its cases. A source
# check (comments stripped) pins the wiring in WapPushDeliverReceiver.java.
#
# NWP-20261110-15: the policy is persistent per subscription and the count dies with the process, so a chooser that
# died inside a download left the SIM's MMS PDN allowed. MmsInFlight.resetIdle (C6-C9) switches it off, under the
# lock, on each SIM with no download registered; source checks pin its caller: WapPushDeliverReceiver
# .resetIdlePolicies returns before any SubscriptionManager call unless user 0 (S6) and logs counts only (S7), and
# NowhereApp.onCreate calls it inside its user-0 block (S5).
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-mms-inflight-java.sh            # the cases and the source check
#   bash test-mms-inflight-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SUT="${MMS_INFLIGHT_SRC:-$SRC/MmsInFlight.java}"
WAP="$SRC/WapPushDeliverReceiver.java"
APP="$SRC/NowhereApp.java"
CASES="$root/core/chooser/tests/mms-inflight/MmsInFlightCases.java"
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
[ -f "$CASES" ] || { echo "FAIL: missing $CASES" >&2; exit 2; }

# suite <MmsInFlight.java> -> 0 pass, 1 a case failed or the class is missing, 3 did not compile.
suite() {
  local src="$1" d out rc
  [ -f "$src" ] || { echo "  FAIL  MmsInFlight.java does not exist" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$src" "$d/src/com/nowhere/chooser/MmsInFlight.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/MmsInFlightCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.MmsInFlightCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# strip <file> -> the source with comments removed (string literals kept).
strip() {
  perl -0pe 's{("(?:\\.|[^"\\\n])*")|//[^\n]*|/\*.*?\*/}{defined $1 ? $1 : ""}gse' "$1"
}

# fbody <stripped-source> <signature-fragment> -> the method from its signature to the closing `    }`.
fbody() {
  printf '%s\n' "$1" | awk -v sig="$2" 'index($0, sig) { on = 1 } on { print } on && /^    }$/ { exit }'
}

# source_check <WapPushDeliverReceiver.java> -> 0 when the wiring holds.
source_check() {
  local code hn fd at rp guard n bad=0
  code=$(strip "$1")
  hn=$(fbody "$code" 'private static void handleNotification(')
  fd=$(fbody "$code" 'static boolean finishDownload(')
  at=$(fbody "$code" 'private static void armDownloadTimeout(')
  [ -n "$hn" ] && [ -n "$fd" ] && [ -n "$at" ] || { echo "  FAIL  a member is missing from $1" >&2; return 1; }
  printf '%s\n' "$hn" | grep -qF 'MmsInFlight.register(' || { echo "  FAIL  S1 handleNotification does not call MmsInFlight.register(" >&2; bad=1; }
  if printf '%s\n' "$hn" | grep -qE 'IN_FLIGHT|mmsPdnAcquire'; then echo "  FAIL  S1 handleNotification keeps its own bookkeeping" >&2; bad=1; fi
  printf '%s\n' "$fd" | grep -qE 'return true;' && printf '%s\n' "$fd" | grep -qF '!MmsInFlight.finish(name, policy(app))) return false;' \
    || { echo "  FAIL  S2 finishDownload does not return MmsInFlight.finish's result" >&2; bad=1; }
  n=$(printf '%s\n' "$at" | grep -c 'releaseTxn(')
  if [ "$n" -ne 1 ] || ! printf '%s\n' "$at" | perl -0ne 'exit !/if \(finishDownload\([^)]*\)\) \{[^{}]*releaseTxn\([^)]*\);[^{}]*\}/'; then
    echo "  FAIL  S3 armDownloadTimeout frees the txn outside 'if (finishDownload('" >&2; bad=1
  fi
  if printf '%s\n' "$code" | grep -qE '(MMS_PDN_REFS|TXN_SEEN|IN_FLIGHT)[[:space:]]*=|(ConcurrentHashMap|Map)<[^;]*>[[:space:]]+(MMS_PDN_REFS|TXN_SEEN|IN_FLIGHT)\b'; then
    echo "  FAIL  S4 WapPushDeliverReceiver still declares its own MMS bookkeeping" >&2; bad=1
  fi
  rp=$(fbody "$code" 'static void resetIdlePolicies(Context app) {')
  guard=$(printf '%s\n' "$rp" | sed -n 2p)
  if [ -z "$rp" ] || ! printf '%s\n' "$guard" | grep -qxE '[[:space:]]*if \(android\.os\.UserHandle\.myUserId\(\) != 0\) return;[[:space:]]*' \
     || printf '%s\n' "$rp" | sed -n '1,2p' | grep -qF 'SubscriptionManager'; then
    echo "  FAIL  S6 resetIdlePolicies does not return before any SubscriptionManager call unless myUserId() == 0" >&2; bad=1
  fi
  if [ -z "$rp" ] || ! printf '%s\n' "$rp" | grep -qF '"#150 MMS data policy reset at process start: " + n + " of "' \
     || printf '%s\n' "$rp" | grep -qE '[Ii][Cc][Cc][Ii][Dd]|getIccId|getNumber|getCarrierName|getDisplayName|getMessage\(' \
     || printf '%s\n' "$rp" | grep -qE 'Log\.[a-z]\([^;]*,[[:space:]]*t\)'; then
    echo "  FAIL  S7 resetIdlePolicies' log line is missing or can carry an iccid, number or carrier name" >&2; bad=1
  fi
  [ "$bad" -eq 0 ]
}

# app_check <NowhereApp.java> -> 0 when onCreate's user-0 block calls resetIdlePolicies, and nothing else does (S5).
app_check() {
  local code
  code=$(strip "$1")
  printf '%s\n' "$code" | perl -0ne '
    sub block { my ($s, $o) = @_; my $d = 0;
      for (my $p = $o; $p < length $s; $p++) { my $c = substr($s, $p, 1);
        $d++ if $c eq "{"; if ($c eq "}") { return substr($s, $o, $p - $o + 1) if --$d == 0 } }
      return undef }
    my $call = "WapPushDeliverReceiver.resetIdlePolicies(";
    my $n = () = /\Q$call\E/g; exit 1 if $n != 1;
    my $i = index($_, "public void onCreate() {"); exit 1 if $i < 0;
    my $body = block($_, index($_, "{", $i)); exit 1 unless defined $body;
    my $g = "if (android.os.UserHandle.myUserId() == 0) {";
    my $j = index($body, $g); exit 1 if $j < 0;
    my $u0 = block($body, $j + length($g) - 1); exit 1 unless defined $u0;
    exit(index($u0, $call) < 0 ? 1 : 0);' \
    || { echo "  FAIL  S5 NowhereApp.onCreate does not call WapPushDeliverReceiver.resetIdlePolicies( (once) inside its myUserId() == 0 block" >&2; return 1; }
}

echo "== $SUT"
suite "$SUT" || { echo "FAILED"; exit 1; }
source_check "$WAP" || { echo "FAILED (source)"; exit 1; }
app_check "$APP" || { echo "FAILED (source)"; exit 1; }
echo "source: ok"
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED -- a mutant that does not compile proves nothing)"
mut() { # mut <label> <perl-expr>   (mutates MmsInFlight.java; the cases must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/MmsInFlight.java"
  cp "$SUT" "$c"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$SUT" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  suite "$c" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
mutsrc() { # mutsrc <label> <perl-expr>   (mutates WapPushDeliverReceiver.java; the source check must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/WapPushDeliverReceiver.java"
  cp "$WAP" "$c"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$WAP" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  source_check "$c" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  echo "  convicted $1"
}
mutapp() { # mutapp <label> <perl-expr>   (mutates NowhereApp.java; the S5 check must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/NowhereApp.java"
  cp "$APP" "$c"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$APP" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  app_check "$c" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  echo "  convicted $1"
}
fails=0
mut "M1 register calls p.set after leaving the lock" \
  's/(synchronized \(LOCK\) \{\n            IN_FLIGHT\.put\(name, subId\);\n            int n = REFS\.merge\(subId, 1, Integer::sum\);\n)            if \(n == 1\) p\.set\(subId, true\);\n        \}/$1        \}\n        if (REFS.getOrDefault(subId, 0) == 1) p.set(subId, true);/' || fails=$((fails+1))
mut "M1b finish calls p.set after leaving the lock" \
  's/static boolean finish\(String name, Policy p\) \{\n        synchronized \(LOCK\) \{(.*?)\n            if \(left <= 0\) \{\n                REFS\.remove\(subId\);\n                p\.set\(subId, false\);\n            \}\n            return true;\n        \}/static boolean finish(String name, Policy p) {\n        Integer subId; int left;\n        synchronized (LOCK) {\n            subId = IN_FLIGHT.remove(name);\n            if (subId == null) return false;\n            left = REFS.merge(subId, -1, Integer::sum);\n            if (left <= 0) REFS.remove(subId);\n        }\n        if (left <= 0) p.set(subId, false);\n        return true;/s' || fails=$((fails+1))
mut "M2 finish sets off on every finish" 's/if \(left <= 0\) \{\n                REFS\.remove\(subId\);\n                p\.set\(subId, false\);\n            \}/if (left <= 0) REFS.remove(subId);\n            p.set(subId, false);/' || fails=$((fails+1))
mut "M3 finish uncounts another SIM" 's/REFS\.merge\(subId, -1, Integer::sum\)/REFS.merge(subId == 1 ? 2 : 1, -1, Integer::sum)/' || fails=$((fails+1))
mut "M4 finish is true for an unknown name" 's/if \(subId == null\) return false;/if (subId == null) return true;/' || fails=$((fails+1))
mut "M5 claimTxn never prunes" 's/if \(nowMs - it\.next\(\) > TXN_WINDOW_MS\) it\.remove\(\);/it.next();/' || fails=$((fails+1))
mutsrc "M6 armDownloadTimeout frees the txn outside the if" \
  's/(if \(finishDownload\(app, name, uriStr, subId\)\) \{\n[^\n]*\n)\s*releaseTxn\(txn\);[^\n]*\n(\s*\})/$1$2\n            releaseTxn(txn);/' || fails=$((fails+1))
mut "M7 resetIdle ignores the count" \
  's/if \(subId == null \|\| REFS\.getOrDefault\(subId, 0\) != 0\) continue;/if (subId == null) continue;/' || fails=$((fails+1))
mut "M8 resetIdle runs outside the lock" \
  's/(static int resetIdle\(Iterable<Integer> subIds, Policy p\) \{\n        )synchronized \(LOCK\) \{/$1\{/' || fails=$((fails+1))
mutapp "M9 the resetIdlePolicies call moved out of the user-0 block" \
  's/\n[ \t]*new Thread\(\(\) -> WapPushDeliverReceiver\.resetIdlePolicies\(this\), "nowhere-mms-policy"\)\.start\(\);//; s/\n(        if \(android\.os\.UserHandle\.myUserId\(\) == 0\) \{)/\n        new Thread(() -> WapPushDeliverReceiver.resetIdlePolicies(this), "nowhere-mms-policy").start();\n$1/' || fails=$((fails+1))
mutsrc "M10 resetIdlePolicies loses its user-0 guard" \
  's/\n\s*if \(android\.os\.UserHandle\.myUserId\(\) != 0\) return;//' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
