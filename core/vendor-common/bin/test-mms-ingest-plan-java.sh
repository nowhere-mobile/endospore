#!/usr/bin/env bash
# test-mms-ingest-plan-java.sh [--mutate] -- NWP-20261204-10, row "An inbound text MMS is delivered but shows an empty
# balloon in the Messaging app". TelIngest.deliverMms writes a text-only MMS as AOSP's PduPersister.persist writes one:
# the parts first, under a placeholder message id, then the pdu, then one update that moves the parts to the pdu's id,
# and text_only=1. A media MMS keeps the earlier order (pdu, addr, parts). Compiles the chooser's pure MmsIngestPlan
# (java.* only) with the cases ALONE and EXECUTES them (C1-C3), then checks the REAL deliverMms, found by brace count,
# on the source with comments dropped, so a comment can neither satisfy nor trip a check (S1-S6):
#   C1  textOnly: 1 or 2 parts, each application/smil or text/plain, at least one text/plain; a vCard, any media,
#       3+ parts or no parts is not.
#   C2  hint: a note with no non-empty text and no media; a non-empty text, media or an empty note is not.
#   C3  placeholderMid(when) is when, above 0 for a real arrival.
#   S1  pdu.put("text_only", textOnly ? 1 : 0) once, before the pdu insert.
#   S2  in the if (textOnly) block, the first insertMmsPart call (under the placeholder) precedes the pdu insert.
#   S3  after the pdu insert, one update of content://mms/<placeholder>/part sets mid to the pdu's id.
#   S4  when the update does not move every part, the placeholders are deleted and the parts go in under id
#       (the if (!early) loop); a null pdu Uri deletes the placeholders; deleteMmsParts deletes mms/<mid>/part.
#   S5  a media MMS never reaches the placeholder insert (its guard is if (textOnly)); the second insertMmsPart call
#       is under if (!early), after the pdu insert; the addr insert follows the pdu insert and precedes the parts.
#   S6  the placeholder pre-clean delete precedes the first placeholder insert, and a false placeholder insert sets
#       early false and deletes the placeholders, so the message takes the earlier order.
#
# It needs a JDK and perl, and it FAILS when there is none: a Java suite that skips without one would read green on a
# runner that never ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
# --mutate re-runs it against broken copies of MmsIngestPlan.java and TelIngest.java, each of which must FAIL a named
# check (X1-X11). A mutant that does not apply (INERT) or does not compile (BROKEN) counts as a failure, never a pass.
#
#   bash test-mms-ingest-plan-java.sh            # the cases and the source checks
#   bash test-mms-ingest-plan-java.sh --mutate   # ... plus the mutants
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
  echo "test-mms-ingest-plan-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
command -v perl >/dev/null 2>&1 || { echo "test-mms-ingest-plan-java: FAIL -- no perl; this suite did NOT run" >&2; exit 2; }
# ONE temp root: every class dir and mutant tree lives under it, and the trap removes it however this ends.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser
CASES=$ROOT/core/chooser/tests/mms-ingest-plan/MmsIngestPlanCases.java

# cases <root>: compile <root>'s MmsIngestPlan with the cases into a fresh dir and run them. 3 when they do not compile.
cases() {
  local d
  d=$(mktemp -d -p "$W")
  "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d" "$1/$CH/MmsIngestPlan.java" "$CASES" || return 3
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d" com.nowhere.chooser.MmsIngestPlanCases
}

