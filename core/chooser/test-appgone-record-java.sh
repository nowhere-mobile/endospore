#!/usr/bin/env bash
# test-appgone-record-java.sh [--mutate] -- an UNINSTALL is recorded in files/nowhere-appgone.list as well as the Off
# record, an Off never is, and a re-keep retires both lines (NWP-20261023-10).
#
# WHY THIS IS COMMITTED. nowhere-appoff.list holds Offs and uninstalls alike (DECIDED 2026-09-26), so the account
# tombstone the 2026-09-06 decision needs cannot go live without tombstoning every Off: with the flag on, one Off on
# one handset would delete the app from every signed-in handset. The chooser half of the split is a second file, the
# uninstall record, written only by the two uninstall writers (the logoff prune's `uninstalled` set -- never its `drop`
# set, which also holds bundled-system apps -- and the phantom-line reconcile), retired with the Off line by
# clearTurnedOff. Its consumer is roamd's appcode_seal; until that lands nothing reads it.
#
# WHAT RUNS. core/chooser/tests/appgone-record/run.sh lifts recordUninstalled, readUninstalled, clearUninstalled,
# APPKEEP_LOCK and writeAtomic with its seam from StoreInstaller.java, and keepSetAll from ProfileActivity.java, by
# signature, and runs AppgoneRecordCases. The call sites need an Activity and cannot be lifted, so they are PINNED in
# code only (comments dropped, string literals emptied except the file name): captureAppCode passes `uninstalled`
# after its recordTurnedOff loop, reconcilePhantomKeepLines passes `drop`, clearTurnedOff starts with
# clearUninstalled, no Off writer calls recordUninstalled, and only StoreInstaller.java names the file.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (exit 2), like the other javac suites.
#
#   bash test-appgone-record-java.sh            # the cases and the pins
#   bash test-appgone-record-java.sh --mutate   # ... plus broken copies that must each FAIL them
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PA0="$HERE/src/com/nowhere/chooser/ProfileActivity.java"
SI0="$HERE/src/com/nowhere/chooser/StoreInstaller.java"
PA="${PA:-$PA0}"
SI="${SI:-$SI0}"
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
RUN="$HERE/tests/appgone-record/run.sh"
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
[ -f "$PA" ] && [ -f "$SI" ] && [ -f "$RUN" ] || { echo "FAIL: missing $PA, $SI or $RUN" >&2; exit 2; }

# The one temp root: run.sh and every mutant live inside it, and the EXIT trap removes it on every path.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export W

# ⚠ Every match reads its input to the end (a here-string or a count, never `cmd | grep -q`): under pipefail grep -q
# can SIGPIPE its producer and flip an absence check.
# codeonly: each line reduced to CODE -- comments dropped, string, char and text-block literals emptied. Same scanner
# as test-playdep-lock.sh.
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
        q=c; i++; start_i=i
        while (i<=n) { d=substr($0, i, 1); if (d=="\\") { i+=2; continue }; if (d==q) break; i++ }
        lit=substr($0, start_i, i-start_i)
        i++; if (q=="\"" && lit=="nowhere-appgone.list") code=code q lit q; else code=code q q; continue
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

# bodyline <body> <regex>: the first line number of the body matching the regex, or empty
firstline(){ RE="$2" awk '$0 ~ ENVIRON["RE"] { print NR; exit }' <<<"$1"; }

