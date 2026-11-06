#!/usr/bin/env bash
# test-report-preview-filter-java.sh [--mutate] -- NWP-20261113-39, backlog row "The issue report's "View what's
# sent" is one block of plain text: no search, no filter by log or tag". Runs core/chooser/tests/report-preview-filter:
# ReportPreviewFilter's sections, tags, filter and matches over a sample preview in report_issue.go's MarshalIndent
# shape (compiled and EXECUTED), then source checks that ProfileActivity.showReportPreview is a full-screen
# android.app.Dialog built on it, with no AlertDialog left and no Log call.
#
# It needs a JDK, and it FAILS when there is none. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
# --mutate re-runs the suite against broken copies, each of which must FAIL: a mutant that does not apply (INERT) or
# fails some other way than expected (BROKEN) counts as a failure, never a pass.
#
#   bash test-report-preview-filter-java.sh            # the cases
#   bash test-report-preview-filter-java.sh --mutate   # ... plus the mutants
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
  echo "test-report-preview-filter-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
command -v perl >/dev/null 2>&1 || { echo "test-report-preview-filter-java: FAIL -- the source checks need perl, and there is none; this suite did NOT run" >&2; exit 2; }
RPF="$ROOT/core/chooser/src/com/nowhere/chooser/ReportPreviewFilter.java"
PA="$ROOT/core/chooser/src/com/nowhere/chooser/ProfileActivity.java"

# check <ReportPreviewFilter.java> <ProfileActivity.java>: the cases, then the source checks.
check() {
  JAVAC=$JAVAC JAVA=$JAVA bash "$ROOT/core/chooser/tests/report-preview-filter/run.sh" "$1" "$2"
}
check "$RPF" "$PA" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <rpf|pa> <perl-expr> <text the failure must contain>
  local d f rpf pa out rc
  d=$(mktemp -d -p "$W"); rpf=$RPF; pa=$PA
  if [ "$2" = rpf ]; then f="$d/ReportPreviewFilter.java"; cp "$RPF" "$f"; else f="$d/ProfileActivity.java"; cp "$PA" "$f"; fi
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed"; return 1; fi
  if [ "$2" = rpf ]; then if cmp -s "$RPF" "$f"; then echo "  INERT     $1"; return 1; fi; rpf=$f
  else if cmp -s "$PA" "$f"; then echo "  INERT     $1"; return 1; fi; pa=$f; fi
  out=$(check "$rpf" "$pa" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  case "$out" in *"$4"*) ;; *) echo "  BROKEN    $1 -- it failed, but not with '$4' (rc=$rc)"; return 1 ;; esac
  echo "  convicted $1"
}
fails=0
mut "M1 matches is case-sensitive" rpf 's/text\.regionMatches\(true, i, query, 0, q\)/text.regionMatches(false, i, query, 0, q)/' \
  "FAIL matches(ODTEST): case-insensitive" || fails=$((fails+1))
mut "M2 filter ignores the tag" rpf 's/ && \(tag == null \|\| tag\.equals\(l\.tag\)\);/;/' \
  "FAIL filter(tag [logind])" || fails=$((fails+1))
mut "M3 sections drops the last log" rpf 's/(for \(Line l : ls\) if \(l\.header\) out\.add\(l\.section\);\n)(\s*return out;)/$1        if (out.size() > 1) out.remove(out.size() - 1);\n$2/' \
  "FAIL sections: status, then the logs in order" || fails=$((fails+1))
mut "M4 the unparseable fallback shows nothing" rpf 's/if \(ls == null\) return preview;/if (ls == null) return "";/' \
  "FAIL unparseable 0: filter returns it unchanged" || fails=$((fails+1))
mut "M5 the AlertDialog restored" pa 's/(private void showReportPreview\(String text\) \{\n)/$1        android.widget.ScrollView sc = new android.widget.ScrollView(this);\n        new android.app.AlertDialog.Builder(this).setTitle("What\x27s sent").setView(sc).setPositiveButton("Close", (d, w) -> {}).show();\n/' \
  "FAIL s3" || fails=$((fails+1))
mut "M6 the preview is logged" pa 's/(private void showReportPreview\(String text\) \{\n)/$1        Log.d("NowhereChooser", "preview " + text);\n/' \
  "FAIL s4" || fails=$((fails+1))
mut "M7 the Dialog is not full-screen" pa 's/new android\.app\.Dialog\(this,\s*android\.R\.style\.Theme_DeviceDefault_NoActionBar_Fullscreen\)/new android.app.Dialog(this)/' \
  "FAIL s2" || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