# wiring <root>: S1-S6 over <root>'s TelIngest.java with comments dropped. Prints one ok or FAIL line per check; 1 when
# any failed.
wiring() {
  perl -e '
    use strict; use warnings;
    open(my $h, "<", $ARGV[0]) or do { print "FAIL S0 cannot read $ARGV[0]: $!\n"; exit 1 };
    my $raw = do { local $/; <$h> };

    # Comments out, strings and char literals kept.
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
    # The end (one past the closing brace) of the block whose "{" is at $p in $s; -1 when it does not close.
    sub close_of {
      my ($s, $p) = @_;
      my $d = 1; $p++;
      while ($p < length($s) && $d > 0) {
        my $c = substr($s, $p, 1);
        if ($c eq "\"" || $c eq "\x27") {
          my $j = $p + 1;
          while ($j < length($s) && substr($s, $j, 1) ne $c) { $j++ if substr($s, $j, 1) eq "\\"; $j++ }
          $p = $j;
        } elsif ($c eq "{") { $d++ } elsif ($c eq "}") { $d-- }
        $p++;
      }
      return $d == 0 ? $p : -1;
    }
    # The one method whose declaration starts with this text, by brace count; "" when it is not there exactly once.
    sub method {
      my ($sig) = @_;
      my $at = index($code, $sig);
      return "" if $at < 0 || index($code, $sig, $at + 1) >= 0;
      my $p = index($code, "{", $at);
      return "" if $p < 0;
      my $e = close_of($code, $p);
      return $e < 0 ? "" : substr($code, $at, $e - $at);
    }
    # [start, end] of the block opened by the first $head at or after $from in $s; (-1, -1) when there is none.
    sub block {
      my ($s, $head, $from) = @_;
      my $at = index($s, $head, $from);
      return (-1, -1) if $at < 0;
      my $e = close_of($s, $at + length($head) - 1);
      return $e < 0 ? (-1, -1) : ($at, $e);
    }
    sub count { my ($s, $lit) = @_; my $k = () = $s =~ /\Q$lit\E/g; return $k }
    sub inside { my ($p, $a, $b) = @_; return $p >= 0 && $a >= 0 && $p > $a && $p < $b }
    my $bad = 0;
    sub verdict {
      my ($id, $good, @e) = @_;
      if (@e) { print "FAIL $id " . join("; ", @e) . "\n"; $bad = 1 } else { print "ok $id $good\n" }
    }

    my $m = method("private static boolean deliverMms(Context ctx, String[] f,");
    my $prt = method("private static void deleteMmsParts(Context ctx, long mid)");
    my $INS = q{insert(Uri.parse("content://mms"), pdu)};
    my $P = index($m, $INS);
    my ($T0, $T1) = block($m, "if (textOnly) {", 0);
    my ($E0, $E1) = $P < 0 ? (-1, -1) : block($m, "if (early) {", $P);
    my ($L0, $L1) = block($m, "if (!early) {", 0);
    my $first = index($m, "insertMmsPart(");
    my $second = $first < 0 ? -1 : index($m, "insertMmsPart(", $first + 1);
    my @e;

    $m ne "" or push @e, "deliverMms not found";
    count($m, $INS) == 1 or push @e, "the pdu insert is there other than once";
    count($m, q{pdu.put("text_only"}) == 1 or push @e, "pdu.put(\"text_only\" is there other than once";
    my $to = index($m, q{pdu.put("text_only", textOnly ? 1 : 0);});
    $to >= 0 && $to < $P or push @e, "pdu.put(\"text_only\", textOnly ? 1 : 0); is not before the pdu insert";
    verdict("S1", "every pdu carries text_only, set before its insert", @e);

    @e = ();
    my $tp = index($m, "boolean textOnly = MmsIngestPlan.textOnly(");
    $tp >= 0 && ($T0 < 0 || $tp < $T0) or push @e, "textOnly is not decided by MmsIngestPlan.textOnly before the if (textOnly) block";
    if ($T0 < 0) { push @e, "no if (textOnly) { block" }
    else {
      $T1 < $P or push @e, "the if (textOnly) block does not end before the pdu insert";
      index(substr($m, $T0, $T1 - $T0), "insertMmsPart(ctx, ph, ") >= 0 or push @e, "the if (textOnly) block does not insert under the placeholder";
      inside($first, $T0, $T1) && $first < $P or push @e, "the first insertMmsPart call is not in the if (textOnly) block, before the pdu insert";
    }
    verdict("S2", "a text-only MMS inserts its parts under the placeholder before the pdu", @e);

    @e = ();
    my $ph = index($m, "long ph = MmsIngestPlan.placeholderMid(when);");
    $ph >= 0 && ($T0 < 0 || $ph < $T0) or push @e, "the placeholder is not MmsIngestPlan.placeholderMid(when), before the if (textOnly) block";
    if ($E0 < 0) { push @e, "no if (early) { block after the pdu insert" }
    else {
      my $eb = substr($m, $E0, $E1 - $E0);
      index($eb, q{mv.put("mid", id);}) >= 0 or push @e, "the update does not set mid to id";
      index($eb, q{moved = ctx.getContentResolver().update(Uri.parse("content://mms/" + ph + "/part"), mv, null, null);}) >= 0
        or push @e, "no update of content://mms/<placeholder>/part in the if (early) block";
    }
    count($m, ".update(") == 1 or push @e, "deliverMms updates other than once";
    verdict("S3", "after the pdu insert, one update moves the placeholder parts to the pdu id", @e);

    @e = ();
    if ($E0 < 0) { push @e, "no if (early) { block" }
    else {
      my $eb = substr($m, $E0, $E1 - $E0);
      my ($F0, $F1) = block($eb, "if (moved != total) {", 0);
      if ($F0 < 0) { push @e, "no if (moved != total) { fallback" }
      else {
        my $fb = substr($eb, $F0, $F1 - $F0);
        index($fb, "deleteMmsParts(ctx, ph);") >= 0 or push @e, "the fallback does not delete the placeholder parts";
        index($fb, "deleteMmsParts(ctx, id);") >= 0 or push @e, "the fallback does not delete a partial move under id";
        index($fb, "early = false;") >= 0 or push @e, "the fallback does not set early false";
      }
      $L0 > $E1 or push @e, "the if (!early) block does not follow the if (early) block";
    }
    $L0 >= 0 && index(substr($m, $L0, $L1 - $L0), "insertMmsPart(ctx, id, k, ") >= 0 or push @e, "the if (!early) block does not insert under id";
    my $nd = index($m, "if (mmsUri == null && early) deleteMmsParts(ctx, ph);");
    my $nr = index($m, "if (mmsUri == null) return false;");
    $nd >= 0 && $nr > $nd or push @e, "a null pdu Uri does not delete the placeholder parts before return false";
    $prt ne "" && index($prt, q{.delete(Uri.parse("content://mms/" + mid + "/part"), null, null)}) >= 0
      or push @e, "deleteMmsParts does not delete content://mms/<mid>/part";
    verdict("S4", "an update that does not move every part falls back to the parts under id", @e);

    @e = ();
    count($m, "insertMmsPart(") == 2 or push @e, "insertMmsPart is called other than twice";
    inside($first, $T0, $T1) or push @e, "the first insertMmsPart call is not guarded by if (textOnly) {";
    inside($second, $L0, $L1) && $second > $P or push @e, "the second insertMmsPart call is not under if (!early), after the pdu insert";
    my $ad = index($m, q{insert(Uri.parse("content://mms/" + id + "/addr"), addr)});
    $ad > $P && ($L0 < 0 || $ad < $L0) or push @e, "the addr insert does not follow the pdu insert and precede the parts";
    verdict("S5", "a media MMS keeps the earlier order: pdu, addr, then the parts under id", @e);

    @e = ();
    if ($T0 < 0) { push @e, "no if (textOnly) { block" }
    else {
      my $tb = substr($m, $T0, $T1 - $T0);
      my $pre = index($tb, "deleteMmsParts(ctx, ph);");
      my $ins = index($tb, "insertMmsPart(");
      $pre >= 0 && $ins > $pre or push @e, "no placeholder delete before the first placeholder insert";
      my $ek = index($tb, "early = ok[k];");
      $ek > $ins or push @e, "a placeholder insert does not set early from its outcome (early = ok[k];)";
      my $rd = index($tb, "if (!early) deleteMmsParts(ctx, ph);");
      $rd > $ek or push @e, "a refused placeholder insert does not delete the placeholders";
    }
    $L0 >= 0 or push @e, "the parts under id are not guarded by if (!early) {";
    verdict("S6", "a stale placeholder is cleared first; a refused placeholder insert takes the earlier order", @e);

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
  for n in MmsIngestPlan.java TelIngest.java; do cp "$ROOT/$CH/$n" "$d/$CH/$n"; done
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
MP=$CH/MmsIngestPlan.java; TI=$CH/TelIngest.java
mut "X1 textOnly always false" "$MP" 's/return text;/return false;/' C1 || fails=$((fails+1))
mut "X2 the 2-part limit removed" "$MP" 's/ \|\| cts\.size\(\) > 2//' C1 || fails=$((fails+1))
mut "X3 any text/ type accepted (a vCard)" "$MP" 's/ct\.startsWith\("text\/plain"\)/ct.startsWith("text\/")/' C1 || fails=$((fails+1))
mut "X4 the hint ignores media" "$MP" 's/ && !anyMedia//' C2 || fails=$((fails+1))
mut "X5 the text_only put removed" "$TI" 's/\n[ \t]*pdu\.put\("text_only", textOnly \? 1 : 0\);[^\n]*//' S1 || fails=$((fails+1))
mut "X6 the parts moved after the pdu insert" "$TI" 's/(\n[ \t]*if \(textOnly\) \{\n.*?\n            \}\n)(.*?long id = android\.content\.ContentUris\.parseId\(mmsUri\);\n)/\n$2$1/s' S2 || fails=$((fails+1))
mut "X7 the update removed" "$TI" 's/moved = ctx\.getContentResolver\(\)\.update\([^;]*;/moved = total;/' S3 || fails=$((fails+1))
mut "X8 the fallback removed" "$TI" 's/if \(moved != total\) \{/if (false) {/' S4 || fails=$((fails+1))
mut "X9 a media MMS through the parts-first branch" "$TI" 's/if \(textOnly\) \{/if (true) {/' S5 || fails=$((fails+1))
mut "X10 the pre-clean delete removed" "$TI" 's/(if \(textOnly\) \{\n)[ \t]*deleteMmsParts\(ctx, ph\);[^\n]*\n/$1/' S6 || fails=$((fails+1))
mut "X11 a refused placeholder insert ignored" "$TI" 's/early = ok\[k\];/early = true;/' S6 || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
