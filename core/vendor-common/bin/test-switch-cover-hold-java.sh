#!/usr/bin/env bash
# test-switch-cover-hold-java.sh [--mutate] -- the switch-in cover holds while the sign-in worker prepares the
# session, and a second sign-in is refused while one runs, run under javac (NWP-20261118-13).
#
# WHY THIS IS COMMITTED. roamLogin arms the switch-in cover before its provisioning steps, which can run for
# minutes. onResume and watchSwitchIn timed the cover out on a bare 15 s clock, so the gate dropped to an empty,
# enabled sign-in form with Owner settings live and then switched into the session by itself; meanwhile Unlock
# could start a second sign-in. The rule now lives in SwitchCoverHold, a pure class with no android.* import,
# compiled here with its cases. Source pins check that onResume's two checks and watchSwitchIn ask it, that
# roamLogin sets signinWorkerRunning at the arm and clears it in the switch lambda after the re-stamp, that its
# finally recovers the gate when no switch was posted, and that roamLogin's entry refuses while loginInProgress.
#
# NWP-20261119-04: a call that rang during a sign-in's restore resumed the gate when its screen went away. The
# GET-COLDLOCK reveal and applySigningOutUi's idle branch then treated the sign-in screen as a gate at rest: the
# reveal restored the plain gate, and both cleared FLAG_KEEP_SCREEN_ON, so the display slept while the sign-in ran
# on. SwitchCoverHold.signInOwnsScreen and revealStandsAside now hold the rule; pins P11 and P12 check that the two
# reveal guards and the idle branch ask them. NWP-20261120-19 moved the reveal's UI body into applyColdLockReveal,
# so P11 checks that the lambda's re-check is followed by applyColdLockReveal(cl), whose first statement is the cover
# teardown.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-switch-cover-hold-java.sh            # the cases + source pins
#   bash test-switch-cover-hold-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src"
COPY="$SRC/com/nowhere/chooser/SwitchCoverHold.java"
ACT="$SRC/com/nowhere/chooser/ChooserActivity.java"
INSTALL="$SRC/com/nowhere/chooser/InstallWait.java"
CASES="$root/core/chooser/tests/switch-cover-hold/SwitchCoverHoldCases.java"
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
command -v perl >/dev/null 2>&1 || { echo "FAIL: this suite needs perl, and there is none" >&2; exit 2; }
[ -f "$ACT" ] && [ -f "$CASES" ] && [ -f "$INSTALL" ] || { echo "FAIL: missing $ACT, $INSTALL or $CASES" >&2; exit 2; }

# InstallWait.HARD_MS, the longest single install wait: HARD_CAP_MS must outlast it.
HARD_MS=$(sed -n 's/^ *static final long HARD_MS = \([0-9_]*\)L\{0,1\};.*$/\1/p' "$INSTALL" | tr -d '_')
case "$HARD_MS" in ''|*[!0-9]*) echo "FAIL: could not read one number for InstallWait.HARD_MS (got '$HARD_MS')" >&2; exit 2 ;; esac

ARM='switchingIn = true; switchingInAt = android.os.SystemClock.uptimeMillis(); signinWorkerRunning = true;'
CHECK1='        } else if (!switchingIn || !SwitchCoverHold.inWindow(android.os.SystemClock.uptimeMillis(), switchingInAt, signinWorkerRunning)) {'
CHECK2='            if (SwitchCoverHold.inWindow(android.os.SystemClock.uptimeMillis(), switchingInAt, signinWorkerRunning)) {'
WATCH='while (!SwitchCoverHold.watcherGivesUp(android.os.SystemClock.uptimeMillis(), watchStart, switchingInAt, signinWorkerRunning)) {'
FIELD='    private static volatile boolean signinWorkerRunning = false;'
SIG='    private void roamLogin(final String name, final String pw, final boolean isCreate, final String keyMode) {'
STANDS='SwitchCoverHold.revealStandsAside(signingOut, resumeBusy, loginInProgress, switchingIn)'
OUTER="        if (!$STANDS) {"
INNER="                    if ($STANDS) return;"
OWNS='                boolean signIn = SwitchCoverHold.signInOwnsScreen(loginInProgress, switchingIn && SwitchCoverHold.inWindow(android.os.SystemClock.uptimeMillis(), switchingInAt, signinWorkerRunning));'
CLEAR='getWindow().clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);'
ENABLE='unlockBtn.setEnabled(true);'

