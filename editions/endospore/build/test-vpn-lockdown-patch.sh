#!/usr/bin/env bash
# test-vpn-lockdown-patch.sh [--mutate] -- NWP-20261026-21.
#
# WHY THIS IS COMMITTED. patches/vpn-lockdown-on-first-connect.sh (services.jar: VpnManagerService.java and
# connectivity/Vpn.java; NWP-20260925-02, the DECIDED "Block connections without VPN" armed at the first connection) is
# applied to every Endospore build by build-device.sh's glob and was executed by no suite. It is silent when wrong: an
# edit that loosens its REV check to the bare marker lets a tree carrying an OLDER cut report "already applied" in every
# later image -- the lockdown behaviour of the older cut ships while the record says rev 4 -- and a relaxed once() patches
# a moved anchor. Neither breaks a build; both surface when a user's traffic leaves outside the VPN.
# This runs the REAL script against synthetic trees whose two Java files are built from the script's OWN once() anchors
# (read out of its python heredoc, so a new or changed anchor is covered without editing this file) and pins:
#   (a) pristine -> exit 0, the REV marker in both files, every replacement present once in its file, and the literal
#       patch-markers.tsv names for this script (read from its row) present in VpnManagerService.java or Vpn.java;
#   (b) a re-run -> exit 0, `already applied (no change)`, both files byte-identical;
#   (c) an older cut (the marker in both files, REV in neither -- or in one only) -> exit 1, the revert command printed,
#       both files byte-identical;
#   (d) half-applied, VpnManagerService only (10) and Vpn.java only (01) -> exit 1 each, both byte-identical;
#   (e) for EACH anchor, missing and duplicated -> non-zero, BOTH files byte-identical (the script writes nothing until
#       every anchor has landed);
#   (f) either file missing -> exit 1.
# The older-cut and half-applied fixtures are made from a pair the REAL script applied, never from a mutant's output.
# Synthetic trees only: this cannot show that the anchors still match the real GrapheneOS tree; the build host checks that
# (patch-markers.tsv, docs/framework-patches.md). The script is a build-host bash script run as `bash "$p"`, so the cases
# run under bash only. python3 is needed, as the patch needs it.
#
#   bash test-vpn-lockdown-patch.sh            # the cases
#   bash test-vpn-lockdown-patch.sh --mutate   # ... plus four mutants of the script that must each CONVICT the suite
#     V1 REV check loosened to the marker   -> (c)      V2 the 01 arm removed          -> (d)
#     V3 once()'s `n != 1` -> `n < 1`        -> (e)      V4 each file written as soon as its first anchor lands -> (e)
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
command -v python3 >/dev/null || { echo "python3 not found: the patch needs it" >&2; exit 2; }
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
S0="$REPO/editions/endospore/build/patches/vpn-lockdown-on-first-connect.sh"
TSV="$REPO/editions/endospore/build/patch-markers.tsv"
F_REL=frameworks/base/services/core/java/com/android/server/VpnManagerService.java
V_REL=frameworks/base/services/core/java/com/android/server/connectivity/Vpn.java
X="$W/x"

cat >"$W/h.py" <<'PY'
import ast, io, os, re, sys

def die(msg, code=2):
    print("EXTRACTION FAILED: " + msg, file=sys.stderr)
    sys.exit(code)

def rd(p):
    return io.open(p, encoding="utf-8").read()

def wr(p, s):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    io.open(p, "w", encoding="utf-8", newline="\n").write(s)

def load(x):
    n = int(rd(x + "/n"))
    return [dict(i=i, path=rd("%s/%d.path" % (x, i)), anchor=rd("%s/%d.anchor" % (x, i)),
                 repl=rd("%s/%d.repl" % (x, i)), what=rd("%s/%d.what" % (x, i))) for i in range(1, n + 1)]

