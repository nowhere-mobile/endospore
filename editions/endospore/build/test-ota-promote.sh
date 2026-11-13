#!/usr/bin/env bash
# test-ota-promote.sh [--mutate] -- exercise e4-ota-promote.sh's ring reads (NWP-20261024-05).
#
# WHY THIS IS COMMITTED. The promote script writes the marker the general fleet reads, and the path that
# matters -- a ring read that FAILS -- never runs on a healthy host. It used to read a failed read of the
# target ring as "no marker", skip its downgrade guard and rewrite a stable ring that was ahead of beta.
# This suite stubs the agent (ota-check / ota-mark over a fixture dir) and pins every outcome.
#
#   bash test-ota-promote.sh            # the behaviour cases
#   bash test-ota-promote.sh --mutate   # ... plus mutants that must each CONVICT the suite
#
# Pure logic -- no build, no device, no network, fake store values only.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MUTATE=0
[ "${1:-}" = "--mutate" ] && MUTATE=1
SUT="$HERE/e4-ota-promote.sh"
[ -f "$SUT" ] || { echo "no such script: $SUT"; exit 2; }

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

# Fixture store conf: fake values only.
cat > "$W/store.conf" <<'CONF'
S3_ENDPOINT=https://store.invalid
S3_REGION=auto
S3_BUCKET=fixture-bucket
S3_ACCESS_KEY=fixture-access
S3_SECRET_KEY=fixture-secret
CONF

# The stub agent. Fixture dir $FX holds, per ring ref (slashes -> _):
#   <ref>          the marker version (absent file = absent ring)
#   <ref>.fail     "<exit>" -> ota-check exits that with stderr text and empty stdout
#   <ref>.noline   present -> ota-check exits $(cat) with no stdout line
# $FX/mark-writes   if present, ota-mark writes THIS instead of the requested version
# $FX/read-fails-after-mark   if present, ota-check on a marked ref fails (exit 5) after any ota-mark
cat > "$W/agent" <<'STUB'
#!/usr/bin/env bash
k="${NOWHERE_OTA_VERSION_REF//\//_}"
case "$1" in
  ota-check)
    if [ -e "$FX/read-fails-after-mark" ] && [ -e "$FX/marked" ]; then
      echo "stub: store unreachable after mark" >&2; exit 5
    fi
    if [ -e "$FX/$k.fail" ]; then
      echo "stub: simulated store failure for $NOWHERE_OTA_VERSION_REF" >&2; exit "$(cat "$FX/$k.fail")"
    fi
    if [ -e "$FX/$k.noline" ]; then exit "$(cat "$FX/$k.noline")"; fi
    if [ ! -s "$FX/$k" ]; then echo "ota-check: no published OS version"; exit 3; fi
    echo "ota-check: UPDATE -> $(cat "$FX/$k")"; exit 0 ;;
  ota-mark)
    echo "$NOWHERE_OTA_VERSION_REF $3" >> "$FX/mark-calls"
    : > "$FX/marked"
    if [ -e "$FX/mark-writes" ]; then cat "$FX/mark-writes" > "$FX/$k"; else echo "$3" > "$FX/$k"; fi
    exit 0 ;;
esac
exit 64
STUB
chmod +x "$W/agent"

# run_case <script> <name> <setup-cmds...> -> sets OUT, RC, FX; script copied beside a stub freshness check.
run_case() {
  local sut="$1" name="$2" args="${3:-}" setup="${4:-}" bin v
  bin="$W/bin-$name"; FX="$W/fx-$name"
  mkdir -p "$bin" "$FX"
  cp "$sut" "$bin/e4-ota-promote.sh"
  # NWP-20261124-19: the copy runs support-guard.sh beside itself; it reads $W/support-ended, which holds only the
  # README (never the committed markers: a real one for lynx would refuse every case here).
  cp "$HERE/support-guard.sh" "$bin/"; mkdir -p "$W/support-ended"; cp "$HERE/../support-ended/README" "$W/support-ended/"
  # NWP-20261202-12: and canary-guard.sh, which reads $W/canary-pass: a canary pass for every version a case promotes
  # (0.5.40 to 0.5.49), so the device 'fixture' (a fleet device) gets past the guard and every case runs as before.
  cp "$HERE/canary-guard.sh" "$bin/"; mkdir -p "$W/canary-pass"; cp "$HERE/../canary-pass/README" "$W/canary-pass/"
  for v in 0.5.40 0.5.41 0.5.42 0.5.43 0.5.44 0.5.45 0.5.46 0.5.47 0.5.48 0.5.49; do
    printf 'canary husky\nbuild 2026120101\nsmoke pass 2026-12-01\n' > "$W/canary-pass/$v"
  done
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/check-agent-fresh.sh"
  chmod +x "$bin/check-agent-fresh.sh" "$bin/e4-ota-promote.sh"
  eval "$setup"
  OUT="$(FX="$FX" bash "$bin/e4-ota-promote.sh" "$W/store.conf" --device fixture "$W/agent" --yes $args 2>&1)"; RC=$?
}
marked() { [ -e "$FX/mark-calls" ]; }

