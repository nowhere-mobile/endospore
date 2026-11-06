#!/usr/bin/env bash
# test-gate-lock-clear-java.sh [--mutate] -- NWP-20261118-04 (h48 #1, docs/product-decisions.md 2026-10-30): the gate
# removes a screen lock set on user 0 with a reset-password token it keeps.
#
# WHY THIS IS COMMITTED. A PIN set on user 0 through Owner settings > System settings (Android asks for one before a
# fingerprint enrolment) left user 0 RUNNING_LOCKED at the next boot, and the gate never started (lynx, 2026-10-29).
# Nothing cleared a user-0 credential. Now GateLockToken.run hands GateLockClear.run its platform calls (a Port);
# GateLockClear.run reads the state, decides with GateLockClear.decide and clears the lock with
# resetPasswordWithToken(admin, null, token, 0), at each gate start (onCreate's device-owner block) and at each return
# from System settings (confirmReArm's LOCKED arm). Owner settings says once that it did, or reports a lock it waits on.
#
# Two halves: the cases run GateLockClear.java as is under javac (core/chooser/tests/gate-lock-clear/): the decision
# table, the notice rules and the run against a fake platform (R1-R9). Source pins check the two call points, the Owner
# settings line, the null password, the token write, that GateLockToken asks the activation query only through
# GateLockClear.run, and that no Log line names the token.
#
# R1-R3 are RF-001 (review of 2026-10-31): isResetPasswordTokenActive throws IllegalStateException when no token
# exists (its documented contract). The first run asked it before it read the kept token, stopped at the exception,
# and so set no token and reported nothing, on a first gate start and on every later one.
#
# It needs a JDK, and it FAILS when there is none. javac/java come from PATH, then the build VM's prebuilt JDK 21.
# --mutate re-runs it against deliberately broken copies, each of which must fail a CASE or a PIN.
#
#   bash test-gate-lock-clear-java.sh            # the cases and the pins
#   bash test-gate-lock-clear-java.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail
MUTATE=no; for a in "$@"; do [ "$a" = --mutate ] && MUTATE=yes; done
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
CH="$ROOT/core/chooser"
SRC="$CH/src/com/nowhere/chooser"
CLEAR="$SRC/GateLockClear.java"
TOKEN="$SRC/GateLockToken.java"
ACT="$SRC/ChooserActivity.java"
CASES="$CH/tests/gate-lock-clear/GateLockClearCases.java"
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-gate-lock-clear-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
# One root: every temp of this suite lives inside $W.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

# cases <GateLockClear.java>: compiles it as is with the cases and runs them.
# Returns 0 every case passes, 1 a case failed, 3 no compile.
cases(){
  local d out r
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser" "$d/out"
  cp "$1" "$d/src/com/nowhere/chooser/GateLockClear.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/GateLockClearCases.java"
  if ! out=$("$JAVAC" -J-Djava.io.tmpdir="$W" -d "$d/out" "$d/src/com/nowhere/chooser/GateLockClear.java" \
      "$d/src/com/nowhere/chooser/GateLockClearCases.java" 2>&1); then
    printf '%s\n' "$out" >&2; rm -rf "$d"; return 3
  fi
  out=$(timeout 20 "$JAVA" -Djava.io.tmpdir="$W" -cp "$d/out" com.nowhere.chooser.GateLockClearCases 2>&1); r=$?
  rm -rf "$d"
  printf '%s\n' "$out" | sed 's/^/    /'
  case "$r" in 0) return 0 ;; *) return 1 ;; esac
}

# nocomment <file>: the file with // comments dropped (the pinned lines hold no // in a literal)
nocomment(){ sed 's|//.*$||' "$1"; }
# do_branch <ChooserActivity.java>: onCreate's device-owner branch, to its closing brace (12 spaces and a brace)
do_branch(){
  nocomment "$1" | awk '
    $0 == "    protected void onCreate(Bundle b) {" { inc = 1 }
    inc && !on && index($0, "if (dpm != null && dpm.isDeviceOwnerApp(getPackageName())) {") { on = 1 }
    on { print }
    on && /^            }$/ { exit }'
}
# locked_arm <ChooserActivity.java>: confirmReArm's LOCKED arm, to its "} else if (tries < 30)"
locked_arm(){
  nocomment "$1" | awk '
    $0 == "    private void confirmReArm(int tries) {" { inm = 1 }
    inm && !on && index($0, "if (lts == android.app.ActivityManager.LOCK_TASK_MODE_LOCKED) {") { on = 1 }
    on && index($0, "} else if (tries < 30) {") { exit }
    on { print }'
}
# owner_menu <ChooserActivity.java>: buildOwnerMenu, to its closing brace (4 spaces and a brace)
owner_menu(){
  nocomment "$1" | awk '
    $0 == "    private View buildOwnerMenu() {" { on = 1 }
    on { print }
    on && /^    }$/ { exit }'
}

