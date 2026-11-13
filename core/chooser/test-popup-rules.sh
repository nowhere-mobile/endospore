#!/usr/bin/env bash
# test-popup-rules.sh [--mutate] -- the popup rules hold in the chooser's dialogs, and today's breaches only shrink
# (NWP-20261201-30).
#
# WHY THIS IS COMMITTED. Chester chose Design A for the popups on 2026-11-08 (docs/backlog.md, "Popups are plain dialogs:
# the choice pickers and the confirmations move to one bottom-sheet design"). Its rules are in that row. This suite pins
# them on every AlertDialog.Builder in ChooserActivity, ProfileActivity, PrivateDnsPromptActivity and PrivateDnsWatch. The
# row excluded the gate Help's list. NOWHERE-1695 replaced that list with GateHelpScreen, which is no AlertDialog. The one
# Help builder left, showGateHelpPage, has a Back button and a named "also" button, so this scan exempts no builder.
#
#   R1 a button is never OK or Cancel        (setPositiveButton, setNegativeButton, setNeutralButton)
#   R2 no "&" in a string of the builder or in a label that a constant resolves to
#   R3 the first word of a positive button is never a destructive verb
#
# THIS IS A RATCHET, NOT A REWORDING. tests/popup-rules/baseline.txt lists today's breaches. Each line is
# <file> TAB <method> TAB <R1|R2|R3> TAB <label or literal> TAB <count>. The keys hold no line number, so an unrelated edit
# does not change them. A run fails on:
#   NEW                a breach that is not in the baseline, or above its count: reword the dialog
#   STALE: delete it   a baseline line that no longer occurs, or occurs fewer times: delete it or lower its count
#   CONTROL            fewer than 50 builders found, so the scan did not run
#   VERBS differ       core/chooser/src/.../PopupSheet.java holds another DESTRUCTIVE_VERBS list than this scanner
# The rules judge the VALUE of a Java literal, after its unicode, octal and character escapes. A tab, a line break or
# another unprintable character in a key is written as a backslash escape, so one key stays on one baseline line.
# A label that is a variable, a call, a concatenation or a ternary cannot be judged. The run counts it under UNRESOLVED and
# does not call it a breach. The number of builders is printed and never pinned: only the floor of 50 fails.
#
# ⚠ IT FAILS WHEN THERE IS NO PYTHON3, IT NEVER SKIPS.
#
#   bash test-popup-rules.sh            # scan the tree against the baseline
#   bash test-popup-rules.sh --mutate   # ... plus broken copies that must each FAIL
# SRC_DIR=<dir> / BASELINE=<file> point the scan at other copies.
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
TREE_SRC="${SRC_DIR:-$here/src/com/nowhere/chooser}"
TREE_BASELINE="${BASELINE:-$here/tests/popup-rules/baseline.txt}"

command -v python3 >/dev/null 2>&1 || { echo "FAIL: no python3, the scanner needs it" >&2; exit 2; }

cat > "$W/scan.py" <<'PY'
import collections, os, re, sys

FILES = ("ChooserActivity.java", "ProfileActivity.java", "PrivateDnsPromptActivity.java", "PrivateDnsWatch.java")
DESTRUCTIVE_VERBS = ("Delete", "Erase", "Wipe", "Remove", "Discard", "Unbind", "Clear", "Reset", "Drop", "Forget",
                     "Leave", "Uninstall")
FLOOR = 50
OK_OR_CANCEL = ("ok", "okay", "cancel")
CONTROL_WORDS = ("if", "for", "while", "switch", "catch", "synchronized", "try", "do", "else", "return", "new")

CHAR_LITERAL = re.compile(r"'(?:[^'\\\n]|\\[0-7]{1,3}|\\.)'")
STRING_LITERAL = re.compile(r'"(?:[^"\\\n]|\\.)*"')
UNICODE_ESCAPE = re.compile(r"\\\\|\\u+([0-9a-fA-F]{4})")
STRING_ESCAPE = re.compile(r"\\(?:([0-3][0-7]{0,2}|[4-7][0-7]?)|(.))", re.S)
SIMPLE_ESCAPES = {"b": "\b", "s": " ", "t": "\t", "n": "\n", "f": "\f", "r": "\r", '"': '"', "'": "'", "\\": "\\"}
KEY_ESCAPES = {"\\": "\\\\", "\t": "\\t", "\n": "\\n", "\r": "\\r"}
CONSTANT_LABEL = re.compile(r"([A-Z]\w*)\.([A-Z_][A-Z0-9_]*)")
ANDROID_LABEL = re.compile(r"android\s*\.\s*R\s*\.\s*string\s*\.\s*(ok|cancel)")
BUILDER = re.compile(r"\bAlertDialog\s*\.\s*Builder\s*\(")
VARIABLE = re.compile(r"\bAlertDialog\s*\.\s*Builder\s+([A-Za-z_]\w*)\s*=\s*new\s+(?:android\s*\.\s*app\s*\.\s*)?"
                      r"AlertDialog\s*\.\s*Builder\s*\(")
