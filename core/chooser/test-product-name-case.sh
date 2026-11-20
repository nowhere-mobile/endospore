#!/usr/bin/env bash
# test-product-name-case.sh [--mutate] [SUT root] -- no user-visible chooser string writes the product as "Nowhere"
# (NWP-20261210-30).
#
# WHY THIS IS COMMITTED. docs/product-decisions.md, 2026-11-15, "DECIDED: the product's name is written "nowhere" in
# user-visible text": wherever user-visible text names the product it is written nowhere, lower-case, at the start of a
# sentence too. The legal entity keeps its spelling ("Nowhere Mobile LLC"). Identifiers, package names, the docs and
# the public repos' names are out of scope. The backlog row is 'User-visible text writes the product's name as
# "Nowhere"; Chester wants it written "nowhere"' (docs/backlog.md, section C).
#
# WHAT IT SCANS. The SCANNER below (python3) reads, under the SUT root (default: this repo):
#   - core/chooser/src/**/*.java: comments are stripped (never inside a string), then every string literal is taken.
#     A literal is refused when it holds the word Nowhere (\bNowhere\b), unless that occurrence is followed by
#     " Mobile LLC" (the legal name), or the literal sits in a statement (the text since the previous ; { or }) that
#     calls Log.v|d|i|w|e|wtf( (log text, never shown to a user).
#   - core/chooser/AndroidManifest.xml and core/chooser/res/**/*.xml: comments are skipped; the word is refused in any
#     android:label, android:description or android:title value and in any <string> body.
# Identifiers (NowhereApp, Theme.Nowhere, com.nowhere.*) never match: they are not literals, and \b keeps a word
# inside a longer name from matching. Each hit prints as file:line; then a count. Exit 0 clean, 1 on any hit, 2 on a
# scan that read no file.
#
# THE CASES. R1 runs the scanner over the real tree: 0 hits, and at least 100 Java files read (a control that proves
# it ran). F1-F8 are fixtures under $W, each its own SUT root. E1 runs this script over an empty SUT directory and
# expects exit 2, not 1 (it runs only from the default SUT). --mutate breaks a copy of the tree (source mutants), of
# the scanner (scanner mutants) or of this script (M8, M9, convicted by E1); each must be CONVICTED by the case its
# label names. One control mutant (a comment in the scanner) must SURVIVE.
#
#   bash core/chooser/test-product-name-case.sh            # R1 + F1-F8
#   bash core/chooser/test-product-name-case.sh --mutate   # ... plus the mutants
set -uo pipefail

MUTATE=no
SUT=
for a in "$@"; do
  case "$a" in
    --mutate) MUTATE=yes ;;
    -*) echo "usage: $0 [--mutate] [SUT root]" >&2; exit 2 ;;
    *) [ -z "$SUT" ] || { echo "usage: $0 [--mutate] [SUT root]" >&2; exit 2; }; SUT="$a" ;;
  esac
done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
self="$here/$(basename "$0")"
[ -n "$SUT" ] || SUT=$(cd "$here/../.." && pwd)
[ -d "$SUT" ] || { echo "FAIL: no SUT root $SUT" >&2; exit 2; }
SUT=$(cd "$SUT" && pwd)
command -v python3 >/dev/null 2>&1 || { echo "FAIL: no python3 -- this suite does not skip" >&2; exit 2; }

# The scanner is the text between the two marker lines of this file, so a mutant can edit a copy of it.
SCANNER="$W/scan.py"
awk '/^# >>> SCANNER$/{f=1; next} /^# <<< SCANNER$/{f=0} f' "$self" > "$SCANNER"
[ -s "$SCANNER" ] || { echo "FAIL: could not extract the scanner from $self" >&2; exit 2; }
: <<'END_OF_SCANNER'
# >>> SCANNER
import html, os, re, sys

WORD = re.compile(r'\bNowhere\b(?! Mobile LLC)')
LOGCALL = re.compile(r'(?<![\w.])Log\s*\.\s*(?:v|d|i|w|e|wtf)\s*\(')