# pins <ChooserActivity.java> <SwitchCoverHold.java> -> 0 clean, 1 a pin failed. Output is captured into variables.
pins() {
  local act="$1" copy="$2" bad=0 resume watch roam n l1 l2 l_sw l_arm l_prep sw fin blk first ca cc
  local bare apply elsebr ifbr l_owns l_clear l_enable reveal
  resume=$(awk '/^    protected void onResume\(\) \{$/ { on = 1 } on { print } on && /^    }$/ { exit }' "$act")
  watch=$(awk '/^    private void watchSwitchIn\(\) \{$/ { on = 1 } on { print } on && /^    }$/ { exit }' "$act")
  roam=$(awk -v sig="$SIG" '$0 == sig { on = 1 } on && /^    private void offerSnapshotRecovery\(/ { exit } on { print }' "$act")
  case "$resume" in *'lockGate(true)'*) ;; *) echo "  PIN control: the extraction did not find onResume" >&2; return 1 ;; esac
  case "$watch" in *'nowhere-switchin-watch'*) ;; *) echo "  PIN control: the extraction did not find watchSwitchIn" >&2; return 1 ;; esac
  case "$roam" in *'prepRoamedUser(uid);'*) ;; *) echo "  PIN control: the extraction did not find roamLogin" >&2; return 1 ;; esac

  # P1/P2: onResume's two switch-in checks ask SwitchCoverHold with the worker flag.
  n=$(grep -c -F -x -- "$CHECK1" <<<"$resume")
  [ "$n" = 1 ] || { echo "  PIN P1 onResume's LockTask check asks SwitchCoverHold.inWindow with the worker flag: $n line(s), want 1" >&2; bad=1; }
  l2=$(awk -v want="$CHECK2" 'prev == "        if (switchingIn) {" && $0 == want { c++ } { prev = $0 } END { print c + 0 }' <<<"$resume")
  [ "$l2" = 1 ] || { echo "  PIN P2 onResume's cover check (after 'if (switchingIn) {') asks SwitchCoverHold.inWindow with the worker flag" >&2; bad=1; }
  # P3: the bare 15 s rule on switchingInAt is gone from the whole file.
  n=$(grep -c -E 'switchingInAt (>=|<) *SWITCH_COVER_MS' "$act")
  [ "$n" = 0 ] || { echo "  PIN P3 the file still reads switchingInAt against a bare SWITCH_COVER_MS ($n line(s))" >&2; bad=1; }
  # P4: watchSwitchIn waits on SwitchCoverHold.watcherGivesUp, with no clock of its own, and still recovers.
  n=$(grep -c -F -- "$WATCH" <<<"$watch")
  [ "$n" = 1 ] || { echo "  PIN P4 watchSwitchIn does not loop on SwitchCoverHold.watcherGivesUp with the worker flag ($n)" >&2; bad=1; }
  n=$(sed 's,//.*$,,' <<<"$watch" | grep -c 'SWITCH_COVER_MS')
  [ "$n" = 0 ] || { echo "  PIN P4 watchSwitchIn still has a SWITCH_COVER_MS clock of its own" >&2; bad=1; }
  if ! perl -0e 'my $s = do { local $/; <STDIN> }; exit($s =~ /\n\s*switchingIn = false;[^\n]*\n\s*runOnUiThread\(\(\) -> recreate\(\)\);/ ? 0 : 1)' <<<"$watch"; then
    echo "  PIN P4 watchSwitchIn's give-up tail (switchingIn = false; then recreate()) is gone" >&2; bad=1
  fi
  # P5: the field, once, beside switchingIn.
  n=$(grep -c 'boolean signinWorkerRunning' "$act")
  l1=$(awk -v want="$FIELD" 'prev == "    private static volatile boolean switchingIn = false;" && index($0, want) == 1 { c++ } { prev = $0 } END { print c + 0 }' "$act")
  [ "$n" = 1 ] && [ "$l1" = 1 ] || { echo "  PIN P5 signinWorkerRunning is declared once, on the line after switchingIn ($n decl, $l1 placed)" >&2; bad=1; }
  # P6: the arm sets the flag, before the provisioning steps.
  n=$(grep -c -F -- "$ARM" <<<"$roam")
  l_arm=$(grep -n -F -- "$ARM" <<<"$roam" | head -1 | cut -d: -f1)
  l_prep=$(grep -n -F 'prepRoamedUser(uid);' <<<"$roam" | head -1 | cut -d: -f1)
  if [ "$n" != 1 ] || [ -z "$l_arm" ] || [ -z "$l_prep" ] || [ "$l_arm" -ge "$l_prep" ]; then
    echo "  PIN P6 roamLogin's cover arm sets signinWorkerRunning = true once, before prepRoamedUser ($n)" >&2; bad=1
  fi
  # P7: the switch lambda clears the flag AFTER it re-stamps switchingInAt, both before switchToUser.
  sw=$(grep -F 'switchToUser(uid, ownedLbls)' <<<"$roam")
  n=$(grep -c -F 'switchToUser(uid, ownedLbls)' <<<"$roam")
  if [ "$n" != 1 ] \
     || ! perl -e 'exit($ARGV[0] =~ /switchingInAt = android\.os\.SystemClock\.uptimeMillis\(\);.*\bsigninWorkerRunning = false;.*switchToUser\(/ ? 0 : 1)' "$sw" \
     || perl -e 'exit($ARGV[0] =~ /\bsigninWorkerRunning = false;.*switchingInAt = / ? 0 : 1)' "$sw"; then
    echo "  PIN P7 the switch lambda clears signinWorkerRunning only after it re-stamps switchingInAt" >&2; bad=1
  fi
  # P8: the finally keeps restoreGateView and recovers the gate when no switch was posted.
  fin=$(awk '/loginInProgress = false; \/\/ #73: login resolved/ { on = 1 } on { print }' <<<"$roam")
  blk=$(awk '/^            if \(!switched\[0\] && signinWorkerRunning\) \{$/ { on = 1 } on { print } on && /^            }$/ { exit }' <<<"$fin")
  n=$(grep -c -F -x '            if (!switched[0]) restoreGateView();' <<<"$fin")
  [ "$n" = 1 ] || { echo "  PIN P8 the finally's 'if (!switched[0]) restoreGateView();' is gone" >&2; bad=1; }
  if [ -z "$blk" ]; then echo "  PIN P8 the finally has no 'if (!switched[0] && signinWorkerRunning) {' block" >&2; bad=1
  else
    for n in 'signinWorkerRunning = false;' 'switchingIn = false;' 'runOnUiThread(' 'recreate();'; do
      case "$blk" in *"$n"*) ;; *) echo "  PIN P8 the finally's no-switch block does not hold '$n'" >&2; bad=1 ;; esac
    done
  fi
  # P9: the flag's writers, exactly: one set, two clears (the lambda, the finally).
  n=$(grep -c 'signinWorkerRunning = true;' "$act")
  [ "$n" = 1 ] || { echo "  PIN P9 signinWorkerRunning = true; appears $n times, want 1" >&2; bad=1; }
  n=$(grep -v 'boolean signinWorkerRunning' "$act" | grep -c 'signinWorkerRunning = false;')
  [ "$n" = 2 ] || { echo "  PIN P9 signinWorkerRunning = false; appears $n times outside the declaration, want 2" >&2; bad=1; }
  # P10: roamLogin's first statement refuses while a sign-in runs, repaints "Finishing up…" and returns.
  first=$(sed '1d' <<<"$roam" | grep -v -E '^\s*(//|$)' | head -1)
  [ "$first" = '        if (SwitchCoverHold.refuseSecondLogin(loginInProgress)) { // NWP-20261118-13: one sign-in at a time, as the NFC path refuses' ] \
    || { echo "  PIN P10 roamLogin's first statement is not the loginInProgress refusal (got: $first)" >&2; bad=1; }
  blk=$(awk '/^        if \(SwitchCoverHold\.refuseSecondLogin\(loginInProgress\)\) \{/ { on = 1 } on { print } on && /^        }$/ { exit }' <<<"$roam")
  case "$blk" in *'"Finishing up…"'*'return;'*) ;; *) echo "  PIN P10 the refusal does not repaint \"Finishing up…\" and return" >&2; bad=1 ;; esac
  case "$blk" in *'final long tapAt'*|*'new Thread('*) echo "  PIN P10 the refusal block runs into the sign-in itself" >&2; bad=1 ;; esac
  # P11 (NWP-20261119-04): both GET-COLDLOCK reveal guards in onResume ask SwitchCoverHold.revealStandsAside with
  # the live fields -- the outer one before the thread starts, and the re-check first in the UI lambda, before the
  # cover teardown -- and the old two-flag guards are gone. Comments are stripped first. NWP-20261120-19: the
  # teardown is applyColdLockReveal's first statement, and the lambda calls it right after the re-check.
  bare=$(sed 's,//.*$,,' <<<"$resume")
  n=$(grep -c -F 'SwitchCoverHold.revealStandsAside(' <<<"$bare")
  [ "$n" = 2 ] || { echo "  PIN P11 onResume calls SwitchCoverHold.revealStandsAside( $n time(s), want 2" >&2; bad=1; }
  n=$(grep -c -F -x -- "$OUTER" <<<"$bare")
  [ "$n" = 1 ] || { echo "  PIN P11 onResume's outer reveal guard is not '$OUTER' ($n)" >&2; bad=1; }
  n=$(grep -c -F -x -- "$INNER" <<<"$bare")
  [ "$n" = 1 ] || { echo "  PIN P11 the reveal lambda's re-check is not '$INNER' ($n)" >&2; bad=1; }
  n=$(grep -c -F '!signingOut && !resumeBusy' <<<"$bare")
  [ "$n" = 0 ] || { echo "  PIN P11 onResume still holds the bare '!signingOut && !resumeBusy' guard ($n)" >&2; bad=1; }
  n=$(grep -c -F 'if (resumeBusy || signingOut) return;' <<<"$bare")
  [ "$n" = 0 ] || { echo "  PIN P11 onResume still holds the bare 'if (resumeBusy || signingOut) return;' re-check ($n)" >&2; bad=1; }
  if ! perl -e '
      my ($s, $o, $i) = @ARGV;
      exit($s =~ /\Q$o\E\s*\n\s*new Thread\(\(\) -> \{\s*\n\s*String cl = sendDaemon\("GET-COLDLOCK\\n"\)\.trim\(\);.*?\n\s*runOnUiThread\(\(\) -> \{\s*\n\Q$i\E\s*\n\s*applyColdLockReveal\(cl\);/s ? 0 : 1)' \
      "$bare" "$OUTER" "$INNER"; then
    echo "  PIN P11 the guards are not placed as: outer guard, the GET-COLDLOCK thread, the lambda's first statement" \
         "the re-check, then applyColdLockReveal(cl)" >&2; bad=1
  fi
  reveal=$(awk '/^    private void applyColdLockReveal\(String cl\) \{$/ { on = 1 } on { print } on && /^    }$/ { exit }' "$act")
  case "$reveal" in *'enterResumeMode('*) ;; *) echo "  PIN control: the extraction did not find applyColdLockReveal" >&2; return 1 ;; esac
  n=$(sed '1d' <<<"$reveal" | sed 's,//.*$,,' | grep -v -E '^\s*$' | head -1)
  [ "$n" = '        if (coverShown) { setContentView(gateView); coverShown = false; }' ] \
    || { echo "  PIN P11 applyColdLockReveal's first statement is not the cover teardown (got: $n)" >&2; bad=1; }
  # P12 (NWP-20261119-04): applySigningOutUi's idle branch leaves the screen hold and Unlock alone while a sign-in
  # owns the screen (switchingIn read through the cover window, so a stale one cannot hold the screen on).
  apply=$(awk '/^    private void applySigningOutUi\(\) \{$/ { on = 1 } on { print } on && /^    }$/ { exit }' "$act")
  case "$apply" in *'"Signing out…"'*) ;; *) echo "  PIN control: the extraction did not find applySigningOutUi" >&2; return 1 ;; esac
  ifbr=$(sed 's,//.*$,,' <<<"$apply" | awk '/^            if \(signingOut\) \{$/ { on = 1 } /^            } else \{$/ { exit } on { print }')
  elsebr=$(sed 's,//.*$,,' <<<"$apply" | awk '/^            } else \{$/ { on = 1 } on { print }')
  [ -n "$ifbr" ] && [ -n "$elsebr" ] || { echo "  PIN control: applySigningOutUi has no 'if (signingOut) {' ... '} else {'" >&2; return 1; }
  n=$(grep -c -F 'SwitchCoverHold.signInOwnsScreen(' <<<"$elsebr")
  [ "$n" = 1 ] || { echo "  PIN P12 the idle branch calls SwitchCoverHold.signInOwnsScreen( $n time(s), want 1" >&2; bad=1; }
  n=$(grep -c -F -x -- "$OWNS" <<<"$elsebr")
  [ "$n" = 1 ] || { echo "  PIN P12 the idle branch does not read '$OWNS' ($n)" >&2; bad=1; }
  n=$(grep -c -F -- "$CLEAR" <<<"$elsebr")
  l1=$(grep -c -F -x -- "                if (!signIn) $CLEAR" <<<"$elsebr")
  [ "$n" = 1 ] && [ "$l1" = 1 ] || { echo "  PIN P12 the idle branch's FLAG_KEEP_SCREEN_ON clear is not the one 'if (!signIn) ...' line ($n clear(s), $l1 guarded)" >&2; bad=1; }
  n=$(grep -c -F -- "$ENABLE" <<<"$elsebr")
  l1=$(grep -c -F -x -- "                if (!signIn && unlockBtn != null) $ENABLE" <<<"$elsebr")
  [ "$n" = 1 ] && [ "$l1" = 1 ] || { echo "  PIN P12 the idle branch's Unlock re-enable is not the one 'if (!signIn && unlockBtn != null) ...' line ($n, $l1 guarded)" >&2; bad=1; }
  l_owns=$(grep -n -F -x -- "$OWNS" <<<"$elsebr" | head -1 | cut -d: -f1)
  l_clear=$(grep -n -F -- "$CLEAR" <<<"$elsebr" | head -1 | cut -d: -f1)
  l_enable=$(grep -n -F -- "$ENABLE" <<<"$elsebr" | head -1 | cut -d: -f1)
  if [ -z "$l_owns" ] || [ -z "$l_clear" ] || [ -z "$l_enable" ] || [ "$l_owns" -ge "$l_clear" ] || [ "$l_owns" -ge "$l_enable" ]; then
    echo "  PIN P12 signIn is not computed before the guarded clear and re-enable" >&2; bad=1
  fi
  for n in '"Signing out…".contentEquals(result.getText())' 'if (signOffCoverShown) {'; do
    case "$elsebr" in *"$n"*) ;; *) echo "  PIN P12 the idle branch no longer holds '$n'" >&2; bad=1 ;; esac
  done
  for n in 'getWindow().addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);' 'if (unlockBtn != null) unlockBtn.setEnabled(false);'; do
    case "$ifbr" in *"$n"*) ;; *) echo "  PIN P12 the signingOut branch no longer holds '$n'" >&2; bad=1 ;; esac
  done
  case "$ifbr" in *signInOwnsScreen*|*signIn*) echo "  PIN P12 the signingOut branch reads the sign-in" >&2; bad=1 ;; esac
  # K: ChooserActivity.SWITCH_COVER_MS and SwitchCoverHold.SWITCH_COVER_MS cannot drift.
  ca=$(sed -n 's/^ *private static final long SWITCH_COVER_MS = \([0-9_]*\)L\{0,1\};.*$/\1/p' "$act" | tr -d '_')
  cc=$(sed -n 's/^ *static final long SWITCH_COVER_MS = \([0-9_]*\)L\{0,1\};.*$/\1/p' "$copy" | tr -d '_')
  [ -n "$ca" ] && [ "$ca" = "$cc" ] || { echo "  PIN K ChooserActivity.SWITCH_COVER_MS ($ca) != SwitchCoverHold.SWITCH_COVER_MS ($cc)" >&2; bad=1; }
  return "$bad"
}