BUTTON_NAMES = ("setPositiveButton", "setNegativeButton", "setNeutralButton")
BUTTON = re.compile(r"\.\s*(set(?:Positive|Negative|Neutral)Button)\s*\(")
CHAIN_CALL = re.compile(r"\s*([A-Za-z_]\w*)\s*\(")
CLASS_HEADER = re.compile(r"\b(?:class|interface|enum)\b[^;{}()=]*$")
THROWS_CLAUSE = re.compile(r"\bthrows\s+[\w.,\s]+$")
ANONYMOUS_CLASS = re.compile(r"\bnew\s+[\w.]+(?:<[^;(){}]*>)?\s*$")
METHOD_NAME = re.compile(r"([A-Za-z_]\w*)\s*$")
VERB_LIST = re.compile(r"DESTRUCTIVE_VERBS\s*=\s*Collections\s*\.\s*unmodifiableList\s*\(\s*Arrays\s*\.\s*asList\s*\("
                       r"([^;]*?)\)\s*\)\s*;")

Builder = collections.namedtuple("Builder", "start open end method")
Span = collections.namedtuple("Span", "start end builder")


def die(message):
    print("FAIL: " + message)
    sys.exit(2)


def read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError as e:
        die("cannot read %s: %s" % (path, e.strerror))


def translate_unicode(m):
    return chr(int(m.group(1), 16)) if m.group(1) else m.group(0)


def read_java(path):
    """The source after Java's first step: each \\uXXXX whose backslash is not itself escaped becomes its character."""
    return UNICODE_ESCAPE.sub(translate_unicode, read(path))


def unescape(m):
    return chr(int(m.group(1), 8)) if m.group(1) else SIMPLE_ESCAPES.get(m.group(2), m.group(0))


def decode_literal(literal):
    """The value of a quoted Java string literal."""
    return STRING_ESCAPE.sub(unescape, literal[1:-1])


def key_text(value):
    """value on one line, with no tab, and two different values never share a key."""
    return "".join(KEY_ESCAPES.get(c) or (c if c.isprintable() else "\\u%04x" % ord(c)) for c in value)


def skip_string(text, i):
    j = i + 1
    while j < len(text) and text[j] != "\n":
        if text[j] == "\\":
            j += 2
            continue
        if text[j] == '"':
            return j + 1
        j += 1
    return j


def strip_comments(raw):
    out = list(raw)
    i, n = 0, len(raw)
    while i < n:
        c = raw[i]
        if c == '"':
            i = skip_string(raw, i)
        elif c == "'":
            m = CHAR_LITERAL.match(raw, i)
            i = m.end() if m else i + 1
        elif raw.startswith("//", i):
            j = raw.find("\n", i)
            j = n if j < 0 else j
            out[i:j] = " " * (j - i)
            i = j
        elif raw.startswith("/*", i):
            j = raw.find("*/", i + 2)
            j = n if j < 0 else j + 2
            for k in range(i, j):
                if raw[k] != "\n":
                    out[k] = " "
            i = j
        else:
            i += 1
    return "".join(out)


def mask_literals(text):
    """A copy of text with every string and char literal blanked, and the spans of the strings."""
    out = list(text)
    strings = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            j = skip_string(text, i)
            strings.append((i, j))
            out[i:j] = " " * (j - i)
            i = j
        elif c == "'":
            m = CHAR_LITERAL.match(text, i)
            if m:
                out[i:m.end()] = " " * (m.end() - i)
                i = m.end()
            else:
                i += 1
        else:
            i += 1
    return "".join(out), strings


def close_paren(mask, open_paren):
    depth = 0
    for i in range(open_paren, len(mask)):
        if mask[i] == "(":
            depth += 1
        elif mask[i] == ")":
            depth -= 1
            if depth == 0:
                return i
    return None


def open_paren_before(mask, close):
    depth = 0
    for i in range(close, -1, -1):
        if mask[i] == ")":
            depth += 1
        elif mask[i] == "(":
            depth -= 1
            if depth == 0:
                return i
    return None


