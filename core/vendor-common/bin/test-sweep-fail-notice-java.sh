#!/usr/bin/env bash
# test-sweep-fail-notice-java.sh [--mutate] -- NWP-20261203-17: an Auto sweep pass with failed apps says how many.
# Backlog section C, "When every app in an Auto sweep fails, the user is not told: ..." (Chester, husky 0.5.55, ticket
# NW-222be2ee470a, 2026-11-12). DECIDED by Chester, 2026-11-12, "Notice with a count": any pass with at least one app
# that fetch-failed, install-failed or ended in error posts one notice with the count, and a tap opens Your apps; a
# later pass that lands apps with none failing clears it. The landing card is unchanged. The words are DRAFTS for
# Chester (mockup gate). NWP-20261207-04 (decision 2026-11-12, answer 4 (2)): the notice carries a "Try again" action
# (draft words) that starts the sweep by hand, with the intent "Install pending apps now" sends. NWP-20261208-17:
# backlog section C, "The Auto sweep's failed-apps notice counts an app the user installed by hand while the sweep
# ran, ..." (Chester, 0.5.58, 2026-11-17): when the pass ends, the failed apps are re-checked with hasInstalledCode,
# and one installed meanwhile counts as landed, not failed.
# Compiles the chooser's pure SweepFailNotice and SweepOutcome with core/chooser/tests/sweep-fail-notice ALONE and
# EXECUTES the cases (C1-C8), then checks the REAL UnarchiveService.sweepAuto and onStartCommand over their code with
# comments dropped (S1-S9):
#   C1  hard() is true for fetch-failed, install-failed and error only, over all ten SweepOutcome.TOKENS, null and "x".
#   C2  action(total, done, hardFailed): POST when total > 0 and hardFailed > 0; CANCEL when hardFailed == 0 and
#       done > 0; KEEP otherwise.
#   C3  title(): null for nothing failed, "1 app could not be fetched", "<f> of <t> apps could not be fetched"; TEXT.
#   C4  NOTICE_ID is 0x0A2F.
#   C5  offersRetry() is true for POST only; RETRY_REQUEST differs from NOTICE_ID, 0x0A2D and 0x0A2E; ACTION_RETRY
#       starts with "com.nowhere.chooser.action.".
#   C6  RETRY is "Try again".
#   C7  stillMissing(failed, installed): the failed packages not installed, in input order, each once, nulls dropped;
#       a test that throws counts the package as missing; a null list is an empty one.
#   C8  afterRecheck(total, done, ranFailed, missing): action(total, done + (ranFailed - missing), missing); the only
#       failure installed by hand is CANCEL.
#   S1  `java.util.List<String> hardFailedPkgs = new ArrayList<>();` once, the line after `int done = 0, failed = 0;`;
#       the guarded `hardFailedPkgs.add(pkg);` once, directly after the done++ statement; no `hardFailed++`.
#   S2  SweepFailNotice.afterRecheck(work.size(), done, hardFailedPkgs.size(), hardFailed) once, after
#       ACTION_SWEEP_DONE and the OlderCopy end block; no SweepFailNotice.action( call left in sweepAuto.
#   S3  the POST arm notifies SweepFailNotice.NOTICE_ID with title(hardFailed, work.size()) and TEXT, a FLAG_IMMUTABLE
#       PendingIntent that opens Your apps (LandingLine.EXTRA_OPEN = OPEN_YOUR_APPS), and setAutoCancel(true).
#   S4  the CANCEL arm calls nm.cancel(SweepFailNotice.NOTICE_ID).
#   S5  the new block holds no DaemonSocket, pkg, work.get or getApplicationLabel: counts only.
#   S6  the POST arm holds one .addAction(: getForegroundService(this, SweepFailNotice.RETRY_REQUEST, ...) with
#       FLAG_IMMUTABLE, of an intent with .setAction(SweepFailNotice.ACTION_RETRY), EXTRA_SWEEP and EXTRA_BY_HAND and
#       none of EXTRA_RESUME, EXTRA_NET_REKICK, EXTRA_WAKE, EXTRA_PKG, EXTRA_ID; the label is SweepFailNotice.RETRY.
#   S7  the action is guarded by SweepFailNotice.offersRetry(act) in its own try before the notify; the CANCEL arm
#       holds no addAction.
#   S8  onStartCommand compares SweepFailNotice.ACTION_RETRY with intent.getAction() once and logs the fixed line,
#       after the extras are read and before the sweep branch.
#   S9  SweepFailNotice.stillMissing(hardFailedPkgs, p -> hasInstalledCode(p)) once, after the OlderCopy block and
#       before `SweepFailNotice.Act act =`; `int hardFailed = stillFailed.size();` between them; the "installed
#       meanwhile" log line holds counts only (no pkg, `p +` or stillFailed.get).
#
# It needs a JDK, and it FAILS when there is none. javac/java come from PATH, then the build VM's prebuilt JDK 21.
# --mutate re-runs it against broken copies of SweepFailNotice and UnarchiveService (M1-M23), each of which must FAIL a
# named check. A mutant that does not apply (INERT) or does not compile (BROKEN) counts as a failure, never a pass.
#
#   bash test-sweep-fail-notice-java.sh            # the cases and the source checks
#   bash test-sweep-fail-notice-java.sh --mutate   # ... plus the mutants
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
  echo "test-sweep-fail-notice-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