# pins <ChooserActivity.java> <GateLockToken.java>: prints one "ok|no <label>" per pin
pins(){
  local act=$1 tok=$2 br arm menu n m code logs firstdpm guard
  br=$(do_branch "$act")
  if [ -z "$br" ]; then echo "no control: onCreate's device-owner branch not found"
  else
    n=$(grep -cF 'GateLockToken.runAsync(this, "start");' <<<"$br")
    if [ "$n" = 1 ]; then echo "ok onCreate's device-owner branch calls GateLockToken.runAsync(this, \"start\") once"
    else echo "no onCreate's device-owner branch calls GateLockToken.runAsync(this, \"start\") $n time(s), not once"; fi
  fi
  arm=$(locked_arm "$act")
  if [ -z "$arm" ]; then echo "no control: confirmReArm's LOCKED arm not found"
  else
    n=$(grep -cF 'GateLockToken.runAsync(this, "rearm");' <<<"$arm")
    if [ "$n" = 1 ]; then echo "ok confirmReArm's LOCKED arm calls GateLockToken.runAsync(this, \"rearm\") once"
    else echo "no confirmReArm's LOCKED arm calls GateLockToken.runAsync(this, \"rearm\") $n time(s), not once"; fi
  fi
  code=$(nocomment "$act")
  n=$(grep -c 'GateLockToken\.runAsync(' <<<"$code")
  if [ "$n" = 2 ]; then echo "ok ChooserActivity.java calls GateLockToken.runAsync exactly twice"
  else echo "no ChooserActivity.java calls GateLockToken.runAsync $n time(s), not twice"; fi
  menu=$(owner_menu "$act")
  n=$(grep -cF 'GateLockToken.addNotice(this, ll, MUTED);' <<<"$menu")
  if [ "$n" = 1 ]; then echo "ok buildOwnerMenu adds the gate-lock notice once"
  else echo "no buildOwnerMenu adds the gate-lock notice $n time(s), not once"; fi
  code=$(nocomment "$tok")
  n=$(grep -cF 'dpm.resetPasswordWithToken(admin, null, token, 0)' <<<"$code")
  m=$(grep -c 'resetPasswordWithToken(' <<<"$code")
  if [ "$n" = 1 ] && [ "$m" = 1 ]; then echo "ok the clear is resetPasswordWithToken(admin, null, token, 0), the only reset call"
  else echo "no the clear is not exactly one resetPasswordWithToken(admin, null, token, 0) ($n of $m calls)"; fi
  logs=$(grep 'Log\.' <<<"$code" | grep -wE 'token|hex|fresh|toHex' || true)
  if [ -z "$logs" ]; then echo "ok no Log line names the token (token, fresh, hex, toHex)"
  else echo "no a Log line names the token: $logs"; fi
  n=$(grep -cF 'StoreInstaller.writeAtomic(tokenFile(ctx), toHex(fresh));' <<<"$code")
  m=$(grep -cE 'FileOutputStream|FileWriter|openFileOutput' <<<"$code")
  if [ "$n" = 1 ] && [ "$m" = 0 ]; then echo "ok the token file is written through StoreInstaller.writeAtomic, and nothing else opens a file for write"
  else echo "no the token file is not written through writeAtomic alone ($n writeAtomic, $m other writers)"; fi
  n=$(grep -cF 'android.system.Os.chmod(tokenFile(ctx).getPath(), 0600);' <<<"$code")
  if [ "$n" = 1 ]; then echo "ok the token file is set to mode 600"; else echo "no the token file is not set to mode 600"; fi
  guard=$(grep -nF 'if (CredentialService.myUserId() != 0) return;' <<<"$code" | head -1 | cut -d: -f1)
  firstdpm=$(grep -nE 'dpm\.|DevicePolicyManager\.class' <<<"$code" | head -1 | cut -d: -f1)
  if [ -n "$guard" ] && [ -n "$firstdpm" ] && [ "$guard" -lt "$firstdpm" ]; then echo "ok run returns outside user 0 before any DevicePolicyManager call"
  else echo "no run has no user-0 guard before its first DevicePolicyManager call"; fi
  n=$(grep -cF 'GateLockClear.Action a = GateLockClear.run(new GateLockClear.Port() {' <<<"$code")
  if [ "$n" = 1 ]; then echo "ok GateLockToken.run goes through GateLockClear.run once"
  else echo "no GateLockToken.run calls GateLockClear.run $n time(s), not once"; fi
  n=$(grep -c 'isResetPasswordTokenActive(' <<<"$code")
  m=$(grep -cF '@Override public boolean active() { return dpm.isResetPasswordTokenActive(admin); }' <<<"$code")
  if [ "$n" = 1 ] && [ "$m" = 1 ]; then echo "ok the activation query is asked only through Port.active (GateLockClear.run's order)"
  else echo "no the activation query is asked outside Port.active ($n calls, $m in Port.active)"; fi
}
run_pins(){ # run_pins <ChooserActivity.java> <GateLockToken.java>: ok/no lines to the counters; 1 if any pin failed
  local line bad=0
  while IFS= read -r line; do
    case "$line" in ok\ *) ok "${line#ok }" ;; *) no "${line#no }"; bad=1 ;; esac
  done < <(pins "$1" "$2")
  return $bad
}

