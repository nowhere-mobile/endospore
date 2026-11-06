#!/system/bin/sh
# Nowhere first-boot provisioning: make the chooser the DEVICE OWNER so it can drive the kiosk Lock
# Task on the gate -- with NO manual adb. Runs once per fresh /data (a marker, cleared by a factory
# reset). su:s0 (not the confined nowhere domain) because dpm/settings need broad framework access.
LOG=/data/nowhere/provision.log
MARK=/data/nowhere/.provisioned
ADMIN=com.nowhere.chooser/.AdminReceiver
mkdir -p /data/nowhere

# Count the tmpfs mounts on /data/nowhere/state, once per run (NWP-20261128-28). nowhere.rc's
# `on property:sys.boot_completed=1` action mounts the state tmpfs and then starts this script, so a boot shows 1.
# WHY: AOSP init queues a property trigger on EVERY set of the property, the same value included (property_service
# PropertySet -> PropertyChanged -> ActionManager::QueuePropertyChange; no same-value check), and
# ActivityManagerService sets sys.boot_completed=1 at every system_server start. So a framework restart re-runs the
# action and stacks a second, empty tmpfs over the live state dir: the departed session's files (.roamsession,
# mediad.req) stay in RAM under it, out of every clean-up's reach, until power-off. Read from source, NOT measured:
# this line is the evidence. 2 or more = the action ran again; 0 = the state dir is not a tmpfs at all (the #30
# case state_tmpfs.go refuses); unreadable = the read failed or was empty, never 0. The fix is a once-per-boot
# guard on the mount in nowhere.rc, an init change that needs an image build and a boot to prove. Above the marker
# exit on purpose: the marker exists on every boot after the first.
# The table reaches grep through a here-document, never as a `printf '%s\n'` argument: the device's mksh has no
# printf builtin, and one argument over 128 KiB fails with E2BIG (roamd's stop_mediad states the same rule).
# No cmd runs here, so the /dev/null stdio rule at owner_ok does not apply. No /proc/uptime: endospore_priv has no
# read of it. Pinned by test-provision-state-mounts.sh, which extracts the block by the two anchor lines.
# STATE-MOUNTS-BEGIN (NWP-20261128-28)
_sm_t=$(cat /proc/mounts 2>/dev/null); _sm_rc=$?
_sm_n=unreadable
if [ "$_sm_rc" -eq 0 ] && [ -n "$_sm_t" ]; then
  _sm_n=$(grep -c '^[^ ]* /data/nowhere/state tmpfs ' <<EOF_SM
$_sm_t
EOF_SM
)
  case "$_sm_n" in ''|*[!0-9]*) _sm_n=unreadable ;; esac
fi
echo "[provision] start: state tmpfs mounts=$_sm_n (one per boot; 2 or more = nowhere.rc's boot_completed action ran again over a live state dir, NWP-20261128-28) $(date)" >> "$LOG"
# STATE-MOUNTS-END

# DEV (userdebug) ONLY: enable `adb root` durably. LineageOS gates `adb root` behind the IADBRootService,
# whose enabled-state is the file /data/adbroot/enabled -- normally written only by the Settings "Rooted
# debugging" toggle (system uid), which is UNREACHABLE on this product because the kiosk hides Settings. We
# already run as root on every boot (above the run-once marker), so seed the file + relabel + bounce the
# service. Userdebug-only, so production `user` builds are untouched. (DIA-20260625-02 -- on-device debugging.)
if [ "$(getprop ro.build.type)" = "userdebug" ]; then
  mkdir -p /data/adbroot
  echo 1 > /data/adbroot/enabled
  restorecon -R /data/adbroot 2>/dev/null
  setprop ctl.restart adb_root
fi

[ -f "$MARK" ] && exit 0

# boot_completed can still race the package scan on a very first boot; wait for the chooser to exist.
i=0
while [ "$i" -lt 10 ]; do
  pm path com.nowhere.chooser >/dev/null 2>&1 && break
  i=$((i + 1)); sleep 2
done

