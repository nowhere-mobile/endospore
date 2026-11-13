#!/usr/bin/env bash
# test-od-data-barrier-java.sh [--mutate] -- the chooser's launch barrier (NWP-20261130-03, 2b, maintainer decision
# 2026-11-08: "chooser change to block the app until data lands"). A package installed by any path while its data is
# still out (Play, Aurora, a sideload, a nApps Get waiting for RESTORE-ODDATA) is suspended at its package-added event and
# released only after the fetch has landed.
#
# WHAT RUNS. OdDataBarrier.java compiles under javac alone with tests/od-data-barrier/OdDataBarrierCases.java, and the
# hook points in AppInstallReceiver, UnarchiveService, NowhereApp, AppClaim, OdDataBarrierHost, OdDataInstallWatch (RF-013:
# the user-0 watcher, for an install with no session chooser process), OdDataAddedReceiver and the manifest are pinned
# by grep, because they need the Android tree to compile. RF-012: OdDataBarrierBothOwners.java runs the real barrier
# against the real roamd helpers (od_block_app, od_chooser_holds, od_unblock_app, the odrestore reply) under every shell
# found, with one owner list behind a `pm` that prints the state of ALL suspenders, as the platform does.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (exit 2), like the other javac suites.
#
#   bash test-od-data-barrier-java.sh            # the cases
#   bash test-od-data-barrier-java.sh --mutate   # ... plus broken copies that must each be CONVICTED by the named check
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/src/com/nowhere/chooser"
CASES="$HERE/tests/od-data-barrier/OdDataBarrierCases.java"
BOTH="$HERE/tests/od-data-barrier/OdDataBarrierBothOwners.java"
ROAMD="$HERE/../vendor-common/bin/nowhere_roamd.sh"
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip." >&2
  exit 2
fi

# The one temp root: every class dir and mutant lives inside it, and the EXIT trap removes it on every path.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

# cases <OdDataBarrier.java> -> prints the case lines; 0 all passed, 1 a case failed, 3 no compile
cases() {
  local src="$1" d
  d=$(mktemp -d -p "$W") || return 2
  "$JAVAC" -nowarn -Xlint:none -d "$d" "$src" "$CASES" >"$d/javac.out" 2>&1 || { sed -n 1,10p "$d/javac.out"; return 3; }
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d" com.nowhere.chooser.OdDataBarrierCases
}

SHELLS=""
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "FAIL: no shell to run the roamd helpers under" >&2; exit 2; }

anchor_of() { awk -v a="$2" 'index($0, a) == 1 {f=1} f{print} f&&/^\}$/{exit}' "$1"; }

# roamd_lib <roamd.sh> <dir>: writes <dir>/lib.sh, the real helpers re-rooted into <dir>. 2 when one cannot be extracted.
roamd_lib() {
  local sut="$1" t="$2" fn body
  mkdir -p "$t/state/odfetch.12" "$t/user" || return 2
  : > "$t/state/odfetch.12/unfetched.ce"; : > "$t/state/odfetch.12/unfetched.de"
  {
    echo 'LOG="$D/log"; RES="$D/res"; STATE="$D/state"; uid=12; USERDIR="$D/user"'
    echo 'chmod() { :; }; am() { :; }; timeout() { shift 3; "$@"; }'
    # one suspension list: `pm` changes root's entry only and prints the state of all owners
    echo 'pm() { case "$1" in suspend) grep -qx root "$D/owners" || echo root >> "$D/owners" ;; unsuspend) grep -vx root "$D/owners" > "$D/owners.t"; mv -f "$D/owners.t" "$D/owners" ;; esac; if [ -s "$D/owners" ]; then echo "Package $4 new suspended state: true"; else echo "Package $4 new suspended state: false"; fi; return 0; }'
    for fn in od_pending_path od_pending_clear od_chooser_holds od_block_app od_unblock_app; do
      body=$(anchor_of "$sut" "$fn() {")
      [ -n "$body" ] || { echo "EXTRACTION FAILED: $fn" >&2; return 2; }
      printf '%s\n' "$body" | sed 's|/data/user/$uid/|$USERDIR/|'
    done
    echo 'run_reply() { odsrc="$1"; odkept="$2"; pkg="$3"'
    body=$(awk '/^    if \[ "\$odsrc" = 0 \]; then$/{f=1} f{print} f&&/^    fi$/{exit}' "$sut")
    [ -n "$body" ] || { echo "EXTRACTION FAILED: the odrestore reply" >&2; return 2; }
    printf '%s\n' "$body"
    echo '}'
  } > "$t/lib.sh" || return 2
}

