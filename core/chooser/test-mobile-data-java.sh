#!/usr/bin/env bash
# test-mobile-data-java.sh [--mutate] -- the Profile screen's Mobile data switch, run under javac (NWP-20261026-07).
#
# WHY THIS IS COMMITTED. A profile's mobile-data choice is a TRI-STATE in its nowhere-prefs (mobiledata=1, mobiledata=0,
# or no line = the gate's value), and the screen may say a change is applied only when roamd read THAT value back. None
# of it executed off-device, and each rule fails quietly: a "2" read as On, a profile with no choice shown as Off, a
# throwaway or offline sign-in offered a switch, a toast that claims a change the daemon never confirmed, a pref written
# AFTER the daemon was asked (roamd applies what the file holds, so the phone would take the previous choice), and a
# setPref that drops the line (prefsText is a fixed key list). MobileData.java decides all of it and is pure Java, so
# core/chooser/tests/mobile-data/run.sh compiles it directly and runs MobileDataCases; core/chooser/tests/loc-prefs runs
# the prefsText / prefsUpdated cases against ProfileActivity; the PINS below check that ProfileActivity's Android-only
# glue (a) offers the row only through MobileData.offered, (b) writes the pref before sending APPLY-MOBILE-DATA and
# (c) toasts only through MobileData.applyToast / notSavedToast. ProfileActivity itself is compiled by the merger's full
# javac check / `m NowhereChooser`, not here.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (exit 2), like the other javac suites.
#
#   bash test-mobile-data-java.sh            # the cases and the pins
#   bash test-mobile-data-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

HERE="$(cd "$(dirname "$0")" && pwd)"
DIR="$HERE/src/com/nowhere/chooser"
MD="$DIR/MobileData.java"
PA="$DIR/ProfileActivity.java"
RUN="$HERE/tests/mobile-data/run.sh"
LOCRUN="$HERE/tests/loc-prefs/run.sh"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export W TMPDIR="$W"

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip: install a JDK or run it on the" \
       "build VM." >&2
  exit 2
fi
export JAVAC JAVA
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
[ -f "$PA" ] && [ -f "$RUN" ] && [ -f "$LOCRUN" ] || { echo "FAIL: missing $PA, $RUN or $LOCRUN" >&2; exit 2; }

# pin <file> <label> <perl-regex>: a textual check on the call sites (anchors, not line numbers).
pin() {
  perl -0ne "exit(/$3/s ? 0 : 1)" "$1" || { echo "  PIN   $2" >&2; return 1; }
}

