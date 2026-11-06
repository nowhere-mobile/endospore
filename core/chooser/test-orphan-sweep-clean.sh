#!/usr/bin/env bash
# test-orphan-sweep-clean.sh [<chooser src dir>] [--mutate] -- the #73 parked orphan sweep sends CLEAN-STORAGE only
# for a user whose removeUser was accepted (NWP-20261011-38).
#
# WHY THIS IS COMMITTED. reapOrphanSecondaryUsers used to ignore dpm.removeUser's result and call
# cleanUserStorage(uid) either way. roamd's cleanstorage then rm -rf's /data/{system_ce,system_de,misc_ce,misc_de,
# user,user_de,media,vendor_ce,vendor_de}/<uid> before anything checks that the user is gone -- so a refused removal
# deleted a possibly LIVE user's storage. The chooser has no unit-test harness, so these are source-level checks; CI
# executes this suite and its --mutate run.
#
# HOW IT CHECKS. reapOrphanSecondaryUsers is PINNED BYTE FOR BYTE, comments included, as test-owner-conf.sh pins its
# methods: a line check on a spelling passes a commented-out step or a call split across lines. So any edit to the
# method fails here, and the pin is updated with the edit, on purpose. The line checks below the pin say WHY each
# property matters, and each has a mutation that must convict the suite. The method must occur exactly once, so a
# dead copy left in a comment cannot stand in for a changed one.
#
#   bash test-orphan-sweep-clean.sh            # the invariants
#   bash test-orphan-sweep-clean.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SRC=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SRC="$a" ;; esac; done
SRC="${SRC:-$(dirname "$0")/src/com/nowhere/chooser}"
CA="$SRC/ChooserActivity.java"
[ -f "$CA" ] || { echo "no such file: $CA" >&2; exit 2; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
# ⚠ Every match reads its input to the end: `grep -c ... >/dev/null`, never `grep -q` (see test-owner-key.sh).

# body <file> <signature fragment>: the method's lines, from its signature to the first line closing it at the class's
# method indent ("    }") -- or a marker that fails every check when the signature does not occur exactly once.
body(){ [ "$(grep -cF -- "$2" "$1")" = 1 ] || { echo "<signature not exactly once: $2>"; return; }; awk -v sig="$2" 'index($0, sig) { on = 1 } on { print } on && /^    }$/ { exit }' "$1"; }
# line <text> <fixed string>: the 1-based line of its first match, or 0.
line(){ printf '%s\n' "$1" | awk -v s="$2" 'index($0, s) && !n { n = NR } END { print n + 0 }'; }
# count <text> <fixed string>: how many lines contain it.
count(){ printf '%s\n' "$1" | grep -cF -- "$2"; }
# pin <name> <actual> <expected>
pin(){ if [ "$2" = "$3" ]; then ok "$1 is the pinned block"; else no "$1 differs from the pinned block"; fi; }

echo "== the pinned block (byte for byte, comments included) =="
B=$(body "$CA" 'private void reapOrphanSecondaryUsers(int keepUid)')
PIN_B=$(cat <<'PIN'
    private void reapOrphanSecondaryUsers(int keepUid) {
        if (sessionLive || signingOut || resumeBusy || loginInProgress) return; // only when truly parked at the gate
        try {
            android.app.admin.DevicePolicyManager dpm =
                    (android.app.admin.DevicePolicyManager) getSystemService(DEVICE_POLICY_SERVICE);
            android.content.ComponentName admin = new android.content.ComponentName(this, AdminReceiver.class);
            for (android.os.UserHandle uh : dpm.getSecondaryUsers(admin)) {
                int uid = uh.getIdentifier();
                if (uid == keepUid) continue; // the one resumable cold-locked session -> keep
                if (loginInProgress || sessionLive || signingOut) return; // a login/reap started mid-sweep -> stop at once
                android.util.Log.i("NowhereChooser", "#73 reap orphan roam user " + uid + " (keep=" + keepUid + ")");
                boolean removed = false;
                try { removed = dpm.removeUser(admin, uh); }
                catch (Throwable t) { android.util.Log.w("NowhereChooser", "reap removeUser " + uid, t); }
                // NWP-20261011-38 (docs/backlog.md, "The #73 orphan sweep sends CLEAN-STORAGE for a uid whose
                // removeUser may have failed"): roamd's cleanstorage rm's this uid's FBE trees (/data/user, system_ce,
                // media, ...) without checking that the user is gone, so it runs only for a removal that was accepted.
                // After a refused or throwing removeUser the user may be LIVE: leave its storage alone. It is still a
                // secondary user, so the next parked sweep retries it.
                if (removed) cleanUserStorage(uid); // rm the per-uid CE leftovers so a reused uid can't crash system_server
                else android.util.Log.w("NowhereChooser", "#73 removeUser " + uid + " refused -- storage NOT cleaned; the next parked sweep retries");
            }
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "reapOrphanSecondaryUsers", t);
        }
    }
PIN
)
pin "reapOrphanSecondaryUsers" "$B" "$PIN_B"

