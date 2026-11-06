#!/usr/bin/env bash
# test-owner-verify-form-java.sh [--mutate] -- the owner verify heals a PBKDF2-form check, run under javac (NWP-20261108-07).
#
# WHY THIS IS COMMITTED. A StrongBox phone whose chip failed at setup stored the PBKDF2 form of the owner's check
# (Q018, docs/product-decisions.md 2026-10-20). Once the chip answered, the verify compared only the chip form and
# called the RIGHT passphrase wrong -- a lockout with a factory reset as the only exit, and no device-owner key, so every
# unassigned-SIM arrival was lost. And a phone whose stored check is the chip form said "wrong passphrase" while the chip
# was silent. OwnerVerifyForm (pure, no android.* import) is compiled here with its cases; the source checks over
# ChooserActivity pin what the cases cannot see: the attempt is counted BEFORE the derive, verifyOwner's one
# OwnerVerifyForm.check comes after it (changeOwnerPass's re-check is the only other, NWP-20261126-20), ENSURE is sent only on a match, -6 only for CHIP_DOWN, and both screens say "try again" for it.
# test-owner-conf.sh pins verifyOwner byte for byte; this suite says why each part is shaped as it is.
#
# THE SETUP HALF (NWP-20261108-11). enrollOwner derived once: a chip that did not answer at setup silently stored the
# weaker, offline-guessable PBKDF2 form (or the chip form with no pepper), minted no key, and the screen said only
# "device passphrase set". It now asks the chip twice more with the SAME salt before it writes -- a fresh salt would put
# on disk a salt the stored check was not derived with -- never refuses for it (setup is mandatory), and returns
# OwnerVerifyForm.enrolResult so the gate shows ENROL_NO_CHIP_LINE for a chip still silent, and only then. The cases pin
# enrolResult and the line; the source checks pin the loop's bound, its salt, its place before the write, and the screen.
#
# THE LOST KEY (NWP-20261120-04, #26 of docs/product-decisions.md 2026-10-22). ownerSeMac minted a NEW StrongBox key
# whenever the `nowhere_owner` alias was missing, on every caller, so a chip that lost the key answered with an HMAC
# that matched neither stored form: "wrong passphrase" to the right passphrase, forever, each try counted. The decision
# names exactly two signals: the Keystore reports the alias missing, or owner.conf's key-check value (kcv, the key's
# HMAC of OwnerConf.KCV_CONST) no longer matches. verifyOwner now answers -7 for them before the wait, the count and the
# derive, and the screen opens re-setup. The cases pin OwnerVerifyForm.lostKey (UNKNOWN, a silent chip, an FP3 and a
# conf with no kcv are never lost) and OwnerConf.body read back by ChooserActivity's own readOwnerConf, lifted into
# LiftedConf; the source checks pin the order in verifyOwner, ownerAliasState's catch, ownerSeMac's create flag, each
# caller's flag, the enrol's kcv and the -7 screen.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-owner-verify-form-java.sh            # the cases and the source checks
#   bash test-owner-verify-form-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SUT_OVF="$root/core/chooser/src/com/nowhere/chooser/OwnerVerifyForm.java"
SUT_CA="$root/core/chooser/src/com/nowhere/chooser/ChooserActivity.java"
SUT_OC="$root/core/chooser/src/com/nowhere/chooser/OwnerConf.java"
CASES="$root/core/chooser/tests/owner-verify-form/OwnerVerifyFormCases.java"
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
[ -f "$SUT_CA" ] || { echo "FAIL: missing $SUT_CA" >&2; exit 2; }
[ -f "$SUT_OC" ] || { echo "FAIL: missing $SUT_OC" >&2; exit 2; }

# The android.* members OwnerConf.java imports, as stubs (OwnerConf.write is not run here; test-owner-conf.sh pins it).
STUBS="$W/stubs"
mkdir -p "$STUBS/android/system" "$STUBS/android/util"
cat > "$STUBS/android/system/Os.java" <<'EOF'
package android.system;
public final class Os {
    public static void rename(String a, String b) throws Exception {}
    public static java.io.FileDescriptor open(String p, int f, int m) throws Exception { return new java.io.FileDescriptor(); }
    public static void fsync(java.io.FileDescriptor d) throws Exception {}
    public static void close(java.io.FileDescriptor d) throws Exception {}
}
EOF
cat > "$STUBS/android/system/OsConstants.java" <<'EOF'
package android.system;
public final class OsConstants { public static final int O_RDONLY = 0; }
EOF
cat > "$STUBS/android/util/Log.java" <<'EOF'
package android.util;
public final class Log {
    public static int e(String t, String m) { return 0; }
    public static int w(String t, String m) { return 0; }
    public static int i(String t, String m) { return 0; }
}
EOF

