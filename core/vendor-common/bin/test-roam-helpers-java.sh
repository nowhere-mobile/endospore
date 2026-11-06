#!/usr/bin/env bash
# test-roam-helpers-java.sh [--mutate] -- NWP-20261010-15: roamd's two app_process helpers (np.SyncRoam, np.VpnAlwaysOn)
# and the chooser's VPN-picker decisions, compiled and EXECUTED (editions/endospore/tests/roam-helpers). The fakes refuse
# what GrapheneOS refuses -- a root caller's per-account sync switch, an authority with no adapter package -- silently,
# as the framework does, so a helper that makes its calls as root or re-reads a switch it cannot see fails here and not
# on a phone. roamd's half is test-sync-vpn-roam.sh.
#
# It needs a JDK, and it FAILS when there is none: a Java suite that skips without one would read green on a runner
# that never ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
#   bash test-roam-helpers-java.sh            # the cases
#   bash test-roam-helpers-java.sh --mutate   # ... plus mutants of the real sources, each of which must FAIL the cases
#
# mutant <label> <sync|vpn|pa|roamd> <sed> [<anchor> <conviction>]: the kind names the source mutated (roamd = roamd's
# own vpn_choice, run.sh's pin). With an anchor the line must occur exactly once in that source, and with a conviction
# the run must fail ON THAT CASE (pa/sync/vpn: its "FAIL <case>" line; roamd: its "[<shell>] vpn_choice read <pin>" line
# under every shell run.sh found), so a mutant that merely fails to compile or extract is a failure, not a conviction.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-roam-helpers-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT
export JAVAC JAVA TMPDIR="$W"
RUN="$ROOT/editions/endospore/tests/roam-helpers/run.sh"
H="$ROOT/editions/endospore/vendor/helpers/np"
SYNC="$H/SyncRoam.java"; VPN="$H/VpnAlwaysOn.java"
PA="$ROOT/core/chooser/src/com/nowhere/chooser/ProfileActivity.java"; ROAMD="$ROOT/core/vendor-common/bin/nowhere_roamd.sh"

echo "== as committed =="
bash "$RUN" "$SYNC" "$VPN" "$PA" "$ROAMD"
[ "${1:-}" = --mutate ] || exit 0

echo; echo "== mutants (each MUST fail the cases) =="
M=$(mktemp -d -p "$W")
rc=0
# mutant <label> <sync|vpn|pa|roamd> <sed program> [<anchor> <conviction>]. A sed that changes nothing is NOT a
# conviction. Given an anchor (a fixed string), it must occur exactly once in the source; given a conviction, the run
# must exit non-zero AND name it (see the header).
mutant() {
  local l="$1" w="$2" prog="$3" anchor="${4:-}" conv="${5:-}" src s v p r n sh ok=1
  case "$w" in sync) src=$SYNC ;; vpn) src=$VPN ;; pa) src=$PA ;; roamd) src=$ROAMD ;; esac
  if [ -n "$anchor" ]; then
    n=$(grep -cF -- "$anchor" "$src" || true)
    if [ "$n" != 1 ]; then echo "  ⚠ ANCHOR x$n  $l"; rc=1; return; fi
  fi
  sed "$prog" "$src" > "$M/mut" 2>/dev/null || true
  if [ ! -s "$M/mut" ] || cmp -s "$M/mut" "$src"; then echo "  ⚠ NOT APPLIED  $l"; rc=1; return; fi
  s=$SYNC; v=$VPN; p=$PA; r=$ROAMD
  case "$w" in sync) s=$M/mut ;; vpn) v=$M/mut ;; pa) p=$M/mut ;; roamd) r=$M/mut ;; esac
  if bash "$RUN" "$s" "$v" "$p" "$r" > "$M/out" 2>&1; then echo "  ⚠ SURVIVED  $l"; rc=1; return; fi
  [ -n "$conv" ] || { echo "  convicted   $l"; return; }
  if [ "$w" = roamd ]; then
    for sh in bash dash mksh; do
      command -v "$sh" >/dev/null 2>&1 || continue
      if grep -qF -- "FAIL  [$sh] vpn_choice read $conv " "$M/out"; then echo "  convicted   $l [$sh]"
      else echo "  ⚠ SURVIVED  $l [$sh]"; ok=0; fi
    done
  elif grep -qF -- "FAIL $conv" "$M/out"; then echo "  convicted   $l"
  else ok=0; fi
  [ "$ok" = 1 ] || { echo "  ⚠ BROKEN  $l (not convicted by $conv)"; rc=1; }
}
mutant "H1: the helper makes its binder calls as root (no drop, no relaunch)" sync \
  's/^        if (Os.getuid() == 0) {$/        if (false) {/'
