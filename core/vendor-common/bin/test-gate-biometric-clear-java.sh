#!/usr/bin/env bash
# test-gate-biometric-clear-java.sh [--mutate] -- NWP-20261208-20 (h45 #1, docs/product-decisions.md 2026-10-25): the
# gate removes a fingerprint or face enrolled in user 0, or reports it in Owner settings.
#
# WHY THIS IS COMMITTED. User 0 is the gate and is never wiped. A fingerprint or face enrolled there through Owner
# settings > System settings persists across every sign-out and power-off and reaches the next renter. NWP-20261114-12
# disabled Settings' entry while nothing is enrolled; an enrolment made before it stayed. Now GateBiometricRemove.run
# hands GateBiometricClear.run its platform calls (a Port): count user 0's templates, remove them with the hidden
# FingerprintManager / FaceManager removeAll(int, RemovalCallback) (else remove per template), count again. It runs at
# each gate start (onCreate's device-owner block). Owner settings says once that it removed them, or reports a
# template it could not remove.
#
# Two halves: the cases run GateBiometricClear.java as is under javac (core/chooser/tests/gate-biometric-clear/): the
# run against a fake platform, the notice rules and the log lines (B1-B9). Source pins check the two call points, the
# three permissions, the NowhereChooser module's privilege, the user-0 and device-owner guards, the reflected names,
# the log lines and the marker write.
#
# It needs a JDK, and it FAILS when there is none. javac/java come from PATH, then the build VM's prebuilt JDK 21.
# --mutate re-runs it against deliberately broken copies, each of which must fail a CASE or a PIN.
#
#   bash test-gate-biometric-clear-java.sh            # the cases and the pins
#   bash test-gate-biometric-clear-java.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail
MUTATE=no; for a in "$@"; do [ "$a" = --mutate ] && MUTATE=yes; done
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
CH="$ROOT/core/chooser"
SRC="$CH/src/com/nowhere/chooser"
CLEAR="$SRC/GateBiometricClear.java"
REMOVE="$SRC/GateBiometricRemove.java"
ACT="$SRC/ChooserActivity.java"
MANIFEST="$CH/AndroidManifest.xml"
BP="$ROOT/core/vendor-common/Android.bp"
PERMS="$ROOT/core/vendor-common/etc/permissions"
CASES="$CH/tests/gate-biometric-clear/GateBiometricClearCases.java"
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-gate-biometric-clear-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
# One root: every temp of this suite lives inside $W.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

# cases <GateBiometricClear.java>: compiles it as is with the cases and runs them.
# Returns 0 every case passes, 1 a case failed, 3 no compile.
cases(){
  local d out r
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser" "$d/out"
  cp "$1" "$d/src/com/nowhere/chooser/GateBiometricClear.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/GateBiometricClearCases.java"
  if ! out=$("$JAVAC" -J-Djava.io.tmpdir="$W" -d "$d/out" "$d/src/com/nowhere/chooser/GateBiometricClear.java" \
      "$d/src/com/nowhere/chooser/GateBiometricClearCases.java" 2>&1); then
    printf '%s\n' "$out" >&2; rm -rf "$d"; return 3
  fi
  out=$(timeout 20 "$JAVA" -Djava.io.tmpdir="$W" -cp "$d/out" com.nowhere.chooser.GateBiometricClearCases 2>&1); r=$?
  rm -rf "$d"
  printf '%s\n' "$out" | sed 's/^/    /'
  case "$r" in 0) return 0 ;; *) return 1 ;; esac
}