bad=0
chk() { # chk <description> <0|1 ok>
  if [ "$2" = 1 ]; then echo "  ok    $1"; else echo "  FAIL  $1"; bad=$((bad+1)); fi
}
# lineno <text> <fixed string> -> the first 1-based line holding it, or 0.
lineno() { local n; n=$(printf '%s\n' "$1" | grep -nF -- "$2" | head -1 | cut -d: -f1); echo "${n:-0}"; }
# count <text> <fixed string> -> how many lines hold it.
count() { local n; n=$(printf '%s\n' "$1" | grep -cF -- "$2"); echo "$n"; }
# method <text> <signature fragment> -> from the signature to the first line closing it at the class's method indent.
method() { printf '%s\n' "$1" | awk -v sig="$2" 'index($0, sig) { on = 1 } on { print } on && /^    }$/ { exit }'; }

# srcchecks <ChooserActivity.java>: the source-level properties of verifyOwner and the two screens.
srcchecks() {
  local ca="$1" code vb vc l_count l_derive l_check blk l_ens l_ret n m verb chg ln logs rest
  local eb ec enr l_d1 l_for l_sleep l_d2 l_guard l_write l_read l_new l_eret l_set l_nochip l_fail
  local l_lost l_wait l_kcv l_ew as smac l_ca l_cr l_gen ib cp lks cpc
  code=$(grep -v '^[[:space:]]*//' "$ca")
  vb=$(method "$code" 'private int verifyOwner(String pass)')
  [ -n "$vb" ] || { chk "verifyOwner is in ChooserActivity" 0; return; }
  vc=$(printf '%s\n' "$vb" | sed -E 's# // .*$##')

  l_count=$(lineno "$vb" 'fails + 1')
  l_derive=$(lineno "$vb" 'OwnerDerived d = ownerDerive(pass, owUnhex(c.get("salt")), kcv.isEmpty());')
  l_check=$(lineno "$vb" 'OwnerVerifyForm.check(')
  l_lost=$(lineno "$vb" 'if (OwnerVerifyForm.lostKey(')
  l_wait=$(lineno "$vb" 'owWaitSecs(')
  if [ "$l_count" -gt 0 ] && [ "$l_derive" -gt "$l_count" ] && [ "$l_check" -gt "$l_derive" ]; then
    chk "the attempt is counted, then the passphrase derived, then the form checked" 1
  else
    chk "count/derive/check out of order or missing (count $l_count, derive $l_derive, check $l_check)" 0
  fi
  cpc=$(method "$code" 'private int changeOwnerPass(String oldPass, String newPass)')
  if [ "$(count "$vb" 'fails + 1')" = 1 ] && [ "$(count "$vb" 'OwnerVerifyForm.check(')" = 1 ] \
     && [ "$(count "$cpc" 'OwnerVerifyForm.check(')" = 1 ] && [ "$(count "$code" 'OwnerVerifyForm.check(')" = 2 ]; then
    chk "one count, and two OwnerVerifyForm.check in the whole activity: verifyOwner's and changeOwnerPass's re-check (NWP-20261126-20)" 1
  else
    chk "the attempt is counted, or the form checked, more or less often than verifyOwner once and changeOwnerPass once" 0
  fi

  # NWP-20261120-04 (#26): the lost key is told before the wait, the count and the derive, logged, and answers -7.
  if [ "$l_lost" -gt 0 ] && [ "$l_wait" -gt "$l_lost" ] && [ "$l_count" -gt "$l_wait" ] && [ "$l_derive" -gt "$l_count" ] \
     && [ "$(count "$code" 'OwnerVerifyForm.lostKey(')" = 1 ]; then
    chk "verifyOwner calls OwnerVerifyForm.lostKey once, before the wait, the count and the derive" 1
  else
    chk "the lost-key check is missing, repeated or not first (lost key $l_lost, wait $l_wait, count $l_count, derive $l_derive)" 0
  fi
  lks=$(printf '%s\n' "$vb" | sed -n "$((l_lost + 1)),$((l_lost + 3))p" | sed -E 's/^[[:space:]]+//')
  if [ "$l_lost" -gt 0 ] && [ "$lks" = "$(printf '%s\n' 'android.util.Log.w("NowhereChooser", "owner verify: the security chip'"'"'s owner key is gone (" + (alias == OwnerVerifyForm.ALIAS_MISSING ? "alias missing" : "key changed") + ") -> re-setup (#26)");' 'return -7;' '}')" ] \
     && [ "$(count "$vc" 'return -7;')" = 1 ] && [ "$(count "$vc" 'int alias = ownerAliasState();')" = 1 ] \
     && [ "$(count "$vc" 'kcv, alias, alias == OwnerVerifyForm.ALIAS_PRESENT ? ownerKcv() : "")) {')" = 1 ]; then
    chk "a lost key logs its reason (no value) and returns -7, once; kcvNow is asked of the chip only when the alias is there" 1
  else
    chk "the lost-key branch does not log then return -7 alone, or lostKey is not given the alias state and kcv" 0
  fi
  if [ "$(count "$vc" 'fails + 1, android.os.SystemClock.elapsedRealtime(), kcv)) return -3;')" = 1 ]; then
    chk "the counted write keeps the conf's kcv" 1
  else
    chk "the counted write drops or changes the conf's kcv" 0
  fi
  if [ "$(count "$vc" ', 0, 0, kcv.isEmpty() && !d.chipHex.isEmpty() ? ownerKcv() : kcv);')" = 1 ]; then
    chk "a matched verify keeps the kcv, and a conf with no kcv gains one when the chip answered" 1
  else
    chk "the matched write does not keep the kcv, or a legacy conf never gains one" 0
  fi

  # ownerAliasState: PRESENT or MISSING only from a completed load + containsAlias; every throw is UNKNOWN.
  as=$(method "$code" 'private static int ownerAliasState()')
  l_ca=$(lineno "$as" 'ks.load(null);'); l_cr=$(lineno "$as" 'return ks.containsAlias("nowhere_owner") ? OwnerVerifyForm.ALIAS_PRESENT : OwnerVerifyForm.ALIAS_MISSING;')
  if [ -n "$as" ] && [ "$l_ca" -gt 0 ] && [ "$l_cr" -gt "$l_ca" ] && [ "$(count "$as" 'ALIAS_MISSING')" = 1 ] \
     && [ "$(count "$as" 'catch')" = 1 ] && [ "$(count "$as" '} catch (Throwable t) { return OwnerVerifyForm.ALIAS_UNKNOWN; }')" = 1 ]; then
    chk "ownerAliasState answers MISSING only from a completed containsAlias, and maps every throw to UNKNOWN" 1
  else
    chk "ownerAliasState answers MISSING some other way, or a throw is not UNKNOWN" 0
  fi
  # ownerSeMac mints the alias only under its create flag; ownerKcv never does.
  smac=$(method "$code" 'private String ownerSeMac(byte[] input, boolean create)')
  l_gen=$(lineno "$smac" 'kg.generateKey();')
  n=$(printf '%s\n' "$smac" | grep -nF 'if (!ks.containsAlias(alias)) {' | head -1 | cut -d: -f1); n=${n:-0}
  if [ -n "$smac" ] && [ "$n" -gt 0 ] && [ "$(printf '%s\n' "$smac" | sed -n "$((n + 1))p" | sed -E 's/^[[:space:]]+//')" = 'if (!create) return "";' ] \
     && [ "$l_gen" -gt "$((n + 1))" ] && [ "$(count "$smac" 'generateKey(')" = 1 ]; then
    chk "ownerSeMac generates the owner key only when create is true" 1
  else
    chk "ownerSeMac generates the owner key without its create flag" 0
  fi
  if [ "$(count "$code" 'private String ownerKcv() { return ownerSeMac(OwnerConf.KCV_CONST.getBytes(java.nio.charset.StandardCharsets.UTF_8), false); }')" = 1 ] \
     && [ "$(count "$code" 'ownerSeMac(')" = 3 ] && [ "$(count "$code" 'String se = ownerSeMac(dk, create);')" = 1 ]; then
    chk "ownerKcv HMACs KCV_CONST with create=false; ownerDerive passes its own flag; nothing else calls ownerSeMac" 1
  else
    chk "ownerKcv may mint the key, or ownerSeMac has another caller" 0
  fi
  ib=$(method "$code" 'private String ownerInboxReq(String verb, String tail)')
  cp=$(method "$code" 'private int changeOwnerPass(String oldPass, String newPass)')
  if [ "$(count "$ib" 'OwnerDerived d = ownerDerive(pass, owUnhex(c.get("salt")), false);')" = 1 ] && [ "$(count "$ib" 'ownerDerive(')" = 1 ] \
     && [ "$(count "$cp" 'ownerDerive(')" = 2 ] && [ "$(printf '%s\n' "$cp" | grep -F 'ownerDerive(' | grep -cF ', false);')" = 2 ] \
     && [ "$(count "$code" 'ownerDerive(')" = 7 ]; then
    chk "ownerInboxReq and changeOwnerPass's two derives never mint the owner key (create=false)" 1
  else
    chk "ownerInboxReq or changeOwnerPass derives with create=true, or a derive was added" 0
  fi
  if [ "$(count "$cp" 'writeOwnerConf(owHex(newSalt), dNew.verifier, 0, 0, c.getOrDefault("kcv", ""));')" = 1 ]; then
    chk "a passphrase change keeps the conf's kcv" 1
  else
    chk "a passphrase change drops the conf's kcv" 0
  fi

  blk=$(printf '%s\n' "$vb" | awk '/if \(OwnerVerifyForm\.matched\(o\)\) \{/ { on = 1 } on { print } on && /^        }$/ { exit }')
  l_ens=$(lineno "$blk" 'ownerKeyAsync("OWNER-KEY-ENSURE", pass, d);'); l_ret=$(lineno "$blk" 'return 0;')
  if [ "$(count "$vb" 'ownerKeyAsync("OWNER-KEY-ENSURE", pass, d);')" = 1 ] && [ "$l_ens" -gt 0 ] && [ "$l_ret" -gt "$l_ens" ]; then
    chk "ENSURE is sent only inside the matched block, before it returns 0" 1
  else
    chk "ENSURE is sent outside the matched block (in block $l_ens, return $l_ret)" 0
  fi

  m=$(printf '%s\n' "$vc" | grep -F -- '-6' || true)
  if [ "$(printf '%s\n' "$vc" | grep -cF -- '-6')" = 1 ] \
     && [ "$(printf '%s' "$m" | sed -E 's/^[[:space:]]+//')" = 'if (o == OwnerVerifyForm.Outcome.CHIP_DOWN) { d.clear(); return -6; }' ]; then
    chk "-6 is returned only for CHIP_DOWN, and sends no key request and writes nothing" 1
  else
    chk "-6 is returned for something other than CHIP_DOWN alone, or does more than clear" 0
  fi

  verb=$(method "$code" 'private View buildOwnerVerifyScreen(final int dest)')
  chg=$(method "$code" 'private View buildOwnerChangePassScreen()')
  n=0
  if [ -n "$verb" ] && [ "$(printf '%s\n' "$verb" | grep 'StatusLine.error(msg, ' | grep -cF 'r == -6 ? OwnerVerifyForm.CHIP_DOWN_LINE : ')" = 1 ]; then n=$((n+1)); fi
  if [ -n "$chg" ] && [ "$(printf '%s\n' "$chg" | grep 'StatusLine.error(msg, ' | grep -cF 'r == -6 ? OwnerVerifyForm.CHIP_DOWN_LINE : ')" = 1 ]; then n=$((n+1)); fi
  if [ "$n" = 2 ] && [ "$(count "$code" 'r == -6 ? OwnerVerifyForm.CHIP_DOWN_LINE : ')" = 2 ]; then
    chk "both screens map -6 to CHIP_DOWN_LINE, and nothing else does" 1
  else
    chk "a screen does not map -6 to CHIP_DOWN_LINE (screens carrying it: $n)" 0
  fi

  # NWP-20261108-11: the enrol retries a silent chip, bounded, with the same salt, before the write; never refuses for it.
  eb=$(method "$code" 'private int enrollOwner(String pass)')
  if [ -z "$eb" ]; then
    chk "enrollOwner(String) returns an int (the enrol result) in ChooserActivity" 0
  else
    ec=$(printf '%s\n' "$eb" | sed -E 's# // .*$##')
    l_d1=$(lineno "$ec" 'OwnerDerived d = ownerDerive(pass, salt, true);')
    l_for=$(lineno "$ec" 'for (int retry = 0; d.seBroken && retry < 2; retry++) {')
    l_sleep=$(lineno "$ec" 'Thread.sleep(500);')
    l_d2=$(printf '%s\n' "$ec" | grep -nE '^[[:space:]]*d = ownerDerive\(pass, salt, true\);$' | head -1 | cut -d: -f1); l_d2=${l_d2:-0}
    l_guard=$(lineno "$ec" 'if (d.verifier.isEmpty()) { d.clear(); return OwnerVerifyForm.ENROL_FAILED; }')
    l_write=$(lineno "$ec" 'writeOwnerConf(')
    l_kcv=$(lineno "$ec" 'String kcv = d.chipHex.isEmpty() ? "" : ownerKcv();')
    l_ew=$(lineno "$ec" 'writeOwnerConf(owHex(salt), d.verifier, 0, 0, kcv);')
    if [ "$l_kcv" -gt "$(lineno "$ec" 'if (d.verifier.isEmpty())')" ] && [ "$l_ew" -gt "$l_kcv" ] && [ "$l_ew" = "$l_write" ]; then
      chk "enrollOwner writes the chip key's kcv (none for a silent chip) with the new check" 1
    else
      chk "enrollOwner writes no kcv, or computes it in the wrong place (kcv $l_kcv, write $l_ew)" 0
    fi
    l_read=$(lineno "$ec" 'readOwnerConf()')
    l_new=$(lineno "$ec" 'if (ok) ownerKeyAsync("OWNER-KEY-NEW", pass, d); else d.clear();')
    l_eret=$(lineno "$ec" 'return OwnerVerifyForm.enrolResult(ok, d.seBroken);')
    if [ "$l_d1" -gt 0 ] && [ "$l_for" -gt "$l_d1" ] && [ "$l_sleep" -gt "$l_for" ] && [ "$l_d2" -gt "$l_sleep" ] \
       && [ "$l_guard" -gt "$l_d2" ] && [ "$l_write" -gt "$l_guard" ] && [ "$l_read" -gt "$l_write" ] \
       && [ "$l_new" -gt "$l_read" ] && [ "$l_eret" -gt "$l_new" ]; then
      chk "enrollOwner derives, retries a silent chip (sleep, same-salt derive), guards, writes, reads back, NEW, returns enrolResult" 1
    else
      chk "enrollOwner out of order or missing a step (derive $l_d1, retry $l_for, sleep $l_sleep, re-derive $l_d2, guard $l_guard, write $l_write, read $l_read, NEW $l_new, return $l_eret)" 0
    fi
    if [ "$(count "$ec" 'retry < 2')" = 1 ] && [ "$(count "$ec" 'for (')" = 1 ] && [ "$(count "$ec" 'while')" = 0 ]; then
      chk "the enrol retry is one loop, bounded by a literal 2" 1
    else
      chk "the enrol retry is not one loop bounded by a literal 2" 0
    fi
    if [ "$(count "$ec" 'ownerDerive(')" = 2 ] && [ "$(count "$ec" 'ownerDerive(pass, salt, true)')" = 2 ] \
       && [ "$(count "$ec" 'nextBytes(')" = 1 ] && [ "$(count "$ec" 'salt = ')" = 1 ] \
       && [ "$(lineno "$ec" 'salt = ')" = "$(lineno "$ec" 'byte[] salt = new byte[16]; new java.security.SecureRandom().nextBytes(salt);')" ]; then
      chk "the enrol re-derives with the one salt it made, never a new one" 1
    else
      chk "the enrol re-derives with a different salt, or derives more than twice" 0
    fi
    if [ "$(count "$ec" 'writeOwnerConf(')" = 1 ] && [ "$(count "$ec" 'readOwnerConf()')" = 1 ] \
       && [ "$(count "$ec" 'OWNER-KEY-NEW')" = 1 ] && [ "$(count "$ec" 'ENROL_FAILED')" = 1 ] \
       && [ "$(printf '%s\n' "$ec" | grep -cE '^[[:space:]]*(if \(.*\) \{ .*)?return ')" = 2 ] \
       && [ "$(count "$ec" 'seBroken')" = 2 ]; then
      chk "one write, one read-back, one NEW; FAILED only for an empty check, so a silent chip is never refused" 1
    else
      chk "enrollOwner writes, reads back or sends NEW more than once, or refuses on something else (a silent chip?)" 0
    fi
  fi
  enr=$(method "$code" 'private View buildOwnerEnrollScreen(final boolean firstRun)')
  l_set=$(lineno "$enr" 'result.setText("device passphrase set");')
  l_nochip=$(printf '%s\n' "$enr" | grep -nF 'ENROL_NO_CHIP_LINE' | head -1 | cut -d: -f1); l_nochip=${l_nochip:-0}
  l_fail=$(lineno "$enr" "couldn't set the passphrase — try again")
  m=$(printf '%s\n' "$enr" | grep -F 'ENROL_NO_CHIP_LINE' | sed -E 's/^[[:space:]]+//' || true)
  if [ "$(count "$enr" 'final int r = enrollOwner(a);')" = 1 ] && [ "$(count "$enr" 'if (r != OwnerVerifyForm.ENROL_FAILED) {')" = 1 ] \
     && [ "$m" = 'if (r == OwnerVerifyForm.ENROL_OK_NO_CHIP) { result.setTextColor(ACCENT); result.setText(OwnerVerifyForm.ENROL_NO_CHIP_LINE); }' ] \
     && [ "$(count "$code" 'ENROL_NO_CHIP_LINE')" = 1 ] && [ "$(count "$enr" "couldn't set the passphrase — try again")" = 1 ] \
     && [ "$l_set" -gt 0 ] && [ "$l_nochip" -gt "$l_set" ] && [ "$l_fail" -gt "$l_nochip" ]; then
    chk "the Set handler shows ENROL_NO_CHIP_LINE after a success, only for ENROL_OK_NO_CHIP" 1
  else
    chk "the Set handler shows ENROL_NO_CHIP_LINE for something other than ENROL_OK_NO_CHIP alone, or out of place (set $l_set, no-chip $l_nochip, fail $l_fail)" 0
  fi

  # NWP-20261120-04: the verify screen opens re-setup on -7; the change screen says why.
  if [ "$(printf '%s\n' "$verb" | grep -cF 'else if (r == -7) setContentView(buildOwnerLostKeyScreen());')" = 1 ] \
     && [ "$(count "$code" 'setContentView(buildOwnerLostKeyScreen())')" = 1 ] \
     && [ "$(printf '%s\n' "$chg" | grep 'StatusLine.error(msg, ' | grep -cF 'r == -7 ? OwnerVerifyForm.LOST_KEY_LINE : ')" = 1 ]; then
    chk "the verify screen maps -7 to buildOwnerLostKeyScreen, and the change screen to LOST_KEY_LINE" 1
  else
    chk "the verify screen does not open buildOwnerLostKeyScreen on -7, or the change screen does not say LOST_KEY_LINE" 0
  fi
  lks=$(method "$code" 'private View buildOwnerLostKeyScreen()')
  if [ "$(count "$lks" 't.setText(OwnerVerifyForm.LOST_KEY_TITLE);')" = 1 ] && [ "$(count "$lks" 'sub.setText(OwnerVerifyForm.LOST_KEY_LINE);')" = 1 ] \
     && [ "$(count "$lks" 'accentButton(')" = 1 ] && [ "$(count "$lks" 'accentButton("Set a new device passphrase")')" = 1 ] \
     && [ "$(count "$lks" 'set.setOnClickListener(v -> setContentView(buildOwnerEnrollScreen(false)));')" = 1 ] \
     && [ "$(count "$lks" 'emergencyLink()')" = 1 ] && [ "$(count "$lks" 'setOnClickListener(')" = 1 ]; then
    chk "the re-setup screen: LOST_KEY_TITLE, LOST_KEY_LINE, one button to the enrol, and the emergency link" 1
  else
    chk "the re-setup screen lacks its title, its line, its one enrol button or the emergency link" 0
  fi

  logs=$( { printf '%s\n' "$vc"; printf '%s\n' "${ec:-}"; } | grep -F 'Log.' || true)
  rest=$(printf '%s\n' "$logs" | sed -E 's/^.*Log\./Log./; s/"[^"]*"//g')
  if printf '%s\n' "$rest" | grep -E 'pass|chipHex|pbkdfHex|verifier|toStore|c\.get|kcv|Kcv' >/dev/null; then
    chk "a verifyOwner or enrollOwner log line carries a passphrase, a hash or the stored check" 0
  else
    chk "no verifyOwner or enrollOwner log line carries a passphrase, a hash or the stored check" 1
  fi
}

# suite <OwnerVerifyForm.java> <ChooserActivity.java> <OwnerConf.java> -> 0 pass, 1 a case or a source check failed or the class is
# missing (the only codes that convict a mutant), 3 the class or the cases did not compile.
suite() {
  local src="$1" ca="$2" oc="$3" d out rc rd
  [ -f "$src" ] || { echo "  FAIL  OwnerVerifyForm.java does not exist (the change is not built)" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$src" "$d/src/com/nowhere/chooser/OwnerVerifyForm.java"
  cp "$oc" "$d/src/com/nowhere/chooser/OwnerConf.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/OwnerVerifyFormCases.java"
  # NWP-20261120-04: ChooserActivity's own readOwnerConf, lifted; a missing one fails here, never as a compile error.
  rd=$(method "$(cat "$ca")" 'private java.util.HashMap<String, String> readOwnerConf()')
  if [ -z "$rd" ]; then echo "  FAIL  readOwnerConf() is not in ChooserActivity"; rm -rf "$d"; return 1; fi
  { printf '%s\n' 'package com.nowhere.chooser;' 'final class LiftedConf {' '    private final java.io.File f;' \
      '    LiftedConf(java.io.File f) { this.f = f; }' '    private java.io.File ownerConf() { return f; }'
    printf '%s\n' "$rd"
    printf '%s\n' '    java.util.HashMap<String, String> read() { return readOwnerConf(); }' '}'; } > "$d/src/com/nowhere/chooser/LiftedConf.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java "$STUBS"/android/system/*.java "$STUBS"/android/util/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.OwnerVerifyFormCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  bad=0
  srcchecks "$ca"
  [ "$rc" -eq 0 ] && [ "$bad" -eq 0 ] && return 0
  return 1
}

echo "== $SUT_OVF"
suite "$SUT_OVF" "$SUT_CA" "$SUT_OC" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not compile proves nothing)"
mut() { # mut <label> <OVF|CA|OC> <perl-expr>
  local d c rc orig ovf ca oc; d=$(mktemp -d -p "$W") || return 1
  ovf="$SUT_OVF"; ca="$SUT_CA"; oc="$SUT_OC"
  case "$2" in
    OVF) c="$d/OwnerVerifyForm.java"; orig="$SUT_OVF" ;;
    OC) c="$d/OwnerConf.java"; orig="$SUT_OC" ;;
    *) c="$d/ChooserActivity.java"; orig="$SUT_CA" ;;
  esac
  cp "$orig" "$c"
  if ! perl -0pi -e "$3" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  case "$2" in OVF) ovf="$c" ;; OC) oc="$c" ;; *) ca="$c" ;; esac
  suite "$ovf" "$ca" "$oc" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "toStore never upgrades" OVF 's/o == Outcome\.UPGRADE \? chipHex : stored/stored/' || fails=$((fails+1))
