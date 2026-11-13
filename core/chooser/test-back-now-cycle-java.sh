#!/usr/bin/env bash
# test-back-now-cycle-java.sh [--mutate] -- when the "back online -- Back up now" prompt goes up and comes down, run
# under javac (NWP-20261117-27).
#
# WHY THIS IS COMMITTED. The backup watcher cancelled the prompt whenever GET-SYNC-STATUS was not STALE. That is the
# LAST seal's verdict, which predates the reconnect, so the prompt went about 15 s after the reconnect while the
# offline changes were unsaved; the same arm reset the drop latch, so the "Backing up" a tap made of the prompt was
# never cleared (docs/backlog.md, "Back up now" answers BUSY and says nothing). BackNowCycle.java decides now and is
# pure Java, so this suite compiles it alone with the cases below; the PINS read the watcher in ChooserActivity as
# data, with comments stripped.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK; the version
# is printed first so the log proves which compiler ran.
#
#   bash test-back-now-cycle-java.sh            # the cases and the pins
#   bash test-back-now-cycle-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
DIR="$root/core/chooser/src/com/nowhere/chooser"
BC="$DIR/BackNowCycle.java"
CH="$DIR/ChooserActivity.java"
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
export TMPDIR="$W"
"$JAVAC" -J-Djava.io.tmpdir="$W" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
[ -f "$CH" ] || { echo "FAIL: missing $CH" >&2; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "FAIL: the pins need perl, and there is none -- refusing to report" >&2; exit 2; }

