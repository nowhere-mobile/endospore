#!/usr/bin/env bash
# run.sh <ReportPreviewFilter.java> <ProfileActivity.java> -- NWP-20261113-39: compile ReportPreviewFilter directly
# (pure Java, no android.*) with ReportPreviewFilterCases and run it, then check that ProfileActivity's
# showReportPreview is the full-screen dialog built on it. $JAVAC / $JAVA default to PATH;
# core/vendor-common/bin/test-report-preview-filter-java.sh is the CI entry point.
# Exit codes: 1 = a case or a source check failed; 2 = no perl; 3 = the source or the cases did not compile.
set -euo pipefail
SRC="${1:?usage: run.sh path/to/ReportPreviewFilter.java path/to/ProfileActivity.java}"
PA="${2:?usage: run.sh path/to/ReportPreviewFilter.java path/to/ProfileActivity.java}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
mkdir -p "$D/com/nowhere/chooser"
cp "$SRC" "$D/com/nowhere/chooser/ReportPreviewFilter.java"
# The cases live in the default package, so they reach the package-private class through a same-package shim.
sed -e '1i package com.nowhere.chooser;' "$here/ReportPreviewFilterCases.java" \
  > "$D/com/nowhere/chooser/ReportPreviewFilterCases.java"
"$JAVAC" -encoding UTF-8 -J-Djava.io.tmpdir="$D" -d "$D/out" "$D/com/nowhere/chooser/ReportPreviewFilter.java" \
  "$D/com/nowhere/chooser/ReportPreviewFilterCases.java" || exit 3
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D/out" com.nowhere.chooser.ReportPreviewFilterCases || exit 1

command -v perl >/dev/null 2>&1 || { echo "FAIL: the source checks need perl, and there is none"; exit 2; }

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

source_checks() {
  local pa=$1 st b caller fn
  st="$D/ProfileActivity.stripped"
  strip "$pa" "$st" || { echo "FAIL s0: could not strip $pa"; return 1; }
  b=$(body "$st" "private void showReportPreview(String text)")
  [ -n "$b" ] || { echo "FAIL s0: showReportPreview(String text) was not found"; return 1; }
  # (s1) the screen is built on ReportPreviewFilter: both filters, the filtered text and the search
  for fn in sections tags filter matches; do
    case "$b" in *"ReportPreviewFilter.$fn("*) ;; *) echo "FAIL s1: showReportPreview does not call ReportPreviewFilter.$fn("; return 1 ;; esac
  done
  # (s2) a full-screen android.app.Dialog, so the Report an issue screen and its note stay underneath
  has "$b" 'new android\.app\.Dialog\(this,\s*android\.R\.style\.Theme_[A-Za-z_]*Fullscreen\)' \
    || { echo "FAIL s2: showReportPreview does not build a full-screen android.app.Dialog"; return 1; }
  # (s3) the old one-block AlertDialog is gone
  case "$b" in *AlertDialog*|*'setView(sc)'*) echo "FAIL s3: showReportPreview still builds an AlertDialog / setView(sc)"; return 1 ;; esac
  # (s4) nothing logs the preview or the query
  ! has "$b" '(?<![\w.])Log\.[a-z]+\(' \
    || { echo "FAIL s4: showReportPreview logs (the preview or the query); it must log nothing"; return 1; }
  # (s5) the View what's sent button still hands the preview reply to it
  caller=$(body "$st" "private void showReportIssue()")
  has "$caller" 'secondaryButton\("View what.s sent".*?showReportPreview\(out\);' \
    || { echo "FAIL s5: the View what's sent button no longer calls showReportPreview(out)"; return 1; }
  echo "  ok   source checks s1 s2 s3 s4 s5"
}
source_checks "$PA" || exit 1
