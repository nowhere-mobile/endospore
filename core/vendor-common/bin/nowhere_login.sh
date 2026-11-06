#!/system/bin/sh
# Nowhere blind-login daemon launcher (P3.1). init creates the AF_UNIX socket nowhere_login and
# passes its fd (env ANDROID_SOCKET_nowhere_login); we source the store config + env and exec the
# agent's login-daemon, which reads name/pass from the chooser over that socket and restores the
# chosen profile's working set into the tmpfs IN-PROCESS. The passphrase only ever lives in the
# daemon's memory -- never on disk, never in any argv.
LOG=/data/nowhere/login.log
mkdir -p /data/nowhere
# Store config: prefer the provisioned, mutable /data copy (kept out of the read-only system image and
# rotatable without a reflash); fall back to a baked /system copy for older / un-migrated devices.
# (Superseded by NWP-20260908-06: the conf load below is a merge, ring first, /data on top -- not a /data-or-/system choice.)
# IMPORTANT (Tier 2): start the daemon even with NO conf -- a fresh free-OS flash ships with no store, and
# the Settings/Store screen talks to THIS daemon (GET-STORE / SET-STORE) to configure one in-place. With no
# store the daemon answers create/login with NOSTORE (gate -> Settings); the worker re-sources the conf each
# run, so a SET-STORE takes effect without a reboot.
# Store config: the BAKED ring conf first, then the PROVISIONED /data copy ON TOP -- a MERGE, per key.
#
# ⚠ IT USED TO REPLACE, AND THAT SILENTLY DISARMED EVERY RING SETTING THE DEVICE CONF DID NOT REPEAT.
# `CONF=/data/...; [ -f "$CONF" ] || CONF=/system/...` picks ONE file. On lynx the two shared ZERO keys:
# /data carried GATEWAY_URL, NOWHERE_MULTIDEVICE and NOWHERE_CARRY_ESSENTIAL, while the ring supplied
# NOWHERE_GATEWAY_DEFAULT, NOWHERE_SEQ_GUARD and OTA_RING -- so all three ring keys were simply gone, with
# no log line and no error. That is why NWP-20260907-16 shipped the sequential guard to the beta ring and
# NWP-20260907-22 measured it as never having been live: the flag was correct, the delivery was not.
#
# ORDER IS THE CONTRACT: the ring is the floor, the device conf overrides it key by key. So enrolment can
# still write GATEWAY_URL into /data and win, a partial or truncated /data conf can no longer take the
# gateway away with it, and a ring flag reaches a device that was provisioned before the flag existed.
#
# ⚠ ONE SEMANTIC CHANGES, DELIBERATELY: omitting a key from /data no longer turns it off, because the ring
# value survives. To disable a ring setting on a device, set it explicitly (FLAG=0) rather than deleting
# the line. Nothing in the fleet relied on the old behaviour -- it was not a feature, it was this bug.
#
# CONF is left naming the LAST file actually sourced, or empty if there was none, so a caller can still
# ask "was any conf loaded at all".
CONF=
for _nwconf in /system/etc/nowhere/nowhere.conf /data/nowhere/nowhere.conf; do
  if [ -f "$_nwconf" ]; then . "$_nwconf"; CONF="$_nwconf"; fi
done
unset _nwconf
if [ -n "$CONF" ]; then
  export S3_ENDPOINT S3_REGION S3_BUCKET S3_ACCESS_KEY S3_SECRET_KEY
  # GATEWAY_URL (managed-store billing, Slice B) rides the same conf and rotates via discovery; export it so
  # the daemon's pay-rent loop sees it. Exporting an unset value is harmless (empty -> billing simply off).
  export GATEWAY_URL
  # App-store dynamic sources (Phase 4c catalog + the F-Droid search index): the daemon reads os.Getenv here.
  # CATALOG_URL = where REFRESH-CATALOG pulls a fresh SIGNED catalog.json(.sig) (no-OTA storefront updates).
  # INDEX_URL   = where REFRESH-INDEX pulls the SIGNED trimmed F-Droid index (full-catalog search). Both empty
  # -> that refresh path is simply off and the baked /system copy is served (dynamic push disabled, not broken).
  export CATALOG_URL INDEX_URL STOREFRONT_URL
  # DIA-20260805-05: NOWHERE_GATEWAY_DEFAULT is which gateway the user's "nowhere store" choice ENROLS
  # against (handleSetStoreManaged), as distinct from GATEWAY_URL, which means "this device is ALREADY
  # enrolled". Sourcing the conf sets it as a shell var but the daemon reads os.Getenv, so without this
  # export a baked value is silently ignored and enrolment falls through to defaultGatewayURL = PROD.
  # That is the difference between a beta device enrolling against beta and against production.
  export NOWHERE_GATEWAY_DEFAULT
  # NWP-20261114-13: the beta-setup ring's DRAFT OS-agreement signal; the daemon serves it as GET-OS-AGREEMENT.
  export NOWHERE_OS_AGREEMENT
  echo "[login] store config loaded $(date)" >> "$LOG"
