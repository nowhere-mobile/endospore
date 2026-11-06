#!/usr/bin/env bash
# test-doze-absent-java.sh [--mutate] -- NWP-20261104-16 (Q054, docs/product-decisions.md 2026-10-20): which recorded
# Doze names DozeAppsMirror.capture keeps once their app is not installed, compiled and EXECUTED
# (core/chooser/tests/doze-absent/run.sh says how).
#
# WHY THIS IS COMMITTED. capture keeps a recorded name whose app is absent, because an app the sign-in could not
# install is not a choice turned off. Kept for EVERY absent name, a user who uninstalled an Unrestricted app and
# reinstalled it in a session that cold-locked before a capture got Unrestricted back at the next sign-in. The rule is
# now two inputs: the profile's keep record (files/nowhere-appkeep) must still carry the app, AND this session must not
# have watched it be uninstalled (StoreInstaller.appGoneThisSession). Neither alone is enough: an uninstall's keep line
# is pruned only at logoff by captureAppCode, which runs AFTER DozeAppsMirror.capture, so within the uninstalling
# session the keep record still carries the app and only the gone set says otherwise.
#
# Two halves: the cases (keptPackages, absentKept) run under javac, and source pins on capture check that it reads the
# gone set OUTSIDE its synchronized (CAPTURE_LOCK) block (appGoneThisSession takes APPKEEP_LOCK; the two never nest) and
# hands absentFrom the keep file and that set.
#
# It needs a JDK, and it FAILS when there is none. javac/java come from PATH, then the build VM's prebuilt JDK 21.
# --mutate re-runs it against deliberately broken copies, each of which must fail a CASE or a PIN.
#
#   bash test-doze-absent-java.sh            # the cases and the pins
#   bash test-doze-absent-java.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail
MUTATE=no; for a in "$@"; do [ "$a" = --mutate ] && MUTATE=yes; done
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
CH="$ROOT/core/chooser"
RUN="$CH/tests/doze-absent/run.sh"
DM_REL=src/com/nowhere/chooser/DozeAppsMirror.java
DM="$CH/$DM_REL"
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-doze-absent-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
export JAVAC JAVA
# One root: every temp of this suite lives inside $W (run.sh makes and removes its own inside it).
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export W

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

# capture_of <file>: the lines of capture() with // comments dropped (the pinned lines hold no // inside a literal)
capture_of(){
  awk '
    !on && index($0, "    static void capture(Context ctx) {") == 1 { on=1; depth=0 }
    on { l=$0; sub(/\/\/.*$/, "", l); print l; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
  ' "$1"
}
# absent_of <file>: the lines of absentFrom(), same treatment
absent_of(){
  awk '
    !on && index($0, "    static java.util.Set<String> absentFrom(") == 1 { on=1; depth=0 }
    on { l=$0; sub(/\/\/.*$/, "", l); print l; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
  ' "$1"
}
# pins <file>: prints one "ok|no <label>" per pin on capture and absentFrom
pins(){
  local cap abs ncall callno syncno joined
  cap=$(capture_of "$1"); abs=$(absent_of "$1")
  ncall=$(grep -cF 'StoreInstaller.appGoneThisSession(ctx)' <<<"$cap" || true)
  if [ "$ncall" = 1 ]; then echo "ok capture calls appGoneThisSession exactly once"; else echo "no capture calls appGoneThisSession $ncall times, not once"; fi
  syncno=$(grep -n '^        synchronized (CAPTURE_LOCK) {$' <<<"$cap" | cut -d: -f1)
  callno=$(grep -nF 'StoreInstaller.appGoneThisSession(ctx)' <<<"$cap" | head -1 | cut -d: -f1)
  if [ "$(grep -c . <<<"$syncno")" = 1 ]; then echo "ok control: capture holds CAPTURE_LOCK in one synchronized block"; else echo "no control: the synchronized (CAPTURE_LOCK) line did not match once"; fi
  if [ -n "$callno" ] && [ -n "$syncno" ] && [ "$callno" -lt "$syncno" ]; then echo "ok the gone set is read before CAPTURE_LOCK is taken"; else echo "no the gone set is not read before the synchronized (CAPTURE_LOCK) block"; fi
  joined=$(tr -s ' \n' ' ' <<<"$cap")
  if grep -qF 'absentFrom(installed, new java.io.File(dir, "nowhere-doze-apps"), new java.io.File(dir, "nowhere-appkeep"), gone)' <<<"$joined"; then echo "ok capture passes the keep file and the gone set to absentFrom"; else echo "no capture does not pass the keep file and the gone set to absentFrom"; fi
  joined=$(tr -s ' \n' ' ' <<<"$abs")
  if grep -qF 'return absentKept(names, recorded, keptPackages(keepFile), gone);' <<<"$joined"; then echo "ok absentFrom decides through keptPackages and absentKept"; else echo "no absentFrom does not decide through keptPackages and absentKept"; fi
}
run_pins(){ # run_pins <file>: ok/no lines to the counters; returns 1 if any pin failed
  local line bad=0
  while IFS= read -r line; do
    case "$line" in ok\ *) ok "${line#ok }" ;; *) no "${line#no }"; bad=1 ;; esac
  done < <(pins "$1")
  return $bad
}

