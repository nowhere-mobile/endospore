#!/usr/bin/env bash
# test-auto-sweep-net-java.sh [--mutate] -- NWP-20261112-11 (Q042): the post-login Auto sweep follows the profile's
# "Download over mobile data" switch, the media prefetch's rule; "Install pending apps now" runs on any network; the
# gate re-kicks the sweep when the rule turns to yes within one session.
# Compiles the chooser's pure AutoSweepNet (java.lang only, no Android SDK) with core/chooser/tests/auto-sweep-net's
# cases ALONE and EXECUTES them, then checks the REAL call sites over their code with comments dropped, so a comment
# can neither satisfy nor trip a check:
#   A1 mayFetch: by hand always; switch on -> any internet; switch off -> Wi-Fi only.
#   A2 meteredAllowed: only a trimmed "1" is on.
#   A3 rekick: only a no -> yes turn of one session (uid > 0, the same uid on both ticks).
#   A4.1 sweepAuto takes (boolean byHand) and asks AutoSweepNet.mayFetch with the session's GET-PREFETCH-METERED reply, onWifiCtx
#        and hasInternetCtx, after pendingAutoApps and before the empty check and qEnqueue(work).
#   A4.2 a false gate clears work and returns nothing; the restore-only retry loop follows the gate block, outside it.
#   A4.3 installPendingRow's chip starts the sweep with EXTRA_BY_HAND.
#   A4.4 kickAutoMaterialise's sweep carries neither EXTRA_BY_HAND nor EXTRA_NET_REKICK (its sweep is the gated one).
#   A4.5 onStartCommand reads both extras, and an EXTRA_NET_REKICK start runs sweepAutoJoined(false) and returns before
#        snapshotAppSeen, AppHeld.refresh, the phantom reconcile and wakeRestored.
#   A4.6 the gate's backup watcher re-kicks through AutoSweepNet.rekick after its `net` line, starts the service in
#        that user with EXTRA_SWEEP + EXTRA_NET_REKICK, remembers uid/net, and forgets the uid at the gate.
#
# It needs a JDK, and it FAILS when there is none: a Java suite that skips without one would read green on a runner
# that never ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
# --mutate re-runs it against broken copies of the four files, each of which must FAIL a named check. A mutant that
# does not apply (INERT) or does not compile (BROKEN) counts as a failure, never a pass.
#
#   bash test-auto-sweep-net-java.sh            # the cases and the source checks
#   bash test-auto-sweep-net-java.sh --mutate   # ... plus the mutants
set -uo pipefail
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-auto-sweep-net-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
command -v perl >/dev/null 2>&1 || { echo "test-auto-sweep-net-java: FAIL -- no perl; this suite did NOT run" >&2; exit 2; }
# ONE temp root: every class dir and mutant tree lives under it, and the trap removes it however this ends.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser
CASES=$ROOT/core/chooser/tests/auto-sweep-net/AutoSweepNetCases.java

# cases <root>: compile <root>'s AutoSweepNet with the cases into a fresh dir and run them (A1-A3).
cases() {
  local d
  [ -f "$1/$CH/AutoSweepNet.java" ] || { echo "FAIL A1-A3 $CH/AutoSweepNet.java does not exist"; return 1; }
  d=$(mktemp -d -p "$W")
  "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d" "$1/$CH/AutoSweepNet.java" "$CASES" || return 3
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d" com.nowhere.chooser.AutoSweepNetCases
}