# pins <ProfileActivity.java> <StoreInstaller.java>: 0 all hold, 1 a pin failed, 2 an anchor moved.
pins() {
  local pa="$1" si="$2" bad=0 body a b n f hits
  # (d1) captureAppCode: recordUninstalled(this, uninstalled), once, after the recordTurnedOff loop, never drop
  body=$(method "$pa" 'private void captureAppCode\(\) \{') && [ -n "$body" ] || { echo "EXTRACTION FAILED -- captureAppCode" >&2; return 2; }
  a=$(firstline "$body" 'for \(String pkg : uninstalled\) recordTurnedOff\(pkg\);')
  b=$(firstline "$body" 'StoreInstaller\.recordUninstalled\(this, uninstalled\)')
  n=$(grep -cE 'StoreInstaller\.recordUninstalled\(' <<<"$body")
  if [ -n "$a" ] && [ -n "$b" ] && [ "$b" -gt "$a" ] && [ "$n" = 1 ]; then
    echo "  ok    captureAppCode records its uninstalled set, once, after the Off loop"
  else
    echo "  FAIL  captureAppCode does not call StoreInstaller.recordUninstalled(this, uninstalled) once after its recordTurnedOff loop"; bad=1
  fi
  # (d2) reconcilePhantomKeepLines: recordUninstalled(ctx, drop), once, after its recordTurnedOff loop
  body=$(method "$pa" 'static void reconcilePhantomKeepLines\(android\.content\.Context ctx\) \{') && [ -n "$body" ] || { echo "EXTRACTION FAILED -- reconcilePhantomKeepLines" >&2; return 2; }
  a=$(firstline "$body" 'for \(String pkg : drop\) StoreInstaller\.recordTurnedOff\(ctx, pkg\);')
  b=$(firstline "$body" 'StoreInstaller\.recordUninstalled\(ctx, drop\)')
  n=$(grep -cE 'StoreInstaller\.recordUninstalled\(' <<<"$body")
  if [ -n "$a" ] && [ -n "$b" ] && [ "$b" -gt "$a" ] && [ "$n" = 1 ]; then
    echo "  ok    reconcilePhantomKeepLines records its drop set, once, after the Off loop"
  else
    echo "  FAIL  reconcilePhantomKeepLines does not call StoreInstaller.recordUninstalled(ctx, drop) once after its recordTurnedOff loop"; bad=1
  fi
  # (d3) clearTurnedOff's first statement retires the uninstall line
  body=$(method "$si" 'static void clearTurnedOff\(Context ctx, java\.util\.Collection<String> pkgs\) \{') && [ -n "$body" ] || { echo "EXTRACTION FAILED -- clearTurnedOff" >&2; return 2; }
  f=$(sed 1d <<<"$body" | awk 'NF { gsub(/[[:space:]]+/, " "); sub(/^ /, ""); sub(/ $/, ""); print; exit }')
  if [ "$f" = 'clearUninstalled(ctx, pkgs);' ]; then
    echo "  ok    clearTurnedOff's first statement is clearUninstalled(ctx, pkgs);"
  else
    echo "  FAIL  clearTurnedOff's first statement is not clearUninstalled(ctx, pkgs); (it is: ${f:-nothing})"; bad=1
  fi
  # (d4) no Off writer records an uninstall
  for spec in 'setAppModeLocked|private java\.util\.Set<String> setAppModeLocked\(' \
              'confirmDropAndSignOut|private void confirmDropAndSignOut\(' \
              'applyStorageDrop|private void applyStorageDrop\('; do
    n=${spec%%|*}
    body=$(method "$pa" "${spec#*|}") && [ -n "$body" ] || { echo "EXTRACTION FAILED -- $n" >&2; return 2; }
    if grep -qE '(^|[^[:alnum:]_$])recordUninstalled([^[:alnum:]_$]|$)' <<<"$body"; then
      echo "  FAIL  $n calls recordUninstalled -- an Off would be tombstoned"; bad=1
    else
      echo "  ok    $n never calls recordUninstalled"
    fi
  done
  # (d5) only StoreInstaller.java names the file; recordUninstalled and clearUninstalled each name it
  hits=""
  for f in $(find "$HERE/src" -name '*.java' | LC_ALL=C sort); do
    case "$f" in "$PA0") f="$pa" ;; "$SI0") f="$si" ;; esac
    if [ "$(codeonly < "$f" | grep -cF '"nowhere-appgone.list"')" -gt 0 ]; then hits="$hits $(basename "$f")"; fi
  done
  if [ "$hits" = " StoreInstaller.java" ]; then
    echo "  ok    only StoreInstaller.java names \"nowhere-appgone.list\""
  else
    echo "  FAIL  files naming \"nowhere-appgone.list\":${hits:- none} (want exactly StoreInstaller.java)"; bad=1
  fi
  for spec in 'recordUninstalled|static void recordUninstalled\(Context ctx, ' 'clearUninstalled|static void clearUninstalled\(Context ctx, '; do
    n=${spec%%|*}
    body=$(method "$si" "${spec#*|}") && [ -n "$body" ] || { echo "EXTRACTION FAILED -- $n" >&2; return 2; }
    if grep -qF '"nowhere-appgone.list"' <<<"$body"; then
      echo "  ok    $n works on \"nowhere-appgone.list\""
    else
      echo "  FAIL  $n does not name \"nowhere-appgone.list\""; bad=1
    fi
  done
  return "$bad"
}

