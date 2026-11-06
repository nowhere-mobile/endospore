#!/usr/bin/env bash
# test-owner-pass-change-java.sh [--mutate] -- the owner's device-passphrase change, run under javac (NWP-20261022-01).
#
# WHY THIS IS COMMITTED. Changing the device passphrase is a rewrap: the chooser sends OWNER-KEY-REWRAP and writes
# owner.conf ONLY on OK or NOKEY. A request in the wrong grammar, a reply table that lets an ERR through to the
# disk, or an enrol floor that drifts from the change's would each lose or strand the owner's key. OwnerPassChange
# is a pure class with no android.* import, compiled here with its cases. test-owner-key.sh pins the call sites.
#
# THE RE-CHECK (NWP-20261126-20). changeOwnerPass runs verifyOwner, which compares through OwnerVerifyForm.check, and
# then derives the old passphrase again and re-checks it. That re-check was a bare compare of one form. A chip that
# answered the verify and went silent for the second derive gave the PBKDF2 hex, so the change said "unchanged" (-4)
# instead of the chip line (-6). After an UPGRADE whose conf write did not land, owner.conf held the PBKDF2 form and the
# chip gave the chip form, so every change said "unchanged". The re-check now uses the verify's rule through
# OwnerPassChange.recheckCode, compiled here beside OwnerVerifyForm.java. The cases pin the map (K1-K3) and both
# scenarios (K4, K5, each with the old bare compare as its control); the source checks pin the call site in
# ChooserActivity.changeOwnerPass (S1) and that the bare compare is gone (S2). ChooserActivity.java is read as text only.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-owner-pass-change-java.sh            # the cases
#   bash test-owner-pass-change-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SUT="$root/core/chooser/src/com/nowhere/chooser/OwnerPassChange.java"
SUT_OVF="$root/core/chooser/src/com/nowhere/chooser/OwnerVerifyForm.java"
SUT_CA="$root/core/chooser/src/com/nowhere/chooser/ChooserActivity.java"
CASES="$root/core/chooser/tests/owner-pass-change/OwnerPassChangeCases.java"
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
[ -f "$SUT_OVF" ] || { echo "FAIL: missing $SUT_OVF" >&2; exit 2; }
[ -f "$SUT_CA" ] || { echo "FAIL: missing $SUT_CA" >&2; exit 2; }

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

# srcchecks <ChooserActivity.java>: the re-check in changeOwnerPass, with comments dropped (NWP-20261126-20).
srcchecks() {
  local ca="$1" code cp cpc l_old l_rc l_if l_new
  code=$(grep -v '^[[:space:]]*//' "$ca")
  cp=$(method "$code" 'private int changeOwnerPass(String oldPass, String newPass)')
  [ -n "$cp" ] || { chk "S1 changeOwnerPass is in ChooserActivity" 0; return; }
  cpc=$(printf '%s\n' "$cp" | sed -E 's# // .*$##')
  l_old=$(lineno "$cpc" 'OwnerDerived dOld = ownerDerive(')
  l_rc=$(lineno "$cpc" 'int rc = OwnerPassChange.recheckCode(OwnerVerifyForm.check(c.get("verifier"), dOld.chipHex, dOld.pbkdfHex, dOld.strongBox));')
  l_if=$(lineno "$cpc" 'if (rc != 0) { dOld.clear(); return rc; }')
  l_new=$(lineno "$cpc" 'OwnerDerived dNew = ownerDerive(')
  if [ "$(count "$cpc" 'OwnerPassChange.recheckCode(OwnerVerifyForm.check(')" = 1 ] \
     && [ "$(count "$cpc" 'if (rc != 0) { dOld.clear(); return rc; }')" = 1 ] \
     && [ "$l_old" -gt 0 ] && [ "$l_rc" -gt "$l_old" ] && [ "$l_if" -eq "$((l_rc + 1))" ] && [ "$l_new" -gt "$l_if" ]; then
    chk "S1 changeOwnerPass re-checks the old derive with OwnerPassChange.recheckCode(OwnerVerifyForm.check(...)) and returns its non-zero code after dOld.clear()" 1
  else
    chk "S1 the re-check is missing, moved or does not return its code (dOld $l_old, rc $l_rc, if $l_if, dNew $l_new)" 0
  fi
  if [ "$(count "$code" 'owConstEq(dOld.verifier')" = 0 ]; then
    chk "S2 no bare owConstEq(dOld.verifier, ...) re-check remains" 1
  else
    chk "S2 the bare owConstEq(dOld.verifier, ...) re-check is still there" 0
  fi
}