echo "== the cases =="
cases "$CLEAR"; rc=$?
if [ "$rc" = 0 ]; then ok "every case passes"; else no "the cases did not pass (exit $rc: 1 a case failed, 3 no compile)"; fi
echo "== the source pins =="
run_pins "$ACT" "$TOKEN"; prc=$?

if [ "$MUTATE" = yes ] && [ "$rc" = 0 ] && [ "$prc" = 0 ]; then
  echo
  echo "== mutations (each MUST be convicted by a case or a pin) =="
  # mutate <case|act|token> <label> <perl -0 script>: case mutates GateLockClear.java; act ChooserActivity.java;
  # token GateLockToken.java
  mutate(){
    local kind=$1 label=$2 script=$3 d src copy r out
    case "$kind" in case) src=$CLEAR ;; act) src=$ACT ;; *) src=$TOKEN ;; esac
    d=$(mktemp -d -p "$W"); copy="$d/$(basename "$src")"
    if ! perl -0pe "$script" "$src" > "$copy" 2>"$d/err"; then no "MUTATION BROKEN (perl): $label"; rm -rf "$d"; return; fi
    if cmp -s "$copy" "$src"; then no "MUTATION DID NOT APPLY: $label"; rm -rf "$d"; return; fi
    if [ "$kind" = case ]; then
      cases "$copy" >/dev/null 2>&1; r=$?
      case "$r" in
        1) ok "CONVICTED: $label" ;;
        0) no "SURVIVED: $label -- the cases pass on broken code" ;;
        *) no "MUTATION BROKEN (exit $r, not a case): $label" ;;
      esac
    else
      if [ "$kind" = act ]; then out=$(pins "$copy" "$TOKEN"); else out=$(pins "$ACT" "$copy"); fi
      if [ -n "$(grep '^no ' <<<"$out" || true)" ]; then ok "CONVICTED: $label"; else no "SURVIVED: $label -- the pins pass on broken code"; fi
    fi
    rm -rf "$d"
  }
  # m0: the cases fail against a GateLockClear that answers NONE for everything.
  # RF-001: the run's order. Each must fail a runner case (R1-R9).
  mutate case "r1 RF-001: the query asked before the kept token is read, its IllegalStateException ends the run" \
    's/if \(stored\) \{\n( *try \{\n *active = p\.active\(\);)/if (true) {\n$1/; s/stored = false;\n *p\.log\("the platform holds no token[^\n]*/return null;/'
  mutate case "r2 a kept token the platform lacks ends the run" \
    's/stored = false;\n *p\.log\("the platform holds no token[^\n]*/return null;/'
  mutate case "r3 the marker written after any CLEAR" 's/if \(writesMarker\(a\)\) p\.writeMarker\(\);/p.writeMarker();/'
  mutate case "r4 the kept bytes are not zeroed" 's/if \(token != null\) java\.util\.Arrays\.fill\(token, \(byte\) 0\);//'
  mutate case "r5 a run log line holds the hex token" \
    's/(" action=" \+ a)\);/$1 + String.format("%064x", new java.math.BigInteger(1, token)));/'
  mutate case "r6 an inactive kept token is replaced (SET_TOKEN on REPORT)" 's/(case SET_TOKEN_REPORT:\n)/$1                case REPORT:\n/'
  mutate token "r7 GateLockToken asks the query itself before GateLockClear.run" \
    's/(\n *GateLockClear\.Action a = GateLockClear\.run\()/\n        boolean pre = dpm.isResetPasswordTokenActive(admin);$1/'
  mutate case "m0 decide answers NONE for everything" \
    's/(static Action decide\(boolean secure, boolean stored, boolean active\) \{\n)/$1        if (true) return Action.NONE;\n/'
  # The seven the task names.
  mutate case "m1 secure+stored+inactive answers SET_TOKEN" \
    's/return active \? Action\.CLEAR : Action\.REPORT;/return active ? Action.CLEAR : Action.SET_TOKEN;/'
  mutate case "m2 secure+!stored+active answers CLEAR" \
    's/if \(!stored\) return Action\.SET_TOKEN_REPORT;/if (!stored) return active ? Action.CLEAR : Action.SET_TOKEN_REPORT;/'
  mutate case "m3 secure+stored+active answers REPORT" \
    's/return active \? Action\.CLEAR : Action\.REPORT;/return Action.REPORT;/'
  mutate case "m4 !secure+stored+inactive answers NONE" \
    's/return stored && active \? Action\.NONE : Action\.SET_TOKEN;/return stored ? Action.NONE : Action.SET_TOKEN;/'
  mutate case "m5 the cleared notice shown twice (the marker is never dropped)" \
    's/return !CLEARED\.equals\(shownLine\);/return true;/'
  mutate act "m6 the confirmReArm call removed" \
    's/\n *GateLockToken\.runAsync\(this, "rearm"\);[^\n]*//'
  mutate act "m7 the gate-start call removed" \
    's/\n *GateLockToken\.runAsync\(this, "start"\);//'
  # More of the contract.
  mutate case "a failed CLEAR stays CLEAR" 's/return clearReturnedTrue \? Action\.CLEAR : Action\.REPORT;/return Action.CLEAR;/'
  mutate case "the report line drops SET_TOKEN_REPORT" 's/ \|\| last == Action\.SET_TOKEN_REPORT//'
  mutate case "the marker written after any action" 's/return afterClearResult == Action\.CLEAR;/return true;/'
  mutate case "the cleared text changed" "s/so it was removed: a lock/so it was removed; a lock/"
  mutate act "the gate-start call moved out of the device-owner branch" \
    's/\n *GateLockToken\.runAsync\(this, "start"\);//; s/(\n            android\.util\.Log\.w\("NowhereChooser", "clearAffiliationIds", t\);\n        \}\n)/$1        GateLockToken.runAsync(this, "start");\n/'
  mutate act "the rearm call moved to the not-confirmed arm" \
    's/\n *GateLockToken\.runAsync\(this, "rearm"\);[^\n]*//; s/(owner: re-arm not confirmed[^\n]*\n)/$1            GateLockToken.runAsync(this, "rearm");\n/'
  mutate act "the Owner settings line removed" 's/\n *GateLockToken\.addNotice\(this, ll, MUTED\);[^\n]*//'
  mutate token "the clear passes an empty password" 's/resetPasswordWithToken\(admin, null, token, 0\)/resetPasswordWithToken(admin, "", token, 0)/'
  mutate token "a Log line names the hex token" 's/(": " \+ line)\);/$1 + toHex(readToken(ctx)));/'
  mutate token "the token file written with a FileWriter" \
    's/StoreInstaller\.writeAtomic\(tokenFile\(ctx\), toHex\(fresh\)\);/try (java.io.FileWriter w = new java.io.FileWriter(tokenFile(ctx))) { w.write(toHex(fresh)); }/'
  mutate token "the user-0 guard removed" 's/\n *if \(CredentialService\.myUserId\(\) != 0\) return;[^\n]*//'
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
