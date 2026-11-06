#!/system/bin/sh
# Nowhere on-device OTA updater (su:s0) -- DIA-20260618-03, "self-service OTA". On-demand worker (an app
# can't spawn su:s0): the caller writes $REQ then `setprop ctl.start nowhere_otad`; init runs this once and
# writes $RES. It asks the store whether a newer OS version is published and, if so, CDC-restores the payload
# (delta, via the chunk cache), applies it with update_engine, and reboots into the freshly written slot.
#   req (state tmpfs): present = check+apply (one line, the op, currently just "update")
#   res (state tmpfs): NONE | UPTODATE <ver> | STAGING | APPLYING <ver> | OK <ver> (reboot follows) | ERR-...
# The OS is public + content-addressed, so this carries NO profile creds (unlike nowhere_roamd).
STATE=/data/nowhere/state
REQ="$STATE/ota.req"
RES="$STATE/ota.res"
# NWP-20260901-05: fine-grained progress for the two LONG phases, written as ONE line
# "<phase> <done> <total>" -- the same shape the agent's writeProg already uses for the login bar, so the
# reader is one parser. OTA-STATUS serves it as an OPTIONAL SECOND LINE (see below). Lives on the state
# tmpfs beside ota.res, so it dies with the boot exactly as the phase file does.
PROG="$STATE/ota.prog"
RC="$STATE/ota.rc"                        # apply exit status, carried out of the progress pipe subshell
LOG=/data/nowhere/ota.log                 # status only
AGENT=/system/bin/nowhere_agent
PKG=/data/ota_package                      # update_engine staging dir -- NEVER rm/mkdir it (FBE policy); clear FILES only
# Per-edition OS payload ref. Each edition publishes its A/B payload under its OWN store ref -- the FP3
# (LineageOS) and Pixel (Endospore/GrapheneOS) images are NOT interchangeable, so a shared ref would cross
# the streams. The ref is baked per edition at /system/etc/nowhere/os-ref (the edition .mk PRODUCT_COPY_FILES
# it; same system-file label otad already reads nowhere.conf under, so no sepolicy change) and defaults to
# the FP3 ref so the shipping FP3 keeps working unchanged. The pass just keys the PUBLIC seal (carries no creds).
OSREF="$(cat /system/etc/nowhere/os-ref 2>/dev/null)"; OSREF="${OSREF:-os-fp3}"
OSPASS=nowhere-os

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
# GATEWAY_URL is what puts the agent in cap/managed mode (main.go capMode() = GATEWAY_URL set AND
# S3_ACCESS_KEY empty). A managed device's nowhere.conf holds ONLY GATEWAY_URL (writeManagedConf strips the
# S3_* lines), so WITHOUT this export the agent child sees an empty GATEWAY_URL, capMode() is false, and
# ota-check/restore fall to the credential-less s3 path -> minio-on-empty-creds crash -> otad reports "NONE"
# and silently never updates. Every sibling worker exports it beside the S3_* set (nowhere_login.sh,
# nowhere_roamd.sh, nowhere_mediad.sh); otad was the lone omission (the E.4 harvest ran under direct S3).
# Exporting an unset value is harmless (self-hosted/S3 devices keep their S3_* creds and ignore GATEWAY_URL).
export S3_ENDPOINT S3_REGION S3_BUCKET S3_ACCESS_KEY S3_SECRET_KEY GATEWAY_URL
export SSL_CERT_DIR=/system/etc/security/cacerts
# The agent auto-discovers the device's own per-network DNS (privacy: no public-resolver leak), with a
# public fallback only if discovery fails. Set NOWHERE_DNS=host[:port] to force a specific resolver.
export NOWHERE_DNS="${NOWHERE_DNS:-}"
# delta download: only fetch changed chunks (DIA-20260618-02). The cache holds the LAST restored payload's chunks
# only (NWP-20261017-11: the agent's pruneChunkCache runs after every complete restore) -- public OS update
# ciphertext, kept so the next update downloads only what changed.
export NOWHERE_CHUNK_CACHE=/data/nowhere/otacache

