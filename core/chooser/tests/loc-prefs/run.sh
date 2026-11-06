#!/usr/bin/env bash
# run.sh <ProfileActivity.java> -- NWP-20261016-45: lift the chooser's pure Location services members verbatim out of
# ProfileActivity.java by signature, and run LocPrefsCases against them under plain javac/java: the nowhere-prefs parser
# prefValueIn, the composer prefsText, setPref's read-modify step prefsUpdated, the On rule locPrefOn, who is offered
# the switches (locOffered), the reply rules locReplyValue and locApplied, the two toasts locApplyToast and
# locNotSavedToast, the two key constants and the prefs file's name. They use only java.lang, so the class compiles
# with no Android SDK. $JAVAC / $JAVA come from the caller (core/chooser/test-loc-prefs-java.sh).
#
# What cannot run without Android is PINNED in the source, byte for byte where it is a block: setPref (only the file
# I/O around prefsUpdated, written to PREFS_FILE, and a false when the write fails), readPrefsText (the whole file,
# read from PREFS_FILE), the switch handler (write first; then APPLY-LOCATION whether or not the write landed, since
# roamd applies what the file holds; a failed write redraws the screen from the file and toasts what the file holds,
# else the toast is the tap's; either only for the choice still stored), the switch's initial state, the two rows' keys
# in order, the one Preferences branch that offers the screen, and the provider test.
#
# Exit codes: 1 = a case or a pin failed; 2 = a member did not extract; 3 = the lifted class or the cases did not compile.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/ProfileActivity.java}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
methods="prefValueIn prefsText prefsUpdated locPrefOn locOffered locReplyValue locApplied locApplyToast locNotSavedToast"
{
  echo "final class Lifted {"
  for k in PREF_NETLOC PREF_GEOCODER PREFS_FILE; do
    grep -E "^    static final String $k = \"[a-z-]+\";$" "$SRC" || true
  done
  for m in $methods; do
    # from the method's signature line to the brace that closes it (a signature may run over two lines)
    awk -v m="$m" '
      !on && index($0, "    static ") == 1 && index($0, " " m "(") { on=1; depth=0 }
      on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
    ' "$SRC"
  done
  echo "}"
} > "$D/Lifted.java"
for k in PREF_NETLOC PREF_GEOCODER PREFS_FILE; do
  [ "$(grep -c "static final String $k = " "$D/Lifted.java")" = 1 ] || { echo "EXTRACTION FAILED: $k" >&2; exit 2; }