def extract(s0, tsv, x):
    src = rd(s0).split("\n")
    vals = {}
    for key in ("M", "REV"):
        c = [l for l in src if l.startswith(key + "=")]
        m = re.fullmatch(key + r'="([^"]+)"', c[0]) if len(c) == 1 else None
        if not m:
            die("no single %s=\"...\" line in the script" % key)
        vals[key] = m.group(1)
    if not vals["REV"].startswith(vals["M"]) or vals["REV"] == vals["M"]:
        die("REV is not a longer form of M")
    starts = [i for i, l in enumerate(src) if l.endswith("<<'PY'")]
    if len(starts) != 1:
        die("%d python heredocs in the script, need 1" % len(starts))
    ends = [i for i in range(starts[0] + 1, len(src)) if src[i] == "PY"]
    if not ends:
        die("the python heredoc is not closed")
    lines = src[starts[0] + 1:ends[0]]
    try:
        tree = ast.parse("\n".join(lines))
    except SyntaxError as e:
        die("the heredoc does not parse: %s" % e)
    calls = [n for n in ast.walk(tree) if isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id == "once"]
    top = [n.value for n in tree.body if isinstance(n, ast.Expr) and isinstance(n.value, ast.Call)
           and isinstance(n.value.func, ast.Name) and n.value.func.id == "once"]
    textual = len([l for l in lines if l.startswith("once(")])
    if not top or len(top) != len(calls) or len(top) != textual:
        die("once() calls: %d top-level, %d anywhere, %d at line start" % (len(top), len(calls), textual))
    os.makedirs(x)
    wr(x + "/M", vals["M"]); wr(x + "/REV", vals["REV"]); wr(x + "/n", str(len(top)))
    seen = set()
    for i, c in enumerate(top, 1):
        a = c.args
        if len(a) != 4 or c.keywords or not isinstance(a[0], ast.Name) or a[0].id not in ("fpath", "vpath") \
                or not all(isinstance(v, ast.Constant) and isinstance(v.value, str) for v in a[1:]):
            die("once() call %d is not (fpath|vpath, 'anchor', 'repl', 'what') literals" % i)
        if not a[1].value.endswith("\n") or not a[1].value.strip():
            die("anchor %d does not end in a newline" % i)
        seen.add(a[0].id)
        wr("%s/%d.path" % (x, i), "f" if a[0].id == "fpath" else "v")
        wr("%s/%d.anchor" % (x, i), a[1].value); wr("%s/%d.repl" % (x, i), a[2].value); wr("%s/%d.what" % (x, i), a[3].value)
    if seen != {"fpath", "vpath"}:
        die("anchors found for %s only" % sorted(seen))
    name = os.path.basename(s0)
    rows = []
    for l in rd(tsv).split("\n"):
        if l.strip() and not l.startswith("#"):
            c = l.split("\t")
            if c[0] == name:
                rows.append(c)
    if not rows:
        die("no patch-markers.tsv row for %s" % name)
    for c in rows:
        if len(c) != 4 or c[1] != "services.jar" or c[2] != "need" or not c[3].strip():
            die("patch-markers.tsv row %r is not <script> services.jar need <literal>" % c)
    wr(x + "/lits", "\n".join(c[3] for c in rows) + "\n")

def pkg(path):
    return "com.android.server" if path == "f" else "com.android.server.connectivity"

def tree(x, variant, d, f_rel, v_rel, k):
    an = load(x); M = rd(x + "/M")
    texts = {}
    for p in ("f", "v"):
        s = "package %s;\n\n" % pkg(p)
        for a in an:
            if a["path"] != p:
                continue
            t = a["anchor"]
            s += "// filler before %d\n" % a["i"]
            if a["i"] == k and variant == "missing":
                t = t.replace("\n", "/*drift*/\n", 1)
            s += t
            if a["i"] == k and variant == "dup":
                s += "// between\n" + t
            s += "// filler after %d\n" % a["i"]
        texts[p] = s
    for a in an:
        want = 0 if (variant == "missing" and a["i"] == k) else 2 if (variant == "dup" and a["i"] == k) else 1
        if texts[a["path"]].count(a["anchor"]) != want:
            die("fixture: anchor %d (%s) counts %d, wanted %d" % (a["i"], a["what"], texts[a["path"]].count(a["anchor"]), want))
    if any(M in t for t in texts.values()):
        die("fixture: the pristine tree already carries the marker")
    wr(os.path.join(d, f_rel), texts["f"]); wr(os.path.join(d, v_rel), texts["v"])

def older(x, src, dst, f_rel, v_rel, which):
    M, REV = rd(x + "/M"), rd(x + "/REV")
    for key, rel in (("f", f_rel), ("v", v_rel)):
        s = rd(os.path.join(src, rel))
        if key in which:
            s = s.replace(REV, M + " rev 0")
            if REV in s or M not in s:
                die("fixture: could not make an older cut of %s" % rel)
        wr(os.path.join(dst, rel), s)