set_res() { echo "$1" > "$RES.tmp" 2>/dev/null && chmod 600 "$RES.tmp" 2>/dev/null && mv "$RES.tmp" "$RES" 2>/dev/null; }
# record_reboot_reason <reason> (NWP-20260904-10) -- the SAME file and shape the agent's recordRebootReason
# writes (core/agent/main.go): '<unix_seconds>\t<boot_id>\t<reason>\n', 0600, temp+rename. An issue report
# filed from the gate carries it as last_reboot_reason, so an owner's "why did it reboot?" is answerable
# without login.log. The reason is DEVICE-SCOPE BY CONTRACT: a version string is fine, a profile name never.
LASTREBOOT=/data/nowhere/last-reboot
record_reboot_reason() {
  bid=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null); bid=${bid:-unknown}
  printf '%s\t%s\t%s\n' "$(date +%s)" "$bid" "$1" > "$LASTREBOOT.tmp" 2>/dev/null \
    && chmod 600 "$LASTREBOOT.tmp" 2>/dev/null && mv -f "$LASTREBOOT.tmp" "$LASTREBOOT" 2>/dev/null
}
rm -f "$REQ"                               # consume the trigger immediately

# ---- suspend blocker (NWP-20260903-02) ---------------------------------------------------------------
# WHY THIS EXISTS. Nothing in the OTA path held a wakelock, so the SoC was free to suspend the moment the
# screen went off and the last framework wakelock dropped -- mid-apply. That is not update_engine's job and
# it does not do it: its .rc puts it in group `wakelock` (permission to use this exact interface) but NO
# code under system/update_engine ever writes the node. The CALLER is expected to hold one, and GrapheneOS's
# own updater -- the app this script replaced -- does precisely that:
# packages/apps/Updater/src/app/seamlessupdate/client/Service.java acquires a PARTIAL_WAKE_LOCK before the
# download and releases it in the finally. We took over its job and did not carry its wakelock across.
# init also de-prioritises update_engine on purpose (task_profiles OtaProfiles = ServiceCapacityLow +
# LowIoPriority + HighEnergySaving), which is survivable while awake and is a different thing from frozen.
# SYMPTOM THAT LED HERE: apply legs of 644s / 1260s / 3656s, the LONGEST being an overnight apply of the
# SMALLEST delta. Chester: "when the screen doses off, ota update seems to be getting stuck".
# su:s0 may write both nodes -- device-probed on lynx in this exact domain, so no sepolicy change.
WLNAME=nowhere_ota
wl_release() { echo "$WLNAME" > /sys/power/wake_unlock 2>/dev/null; }
susp() { cat /sys/power/suspend_stats/success 2>/dev/null || echo "?"; }
# A leaked KERNEL wakelock never expires -- unlike a framework PARTIAL_WAKE_LOCK it has no owner and no
# timeout, so the phone simply never suspends again until it reboots. On an amnesiac device that is a
# battery bug with no diagnostic trail. THE TRAP IS THE GUARD: this script has seven `exit 0`s plus a
# reboot, and a trap is the only way to cover them all that does not rot on the next edit (an explicit
# release before each exit is the version someone forgets to add to exit eight).
# The bare wl_release below is belt-and-braces only, and worth being honest about: the trap already covers
# every path THIS run can take, so it changes the outcome solely when a PREVIOUS run was SIGKILLed past its
# own trap -- and even then the leak dies at the next reboot, because /sys/power/wake_lock is kernel state.
# It is one cheap line, it is the conventional release-before-acquire idiom, and it is deliberately NOT
# claimed as tested: no mutation of it changes observable behaviour, which is the definition of untestable.
wl_release
trap wl_release EXIT INT TERM HUP
if echo "$WLNAME" > /sys/power/wake_lock 2>/dev/null; then
  echo "[otad] wakelock $WLNAME held (suspends since boot: $(susp)) $(date)" >> "$LOG"
