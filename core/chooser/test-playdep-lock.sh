#!/usr/bin/env bash
# test-playdep-lock.sh [<ProfileActivity.java>] [--mutate] -- no block on ProfileActivity.PLAYDEP_LOCK makes a
# PackageManager binder read, and notePlaySeen resolves the package's versionCode BEFORE it takes the lock.
#
# WHY THIS IS COMMITTED. PLAYDEP_LOCK WAS taken on the MAIN LOOPER (AppInstallReceiver is registered with no
# Handler, so its decide() -> keepInMode path ran on main); since NWP-20261029-19 that path runs on the receiver's
# serial worker. Its own comment still states the rule that keeps ANY main-thread taker ANR-safe: NO BINDER CALL is ever made while holding it, so the hold is bounded local I/O on two small files in
# the app's own dir. Until NWP-20261011-62 notePlaySeen broke that rule -- it called versionCodeOf, a
# PackageManager round trip into system_server, as the first statement INSIDE the lock -- and the next person to
# reason about the lock would have reasoned from the comment. The read now happens before the lock; a later edit
# that tidies it back inside would compile, run and pass every functional check, so its position is pinned here.
#
# WHAT IS PINNED, in code only (comments and string / char / text-block literals stripped first):
#   * notePlaySeen holds exactly one `synchronized (PLAYDEP_LOCK) {` block, and that block calls none of
#     versionCodeOf(, getPackageManager(, readsPlayServices(;
#   * notePlaySeen calls versionCodeOf exactly once, and the call and its `if (vc < 0) return;` guard both come
#     BEFORE the lock line -- so the determination is still keyed to a version, just read outside the hold;
#   * EVERY block on PLAYDEP_LOCK in every chooser source (ProfileActivity's setPlayDep today, and any added
#     later) calls none of the three either. Two controls keep that silence honest: the block finder must see at
#     least the two known holders (notePlaySeen, setPlayDep), and the call pattern must match a sample call.
# NOT followed: calls made by a method the block invokes. Today the blocks call only readPlaySeenStrict /
# readPlayDepsStrict (FileReader in the app's own dir); a helper that hides a binder read one level down is the reviewer's to catch.
#
#   bash test-playdep-lock.sh            # the invariants
#   bash test-playdep-lock.sh --mutate   # ... plus mutations that must each CONVICT the suite (and a correct-code
#                                        #     probe that must NOT)
#
# Source-level checks, same committed style as test-appmode-lock.sh -- the chooser has no unit-test harness. The
# SUT argument replaces ProfileActivity.java; every other chooser class is read from this script's own src/ tree.
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
HERE="$(dirname "$0")"
SRC="$HERE/src/com/nowhere/chooser"
SUT="${SUT:-$SRC/ProfileActivity.java}"
[ -f "$SUT" ] || { echo "no such file: $SUT" >&2; exit 2; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
# ⚠ Every match below reads its input to the end: a here-string (`grep -q PAT <<<"$var"`) or a count, never
# `cmd | grep -q`. Under pipefail grep -q exits at its first match, the producer can die of SIGPIPE, and the
# pipeline fails: an absence check then passes on the code it exists to reject (docs/backlog.md, "pipes into
# grep -q under pipefail").

# codeonly: each line reduced to CODE -- line and block comments dropped, string, char and text-block literals
# emptied -- so neither a match nor a brace count can be fooled by prose. Same scanner as test-appmode-lock.sh.
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
# method <file> <signature-regex>: the method, code only, from its signature line to the brace that closes it.
# Fails (rc 3) when the anchor is missing or its braces do not balance.
method(){ codeonly < "$1" | RE="$2" awk '
  !on && $0 ~ ENVIRON["RE"] { on=1 }
  on && !done { print; n=length($0); for (i=1;i<=n && !done;i++) { c=substr($0,i,1); if (c=="{") d++; else if (c=="}") { d--; if (d==0) done=1 } } }
  END { if (!done) exit 3 }'; }   # reads to EOF: an early exit would SIGPIPE codeonly and fail the pipeline
# lockblocks <label>: reads code-only text on stdin and prints every `synchronized (PLAYDEP_LOCK) {` block --
# qualified or not, any spacing -- from its opening brace to the brace that closes it, each preceded by a
# `@@BLOCK <label>:<line>` header line.
lockblocks(){ L="$1" awk '
  BEGIN { inb=0 }
  {
    s=$0
    if (!inb && match(s, /synchronized[[:space:]]*\([[:space:]]*(ProfileActivity[[:space:]]*\.[[:space:]]*)?PLAYDEP_LOCK[[:space:]]*\)[[:space:]]*\{/)) {
      print "@@BLOCK " ENVIRON["L"] ":" NR
      s=substr(s, RSTART + RLENGTH - 1); inb=1; d=0
    }
    if (!inb) next
    out=""; n=length(s)
    for (i=1;i<=n;i++) {
      c=substr(s,i,1); out=out c
      if (c=="{") d++
      else if (c=="}") { d--; if (d==0) { inb=0; break } }
    }
    print out
  }'; }

BAN='(^|[^[:alnum:]_$])(versionCodeOf|getPackageManager|readsPlayServices)[[:space:]]*\('

NPS=$(method "$SUT" 'static void notePlaySeen\(android\.content\.Context ctx, String pkg, boolean needsPlay\) \{') &&
[ -n "$NPS" ] || { echo "EXTRACTION FAILED -- notePlaySeen's anchor moved, or its braces do not balance" >&2; exit 2; }

echo "== controls =="
if grep -qE "$BAN" <<<'long vc = versionCodeOf(ctx, pkg); ctx.getPackageManager (); readsPlayServices(ctx, p);' \
    && ! grep -qE "$BAN" <<<'long vc = myversionCodeOf(ctx, pkg); readPlaySeen(ctx);'; then
  ok "the binder-call pattern matches a sample call of each banned name, and not a lookalike or a file read"
else
  no "the binder-call pattern is broken (its controls do not hold) -- its silence below would prove nothing"
fi
ALL=""
for f in "$SRC"/*.java; do
  case "$f" in */ProfileActivity.java) f="$SUT" ;; esac
  ALL+=$(codeonly < "$f" | lockblocks "$(basename "$f")")$'\n'
done
NBLK=$(grep -c '^@@BLOCK ' <<<"$ALL")
SPB=$(method "$SUT" 'static void setPlayDep\(android\.content\.Context ctx, String pkg, boolean on\) \{' | lockblocks x)
if [ "$NBLK" -ge 2 ] && grep -q '^@@BLOCK ' <<<"$SPB"; then
  ok "the block finder sees $NBLK PLAYDEP_LOCK block(s) across the chooser, setPlayDep's among them"
else
  no "the block finder sees $NBLK PLAYDEP_LOCK block(s) and/or misses setPlayDep's -- renamed on purpose? then update this control; otherwise the finder broke"
fi

echo "== notePlaySeen reads the version BEFORE the lock =="
NB=$(lockblocks notePlaySeen <<<"$NPS")
if [ "$(grep -c '^@@BLOCK ' <<<"$NB")" = 1 ]; then
  ok "notePlaySeen holds exactly one PLAYDEP_LOCK block (the read-modify-write of nowhere-playseen)"
else
  no "notePlaySeen holds $(grep -c '^@@BLOCK ' <<<"$NB") PLAYDEP_LOCK blocks, not one -- its write is unguarded or split"
fi
if grep -qE "$BAN" <<<"$NB"; then
  no "notePlaySeen makes a PackageManager binder call INSIDE PLAYDEP_LOCK -- the lock is taken on main and its rule says never"
else
  ok "notePlaySeen's lock block calls none of versionCodeOf / getPackageManager / readsPlayServices"
fi
L_LOCK=$(grep -nE 'synchronized[[:space:]]*\([[:space:]]*(ProfileActivity[[:space:]]*\.[[:space:]]*)?PLAYDEP_LOCK' <<<"$NPS" | head -1 | cut -d: -f1)
L_VC=$(grep -nE 'long vc = versionCodeOf\(ctx, pkg\);' <<<"$NPS" | head -1 | cut -d: -f1)
L_GUARD=$(grep -nF 'if (vc < 0) return;' <<<"$NPS" | head -1 | cut -d: -f1)
N_VC=$(grep -oE '(^|[^[:alnum:]_$])versionCodeOf[[:space:]]*\(' <<<"$NPS" | wc -l | tr -d ' ')
if [ -n "$L_LOCK" ] && [ -n "$L_VC" ] && [ -n "$L_GUARD" ] && [ "$L_VC" -lt "$L_GUARD" ] && [ "$L_GUARD" -lt "$L_LOCK" ] && [ "$N_VC" = 1 ]; then
  ok "notePlaySeen calls versionCodeOf once, and it and its vc < 0 guard precede the lock (the record stays keyed to a version)"
else
  no "notePlaySeen's versionCodeOf read / vc < 0 guard is missing, repeated ($N_VC calls), or not before the lock"
fi

echo "== no PLAYDEP_LOCK block anywhere in the chooser makes a binder call =="
# The pattern goes in through ENVIRON, not -v: -v processes escapes, turning `\(` into an unbalanced `(` that kills
# awk -- and a dead scan prints nothing, which would read as a pass. Its exit status is checked for the same reason.
HITS=$(BAN="$BAN" awk '/^@@BLOCK / { where=$2; next } $0 ~ ENVIRON["BAN"] { print where }' <<<"$ALL"); SCANRC=$?
HITS=$(sort -u <<<"$HITS" | tr '\n' ' '); HITS="${HITS%% }"
if [ "$SCANRC" != 0 ]; then
  no "the PLAYDEP_LOCK block scan did not run (awk rc=$SCANRC) -- a check that cannot run is not a pass"
elif [ -z "$HITS" ]; then
  ok "all $NBLK PLAYDEP_LOCK block(s) are free of versionCodeOf / getPackageManager / readsPlayServices"
else
  no "a PLAYDEP_LOCK block makes a PackageManager binder call: $HITS"
fi

if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each MUST be convicted; the correct-code probe must NOT) =="
  PY=""
  for c in python3 python; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c "pass" >/dev/null 2>&1; then PY=$c; break; fi
  done
  M=$(mktemp -d)
  # probe <convict|pass> <label> <python-on-s>: a missing anchor stops the probe as BROKEN, so a half-applied
  # mutant can never be counted.
  probe(){
    local expect="$1" label="$2" py="$3" out="$M/ProfileActivity.java" rc
    [ -n "$PY" ] || { no "PROBE UNRUN (no python): $label"; return; }
    if ! "$PY" -c "
import io,sys
p,out=sys.argv[1],sys.argv[2]
s=io.open(p,encoding='utf-8',newline='').read()
def r(a,b):
    global s
    if a not in s: sys.exit('anchor not found: '+a[:70])
    s=s.replace(a,b,1)
$py
io.open(out,'w',encoding='utf-8',newline=chr(10)).write(s)
" "$SUT" "$out"; then no "PROBE BROKEN: $label"; return; fi
    bash "$0" "$out" >/dev/null 2>&1; rc=$?
    case "$expect:$rc" in
      convict:0) no "NOT CONVICTED: $label" ;;
      convict:*) ok "convicted: $label" ;;
      pass:0)    ok "passes (correct code): $label" ;;
      pass:*)    no "FALSE CONVICTION on correct code: $label" ;;
    esac
  }
  # The pre-NWP-20261011-62 shape: the read back as the first statement inside the lock.
  probe convict "versionCodeOf moved back inside notePlaySeen's lock (the shape this slice fixed)" "
