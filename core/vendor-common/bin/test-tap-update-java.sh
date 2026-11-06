#!/usr/bin/env bash
# test-tap-update-java.sh [--mutate] -- Q050's tap update, run under javac (NWP-20261112-06).
#
# WHY THIS IS COMMITTED. Q050 (decided 2026-10-20, docs/product-decisions.md): at the TAP on an On-demand app, when
# the catalog pins a newer version from the same signer, the materialise installs that instead of the sealed #apps
# copy, and falls back to the sealed copy when the catalog cannot be reached or the fetch or install fails. Before it,
# a curated app that got a security fix in the catalog opened at the version sealed months ago on every tap.
# TapUpdate (parse the CATALOG-PIN reply, decide newer + same signer, hash a cert, map FETCH-APP + install verdict to
# INSTALLED / SEALED / STOP) is a pure class with no android.* import, compiled here with its cases. A source check
# on UnarchiveService.java pins the wiring the cases cannot see: only a tap (behind `quiet ?`) calls tapUpdateLocked,
# never materializeMember or sweepAuto; the archived label is read before it; the sealed fallback clears the staging
# dir first; materializeLocked keeps exactly one RESTORE-ODDATA; IN_FLIGHT is released in a finally; and an OK install
# records the app's Play dependency (recordPlayDepAtInstall), as installApks does.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-tap-update-java.sh            # the cases + the source check
#   bash test-tap-update-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SUT="$SRC/TapUpdate.java"
UNA="$SRC/UnarchiveService.java"
INSTALLER="$SRC/StoreInstaller.java"
CASES="$root/core/chooser/tests/tap-update/TapUpdateCases.java"
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
[ -f "$UNA" ] && [ -f "$INSTALLER" ] || { echo "FAIL: missing UnarchiveService.java or StoreInstaller.java" >&2; exit 2; }

