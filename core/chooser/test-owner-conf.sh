#!/usr/bin/env bash
# test-owner-conf.sh [<chooser src dir>] [--mutate] -- owner.conf is written atomically, a verify that cannot count
# its attempt is refused, and a damaged file says so (NWP-20260930-03).
#
# WHY THIS IS COMMITTED. owner.conf holds the device passphrase's salt, verifier and failure count. It used to be
# truncated and rewritten in place at every enrol and verify, so a crash could leave it empty -- the next boot then
# sends the gate to the required enrol, which mints a new device-owner key under whoever holds the phone -- or
# cut before or inside its verifier, which the owner verify showed as "wrong passphrase": a lockout that looked like a
# typo. And the
# failure count was written only after a wrong passphrase had been checked, and a failed write was only logged, so
# the back-off could stop advancing. The chooser has no unit-test harness, so these are source-level checks; CI
# executes this suite and its --mutate run.
#
# HOW IT CHECKS. The four methods that decide these properties -- OwnerConf.write, writeOwnerConf, verifyOwner and
# readOwnerConf -- are PINNED BYTE FOR BYTE, comments included: a line check on a spelling passes a commented-out
# step, a swallowed failure or a log call split across lines, and each round of "catch that spelling too" found
# another (worklog.md, NWP-20260927-10). So any edit to one of them fails here, and the pin is updated
# with the edit, on purpose. The line checks below the pins say WHY each property matters, and each has a mutation
# that must convict the suite. A pinned method must occur exactly once, so a dead copy left in a comment cannot stand
# in for a changed one. What a pin cannot see is a new writer elsewhere: the reference checks count the file name, the
# uses of ownerConf(), and the callers of writeOwnerConf, readOwnerConf and verifyOwner, and pin the one-line
# ownerConf() and ownerSecretSet(); a name built to evade them (e.g. "owner" + ".conf") is beyond this suite.
#
#   bash test-owner-conf.sh            # the invariants
#   bash test-owner-conf.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SRC=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SRC="$a" ;; esac; done
SRC="${SRC:-$(dirname "$0")/src/com/nowhere/chooser}"
CA="$SRC/ChooserActivity.java"; OC="$SRC/OwnerConf.java"
for f in "$CA" "$OC"; do [ -f "$f" ] || { echo "no such file: $f" >&2; exit 2; }; done
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
# ⚠ Every match reads its input to the end: `grep -c ... >/dev/null`, never `grep -q` (see test-owner-key.sh).

# body <file> <signature fragment>: the method's lines, from its signature to the first line closing it at the class's
# method indent ("    }") -- or a marker that fails every pin when the signature does not occur exactly once.
body(){ [ "$(grep -cF -- "$2" "$1")" = 1 ] || { echo "<signature not exactly once: $2>"; return; }; awk -v sig="$2" 'index($0, sig) { on = 1 } on { print } on && /^    }$/ { exit }' "$1"; }
# field <file> <declaration fragment>: a constant's lines, from its declaration to the first line ending in ';' -- so a
# pin ties the VALUE to the constant, not just to the words appearing somewhere in the file (a second constant could hold them).
field(){ [ "$(grep -cF -- "$2" "$1")" = 1 ] || { echo "<declaration not exactly once: $2>"; return; }; awk -v sig="$2" 'index($0, sig) { on = 1 } on { print } on && /;[[:space:]]*$/ { exit }' "$1"; }
# line <text> <fixed string>: the 1-based line of its first match, or 0.
line(){ printf '%s\n' "$1" | grep -nF -- "$2" | head -1 | cut -d: -f1 | grep . || echo 0; }
# pin <name> <actual> <expected>
pin(){ if [ "$2" = "$3" ]; then ok "$1 is the pinned block"; else no "$1 differs from the pinned block"; fi; }

