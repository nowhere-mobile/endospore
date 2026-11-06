#!/usr/bin/env bash
# test-captureperms-keepset.sh [<ProfileActivity.java>] [--mutate] -- which packages capturePerms can SEE, and
# that it records what the profile DECLINED (NWP-20261012-05).
#
# WHY THIS IS COMMITTED. nowhere-perms is written in exactly ONE place and the write is a WHOLE-FILE rewrite,
# so any package missing from that rewrite loses its restored runtime grants PERMANENTLY at logoff -- silently,
# with no error and nothing in the UI. Two independent filters used to conspire to produce exactly that: the
# candidate set is a CATEGORY_LAUNCHER query (so a launcher-LESS package is invisible), and the carry-forward
# that rescues absent packages was gated to DEFERRED modes only. A keep-INSTALLED app with no launcher activity
# -- sandboxed Play Services and GSF are precisely this -- was in neither, every single logoff.
#
# ⚠ THE TWO HALVES MUST STAY SPLIT, which is what most of these checks are really pinning. A blind
# carry-forward would "fix" the symptom and RESURRECT REVOKED PERMISSIONS: for a package that IS installed this
# session the LIVE grants are authoritative, so it has to reach the live enumeration (via `fresh`), not the
# carry-forward. Only a package that is genuinely absent may be carried.
#
# ⚠ AND THE EDIT SITE IS AMBIGUOUS BY TEXT. captureAppCode carries the SAME launcher-query block and the SAME
# `if (!deferredMode(e.getValue())) continue;` line, for APK CODE rather than permissions. A global replace
# aimed at capturePerms lands there instead and un-gates the wrong carry-forward, so this suite asserts
# captureAppCode's gate is STILL PRESENT as well.
#
# ⚠ A DECLINED PERMISSION IS RECORDED TOO (NWP-20261012-05). "Not granted" is a fresh user's default as much as a
# refusal, and the platform re-prompts for a permission that is not granted and carries neither USER_SET nor
# USER_FIXED -- so recording only grants made every declined permission (notifications above all) ask again after
# every roam. capturePerms reads those flags for each dangerous permission that is NOT granted and writes
# `<pkg> flags:<user-set|user-fixed|user-set,user-fixed>:<perm>`, which roamd's grant_perms_for re-declines
# (test-grant-declined-flags.sh pins that half). The read needs GET_RUNTIME_PERMISSIONS in the manifest; without it
# every read throws, so a failure must be counted and logged, never swallowed. Carry-forward copies an absent package's
# old lines WHOLE, which is what lets a flags line survive a session the app spent as a placeholder, and re-emits only
# the `flags:` lines of one materialised and archived again this session (withhold-only, so a stale line is safe).
# The old record is read strictly and grouped by PermsCaptureRule.oldLinesByPkg (NWP-20261123-11).
# What "declined" means (dangerous, USER_SET/USER_FIXED, not AUTO_REVOKED) is PermDeclines.declinedWord, pinned with
# the role re-apply by core/vendor-common/bin/test-perm-declines-java.sh.
#
# ⚠ A RECORDED DECLINE SURVIVES A ROLE GRANT, FOR EVERY PERMISSION (NWP-20261012-08 for the SMS six, widened to every
# permission by NWP-20261102-10, Q059). The SMS role holder keeps the six permissions the SMS role grants (READ_SMS,
# RECEIVE_SMS, RECEIVE_MMS, RECEIVE_WAP_PUSH, SEND_SMS, READ_CELL_BROADCASTS) over a decline, and a mid-session fill of
# an empty dialer or SMS role grants and clears the flags of any permission, so a live state reading "never answered"
# or "granted, no user flag" is not the user's answer; both sites in capturePerms carry a decline already on record, in
# any app (PermDeclines.carriedDecline, or oldDeclineWord when declinedWord's read just failed, so one failure is
# counted once), and the granted one writes it INSTEAD of the grant, so the decline returns at the next sign-in.
#
#   bash test-captureperms-keepset.sh            # the invariants
#   bash test-captureperms-keepset.sh --mutate   # ... plus mutations that must each CONVICT the suite
#
# Source-level checks on FUNCTIONAL forms (never comment text), same committed style as
# test-owner-mandatory.sh -- the chooser has no unit-test harness.
set -uo pipefail
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/src/com/nowhere/chooser/ProfileActivity.java}"
[ -f "$SUT" ] || { echo "no such file: $SUT" >&2; exit 2; }
MANIFEST="${MANIFEST:-$(dirname "$0")/AndroidManifest.xml}"
[ -f "$MANIFEST" ] || { echo "no such file: $MANIFEST" >&2; exit 2; }
RULE="${RULE:-$(dirname "$0")/src/com/nowhere/chooser/PermsCaptureRule.java}"
[ -f "$RULE" ] || { echo "no such file: $RULE" >&2; exit 2; }
RULESRC=$(cat "$RULE")

