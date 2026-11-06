#!/usr/bin/env bash
# test-hotspot-java.sh [--mutate] -- the gate's HotspotService / HotspotReceiver contract, under javac (NWP-20261028-08).
#
# WHY THIS IS COMMITTED. A session's hotspot is started by the user-0 chooser for it, and its name and passphrase are
# the profile's own: they cross only as a Binder parcel and must never reach a log, a reply or argv, and a release must
# overwrite them. Hotspot.java is pure and runs under javac against HotspotCases; the platform glue
# (HotspotService, HotspotReceiver, the manifest) cannot compile off the build host, so tests/hotspot/run.sh pins it as
# data: both permissions declared once, both components unexported with no intent-filter, mayStart before any
# framework call in START, the owner recorded before startTethering, the receiver's random reset, no Log line naming
# the ssid or passphrase. The build host's `m NowhereChooser` compiles the glue. A timeout or no reply toasts "the phone
# didn't answer", any other unconfirmed reply "didn't confirm it" (NWP-20261113-07, mutants T1-T4).
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (exit 2).
#
#   bash test-hotspot-java.sh            # the cases and pins
#   bash test-hotspot-java.sh --mutate   # ... plus broken copies that must each FAIL them
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
S="$HERE/src/com/nowhere/chooser"
HS="$S/Hotspot.java"; SV="$S/HotspotService.java"; RC="$S/HotspotReceiver.java"; MF="$HERE/AndroidManifest.xml"
PA="$S/ProfileActivity.java"; HC="$S/HotspotClient.java"
RUN="$HERE/tests/hotspot/run.sh"
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
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
for f in "$HS" "$SV" "$RC" "$MF" "$PA" "$HC" "$RUN"; do
  [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 2; }
done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export W

suite() { bash "$RUN" "$1" "$2" "$3" "$4" "$5"; }

