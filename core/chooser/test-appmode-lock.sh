#!/usr/bin/env bash
# test-appmode-lock.sh [<ProfileActivity.java>] [--mutate] -- setAppModeLocked's read of the keep-set and its
# write of the keep-set sit inside ONE synchronized(StoreInstaller.APPKEEP_LOCK) block, and no block on that lock,
# anywhere in the chooser, reaches setAppMode, the plan gate, or a socket.
#
# WHY THIS IS COMMITTED. setAppMode is the single funnel every keep-mode edit passes through: its locked edit
# (setAppModeLocked, since NWP-20260925-03) reads the whole keep-set into a map, edits it (the toggle, the
# play-deps bookkeeping, the Play-stack reconcile), and ends in writeAppModes, which RE-EMITS EVERY LINE from that
# map. Until NWP-20260904-13 only the write held the lock. Any removal that landed between the read and the
# write -- the logoff prune, the PACKAGE_REMOVED path (NWP-20260904-06), the login-time phantom reconcile thread
# (NWP-20260904-07, which runs ~15-45 s after every login, so the window is live in ordinary use), or a second
# toggle on another thread -- was silently re-emitted: a lost update on the ONE file that says what the user
# chose to roam. The fix is a lock, and a lock is the kind of thing a later edit moves one line without
# noticing, so its extent is pinned here.
#
# WHAT IS PINNED, all in FUNCTIONAL form (never comment text):
#   * the `synchronized (StoreInstaller.APPKEEP_LOCK) {` line in setAppModeLocked comes BEFORE the
#     readAppModesStrictIn(getFilesDir()) call (NWP-20261112-03; readAppModes() before it), and the `return writeAppModes(m, overPlanNow);` is still inside that block (brace depth
#     never returns to the block's opening depth between the two) -- so no removal can land between the read and
#     the write;
#   * the block closes before the method does (a `synchronized` that swallowed the next method would still
#     pass the first check and would not compile);
#   * the removers this serializes against still take the same lock: StoreInstaller.removeKeepLines (the
#     logoff prune and the reconcile both delegate to it) and writeAppModes itself (reentrant nesting);
#   * NWP-20260925-03: the plan gate (overPlan -> GET-ENTITLEMENT, a daemon and gateway round trip) is NEVER
#     called under the lock. Under it, it froze Profile on lynx 2026092603: the UI thread waited on this lock
#     while the gate waited on a network that could not reach the gateway. The locked edit is now
#     setAppModeLocked; setAppMode is a lock-free wrapper that asks the gate between two passes of it, and
#     writeAppModes returns null -- BEFORE it writes the keep-set -- when an add still needs the answer. Pinned:
#     setAppMode's statements token for token, whitespace aside (the null start, the locked pass, the exit on a
#     non-null result, then the ask), which convicts an endless loop, a gate asked on every edit and a discarded
#     answer alike; one road for the verdict at both hops -- setAppModeLocked used only by setAppMode, and
#     writeAppModes only by `return writeAppModes(m, overPlanNow);` in setAppModeLocked (calls and method
#     references counted); writeAppModes' exact early return and refusal, from the `added` set down, with nothing
#     below setAppMode assigning the verdict; and that NO synchronized block on APPKEEP_LOCK anywhere in the
#     chooser reaches setAppMode, the
#     gate, or a socket or network call (new LocalSocket, LocalSocketAddress, java.net sockets, openConnection /
#     openStream, socket channels, InetAddress lookups). "Reaches" is a call graph built from source across every
#     class in the chooser, nested ones included, rooted at the body of every such block. A lock is recognised
#     through whitespace and parentheses anywhere in its expression, qualified or not, by an alias assigned from
#     it in any class, or by a method whose whole body returns it. Bare and `this.` calls resolve within their
#     class, `Class.method(` (a nested class too) across classes, method references (`this::m`, `Class::m`)
#     likewise, `new X(` / `new Outer.X(` to X's constructors and to X's field initialisers and initialiser
#     blocks, top-level or nested (its own member declarations blanked; an anonymous class written inside an
#     initialiser stays in), all by name (overloads together, so it over-approximates; a record is a class, and a
#     nested name declared in several files is followed in all of them). No declaration -- with a body or, like an
#     interface or abstract method, without -- is read as a call. setAppMode and the gate are matched by NAME
#     wherever they are called under the lock, whatever the receiver. NOT followed: other
#     calls on another object's instance (`obj.m(`), functional values invoked through a parameter or a field
#     (`body.call()`, `gate.get()`), and anything outside the chooser's sources. A lambda or anonymous class
#     written inside a reached body counts as run under the lock even when it is handed to another thread: move
#     such work out of the block. The scan needs python and FAILS without it, and it carries four controls: the
#     synthetic lock shapes, the known lock holders and the known callees must be found, and the gate itself must
#     be seen to reach a socket.
#
# THE BRACE WALK SEES CODE ONLY. Comments AND string, char and text-block literals are stripped by a one-pass
# scanner (the methods are extracted by brace matching on that code, not by their neighbours) before a
# brace is counted or a line is matched: the review of NWP-20260904-13 showed the first cut counted a `}`
# inside a Log message as a block close (the suite failed on CORRECT code), and by the same arithmetic a `{`
# in a string would have hidden a block that really did close before the write (a false green). Both shapes
# are probed under --mutate: the first must PASS, the second must CONVICT.
#
#   bash test-appmode-lock.sh            # the invariants
#   bash test-appmode-lock.sh --mutate   # ... plus mutations that must each CONVICT the suite (and six
#                                        #     correct-code probes that must NOT)
#
# Source-level checks, same committed style as test-keepset-reconcile.sh -- the chooser has no unit-test
# harness. The SUT argument replaces ProfileActivity.java; StoreInstaller.java and every other chooser class are
# read from this script's own src/ tree, and LOCK_ST replaces StoreInstaller.java alone, so a mutation can target it.
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
HERE="$(dirname "$0")"
SUT="${SUT:-$HERE/src/com/nowhere/chooser/ProfileActivity.java}"
[ -f "$SUT" ] || { echo "no such file: $SUT" >&2; exit 2; }
ST="${LOCK_ST:-$HERE/src/com/nowhere/chooser/StoreInstaller.java}"
[ -f "$ST" ] || { echo "no such file: $ST" >&2; exit 2; }

PY=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c "pass" >/dev/null 2>&1; then PY=$c; break; fi
done
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
# ⚠ Every match below reads its input to the end: a here-string (`grep -q PAT <<<"$var"`) or
# `grep -c PAT >/dev/null` on a pipe, never `cmd | grep -q`. Under pipefail grep -q exits at its first match,
# the producer can die of SIGPIPE, and the pipeline fails: an absence check then passes on the code it exists
# to reject, a presence check goes red at random (docs/backlog.md, "pipes into grep -q under pipefail").

