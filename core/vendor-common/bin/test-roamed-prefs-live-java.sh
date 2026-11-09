#!/usr/bin/env bash
# test-roamed-prefs-live-java.sh [--mutate] -- a Security-screen Auto standby or Auto-wipe change applies to the running
# session (h45 #4, docs/product-decisions.md 2026-10-25), run under javac (NWP-20261119-21).
#
# WHY THIS IS COMMITTED. The gate's sIdleTimeoutMs, sWipeTimeoutMs, sWipeOnSave and sHoldLockForInstalls (and, since
# NWP-20261124-17, sHoldLockForAudio; core/vendor-common/bin/test-audio-hold-pref-java.sh holds its mutants) were set only
# at sign-in, from GET-PREFS's snapshot, so a stored profile that picked "After 5 minutes" and "Right away, once saved"
# kept the old 15 minutes and 12 hours until it signed in again. Now each picker's Save, once its write landed, sends
# the values to the gate (ProfileActivity.sendLivePrefs -> PrefsLiveReceiver, user 0), which parses them with the
# sign-in's rules (RoamedPrefs) and applies them to the current, live session only (ChooserActivity.applyLivePrefs,
# re-arming the idle watcher; the wipe values are read at the next cold lock). Drop a link and the screen says the
# change applies now while the gate keeps the old values, with green CI.
#
# RoamedPrefs is pure java.lang and is compiled here with WipeOnSave, WipeChoice and its cases. Source pins (comment
# lines stripped) hold applyRoamedPrefs, applyLivePrefs, PrefsLiveReceiver, the manifest line and both Save lambdas.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-roamed-prefs-live-java.sh            # the cases and the pins
#   bash test-roamed-prefs-live-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SUT="$SRC/RoamedPrefs.java"
CHOOSER="$SRC/ChooserActivity.java"
RECV="$SRC/PrefsLiveReceiver.java"
PA="$SRC/ProfileActivity.java"
MAN="$root/core/chooser/AndroidManifest.xml"
CASES="$root/core/chooser/tests/roamed-prefs/RoamedPrefsCases.java"
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
[ -f "$CASES" ] || { echo "FAIL: missing $CASES" >&2; exit 2; }

