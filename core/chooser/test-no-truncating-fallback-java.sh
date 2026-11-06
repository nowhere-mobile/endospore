#!/usr/bin/env bash
# test-no-truncating-fallback-java.sh [<StoreInstaller.java> <GosState.java> <AppClaim.java>] [--mutate] -- GosState's
# carry-file writer and AppClaim's receipt writer, run under javac (NWP-20261022-06).
#
# WHY THIS IS COMMITTED. Both wrote temp + rename and, when the rename failed, rewrote the target with a FileWriter,
# which truncates first: a write that then failed (ENOSPC at the flush) left the GosPackageState carry file without its
# sealed per-app hardening rows, or an AppClaim receipt too cut for AppClaim to release what it holds. NWP-20261021-06
# took that fallback out of StoreInstaller.writeAtomic; both now publish through it. core/chooser/tests/no-truncating-
# fallback/run.sh lifts writeAtomic (over a seam of its own that can refuse the open or the rename), GosState.write and
# AppClaim.writeReceipt by signature, and runs FallbackCases: a refused rename or open leaves a target that held "old"
# byte for byte, no .tmp and a logged failure; and the two bodies are pinned (comments stripped) to one
# StoreInstaller.writeAtomic call and no renameTo or new FileWriter.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (exit 2), like the other javac suites.
#
#   bash test-no-truncating-fallback-java.sh            # the cases
#   bash test-no-truncating-fallback-java.sh --mutate   # ... plus broken copies that must each FAIL the cases
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
S="$HERE/src/com/nowhere/chooser"
STORE="$S/StoreInstaller.java"; GOS="$S/GosState.java"; AC="$S/AppClaim.java"
MUTATE=no
files=()
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) files+=("$a") ;; esac; done
if [ "${#files[@]}" -eq 3 ]; then STORE="${files[0]}"; GOS="${files[1]}"; AC="${files[2]}"
elif [ "${#files[@]}" -ne 0 ]; then echo "FAIL: pass all three of StoreInstaller, GosState, AppClaim or none" >&2; exit 2; fi
RUN="$HERE/tests/no-truncating-fallback/run.sh"
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
export JAVAC JAVA
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
for f in "$STORE" "$GOS" "$AC" "$RUN"; do [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 2; }; done

# The one temp root: run.sh and every mutant live inside it, and the EXIT trap removes it on every path.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export W

# suite <StoreInstaller> <GosState> <AppClaim> -> run.sh's code: 0 pass, 1 a case or pin failed (only this may convict a
# mutant), 2 a member did not extract, 3 the lifted classes did not compile.
suite() { bash "$RUN" "$1" "$2" "$3"; }

echo "== $GOS + $AC"
suite "$STORE" "$GOS" "$AC"; rc=$?
if [ "$rc" -ne 0 ]; then echo "FAILED (rc=$rc)"; [ "$rc" -eq 1 ] && exit 1 || exit 2; fi
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by behaviour; one that does not apply or compile is a failure)"

# main's two bodies before this slice, restored by the mutants
OLD_GOS='        try {
            File tmp = new File(f.getParentFile(), f.getName() + ".tmp");
            try (java.io.FileWriter fw = new java.io.FileWriter(tmp)) { fw.write(content); }
            if (!tmp.renameTo(f)) {
                try (java.io.FileWriter fw = new java.io.FileWriter(f)) { fw.write(content); }
                tmp.delete();
            }
        } catch (Throwable t) {
            Log.w("NowhereChooser", "gos write " + f.getName(), t);
        }
'
OLD_WR='        File f = receiptFile(ctx);
        File tmp = new File(f.getParentFile(), RECEIPT + ".tmp");
        try (java.io.FileWriter w = new java.io.FileWriter(tmp)) {
            w.write(sb.toString());
        } catch (Throwable t) {
            Log.w(TAG, "appclaim receipt (" + why + ")", t);
            return;
        }
        if (!tmp.renameTo(f)) {
            try (java.io.FileWriter w = new java.io.FileWriter(f)) {
                w.write(sb.toString());
            } catch (Throwable t) {
                Log.w(TAG, "appclaim receipt rename+rewrite (" + why + ")", t);
            }
            tmp.delete();
        }
'
RE_GOS='        try \{ StoreInstaller\.writeAtomic\(f, content\); \}\n        catch \(Throwable t\) \{ Log\.w\("NowhereChooser", "gos write " \+ f\.getName\(\), t\); \}\n'
RE_WR='        // temp \+ rename[^\n]*\n        try \{ StoreInstaller\.writeAtomic\(receiptFile\(ctx\), sb\.toString\(\)\); \}\n        catch \(Throwable t\) \{ Log\.w\(TAG, "appclaim receipt \(" \+ why \+ "\)", t\); \}\n'
NEW_GOS_FB='        try { StoreInstaller.writeAtomic(f, content); }
        catch (Throwable t) {
            Log.w("NowhereChooser", "gos write " + f.getName(), t);
            try (java.io.FileWriter fw = new java.io.FileWriter(f)) { fw.write(content); } catch (Throwable ignore) {}
        }
'

# mut <label> <which: gos|wr> <regex of the body> <replacement body>
mut() {
  local d m rc which="$2"
  d=$(mktemp -d -p "$W")
  case "$which" in
    gos) m="$d/GosState.java"; BODY="$4" perl -0pe "s#$3#\$ENV{BODY}#" "$GOS" > "$m" ;;
    wr)  m="$d/AppClaim.java"; BODY="$4" perl -0pe "s#$3#\$ENV{BODY}#" "$AC" > "$m" ;;
  esac
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if { [ "$which" = gos ] && cmp -s "$GOS" "$m"; } || { [ "$which" = wr ] && cmp -s "$AC" "$m"; }; then
    echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  if [ "$which" = gos ]; then suite "$STORE" "$m" "$AC" >/dev/null 2>&1; rc=$?
  else suite "$STORE" "$GOS" "$m" >/dev/null 2>&1; rc=$?; fi
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not extract or compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "N1 GosState.write: the old temp / renameTo / FileWriter fallback body restored" gos "$RE_GOS" "$OLD_GOS" || fails=$((fails+1))
mut "N2 AppClaim.writeReceipt: the old temp / renameTo / FileWriter fallback body restored" wr "$RE_WR" "$OLD_WR" || fails=$((fails+1))
mut "N3 GosState.write: writeAtomic, then a FileWriter over f in its catch" gos "$RE_GOS" "$NEW_GOS_FB" || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