# both <OdDataBarrier.java> <roamd.sh> -> prints the case lines; 0 all passed, 1 a case failed, 2 no extraction, 3 no compile
both() {
  local src="$1" sut="$2" d sh t rc=0 r
  d=$(mktemp -d -p "$W") || return 2
  "$JAVAC" -nowarn -Xlint:none -d "$d" "$src" "$BOTH" >"$d/javac.out" 2>&1 || { sed -n 1,10p "$d/javac.out"; return 3; }
  for sh in $SHELLS; do
    t=$(mktemp -d -p "$W") || return 2
    roamd_lib "$sut" "$t" || return 2
    "$JAVA" -Djava.io.tmpdir="$W" -cp "$d" com.nowhere.chooser.OdDataBarrierBothOwners "$sh" "$t"; r=$?
    [ "$r" -eq 0 ] || rc=1
  done
  return "$rc"
}

# pins <src dir> <manifest> -> prints "  FAIL  P<n>" for each broken hook; 0 when all hold
pins() {
  local dir="$1" mf="$2" rc=0
  python3 - "$dir" "$mf" "$ROAMD" <<'PY' || rc=$?
import re,sys
d,mf,roamd=sys.argv[1:]
rd=lambda n:open(d+'/'+n,encoding='utf-8').read()
ok=True
def chk(name,cond):
    global ok
    print(('  ok    ' if cond else '  FAIL  ')+name)
    ok=ok and cond
r=rd('AppInstallReceiver.java')
i=r.find('OdDataBarrierHost.onPackageAdded(context, pkg);')
chk('P1 the hook runs at the package-added event, before decide and the heal', i>0 and i<r.find('decide(context, pkg, replacing, "broadcast");') and i<r.find('heal(context, pkg, replacing);') and i>r.find('ACTION_PACKAGE_ADDED.equals'))
chk('P2 the heal reports a non-OK reply to the barrier', re.search(r'if \(r\.startsWith\("OK"\)\) UnarchiveService\.markOdRestored\(context, pkg\);\s*else OdDataBarrierHost\.afterReply\(context, pkg, r\);',r) is not None)
u=rd('UnarchiveService.java')
m=u[u.find('static void markOdRestored('):]; m=m[:m.find('\n    }\n')]
chk('P3 a confirmed restore releases the barrier before the marker holders act', 'OdDataBarrierHost.afterReply(ctx, pkg, "OK");' in m and m.find('OdDataBarrierHost')<m.find('SmsRoleRoam.onMaterialised'))
chk('P4 the process birth reconciles', 'OdDataBarrierHost.reconcile(this)' in rd('NowhereApp.java'))
a=rd('AppClaim.java')
chk('P5 a claim release leaves a barrier hold alone', 'set(ctx, userId, OdDataBarrierHost.withoutHeld(ctx, pkgs), false, null)' in a)
h=rd('OdDataBarrierHost.java')
chk('P6 the question is OD-DATA-PENDING', '"OD-DATA-PENDING\\n" + pkg' in h)
chk('P7 the host suspends through PackageManager with a dialog', 'setPackagesSuspended(new String[] {pkg}, true, null, null, b.build())' in h and 'setNeutralButtonText("Try again")' in h)
mt=open(mf,encoding='utf-8').read()
e=re.search(r'<activity android:name="\.OdDataRetryActivity".*?</activity>',mt,re.S)
chk('P8 the retry activity needs the suspended-details permission and takes its action', e is not None and 'SEND_SHOW_SUSPENDED_APP_DETAILS' in e.group(0) and 'android.intent.action.SHOW_SUSPENDED_APP_DETAILS' in e.group(0))
m=re.search(r'MARK_DIR = "([^"]+)"',h)
chk('P9 roamd reads the mark where the host writes it', m is not None and ('/com.nowhere.chooser/files/'+m.group(1)+'/$1') in open(roamd,encoding='utf-8').read())
c=h[h.find('public void confirm('):]; c=c[:c.find('\n    }\n')]
chk('P10 the confirmed mark is not empty', "out.write('1');" in c)
w=rd('OdDataInstallWatch.java')
chk('P11 the persistent process registers the watcher', 'OdDataInstallWatch.register(this);' in rd('NowhereApp.java'))
chk('P12 the watcher runs in user 0 only', 'if (UserHandle.myUserId() != 0) return;' in w[w.find('static void register('):])
chk('P13 the watcher hears every user', w.count('registerReceiverForAllUsers(')==2 and 'new IntentFilter(Intent.ACTION_PACKAGE_ADDED)' in w and 'addDataScheme("package")' in w)
chk('P14 the relay is explicit and names the package', 'new Intent(app, OdDataAddedReceiver.class).setData(Uri.fromParts("package", pkg, null))' in w)
chk('P15 the relay reaches a stopped chooser in that user', 'FLAG_INCLUDE_STOPPED_PACKAGES' in w and re.search(r'sendBroadcastAsUser\(.*UserHandle\.of\(user\)\);',w) is not None)
chk('P16 the watcher takes the rule its event and the sender', 'w.rule.onAdded(w, getSendingUserId(),' in w and 'w.rule.onUserChange(w);' in w)
e=re.search(r'<receiver android:name="\.OdDataAddedReceiver"[^>]*/>',mt)
chk('P17 the session receiver is in the manifest, reached only by name', e is not None and 'android:exported="false"' in e.group(0))
ar=rd('OdDataAddedReceiver.java')
chk('P18 the session receiver holds a named app', 'OdDataBarrierHost.onRelayedAdd(app, pkg);' in ar and 'goAsync()' in ar)
chk('P19 the session receiver reconciles when no app is named', 'OdDataBarrierHost.reconcile(app)' in ar)
ora=h[h.find('static void onRelayedAdd('):]; ora=ora[:ora.find('\n    }\n')]
chk('P20 the relayed path holds through the barrier, then the retry', 'OdDataBarrier.onRelayed(new OdDataBarrierHost(ctx), pkg, p -> retry(ctx, p));' in ora and 'launchable(ctx, pkg)' in ora)
sys.exit(0 if ok else 1)
PY
  return "$rc"
}