command -v perl >/dev/null 2>&1 || { echo "test-sweep-fail-notice-java: FAIL -- no perl; this suite did NOT run" >&2; exit 2; }
# ONE temp root: every class dir and mutant tree lives under it, and the trap removes it however this ends.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser
CASES=$ROOT/core/chooser/tests/sweep-fail-notice/SweepFailNoticeCases.java

# cases <root>: compile <root>'s SweepFailNotice and SweepOutcome with the cases into a fresh dir and run them.
cases() {
  local d
  d=$(mktemp -d -p "$W")
  "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d" "$1/$CH/SweepFailNotice.java" "$1/$CH/SweepOutcome.java" \
    "$CASES" || return 3
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d" com.nowhere.chooser.SweepFailNoticeCases
}

# code <file> [<signature line>]: the method from its signature to its closing `    }` (the whole file with no
# signature), with whole-line comments dropped and trailing `//` comments stripped (a `//` inside a string is kept).
code() {
  perl -e '
    my ($f, $sig) = @ARGV; open(my $h, "<", $f) or die "$f: $!";
    my $in = defined($sig) ? 0 : 1;
    while (my $l = <$h>) {
      if (!$in) { next unless index($l, $sig) == 0; $in = 1; }
      last if defined($sig) && $l =~ /^    \}$/;
      next if $l =~ m{^\s*(//|\*|/\*)};
      $l =~ s{^((?:[^"/\n]|"(?:[^"\\\n]|\\.)*"|/(?![/*]))*)//.*$}{$1};
      print $l;
    }' "$@"
}

# pin <id> <what> <perl body over $c, exit 0 on pass> <<<"$code": one source check.
pin() {
  if perl -0e 'my $c = do { local $/; <STDIN> }; '"$3"; then echo "ok $1 $2"; else echo "FAIL $1 $2"; return 1; fi
}

# sources <root>: S1-S7 and S9 over <root>'s UnarchiveService.sweepAuto, S8 over its onStartCommand.
sources() {
  local r=$1 sweep bad=0
  sweep=$(code "$r/$CH/UnarchiveService.java" "    private void sweepAuto(boolean byHand) {")
  if [ -z "$sweep" ]; then echo "FAIL S1 sweepAuto not found"; return 1; fi
  pin S1 "the failed apps are listed once, directly after the done++ statement, for a NEXT step only" '
    my $n = () = $c =~ /\bjava\.util\.List<String> hardFailedPkgs = new ArrayList<>\(\);/g; exit 1 unless $n == 1;
    exit 1 unless $c =~ /int done = 0, failed = 0;[ \t]*\n[ \t]*java\.util\.List<String> hardFailedPkgs = new ArrayList<>\(\);/;
    my $i = () = $c =~ /if \(!ok && step == SweepBusy\.Step\.NEXT && SweepFailNotice\.hard\(end\)\) hardFailedPkgs\.add\(pkg\);/g;
    exit 1 unless $i == 1;
    my $p = () = $c =~ /hardFailedPkgs\.add\(/g; exit 1 unless $p == 1;
    exit 1 if $c =~ /hardFailed\+\+/;
    exit($c =~ /if \(ok\) done\+\+; else if \(step == SweepBusy\.Step\.NEXT\) failed\+\+;\s*if \(!ok && step == SweepBusy\.Step\.NEXT && SweepFailNotice\.hard\(end\)\) hardFailedPkgs\.add\(pkg\);/ ? 0 : 1);' <<<"$sweep" || bad=1
  pin S2 "the action is decided once, at the end, after ACTION_SWEEP_DONE and the older-copy line, on the re-check" '
    my $call = "SweepFailNotice.afterRecheck(work.size(), done, hardFailedPkgs.size(), hardFailed)";
    my $n = () = $c =~ /\Q$call\E/g; exit 1 unless $n == 1;
    exit 1 if index($c, "SweepFailNotice.action(") >= 0;
    my $a = index($c, $call);
    my $o = rindex($c, "olderMetas"); my $on = index($c, "nm.notify(OlderCopy.NOTICE_ID");
    my $b = index($c, "sendBroadcast(new Intent(ACTION_SWEEP_DONE)");
    exit 1 if $o < 0 || $on < 0 || $b < 0;
    exit(($a > $o && $a > $on && $a > $b) ? 0 : 1);' <<<"$sweep" || bad=1
  pin S3 "the POST arm posts the count on its own id and opens Your apps" '
    my $s = index($c, "SweepFailNotice.Act act ="); exit 1 if $s < 0;
    my $k = substr($c, $s);
    exit 1 if index($k, "OlderCopy.NOTICE_ID") >= 0;
    $k =~ /if \(nm != null && act == SweepFailNotice\.Act\.POST\) \{(.*?)\n\s*\} else if/s or exit 1;
    my $p = $1;
    for my $w ("nm.notify(SweepFailNotice.NOTICE_ID,", ".setContentTitle(SweepFailNotice.title(hardFailed, work.size()))",
               ".setContentText(SweepFailNotice.TEXT)", "bigText(SweepFailNotice.TEXT)",
               ".putExtra(LandingLine.EXTRA_OPEN, LandingLine.OPEN_YOUR_APPS)",
               "getActivity(this, SweepFailNotice.NOTICE_ID,", "FLAG_IMMUTABLE", ".setContentIntent(pi)",
               ".setAutoCancel(true)") {
      exit 1 if index($p, $w) < 0;
    }
    exit 0;' <<<"$sweep" || bad=1
  pin S4 "the CANCEL arm removes the notice" '
    my $s = index($c, "SweepFailNotice.Act act ="); exit 1 if $s < 0;
    my $k = substr($c, $s);
    exit($k =~ /else if \(nm != null && act == SweepFailNotice\.Act\.CANCEL\) \{\s*nm\.cancel\(SweepFailNotice\.NOTICE_ID\);\s*\}/ ? 0 : 1);' <<<"$sweep" || bad=1
  pin S5 "the new block carries counts only: no daemon call, no package, no label" '
    my $s = index($c, "SweepFailNotice.Act act ="); exit 1 if $s < 0;
    my $k = substr($c, $s);
    exit 1 if $k =~ /DaemonSocket|\bpkg\b|work\.get|getApplicationLabel/;
    exit 0;' <<<"$sweep" || bad=1
  pin S6 "the POST arm carries one Try again action: a foreground-service start of the by-hand sweep, nothing else" '
    my $s = index($c, "SweepFailNotice.Act act ="); exit 1 if $s < 0;
    my $k = substr($c, $s);
    $k =~ /if \(nm != null && act == SweepFailNotice\.Act\.POST\) \{(.*?)\n\s*\} else if/s or exit 1;
    my $p = $1;
    my $n = () = $p =~ /\.addAction\(/g; exit 1 unless $n == 1;
    $p =~ /\bIntent retryTap = new Intent\(this, UnarchiveService\.class\)([^;]*);/ or exit 1;
    my $i = $1;
    for my $w (".setAction(SweepFailNotice.ACTION_RETRY)", ".putExtra(EXTRA_SWEEP, true)", ".putExtra(EXTRA_BY_HAND, true)") {
      exit 1 if index($i, $w) < 0;
    }
    exit 1 if $i =~ /EXTRA_RESUME|EXTRA_NET_REKICK|EXTRA_WAKE|EXTRA_PKG|EXTRA_ID/;
    $p =~ /android\.app\.PendingIntent rpi = android\.app\.PendingIntent\.getForegroundService\(this,\s*SweepFailNotice\.RETRY_REQUEST,\s*retryTap,([^;]*);/ or exit 1;
    exit 1 if index($1, "FLAG_IMMUTABLE") < 0;
    exit($p =~ /\.addAction\(new Notification\.Action\.Builder\(\(android\.graphics\.drawable\.Icon\) null,\s*SweepFailNotice\.RETRY, rpi\)\.build\(\)\);/ ? 0 : 1);' <<<"$sweep" || bad=1
  pin S7 "the action is guarded by offersRetry(act) in its own try, and the CANCEL arm holds no action" '
    my $s = index($c, "SweepFailNotice.Act act ="); exit 1 if $s < 0;
    my $k = substr($c, $s);
    $k =~ /if \(nm != null && act == SweepFailNotice\.Act\.POST\) \{(.*?)\n\s*\} else if/s or exit 1;
    my $p = $1;
    $p =~ /if \(SweepFailNotice\.offersRetry\(act\)\) \{\s*try \{(.*?)\n\s*\} catch \(Throwable t\) \{/s or exit 1;
    exit 1 if index($1, ".addAction(") < 0;
    exit 1 unless $p =~ /\} catch \(Throwable t\) \{[^}]*\}\s*\}\s*nm\.notify\(SweepFailNotice\.NOTICE_ID, b\.build\(\)\);/;
    $k =~ /else if \(nm != null && act == SweepFailNotice\.Act\.CANCEL\) \{(.*?)\n\s*\}/s or exit 1;
    exit(index($1, "addAction") < 0 ? 0 : 1);' <<<"$sweep" || bad=1
  pin S9 "the failed apps are re-checked with hasInstalledCode after the older-copy block and before the action; the log line holds counts only" '
    my $call = "SweepFailNotice.stillMissing(hardFailedPkgs, p -> hasInstalledCode(p))";
    my $n = () = $c =~ /\Q$call\E/g; exit 1 unless $n == 1;
    my $r = index($c, $call); my $act = index($c, "SweepFailNotice.Act act =");
    my $o = rindex($c, "olderMetas"); my $on = index($c, "nm.notify(OlderCopy.NOTICE_ID");
    exit 1 if $act < 0 || $o < 0 || $on < 0;
    exit 1 unless $r > $o && $r > $on && $r < $act;
    my $h = index($c, "int hardFailed = stillFailed.size();");
    exit 1 unless $h > $r && $h < $act;
    $c =~ /(android\.util\.Log\.i\([^;]*installed meanwhile[^;]*;)/s or exit 1;
    exit 1 if $1 =~ /\bpkg\b|\bp \+|stillFailed\.get/;
    exit 0;' <<<"$sweep" || bad=1
  local start
  start=$(code "$r/$CH/UnarchiveService.java" "    public int onStartCommand(Intent intent, int flags, int startId) {")
  pin S8 "onStartCommand logs a start from the notice once, a fixed line, before the sweep branch" '
    my $l = q{if (intent != null && SweepFailNotice.ACTION_RETRY.equals(intent.getAction()))};
    my $g = q{android.util.Log.i("NowhereChooser", "#130 sweep started by hand from the failed-apps notice (NWP-20261207-04)");};
    my $n = () = $c =~ /\Q$l\E\s*\Q$g\E/g; exit 1 unless $n == 1;
    my $a = index($c, $l); my $w = index($c, "intent.getStringArrayExtra(EXTRA_WAKE)"); my $sw = index($c, "if (sweep) {");
    exit(($w >= 0 && $sw >= 0 && $a > $w && $a < $sw) ? 0 : 1);' <<<"$start" || bad=1
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
mut() { # mut <label> <path under the root> <perl-expr> <check the mutant must fail>
  local d f out rc n
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/$CH"
  for n in "$CH/SweepFailNotice.java" "$CH/SweepOutcome.java" "$CH/UnarchiveService.java"; do
    cp "$ROOT/$n" "$d/$n"
  done
  f="$d/$2"
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed"; rm -rf "$d"; return 1; fi
  if cmp -s "$ROOT/$2" "$f"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  out=$(check "$d" 2>&1); rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if [ "$rc" -eq 3 ]; then echo "  BROKEN    $1 -- it did not compile"; return 1; fi
  if ! grep -qF -- "FAIL $4" <<<"$out"; then echo "  BROKEN    $1 -- it failed, but not '$4' (rc=$rc)"; return 1; fi
  echo "  convicted $1 (fails '$4')"
}
S=$CH/SweepFailNotice.java
U=$CH/UnarchiveService.java
fails=0
mut "M1 hard() also true for needs-play" "$S" 's/ "error"\.equals\(outcome\);/ "error".equals(outcome) || "needs-play".equals(outcome);/' C1 || fails=$((fails+1))
mut "M2 POST only when nothing landed (the old all-failed rule)" "$S" 's/if \(total > 0 && hardFailed > 0\) return/if (total > 0 && hardFailed > 0 && done == 0) return/' "C2 action(5, 3, 2)" || fails=$((fails+1))
mut "M3 POST only when every app failed" "$S" 's/if \(total > 0 && hardFailed > 0\) return/if (total > 0 && hardFailed == total) return/' "C2 action(3, 0, 2)" || fails=$((fails+1))
mut "M4 the CANCEL arm of action removed" "$S" 's/^[ \t]*if \(hardFailed == 0 && done > 0\) return Act\.CANCEL;\n//m' C2 || fails=$((fails+1))
mut "M5 title swaps failed and total" "$S" 's/return failed \+ " of " \+ total/return total + " of " + failed/' "C3 title(2, 5)" || fails=$((fails+1))
mut "M6 the add deleted" "$U" 's/^[ \t]*if \(!ok && step == SweepBusy\.Step\.NEXT && SweepFailNotice\.hard\(end\)\) hardFailedPkgs\.add\(pkg\);\n//m' S1 || fails=$((fails+1))
mut "M7 the add loses its NEXT guard" "$U" 's/if \(!ok && step == SweepBusy\.Step\.NEXT && SweepFailNotice\.hard\(end\)\) hardFailedPkgs/if (!ok && SweepFailNotice.hard(end)) hardFailedPkgs/' S1 || fails=$((fails+1))
mut "M8 the action call deleted" "$U" 's/SweepFailNotice\.Act act = SweepFailNotice\.afterRecheck\(work\.size\(\), done, hardFailedPkgs\.size\(\), hardFailed\);/SweepFailNotice.Act act = SweepFailNotice.Act.KEEP;/' S2 || fails=$((fails+1))
mut "M9 notify uses OlderCopy.NOTICE_ID" "$U" 's/nm\.notify\(SweepFailNotice\.NOTICE_ID,/nm.notify(OlderCopy.NOTICE_ID,/' S3 || fails=$((fails+1))
mut "M10 the cancel call deleted" "$U" 's/nm\.cancel\(SweepFailNotice\.NOTICE_ID\);//' S4 || fails=$((fails+1))
mut "M11 the PendingIntent drops EXTRA_OPEN" "$U" 's/(SweepFailNotice\.Act act = .*?)\s*\.putExtra\(LandingLine\.EXTRA_OPEN, LandingLine\.OPEN_YOUR_APPS\)/$1/s' S3 || fails=$((fails+1))
mut "M12 offersRetry also true for KEEP" "$S" 's/return act == Act\.POST;/return act == Act.POST || act == Act.KEEP;/' "C5 offersRetry(KEEP)" || fails=$((fails+1))
mut "M13 RETRY_REQUEST collides with NOTICE_ID" "$S" 's/RETRY_REQUEST = 0x0A30;/RETRY_REQUEST = 0x0A2F;/' "C5 RETRY_REQUEST differs from 0xa2f" || fails=$((fails+1))
mut "M14 the retry intent drops EXTRA_BY_HAND" "$U" 's/\.putExtra\(EXTRA_SWEEP, true\)\.putExtra\(EXTRA_BY_HAND, true\);/.putExtra(EXTRA_SWEEP, true);/' S6 || fails=$((fails+1))
mut "M15 the retry intent drops EXTRA_SWEEP" "$U" 's/\.putExtra\(EXTRA_SWEEP, true\)\.putExtra\(EXTRA_BY_HAND, true\);/.putExtra(EXTRA_BY_HAND, true);/' S6 || fails=$((fails+1))
mut "M16 getService on FG_ID + 2 (the Stop action's PendingIntent)" "$U" 's/PendingIntent\.getForegroundService\(this,(\s*)SweepFailNotice\.RETRY_REQUEST,/PendingIntent.getService(this,$1FG_ID + 2,/' S6 || fails=$((fails+1))
mut "M17 the action moved into the CANCEL arm" "$U" 's/\n([ \t]*)(b\.addAction\(new Notification\.Action\.Builder\(.*?\)\.build\(\)\);)(.*?nm\.cancel\(SweepFailNotice\.NOTICE_ID\);)/$3\n$1$2/s' S7 || fails=$((fails+1))
mut "M18 stillMissing ignores the predicate" "$S" 's/if \(!in\) out\.add\(p\);/out.add(p);/' C7 || fails=$((fails+1))
mut "M19 afterRecheck drops the healed apps" "$S" 's/return action\(total, done \+ healed, missing\);/return action(total, done, missing);/' "C8 afterRecheck(1, 0, 1, 0)" || fails=$((fails+1))
mut "M20 afterRecheck counts ranFailed, not missing" "$S" 's/return action\(total, done \+ healed, missing\);/return action(total, done + healed, ranFailed);/' "C8 afterRecheck(3, 0, 2, 0)" || fails=$((fails+1))
mut "M21 a throwing test counts as installed" "$S" 's/catch \(Throwable t\) \{ in = false; \}/catch (Throwable t) { in = true; }/' C7 || fails=$((fails+1))
mut "M22 the re-check deleted" "$U" 's/SweepFailNotice\.stillMissing\(hardFailedPkgs, p -> hasInstalledCode\(p\)\)/hardFailedPkgs/' S9 || fails=$((fails+1))
mut "M23 the act line back to action()" "$U" 's/SweepFailNotice\.afterRecheck\(work\.size\(\), done, hardFailedPkgs\.size\(\), hardFailed\)/SweepFailNotice.action(work.size(), done, hardFailed)/' S2 || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
