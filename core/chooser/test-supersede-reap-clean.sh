#!/usr/bin/env bash
# test-supersede-reap-clean.sh [<chooser src dir>] [--mutate] -- the #123 supersede reap in the login worker sends
# CLEAN-STORAGE only for a superseded user whose removeUser was accepted (NWP-20261022-15).
#
# WHY THIS IS COMMITTED. The reap discarded dpm.removeUser's result and called cleanUserStorage either way, but
# roamd's cleanstorage rm -rf's the user's FBE trees without checking the user is gone (NWP-20261011-38). A refused
# removal therefore deleted a user that still existed, and held the RW lane for the reap's full settle poll. The #73
# sweep and the boot wipe already keep the precondition (test-orphan-sweep-clean.sh, test-boot-wipe-login-race.sh);
# this was the last chooser sender without it. The chooser has no unit-test harness, so these are source-level checks.
#
# HOW IT CHECKS. NWP-20261022-25 lifted the reap out of the login worker into `reapSupersededColdLock`, so a pending
# cold lock's sign-in can reap through the same code. The method, from its signature to its closing brace, is PINNED
# BYTE FOR BYTE, comments included; any edit fails here and the pin is updated with the edit, on purpose. The
# signature must occur exactly once, and the login worker's superseded branch must still call it, with the
# superseded uid and the new one. The line checks say WHY each property matters, and each has a mutation that must
# convict.
#
#   bash test-supersede-reap-clean.sh            # the invariants
#   bash test-supersede-reap-clean.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

MUTATE=no; SRC=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SRC="$a" ;; esac; done
SRC="${SRC:-$(dirname "$0")/src/com/nowhere/chooser}"
CA="$SRC/ChooserActivity.java"
[ -f "$CA" ] || { echo "no such file: $CA" >&2; exit 2; }

ANCHOR='    private void reapSupersededColdLock(android.content.Context appCtx, int coldUid, int byUid) {'
[ "$(grep -cxF -- "$ANCHOR" "$CA")" = 1 ] || { echo "anchor not exactly once: $ANCHOR" >&2; exit 2; }
SITE='                if (supersedeColdUid > 0 && supersedeColdUid != uid) {'
CALL='                    reapSupersededColdLock(appCtx, supersedeColdUid, uid);'

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
# Every match reads its input to the end: `grep -c ... >/dev/null`, never `grep -q`.

# block: the lines from the anchor to the first line closing it at its own indent.
block(){ awk -v sig="$ANCHOR" '$0 == sig { on = 1 } on { print } on && /^    }$/ { exit }' "$1"; }
line(){ printf '%s\n' "$1" | awk -v s="$2" 'index($0, s) && !n { n = NR } END { print n + 0 }'; }
count(){ printf '%s\n' "$1" | grep -cF -- "$2"; }
pin(){ if [ "$2" = "$3" ]; then ok "$1 is the pinned block"; else no "$1 differs from the pinned block"; fi; }

echo "== the login worker's superseded branch reaps through the method =="
# The line after the superseded branch's condition is the call, with the superseded uid first and the new one second.
call_after=$(awk -v s="$SITE" 'n == 1 { print; exit } $0 == s { n = 1 }' "$CA")
if [ "$(grep -cxF -- "$SITE" "$CA")" = 1 ] && [ "$call_after" = "$CALL" ]; then
  ok "if (supersedeColdUid > 0 && supersedeColdUid != uid) calls reapSupersededColdLock(appCtx, supersedeColdUid, uid)"
else
  no "the superseded branch does not call reapSupersededColdLock(appCtx, supersedeColdUid, uid) first (next line: $call_after)"
fi

echo "== the pinned block (byte for byte, comments included) =="
B=$(block "$CA")
PIN_B=$(cat <<'PIN'
    private void reapSupersededColdLock(android.content.Context appCtx, int coldUid, int byUid) {
        android.util.Log.i("NowhereChooser", "#123 reap superseded cold-lock user " + coldUid + " (superseded by login " + byUid + ")");
        boolean removed = false;
        try {
            android.app.admin.DevicePolicyManager rdpm = (android.app.admin.DevicePolicyManager) appCtx.getSystemService(Context.DEVICE_POLICY_SERVICE);
            android.content.ComponentName rAdmin = new android.content.ComponentName(appCtx, AdminReceiver.class);
            removed = rdpm.removeUser(rAdmin, android.os.UserHandle.of(coldUid));
        } catch (Throwable t) { android.util.Log.w("NowhereChooser", "reap superseded cold-lock", t); }
        // NWP-20261022-15 (docs/backlog.md, "The #73 orphan sweep sends CLEAN-STORAGE for a uid whose
        // removeUser may have failed"): roamd's cleanstorage rm's this uid's FBE trees without checking that
        // the user is gone (NWP-20261011-38), so it runs only for a removal that was accepted. A refused or
        // throwing removeUser leaves a user the #73 parked sweep reaps later.
        if (removed) cleanUserStorage(coldUid); // rm per-uid CE leftovers
        else android.util.Log.w("NowhereChooser", "#123 removeUser " + coldUid + " refused -- storage NOT cleaned; the #73 parked sweep retries");
        // Unconditional, and after the clean: the new sign-in committed, so the superseded session must not
        // be offered as "Welcome back" whether or not its removal was accepted.
        sendDaemon("CLEAR-COLDLOCK\n"); // belt-and-suspenders: forget the marker so GET-COLDLOCK stops offering the reaped session
    }
PIN
)
pin "the #123 supersede reap" "$B" "$PIN_B"

