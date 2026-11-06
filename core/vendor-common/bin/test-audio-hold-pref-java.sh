#!/usr/bin/env bash
# test-audio-hold-pref-java.sh [--mutate] -- the "audio playing" box of Auto standby when idle, its roamed key
# holdaudio=, its live send and its presets row, run under javac (NWP-20261124-17).
#
# WHY THIS IS COMMITTED. NWP-20261120-02 built the gate's audio wait (IdleLogoffReceiver holds the idle cold lock for up
# to two hours while audio plays) behind ChooserActivity.sHoldLockForAudio, a constant true that nothing set. So a
# Hardened, Isolated or Zero profile, whose preset says the audio wait is Off (docs/product-decisions.md 2026-11-01,
# "before the idle cold lock, a session can wait for app installs and for audio playing ..."), still kept the phone
# decrypted past standby while music played, and no user could turn the hold off. Now showIdlePicker has the box,
# setPref/prefsText write holdaudio=0 when it is Off (absent = On), sendLivePrefs carries it to PrefsLiveReceiver, and
# applyRoamedPrefs (sign-in) and applyLivePrefs (a live Save) set sHoldLockForAudio from RoamedPrefs.parse. Drop one
# link and the box says Off while the gate still holds, with green CI.
#
# RoamedPrefs, ProfilePresets, PresetPicker, WipeOnSave, WipeChoice, SettingsText and MobileData are pure java.*, and
# compile as they are. Lifted holds what the suite lifts from the chooser's sources: prefValueIn, locPrefOn, prefsText
# and prefsUpdated (ProfileActivity, by signature); the EXTRA_* names and the RoamedPrefs.parse call of
# PrefsLiveReceiver.onReceive (its intent reads become map reads); applyRoamedPrefs's line loop, parse call and static
# writes; applyLivePrefs's static writes. A lifted piece that is not found exactly once is an extraction failure,
# never a pass. Source pins (comment lines stripped) hold the picker, the live send and the receiver's wiring.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-audio-hold-pref-java.sh            # the cases and the pins
#   bash test-audio-hold-pref-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
RP="$SRC/RoamedPrefs.java"
PA="$SRC/ProfileActivity.java"
CH="$SRC/ChooserActivity.java"
RV="$SRC/PrefsLiveReceiver.java"
PP="$SRC/PresetPicker.java"
PPS="$SRC/ProfilePresets.java"
CASES="$root/core/chooser/tests/audio-hold-pref/AudioHoldPrefCases.java"
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
for f in "$CASES" "$RP" "$PA" "$CH" "$RV" "$PP" "$PPS" "$SRC/WipeOnSave.java" "$SRC/WipeChoice.java" \
         "$SRC/SettingsText.java" "$SRC/MobileData.java"; do
  [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 2; }
done

# mbody <file> <regex>: a method's body, from its signature to the closing brace at four spaces, comment lines dropped.
mbody() {
  RE="$2" awk '$0 ~ ENVIRON["RE"] { on = 1 } on && $0 !~ /^[ \t]*(\/\/|\*|\/\*)/ { print } on && /^    }$/ { exit }' "$1"
}
# count <body> <regex>: matching lines.
count() { printf '%s\n' "$1" | RE="$2" awk '$0 ~ ENVIRON["RE"] { n++ } END { print n + 0 }'; }
# first_line <body> <regex>: the first matching line number, empty when none.
first_line() { printf '%s\n' "$1" | RE="$2" awk '$0 ~ ENVIRON["RE"] { print NR; exit }'; }
# code <file>: the file without its comment lines.
code() { awk '$0 !~ /^[ \t]*(\/\/|\*|\/\*)/' "$1"; }
# static_method <file> <name>: a "    static ... name(" method, by brace depth.
static_method() {
  awk -v m="$2" '
    !on && index($0, "    static ") == 1 && index($0, " " m "(") { on=1; depth=0 }
    on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
  ' "$1"
}