def checka(x, d, f_rel, v_rel):
    an = load(x); REV = rd(x + "/REV")
    t = {"f": rd(os.path.join(d, f_rel)), "v": rd(os.path.join(d, v_rel))}
    bad = []
    for p in ("f", "v"):
        if REV not in t[p]:
            bad.append("REV missing from %s" % p)
    for a in an:
        n = t[a["path"]].count(a["repl"])
        if n != 1:
            bad.append("replacement %s present %d times" % (a["what"], n))
    for lit in rd(x + "/lits").split("\n"):
        if lit and lit not in t["f"] + t["v"]:
            bad.append("patch-markers.tsv literal %r absent" % lit)
    print("; ".join(bad))

MUT = {
    "V1": ('if grep -q "$REV" "$F" && grep -q "$REV" "$V"; then', 'if grep -q "$M" "$F" && grep -q "$M" "$V"; then'),
    "V2": ('if [ "$hf$hv" = 01 ]; then\n  echo "HALF-APPLIED (Vpn.java patched, VpnManagerService.java not) -- revert with: $REVERT ; then re-run" >&2; exit 1\nfi\n', ''),
    "V3": ("    if n != 1:\n", "    if n < 1:\n"),
    "V4": ("    files[path] = files[path].replace(anchor, repl, 1)\n",
           "    files[path] = files[path].replace(anchor, repl, 1)\n    io.open(path, 'w', encoding='utf-8', newline='\\n').write(files[path])\n"),
}

def mutate(name, src, dst):
    old, new = MUT[name]
    s = rd(src)
    if s.count(old) != 1:
        print("MUTANT DID NOT APPLY: %s anchor found %d times" % (name, s.count(old))); sys.exit(1)
    wr(dst, s.replace(old, new, 1))
    if rd(dst) == s:
        print("MUTANT CHANGED NOTHING: " + name); sys.exit(1)

cmd, a = sys.argv[1], sys.argv[2:]
if cmd == "extract": extract(*a)
elif cmd == "tree": tree(a[0], a[1], a[2], a[3], a[4], int(a[5]) if len(a) > 5 else 0)
elif cmd == "older": older(*a)
elif cmd == "checka": checka(*a)
elif cmd == "mutate": mutate(*a)
PY
py(){ python3 -I "$W/h.py" "$@"; }
python3 --version
py extract "$S0" "$TSV" "$X" || exit 2
N=$(cat "$X/n")
REV=$(cat "$X/REV")

FAILS=0
chk(){ if [ "$2" = 0 ]; then echo "ok $1"; else echo "FAIL $1${3:+ -- $3}"; FAILS=$((FAILS+1)); fi; }
has(){ [[ $1 == *"$2"* ]]; }
T=""
mk(){ T=$(mktemp -d -p "$W") && py tree "$X" "$1" "$T" "$F_REL" "$V_REL" "${2:-0}" || { echo "fixture build failed" >&2; exit 2; }; }
run_s(){ bash "$1" "$2" >"$2.out" 2>"$2.err"; RC=$?; OUT=$(cat "$2.out"); ERR=$(cat "$2.err"); }
snap(){ local t="$1" r; mkdir -p "$t.snap"; for r in "$F_REL" "$V_REL"; do [ -f "$t/$r" ] && { mkdir -p "$t.snap/$(dirname "$r")"; cp "$t/$r" "$t.snap/$r"; }; done; return 0; }
same(){ local t="$1" r; for r in "$F_REL" "$V_REL"; do if [ -f "$t.snap/$r" ]; then cmp -s "$t/$r" "$t.snap/$r" || return 1; fi; done; return 0; }
revert_for(){ echo "git -C $1/frameworks/base checkout -- services/core/java/com/android/server/VpnManagerService.java services/core/java/com/android/server/connectivity/Vpn.java"; }

# The applied pair every older-cut and half-applied fixture is made from: the REAL script's output, never a mutant's.
mk pristine; AP="$T"
run_s "$S0" "$AP"
if [ "$RC" != 0 ]; then echo "FAIL fixture: the real script did not apply to a pristine tree (rc $RC): $ERR" >&2; exit 1; fi