# suite <script> -> 0 if every case behaved. A test-name prefix keeps the dirs of one run apart.
suite() {
  local sut="$1" quiet="${2:-}" p=0 x=0
  ok()  { p=$((p+1)); [ -n "$quiet" ] || printf '  ok    %s\n' "$1"; }
  bad() { x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  %s\n' "$1"; }
  has() { case "$OUT" in *"$1"*) return 0 ;; esac; return 1; }
  chk() { if "${@:2}"; then ok "$1"; else bad "$1"; [ -n "$quiet" ] || printf '%s\n' "$OUT" | sed 's/^/        | /'; fi; }
  local tag="$2"
  local B=ota_fixture_version-beta S=ota_fixture_version

  # 1. forward promote
  run_case "$sut" "$tag-1" "" "echo 0.5.48 > \$FX/$B; echo 0.5.47 > \$FX/$S"
  chk "1 forward promote: rc 0, stable written, OK line" \
    bash -c '[ "$1" = 0 ] && [ "$(cat "$2/'"$S"'")" = 0.5.48 ] && case "$3" in *"OK: "*) true;; *) false;; esac' _ "$RC" "$FX" "$OUT"

  # 2. stable ahead of beta
  run_case "$sut" "$tag-2" "" "echo 0.5.48 > \$FX/$B; echo 0.5.49 > \$FX/$S"
  chk "2 stable >= beta: refusing, rc 2, no ota-mark" bash -c '[ "$1" = 2 ] && [ ! -e "$2/mark-calls" ] && case "$3" in *refusing*) true;; *) false;; esac' _ "$RC" "$FX" "$OUT"

  # 3. stable absent
  run_case "$sut" "$tag-3" "" "echo 0.5.48 > \$FX/$B"
  chk "3 stable absent: first promote writes, rc 0" bash -c '[ "$1" = 0 ] && [ "$(cat "$2/'"$S"'")" = 0.5.48 ]' _ "$RC" "$FX"

  # 4. stable read fails (exit 5, empty stdout)
  run_case "$sut" "$tag-4" "" "echo 0.5.48 > \$FX/$B; echo 0.5.49 > \$FX/$S; echo 5 > \$FX/$S.fail"
  chk "4 stable read fails: could not read, rc 2, no ota-mark, agent stderr shown" \
    bash -c '[ "$1" = 2 ] && [ ! -e "$2/mark-calls" ] && case "$3" in *"could not read the '"'stable'"' ring"*"simulated store failure"*) true;; *) false;; esac' _ "$RC" "$FX" "$OUT"

  # 5. stable read exits 1 with no UPTODATE line
  run_case "$sut" "$tag-5" "" "echo 0.5.48 > \$FX/$B; echo 0.5.49 > \$FX/$S; echo 1 > \$FX/$S.noline"
  chk "5 exit 1 without its line: refused like 4" \
    bash -c '[ "$1" = 2 ] && [ ! -e "$2/mark-calls" ] && case "$3" in *"could not read"*) true;; *) false;; esac' _ "$RC" "$FX" "$OUT"

  # 6. beta read fails
  run_case "$sut" "$tag-6" "" "echo 0.5.48 > \$FX/$B; echo 0.5.47 > \$FX/$S; echo 1 > \$FX/$B.fail"
  chk "6 beta read fails: could not read, never nothing is staged" \
    bash -c '[ "$1" = 2 ] && [ ! -e "$2/mark-calls" ] && case "$3" in *"could not read the '"'beta'"' ring"*) case "$3" in *"nothing is staged"*) false;; *) true;; esac;; *) false;; esac' _ "$RC" "$FX" "$OUT"

  # 7. beta absent
  run_case "$sut" "$tag-7" "" "echo 0.5.47 > \$FX/$S"
  chk "7 beta absent: nothing is staged, rc 2" \
    bash -c '[ "$1" = 2 ] && [ ! -e "$2/mark-calls" ] && case "$3" in *"nothing is staged"*) true;; *) false;; esac' _ "$RC" "$FX" "$OUT"

  # 8. --force with a failed stable read
  run_case "$sut" "$tag-8" "--force" "echo 0.5.48 > \$FX/$B; echo 0.5.49 > \$FX/$S; echo 5 > \$FX/$S.fail"
  chk "8 --force with a failed stable read: still refused, no ota-mark" \
    bash -c '[ "$1" = 2 ] && [ ! -e "$2/mark-calls" ] && case "$3" in *"could not read"*) true;; *) false;; esac' _ "$RC" "$FX" "$OUT"

  # 9. read-back mismatch
  run_case "$sut" "$tag-9" "" "echo 0.5.48 > \$FX/$B; echo 0.5.47 > \$FX/$S; echo 0.5.40 > \$FX/mark-writes"
  chk "9 read-back mismatch: VERIFY FAILED, rc 1" \
    bash -c '[ "$1" = 1 ] && case "$2" in *"VERIFY FAILED: '"'stable'"' ring now reads"*) true;; *) false;; esac' _ "$RC" "$OUT"

  # 10. read-back fails
  run_case "$sut" "$tag-10" "" "echo 0.5.48 > \$FX/$B; echo 0.5.47 > \$FX/$S; : > \$FX/read-fails-after-mark"
  chk "10 failed read-back: could not read back, rc 1" \
    bash -c '[ "$1" = 1 ] && case "$2" in *"could not read back"*) true;; *) false;; esac' _ "$RC" "$OUT"

  [ -n "$quiet" ] || printf '  (%d ok, %d failed)\n' "$p" "$x"
  [ "$x" = 0 ]
}