# codeonly: the same one-pass scanner as the brace walk below, printing each line reduced to CODE -- line and
# block comments dropped, string, char and text-block literals emptied -- so a match below can never be fooled by
# prose.
codeonly(){ awk -v SQ="'" '
  BEGIN { inblock=0; intext=0 }
  {
    code=""; n=length($0); i=1
    while (i<=n) {
      c=substr($0, i, 1); two=substr($0, i, 2)
      if (inblock) { if (two=="*/") { inblock=0; i+=2 } else i++; continue }
      if (intext) { if (substr($0, i, 3)=="\"\"\"") { intext=0; i+=3 } else i++; continue }
      if (two=="//") break
      if (two=="/*") { inblock=1; i+=2; continue }
      if (substr($0, i, 3)=="\"\"\"") { intext=1; i+=3; code=code "\"\""; continue }
      if (c=="\"" || c==SQ) {
        q=c; i++
        while (i<=n) { d=substr($0, i, 1); if (d=="\\") { i+=2; continue }; if (d==q) break; i++ }
        i++; code=code q q; continue
      }
      code=code c; i++
    }
    print code
  }'; }
# method <file> <signature-regex>: the method, code only, from its signature line to the brace that closes it --
# matched by brace, so moving a neighbour or inserting a helper changes nothing. Fails (rc 3) when unbalanced.
method(){ codeonly < "$1" | RE="$2" awk '
  !on && $0 ~ ENVIRON["RE"] { on=1 }
  on && !done { print; n=length($0); for (i=1;i<=n && !done;i++) { c=substr($0,i,1); if (c=="{") d++; else if (c=="}") { d--; if (d==0) done=1 } } }
  END { if (!done) exit 3 }'; }   # reads to EOF: an early exit would SIGPIPE codeonly and fail the pipeline
SAM=$(method "$SUT" 'private java.util.Set<String> setAppModeLocked\(String pkg, String mode, Boolean overPlanNow\) \{') &&
SAW=$(method "$SUT" 'private java.util.Set<String> setAppMode\(String pkg, String mode\) \{') &&
WAM=$(method "$SUT" 'private java.util.Set<String> writeAppModes\(java.util.Map<String,String> modes, Boolean overPlanNow\) \{') &&
RKL=$(method "$ST" 'static void removeKeepLines\(Context ctx, java.util.Set<String> drop\) \{') &&
[ -n "$SAM" ] && [ -n "$SAW" ] && [ -n "$WAM" ] && [ -n "$RKL" ] || { echo "EXTRACTION FAILED -- a method anchor moved, or its braces do not balance" >&2; exit 2; }
C_SAM=$SAM; C_SAW=$SAW; C_WAM=$WAM

# Walk setAppModeLocked's body with a brace counter. Each line is first reduced to CODE by a one-pass scanner that
# drops line comments, block comments and text blocks (across lines too) and the contents of string / char
# literals -- a `{` in prose and a `}` in a Log message must move nothing. Both the brace count and the line
# matches run on the reduced line, so a commented-out lock line does not match either.
# Prints: L_SYNC L_READ L_WRITE INSIDE CLOSED, where INSIDE=1 when the brace depth between the synchronized
# line and the write line never drops back to the depth the block was opened at, and CLOSED=1 when the block
# has closed again by the time the method's own closing brace is reached.
LOCKSCAN=$(printf '%s\n' "$SAM" | awk -v SQ="'" '
  BEGIN { depth=0; lsync=0; lread=0; lwrite=0; inside=1; opened=-1; closed=0; inblock=0; intext=0 }
  {
    code=""; n=length($0); i=1
    while (i<=n) {
      c=substr($0, i, 1); two=substr($0, i, 2)
      if (inblock) { if (two=="*/") { inblock=0; i+=2 } else i++; continue }
      if (intext) { if (substr($0, i, 3)=="\"\"\"") { intext=0; i+=3 } else i++; continue }
      if (two=="//") break                              # line comment: the rest is prose
      if (two=="/*") { inblock=1; i+=2; continue }      # block comment: prose until */
      if (substr($0, i, 3)=="\"\"\"") { intext=1; i+=3; code=code "\"\""; continue }   # text block: prose until the closing quotes
      if (c=="\"" || c==SQ) {                           # string / char literal: skip to the unescaped close
        q=c; i++
        while (i<=n) {
          d=substr($0, i, 1)
          if (d=="\\") { i+=2; continue }
          if (d==q) break
          i++
        }
        i++; code=code q q                              # the literal survives as an EMPTY one
        continue
      }
      code=code c; i++
    }
    if (lsync==0 && code ~ /synchronized \(StoreInstaller\.APPKEEP_LOCK\) \{/) { lsync=NR; opened=depth }
    if (lread==0 && code ~ /java\.util\.LinkedHashMap<String,String> m = readAppModesStrictIn\(getFilesDir\(\)\);/) lread=NR
    if (lwrite==0 && code ~ /return writeAppModes\(m, overPlanNow\);/) lwrite=NR
    k=length(code)
    for (j=1;j<=k;j++) {
      c=substr(code, j, 1)
      if (c=="{") depth++
      else if (c=="}") {
        depth--
        if (lsync>0 && lwrite==0 && depth==opened) inside=0   # the block closed before the write
        if (lsync>0 && lwrite>0 && closed==0 && depth==opened) closed=1
      }
    }
  }
  END { print lsync, lread, lwrite, inside, closed }')
set -- $LOCKSCAN; L_SYNC=$1; L_READ=$2; L_WRITE=$3; INSIDE=$4; CLOSED=$5

echo "== the read and the write share one lock block =="
if [ "$L_SYNC" -gt 0 ] && [ "$L_READ" -gt 0 ] && [ "$L_SYNC" -lt "$L_READ" ]; then
  ok "setAppModeLocked takes StoreInstaller.APPKEEP_LOCK BEFORE it reads the keep-set (readAppModesStrictIn)"
else
  no "the keep-set is read outside the lock -- a removal landing before the write is re-emitted (lost update)"
fi
if [ "$L_SYNC" -gt 0 ] && [ "$L_WRITE" -gt 0 ] && [ "$L_SYNC" -lt "$L_WRITE" ] && [ "$INSIDE" = 1 ]; then
  ok "... and the block is still open at the return writeAppModes(m, overPlanNow) line (brace depth never returned to the opening depth)"
else
  no "the lock block closes before writeAppModes -- the read-to-write span is unprotected again"
fi
if [ "$CLOSED" = 1 ]; then
  ok "the block closes inside setAppModeLocked (it does not swallow the method's end)"
else
  no "the synchronized block never closes before setAppModeLocked's own closing brace"
fi
if [ "$L_READ" -gt 0 ] && [ "$L_WRITE" -gt 0 ] && [ "$L_READ" -lt "$L_WRITE" ]; then
  ok "read precedes write (the map that is written is the one that was read under the lock)"
else
  no "readAppModesStrictIn / writeAppModes are out of order or missing in setAppModeLocked"
fi

echo "== the removers this serializes against still take the same lock =="
if grep -q 'synchronized (APPKEEP_LOCK) {' <<<"$RKL"; then
  ok "StoreInstaller.removeKeepLines (the logoff prune AND the login reconcile) holds APPKEEP_LOCK"
else
  no "StoreInstaller.removeKeepLines no longer holds APPKEEP_LOCK -- the lock in setAppModeLocked guards nothing"
fi
if grep -q 'synchronized (StoreInstaller.APPKEEP_LOCK) {' <<<"$WAM"; then
  ok "writeAppModes still holds APPKEEP_LOCK itself (inside setAppModeLocked, its only caller, it nests reentrantly)"
else
  no "writeAppModes dropped its own lock"
fi
if grep -q 'static final Object APPKEEP_LOCK = new Object();' "$ST"; then
  ok "APPKEEP_LOCK is one static monitor (the same object on every thread in the process)"
else
  no "APPKEEP_LOCK is not a single static monitor"
fi

echo "== the plan gate is asked OFF the lock (NWP-20260925-03) =="
if grep -q 'overPlan(' <<<"$C_SAM"; then
  no "setAppModeLocked calls overPlan() -- the gateway round trip is back under APPKEEP_LOCK (the Profile freeze)"
else
  ok "setAppModeLocked never calls overPlan() (code only, comments and literals stripped)"
fi
if grep -q 'overPlan(' <<<"$C_WAM"; then
  no "writeAppModes calls overPlan() -- the gateway round trip is back under APPKEEP_LOCK (the Profile freeze)"
else
  ok "writeAppModes never calls overPlan()"
fi
# setAppMode, token for token (whitespace dropped, code only): the verdict starts null; each pass runs the locked
# edit and leaves on a non-null result; only a pass that returned null is followed by the ask; the method holds no
# lock and does nothing else.
norm(){ tr -d ' \t\r' | grep -v '^$'; }
WANT_SAW='private java.util.Set<String> setAppMode(String pkg, String mode) {
Boolean overPlanNow = null;
for (;;) {
java.util.Set<String> dropped = setAppModeLocked(pkg, mode, overPlanNow);
if (dropped != null) return dropped;
overPlanNow = overPlan(pkg, mode);
}
}'
if [ "$(printf '%s\n' "$C_SAW" | norm)" = "$(printf '%s\n' "$WANT_SAW" | norm)" ]; then
  ok "setAppMode is the two-pass protocol statement for statement: null verdict, locked pass, exit on non-null, then the ask -- no lock, nothing else"
else
  no "setAppMode is not the two-pass protocol statement for statement (an endless loop, a gate asked on every edit, a discarded answer, or a lock)"
fi
L_NULL=$(printf '%s\n' "$C_WAM" | grep -nF 'if (!added.isEmpty() && overPlanNow == null) return null;' | head -1 | cut -d: -f1)
L_FW=$(printf '%s\n' "$C_WAM" | grep -nE 'new java\.io\.FileWriter\(|writeAtomic[[:space:]]*\(|\.renameTo[[:space:]]*\(|Files\.write' | head -1 | cut -d: -f1)
if [ -n "$L_NULL" ] && [ -n "$L_FW" ] && [ "$L_NULL" -lt "$L_FW" ]; then
  ok "writeAppModes returns null for a verdict-less add BEFORE its first write (pass one writes no keep-set line)"
else
  no "writeAppModes' verdict-less return is missing or comes after a write -- pass one could write, then run again"
fi
# The gate's answer must reach the refusal unchanged: nothing below setAppMode assigns the verdict (the pattern
# carries a control that must match), and writeAppModes' refusal is pinned statement for statement.
ASSIGN='overPlanNow[[:space:]]*=[^=]'
if ! grep -qE "$ASSIGN" <<<'x; overPlanNow = y;'; then
  no "the verdict-assignment pattern is broken (its control does not match) -- its silence would prove nothing"
elif printf '%s\n' "$C_SAM" "$C_WAM" | grep -cE "$ASSIGN" >/dev/null; then
  no "setAppModeLocked or writeAppModes assigns the verdict -- the gate's answer can be discarded below setAppMode"
else
  ok "nothing below setAppMode assigns the verdict (setAppModeLocked and writeAppModes only pass and read it)"
fi
# ... and the verdict has ONE road there, at both hops: writeAppModes' only use in the chooser is the pinned return
# in setAppModeLocked, and setAppModeLocked's only use is the pinned call in setAppMode (whose statements are pinned
# above). A use is a call or a method reference, declarations aside.
roads(){ for f in "$HERE"/src/com/nowhere/chooser/*.java; do
  case "$f" in */ProfileActivity.java) f="$SUT" ;; */StoreInstaller.java) f="$ST" ;; esac
  codeonly < "$f"; done | grep -v "$2" |
  grep -oE "(^|[^[:alnum:]_])$1[[:space:]]*\(|::[[:space:]]*$1([^[:alnum:]_]|\$)" | wc -l | tr -d ' '; }
CALLS=$(roads writeAppModes 'Set<String> writeAppModes(java.util.Map<String,String> modes, Boolean overPlanNow)')
LCALLS=$(roads setAppModeLocked 'Set<String> setAppModeLocked(String pkg, String mode, Boolean overPlanNow)')
if [ "$CALLS" = 1 ] && [ "$(printf '%s\n' "$C_SAM" | grep -cF 'return writeAppModes(m, overPlanNow);')" = 1 ] \
    && [ "$LCALLS" = 1 ] && [ "$(printf '%s\n' "$C_SAW" | grep -cF 'setAppModeLocked(pkg, mode, overPlanNow)')" = 1 ]; then
  ok "one road for the verdict: writeAppModes is used only by setAppModeLocked's pinned return, and setAppModeLocked only by setAppMode"
else
  no "writeAppModes is used $CALLS times and setAppModeLocked $LCALLS times, or not by the pinned calls -- a second road can carry a verdict that is not the gate's"
fi
WANT_REFUSE='java.util.LinkedHashMap<String,String> keptOnDisk = readAppModesStrictIn(getFilesDir());
if (keptOnDisk == null) {
android.util.Log.w("", "");
return KEEPSET_UNREADABLE;
}
java.util.Set<String> before = keptOnDisk.keySet();
java.util.List<String> added = new java.util.ArrayList<>();
for (String p : modes.keySet()) if (!before.contains(p)) added.add(p);
if (!added.isEmpty() && overPlanNow == null) return null;
if (!added.isEmpty() && overPlanNow) {
java.util.LinkedHashMap<String,String> kept = new java.util.LinkedHashMap<>(modes);
for (String p : added) kept.remove(p);
modes = kept;
dropped.addAll(added);
}'
N_WAM=$(printf '%s\n' "$C_WAM" | norm)
N_REFUSE=$(printf '%s\n' "$WANT_REFUSE" | norm)
case "$N_WAM" in
  *"$N_REFUSE"*) ok "writeAppModes refuses an over-plan add exactly as pinned: the added set against the keep-set on disk, the early return, then every added package dropped" ;;
  *) no "writeAppModes' refusal is not the pinned statements -- an over-plan add could pass, or every add be refused" ;;
