#!/usr/bin/env bash
# test-profile-back-java.sh [--mutate] -- Profile's Back goes to the screen's parent, run under javac (NWP-20261128-10).
#
# WHY THIS IS COMMITTED. The row "The Profile app closes on Back from any screen and never shows in recent apps",
# parts (1) and (2). ProfileActivity swaps its screens in place, and Back (the button or the swipe) ran
# super.onBackPressed() from every one of them, so the whole app closed from Profile › Preferences › Your apps.
# ProfileBack holds the decision (pure java.lang) and is compiled here with its cases: a sub-screen with a parent goes
# there (B1), one without goes to Profile home (B2), Profile home leaves the app (B3), a sign-out swallows Back on any
# screen (B4), and the API 33+ callback is unregistered only on home with no sign-out, so the platform shows its peek
# there (B5). Source checks (comments stripped) pin the wiring in ProfileActivity and the manifest:
#   P1 onBackPressed calls goBack, and super.onBackPressed() appears once, inside goBack;
#   P2 finishMenuScreen(ll, onBack, head) wires its link through backLink;
#   P3 no back.setOnClickListener( outside backLink and Help's card Back;
#   P4 the setContentView override moves pendingBack into backTarget and calls syncBackCallback();
#   P5 every `loggingOff = true;` is followed by syncBackCallback() (the field and the `= false` writes excluded);
#   P6 Help saves its own target when a topic opens, the topic's card Back is the target, and close restores it;
#   P7 enableOnBackInvokedCallback="true" is on ProfileActivity's element only (not <application>, not the gate's),
#      and excludeFromRecents="true" stays;
#   P8 finishOfflineMedia's late link does not leave pendingBack set for the next screen.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-profile-back-java.sh            # the cases and the source checks
#   bash test-profile-back-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
BACK="${PROFILE_BACK_SRC:-$SRC/ProfileBack.java}"
PROFILE="${PROFILE_ACTIVITY_SRC:-$SRC/ProfileActivity.java}"
MANIFEST="${CHOOSER_MANIFEST:-$root/core/chooser/AndroidManifest.xml}"
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
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }

CASES=$(mktemp -p "$W" ProfileBackCases.XXXXXX) || exit 2
cat > "$CASES" <<'JAVA'
package com.nowhere.chooser;

public class ProfileBackCases {
    static int bad = 0, n = 0;
    static void eq(String id, Object got, Object want) {
        n++;
        if (!want.equals(got)) { bad++; System.out.println("FAIL " + id + ": got " + got + ", want " + want); }
    }
    public static void main(String[] a) {
        eq("B1 a sub-screen with a parent", ProfileBack.decide(false, false, true), ProfileBack.Act.TARGET);
        eq("B2 a sub-screen without a parent", ProfileBack.decide(false, false, false), ProfileBack.Act.HOME);
        eq("B3 home, a target recorded", ProfileBack.decide(false, true, true), ProfileBack.Act.LEAVE);
        eq("B3 home, no target", ProfileBack.decide(false, true, false), ProfileBack.Act.LEAVE);
        for (boolean home : new boolean[] {false, true})
            for (boolean target : new boolean[] {false, true})
                eq("B4 sign-out, home=" + home + " target=" + target, ProfileBack.decide(true, home, target),
                        ProfileBack.Act.SWALLOW);
        eq("B5 callback on a sub-screen", ProfileBack.wantCallback(false, false), true);
        eq("B5 no callback on home", ProfileBack.wantCallback(false, true), false);
        eq("B5 callback during sign-out on a sub-screen", ProfileBack.wantCallback(true, false), true);
        eq("B5 callback during sign-out on home", ProfileBack.wantCallback(true, true), true);
        if (bad > 0) { System.out.println(bad + " of " + n + " cases failed"); System.exit(1); }
        System.out.println("ok " + n + " cases");
    }
}
JAVA