def java_literals(src):
    """Yield (line, text, statement) for every string literal of a Java source, comments stripped."""
    out = []
    i, n, line = 0, len(src), 1
    stmt = []                     # the code text since the previous ; { or }
    pending = []                  # the literals of the current statement: [line, text]

    def flush():
        s = ''.join(stmt)
        for ln, t in pending:
            out.append((ln, t, s))
        pending.clear()
        stmt.clear()

    while i < n:
        c = src[i]
        # a line comment: skipped to the end of the line
        if src.startswith('//', i):
            j = src.find('\n', i)
            i = n if j < 0 else j
            continue
        # a block comment: skipped, its newlines still counted
        if src.startswith('/*', i):
            j = src.find('*/', i + 2)
            j = n if j < 0 else j + 2
            line += src.count('\n', i, j)
            stmt.append(' ')
            i = j
            continue
        # a text block """ ... """
        if src.startswith('"""', i):
            j = i + 3
            buf = []
            start = line
            while j < n and not src.startswith('"""', j):
                if src[j] == '\\' and j + 1 < n:
                    buf.append(src[j:j + 2]); j += 2; continue
                buf.append(src[j]); j += 1
            text = ''.join(buf)
            line += text.count('\n')
            pending.append([start, text])
            stmt.append('""')
            i = j + 3
            continue
        # a string literal "..."
        if c == '"':
            j = i + 1
            buf = []
            while j < n and src[j] != '"' and src[j] != '\n':
                if src[j] == '\\' and j + 1 < n:
                    buf.append(src[j:j + 2]); j += 2; continue
                buf.append(src[j]); j += 1
            pending.append([line, ''.join(buf)])
            stmt.append('""')
            i = j + 1
            continue
        # a char literal 'x' or '\x' (so a quote in it does not open a string)
        if c == "'":
            m = re.match(r"'(?:\\.[^']*|[^'\\\n])'", src[i:i + 12])
            if m:
                stmt.append("''")
                i += m.end()
                continue
        if c == '\n':
            line += 1
        if c in ';{}':
            flush()
        else:
            stmt.append(c)
        i += 1
    flush()
    return out


def scan_java(path, rel, hits):
    with open(path, encoding='utf-8') as f:
        src = f.read()
    for ln, text, stmt in java_literals(src):
        if LOGCALL.search(stmt):
            continue                      # log text
        for m in WORD.finditer(text):
            hits.append('%s:%d' % (rel, ln + text.count('\n', 0, m.start())))


XML_COMMENT = re.compile(r'<!--.*?-->', re.S)
XML_ATTR = re.compile(r'\bandroid:(?:label|description|title)\s*=\s*(["\'])(.*?)\1', re.S)
XML_STRING = re.compile(r'<string\b[^>]*>(.*?)</string\s*>', re.S)


def scan_xml(path, rel, hits):
    with open(path, encoding='utf-8') as f:
        src = f.read()
    # comments blanked, their newlines kept, so a position still names its line
    src = XML_COMMENT.sub(lambda m: re.sub(r'[^\n]', ' ', m.group(0)), src)
    for rx, g in ((XML_ATTR, 2), (XML_STRING, 1)):
        for m in rx.finditer(src):
            value = m.group(g)
            for w in WORD.finditer(html.unescape(value)):
                # the line of the value's start, plus the newlines before the hit (entities hold no newline)
                hits.append('%s:%d' % (rel, src.count('\n', 0, m.start(g)) + 1 + html.unescape(value).count('\n', 0, w.start())))


def main(root):
    hits, java_n, xml_n = [], 0, 0
    src_root = os.path.join(root, 'core/chooser/src')
    for d, _, files in sorted(os.walk(src_root)):
        for fn in sorted(files):
            if fn.endswith('.java'):
                p = os.path.join(d, fn)
                scan_java(p, os.path.relpath(p, root), hits)
                java_n += 1
    xmls = []
    man = os.path.join(root, 'core/chooser/AndroidManifest.xml')
    if os.path.isfile(man):
        xmls.append(man)
    for d, _, files in sorted(os.walk(os.path.join(root, 'core/chooser/res'))):
        xmls += [os.path.join(d, fn) for fn in sorted(files) if fn.endswith('.xml')]
    for p in xmls:
        scan_xml(p, os.path.relpath(p, root), hits)
        xml_n += 1
    for h in hits:
        print(h)
    print('hits=%d java_files=%d xml_files=%d' % (len(hits), java_n, xml_n))
    if java_n + xml_n == 0:
        print('FAIL: the scan read no file under %s' % root, file=sys.stderr)
        return 2
    return 1 if hits else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1]))
# <<< SCANNER
END_OF_SCANNER