esac
# Nothing run under APPKEEP_LOCK -- in ANY block on it, in any class -- may reach setAppMode, the plan gate, or a
# socket or network call. The set is a call graph built from source (the header says exactly what it follows),
# rooted at every such block, so a callee or a lock holder added later is covered the day it lands. Six results come
# back, each a check below; the first four are controls, because a scan that cannot see the lock's shapes, the known
# holders, the known callees or the gate's own socket proves nothing by its silence.
lockgraph(){ "$PY" - "$@" <<'PYEOF'
import io, os, re, sys

src_dir, sut, st = sys.argv[1], sys.argv[2], sys.argv[3]
files = {f[:-5]: os.path.join(src_dir, f) for f in sorted(os.listdir(src_dir)) if f.endswith(".java")}
files["ProfileActivity"], files["StoreInstaller"] = sut, st


def codeonly(t):
    # comments dropped and string, char and text-block literals emptied, newlines kept so line numbers hold
    out, i, n = [], 0, len(t)
    while i < n:
        two = t[i:i + 2]
        if two == "//":
            j = t.find("\n", i)
            i = n if j < 0 else j
            continue
        if two == "/*" or t.startswith('"""', i):
            close = "*/" if two == "/*" else '"""'
            j = t.find(close, i + len(close))
            e = n if j < 0 else j + len(close)
            out.append(("" if two == "/*" else '""') + "\n" * t.count("\n", i, e))
            i = e
            continue
        c = t[i]
        if c in "\"'":
            j = i + 1
            while j < n and t[j] != c and t[j] != "\n":
                j += 2 if t[j] == "\\" else 1
            out.append(c + c)
            i = j + 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def match_close(code, k, op="{", cl="}"):
    # the index of the bracket that closes the one at k
    d = 0
    for e in range(k, len(code)):
        if code[e] == op:
            d += 1
        elif code[e] == cl:
            d -= 1
            if d == 0:
                return e
    return len(code) - 1


KW = {"if", "for", "while", "switch", "catch", "synchronized", "return", "new", "else", "try", "do", "throw",
      "case", "assert", "super", "this"}
HDR = re.compile(r"(\w+)\s*\(([^()]|\([^()]*\))*\)\s*(throws\s+[\w.,\s]+)?$")
ANNOT = re.compile(r"@[\w.]+(\s*\(([^()]|\([^()]*\))*\))?")
MODS = re.compile(r"\b(public|protected|private|static|final|synchronized|abstract|native|default)\b")


def methods(code, decls=None):
    # every method and constructor declaration -- a header `name(...)` ending at a `{` -- with its body span; decls,
    # when given, collects each whole declaration (header and body). Annotations are stripped from the header first
    # (their arguments may hold `=`). A header with no return type whose name is capitalised is a constructor, of
    # the class so named (nested classes included); a record header is a type, not a method.
    meth, ctor = {}, {}
    for m in re.finditer(r"\{", code):
        k = m.start()
        j = max(code.rfind(";", 0, k), code.rfind("{", 0, k), code.rfind("}", 0, k))
        hdr = ANNOT.sub(" ", code[j + 1:k]).rstrip()
        h = HDR.search(hdr)
        if not h:
            continue
        name, pre = h.group(1), hdr[:h.start()]
        if name in KW or "=" in pre or re.search(r"\bnew\b", pre) or "." in hdr[max(0, h.start() - 1):h.start()]:
            continue
        if re.search(r"\brecord\s*$", pre):
            continue
        span = (k, match_close(code, k))
        if decls is not None:
            decls.append((j + 1, span[1]))
        if re.search(r"[\w>\]]\s+$", MODS.sub("", pre)):
            meth.setdefault(name, []).append(span)
        elif name[:1].isupper():
            ctor.setdefault(name, []).append(span)
    return meth, ctor


def classes(code, decls=None):
    # every class, interface, enum and record declared in the file, nested ones included, with its body span;
    # decls, when given, collects each whole declaration
    out = []
    for m in re.finditer(r"\b(?:class|interface|enum|record)\s+([A-Z]\w*)[^{;]*\{", code):
        k = m.end() - 1
        out.append((m.group(1), (k, match_close(code, k))))
        if decls is not None:
            decls.append((m.start(), out[-1][1][1]))
    return out


CODE = {cls: codeonly(io.open(p, encoding="utf-8").read()) for cls, p in files.items()}
M, CTOR, KLASS, DECL = {}, {}, {}, {}
for cls, code in CODE.items():
    DECL[cls] = []
    meth, ctor = methods(code, DECL[cls])
    M[cls] = meth
    for name, spans in ctor.items():
        CTOR.setdefault(name, []).extend((cls, sp) for sp in spans)
    for name, span in classes(code, DECL[cls]):
        KLASS.setdefault(name, []).append((cls, span))  # every declaration: nested names repeat across files


def init_text(cls, a, b):
    # a class body with its OWN member declarations (methods, constructors, nested types -- those at depth 1 of the
    # body) blanked, newlines kept: what runs when the class is constructed, its field initialisers and initialiser
    # blocks. An anonymous class written inside an initialiser is not a member, so its methods stay in.
    t = list(CODE[cls][a:b + 1])
    for s0, e0 in DECL[cls]:
        seg = CODE[cls][a:s0]
        if a < s0 and e0 < b and seg.count("{") - seg.count("}") == 1:
            for x in range(s0 - a, e0 - a + 1):
                if t[x] != "\n":
                    t[x] = " "
    return "".join(t)

BARE = re.compile(r"(?<![\w.$])(\w+)\s*\(")
QUAL = re.compile(r"\b([A-Z]\w*)\.(\w+)\s*\(")
THIS = re.compile(r"\bthis\.(\w+)\s*\(")
REF = re.compile(r"\b(this|super|[A-Z]\w*)\s*::\s*(\w+)")
NEW = re.compile(r"\bnew\s+(?:\w+\s*\.\s*)*([A-Z]\w*)\s*[(<]")
PRIM = re.compile(r"\bnew\s+(?:android\.net\.)?LocalSocket\s*\(|\bLocalSocketAddress\b"
                  r"|\bnew\s+(?:java\.net\.)?(?:Socket|DatagramSocket|ServerSocket)\s*\("
                  r"|\.openConnection\s*\(|\.openStream\s*\(|\bcreateSocket\s*\(|\b(?:Socket|Datagram)Channel\s*\.\s*open\s*\("
                  r"|\bHttps?URLConnection\b|\bInetAddress\s*\.\s*(?:get(?:All)?By\w+|getLocalHost)\s*\(")
NAMED = re.compile(r"(?<![\w$])(?:setAppMode|overPlan)\s*\(|::\s*(?:setAppMode|overPlan)\b")


def owners(name):
    # the files a class name belongs to: itself when it is a file, else every file that declares it
    if name in M:
        return [name]
    return sorted({c for c, _ in KLASS.get(name, [])})


def is_decl(body, m):
    # a `name(...)` followed by `{` (or throws) is a declaration -- an anonymous class's method, say -- not a call;
    # so is a bodiless one followed by `;` whose statement, modifiers and annotations aside, is EXACTLY a type and
    # the name (`void run();` in an interface, an abstract method). Merely ending like a type is not enough: a
    # switch rule's `->`, a comparison's `>` or a keyword (`return f();`) before a call must leave it a call
    j = match_close(body, m.end() - 1, "(", ")")
    after = body[j + 1:j + 200]
    if re.match(r"\s*(throws\s+[\w.,\s]+)?\{", after):
        return True
    if not re.match(r"\s*(throws\s+[\w.,\s]+)?;", after):
        return False
    k = max(body.rfind(";", 0, m.start()), body.rfind("{", 0, m.start()), body.rfind("}", 0, m.start()))
    pre = MODS.sub("", ANNOT.sub(" ", body[k + 1:m.start()]))
    typ = r"\s*(<[^;{}()=]*>\s*)?[\w$]+(\s*\.\s*[\w$]+)*\s*(<[^;{}()=]*>)?\s*(\[\s*\]\s*)*\s"
    return (re.fullmatch(typ, pre) is not None
            and not re.search(r"\b(return|throw|new|else|case|yield|do|assert)\s*$", pre))


def text(node):
    if node[0] == "m":
        return [CODE[node[1]][a:b + 1] for a, b in M[node[1]][node[2]]]
    if node[0] == "c":
        return [CODE[c][a:b + 1] for c, (a, b) in CTOR[node[2]]]
    if node[0] == "k":
        return [init_text(c, a, b) for c, (a, b) in KLASS[node[2]]]
    return [node[2]]  # a lock block: ("l", cls, body, label)


def callees(node):
    out = set()
    homes = [node[1]] if node[0] in ("m", "l") else [c for c, _ in (CTOR if node[0] == "c" else KLASS)[node[2]]]
    for cls in set(homes):
        for body in text(node):
            for m in BARE.finditer(body):
                if (m.group(1) in M[cls] and not re.search(r"\bnew\s+$", body[max(0, m.start() - 8):m.start()])
                        and not is_decl(body, m)):
                    out.add(("m", cls, m.group(1)))
            for m in THIS.finditer(body):
                if m.group(1) in M[cls]:
                    out.add(("m", cls, m.group(1)))
            for m in QUAL.finditer(body):
                for o in owners(m.group(1)):
                    if m.group(2) in M[o]:
                        out.add(("m", o, m.group(2)))
            for m in REF.finditer(body):
                for o in ([cls] if m.group(1) in ("this", "super") else owners(m.group(1))):
                    if m.group(2) in M[o]:
                        out.add(("m", o, m.group(2)))
            for m in NEW.finditer(body):
                if m.group(1) in CTOR:
                    out.add(("c", None, m.group(1)))
                if m.group(1) in KLASS:
                    out.add(("k", None, m.group(1)))  # its field initialisers and initialiser blocks, top-level or nested
    return out


def label(node):
    if node[0] == "m":
        return "%s.%s" % (node[1], node[2])
    if node[0] == "c":
        return "new %s" % node[2]
    if node[0] == "k":
        return "class %s" % node[2]
    return node[3]


def closure(roots):
    parent = {r: None for r in roots}
    todo = list(roots)
    while todo:
        node = todo.pop()
        for c in callees(node):
            if c not in parent:
                parent[c] = node
                todo.append(c)
    return parent


def path(parent, node):
    out = []
    while node is not None:
        out.append(label(node))
        node = parent[node]
    return " > ".join(reversed(out))


def lock_names(codes):
    # the lock's names across the given sources: APPKEEP_LOCK, every variable or field assigned from it (aliases of
    # aliases too, in any class), and every method whose whole body returns one of them
    names = {"APPKEEP_LOCK"}
    while True:
        pat = r"\b(\w+)\s*=\s*(?:[\w.]*\.)?(?:%s)\s*;" % "|".join(sorted(names))
        more = {a for code in codes for a in re.findall(pat, code)} - names
        if not more:
            break
        names |= more
    acc = set()
    body = re.compile(r"^\{return(?:[\w.]*\.)?(?:%s);\}$" % "|".join(sorted(names)))
    for code in codes:
        meth, _ = methods(code)
        for name, spans in meth.items():
            if any(body.match(re.sub(r"\s", "", code[a:b + 1])) for a, b in spans):
                acc.add(name)
    return names, acc


def lock_blocks(code, names, acc):
    # every synchronized block whose lock expression -- whitespace and parentheses dropped, so `((X . L))`, a
    # qualifier on its own line and `X.lockOf()` all read plainly -- ends in one of the lock's names or accessors
    out = []
    for m in re.finditer(r"\bsynchronized\s*\(", code):
        i = m.end() - 1
        j = match_close(code, i, "(", ")")
        k = code.find("{", j)
        if k < 0 or code[j + 1:k].strip():
            continue
        expr = re.sub(r"\s", "", code[i + 1:j])
        while expr.startswith("(") and match_close(expr, 0, "(", ")") == len(expr) - 1:
            expr = expr[1:-1]  # redundant parentheses around the whole expression
        call = expr.endswith("()")
        tail = (expr[:-2] if call else expr).split(".")[-1]
        if (tail in acc) if call else (tail in names):
            out.append((k, code[k:match_close(code, k) + 1]))
    return out


def enclosing(cls, pos):
    best = None
    for name, spans in M[cls].items():
        for a, b in spans:
            if a <= pos <= b and (best is None or a > best[1]):
                best = (name, a)
    return best[0] if best else "?"


SYNTH_Y = """class Y {
  static final Object KEEP = StoreInstaller.APPKEEP_LOCK;
  static Object keepLock() { return APPKEEP_LOCK; }
}"""
SYNTH = """class X {
  void a() { synchronized (StoreInstaller.APPKEEP_LOCK) { f(); } }
  void b() { synchronized(APPKEEP_LOCK){ f(); } }
  void c() { synchronized (
      StoreInstaller.APPKEEP_LOCK
  ) { f(); } }
  void d() { synchronized (StoreInstaller
      .APPKEEP_LOCK) { f(); } }
  void e() { synchronized ((StoreInstaller.APPKEEP_LOCK)) { f(); } }
  void g() { synchronized (com.nowhere.chooser.StoreInstaller.APPKEEP_LOCK) { f(); } }
  void h() { final Object k = StoreInstaller.APPKEEP_LOCK; synchronized (k) { f(); } }
  void i() { synchronized (Y.KEEP) { f(); } }
  void j() { synchronized (Y.keepLock()) { f(); } }
  void n() { synchronized (other) { f(); } }
  synchronized void o() { f(); }
}"""

res = {}
sn, sa = lock_names([SYNTH, SYNTH_Y])
seen = len(lock_blocks(SYNTH, sn, sa))
res["SHAPES"] = (seen == 9, "control: the lock finder sees %d of 9 synthetic lock shapes (spaced, unspaced, wrapped "
                 "inside the parentheses or at the dot, parenthesised, qualified, a local alias, another class's "
                 "alias, an accessor) and neither non-lock" % seen)
names, acc = lock_names(list(CODE.values()))
roots, where = [], []
for cls, code in CODE.items():
    for pos, body in lock_blocks(code, names, acc):
        line = code.count("\n", 0, pos) + 1
        where.append((cls, enclosing(cls, pos)))
        roots.append(("l", cls, body, "%s.%s{APPKEEP_LOCK@%d}" % (cls, enclosing(cls, pos), line)))
need_holders = [("ProfileActivity", "setAppModeLocked"), ("ProfileActivity", "writeAppModes"), ("StoreInstaller", "removeKeepLines")]
lost_h = ["%s.%s" % h for h in need_holders if h not in where]
res["HOLDERS"] = (not lost_h, "control: %d APPKEEP_LOCK blocks found in %d classes, the known holders among them"
                  % (len(roots), len({c for c, _ in where})) if not lost_h else
                  "no lock block found in %s -- renamed or removed on purpose? then update this list; otherwise the "
                  "lock finder broke" % ", ".join(lost_h))
under = closure(roots)
need = [("m", "ProfileActivity", n) for n in ("writeAppModes", "reconcilePlayStack", "applyStackMember", "playDependent",
                                              "resolvableForKeep", "notePlaySeen", "playStackOrphanKnown", "setPlayDep")]
need += [("m", "StoreInstaller", "snapshotAppSeen"), ("m", "StoreInstaller", "recordTurnedOff")]
lost = [label(n) for n in need if n not in under]
res["CALLEES"] = (not lost, "control: %d methods reachable under the lock, the known callees among them"
                  % (len(under) - len(roots)) if not lost else
                  "known callee(s) %s no longer reached under the lock -- renamed or removed on purpose? then update "
                  "this list; otherwise the call graph broke" % ", ".join(lost))
gate = ("m", "ProfileActivity", "overPlan")
ghits = []
if "overPlan" in M.get("ProfileActivity", {}):
    gc = closure([gate])
    ghits = [path(gc, n) for n in gc if any(PRIM.search(b) for b in text(n))]
res["GATE"] = (bool(ghits), "control: the gate itself reaches a socket (%s)" % ghits[0] if ghits else
               "the gate (overPlan) is not seen to reach a socket -- renamed? then update this control; otherwise the "
               "socket detection broke")
bad = sorted({path(under, n) for n in under if any(NAMED.search(b) for b in text(n))})
res["SETAPPMODE"] = (not bad, "no APPKEEP_LOCK block reaches setAppMode or the gate, by any receiver or a method "
                     "reference" if not bad else "setAppMode or the gate named under APPKEEP_LOCK: " + "; ".join(bad))
sock = sorted({path(under, n) for n in under if any(PRIM.search(b) for b in text(n))})
res["SOCKETS"] = (not sock, "no APPKEEP_LOCK block reaches a daemon socket or a network call" if not sock else
                  "reachable under APPKEEP_LOCK and opening a socket or connection: " + "; ".join(sock))
for k in ("SHAPES", "HOLDERS", "CALLEES", "GATE", "SETAPPMODE", "SOCKETS"):
    print("%s %s %s" % (k, "ok" if res[k][0] else "FAIL", res[k][1]))
PYEOF
}
if [ -z "$PY" ]; then
  no "the lock scan did not run: no working python -- a check that cannot run is not a pass"
