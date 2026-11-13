#!/usr/bin/env bash
# test-ota-notes-publish.sh [--mutate] -- e4-ota-publish.sh's OTA-notes gates (NWP-20261006-12) and its signed release
# metadata gates (NWP-20261011-05: a release flagged mandatory never publishes without its verified, signed manifest).
#
# WHY THIS IS COMMITTED. The notes a phone shows are only as good as the publish that put them there: a release
# without notes, notes that differ from what the image baked, or a broken link in the chain of `previous` versions
# would each reach the fleet silently, and the phone would just show less. These run the REAL script (a copy, in a
# scratch layout) against a stub agent that logs every call, and assert each refusal and the order of the writes:
# the notes must be in the store BEFORE the marker, or a phone that sees the marker finds nothing to show.
#
#   bash test-ota-notes-publish.sh            # the gates
#   bash test-ota-notes-publish.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(cd "$(dirname "$0")" && pwd)/e4-ota-publish.sh}"
[ -f "$SUT" ] || { echo "no such file: $SUT" >&2; exit 2; }
command -v zip >/dev/null || { echo "zip is required" >&2; exit 2; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
NOTES_OK=$'version 0.5.43\nprevious 0.5.42\n- A point.\n'

# setup <case-dir>: the layout e4-ota-publish.sh resolves ($HERE/../../../core/...), a release dir, a stub agent.
setup() {
  local T="$1"; mkdir -p "$T/editions/endospore/build" "$T/editions/endospore/ota-mandatory" "$T/core/vendor-common/etc/ota-notes" "$T/rel" "$T/img/SYSTEM/etc"
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
  # The stub agent: logs each verb (and its arguments to args); ota-notes-check and ota-release-check refuse a file
  # containing BAD; ota-notes-get answers $T/prev-rc; ota-check reports an absent ring.
  cat > "$T/agent" <<'AGENT'
#!/bin/sh
T=$(dirname "$0")
echo "$1" >> "$T/calls"
echo "$*" >> "$T/args"
case "$1" in
  ota-notes-check) grep -q BAD "$2" && exit 1; exit 0 ;;
  ota-notes-get)   exit "$(cat "$T/prev-rc" 2>/dev/null || echo 0)" ;;
  ota-check)       echo 'ota-check: no published OS version'; exit 3 ;;
  ota-release-check) grep -q BAD "$2" && exit 1; exit 0 ;;
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

echo "== refusals =="
T=$W/nonotes; setup "$T"; rm "$T/core/vendor-common/etc/ota-notes/0.5.43"
run "$T"; rc=$?
[ $rc -ne 0 ] && grep -q "no OTA notes for 0.5.43" "$T/out" && ok "a release without notes is refused" || no "a release without notes was published (rc $rc)"
grep -q ota-mark "$T/calls" 2>/dev/null && no "…and it marked the version anyway" || ok "…before anything is written"

T=$W/badnotes; setup "$T"; echo BAD >> "$T/core/vendor-common/etc/ota-notes/0.5.43"
run "$T"; rc=$?
[ $rc -ne 0 ] && grep -q "not valid" "$T/out" && ok "invalid notes are refused" || no "invalid notes were published (rc $rc)"

T=$W/drift; setup "$T"; printf '%s' $'version 0.5.43\nprevious 0.5.42\n- Edited after the build.\n' > "$T/core/vendor-common/etc/ota-notes/0.5.43"
run "$T"; rc=$?
[ $rc -ne 0 ] && grep -q "baked notes" "$T/out" && ok "notes that differ from the image's baked copy are refused" || no "notes edited after the build were published (rc $rc)"

T=$W/unbaked; setup "$T"; rm "$T/rel/lynx-target_files.zip"; rm "$T/img/SYSTEM/etc/nowhere-ota-notes"; (cd "$T/img" && zip -qr "$T/rel/lynx-target_files.zip" SYSTEM)
run "$T"; rc=$?
[ $rc -ne 0 ] && grep -q "baked notes" "$T/out" && ok "an image that baked no notes is refused" || no "an image with no baked notes was published (rc $rc)"

T=$W/brokenchain; setup "$T"; echo 3 > "$T/prev-rc"
run "$T"; rc=$?
[ $rc -ne 0 ] && grep -q "has no published notes" "$T/out" && ok "a missing previous link is refused without --first-notes" || no "a broken chain was published (rc $rc)"
grep -q ota-mark "$T/calls" 2>/dev/null && no "…and it marked the version anyway" || ok "…and nothing was marked"

T=$W/storeerr; setup "$T"; echo 1 > "$T/prev-rc"
run "$T" --first-notes; rc=$?
[ $rc -ne 0 ] && grep -q "not the same as 'none'" "$T/out" && ok "a store error on the previous link is refused even with --first-notes" || no "a store error read as 'no previous notes' (rc $rc)"

echo "== publishing =="
T=$W/first; setup "$T"; echo 3 > "$T/prev-rc"
run "$T" --first-notes; rc=$?
[ $rc -eq 0 ] && ok "--first-notes publishes the release that starts the chain" || { no "--first-notes did not publish (rc $rc)"; sed 's/^/        /' "$T/out" | tail -5; }
T=$W/chained; setup "$T"
run "$T"; rc=$?
c=$(calls "$T")
[ $rc -eq 0 ] && ok "a chained release publishes" || { no "a chained release was refused (rc $rc)"; sed 's/^/        /' "$T/out" | tail -5; }
case "$c" in
  *"ota-notes-get push ota-notes-put"*"ota-mark"*) ok "the notes are written after the previous link is checked, and BEFORE the marker ($c)" ;;
  *) no "wrong order: $c (want ... ota-notes-get push ota-notes-put ... ota-mark)" ;;
esac