# scan <scanner> <root> -> prints the scanner's output; returns its exit code.
scan() {
  python3 -I "$1" "$2"
}

# r1 <scanner> <root>: the real tree has 0 hits, and the scan read at least 100 Java files.
# Returns 2 when the scanner read no file at all (its own exit 2), so the public command can exit 2 too (RF-001).
r1() {
  local out rc n
  out=$(scan "$1" "$2" 2>&1); rc=$?
  if [ "$rc" -eq 2 ]; then
    echo "--- FAIL R1 control: the scan read no file ($2)"; return 2
  fi
  n=$(printf '%s\n' "$out" | sed -n 's/.*java_files=\([0-9]*\).*/\1/p' | tail -n 1)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  if [ "$n" -lt 100 ]; then
    echo "--- FAIL R1 control: the scan read $n Java files, fewer than 100 ($2)"; return 1
  fi
  if [ "$rc" -ne 0 ]; then
    echo "--- FAIL R1 the real tree writes the product as \"Nowhere\" (rc=$rc):"
    printf '%s\n' "$out" | sed 's/^/      /'
    return 1
  fi
  echo "ok   R1 $(printf '%s\n' "$out" | tail -n 1)"
}

# fixture <name> <rel path> <content>: a SUT root of its own under $W, holding one file.
fixture() {
  local d="$W/fx-$1"
  mkdir -p "$d/$(dirname "$2")"
  printf '%s\n' "$3" > "$d/$2"
  printf '%s' "$d"
}

# fx <scanner> <case> <refused|allowed> <expected hit or -> <root>
fx() {
  local out rc
  out=$(scan "$1" "$5" 2>&1); rc=$?
  case "$3" in
    refused)
      if [ "$rc" -eq 1 ] && case "$out" in *"$4"*) true ;; *) false ;; esac; then echo "ok   $2"; return 0; fi ;;
    allowed)
      if [ "$rc" -eq 0 ]; then echo "ok   $2"; return 0; fi ;;
  esac
  echo "--- FAIL $2 (expected $3, rc=$rc):"
  printf '%s\n' "$out" | sed 's/^/      /'
  return 1
}

J=core/chooser/src/com/nowhere/chooser/F.java
F1=$(fixture f1 "$J" 'class F { String s = "Sign in on any Nowhere phone"; }')
F2=$(fixture f2 "$J" 'class F {
    String s = "Sign in on any "
            + "Nowhere phone";
}')
F3=$(fixture f3 "$J" 'class F { String s = "These terms are from Nowhere Mobile LLC."; }')
F4=$(fixture f4 "$J" 'class F { void f() { Log.w("NowhereChooser", "Nowhere x"); } }')
F5=$(fixture f5 "$J" 'class F {
    // the "Nowhere" word, in a line comment
    /* and the "Nowhere" word,
       in a block comment */
    String s = "ok";
}')
F6=$(fixture f6 "$J" 'class NowhereApp {
    String cls = "com.nowhere.chooser.NowhereApp";
    String s = "the managed nowhere store";
}')
F7=$(fixture f7 core/chooser/AndroidManifest.xml '<manifest xmlns:android="http://schemas.android.com/apk/res/android">
  <!-- android:label="Nowhere" in a comment is skipped -->
  <application android:label="Nowhere" android:name=".NowhereApp" />
</manifest>')
F8=$(fixture f8 "$J" 'class F { String s = "// Nowhere"; }')

# checks <scanner> <real root>: R1 and F1-F8; every failing case prints a "--- FAIL <case>" line.
# Returns 2 when R1's scan read no file, 1 on any other failing case, 0 when every case passes.
checks() {
  local f=0 r=0
  r1 "$1" "$2" || r=$?
  fx "$1" "F1 a plain literal is refused"                     refused "$J:1" "$F1" || f=1
  fx "$1" "F2 the second literal of a concatenation is refused" refused "$J:3" "$F2" || f=1
  fx "$1" "F3 Nowhere Mobile LLC is allowed"                   allowed - "$F3" || f=1
  fx "$1" "F4 log text is allowed"                             allowed - "$F4" || f=1
  fx "$1" "F5 the word in comments only is allowed"            allowed - "$F5" || f=1
  fx "$1" "F6 identifiers and lower-case nowhere are allowed"  allowed - "$F6" || f=1
  fx "$1" "F7 a manifest android:label is refused"             refused "core/chooser/AndroidManifest.xml:3" "$F7" || f=1
  fx "$1" "F8 a comment-looking string is refused"             refused "$J:1" "$F8" || f=1
  [ "$r" -eq 0 ] || f=$r
  return "$f"
}

# e1 <script>: the public command, given an existing but empty SUT directory, exits 2 (a scan that read no file),
# never 1 (a hit). The script runs plain, so it never runs e1 again.
e1() {
  local d out rc
  d=$(mktemp -d -p "$W" empty.XXXXXX)
  out=$(TMPDIR="$W" bash "$1" "$d" 2>&1); rc=$?
  if [ "$rc" -eq 2 ] && case "$out" in *"the scan read no file"*) true ;; *) false ;; esac; then
    echo "ok   E1 an empty SUT directory exits 2"; return 0
  fi
  echo "--- FAIL E1 an empty SUT directory exits 2 (rc=$rc):"
  printf '%s\n' "$out" | sed 's/^/      /'
  return 1
}

