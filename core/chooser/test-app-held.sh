#!/usr/bin/env bash
# test-app-held.sh [--mutate] -- the held-apps producer's file format, release floors and sign-out rule, run under
# javac (NWP-20261015-28).
#
# WHY THIS IS COMMITTED. AppHeld produces the list of apps this handset claims, which the seal publishes and the other
# handset suspends. Its rules are decisions in its own header (NWP-20260912-05), each device-debugged: a file stamped
# for another session reads as EMPTY; a release records a per-package MONOTONIC floor, converted at comparison as
# max(sessionFloor, nowWall - (nowElapsed - r)); releaseForSignOut empties the list WITHOUT moving the floor, so a
# refused sign-out can rebuild; a malformed #rel line is no floor, never a wrong one; and every non-package line is a
# `#` comment because the agent's fileHeldList publishes every other line. The rules are the Context-free statics
# between the "pure rules" markers in core/chooser/src/com/nowhere/chooser/AppHeld.java; they are compiled as they
# stand with core/chooser/tests/app-held/AppHeldCases.java. `m NowhereChooser` is the compile check of the rest.
#
# AN UNREADABLE LIST IS NOT AN ABSENT ONE (NWP-20261111-19). readText answers "" for an absent file and NULL for one
# that exists but cannot be read; read(Context) passes the null on, and refresh, release and releaseForSignOut return
# before their write on it, because the #rel release floors exist only in that file. Those branches are Android code,
# so check_source pins them on the comment-stripped source; it runs on AppHeld.java AND on every mutant copy.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-app-held.sh            # the cases
#   bash test-app-held.sh --mutate   # ... plus broken copies that must each FAIL them
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export W

here=$(cd "$(dirname "$0")" && pwd)
SRC="$here/src/com/nowhere/chooser/AppHeld.java"
RUN="$here/tests/app-held/run.sh"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip." >&2
  exit 1
fi
export JAVAC JAVA
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 1; }
for f in "$SRC" "$RUN" "$here/tests/app-held/AppHeldCases.java"; do [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }; done

# The source checks, as a python program in a file of its own (a heredoc inside a function cannot hold one cleanly).
# On the comment-stripped source: each of the three writers returns on a null read before its first `write(ctx,`,
# and read(Context) swallows nothing and reads through readText. Exit 1 when any check fails.
CHECK="$W/check-source.py"
cat > "$CHECK" <<'PY'
import re, sys

def strip(src):
    """Drop comments; keep string and char literals."""
    out = []; i = 0; n = len(src)
    while i < n:
        c = src[i]; d = src[i:i+2]
        if d == '//':
            while i < n and src[i] != '\n': i += 1
        elif d == '/*':
            j = src.find('*/', i + 2); i = n if j < 0 else j + 2; out.append(' ')
        elif c == '"' or c == "'":
            j = i + 1
            while j < n and src[j] != c:
                j += 2 if src[j] == '\\' else 1
            out.append(src[i:j+1]); i = j + 1
        else:
            out.append(c); i += 1
    return ''.join(out)

def blank(code):
    """The same text, same length, with every literal's contents spaced out, so a brace inside one is not counted."""
    return re.sub(r'"(?:[^"\\\n]|\\.)*"|\'(?:[^\'\\\n]|\\.)*\'', lambda m: m.group()[0] + ' ' * (len(m.group()) - 2) + m.group()[0], code)

code = strip(open(sys.argv[1]).read())
flat = blank(code)

def body(sig):
    i = code.find(sig)
    if i < 0 or code.find(sig, i + 1) >= 0:
        return None
    o = flat.find('{', i + len(sig))
    d = 0
    for j in range(o, len(flat)):
        if flat[j] == '{': d += 1
        elif flat[j] == '}':
            d -= 1
            if d == 0: return code[o:j+1]
    return None

bad = 0
def check(ok, what):
    global bad
    print(("  ok    " if ok else "  FAIL  ") + what)
    if not ok: bad = 1

NULL = re.compile(r'Held prev = read\(ctx\);\s*if \(prev == null\) \{\s*Log\.w\([^;]*\);\s*return;\s*\}')
for sig in ('static void refresh(Context ctx)', 'static void release(Context ctx, String only)',
            'static void releaseForSignOut(Context ctx)'):
    b = body(sig)
    if b is None:
        check(False, "source: %s is not found exactly once" % sig)
        continue
    m = NULL.search(b); w = b.find('write(ctx,')
    check(w >= 0, "source: %s writes the list" % sig)
    check(m is not None and 0 <= m.end() <= w, "source: %s returns on a null read before write(ctx," % sig)
b = body('private static Held read(Context ctx)')
check(b is not None, "source: read(Context) is found exactly once")
if b is not None:
    check('catch (Throwable ignore)' not in b, "source: read(Context) has no catch (Throwable ignore)")
    check('readText(file(ctx))' in b, "source: read(Context) reads through readText")
sys.exit(bad)
PY

