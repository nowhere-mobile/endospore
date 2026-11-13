#!/system/bin/sh
# Early gate launch -- the home-flash fix.
#
# The chooser's BootReceiver launches the gate on BOOT_COMPLETED, but that is an ORDERED broadcast with
# ~11 receivers that takes ~2s to drain, so the gate appears ~2s after launcher3 is already on screen --
# the visible "home flash" before the gate. This service instead runs the instant `sys.boot_completed`
# flips (init triggers it ~1s BEFORE the broadcast is even posted), racing the gate up with the home so
# the launcher is barely visible.
#
# su:s0 (like nowhere_provision) so `am` can start an activity. Idempotent with the BootReceiver:
# ChooserActivity is singleTask, so a duplicate launch is a no-op. Also clears the Android-12+ "stopped"
# state of a freshly-flashed system app on EVERY boot (not just first-provision), so the gate auto-arms.

# NWP-20261129-31: the gate has no log of its own and its logcat lines reach no issue report, so the boot's outcome
# also goes to provision.log, which every report carries (as NWP-20261128-28's start line).
PLOG=/data/nowhere/provision.log

# #46: pin the GATE as user 0's HOME (BEFORE launching it, so home resolves to the gate). The chooser declares
# CATEGORY_HOME, so a user-0 gate task-death (crash / the a11y-dump NPE / a foreground race) relaunches THE
# GATE instead of dropping user 0 to launcher3 (which exposes the drawer + Settings, un-authenticated). The
# pin is ATTEMPTED per-boot (not just at first-provision) so a system-flash-only update gets it too, and so a
# cleared preference gets it back at the next boot. Roamed users are pinned to launcher3 by roamd's `grant` op
# (home_pin), the chooser's last sign-in step, after install-existing -- not by the roam-in. cmd stdio ->
# /dev/null (the su:s0 cmd fd-passing denial, DIA-20260616-56), so only its exit status is a signal.
# NWP-20261122-17: that status is KEPT, the shape of roamd's home_pin: a non-zero status writes one
# `home pin FAILED` logcat line, because a failed pin leaves user 0's HOME on launcher3 and nothing else says
# so. ONE call, no retry: this service exists to get the gate up before launcher3, and a retry with sleeps
# would delay the launch below on exactly the failure path.
_hrc=0
cmd package set-home-activity --user 0 com.nowhere.chooser/com.nowhere.chooser.ChooserActivity </dev/null >/dev/null 2>&1 || _hrc=$?
[ "$_hrc" -eq 0 ] || log -t nowhere_gate "home pin FAILED rc=$_hrc -- a gate crash now lands on launcher3 (#46)" 2>/dev/null

# Four tries at the launch. When all four fail, one `gate launch FAILED` logcat line (NWP-20261122-17): the
# chooser's BootReceiver launch on BOOT_COMPLETED is then the only path left to the gate.
i=0
while [ "$i" -lt 4 ]; do
  am start -n com.nowhere.chooser/.ChooserActivity >/dev/null 2>&1 && break
  i=$((i + 1)); sleep 1
done
[ "$i" -lt 4 ] || log -t nowhere_gate "gate launch FAILED after 4 tries -- the BootReceiver's launch is the only one left" 2>/dev/null

# Re-assert keyguard-off on EVERY boot. The one-time provisioning `locksettings set-disabled true` does
# NOT reliably persist across reflashes/boots (observed get-disabled=false), which lets a swipe-keyguard
# precede the gate. Re-applying here (su:s0, every boot) tries to keep the boot landing straight on the
# gate; a non-zero locksettings status writes one `keyguard disable FAILED` logcat line (NWP-20261122-17).
_krc=0
locksettings set-disabled true >/dev/null 2>&1 || _krc=$?
[ "$_krc" -eq 0 ] || log -t nowhere_gate "keyguard disable FAILED rc=$_krc" 2>/dev/null

# NWP-20260922-04: re-assert the hidden user switcher on EVERY boot, for the same reason the line above
# is re-asserted -- a one-time provisioning write is not durable here. The framework re-enables the
# switcher whenever a user is created AND this row is null (UserManagerService, "If the user switch
# hasn't been explicitly toggled on or off by the user, turn it on"), and Nowhere creates a user on
# every single login. So if the row is ever cleared -- a reflash, a factory reset, a wipe that misses
# it -- the very next sign-in turns the switcher back on silently. Re-writing it per boot closes that when
# the write lands. NWP-20261122-17: the value is read back, as nowhere_provision.sh reads back private DNS
# (NWP-20261110-18: assert the value, never the call); any value but 0 writes one `user switcher NOT hidden`
# logcat line.
settings put global user_switcher_enabled 0 </dev/null >/dev/null 2>&1
_sw=$(settings get global user_switcher_enabled </dev/null 2>/dev/null)
[ "$_sw" = 0 ] || log -t nowhere_gate "user switcher NOT hidden -- user_switcher_enabled=$_sw want=0" 2>/dev/null

