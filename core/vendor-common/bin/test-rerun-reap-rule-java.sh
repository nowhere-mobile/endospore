#!/usr/bin/env bash
# test-rerun-reap-rule-java.sh [--mutate] -- the gate's deadline on a lost REAP, run under javac (NWP-20261128-04).
#
# WHY THIS IS COMMITTED. Backlog row "A deleted profile's user stays running, with its CE unlocked, when the login
# daemon dies between the delete's SWITCH and its REAP ...". The daemon queues SWITCH and REAP together; when it dies
# after the gate acks SWITCH, its restart has lost the queue and nothing removes the user. The reap watcher now keeps
# a record of the switched uid and, after RERUN_AFTER_MS with no REAP or LOCK, sends RERUN-REAP and removes the user
# itself when that fails (docs/product-decisions.md 2026-10-25 h45 #2, 2026-10-30 h48 #3, 2026-11-02 h53 #4).
# RerunReapRule (pure) holds every decision and is compiled here with its cases ALONE. Source pins over
# ChooserActivity.ensureReapWatcher (comments stripped) check the record, the request text and the fallback:
#   S1 the REAP and the LOCK branch each clear the record of their uid
#   S2 REMOVE runs doRemove, and the watcher holds no reboot beyond the #46 watchdog's one
#   S3 the request is the literal "RERUN-REAP\n" + rrUid + "\n", once
#   S4 the watcher sleeps only in its own nap; RerunReapRule never sleeps
#   S5 an unanswered GET-COLDLOCK probe records UNKNOWN, never WARM
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-rerun-reap-rule-java.sh            # the cases and the source pins
#   bash test-rerun-reap-rule-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SUT="$SRC/RerunReapRule.java"
CHOOSER="$SRC/ChooserActivity.java"
CASES="$root/core/chooser/tests/rerun-reap/RerunReapRuleCases.java"
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
command -v perl >/dev/null 2>&1 || { echo "FAIL: comment stripping needs perl, and there is none" >&2; exit 2; }
"$JAVAC" -J-Djava.io.tmpdir="$W" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
[ -f "$CASES" ] || { echo "FAIL: missing $CASES" >&2; exit 2; }

strip() { perl -0pe 's{/\*.*?\*/}{ (my $x = $&) =~ s/[^\n]//g; $x }gse; s{//[^\n]*}{}g' "$1"; }

# suite <RerunReapRule.java> -> 0 pass, 1 a case failed or the class is missing, 3 did not compile.
suite() {
  local src="$1" d out rc
  [ -f "$src" ] || { echo "  FAIL  RerunReapRule.java does not exist (the rule is not built)" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$src" "$d/src/com/nowhere/chooser/RerunReapRule.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/RerunReapRuleCases.java"
  if ! "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then
    rm -rf "$d"; return 3
  fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.RerunReapRuleCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# count <haystack> <fixed string> -> the number of lines holding it.
count() { printf '%s\n' "$1" | grep -cF -- "$2"; }

# branch <watcher> <opening fixed string> -> the text from that line to the next "} else if" line.
branch() {
  printf '%s\n' "$1" | awk -v a="$2" 'index($0, a) { on = 1; print; next } on && /\} else if/ { exit } on { print }'
}

# pins <ChooserActivity.java> <RerunReapRule.java> -> 0 when S1-S5 hold, 1 otherwise.
pins() {
  local chooser="$1" rule="$2" w rs br n bad=0 l_unk l_probe
  w=$(strip "$chooser" | awk '/static void ensureReapWatcher\(Context ctx\) \{/ { on = 1 } on { print } on && /^    }$/ { exit }')
  case "$w" in *'POLL-REAP'*) ;; *) echo "  FAIL  ensureReapWatcher not found in $chooser" >&2; return 1 ;; esac
  rs=""; [ -f "$rule" ] && rs=$(strip "$rule")
  # S1
  br=$(branch "$w" 'reply.startsWith("REAP ")')
  case "$br" in *'if (uid == rrUid) rrUid = -1;'*) echo "  ok    S1 the REAP branch clears the record" ;;
    *) echo "  FAIL  S1 the REAP branch does not clear the record of its uid" >&2; bad=1 ;; esac
  br=$(branch "$w" 'reply.startsWith("LOCK ")')
  case "$br" in *'if (uid == rrUid) rrUid = -1;'*) echo "  ok    S1 the LOCK branch clears the record" ;;
    *) echo "  FAIL  S1 the LOCK branch does not clear the record of its uid" >&2; bad=1 ;; esac
  # S2
  br=$(printf '%s\n' "$w" | awk '/\} else if \(rrD == RerunReapRule\.REMOVE\) \{/ { on = 1; next } on && /^                    \}/ { exit } on { print }')
  n=$(count "$br" 'main.post(() -> doRemove(app, rrU));')
  if [ "$n" -eq 1 ]; then echo "  ok    S2 REMOVE runs doRemove on the main handler"
  else echo "  FAIL  S2 the REMOVE arm does not run doRemove(app, rrU) on the main handler" >&2; bad=1; fi
  n=$(count "$w" 'reboot(')
  if [ "$n" -eq 1 ]; then echo "  ok    S2 the watcher's one reboot is the #46 watchdog's"
  else echo "  FAIL  S2 the watcher holds $n reboot( calls, not the #46 watchdog's one" >&2; bad=1; fi
  case "$rs" in *reboot*) echo "  FAIL  S2 RerunReapRule names a reboot" >&2; bad=1 ;; esac
  # S3
  n=$(count "$w" 'pollDaemon("RERUN-REAP\n" + rrUid + "\n")')
  if [ "$n" -eq 1 ]; then echo "  ok    S3 the RERUN-REAP request text"
  else echo "  FAIL  S3 the watcher sends pollDaemon(\"RERUN-REAP\\n\" + rrUid + \"\\n\") $n times, not once" >&2; bad=1; fi
  # S4
  n=$(count "$w" 'Thread.sleep(')
  if [ "$n" -eq 1 ]; then echo "  ok    S4 the watcher sleeps only in its nap"
  else echo "  FAIL  S4 the watcher holds $n Thread.sleep( calls, not the nap's one" >&2; bad=1; fi
  case "$rs" in *sleep*) echo "  FAIL  S4 RerunReapRule sleeps" >&2; bad=1 ;; esac
  # S5
  br=$(branch "$w" 'reply.startsWith("SWITCH ")')
  l_unk=$(printf '%s\n' "$br" | grep -nF 'int rrK = RerunReapRule.UNKNOWN;' | head -1 | cut -d: -f1)
  l_probe=$(printf '%s\n' "$br" | grep -nF 'pollDaemon("GET-COLDLOCK\n")' | head -1 | cut -d: -f1)
  if [ -n "$l_unk" ] && [ -n "$l_probe" ] && [ "$l_unk" -lt "$l_probe" ]; then
    echo "  ok    S5 the record's kind starts UNKNOWN before the probe"
  else echo "  FAIL  S5 the SWITCH branch does not start its kind as UNKNOWN before the GET-COLDLOCK probe" >&2; bad=1; fi
  n=$(count "$br" 'rrK = RerunReapRule.kindOf(')
  [ "$n" -eq 1 ] || { echo "  FAIL  S5 the probe's answer does not pass RerunReapRule.kindOf" >&2; bad=1; }
  n=$(count "$br" 'rrKind = rrK;')
  [ "$n" -eq 1 ] || { echo "  FAIL  S5 the record does not take the probe's kind" >&2; bad=1; }
  n=$(count "$br" 'RerunReapRule.WARM')
  [ "$n" -eq 0 ] || { echo "  FAIL  S5 the SWITCH branch assigns WARM itself" >&2; bad=1; }
  [ "$bad" -eq 0 ]
}

