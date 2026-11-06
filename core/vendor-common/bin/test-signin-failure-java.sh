#!/usr/bin/env bash
# test-signin-failure-java.sh [--mutate] -- the gate's failed-sign-in verdict, run under javac (NWP-20261023-08).
#
# WHY THIS IS COMMITTED. ChooserActivity.roamLogin decides what a failed sign-in says. The rollback it can offer is a
# permanent step back to an older save, so a network or phone fault (BLANK NET, an empty reply, ERR-UNRECORDED,
# ERR-CREATEUSER) must never reach it, and only a wrong passphrase / unknown profile may read as the blind line.
# SigninFailure is that verdict as a pure class with no android.* import, compiled here with its cases. The source
# check below pins roamLogin's one call and the rollback inside OFFER_ROLLBACK only, and the one SIGNIN-SHOWN send
# (Q065, NWP-20261106-11): after the switch, for a sign-in only, built from SigninFailure.shownCode and nothing else.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-signin-failure-java.sh            # the source check, then the cases
#   bash test-signin-failure-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SUT="$root/core/chooser/src/com/nowhere/chooser/SigninFailure.java"
CASES="$root/core/chooser/tests/signin-failure/SigninFailureCases.java"
ACT="$root/core/chooser/src/com/nowhere/chooser/ChooserActivity.java"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