# suite <SwitchCoverHold.java> <ChooserActivity.java> -> 0 pass, 1 a case or pin failed (the only code that
# convicts a mutant), 3 the class or the cases did not compile.
suite() {
  local copy="$1" act="$2" d out rc bad=0
  [ -f "$copy" ] || { echo "  FAIL  SwitchCoverHold.java does not exist" >&2; return 1; }
  pins "$act" "$copy" || bad=1
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$copy" "$d/src/com/nowhere/chooser/SwitchCoverHold.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/SwitchCoverHoldCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.SwitchCoverHoldCases "$HARD_MS" 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && [ "$bad" -eq 0 ] && return 0
  return 1
}

echo "== $COPY (InstallWait.HARD_MS = $HARD_MS)"
suite "$COPY" "$ACT" || { echo "FAILED"; exit 1; }
echo "== all cases and source pins pass"
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED -- a mutant that does not compile proves nothing)"
mut() { # mut <label> <copy|act> <perl-expr>
  local d c a rc target; d=$(mktemp -d -p "$W"); c="$d/SwitchCoverHold.java"; a="$d/ChooserActivity.java"
  cp "$COPY" "$c"; cp "$ACT" "$a"
  target="$c"; [ "$2" = act ] && target="$a"
  if ! perl -0pi -e "$3" "$target"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$COPY" "$c" && cmp -s "$ACT" "$a"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  suite "$c" "$a" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "M1 the watcher ignores the worker"                act  's/watchStart, switchingInAt, signinWorkerRunning\)/watchStart, switchingInAt, false)/' || fails=$((fails+1))
mut "M2 watcherGivesUp: the worker branch removed"     copy 's/\n[ ]*if \(workerRunning\) return now - switchingInAt >= HARD_CAP_MS;//' || fails=$((fails+1))
mut "M3 onResume's LockTask check ignores the worker"  act  's/(\} else if \(!switchingIn \|\| !SwitchCoverHold\.inWindow\(android\.os\.SystemClock\.uptimeMillis\(\), switchingInAt, )signinWorkerRunning\)\)/${1}false))/' || fails=$((fails+1))
mut "M4 onResume's cover check ignores the worker"     act  's/(\n            if \(SwitchCoverHold\.inWindow\(android\.os\.SystemClock\.uptimeMillis\(\), switchingInAt, )signinWorkerRunning\)\) \{/${1}false)) {/' || fails=$((fails+1))
mut "M5 inWindow: the worker branch removed"           copy 's/\n[ ]*if \(workerRunning\) return age < HARD_CAP_MS;//' || fails=$((fails+1))
mut "M6 the no-worker rule widened past 15 s"          copy 's/return age < SWITCH_COVER_MS;/return age < SWITCH_COVER_MS + 5000;/' || fails=$((fails+1))
mut "M7 SWITCH_COVER_MS 20 s"                          copy 's/SWITCH_COVER_MS = 15000L;/SWITCH_COVER_MS = 20000L;/' || fails=$((fails+1))
mut "M8 the lambda clears the flag before the re-stamp" act 's/(runOnUiThread\(\(\) -> \{ )(switchingIn = true; switchingInAt = android\.os\.SystemClock\.uptimeMillis\(\); )signinWorkerRunning = false; /${1}signinWorkerRunning = false; ${2}/' || fails=$((fails+1))
mut "M9 the finally does not recreate the gate"        act  's/\n[ ]*runOnUiThread\(\(\) -> \{ ChooserActivity g = sLiveGate; if \(g != null && !g\.isFinishing\(\)[^\n]*//' || fails=$((fails+1))
mut "M10 the finally does not clear switchingIn"       act  's/(\n                signinWorkerRunning = false;)\n                switchingIn = false;/$1/' || fails=$((fails+1))
mut "M11 the finally recovers on every failure"        act  's/if \(!switched\[0\] && signinWorkerRunning\) \{/if (!switched[0]) {/' || fails=$((fails+1))
mut "M12 Unlock does not refuse a second sign-in"      act  's/\n        if \(SwitchCoverHold\.refuseSecondLogin\(loginInProgress\)\) \{[^\n]*\n[^\n]*\n            return;\n        \}//' || fails=$((fails+1))
mut "M13 refuseSecondLogin returns false"              copy 's/return loginInProgress;/return false;/' || fails=$((fails+1))
mut "M14 HARD_CAP removed from inWindow"               copy 's/if \(workerRunning\) return age < HARD_CAP_MS;/if (workerRunning) return true;/' || fails=$((fails+1))
mut "M15 HARD_CAP removed from watcherGivesUp"         copy 's/if \(workerRunning\) return now - switchingInAt >= HARD_CAP_MS;/if (workerRunning) return false;/' || fails=$((fails+1))
mut "M16 the arm does not set the flag"                act  's/ signinWorkerRunning = true;//' || fails=$((fails+1))
mut "M17 signInOwnsScreen ignores loginInProgress"     copy 's/return loginInProgress \|\| switchingIn;/return switchingIn;/' || fails=$((fails+1))
mut "M18 signInOwnsScreen ignores switchingIn"         copy 's/return loginInProgress \|\| switchingIn;/return loginInProgress;/' || fails=$((fails+1))
mut "M19 the reveal lambda's re-check reverted"        act  's/if \(SwitchCoverHold\.revealStandsAside\(signingOut, resumeBusy, loginInProgress, switchingIn\)\) return;/if (resumeBusy || signingOut) return;/' || fails=$((fails+1))
mut "M20 the outer reveal guard reverted"              act  's/if \(!SwitchCoverHold\.revealStandsAside\(signingOut, resumeBusy, loginInProgress, switchingIn\)\) \{/if (!signingOut && !resumeBusy) {/' || fails=$((fails+1))
mut "M21 applySigningOutUi clears the hold always"     act  's/if \(!signIn\) (getWindow\(\)\.clearFlags\(android\.view\.WindowManager\.LayoutParams\.FLAG_KEEP_SCREEN_ON\);)/$1/' || fails=$((fails+1))
mut "M22 applySigningOutUi reads a raw switchingIn"    act  's/switchingIn && SwitchCoverHold\.inWindow\(android\.os\.SystemClock\.uptimeMillis\(\), switchingInAt, signinWorkerRunning\)\);/switchingIn);/' || fails=$((fails+1))
mut "M23 revealStandsAside drops the sign-in"          copy 's/ \|\| signInOwnsScreen\(loginInProgress, switchingIn\);/;/' || fails=$((fails+1))
mut "M24 applySigningOutUi re-enables Unlock always"   act  's/if \(!signIn && unlockBtn != null\)/if (unlockBtn != null)/' || fails=$((fails+1))
mut "M25 the reveal lambda drops applyColdLockReveal"  act  's/(\n                    if \(SwitchCoverHold\.revealStandsAside\(signingOut, resumeBusy, loginInProgress, switchingIn\)\) return;)\n\s*applyColdLockReveal\(cl\);/$1/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
