#!/usr/bin/env bash
# test-support-end-java.sh [--mutate] -- the gate's and Profile's out-of-support line (NWP-20261125-04, h55 #2 in
# docs/product-decisions.md), run under javac.
#
# WHY THIS IS COMMITTED. A phone past the end of GrapheneOS full support keeps running its last build, and nobody at
# the gate or in Profile was told it gets no more security updates. Staging now bakes the device's support-end file
# to /system/etc/nowhere/support-end (test-support-end-stage.sh). The rule lives in SupportEnd, a pure class compiled
# here with its cases on either side of the date. Source pins check that ChooserActivity.onCreate reads the file and
# asks SupportEnd.line between the OTA banner and the profile field, with the build from ro.build.version.incremental,
# today in UTC and a MUTED line that is GONE when there is nothing to say; that ProfileActivity.showConfirm does the
# same under its identity header; and that neither reads through a thread or the daemon.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-support-end-java.sh            # the cases + source pins
#   bash test-support-end-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SE="$SRC/SupportEnd.java"
ACT="$SRC/ChooserActivity.java"
PROF="$SRC/ProfileActivity.java"
CASES="$root/core/chooser/tests/support-end/SupportEndCases.java"
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
command -v perl >/dev/null 2>&1 || { echo "FAIL: this suite needs perl, and there is none" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: this suite needs python3, and there is none" >&2; exit 2; }
[ -f "$SE" ] && [ -f "$ACT" ] && [ -f "$PROF" ] && [ -f "$CASES" ] || {
  echo "FAIL: missing $SE, $ACT, $PROF or $CASES" >&2; exit 2; }

cat >"$W/pins.py" <<'PY'
import sys
act = open(sys.argv[1]).read()
prof = open(sys.argv[2]).read()

def strip(t):
    # drop comments, keeping string literals (a "//" inside a string is not a comment)
    out, i, n = [], 0, len(t)
    while i < n:
        c = t[i]
        if c == '"' or c == "'":
            j = i + 1
            while j < n and t[j] != c:
                j += 2 if t[j] == '\\' else 1
            out.append(t[i:j + 1]); i = j + 1
        elif t.startswith("//", i):
            j = t.find("\n", i); i = n if j < 0 else j
        elif t.startswith("/*", i):
            j = t.find("*/", i + 2); i = n if j < 0 else j + 2
        else:
            out.append(c); i += 1
    return "".join(out)

def close(t, o):
    # index of the brace that closes the one at o, skipping string literals
    d, i, n = 0, o, len(t)
    while i < n:
        c = t[i]
        if c == '"' or c == "'":
            j = i + 1
            while j < n and t[j] != c:
                j += 2 if t[j] == '\\' else 1
            i = j + 1; continue
        if c == '{': d += 1
        elif c == '}':
            d -= 1
            if d == 0: return i
        i += 1
    return -1

def block(t, head):
    a = t.find(head)
    if a < 0: return None
    o = t.find("{", a)
    if o < 0: return None
    c = close(t, o)
    return None if c < 0 else (a, c + 1)

fails = []
def ok(cond, what):
    print(("  ok    " if cond else "  FAIL  ") + what)
    if not cond: fails.append(what)

PATH = '"/system/etc/nowhere/support-end"'
NOTHREAD = ("new Thread(", "DaemonSocket", "sendDaemon(", "runOnUiThread(")

# G: the gate, ChooserActivity.onCreate
s = strip(act)
ob = block(s, "protected void onCreate(Bundle b)")
if ob is None:
    ok(False, "ChooserActivity.onCreate's body is found")
else:
    o = s[ob[0]:ob[1]]
    a = o.find("ll.addView(otaBanner, otaLp);")
    p = o.find('profileField = field("profile", false);')
    ok(0 <= a < p, "control: onCreate holds ll.addView(otaBanner, otaLp); then profileField = field(\"profile\", false);")
    if 0 <= a < p:
        g = o[a:p]
        ok(g.count("SupportEnd.line(") == 1, "the gate calls SupportEnd.line once, between the OTA banner and the profile field")
        ok(g.count(PATH) == 1, "the gate reads " + PATH + " there")
        ok('sysProp("ro.build.version.incremental", "")' in g, "the gate names the build from ro.build.version.incremental")
        ok("java.time.LocalDate.now(java.time.ZoneOffset.UTC)" in g, "the gate takes today in UTC")
        ok(".setTextColor(MUTED);" in g, "the gate's line is MUTED")
        ok("TypedValue.COMPLEX_UNIT_SP, 13)" in g, "the gate's line is 13sp")
        ok(".bottomMargin = dp(16);" in g, "the gate's line has a dp(16) bottom margin")
        ok("== null ? View.GONE : View.VISIBLE" in g, "the gate's line is GONE when SupportEnd.line gives null")
        ok(not any(t in g for t in NOTHREAD), "the gate reads synchronously, with no thread and no daemon")
    ok(s.count("SupportEnd.line(") == 1, "ChooserActivity calls SupportEnd.line nowhere else")

# P: Profile, ProfileActivity.showConfirm
s = strip(prof)
sb = block(s, "private void showConfirm()")
if sb is None:
    ok(False, "ProfileActivity.showConfirm's body is found")
else:
    c = s[sb[0]:sb[1]]
    n = c.find("ll.addView(nameTv,")
    t = c.find("TextView status = new TextView(this);")
    ok(0 <= n < t, "control: showConfirm holds ll.addView(nameTv, ...) then TextView status")
    if 0 <= n < t:
        g = c[n:t]
        ok(g.count("SupportEnd.line(") == 1, "Profile calls SupportEnd.line once, right after the identity header")
        ok(g.count(PATH) == 1, "Profile reads " + PATH + " there")
        ok("android.os.Build.VERSION.INCREMENTAL" in g, "Profile names the build from Build.VERSION.INCREMENTAL")
        ok("java.time.LocalDate.now(java.time.ZoneOffset.UTC)" in g, "Profile takes today in UTC")
        ok(".setTextColor(MUTED);" in g, "Profile's line is MUTED")
        ok("if (supportEndLine != null)" in g, "Profile adds the line only when SupportEnd.line gives one")
        ok(not any(x in g for x in NOTHREAD), "Profile reads synchronously, with no thread and no daemon")
    ok(s.count("SupportEnd.line(") == 1, "ProfileActivity calls SupportEnd.line nowhere else")
sys.exit(1 if fails else 0)
PY

# suite <SupportEnd.java> <ChooserActivity.java> <ProfileActivity.java> -> 0 pass, 1 a case or a pin failed,
# 3 did not compile
suite() {
  local se="$1" act="$2" prof="$3" d rc=0
  d=$(mktemp -d -p "$W") || return 3
  "$JAVAC" -d "$d" "$se" "$CASES" >"$d/javac.log" 2>&1 || { cat "$d/javac.log"; return 3; }
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d" com.nowhere.chooser.SupportEndCases || rc=1
  python3 "$W/pins.py" "$act" "$prof" || rc=1
  return "$rc"
}

echo "== $SE + $ACT + $PROF"
suite "$SE" "$ACT" "$PROF"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAILED (rc=$rc)"; exit 1; }
echo "PASS"
[ "$MUTATE" = yes ] || exit 0

echo "== --mutate"
fails=0
mutant() { # mutant <label> <se|act|prof> <perl-expr>: the copy must FAIL its cases or pins (rc 1)
  local label="$1" which="$2" expr="$3" d s a p rc f orig
  d=$(mktemp -d -p "$W") || { fails=$((fails+1)); return; }
  mkdir -p "$d/src"; s="$d/src/SupportEnd.java"; a="$d/src/ChooserActivity.java"; p="$d/src/ProfileActivity.java"
  cp "$SE" "$s"; cp "$ACT" "$a"; cp "$PROF" "$p"
  case "$which" in
    se) f="$s"; orig="$SE" ;;
    act) f="$a"; orig="$ACT" ;;
    *) f="$p"; orig="$PROF" ;;
  esac
  if ! perl -0pi -e "$expr" "$f"; then echo "  ERROR     $label -- perl failed"; fails=$((fails+1)); return; fi
  if [ ! -s "$f" ] || cmp -s "$orig" "$f"; then echo "  INERT     $label -- the mutation changed nothing"; fails=$((fails+1)); return; fi
  suite "$s" "$a" "$p" >"$d/out" 2>&1; rc=$?
  case "$rc" in
    1) echo "  convicted $label" ;;
    0) echo "  SURVIVED  $label"; fails=$((fails+1)) ;;
    *) echo "  BROKEN    $label -- the mutant did not compile (rc=$rc)"; tail -5 "$d/out"; fails=$((fails+1)) ;;
  esac
}
mutant "S1 the comparison inverted" se 's/\.compareTo\(last\) > 0/.compareTo(last) < 0/g'
mutant "S2 a month compared as its first day" se 's/todayIso\.substring\(0, 7\)\.compareTo\(last\) > 0/todayIso.compareTo(last + "-01") > 0/'
mutant "S3 the build dropped from the line" se 's/"build " \+ b/"this build"/'
mutant "S4 the gate call removed" act 's/SupportEnd\.line\(supportEndText,\s*java\.time\.LocalDate\.now\(java\.time\.ZoneOffset\.UTC\)\.toString\(\),\s*sysProp\("ro\.build\.version\.incremental", ""\)\)/null/'
mutant "S5 the Profile call removed" prof 's/SupportEnd\.line\(supportEndText,\s*java\.time\.LocalDate\.now\(java\.time\.ZoneOffset\.UTC\)\.toString\(\), android\.os\.Build\.VERSION\.INCREMENTAL\)/null/'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
