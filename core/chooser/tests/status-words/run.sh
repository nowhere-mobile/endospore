#!/usr/bin/env bash
# run.sh <core/chooser dir> [<repo root>] -- NWP-20261122-19: lift ChooserActivity.otaApplyPhase and otaFailReason and
# ProfileActivity.coldLockWhy (pure, java.lang only) into a plain class and run StatusWordsCases against them. Then pin
# the tokens they read to the code that writes them: the update_engine phases in nowhere_otad.sh, its download phase,
# the FAILED codes of core/agent/main.go otaResState, and the line coldLockStatusLine formats. Each pin has a control
# that must match first, so a pin that finds nothing fails instead of passing.
# JAVAC and JAVA name the tools (default: javac, java on PATH); core/vendor-common/bin/test-status-words-java.sh
# resolves them and is what CI runs. The repo root defaults to <core/chooser dir>/../.. .
# Exit status: 0 every case and pin passed; 1 a case or a pin failed; 2 cannot run (a tool, a file or a member
# missing); 3 the lifted members do not compile. --mutate counts only a 1.
set -uo pipefail
CH="${1:?usage: run.sh <core/chooser dir> [<repo root>]}"
ROOT="${2:-$CH/../..}"
JAVAC="${JAVAC:-javac}"; JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
J="$CH/src/com/nowhere/chooser"
CA="$J/ChooserActivity.java"
PA="$J/ProfileActivity.java"
OTAD="$ROOT/core/vendor-common/bin/nowhere_otad.sh"
MAIN="$ROOT/core/agent/main.go"
CLT="$ROOT/core/agent/coldlock_status_test.go"
for f in "$CA" "$PA" "$OTAD" "$MAIN" "$CLT" "$here/StatusWordsCases.java"; do
  [ -f "$f" ] || { echo "run.sh: no such file: $f" >&2; exit 2; }