echo "== behaviour: $SUT"
suite "$SUT" "" real; BRC=$?
[ "$BRC" = 0 ] || { echo "⚠ behaviour cases failed"; exit 1; }
[ "$MUTATE" = 1 ] || exit 0

echo
echo "== mutations (each must make the suite FAIL)"
MRC=0
# mutate <label> <old-text> <new-text>: replace the first occurrence of old with new in a copy.
mutate() {
  local label="$1" old="$2" new="$3" copy
  copy="$(mktemp -p "$W" mutant.XXXXXX)"
  cp "$SUT" "$copy"
  OLD="$old" NEW="$new" python3 -I - "$copy" <<'PY' || { echo "  FAIL  $label: mutation did not apply"; MRC=1; return; }
import os, sys
p = sys.argv[1]
s = open(p).read()
old, new = os.environ["OLD"], os.environ["NEW"]
if old not in s:
    sys.exit(1)
open(p, "w").write(s.replace(old, new, 1))
PY
  if cmp -s "$SUT" "$copy"; then echo "  FAIL  $label: INERT (copy equals original)"; MRC=1; return; fi
  if ! bash -n "$copy" 2>/dev/null; then echo "  FAIL  $label: mutant does not parse"; MRC=1; return; fi
  if suite "$copy" quiet "m$((++MN))"; then echo "  FAIL  $label: NOT convicted"; MRC=1
  else echo "  ok    $label: convicted"; fi
  rm -f "$copy"
}
MN=0

mutate "P1 failed target read treated as absent again" \
  '    *) refuse_unreadable "$TO" ;;' \
  '    *) DST="" ;;'
mutate "P2 stderr discarded again" \
  '2>"$W/ota-check.err")"' \
  '2>/dev/null)"'
mutate "P3 --force skips the read-failure refusal" \
  '    *) refuse_unreadable "$TO" ;;' \
  '    *) [ "$FORCE" = 1 ] && DST="" || refuse_unreadable "$TO" ;;'
mutate "P4 exit 1 accepted without its line" \
  '  if [ -n "$line" ]; then' \
  '  if [ -n "$line" ] || [ "$rc" = 1 ]; then'
mutate "P5 downgrade guard deleted" \
  'if [ -n "$DST" ] && ! vlt "$DST" "$SRC"; then' \
  'if false; then'

echo
[ "$MRC" = 0 ] && echo "all mutations convicted" || echo "⚠ at least one mutation was not convicted"
exit $MRC