else
  LG=$(lockgraph "$HERE/src/com/nowhere/chooser" "$SUT" "$ST" 2>&1); LGRC=$?
  for key in SHAPES HOLDERS CALLEES GATE SETAPPMODE SOCKETS; do
    line=$(printf '%s\n' "$LG" | grep -m1 "^$key ")
    case "$line" in
      "$key ok "*)   ok "${line#"$key ok "}" ;;
      "$key FAIL "*) no "${line#"$key FAIL "}" ;;
      *)             no "the lock scan returned no $key result (rc=$LGRC): $(printf '%s' "$LG" | tail -3 | tr '\n' ' ')" ;;
    esac
  done
fi

if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each MUST be convicted; the correct-code probes must NOT) =="
  M=$(mktemp -d)
  [ -n "$PY" ] || echo "  SKIP  mutations: no working python on PATH" >&2
  # probe <convict|pass> <label> <python-on-s> [which]   which = SUT (default) | ST
  #   Each edit is r(old, new) or rs(pattern, repl): a missing anchor stops the probe as BROKEN, so a half-applied
  #   mutant can never be counted.
  #   convict: the edited file is BROKEN and the suite must fail on it.
  #   pass:    the edited file is CORRECT (a shape the walk must see through) and the suite must still pass.
  probe_one(){
    local expect="$1" label="$2" py="$3" which="${4:-SUT}" src out rc
    [ -n "$PY" ] || { no "PROBE UNRUN (no python): $label"; return; }
    case "$which" in SUT) src="$SUT";; ST) src="$ST";; esac
    out="$M/$PN.$which.java"
    if ! "$PY" -c "