# nocomment <file>: the file with // comments dropped (the pinned lines hold no // in a literal)
nocomment(){ sed 's|//.*$||' "$1"; }
# noblock <file>: the file with /* */ and // comments dropped
noblock(){ perl -0pe 's{/\*.*?\*/}{}gs; s{//[^\n]*}{}g' "$1"; }
# do_branch <ChooserActivity.java>: onCreate's device-owner branch, to its closing brace (12 spaces and a brace)
do_branch(){
  nocomment "$1" | awk '
    $0 == "    protected void onCreate(Bundle b) {" { inc = 1 }
    inc && !on && index($0, "if (dpm != null && dpm.isDeviceOwnerApp(getPackageName())) {") { on = 1 }
    on { print }
    on && /^            }$/ { exit }'
}
# owner_menu <ChooserActivity.java>: buildOwnerMenu, to its closing brace (4 spaces and a brace)
owner_menu(){
  nocomment "$1" | awk '
    $0 == "    private View buildOwnerMenu() {" { on = 1 }
    on { print }
    on && /^    }$/ { exit }'
}
# remove_run <GateBiometricRemove.java>: run(Context, String), to its closing brace (4 spaces and a brace)
remove_run(){
  nocomment "$1" | awk '
    index($0, "    static synchronized void run(Context ctx, String why) {") == 1 { on = 1 }
    on { print }
    on && /^    }$/ { exit }'
}
# chooser_block <Android.bp>: the NowhereChooser module from its name to its closing brace
chooser_block(){
  awk '
    index($0, "    name: \"NowhereChooser\",") == 1 { on = 1 }
    on { print }
    on && /^}$/ { exit }' "$1"
}
# lineof <text> <fixed string>: the first line number of the string in the text, or empty
lineof(){ grep -nF -- "$2" <<<"$1" | head -1 | cut -d: -f1; }