import re
s2,n=re.subn(r'(static void notePlaySeen\([^)]*\) \{\n)        long vc = versionCodeOf\(ctx, pkg\);[^\n]*\n        if \(vc < 0\) return;\n        synchronized \(PLAYDEP_LOCK\) \{\n',
             lambda m: m.group(1)+'        synchronized (PLAYDEP_LOCK) {\n            long vc = versionCodeOf(ctx, pkg);\n            if (vc < 0) return;\n', s, count=1)
if n!=1: sys.exit('pattern not found: notePlaySeen head')
s=s2"
  probe convict "a second versionCodeOf re-read added inside notePlaySeen's lock" \
    "r('            String ans = needsPlay ? \"y\" : \"n\";', '            if (versionCodeOf(ctx, pkg) != vc) return;\n            String ans = needsPlay ? \"y\" : \"n\";')"
  probe convict "setPlayDep's lock block calls getPackageManager()" \
    "r('            java.util.LinkedHashSet<String> s = new java.util.LinkedHashSet<>(onDisk);', '            ctx.getPackageManager();\n            java.util.LinkedHashSet<String> s = new java.util.LinkedHashSet<>(onDisk);')"
  probe convict "setPlayDep's lock block calls readsPlayServices(), qualified lock spelling" \
    "r('    static void setPlayDep(android.content.Context ctx, String pkg, boolean on) {\n        synchronized (PLAYDEP_LOCK) {', '    static void setPlayDep(android.content.Context ctx, String pkg, boolean on) {\n        synchronized ( ProfileActivity.PLAYDEP_LOCK ){\n            readsPlayServices(ctx, pkg);')"
  probe convict "notePlaySeen's vc < 0 guard dropped (an unresolvable version would be recorded)" \
    "r('        if (vc < 0) return;\n        synchronized (PLAYDEP_LOCK) {', '        synchronized (PLAYDEP_LOCK) {')"
  probe pass "a versionCodeOf( mention in a comment and a string inside notePlaySeen's lock (prose, not a call)" \
    "r('            String ans = needsPlay ? \"y\" : \"n\";', '            // not versionCodeOf(ctx, pkg) here: see PLAYDEP_LOCK\n            String ans = needsPlay ? \"y\" : \"n\"; String why = \"getPackageManager() is off-lock\";')"
  rm -rf "$M"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
