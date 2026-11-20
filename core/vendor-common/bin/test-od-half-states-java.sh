#!/usr/bin/env bash
# test-od-half-states-java.sh [--mutate] -- NWP-20261204-14: every session issue report (through
# ProfileActivity.reportStatus) carries od_half, the reading Q056 (docs/product-decisions.md, 2026-10-20) takes before
# any per-app Repair: counts of the profile's Auto and on-demand apps with code and no confirmed restore (on-demand split
# by our own install) and the restore-only replies this chooser process saw answer ERR-NOTREADY. Counts only, never a
# name. Runs core/chooser/tests/od-half-states: the chooser's pure OdHalfStates, compiled against its cases ALONE and
# EXECUTED, plus source pins that reportStatus puts the key inside a Throwable try and that
# UnarchiveService.restoreOnlyReplied counts each ERR-NOTREADY reply.
#
# It needs a JDK, and it FAILS when there is none: a Java suite that skips without one would read green on a runner
# that never ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21. The pins need python3.
#
# --mutate re-runs the cases and the pins against broken copies of OdHalfStates.java, UnarchiveService.java and
# ProfileActivity.java, each of which must FAIL a named case or pin. A mutant that does not apply (INERT) or does not
# compile (BROKEN) counts as a failure, never a pass.
#
#   bash test-od-half-states-java.sh            # the cases and the pins
#   bash test-od-half-states-java.sh --mutate   # ... plus the mutants
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
  echo "test-od-half-states-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
command -v python3 >/dev/null 2>&1 || { echo "test-od-half-states-java: FAIL -- no python3 for the pins" >&2; exit 2; }
# ONE temp root: every class dir and mutant tree lives under it, and the EXIT trap removes it however this ends.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser
CASES=$ROOT/core/chooser/tests/od-half-states/OdHalfStatesCases.java

run() { # run <root>: compile <root>'s OdHalfStates.java with the cases ALONE and execute them
  local d
  d=$(mktemp -d -p "$W")
  "$JAVAC" -encoding UTF-8 -d "$d" "$1/$CH/OdHalfStates.java" "$CASES" || return 1
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d" com.nowhere.chooser.OdHalfStatesCases
}

