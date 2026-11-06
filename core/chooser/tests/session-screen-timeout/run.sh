#!/usr/bin/env bash
# run.sh <src dir> <work dir> -- SessionScreenTimeout's cases and the ChooserActivity pins (NWP-20261113-13, Q073).
#
# <src dir> holds ChooserActivity.java and SessionScreenTimeout.java (the tree's, or a mutant copy). Every temp this
# makes is inside <work dir>, which the caller owns and removes. JAVAC / JAVA come from the environment.
# Exit: 0 pass, 1 a case or a pin failed, 2 a source, a tool or the work dir is missing, 3 the class did not compile.
# Only 1 convicts a mutant.
set -uo pipefail

[ $# = 2 ] || { echo "usage: $0 <src dir> <work dir>" >&2; exit 2; }
SRC="$1"; WD="$2"
JAVAC="${JAVAC:-javac}"; JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
CASES="$here/SessionScreenTimeoutCases.java"
ACT="$SRC/ChooserActivity.java"
CLS="$SRC/SessionScreenTimeout.java"

[ -d "$WD" ] || { echo "  FAIL no work dir $WD" >&2; exit 2; }
for f in "$ACT" "$CLS" "$CASES"; do [ -f "$f" ] || { echo "  FAIL missing $f" >&2; exit 2; }; done
command -v perl >/dev/null 2>&1 || { echo "  FAIL this suite needs perl" >&2; exit 2; }

o=$(mktemp -d -p "$WD") || exit 2
cp "$CLS" "$CASES" "$o/"
"$JAVAC" -encoding UTF-8 -J-Djava.io.tmpdir="$WD" -d "$o" "$o/SessionScreenTimeout.java" \
  "$o/SessionScreenTimeoutCases.java" || { echo "  FAIL the class did not compile" >&2; exit 3; }
"$JAVA" -Djava.io.tmpdir="$WD" -cp "$o" com.nowhere.chooser.SessionScreenTimeoutCases || exit 1

# body <file> <signature-substring> -> the member from its signature line to the brace that closes it
body() {
  awk -v sig="$2" '
    !on && index($0, sig) { on=1; depth=0 }
    on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
  ' "$1"
}

# S1: ChooserActivity calls ensureSessionScreenTimeout exactly once, as ensureSessionScreenTimeout(uid); (so never
# from resume() or anywhere else too, whatever the argument)
n=$(perl -0ne 'my $k = () = /(?<!void )ensureSessionScreenTimeout\(/g; print $k' "$ACT")
[ "$n" = 1 ] || { echo "  PIN S1 ChooserActivity calls ensureSessionScreenTimeout $n times, not once" >&2; exit 1; }
n=$(grep -c '^[[:space:]]*ensureSessionScreenTimeout(uid);' "$ACT" || true)
[ "$n" = 1 ] || { echo "  PIN S1 no line calls ensureSessionScreenTimeout(uid); on its own" >&2; exit 1; }

# S2: in roamLogin's tail (sign-in and create), after prepRoamedUser(uid) and before applyRoamedPrefs()
b=$(body "$ACT" 'private void roamLogin(final String name, final String pw, final boolean isCreate, final String keyMode)')
[ -n "$b" ] || { echo "  PIN S2 roamLogin(name, pw, isCreate, keyMode) is missing" >&2; exit 1; }
order=$(printf '%s\n' "$b" | awk '
  /^[ \t]*prepRoamedUser\(uid\);/ && !p { p=NR }
  /^[ \t]*ensureSessionScreenTimeout\(uid\);/ && !e { e=NR }
  /^[ \t]*applyRoamedPrefs\(\);/ && !a { a=NR }
  END { print p+0, e+0, a+0 }')
read -r p e a <<<"$order"
if [ "$p" -eq 0 ] || [ "$e" -eq 0 ] || [ "$a" -eq 0 ] || [ "$p" -ge "$e" ] || [ "$e" -ge "$a" ]; then
  echo "  PIN S2 roamLogin does not call prepRoamedUser(uid), ensureSessionScreenTimeout(uid), applyRoamedPrefs() in" \
    "that order (lines $p $e $a)" >&2; exit 1
fi

# S3: the method writes NEW_SESSION_MS into user uid's own resolver, behind needsWrite(
m=$(body "$ACT" 'private void ensureSessionScreenTimeout(int uid)')
[ -n "$m" ] || { echo "  PIN S3 ensureSessionScreenTimeout(int uid) is missing" >&2; exit 1; }
printf '%s' "$m" | perl -0ne 'exit(/ContentResolver cr\s*=\s*createContextAsUser\(android\.os\.UserHandle\.of\(uid\), 0\)\s*\.getContentResolver\(\);/s ? 0 : 1)' || {
  echo "  PIN S3 the resolver is not createContextAsUser(UserHandle.of(uid), 0).getContentResolver()" >&2; exit 1; }
printf '%s' "$m" | perl -0ne 'exit(/SessionScreenTimeout\.needsWrite\(.*?Settings\.System\.putInt\(cr,[^;]*Settings\.System\.SCREEN_OFF_TIMEOUT[^;]*SessionScreenTimeout\.NEW_SESSION_MS/s ? 0 : 1)' || {
  echo "  PIN S3 no Settings.System.putInt(cr, SCREEN_OFF_TIMEOUT, NEW_SESSION_MS) behind SessionScreenTimeout.needsWrite(" >&2; exit 1; }

# S4: it never throws and runs on the caller's thread, so it lands before applyRoamedPrefs()
[[ "$m" == *'catch (Throwable'* ]] || { echo "  PIN S4 ensureSessionScreenTimeout does not catch Throwable" >&2; exit 1; }
[[ "$m" != *'new Thread'* ]] || { echo "  PIN S4 ensureSessionScreenTimeout starts a Thread: it would race applyRoamedPrefs()" >&2; exit 1; }

echo "  pins ok"
exit 0