# The cases, in the default package; run() adds the package line so they reach the package-private class.
CASES="$W/BackNowCycleCases.java"
cat > "$CASES" <<'EOF'
public class BackNowCycleCases {
    static int failed = 0;
    static void eq(String name, long got, long want) {
        if (got != want) { System.out.println("--- FAIL " + name + ": got " + got + ", want " + want); failed++; }
        else System.out.println("ok   " + name);
    }
    public static void main(String[] a) {
        final int N = BackNowCycle.NOTHING, P = BackNowCycle.POST, C = BackNowCycle.CANCEL;
        BackNowCycle b;

        // No drop, no prompt: an online tick posts nothing, a landed seal cancels nothing.
        b = new BackNowCycle();
        eq("no drop: online posts nothing", b.onOnline(2000), N);
        eq("no drop: a landed seal cancels nothing", b.onLanded(2500), N);

        // Cause 1: the last seal landed OK before the drop and none since -> the prompt stays.
        b = new BackNowCycle();
        b.onDrop();
        eq("drop then online posts", b.onOnline(2000), P);
        eq("cause 1: the stamp of the seal before the drop does not cancel", b.onLanded(1000), N);
        eq("cause 1: asked again, still not", b.onLanded(1000), N);
        eq("cause 1: the prompt still waits", b.awaitingLanded() ? 1 : 0, 1);

        // A seal announced before the reconnect lands after it: no cancel. One announced at or after: cancel once.
        b = new BackNowCycle();
        b.onDrop();
        eq("posted", b.onOnline(2000), P);
        eq("a stamp one second before the reconnect does not cancel", b.onLanded(1999), N);
        eq("a stamp AT the reconnect cancels", b.onLanded(2000), C);
        eq("after CANCEL the cycle is disarmed", b.awaitingLanded() ? 1 : 0, 0);
        eq("after CANCEL a second landed reply cancels nothing", b.onLanded(2100), N);
        eq("after CANCEL no second POST without a new drop", b.onOnline(2200), N);

        b = new BackNowCycle();
        b.onDrop();
        b.onOnline(2000);
        eq("a stamp after the reconnect cancels", b.onLanded(2030), C);

        // reconnectAt is the POST tick's, not a later online tick's.
        b = new BackNowCycle();
        b.onDrop();
        eq("posted at 2000", b.onOnline(2000), P);
        eq("a later online tick posts nothing", b.onOnline(2010), N);
        eq("a seal from 2005 (after the POST tick) cancels", b.onLanded(2005), C);

        // 0 = no seal landed this session: never a cancel, even with a clock at 0.
        b = new BackNowCycle();
        b.onDrop();
        eq("posted at 0", b.onOnline(0), P);
        eq("a 0 stamp never cancels", b.onLanded(0), N);
        eq("a 0 reply never cancels", b.onReply("OK 0"), N);
        eq("a 1 stamp then cancels", b.onLanded(1), C);

        // The drop arm calls onDrop on every offline tick past the debounce: idempotent, it does not post.
        b = new BackNowCycle();
        b.onDrop(); b.onDrop();
        eq("two onDrop calls: one POST", b.onOnline(2000), P);
        eq("two onDrop calls: no second POST", b.onOnline(2005), N);

        // A second drop re-arms with a new reconnectAt.
        b = new BackNowCycle();
        b.onDrop();
        b.onOnline(2000);
        eq("first cycle cancels", b.onLanded(2010), C);
        b.onDrop();
        eq("second drop posts again", b.onOnline(3000), P);
        eq("second cycle: a stamp from the first cycle does not cancel", b.onLanded(2010), N);
        eq("second cycle: a stamp after the second reconnect cancels", b.onLanded(3001), C);

        // A drop before the prompt was cleared starts over: the old reconnect does not count.
        b = new BackNowCycle();
        b.onDrop();
        b.onOnline(2000);
        b.onDrop();
        eq("re-dropped, not yet online: nothing to wait for", b.awaitingLanded() ? 1 : 0, 0);
        eq("re-dropped: a landed seal cancels nothing", b.onLanded(2500), N);
        eq("re-dropped: back online posts", b.onOnline(3000), P);
        eq("re-dropped: a stamp after the first reconnect only does not cancel", b.onLanded(2500), N);

        // reset (no session) ends the cycle.
        b = new BackNowCycle();
        b.onDrop();
        b.onOnline(2000);
        b.reset();
        eq("reset: nothing to wait for", b.awaitingLanded() ? 1 : 0, 0);
        eq("reset: a landed seal cancels nothing", b.onLanded(2500), N);
        eq("reset: online posts nothing", b.onOnline(2600), N);

        // NWP-20261201-09: reconnectAt() is the POST tick's stamp, and 0 whenever no prompt is posted.
        b = new BackNowCycle();
        eq("reconnectAt: 0 on a new cycle", b.reconnectAt(), 0);
        b.onDrop();
        eq("reconnectAt: 0 before the POST", b.reconnectAt(), 0);
        eq("reconnectAt: posted at 2000", b.onOnline(2000), P);
        eq("reconnectAt: the POST's stamp after it", b.reconnectAt(), 2000);
        b.onOnline(2010);
        eq("reconnectAt: a later online tick does not move it", b.reconnectAt(), 2000);
        eq("reconnectAt: cancelled", b.onLanded(2100), C);
        eq("reconnectAt: 0 after a CANCEL", b.reconnectAt(), 0);
        b.onDrop();
        b.onOnline(3000);
        b.reset();
        eq("reconnectAt: 0 after reset", b.reconnectAt(), 0);

        // Replies: only "OK <digits>" is a stamp; anything else is NOTHING and keeps the notice.
        String[] bad = {null, "", "BUSY", "OK", "OK ", "OK -5", "OK 12x", "OK 2100 extra", "ERR", "IDLE",
                "OK 99999999999999999999", "ok 2100", "OK +2100", "STALE"};
        for (String r : bad) {
            b = new BackNowCycle();
            b.onDrop();
            b.onOnline(2000);
            eq("reply " + (r == null ? "null" : "\"" + r + "\"") + " is NOTHING", b.onReply(r), N);
            eq("reply " + (r == null ? "null" : "\"" + r + "\"") + " keeps the cycle", b.awaitingLanded() ? 1 : 0, 1);
        }
        eq("stamp of \"OK 2100\"", BackNowCycle.landedStamp("OK 2100"), 2100);
        eq("stamp of \" OK 2100 \" (trimmed)", BackNowCycle.landedStamp(" OK 2100 \n"), 2100);
        b = new BackNowCycle();
        b.onDrop();
        b.onOnline(2000);
        eq("reply \"OK 1999\" does not cancel", b.onReply("OK 1999"), N);
        eq("reply \"OK 2100\" cancels", b.onReply("OK 2100"), C);

        if (failed > 0) { System.out.println(failed + " case(s) failed"); System.exit(1); }
        System.out.println("all cases passed");
    }
}
EOF