# lifted <ProfileActivity> <ChooserActivity> <PrefsLiveReceiver> <out Lifted.java> -> 0, or 2 when a piece is not found
# exactly once.
lifted() {
  local pa="$1" ch="$2" rv="$3" out="$4" arp alp rcv loop parse k m
  arp=$(mbody "$ch" 'private void applyRoamedPrefs\(')
  alp=$(mbody "$ch" 'static void applyLivePrefs\(')
  rcv=$(code "$rv")
  # applyRoamedPrefs's `for (String l : lines) {` loop, by brace depth.
  loop=$(printf '%s\n' "$arp" | awk '!on && /^ *for \(String l : lines\) \{$/ { on=1; depth=0 }
    on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0) exit }')
  parse=$(printf '%s\n' "$arp" | grep -E '^ *final RoamedPrefs\.Values rp = RoamedPrefs\.parse\(.*\);$' || true)
  {
    echo "package com.nowhere.chooser;"
    echo "final class Lifted {"
    for k in PREF_NETLOC PREF_GEOCODER; do grep -E "^    static final String $k = \"[a-z-]+\";$" "$pa" || true; done
    for m in prefValueIn locPrefOn prefsText prefsUpdated; do static_method "$pa" "$m"; done
    # The receiver's extra names, one constant each.
    printf '%s\n' "$rcv" | grep -oE 'EXTRA_[A-Z]+ = "[a-z.]+"' | sed 's/^/    static final String /; s/$/;/'
    echo "    static final long IDLE_LOGOFF_MS = 900000L, HARD_WIPE_MS = 43200000L;"
    echo "    static long sIdleTimeoutMs, sWipeTimeoutMs;"
    echo "    static boolean sWipeOnSave, sHoldLockForInstalls = true, sHoldLockForAudio = true;"
    # The receiver's parse call, its intent reads turned into map reads.
    echo "    static RoamedPrefs.Values receiverParse(java.util.Map<String, String> intent) {"
    printf '%s\n' "$rcv" | perl -0ne 'while (/(RoamedPrefs\.parse\(.*?\);)/sg) { my $c = $1;
        $c =~ s/intent\.getStringExtra\((EXTRA_[A-Z]+)\)/intent.get($1)/g; $c =~ s/ChooserActivity\.//g;
        print "        return $c\n"; }'
    echo "    }"
    # applyLivePrefs's static writes.
    echo "    static void applyLive(RoamedPrefs.Values v) {"
    printf '%s\n' "$alp" | grep -E '^ *s[A-Z][A-Za-z]* = v\.[A-Za-z]+;$' || true
    echo "    }"
    # applyRoamedPrefs: the line loop, the parse call and the static writes.
    echo "    static void signIn(java.util.List<String> lines) {"
    echo "        String tz = null, lastTz = null, loc = null, idle = null, wipe = null, holdlock = null, holdaudio = null,"
    echo "                wipesaved = null;"
    printf '%s\n' "$loop"
    printf '%s\n' "$parse"
    printf '%s\n' "$arp" | grep -E '^ *s[A-Z][A-Za-z]* = rp\.[A-Za-z]+;$' || true
    echo "    }"
    echo "}"
  } > "$out"
  for k in PREF_NETLOC PREF_GEOCODER; do
    [ "$(grep -c "static final String $k = " "$out")" = 1 ] || { echo "  FAIL  extraction: $k" >&2; return 2; }
  done
  for m in prefValueIn locPrefOn prefsText prefsUpdated; do
    [ "$(grep -cE "^    static [A-Za-z]+ $m\(" "$out")" = 1 ] || { echo "  FAIL  extraction: $m" >&2; return 2; }
  done
  [ "$(grep -c 'return RoamedPrefs\.parse(' "$out")" = 1 ] || { echo "  FAIL  extraction: the receiver's parse call" >&2; return 2; }
  [ "$(grep -c 'EXTRA_IDLE = ' "$out")" = 1 ] || { echo "  FAIL  extraction: the receiver's EXTRA_* names" >&2; return 2; }
  [ -n "$loop" ] || { echo "  FAIL  extraction: applyRoamedPrefs's line loop" >&2; return 2; }
  [ -n "$parse" ] || { echo "  FAIL  extraction: applyRoamedPrefs's parse call" >&2; return 2; }
  return 0
}

