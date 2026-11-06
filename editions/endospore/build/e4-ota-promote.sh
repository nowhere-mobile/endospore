#!/usr/bin/env bash
# E.4 -- Endospore staged-OTA PROMOTE (#83). Promote a release that was staged to a canary ring
# (e4-ota-publish.sh --ring beta) up to the general "stable" ring, so every device picks it up on its next
# ota-check. Because the OS payload is content-addressed, beta-publish already pushed the WHOLE payload into
# the store (os-lynx) -- and replaced the payload every stable phone downloads, so the marker does NOT keep the general fleet on the old build (docs/backlog.md section E).
# So promote is a MARKER-ONLY copy -- read the source ring's published version and write it to the target
# ring's marker. No re-upload, instant, and safe to run any time after canary sign-off. Runs entirely
# through the EXISTING agent verbs (ota-check to read a ring, ota-mark to write one) via the
# NOWHERE_OTA_VERSION_REF override, so it needs no new device/agent build.
#
# Usage: e4-ota-promote.sh <store-conf> --device <dev> [agent_host] [--from <ring>] [--to <ring>] [--yes] [--force]
#   <store-conf>   the S3_* creds file (R2; the same store the device + e4-ota-publish use)
#   [agent_host]   native-linux agent (default /tmp/agent_host; the same binary e4-ota-publish uses)
#   --from <ring>  source ring to promote FROM   (default beta   -> ota/<dev>/version-beta)
#   --to   <ring>  target ring to promote INTO   (default stable -> ota/<dev>/version)
#   --device <dev> device/edition key -- REQUIRED, no default (NWP-20260901-08; the version ref is per-edition)
#   --yes          skip the interactive confirmation (for CI/automation)
#   --force        write even when target >= source (re-point / roll the general ring BACK to an older
#                  staged build); normally refused as a no-op/downgrade
#
# Ring -> marker ref: "stable" is the bare ota/<dev>/version (what every device reads by default); any other
# ring is ota/<dev>/version-<ring> (only devices opted into that ring read it). Promoting advances ONLY the
# target ring's marker; the source (beta) ring keeps pointing at the same build, so canary devices stay put.
set -euo pipefail

CONF=""
AGENT=/tmp/agent_host
FROM=beta
# NWP-20260901-08: no default here either. Promote is marker-only and so feels harmless, but getting the
# device wrong advances a DIFFERENT fleet's stable ring to whatever is sitting on its beta ring -- pushing an
# unvetted canary build to every device of a model you were not even thinking about. The ring defaults above
# stay (beta -> stable is the one flow this script exists for); the device is the parameter with no safe guess.
DEV=""
TO=stable
ASSUME_YES=0
FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --from)     FROM="${2:?--from needs a ring}"; shift ;;
    --from=*)   FROM="${1#--from=}" ;;
    --to)       TO="${2:?--to needs a ring}"; shift ;;
    --to=*)     TO="${1#--to=}" ;;
    --device)   DEV="${2:?--device needs a name}"; shift ;;
    --device=*) DEV="${1#--device=}" ;;
    --yes|-y)   ASSUME_YES=1 ;;
    --force)    FORCE=1 ;;
    -*)         echo "unknown flag: $1"; exit 2 ;;
    *)          if [ -z "$CONF" ]; then CONF="$1"; else AGENT="$1"; fi ;;
  esac
  shift
done
: "${CONF:?usage: e4-ota-promote.sh <store-conf> --device <dev> [agent_host] [--from beta] [--to stable] [--yes] [--force]}"
case "$DEV" in
  '' ) echo "refusing: --device is REQUIRED (e.g. --device frankel). Promoting the wrong device advances that"
       echo "          fleet's '$TO' ring to whatever sits on its '$FROM' ring."
       echo "          usage: e4-ota-promote.sh <store-conf> --device <dev> [agent_host] [--from beta] [--to stable] [--yes] [--force]"
       exit 2 ;;
  *[!a-z0-9]* ) echo "bad --device '$DEV' -- use lowercase alphanumerics (e.g. frankel)"; exit 2 ;;