PY=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c "pass" >/dev/null 2>&1; then PY=$c; break; fi
done
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
# ⚠ Every match below reads its input to the end: a here-string (`grep -q PAT <<<"$var"`) or
# `grep -c PAT >/dev/null` on a pipe, never `cmd | grep -q`. Under pipefail grep -q exits at its first match,
# the producer can die of SIGPIPE, and the pipeline fails: an absence check then passes on the code it exists
# to reject, a presence check goes red at random (docs/backlog.md, "pipes into grep -q under pipefail").

# body <start-marker> <end-marker> -- print the source between two anchors, so every check below is scoped to
# ONE method. Without this the checks cannot tell capturePerms from captureAppCode at all.
body(){ awk "/$1/,/$2/" "$SUT"; }

PERMS=$(body 'static void capturePerms\(android\.content\.Context ctx, java\.util\.Map<String,String> keptModes, boolean midSession\) \{' '\/\*\* Read one ')
CODE=$(body 'private void captureAppCode\(\) \{' 'private void capturePrefs\(\) \{')
[ -n "$PERMS" ] && [ -n "$CODE" ] || { echo "EXTRACTION FAILED -- method anchors moved in $SUT" >&2; exit 2; }

echo "== capturePerms can see a launcher-LESS kept package =="
if grep -q 'for (String p : keptModes.keySet())' <<<"$PERMS"; then
  ok "the keep-set is unioned into the candidate set"
else
  no "the candidate set is the launcher query ALONE -- a launcher-less kept app loses its grants every logoff"
fi

echo "== the carry-forward is no longer DEFERRED-only =="
if grep -q 'if (!deferredMode(e.getValue())) continue;' <<<"$PERMS"; then
  no "capturePerms' carry-forward is gated to deferred modes again -- a keep-INSTALLED app that is ABSENT is dropped"
else
  ok "the carry-forward covers every kept package, not just the deferred ones"
fi

echo "== but a package present THIS session still wins on its LIVE grants (a revoke must stick) =="
if grep -q 'fresh.contains(pkg)' <<<"$PERMS"; then
  ok "the carry-forward skips anything captured live -- no stale grant can outrank a fresh revoke"
else
  no "the carry-forward no longer defers to live capture -- a revoked permission can be RESURRECTED"
fi
if grep -q 'fresh.add(pkg);' <<<"$PERMS"; then
  ok "the live enumeration still records what it captured"
else
  no 'nothing populates fresh -- the skip above can never fire'
fi

echo "== the SAME-SHAPED code in captureAppCode is untouched (different carry-forward, different meaning) =="
if grep -q 'if (!deferredMode(e.getValue())) continue;' <<<"$CODE"; then
  ok "captureAppCode's APK-code carry-forward is still deferred-gated"
else
  no "captureAppCode was un-gated too -- that re-emits stale APK CODE lines, a different bug entirely"
fi

