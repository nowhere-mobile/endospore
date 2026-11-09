#!/usr/bin/env bash
# test-install-wait-java.sh [--mutate] -- the big-install wait-and-decide rule, run under javac (NWP-20261022-10).
#
# WHY THIS IS COMMITTED. "A TIMEOUT IS NOT A VERDICT" (NWP-20260831-03): a committed install that outlives the old
# single 120s latch was reported FAILURE and aborted every app depending on it, while the install then succeeded
# unobserved (lynx 2026-08-30, a 243MB gms set landing at ~4 minutes). The rule existed twice, by copy, in
# UnarchiveService.installApks and ChooserActivity.installApkSet, and no suite executed either. It is now one pure
# class, InstallWait, compiled here with simulated-time cases; the PINS check that all three sites (those two and
# StoreInstaller.installStaged, NWP-20261129-21) call it, map LANDED to success, read the session defensively and
# (installApkSet) read the codePath as the target user. The store site's pins also forbid its old 180 s latch and
# isInstalled verdict, and require HARD_BOUND to answer PENDING and pathBefore to be read before the commit.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-install-wait-java.sh            # the cases + pins
#   bash test-install-wait-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
HELPER="$root/core/chooser/src/com/nowhere/chooser/InstallWait.java"
SVC="$root/core/chooser/src/com/nowhere/chooser/UnarchiveService.java"
ACT="$root/core/chooser/src/com/nowhere/chooser/ChooserActivity.java"
STORE="$root/core/chooser/src/com/nowhere/chooser/StoreInstaller.java"
CASES="$root/core/chooser/tests/install-wait/InstallWaitCases.java"
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
command -v perl >/dev/null 2>&1 || { echo "FAIL: this suite needs perl, and there is none" >&2; exit 2; }
[ -f "$SVC" ] && [ -f "$ACT" ] && [ -f "$STORE" ] && [ -f "$CASES" ] || { echo "FAIL: missing $SVC, $ACT, $STORE or $CASES" >&2; exit 2; }

# method <file> <name> -> the method's text, from its 4-space-indented signature line to its closing 4-space brace.
method() {
  perl -0ne 'print $1 if /(\n    (?! )[^\n]*\b'"$2"'\([^\n]*\{\n.*?\n    \}\n)/s' "$1"
}

# pins <label> <method text> <site: svc|act|store> -> sets bad=1 (caller's local) on a failed pin.
pins() {
  local label="$1" body="$2" site="$3" n
  if [ -z "$body" ]; then echo "  PIN   $label: the method was not found" >&2; bad=1; return; fi
  n=$(printf '%s' "$body" | perl -0ne 'my $c = () = /InstallWait\.await\(/g; print $c')
  [ "$n" = 1 ] || { echo "  PIN   $label: expected exactly one InstallWait.await( call, found ${n:-0}" >&2; bad=1; }
  printf '%s' "$body" | perl -0ne 'exit(/while \(!latch\.await\(30/ ? 1 : 0)' || {
    echo "  PIN   $label: holds its own while (!latch.await(30 loop again" >&2; bad=1; }
  printf '%s' "$body" | perl -0ne 'exit(/if \(outcome == InstallWait\.Outcome\.LANDED\) st\[0\] = (?:android\.content\.pm\.)?PackageInstaller\.STATUS_SUCCESS;/ ? 0 : 1)' || {
    echo "  PIN   $label: LANDED is no longer mapped to STATUS_SUCCESS" >&2; bad=1; }
  printf '%s' "$body" | perl -0ne 'exit(/if \(outcome != InstallWait\.Outcome\.BROADCAST\) stMsg\[0\] = InstallWait\.message\(outcome\);/ ? 0 : 1)' || {
    echo "  PIN   $label: the outcome message is no longer recorded for a non-BROADCAST outcome" >&2; bad=1; }
  printf '%s' "$body" | perl -0ne 'exit(/\(\) -> \{ try \{ return pi\.getSessionInfo\(sid\) != null; \} catch \(Throwable \w+\) \{ return false; \} \}/ ? 0 : 1)' || {
    echo "  PIN   $label: the session adapter no longer reads getSessionInfo(sid) in a try/catch that answers false" >&2; bad=1; }
  if [ "$site" = act ]; then
    printf '%s' "$body" | perl -0ne 'exit(/\(\) -> \{ try \{ return createContextAsUser\(android\.os\.UserHandle\.of\(uid\), 0\)\s*\.getPackageManager\(\)\.getApplicationInfo\(pkg, 0\)\.sourceDir;/ ? 0 : 1)' || {
      echo "  PIN   $label: the codePath no longer goes through createContextAsUser(UserHandle.of(uid), 0)" >&2; bad=1; }
  fi
  if [ "$site" = store ]; then
    printf '%s' "$body" | perl -0ne 'exit(/latch\.await\(180/ ? 1 : 0)' || {
      echo "  PIN   $label: the single 180 s latch is back" >&2; bad=1; }
    printf '%s' "$body" | perl -0ne 'exit(/isInstalled\(ctx, pkg\) \? OK : PENDING/ ? 1 : 0)' || {
      echo "  PIN   $label: an installed old version answers OK again" >&2; bad=1; }
    n=$(printf '%s' "$body" | perl -0ne 'my $c = () = /if \(outcome == InstallWait\.Outcome\.HARD_BOUND\) return PENDING;/g; print $c')
    [ "$n" = 1 ] || { echo "  PIN   $label: expected HARD_BOUND to return PENDING exactly once, found ${n:-0}" >&2; bad=1; }
    printf '%s' "$body" | perl -0ne 'exit(/pathBefore = ctx\.getPackageManager\(\)\.getApplicationInfo\(pkg, 0\)\.sourceDir;.*ses\.commit\(/s ? 0 : 1)' || {
      echo "  PIN   $label: pathBefore is no longer read before ses.commit(" >&2; bad=1; }
  fi
}