echo "== $SUT"
checks "$SCANNER" "$SUT"; rc=$?
if [ "$rc" -eq 2 ]; then echo "FAIL: test-product-name-case (the scan read no file)"; exit 2; fi
if [ "$rc" -ne 0 ]; then echo "FAIL: test-product-name-case"; exit 1; fi
# E1 runs only from the default SUT (this repo), so the child run it starts (an empty SUT) never runs E1 again.
if [ $# -eq 0 ] || { [ $# -eq 1 ] && [ "$MUTATE" = yes ]; }; then
  e1 "$self" || { echo "FAIL: test-product-name-case"; exit 1; }
fi
echo "PASS: test-product-name-case"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not apply proves nothing)"

# A copy of the scanned part of the SUT, for the source mutants.
TREE="$W/tree"
mkdir -p "$TREE/core/chooser"
cp -R "$SUT/core/chooser/src" "$TREE/core/chooser/src" || { echo "FAIL: could not copy the tree" >&2; exit 1; }
[ -d "$SUT/core/chooser/res" ] && cp -R "$SUT/core/chooser/res" "$TREE/core/chooser/res"
cp "$SUT/core/chooser/AndroidManifest.xml" "$TREE/core/chooser/AndroidManifest.xml" || exit 1

# verdict <label> <out file> <rc> <convicting text>: CONVICTED only when the checks fail AND the output holds
# <convicting text> (a fixed string: the failing case the label names).
verdict() {
  if [ "$3" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if grep -qF -- "$4" "$2"; then echo "  convicted $1"; return 0; fi
  echo "  WRONG     $1 -- the checks failed, but not on: $4"; sed 's/^/      /' "$2"; return 1
}

# srcmut <label> <rel file> <perl-expr> <convicting text>: a source mutant, on the tree copy, restored afterwards.
srcmut() {
  local f="$TREE/$2" keep out rc
  keep=$(mktemp -p "$W"); out=$(mktemp -p "$W")
  cp "$f" "$keep"
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed on the mutation"; cp "$keep" "$f"; return 1; fi
  if cmp -s "$f" "$keep"; then echo "  INERT     $1 -- the mutation changed nothing"; return 1; fi
  checks "$SCANNER" "$TREE" >"$out" 2>&1; rc=$?
  cp "$keep" "$f"
  verdict "$1" "$out" "$rc" "$4"
}

# scanmut <label> <perl-expr> <convicting text> [survive]: a scanner mutant, run over the real tree and the fixtures.
scanmut() {
  local m out rc
  m=$(mktemp -p "$W" scan.XXXXXX); out=$(mktemp -p "$W")
  if ! perl -0pe "$2" "$SCANNER" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; return 1; fi
  if cmp -s "$SCANNER" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; return 1; fi
  checks "$m" "$SUT" >"$out" 2>&1; rc=$?
  if [ "${4:-}" = survive ]; then
    if [ "$rc" -eq 0 ]; then echo "  survived  $1 (control: must survive)"; return 0; fi
    echo "  KILLED    $1 -- a control mutant failed the checks"; sed 's/^/      /' "$out"; return 1
  fi
  verdict "$1" "$out" "$rc" "$3"
}

D=core/chooser/src/com/nowhere/chooser
fails=0
srcmut "S1 GateHelpHome HERO_TITLE back to \"How Nowhere works\" (R1)" "$D/GateHelpHome.java" \
  's/HERO_TITLE = "How nowhere works";/HERO_TITLE = "How Nowhere works";/' "--- FAIL R1 " || fails=$((fails+1))
srcmut "S2 ProfileActivity's \"nowhere couldn't confirm what happened\" back (R1)" "$D/ProfileActivity.java" \
  's/and nowhere couldn\x27t confirm what happened/and Nowhere couldn\x27t confirm what happened/' "--- FAIL R1 " || fails=$((fails+1))
srcmut "S3 StoreScreenCopy's managed line back (R1)" "$D/StoreScreenCopy.java" \
  's/the managed nowhere store\./the managed Nowhere store./' "--- FAIL R1 " || fails=$((fails+1))
srcmut "S4 a manifest label \"Nowhere\" added (R1)" "core/chooser/AndroidManifest.xml" \
  's/<application /<application android:label="Nowhere" /' "--- FAIL R1 " || fails=$((fails+1))

scanmut "M1a the LLC exemption dropped (R1 names OsAgreement:102)" \
  's/\(\?! Mobile LLC\)//' "OsAgreement.java:102" || fails=$((fails+1))
scanmut "M1b the LLC exemption dropped (F3)" \
  's/\(\?! Mobile LLC\)//' "--- FAIL F3 " || fails=$((fails+1))
scanmut "M2 the Log exemption dropped (F4)" \
  's/        if LOGCALL\.search\(stmt\):\n            continue                      # log text\n//' "--- FAIL F4 " || fails=$((fails+1))
scanmut "M3 comment stripping dropped (F5)" \
  's/if src\.startswith\(\x27\/\/\x27, i\):/if False:/; s/if src\.startswith\(\x27\/\*\x27, i\):/if False:/' \
  "--- FAIL F5 " || fails=$((fails+1))
scanmut "M4 \\b dropped so identifiers match (F6)" \
  's/\\bNowhere\\b/Nowhere/' "--- FAIL F6 " || fails=$((fails+1))
scanmut "M5 XML not scanned (F7)" \
  's/    for p in xmls:\n        scan_xml\(p, os\.path\.relpath\(p, root\), hits\)\n/    for p in xmls:\n/' \
  "--- FAIL F7 " || fails=$((fails+1))
scanmut "M6 comment stripping applied inside strings (F8)" \
  's/(            while j < n and src\[j\] != \x27"\x27 and src\[j\] != \x27\\n\x27:\n)/$1                if src.startswith(\x27\/\/\x27, j):\n                    break\n/' \
  "--- FAIL F8 " || fails=$((fails+1))
scanmut "M7 the file-count control removed and the scan root misspelled (R1 control)" \
  's/core\/chooser\/src\x27/core\/chooser\/scr\x27/; s/    if java_n \+ xml_n == 0:\n.*?\n        return 2\n//s' \
  "--- FAIL R1 control:" || fails=$((fails+1))
# selfmut <label> <perl-expr> <convicting text>: a mutant of a copy of this script, convicted by E1 on that copy.
selfmut() {
  local m out rc
  m=$(mktemp -p "$W" self.XXXXXX); out=$(mktemp -p "$W")
  if ! perl -0pe "$2" "$self" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; return 1; fi
  if cmp -s "$self" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; return 1; fi
  e1 "$m" >"$out" 2>&1; rc=$?
  verdict "$1" "$out" "$rc" "$3"
}
selfmut "M8 R1 turns the scanner's exit 2 into 1 (E1)" \
  's/echo "--- FAIL R1 control: the scan read no file \(\$2\)"; return 2/echo "--- FAIL R1 control: the scan read no file (\$2)"; return 1/' \
  "--- FAIL E1 " || fails=$((fails+1))
selfmut "M9 the entry point turns checks' 2 into 1 (E1)" \
  's/\(the scan read no file\)"; exit 2; fi/(the scan read no file)"; exit 1; fi/' \
  "--- FAIL E1 " || fails=$((fails+1))
scanmut "C1 a comment's wording in the scanner (control)" \
  's/# a line comment: skipped to the end of the line/# a line comment: dropped up to its newline/' \
  "" survive || fails=$((fails+1))

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails mutant(s) not convicted (or a control killed)"; exit 1; fi
echo "PASS: every mutant convicted, the control survived"
