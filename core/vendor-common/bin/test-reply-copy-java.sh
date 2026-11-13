#!/usr/bin/env bash
# test-reply-copy-java.sh [--mutate] -- the chooser's copy for a daemon that does not answer, run under javac (NWP-20261020-11).
#
# WHY THIS IS COMMITTED. sendDaemon/daemonCmd return "" on any failure, and the chooser used to render "" as an
# answer: the create form's strength meter said "too weak" and the gate Settings backup row said "every 2 minutes"
# whatever the owner had set (docs/backlog.md, "every user-facing daemon read/write that times out fails SILENTLY").
# ReplyCopy.java decides the words and is pure Java, so core/chooser/tests/reply-copy/run.sh compiles it directly and
# runs ReplyCopyCases; the PINS below check that the call sites (and the "Your data" apps line) actually ask it.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (see test-storage-usage-java.sh). javac comes from PATH, else from
# the build host's JDK; the version is printed first so the log proves which compiler ran.
#
#   bash test-reply-copy-java.sh            # the cases and the pins
#   bash test-reply-copy-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
# One temp root (NWP-20261113-11): every mutant dir, and run.sh's own, is made inside it and goes with it on exit.
W=$(mktemp -d) || exit 2
export TMPDIR="$W"
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
DIR="$root/core/chooser/src/com/nowhere/chooser"
RC="$DIR/ReplyCopy.java"
CH="$DIR/ChooserActivity.java"
PA="$DIR/ProfileActivity.java"
RUN="$root/core/chooser/tests/reply-copy/run.sh"
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
[ -f "$CH" ] && [ -f "$PA" ] && [ -f "$RUN" ] || { echo "FAIL: missing $CH, $PA or $RUN" >&2; exit 2; }

# pin <file> <label> <perl-regex>: a textual check on the call sites (anchors, not line numbers).
pin() {
  perl -0ne "exit(/$3/s ? 0 : 1)" "$1" || { echo "  PIN   $2" >&2; return 1; }
}