mut "a silent chip with no match on a StrongBox phone is WRONG, not CHIP_DOWN" OVF 's/strongBox \? Outcome\.CHIP_DOWN : Outcome\.WRONG/Outcome.WRONG/' || fails=$((fails+1))
mut "a PBKDF2 match while the chip answers is WRONG, not UPGRADE" OVF 's/pbkdfEq \? Outcome\.UPGRADE : Outcome\.WRONG/Outcome.WRONG/' || fails=$((fails+1))
mut "strongBox is ignored when the chip is silent" OVF 's/strongBox \? Outcome\.MATCH_NO_CHIP : Outcome\.MATCH/Outcome.MATCH/' || fails=$((fails+1))
mut "the counted write moved after the derive" CA 's/(        if \(!writeOwnerConf\(c\.get\("salt"\), c\.get\("verifier"\), fails \+ 1, [^\n]*\n)(        OwnerDerived d = ownerDerive\(pass, owUnhex\(c\.get\("salt"\)\), kcv\.isEmpty\(\)\);[^\n]*\n)/$2$1/' || fails=$((fails+1))
mut "ENSURE added to the -6 return" CA 's/\{ d\.clear\(\); return -6; \}/{ ownerKeyAsync("OWNER-KEY-ENSURE", pass, d); return -6; }/' || fails=$((fails+1))
mut "the verify screen's -6 mapping removed" CA 's/r == -6 \? OwnerVerifyForm\.CHIP_DOWN_LINE : //' || fails=$((fails+1))
mut "the change screen's -6 mapping removed" CA 's/(r == -6 \? OwnerVerifyForm\.CHIP_DOWN_LINE : )(OwnerPassChange\.UNCHANGED_MSG)/$2/' || fails=$((fails+1))
mut "the enrol retry loop removed" CA 's/\n        for \(int retry = 0; d\.seBroken && retry < 2; retry\+\+\) \{\n.*?\n        \}\n/\n/s' || fails=$((fails+1))
mut "the enrol retry unbounded" CA 's/d\.seBroken && retry < 2; retry\+\+/d.seBroken; retry++/' || fails=$((fails+1))
mut "a new salt per enrol retry" CA 's/(Thread\.sleep\(500\);[^\n]*\n\s*)d = ownerDerive\(pass, salt, true\);/$1new java.security.SecureRandom().nextBytes(salt); d = ownerDerive(pass, salt, true);/' || fails=$((fails+1))
mut "NO_CHIP reported as OK (enrolResult)" OVF 's/noChip \? ENROL_OK_NO_CHIP : ENROL_OK/ENROL_OK/' || fails=$((fails+1))
mut "NO_CHIP reported as OK (enrollOwner)" CA 's/enrolResult\(ok, d\.seBroken\)/enrolResult(ok, false)/' || fails=$((fails+1))
mut "the no-chip line shown for every success" CA 's/if \(r == OwnerVerifyForm\.ENROL_OK_NO_CHIP\) \{ ([^\n]*) \}/{ $1 }/' || fails=$((fails+1))
mut "a no-chip enrol refused (enrollOwner)" CA 's/if \(d\.verifier\.isEmpty\(\)\) \{ d\.clear\(\); return OwnerVerifyForm\.ENROL_FAILED/if (d.verifier.isEmpty() || d.seBroken) { d.clear(); return OwnerVerifyForm.ENROL_FAILED/' || fails=$((fails+1))
mut "a no-chip enrol refused (enrolResult)" OVF 's/!onDisk \? ENROL_FAILED/!onDisk || noChip ? ENROL_FAILED/' || fails=$((fails+1))
mut "the enrol retry moved after the write" CA 's/(\n        for \(int retry = 0; d\.seBroken && retry < 2; retry\+\+\) \{\n.*?\n        \}\n)(.*?        writeOwnerConf\(owHex\(salt\), d\.verifier, 0, 0, kcv\);\n)/\n$2$1/s' || fails=$((fails+1))
mut "an enrol retry log names the passphrase" CA 's/" of 2"\)/" of 2" + pass)/' || fails=$((fails+1))
mut "a log line names the chip hash" CA 's/"owner verifier upgraded to the chip-bound form"/"owner verifier upgraded " + d.chipHex/' || fails=$((fails+1))
# NWP-20261120-04 (#26): the lost chip key.
mut "lostKey ignoring the stored-kcv guard" OVF 's/ \|\| storedKcv == null \|\| storedKcv\.isEmpty\(\)//' || fails=$((fails+1))
mut "lostKey treating a silent chip as lost" OVF 's/ && kcvNow != null && !kcvNow\.isEmpty\(\)//' || fails=$((fails+1))
mut "lostKey treating UNKNOWN as MISSING" OVF 's/aliasState == ALIAS_MISSING\) return true/aliasState != ALIAS_PRESENT) return true/' || fails=$((fails+1))
mut "lostKey without StrongBox" OVF 's/if \(!strongBox \|\| /if (/' || fails=$((fails+1))
mut "lostKey calling an equal kcv lost" OVF 's/!constEq\(kcvNow, storedKcv\)/constEq(kcvNow, storedKcv)/' || fails=$((fails+1))
mut "ownerAliasState's catch returning MISSING" CA 's/return OwnerVerifyForm\.ALIAS_UNKNOWN; \}/return OwnerVerifyForm.ALIAS_MISSING; }/' || fails=$((fails+1))
mut "the -7 check moved after the count" CA 's/(        int alias = ownerAliasState\(\);\n.*?\n            return -7;\n        \}\n)(.*?fails \+ 1, [^\n]*\n)/$2$1/s' || fails=$((fails+1))
mut "ownerSeMac creating unconditionally" CA 's/\n                if \(!create\) return "";//' || fails=$((fails+1))
mut "writeOwnerConf dropping kcv on the counter write" CA 's/elapsedRealtime\(\), kcv\)\) return -3;/elapsedRealtime(), "")) return -3;/' || fails=$((fails+1))
mut "ownerInboxReq derives with create=true" CA 's/(OwnerDerived d = ownerDerive\(pass, owUnhex\(c\.get\("salt"\)\)), false\);(\n        if \(d\.seBroken\) \{ d\.clear\(\); return null; \})/$1, true);$2/' || fails=$((fails+1))
mut "changeOwnerPass's new derive with create=true" CA 's/ownerDerive\(newPass, newSalt, false\)/ownerDerive(newPass, newSalt, true)/' || fails=$((fails+1))
mut "a passphrase change drops the kcv" CA 's/dNew\.verifier, 0, 0, c\.getOrDefault\("kcv", ""\)\)/dNew.verifier, 0, 0, "")/' || fails=$((fails+1))
mut "enrollOwner writes no kcv" CA 's/writeOwnerConf\(owHex\(salt\), d\.verifier, 0, 0, kcv\);/writeOwnerConf(owHex(salt), d.verifier, 0, 0, "");/' || fails=$((fails+1))
mut "a legacy conf never gains a kcv" CA 's/, 0, 0, kcv\.isEmpty\(\) && !d\.chipHex\.isEmpty\(\) \? ownerKcv\(\) : kcv\);/, 0, 0, kcv);/' || fails=$((fails+1))
mut "the verify screen's -7 mapping removed" CA 's/\n *else if \(r == -7\) setContentView\(buildOwnerLostKeyScreen\(\)\);[^\n]*//' || fails=$((fails+1))
mut "the re-setup button opens the menu, not the enrol" CA 's/set\.setOnClickListener\(v -> setContentView\(buildOwnerEnrollScreen\(false\)\)\);/set.setOnClickListener(v -> setContentView(buildOwnerMenu()));/' || fails=$((fails+1))
mut "OwnerConf.body emits kcv= when empty" OC 's/\(kcv == null \|\| kcv\.isEmpty\(\) \? "" : "kcv=" \+ kcv \+ "\\n"\)/("kcv=" + kcv + "\\n")/' || fails=$((fails+1))
mut "OwnerConf.body drops the kcv" OC 's/: "kcv=" \+ kcv \+ "\\n"\)/: "")/' || fails=$((fails+1))
mut "readOwnerConf accepts a damaged kcv" CA 's/\n                && \(!m\.containsKey\("kcv"\) \|\| m\.get\("kcv"\)\.matches\("\[0-9a-f\]\{64\}"\)\)\)/)/' || fails=$((fails+1))
mut "the lost-key log names the stored kcv" CA 's/"\) -> re-setup \(#26\)"\)/") -> re-setup (#26)" + kcv)/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