pins() { # pins <root>: source checks over <root>'s ProfileActivity, UnarchiveService and OdHalfStates
  python3 -I -B - "$1" <<'PY'
import re
import sys

CH = "core/chooser/src/com/nowhere/chooser"


def strip(src):
    """Drop // and /* */ comments outside string and char literals, then collapse whitespace."""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if c in "\"'":
            j = i + 1
            while j < n and src[j] != c:
                j += 2 if src[j] == "\\" else 1
            out.append(src[i:j + 1])
            i = j + 1
        elif src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            i = n if j < 0 else j + 2
            out.append(" ")
        else:
            out.append(c)
            i += 1
    return re.sub(r"\s+", " ", "".join(out))


def match(s, o):
    """The index of the '}' that closes the '{' at o (-1 when unmatched)."""
    depth = 0
    for k in range(o, len(s)):
        if s[k] == "{":
            depth += 1
        elif s[k] == "}":
            depth -= 1
            if depth == 0:
                return k
    return -1


def block(s, anchor):
    """The brace-matched block whose '{' is the first after anchor ('' when the anchor is absent)."""
    a = s.find(anchor)
    if a < 0:
        return ""
    o = s.find("{", a + len(anchor) - 1)
    if o < 0:
        return ""
    k = match(s, o)
    return s[o:k + 1] if k >= 0 else ""


def read(root, name):
    with open(f"{root}/{CH}/{name}", encoding="utf-8") as f:
        return strip(f.read())


def main():
    root = sys.argv[1]
    pa = read(root, "ProfileActivity.java")
    us = read(root, "UnarchiveService.java")
    try:
        oh = read(root, "OdHalfStates.java")
    except OSError:
        oh = ""
    bad = 0

    def pin(name, ok, why):
        nonlocal bad
        if ok:
            print(f"ok   {name}")
        else:
            print(f"FAIL {name} -- {why}")
            bad = 1

    put = 'st.put("od_half", OdHalfStates.reportValue('
    rs = block(pa, "static org.json.JSONObject reportStatus(")
    at = rs.find(put)
    ret = rs.find("return st;")
    tb, why1 = "", ""
    if rs.count(put) != 1 or not (0 <= at < ret) or pa.count('"od_half"') != 1:
        why1 = (f"reportStatus holds {put!r} {rs.count(put)} time(s) (want 1, before return st;); the file holds "
                f"\"od_half\" {pa.count(chr(34) + 'od_half' + chr(34))} time(s)")
    else:
        t = rs.rfind("try {", 0, at)
        k = match(rs, t + 4) if t >= 0 else -1
        if t < 0 or k < at:
            why1 = "the put is not inside a try block"
        elif not rs[k + 1:].lstrip().startswith("catch (Throwable "):
            why1 = "the try around the put is not caught as Throwable: " + rs[k + 1:k + 40]
        else:
            tb = rs[t:k + 1]
            if "Log." in tb:
                why1 = "the od_half block logs"
    pin("p1 reportStatus puts od_half from OdHalfStates.reportValue inside a Throwable try", why1 == "", why1)

    need = ["UnarchiveService.hasInstalledCode(ctx, p)", "UnarchiveService.odRestored(ctx, p)", '"nowhere-appkeep"',
            '"nowhere-od-materialised"', "UnarchiveService.RESTORE_NOTREADY.get()", "ctx.getFilesDir()"]
    missing = [n for n in need if n not in tb]
    pin("p2 reportValue reads code, restored, materialised and RESTORE_NOTREADY", tb != "" and not missing,
        "no od_half try block" if tb == "" else f"the od_half block misses {missing}")

    inc = 'if (rr != null && rr.startsWith("ERR-NOTREADY")) RESTORE_NOTREADY.incrementAndGet();'
    ro = block(us, "private boolean restoreOnlyReplied(")
    pin("p3 restoreOnlyReplied counts ERR-NOTREADY replies",
        ro.count(inc) == 1 and us.count("RESTORE_NOTREADY.incrementAndGet()") == 1,
        f"restoreOnlyReplied holds {inc!r} {ro.count(inc)} time(s) (want 1); the file increments RESTORE_NOTREADY "
        f"{us.count('RESTORE_NOTREADY.incrementAndGet()')} time(s) (want 1)")

    decl = "static final java.util.concurrent.atomic.AtomicInteger RESTORE_NOTREADY ="
    pin("p4 RESTORE_NOTREADY is a static AtomicInteger", us.count(decl) == 1, f"UnarchiveService lacks {decl!r}")

    pin("p5 OdHalfStates modes match ProfileActivity",
        'MODE_ONDEMAND = "ondemand";' in pa and 'MODE_AUTO = "auto";' in pa
        and 'MODE_ONDEMAND = "ondemand";' in oh and 'MODE_AUTO = "auto";' in oh and "import android." not in oh
        and "android." not in oh,
        "the mode literals differ between ProfileActivity and OdHalfStates, OdHalfStates is absent, "
        "or it uses an Android type")
    sys.exit(bad)


main()
PY
}