else
  echo "[otad] WARNING: /sys/power/wake_lock refused -- apply can stall while the screen is off" >> "$LOG"
fi

# #59: reconcile stale update_engine state. A fastboot-flashed device can carry a leftover
# UPDATED_NEED_REBOOT (a prior OTA apply that a manual flash superseded) -- update_engine would then nag or
# flip slots out from under the flashed image. No apply is in flight when this worker STARTS (we haven't
# kicked update_engine yet this run), so an unconditional reset here is always safe; the apply path below
# does its own reset right before --update, exactly as before.
update_engine_client --reset_status >> "$LOG" 2>&1 || true

# Runs on the user's confirmed Install (the daemon's ctl.start), which can follow a network change, so give the
# network a moment before hitting the store: else ota-check cannot reach the store, exits 5, and the gate shows
# the retryable ERR-CHECK. Android's netd keeps every network's routes, its default included, in that network's
# own table (`table wlan0`, `table rmnet_data0`), never the main one, so ask for every table, both families. A
# line counts when it begins with `default ` and its device is not dummy0 (NWP-20261117-37): netd's
# RouteController::Init installs a v4 and a v6 default through its dummy (black-hole) network into table dummy0
# at every start, whether or not any real network is up, so counting it ended the wait at its first pass. A
# restricted cellular default (IMS on a VoLTE SIM) still counts; the wait cannot tell it apart. Best effort: with
# no counted default in ~40 s the wait logs one line and falls through to the check below.
i=0; while [ $i -lt 20 ]; do
  _rt=$( { ip route show table all; ip -6 route show table all; } 2>/dev/null | grep -v -E '^default (.* )?dev dummy0( |$)' )
  case "
$_rt" in *"
default "*) break ;; esac
  sleep 2; i=$((i+1))
done
[ $i -lt 20 ] || echo "[otad] no default route in any table after 40 s -- checking anyway $(date)" >> "$LOG"

# 1. Is a newer OS published?  Each ota-check status and the verdict this step writes, in script order:
#   124 (toybox `timeout` expired)                       -> ERR-CHECK
#   5 (the store could not be reached)                   -> ERR-CHECK
#   1 without its `ota-check: UPTODATE` line             -> ERR-CHECK (a failed check)
#   1 with that line                                     -> UPTODATE <ver>
#   3 with its `ota-check: no published OS version` line -> NONE
#   any other non-zero, 3 without that line too          -> ERR-CHECK
#   0                                                    -> STAGING
# A verdict needs ota-check to SAY it (the NWP-20261006-21 rule for UPTODATE, extended to NONE by
# NWP-20261123-25). `case "ota-check":` prints a verdict line for 0, 1 and 3 only; any other status is no answer:
# 2 is a Go runtime panic the dispatch did not recover, 126/127 an agent that is not executable or not there,
# 137/143 a kill. Read as NONE, a crashed check on a confirmed Install served the cached AVAIL again (otaResState
# maps NONE to "") and the gate showed "Update available" with no failure; ERR-CHECK is "FAILED ERR-CHECK", which
# the gate words as retryable. Bound every store step so a wedged network (e.g. the 2-SIM unbound-socket
# false-offline) surfaces a retryable FAILED at the gate instead of pinning the phase forever (the #23 "frozen
# Installing..." class). ERR-CHECK is distinct from NONE so a transport hang doesn't masquerade as "up to date /
# nothing published".
out=$(timeout 120 "$AGENT" ota-check s3 2>>"$LOG"); rc=$?
ver=$(echo "$out" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | tail -1)
if [ "$rc" = 124 ]; then echo "[otad] ota-check TIMED OUT $(date)" >> "$LOG"; set_res "ERR-CHECK"; exit 0; fi
# NWP-20261006-21: "up to date" only when ota-check SAID so. The agent's recovered panic also exits 1, so a
# store that failed in transport read as up to date; a transport failure now exits 5 (exitStoreUnreachable),
# and any other 1 without the UPTODATE line is a failed check, not an answer.
if [ "$rc" = 5 ]; then echo "[otad] ota-check could not reach the store $(date)" >> "$LOG"; set_res "ERR-CHECK"; exit 0; fi
# NWP-20261017-26: `| grep -q` is safe here only because this script sets no pipefail (a SIGPIPE'd `echo` cannot flip it); convert before adding one.
if [ "$rc" = 1 ] && ! echo "$out" | grep -q "ota-check: UPTODATE"; then echo "[otad] ota-check FAILED (rc=1, no verdict) $(date)" >> "$LOG"; set_res "ERR-CHECK"; exit 0; fi
if [ "$rc" = 1 ]; then echo "[otad] up to date $(date)" >> "$LOG"; set_res "UPTODATE ${ver:-?}"; exit 0; fi
if [ "$rc" = 3 ] && [ "${out#*ota-check: no published OS version}" != "$out" ]; then echo "[otad] no published version (rc=$rc) $(date)" >> "$LOG"; set_res "NONE"; exit 0; fi
if [ "$rc" != 0 ]; then echo "[otad] ota-check FAILED (rc=$rc) $(date)" >> "$LOG"; set_res "ERR-CHECK"; exit 0; fi
echo "[otad] update available -> $ver $(date)" >> "$LOG"; set_res "STAGING"

