#!/usr/bin/env bash
# test-tap-memory-java.sh [--mutate] -- NWP-20261122-11 (h51 #1): an on-demand tap queued behind the login sweep is
# remembered in the session, so a chooser restart (a cold lock and its resume) does not drop it. The tap worker writes
# the app to a serial-stamped file (TapMemory) before it queues it and removes it when the install ends; the restart's
# sweep installs the remembered taps first, once each, not opened; the sign-out removes the file.
# Compiles the chooser's pure TapMemory (java.io and java.util only, no Android SDK) with a driver this script writes,
# EXECUTES the cases, then checks the REAL call sites over their code with comments dropped, so a comment can neither
# satisfy nor trip a check:
#   T1-T11 TapMemory: the serial stamp, a foreign or malformed file read empty and deleted, add dedupes, remove, clear,
#          no serial does nothing, no temp left, and THE RESTART CASE: a remembered tap comes back once, then never.
#   P1 the tap worker calls TapMemory.add before it queues the tap.
#   P2 the tap worker removes it (TapMemory.remove, and its LIVE_TAPS claim) in the finally, not after the call.
#   P3-P6, P8, P9 sweepAuto: the remembered taps come before pendingAutoApps; each is claimed with one atomic
#          `if (!LIVE_TAPS.add(` before it runs, after a sign-out check; it runs quiet (true); the outer finally
#          forgets it, but a busy end (nothing ran) keeps its line; a busy lane is retried on SweepBusy under MAT_LOCK.
#   P10    sweepAuto: a lane busy past SweepBusy's bound on a remembered tap returns before pendingAutoApps, so no Auto
#          app installs ahead of a remembered tap.
#   P7 doLogoffImpl clears the file after SignOutGate.begin().
#
# It needs a JDK, and it FAILS when there is none: a Java suite that skips without one would read green on a runner
# that never ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
# --mutate re-runs it against broken copies of the three files, each of which must FAIL a named check. A mutant that
# does not apply (INERT) or does not compile (BROKEN) counts as a failure, never a pass.
#
#   bash test-tap-memory-java.sh            # the cases and the source checks
#   bash test-tap-memory-java.sh --mutate   # ... plus the mutants
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
  echo "test-tap-memory-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
command -v perl >/dev/null 2>&1 || { echo "test-tap-memory-java: FAIL -- no perl; this suite did NOT run" >&2; exit 2; }
# ONE temp root: the driver, every class dir, the cases' files and every mutant tree live under it, and the trap
# removes it however this ends.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser
CASES=$W/TapMemoryCases.java
cat >"$CASES" <<'EOF'
package com.nowhere.chooser;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

public class TapMemoryCases {
    static int bad = 0;

    static void ok(String label, boolean cond) {
        System.out.println((cond ? "ok " : "FAIL ") + label);
        if (!cond) bad++;
    }

    static void put(File f, String body) throws IOException {
        try (FileOutputStream o = new FileOutputStream(f)) { o.write(body.getBytes("UTF-8")); }
    }

    static File fresh(File dir, String name) {
        File d = new File(dir, name);
        d.mkdirs();
        return TapMemory.file(d);
    }

