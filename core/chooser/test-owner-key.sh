#!/usr/bin/env bash
# test-owner-key.sh [<ChooserActivity.java>] [--mutate] -- the gate's half of the device-owner key (NWP-20260928-01).
#
# WHY THIS IS COMMITTED. The daemon mints or replaces the device-owner key on the chooser's word: OWNER-KEY-NEW at an
# enrol, OWNER-KEY-ENSURE at a verify, and ENSURE REPLACES a key the passphrase it is given cannot open. So a call from
# the wrong branch -- a failed verify, an enrol whose owner.conf never reached disk -- replaces the owner key, and
# every record sealed to the old one becomes unreadable. The chooser has no unit-test harness, so these are
# source-level checks on the functional forms (never comment text), in the style of test-owner-mandatory.sh; CI
# executes this suite and its --mutate run.
#
#   bash test-owner-key.sh            # the invariants
#   bash test-owner-key.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/src/com/nowhere/chooser/ChooserActivity.java}"
[ -f "$SUT" ] || { echo "no such file: $SUT" >&2; exit 2; }
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

# body <method signature fragment>: the method's lines, from its signature to the first line that closes it at the
# class's method indent ("    }").
body(){ awk -v sig="$1" 'index($0, sig) { on = 1 } on { print } on && /^    }$/ { exit }' "$SUT"; }
# ⚠ Every match below reads its input to the end: `grep -c ... >/dev/null`, never `grep -q`. Under pipefail, grep -q
# exits at its first match and the command feeding it can then die of SIGPIPE, which fails the whole pipeline -- a
# pattern that IS there reads as absent, and an absence check (the log check below) passes on the code it exists to
# reject. Measured in test-tel-scrub.sh (NWP-20260927-10): a check built that way passed its broken tree 36 times in 40.

echo "== ENSURE only after a verify that matched =="
V=$(body 'private int verifyOwner(String pass)')
if [ "$(grep -c 'ownerKeyAsync("OWNER-KEY-ENSURE"' "$SUT")" = 2 ]; then ok "OWNER-KEY-ENSURE is sent from exactly two places (verifyOwner's matched branch and changeOwnerPass's success)"; else no "OWNER-KEY-ENSURE is sent from other than exactly two places (verifyOwner's matched branch and changeOwnerPass's success)"; fi
BR=$(printf '%s\n' "$V" | awk '/if \(OwnerVerifyForm\.matched\(o\)\) \{/ { on = 1 } on { print } on && /^        }$/ { exit }')
if printf '%s\n' "$BR" | grep -c 'ownerKeyAsync("OWNER-KEY-ENSURE", pass, d);' >/dev/null && printf '%s\n' "$BR" | grep -c 'return 0;' >/dev/null; then
  ok "…inside the matched branch, which returns 0"
else
  no "OWNER-KEY-ENSURE is not inside verifyOwner's matched-verifier branch -- a wrong passphrase would replace the owner key"
fi
if [ "$(printf '%s\n' "$BR" | grep -n 'ownerKeyAsync' | cut -d: -f1)" -lt "$(printf '%s\n' "$BR" | grep -n 'return 0;' | cut -d: -f1)" ] 2>/dev/null; then
  ok "…and before that return"
else
  no "OWNER-KEY-ENSURE does not run before the matched branch returns"
fi

echo "== NEW only after an enrol that reached disk =="
E=$(body 'private int enrollOwner(String pass)')
if [ "$(grep -c 'ownerKeyAsync("OWNER-KEY-NEW"' "$SUT")" = 1 ] && printf '%s\n' "$E" | grep -c 'if (ok) ownerKeyAsync("OWNER-KEY-NEW", pass, d);' >/dev/null; then
  ok "OWNER-KEY-NEW is sent once, from enrollOwner, behind ok"
else
  no "OWNER-KEY-NEW is not sent exactly once from enrollOwner behind the read-back"
fi
if printf '%s\n' "$E" | grep -c 'boolean ok = c != null && owHex(salt).equals(c.get("salt")) && d.verifier.equals(c.get("verifier"));' >/dev/null; then
  ok "ok is the read-back of the new salt and verifier"