# 2. CDC-restore the payload (delta via the chunk cache). Clear the FILES in the staging dir, keep the dir.
rm -f "$PKG/payload.bin" "$PKG/payload_properties.txt"
# NWP-20260901-05: the agent ALREADY reports byte progress through writeProg -- it is simply env-gated on
# NOWHERE_PROGRESS, which otad never set, so every OTA download ran blind behind a spinner. Setting it here
# costs one env var and gives the gate real bytes for a multi-GB fetch. The phase name is what the UI
# switches on; `osdownload` distinguishes THIS from update_engine's own internal "DOWNLOADING" status,
# which is a different thing entirely (see the apply loop below).
if ! NOWHERE_PROGRESS="$PROG" NOWHERE_PHASE=osdownload \
     timeout 1800 "$AGENT" restore s3 "$OSREF" "$OSPASS" "$PKG" >> "$LOG" 2>&1; then
  # NWP-20261120-11: the restore O_TRUNC-writes each entry straight into $PKG, so a failed or killed one leaves a partial payload; free it (the chunk cache keeps the delta). FILES only, never the dir (FBE policy).
  echo "[otad] restore FAILED/timeout $(date)" >> "$LOG"; rm -f "$PKG/payload.bin" "$PKG/payload_properties.txt"; echo "[otad] partial payload removed from $PKG after a failed download (NWP-20261120-11) $(date)" >> "$LOG"; rm -f "$PROG"; set_res "ERR-RESTORE"; exit 0
fi
rm -f "$PROG"                              # the download is done; don't let its last frame bleed into the apply
restorecon -R "$PKG" 2>> "$LOG"            # ota_package_file label; does NOT touch the FBE policy
[ -s "$PKG/payload.bin" ] && [ -s "$PKG/payload_properties.txt" ] || {
  echo "[otad] payload missing after restore $(date)" >> "$LOG"; rm -f "$PKG/payload.bin" "$PKG/payload_properties.txt"; echo "[otad] partial payload removed from $PKG after an incomplete download (NWP-20261120-11) $(date)" >> "$LOG"; set_res "ERR-PAYLOAD"; exit 0; }