esac
# NWP-20261124-19 (#23): no release for a device past GrapheneOS's full support (editions/endospore/support-ended/).
sh "$(dirname "$0")/support-guard.sh" "$DEV" || exit 2
[ -x "$AGENT" ] || { echo "agent_host not at $AGENT -- build: (cd core/agent && CGO_ENABLED=0 GOOS=linux go build -o $AGENT .)"; exit 2; }
# NWP-20260914-08: and is it THIS code? `-x` answers "a file is there", not "it is current". A binary built
# weeks ago publishes silently, and what it writes is the marker every fielded device reads. Rebuilt by hand
# before three consecutive releases purely because someone remembered.
#
# ⚠ THREE OUTCOMES, AND "CANNOT DETERMINE" IS NOT "FINE". That is the whole bug class this guard is part
# of: on 2026-09-13/14 three separate checks could not run and printed like passes.
AGENT_FRESH="$(dirname "$0")/check-agent-fresh.sh"
if [ -x "$AGENT_FRESH" ]; then
  "$AGENT_FRESH" "$AGENT"; FRESHRC=$?
  case "$FRESHRC" in
    0) : ;;
    1) echo "REFUSING: $AGENT is STALE. Rebuild it, then re-run:"
       echo "  (cd core/agent && CGO_ENABLED=0 GOOS=linux go build -o $AGENT .)"
       exit 2 ;;
    *) echo "⚠ could not check whether $AGENT is current (see the line above). Proceeding, but if this"
       echo "  publish behaves oddly, rebuild the agent FIRST and rule it out." ;;
  esac
else
  echo "⚠ check-agent-fresh.sh not found beside this script -- agent freshness was NOT checked."
fi
[ -f "$CONF" ] || { echo "store-conf not found: $CONF"; exit 2; }
W="$(mktemp -d)" || exit 2; trap 'rm -rf "$W"' EXIT
READ_RC_FILE="$W/read-rc"
for r in "$FROM" "$TO"; do
  case "$r" in ''|*[!a-z0-9]*) echo "bad ring '$r' -- use lowercase alphanumerics (e.g. beta, stable)"; exit 2 ;; esac
done
[ "$FROM" = "$TO" ] && { echo "--from and --to are both '$FROM' -- nothing to promote"; exit 2; }

. "$CONF"; export S3_ENDPOINT S3_REGION S3_BUCKET S3_ACCESS_KEY S3_SECRET_KEY
export SSL_CERT_DIR="${SSL_CERT_DIR:-/etc/ssl/certs}"

ring_ref() { case "$1" in stable) echo "ota/$DEV/version" ;; *) echo "ota/$DEV/version-$1" ;; esac; }
vlt() { [ "$1" = "$2" ] && return 1; [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]; }  # $1 < $2 ?

# Read a ring's currently-published version via the agent. ota-check compares against a running /system
# stamp; on the build host there is none, so it treats "running" as 0.0.0 and prints the marker's version
# whether it reports UPDATE or UPTODATE.
#
# NWP-20261024-05: THREE OUTCOMES, AND A FAILED READ MUST NEVER MEAN "ABSENT". Absent (exit 3 with the
# "no published OS version" line) is a fact about the store; a read that threw (an R2 5xx after the agent's
# retries, a 403, a DNS blip: exit 5 or 1 with nothing on stdout) is a fact about this attempt. This function
# used to fold the second into the first, so a transient failure reading the TARGET ring became "first promote
# onto this ring", skipped the downgrade guard, and rewrote a stable ring that was AHEAD of beta (a hotfix
# published straight to stable) back to the older beta build -- after which the read-back verify passed,
# because the marker now equalled the source. Stdout is the only signal the agent gives, so a version is
# accepted only from exit 0 with the UPDATE line or exit 1 with the UPTODATE line; stderr is kept, not
# discarded, and shown whenever a read is refused.
#   return 0  present: version on stdout       return 3  absent       return 4  could not read
read_ring() {  # read_ring <ring>
  local ref out rc line="" re
  ref="$(ring_ref "$1")"
  if out="$(NOWHERE_OTA_VERSION_REF="$ref" "$AGENT" ota-check s3 2>"$W/ota-check.err")"; then rc=0; else rc=$?; fi
  printf '%s' "$rc" > "$READ_RC_FILE"
  case "$rc" in
    0) re='^ota-check: UPDATE -> [0-9]+\.[0-9]+(\.[0-9]+)?$' ;;
    1) re='^ota-check: UPTODATE \(latest [0-9]+\.[0-9]+(\.[0-9]+)?\)$' ;;
    3) if printf '%s\n' "$out" | grep -qxF 'ota-check: no published OS version'; then return 3; fi ;;
  esac
  if [ -n "${re:-}" ]; then
    line="$(printf '%s\n' "$out" | grep -E "$re" | tail -1 || true)"
  fi
  if [ -n "$line" ]; then
    printf '%s\n' "$line" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | tail -1
    return 0
  fi
  {
    echo "[e4-ota-promote] could not read the '$1' ring ($ref): agent exit $rc, stdout: ${out:-<empty>}"
    echo "[e4-ota-promote] agent stderr:"
    sed 's/^/    /' "$W/ota-check.err"
  } >&2
  return 4
}

