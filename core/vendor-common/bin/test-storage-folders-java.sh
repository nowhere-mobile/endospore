#!/usr/bin/env bash
# test-storage-folders-java.sh [--mutate] -- NWP-20261125-09: "What's using your space" draws one row per top-level
# folder, each with its plan and phone figures, in place of the one "Your photos, videos and files" row
# (docs/product-decisions.md, h51 #4 A1; backlog row ""What's using your space" should name the RECLAIMABLE
# store-backed categories and evict them in-session"). Runs core/chooser/tests/storage-folders (StorageFolders' words,
# compiled and EXECUTED) and source checks that parseStorageBreakdown reads the daemon's `folders` and
# `folders_measured`, and that renderStorageList draws the folder rows through StorageFolders, keeps the one row when
# the reply has no folders, and counts folders in its empty-screen test.
#
# It needs a JDK, and it FAILS when there is none. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
# --mutate re-runs the suite against broken copies, each of which must FAIL: a mutant that does not apply (INERT) or
# fails for another reason (BROKEN) counts as a failure, never a pass.
#
#   bash test-storage-folders-java.sh            # the cases
#   bash test-storage-folders-java.sh --mutate   # ... plus the mutants
set -uo pipefail
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W"
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-storage-folders-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
command -v perl >/dev/null 2>&1 || { echo "test-storage-folders-java: FAIL -- the source checks need perl, and there is none; this suite did NOT run" >&2; exit 2; }
SRCDIR="$ROOT/core/chooser/src/com/nowhere/chooser"
SF="$SRCDIR/StorageFolders.java"
PA="$SRCDIR/ProfileActivity.java"

# strip <in> <out>: Java comments removed, string literals kept.
strip() {
  perl -0pe 's{("(?:\\.|[^"\\\n])*")|//[^\n]*|/\*.*?\*/}{defined $1 ? $1 : ""}gse' "$1" > "$2"
}

# body <file> <signature>: the method from its signature to its closing brace.
body() {
  awk -v sig="$2" '
    !on && index($0, sig) { on=1; depth=0 }
    on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
  ' "$1"
}

# has <text> <perl regex>: 0 when the text matches.
has() { perl -0e 'exit(($ARGV[0] =~ /$ARGV[1]/s) ? 0 : 1)' -- "$1" "$2"; }

