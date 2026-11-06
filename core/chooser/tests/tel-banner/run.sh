#!/usr/bin/env bash
# run.sh <core/chooser dir> -- NWP-20261013-41: lift ChooserActivity.summarize (pure, java.lang / java.util only) into a
# plain class and run TelBannerCases against it, and against the wiring around it (the count the receiver carries, the
# summary's caller). JAVAC and JAVA name the tools (default: javac, java on PATH);
# core/vendor-common/bin/test-tel-banner-java.sh resolves them and is what CI runs. Exit status: 0 every case passed;
# 1 a case failed; 2 cannot run (a tool, a file or the helper missing); 3 the lifted helper does not compile.
# --mutate counts only a 1.
set -uo pipefail
CH="${1:?usage: run.sh <core/chooser dir>}"
JAVAC="${JAVAC:-javac}"; JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
J="$CH/src/com/nowhere/chooser"
CA="$J/ChooserActivity.java"; SD="$J/SmsDeliverReceiver.java"
for f in "$CA" "$SD" "$here/TelBannerCases.java"; do
  [ -f "$f" ] || { echo "run.sh: no such file: $f" >&2; exit 2; }
done
command -v "$JAVAC" >/dev/null 2>&1 && command -v "$JAVA" >/dev/null 2>&1 \
  || { echo "run.sh: FAIL -- no javac/java ($JAVAC, $JAVA); this suite does not skip" >&2; exit 2; }
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
{
  echo "final class Lifted {"
  # from the method's declaration ('static', then its name and '(' -- never a call site) to the brace closing it
  awk '
    !on && $0 ~ "^[ \t]*(private |public )?static [^=;]* summarize[(]" { on=1; depth=0 }
    on { print; n=gsub(/[{]/,"{"); c=gsub(/[}]/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
  ' "$CA" | sed -E 's/^([ \t]*)(private |public )?static /\1static /'
  echo "}"
} > "$D/Lifted.java"
n=$(grep -cE "^[ \t]*static [^=;]* summarize[(]" "$D/Lifted.java" || true)
[ "$n" = 1 ] || { echo "run.sh: helper summarize found $n time(s), want 1" >&2; exit 2; }
cp "$here/TelBannerCases.java" "$D/"
"$JAVAC" -encoding UTF-8 -d "$D" "$D/Lifted.java" "$D/TelBannerCases.java" || { echo "run.sh: the lifted helper does not compile" >&2; exit 3; }
"$JAVA" -Dfile.encoding=UTF-8 -cp "$D" TelBannerCases "$CA" "$SD"