# pins <ChooserActivity.java> <GateBiometricRemove.java> <AndroidManifest.xml> <Android.bp> <GateBiometricClear.java>:
# prints one "ok|no <label>" per pin
pins(){
  local act=$1 rem=$2 man=$3 bp=$4 clr=$5 br menu code n a b g d o perm block allow logs lit
  # P1 the gate-start call follows the keyguard catch, inside the device-owner branch
  br=$(do_branch "$act")
  if [ -z "$br" ]; then echo "no control: onCreate's device-owner branch not found"
  else
    n=$(grep -cF 'GateBiometricRemove.runAsync(this, "start");' <<<"$br")
    a=$(lineof "$br" '"NWP-20261114-12 keyguard biometrics off (DO)"')
    b=$(lineof "$br" 'GateBiometricRemove.runAsync(this, "start");')
    if [ "$n" = 1 ] && [ -n "$a" ] && [ -n "$b" ] && [ "$b" -gt "$a" ]; then
      echo "ok P1 onCreate's device-owner branch calls GateBiometricRemove.runAsync(this, \"start\") once, after the keyguard catch"
    else echo "no P1 onCreate's device-owner branch: GateBiometricRemove.runAsync(this, \"start\") $n time(s), line ${b:-none} vs the keyguard catch ${a:-none}"; fi
  fi
  # P2 the Owner settings notice follows the gate-lock notice
  menu=$(owner_menu "$act")
  n=$(grep -cF 'GateBiometricRemove.addNotice(this, ll, MUTED);' <<<"$menu")
  a=$(lineof "$menu" 'GateLockToken.addNotice(this, ll, MUTED);')
  b=$(lineof "$menu" 'GateBiometricRemove.addNotice(this, ll, MUTED);')
  if [ "$n" = 1 ] && [ -n "$a" ] && [ -n "$b" ] && [ "$b" -gt "$a" ]; then echo "ok P2 buildOwnerMenu adds the biometric notice once, after the gate-lock notice"
  else echo "no P2 buildOwnerMenu adds the biometric notice $n time(s), line ${b:-none} vs the gate-lock notice ${a:-none}"; fi
  # P3 one call in the whole activity: gate start only (the return from System settings is not decided)
  code=$(nocomment "$act")
  n=$(grep -c 'GateBiometricRemove\.runAsync(' <<<"$code")
  if [ "$n" = 1 ]; then echo "ok P3 ChooserActivity.java calls GateBiometricRemove.runAsync exactly once"
  else echo "no P3 ChooserActivity.java calls GateBiometricRemove.runAsync $n time(s), not once"; fi
  # P4 the three permissions, outside comments
  code=$(perl -0pe 's/<!--.*?-->//gs' "$man")
  for perm in MANAGE_FINGERPRINT MANAGE_BIOMETRIC USE_BIOMETRIC_INTERNAL; do
    n=$(grep -cF "<uses-permission android:name=\"android.permission.$perm\"/>" <<<"$code")
    if [ "$n" -ge 1 ]; then echo "ok P4 the manifest asks for $perm"
    else echo "no P4 the manifest does not ask for $perm"; fi
  done
  # P5 NowhereChooser is not a priv-app, unless a privapp-permissions file grants it all three
  block=$(chooser_block "$bp")
  if [ -z "$block" ]; then echo "no control: the NowhereChooser module not found in Android.bp"
  elif [ -z "$(grep -E '^[[:space:]]*privileged:[[:space:]]*true' <<<"$block" || true)" ]; then
    echo "ok P5 NowhereChooser has no privileged: true, so no privapp-permissions entry is needed"
  else
    allow=no
    for g in "$PERMS"/privapp-permissions-com.nowhere.chooser*.xml; do
      [ -f "$g" ] || continue
      d=$(cat "$g")
      if [ -n "$(grep -F 'android.permission.MANAGE_FINGERPRINT' <<<"$d" || true)" ] \
          && [ -n "$(grep -F 'android.permission.MANAGE_BIOMETRIC"' <<<"$d" || true)" ] \
          && [ -n "$(grep -F 'android.permission.USE_BIOMETRIC_INTERNAL' <<<"$d" || true)" ]; then allow=yes; fi
    done
    if [ "$allow" = yes ]; then echo "ok P5 NowhereChooser is privileged and a privapp-permissions file grants all three"
    else echo "no P5 NowhereChooser has privileged: true and no privapp-permissions file grants it the three permissions"; fi
  fi
  # P6 run returns outside user 0 before the device-owner check, which precedes GateBiometricClear.run
  code=$(remove_run "$rem")
  g=$(lineof "$code" 'if (CredentialService.myUserId() != 0) return;')
  o=$(lineof "$code" '!dpm.isDeviceOwnerApp(ctx.getPackageName())) return;')
  b=$(lineof "$code" 'GateBiometricClear.run(')
  if [ -n "$g" ] && [ -n "$o" ] && [ -n "$b" ] && [ "$g" -lt "$o" ] && [ "$o" -lt "$b" ]; then
    echo "ok P6 GateBiometricRemove.run returns outside user 0, then outside the device owner, before it counts"
  else echo "no P6 GateBiometricRemove.run guards out of order or missing (user 0 at ${g:-none}, owner at ${o:-none}, run at ${b:-none})"; fi
  # P7 the reflected names
  code=$(nocomment "$rem")
  for lit in getEnrolledFingerprints getEnrolledFaces removeAll remove; do
    n=$(grep -cF "\"$lit\"" <<<"$code")
    if [ "$n" -ge 1 ]; then echo "ok P7 GateBiometricRemove reflects \"$lit\""
    else echo "no P7 GateBiometricRemove does not reflect \"$lit\""; fi
  done
  # P8 a Log line concatenates only literals, why, the Port line and an exception class name
  logs=$(grep 'Log\.' <<<"$code" | sed -E 's/"([^"\\]|\\.)*"//g; s/\+ *why\b//g; s/\+ *line\b//g; s/\+ *[A-Za-z_][A-Za-z0-9_]*\.getClass\(\)\.getSimpleName\(\)//g' \
    | grep -E '\+ *[A-Za-z_(]' || true)
  n=$(grep -c 'Log\.' <<<"$code")
  if [ "$n" -ge 1 ] && [ -z "$logs" ]; then echo "ok P8 every Log line in GateBiometricRemove carries why, the Port line or an exception class only"
  else echo "no P8 a Log line in GateBiometricRemove concatenates something else ($n Log lines): $logs"; fi
  # P9 GateBiometricClear stays pure java.*
  if [ -f "$clr" ]; then code=$(noblock "$clr"); else code="android. (the file is missing)"; fi
  n=$(grep -c 'android\.' <<<"$code")
  if [ "$n" = 0 ]; then echo "ok P9 GateBiometricClear.java names no android class"
  else echo "no P9 GateBiometricClear.java names an android class ($n line(s))"; fi
  # P10 the marker: its name, written through StoreInstaller.writeAtomic
  code=$(nocomment "$rem")
  n=$(grep -cF 'StoreInstaller.writeAtomic(removedMarker(ctx), "1");' <<<"$code")
  a=$(grep -cF 'new java.io.File(ctx.getFilesDir(), "gate-biometric-removed")' <<<"$code")
  if [ "$n" = 1 ] && [ "$a" = 1 ]; then echo "ok P10 the marker files/gate-biometric-removed is written through StoreInstaller.writeAtomic"
  else echo "no P10 the marker is not files/gate-biometric-removed through StoreInstaller.writeAtomic ($n writes, $a names)"; fi
}
run_pins(){ # run_pins <act> <remove> <manifest> <bp> <clear>: ok/no lines to the counters; 1 if any pin failed
  local line bad=0
  while IFS= read -r line; do
    case "$line" in ok\ *) ok "${line#ok }" ;; *) no "${line#no }"; bad=1 ;; esac
  done < <(pins "$1" "$2" "$3" "$4" "$5")
  return $bad
}

