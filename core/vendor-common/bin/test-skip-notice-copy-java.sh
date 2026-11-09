#!/usr/bin/env bash
# test-skip-notice-copy-java.sh [--mutate] -- the #119 skip notice's chooser half, run under javac (NWP-20261128-08).
#
# WHY THIS IS COMMITTED. Backlog row "`pushProfile`'s tombstone skips report "Saved" and the next login tells nobody
# (#119)". A phone that signed in before a passphrase change on another phone skips its seal at sign-out, and the
# agent writes a notice (core/agent skip_notice.go). Until this slice no chooser source read it, so the decided discard
# stayed silent. The decision (docs/product-decisions.md 2026-11-01, h50 #6): a sign-in reads the notice, shows the
# words decided 2026-10-30 (h48 #5) and records that it showed it.
#
# WHAT RUNS. SkipNoticeCopy (pure, java.lang only) is compiled with core/chooser/tests/skip-notice/SkipNoticeCopyCases
# ALONE and run: P1 a notice parses (a label, an empty label, a label with spaces); P2 NONE, ERR, "", null, no tab, a
# non-numeric, zero or negative time and other malformed replies read as no notice; P3 words() is the h48 #5 sentence
# that THIS SUITE READS from docs/product-decisions.md, placeholders put in, so the copy cannot drift from the decision;
# P4 an empty label reads "another phone" (an inference, not a decided word); P5 shownRequest's exact bytes.
# WHAT IS PINNED BY ANCHOR (the chooser cannot be compiled off the build host; comments are stripped first):
#   S1 UnarchiveService.onStartCommand starts SkipNoticeActivity.check on its own daemon thread, with the application
#      context, only on the switch-landing path: after the netRekick block (which returns) and inside if (!byHand).
#   S2 SkipNoticeActivity sends SkipNoticeCopy.shownRequest only from markShown, and calls markShown only from
#      onResume behind a once-flag (shownSent) that onCreate restores and onSaveInstanceState saves: never from
#      onCreate or the OK button.
# The merger's full javac / `m NowhereChooser` covers SkipNoticeActivity and UnarchiveService themselves.
#
# What this does NOT prove: the two-phone run (a passphrase change on one phone, a skipped sign-out on the other, the
# notice shown once at the next sign-in) stays on the backlog row.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-skip-notice-copy-java.sh            # the cases and the pins
#   bash test-skip-notice-copy-java.sh --mutate   # ... plus mutants M1-M7 that must each CONVICT the suite
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W"

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
COPY="$SRC/SkipNoticeCopy.java"
ACT="$SRC/SkipNoticeActivity.java"
SVC="$SRC/UnarchiveService.java"
CASES="$root/core/chooser/tests/skip-notice/SkipNoticeCopyCases.java"
DOC="$root/docs/product-decisions.md"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "test-skip-notice-copy-java: FAIL -- no javac/java on PATH or in $HOST_JDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -J-Djava.io.tmpdir="$W" -version 2>&1 | sed 's/^/using /'

missing=0
for f in "$COPY" "$ACT" "$SVC" "$CASES" "$DOC"; do
  [ -f "$f" ] || { echo "test-skip-notice-copy-java: FAIL -- $f is missing"; missing=1; }
done
[ "$missing" -eq 0 ] || exit 1

# The h48 #5 sentence, placeholders intact, read from the decision itself.
SENT="$W/sentence.txt"
python3 -I - "$DOC" "$SENT" <<'PY'
import io, re, sys
doc = io.open(sys.argv[1], encoding='utf-8').read()
head = '## 2026-10-30 — DECIDED: ten answers to harvest 48'
if doc.count(head) != 1:
    print("EXTRACTION FAILED: the h48 entry heading occurs %d times" % doc.count(head)); sys.exit(1)
sec = doc[doc.index(head):]
nxt = sec.find('\n## ', 1)
sec = sec if nxt < 0 else sec[:nxt]
m = re.search(r'^5\. (.*)$', sec, re.M)
if not m:
    print("EXTRACTION FAILED: no item 5. in the h48 entry"); sys.exit(1)
