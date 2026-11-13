#!/usr/bin/env bash
# test-tel-seen-java.sh [--mutate] -- NWP-20261129-02: after a sign-in or resume delivery TelIngest reads back, as the
# session's reader, each SMS and MMS it inserted, and login.log carries the counts, so an issue report tells a hidden
# row from a delivered one. Evidence only: nothing TelIngest inserts, acknowledges, re-stages or notifies changes.
# Compiles the chooser's pure TelSeen (java.lang and java.util only) with the cases ALONE and EXECUTES them (C1-C5), then
# checks the REAL TelIngest methods, found by brace count. W1-W4 run on the source with comments dropped, so a comment
# can neither satisfy nor trip them; W6 runs on the raw file, because a comment is what it checks:
#   C1  a row inserted twice counts once, per kind, in arrival order.
#   C2  readBack: TRUE counts nothing, FALSE counts hidden in its own kind, null counts unknown only.
#   C3  addr/part: false counts, true does not; a false alone makes any() true.
#   C4  line() is seven numbers, digits and single spaces only, each clamped to 0..99999.
#   C5  sends(true, s) is false for any s; sends(false, empty) is false; sends(false, one hidden sms) is true.
#   W1  deliver records "sms" on the line after the insert, under ins != null, never for a call.
#   W2  deliverMms records "mms" after the null check; the addr Uri and every insertMmsPart call feed TelSeen;
#       insertMmsPart returns whether its part Uri is non-null, and its byte-write retry is unchanged.
#   W3  run holds one TelSeen; the read-back follows the pass loop, the re-stage loops and the final ackLanded, under
#       !live, through canReadMessages.
#   W4  one TELINGEST-SEEN send, behind TelSeen.sends(live, ...), on the line before ACK-TELINGEST.
#   (W5, the control that v.put("sub_id", -1) and pdu.put("sub_id", -1) were unchanged, was retired by NWP-20261130-01,
#   which files each SMS and MMS under its SIM's subscription; test-telingest-sub-java.sh pins that.)
#   W6  the // comment lines directly above the read-back's if (!live) cite the decision: 2026-11-06, harvest 60, #4.
#
# It needs a JDK and perl, and it FAILS when there is none: a Java suite that skips without one would read green on a
# runner that never ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
# --mutate re-runs it against broken copies of TelSeen.java and TelIngest.java, each of which must FAIL a named check. A
# mutant that does not apply (INERT) or does not compile (BROKEN) counts as a failure, never a pass.
#
#   bash test-tel-seen-java.sh            # the cases and the source checks
#   bash test-tel-seen-java.sh --mutate   # ... plus the mutants
#
# Exit: 0 pass, 1 a case or check failed, 2 cannot run, 3 the cases do not compile.
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
  echo "test-tel-seen-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
command -v perl >/dev/null 2>&1 || { echo "test-tel-seen-java: FAIL -- no perl; this suite did NOT run" >&2; exit 2; }
# ONE temp root: every class dir and mutant tree lives under it, and the trap removes it however this ends.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser
CASES=$ROOT/core/chooser/tests/tel-seen/TelSeenCases.java

# cases <root>: compile <root>'s TelSeen with the cases into a fresh dir and run them. 3 when they do not compile.
cases() {
  local d
  d=$(mktemp -d -p "$W")
  "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d" "$1/$CH/TelSeen.java" "$CASES" || return 3
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d" com.nowhere.chooser.TelSeenCases
}