# Bc is the block with its comment lines removed, so a commented-out step reads as absent.
Bc=$(printf '%s\n' "$B" | grep -v '^[[:space:]]*//')

echo "== removeUser's result is captured, and only removeUser sets it =="
d=$(line "$Bc" 'boolean removed = false;'); r=$(line "$Bc" 'removed = rdpm.removeUser(rAdmin, android.os.UserHandle.of(coldUid));')
if [ "$(count "$Bc" 'removed = rdpm.removeUser(')" = 1 ] && [ "$d" -gt 0 ] && [ "$d" -lt "$r" ]; then
  ok "removeUser's result is assigned to removed, which starts false (a throw leaves it false)"
else
  no "removeUser's result is not captured (declared at $d, assigned at $r)"
fi
if [ "$(count "$Bc" 'removed =')" = 2 ] && [ "$(count "$Bc" 'removeUser(')" = 1 ]; then
  ok "nothing else assigns removed, and removeUser is called once"
else
  no "removed is assigned outside its declaration and the removeUser call, or removeUser is called again"
fi

echo "== CLEAN-STORAGE runs only for a removal that was accepted =="
c=$(line "$Bc" 'if (removed) cleanUserStorage(coldUid);')
if [ "$(count "$Bc" 'cleanUserStorage(')" = 1 ] && [ "$c" -gt 0 ]; then
  ok "cleanUserStorage(coldUid) is called exactly once, under if (removed)"
else
  no "cleanUserStorage is called unconditionally, more than once, or not at all -- a refused removal's LIVE storage is rm'd"
fi
if [ "$c" -gt "$r" ]; then ok "...after removeUser has answered"; else no "cleanUserStorage comes before removeUser answers (clean $c, removeUser $r)"; fi
e=$(line "$Bc" 'else android.util.Log.w("NowhereChooser", "#123 removeUser " + coldUid + " refused')
if [ "$e" = $((c + 1)) ]; then
  ok "a refused removal logs \"#123 removeUser <n> refused\" as the else of the clean"
else
  no "a refused removal is not logged as the else of the clean (clean $c, log $e)"
fi

echo "== CLEAR-COLDLOCK is unconditional and after both =="
k=$(line "$Bc" 'sendDaemon("CLEAR-COLDLOCK')
if [ "$(count "$Bc" 'CLEAR-COLDLOCK')" = 1 ] && [ "$k" -gt "$e" ] && [ "$e" -gt 0 ]; then
  ok "CLEAR-COLDLOCK is sent once, after the clean and the refusal log"
else
  no "CLEAR-COLDLOCK is missing, repeated, or before the clean/refusal log (clear $k, log $e)"
fi
if printf '%s\n' "$Bc" | sed -n "${k}p" | grep -E '^ {8}sendDaemon' >/dev/null; then
  ok "...at the method's own indent, outside the guard"
else
  no "CLEAR-COLDLOCK is nested inside a guard"
fi

# --- mutations ------------------------------------------------------------------------------------------
if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each MUST be convicted) =="
  mutate(){ # mutate <label> <sed script>
    local f="$W/src/ChooserActivity.java"
    rm -rf "$W/src"; mkdir "$W/src" || { no "MUTATION BROKEN (mkdir): $1"; return; }
    if ! cp "$CA" "$f" || ! cmp -s "$CA" "$f"; then no "MUTATION BROKEN (copy): $1"; return; fi
    if ! sed -i "$2" "$f" 2>"$W/err"; then no "MUTATION BROKEN (sed): $1"; return; fi
    if cmp -s "$f" "$CA"; then no "MUTATION INERT: $1"; return; fi
    if bash "$0" "$W/src" >/dev/null 2>&1; then no "NOT CONVICTED: $1 -- suite passes on broken code"
    else ok "convicted: $1"; fi
  }
  I='^\( \{8\}\)'
  mutate "cleanUserStorage is unconditional again"   "s/${I}if (removed) cleanUserStorage(coldUid);/\1cleanUserStorage(coldUid); if (!removed) { }/"
  mutate "removeUser's result is dropped"            "s/^\\( \\{12\\}\\)removed = rdpm.removeUser(/\\1rdpm.removeUser(/"
  mutate "the condition is inverted"                 "s/${I}if (removed) cleanUserStorage(/\1if (!removed) cleanUserStorage(/"
  mutate "removed is forced true after the call"     "s/\(removed = rdpm.removeUser(.*\)\$/\1 removed = true;/"
  mutate "a throwing removeUser cleans anyway"       "s/\"reap superseded cold-lock\", t); }\$/\"reap superseded cold-lock\", t); cleanUserStorage(coldUid); }/"
  mutate "the refusal log is dropped"                "s/${I}else android.util.Log.w(\"NowhereChooser\", \"#123 removeUser .*\$/\1else { }/"
  mutate "CLEAR-COLDLOCK moves inside the guard"     "s/${I}if (removed) cleanUserStorage(coldUid);\(.*\)\$/\1if (removed) { cleanUserStorage(coldUid); sendDaemon(\"CLEAR-COLDLOCK\\\\n\"); }/; /^ \{8\}sendDaemon(\"CLEAR-COLDLOCK/d"
  mutate "the superseded branch no longer reaps"     "/^ \{20\}reapSupersededColdLock(appCtx, supersedeColdUid, uid);\$/d"
  mutate "the reap is handed the new uid"            "s/^\( \{20\}\)reapSupersededColdLock(appCtx, supersedeColdUid, uid);\$/\1reapSupersededColdLock(appCtx, uid, uid);/"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