def statement_end(mask, open_paren):
    """The end of the statement that starts at this paren: a ; or , at depth 0, or the bracket that closes around it."""
    depth = 0
    for i in range(open_paren, len(mask)):
        c = mask[i]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            if depth < 0:
                return i
        elif depth == 0 and c in ";,":
            return i
    return len(mask)


def classify_brace(mask, brace, parent_kind):
    offset = max(0, brace - 2000)
    head = mask[offset:brace]
    if CLASS_HEADER.search(head):
        return "class", None
    head = THROWS_CLAUSE.sub("", head.rstrip()).rstrip()
    if not head.endswith(")"):
        return "block", None
    opened = open_paren_before(mask, offset + len(head) - 1)
    if opened is None:
        return "block", None
    before = mask[max(0, opened - 300):opened]
    if ANONYMOUS_CLASS.search(before):
        return "class", None
    name = METHOD_NAME.search(before)
    if parent_kind == "class" and name and name.group(1) not in CONTROL_WORDS:
        return "method", name.group(1)
    return "block", None


def method_spans(mask):
    stack, spans = [], []
    for i, c in enumerate(mask):
        if c == "{":
            kind, name = classify_brace(mask, i, stack[-1][0] if stack else None)
            stack.append((kind, name, i))
        elif c == "}" and stack:
            kind, name, start = stack.pop()
            if kind == "method":
                spans.append((start, i + 1, name))
    return spans


def enclosing_method(methods, pos):
    inside = [m for m in methods if m[0] <= pos < m[1]]
    return max(inside, key=lambda m: m[0]) if inside else None


def owners(spans, pos):
    inside = sorted((s for s in spans if s.start <= pos < s.end), key=lambda s: s.start, reverse=True)
    return inside[:1]


def button_chain(mask, pos):
    """The (open, close) parens of each button call in the chain that starts at pos, just after `<v>.`."""
    calls = []
    while True:
        m = CHAIN_CALL.match(mask, pos)
        if not m:
            return calls
        opened = m.end() - 1
        closed = close_paren(mask, opened)
        if closed is None:
            return calls
        if m.group(1) in BUTTON_NAMES:
            calls.append((opened, closed))
        pos = closed + 1
        while pos < len(mask) and mask[pos].isspace():
            pos += 1
        if pos >= len(mask) or mask[pos] != ".":
            return calls
        pos += 1


def variable_spans(mask, builders, methods):
    """One span for the argument list of each later <v>.set...Button( call of a builder held in a variable."""
    by_open = {b.open: b for b in builders}
    declarations = [m for m in VARIABLE.finditer(mask)]
    found = []
    for i, decl in enumerate(declarations):
        builder = by_open.get(decl.end() - 1)
        method = enclosing_method(methods, decl.start())
        if builder is None or method is None:
            continue
        limit = method[1]
        for later in declarations[i + 1:]:
            if later.group(1) == decl.group(1) and later.start() < limit:
                limit = later.start()
                break
        use = re.compile(r"(?<![\w.])" + re.escape(decl.group(1)) + r"\s*\.")
        for call in use.finditer(mask, builder.end, limit):
            found.extend(Span(opened, closed + 1, builder) for opened, closed in button_chain(mask, call.end()))
    return found


class Constants:
    def __init__(self, src_dir):
        self.src_dir = src_dir
        self.texts = {}

    def resolve(self, cls, name):
        if cls not in self.texts:
            path = os.path.join(self.src_dir, cls + ".java")
            self.texts[cls] = strip_comments(read_java(path)) if os.path.isfile(path) else ""
        m = re.search(r"static\s+final\s+String\s+" + re.escape(name) + r"\s*=\s*(" + STRING_LITERAL.pattern + r")\s*;",
                      self.texts[cls])
        return decode_literal(m.group(1)) if m else None


def resolve_label(expression, constants):
    """(kind, label). The kind is literal, constant, android or unresolved."""
    if STRING_LITERAL.fullmatch(expression):
        return "literal", decode_literal(expression)
    m = CONSTANT_LABEL.fullmatch(expression)
    if m:
        value = constants.resolve(m.group(1), m.group(2))
        if value is not None:
            return "constant", value
    if ANDROID_LABEL.fullmatch(expression):
        return "android", expression
    return "unresolved", expression


def first_argument_end(mask, opened, closed):
    depth = 0
    for i in range(opened + 1, closed):
        c = mask[i]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == "," and depth == 0:
            return i
    return closed


def is_destructive(label):
    words = label.split()
    return bool(words) and words[0].strip(".,:;!?…").casefold() in [v.casefold() for v in DESTRUCTIVE_VERBS]