# code <file> <signature line>: the method from its signature to its closing `    }`, with whole-line comments dropped
# and trailing `//` comments stripped (a `//` inside a string literal is kept).
code() {
  perl -e '
    my ($f, $sig) = @ARGV; open(my $h, "<", $f) or die "$f: $!";
    my $in = 0;
    while (my $l = <$h>) {
      if (!$in) { next unless index($l, $sig) == 0; $in = 1; }
      last if $in && $l =~ /^    \}$/;
      next if $l =~ m{^\s*(//|\*|/\*)};
      $l =~ s{^((?:[^"/\n]|"(?:[^"\\\n]|\\.)*"|/(?![/*]))*)//.*$}{$1};
      print $l;
    }' "$1" "$2"
}

# sources <root>: A4.1-A4.6 over <root>'s UnarchiveService, ProfileActivity and ChooserActivity.
sources() {
  local r=$1 sweep start chip kick watch bad=0 out
  sweep=$(code "$r/$CH/UnarchiveService.java" "    private void sweepAuto(")
  start=$(code "$r/$CH/UnarchiveService.java" "    public int onStartCommand(Intent intent, int flags, int startId) {")
  chip=$(code "$r/$CH/ProfileActivity.java" "    private LinearLayout installPendingRow(int n, boolean allowMetered, boolean onWifi) {")
  kick=$(code "$r/$CH/ChooserActivity.java" "    private static void kickAutoMaterialise(")
  watch=$(code "$r/$CH/ChooserActivity.java" "    private void startSyncStatusWatcher() {")
  if [ -z "$sweep" ] || [ -z "$start" ] || [ -z "$chip" ] || [ -z "$kick" ] || [ -z "$watch" ]; then
    echo "FAIL A4.0 sweepAuto, onStartCommand, installPendingRow, kickAutoMaterialise or startSyncStatusWatcher not found"
    bad=1
  fi

  out=$(perl -0777 -ne '
    my $s = $_; my @f;
    push @f, "A4.1 sweepAuto does not take (boolean byHand)" unless $s =~ /\A    private void sweepAuto\(boolean byHand\) \{/;
    my $call = q{AutoSweepNet.mayFetch(byHand,};
    my $n = () = $s =~ /\Q$call\E/g;
    if ($n != 1) { push @f, "A4.1 sweepAuto holds $n AutoSweepNet.mayFetch(byHand, calls, want 1"; }
    else {
      my $i = index($s, $call);
      my $pend = index($s, q{pendingAutoApps(this, true, retry);});
      my $enq = index($s, q{qEnqueue(work);});
      my $empty = index($s, q{if (work.isEmpty() && retry.isEmpty())});
      push @f, "A4.1 the gate does not sit after pendingAutoApps and before the empty check and qEnqueue(work)"
        unless $pend >= 0 && $enq >= 0 && $empty >= 0 && $pend < $i && $i < $empty && $i < $enq;
      for my $w (q{AutoSweepNet.meteredAllowed(daemon("GET-PREFETCH-METERED\n"))},
                 q{ChooserActivity.onWifiCtx(this)}, q{ChooserActivity.hasInternetCtx(this)}) {
        push @f, "A4.1 the gate does not read $w" if index($s, $w) < 0;
      }
    }
    if ($s =~ /if \(!work\.isEmpty\(\) && !AutoSweepNet\.mayFetch\((.*?)\)\) \{(.*?)\n        \}/s) {
      my ($body, $end) = ($2, $+[0]);
      my $after = substr($s, $end);
      push @f, "A4.2 a false gate does not clear work" if index($body, q{work.clear();}) < 0;
      push @f, "A4.2 a false gate returns (the restore-only retries would be skipped)" if $body =~ /\breturn\b/;
      push @f, "A4.2 the gate block touches retry" if $body =~ /\bretry\b/;
      push @f, "A4.2 byHand or mayFetch is read again after the gate block (a branch on it)"
        if $after =~ /\bbyHand\b|mayFetch/;
      push @f, "A4.2 the restore-only loop `for (int c = 0; c < retry.size(); c += OdRestoreList.CHUNK) {` does not follow the gate block"
        if index($after, q(for (int c = 0; c < retry.size(); c += OdRestoreList.CHUNK) {)) < 0;
    } else { push @f, "A4.2 no `if (!work.isEmpty() && !AutoSweepNet.mayFetch(...)) {` gate block in sweepAuto"; }
    print "FAIL $_\n" for @f; print "ok A4.1/A4.2 sweepAuto gates its downloads, not its retries\n" unless @f;
  ' <<<"$sweep") || out="$out
FAIL A4.1 the perl check did not run"
  echo "$out"; case "$out" in *FAIL*) bad=1 ;; esac

  out=$(perl -0777 -ne '
    if (/startService\(new Intent\(this, UnarchiveService\.class\)\.putExtra\(UnarchiveService\.EXTRA_SWEEP, true\)\s*\.putExtra\(UnarchiveService\.EXTRA_BY_HAND, true\)\);/) {
      print "ok A4.3 the Install chip starts the sweep with EXTRA_BY_HAND\n";
    } else { print "FAIL A4.3 installPendingRow does not start the sweep with EXTRA_BY_HAND\n"; }
  ' <<<"$chip") || out="$out
FAIL A4.3 the perl check did not run"
  echo "$out"; case "$out" in *FAIL*) bad=1 ;; esac

  out=$(perl -0777 -ne '
    if (/EXTRA_BY_HAND|EXTRA_NET_REKICK/) { print "FAIL A4.4 kickAutoMaterialise sends EXTRA_BY_HAND or EXTRA_NET_REKICK\n"; }
    elsif (index($_, q{.putExtra(UnarchiveService.EXTRA_SWEEP, true);}) < 0) { print "FAIL A4.4 kickAutoMaterialise no longer starts the sweep\n"; }
    else { print "ok A4.4 the login kick starts the gated sweep\n"; }
  ' <<<"$kick") || out="$out
FAIL A4.4 the perl check did not run"
  echo "$out"; case "$out" in *FAIL*) bad=1 ;; esac

  out=$(perl -0777 -ne '
    my $s = $_; my @f;
    for my $w (q{final boolean byHand = intent != null && intent.getBooleanExtra(EXTRA_BY_HAND, false);},
               q{final boolean netRekick = intent != null && intent.getBooleanExtra(EXTRA_NET_REKICK, false);}) {
      push @f, "A4.5 onStartCommand lacks `$w`" if index($s, $w) < 0;
    }
    if ($s =~ /Thread sw = new Thread\(\(\) -> \{\s*if \(netRekick\) \{((?:(?!snapshotAppSeen|AppHeld\.refresh|reconcilePhantomKeepLines|wakeRestored).)*?)\breturn;\s*\}/s) {
      my $b = $1;
      push @f, "A4.5 the re-kick branch does not run sweepAutoJoined(false)" if index($b, q{sweepAutoJoined(false);}) < 0;
      push @f, "A4.5 the re-kick branch does not call workerDone()" if index($b, q{workerDone();}) < 0;
    } else { push @f, "A4.5 an EXTRA_NET_REKICK start does not return before snapshotAppSeen / AppHeld.refresh / the phantom reconcile / wakeRestored"; }
    my $call = q{try { sweepAutoJoined(byHand); }};
    my $n = () = $s =~ /\Q$call\E/g;
    push @f, "A4.5 `$call` occurs $n times, want 1" if $n != 1;
    my $snap = index($s, q{snapshotAppSeen});
    push @f, "A4.5 the switch-landing sweepAutoJoined(byHand) does not follow snapshotAppSeen"
      unless $snap >= 0 && index($s, $call) > $snap;
    print "FAIL $_\n" for @f; print "ok A4.5 a re-kick start runs only the sweep\n" unless @f;
  ' <<<"$start") || out="$out
FAIL A4.5 the perl check did not run"
  echo "$out"; case "$out" in *FAIL*) bad=1 ;; esac

  out=$(perl -0777 -ne '
    my $s = $_; my @f;
    my $net = index($s, q{boolean net = allowMetered ? hasInternetCtx(app) : onWifiCtx(app);});
    my $rk = q{AutoSweepNet.rekick(sweepNetUid, sweepNetPrev, uid, net)};
    my $n = () = $s =~ /\Q$rk\E/g;
    if ($n != 1 || $net < 0 || index($s, $rk) < $net) {
      push @f, "A4.6 the watcher does not call $rk once, after its net line";
    } elsif ($s !~ /if \(\Q$rk\E\) \{\s*try \{\s*app\.startServiceAsUser\(new android\.content\.Intent\(app, UnarchiveService\.class\)\s*\.putExtra\(UnarchiveService\.EXTRA_SWEEP, true\)\s*\.putExtra\(UnarchiveService\.EXTRA_NET_REKICK, true\), android\.os\.UserHandle\.of\(uid\)\);.*?\} catch \(Throwable \w+\) \{[^\n]*\}\s*\}\s*sweepNetUid = uid;\s*sweepNetPrev = net;/s) {
      push @f, "A4.6 the re-kick does not start EXTRA_SWEEP + EXTRA_NET_REKICK in UserHandle.of(uid) inside a try, then remember uid and net";
    }
    if ($s =~ /if \(uid < 0\) \{(.*?)\bcontinue;/s) {
      push @f, "A4.6 the gate tick (uid < 0) does not forget the uid (sweepNetUid = -1;)" if index($1, q{sweepNetUid = -1;}) < 0;
    } else { push @f, "A4.6 no `if (uid < 0) { ... continue;` block in the watcher"; }
    print "FAIL $_\n" for @f; print "ok A4.6 the backup watcher re-kicks the sweep on a no -> yes turn\n" unless @f;
  ' <<<"$watch") || out="$out
FAIL A4.6 the perl check did not run"
  echo "$out"; case "$out" in *FAIL*) bad=1 ;; esac

  out=$(perl -0777 -ne '
    my @f;
    for my $m (qw(hasInternetCtx onWifiCtx)) {
      push @f, "A4.6 ChooserActivity.$m is missing or private (the session service calls it)"
        unless /^    static boolean \Q$m\E\(Context ctx\) \{/m;
    }
    print "FAIL $_\n" for @f; print "ok A4.6 hasInternetCtx / onWifiCtx are package-private\n" unless @f;
  ' "$r/$CH/ChooserActivity.java") || out="$out
FAIL A4.6 the perl check did not run"
  echo "$out"; case "$out" in *FAIL*) bad=1 ;; esac
  return "$bad"
}

# check <root>: 0 pass, 1 a failed check, 3 the cases did not compile.
check() {
  local rc=0 crc
  cases "$1"; crc=$?
  [ "$crc" -eq 3 ] && return 3
  [ "$crc" -eq 0 ] || rc=1
  sources "$1" || rc=1
  return "$rc"
}

check "$ROOT" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <file name under $CH> <perl-expr> <check the mutant must fail>
  local d f out rc n
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/$CH"
  for n in AutoSweepNet.java UnarchiveService.java ProfileActivity.java ChooserActivity.java; do cp "$ROOT/$CH/$n" "$d/$CH/$n"; done
  f="$d/$CH/$2"
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed"; rm -rf "$d"; return 1; fi
  if cmp -s "$ROOT/$CH/$2" "$f"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  out=$(check "$d" 2>&1); rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if [ "$rc" -eq 3 ]; then echo "  BROKEN    $1 -- it did not compile"; return 1; fi
  if ! grep -qF -- "FAIL $4" <<<"$out"; then echo "  BROKEN    $1 -- it failed, but not '$4' (rc=$rc)"; return 1; fi
  echo "  convicted $1 (fails '$4')"
}
fails=0
mut "M1 byHand ignored" AutoSweepNet.java 's/if \(byHand\) return true;/if (false) return true;/' "A1 by hand, cellular" || fails=$((fails+1))
mut "M2 allowMetered ignored (always Wi-Fi)" AutoSweepNet.java 's/if \(allowMetered\) return hasInternet;/if (false) return hasInternet;/' "A1 switch on, cellular" || fails=$((fails+1))
mut "M3 a false gate returns early, skipping the retry loop" UnarchiveService.java 's/(app\(s\) wait for Wi-Fi \(Q042\)"\);\s*)work\.clear\(\);/${1}return;/' "A4.2 a false gate" || fails=$((fails+1))
mut "M4 rekick true on every tick while net" AutoSweepNet.java 's/return uid > 0 && uid == prevUid && !prevNet && net;/return uid > 0 && net;/' "A3 rekick(10,true,10,true)" || fails=$((fails+1))
mut "M5 the chip's EXTRA_BY_HAND removed" ProfileActivity.java 's/\s*\.putExtra\(UnarchiveService\.EXTRA_BY_HAND, true\)//' "A4.3" || fails=$((fails+1))
mut "M6 meteredAllowed(\"\") true" AutoSweepNet.java 's/return reply != null && "1"\.equals\(reply\.trim\(\)\);/return reply != null && (reply.trim().isEmpty() || "1".equals(reply.trim()));/' 'A2 meteredAllowed("")' || fails=$((fails+1))
mut "M7 a re-kick start falls through to the switch-landing" UnarchiveService.java 's/(finally \{ workerDone\(\); \}\n)\s*return;\n(\s*\}\n)/$1$2/' "A4.5" || fails=$((fails+1))
mut "M8 the login kick made by hand" ChooserActivity.java 's/(\.putExtra\(UnarchiveService\.EXTRA_SWEEP, true\));(\s*if \(restoredOk)/$1.putExtra(UnarchiveService.EXTRA_BY_HAND, true);$2/' "A4.4" || fails=$((fails+1))
mut "M9 the gate tick keeps the uid" ChooserActivity.java 's/^[ \t]*sweepNetUid = -1;[^\n]*\n//m' "A4.6" || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
