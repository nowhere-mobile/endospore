#!/usr/bin/env bash
# test-store-gate-java.sh [--mutate] -- the gate's Store settings sit behind the owner passphrase (NWP-20261031-04).
#
# WHY THIS IS COMMITTED. Settings > Store settings repoints where every profile's data goes and takes S3 credentials,
# and it used to open with no sign-in (docs/product-decisions.md, 2026-10-20). StoreGate (pure, java.lang only) holds
# the two rules and is compiled here with its cases; SOURCE checks over ChooserActivity pin that the Settings row and
# first run's self-host branch reach the screen only through openStoreSettings, that the verify screen reads nothing
# about the store before success, and that the Store screen does not keep the passphrase.
#
# NWP-20261124-11 (decision #13, 2026-11-02): the Settings screen's device-wide controls -- the Backup row
# (SET-SYNC-INTERVAL via showSyncIntervalPicker; moved to Owner settings by NWP-20261130-14, below), the
# automatic-install switch (SET-OTA-AUTO) and the install-time row (SET-OTA-TIME via showOtaTimePicker) -- sit behind
# the same verify. The cases pin devicePickersOpen and that
# DEST_DEVICE does not keep the passphrase; the source checks (s7-s11) pin that each sender still on Settings is reached only
# through deviceControlsOpen(), that a closed control opens buildOwnerVerifyScreen(DEST_DEVICE), that its success sets
# deviceSettingsVerified after it reopens Settings and its Cancel returns to Settings, and that the setContentView
# override and onPause clear the field. s12 pins the visit token (NWP-20261129-09: for every destination, not only
# DEST_DEVICE): the verify records deviceVisit at submit, before its thread starts; the answer's first statement is the
# guard StoreGate.deviceVerifyLands(visit, deviceVisit) for a success and for -7; and endDeviceVisit() (the
# setContentView override, so Cancel too, and onPause) raises it. So a correct passphrase answered after a Cancel or a
# screen-off opens nothing and holds no passphrase (s4: ownerSessionPass is assigned after the guard), and the guard
# empties the field, because the verify screen survives a screen-off.
#
# NWP-20261126-03 (decision 2026-11-03, "... Store settings moves to Owner settings"): the Store settings row leaves
# Gate settings (s2) and is an Owner settings row (s13). That menu opens only through DEST_MENU's verify, so the row
# opens buildStoreScreen() with no second verify; its storeBackTo and storeOnSaved reopen buildOwnerMenu(), so Back
# and a save return to Owner settings, never to the gate. s14: with no route from Gate settings, the Store Cancel and
# the DEST_STORE Cancel fall back to gateView, not buildSettingsScreen(). First run's store step is unchanged: it
# still opens the screen through openStoreSettings and DEST_STORE (s1, s3).
#
# NWP-20261130-14 (decision 2026-11-06, "... Backup moves from Gate settings into Owner settings"): Gate settings has no
# Backup entry and no shortcut (s15). Owner settings has one Backup row, and it is the one way to buildOwnerBackupScreen
# (s16). That menu opens only through DEST_MENU's verify, so neither the row nor the screen asks again (s6, s17), and
# Back returns to Owner settings (s18). DEST_DEVICE now guards automatic install and install time only, and its line
# says so (s19). An AlertDialog outlives the screen under it, so the picker is one at a time and onPause closes it: a
# wake shows the gate with no picker over it (s20). The B mutants each name the check that must convict them.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-store-gate-java.sh            # the cases and the source checks
#   bash test-store-gate-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SUT="$SRC/StoreGate.java"
CHOOSER="$SRC/ChooserActivity.java"
CASES="$root/core/chooser/tests/store-gate/StoreGateCases.java"
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