echo "== the cases =="
bash "$RUN" "$DM"; rc=$?
if [ "$rc" = 0 ]; then ok "every case passes"; else no "the suite did not pass (run.sh exit $rc: 1 a case, 2 cannot run, 3 no compile)"; fi
echo "== the capture pins =="
run_pins "$DM"; prc=$?
# a comment line added inside capture changes no pinned code
cp "$DM" "$W/probe.java"
sed -i 's|^    static void capture(Context ctx) {$|&\n        // probe: a comment inside capture|' "$W/probe.java"
if cmp -s "$W/probe.java" "$DM"; then no "probe copy is inert"; elif [ -z "$(pins "$W/probe.java" | grep '^no ' || true)" ]; then ok "a comment added inside capture leaves the pins green"; else no "a comment inside capture broke a pin"; fi

if [ "$MUTATE" = yes ] && [ "$rc" = 0 ] && [ "$prc" = 0 ]; then
  echo
  echo "== mutations (each MUST be convicted by a case or a pin) =="
  mutate(){ # mutate <kind case|pin> <label> <sed script>
    local kind=$1 label=$2 script=$3 r
    rm -rf "$W/c"; mkdir -p "$W/c"
    cp "$DM" "$W/c/DozeAppsMirror.java"
    if ! sed -i "$script" "$W/c/DozeAppsMirror.java" 2>"$W/err"; then no "MUTATION BROKEN (sed): $label"; return; fi
    if cmp -s "$W/c/DozeAppsMirror.java" "$DM"; then no "MUTATION INERT: $label"; return; fi
    if [ "$kind" = case ]; then
      bash "$RUN" "$W/c/DozeAppsMirror.java" >/dev/null 2>&1; r=$?
      case "$r" in
        1) ok "convicted: $label" ;;
        0) no "NOT CONVICTED: $label -- suite passes on broken code" ;;
        *) no "MUTATION BROKEN (run.sh exit $r, not a case): $label" ;;
      esac
    else
      if [ -n "$(pins "$W/c/DozeAppsMirror.java" | grep '^no ' || true)" ]; then ok "convicted: $label"; else no "NOT CONVICTED: $label -- the pins pass on broken code"; fi
    fi
  }
  mutate case "kept ignored (today's code)" '/if (kept != null && !kept.contains(p)) continue;/d'
  mutate case "gone ignored" 's/if (installed.contains(p) || gone.contains(p)) continue;/if (installed.contains(p)) continue;/'
  mutate case "null treated as empty" 's/if (kept != null && !kept.contains(p))/if (kept == null || !kept.contains(p))/'
  mutate case "the tab split dropped" 's/String pkg = l.split("\\t", 2)\[0\].trim();/String pkg = l;/'
  mutate pin "the gone read moved inside CAPTURE_LOCK" '/^        java.util.Set<String> gone;/{N;d}; s/^        synchronized (CAPTURE_LOCK) {$/&\n        java.util.Set<String> gone = StoreInstaller.appGoneThisSession(ctx);/'
  mutate pin "capture no longer passes the keep file" 's/new java.io.File(dir, "nowhere-appkeep"), gone)/null, gone)/'
  mutate pin "capture passes an empty gone set" 's/"nowhere-appkeep"), gone)/"nowhere-appkeep"), java.util.Collections.emptySet())/'
  mutate pin "absentFrom bypasses keptPackages" 's/keptPackages(keepFile)/null/'
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
