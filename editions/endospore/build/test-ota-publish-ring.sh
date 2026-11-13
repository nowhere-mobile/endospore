#!/usr/bin/env bash
# test-ota-publish-ring.sh [--mutate] [script] -- e4-ota-publish.sh reads the ring it is about to write (NWP-20261026-04).
#
# WHY THIS IS COMMITTED. The script used to overwrite ota/<dev>/version (or version-<ring>) with whatever version it was
# given. Re-running last month's release directory moved the stable marker BACK: phones on the newer build were offered
# nothing and a phone behind installed the older build. And its previous-notes check, which can still refuse, ran AFTER
# the payload push, so a refused publish had already swapped the payload every phone downloads. These run a COPY of the
# real script in a scratch layout against a stub agent that logs every verb and answers `ota-check` from a fixture:
#   - a ring already HIGHER is refused unless --force; an UNREADABLE ring is refused even with --force;
#   - no refusal of the script follows the payload push;
#   - a non-stable ring publish is refused, before any agent call, without --stable-current (NWP-20261112-18): the
#     payload os-<dev> is one head for every ring, so a ring push replaces what every stable phone downloads;
#   - the script's scratch files all live in one dir with one trap.
#
#   bash test-ota-publish-ring.sh                 # the gates
#   bash test-ota-publish-ring.sh --mutate        # ... plus mutations that must each CONVICT the suite
#   bash test-ota-publish-ring.sh <script>        # run against another copy of e4-ota-publish.sh
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(cd "$(dirname "$0")" && pwd)/e4-ota-publish.sh}"
[ -f "$SUT" ] || { echo "no such file: $SUT" >&2; exit 2; }
command -v zip >/dev/null || { echo "zip is required" >&2; exit 2; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT
NOTES_OK=$'version 0.5.43\nprevious 0.5.42\n- A point.\n'

# setup <case-dir> <ota-check stdout> <ota-check rc>: the layout e4-ota-publish.sh resolves, a release dir, a stub agent.
setup() {
  local T="$1"
  mkdir -p "$T/editions/endospore/build" "$T/editions/endospore/ota-mandatory" "$T/core/vendor-common/etc/ota-notes" "$T/rel" "$T/img/SYSTEM/etc"
  cp "$SUT" "$T/editions/endospore/build/e4-ota-publish.sh"
  # NWP-20261124-19: the copy runs support-guard.sh beside itself; the real guard and a support-ended dir with only
  # its README (never the committed markers: a real one for lynx would refuse every case here).
  cp "$(dirname "$0")/support-guard.sh" "$T/editions/endospore/build/"; mkdir -p "$T/editions/endospore/support-ended"
  cp "$(dirname "$0")/../support-ended/README" "$T/editions/endospore/support-ended/"
  # NWP-20261202-12: the copy runs canary-guard.sh beside itself too; a canary pass for 0.5.43, the version every case
  # publishes, so lynx (a fleet device) gets past the guard and every case runs as before.
  cp "$(dirname "$0")/canary-guard.sh" "$T/editions/endospore/build/"; mkdir -p "$T/editions/endospore/canary-pass"
  cp "$(dirname "$0")/../canary-pass/README" "$T/editions/endospore/canary-pass/"
  printf 'canary husky\nbuild 2026120101\nsmoke pass 2026-12-01\n' > "$T/editions/endospore/canary-pass/0.5.43"
  printf '#!/bin/sh\nexit 0\n' > "$T/editions/endospore/build/check-agent-fresh.sh"; chmod +x "$T/editions/endospore/build/check-agent-fresh.sh"
  echo 0.5.43 > "$T/core/vendor-common/etc/nowhere-ota-version"
  printf '%s' "$NOTES_OK" > "$T/core/vendor-common/etc/ota-notes/0.5.43"
  echo 0.5.43 > "$T/img/SYSTEM/etc/nowhere-ota-version"
  printf '%s' "$NOTES_OK" > "$T/img/SYSTEM/etc/nowhere-ota-notes"
  (cd "$T/img" && zip -qr "$T/rel/lynx-target_files.zip" SYSTEM)
  printf 'p' > "$T/payload.bin"; printf 'q' > "$T/payload_properties.txt"
  (cd "$T" && zip -q "$T/rel/lynx-ota_update-1.zip" payload.bin payload_properties.txt)
  printf 'S3_ENDPOINT=x\nS3_REGION=x\nS3_BUCKET=x\nS3_ACCESS_KEY=x\nS3_SECRET_KEY=x\n' > "$T/conf"
  printf '%s\n' "$2" > "$T/ota-out"; printf '%s' "$3" > "$T/ota-rc"
  # The stub agent: logs each verb; ota-check answers the fixture; ota-notes-get answers $T/prev-rc.
  cat > "$T/agent" <<'AGENT'
#!/bin/sh
T=$(dirname "$0")
echo "$1" >> "$T/calls"
case "$1" in
  ota-check)       [ -s "$T/ota-out" ] && [ "$(cat "$T/ota-out")" != "-" ] && cat "$T/ota-out"; exit "$(cat "$T/ota-rc")" ;;
  ota-notes-get)   exit "$(cat "$T/prev-rc" 2>/dev/null || echo 0)" ;;