else
  echo "[login] no store configured yet -- daemon up for Settings/Store $(date)" >> "$LOG"
fi
# Discovery endpoint (baked default): lets a fresh device with NO store bootstrap its data-store config from
# name+passphrase (the daemon GETs a sealed config at an unguessable bootstrapRef). Sealed configs only ->
# the discovery endpoint sees ciphertext (zero-knowledge). Prefer the /data copy; fall back to a baked one.
DCONF=/data/nowhere/discovery.conf
[ -f "$DCONF" ] || DCONF=/system/etc/nowhere/discovery.conf
if [ -f "$DCONF" ]; then
  . "$DCONF"
  export DISCO_ENDPOINT DISCO_REGION DISCO_BUCKET DISCO_ACCESS_KEY DISCO_SECRET_KEY
  echo "[login] discovery endpoint loaded $(date)" >> "$LOG"
fi
export SSL_CERT_DIR=/system/etc/security/cacerts
# The agent auto-discovers the device's own per-network DNS (privacy: no public-resolver leak), with a
# public fallback only if discovery fails. Set NOWHERE_DNS=host[:port] to force a specific resolver.
export NOWHERE_DNS="${NOWHERE_DNS:-}"
export NOWHERE_STATE=/data/nowhere/state
# #91 slice 3: per-unit head model, enabled PER-DEVICE via the conf (default off). Sourced from the conf above;
# export it so the daemon's headKey/putHead see it. Staged rollout: NOWHERE_MULTIDEVICE=1 in nowhere.conf.
export NOWHERE_MULTIDEVICE="${NOWHERE_MULTIDEVICE:-0}"
# NWP-20260822-24 (-08f): two knobs that were DOCUMENTED as conf-settable and silently inert, because this
# launcher sources the conf but never exported them -- so the agent's os.Getenv always saw "".
#   ACTIVATION_JITTER_EPOCHS (billing.go): beta.conf sets 0 to remove the 0-2 day plan-activation delay on
#     the beta ring; without the export, beta devices kept the delay the ring exists to remove.
#   NOWHERE_SYNC_INTERVAL (the daemon syncLoop): nowhere.conf.example documents it, writeStoreConf goes out
#     of its way to PRESERVE it across store reconfiguration -- and it never reached the daemon.
# Guarded: only exported when the conf actually set them, so unset stays unset and the agent defaults hold.
[ -n "${ACTIVATION_JITTER_EPOCHS:-}" ] && export ACTIVATION_JITTER_EPOCHS
[ -n "${NOWHERE_SYNC_INTERVAL:-}" ] && export NOWHERE_SYNC_INTERVAL
# Cap-mode seal spills sealed blobs to disk (NOT the tmpfs state dir) so a multi-GB managed seal can't blow up
# RAM (#45). The managed CREATE + PROMOTE (throwaway -> stored profile) paths run capFlush in THIS daemon, so
# it needs the spill dir too -- roamd already exports it for the periodic/logoff seal. Without it spillDir()
# falls back to os.TempDir() (/tmp), which the daemon's domain can't write -> "open /tmp/capspill-...:
# permission denied" and the save/create fails. (#45 follow-on; surfaced on-device 2026-06-30.)
# NWP-20260907-13: the SEQUENTIAL-overwrite guard. DETECTION is always on in the agent and always logs
# ("STALE BASE ... refusal=<bool>"); this flag decides only whether such a seal is REFUSED. Default OFF,
# because when a handset has genuinely diverged there is no correct automatic answer -- it either loses
# its own unsealed session or overwrites the other handset -- and that is a product decision, recorded
# as OPEN in docs/product-decisions.md. Turn it on to MEASURE how often it fires in ordinary use.
#
# ⚠ EXPORTED HERE BECAUSE A CONF FLAG THE DAEMON DOES NOT EXPORT IS INERT, AND I SHIPPED EXACTLY THAT
# ONE COMMIT AGO. NWP-20260907-13 documented this flag in nowhere.conf.example and wired nothing, so
# setting it would have measured nothing and looked like a guard that never fires -- the same shape as
# multi-device.md's stale "roamd does not set NOWHERE_CARRY_ESSENTIAL" note, which I corrected in this
# same session. A flag is not shipped until something exports it.
export NOWHERE_SEQ_GUARD="${NOWHERE_SEQ_GUARD:-0}"
export NOWHERE_SPILL=/data/nowhere/spill
mkdir -p "$NOWHERE_SPILL"
echo "[login] daemon start $(date)" >> "$LOG"
exec /system/bin/nowhere_agent login-daemon >> "$LOG" 2>&1