echo "== a DECLINED permission is recorded, not just the granted ones (NWP-20261012-05) =="
# line <fixed string> -> the line number of its first occurrence inside capturePerms, 0 when absent
line(){ local l; l=$(grep -nF -- "$1" <<<"$PERMS" | head -1 | cut -d: -f1); echo "${l:-0}"; }
NOTG=$(line '& android.content.pm.PackageInfo.REQUESTED_PERMISSION_GRANTED) == 0) {')
INETL=$(line '.append(" deny:")')
READ=$(line 'String word = PermDeclines.declinedWord(pm, pkg, perm, android.os.Process.myUserHandle(), flagFails);')
EMIT=$(line 'sb.append(pkg).append(" flags:").append(word).append('"':'"').append(perm).append('"'\n'"');')
GRANTED=$(line 'try { // only roam DANGEROUS (runtime) grants')
if [ "$NOTG" -gt 0 ] && [ "$INETL" -gt "$NOTG" ] && [ "$READ" -gt "$INETL" ] && [ "$EMIT" -gt "$READ" ] \
   && [ "$GRANTED" -gt "$EMIT" ]; then
  ok "the decline is read and written in the NOT-granted branch, after INTERNET's deny: (lines $NOTG<$INETL<$READ<$EMIT<$GRANTED)"
else
  no "the declined-permission read is missing or out of place (not-granted $NOTG, deny $INETL, read $READ, emit $EMIT, granted $GRANTED)"
fi
if grep -qF 'if ("android.permission.INTERNET".equals(perm)) {' <<<"$PERMS" \
   && [ "$(sed -n "$((INETL + 1))p" <<<"$PERMS" | tr -d ' ')" = 'continue;' ]; then
  ok "INTERNET keeps its own deny: channel and never reaches the decline read"
else
  no "INTERNET's deny: no longer ends its branch -- it would also be written as a flags line roamd refuses"
fi
if [ "$EMIT" -gt 0 ] && [ "$(sed -n "$((EMIT - 1))p" <<<"$PERMS" | tr -d ' ')" = 'if(word!=null){' ]; then
  ok "only an ANSWERED permission is written as declined (word != null)"
else
  no "the flags line is no longer guarded by word != null -- a never-answered permission would roam as declined"
fi
if [ "$EMIT" -gt 0 ] && [ "$(sed -n "$((EMIT + 1))p" <<<"$PERMS" | tr -d ' ')" = 'declined++;' ]; then
  ok "each decline written is counted"
else
  no "declined++ no longer follows the flags line -- the log under-reports what roams"
fi
if grep -qF 'if (flagFails.n > 0)' <<<"$PERMS" \
   && grep -qF 'android.util.Log.w("NowhereChooser", "capturePerms: " + flagFails.n + " permission-flag read(s) FAILED --"' <<<"$PERMS" \
   && grep -qF '+ " (is GET_RUNTIME_PERMISSIONS granted to the chooser?) (NWP-20261012-05)", flagFails.first);' <<<"$PERMS"; then
  ok "a failed read is logged with its count and first reason, not swallowed"
else
  no "a failed read is silent -- without GET_RUNTIME_PERMISSIONS every decline would stop roaming unseen"
fi
if grep -qF '+ declined + " declined kept, " + flagFails.n + " flag read(s) failed)");' <<<"$PERMS"; then
  ok "the summary line reports the declines kept and the reads that failed"
else
  no "the summary line lost its decline or failure count -- the device proof reads them there"
fi
if grep -qF '<uses-permission android:name="android.permission.GET_RUNTIME_PERMISSIONS"/>' "$MANIFEST"; then
  ok "the manifest requests GET_RUNTIME_PERMISSIONS"
else
  no "the manifest does not request GET_RUNTIME_PERMISSIONS -- getPermissionFlags throws for every permission"