esac
exit 0
AGENT
  chmod +x "$T/agent"
}
# run <case-dir> [flags...] -> exit code; output in <case-dir>/out
run() {
  local T="$1"; shift
  bash "$T/editions/endospore/build/e4-ota-publish.sh" --device lynx "$@" "$T/rel/lynx-ota_update-1.zip" 0.5.43 "$T/conf" "$T/agent" > "$T/out" 2>&1
}
calls() { tr '\n' ' ' < "$1/calls" 2>/dev/null; }
has() { case " $(calls "$1")" in *" $2 "*) return 0 ;; *) return 1 ;; esac; }
ABSENT='ota-check: no published OS version'

echo "== a ring that is already ahead =="
T=$W/r1; setup "$T" 'ota-check: UPDATE -> 0.5.48' 0
run "$T"; rc=$?
[ $rc -eq 2 ] && grep -q "already offers 0.5.48; publishing 0.5.43 would move it back" "$T/out" && ok "r1 a higher ring is refused" || { no "r1 a higher ring was not refused (rc $rc)"; tail -3 "$T/out" | sed 's/^/        /'; }
if has "$T" push || has "$T" ota-mark; then no "r1 …but a push or mark was made: $(calls "$T")"; else ok "r1 …and nothing was pushed or marked"; fi

T=$W/r1b; setup "$T" 'ota-check: UPTODATE (latest 0.5.48)' 1
run "$T"; rc=$?
[ $rc -eq 2 ] && ! has "$T" push && ok "r1b a higher ring read from the UPTODATE line is refused too" || no "r1b UPTODATE-higher ring not refused (rc $rc, $(calls "$T"))"

T=$W/r2; setup "$T" 'ota-check: UPDATE -> 0.5.48' 0
run "$T" --force; rc=$?
c=$(calls "$T")
[ $rc -eq 0 ] && grep -q -- "--force: moving 'stable' back from 0.5.48 to 0.5.43" "$T/out" && ok "r2 --force publishes over a higher ring, saying so" || { no "r2 --force did not publish (rc $rc)"; tail -3 "$T/out" | sed 's/^/        /'; }
case "$c" in *"push "*"ota-mark"*) ok "r2 …push, then mark ($c)" ;; *) no "r2 wrong calls: $c" ;; esac

T=$W/r3; setup "$T" 'ota-check: UPTODATE (latest 0.5.43)' 1
run "$T"; rc=$?
[ $rc -eq 0 ] && grep -q "phones already running 0.5.43 will NOT be offered this payload" "$T/out" && has "$T" ota-mark && ok "r3 an equal ring publishes, with the note" || { no "r3 equal ring (rc $rc, $(calls "$T"))"; tail -3 "$T/out" | sed 's/^/        /'; }

T=$W/r4; setup "$T" 'ota-check: UPDATE -> 0.5.42' 0
run "$T"; rc=$?
[ $rc -eq 0 ] && has "$T" ota-mark && grep -q "was 0.5.42" "$T/out" && ok "r4 a lower ring publishes, and the summary says what it moved from" || { no "r4 lower ring (rc $rc, $(calls "$T"))"; tail -3 "$T/out" | sed 's/^/        /'; }

T=$W/r5; setup "$T" "$ABSENT" 3
run "$T"; rc=$?
[ $rc -eq 0 ] && has "$T" ota-mark && grep -q "was <none>" "$T/out" && ok "r5 an absent ring is a first publish" || { no "r5 absent ring (rc $rc, $(calls "$T"))"; tail -3 "$T/out" | sed 's/^/        /'; }

