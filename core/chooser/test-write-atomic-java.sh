#!/usr/bin/env bash
# test-write-atomic-java.sh [<StoreInstaller.java>] [--mutate] -- StoreInstaller.writeAtomic, run under javac
# (NWP-20261021-06).
#
# WHY THIS IS COMMITTED. writeAtomic is the chooser's file-replace path for the records that roam: the keep-set (from
# StoreInstaller and the Profile screen), the Off record, the play deps and play determinations, the held list, a
# profile's nowhere-prefs (setPref) and nowhere-perms. It exists so a failed write never
# costs the file it replaces. Before this slice a failed rename fell back to a direct FileWriter over the target, which
# truncates first (the loss the temp file prevents), and a failed write left the .tmp behind. Nothing ran that off-device,
# and a write that fails at its close (ENOSPC at the flush) cannot be staged on a phone. core/chooser/tests/write-atomic/
# run.sh lifts the AtomicIo seam, FILE_IO and both writeAtomic overloads by signature and runs WriteAtomicCases against
# them: a failed open, write, close or rename leaves the target byte for byte, opens only <name>.tmp, and leaves no .tmp.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (exit 2), like the other javac suites.
#
#   bash test-write-atomic-java.sh            # the cases
#   bash test-write-atomic-java.sh --mutate   # ... plus broken copies that must each FAIL the cases
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/src/com/nowhere/chooser/StoreInstaller.java"
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SRC="$a" ;; esac; done
RUN="$HERE/tests/write-atomic/run.sh"
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
[ -f "$SRC" ] && [ -f "$RUN" ] || { echo "FAIL: missing $SRC or $RUN" >&2; exit 2; }

# The one temp root: run.sh and every mutant live inside it, and the EXIT trap removes it on every path.
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
export W

# suite <StoreInstaller.java> -> run.sh's code: 0 pass, 1 a case failed (only this may convict a mutant), 2 a member
# did not extract, 3 the lifted class did not compile.
suite() { bash "$RUN" "$1"; }

echo "== $SRC"
suite "$SRC"; rc=$?
if [ "$rc" -ne 0 ]; then echo "FAILED (rc=$rc)"; [ "$rc" -eq 1 ] && exit 1 || exit 2; fi
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by behaviour; one that does not apply or compile is a failure)"
mut() { # mut <label> <perl-expr> [<lines-that-must-change>]
  local d m rc changed; d=$(mktemp -d -p "$W"); m="$d/StoreInstaller.java"
  if ! perl -0pe "$2" "$SRC" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$SRC" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  changed=$(diff "$SRC" "$m" | grep -c '^>')
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
mut "W1 a failed rename falls back to a direct FileWriter over the target" 's/throw new java\.io\.IOException\("rename " \+ tmp \+ " -> " \+ f \+ " failed"\);/{ try (java.io.Writer w2 = new java.io.FileWriter(f)) { w2.write(content); } tmp.delete(); return; }/' || fails=$((fails+1))
mut "W2 a failed rename falls back to io.open(target)" 's/throw new java\.io\.IOException\("rename " \+ tmp \+ " -> " \+ f \+ " failed"\);/{ try (java.io.Writer w2 = io.open(f)) { w2.write(content); } tmp.delete(); return; }/' || fails=$((fails+1))
mut "W3 the .tmp is not deleted on a failure"   's/(catch \(java\.io\.IOException \| RuntimeException e\) \{\n[^\n]*\n)            tmp\.delete\(\);/${1}            ;/' || fails=$((fails+1))
mut "W4 the target is opened instead of the .tmp" 's/io\.open\(tmp\)/io.open(f)/' || fails=$((fails+1))
mut "W5 the rename happens before the close"    's/(try \(java\.io\.Writer w = io\.open\(tmp\)\) \{ w\.write\(content\); )\}\n(            \/\/[^\n]*\n            \/\/[^\n]*\n)(            if \(!io\.rename\(tmp, f\)\)[^\n]*\n)/${1}${3}}\n${2}/' 2 || fails=$((fails+1))
mut "W6 FILE_IO.rename answers true without renaming" 's/return from\.renameTo\(to\);/return true;/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
