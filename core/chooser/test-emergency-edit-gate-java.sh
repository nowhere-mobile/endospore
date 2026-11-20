#!/usr/bin/env bash
# test-emergency-edit-gate-java.sh [--mutate] [--root <tree>] -- Emergency information is read-only at the gate and is
# edited only from owner mode, run under javac (NWP-20261210-21).
#
# WHY THIS IS COMMITTED. docs/product-decisions.md, 2026-11-02, #12: Emergency information is read-only at the gate and
# is edited only from owner mode, after the owner passphrase; emergency dialling is unchanged. The gate keeps
# com.android.emergency in its Lock Task allowlist (the dialer opens the read-only card from there), so the gate
# disables the platform EmergencyInfo app's two editors in user 0 every time it locks the kiosk, and sets them back to
# their default state only while owner mode stands the kiosk down for System settings. The rule is EmergencyEditGate.java,
# pure Java, so tests/emergency-edit-gate/run.sh compiles it with EmergencyEditGateCases and runs C1-C5. The PINS read
# ChooserActivity.java and AndroidManifest.xml as data (perl anchors, never line numbers):
#   P1 lockGate's device-owner `if (lock) {` arm calls applyEmergencyEditGate(false) before dpm.setLockTaskPackages
#   P2 standDownForOwner(Intent) calls applyEmergencyEditGate(true) after `sOwnerSession = true`, before startActivity(target
#   P3 exactly one applyEmergencyEditGate(true) in the file (no other caller enables the editors)
#   P4 setLockTaskPackages still lists getPackageName(), "com.android.phone", "com.android.emergency" (dialling unchanged)
#   P5 the manifest still declares CHANGE_COMPONENT_ENABLED_STATE (a guard: it passes on main)
#   P6 applyEmergencyEditGate catches Throwable inside its loop, and its only Log call's message is EmergencyEditGate.line(
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK; the version
# is printed first so the log proves which compiler ran.
#
#   bash test-emergency-edit-gate-java.sh                 # the cases and the pins
#   bash test-emergency-edit-gate-java.sh --mutate        # ... plus broken copies that must each FAIL
#   bash test-emergency-edit-gate-java.sh --root <tree>   # run against another checkout's core/chooser (e.g. main's)
set -uo pipefail

MUTATE=no
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
while [ $# -gt 0 ]; do
  case "$1" in
    --mutate) MUTATE=yes ;;
    --root) [ $# -ge 2 ] || { echo "usage: $0 [--mutate] [--root <tree>]" >&2; exit 2; }; root=$(cd "$2" && pwd) || exit 2; shift ;;
    *) echo "usage: $0 [--mutate] [--root <tree>]" >&2; exit 2 ;;
  esac
  shift
done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

DIR="$root/core/chooser/src/com/nowhere/chooser"
EG="$DIR/EmergencyEditGate.java"
CA="$DIR/ChooserActivity.java"
MF="$root/core/chooser/AndroidManifest.xml"
RUN="$here/tests/emergency-edit-gate/run.sh"
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
export JAVAC JAVA W TMPDIR="$W"
"$JAVAC" -J-Djava.io.tmpdir="$W" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "FAIL: no perl -- the pins need it" >&2; exit 2; }
[ -f "$CA" ] && [ -f "$MF" ] && [ -f "$RUN" ] || { echo "FAIL: missing $CA, $MF or $RUN" >&2; exit 2; }

# pin <file> <label> <perl-regex>: a textual check (anchors, not line numbers).
pin() {
  perl -0ne "exit(/$3/s ? 0 : 1)" "$1" || { echo "  PIN   $2" >&2; return 1; }
}

# The body of a 4-space-indented method ends at the first "\n    }\n" after its signature; (?:(?!$END).)*? keeps a
# match inside that body.
END='\n    \}\n'