# cases <ProfileBack.java> -> 0 pass, 1 a case failed or the class is missing, 3 did not compile.
cases() {
  local back="$1" d out rc
  [ -f "$back" ] || { echo "  FAIL  ProfileBack.java does not exist (the Back decision is not built)"; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$back" "$d/src/com/nowhere/chooser/ProfileBack.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/ProfileBackCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.ProfileBackCases 2>&1)
  rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# strip <file> -> the source with comment lines (first non-blank "*" or "/*") and every "//" tail removed.
strip() { sed -e '/^[[:space:]]*\(\*\|\/\*\)/d' -e 's#//.*$##' "$1"; }
# method <file> <signature-regex> -> the stripped method from its signature to its closing "    }".
method() {
  strip "$1" | awk -v sig="$2" '$0 ~ sig { on = 1 } on { print } on && /^    }$/ { exit }'
}
# count <text> <fixed needle> -> how many lines hold it.
count() { local c; c=$(printf '%s\n' "$1" | grep -cF -- "$2"); echo "$c"; }
# idx <text> <needle> -> the offset of the first needle, -1 when absent.
idx() { NEEDLE="$2" perl -0e '$_ = join("", <STDIN>); print index($_, $ENV{NEEDLE})' <<<"$1"; }
# tag <manifest> <start> -> the opening tag that begins with <start>, up to its first ">".
tag() { START="$2" perl -0ne '$s = quotemeta $ENV{START}; print $1 if /($s[^>]*>)/s' "$1"; }

# source_check <ProfileActivity.java> <AndroidManifest.xml> -> 0 when every pin holds, 1 otherwise.
source_check() {
  local pa="$1" mf="$2" bad=0 all onb gob fin bl scv help page offm i j n t
  all=$(strip "$pa")
  onb=$(method "$pa" 'public void onBackPressed\\(\\)')
  gob=$(method "$pa" 'private void goBack\\(\\)')
  fin=$(method "$pa" 'private void finishMenuScreen\\(LinearLayout ll, Runnable onBack, LinearLayout head\\)')
  bl=$(method "$pa" 'private void backLink\\(TextView back, Runnable onBack\\)')
  scv=$(method "$pa" 'public void setContentView\\(android\\.view\\.View view\\)')
  help=$(method "$pa" 'private void showHelp\\(\\)')
  page=$(method "$pa" 'private void showHelpPage\\(')
  offm=$(method "$pa" 'private void finishOfflineMedia\\(')

  # P1 onBackPressed -> goBack; super.onBackPressed() only inside goBack.
  [ "$(count "$onb" 'goBack();')" -ge 1 ] || { echo "  PIN   P1 onBackPressed does not call goBack()"; bad=1; }
  [ "$(count "$all" 'super.onBackPressed()')" = 1 ] || {
    echo "  PIN   P1 super.onBackPressed() is not called exactly once in ProfileActivity"; bad=1; }
  [ "$(count "$gob" 'super.onBackPressed()')" = 1 ] || { echo "  PIN   P1 super.onBackPressed() is not inside goBack"; bad=1; }
  [ "$(count "$gob" 'ProfileBack.decide(loggingOff, shownView == confirmView, backTarget != null)')" = 1 ] || {
    echo "  PIN   P1 goBack does not ask ProfileBack.decide with the live state"; bad=1; }

  # P2 finishMenuScreen wires its link through backLink.
  [ "$(count "$fin" 'backLink(back, onBack);')" = 1 ] || { echo "  PIN   P2 finishMenuScreen does not use backLink"; bad=1; }

  # P3 backLink sets the listener and pendingBack; no other back.setOnClickListener( but Help's card Back.
  [ "$(count "$bl" 'back.setOnClickListener(v -> onBack.run());')" = 1 ] || {
    echo "  PIN   P3 backLink does not set the click listener"; bad=1; }
  [ "$(count "$bl" 'pendingBack = onBack;')" = 1 ] || { echo "  PIN   P3 backLink does not record pendingBack"; bad=1; }
  [ "$(count "$page" 'back.setOnClickListener(v -> swipe.accept(-1));')" = 1 ] || {
    echo "  PIN   P3 Help's card Back is not swipe.accept(-1)"; bad=1; }
  n=$(count "$all" 'back.setOnClickListener(')
  [ "$n" = 2 ] || { echo "  PIN   P3 $n back.setOnClickListener( in ProfileActivity, want 2 (backLink and Help's card)"; bad=1; }

  # P4 the setContentView override records the parent and syncs the callback after shownView.
  [ "$(count "$scv" 'backTarget = pendingBack;')" = 1 ] || { echo "  PIN   P4 setContentView does not set backTarget"; bad=1; }
  [ "$(count "$scv" 'pendingBack = null;')" = 1 ] || { echo "  PIN   P4 setContentView does not clear pendingBack"; bad=1; }
  i=$(idx "$scv" 'shownView = view;'); j=$(idx "$scv" 'syncBackCallback();')
  { [ "$i" -ge 0 ] && [ "$j" -gt "$i" ]; } || {
    echo "  PIN   P4 setContentView does not call syncBackCallback() after shownView = view;"; bad=1; }

  # P5 each `loggingOff = true;` statement is followed by syncBackCallback() as its next statement.
  t=$(printf '%s\n' "$all" | perl -ne '
      if ($want) { next if /^\s*$/; if (/^\s*syncBackCallback\(\);\s*$/) { $ok++ } else { $miss++ } $want = 0 }
      if (/^\s*loggingOff = true;\s*$/) { $n++; $want = 1 }
      END { printf "%d %d %d\n", $n, $ok, $miss + ($want ? 1 : 0) }')
  read -r n i j <<<"$t"
  [ "$n" -ge 4 ] || { echo "  PIN   P5 only $n loggingOff = true; statement(s) found, want 4 or more"; bad=1; }
  { [ "$j" = 0 ] && [ "$i" = "$n" ]; } || {
    echo "  PIN   P5 $j of $n loggingOff = true; statement(s) not followed by syncBackCallback();"; bad=1; }

  # P6 Help: the open saves Help's target, the card Back is the target, and close restores it.
  [ "$(count "$help" 'helpBack[0] = backTarget;')" = 1 ] || { echo "  PIN   P6 showHelp does not save its own target"; bad=1; }
  n=$(printf '%s\n' "$help" | perl -0ne '$c = () = /close\[i\] = \(\) -> \{[^}]*backTarget = helpBack\[0\];[^}]*\};/g; print $c')
  [ "$n" = 1 ] || { echo "  PIN   P6 a Help topic's close does not restore the saved target"; bad=1; }
  i=$(idx "$help" 'helpBack[0] = backTarget;'); j=$(idx "$help" 'showHelpPage(body, k, close[k]);')
  { [ "$i" -ge 0 ] && [ "$j" -gt "$i" ]; } || { echo "  PIN   P6 showHelp saves its target after the topic opens"; bad=1; }
  [ "$(count "$page" 'backTarget = () -> swipe.accept(-1);')" = 1 ] || {
    echo "  PIN   P6 a topic's card Back is not the Back target"; bad=1; }
  n=$(printf '%s\n' "$page" | grep -cE 'menuScreen\(|finishMenuScreen\(|setContentView\(|backLink\(')
  [ "$n" -eq 0 ] || { echo "  PIN   P6 showHelpPage builds a screen or a backLink of its own"; bad=1; }

  # P7 the manifest: on ProfileActivity only.
  t=$(tag "$mf" '<activity android:name=".ProfileActivity"')
  [ -n "$t" ] || { echo "  PIN   P7 no ProfileActivity element in the manifest"; bad=1; }
  [ "$(count "$t" 'android:enableOnBackInvokedCallback="true"')" = 1 ] || {
    echo "  PIN   P7 ProfileActivity does not carry enableOnBackInvokedCallback=\"true\""; bad=1; }
  [ "$(count "$t" 'android:excludeFromRecents="true"')" = 1 ] || {
    echo "  PIN   P7 ProfileActivity lost excludeFromRecents=\"true\" (not this slice's change)"; bad=1; }
  t=$(tag "$mf" '<application')
  [ -n "$t" ] || { echo "  PIN   P7 no <application> element in the manifest"; bad=1; }
  [ "$(count "$t" 'enableOnBackInvokedCallback')" = 0 ] || {
    echo "  PIN   P7 <application> carries enableOnBackInvokedCallback (the gate would lose onBackPressed)"; bad=1; }
  t=$(tag "$mf" '<activity android:name=".ChooserActivity"')
  [ -n "$t" ] || { echo "  PIN   P7 no ChooserActivity element in the manifest"; bad=1; }
  [ "$(count "$t" 'enableOnBackInvokedCallback')" = 0 ] || {
    echo "  PIN   P7 ChooserActivity carries enableOnBackInvokedCallback"; bad=1; }

  # P8 the late Offline media link joins a shown screen: it must not leave a parent for the next one.
  i=$(idx "$offm" 'offlineMediaBackLink();'); j=$(idx "$offm" 'pendingBack = null;')
  { [ "$i" -ge 0 ] && [ "$j" -gt "$i" ]; } || {
    echo "  PIN   P8 finishOfflineMedia leaves pendingBack set after its late Back link"; bad=1; }

  [ "$bad" -eq 0 ]
}

# run_all <ProfileBack.java> <ProfileActivity.java> <AndroidManifest.xml> -> 0 pass, 1 a check failed, 3 no compile.
run_all() {
  local rc
  echo "== $1"
  cases "$1"; rc=$?
  [ "$rc" -eq 3 ] && return 3
  if source_check "$2" "$3"; then echo "source: ok"; else echo "FAILED (source)"; rc=1; fi
  return "$rc"
}

run_all "$BACK" "$PROFILE" "$MANIFEST"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAILED (rc=$rc)"; exit 1; }
echo "PASS"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not apply or does not compile proves nothing)"

# mut <label> <back|profile|manifest> <perl-expr> -> 0 when the mutant is convicted.
mut() {
  local label="$1" which="$2" expr="$3" d orig c rc bk="$BACK" pr="$PROFILE" mf="$MANIFEST"
  case "$which" in back) orig="$BACK" ;; profile) orig="$PROFILE" ;; manifest) orig="$MANIFEST" ;; esac
  d=$(mktemp -d -p "$W") || return 1
  c="$d/$(basename "$orig")"
  cp "$orig" "$c"
  if ! perl -0pi -e "$expr" "$c"; then
    echo "  ERROR     $label -- perl failed on the mutation"; rm -rf "$d"; return 1
  fi
  if cmp -s "$orig" "$c"; then echo "  INERT     $label -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  case "$which" in back) bk="$c" ;; profile) pr="$c" ;; manifest) mf="$c" ;; esac
  run_all "$bk" "$pr" "$mf" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $label"; return 1 ;;
    1) echo "  CONVICTED $label"; return 0 ;;
    *) echo "  BROKEN    $label -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "M1 the SWALLOW check removed (B4)" back 's/^\s*if \(loggingOff\) return Act\.SWALLOW;\n//m' || fails=$((fails+1))