# suite <TapUpdate.java> -> 0 pass, 1 a case failed or the class is missing (the only codes that convict a mutant),
# 3 the class or the cases did not compile.
suite() {
  local src="$1" d out rc
  [ -f "$src" ] || { echo "  FAIL  TapUpdate.java does not exist (the tap update is not built)" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$src" "$d/src/com/nowhere/chooser/TapUpdate.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/TapUpdateCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.TapUpdateCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# meth <file> <name> -> the method's lines, from its 4-space declaration to its 4-space closing brace.
meth() {
  awk -v n="$2" '$0 ~ ("^    [a-zA-Z].* " n "\\(") && !f { f = 1 } f { print } f && /^    }$/ { exit }' "$1"
}

# sources <UnarchiveService.java> <StoreInstaller.java> -> 0 when every wiring rule holds, 1 (with the reason) when not.
sources() {
  local una="$1" ins="$2" ml tl mm sw r n
  ml=$(meth "$una" materializeLocked)
  tl=$(meth "$una" tapUpdateLocked)
  mm=$(meth "$una" materializeMember)
  sw=$(meth "$una" sweepAuto)
  [ -n "$ml" ] && [ -n "$mm" ] && [ -n "$sw" ] || { echo "  FAIL  materializeLocked, materializeMember or sweepAuto not found" >&2; return 1; }
  [ -n "$tl" ] || { echo "  FAIL  tapUpdateLocked not found in UnarchiveService.java (the tap update is not wired)" >&2; return 1; }
  # S1: the one call of tapUpdateLocked in the whole file is the tap's, behind `quiet ?`, inside materializeLocked.
  r=$(awk '
    /tapUpdateLocked\(/ && !/private Boolean tapUpdateLocked\(/ && !/^ *(\/\/|\*|\/\*)/ {
      calls++; if (index($0, "Boolean tu = quiet ? null : tapUpdateLocked(pkg);")) guarded++
    }
    END { if (calls == 1 && guarded == 1) print "ok"; else print "bad: calls=" calls+0 " behind-quiet=" guarded+0 }
  ' "$una")
  [ "$r" = ok ] || { echo "  FAIL  S1 tapUpdateLocked: $r (want exactly one call, \`Boolean tu = quiet ? null : tapUpdateLocked(pkg);\`)" >&2; return 1; }
  r=$(printf '%s\n' "$ml" | awk 'index($0, "quiet ? null : tapUpdateLocked(pkg)") { c++ } END { print c+0 }')
  [ "$r" = 1 ] || { echo "  FAIL  S1 the guarded call is not inside materializeLocked" >&2; return 1; }
  # S2: neither the group deps nor the Auto sweep reach it.
  r=$(printf '%s\n%s\n' "$mm" "$sw" | awk '/tapUpdateLocked/ { c++ } END { print c+0 }')
  [ "$r" = 0 ] || { echo "  FAIL  S2 materializeMember or sweepAuto names tapUpdateLocked ($r line(s))" >&2; return 1; }
  # S3: the label is read while the package is still archived, before the tap update can install it.
  r=$(printf '%s\n' "$ml" | awk '
    index($0, "archivedLabel(pkg)") && !l { l = NR }
    index($0, "tapUpdateLocked(pkg)") && !t { t = NR }
    END { if (l && t && l < t) print "ok"; else print "bad: archivedLabel=" l+0 " tapUpdateLocked=" t+0 }')
  [ "$r" = ok ] || { echo "  FAIL  S3 materializeLocked: $r (want archivedLabel(pkg) before the tapUpdateLocked call)" >&2; return 1; }
  # S4: one RESTORE-ODDATA in materializeLocked, the post-install one both copies share.
  r=$(printf '%s\n' "$ml" | awk 'index($0, "daemon(\"RESTORE-ODDATA\\n\" + pkg") { c++ } END { print c+0 }')
  [ "$r" = 1 ] || { echo "  FAIL  S4 materializeLocked holds $r daemon(\"RESTORE-ODDATA\\n\" + pkg calls, want exactly 1" >&2; return 1; }
  # S6: the sealed fallback clears the staging dir after the tap update and before the sealed fetch.
  r=$(printf '%s\n' "$ml" | awk '
    index($0, "tapUpdateLocked(pkg)") && !t { t = NR }
    t && !d && /^ *rmTree\(dir\);/ && !rm { rm = NR }
    index($0, "daemonMaterialize(pkg)") && !d { d = NR }
    END { if (t && rm && d && t < rm && rm < d) print "ok"; else print "bad: tapUpdateLocked=" t+0 " rmTree=" rm+0 " daemonMaterialize=" d+0 }')
  [ "$r" = ok ] || { echo "  FAIL  S6 materializeLocked: $r (want tapUpdateLocked < rmTree(dir); < daemonMaterialize(pkg))" >&2; return 1; }
  # S5: IN_FLIGHT is taken, and released in the finally of tapUpdateLocked.
  r=$(printf '%s\n' "$tl" | awk '
    index($0, "StoreInstaller.IN_FLIGHT.add(pkg)") { add++ }
    /^        } finally \{$/ { fin = 1; next }
    fin && /^        }$/ { fin = 0 }
    fin { s = $0; gsub(/^ +| +$/, "", s); if (s == "StoreInstaller.IN_FLIGHT.remove(pkg);") rel++ }
    END { if (add >= 1 && rel == 1) print "ok"; else print "bad: add=" add+0 " release-in-finally=" rel+0 }')
  [ "$r" = ok ] || { echo "  FAIL  S5 tapUpdateLocked: $r (want IN_FLIGHT.add(pkg) and StoreInstaller.IN_FLIGHT.remove(pkg); in its finally)" >&2; return 1; }
  # S8: an OK install records the app's Play dependency, between installStaged and the outcome's mapping.
  r=$(printf '%s\n' "$tl" | awk '
    { s = $0; gsub(/^ +| +$/, "", s) }
    index(s, "StoreInstaller.installStaged(") && !is { is = NR }
    index(s, "TapUpdate.afterFetch(") && !af { af = NR }
    s == "try { ProfileActivity.recordPlayDepAtInstall(this, pkg); } catch (Throwable ignore) {}" { rec++; rl = NR; guard = prev }
    s != "" && s !~ /^\/\// { prev = s }
    END {
      if (rec != 1) { print "missing: recordPlayDepAtInstall in tapUpdateLocked " rec+0 " time(s), want 1"; exit }
      if (guard != "if (StoreInstaller.OK.equals(verdict)) {") { print "unguarded: the line before it is \"" guard "\", want the OK verdict guard"; exit }
      if (!(is && af && is < rl && rl < af)) { print "misplaced: installStaged=" is+0 " record=" rl+0 " afterFetch=" af+0; exit }
      print "ok"
    }')
  [ "$r" = ok ] || { echo "  FAIL  S8 recordPlayDepAtInstall $r" >&2; return 1; }
  # S7: TapUpdate compares installStaged's verdicts as literals; they must stay these values.
  n=$(awk '/static final String OK = "OK";/ { a++ } /static final String PENDING = "PENDING";/ { b++ } END { print a+0 " " b+0 }' "$ins")
  [ "$n" = "1 1" ] || { echo "  FAIL  S7 StoreInstaller no longer declares OK = \"OK\" and PENDING = \"PENDING\" ($n)" >&2; return 1; }
  return 0
}

echo "== $SUT"
ok=yes
suite "$SUT" || ok=no
sources "$UNA" "$INSTALLER" || ok=no
[ "$ok" = yes ] || { echo "FAILED"; exit 1; }
echo "ok: cases + source check"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not compile or does not apply proves nothing)"
mut() { # mut <label> <file: tap|una> <perl-expr>
  local d c rc orig out why
  d=$(mktemp -d -p "$W") || return 1
  case "$2" in
    tap) orig="$SUT"; c="$d/TapUpdate.java" ;;
    *) orig="$UNA"; c="$d/UnarchiveService.java" ;;
  esac
  cp "$orig" "$c"
  if ! perl -0pi -e "$3" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  if [ "$2" = tap ]; then out=$(suite "$c" 2>&1); rc=$?
  else out=$(sources "$c" "$INSTALLER" 2>&1); rc=$?
  fi
  rm -rf "$d"
  why=$(printf '%s\n' "$out" | awk '/FAIL/ { sub(/^ +/, ""); print; exit }')
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1 -- $why"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "N1 > becomes >="                          tap 's/if \(!\(pin\.vc > sealedVc\)\) return false;/if (!(pin.vc >= sealedVc)) return false;/' || fails=$((fails+1))
mut "N2 the cert check dropped"                tap 's/for \(String c : sealedCerts\) if \(c != null && c\.equalsIgnoreCase\(pin\.cert\)\) return true;\n        return false;/return true;/' || fails=$((fails+1))
mut "N3 ERR-CANCELLED maps to SEALED"          tap 's/startsWith\("ERR-CANCELLED"\)\) return STOP;/startsWith("ERR-CANCELLED")) return SEALED;/' || fails=$((fails+1))
mut "N4 PENDING maps to SEALED"                tap 's/if \("PENDING"\.equals\(installVerdict\)\) return STOP;/if ("PENDING".equals(installVerdict)) return SEALED;/' || fails=$((fails+1))
mut "N5 the quiet guard removed"               una 's/Boolean tu = quiet \? null : tapUpdateLocked\(pkg\);/Boolean tu = tapUpdateLocked(pkg);/' || fails=$((fails+1))
mut "N6 the IN_FLIGHT release removed"         una 's/\n *StoreInstaller\.IN_FLIGHT\.remove\(pkg\);\n/\n/' || fails=$((fails+1))
mut "N7 the Play-dependency record deleted"    una 's/(private Boolean tapUpdateLocked\(.*?)\n *try \{ ProfileActivity\.recordPlayDepAtInstall\(this, pkg\); \} catch \(Throwable ignore\) \{\}\n/$1\n/s' || fails=$((fails+1))
mut "N8 the OK-verdict guard dropped"          una 's/if \(StoreInstaller\.OK\.equals\(verdict\)\) \{/if (verdict != null) {/' || fails=$((fails+1))
mut "N9 the label read after the tap update"   una 's/( *final CharSequence label = archivedLabel\(pkg\);[^\n]*\n)(.*?)( *Boolean tu = quiet \? null : tapUpdateLocked\(pkg\);\n)/$2$3$1/s' || fails=$((fails+1))
mut "N10 the fallback rmTree deleted"          una 's/\n *rmTree\(dir\); \/\/ a failed FETCH-APP[^\n]*\n/\n/' || fails=$((fails+1))
mut "N11 the tap update called from a dep"     una 's/(private boolean materializeMember\(String pkg\) \{\n)/$1        tapUpdateLocked(pkg);\n/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
