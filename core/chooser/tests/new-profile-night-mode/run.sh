#!/usr/bin/env bash
# run.sh <src dir> <work dir> -- NewProfileNightMode's cases and the ChooserActivity pins (NWP-20261124-18, #14).
#
# <src dir> holds ChooserActivity.java, NewProfileNightMode.java and GatePalette.java (the tree's, or a mutant copy).
# Every temp this makes is inside <work dir>, which the caller owns and removes. JAVAC / JAVA come from the environment.
# Exit: 0 pass, 1 a case or a pin failed, 2 a source, a tool or the work dir is missing, 3 the class did not compile.
# Only 1 convicts a mutant.
set -uo pipefail

[ $# = 2 ] || { echo "usage: $0 <src dir> <work dir>" >&2; exit 2; }
SRC="$1"; WD="$2"
JAVAC="${JAVAC:-javac}"; JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
CASES="$here/NewProfileNightModeCases.java"
ACT="$SRC/ChooserActivity.java"
CLS="$SRC/NewProfileNightMode.java"
PAL="$SRC/GatePalette.java"

[ -d "$WD" ] || { echo "  FAIL no work dir $WD" >&2; exit 2; }
for f in "$ACT" "$CLS" "$PAL" "$CASES"; do [ -f "$f" ] || { echo "  FAIL missing $f" >&2; exit 2; }; done
command -v perl >/dev/null 2>&1 || { echo "  FAIL this suite needs perl" >&2; exit 2; }

o=$(mktemp -d -p "$WD") || exit 2
cp "$CLS" "$PAL" "$CASES" "$o/"
"$JAVAC" -encoding UTF-8 -J-Djava.io.tmpdir="$WD" -d "$o" "$o/NewProfileNightMode.java" "$o/GatePalette.java" \
  "$o/NewProfileNightModeCases.java" || { echo "  FAIL the class did not compile" >&2; exit 3; }
"$JAVA" -Djava.io.tmpdir="$WD" -cp "$o" com.nowhere.chooser.NewProfileNightModeCases || exit 1

# body <file> <signature-substring> -> the member from its signature line to the brace that closes it
body() {
  awk -v sig="$2" '
    !on && index($0, sig) { on=1; depth=0 }
    on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
  ' "$1"
}

# P1: ChooserActivity calls ensureCreateNightMode exactly once, and only as `if (isCreate) ensureCreateNightMode(uid);`
n=$(perl -0ne 'my $k = () = /(?<!void )ensureCreateNightMode\(/g; print $k' "$ACT")
[ "$n" = 1 ] || { echo "  PIN P1 ChooserActivity calls ensureCreateNightMode $n times, not once" >&2; exit 1; }
n=$(grep -c '^[[:space:]]*if (isCreate) ensureCreateNightMode(uid);' "$ACT" || true)
[ "$n" = 1 ] || { echo "  PIN P1 no line calls ensureCreateNightMode(uid) under if (isCreate)" >&2; exit 1; }

# P2: in roamLogin's tail, after prepRoamedUser(uid) and before the switch-in (the first switchToUser(uid)
b=$(body "$ACT" 'private void roamLogin(final String name, final String pw, final boolean isCreate, final String keyMode)')
[ -n "$b" ] || { echo "  PIN P2 roamLogin(name, pw, isCreate, keyMode) is missing" >&2; exit 1; }
order=$(printf '%s\n' "$b" | awk '
  /^[ \t]*prepRoamedUser\(uid\);/ && !p { p=NR }
  /^[ \t]*if \(isCreate\) ensureCreateNightMode\(uid\);/ && !e { e=NR }
  /switchToUser\(uid/ && !s { s=NR }
  END { print p+0, e+0, s+0 }')
read -r p e s <<<"$order"
if [ "$p" -eq 0 ] || [ "$e" -eq 0 ] || [ "$s" -eq 0 ] || [ "$p" -ge "$e" ] || [ "$e" -ge "$s" ]; then
  echo "  PIN P2 roamLogin does not call prepRoamedUser(uid), if (isCreate) ensureCreateNightMode(uid), switchToUser(uid" \
    "in that order (lines $p $e $s)" >&2; exit 1
fi

# P3: the method writes Secure ui_night_mode into user uid's own resolver
m=$(body "$ACT" 'private void ensureCreateNightMode(int uid)')
[ -n "$m" ] || { echo "  PIN P3 ensureCreateNightMode(int uid) is missing" >&2; exit 1; }
printf '%s' "$m" | perl -0ne 'exit(/ContentResolver cr\s*=\s*createContextAsUser\(android\.os\.UserHandle\.of\(uid\), 0\)\s*\.getContentResolver\(\);/s ? 0 : 1)' || {
  echo "  PIN P3 the resolver is not createContextAsUser(UserHandle.of(uid), 0).getContentResolver()" >&2; exit 1; }
printf '%s' "$m" | perl -0ne 'exit(/android\.provider\.Settings\.Secure\.putInt\(cr, NewProfileNightMode\.SETTING, v\);/ ? 0 : 1)' || {
  echo "  PIN P3 no Settings.Secure.putInt(cr, NewProfileNightMode.SETTING, v)" >&2; exit 1; }

# P4: it reads the gate's look as applyGateLook does and maps it through NewProfileNightMode.value(
printf '%s' "$m" | perl -0ne 'exit(/NewProfileNightMode\.value\(\s*getSharedPreferences\("nowhere_gate", MODE_PRIVATE\)\.getString\(GatePalette\.KEY, null\)\)/s ? 0 : 1)' || {
  echo "  PIN P4 the value is not NewProfileNightMode.value(the nowhere_gate prefs' GatePalette.KEY)" >&2; exit 1; }

# P5: it never throws and runs on the caller's thread, so it lands before switch-in
[[ "$m" == *'catch (Throwable'* ]] || { echo "  PIN P5 ensureCreateNightMode does not catch Throwable" >&2; exit 1; }
[[ "$m" != *'new Thread'* ]] || { echo "  PIN P5 ensureCreateNightMode starts a Thread: it would race switch-in" >&2; exit 1; }

# P6: it names no profile (no name / pw in the method)
printf '%s' "$m" | perl -0ne 'exit(/\b(name|pw)\b/ ? 1 : 0)' || {
  echo "  PIN P6 ensureCreateNightMode refers to name or pw: it must log no profile" >&2; exit 1; }

echo "  pins ok"
exit 0