echo "== cases and pins"
suite "$HS" "$SV" "$RC" "$MF" "$PA"; rc=$?
if [ "$rc" -ne 0 ]; then echo "FAILED (rc=$rc)"; [ "$rc" -eq 1 ] && exit 1 || exit 2; fi
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED; one that does not apply or compile is a failure)"
mut() { # mut <label> <HS|SV|RC|MF|PA> <perl-expr> [<lines-that-must-change>]
  local d src name rc changed
  d=$(mktemp -d -p "$W")
  cp "$HS" "$d/Hotspot.java"; cp "$SV" "$d/HotspotService.java"; cp "$RC" "$d/HotspotReceiver.java"; cp "$MF" "$d/AndroidManifest.xml"
  mkdir -p "$d/pa"; cp "$PA" "$d/pa/ProfileActivity.java"; cp "$HC" "$d/pa/HotspotClient.java"
  case "$2" in HS) name=Hotspot.java ;; SV) name=HotspotService.java ;; RC) name=HotspotReceiver.java ;; MF) name=AndroidManifest.xml ;; PA) name=pa/ProfileActivity.java ;; esac
  src="$d/$name"; cp "$src" "$src.orig"
  if ! perl -0pi -e "$3" "$src"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$src" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$src.orig" "$src"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  changed=$(diff "$src.orig" "$src" | grep -c '^>')
  if [ "$changed" -ne "${4:-1}" ]; then
    echo "  ERROR     $1 -- the mutation changed $changed line(s), expected ${4:-1}"; rm -rf "$d"; return 1; fi
  suite "$d/Hotspot.java" "$d/HotspotService.java" "$d/HotspotReceiver.java" "$d/AndroidManifest.xml" "$d/pa/ProfileActivity.java" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile or run (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "P1 validPassphrase accepts 64" HS 's/p\.length\(\) > 63/p.length() > 64/' || fails=$((fails+1))
mut "P2 validSsid counts characters, not bytes" HS 's/int n = s\.getBytes\(StandardCharsets\.UTF_8\)\.length;/int n = s.length();/' || fails=$((fails+1))
mut "P3 mayStart drops the foreground check" HS 's/ && callerUser == foregroundUser;/;/' || fails=$((fails+1))
mut "P4 releaseDecision releases another owner's" HS 's/owner\.intValue\(\) == uid\) \? Release/owner.intValue() != -2) ? Release/' || fails=$((fails+1))
mut "P5 resetPassphrase draws from 10 characters" HS 's/r\.nextInt\(ALNUM\.length\(\)\)/r.nextInt(10)/' || fails=$((fails+1))
mut "P6 a Log line prints the passphrase in HotspotService" SV 's/(String pass = data\.readString\(\);\n)/$1                android.util.Log.i("NowhereChooser", "start " + pass);\n/' 1 || fails=$((fails+1))
mut "P7 the owner is assigned after startTethering" SV 's/( *owner = callerUser;\n)( *tm\.startTethering\(.*?\n {20}\}\);\n)/$2$1/s' 1 || fails=$((fails+1))
mut "P7b the reply gains an exception header" SV 's/(reply\.writeString\(line\);)/reply.writeNoException();\n            $1/' 1 || fails=$((fails+1))
mut "P8 the service is exported" MF 's/(HotspotService" android:exported=")false"/${1}true"/' || fails=$((fails+1))
mut "P9 the receiver is exported" MF 's/(HotspotReceiver" android:exported=")false"/${1}true"/' || fails=$((fails+1))
mut "P10 NETWORK_SETTINGS is no longer declared" MF 's/<uses-permission android:name="android\.permission\.NETWORK_SETTINGS"\/>\n//' || fails=$((fails+1))
mut "P11 the receiver resets to a fixed name" RC 's/String s = Hotspot\.resetSsid\(rng\);/String s = "AndroidAP_0000";/' || fails=$((fails+1))
mut "P12 mayStart is checked after the framework call" SV 's/if \(!Hotspot\.mayStart\(sameApp, callerUser, ActivityManager\.getCurrentUser\(\)\)\) return Hotspot\.errLine\(Hotspot\.R_CALLER\);\n(\s*TetheringManager tm = tether\(\);)/$1\n            if (!Hotspot.mayStart(sameApp, callerUser, ActivityManager.getCurrentUser())) return Hotspot.errLine(Hotspot.R_CALLER);/' 1 || fails=$((fails+1))
mut "P14 the foreground is authorized before the lock (RF-005)" SV 's/(private String start\(Parcel data, String type, boolean sameApp, int callerUser\) \{\n)(\s*synchronized \(LOCK\) \{\n)(.*?\n)(\s*if \(!Hotspot\.mayStart\(.*?\n)/$1$4$2$3/s' 1 || fails=$((fails+1))
mut "P13 a regexp event counts as stop evidence" HS 's/(synchronized void onRegexs\(List<String> usb, List<String> bt\) \{)/$1 ifaceEvents++;/' || fails=$((fails+1))
mut "U1 the row is offered to an offline session" PA 's/Hotspot\.offered\(sessionType, offlineSession\)/Hotspot.offered(sessionType, false)/' || fails=$((fails+1))
mut "U2 the START sends the field's unsaved text" PA 's/HotspotClient\.start\(ProfileActivity\.this, type, saved\[0\], saved\[1\]\)/HotspotClient.start(ProfileActivity.this, type, nameF.getText().toString(), pwF.getText().toString())/' || fails=$((fails+1))
mut "U3 a toast is built with the SSID" PA 's/Hotspot\.toast\(type, on, reply\),/Hotspot.toast(type, on, reply) + saved[0],/' || fails=$((fails+1))
mut "U4 switchOn is true for wifi=0" HS 's/tok\.equals\(type \+ "=1"\)/tok.startsWith(type + "=")/' || fails=$((fails+1))
mut "U5 the row is offered without the offered() check" PA 's/if \(Hotspot\.offered\(sessionType, offlineSession\)\) \{/if (true) {/' || fails=$((fails+1))
mut "U6 the passphrase is logged by the screen" PA 's/(android\.util\.Log\.w\("NowhereChooser", "saveHotspot failed")\)/$1 + pass)/' || fails=$((fails+1))
mut "U7 prefsText gains a hotspot key" PA 's/(static String prefsText\([^\n]*\n)/$1        \/\/ hotspot\n/' || fails=$((fails+1))
mut "T1 a timeout toasts \"didn't confirm\" again" HS 's/ \|\| errLine\(R_TIMEOUT\)\.equals\(reply\)\) \{/) {/' || fails=$((fails+1))
mut "T2 an empty reply toasts \"didn't confirm\" again" HS 's/ \|\| ""\.equals\(reply\)//' || fails=$((fails+1))
mut "T3 a null reply toasts \"didn't confirm\" again" HS 's/reply == null \|\| "/"/' || fails=$((fails+1))
mut "T4 the no-answer branch swallows R_CALLER" HS 's/(errLine\(R_TIMEOUT\)\.equals\(reply\))\) \{/$1 || errLine(R_CALLER).equals(reply)) {/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