# suite <RoamedPrefs.java> -> 0 pass, 1 a case failed or the class is missing, 3 did not compile.
suite() {
  local src="$1" d out rc
  [ -f "$src" ] || { echo "  FAIL  RoamedPrefs.java does not exist" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$src" "$d/src/com/nowhere/chooser/RoamedPrefs.java"
  cp "$SRC/WipeOnSave.java" "$SRC/WipeChoice.java" "$d/src/com/nowhere/chooser/"
  cp "$CASES" "$d/src/com/nowhere/chooser/RoamedPrefsCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.RoamedPrefsCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# mbody <file> <regex>: a method's body, from its signature to the closing brace at four spaces, comment lines dropped.
mbody() {
  RE="$2" awk '$0 ~ ENVIRON["RE"] { on = 1 } on && $0 !~ /^[ \t]*(\/\/|\*|\/\*)/ { print } on && /^    }$/ { exit }' "$1"
}
# count <body> <regex>: matching lines (fixed by the caller's regex; the body has no comment lines).
count() { printf '%s\n' "$1" | RE="$2" awk '$0 ~ ENVIRON["RE"] { n++ } END { print n + 0 }'; }
# first_line <body> <regex>: the first matching line number, empty when none.
first_line() { printf '%s\n' "$1" | RE="$2" awk '$0 ~ ENVIRON["RE"] { print NR; exit }'; }
# code <file>: the file without its comment lines.
code() { awk '$0 !~ /^[ \t]*(\/\/|\*|\/\*)/' "$1"; }

# pins <ChooserActivity.java> <PrefsLiveReceiver.java> <ProfileActivity.java> <AndroidManifest.xml> -> 0 when the
# wiring holds, 1 otherwise.
pins() {
  local ch="$1" rv="$2" pa="$3" man="$4" bad=0 arp alp rcv sip swp slp g a l f n s first_set arm
  [ -f "$rv" ] || { echo "  FAIL  pins: $rv does not exist" >&2; bad=1; rv=/dev/null; }
  arp=$(mbody "$ch" 'private void applyRoamedPrefs\(')
  alp=$(mbody "$ch" 'static void applyLivePrefs\(')
  rcv=$(code "$rv")
  sip=$(mbody "$pa" 'private void showIdlePicker\(')
  swp=$(mbody "$pa" 'private void showWipePicker\(')
  slp=$(mbody "$pa" 'private boolean sendLivePrefs\(')
  # A missing body is reported and the checks still run, so each one shows what it holds.
  for n in arp alp sip swp slp; do [ -n "${!n}" ] || { echo "  FAIL  pins: $n body not found" >&2; bad=1; }; done

  # R1-R3: applyRoamedPrefs parses through RoamedPrefs once and assigns the five statics from its result.
  [ "$(count "$arp" 'RoamedPrefs\.parse\(idle, wipe, wipesaved, holdlock, holdaudio, IDLE_LOGOFF_MS, HARD_WIPE_MS\)')" -eq 1 ] \
    && [ "$(count "$arp" 'RoamedPrefs\.parse\(')" -eq 1 ] \
    || { echo "  FAIL  R1 applyRoamedPrefs does not call RoamedPrefs.parse(..., IDLE_LOGOFF_MS, HARD_WIPE_MS) exactly once" >&2; bad=1; }
  [ "$(count "$arp" 'Long\.parseLong\((idle|wipe)\)')" -eq 0 ] \
    || { echo "  FAIL  R2 applyRoamedPrefs still parses idle or wipe itself" >&2; bad=1; }
  for s in 'sIdleTimeoutMs = rp\.idleMs;' 'sWipeTimeoutMs = rp\.wipeMs;' 'sWipeOnSave = rp\.wipeOnSave;' \
           'sHoldLockForInstalls = rp\.holdLock;' 'sHoldLockForAudio = rp\.holdAudio;'; do
    [ "$(count "$arp" "$s")" -eq 1 ] || { echo "  FAIL  R3 applyRoamedPrefs does not hold exactly one '$s'" >&2; bad=1; }
  done

  # L1: the current-user guard comes before any static write, and returns.
  g=$(first_line "$alp" 'if \(uid <= 0 \|\| .*uid != android\.app\.ActivityManager\.getCurrentUser\(\)\) \{')
  first_set=$(first_line "$alp" '(sIdleTimeoutMs|sWipeTimeoutMs|sWipeOnSave|sHoldLockForInstalls|sHoldLockForAudio) = ')
  if [ -z "$g" ]; then echo "  FAIL  L1 applyLivePrefs has no 'uid <= 0 || ... uid != getCurrentUser()' guard" >&2; bad=1
  elif [ -z "$first_set" ] || [ "$g" -ge "$first_set" ]; then echo "  FAIL  L1 applyLivePrefs writes a static before its guard" >&2; bad=1
  else
    case "$(printf '%s\n' "$alp" | sed -n "$((g + 2))p")" in
      *'return;'*) ;;
      *) echo "  FAIL  L1 applyLivePrefs's guard does not return" >&2; bad=1 ;;
    esac
  fi
  # L2: the five statics come from v.
  for s in 'sIdleTimeoutMs = v\.idleMs;' 'sWipeTimeoutMs = v\.wipeMs;' 'sWipeOnSave = v\.wipeOnSave;' \
           'sHoldLockForInstalls = v\.holdLock;' 'sHoldLockForAudio = v\.holdAudio;'; do
    [ "$(count "$alp" "$s")" -eq 1 ] || { echo "  FAIL  L2 applyLivePrefs does not hold exactly one '$s'" >&2; bad=1; }
  done
  # L3: the idle watcher is re-armed, after the five writes.
  arm=$(first_line "$alp" 'armIdleWatcher\(appCtx, uid\);')
  if [ "$(count "$alp" 'armIdleWatcher\(')" -ne 1 ] || [ -z "$arm" ]; then
    echo "  FAIL  L3 applyLivePrefs does not call armIdleWatcher(appCtx, uid) exactly once" >&2; bad=1
  else
    for s in 'sIdleTimeoutMs = v\.' 'sWipeTimeoutMs = v\.' 'sWipeOnSave = v\.' 'sHoldLockForInstalls = v\.' \
             'sHoldLockForAudio = v\.'; do
      l=$(first_line "$alp" "$s")
      [ -n "$l" ] && [ "$l" -lt "$arm" ] || { echo "  FAIL  L3 armIdleWatcher runs before '$s'" >&2; bad=1; }
    done
  fi
  # L4: no wipe alarm is touched now.
  [ "$(count "$alp" 'setWipeAlarm\(|armWipeWatcher\(')" -eq 0 ] \
    || { echo "  FAIL  L4 applyLivePrefs arms the wipe alarm (it must wait for the next cold lock)" >&2; bad=1; }
  # L5: the log line.
  [ "$(count "$alp" '"live prefs user=" \+ uid \+ " idle="')" -eq 1 ] && [ "$(count "$alp" '\(NWP-20261119-21\)"')" -ge 1 ] \
    || { echo "  FAIL  L5 applyLivePrefs does not log 'live prefs user=<uid> idle=... (NWP-20261119-21)'" >&2; bad=1; }

  # C1: the receiver parses through RoamedPrefs with the gate's defaults and calls only applyLivePrefs, with the app context.
  [ "$(count "$rcv" 'ChooserActivity\.applyLivePrefs\(app, ')" -eq 1 ] \
    || { echo "  FAIL  C1 PrefsLiveReceiver does not call ChooserActivity.applyLivePrefs(app, ...) once" >&2; bad=1; }
  [ "$(count "$rcv" 'ChooserActivity\.[A-Za-z_]+\(')" -eq 1 ] \
    || { echo "  FAIL  C1 PrefsLiveReceiver calls a ChooserActivity method other than applyLivePrefs" >&2; bad=1; }
  [ "$(count "$rcv" 'final Context app = ctx\.getApplicationContext\(\);')" -eq 1 ] \
    || { echo "  FAIL  C1 PrefsLiveReceiver does not pass the application context" >&2; bad=1; }
  [ "$(count "$rcv" 'RoamedPrefs\.parse\(')" -eq 1 ] && [ "$(count "$rcv" 'ChooserActivity\.IDLE_LOGOFF_MS, ChooserActivity\.HARD_WIPE_MS\)')" -eq 1 ] \
    || { echo "  FAIL  C1 PrefsLiveReceiver does not parse through RoamedPrefs with IDLE_LOGOFF_MS and HARD_WIPE_MS" >&2; bad=1; }

  # M1: the manifest declares it, not exported.
  [ "$(grep -c '^    <receiver android:name="\.PrefsLiveReceiver" android:exported="false"/>$' "$man")" -eq 1 ] \
    || { echo "  FAIL  M1 the manifest does not declare PrefsLiveReceiver exported=\"false\"" >&2; bad=1; }
  [ "$(grep -c 'PrefsLiveReceiver.*exported="true"' "$man")" -eq 0 ] \
    || { echo "  FAIL  M1 the manifest declares PrefsLiveReceiver exported=\"true\"" >&2; bad=1; }

  # P1/P2: each Save sends only inside the branch where its write landed, and says "applies next sign-in" only when
  # it did not send.
  [ "$(count "$sip" '^ *final boolean idleOk = writeIdlePref\(mins\[idx\]\);$')" -eq 1 ] \
    && [ "$(count "$sip" '^ *final boolean holdOk = setPref\("holdlock", holdBox\.isChecked\(\) \? "" : "0"\);$')" -eq 1 ] \
    && [ "$(count "$sip" '^ *final boolean audioOk = setPref\("holdaudio", audioBox\.isChecked\(\) \? "" : "0"\);$')" -eq 1 ] \
    || { echo "  FAIL  P1 showIdlePicker does not keep all three write results" >&2; bad=1; }
  for f in sip swp; do
    case "$f" in
      sip) s='^ *if \(idleOk && holdOk && audioOk\) live = sendLivePrefs\(\);$' ;;
      swp) s='^ *if \(writeWipePref\(idx\)\) live = sendLivePrefs\(\);$' ;;
    esac
    [ "$(count "${!f}" "$s")" -eq 1 ] && [ "$(count "${!f}" 'sendLivePrefs\(')" -eq 1 ] \
      || { echo "  FAIL  P $f does not send only when its write landed" >&2; bad=1; }
    [ "$(count "${!f}" '\(live \? "" : " — applies next sign-in"\)')" -eq 1 ] \
      && [ "$(count "${!f}" 'applies next sign-in')" -eq 1 ] \
      || { echo "  FAIL  P $f does not say \"applies next sign-in\" on the failure path only" >&2; bad=1; }
  done
  # P3: sendLivePrefs sends one explicit broadcast to user 0, with the six extras.
  [ "$(count "$slp" 'sendBroadcastAsUser\(new android\.content\.Intent\(this, PrefsLiveReceiver\.class\)')" -eq 1 ] \
    && [ "$(count "$slp" 'sendBroadcastAsUser\(')" -eq 1 ] \
    && [ "$(count "$slp" 'android\.os\.UserHandle\.SYSTEM\);')" -eq 1 ] \
    || { echo "  FAIL  P3 sendLivePrefs does not send one explicit broadcast to UserHandle.SYSTEM" >&2; bad=1; }
  for s in 'EXTRA_IDLE, readPrefValue\("idle"\)' 'EXTRA_WIPE, readPrefValue\("wipe"\)' \
           'EXTRA_WIPESAVED, readPrefValue\(WipeOnSave\.PREF\)' 'EXTRA_HOLDLOCK, readPrefValue\("holdlock"\)' \
           'EXTRA_HOLDAUDIO, readPrefValue\("holdaudio"\)' 'EXTRA_UID, android\.os\.UserHandle\.myUserId\(\)'; do
    [ "$(count "$slp" "$s")" -eq 1 ] || { echo "  FAIL  P3 sendLivePrefs does not carry '$s'" >&2; bad=1; }
  done
  # NWP-20261122-02: the preset picker's Apply (applyPreset) is the third caller; test-preset-picker-java.sh pins it.
  [ "$(code "$pa" | grep -c 'sendLivePrefs(')" -eq 4 ] \
    || { echo "  FAIL  P3 sendLivePrefs is not exactly defined once and called from the two Saves and applyPreset" >&2; bad=1; }
  # P4: both writes report whether they landed.
  [ "$(code "$pa" | grep -cF 'private boolean writeIdlePref(int minutes) { return setPref("idle", String.valueOf(minutes)); }')" -eq 1 ] \
    || { echo "  FAIL  P4 writeIdlePref does not return setPref's result" >&2; bad=1; }
  a=$(mbody "$pa" 'private boolean writeWipePref\(')
  if [ -z "$a" ]; then echo "  FAIL  P4 writeWipePref is not 'private boolean writeWipePref('" >&2; bad=1
  else
    l=$(first_line "$a" 'StoreInstaller\.writeAtomic\(')
    case "$(printf '%s\n' "$a" | sed -n "$((${l:-0} + 1))p")" in
      *'return true;'*) ;;
      *) echo "  FAIL  P4 writeWipePref does not return true right after writeAtomic" >&2; bad=1 ;;
    esac
    # Two: the strict read's refusal (NWP-20261129-15, test-settings-text-java.sh S8) and the failed write's, right
    # after its log line.
    l=$(first_line "$a" 'android\.util\.Log\.w\("NowhereChooser", "writeWipePref", e\);')
    case "$(printf '%s\n' "$a" | sed -n "$((${l:-0} + 1))p")" in
      *'return false;'*) ;;
      *) echo "  FAIL  P4 writeWipePref does not return false on a failed write" >&2; bad=1 ;;
    esac
    [ "$(count "$a" 'return false;')" -eq 2 ] || { echo "  FAIL  P4 writeWipePref does not hold exactly two return false;" >&2; bad=1; }
  fi

  # G1: no new log line prints a profile name.
  g=$(printf '%s\n%s\n%s\n' "$alp" "$rcv" "$slp" | grep -E 'Log\.[a-z]\(' | grep -iwE 'name|profile|alias|label' || true)
  [ -z "$g" ] || { echo "  FAIL  G1 a new log line prints a profile name: $g" >&2; bad=1; }
  [ "$bad" -eq 0 ]
}