echo "== the cases =="
if [ -f "$CLEAR" ]; then cases "$CLEAR"; rc=$?; else echo "    $CLEAR is missing"; rc=3; fi
if [ "$rc" = 0 ]; then ok "every case passes"; else no "the cases did not pass (exit $rc: 1 a case failed, 3 no compile)"; fi
echo "== the source pins =="
run_pins "$ACT" "$REMOVE" "$MANIFEST" "$BP" "$CLEAR"; prc=$?

if [ "$MUTATE" = yes ] && [ "$rc" = 0 ] && [ "$prc" = 0 ]; then
  echo
  echo "== mutations (each MUST be convicted by a case or a pin) =="
  # mutate <case|clear|act|remove|manifest|bp> <label> <perl -0 script>: case mutates GateBiometricClear.java and runs
  # the cases; any other kind mutates that one file (clear: GateBiometricClear.java) and re-runs the pins.
  mutate(){
    local kind=$1 label=$2 script=$3 d src copy r out
    case "$kind" in
      case|clear) src=$CLEAR ;; act) src=$ACT ;; remove) src=$REMOVE ;; manifest) src=$MANIFEST ;; *) src=$BP ;;
    esac
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
      case "$kind" in
        act) out=$(pins "$copy" "$REMOVE" "$MANIFEST" "$BP" "$CLEAR") ;;
        remove) out=$(pins "$ACT" "$copy" "$MANIFEST" "$BP" "$CLEAR") ;;
        manifest) out=$(pins "$ACT" "$REMOVE" "$copy" "$BP" "$CLEAR") ;;
        clear) out=$(pins "$ACT" "$REMOVE" "$MANIFEST" "$BP" "$copy") ;;
        *) out=$(pins "$ACT" "$REMOVE" "$MANIFEST" "$copy" "$CLEAR") ;;
      esac
      if [ -n "$(grep '^no ' <<<"$out" || true)" ]; then ok "CONVICTED: $label"; else no "SURVIVED: $label -- the pins pass on broken code"; fi
    fi
    rm -rf "$d"
  }
  mutate case "M1 (B3, B4) the marker written on every action" \
    's/if \(a == Action\.REMOVED\) p\.writeMarker\(\);/p.writeMarker();/'
  mutate case "M2 (B5) REMOVED with templates left" 's/a = m == 0 \? Action\.REMOVED : Action\.REPORT;/a = m >= 0 ? Action.REMOVED : Action.REPORT;/'
  mutate case "M3 (B1) removeAll called with nothing enrolled" \
    's/(        int m = -1;\n)/$1        if (n == 0) { try { p.removeAll(); } catch (Throwable t) { } }\n/'
  mutate case "M4 (B6) a failed first read proceeds as 0" \
    's/(p\.log\("enrolled failed \([^\n]*\n) *return null;/$1            n = 0;/'
  mutate case "M5 (B8) REMOVED kept after it was shown" 's/return !REMOVED\.equals\(shownLine\);/return true;/'
  mutate case "M11 (B7) a failed recount answers REMOVED" \
    's/(p\.log\("recount failed \([^\n]*\n) *m = -1;/$1                    m = 0;/'
  mutate case "M13 (B9) the summary line prints a word" 's/"biometric-clear: before=" \+ n/"biometric-clear: before=n" + n/'
  mutate case "B8 the removed text changed" 's/so it was removed: what/so it was removed; what/'
  mutate case "B8 the report line shown after REMOVED too" 's/if \(last == Action\.REPORT\) return REPORTED;/if (last != null \&\& last != Action.NONE) return REPORTED;/'
  mutate case "B3 canRemove ignored" 's/\} else if \(!p\.canRemove\(\)\) \{\n *a = Action\.REPORT;\n/} else if (false) {\n/'
  mutate act "M6 (P1, P3) the onCreate call dropped" 's/\n *GateBiometricRemove\.runAsync\(this, "start"\);//'
  mutate act "M14 (P1) the onCreate call moved before the keyguard try" \
    's/\n *GateBiometricRemove\.runAsync\(this, "start"\);//; s/(\n *try \{\n *int cur = dpm\.getKeyguardDisabledFeatures\(admin\);)/\n                GateBiometricRemove.runAsync(this, "start");$1/'
  mutate act "P1, P3 the call moved out of the device-owner branch" \
    's/\n *GateBiometricRemove\.runAsync\(this, "start"\);//; s/(\n            android\.util\.Log\.w\("NowhereChooser", "clearAffiliationIds", t\);\n        \}\n)/$1        GateBiometricRemove.runAsync(this, "start");\n/'
  mutate act "P3 a second call on the return from System settings" \
    's/(\n *GateLockToken\.runAsync\(this, "rearm"\);)/$1 GateBiometricRemove.runAsync(this, "rearm");/'
  mutate act "M7 (P2) the menu call dropped" 's/\n *GateBiometricRemove\.addNotice\(this, ll, MUTED\);[^\n]*//'
  mutate manifest "M8 (P4) USE_BIOMETRIC_INTERNAL dropped" 's/\n *<uses-permission android:name="android\.permission\.USE_BIOMETRIC_INTERNAL"\/>//'
  mutate manifest "M8 (P4) MANAGE_FINGERPRINT dropped" 's/\n *<uses-permission android:name="android\.permission\.MANAGE_FINGERPRINT"\/>//'
  mutate manifest "M8 (P4) MANAGE_BIOMETRIC dropped" 's/\n *<uses-permission android:name="android\.permission\.MANAGE_BIOMETRIC"\/>//'
  mutate bp "M9 (P5) privileged: true added to NowhereChooser with no allowlist file" \
    's/(    name: "NowhereChooser",\n(?:[^\n]*\n)*?    certificate: "platform",\n)/$1    privileged: true,\n/'
  mutate remove "M10 (P6) the user-0 guard dropped" 's/\n *if \(CredentialService\.myUserId\(\) != 0\) return;[^\n]*//'
  mutate remove "P6 the device-owner guard dropped" 's/ \|\| !dpm\.isDeviceOwnerApp\(ctx\.getPackageName\(\)\)//'
  mutate remove "M12 (P8) a Log line appends the templates" 's/(": " \+ line)\);/$1 + templates(ctx, true));/'
  mutate remove "P7 the face count not reflected" 's/"getEnrolledFaces"/"getFaces"/'
  mutate clear "P9 GateBiometricClear imports an android class" 's/^(package com\.nowhere\.chooser;\n)/$1\nimport android.util.Log;\n/'
  mutate remove "P10 the marker written with a FileWriter" \
    's/StoreInstaller\.writeAtomic\(removedMarker\(ctx\), "1"\);/try (java.io.FileWriter w = new java.io.FileWriter(removedMarker(ctx))) { w.write("1"); }/'
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