# run <BackNowCycle.java> -> 0 pass, 1 a case failed, 3 compile.
run() {
  local d
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/com/nowhere/chooser"
  cp "$1" "$d/com/nowhere/chooser/BackNowCycle.java"
  sed -e '1i package com.nowhere.chooser;' "$CASES" > "$d/com/nowhere/chooser/BackNowCycleCases.java"
  "$JAVAC" -J-Djava.io.tmpdir="$W" -d "$d/out" "$d"/com/nowhere/chooser/*.java || return 3
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d/out" com.nowhere.chooser.BackNowCycleCases || return 1
}

# watcher <ChooserActivity.java>: startSyncStatusWatcher with comments stripped (lines that start with //, * or /*;
# a trailing // outside a string literal).
watcher() {
  perl -e '
    my ($f) = @ARGV; open(my $h, "<", $f) or die "$f: $!";
    my $in = 0;
    while (my $l = <$h>) {
      if (!$in) { next unless $l =~ /^    private void startSyncStatusWatcher\(\) \{$/; $in = 1; }
      last if $in && $l =~ /^    \}$/;
      next if $l =~ m{^\s*(//|\*|/\*)};
      $l =~ s{^((?:[^"/\n]|"(?:[^"\\\n]|\\.)*"|/(?![/*]))*)//.*$}{$1};
      print $l;
    }' "$1"
}

# notstale <stripped watcher>: the body of the slow tick's not-STALE arm -- the "} else {" that closes the
# "if (stale) {" after the GET-SYNC-STATUS poll, up to its own closing "}" at the same indent.
notstale() {
  perl -e '
    my ($f) = @ARGV; open(my $h, "<", $f) or die "$f: $!";
    my ($seen, $ind, $in) = (0, undef, 0);
    while (my $l = <$h>) {
      if ($seen == 0) { $seen = 1 if index($l, q{pollDaemon("GET-SYNC-STATUS\n")}) >= 0; next; }
      if ($seen == 1) { if ($l =~ /^(\s*)if \(stale\) \{\s*$/) { $ind = $1; $seen = 2; } next; }
      if (!$in) { $in = 1 if $l =~ /^\Q$ind\E\} else \{\s*$/; next; }
      last if $l =~ /^\Q$ind\E\}\s*$/;
      print $l;
    }' "$1"
}

# pins <ChooserActivity.java> -> 0 pass, 1 a pin failed.
pins() {
  local w arm bad=0
  w=$(mktemp -p "$W"); arm=$(mktemp -p "$W")
  watcher "$1" > "$w"
  notstale "$w" > "$arm"
  if ! grep -qF 'cancelBackupNotice(app, shownForUid)' "$arm"; then
    echo "  PIN   ERROR: the not-STALE arm was not found (no cancelBackupNotice in the extract)" >&2; return 1
  fi
  # P5 (cause 1): the not-STALE arm reads the LAST seal's OK; it must neither cancel the prompt nor touch the cycle.
  if grep -qE 'cancelBackNowNotice\(|backNow\.' "$arm"; then
    echo "  PIN   P5 the not-STALE arm cancels the Back-up-now prompt or touches its cycle (cause 1)" >&2; bad=1
  fi
  # P6: the old latch is gone as code.
  if grep -qw 'wasDropped' "$w"; then echo "  PIN   P6 wasDropped is still code in the watcher" >&2; bad=1; fi
  perl -0ne 'exit(/final BackNowCycle backNow = new BackNowCycle\(\);/ ? 0 : 1)' "$w" \
    || { echo "  PIN   P1 the watcher holds no BackNowCycle" >&2; bad=1; }
  perl -0ne 'exit(/if \(uid < 0\) \{(?:(?!\n                \}).)*?backNow\.reset\(\);(?:(?!\n                \}).)*?continue;/s ? 0 : 1)' "$w" \
    || { echo "  PIN   P2 the no-session arm does not reset the cycle" >&2; bad=1; }
  perl -0ne 'exit(/if \(offTicks >= 3\) \{(?:(?!\n\s*\}\n).)*?postDropNotice\(app, uid\);\s*dropShownForUid = uid; backNow\.onDrop\(\);\s*\}/s ? 0 : 1)' "$w" \
    || { echo "  PIN   P3 the debounced drop arm does not arm the cycle" >&2; bad=1; }
  perl -0ne 'exit(/if \(backNow\.onOnline\(System\.currentTimeMillis\(\) \/ 1000L\) == BackNowCycle\.POST\) \{\s*postBackNowNotice\(app, uid, backNow\.reconnectAt\(\), SaveMode\.backNowBody\(pollDaemon\("GET-SAVE-MODE\\n"\), unmeteredCtx\(app\)\)\);\s*backNowShownForUid = uid;\s*\}/ ? 0 : 1)' "$w" \
    || { echo "  PIN   P4 the online arm does not post the prompt on POST" >&2; bad=1; }
  perl -0ne 'exit(/if \(backNow\.awaitingLanded\(\)\s*&& backNow\.onReply\(pollDaemon\("GET-SEAL-LANDED\\n"\)\.trim\(\)\) == BackNowCycle\.CANCEL\) \{\s*cancelBackNowNotice\(app, uid\);\s*backNowShownForUid = -1;\s*\}/ ? 0 : 1)' "$w" \
    || { echo "  PIN   P7 the slow tick does not cancel the prompt on GET-SEAL-LANDED's CANCEL" >&2; bad=1; }
  # P8: postBackNowNotice is called only from the POST arm.
  [ "$(grep -c 'postBackNowNotice(' "$w")" = 1 ] || { echo "  PIN   P8 the watcher posts the prompt somewhere else" >&2; bad=1; }
  return "$bad"
}

# suite <BackNowCycle.java> <ChooserActivity.java>
suite() {
  [ -f "$1" ] || { echo "  PIN   BackNowCycle.java does not exist" >&2; return 1; }
  if grep -qE 'DaemonSocket|LocalSocket|nowhere_login|^import ' "$1"; then
    echo "  PIN   BackNowCycle.java must be java.lang only and name no daemon socket" >&2; return 1
  fi
  pins "$2" || return 1
  run "$1"
}

echo "== $BC"
suite "$BC" "$CH" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED -- a mutant that does not apply or compile proves nothing)"
# mut <label> <which: bc|ch> <perl-expr>
mut() {
  local d src m bcf chf rc
  d=$(mktemp -d -p "$W")
  bcf="$BC"; chf="$CH"
  case "$2" in bc) src="$BC" ;; ch) src="$CH" ;; esac
  m="$d/$(basename "$src")"
  if ! perl -0pe "$3" "$src" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; return 1; fi
  if cmp -s "$src" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; return 1; fi
  case "$2" in bc) bcf="$m" ;; ch) chf="$m" ;; esac
  suite "$bcf" "$chf" >"$d/out" 2>&1; rc=$?
  # Only a failing CASE ("--- FAIL") or a failing PIN convicts; a compile error (rc 3) is a broken mutant.
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "C1 any landed stamp cancels"                 bc 's/ \|\| landedSec < reconnectAt\) return NOTHING;/) return NOTHING;/' || fails=$((fails+1))
mut "C2 reconnectAt taken at the drop"            bc 's/(posted = true;\n\s*)reconnectAt = nowSec;\n/$1/' || fails=$((fails+1))
mut "C3 no disarm after CANCEL"                   bc 's/(landedSec < reconnectAt\) return NOTHING;\n)\s*reset\(\);\n/$1/' || fails=$((fails+1))
mut "C4 a 0 stamp counts as landed"               bc 's/ \|\| landedSec <= 0 \|\|/ ||/' || fails=$((fails+1))
mut "C5 the not-STALE arm cancels the prompt"     ch 's/(\} else \{\n(\s*)if \(shownForUid >= 0\) \{ cancelBackupNotice\(app, shownForUid\); shownForUid = -1; \}\n)/$1$2if (backNowShownForUid >= 0) { cancelBackNowNotice(app, backNowShownForUid); backNowShownForUid = -1; }\n/' || fails=$((fails+1))
mut "C6 the not-STALE arm resets the cycle"       ch 's/(\} else \{\n(\s*)if \(shownForUid >= 0\) \{ cancelBackupNotice\(app, shownForUid\); shownForUid = -1; \}\n)/$1$2backNow.reset();\n/' || fails=$((fails+1))
mut "C7 every online tick moves reconnectAt"      bc 's/(int onOnline\(long nowSec\) \{\n)/$1        reconnectAt = nowSec;\n/' || fails=$((fails+1))
mut "C8 a malformed reply reads as a stamp"       bc 's/return v < 0 \? NOTHING : onLanded\(v\);/return onLanded(v < 0 ? Long.MAX_VALUE : v);/' || fails=$((fails+1))
mut "C9 the online arm posts on every tick"       ch 's/if \(backNow\.onOnline\(System\.currentTimeMillis\(\) \/ 1000L\) == BackNowCycle\.POST\) \{/if (backNow.onOnline(System.currentTimeMillis() \/ 1000L) >= 0) {/' || fails=$((fails+1))
mut "C10 reconnectAt returns 0 (case reconnectAt: the POST's stamp after it)" bc 's/(long reconnectAt\(\) \{\n\s*)return reconnectAt;/$1return 0;/' || fails=$((fails+1))
mut "C11 the watcher passes no stamp (pin P4)"     ch 's/postBackNowNotice\(app, uid, backNow\.reconnectAt\(\), /postBackNowNotice(app, uid, 0L, /' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