echo "== $SUT"
suite "$SUT" || { echo "FAILED"; exit 1; }
pins "$CHOOSER" "$RECV" "$PA" "$MAN" || { echo "FAILED (pins)"; exit 1; }
echo "pins: ok"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not compile or does not apply proves nothing)"
mut() { # mut <label> <perl-expr>   (mutates RoamedPrefs.java; the cases must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/RoamedPrefs.java"
  cp "$SUT" "$c"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$SUT" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  suite "$c" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  CONVICTED $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
mutpin() { # mutpin <label> <CH|RV|PA|MAN> <perl-expr>   (mutates one source; the pins must fail)
  local d c rc why ch="$CHOOSER" rv="$RECV" pa="$PA" man="$MAN" orig
  d=$(mktemp -d -p "$W") || return 1
  case "$2" in
    CH) orig="$CHOOSER"; c="$d/ChooserActivity.java"; ch="$c" ;;
    RV) orig="$RECV"; c="$d/PrefsLiveReceiver.java"; rv="$c" ;;
    PA) orig="$PA"; c="$d/ProfileActivity.java"; pa="$c" ;;
    MAN) orig="$MAN"; c="$d/AndroidManifest.xml"; man="$c" ;;
  esac
  cp "$orig" "$c"
  if ! perl -0pi -e "$3" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  why=$(pins "$ch" "$rv" "$pa" "$man" 2>&1); rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  echo "  CONVICTED $1 --$(printf '%s\n' "$why" | grep -m1 'FAIL' | sed 's/^ *FAIL//')"
}
fails=0
mutpin "X1 the getCurrentUser() guard removed" CH 's/\n *if \(uid <= 0 \|\| [^\n]*getCurrentUser\(\)\) \{\n[^\n]*\n *return;\n *\}//' || fails=$((fails+1))
mutpin "X2 the armIdleWatcher call removed" CH 's/(static void applyLivePrefs\(.*?)\n *armIdleWatcher\(appCtx, uid\);/$1/s' || fails=$((fails+1))
mutpin "X3 sWipeOnSave not set by applyLivePrefs" CH 's/\n *sWipeOnSave = v\.wipeOnSave;//' || fails=$((fails+1))
mutpin "X4 the wipe Save sends before its write" PA 's/if \(writeWipePref\(idx\)\) live = sendLivePrefs\(\);/live = sendLivePrefs(); writeWipePref(idx);/' || fails=$((fails+1))
mutpin "X4b the idle Save sends before its writes" PA 's/(\n *)(final boolean idleOk = writeIdlePref)/$1live = sendLivePrefs();$1$2/; s/if \(idleOk && holdOk && audioOk\) live = sendLivePrefs\(\);/if (idleOk \&\& holdOk \&\& audioOk) live = true;/' || fails=$((fails+1))
mutpin "X5 the receiver exported" MAN 's/(android:name="\.PrefsLiveReceiver" android:exported=)"false"/$1"true"/' || fails=$((fails+1))
mutpin "X6 the idle toast always says applies next sign-in" PA 's/("Auto standby when idle: " \+ labels\[idx\]\.toLowerCase\(\)\n *\+ )\(live \? "" : " — applies next sign-in"\)/$1" — applies next sign-in"/' || fails=$((fails+1))
mut "X7 parse reads \"0\" (Never) as the default" 's/if \(idle != null && !idle\.isEmpty\(\)\)/if (idle != null \&\& !idle.isEmpty() \&\& !"0".equals(idle))/' || fails=$((fails+1))
mutpin "X8 the receiver calls another ChooserActivity method" RV 's/(\n *ChooserActivity\.applyLivePrefs\()/\n        ChooserActivity.armIdleWatcher(app, 0);$1/' || fails=$((fails+1))
mutpin "X9 applyLivePrefs arms the wipe alarm now" CH 's/(\n *)(armIdleWatcher\(appCtx, uid\);)/$1$2$1armWipeWatcher(appCtx, uid);/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "PASS: 10 of 10 mutants convicted" || { echo "== $fails mutant(s) not convicted"; exit 1; }