def scan_file(name, src_dir, constants, found):
    """Add this file's breaches to found. Returns (builders, unresolved labels)."""
    raw = read_java(os.path.join(src_dir, name))
    text = strip_comments(raw)
    mask, strings = mask_literals(text)
    methods = method_spans(mask)

    builders = []
    for m in BUILDER.finditer(mask):
        opened = m.end() - 1
        method = enclosing_method(methods, m.start())
        builders.append(Builder(m.start(), opened, statement_end(mask, opened), method[2] if method else "<none>"))
    spans = [Span(b.start, b.end, b) for b in builders]
    spans.extend(variable_spans(mask, builders, methods))

    def breach(builder, rule, label):
        found["\t".join((name, builder.method, rule, key_text(label)))] += 1

    unresolved = 0
    for m in BUTTON.finditer(mask):
        opened = m.end() - 1
        holders = owners(spans, opened)
        if not holders:
            continue
        closed = close_paren(mask, opened)
        if closed is None:
            continue
        expression = text[opened + 1:first_argument_end(mask, opened, closed)].strip()
        kind, label = resolve_label(expression, constants)
        for holder in holders:
            if kind == "unresolved":
                unresolved += 1
                continue
            if kind == "android" or label.strip().casefold() in OK_OR_CANCEL:
                breach(holder.builder, "R1", label)
            if kind == "constant" and "&" in label:
                breach(holder.builder, "R2", label)
            if m.group(1) == "setPositiveButton" and is_destructive(label):
                breach(holder.builder, "R3", label)

    for start, end in strings:
        value = decode_literal(text[start:end])
        if "&" not in value:
            continue
        for holder in owners(spans, start):
            breach(holder.builder, "R2", value)
    return len(builders), unresolved