else
  no "enrollOwner no longer reads owner.conf back -- a failed write would mint the key under a passphrase nobody can verify"
fi
if printf '%s\n' "$E" | grep -cF 'return ownerSecretSet()' >/dev/null; then
  no "enrollOwner returns ownerSecretSet() again -- an older owner.conf reports a failed enrol as done"
else
  ok "enrollOwner does not return ownerSecretSet()"
fi
# NWP-20261108-11: what reached disk, and whether the chip answered, is what the enrol screen is told.
if [ "$(printf '%s\n' "$E" | grep -cF 'return OwnerVerifyForm.enrolResult(ok, d.seBroken);')" = 1 ]; then
  ok "enrollOwner returns OwnerVerifyForm.enrolResult(ok, d.seBroken)"
else
  no "enrollOwner does not return OwnerVerifyForm.enrolResult(ok, d.seBroken) exactly once -- the screen is told something other than what reached disk"
fi

echo "== the request: off the UI thread, v1 first, never a secret in a log =="
A=$(body 'private static void ownerKeyAsync(String verb, String pass, OwnerDerived d)')
# NWP-20261022-01: one FIFO lane for every owner-key verb, so an ENSURE for an old passphrase cannot land after the ENSURE
# that pruned it (the daemon serves verbs in arrival order; a Thread per verb left the order to the scheduler).
if printf '%s\n' "$A" | grep -cF 'OWNER_KEY_LANE.submit(() -> {' >/dev/null && ! printf '%s\n' "$A" | grep -c 'new Thread' >/dev/null && ! printf '%s\n' "$A" | grep -cF '.start()' >/dev/null; then
  ok "the daemon call is submitted to OWNER_KEY_LANE and ownerKeyAsync starts no thread of its own"
else
  no "ownerKeyAsync does not submit to OWNER_KEY_LANE, or starts a Thread of its own -- verbs are unordered again"
fi
if [ "$(grep -cF 'private static final java.util.concurrent.ExecutorService OWNER_KEY_LANE = java.util.concurrent.Executors.newSingleThreadExecutor(' "$SUT")" = 1 ]; then
  ok "OWNER_KEY_LANE is a single-thread executor, declared once"
else
  no "OWNER_KEY_LANE is not declared once as a single-thread executor"
fi
if printf '%s\n' "$A" | grep -cF 'final String msg = verb + "\nv1\n"' >/dev/null; then ok 'the request puts "v1" before the secret'; else no 'the request does not start with "v1" -- an older agent would take the owner passphrase for a profile'"'"'s'; fi
SB=$(printf '%s\n' "$A" | awk '/if \(d.seBroken\) \{/ { on = 1 } on { print } on && /^        }$/ { exit }')
if printf '%s\n' "$SB" | grep -c 'return;' >/dev/null; then ok "a StrongBox device whose pepper failed sends nothing"; else no "a StrongBox device whose pepper failed falls through to a pepperless request"; fi
D=$(body 'private OwnerDerived ownerDerive(String pass, byte[] salt, boolean create)')
if printf '%s\n' "$D" | grep -A2 -F 'd.verifier = se;' | tr -d ' ' | tr '\n' '|' | grep -cF 'd.verifier=se;|d.pepper=ownerSePepper(dk);|d.seBroken=d.pepper==null;|' >/dev/null; then
  ok "a StrongBox verifier comes with its pepper, and a missing pepper sets seBroken"
else
  no "ownerDerive's StrongBox branch no longer computes the pepper, or no longer sets seBroken from it -- a StrongBox phone would mint a pepperless key"
fi
if printf '%s\n' "$D" | grep -cF 'd.seBroken = getPackageManager().hasSystemFeature(android.content.pm.PackageManager.FEATURE_STRONGBOX_KEYSTORE);' >/dev/null; then
  ok "a StrongBox device whose verifier fell back to PBKDF2 is marked seBroken"
else
  no "a StrongBox device whose verifier fell back to PBKDF2 is not marked seBroken -- its enrol would mint a pepperless key"