# suite <MobileData.java> <ProfileActivity.java> -> 0 pass, 1 a case or a pin failed (only this may convict a mutant),
# 2 a member did not extract, 3 a class did not compile.
suite() {
  local md="$1" pa="$2" rc=0
  [ -f "$md" ] || { echo "  PIN   MobileData.java does not exist" >&2; return 1; }
  pin "$pa" "Preferences does not offer Mobile data only through MobileData.offered" \
    'if \(MobileData\.offered\(sessionType, offlineSession\)\) \{\n\s*rows\.add\("Mobile data"\);\n\s*acts\.add\(\(\) -> showMobileData\(\)\);\n\s*\}' || return 1
  [ "$(grep -c 'rows\.add("Mobile data")' "$pa")" = 1 ] || { echo "  PIN   the Mobile data row is added more than once" >&2; return 1; }
  [ "$(grep -c '() -> showMobileData()' "$pa")" = 1 ] || { echo "  PIN   a second door into showMobileData" >&2; return 1; }
  pin "$pa" "the switch does not write the pref (setPref) BEFORE it sends APPLY-MOBILE-DATA" \
    'final boolean saved = setPref\(MobileData\.PREF, on \? "1" : "0"\);(?:(?!sendDaemon).)*?MD_APPLY\.execute\(\(\) -> \{\n\s*final String reply = sendDaemon\("APPLY-MOBILE-DATA\\n"\);' || return 1
  [ "$(grep -c 'sendDaemon("APPLY-MOBILE-DATA' "$pa")" = 2 ] || { echo "  PIN   APPLY-MOBILE-DATA is not sent exactly twice (the two rows)" >&2; return 1; }
  [ "$(grep -c 'setPref(MobileData\.PREF' "$pa")" = 1 ] || { echo "  PIN   the pref is not written exactly once" >&2; return 1; }
  pin "$pa" "the switch does not toast only through MobileData.applyToast / notSavedToast" \
    'String t = saved \? MobileData\.applyToast\(on, reply, stillChosen\)\n\s*: MobileData\.notSavedToast\(nowOn, reply, stillChosen\);\n\s*if \(t != null\) android\.widget\.Toast\.makeText' || return 1
  pin "$pa" "the Data roaming row does not write the pref (setPref) BEFORE it sends APPLY-MOBILE-DATA" \
    'final boolean saved = setPref\(MobileData\.ROAM_PREF, on \? "1" : "0"\);(?:(?!sendDaemon).)*?MD_APPLY\.execute\(\(\) -> \{\n\s*final String reply = sendDaemon\("APPLY-MOBILE-DATA\\n"\);' || return 1
  [ "$(grep -c 'setPref(MobileData\.ROAM_PREF' "$pa")" = 1 ] || { echo "  PIN   the roaming pref is not written exactly once" >&2; return 1; }
  pin "$pa" "the Data roaming row does not toast only through MobileData.roamApplyToast / roamNotSavedToast" \
    'String t = saved \? MobileData\.roamApplyToast\(on, reply, stillChosen\)\n\s*: MobileData\.roamNotSavedToast\(nowOn, reply, stillChosen\);\n\s*if \(t != null\) android\.widget\.Toast\.makeText' || return 1
  if grep -q 'Data roaming on\|Data roaming off\|Data roaming is now' "$pa"; then
    echo "  PIN   ProfileActivity spells Data roaming toast copy itself" >&2; return 1; fi
  pin "$pa" "the Data roaming switch's initial state is not MobileData.switchChecked over the stored choice and the phone" \
    'sw\.setChecked\(MobileData\.switchChecked\(MobileData\.roamChoice\(readPrefValue\(MobileData\.ROAM_PREF\)\),\s*phoneRoamingOn\(\)\)\);' || return 1
  pin "$pa" "the screen does not add the Data roaming row beside Mobile data" \
    'll\.addView\(mdSwitchRow\(\), new LinearLayout\.LayoutParams\(MATCH, WRAP\)\);\n\s*ll\.addView\(roamSwitchRow\(\), new LinearLayout\.LayoutParams\(MATCH, WRAP\)\);' || return 1
  if grep -q 'Mobile data on\|Mobile data off\|Mobile data is now' "$pa"; then
    echo "  PIN   ProfileActivity spells Mobile data toast copy itself" >&2; return 1; fi
  pin "$pa" "the switch's initial state is not MobileData.switchChecked over the stored choice and the phone" \
    'sw\.setChecked\(MobileData\.switchChecked\(MobileData\.choice\(readPrefValue\(MobileData\.PREF\)\), phoneDataOn\(\)\)\);' || return 1
  bash "$RUN" "$md" || rc=$?
  [ "$rc" = 0 ] || return "$rc"
  MOBILEDATA_JAVA="$md" bash "$LOCRUN" "$pa" || rc=$?
  return "$rc"
}

echo "== $MD"
suite "$MD" "$PA"; rc=$?
if [ "$rc" -ne 0 ]; then echo "FAILED (rc=$rc)"; [ "$rc" -eq 1 ] && exit 1 || exit 2; fi
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED; one that does not apply or compile is a failure)"
# mut <label> <md|pa> <perl-expr>: mutate MobileData.java or ProfileActivity.java and require the suite to exit 1.
mut() {
  local which="$2" src d m rc
  if [ "$which" = md ]; then src="$MD"; else src="$PA"; fi
  d=$(mktemp -d -p "$W"); m="$d/$(basename "$src")"
  if ! perl -0pe "$3" "$src" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$src" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  if [ "$which" = md ]; then suite "$m" "$PA" >"$d/out" 2>&1; rc=$?; else suite "$MD" "$m" >"$d/out" 2>&1; rc=$?; fi
  case "$rc" in
    0) echo "  SURVIVED  $1"; rm -rf "$d"; return 1 ;;
    1) echo "  convicted $1"; rm -rf "$d"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not extract or compile (rc=$rc)"; rm -rf "$d"; return 1 ;;
  esac
}
fails=0
mut "K1 a 2 is read as On"                      md 's/return "1"\.equals\(t\) \|\| "0"\.equals\(t\) \? t : "";/return "1".equals(t) || "0".equals(t) ? t : "2".equals(t) ? "1" : "";/' || fails=$((fails+1))
mut "K2 no choice is read as Off"               md 's/return phoneOn != null && phoneOn;/return false;/' || fails=$((fails+1))
mut "K3 an offline session is offered it"       md 's/return !offline && "STORED"\.equals\(sessionType\);/return "STORED".equals(sessionType);/' || fails=$((fails+1))
mut "K4 the toast trusts any OK reply"          md 's/(static String applyToast\([^\n]*\n[^\n]*\n[^\n]*\n)        if \(!applied\(reply, on\)\) \{/${1}        if (reply == null || !reply.startsWith("OK APPLIED ")) {/' || fails=$((fails+1))
mut "K5 the toast ignores stillChosen"          md 's/(static String applyToast\([^\n]*\n)        if \(!stillChosen\) return null;/${1}        if (false) return null;/' || fails=$((fails+1))
mut "K6 prefsText writes mobiledata= with no choice" pa 's/if \(!md\.isEmpty\(\)\) sb\.append\(MobileData\.PREF\)/sb.append(MobileData.PREF)/' || fails=$((fails+1))
mut "K7 prefsUpdated drops mobiledata on another key's write" pa 's/MobileData\.PREF\.equals\(key\) \? value : prefValueIn\(cur, MobileData\.PREF\);/MobileData.PREF.equals(key) ? value : "";/' || fails=$((fails+1))
mut "K8 the pref is written after the daemon is asked" pa 's/final boolean saved = setPref\(MobileData\.PREF, on \? "1" : "0"\);/final boolean saved = true;/; s/(final String reply = sendDaemon\("APPLY-MOBILE-DATA\\n"\);)/$1 setPref(MobileData.PREF, on ? "1" : "0");/' || fails=$((fails+1))
mut "K9 the row is offered without MobileData.offered" pa 's/if \(MobileData\.offered\(sessionType, offlineSession\)\) \{/if (true) {/' || fails=$((fails+1))
mut "K10 the toast is spelled in ProfileActivity" pa 's/String t = saved \? MobileData\.applyToast\(on, reply, stillChosen\)/String t = saved ? "Mobile data on"/' || fails=$((fails+1))
mut "K11 notSavedToast calls the file's value the phone's without a read-back" md 's/        if \(!applied\(reply, nowOn\)\) \{/        if (false) {/' || fails=$((fails+1))
mut "K12 the read-back value is not compared"   md 's/return \(on \? "1" : "0"\)\.equals\(replyValue\(reply\)\);/return !replyValue(reply).isEmpty();/' || fails=$((fails+1))
mut "T1 a reply without the roaming token is read as applied" md 's/(static String roamReplyValue\(String reply\) \{\n[^\n]*\n[^\n]*\n)/$1        if (!reply.contains("data_roaming=")) return "1";\n/' || fails=$((fails+1))
mut "T2 the roaming toast reads mobile_data's value" md 's/return \(on \? "1" : "0"\)\.equals\(roamReplyValue\(reply\)\);/return (on ? "1" : "0").equals(replyValue(reply));/' || fails=$((fails+1))
mut "T3 a ? is read as 0"                       md 's/return "1"\.equals\(v\) \|\| "0"\.equals\(v\) \? v : "";/return "1".equals(v) ? v : "0";/' || fails=$((fails+1))
mut "T4 prefsText writes dataroaming= with no choice" pa 's/if \(!dr\.isEmpty\(\)\) sb\.append\(MobileData\.ROAM_PREF\)/sb.append(MobileData.ROAM_PREF)/' || fails=$((fails+1))
mut "T5 prefsUpdated drops dataroaming on another key's write" pa 's/MobileData\.ROAM_PREF\.equals\(key\) \? value : prefValueIn\(cur, MobileData\.ROAM_PREF\);/MobileData.ROAM_PREF.equals(key) ? value : "";/' || fails=$((fails+1))
mut "T6 the roaming pref is written after the daemon is asked" pa 's/final boolean saved = setPref\(MobileData\.ROAM_PREF, on \? "1" : "0"\);/final boolean saved = true;/; s/(final String reply = sendDaemon\("APPLY-MOBILE-DATA\\n"\);)(?![\s\S]*final String reply = sendDaemon)/$1 setPref(MobileData.ROAM_PREF, on ? "1" : "0");/' || fails=$((fails+1))
mut "T7 the roaming toast is spelled in ProfileActivity" pa 's/String t = saved \? MobileData\.roamApplyToast\(on, reply, stillChosen\)/String t = saved ? "Data roaming on"/' || fails=$((fails+1))
mut "T8 the roaming toast ignores stillChosen"  md 's/(static String roamApplyToast\([^\n]*\n)        if \(!stillChosen\) return null;/${1}        if (false) return null;/' || fails=$((fails+1))
mut "T9 the roaming row reads Mobile data's key" pa 's/(sw\.setChecked\(MobileData\.switchChecked\(MobileData\.roamChoice\(readPrefValue\()MobileData\.ROAM_PREF/${1}MobileData.PREF/' || fails=$((fails+1))
mut "T10 notSavedToast claims roaming without a read-back" md 's/        if \(!roamApplied\(reply, nowOn\)\) \{/        if (false) {/' || fails=$((fails+1))
mut "T11 the roaming key is renamed"            md 's/ROAM_PREF = "dataroaming"/ROAM_PREF = "roaming"/' || fails=$((fails+1))
[ "$fails" -eq 0 ] || { echo "FAILED: $fails mutant(s) not convicted"; exit 1; }
echo "all mutants convicted"