# Both legs always run, so a red case does not hide a red pin.
rc=0
run "$ROOT" || rc=1
pins "$ROOT" || rc=1
[ "$rc" -eq 0 ] || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
SRCS="OdHalfStates.java UnarchiveService.java ProfileActivity.java"
mut() { # mut <label> <file under $CH> <perl-expr over it> <case or pin the mutant must fail>
  local d f out rc s
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/$CH"
  for s in $SRCS; do cp "$ROOT/$CH/$s" "$d/$CH/$s"; done
  f="$d/$CH/$2"
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed"; rm -rf "$d"; return 1; fi
  if cmp -s "$ROOT/$CH/$2" "$f"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  rc=0
  out=$(run "$d" 2>&1) || rc=1
  out+=$'\n'$(pins "$d" 2>&1) || rc=1
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if grep -qF -- "error:" <<<"$out"; then echo "  BROKEN    $1 -- it did not compile"; return 1; fi
  if ! grep -qF -- "FAIL $4" <<<"$out"; then
    echo "  BROKEN    $1 -- it failed, but not '$4'"; return 1
  fi
  echo "  convicted $1 (fails '$4')"
}
fails=0
mut "M1 auto ignores restored" OdHalfStates.java \
  's/if \(half\(pkg, code, restored\)\) a\+\+;/if (code.test(pkg)) a++;/' \
  "a2 a restored auto app does not count" || fails=$((fails+1))
mut "M2 ondemand_ours ignores materialised" OdHalfStates.java \
  's/if \(materialised != null && materialised\.contains\(pkg\)\) m\+\+;/m++;/' \
  "b2 an ondemand app not in materialised is not ours" || fails=$((fails+1))
mut "M3 first-tab-only split" OdHalfStates.java \
  's/line\.split\("\\t", -1\)/line.split("\\t", 2)/' \
  "d1 a group token keeps the ondemand mode" || fails=$((fails+1))
mut "M4 a bare line counted as auto" OdHalfStates.java \
  's/String mode = f\[1\]\.trim\(\);/String mode = f.length < 2 ? "auto" : f[1].trim();/; s/if \(f\.length < 2\) continue;//' \
  "c1 a bare line counts nowhere" || fails=$((fails+1))
mut "M5 dedupe removed" OdHalfStates.java \
  's/Set<String> ondemand = new LinkedHashSet<>\(\);/java.util.List<String> ondemand = new java.util.ArrayList<>();/' \
  "e1 a duplicate line counts once" || fails=$((fails+1))
mut "M6 mode compare swapped auto/ondemand" OdHalfStates.java \
  's/MODE_AUTO\.equals\(mode\)\) auto\.add/MODE_ONDEMAND.equals(mode)) auto.add/; s/MODE_ONDEMAND\.equals\(mode\)\) ondemand\.add/MODE_AUTO.equals(mode)) ondemand.add/' \
  "a1 auto with code and no restore counts" || fails=$((fails+1))
mut "M7 the reportStatus put removed" ProfileActivity.java \
  's/st\.put\("od_half", (OdHalfStates\.reportValue\()/String ignoreOd = $1/' \
  "p1 reportStatus puts od_half from OdHalfStates.reportValue inside a Throwable try" || fails=$((fails+1))
mut "M8 the increment removed" UnarchiveService.java \
  's/\n[ \t]*if \(rr != null && rr\.startsWith\("ERR-NOTREADY"\)\) RESTORE_NOTREADY\.incrementAndGet\(\);[^\n]*//' \
  "p3 restoreOnlyReplied counts ERR-NOTREADY replies" || fails=$((fails+1))
mut "M9 the increment moved out of the ERR-NOTREADY branch" UnarchiveService.java \
  's/if \(rr != null && rr\.startsWith\("ERR-NOTREADY"\)\) (RESTORE_NOTREADY\.incrementAndGet\(\);)/$1/' \
  "p3 restoreOnlyReplied counts ERR-NOTREADY replies" || fails=$((fails+1))
mut "M10 restored read for an app without code" OdHalfStates.java \
  's/return code\.test\(pkg\) && !restored\.test\(pkg\);/return !restored.test(pkg) && code.test(pkg);/' \
  "f1 restored is never read for an app without code" || fails=$((fails+1))
mut "M11 the od_half catch narrowed to Exception" ProfileActivity.java \
  's/(UnarchiveService\.RESTORE_NOTREADY\.get\(\)\)\);\n[ \t]*\} catch \()Throwable/${1}Exception/' \
  "p1 reportStatus puts od_half from OdHalfStates.reportValue inside a Throwable try" || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