import io,sys,re
p,out=sys.argv[1],sys.argv[2]
s=io.open(p,encoding='utf-8',newline='').read()
def r(a,b):
    global s
    if a not in s: sys.exit('anchor not found: '+a[:70])
    s=s.replace(a,b,1)
def rs(pat,rep):
    global s
    s2,n=re.subn(pat,rep,s,count=1)
    if n!=1: sys.exit('pattern not found: '+pat[:70])
    s=s2
$py
io.open(out,'w',encoding='utf-8',newline=chr(10)).write(s)
" "$src" "$out"; then no "PROBE BROKEN: $label"; return; fi
    if cmp -s "$src" "$out"; then no "PROBE INERT: $label"; return; fi
    case "$which" in
      SUT) bash "$0" "$out" >/dev/null 2>&1; rc=$? ;;
      ST)  LOCK_ST="$out" bash "$0" "$SUT" >/dev/null 2>&1; rc=$? ;;
    esac
    case "$expect:$rc" in
      convict:0) no "NOT CONVICTED: $label -- suite passes on broken code" ;;
      convict:2) no "PROBE BROKEN: $label -- extraction failed on the edited file, that is not a conviction" ;;
      convict:*) ok "convicted: $label" ;;
      pass:0)    ok "not fooled: $label" ;;
      pass:*)    no "UNSOUND: $label -- the suite fails on CORRECT code (rc=$rc)" ;;
    esac
  }
  # Sequentially (the default) each verdict prints as it lands; with MUTJOBS > 1 that many probes run at once, their
  # lines are replayed in order at the end and counted into PASS/FAIL there (a background job cannot bump them).
  PN=0
  probe(){
    PN=$((PN + 1))
    if [ "${MUTJOBS:-1}" -gt 1 ]; then
      while [ "$(jobs -rp | wc -l)" -ge "$MUTJOBS" ]; do command sleep 0.2; done
      probe_one "$@" > "$M/$PN.res" &
    else
      probe_one "$@"
    fi
  }
  mutate(){ probe convict "$@"; }
  sound(){ probe pass "$@"; }
  # The pre-NWP-20260904-13 shape: the read sits above the synchronized line.
  mutate "the read moves outside the lock (the pre-fix shape: only the write is guarded)" \
    "r('      synchronized (StoreInstaller.APPKEEP_LOCK) {\n        java.util.LinkedHashMap<String,String> m = readAppModesStrictIn(getFilesDir());','        java.util.LinkedHashMap<String,String> m = readAppModesStrictIn(getFilesDir());\n      synchronized (StoreInstaller.APPKEEP_LOCK) {')"
  mutate "the lock is dropped from setAppModeLocked entirely" \
    "r('      synchronized (StoreInstaller.APPKEEP_LOCK) {\n        java.util.LinkedHashMap<String,String> m = readAppModesStrictIn(getFilesDir());','        java.util.LinkedHashMap<String,String> m = readAppModesStrictIn(getFilesDir());'); r('        return writeAppModes(m, overPlanNow); // #136: the caller surfaces any plan-gate drop where the tap happened; null = ask the gate\n      } // synchronized (StoreInstaller.APPKEEP_LOCK)','        return writeAppModes(m, overPlanNow); // #136: the caller surfaces any plan-gate drop where the tap happened; null = ask the gate')"
  mutate "the block closes before the write (the reconcile runs under the lock, the write does not)" \
    "r('        reconcilePlayStack(m, preKept);\n','        reconcilePlayStack(m, preKept);\n      } // synchronized (StoreInstaller.APPKEEP_LOCK)\n'); r('        return writeAppModes(m, overPlanNow); // #136: the caller surfaces any plan-gate drop where the tap happened; null = ask the gate\n      } // synchronized (StoreInstaller.APPKEEP_LOCK)','        return writeAppModes(m, overPlanNow); // #136: the caller surfaces any plan-gate drop where the tap happened; null = ask the gate')"
  mutate "the lock line survives only as a comment" \
    "r('      synchronized (StoreInstaller.APPKEEP_LOCK) {\n        java.util.LinkedHashMap<String,String> m = readAppModesStrictIn(getFilesDir());','      // synchronized (StoreInstaller.APPKEEP_LOCK) {\n        java.util.LinkedHashMap<String,String> m = readAppModesStrictIn(getFilesDir());'); r('        return writeAppModes(m, overPlanNow); // #136: the caller surfaces any plan-gate drop where the tap happened; null = ask the gate\n      } // synchronized (StoreInstaller.APPKEEP_LOCK)','        return writeAppModes(m, overPlanNow); // #136: the caller surfaces any plan-gate drop where the tap happened; null = ask the gate')"
  mutate "StoreInstaller.removeKeepLines drops its lock" \
    "rs(r'(static void removeKeepLines\(Context ctx, java\.util\.Set<String> drop\) \{\n        if \(drop == null \|\| drop\.isEmpty\(\)\) return;\n)        synchronized \(APPKEEP_LOCK\) \{', r'\1        {')" ST
  # NWP-20260925-03: the plan gate back under the lock, the two-pass protocol broken, and a correct-code probe.
  mutate "overPlan() asked inside writeAppModes again (the pre-fix freeze shape)" \
    "r('            if (!added.isEmpty() && overPlanNow == null) return null;','            if (!added.isEmpty() && overPlanNow == null) overPlanNow = overPlan();')"
  mutate "setAppMode takes APPKEEP_LOCK around the ask" \
    "r('        overPlanNow = overPlan(pkg, mode);','        synchronized (StoreInstaller.APPKEEP_LOCK) { overPlanNow = overPlan(pkg, mode); }')"
  mutate "writeAppModes loses its verdict-less early return" \
    "r('            if (!added.isEmpty() && overPlanNow == null) return null;\n','')"
  mutate "the ask removed from the loop (pass one returns null forever: an endless loop)" \
    "r('        overPlanNow = overPlan(pkg, mode);\n','')"
  mutate "the gate asked up front on every edit (the rev-1 shape)" \
    "r('      Boolean overPlanNow = null;','      Boolean overPlanNow = overPlan();')"
  mutate "the early return disabled (every add passes ungated)" \
    "r('            if (!added.isEmpty() && overPlanNow == null) return null;','            if (false && !added.isEmpty() && overPlanNow == null) return null;')"
  mutate "a caller takes APPKEEP_LOCK around setAppMode" \
    "r('                dropped = setAppMode(pkg, mode);','                synchronized (StoreInstaller.APPKEEP_LOCK) { dropped = setAppMode(pkg, mode); }')"
  mutate "a daemon call added inside a callee under the lock (reconcilePlayStack)" \
    "r('        java.util.Set<String> playClients = readPlayDeps(this);','        sendDaemon(\"PING\");\n        java.util.Set<String> playClients = readPlayDeps(this);')"
  # The rev-3 review's survivors: one-token endless loops, a gate asked on every edit, a discarded answer, daemon
  # calls the old hand-picked callee list and pattern missed, and an unspaced caller wrap.
  mutate "the exit test inverted (!= to ==): an edit that adds nothing loops forever, asking the gate each turn" \
    "r('        if (dropped != null) return dropped;','        if (dropped == null) return dropped;')"
  mutate "the exit removed: every edit loops forever" \
    "r('        if (dropped != null) return dropped;\n','')"
  mutate "the gate asked before the loop (every edit, removals included, pays the round trip)" \
    "r('      Boolean overPlanNow = null;\n      for (;;) {','      Boolean overPlanNow = null;\n      overPlanNow = overPlan();\n      for (;;) {')"
  mutate "the gate asked before each pass" \
    "r('      for (;;) {\n        java.util.Set<String> dropped','      for (;;) {\n        overPlanNow = overPlan();\n        java.util.Set<String> dropped')"
  mutate "the gate's answer discarded (every add passes ungated)" \
    "r('        overPlanNow = overPlan(pkg, mode);\n','        overPlanNow = overPlan(pkg, mode);\n        overPlanNow = Boolean.FALSE;\n')"
  mutate "a gate round trip in playDependent (a direct callee the old hand-picked list missed)" \
    "r('    private boolean playDependent(String pkg) {\n','    private boolean playDependent(String pkg) {\n        sendDaemonReply(\"GET-ENTITLEMENT\");\n')"
  mutate "sendDaemonMulti in reconcilePlayStack (a helper the old pattern did not match)" \
    "r('        java.util.Set<String> playClients = readPlayDeps(this);','        sendDaemonMulti(\"GET-ENTITLEMENT\");\n        java.util.Set<String> playClients = readPlayDeps(this);')"
  mutate "sealStatus() in reconcilePlayStack (a daemon round trip by another name)" \
    "r('        java.util.Set<String> playClients = readPlayDeps(this);','        sealStatus();\n        java.util.Set<String> playClients = readPlayDeps(this);')"
  mutate "StoreInstaller.snapshotAppSeen asks the daemon (a callee in another class)" \
    "r('    static void snapshotAppSeen(Context ctx, java.util.Set<String> presentPkgs) {\n','    static void snapshotAppSeen(Context ctx, java.util.Set<String> presentPkgs) {\n        DaemonSocket.roundTrip(\"PING\", 1000);\n')" ST
  mutate "a caller wraps setAppMode in an UNSPACED synchronized" \
    "r('                dropped = setAppMode(pkg, mode);','                synchronized(StoreInstaller.APPKEEP_LOCK){ dropped = setAppMode(pkg, mode); }')"
  # The rev-4 review's survivors: another lock holder, a one-hop wrapper, an aliased / wrapped / qualified lock, a
  # method reference, a constructor, a network call, an annotation with an argument, and the verdict discarded or
  # the refusal broken below setAppMode.
  mutate "the gate asked inside keepAutoImpl's lock (a holder other than setAppModeLocked)" \
    "r('                if (overPlan) return false;','                if (overPlan || DaemonSocket.roundTrip(\"GET-ENTITLEMENT\", 90000) != null) return false;')" ST
  mutate "a lock holder calls setAppMode through a one-hop wrapper" \
    "r('                dropped = setAppMode(pkg, mode);','                synchronized (StoreInstaller.APPKEEP_LOCK) { dropped = applyModeNow(pkg, mode); }'); r('    private boolean playDependent(String pkg) {\n','    private java.util.Set<String> applyModeNow(String p, String m) { return setAppMode(p, m); }\n\n    private boolean playDependent(String pkg) {\n')"
  mutate "the lock taken through a local alias" \
    "r('                dropped = setAppMode(pkg, mode);','                final Object keepLock = StoreInstaller.APPKEEP_LOCK;\n                synchronized (keepLock) { dropped = setAppMode(pkg, mode); }')"
  mutate "the lock wrapped inside its parentheses" \
    "r('                dropped = setAppMode(pkg, mode);','                synchronized (\n                        StoreInstaller.APPKEEP_LOCK) { dropped = setAppMode(pkg, mode); }')"
  mutate "the lock named fully qualified" \
    "r('                dropped = setAppMode(pkg, mode);','                synchronized (com.nowhere.chooser.StoreInstaller.APPKEEP_LOCK) { dropped = setAppMode(pkg, mode); }')"
  mutate "a daemon helper passed as a method reference (askText(this::sealStatus))" \
    "r('        java.util.Set<String> playClients = readPlayDeps(this);','        askText(this::sealStatus);\n        java.util.Set<String> playClients = readPlayDeps(this);'); r('    private boolean playDependent(String pkg) {\n','    private String askText(java.util.concurrent.Callable<String> q) { try { return q.call(); } catch (Exception e) { return null; } }\n\n    private boolean playDependent(String pkg) {\n')"
  mutate "a constructor that opens the daemon (new EntitlementCheck())" \
    "r('        java.util.Set<String> playClients = readPlayDeps(this);','        new EntitlementCheck();\n        java.util.Set<String> playClients = readPlayDeps(this);'); r('    private boolean playDependent(String pkg) {\n','    static final class EntitlementCheck { final String over; EntitlementCheck() { over = DaemonSocket.roundTrip(\"GET-ENTITLEMENT\", 90000); } }\n\n    private boolean playDependent(String pkg) {\n')"
  mutate "a network call under the lock (URL.openStream)" \
    "r('        java.util.Set<String> playClients = readPlayDeps(this);','        try { new java.net.URL(\"https://example.invalid/\").openStream().close(); } catch (Exception e) { }\n        java.util.Set<String> playClients = readPlayDeps(this);')"
  mutate "a daemon helper whose annotation takes an argument (value = ...)" \
    "r('    private String sealStatus() {','    @SuppressWarnings(value = \"resource\")\n    private String sealStatus() {'); r('        java.util.Set<String> playClients = readPlayDeps(this);','        sealStatus();\n        java.util.Set<String> playClients = readPlayDeps(this);')"
  mutate "the verdict defaulted below setAppMode (every add passes ungated)" \
    "r('        return writeAppModes(m, overPlanNow); // #136','        if (overPlanNow == null) overPlanNow = Boolean.FALSE;\n        return writeAppModes(m, overPlanNow); // #136')"
  mutate "the refusal disabled in writeAppModes" \
    "r('            if (!added.isEmpty() && overPlanNow) {','            if (!added.isEmpty() && overPlanNow && false) {')"
  mutate "the refusal inverted (every add refused while under plan)" \
    "r('            if (!added.isEmpty() && overPlanNow) {','            if (!added.isEmpty() && !overPlanNow) {')"
  # The rev-5 review's survivors: setAppMode through a reference, a nested class's static factory, a qualified
  # nested constructor with a field initialiser, a second writeAppModes road, the added set emptied, an accessor
  # lock, a lock wrapped at the dot or parenthesised, a text block hiding a daemon call, getAllByName.
  mutate "a lock holder calls setAppMode through a reference (a.setAppMode)" \
    "r('    private boolean playDependent(String pkg) {\n','    private static void applyModes(ProfileActivity a, java.util.Map<String,String> ms) {\n        synchronized (StoreInstaller.APPKEEP_LOCK) { for (java.util.Map.Entry<String,String> e : ms.entrySet()) a.setAppMode(e.getKey(), e.getValue()); }\n    }\n\n    private boolean playDependent(String pkg) {\n')"
  mutate "a nested class's static factory asks the daemon (PlanAsk.ask)" \
    "r('    private boolean playDependent(String pkg) {\n','    static final class PlanAsk { static String ask(String m) { return DaemonSocket.roundTrip(m, 90000); } }\n\n    private boolean playDependent(String pkg) {\n'); r('        java.util.Set<String> playClients = readPlayDeps(this);','        PlanAsk.ask(\"GET-ENTITLEMENT\");\n        java.util.Set<String> playClients = readPlayDeps(this);')"
  mutate "a qualified nested constructor whose field initialiser asks the daemon (new StoreInstaller.Probe())" \
    "r('    static void snapshotAppSeen(Context ctx, java.util.Set<String> presentPkgs) {\n','    static final class Probe { final String reply = DaemonSocket.roundTrip(\"PING\", 1000); }\n\n    static void snapshotAppSeen(Context ctx, java.util.Set<String> presentPkgs) {\n        new StoreInstaller.Probe();\n')" ST
  mutate "a second writeAppModes road that hands it a verdict the gate never gave" \
    "r('        return writeAppModes(m, overPlanNow); // #136','        if (MODE_AUTO.equals(mode)) return writeAppModes(m, Boolean.FALSE);\n        return writeAppModes(m, overPlanNow); // #136')"
  mutate "the added set computed against the new map (nothing is ever an add)" \
    "r('            java.util.Set<String> before = keptOnDisk.keySet();','            java.util.Set<String> before = modes.keySet();')"
  mutate "a daemon call under the lock taken through an accessor (synchronized (keepLock()))" \
    "r('    static void snapshotAppSeen(Context ctx, java.util.Set<String> presentPkgs) {\n','    static Object keepLock() { return APPKEEP_LOCK; }\n\n    static void pingUnderLock() { synchronized (keepLock()) { DaemonSocket.roundTrip(\"PING\", 1000); } }\n\n    static void snapshotAppSeen(Context ctx, java.util.Set<String> presentPkgs) {\n')" ST
  mutate "the lock wrapped at the qualifier's dot" \
    "r('                dropped = setAppMode(pkg, mode);','                synchronized (StoreInstaller\n                        .APPKEEP_LOCK) { dropped = setAppMode(pkg, mode); }')"
  mutate "the lock parenthesised" \
    "r('                dropped = setAppMode(pkg, mode);','                synchronized ((StoreInstaller.APPKEEP_LOCK)) { dropped = setAppMode(pkg, mode); }')"
  mutate "a text block whose brace hides a daemon call from the lock graph" \
    "r('    static void snapshotAppSeen(Context ctx, java.util.Set<String> presentPkgs) {\n        synchronized (APPKEEP_LOCK) {\n','    static void snapshotAppSeen(Context ctx, java.util.Set<String> presentPkgs) {\n        synchronized (APPKEEP_LOCK) {\n            String note = \"\"\"\n                }\n                \"\"\";\n            DaemonSocket.roundTrip(\"PING\", 1000);\n')" ST
  mutate "a DNS lookup under the lock (InetAddress.getAllByName)" \
    "r('    static void snapshotAppSeen(Context ctx, java.util.Set<String> presentPkgs) {\n        synchronized (APPKEEP_LOCK) {\n','    static void snapshotAppSeen(Context ctx, java.util.Set<String> presentPkgs) {\n        synchronized (APPKEEP_LOCK) {\n            try { java.net.InetAddress.getAllByName(\"api.nowhere.mobile\"); } catch (Exception e) { }\n')" ST
  sound "setAppModeLocked moved above setAppMode on CORRECT code (extraction follows braces, not neighbours)" \
    "i=s.index('    private java.util.Set<String> setAppMode(String pkg, String mode) {'); j=s.index('\n    }\n', i)+7; m=s[i:j]; s=s[:i]+s[j:]; k=s.index('    private void putAppMode('); s=s[:k]+m+'\n'+s[k:]"
  # The rev-6 and rev-7 reviews' survivors: a second road into setAppModeLocked (by call and by method reference),
  # the field initialiser of a class that is its own file, an anonymous class inside a field initialiser, a nested
  # record's static factory, a nested name another file also declares -- and correct-code probes for the false reds
  # the nested-class rule raised on an innocent task built under the lock (a JDK interface, a chooser one).
  mutate "a second setAppModeLocked road that hands it a verdict the gate never gave" \
    "r('                dropped = setAppMode(pkg, mode);','                dropped = setAppModeLocked(pkg, mode, Boolean.FALSE);')"
  mutate "a class that is its own file (new StoreInstaller()) whose field initialiser asks the daemon" \
    "r('    private StoreInstaller() {}','    private StoreInstaller() {}\n    private final String probe = DaemonSocket.roundTrip(\"PING\", 1000);'); r('    static void snapshotAppSeen(Context ctx, java.util.Set<String> presentPkgs) {\n        synchronized (APPKEEP_LOCK) {\n','    static void snapshotAppSeen(Context ctx, java.util.Set<String> presentPkgs) {\n        synchronized (APPKEEP_LOCK) {\n            new StoreInstaller();\n')" ST
  mutate "an anonymous class inside a field initialiser asks the daemon at construction" \
    "r('    private boolean playDependent(String pkg) {\n','    static final class Warm { final String reply = new Object() { String ask() { return DaemonSocket.roundTrip(\"GET-ENTITLEMENT\", 90000); } }.ask(); }\n\n    private boolean playDependent(String pkg) {\n'); r('        java.util.Set<String> playClients = readPlayDeps(this);','        new Warm();\n        java.util.Set<String> playClients = readPlayDeps(this);')"
  mutate "a second road into setAppModeLocked by method reference" \
    "r('    private boolean playDependent(String pkg) {\n','    interface Road { java.util.Set<String> go(String p, String m, Boolean v); }\n    private final Road road = this::setAppModeLocked;\n\n    private boolean playDependent(String pkg) {\n')"
  sound "an innocent task of a chooser-declared interface built under the lock on CORRECT code (a bodiless declaration is not a call)" \
    "r('    private boolean playDependent(String pkg) {\n','    interface Step { void run(); }\n\n    private boolean playDependent(String pkg) {\n'); r('        java.util.Set<String> playClients = readPlayDeps(this);','        Step later = new Step() { @Override public void run() { } };\n        java.util.Set<String> playClients = readPlayDeps(this);')"
  mutate "a nested record's static factory asks the daemon" \
    "r('    private boolean playDependent(String pkg) {\n','    record PlanReply(String reply) { static PlanReply ask(String m) { return new PlanReply(DaemonSocket.roundTrip(m, 90000)); } }\n\n    private boolean playDependent(String pkg) {\n'); r('        java.util.Set<String> playClients = readPlayDeps(this);','        PlanReply.ask(\"GET-ENTITLEMENT\");\n        java.util.Set<String> playClients = readPlayDeps(this);')"
  mutate "a nested class named like another file's (MmsPart) whose field initialiser asks the daemon" \
    "r('    private boolean playDependent(String pkg) {\n','    static final class MmsPart { final String reply = DaemonSocket.roundTrip(\"GET-ENTITLEMENT\", 90000); }\n\n    private boolean playDependent(String pkg) {\n'); r('        java.util.Set<String> playClients = readPlayDeps(this);','        new MmsPart();\n        java.util.Set<String> playClients = readPlayDeps(this);')"
  sound "an innocent nested task built under the lock on CORRECT code (a declaration is not a call)" \
    "r('    private boolean playDependent(String pkg) {\n','    static final class Later implements Runnable { @Override public void run() { } }\n\n    private boolean playDependent(String pkg) {\n'); r('        java.util.Set<String> playClients = readPlayDeps(this);','        Runnable later = new Later();\n        java.util.Set<String> playClients = readPlayDeps(this);')"
  # The rev-8 review: a bare call after `->` or a comparison is still a call, not a bodiless declaration.
  mutate "a daemon helper called from a switch rule (case 0 -> sealStatus())" \
    "r('        java.util.Set<String> playClients = readPlayDeps(this);','        switch (m.size()) { case 0 -> sealStatus(); default -> { } }\n        java.util.Set<String> playClients = readPlayDeps(this);')"
  mutate "a daemon helper's answer compared and returned (return n > budgetLeft())" \
    "r('    private boolean playDependent(String pkg) {\n','    private int budgetLeft() { return sealStatus() == null ? 0 : 1; }\n    private boolean overBudget(int n) { return n > budgetLeft(); }\n\n    private boolean playDependent(String pkg) {\n'); r('        java.util.Set<String> playClients = readPlayDeps(this);','        overBudget(1);\n        java.util.Set<String> playClients = readPlayDeps(this);')"
  mutate "a daemon helper in a returned lambda run under the lock (return () -> sealStatus())" \
    "r('    private boolean playDependent(String pkg) {\n','    private Runnable warmTask() { return () -> sealStatus(); }\n\n    private boolean playDependent(String pkg) {\n'); r('        java.util.Set<String> playClients = readPlayDeps(this);','        warmTask().run();\n        java.util.Set<String> playClients = readPlayDeps(this);')"
  sound "an interface with generic, array and throws declarations on CORRECT code (each is a declaration)" \
    "r('    private boolean playDependent(String pkg) {\n','    interface Names { @Deprecated <T> java.util.List<T>[] names(int n) throws Exception; String[] more(); }\n\n    private boolean playDependent(String pkg) {\n'); r('        java.util.Set<String> playClients = readPlayDeps(this);','        Names nm = null;\n        java.util.Set<String> playClients = readPlayDeps(this);')"
  sound "a comment naming overPlan() inside writeAppModes on CORRECT code" \
    "r('            if (!added.isEmpty() && overPlanNow == null) return null;','            // overPlan() is never called here\n            if (!added.isEmpty() && overPlanNow == null) return null;')"
  # The review's two string-literal shapes (NWP-20260904-13 fix round). The lock layout is CORRECT in the
  # first -- a `}` inside a Log message must not read as the block closing early; the first cut of this suite
  # failed 2 of 7 on exactly that. The second is the mirror and is BROKEN: a `{` inside a string used to raise
  # the depth by one, so the real close before the write never returned to the opening depth and the
  # unprotected span passed as protected. The third is the second in a text block (NWP-20260925-03).
  sound "a } inside a string literal on CORRECT code (the walk must see through literals)" \
    "r('        reconcilePlayStack(m, preKept);\n','        reconcilePlayStack(m, preKept);\n        android.util.Log.i(\"NowhereChooser\", \"brace } in a string\");\n')"
  mutate "a { inside a string literal masks a block that closes before the write" \
    "r('        reconcilePlayStack(m, preKept);\n','        reconcilePlayStack(m, preKept);\n        android.util.Log.i(\"NowhereChooser\", \"brace { in a string\");\n      } // synchronized (StoreInstaller.APPKEEP_LOCK)\n'); r('        return writeAppModes(m, overPlanNow); // #136: the caller surfaces any plan-gate drop where the tap happened; null = ask the gate\n      } // synchronized (StoreInstaller.APPKEEP_LOCK)','        return writeAppModes(m, overPlanNow); // #136: the caller surfaces any plan-gate drop where the tap happened; null = ask the gate')"
  mutate "a { inside a text block masks a block that closes before the write" \
    "r('        reconcilePlayStack(m, preKept);\n','        reconcilePlayStack(m, preKept);\n        android.util.Log.i(\"NowhereChooser\", \"\"\"\n            brace { in a text block\n            \"\"\");\n      } // synchronized (StoreInstaller.APPKEEP_LOCK)\n'); r('        return writeAppModes(m, overPlanNow); // #136: the caller surfaces any plan-gate drop where the tap happened; null = ask the gate\n      } // synchronized (StoreInstaller.APPKEEP_LOCK)','        return writeAppModes(m, overPlanNow); // #136: the caller surfaces any plan-gate drop where the tap happened; null = ask the gate')"
  wait
  if [ "${MUTJOBS:-1}" -gt 1 ]; then
    for i in $(seq 1 "$PN"); do
      cat "$M/$i.res"
      PASS=$((PASS + $(grep -c '^  ok ' "$M/$i.res")))
      FAIL=$((FAIL + $(grep -c '^  FAIL ' "$M/$i.res")))
    done
  fi
  rm -rf "$M"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