echo "== the pinned blocks (byte for byte, comments included) =="
X=$(body "$OC" 'static boolean write(File f, byte[] body)')
PIN_X=$(cat <<'PIN'
    static boolean write(File f, byte[] body) {
        File dir = f.getParentFile();
        File tmp = new File(dir, "." + f.getName() + ".tmp");
        try {
            try (FileOutputStream out = new FileOutputStream(tmp)) {
                out.write(body);
                out.getFD().sync();
            }
            Os.rename(tmp.getPath(), f.getPath());
        } catch (Throwable t) {
            tmp.delete();
            android.util.Log.e("NowhereChooser", "owner.conf write failed: " + t.getClass().getSimpleName());
            return false;
        }
        try {
            FileDescriptor d = Os.open(dir.getPath(), OsConstants.O_RDONLY, 0);
            try {
                Os.fsync(d);
            } finally {
                Os.close(d);
            }
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "owner.conf directory sync failed: " + t.getClass().getSimpleName());
        }
        return true;
    }
PIN
)
pin "OwnerConf.write" "$X" "$PIN_X"
WOC=$(body "$CA" 'private boolean writeOwnerConf(String saltHex, String verifier, int fails, long last, String kcv)')
PIN_W=$(cat <<'PIN'
    private boolean writeOwnerConf(String saltHex, String verifier, int fails, long last, String kcv) {
        String body = OwnerConf.body(saltHex, verifier, fails, last, kcv);
        // NWP-20260930-03: temp file, sync, rename, directory sync -- a crash never leaves it empty or half-written.
        return OwnerConf.write(ownerConf(), body.getBytes(java.nio.charset.StandardCharsets.UTF_8)); // never logs the body
    }
PIN
)
pin "writeOwnerConf" "$WOC" "$PIN_W"
V=$(body "$CA" 'private int verifyOwner(String pass)')
PIN_V=$(cat <<'PIN'
    private int verifyOwner(String pass) {
        // NWP-20261005-18: the shield opens verify even when no secret was ever set. That is not damage, and the
        // screen must not tell whoever tapped it that the phone has no owner yet -- answer as a wrong passphrase.
        if (!ownerSecretSet()) return -1;
        java.util.HashMap<String, String> c = readOwnerConf();
        if (c == null) return -2;
        String kcv = c.getOrDefault("kcv", ""); // NWP-20261120-04: "" for a conf written before the kcv, or by a silent chip
        // NWP-20261120-04 (#26, Q018): a lost chip key is told before the wait, the count and the derive; the passphrase is not read.
        int alias = ownerAliasState();
        if (OwnerVerifyForm.lostKey(getPackageManager().hasSystemFeature(android.content.pm.PackageManager.FEATURE_STRONGBOX_KEYSTORE), kcv, alias, alias == OwnerVerifyForm.ALIAS_PRESENT ? ownerKcv() : "")) {
            android.util.Log.w("NowhereChooser", "owner verify: the security chip's owner key is gone (" + (alias == OwnerVerifyForm.ALIAS_MISSING ? "alias missing" : "key changed") + ") -> re-setup (#26)");
            return -7;
        }
        int fails = 0; long last = 0;
        try { fails = Integer.parseInt(c.get("fails")); } catch (Throwable ig) {}
        try { last = Long.parseLong(c.get("last")); } catch (Throwable ig) {}
        int wait = owWaitSecs(fails, android.os.SystemClock.elapsedRealtime(), last); // NWP-20261011-39: per boot, not wall clock
        if (wait > 0) return wait;
        if (!writeOwnerConf(c.get("salt"), c.get("verifier"), fails + 1, android.os.SystemClock.elapsedRealtime(), kcv)) return -3; // NWP-20260930-03: counted before it is checked; uncountable = refused
        OwnerDerived d = ownerDerive(pass, owUnhex(c.get("salt")), kcv.isEmpty()); // NWP-20261120-04: mints the key only for a conf with no kcv (NWP-20261108-07's heal)
        OwnerVerifyForm.Outcome o = OwnerVerifyForm.check(c.get("verifier"), d.chipHex, d.pbkdfHex, d.strongBox);
        if (OwnerVerifyForm.matched(o)) {
            boolean kept = writeOwnerConf(c.get("salt"), OwnerVerifyForm.toStore(o, c.get("verifier"), d.chipHex), 0, 0, kcv.isEmpty() && !d.chipHex.isEmpty() ? ownerKcv() : kcv); // NWP-20261108-07: an UPGRADE stores the chip-bound form; NWP-20261120-04: a conf with no kcv gains one
            if (o == OwnerVerifyForm.Outcome.UPGRADE) android.util.Log.i("NowhereChooser", kept ? "owner verifier upgraded to the chip-bound form" : "owner verifier upgrade not written; the next verify retries it");
            ownerKeyAsync("OWNER-KEY-ENSURE", pass, d); // NWP-20260928-01: the heal for a device enrolled before the key
            return 0;
        }
        if (o == OwnerVerifyForm.Outcome.CHIP_DOWN) { d.clear(); return -6; } // NWP-20261108-07: counted, the form cannot be told
        d.clear();
        return -1;
    }
PIN
)
pin "verifyOwner" "$V" "$PIN_V"
R=$(body "$CA" 'private java.util.HashMap<String, String> readOwnerConf()')
PIN_R=$(cat <<'PIN'
    private java.util.HashMap<String, String> readOwnerConf() {
        java.util.HashMap<String, String> m = new java.util.HashMap<>();
        try (java.io.BufferedReader r = new java.io.BufferedReader(new java.io.FileReader(ownerConf()))) {
            String line;
            while ((line = r.readLine()) != null) { int eq = line.indexOf('='); if (eq > 0) m.put(line.substring(0, eq).trim(), line.substring(eq + 1).trim()); }
        } catch (Throwable t) { return null; }
        return (m.containsKey("salt") && m.get("salt").matches("[0-9a-f]{32}") && m.containsKey("verifier") && m.get("verifier").matches("[0-9a-f]{64}")
                && (!m.containsKey("kcv") || m.get("kcv").matches("[0-9a-f]{64}"))) ? m : null; // NWP-20260930-03: a damaged value is damage too; NWP-20261120-04: the kcv is optional
    }
PIN
)
pin "readOwnerConf" "$R" "$PIN_R"
DMG=$(field "$OC" 'static final String DAMAGED =')
PIN_DMG=$(cat <<'PIN'
    static final String DAMAGED =
            "this phone's passphrase file is damaged — the passphrase can't be checked."
            + " Erasing the phone is the only way back into Owner settings.";
PIN
)
pin "OwnerConf.DAMAGED" "$DMG" "$PIN_DMG"
NC=$(field "$OC" 'static final String NOT_COUNTED =')
PIN_NC=$(cat <<'PIN'
    static final String NOT_COUNTED = "can't check the passphrase right now — try again";
PIN
)
pin "OwnerConf.NOT_COUNTED" "$NC" "$PIN_NC"

