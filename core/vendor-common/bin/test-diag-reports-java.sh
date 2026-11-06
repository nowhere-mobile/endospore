#!/usr/bin/env bash
# test-diag-reports-java.sh [--mutate] -- NWP-20261126-02: a beta profile's scheduled diagnostic reports (slice 2 of
# the backlog row "A beta profile has no way to send a diagnostic report on a schedule: every report is sent by hand,
# ..."; decision 2026-11-02 in docs/product-decisions.md, NWP-20261102-29).
# Compiles the chooser's pure DiagReports (java.lang / java.util only, no Android SDK) with
# core/chooser/tests/diag-reports' cases ALONE and EXECUTES them, then checks the REAL call sites over their code with
# comments dropped, so a comment can neither satisfy nor trip a check:
#   D1 offered: only "OFFERED 1 ...".   D2 armedOff: only "OFFERED 1 ON 0".
#   D3 newTag is "t-" + 10 of [a-z2-7], an all-digit body drawn again; tagOk takes that exact shape.
#   D4 due: never offline; never within 6 h of the last send; Wi-Fi sends; mobile only after 12 h without Wi-Fi,
#      counted from onSince when no Wi-Fi was seen.
#   D5 status's two keys (tester_tag, report_kind scheduled / by_hand) and the file parsers.
#   D6 runJob over a recording fake Port: OFFERED 0 cancels and sends nothing; no status reply skips the run and
#      keeps the schedule; an Off or a stop during the status request sends nothing; an Off tapped during a send
#      waits for it (the consent lock); only an OK records SENT_FILE; no retry.
#   D7 switchOn / switchOff / arm, and SWITCH: one transition at a time in tap order, so a slow older Off cannot
#      cancel the job after a newer On.
#   S1 showReportIssue asks DIAG-SUMMARY status and builds its Switch and title only inside `if (DiagReports.offered(`;
#      its transitions go through DiagReports.SWITCH, never a thread of their own.
#   S2 reportRequestJson takes reportStatus(this) and adds DiagReports.status(tag, false) only under an `if` that holds
#      both DiagReports.optedIn( and DiagReports.tagOk(.
#   S3 DiagReports.runJob asks status and returns on notOffered / !offered before its one p.report(; onStartJob runs
#      it with the job's stop flag and onStopJob sets that flag; sendScheduled sends one REPORT-ISSUE with
#      ProfileActivity.reportStatus and the run's keys, no note, no preview, no ticket row, no loop.
#   S4 the manifest declares .DiagReportJob with BIND_JOB_SERVICE, not exported.
#   S5 sweepAuto's first statement is `try { DiagReportJob.arm(this); }`.
#   S6 schedule() is one periodic 1 h job, NETWORK_TYPE_ANY, not persisted.
#
# It needs a JDK, and it FAILS when there is none: a Java suite that skips without one would read green on a runner
# that never ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
# --mutate re-runs it against broken copies, each of which must FAIL a named check. A mutant that does not apply
# (INERT) or does not compile (BROKEN) counts as a failure, never a pass.
#
#   bash test-diag-reports-java.sh            # the cases and the source checks
#   bash test-diag-reports-java.sh --mutate   # ... plus the mutants M1-M19
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
  echo "test-diag-reports-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
command -v perl >/dev/null 2>&1 || { echo "test-diag-reports-java: FAIL -- no perl; this suite did NOT run" >&2; exit 2; }
# ONE temp root: every class dir and mutant tree lives under it, and the trap removes it however this ends.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser
MF=core/chooser/AndroidManifest.xml
CASES=$ROOT/core/chooser/tests/diag-reports/DiagReportsCases.java
FILES="$CH/DiagReports.java $CH/DiagReportJob.java $CH/ProfileActivity.java $CH/UnarchiveService.java $MF"

# cases <root>: compile <root>'s DiagReports with the cases into a fresh dir and run them (D1-D7).
cases() {
  local d
  [ -f "$1/$CH/DiagReports.java" ] || { echo "FAIL D1-D7 $CH/DiagReports.java does not exist"; return 1; }
  d=$(mktemp -d -p "$W")
  "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d" "$1/$CH/DiagReports.java" "$CASES" || return 3
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d" com.nowhere.chooser.DiagReportsCases
}