# #135 B5: per-boot telephony janitor + SECURE-ERASE -- the crash/battery-death backstop (there is no
# shutdown hook; nowhere.rc has only sys.boot_completed). user 0 keeps NO telephony content of its own:
# the gate sends none, and inbound records are sealed to a tmpfs inbox that is wiped at power-off. So any
# row in user 0's SMS/MMS/CallLog databases is residue from a crash before the app's in-session scrub ran.
# EXCEPT the SMS `raw` reassembly table, which this janitor leaves alone (NWP-20260927-10, decided 2026-09-28):
# at sys.boot_completed it can hold texts received this boot and not yet delivered. TelScrub.sms removes only
# rows the framework has dispatched, and (NWP-20261108-10, Q033) a row still waiting 24 h after the gate first saw it.
# We DELETE the content rows AND VACUUM to collapse the freed pages (the strict-zero-window secure-erase --
# `content delete` alone leaves rows in free pages + the FTS `words` index until VACUUM). The scrub runs
# through nowhere_db_fix since DIA-20260817-01 (below), not sqlite3; sqlite's own file locking makes a
# DELETE/VACUUM against a live provider db a clean no-op if busy, never corruption (busy_timeout gives it a
# moment), and NWP-20261019-15 makes that no-op loud: a telscrub that exits non-zero (3 cannot open, 6 VACUUM
# or checkpoint failed) leaves one `telscrub FAILED` logcat line, so a denied or busy db is no longer silent.
# We touch ONLY the message/call databases -- the carrier/APN config (telephony.db, *Carrier*,
# HbpcdLookup, carrierIdentification) is left intact. Both the CE (/data/user/0) and the direct-boot DE
# (/data/user_de/0, incl. calllog_shadow.db) copies are scrubbed. B6 (enforcing endospore_priv): su:s0
# file access to radio_data_file + the contacts app-data dir needs sepolicy allows -- harvest on lynx.
# DIA-20260817-01 (#732): nowhere_db_fix, not sqlite3. The old `command -v sqlite3` guard meant this whole
# janitor SILENTLY SKIPPED on every `user` build -- sqlite3 is userdebug-only -- so deleted call/SMS row
# bytes sat un-vacuumed in the provider db files on every shipping device. The tool sets busy_timeout on its
# one connection (the per-invocation PRAGMA dance below was only ever needed because each CLI call was a
# fresh process), deletes per-table so a missing legacy table (attachments/drm) can't abort the batch, and
# VACUUMs last. The FTS `words` virtual table remains the only legal clear for its shadows, exactly as
# before. Loud skip, not silent: a missing tool is a build-configuration bug someone must see.
# NWP-20261019-15: the FILE wipes do not need nowhere_db_fix, so they run on every boot, outside the tool guard
# below -- a build that lost the tool still gets the cleartext-MMS backstop (and still logs the skip).
for _base in /data/user/0 /data/user_de/0; do
  # MMS attachment PAYLOADS live as files (part._data -> app_parts/PART_<ts>_<name>), not in the `part`
  # table, so a plain table delete orphans them -- wipe the on-disk part stores too (both historical dir
  # names). user 0 has no legitimate MMS, so clearing the store is always correct.
  rm -rf "$_base/com.android.providers.telephony/app_parts"/* \
         "$_base/com.android.providers.telephony/parts"/* 2>/dev/null
  # #150: the gate downloads an inbound MMS body to a chooser-private staging file before sealing it. That
  # file is CE storage (persistent), not tmpfs, so a crash/power-off between the download and the seal's
  # cleanup could leave the CLEARTEXT MMS (image + text) on user 0's disk. The chooser also sweeps it (per-
  # download timeout + a pre-download stale sweep), but this per-boot wipe is the amnesia backstop.
  rm -rf "$_base/com.nowhere.chooser/cache/mms"/* 2>/dev/null
done

_ts=ran; _ts_ok=0; _ts_failed=0; _ts_absent=0; _ts_dbs=
if [ -x /system/bin/nowhere_db_fix ]; then
  scrub_db() { # $1=db path, $2..=content tables to empty
    local _db _rc _nm _sc
    _db="$1"; shift
    [ -f "$_db" ] || { _ts_absent=$((_ts_absent + 1)); return 0; }
    /system/bin/nowhere_db_fix telscrub "$_db" "$@" >/dev/null 2>&1
    _rc=$?
    [ "$_rc" -eq 0 ] || log -t nowhere_gate "telscrub FAILED rc=$_rc on ${_db#/data/} -- its deleted rows may still be on disk" 2>/dev/null
    if [ "$_rc" -eq 0 ]; then
      _ts_ok=$((_ts_ok + 1))
    else
      _ts_failed=$((_ts_failed + 1))
      _nm=${_db##*/}; _nm=${_nm%.db}
      case "$_db" in */user_de/*) _sc=de ;; *) _sc=ce ;; esac
      _ts_dbs="${_ts_dbs:+$_ts_dbs,}$_nm.$_sc:$_rc"
    fi
    return 0
  }
  for _base in /data/user/0 /data/user_de/0; do
    scrub_db "$_base/com.android.providers.telephony/databases/mmssms.db" \
      sms pdu part addr canonical_addresses threads pending_msgs sr_pending attachments drm words
    scrub_db "$_base/com.android.providers.contacts/databases/calllog.db" calls
    scrub_db "$_base/com.android.providers.contacts/databases/calllog_shadow.db" calls
    # DIA-20260808-01: the telephony stack keeps its own ANALYTICS db, and it is not the message store above --
    # it is a separate file in the phone app's DE storage that nothing has ever touched. It survives a logoff
    # because com.android.phone is singleUser: it runs as user 0 and serves whichever user is in the foreground,
    # so a roamed session's telephony activity is recorded in USER-0 storage and the reap never reaches it.
    # Observed on lynx 2026-08-08: 4 rows of SmsMmsDataLogs and 31 of ServiceStateLogs, e.g.
    #   2026-07-31|SMS Incoming|0|1        2026-08-05|SMS Incoming|1|3
    # -- per-day, per-SIM-slot message counts WITH DIRECTION. No content and no addresses, but it still answers
    # "did the previous owner text, on which SIM, on which days, how much" for anyone who reads the file, which
    # is exactly the behavioural residue the amnesia guarantee exists to deny.
    # DELETE+VACUUM rather than rm: the phone process holds this db open, so unlinking it would leave the app
    # writing to a dead inode -- the same trap the log rewrite had to avoid. Same scrub_db path as everything
    # above, so it inherits the busy_timeout and the freed-page collapse.
    scrub_db "$_base/com.android.phone/databases/telephony_analytics.db" \
      SmsMmsDataLogs ServiceStateLogs CallDataLogs
  done
else
  # Both editions' .mk lists ship nowhere_db_fix, so reaching here means a build-configuration
  # regression. The gate has no log file of its own; this logcat line names the missing tool, the boot line at the
  # end of this script records telscrub=SKIPPED, and either beats the old `command -v sqlite3` behaviour, which
  # skipped this entire janitor on every user build in perfect silence.
  log -t nowhere_gate "telscrub SKIPPED: /system/bin/nowhere_db_fix missing on this build" 2>/dev/null
  _ts=SKIPPED
fi

# NWP-20261129-31: the boot's outcome, one line in provision.log. What each field answers: home-pin rc, did user 0's
# HOME pin land; launch and tries, did `am start` succeed and on which of the four tries; keyguard rc, did the
# re-assert land; switcher, what user_switcher_enabled reads back (`?` when that is not 1 to 8 characters of [0-9a-z],
# empty included); telscrub, did the janitor run or was the tool absent; ok, failed and absent, how each database
# call ended; failed-dbs, each refused database as <db>.<ce|de>:<rc>, or - when none was. Device facts only: no path,
# no uid, no package, no `"` (log_scrub reads one as the start of a name), no count of deleted rows or wiped files.
# Every run of nowhere.rc's boot_completed action writes one `[gate] boot:` line beside provision's `[provision] start:`
# line, so a second pair whose start line reads mounts=2 or more is the action re-running over a live state dir (the
# NWP-20261128-28 question). A failed write changes nothing else. Residual: roamd's boot log scrub (log_scrub) rewrites
# provision.log in place shortly after BOOT_COMPLETED, so a line appended during that rewrite can be lost.
if [ "$i" -lt 4 ]; then _launch=ok; _tries=$((i + 1)); else _launch=FAILED; _tries=4; fi
case "$_sw" in ''|?????????*|*[!0-9a-z]*) _swv='?' ;; *) _swv=$_sw ;; esac
echo "[gate] boot: home-pin rc=$_hrc launch=$_launch tries=$_tries keyguard rc=$_krc switcher=$_swv telscrub=$_ts ok=$_ts_ok failed=$_ts_failed absent=$_ts_absent failed-dbs=${_ts_dbs:--} (NWP-20261129-31) $(date)" >> "$PLOG" 2>/dev/null