# suite <OwnerPassChange.java> <ChooserActivity.java> -> 0 pass, 1 a case or a source check failed or the class is
# missing (the only codes that convict a mutant), 3 the classes or the cases did not compile.
suite() {
  local src="$1" ca="$2" d out rc
  [ -f "$src" ] || { echo "  FAIL  OwnerPassChange.java does not exist (the change is not built)" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$src" "$d/src/com/nowhere/chooser/OwnerPassChange.java"
  cp "$SUT_OVF" "$d/src/com/nowhere/chooser/OwnerVerifyForm.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/OwnerPassChangeCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.OwnerPassChangeCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  bad=0
  echo "== source checks: $ca"
  srcchecks "$ca"
  [ "$rc" -eq 0 ] && [ "$bad" -eq 0 ] && return 0
  return 1
}

echo "== $SUT"
suite "$SUT" "$SUT_CA" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not compile proves nothing)"
mut() { # mut <label> <OPC|CA> <perl-expr>
  local d c t rc; d=$(mktemp -d -p "$W") || return 1
  case "$2" in
    OPC) t="$SUT"; c="$d/OwnerPassChange.java" ;;
    CA)  t="$SUT_CA"; c="$d/ChooserActivity.java" ;;
    *)   echo "  ERROR     $1 -- unknown target $2"; rm -rf "$d"; return 1 ;;
  esac
  cp "$t" "$c"
  if ! perl -0pi -e "$3" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$t" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  if [ "$2" = OPC ]; then suite "$c" "$SUT_CA" >/dev/null 2>&1; rc=$?; else suite "$SUT" "$c" >/dev/null 2>&1; rc=$?; fi
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "step maps NOKEY to UNCHANGED"     OPC 's/r\.equals\("OK"\) \|\| r\.equals\("NOKEY"\)/r.equals("OK")/' || fails=$((fails+1))
mut "step maps ERR mode to WRITE_CONF" OPC 's/if \(r\.equals\("OK"\)/if (r.equals("ERR mode") || r.equals("OK")/' || fails=$((fails+1))
mut "rewrapRequest swaps the old and new pairs" OPC 's/p\(oldPepperB64\) \+ "\\n" \+ oldPassB64 \+ "\\n" \+ p\(newPepperB64\) \+ "\\n" \+ newPassB64/p(newPepperB64) + "\\n" + newPassB64 + "\\n" + p(oldPepperB64) + "\\n" + oldPassB64/' || fails=$((fails+1))
mut "a null pepper written as an empty line" OPC 's/x == null \|\| x\.isEmpty\(\) \? "-" : x/x == null ? "" : x.isEmpty() ? "-" : x/' || fails=$((fails+1))
mut "M1 recheckCode maps CHIP_DOWN to -4" OPC 's/case CHIP_DOWN: return -6;/case CHIP_DOWN: return -4;/' || fails=$((fails+1))
mut "M2 recheckCode maps UPGRADE to -4" OPC 's/case MATCH: case UPGRADE: case MATCH_NO_CHIP: return 0;/case MATCH: case MATCH_NO_CHIP: return 0;\n            case UPGRADE: return -4;/' || fails=$((fails+1))
mut "M3 recheckCode maps WRONG to 0" OPC 's/default: return -4;/default: return 0;/' || fails=$((fails+1))
mut "M4 changeOwnerPass ignores the re-check's code" CA 's/if \(rc != 0\) \{ dOld\.clear\(\); return rc; \}/if (rc != 0) { dOld.clear(); }/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