# suite <EmergencyEditGate.java> <ChooserActivity.java> <AndroidManifest.xml> -> 0 pass, 1 a case or a pin failed,
# 3 compile.
suite() {
  local eg="$1" ca="$2" mf="$3" n bad=0
  # P1: the device-owner lock arm disables the editors, and does it before the allowlist is set.
  pin "$ca" "P1 lockGate's if (lock) arm does not call applyEmergencyEditGate(false) before dpm.setLockTaskPackages" \
    "private void lockGate\\(boolean lock\\) \\{(?:(?!$END).)*?if \\(owner\\) \\{\\s*if \\(lock\\) \\{(?:(?!setLockTaskPackages|$END|\\} else \\{).)*?\\n\\s*applyEmergencyEditGate\\(false\\);(?:(?!$END).)*?dpm\\.setLockTaskPackages\\(" || bad=1
  # P2: owner mode's stand-down enables them after the owner flag is set and before the target launches.
  pin "$ca" "P2 standDownForOwner(Intent) does not call applyEmergencyEditGate(true) between sOwnerSession = true and startActivity(target" \
    "private void standDownForOwner\\(android\\.content\\.Intent target\\) \\{(?:(?!$END).)*?\\n\\s*sOwnerSession = true;(?:(?!$END|startActivity\\(target).)*?\\n\\s*applyEmergencyEditGate\\(true\\);(?:(?!$END).)*?startActivity\\(target" || bad=1
  # P3: no other caller enables them.
  n=$(perl -0ne 'my $c = () = /applyEmergencyEditGate\(true\)/g; print $c' "$ca")
  [ "$n" = 1 ] || { echo "  PIN   P3 applyEmergencyEditGate(true) occurs $n times, not once" >&2; bad=1; }
  # P4: the allowlist is unchanged, so the emergency dialer and the read-only card stay reachable at the gate.
  pin "$ca" "P4 setLockTaskPackages no longer lists getPackageName(), com.android.phone and com.android.emergency" \
    'dpm\.setLockTaskPackages\(new android\.content\.ComponentName\(this, AdminReceiver\.class\),\s*new String\[\]\{getPackageName\(\), "com\.android\.phone", "com\.android\.emergency"\}\);' || bad=1
  # P5: the permission the component writes need.
  pin "$mf" "P5 AndroidManifest.xml does not declare CHANGE_COMPONENT_ENABLED_STATE" \
    '<uses-permission android:name="android\.permission\.CHANGE_COMPONENT_ENABLED_STATE"\/>' || bad=1
  # P6: one catch per component inside the loop (a failure is counted, never a crash or a skipped lock), and one log
  # line whose message is the counts-only line and nothing else.
  pin "$ca" "P6 applyEmergencyEditGate does not catch Throwable per component inside its loop" \
    "private void applyEmergencyEditGate\\(boolean ownerStoodDown\\) \\{(?:(?!$END).)*?for \\(String cls : EmergencyEditGate\\.EDITORS\\) \\{\\s*try \\{(?:(?!$END).)*?\\} catch \\(Throwable t\\) \\{\\s*failed\\+\\+;\\s*\\}\\s*\\}" || bad=1
  n=$(perl -0ne 'if (/private void applyEmergencyEditGate\(boolean ownerStoodDown\) \{(.*?)\n    \}\n/s) { my $b = $1; my $c = () = $b =~ /Log\./g; print $c } else { print "none" }' "$ca")
  [ "$n" = 1 ] || { echo "  PIN   P6 applyEmergencyEditGate has $n Log calls, not 1" >&2; bad=1; }
  pin "$ca" "P6 applyEmergencyEditGate's Log call is not Log.i(\"NowhereChooser\", EmergencyEditGate.line(...)) alone" \
    "private void applyEmergencyEditGate\\(boolean ownerStoodDown\\) \\{(?:(?!$END).)*?android\\.util\\.Log\\.i\\(\"NowhereChooser\", EmergencyEditGate\\.line\\(ownerStoodDown, changed, kept, failed\\)\\);" || bad=1
  # C1-C5: the pure rule. A tree without the class fails each case by name rather than as a compile error.
  if [ ! -f "$eg" ]; then
    echo "--- FAIL C1 EmergencyEditGate.java does not exist"
    echo "--- FAIL C2 EmergencyEditGate.java does not exist"
    echo "--- FAIL C3 EmergencyEditGate.java does not exist"
    echo "--- FAIL C4 EmergencyEditGate.java does not exist"
    echo "--- FAIL C5 EmergencyEditGate.java does not exist"
    return 1
  fi
  bash "$RUN" "$eg"; n=$?
  [ "$n" = 0 ] || return "$n"
  return "$bad"
}

