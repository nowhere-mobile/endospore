#!/usr/bin/env bash
# test-profile-recents.sh [--mutate] -- Profile shows in Recents; its recovery-code screen is FLAG_SECURE (NWP-20261203-20).
#
# WHY THIS IS COMMITTED. The row "The Profile app closes on Back from any screen and never shows in recent apps",
# part (3), decided by docs/product-decisions.md 2026-11-05 h59 #6: the Profile app shows in Recents, and the screen
# that shows a recovery code keeps it out of the thumbnail (FLAG_SECURE). The manifest excluded ProfileActivity from
# Recents. Source checks (comments stripped) over ProfileActivity.java and the manifest:
#   R1 ProfileActivity's element has no excludeFromRecents; the gate's (ChooserActivity) still has it "true";
#   R2 showRecovery sets `pendingSecure = true;` before its setContentView(sc), and nothing else sets it true;
#   R3 the setContentView override reads pendingSecure, resets it to false, adds FLAG_SECURE when it was set and
#      clears FLAG_SECURE otherwise, all before super.setContentView(view);
#   R4 (keep) each sign-out block still drops its task from Recents at runtime after `loggingOff = true;`, and
#      onUserLeaveHint still re-fronts the screen while loggingOff.
# Pins are per element and per method, never a manifest-wide count of excludeFromRecents.
#
# ⚠ IT FAILS WHEN THERE IS NO PYTHON3 (AND, FOR --mutate, NO PERL). IT NEVER SKIPS.
#
#   bash test-profile-recents.sh            # the source checks
#   bash test-profile-recents.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
PROFILE="${PROFILE_ACTIVITY_SRC:-$root/core/chooser/src/com/nowhere/chooser/ProfileActivity.java}"
MANIFEST="${CHOOSER_MANIFEST:-$root/core/chooser/AndroidManifest.xml}"

command -v python3 >/dev/null 2>&1 || {
  echo "FAIL: no python3 -- this suite does not skip: install python3 or run it on the build VM." >&2; exit 2; }

CHK=$(mktemp -p "$W" recents.XXXXXX.py) || exit 2
cat > "$CHK" <<'PY'
import re, sys

def strip(src):
    # Drop /* */ and // comments outside string and char literals; keep every newline so line order holds.
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if c in '"\'':
            q = c; j = i + 1
            while j < n and src[j] != q:
                j += 2 if src[j] == '\\' else 1
            out.append(src[i:j + 1]); i = j + 1
        elif src.startswith('//', i):
            j = src.find('\n', i)
            i = n if j < 0 else j
        elif src.startswith('/*', i):
            j = src.find('*/', i + 2)
            j = n if j < 0 else j + 2
            out.append('\n' * src.count('\n', i, j)); i = j
        else:
            out.append(c); i += 1
    return ''.join(out)

def method(src, sig):
    # From the first line holding sig to the first following line that is exactly "    }"; "" when absent.
    lines = src.split('\n')
    for k, l in enumerate(lines):
        if sig in l:
            for e in range(k + 1, len(lines)):
                if lines[e] == '    }':
                    return '\n'.join(lines[k:e + 1])
            return ''
    return ''

def element(mf, name):
    m = re.search(r'<activity android:name="\.' + re.escape(name) + r'"[^>]*>', mf, re.S)
    return m.group(0) if m else ''

pa = strip(open(sys.argv[1], encoding='utf-8').read())
mf = re.sub(r'<!--.*?-->', '', open(sys.argv[2], encoding='utf-8').read(), flags=re.S)
bad = []

# R1 per element.
pe, ce = element(mf, 'ProfileActivity'), element(mf, 'ChooserActivity')
if not pe:
    bad.append('R1 no ProfileActivity element in the manifest')
elif 'excludeFromRecents' in pe:
    bad.append('R1 ProfileActivity still carries excludeFromRecents (h59 #6: it shows in Recents)')
if not ce:
    bad.append('R1 no ChooserActivity element in the manifest')
elif 'android:excludeFromRecents="true"' not in ce:
    bad.append('R1 ChooserActivity lost excludeFromRecents="true" (the gate stays out of Recents)')

# R2 showRecovery is the one setter.
sr = method(pa, 'private void showRecovery(String words)')
set_re = re.compile(r'pendingSecure\s*=\s*true\s*;')
if not sr:
    bad.append('R2 no showRecovery(String words) in ProfileActivity')
else:
    m = set_re.search(sr); s = sr.find('setContentView(sc);')
    if not m or s < 0 or m.start() > s:
        bad.append('R2 showRecovery does not set pendingSecure = true; before its setContentView(sc)')
n = len(set_re.findall(pa))
if n != 1:
    bad.append('R2 %d pendingSecure = true; in ProfileActivity, want 1 (showRecovery only)' % n)

# R3 the override consumes it.
scv = method(pa, 'public void setContentView(android.view.View view)')
if not scv:
    bad.append('R3 no setContentView(android.view.View) override in ProfileActivity')
