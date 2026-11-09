#!/usr/bin/env bash
# test-label-cache-java.sh [--mutate] -- the app-label cache keeps its most recent 200 labels, under javac
# (NWP-20261128-43).
#
# WHY THIS IS COMMITTED. NWP-20260902-07's label cache (files/nowhere-applabels, sealed and roamed) lets Your data and
# the Storage screen name a kept app that is not on this phone. Its write kept the first 200 entries of a HashMap, an
# arbitrary subset that could drop the label just learned, and wrote by FileWriter + renameTo, which could leave
# nowhere-applabels.tmp in the sealed files dir. LabelCache (pure, java.* only) now holds the file rules and is
# compiled here alone with its cases: parse keeps file order and today's tab rule, put moves a new or changed label to
# the end, render writes the LAST cap entries. A source check (comments and string literals stripped) pins
# ProfileActivity: rememberLabel calls LabelCache.put and writes LabelCache.render through StoreInstaller.writeAtomic,
# neither rememberLabel nor labelCache makes a FileWriter or calls renameTo, labelCacheMap is a LinkedHashMap, and both
# methods stay synchronized.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-label-cache-java.sh            # the cases and the source check
#   bash test-label-cache-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
CACHE="${LABEL_CACHE_SRC:-$SRC/LabelCache.java}"
PROFILE="${LABEL_PROFILE_SRC:-$SRC/ProfileActivity.java}"
CASES="$root/core/chooser/tests/label-cache/LabelCacheCases.java"
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
command -v perl >/dev/null 2>&1 || { echo "FAIL: this suite needs perl to strip string literals" >&2; exit 2; }