echo "== owner.conf is reached only through ownerConf(), and written only through the atomic writer =="
if [ "$(grep -rhoF -- '"owner.conf"' "$SRC" | wc -l)" = 1 ]; then ok "the file name appears once, in ownerConf()"; else no "the file name owner.conf is used somewhere new"; fi
if [ "$(grep -rhoE -- '\bownerConf\(\)' "$SRC" | wc -l)" = 4 ]; then ok "ownerConf() is used only by its definition, ownerSecretSet, readOwnerConf and writeOwnerConf"; else no "ownerConf() is used somewhere new -- a second writer would bypass the atomic write"; fi
# readOwnerConf() is 4: its definition, the reads in enrollOwner and verifyOwner, and ownerInboxReq (NWP-20261001-02), which reads
# ONLY the salt to derive the StrongBox pepper for the owner-key unwrap from the already-verified session passphrase.
# It writes nothing and verifies nothing, so it is no uncounted guess path -- and the writeOwnerConf count below
# is what proves it adds no writer.
# NWP-20261022-01: changeOwnerPass (the device-passphrase change) adds one writeOwnerConf, two readOwnerConf and one
# verifyOwner, each a counted path. Its verifyOwner is the first statement, so the attempt is counted and backed off
# like any other verify; its one writer runs only after that verify matched and after a rewrap the daemon answered
# OK or NOKEY, and is read back; its two reads (the re-read for the salt and the read-back) write nothing and verify
# nothing. So the counts are exactly 5 writers, 6 readers and 3 verifyOwner callers.
if [ "$(grep -rhoE -- '\bwriteOwnerConf\(' "$SRC" | wc -l)" = 5 ] && [ "$(grep -rhoE -- '\breadOwnerConf\(\)' "$SRC" | wc -l)" = 6 ] && [ "$(grep -rhoE -- '\bverifyOwner\(' "$SRC" | wc -l)" = 3 ]; then
  ok "writeOwnerConf, readOwnerConf and verifyOwner have no new callers"
