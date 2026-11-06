#!/usr/bin/env bash
# test-media-apk-eager.sh [--mutate] -- runs media_apk_eager_test.go with the media tier tests (NWP-20261123-13, h53 #5):
# a package file (.apk, .apks, .xapk, .apkm) in an app's private storage -- Android/data/<pkg>/ or a CE <pkg>/ tree --
# is never deferred, at both layers (classifyDeferred and classifyTier); Download and Android/media still defer.
# --mutate re-runs it against a COPY of the package with each guard broken in turn; the tree is never touched. Each
# mutant must be CONVICTED by a real `--- FAIL`; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
. ./suite-report.sh
RUN=(go test -count=1 -timeout 300s -run 'MediaApkEager|ClassifyDeferred|ClassifyTier|MediaTier' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <file> <python expression over s that returns the mutated text, or None when it does not apply>
  local label=$1 file=$2 expr=$3 P res mrc
  P=$(mktemp -d -p "$W") || { fails=$((fails+1)); return; }
  cp -a . "$P/agent" && rm -f "$P"/agent/*.orig
  if ! (cd "$P/agent" && python3 - "$file" "$expr" <<'PY'
import re, sys
p, expr = sys.argv[1:3]
s = open(p).read()
n = eval(expr)
if n is None or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
  ); then echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); rm -rf "$P"; return; fi
  res=$(cd "$P/agent" && "${RUN[@]}" 2>&1); mrc=$?
  score_mutant "$label" "$mrc" "$res" || fails=$((fails+1))
  rm -rf "$P"
}
one() { echo "(lambda r: r[0] if r[1] == 1 else None)(re.subn($1, $2, s, count=1))"; }
mut "M1 .xapk dropped from mediaPackageExts" media_tier.go \
  "$(one "r'(var mediaPackageExts = \[\]string\{\"\.apk\", \"\.apks\"), \"\.xapk\"'" "lambda m: m.group(1)")"
mut "M2 the package suffixes in mediaDenyExts, not app-private only" media_tier.go \
  "$(one "r'(var mediaDenyExts = \[\]string\{[^}]*\"\.so\")\}((?:.|\n)*?)var mediaPackageExts = \[\]string\{[^}]*\}'" "lambda m: m.group(1) + ', \".apk\", \".apks\", \".xapk\", \".apkm\"}' + m.group(2) + 'var mediaPackageExts = []string{}'")"
mut "M3 the CE <pkg>/ shape dropped" media_tier.go \
  "$(one "r'ok && strings\.Contains\(first, \"\.\"\) \{\n\t\treturn true'" "'ok && strings.Contains(first, \".\") {\n\t\treturn false'")"
mut "M4 the Android/data/<pkg>/ shape dropped" media_tier.go \
  "$(one "r'if i := strings\.IndexByte\(rest, \x27/\x27\); i > 0 \{\n\t\t\treturn true'" "'if i := strings.IndexByte(rest, \x27/\x27); i > 0 {\n\t\t\treturn false'")"
mut "M5 the CE shape guarded by a Contains test of the user dirs" media_tier.go \
  "$(one "r'ok && strings\.Contains\(first, \"\.\"\) \{'" "lambda m: 'ok && strings.Contains(first, \".\") && !strings.Contains(lower, \"/download/\") {'")"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
