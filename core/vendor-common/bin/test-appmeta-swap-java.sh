#!/usr/bin/env bash
# test-appmeta-swap-java.sh [--mutate] -- NWP-20261125-18: a failed placeholder capture keeps the previous snapshot.
# ProfileActivity.captureArchivedMeta used to rmTree files/nowhere-appmeta/<pkg> and rebuild it in place, so a throw
# after the delete (a full /data on the meta write, a PackageManager binder failure) left no snapshot, and a failed
# signer read wrote a cert-less meta over a good one. installArchivedPlaceholder refuses both, so the app lost its
# launcher icon and then its code line. Now the snapshot is built in a staging dir and AppMetaDir.publish swaps it in
# only when it is complete, or when there is no previous one. The swap never moves the published dir and never deletes
# its meta: it renames the new meta over the old one, so after any failure the dir holds a raisable meta.
# This suite compiles AppMetaDir with AppCodeManifest and core/chooser/tests/appmeta-swap/AppMetaDirCases.java ALONE
# and EXECUTES the cases on real temp dirs (C1-C17; after each, nowhere-appmeta holds only <pkg> dirs and no staging or
# aside dir is left). Each failure case checks, right after publish returns, what roamd's appcode_seal would seal
# ([ -d nowhere-appmeta/<pkg> ] && cp -r) and that installArchivedPlaceholder could raise it (meta, cert, act). Then it checks the REAL captureArchivedMeta with comments dropped:
#   S1  its body calls no rmTree.
#   S2  it builds into dir = AppMetaDir.stagingFor(...) after AppMetaDir.clear(dir, aside), and dir is never the
#       nowhere-appmeta/<pkg> path.
#   S3  it calls AppMetaDir.publish( exactly once, after the one meta StoreInstaller.writeAtomic.
#   S4  AppCodeLine's LOCK comment no longer says captureArchivedMeta rmTrees nowhere-appmeta.
#   S5  it calls AppMetaDir.recover(target, aside) before AppMetaDir.clear(dir, aside), and returns when it fails: an
#       aside that recover did not empty holds the only copy of old icons (C16, C17).
#   S6  a publish that returns false is logged: the line after `if (!AppMetaDir.publish(target, dir, aside))` is a
#       Log.w naming both outcomes, "swap failed" (C16's double failure) and "new snapshot incomplete" (C2).
#
# It needs a JDK and perl, and it FAILS when either is missing. javac/java come from PATH, then the build VM's JDK 21.
#
# --mutate re-runs it against broken copies, each of which must FAIL a named check. A mutant that does not apply (INERT)
# or does not compile (BROKEN) counts as a failure, never a pass:
#   MA1 rmTree of nowhere-appmeta/<pkg> back at the top of captureArchivedMeta (S1)
#   MA2 publish ignores complete() (C2)          MA3 complete() accepts a meta with no cert line (C2)
#   MA4 complete() accepts no meta file (C11)    MA5 restore does not move the old icons back (C9)
#   MA6 staging placed under nowhere-appmeta (C12)
#   MA7 publish moved before the meta writeAtomic (S3)
#   MA8 publish skips restore after a failure (C13)  MA9 restore has no copy fallback (C14)
#   MA10 publish deletes the old meta before the meta rename (C15)
#   MA11 recover deletes aside after a failed copy back (C16)   MA12 captureArchivedMeta skips recover (S5)
#   MA13 recover puts back a stale aside (C17)                  MA14 publish deletes aside instead of recover (C17)
#   MA15 captureArchivedMeta drops the log of a failed publish (S6)
#
#   bash core/vendor-common/bin/test-appmeta-swap-java.sh            # the cases and the source checks
#   bash core/vendor-common/bin/test-appmeta-swap-java.sh --mutate   # ... plus the mutants
set -uo pipefail
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-appmeta-swap-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
command -v perl >/dev/null 2>&1 || { echo "test-appmeta-swap-java: FAIL -- no perl; this suite did NOT run" >&2; exit 2; }
# ONE temp root: every class dir, case dir and mutant tree lives under it, and the trap removes it however this ends.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser
CASES=$ROOT/core/chooser/tests/appmeta-swap/AppMetaDirCases.java
IDS="C1 C2 C3 C4 C5 C6 C7 C8 C9 C10 C11 C12 C13 C14 C15 C16 C17"