mutant "H1: it changes its gid but keeps uid 0" sync \
  's/^            Os.setuid(SYSTEM_UID);$/            Os.setgid(SYSTEM_UID);/'
mutant "H2: capture re-reads a switch whose adapter package is absent" sync \
  's/^            if (have.contains(p.acct()) \&\& s.hasAdapter(p.authority)) {$/            if (have.contains(p.acct())) {/'
mutant "M1: capture re-reads a switch whose account is invisible" sync \
  's/^            if (have.contains(p.acct()) \&\& s.hasAdapter(p.authority)) {$/            if (s.hasAdapter(p.authority)) {/'
mutant "H2: apply sets a switch whose adapter package is absent" sync \
  's/^            if (!have.contains(r.acct()) || !s.hasAdapter(r.authority)) {$/            if (!have.contains(r.acct())) {/'
mutant "a pend line is re-read at capture instead of carried" sync \
  's/^        for (Row p : in.pending) {$/        for (Row p : new ArrayList<Row>()) {/'
mutant "apply skips the read-back" sync \
  's/^                if (s.get(r.name, r.type, r.authority) == r.on) {$/                if (true) {/'
mutant "apply never sets master" sync \
  's/^        if (p.master != null) {$/        if (false) {/'
mutant "an error prints the exception itself (its message names the account)" sync \
  's/^        return "ERR " + c.getClass().getSimpleName();$/        return "ERR " + c;/'
mutant "the pend lines are not printed" sync \
  's/^            b.append("pend ").*$/            b.append("");/'
mutant "J1: the dropped process does the work itself, on the binder it opened as root" sync \
  's/^            return relaunch.run(a);$/            return run(a, in, out, null);/'
mutant "J2: the child is waited for without a bound" sync \
  's/^        if (!p.waitFor(RELAUNCH_TIMEOUT_S, TimeUnit.SECONDS)) {$/        if (p.waitFor() < 0) {/'
mutant "J3: the arguments are not passed to the child" sync \
  '/^        cmd.addAll(Arrays.asList(a));$/d'
mutant "J4: the child does not inherit stdin/stdout" sync \
  's/starter.start(new ProcessBuilder(cmd).inheritIO())/starter.start(new ProcessBuilder(cmd))/'
mutant "J5: setuid before setgid (the gid change then fails)" sync \
  's/^            Os.setgid(SYSTEM_UID);$/            Os.setuid(SYSTEM_UID); Os.setgid(SYSTEM_UID);/; /^            Os.setuid(SYSTEM_UID);$/d'
mutant "F10: the relaunch bound is no shorter than roamd's timeout" sync \
  's/^    static final long RELAUNCH_TIMEOUT_S = 12;$/    static final long RELAUNCH_TIMEOUT_S = 20;/'
mutant "F5: a placeable pend line is carried instead of landed" sync \
  's/^            if (s.hasAdapter(p.authority) \&\& have.contains(p.acct())) {$/            if (false) {/'
mutant "I: a setuid that silently changed nothing is not caught" sync \
  's/^            if (Os.getuid() != SYSTEM_UID) {$/            if (false) {/'
mutant "H: a pend line is landed for an account that is not visible" sync \
  's/^            if (s.hasAdapter(p.authority) \&\& have.contains(p.acct())) {$/            if (s.hasAdapter(p.authority)) {/'