# srccheck <ChooserActivity.java> -> 0 pass, 1 a property fails.
srccheck() {
  local f="$1" start end body n rb arm rc=0 fb sw lm gd sd tail
  start=$(grep -nF 'private void roamLogin(final String name, final String pw, final boolean isCreate, final String keyMode)' "$f" | cut -d: -f1)
  end=$(grep -nF 'private void offerSnapshotRecovery(' "$f" | cut -d: -f1)
  case "$start" in ''|*[!0-9]*) echo "  FAIL  roamLogin's signature is not found exactly once"; return 1 ;; esac
  case "$end" in ''|*[!0-9]*) echo "  FAIL  offerSnapshotRecovery's declaration is not found exactly once"; return 1 ;; esac
  [ "$end" -gt "$start" ] || { echo "  FAIL  offerSnapshotRecovery precedes roamLogin"; return 1; }
  body=$(sed -n "${start},$((end-1))p" "$f")
  if [ -z "$body" ] || ! grep -qF 'createRoamUser(' <<<"$body"; then
    echo "  FAIL  the roamLogin extraction is broken (empty, or no createRoamUser( in it)"; return 1
  fi
  n=$(grep -cF 'SigninFailure.of(' <<<"$body" || true)
  [ "$n" = 1 ] || { echo "  FAIL  roamLogin has $n SigninFailure.of( call(s), want exactly 1"; rc=1; }
  n=$(grep -cF 'offerSnapshotRecovery(name, pw)' <<<"$body" || true)
  [ "$n" = 1 ] || { echo "  FAIL  roamLogin has $n offerSnapshotRecovery(name, pw) call(s), want exactly 1"; rc=1; }
  n=$(grep -cF 'reply.startsWith("ERR-UNRECORDED")' <<<"$body" || true)
  [ "$n" = 0 ] || { echo "  FAIL  roamLogin still decides ERR-UNRECORDED itself"; rc=1; }
  arm=$(awk '/case OFFER_ROLLBACK:/ {on=1; next} on && /case [A-Z_]+:|default:/ {exit} on {print}' <<<"$body")
  rb=$(grep -cF 'offerSnapshotRecovery(name, pw)' <<<"$arm" || true)
  [ "$rb" = 1 ] || { echo "  FAIL  the rollback is not inside the OFFER_ROLLBACK case"; rc=1; }
  [ "$rc" = 0 ] && echo "  ok    roamLogin: one SigninFailure.of, the rollback only in OFFER_ROLLBACK"
  n=$(grep -cF 'SIGNIN-SHOWN' <<<"$body" || true)
  [ "$n" = 1 ] || { echo "  FAIL  roamLogin has $n SIGNIN-SHOWN send(s), want exactly 1"; rc=1; }
  fb=$(awk '/if \(uid >= 0\) stopRoamUser\(uid\); \/\/ blind/ {on=1} on && /\} finally \{/ {exit} on {print}' <<<"$body")
  if [ -z "$fb" ]; then echo "  FAIL  roamLogin's failure branch is not found"; return 1; fi
  n=$(grep -cF 'SIGNIN-SHOWN' <<<"$fb" || true)
  [ "$n" = 1 ] || { echo "  FAIL  the failure branch has $n SIGNIN-SHOWN send(s), want exactly 1"; rc=1; }
  sw=$(grep -nF 'switch (verdict) {' <<<"$fb" | head -n1 | cut -d: -f1)
  lm=$(grep -nF 'showMsg(SigninFailure.message(' <<<"$fb" | head -n1 | cut -d: -f1)
  sd=$(grep -nF 'SIGNIN-SHOWN' <<<"$fb" | head -n1 | cut -d: -f1)
  case "$sw" in ''|*[!0-9]*) echo "  FAIL  the failure branch has no switch (verdict)"; return 1 ;; esac
  case "$lm" in ''|*[!0-9]*) echo "  FAIL  the failure branch has no showMsg(SigninFailure.message( arm"; return 1 ;; esac
  case "$sd" in ''|*[!0-9]*) echo "  FAIL  the failure branch sends no SIGNIN-SHOWN"; return 1 ;; esac
  gd=$(grep -nF 'if (!isCreate) {' <<<"$fb" | cut -d: -f1 | awk -v lm="$lm" '$1 > lm {print; exit}')
  case "$gd" in ''|*[!0-9]*) echo "  FAIL  no if (!isCreate) { guard after the switch"; return 1 ;; esac
  if [ "$sw" -lt "$lm" ] && [ "$lm" -lt "$gd" ] && [ "$gd" -lt "$sd" ]; then :; else
    echo "  FAIL  the SIGNIN-SHOWN send is not after the switch and inside its !isCreate guard"; rc=1
  fi
  tail=$(sed -n "${gd},$((sd+2))p" <<<"$fb")
  n=$(grep -cF 'final String shown = SigninFailure.shownCode(verdict, reply);' <<<"$tail" || true)
  [ "$n" = 1 ] || { echo "  FAIL  the code is not taken from SigninFailure.shownCode(verdict, reply)"; rc=1; }
  n=$(grep -cE 'sendDaemon\("SIGNIN-SHOWN\\n" \+ shown \+ "\\n"\)' <<<"$tail" || true)
  [ "$n" = 1 ] || { echo "  FAIL  the send is not built from the literal and shown alone"; rc=1; }
  n=$(grep -E '\b(name|pw|uid)\b' <<<"$tail" || true)
  [ -z "$n" ] || { echo "  FAIL  the send or its log line mentions the name, passphrase or uid"; rc=1; }
  [ "$rc" = 0 ] && echo "  ok    roamLogin: SIGNIN-SHOWN once, in the failure branch after the switch, under !isCreate, from shownCode"
  return "$rc"
}

echo "== $ACT"
srccheck "$ACT" || { echo "FAILED"; exit 1; }

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