# wiring <root>: W1-W4 over <root>'s TelIngest.java with comments dropped, W6 over the raw file. Prints one ok or FAIL
# line per check; 1 when any failed.
wiring() {
  perl -e '
    use strict; use warnings;
    open(my $h, "<", $ARGV[0]) or do { print "FAIL W0 cannot read $ARGV[0]: $!\n"; exit 1 };
    my $raw = do { local $/; <$h> };

    # Comments out, strings and char literals kept. A comment becomes nothing, so a whole-line comment leaves its
    # indent, and a trailing one leaves the space before it.
    my $code = "";
    for (my ($i, $n) = (0, length($raw)); $i < $n; ) {
      my $c = substr($raw, $i, 1);
      if ($c eq "\"" || $c eq "\x27") {
        my $j = $i + 1;
        while ($j < $n && substr($raw, $j, 1) ne $c) { $j++ if substr($raw, $j, 1) eq "\\"; $j++ }
        $code .= substr($raw, $i, $j - $i + 1); $i = $j + 1;
      } elsif (substr($raw, $i, 2) eq "//") {
        my $j = index($raw, "\n", $i); $j = $n if $j < 0; $i = $j;
      } elsif (substr($raw, $i, 2) eq "/*") {
        my $j = index($raw, "*/", $i + 2); $i = $j < 0 ? $n : $j + 2;
      } else { $code .= $c; $i++ }
    }
    # The one method whose declaration starts with this text, by brace count; "" when it is not there exactly once.
    sub method {
      my ($sig) = @_;
      my $at = index($code, $sig);
      return "" if $at < 0 || index($code, $sig, $at + 1) >= 0;
      my $p = index($code, "{", $at);
      return "" if $p < 0;
      my $d = 1; $p++;
      while ($p < length($code) && $d > 0) {
        my $c = substr($code, $p, 1);
        if ($c eq "\"" || $c eq "\x27") {
          my $j = $p + 1;
          while ($j < length($code) && substr($code, $j, 1) ne $c) { $j++ if substr($code, $j, 1) eq "\\"; $j++ }
          $p = $j;
        } elsif ($c eq "{") { $d++ } elsif ($c eq "}") { $d-- }
        $p++;
      }
      return $d == 0 ? substr($code, $at, $p - $at) : "";
    }
    sub count { my ($s, $re) = @_; my $k = () = $s =~ /$re/g; return $k }
    my $bad = 0;
    sub verdict {
      my ($id, $good, @e) = @_;
      if (@e) { print "FAIL $id " . join("; ", @e) . "\n"; $bad = 1 } else { print "ok $id $good\n" }
    }
    my $nl = qr/[ \t]*\n[ \t]*/; # one line break, no line between

    my $run = method("static void run(Context ctx, boolean live)");
    my $del = method("private static boolean deliver(Context ctx, String line,");
    my $mms = method("private static boolean deliverMms(Context ctx, String[] f,");
    my $prt = method("private static boolean insertMmsPart(Context ctx, long mid,");
    my @e;

    $del ne "" or push @e, "deliver not found";
    $del =~ /\bTelSeen seen\) \{/ or push @e, "deliver takes no TelSeen seen";
    $del =~ /Uri ins = ctx\.getContentResolver\(\)\.insert\(uri, v\);${nl}if \(ins != null && !isCall\) seen\.inserted\("sms", when\);/
      or push @e, "the line after the insert is not: if (ins != null && !isCall) seen.inserted(\"sms\", when);";
    count($del, qr/\bseen\.inserted\(/) == 1 or push @e, "deliver records a row other than once";
    verdict("W1", "deliver records an SMS on the line after the insert, under ins != null, never a call", @e);

    @e = ();
    $mms ne "" or push @e, "deliverMms not found";
    $del =~ /return deliverMms\(ctx, f, insertedThisRun, unknown, sims, tally, seen\);/ or push @e, "deliver does not pass seen to deliverMms";
    $mms =~ /if \(mmsUri == null\) return false;${nl}seen\.inserted\("mms", when\);/
      or push @e, "seen.inserted(\"mms\", when) is not the line after the null check";
    count($mms, qr/\bseen\.inserted\(/) == 1 or push @e, "deliverMms records a row other than once";
    $mms =~ /Uri addrUri = null;${nl}try \{ addrUri = ctx\.getContentResolver\(\)\.insert\(Uri\.parse\("content:\/\/mms\/" \+ id \+ "\/addr"\), addr\); \} catch \(Throwable ignore\) \{\}${nl}seen\.addr\(addrUri != null\);/
      or push @e, "the addr insert is not non-fatal with its Uri fed to seen.addr(addrUri != null)";
    my $calls = count($mms, qr/\binsertMmsPart\(/);
    my $fed = count($mms, qr/\bseen\.part\(insertMmsPart\(/);
    ($calls == 2 && $fed == 2) or push @e, "insertMmsPart calls: $calls, fed to seen.part: $fed (want 2 and 2)";
    if ($prt eq "") { push @e, "insertMmsPart does not return boolean" }
    else {
      $prt =~ /Uri partUri = ctx\.getContentResolver\(\)\.insert\(Uri\.parse\("content:\/\/mms\/" \+ mid \+ "\/part"\), v\);${nl}inserted = partUri != null;/
        or push @e, "inserted is not set from the part Uri on the line after its insert";
      $prt =~ /boolean inserted = false;/ or push @e, "inserted does not start false";
      count($prt, qr/\binserted = /) == 2 or push @e, "inserted is assigned somewhere else";
      count($prt, qr/\breturn\b/) == 1 or push @e, "insertMmsPart has more than one return";
      $prt =~ /\}\s*return inserted;\s*\}\z/ or push @e, "insertMmsPart does not end in return inserted";
      $prt =~ /if \(attempt >= 20\) \{/ or push @e, "control: the byte-write retry changed";
    }
    verdict("W2", "deliverMms records the pdu, the addr Uri and every part; insertMmsPart returns its part Uri non-null", @e);

    @e = ();
    $run ne "" or push @e, "run not found";
    count($run, qr/\bnew TelSeen\(\)/) == 1 or push @e, "run does not hold exactly one TelSeen";
    $run =~ /\bdeliver\(ctx, reply\.get\(i\), insertedThisRun, notified, unknown, sims, tally, seen\)/ or push @e, "run does not pass its TelSeen to deliver";
    my $rb = qr/if \(!live\) \{\s*final boolean canRead = canReadMessages\(ctx\);\s*for \(long w : seen\.sms\) seen\.readBack\("sms", canRead \? exists\(ctx, android\.provider\.Telephony\.Sms\.Inbox\.CONTENT_URI, w\) : null\);\s*for \(long w : seen\.mms\) seen\.readBack\("mms", canRead \? mmsExists\(ctx, w\) : null\);\s*\}/;
    if ($run =~ $rb) {
      my $at = $-[0];
      my $ack = index($run, "ackLanded(ctx, reply, everOk, readOk, acked, true, unknown);");
      $ack >= 0 && $at > $ack or push @e, "the read-back is not after the final ackLanded";
      my $pass = index($run, "for (int pass = 0; pass < passes; pass++) {");
      $pass >= 0 && $at > $pass or push @e, "the read-back is not after the pass loop";
      rindex($run, "RESTAGE-TELINGEST") < $at or push @e, "the read-back is not after the re-stage loops";
    } else { push @e, "no read-back block: if (!live) { canReadMessages, then each sms and mms through canRead ? ... : null }" }
    count($run, qr/\bseen\.readBack\(/) == 2 or push @e, "run reads back other than in those two loops";
    verdict("W3", "the read-back follows the passes and the final ackLanded, under !live, through canReadMessages", @e);

    @e = ();
    count($code, qr/"TELINGEST-SEEN\\n"/) == 1 or push @e, "the file does not send TELINGEST-SEEN exactly once";
    my $send = q{if (TelSeen.sends(live, seen)) DaemonSocket.roundTrip("TELINGEST-SEEN\n" + seen.line() + "\n", 5_000);};
    my $ackt = q{DaemonSocket.roundTrip("ACK-TELINGEST\n", 5_000);};
    $run =~ /\Q$send\E$nl\Q$ackt\E/ or push @e, "the send behind TelSeen.sends(live, seen) is not directly before ACK-TELINGEST";
    index($raw, "        $send\n        $ackt\n") >= 0 or push @e, "in the file itself, the send line is not the line before ACK-TELINGEST";
    verdict("W4", "one TELINGEST-SEEN send behind TelSeen.sends(live, ...), the line before ACK-TELINGEST", @e);

    # From $raw, because the comment is the thing checked: the // lines directly above the if (!live) { whose block,
    # closed at the indent of that if line, holds the sms read-back. Joined, so a citation may wrap across lines.
    @e = ();
    my @lines = split /\n/, $raw;
    my @found;
    for my $i (0 .. $#lines) {
      next unless $lines[$i] =~ /^([ \t]*)if \(!live\) \{[ \t]*$/;
      my $ind = $1;
      my ($j, $holds) = ($i + 1, 0);
      while ($j <= $#lines && $lines[$j] !~ /^\Q$ind\E\}/) { $holds = 1 if index($lines[$j], "seen.readBack(\"sms\"") >= 0; $j++ }
      next unless $holds;
      my @note;
      for (my $k = $i - 1; $k >= 0 && $lines[$k] =~ m{^[ \t]*//[ \t]?(.*)$}; $k--) { unshift @note, $1 }
      push @found, join(" ", @note);
    }
    if (@found != 1) { push @e, "the if (!live) block holding the sms read-back was found " . scalar(@found) . " time(s), want 1" }
    else {
      for my $want (qr/2026-11-06/, qr/harvest 60\b/, qr/#4\b/) {
        $found[0] =~ $want or push @e, "the comment above the read-back does not match $want";
      }
    }
    verdict("W6", "the comment above the read-back cites docs/product-decisions.md 2026-11-06 harvest 60 #4", @e);

    exit $bad;' "$1/$CH/TelIngest.java"
}

# check <root>: 0 pass, 1 a failed case or check, 3 the cases did not compile. A failed case still runs the wiring.
check() {
  local rc=0 crc
  cases "$1"; crc=$?
  [ "$crc" -eq 3 ] && return 3
  [ "$crc" -eq 0 ] || rc=1
  wiring "$1" || rc=1
  return "$rc"
}

check "$ROOT"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAILED"; exit "$rc"; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <path under the root> <perl-expr> <check the mutant must fail>
  local d f out rc n
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/$CH"
  for n in TelSeen.java TelIngest.java; do cp "$ROOT/$CH/$n" "$d/$CH/$n"; done
  f="$d/$2"
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed"; rm -rf "$d"; return 1; fi
  if cmp -s "$ROOT/$2" "$f"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  out=$(check "$d" 2>&1); rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if [ "$rc" -eq 3 ]; then echo "  BROKEN    $1 -- it did not compile"; return 1; fi
  if [[ "$out" != *"FAIL $4 "* ]]; then echo "  BROKEN    $1 -- it failed, but not '$4' (rc=$rc)"; return 1; fi
  echo "  convicted $1 (fails '$4')"
}
fails=0
TS=$CH/TelSeen.java; TI=$CH/TelIngest.java
mut "M1 sends ignores live" "$TS" 's/return !live && s != null && s\.any\(\);/return s != null \&\& s.any();/' C5 || fails=$((fails+1))
mut "M2 readBack(null) counts hidden" "$TS" 's/if \(present == null\) \{ unknown\+\+; return; \}/if (present == null) present = Boolean.FALSE;/' C2 || fails=$((fails+1))
mut "M3 a re-inserted row counts twice" "$TS" 's/final java\.util\.Set<Long> (\w+) = new java\.util\.LinkedHashSet<>\(\);/final java.util.List<Long> $1 = new java.util.ArrayList<>();/g' C1 || fails=$((fails+1))
mut "M4 seen.addr dropped" "$TI" 's/\n[ \t]*seen\.addr\(addrUri != null\);//' W2 || fails=$((fails+1))
mut "M5 insertMmsPart true on a null part Uri" "$TI" 's/inserted = partUri != null;/inserted = true;/' W2 || fails=$((fails+1))
mut "M6 the read-back without canReadMessages" "$TI" 's/final boolean canRead = canReadMessages\(ctx\);\n(\s*for \(long w : seen\.sms\))/final boolean canRead = true;\n$1/' W3 || fails=$((fails+1))
mut "M7 line() unclamped" "$TS" 's/return v < 0 \? 0 : v > 99999 \? 99999 : v;/return v;/' C4 || fails=$((fails+1))
mut "M8 deliver records an SMS whose insert returned null" "$TI" 's/if \(ins != null && !isCall\) seen\.inserted/if (!isCall) seen.inserted/' W1 || fails=$((fails+1))
mut "M9 the read-back comment no longer cites h60 #4" "$TI" 's/harvest 60" #4/harvest 60"/' W6 || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