mutant "CLOBBER: a carried 0 is kept pending at sign-in" sync \
  's/^                if (r.on) {$/                if (true) {/'
mutant "CLOBBER: a pend 0 is landed or carried" sync \
  's/^            if (!p.on) {$/            if (false) {/'
mutant "a pend 1 is written over the user's own live 1" sync \
  '0,/^                if (s.get(p.name, p.type, p.authority)) {$/s//                if (false) {/'
mutant "J-d: a pend 1 the user had already turned on is counted as landed" sync \
  's/^                    rows.put(p.key(), p); \/\/ the user turned it on already; nothing to land$/                    landed++; rows.put(p.key(), p);/'
mutant "round 7: the retry re-applies the whole record over the session's changes" sync \
  's/^        boolean handedBack = !p.fixes.isEmpty() || p.fixMaster != null;$/        boolean handedBack = false;/'
mutant "round 8: the retry ignores whether the switch changed since the failure" sync \
  's/^                if (known ? !live.equals(r.was) : !"0".equals(live)) {$/                if (false) {/'
mutant "round 8: the retry skips a carried 0 that did not land" sync \
  's/^            if (!known \&\& !r.on) {$/            if (!r.on) {/'
mutant "round 8: the retry sets master whatever it reads now" sync \
  's/^        } else if (master != null \&\& liveMaster.equals(p.fixMasterWas)) {$/        } else if (master != null) {/'
mutant "round 8: the whole-record fallback touches master (both of its guards gone)" sync \
  's/? p.fixMaster : null;$/? p.fixMaster : p.master;/; s/^        } else if (master != null \&\& liveMaster.equals(p.fixMasterWas)) {$/        } else if (master != null \&\& (!handedBack || liveMaster.equals(p.fixMasterWas))) {/'
mutant "round 9: an unreadable row during the retry is dropped (answer OK)" sync \
  's/^            if ("-".equals(live)) {$/            if (false) {/'
mutant "round 9: an unreadable master during the retry is dropped" sync \
  's/^        if (master != null \&\& "-".equals(liveMaster)) {$/        if (false) {/'
mutant "round 8: a failed apply hands back no value-after-failure" sync \
  '0,/^            r.was = liveOf(s, r);$/s//            ;/'
mutant "round 7: a failed apply hands nothing back" sync \
  '0,/^            fixes.add(r);$/s//            ;/'
mutant "round 7: a retry that still fails hands nothing back" sync \
  '/static Applied retry(/,$s/^            fixes.add(r);$/            ;/'
mutant "round 7: the retry mode runs the full apply" sync \
  's/"apply".equals(a\[0\]) ? apply(s, in0) : retry(s, in0)/apply(s, in0)/'
mutant "a carried 1 that did not stick is dropped, not kept pending" sync \
  's/^                unstuck++;$/                unstuck++; rows.put(p.key(), p); continue;/'
mutant "the landed/unstuck counts are not reported" sync \
  's/^        if (landed + unstuck > 0) {$/        if (false) {/'
mutant "an unplaceable pend line is not handed back" sync \
  's/^        for (Row p : still) {$/        for (Row p : new ArrayList<Row>()) {/'
mutant "vpn defer uses another consent type" vpn \
  's/^    static final int TYPE_VPN_SERVICE = 1;/    static final int TYPE_VPN_SERVICE = 3;/'
mutant "vpn defer sets always-on directly" vpn \
  's/^        if ("defer".equals(mode)) {$/        if (false) {/'
mutant "picker: a new app gets the block whatever was in effect" pa \
  's/return "1".equals(current\[1\]) ? "1" : "0";$/return "1";/'
mutant "picker: a deferred block is shown as off" pa \
  's/("1".equals(liveLock) || app.equals(livePend))/"1".equals(liveLock)/'
mutant "picker: promises a next-sign-in apply on an image with no helper (L8)" pa \
  's/^        if (helperPresent) return null;$/        return null;/'