# Refuse a failed read: nothing was written, the operator retries.
refuse_unreadable() {  # refuse_unreadable <ring>
  echo "refusing: could not read the '$1' ring ($(ring_ref "$1"), agent exit $(cat "$READ_RC_FILE")) -- retry; nothing was written"
  exit 2
}

if SRC="$(read_ring "$FROM")"; then :; else
  case $? in
    3) echo "refusing: nothing is staged on the '$FROM' ring ($(ring_ref "$FROM")) -- publish it first (e4-ota-publish.sh --ring $FROM ...)"; exit 2 ;;
    *) refuse_unreadable "$FROM" ;;
  esac
fi
[ -n "$SRC" ] || { echo "refusing: the '$FROM' ring marker is empty/unparseable"; exit 2; }
# Absent target = first promote onto this ring. An UNREADABLE target is not that: it cannot be compared, so
# it refuses, --force included (the read-back verify below could not be trusted either).
if DST="$(read_ring "$TO")"; then :; else
  case $? in
    3) DST="" ;;
    *) refuse_unreadable "$TO" ;;
  esac
fi
DSTDISP="${DST:-<none>}"

echo "[e4-ota-promote] device $DEV: '$FROM' ring = $SRC  ->  '$TO' ring = $DSTDISP"
if [ -n "$DST" ] && ! vlt "$DST" "$SRC"; then
  if [ "$FORCE" != 1 ]; then
    echo "refusing: the '$TO' ring ($DSTDISP) is already >= the '$FROM' ring ($SRC) -- nothing to promote."
    echo "          (use --force to deliberately re-point '$TO' to '$SRC', e.g. to roll the fleet back.)"
    exit 2
  fi
  echo "[e4-ota-promote] --force: re-pointing '$TO' from $DSTDISP to $SRC (a NON-forward move; devices on '$TO' will see $SRC as the latest)."
fi

if [ "$ASSUME_YES" != 1 ]; then
  printf "Promote %s from the '%s' ring to the '%s' ring for device %s? [y/N] " "$SRC" "$FROM" "$TO" "$DEV"
  read -r ans
  case "$ans" in y|Y|yes|YES) ;; *) echo "aborted."; exit 1 ;; esac
fi

# The copy: write the target ring's marker to the source version. Marker-only -- the payload (os-<dev>) is
# already in the store from the beta publish, so devices on the target ring CDC-restore it on their next check.
NOWHERE_OTA_VERSION_REF="$(ring_ref "$TO")" "$AGENT" ota-mark s3 "$SRC"

# Verify the read-back so a silent write failure can't look like a successful promote.
if CHECK="$(read_ring "$TO")"; then :; else
  case $? in
    3) CHECK="" ;;
    *) echo "[e4-ota-promote] VERIFY FAILED: could not read back the '$TO' ring after writing '$SRC' -- check it before trusting the promote"; exit 1 ;;
  esac
fi
if [ "$CHECK" != "$SRC" ]; then
  echo "[e4-ota-promote] VERIFY FAILED: '$TO' ring now reads '${CHECK:-<none>}', expected '$SRC'"; exit 1
fi
echo "[e4-ota-promote] OK: '$TO' ring ($(ring_ref "$TO")) now = $SRC. Devices on the '$TO' ring update on their next ota-check; the '$FROM' ring is unchanged."
