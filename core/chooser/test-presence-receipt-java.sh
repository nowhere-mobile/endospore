#!/usr/bin/env bash
# test-presence-receipt-java.sh [--mutate] -- the session-presence receipts (files/nowhere-appseen and
# files/nowhere-appgone) keep their stamp discipline, and an unreadable user serial neither stamps nor matches
# (NWP-20261120-18).
#
# WHY THIS IS COMMITTED. The two receipts authorise ProfileActivity.captureAppCode's logoff keep-set prune: a package
# seen or gone this session and unknown to PackageManager at logoff loses its keep line and is recorded as turned off,
# so these members decide which apps stop roaming. The rule of the class comment is that a receipt whose stamp does
# not match the live session reads as EMPTY, so every failure mode SUBTRACTS from the eligible set. seenStamp used to
# return "#stamp -1" when getSerialNumberForUser threw. That value names no session: two sessions whose lookup failed,
# or a receipt written that way and restored from a seal, matched each other and unioned, the one failure that ADDED.
# No suite executed these members before this one.
#
# WHAT RUNS. core/chooser/tests/presence-receipt/run.sh lifts stampFor, snapshotAppSeen, noteAppGone,
# appGoneThisSession, appSeenThisSession, stampMatches, readSeenLines, the two file names, APPKEEP_LOCK and writeAtomic
# with its seam from StoreInstaller.java, by signature, stubs seenStamp as stampFor(<the case's serial>), and runs
# Cases (R1-R9). seenStamp needs a UserManager and cannot be lifted, so it is PINNED in code only (comments dropped,
# string literals emptied): it returns stampFor(serial) and holds no "#stamp" text. snapshotAppSeen's first two lines
# are pinned byte for byte, because test-appmode-lock.sh's mutants anchor on them.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (exit 2), like the other javac suites.
#
#   bash test-presence-receipt-java.sh            # the cases and the pins
#   bash test-presence-receipt-java.sh --mutate   # ... plus broken copies that must each FAIL them
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SI0="$HERE/src/com/nowhere/chooser/StoreInstaller.java"
SI="${SI:-$SI0}"
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
RUN="$HERE/tests/presence-receipt/run.sh"
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
[ -f "$SI" ] && [ -f "$RUN" ] || { echo "FAIL: missing $SI or $RUN" >&2; exit 2; }

# The one temp root: run.sh and every mutant live inside it, and the EXIT trap removes it on every path.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export W