# cases <root>: compile <root>'s AppMetaDir + AppCodeManifest with the cases ALONE and run them. 3 = no compile.
cases() {
  local d t out rc id bad=0
  d=$(mktemp -d -p "$W"); t=$(mktemp -d -p "$W")
  "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d" \
    "$1/$CH/AppMetaDir.java" "$1/$CH/AppCodeManifest.java" "$CASES" || return 3
  out=$("$JAVA" -Djava.io.tmpdir="$t" -cp "$d" com.nowhere.chooser.AppMetaDirCases 2>&1); rc=$?
  printf '%s\n' "$out"
  [ "$rc" -eq 0 ] || bad=1
  if grep -q '^FAIL ' <<<"$out"; then bad=1; fi
  for id in $IDS; do
    if ! grep -q "^ok $id " <<<"$out"; then echo "FAIL $id no ok line"; bad=1; fi
  done
  if [ -n "$(ls -A "$t")" ]; then echo "FAIL CT the cases left files in java.io.tmpdir"; bad=1; fi
  return "$bad"
}

# code <file> <signature line>: the member from its signature to its closing `    }`, with whole-line comments dropped
# and trailing `//` comments stripped (a `//` in a string is kept).
code() {
  perl -e '
    my ($f, $sig) = @ARGV; open(my $h, "<", $f) or die "$f: $!";
    my $in = 0;
    while (my $l = <$h>) {
      if (!$in) { next unless index($l, $sig) == 0; $in = 1; }
      last if $l =~ /^    \}$/;
      next if $l =~ m{^\s*(//|\*|/\*)};
      $l =~ s{^((?:[^"/\n]|"(?:[^"\\\n]|\\.)*"|/(?![/*]))*)//.*$}{$1};
      print $l;
    }' "$1" "$2"
}

# has <text> <fixed string>: 0 when the text holds it (a here-string, never a pipe into grep -q).
has() { grep -qF -- "$2" <<<"$1"; }
# count <text> <fixed string>: how many lines hold it.
count() { grep -cF -- "$2" <<<"$1"; }
# lineno <text> <fixed string>: the first line that holds it, empty when none.
lineno() { grep -nF -- "$2" <<<"$1" | head -1 | cut -d: -f1; }

SIG='    static void captureArchivedMeta(android.content.Context ctx, android.content.pm.PackageManager pm, String pkg, long vc) {'
WA='StoreInstaller.writeAtomic(new java.io.File(dir, "meta"), meta.toString());'

# sources <root>: S1-S6.
sources() {
  local r=$1 bad=0 body wl pl rl cl lw lm
  body=$(code "$r/$CH/ProfileActivity.java" "$SIG")
  if [ -z "$body" ]; then echo "EXTRACTION FAILED: captureArchivedMeta's signature line not found"; return 2; fi
  if has "$body" 'rmTree('; then echo "FAIL S1 captureArchivedMeta still calls rmTree"; bad=1
  else echo "ok S1 captureArchivedMeta calls no rmTree"; fi
  if ! has "$body" 'dir = AppMetaDir.stagingFor(files, pkg);'; then echo "FAIL S2 dir is not AppMetaDir.stagingFor(files, pkg)"; bad=1
  elif ! has "$body" 'AppMetaDir.clear(dir, aside);'; then echo "FAIL S2 no AppMetaDir.clear(dir, aside) before the build"; bad=1
  elif perl -0ne 'exit(/\bdir\s*=\s*new java\.io\.File\([^;]*"nowhere-appmeta"/ ? 0 : 1)' <<<"$body"; then
    echo "FAIL S2 dir is assigned the nowhere-appmeta/<pkg> path"; bad=1
  else echo "ok S2 captureArchivedMeta builds into the staging dir"; fi
  wl=$(lineno "$body" "$WA"); pl=$(lineno "$body" 'AppMetaDir.publish(')
  if [ "$(count "$body" "$WA")" -ne 1 ]; then echo "FAIL S3 not exactly one meta writeAtomic"; bad=1
  elif [ "$(count "$body" 'AppMetaDir.publish(')" -ne 1 ]; then echo "FAIL S3 not exactly one AppMetaDir.publish"; bad=1
  elif [ "$pl" -le "$wl" ]; then echo "FAIL S3 AppMetaDir.publish (line $pl) is not after the meta writeAtomic (line $wl)"; bad=1
  else echo "ok S3 captureArchivedMeta publishes once, after the meta writeAtomic"; fi
  if grep -qF 'captureArchivedMeta rmTrees nowhere-appmeta' "$r/$CH/AppCodeLine.java"; then
    echo "FAIL S4 AppCodeLine's LOCK comment still says captureArchivedMeta rmTrees nowhere-appmeta"; bad=1
  else echo "ok S4 AppCodeLine's LOCK comment says the dir is built aside and swapped in"; fi
  rl=$(lineno "$body" 'if (!AppMetaDir.recover(target, aside)) {'); cl=$(lineno "$body" 'AppMetaDir.clear(dir, aside);')
  if [ -z "$rl" ]; then echo "FAIL S5 no if (!AppMetaDir.recover(target, aside)) before the build"; bad=1
  elif [ -z "$cl" ] || [ "$rl" -ge "$cl" ]; then echo "FAIL S5 AppMetaDir.recover is not before AppMetaDir.clear(dir, aside)"; bad=1
  elif ! grep -q '^ *return; *$' <<<"$(sed -n "$rl,$((cl - 1))p" <<<"$body")"; then
    echo "FAIL S5 a failed recover does not return before the clear"; bad=1
  else echo "ok S5 captureArchivedMeta recovers a held aside before it clears it"; fi
  pl=$(lineno "$body" 'if (!AppMetaDir.publish(target, dir, aside))')
  if [ -n "$pl" ]; then lw=$(sed -n "$((pl + 1))p" <<<"$body"); lm=$(sed -n "$((pl + 2)),$((pl + 3))p" <<<"$body"); fi
  if [ -z "$pl" ]; then echo "FAIL S6 no if (!AppMetaDir.publish(target, dir, aside))"; bad=1
  elif ! has "$lw" 'android.util.Log.w("NowhereChooser", whole'; then
    echo "FAIL S6 a failed publish is not logged on the next line"; bad=1
  elif ! has "$lm" ': swap failed -- kept the previous snapshot'; then
    echo "FAIL S6 the log of a failed publish does not say the swap failed"; bad=1
  elif ! has "$lm" ': new snapshot incomplete -- kept the previous one (NWP-20261125-18)'; then
    echo "FAIL S6 the log of a failed publish does not say the new snapshot was incomplete"; bad=1
  else echo "ok S6 captureArchivedMeta logs a publish that returns false"; fi
  return "$bad"
}

# check <root>: 0 pass, 1 a failed check, 2 extraction failed, 3 the cases did not compile.
check() {
  local rc=0 crc src
  cases "$1"; crc=$?
  sources "$1"; src=$?
  [ "$src" -eq 2 ] && return 2
  [ "$crc" -eq 3 ] && return 3
  [ "$crc" -eq 0 ] || rc=1
  [ "$src" -eq 0 ] || rc=1
  return "$rc"
}

check "$ROOT"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAILED (rc=$rc)"; exit 1; }
[ "$MUTATE" = yes ] || { echo "PASS test-appmeta-swap-java"; exit 0; }

echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <path under the root> <perl-expr> <check the mutant must fail>
  local d f out rc n
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/$CH"
  for n in AppMetaDir.java AppCodeManifest.java ProfileActivity.java AppCodeLine.java; do
    cp "$ROOT/$CH/$n" "$d/$CH/$n"
  done
  f="$d/$2"
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed"; rm -rf "$d"; return 1; fi
  if cmp -s "$ROOT/$2" "$f"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  out=$(check "$d" 2>&1); rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if [ "$rc" -eq 2 ]; then echo "  BROKEN    $1 -- extraction failed"; return 1; fi
  if [ "$rc" -eq 3 ]; then echo "  BROKEN    $1 -- it did not compile"; return 1; fi
  if ! grep -qF -- "FAIL $4 " <<<"$out"; then echo "  BROKEN    $1 -- it failed, but not '$4' (rc=$rc)"; return 1; fi
  echo "  convicted $1 (fails '$4')"
}
A=$CH/AppMetaDir.java
P=$CH/ProfileActivity.java
fails=0 conv=0
tally() { if "$@"; then conv=$((conv+1)); else fails=$((fails+1)); fi; }
tally mut "MA1 rmTree of nowhere-appmeta/<pkg> restored at the top" "$P" \
  's/(            AppMetaDir\.clear\(dir, aside\);\n)/            rmTree(new java.io.File(new java.io.File(ctx.getFilesDir(), "nowhere-appmeta"), pkg));\n$1/' S1
tally mut "MA2 publish ignores complete()" "$A" \
  's/            if \(had && !whole\) \{ rm\(staged\); return false; \}\n//' C2
tally mut "MA3 complete() accepts a meta with no cert line" "$A" \
  's/for \(String c : AppCodeManifest\.parseMeta\(text\)\.certs\) if \(!c\.trim\(\)\.isEmpty\(\)\) return true;\n\s*return false;/return true;/' C2
tally mut "MA4 complete() accepts a staged dir with no meta file" "$A" \
  's/if \(!m\.isFile\(\)\) return false;/if (!m.isFile()) return true;/' C11
tally mut "MA5 restore does not move the old icons back" "$A" \
  's/if \(held == null\) return false;/if (held != null) return false;/' C9
tally mut "MA6 staging placed under nowhere-appmeta" "$A" \
  's/new java\.io\.File\(new java\.io\.File\(filesDir, "\.nowhere-appmeta-staging"\), pkg\)/new java.io.File(new java.io.File(new java.io.File(filesDir, "nowhere-appmeta"), ".staging"), pkg)/' C12
tally mut "MA7 publish moved before the meta writeAtomic" "$P" \
  's/(            StoreInstaller\.writeAtomic\(new java\.io\.File\(dir, "meta"\), meta\.toString\(\)\);\n)(            boolean whole = AppMetaDir\.complete\(dir\);\n            if \(!AppMetaDir\.publish\(target, dir, aside\)\)\n)/$2$1/' S3
tally mut "MA8 publish skips restore after a failure" "$A" \
  's/\n\s*if \(swapping\) restore\(target, aside, in, r, c\);//' C13
tally mut "MA9 restore has no copy fallback" "$A" \
  's/ok = c\.copy\(f, to\);/ok = false;/' C14
tally mut "MA10 publish deletes the old meta before the meta rename" "$A" \
  's/(\n(\s*)if \(!r\.rename\(new java\.io\.File\(staged, "meta"\))/\n$2new java.io.File(target, "meta").delete();$1/' C15
tally mut "MA11 recover deletes aside after a failed copy back" "$A" \
  's/\n\s*if \(!all\) return false;//' C16
tally mut "MA12 captureArchivedMeta skips recover" "$P" \
  's/if \(!AppMetaDir\.recover\(target, aside\)\) \{/if (false) {/' S5
tally mut "MA13 recover puts back a stale aside" "$A" \
  's/if \(!belongs\) \{/if (false) {/' C17
tally mut "MA14 publish deletes aside instead of recover" "$A" \
  's/if \(!recover\(target, aside, r, c\)\) \{ rm\(staged\); return false; \}/rm(aside);/' C17
tally mut "MA15 captureArchivedMeta drops the log of a failed publish" "$P" \
  's/(            if \(!AppMetaDir\.publish\(target, dir, aside\)\))\n                android\.util\.Log\.w\("NowhereChooser", whole\n[^\n]*\n[^\n]*\n/$1 { }\n/' S6
echo "== $conv convicted, $fails failed"
[ "$fails" -eq 0 ] && [ "$conv" -eq 15 ] || exit 1
echo "PASS test-appmeta-swap-java --mutate"