    public static void main(String[] a) throws Exception {
        File root = new File(System.getProperty("java.io.tmpdir"), "tapmemory-cases-" + System.nanoTime());
        root.mkdirs();
        List<String> none = Collections.emptyList();
        String A = "com.example.a";

        File f = fresh(root, "t1");
        ok("T1 same serial: add is true", TapMemory.add(f, 7, A));
        ok("T1 same serial: read gives [pkg]", TapMemory.read(f, 7).equals(Arrays.asList(A)));
        ok("T2 foreign serial: read is empty", TapMemory.read(f, 8).isEmpty());
        ok("T2 foreign serial: the file is gone", !f.exists());
        ok("T2 foreign serial: the own serial reads empty after", TapMemory.read(f, 7).isEmpty());

        String[][] headers = { { "v=2 serial=7\n" + A + "\n", "a v=2 header" }, { "garbage\n", "garbage" },
                { "", "an empty file" }, { "v=1 serial=7 \n" + A + "\n", "a trailing space" },
                { "v=1 serial=70\n" + A + "\n", "serial 70" } };
        for (String[] h : headers) {
            f = fresh(root, "t3-" + h[1].replace(' ', '_'));
            put(f, h[0]);
            ok("T3 bad header (" + h[1] + "): read is empty", TapMemory.read(f, 7).isEmpty());
            ok("T3 bad header (" + h[1] + "): the file is gone", !f.exists());
        }
        StringBuilder longName = new StringBuilder("a.");
        while (longName.length() < 256) longName.append('b');
        String[][] lines = { { "not a pkg", "a space" }, { "..x", "..x" }, { "", "an empty line" },
                { longName.toString(), "256 chars" }, { "nodot", "no dot" }, { "com.ex-ample", "a dash" } };
        for (String[] l : lines) {
            f = fresh(root, "t4-" + l[1].replace(' ', '_').replace('.', '_'));
            put(f, "v=1 serial=7\n" + A + "\n" + l[0] + "\ncom.example.b\n");
            ok("T4 bad line (" + l[1] + "): read is empty", TapMemory.read(f, 7).isEmpty());
            ok("T4 bad line (" + l[1] + "): the file is gone", !f.exists());
        }
        f = fresh(root, "t4-ok");
        put(f, "v=1 serial=7\n" + A + "\ncom.example.b");
        ok("T4 a last line with no newline still reads", TapMemory.read(f, 7).equals(Arrays.asList(A, "com.example.b")));
        ok("T4 add refuses a bad name", !TapMemory.add(f, 7, "not a pkg"));
        ok("T4 add refuses a bad name: the file is unchanged", TapMemory.read(f, 7).equals(Arrays.asList(A, "com.example.b")));

        f = fresh(root, "t5");
        TapMemory.add(f, 7, A);
        ok("T5 dedupe: a second add is true", TapMemory.add(f, 7, A));
        ok("T5 dedupe: one entry", TapMemory.read(f, 7).equals(Arrays.asList(A)));
        TapMemory.add(f, 7, "com.example.b");
        ok("T5 order kept", TapMemory.read(f, 7).equals(Arrays.asList(A, "com.example.b")));
        ok("T6 remove: true", TapMemory.remove(f, 7, A));
        ok("T6 remove: the other stays", TapMemory.read(f, 7).equals(Arrays.asList("com.example.b")));
        ok("T6 remove: an absent pkg is true", TapMemory.remove(f, 7, A));
        ok("T6 remove: the last", TapMemory.remove(f, 7, "com.example.b"));
        ok("T6 remove: read is empty", TapMemory.read(f, 7).isEmpty());
        ok("T6 remove: the last one gone deletes the file", !f.exists());

        // THE RESTART CASE (h51 #1): a tap is queued, the chooser restarts before its install, and the next sweep
        // installs it ONCE.
        f = fresh(root, "t7");
        String T = "com.example.tap";
        TapMemory.add(f, 7, T); // the tap worker, before it queues the tap; the process then dies
        int served = 0;
        List<String> first = TapMemory.afterRestart(TapMemory.read(f, 7), new HashSet<String>());
        ok("T7 restart: the remembered tap comes back exactly once", first.equals(Arrays.asList(T)));
        for (String p : first) { served++; TapMemory.remove(f, 7, p); }
        List<String> second = TapMemory.afterRestart(TapMemory.read(f, 7), new HashSet<String>());
        ok("T7 restart: a second restart gives nothing", second.isEmpty());
        ok("T7 restart: installed once", served == 1);

        Set<String> live = new HashSet<>(Arrays.asList(A));
        List<String> rem = Arrays.asList(A, "com.example.b", A);
        ok("T8 live: a pkg in live is not returned", TapMemory.afterRestart(rem, live).equals(Arrays.asList("com.example.b")));
        ok("T8 live: each once, in order", TapMemory.afterRestart(rem, new HashSet<String>()).equals(Arrays.asList(A, "com.example.b")));
        ok("T8 live: null inputs read empty", TapMemory.afterRestart(null, null).isEmpty()
                && TapMemory.afterRestart(rem, null).equals(Arrays.asList(A, "com.example.b")));

        f = fresh(root, "t9");
        TapMemory.add(f, 7, A);
        ok("T9 clear: true", TapMemory.clear(f));
        ok("T9 clear: the file is gone", !f.exists());
        ok("T9 clear: a missing file reads empty", TapMemory.read(f, 7).isEmpty());
        ok("T9 clear: a missing file clears true", TapMemory.clear(f));

        f = fresh(root, "t10");
        ok("T10 no serial: add is false", !TapMemory.add(f, -1, A));
        ok("T10 no serial: nothing written", !f.exists());
        TapMemory.add(f, 7, A);
        ok("T10 no serial: read is empty", TapMemory.read(f, -1).isEmpty());
        ok("T10 no serial: the file is left", f.exists() && TapMemory.read(f, 7).equals(Arrays.asList(A)));

        boolean tmp = false;
        for (File x : root.listFiles()) for (File y : x.listFiles()) if (y.getName().endsWith(".tmp")) tmp = true;
        ok("T11 no temp left", !tmp);

        for (File x : root.listFiles()) { for (File y : x.listFiles()) y.delete(); x.delete(); }
        root.delete();
        System.exit(bad == 0 ? 0 : 1);
    }
}
EOF