fi
if grep -qF 'PermsCaptureRule.oldLinesByPkg(SettingsText.read(new java.io.File(ctx.getFilesDir(), "nowhere-perms")));' <<<"$PERMS" \
   && grep -qF 'm.computeIfAbsent(ln.substring(0, sp), k -> new java.util.ArrayList<>()).add(ln);' <<<"$RULESRC" \
   && grep -qF 'if (ctx.getPackageName().equals(pkg) || fresh.contains(pkg)) continue;' <<<"$PERMS" \
   && grep -qF 'boolean declinesOnly = materialised.contains(pkg);' <<<"$PERMS" \
   && grep -qxF '                        if (declinesOnly) {' <<<"$PERMS" \
   && grep -qF 'String soft = PermDeclines.softenedDecline(ln, pkg);' <<<"$PERMS" \
   && grep -qF 'if (soft != null) sb.append(soft).append' <<<"$PERMS" \
   && ! grep -qF '|| materialised.contains(pkg)) continue;' <<<"$PERMS"; then
  ok "carry-forward: an absent package keeps every old line; a materialised-then-archived one only its declines, softened"
else
  no "carry-forward changed -- a placeholder session drops a decline, or a materialised app's stale GRANTS come back"
fi

echo "== a role grant cannot erase a recorded decline, any permission (NWP-20261012-08, NWP-20261102-10) =="
# A role keeps its grant over a recorded decline -- roamd leaves the SMS six to the role, and a role's grant clears the
# user flags of any permission -- so the live state reads "never answered" (not granted) or "granted, no flags".
# Recording that would lose the refusal for good; PermDeclines.carriedDecline carries the login-time decline instead.
CARRY='PermDeclines.carriedDecline(pm, pkg, perm, android.os.Process.myUserHandle(),'
NGC=$(line 'if (word == null)')
GRC=$(line 'String keptDecline = PermDeclines.carriedDecline(pm, pkg, perm, android.os.Process.myUserHandle(),')
if [ "$NGC" -gt "$READ" ] && [ "$EMIT" -gt "$NGC" ] && [ "$READ" -gt 1 ] \
   && [ "$(sed -n "$((NGC + 1)),$((NGC + 3))p" <<<"$PERMS" | tr -d ' ' | tr '\n' '~')" \
        = 'word=flagFails.n>readFails?PermDeclines.oldDeclineWord(oldByPkg.get(pkg),pkg,perm)~:PermDeclines.carriedDecline(pm,pkg,perm,android.os.Process.myUserHandle(),~oldByPkg.get(pkg),flagFails);~' ]; then
  ok "not granted and never answered: the decline on record is carried (lines $READ<$NGC<$EMIT)"
else
  no "a not-granted permission a role was given loses its recorded decline (read $READ, carry $NGC, emit $EMIT)"
fi
# NWP-20261012-08 review: one failed read is counted ONCE. declinedWord counts its own failure; the carry then takes
# the decline on record without reading the same flags again (oldDeclineWord), so the summary's count stays true.
if [ "$(sed -n "$((READ - 1))p" <<<"$PERMS" | tr -d ' ')" = 'intreadFails=flagFails.n;' ]; then
  ok "a failed flag read is counted once: the carry does not read again after declinedWord failed"
else
  no "the failure count before declinedWord is gone -- a failed read is counted twice, or the carry re-reads"
fi
if grep -qF '+ " a declined permission whose read failed will NOT roam and will be asked again after the next"' <<<"$PERMS" \
   && grep -qF '+ " login, except one whose decline is already on record, which is"' <<<"$PERMS"; then
  ok "the failure warning says what does and does not roam"
else
  no "the failure warning no longer says which declines still roam"
fi
if [ "$GRC" -gt "$EMIT" ] && [ "$GRANTED" -gt "$GRC" ] \
   && [ "$(sed -n "$((GRC + 1))p" <<<"$PERMS" | tr -d ' ')" = 'oldByPkg.get(pkg),flagFails);' ] \
   && [ "$(sed -n "$((GRC + 2)),$((GRC + 6))p" <<<"$PERMS" | tr -d ' ' | tr '\n' '~')" \
        = "if(keptDecline!=null){~sb.append(pkg).append(\"flags:\").append(keptDecline).append(':').append(perm).append('\\n');~declined++;~continue;~}~" ]; then
  ok "granted by the role over a decline: the decline is written INSTEAD of the grant (lines $EMIT<$GRC<$GRANTED)"
