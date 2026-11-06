#!/usr/bin/env bash
# test-install-default-java.sh [<AppInstallReceiver.java>] [--mutate] -- AppInstallReceiver.decide, the one decision that
# writes, resets or clears a newly installed app's keep line, run under javac (NWP-20261021-09).
#
# WHY THIS IS COMMITTED. decide's branch ORDER is the behaviour: replacing; bundled; the nApps bucket; the bucket whose
# default is off (clearing a stale line only when `returning && keepSetHas`); the Off record; the returning reset
# (removeKeepLines, then keepInMode); "left alone"; then keep. The backlog row "A RE-INSTALLED APP INHERITS THE PREVIOUS
# INSTALL'S TIER" (NWP-20260922-01) shipped its fix with no test, and its first diagnosis was wrong precisely because it
# misread that order (the off default is tested BEFORE the Off record). Two plausible tidy-ups -- a reorder, or a dropped
# `returning &&` -- would silently keep an app the user switched Off, or clear a keep line an nApps install had just
# written, with CI green. test-yourapps-off-row.sh pins one ordering by text and test-keepset-uninstall.sh pins the removal
# receiver; nothing executed decide. core/chooser/tests/install-default/run.sh lifts decide verbatim from
# AppInstallReceiver.java, and cfgKeyForInstaller plus the constants it reads verbatim from ProfileActivity.java (so the
# real installer-to-bucket mapping runs), stubs what else decide asks (counted) and runs InstallDefaultCases.
#
# This suite pins SHIPPED behaviour: its cases pass on main. What must fail is every mutant below.
# NWP-20261122-06 added the Play choice (PlayChoice, copied in by run.sh as-is): with play.wanted=1 Play Store, Play
# services and GSF are kept On-demand whatever the bucket says, and a Play Store keep is recorded in nowhere-playdeps;
# without the GrapheneOS App Store (Diaspore) the flag changes nothing.
# What it does NOT prove: the device run on that row (install from Aurora, set On-demand, uninstall in Settings, reinstall
# in the same session; Your apps shows it Off, the bucket default).
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (exit 2), like the other javac suites.
#
#   bash test-install-default-java.sh            # the cases
#   bash test-install-default-java.sh --mutate   # ... plus broken copies that must each FAIL the cases
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/src/com/nowhere/chooser/AppInstallReceiver.java"
PA="$HERE/src/com/nowhere/chooser/ProfileActivity.java"
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SRC="$a" ;; esac; done
RUN="$HERE/tests/install-default/run.sh"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite did NOT run and does not skip: install a JDK or" \
       "run it on the build VM." >&2
  exit 2
fi
export JAVAC JAVA
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
[ -f "$SRC" ] && [ -f "$PA" ] && [ -f "$RUN" ] || { echo "FAIL: missing $SRC, $PA or $RUN" >&2; exit 2; }

# One root for everything this suite creates (run.sh's work dir, every mutant copy); one trap.
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
export INSTALL_DEFAULT_TMP="$W"

# suite <AppInstallReceiver.java> -> run.sh's code: 0 pass, 1 a case failed (only this may convict a mutant), 2 a member
# did not extract, 3 the lifted classes did not compile.
suite() { bash "$RUN" "$1" "$PA"; }

echo "== $SRC"
suite "$SRC"; rc=$?
if [ "$rc" -ne 0 ]; then echo "FAILED (rc=$rc)"; [ "$rc" -eq 1 ] && exit 1 || exit 2; fi
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by behaviour; one that does not apply or compile is a failure)"
mut() { # mut <label> <perl-expr> [<lines-that-must-change>]
  local d m rc changed; d=$(mktemp -d -p "$W"); m="$d/AppInstallReceiver.java"
  if ! perl -0pe "$2" "$SRC" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$SRC" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  changed=$(diff "$SRC" "$m" | grep -c '^>' || true)
  if [ "$changed" -ne "${3:-1}" ]; then
    echo "  ERROR     $1 -- the mutation changed $changed line(s), expected ${3:-1}"; rm -rf "$d"; return 1; fi
  suite "$m" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not extract or compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "M1 the off-default and Off-record branches swapped" 's/(        \} else if \(ProfileActivity\.APPDEF_OFF\.equals\(mode\)\) \{\n.*?\n)(        \} else if \(ProfileActivity\.explicitlyTurnedOff\(ctx\)\.contains\(pkg\)\) \{\n            outcome = "not kept \(the user switched this app off\)";\n)/$2$1/s' 2 || fails=$((fails+1))
mut "M2 returning && dropped from the off-default clear" 's/(\n {12})if \(returning && (StoreInstaller\.keepSetHas\(ctx, pkg\)\) \{\n {16}StoreInstaller\.removeKeepLines)/$1if ($2/' || fails=$((fails+1))
mut "M3 the nApps branch removed" 's/\} else if \(ProfileActivity\.CFG_APPS_NAPPS\.equals\(key\)\) \{/} else if (false) {/' || fails=$((fails+1))
mut "M4 removeKeepLines dropped from the returning reset" 's/ {12}StoreInstaller\.removeKeepLines\(ctx, java\.util\.Collections\.singleton\(pkg\)\);(\n {12}wrote = StoreInstaller\.keepInMode)/            ;$1/' || fails=$((fails+1))
mut "M5 the catch-up log condition inverted" 's/if \(!"catch-up"\.equals\(via\) \|\| wrote\) \{/if ("catch-up".equals(via) || wrote) {/' || fails=$((fails+1))
mut "M6 the replacing branch removed" 's/        if \(replacing\) \{\n            outcome = "skipped \(an update/        if (false) {\n            outcome = "skipped (an update/' || fails=$((fails+1))
# NWP-20261122-06: Play on keeps a Play stack member On-demand, and Play Store alone as the user's keep.
mut "M7 decide ignores the Play choice" 's/mode = PlayChoice\.keepModeOnInstall\(play, pkg, mode\);/;/' || fails=$((fails+1))
mut "M8 the user keep of Play Store not recorded" 's/ProfileActivity\.setPlayDep\(ctx, pkg, true\);/;/' || fails=$((fails+1))
mut "M9 decide acts on the flag without the GrapheneOS App Store" 's/ProfileActivity\.gosStorePresent\(ctx\)\);/true);/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