# check <StorageFolders.java> <ProfileActivity.java>: the cases, then the source checks.
check() {
  local sf=$1 pa=$2 st pb rb pre_use pre_one
  [ -f "$sf" ] || { echo "FAIL c0: no StorageFolders.java"; return 1; }
  JAVAC=$JAVAC JAVA=$JAVA bash "$ROOT/core/chooser/tests/storage-folders/run.sh" "$sf" || return 1
  st=$(mktemp -p "$W") || return 1
  strip "$pa" "$st" || { echo "FAIL s0: could not strip $pa"; return 1; }
  pb=$(body "$st" "private StorageInfo parseStorageBreakdown(String json)")
  # (s0) control: the extractor found the parse (this matches before the folder read existed too)
  case "$pb" in *'si.mediaBytes = o.optLong("media_bytes", 0);'*) ;; *) echo "FAIL s0: parseStorageBreakdown was not found, or it no longer reads media_bytes"; return 1 ;; esac
  # (s1) the folder list is read: an array that may be missing, object entries only, each with its three fields
  has "$pb" 'org\.json\.JSONArray (\w+) = o\.optJSONArray\("folders"\);.*?for \(int (\w+) = 0; \2 < \1\.length\(\); \2\+\+\) \{\s*org\.json\.JSONObject (\w+) = \1\.optJSONObject\(\2\);\s*if \(\3 == null\) continue;\s*si\.folders\.add\(new StorageFolder\(\3\.optString\("name", ""\), \3\.optLong\("bytes", 0\), \3\.optLong\("store", 0\)\)\);' \
    || { echo "FAIL s1: parseStorageBreakdown does not read folders as [{name, bytes, store}] objects"; return 1; }
  has "$pb" 'if \(\w+ != null\) \{\s*for \(int' \
    || { echo "FAIL s1: parseStorageBreakdown does not treat a missing or non-array folders as no folders"; return 1; }
  # (s2) folders_measured is read
  case "$pb" in *'si.foldersMeasured = o.optBoolean("folders_measured", false);'*) ;; *) echo "FAIL s2: parseStorageBreakdown does not read folders_measured"; return 1 ;; esac
  echo "  ok   source checks s0 s1 s2"
  rb=$(body "$st" "private void renderStorageList(")
  # (s3) control: the extractor found the render and reached its remainder row
  case "$rb" in *'"Recent backups and shared data"'*) ;; *) echo "FAIL s3: renderStorageList was not found, or the body ends before the remainder row"; return 1 ;; esac
  # (s3) one row per folder through StorageFolders, with the folder's own figures
  has "$rb" 'if \(StorageFolders\.useFolderRows\(si\.folders\.size\(\)\)\) \{\s*for \(StorageFolder (\w+) : si\.folders\) \{\s*list\.addView\(storageInfoRow\(StorageFolders\.title\(\1\.name\),\s*StorageFolders\.line\(humanBytes\(\1\.bytes\), humanBytes\(\1\.store\), si\.foldersMeasured\), null\)' \
    || { echo "FAIL s3: renderStorageList does not draw one StorageFolders row per folder under StorageFolders.useFolderRows"; return 1; }
  # (s4) the empty-screen test counts folders: a phone holding only store-side folders is not "Nothing much"
  has "$rb" 'if \(si\.apps\.isEmpty\(\) && si\.mediaBytes == 0 && si\.cacheBytes == 0 && si\.folders\.isEmpty\(\)\) \{\s*TextView empty' \
    || { echo "FAIL s4: renderStorageList's empty test does not count folders"; return 1; }
  # (s5) today's one row is kept, in the else branch after the folder rows
  has "$rb" '\} else if \(si\.mediaBytes > 0\) \{\s*list\.addView\(storageInfoRow\("Your photos, videos and files", humanBytes\(si\.mediaBytes\)\s*\+ " on this phone · always comes with you", null\)' \
    || { echo "FAIL s5: renderStorageList does not keep the one row in an else branch for a reply with no folders"; return 1; }
  pre_use=${rb%%StorageFolders.useFolderRows(*}
  pre_one=${rb%%\"Your photos, videos and files\"*}
  [ "${#pre_use}" -lt "${#pre_one}" ] \
    || { echo "FAIL s5: the one row is not after the useFolderRows test"; return 1; }
  echo "  ok   source checks s3 s4 s5"
}
check "$SF" "$PA" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED; a mutant that does not apply proves nothing)"
mut() { # mut <label> <sf|pa> <perl-expr> <text the failure must contain>
  local d f sf pa src out rc
  d=$(mktemp -d -p "$W"); sf=$SF; pa=$PA
  case "$2" in
    sf) src=$SF; f="$d/StorageFolders.java"; sf=$f ;;
    pa) src=$PA; f="$d/ProfileActivity.java"; pa=$f ;;
    *) echo "  ERROR     $1 -- unknown file $2"; return 1 ;;
  esac
  cp "$src" "$f"
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed"; return 1; fi
  if cmp -s "$src" "$f"; then echo "  INERT     $1"; return 1; fi
  out=$(check "$sf" "$pa" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  case "$out" in *"$4"*) ;; *) echo "  BROKEN    $1 -- it failed, but not with '$4' (rc=$rc)"; return 1 ;; esac
  echo "  convicted $1"
}
fails=0
mut "m1 the \"\" title returns \"\"" sf 's/return OUTSIDE;/return "";/' "FAIL c1" || fails=$((fails+1))
mut "m2 the measured and not-measured lines swapped" sf 's/if \(measured\) return/if (!measured) return/' "FAIL c3" || fails=$((fails+1))
mut "m3 useFolderRows always false" sf 's/return n > 0;/return false;/' "FAIL c6" || fails=$((fails+1))
mut "m4 the parse ignores folders_measured" pa 's/si\.foldersMeasured = o\.optBoolean\("folders_measured", false\);/si.foldersMeasured = false;/' "FAIL s2" || fails=$((fails+1))
mut "m5 the empty test ignores folders" pa 's/ && si\.folders\.isEmpty\(\)\) \{/) {/' "FAIL s4" || fails=$((fails+1))
mut "m6 the parse reads no folder list" pa 's/o\.optJSONArray\("folders"\)/null/' "FAIL s1" || fails=$((fails+1))
mut "m7 the one row dropped for a reply with no folders" pa 's/\} else if \(si\.mediaBytes > 0\) \{\n(\s*)list\.addView\(storageInfoRow\("Your photos, videos and files"/} else if (false) {\n$1list.addView(storageInfoRow("Your photos, videos and files"/' "FAIL s5" || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