# check_source <AppHeld.java>: the call sites are pinned, since a correct rule called wrongly is the same bug, and the
# source checks above run. Non-zero when any pin or check fails.
check_source() {
  local f="$1" body pin bad=0
  body=$(cat "$f")
  for pin in \
    'Held next = signOutOf(prev);' \
    'Held next = releaseOf(prev, only, SystemClock.elapsedRealtime());' \
    'long floorWall = floorWall(sessionFloor, rel.get(e.getKey()), nowWall, nowElapsed);' \
    'String text = readText(file(ctx));' \
    'return text == null ? null : parseHeld(text, stamp(ctx));' \
    'renderHeld(stamp(ctx), pkgs, released)'; do
    [[ "$body" == *"$pin"* ]] || { echo "  PIN   gone from AppHeld.java: $pin"; bad=1; }
  done
  python3 "$CHECK" "$f" || bad=1
  return $bad
}

src_out=$(check_source "$SRC" 2>&1); bad=$?
printf '%s\n' "$src_out"
out=$(bash "$RUN" "$SRC" 2>&1); rc=$?
printf '%s\n' "$out"
[ $rc -eq 0 ] && [ $bad -eq 0 ] || { echo "FAILED (cases rc=$rc, source checks bad=$bad)"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo
echo "== mutants: each must be convicted =="
TMP=$(mktemp -d -p "$W") || exit 2
miss=0
# mutant <label> <python3 replace: old> <new>: apply to a copy of AppHeld.java. CONVICTED only when the cases fail
# (run.sh exit 1) or a pin or source check fails. A copy that does not compile (3), has lost its markers (4), exits
# any other way, or a mutant that does not apply, is a FAILURE of the suite, never a conviction (NWP-20261111-19).
mutant() {
  local label="$1" old="$2" new="$3" m="$TMP/AppHeld.java" o rc sb
  if ! OLD="$old" NEW="$new" python3 - "$SRC" "$m" <<'PY'
import os, sys
s = open(sys.argv[1]).read()
if s.count(os.environ["OLD"]) != 1:
    sys.exit(1)
open(sys.argv[2], "w").write(s.replace(os.environ["OLD"], os.environ["NEW"]))
PY
  then echo "  FAIL  mutant did not apply: $label"; miss=1; return; fi
  sb=0; o=$(check_source "$m" 2>&1) || sb=1
  o=$(bash "$RUN" "$m" 2>&1); rc=$?
  case "$rc" in
    0) if [ $sb -eq 1 ]; then echo "  ok    convicted (source): $label"
       else echo "  FAIL  mutant SURVIVED: $label"; miss=1; fi ;;
    1) echo "  ok    convicted (cases): $label" ;;
    3|4) echo "  FAIL  mutant broke the build (run.sh rc=$rc), not a conviction: $label"; miss=1 ;;
    *) echo "  FAIL  unexpected run.sh rc=$rc: $label"; miss=1 ;;
  esac
}
mutant "sign-out clears the floors" \
  'return new Held(new java.util.ArrayList<String>(), prev.released, prev.stampMatched);' \
  'return new Held(new java.util.ArrayList<String>(), new java.util.HashMap<String, Long>(), prev.stampMatched);'
mutant "floorWall takes the earlier of the two" \
  ': Math.max(sessionFloorWall, nowWall - (nowElapsed - releasedElapsed));' \
  ': Math.min(sessionFloorWall, nowWall - (nowElapsed - releasedElapsed));'
mutant "the stamp check is removed" \
  'if (!matched) {' \
  'if (false) {'
mutant "release floors written without #" \
  'sb.append("#rel ").append(k)' \
  'sb.append("rel ").append(k)'
mutant "a malformed floor is read as a wrong one" \
  'if (bits.length == 2) {' \
  'if (bits.length >= 2) {'
mutant "a release does not record its floor" \
  'rel.put(pkg, nowElapsed);' \
  'rel.put(pkg, 0L);'
mutant "path separators are kept" \
  "if (ln.indexOf('/') < 0 && ln.indexOf('\\\\') < 0) pkgs.add(ln);" \
  'pkgs.add(ln);'
mutant "M1 readText reads an unreadable file as \"\"" \
  'return null; // exists but unreadable' \
  'return ""; // exists but unreadable'
mutant "M2 release's null branch falls through to write" \
  '                    return;
                }
                Held next = releaseOf(prev, only, SystemClock.elapsedRealtime());' \
  '                }
                Held next = releaseOf(prev, only, SystemClock.elapsedRealtime());'
mutant "M3 refresh's null branch falls through to write" \
  '                    return;
                }
                java.util.LinkedHashSet<String> held = new java.util.LinkedHashSet<>(prev.pkgs);' \
  '                }
                java.util.LinkedHashSet<String> held = new java.util.LinkedHashSet<>(prev.pkgs);'
mutant "M4 releaseForSignOut's null branch is removed" \
  '                if (prev == null) {
                    Log.w(TAG, "appheld: list unreadable -- keeping the previous file (NWP-20261111-19)");
                    return;
                }
                Held next = signOutOf(prev);' \
  '                Held next = signOutOf(prev);'
mutant "M5 read(Context) parses an unreadable file as empty" \
  'return text == null ? null : parseHeld(text, stamp(ctx));' \
  'return parseHeld(text == null ? "" : text, stamp(ctx));'
[ $miss -eq 0 ] || { echo "FAILED: a mutant was not convicted"; exit 1; }
echo PASS