w = re.search(r'\*"(Changes made on <phone>[^"]*)"\*', m.group(1))
if not w:
    print("EXTRACTION FAILED: no quoted sentence in h48 #5"); sys.exit(1)
s = w.group(1)
if s.count('<phone>') != 1 or s.count('<time>') != 1:
    print("EXTRACTION FAILED: h48 #5 does not hold <phone> and <time> once each"); sys.exit(1)
io.open(sys.argv[2], 'w', encoding='utf-8').write(s + '\n')
PY
[ $? -eq 0 ] || { echo "test-skip-notice-copy-java: FAIL -- the h48 #5 sentence"; exit 1; }
echo "ok the h48 #5 sentence read from docs/product-decisions.md"

# cases <SkipNoticeCopy.java> [quiet]: 0 pass, 1 a case failed, 3 did not compile.
cases() {
  local src=$1 quiet=${2:-} d out rc=0
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src" "$d/out"
  cp "$src" "$d/src/SkipNoticeCopy.java"
  cp "$CASES" "$d/src/SkipNoticeCopyCases.java"
  if ! out=$("$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d/out" "$d/src/SkipNoticeCopy.java" \
      "$d/src/SkipNoticeCopyCases.java" 2>&1); then
    [ -z "$quiet" ] && printf '%s\n' "$out"
    rm -rf "$d"; return 3
  fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.SkipNoticeCopyCases \
    "$SENT" 2>&1) || rc=$?
  [ -z "$quiet" ] && printf '%s\n' "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# pin <S1|S2> <file>: 0 the pin holds, 1 it does not, 2 could not extract.
