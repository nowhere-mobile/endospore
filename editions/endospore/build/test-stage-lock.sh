#!/usr/bin/env bash
# test-stage-lock.sh [--mutate] [<endospore-stage-vendor.sh> <diaspore-stage-vendor.sh>] -- both editions'
# stage-vendor.sh refuse a concurrent stage of the shared vendor tree (NWP-20261011-16).
#
# WHY THIS IS COMMITTED. Both scripts assemble into ONE shared vendor/<edition>. Two stages at once duplicate
# file_contexts entries and sepolicy dies with "Multiple same specifications" -- a failure that reads like a
# sepolicy bug and that the next clean stage erases. A guard that stops refusing is just as silent, so this holds
# the lock each script takes (beside its destination) and runs the REAL script against an empty fake repo: it must
# exit non-zero within 5 s, name the race, and not create the destination. With the lock free it must get past
# the lock (it then dies on the empty repo, which is fine) -- that proves the lock is released and never refuses
# spuriously.
#
#   bash test-stage-lock.sh            # both scripts
#   bash test-stage-lock.sh --mutate   # ... plus mutants that must each CONVICT the suite
set -uo pipefail

# Exit 2, never 0: a runner without flock must fail the CI step, not pass it silently.
command -v flock >/dev/null 2>&1 || { echo 'SKIP: no flock'; exit 2; }
command -v timeout >/dev/null 2>&1 || { echo 'timeout (coreutils) is required' >&2; exit 2; }

HERE=$(cd "$(dirname "$0")" && pwd)
MUTATE=no; SUTS=()
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUTS+=("$a") ;; esac; done
SUT_E="${SUTS[0]:-$HERE/stage-vendor.sh}"
SUT_D="${SUTS[1]:-$(cd "$HERE/../../diaspore/build" && pwd)/stage-vendor.sh}"
for f in "$SUT_E" "$SUT_D"; do [ -f "$f" ] || { echo "no such file: $f" >&2; exit 2; }; done

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

HOLDER=""
W=$(mktemp -d); trap '[ -n "$HOLDER" ] && kill "$HOLDER" 2>/dev/null; rm -rf "$W"' EXIT

# check_script <label> <path>
check_script() {
  local label="$1" path="$2" T LOCK DEST rc i
  T=$(mktemp -d "$W/XXXX"); mkdir -p "$T/repo" "$T/vendor"   # empty fake repo: nothing under core/ exists
  LOCK="$T/vendor/.x.stage.lock"; DEST="$T/vendor/x"
  # Hold the lock. NOT `flock "$LOCK" sleep 30 &`: killing that kills only the flock parent, and the sleep child
  # keeps the inherited fd, so the lock stays held for the full 30 s. exec makes sleep ITSELF the holder.
  bash -c 'exec 9>"$1"; flock 9; exec sleep 30' _ "$LOCK" & HOLDER=$!
  for i in $(seq 1 50); do flock -n "$LOCK" true 2>/dev/null || break; sleep 0.1; done
  if flock -n "$LOCK" true 2>/dev/null; then no "$label: could not establish the lock holder"; fi

  timeout 5 bash "$path" "$T/repo" "$DEST" > "$T/out" 2>&1; rc=$?
  if [ $rc -ne 0 ] && [ $rc -ne 124 ]; then ok "$label: refused while another stage holds the lock (rc $rc)"
  else no "$label: did not fail fast (rc $rc)"; fi
  if grep -q 'another stage-vendor.sh' "$T/out"; then ok "$label: names the race"
  else no "$label: no race message"; sed 's/^/        /' "$T/out" | tail -5; fi
  if [ ! -e "$DEST" ]; then ok "$label: wrote nothing to the destination"
  else no "$label: created the destination while another stage held the lock"; fi
  kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; HOLDER=""

  # Positive control: lock free -> past the lock (it then dies on the empty repo; only these two facts matter).
  timeout 20 bash "$path" "$T/repo" "$DEST" > "$T/out2" 2>&1; rc=$?
  if ! grep -q 'another stage-vendor.sh' "$T/out2"; then ok "$label: no refusal once the holder is gone"
  else no "$label: refused with the lock free"; fi
  if [ -e "$DEST" ]; then ok "$label: proceeded past the lock when free"
  else no "$label: never reached its first write with the lock free (rc $rc)"; sed 's/^/        /' "$T/out2" | tail -5; fi
}

echo "== endospore =="
check_script endospore "$SUT_E"
echo "== diaspore =="
check_script diaspore "$SUT_D"

if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each MUST be convicted) =="
  M=$(mktemp -d)
  mutate() {  # <label> <E|D> <sed-expr>
    local src e="$SUT_E" d="$SUT_D"
    if [ "$2" = E ]; then src="$SUT_E"; else src="$SUT_D"; fi
    if ! sed "$3" "$src" > "$M/stage-vendor.sh" 2>"$M/err"; then no "MUTATION BROKEN (sed): $1"; return; fi
    if cmp -s "$src" "$M/stage-vendor.sh"; then no "MUTATION INERT: $1"; return; fi
    if [ "$2" = E ]; then e="$M/stage-vendor.sh"; else d="$M/stage-vendor.sh"; fi
    if bash "$0" "$e" "$d" >/dev/null 2>&1; then no "NOT CONVICTED: $1 -- suite passes on broken code"
    else ok "convicted: $1"; fi
  }
  mutate "endospore: the flock line removed"    E '/^flock -n 9 ||/d'
  mutate "diaspore: the flock line removed"     D '/^flock -n 9 ||/d'
  mutate "endospore: the lock never contended"  E 's/^flock -n 9 ||/true ||/'
  mutate "diaspore: the lock never contended"   D 's/^flock -n 9 ||/true ||/'
  mutate "endospore: the lock taken after the first write" E '/^mkdir -p "\$DEST"$/d; s/^LOCK=/mkdir -p "$DEST"\n&/'
  mutate "diaspore: the lock taken after the first write"  D '/^mkdir -p "\$DEST"$/d; s/^LOCK=/mkdir -p "$DEST"\n&/'
  rm -rf "$M"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