else:
    sup = scv.find('super.setContentView(view);')
    def at(rx):
        m = re.search(rx, scv, re.M)
        return m.start() if m else -1
    rd = at(r'=\s*pendingSecure\s*;')
    rs = at(r'pendingSecure\s*=\s*false\s*;')
    ad = at(r'^[ \t]*if \(secure\)[^\n]*\.addFlags\((android\.view\.)?WindowManager\.LayoutParams\.FLAG_SECURE\)')
    cl = at(r'^[ \t]*else[^\n]*\.clearFlags\((android\.view\.)?WindowManager\.LayoutParams\.FLAG_SECURE\)')
    if sup < 0:
        bad.append('R3 the override does not call super.setContentView(view);')
    for what, o in (('read pendingSecure', rd), ('reset pendingSecure = false;', rs),
                    ('addFlags(FLAG_SECURE) under if (secure)', ad), ('clearFlags(FLAG_SECURE) under else', cl)):
        if o < 0 or (sup >= 0 and o > sup):
            bad.append('R3 the override does not %s before super.setContentView(view);' % what)
    if rd >= 0 and rs >= 0 and rs < rd:
        bad.append('R3 the override resets pendingSecure before it reads it')

# R4 keep: the sign-out's runtime Recents exclusion and the re-front.
for sig in ('private void doLogoffImpl(', 'private void doColdLock()'):
    b = method(pa, sig)
    lo = b.find('loggingOff = true;'); ex = b.find('setExcludeFromRecents(true)')
    if lo < 0 or ex < lo:
        bad.append('R4 %s no longer calls setExcludeFromRecents(true) after loggingOff = true;' % sig.split('(')[0])
ul = method(pa, 'protected void onUserLeaveHint()')
if not ('if (loggingOff)' in ul and 'startActivity(' in ul and 'FLAG_ACTIVITY_REORDER_TO_FRONT' in ul):
    bad.append('R4 onUserLeaveHint no longer re-fronts the screen while loggingOff')

for b in bad:
    print('  PIN   ' + b)
print('ok' if not bad else 'FAILED (%d)' % len(bad))
sys.exit(1 if bad else 0)
PY

# check <ProfileActivity.java> <AndroidManifest.xml> -> 0 when every pin holds, 1 when one fails, 2 the checker broke.
check() { python3 -I "$CHK" "$1" "$2"; }

echo "== $PROFILE"
echo "== $MANIFEST"
out=$(check "$PROFILE" "$MANIFEST" 2>&1); rc=$?
printf '%s\n' "$out"
[ "$rc" -eq 0 ] || { echo "FAILED (rc=$rc)"; exit 1; }
echo "PASS"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED by the check it names -- a mutant that does not apply proves nothing)"

# mut <label> <profile|manifest> <perl-expr> <check id> -> 0 when the named check convicts the mutant.
mut() {
  local label="$1" which="$2" expr="$3" want="$4" d orig c rc out pr="$PROFILE" mf="$MANIFEST"
  case "$which" in profile) orig="$PROFILE" ;; manifest) orig="$MANIFEST" ;; esac
  d=$(mktemp -d -p "$W") || return 1
  c="$d/$(basename "$orig")"
  cp "$orig" "$c"
  if ! perl -0pi -e "$expr" "$c"; then
    echo "  ERROR     $label -- perl failed on the mutation"; rm -rf "$d"; return 1
  fi
  if cmp -s "$orig" "$c"; then echo "  INERT     $label -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  case "$which" in profile) pr="$c" ;; manifest) mf="$c" ;; esac
  out=$(check "$pr" "$mf" 2>&1); rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $label"; return 1 ;;
    1) case "$out" in
         *"PIN   $want "*) echo "  CONVICTED $label"; return 0 ;;
         *) echo "  WRONG CHECK $label -- not convicted by $want:"; printf '%s\n' "$out"; return 1 ;;
       esac ;;
    *) echo "  BROKEN    $label -- the checker failed (rc=$rc):"; printf '%s\n' "$out"; return 1 ;;
  esac
}
fails=0
mut "M1 excludeFromRecents left on ProfileActivity (R1)" manifest \
  's/(<activity android:name="\.ProfileActivity"[^>]*?android:theme="\@style\/Theme\.Nowhere")/$1\n              android:excludeFromRecents="true"/s' \
  R1 || fails=$((fails+1))
mut "M2 excludeFromRecents removed from ChooserActivity too (R1)" manifest \
  's/(<activity android:name="\.ChooserActivity"[^>]*?)\n[ \t]*android:excludeFromRecents="true"/$1/s' R1 || fails=$((fails+1))
mut "M3 showRecovery does not set pendingSecure (R2)" profile 's/^[ \t]*pendingSecure = true;[^\n]*\n//m' R2 \
  || fails=$((fails+1))
mut "M4 the clearFlags arm removed, FLAG_SECURE stays set after the screen (R3)" profile \
  's/^[ \t]*else getWindow\(\)\.clearFlags\([^\n]*FLAG_SECURE\);\n//m' R3 || fails=$((fails+1))
mut "M5 pendingSecure never reset (R3)" profile 's/^[ \t]*pendingSecure = false;\n//m' R3 || fails=$((fails+1))
mut "M6 the addFlags arm removed (R3)" profile \
  's/if \(secure\) getWindow\(\)\.addFlags\([^;]*FLAG_SECURE\);/if (secure) { }/' R3 || fails=$((fails+1))
mut "M7 sign-out's setExcludeFromRecents(true) removed (R4)" profile \
  's/^[ \t]*for \(android\.app\.ActivityManager\.AppTask t : am\.getAppTasks\(\)\) t\.setExcludeFromRecents\(true\);\n//m' \
  R4 || fails=$((fails+1))
mut "M8 showRecovery sets pendingSecure after its setContentView(sc) (R2)" profile \
  's/^([ \t]*pendingSecure = true;[^\n]*\n)([ \t]*setContentView\(sc\);\n)/$2$1/m' R2 || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