echo "== a ring that cannot be read =="
unreadable() {  # unreadable <label> <stdout> <rc> [flags...]
  local L="$1" O="$2" R="$3" T; shift 3
  T=$W/$L; setup "$T" "$O" "$R"
  run "$T" "$@"; rc=$?
  if [ $rc -eq 2 ] && grep -q "could not read the 'stable' ring (ota/lynx/version, agent exit $R)" "$T/out" && ! has "$T" push && ! has "$T" ota-mark; then
    ok "$L refused, nothing pushed or marked"
  else no "$L an unreadable ring was not refused cleanly (rc $rc, $(calls "$T"))"; fi
}
unreadable r6a '-' 5
unreadable r6b '-' 5 --force
unreadable r6c 'ota-check: something unexpected' 0
unreadable r6d 'ota-check: something unexpected' 0 --force
unreadable r6e 'ota-check: UPDATE -> 0.5.48' 3 --force

echo "== no refusal after the push =="
T=$W/r7; setup "$T" "$ABSENT" 3; echo 3 > "$T/prev-rc"
run "$T"; rc=$?
[ $rc -eq 2 ] && grep -q "has no published notes" "$T/out" && ok "r7 a missing previous link is refused" || no "r7 not refused (rc $rc)"
has "$T" push && no "r7 …but the payload was already pushed: $(calls "$T")" || ok "r7 …and no payload was pushed"

echo "== scratch files =="
# r8: a source assertion. Comment lines are skipped; the first mktemp must be the scratch dir with its EXIT trap on the
# same line, there must be exactly one trap, and every other mktemp goes into that dir.
CODE=$(grep -nv '^[[:space:]]*#' "$SUT" | grep mktemp || true)
FIRST=$(printf '%s\n' "$CODE" | head -1)
REST=$(printf '%s\n' "$CODE" | tail -n +2)
TRAPS=$(grep -v '^[[:space:]]*#' "$SUT" | grep -c 'trap ' || true)
case "$FIRST" in
  *'mktemp -d'*'trap '*'EXIT'*) ok "r8 the first mktemp is the scratch dir, with its EXIT trap" ;;
  *) no "r8 the first mktemp is not the scratch dir with its trap: ${FIRST:-<none>}" ;;
esac
[ "$TRAPS" = 1 ] && ok "r8 exactly one trap" || no "r8 $TRAPS traps"
BAD=$(printf '%s\n' "$REST" | grep -v -e '^$' | grep -v -e 'mktemp -p "\$SCRATCH"' || true)
[ -z "$BAD" ] && ok "r8 every other mktemp is inside the scratch dir" || no "r8 a temp outside the scratch dir: $BAD"
# r9
E=$(mktemp -d -p "$W"); T=$W/r9; setup "$T" 'ota-check: UPDATE -> 0.5.48' 0
TMPDIR="$E" run "$T"; rc=$?
LEFT=$(ls -A "$E")
[ $rc -eq 2 ] && [ -z "$LEFT" ] && ok "r9 a refusal leaves nothing in TMPDIR" || no "r9 rc $rc, left in TMPDIR: $LEFT"

echo "== a ring publish needs --stable-current (NWP-20261112-18) =="
# The absent-ring fixture: without the guard each of these would publish, so a missing guard shows on rc and calls.
ringrefused() {  # ringrefused <label> <ring-name> [flags...]
  local L="$1" R="$2" T; shift 2
  T=$W/$L; setup "$T" "$ABSENT" 3
  run "$T" "$@"; rc=$?
  if [ $rc -eq 2 ] && grep -qF "refusing: publishing to the '$R' ring" "$T/out" && grep -qF -- "--stable-current to attest" "$T/out"; then
    ok "$L refused, saying why"
  else no "$L a ring publish without --stable-current was not refused (rc $rc)"; tail -3 "$T/out" | sed 's/^/        /'; fi
  if [ -s "$T/calls" ]; then no "$L …but the agent was run: $(calls "$T")"; else ok "$L …and the agent was never run (no ota-check, push or mark)"; fi
}
ringrefused r10 beta --beta
ringrefused r11 canary --ring canary

