#!/usr/bin/env bash
# test-perms-capture-receiver.sh [--mutate] -- NWP-20261112-07: the session half of permissions captured on change
# (docs/product-decisions.md, 2026-10-20, Q061). Backlog row "A permission answered in a session that never signs out
# is lost: permissions are captured only at sign-out". NWP-20261123-11: backlog row "An unreadable nowhere-perms or
# keep-set at a permission capture drops every On-demand placeholder's carried lines, re-granting INTERNET to a
# Network-off app" (r4, r5, r7-r9).
#
# Runs core/chooser/tests/perms-capture (PermsCaptureRule.keepCarried and oldLinesByPkg, compiled and EXECUTED), then
# source checks on
# the real files:
#   r1 capturePerms is `static void capturePerms(Context ctx, Map<String,String> keptModes, boolean midSession)` and its
#      body calls no bare getFilesDir( / getPackageManager( / getPackageName( / getSystemService( / readAppModes(
#      (it runs from PermsCaptureReceiver, with no Activity);
#   r2 the whole body is inside synchronized (PERMS_CAPTURE_LOCK), so a relayed capture and the sign-out's never
#      interleave their read-modify-write of nowhere-perms;
#   r3 the live loop skips a package PermsCaptureRule.keepCarried holds (with UnarchiveService.odRestored(ctx, pkg)),
#      and the carry-forward re-emits its old lines verbatim, before the softening branch;
#   r4 doLogoffImpl calls capturePerms(this, readAppModesStrictIn(getFilesDir()), false), after captureAppCode();
#   r5 PermsCaptureReceiver returns for user 0 before goAsync, and passes readAppModesStrictIn and true;
#   r6 the manifest declares PermsCaptureReceiver exported="false";
#   r7 capturePerms returns on a null keptModes (an unreadable keep-set) before it enumerates anything;
#   r8 capturePerms reads nowhere-perms through SettingsText.read and PermsCaptureRule.oldLinesByPkg, and returns on
#      null (an unreadable record) before it enumerates or writes anything;
#   r9 neither caller passes the lenient readAppModes() or readAppModesIn( (an unreadable keep-set read as empty).
# What it does not prove: the chooser is not compiled here (the build host's javac check is), nothing runs on a
# device, and nothing sends to the receiver until the user-0 listener and relay (NOWHERE-1073).
#
# It needs a JDK, and it FAILS when there is none. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
# --mutate re-runs the suite against broken copies, each of which must be CONVICTED: a mutant that does not apply
# (INERT) or does not compile (BROKEN) counts as a failure, never a pass.
#
#   bash test-perms-capture-receiver.sh            # the cases and source checks
#   bash test-perms-capture-receiver.sh --mutate   # ... plus the mutants
set -uo pipefail
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W"
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-perms-capture-receiver: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
SRCDIR="$ROOT/core/chooser/src/com/nowhere/chooser"
RULE="$SRCDIR/PermsCaptureRule.java"
PA="$SRCDIR/ProfileActivity.java"
RCV="$SRCDIR/PermsCaptureReceiver.java"
MAN="$ROOT/core/chooser/AndroidManifest.xml"

SIG='    static void capturePerms(android.content.Context ctx, java.util.Map<String,String> keptModes, boolean midSession) {'

# body <file>: capturePerms from its signature line to the brace that closes it, `//` comments stripped (the body holds
# no `//` and no brace inside a string literal). Empty when the signature is missing or the braces never balance.
body() {
  awk -v sig="$SIG" '
    !on && $0 == sig { on=1 }
    on {
      code=$0; sub(/\/\/.*$/, "", code); print code
      for (i=1;i<=length(code);i++) { c=substr(code,i,1); if (c=="{") d++; else if (c=="}") { d--; if (d==0) { ok=1; exit } } }
    }
    END { if (!ok) print "__UNBALANCED__" }' "$1"
}

# lineof <fixed string> <text>: the 1-based line of its first occurrence, 0 when absent
lineof() {
  local n
  n=$(grep -nF -- "$1" <<<"$2" | head -1 | cut -d: -f1)
  echo "${n:-0}"
}

