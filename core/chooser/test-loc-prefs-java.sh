#!/usr/bin/env bash
# test-loc-prefs-java.sh [<ProfileActivity.java>] [--mutate] -- the Profile screen's Location services prefs, run
# under javac (NWP-20261016-45).
#
# WHY THIS IS COMMITTED. The two switches store a profile's network-location and geocoding choice in its nowhere-prefs,
# which every chooser rewrites WHOLE from a fixed key list (setPref). The rules there decide what the phone does and
# none of them executed off-device: a file written before these keys existed must read Off (the decided default); the
# file must stay byte for byte what an older chooser wrote while both are Off, so nothing an older reader knows moves; a
# stored value is On only when it is exactly "1", the same rule roamd's loc_on applies when it writes Settings.Global
# (test-locglobals.sh); and setPref's read-modify step must carry every OTHER key through a write -- a logoff's locale
# capture that dropped geocoder, or two arguments trading places, would switch a profile's choice off or onto the wrong
# setting with CI green. Plus who is offered the screen (a stored profile on an image with GrapheneOS's provider; never
# a throwaway or an offline sign-in, NWP-20260924-02), and the reply rule: the screen may say a switch is on or off only
# when roamd read THAT setting back as THAT value. A write that fails leaves the file as it was (setPref writes through
# StoreInstaller.writeAtomic's temp + rename, NWP-20261021-06), and the switch still asks roamd to apply the file, the
# screen is redrawn from it, and the toast says what the FILE holds -- the switches, the file and the phone agree at once. core/chooser/tests/loc-prefs/run.sh lifts
# prefValueIn, prefsText, prefsUpdated, locPrefOn, locOffered, locReplyValue, locApplied, locApplyToast,
# locNotSavedToast, the two key constants and the prefs file's name by signature and runs LocPrefsCases against them,
# and pins the Android-only glue in the source (setPref's file I/O, readPrefsText, the switch handler, the rows' keys,
# the Preferences branch, the provider test).
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (exit 2), like the other javac suites.
#
#   bash test-loc-prefs-java.sh            # the cases
#   bash test-loc-prefs-java.sh --mutate   # ... plus broken copies that must each FAIL the cases
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/src/com/nowhere/chooser/ProfileActivity.java"
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SRC="$a" ;; esac; done
RUN="$HERE/tests/loc-prefs/run.sh"
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
export JAVAC JAVA
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
[ -f "$SRC" ] && [ -f "$RUN" ] || { echo "FAIL: missing $SRC or $RUN" >&2; exit 2; }

# suite <ProfileActivity.java> -> run.sh's code: 0 pass, 1 a case or pin failed (only this may convict a mutant), 2 a
# member did not extract, 3 the lifted class did not compile.
suite() { bash "$RUN" "$1"; }