pin() {
  python3 -I - "$1" "$2" <<'PY'
import io, re, sys
which, path = sys.argv[1], sys.argv[2]
raw = io.open(path, encoding='utf-8').read()

def strip(s):
    """Drop // and /* */ comments; keep string and char literals."""
    out, i, n = [], 0, len(s)
    while i < n:
        c = s[i]
        if c in '"\'':
            j = i + 1
            while j < n and s[j] != c:
                j += 2 if s[j] == '\\' else 1
            out.append(s[i:j + 1]); i = j + 1
        elif s.startswith('//', i):
            j = s.find('\n', i); i = n if j < 0 else j
        elif s.startswith('/*', i):
            j = s.find('*/', i + 2); i = n if j < 0 else j + 2
        else:
            out.append(c); i += 1
    return ''.join(out)

def mask(s):
    """Blank the inside of every string and char literal, so braces in text never count. Same length."""
    out, i, n = list(s), 0, len(s)
    while i < n:
        c = s[i]
        if c in '"\'':
            j = i + 1
            while j < n and s[j] != c:
                j += 2 if s[j] == '\\' else 1
            for k in range(i + 1, min(j, n)): out[k] = ' '
            i = j + 1
        else:
            i += 1
    return ''.join(out)

src = strip(raw)
m = mask(src)

def close_of(o):
    """Index of the } that closes the { at o."""
    d = 0
    for k in range(o, len(m)):
        if m[k] == '{': d += 1
        elif m[k] == '}':
            d -= 1
            if d == 0: return k
    print("EXTRACTION FAILED: unbalanced braces"); sys.exit(2)

def header(o):
    """The text before the { at o, back to the previous ; { or }."""
    k = o - 1
    while k >= 0 and m[k] not in ';{}': k -= 1
    return ' '.join(src[k + 1:o].split())

def body(sig):
    """[open, close] of the one method whose 4-space-indent declaration matches sig."""
    hits = [x for x in re.finditer(sig, m, re.M)]
    if len(hits) != 1:
        print("EXTRACTION FAILED: %r matches %d times" % (sig, len(hits))); sys.exit(2)
    o = m.index('{', hits[0].end() - 1)
    return o, close_of(o)

def fail(why):
    print("FAIL %s: %s" % (which, why)); sys.exit(1)

if which == 'S1':
    calls = [x.start() for x in re.finditer(r'SkipNoticeActivity\.check\(', m)]
    if len(calls) != 1: fail("SkipNoticeActivity.check( occurs %d times, want 1" % len(calls))
    c = calls[0]
    so, sc = body(r'^    public int onStartCommand\(')
    if not (so < c < sc): fail("the check is not started inside onStartCommand")
    nr = re.search(r'if \(netRekick\) \{', m[so:sc])
    if not nr: fail("no if (netRekick) { block in onStartCommand")
    no = so + nr.end() - 1
    nc = close_of(no)
    if not re.search(r'\breturn;', m[no:nc]): fail("the netRekick block does not return")
    if c < nc: fail("the check is started before the netRekick block returns")
    # Walk out of the braces around the call; the first if (...) met must be if (!byHand).
    opens, d = [], 0
    for k in range(c, so, -1):
        if m[k] == '}': d += 1
        elif m[k] == '{':
            if d == 0: opens.append(k)
            else: d -= 1
    guard = None
    for o in opens:
        h = header(o)
        if h.startswith('if'):
            guard = (o, h); break
    if guard is None: fail("no if (...) encloses the check")
    if guard[1] != 'if (!byHand)': fail("the first if around the check is %r, want 'if (!byHand)'" % guard[1])
    blk = m[guard[0]:close_of(guard[0]) + 1]
    if not re.search(r'new Thread\(\(\) -> SkipNoticeActivity\.check\(', blk): fail("the check does not run on its own new Thread")
    if not re.search(r'\.setDaemon\(true\);', blk): fail("the check's thread is not a daemon thread")
    if 'getApplicationContext()' not in blk: fail("the check does not get the application context")
    print("PASS S1 the check starts on the switch-landing path only (after the netRekick return, inside if (!byHand))")
elif which == 'S2':
    meth = {
        'onCreate': body(r'^    @Override protected void onCreate\('),
        'onResume': body(r'^    @Override protected void onResume\('),
        'onSaveInstanceState': body(r'^    @Override protected void onSaveInstanceState\('),
        'markShown': body(r'^    private static void markShown\('),
    }
    def inside(pos):
        return [k for k, (o, e) in meth.items() if o < pos < e]
    sr = [x.start() for x in re.finditer(r'shownRequest\(', m)]
    if not sr: fail("no shownRequest( call")
    for p in sr:
        if inside(p) != ['markShown']: fail("shownRequest( is called outside markShown")
    decl = re.search(r'^    private static void markShown\(', m, re.M).start()
    ms = [x.start() for x in re.finditer(r'\bmarkShown\(', m) if x.start() != decl + len('    private static void ')]
    if not ms: fail("markShown( is never called")
    for p in ms:
        if inside(p) != ['onResume']: fail("markShown( is called outside onResume (%s)" % (inside(p) or 'no method'))
    ro, re_ = meth['onResume']
    rb = m[ro:re_]
    g = re.search(r'if \(!shownSent\b', rb)
    st = rb.find('shownSent = true;')
    if not g: fail("onResume does not test !shownSent")
    if st < 0: fail("onResume does not set shownSent = true")
    if not (g.start() < st < rb.find('markShown(')): fail("onResume does not set shownSent before it starts markShown")
    co, ce = meth['onCreate']
    if 'markShown(' in m[co:ce] or 'shownRequest(' in m[co:ce]: fail("onCreate sends the shown request")
    if 'getBoolean(STATE_SHOWN_SENT' not in m[co:ce]: fail("onCreate does not restore shownSent")
    oo, oe = meth['onSaveInstanceState']
    if 'putBoolean(STATE_SHOWN_SENT' not in m[oo:oe]: fail("onSaveInstanceState does not save shownSent")
    print("PASS S2 the shown request is sent from onResume once, never from onCreate or the OK button")
else:
    print("EXTRACTION FAILED: no pin %s" % which); sys.exit(2)
PY
}

fails=0
if cases "$COPY"; then echo "PASS cases"; else echo "FAIL cases"; fails=$((fails + 1)); fi
pin S1 "$SVC" || fails=$((fails + 1))
pin S2 "$ACT" || fails=$((fails + 1))
if [ "$fails" -ne 0 ]; then echo "test-skip-notice-copy-java: FAIL ($fails check(s))"; exit 1; fi
echo "test-skip-notice-copy-java: PASS"
[ "$MUTATE" = yes ] || exit 0