# Is the chooser the DEVICE OWNER? Read the state file system_server persists, do NOT parse `dpm list-owners`.
# WHY (the bug that made a freshly-wiped device stay a NON-kiosk gate forever): a `cmd` invocation -- which is
# what dpm/pm/am/settings all are -- hands ITS stdio fds to system_server over the binder transaction so the
# service can write the reply. From this su:s0 init service those fds point at our LOG (nowhere_data_file) or,
# for `$(...)`/pipes, an su:s0 fifo -- and system_server is DENIED use of both under enforcing sepolicy, so the
# whole transaction aborts ("Failure calling service ...: Failed transaction (2147483646)") and the command
# NEVER RUNS. (The same call from `adb shell` works: shell's pty fds are ones system_server services freely --
# which is why a manual `dpm set-device-owner` always fixed it.) So: every cmd below sends stdio to /dev/null
# (a null_device fd system_server CAN use -> the call actually executes), and we read success from the file
# system_server already wrote in its own context (no fd hand-off). device_policies.xml lists the *active admin*
# even without ownership -> would false-positive; only device_owner*.xml means DEVICE OWNER.
owner_ok() {
  for f in /data/system/device_owner_2.xml /data/system/device_owner.xml; do
    [ -f "$f" ] && grep -q "com.nowhere.chooser" "$f" 2>/dev/null && return 0
  done
  return 1
}

# A FOREIGN device-owner -- a DO record present that is NOT us (e.g. a pre-rename com.diaspore.chooser left in
# /data by a system-only reflash) -- BLOCKS set-device-owner (one DO is allowed, no cross-package transfer)
# and can't be cleared from outside the owning app. So a package RENAME on a provisioned device is a hard
# factory-reset migration (docs/rename-migration.md). Only consulted when owner_ok is already false, so any DO
# record found here is foreign. Detect it to log a clear signal instead of burning the retry budget on a
# doomed set + leaving a silent non-kiosk gate.
# THE RECORD IS ABX ON ANDROID 12+ (NWP-20261127-12). system_server writes it through Xml.resolveSerializer,
# which emits Android Binary XML: an attribute name is an interned string and its value a 2-byte length plus
# the bytes, so no `=` byte is ever written -- the old `grep 'package='` never matched, and a foreign owner was
# retried 60 times every boot. So the test is the TAG NAME `device-owner` (OwnersData's tag for the device
# owner), the one token that is byte-identical in text XML (`<device-owner`) and in ABX (the interned tag
# string); `-a` reads the NUL-bearing file as text (toybox grep accepts it). A record with no device owner
# (only a system-update-policy) does not hold it, so the claim runs. owner_ok needs no such change: the value
# `com.nowhere.chooser` is written verbatim in both encodings.
foreign_owner() {
  for f in /data/system/device_owner_2.xml /data/system/device_owner.xml; do
    [ -f "$f" ] && grep -q -a 'device-owner' "$f" 2>/dev/null && return 0
  done
  return 1
}