# suite <LabelCache.java> -> 0 pass, 1 a case failed or the class is missing, 3 did not compile.
suite() {
  local cache="$1" d out rc
  [ -f "$cache" ] || { echo "  FAIL  LabelCache.java does not exist (the label cache rules are not lifted)" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$cache" "$d/src/com/nowhere/chooser/LabelCache.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/LabelCacheCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.LabelCacheCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# strip -> stdin with comment lines, "//" tails and the contents of string literals removed.
strip() {
  sed -e '/^[[:space:]]*\(\*\|\/\*\)/d' | perl -pe 's/"(?:[^"\\]|\\.)*"/""/g; s#//.*$##'
}

# method <file> <signature-regex> -> the method from its signature to its closing "    }", stripped.
method() {
  awk -v sig="$2" '$0 ~ sig { on = 1 } on { print } on && /^    }$/ { exit }' "$1" | strip
}

# source_check <ProfileActivity.java> -> 0 when the two cache methods hold, 1 otherwise.
source_check() {
  local profile="$1" rd wr all n bad=0
  rd=$(method "$profile" ' labelCache\\(\\) \\{$')
  wr=$(method "$profile" ' void rememberLabel\\(')
  [ -n "$rd" ] || { echo "  FAIL  labelCache() not found in $profile" >&2; bad=1; }
  [ -n "$wr" ] || { echo "  FAIL  rememberLabel( not found in $profile" >&2; bad=1; }
  [ "$bad" -eq 0 ] || return 1

  # S1 rememberLabel records through LabelCache.put (the move to the end).
  n=$(printf '%s\n' "$wr" | grep -cF 'LabelCache.put(')
  [ "$n" -ge 1 ] || { echo "  FAIL  rememberLabel does not call LabelCache.put(" >&2; bad=1; }

  # S2 rememberLabel writes LabelCache.render through StoreInstaller.writeAtomic.
  n=$(printf '%s\n' "$wr" | grep -F 'StoreInstaller.writeAtomic(' | grep -cF 'LabelCache.render(')
  [ "$n" -ge 1 ] || { echo "  FAIL  rememberLabel does not write LabelCache.render( by StoreInstaller.writeAtomic(" >&2; bad=1; }

  # S3 no FileWriter and no renameTo in either method.
  n=$(printf '%s\n%s\n' "$rd" "$wr" | grep -cE 'FileWriter|renameTo\(')
  [ "$n" -eq 0 ] || { echo "  FAIL  labelCache/rememberLabel still use FileWriter or renameTo ($n line(s))" >&2; bad=1; }

  # S4 labelCacheMap is a LinkedHashMap (insertion order), and no plain HashMap is made for it.
  all=$(strip < "$profile")
  n=$(printf '%s\n' "$all" | grep -cE '^    private java\.util\.LinkedHashMap<String,String> labelCacheMap;$')
  [ "$n" -eq 1 ] || { echo "  FAIL  labelCacheMap is not declared a java.util.LinkedHashMap<String,String>" >&2; bad=1; }
  n=$(printf '%s\n' "$all" | grep -cE '(^|[^A-Za-z])HashMap<String,String> labelCacheMap')
  [ "$n" -eq 0 ] || { echo "  FAIL  labelCacheMap is declared a HashMap" >&2; bad=1; }
  n=$(printf '%s\n%s\n' "$rd" "$wr" | grep -cE '(^|[^A-Za-z])HashMap<')
  [ "$n" -eq 0 ] || { echo "  FAIL  labelCache/rememberLabel name a plain HashMap ($n line(s))" >&2; bad=1; }

  # S5 both methods stay under the activity's monitor (NWP-20261016-48).
  n=$(printf '%s\n' "$rd" | head -1 | grep -cE '^    private synchronized ')
  [ "$n" -eq 1 ] || { echo "  FAIL  labelCache() is not private synchronized" >&2; bad=1; }
  n=$(printf '%s\n' "$wr" | head -1 | grep -cE '^    private synchronized ')
  [ "$n" -eq 1 ] || { echo "  FAIL  rememberLabel( is not private synchronized" >&2; bad=1; }
  [ "$bad" -eq 0 ]
}

# run_all <LabelCache.java> <ProfileActivity.java> -> 0 pass, 1 a check failed, 3 no compile.
run_all() {
  local rc out
  echo "== $1"
  out=$(suite "$1"); rc=$?
  echo "$out"
  [ "$rc" -eq 3 ] && return 3
  if source_check "$2"; then echo "source: ok"; else echo "FAILED (source)"; rc=1; fi
  return "$rc"
}

run_all "$CACHE" "$PROFILE"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAILED (rc=$rc)"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED -- a mutant that does not apply or does not compile proves nothing)"

# mut <label> <cache|profile> <perl-expr> -> 0 when the mutant is convicted.
mut() {
  local label="$1" which="$2" expr="$3" d orig c rc ca="$CACHE" pr="$PROFILE"
  case "$which" in cache) orig="$CACHE" ;; profile) orig="$PROFILE" ;; *) echo "  ERROR     $label -- $which"; return 1 ;; esac
  d=$(mktemp -d -p "$W") || return 1
  c="$d/$(basename "$orig")"
  cp "$orig" "$c"
  if ! perl -0pi -e "$expr" "$c"; then
    echo "  ERROR     $label -- perl failed on the mutation"; rm -rf "$d"; return 1
  fi
  if cmp -s "$orig" "$c"; then echo "  INERT     $label -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  case "$which" in cache) ca="$c" ;; profile) pr="$c" ;; esac
  run_all "$ca" "$pr" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $label"; return 1 ;;
    1) echo "  CONVICTED $label"; return 0 ;;
    *) echo "  BROKEN    $label -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "L1 render keeps the FIRST cap entries" cache \
  's/int skip = Math\.max\(0, m\.size\(\) - cap\);/int skip = 0;/; s/if \(skip > 0\) \{ skip--; continue; \}/if (cap-- <= 0) break;/' \
  || fails=$((fails+1))
mut "L2 put re-inserts without the move to the end" cache \
  's/        m\.remove\(pkg\);\n        m\.put\(pkg, label\);/        m.put(pkg, label);/' || fails=$((fails+1))
mut "L3 parse keeps a line with a leading tab" cache 's/if \(t <= 0 \|\| /if (t < 0 || /' || fails=$((fails+1))
mut "L4 rememberLabel writes by FileWriter on a .tmp + renameTo" profile \
  's/^            StoreInstaller\.writeAtomic\(new java\.io\.File\(getFilesDir\(\), LABEL_CACHE\), LabelCache\.render\(m, LabelCache\.CAP\)\);$/            java.io.File tmp = new java.io.File(getFilesDir(), LABEL_CACHE + ".tmp"); try (java.io.FileWriter w = new java.io.FileWriter(tmp)) { w.write(LabelCache.render(m, LabelCache.CAP)); } if (!tmp.renameTo(new java.io.File(getFilesDir(), LABEL_CACHE))) tmp.delete();/m' \
  || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