# --mutate: each mutant edits a COPY of one file and must make its check fail. A mutant that does not apply fails.
MFAILS=0
# mutate <Mn> <file> <out>: apply mutant Mn to <file>, write <out>; non-zero when it did not apply.
mutate() {
  python3 -I - "$1" "$2" "$3" <<'PY'
import io, sys
mid, src, dst = sys.argv[1], sys.argv[2], sys.argv[3]
s = io.open(src, encoding='utf-8').read()
def rep(t, old, new):
    if t.count(old) != 1:
        print("MUTANT %s DID NOT APPLY: %r occurs %d times" % (mid, old, t.count(old))); sys.exit(1)
    return t.replace(old, new)
if mid == 'M1':
    sig = '    static Notice parse(String reply) {\n'
    t = rep(s, sig, sig + '        if ("NONE".equals(reply)) return new Notice("", 1L);\n')
elif mid == 'M2':
    t = rep(s, 'if (t <= 0) return null;', 'if (t < 0) return null;')
elif mid == 'M3':
    t = rep(s, "<time> weren't saved,", "<time> were not saved,")
elif mid == 'M4':
    t = rep(s, '(phone == null || phone.isEmpty()) ? ANOTHER_PHONE : phone', '(phone == null) ? "" : phone')
elif mid == 'M5':
    t = rep(s, '''            Thread th = new Thread(() -> markShown(t), "nowhere-skip-notice-shown");
            th.setDaemon(true);
            th.start();
''', '')
    t = rep(t, 'ok.setOnClickListener(v -> finish());', 'ok.setOnClickListener(v -> { markShown(time); finish(); });')
elif mid in ('M6', 'M7'):
    a = s.find('                // NWP-20261128-08 (#119, h50 #6)')
    e = s.find('"skip notice start", t); }\n                }\n', a)
    if a < 0 or e < 0:
        print("MUTANT %s DID NOT APPLY: the skip notice block not found" % mid); sys.exit(1)
    e = e + len('"skip notice start", t); }\n                }\n')
    blk = s[a:e]
    if mid == 'M6':
        t = s[:a] + s[e:]
        t = rep(t, '                if (netRekick) {\n', blk + '                if (netRekick) {\n')
    else:
        t = s[:a] + rep(blk, 'if (!byHand) {', '{') + s[e:]
else:
    print("no mutant %s" % mid); sys.exit(2)
if t == s:
    print("MUTANT %s DID NOT APPLY: no change" % mid); sys.exit(1)
io.open(dst, 'w', encoding='utf-8').write(t)
PY
}

# convict <Mn> <cases|S1|S2> <file> <what>
convict() {
  local id=$1 check=$2 file=$3 what=$4 d dst rc
  d=$(mktemp -d -p "$W") || { echo "FAIL $id: no temp"; MFAILS=$((MFAILS + 1)); return; }
  dst="$d/$(basename "$file")"
  if ! mutate "$id" "$file" "$dst"; then echo "FAIL $id ($what): the mutant did not apply"; MFAILS=$((MFAILS + 1)); return; fi
  if [ "$check" = cases ]; then
    cases "$dst" quiet; rc=$?
  else
    pin "$check" "$dst" >/dev/null; rc=$?
  fi
  if [ "$rc" -eq 1 ]; then echo "CONVICTED $id ($what)"
  elif [ "$rc" -eq 0 ]; then echo "SURVIVED $id ($what)"; MFAILS=$((MFAILS + 1))
  else echo "FAIL $id ($what): the check could not run (rc $rc)"; MFAILS=$((MFAILS + 1)); fi
  rm -rf "$d"
}

convict M1 cases "$COPY" "parse accepts NONE as a notice"
convict M2 cases "$COPY" "parse accepts time 0"
convict M3 cases "$COPY" "one word of the sentence changed"
convict M4 cases "$COPY" "the empty-phone fallback removed"
convict M5 S2 "$ACT" "the shown request moved to the OK button"
convict M6 S1 "$SVC" "the check runs before the netRekick return"
convict M7 S1 "$SVC" "the !byHand guard removed"

if [ "$MFAILS" -ne 0 ]; then echo "FAIL: $MFAILS mutant check(s) failed"; exit 1; fi
echo "OK: all 7 mutants convicted"