# suite <StoreGate.java> -> 0 pass, 1 a case failed or the class is missing, 3 did not compile.
suite() {
  local src="$1" d out rc
  [ -f "$src" ] || { echo "  FAIL  StoreGate.java does not exist (the gate is not lifted)" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$src" "$d/src/com/nowhere/chooser/StoreGate.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/StoreGateCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.StoreGateCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# count <text> <regex> -> the number of matching lines, comment lines skipped.
count() { printf '%s\n' "$1" | RE="$2" awk '$0 !~ /^[ \t]*(\/\/|\*|\/\*)/ && $0 ~ ENVIRON["RE"] { n++ } END { print n + 0 }'; }

# source <ChooserActivity.java> -> 0 when every source check holds.
source_checks() {
  local f="$1" bad=0 all open first verify n settings sw scv pause l_guard l_set owner orow store vcancel answer want ans1 l_ans l_pass obackup obrow picker
  all=$(cat "$f")
  settings=$(awk '/private View buildSettingsScreen\(\)/ { on = 1 } on { print } on && /^    }$/ { exit }' "$f")
  sw=$(printf '%s\n' "$settings" | awk '/public void onCheckedChanged\(android\.widget\.CompoundButton b, boolean c\)/ { on = 1 } on { print } on && /SET-OTA-AUTO/ { exit }')
  scv=$(awk '/public void setContentView\(android\.view\.View view\)/ { on = 1 } on { print } on && /^    }$/ { exit }' "$f")
  pause=$(awk '/protected void onPause\(\)/ { on = 1 } on { print } on && /^    }$/ { exit }' "$f")
  open=$(awk '/private void openStoreSettings\(\)/ { on = 1 } on { print } on && /^    }$/ { exit }' "$f")
  owner=$(awk '/private View buildOwnerMenu\(\)/ { on = 1 } on { print } on && /^    }$/ { exit }' "$f")
  orow=$(printf '%s\n' "$owner" | awk '/settingsRow\("Store settings"/ { on = 1 } on { print } on && /WRAP\)\);/ { exit }')
  obrow=$(printf '%s\n' "$owner" | awk '/settingsRow\("Backup"/ { on = 1 } on { print } on && /WRAP\)\);/ { exit }')
  obackup=$(awk '/private View buildOwnerBackupScreen\(\)/ { on = 1 } on { print } on && /^    }$/ { exit }' "$f")
  picker=$(awk '/private void showSyncIntervalPicker\(Runnable onChanged\)/ { on = 1 } on { print } on && /^    }$/ { exit }' "$f")
  store=$(awk '/private View buildStoreScreen\(\)/ { on = 1 } on { print } on && /^    }$/ { exit }' "$f")
  first=$(awk '/if \(selfHost\[0\]\) \{/ { on = 1 } on { print } on && /\} else \{/ { exit }' "$f")
  verify=$(awk '/private View buildOwnerVerifyScreen\(final int dest\)/ { on = 1 } on { print } on && /^    }$/ { exit }' "$f")
  vcancel=$(printf '%s\n' "$verify" | awk '/cancel\.setOnClickListener\(v -> \{$/ { on = 1 } on { print } on && /^        \}\);$/ { exit }')
  answer=$(printf '%s\n' "$verify" | awk '/^                runOnUiThread\(\(\) -> \{$/ { on = 1; next } on && /^                \}\);$/ { exit } on { print }')
  [ -n "$open" ]   || { echo "  FAIL  openStoreSettings not found" >&2; bad=1; }
  [ -n "$owner" ]  || { echo "  FAIL  buildOwnerMenu() not found" >&2; bad=1; }
  [ -n "$store" ]  || { echo "  FAIL  buildStoreScreen() not found" >&2; bad=1; }
  [ -n "$picker" ] || { echo "  FAIL  showSyncIntervalPicker(Runnable) not found" >&2; bad=1; }
  [ -n "$vcancel" ] || { echo "  FAIL  the verify screen's Cancel listener not found" >&2; bad=1; }
  [ -n "$first" ]  || { echo "  FAIL  first run's self-host branch not found" >&2; bad=1; }
  [ -n "$verify" ] || { echo "  FAIL  buildOwnerVerifyScreen(int dest) not found" >&2; bad=1; }
  [ -n "$answer" ] || { echo "  FAIL  the verify's runOnUiThread answer not found" >&2; bad=1; }
  [ -n "$settings" ] || { echo "  FAIL  buildSettingsScreen() not found" >&2; bad=1; }
  [ -n "$sw" ]     || { echo "  FAIL  the automatic-install switch's onCheckedChanged not found in buildSettingsScreen" >&2; bad=1; }
  [ -n "$scv" ]    || { echo "  FAIL  the setContentView(View) override not found" >&2; bad=1; }
  [ -n "$pause" ]  || { echo "  FAIL  onPause not found" >&2; bad=1; }
  [ "$bad" -eq 0 ] || return 1

  n=$(count "$all" 'buildStoreScreen\(\)')
  n=$((n - $(count "$all" 'View buildStoreScreen\(\)')))
  [ "$n" -eq 3 ] || { echo "  FAIL  s1: buildStoreScreen() is called $n times outside its declaration, want 3" >&2; bad=1; }
  [ "$(count "$open" 'buildStoreScreen\(\)')" -eq 1 ] \
    || { echo "  FAIL  s1: openStoreSettings does not call buildStoreScreen() exactly once" >&2; bad=1; }
  [ "$(count "$verify" 'DEST_STORE\) setContentView\(buildStoreScreen\(\)\)')" -eq 1 ] \
    || { echo "  FAIL  s1: the verify screen's DEST_STORE arm does not open buildStoreScreen()" >&2; bad=1; }
  [ "$(count "$open" 'needsOwnerVerify\(ownerSecretSet\(\)\).*buildOwnerVerifyScreen\(StoreGate\.DEST_STORE\)')" -eq 1 ] \
    || { echo "  FAIL  s1: openStoreSettings does not verify first when a passphrase exists" >&2; bad=1; }
  # NWP-20261126-03: Gate settings has no Store settings row (s2); Owner settings has one (s13).
  [ "$(count "$settings" '"Store settings"')" -eq 0 ] || { echo "  FAIL  s2: buildSettingsScreen still holds \"Store settings\"" >&2; bad=1; }
  [ "$(count "$settings" 'openStoreSettings')" -eq 0 ] || { echo "  FAIL  s2: buildSettingsScreen still calls openStoreSettings" >&2; bad=1; }
  [ "$(count "$settings" 'buildStoreScreen')" -eq 0 ] || { echo "  FAIL  s2: buildSettingsScreen calls buildStoreScreen" >&2; bad=1; }
  [ "$(count "$owner" 'settingsRow\("Store settings"')" -eq 1 ] \
    || { echo "  FAIL  s13: buildOwnerMenu does not hold exactly one Store settings row" >&2; bad=1; }
  n=$(printf '%s\n' "$orow" | tr '\n' ' ' | grep -cE 'storeBackTo = \(\) -> setContentView\(buildOwnerMenu\(\)\); storeOnSaved = storeBackTo; setContentView\(buildStoreScreen\(\)\);')
  [ "$n" -eq 1 ] \
    || { echo "  FAIL  s13: the owner row does not set storeBackTo to reopen buildOwnerMenu(), then storeOnSaved, then open buildStoreScreen()" >&2; bad=1; }
  [ "$(count "$orow" 'openStoreSettings|buildOwnerVerifyScreen|buildSettingsScreen')" -eq 0 ] \
    || { echo "  FAIL  s13: the owner row opens a second verify or returns to Gate settings" >&2; bad=1; }
  [ "$(count "$store" '^ *cancel\.setOnClickListener\(v -> \{ if \(storeBackTo != null\) storeBackTo\.run\(\); else setContentView\(gateView\); \}\);')" -eq 1 ] \
    || { echo "  FAIL  s14: the Store screen's Cancel does not fall back to gateView" >&2; bad=1; }
  [ "$(count "$store" 'buildSettingsScreen')" -eq 0 ] || { echo "  FAIL  s14: buildStoreScreen names buildSettingsScreen" >&2; bad=1; }
  [ "$(printf '%s\n' "$vcancel" | grep -A1 -E '^ *else if \(storeBackTo != null\) storeBackTo\.run\(\);' | sed -n 2p | sed -E 's#^ +##; s# +//.*$##')" \
      = 'else setContentView(gateView);' ] \
    || { echo "  FAIL  s14: the DEST_STORE Cancel does not fall back to gateView" >&2; bad=1; }
  [ "$(count "$vcancel" 'buildSettingsScreen')" -eq 1 ] \
    || { echo "  FAIL  s14: the verify Cancel names buildSettingsScreen outside the DEST_DEVICE line" >&2; bad=1; }
  [ "$(count "$first" 'openStoreSettings\(\)')" -eq 1 ] || { echo "  FAIL  s3: the self-host branch does not call openStoreSettings()" >&2; bad=1; }
  [ "$(count "$first" 'buildStoreScreen')" -eq 0 ] || { echo "  FAIL  s3: the self-host branch calls buildStoreScreen" >&2; bad=1; }
  [ "$(count "$verify" 'ownerSessionPass = ')" -eq 1 ] || { echo "  FAIL  s4: ownerSessionPass is not assigned exactly once in the verify screen" >&2; bad=1; }
  [ "$(count "$verify" 'if \(StoreGate\.keepsOwnerPass\(dest\)\) ownerSessionPass = ')" -eq 1 ] \
    || { echo "  FAIL  s4: ownerSessionPass is assigned outside keepsOwnerPass" >&2; bad=1; }
  want='if ((r == 0 || r == -7) && !StoreGate.deviceVerifyLands(visit, deviceVisit)) { pf.setText(""); go.setEnabled(true); msg.setText(""); return; }'
  l_ans=$(printf '%s\n' "$answer" | grep -nF "$want" | head -1 | cut -d: -f1)
  l_pass=$(printf '%s\n' "$answer" | grep -nF 'ownerSessionPass = ' | head -1 | cut -d: -f1)
  [ -n "$l_ans" ] && [ -n "$l_pass" ] && [ "$l_pass" -gt "$l_ans" ] \
    || { echo "  FAIL  s4: ownerSessionPass is not assigned after the answer's guard" >&2; bad=1; }
  [ "$(count "$verify" 'GET-STORE|PING-STORE|[Gg]etStore|[Pp]ingStore|GET-SYNC-INTERVAL|SET-SYNC-INTERVAL|GET-OTA-|SET-OTA-|showSyncIntervalPicker|showOtaTimePicker')" -eq 0 ] \
    || { echo "  FAIL  s5: the verify screen touches the store or a device-wide setting before success" >&2; bad=1; }

  # NWP-20261124-11 (#13): the device-wide controls. NWP-20261130-14: Backup's guard is now Owner settings' own verify.
  [ "$(count "$obackup" '^        bkRow\.setOnClickListener\(v -> showSyncIntervalPicker\(refreshBkRow\)\);$')" -eq 1 ] \
    || { echo "  FAIL  s6: the Owner settings Backup screen's line does not open showSyncIntervalPicker directly" >&2; bad=1; }
  n=$(( $(count "$all" 'showSyncIntervalPicker\(') - $(count "$all" 'private void showSyncIntervalPicker\(') ))
  [ "$n" -eq 1 ] || { echo "  FAIL  s6: showSyncIntervalPicker( is called $n times, want 1 (the Owner settings Backup screen)" >&2; bad=1; }
  [ "$(count "$settings" '^        timeRow\.setOnClickListener\(v -> \{ if \(deviceControlsOpen\(\)\) showOtaTimePicker\(refreshTimeRow\); else openDeviceVerify\(\); \}\);$')" -eq 1 ] \
    || { echo "  FAIL  s7: the install-time row does not open showOtaTimePicker only under deviceControlsOpen()" >&2; bad=1; }
  n=$(( $(count "$all" 'showOtaTimePicker\(') - $(count "$all" 'private void showOtaTimePicker\(') ))
  [ "$n" -eq 1 ] || { echo "  FAIL  s7: showOtaTimePicker( is called $n times, want 1 (the guarded time row)" >&2; bad=1; }
  [ "$(count "$all" 'SET-OTA-AUTO')" -eq 1 ] || { echo "  FAIL  s8: SET-OTA-AUTO is not sent from exactly one line" >&2; bad=1; }
  [ "$(count "$sw" 'SET-OTA-AUTO')" -eq 1 ] || { echo "  FAIL  s8: SET-OTA-AUTO is not sent from the switch's onCheckedChanged" >&2; bad=1; }
  l_guard=$(printf '%s\n' "$sw" | grep -nE '^ *if \(!deviceControlsOpen\(\)\) \{' | head -1 | cut -d: -f1)
  [ -n "$l_guard" ] && [ "$(printf '%s\n' "$sw" | grep -nE '^ *final android\.widget\.CompoundButton\.OnCheckedChangeListener self = this;$' | head -1 | cut -d: -f1)" = "$((l_guard - 1))" ] \
    && [ "$(printf '%s\n' "$sw" | sed -n "$((l_guard + 1)),$((l_guard + 6))p" | sed -E 's#^ +##; s# +//.*$##' | tr '\n' '~')" \
         = 'autoSw.setOnCheckedChangeListener(null);~autoSw.setChecked(!c);~autoSw.setOnCheckedChangeListener(self);~openDeviceVerify();~return;~}~' ] \
    || { echo "  FAIL  s8: the switch's first act is not the guard that undoes the flip, opens the verify and returns before any SET-OTA-AUTO" >&2; bad=1; }
  [ "$(count "$all" '^    private boolean deviceControlsOpen\(\) \{ return StoreGate\.devicePickersOpen\(ownerSecretSet\(\), deviceSettingsVerified\); \}$')" -eq 1 ] \
    || { echo "  FAIL  s9: deviceControlsOpen() does not read StoreGate.devicePickersOpen(ownerSecretSet(), deviceSettingsVerified)" >&2; bad=1; }
  [ "$(count "$all" '^    private void openDeviceVerify\(\) \{ setContentView\(buildOwnerVerifyScreen\(StoreGate\.DEST_DEVICE\)\); \}$')" -eq 1 ] \
    || { echo "  FAIL  s9: openDeviceVerify() does not open buildOwnerVerifyScreen(StoreGate.DEST_DEVICE)" >&2; bad=1; }
  [ "$(count "$answer" '^ *else if \(dest == StoreGate\.DEST_DEVICE\) \{ setContentView\(buildSettingsScreen\(\)\); deviceSettingsVerified = true; \}')" -eq 1 ] \
    || { echo "  FAIL  s10: the verify's DEST_DEVICE success does not reopen Settings, then set deviceSettingsVerified" >&2; bad=1; }
  # NWP-20261129-09: the guard comes first, for every destination; comment lines above it are not statements.
  ans1=$(printf '%s\n' "$answer" | awk '$0 !~ /^[ \t]*(\/\/|\*|\/\*)/ && NF { sub(/^ +/, ""); print; exit }')
  [ "$ans1" = "$want" ] \
    || { echo "  FAIL  s12: the answer's first statement is not the guard for every destination" >&2; bad=1; }
  [ -n "$l_ans" ] && [ "$(count "$(printf '%s\n' "$answer" | head -n "$((l_ans - 1))")" 'setContentView\(')" -eq 0 ] \
    || { echo "  FAIL  s12: the answer opens a screen before its guard" >&2; bad=1; }
  [ "$(count "$answer" '^ *if \(.*deviceVerifyLands\(.*pf\.setText\(""\);.*return; \}$')" -eq 1 ] \
    || { echo "  FAIL  s12: the guard does not empty the passphrase field on a late answer" >&2; bad=1; }
  [ "$(count "$verify" '^            final int visit = deviceVisit;')" -eq 1 ] && [ "$(count "$verify" 'deviceVisit')" -eq 2 ] \
    || { echo "  FAIL  s12: the verify does not record deviceVisit once at submit and compare it once at the answer" >&2; bad=1; }
  [ "$(printf '%s\n' "$verify" | grep -B2 -E '^            final int visit = deviceVisit;' | head -1 | sed -E 's#^ +##')" = 'if (p.isEmpty()) { msg.setTextColor(MUTED); StatusLine.error(msg, "enter your device passphrase"); return; }' ] \
    || { echo "  FAIL  s12: deviceVisit is not recorded at submit, before the verify thread starts" >&2; bad=1; }
  [ "$(printf '%s\n' "$verify" | grep -A1 -E '^            final int visit = deviceVisit;' | sed -n 2p | sed -E 's#^ +##')" = 'new Thread(() -> {' ] \
    || { echo "  FAIL  s12: the verify thread does not start right after deviceVisit is recorded" >&2; bad=1; }
  [ "$(count "$all" '^    private void endDeviceVisit\(\) \{ deviceSettingsVerified = false; deviceVisit\+\+; \}$')" -eq 1 ] \
    || { echo "  FAIL  s12: endDeviceVisit() does not clear deviceSettingsVerified and raise deviceVisit" >&2; bad=1; }
  [ "$(count "$all" 'deviceVisit\+\+|deviceVisit = |deviceVisit--|deviceVisit \+=|deviceVisit -=')" -eq 1 ] \
    || { echo "  FAIL  s12: deviceVisit is changed outside endDeviceVisit()" >&2; bad=1; }
  [ "$(count "$verify" '^ *if \(dest == StoreGate\.DEST_DEVICE\) setContentView\(buildSettingsScreen\(\)\);')" -eq 1 ] \
    || { echo "  FAIL  s10: the verify's DEST_DEVICE Cancel does not return to Settings" >&2; bad=1; }
  [ "$(count "$verify" 'deviceSettingsVerified')" -eq 1 ] \
    || { echo "  FAIL  s10: the verify screen does not name deviceSettingsVerified exactly once (its success arm)" >&2; bad=1; }
  [ "$(count "$all" 'deviceSettingsVerified = true')" -eq 1 ] \
    || { echo "  FAIL  s11: deviceSettingsVerified is not set true exactly once (the verify's success arm)" >&2; bad=1; }
  l_set=$(printf '%s\n' "$scv" | grep -nE '^        endDeviceVisit\(\);' | head -1 | cut -d: -f1)
  [ "$(count "$scv" 'endDeviceVisit\(\);')" -eq 1 ] && [ "${l_set:-0}" = 2 ] \
    || { echo "  FAIL  s11: the setContentView override does not call endDeviceVisit() first" >&2; bad=1; }
  [ "$(count "$pause" '^        endDeviceVisit\(\);')" -eq 1 ] \
    || { echo "  FAIL  s11: onPause does not call endDeviceVisit()" >&2; bad=1; }
  [ "$(count "$all" 'deviceSettingsVerified = false;')" -eq 1 ] \
    || { echo "  FAIL  s11: deviceSettingsVerified is not cleared in exactly one place (endDeviceVisit)" >&2; bad=1; }

  # NWP-20261130-14 (decision 2026-11-06): Backup leaves Gate settings for Owner settings.
  [ "$(count "$settings" '"Backup"|bkRow|showSyncIntervalPicker|SYNC-INTERVAL|buildOwnerBackupScreen')" -eq 0 ] \
    || { echo "  FAIL  s15: buildSettingsScreen still holds a Backup entry or shortcut" >&2; bad=1; }
  [ "$(count "$owner" 'settingsRow\("Backup"')" -eq 1 ] \
    || { echo "  FAIL  s16: buildOwnerMenu does not hold exactly one Backup row" >&2; bad=1; }
  [ "$(count "$obrow" 'setContentView\(buildOwnerBackupScreen\(\)\)')" -eq 1 ] \
    || { echo "  FAIL  s16: the owner row does not open buildOwnerBackupScreen()" >&2; bad=1; }
  n=$(( $(count "$all" 'buildOwnerBackupScreen\(\)') - $(count "$all" 'private View buildOwnerBackupScreen\(\)') ))
  [ "$n" -eq 1 ] || { echo "  FAIL  s16: buildOwnerBackupScreen() is called $n times, want 1 (the owner row)" >&2; bad=1; }
  [ -n "$obackup" ] && [ "$(count "$all" 'SET-SYNC-INTERVAL')" -eq 1 ] && [ "$(count "$picker" 'SET-SYNC-INTERVAL')" -eq 1 ] \
    || { echo "  FAIL  s16: SET-SYNC-INTERVAL is sent from outside showSyncIntervalPicker" >&2; bad=1; }
  [ -n "$obrow" ] && [ "$(count "$obrow" 'deviceControlsOpen|openDeviceVerify|buildOwnerVerifyScreen|openStoreSettings')" -eq 0 ] \
    || { echo "  FAIL  s17: the owner Backup row asks for a second verify" >&2; bad=1; }
  [ -n "$obackup" ] && [ "$(count "$obackup" 'deviceControlsOpen|openDeviceVerify|buildOwnerVerifyScreen|openStoreSettings')" -eq 0 ] \
    || { echo "  FAIL  s17: the owner Backup screen asks for a second verify" >&2; bad=1; }
  [ "$(count "$obackup" 'ownerBack\("Back", v -> setContentView\(buildOwnerMenu\(\)\)\)')" -eq 1 ] \
    || { echo "  FAIL  s18: the owner Backup screen's Back does not return to buildOwnerMenu()" >&2; bad=1; }
  [ -n "$obackup" ] && [ "$(count "$obackup" 'gateView|buildSettingsScreen')" -eq 0 ] \
    || { echo "  FAIL  s18: the owner Backup screen leads to the gate or to Gate settings" >&2; bad=1; }
  [ "$(count "$verify" 'to change update settings\.')" -eq 1 ] && [ "$(count "$verify" '[Bb]ackup')" -eq 0 ] \
    || { echo "  FAIL  s19: the DEST_DEVICE verify line does not name update settings only" >&2; bad=1; }
  [ "$(count "$picker" '^        if \(syncPicker != null && syncPicker\.isShowing\(\)\) return;')" -eq 1 ] \
    || { echo "  FAIL  s20: showSyncIntervalPicker can open a second picker over the one syncPicker holds" >&2; bad=1; }
  [ "$(count "$picker" 'syncPicker = new android\.app\.AlertDialog\.Builder\(this\)')" -eq 1 ] \
    || { echo "  FAIL  s20: showSyncIntervalPicker does not store its dialog in syncPicker" >&2; bad=1; }
  [ "$(count "$pause" '^        if \(syncPicker != null\) \{ syncPicker\.dismiss\(\); syncPicker = null; \}')" -eq 1 ] \
    || { echo "  FAIL  s20: onPause does not close the picker" >&2; bad=1; }
  [ "$bad" -eq 0 ]
}

echo "== $SUT"
suite "$SUT" || { echo "FAILED"; exit 1; }
source_checks "$CHOOSER" || { echo "FAILED (source)"; exit 1; }
echo "source: ok"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not compile proves nothing)"
mut() { # mut <label> <perl-expr>   (mutates StoreGate.java; the cases must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/StoreGate.java"
  cp "$SUT" "$c"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$SUT" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  suite "$c" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
muts() { # muts <label> <perl-expr>   (mutates ChooserActivity.java; the source checks must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/ChooserActivity.java"
  cp "$CHOOSER" "$c"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$CHOOSER" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  source_checks "$c" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  echo "  convicted $1"
}
mutb() { # mutb <sNN> <label> <perl-expr>   (mutates ChooserActivity.java; the check named sNN must fail)
  local id="$1" label="$2" d c out rc; d=$(mktemp -d -p "$W") || return 1; c="$d/ChooserActivity.java"
  cp "$CHOOSER" "$c"
  if ! perl -0pi -e "$3" "$c"; then echo "  ERROR     $label -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$CHOOSER" "$c"; then echo "  INERT     $label -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  out=$(source_checks "$c" 2>&1); rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $label"; return 1; fi
  case "$out" in
    *"FAIL  $id:"*) echo "  convicted $label (by $id)" ;;
    *) echo "  WRONG     $label -- failed, but not on $id: $out"; return 1 ;;
  esac
}
fails=0
mut "G1 needsOwnerVerify returns false" 's/return ownerSecretSet; \}/return false; }/' || fails=$((fails+1))
muts "G2 the Store settings row is back on Gate settings" 's/(\n *ll\.addView\(settingsRow\("Wi-Fi", "Join a network",)/\n        ll.addView(settingsRow("Store settings", "Where your encrypted data is saved",\n                v -> openStoreSettings()), new LinearLayout.LayoutParams(MATCH, WRAP));$1/' || fails=$((fails+1))
mut "G3 keepsOwnerPass true for DEST_STORE" 's/return dest == DEST_MENU \|\| dest == DEST_INBOX;/return dest != DEST_DEVICE;/' || fails=$((fails+1))
muts "G4 the DEST_STORE arm opens buildOwnerMenu()" 's/if \(dest == StoreGate\.DEST_STORE\) setContentView\(buildStoreScreen\(\)\);/if (dest == StoreGate.DEST_STORE) setContentView(buildOwnerMenu());/' || fails=$((fails+1))
muts "G5 the first-run branch calls buildStoreScreen() directly" 's/(storeOnSaved = this::showFirstRunOwner;[^\n]*\n\s*)openStoreSettings\(\);/$1setContentView(buildStoreScreen());/' || fails=$((fails+1))
muts "D2 the switch sends SET-OTA-AUTO unguarded" 's/\n *if \(!deviceControlsOpen\(\)\) \{[^\n]*\n(?:[^\n]*\n){4} *return;\n *\}//' || fails=$((fails+1))
muts "D3 the time row opens the picker unguarded" 's/timeRow\.setOnClickListener\(v -> \{ if \(deviceControlsOpen\(\)\) showOtaTimePicker\(refreshTimeRow\); else openDeviceVerify\(\); \}\);/timeRow.setOnClickListener(v -> showOtaTimePicker(refreshTimeRow));/' || fails=$((fails+1))
mut "D4 devicePickersOpen true without a verify" 's/return !ownerSecretSet \|\| verifiedThisVisit;/return true;/' || fails=$((fails+1))
muts "D4b deviceControlsOpen ignores StoreGate" 's/\{ return StoreGate\.devicePickersOpen\(ownerSecretSet\(\), deviceSettingsVerified\); \}/{ return true; }/' || fails=$((fails+1))
muts "D5 the verify kept across screens (no clear in setContentView)" 's/(public void setContentView\(android\.view\.View view\) \{\n) *endDeviceVisit\(\);[^\n]*\n/$1/' || fails=$((fails+1))
muts "D6 the verify kept across a screen-off (no clear in onPause)" 's/\n        endDeviceVisit\(\); \/\/ NWP-20261124-11: a screen-off[^\n]*//' || fails=$((fails+1))
mut "D7 keepsOwnerPass true for DEST_DEVICE" 's/return dest == DEST_MENU \|\| dest == DEST_INBOX;/return dest != DEST_STORE;/' || fails=$((fails+1))
muts "D8 the success sets the field before setContentView" 's/\{ setContentView\(buildSettingsScreen\(\)\); deviceSettingsVerified = true; \}/{ deviceSettingsVerified = true; setContentView(buildSettingsScreen()); }/' || fails=$((fails+1))
muts "D9 the DEST_DEVICE Cancel goes to the gate" 's/if \(dest == StoreGate\.DEST_DEVICE\) setContentView\(buildSettingsScreen\(\)\);/if (dest == StoreGate.DEST_DEVICE) setContentView(gateView);/' || fails=$((fails+1))
muts "D10 the verify screen reads GET-OTA-AUTO before success" 's/(private View buildOwnerVerifyScreen\(final int dest\) \{\n)/$1        daemonCmd("GET-OTA-AUTO");\n/' || fails=$((fails+1))
muts "D11 the DEST_DEVICE success sets the field but opens the owner menu" 's/\{ setContentView\(buildSettingsScreen\(\)\); deviceSettingsVerified = true; \}/{ setContentView(buildOwnerMenu()); deviceSettingsVerified = true; }/' || fails=$((fails+1))
muts "D12 the switch guard does not undo the flip" 's/(if \(!deviceControlsOpen\(\)\) \{[^\n]*\n(?:[^\n]*\n)) *autoSw\.setChecked\(!c\);\n/$1/' || fails=$((fails+1))
mut "V1 deviceVerifyLands true for a late answer" 's/return visitAtSubmit == visitNow;/return true;/' || fails=$((fails+1))
muts "V2 a late answer lands for every destination (no guard)" 's/\(r == 0 \|\| r == -7\) && !StoreGate\.deviceVerifyLands\(visit, deviceVisit\)\) \{ pf/false) { pf/' || fails=$((fails+1))
muts "V3 endDeviceVisit does not raise deviceVisit (Cancel and screen-off revoke nothing in flight)" 's/\{ deviceSettingsVerified = false; deviceVisit\+\+; \}/{ deviceSettingsVerified = false; }/' || fails=$((fails+1))
muts "V4 the answer compares the visit with itself" 's/!StoreGate\.deviceVerifyLands\(visit, deviceVisit\)\) \{ pf/!StoreGate.deviceVerifyLands(visit, visit)) { pf/' || fails=$((fails+1))
muts "V5 the visit is read at the answer, not at submit" 's/\n            final int visit = deviceVisit;[^\n]*//; s/!StoreGate\.deviceVerifyLands\(visit, deviceVisit\)\) \{ pf/!StoreGate.deviceVerifyLands(deviceVisit, deviceVisit)) { pf/' || fails=$((fails+1))
muts "V6 Cancel clears the field without ending the visit" 's/(public void setContentView\(android\.view\.View view\) \{\n) *endDeviceVisit\(\);([^\n]*)\n/$1        deviceSettingsVerified = false;$2\n/' || fails=$((fails+1))
muts "V7 the guard back inside the DEST_DEVICE arm only (a late DEST_MENU answer lands)" 's/\n *if \(\(r == 0 \|\| r == -7\) && !StoreGate\.deviceVerifyLands\(visit, deviceVisit\)\) \{ pf[^\n]*//; s/else if \(dest == StoreGate\.DEST_DEVICE\) \{ setContentView\(buildSettingsScreen\(\)\); deviceSettingsVerified = true; \}/else if (dest == StoreGate.DEST_DEVICE) { if (StoreGate.deviceVerifyLands(visit, deviceVisit)) { setContentView(buildSettingsScreen()); deviceSettingsVerified = true; } }/' || fails=$((fails+1))
muts "V8 ownerSessionPass set above the guard (a late answer holds the passphrase)" 's/\n *if \(StoreGate\.keepsOwnerPass\(dest\)\) ownerSessionPass = p;[^\n]*//; s/(\n *)(if \(\(r == 0 \|\| r == -7\) && !StoreGate)/$1if (r == 0 \&\& StoreGate.keepsOwnerPass(dest)) ownerSessionPass = p;$1$2/' || fails=$((fails+1))
muts "V9 a late answer leaves the passphrase in the field" 's/\{ pf\.setText\(""\); go\.setEnabled\(true\); msg\.setText\(""\); return; \}/{ go.setEnabled(true); msg.setText(""); return; }/' || fails=$((fails+1))
muts "V10 the guard limited to r == 0 (a late -7 lands over the gate)" 's/\(r == 0 \|\| r == -7\) && !StoreGate/r == 0 \&\& !StoreGate/' || fails=$((fails+1))
muts "O1 the owner row removed" 's/\n *ll\.addView\(settingsRow\("Store settings", "Where your encrypted data is saved", v -> \{\n[^\n]*\n *\}\), new LinearLayout\.LayoutParams\(MATCH, WRAP\)\);//' || fails=$((fails+1))
muts "O2 the owner row opens openStoreSettings() (a second verify)" 's/(storeOnSaved = storeBackTo; )setContentView\(buildStoreScreen\(\)\);/${1}openStoreSettings();/' || fails=$((fails+1))
muts "O3 the owner row's storeBackTo opens buildSettingsScreen()" 's/storeBackTo = \(\) -> setContentView\(buildOwnerMenu\(\)\);/storeBackTo = () -> setContentView(buildSettingsScreen());/' || fails=$((fails+1))
muts "O4 the Store Cancel fallback is buildSettingsScreen()" 's/(cancel\.setOnClickListener\(v -> \{ if \(storeBackTo != null\) storeBackTo\.run\(\); else setContentView\()gateView\)/${1}buildSettingsScreen())/' || fails=$((fails+1))
muts "O5 the DEST_STORE Cancel fallback is buildSettingsScreen()" 's/(else if \(storeBackTo != null\) storeBackTo\.run\(\);\n *else setContentView\()gateView\);/${1}buildSettingsScreen());/' || fails=$((fails+1))
BR='ll.addView(settingsRow("Backup", "How often your data is saved", v -> setContentView(buildOwnerBackupScreen())), new LinearLayout.LayoutParams(MATCH, WRAP));'
export BR
mutb s15 "B1 the Backup header is back on Gate settings" 's/(\n *ll\.addView\(settingsRow\("Wi-Fi", "Join a network",)/\n        TextView bkHdr = new TextView(this);\n        bkHdr.setText("Backup");$1/' || fails=$((fails+1))
mutb s15 "B2 a Backup shortcut on Gate settings, with its row still in Owner settings" 's/(\n *ll\.addView\(settingsRow\("Wi-Fi", "Join a network",)/\n        $ENV{BR}$1/' || fails=$((fails+1))
mutb s16 "B2b the same shortcut under another label, seen by the one-caller count" 's/(\n *ll\.addView\(settingsRow\("Wi-Fi", "Join a network",)/\n        ll.addView(settingsRow("Saving", "", v -> setContentView(buildOwnerBackupScreen())), new LinearLayout.LayoutParams(MATCH, WRAP));$1/' || fails=$((fails+1))
mutb s16 "B3 the owner Backup row removed" 's/\n *ll\.addView\(settingsRow\("Backup", "How often your data is saved",\n[^\n]*//' || fails=$((fails+1))
mutb s16 "B4 the owner Backup row opens the verify, not the screen" 's/(settingsRow\("Backup", "How often your data is saved",\n *v -> )setContentView\(buildOwnerBackupScreen\(\)\)/$1setContentView(buildOwnerVerifyScreen(StoreGate.DEST_DEVICE))/' || fails=$((fails+1))
mutb s17 "B4b the owner Backup row asks for the verify first" 's/(settingsRow\("Backup", "How often your data is saved",\n *v -> )setContentView\(buildOwnerBackupScreen\(\)\)/$1\{ if (!deviceControlsOpen()) openDeviceVerify(); else setContentView(buildOwnerBackupScreen()); }/' || fails=$((fails+1))
mutb s6 "B5 the cadence line keeps the separate verify" 's/bkRow\.setOnClickListener\(v -> showSyncIntervalPicker\(refreshBkRow\)\);/bkRow.setOnClickListener(v -> { if (deviceControlsOpen()) showSyncIntervalPicker(refreshBkRow); else openDeviceVerify(); });/' || fails=$((fails+1))
mutb s17 "B5b the screen asks for the verify before it opens" 's/(private View buildOwnerBackupScreen\(\) \{\n)/$1        if (!deviceControlsOpen()) openDeviceVerify();\n/' || fails=$((fails+1))
mutb s6 "B6 the picker opens from a second place" 's/(private View buildOwnerBackupScreen\(\) \{\n)/$1        showSyncIntervalPicker(() -> { });\n/' || fails=$((fails+1))
mutb s18 "B7 Back goes to Gate settings" 's/(LinearLayout ll = ownerColumn\("Backup"\);.*?ownerBack\("Back", v -> setContentView\()buildOwnerMenu\(\)/$1buildSettingsScreen()/s' || fails=$((fails+1))
mutb s18 "B8 Back goes to the gate" 's/(LinearLayout ll = ownerColumn\("Backup"\);.*?ownerBack\("Back", v -> setContentView\()buildOwnerMenu\(\)/$1gateView/s' || fails=$((fails+1))
mutb s19 "B9 the DEST_DEVICE line names backup again" 's/to change update settings\./to change backup and update settings./' || fails=$((fails+1))
mutb s20 "B10 onPause does not close the picker" 's/\n *if \(syncPicker != null\) \{ syncPicker\.dismiss\(\); syncPicker = null; \}//' || fails=$((fails+1))
mutb s20 "B11 the picker is not stored" 's/syncPicker = new android\.app\.AlertDialog\.Builder\(this\)/new android.app.AlertDialog.Builder(this)/' || fails=$((fails+1))
mutb s20 "B12 a second picker can open over the one syncPicker holds" 's/\n *if \(syncPicker != null && syncPicker\.isShowing\(\)\) return;[^\n]*//' || fails=$((fails+1))
mutb s16 "B13 SET-SYNC-INTERVAL is sent from the Backup screen too" 's/(private View buildOwnerBackupScreen\(\) \{\n)/$1        daemonCmd("SET-SYNC-INTERVAL\\n60");\n/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