T=$W/r12; setup "$T" "$ABSENT" 3
run "$T" --beta --stable-current; rc=$?
c=$(calls "$T")
[ $rc -eq 0 ] && ! grep -qF "refusing:" "$T/out" && ok "r12 --beta --stable-current publishes" || { no "r12 --beta --stable-current did not publish (rc $rc)"; tail -3 "$T/out" | sed 's/^/        /'; }
case "$c" in *"ota-check "*"push "*"ota-mark"*) ok "r12 …ota-check, push, then mark ($c)" ;; *) no "r12 wrong calls: $c" ;; esac
grep -qF "on the 'beta' ring (ref ota/lynx/version-beta," "$T/out" && ok "r12 …to the beta marker" || no "r12 not marked on version-beta"

for f in "" --stable-current; do  # r13: a stable publish, with and without the flag, exactly as before
  T=$W/r13${f:+-flag}; setup "$T" "$ABSENT" 3
  run "$T" $f; rc=$?
  c=$(calls "$T")
  case "$c" in *"push "*"ota-mark"*) pc=1 ;; *) pc=0 ;; esac
  [ $rc -eq 0 ] && [ $pc = 1 ] && grep -qF "on the 'stable' ring (ref ota/lynx/version," "$T/out" && ! grep -qF "refusing:" "$T/out" \
    && ok "r13 stable ${f:-(no flag)}: push then mark" || { no "r13 stable ${f:-(no flag)} (rc $rc, $c)"; tail -3 "$T/out" | sed 's/^/        /'; }
done

if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each MUST be convicted) =="
  M=$(mktemp -d -p "$W")
  mutate() {
    if ! sed "$2" "$SUT" > "$M/e4-ota-publish.sh" 2>"$M/err"; then no "MUTATION BROKEN (sed): $1"; return; fi
    if cmp -s "$SUT" "$M/e4-ota-publish.sh"; then no "MUTATION INERT: $1"; return; fi
    if bash "$0" "$M/e4-ota-publish.sh" >/dev/null 2>&1; then no "NOT CONVICTED: $1 -- suite passes on broken code"
    else ok "convicted: $1"; fi
  }
  mutate "M1 the higher-than guard removed" 's/^if \[ -n "\$CUR" \] && vlt "\$VERSION" "\$CUR"; then$/if false; then/'
  mutate "M2 --force also overrides an unreadable ring" 's/^    \*) echo "refusing: could not read the .*$/    *) if [ "$FORCE" = 1 ]; then CUR=""; else echo "refusing: unreadable"/; s/^       exit 2 ;;$/       exit 2; fi ;;/'
  mutate "M3 an unreadable ring read as absent" 's/^    3) CUR="" ;;$/    3|4) CUR="" ;;/'
  mutate "M4 the notes read moved back after the push" '/^"\$AGENT" push s3 /d; s/^case "\$PREV_RC" in$/"$AGENT" push s3 "$OSREF" "$OSPASS" "$STAGE"\n&/'
  mutate "M5 IMG_NOTES back to a bare mktemp" 's/^IMG_NOTES="\$(mktemp -p "\$SCRATCH")"$/IMG_NOTES="$(mktemp)"/'
  mutate "M6 an equal ring refused" 's/^elif \[ "\$CUR" = "\$VERSION" \]; then$/&\n  exit 2/'
  mutate "G1 the ring guard removed" 's/^if \[ "\$RING" != stable \] \&\& \[ "\$STABLE_CURRENT" != 1 \]; then$/if false; then/'
  mutate "G2 the ring guard's flag test inverted" 's/^if \[ "\$RING" != stable \] \&\& \[ "\$STABLE_CURRENT" != 1 \]; then$/if [ "$RING" != stable ] \&\& [ "$STABLE_CURRENT" = 1 ]; then/'
  mutate "G3 the ring guard moved after the payload push" '/^if \[ "\$RING" != stable \] \&\& \[ "\$STABLE_CURRENT" != 1 \]; then$/,/^fi$/d; s/^"\$AGENT" push s3 .*$/&\nif [ "$RING" != stable ] \&\& [ "$STABLE_CURRENT" != 1 ]; then echo "refusing: publishing to the '"'"'$RING'"'"' ring -- pass --stable-current to attest"; exit 2; fi/'
  mutate "G4 --stable-current no longer parsed" '/^    --stable-current) STABLE_CURRENT=1 ;;$/d'
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