def load_baseline(path):
    baseline = collections.Counter()
    for number, line in enumerate(read(path).splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 5 or not fields[4].isdigit() or int(fields[4]) < 1:
            die("%s:%d: a line is <file> TAB <method> TAB <rule> TAB <label> TAB <count>" % (path, number))
        key = "\t".join(fields[:4])
        if key in baseline:
            die("%s:%d: the key occurs twice" % (path, number))
        baseline[key] = int(fields[4])
    return baseline


def check_verbs(src_dir):
    """A message when PopupSheet.java disagrees with this scanner's verbs, else None."""
    path = os.path.join(src_dir, "PopupSheet.java")
    if not os.path.isfile(path):
        print("PopupSheet.java absent: verb list not cross-checked")
        return None
    m = VERB_LIST.search(strip_comments(read_java(path)))
    if not m:
        return "VERBS differ: no DESTRUCTIVE_VERBS list found in PopupSheet.java"
    theirs = sorted(decode_literal(v) for v in STRING_LITERAL.findall(m.group(1)))
    ours = sorted(DESTRUCTIVE_VERBS)
    if theirs != ours:
        return "VERBS differ: missing from PopupSheet.java %s, extra in PopupSheet.java %s" % (
            sorted(set(ours) - set(theirs)), sorted(set(theirs) - set(ours)))
    return None


def main():
    src_dir, baseline_path = os.environ["SRC_DIR"], os.environ["BASELINE"]
    baseline = load_baseline(baseline_path)
    found = collections.Counter()
    constants = Constants(src_dir)
    builders = unresolved = 0
    for name in FILES:
        counted, labels = scan_file(name, src_dir, constants, found)
        builders += counted
        unresolved += labels

    print("builders found: %d" % builders)
    for rule in ("R1", "R2", "R3"):
        print("rule %s: %d" % (rule, sum(c for k, c in found.items() if k.split("\t")[2] == rule)))
    for name in FILES:
        print("file %s: %d" % (name, sum(c for k, c in found.items() if k.split("\t")[0] == name)))
    print("UNRESOLVED: %d" % unresolved)

    failures = []
    for key in sorted(found):
        if found[key] > baseline[key]:
            failures.append("NEW: %s (baseline %d, found %d)" % (key, baseline[key], found[key]))
    for key in sorted(baseline):
        if found[key] < baseline[key]:
            failures.append("STALE: delete it: %s (baseline %d, found %d)" % (key, baseline[key], found[key]))
    if builders < FLOOR:
        failures.append("CONTROL: only %d builders found, expected at least %d" % (builders, FLOOR))
    verbs = check_verbs(src_dir)
    if verbs:
        failures.append(verbs)

    for failure in failures:
        print(failure)
    if failures:
        print("FAIL: popup rules: %d problem(s). Reword the dialog, or delete what the baseline no longer holds." % len(failures))
        return 1
    print("PASS: popup rules: no new breach, and the baseline matches the source")
    return 0


sys.exit(main())
PY

scan() { SRC_DIR="$1" BASELINE="$2" python3 -I "$3"; }

scan "$TREE_SRC" "$TREE_BASELINE" "$W/scan.py"
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"
[ "$MUTATE" = yes ] || exit 0

echo "== mutants: each broken copy must FAIL with its named message"

cat > "$W/mut.py" <<'PY'
import re, sys


def load(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def save(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def die(message):
    print("mutation did not apply: " + message)
    sys.exit(1)


def method_region(text, method):
    m = re.search(r"\bvoid " + re.escape(method) + r"\(", text)
    if not m:
        die("no method " + method)
    end = text.find("\n    }\n", m.start())
    if end < 0:
        die("no end of method " + method)
    return m.start(), end


def builder_open_end(text, start, end):
    i = text.find("AlertDialog.Builder(", start, end)
    if i < 0:
        die("no builder in the method")
    close = text.find(")", i)
    return close + 1


op, path = sys.argv[1], sys.argv[2]
args = sys.argv[3:]
text = load(path)

if op == "chain":               # chain FILE METHOD CODE: add CODE to the method's first builder
    start, end = method_region(text, args[0])
    at = builder_open_end(text, start, end)
    text = text[:at] + "\n" + args[1] + text[at:]
elif op == "in-method":         # in-method FILE METHOD OLD NEW: replace the one OLD inside METHOD
    start, end = method_region(text, args[0])
    region = text[start:end]
    if region.count(args[1]) != 1:
        die("%r occurs %d times in %s" % (args[1], region.count(args[1]), args[0]))
    text = text[:start] + region.replace(args[1], args[2]) + text[end:]
elif op == "every-builder":     # every-builder FILE METHOD COUNT CODE: add CODE to every builder of METHOD
    start, end = method_region(text, args[0])
    region = text[start:end]
    needle = "AlertDialog.Builder(this)"
    if region.count(needle) != int(args[1]):
        die("%d builders in %s" % (region.count(needle), args[0]))
    text = text[:start] + region.replace(needle, needle + "\n" + args[2]) + text[end:]
elif op == "once":              # once FILE OLD NEW: replace the one OLD in the file
    if text.count(args[0]) != 1:
        die("%r occurs %d times" % (args[0], text.count(args[0])))
    text = text.replace(args[0], args[1])
elif op == "all":               # all FILE OLD NEW: replace every OLD in the file
    if args[0] not in text:
        die("%r is absent" % args[0])
    text = text.replace(args[0], args[1])
elif op == "member":            # member FILE CODE: add CODE before the class's last brace
    at = text.rfind("}")
    if at < 0:
        die("no closing brace")
    text = text[:at] + args[0] + "\n" + text[at:]
elif op == "cut":               # cut FILE START END: delete from START through the first END after it
    a = text.find(args[0])
    b = text.find(args[1], a) if a >= 0 else -1
    if a < 0 or b < 0:
        die("anchors absent")
    text = text[:a] + text[b + len(args[1]):]
else:
    die("unknown operation " + op)
save(path, text)
PY

C="$W/copy"
FAILS=0
APPLIED=yes
OUT=
T=$'\t'
ACTIVITIES="ChooserActivity.java ProfileActivity.java PrivateDnsPromptActivity.java PrivateDnsWatch.java"
CONSTANTS="PresetPicker.java PrivateDnsDowngrade.java WalletRepairCopy.java PlayChoice.java BuildWarningNotice.java GateHelpHome.java"
PS="ProfileActivity.java"
SIGNOUT="confirmSignOutAndInstall"
VERBS='"Delete", "Erase", "Wipe", "Remove", "Discard", "Unbind", "Clear", "Reset", "Forget", "Leave", "Uninstall"'

bad() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }

fresh() {
  local f
  APPLIED=yes
  rm -rf "$C"
  mkdir -p "$C" || { bad "cannot make the copy"; APPLIED=no; return; }
  for f in $ACTIVITIES $CONSTANTS; do
    cp "$TREE_SRC/$f" "$C/$f" || { bad "cannot copy $f"; APPLIED=no; }
  done
  cp "$TREE_BASELINE" "$C/baseline.txt" || { bad "cannot copy the baseline"; APPLIED=no; }
  cp "$W/scan.py" "$C/scan.py" || { bad "cannot copy the scanner"; APPLIED=no; }
}

edit() {
  local msg
  msg=$(python3 -I "$W/mut.py" "$@") || { echo "$msg"; APPLIED=no; }
}

run_copy() { OUT=$(scan "$C" "$C/baseline.txt" "$C/scan.py" 2>&1); }

# convict <id> <exit status> <needle>...: the copy fails with that status and prints every needle.
convict() {
  local id="$1" want="$2" rc needle
  shift 2
  if [ "$APPLIED" != yes ]; then bad "$id: the mutant did not apply"; return; fi
  run_copy
  rc=$?
  if [ "$rc" -ne "$want" ]; then bad "$id: exit $rc, wanted $want"; echo "$OUT"; return; fi
  for needle in "$@"; do
    case "$OUT" in
      *"$needle"*) ;;
      *) bad "$id: the output lacks: $needle"; echo "$OUT"; return ;;
    esac
  done
  echo "CONVICTED $id"
}