# code <file> <signature line>: the method from its signature to its closing `    }`, with whole-line comments dropped
# and trailing `//` comments stripped (a `//` inside a string literal is kept).
code() {
  perl -e '
    my ($f, $sig) = @ARGV; open(my $h, "<", $f) or exit 0;
    my $in = 0;
    while (my $l = <$h>) {
      if (!$in) { next unless index($l, $sig) == 0; $in = 1; }
      last if $in && $l =~ /^    \}$/;
      next if $l =~ m{^\s*(//|\*|/\*)};
      $l =~ s{^((?:[^"/\n]|"(?:[^"\\\n]|\\.)*"|/(?![/*]))*)//.*$}{$1};
      print $l;
    }' "$1" "$2"
}

# verdict <label> <perl output>: print it; 1 when it holds a FAIL or is empty (the perl did not run).
verdict() {
  if [ -z "$2" ]; then echo "FAIL $1 the perl check did not run"; return 1; fi
  echo "$2"
  case "$2" in *FAIL*) return 1 ;; esac
  return 0
}

# sources <root>: S1-S6 over <root>'s files.
sources() {
  local r=$1 rep req run start stopj send sched sweep bad=0 out
  rep=$(code "$r/$CH/ProfileActivity.java" "    private void showReportIssue() {")
  req=$(code "$r/$CH/ProfileActivity.java" "    private String reportRequestJson(String note, boolean preview) {")
  run=$(code "$r/$CH/DiagReports.java" "    static String runJob(Port p, AtomicBoolean stopped) {")
  start=$(code "$r/$CH/DiagReportJob.java" "    @Override public boolean onStartJob(final JobParameters params) {")
  stopj=$(code "$r/$CH/DiagReportJob.java" "    @Override public boolean onStopJob(JobParameters params) {")
  send=$(code "$r/$CH/DiagReportJob.java" "    private static String sendScheduled(Context ctx, Map<String, String> extra) {")
  sched=$(code "$r/$CH/DiagReportJob.java" "    static void schedule(Context ctx) {")
  sweep=$(code "$r/$CH/UnarchiveService.java" "    private void sweepAuto(boolean byHand) {")

  out=$(perl -0777 -ne '
    my $s = $_; my @f;
    push @f, "S1 showReportIssue not found" unless length $s;
    push @f, "S1 showReportIssue does not send DIAG-SUMMARY status"
      if index($s, q{sendDaemon("DIAG-SUMMARY\nstatus\n")}) < 0;
    my $sw = () = $s =~ /new android\.widget\.Switch\(/g;
    my $ti = () = $s =~ /DiagReports\.TITLE/g;
    if ($s =~ /if \(DiagReports\.offered\(\w+\)\) (\{(?:[^{}]++|(?1))*\})/s) {
      my $b = $1;
      my $bsw = () = $b =~ /new android\.widget\.Switch\(/g;
      my $bti = () = $b =~ /DiagReports\.TITLE/g;
      push @f, "S1 no Switch inside the offered block" if $bsw < 1;
      push @f, "S1 a Switch is built outside the offered block ($sw in the method, $bsw in the block)" if $sw != $bsw;
      push @f, "S1 DiagReports.TITLE is not only inside the offered block" if $bti < 1 || $ti != $bti;
      for my $w (q!DiagReports.SWITCH.execute(() -> {!, q{final boolean ok = DiagReports.switchOn(port);},
                 q{DiagReports.SWITCH.execute(() -> DiagReports.switchOff(port));}, q{DiagReports.RESET},
                 q{DiagReports.SUBLINE}, q{DiagReports.ON_FAILED}) {
        push @f, "S1 the offered block lacks $w" if index($b, $w) < 0;
      }
      push @f, "S1 the offered block starts a thread of its own (a transition off SWITCH)" if $b =~ /new Thread\(/;
      push @f, "S1 the offered block sends DIAG-SUMMARY on / off itself" if $b =~ /DIAG-SUMMARY\\no(n|ff)/;
      push @f, "S1 the offered block logs the tag" if $b =~ /Log\.\w+\([^;]*\btag\b/;
    } else { push @f, "S1 no `if (DiagReports.offered(<reply>)) {` block in showReportIssue"; }
    print "FAIL $_\n" for @f; print "ok S1 showReportIssue draws the switch only when offered\n" unless @f;
  ' <<<"$rep")
  verdict S1 "$out" || bad=1

  out=$(perl -0777 -ne '
    my $s = $_; my @f;
    push @f, "S2 reportRequestJson does not take reportStatus(this)"
      if index($s, q{org.json.JSONObject st = reportStatus(this);}) < 0;
    my $n = () = $s =~ /DiagReports\.status\(/g;
    push @f, "S2 reportRequestJson calls DiagReports.status( $n times, want 1" if $n != 1;
    if ($s =~ /if \(([^\n]*)\) \{\s*for \(java\.util\.Map\.Entry<String, String> e : DiagReports\.status\(tag, false\)\.entrySet\(\)\)/) {
      my $c = $1;
      push @f, "S2 the tag is added without DiagReports.optedIn( (the switch off still tags)" if index($c, q{DiagReports.optedIn(}) < 0;
      push @f, "S2 the tag is added without DiagReports.tagOk(" if index($c, q{DiagReports.tagOk(tag)}) < 0;
      push @f, "S2 the condition is not a conjunction" if $c =~ /\|\|/;
    } else { push @f, "S2 DiagReports.status(tag, false) is not added under an `if (...) {`"; }
    print "FAIL $_\n" for @f; print "ok S2 a by-hand report is tagged only when the opt-in says on\n" unless @f;
  ' <<<"$req")
  verdict S2 "$out" || bad=1

  out=$(perl -0777 -ne '
    my ($s, $j, $k, $t) = split /\n=====PART=====\n/, $_, 4; my @f;
    push @f, "S3 DiagReports.runJob, onStartJob, onStopJob or sendScheduled not found"
      unless length $s && length $j && length $k && length $t;
    my $opt = index($s, q{if (!optedIn(p.read(OPT_FILE))) { p.cancel(); return R_OFF; }});
    my $st = index($s, q{String st = p.status();});
    my $no = index($s, q{if (notOffered(st)) { p.cancel(); return R_NOT_OFFERED; }});
    my $off = index($s, q{if (!offered(st)) return R_UNAVAILABLE;});
    my $lk = index($s, q!synchronized (LOCK) {!);
    my $snd = index($s, q{p.report(});
    push @f, "S3 runJob has no `if (!offered(st)) return R_UNAVAILABLE;`" if $off < 0;
    push @f, "S3 runJob has no notOffered cancel" if $no < 0;
    push @f, "S3 the opt-in, the status read and the OFFERED checks do not all sit before the lock and p.report("
      unless $opt >= 0 && $st > $opt && $no > $st && $off > $no && $lk > $off && $snd > $lk;
    my $n = () = $s =~ /p\.report\(/g;
    push @f, "S3 runJob calls p.report( $n times, want 1" if $n != 1;
    push @f, "S3 runJob retries (a loop)" if $s =~ /\b(while|do|for)\b/;
    push @f, "S3 onStartJob does not run DiagReports.runJob with its stop flag"
      unless index($j, q{stop = s;}) >= 0 && index($j, q{DiagReports.runJob(new AndroidPort(ctx), s)}) >= 0;
    push @f, "S3 onStopJob does not set the stop flag" unless $k =~ /if \(s != null\) s\.set\(true\);/;
    push @f, "S3 sendScheduled does not send REPORT-ISSUE through DaemonSocket.roundTrip"
      if index($t, q{reply = DaemonSocket.roundTrip("REPORT-ISSUE\n" + o.toString() + "\n", 120000);}) < 0;
    push @f, "S3 sendScheduled does not add the run\x27s keys" if index($t, q{for (Map.Entry<String, String> e : extra.entrySet()) st.put(}) < 0;
    push @f, "S3 sendScheduled does not take ProfileActivity.reportStatus(ctx)" if index($t, q{ProfileActivity.reportStatus(ctx)}) < 0;
    push @f, "S3 sendScheduled sends a note or a preview"
      unless index($t, q{o.put("note", "");}) >= 0 && index($t, q{o.put("preview", false);}) >= 0;
    push @f, "S3 sendScheduled adds a ticket-table row" if $t =~ /appendTicket|ticketTable|TICKET/;
    push @f, "S3 sendScheduled retries (a loop)" if $t =~ /\b(while|do)\b/;
    print "FAIL $_\n" for @f; print "ok S3 the job reads OFFERED before its one REPORT-ISSUE send\n" unless @f;
  ' <<<"$run
=====PART=====
$start
=====PART=====
$stopj
=====PART=====
$send")
  verdict S3 "$out" || bad=1

  out=$(perl -0777 -ne '
    my @f;
    my $n = () = /android:name="\.DiagReportJob"/g;
    push @f, "S4 the manifest names .DiagReportJob $n times, want 1" if $n != 1;
    push @f, "S4 the manifest does not declare .DiagReportJob with BIND_JOB_SERVICE, not exported"
      unless /<service android:name="\.DiagReportJob"\s+android:permission="android\.permission\.BIND_JOB_SERVICE"\s+android:exported="false"\s*\/>/;
    print "FAIL $_\n" for @f; print "ok S4 the manifest declares the JobService\n" unless @f;
  ' "$r/$MF")
  verdict S4 "$out" || bad=1

  out=$(perl -0777 -ne '
    if (/\A    private void sweepAuto\(boolean byHand\) \{\n\s*try \{ DiagReportJob\.arm\(this\); \}\n\s*catch \(Throwable t\) \{ android\.util\.Log\.w\([^\n]*\); \}\n/) {
      print "ok S5 sweepAuto arms the diagnostic reports first\n";
    } else { print "FAIL S5 the first statement of sweepAuto is not `try { DiagReportJob.arm(this); }` with a logging catch\n"; }
  ' <<<"$sweep")
  verdict S5 "$out" || bad=1

  out=$(perl -0777 -ne '
    my @f;
    for my $w (q{.setPeriodic(3600_000L)}, q{.setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)}, q{.setPersisted(false)},
               q{js.getPendingJob(JOB_ID) != null) return;}) {
      push @f, "S6 schedule lacks $w" if index($_, $w) < 0;
    }
    print "FAIL $_\n" for @f; print "ok S6 one periodic 1 h job, any network, not persisted\n" unless @f;
  ' <<<"$sched")
  verdict S6 "$out" || bad=1
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
mut() { # mut <label> <path under ROOT> <perl-expr> <check the mutant must fail>
  local d f out rc n
  d=$(mktemp -d -p "$W")
  for n in $FILES; do mkdir -p "$d/$(dirname "$n")"; cp "$ROOT/$n" "$d/$n"; done
  f="$d/$2"
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed"; rm -rf "$d"; return 1; fi
  if cmp -s "$ROOT/$2" "$f"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  out=$(check "$d" 2>&1); rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if [ "$rc" -eq 3 ]; then echo "  BROKEN    $1 -- it did not compile"; return 1; fi
  case "$out" in *"FAIL $4"*) ;; *) echo "  BROKEN    $1 -- it failed, but not '$4' (rc=$rc)"; return 1 ;; esac
  echo "  convicted $1 (fails '$4')"
}
fails=0
mut "M1 the 6 h spacing made 0" "$CH/DiagReports.java" 's/SIX_H = 6 \* 3600_000L;/SIX_H = 0L;/' "D4 Wi-Fi, sent 6 h - 1 ms ago" || fails=$((fails+1))
mut "M2 the 12 h rule dropped (mobile always sends)" "$CH/DiagReports.java" 's/if \(now - Math\.max\(lastWifi, onSince\) >= TWELVE_H\) return SEND;\n        return WAIT;/return SEND;/' "D4 mobile, no Wi-Fi seen, on 12 h - 1 ms" || fails=$((fails+1))
mut "M3 offered always true" "$CH/DiagReports.java" 's/return statusReply != null && statusReply\.trim\(\)\.startsWith\("OFFERED 1 "\);/return true;/' 'D1 offered("OFFERED 0 ON 1")' || fails=$((fails+1))
mut "M4 the tag added with the switch off" "$CH/ProfileActivity.java" 's/if \(DiagReports\.optedIn\(DiagReportJob\.readFile\(this, DiagReports\.OPT_FILE\)\) && DiagReports\.tagOk\(tag\)\)/if (DiagReports.tagOk(tag))/' "S2 the tag is added without DiagReports.optedIn(" || fails=$((fails+1))
mut "M5 the job sends without the OFFERED check" "$CH/DiagReports.java" 's/        if \(notOffered\(st\)\) \{ p\.cancel\(\); return R_NOT_OFFERED; \}\n        if \(!offered\(st\)\) return R_UNAVAILABLE;\n//' "D6 OFFERED 0 sends no report" || fails=$((fails+1))
mut "M6 an all-digit tag kept" "$CH/DiagReports.java" 's/if \(letter\) return sb\.toString\(\);/return sb.toString();/' "D3 an all-digit body is drawn again" || fails=$((fails+1))
mut "M7 tagOk widened to [a-z0-9]" "$CH/DiagReports.java" 's/t\.matches\("t-\[a-z2-7\]\{10\}"\)/t.matches("t-[a-z0-9]{10}")/' "D3 tagOk rejects 1" || fails=$((fails+1))
mut "M8 the switch drawn on any status reply" "$CH/ProfileActivity.java" 's/if \(DiagReports\.offered\(diagSt\)\) \{/if (diagSt != null) {/' "S1 no \`if (DiagReports.offered" || fails=$((fails+1))
mut "M9 the JobService exported" "$MF" 's/(android:name="\.DiagReportJob"\s+android:permission="android\.permission\.BIND_JOB_SERVICE"\s+)android:exported="false"/${1}android:exported="true"/' "S4 the manifest does not declare" || fails=$((fails+1))
mut "M10 sweepAuto no longer arms" "$CH/UnarchiveService.java" 's/        try \{ DiagReportJob\.arm\(this\); \}\n[^\n]*\n//' "S5" || fails=$((fails+1))
mut "M11 SENT_FILE written on any reply" "$CH/DiagReports.java" 's/            if \(reply == null \|\| !reply\.startsWith\("OK "\)\) return R_NOT_SENT;\n//' "D6 an ERR reply records no SENT_FILE" || fails=$((fails+1))
mut "M12 the job persisted" "$CH/DiagReportJob.java" 's/\.setPersisted\(false\)/.setPersisted(true)/' "S6 schedule lacks .setPersisted(false)" || fails=$((fails+1))
mut "M13 the run keeps its first opt-in read (an Off during status still sends)" "$CH/DiagReports.java" 's/            if \(!optedIn\(opt\)\) return R_OFF;[^\n]*\n//' "D6 an Off during the status request sends no report" || fails=$((fails+1))
mut "M14 the stop flag ignored" "$CH/DiagReports.java" 's/            if \(stopped\.get\(\)\) return R_STOPPED;\n//g' "D6 a stop during the status request sends no report" || fails=$((fails+1))
mut "M15 switchOff without the consent lock" "$CH/DiagReports.java" 's/synchronized \(LOCK\) \{\n            p\.remove\(OPT_FILE\);/{\n            p.remove(OPT_FILE);/' "D6 an Off tapped during a send waits for it" || fails=$((fails+1))
mut "M16 a missing status reply cancels the job" "$CH/DiagReports.java" 's/if \(!offered\(st\)\) return R_UNAVAILABLE;/if (!offered(st)) { p.cancel(); return R_UNAVAILABLE; }/' "D6 no status reply keeps the schedule" || fails=$((fails+1))
mut "M17 SWITCH runs transitions in parallel" "$CH/DiagReports.java" 's/Executors\.newSingleThreadExecutor\(/Executors.newCachedThreadPool(/' "D7 SWITCH does not start a second transition" || fails=$((fails+1))
mut "M18 the Off tap on a thread of its own" "$CH/ProfileActivity.java" 's/DiagReports\.SWITCH\.execute\(\(\) -> DiagReports\.switchOff\(port\)\);/new Thread(() -> DiagReports.switchOff(port)).start();/' "S1 the offered block starts a thread of its own" || fails=$((fails+1))
mut "M19 onStopJob does not set the stop flag" "$CH/DiagReportJob.java" 's/        if \(s != null\) s\.set\(true\);\n//' "S3 onStopJob does not set the stop flag" || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