fails=0
echo "== cases"
out=$(cases "$SRC/OdDataBarrier.java"); rc=$?
printf '%s\n' "$out"
[ "$rc" -eq 0 ] || { echo "FAILED (rc=$rc)"; exit 1; }
echo "== pins"
out=$(pins "$SRC" "$HERE/AndroidManifest.xml"); rc=$?
printf '%s\n' "$out"
[ "$rc" -eq 0 ] || { echo "FAILED (rc=$rc)"; exit 1; }
echo "== both owners, real barrier and real roamd helpers (RF-012)"
out=$(both "$SRC/OdDataBarrier.java" "$ROAMD"); rc=$?
printf '%s\n' "$out"
[ "$rc" -eq 0 ] || { echo "FAILED (rc=$rc)"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by its named check; one that does not apply or compile is a failure)"

# mcase <label> <want> <perl-expr>: mutate a copy of OdDataBarrier.java, the case named <want> must FAIL
mcase() {
  local label="$1" want="$2" expr="$3" m o rc
  m=$(mktemp -d -p "$W") || return 2
  cp "$SRC/OdDataBarrier.java" "$m/OdDataBarrier.java"
  perl -0pi -e "$expr" "$m/OdDataBarrier.java"
  if cmp -s "$SRC/OdDataBarrier.java" "$m/OdDataBarrier.java"; then echo "  INERT     $label"; fails=$((fails+1)); return; fi
  o=$(cases "$m/OdDataBarrier.java"); rc=$?
  if [ "$rc" -eq 3 ]; then echo "  NOCOMPILE $label"; fails=$((fails+1)); return; fi
  if [[ "$o" == *"FAIL  $want"* ]]; then echo "  convicted $label: $want"; else echo "  SURVIVED  $label (rc=$rc)"; fails=$((fails+1)); fi
}