echo "== $EG"
suite "$EG" "$CA" "$MF" || { echo "FAILED"; exit 1; }
echo "== all cases and pins passed"
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED -- a mutant that does not apply or compile proves nothing)"
# mut <label> <which: eg|ca|mf> <perl-expr> <convicting line> [survive]: the mutant is CONVICTED only when the suite
# fails AND its output holds <convicting line> (a fixed string: the failing case or pin the label names). With a fifth
# argument "survive" it is a CONTROL and must pass.
mut() {
  local d src m egf caf mff rc
  d=$(mktemp -d -p "$W")
  egf="$EG"; caf="$CA"; mff="$MF"
  case "$2" in eg) src="$EG" ;; ca) src="$CA" ;; mf) src="$MF" ;; esac
  m="$d/$(basename "$src")"
  if ! perl -0pe "$3" "$src" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; return 1; fi
  if cmp -s "$src" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; return 1; fi
  case "$2" in eg) egf="$m" ;; ca) caf="$m" ;; mf) mff="$m" ;; esac
  suite "$egf" "$caf" "$mff" >"$d/out" 2>&1; rc=$?
  if [ "${5:-}" = survive ]; then
    if [ "$rc" = 0 ]; then echo "  survived  $1 (control)"; return 0; fi
    echo "  KILLED    $1 -- the control must pass (rc=$rc)"; sed 's/^/      /' "$d/out"; return 1
  fi
  # Only a failing CASE ("--- FAIL") or a failing PIN convicts; a compile error (rc 3) is a broken mutant.
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) if grep -qF -- "$4" "$d/out"; then echo "  convicted $1"; return 0; fi
       echo "  WRONG     $1 -- the suite failed, but not on: $4"; sed 's/^/      /' "$d/out"; return 1 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "M1 wanted inverted (case C1)" eg \
  's/return ownerStoodDown \? STATE_DEFAULT : STATE_DISABLED;/return ownerStoodDown ? STATE_DISABLED : STATE_DEFAULT;/' \
  '--- FAIL C1 ' || fails=$((fails+1))
mut "M2 EditMedicalInfoActivity dropped (case C2)" eg \
  's/\n\s*PKG \+ "\.edit\.EditMedicalInfoActivity",//' \
  '--- FAIL C2 ' || fails=$((fails+1))
mut "M3 .view.ViewInfoActivity added (case C2)" eg \
  's/(PKG \+ "\.edit\.EditMedicalInfoActivity",)/$1\n        PKG + ".view.ViewInfoActivity",/' \
  '--- FAIL C2 ' || fails=$((fails+1))
mut "M4 needsWrite always false (case C3)" eg \
  's/return current != wanted;/return false;/' \
  '--- FAIL C3 ' || fails=$((fails+1))
mut "M5 DONT_KILL_APP on disable (case C4)" eg \
  's/return wanted == STATE_DISABLED \? 0 : DONT_KILL_APP;/return DONT_KILL_APP;/' \
  '--- FAIL C4 ' || fails=$((fails+1))
mut "M6 the log line's shape changed (case C5)" eg \
  's/" kept="/" kept: "/' \
  '--- FAIL C5 ' || fails=$((fails+1))
mut "M7 the lockGate call removed (pin P1)" ca \
  's/\n[ \t]*applyEmergencyEditGate\(false\);\n/\n/' \
  'PIN   P1 ' || fails=$((fails+1))
mut "M8 the lockGate call moved after setLockTaskPackages (pin P1)" ca \
  's/\n([ \t]*)applyEmergencyEditGate\(false\);\n(\s*dpm\.setLockTaskPackages\([^;]*;[^\n]*\n)/\n$2$1applyEmergencyEditGate(false);\n/' \
  'PIN   P1 ' || fails=$((fails+1))
mut "M9 the standDown call removed (pin P2)" ca \
  's/\n[ \t]*applyEmergencyEditGate\(true\);[^\n]*\n/\n/' \
  'PIN   P2 ' || fails=$((fails+1))
mut "M10 applyEmergencyEditGate(true) added to lockGate (pin P3)" ca \
  's/(\n([ \t]*)stopLockTask\(\);\n)/\n$2applyEmergencyEditGate(true);$1/' \
  'PIN   P3 ' || fails=$((fails+1))
mut "M11 com.android.emergency dropped from setLockTaskPackages (pin P4)" ca \
  's/new String\[\]\{getPackageName\(\), "com\.android\.phone", "com\.android\.emergency"\}/new String[]{getPackageName(), "com.android.phone"}/' \
  'PIN   P4 ' || fails=$((fails+1))
mut "M12 the permission removed (pin P5)" mf \
  's/\n[ \t]*<uses-permission android:name="android\.permission\.CHANGE_COMPONENT_ENABLED_STATE"\/>//' \
  'PIN   P5 ' || fails=$((fails+1))
mut "M13 the per-component catch removed (pin P6)" ca \
  's/\} catch \(Throwable t\) \{\n(\s*)failed\+\+;\n(\s*)\}/} finally {\n$2}/' \
  'PIN   P6 ' || fails=$((fails+1))
mut "M14 control: a comment's wording changes (must survive)" eg \
  's/Its two exported editors\./The two exported editors./' \
  '' survive || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted, the control survived" || { echo "== $fails mutation(s) not convicted"; exit 1; }