# pins <PrefsLiveReceiver> <ChooserActivity> <ProfileActivity> -> 0 when the wiring holds, 1 otherwise.
pins() {
  local rv="$1" ch="$2" pa="$3" bad=0 rcv alp arp sip slp g n arm s l
  rcv=$(code "$rv")
  alp=$(mbody "$ch" 'static void applyLivePrefs\(')
  arp=$(mbody "$ch" 'private void applyRoamedPrefs\(')
  sip=$(mbody "$pa" 'private void showIdlePicker\(')
  slp=$(mbody "$pa" 'private boolean sendLivePrefs\(')
  for n in alp arp sip slp; do [ -n "${!n}" ] || { echo "  FAIL  pins: $n body not found" >&2; bad=1; }; done
  # S1: the receiver names the extra and reads it once.
  [ "$(count "$rcv" 'EXTRA_HOLDAUDIO = "nowhere\.prefs\.holdaudio"')" -eq 1 ] \
    && [ "$(count "$rcv" 'intent\.getStringExtra\(EXTRA_HOLDAUDIO\)')" -eq 1 ] \
    || { echo "  FAIL  S1 PrefsLiveReceiver does not read EXTRA_HOLDAUDIO (\"nowhere.prefs.holdaudio\") once" >&2; bad=1; }
  # S2: applyLivePrefs sets sHoldLockForAudio once, after its guard and before armIdleWatcher.
  g=$(first_line "$alp" 'if \(uid <= 0 \|\| .*getCurrentUser\(\)\) \{')
  l=$(first_line "$alp" 'sHoldLockForAudio = v\.holdAudio;')
  arm=$(first_line "$alp" 'armIdleWatcher\(appCtx, uid\);')
  if [ "$(count "$alp" 'sHoldLockForAudio = ')" -ne 1 ] || [ -z "$l" ] || [ -z "$g" ] || [ -z "$arm" ] \
     || [ "$g" -ge "$l" ] || [ "$l" -ge "$arm" ]; then
    echo "  FAIL  S2 applyLivePrefs does not set sHoldLockForAudio = v.holdAudio once, after its guard, before armIdleWatcher" >&2; bad=1
  fi
  # S3: applyRoamedPrefs reads holdaudio= and sets the static from the parse.
  [ "$(count "$arp" 'l\.startsWith\("holdaudio="\)\) holdaudio = l\.substring\(10\)\.trim\(\);')" -eq 1 ] \
    && [ "$(count "$arp" 'RoamedPrefs\.parse\(idle, wipe, wipesaved, holdlock, holdaudio, ')" -eq 1 ] \
    && [ "$(count "$arp" 'sHoldLockForAudio = rp\.holdAudio;')" -eq 1 ] \
    || { echo "  FAIL  S3 applyRoamedPrefs does not read holdaudio= into sHoldLockForAudio through RoamedPrefs.parse" >&2; bad=1; }
  # S4: the picker: the heading, both boxes, the default, one guard call with both keys, three writes, one send.
  for s in '"Before standby, wait for:"' 'holdBox\.setText\("app installs"\);' 'audioBox\.setText\("audio playing"\);' \
           '^ *audioBox\.setChecked\(!"0"\.equals\(readPrefValue\("holdaudio"\)\)\);$' \
           '^ *"holdaudio", audioBox\.isChecked\(\) \? "" : "0"\), \(\) -> \{$' \
           '^ *final boolean audioOk = setPref\("holdaudio", audioBox\.isChecked\(\) \? "" : "0"\);$' \
           '^ *if \(idleOk && holdOk && audioOk\) live = sendLivePrefs\(\);$' \
           'holdWrap\.addView\(audioBox, '; do
    [ "$(count "$sip" "$s")" -eq 1 ] || { echo "  FAIL  S4 showIdlePicker does not hold exactly one '$s'" >&2; bad=1; }
  done
  [ "$(count "$sip" 'PresetPicker\.change\(')" -eq 1 ] \
    || { echo "  FAIL  S4 showIdlePicker does not save through one PresetPicker.change call" >&2; bad=1; }
  # S5: the live send carries the value nowhere-prefs holds.
  [ "$(count "$slp" 'EXTRA_HOLDAUDIO, readPrefValue\("holdaudio"\)')" -eq 1 ] \
    || { echo "  FAIL  S5 sendLivePrefs does not carry EXTRA_HOLDAUDIO, readPrefValue(\"holdaudio\")" >&2; bad=1; }
  # S6: the static's comment no longer says it waits for the checkbox.
  [ "$(grep -c 'until the checkbox' "$ch")" -eq 0 ] \
    || { echo "  FAIL  S6 ChooserActivity still says sHoldLockForAudio waits 'until the checkbox lands'" >&2; bad=1; }
  [ "$bad" -eq 0 ]
}

# suite <RoamedPrefs> <ProfileActivity> <ChooserActivity> <PrefsLiveReceiver> <PresetPicker> <ProfilePresets>
#   -> 0 pass, 1 a case or pin failed, 2 extraction failed, 3 did not compile.
suite() {
  local rp="$1" pa="$2" ch="$3" rv="$4" pp="$5" pps="$6" d o out rc
  d=$(mktemp -d -p "$W") || return 3
  o="$d/src/com/nowhere/chooser"
  mkdir -p "$o"
  cp "$rp" "$o/RoamedPrefs.java"; cp "$pp" "$o/PresetPicker.java"; cp "$pps" "$o/ProfilePresets.java"
  cp "$SRC/WipeOnSave.java" "$SRC/WipeChoice.java" "$SRC/SettingsText.java" "$SRC/MobileData.java" "$o/"
  cp "$CASES" "$o/AudioHoldPrefCases.java"
  lifted "$pa" "$ch" "$rv" "$o/Lifted.java" || { rm -rf "$d"; return 2; }
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$o"/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.AudioHoldPrefCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] || return 1
  pins "$rv" "$ch" "$pa"
}