echo "== $SUT"
suite "$SUT" || { echo "FAILED"; exit 1; }
echo "== source pins"
pins "$CHOOSER" "$SUT" || { echo "FAILED (pins)"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED -- a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <perl-expr>   (mutates RerunReapRule.java; the cases must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/RerunReapRule.java"
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
mutpin() { # mutpin <label> <perl-expr>   (mutates ChooserActivity.java; the source pins must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/ChooserActivity.java"
  cp "$CHOOSER" "$c"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$CHOOSER" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  pins "$c" "$SUT" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  echo "  convicted $1"
}
fails=0
mut "M1 cold switches rerun" 's/\n\s+if \(kind == COLD\) return WAIT;//' || fails=$((fails+1))
mut "M2 ERR-LIVE removes" 's/case "ERR-LIVE":\n(\s+)case "ERR-PARKED":\n(\s+)return STAND_DOWN;/case "ERR-PARKED":\n$2return STAND_DOWN;\n$1case "ERR-LIVE":\n$2return REMOVE;/' || fails=$((fails+1))
mut "M3 BUSY removes at once" 's/return tries < MAX_TRIES \? RETRY : failed\(kind\);/return failed(kind);/' || fails=$((fails+1))
mut "M4 RERUN_AFTER_MS set to 10 000" 's/RERUN_AFTER_MS = 45_000L;/RERUN_AFTER_MS = 10_000L;/' || fails=$((fails+1))
mutpin "M5 the LOCK clear removed" 's/\n\s+if \(uid == rrUid\) rrUid = -1; \/\/ NWP-20261128-04: the LOCK came//' || fails=$((fails+1))
mut "M6 UNKNOWN treated as WARM" 's/return kind == WARM \? REMOVE : STAND_DOWN;/return kind != COLD ? REMOVE : STAND_DOWN;/' || fails=$((fails+1))
mutpin "M7 a no-answer probe recorded as WARM" 's/int rrK = RerunReapRule\.UNKNOWN;/int rrK = RerunReapRule.WARM;/' || fails=$((fails+1))
mut "M7b kindOf maps no answer to WARM" 's/if \(p\.isEmpty\(\)\) return UNKNOWN;/if (p.isEmpty()) return WARM;/' || fails=$((fails+1))
mutpin "M8 the REAP clear removed" 's/\n\s+if \(uid == rrUid\) rrUid = -1; \/\/ NWP-20261128-04: the REAP came//' || fails=$((fails+1))
mutpin "M9 REMOVE switches instead of removing" 's/main\.post\(\(\) -> doRemove\(app, rrU\)\);/main.post(() -> doSwitch(app, rrU));/' || fails=$((fails+1))
mutpin "M10 REMOVE reboots" 's/main\.post\(\(\) -> doRemove\(app, rrU\)\);/main.post(() -> doRemove(app, rrU)); try { dpm.reboot(admin); } catch (Throwable ig) {}/' || fails=$((fails+1))
mutpin "M11 the step sleeps" 's/(\n\s+)rrTries\+\+;/$1try { Thread.sleep(RerunReapRule.RETRY_MS); } catch (InterruptedException ie) { return; }$1rrTries++;/' || fails=$((fails+1))
mutpin "M12 the request names another verb" 's/pollDaemon\("RERUN-REAP\\n" \+ rrUid/pollDaemon("REAP\\n" + rrUid/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