echo "== $SRC"
suite "$SRC"; rc=$?
if [ "$rc" -ne 0 ]; then echo "FAILED (rc=$rc)"; [ "$rc" -eq 1 ] && exit 1 || exit 2; fi
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by behaviour; one that does not apply or compile is a failure)"
mut() { # mut <label> <perl-expr> [<lines-that-must-change>]
  local d m rc changed; d=$(mktemp -d); m="$d/ProfileActivity.java"
  if ! perl -0pe "$2" "$SRC" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$SRC" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  changed=$(diff "$SRC" "$m" | grep -c '^>')
  if [ "$changed" -ne "${3:-1}" ]; then
    echo "  ERROR     $1 -- the mutation changed $changed line(s), expected ${3:-1}"; rm -rf "$d"; return 1; fi
  suite "$m" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not extract or compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "J1 any non-empty stored value is On"           's/return v != null && "1"\.equals\(v\.trim\(\)\);/return v != null \&\& !v.trim().isEmpty();/' || fails=$((fails+1))
mut "J2 the stored value is not trimmed"            's/return v != null && "1"\.equals\(v\.trim\(\)\);/return v != null \&\& "1".equals(v);/' || fails=$((fails+1))
mut "J3 lines end only at a newline (a lone CR joins lines)" 's/text\.split\("\\r\\n\|\\r\|\\n", -1\)/text.split("\\n", -1)/' || fails=$((fails+1))
mut "J4 the parsed value is not trimmed"            's/if \(line\.startsWith\(p\)\) return line\.substring\(p\.length\(\)\)\.trim\(\);/if (line.startsWith(p)) return line.substring(p.length());/' || fails=$((fails+1))
mut "J5 the netloc line is written for any non-empty value" 's/if \(locPrefOn\(netloc\)\) sb\.append/if (!netloc.isEmpty()) sb.append/' || fails=$((fails+1))
mut "J6 the stored value is copied, not normalised to 1" 's/if \(locPrefOn\(geocoder\)\) sb\.append\(PREF_GEOCODER\)\.append\("=1\\n"\);/if (locPrefOn(geocoder)) sb.append(PREF_GEOCODER).append("=").append(geocoder).append("\\n");/' || fails=$((fails+1))
mut "J7 Off is written as netloc=0 (the file no longer matches an old one)" 's/if \(locPrefOn\(netloc\)\) sb\.append\(PREF_NETLOC\)\.append\("=1\\n"\);/sb.append(PREF_NETLOC).append(locPrefOn(netloc) ? "=1\\n" : "=0\\n");/' || fails=$((fails+1))
mut "J8 the geocoder switch is written under the netloc key" 's/if \(locPrefOn\(geocoder\)\) sb\.append\(PREF_GEOCODER\)/if (locPrefOn(geocoder)) sb.append(PREF_NETLOC)/' || fails=$((fails+1))
mut "J9 a reply's value counts without its OK APPLIED verdict" 's/ \|\| !reply\.startsWith\("OK APPLIED "\)\) return "";/) return "";/' || fails=$((fails+1))
mut "J10 the toast claims the change without a confirmation" 's/        if \(!locApplied\(reply, key, on\)\) \{/        if (false) {/' || fails=$((fails+1))
mut "J11 the geocoder key is renamed"               's/static final String PREF_GEOCODER = "geocoder";/static final String PREF_GEOCODER = "geocode";/' || fails=$((fails+1))
mut "J12 the switch stores \"true\", not \"1\""     's/final boolean saved = setPref\(key, on \? "1" : ""\);/final boolean saved = setPref(key, on ? "true" : "");/' || fails=$((fails+1))
mut "J13 the LAST matching line wins"               's/        String p = key \+ "=";\n(        for \(String line : text\.split\("[^"]*", -1\)\) \{\n)            if \(line\.startsWith\(p\)\) return line\.substring\(p\.length\(\)\)\.trim\(\);\n        \}\n        return "";/        String p = key + "=", last = "";\n$1            if (line.startsWith(p)) last = line.substring(p.length()).trim();\n        }\n        return last;/' 3 || fails=$((fails+1))
mut "J14 setPref's composer gets netloc and geocoder swapped" 's/return prefsText\(tz, loc, idle, wipe, holdlock, holdaudio, vpn, vpnlock, netloc, geocoder, mobiledata,\n/return prefsText(tz, loc, idle, wipe, holdlock, holdaudio, vpn, vpnlock, geocoder, netloc, mobiledata,\n/' || fails=$((fails+1))
mut "J15 netloc is carried from the geocoder line"  's/(String netloc = PREF_NETLOC\.equals\(key\) \? value : prefValueIn\(cur, )PREF_NETLOC\);/${1}PREF_GEOCODER);/' || fails=$((fails+1))
mut "J16 any other write drops geocoder"            's/String geocoder = PREF_GEOCODER\.equals\(key\) \? value : prefValueIn\(cur, PREF_GEOCODER\);/String geocoder = PREF_GEOCODER.equals(key) ? value : "";/' || fails=$((fails+1))
mut "J17 holdlock and vpn trade places"             's/return prefsText\(tz, loc, idle, wipe, holdlock, holdaudio, vpn, /return prefsText(tz, loc, idle, wipe, vpn, holdaudio, holdlock, /' || fails=$((fails+1))
mut "J18 the empty-locale fallback is dropped"      's/if \(loc\.isEmpty\(\)\) loc = defaultLocale;/if (loc.isEmpty()) loc = "";/' || fails=$((fails+1))
mut "J19 setPref no longer passes the device locale" 's/prefsUpdated\(readPrefsText\(\), key, value, java\.util\.Locale\.getDefault\(\)\.toLanguageTag\(\)\)/prefsUpdated(readPrefsText(), key, value, "")/' || fails=$((fails+1))
mut "J20 setPref reports a failed write as landed"  's/(android\.util\.Log\.w\("NowhereChooser", "setPref " \+ key, e\);\n)            return false;/${1}            return true;/' || fails=$((fails+1))
mut "J21 the switch shows Network location's state on both rows" 's/        sw\.setChecked\(locPrefOn\(readPrefValue\(key\)\)\);/        sw.setChecked(locPrefOn(readPrefValue(PREF_NETLOC)));/' || fails=$((fails+1))
mut "J22 a failed write is not redrawn: the switches keep the tap, not the file" 's/            if \(!saved\) showLocationServices\(\);/            if (false) showLocationServices();/' || fails=$((fails+1))
mut "J23 a failed write drops its APPLY-LOCATION (the phone keeps the old value)" 's/            if \(!saved\) showLocationServices\(\);/            if (!saved) { showLocationServices(); return; }/' || fails=$((fails+1))
mut "J24 every answer is toasted as if still chosen" 's/boolean stillChosen = locPrefOn\(readPrefValue\(key\)\) == want;/boolean stillChosen = true;/' || fails=$((fails+1))
mut "J25 the Geocoding row stores under netloc"     's/                PREF_GEOCODER\), new LinearLayout\.LayoutParams\(MATCH, WRAP\)\);/                PREF_NETLOC), new LinearLayout.LayoutParams(MATCH, WRAP));/' || fails=$((fails+1))
mut "J26 Preferences never offers the screen"       's/            if \(locOffered\(sessionType, offlineSession, locServicesAvailable\(\)\)\) \{/            if (false) {/' || fails=$((fails+1))
mut "J27 the provider test always passes"           's/        return new java\.io\.File\(LOC_PROVIDER_APK\)\.isFile\(\);/        return true;/' || fails=$((fails+1))
mut "J28 every session is offered the screen"       's/return providerPresent && !offline && "STORED"\.equals\(sessionType\);/return providerPresent;/' || fails=$((fails+1))
mut "J29 the offline flag is ignored"               's/return providerPresent && !offline && "STORED"/return providerPresent \&\& "STORED"/' || fails=$((fails+1))
mut "J30 any session that is not LOCAL is offered it (an UNKNOWN one too)" 's/return providerPresent && !offline && "STORED"\.equals\(sessionType\);/return providerPresent \&\& !offline \&\& !"LOCAL".equals(sessionType);/' || fails=$((fails+1))
mut "J31 the provider is not asked (Diaspore gets the screen)" 's/return providerPresent && !offline && /return !offline \&\& /' || fails=$((fails+1))
mut "J32 any read-back value confirms (the value is not compared)" 's/return \(on \? "2" : "0"\)\.equals\(locReplyValue\(reply, key\)\);/return !locReplyValue(reply, key).isEmpty();/' || fails=$((fails+1))
mut "J33 geocoding is judged by network_location="  's/PREF_GEOCODER\.equals\(key\) \? "geocoder=" : null;/PREF_GEOCODER.equals(key) ? "network_location=" : null;/' || fails=$((fails+1))
mut "J34 On expects 1 read back, not 2"             's/return \(on \? "2" : "0"\)\.equals/return (on ? "1" : "0").equals/' || fails=$((fails+1))
mut "J35 a tap a later tap replaced still toasts"   's/        if \(!stillChosen\) return null;/        if (false) return null;/' || fails=$((fails+1))
mut "J36 the not-saved toast calls the file's value the phone's without a read-back" 's/        if \(!locApplied\(reply, key, nowOn\)\) \{/        if (false) {/' || fails=$((fails+1))
mut "J37 a failed write a later tap replaced still toasts" 's/(static String locNotSavedToast\([^\n]*\n)        if \(!stillChosen\) return null;/${1}        if (false) return null;/' || fails=$((fails+1))
mut "J38 the not-saved toast says on for off and off for on" 's/what \+ " is now " \+ \(nowOn \?/what + " is now " + (!nowOn ?/' || fails=$((fails+1))
mut "J39 the reader's file name is changed (the writer still writes PREFS_FILE)" 's/new java\.io\.File\(getFilesDir\(\), PREFS_FILE\)\.toPath\(\)/new java.io.File(getFilesDir(), "nowhere-prefz").toPath()/' || fails=$((fails+1))
mut "J40 the reader always gives an empty file"     's/            return new String\(java\.nio\.file\.Files\.readAllBytes\([^\n]*\n[^\n]*StandardCharsets\.UTF_8\);/            return "";/' || fails=$((fails+1))
mut "J41 the file is renamed for reader and writer alike (roamd reads nowhere-prefs)" 's/static final String PREFS_FILE = "nowhere-prefs";/static final String PREFS_FILE = "nowhere-prefz";/' || fails=$((fails+1))
mut "J42 the writer spells its own file name again" 's/StoreInstaller\.writeAtomic\(new java\.io\.File\(getFilesDir\(\), PREFS_FILE\), text\);/StoreInstaller.writeAtomic(new java.io.File(getFilesDir(), "nowhere-prefs"), text);/' || fails=$((fails+1))
mut "J43 a failed write's toast is the tap, not the file" 's/final boolean want = saved \? on : locPrefOn\(readPrefValue\(key\)\);/final boolean want = on;/' || fails=$((fails+1))
mut "J44 a failed write is toasted as a saved one"  's/: locNotSavedToast\(title, key, want, reply, stillChosen\);/: locApplyToast(title, key, want, reply, stillChosen);/' || fails=$((fails+1))
mut "J45 setPref writes nowhere-prefs directly again (FileWriter truncates it first)" 's/        try \{\n(            )StoreInstaller\.writeAtomic\(new java\.io\.File\(getFilesDir\(\), PREFS_FILE\), text\);\n/        try (java.io.FileWriter fw = new java.io.FileWriter(new java.io.File(getFilesDir(), PREFS_FILE))) {\n${1}fw.write(text);\n/' 2 || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