# suite <ProfileActivity.java> <StoreInstaller.java> -> 0 pass, 1 a case or pin failed (only this may convict a
# mutant), 2 a member did not extract, 3 the lifted classes did not compile. The pins run even when the cases are red.
suite() {
  local rc=0 prc=0
  bash "$RUN" "$1" "$2" || rc=$?
  [ "$rc" -le 1 ] || [ "$rc" -eq 2 ] || return "$rc"
  pins "$1" "$2" || prc=$?
  [ "$prc" -le 1 ] || return 2
  [ "$rc" -le 1 ] || return "$rc"
  [ "$rc" = 0 ] && [ "$prc" = 0 ] && return 0
  return 1
}

echo "== $PA"
suite "$PA" "$SI"; rc=$?
if [ "$rc" -ne 0 ]; then echo "FAILED (rc=$rc)"; [ "$rc" -eq 1 ] && exit 1 || exit 2; fi
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED; one that does not apply or compile is a failure)"
mut() { # mut <label> <PA|SI> <perl-expr> <lines-that-must-change>
  local d m rc changed orig pa si; d=$(mktemp -d -p "$W")
  pa="$PA"; si="$SI"
  if [ "$2" = PA ]; then orig="$PA"; m="$d/ProfileActivity.java"; else orig="$SI"; m="$d/StoreInstaller.java"; fi
  if ! perl -0pe "$3" "$orig" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  changed=$(diff "$orig" "$m" | grep -c "^[<>]")
  if [ "$changed" -ne "$4" ]; then
    echo "  ERROR     $1 -- the mutation changed $changed line(s), expected $4"; rm -rf "$d"; return 1; fi
  if [ "$2" = PA ]; then pa="$m"; else si="$m"; fi
  suite "$pa" "$si" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not extract or compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "C1 captureAppCode records drop (bundled-system apps too) instead of uninstalled" PA 's/recordUninstalled\(this, uninstalled\)/recordUninstalled(this, drop)/' 2 || fails=$((fails+1))
mut "C2 setAppModeLocked's Off branch records an uninstall" PA 's/(\n            recordTurnedOff\(pkg\);\n)/$1            StoreInstaller.recordUninstalled(this, java.util.Collections.singleton(pkg));\n/' 1 || fails=$((fails+1))
mut "C3 clearUninstalled drops its kept guard" SI 's/onDisk\.contains\(p\) && s\.remove\(p\)\) retired\+\+/s.remove(p)) retired++/' 2 || fails=$((fails+1))
mut "C4 recordUninstalled appends a package that is already listed" SI 's/if \(s\.add\(p\.trim\(\)\)\) added\+\+;/s.add(p.trim()); added++;/' 2 || fails=$((fails+1))
mut "C5 clearTurnedOff no longer retires the uninstall line" SI 's/        clearUninstalled\(ctx, pkgs\);[^\n]*\n//' 1 || fails=$((fails+1))
mut "C6 recordUninstalled writes nowhere-appoff.list instead" SI 's/(static void recordUninstalled\(.*?File f = new File\(ctx\.getFilesDir\(\), )"nowhere-appgone\.list"/$1"nowhere-appoff.list"/s' 2 || fails=$((fails+1))
mut "C7 reconcilePhantomKeepLines no longer records its uninstalls" PA 's/            StoreInstaller\.recordUninstalled\(ctx, drop\);[^\n]*\n//' 1 || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
