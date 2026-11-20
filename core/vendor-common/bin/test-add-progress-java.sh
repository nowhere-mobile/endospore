#!/usr/bin/env bash
# test-add-progress-java.sh [--mutate] -- NWP-20261209-05: nApps reads an add's progress from the chooser, and nApps'
# "Learn more" opens Profile > Help on its "Your apps" topic (decision 2026-11-17 in docs/product-decisions.md, "nApps
# gets the mixed look (M); Signal leaves the curated catalog; the app page points to Your apps; in-app progress
# reopens h51 #3").
#
# WHY THIS IS COMMITTED. The chooser cannot be compiled off the build host. This suite runs:
#   - the cases: core/chooser/tests/add-progress/AddProgressCases.java, compiled with AddProgress.java as-is (pure
#     java.*) and EXECUTED (C1-C9);
#   - H0: HelpPages.java as-is, TITLES[1] is "Your apps" (the title the help branch looks for, not only the index);
#   - the source pins a lift cannot see:
#       A1 getAddProgress and getAddsInFlight are the LAST two INowhereStore methods, directly after materializeOwn,
#          each declared once (methods are only appended, so existing transaction codes keep their numbers);
#       S1 getApp calls AddProgress.update inside the callback that calls postInstallNotice with got/total;
#       S2 AddProgress.end sits in getApp's finally, beside StoreInstaller.IN_FLIGHT.remove;
#   - S5, the handoff: getApp's finally, lifted as-is from StoreService.java, is compiled with AddProgress.java and run.
#     A stub IN_FLIGHT starts a second add of the same package the moment the package is released. That add's
#     progress must survive the first add's cleanup (an end AFTER the release would erase it);
#       S3 getApp returns ERR-BUSY before AddProgress.begin, which is inside the try and before fetchVerdict;
#       S4 both new binder methods start with the callerIsStorefront() check and never talk to the daemon;
#       H1 openYourAppsIfAsked handles OPEN_HELP_YOUR_APPS: removes the extra, showHelp(), then clicks the row titled
#          HelpPages.TITLES[1], and never opens Your apps on it;
#       H2 LandingLine holds OPEN_HELP_YOUR_APPS = "help-your-apps" and still OPEN_YOUR_APPS = "your-apps";
#       H3 showHelp still builds the row the help branch clicks (title TextView in the row, the row's click).
#
# It needs a JDK, and it FAILS when there is none: a Java suite that skips without one would read green on a runner
# that never ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
# --mutate re-runs the suite against broken copies of the chooser sources, each of which must FAIL a named check. A
# mutant that does not apply (INERT) or does not compile (BROKEN) counts as a failure, never a pass.
#
#   bash test-add-progress-java.sh            # the cases and the pins
#   bash test-add-progress-java.sh --mutate   # ... plus the mutants P1-P9
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
  echo "test-add-progress-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
command -v perl >/dev/null 2>&1 || { echo "test-add-progress-java: FAIL -- the pins need perl, and there is none" >&2; exit 2; }
# ONE temp root: every class dir and mutant tree lives under it, and the EXIT trap removes it however this ends.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser
AIDL=core/chooser/aidl/com/nowhere/chooser/INowhereStore.aidl
CASES=core/chooser/tests/add-progress/AddProgressCases.java

# cases <root> -> 0 every case passed, 1 a case failed, 3 a compile error.
cases() {
  local r=$1 d
  d=$(mktemp -d -p "$W")
  if [ ! -f "$r/$CH/AddProgress.java" ]; then echo "FAIL C0 AddProgress.java is missing"; return 1; fi
  "$JAVAC" -nowarn -d "$d" "$r/$CH/AddProgress.java" "$r/$CASES" >"$d/javac.out" 2>&1 \
    || { cat "$d/javac.out"; echo "BROKEN: AddProgress + cases do not compile"; return 3; }
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d" com.nowhere.chooser.AddProgressCases || return 1
  return 0
}

# title <root> -> 0 HelpPages.TITLES[1] is "Your apps", 1 not, 3 a compile error.
title() {
  local r=$1 d
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/src"
  cat > "$d/src/HelpTitle.java" <<'JAVA'
package com.nowhere.chooser;
public class HelpTitle {
  public static void main(String[] a) {
    boolean ok = "Your apps".equals(HelpPages.TITLES[1]);
    System.out.println((ok ? "ok   " : "FAIL ") + "H0 HelpPages.TITLES[1] is \"Your apps\" (it reads \"" + HelpPages.TITLES[1] + "\")");
    if (!ok) System.exit(1);
  }
}
JAVA
  "$JAVAC" -nowarn -d "$d" "$r/$CH/HelpPages.java" "$d/src/HelpTitle.java" >"$d/javac.out" 2>&1 \
    || { cat "$d/javac.out"; echo "BROKEN: HelpPages + HelpTitle do not compile"; return 3; }
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d" com.nowhere.chooser.HelpTitle || return 1
  return 0
}