# suite <InstallWait.java> <UnarchiveService.java> <ChooserActivity.java> <StoreInstaller.java> -> 0 pass, 1 a case or
# pin failed (the only code that convicts a mutant), 3 the helper or the cases did not compile.
suite() {
  local helper="$1" svc="$2" act="$3" store="$4" d out rc
  local bad=0
  pins installApks "$(method "$svc" installApks)" svc
  pins installApkSet "$(method "$act" installApkSet)" act
  pins installStaged "$(method "$store" installStaged)" store
  [ -f "$helper" ] || { echo "  FAIL  InstallWait.java does not exist (the wait-and-decide rule is missing)" >&2; return 1; }
  [ "$bad" -eq 0 ] || return 1
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$helper" "$d/src/com/nowhere/chooser/InstallWait.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/InstallWaitCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.InstallWaitCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

echo "== $HELPER"
suite "$HELPER" "$SVC" "$ACT" "$STORE" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED -- a mutant that does not compile proves nothing)"
mut() { # mut <label> <helper|svc|act|store> <perl-expr>
  local d h s a i rc target
  d=$(mktemp -d -p "$W"); h="$d/InstallWait.java"; s="$d/UnarchiveService.java"; a="$d/ChooserActivity.java"; i="$d/StoreInstaller.java"
  cp "$HELPER" "$h"; cp "$SVC" "$s"; cp "$ACT" "$a"; cp "$STORE" "$i"
  case "$2" in helper) target="$h" ;; svc) target="$s" ;; store) target="$i" ;; *) target="$a" ;; esac
  if ! perl -0pi -e "$3" "$target"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$HELPER" "$h" && cmp -s "$SVC" "$s" && cmp -s "$ACT" "$a" && cmp -s "$STORE" "$i"; then
    echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  suite "$h" "$s" "$a" "$i" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "M1 the re-arm is a single wait"                    helper 's/while \(!latch\.await\(BEAT_MS\)\)/if (!latch.await(BEAT_MS))/' || fails=$((fails+1))
mut "M2 the 5s lag beat removed"                        helper 's/\n\s*if \(latch\.await\(LAG_MS\)\) return Outcome\.BROADCAST;//' || fails=$((fails+1))
mut "M3 the codePath test inverted"                     helper 's/!after\.equals\(pathBefore\)/after.equals(pathBefore)/' || fails=$((fails+1))
mut "M4 a null pathBefore reads as unchanged"           helper 's/after != null && !after\.equals\(pathBefore\)/after != null \&\& pathBefore != null \&\& !after.equals(pathBefore)/' || fails=$((fails+1))
mut "M5 the hard-bound check removed"                   helper 's/\n\s*if \(clock\.now\(\) > deadline\) return Outcome\.HARD_BOUND;//' || fails=$((fails+1))
mut "M6 LANDED not mapped to STATUS_SUCCESS (installApks)" svc 's/if \(outcome == InstallWait\.Outcome\.LANDED\) st\[0\] = PackageInstaller\.STATUS_SUCCESS;/\/\/ dropped/' || fails=$((fails+1))
mut "M7 installApkSet reverted to its own loop"         act   's/InstallWait\.Outcome outcome = InstallWait\.await\(.*?\(NWP-20260831-03\)"\)\);/InstallWait.Outcome outcome = InstallWait.Outcome.BROADCAST;\n                while (!latch.await(30, java.util.concurrent.TimeUnit.SECONDS)) { if (pi.getSessionInfo(sid) == null) break; }/s' || fails=$((fails+1))
mut "S1 the store site's single 180 s latch and old verdict restored" store 's/outcome = InstallWait\.await\(.*?\(NWP-20261129-21\)"\)\);\n\s*if \(outcome == InstallWait\.Outcome\.LANDED\)[^\n]*\n\s*if \(outcome != InstallWait\.Outcome\.BROADCAST\)[^\n]*\n/replied = latch.await(180, java.util.concurrent.TimeUnit.SECONDS);\n/s; s/if \(outcome == InstallWait\.Outcome\.HARD_BOUND\) return PENDING;\n\s*return st\[0\][^\n]*\n/if (replied) return st[0] == android.content.pm.PackageInstaller.STATUS_SUCCESS ? OK : FAIL;\n                return isInstalled(ctx, pkg) ? OK : PENDING;\n/' || fails=$((fails+1))
mut "S2 HARD_BOUND returns OK"                          store 's/if \(outcome == InstallWait\.Outcome\.HARD_BOUND\) return PENDING;/if (outcome == InstallWait.Outcome.HARD_BOUND) return OK;/' || fails=$((fails+1))
mut "S3 LANDED not mapped to STATUS_SUCCESS (installStaged)" store 's/if \(outcome == InstallWait\.Outcome\.LANDED\) st\[0\] = android\.content\.pm\.PackageInstaller\.STATUS_SUCCESS;/\/\/ dropped/' || fails=$((fails+1))
mut "S4 pathBefore read after the commit"               store 's/\n\s*try \{\n\s*pathBefore = ctx\.getPackageManager\(\)\.getApplicationInfo\(pkg, 0\)\.sourceDir;\n\s*\} catch \(Throwable notInstalled\) \{ \}//; s/(committed = true;[^\n]*\n)/$1                    try { pathBefore = ctx.getPackageManager().getApplicationInfo(pkg, 0).sourceDir; } catch (Throwable notInstalled) { }\n/' || fails=$((fails+1))
mut "S5 the session adapter answers true on a throw"    store 's/(return pi\.getSessionInfo\(sid\) != null; \} catch \(Throwable \w+\) \{ return) false;/$1 true;/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