# mpin <label> <want> <file relative to the src dir, or AndroidManifest.xml> <perl-expr>: a mutated copy of the file must fail pin <want>
mpin() {
  local label="$1" want="$2" file="$3" expr="$4" m t o rc
  m=$(mktemp -d -p "$W") || return 2
  cp "$SRC"/*.java "$m/"; cp "$HERE/AndroidManifest.xml" "$m/AndroidManifest.xml"
  t="$m/$file"
  perl -0pi -e "$expr" "$t"
  if cmp -s "$t" "$( [ "$file" = AndroidManifest.xml ] && echo "$HERE/AndroidManifest.xml" || echo "$SRC/$file" )"; then echo "  INERT     $label"; fails=$((fails+1)); return; fi
  o=$(pins "$m" "$m/AndroidManifest.xml"); rc=$?
  if [ "$rc" -ne 0 ] && [[ "$o" == *"FAIL  $want"* ]]; then echo "  convicted $label: $want"; else echo "  SURVIVED  $label (rc=$rc)"; fails=$((fails+1)); fi
}

mcase "B1 the hook does not suspend" "C1 listed: suspended" 's/if \(!s\.suspend\(pkg, false\)\) \{\n            s\.unmark\(pkg\);/if (false) {\n            s.unmark(pkg);/'
mcase "B2 it unsuspends before the fetch lands" "C4 OK but still out: suspended" 's/if \(!dataOut\(s\.ask\(pkg\)\)\) release\(s, pkg\);\n            else s\.log/release(s, pkg);\n            if (false) s.log/'
mcase "B3 it unsuspends on a failed fetch" "C5 failed fetch: suspended" 's/if \(FAILED\.add\(pkg\)\) \{\n                s\.suspend\(pkg, true\);/if (FAILED.add(pkg)) {\n                release(s, pkg);/'
mcase "B4 a busy reply releases" "C6 reply [ERR-WORKER-BUSY]: suspended" 's/if \(r\.startsWith\("OK"\)\) \{\n            if \(!dataOut\(s\.ask\(pkg\)\)\) release\(s, pkg\);/if (true) {\n            release(s, pkg); if (false) release(s, pkg);/'
mcase "B5 every package is suspended" "C2 unlisted: no suspend call" 's/static boolean dataOut\(String reply\) \{\n        return [^\n]*\n/static boolean dataOut(String reply) {\n        return true;\n/'
mcase "B6 no answer counts as data back" "C7 answer []: held" 's/return !"NO"\.equals\(reply == null \? "" : reply\.trim\(\)\);/return !"NO".equals(reply == null ? "" : reply.trim()) \&\& !"".equals(reply == null ? "" : reply.trim());/'
mcase "B7 no question after the suspension" "C8 race: suspension lifted" 's/if \(!dataOut\(s\.ask\(pkg\)\)\) \{\n            release\(s, pkg\);\n            return false;\n        \}/if (false) { release(s, pkg); return false; }/'
mcase "B8 a failed fetch logs every time" "C5 failed fetch: logged once" 's/if \(FAILED\.add\(pkg\)\) \{/if (true) {/'
mcase "B9 a claim is lifted with the barrier" "C10 claimed: no unsuspend" 's/if \(s\.claimedElsewhere\(pkg\)\) \{/if (false) {/'
mcase "B10 reconcile drops the missed install" "C13 the install the dead process missed: held" 's/if \(onAdded\(s, p\)\) retry\.accept\(p\);/if (false) retry.accept(p);/'
mcase "B11 a refused suspension still counts as a hold" "C9 refused: no mark" 's/if \(!s\.suspend\(pkg, false\)\) \{\n            s\.unmark\(pkg\);\n/if (!s.suspend(pkg, false)) {\n/'
mcase "B12 a refused release loses the mark" "C11 refused release: mark kept" 's/if \(s\.unsuspend\(pkg\)\) \{\n            s\.unmark\(pkg\);/s.unsuspend(pkg); if (true) {\n            s.unmark(pkg);/'
mcase "B13 the hold is never confirmed" "C1 listed: confirmed after the suspension" 's/        s\.confirm\(pkg\);\n//'
mcase "B14 the mark is confirmed before the suspension" "C9 refused: not confirmed" 's/s\.mark\(pkg\);\n        if \(!s\.suspend/s.mark(pkg); s.confirm(pkg);\n        if (!s.suspend/'
mcase "B15 reconcile does not confirm" "C13 the two holds confirmed" 's/if \(s\.suspend\(m, false\)\) s\.confirm\(m\);\n\s*else /if (!s.suspend(m, false)) /'
mcase "W1 the watcher relays nothing" "W1 process absent: relayed once" 's/if \(user == p\.currentUser\(\) \&\& p\.unlocked\(user\)\) p\.relay\(user, pkg\);/if (false) p.relay(user, pkg);/'
mcase "W2 the relayed path does not suspend" "W1 process absent: suspended" 's/if \(onAdded\(s, pkg\)\) retry\.accept\(pkg\);\n    \}\n\n    \/\*\* A RESTORE/retry.accept(pkg);\n    }\n\n    \/** A RESTORE/'
mcase "W3 the relayed path asks for no restore" "W1 process absent: the restore is asked for" 's/if \(onAdded\(s, pkg\)\) retry\.accept\(pkg\);\n    \}\n\n    \/\*\* A RESTORE/onAdded(s, pkg);\n    }\n\n    \/** A RESTORE/'
mcase "W4 the restore is asked for before the hold" "W1 process absent: the hold stands before the restore" 's/if \(onAdded\(s, pkg\)\) retry\.accept\(pkg\);\n    \}\n\n    \/\*\* A RESTORE/retry.accept(pkg); onAdded(s, pkg);\n    }\n\n    \/** A RESTORE/'
mcase "W5 a data-home app still asks for a restore" "W2 unlisted: no restore asked for" 's/if \(onAdded\(s, pkg\)\) retry\.accept\(pkg\);\n    \}\n\n    \/\*\* A RESTORE/onAdded(s, pkg); retry.accept(pkg);\n    }\n\n    \/** A RESTORE/'
mcase "W6 user 0 is relayed" "W3 user 0: no relay" 's/if \(user <= 0 \|\| pkg == null/if (pkg == null/'
mcase "W7 the chooser itself is relayed" "W3 the chooser itself: no relay" 's/ \|\| pkg\.equals\(self\)\) return;/) return;/'
mcase "W8 an event for a non-current session relays" "W4 not current: no relay" 's/if \(user == p\.currentUser\(\) \&\& p\.unlocked\(user\)\) p\.relay/if (p.unlocked(user)) p.relay/'
mcase "W9 a locked session relays" "W5 locked: no relay" 's/if \(user == p\.currentUser\(\) \&\& p\.unlocked\(user\)\) p\.relay/if (user == p.currentUser()) p.relay/'
mcase "W10 a waiting event is forgotten" "W4 the switch: one sweep" 's/else waiting = user;/else waiting = -1;/'
mcase "W11 the sweep repeats" "W4 the next change: no second sweep" 's/p\.sweep\(waiting\);\n            waiting = -1;/p.sweep(waiting);/'
mcase "W12 the sweep does not wait for the switch" "W4 still not current: no sweep" 's/if \(waiting <= 0 \|\| waiting != p\.currentUser\(\) \|\| !p\.unlocked\(waiting\)\) return;/if (waiting <= 0 || !p.unlocked(waiting)) return;/'
mcase "W13 the sweep does not wait for the unlock" "W5 still locked: no sweep" 's/if \(waiting <= 0 \|\| waiting != p\.currentUser\(\) \|\| !p\.unlocked\(waiting\)\) return;/if (waiting <= 0 || waiting != p.currentUser()) return;/'
mpin "H1 the hook is gone" "P1 the hook runs" AppInstallReceiver.java 's/OdDataBarrierHost\.onPackageAdded\(context, pkg\);//'
mpin "H2 the hook runs after decide" "P1 the hook runs" AppInstallReceiver.java 's/OdDataBarrierHost\.onPackageAdded\(context, pkg\);\n\s*decide\(context, pkg, replacing, "broadcast"\);/decide(context, pkg, replacing, "broadcast");\n                OdDataBarrierHost.onPackageAdded(context, pkg);/'
mpin "H3 a failed heal does not reach the barrier" "P2 the heal reports" AppInstallReceiver.java 's/\n\s*else OdDataBarrierHost\.afterReply\(context, pkg, r\);[^\n]*//'
mpin "H4 the marker writer does not release" "P3 a confirmed restore" UnarchiveService.java 's/OdDataBarrierHost\.afterReply\(ctx, pkg, "OK"\);//'
mpin "H5 no reconcile at the process birth" "P4 the process birth" NowhereApp.java 's/OdDataBarrierHost\.reconcile\(this\)/OdDataBarrierHost.class.getName()/'
mpin "H6 a claim release lifts a barrier hold" "P5 a claim release" AppClaim.java 's/OdDataBarrierHost\.withoutHeld\(ctx, pkgs\)/pkgs/'
mpin "H7 the verb is misnamed" "P6 the question" OdDataBarrierHost.java 's/OD-DATA-PENDING/OD-PENDING/'
mpin "H8 the dialog has no retry button" "P7 the host suspends" OdDataBarrierHost.java 's/\.setNeutralButtonText\("Try again"\)//'
mpin "H9 the retry activity is open to any caller" "P8 the retry activity" AndroidManifest.xml 's/android:permission="android\.permission\.SEND_SHOW_SUSPENDED_APP_DETAILS"//'
mpin "H10 the host writes its marks where roamd does not read" "P9 roamd reads the mark" OdDataBarrierHost.java 's/MARK_DIR = "nowhere-odbarrier"/MARK_DIR = "nowhere-odhold"/'
mpin "H11 the confirmed mark stays empty" "P10 the confirmed mark" OdDataBarrierHost.java "s/out\.write\('1'\);//"
mpin "R1 the watcher is never registered" "P11 the persistent process" NowhereApp.java 's/OdDataInstallWatch\.register\(this\);//'
mpin "R2 the watcher runs in every user" "P12 the watcher runs" OdDataInstallWatch.java 's/if \(UserHandle\.myUserId\(\) != 0\) return;//'
mpin "R3 the watcher hears user 0 alone" "P13 the watcher hears" OdDataInstallWatch.java 's/app\.registerReceiverForAllUsers\(new BroadcastReceiver\(\) \{/app.registerReceiver(new BroadcastReceiver() {/'
mpin "R4 the watcher does not filter on package" "P13 the watcher hears" OdDataInstallWatch.java 's/added\.addDataScheme\("package"\);//'
mpin "R5 the relay is implicit" "P14 the relay is explicit" OdDataInstallWatch.java 's/new Intent\(app, OdDataAddedReceiver\.class\)\.setData/new Intent("nowhere.od.added").setData/'
mpin "R6 the relay skips a stopped chooser" "P15 the relay reaches" OdDataInstallWatch.java 's/Intent\.FLAG_INCLUDE_STOPPED_PACKAGES \| //'
mpin "R7 the relay goes to the wrong user" "P15 the relay reaches" OdDataInstallWatch.java 's/UserHandle\.of\(user\)\);\n    \}\n\}/UserHandle.SYSTEM);\n    }\n}/'
mpin "R8 the receiver hears nothing from the rule" "P16 the watcher takes" OdDataInstallWatch.java 's/w\.rule\.onAdded\(w, getSendingUserId\(\),/w.rule.onAdded(w, 0,/'
mpin "R9 no session receiver in the manifest" "P17 the session receiver" AndroidManifest.xml 's/<receiver android:name="\.OdDataAddedReceiver"[^>]*\/>//'
mpin "R10 the session receiver is exported" "P17 the session receiver" AndroidManifest.xml 's/(<receiver android:name="\.OdDataAddedReceiver" android:exported=)"false"/$1"true"/'
mpin "R11 the receiver does not hold the app" "P18 the session receiver" OdDataAddedReceiver.java 's/OdDataBarrierHost\.onRelayedAdd\(app, pkg\);//'
mpin "R12 the sweep does not reconcile" "P19 the session receiver" OdDataAddedReceiver.java 's/OdDataBarrierHost\.reconcile\(app\)/app.getPackageName()/'
mpin "R13 the relayed path skips the barrier" "P20 the relayed path" OdDataBarrierHost.java 's/OdDataBarrier\.onRelayed\(new OdDataBarrierHost\(ctx\), pkg, p -> retry\(ctx, p\)\);/retry(ctx, pkg);/'

# mboth <label> <want> <sed-expr on a copy of nowhere_roamd.sh>: the both-owners case named <want> must FAIL
mboth() {
  local label="$1" want="$2" expr="$3" m o rc
  m=$(mktemp -p "$W") || return 2
  sed "$expr" "$ROAMD" > "$m"
  if cmp -s "$ROAMD" "$m"; then echo "  INERT     $label"; fails=$((fails+1)); return; fi
  o=$(both "$SRC/OdDataBarrier.java" "$m"); rc=$?
  if [ "$rc" -eq 1 ] && [[ "$o" == *"FAIL  $want"* ]]; then echo "  convicted $label: $want"; else echo "  SURVIVED  $label (rc=$rc)"; fails=$((fails+1)); fi
}
mboth "O1 another owner's hold counts as root's block still on (the RF-012 deadlock)" "S1 root and chooser: OK reply" 's/\*"new suspended state: "\*) _ok=1/*"new suspended state: false"*) _ok=1/'
mboth "O2 root's unsuspend is never sent" "S1 root and chooser: root's suspension removed" 's/pm unsuspend --user/pm nounsuspend --user/'
mboth "O3 root suspends over a confirmed chooser hold" "S2 chooser first: no second suspension" 's/^  if od_chooser_holds "\$pkg"; then$/  if false; then/'
mboth "O4 a kept hold answers OK" "S3 kept hold: ERR-NOTREADY" 's/^      echo "ERR-NOTREADY" > "\$RES"$/      echo "OK $pkg" > "$RES"/'

[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