else
  no "a new caller of writeOwnerConf, readOwnerConf or verifyOwner -- it could write or clear the count outside the pins"
fi
if [ "$(grep -cxF -- '    private java.io.File ownerConf() { return new java.io.File(getFilesDir(), "owner.conf"); }' "$CA")" = 1 ] && [ "$(grep -cxF -- '    private boolean ownerSecretSet() { java.io.File f = ownerConf(); return f.exists() && f.length() > 0; }' "$CA")" = 1 ]; then
  ok "ownerConf() and ownerSecretSet() are the pinned lines"
else
  no "ownerConf() or ownerSecretSet() changed"
fi
if grep -rn -- 'openFileOutput("owner.conf' "$SRC" >/dev/null; then no "something truncates owner.conf in place with openFileOutput"; else ok "nothing truncates owner.conf in place"; fi

echo "== why the writer is shaped as it is =="
# Xc is the writer with its comment lines removed, so a commented-out step reads as absent.
Xc=$(printf '%s\n' "$X" | grep -v '^[[:space:]]*//')
if printf '%s\n' "$Xc" | grep -cF 'File dir = f.getParentFile();' >/dev/null; then ok "the temp file and the synced directory are owner.conf's own"; else no "the writer's directory is not owner.conf's -- the rename would cross directories"; fi
s=$(line "$Xc" 'out.getFD().sync();'); r=$(line "$Xc" 'Os.rename(tmp.getPath(), f.getPath());'); d=$(line "$Xc" 'Os.fsync(d);')
if [ "$s" -gt 0 ] && [ "$s" -lt "$r" ] && [ "$r" -lt "$d" ]; then ok "the file is synced, then renamed, then the directory synced"; else no "the writer's steps are out of order (sync $s, rename $r, dir sync $d)"; fi
f=$(line "$Xc" 'return false;')
if [ "$(printf '%s\n' "$Xc" | grep -c 'return false;')" = 1 ] && [ "$f" -gt "$r" ] && [ "$f" -lt "$d" ]; then ok "only a failure up to the rename reports false"; else no "a failure after the rename reports false, or none does (false at $f, rename $r, dir sync $d)"; fi
if [ "$(printf '%s\n' "$Xc" | grep -c 'Log\.')" = 2 ] && [ "$(printf '%s\n' "$Xc" | grep 'Log\.' | grep -c '" + t.getClass().getSimpleName());$')" = 2 ]; then
  ok "the writer's only log lines name the exception's class, never the body"
else
  no "the writer logs something other than the exception's class -- on a phone without StrongBox the verifier is the PBKDF2 output"
fi
if [ "$(printf '%s\n' "$WOC" | grep -v '^[[:space:]]*//' | grep -c '^        return OwnerConf.write(ownerConf(), body.getBytes(java.nio.charset.StandardCharsets.UTF_8));')" = 1 ]; then
  ok "writeOwnerConf returns the atomic writer's result"
else
  no "writeOwnerConf does not return OwnerConf.write's result -- verifyOwner's -3 would never fire"
fi