echo "== the signed release metadata (NWP-20261011-05) =="
MAND=$'version 0.5.43\nseverity mandatory\nreason A reason.\nconsequence A consequence.\n'
T=$W/ordinary; setup "$T"
run "$T"; rc=$?
[ $rc -eq 0 ] && ! grep -q ota-release "$T/calls" && grep -q "an ordinary release" "$T/out" \
  && ok "an ordinary release with no signed manifest publishes, saying so, and puts no metadata" \
  || { no "an ordinary release without a manifest: rc $rc, calls $(calls "$T")"; sed 's/^/        /' "$T/out" | tail -5; }

T=$W/flagged-nosig; setup "$T"; printf '%s' "$MAND" > "$T/editions/endospore/ota-mandatory/0.5.43"
run "$T"; rc=$?
[ $rc -ne 0 ] && grep -q "flagged mandatory" "$T/out" && ok "a flagged release without its signed manifest is refused" \
  || no "a flagged release was published without its signed manifest (rc $rc)"
grep -q ota-mark "$T/calls" 2>/dev/null && no "…and it marked the version anyway" || ok "…before anything is written"

T=$W/signed; setup "$T"; printf '%s' "$MAND" > "$T/editions/endospore/ota-mandatory/0.5.43"
printf '{"ota":{}}\n' > "$T/rel/lynx-manifest-1.json"; printf 'sig' > "$T/rel/lynx-manifest-1.json.sig"
run "$T"; rc=$?
c=$(calls "$T")
[ $rc -eq 0 ] && ok "a flagged release with its signed manifest publishes" || { no "a signed flagged release was refused (rc $rc)"; sed 's/^/        /' "$T/out" | tail -5; }
case "$c" in
  *"ota-release-check "*"ota-notes-put ota-release-put ota-mark"*) ok "checked first, then published after the notes and BEFORE the marker ($c)" ;;
  *) no "wrong order: $c (want ota-release-check ... ota-notes-put ota-release-put ota-mark)" ;;
esac
grep -qx "ota-release-check $T/rel/lynx-manifest-1.json $T/rel/lynx-manifest-1.json.sig lynx 0.5.43 $T/editions/endospore/build/../ota-mandatory/0.5.43" "$T/args" \
  && ok "the check gets this device, this version and the committed flag file" \
  || { no "ota-release-check got the wrong arguments"; grep ota-release-check "$T/args" | sed 's/^/        /'; }
grep -q "^ota-release-put s3 $T/rel/lynx-manifest-1.json $T/rel/lynx-manifest-1.json.sig lynx 0.5.43 " "$T/args" \
  && ok "the put publishes that same manifest for this device and version" || no "ota-release-put got the wrong arguments"

T=$W/badsig; setup "$T"
printf 'BAD\n' > "$T/rel/lynx-manifest-1.json"; printf 'sig' > "$T/rel/lynx-manifest-1.json.sig"
run "$T"; rc=$?
[ $rc -ne 0 ] && grep -q "does not pass the phone's own check" "$T/out" && ok "a signed manifest that fails the phone's check is refused, flagged or not" \
  || no "a manifest failing the check was published (rc $rc)"
grep -q ota-mark "$T/calls" 2>/dev/null && no "…and it marked the version anyway" || ok "…and nothing was marked"

T=$W/orphansig; setup "$T"; printf 'sig' > "$T/rel/lynx-manifest-1.json.sig"
run "$T"; rc=$?
[ $rc -ne 0 ] && grep -q "but the manifest it signs" "$T/out" && ok "a signature without its manifest is refused" \
  || no "a signature without its manifest was published (rc $rc)"

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
  mutate "the notes file no longer required"      's/^\[ -f "\$NOTES" \] || {/[ -n "x" ] || {/'
  mutate "the baked-copy comparison dropped"      's/^if ! cmp -s "\$IMG_NOTES" "\$NOTES"; then$/if false; then/'
  mutate "a broken chain allowed"                 's/^  3) if \[ "\$FIRST_NOTES" = 1 \]; then$/  3) if true; then/'
  mutate "a store error read as none"             's/^  \*) echo "refusing: could not read .*$/  *) : ;;/'
  mutate "the notes written after the marker"     '/^"\$AGENT" ota-notes-put s3 "\$DEV" "\$NOTES"$/d; s/^"\$AGENT" ota-mark s3 "\$VERSION"$/&\n"$AGENT" ota-notes-put s3 "$DEV" "$NOTES"/'
  mutate "a flagged release published without its manifest" 's/^elif \[ -f "\$MAND_SRC" \]; then$/elif false; then/'
  mutate "a failing release check ignored"        's/^  if ! "\$AGENT" ota-release-check /  if false \&\& "$AGENT" ota-release-check /'
  mutate "the release check not given the flag"   's/^\(  if ! "\$AGENT" ota-release-check "\$REL_MAN" "\$REL_SIG" "\$DEV" "\$VERSION"\) "\$MAND_SRC"; then$/\1; then/'
  mutate "the metadata never published"           's/^  "\$AGENT" ota-release-put s3 /  : "$AGENT" ota-release-put s3 /'
  mutate "the metadata published after the marker" 's/^if \[ "\$REL_PUBLISH" = 1 \]; then$/if false; then/; s/^"\$AGENT" ota-mark s3 "\$VERSION"$/&\n[ "$REL_PUBLISH" = 1 ] \&\& "$AGENT" ota-release-put s3 "$REL_MAN" "$REL_SIG" "$DEV" "$VERSION" "$MAND_SRC"/'
  mutate "an orphan signature tolerated"          's/^  \[ -f "\$REL_MAN" \] || { echo "refusing: \$REL_SIG is here.*$/  :/'
  rm -rf "$M"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