done
for m in $methods; do
  [ "$(grep -cE "^    static [A-Za-z]+ $m\(" "$D/Lifted.java")" = 1 ] || { echo "EXTRACTION FAILED: $m" >&2; exit 2; }
done
cp "$here/LocPrefsCases.java" "$D/"
# prefsText and prefsUpdated call MobileData (NWP-20261026-07): it is pure Java, so it is compiled beside Lifted with its
# package line dropped. $MOBILEDATA_JAVA lets test-mobile-data-java.sh hand in a mutant of it.
MD="${MOBILEDATA_JAVA:-$here/../../src/com/nowhere/chooser/MobileData.java}"
[ -f "$MD" ] || { echo "EXTRACTION FAILED: $MD does not exist" >&2; exit 2; }
grep -v '^package ' "$MD" > "$D/MobileData.java"
# prefsText and prefsUpdated call WipeOnSave too (NWP-20261106-15), compiled the same way.
WOS="$here/../../src/com/nowhere/chooser/WipeOnSave.java"
[ -f "$WOS" ] || { echo "EXTRACTION FAILED: $WOS does not exist" >&2; exit 2; }
grep -v '^package ' "$WOS" > "$D/WipeOnSave.java"
"$JAVAC" -encoding UTF-8 -d "$D" "$D/Lifted.java" "$D/MobileData.java" "$D/WipeOnSave.java" "$D/LocPrefsCases.java" || exit 3
rc=0
"$JAVA" -Dfile.encoding=UTF-8 -Djava.io.tmpdir="$D" -cp "$D" LocPrefsCases || rc=$?
[ "$rc" = 0 ] || [ "$rc" = 1 ] || exit 3

# --- the source pins ---------------------------------------------------------------------------------------------------
pass() { echo "  ok    $1"; }
fail() { echo "  FAIL  $1"; rc=1; }
# pin_block <label>, the block on stdin: it must start at a line found exactly once in the source, and the lines from
# there must be the block, byte for byte.
pin_block() {
  local want first n at got
  want=$(cat)
  first=$(head -n 1 <<< "$want")
  n=$(wc -l <<< "$want")
  if [ "$(grep -cxF -- "$first" "$SRC" || true)" != 1 ]; then fail "$1 (its first line is not in the source exactly once)"; return; fi
  at=$(grep -nxF -- "$first" "$SRC" | cut -d: -f1)
  got=$(sed -n "${at},$((at + n - 1))p" "$SRC")
  if [ "$got" = "$want" ]; then pass "$1"; else fail "$1 (the block at line $at differs)"; fi
}
# line_of <exact line>: its line number when it is in the source exactly once, else nothing
line_of() { [ "$(grep -cxF -- "$1" "$SRC" || true)" = 1 ] && grep -nxF -- "$1" "$SRC" | cut -d: -f1 || true; }

pin_block "setPref is only the file I/O around prefsUpdated, writes PREFS_FILE through StoreInstaller.writeAtomic, and answers false when the write fails" <<'EOF'
    private boolean setPref(String key, String value) {
        String text = prefsUpdated(readPrefsText(), key, value, java.util.Locale.getDefault().toLanguageTag());
        try {
            StoreInstaller.writeAtomic(new java.io.File(getFilesDir(), PREFS_FILE), text);
            return true;
        } catch (Exception e) {
            android.util.Log.w("NowhereChooser", "setPref " + key, e);
            return false;
        }
    }
EOF

pin_block "readPrefsText reads the whole of PREFS_FILE, the file setPref writes, and gives \"\" when it cannot" <<'EOF'
    private String readPrefsText() {
        try {
            return new String(java.nio.file.Files.readAllBytes(new java.io.File(getFilesDir(), PREFS_FILE).toPath()),
                    java.nio.charset.StandardCharsets.UTF_8);
        } catch (Exception ignore) {
            return "";
        }
    }
EOF

pin_block "the switch: its state is the stored choice; a tap writes \"1\"/\"\" first and then always asks for APPLY-LOCATION; a failed write redraws the screen from the file and toasts what the file holds; a toast only for the choice still stored" <<'EOF'
        sw.setChecked(locPrefOn(readPrefValue(key)));
        sw.setOnCheckedChangeListener((b, on) -> {
            final boolean saved = setPref(key, on ? "1" : "");
            // After a failed write the choice is whatever the file holds now -- the earlier value, since a failed write
            // leaves the file as it was -- and the redraw shows that on both switches, which are built from the file.
            final boolean want = saved ? on : locPrefOn(readPrefValue(key));
            if (!saved) showLocationServices();
            LOC_APPLY.execute(() -> {
                final String reply = sendDaemon("APPLY-LOCATION\n");
                runOnUiThread(() -> {
                    boolean stillChosen = locPrefOn(readPrefValue(key)) == want;
                    String t = saved ? locApplyToast(title, key, on, reply, stillChosen)
                            : locNotSavedToast(title, key, want, reply, stillChosen);
                    if (t != null) android.widget.Toast.makeText(ProfileActivity.this, t,
                            android.widget.Toast.LENGTH_LONG).show();
                });
            });
        });
EOF

# The two rows, each with its own key, Network location first.
t1=$(line_of '        ll.addView(locSwitchRow("Network location",')
k1=$(line_of '                PREF_NETLOC), new LinearLayout.LayoutParams(MATCH, WRAP));')
t2=$(line_of '        ll.addView(locSwitchRow("Geocoding",')
k2=$(line_of '                PREF_GEOCODER), new LinearLayout.LayoutParams(MATCH, WRAP));')
if [ -n "$t1" ] && [ -n "$k1" ] && [ -n "$t2" ] && [ -n "$k2" ] && [ "$t1" -lt "$k1" ] && [ "$k1" -lt "$t2" ] \
   && [ "$t2" -lt "$k2" ]; then
  pass "the Network location row stores under netloc and the Geocoding row under geocoder"
else fail "the two rows' keys (title/key lines: ${t1:-none} ${k1:-none} ${t2:-none} ${k2:-none})"; fi

# Preferences offers the screen in one branch, decided by locOffered, and nowhere else. The four mentions are its
# definition, that branch's row, the redraw inside its own switch handler (pinned above), which only that screen
# reaches, and the preset preview's "Location" link (NWP-20261122-02), which is tappable only under the same
# locOffered test.
lo=$(line_of '            if (locOffered(sessionType, offlineSession, locServicesAvailable())) {')
calls=$(grep -c 'showLocationServices()' "$SRC" || true)
rows=$(grep -c '() -> showLocationServices()' "$SRC" || true)
call=$(grep -n '() -> showLocationServices()' "$SRC" | cut -d: -f1 | head -n 1 || true)
redraw=$(line_of '            if (!saved) showLocationServices();')
plo=$(line_of '                    : locOffered(sessionType, offlineSession, locServicesAvailable());')
plink=$(line_of '                    else showLocationServices();')
if [ -n "$lo" ] && [ "$calls" = 4 ] && [ "$rows" = 1 ] && [ -n "$redraw" ] && [ -n "$call" ] && [ "$call" -gt "$lo" ] \
   && [ $((call - lo)) -le 4 ] && [ -n "$plo" ] && [ -n "$plink" ] && [ "$plink" -gt "$plo" ] \
   && [ $((plink - plo)) -le 8 ]; then
  pass "Preferences offers Location services only in the branch locOffered decides"
else fail "the Preferences branch for Location services (locOffered line ${lo:-none}, call ${call:-none}, $rows row(s), redraw ${redraw:-none}, $calls mention(s))"; fi

[ -n "$(line_of '        return new java.io.File(LOC_PROVIDER_APK).isFile();')" ] \
  && pass "the provider test is the provider file" || fail "locServicesAvailable no longer tests the provider file"
[ -n "$(line_of '        return prefValueIn(readPrefsText(), key);')" ] \
  && pass "readPrefValue reads through prefValueIn" || fail "readPrefValue no longer reads through prefValueIn"
exit "$rc"