echo "== holdaudio= ($SRC)"
suite "$RP" "$PA" "$CH" "$RV" "$PP" "$PPS" || { echo "FAILED"; exit 1; }
echo "pins: ok"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not apply, extract or compile proves nothing)"
mut() { # mut <label> <RP|PA|CH|RV|PP|PPS> <perl-expr>
  local d c rc orig why rp="$RP" pa="$PA" ch="$CH" rv="$RV" pp="$PP" pps="$PPS"
  d=$(mktemp -d -p "$W") || return 1
  case "$2" in
    RP) orig="$RP"; c="$d/RoamedPrefs.java"; rp="$c" ;;
    PA) orig="$PA"; c="$d/ProfileActivity.java"; pa="$c" ;;
    CH) orig="$CH"; c="$d/ChooserActivity.java"; ch="$c" ;;
    RV) orig="$RV"; c="$d/PrefsLiveReceiver.java"; rv="$c" ;;
    PP) orig="$PP"; c="$d/PresetPicker.java"; pp="$c" ;;
    PPS) orig="$PPS"; c="$d/ProfilePresets.java"; pps="$c" ;;
    *) echo "  ERROR     $1 -- unknown file $2"; rm -rf "$d"; return 1 ;;
  esac
  cp "$orig" "$c"
  if ! perl -0pi -e "$3" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  why=$(suite "$rp" "$pa" "$ch" "$rv" "$pp" "$pps" 2>&1); rc=$?
  rm -rf "$d"
  case "$rc" in
    1) echo "  CONVICTED $1 --$(printf '%s\n' "$why" | grep -m1 'FAIL' | sed 's/^ *FAIL//')"; return 0 ;;
    0) echo "  SURVIVED  $1"; return 1 ;;
    *) echo "  BROKEN    $1 -- the mutant did not extract or compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "U1 the default flipped (holdaudio absent reads Off)" RP 's/!"0"\.equals\(holdaudio\)/"1".equals(holdaudio)/' || fails=$((fails+1))
mut "U2 prefsText does not write the key" PA 's/\n *if \("0"\.equals\(holdaudio\)\) sb\.append\("holdaudio=0\\n"\);//' || fails=$((fails+1))
mut "U3 Hardened's audio cell is On (\"\")" PPS 's/(new Row\("holdaudio",\n[^\n]*\n[^\n]*\n\s*new String\[\]\{ "", "0" \},\n\s*"", "", )"0"/$1""/' || fails=$((fails+1))
mut "U4 the receiver ignores the extra" RV 's/intent\.getStringExtra\(EXTRA_HOLDAUDIO\)/null/' || fails=$((fails+1))
mut "U5 PresetPicker does not read the key" PP 's/(else if \(k\.equals\("holdaudio"\)\) out\.put\(k, )"0"\.equals\(prefValue\(prefsText, "holdaudio"\)\) \? "0" : ""\)/$1"")/' || fails=$((fails+1))
mut "U6 applyLivePrefs does not set sHoldLockForAudio" CH 's/\n *sHoldLockForAudio = v\.holdAudio;//' || fails=$((fails+1))
mut "U7 applyRoamedPrefs does not set sHoldLockForAudio" CH 's/\n *sHoldLockForAudio = rp\.holdAudio;//' || fails=$((fails+1))
mut "U8 applyRoamedPrefs does not read holdaudio=" CH 's/\n *else if \(l\.startsWith\("holdaudio="\)\) holdaudio = l\.substring\(10\)\.trim\(\);//' || fails=$((fails+1))
mut "U9 the idle Save sends without the audio write" PA 's/if \(idleOk && holdOk && audioOk\) live = sendLivePrefs\(\);/if (idleOk \&\& holdOk) live = sendLivePrefs();/' || fails=$((fails+1))
mut "U10 sendLivePrefs drops the extra" PA 's/\n *\.putExtra\(PrefsLiveReceiver\.EXTRA_HOLDAUDIO, readPrefValue\("holdaudio"\)\)//' || fails=$((fails+1))
mut "U11 the box starts Off" PA 's/audioBox\.setChecked\(!"0"\.equals\(readPrefValue\("holdaudio"\)\)\);/audioBox.setChecked("1".equals(readPrefValue("holdaudio")));/' || fails=$((fails+1))
mut "U12 the Save writes the box inverted" PA 's/(final boolean audioOk = setPref\("holdaudio", audioBox\.isChecked\(\) \? )"" : "0"\);/$1"0" : "");/' || fails=$((fails+1))
mut "U13 PresetPicker routes holdaudio to no file" PP 's/ \|\| key\.equals\("holdaudio"\)//' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "PASS: 13 of 13 mutants convicted" || { echo "== $fails mutant(s) not convicted"; exit 1; }
