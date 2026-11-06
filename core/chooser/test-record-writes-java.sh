#!/usr/bin/env bash
# test-record-writes-java.sh [<ProfileActivity.java>] [--mutate] -- the four roaming records the Profile screen
# rewrites (nowhere-perms, nowhere-playdeps, nowhere-playseen, nowhere-appkeep) are replaced only by temp + rename
# (NWP-20261022-04).
#
# WHY THIS IS COMMITTED. StoreInstaller.writeAtomic (NWP-20261021-06) leaves its target byte for byte when a write
# fails, but four writers in ProfileActivity still truncated their file at open: capturePerms (nowhere-perms, every
# logoff), setPlayDep and notePlaySeen (nowhere-playdeps, nowhere-playseen) and, on a failed rename, writeAppModes
# (nowhere-appkeep). Two failures follow. (1) ENOSPC at capturePerms' flush leaves nowhere-perms empty or cut and the
# logoff seals it; at the next sign-in roamd's grant_perms_for finds no INTERNET line (its #127 default: absent means no
# captured knowledge) and grants INTERNET to every third-party package, so every Network-off app gets the network back
# and every declined permission is asked again. (2) A failed setPlayDep empties nowhere-playdeps, so appDeps pulls no
# Play stack for an archived Play client and the tap materialises it without its stack.
#
# WHAT RUNS. core/chooser/tests/record-writes/run.sh lifts readPlayDeps, setPlayDep, readPlaySeen, notePlaySeen and
# PLAYDEP_LOCK from ProfileActivity.java, and the AtomicIo seam, FILE_IO and both writeAtomic overloads from
# StoreInstaller.java, by signature, and runs RecordWritesCases: with "<name>.tmp" occupied by a non-empty directory
# (the temp cannot be opened, as root too) a failed write leaves the record byte for byte and is logged.
# writeAppModes needs an Activity, and capturePerms (static on a Context since NWP-20261112-07) reads PackageManager and
# AppOps for every package, so neither can be lifted and both are PINNED in code only (comments and string literals
# stripped): each writes its record only through StoreInstaller.writeAtomic and constructs no
# FileWriter (writeAppModes also has no renameTo fallback); setPlayDep and notePlaySeen construct no FileWriter.
#
# NWP-20261111-06: AN UNREADABLE PLAY RECORD IS UNKNOWN, NOT EMPTY. readPlayDeps / readPlaySeen read a file that exists
# but cannot be opened as empty, and their two writers rewrote the whole file from that read, so one read error turned
# every recorded Play client into none. The cases S1-S4 put a non-empty directory where the record belongs (it exists
# and cannot be opened, as root too): readPlayDepsStrict / readPlaySeenStrict answer null for it and empty for an absent
# file, and setPlayDep / notePlaySeen leave it as it is and log the abstention. reconcilePlayStack needs an Activity and
# cannot be lifted, so pins() also checks, in code only: its guard `if (readPlayDepsStrict(this) == null)` returns
# before the first applyStackMember( and before m.remove(VENDING_PKG), and the playClients line test-appmode-lock.sh's
# mutants anchor on is unchanged byte for byte.
#
# NWP-20261112-03: AN UNREADABLE KEEP-SET IS UNKNOWN, NOT EMPTY. readAppModes / readAppGroups read a nowhere-appkeep
# that exists but cannot be opened (or fails mid-file) as empty (or as the lines read so far), and setAppModeLocked /
# writeAppModes rewrote EVERY keep line and group: token from that read, so one EIO turned a single toggle into "the
# keep-set is this one app", and the logoff sealed it. K1 puts a non-empty directory where nowhere-appkeep belongs:
# readAppModesStrictIn / readAppGroupsStrict answer null for it and empty for an absent file. K2 feeds parseAppModes /
# parseAppGroups, and the strict readers through run.sh's seam copies, a reader that fails after its first line: the
# IOException escapes the parsers and the readers answer null, never the one-line partial map. setAppModeLocked,
# writeAppModes and applyKeepModeOffThread need an Activity, so pins() checks them in code only: setAppModeLocked's
# first act under APPKEEP_LOCK is the strict read, whose null returns KEEPSET_UNREADABLE before putAppMode(,
# recordTurnedOff(, setPlayDep( and reconcilePlayStack(; writeAppModes returns it on either strict read's null before
# StoreInstaller.writeAtomic( (and calls neither lenient reader); applyKeepModeOffThread tests KEEPSET_UNREADABLE (the
# Toast) before showOverPlanDialog(.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (exit 2), like the other javac suites.
#
#   bash test-record-writes-java.sh            # the cases and the pins
#   bash test-record-writes-java.sh --mutate   # ... plus broken copies that must each FAIL them
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/src/com/nowhere/chooser/ProfileActivity.java"
SI="$HERE/src/com/nowhere/chooser/StoreInstaller.java"
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SRC="$a" ;; esac; done
RUN="$HERE/tests/record-writes/run.sh"
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
[ -f "$SRC" ] && [ -f "$SI" ] && [ -f "$RUN" ] || { echo "FAIL: missing $SRC, $SI or $RUN" >&2; exit 2; }

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