fi
LOGS=$( { body 'private OwnerDerived ownerDerive(String pass, byte[] salt, boolean create)'; body 'private int enrollOwner(String pass)'; body 'private static byte[] ownerSePepper(byte[] dk)'; printf '%s\n' "$A"; } | grep 'android.util.Log')
if printf '%s\n' "$LOGS" | grep -cE '[(+ ,](pass|pb|msg|dk|d\.pepper)[ ,)+]' >/dev/null; then
  no "an owner-key log line carries the passphrase, the pepper or the request"
else
  ok "no owner-key log line carries the passphrase, the pepper or the request"
fi
if body 'private OwnerDerived ownerDerive(String pass, byte[] salt, boolean create)' | grep -c 'spec.clearPassword();' >/dev/null; then ok "the PBKDF2 spec's copy of the passphrase is cleared"; else no "the PBKDF2 spec's copy of the passphrase is not cleared"; fi

echo "== the passphrase change: a rewrap, owner.conf only on OK or NOKEY (NWP-20261022-01) =="
P=$(body 'private int changeOwnerPass(String oldPass, String newPass)')
# line <fixed string> [<text>]: the first line number of the fragment in $P, empty when absent.
ln(){ printf '%s\n' "${2:-$P}" | grep -nF -- "$1" | head -1 | cut -d: -f1; }
lt(){ [ -n "$1" ] && [ -n "$2" ] && [ "$1" -lt "$2" ]; }
OPC="$(dirname "$SUT")/OwnerPassChange.java"
if [ "$(grep -cF 'OWNER-KEY-REWRAP' "$SUT")" = 0 ] && [ "$(grep -cF 'OwnerPassChange.rewrapRequest(' "$SUT")" = 1 ] && printf '%s\n' "$P" | grep -cF 'OwnerPassChange.rewrapRequest(' >/dev/null \
   && { [ ! -f "$OPC" ] || [ "$(grep -cF '"OWNER-KEY-REWRAP' "$OPC")" = 1 ]; }; then
  ok "OWNER-KEY-REWRAP is built only in OwnerPassChange.rewrapRequest and sent only from changeOwnerPass"
else
  no "OWNER-KEY-REWRAP is built or sent from somewhere other than OwnerPassChange.rewrapRequest / changeOwnerPass"
fi
if printf '%s\n' "$P" | grep -cF 'OWNER_KEY_LANE.submit(() -> DaemonSocket.roundTrip(req, 60000)).get(90, java.util.concurrent.TimeUnit.SECONDS);' >/dev/null && ! printf '%s\n' "$P" | grep -c 'new Thread' >/dev/null; then
  ok "the rewrap goes through OWNER_KEY_LANE, behind the ENSURE verifyOwner queued"
else
  no "the rewrap is not sent through OWNER_KEY_LANE -- an ENSURE for the old passphrase could land after the prune"
fi
G=$(body 'private int changeOwnerPassSerialized(String oldPass, String newPass)')
if [ "$(grep -cF 'changeOwnerPass(' "$SUT")" = 2 ] && [ "$(grep -cF 'changeOwnerPassSerialized(old, a)' "$SUT")" = 1 ] \
   && printf '%s\n' "$G" | grep -F 'OWNER_AUTH_LOCK.tryLock()' | grep -cF 'return -5' >/dev/null \
   && printf '%s\n' "$G" | grep -cF 'finally { OWNER_AUTH_LOCK.unlock(); }' >/dev/null; then
  ok "a passphrase change is single-flight: the screen calls changeOwnerPassSerialized, which refuses (-5) while the auth lock is held and releases in finally"
else
  no "a passphrase change is not single-flight -- two overlapping changes could replace the owner key"
fi
if [ "$(grep -cF 'OWNER_AUTH_LOCK.lock();' "$SUT")" = 1 ] && [ "$(grep -cF 'try { r = verifyOwner(p); } finally { OWNER_AUTH_LOCK.unlock(); }' "$SUT")" = 1 ] \
   && [ "$(grep -cE '[^a-zA-Z]verifyOwner\(' "$SUT")" = 3 ]; then
  ok "every ordinary verify holds OWNER_AUTH_LOCK, so none can straddle a passphrase change and restore the old owner.conf"
else
  no "an ordinary verifyOwner call can run outside OWNER_AUTH_LOCK -- a stale verify could queue ENSURE(old) behind the prune"
fi
L_VER=$(ln 'int r = verifyOwner(oldPass);'); L_RD=$(ln 'readOwnerConf()'); L_REQ=$(ln 'OwnerPassChange.rewrapRequest(')
if lt "$L_VER" "$L_RD" && lt "$L_VER" "$L_REQ" && [ "$(printf '%s\n' "$P" | grep -cF 'verifyOwner(')" = 1 ]; then
  ok "verifyOwner(oldPass) runs first and once: it counts the attempt and queues ENSURE(old) ahead of everything"
else
  no "changeOwnerPass does not start with verifyOwner(oldPass)"
fi
L_SUB=$(ln 'OWNER_KEY_LANE.submit(() -> DaemonSocket.roundTrip'); L_WR=$(ln 'writeOwnerConf('); L_CASE=$(ln 'case WRITE_CONF: break;'); L_UNC=$(ln 'case UNCHANGED:'); L_WRG=$(ln 'case WRONG:')
if [ "$(printf '%s\n' "$P" | grep -cF 'writeOwnerConf(')" = 1 ] && lt "$L_SUB" "$L_WR" && lt "$L_CASE" "$L_WR" && lt "$L_UNC" "$L_WR" \
   && printf '%s\n' "$P" | grep -F 'case UNCHANGED:' | grep -cF 'return -' >/dev/null && printf '%s\n' "$P" | grep -F 'case WRONG:' | grep -cF 'return -' >/dev/null; then
  ok "owner.conf is written once, after the rewrap reply, and only past the WRITE_CONF arm (WRONG and UNCHANGED return)"
else
  no "writeOwnerConf is before the rewrap reply, repeated, or reachable from a WRONG or UNCHANGED reply"
fi
if printf '%s\n' "$P" | grep -cF 'boolean ok = c2 != null && owHex(newSalt).equals(c2.get("salt")) && dNew.verifier.equals(c2.get("verifier"));' >/dev/null && printf '%s\n' "$P" | grep -cF 'if (!ok) { dNew.clear(); return -4; }' >/dev/null; then
  ok "ok is the read-back of the new salt and verifier, and a miss returns -4"
else
  no "changeOwnerPass no longer reads owner.conf back for the new salt and verifier"
fi
L_OK=$(ln 'boolean ok = '); L_SP=$(ln 'ownerSessionPass = newPass;'); L_EN=$(ln 'ownerKeyAsync("OWNER-KEY-ENSURE", newPass, dNew);')
if lt "$L_OK" "$L_SP" && lt "$L_SP" "$L_EN"; then ok "ownerSessionPass moves to the new passphrase after the read-back, before the post-change ENSURE"; else no "ownerSessionPass is not set after the read-back (or not at all)"; fi
if printf '%s\n' "$P" | grep -cF 'OwnerDerived dNew = ownerDerive(newPass, newSalt, false);' >/dev/null && printf '%s\n' "$P" | grep -cF 'writeOwnerConf(owHex(newSalt), dNew.verifier, 0, 0, c.getOrDefault("kcv", ""));' >/dev/null \
   && [ "$(printf '%s\n' "$P" | grep -cF 'nextBytes(')" = 1 ] && [ "$(printf '%s\n' "$P" | grep -cF 'new byte[16]')" = 1 ]; then
  ok "dNew is derived from, and owner.conf written with, the SAME newSalt"
else
  no "the new derivation and the owner.conf write do not share one newSalt -- the verifier would not match the salt on disk"
fi
if printf '%s\n' "$P" | grep -F 'dNew.seBroken || dOld.seBroken' | grep -cF 'return -5;' >/dev/null && lt "$(ln 'dNew.seBroken || dOld.seBroken')" "$L_REQ"; then
  ok "a StrongBox phone whose pepper failed returns before any rewrap is built"
else
  no "the seBroken refusal is missing or after the rewrap request -- a pepperless request from a StrongBox phone"
fi
L_DN=$(ln 'OwnerDerived dNew = ownerDerive(newPass, newSalt, false);')
KEEP=$(printf '%s\n' "$P" | awk -v a="$L_DN" -v b="$L_EN" 'NR > a && NR < b && /dNew\.clear\(\)/ && !/return -/ { print }')
if [ -z "$L_DN" ] || [ -z "$L_EN" ]; then
  no "changeOwnerPass has no dNew derivation or no post-change ENSURE"
elif [ -z "$KEEP" ] && [ "$(printf '%s\n' "$P" | grep -cF 'Arrays.fill(dNew.pepper')" = 0 ] && [ "$(printf '%s\n' "$P" | grep -cF 'ownerKeyAsync("OWNER-KEY-ENSURE", newPass, dNew);')" = 1 ]; then
  ok "dNew keeps its real pepper until the post-change ENSURE (every clear before it is on a return)"
else
  no "dNew is cleared or zeroed before the post-change ENSURE -- a zeroed pepper opens neither wrapping and the key is REPLACED"
fi
S=$(body 'private View buildOwnerChangePassScreen()')
if lt "$(ln 'OwnerPassChange.floorError(' "$S")" "$(ln 'new Thread(' "$S")" && printf '%s\n' "$S" | grep -cF 'changeOwnerPassSerialized(' >/dev/null \
   && [ "$(body 'private View buildOwnerMenu()' | grep -cF 'buildOwnerChangePassScreen()')" = 1 ]; then
  ok "the change screen checks OwnerPassChange.floorError before it starts the worker, and the owner menu offers it"
else
  no "the change screen does not check floorError before its worker, or the owner menu does not offer it"
fi
if printf '%s\n' "$P" | grep 'android.util.Log' | grep -cE '[(+ ,](oldPass|newPass|req|oldPb|newPb|newSalt|dOld\.[a-z]+|dNew\.[a-z]+|reply|c|c2)[ ,)+]' >/dev/null; then
  no "a changeOwnerPass log line carries a passphrase, the request, a pepper, a salt, a verifier or the whole reply"
else
  ok "no changeOwnerPass log line carries a passphrase, the request, a pepper, a salt, a verifier or the whole reply"
fi

# --- mutations ------------------------------------------------------------------------------------------
if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each MUST be convicted) =="
  M=$(mktemp -d -p "$W")
  mutate(){
    if ! sed "$2" "$SUT" > "$M/m.java" 2>"$M/err"; then no "MUTATION BROKEN (sed): $1"; return; fi
    if cmp -s "$SUT" "$M/m.java"; then no "MUTATION INERT: $1"; return; fi
    if bash "$0" "$M/m.java" >/dev/null 2>&1; then no "NOT CONVICTED: $1 -- suite passes on broken code"
    else ok "convicted: $1"; fi
  }
  mutate "ENSURE sent after a WRONG passphrase too" \
         '/^        d.clear();$/{n;s/^        return -1;$/        ownerKeyAsync("OWNER-KEY-ENSURE", pass, d); return -1;/}'
  mutate "seBroken no longer follows the pepper" \
         's/d.seBroken = d.pepper == null;/d.seBroken = false;/'
  mutate "the StrongBox pepper never computed" \
         's/d.pepper = ownerSePepper(dk);/d.pepper = null;/'
  mutate "a StrongBox device's PBKDF2 fallback not marked seBroken" \
         's/d.seBroken = getPackageManager().hasSystemFeature(android.content.pm.PackageManager.FEATURE_STRONGBOX_KEYSTORE);/d.seBroken = false;/'
  mutate "the enrol read-back dropped" \
         's/boolean ok = c != null \&\& owHex(salt).equals(c.get("salt")) \&\& d.verifier.equals(c.get("verifier"));/boolean ok = true;/'
  mutate "ownerKeyAsync back on its own Thread" \
         '/private static void ownerKeyAsync/,/^    }$/{s/^        OWNER_KEY_LANE.submit(() -> {$/        new Thread(() -> {/;s/^        });$/        }, "nowhere-owner-key").start();/}'
  mutate "the passphrase logged" \
         's/^        byte\[\] pb = pass.getBytes(java.nio.charset.StandardCharsets.UTF_8);$/&\n        android.util.Log.w("NowhereChooser", verb + pass);/'
  mutate "the v1 line removed" \
         's/final String msg = verb + "\\nv1\\n"/final String msg = verb + "\\n"/'
  mutate "a broken StrongBox pepper falls through to a pepperless request" \
         '/android.util.Log.w("NowhereChooser", verb + ": skipped, StrongBox unavailable");/{n;s/^            return;$/            \/\/ fall through/}'
  mutate "enrollOwner reports ownerSecretSet() again" \
         's/^        return OwnerVerifyForm.enrolResult(ok, d.seBroken);$/        return ownerSecretSet() ? OwnerVerifyForm.ENROL_OK : OwnerVerifyForm.ENROL_FAILED;/'
  mutate "the enrol retry log carries the passphrase" \
         's/" of 2")/" of 2" + pass)/'
  # NWP-20261022-01: the passphrase change. Every sed is scoped to changeOwnerPass / the change screen.
  CP='/private int changeOwnerPass/,/^    }$/'
  mutate "writeOwnerConf moved before the rewrap send" \
         "$CP"'{/^        writeOwnerConf(owHex(newSalt), dNew.verifier, 0, 0, c.getOrDefault("kcv", ""));.*$/d;s/^        String reply;$/        writeOwnerConf(owHex(newSalt), dNew.verifier, 0, 0, c.getOrDefault("kcv", ""));\n&/}'
  mutate "the WRITE_CONF arm also taken on UNCHANGED" \
         "$CP"'s/^            case UNCHANGED: .*$/            case UNCHANGED:/'
  mutate "the change's read-back replaced by ok = true" \
         "$CP"'s/boolean ok = c2 != null .*;$/boolean ok = true;/'
  mutate "ownerSessionPass set before the read-back" \
         "$CP"'{/^        ownerSessionPass = newPass;/d;s/^        writeOwnerConf(owHex(newSalt), dNew.verifier, 0, 0, c.getOrDefault("kcv", ""));.*$/        ownerSessionPass = newPass;\n&/}'
  mutate "ownerSessionPass not set at all" \
         "$CP"'{/^        ownerSessionPass = newPass;/d}'
  mutate "the post-change ENSURE sent with oldPass" \
         's/ownerKeyAsync("OWNER-KEY-ENSURE", newPass, dNew);/ownerKeyAsync("OWNER-KEY-ENSURE", oldPass, dNew);/'
  mutate "dNew derived from a second random salt" \
         's/OwnerDerived dNew = ownerDerive(newPass, newSalt, false);/byte[] s2 = new byte[16]; new java.security.SecureRandom().nextBytes(s2); OwnerDerived dNew = ownerDerive(newPass, s2, false);/'
  mutate "the seBroken refusal removed" \
         's/ || dNew.seBroken || dOld.seBroken)/)/'
  mutate "dNew cleared right after the request is built" \
         "$CP"'s/^        dOld.clear();$/        dOld.clear(); dNew.clear();/'
  mutate "the rewrap sent on a new Thread instead of the lane" \
         's/^            reply = OWNER_KEY_LANE.submit(() -> DaemonSocket.roundTrip(req, 60000)).get(90, java.util.concurrent.TimeUnit.SECONDS);$/            final String[] rr = new String[1]; Thread th = new Thread(() -> rr[0] = DaemonSocket.roundTrip(req, 60000)); th.start(); th.join(90000); reply = rr[0];/'
  mutate "floorError dropped from the change screen" \
         '/private View buildOwnerChangePassScreen/,/^    }$/{s/final String floor = OwnerPassChange.floorError(a, b);/final String floor = null;/}'
  mutate "the change screen calls changeOwnerPass directly, outside the single-flight guard" \
         's/final int r = changeOwnerPassSerialized(old, a);/final int r = changeOwnerPass(old, a);/'
  mutate "the single-flight guard never refuses" \
         's/if (!OWNER_AUTH_LOCK.tryLock()) return -5;/OWNER_AUTH_LOCK.tryLock();/'
  mutate "the owner verify screen runs verifyOwner outside the auth lock" \
         '/^                OWNER_AUTH_LOCK.lock();/d;s/^                try { r = verifyOwner(p); } finally { OWNER_AUTH_LOCK.unlock(); }$/                r = verifyOwner(p);/'
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