# ⚠ Every match reads its input to the end (a here-string or a count, never `cmd | grep -q`): under pipefail grep -q
# can SIGPIPE its producer and flip an absence check.
# codeonly: each line reduced to CODE -- comments dropped, string, char and text-block literals emptied. Same scanner
# as test-appgone-record-java.sh, with no literal kept.
codeonly(){ awk -v SQ="'" '
  BEGIN { inblock=0; intext=0 }
  {
    code=""; n=length($0); i=1
    while (i<=n) {
      c=substr($0, i, 1); two=substr($0, i, 2)
      if (inblock) { if (two=="*/") { inblock=0; i+=2 } else i++; continue }
      if (intext) { if (substr($0, i, 3)=="\"\"\"") { intext=0; i+=3 } else i++; continue }
      if (two=="//") break
      if (two=="/*") { inblock=1; i+=2; continue }
      if (substr($0, i, 3)=="\"\"\"") { intext=1; i+=3; code=code "\"\""; continue }
      if (c=="\"" || c==SQ) {
        q=c; i++
        while (i<=n) { d=substr($0, i, 1); if (d=="\\") { i+=2; continue }; if (d==q) break; i++ }
        i++; code=code q q; continue
      }
      code=code c; i++
    }
    print code
  }'; }
# method <file> <signature-regex>: the method, code only, from its signature line to the brace that closes it.
# Fails (rc 3) when the anchor is missing or its braces do not balance. Reads to EOF.
method(){ codeonly < "$1" | RE="$2" awk '
  !on && $0 ~ ENVIRON["RE"] { on=1 }
  on && !done { print; n=length($0); for (i=1;i<=n && !done;i++) { c=substr($0,i,1); if (c=="{") d++; else if (c=="}") { d--; if (d==0) done=1 } } }
  END { if (!done) exit 3 }'; }
# rawmethod <file> <signature-regex>: the same lines, comments and literals intact (codeonly keeps one line per line).
rawmethod(){
  local a b
  a=$(codeonly < "$1" | RE="$2" awk '$0 ~ ENVIRON["RE"] { print NR; exit }')
  [ -n "$a" ] || return 3
  b=$(method "$1" "$2" | wc -l) || return 3
  sed -n "${a},$((a + b - 1))p" "$1"
}

# pins <StoreInstaller.java>: 0 all hold, 1 a pin failed, 2 an anchor moved.
pins() {
  local si="$1" bad=0 body raw last n a nx
  # (P1) seenStamp returns stampFor(serial) and holds no "#stamp" text of its own
  body=$(method "$si" 'private static String seenStamp\(Context ctx\) \{') && [ -n "$body" ] || { echo "EXTRACTION FAILED -- seenStamp" >&2; return 2; }
  raw=$(rawmethod "$si" 'private static String seenStamp\(Context ctx\) \{') || { echo "EXTRACTION FAILED -- seenStamp (raw)" >&2; return 2; }
  last=$(sed '$d' <<<"$body" | awk 'NF { gsub(/[[:space:]]+/, " "); sub(/^ /, ""); sub(/ $/, ""); l=$0 } END { print l }')
  n=$(grep -cF '#stamp' <<<"$raw" || true)
  if [ "$last" = 'return stampFor(serial);' ] && [ "$n" = 0 ]; then
    echo "  ok    seenStamp returns stampFor(serial) and spells no stamp itself"
  else
    echo "  FAIL  seenStamp's last statement is not return stampFor(serial); or it spells \"#stamp\" (last: ${last:-nothing}; #stamp lines: $n)"; bad=1
  fi
  # (P2) snapshotAppSeen's first two lines, which test-appmode-lock.sh's mutants anchor on
  n=$(grep -cxF '    static void snapshotAppSeen(Context ctx, java.util.Set<String> presentPkgs) {' "$si" || true)
  a=$(grep -nxF '    static void snapshotAppSeen(Context ctx, java.util.Set<String> presentPkgs) {' "$si" | cut -d: -f1 | head -1)
  nx=""; [ -n "$a" ] && nx=$(sed -n "$((a + 1))p" "$si")
  if [ "$n" = 1 ] && [ "$nx" = '        synchronized (APPKEEP_LOCK) {' ]; then
    echo "  ok    snapshotAppSeen opens with its two pinned lines, byte for byte"
  else
    echo "  FAIL  snapshotAppSeen's two pinned opening lines changed (signature lines: $n; next: ${nx:-nothing})"; bad=1
  fi
  return "$bad"
}

# suite <StoreInstaller.java> -> 0 pass, 1 a case or pin failed (only this may convict a mutant), 2 a member did not
# extract, 3 the lifted classes did not compile. The pins run even when the cases are red.
suite() {
  local rc=0 prc=0
  bash "$RUN" "$1" || rc=$?
  [ "$rc" -le 1 ] || [ "$rc" -eq 2 ] || return "$rc"
  pins "$1" || prc=$?
  [ "$prc" -le 1 ] || return 2
  [ "$rc" -le 1 ] || return "$rc"
  [ "$rc" = 0 ] && [ "$prc" = 0 ] && return 0
  return 1
}

echo "== $SI"
suite "$SI"; rc=$?
if [ "$rc" -ne 0 ]; then echo "FAILED (rc=$rc)"; [ "$rc" -eq 1 ] && exit 1 || exit 2; fi
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by the named case; one that does not apply or compile is a failure)"
mut() { # mut <label> <perl-expr> <lines-that-must-change> <convicting case or pin, e.g. R2 or P1>
  local d m rc changed out n; d=$(mktemp -d -p "$W")
  m="$d/StoreInstaller.java"
  if ! perl -0pe "$2" "$SI" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$SI" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  changed=$(diff "$SI" "$m" | grep -c "^[<>]")
  if [ "$changed" -ne "$3" ]; then
    echo "  ERROR     $1 -- the mutation changed $changed line(s), expected $3"; rm -rf "$d"; return 1; fi
  out=$(suite "$m" 2>&1); rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) ;;
    *) echo "  BROKEN    $1 -- the mutant did not extract or compile (rc=$rc)"; return 1 ;;
  esac
  # the named case must be the one that fails: the FAIL lines that follow its "== (<id>)" header, or the pin's line
  if [ "${4#P}" != "$4" ]; then
    case "$4" in
      P1) n=$(grep -c '^  FAIL  seenStamp' <<<"$out" || true) ;;
      P2) n=$(grep -c '^  FAIL  snapshotAppSeen' <<<"$out" || true) ;;
      *) n=0 ;;
    esac
  else
    n=$(ID="$4" awk 'index($0, "== (" ENVIRON["ID"] ")") == 1 { on=1; next } /^== / { on=0 } on && /^  FAIL  / { c++ } END { print c+0 }' <<<"$out")
  fi
  if [ "$n" -gt 0 ]; then echo "  convicted $1 (by $4)"; return 0; fi
  echo "  WRONG     $1 -- the suite failed, but not on $4"; return 1
}
fails=0
mut "M1 stampMatches returns true for any existing file" \
  's/return first != null && first\.trim\(\)\.equals\(want\);/return true;/' 2 R2 || fails=$((fails+1))
mut "M2 snapshotAppSeen unions without the stamp check" \
  's/(static void snapshotAppSeen\(.*?)if \(stampMatches\(f, stamp\)\) all\.addAll\(/$1all.addAll(/s' 2 R2 || fails=$((fails+1))
mut "M3 stampFor(-1) returns \"#stamp -1\"" \
  's/return serial < 0 \? null : "#stamp " \+ serial;/return "#stamp " + serial;/' 2 R9 || fails=$((fails+1))
mut "M4 readSeenLines keeps '#' lines" \
  's/if \(!ln\.isEmpty\(\) && !ln\.startsWith\("#"\)\) out\.add\(ln\);/if (!ln.isEmpty()) out.add(ln);/' 2 R8 || fails=$((fails+1))
mut "M5 noteAppGone unions a foreign file" \
  's/(static void noteAppGone\(.*?)if \(stampMatches\(f, stamp\)\) all\.addAll\(/$1all.addAll(/s' 2 R7 || fails=$((fails+1))
mut "M6 appSeenThisSession reads without the stamp check" \
  's/(static java\.util\.Set<String> appSeenThisSession\(.*?)\n[ ]*if \(!stampMatches\(f, stamp\)\) return java\.util\.Collections\.emptySet\(\);/$1/s' 1 R2 || fails=$((fails+1))
mut "M7 seenStamp returns \"#stamp \" + serial again" \
  's/        return stampFor\(serial\);/        return "#stamp " + serial;/' 2 P1 || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