mutant "M5: roamd keeps the block on an Off pick (the clamp deleted)" roamd \
  '/^    \[ -n "\$_p" \] || _l=0$/d' '    [ -n "$_p" ] || _l=0' hand-off-lock1
mutant "R2: roamd takes a pick whose app has a bad character" roamd \
  '/^    case "\$_p" in \*\[!A-Za-z0-9._\]\*) continue ;; esac$/d' '    case "$_p" in *[!A-Za-z0-9._]*) continue ;; esac' hand-badchar
mutant "R3: roamd takes a pick with no app= line" roamd \
  "/^    grep -q '^app=' \"\\\$_f\" 2>\\/dev\\/null || continue\$/d" "    grep -q '^app=' \"\$_f\" 2>/dev/null || continue" hand-noapp
VA='if (app != null && vpnPkgOk(app) && ('
mutant "picker: a pick's app is not checked (c1)" pa \
  's/if (app != null \&\& vpnPkgOk(app) \&\& (/if (app != null \&\& (/' "$VA" "picker: a pick whose app has a bad character falls to the live setting"
mutant "picker: a pick with no app= line reads as Off (c2)" pa \
  "s/^            if (app != null \&\& vpnPkgOk(app) \&\& (/            if (app == null) app = \"\";\n&/" "$VA" "picker: a pick with no app= line falls to the live setting"
mutant "picker: an Off pick keeps its block (c3)" pa \
  's/return new String\[\] {app, app.isEmpty() ? "0" : lock};/return new String[] {app, lock};/' \
  'return new String[] {app, app.isEmpty() ? "0" : lock};' "picker: an Off pick that carries lockdown=1 is none, block 0"
mutant "picker: live app \"null\" is an app (c4)" pa \
  's/liveApp == null || "null".equals(liveApp) ? "" : liveApp/liveApp == null ? "" : liveApp/' \
  'liveApp == null || "null".equals(liveApp) ? "" : liveApp' 'picker: live app "null" is none'
mutant "picker: a live block alone is not on (c5)" pa \
  's/("1".equals(liveLock) || app.equals(livePend))/app.equals(livePend)/' \
  '("1".equals(liveLock) || app.equals(livePend))' "picker: live lockdown 1 on its own is on"
mutant "picker: a pending block naming another app counts (c6)" pa \
  's/app.equals(livePend))/livePend != null)/' 'app.equals(livePend))' "picker: a pending block naming another app is off"
VP='app.isEmpty() || "0".equals(prefsLock) ? "0" : "1"'
mutant "picker: prefs vpnlockdown=0 is ignored (c7)" pa 's/app.isEmpty() || "0".equals(prefsLock) ? "0" : "1"/app.isEmpty() ? "0" : "1"/' \
  "$VP" "picker: prefs vpnlockdown=0 is off"
mutant "picker: prefs always block (c8)" pa 's/app.isEmpty() || "0".equals(prefsLock) ? "0" : "1"/"0".equals(prefsLock) ? "0" : "1"/' \
  "$VP" "picker: nothing anywhere is none, block 0"
mutant "pick text: an Off pick writes lockdown=1" pa \
  's/(p.isEmpty() || !"1".equals(lock) ? "0" : "1")/(!"1".equals(lock) ? "0" : "1")/' \
  '(p.isEmpty() || !"1".equals(lock) ? "0" : "1")' "pick text: Off is app= lockdown=0"
mutant "picker: the pending pick is ignored" pa 's/^        if (pickText != null) {$/        if (false) {/' \
  '        if (pickText != null) {' "picker: a pending pick is what is shown"
mutant "lockdown: an Off pick carries a block" pa 's/if (picked == null || picked.isEmpty()) return "0";/if (picked == null || picked.isEmpty()) return "1";/' \
  'if (picked == null || picked.isEmpty()) return "0";' "lockdown: Off carries no block"
echo; [ "$rc" = 0 ] && echo "all mutants convicted" || echo "⚠ a mutant survived or did not apply"
exit $rc