else
  no "a role-granted permission is recorded as a grant -- the decline would not come back at the next sign-in (carry $GRC)"
fi
[ "$(grep -cF "$CARRY" <<<"$PERMS")" = 2 ] && ok "exactly the two carry sites" \
  || no "the carry appears $(grep -cF "$CARRY" <<<"$PERMS") time(s), want 2"

if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each MUST be convicted) =="
  M=$(mktemp -d -p "$W")
  [ -n "$PY" ] || { echo "  SKIP  mutations: no working python on PATH" >&2; }
  mutate(){
    [ -n "$PY" ] || { no "MUTATION UNRUN (no python): $1"; return; }
    if ! "$PY" -c "
import io,sys
p,out=sys.argv[1],sys.argv[2]
s=io.open(p,encoding='utf-8',newline='').read()
$2
io.open(out,'w',encoding='utf-8',newline=chr(10)).write(s)
" "$SUT" "$M/m.java"; then no "MUTATION BROKEN: $1"; return; fi
    if cmp -s "$SUT" "$M/m.java"; then no "MUTATION INERT: $1"; return; fi
    if bash "$0" "$M/m.java" >/dev/null 2>&1; then no "NOT CONVICTED: $1 -- suite passes on broken code"
    else ok "convicted: $1"; fi
  }
  mutate "the keep-set union is removed (back to launcher-only)" \
    "s=s.replace('                for (String p : keptModes.keySet()) {','                for (String p : new java.util.ArrayList<String>()) {',1)"
  mutate "capturePerms' carry-forward is deferred-gated again (the filed bug)" \
    "i=s.index('static void capturePerms(');j=s.index('for (java.util.Map.Entry<String,String> e : keptModes.entrySet()) {',i);s=s[:j]+'for (java.util.Map.Entry<String,String> e : keptModes.entrySet()) {'+chr(10)+'                    if (!deferredMode(e.getValue())) continue;'+s[j+len('for (java.util.Map.Entry<String,String> e : keptModes.entrySet()) {'):]"
  mutate "the live-capture skip is dropped (a fresh revoke gets resurrected)" \
    "i=s.index('static void capturePerms(');j=s.index('fresh.contains(pkg)',i);s=s[:j]+'false'+s[j+len('fresh.contains(pkg)'):]"
  mutate "captureAppCode is un-gated instead (the wrong function -- what a global replace would do)" \
    "i=s.index('private void captureAppCode');j=s.index('                if (!deferredMode(e.getValue())) continue;'+chr(10),i);s=s[:j]+s[j+len('                if (!deferredMode(e.getValue())) continue;'+chr(10)):]"
  mutate "the decline read is gone (every permission reads as never answered)" \
    "s=s.replace('String word = PermDeclines.declinedWord(pm, pkg, perm, android.os.Process.myUserHandle(), flagFails);','String word = null;',1)"
  mutate "the flags line is no longer written" \
    "i=s.index('static void capturePerms(');j=s.index('.append(\" flags:\").append(word)',i);s=s[:j]+'.append(\" x:\").append(word)'+s[j+len('.append(\" flags:\").append(word)'):]"
  mutate "declined++ is dropped (C2)" \
    "i=s.index('static void capturePerms(');j=s.index('                                    declined++;'+chr(10),i);s=s[:j]+s[j+len('                                    declined++;'+chr(10)):]"
  mutate "the failure log is dropped" \
    "s=s.replace('                if (flagFails.n > 0)'+chr(10),'                if (false)'+chr(10),1)"
  mutate "the summary line loses its counts (C3)" \
    "s=s.replace('+ declined + \" declined kept, \" + flagFails.n + \" flag read(s) failed)\");','+ \"0 declined kept, 0 flag read(s) failed)\");',1)"
  mutate "INTERNET falls through to the decline read" \
    "i=s.index('static void capturePerms(');j=s.index('.append(\" deny:\")',i);k=s.index('continue;',j);s=s[:k]+s[k+len('continue;'):]"
  mutate "a materialised-then-archived app drops its declines again (F4)" \
    "s=s.replace('                    boolean declinesOnly = materialised.contains(pkg);','                    if (materialised.contains(pkg)) continue;'+chr(10)+'                    boolean declinesOnly = false;',1)"
  mutate "a materialised-then-archived app re-emits its stale grants too" \
    "s=s.replace('                        if (declinesOnly) {','                        if (false) {',1)"
  mutate "carry-forward keeps a materialised app's user-fixed as is" \
    "s=s.replace('String soft = PermDeclines.softenedDecline(ln, pkg);','String soft = ln.startsWith(pkg + \" flags:\") ? ln : null;',1)"
  mutate "a never-answered permission is written as declined (M12)" \
    "i=s.index('static void capturePerms(');j=s.index('if (word != null) {',i);s=s[:j]+'if (true) {'+s[j+len('if (word != null) {'):]"
  mutate "the not-granted SMS carry is gone (NWP-20261012-08)" \
    "s=s.replace('                                if (word == null)'+chr(10),'                                if (false)'+chr(10),1)"
  mutate "the role-granted SMS permission is recorded as a grant (no carry)" \
    "s=s.replace('                            if (keptDecline != null) {','                            if (false) {',1)"
  mutate "the role-granted SMS permission is recorded as a grant AND a decline" \
    "i=s.index('if (keptDecline != null) {');j=s.index('                                continue;'+chr(10),i);s=s[:j]+s[j+len('                                continue;'+chr(10)):]"
  mutate "a failed read is read again and counted twice" \
    "s=s.replace('word = flagFails.n > readFails ? PermDeclines.oldDeclineWord(oldByPkg.get(pkg), pkg, perm)','word = false ? PermDeclines.oldDeclineWord(oldByPkg.get(pkg), pkg, perm)',1)"
  mutate "a failed read drops the decline on record" \
    "s=s.replace('word = flagFails.n > readFails ? PermDeclines.oldDeclineWord(oldByPkg.get(pkg), pkg, perm)','word = flagFails.n > readFails ? null',1)"
  mutate "the failure count is taken after the read (never sees it fail)" \
    "s=s.replace('                                int readFails = flagFails.n;'+chr(10),'',1).replace('flagFails.n > readFails ?','flagFails.n > flagFails.n ?',1)"
  mutate "the failed-read carry is SMS-only again (NWP-20261102-10)" \
    "s=s.replace('? PermDeclines.oldDeclineWord(oldByPkg.get(pkg), pkg, perm)','? (PermDeclines.smsRolePerm(perm) ? PermDeclines.oldDeclineWord(oldByPkg.get(pkg), pkg, perm) : null)',1)"
  mutate "the carry reads no old file (null old lines)" \
    "s=s.replace('                                    oldByPkg.get(pkg), flagFails);','                                    null, flagFails);',1)"
  # The manifest, mutated separately: the suite reads it from MANIFEST.
  if [ -n "$PY" ]; then
    "$PY" -c "
import io,sys
s=io.open(sys.argv[1],encoding='utf-8',newline='').read()
t=s.replace('<uses-permission android:name=\"android.permission.GET_RUNTIME_PERMISSIONS\"/>','',1)
io.open(sys.argv[2],'w',encoding='utf-8',newline=chr(10)).write(t)
" "$MANIFEST" "$M/m.xml"
    if cmp -s "$MANIFEST" "$M/m.xml"; then no "MUTATION INERT: the manifest no longer requests GET_RUNTIME_PERMISSIONS"
    elif MANIFEST="$M/m.xml" bash "$0" "$SUT" >/dev/null 2>&1; then
      no "NOT CONVICTED: the manifest no longer requests GET_RUNTIME_PERMISSIONS -- suite passes on broken code"
    else ok "convicted: the manifest no longer requests GET_RUNTIME_PERMISSIONS"; fi
  else
    no "MUTATION UNRUN (no python): the manifest no longer requests GET_RUNTIME_PERMISSIONS"
  fi
  rm -rf "$M"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
