#!/usr/bin/env bash
# test-offlinemedia-folder-label.sh [<ProfileActivity.java>] [--mutate] -- Offline media labels a dot-less
# top-level shared dir ("Download") as a folder, not an app (NWP-20261014-32).
#
# pinnedApp returns the first path segment for anything outside Android/{data,media,obb}/, so the shared
# Download folder groups as a pseudo-app and mediaAppRow rendered the raw segment as an app. Package names
# always contain '.', so a dot-less segment is never a package. mediaFolderLabel is extracted from the
# source (pure Java, nothing Android) and RUN under a JVM.
#
#   bash test-offlinemedia-folder-label.sh            # the truth table
#   bash test-offlinemedia-folder-label.sh --mutate   # ... plus mutants that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/src/com/nowhere/chooser/ProfileActivity.java}"
[ -f "$SUT" ] || { echo "no such file: $SUT" >&2; exit 2; }

command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1 || {
  echo "SKIP: no javac/java on PATH -- this suite RUNS the method." >&2; exit 3; }

M=$(awk '/^    (private )?static String mediaFolderLabel\(/,/^    \}$/' "$SUT")
[ -n "$M" ] || { echo "EXTRACTION FAILED -- mediaFolderLabel not found in $SUT" >&2; exit 1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
{
  echo 'public class FolderT {'
  echo "$M"
  cat <<'JAVA'
    static int fails = 0;
    static void eq(String what, Object got, Object want) {
        if (!String.valueOf(got).equals(String.valueOf(want))) {
            System.out.println("FAIL " + what + ": got " + got + ", want " + want); fails++;
        } else System.out.println("ok   " + what);
    }
    public static void main(String[] a) {
        eq("Download is a folder", mediaFolderLabel("Download"), "Files · Download");
        eq("DCIM is a folder", mediaFolderLabel("DCIM"), "Files · DCIM");
        eq("a package keeps its app label", mediaFolderLabel("app.organicmaps"), null);
        eq("a system package keeps its app label", mediaFolderLabel("com.android.vending"), null);
        eq("a loose dotted file keeps today's label", mediaFolderLabel("foo.jpg"), null);
        eq("empty is not a folder", mediaFolderLabel(""), null);
        eq("null is not a folder", mediaFolderLabel(null), null);
        System.exit(fails == 0 ? 0 : 1);
    }
}
JAVA
} > "$T/FolderT.java"

if ! javac -d "$T" "$T/FolderT.java" 2>"$T/javac.err"; then
  echo "  FAIL  the extracted method does not compile:"; sed 's/^/        /' "$T/javac.err" | head -12; exit 1
fi
OUT=$(java -cp "$T" FolderT 2>&1); RC=$?
echo "$OUT"
FAIL=0; [ "$RC" = 0 ] || FAIL=1

if [ "$MUTATE" = yes ]; then
  echo; echo "== mutations (each MUST be convicted) =="
  MD=$(mktemp -d); trap 'rm -rf "$T" "$MD"' EXIT
  mutate(){
    sed "$2" "$SUT" > "$MD/PA.java" 2>/dev/null
    if cmp -s "$SUT" "$MD/PA.java"; then echo "  FAIL  MUTATION INERT: $1"; FAIL=1; return; fi
    if bash "$0" "$MD/PA.java" >/dev/null 2>&1; then echo "  FAIL  NOT CONVICTED: $1"; FAIL=1
    else echo "  ok    convicted: $1"; fi
  }
  mutate "the filed bug: always null (folders render as apps)" \
         's#return seg != null && !seg.isEmpty() && seg.indexOf(.\..) < 0 ? "Files#return null ? "Files#'
  mutate "tests '/' not '.'" \
         "s#seg.indexOf('.') < 0#seg.indexOf('/') < 0#"
  mutate "drops the empty guard" \
         's#!seg.isEmpty() && ##'
  mutate "labels packages too" \
         "s#seg.indexOf('.') < 0 ?#seg.indexOf('.') < 99 ?#"
fi
[ "$FAIL" = 0 ] && echo "PASS" || echo "FAILED"
[ "$FAIL" = 0 ]