# 3. Apply with update_engine, then reboot into the freshly written (inactive) slot. /data is untouched
# (a slot switch, not the amnesiac power-off wipe), so the user logs back into the same data on the new OS.
set_res "APPLYING ${ver:-?}"
update_engine_client --reset_status >> "$LOG" 2>&1
# 90-min backstop: a full A/B VABC apply legitimately runs ~40min on lynx, but a genuinely wedged
# --follow (proven NOT to occur under the harvested enforcing sepolicy, but belt-and-suspenders) must not
# pin ota.res at APPLYING forever. If the timeout ever fires mid-apply it kills only the client (not the
# update_engine daemon), leaving a staged slot that the next boot's #59 reset_status reconciles cleanly.
# NWP-20260901-05: PARSE --follow instead of dumping it in the log. update_engine_client calls
# brillo::InitLog(brillo::kLogToStderr) (aosp/update_engine_client_android.cc:197), so its
# `onStatusUpdate(<STATUS> (<code>), <progress>)` frames were ALREADY arriving here on stderr under the old
# `>> "$LOG" 2>&1` -- carrying both the phase and a 0..1 fraction, and being thrown away. The gate showed a
# bare spinner for the whole thing, and a full VABC apply legitimately runs ~40 min on lynx, so owners
# reasonably read it as hung. The frames name the phase too, which matters more than the number: "Verifying"
# for eight minutes is patience, an unexplained bar for eight minutes is a wedge.
#
# ⚠ THE EXIT STATUS MUST SURVIVE THE PIPE. `cmd | while ...` makes the pipeline's status that of the WHILE,
# so a failed apply would read as success and the phone would reboot into an unwritten slot. mksh does have
# `set -o pipefail`, but toybox/mksh behaviour across editions is not something to bet a reboot on: carry
# the real status out through a file written INSIDE the subshell, where the redirect keeps it out of the pipe.
#
# ⚠ THE PARENTHESES MUST COME FROM VARIABLES, NOT LITERALS. `${line#*onStatusUpdate(}` is a parse ERROR in
# mksh (the device's /system/bin/sh): the unbalanced `(` inside the expansion makes it consume the closing
# brace looking for a match, and the failure surfaces far away as "syntax error: unmatched '{'" on the
# enclosing block. Device-caught while writing this, not reasoned about -- the whole worker would have
# failed to parse, so EVERY OTA would have died at the apply step.
UE_OPEN='onStatusUpdate('
UE_CLOSE=')'
rm -f "$RC"
APPLY_S0=$(susp); APPLY_T0=$(date +%s)
( timeout 5400 update_engine_client --update --follow --payload="file://$PKG/payload.bin" \
        --headers="$(cat "$PKG/payload_properties.txt")" 2>&1; echo "$?" > "$RC" ) |