echo "== a verify counts its attempt before checking it, refuses one it cannot count, and clears it on a match =="
PRE='if (!writeOwnerConf(c.get("salt"), c.get("verifier"), fails + 1, android.os.SystemClock.elapsedRealtime(), kcv)) return -3;'
p=$(line "$V" "$PRE"); k=$(line "$V" 'OwnerDerived d = ownerDerive(pass, owUnhex(c.get("salt")), kcv.isEmpty());'); w=$(line "$V" 'if (wait > 0) return wait;')
lk=$(line "$V" 'if (OwnerVerifyForm.lostKey(')
if [ "$p" -gt 0 ] && [ "$k" -gt "$p" ]; then ok "the failure count is written, and checked, before the passphrase is derived"; else no "the count is not written before the derivation (count at $p, derive at $k)"; fi
if [ "$w" -gt 0 ] && [ "$w" -lt "$p" ]; then ok "...after the back-off check, so a waiting caller is not counted"; else no "the back-off check does not come first (wait $w, count $p)"; fi
# NWP-20261120-04 (#26): a lost chip key answers -7 before the wait and the count, so it never advances the back-off.
if [ "$lk" -gt 0 ] && [ "$lk" -lt "$w" ] && [ "$(printf '%s\n' "$V" | grep -cF 'OwnerVerifyForm.lostKey(')" = 1 ]; then ok "a lost key is told before the wait, so it is never counted"; else no "the lost-key check is missing or after the wait (lost key $lk, wait $w)"; fi
if [ "$(printf '%s\n' "$V" | grep -cF 'fails + 1')" = 1 ]; then ok "the attempt is counted exactly once"; else no "the attempt is counted more or less than once"; fi
BR=$(printf '%s\n' "$V" | awk '/if \(OwnerVerifyForm\.matched\(o\)\) \{/ { on = 1 } on { print } on && /^        }$/ { exit }')
RESET='writeOwnerConf(c.get("salt"), OwnerVerifyForm.toStore(o, c.get("verifier"), d.chipHex), 0, 0, kcv.isEmpty() && !d.chipHex.isEmpty() ? ownerKcv() : kcv);'
z=$(line "$BR" "$RESET"); z0=$(line "$BR" 'return 0;')
if [ "$z" -gt 0 ] && [ "$z" -lt "$z0" ]; then ok "a matched passphrase clears the attempt it just counted"; else no "a matched passphrase leaves its attempt counted -- every correct entry advances the back-off"; fi
# The reset is the only non-comment writeOwnerConf of verifyOwner that passes ", 0, 0, " in ANY spelling of its verifier argument.
if [ "$(printf '%s\n' "$V" | grep -v '^[[:space:]]*//' | grep -F 'writeOwnerConf(' | grep -cF ', 0, 0, ')" = 1 ] && [ "$(printf '%s\n' "$BR" | grep -cF -- "$RESET")" = 1 ]; then ok "...and nothing else clears it, so no attempt is checked uncounted"; else no "the count is cleared outside the matched branch -- an attempt would be checked uncounted"; fi

echo "== the back-off runs on uptime, never the wall clock (NWP-20261011-39) =="
# Vc is verifyOwner with its comment lines removed. The wait and the failure stamp both read elapsedRealtime, so a set
# clock or a NITZ jump moves neither; owWaitSecs/owSinceMs, the arithmetic, are executed by
# core/vendor-common/bin/test-owner-throttle-java.sh. The wall clock here lifted the wait early when it jumped forward and
# skipped it entirely when it jumped back.
Vc=$(printf '%s\n' "$V" | grep -v '^[[:space:]]*//')
if printf '%s\n' "$Vc" | grep -cE 'currentTimeMillis|nanoTime|java\.time|Date\(' >/dev/null; then no "verifyOwner reads the wall clock again -- a clock change lifts or skips the back-off"; else ok "verifyOwner reads no wall clock"; fi
if [ "$(printf '%s\n' "$Vc" | grep -cF 'owWaitSecs(fails, android.os.SystemClock.elapsedRealtime(), last)')" = 1 ] && [ "$(printf '%s\n' "$Vc" | grep -cF 'fails + 1, android.os.SystemClock.elapsedRealtime(), kcv)')" = 1 ]; then
  ok "the wait is computed from, and the failure stamped with, elapsedRealtime"
else
  no "the wait or the failure stamp is not elapsedRealtime -- the two must share one clock"
fi