mut "M2 the HOME arm returns LEAVE (B2)" back 's/return Act\.HOME;/return Act.LEAVE;/' || fails=$((fails+1))
mut "M3 wantCallback always true (B5)" back 's/return loggingOff \|\| !atHome;/return true;/' || fails=$((fails+1))
mut "M4 one Back link reverted to a bare setOnClickListener (P3)" profile \
  's/backLink\(back, this::showSecurity\);/back.setOnClickListener(v -> showSecurity());/' || fails=$((fails+1))
mut "M5 the attribute moved to <application> (P7)" manifest \
  's/\n[ \t]*android:enableOnBackInvokedCallback="true"//; s/<application /<application android:enableOnBackInvokedCallback="true" /' \
  || fails=$((fails+1))
mut "M6 the Help close no longer restores the target (P6)" profile 's/^\s*backTarget = helpBack\[0\];\n//m' \
  || fails=$((fails+1))
mut "M7 the sync after doLogoff's loggingOff = true; removed (P5)" profile \
  's/(loggingOff = true; \/\/ from here on, block Back[^\n]*\n)\s*syncBackCallback\(\);\n/$1/' || fails=$((fails+1))
mut "M8 finishOfflineMedia leaves pendingBack set (P8)" profile 's/^\s*pendingBack = null; \/\/ NWP-20261128-10: this link[^\n]*\n//m' \
  || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