# FRP-WINDOW-BEGIN  (NWP-20261011-14) -- narrow the pre-device-owner window.
# docs/owner-identity-spec.md §5.5 and docs/owner-claim-spec.md §7.1. Between boot_completed and the
# device-owner claim below (~180 s on a fresh /data) nothing Nowhere-owned enforces anything: launcher3 is a
# fallback home, lockGate() is inert until the chooser owns the device, and Settings -> About phone -> Build
# number x7 -> Developer options -> OEM unlocking is open -- the one route that defeats reset protection. So,
# for as long as the chooser is NOT the owner, hold development_settings_enabled and adb_enabled at 0 every
# 3 s, 100 passes at most (5 min). It sits BELOW the marker early-exit on purpose: the marker is written only
# once owner_ok, so an unmarked boot IS the window.
# ⚠ A NARROWING, NOT A CLOSURE: it does not close an already-open Developer options screen, does not revert
# an OEM-unlock bit already written, leaves a 3 s gap per pass, and is retried once per reset (owner-claim-spec
# §8 H1 measures the race on hardware). Only setOemUnlockEnabled(false) from the claimed chooser reverts a
# written bit, and that is not this script.
# ⚠ NOT a check of the pdb record: this script CANNOT read it (su:s0 / endospore_priv have no blk_file rule,
# and AOSP's frp_block_device neverallow makes adding one a COMPILE failure). The loop is blind by design.
# Skipped on a debuggable build because the dev block below deliberately turns both keys ON. Backgrounded so
# it never delays the claim; the parent logs ONE line (no profile data), the loop logs nothing. Every cmd's
# stdio is /dev/null for the fd-passing reason at owner_ok. Init kills a oneshot service's process group
# when the main process exits (AOSP init, vendor API >= R; read from source, not measured), so on such a
# vendor the loop lives at most as long as this script -- by then owner_ok has ended it or the claim has
# given up for this boot. Pinned by test-provision-frp-window.sh, which extracts this block by the two
# anchor lines -- keep them, and keep each settings line on one line.
if [ "$(getprop ro.debuggable)" != "1" ]; then
  echo "[provision] pre-owner window: holding developer options/adb off until device owner $(date)" >> "$LOG"
  ( n=0
    while [ "$n" -lt 100 ]; do            # 100 x 3s = 5 min hard cap
      owner_ok && break                   # the chooser owns the device; the gate takes over
      settings put global development_settings_enabled 0 </dev/null >/dev/null 2>&1
      settings put global adb_enabled 0 </dev/null >/dev/null 2>&1
      n=$((n + 1)); sleep 3
    done ) &
fi
# FRP-WINDOW-END

# Un-stop the chooser so its DeviceAdminReceiver can register/enable. A freshly-flashed system app is in the
# Android-12+ STOPPED state, and its admin can't be activated until the app has been launched once.
am start -n com.nowhere.chooser/.ChooserActivity </dev/null >/dev/null 2>&1

# Claim DEVICE OWNERSHIP. At boot_completed the device is briefly not ready in several transient ways (admin
# not registered with DPMS yet; a transient boot-time account; services still overloaded), all of which clear
# once it settles. The old code blamed THIS for the failures and added a 180s "readiness probe" + retries that
# STILL failed -- because the real cause was the fd-passing denial above (the probe's `dumpsys account | grep`
# went through an su:s0 pipe and never succeeded; the set attempt's `$(...)` capture aborted the transaction).
# With stdio fixed to /dev/null the call actually executes, and a plain retry loop subsumes the readiness wait:
# keep trying (set-active-admin re-registers the admin each pass; device_provisioned toggled 0 around the set,
# as set-device-owner requires) until ownership STICKS in the file, or a generous cap. We mark done (far below)
# ONLY once owner_ok, so a still-not-ready first boot re-attempts next boot instead of stranding a non-kiosk.
attempt=0
if owner_ok; then
  : # already owned by us
elif foreign_owner; then
  # A different package owns the device (almost always a pre-rename com.diaspore.chooser left in /data by a
  # system-only reflash). set-device-owner cannot override it and it can't be cleared from here, so retrying
  # is pointless -- the device needs a FACTORY RESET to re-provision (user data is safe; it roams from the
  # store). See docs/rename-migration.md. Logged every boot (no marker is written) until the reset.
  echo "[provision] FOREIGN device-owner present (not com.nowhere.chooser) -- a package rename can't transfer ownership; a FACTORY RESET is required to re-provision (docs/rename-migration.md). Not retrying. $(date)" >> "$LOG"
else
  while ! owner_ok && [ "$attempt" -lt 60 ]; do
    settings put global device_provisioned 0 </dev/null >/dev/null 2>&1
    settings put secure user_setup_complete 0 </dev/null >/dev/null 2>&1
    dpm set-active-admin --user 0 "$ADMIN" </dev/null >/dev/null 2>&1
    dpm set-device-owner "$ADMIN" </dev/null >/dev/null 2>&1
    settings put global device_provisioned 1 </dev/null >/dev/null 2>&1
    settings put secure user_setup_complete 1 </dev/null >/dev/null 2>&1
    owner_ok && break
    attempt=$((attempt + 1))
    sleep 3
  done
