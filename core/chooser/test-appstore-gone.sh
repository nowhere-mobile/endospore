#!/usr/bin/env bash
# test-appstore-gone.sh [<ProfileActivity.java>] [--mutate] -- the in-chooser nApps copy stays deleted (NWP-20261013-38).
#
# The storefront is com.nowhere.napps since DIA-20260818-08 (#747); the chooser's own copy (showAppStore and its
# chain) had no caller and duplicated the live screen. Pinned, in CODE only (comments and string literals are
# blanked first, so a comment may still name a deleted member):
#   * none of the deleted names appears as an identifier in ProfileActivity.java;
#   * the members that live screens share are still declared: presentMenuScreen, dispName, showOverPlanDialog,
#     showSideloadWarning, daemonLenReply;
#   * braces balance.
# ProfileActivity's other users of these names are other classes' own copies (StoreInstaller, StoreService) and
# are not scanned. --mutate re-inserts a declaration, a call and a field, and breaks a brace; each must fail.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/src/com/nowhere/chooser/ProfileActivity.java"
MUTATE=no
for a in "$@"; do
  case "$a" in --mutate) MUTATE=yes ;; *) SRC="$a" ;; esac
done
[ -f "$SRC" ] || { echo "FAIL: $SRC not found"; exit 1; }
command -v python3 >/dev/null || { echo "FAIL: python3 required"; exit 1; }

check() { # $1 = file; prints problems, exit 1 if any
python3 - "$1" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
out, i, n = [], 0, len(s)
while i < n:
    c = s[i]
    if s.startswith('//', i):
        while i < n and s[i] != '\n': i += 1
    elif s.startswith('/*', i):
        j = s.find('*/', i + 2); j = n if j < 0 else j + 2
        out.append('\n' * s.count('\n', i, j)); i = j
    elif s.startswith('"""', i):
        j = s.find('"""', i + 3); j = n if j < 0 else j + 3
        out.append('""' + '\n' * s.count('\n', i, j)); i = j
    elif c in '"\'':
        j = i + 1
        while j < n and s[j] != c:
            j += 2 if s[j] == '\\' else 1
        out.append(c + c); i = j + 1
    else:
        out.append(c); i += 1
code = ''.join(out)
bad = 0
gone = """showAppStore renderCatalog catalogRow paintStoreAction onGetApp loadCatalogIcon getCatalogJson
searchAppsJson refreshCatalog refreshIndex catalogSub showGetModeDialog getAppInMode fetchApp installStagedApk
stagedSignerMatches sha256hex installedVc showPlayNotice openInAurora storeToast decodeDataUriBitmap
fetchIconBitmap ICON_CACHE""".split()
for g in gone:
    m = re.search(r'\b' + g + r'\b', code)
    if m:
        print('deleted name back: %s (line %d)' % (g, code.count('\n', 0, m.start()) + 1)); bad = 1
for k in 'presentMenuScreen dispName showOverPlanDialog showSideloadWarning daemonLenReply'.split():
    if not re.search(r'^\s+(private|public|static|final)[^;=()]*\b' + k + r'\s*\(', code, re.M):
        print('kept member not declared: ' + k); bad = 1
if code.count('{') != code.count('}'):
    print('braces unbalanced: %d { vs %d }' % (code.count('{'), code.count('}'))); bad = 1
sys.exit(bad)
PY
}

FAILS=0
if out=$(check "$SRC"); then echo "PASS: the in-chooser store stays deleted; shared members kept; braces balance"
else echo "FAIL: $out"; FAILS=1; fi

if [ "$MUTATE" = yes ]; then
  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  mut() { # name, python replace expr applied to text `s`
    python3 - "$SRC" "$T/m.java" "$2" <<'PY' || { echo "FAIL: mutant $1 did not apply"; FAILS=1; return; }
import sys
s = open(sys.argv[1]).read(); t = s
exec(sys.argv[3])
if t == s: sys.exit(1)
open(sys.argv[2], 'w').write(t)
PY
    if out=$(check "$T/m.java"); then echo "FAIL: mutant $1 NOT convicted"; FAILS=1
    else echo "PASS: mutant $1 convicted"; fi
  }
  mut showAppStore-decl "t = s.replace('    private void presentMenuScreen', '    private void showAppStore() { }\n    private void presentMenuScreen', 1)"
  mut helper-decl "t = s.replace('    private void presentMenuScreen', '    private static String sha256hex(byte[] b) { return \"\"; }\n    private void presentMenuScreen', 1)"
  mut field "t = s.replace('    private void presentMenuScreen', '    private static final int ICON_CACHE = 0;\n    private void presentMenuScreen', 1)"
  mut call "t = s.replace('    private void presentMenuScreen', '    private void x() { storeToast(\"a\"); }\n    private void presentMenuScreen', 1)"
  mut kept-removed "import re; t = re.sub(r'private String dispName\\(', 'private String dispNam(', s, count=1)"
  mut brace "t = s.replace('    private void presentMenuScreen', '    private void x() {\n    private void presentMenuScreen', 1)"
fi
exit $FAILS