echo "== a damaged file is damage, whatever part of it is damaged =="
if printf '%s\n' "$R" | grep -cF 'm.get("salt").matches("[0-9a-f]{32}")' >/dev/null && printf '%s\n' "$R" | grep -cF 'm.get("verifier").matches("[0-9a-f]{64}")' >/dev/null; then
  ok "a salt or verifier value of the wrong form reads as damaged (-2), not a typo, and never reaches owUnhex"
else
  no "a damaged salt or verifier value is read as a real one -- a typo, or an owUnhex throw that kills the gate"
fi
# NWP-20261120-04: a kcv is optional, but a present one of the wrong form is damage, never a "key changed" re-setup.
if printf '%s\n' "$R" | grep -cF '(!m.containsKey("kcv") || m.get("kcv").matches("[0-9a-f]{64}"))' >/dev/null; then
  ok "a kcv value of the wrong form reads as damaged (-2), never as a lost chip key"
else
  no "a damaged kcv is read as a real one -- it would send the owner to re-setup and replace the owner key"
fi

echo "== each outcome has its own message =="
M='StatusLine.error(msg, r > 0 ? ("too many tries — wait " + r + "s") : r == -2 ? OwnerConf.DAMAGED : r == -3 ? OwnerConf.NOT_COUNTED : r == -6 ? OwnerVerifyForm.CHIP_DOWN_LINE : "wrong passphrase");'
if [ "$(grep -cxF -- "                        $M" "$CA")" = 1 ]; then ok "-2, -3 and -6 have their own messages, not \"wrong passphrase\""; else no "the verify screen maps -2, -3 or -6 to \"wrong passphrase\""; fi
if grep -cF '"this phone'"'"'s passphrase file is damaged — the passphrase can'"'"'t be checked."' "$OC" >/dev/null && grep -cF '+ " Erasing the phone is the only way back into Owner settings.";' "$OC" >/dev/null; then
  ok "the damaged-file message is docs/owner-identity-spec.md's"
else
  no "the damaged-file message is not the spec's wording"
fi