fi
if owner_ok; then
  echo "[provision] device-owner CONFIRMED after $attempt attempts $(date)" >> "$LOG"
elif ! foreign_owner; then
  echo "[provision] device-owner NOT set after $attempt attempts -- will retry next boot $(date)" >> "$LOG"
fi

# Disable the redundant keyguard/lockscreen. The blind-login gate IS the lock (there is no PIN), so the
# default swipe keyguard only flashes for ~1s before the gate kiosks at boot. Done here (su:s0, once per
# fresh /data) so it's DURABLE -- the equivalent runtime `locksettings set-disabled true` is wiped by a
# factory reset / unlock. (/dev/null stdio: same fd-passing reason as above.)
locksettings set-disabled true </dev/null >/dev/null 2>&1
_rc=$?
echo "[provision] keyguard disable rc=$_rc $(date)" >> "$LOG"

# Dev convenience (DIA-20260623-25): on a DEBUGGABLE build, keep ADB usable across the /data wipe. A fresh
# /data defaults USB-debugging OFF, and the device-owner kiosk gate blocks Developer options -- so a wiped
# dev device strands the adb loop with no in-OS way back. Guarded to ro.debuggable=1, so a user/production
# build NEVER does this. (/dev/null stdio: the cmd fd-passing reason as above, DIA-20260616-56.)
if [ "$(getprop ro.debuggable)" = "1" ]; then
  settings put global development_settings_enabled 1 </dev/null >/dev/null 2>&1
  settings put global adb_enabled 1 </dev/null >/dev/null 2>&1
  echo "[provision] (dev/debuggable) adb_enabled set so it survives the wipe $(date)" >> "$LOG"
fi

# Privacy DNS (DIA-20260709): force encrypted DNS-over-TLS to a no-logging privacy resolver (Mullvad) instead of
# the network's cleartext DHCP resolvers -- so DNS isn't handed in plaintext to whatever Wi-Fi the phone joins.
# private_dns_mode/specifier are GLOBAL (device-wide -> the gate + every roamed user), set here as the durable
# out-of-box default; the user can still change it in Settings. Proven on FP3: DoT validates to Mullvad
# (194.242.2.2 / 2a07:e340::2) + resolves. (Relayed/anonymized DNS -- ODoH -- is the later, stronger step.)
# NWP-20260922-04: HIDE THE USER SWITCHER. Chester asked how Android's switch-user should behave here;
# this is the surface half of the answer, and deliberately NOT the policy half.
#
# WHY NOT DISALLOW_USER_SWITCH. The gate switches users at four sites and every one uses
# ActivityManager.switchUser; the device-owner exemption AOSP documents is for DevicePolicyManager
# .switchUser, an API this tree has never called. UserManagerService checks the restriction SEPARATELY
# from this setting, so the restriction would gate our own logins while this row does not -- and
# check 13 in section 7 of docs/fleet-lock-design.md already calls that flag "a fleet-wide brick outright".
#
# WHAT THIS ACTUALLY REACHES, read from the GrapheneOS tree rather than assumed:
# UserManagerService.isUserSwitcherEnabled() reads exactly this Global row (defaulting to
# config_showUserSwitcherByDefault), and the surfaces that consult it include GlobalActionsDialogLite
# (the POWER MENU -- the only switch surface reachable at the gate, where the shade and QS are already
# blocked), the QS user switcher, the bouncer and the keyguard status bar.
#
# ⚠ IT MUST BE SET EXPLICITLY, NOT LEFT UNSET. UserManagerService turns the switcher ON when a user is
# created, but ONLY when this row is null: "If the user switch hasn't been explicitly toggled on or off
# by the user, turn it on." Nowhere creates a user on EVERY login, so an unset row is re-enabled at the
# next sign-in -- which is exactly why a fielded lynx measured 1 with nothing in this tree ever setting
# it. Writing 0 makes the row non-null, and the framework then leaves it alone.
settings put global user_switcher_enabled 0 </dev/null >/dev/null 2>&1
settings put global private_dns_mode hostname </dev/null >/dev/null 2>&1
settings put global private_dns_specifier dns.mullvad.net </dev/null >/dev/null 2>&1
# Read them BACK, as the dropbox block below does: assert the value, never the call (NWP-20261110-18).
_dnsmode=$(settings get global private_dns_mode </dev/null 2>/dev/null)
_dnsspec=$(settings get global private_dns_specifier </dev/null 2>/dev/null)
if [ "$_dnsmode" = hostname ] && [ "$_dnsspec" = dns.mullvad.net ]; then
  echo "[provision] private DNS = DoT dns.mullvad.net (no-log) $(date)" >> "$LOG"