# Bc is the method with its comment lines removed, so a commented-out step reads as absent.
Bc=$(printf '%s\n' "$B" | grep -v '^[[:space:]]*//')

echo "== removeUser's result is captured, and only removeUser sets it =="
d=$(line "$Bc" 'boolean removed = false;'); r=$(line "$Bc" 'try { removed = dpm.removeUser(admin, uh); }')
if [ "$(count "$Bc" 'removed = dpm.removeUser(admin, uh);')" = 1 ] && [ "$d" -gt 0 ] && [ "$d" -lt "$r" ]; then
  ok "removeUser's result is assigned to removed, which starts false (a throw leaves it false)"
else
  no "removeUser's result is not captured (declared at $d, assigned at $r) -- the sweep cannot tell a refused removal"
fi
if [ "$(count "$Bc" 'removed =')" = 2 ] && [ "$(count "$Bc" 'removeUser(')" = 1 ]; then
  ok "nothing else assigns removed, and removeUser is called once"
else
  no "removed is assigned outside its declaration and the removeUser call, or removeUser is called again"
fi

echo "== CLEAN-STORAGE runs only for a removal that was accepted =="
c=$(line "$Bc" 'if (removed) cleanUserStorage(uid);')
if [ "$(count "$Bc" 'cleanUserStorage(')" = 1 ] && [ "$c" -gt 0 ]; then
  ok "cleanUserStorage(uid) is called exactly once, under if (removed)"
else
  no "cleanUserStorage is called unconditionally, more than once, or not at all -- a refused removal's LIVE storage is rm'd"
fi
if [ "$c" -gt "$r" ]; then ok "...after removeUser has answered"; else no "cleanUserStorage comes before removeUser answers (clean $c, removeUser $r)"; fi
e=$(line "$Bc" 'else android.util.Log.w("NowhereChooser", "#73 removeUser " + uid + " refused -- storage NOT cleaned; the next parked sweep retries");')
if [ "$e" = $((c + 1)) ]; then
  ok "a refused removal logs \"#73 removeUser <n> refused\" -- the maintainer's device check reads this line"
else
  no "a refused removal is not logged as the else of the clean (clean $c, log $e)"
fi

# --- mutations ------------------------------------------------------------------------------------------
if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each MUST be convicted) =="
  M2=$(mktemp -d)
  mutate(){ # mutate <label> <sed script>
    # The suite reads only ChooserActivity.java, so only it is copied; a failed copy is a broken mutation, never
    # a conviction (a truncated file fails the pin for the wrong reason).
    rm -rf "$M2/src"; mkdir "$M2/src" || { no "MUTATION BROKEN (mkdir): $1"; return; }
    local f="$M2/src/ChooserActivity.java"
    if ! cp "$CA" "$f" || ! cmp -s "$CA" "$f"; then no "MUTATION BROKEN (copy): $1"; return; fi
    if ! sed -i "$2" "$f" 2>"$M2/err"; then no "MUTATION BROKEN (sed): $1"; return; fi
    if cmp -s "$f" "$CA"; then no "MUTATION INERT: $1"; return; fi
    if bash "$0" "$M2/src" >/dev/null 2>&1; then no "NOT CONVICTED: $1 -- suite passes on broken code"
    else ok "convicted: $1"; fi
  }
  mutate "cleanUserStorage is unconditional again"             's/^\(                \)if (removed) cleanUserStorage(uid);/\1cleanUserStorage(uid); if (!removed) { }/'
  mutate "removeUser's result is dropped"                      's/^\(                \)try { removed = dpm.removeUser(admin, uh); }$/\1try { dpm.removeUser(admin, uh); }/'
  mutate "the condition is inverted"                           's/^\(                \)if (removed) cleanUserStorage(uid);/\1if (!removed) cleanUserStorage(uid);/'
  mutate "removed is forced true after the call"               's/^\(                \)try { removed = dpm.removeUser(admin, uh); }$/\1try { removed = dpm.removeUser(admin, uh); } finally { removed = true; }/'
  mutate "a throwing removeUser cleans anyway"                 's/"reap removeUser " + uid, t); }$/"reap removeUser " + uid, t); cleanUserStorage(uid); }/'
  mutate "the refused log line is dropped"                     's/^\(                \)else android.util.Log.w("NowhereChooser", "#73 removeUser " + uid + " refused.*$/\1else { }/'
  mutate "the guarded clean survives only in a comment"        's/^\(                \)if (removed) cleanUserStorage(uid);\(.*\)$/\1\/\/ if (removed) cleanUserStorage(uid);\n\1cleanUserStorage(uid); if (false) { }/'
  mutate "a dead copy of the method left in a comment"         's/^\(    \)private void reapOrphanSecondaryUsers(int keepUid) {$/\1\/* private void reapOrphanSecondaryUsers(int keepUid) { } *\/\n&/'
  rm -rf "$M2"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