# cases <root>: compile <root>'s TapMemory with the driver into a fresh dir and run it (T1-T11).
cases() {
  local d
  [ -f "$1/$CH/TapMemory.java" ] || { echo "FAIL T1-T11 $CH/TapMemory.java does not exist"; return 1; }
  d=$(mktemp -d -p "$W")
  "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d" "$1/$CH/TapMemory.java" "$CASES" || return 3
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d" com.nowhere.chooser.TapMemoryCases
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

# sources <root>: P1-P9 over <root>'s UnarchiveService and ProfileActivity.
sources() {
  local r=$1 sweep start logoff bad=0 out
  # The prefix, not the whole signature, so sweepAuto(boolean byHand) and sweepAuto(boolean byHand, boolean landing)
  # both match.
  sweep=$(code "$r/$CH/UnarchiveService.java" "    private void sweepAuto(")
  start=$(code "$r/$CH/UnarchiveService.java" "    public int onStartCommand(Intent intent, int flags, int startId) {")
  logoff=$(code "$r/$CH/ProfileActivity.java" "    private void doLogoffImpl(")
  if [ -z "$sweep" ] || [ -z "$start" ] || [ -z "$logoff" ]; then
    echo "FAIL P0 sweepAuto, onStartCommand or doLogoffImpl not found"
    bad=1
  fi

  out=$(perl -0777 -ne '
    my $s = $_; my @f;
    my $add = q{TapMemory.add(};
    my $enq = q{qEnqueue(java.util.Collections.singletonList(pkg));};
    my $n = () = $s =~ /\Q$add\E/g;
    my ($ia, $ie) = (index($s, $add), index($s, $enq));
    push @f, "P1 tap add: onStartCommand holds $n TapMemory.add( calls, want 1" if $n != 1;
    push @f, "P1 tap add: TapMemory.add( does not come before $enq" unless $ia >= 0 && $ie >= 0 && $ia < $ie;
    my $call = q{ok = materializeAndInstall(pkg, false);};
    my $ic = index($s, $call);
    if ($ic < 0) { push @f, "P2 tap remove in finally: no `$call` in onStartCommand"; }
    else {
      my $tail = substr($s, $ic);
      my $fi = index($tail, q(} finally {));
      if ($fi < 0) { push @f, "P2 tap remove in finally: no finally after the tap call"; }
      else {
        my ($between, $fin) = (substr($tail, 0, $fi), substr($tail, $fi));
        push @f, "P2 tap remove in finally: TapMemory.remove( runs between the call and the finally"
          if index($between, q{TapMemory.remove(}) >= 0;
        push @f, "P2 tap remove in finally: the finally does not call TapMemory.remove(tapFile, tapSerial, pkg)"
          if index($fin, q{TapMemory.remove(tapFile, tapSerial, pkg)}) < 0;
        push @f, "P2 tap remove in finally: the finally does not release the claim (if (mine) LIVE_TAPS.remove(pkg);)"
          if index($fin, q{if (mine) LIVE_TAPS.remove(pkg);}) < 0;
      }
      my $im = index($s, q{boolean mine = LIVE_TAPS.add(pkg);});
      push @f, "P2 tap remove in finally: `boolean mine = LIVE_TAPS.add(pkg);` does not come before TapMemory.add("
        unless $im >= 0 && $ia >= 0 && $im < $ia;
    }
    print "FAIL $_\n" for @f; print "ok P1/P2 the tap worker remembers its tap until the install ends\n" unless @f;
  ' <<<"$start") || out="$out
FAIL P1 the perl check did not run"
  echo "$out"; case "$out" in *FAIL*) bad=1 ;; esac

  out=$(perl -0777 -ne '
    my $s = $_; my @f;
    my ($ia, $ip) = (index($s, q{TapMemory.afterRestart(}), index($s, q{pendingAutoApps(}));
    if ($ia < 0 || $ip < 0 || $ia > $ip) {
      push @f, "P3 sweep order: TapMemory.afterRestart( does not come before pendingAutoApps(";
    } else {
      my $g = substr($s, $ia, $ip - $ia);
      my $claim = index($g, q{if (!LIVE_TAPS.add(});
      my $quiet = index($g, q{materializeAndInstall(pkg, true)});
      my $gate = index($g, q{SignOutGate.begun()});
      push @f, "P4 sweep claim: no atomic `if (!LIVE_TAPS.add(` claim" if $claim < 0;
      push @f, "P4 sweep claim: no SignOutGate.begun() check before the claim" unless $gate >= 0 && $claim >= 0 && $gate < $claim;
      push @f, "P4 sweep claim: materializeAndInstall(pkg, true) does not follow the claim" unless $claim >= 0 && $quiet > $claim;
      push @f, "P5 sweep quiet: the remembered taps do not run materializeAndInstall(pkg, true)" if $quiet < 0;
      push @f, "P5 sweep quiet: the remembered taps run materializeAndInstall(pkg, false) (opened)"
        if index($g, q{materializeAndInstall(pkg, false)}) >= 0;
      my $nr = () = $g =~ /TapMemory\.remove\(/g;
      push @f, "P6 sweep finally: the remembered-tap block holds $nr TapMemory.remove( calls, want 1" if $nr != 1;
      my $lf = rindex($g, q(finally {));
      if ($lf < 0) { push @f, "P6 sweep finally: no finally in the remembered-tap block"; }
      else {
        my $fin = substr($g, $lf);
        push @f, "P6 sweep finally: the outer finally does not call TapMemory.remove(" if index($fin, q{TapMemory.remove(}) < 0;
        push @f, "P6 sweep finally: LIVE_TAPS.remove(pkg); does not follow the if/else chain unconditionally"
          unless $fin =~ /TapMemory\.remove\([^\n]*\n.*?\n\s*\}\n\s*LIVE_TAPS\.remove\(pkg\);/s;
        push @f, "P8 sweep keeps a busy tap: TapMemory.remove( is not skipped on a BUSY end"
          unless $fin =~ /if \(SweepOutcome\.BUSY\.equals\(tapEnd\)\) \{[^}]*\}\s*else if \(!TapMemory\.remove\(/;
      }
      push @f, "P8 sweep keeps a busy tap: no `String tapEnd = SweepOutcome.BUSY;`" if index($g, q{String tapEnd = SweepOutcome.BUSY;}) < 0;
      my $at = 0;
      for my $w (q{MAT_LOCK.lock();}, q{materializeAndInstall(pkg, true);}, q{tapEnd = matEnd;}, q{MAT_LOCK.unlock();},
                 q{SweepBusy.step(tapEnd, tapTries, tapWaited)}, q{if (tapStep != SweepBusy.Step.RETRY) break;},
                 q{SweepBusy.waitMs(tapTries)}) {
        my $i = index($g, $w, $at);
        if ($i < 0) { push @f, "P9 sweep busy retry: `$w` is missing or out of order"; last; }
        $at = $i + length($w);
      }
      for my $w (q{while (!SignOutGate.begun())}, q{while (left > 0 && !SignOutGate.begun())}) {
        push @f, "P9 sweep busy retry: no `$w`" if index($g, $w) < 0;
      }
      # P10: a lane busy past the bound on a remembered tap stops the WHOLE sweep, so no Auto app goes before it.
      push @f, "P10 busy stops the sweep: a STOP step does not set tapLaneBusy"
        if index($g, q{if (tapStep == SweepBusy.Step.STOP) tapLaneBusy = true;}) < 0;
      my $lr = rindex($g, q{LIVE_TAPS.remove(pkg);});
      my $stop = rindex($g, q(if (tapLaneBusy) {));
      if ($stop < 0 || $stop < $lr) {
        push @f, "P10 busy stops the sweep: no `if (tapLaneBusy) {` after the remembered-tap loop, before pendingAutoApps(";
      } else {
        my $body = substr($g, $stop);
        $body = substr($body, 0, index($body, "}") + 1);
        push @f, "P10 busy stops the sweep: the `if (tapLaneBusy)` block does not return" unless $body =~ /\breturn;\s*\}$/;
      }
    }
    print "FAIL $_\n" for @f; print "ok P3-P10 sweepAuto installs the remembered taps first, once each, not opened\n" unless @f;
  ' <<<"$sweep") || out="$out
FAIL P3 the perl check did not run"
  echo "$out"; case "$out" in *FAIL*) bad=1 ;; esac

  out=$(perl -0777 -ne '
    my ($b, $c) = (index($_, q{SignOutGate.begin();}), index($_, q{TapMemory.clear(}));
    if ($b >= 0 && $c > $b) { print "ok P7 the sign-out clears the remembered taps\n"; }
    else { print "FAIL P7 sign-out clear: doLogoffImpl does not call TapMemory.clear( after SignOutGate.begin();\n"; }
  ' <<<"$logoff") || out="$out
FAIL P7 the perl check did not run"
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
  for n in TapMemory.java UnarchiveService.java ProfileActivity.java; do cp "$ROOT/$CH/$n" "$d/$CH/$n"; done
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
mut "m1 read ignores the serial" TapMemory.java 's/!lines\[0\]\.equals\("v=1 serial=" \+ serial\)/!lines[0].startsWith("v=1 serial=")/' "T2 foreign serial: read is empty" || fails=$((fails+1))
mut "m2 a foreign file is not deleted" TapMemory.java 's/(if \(pkgs == null\) \{\n)\s*deleteLocked\(f\);\n/$1/' "T2 foreign serial: the file is gone" || fails=$((fails+1))
mut "m3 afterRestart ignores live" TapMemory.java 's/busy\.contains\(p\) \|\| //' "T8 live: a pkg in live is not returned" || fails=$((fails+1))
mut "m4 the tap remove moved out of the finally" UnarchiveService.java 's/(\n[ \t]*ok = materializeAndInstall\(pkg, false\);)(.*?)(\n[ \t]*if \(!TapMemory\.remove\(tapFile, tapSerial, pkg\)\) android[^\n]*)/$1$3$2/s' "P2 tap remove in finally" || fails=$((fails+1))
mut "m5 the remembered taps run opened" UnarchiveService.java 's/materializeAndInstall\(pkg, true\)/materializeAndInstall(pkg, false)/' "P5 sweep quiet" || fails=$((fails+1))
mut "m6 the sign-out clear removed" ProfileActivity.java 's/^[^\n]*TapMemory\.clear\([^\n]*\n//m' "P7 sign-out clear" || fails=$((fails+1))
mut "m7 the sweep's claim is a plain add" UnarchiveService.java 's/if \(!LIVE_TAPS\.add\(pkg\)\) continue;/LIVE_TAPS.add(pkg);/' "P4 sweep claim" || fails=$((fails+1))
mut "m8 a busy end deletes the line" UnarchiveService.java 's/if \(SweepOutcome\.BUSY\.equals\(tapEnd\)\) \{[^}]*\} else if \(!TapMemory\.remove\(/if (!TapMemory.remove(/' "P8 sweep keeps a busy tap" || fails=$((fails+1))
mut "m9 the busy retry dropped" UnarchiveService.java 's/SweepBusy\.step\(tapEnd, tapTries, tapWaited\)/SweepBusy.Step.NEXT/' "P9 sweep busy retry" || fails=$((fails+1))
mut "m10 a busy tap lane falls through to the Auto work" UnarchiveService.java 's/(if \(tapLaneBusy\) \{.*?)\n[ \t]*return;\n/$1\n/s' "P10 busy stops the sweep" || fails=$((fails+1))
mut "m11 a STOP no longer marks the lane busy" UnarchiveService.java 's/if \(tapStep == SweepBusy\.Step\.STOP\) tapLaneBusy = true;//' "P10 busy stops the sweep" || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