# --- mutations ------------------------------------------------------------------------------------------
if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each MUST be convicted) =="
  M2=$(mktemp -d -p "$W")
  # arity <file> <method> <n>: one "<method> line <k> has <m> args" per non-comment call of <method> that does not pass
  # exactly <n> top-level arguments. String literals are skipped; a declaration ("<type> <method>(") is not a call.
  arity(){ awk -v name="$2" -v want="$3" '
    /^[[:space:]]*\/\// { next }
    { s = $0
      while ((i = index(s, name "(")) > 0) {
        pre = substr(s, 1, i - 1); s = substr(s, i + length(name) + 1)
        if (pre ~ /[A-Za-z0-9_]$/ || pre ~ /(boolean|OwnerDerived) $/) continue
        d = 1; n = 1; q = 0; e = 1
        for (j = 1; j <= length(s) && d > 0; j++) {
          ch = substr(s, j, 1)
          if (q) { if (ch == "\\") j++; else if (ch == "\"") q = 0; continue }
          if (ch == "\"") { q = 1; e = 0 } else if (ch == "(") { d++; e = 0 } else if (ch == ")") d--
          else if (ch == "," && d == 1) n++
          else if (ch != " ") e = 0
        }
        if (e) n = 0
        if (n != want) printf "%s line %d has %d args; ", name, NR, n
      }
    }' "$1"; }
  mutate(){ # mutate <label> <CA|OC> <sed script>
    rm -rf "$M2/src"; cp -r "$SRC" "$M2/src"
    local f="$M2/src/ChooserActivity.java"; [ "$2" = OC ] && f="$M2/src/OwnerConf.java"
    if ! sed -i "$3" "$f" 2>"$M2/err"; then no "MUTATION BROKEN (sed): $1"; return; fi
    if cmp -s "$f" "$SRC/$(basename "$f")"; then no "MUTATION INERT: $1"; return; fi
    # NWP-20261120-04: a mutant that passes the wrong number of arguments would not compile, so its conviction proves
    # nothing. This suite cannot run javac over ChooserActivity, so it counts the arguments of each changed call.
    local bad; bad=$(arity "$f" writeOwnerConf 5; arity "$f" ownerDerive 3)
    if [ -n "$bad" ]; then no "MUTATION BROKEN (would not compile: $bad): $1"; return; fi
    if bash "$0" "$M2/src" >/dev/null 2>&1; then no "NOT CONVICTED: $1 -- suite passes on broken code"
    else ok "convicted: $1"; fi
  }
  mutate "the writer no longer syncs the file"                OC 's/^                out.getFD().sync();$/                \/\/ out.getFD().sync();/'
  mutate "the writer no longer syncs the directory"           OC 's/^                Os.fsync(d);$/                \/\/ Os.fsync(d);/'
  mutate "the writer renames before it syncs"                 OC '/^            Os.rename(tmp.getPath(), f.getPath());$/d; s/^                out.getFD().sync();$/                Os.rename(tmp.getPath(), f.getPath());\n                out.getFD().sync();/'
  mutate "a failed write reports success"                     OC '0,/^            return false;$/s//            return true;/'
  mutate "a failed directory sync reports failure"            OC '/directory sync failed/a\            return false;'
  mutate "the temp and the synced directory are not owner.conf's" OC 's/^        File dir = f.getParentFile();$/        File dir = f.getParentFile().getParentFile();/'
  mutate "the writer logs the body"                           OC 's/"owner.conf write failed: " + t.getClass().getSimpleName()/"owner.conf write failed: " + new String(body)/'
  mutate "the writer logs the body on a continuation line"    OC 's/^            tmp.delete();$/            tmp.delete(); android.util.Log.e("NowhereChooser",\n                new String(body));/'
  mutate "writeOwnerConf truncates in place again"            CA 's/^        return OwnerConf.write(ownerConf(), body.getBytes(java.nio.charset.StandardCharsets.UTF_8));\(.*\)$/        try (java.io.FileOutputStream fo = openFileOutput("owner.conf", MODE_PRIVATE)) { fo.write(body.getBytes("UTF-8")); } catch (Throwable t) {} return true;/'
  mutate "writeOwnerConf always reports success"              CA 's/^        return OwnerConf.write(ownerConf(), body.getBytes(java.nio.charset.StandardCharsets.UTF_8));\(.*\)$/        OwnerConf.write(ownerConf(), body.getBytes(java.nio.charset.StandardCharsets.UTF_8)); return true;\1/'
  mutate "a second writer reaches owner.conf"                 CA 's/^        OwnerDerived d = ownerDerive(pass, salt, true);$/        OwnerDerived d = ownerDerive(pass, salt, true); try (java.io.FileOutputStream fo = new java.io.FileOutputStream(ownerConf())) { fo.write(1); } catch (Throwable t) {}/'
  mutate "an uncountable attempt is checked anyway"           CA 's/fails + 1, android.os.SystemClock.elapsedRealtime(), kcv)) return -3;/fails + 1, android.os.SystemClock.elapsedRealtime(), kcv)) { }/'
  mutate "the attempt counted only after a failure"           CA '/fails + 1, android.os.SystemClock.elapsedRealtime(), kcv)) return -3;/d; s/^        return -1;$/        writeOwnerConf(c.get("salt"), c.get("verifier"), fails + 1, android.os.SystemClock.elapsedRealtime(), kcv); return -1;/'
  mutate "the attempt counted before the back-off check"      CA '/^        if (wait > 0) return wait;$/{h;d}; /fails + 1, android.os.SystemClock.elapsedRealtime(), kcv)) return -3;/{G}'
  mutate "the attempt counted twice after a wrong passphrase" CA '/^        d.clear();$/{n;s/^        return -1;$/        writeOwnerConf(c.get("salt"), c.get("verifier"), fails + 1, android.os.SystemClock.elapsedRealtime(), kcv); return -1;/}'
  mutate "a matched passphrase keeps its attempt counted"     CA '/^            boolean kept = writeOwnerConf(/d'
  mutate "the count cleared before the check"                 CA '/fails + 1, android.os.SystemClock.elapsedRealtime(), kcv)) return -3;/a\        writeOwnerConf(c.get("salt"), c.get("verifier"), 0, 0, kcv);'
  mutate "the wait reads the wall clock again"                CA 's/owWaitSecs(fails, android.os.SystemClock.elapsedRealtime(), last)/owWaitSecs(fails, System.currentTimeMillis(), last)/'
  mutate "the failure is stamped with the wall clock again"   CA 's/fails + 1, android.os.SystemClock.elapsedRealtime(), kcv)) return -3;/fails + 1, System.currentTimeMillis(), kcv)) return -3;/'
  mutate "a damaged value reads as a real one again"          CA 's/ \&\& m.get("salt").matches("\[0-9a-f\]{32}")//; s/ \&\& m.get("verifier").matches("\[0-9a-f\]{64}")//'
  mutate "a damaged file reads as a typo again"               CA 's/r == -2 ? OwnerConf.DAMAGED : //'
  mutate "an uncounted attempt reads as a typo"               CA 's/r == -3 ? OwnerConf.NOT_COUNTED : //'
  mutate "the damaged words moved to a second constant"     OC 's/static final String DAMAGED =/static final String DAMAGED = "wrong passphrase."; static final String OLD_DAMAGED =/'
  mutate "the uncounted constant is wrong-passphrase"       OC 's/= "can'"'"'t check the passphrase right now — try again";/= "wrong passphrase";/'
  mutate "the message mapping survives only in a comment"     CA 's/^\(                        \)StatusLine.error(msg, r > 0 ? ("too many tries — wait " + r + "s") : r == -2 ? OwnerConf.DAMAGED : r == -3 ? OwnerConf.NOT_COUNTED : r == -6 ? OwnerVerifyForm.CHIP_DOWN_LINE : "wrong passphrase");$/\1StatusLine.error(msg, r > 0 ? ("too many tries — wait " + r + "s") : "wrong passphrase"); \/\/ StatusLine.error(msg, r > 0 ? ("too many tries — wait " + r + "s") : r == -2 ? OwnerConf.DAMAGED : r == -3 ? OwnerConf.NOT_COUNTED : r == -6 ? OwnerVerifyForm.CHIP_DOWN_LINE : "wrong passphrase");/'
  mutate "the damaged-file wording changed"                   OC 's/Erasing the phone is the only way back into Owner settings./Please contact support./'
  mutate "a new caller clears the count after a wrong passphrase" CA '/^                try { r = verifyOwner(p); } finally { OWNER_AUTH_LOCK.unlock(); }$/a\                if (r == -1) { java.util.HashMap<String, String> c2 = readOwnerConf(); if (c2 != null) writeOwnerConf(c2.get("salt"), c2.get("verifier"), 0, 0, ""); }'
  mutate "ownerSecretSet truncates the file"                   CA 's/^    private boolean ownerSecretSet() { java.io.File f = ownerConf(); return f.exists() \&\& f.length() > 0; }$/    private boolean ownerSecretSet() { java.io.File f = ownerConf(); try { new java.io.FileOutputStream(f).close(); } catch (Throwable t) {} return f.exists() \&\& f.length() > 0; }/'
  mutate "writeOwnerConf drops kcv on the counter write"       CA 's/fails + 1, android.os.SystemClock.elapsedRealtime(), kcv)) return -3;/fails + 1, android.os.SystemClock.elapsedRealtime(), "")) return -3;/'
  mutate "a damaged kcv reads as a real one"                   CA 's/^                \&\& (!m.containsKey("kcv") || m.get("kcv").matches("\[0-9a-f\]{64}"))) ? m : null;/                ) ? m : null;/'
  mutate "the lost-key check moved after the count"            CA '/^        int alias = ownerAliasState();$/{N;N;N;N;h;d}; /fails + 1, android.os.SystemClock.elapsedRealtime(), kcv)) return -3;/{G}'
  mutate "a dead copy of the writer left in a comment"         OC '/^    \/\*\* Writes body to f atomically/i\    /* static boolean write(File f, byte[] body) { return true; } */'
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