# suite <ReplyCopy.java> <ChooserActivity.java> <ProfileActivity.java> -> 0 pass, 1 a case or a pin failed, 3 compile.
suite() {
  local rc="$1" ch="$2" pa="$3"
  [ -f "$rc" ] || { echo "  PIN   ReplyCopy.java does not exist" >&2; return 1; }
  pin "$ch" "the gate's strengthCheck no longer decides through ReplyCopy.strength" \
    'strengthCheck = \(\) -> \{.*?ReplyCopy\.strength\(r\);\n\s*showStrength\(st\.state, st\.text\);.*?"nowhere-passcheck"' || return 1
  pin "$pa" "showSaveCeremony's strength check no longer decides through ReplyCopy.strength" \
    'sendDaemon\("CHECK-PASSPHRASE\\n" \+ \(nm == null[^\n]*\n\s*runOnUiThread\(\(\) -> \{\n\s*final ReplyCopy\.Strength st = ReplyCopy\.strength\(r\);' || return 1
  pin "$ch" "refreshBkRow does not render ReplyCopy.backupRow(GET-SYNC-INTERVAL)" \
    'refreshBkRow = \(\) -> new Thread\(\(\) -> \{\n\s*final String line = ReplyCopy\.backupRow\(daemonCmd\("GET-SYNC-INTERVAL"\)\);' || return 1
  local body; body=$(perl -0ne 'print $1 if /(refreshBkRow = \(\) -> new Thread.*?\}\)\.start\(\);)/s' "$ch")
  case "$body" in *"int sec = 120"*|*prettyInterval*) echo "  PIN   refreshBkRow still renders a default cadence" >&2; return 1 ;; esac
  pin "$ch" "the picker does not read cadenceSaved(SET-SYNC-INTERVAL's reply) and say so when unsaved" \
    'ReplyCopy\.cadenceSaved\(daemonCmd\("SET-SYNC-INTERVAL\\n" \+ secs\[w\]\)\);.*?if \(!saved\) android\.widget\.Toast' || return 1
  pin "$ch" "showStrength has no muted third state" \
    'private void showStrength\(ReplyCopy\.State state, String text\).*?ReplyCopy\.State\.UNKNOWN \? MUTED' || return 1
  # NWP-20261021-07: the four device-setting controls. Each read decides through flagOf (or OrNull), each SET's reply
  # through settingSaved, and a failed save reverts WITHOUT re-firing the listener and says so.
  pin "$ch" "the auto-install switch does not read GET-OTA-AUTO through flagOf and stay disabled on null" \
    'final Boolean on = ReplyCopy\.flagOf\(daemonCmd\("GET-OTA-AUTO"\)\);\s*runOnUiThread\(\(\) -> \{\s*if \(on == null\) \{[^\n]*\n\s*autoSw\.setEnabled\(false\);' || return 1
  pin "$ch" "the auto-install switch does not say a read that did not answer on swMsg" \
    'autoSw\.setEnabled\(false\);\s*settingVerdict\.accept\("Automatic install couldn.t be read right now' || return 1
  pin "$ch" "the auto-install switch ignores SET-OTA-AUTO's reply" \
    'ReplyCopy\.settingSaved\(daemonCmd\("SET-OTA-AUTO\\n" \+ \(c \? "1" : "0"\)\)\);\s*runOnUiThread\(\(\) -> \{\s*autoSw\.setEnabled\(true\);\s*if \(saved\) return;' || return 1
  pin "$ch" "a failed SET-OTA-AUTO does not revert with the listener detached, then say so on swMsg" \
    'if \(saved\) return;\s*autoSw\.setOnCheckedChangeListener\(null\);[^\n]*\n\s*autoSw\.setChecked\(!c\);\s*autoSw\.setOnCheckedChangeListener\(self\);.*?settingVerdict\.accept\("Couldn.t save that change — try again\."\);' || return 1
  pin "$ch" "the software-update screen has a second status line besides swMsg" \
    'final java\.util\.function\.Consumer<String> settingVerdict = msg -> \{[^}]*StatusLine\.error\(swMsg, msg\);' || return 1
  case "$(perl -0ne 'print $1 if /(final android\.widget\.Switch autoSw.*?doCheck = \(\) -> \{)/s' "$ch")" in
    *autoMsg*) echo "  PIN   a separate autoMsg line is back" >&2; return 1 ;; esac
  pin "$ch" "the status poll can erase a setting verdict (no watcher holding it over swMsg)" \
    'swMsg\.addTextChangedListener\(new android\.text\.TextWatcher\(\).*?heldMsg\[0\] == null \|\| holding\[0\]\) return;.*?if \(e\.toString\(\)\.contains\(heldMsg\[0\]\)\) return;\s*holding\[0\] = true;\s*StatusLine\.error\(swMsg, heldMsg\[0\]\)' || return 1
  pin "$ch" "the install-time row does not tell no reply from no preference (roundTripLinesOrNull)" \
    'DaemonSocket\.roundTripLinesOrNull\("GET-OTA-TIME\\n", 8000\);\s*runOnUiThread\(\(\) -> timeRow\.setText\(ls == null\s*\? "Install time couldn.t be read right now  ·  tap to set"\s*: ls\.isEmpty\(\)\s*\? "Install time:  Any time' || return 1
  pin "$ch" "the time dialog does not read SET-OTA-TIME's reply (set)" \
    'ReplyCopy\.settingSaved\(daemonCmd\("SET-OTA-TIME\\n" \+ hhmm\)\);\s*if \(saved\) OtaTimeReceiver\.arm\(getApplicationContext\(\), hhmm\);\s*runOnUiThread\(\(\) -> \{\s*if \(!saved\) android\.widget\.Toast\.makeText\(this,\s*"Couldn.t save that change — try again\."[^\n]*\n\s*onChanged\.run\(\);' || return 1
  pin "$ch" "the time dialog does not read SET-OTA-TIME's reply (any time)" \
    'ReplyCopy\.settingSaved\(daemonCmd\("SET-OTA-TIME\\n"\)\);\s*if \(saved\) OtaTimeReceiver\.cancel\(getApplicationContext\(\)\);\s*runOnUiThread\(\(\) -> \{\s*if \(!saved\) android\.widget\.Toast\.makeText\(this,\s*"Couldn.t save that change — try again\."[^\n]*\n\s*onChanged\.run\(\);' || return 1
  pin "$ch" "the caller's-number switch does not read GET-NOTICE-NUMBER through flagOf and stay disabled on null" \
    'final Boolean on = ReplyCopy\.flagOf\(daemonCmd\("GET-NOTICE-NUMBER"\)\);\s*runOnUiThread\(\(\) -> \{\s*if \(on == null\) \{[^\n]*\n\s*numSw\.setEnabled\(false\);\s*numMsg\.setVisibility\(View\.VISIBLE\);' || return 1
  pin "$ch" "a failed SET-NOTICE-NUMBER does not revert with the listener detached, then say so" \
    'ReplyCopy\.settingSaved\(daemonCmd\("SET-NOTICE-NUMBER\\n" \+ \(c \? "1" : "0"\)\)\);\s*runOnUiThread\(\(\) -> \{\s*numSw\.setEnabled\(true\);\s*if \(saved\) \{[^\n]*\n\s*numSw\.setOnCheckedChangeListener\(null\);[^\n]*\n\s*numSw\.setChecked\(!c\);\s*numSw\.setOnCheckedChangeListener\(self\);\s*numMsg\.setVisibility\(View\.VISIBLE\);\s*StatusLine\.error\(numMsg, "Couldn.t save that change — try again\."\);' || return 1
  # NWP-20261026-13: Back up now's BUSY arm reads the reason through ReplyCopy.backupBusy, and the old sentence is gone.
  pin "$pa" "doBackup's BUSY arm does not decide through ReplyCopy.backupBusy" \
    'r\.startsWith\("BUSY"\) \? ReplyCopy\.backupBusy\(r\)\n\s*: r\.startsWith\("NONE"\)' || return 1
  if grep -q 'your changes are being captured right now' "$pa"; then
    echo "  PIN   ProfileActivity still says a save is capturing changes" >&2; return 1
  fi
  # NWP-20261026-18: the "Your data" apps line is decided by ReplyCopy.storedAppsLine, and an unreadable keep-set is
  # null (unknown), never the empty set that means "keeps no apps". NWP-20261113-11: it is told whether the last
  # verdict's parts (SEAL-DELTA "parts") name apps=.
  pin "$pa" "loadSealDelta does not take the apps line from ReplyCopy.storedAppsLine with SEAL-DELTA's parts" \
    'final boolean leftApps = o\.optString\("parts", ""\)\.contains\("apps="\);[^\n]*\n\s*final ReplyCopy\.AppsLine al = ReplyCopy\.storedAppsLine\(kept != null, kept == null \? 0 : kept\.size\(\), measured, unsaved, leftApps\);\s*a = al\.text;\s*aWarn = al\.warn;' || return 1
  pin "$pa" "keptSetForDelta's catch does not return null (an unreadable keep-set would read as keeps-none)" \
    'private java\.util\.Set<String> keptSetForDelta\(\) \{.*?\} catch \(Throwable t\) \{\s*Log\.w\("NowhereChooser", "keptSetForDelta", t\);\s*return null;\s*\}' || return 1
  case "$(cat "$pa")" in *'"Apps in your store: unknown right now."'*)
    echo "  PIN   ProfileActivity still spells the apps line itself" >&2; return 1 ;; esac
  bash "$RUN" "$rc"
}