done
command -v "$JAVAC" >/dev/null 2>&1 && command -v "$JAVA" >/dev/null 2>&1 \
  || { echo "run.sh: FAIL -- no javac/java ($JAVAC, $JAVA); this suite does not skip" >&2; exit 2; }
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
D=$(mktemp -d -p "$W") || exit 2
# lift <method> <file>: from the method's declaration ('static', then its name and '(' -- never a call site) to the
# brace closing it, with any access modifier dropped.
lift() {
  awk -v m="$1" '
    !on && $0 ~ ("^[ \t]*(private |public )?static [^=;]* " m "[(]") { on=1; depth=0 }
    on { print; n=gsub(/[{]/,"{"); c=gsub(/[}]/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
  ' "$2" | sed -E 's/^([ \t]*)(private |public )?static /\1static /'
}
# body_go <func>: a top-level Go function of main.go, from its 'func' line to the first closing brace in column 1.
body_go() {
  awk -v f="$1" '$0 ~ ("^func " f "[(]") { on=1 } on { print } on && /^}/ { exit }' "$MAIN"
}
ap=$(lift otaApplyPhase "$CA")
fr=$(lift otaFailReason "$CA")
cw=$(lift coldLockWhy "$PA")
printf '%s\n' "final class Lifted {" "$ap" "$fr" "$cw" "}" > "$D/Lifted.java"
for m in otaApplyPhase otaFailReason coldLockWhy; do
  n=$(grep -cE "^[ \t]*static [^=;]* $m[(]" "$D/Lifted.java" || true)
  [ "$n" = 1 ] || { echo "run.sh: helper $m found $n time(s), want 1" >&2; exit 2; }
done
cp "$here/StatusWordsCases.java" "$D/"
"$JAVAC" -encoding UTF-8 -d "$D" "$D/Lifted.java" "$D/StatusWordsCases.java" \
  || { echo "run.sh: the lifted helpers do not compile" >&2; exit 3; }
echo "== cases"
"$JAVA" -Djava.io.tmpdir="$W" -cp "$D" StatusWordsCases; jrc=$?
[ "$jrc" -le 1 ] || { echo "run.sh: the cases did not run (rc=$jrc)" >&2; exit 2; }

echo "== pins"
fails=0
pass() { echo "  PASS $1"; }
fail() { echo "  FAIL $1: $2"; fails=$((fails+1)); }
# has <haystack> <literal>: the literal occurs in the haystack.
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

# K1: every phase otad's update_engine case writes has its own case in otaApplyPhase.
k1() {
  local blk words w
  blk=$(awk '/case "\$st" in/ { on=1 } on { print } on && /^[ \t]*esac/ { exit }' "$OTAD")
  words=$(printf '%s\n' "$blk" | grep -oE '(^|[[:space:]])ph=[a-z]+' | sed 's/.*ph=//' | sort -u)
  if [ -z "$words" ] || [ -z "$ap" ]; then
    fail "K1 control" "no ph= phase in the update_engine case of nowhere_otad.sh, or no otaApplyPhase in ChooserActivity.java"
    return
  fi
  pass "K1 control: otad writes $(echo $words)"
  for w in $words; do
    if has "$ap" "case \"$w\":"; then
      pass "K1 otad phase $w has its words"
    else
      fail "K1 otad phase $w" "no case in ChooserActivity.otaApplyPhase -- change nowhere_otad.sh and ChooserActivity.java together"
    fi
  done
}
k1

# K2: the download's phase, which renderOtaStatus reads in its DOWNLOADING arm.
k2() {
  local o c
  o=$(grep -cF 'NOWHERE_PHASE=osdownload' "$OTAD" || true)
  c=$(grep -cF '"osdownload".equals(pPhase)' "$CA" || true)
  if [ "$c" -ge 1 ]; then
    pass "K2 control: renderOtaStatus reads \"osdownload\""
  else
    fail "K2 control" "ChooserActivity.renderOtaStatus no longer reads \"osdownload\".equals(pPhase) -- change ChooserActivity.java and nowhere_otad.sh together"
    return
  fi
  if [ "$o" -ge 1 ]; then
    pass "K2 otad writes NOWHERE_PHASE=osdownload"
  else
    fail "K2 download phase" "nowhere_otad.sh no longer sets NOWHERE_PHASE=osdownload -- change nowhere_otad.sh and ChooserActivity.renderOtaStatus together"
  fi
}
k2

# K3: every FAILED code otaResState returns has its own case in otaFailReason.
k3() {
  local rs codes c
  rs=$(body_go otaResState)
  codes=$(printf '%s\n' "$rs" | grep -oE 'ERR-[A-Z]+' | sort -u)
  if [ -z "$codes" ] || ! has "$codes" "ERR-STALE" || [ -z "$fr" ]; then
    fail "K3 control" "no ERR- code (or no ERR-STALE) in core/agent/main.go otaResState, or no otaFailReason in ChooserActivity.java"
    return
  fi
  pass "K3 control: otaResState returns $(echo $codes)"
  for c in $codes; do
    if has "$fr" "case \"$c\":"; then
      pass "K3 FAILED $c has its reason"
    else
      fail "K3 FAILED $c" "no case in ChooserActivity.otaFailReason -- change core/agent/main.go otaResState and ChooserActivity.java together"
    fi
  done
}
k3

# K4: coldLockStatusLine still formats the three replies coldLockWhy reads.
k4() {
  local cs lit
  cs=$(body_go coldLockStatusLine)
  if [ -z "$cs" ] || [ -z "$cw" ]; then
    fail "K4 control" "no coldLockStatusLine in core/agent/main.go, or no coldLockWhy in ProfileActivity.java"
    return
  fi
  pass "K4 control: coldLockStatusLine found"
  for lit in 'fmt.Sprintf("WAITING %s %d", op, secs)' 'return "LOCKING"' 'return "NONE"'; do
    if has "$cs" "$lit"; then
      pass "K4 coldLockStatusLine holds $lit"
    else
      fail "K4 coldLockStatusLine" "no $lit -- change core/agent/main.go coldLockStatusLine and ProfileActivity.coldLockWhy together"
    fi
  done
}
k4

# K5: the seal op is "out" on both sides.
k5() {
  local t
  t=$(cat "$CLT")
  if ! has "$t" 'coldLockStatusLine('; then
    fail "K5 control" "core/agent/coldlock_status_test.go no longer calls coldLockStatusLine"
    return
  fi
  pass "K5 control: coldlock_status_test.go calls coldLockStatusLine"
  if has "$t" '"WAITING out 125"'; then
    pass "K5 the daemon's seal op is \"out\""
  else
    fail "K5 seal op" "coldlock_status_test.go no longer pins \"WAITING out 125\" -- change core/agent/main.go and ProfileActivity.coldLockWhy together"
  fi
  if has "$cw" '"out".equals(f[1])'; then
    pass "K5 coldLockWhy reads the seal op as \"out\""
  else
    fail "K5 seal op" "ProfileActivity.coldLockWhy no longer reads \"out\".equals(f[1]) -- change ProfileActivity.java and core/agent/main.go together"
  fi
}
k5

if [ "$jrc" -eq 0 ] && [ "$fails" -eq 0 ]; then
  echo "== all cases and pins passed"
  exit 0
fi
echo "== FAILED: cases rc=$jrc, $fails pin(s) failed"
exit 1