cases(){   # <script under test>
  local S="$1" k what v rv e A
  # (a) pristine
  mk pristine; A="$T"; snap "$A"; run_s "$S" "$A"
  [ "$RC" = 0 ]; chk "(a) pristine applies (exit 0)" $? "rc $RC: $ERR"
  e=$(py checka "$X" "$A" "$F_REL" "$V_REL"); [ -z "$e" ]; chk "(a) $REV in both files, every replacement once, the patch-markers.tsv literal present" $? "$e"
  # (b) re-run
  snap "$A"; run_s "$S" "$A"
  [ "$RC" = 0 ]; chk "(b) re-run exits 0" $? "rc $RC: $ERR"
  has "$OUT" "already applied (no change)"; chk "(b) re-run says already applied (no change)" $? "stdout: $OUT"
  same "$A"; chk "(b) re-run leaves both files byte-identical" $?
  # (c) an older cut, and REV in one file only
  for v in fv f v; do
    mk pristine; py older "$X" "$AP" "$T" "$F_REL" "$V_REL" "$v"; snap "$T"; run_s "$S" "$T"
    [ "$RC" = 1 ]; chk "(c) older cut ($v downgraded) exits 1" $? "rc $RC: $OUT $ERR"
    has "$ERR" "$(revert_for "$T")"; chk "(c) older cut ($v downgraded) prints the revert command" $? "stderr: $ERR"
    same "$T"; chk "(c) older cut ($v downgraded) leaves both files byte-identical" $?
  done
  # (d) half-applied
  for v in 10 01; do
    mk pristine
    if [ "$v" = 10 ]; then cp "$AP/$F_REL" "$T/$F_REL"; else cp "$AP/$V_REL" "$T/$V_REL"; fi
    snap "$T"; run_s "$S" "$T"
    [ "$RC" = 1 ]; chk "(d) half-applied $v exits 1" $? "rc $RC: $OUT $ERR"
    has "$ERR" "$(revert_for "$T")"; chk "(d) half-applied $v prints the revert command" $? "stderr: $ERR"
    same "$T"; chk "(d) half-applied $v leaves both files byte-identical" $?
  done
  # (e) every anchor: missing, duplicated
  for k in $(seq 1 "$N"); do
    what=$(cat "$X/$k.what")
    for v in missing dup; do
      mk "$v" "$k"; snap "$T"; run_s "$S" "$T"
      [ "$RC" != 0 ]; chk "(e) $v $what refused (non-zero)" $? "rc $RC: $OUT"
      same "$T"; chk "(e) $v $what leaves BOTH files byte-identical" $?
    done
  done
  # (f) either file missing
  for rv in "$F_REL" "$V_REL"; do
    mk pristine; rm -f "${T:?}/${rv:?}"; snap "$T"; run_s "$S" "$T"
    [ "$RC" = 1 ]; chk "(f) $(basename "$rv") missing exits 1" $? "rc $RC: $OUT $ERR"
    same "$T"; chk "(f) $(basename "$rv") missing leaves the other file byte-identical" $?
  done
}

if [ "$MUTATE" = no ]; then
  cases "$S0"
  if [ "$FAILS" != 0 ]; then echo "$FAILS check(s) failed"; exit 1; fi
  echo "all checks passed (synthetic trees; $N anchors read from the script)"
  exit 0
fi

R="$W/plain.out"; cases "$S0" >"$R"; cat "$R"
out=$(grep -c '^FAIL' "$R")
if [ "$out" != 0 ]; then echo "$out check(s) failed on the real script"; exit 1; fi
BAD=0
for pair in V1:c V2:d V3:e V4:e; do
  m=${pair%%:*}; c=${pair##*:}
  MS=$(mktemp -p "$W")
  if ! msg=$(py mutate "$m" "$S0" "$MS"); then echo "$msg"; BAD=$((BAD+1)); continue; fi
  MO="$W/$m.out"; cases "$MS" >"$MO"
  out=$'\n'$(cat "$MO")
  if has "$out" $'\nFAIL ('"$c"')'; then echo "CONVICTED $m by ($c)"; else echo "NOT CONVICTED $m (expected ($c))"; BAD=$((BAD+1)); fi
done
if [ "$BAD" != 0 ]; then echo "$BAD mutant(s) not convicted"; exit 1; fi
echo "all checks passed and every mutant convicted"