# guarded <code-only body> <call regex>: "R I U" -- R the line of `<var> = <call>;`, I the line of the first
# `if (<var> == null) {` after it, U the line of a `return KEEPSET_UNREADABLE;` inside that if's braces (0 = absent).
guarded(){ CALL="$2" awk '
  BEGIN { r=0; i=0; u=0 }
  !r && match($0, "[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*" ENVIRON["CALL"] "[[:space:]]*;") {
    r=NR; v=substr($0, RSTART, RLENGTH); sub(/[[:space:]]*=.*/, "", v); next }
  r && !i && index($0, "if (" v " == null) {") { i=NR; d=0 }
  i && !u && !shut {
    n=length($0); for (k=1;k<=n;k++) { c=substr($0,k,1); if (c=="{") d++; else if (c=="}") { d--; if (d==0) { shut=1; break } } }
    if (/return KEEPSET_UNREADABLE;/ && (d>0 || shut)) u=NR
  }
  END { print r+0, i+0, u+0 }' <<<"$1"; }

# pins <ProfileActivity.java>: 0 all hold, 1 a pin failed, 2 an anchor moved.
pins() {
  local f="$1" body raw bad=0 spec name re target extra
  # name|signature regex|record file|extra banned token
  for spec in \
    'capturePerms|static void capturePerms\(android\.content\.Context ctx, java\.util\.Map<String,String> keptModes, boolean midSession\) \{|nowhere-perms|' \
    'writeAppModes|private java\.util\.Set<String> writeAppModes\(|nowhere-appkeep|renameTo' \
    'setPlayDep|static void setPlayDep\(android\.content\.Context ctx, String pkg, boolean on\) \{|nowhere-playdeps|' \
    'notePlaySeen|static void notePlaySeen\(android\.content\.Context ctx, String pkg, boolean needsPlay\) \{|nowhere-playseen|'; do
    IFS='|' read -r name re target extra <<<"$spec"
    body=$(method "$f" "$re") && [ -n "$body" ] || { echo "EXTRACTION FAILED -- $name's anchor moved or its braces do not balance" >&2; return 2; }
    raw=$(rawmethod "$f" "$re") || { echo "EXTRACTION FAILED -- $name (raw)" >&2; return 2; }
    if grep -qE '(^|[^[:alnum:]_$])FileWriter([^[:alnum:]_$]|$)' <<<"$body"; then
      echo "  FAIL  $name constructs a FileWriter -- a truncating write over a roaming record"; bad=1
    else
      echo "  ok    $name constructs no FileWriter"
    fi
    if [ "$(grep -cE 'StoreInstaller[[:space:]]*\.[[:space:]]*writeAtomic[[:space:]]*\(' <<<"$body")" = 1 ] &&
       grep -qE "^[[:space:]]*(try \{ *)?StoreInstaller\.writeAtomic\(.*\"$target\"|^[[:space:]]*StoreInstaller\.writeAtomic\(f, " <<<"$raw"; then
      echo "  ok    $name writes $target through StoreInstaller.writeAtomic, once"
    else
      echo "  FAIL  $name does not write $target through exactly one StoreInstaller.writeAtomic"; bad=1
    fi
    if [ -n "$extra" ]; then
      if grep -qE "(^|[^[:alnum:]_$])$extra[[:space:]]*\(" <<<"$body"; then
        echo "  FAIL  $name calls $extra -- a direct-write fallback"; bad=1
      else
        echo "  ok    $name has no $extra fallback"
      fi
    fi
  done
  # NWP-20261111-06: reconcilePlayStack leaves the stack as kept when nowhere-playdeps is unreadable
  local rre lg lr lp la lv
  rre='private void reconcilePlayStack\(java\.util\.Map<String,String> m, java\.util\.Set<String> preKept\) \{'
  body=$(method "$f" "$rre") && [ -n "$body" ] || { echo "EXTRACTION FAILED -- reconcilePlayStack" >&2; return 2; }
  raw=$(rawmethod "$f" "$rre") || { echo "EXTRACTION FAILED -- reconcilePlayStack (raw)" >&2; return 2; }
  lg=$(grep -nE 'if[[:space:]]*\([[:space:]]*readPlayDepsStrict[[:space:]]*\([[:space:]]*this[[:space:]]*\)[[:space:]]*==[[:space:]]*null' <<<"$body" | head -1 | cut -d: -f1)
  lr=""
  [ -z "$lg" ] || lr=$(awk -v g="$lg" 'NR > g && /(^|[^[:alnum:]_$])return[[:space:]]*;/ { print NR; exit }' <<<"$body")
  lp=$(grep -nE 'playClients[[:space:]]*=' <<<"$body" | head -1 | cut -d: -f1)
  la=$(grep -nE 'applyStackMember[[:space:]]*\(' <<<"$body" | head -1 | cut -d: -f1)
  lv=$(grep -nE '(^|[^[:alnum:]_$])m[[:space:]]*\.[[:space:]]*remove[[:space:]]*\([[:space:]]*VENDING_PKG' <<<"$body" | head -1 | cut -d: -f1)
  if [ -n "$lg" ] && [ -n "$lr" ] && [ -n "$lp" ] && [ -n "$la" ] && [ -n "$lv" ] &&
     [ "$lg" -lt "$lr" ] && [ "$lr" -lt "$lp" ] && [ "$lr" -lt "$la" ] && [ "$lr" -lt "$lv" ]; then
    echo "  ok    reconcilePlayStack returns on an unreadable nowhere-playdeps before it touches the stack"
  else
    echo "  FAIL  reconcilePlayStack has no readPlayDepsStrict(this) == null guard returning before applyStackMember / m.remove(VENDING_PKG)"; bad=1
  fi
  if [ "$(grep -cxF '        java.util.Set<String> playClients = readPlayDeps(this);' <<<"$raw")" = 1 ]; then
    echo "  ok    reconcilePlayStack's playClients line is unchanged (test-appmode-lock.sh anchors on it)"
  else
    echo "  FAIL  reconcilePlayStack's playClients line changed"; bad=1
  fi
  # NWP-20261112-03: the keep-set writers write nothing from a failed read
  local sb wb kb gl lsync lrd lif lret lfirst ltm lgr lgi lgret lwa lk lt lo
  sb=$(method "$f" 'private java\.util\.Set<String> setAppModeLocked\(String pkg, String mode, Boolean overPlanNow\) \{') && [ -n "$sb" ] ||
    { echo "EXTRACTION FAILED -- setAppModeLocked" >&2; return 2; }
  set -- $(guarded "$sb" 'readAppModesStrictIn\(getFilesDir\(\)\)'); lrd=$1; lif=$2; lret=$3
  lsync=$(grep -nE 'synchronized[[:space:]]*\([[:space:]]*StoreInstaller\.APPKEEP_LOCK[[:space:]]*\)' <<<"$sb" | head -1 | cut -d: -f1)
  lfirst=$(grep -nE '(^|[^[:alnum:]_$.])(putAppMode|recordTurnedOff|setPlayDep|reconcilePlayStack)[[:space:]]*\(' <<<"$sb" | head -1 | cut -d: -f1)
  if [ -n "$lsync" ] && [ -n "$lfirst" ] && [ "$lrd" -gt 0 ] && [ "$lif" -gt 0 ] && [ "$lret" -gt 0 ] &&
     [ "$lsync" -lt "$lrd" ] && [ "$lrd" -lt "$lif" ] && [ "$lif" -lt "$lret" ] && [ "$lret" -lt "$lfirst" ] &&
     [ "$(awk -v s="$lsync" -v r="$lrd" 'NR > s && NR < r && /[^[:space:]]/' <<<"$sb" | wc -l)" = 0 ]; then
    echo "  ok    setAppModeLocked: the strict keep-set read is the first statement under APPKEEP_LOCK, and its null returns KEEPSET_UNREADABLE before putAppMode / recordTurnedOff / setPlayDep / reconcilePlayStack"
  else
    echo "  FAIL  setAppModeLocked edits or writes before (or without) returning KEEPSET_UNREADABLE on an unreadable keep-set"; bad=1
  fi
  wb=$(method "$f" 'private java\.util\.Set<String> writeAppModes\(') || return 2
  set -- $(guarded "$wb" 'readAppModesStrictIn\(getFilesDir\(\)\)'); lk=$3
  set -- $(guarded "$wb" 'readAppGroupsStrict\(this\)'); lgret=$3
  lwa=$(grep -nE 'StoreInstaller[[:space:]]*\.[[:space:]]*writeAtomic[[:space:]]*\(' <<<"$wb" | head -1 | cut -d: -f1)
  if [ -n "$lwa" ] && [ "$lk" -gt 0 ] && [ "$lgret" -gt 0 ] && [ "$lk" -lt "$lwa" ] && [ "$lgret" -lt "$lwa" ]; then
    echo "  ok    writeAppModes returns KEEPSET_UNREADABLE before StoreInstaller.writeAtomic when either strict read is null"
  else
    echo "  FAIL  writeAppModes can reach StoreInstaller.writeAtomic from a failed keep-set or group read"; bad=1
  fi
  if grep -qE '(^|[^[:alnum:]_$.])(readAppModes|readAppModesIn|readAppGroups)[[:space:]]*\(' <<<"$wb"; then
    echo "  FAIL  writeAppModes calls a lenient keep-set reader"; bad=1
  else
    echo "  ok    writeAppModes calls no lenient keep-set reader"
  fi
  kb=$(method "$f" 'private void applyKeepModeOffThread\(') || { echo "EXTRACTION FAILED -- applyKeepModeOffThread" >&2; return 2; }
  lk=$(grep -nE '==[[:space:]]*KEEPSET_UNREADABLE([^[:alnum:]_$]|$)' <<<"$kb" | head -1 | cut -d: -f1)
  lt=$(grep -nE 'Toast[[:space:]]*\.[[:space:]]*makeText[[:space:]]*\(' <<<"$kb" | head -1 | cut -d: -f1)
  lo=$(grep -nE 'showOverPlanDialog[[:space:]]*\(' <<<"$kb" | head -1 | cut -d: -f1)
  if [ -n "$lk" ] && [ -n "$lt" ] && [ -n "$lo" ] && [ "$lk" -lt "$lt" ] && [ "$lt" -le "$lo" ]; then
    echo "  ok    applyKeepModeOffThread tests KEEPSET_UNREADABLE (and toasts) before showOverPlanDialog"
  else
    echo "  FAIL  applyKeepModeOffThread does not tell the user an unsaved change apart from the over-plan dialog"; bad=1
  fi
  # the target of writeAppModes' writeAtomic is the file it names "nowhere-appkeep"
  raw=$(rawmethod "$f" 'private java\.util\.Set<String> writeAppModes\(') || return 2
  if grep -qE 'java\.io\.File f = new java\.io\.File\(getFilesDir\(\), "nowhere-appkeep"\);' <<<"$raw"; then
    echo "  ok    writeAppModes' f is nowhere-appkeep"
  else
    echo "  FAIL  writeAppModes' f is not nowhere-appkeep"; bad=1
  fi
  return "$bad"
}

# suite <ProfileActivity.java> -> 0 pass, 1 a case or pin failed (only this may convict a mutant), 2 a member did not
# extract, 3 the lifted classes did not compile.
suite() {
  local rc=0 prc=0
  bash "$RUN" "$1" "$SI" || rc=$?
  [ "$rc" -le 1 ] || return "$rc"
  pins "$1" || prc=$?
  [ "$prc" -le 1 ] || return 2
  [ "$rc" = 0 ] && [ "$prc" = 0 ] && return 0
  return 1
}

echo "== $SRC"
suite "$SRC"; rc=$?
if [ "$rc" -ne 0 ]; then echo "FAILED (rc=$rc)"; [ "$rc" -eq 1 ] && exit 1 || exit 2; fi
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED; one that does not apply or compile is a failure)"
mut() { # mut <label> <perl-expr> <lines-that-must-change>
  local d m rc changed; d=$(mktemp -d -p "$W"); m="$d/ProfileActivity.java"
  if ! perl -0pe "$2" "$SRC" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$SRC" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  changed=$(diff "$SRC" "$m" | grep -c '^>')
  if [ "$changed" -ne "$3" ]; then
    echo "  ERROR     $1 -- the mutation changed $changed line(s), expected $3"; rm -rf "$d"; return 1; fi
  suite "$m" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not extract or compile (rc=$rc)"; return 1 ;;
  esac
}
# revert <file name>: the writeAtomic try-block of setPlayDep / notePlaySeen back to the truncating FileWriter
revert() { echo 's/try \{\n(\s+)StoreInstaller\.writeAtomic\(new java\.io\.File\(ctx\.getFilesDir\(\), "'"$1"'"\), sb\.toString\(\)\);/try (java.io.FileWriter fw = new java.io.FileWriter(new java.io.File(ctx.getFilesDir(), "'"$1"'"))) {\n$1fw.write(sb.toString());/'; }
fails=0
mut "R1 setPlayDep writes nowhere-playdeps with a direct FileWriter" "$(revert nowhere-playdeps)" 2 || fails=$((fails+1))
mut "R2 notePlaySeen writes nowhere-playseen with a direct FileWriter" "$(revert nowhere-playseen)" 2 || fails=$((fails+1))
mut "R3 capturePerms writes nowhere-perms with a direct FileWriter" 's/StoreInstaller\.writeAtomic\(new java\.io\.File\(ctx\.getFilesDir\(\), "nowhere-perms"\), sb\.toString\(\)\);/try (java.io.FileWriter fw = new java.io.FileWriter(ctx.getFilesDir() + "\/nowhere-perms")) { fw.write(sb.toString()); }/' 1 || fails=$((fails+1))
mut "R4 writeAppModes falls back to a direct write when the rename fails" 's/(java\.io\.File f = new java\.io\.File\(getFilesDir\(\), "nowhere-appkeep"\);\n)(\s+)StoreInstaller\.writeAtomic\(f, sb\.toString\(\)\);/${1}${2}java.io.File tmp = new java.io.File(getFilesDir(), "nowhere-appkeep.tmp");\n${2}try (java.io.FileWriter fw = new java.io.FileWriter(tmp)) { fw.write(sb.toString()); }\n${2}if (!tmp.renameTo(f)) { try (java.io.FileWriter fw = new java.io.FileWriter(f)) { fw.write(sb.toString()); } }/' 3 || fails=$((fails+1))
# NWP-20261111-06
mut "M1 readPlayDepsStrict reads an unopenable file as empty" 's/(static java\.util\.Set<String> readPlayDepsStrict\(android\.content\.Context ctx\) \{.*?)\} catch \(Exception e\) \{ return null; \}/${1}} catch (Exception e) { return new java.util.LinkedHashSet<>(); }/s' 1 || fails=$((fails+1))
mut "M2 setPlayDep falls through an unreadable nowhere-playdeps to a write" 's/if \(onDisk == null\) \{/if (onDisk == null) onDisk = new java.util.LinkedHashSet<>(); if (false) {/' 1 || fails=$((fails+1))
mut "M3 notePlaySeen reads through the lenient readPlaySeen again" 's/java\.util\.Map<String,String\[\]> m = readPlaySeenStrict\(ctx\);/java.util.Map<String,String[]> m = readPlaySeen(ctx);/' 1 || fails=$((fails+1))
mut "M5 reconcilePlayStack's unreadable-playdeps guard deleted" 's/\n        if \(readPlayDepsStrict\(this\) == null\) \{\n.*?\n        \}\n/\n/s' 0 || fails=$((fails+1))
# NWP-20261112-03 (the task's M1-M6; AK so the labels do not collide with M1-M5 above)
mut "AK1 parseAppModes swallows the IOException (a part-read keep-set parses)" 's/(parseAppModes\(java\.io\.BufferedReader br\) throws java\.io\.IOException \{\n.*?)while \(\(line = br\.readLine\(\)\) != null\) \{/${1}while ((line = ((java.util.function.Supplier<String>) () -> { try { return br.readLine(); } catch (java.io.IOException x) { return null; } }).get()) != null) {/s' 1 || fails=$((fails+1))
mut "AK2 readAppModesStrictIn reads an unopenable nowhere-appkeep as empty" 's/(static java\.util\.LinkedHashMap<String,String> readAppModesStrictIn\(java\.io\.File filesDir\) \{.*?)\} catch \(Exception e\) \{ return null; \}/${1}} catch (Exception e) { return new java.util.LinkedHashMap<>(); }/s' 1 || fails=$((fails+1))
mut "AK3 setAppModeLocked's unreadable-keep-set branch deleted" 's/\n        if \(m == null\) \{ \/\/ NWP-20261112-03[^\n]*\n[^\n]*\n            return KEEPSET_UNREADABLE;\n        \}\n/\n/' 0 || fails=$((fails+1))
mut "AK4 setAppModeLocked's guard moved after putAppMode" 's/\n(        if \(m == null\) \{ \/\/ NWP-20261112-03[^\n]*\n[^\n]*\n            return KEEPSET_UNREADABLE;\n        \}\n)(.*?\n        putAppMode\(m, pkg, mode\);\n)/\n$2$1/s' 4 || fails=$((fails+1))
mut "AK5 writeAppModes reads the group tokens leniently again" 's/java\.util\.Map<String,String> groups = readAppGroupsStrict\(this\);/java.util.Map<String,String> groups = readAppGroups(this);/' 1 || fails=$((fails+1))
mut "AK6 applyKeepModeOffThread's sentinel test deleted" 's/final boolean unsaved = dropped == KEEPSET_UNREADABLE;/final boolean unsaved = false;/' 1 || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
