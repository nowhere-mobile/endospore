#!/usr/bin/env bash
# test-deleted-watch-java.sh [--mutate] -- the "Profile deleted" screen's watchdog, run under javac
# (NWP-20261105-02, Q117, #141 D5).
#
# WHY THIS IS COMMITTED. After DELETE's OK the daemon ends the screen by switching to the gate and removing the user.
# If the daemon dies first, nothing does: the screen strands and the deleted session stays decrypted. The verdict
# (DeletedWatch.action) is pure and runs here; the thread that polls and reboots (ProfileActivity.watchDeleted) cannot
# run off a device, so its shape is pinned as data: the GET-SYNC-STATUS poll, one reboot, no write verb, an empty
# reply counted as a miss (DaemonSocket.roundTrip answers "", never null), and the watch ending with no reboot once
# the gate's switch has moved this user to the background.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (see test-end-unsaved-java.sh).
#
#   bash test-deleted-watch-java.sh            # the cases and pins
#   bash test-deleted-watch-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W"

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
DW="$root/core/chooser/src/com/nowhere/chooser/DeletedWatch.java"
PA="$root/core/chooser/src/com/nowhere/chooser/ProfileActivity.java"
CASES="$root/core/chooser/tests/deleted-watch/DeletedWatchCases.java"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip: install a JDK or run it on the" \
       "build VM." >&2
  exit 1
fi
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 1; }
command -v perl >/dev/null 2>&1 || { echo "FAIL: this suite needs perl, and there is none" >&2; exit 1; }
[ -f "$PA" ] && [ -f "$CASES" ] || { echo "FAIL: missing $PA or $CASES" >&2; exit 1; }

body() { # body <file> <signature> -- the signature line through its closing brace
  awk -v sig="$2" '
    !on && index($0, sig) { on=1; depth=0 }
    on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
  ' "$1"
}

# suite <DeletedWatch.java> <ProfileActivity.java> -> 0 pass, 1 a case or a pin failed, 3 the cases did not compile.
# Only 1 may convict a mutant.
suite() {
  local dw="$1" pa="$2" b n d
  [ -f "$dw" ] || { echo "  PIN   DeletedWatch.java is missing" >&2; return 1; }
  # P1: the success branch starts the watchdog right after the terminal screen is set.
  perl -0ne 'exit(/if \(deleteSucceeded\(r\)\) \{.*?setContentView\(done\);\s*watchDeleted\(done\);.*?\} else \{/s ? 0 : 1)' "$pa" || {
    echo "  PIN   the delete success branch must call watchDeleted(done) right after setContentView(done)" >&2; return 1; }
  b=$(body "$pa" 'private void watchDeleted(')
  [ -n "$b" ] || { echo "  PIN   watchDeleted is missing" >&2; return 1; }
  # P2: it polls the lock-free status with a short cap.
  printf '%s' "$b" | perl -0ne 'exit(/DaemonSocket\.roundTrip\("GET-SYNC-STATUS\\n",\s*(\d+)\)/ && $1 <= 5000 ? 0 : 1)' || {
    echo "  PIN   watchDeleted must poll DaemonSocket.roundTrip(\"GET-SYNC-STATUS\\n\", <=5000)" >&2; return 1; }
  # P3: exactly one reboot(null), under the REBOOT branch.
  n=$(printf '%s' "$b" | grep -o 'reboot(null)' | wc -l)
  [ "$n" -eq 1 ] || { echo "  PIN   watchDeleted must call reboot(null) exactly once (found $n)" >&2; return 1; }
  printf '%s' "$b" | perl -0ne 'exit(/"REBOOT"\.equals\(act\)\)\s*\{[^}]*?\.reboot\(null\)/s ? 0 : 1)' || {
    echo "  PIN   reboot(null) must sit under the REBOOT branch" >&2; return 1; }
  # P4: no write verb.
  [[ "$b" != *DELETE* && "$b" != *LOGOUT* && "$b" != *ACK-* ]] || {
    echo "  PIN   watchDeleted must send no write verb (DELETE, LOGOUT, ACK-)" >&2; return 1; }
  # P5: the delete-reply suite's pins.
  grep -qF 'if (deleteSucceeded(r)) {' "$pa" && grep -qF 'StatusLine.error(msg, deleteFailCopy(r));' "$pa" || {
    echo "  PIN   the delete listener's deleteSucceeded / deleteFailCopy lines changed" >&2; return 1; }
  # P6: an empty reply is a miss (roundTrip answers "" for an unreachable daemon).
  printf '%s' "$b" | perl -0ne 'exit(/r\s*==\s*null\s*\|\|\s*r\.isEmpty\(\)/ ? 0 : 1)' || {
    echo "  PIN   watchDeleted must count an empty reply as a miss, not only null" >&2; return 1; }
  # P7: a background user ends the watch. After the poll and right before the verdict it returns once getCurrentUser()
  # is not this user (the gate took the switch), so no reboot lands under the gate; a throw keeps it watching.
  printf '%s' "$b" | perl -0ne 'exit(/DaemonSocket\.roundTrip\(.*?try \{\s*if \(android\.app\.ActivityManager\.getCurrentUser\(\) != android\.os\.UserHandle\.myUserId\(\)\) return;\s*\} catch \(Throwable ignore\) \{\}\s*String act = DeletedWatch\.action\(/s ? 0 : 1)' || {
    echo "  PIN   watchDeleted must return before DeletedWatch.action once getCurrentUser() is not this user" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  cp "$dw" "$d/DeletedWatch.java"; cp "$CASES" "$d/DeletedWatchCases.java"
  "$JAVAC" -encoding UTF-8 -d "$d/c" "$d"/*.java || { rm -rf "$d"; return 3; }
  "$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/c" com.nowhere.chooser.DeletedWatchCases
  n=$?
  rm -rf "$d"
  [ "$n" -eq 0 ] || return 1
}

echo "== $DW"
suite "$DW" "$PA" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED -- a mutant that does not apply or compile is a failure)"
mut() { # mut <label> <dw|pa> <perl-expr>
  local d m rc src
  if [ "$2" = dw ]; then src="$DW"; else src="$PA"; fi
  d=$(mktemp -d -p "$W") || return 1; m="$d/$(basename "$src")"
  if ! perl -0pe "$3" "$src" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$src" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  if [ "$2" = dw ]; then suite "$m" "$PA" >/dev/null 2>&1; else suite "$DW" "$m" >/dev/null 2>&1; fi
  rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "M1 deadline ahead of the daemon's holds" dw 's/DEADLINE_MS = 60_000/DEADLINE_MS = 20_000/' || fails=$((fails+1))
mut "M2 misses ignored"                       dw 's/missesInARow >= MISSES \|\| //' || fails=$((fails+1))
mut "M3 the grace ignored"                    dw 's/rebootThrew \|\| sinceAskMs >= REBOOT_GRACE_MS/rebootThrew/' || fails=$((fails+1))
mut "M4 reboot answered again after asking"   dw 's/if \(!rebootAsked && /if (/' || fails=$((fails+1))
mut "M5 the watchdog is not started"          pa 's/\n[ \t]*watchDeleted\(done\);//' || fails=$((fails+1))
mut "M6 only a null reply is a miss"          pa 's/r == null \|\| r\.isEmpty\(\)/r == null/' || fails=$((fails+1))
mut "M7 the watch outlives the gate's switch" pa 's/\n[ \t]*try \{\n[ \t]*if \(android\.app\.ActivityManager\.getCurrentUser\(\)[^\n]*\n[ \t]*\} catch \(Throwable ignore\) \{\}//' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
