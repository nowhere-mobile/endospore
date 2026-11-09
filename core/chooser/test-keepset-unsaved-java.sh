#!/usr/bin/env bash
# test-keepset-unsaved-java.sh [--mutate] -- a keep-set rewrite that fails is not reported as saved (NWP-20261128-15),
# run under javac.
#
# WHY THIS IS COMMITTED. ProfileActivity.writeAppModes logged a failed StoreInstaller.writeAtomic of nowhere-appkeep and
# carried on: it recorded the sighting, retired the Off record of every add it believed had landed, and returned
# `dropped`, so setAppMode's callers read "written". applyStorageDrop (the Storage screen's "Stop keeping it" and "Stop
# carrying it") also dropped setAppMode's answer, recorded the turn-off and toasted "Stopped keeping <app>" even for
# KEEPSET_UNREADABLE. On a full phone the keep line stayed and the next sign-out sealed the app again. writeAppModes now
# returns KEEPSET_UNREADABLE from the write's catch, before the sighting and clearTurnedOff, and applyStorageDrop records
# the turn-off and says "Stopped keeping" only when the rewrite landed, else SettingsSaveCopy.NOT_SAVED. The words are
# lifted into StorageDropCopy.line, which tests/keepset-unsaved/run.sh compiles and runs; the two ProfileActivity methods
# cannot be compiled off the build host, so their order is checked on the source, comments and literals stripped.
#
# On origin/main this suite FAILS with exit 1: checks (a), (b) and (c) fail, StorageDropCopy.java is absent so run.sh
# stubs main's inline words, and the not-saved case fails. Its mutants:
#   M1 writeAppModes' write catch loses its `return KEEPSET_UNREADABLE;`
#   M2 clearTurnedOff moved into that catch, ahead of the return
#   M3 applyStorageDrop's recordTurnedOff moved above the saved check
#   M4 StorageDropCopy.line answers "Stopped keeping" when not saved
# What it does NOT prove: how the toast looks on a full phone (a handset check), or that ProfileActivity compiles (the
# merger's full javac check).
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (exit 2), like the other javac suites.
#
#   bash test-keepset-unsaved-java.sh            # the checks and cases
#   bash test-keepset-unsaved-java.sh --mutate   # ... plus broken copies that must each FAIL them
# PROFILE_SRC and STORAGE_DROP_SRC override the two sources (to run against another tree).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PA="${PROFILE_SRC:-$HERE/src/com/nowhere/chooser/ProfileActivity.java}"
SDC="${STORAGE_DROP_SRC:-$HERE/src/com/nowhere/chooser/StorageDropCopy.java}"
SSC="$HERE/src/com/nowhere/chooser/SettingsSaveCopy.java"
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
RUN="$HERE/tests/keepset-unsaved/run.sh"
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
[ -f "$PA" ] && [ -f "$SSC" ] && [ -f "$RUN" ] || { echo "FAIL: missing $PA, $SSC or $RUN" >&2; exit 2; }

# One root for everything this suite creates (run.sh's work dir, every mutant copy); one trap.
W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT
export KEEPSET_UNSAVED_TMP="$W"

# ⚠ Every match reads its input to the end (a here-string or a count, never `cmd | grep -q`): under pipefail grep -q
# can SIGPIPE its producer and flip an absence check.
# codeonly: each line reduced to CODE -- comments dropped, string, char and text-block literals emptied. Same scanner
# as test-record-writes-java.sh.
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
# rawmethod <file> <signature-regex>: the same lines with comments dropped but string literals kept.
rawmethod(){
  local a b
  a=$(codeonly < "$1" | RE="$2" awk '$0 ~ ENVIRON["RE"] { print NR; exit }')
  [ -n "$a" ] || return 3
  b=$(method "$1" "$2" | wc -l) || return 3
  sed -n "${a},$((a + b - 1))p" "$1" | sed 's#[[:space:]]//.*$##'
}