else
  echo "[provision] WARN private DNS NOT applied -- mode=$_dnsmode want=hostname, specifier=$_dnsspec want=dns.mullvad.net $(date)" >> "$LOG"
fi

# DIA-20260816-07 (amnesia audit fix 7, take 2): bound how long /data/system/dropbox keeps entries that name
# departed identities.
#
# WHY NOT JUST DELETE IT AT BOOT, which is what the audit asked for: /data/system/dropbox carries its own
# SELinux type, dropbox_data_file, and system/sepolicy/private/domain.te forbids every domain but init,
# system_server and dumpstate from touching it --
#   # System_server owns dropbox data, and init creates/restorecons the directory
#   neverallow { domain -init -system_server -dumpstate } dropbox_data_file:dir *;
# The boot sweep (DIA-20260816-04) was measured DEAD against it on lynx 2026081602 for exactly this reason:
# 1000 entries before, 1000 after, with an avc getattr denial for endospore_priv. Granting roamd access means
# source-patching that neverallow, which both punches through a boundary AOSP drew deliberately and hands our
# daemon every crash report on the device. Not worth it for this payload: the audit verified all 1,000
# entries contain NO personal content -- zero content:// URIs, zero email-shaped strings, zero profile names.
# What leaks is the CENSUS (how many sessions existed, which slots, when to the second), and a census is
# bounded perfectly well by time.
#
# So: ask system_server to prune it, inside its own boundary. DropBoxManagerService reads both of these
# (DropBoxManagerService.java:1270-1272) and the audit found all four dropbox knobs UNSET, so AOSP defaults
# were applying -- a 3-DAY age and a 1000-file cap, i.e. three days of departed-session metadata on an
# amnesiac phone.
#
# The numbers are a trade, not a truth. 2h is long enough that someone who hits a bug and taps "Report an
# issue" still has the crash entry -- and on a locked user build that report is the ONLY diagnostic channel
# we have, so setting this to minutes would buy a little privacy by making real failures undebuggable.
# 200 files bounds volume without touching that: the audit measured 988 of 1000 entries as userdebug
# StrictMode churn, so 200 is generous for genuine crashes on a user build.
NOWHERE_DROPBOX_AGE="${NOWHERE_DROPBOX_AGE:-7200}"     # 2 hours
NOWHERE_DROPBOX_MAX="${NOWHERE_DROPBOX_MAX:-200}"      # files
settings put global dropbox_age_seconds "$NOWHERE_DROPBOX_AGE" </dev/null >/dev/null 2>&1
settings put global dropbox_max_files "$NOWHERE_DROPBOX_MAX" </dev/null >/dev/null 2>&1
# Read them BACK. `settings put` from this context fails silently on a wedged SettingsProvider, and a
# retention policy that was never applied looks exactly like one that was -- the same trap the boot sweep
# just fell into. Assert the value, never the call.
_dbage=$(settings get global dropbox_age_seconds </dev/null 2>/dev/null)
_dbmax=$(settings get global dropbox_max_files </dev/null 2>/dev/null)
if [ "$_dbage" = "$NOWHERE_DROPBOX_AGE" ] && [ "$_dbmax" = "$NOWHERE_DROPBOX_MAX" ]; then
  echo "[provision] dropbox retention = ${NOWHERE_DROPBOX_AGE}s / ${NOWHERE_DROPBOX_MAX} files (was AOSP default 3d/1000) $(date)" >> "$LOG"