# accept <id> [--lacks <text>]...: the copy passes.
accept() {
  local id="$1" rc
  shift
  if [ "$APPLIED" != yes ]; then bad "$id: the case did not apply"; return 1; fi
  run_copy
  rc=$?
  if [ "$rc" -ne 0 ]; then bad "$id: exit $rc, wanted 0"; echo "$OUT"; return 1; fi
  while [ "$#" -ge 2 ] && [ "$1" = --lacks ]; do
    case "$OUT" in
      *"$2"*) bad "$id: the output holds: $2"; echo "$OUT"; return 1 ;;
    esac
    shift 2
  done
  echo "ACCEPTED $id"
}

number_of() { printf '%s\n' "$OUT" | sed -n "s/^$1: //p"; }

fresh; accept P1-copy-matches-baseline
BUILDERS=$(number_of "builders found")
UNRESOLVED=$(number_of "UNRESOLVED")
case "$BUILDERS" in ''|*[!0-9]*) bad "P1: no builder count printed"; BUILDERS=0 ;; esac
case "$UNRESOLVED" in ''|*[!0-9]*) bad "P1: no UNRESOLVED count printed"; UNRESOLVED=0 ;; esac

fresh; edit chain "$C/$PS" "$SIGNOUT" '.setPositiveButton("OK", null)'
convict M1 1 "NEW: $PS$T$SIGNOUT${T}R1${T}OK (baseline 0, found 1)"

fresh; edit member "$C/PresetPicker.java" 'static final String M2_LABEL = "Cancel";'
edit chain "$C/$PS" "$SIGNOUT" '.setNegativeButton(PresetPicker.M2_LABEL, null)'
convict M2 1 "NEW: $PS$T$SIGNOUT${T}R1${T}Cancel (baseline 0, found 1)"

fresh; edit in-method "$C/$PS" "$SIGNOUT" '.setMessage(OtaUpdate.installConfirm(local))' '.setMessage("Wi-Fi & data")'
convict M3 1 "NEW: $PS$T$SIGNOUT${T}R2${T}Wi-Fi & data (baseline 0, found 1)"

fresh; edit chain "$C/$PS" "$SIGNOUT" '.setPositiveButton("Delete all", null)'
convict M4 1 "NEW: $PS$T$SIGNOUT${T}R3${T}Delete all (baseline 0, found 1)"

fresh; edit in-method "$C/$PS" confirmRollback '.setNegativeButton("Cancel"' '.setNegativeButton("Not now"'
convict M5 1 "STALE: delete it: $PS${T}confirmRollback${T}R1${T}Cancel (baseline 1, found 0)"

fresh; edit chain "$C/$PS" "$SIGNOUT" '// "OK & more"'
edit once "$C/scan.py" 'text = strip_comments(raw)' 'text = raw'
convict M6 1 "NEW: $PS$T$SIGNOUT${T}R2${T}OK & more"

fresh
for f in $ACTIVITIES; do edit all "$C/$f" 'AlertDialog.Builder(' 'AlertDialog.Bilder('; done
convict M7 1 "CONTROL: only 0 builders found, expected at least 50"

# The gate Help page is in scope: its Back label resolves through GateHelpHome.BACK, and no exemption hides it.
fresh; edit once "$C/GateHelpHome.java" 'static final String BACK = "Back";' 'static final String BACK = "Cancel";'
convict M8-the-gate-help-page-is-scanned 1 "NEW: ChooserActivity.java${T}showGateHelpPage${T}R1${T}Cancel (baseline 0, found 1)"

fresh; edit once "$C/scan.py" 'declarations = [m for m in VARIABLE.finditer(mask)]' 'declarations = []'
convict M9 1 "STALE: delete it: ChooserActivity.java${T}showCreateOverColdLock${T}R1${T}OK" \
             "STALE: delete it: ChooserActivity.java${T}showCreateOverColdLock${T}R1${T}Cancel"

