#!/usr/bin/env bash
# test-ring-smooth.sh [--mutate] -- NWP-20261013-37.
#
# launcher3-media-ring-smooth.sh (one copy per Endospore device) used to print '#129 ring not present -- no-op' and
# exit 0 when launcher3-media-progress-ring.sh had not applied, so build-device.sh printed 'ok' for a build with no
# smooth patch and the ordering held only by alphabet. A missing ring now exits 3, which fails the build. This suite
# runs every copy against synthetic BubbleTextView.java trees: no ring -> 3 and the file untouched; ring -> 0 and
# eased; re-run -> 'already applied'; drifted anchor -> 2. It also pins the five copies identical below line 2.
# It cannot show the anchors match the real GrapheneOS tree; that is the next Endospore build. Plain bash.
#
#   bash test-ring-smooth.sh            # the five device copies
#   bash test-ring-smooth.sh --mutate   # ... plus mutants that must each CONVICT the suite
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; esac; done
ED="$(cd "$(dirname "$0")/.." && pwd)"
DEVICES="lynx frankel stallion tegu husky"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
BT=packages/apps/Launcher3/src/com/android/launcher3/BubbleTextView.java
ANCHOR='        canvas.drawArc(oval, -90f, 360f * pct / 100f, false, mMediaRingPaint);'

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
has(){ grep -cF -- "$2" "$1" >/dev/null; }
lacks(){ ! grep -cF -- "$2" "$1" >/dev/null; }

# mk <name> <ring|none|drift>: a minimal tree.
mk(){
  local f="$W/$1/$BT"; mkdir -p "$(dirname "$f")"
  case "$2" in
    none)  printf 'class BubbleTextView {\n    void draw() {}\n}\n' > "$f" ;;
    ring)  printf 'class BubbleTextView {\n    private Paint mMediaRingPaint;\n    void drawMediaRingIfNecessary(Canvas canvas) {\n%s\n    }\n}\n' "$ANCHOR" > "$f" ;;
    drift) printf 'class BubbleTextView {\n    private Paint mMediaRingPaint;\n    void drawMediaRingIfNecessary(Canvas canvas) {\n        canvas.drawArc(oval, 0f, 1f, false, mMediaRingPaint);\n    }\n}\n' > "$f" ;;
  esac
}
run(){ bash "$1" "$W/$2" > "$W/$2.out" 2>"$W/$2.err"; echo $?; }

check(){  # check <sut> <label>
  local sut="$1" l="$2" rc
  mk "$l-none" none; cp "$W/$l-none/$BT" "$W/$l-none.orig"
  rc=$(run "$sut" "$l-none")
  [ "$rc" != 0 ] && [ "$rc" = 3 ] && has "$W/$l-none.err" 'ring not present' && cmp -s "$W/$l-none/$BT" "$W/$l-none.orig" \
    && ok "$l: no ring -> exit 3, ERROR on stderr, file untouched" || no "$l: no ring (rc=$rc)"
  mk "$l-ring" ring
  rc=$(run "$sut" "$l-ring")
  [ "$rc" = 0 ] && has "$W/$l-ring/$BT" mMediaRingShownPct && has "$W/$l-ring.out" eased \
    && ok "$l: ring -> exit 0, eased" || no "$l: ring (rc=$rc)"
  rc=$(run "$sut" "$l-ring")
  [ "$rc" = 0 ] && has "$W/$l-ring.out" 'already applied' && ok "$l: re-run -> already applied" || no "$l: re-run (rc=$rc)"
  mk "$l-drift" drift
  rc=$(run "$sut" "$l-drift")
  [ "$rc" = 2 ] && ok "$l: drifted anchor -> exit 2" || no "$l: drift (rc=$rc)"
}

suite(){  # suite <label-prefix> <script>...
  local p="$1"; shift
  local first="$1" s
  for s in "$@"; do check "$s" "$p$(basename "$(dirname "$(dirname "$s")")")"; done
  for s in "$@"; do
    if diff <(tail -n +3 "$first") <(tail -n +3 "$s") >/dev/null; then ok "$p$(basename "$(dirname "$(dirname "$s")")") identical to first below line 2"
    else no "$p$(basename "$(dirname "$(dirname "$s")")") differs below line 2"; fi
  done
}

SUTS=(); for d in $DEVICES; do SUTS+=("$ED/devices/$d/patches/launcher3-media-ring-smooth.sh"); done
suite "" "${SUTS[@]}"

if [ "$MUTATE" = yes ]; then
  echo "-- mutants (each must be convicted)"
  M="$W/mut"; mkdir -p "$M/lynx/patches/x"; MS="$M/lynx/patches/x/launcher3-media-ring-smooth.sh"
  mutant(){  # mutant <name> <sed expr>
    cp "${SUTS[0]}" "$MS"; sed -i "$2" "$MS"
    if cmp -s "${SUTS[0]}" "$MS"; then no "mutant $1 did not apply"; return; fi
    local before=$FAIL; PASS_SAVE=$PASS
    check "$MS" "mut-$1" >/dev/null
    if [ "$FAIL" -gt "$before" ]; then FAIL=$before; PASS=$PASS_SAVE; ok "mutant $1 convicted"; else no "mutant $1 NOT convicted"; fi
  }
  mutant absent-exit0 's/file=sys.stderr); sys.exit(3)/file=sys.stderr); sys.exit(0)/'
  mutant drift-exit0 's/aborting", file=sys.stderr); sys.exit(2)/aborting", file=sys.stderr); sys.exit(0)/'
  mutant no-stderr 's/ERROR: #129 ring not present/#129 ring not present/;s/ring not present -- launcher3/ring there -- launcher3/'
fi

echo "== $PASS ok, $FAIL failed"
[ "$FAIL" = 0 ]