# handoff <root> -> 0 S5 holds, 1 not, 3 a compile error. Lifts getApp's finally body from StoreService.java as-is.
handoff() {
  local r=$1 d body
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/src"
  body=$(perl -0ne '
    s{/\*.*?\*/}{}gs; s{//[^\n]*}{}g;
    my ($get) = /public String getApp\(String pkg, String label\) \{(.*?)\n        \}\n/s;
    exit 1 unless defined $get;
    my ($fin) = $get =~ /\}\s*finally \{([^{}]*)\}/s;
    exit 1 unless defined $fin;
    print $fin;
  ' "$r/$CH/StoreService.java") || { echo "FAIL S5 getApp's finally was not found in StoreService.java"; return 1; }
  cat > "$d/src/AddProgressHandoff.java" <<JAVA
package com.nowhere.chooser;
// A stub of the one StoreInstaller member getApp's finally uses. remove() runs a hook once the package is released:
// the hook is the second add, which getApp starts on another binder thread the moment IN_FLIGHT.add succeeds.
final class StoreInstaller {
  static final HandoffSet IN_FLIGHT = new HandoffSet();
}
final class HandoffSet {
  private final java.util.Set<String> s = new java.util.HashSet<>();
  Runnable onRelease;
  boolean add(String p) { return s.add(p); }
  boolean remove(Object p) {
    boolean r = s.remove(p);
    Runnable h = onRelease;
    onRelease = null;
    if (r && h != null) h.run();
    return r;
  }
}
public class AddProgressHandoff {
  static boolean second;
  static void cancelInstallNotice(String pkg) {}
  static void cleanup(String pkg) {
$body
  }
  public static void main(String[] a) {
    final String pkg = "org.example.handoff";
    StoreInstaller.IN_FLIGHT.add(pkg);
    AddProgress.begin(pkg);
    AddProgress.update(pkg, 9, 10);
    StoreInstaller.IN_FLIGHT.onRelease = () -> {
      if (!StoreInstaller.IN_FLIGHT.add(pkg)) return; // ERR-BUSY: getApp would not begin
      second = true;
      AddProgress.begin(pkg);
      AddProgress.update(pkg, 5, 10);
    };
    cleanup(pkg);
    String got = AddProgress.get(pkg);
    boolean ok = second && "5 10".equals(got) && pkg.equals(AddProgress.inFlight());
    System.out.println((ok ? "ok   " : "FAIL ") + "S5 a second add of the package, begun when the first add's finally releases it, keeps its progress"
        + " (second add began: " + second + ", get: \"" + got + "\", in flight: \"" + AddProgress.inFlight() + "\")");
    if (!ok) System.exit(1);
  }
}
JAVA
  "$JAVAC" -nowarn -d "$d" "$r/$CH/AddProgress.java" "$d/src/AddProgressHandoff.java" >"$d/javac.out" 2>&1 \
    || { cat "$d/javac.out"; echo "BROKEN: AddProgress + the lifted finally do not compile"; return 3; }
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d" com.nowhere.chooser.AddProgressHandoff || return 1
  return 0
}

# pins <root> -> 0 every pin holds, 1 a pin failed. Prints "ok   <id> ..." / "FAIL <id> ..." per pin.
pins() {
  perl -e '
    use strict; use warnings;
    my ($r, $ch, $aidl) = @ARGV;
    my $bad = 0;
    sub slurp { my $f = shift; open(my $h, "<", $f) or return ""; local $/; my $s = <$h>; close $h; return $s; }
    sub strip { my $s = shift; $s =~ s{/\*.*?\*/}{}gs; $s =~ s{//[^\n]*}{}g; return $s; }
    sub res { my ($id, $ok, $what) = @_; print(($ok ? "ok   " : "FAIL ") . "$id $what\n"); $bad++ unless $ok; }
    sub pos_of { my ($s, $n) = @_; my $i = index($s, $n); return $i; }

    # A1
    my @decls = grep { /\S.*\(.*\);\s*$/ } split /\n/, strip(slurp("$r/$aidl"));
    s/\s+//g for @decls;
    my $n = scalar @decls;
    my $cnt = sub { my $p = shift; scalar grep { index($_, $p) >= 0 } @decls };
    res("A1", $n >= 3 && $decls[$n-1] eq "StringgetAddsInFlight();" && $decls[$n-2] eq "StringgetAddProgress(Stringpkg);"
        && $decls[$n-3] eq "StringmaterializeOwn(Stringpkg);" && $cnt->("getAddProgress(") == 1 && $cnt->("getAddsInFlight(") == 1,
        "INowhereStore ends materializeOwn, getAddProgress, getAddsInFlight, each declared once (last three: "
        . join(" ", @decls[($n >= 3 ? $n-3 : 0) .. $n-1]) . ")");

    my $svc = strip(slurp("$r/$ch/StoreService.java"));
    my ($get) = $svc =~ /public String getApp\(String pkg, String label\) \{(.*?)\n        \}\n/s;
    $get //= "";

    # S1
    my ($lam) = $get =~ /fetchVerdict\("FETCH-APP\\n" \+ pkg \+ " 0 progress\\n", FETCH_APP_CAP_MS,\s*\(got, total\) -> \{([^{}]*)\}\);/s;
    res("S1", defined $lam && index($lam, "AddProgress.update(pkg, got, total);") >= 0
        && index($lam, "postInstallNotice(pkg, label, got, total);") >= 0,
        "getApp calls AddProgress.update(pkg, got, total) in the callback that calls postInstallNotice with got/total");

    # S2
    my ($fin) = $get =~ /\}\s*finally \{([^{}]*)\}/s;
    res("S2", defined $fin && index($fin, "StoreInstaller.IN_FLIGHT.remove(pkg);") >= 0 && index($fin, "AddProgress.end(pkg);") >= 0,
        "getApp ends the add (AddProgress.end) in the finally beside StoreInstaller.IN_FLIGHT.remove");

    # S3
    my ($pb, $pt, $pg, $pf) = (pos_of($get, "return \"ERR-BUSY\";"), pos_of($get, "try {"),
        pos_of($get, "AddProgress.begin(pkg);"), pos_of($get, "fetchVerdict("));
    my $begins = () = $svc =~ /AddProgress\.begin\(/g;
    res("S3", $pb >= 0 && $pt > $pb && $pg > $pt && $pf > $pg && $begins == 1,
        "getApp: ERR-BUSY return < try < AddProgress.begin(pkg) < fetchVerdict, begin once (at $pb < $pt < $pg < $pf, $begins begin)");

    # S4
    for my $m (["getAddProgress", "String pkg"], ["getAddsInFlight", ""]) {
        my ($name, $arg) = @$m;
        my ($b) = $svc =~ /public String \Q$name\E\(\Q$arg\E\) \{(.*?)\n        \}\n/s;
        res("S4", defined $b && $b =~ /\A\s*if \(!callerIsStorefront\(\)\) return "";/
            && $b !~ /\bline\(|lenReply\(|fetchVerdict\(|DaemonSocket/,
            "$name starts with the callerIsStorefront() check and never talks to the daemon");
    }

    # H1
    my $pa = strip(slurp("$r/$ch/ProfileActivity.java"));
    my ($oy) = $pa =~ /private void openYourAppsIfAsked\(\) \{(.*?)\n    \}\n/s;
    $oy //= "";
    my ($hb) = $oy =~ /if \([^\n]*LandingLine\.OPEN_HELP_YOUR_APPS\.equals\(open\)\) \{(.*?)\n        \}\n/s;
    $hb //= "";
    my @at = map { pos_of($hb, $_) } ("in.removeExtra(LandingLine.EXTRA_OPEN);", "showHelp();", "HelpPages.TITLES[1]",
        "performClick()", "return;");
    my $ordered = 1;
    for my $i (0 .. $#at) { $ordered = 0 if $at[$i] < 0 || ($i > 0 && $at[$i] < $at[$i-1]); }
    res("H1", $hb ne "" && $ordered && index($hb, "showYourApps(") < 0,
        "openYourAppsIfAsked on OPEN_HELP_YOUR_APPS: removeExtra < showHelp() < the row titled HelpPages.TITLES[1] clicked < return, no showYourApps (at @at)");

    # H2
    my $ll = slurp("$r/$ch/LandingLine.java");
    res("H2", index($ll, "static final String OPEN_HELP_YOUR_APPS = \"help-your-apps\";") >= 0
        && index($ll, "static final String OPEN_YOUR_APPS = \"your-apps\";") >= 0,
        "LandingLine: OPEN_HELP_YOUR_APPS = \"help-your-apps\", OPEN_YOUR_APPS = \"your-apps\"");

    # H3
    my ($sh) = $pa =~ /private void showHelp\(\) \{(.*?)\n    \}\n/s;
    $sh //= "";
    res("H3", index($sh, "t.setText(HelpPages.TITLES[i]);") >= 0 && index($sh, "row.addView(t, tlp);") >= 0
        && index($sh, "row.setOnClickListener(") >= 0,
        "showHelp builds each topic row with its title TextView inside and the row'"'"'s own click");
    exit($bad ? 1 : 0);
  ' "$1" "$CH" "$AIDL"
}

# suite <root> -> 0 pass, 1 a case or pin failed, 3 a compile error.
suite() {
  local r=$1 rc=0 c
  cases "$r"; c=$?
  [ "$c" -eq 3 ] && return 3; [ "$c" -ne 0 ] && rc=1
  title "$r"; c=$?
  [ "$c" -eq 3 ] && return 3; [ "$c" -ne 0 ] && rc=1
  handoff "$r"; c=$?
  [ "$c" -eq 3 ] && return 3; [ "$c" -ne 0 ] && rc=1
  pins "$r" || rc=1
  return "$rc"
}

echo "== $ROOT"
suite "$ROOT"; rc=$?
[ "$rc" -eq 0 ] || { echo "test-add-progress-java: FAILED (rc=$rc)"; exit 1; }
echo "test-add-progress-java: all cases and pins pass"
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must FAIL its named check: a mutant that is inert or does not compile proves nothing)"
# mut <label> <check-id> <file under core/chooser> <perl-expr>
mut() {
  local label=$1 want=$2 rel=$3 expr=$4 d m out rc
  d=$(mktemp -d -p "$W") || return 1
  mkdir -p "$d/core/chooser/tests"
  cp -R "$ROOT/core/chooser/src" "$ROOT/core/chooser/aidl" "$d/core/chooser/"
  cp -R "$ROOT/core/chooser/tests/add-progress" "$d/core/chooser/tests/"
  m="$d/core/chooser/$rel"
  cp "$m" "$d/orig"
  if ! perl -0pi -e "$expr" "$m"; then echo "  ERROR     $label -- perl failed"; rm -rf "$d"; return 1; fi
  if cmp -s "$d/orig" "$m"; then echo "  INERT     $label -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  out=$(suite "$d" 2>&1); rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $label"; return 1 ;;
    3) echo "  BROKEN    $label -- did not compile"; return 1 ;;
  esac
  case "$out" in
    *"FAIL $want "*) echo "  convicted $label (fails '$want')"; return 0 ;;
    *) echo "  WRONG     $label -- failed, but not check $want"; return 1 ;;
  esac
}
fails=0
S=src/com/nowhere/chooser
mut "P1 update not called from the callback" S1 "$S/StoreService.java" \
  's/\n\s*AddProgress\.update\(pkg, got, total\);[^\n]*//' || fails=$((fails+1))
mut "P2 end missing from the finally" S2 "$S/StoreService.java" \
  's/\n\s*AddProgress\.end\(pkg\);//' || fails=$((fails+1))
mut "P3 begin before the ERR-BUSY return" S3 "$S/StoreService.java" \
  's/\n\s*AddProgress\.begin\(pkg\);[^\n]*//; s/(\n(\s*)if \(!StoreInstaller\.IN_FLIGHT\.add\(pkg\)\) return "ERR-BUSY";)/\n$2AddProgress.begin(pkg);$1/' || fails=$((fails+1))
mut "P4 getAddProgress without the caller check" S4 "$S/StoreService.java" \
  's/(public String getAddProgress\(String pkg\) \{)\s*if \(!callerIsStorefront\(\)\) return "";/$1/' || fails=$((fails+1))
mut "P5 a new method inserted before materializeOwn" A1 aidl/com/nowhere/chooser/INowhereStore.aidl \
  's/(\n\s*\/\*\*[^\n]*NWP-20261209-05[^\n]*the progress of.*?String getAddProgress\(String pkg\);\n)/\n/s; $x=$1; s/(\n\s*\/\*\*[^\n]*MATERIALIZE-OWN)/$x$1/' || fails=$((fails+1))
mut "P6 get returns got only" C3 "$S/AddProgress.java" \
  's/return p\[0\] \+ " " \+ p\[1\];/return String.valueOf(p[0]);/' || fails=$((fails+1))
mut "P7 inFlight in reverse order" C6 "$S/AddProgress.java" \
  's/return String\.join\(" ", MAP\.keySet\(\)\);/java.util.List<String> l = new java.util.ArrayList<>(MAP.keySet()); java.util.Collections.reverse(l); return String.join(" ", l);/' || fails=$((fails+1))
mut "P8 the help extra opens Your apps instead" H1 "$S/ProfileActivity.java" \
  's/(\.OPEN_HELP_YOUR_APPS\.equals\(open\)\) \{\s*in\.removeExtra\(LandingLine\.EXTRA_OPEN\);\s*)showHelp\(\);/${1}showYourApps();/' || fails=$((fails+1))
mut "P9 end after the package is released" S5 "$S/StoreService.java" \
  's/(\n\s*AddProgress\.end\(pkg\);)(\n\s*StoreInstaller\.IN_FLIGHT\.remove\(pkg\);)/$2$1/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
