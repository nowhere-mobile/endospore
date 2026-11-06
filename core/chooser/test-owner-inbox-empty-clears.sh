#!/usr/bin/env bash
# test-owner-inbox-empty-clears.sh [<ChooserActivity.java>] [--mutate] -- opening an EMPTY owner inbox clears the
# unassigned-line gate notice (NWP-20261017-32, made live by NWP-20261128-12).
#
# WHY COMMITTED. buildOwnerInboxScreen cancelled the gate notice only after `shown == 0` had returned, so a notice
# left by a dropped arrival (no kept item) survived the owner opening the inbox. NWP-20261017-32 added a clear for an
# OK reply with no row, but the daemon answers an empty inbox NONE, so that clear never ran. Since NWP-20261128-12
# the EMPTY arm of the switch on OwnerInboxReply.of (NONE, or a bare OK) cancels the UNBOUND_LINE notice off the UI
# thread. The FAILED arm (no answer, a cut-short read, ERR request, DENIED) clears nothing; an OK reply whose rows all
# fail inboxDecode is not empty and clears nothing.
#
# SOURCE CHECKS, not a JVM run: the decision is inline in a UI callback and this sandbox has no JDK to run a lifted
# helper under; the structure is pinned on the method body instead.
#
#   bash test-owner-inbox-empty-clears.sh            # the checks
#   bash test-owner-inbox-empty-clears.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail
SUT="$(dirname "$0")/src/com/nowhere/chooser/ChooserActivity.java"
MUTATE=0
for a in "$@"; do case "$a" in --mutate) MUTATE=1 ;; *) SUT="$a" ;; esac; done
[ -f "$SUT" ] || { echo "no such file: $SUT" >&2; exit 2; }
command -v python3 >/dev/null || { echo "python3 not on PATH"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

check() { # check <ChooserActivity.java> -> prints ok/FAIL lines, exit 1 on any FAIL
  python3 - "$1" <<'PY'
import io, re, sys
src = io.open(sys.argv[1], encoding='utf-8').read()
i = src.find('private View buildOwnerInboxScreen()')
if i < 0:
    print('  FAIL  buildOwnerInboxScreen not found'); sys.exit(1)
j = src.index('{', i); depth = 0
for k in range(j, len(src)):
    if src[k] == '{': depth += 1
    elif src[k] == '}':
        depth -= 1
        if depth == 0: break
m = src[i:k+1]
fails = 0
def ok(name, cond):
    global fails
    if cond: print('  ok    ' + name)
    else: fails += 1; print('  FAIL  ' + name)
def arm(text, head, nxt):
    a = text.find(head)
    if a < 0: return None
    b = text.find(nxt, a + len(head))
    return None if b < 0 else text[a:b]
def block(text, head):
    a = text.find(head)
    if a < 0: return None
    b = text.index('{', a); d = 0
    for n in range(b, len(text)):
        if text[n] == '{': d += 1
        elif text[n] == '}':
            d -= 1
            if d == 0: return text[a:n+1]
    return None
CANCEL = 'cancelTelNotices(java.util.Collections.singleton(SmsDeliverReceiver.UNBOUND_LINE))'
failed = arm(m, 'case OwnerInboxReply.FAILED:', 'case OwnerInboxReply.EMPTY:')
nullreq = block(m, 'if (req == null)')
empty = arm(m, 'case OwnerInboxReply.EMPTY:', 'default:')
shown0 = block(m, 'if (shown == 0)')
ok('failed-read branch present', failed is not None)
ok('failed-read branch clears nothing', failed is not None and 'cancelTelNotices' not in failed)
ok('req == null branch clears nothing', nullreq is not None and 'cancelTelNotices' not in nullreq)
ok('confirmed-empty arm (NONE, or OK with zero rows) present', empty is not None)
ok('confirmed-empty arm cancels UNBOUND_LINE off the UI thread',
   empty is not None and 'new Thread(() -> ' + CANCEL + ').start();' in empty)
ok('confirmed-empty arm still shows the empty copy', empty is not None and 'OwnerInboxReply.EMPTY_LINE' in empty)
ok('confirmed-empty arm follows the failed-read arm and precedes the row loop',
   failed is not None and empty is not None and m.find(failed) < m.find(empty) < m.find('inboxDecode(lines.get(i))'))
ok('rows that all fail inboxDecode (shown == 0) clear nothing', shown0 is not None and 'cancelTelNotices' not in shown0)
ok('open-time cancel with rows is unchanged (after shown == 0)',
   shown0 is not None and ('new Thread(() -> ' + CANCEL + ').start();') in m[m.find(shown0)+len(shown0):])
ok('never cancels all lines (no null argument)', 'cancelTelNotices(null)' not in m)
ok('exactly three cancels: empty, open, Clear all', m.count('cancelTelNotices(') == 3 and m.count(CANCEL) == 3)
sys.exit(1 if fails else 0)
PY
}

echo "== real source"
check "$SUT"; rc=$?
[ "$MUTATE" = 1 ] || exit $rc
[ "$rc" = 0 ] || { echo "real source fails; mutations are meaningless"; exit 1; }

CANCEL='cancelTelNotices(java.util.Collections.singleton(SmsDeliverReceiver.UNBOUND_LINE))'
mutant() { # mutant <name> <python-expr transforming s>
  python3 - "$SUT" "$WORK/M.java" "$2" <<'PY'
import io, sys
s = io.open(sys.argv[1], encoding='utf-8').read()
t = eval(sys.argv[3])
if t == s: sys.exit(3)
io.open(sys.argv[2], 'w', encoding='utf-8').write(t)
PY
  case $? in 0) ;; *) echo "  FAIL  mutant '$1' did not apply"; return 1 ;; esac
  out="$(check "$WORK/M.java")"; r=$?
  if [ "$r" = 0 ]; then echo "  FAIL  mutant '$1' SURVIVED"; return 1; fi
  echo "  ok    mutant '$1' convicted"; return 0
}
echo "== mutants"
bad=0
NT="new Thread(() -> $CANCEL).start();"
mutant 'cancel added to the failed-read arm' \
  "s.replace('case OwnerInboxReply.FAILED:\n                        StatusLine.error', 'case OwnerInboxReply.FAILED:\n                        $NT StatusLine.error',1)" || bad=1
mutant 'cancel removed from the empty arm' \
  "s.replace('                        $NT\n                        status.setText(OwnerInboxReply.EMPTY_LINE)', '                        status.setText(OwnerInboxReply.EMPTY_LINE)',1)" || bad=1
mutant 'cancel called with null (all lines)' \
  "s.replace('$NT\n                        status.setText', 'new Thread(() -> cancelTelNotices(null)).start();\n                        status.setText',1)" || bad=1
mutant 'cancel fired when rows exist but none decoded' \
  "s.replace('if (shown == 0) { StatusLine.error', 'if (shown == 0) { $NT StatusLine.error',1)" || bad=1
exit $bad