fresh; edit once "$C/scan.py" 'return inside[:1]' 'return inside'
convict M10 1 "NEW: $PS${T}confirmRemoveKey${T}R1${T}Cancel"

fresh; printf 'final class PopupSheet { static final java.util.List<String> DESTRUCTIVE_VERBS = Collections.unmodifiableList(Arrays.asList(%s)); }\n' "$VERBS" > "$C/PopupSheet.java"
convict M11 1 "VERBS differ: missing from PopupSheet.java ['Drop']"

fresh; edit member "$C/PresetPicker.java" 'static final String M12_LABEL = "Back & forth";'
edit chain "$C/$PS" "$SIGNOUT" '.setNeutralButton(PresetPicker.M12_LABEL, null)'
convict M12 1 "NEW: $PS$T$SIGNOUT${T}R2${T}Back & forth (baseline 0, found 1)"

fresh; edit chain "$C/$PS" "$SIGNOUT" '.setPositiveButton(android.R.string.ok, null)'
convict M13 1 "NEW: $PS$T$SIGNOUT${T}R1${T}android.R.string.ok (baseline 0, found 1)"

fresh; edit chain "$C/$PS" "$SIGNOUT" '.setNeutralButton(" okay ", null)'
convict M14 1 "NEW: $PS$T$SIGNOUT${T}R1$T okay  (baseline 0, found 1)"

fresh; : > "$C/baseline.txt"
convict M15-empty-baseline 1 "NEW: $PS$T$SIGNOUT${T}R2${T}Sign out & install (baseline 0, found 1)"

fresh; edit chain "$C/$PS" confirmRollback '.setNegativeButton("Cancel", null)'
convict M16-above-its-count 1 "NEW: $PS${T}confirmRollback${T}R1${T}Cancel (baseline 1, found 2)"

fresh; edit once "$C/baseline.txt" "$PS${T}confirmRollback${T}R1${T}Cancel${T}1" "$PS${T}confirmRollback${T}R1${T}Cancel${T}2"
convict M17-fewer-than-its-count 1 "STALE: delete it: $PS${T}confirmRollback${T}R1${T}Cancel (baseline 2, found 1)"

fresh; printf 'one field only\n' >> "$C/baseline.txt"
convict M18-malformed-baseline 2 "a line is <file> TAB <method> TAB <rule> TAB <label> TAB <count>"

# The rules judge a literal's value, so an escape spelling of a breach is still a breach.
fresh; edit chain "$C/$PS" "$SIGNOUT" '.setPositiveButton("\tOK\t", null)'
convict M19-escaped-label-R1 1 "NEW: $PS$T$SIGNOUT${T}R1$T\tOK\t (baseline 0, found 1)"

fresh; edit chain "$C/$PS" "$SIGNOUT" '.setPositiveButton("Wi-Fi \u0026 data", null)'
convict M20-unicode-label-R2 1 "NEW: $PS$T$SIGNOUT${T}R2${T}Wi-Fi & data (baseline 0, found 1)"

fresh; edit chain "$C/$PS" "$SIGNOUT" '.setPositiveButton("Delete\nall", null)'
convict M21-escaped-label-R3 1 "NEW: $PS$T$SIGNOUT${T}R3${T}Delete\nall (baseline 0, found 1)"

fresh; edit member "$C/PresetPicker.java" 'static final String M22_LABEL = "\u0043ancel";'
edit chain "$C/$PS" "$SIGNOUT" '.setNegativeButton(PresetPicker.M22_LABEL, null)'
convict M22-escaped-constant-R1 1 "NEW: $PS$T$SIGNOUT${T}R1${T}Cancel (baseline 0, found 1)"

fresh; edit member "$C/PresetPicker.java" 'static final String M23_LABEL = "Back \46 forth";'
edit chain "$C/$PS" "$SIGNOUT" '.setNeutralButton(PresetPicker.M23_LABEL, null)'
convict M23-octal-constant-R2 1 "NEW: $PS$T$SIGNOUT${T}R2${T}Back & forth (baseline 0, found 1)"

fresh; edit member "$C/PresetPicker.java" 'static final String M24_LABEL = "Erase\tall";'
edit chain "$C/$PS" "$SIGNOUT" '.setPositiveButton(PresetPicker.M24_LABEL, null)'
convict M24-escaped-constant-R3 1 "NEW: $PS$T$SIGNOUT${T}R3${T}Erase\tall (baseline 0, found 1)"

fresh; edit chain "$C/$PS" "$SIGNOUT" '.setTitle("A \uuu0026 B")'
convict M25-many-u-title-R2 1 "NEW: $PS$T$SIGNOUT${T}R2${T}A & B (baseline 0, found 1)"