while IFS= read -r line; do
  case "$line" in
    *"$UE_OPEN"*) ;;
    # Everything that is not a progress frame is real diagnostic output -- keep it verbatim.
    *) printf '%s\n' "$line" >> "$LOG"; continue ;;
  esac
  st=${line#*"$UE_OPEN"}; st=${st%% *}               # "DOWNLOADING (2), 0.4530)" -> "DOWNLOADING"
  frac=${line##*, }; frac=${frac%"$UE_CLOSE"}        # -> "0.4530"
  # 0..1 float -> whole percent, without awk (Android ships toybox; there is no awk in /system/bin).
  # NWP-20261121-11: update_engine_client streams the float with default ostream formatting (%g, 6 significant
  # digits), so a progress under 1e-4 arrives as `1.52588e-05`. A progress in [0,1] in that form is below 1 %.
  # Without the first arm, a mantissa of 1.x matched `1|1.*` and read as 100 %.
  case "$frac" in
    *[eE]*) pct=0 ;;
    1|1.*) pct=100 ;;
    0.*)   d=${frac#0.}; d="${d}00"; d=${d%"${d#??}"}; pct=$((10#$d)) ;;
    *)     pct=0 ;;
  esac
  # update_engine's own "DOWNLOADING" is NOT a download -- the payload is already local by now; it is the
  # write into the inactive slot. Naming it "downloading" to the owner would be actively misleading, which
  # is why these are our own phase words rather than a pass-through of the enum.
  # NWP-20260901-20: the strings are UPDATE_STATUS_*-PREFIXED. Device-proven on lynx:
  #   [INFO:update_engine_client_android.cc(94)] onStatusUpdate(UPDATE_STATUS_IDLE (0), 0)
  # UpdateStatusToString returns "UPDATE_STATUS_DOWNLOADING" etc., NOT the bare enum label -- the first
  # 0.5.12 apply on frankel matched nothing here, every frame fell through to `continue`, ota.prog was never
  # written, and the whole apply showed the "Working" fallback. The original patterns were written from the
  # `case UpdateStatus::IDLE:` labels after a grep for the returned strings came back EMPTY -- that empty
  # result was the warning, and building on the labels anyway was the mistake. Suffix-matched (*DOWNLOADING)
  # so a future Android dropping the prefix cannot break this the same way twice.
  case "$st" in
    *DOWNLOADING)             ph=oswrite ;;
    *VERIFYING)               ph=osverify ;;
    *FINALIZING)              ph=osfinalize ;;
    *CLEANUP_PREVIOUS_UPDATE) ph=oscleanup ;;
    *UPDATED_NEED_REBOOT)     ph=osdone; pct=100 ;;
    *)                        continue ;;             # IDLE / CHECKING / error states -> nothing to show
  esac
  [ "$ph $pct" = "$last" ] && continue                # only on a real change; ~100 tmpfs writes per phase
  last="$ph $pct"
  printf '%s %s 100\n' "$ph" "$pct" > "$PROG.tmp" && mv -f "$PROG.tmp" "$PROG"
  if [ "$ph" != "$lastph" ]; then                     # log PHASE changes, not every percent
    printf '[otad] apply phase %s %s\n' "$st" "$(date)" >> "$LOG"; lastph="$ph"
  fi
done
rc=$(cat "$RC" 2>/dev/null); rc=${rc:-1}; rm -f "$RC"
APPLY_S1=$(susp); APPLY_T1=$(date +%s)
# THE MONEY LINE. A non-zero delta means the device suspended DURING the apply, i.e. the wakelock above is
# absent or was refused -- which is exactly the failure this slice fixes, so on a fixed build it must read 0.
# Kept permanently: it turns "the update feels stuck" into a measurement the owner's next OTA log answers.
case "$APPLY_S0$APPLY_S1" in
  *"?"*) SUSPD="unknown" ;;
  *)     SUSPD=$((APPLY_S1-APPLY_S0)) ;;
esac
echo "[otad] apply leg rc=$rc took $((APPLY_T1-APPLY_T0))s, suspends during apply: $SUSPD $(date)" >> "$LOG"
if [ "$rc" = 0 ]; then
  echo "[otad] applied $ver -> rebooting $(date)" >> "$LOG"; rm -f "$PROG"; set_res "OK ${ver:-?}"
  record_reboot_reason "otad: OTA ${ver:-?} applied, rebooting into the new slot"
  # NWP-20261109-10: update_engine has finished with the payload (UPDATED_NEED_REBOOT), so free it BEFORE the reboot. FILES only, never the dir (FBE policy).
  rm -f "$PKG/payload.bin" "$PKG/payload_properties.txt"; echo "[otad] applied payload removed from $PKG (NWP-20261109-10) $(date)" >> "$LOG"
  sync; reboot
else
  # The failure branch keeps the files: a timed-out client may leave update_engine still reading, and the next run's step 2 clears them.
  echo "[otad] update_engine FAILED/timeout (rc=$rc) $(date)" >> "$LOG"; rm -f "$PROG"; set_res "ERR-APPLY"
fi