else
  echo "[provision] WARN dropbox retention NOT applied -- age=$_dbage want=$NOWHERE_DROPBOX_AGE, max=$_dbmax want=$NOWHERE_DROPBOX_MAX $(date)" >> "$LOG"
fi

# Disable the LineageOS SetupWizard on user 0. On a provisioned Nowhere device the blind-login gate IS the
# setup -- there's no wizard step -- but SetupWizard can WIN the boot foreground race and sit in front of the
# gate ("welcome screen"); that also blocks the gate's device-owner Lock Task from engaging (startLockTask
# needs the FOREGROUND task -> "Invalid task, not in foreground" -> the kiosk never locks). Disable it here
# (su:s0, once per fresh /data; the disabled state persists until a factory reset, which re-runs provisioning)
# so it can never win that race. (prepRoamedUser already disables it for the roamed users; this covers user 0.)
# Only LineageOS ships the package: probe first, so an Endospore (GrapheneOS) log does not claim a disable of
# something that is not there (NWP-20261110-18).
if pm path org.lineageos.setupwizard </dev/null >/dev/null 2>&1; then
  pm disable-user --user 0 org.lineageos.setupwizard </dev/null >/dev/null 2>&1
  _rc=$?
  echo "[provision] setupwizard disable rc=$_rc $(date)" >> "$LOG"
else
  echo "[provision] no LineageOS setup wizard on this build -- nothing to disable $(date)" >> "$LOG"
fi
# (#46 user-0 home pin lives in nowhere_gate.sh -- per-boot, so it also covers a system-flash-only update.)

# Default geolocation time-zone detection ON for all users (DIA-20260617-01). The AOSP offline geo tz provider
# is integrated (DIA-20260616-61) and the master switch is on, but the per-user "use location for time zone"
# setting defaults OFF (ServerFlags KEY_LOCATION_TIME_ZONE_DETECTION_SETTING_ENABLED_DEFAULT) -- so geo only
# runs if a user toggles it. Flip the global default on so every fresh (ephemeral) roamed user auto-uses geo in
# Automatic mode (no SIM -> NITZ is silent, so geo is the live source). It's a GLOBAL DeviceConfig flag
# (system_time namespace), so all users inherit it with no per-user write; no GApps -> no server sync to
# overwrite it. cmd needs /dev/null stdio from su:s0 (the cmd fd-passing denial, DIA-20260616-56).
device_config put system_time location_time_zone_detection_setting_enabled_default true </dev/null >/dev/null 2>&1
_rc=$?
echo "[provision] geolocation tz detection default rc=$_rc $(date)" >> "$LOG"

# Arm the gate on a cold device. A freshly-flashed system app is left in the STOPPED state (Android 12+),
# and stopped apps do NOT receive BOOT_COMPLETED -- so the chooser's BootReceiver never fires and the gate
# never auto-arms on the very first boots after a wipe. Launching the activity once here clears the stopped
# flag (the un-stopped state persists in /data across reboots), so every subsequent boot the BootReceiver
# arms the gate normally. Re-launching after ownership is set also re-triggers the gate's onResume Lock Task
# now that it can actually lock. su:s0 can start it; the chooser kiosk-locks itself in onResume.
am start -n com.nowhere.chooser/.ChooserActivity </dev/null >/dev/null 2>&1
_rc=$?
echo "[provision] launched gate to clear stopped-state rc=$_rc $(date)" >> "$LOG"

# Mark done ONLY once device-owner is actually set, so a first boot where the device-policy service wasn't
# ready re-attempts on the NEXT boot instead of leaving the device stuck as a non-kiosk gate forever. The
# steps above (keyguard / setupwizard-disable / gate-launch) are idempotent, so re-running them is harmless.
if owner_ok; then
  touch "$MARK"
  echo "[provision] done; marker written $(date)" >> "$LOG"
else
  echo "[provision] marker NOT written -- provisioning will re-run next boot $(date)" >> "$LOG"
fi