echo "== $RC"
suite "$RC" "$CH" "$PA" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not apply or compile proves nothing)"
# mut <label> <which: rc|ch|pa> <perl-expr>
mut() {
  local d rcf chf paf src rc; d=$(mktemp -d -p "$W")
  rcf="$RC"; chf="$CH"; paf="$PA"
  case "$2" in rc) src="$RC"; rcf="$d/ReplyCopy.java" ;; ch) src="$CH"; chf="$d/ChooserActivity.java" ;; pa) src="$PA"; paf="$d/ProfileActivity.java" ;; esac
  local m="$d/$(basename "$src")"
  if ! perl -0pe "$3" "$src" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$src" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  [ "$2" = rc ] && rcf="$m"; [ "$2" = ch ] && chf="$m"; [ "$2" = pa ] && paf="$m"
  suite "$rcf" "$chf" "$paf" >"$d/out" 2>&1; rc=$?
  # Only a failing CASE ("--- FAIL") or a failing PIN convicts; a compile error (rc 3) is a broken mutant.
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "M1 UNKNOWN folded into WEAK"              rc 's/return new Strength\(State\.UNKNOWN, "couldn\x27t check[^\n]*\n/return new Strength(State.WEAK, "too weak");\n/' || fails=$((fails+1))
mut "M2 backupRow falls back to 120"           rc 's/if \(sec <= 0\) return "Backup[^\n]*\n/if (sec <= 0) sec = 120;\n/' || fails=$((fails+1))
mut "M3 prettyInterval minute branch broken"   rc 's/return m == 1 \? "every minute"/return m == 2 ? "every minute"/' || fails=$((fails+1))
mut "M4 the ceremony check bypasses the helper" pa 's/final ReplyCopy\.Strength st = ReplyCopy\.strength\(r\);/final ReplyCopy.Strength st = new ReplyCopy.Strength(r.startsWith("OK") ? ReplyCopy.State.STRONG : ReplyCopy.State.WEAK, "too weak");/' || fails=$((fails+1))
mut "M5 the picker ignores the reply"          ch 's/final boolean saved = ReplyCopy\.cadenceSaved\(daemonCmd\(("SET-SYNC-INTERVAL\\n" \+ secs\[w\])\)\);/daemonCmd($1); final boolean saved = true;/' || fails=$((fails+1))
mut "M6 the gate check bypasses the helper"    ch 's/final ReplyCopy\.Strength st = ReplyCopy\.strength\(r\);\n(\s*)showStrength/final ReplyCopy.Strength st = new ReplyCopy.Strength(r.startsWith("OK") ? ReplyCopy.State.STRONG : ReplyCopy.State.WEAK, "too weak");\n$1showStrength/' || fails=$((fails+1))
mut "M7 the backup row keeps a 120 default"    ch 's/final String line = ReplyCopy\.backupRow\(daemonCmd\("GET-SYNC-INTERVAL"\)\);/int sec = 120; final String line = "Your data is backed up " + ReplyCopy.prettyInterval(sec);/' || fails=$((fails+1))
mut "M8 cadenceSaved accepts anything"         rc 's/return reply != null && reply\.split\("\\n", 2\)\[0\]\.trim\(\)\.equals\("OK"\);/return true;/' || fails=$((fails+1))
mut "M9 a bare WEAK reads as strong"           rc 's/if \(first\.equals\("WEAK"\)\) return new Strength\(State\.WEAK/if (first.equals("WEAK")) return new Strength(State.STRONG/' || fails=$((fails+1))
mut "M10 settingSaved accepts the empty reply"  rc 's/(static boolean settingSaved\(String reply\) \{\n\s*return reply != null) && (reply\.split\("\\n", 2\)\[0\]\.trim\(\)\.equals\("OK"\));/$1 && (reply.isEmpty() || $2);/' || fails=$((fails+1))
mut "M11 flagOf maps the empty reply to FALSE"  rc 's/if \(v\.equals\("0"\)\) return Boolean\.FALSE;/if (v.equals("0") || v.isEmpty()) return Boolean.FALSE;/' || fails=$((fails+1))
mut "M12 flagOf maps 2 to TRUE"                 rc 's/if \(v\.equals\("1"\)\) return Boolean\.TRUE;/if (v.equals("1") || v.equals("2")) return Boolean.TRUE;/' || fails=$((fails+1))
mut "M13 the auto switch reads OFF for no answer"      ch 's/final Boolean on = ReplyCopy\.flagOf\(daemonCmd\("GET-OTA-AUTO"\)\);/final Boolean on = "1".equals(daemonCmd("GET-OTA-AUTO"));/' || fails=$((fails+1))
mut "M14 the auto switch ignores the SET reply"        ch 's/final boolean saved = ReplyCopy\.settingSaved\(daemonCmd\(("SET-OTA-AUTO\\n" \+ \(c \? "1" : "0"\))\)\);/daemonCmd($1); final boolean saved = true;/' || fails=$((fails+1))
mut "M15 the auto revert re-fires the listener"        ch 's/(if \(saved\) return;\s*)autoSw\.setOnCheckedChangeListener\(null\);[^\n]*\n/$1/' || fails=$((fails+1))
mut "M16 the auto switch stays enabled on no answer"   ch 's/(if \(on == null\) \{[^\n]*\n\s*)autoSw\.setEnabled\(false\);/$1/' || fails=$((fails+1))
mut "M17 the auto verdict goes to its own line"        ch 's/settingVerdict\.accept\("Couldn.t save that change — try again\."\);(\s*\}\);\s*\}\)\.start\(\);\s*\}\s*\}\);\s*\}\);\s*\}\)\.start\(\);\s*\n\s*\/\/ #21)/new TextView(this).setText("Couldn\x27t save that change — try again.");$1/' || fails=$((fails+1))
mut "M18 the status poll may erase the verdict"        ch 's/if \(e\.toString\(\)\.contains\(heldMsg\[0\]\)\) return;/return;/' || fails=$((fails+1))
mut "M19 the time row reads no answer as Any time"     ch 's/DaemonSocket\.roundTripLinesOrNull\("GET-OTA-TIME\\n", 8000\)/DaemonSocket.roundTripLines("GET-OTA-TIME\\n", 8000)/' || fails=$((fails+1))
mut "M20 the time dialog ignores the clear's reply"    ch 's/final boolean saved = ReplyCopy\.settingSaved\(daemonCmd\("SET-OTA-TIME\\n"\)\);/daemonCmd("SET-OTA-TIME\\n"); final boolean saved = true;/' || fails=$((fails+1))
mut "M21 the time dialog ignores the set reply"        ch 's/final boolean saved = ReplyCopy\.settingSaved\(daemonCmd\("SET-OTA-TIME\\n" \+ hhmm\)\);/daemonCmd("SET-OTA-TIME\\n" + hhmm); final boolean saved = true;/' || fails=$((fails+1))
mut "M22 the caller's-number switch reads OFF for none" ch 's/final Boolean on = ReplyCopy\.flagOf\(daemonCmd\("GET-NOTICE-NUMBER"\)\);/final Boolean on = "1".equals(daemonCmd("GET-NOTICE-NUMBER"));/' || fails=$((fails+1))
mut "M23 the caller's-number switch ignores the reply" ch 's/final boolean saved = ReplyCopy\.settingSaved\(daemonCmd\(("SET-NOTICE-NUMBER\\n" \+ \(c \? "1" : "0"\))\)\);/daemonCmd($1); final boolean saved = true;/' || fails=$((fails+1))
mut "M24 the caller's-number revert re-fires"          ch 's/(numSw\.setEnabled\(true\);\s*if \(saved\) \{[^\n]*\n\s*)numSw\.setOnCheckedChangeListener\(null\);[^\n]*\n/$1/' || fails=$((fails+1))
mut "M25 the caller's-number switch stays enabled"     ch 's/(if \(on == null\) \{[^\n]*\n\s*)numSw\.setEnabled\(false\);/$1/' || fails=$((fails+1))
mut "B1 login maps to the save-running text"     rc 's/if \(why\.equals\("login"\)\)\n(\s*)return "Your sign-in[^\n]*\n/if (why.equals("login"))\n$1return "A save is already running, and this tap joined it.";\n/' || fails=$((fails+1))
mut "B2 an unknown token maps to the save-running text" rc 's/return "The phone is busy, so the save wasn.t started\. Try again in a moment\.";/return "A save is already running, and this tap joined it.";/' || fails=$((fails+1))
mut "B3 seal-run:* falls to the generic text"    rc 's/ \|\| why\.startsWith\("seal-run:"\)//' || fails=$((fails+1))
mut "B4 doBackup keeps its literal"              pa 's/r\.startsWith\("BUSY"\) \? ReplyCopy\.backupBusy\(r\)/r.startsWith("BUSY") ? "A save is already running — your changes are being captured right now."/' || fails=$((fails+1))
mut "S1 keeps-none checked only when measured"        rc 's/if \(keptKnown && keptCount == 0\) return/if (keptKnown \&\& keptCount == 0 \&\& measured) return/' || fails=$((fails+1))
mut "S2 an unreadable keep-set reads as keeps-none"   rc 's/if \(keptKnown && keptCount == 0\) return/if (keptCount == 0) return/' || fails=$((fails+1))
mut "S3 all-saved carries the warning"                rc 's/new AppsLine\("All your kept apps are saved\.", false\)/new AppsLine("All your kept apps are saved.", true)/' || fails=$((fails+1))
mut "S4 keptSetForDelta's catch returns an empty set" pa 's/(Log\.w\("NowhereChooser", "keptSetForDelta", t\);\s*)return null;/${1}return out;/' || fails=$((fails+1))
# NWP-20261113-11 (case 1): the apps line after a save that left #apps behind.
mut "S5 storedAppsLine ignores lastSaveLeftApps"      rc 's/return lastSaveLeftApps\n/return false\n/' || fails=$((fails+1))
mut "S6 the Your data call passes false always"       pa 's/measured, unsaved, leftApps\);/measured, unsaved, false);/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