# suite <SigninFailure.java> -> 0 pass, 1 a case failed or the class is missing (the only codes that convict a
# mutant), 3 the class or the cases did not compile.
suite() {
  local src="$1" d out rc
  [ -f "$src" ] || { echo "  FAIL  SigninFailure.java does not exist (the change is not built)" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$src" "$d/src/com/nowhere/chooser/SigninFailure.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/SigninFailureCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.SigninFailureCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

echo "== $SUT"
suite "$SUT" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not compile proves nothing)"
mut() { # mut <label> <perl-expr>
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/SigninFailure.java"
  cp "$SUT" "$c"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$SUT" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  suite "$c" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
smut() { # smut <label> <perl-expr> -- a mutant of ChooserActivity.java, convicted by the source check
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/ChooserActivity.java"
  cp "$ACT" "$c"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$ACT" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  srccheck "$c" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  echo "  convicted $1"; return 0
}
fails=0
mut "M1 the BLANK NET arm removed" 's/\n[ \t]*if \(r\.startsWith\("BLANK NET"\)\) return Verdict\.STORE_UNREACHABLE;//' || fails=$((fails+1))
mut "M2 the progress test above the PHONE_FAULT arm" 's/(\n[ \t]*if \(r\.startsWith\("ERR-UNRECORDED"\)[^\n]*)(\n[ \t]*if \(sawRestoreProgress\)[^\n]*)/$2$1/' || fails=$((fails+1))
mut "M3 ERR-CREATEUSER dropped from PHONE_FAULT" 's/ \|\| r\.startsWith\("ERR-CREATEUSER"\)//' || fails=$((fails+1))
mut "M4 a create gets OFFER_ROLLBACK" 's/isCreate \? Verdict\.CREATE_FAILED : //' || fails=$((fails+1))
mut "M5 the NOSTORE arm below the progress test" 's/(\n[ \t]*if \(r\.startsWith\("NOSTORE"\)[^\n]*)(.*?)(\n[ \t]*if \(sawRestoreProgress\)[^\n]*)/$2$3$1/s' || fails=$((fails+1))
mut "M6 the empty-reply arm removed" 's/\n[ \t]*if \(r\.isEmpty\(\)\) return Verdict\.TIMED_OUT;//' || fails=$((fails+1))
mut "M7 the create PHONE_FAULT line replaced by the sign-in one" 's/if \(isCreate\) return CREATE_PHONE_FAULT;/if (isCreate) return CREATEUSER;/' || fails=$((fails+1))
mut "C1 the ERR-WORKER-BUSY rule removed" 's/\n[ \t]*if \(r\.startsWith\("ERR-WORKER-BUSY"\)\) return Verdict\.WORKER_BUSY;//' || fails=$((fails+1))
mut "C2 the ERR-WORKER-BUSY rule below the progress test" 's/(\n[ \t]*if \(r\.startsWith\("ERR-WORKER-BUSY"\)[^\n]*)(.*?)(\n[ \t]*if \(sawRestoreProgress\)[^\n]*)/$2$3$1/s' || fails=$((fails+1))
mut "C3 the ERR-TIMEOUT rule removed" 's/\n[ \t]*if \(r\.startsWith\("ERR-TIMEOUT"\)\) return Verdict\.TIMED_OUT;//' || fails=$((fails+1))
mut "C4 the ERR-TIMEOUT rule below the progress test" 's/(\n[ \t]*if \(r\.startsWith\("ERR-TIMEOUT"\)[^\n]*)(.*?)(\n[ \t]*if \(sawRestoreProgress\)[^\n]*)/$2$3$1/s' || fails=$((fails+1))
mut "C5 WORKER_BUSY mapped to BLANK" 's/return Verdict\.WORKER_BUSY;/return Verdict.BLANK;/' || fails=$((fails+1))
mut "C6 the busy create message replaced by the sign-in one" 's/isCreate \? CREATE_BUSY : SIGNIN_BUSY/SIGNIN_BUSY/' || fails=$((fails+1))
smut "S1 a second rollback offer in the BLANK case" 's/(case BLANK:[^\n]*\n(?:[^\n]*\n)*?[ \t]*)showBlank\(\);/$1offerSnapshotRecovery(name, pw); showBlank();/' || fails=$((fails+1))
mut "R1 BLANK maps to a code" 's/(case OFFER_ROLLBACK: return "load";)/$1\n            case BLANK: return "phone";/' || fails=$((fails+1))
mut "R2 OFFER_ROLLBACK maps to slow" 's/case OFFER_ROLLBACK: return "load";/case OFFER_ROLLBACK: return "slow";/' || fails=$((fails+1))
mut "R3 PHONE_FAULT always phone" 's/case PHONE_FAULT: return reply[^\n]*;/case PHONE_FAULT: return "phone";/' || fails=$((fails+1))
smut "R4 the !isCreate guard removed" 's/if \(!isCreate\) \{(\n[ \t]*final String shown = SigninFailure\.shownCode)/if (true) {$1/' || fails=$((fails+1))
smut "R5 the send placed before the switch" 's/([ \t]*switch \(verdict\) \{)(.*?)(\n[ \t]*\/\/ NWP-20261106-11 \(Q065\).*?-> " \+ sr\);\n[ \t]*\}\n[ \t]*\})/$3\n$1$2/s' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