# span <body> <open-line-regex>: "O E" -- O the first line matching the regex (it must end with the block's `{`), E the
# line that closes that block (0 0 when the regex never matches, O 0 when the braces do not balance).
span(){ RE="$2" awk '
  !o && $0 ~ ENVIRON["RE"] { o=NR; d=1; next }
  o && !e { n=length($0); for (k=1;k<=n;k++) { c=substr($0,k,1); if (c=="{") d++; else if (c=="}") { d--; if (d==0) { e=NR; break } } } }
  END { print o+0, e+0 }' <<<"$1"; }
# lines <body> <regex>: the line numbers that match, space-separated.
lines(){ RE="$2" awk '$0 ~ ENVIRON["RE"] { printf "%s ", NR }' <<<"$1"; }

# checks <ProfileActivity.java>: 0 all hold, 1 a check failed, 2 a method or anchor was not found (CONTROL failure).
checks(){
  local pa="$1" body raw f=0 lw lc le o e x ls lk n sp
  body=$(method "$pa" 'private java\.util\.Set<String> writeAppModes\(') || body=""
  if [ -z "$body" ]; then echo "  CONTROL FAILED -- writeAppModes not found"; return 2; fi
  lw=$(lines "$body" 'StoreInstaller\.writeAtomic\(f, sb\.toString\(\)\);'); lw=${lw%% *}
  if [ -z "$lw" ]; then echo "  CONTROL FAILED -- writeAppModes has no StoreInstaller.writeAtomic(f, sb.toString());"; return 2; fi
  sp=$(span "$(tail -n +"$((lw + 1))" <<<"$body")" '^[[:space:]]*\}[[:space:]]*catch[[:space:]]*\(Exception e\)[[:space:]]*\{[[:space:]]*$')
  read -r o e <<<"$sp"
  if [ "$o" -ne 1 ] || [ "$e" -eq 0 ]; then
    echo "  CONTROL FAILED -- writeAppModes: no } catch (Exception e) { on the line after the keep-set writeAtomic"; return 2; fi
  lc=$((lw + o)); le=$((lw + e))
  local ret=0 sa=0 ct=0 bad=0
  for x in $(lines "$body" 'return KEEPSET_UNREADABLE;'); do [ "$x" -gt "$lc" ] && [ "$x" -lt "$le" ] && ret=1; done
  for x in $(lines "$body" 'snapshotAppSeen[[:space:]]*\('); do sa=1; [ "$x" -gt "$le" ] || bad=1; done
  for x in $(lines "$body" 'clearTurnedOff[[:space:]]*\('); do ct=1; [ "$x" -gt "$le" ] || bad=1; done
  if [ "$ret" -eq 1 ] && [ "$sa" -eq 1 ] && [ "$ct" -eq 1 ] && [ "$bad" -eq 0 ]; then
    echo "  ok    (a) writeAppModes returns KEEPSET_UNREADABLE when its keep-set write fails, before the sighting and the Off-record retirement"
  else
    echo "  FAIL  (a) writeAppModes: write catch returns KEEPSET_UNREADABLE=$ret; snapshotAppSeen found=$sa," \
         "clearTurnedOff found=$ct; one of them inside or above the catch=$bad"; f=1
  fi

  body=$(method "$pa" 'private void applyStorageDrop\(') || body=""
  if [ -z "$body" ]; then echo "  CONTROL FAILED -- applyStorageDrop not found"; return 2; fi
  raw=$(rawmethod "$pa" 'private void applyStorageDrop\(') || raw=""
  if [ -z "$raw" ]; then echo "  CONTROL FAILED -- applyStorageDrop (raw) not found"; return 2; fi
  ls=$(lines "$body" 'dropped[[:space:]]*=[[:space:]]*setAppMode\(pkg, null\);'); ls=${ls%% *}
  lk=$(lines "$body" 'saved[[:space:]]*=.*!=[[:space:]]*KEEPSET_UNREADABLE'); lk=${lk%% *}
  sp=$(span "$body" 'if[[:space:]]*\(saved\)[[:space:]]*\{[[:space:]]*$'); read -r o e <<<"$sp"
  local rt=0 cs=0 rtin=0 csin=0 thr=0
  for x in $(lines "$body" 'recordTurnedOff[[:space:]]*\('); do rt=$((rt + 1)); [ "$o" -gt 0 ] && [ "$x" -gt "$o" ] && [ "$x" -lt "$e" ] && rtin=$((rtin + 1)); done
  for x in $(lines "$body" 'clearedStorageThisSession[[:space:]]*=[[:space:]]*true'); do cs=$((cs + 1)); [ "$o" -gt 0 ] && [ "$x" -gt "$o" ] && [ "$x" -lt "$e" ] && csin=$((csin + 1)); done
  n=$(grep -c 'catch[[:space:]]*(Throwable' <<<"$body" || true); [ "$n" -ge 1 ] && thr=1
  if [ -n "$ls" ] && [ -n "$lk" ] && [ "$o" -gt 0 ] && [ "$e" -gt 0 ] && [ "$ls" -lt "$lk" ] && [ "$lk" -lt "$o" ] \
     && [ "$rt" -eq 1 ] && [ "$rtin" -eq 1 ] && [ "$cs" -eq 1 ] && [ "$csin" -eq 1 ] && [ "$thr" -eq 1 ]; then
    echo "  ok    (b) applyStorageDrop compares setAppMode's answer with KEEPSET_UNREADABLE and records the turn-off only when saved"
  else
    echo "  FAIL  (b) applyStorageDrop: dropped = setAppMode at line '${ls:-none}', saved != KEEPSET_UNREADABLE at" \
         "'${lk:-none}', if (saved) { at $o-$e; recordTurnedOff $rtin of $rt inside, clearedStorageThisSession = true" \
         "$csin of $cs inside; a throw caught=$thr"; f=1
  fi
  n=$(grep -c 'StorageDropCopy\.line[[:space:]]*(' <<<"$body" || true)
  x=$(grep -c '"Stopped keeping' <<<"$raw" || true)
  if [ "$n" -ge 1 ] && [ "$x" -eq 0 ]; then
    echo "  ok    (c) applyStorageDrop takes its toast words from StorageDropCopy.line"
  else
    echo "  FAIL  (c) applyStorageDrop: StorageDropCopy.line calls=$n; inline \"Stopped keeping literals=$x"; f=1
  fi
  return "$f"
}

# suite <ProfileActivity.java> <StorageDropCopy.java> -> 0 pass, 1 a check or case failed (only this may convict a
# mutant), 2 a method or anchor was not found, 3 compile failure.
suite(){
  local rc1 rc2
  echo "== source checks on $1"
  checks "$1"; rc1=$?
  echo "== cases on $2"
  bash "$RUN" "$2" "$SSC"; rc2=$?
  [ "$rc1" -eq 2 ] && return 2
  [ "$rc2" -ge 2 ] && return "$rc2"
  [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] && return 0
  return 1
}

suite "$PA" "$SDC"; rc=$?
if [ "$rc" -ne 0 ]; then echo "FAILED (rc=$rc)"; [ "$rc" -eq 1 ] && exit 1 || exit 2; fi
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED; one that does not apply, extract or compile is a failure)"
mut() { # mut <label> <pa|sd> <perl-expr> [<lines-that-must-change>]
  local d m rc changed src; d=$(mktemp -d -p "$W"); m="$d/mutant.java"
  case "$2" in pa) src="$PA" ;; *) src="$SDC" ;; esac
  if ! perl -0pe "$3" "$src" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$src" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  changed=$(diff "$src" "$m" | grep -c '^>' || true)
  if [ "$changed" -ne "${4:-1}" ]; then
    echo "  ERROR     $1 -- the mutation changed $changed line(s), expected ${4:-1}"; rm -rf "$d"; return 1; fi
  case "$2" in
    pa) suite "$m" "$SDC" >/dev/null 2>&1; rc=$? ;;
    *)  suite "$PA" "$m" >/dev/null 2>&1; rc=$? ;;
  esac
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not extract or compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "M1 writeAppModes' write catch loses its return KEEPSET_UNREADABLE" pa \
  's/(android\.util\.Log\.w\("NowhereChooser", "writeAppModes", e\);\n) {12}return KEEPSET_UNREADABLE;[^\n]*\n/$1/' 0 \
  || fails=$((fails+1))
mut "M2 clearTurnedOff moved into the write catch, ahead of the return" pa \
  's/(android\.util\.Log\.w\("NowhereChooser", "writeAppModes", e\);\n)( {12}return KEEPSET_UNREADABLE;)(.*?\n) {8}(if \(!landed\.isEmpty\(\)\) StoreInstaller\.clearTurnedOff\(this, landed\);\n)/$1            $4$2$3/s' 1 \
  || fails=$((fails+1))
mut "M3 applyStorageDrop's recordTurnedOff moved above the saved check" pa \
  's/( {12}final boolean saved = ok && dropped != KEEPSET_UNREADABLE;\n {12}if \(saved\) \{\n)( {16}recordTurnedOff\(pkg\);[^\n]*\n)/$2$1/' 1 \
  || fails=$((fails+1))
mut "M4 StorageDropCopy.line answers Stopped keeping when not saved" sd \
  's/: SettingsSaveCopy\.NOT_SAVED;/: "Stopped keeping " + label + ". It\x27s still here until you log off.";/' \
  || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
