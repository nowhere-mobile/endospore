#!/usr/bin/env bash
# test-default-apps-edition-list.sh -- NWP-20261013-43. The secondary-user gate's --edition filter.
#
# WHY. test-default-apps-secondary-user.sh with no arguments tests every manifest row, Fennec included, which
# Endospore does not bake, so the gate failed on Endospore by design and a release could not run it as written.
# `--edition ED --list` resolves the edition's set from editions/ED/ED.mk (every PRODUCT_PACKAGES += block) and
# the manifest, with no adb, so it is checkable here against the real files:
#   - Endospore holds Thunderbird and Etar and NOT Fennec; Diaspore holds Fennec;
#   - an unknown edition exits 2;
#   - the list is exactly the manifest rows whose module is listed in the mk (recomputed independently).
#
# --mutate re-runs against broken copies of the gate, each of which must FAIL: the edition filter ignored, and
# only the first PRODUCT_PACKAGES block read. A mutant that does not apply counts as a failure.
#
# Run from anywhere:  bash core/vendor-common/prebuilts/test-default-apps-edition-list.sh [--mutate]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
GATE="$HERE/test-default-apps-secondary-user.sh"
MANIFEST="$HERE/default-apps.manifest"
[ -r "$GATE" ] && [ -r "$MANIFEST" ] || { echo "cannot read gate or manifest" >&2; exit 2; }

# check <gate-script> : 0 when every assertion holds
check() {
  local gate="$1" bad=0 e endo dia rc want
  endo="$(bash "$gate" --edition endospore --list 2>&1)"; rc=$?
  [ "$rc" = 0 ] || { echo "  FAIL endospore --list exited $rc"; bad=1; }
  dia="$(bash "$gate" --edition diaspore --list 2>&1)"; rc=$?
  [ "$rc" = 0 ] || { echo "  FAIL diaspore --list exited $rc"; bad=1; }
  for p in net.thunderbird.android ws.xsoh.etar; do
    grep -qxF "$p" <<<"$endo" || { echo "  FAIL endospore list lacks $p"; bad=1; }
  done
  if grep -qxF org.mozilla.fennec_fdroid <<<"$endo"; then echo "  FAIL endospore list holds Fennec"; bad=1; fi
  grep -qxF org.mozilla.fennec_fdroid <<<"$dia" || { echo "  FAIL diaspore list lacks Fennec"; bad=1; }
  # Independent oracle: tokens of every PRODUCT_PACKAGES block, joined against the manifest.
  for e in endospore diaspore; do
    want="$(python3 -I - "$ROOT/editions/$e/$e.mk" "$MANIFEST" <<'PY'
import re, sys
mods, on = set(), False
for line in open(sys.argv[1]):
    line = line.split('#')[0].rstrip()
    if re.match(r'\s*PRODUCT_PACKAGES\s*\+=', line):
        on, line = True, line.split('=', 1)[1]
    if on:
        cont = line.endswith('\\')
        mods.update(line.rstrip('\\').split())
        on = cont
for line in open(sys.argv[2]):
    f = line.split('#')[0].split()
    if f and f[0] in mods:
        print(f[1])
PY
)"
    got="$endo"; [ "$e" = diaspore ] && got="$dia"
    [ "$got" = "$want" ] || { echo "  FAIL $e list differs from the manifest-by-mk oracle"; bad=1; }
  done
  bash "$gate" --edition nonesuch --list >/dev/null 2>&1; rc=$?
  [ "$rc" = 2 ] || { echo "  FAIL unknown edition exited $rc, want 2"; bad=1; }
  return $bad
}

if [ "${1:-}" != "--mutate" ]; then
  if check "$GATE"; then echo "PASS: edition list"; exit 0; fi
  echo "FAIL: edition list"; exit 1
fi

if ! check "$GATE" >/dev/null; then echo "FAIL: the unmutated gate does not pass"; exit 1; fi
MUT="$HERE/.mutant-$$.sh"
trap 'rm -f "$MUT"' EXIT
fail=0
mutant() {   # <label> <sed expr>
  sed -e "$2" "$GATE" > "$MUT"
  if cmp -s "$GATE" "$MUT"; then echo "  FAIL mutant '$1' did not apply"; fail=1; return; fi
  if check "$MUT" >/dev/null 2>&1; then echo "  FAIL mutant '$1' SURVIVED"; fail=1; else echo "  ok   mutant '$1' convicted"; fi
}
mutant "edition filter ignored" 's/if \[ -n "\$EDITION" \] && ! grep -qxF/if false \&\& ! grep -qxF/'
mutant "only the first PRODUCT_PACKAGES block" 's/if (!c) on = 0 }/if (!c) { on = 0; exit } }/'
[ "$fail" = 0 ] && echo "PASS: all mutants convicted" || echo "FAIL: a mutant survived"
exit $fail