# The same labels, listed in the baseline: with its decoding step gone, the scanner cannot find them.
fresh; edit chain "$C/$PS" "$SIGNOUT" '.setPositiveButton("\tOK\t", null)'
printf '%s\n' "$PS$T$SIGNOUT${T}R1$T\tOK\t${T}1" >> "$C/baseline.txt"
edit once "$C/scan.py" 'return STRING_ESCAPE.sub(unescape, literal[1:-1])' 'return literal[1:-1]'
convict M26-no-string-decoding 1 "STALE: delete it: $PS$T$SIGNOUT${T}R1$T\tOK\t (baseline 1, found 0)"

fresh; edit chain "$C/$PS" "$SIGNOUT" '.setPositiveButton("Wi-Fi \u0026 data", null)'
printf '%s\n' "$PS$T$SIGNOUT${T}R2${T}Wi-Fi & data${T}1" >> "$C/baseline.txt"
edit once "$C/scan.py" 'return UNICODE_ESCAPE.sub(translate_unicode, read(path))' 'return read(path)'
convict M27-no-unicode-translation 1 "STALE: delete it: $PS$T$SIGNOUT${T}R2${T}Wi-Fi & data (baseline 1, found 0)"

fresh; edit chain "$C/$PS" "$SIGNOUT" '.setPositiveButton("Delete\nall", null)'
printf '%s\n' "$PS$T$SIGNOUT${T}R3${T}Delete\nall${T}1" >> "$C/baseline.txt"
edit once "$C/scan.py" 'rule, key_text(label)))' 'rule, label))'
convict M28-raw-line-break-in-key 1 "STALE: delete it: $PS$T$SIGNOUT${T}R3${T}Delete\nall (baseline 1, found 0)"

fresh; edit member "$C/$PS" 'void addedCleanBuilder() { new android.app.AlertDialog.Builder(this).setTitle("Added").setPositiveButton("Got it", null).show(); }'
if accept P2-a-clean-builder-added; then
  [ "$(number_of "builders found")" -eq $((BUILDERS + 1)) ] || bad "P2: the printed builder count did not rise by one"
fi

fresh; edit cut "$C/PrivateDnsWatch.java" 'dialog = new AlertDialog.Builder(a)' '.show();'
if accept P3-a-clean-builder-removed; then
  [ "$(number_of "builders found")" -eq $((BUILDERS - 1)) ] || bad "P3: the printed builder count did not fall by one"
fi

fresh; edit chain "$C/$PS" "$SIGNOUT" '// "OK & more"'
accept P4-a-comment-does-not-count

fresh; edit every-builder "$C/ChooserActivity.java" showGateHelpPage 1 '.setPositiveButton("Got it", null)'
accept P5-the-gate-help-page-is-clean --lacks "showGateHelpPage"

fresh; printf 'final class PopupSheet { static final java.util.List<String> DESTRUCTIVE_VERBS = Collections.unmodifiableList(Arrays.asList(%s, "Drop")); }\n' "$VERBS" > "$C/PopupSheet.java"
accept P6-the-same-verbs-pass --lacks "VERBS differ" --lacks "PopupSheet.java absent"

fresh; edit chain "$C/$PS" "$SIGNOUT" '.setNeutralButton(someLabel, null)'
if accept P7-a-variable-label-is-unresolved; then
  [ "$(number_of "UNRESOLVED")" -eq $((UNRESOLVED + 1)) ] || bad "P7: UNRESOLVED did not rise by one"
fi

fresh; edit chain "$C/$PS" "$SIGNOUT" '.setTitle("Back \\u0026 forth")'
accept P8-an-escaped-backslash-is-no-ampersand --lacks "${T}R2${T}Back"

# Keys with a tab, a line break and a character that Python's splitlines() breaks on stay one baseline line each.
fresh; edit chain "$C/$PS" "$SIGNOUT" '.setPositiveButton("\tOK\t", null).setPositiveButton("Delete\nall", null).setPositiveButton("Delete\u2028all", null)'
printf '%s\n' "$PS$T$SIGNOUT${T}R1$T\tOK\t${T}1" "$PS$T$SIGNOUT${T}R3${T}Delete\nall${T}1" "$PS$T$SIGNOUT${T}R3${T}Delete\u2028all${T}1" >> "$C/baseline.txt"
accept P9-escaped-keys-round-trip-through-the-baseline

if [ "$FAILS" -ne 0 ]; then
  echo "FAIL: $FAILS mutant or control case(s) wrong"
  exit 1
fi
echo "PASS: every mutant convicted, every control accepted"