# check <rule> <ProfileActivity.java> <PermsCaptureReceiver.java> <AndroidManifest.xml>: the cases, then r1-r9.
# Returns 3 when the cases do not compile, 1 on any failed case or check.
check() {
  local rule=$1 pa=$2 rcv=$3 man=$4 rc b src n l1 l2 l3 nxt start rs ps
  JAVAC=$JAVAC JAVA=$JAVA bash "$ROOT/core/chooser/tests/perms-capture/run.sh" "$rule"; rc=$?
  [ "$rc" -eq 0 ] || { echo "FAIL cases (run.sh rc=$rc)"; [ "$rc" -eq 3 ] && return 3; return 1; }
  src=$(cat "$pa")
  # (r1)
  n=$(grep -cxF -- "$SIG" <<<"$src")
  [ "$n" = 1 ] || { echo "FAIL r1: the capturePerms(Context, Map, boolean) signature occurs $n time(s), want 1"; return 1; }
  b=$(body "$pa")
  case "$b" in *__UNBALANCED__*) echo "FAIL r1: capturePerms' braces never balance"; return 1 ;; esac
  n=$(grep -cE '(^|[^.[:alnum:]_])(getFilesDir|getPackageManager|getPackageName|getSystemService|readAppModes)\(' <<<"$b")
  [ "$n" = 0 ] || { echo "FAIL r1: capturePerms' body calls $n bare Activity method(s) or readAppModes()"; return 1; }
  echo "  ok   r1 capturePerms takes (ctx, keptModes, midSession) and calls nothing on an Activity"
  # (r2) the first line after the signature opens the lock; the last two close the lock and the method
  l1=$(sed -n '2p' <<<"$b"); l2=$(tail -n 2 <<<"$b" | head -1); l3=$(tail -n 1 <<<"$b")
  [ "$l1" = '        synchronized (PERMS_CAPTURE_LOCK) {' ] && [ "$l2" = '        }' ] && [ "$l3" = '    }' ] \
    || { echo "FAIL r2: capturePerms' body is not wholly inside synchronized (PERMS_CAPTURE_LOCK)"; return 1; }
  n=$(grep -cxF '    private static final Object PERMS_CAPTURE_LOCK = new Object();' <<<"$src")
  [ "$n" = 1 ] || { echo "FAIL r2: PERMS_CAPTURE_LOCK is declared $n time(s), want 1"; return 1; }
  echo "  ok   r2 the whole body runs under PERMS_CAPTURE_LOCK"
  # (r3) the live-loop skip, and the verbatim carry before the softening branch
  l1=$(lineof 'if (PermsCaptureRule.keepCarried(midSession, keptModes.get(pkg), UnarchiveService.odRestored(ctx, pkg))) {' "$b")
  l2=$(lineof 'for (String pkg : pkgs) {' "$b")
  [ "$l1" -gt 0 ] && [ "$l2" -gt 0 ] && [ "$l1" -gt "$l2" ] \
    || { echo "FAIL r3: the live loop does not ask PermsCaptureRule.keepCarried(..., UnarchiveService.odRestored(ctx, pkg))"; return 1; }
  [ "$(sed -n "$((l1+1))p" <<<"$b" | tr -d ' ')" = 'held.add(pkg);' ] && [ "$(sed -n "$((l1+2))p" <<<"$b" | tr -d ' ')" = 'continue;' ] \
    || { echo "FAIL r3: a held package is not skipped in the live loop (held.add + continue)"; return 1; }
  l1=$(lineof 'if (held.contains(pkg)) {' "$b")
  l2=$(lineof 'boolean declinesOnly = materialised.contains(pkg);' "$b")
  l3=$(lineof 'for (java.util.Map.Entry<String,String> e : keptModes.entrySet()) {' "$b")
  [ "$l1" -gt 0 ] && [ "$l2" -gt "$l1" ] && [ "$l3" -gt 0 ] && [ "$l1" -gt "$l3" ] \
    || { echo "FAIL r3: the carry-forward does not take a held package before the softening branch"; return 1; }
  [ "$(sed -n "$((l1+1))p" <<<"$b" | tr -d ' ')" = "for(Stringln:old)sb.append(ln).append('\\n');" ] \
    && [ "$(sed -n "$((l1+2))p" <<<"$b" | tr -d ' ')" = 'continue;' ] \
    || { echo "FAIL r3: a held package's old lines are not re-emitted verbatim"; return 1; }
  echo "  ok   r3 an unrestored deferred app is held mid-session and carried verbatim"
  # (r4) doLogoffImpl: captureAppCode(); then capturePerms(this, readAppModesStrictIn(getFilesDir()), false);, and no
  # other caller
  n=$(sed 's#//.*$##' <<<"$src" | grep -c 'capturePerms(')
  [ "$n" = 2 ] || { echo "FAIL r4: capturePerms( appears $n time(s) in code, want 2 (the definition and the sign-out)"; return 1; }
  start=$(lineof '    private void doLogoffImpl(final boolean forInstall) {' "$src")
  [ "$start" -gt 0 ] || { echo "FAIL r4: no doLogoffImpl"; return 1; }
  nxt=$(awk -v s="$start" 'NR>s && /^    [a-zA-Z].*\) \{$/ { print NR; exit }' <<<"$src")
  l1=$(awk -v s="$start" 'NR>s && /^ *captureAppCode\(\);/ { print NR; exit }' <<<"$src")
  l2=$(awk -v s="$start" 'NR>s && /^ *capturePerms\(this, readAppModesStrictIn\(getFilesDir\(\)\), false\);/ { print NR; exit }' <<<"$src")
  [ -n "$nxt" ] && [ -n "$l1" ] && [ -n "$l2" ] && [ "$l1" -lt "$l2" ] && [ "$l2" -lt "$nxt" ] \
    || { echo "FAIL r4: doLogoffImpl does not call capturePerms(this, readAppModesStrictIn(getFilesDir()), false) after captureAppCode()"; return 1; }
  echo "  ok   r4 the sign-out passes (this, readAppModesStrictIn(getFilesDir()), false) after captureAppCode()"
  # (r5) the receiver
  rs=$(sed 's#//.*$##' "$rcv")
  l1=$(lineof 'if (android.os.UserHandle.myUserId() == 0) return;' "$rs")
  l2=$(lineof 'goAsync()' "$rs")
  [ "$l1" -gt 0 ] && [ "$l2" -gt "$l1" ] || { echo "FAIL r5: PermsCaptureReceiver does not return for user 0 before goAsync"; return 1; }
  case "$rs" in *'ProfileActivity.capturePerms(app, ProfileActivity.readAppModesStrictIn(app.getFilesDir()), true);'*) ;;
    *) echo "FAIL r5: PermsCaptureReceiver does not call capturePerms(app, readAppModesStrictIn(...), true)"; return 1 ;; esac
  case "$rs" in *'} finally { pending.finish(); }'*) ;; *) echo "FAIL r5: pending.finish() is not in a finally"; return 1 ;; esac
  echo "  ok   r5 the receiver never acts in user 0 and runs a mid-session capture"
  # (r6) the manifest
  n=$(grep -cxF '    <receiver android:name=".PermsCaptureReceiver" android:exported="false"/>' "$man")
  [ "$n" = 1 ] || { echo "FAIL r6: the manifest declares PermsCaptureReceiver exported=\"false\" $n time(s), want 1"; return 1; }
  n=$(grep -c 'PermsCaptureReceiver.*exported="true"' "$man")
  [ "$n" = 0 ] || { echo "FAIL r6: PermsCaptureReceiver is exported"; return 1; }
  echo "  ok   r6 the manifest declares PermsCaptureReceiver, not exported"
  # (r7) an unreadable keep-set (null) returns before the first enumeration and the keep-set union
  l1=$(lineof 'if (keptModes == null) {' "$b")
  [ "$l1" -gt 0 ] || { echo "FAIL r7: capturePerms does not test keptModes == null"; return 1; }
  l2=$(awk -v s="$l1" 'NR>s && NR<=s+4 && /^ *return; *$/ { print NR; exit } NR>s && /^ *\} *$/ { exit }' <<<"$b")
  l3=$(lineof 'pm.queryIntentActivities(' "$b"); n=$(lineof 'keptModes.keySet()' "$b")
  [ -n "$l2" ] && [ "$l3" -gt "$l2" ] && [ "$n" -gt "$l2" ] \
    || { echo "FAIL r7: a null keptModes does not return before pm.queryIntentActivities and keptModes.keySet()"; return 1; }
  echo "  ok   r7 an unreadable keep-set returns before anything is enumerated"
  # (r8) the record is read strictly and an unreadable one returns before the enumeration and the write
  l1=$(lineof 'PermsCaptureRule.oldLinesByPkg(SettingsText.read(new java.io.File(ctx.getFilesDir(), "nowhere-perms")));' "$b")
  [ "$l1" -gt 1 ] && [ "$(sed -n "$((l1-1))p" <<<"$b" | tr -d ' ')" = 'java.util.HashMap<String,java.util.ArrayList<String>>oldByPkg=' ] \
    || { echo "FAIL r8: oldByPkg is not PermsCaptureRule.oldLinesByPkg(SettingsText.read(... nowhere-perms))"; return 1; }
  l2=$(lineof 'if (oldByPkg == null) {' "$b")
  [ "$l2" -gt "$l1" ] || { echo "FAIL r8: capturePerms does not test oldByPkg == null after the read"; return 1; }
  l3=$(awk -v s="$l2" 'NR>s && NR<=s+4 && /^ *return; *$/ { print NR; exit } NR>s && /^ *\} *$/ { exit }' <<<"$b")
  [ -n "$l3" ] && [ "$(lineof 'pm.queryIntentActivities(' "$b")" -gt "$l3" ] \
    && [ "$(lineof 'StoreInstaller.writeAtomic(' "$b")" -gt "$l3" ] \
    || { echo "FAIL r8: a null oldByPkg does not return before pm.queryIntentActivities and StoreInstaller.writeAtomic"; return 1; }
  n=$(grep -cE 'FileReader\(.*nowhere-perms' <<<"$b")
  [ "$n" = 0 ] || { echo "FAIL r8: capturePerms still opens nowhere-perms with a FileReader $n time(s)"; return 1; }
  echo "  ok   r8 an unreadable nowhere-perms returns before anything is enumerated or written"
  # (r9) no caller hands capturePerms a lenient keep-set read
  ps=$(sed 's#//.*$##' "$pa")
  n=$(grep -cE 'capturePerms\(.*readAppModes(\(\)|In\()' <<<"$ps")
  [ "$n" = 0 ] || { echo "FAIL r9: ProfileActivity passes capturePerms a lenient keep-set read $n time(s)"; return 1; }
  n=$(grep -cE 'capturePerms\(.*readAppModes(\(\)|In\()' <<<"$rs")
  [ "$n" = 0 ] || { echo "FAIL r9: PermsCaptureReceiver passes capturePerms a lenient keep-set read $n time(s)"; return 1; }
  echo "  ok   r9 neither caller passes readAppModes() or readAppModesIn("
}
check "$RULE" "$PA" "$RCV" "$MAN" || { echo "FAILED"; exit 1; }
echo "== all checks pass"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <rule|pa|rcv|man> <perl-expr> <text the failure must contain>
  local d f orig rule pa rcv man out rc
  d=$(mktemp -d -p "$W"); rule=$RULE; pa=$PA; rcv=$RCV; man=$MAN
  case "$2" in
    rule) orig=$RULE; f="$d/PermsCaptureRule.java"; rule=$f ;;
    pa)   orig=$PA;   f="$d/ProfileActivity.java";  pa=$f ;;
    rcv)  orig=$RCV;  f="$d/PermsCaptureReceiver.java"; rcv=$f ;;
    man)  orig=$MAN;  f="$d/AndroidManifest.xml";   man=$f ;;
    *) echo "  ERROR     $1 -- unknown target $2"; return 1 ;;
  esac
  cp "$orig" "$f"
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed"; return 1; fi
  if cmp -s "$orig" "$f"; then echo "  INERT     $1"; return 1; fi
  out=$(check "$rule" "$pa" "$rcv" "$man" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if [ "$rc" -ne 1 ]; then echo "  BROKEN    $1 -- rc=$rc (did not compile)"; return 1; fi
  case "$out" in *"$4"*) ;; *) echo "  BROKEN    $1 -- it failed, but not with '$4'"; return 1 ;; esac
  echo "  convicted $1"
}
fails=0
mut "M1 keepCarried ignores restored" rule 's/ && !restored;/;/' "FAIL mid-session, ondemand, restored" || fails=$((fails+1))
mut "M2 keepCarried ignores midSession" rule 's/return midSession && /return /' "FAIL sign-out, ondemand" || fails=$((fails+1))
mut "M3 the keepCarried skip removed from capturePerms" pa 's/\n *\/\/ NWP-20261112-07: mid-session, a deferred app[^\n]*\n[^\n]*\n *if \(PermsCaptureRule\.keepCarried\([^\n]*\n *held\.add\(pkg\);\n *continue;\n *\}//' "FAIL r3" || fails=$((fails+1))
mut "M4 a bare getFilesDir() left in capturePerms" pa 's/SettingsText\.read\(new java\.io\.File\(ctx\.getFilesDir\(\), "nowhere-perms"\)\)/SettingsText.read(new java.io.File(getFilesDir(), "nowhere-perms"))/' "FAIL r1" || fails=$((fails+1))
mut "M5 the synchronized block removed" pa 's/^        synchronized \(PERMS_CAPTURE_LOCK\) \{$/        {/m' "FAIL r2" || fails=$((fails+1))
mut "M6 the receiver's user-0 return removed" rcv 's/^ *if \(android\.os\.UserHandle\.myUserId\(\) == 0\) return;[^\n]*\n//m' "FAIL r5" || fails=$((fails+1))
mut "M7 doLogoff passes midSession true" pa 's/capturePerms\(this, readAppModesStrictIn\(getFilesDir\(\)\), false\);/capturePerms(this, readAppModesStrictIn(getFilesDir()), true);/' "FAIL r4" || fails=$((fails+1))
mut "M8 the receiver exported" man 's/(<receiver android:name="\.PermsCaptureReceiver" android:exported=)"false"/$1"true"/' "FAIL r6" || fails=$((fails+1))
mut "M9 a held package's old lines softened in the carry-forward" pa 's/(if \(held\.contains\(pkg\)\) \{[^\n]*\n *for \(String ln : old\) )sb\.append\(ln\)/$1sb.append(PermDeclines.softenedDecline(ln, pkg))/' "FAIL r3" || fails=$((fails+1))
mut "M10 oldLinesByPkg reads null as empty" rule 's/if \(text == null\) return null;/if (text == null) return new java.util.HashMap<>();/' "FAIL oldLinesByPkg(null)" || fails=$((fails+1))
mut "M11 the keep-set null guard removed" pa 's/\n *if \(keptModes == null\) \{.*?\n *return;\n *\}//s' "FAIL r7" || fails=$((fails+1))
mut "M12 the nowhere-perms null guard removed" pa 's/\n *if \(oldByPkg == null\) \{.*?\n *return;\n *\}//s' "FAIL r8" || fails=$((fails+1))
mut "M13 the receiver back on readAppModesIn" rcv 's/ProfileActivity\.readAppModesStrictIn\(app\.getFilesDir\(\)\)/ProfileActivity.readAppModesIn(app.getFilesDir())/' "FAIL r5" || fails=$((fails+1))
mut "M14 doLogoff back on readAppModes()" pa 's/capturePerms\(this, readAppModesStrictIn\(getFilesDir\(\)\), false\);/capturePerms(this, readAppModes(), false);/' "FAIL r4" || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
