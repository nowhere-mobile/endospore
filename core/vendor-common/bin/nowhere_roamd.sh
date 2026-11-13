#!/system/bin/sh
# Nowhere Arc 2 per-user DATA worker (su:s0). The chooser (device owner) owns the user LIFECYCLE
# (create/start/switch/stop/remove via DPM/AM -- M1); THIS does only the privileged DATA half the
# confined nowhere domain can't: restore arbitrary app data into /data/user/N + restorecon, and seal it
# back. On-demand -- an app can't spawn su:s0, so the caller writes the request file into the RAM tmpfs
# then `setprop ctl.start nowhere_roamd`; init runs this once; it writes the result file.
#   req (state tmpfs = RAM, consumed immediately):  op\nname\npass\nuid
#   res (state tmpfs = RAM):                         OK <uid> | BLANK | ERR-...
# req/res live in /data/nowhere/state (the tmpfs, gone on power-off; the sync skips plain files, so the
# creds never roam) -- same trick as the Arc-1 .session marker.
STATE=/data/nowhere/state

# NWP-20260826-06: THE READ-ONLY LANE. $1 is the lane -- "ro" from the nowhere_roamd_ro init service, empty
# (=> "rw") for every existing caller, so nothing about the RW path changes.
#
# WHY A SECOND LANE AT ALL. req/res are FIXED paths and this is a `oneshot` init service, so every worker op
# shares one FIFO: a 2-second recursive stat queues behind a 4-minute store-streaming seal. Measured on lynx:
# `worker op=storagebreakdown uid=12 waited 164673ms`. That is not a lock bug, it is one queue serving two
# workloads with nothing to tell them apart. The RO lane gives the read its own req/res pair and its own init
# service, so it can run WHILE a seal holds the RW slot.
#
# ⚠ IT IS RESTRICTED TO READ-ONLY OPS BY AN ALLOWLIST BELOW, and that restriction is what makes a second
# concurrent instance of this script safe at all. Anything that mutates the roamed user's data, touches the
# store, or needs a passphrase MUST stay on the RW lane, where the single slot is the thing keeping a seal
# from interleaving with a login.
LANE="${1:-rw}"
case "$LANE" in
  ro)   REQ="$STATE/roamro.req"; RES="$STATE/roamro.res" ;;
  cred) REQ="$STATE/roamcred.req"; RES="$STATE/roamcred.res" ;;   # NWP-20260903-09: see the cred allowlist below
  *)    LANE=rw; REQ="$STATE/roam.req"; RES="$STATE/roam.res" ;;
esac
LOG=/data/nowhere/roam.log            # status only -- never creds

# NWP-20260819-05: login-latency instrumentation. A "blank" profile login measured ~57s (lynx) / ~126s
# (frankel), and the split across restore/reown/restorecon/grant in the ~31s pre-IN window was never logged
# -- so it could only be guessed. _ms is numeric-guarded (a bad `date` echoes 0, never aborts a login), and
# _tlog writes one "[roamd] TIMING <phase> <ms>ms" line. Log-only; no behaviour change. Grep TIMING to read.
_ms() { local _t; _t=$(date +%s%3N 2>/dev/null); case "$_t" in ''|*[!0-9]*) echo 0;; *) echo "$_t";; esac; }
_tlog() { echo "[roamd] TIMING $1 $(( $(_ms) - ${2:-0} ))ms (user ${uid:-?}) $(date)" >> "$LOG"; }
# _ssum WORD START (NWP-20261130-08): one `v=1 phase=WORD ms=<n>` line in this sign-in's summary (core/agent/signin_summary.go).
# A bad clock writes no line. The guards on a raw time are `case`, never a numeric test: mksh arithmetic is 32-bit, a
# 13-digit time wraps, and only the difference stays correct.
_ssum() {
  [ -n "${NOWHERE_SIGNIN_SUMMARY:-}" ] || return 0
  case "${2:-}" in ''|0|*[!0-9]*) return 0 ;; esac
  local _n _d
  _n=$(_ms)
  case "$_n" in 0) return 0 ;; esac
  _d=$(( _n - $2 ))
  [ "$_d" -ge 0 ] || return 0
  echo "v=1 phase=$1 ms=$_d" 2>/dev/null >> "$NOWHERE_SIGNIN_SUMMARY"
  return 0
}
# signin_in_ms starts here, at this run's start, so it holds the synchronous work before the `in` arm. _sumt holds each
# bracket's start (_ssum), never the _tt that restore_media_tail overwrites.
_sum0=$(_ms)
AGENT=/system/bin/nowhere_agent

# usb_host on|off -- portable USB host-mode (OTG) flip for the FIDO2 CTAPHID path (#142). A plugged security
# key enumerates as /dev/hidraw ONLY while the port is HOST, and neither device auto-OTGs into host while the
# gadget (adb/MTP device role) is up. The FP3 (LineageOS, Qualcomm ssusb) exposes a 'mode' file; lynx/Pixel
# (dwc3 + Type-C class, sys.usb.controller=*.dwc3) switches via the Type-C port data_role role-switch -- the
# ssusb path does not exist there, so the old hardcoded `echo host > .../7000000.ssusb/mode` silently no-op'd
# and the USB-C key was never detected at login. Pick whichever interface this device actually has. Best-
# effort (2>>LOG); on a USER build the endospore_priv domain also needs sysfs_usb/typec write policy (harvest).
usb_host() {
  m=/sys/devices/platform/soc/7000000.ssusb/mode; t=/sys/class/typec/port0/data_role
  if [ -w "$m" ]; then
    [ "$1" = on ] && echo host > "$m" 2>> "$LOG" || echo peripheral > "$m" 2>> "$LOG"
  elif [ -e "$t" ]; then
    [ "$1" = on ] && echo host > "$t" 2>> "$LOG" || echo device > "$t" 2>> "$LOG"
  else
    echo "[roamd] usb_host $1: no ssusb/typec role-switch found" >> "$LOG"
  fi
}
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
# WHAT THE MERGE ACTUALLY DID, in the log that gets read. KEY NAMES ONLY -- a conf can carry S3
# credentials and this file is quoted in tickets. Without this line the only way to answer "is my flag
# live on this handset?" was to read two files over adb, which a locked user build does not allow --
# and not being able to answer it is what let a measurement campaign run for an evening against a flag
# that was never set.
# NWP-20260908-08: the trailing `tr` collapses the list to ONE LINE. Without it the names come back newline-separated,
# and interpolating that inside a quoted echo produced a MULTI-LINE log entry -- so `grep "conf merge:"` showed
# only the first key and the rest looked like unrelated lines. Proven on lynx 2026090802.
_nwkeys() { grep -o "^[A-Za-z_][A-Za-z0-9_]*=" "$1" 2>/dev/null | tr -d "=" | sort | tr "\n" " "; }
# POSIX only -- this runs under /system/bin/sh, and process substitution appears NOWHERE else in this tree.
_nwring=$(_nwkeys /system/etc/nowhere/nowhere.conf)
_nwdev=$(_nwkeys /data/nowhere/nowhere.conf)
_nwover=
for _k in $_nwring; do
  for _j in $_nwdev; do
    if [ "$_k" = "$_j" ]; then _nwover="$_nwover $_k"; fi
  done
done
echo "[roamd] conf merge: ring=[$_nwring] device=[$_nwdev] overridden=[$_nwover] (key names only) $(date)" >> "$LOG"
unset _nwring _nwdev _nwover _k _j
export S3_ENDPOINT S3_REGION S3_BUCKET S3_ACCESS_KEY S3_SECRET_KEY
# Managed/cap mode (Slice B / cap-gated I/O): the seal worker now PAYS -- capFlush leases the new chunks it
# writes -- so it needs the billing gateway and the session wallet (login daemon restores it to $STATE).
export GATEWAY_URL NOWHERE_STATE="$STATE"
# capFlush spills sealed blob bytes here while STREAMING them to the store (#45), so a multi-GB seal can't
# OOM the device. MUST be on DISK -- NOT the tmpfs $STATE -- and is cleared per flush. /data has the space.
export NOWHERE_SPILL=/data/nowhere/spill
mkdir -p "$NOWHERE_SPILL"
# On-demand media (#84, default ON): the seal splits large media (classifyDeferred) out of the login-gating
# manifest into the Deferred index; nowhere_mediad serves it on-access through per-dir FUSE overlays. Login
# stops paying for GBs of maps/photos. Set NOWHERE_ONDEMAND_MEDIA=0 in nowhere.conf to kill-switch (the next
# seal folds everything back into the essential set). The FIRST seal after enabling re-chunks the media once
# (tar-wrapped essential chunks -> raw deferred chunks), so that one save re-uploads the media set.
export NOWHERE_ONDEMAND_MEDIA="${NOWHERE_ONDEMAND_MEDIA:-1}"
# #91 slice 3: per-unit head model, enabled PER-DEVICE via the conf (default off). Export it so the worker's
# restore/seal agent calls resolve heads per-unit too (must match the daemon). NOWHERE_MULTIDEVICE=1 in conf.
export NOWHERE_MULTIDEVICE="${NOWHERE_MULTIDEVICE:-0}"
# #91 slice 5c: the #apps essential index + cross-lineage CARRY + account tombstones. It was first enabled
# PER-DEVICE via the conf, the same staged-rollout shape as NOWHERE_MULTIDEVICE above and for the same
# reason: it changes what a seal WRITES, and #apps is the scope users meet as "all my apps are gone".
#
# What it turns on, in the agent: a per-file index of the essential region (chunkManifest.Ess), per-file
# chunk alignment so those spans exist at all, re-emitting BY HASH any package the stored head names that
# this handset never staged, the whole-scope manifest.tsv reconciled against the account, and the Gone
# tombstone set. Off, every one of them is inert and the manifest is byte-identical to today.
#
# The FIRST seal after enabling re-chunks the #apps scope once (grouped small files -> one region each),
# so that one save re-uploads the app-code set. Same one-off cost NOWHERE_ONDEMAND_MEDIA documents above.
#
# ON BY DEFAULT since NWP-20261118-10 (DECIDED 2026-10-30, docs/product-decisions.md, h48 #2: the #apps per-app
# index comes from this flag, and h47 #2 is built on it). An image staged with no ring now runs the carry.
# An explicit NOWHERE_CARRY_ESSENTIAL=0 in a ring or the provisioned conf still turns it off: the conf load
# above is a MERGE (NWP-20260908-06), and `:-` only fills a value no conf set. A flagless older image's
# grouped #apps re-seal against a file-aligned head is not refused: the shrink guard compares file counts
# there (NWP-20260908-11; essIndexOn covers #apps).
#
# ⚠ THIS EXPORT IS PROCESS-WIDE AND THE FLAG IS #apps-ONLY, SO EVERY OTHER PUSH PINS IT OFF AT ITS CALL SITE
# (NWP-20260908-01): _push (vault/#de/#media), acct_seal’s #sys push and keystore_push’s #keys push. Do not
# remove those pins on the grounds that appcode_seal "sets" the flag -- it does not, it re-passes this value.
export NOWHERE_CARRY_ESSENTIAL="${NOWHERE_CARRY_ESSENTIAL:-1}"
# NWP-20260908-04 (#91): the same machinery for the shared #media head, keyed by REL instead of by
# package -- so a photo one handset took survives a seal from the other, which has never materialised it.
# SEPARATE from the flag above because that one also turns on reconcileAppManifest, which WRITES
# manifest.tsv into the tree it is handed; under a #media seal that tree is /data/media/$uid.
#
# The FIRST seal after enabling re-chunks the #media ESSENTIAL set once (grouped small files -> one region
# each). That is a bigger one-off than the #apps wording above suggests: on a real camera roll it is one
# region per sub-1 MiB file, re-uploaded once. The deferred bulk -- where the volume actually is -- is not
# touched, because deferred files are chunked from raw bytes with no tar entry at all.
#
# ON BY DEFAULT since NWP-20261023-09 (DECIDED 2026-09-12, docs/product-decisions.md: two handsets MAY be
# signed in at once, so the shared scopes must CONVERGE). An image staged with no ring now runs the carry.
# An explicit NOWHERE_CARRY_ESSENTIAL_MEDIA=0 in a ring or the provisioned conf still turns it off: the conf
# load above is a MERGE (NWP-20260908-06), and `:-` only fills a value no conf set.
#
# ⚠ BOTH HANDSETS NEED THE CODE BEFORE EITHER GETS THE FLAG. It is baked into /system, so that means a
# build on each. A file-aligned head against an old build’s grouped re-seal is a ~5x chunk collapse, which
# the shrink guard reads as a partial restore and REFUSES -- and a #media refusal fails the whole logoff.
# (superseded by NWP-20260908-11: the shrink guard compares file counts when the stored head is file-aligned
# and the seal is not, so a flagless handset's grouped re-seal is no longer refused -- see rings/beta.conf
# "NOT A ROLLOUT CONSTRAINT")
export NOWHERE_CARRY_ESSENTIAL_MEDIA="${NOWHERE_CARRY_ESSENTIAL_MEDIA:-1}"
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
export SSL_CERT_DIR=/system/etc/security/cacerts
# The agent auto-discovers the device's own per-network DNS (privacy: no public-resolver leak), with a
# public fallback only if discovery fails. Set NOWHERE_DNS=host[:port] to force a specific resolver.
export NOWHERE_DNS="${NOWHERE_DNS:-}"
# Restore progress: the agent writes "<phase> <done> <total>" here per chunk; the login daemon polls it
# and streams it to the gate's restore bar. Lives in the RAM tmpfs (gone on power-off, never roams).
export NOWHERE_PROGRESS="$STATE/roam${LANE#rw}.progress"  # roam.progress | roamro.progress | roamcred.progress
# Known-present blob cache (DIA-20260625-08): the agent records confirmed-in-store chunk hashes here (RAM,
# per-store file) so an unchanged re-seal skips the per-chunk network stat -> a no-change logoff finishes in
# ~1-2s instead of 30-60s. RAM dir, so it's re-warmed by the first periodic seal after each boot.
export NOWHERE_BLOBCACHE="$STATE"

# The agent untars as root, so restored data ends up root:root -- the app, running as its per-user uid,
# then can't open it and crash-loops (launcher icon cache, media/contacts providers, SQLiteCantOpen, ...).
# These helpers re-own restored data to the uid Android already assigned to the (untouched) top-level dir
# it created, so we never hardcode a uid (works for any user id / appId / media domain).

# reown_restored PKGDIR: a restore-created, ROOT-OWNED (0:0) app data dir has no owner Android assigned yet -- the
# app isn't install-existing'd for this user. Give it the CORRECT per-user uid (userId*100000 + appId; appId =
# field 2 of packages.list -- a plain file read, since `pm`/`cmd` from su:s0 can't capture output, DIA-56), so a
# later install REUSES the dir instead of installd wiping it ("Expected <uid> but found 0:0" -> PackageManager
# "recovers" by deleting the just-restored data). Uses the global $uid. Caller restorecon's. Returns 0 if reowned,
# 1 if the appId isn't resolvable yet (pkg not in packages.list -- e.g. an on-demand app before its tap-install).
# (Factored out of remap_per_pkg's root-owned branch, DIA-20260625-03, so #204 odrestore can reuse it at the tap.)
reown_restored() {
  local pkgdir="$1" name appid target
  name="${pkgdir##*/}"
  # Exact on field 1 (NWP-20261111-11): the grep this replaced read $name as a regex, so a look-alike name took the data.
  appid=$(NW_PKG="$name" awk '$1 == ENVIRON["NW_PKG"] { print $2; exit }' /data/system/packages.list 2>/dev/null)
  case "$appid" in ''|*[!0-9]*) return 1;; esac
  target=$((uid * 100000 + appid))
  chown -R "$target:$target" "$pkgdir" 2>> "$LOG"
  # scrub-exempt: $name here is the local PACKAGE dir basename (set above), not the profile name -- and
  # quoting it would make log_scrub redact the one path this line exists to report (the #105 trap at the
  # reap survivor lists). test-log-name-scrub.sh honours this marker; do not add one without that reason.
  echo "[roamd] reowned restored $name -> $target (user $uid)" >> "$LOG"
  return 0
}

# mi_path FIELD: a /proc/self/mountinfo mountpoint field decoded to the path it names (NWP-20261112-30). The
# kernel writes a space as \040, a tab \011, a newline \012 and a backslash \134. Mirrors mediad's unesc_mount
# and the Go walker's unescapeMountPath (NWP-20260828-06, where every overlay with a space in its path leaked):
# \134 is decoded LAST, so a path holding the literal text "\040" (written "\134040") comes back as that text.
# Unlike unesc_mount it also decodes \012, as unescapeMountPath does: mountinfo escapes the newline, so `read`
# never splits on it. Written with `print -r --`, never echo, which would undo the escapes.
mi_path() {
  local nl='
'
  print -r -- "$1" | sed -e 's/\\040/ /g' -e 's/\\011/'"$(printf '\t')"'/g' -e "s/\\\\012/\\$nl/g" -e 's/\\134/\\/g'
}

# relabel_restored PKGDIR (NWP-20261005-03): give every entry under an app's data dir that dir's own SELinux
# context. Whatever this daemon creates there is labelled at ITS level, bare s0, not the app's per-app,
# per-user MLS categories -- an SELinux file takes the creating process's level, not its parent's. And the
# `restorecon -R "$dst"` that odrestore used to run relabels NOTHING under an app dir: without -D toybox
# restorecon does not descend into app data (measured on lynx 2026-10-05: a planted bare-s0 dir and file kept
# s0 after it, rc=0). Measured the same day on a restored profile: 606 of 715 Play Store entries and 264 of
# 274 WhatsApp entries at bare s0. The app can still use them (its level dominates s0), so nothing visibly
# breaks; what is lost is the MLS wall between apps, one of the two layers that keeps one app out of another's
# files.
#
# Why not `restorecon -R -D`: -D reaches libselinux's pkgdir_selabel_lookup aliasing bug (DIA-20260806-15),
# patched on Endospore only. The pkg dir's own context is what installd gave it from seapp_contexts, and that
# lookup is per PACKAGE, so it is the right label for every entry beneath it; copying it needs no lookup.
#
# ⚠ MOUNTPOINTS ARE PRUNED. mediad mounts a read-only FUSE overlay over each deferred CE dir (#84), and
# `find -xdev`, which stops it descending, still LISTS the mountpoint itself, as the mounted root -- so a
# chcon would land on the overlay and fail. The overlay's files are mediad's to serve, not ours to label.
# mountinfo writes them octal-escaped (a space is \040), so each is decoded with mi_path and passed to -path
# with its glob metacharacters escaped (NWP-20261112-30). The trailing x keeps a decoded trailing newline,
# which a command substitution would strip.
# ⚠ A MOUNTINFO LINE FORKS NOTHING UNLESS IT HAS TO (NWP-20261030-09). mi_path is a command substitution, a pipe,
# a sed and the printf it embeds -- several forks a call -- and run on every mountinfo line it cost each CE and
# each DE volume of an odrestore 73-94 s on frankel 0.5.49, against 0-2 s on the 2026-10-13 builds, whatever the
# dir held (6 entries: 73 s; 6403: 93 s). One app's restore took three minutes, the daemon gave up on it at 150 s,
# every op behind it was refused busy, and an Auto sweep ended 45 of 45 fetch-failed (tickets NW-5caf97412b6e,
# NW-0ee95acd7ad4). So each step forks only for the lines that need it:
#  - The kernel escapes a space, a tab, a newline and a backslash, one character at a time. A $d made only of
#    letters, digits and _ . / - -- every app data dir, since a package name is [A-Za-z0-9_.] -- holds none of
#    them and is written in mountinfo as it is, so a field is under it exactly when the field AS WRITTEN starts
#    with "$d/", and every other line is skipped before anything is decoded. (mediad's overlays put escaped lines
#    in mountinfo whatever the app: a space in a media dir's name.) Any other $d is compared after the decode, as
#    every $d was before. The letters are spelled out, not a range, so no locale can widen the set.
#  - Only a field holding a backslash is decoded: every escape starts with one.
#  - Only a path holding [ * ? or a backslash is glob-escaped for -path: any other path is its own glob.
# test-od-relabel.sh: P1-P3 and P5 count the sed calls (P2 and P5 also pin that a package dir, capitals, digits and
# _ included, takes the raw test), P4 pins that a dir holding a space does not (the only escaped character tested),
# N2, N3, N7 and N8 each arm of the glob test, and W3 this loop byte for byte: a fork without a sed (a bare command
# substitution on every line) would pass every count.
relabel_restored() {
  local d="$1" ctx mp n g plain=1
  ctx=$(stat -c '%C' "$d" 2>/dev/null)
  case "$ctx" in
    u:object_r:app_data_file:s0*|u:object_r:privapp_data_file:s0*) ;;
    *) echo "[roamd] WARN relabel ${d##*/}: unexpected dir context [${ctx:-none}] -- left as is (NWP-20261005-03)" >> "$LOG"; return 1;;
  esac
  case "$d" in *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./-]*) plain=0;; esac
  set --
  while read -r _ _ _ _ mp _; do
    if [ "$plain" = 1 ]; then case "$mp" in "$d"/*) ;; *) continue;; esac; fi
    case "$mp" in *\\*) mp=$(mi_path "${mp}x"); mp=${mp%x};; esac
    case "$mp" in "$d"/*)
      g=$mp
      case "$mp" in *\[*|*\**|*\?*|*\\*) g=$(print -r -- "${mp}x" | sed 's/[[*?\\]/\\&/g'); g=${g%x};; esac
      set -- "$@" -path "$g" -prune -o;;
    esac
  done < /proc/self/mountinfo
  n=$(find "$d" -xdev "$@" ! -context "$ctx" -print 2>>"$LOG" | wc -l)
  [ "$n" -gt 0 ] && find "$d" -xdev "$@" ! -context "$ctx" -exec chcon -h "$ctx" {} + 2>>"$LOG"
  echo "[roamd] relabelled $n restored entr(ies) of ${d##*/} to the app's context (NWP-20261005-03)" >> "$LOG"
  return 0
}

# od_relabel VOL DST: odrestore's relabel. CE and DE app dirs take relabel_restored; the external volumes keep
# restorecon as before -- their dirs are not app_data_file, and odrestore re-runs `restorecon -R -D` on
# Android/data after reown_ext_appdata anyway.
od_relabel() {
  case "$1" in
    /data/media/*) restorecon -R "$2" 2>>"$LOG" ;;
    *) relabel_restored "$2" ;;
  esac
}

# od_watched DST CMD [ARGS...] (NWP-20261124-03): odrestore's copy of a held volume, with a progress line for the
# daemon's stall clock while the copy still grows DST (h50 #1). The command runs in the background with its stdout
# and stderr together in one file in $STATE; every OD_GROW_EVERY seconds (default 10) one `du -sk DST` reads the size,
# and only a size LARGER than the last good read writes `cutoff_prog od`. A failed or empty read is no growth. Then it
# prints the command's output (od_served_copy's `served=` tail still last) and returns the command's OWN status. When
# the file cannot be made, the command runs in the foreground as before (`"$@" 2>&1`).
#  - The 60-minute hard cap and the daemon's 150 s stall budget are unchanged: this only feeds the clock while bytes
#    still land, so a copy that stops growing for 150 s is still stopped (h50 #1).
#  - It runs inside `_ce=$(...)`, so its CUTOFF_TICK increments stay in that subshell. The arm's next progress line
#    still differs from the watcher's last one unless the watcher wrote exactly one tick, and that tick had just reset
#    the clock.
#  - The label step after the copy (reown_restored, od_relabel) is NOT watched: it changes no size, and counting the
#    files it labels needs a verbose labeller not yet checked on the handsets' toybox.
# du's stderr is dropped: toybox du names paths. No line it writes names a package or a path.
od_watched() {
  local dst="$1" every out= pid rc n=0 sz last=
  shift
  every="${OD_GROW_EVERY:-10}"
  case "$every" in ''|*[!0-9]*|0*) every=10 ;; esac
  [ -n "${STATE:-}" ] && out=$(mktemp -p "$STATE" 2>/dev/null)
  [ -n "$out" ] || { "$@" 2>&1; return $?; }
  "$@" >"$out" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    n=$((n+1))
    [ "$n" -ge "$every" ] || continue
    n=0
    sz=$(du -sk "$dst" 2>/dev/null) || continue
    sz=${sz%%[!0-9]*}
    [ -n "$sz" ] || continue
    if [ -n "$last" ] && [ "$sz" -gt "$last" ]; then cutoff_prog od; fi
    last=$sz
  done
  wait "$pid"; rc=$?
  cat "$out"
  rm -f "$out"
  return "$rc"
}

# od_served_copy SRC DST (NWP-20261121-02): odrestore's hand-back of an EXTERNAL hold when mediad serves part of
# DST. hold_ondemand parks Android/data/<pkg> at sign-in; mediad then finds the app's deferred dir (Unity's
# files/ContentDownload) missing, re-creates it inside DST (ensureDeferredDir), binds it to a hidden path and mounts
# its read-only overlay over it. roamd's domain may only read `fuse` objects, so `cp -a SRC/. DST/` is refused on
# every essential file the hold carries for that dir, the hold is kept and every tap answers ERR-NOTREADY (frankel
# 0.5.50). #media keeps deferring Android/data (Q114), so the copy goes around the overlay instead:
#  - an entry the overlay shows that the hidden real dir does not hold is SERVED: the store holds its bytes, as a
#    deferred entry of the head, so it is not copied;
#  - every other entry under a target goes into the hidden real dir, which the overlay passes through; that dir then
#    takes the app's owner and its own context, because the chown -R and restorecon on DST cannot reach through
#    the overlay (and restorecon by the hidden PATH would give it the chooser's label);
#  - every entry outside every target is copied to DST, as before.
# A media-unders pair counts only when both of its paths are live mountpoints: mediad removes the file only on
# SIGTERM, so after a SIGKILL it lists dead mounts (the seal takes liveness from the mount table too, media_seal.go).
# Prints its commands' error lines, then `served=<k>` last. Returns 2 when no live target is DST or lies under DST/
# (nothing done: the caller copies as before), 0 when every entry not served landed, 1 otherwise (hold kept).
od_served_copy() {
  local src="$1" dst="$2" tab pairs t h mp ts hs p r full rt k=0 rc=0 skip= under anc appid own ctx
  tab=$(printf '\t')
  pairs=
  while IFS="$tab" read -r t h; do
    case "$t" in "$dst"|"$dst"/*) ;; *) continue ;; esac
    [ -d "$h" ] || continue
    ts=; hs=
    while read -r _ _ _ _ mp _; do
      case "$mp" in *\\*) mp=$(mi_path "${mp}x"); mp=${mp%x};; esac
      [ "$mp" = "$t" ] && ts=1
      [ "$mp" = "$h" ] && hs=1
    done < /proc/self/mountinfo
    [ -n "$ts" ] && [ -n "$hs" ] && pairs="$pairs$t$tab$h
"
  done < "$STATE/media-unders"
  [ -n "$pairs" ] || return 2
  appid=$(NW_PKG="${dst##*/}" awk '$1 == ENVIRON["NW_PKG"] { print $2; exit }' /data/system/packages.list 2>/dev/null)
  case "$appid" in ''|*[!0-9]*) echo "od_served_copy: no app id"; echo "served=0"; return 1;; esac
  case "$dst" in */Android/obb/*) own="$((uid * 100000 + appid)):ext_obb_rw";; *) own="$((uid * 100000 + appid)):ext_data_rw";; esac
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    # A name holding a newline splits into lines that name nothing: fail closed, the hold stays.
    [ -e "$p" ] || [ -L "$p" ] || { echo "od_served_copy: unreadable hold entry"; rc=1; continue; }
    r=${p#"$src"/}; full="$dst/$r"
    if [ -n "$skip" ]; then case "$r" in "$skip"/*) continue;; esac; fi
    under=; anc=
    while IFS="$tab" read -r t h; do
      [ -n "$t" ] || continue
      case "$full" in "$t"|"$t"/*) under=1; break;; esac
      case "$t" in "$full"/*) anc=1;; esac
    done <<EOF
$pairs
EOF
    if [ -n "$under" ]; then
      [ "$full" = "$t" ] && continue
      rt=${full#"$t"/}
      if [ -d "$p" ] && [ ! -L "$p" ]; then
        [ -d "$h/$rt" ] || mkdir -p "$h/$rt" || rc=1
      elif { [ -e "$t/$rt" ] || [ -L "$t/$rt" ]; } && ! { [ -e "$h/$rt" ] || [ -L "$h/$rt" ]; }; then
        k=$((k+1))
      else
        cp -a "$p" "$h/$rt" || rc=1
      fi
    elif [ -n "$anc" ]; then
      [ -d "$full" ] || mkdir -p "$full" || rc=1
    elif [ -d "$p" ] && [ ! -L "$p" ]; then
      { [ -d "$full" ] || mkdir -p "$full"; } && cp -a "$p"/. "$full"/ || rc=1
      skip=$r
    else
      cp -a "$p" "$full" || rc=1
    fi
  done <<EOF
$(find "$src" -mindepth 1 2>&1)
EOF
  while IFS="$tab" read -r t h; do
    [ -n "$h" ] || continue
    chown -R "$own" "$h" || rc=1
    ctx=$(stat -c '%C' "$h" 2>/dev/null)
    [ -z "$ctx" ] || chcon -h -R "$ctx" "$h" || rc=1
  done <<EOF
$pairs
EOF
  echo "served=$k"
  return "$rc"
}

# remap_per_pkg DIR: each immediate child of DIR is a package dir Android created and owns; re-own its
# children to that uid, dot-named ones included. cache/ and code_cache/ THEMSELVES keep their own owner and
# per-user cache GID (installd makes them <app uid>:<cache gid> 02771), but their CONTENTS are re-owned to that
# dir's own uid:gid -- the pair a child the app makes itself carries. The restore runs as root and never chowns, so
# it creates entries there as 0:0 and the app would EACCES on them for the whole session: backlog row "Play install
# fails first try: RESTORE writes Glide's cache as root, app EACCESes (#100)", NWP-20261029-07.
# Used for CE (/data/user/N) and DE (/data/user_de/N) app storage.
remap_per_pkg() {
  # local-scope EVERYTHING: without this, `name=` in reown_restored clobbers the GLOBAL $name (the login profile),
  # and since this runs BETWEEN the CE restore and the DE/media restores, those then resolve "<lastpkg>#de" instead
  # of "<profile>#de" -> DE + media SILENTLY don't restore (regression since DIA-20260625-03 added the reown
  # branch; surfaced by the #72 receipt guard refusing to seal the un-restored heads). su:s0 sh is mksh -> local ok.
  local pkg own sub listing clisting cu cg cdir cpkg csub
  # NWP-20260820-24: ONE stat for every child, instead of one per package. The old loop ran
  # `own=$(stat -c '%u' "$pkg")` per package dir -- which is TWO forks each (the command substitution's
  # subshell plus the stat itself) -- and that, not the chowns, was the cost. Measured on lynx 2026082005
  # over a real 228-package profile: the per-package stat loop alone took 6054ms of a 7720ms `reown-ce`,
  # while one batched `stat -c '%u %n' "$1"/*` over the same children took 85ms. 71x, for the same answer.
  #
  # ⚠ SEMANTICS ARE DELIBERATELY UNCHANGED. Same packages visited, same order, same `-lt 100000` split,
  # same cache/code_cache prune, and CRUCIALLY the same uid derivation: a root-owned TOP-LEVEL pkg dir still
  # goes to reown_restored, which resolves the appId from packages.list. It must NEVER be chowned to the
  # dir's own owner -- that owner IS root, so it would be a no-op, the data would stay 0:0, and installd
  # would later see "Expected <uid> but found 0:0" and DELETE the just-restored data. That is the
  # DIA-20260625-03 shape this function is scarred by; this change makes the SCAN cheaper and touches
  # nothing about WHAT is reowned.
  #
  # ⚠ An earlier plan (NWP-20260820-01) was to skip untouched packages via `find "$USERDIR" -uid 0`.
  # NOT POSSIBLE: toybox find has no -uid predicate (verified on lynx -- the option errors out). Batching
  # the stat gets ~78% of the win with none of the risk of changing which packages are visited.
  #
  # Fed by a here-doc, NOT a pipeline: `... | while read` runs the loop in a SUBSHELL in mksh, and this
  # function's whole history is a scoping accident (see the local-scope note above), so the loop stays in
  # the current shell where `local` still means something.
  listing=$(stat -c '%u %n' "$1"/* 2>/dev/null)
  # NWP-20261029-07 added a SECOND batched stat, of every package's cache/code_cache dir (uid, GID, path), and the
  # dot globs below: the stat count is two whatever the package count. It is taken before the package loop, so a
  # restore-created package's cache dir still reads 0 in the cache pass. $1 is not read after these two listings:
  # the cache pass reuses the positional parameters (set --) to build its chown list.
  clisting=$(stat -c '%u %g %n' "$1"/*/cache "$1"/*/code_cache 2>/dev/null)
  [ -n "$listing" ] || return 0
  while read -r own pkg; do
    [ -n "$pkg" ] || continue
    [ -d "$pkg" ] || continue
    case "$own" in ''|*[!0-9]*) continue;; esac
    if [ "$own" -lt 100000 ]; then
      reown_restored "$pkg"   # root-owned == restore-created; reown to the per-user app uid (skips if not yet in packages.list)
      continue
    fi
    for sub in "$pkg"/* "$pkg"/.[!.]* "$pkg"/..?*; do
      [ -e "$sub" ] || continue
      case "${sub##*/}" in cache|code_cache) continue;; esac
      chown -R "$own:$own" "$sub" 2>> "$LOG"
    done
  done <<REMAP_EOF
$listing
REMAP_EOF
  # The cache pass (NWP-20261029-07): one loop over the second listing, fed by a here-doc for the same reason as
  # above. A cache dir's children get the dir's own uid:gid, never `$own:$own` (that would clobber the cache GID)
  # and never the dir itself. A dir below 100000 belongs to a restore-created package whose whole tree went to
  # reown_restored above (or is not resolvable yet): the listing predates that loop, so it still reads 0 here, and
  # it is skipped silently. One chown per non-empty dir; the child list is built with builtins only.
  while read -r cu cg cdir; do
    [ -n "$cdir" ] || continue
    [ -d "$cdir" ] || continue
    cpkg="${cdir%/*}"; cpkg="${cpkg##*/}"
    case "$cu:$cg" in :*|*:|*:*:*|*[!0-9:]*) echo "[roamd] remap: cache dir of $cpkg unreadable -- left as is (NWP-20261029-07)" >> "$LOG"; continue;; esac
    if [ "$cu" -lt 100000 ]; then continue; fi
    set --
    for csub in "$cdir"/* "$cdir"/.[!.]* "$cdir"/..?*; do
      if [ -e "$csub" ]; then set -- "$@" "$csub"; fi
    done
    if [ "$#" -gt 0 ]; then chown -R "$cu:$cg" "$@" 2>> "$LOG"; fi
  done <<REMAP_CACHE_EOF
$clisting
REMAP_CACHE_EOF
}

# pkgname_ok NAME (NWP-20261014-20): true iff NAME is an Android package name -- the grammar validPkgName
# (core/agent/pkgname.go) checks, ^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$, at most 255 bytes. Every caller
# joins the name into a path and recursively copies or deletes it, so "." and ".." (which a bare slash/space test
# passes) must not get through. STRICTER than the _smsapp check in grant_perms_for, which accepts `1a.b` and `a._b`:
# this one also refuses a segment that starts with a digit or an underscore. Callers: hold_ondemand, od_parked_report,
# ks_stage_drop, appcode_seal, materializeapp, stageapp and odrestore. test-appcode-pkg-guard.sh covers materializeapp,
# stageapp and hold_ondemand; test-odrestore-ext-reown.sh covers odrestore (NWP-20261128-42).
pkgname_ok() {
  local p="$1"
  case "$p" in *.*) ;; *) return 1;; esac      # no dot (and so the empty string): one segment is not a package
  [ "${#p}" -le 255 ] || return 1
  # Each alternative is the only one that refuses some name (test-appcode-pkg-guard.sh pins which): a trailing dot,
  # an empty segment, a segment starting with `_` or a digit, a byte outside [A-Za-z0-9._], a non-letter first byte.
  case "$p" in *.|*..*|*._*|*.[0-9]*|*[!A-Za-z0-9._]*|[!A-Za-z]*) return 1;; esac
  return 0
}

# pkg_live_pids PKG UID (NWP-20261110-16): print, space-separated, the pids `pidof PKG` lists whose process belongs to
# Android user UID. `pidof` matches a process NAME, and an app's processes carry the same name in every user, while
# `am force-stop --user "$uid"` stops only the session user's copy: the check has to be per user too, or a user-0
# copy of the same clock app reads as the session's app still running. The user is the REAL uid (the first field of
# /proc/<pid>/status's Uid: line) / 100000; an isolated process (u<N>_i<n>, 99000-99999 within the user) divides to
# the same user, so it counts. A pid whose /proc dir is gone has exited and is not printed. A pid whose status cannot
# be read or has no numeric Uid line (sepolicy may deny it) IS printed: unknown is not "stopped", so that fails closed
# to the unscoped answer. The status is read only through `cat ... 2>/dev/null`, so a failed open stays quiet.
# Callers: silence-alarm and odrestore's hold path. test-pkg-live-pids.sh and test-gate-alarm-arms.sh cover it.
pkg_live_pids() {
  local _p _st _k _r _e _rest _out=""
  for _p in $(pidof "$1" 2>/dev/null); do
    [ -d "/proc/$_p" ] || continue
    _st=$(cat "/proc/$_p/status" 2>/dev/null)
    _r=""
    while read -r _k _r _e _rest; do
      [ "$_k" = "Uid:" ] && break
      _r=""
    done <<PLP_EOF
$_st
PLP_EOF
    case "$_r" in ""|*[!0-9]*) _out="$_out $_p"; continue;; esac
    [ "$((_r / 100000))" = "$2" ] || continue
    _out="$_out $_p"
  done
  [ -n "$_out" ] && printf '%s\n' "${_out# }"
  return 0
}

# hold_ondemand UID (#204): an on-demand app is installed at login as an APK-less ARCHIVED PLACEHOLDER, not a real
# install. Its restored per-app data dir is ROOT-owned (remap_per_pkg can't reown it -- the pkg isn't in
# packages.list yet), so installArchivedPlaceholder's installd would find owner 0:0 and WIPE it. Before the chooser
# provisions, MOVE each on-demand app's restored CE+DE data OUT of the canonical /data/user/N/<pkg> (+ user_de)
# into a .nowhere-odhold/<pkg> stash UNDER the chooser's own (installed) package dir on the SAME volume. The hold
# MUST live under a real package dir, NOT at the user root: Android's app-data reconcile reaps any TOP-LEVEL
# non-package dir under /data/user/N (+ DE) on CE/DE unlock -- the exact #92 hazard that put .nowhere-media under
# com.nowhere.chooser. The placeholder then installs onto a clean empty canonical dir (no wipe); the tap's
# `odrestore` op moves the hold back + reowns after the real APK install. A never-tapped app keeps its data in the
# hold -- the ordinary out-seal walks it (basename NOT .nowhere-media-prefixed) so it re-seals + roams.
# BOTH-present guard: once the placeholder is installed, the canonical is an EMPTY installd skeleton that a periodic
# seal captures alongside the real hold; on the next login BOTH come back, so if the hold already exists it is
# authoritative -- DROP the empty/placeholder canonical and KEEP the hold; only move when there's no hold yet.
# Idempotent for a dormant app (canonical absent -> skip). Keep-set mode column: `pkg\tondemand` (installed/off
# rows untouched). Amnesia-safe: the hold lives in the ephemeral user's FBE CE/DE volumes -> sealed by out, reaped.
# NWP-20261129-27: the data of an app the IMAGE SHIPS is never parked. A keep line can name one, because a release can
# bundle an app a profile already keeps (NWP-20260827-22 bundled Etar). remap_per_pkg has already re-owned that data (a
# system package is in packages.list) and install-existing keeps an app-owned dir, so it stays where the restore put
# it, as every bundled app's data does. A hold here would strand it: Endospore lets no store install land over a system
# app (docs/product-decisions.md Q156), so RESTORE-ODDATA is never sent; AppInstallReceiver.heal skips a bundled app;
# at sign-out captureAppCode prunes the bundled keep line with no drop record, so the hold seals into every later head
# and nothing reads it again. "Ships" means ONE read per call: the exact line `package:<pkg>` is in the system listing
# and not in the third-party listing. A listing that cannot be read, or a package both listings name, parks as before.
# Residual: a hold an earlier image stranded is not handed back. test-hold-shipped.sh covers it.
# DIA-20260816-19: one definition of the hold dir name, shared by the CE/DE and EXTERNAL holds and matching
# odHoldDirName in the agent (incremental_seal.go). It is part of a SEALED PATH SHAPE -- the seal's drop and
# attribution rules match on it literally -- so it cannot drift between the two languages.
ODHOLD=".nowhere-odhold"
# NWP-20261130-03: fetch-oddata's stage beside the hold (odFetchStageName in core/agent/incremental_seal.go).
ODFETCH=".nowhere-odfetch"

# NWP-20261130-03: the session's list of packages a scope's sign-in restore skipped (On-demand and Auto, not fetched yet).
# od_unf_path UID SCOPE prints $STATE/odfetch.<uid>/unfetched.<scope> ALWAYS, whether the file exists or not: a push
# that names a lost file is refused (unfetched-unknown), never sealed unguarded. The ONE roamd place that names the
# list files (odUnfetchedCE / odUnfetchedDE in core/agent/unfetched_fetch.go, TestOdListNamesMatchRoamd).
od_unf_path() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  case "$2" in ce|de) ;; *) return 1 ;; esac
  echo "$STATE/odfetch.$1/unfetched.$2"
}

# NWP-20261130-03: od_pending_path UID PKG prints $STATE/odfetch.<uid>/pending.<pkg>: the marker od_fetch_data writes before
# a fetch and odrestore removes at its OK reply. The daemon's OD-DATA-PENDING reads it (odPendingName in
# core/agent/unfetched_fetch.go, TestOdPendingNameMatchesRoamd), so the chooser's launch barrier holds an app from its
# package-added event until its data is back, including across the fetch-then-install of a nApps Get, where the list no
# longer names it. The ONE roamd place that names the marker.
od_pending_path() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  echo "$STATE/odfetch.$1/pending.$2"
}

# NWP-20261130-03: od_shipped_prep writes $STATE/odfetch.<uid>/shipped before the vault restore: the packages the image
# ships (hold_ondemand's rule, NWP-20261129-27: in the system listing, not in the third-party one), which the restore
# never skips. A listing that cannot be read turns the skip off for this sign-in. Always returns 0: the sign-in goes on.
od_shipped_prep() {
  local _sl _tl _src _trc _d="$STATE/odfetch.$uid"
  [ "$_odoff" = 0 ] && [ -d "$_d" ] || { _odoff=1; return 0; }
  _sl=$(timeout -k 2 20 pm list packages -s -u </dev/null 2>/dev/null); _src=$?
  _tl=$(timeout -k 2 20 pm list packages -3 -u </dev/null 2>/dev/null); _trc=$?
  if [ "$_src" != 0 ] || [ -z "$_sl" ] || [ "$_trc" != 0 ]; then
    _odoff=1; echo "[roamd] IN the system package list could not be read -- every app's data fetched at sign-in (NWP-20261130-03) $(date)" >> "$LOG"
    return 0
  fi
  printf '%s\n' "$_sl" | sed -n 's/^package://p' | sort -u > "$_d/shipped.s" 2>>"$LOG"
  printf '%s\n' "$_tl" | sed -n 's/^package://p' | sort -u > "$_d/shipped.t" 2>>"$LOG"
  if ! comm -23 "$_d/shipped.s" "$_d/shipped.t" > "$_d/shipped" 2>>"$LOG"; then
    _odoff=1; rm -f "$_d/shipped"
  fi
  rm -f "$_d/shipped.s" "$_d/shipped.t"
  return 0
}

# NWP-20261130-03: od_park_var keep|shipped|ce|de -- a restore's park variable, or nothing when the skip is off
# (_odoff=1), which turns the agent's skip off. Given to the vault and #de restores only.
od_park_var() {
  [ "$_odoff" = 0 ] || return 0
  case "$1" in
    keep) echo "/data/user/$uid/com.nowhere.chooser/files/nowhere-appkeep" ;;
    shipped) echo "$STATE/odfetch.$uid/shipped" ;;
    ce|de) od_unf_path "$uid" "$1" ;;
  esac
}

# NWP-20261130-03: od_list_state PKG -- what this session's two unfetched lists say of PKG: 0 a list names it, 1 BOTH
# lists were read and neither names it, 2 a list is missing or could not be read. A sign-in that lands has made both
# lists (the `in` commit arm), so a missing one is lost state, never "nothing to fetch"; the seal refuses it too
# (unfetched-unknown). The read is cat's exit status, not grep's: a device grep's status on an open failure is not a
# contract, and only "no line matched" may mean 1.
od_list_state() {
  local _ce _de _l _c _r=1
  _ce=$(od_unf_path "$uid" ce) || return 2
  _de=$(od_unf_path "$uid" de) || return 2
  for _l in "$_ce" "$_de"; do
    _c=$(cat "$_l" 2>/dev/null) || return 2
    case "
$_c
" in *"
$1
"*) _r=0 ;; esac
  done
  return "$_r"
}

# NWP-20261130-03: od_fetch_data PKG -- place PKG's skipped CE/DE data into its on-demand hold before anything installs
# or restores it. 0 when both lists were read and neither names PKG, or the fetch placed it; 1 on a failure (the list
# keeps PKG) and when a list is missing or unreadable: an unknown state never permits an install or a restore.
od_fetch_data() {
  local pkg="$1" _st _t0 _rc _vol _pm
  od_list_state "$pkg"; _st=$?
  case "$_st" in
    0) ;;
    1) return 0 ;;
    *) echo "[roamd] od-fetch $pkg REFUSED: an unfetched list is missing or unreadable -- not installed (NWP-20261130-03) $(date)" >> "$LOG"; return 1 ;;
  esac
  # The marker goes first: once the fetch is on its way the list stops being the whole answer, and the app must read as
  # "data out" from now until odrestore's OK. No marker, no fetch: an app nothing can hold is not installed.
  if ! _pm=$(od_pending_path "$uid" "$pkg") || ! ( : > "$_pm" ) 2>>"$LOG"; then
    echo "[roamd] od-fetch $pkg REFUSED: no pending marker -- not installed (NWP-20261130-03) $(date)" >> "$LOG"
    return 1
  fi
  # A security-key profile's keys open only with the factor the login cached. Each worker op starts without it, and an
  # install that bypassed materializeapp reaches this fetch with nothing else having exported it.
  [ -f "$STATE/.fido2hmac" ] && export NOWHERE_FIDO2_HMAC="$(cat "$STATE/.fido2hmac")"
  _t0=$(_ms)
  NOWHERE_ODFETCH_DIR="$STATE/odfetch.$uid" NOWHERE_PHASE=apps NOWHERE_OD_CANCEL="$STATE/od-cancel" \
    "$AGENT" fetch-oddata s3 "$name" "$(pw "$pass")" "$pkg" "/data/user/$uid" "/data/user_de/$uid" >> "$LOG" 2>&1
  _rc=$?
  if [ "$_rc" != 0 ]; then
    echo "[roamd] od-fetch $pkg FAILED rc=$_rc -- left unfetched, not installed (NWP-20261130-03) $(date)" >> "$LOG"
    return 1
  fi
  for _vol in "/data/user/$uid" "/data/user_de/$uid"; do
    [ -d "$_vol/com.nowhere.chooser/$ODHOLD/$pkg" ] && restorecon -R "$_vol/com.nowhere.chooser/$ODHOLD" 2>>"$LOG"
  done
  echo "[roamd] od-fetch $pkg placed in $(( $(_ms) - _t0 ))ms (NWP-20261130-03) $(date)" >> "$LOG"
  return 0
}

# NWP-20261130-03: od_pending_clear PKG -- odrestore's data is back: the chooser may lift its suspension. rm -f of a
# marker that is not there is the normal case (the package was never fetched this session).
od_pending_clear() {
  local _pm
  _pm=$(od_pending_path "$uid" "$1") || return 0
  rm -f "$_pm" 2>>"$LOG"
  return 0
}

# NWP-20261130-03: od_listed PKG -- 1 only when both lists were read and neither names PKG. A missing or unreadable list
# counts as listed: odrestore then blocks the installed app, and od_fetch_data refuses it.
od_listed() {
  od_list_state "$1"
  [ "$?" != 1 ]
}

# NWP-20261130-03 (RF-012): od_chooser_holds PKG -- true when the chooser's barrier (OdDataBarrier) has this app
# suspended: its mark for PKG exists and is not empty. The chooser writes the mark empty before it suspends and fills it
# only after the framework accepted the suspension, so an empty mark proves nothing. Android shows ONE suspender's
# dialog, so a second suspension by root could replace the chooser's "restoring" text and its Try again button.
od_chooser_holds() {
  [ -s "/data/user/$uid/com.nowhere.chooser/files/nowhere-odbarrier/$1" ]
}

# NWP-20261130-03: od_block_app PKG -- an INSTALLED app whose data is still unfetched is not launchable. An install that
# bypassed materializeapp (nApps, Aurora, Play, sideload) reaches odrestore with the app installed and its data in the
# store; odrestore calls this BEFORE the fetch, so the app stays blocked while the fetch runs and after a failed one. It
# stops the app, then suspends it (the platform shows its "paused" dialog at a launch), or disables it for this user when
# the suspend is refused, or archives it when both are refused (no code, so a tap goes through materializeapp, which
# fetches first). Each package has its own record, $STATE/odfetch.<uid>/blocked.<pkg> ("<mode> <pkg>" lines, mode s, d or
# a), because the RO lane's odblock and the RW lane's odrestore both write them: one shared file would lose a record to
# a read-rewrite. Returns 0 when the app is blocked, 1 when no command worked (the caller then refuses to go on).
# A zero exit is not proof: `pm suspend` exits 0 and prints "new suspended state: false" when PackageManager refuses
# (the default dialer, an active admin, ...), so each mode counts only when the command's own state line says it took.
# RF-012: the app is still force-stopped when the chooser holds it, because an app opened before the suspension must not
# write over the fetch; only the second suspension is left out, and no record is written, so od_unblock_app has nothing to lift.
od_block_app() {
  local pkg="$1" _b _m="" _o
  _b="$STATE/odfetch.$uid/blocked.$pkg"
  [ -s "$_b" ] && return 0   # already blocked: the barrier op ran before this odrestore
  am force-stop --user "$uid" "$pkg" </dev/null >/dev/null 2>&1
  if od_chooser_holds "$pkg"; then
    echo "[roamd] od-fetch $pkg held by the chooser's barrier: no second suspension (NWP-20261130-03) $(date)" >> "$LOG"
    return 0
  fi
  _o=$(timeout -k 2 20 pm suspend --user "$uid" "$pkg" </dev/null 2>&1) && case "$_o" in *"new suspended state: true"*) _m=s ;; esac
  if [ -z "$_m" ]; then
    _o=$(timeout -k 2 20 pm disable-user --user "$uid" "$pkg" </dev/null 2>&1) && case "$_o" in *"new state: disabled-user"*) _m=d ;; esac
  fi
  if [ -z "$_m" ]; then
    _o=$(timeout -k 2 20 pm archive --user "$uid" "$pkg" </dev/null 2>&1) && case "$_o" in *Success*) _m=a ;; esac
  fi
  if [ -z "$_m" ]; then
    echo "[roamd] WARN od-fetch $pkg could not be blocked (suspend, disable and archive refused) (NWP-20261130-03) $(date)" >> "$LOG"
    return 1
  fi
  grep -qxF -- "$_m $pkg" "$_b" 2>/dev/null || echo "$_m $pkg" >> "$_b"
  echo "[roamd] od-fetch $pkg blocked ($_m) until its data is back (NWP-20261130-03) $(date)" >> "$LOG"
  return 0
}

# NWP-20261130-03: od_unblock_app PKG -- undo od_block_app once PKG's data is restored. A package this session never
# blocked is left alone (the user's own or AppClaim's suspension is not ours to lift). A record is a later odrestore's
# only way to retry, so it goes only when the command exits 0 AND prints its state line (see od_block_app: a zero exit is
# not proof). RF-012: that line is the state of ALL suspenders (`pm` prints isPackageSuspendedForUser after it removes
# root's own entry), so "true" means another owner still holds the app: the chooser's barrier, a claim or an admin. Root's
# block is off then, and the record goes. Waiting for "false" would deadlock, because the chooser lifts its own suspension
# only after this op's OK. Returns 1 while a record stays; odrestore then answers ERR-NOTREADY.
od_unblock_app() {
  local pkg="$1" _b _m _p _rest _o _ok _gone="" _fail=0
  _b="$STATE/odfetch.$uid/blocked.$pkg"
  [ -f "$_b" ] || return 0
  while read -r _m _p _rest; do
    [ "$_p" = "$pkg" ] || continue
    _ok=0
    case "$_m" in
      s) _o=$(timeout -k 2 20 pm unsuspend --user "$uid" "$pkg" </dev/null 2>&1) && case "$_o" in *"new suspended state: "*) _ok=1 ;; esac ;;
      d) _o=$(timeout -k 2 20 pm enable --user "$uid" "$pkg" </dev/null 2>&1) && case "$_o" in *"new state: enabled"*) _ok=1 ;; esac ;;
      a) _ok=1 ;;   # the real install that reached this OK reply already undid the archive
    esac
    if [ "$_ok" = 1 ]; then
      _gone="$_gone $_m"
      echo "[roamd] od-fetch $pkg unblocked ($_m) (NWP-20261130-03) $(date)" >> "$LOG"
      if [ "$_m" = s ]; then case "$_o" in *"new suspended state: true"*) echo "[roamd] od-fetch $pkg another owner still holds its suspension (NWP-20261130-03) $(date)" >> "$LOG" ;; esac; fi
    else
      _fail=1
      echo "[roamd] WARN od-fetch $pkg still blocked ($_m) -- record kept for a retry (NWP-20261130-03) $(date)" >> "$LOG"
    fi
  done < "$_b"
  for _m in $_gone; do
    grep -vxF -- "$_m $pkg" "$_b" > "$_b.tmp" 2>/dev/null
    if [ "$?" -gt 1 ] || ! mv -f "$_b.tmp" "$_b" 2>>"$LOG"; then
      rm -f "$_b.tmp"
      _fail=1
    fi
  done
  return "$_fail"
}

# NWP-20261130-03: od_block_installed -- the backstop for an install no RESTORE-ODDATA followed (the runtime receiver
# dies with the chooser process). At each seal, any listed package that has code on the phone is blocked, and stays so
# until a later odrestore. An archived placeholder is not in the plain listing and `pm path` finds no code for it.
od_block_installed() {
  local _ce _de _pl _p
  _ce=$(od_unf_path "$uid" ce) || return 0
  _de=$(od_unf_path "$uid" de) || return 0
  [ -s "$_ce" ] || [ -s "$_de" ] || return 0
  _pl=$(timeout -k 2 20 pm list packages -3 --user "$uid" </dev/null 2>/dev/null) || return 0
  for _p in $(cat "$_ce" "$_de" 2>/dev/null | sort -u); do
    case "
$_pl
" in *"
package:$_p
"*) ;; *) continue ;; esac
    [ -n "$(timeout -k 2 20 pm path --user "$uid" "$_p" </dev/null 2>/dev/null)" ] || continue
    od_block_app "$_p"
  done
  return 0
}

hold_ondemand() {
  # every assigned name is local -- see [[roam-data-loss-saga]]; the ext loop below reuses vol/holddir/src/dst.
  local uid="$1" ak pkg mode rest vol holddir src dst _ce _cn _cl _nl _sl _tl _src _trc _use=0 _nk=0
  ak="/data/user/$uid/com.nowhere.chooser/files/nowhere-appkeep"
  [ -f "$ak" ] || return 0
  # NWP-20261129-27: see the header. -u lists a package uninstalled for user 0 too. Each status is read on its own line.
  _nl='
'
  _sl=$(timeout -k 2 20 pm list packages -s -u </dev/null 2>/dev/null); _src=$?
  _tl=$(timeout -k 2 20 pm list packages -3 -u </dev/null 2>/dev/null); _trc=$?
  if [ "$_src" = 0 ] && [ -n "$_sl" ] && [ "$_trc" = 0 ]; then
    _use=1; _sl="$_nl$_sl$_nl"; _tl="$_nl$_tl$_nl"
  else
    echo "[roamd] hold: the system package list could not be read -- every kept app parked as before (NWP-20261129-27) $(date)" >> "$LOG"
  fi
  while IFS="$(printf '\t')" read -r pkg mode rest; do
    # DIA-20260801: hold BOTH on-demand rows AND installed sealed-code rows (mode empty == installed). A kept
    # INSTALLED app is user-installed (captureAppCode prunes bundled apps from the keep-set) whose APK the logoff
    # reap GC'd, so login reinstalls it via installApkSet -- a FRESH install that, exactly like the on-demand
    # placeholder, finds the root-owned restored dir and WIPES it (proven: sandboxed Play Services roamed back with
    # empty data + no account). Parking it here lets installApkSet land on a clean dir; installRoamedAppCode fires
    # RESTORE-ODDATA right after the install to move the hold back + reown (on-demand rows still restore on tap).
    # NWP-20260903-15: `installed` SPELLED OUT must match too, not just the empty column. The chooser writes
    # a bare `pkg` line for installed mode -- which lands here as mode='' -- BUT it writes the literal
    # `installed` whenever the app carries a group token, because field 2 must exist to reach field 3
    # (ProfileActivity.writeAppModes: `else if (hasGrp) sb.append('	').append(MODE_INSTALLED)`). Those
    # lines fell through to `continue`, so the app got NO hold, its restored data stayed root-owned in the
    # canonical dir, and installApkSet's installd wiped it -- the exact loss the comment above says this
    # branch exists to prevent ("proven: sandboxed Play Services roamed back with empty data + no
    # account"). Device-reproduced on lynx 2026-09-03: 2 MB planted in CE+DE sealed (vault 8 chunks /
    # 2138KiB, #de 5 chunks / 2151772B) and restored (8 and 5 chunks), then
    #   E cutils: Expected path /data/user/10/com.nowhere.fusetest with owner 1010232:1010232 but found 0:0
    # and the data was gone. The Java side already resolves any non-ondemand/auto value to installed
    # (readAppModes), and this script's OWN appcode reader normalises a bare line the same way (kmode=
    # installed, in appcode_seal's keep-set sweep) -- this gate was the one place that read only the empty form.
    case "$mode" in ondemand|auto|installed|'') ;; *) continue;; esac   # #130: auto parks exactly like ondemand
    # NWP-20261014-20: the names come from the chooser's ROAMING nowhere-appkeep file. `..` here made src /data/user
    # and dst the chooser's package dir (inside src), so the merge branch ran `cp -a /data/user/. <that dir>/`: the
    # copy pulled /data/user (other users' CE dirs included) into the ROAMED chooser dir until cp hit its own
    # destination and failed, which is all that kept the `rm -rf /data/user` behind it from running.
    pkgname_ok "$pkg" || continue
    # NWP-20261129-27: the image ships it, so its data stays where the restore put it (no move, no hold dir).
    if [ "$_use" = 1 ]; then
      case "$_sl" in
        *"${_nl}package:$pkg$_nl"*)
          case "$_tl" in *"${_nl}package:$pkg$_nl"*) ;; *) _nk=$((_nk + 1)); continue ;; esac ;;
      esac
    fi
    for vol in "/data/user/$uid" "/data/user_de/$uid"; do
      src="$vol/$pkg"                                    # canonical per-app data dir
      [ -d "$src" ] || continue                          # dormant (data already held) -> nothing to move
      holddir="$vol/com.nowhere.chooser/$ODHOLD"        # UNDER the chooser pkg dir (reconcile-safe, mirrors #92)
      dst="$holddir/$pkg"
      mkdir -p "$holddir" 2>>"$LOG"
      if [ -d "$dst" ]; then
        # A hold already exists. The case this branch was WRITTEN for is a DORMANT app: the hold is the real
        # data and the canonical is the EMPTY installd skeleton that a periodic seal captured beside it, so
        # both come back at login and the hold is authoritative.
        #
        # ⚠⚠ NWP-20260922-09 -- THIS BRANCH USED TO `rm -rf "$src"` HERE, AND THAT WAS A DATA-LOSS RATCHET.
        # `[ -d "$dst" ]` cannot tell that empty skeleton from a canonical FULL OF THIS SESSION’S MESSAGES,
        # and the comment above is the proof: it states the precondition ("an EMPTY installd skeleton",
        # the BOTH-present guard in the hold_ondemand header) and nothing ever checked
        # it. Once a hold strands -- see the odrestore reply below, which
        # until this slice answered OK on exactly that path -- the app’s real data sealed from the canonical
        # AND the stale hold both roam, so EVERY later login dropped the canonical and handed the stale hold
        # back. Chester, on the WhatsApp loss: "it worked fine for a roam, but then next roam it restored the
        # backup data and dropped everything else." That is this branch, logging
        # its own crime as "kept existing hold, dropped canonical".
        #
        # So MERGE instead of dropping, NEWEST WINS: `cp -a "$src"/. "$dst"/` lays the canonical over the
        # hold, so a file present in both takes the canonical’s (newer) copy and a file only the hold has
        # survives. Two divergent copies of one sqlite db cannot be reconciled, but the newer MUST be the one
        # that wins -- the older winning IS the reported bug. The dormant case is unchanged in outcome: an
        # empty skeleton merges to nothing and the canonical still goes.
        #
        # Only drop the canonical on a CLEAN copy, the same rule odrestore states for the hold ("so a failure
        # is recoverable"). A failed merge leaves both in place: installd may then wipe the canonical (#204),
        # which is the pre-existing hazard, but this script will not have been the one to delete it.
        #
        # NWP-20261109-09: cp's and rm's stderr no longer goes to roam.log. toybox names every FILE it fails on, inside
        # the app's private data, and LOG_SCRUB_SED redacts double-quoted tokens only, so those single-quoted names
        # outlived the session into a later profile's issue report (Q001 (e): the file name inside the app must not;
        # reap_userdir_take drops rm's stderr for the same reason). The line keeps the count and the errno text.
        if _ce=$(cp -a "$src"/. "$dst"/ 2>&1); then
          rm -rf "$src" 2>/dev/null
          [ -e "$src" ] && echo "[roamd] WARN on-demand $pkg ($vol) could not remove all of the canonical after the merge -- the rest is left in place (NWP-20261109-09) $(date)" >> "$LOG"
          echo "[roamd] on-demand $pkg ($vol) merged canonical into existing hold, newest wins (NWP-20260922-09) $(date)" >> "$LOG"
        else
          _cn=$(printf '%s\n' "$_ce" | grep -c .)
          _cl=$(printf '%s\n' "$_ce" | sed -n '$p')
          case "$_cl" in *': '*) _cl=${_cl##*: } ;; *) _cl= ;; esac
          case "$_cl" in ''|*/*|*\'*|*\"*) _cl=error ;; esac
          [ "${#_cl}" -le 80 ] || _cl=error
          echo "[roamd] WARN on-demand $pkg ($vol) merge into existing hold FAILED -- canonical LEFT IN PLACE, nothing dropped (NWP-20260922-09) $(date) ($_cn error line(s), last: $_cl)" >> "$LOG"
        fi
      elif mv "$src" "$dst" 2>>"$LOG"; then
        echo "[roamd] held on-demand data $pkg ($vol) $(date)" >> "$LOG"
      fi
      restorecon -R "$holddir" 2>>"$LOG"
    done
    # DIA-20260816-19: the EXTERNAL app-data volumes, for the same reason and by the same mechanism.
    #
    # reap_stale_ondemand runs `pm uninstall` a few lines later (USER_ALL only when no other user has the package), and
    # its safety argument is that hold_ondemand already moved the just-restored data out from under <pkg> so the
    # uninstall cannot take it.
    # That was true of CE and DE and FALSE of external app-data, which the loop above never touched -- and for
    # an on-demand app /data/media/<uid>/Android/data/<pkg> IS the #media ESSENTIAL tier, because #497 made
    # app-essential media essential so the app would not fail at launch.
    #
    # Measured on lynx 2026081605 (odtest3, user 10), every login for weeks:
    #   18:48:31  /data/media/10  files=120 bytes=87,950,187   <- the #media restore lands 88 MB
    #   18:48:38  reap-stale-ondemand net.peakgames.toonblast  <- pm uninstall deletes it
    #   18:48:40  /data/media/10  files=28  bytes=2,512
    # mediad then bound the emptied dir to .under, the seal walked it, essential collapsed 66 MB -> 1.9 KB and
    # the shrink guard refused -- correctly. The refusal was a TRUE POSITIVE protecting the 86-chunk head; the
    # data loss it kept reporting was real and happened before it ever ran.
    #
    # The hold goes under the CHOOSER's own external dir on the SAME volume, exactly mirroring the CE/DE hold:
    # `pm uninstall <pkg>` cannot reach it (different package), PM's reconcile keeps it (the chooser IS
    # installed), and it stays inside /data/media/<uid> so the move is a rename within one fscrypt policy
    # rather than an 88 MB copy across two.
    for vol in "/data/media/$uid/Android/data" "/data/media/$uid/Android/obb"; do
      src="$vol/$pkg"
      [ -d "$src" ] || continue                          # app has no external data on this volume
      holddir="$vol/com.nowhere.chooser/$ODHOLD"
      dst="$holddir/$pkg"
      mkdir -p "$holddir" 2>>"$LOG"
      if [ -d "$dst" ]; then
        # NWP-20260922-09: the SAME ratchet, on the volumes that carry the most bytes. Merge, newest wins --
        # see the long note on the CE/DE loop above for why a bare `[ -d "$dst" ]` cannot make this decision.
        # For an on-demand app Android/data/<pkg> IS the #media ESSENTIAL tier (#497), so dropping a
        # non-empty canonical here also collapses essential media and trips the seal’s shrink guard.
        if _ce=$(cp -a "$src"/. "$dst"/ 2>&1); then
          rm -rf "$src" 2>/dev/null
          [ -e "$src" ] && echo "[roamd] WARN on-demand $pkg ($vol) could not remove all of the canonical after the merge -- the rest is left in place (NWP-20261109-09) $(date)" >> "$LOG"
          echo "[roamd] on-demand $pkg ($vol) merged canonical into existing ext hold, newest wins (NWP-20260922-09) $(date)" >> "$LOG"
        else
          _cn=$(printf '%s\n' "$_ce" | grep -c .)
          _cl=$(printf '%s\n' "$_ce" | sed -n '$p')
          case "$_cl" in *': '*) _cl=${_cl##*: } ;; *) _cl= ;; esac
          case "$_cl" in ''|*/*|*\'*|*\"*) _cl=error ;; esac
          [ "${#_cl}" -le 80 ] || _cl=error
          echo "[roamd] WARN on-demand $pkg ($vol) ext merge FAILED -- canonical LEFT IN PLACE, nothing dropped (NWP-20260922-09) $(date) ($_cn error line(s), last: $_cl)" >> "$LOG"
        fi
      elif mv "$src" "$dst" 2>>"$LOG"; then
        echo "[roamd] held on-demand EXT data $pkg ($vol) $(date)" >> "$LOG"
      fi
      restorecon -R "$holddir" 2>>"$LOG"
    done
  done < "$ak"
  if [ "$_nk" -gt 0 ]; then
    echo "[roamd] hold: $_nk kept app(s) the image ships left in place, not parked (NWP-20261129-27) $(date)" >> "$LOG"
  fi
  return 0
}

# od_parked_report UID (NWP-20261119-17): one roam.log line saying how much of this sign-in's restored CE and DE data
# belongs to On-demand and Auto apps that stay parked in .nowhere-odhold until a tap. The vault and #de restores fetch
# that data at every sign-in, and the decided per-package fetch (docs/product-decisions.md, 2026-10-26, #2) is to be
# timed against this number. Diagnostics only: it reads the same nowhere-appkeep as hold_ondemand and changes nothing.
# `installed` rows (spelled out or bare) are skipped: RESTORE-ODDATA hands their hold back right after the install.
# ONE `du` over every hold, bounded at 3 s, so a huge hold adds at most that to the sign-in; its stderr is dropped,
# because toybox du names the path it fails on and a path holds a package name. The line carries counts and sizes
# only, never a name or a path. A failed or timed-out du logs "size unknown" and still returns 0: a measurement
# never fails a sign-in. Caller: the `in` op, right after hold_ondemand. test-od-parked-report.sh covers it.
od_parked_report() {
  local uid="$1" ak pkg mode rest d _has _seen=" " _n=0 _ce=0 _de=0 _out _rc _k _p _t0
  _t0=$(_ms)
  ak="/data/user/$uid/com.nowhere.chooser/files/nowhere-appkeep"
  [ -f "$ak" ] || return 0
  set --
  while IFS="$(printf '\t')" read -r pkg mode rest; do
    case "$mode" in ondemand|auto) ;; *) continue;; esac
    pkgname_ok "$pkg" || continue
    case "$_seen" in *" $pkg "*) continue;; esac   # a doubled row is one app
    _seen="$_seen$pkg "
    _has=0
    for d in "/data/user/$uid/com.nowhere.chooser/$ODHOLD/$pkg" "/data/user_de/$uid/com.nowhere.chooser/$ODHOLD/$pkg"; do
      [ -d "$d" ] || continue
      set -- "$@" "$d"
      _has=1
    done
    [ "$_has" = 1 ] && _n=$((_n + 1))
  done < "$ak"
  if [ "$#" -gt 0 ]; then
    _out=$(timeout 3 du -sk "$@" 2>/dev/null)
    _rc=$?
    if [ "$_rc" != 0 ]; then
      echo "[roamd] IN parked data of $_n On-demand/Auto app(s), fetched by the sign-in's restores: size unknown, measured in $(( $(_ms) - _t0 ))ms (NWP-20261026-35 #2) $(date)" >> "$LOG"
      [ -n "${NOWHERE_SIGNIN_SUMMARY:-}" ] && echo "v=1 parked apps=$_n size=unknown" 2>/dev/null >> "$NOWHERE_SIGNIN_SUMMARY"   # NWP-20261122-09
      return 0
    fi
    while IFS="$(printf '\t')" read -r _k _p; do
      case "$_k" in ''|0?*|*[!0-9]*) continue;; esac   # an unexpected du line is ignored
      case "$_p" in
        "/data/user/$uid/"*) _ce=$((_ce + _k)) ;;
        "/data/user_de/$uid/"*) _de=$((_de + _k)) ;;
      esac
    done <<ODPR_EOF
$_out
ODPR_EOF
  fi
  echo "[roamd] IN parked data of $_n On-demand/Auto app(s), fetched by the sign-in's restores: CE $_ce KiB, DE $_de KiB, measured in $(( $(_ms) - _t0 ))ms (NWP-20261026-35 #2) $(date)" >> "$LOG"
  [ -n "${NOWHERE_SIGNIN_SUMMARY:-}" ] && echo "v=1 parked apps=$_n ce_kib=$_ce de_kib=$_de" 2>/dev/null >> "$NOWHERE_SIGNIN_SUMMARY"   # NWP-20261122-09
  return 0
}

# od_other_users UID (NWP-20261201-17, h60 #6): the ids of the users other than 0 and UID that still have a record, one
# per line, each once. The loop is staging_boot's: <n>.xml, <n>.xml.backup and <n>.xml.reservecopy each name a user
# (userdir_has_record: a live user can briefly have only one of them), and a bare <n>/ directory does not. Ids below 10
# are system ids, 0 among them. Caller: reap_stale_ondemand.
od_other_users() {
  local _p _i _seen=" "
  for _p in "/data/system/users/"*; do
    _i=${_p##*/}; _i=${_i%.reservecopy}; _i=${_i%.backup}; _i=${_i%.xml}
    case "$_i" in ''|0?*|*[!0-9]*) continue;; esac
    [ "$_i" -lt 10 ] && continue
    [ "$_i" = "$1" ] && continue
    case "$_seen" in *" $_i "*) continue;; esac
    userdir_has_record "$_i" || continue
    _seen="$_seen$_i "
    printf '%s\n' "$_i"
  done
  return 0
}

# od_reap_batch UID ENTRY... (NWP-20261130-06): the removal step of reap_stale_ondemand. An entry is `A:<pkg>` (USER_ALL:
# `pm uninstall <pkg>`) or `K:<pkg>` (`pm uninstall --user 0 <pkg>`, then `--user UID`). The entries go, 16 at a time,
# to ONE `sh` process per batch, bounded as a whole by `timeout -k 5 120`, which runs every call of the batch in list
# order. No call has its own timeout process, and the reap's own shell runs no pm uninstall. The batch reads its entries
# on stdin; pm reads /dev/null and writes to /dev/null, so the batch's stdout holds one result line per entry: `A <rc>`
# or `K <rc user 0> <rc user UID>`. An `A` entry also logs its rc line. This function prints one line per entry, in list
# order: the batch's own line, or `A -` / `K - -` for an entry the batch did not reach (a stall that hit the bound, a
# batch that could not start), which then counts as failed; a batch that ends early logs one WARN, with counts only.
# One `pm uninstall` takes one name (the arguments after it are split names), so a batch makes one pm call per removal.
od_reap_batch() {
  local uid="$1" _e _c="" _n=0
  shift
  for _e; do
    _c="$_c$_e
"
    _n=$((_n + 1))
    if [ "$_n" = 16 ]; then od_reap_batch_run "$uid" "$_n" "$_c"; _c=""; _n=0; fi
  done
  [ "$_n" = 0 ] || od_reap_batch_run "$uid" "$_n" "$_c"
  return 0
}

# od_reap_batch_run UID N ENTRIES (NWP-20261130-06): one batch of od_reap_batch, N entries one per line.
od_reap_batch_run() {
  local uid="$1" _n="$2" _c="$3" _r _rc _got=0 _k _a _b _e _i=0
  _r=$(timeout -k 5 120 sh -c '
u=$1; log=$2
while IFS= read -r e; do
  p=${e#?:}
  case "$e" in
    K:?*) pm uninstall --user 0 "$p" </dev/null >/dev/null 2>&1; a=$?
          pm uninstall --user "$u" "$p" </dev/null >/dev/null 2>&1; echo "K $a $?" ;;
    A:?*) pm uninstall "$p" </dev/null >/dev/null 2>&1; a=$?
          echo "[roamd] reap-stale-ondemand $p (rc=$a)" >> "$log"; echo "A $a" ;;
  esac
done' sh "$uid" "$LOG" 2>>"$LOG" <<ODRB_EOF
$_c
ODRB_EOF
)
  _rc=$?
  while read -r _k _a _b; do
    case "$_k" in A|K) [ "$_got" -lt "$_n" ] || continue; _got=$((_got + 1)); echo "$_k $_a $_b" ;; esac
  done <<ODRR_EOF
$_r
ODRR_EOF
  while IFS= read -r _e; do
    [ -n "$_e" ] || continue
    _i=$((_i + 1))
    [ "$_i" -le "$_got" ] && continue
    case "$_e" in K:*) echo "K - -" ;; *) echo "A -" ;; esac
  done <<ODRE_EOF
$_c
ODRE_EOF
  [ "$_got" -lt "$_n" ] && echo "[roamd] WARN reap-stale-ondemand: a batch ended after $_got of $_n package(s) (rc=$_rc) -- the rest count as failed (NWP-20261130-06) $(date)" >> "$LOG"
  return 0
}

# reap_stale_ondemand MANIFEST UID (#204, DIA-20260726-08): clear any RETAINED archived package record left by a prior
# session BEFORE the chooser raises this login's archived placeholders. PackageManager keeps an archived package's
# record across removeUser, so a 2nd (or interrupted-logoff) roam-in finds the leftover and installArchivedPlaceholder
# COLLIDES with it -> the app strands as a label-less ghost in "Your apps" (device-proven on lynx). Root
# `pm uninstall <pkg>` (USER_ALL) clears the record (the chooser's own PackageInstaller.uninstall cannot -- it runs
# in a user where the app is installed=false). This REPLACES the old logoff-time reap, which was fragile: it raced
# the user teardown and, if the logoff was interrupted before it ran (the 22-min watchdog reboot), leaked the record
# anyway. Here it is idempotent + SELF-HEALING regardless of how the last logoff ended (a no-op when there's no
# leftover). Runs AFTER hold_ondemand and BEFORE the chooser raises. ONLY ondemand-mode rows (manifest col 4): an
# INSTALLED-mode kept app is restored+installed whole and must NOT be touched. Bounded by `timeout` -- a pm stall at
# login must not wedge the roam-in either.
# NWP-20261125-01 (docs/product-decisions.md, h55 #4): the safety premise -- hold_ondemand moved the restored data out
# of <pkg>, so the USER_ALL uninstall cannot take it -- is now CHECKED here, not assumed. hold_ondemand leaves the
# canonical dir in place when the merge into an existing hold fails, when the plain `mv` fails, when the name fails
# pkgname_ok (this reap's own name filter is looser) and when nowhere-appkeep is absent. So, for each row that passes
# the filters, if /data/user/UID/<pkg>, /data/user_de/UID/<pkg>, /data/media/UID/Android/data/<pkg> or
# /data/media/UID/Android/obb/<pkg> still exists (`-e`: a non-directory counts), the row makes NO pm call, logs one
# SKIPPED line naming the first volume found (CE, DE, data or obb) and is listed. The check reads disk state, not
# hold_ondemand's outcome, so it covers any future path that leaves data in place too. A UID that is empty or not
# all digits fails closed: one log line, no pm call, no list (without the uid the premise cannot be checked).
# The list is $STATE/od-unparked.<UID>: one package name per line, each ending in a newline, no other field; an empty
# file means nothing was skipped. It is written FRESH (temp + rename, mode 600) at every call with a valid uid, also
# when the manifest is absent, so it is rewritten at each sign-in of that uid, as $STATE/.declined.<uid> is cleared.
# $STATE is the tmpfs. A failed write is logged and changes nothing else: the safety is the missing pm call, not the
# file.
# NWP-20261129-13: the reader is the gate's chooser, which leaves those apps out of this session's placeholders. The
# decision puts the list in roamd's state dir, but that chooser is an app uid in user 0 and cannot read $STATE. So the
# same list is ALSO written beside the manifest it qualifies, as <manifest dir>/od-unparked (the chooser's .appcode):
# an inference from the decision, not its words. rmTree removes it with .appcode. The in op's chown and restorecon of
# .appcode ran before this call and do not cover it, so this block does both, on the temp file before the rename, so
# the chooser never sees a copy it cannot read. Temp + rename, mode 600, owned by the dir's owner. A manifest whose dir
# is absent writes no copy. A failed write logs one WARN naming no package and changes nothing else: the chooser then
# raises as it did before this list, and the safety is still the missing pm call. A failed restorecon alone keeps the
# copy, as the in op's own restorecon of this dir ignores its rc: the new file already inherits the dir's label.
# NWP-20261201-17 (docs/product-decisions.md, h60 #6, which applies h59 #12's rule and supersedes h48 #4 and h55 #4's
# note for this reap): USER_ALL would also delete a cold-locked session's copy of the package and its data. So a package
# another user has is uninstalled only `--user 0` and `--user UID`, and USER_ALL stays for a package no other user has.
# Each other user's `pm list packages --user <n>` is read ONCE per call, at the first row that reaches removal, not one
# dumpsys per package: a sign-in has about 72 packages (NOWHERE-1690). No -a: with it every package reads as "has it".
# A non-zero rc or an empty listing (a live user always lists system packages) makes the read UNKNOWN, and every package
# then goes per-user: data loss is the worse error, and a record left behind is retried at the next sign-in. The match
# is in-shell and newline-anchored. The two new log lines hold counts only, no package name and no other user's id.
# Two residuals. A departed session whose user is not yet reaped counts as another user, so its package keeps its record
# until a later sign-in. Another user's archived (unfetched) placeholder is not in its listing without -a, so that
# package still goes USER_ALL: its data is parked in that user's hold, so only the placeholder goes.
# NWP-20261130-06: the reap spent about 0.8 s per package, about 60 s of a sign-in (NW-98a2, frankel 0.5.53), and
# removing data is not deferred (docs/product-decisions.md, 2026-10-26). So the loop above only CLASSIFIES now, with the
# same mode filter, name guard, unparked-data check, listing read and h60 #6 rule: each row that reaches removal is
# listed as `A:<pkg>` (USER_ALL) or `K:<pkg>` (another user has it, or a listing is UNKNOWN: `--user 0` and `--user
# UID`). od_reap_batch then removes the list in batches of 16, each ONE `sh` process under `timeout -k 5 120`, with the
# same pm argv in the same order. h60 #6's two count lines stay; the reap adds a removed/failed count per package (a
# kept package is removed only when both of its calls are) and one timing line, timed from before the list is built.
# test-reap-stale-ondemand.sh covers it.
reap_stale_ondemand() {
  local man="$1" uid="$2" rline rpkg rmode _vol _skipped="" _out _tmp _nl _ou _ol _lst _rd=0 _unk=0 _kp _nk=0 _ko=0 _kf=0
  local _t0 _res _k _a _b _ok=0 _bad=0
  case "$uid" in ""|*[!0-9]*) echo "[roamd] reap-stale-ondemand: no valid uid -- reaping nothing (NWP-20261125-01)" >> "$LOG"; return 0;; esac
  _t0=$(_ms)
  set --
  _nl="
"
  _ol="$_nl"
  if [ -f "$man" ]; then
    while IFS= read -r rline; do
      [ -n "$rline" ] || continue
      rpkg=$(printf '%s' "$rline" | cut -f1)
      rmode=$(printf '%s' "$rline" | cut -f4)
      case "$rmode" in ondemand|auto) ;; *) continue;; esac   # #130: auto rows raise placeholders too -> same stale-record reap
      case "$rpkg" in ""|*/*|*" "*) continue;; esac
      _vol=
      [ -e "/data/user/$uid/$rpkg" ] && _vol=CE
      [ -z "$_vol" ] && [ -e "/data/user_de/$uid/$rpkg" ] && _vol=DE
      [ -z "$_vol" ] && [ -e "/data/media/$uid/Android/data/$rpkg" ] && _vol=data
      [ -z "$_vol" ] && [ -e "/data/media/$uid/Android/obb/$rpkg" ] && _vol=obb
      if [ -n "$_vol" ]; then
        echo "[roamd] reap-stale-ondemand $rpkg SKIPPED -- its data is still in the canonical dir ($_vol), not parked (NWP-20261125-01) $(date)" >> "$LOG"
        _skipped="$_skipped$rpkg
"
        continue   # NWP-20261125-01: no pm call for unparked data
      fi
      if [ "$_rd" = 0 ]; then
        _rd=1
        for _ou in $(od_other_users "$uid"); do
          if _lst=$(timeout -k 2 20 pm list packages --user "$_ou" </dev/null 2>/dev/null) && [ -n "$_lst" ]; then
            _ol="$_ol$_lst$_nl"
          else
            _unk=1
          fi
        done
      fi
      _kp=$_unk
      case "$_ol" in *"${_nl}package:$rpkg${_nl}"*) _kp=1 ;; esac
      if [ "$_kp" = 1 ]; then
        _nk=$((_nk + 1))
        set -- "$@" "K:$rpkg"
        continue
      fi
      set -- "$@" "A:$rpkg"
    done < "$man"
  fi
  if [ "$#" -gt 0 ]; then
    _res=$(od_reap_batch "$uid" "$@")
    while read -r _k _a _b; do
      case "$_k" in
        A) if [ "$_a" = 0 ]; then _ok=$((_ok + 1)); else _bad=$((_bad + 1)); fi ;;
        K) if [ "$_a" = 0 ]; then _ko=$((_ko + 1)); else _kf=$((_kf + 1)); fi
           if [ "$_b" = 0 ]; then _ko=$((_ko + 1)); else _kf=$((_kf + 1)); fi
           if [ "$_a" = 0 ] && [ "$_b" = 0 ]; then _ok=$((_ok + 1)); else _bad=$((_bad + 1)); fi ;;
      esac
    done <<ODRB_EOF
$_res
ODRB_EOF
  fi
  echo "[roamd] reap-stale-ondemand: $_ok removed, $_bad failed (NWP-20261130-06) $(date)" >> "$LOG"
  echo "[roamd] reap-stale-ondemand: $# package(s) in $(( $(_ms) - _t0 )) ms (NWP-20261130-06) $(date)" >> "$LOG"
  [ "$_nk" -gt 0 ] && echo "[roamd] reap-stale-ondemand: $_nk package(s) kept for another user, removed for user 0 and user $uid only ($_ko ok, $_kf failed) (h60 #6) $(date)" >> "$LOG"
  [ "$_unk" = 1 ] && echo "[roamd] WARN reap-stale-ondemand: could not read another user's packages -- no package removed for all users (h60 #6) $(date)" >> "$LOG"
  _out="$STATE/od-unparked.$uid"; _tmp="$_out.tmp"
  if { ( : > "$_tmp" ) && printf '%s' "$_skipped" >> "$_tmp" && chmod 600 "$_tmp" && mv -f "$_tmp" "$_out"; } 2>>"$LOG"; then :
  else
    rm -f "$_tmp" 2>/dev/null
    echo "[roamd] WARN reap-stale-ondemand: could not write the unparked list for user $uid (NWP-20261125-01) $(date)" >> "$LOG"
  fi
  local _dir _own _copy _ctmp
  _dir="${man%/*}"
  if [ -d "$_dir" ]; then
    _copy="$_dir/od-unparked"; _ctmp="$_copy.tmp"
    if { _own=$(stat -c %u "$_dir") && [ -n "$_own" ] && ( : > "$_ctmp" ) && printf '%s' "$_skipped" >> "$_ctmp" && chmod 600 "$_ctmp" && chown "$_own:$_own" "$_ctmp" && { restorecon -D "$_ctmp" || :; } && mv -f "$_ctmp" "$_copy"; } 2>>"$LOG"; then :
    else
      rm -f "$_ctmp" 2>/dev/null
      echo "[roamd] WARN reap-stale-ondemand: could not write the unparked list beside the manifest for user $uid (NWP-20261129-13) $(date)" >> "$LOG"
    fi
  fi
  return 0
}

# reap_orphan_provisioned MANIFEST (DIA-20260730-06): the amnesia backstop for CROSS-PROFILE leaks. reap_stale_ondemand
# above only clears records NAMED in THIS login's manifest; a package left by a DIFFERENT profile -- either the
# keep-installed installApkSet user-0 leak (device-owner install FOR USER 0, survives logoff) or a record PM retained
# across removeUser -- is never in this manifest, so it ghosts across profiles (device-proven: odtest4's
# net.peakgames.toonblast visible from odtest9; com.wireguard.android leaked LIVE into user 0). Reap EVERY
# `installer=com.nowhere.chooser` package that is NOT in this profile's keep manifest: `pm uninstall` (USER_ALL) clears
# both a live user-0 install AND a dangling record. SAFE by construction -- bundled/system apps carry installer=null;
# only roamed-provisioned apps carry the chooser installer. Runs at roam-in right after reap_stale_ondemand (before the
# chooser raises), so a fresh profile never even sees a prior profile's app. Idempotent + self-healing; each pm bounded
# by timeout so it cannot wedge the login. (installApkSet is also now roamed-user-scoped, so leak A stops at the source;
# this is the belt-and-suspenders that also cleans historical + dangling records.)
reap_orphan_provisioned() {
  local man="$1" ruid="$2" keep p cp inst u reap _others _in0 _inr
  # keep-set = this profile's FULL provisioned set (nowhere-apps.list, restored with the CE) UNION the keep-installed
  # raise manifest -- NOT the manifest alone. The manifest lists ONLY keep-installed/on-demand apps; a package the
  # profile provisions another way -- e.g. the #159 WireGuard always-on VPN, in nowhere-apps.list but never in the
  # keep-installed manifest -- would otherwise look like an orphan and get a (harmless, DELETE_FAILED) uninstall
  # attempt every login. Empty/absent both => reap ALL provisioned (a truly empty profile keeps nothing).
  # DIA-20260805-10: the KEEP-SET (nowhere-appkeep) is part of the union too. The manifest is only as good as the
  # last seal, and DIA-20260805-09 showed it can lose a kept app's code entirely -- at which point this reap read
  # the survivor as another profile's leftover and pm-uninstalled it. Device-proven on lynx 2026-08-05: a degraded
  # head listing 1 pkg made this line delete com.android.vending and com.google.android.youtube at 19:22:09 (both
  # rc=0), which is how the user lost their Play Store icon. The keep-set is the user's EXPLICIT statement that
  # this profile keeps the app, so it outranks a manifest we may have failed to write. Cross-profile protection is
  # untouched: nowhere-appkeep is restored with THIS profile's CE, so it can only ever name this profile's apps --
  # another profile's leftover is still not in it, and is still reaped. Pairs with the appcode_seal recovery
  # sweep: leaving the app installed is what lets the next seal re-seal its code and heal the profile.
  keep=$( { [ -f "$man" ] && cut -f1 "$man"; [ -f "$USERDIR/com.nowhere.chooser/files/nowhere-apps.list" ] && cat "$USERDIR/com.nowhere.chooser/files/nowhere-apps.list"; [ -f "$USERDIR/com.nowhere.chooser/files/nowhere-appkeep" ] && cut -f1 "$USERDIR/com.nowhere.chooser/files/nowhere-appkeep"; } 2>/dev/null )
  pm list packages -a -i 2>/dev/null | grep 'installer=com.nowhere.chooser' | sed 's/^package://; s/ .*//' | \
  while IFS= read -r p; do
    case "$p" in ""|*/*|*" "*) continue;; esac
    printf '%s\n' "$keep" | grep -qxF "$p" && continue   # this profile's own provisioned app -> leave it
    # Only a real DOWNLOADED app (codePath under /data/app) is reap-eligible: a bundled /product|/system app can't be
    # pm-uninstalled anyway (DELETE_FAILED_INTERNAL_ERROR) and must never be targeted -- belt-and-suspenders over the
    # keep-set above, so a bundled provisioned app is skipped even if it somehow escaped nowhere-apps.list.
    cp=$(dumpsys package "$p" 2>/dev/null | sed -n 's/.*codePath=//p' | head -1)
    case "$cp" in /data/app/*) ;; *) continue;; esac
    # DIA-20260811-07: do NOT uninstall a package that is live for a DIFFERENT profile. The enumeration above is
    # `pm list packages -a -i`, and -a includes packages that merely have a RECORD in user 0's view -- so an app
    # correctly installed for another roamed user shows up here even though it is not installed for user 0 and is
    # invisible to this profile. Device-proven on lynx 2026-08-11: `pm list packages -a | grep youtube` -> 1 while
    # `pm list packages --user 0 | grep youtube` -> 0. Combined with the USER_ALL `pm uninstall` below, a FRESH
    # profile (empty keep-set by construction -- no manifest, no apps.list, no appkeep) uninstalled another
    # profile's Play Store and YouTube device-wide, and because that profile's #apps head was short there was
    # nothing left to restore from. Ticket NW-befc9e0f9c2b, 11:56:52 "restore: profile empty -> nothing" followed
    # one second later by "reap-orphan-provisioned com.google.android.youtube (rc=0)".
    #
    # Both documented reasons for the USER_ALL breadth are preserved:
    #   - a residual user-0 INSTALL (the old installApkSet leak) -> still reaped
    #   - a dangling RECORD with no install anywhere -> still reaped (that is what
    #     USER_ALL uniquely clears: see the reap_stale_ondemand header)
    # What stops is destroying code that belongs to a live profile which simply is not signed in right now. That
    # is not a leak: installApkSet has been roamed-user-scoped since DIA-20260730-06 (createContextAsUser), so a
    # per-user install is already invisible to this profile without uninstalling anything.
    # A package installed for user 0 or the roaming user AND for another user is the mixed case (decided 2026-11-05,
    # h59 #12, docs/product-decisions.md, "seventeen answers to harvest 59 ..."): USER_ALL would delete a cold-locked
    # session's copy and its data, so only the copies of user 0 and the roaming user go. USER_ALL stays for every
    # other reap: a record installed for nobody, or only for user 0 and/or the roaming user.
    inst=$(dumpsys package "$p" 2>/dev/null | sed -n 's/^ *User \([0-9][0-9]*\): .*installed=true.*/\1/p')
    reap=1
    if [ -n "$inst" ]; then
      reap=0
      for u in $inst; do
        # user-0 residue is the leak this backstop exists for; an install for the CURRENT roaming user that is not
        # in the keep-set is this profile's own switched-off app, which is today's behaviour and stays.
        { [ "$u" = 0 ] || [ "$u" = "$ruid" ]; } && reap=1
      done
    fi
    if [ "$reap" != 1 ]; then
      echo "[roamd] reap-orphan-provisioned SKIP $p -- installed for user(s) $inst, none of them user 0 or $ruid; another profile's app, not a leak $(date)" >> "$LOG"
      continue
    fi
    _others=""; _in0=0; _inr=0
    for u in $inst; do
      if [ "$u" = 0 ]; then _in0=1
      elif [ "$u" = "$ruid" ]; then _inr=1
      else _others="${_others:+$_others }$u"
      fi
    done
    if [ -n "$_others" ]; then
      if [ "$_in0" = 1 ]; then
        timeout -k 5 30 pm uninstall --user 0 "$p" </dev/null >/dev/null 2>&1
        echo "[roamd] reap-orphan-provisioned $p --user 0 (rc=$?) kept for user(s) $_others $(date)" >> "$LOG"
      fi
      if [ "$_inr" = 1 ]; then
        timeout -k 5 30 pm uninstall --user "$ruid" "$p" </dev/null >/dev/null 2>&1
        echo "[roamd] reap-orphan-provisioned $p --user $ruid (rc=$?) kept for user(s) $_others $(date)" >> "$LOG"
      fi
      continue
    fi
    timeout -k 5 30 pm uninstall "$p" </dev/null >/dev/null 2>&1
    # rc + WHY, so this never again reads as routine hygiene: "installed=" is the state that justified the uninstall.
    echo "[roamd] reap-orphan-provisioned $p (rc=$?) installed=[${inst:-none}] $(date)" >> "$LOG"
  done
}

# grant_perms_for UID [PKGFILTER [DECLINES [BATCH]]] (#94/#204): re-grant the captured roamed runtime perms + the "while in use"
# appops-foreground mode (location/camera/mic) from nowhere-perms. With PKGFILTER, grant ONLY that one package's
# perms -- used by `odrestore` after a tap materialises an on-demand app (the login grant no-op'd on its APK-less
# placeholder, which has no manifest to grant against). pm/cmd from su:s0 use /dev/null stdio (the DIA-56 fd-passing
# denial is only about CAPTURING output, which we don't). Factored out of the `grant` op. Since NWP-20261012-05 it
# also re-declines what the profile declined (`flags:` lines), last, so a declined permission is not asked again --
# always at login (no PKGFILTER), and for a PKGFILTER call only when DECLINES is 1 (odrestore: a first install this session -- a hold, or since
# NWP-20261022-05 the session's nowhere-od-materialised record) and the
# package's declines were not already applied this session ($STATE/.declined.<uid>).
# Since NWP-20261025-10 the GRANT phase (grant, appop and deny lines, the INTERNET default) runs once per package per
# session too: a PKGFILTER call that is not a first install (DECLINES 1 and not yet in .declined.<uid>) for a package
# in $STATE/.granted.<uid> -- the packages whose grants landed -- skips it, so an update's heal cannot re-grant what
# the user changed mid-session. Residuals and the full rule: the NWP-20261025-10 bullet below.
# BATCH (NWP-20261125-08) is a RESTORE-ODDATA list's token b<8 hex>.<i>.<n>: the list's ops share one
# `pm list packages -3` read (the NWP-20261123-08 block below).
grant_perms_for() {
  local uid="$1" pkgfilter="$2" PF gpkg gperm op aop n=0 _gbg=0 _gn _gd _dcl=0 _drej=0 _dskip=0 _df _dfl _dperm _pfx NL _dok=0 _dmark
  local _smsf _smsapp="" _sl _dsms=0 _ws _sz
  local _grec="$STATE/.granted.$uid" _gok="$STATE/.grantok" _gfirst=0 _gskip=0 _gnofile=0
  # NWP-20260820-25: the per-permission `pm grant` / `cmd appops set` calls are LATENCY, not CPU -- each is a
  # `cmd` startup plus a binder round trip. Measured on lynx 2026082005: 46ms each sequential, 10ms each at
  # 6-way concurrency (24 calls, 1107ms -> 260ms). With ~136 permissions on a real profile that is the
  # difference between `grant-135` at ~8.9s and ~2.1s, and after NWP-20260820-24 it is the single largest
  # phase of a login.
  #
  # ⚠ `pm` is NOT the overhead and must not be "optimised" away: /system/bin/pm is a one-line shell wrapper
  # (`cmd package "$@"`), and calling `cmd package` directly measured 54ms vs 53ms -- identical. The cost is
  # entirely `cmd` itself.
  #
  # Bounded to 6 in flight: enough to hide the latency, few enough not to pile work onto a single-threaded
  # binder path during a login that is already contended.
  #
  # The COUNT moves to a file because each grant now runs in a subshell and `n=$((n+1))` there would be lost.
  # Appends are 2 bytes under O_APPEND, so concurrent writers cannot interleave a line. The count is
  # diagnostic only -- it is the "-> N perms" in the log line below, and losing it would blind exactly the
  # kind of investigation this file keeps needing.
  # NWP-20261114-09: a failed redirection on the special builtin ':' ends mksh and dash; in a subshell it ends only the subshell.
  _gn="$STATE/.grantn"; ( : > "$_gn" ) 2>/dev/null
  PF="/data/user/$uid/com.nowhere.chooser/files/nowhere-perms"
  # NWP-20261201-19: a profile with no capture yet has no nowhere-perms, and its first-session installs reach this
  # call (AppInstallReceiver.heal -> RESTORE-ODDATA -> odrestore). A return here left them with Network off until the
  # sign-out captured that as the user's Network-off. So a PKGFILTER call goes on with no line known for any package:
  # the -3 read, the INTERNET default, the record and the .declined marker run; the grant lines and the flags pass do
  # not. A sign-in call with no file still returns here.
  if [ ! -f "$PF" ]; then
    [ -n "$pkgfilter" ] || { echo "[roamd] GRANT -> 0 perms (no file, user $uid) $(date)" >> "$LOG"; return 0; }
    _gnofile=1
  fi
  # The file read ONCE, newline-anchored on both sides, for the in-shell membership tests below (the INTERNET
  # default and the declined-permission skip). See NWP-20260820-19 at the INTERNET default for why it is anchored.
  NL='
'
  if [ "$_gnofile" = 1 ]; then _pfx="${NL}${NL}"; else _pfx="${NL}$(cat "$PF" 2>/dev/null)${NL}"; fi
  ( : > "$_gok" ) 2>/dev/null
  # NWP-20261025-10: a first install is the declines pass's own test (DECLINES 1 and not yet in .declined.<uid>), read
  # here BEFORE that pass records it. A package-filtered call that is not a first install, for a package whose grants
  # already landed this session ($_grec), is an update's heal: it must not re-grant what the user changed since.
  [ -n "$pkgfilter" ] && [ "${3:-}" = 1 ] && ! grep -qxF -- "$pkgfilter" "$STATE/.declined.$uid" 2>/dev/null && _gfirst=1
  if [ -n "$pkgfilter" ] && [ "$_gfirst" != 1 ] && grep -qxF -- "$pkgfilter" "$_grec" 2>/dev/null; then
    _gskip=1
    echo "[roamd] GRANT ($pkgfilter) -> skipped: granted this session, not a first install $(date)" >> "$LOG"
  fi
  [ "$_gskip" = 1 ] || [ "$_gnofile" = 1 ] || while read -r gpkg gperm; do
    [ -n "$gpkg" ] && [ -n "$gperm" ] || continue
    [ -n "$pkgfilter" ] && [ "$gpkg" != "$pkgfilter" ] && continue
    # #204: an `appop:<opstr>` line is a SPECIAL APP ACCESS (All files / draw-over / write-settings / install-source /
    # usage access)
    # captured from AppOps by capturePerms, NOT a pm-grantable runtime perm -- restore it with `appops set` (write-only,
    # so the su:s0 cmd fd-passing denial doesn't bite). Allowlist-guarded here too (defence in depth: never honour an op
    # outside the curated roaming set, even if a tampered/older sealed file names one). request_install_packages roams
    # (DIA-20260727-01) so F-Droid/Aurora don't re-ask to be an install source each session -- the per-APK
    # CONFIRM_INSTALL dialog still gates each actual install. get_usage_stats (usage access) roams since Q024
    # (docs/product-decisions.md, 2026-10-20), only when the user granted it: the capture records an allowed op only.
    # Keep in sync with ProfileActivity.SPECIAL_APPOP_PERMS.
    case "$gperm" in
      appop:*)
        aop="${gperm#appop:}"
        case "$aop" in
          android:manage_external_storage|android:system_alert_window|android:write_settings|android:request_install_packages|android:get_usage_stats)
            { cmd appops set --user "$uid" "$gpkg" "$aop" allow </dev/null >/dev/null 2>&1 && echo x >> "$_gn"; } &
            _gbg=$((_gbg + 1)); [ "$_gbg" -ge 6 ] && { wait; _gbg=0; };;
        esac
        continue;;
      deny:*)
        # DIA-20260813-08 (#127): an EXPLICIT captured revoke (only INTERNET is captured this way today) --
        # the user's deliberate Network-off toggle roams as the denial it is. Only INTERNET is honoured, the
        # same allowlist discipline as the appop lines: never revoke arbitrary perms named by a sealed file.
        case "${gperm#deny:}" in
          android.permission.INTERNET)
            { pm revoke --user "$uid" "$gpkg" android.permission.INTERNET </dev/null >/dev/null 2>&1 && { echo x >> "$_gn"; echo "$gpkg" >> "$_gok"; }; } &
            _gbg=$((_gbg + 1)); [ "$_gbg" -ge 6 ] && { wait; _gbg=0; };;
        esac
        continue;;
      flags:*)
        # NWP-20261012-05: a DECLINED permission. Applied in its own pass at the end of this function, after every
        # grant here has drained -- see there.
        continue;;
    esac
    # NWP-20261012-05: a permission the profile DECLINED is never granted, even if the file also names it as a
    # grant (a tampered or hand-edited file; the capture writes one or the other). Only the three flag forms the
    # declined pass honours suppress the grant, so a malformed flags line withholds nothing. ⚠ INTERNET is the one
    # exception: a `flags:` line naming INTERNET is REFUSED by the declined pass but still withholds a matching
    # INTERNET grant line here, and the INTERNET default below then sees that grant line and skips too, so the
    # package gets no INTERNET. That only withholds -- never grants -- and the capture never writes such a line.
    case "$_pfx" in
      *"${NL}${gpkg} flags:user-set:${gperm}${NL}"*|*"${NL}${gpkg} flags:user-fixed:${gperm}${NL}"*|*"${NL}${gpkg} flags:user-set,user-fixed:${gperm}${NL}"*)
        _dskip=$((_dskip + 1)); continue;;
    esac
    # #94: "While using the app" location/camera/mic is an APPOPS FOREGROUND mode, NOT the plain runtime grant.
    # The op is resolved HERE, in the parent, so only the two forks go to the background.
    op=""
    case "$gperm" in
      android.permission.ACCESS_FINE_LOCATION)   op=FINE_LOCATION;;
      android.permission.ACCESS_COARSE_LOCATION) op=COARSE_LOCATION;;
      android.permission.CAMERA)                 op=CAMERA;;
      android.permission.RECORD_AUDIO)           op=RECORD_AUDIO;;
    esac
    # ONE subshell per LINE keeps grant-then-foreground ORDERED for that permission -- the appops foreground
    # mode is a modifier on a grant that must already exist. Ordering ACROSS lines has never mattered: each is
    # an independent (package, permission) pair.
    { pm grant --user "$uid" "$gpkg" "$gperm" </dev/null >/dev/null 2>&1 && { echo x >> "$_gn"; echo "$gpkg" >> "$_gok"; }
      [ -n "$op" ] && cmd appops set --user "$uid" "$gpkg" "$op" foreground </dev/null >/dev/null 2>&1
    } &
    _gbg=$((_gbg + 1)); [ "$_gbg" -ge 6 ] && { wait; _gbg=0; }
  done < "$PF"
  wait                      # drain the last partial batch before the count is read
  n=$(wc -l < "$_gn" 2>/dev/null); n=${n:-0}
  rm -f "$_gn" 2>/dev/null
  # DIA-20260813-08 (#127): the INTERNET DEFAULT. GrapheneOS default-grants INTERNET at install; the roam's
  # install-existing/materialise paths don't, so a package the capture never saw installed (its whole history
  # a placeholder at every logoff) came back with NO NETWORK -- Play Store on 2026-08-13, "you're offline" on
  # a fully-online device. With revokes now captured explicitly (deny: lines above), an absent INTERNET line
  # -- grant or deny -- unambiguously means "no captured knowledge", and the platform default is strictly more
  # correct than an accidental deny. Grant it for every third-party package with no line either way; harmless
  # for packages that don't request it (pm grant just fails). Same fd discipline as the rest of this function.
  # NWP-20260820-19: the two membership tests below were `grep -qxF` -- i.e. TWO FORKS PER THIRD-PARTY
  # PACKAGE, on a loop that already runs one `pm grant` per package. Measured on frankel 2026-08-20 with the
  # NWP-20260819-05 instrumentation, this whole function cost `TIMING grant-135 20434ms`, one of the three
  # fork-bound loops that make a login ~104s. Read the file ONCE and match in-shell instead; the `pm` calls are
  # the irreducible floor and are untouched, so this removes the grep share and nothing else.
  #
  # SEMANTICS PRESERVED EXACTLY. `grep -qxF` is whole-line (-x) + fixed-string (-F), so the replacement is
  # newline-ANCHORED on both sides: `$NL$dpkg <perm>$NL`. Without those anchors `com.foo` would match a
  # `com.foobar ...` line and silently skip a package that should have been granted. The needle sits inside
  # double quotes within the `case` pattern, so it is literal -- glob characters in a package name cannot be
  # interpreted, which is the -F half. `$(cat)` strips trailing newlines, so the closing $NL is re-added
  # explicitly; the leading one anchors the first line. (`_pfx` is read once above the per-line loop since
  # NWP-20261012-05, which matches it the same way for declined permissions.)
  #
  # NWP-20261123-08: the third-party list is read ONCE per call, into _g3. The INTERNET default iterates it, and the
  # record below keeps only the packages it lists. A grant pm took on an archived placeholder then is not the
  # package's session grant once its code arrives: an install by another installer (no hold, no materialised record)
  # would otherwise skip its grant phase, the INTERNET default included. The skip path reads no list and runs no pm.
  # pm's own exit status is checked BEFORE the prefix is stripped: a pipe into sed would hide it, and a pm that
  # prints part of the list and then fails must record nothing, not the part it printed.
  #
  # NWP-20261125-08 (h53 #1): the ops of one RESTORE-ODDATA list (BATCH) share that read. The first op that runs pm
  # publishes its stripped answer to $STATE/.odbatch3.<uid>.<b-part> (tmpfs); a later op uses it only if it lists
  # PKGFILTER as a whole line. A list read before the package was installed lacks it, so that op runs pm again: a
  # stale list never skips a package's INTERNET default or its record. A directory, an unreadable file or a failed
  # or empty pm answer is never used or published. The last op (i = n) never publishes; the odrestore arm removes the
  # file after its grant step, whether or not that op reached this function (RF-001).
  local dpkg dflt=0 _g3=""
  local _gbatch="${4:-}" _gbf="" _gbl=0 _g3hit=0 _gbi
  case "$_gbatch" in */*|*[!0-9a-f.]*) _gbatch="" ;; b????????.?*.?*) ;; *) _gbatch="" ;; esac
  if [ -n "$pkgfilter" ] && [ -n "$_gbatch" ]; then
    _gbf="$STATE/.odbatch3.$uid.${_gbatch%%.*}"
    _gbi=${_gbatch#*.}
    [ "${_gbi%%.*}" = "${_gbi#*.}" ] && _gbl=1
  fi
  if [ "$_gskip" != 1 ]; then
    if [ -n "$_gbf" ] && [ -f "$_gbf" ] && [ -r "$_gbf" ] \
       && grep -qxF -- "$pkgfilter" "$_gbf" 2>/dev/null; then
      _g3=$(cat "$_gbf" 2>/dev/null) || _g3=""
      [ -n "$_g3" ] && _g3hit=1
    fi
    [ "$_g3hit" = 1 ] ||
    _g3=$(pm list packages --user "$uid" -3 2>/dev/null) || _g3=""
    [ "$_g3hit" = 1 ] ||
    [ -z "$_g3" ] || _g3=$(printf '%s\n' "$_g3" | sed 's/^package://')
    if [ "$_g3hit" != 1 ] && [ -n "$_g3" ] && [ -n "$_gbf" ] && [ "$_gbl" != 1 ] && [ ! -d "$_gbf" ]; then
      { ( : > "$_gbf.$$" ) 2>/dev/null && chmod 600 "$_gbf.$$" 2>/dev/null \
        && ( printf '%s\n' "$_g3" > "$_gbf.$$" ) 2>/dev/null && mv -f "$_gbf.$$" "$_gbf" 2>/dev/null; } \
        || rm -f "$_gbf.$$" 2>/dev/null
    fi
  fi
  [ "$_gskip" = 1 ] || for dpkg in $_g3; do
    [ -n "$pkgfilter" ] && [ "$dpkg" != "$pkgfilter" ] && continue
    case "$_pfx" in *"${NL}${dpkg} android.permission.INTERNET${NL}"*) continue;; esac
    case "$_pfx" in *"${NL}${dpkg} deny:android.permission.INTERNET${NL}"*) continue;; esac
    pm grant --user "$uid" "$dpkg" android.permission.INTERNET </dev/null >/dev/null 2>&1 && { dflt=$((dflt+1)); echo "$dpkg" >> "$_gok"; }
  done
  # The record: the _gok packages that are whole lines of _g3, matched in-shell and newline-anchored as the _pfx tests
  # are. A failed or empty list records nothing, the safe direction: a later call runs the grant phase again.
  # ⚠ This holds only while pm lists a placeholder only with -a. If `pm list packages -3` lists an archived
  # placeholder too, this filter cannot tell it from an app with code (docs/backlog.md, §B "A roamed app can come
  # back with GrapheneOS's Network permission off ...").
  if [ -n "$_g3" ]; then
    _g3="${NL}${_g3}${NL}"
    sort -u "$_gok" 2>/dev/null | while read -r dpkg; do
      case "$_g3" in *"${NL}${dpkg}${NL}"*) echo "$dpkg";; esac
    done >> "$_grec" 2>/dev/null
  fi
  rm -f "$_gok" 2>/dev/null
  # NWP-20261012-05: DECLINED permissions stay declined (docs/product-decisions.md, 2026-10-12). The platform
  # re-prompts for a permission that is not granted AND carries none of USER_SET / USER_FIXED (PermissionPolicyService,
  # PermissionManager EXPLICIT_SET_FLAGS) -- and a fresh user's not-granted permission carries neither, so before this
  # every permission a profile had declined (notifications above all) asked again after every roam. capturePerms now
  # writes `<pkg> flags:<user-set|user-fixed|user-set,user-fixed>:<perm>` for each dangerous permission that is not
  # granted and has either flag; this pass puts the flags back.
  #   - The flags FIRST, then `pm revoke`. A revoke does not touch the user flags, and once USER_SET / USER_FIXED is
  #     set a default grant that does not override the user (RoleService's override=false roles) stops at it -- so
  #     setting them first closes that window between the two calls. The revoke is still needed: a permission the
  #     platform or a role default-granted on install-existing would otherwise stay granted. Its rc is NOT gated on
  #     -- a revoke refused (a fixed permission) still leaves a flag that only ever suppresses a prompt.
  #     RoleService's re-grant to a role's CURRENT holders (onGrantDefaultRoles, on PACKAGE_ADDED among others) runs
  #     with override=false, so it stops at the flags this pass sets first. ⚠ STILL RACY, narrowly: a default or
  #     fallback holder ADDED to a role that has NO holder grants with the role's overrideUserWhenGranting -- true for
  #     SMS and dialer -- and clears the flags. The chooser re-applies the profile's declines to the SMS and dialer
  #     holders after its sign-in role step (PermDeclines.reapplyRoleHolders); such an add later in the session is not
  #     caught (PermDeclines' class comment).
  #   - LAST in this function, after the per-line grants and the INTERNET default have run: nothing here can grant
  #     after it. The per-line loop also skips a grant line for a pair this pass will decline.
  #   - ONLY at login and at a first materialise. A PKGFILTER call is also the install-heal's (AppInstallReceiver:
  #     every install and every UPDATE of an app this session) and it reads ~~the LOGIN-time nowhere-perms~~
  #     (Superseded by NWP-20261112-10: a mid-session capture -- PermsCaptureReceiver, relayed by the user-0
  #     PermsLiveRecord -- rewrites nowhere-perms, so it reads the file as last captured, not as of login), so a decline
  #     pass there would revoke a permission the user granted mid-session -- and GrapheneOS kills the app on a revoke.
  #     So a PKGFILTER call declines only when its caller says DECLINES=1, which odrestore does for a first install:
  #     the package's on-demand HOLD (data parked at login because the app was a placeholder) or, since NWP-20261022-05,
  #     this session's nowhere-od-materialised record -- AND only if this
  #     session has not already applied that package's declines. A hold alone is not "first install": odrestore
  #     KEEPS the hold on its failure paths (dest not app-owned, cp FAILED, dest missing) while the app stays
  #     installed and usable, and the next update's install-heal then arrives with the hold still there. So the first
  #     PKGFILTER decline pass for a package records it in $STATE/.declined.<uid> (whether or not it found a flags
  #     line), every later one is skipped, and the `in` op deletes the file at roam-in, beside nowhere-od-restored.
  #     ~~An on-demand app parked with NO data has no hold, so its first install cannot be told from an update and its
  #     declines wait for the next login.~~ (Superseded by NWP-20261022-05: the session's nowhere-od-materialised
  #     record tells that first install apart, so odrestore passes DECLINES=1 for it.) ~~(The grant lines above have the mirror of this flaw -- a mid-session
  #     REVOKE re-granted by an install-heal from the login-time file -- which predates this slice and is not fixed
  #     here.)~~ (Superseded by NWP-20261025-10: the grant phase has the same guard, see the next bullet.)
  #   - NWP-20261025-10: THE GRANT PHASE IS ONCE PER SESSION TOO. A PKGFILTER call that is not a first install (the
  #     test the declines pass makes, computed before the grant loop and without writing .declined) for a package
  #     already in $STATE/.granted.<uid> runs NO grant, appop or deny line and no INTERNET default for it, and logs
  #     `skipped: granted this session`: it is an update's heal reading ~~the LOGIN-time file~~ (Superseded by
  #     NWP-20261112-10: the file as last captured, see the next bullet), and re-running it would
  #     re-grant a permission the user revoked since (and sign-out would then capture the grant, losing the revoke for
  #     good). A first install always runs it. The record holds the packages one of whose `pm grant` / INTERNET `pm
  #     revoke` / INTERNET default succeeded and that `pm list packages -3` lists (NWP-20261123-08), written on every
  #     call (sign-in included), so an APK-less placeholder that pm refuses is not recorded and its first real install
  #     still gets its grants; `in` clears it at roam-in.
  #     Residuals: (a) a package whose only lines are `appop:` lines is never recorded (appops succeeds on a
  #     placeholder, so its success proves nothing), and an update still re-allows its special app access; (b) ~~a
  #     package granted at sign-in and installed by another installer later, with no hold and no materialised
  #     record, is not a first install, so it keeps only its live grants until the next sign-in.~~ (Superseded in
  #     part by NWP-20261123-08: a grant pm took on an archived placeholder is no longer recorded, so that install's
  #     call runs the grant phase, INTERNET default included. This holds only while pm lists a placeholder only with
  #     -a; an app with code at sign-in that another installer replaces later still keeps only its live grants.)
  #   - NWP-20261112-10 (Q061): THE INSTALL-HEAL RE-CHECKED against the mid-session capture. nowhere-perms is no longer
  #     the login-time copy: since NWP-20261112-07 / NWP-20261112-10 the user-0 gate relays a runtime-permission change
  #     in the live session to PermsCaptureReceiver, which rewrites it. An update's heal is unaffected: its grant phase
  #     is skipped once per session by $STATE/.granted.<uid>, its declines by .declined.<uid>. An on-demand or auto
  #     app's first install is covered only because PermsCaptureRule.keepCarried keeps that app's carried lines
  #     verbatim in a mid-session capture until UnarchiveService.markOdRestored records its restore; the materialise
  #     path and the install-heal both write that record, and only after odrestore -- which runs this function before
  #     it writes its result -- answered OK. So the first install's grant always reads the carried lines.
  #   - Allowlisted: exactly the flag names user-set and user-fixed (pm's set-permission-flags also takes
  #     review-required, revoked-compat, ... which this must never be able to set from a sealed file); the package and
  #     permission must be plain names (no leading dash, no shell metacharacter, cannot be read as a pm option); and
  #     INTERNET is refused because its channel is `deny:` above -- the INTERNET default would otherwise race it.
  #   - ⚠ THE SMS APP KEEPS ITS SMS PERMISSIONS (NWP-20261012-08, Chester 2026-10-12: "yes keep the read_sms
  #     access"; 2026-10-13, which of the six the SMS role grants: "All six"). A decline of any of the six permissions
  #     the SMS role grants -- READ_SMS, RECEIVE_SMS, RECEIVE_MMS, RECEIVE_WAP_PUSH, SEND_SMS, READ_CELL_BROADCASTS,
  #     exactly PermDeclines.SMS_ROLE_PERMS -- is NOT applied here to the two apps that can hold the SMS role once the
  #     chooser's sign-in apply has run: the
  #     app the profile's SMS record names (the chooser's files/nowhere-sms, `app=<pkg>`, read as
  #     SmsRoleRoam.parseSmsRecord reads it) and com.android.messaging, the default and its stand-in. No flags, no
  #     revoke: this pass runs BEFORE the role step and cannot see the role, and a role already
  #     held since the user was created is not added again, so nothing would re-grant what a revoke here took -- the
  #     SMS app could not read a text all session. Every other decline of those two apps is applied as usual. The
  #     chooser then declines the six for whichever of the two did NOT end up holding the role
  #     (PermDeclines.reapplyRoleHolders at sign-in; in session onMaterialised and a takeover, which never revoke a
  #     grant), and its capture keeps the
  #     decline recorded, so it returns the first login the app is no longer the SMS app. Counted as "left to the SMS
  #     role" in the log line. The grant-withhold in the per-line loop is unchanged: a decline line for these never
  #     comes with a grant line, and if one did it is withheld, so this only ever leaves a permission to the role.
  # It only ever WITHHOLDS a grant. On an APK-less placeholder pm finds no package and does nothing; the odrestore
  # call with PKGFILTER applies the line once the tap has installed the real APK (DECLINES=1, see above), as it does
  # for the grants.
  _dmark="$STATE/.declined.$uid"
  if [ -z "$pkgfilter" ]; then
    _dok=1
  elif [ "${3:-}" = 1 ]; then
    if grep -qxF -- "$pkgfilter" "$_dmark" 2>/dev/null; then
      _dok=0                                                  # already applied this session: an update, not a first install
    else
      _dok=1; echo "$pkgfilter" >> "$_dmark" 2>/dev/null      # recorded BEFORE the pass, so a pass that dies is not re-run
    fi
  fi
  [ "$_gnofile" = 1 ] && _dok=0                               # the flags loop below reads "$PF"
  # NWP-20261012-08: the profile's recorded SMS app, read exactly as the chooser's PermDeclines.recordedSmsApp +
  # SmsRoleRoam.parseSmsRecord read it: no record when the file is over 4096 bytes; else its first `app=` line, with
  # every character at or below U+0020 trimmed from both ends (Java's String.trim -- _ws is U+0001..U+0020; a NUL is
  # not mirrored, a shell cannot hold one), and only a package name as SmsRoleRoam.isPackageName has it (dotted,
  # [A-Za-z0-9._], no empty segment, at most 255). The chooser needs no check here: it is never a decline target.
  _smsf="${PF%/*}/nowhere-sms"
  _ws=$(printf ' \001\002\003\004\005\006\007\010\011\012\013\014\015\016\017\020\021\022\023\024\025\026\027\030\031\032\033\034\035\036\037')
  if [ -f "$_smsf" ] && _sz=$(wc -c < "$_smsf" 2>/dev/null) && [ "$((_sz + 0))" -le 4096 ]; then
    while IFS= read -r _sl || [ -n "$_sl" ]; do
      case "$_sl" in app=*) _smsapp="${_sl#app=}"; break;; esac
    done < "$_smsf"
  fi
  while :; do
    case "$_smsapp" in
      ["$_ws"]*) _smsapp="${_smsapp#?}";;
      *["$_ws"]) _smsapp="${_smsapp%?}";;
      *) break;;
    esac
  done
  case "$_smsapp" in *.*) ;; *) _smsapp="";; esac
  case "$_smsapp" in .*|*.|*..*|*[!A-Za-z0-9._]*) _smsapp="";; esac
  [ "${#_smsapp}" -le 255 ] || _smsapp=""
  _gd="$STATE/.grantd"; ( : > "$_gd" ) 2>/dev/null; _gbg=0
  [ "$_dok" = 1 ] && while read -r gpkg gperm; do
    case "$gperm" in flags:*) ;; *) continue;; esac
    [ -n "$pkgfilter" ] && [ "$gpkg" != "$pkgfilter" ] && continue
    _df="${gperm#flags:}"; _dfl="${_df%%:*}"; _dperm="${_df#*:}"
    case "$_dfl" in user-set|user-fixed|user-set,user-fixed) ;; *) _drej=$((_drej + 1)); continue;; esac
    case "$_dperm" in ""|[!A-Za-z]*|*[!A-Za-z0-9._]*|android.permission.INTERNET) _drej=$((_drej + 1)); continue;; esac
    case "$gpkg" in ""|[!A-Za-z]*|*[!A-Za-z0-9._]*|com.nowhere.chooser) _drej=$((_drej + 1)); continue;; esac
    if [ "$gpkg" = com.android.messaging ] || [ "$gpkg" = "$_smsapp" ]; then
      case "$_dperm" in
        android.permission.READ_SMS|android.permission.RECEIVE_SMS|android.permission.RECEIVE_MMS|android.permission.RECEIVE_WAP_PUSH|android.permission.SEND_SMS|android.permission.READ_CELL_BROADCASTS)
          _dsms=$((_dsms + 1)); continue;;
      esac
    fi
    { if [ "$_dfl" = user-set,user-fixed ]; then
        pm set-permission-flags --user "$uid" "$gpkg" "$_dperm" user-set user-fixed </dev/null >/dev/null 2>&1
      else
        pm set-permission-flags --user "$uid" "$gpkg" "$_dperm" "$_dfl" </dev/null >/dev/null 2>&1
      fi && echo x >> "$_gd"
      pm revoke --user "$uid" "$gpkg" "$_dperm" </dev/null >/dev/null 2>&1
    } &
    _gbg=$((_gbg + 1)); [ "$_gbg" -ge 6 ] && { wait; _gbg=0; }
  done < "$PF"
  wait
  _dcl=$(wc -l < "$_gd" 2>/dev/null); _dcl=${_dcl:-0}
  rm -f "$_gd" 2>/dev/null
  if [ "$_gnofile" = 1 ]; then
    echo "[roamd] GRANT ($pkgfilter) -> 0 perms (no file) + $dflt INTERNET default(s) (user $uid) $(date)" >> "$LOG"
    return 0
  fi
  echo "[roamd] GRANT${pkgfilter:+ ($pkgfilter)} -> $n perms + $dflt INTERNET default(s) + $_dcl declined kept ($_drej refused, $_dskip grant(s) withheld, declines $([ "$_dok" = 1 ] && echo on || echo off)) + $_dsms left to the SMS role (user $uid) $(date)" >> "$LOG"
}

# stop_mediad: tear down the on-demand media daemon (#84 P3d). It's an init-tracked service (nowhere_mediad.sh
# execs the agent), so STOP it via init -- `setprop ctl.stop nowhere_mediad` -- which SIGKILLs it and marks the
# oneshot stopped (won't restart). init's stop is not a clean unmount, so the DEAD mounts it left must still be
# swept (a seal's walk would hang on them, and removeUser can't delete through a mountpoint) -- but by MEDIAD,
# re-kicked in sweep-only mode, not by us: see the E.5x note in the body. The overlay's /proc/mounts fstype is
# "fuse.nowheremedia" (go-fuse mounts "fuse."+Name). Both services run in init's (global) mount namespace, so a
# `umount -l` there detaches the app-visible mount. NEVER touch /sys/fs/fuse/connections -- aborting it kills
# Android's own emulated-storage FUSE for the live user (spike).
# $1 = reap, $2 = the reaped uid (NWP-20261129-06): only the cleanstorage op passes them. See reap_live_other.
stop_mediad() {
  local i mnt _dev _rest left a j _mt _mtrc _unread _pre _prerc _n _bound _rlo
  if [ "${1:-}" = reap ] && _rlo=$(reap_live_other "$2") && ! reap_media_mounted "$2"; then
    echo "[roamd] reap of user $2: a live session (user $_rlo) holds the media daemon and no media mount lies in the removed user's dirs -- mediad left running (NWP-20261129-06) $(date)" >> "$LOG"
    return 0
  fi
  setprop ctl.stop nowhere_mediad
  i=0
  while [ $i -lt 30 ] && [ "$(getprop init.svc.nowhere_mediad)" = "running" ]; do i=$((i+1)); sleep 0.1; done
  rm -f "$STATE/mediad.pid" "$STATE/mediad.req"   # never revive from a stale req; .pid is legacy (no longer written)
  # E.5x: we no longer umount here. umount(2) needs CAP_SYS_ADMIN, and on Endospore this worker runs confined as
  # endospore_priv, which deliberately does NOT hold it -- mediad has its own domain (endospore_mediad) precisely
  # so the capability stays with the one service that must mount. Drop the sweep marker and kick mediad, which
  # detaches its own mounts and removes the marker. On FP3/diaspore this worker is su:s0 and could still umount
  # directly, but there is one code path, not two: the kick works identically there.
  # VERIFY, do not assume, and RETRY. A surviving mount is not cosmetic: removeUser cannot delete through a
  # mountpoint and a seal walk HANGS on a dead-daemon mount, so a silently-failed sweep is an amnesia failure,
  # not a log line. Kick, wait for the sweep to end (below), then read the ground truth back out of
  # /proc/mounts. (`wc -l`, not `grep -c`: grep exits 1 on a zero count, so any `|| echo 0` fallback fires too
  # and yields two lines of output.)
  # NWP-20261025-17: and READ the table, do not just count it. The count used to be a grep with its read error
  # discarded: a grep that cannot read /proc/mounts (a sepolicy change that drops this domain's read) exits 2 with
  # nothing on stdout, `wc -l` printed 0, the first attempt broke out of the loop and "media mounts clear" was logged
  # over a table never read -- ahead of cleanstorage, a sign-in's reap and dropcaches, which read nothing back. Each
  # attempt now reads the table ONCE with its status kept; a failed or empty read (no Linux system has an empty
  # mounts table) is UNREAD, never a count of zero: it takes the second attempt as a left mount does, and the
  # verdict says so. The return status is unchanged: sweepmedia and coldsweep do their own verified read.
  # NWP-20261113-03: and wait for the sweep THIS attempt kicked to END before reading the table it judges. The marker
  # wait was a fixed 50 ticks (5 s), and mediad removes the marker only after its last detach, so a longer sweep was
  # read while it was still detaching: on frankel (0.5.48) a 96-mount sweep left 36 at roamd's last read (19:22:53),
  # the sign-out was refused with ERR-MEDIA-SWEEP, and mediad logged "63 detached, 63 already gone, 0 FAILED" at
  # 19:22:57. The bound now grows with the media mounts counted from one read before the first kick (a failed or empty
  # read counts 0, today's bound, and the attempt still judges its own read): 50 ticks plus 5 (0.5 s) per mount,
  # CAPPED at 550 (55 s). It stops early when the marker is gone, and when the marker is still there but init no longer
  # reports the oneshot `running` after a 20-tick (2 s) start grace: mediad died or never started, so waiting longer
  # cannot help. THE CAP IS A BUDGET, not a guess. stop_mediad writes no roam.progress, and every caller but `in`
  # runs it inside a worker op that runWorkerHeld polls for roamStallTicks (core/agent/main.go: 300 x 500 ms = 150 s
  # with no new progress) before it answers ERR-TIMEOUT and marks the lane abandoned. Worst case here: 30 (stop) +
  # 2 x 550 (marker) + 2 x 30 (idle) = 1190 ticks, about 119 s; the reap adds up to 20 s of reap_userdir_settle after
  # it (139 s). Raising the cap past that turns a slow sweep into ERR-TIMEOUT plus an abandoned lane, which is worse
  # than the ERR-MEDIA-SWEEP it replaces. One caller has a tighter clock than the worker's: END-UNSAVED
  # (core/agent/end_unsaved.go) starts its sweepmedia by 45 s and must commit by 70 s, and the chooser waits 90 s. A
  # sweep this bound lets run past that fails safe there: the handler's commit check undoes the local mark and kicks
  # mediad back, nothing is torn down late, and sessionMu holds a LOGOUT off until it has. Its "about 20 s" budget
  # notes predate this bound. The pre-count is `grep -c` with NO fallback, so it prints one number on a zero count
  # too (the `wc -l` rule above is about a fallback that fires on grep's exit 1). Both reads reach grep through a
  # here-document, never as a `printf '%s\n' "$_mt"` argument: the device's mksh has no printf builtin, so the
  # table goes through exec(2), and a table over 128 KB (MAX_ARG_STRLEN) fails with E2BIG, prints nothing and counts
  # 0 -- "media mounts clear" over 5000 live mounts (CI's mksh leg, NWP-20261113-03).
  _n=0
  _pre=$(cat /proc/mounts 2>>"$LOG"); _prerc=$?
  if [ "$_prerc" -eq 0 ] && [ -n "$_pre" ]; then
    _n=$(grep -c -e " fuse.nowheremedia " -e "/.nowhere-media[^/]*/.under/" <<EOF_MT
$_pre
EOF_MT
)
  fi
  case "$_n" in ''|*[!0-9]*) _n=0 ;; esac   # never let a non-number reach [ -lt ]: mksh reads it as 0, silently
  _bound=$((50 + 5 * _n))
  [ "$_bound" -gt 550 ] && _bound=550
  a=0
  _unread=0
  while [ $a -lt 2 ]; do
    a=$((a+1))
    ( : > "$STATE/mediad.sweep" ); chmod 600 "$STATE/mediad.sweep"
    setprop ctl.start nowhere_mediad
    i=0
    while [ "$i" -lt "$_bound" ] && [ -f "$STATE/mediad.sweep" ]; do
      [ "$i" -ge 20 ] && [ "$(getprop init.svc.nowhere_mediad)" != "running" ] && break
      i=$((i+1)); sleep 0.1
    done
    if [ "$i" -gt 50 ]; then
      echo "[roamd] media sweep attempt $a waited $((i / 10)).$((i % 10))s for $_n mount(s) $(date)" >> "$LOG"
    fi
    _mt=$(cat /proc/mounts 2>>"$LOG"); _mtrc=$?
    if [ "$_mtrc" -eq 0 ] && [ -n "$_mt" ]; then
      _unread=0
      left=$(grep -e " fuse.nowheremedia " -e "/.nowhere-media[^/]*/.under/" <<EOF_MT | wc -l
$_mt
EOF_MT
)
      [ "${left:-0}" -eq 0 ] && break
      echo "[roamd] media sweep attempt $a left $left mount(s) $(date)" >> "$LOG"
    else
      _unread=1
      left=0
      echo "[roamd] media sweep attempt $a could not read the mount table $(date)" >> "$LOG"
    fi
    # Wait for the oneshot to go idle before re-kicking, BOUNDED -- an unbounded wait here would wedge the
    # logoff itself and hand the session to the logoff's 6-minute no-progress watchdog (logoffStallLimit,
    # core/agent/logoff_cutoff.go).
    j=0
    while [ $j -lt 30 ] && [ "$(getprop init.svc.nowhere_mediad)" = "running" ]; do j=$((j+1)); sleep 0.1; done
  done
  rm -f "$STATE/mediad.sweep"        # never leave a marker that would make the next start a no-op sweep
  if [ "$_unread" -eq 1 ]; then
    echo "[roamd] ERR-MEDIA-SWEEP: mount table unreadable after $a sweep attempt(s) $(date)" >> "$LOG"
  elif [ "${left:-0}" -gt 0 ]; then
    echo "[roamd] ERR-MEDIA-SWEEP: $left media mount(s) survive $a sweep attempt(s) $(date)" >> "$LOG"
    grep -e " fuse.nowheremedia " -e "/.nowhere-media[^/]*/.under/" /proc/mounts 2>/dev/null | while read -r _dev mnt _rest; do
      print -r -- "[roamd]   still mounted: $(qn "$mnt")" >> "$LOG"
    done
  else
    echo "[roamd] media mounts clear $(date)" >> "$LOG"
  fi
}

# remap_tree DIR: the shared media tree is one ownership domain (media_rw), so re-own the whole restored
# tree to the uid:gid Android gave DIR itself. Used for /data/media/N (photos, downloads, files).
remap_tree() {
  local own
  own=$(stat -c '%u:%g' "$1" 2>/dev/null)
  case "$own" in ''|*[!0-9:]*) return;; esac
  chown -R "$own" "$1" 2>> "$LOG"
}

# reown_ext_appdata PKG: an app's EXTERNAL app-private data (/data/media/N/Android/{data,obb}/PKG) is app-owned
# (appUid:ext_data_rw / appUid:ext_obb_rw) and is reached by the app through the storage PASS-THROUGH, whose access
# is DAC-checked against the file OWNER -- NOT the shared-media media_rw domain. remap_tree just blanket-chowned the
# WHOLE /data/media/N tree to media_rw: correct for DCIM/Pictures/Downloads, WRONG here -- it locks the app out of
# its OWN files, which the app surfaces as a resource failure, not a permission one. Device-proven (DIA-20260730):
# a Unity/il2cpp game (Toon Blast) reads files/il2cpp/unity.ver -> EACCES -> shows "Not enough storage space to
# install required resources" and never starts after a roam (it works on a first install because the app CREATES
# those files itself); `chown -R <appuid>:ext_data_rw` the subtree -> the game boots straight to gameplay (proven
# under Enforcing). So re-own each present PKG subtree back to its app. appId from packages.list (like
# reown_restored); returns 1 (skip) when unresolvable -- an on-demand app before its tap install, which odrestore
# re-runs this for once installApks has landed the stable appId. Idempotent. chown -R DOES traverse mediad's overlay
# submounts (ContentDownload / il2cpp/Metadata), and those files are served app-readable via the FUSE regardless.
# ⚠ THIS COMMENT USED TO SAY "a chown that the FUSE rejects is harmless". THE FUSE DID NOT REJECT IT. Every chown
# of a deferred stub arrived as a SETATTR that mediad answered by MATERIALIZING the file -- a full fetch from the
# store -- to service an ownership change a stub cannot even hold (its owner is synthetic). Since odrestore calls
# this on every on-demand app tap, a tap downloaded the deferred set of the app the on-demand tier exists to keep
# light. Device-proven on lynx 2026-09-08 and fixed in the agent (NWP-20260908-19, mediafs.go Setattr), so the
# traversal is now genuinely harmless -- but it is harmless because of that fix, not because FUSE refuses.
# Uses the global $uid.
reown_ext_appdata() {
  local pkg="$1" appid target
  # Exact on field 1 (NWP-20261111-11): the grep this replaced read $pkg as a regex, so a look-alike name took the data.
  appid=$(NW_PKG="$pkg" awk '$1 == ENVIRON["NW_PKG"] { print $2; exit }' /data/system/packages.list 2>/dev/null)
  case "$appid" in ''|*[!0-9]*) return 1;; esac
  target=$((uid * 100000 + appid))
  [ -d "/data/media/$uid/Android/data/$pkg" ] && chown -R "$target:ext_data_rw" "/data/media/$uid/Android/data/$pkg" 2>> "$LOG"
  [ -d "/data/media/$uid/Android/obb/$pkg" ]  && chown -R "$target:ext_obb_rw"  "/data/media/$uid/Android/obb/$pkg"  2>> "$LOG"
  echo "[roamd] reowned ext app-data $pkg -> $target (user $uid)" >> "$LOG"
  return 0
}

# relabel_launcher UID USERDIR: Launcher3 keys every home/dock item to the user's SERIAL number
# (favorites.profileId). An ephemeral roamed user gets a NEW serial each login, so a restored launcher.db
# carries a STALE serial -> Launcher3 finds no matching profile and DROPS every item == the home-screen
# layout never roams (while app DATA does, since data isn't serial-keyed). Rewrite profileId to THIS user's
# serial (from dumpsys -- the /data/system/users xml is binary ABX, not greppable) so the home survives.
# Run BEFORE remap_per_pkg/restorecon so they re-own + relabel anything sqlite touches.
relabel_launcher() {
  local ldb serial
  ldb="$2/com.android.launcher3/databases/launcher.db"
  [ -f "$ldb" ] || return
  serial=$(dumpsys user 2>/dev/null | grep "UserInfo{$1:" | grep -oE 'serialNo=[0-9]+' | head -1 | cut -d= -f2)
  [ -n "$serial" ] || { echo "[roamd] launcher relabel: no serial for user $1" >> "$LOG"; return; }
  # DIA-20260817-01 (#732): nowhere_db_fix, not sqlite3 -- sqlite3 is USERDEBUG-ONLY, so this relabel (and
  # every other sqlite3 shell-out in this file) silently never ran on a `user` build. Roamed favorites kept
  # the previous session's serial and Launcher3 dropped them. Loud guard, not command -v: silently degrading
  # is exactly how five of these hid for months.
  if [ ! -x /system/bin/nowhere_db_fix ]; then
    echo "[roamd] launcher relabel SKIPPED: /system/bin/nowhere_db_fix missing on this build (user $1)" >> "$LOG"
  elif /system/bin/nowhere_db_fix launcher-relabel "$ldb" "$serial" >> "$LOG" 2>&1; then
    echo "[roamd] relabeled launcher favorites -> serial $serial (user $1)" >> "$LOG"
  else
    echo "[roamd] launcher relabel FAILED (user $1)" >> "$LOG"
  fi
  # #93: widgets don't roam -- appwidget IDs are HOST-allocated per user, so the restored rows point at IDs
  # that don't exist for this fresh user and Launcher3 silently drops them. Mark them RESTORED with the FULL
  # flag set Google's own RestoreDbTask uses (LauncherAppWidgetInfo: FLAG_ID_NOT_VALID=1 |
  # FLAG_PROVIDER_NOT_READY=2 | FLAG_UI_NOT_READY=4 | FLAG_RESTORE_STARTED=8 = 15). restored=1 alone was NOT
  # enough (first attempt, failed on-device 2026-07-04): our install-existing app provisioning races the
  # launcher's first load, and for a pending widget whose provider isn't installed-for-this-user YET,
  # WorkspaceItemProcessor DELETES the row ("Unrestored Pending widget removed") unless RESTORE_STARTED is
  # set -- and that delete persists into the next seal, losing the widget for good. With 15 the row survives
  # as a pending tile; when the provider package lands, Launcher3 clears NOT_READY, allocates a fresh id and
  # binds (the WidgetInflater self-heal). Best-effort, same posture as the relabel above.
  if [ -x /system/bin/nowhere_db_fix ] && /system/bin/nowhere_db_fix launcher-widgets "$ldb" >> "$LOG" 2>&1; then
    echo "[roamd] marked roamed widgets for launcher re-bind (user $1)" >> "$LOG"
  else
    echo "[roamd] widget restore-mark FAILED (user $1)" >> "$LOG"
  fi
}

# remap_media_db UID DIR (NWP-20261124-01): the CE and #de seals carry MediaProvider's own database (external.db)
# with the ABSOLUTE /storage/emulated/<sealing user>/ path of every file, as they carry mmssms.db (#148) and
# launcher.db (relabel_launcher above). After a sign-in as a new user id each row still names the old user: the app
# that took a photo calls it "inaccessible", and the mount-time scan adds a second row for the real path, so every
# media folder and album shows twice (three times after a third session). nowhere_db_fix media-remap drops the later
# duplicates of a file (keeping its first row) and repoints the rest at this user. Called for BOTH the CE and the DE
# dir: MediaProvider is directBootAware, so its database may sit under /data/user_de/<uid>. Run BEFORE
# remap_per_pkg/restorecon, like relabel_launcher, so any -wal/-shm/-journal the rewrite creates as root is re-owned
# and relabelled with the rest. Never fatal: a failed rewrite leaves the database as restored, which is today's state.
remap_media_db() {
  local db out rc nrem ndrop mrest nown ngen
  for db in "$2/com.android.providers.media.module/databases/external.db" \
            "$2/com.google.android.providers.media.module/databases/external.db"; do
    [ -f "$db" ] || continue
    # Loud guard, not command -v (relabel_launcher's rule): a silent no-op is how the sqlite3 repairs hid for months.
    if [ ! -x /system/bin/nowhere_db_fix ]; then
      echo "[roamd] media-remap SKIPPED: /system/bin/nowhere_db_fix missing on this build (user $1) (NWP-20261124-01)" >> "$LOG"
      continue
    fi
    out=$(/system/bin/nowhere_db_fix media-remap "$db" "$1" </dev/null 2>> "$LOG"); rc=$?
    if [ "$rc" = 0 ]; then
      nrem=${out%% *}; mrest=${out#* }; ndrop=${mrest%% *}; mrest=${mrest#* }; nown=${mrest%% *}; ngen=${mrest##* }
      if [ "$ngen" = "-" ]; then ngen="generation unchanged"; else ngen="generation $ngen"; fi
      echo "[roamd] media-remap user $1: $nrem row(s) repointed, $ndrop stale duplicate(s) dropped, $nown row(s) given user $1, $ngen (NWP-20261129-01)" >> "$LOG"
    else
      echo "[roamd] media-remap user $1: FAILED rc=$rc -- left as restored (NWP-20261124-01)" >> "$LOG"
    fi
  done
  return 0
}

# insert_deferred_media UID USERDIR DEDIR (NWP-20261130-02; docs/product-decisions.md, 2026-11-06): on the default tier
# MediaStore never learns that a file not yet downloaded exists, so the Gallery is empty. The #media restore leaves
# $STATE/media.rows (core/agent/media_rows.go), and nowhere_db_fix media-insert writes one row per file straight into
# MediaProvider's database, every column computed there. It runs after the #media restore because the mount scan ran
# before it. The user is already running, so MediaProvider may hold the database open: this is too late for
# remap_per_pkg/restorecon to fix a -wal/-shm/-journal the tool creates as root, so this does. Same four candidate paths
# as remap_media_db's two calls. Never fatal: a failed insert leaves the database as restored. Counts only in the log.
insert_deferred_media() {
  local db out rc ni np ns ng mrest own sf found=no list="$STATE/media.rows"
  if [ ! -s "$list" ]; then
    echo "[roamd] media-insert user $1: no media waiting (NWP-20261130-02)" >> "$LOG"
    return 0
  fi
  # Loud guard, not command -v (relabel_launcher's rule).
  if [ ! -x /system/bin/nowhere_db_fix ]; then
    echo "[roamd] media-insert SKIPPED: /system/bin/nowhere_db_fix missing on this build (user $1) (NWP-20261130-02)" >> "$LOG"
    return 0
  fi
  for db in "$2/com.android.providers.media.module/databases/external.db" \
            "$2/com.google.android.providers.media.module/databases/external.db" \
            "$3/com.android.providers.media.module/databases/external.db" \
            "$3/com.google.android.providers.media.module/databases/external.db"; do
    [ -f "$db" ] || continue
    found=yes
    out=$(/system/bin/nowhere_db_fix media-insert "$db" "$1" "$list" </dev/null 2>> "$LOG"); rc=$?
    if [ "$rc" = 0 ]; then
      ni=${out%% *}; mrest=${out#* }; np=${mrest%% *}; mrest=${mrest#* }; ns=${mrest%% *}; ng=${mrest##* }
      if [ "$ng" = "-" ]; then ng="generation unchanged"; else ng="generation $ng"; fi
      echo "[roamd] media-insert user $1: $ni row(s) for media not yet downloaded, $np already listed, $ns skipped, $ng (NWP-20261130-02)" >> "$LOG"
    else
      echo "[roamd] media-insert user $1: FAILED rc=$rc -- left as restored (NWP-20261130-02)" >> "$LOG"
    fi
    own=$(stat -c '%u:%g' "$db" 2>/dev/null)
    for sf in "$db-wal" "$db-shm" "$db-journal"; do
      [ -e "$sf" ] || continue
      case "$own" in ''|*[!0-9:]*) ;; *) chown "$own" "$sf" 2>> "$LOG" ;; esac
      restorecon "$sf" 2>> "$LOG"
    done
  done
  [ "$found" = yes ] || echo "[roamd] media-insert user $1: no MediaProvider database yet -- rows not written (NWP-20261130-02)" >> "$LOG"
  return 0
}

# seed_home UID USERDIR: give a FRESH profile the edition's default page-2 home apps (E.5d). The AOSP/
# GrapheneOS Launcher3 default-layout importer imports only the DOCK from default_workspace and silently
# drops multi-screen desktop items (LineageOS/Trebuchet on the FP3 imports both, so this no-ops there). So
# after the first login we inject the page-2 apps listed in /system/etc/nowhere/default-home directly into
# the launcher.db workspace, then nudge Launcher3 to reload. Guarded to run ONCE per profile: it seeds only
# when the workspace (container=-100) is EMPTY, and after the first login the seeded rows roam in the sealed
# launcher.db, so every later login has a non-empty workspace and this is skipped -- never clobbering a
# roamed or user-arranged home. Sets SEED_VERDICT on EVERY branch (the op writes it to $RES; NWP-20261015-39, #122):
# OK SEEDED <n> | OK SKIPPED nonempty | OK SKIPPED norows | OK NODESC | ERR-SEED notool|nodb|nodock|rc=<n>.
# Runs in the `grant` op (post-switch, AFTER install-existing), so the apps
# resolve and the launcher.db already exists.
seed_home() {
  local uid="$1" userdir="$2" desc ldb tool out rc i=0 _now _mt _age
  SEED_VERDICT=""
  desc="/system/etc/nowhere/default-home"
  ldb="$userdir/com.android.launcher3/databases/launcher.db"
  tool="/system/bin/nowhere_seed_home"

  # ⚠ THIS USED TO SHELL OUT TO /system/bin/sqlite3, WHICH IS USERDEBUG-ONLY. On every `user` build the
  # binary is absent, all three queries returned empty, and seeding silently never ran -- page 2 was
  # missing on every release device while working on lynx, the one device we build userdebug. Worse, the
  # empty count fell through the "workspace is empty" guard and the empty serial then reported "no serial
  # from launcher.db", blaming the launcher for a build-configuration problem, on devices whose logs
  # cannot be read. Replaced by a purpose-built tool that ships in ALL build types (DIA-20260810-01).
  #
  # EVERY branch below logs a reason. The old code had one that returned in silence, which is precisely
  # the one that fired.
  [ -f "$desc" ] || { echo "[roamd] seed-home: no default-home on this build (user $uid)" >> "$LOG"; SEED_VERDICT="OK NODESC"; return; }
  [ -x "$tool" ] || { echo "[roamd] seed-home: $tool missing (user $uid)" >> "$LOG"; SEED_VERDICT="ERR-SEED notool"; return; }
  while [ ! -f "$ldb" ] && [ "$i" -lt 25 ]; do sleep 1; i=$((i+1)); done   # let the launcher create its DB
  [ -f "$ldb" ] || { echo "[roamd] seed-home: no launcher.db (user $uid)" >> "$LOG"; SEED_VERDICT="ERR-SEED nodb"; return; }

  # NWP-20261129-45: two reads for the page-2 gap, BEFORE the tool runs, because the tool writes launcher.db. roamd
  # cannot see the launcher draw. Launcher3 creates launcher.db and writes its dock when it first loads its home, so the
  # age of its mtime here approximates how long the dock-only home has been up: an inference from Launcher3's loader, not
  # a device measurement (a later launcher write would shorten it). The force-stop and relaunch that bring page 2 come
  # after this and are not timed, so the line gives the gap less the restart. `-` means a read failed or the mtime is ahead.
  _now=$(date +%s 2>/dev/null)
  _mt=$(stat -c %Y "$ldb" 2>/dev/null)
  _age=-
  case "$_now" in ''|*[!0-9]*) ;; *)
    case "$_mt" in ''|*[!0-9]*) ;; *) [ "$_now" -lt "$_mt" ] || _age=$((_now - _mt)) ;; esac ;;
  esac

  # STDERR STRAIGHT TO THE LOG, stdout kept clean for the decision below. Capturing both with 2>&1 put the
  # diagnostic line FIRST whenever the descriptor had a malformed row -- "seed-home: 2 malformed line(s)
  # skipped\nseeded 3" -- so a `seeded*` prefix match silently failed and the launcher was never restarted,
  # leaving page 2 invisible until something else bounced it. Found by actually running the tool.
  out=$("$tool" "$ldb" "$desc" 2>>"$LOG"); rc=$?
  case "$rc" in
    0)
      echo "[roamd] seed-home: $out (user $uid) waited=${i}s db_age=${_age}s (NWP-20261129-45)" >> "$LOG"
      # Only a real insert needs the restart; a skip must not bounce the launcher under the user.
      case "$out" in
        seeded*)
          am force-stop --user "$uid" com.android.launcher3 </dev/null >/dev/null 2>&1   # reload the dock-only cache -> shows page 2
          SEED_VERDICT="OK SEEDED ${out#seeded }" ;;
        skip:*) SEED_VERDICT="OK SKIPPED nonempty" ;;
        *) SEED_VERDICT="OK SKIPPED norows" ;;
      esac
      ;;
    5) echo "[roamd] seed-home: launcher has not imported its dock yet (user $uid)" >> "$LOG"; SEED_VERDICT="ERR-SEED nodock" ;;
    *) echo "[roamd] seed-home: FAILED rc=$rc: $out (user $uid)" >> "$LOG"; SEED_VERDICT="ERR-SEED rc=$rc" ;;
  esac
}

# seed_aurora_installer UID: default a FRESH profile's Aurora Store to the AuroraServices SILENT installer
# (PREFERENCE_INSTALLER_ID=3), so a Play-app install from our store lands with NO per-app system "install this
# app?" dialog (DIA-20260731, Chester's "Option 2"). AuroraServices (bundled /product priv-app holding
# INSTALL_PACKAGES) is auto-permitted as Aurora's install backend -- verified on-device. Amnesia: every roam
# starts a fresh Aurora, so this re-seeds each provision. Writes the pref Aurora reads on its FIRST launch;
# chowns to Aurora's uid and copies the package dir's own SELinux context (`stat -c %C`) onto the prefs file and,
# when this call created it, the shared_prefs dir -- as relabel_restored does (NWP-20261005-03, NWP-20261109-13).
# An entry this daemon creates takes ITS level, bare s0, and `restorecon -R` without -D does not descend into app
# data, so the per-app, per-user categories would be lost on the file that later holds Aurora's AUTH_DATA. Not
# `restorecon -R -D`: it reaches libselinux's pkgdir_selabel_lookup aliasing bug (DIA-20260806-15), patched on
# Endospore only. A dir context other than app_data_file/privapp_data_file at s0 seeds nothing (logged WARN). A
# shared_prefs dir that was already there is Aurora's and keeps its own label. SKIPS if Aurora isn't
# install-existing'd here, or already has a prefs file (never clobber its anonymous-session AUTH_DATA).
# Fail-safe: on any error Aurora just falls back to its default (Session) installer -- the pre-Option-2 behavior,
# no harm.
seed_aurora_installer() {
  local uid="$1" adir spdir xml auid ctx made
  adir="/data/user/$uid/com.aurora.store"
  [ -d "$adir" ] || return
  spdir="$adir/shared_prefs"
  xml="$spdir/com.aurora.store_preferences.xml"
  [ -f "$xml" ] && return
  auid=$(stat -c %u "$adir" 2>/dev/null)
  case "$auid" in ''|*[!0-9]*) return;; esac
  ctx=$(stat -c '%C' "$adir" 2>/dev/null)
  case "$ctx" in
    u:object_r:app_data_file:s0*|u:object_r:privapp_data_file:s0*) ;;
    *) echo "[roamd] WARN seed-aurora: unexpected dir context [${ctx:-none}] -- nothing seeded (NWP-20261109-13)" >> "$LOG"; return;;
  esac
  made=
  [ -d "$spdir" ] || made=1
  mkdir -p "$spdir" 2>>"$LOG" || return
  cat > "$xml" 2>>"$LOG" <<'XMLEOF'
<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<map>
    <int name="PREFERENCE_INSTALLER_ID" value="3" />
</map>
XMLEOF
  chown "$auid:$auid" "$spdir" "$xml" 2>>"$LOG"
  chmod 0771 "$spdir" 2>>"$LOG"; chmod 0660 "$xml" 2>>"$LOG"
  chcon -h "$ctx" "$xml" 2>/dev/null || echo "[roamd] WARN seed-aurora: chcon ${xml##*/} failed (NWP-20261109-13)" >> "$LOG"
  if [ -n "$made" ]; then
    chcon -h "$ctx" "$spdir" 2>/dev/null || echo "[roamd] WARN seed-aurora: chcon ${spdir##*/} failed (NWP-20261109-13)" >> "$LOG"
  fi
  echo "[roamd] seeded Aurora installer=Services (user $uid)" >> "$LOG"
}

# NWP-20261010-06: this session's FLOOR in /data/system/uiderrors.txt -- the file's size at sign-in. The issue
# report shows only lines past it (and only those naming this session's user): /data outlives every session here,
# nothing truncates the file, and uids restart at 10 every boot, so without a floor a renter's report would carry
# the previous renter's destroys under the same uid. TAKEN at the start of `in` and COMMITTED only where `in`
# answers OK: a straggler or refused login must not move the live session's floor (the stash discipline below).
# An empty take (the agent could not stat the file) commits as NO floor, and a stale one is removed, so the
# report says it cannot separate this session's lines rather than reading from an older session's offset. The
# daemon drops the floor wherever a session ends or begins without `in` (forgetUiderrorsFloor, report_issue.go).
uiderrors_floor_take() {
  "$AGENT" uiderrorsfloor 2>>"$LOG"
}
uiderrors_floor_commit() {
  local _f="$STATE/uiderrors.floor"
  case "$1" in
    ''|*[!0-9]*) rm -f "$_f" "$_f.part" 2>>"$LOG"
                 echo "[roamd] uiderrors floor NOT recorded -- the report will not show this session's lines $(date)" >> "$LOG"
                 return 0 ;;
  esac
  # A failed write must not leave the OLDER floor standing: that is the one outcome worse than no floor, because
  # the report would then read an earlier session's offset and call those lines this session's.
  if ! { echo "$1" > "$_f.part" && chmod 600 "$_f.part" && mv -f "$_f.part" "$_f"; } 2>>"$LOG"; then
    rm -f "$_f" "$_f.part" 2>>"$LOG"
    echo "[roamd] uiderrors floor write FAILED -- removed; the report will not show this session's lines $(date)" >> "$LOG"
  fi
}

# (#135 B2 delivery v2: the telephony ingest that lived here is gone. su:s0 could never confirm a
# `content insert` landed -- DIA-56 denies capturing cmd output and the insert exits 0 even when the
# provider drops the row -- so this worker either lost the call-log record (provider not settled) or
# duplicated the SMS (#360's blind retry). The roamed user's OWN chooser now pulls the decrypted rows
# from the daemon (GET-TELINGEST) and inserts them in-user, where a query-back verify + retry is
# possible. See TelIngest.java / the daemon's GET-TELINGEST + ACK-TELINGEST verbs.)

[ -f "$REQ" ] || { echo "ERR-NOREQ" > "$RES" 2>/dev/null; exit 0; }
# NWP-20260917-13: ALL SEVEN LINES FROM ONE OPEN. The daemon publishes the req by temp + rename, so a single
# open sees exactly one request; seven separate `sed -n Np` opens could straddle a rename and mix two of them.
# `read` fails at EOF on a short req, which leaves the remaining variables EMPTY (as sed did); there is no `set -e`.
op=""; name=""; pass=""; uid=""; sesec=""; skind=""; srcunit=""
{ IFS= read -r op; IFS= read -r name; IFS= read -r pass; IFS= read -r uid; IFS= read -r sesec; IFS= read -r skind; IFS= read -r srcunit; } < "$REQ"
# line 5 (E.3b) sesec: se_secret hex for a hardened Endospore identity; empty otherwise
[ -n "$sesec" ] && export NOWHERE_SE_SECRET="$sesec"  # -> agent opens/seals via the `se` keyslot (docs/se-binding.md)
# line 6 (#58) skind: seal kind -- "manual" (Back up now), "logoff", "logoff-pinned" (h49 #13: a sign-out that stopped a Back up now; logoff for every logoff-only step, pinned by the agent), empty (periodic)
# NWP-20260824-05: line 6 is overloaded by OP. For a SEAL it is the seal kind ("manual"/empty); for an "in"
# it is the KEY MODE ("nfcfirst" = do not flip USB, answer NEEDKEY and let the gate wait for a tap; ""/"usb" =
# today's flip-and-hunt). Scoped so an "in" can never export NOWHERE_SEAL_KIND, which the agent compares
# against "manual" to decide whether a snapshot is pinned.
keymode=""
[ "$op" = "in" ] && keymode="$skind"
# NWP-20261125-08: for an "odrestore" line 6 is a RESTORE-ODDATA list's batch token, never a seal kind (the arm reads it).
[ "$op" != "in" ] && [ "$op" != "odrestore" ] && [ -n "$skind" ] && export NOWHERE_SEAL_KIND="$skind"  # -> the seal tags its snapshot manual (pinned) vs automatic
# line 7 (#91 slice 4b) srcunit: SOURCE unit id for a "restore from <device>" login
# Only the "in" op carries a srcunit (the seal is a separate "out" run) -- export it so the restore agent calls
# read the SOURCE unit's CE/DE heads (headKey's NOWHERE_UNIT_SRC override); this device's seal still writes its OWN.
[ "$op" = "in" ] && [ -n "$srcunit" ] && export NOWHERE_UNIT_SRC="$srcunit"
# NWP-20261028-02: the sign-in's restore processes only (the seal is a separate `out` run and never carries it): the
# agent stops retrying a store that has not answered for 15 s. Each restore process (base, #de, #media, #apps) has its
# own window, so a store that dies between two of them can cost each later one 15 s.
[ "$op" = "in" ] && export NOWHERE_STORE_GIVEUP=1
rm -f "$REQ"                           # consume creds immediately -- RAM-only, sub-second window

# ⚠ NWP-20260826-06: THE RO LANE'S ALLOWLIST, and the reason a second concurrent instance of this script is
# safe. It is enforced HERE -- after the req is parsed and consumed, before ANY op-specific work -- so an op
# that does not belong on this lane cannot execute a single line of it.
#
# The bar for membership is deliberately high: the op must touch nothing the RW lane could be mutating at the
# same instant. storagebreakdown qualifies because it is a pure recursive stat of /data/user/N (it needs this
# domain for SELinux READ -- mlstrustedsubject plus system_app_data_file, since per-user app data carries MCS
# categories an s0 subject cannot traverse -- not for any write), takes no passphrase, and never opens the
# store. A seal running concurrently can only make its numbers slightly stale, which they already are.
#
# uiderrors (NWP-20261010-06) qualifies because it reads the tail of ONE framework file,
# /data/system/uiderrors.txt, for an issue report. Only the package manager writes it, so there is nothing of
# the RW lane's to race; it is here because the login daemon's domain cannot read /data/system at all.
#
# alarmrelay (NWP-20261108-02, Q183) qualifies because it runs one `am startservice --user <uid>` of the session's
# own CredentialService and writes only $RES and $LOG, so there is nothing the RW lane could be mutating. It takes
# no passphrase. It moved here so a cold lock taken while an abandoned op still holds the RW lane still relays the
# next alarm.
#
# playrestart (NWP-20261201-10) qualifies because it runs one `am force-stop --user <uid>` of one package, Play
# services, in the session's user, and writes only $RES and $LOG, so there is nothing the RW lane could be mutating. It
# takes no passphrase. It runs when the user taps a health notice's Fix, and it never signs out, stops a user or
# touches data.
# gmsstate (NWP-20261201-01) qualifies because it runs two read-only `dumpsys activity` dumps for an issue report and
# writes only $RES and $LOG, so there is nothing the RW lane could be mutating. It takes no passphrase. It is here
# because the login daemon's domain cannot ask the activity manager for them.
# gmsexits (NWP-20261201-02) qualifies because it runs one `dumpsys activity exit-info` for an issue report, needs only
# the uid, opens no store and writes only $RES and $LOG, so there is nothing the RW lane could be mutating.
# odblock (NWP-20261130-03) qualifies because it runs one to three `pm` commands on ONE package and writes only $RES,
# $LOG and that package's own record ($STATE/odfetch.<uid>/blocked.<pkg>). It takes no passphrase and opens no store.
# It is here because an installed app whose data is still in the store must stop being launchable NOW, and a seal can
# hold the RW lane for minutes (see the odblock arm).
# healthprobe (NWP-20261201-08) qualifies because it reads one `dumpsys activity oom` for the login daemon's health
# checks and writes only $RES and $LOG, so there is nothing the RW lane could be mutating. It takes no passphrase. It
# is here because the login daemon's domain may not run `dumpsys activity`, and a check must not wait behind a seal.
#
# ⚠ A PASSPHRASE ON THIS LANE IS A BUG, not a case to handle: nothing read-only needs one, and accepting one
# would put the RO lane back in the business the pass-file namespacing above exists to keep it out of.
# Neither credential may reach this lane: not the passphrase (line 3) and not the session's chip secret (line 5,
# exported as NOWHERE_SE_SECRET above), which opens a tied profile's vault, #de and #sys exactly as the passphrase
# does (docs/se-binding.md; NWP-20261110-17).
# NWP-20260903-09 (#147): THE CREDENTIAL LANE'S ALLOWLIST -- the same structure as the RO lane's below,
# with the sign flipped on credentials. armcred and rekey qualify because each is a sub-second pair of
# `cmd lock_settings` rungs plus this lane's own done marker: no store I/O, no roamed-tree writes, nothing
# a concurrent RW seal could even observe. They CARRY a credential, which is exactly why the RO lane must
# not take them and the RW lane made them wait: on the RW lane the keyguard arm queued behind whole seals
# (field-measured: a 125s seal hold put armcred 73.7s late inside a cold lock -- NW-600f775808fc), and an
# unarmed session screen is the "logged in, walked away during the restore" window. The bar for adding an
# op here is the RO lane's bar PLUS "needs a credential": anything else belongs on RW.
if [ "$LANE" = "cred" ]; then
  case "$op" in
    armcred|rekey) ;;
    *) echo "ERR-LANE" > "$RES" 2>/dev/null; chmod 600 "$RES" 2>/dev/null
       echo "[roamd] cred-lane REFUSED op=$op (not on the credential-lane allowlist) $(date)" >> "$LOG"
       exit 0 ;;
  esac
fi

if [ "$LANE" = "ro" ]; then
  case "$op" in
    storagebreakdown|sealdelta|uiderrors|alarmrelay|healthprobe|playrestart|gmsexits|gmsstate) ;;
    odblock) ;;
    *) echo "ERR-LANE" > "$RES" 2>/dev/null; chmod 600 "$RES" 2>/dev/null
       echo "[roamd] ro-lane REFUSED op=$op (not on the read-only allowlist) $(date)" >> "$LOG"
       exit 0 ;;
  esac
  if [ -n "$pass" ]; then
    echo "ERR-LANE" > "$RES" 2>/dev/null; chmod 600 "$RES" 2>/dev/null
    echo "[roamd] ro-lane REFUSED op=$op -- a passphrase must never reach this lane $(date)" >> "$LOG"
    exit 0
  fi
  if [ -n "$sesec" ]; then
    echo "ERR-LANE" > "$RES" 2>/dev/null; chmod 600 "$RES" 2>/dev/null
    echo "[roamd] ro-lane REFUSED op=$op -- a chip secret must never reach this lane $(date)" >> "$LOG"
    exit 0
  fi
fi

# DIA-20260812-02 (#106): hand the passphrase to the agent through a FILE, never in argv.
#
# WHY. Every agent call below used to take the passphrase positionally, which put it in /proc/<pid>/cmdline --
# world-readable on Android. `ps -A -o ARGS` therefore printed the logged-in profile's passphrase in clear to
# anything on the device. On this OS that is not one secret among many: the passphrase derives the vault key,
# so it decrypts the sealed profile from the store, forever, from any device. The window was the whole of each
# seal/restore, and for nowhere_mediad -- a daemon that lives as long as the session -- the whole session.
#
# `pw` prints the argument to hand the agent: "@file:<path>" where <path> is a 0600 file on the tmpfs $STATE
# (0700 root, never roams, gone at power-off). The AGENT reads it and unlinks it at startup (resolveArgFiles),
# so it exists for milliseconds; argv carries only a path, which discloses nothing.
#
# `print -r --` is REQUIRED here and the two obvious alternatives are both wrong:
#   - printf is NOT a shell builtin on Android (`type printf` -> /system/bin/printf), so `printf '%s' "$pass"`
#     would exec a process WITH THE PASSPHRASE IN ITS ARGV -- reintroducing the exact leak this closes.
#   - echo IS a builtin but mangles the value: on this shell `echo -n 'a\\b'` emits one backslash, not two, so
#     any passphrase containing a backslash would be written wrong and the profile would not open. Measured on
#     lynx, not assumed. `print -r --` writes the bytes verbatim (+ one newline, which the agent strips).
#
# FALLBACK IS DELIBERATE. If the file cannot be created we log loudly and pass the value positionally anyway:
# a passphrase briefly visible in ps is bad, but a seal that does not happen loses the profile at power-off,
# and that is worse. The WARN line is the signal that it happened -- silence here would be the real bug.
# The sweep is PREFIX-SCOPED to this service. It used to be `rm -f "$STATE"/.pw.*` under the comment "init
# runs us singly" -- true for roamd-vs-roamd (oneshot service, and workerMu serialises every daemon-driven
# op), but FALSE across services: nowhere_mediad is a separate init service sharing this directory, and
# kickMediad takes none of roamd's locks. Either script could therefore delete the OTHER's in-flight file in
# the few ms between mktemp and the child agent's read, and the agent fails hard on a missing pass file -- so
# a stray PREFETCH-ARM could turn a periodic seal into "NOT SEALED, head unchanged". On an amnesiac OS that
# is data loss, caused by the cleanup for a leak fix. Namespacing removes the interference entirely.
# ⚠ NWP-20260826-06: the prefix is now LANE-scoped too. The comment above explains why it is service-scoped;
# a SECOND INSTANCE OF THIS VERY SCRIPT is the same hazard one step closer -- both lanes would sweep
# ".pw.roamd.*" and either could delete the other's in-flight pass file, turning a periodic seal into
# "NOT SEALED, head unchanged". The RO lane never needs a pass at all (the allowlist below sees to that), so
# this is belt-and-braces on top of that.
rm -f "$STATE"/.pw.roamd"${LANE#rw}".* 2>/dev/null
pw() {
  local f
  f=$(mktemp "$STATE/.pw.roamd${LANE#rw}.XXXXXX" 2>/dev/null)  # lane-scoped: must match the sweep above
  if [ -n "$f" ] && print -r -- "$1" > "$f" 2>/dev/null; then
    print -r -- "@file:$f"
    return 0
  fi
  [ -n "$f" ] && rm -f "$f"
  echo "[roamd] WARN cannot stage the passphrase under $STATE -- this agent call passes it in argv, where ps can read it. Proceeding: a lost seal is worse than the exposure. $(date)" >> "$LOG"
  # print -r --, NOT echo. This is the DEGRADED path, and it must still deliver the passphrase byte-exact:
  # echo would collapse a backslash and would eat a leading -n/-e as a flag, so the agent would derive a
  # DIFFERENT key and a push would write a head nobody can open. That is worse than the argv exposure this
  # branch is knowingly accepting -- it would turn "seal without protection" into "seal destroyed", which is
  # the exact outcome the fallback exists to avoid.
  print -r -- "$1"
}

# qn (NWP-20261008-09) renders a profile name as ONE double-quoted log token, `\` and `"` backslash-escaped, so
# log_scrub's escape-aware quoted rule -- and the issue reporter's (report_issue.go) -- removes it whole: spaces,
# quotes and backslashes included. Until this, the IN/OUT/GRANT lines printed $name BARE after the verb, and the
# one-word rule left every word after the first of a multi-word name on the handset; the fido2 lines wrote it RAW
# inside quotes, which a name holding a `"` broke open (docs/backlog.md, LOG (2) and (3)).
# Every line that writes the result uses `print -r --`, NEVER echo: this shell's echo turns `\\` back into `\` and
# `\n` into a newline (measured on lynx 2026-10-08), which would undo the escaping exactly where it matters.
qn() {
  print -rn -- "\"$(print -r -- "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')\""
}

# group-materialize (DIA-20260802): the sandboxed-Play group's account-bearing member (Play Services) is
# launcher-less, so under the on-demand group tier it is NOT installed at the login `grant` op. Its #sys account
# reload must then DEFER from grant to the member's tap-time `odrestore` (when its APK + authenticator finally
# install). Env-overridable for a non-GMS account-bearing group. Consumed by the grant + odrestore ops below.
ACCT_AUTH_PKG="${NOWHERE_ACCT_AUTH_PKG:-com.google.android.gms}"

# DIA-20260811-08: the sandboxed-Play STOREFRONT (Finsky). Distinct from ACCT_AUTH_PKG above: gms holds the
# account and the checkin identity, vending is the app that CACHES the result and shows the user "Try again"
# when it started before either existed. Only the grant path needs it (see the checkin kick + restart there);
# the odrestore path force-stops the member it is restoring anyway. Same env-override shape as ACCT_AUTH_PKG.
PLAY_STORE_PKG="${NOWHERE_PLAY_STORE_PKG:-com.android.vending}"

# #210 p2 (Bug A fix, DIA-20260729): keystore2 dumps kept keys at removeUser -- AFTER the `out` seal -- so the
# ONLY roamd step that sees the dump is the chooser's `cleanstorage` op, which is CREDLESS. Credless, keystore_push
# DEFERS; and the roam-in retry runs BEFORE keystore_restore so it never holds a #72 receipt -> it can never seal
# over a non-empty name#keys head. Net: a REUSED profile forever carries a STALE key (data<->key mismatch ->
# VERIFICATION_FAILED). Fix: stash THIS session's creds from the credentialed `out` seal so cleanstorage's
# keystore_push seals the CURRENT session's dump (matching key+data; its own login restore-receipt is still live).
# Only when a kept app exists (keep-uids non-empty) -- superseded by NWP-20260830-03: on every `out`, see below;
# tmpfs + root-only (umask 077); cleared at use and every login.
# (Superseded by NWP-20261108-01: the `in` arm no longer calls keystore_push, so no roam-in retry runs before keystore_restore.)
# Production TODO: a keystore2 "dump-now" verb driven at `out` would seal on the credentialed path with NO stash.
KS_CREDS="$STATE/ks-logoff-creds"
[ "$op" = "in" ] && rm -f "$KS_CREDS" 2>/dev/null   # never let a stale stash survive a login boundary
# DIA-20260818-16 (#737 follow-up): gate on the user's INTENT (the opt-in list), not on nowhere-keep-uids.
# (Superseded by NWP-20260830-03 with the rest of this note to the line before `if`: no opt-in list exists.)
# KS_KEEP is DERIVED state, and it is populated by keystore_register_all -- which runs LATER in this same `out`
# op, inside appcode_seal. So on a short session (login, logoff, no periodic round between) the order was:
#   1. `out` starts, KS_KEEP still empty      -> no stash written
#   2. the sweep runs, KS_KEEP now non-empty
#   3. keystore2 dumps at remove_user         -> a dump EXISTS
#   4. cleanstorage finds no stash            -> keystore_push defers -> the reap DESTROYS the dump
# i.e. #737's fix turned "no dump at all" into "dump produced, then thrown away", and only a session long
# enough for a periodic round to register first would hide it (which is exactly why the 2026-08-18 test passed).
# The keep-set is written by "Your apps" and is present from the moment the user opts in, so it does not depend
# on anything this op has yet to do. Slightly wider than before -- a profile that opted in but whose apps are
# all gone now stashes needlessly -- and that is the cheap side: the stash is tmpfs, root-only (umask 077),
# consumed at use and cleared at every login, whereas the other side loses carried sign-ins for good.
# ⚠ the keep-set path is written out LITERALLY, not via $USERDIR: that is assigned after
# the ERR-ARGS and ERR-UID guards (USERDIR="/data/user/$uid"), far below this
# line, so using it here would silently expand to empty and this whole condition would never fire -- the same
# definition-order trap the "#210 p2 (Bug A fix)" note below exists for. $uid is
# set where the REQ lines are read (IFS= read -r uid), above us.
# NWP-20260830-03: UNCONDITIONAL for an `out`. The old condition asked "did anyone opt in", and with the
# opt-in gone there is no such question -- every logoff may now produce a dump to seal, so the creds this
# needs must always be stashed. (Cheap side, as before: tmpfs, root-only, consumed at use, cleared each login.)
if [ "$op" = "out" ] && [ -n "$name" ] && [ -n "$pass" ]; then
  # DIA-20260812-02 (#106): `print -r --`, NOT printf. printf is an external binary on Android, so the old
  # `printf '%s\n%s\n' "$name" "$pass"` handed the passphrase to a process's ARGV -- the very leak this change
  # exists to close, in the one line that was supposed to be writing the secret away safely. -r also stops the
  # value being escape-mangled on the way in, which would have made the stashed creds silently wrong.
  # NWP-20260917-25: line 3 is the UID this stash belongs to. Without it the stash names a profile and
  # nothing else, while cleanstorage is handed a uid -- so the two could not be checked against each
  # other, and the push below took its name AND passphrase entirely from the stash.
  # NWP-20261007-12: line 4 is the session's secure-element secret (REQ line 5; empty when there is none). A tie re-keys
  # #keys to the chip, so its push at cleanstorage opens the head through `se` or not at all -- without it the dump
  # is destroyed and every app signs out after every session. Same lifetime as the passphrase beside it (Chester,
  # 2026-10-07, docs/product-decisions.md): root-only tmpfs, consumed at use, dropped at a cold lock.
  ( umask 077; { print -r -- "$name"; print -r -- "$pass"; print -r -- "$uid"; print -r -- "$sesec"; } > "$KS_CREDS" ) 2>/dev/null
fi

# #210 p2 (Bug A fix): keystore_push and the KS_* paths are defined HERE, ahead of the early op-dispatch, because
# the credless `cleanstorage` handler (below, before the name-required arg guard) calls keystore_push. When it was
# defined further down (past the dispatch) it was an UNDEFINED command at cleanstorage -> a silent no-op -> the
# #keys seal never ran at logoff, so every REUSED profile carried a stale key (data<->key mismatch, app signs out).
# keystore_unit/register/restore (defined later) reference these same paths at their roam-in call sites.
KS_KEEP=/data/misc/keystore/nowhere-keep-uids   # RETIRED (NWP-20260830-03): never written now; kept only so
                                                # the reap-time prune below still removes any file left over
                                                # from a pre-NWP-20260830-03 boot of this device.
KS_MAP=/data/nowhere/keystore-map               # our sidecar: "<ns> <pkg>", so a dump can be named by package
KS_EXPORT=/data/misc/keystore/nowhere-export    # keystore2 writes <ns>.keys here at reap
KS_CENSUS=/data/misc/keystore/nowhere-ns-keys  # NWP-20260826-11: ns that hold keys (keystore2 writes)
                                                # NWP-20261015-32: nothing serves it now, but keystore2 still
                                                # writes it until its half is retired, so the reap prune stays.
KS_IMPORT=/data/misc/keystore/nowhere-import    # keystore2 reads <ns>.keys here on a lookup miss
KS_IN=/data/nowhere/keystore-in                 # restored bundles, named <pkg>.keys until a uid exists
                                                # (superseded by NWP-20261112-01: <uid>/<pkg>.keys, one dir per user -- ks_in_dir)
KS_UNIT=/data/misc/keystore/nowhere-unit-id     # keystore2-READABLE copy of the unit id (see keystore_unit)
KS_DROP=/data/nowhere/keystore-drop             # NWP-20261102-04: "# <uid>" + the apps this session switched off (see ks_stage_drop)
# DIA-20260803: a bundle is valid ONLY for the login that staged it -- drop any leftovers at the login boundary.
# keystore_restore clears KS_IN, but nothing ever cleared KS_IMPORT: a bundle staged at odrestore for an app that
# then performs no keystore op that session (a group dep materialised but never launched, a logoff right after the
# tap) survives here indefinitely -- this is /data/misc, so it outlives the amnesiac wipe and reboot. BOTH halves
# of the namespace it is keyed by (uid*100000 + appId) are recycled across roams, so a later, unrelated package
# can be assigned that exact ns and consume a bundle that was never meant for it. That was survivable while the
# import only filled an EMPTY namespace; now that it unreferences a shadowing alias to make the carry
# authoritative, a stale bundle could displace an app's LIVE key. Scope them to one login.
# (Superseded by NWP-20261108-01: the login-boundary clear that stood here, at the top of every `in`, is gone -- a refused
# sign-in deleted a live session's staged bundles. ks_signin_reset clears KS_IMPORT at the landing instead.)
# (Superseded by NWP-20261112-01: "keystore_restore clears KS_IN" -- it clears only keystore-in/<uid>, its own user's.)
[ "$op" = "in" ] && rm -f "$STATE"/.armcred.* 2>/dev/null   # DIA-20260813-09: a new session must re-arm before ARM-PIN may claim PINSET
# DIA-20260812-11 (#115): _cause is defined HERE, above the early op-dispatch, for exactly the reason the
# keystore_push note below records -- DIA-20260812-10 introduced it inside the `out)` arm of the main dispatch,
# which is HUNDREDS OF LINES BELOW the credless `cleanstorage` handler and therefore an UNDEFINED COMMAND
# there: exit 127, empty output, no error. cleanstorage now needs it, so it moves above every dispatch. This
# file already records that trap biting keystore_push once (see the "#210 p2 (Bug A
# fix)" note above the KS_* paths); a second instance would have shipped
# a verdict that read `PARTIAL:keys=` with an empty cause while the diff looked correct.
# Maps an exit code to the ONE vocabulary shared by both layers -- the agent's exit codes and roamd's own guards.
_cause() {
  case "$1" in
    0)   echo ok ;;
    3)   echo nocredit ;;   # exitNoCredit
    4)   echo refused ;;    # exitSealRefused (#657), and roamd's own seal guards (#118)
    # NWP-20261014-67: 5 is the AGENT's exitStoreUnreachable (NWP-20261006-21): the push could not reach the
    # store, so nothing was stored. It used to read `pending-placement` here, because acct_seal's own wait
    # (below) also returned 5 -- and the daemon drops that token as benign (benignSealParts), so a #sys or #apps
    # push that lost the network counted as SAVED and the cold-lock re-check wiped a session that was not.
    5)   echo unreachable ;; # exitStoreUnreachable
    # DIA-20260816-16 (#63): a SELF-RESOLVING wait, not a refusal. acct_seal declines while a restored account
    # is still pending placement -- the correct thing to do, and it clears itself the moment acct_reload runs.
    # It shared code 4 with the guard refusals, so `sys=refused` read identically to "a guard caught a
    # collapsing manifest" and inflated every count of how much of the safety net was failing. Measured on
    # lynx: 52 sys=refused entries, and placement demonstrably DID run (17 "accounts placed ... + reloaded"
    # lines) -- so essentially all of them were this benign window, counted as failures.
    # NWP-20261014-67: its code is 6, not 5 -- a code no agent path exits with (the agent exits 0-5 and 7, `timeout`
    # 124, its -k kill 137, the shell 126/127), so the agent's codes and roamd's own can no longer collide.
    6)   echo pending-placement ;;
    7)   echo stopped ;;    # exitSealStopped (h47 #1, NWP-20261117-01): a stop was requested, no head was published
    124) echo timeout ;;    # `timeout` killed it -- the gen never committed
    *)   echo failed ;;
  esac
}

# keystore_push: seal whatever keystore2 dumped at SuperKeyManager::remove_user. Named by PACKAGE via KS_MAP,
# since the next login's uid differs and only the package is stable across a roam.
#
# DIA-20260812-11 (#115): the RETURN VALUE IS NOT A SEAL VERDICT and must not be used as one. Five distinct
# paths return 0 and only ONE of them sealed anything -- no export dir, no dump landed, credless defer, nothing
# fresh, and a genuine success all answer 0. BootReceiver's reap after a battery death always has an empty
# state dir, so it always takes a nothing-to-seal path; reporting `keys=ok` there would certify as sealed
# exactly the case #115 exists to expose. Callers that need a verdict read $KS_VERDICT below, which is
# three-valued: sealed | nothing | notsealed.
KS_VERDICT=nothing
# ks_in_dir (NWP-20261112-01): the keystore-in dir of THIS op's user, "$KS_IN/<uid>". A restored bundle belongs to the
# Android user it was restored for, and only that user's promotions (keystore_register*) and seals (keystore_push) see
# it: when keystore-in was one flat dir, a sign-in that landed in roamd and then failed over a cold-locked user 10
# replaced user 10's unopened-app bundles with the arriving profile's, and user 10's next `out` promoted those into
# its apps and sealed them into its #keys (the whole scope, so its own were destroyed in the store).
# Prints nothing and returns 1 when $uid is empty or not all digits.
ks_in_dir() {
  local _u="$uid"
  case "$_u" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$KS_IN/$_u"
}
# ks_ns_mine FILE (NWP-20261114-08): 0 only when FILE's basename, less `.keys`, is exactly this op's uid followed by five
# digits -- the namespace uid*100000 + appId of an app of THIS user, the shape the reap's KS_MAP prune already reads.
# KS_IMPORT and KS_EXPORT are flat dirs holding every Android user's <ns>.keys; another user's file, any other name, and
# an empty or non-numeric $uid answer 1. A case pattern, never a regex.
ks_ns_mine() {
  local _mu="$uid" _n
  case "$_mu" in ''|*[!0-9]*) return 1 ;; esac
  _n=$(basename "$1" .keys)
  case "$_n" in "$_mu"[0-9][0-9][0-9][0-9][0-9]) return 0 ;; esac
  return 1
}
# ks_prog <word> (NWP-20261116-10): one progress line for the RW worker's stall clock, in cutoff_prog's form (a NEW line
# each call, counter included, through $NOWHERE_PROGRESS.tmp + mv -f; a no-op when NOWHERE_PROGRESS is unset). It is
# defined here and is not cutoff_prog: cutoff_prog is defined below the early op dispatch, so the reap's keystore_push
# cannot see it (the forward-reference trap). KS_PROG_TICK is the one global: the counter has to outlive the call.
ks_prog() {
  local _pf="${NOWHERE_PROGRESS:-}" _pw="$1"
  [ -n "$_pf" ] || return 0
  KS_PROG_TICK=$(( ${KS_PROG_TICK:-0} + 1 ))
  echo "keys $_pw $KS_PROG_TICK" > "$_pf.tmp" 2>/dev/null && mv -f "$_pf.tmp" "$_pf" 2>/dev/null
  return 0
}
keystore_push() {
  KS_VERDICT=nothing   # #115: reset per call -- a stale verdict from a previous op would be read as this one's
  KS_STAGE_VERDICT=""   # NWP-20261124-13: the reap's staging verdict, set only where it differs from KS_VERDICT (see ks_reap_clear)
  _kin=$(ks_in_dir) || _kin=""   # NWP-20261112-01: only this user's restored bundles
  # NWP-20261114-08: a reap stages, waits for and removes only ITS uid's <uid><5 digits>.keys (ks_ns_mine) in
  # KS_IMPORT and KS_EXPORT; another user's bundles stay for that user's own reap. _kim / _kxm: this uid has an
  # import / a dump.
  _kim=0; for f in "$KS_IMPORT"/*.keys; do [ -e "$f" ] && ks_ns_mine "$f" && { _kim=1; break; }; done
  # NWP-20260827-04: the dir-exists guard has the SAME blind spot as the one below -- a profile with
  # carried bundles but no export dir still has removals to honour. Cheap to include rather than leave a
  # second copy of the bug I just fixed; the ls calls below tolerate a missing dir on their own.
  [ -d "$KS_EXPORT" ] || { [ -n "$_kin" ] && ls "$_kin"/*.keys >/dev/null 2>&1; } || [ "$_kim" = 1 ] || return 0
  # keystore2 dumps at remove_user, which lands a beat AFTER the chooser's async cleanstorage (removeUser returns
  # ok=false, the dump lands seconds later). Only the cleanstorage caller passes "wait"; the roam-in retry passes
  # nothing, so it never blocks the login waiting on a dump that isn't coming. Bounded (<=30s), off the wipe path.
  # (Superseded by NWP-20261108-01: the roam-in retry is gone; cleanstorage is the only caller.)
  # NWP-20260830-03: the `[ -s "$KS_KEEP" ]` arm is gone with the opt-in. KS_KEEP is no longer written at all,
  # so keeping it here would make this wait dead code and we would stop waiting for dumps that ARE coming.
  _kxm=0; for f in "$KS_EXPORT"/*.keys; do [ -e "$f" ] && ks_ns_mine "$f" && { _kxm=1; break; }; done
  if [ "$1" = wait ] && [ "$_kxm" = 0 ]; then
    _w=0; while [ "$_w" -lt 150 ]; do
      for f in "$KS_EXPORT"/*.keys; do [ -e "$f" ] && ks_ns_mine "$f" && { _kxm=1; break; }; done
      [ "$_kxm" = 1 ] && break; sleep 0.2; _w=$((_w + 1))
    done
  fi
  # ⚠ NWP-20260827-04: A DROP IS ALSO A REASON TO RUN, and this guard did not know that.
  #
  # It reads "keystore2 dumped nothing, so there is nothing to seal" -- true for ADDS, false for REMOVALS.
  # The drop filter below is the ONLY thing that can make this scope SHRINK, and it sits after this line, so
  # a profile with no fresh dump could never stop carrying a bundle no matter what the user did.
  #
  # ⚠ THIS IS THE SECOND OF TWO "nothing fresh" EARLY-OUTS, and NWP-20260826-15 fixed only the other one
  # (`_kn = 0 && _kdrop = 0`, further down). That made the -15 drop filter UNREACHABLE rather than fixed:
  # this line short-circuits above it. Device-proven on lynx 2026-08-27 -- a full logoff with the staged
  # opt-in list correctly written (`# 10`, 11 packages, tesla absent) and all 9 bundles present still logged
  # `cleanstorage user 10 class=clean keys=nothing`, because keystore2 exported nothing and we returned here.
  # If you add a third reason to run, put it here too.
  #
  # NWP-20261102-05 (Q049): THE THIRD REASON IS THE DROP LIST. $KS_DROP is what `out` staged (ks_stage_drop) from
  # the chooser's drop list: the apps this session switched off, stopped carrying or inferred orphaned. Read it
  # once, here, so both this early-out and the filter below see the same answer.
  # ⚠ UID-STAMPED AND FAILS SAFE: the list counts only when it is readable AND its first line is exactly
  # `# <uid of this op>`. Absent, unreadable, header-only, another uid's header -> nothing is filtered (an
  # unreadable list is not "everything is off"). With NO uid in scope (`$uid` empty) nothing can match, so
  # nothing is filtered. Counts only below: a package name never reaches the log (the roster rule).
  _kdl=""; _kdn=0
  if [ -n "$uid" ] && [ -r "$KS_DROP" ] && [ "$(sed -n 1p "$KS_DROP" 2>/dev/null)" = "# $uid" ]; then
    _kdl=$(sed 1d "$KS_DROP" 2>/dev/null)
    [ -n "$_kdl" ] && _kdn=1
  fi
  if [ "$_kxm" = 0 ]; then
    # Nothing fresh: only a drop list of this uid, with a carried bundle it could remove, is worth going on for.
    [ "$_kdn" = 1 ] || return 0
    _kim=0; for f in "$KS_IMPORT"/*.keys; do [ -e "$f" ] && ks_ns_mine "$f" && { _kim=1; break; }; done
    { [ -n "$_kin" ] && ls "$_kin"/*.keys >/dev/null 2>&1; } || [ "$_kim" = 1 ] || return 0
  fi
  if [ -z "$name" ] || [ -z "$pass" ]; then
    # No creds on this op: leave the dump; the LOGOFF cleanstorage (with the stashed creds) seals it.
    # #115: this IS a not-sealed state -- a dump EXISTS and we could not store it. Distinct from "nothing here".
    KS_VERDICT=notsealed
    echo "[roamd] keystore_push deferred (no creds on this op) $(date)" >> "$LOG"; return 0
  fi
  # h46 #2 (1), NWP-20261116-08: every #keys push stages on the state tmpfs (RAM), so keystore2's own nowhere-export
  # file is the only dump copy on /data. A push killed mid-way, or a power loss, leaves no staged copy on f2fs.
  KSTAGE="$STATE/keystore-stage"
  rm -rf "$KSTAGE"; mkdir -p "$KSTAGE" 2>>"$LOG" || { KS_VERDICT=notsealed; return 1; }
  _kn=0; _kc=0; _knomap=0; _knomapi=0
  _kskip=0
  # MERGE, NEVER REPLACE. `agent push <name>#keys $KSTAGE` seals the DIRECTORY as the whole scope, so anything
  # missing from $KSTAGE is DESTROYED in the store. This used to be seeded from $KS_EXPORT alone -- i.e. only the
  # apps keystore2 dumped THIS session, which is only the apps actually OPENED (the dump is driven by
  # keystore_register at odrestore/tap).
  #
  # So a session where you used Play Store but not Amazon re-sealed #keys with vending's bundle ALONE and threw
  # Amazon's carried keys away for good: the next launch found nothing to import, MAP minted fresh keys and asked
  # for a password. Measured on lynx -- `#keys sealed (1 pkg)` -> `restored (1 bundle(s))` -> Amazon's ns holding
  # exactly the 2 fresh MAP aliases instead of the 3-key carried bundle. "Keep me signed in" broke the first time
  # you skipped a session, and broke IRREVERSIBLY.
  #
  # Carry forward everything of THIS uid still in flight (NWP-20261114-08: ks_ns_mine skips another user's KS_IMPORT
  # and KS_EXPORT files), weakest first so a fresher copy overwrites it:
  #   1. $KS_IN     restored this session, app never materialised (keystore_register mv's it out when it does)
  #   2. $KS_IMPORT staged for an app that DID materialise but whose bundle keystore2 never consumed
  #   3. $KS_EXPORT this session's fresh dump -- always wins
  _kcf=0   # NWP-20261119-06: bundles that did not land in $KSTAGE byte for byte (see the refusal below the loops)
  for f in "$_kin"/*.keys; do
    [ -n "$_kin" ] && [ -e "$f" ] || continue
    _kd="$KSTAGE/$(basename "$f")"
    if cp "$f" "$_kd" 2>>"$LOG" && cmp -s "$f" "$_kd"; then _kc=$((_kc + 1)); else rm -f "$_kd" 2>/dev/null; _kcf=$((_kcf + 1)); fi
  done
  # NWP-20261114-08: only this uid's <uid><5 digits>.keys are staged; another user's are skipped before the KS_MAP lookup.
  for f in "$KS_IMPORT"/*.keys; do
    [ -e "$f" ] || continue
    ks_ns_mine "$f" || { _kskip=$((_kskip + 1)); continue; }
    _ns=$(basename "$f" .keys)
    _pkg=$(grep -m1 "^$_ns " "$KS_MAP" 2>/dev/null | cut -d' ' -f2)
    [ -n "$_pkg" ] || { _kmev='(map absent)'; [ ! -e "$KS_MAP" ] || _kmev=$(awk -v n="$_ns" '{ t++ } ($1 "") == (n "") { r++; if (NF > 1) k++ } END { printf "(map rows=%d ns_rows=%d named=%d)", t, r, k }' "$KS_MAP" 2>/dev/null) || _kmev='(map unreadable)'; echo "[roamd] keystore_push: staged import ns $_ns has no package mapping, dropped $_kmev $(date)" >> "$LOG"; _knomap=$((_knomap + 1)); _knomapi=$((_knomapi + 1)); continue; }
    if cp "$f" "$KSTAGE/$_pkg.keys" 2>>"$LOG" && cmp -s "$f" "$KSTAGE/$_pkg.keys"; then _kc=$((_kc + 1)); else rm -f "$KSTAGE/$_pkg.keys" 2>/dev/null; _kcf=$((_kcf + 1)); fi
  done
  for f in "$KS_EXPORT"/*.keys; do
    # NWP-20260827-07: the ONE loop of four here that was missing this. With an empty export dir the glob
    # stays literal, `basename "*" .keys` is `*`, and the mapping lookup below then logs
    #   keystore_push: ns * has no package mapping, dropped
    # on EVERY logoff. Functionally harmless -- it continues before the copy -- but it reads as data loss in
    # the one log we open to diagnose keystore problems, and a scary false line there costs real time. Its
    # three siblings (KS_IN, KS_IMPORT, and the drop filter) all guard; this one did not.
    [ -e "$f" ] || continue
    ks_ns_mine "$f" || { _kskip=$((_kskip + 1)); continue; }
    _ns=$(basename "$f" .keys)
    _pkg=$(grep -m1 "^$_ns " "$KS_MAP" 2>/dev/null | cut -d' ' -f2)
    [ -n "$_pkg" ] || { _kmev='(map absent)'; [ ! -e "$KS_MAP" ] || _kmev=$(awk -v n="$_ns" '{ t++ } ($1 "") == (n "") { r++; if (NF > 1) k++ } END { printf "(map rows=%d ns_rows=%d named=%d)", t, r, k }' "$KS_MAP" 2>/dev/null) || _kmev='(map unreadable)'; echo "[roamd] keystore_push: ns $_ns has no package mapping, dropped $_kmev $(date)" >> "$LOG"; _knomap=$((_knomap + 1)); continue; }
    if cp "$f" "$KSTAGE/$_pkg.keys" 2>>"$LOG" && cmp -s "$f" "$KSTAGE/$_pkg.keys"; then _kn=$((_kn + 1)); else rm -f "$KSTAGE/$_pkg.keys" 2>/dev/null; _kcf=$((_kcf + 1)); fi
  done
  # NWP-20261119-06: A STAGE THAT IS NOT WHOLE IS NEVER PUSHED. The push seals $KSTAGE as the WHOLE #keys scope (the
  # MERGE note above). So a bundle whose copy failed is DESTROYED in the store, and a short copy is sealed corrupt
  # (cp can exit 0 on a cut read). Each copy above counts only when cmp finds it identical to its source. Otherwise
  # the loop removes the partial file and counts it in _kcf. Then nothing is pushed and the stored head stays. There
  # is no retry: a read that failed fails again from the same source. No dump is removed here: the cleanstorage caller
  # decides what notsealed does to them. The log gets a count only (the roster rule): no package, ns or uid.
  if [ "$_kcf" != 0 ]; then
    echo "[roamd] keystore_push: $_kcf bundle(s) could not be staged whole -- #keys NOT pushed, the stored head is kept (NWP-20261119-06) $(date)" >> "$LOG"
    rm -rf "$KSTAGE"
    KS_VERDICT=notsealed
    return 1
  fi
  # Count only: no ns, package or uid of another user reaches the log.
  [ "$_kskip" = 0 ] || echo "[roamd] keystore_push: $_kskip bundle(s) not named for this user left in place (NWP-20261114-08) $(date)" >> "$LOG"
  # NWP-20260826-08 (d): STOP CARRYING THE KEYS OF AN APP THE USER TURNED OFF.
  # (Superseded by NWP-20260830-03, which removed the OPT-IN list and this filter; the filter is BACK since
  # NWP-20261102-05 (Q049) as a DROP list -- the apps this session switched off -- never as an opt-in/keep list.
  # The opt-in wording from here to the next note describes the removed form; the FAILS SAFE and uid-stamp
  # reasoning is true again of $KS_DROP and is applied at the top of this function.)
  #
  # The drop list covers the app's DATA (dropPkgForRel). It has never covered this scope, so a switched-off
  # app's <pkg>.keys bundle kept being carried forward by the merge above -- from KS_IN/KS_IMPORT, which are
  # exactly the "still in flight" sources -- and re-sealed every session, forever. The bytes are kilobytes and
  # not the point: this is DEVICE-BOUND IDENTITY MATERIAL, so the user switched an app off and its sign-in kept
  # roaming anyway. That is the same promise "Off" already failed to keep for data (DIA-20260804-04), one scope
  # over.
  #
  # The opt-in list is the right authority rather than the drop list: this carry is opt-in by construction
  # ("nothing is captured unless the chooser lists the package"), so a bundle whose package is no longer listed
  # has no mandate to exist -- however it left, whether by an Off in Your apps, the Storage chip, or the
  # keep-set prune when the app was uninstalled from Settings.
  #
  # ⚠ FAILS SAFE, DELIBERATELY. An unreadable list is NOT "nothing is opted in" -- it is far more likely that
  # this uid's data dir is already gone (this runs on cleanstorage, next to the reap). Filtering on that
  # reading would destroy EVERY carried bundle in the store, which is the irreversible direction. So we filter
  # only when the file is readable, and otherwise carry exactly what we carry today.
  # ⚠ NWP-20260826-15: READ THE STAGED DE-SIDE LIST, NOT THE CE ONE. The CE copy under /data/user/$uid is
  # already gone by the time this runs (cleanstorage, next to the reap), so the -08 form of this filter could
  # never execute: `[ -r ]` was false on every logoff, _kdrop stayed 0, and with _kn=0 the whole function
  # early-returned and left the head untouched. Device-proven -- a removed app's bundle survived 15+ roams and
  # `no longer opted in` had never once been logged. keystore_register_all stages $KS_OPTIN while the user is
  # still alive; see the comment there.
  #
  # The CE path stays as a fallback for a mid-session seal, where it IS readable and is the freshest truth.
  # NWP-20260830-03: THE OPT-IN FILTER IS GONE, with the switch that fed it. Everything keystore2 dumped is
  # sealed.
  #
  # ⚠ CONSEQUENCE (SUPERSEDED IN PART by NWP-20261102-05, Q049): this filter was the ONLY thing that could make
  # the #keys scope SHRINK (NWP-20260826-08). The scope is a MERGE, never a replace, so with no opt-out a bundle
  # once carried was carried forever. That is no longer true for an app switched Off, one the user chose to
  # `Stop carrying`, or an inferred orphan: the drop filter below removes its bundle at the sign-out that drops
  # its data, or at the next one whose dump lands. ~~It IS still true for an app uninstalled from Settings: the
  # drop list does not name it (captureAppDrops has no source for it), so its bundle is carried as before --
  # "still installed" cannot be asked at push time, since the user is already being reaped. Open in the
  # backlog; not built here.~~ (superseded by NWP-20261109-20: an app the user uninstalled from Settings or a
  # launcher IS named when captureAppCode's keep-set prune sees it go -- seen this session or watched leaving,
  # and unknown to PackageManager. The prune records it in nowhere-appoff.list through recordTurnedOff, and
  # captureAppDrops, which runs right after it at sign-out, lists it, so its bundle leaves with its data like an
  # Off's. An uninstall the prune cannot see keeps its keep line, so the app is still part of the profile and its
  # keys roam with it, by the same rule.)
  #
  # NWP-20261102-05 (Q049): THE DROP FILTER. $_kdl (read at the top) names the packages to stop carrying. Remove
  # each one's bundle from $KSTAGE, whichever source put it there (KS_IN, KS_IMPORT via KS_MAP, KS_EXPORT);
  # unlisted bundles stay. _kdrop counts bundles actually removed from the stage. The list is read from a
  # here-doc, not a pipe, so the counter lives in this shell (bash, dash and mksh alike). The case refuses
  # anything that is not a bare package name -- the stager validated each line already; this is defence in depth.
  _kdrop=0
  if [ "$_kdn" = 1 ]; then
    while IFS= read -r _kp; do
      case "$_kp" in ''|.*|*[!A-Za-z0-9._]*) continue ;; esac
      [ -e "$KSTAGE/$_kp.keys" ] || continue
      rm -f "$KSTAGE/$_kp.keys" 2>>"$LOG"
      [ -e "$KSTAGE/$_kp.keys" ] || _kdrop=$((_kdrop + 1))
    done <<KSDROP_EOF
$_kdl
KSDROP_EOF
  fi
  # A DROP WITH NO FRESH DUMP DOES NOT PUSH. $KSTAGE is sealed as the WHOLE #keys scope, and keystore2 deletes a
  # bundle it has consumed from $KS_IMPORT (try_import's one-shot remove_file; consume_alias removes the file with
  # the last alias), so a bundle for an app opened this session lives only inside keystore2 until remove_user
  # dumps it to $KS_EXPORT. With _kn = 0 no dump landed within the bounded wait: pushing now would seal a stage
  # without that bundle and DESTROY it in the store. The list is re-staged at every sign-out (an Off app stays
  # listed), so the drop happens at the next session whose dump lands. NWP-20260827-04 is why a drop is a reason
  # to RUN; this is why it is not, alone, a reason to PUSH.
  if [ "$_kn" = 0 ] && [ "$_kdrop" != 0 ]; then
    echo "[roamd] #keys drop of $_kdrop deferred: no dump landed $(date)" >> "$LOG"
    rm -rf "$KSTAGE"; rm -f "$KS_EXPORT/$uid"[0-9][0-9][0-9][0-9][0-9].keys; return 0
  fi
  # Gate on FRESH dumps only: with nothing new there is nothing to re-seal, and leaving the head untouched
  # already preserves every carried bundle. Re-pushing an unchanged set would only churn the store.
  # NWP-20261016-30: the `dropped` field of the sealed line now ALSO counts the namespaces the merge dropped for
  # want of a KS_MAP package (_knomap, export and import loops). _knomap deliberately does NOT gate the push: an
  # unmapped drop removes nothing from the stored head, so with nothing fresh it must not trigger a re-push.
  if [ "$_kn" = 0 ] && [ "$_kdrop" = 0 ]; then rm -rf "$KSTAGE"; rm -f "$KS_EXPORT/$uid"[0-9][0-9][0-9][0-9][0-9].keys; return 0; fi
  # Own scope: these blobs are DEVICE-bound, so they must never ride #apps (isPerUnitRef makes #apps account-SHARED).
  # DIA-20260812-05: backstop, not a stopwatch -- see the long note at the #apps ladder. 60s could truncate an
  # honest #keys push on a slow link; the daemon's progress-based stall detector is the real hang guard.
  # NWP-20260908-01: pinned OFF -- see the note in _push. These blobs are device-bound keystore exports.
  #
  # NWP-20261116-10 (h46 #2 (2)-(3), over #72 of 2026-10-22): a failed #keys push is tried three more times, after
  # 5 s, 30 s and 2 min, within this reap, from the SAME $KSTAGE (on $STATE, the RAM tmpfs). The decided rule:
  # "the retry writes no key material to /data that a single push does not already write, and the export dump does
  # not outlive the reap (destroyed after the third failure, or by the boot sweep after a crash)".
  # Accepted cost: the RW lane and sessionMu are held for the ladder (155 s) plus up to three more attempts, each
  # capped by timeout 3600. Each wait sleeps in slices of at most 5 s with a ks_prog line before each slice, so the
  # RW worker's 150 s no-progress budget (roamStallTicks) does not answer ERR-TIMEOUT in the middle of the reap. The
  # ladder stays INSIDE the reap: the KS_MAP prune after this call is a cross-identity guard, and a retry after it
  # could not name the dump. Only this arm (credentials present) retries: the no-credentials arm above defers before
  # any push, so it has nothing to retry. The stage is removed once, after the last attempt.
  _ka=0
  for _kw in 0 5 30 120; do
    while [ "$_kw" -gt 0 ]; do
      _ksl=5; [ "$_kw" -lt 5 ] && _ksl=$_kw
      ks_prog keys-retry
      sleep "$_ksl"
      _kw=$((_kw - _ksl))
    done
    _ka=$((_ka + 1))
    NOWHERE_CARRY_ESSENTIAL=0 NOWHERE_CARRY_ESSENTIAL_MEDIA=0 \
      timeout -k 5 3600 "$AGENT" push s3 "${name}#keys" "$(pw "$pass")" "$KSTAGE" >> "$LOG" 2>&1; kret=$?
    [ "$kret" = 0 ] && break
    print -r -- "[roamd] OUT $(qn "$name") #keys push attempt $_ka rc=$kret $(date)" >> "$LOG"
  done
  _kt=$(ls "$KSTAGE" 2>/dev/null | wc -l)
  rm -rf "$KSTAGE"
  if [ "$kret" = 0 ]; then
    KS_VERDICT=sealed
    rm -f "$KS_EXPORT/$uid"[0-9][0-9][0-9][0-9][0-9].keys
    # Report the TOTAL sealed, not just the fresh ones -- logging "1 pkg" while silently dropping the rest is
    # exactly how this hid. A total that shrinks between sessions is now visible in the log.
    print -r -- "[roamd] OUT $(qn "$name") #keys sealed ($_kt pkg, $_kn fresh, $((_kdrop + _knomap)) dropped) $(date)" >> "$LOG"
  else
    # (Superseded by NWP-20261108-01: the roam-in retry site is gone, so no retry site remains.)
    # DIA-20260812-11 (#115): "kept for retry" was DEAD CODE on the reap path, and said the opposite of the
    # truth. The only retry site is the roam-in one, which names each dump by looking its namespace up in
    # KS_MAP -- and cleanstorage PRUNES this uid's KS_MAP rows ELEVEN LINES after calling us. So by the time
    # any retry could run, the dump can no longer be attributed to a package and is dropped ("no package
    # mapping", see the loop above). The dump is unsealable from here on, and it is per-identity keystore
    # material in /data/misc, which outlives both the amnesiac wipe and the power-off -- and whose FILENAME
    # alone re-derives the departed uid. Keeping it buys nothing and leaks; the reap destroys it (see
    # cleanstorage). NOT fixed by deferring the KS_MAP prune instead: that prune is a CROSS-IDENTITY guard,
    # and keeping the rows so a later login could name this dump is how a departed identity's keys would be
    # sealed into the ARRIVING profile's #keys scope.
    KS_VERDICT=notsealed
    # NWP-20261124-13 (#6): a lost reply can hide a landed PUT of $KSTAGE, and $KSTAGE lacks every import of this uid
    # that had no KS_MAP package (_knomapi). Then the store may hold no copy of that import, so the reap keeps the
    # staging: ks_reap_clear clears on notsealed but keeps on notsealed-unmapped. KS_VERDICT stays notsealed.
    [ "$_knomapi" = 0 ] || KS_STAGE_VERDICT=notsealed-unmapped
    print -r -- "[roamd] OUT $(qn "$name") #keys push rc=$kret -- NOT SEALED; this dump can no longer be named (its KS_MAP rows are pruned at this reap) $(date)" >> "$LOG"
  fi
  # DIA-20260812-10 (#118): report the push outcome. #keys is the scope where a silent failure DESTROYS rather
  # than merely staling: an app database re-encrypted this session under a keystore key that was never sealed
  # is permanently unreadable after the wipe. Both callers (cleanstorage's
  # keystore_push call, the `in` arm's retry -- superseded by
  # NWP-20261108-01, cleanstorage is now the only caller) currently
  # ignore the value -- surfacing it from the REAP path is entangled with #115 (the reap publishes OK
  # unconditionally) and is deliberately left to that ticket. This makes the verdict exist; #115 makes it travel.
  return "$kret"
}

# ks_reap_clear UID VERDICT (NWP-20261114-18): the reap's removal of this user's Keystore staging -- the restored
# bundles in keystore-in/<uid> and the staged imports <uid>NNNNN.keys in nowhere-import -- once keystore_push has
# answered sealed (they are in the new #keys head), nothing (the head they were restored from was not replaced) or,
# since NWP-20261124-13 (#6 of the 2026-11-02 decisions), notsealed (the store's previous #keys holds them).
# The check behind notsealed, read from the code: only keystore_restore writes keystore-in/<uid>, from the #keys head,
# after ks_signin_reset emptied it at the landing; a nowhere-import file of this uid comes only from keystore_register's
# or keystore_register_all's mv out of keystore-in, and keystore2 only shrinks or removes it. Of keystore_push's
# notsealed arms, the no-credentials defer, the failed stage mkdir and a stage that is not whole push nothing, so the
# head stays the restored one; a push that failed through the ladder either replaced nothing or, behind a lost reply,
# sealed $KSTAGE, which holds every one of them but the drop-listed ones (the user dropped those) and the imports with
# no KS_MAP package. Those clear on notsealed. The one arm that keeps is that failed push with an import of this uid
# dropped for want of a mapping (keystore_register does not check its KS_MAP append): the landed head may lack that
# import, so keystore_push sets KS_STAGE_VERDICT=notsealed-unmapped and cleanstorage passes that verdict here instead
# of notsealed. Any verdict but sealed, nothing or notsealed (notsealed-unmapped, empty, unknown) keeps them and logs
# the kept line. They hold plaintext keystore2 blobs restored at sign-in, and keystore2's remove_user does not remove
# an import file, so before NWP-20261114-18 they sat on /data until a later landed sign-in; the boot sweep removes
# nowhere-import's *.keys too since NWP-20261114-23. Never another uid's file, never the nowhere-import dir itself
# (keystore2's), never through a symbolic link. Counts only in the log: no package, ns or profile name.
# Defined above the op dispatch for the forward-reference reason in the KS_CREDS / keystore_push note.
ks_reap_clear() {
  local _u="$1" _v="$2" _d _f _a=0 _b=0 _c=0 _why=""
  case "$_u" in ''|*[!0-9]*) return 0 ;; esac
  [ "$_u" -ge 10 ] || return 0
  case "$_v" in
    sealed|nothing) ;;
    notsealed) _why=" (the store's previous #keys holds them, #6)" ;;
    *) echo "[roamd] reap: keystore staging of user $_u kept: #keys $_v (NWP-20261114-18) $(date)" >> "$LOG"; return 0 ;;
  esac
  # rm's own diagnostics go to /dev/null, never to $LOG: they name the file (a package or an ns). A bundle counts as
  # cleared only when it is gone after its rm; one that is still there counts in _c, and the line says so.
  _d="$KS_IN/$_u"
  if [ -L "$_d" ]; then
    rm -f "$_d" 2>/dev/null
  elif [ -d "$_d" ]; then
    for _f in "$_d"/*.keys; do
      [ -e "$_f" ] || [ -L "$_f" ] || continue
      rm -f "$_f" 2>/dev/null
      if [ -e "$_f" ] || [ -L "$_f" ]; then _c=$((_c + 1)); else _a=$((_a + 1)); fi
    done
    rm -rf "$_d" 2>/dev/null
  fi
  for _f in "$KS_IMPORT/$_u"[0-9][0-9][0-9][0-9][0-9].keys; do
    [ -e "$_f" ] || [ -L "$_f" ] || continue
    rm -f "$_f" 2>/dev/null
    if [ -e "$_f" ] || [ -L "$_f" ]; then _c=$((_c + 1)); else _b=$((_b + 1)); fi
  done
  if [ "$_c" -gt 0 ]; then
    echo "[roamd] reap: keystore staging of user $_u partly cleared ($_a restored bundle(s), $_b staged import(s)); $_c bundle(s) could not be removed after #keys $_v$_why (NWP-20261114-18) $(date)" >> "$LOG"
  else
    echo "[roamd] reap: keystore staging of user $_u cleared ($_a restored bundle(s), $_b staged import(s)) after #keys $_v$_why (NWP-20261114-18) $(date)" >> "$LOG"
  fi
}

# ks_stage_drop USERDIR UID (NWP-20261102-04, Q049): stage the chooser's drop list where the reap can still read it.
# keystore_push runs from the credless cleanstorage reap, after removeUser, when the CE copy of
# nowhere-appdrop.list is already gone (the NWP-20260826-15 lesson), so `out` copies it to $KS_DROP -- /data/nowhere,
# device-encrypted, outliving the user -- while the user still exists. Defined here, above the early op-dispatch, for
# the forward-reference reason in the KS_CREDS / keystore_push note, so a later caller in the reap finds it.
# Format (what the filter reads): line 1 is `# <uid>` so a reap can ignore a list staged for another user, then one
# package per line: the drop list minus the live keep-set (nowhere-appkeep, first field), valid package names only,
# each once. ABSENT list -> $KS_DROP removed = no filtering (the chooser deletes the file when nothing is off, so
# this is the common case); a readable but empty list -> header alone. A DROP list, never a keep list (AGENTS.md:
# a keep list filtering at export carries nothing when half restored).
# ~~The list names Off, `Stop carrying` and inferred-orphan apps ONLY. An app uninstalled from Settings is NOT named
# (captureAppDrops does not list it); that case is not built by NWP-20261102-04 or the filter slice after it.~~
# (superseded by NWP-20261109-20: the list names Off, `Stop carrying` and inferred-orphan apps, and also an app the
# user uninstalled from Settings or a launcher once captureAppCode's keep-set prune sees it go -- seen this session
# or watched leaving, and unknown to PackageManager. The prune records it in nowhere-appoff.list through
# recordTurnedOff, and captureAppDrops, which runs right after it at sign-out, lists it. An uninstall the prune
# cannot see keeps its keep line, so the app is still part of the profile and its keys roam with it, by the same
# rule.)
# Counts only in the log (#39 roster rule). Never fails or delays the seal: always returns 0.
ks_stage_drop() {
  local dl ak p nl keep body n k b
  dl="$1/com.nowhere.chooser/files/nowhere-appdrop.list"
  ak="$1/com.nowhere.chooser/files/nowhere-appkeep"
  nl='
'
  if ! [ -f "$dl" ] || ! [ -r "$dl" ]; then
    rm -f "$KS_DROP" "$KS_DROP.new" 2>/dev/null
    echo "[roamd] ks-drop: none -- no drop list this session, nothing staged (user $2) $(date)" >> "$LOG"
    return 0
  fi
  keep=""
  [ -r "$ak" ] && keep=$(cut -f1 "$ak" 2>/dev/null)
  body=""; n=0; k=0; b=0
  while IFS= read -r p || [ -n "$p" ]; do
    pkgname_ok "$p" || { b=$((b + 1)); continue; }
    case "$nl$keep$nl" in *"$nl$p$nl"*) k=$((k + 1)); continue ;; esac
    case "$nl$body" in *"$nl$p$nl"*) continue ;; esac
    body="$body$p$nl"; n=$((n + 1))
  done < "$dl"
  if ( umask 077; { printf '# %s\n' "$2"; printf '%s' "$body"; } > "$KS_DROP.new" && mv -f "$KS_DROP.new" "$KS_DROP" ) 2>/dev/null; then
    echo "[roamd] ks-drop: staged $n package(s) for the #keys reap ($k kept, $b malformed skipped) (user $2) $(date)" >> "$LOG"
  else
    rm -f "$KS_DROP.new" "$KS_DROP" 2>/dev/null
    echo "[roamd] ks-drop: FAILED to stage the drop list -- the reap filters nothing (user $2) $(date)" >> "$LOG"
  fi
  return 0
}

# Live timezone apply (DIA-20260616-60). The in-session picker can't set the GLOBAL system zone (a secondary-user
# app), and the confined daemon can't either -- only root can. zone is passed in the NAME slot (empty = Automatic);
# cmd needs /dev/null stdio from su:s0 (the cmd fd-passing denial, DIA-56). Handled BEFORE the name/uid check (a
# settz has no name/uid). Applied here so the pick takes effect immediately, not just on the next login.
# The reply is a read-back, never the write's word (NWP-20261014-29, NWP-20261112-25): both arms read auto_time_zone
# back, and the override arm also reads the pinned zone. Only the zone the detector picks under Automatic is
# asynchronous; the auto_time_zone row it is told to use is written synchronously.
if [ "$op" = "settz" ]; then
  zone="$name"
  if [ -n "$zone" ]; then
    settings put global auto_time_zone 0 </dev/null >/dev/null 2>&1   # OVERRIDE: detector off so the pin sticks
    cmd alarm set-timezone "$zone" </dev/null >/dev/null 2>&1
    # NWP-20261014-29 (#122): the reply used to be a bare OK whatever cmd did. AlarmManager writes
    # persist.sys.timezone synchronously, and getprop is readable -- so read it back.
    # NWP-20261112-25: and the 0. SettingsProvider writes the row synchronously and `settings get` is captured here
    # as loc_set and vpn_apply capture it, but `settings put` from this context fails silently on a wedged
    # SettingsProvider (nowhere_provision.sh); a pin with the detector still on is moved off the zone minutes later.
    applied=$(getprop persist.sys.timezone)
    tzauto=$(settings get global auto_time_zone </dev/null 2>/dev/null | tr -cd '0-9')
    # NWP-20261106-06: the zone is coarse location (tz_seal_capture's rule: nothing here logs the zone), and roam.log
    # outlives the session through every reap and boot, so no line names the pinned or the read-back zone.
    if [ "$applied" = "$zone" ] && [ "$tzauto" = 0 ]; then
      echo "[roamd] settz override APPLIED $(date)" >> "$LOG"
      echo "OK APPLIED" > "$RES"
    elif [ "$applied" != "$zone" ]; then
      echo "[roamd] settz override NOT APPLIED (the pinned zone did not read back) $(date)" >> "$LOG"
      echo "ERR-TZ" > "$RES"
    else
      echo "[roamd] settz override NOT APPLIED (auto_time_zone read ${tzauto:-?}, not 0) $(date)" >> "$LOG"
      echo "ERR-TZ" > "$RES"
    fi
  else
    def=$(getprop ro.nowhere.default.timezone)                       # AUTOMATIC: seed the default, then auto on
    [ -n "$def" ] && cmd alarm set-timezone "$def" </dev/null >/dev/null 2>&1
    settings put global auto_time_zone 1 </dev/null >/dev/null 2>&1
    # NWP-20261112-25: the zone the detector picks lands asynchronously, but the row is written synchronously, so
    # OK AUTO needs it to read back 1. $def is the baked image default, not the profile's pick.
    tzauto=$(settings get global auto_time_zone </dev/null 2>/dev/null | tr -cd '0-9')
    if [ "$tzauto" = 1 ]; then
      echo "[roamd] settz automatic (seed $def) $(date)" >> "$LOG"
      echo "OK AUTO" > "$RES"
    else
      echo "[roamd] settz automatic NOT APPLIED (auto_time_zone read ${tzauto:-?}) $(date)" >> "$LOG"
      echo "ERR-TZ" > "$RES"
    fi
  fi
  chmod 600 "$RES"; exit 0
fi

# ---- NWP-20261016-45: SESSION-SCOPED LOCATION GLOBALS (begin) -------------------------------------------------------
# Network location (Settings.Global network_location) and geocoding (Settings.Global geocoder) are GrapheneOS
# settings that hold for the WHOLE DEVICE, and GrapheneOS lets only user 0 change them -- on Nowhere that is the gate,
# so no signed-in profile could ever turn either on. Chester, 2026-08-31: "if a user enables it - it should just stay
# enabled for that session and then get disabled"; 2026-10-16: "i agree the default should be off"
# (docs/product-decisions.md, 2026-10-16). So both keys follow the FOREGROUND SESSION, on the DIA-20260616-58
# timezone/locale pattern:
#   - THE CHOICE is the profile's own: netloc=1 / geocoder=1 in its nowhere-prefs (the chooser's CE files, sealed with
#     the profile), written by the Profile screen's Location services switches. An absent key, or any value but 1,
#     is Off (loc_on), so every profile sealed before this existed reads Off.
#   - CLAIM (op locapply): the session in front gets its own choice -- at sign-in, an offline sign-in, a cold-lock
#     resume and each live switch. The daemon sends it only for the uid .roamsession names, and re-checks that under
#     the RW slot (runWorkerHeld), so a claim queued behind a seal cannot land after its session ended.
#   - RELEASE (op locrelease, and cleanstorage's reap): the baseline goes back the moment the session is no longer in
#     front -- the gate switch of every sign-out that removes the session (a logoff, END-UNSAVED, a delete, a
#     rollback, a throwaway's sign-out), a cold lock (a resume claims again), and the reap.
#   - THE BOOT SWEEP restores the baseline at every boot (loc_boot), so a session that ended with none of those -- a
#     power loss, a reboot fallback, RESTART-UNSAVED -- costs one boot, never a standing leak.
# THE BASELINE IS WRITTEN, NOT DELETED. 0 is each key's GrapheneOS default (NetworkLocationSettings, GeocoderSettings
# in frameworks/base/core/java/android/ext/settings), so a delete would read the same through IntSetting.get; a
# written 0 reads back as 0, which is what proves the reset happened, and it overwrites a value someone set by hand.
# OWNERSHIP: $LOC_OWNER names the uid whose values are applied. A release for any OTHER uid leaves the globals alone:
# that is what keeps the #123 reap of a superseded cold-locked session, or any late reap, from switching off the
# session that is now in front. One foreground user at a time, and every claim and release runs on the RW lane.
# AN OWNER WHOSE USER NO LONGER EXISTS IS NO OWNER (loc_owner, loc_gone): a sign-in the chooser abandoned can claim
# and then be removed with no sign-out, reap or switch for it, and a release or boot sweep that deferred to that
# record would keep a removed session's choice on until the next sign-in. Only a definite "No such file" for its
# /data/user/<n> counts; a denial or any other error keeps the record, so a live session is never switched off.
# NOT ON DIASPORE: an image without GrapheneOS's provider has neither setting, so nothing is written at all.
# loc_supported tests the provider's APK -- the same file the daemon (locProviderAPK) and the chooser
# (ProfileActivity.LOC_PROVIDER_APK) test, so the switches are never shown where this would not apply them.
# Logs carry the uid and the two VALUES only: never a location, never a profile name.
LOC_PROVIDER_APK=/system/priv-app/NetworkLocation/NetworkLocation.apk  # GrapheneOS's NetworkLocation (handheld_system.mk)
LOC_NET_KEY=network_location    # Settings.Global.NETWORK_LOCATION
LOC_GEO_KEY=geocoder            # Settings.Global.GEOCODER
LOC_NET_ON=2                    # NetworkLocationSettings.NETWORK_LOCATION_GRAPHENEOS_APPLE_PROXY
LOC_GEO_ON=2                    # GeocoderSettings.GEOCODER_SERVER_GRAPHENEOS
LOC_OFF=0                       # NETWORK_LOCATION_DISABLED and GEOCODER_DISABLED, each key's GrapheneOS default
LOC_OWNER="$STATE/.locglobals"  # the uid whose values are applied; on the tmpfs, so every boot starts with no owner
LOC_USER_ROOT=/data/user        # one CE directory per Android user: <n>/com.nowhere.chooser holds the prefs

loc_supported() { [ -f "$LOC_PROVIDER_APK" ]; }

# loc_on <prefs file> <key>: true iff the key's FIRST line reads exactly 1 once blanks are stripped -- the chooser's
# prefValueIn + locPrefOn rule. A missing file or key, 0, 2, "true": Off.
loc_on() {
  local _l _v
  [ -r "$1" ] || return 1
  while IFS= read -r _l || [ -n "$_l" ]; do
    case "$_l" in
      "$2="*) _v=$(printf '%s' "${_l#*=}" | tr -d ' \t\r'); [ "$_v" = 1 ]; return ;;
    esac
  done < "$1"
  return 1
}

# loc_set <network_location value> <geocoder value>: write both, read both back. True iff each put exited 0 and each
# key reads back as written; LOC_SEEN says what they read ("?" for nothing). cmd stdio goes to /dev/null (DIA-56) and
# NEVER to $LOG, which system_server may not append to (DIA-20260807-07); the get's stdout is this shell's pipe.
loc_set() {
  local _rn _rg _n _g
  settings put global "$LOC_NET_KEY" "$1" </dev/null >/dev/null 2>&1; _rn=$?
  settings put global "$LOC_GEO_KEY" "$2" </dev/null >/dev/null 2>&1; _rg=$?
  _n=$(settings get global "$LOC_NET_KEY" </dev/null 2>/dev/null | tr -cd '0-9a-z')
  _g=$(settings get global "$LOC_GEO_KEY" </dev/null 2>/dev/null | tr -cd '0-9a-z')
  LOC_SEEN="$LOC_NET_KEY=${_n:-?},$LOC_GEO_KEY=${_g:-?}"
  [ "$_rn" = 0 ] && [ "$_rg" = 0 ] && [ "$_n" = "$1" ] && [ "$_g" = "$2" ]
}

# loc_gone <uid>: true only when user <uid> DEFINITELY no longer exists: its CE directory, which vold removes with the
# user and which stays (encrypted) while the user is cold-locked, answers "No such file". Anything else -- it is there,
# a denial, an I/O fault -- is "not known to be gone", the daemon's androidUserGone rule.
loc_gone() {
  local _e
  _e=$(ls -d "$LOC_USER_ROOT/$1" 2>&1 >/dev/null) && return 1
  case "$_e" in *"No such file"*) return 0 ;; esac
  return 1
}

# loc_owner: the uid $LOC_OWNER names, or nothing (no record, not a number, or a user that no longer exists).
loc_owner() {
  local _o=""
  [ -f "$LOC_OWNER" ] && IFS= read -r _o < "$LOC_OWNER"
  case "$_o" in *[!0-9]*) _o="" ;; esac
  if [ -n "$_o" ] && loc_gone "$_o"; then
    echo "[roamd] locglobals: the owner, user $_o, no longer exists -- not counted as an owner $(date)" >> "$LOG"
    _o=""
  fi
  echo "$_o"
}

# loc_why <token>: the reason a line is logged with -- lowercase letters only, so nothing else can reach the log.
loc_why() { case "$1" in ''|*[!a-z]*) echo other ;; *) echo "$1" ;; esac; }

# loc_claim <uid> <prefs file> <why>: uid's session is in front -- record it as the owner, then apply its choice.
# Sets LOC_VERDICT: OK APPLIED <both values> | ERR-LOC <what they read> | OK UNAVAILABLE.
loc_claim() {
  local _u="$1" _f="$2" _why _n="$LOC_OFF" _g="$LOC_OFF"
  _why=$(loc_why "$3")
  if ! loc_supported; then
    echo "[roamd] locglobals user $_u ($_why): no GrapheneOS location provider on this image -- nothing written $(date)" >> "$LOG"
    LOC_VERDICT="OK UNAVAILABLE"; return 0
  fi
  loc_on "$_f" netloc && _n="$LOC_NET_ON"
  loc_on "$_f" geocoder && _g="$LOC_GEO_ON"
  # The owner goes down FIRST, so a write that then fails half-way still has an owner whose release resets it.
  if ! { echo "$_u" > "$LOC_OWNER"; } 2>/dev/null; then
    echo "[roamd] locglobals user $_u ($_why): the owner record could not be written $(date)" >> "$LOG"
  fi
  if loc_set "$_n" "$_g"; then
    echo "[roamd] locglobals user $_u ($_why): $LOC_NET_KEY=$_n $LOC_GEO_KEY=$_g APPLIED $(date)" >> "$LOG"
    LOC_VERDICT="OK APPLIED $LOC_NET_KEY=$_n $LOC_GEO_KEY=$_g"
  else
    echo "[roamd] locglobals user $_u ($_why): wrote $LOC_NET_KEY=$_n $LOC_GEO_KEY=$_g, NOT APPLIED (reads $LOC_SEEN) $(date)" >> "$LOG"
    LOC_VERDICT="ERR-LOC $LOC_SEEN"
  fi
}

# loc_release <uid> <why>: uid's session is no longer in front. The baseline goes back unless ANOTHER session, whose
# user still exists, owns the globals now. Sets LOC_VERDICT: OK BASELINE | OK KEPT | ERR-LOC <what they read> |
# OK UNAVAILABLE.
loc_release() {
  local _u="$1" _why _o
  _why=$(loc_why "$2")
  if ! loc_supported; then LOC_VERDICT="OK UNAVAILABLE"; return 0; fi
  _o=$(loc_owner)
  if [ -n "$_o" ] && [ "$_o" != "$_u" ]; then
    echo "[roamd] locglobals user $_u ($_why): left as they are -- user $_o's session holds them $(date)" >> "$LOG"
    LOC_VERDICT="OK KEPT"; return 0
  fi
  if loc_set "$LOC_OFF" "$LOC_OFF"; then
    rm -f "$LOC_OWNER"
    echo "[roamd] locglobals user $_u ($_why): baseline $LOC_NET_KEY=$LOC_OFF $LOC_GEO_KEY=$LOC_OFF RESTORED $(date)" >> "$LOG"
    LOC_VERDICT="OK BASELINE"
  else
    # The owner record stays, so the reap's release of this uid tries again; the boot sweep is the last resort.
    echo "[roamd] locglobals user $_u ($_why): baseline NOT RESTORED (reads $LOC_SEEN) $(date)" >> "$LOG"
    LOC_VERDICT="ERR-LOC $LOC_SEEN"
  fi
}

# loc_boot: the boot backstop. The baseline goes back unless a session that signed in before this sweep ran already
# owns the globals (the gate takes sign-ins while BootReceiver's sweep runs) and its user still exists (loc_owner).
# Sets LOC_BOOT for the result line.
loc_boot() {
  local _o
  if ! loc_supported; then LOC_BOOT=UNAVAILABLE; return 0; fi
  _o=$(loc_owner)
  if [ -n "$_o" ]; then LOC_BOOT="KEPT:user$_o"; return 0; fi
  if loc_set "$LOC_OFF" "$LOC_OFF"; then LOC_BOOT=baseline; else LOC_BOOT="FAILED($LOC_SEEN)"; fi
}

# The daemon's two ops. uid only (a secondary user, >= 10); the name slot carries a reason token, never a name.
# Handled before the name/uid arg check, like settz. Every RES is one line, so nothing waits on an empty reply.
if [ "$op" = "locapply" ] || [ "$op" = "locrelease" ]; then
  case "$uid" in ''|*[!0-9]*|0?*) echo "ERR-UID" > "$RES"; chmod 600 "$RES"; exit 0;; esac
  [ "$uid" -ge 10 ] || { echo "ERR-UID" > "$RES"; chmod 600 "$RES"; exit 0; }
  if [ "$op" = locapply ]; then
    loc_claim "$uid" "$LOC_USER_ROOT/$uid/com.nowhere.chooser/files/nowhere-prefs" "$name"
  else
    loc_release "$uid" "$name"
  fi
  echo "$LOC_VERDICT" > "$RES"; chmod 600 "$RES"; exit 0
fi
# ---- NWP-20261016-45: SESSION-SCOPED LOCATION GLOBALS (end) ---------------------------------------------------------
# ---- NWP-20261028-07: SESSION-SCOPED DATA ROAMING (begin) ------------------------------------------------------------
# Data roaming is a per-subscription DEVICE setting that only the gate (user 0) can change, so a signed-in profile has no
# switch for it. Chester, 2026-10-19 (docs/product-decisions.md): the Mobile data switch COVERS data roaming, on the same
# baseline -- the gate's own value, restored whenever the profile is not in front -- and it is written by the gate's
# chooser through the telephony API and read back from siminfo. It rides on the mobile-data block below: that block's op
# arm (mdapply / mdrelease) calls dr_claim / dr_release, the reap and the boot sweep call dr_release / dr_boot, so
# roaming is claimed and restored at every site mobile data is. This block has no op arm of its own, and it sits BEFORE
# the mobile-data block because that block's op arm exits.
#   - THE CHOICE is the profile's own: dataroaming=1 / dataroaming=0 in the same nowhere-prefs, TRI-STATE on
#     md_choice's rules: the first such line, blanks and CR stripped, exactly 1 or 0; anything else, or no line, is NO
#     CHOICE and means the gate's value, so it never changes the phone.
#   - THE WRITE is the gate's DataRoamingReceiver (am broadcast to user 0), never `settings put` / `settings get` of a
#     data_roaming key: that key is inert (telephony does not act on it), and a value read from it would be a lie. The
#     receiver sets TelephonyManager.setDataRoamingEnabled, waits up to 3 s for siminfo to settle and reports the LAST
#     value it read, so a claim or a restore may take that long. dr_call parses ONLY the `data="..."` of the receiver's
#     `Broadcast completed:` line: `OK sub=<n> data_roaming=<0|1>`; anything else (no line, ERR-DR <why>, a timeout)
#     reads as `?` and is never applied.
# THE BASELINE RECORD, $DR_BASE, is one line `<sub>:<0|1>` -- the gate's data roaming and the subscription it was read on
# -- in /data/nowhere, OUTSIDE the tmpfs for mobiledata.base's reason: after a power loss mid-session only a record that
# survives can say what the gate had. Written by temp file + rename, ONLY when none exists, BEFORE the phone is changed,
# and NEVER rewritten (the recapture trap: a second profile's claim while the first was never released would record the
# first profile's value as the gate's). A release or boot restores the RECORDED subscription (--ei sub), even if the
# default data SIM changed since, and drops the record when that subscription already reads the baseline. A claim whose
# default data subscription is not the recorded one writes nothing: a sub is changed only while its gate value is
# recorded, and the release or boot restores the recorded one.
# A WRITE IS APPLIED ONLY WHEN IT READS BACK: dr_write needs an OK reply AND the receiver's read-back to equal the value.
# OWNERSHIP follows md_owner: $DR_OWNER (tmpfs) names the uid whose choice is applied; a release for any OTHER uid leaves
# the phone alone; an owner whose user is gone (loc_gone) is no owner.
# Logs carry the uid, the subscription id and values only: never a profile name, never the receiver's output.
DR_BASE=/data/nowhere/dataroaming.base  # the GATE's value and its sub while a session has changed it: <sub>:<0|1>, outside the tmpfs
DR_OWNER="$STATE/.dataroaming"          # the uid whose choice is applied; on the tmpfs, so every boot starts with no owner
DR_RECEIVER=com.nowhere.chooser/.DataRoamingReceiver
DR_ACTION=com.nowhere.chooser.action.DATA_ROAMING

# dr_choice <prefs file>: the profile's choice, 0 or 1, or nothing for NO CHOICE (md_choice's rules, dataroaming= key).
dr_choice() {
  local _l _v
  [ -r "$1" ] || return 0
  while IFS= read -r _l || [ -n "$_l" ]; do
    case "$_l" in
      "dataroaming="*)
        _v=$(printf '%s' "${_l#*=}" | tr -d ' \t\r')
        case "$_v" in 1|0) echo "$_v" ;; esac
        return 0 ;;
    esac
  done < "$1"
  return 0
}

# dr_base: the record, <sub>:<0|1> (sub a positive integer without a leading 0), or nothing (none, or anything else).
dr_base() {
  local _b="" _s _v
  [ -f "$DR_BASE" ] && _b=$(cat "$DR_BASE" 2>/dev/null | tr -d '\r')
  _s=${_b%%:*}; _v=${_b#*:}
  case "$_s" in ''|*[!0-9]*|0*) return 0 ;; esac
  case "$_v" in 0|1) echo "$_s:$_v" ;; esac
}

# dr_base_put <sub:v>: write the record by temp file + sync + rename in its own directory, then sync the
#   directory. False when it could not be written.
# NWP-20261124-24: synced as md_base_put says (a power loss before the next f2fs checkpoint lost the record).
dr_base_put() {
  local _dbs=0
  if ! { printf '%s' "$1" > "$DR_BASE.new"; } 2>/dev/null; then rm -f "$DR_BASE.new" 2>/dev/null; return 1; fi
  sync "$DR_BASE.new" 2>/dev/null || _dbs=1
  if ! mv -f "$DR_BASE.new" "$DR_BASE" 2>/dev/null; then rm -f "$DR_BASE.new" 2>/dev/null; return 1; fi
  sync "${DR_BASE%/*}" 2>/dev/null || _dbs=1
  [ "$_dbs" = 0 ] || echo "[roamd] dr baseline record written but its sync failed -- it may not survive a power loss (NWP-20261124-24) $(date)" >> "$LOG"
  return 0
}

# dr_owner: the uid $DR_OWNER names, or nothing (no record, not a number, or a user that no longer exists).
dr_owner() {
  local _o=""
  [ -f "$DR_OWNER" ] && IFS= read -r _o < "$DR_OWNER"
  case "$_o" in *[!0-9]*) _o="" ;; esac
  if [ -n "$_o" ] && loc_gone "$_o"; then
    echo "[roamd] dataroaming: the owner, user $_o, no longer exists -- not counted as an owner $(date)" >> "$LOG"
    _o=""
  fi
  echo "$_o"
}

# dr_call <get|set> [<value>] [<sub>]: one receiver call. DR_SUB and DR_SEEN (0 or 1) are set and 0 is returned only for
# the reply `OK sub=<n> data_roaming=<0|1>`; anything else leaves DR_SEEN '?' and DR_SUB empty and returns 1.
# Only the data="..." of the `Broadcast completed:` line is read; the result code and every other line are ignored.
dr_call() {
  local _op="$1" _val="${2:-}" _sub="${3:-}" _out _d _s _v _rc
  set -- --es op "$_op"
  if [ -n "$_val" ]; then set -- "$@" --ei value "$_val"; fi
  if [ -n "$_sub" ]; then set -- "$@" --ei sub "$_sub"; fi
  DR_SUB=""; DR_SEEN='?'
  _out=$(timeout -k 2 10 am broadcast --user 0 -n "$DR_RECEIVER" -a "$DR_ACTION" "$@" </dev/null 2>/dev/null)
  _rc=$?
  # A timeout (124/137) or any failure of am: whatever it printed before is not a confirmed reply.
  [ "$_rc" -eq 0 ] || return 1
  _d=$(printf '%s\n' "$_out" | tr -d '\r' | sed -n 's/^Broadcast completed:.*data="\([^"]*\)".*/\1/p' | head -n 1)
  case "$_d" in "OK sub="*) ;; *) return 1 ;; esac
  _s=${_d#OK sub=}; _s=${_s%% *}; _v=${_d##* data_roaming=}
  case "$_s" in ''|*[!0-9]*|0*) return 1 ;; esac
  case "$_v" in 0|1) ;; *) return 1 ;; esac
  [ "$_d" = "OK sub=$_s data_roaming=$_v" ] || return 1
  DR_SUB="$_s"; DR_SEEN="$_v"
  return 0
}

# dr_get [<sub>]: read data roaming (the default data subscription when no sub is given).
dr_get() {
  dr_call get "" "${1:-}"
}

# dr_write <0|1> <sub>: ask the receiver to switch that subscription. True iff the reply is OK AND what it read back
# (DR_SEEN) equals the value -- the receiver reports siminfo's value after its settle, so a write that did not land is false.
dr_write() {
  dr_call set "$1" "$2" && [ "$DR_SEEN" = "$1" ]
}

# dr_claim <uid> <prefs file> <why>: uid's session is in front -- record it as the owner, then apply its choice.
# Sets DR_VERDICT (logged only) and ALWAYS leaves DR_SEEN at what the receiver last read, '?' when that call failed.
dr_claim() {
  local _u="$1" _f="$2" _why _c _rec _bs="" _bv="" _cur _sub _t
  _why=$(loc_why "$3")
  # The owner goes down FIRST, so a write that fails half-way still has an owner whose release restores the phone.
  if ! { echo "$_u" > "$DR_OWNER"; } 2>/dev/null; then
    echo "[roamd] dataroaming user $_u ($_why): the owner record could not be written $(date)" >> "$LOG"
  fi
  _c=$(dr_choice "$_f")
  _rec=$(dr_base)
  if [ -n "$_rec" ]; then _bs=${_rec%%:*}; _bv=${_rec#*:}; fi
  dr_get
  _cur="$DR_SEEN"; _sub="$DR_SUB"
  if [ "$_cur" = '?' ]; then
    echo "[roamd] dataroaming user $_u ($_why): current value unreadable -- nothing written $(date)" >> "$LOG"
    DR_VERDICT="ERR-DR data_roaming=?"; return 0
  fi
  if [ -n "$_rec" ] && [ "$_bs" != "$_sub" ]; then
    echo "[roamd] dataroaming user $_u ($_why): the record is for sub $_bs, the data sub is $_sub -- nothing written $(date)" >> "$LOG"
    DR_VERDICT="ERR-DR data_roaming=$_cur"; return 0
  fi
  if [ -n "$_c" ]; then _t="$_c"
  elif [ -n "$_rec" ]; then _t="$_bv"
  else _t=$_cur; fi
  if [ "$_t" = "$_cur" ]; then
    echo "[roamd] dataroaming user $_u ($_why): sub=$_sub data_roaming=$_cur already -- nothing written $(date)" >> "$LOG"
    DR_VERDICT="OK APPLIED data_roaming=$_cur"; return 0
  fi
  if [ -z "$_rec" ]; then
    # No record: no session has changed the phone, so what it reads now is the GATE's value. With a record it is
    # NEVER rewritten (the recapture trap above).
    if ! dr_base_put "$_sub:$_cur"; then
      echo "[roamd] dataroaming user $_u ($_why): the baseline record could not be written -- nothing changed $(date)" >> "$LOG"
      DR_VERDICT="ERR-DR data_roaming=$_cur"; return 0
    fi
  fi
  if dr_write "$_t" "$_sub"; then
    echo "[roamd] dataroaming user $_u ($_why): sub=$_sub data_roaming=$_t APPLIED (reads $DR_SEEN) $(date)" >> "$LOG"
    DR_VERDICT="OK APPLIED data_roaming=$_t"
  else
    # The record stays: the release or the boot sweep finds the phone already at it and drops it.
    echo "[roamd] dataroaming user $_u ($_why): sub=$_sub data_roaming=$_t NOT APPLIED (reads $DR_SEEN) $(date)" >> "$LOG"
    DR_VERDICT="ERR-DR data_roaming=$DR_SEEN"
  fi
}

# dr_release <uid> <why>: uid's session is no longer in front. The gate's value goes back, on the RECORDED subscription,
# unless ANOTHER session, whose user still exists, owns the phone now. Sets DR_VERDICT (logged only):
# BASELINE | KEPT | NONE | ERR-DR.
dr_release() {
  local _u="$1" _why _o _rec _bs _bv
  _why=$(loc_why "$2")
  _o=$(dr_owner)
  if [ -n "$_o" ] && [ "$_o" != "$_u" ]; then
    echo "[roamd] dataroaming user $_u ($_why): left as it is -- user $_o's session holds it $(date)" >> "$LOG"
    DR_VERDICT="KEPT"; return 0
  fi
  _rec=$(dr_base)
  if [ -z "$_rec" ]; then
    rm -f "$DR_OWNER" "$DR_BASE"
    echo "[roamd] dataroaming user $_u ($_why): no baseline -- no session changed the phone $(date)" >> "$LOG"
    DR_VERDICT="NONE"; return 0
  fi
  _bs=${_rec%%:*}; _bv=${_rec#*:}
  dr_get "$_bs"
  if [ "$DR_SEEN" = "$_bv" ]; then
    rm -f "$DR_BASE" "$DR_OWNER"
    echo "[roamd] dataroaming user $_u ($_why): sub=$_bs baseline data_roaming=$_bv already -- record dropped $(date)" >> "$LOG"
    DR_VERDICT="BASELINE"; return 0
  fi
  if dr_write "$_bv" "$_bs"; then
    rm -f "$DR_BASE" "$DR_OWNER"
    echo "[roamd] dataroaming user $_u ($_why): sub=$_bs baseline data_roaming=$_bv RESTORED $(date)" >> "$LOG"
    DR_VERDICT="BASELINE"
  else
    # Both records are kept, so the reap's release of this uid tries again; the boot sweep is the last resort.
    echo "[roamd] dataroaming user $_u ($_why): sub=$_bs baseline NOT RESTORED (reads $DR_SEEN) $(date)" >> "$LOG"
    DR_VERDICT="ERR-DR"
  fi
}

# dr_boot: the boot backstop. Sets DR_BOOT for the result line: KEPT:user<n> | none | baseline | FAILED(<seen>).
dr_boot() {
  local _o _rec _bs _bv
  _o=$(dr_owner)
  if [ -n "$_o" ]; then DR_BOOT="KEPT:user$_o"; return 0; fi
  _rec=$(dr_base)
  if [ -z "$_rec" ]; then rm -f "$DR_BASE"; DR_BOOT=none; return 0; fi
  _bs=${_rec%%:*}; _bv=${_rec#*:}
  dr_get "$_bs"
  if [ "$DR_SEEN" = "$_bv" ]; then rm -f "$DR_BASE"; DR_BOOT=baseline; return 0; fi
  if dr_write "$_bv" "$_bs"; then
    rm -f "$DR_BASE"; DR_BOOT=baseline
    echo "[roamd] dataroaming boot: sub=$_bs baseline data_roaming=$_bv RESTORED $(date)" >> "$LOG"
  else
    DR_BOOT="FAILED($DR_SEEN)"
    echo "[roamd] dataroaming boot: sub=$_bs baseline NOT RESTORED (reads $DR_SEEN) $(date)" >> "$LOG"
  fi
}
# ---- NWP-20261028-07: SESSION-SCOPED DATA ROAMING (end) --------------------------------------------------------------
# ---- NWP-20261028-10: SESSION HOTSPOT RELEASE (begin) ----------------------------------------------------------------
# A signed-in profile cannot share its connection: hotspot and USB/Bluetooth tethering are admin-only, so a session has
# none (docs/product-decisions.md, 2026-10-19; 2026-10-20 item 2: the hotspot starts only from the session's own tap).
# roamd decides WHEN it stops: at every release path mobile data already covers (the mdrelease arm: sign-out, cold lock,
# a gone user's marker), at the reap (an abandoned sign-in's user included) and at boot (fix 15). The gate decides WHETHER:
# HotspotReceiver (user 0) stops wifi/usb/bluetooth tethering and overwrites the stored soft-AP configuration with a fresh
# random name and passphrase -- that reset is what clears WifiConfigStoreSoftAp.xml -- unless the hotspot belongs to
# another session (Hotspot.releaseDecision; uid -1 is unconditional). Reply: OK RELEASED | OK KEPT | ERR-HS <reason>.
#   - NO STATE here: ownership is the gate's, so this block writes no file, under /data/nowhere or the tmpfs, and only
#     appends to $LOG (uid, the loc_why token and the verdict -- never a name, an SSID or a passphrase).
#   - NEVER FROM A CLAIM: a claim starts nothing; the hotspot starts only from the session's own tap.
#   - It precedes the mobile-data block because that block's op arm exits.
HS_RECEIVER=com.nowhere.chooser/.HotspotReceiver
HS_ACTION=com.nowhere.chooser.action.HOTSPOT_RELEASE

# hs_release <uid|-1> <why>: ask the gate to stop and reset the hotspot. Sets HS_VERDICT to the receiver's data= of the
# first "Broadcast completed:" line: OK RELEASED, OK KEPT or ERR-HS <reason>; anything else, a failed or timed-out am
# included, is ERR-HS noreply.
hs_release() {
  local _u="$1" _why _out _rc _d
  _why=$(loc_why "$2")
  _out=$(timeout -k 2 15 am broadcast --user 0 -n "$HS_RECEIVER" -a "$HS_ACTION" --ei uid "$_u" </dev/null 2>/dev/null)
  _rc=$?
  _d=$(printf '%s\n' "$_out" | tr -d '\r' | sed -n 's/^Broadcast completed:.*data="\([^"]*\)".*/\1/p' | head -n 1)
  [ "$_rc" -eq 0 ] || _d=""   # a timed-out or failed am's output is not a confirmed reply
  case "$_d" in
    "OK RELEASED"|"OK KEPT") HS_VERDICT="$_d" ;;
    "ERR-HS "*) case "${_d#ERR-HS }" in ''|*[!a-z]*) HS_VERDICT="ERR-HS noreply" ;; *) HS_VERDICT="$_d" ;; esac ;;
    *) HS_VERDICT="ERR-HS noreply" ;;
  esac
  echo "[roamd] hotspot user $_u ($_why): $HS_VERDICT $(date)" >> "$LOG"
}
# ---- NWP-20261028-10: SESSION HOTSPOT RELEASE (end) ------------------------------------------------------------------
# ---- NWP-20261026-05: SESSION-SCOPED MOBILE DATA (begin) ------------------------------------------------------------
# Mobile data (Settings.Global mobile_data) is a DEVICE setting, and only the gate (user 0) can change it, so a
# signed-in profile has no Mobile data switch. Chester, 2026-10-19 (docs/product-decisions.md): it follows the
# FOREGROUND SESSION on the NWP-20261016-45 location pattern above, with ONE difference -- the baseline is not a
# constant. Location's is 0 (each key's default), so the tmpfs-empty boot can assume it. Mobile data's baseline is
# THE GATE'S OWN VALUE, which only the phone knows:
#   - THE CHOICE is the profile's own: mobiledata=1 / mobiledata=0 in its nowhere-prefs, TRI-STATE. The first such
#     line, blanks and CR stripped: exactly 1 = On, exactly 0 = Off; anything else, or no line, is NO CHOICE and means
#     the gate's value (a profile sealed before this existed has none), so it never changes the phone.
#   - CLAIM (op mdapply): the session in front gets its choice; with none, the phone is put back to the gate's value.
#   - RELEASE (op mdrelease, and cleanstorage's reap): the gate's value goes back when the session leaves the front.
#   - THE BOOT SWEEP (md_boot, fix 12) restores it at every boot, so a power loss costs one boot, never a leak.
# THE BASELINE RECORD, $MD_BASE, is one digit (0 or 1) in /data/nowhere, OUTSIDE the tmpfs on purpose: $STATE is empty
# at every boot, and after a power loss mid-session the persisted device value may be the PROFILE's, so only a record
# that survives can say what the gate had. It is safe under the amnesia rule: it is the gate's own setting, one
# digit, no uid, no reason, naming no profile. Written by temp file + rename, so a reader never sees half of it.
# THE RECAPTURE TRAP: the record is written only when none exists, and NEVER rewritten. A second profile's claim while
# the first was never released would otherwise record the first profile's value as the gate's, and every later
# sign-out would leave the phone at that profile's choice. It is written BEFORE the phone is changed, so a crash in
# between leaves a record whose restore is harmless.
# A WRITE IS APPLIED ONLY WHEN IT READS BACK: md_write needs cmd's exit status 0 AND the read-back to equal the value.
# A refused write therefore replies ERR-MD, never applied. A release or boot sweep that finds the phone ALREADY at the
# baseline (e.g. the claim's write was refused) drops the record without a write: otherwise, on a build whose policy
# denies the write, the record would outlive every session, every boot would retry, and its digit would later
# override a value the owner set in Owner settings.
# OWNERSHIP follows loc_owner: $MD_OWNER (tmpfs) names the uid whose choice is applied; a release for any OTHER uid
# leaves the phone alone; an owner whose user is gone (loc_gone) is no owner.
# NAMES FROM AOSP, NOT FROM THE GRAPHENEOS TREE: multi_sim_data_call (Settings.Global.MULTI_SIM_DATA_CALL_SUBSCRIPTION),
# mobile_data<subId> and `cmd phone data enable|disable` (TelephonyShellCommand, which `svc data` forwards to) were
# not read from the GrapheneOS source. And on an Endospore USER build roamd runs as endospore_priv, whose policy has no
# radio_service find (the `phone` service) and no binder_call to radio, so `cmd phone` is expected to be DENIED there
# until a sepolicy grant lands (docs/backlog.md). A denial shows as ERR-MD, never as applied. We do not write the
# persisted key with `settings put`: that is not known to make telephony act on it.
# ONLY THE DEFAULT DATA SUBSCRIPTION'S KEY IS READ (NWP-20261117-17): md_read reads mobile_data<sub> of the subscription
# multi_sim_data_call names. With none (unset, null, -1, 0, junk) it reads NO setting and answers ?, so a claim writes
# nothing and replies ERR-MD mobile_data=? (data roaming answers ERR-DR nosub then). The legacy mobile_data key is no
# SIM's value when no data SIM is chosen (lynx 2026102901: mobile_data=1 with mobile_data1=0 and mobile_data2=0).
# Logs carry the uid and the VALUES only: never a profile name.
MD_BASE=/data/nowhere/mobiledata.base  # the GATE's value while a session has changed it: one digit, outside the tmpfs
MD_OWNER="$STATE/.mobiledata"          # the uid whose choice is applied; on the tmpfs, so every boot starts with no owner

# md_choice <prefs file>: the profile's choice, 0 or 1, or nothing for NO CHOICE -- the FIRST mobiledata= line, blanks
# and CR stripped (loc_on's rule). A missing or unreadable file, or any other value, is nothing.
md_choice() {
  local _l _v
  [ -r "$1" ] || return 0
  while IFS= read -r _l || [ -n "$_l" ]; do
    case "$_l" in
      "mobiledata="*)
        _v=$(printf '%s' "${_l#*=}" | tr -d ' \t\r')
        case "$_v" in 0|1) echo "$_v" ;; esac
        return 0 ;;
    esac
  done < "$1"
  return 0
}

# md_base: the baseline record's digit, or nothing (no record, or one that is not exactly 0 or 1).
md_base() {
  local _b=""
  [ -f "$MD_BASE" ] && _b=$(cat "$MD_BASE" 2>/dev/null)
  case "$_b" in 0|1) echo "$_b" ;; esac
}

# md_base_put <0|1>: write the record by temp file + sync + rename in its own directory, then sync the
#   directory. False when it could not be written.
# NWP-20261124-24: the record exists for a power loss mid-session, and it is written once (the recapture trap), so the
#   ext4 rename heuristic never applies and f2fs persists the rename only at its next checkpoint: a forced restart in
#   that window left no record, md_boot answered `none` and the gate kept the session's value. So the helper syncs the
#   file before the rename and the directory after it. coreutils and busybox `sync` fsync each operand; a toybox
#   `sync` that ignores operands runs a full sync(), which covers the data and the rename. Either way the record is
#   durable when `sync` returns 0. A failed sync is logged, not a failure: the record is written.
md_base_put() {
  local _mbs=0
  if ! { printf '%s' "$1" > "$MD_BASE.new"; } 2>/dev/null; then rm -f "$MD_BASE.new" 2>/dev/null; return 1; fi
  sync "$MD_BASE.new" 2>/dev/null || _mbs=1
  if ! mv -f "$MD_BASE.new" "$MD_BASE" 2>/dev/null; then rm -f "$MD_BASE.new" 2>/dev/null; return 1; fi
  sync "${MD_BASE%/*}" 2>/dev/null || _mbs=1
  [ "$_mbs" = 0 ] || echo "[roamd] md baseline record written but its sync failed -- it may not survive a power loss (NWP-20261124-24) $(date)" >> "$LOG"
  return 0
}

# md_owner: the uid $MD_OWNER names, or nothing (no record, not a number, or a user that no longer exists).
md_owner() {
  local _o=""
  [ -f "$MD_OWNER" ] && IFS= read -r _o < "$MD_OWNER"
  case "$_o" in *[!0-9]*) _o="" ;; esac
  if [ -n "$_o" ] && loc_gone "$_o"; then
    echo "[roamd] mobiledata: the owner, user $_o, no longer exists -- not counted as an owner $(date)" >> "$LOG"
    _o=""
  fi
  echo "$_o"
}

# md_sub: the default data subscription -- a positive integer in multi_sim_data_call -- or nothing (null, -1, 0, junk).
md_sub() {
  local _s
  _s=$(settings get global multi_sim_data_call </dev/null 2>/dev/null | tr -d ' \t\r\n')
  case "$_s" in ''|*[!0-9]*|0*) return 0 ;; esac
  echo "$_s"
}

# md_read: the default data subscription's data setting, 0 or 1, else ? (null, empty, a denial). With no default data
# subscription it is ? and NO setting is read: the legacy mobile_data key is no SIM's value when no data SIM is chosen.
md_read() {
  local _s _v
  _s=$(md_sub)
  if [ -z "$_s" ]; then echo '?'; return 0; fi
  _v=$(settings get global "mobile_data$_s" </dev/null 2>/dev/null | tr -d ' \t\r\n')
  case "$_v" in 0|1) echo "$_v" ;; *) echo '?' ;; esac
}

# md_write <0|1>: ask telephony to switch, then read it back. True iff cmd exited 0 AND the read-back equals the value.
# MD_SEEN says what it read. cmd's stdio goes to /dev/null (DIA-56), never to $LOG (DIA-20260807-07).
md_write() {
  local _rc _v="$1"
  if [ "$_v" = 1 ]; then cmd phone data enable </dev/null >/dev/null 2>&1; _rc=$?
  else cmd phone data disable </dev/null >/dev/null 2>&1; _rc=$?; fi
  MD_SEEN=$(md_read)
  [ "$_rc" = 0 ] && [ "$MD_SEEN" = "$_v" ]
}

# md_claim <uid> <prefs file> <why>: uid's session is in front -- record it as the owner, then apply its choice.
# Sets MD_VERDICT: OK APPLIED mobile_data=<v> | ERR-MD mobile_data=<what it read>.
md_claim() {
  local _u="$1" _f="$2" _why _c _b _cur _t
  _why=$(loc_why "$3")
  # The owner goes down FIRST, so a write that fails half-way still has an owner whose release restores the phone.
  if ! { echo "$_u" > "$MD_OWNER"; } 2>/dev/null; then
    echo "[roamd] mobiledata user $_u ($_why): the owner record could not be written $(date)" >> "$LOG"
  fi
  _c=$(md_choice "$_f")
  _b=$(md_base)
  _cur=$(md_read)
  # An unreadable value writes NOTHING, record or not (dr_claim's rule): md_write could never read it back. With no
  # default data subscription there is no SIM to switch (NWP-20261117-17).
  if [ "$_cur" = '?' ]; then
    if [ -z "$(md_sub)" ]; then
      echo "[roamd] mobiledata user $_u ($_why): no default data subscription -- nothing written $(date)" >> "$LOG"
    elif [ -z "$_c" ] && [ -z "$_b" ]; then
      echo "[roamd] mobiledata user $_u ($_why): current value unreadable and no choice -- nothing written $(date)" >> "$LOG"
    else
      echo "[roamd] mobiledata user $_u ($_why): current value unreadable -- nothing written $(date)" >> "$LOG"
    fi
    MD_VERDICT="ERR-MD mobile_data=?"; return 0
  fi
  if [ -n "$_c" ]; then _t="$_c"
  elif [ -n "$_b" ]; then _t="$_b"
  else _t="$_cur"; fi
  if [ "$_cur" = "$_t" ]; then
    echo "[roamd] mobiledata user $_u ($_why): mobile_data=$_cur already -- nothing written $(date)" >> "$LOG"
    MD_VERDICT="OK APPLIED mobile_data=$_cur"; return 0
  fi
  if [ -z "$_b" ]; then
    # No record: no session has changed the phone, so what it reads now is the GATE's value. With a record it is
    # NEVER rewritten (the recapture trap above).
    if ! md_base_put "$_cur"; then
      echo "[roamd] mobiledata user $_u ($_why): the baseline record could not be written -- nothing changed $(date)" >> "$LOG"
      MD_VERDICT="ERR-MD mobile_data=$_cur"; return 0
    fi
  fi
  if md_write "$_t"; then
    echo "[roamd] mobiledata user $_u ($_why): mobile_data=$_t APPLIED (reads $MD_SEEN) $(date)" >> "$LOG"
    MD_VERDICT="OK APPLIED mobile_data=$_t"
  else
    # The record stays: the release or the boot sweep finds the phone already at it and drops it.
    echo "[roamd] mobiledata user $_u ($_why): mobile_data=$_t NOT APPLIED (reads $MD_SEEN) $(date)" >> "$LOG"
    MD_VERDICT="ERR-MD mobile_data=$MD_SEEN"
  fi
}

# md_release <uid> <why>: uid's session is no longer in front. The gate's value goes back unless ANOTHER session, whose
# user still exists, owns the phone now. Sets MD_VERDICT: OK BASELINE mobile_data=<v> | OK KEPT | OK NONE |
# ERR-MD mobile_data=<what it read>.
md_release() {
  local _u="$1" _why _o _b _cur
  _why=$(loc_why "$2")
  _o=$(md_owner)
  if [ -n "$_o" ] && [ "$_o" != "$_u" ]; then
    echo "[roamd] mobiledata user $_u ($_why): left as it is -- user $_o's session holds it $(date)" >> "$LOG"
    MD_VERDICT="OK KEPT"; return 0
  fi
  _b=$(md_base)
  if [ -z "$_b" ]; then
    rm -f "$MD_OWNER" "$MD_BASE"
    echo "[roamd] mobiledata user $_u ($_why): no baseline -- no session changed the phone $(date)" >> "$LOG"
    MD_VERDICT="OK NONE"; return 0
  fi
  _cur=$(md_read)
  if [ "$_cur" = "$_b" ]; then
    # Already there (e.g. the claim's write was refused): drop the record, write nothing -- see the note above.
    rm -f "$MD_BASE" "$MD_OWNER"
    echo "[roamd] mobiledata user $_u ($_why): baseline mobile_data=$_cur already -- record dropped $(date)" >> "$LOG"
    MD_VERDICT="OK BASELINE mobile_data=$_cur"; return 0
  fi
  if md_write "$_b"; then
    rm -f "$MD_BASE" "$MD_OWNER"
    echo "[roamd] mobiledata user $_u ($_why): baseline mobile_data=$_b RESTORED $(date)" >> "$LOG"
    MD_VERDICT="OK BASELINE mobile_data=$_b"
  else
    # Both records stay, so the reap's release of this uid tries again; the boot sweep is the last resort.
    echo "[roamd] mobiledata user $_u ($_why): baseline NOT RESTORED (reads $MD_SEEN) $(date)" >> "$LOG"
    MD_VERDICT="ERR-MD mobile_data=$MD_SEEN"
  fi
}

# md_boot: the boot backstop. Sets MD_BOOT for the result line: KEPT:user<n> | none | baseline | FAILED(<seen>).
md_boot() {
  local _o _b _cur
  _o=$(md_owner)
  if [ -n "$_o" ]; then MD_BOOT="KEPT:user$_o"; return 0; fi
  _b=$(md_base)
  if [ -z "$_b" ]; then MD_BOOT=none; return 0; fi
  _cur=$(md_read)
  if [ "$_cur" = "$_b" ]; then rm -f "$MD_BASE"; MD_BOOT=baseline; return 0; fi
  if md_write "$_b"; then rm -f "$MD_BASE"; MD_BOOT=baseline; else MD_BOOT="FAILED($MD_SEEN)"; fi
}

# The daemon's two ops, handled before the name/uid arg check like the location pair. Every RES is one line.
if [ "$op" = "mdapply" ] || [ "$op" = "mdrelease" ]; then
  case "$uid" in ''|*[!0-9]*|0?*) echo "ERR-UID" > "$RES"; chmod 600 "$RES"; exit 0;; esac
  [ "$uid" -ge 10 ] || { echo "ERR-UID" > "$RES"; chmod 600 "$RES"; exit 0; }
  if [ "$op" = mdapply ]; then
    md_claim "$uid" "$LOC_USER_ROOT/$uid/com.nowhere.chooser/files/nowhere-prefs" "$name"
    dr_claim "$uid" "$LOC_USER_ROOT/$uid/com.nowhere.chooser/files/nowhere-prefs" "$name"   # NWP-20261028-07
    MD_VERDICT="$MD_VERDICT data_roaming=$DR_SEEN"   # NWP-20261028-07: roaming's read-back; it never changes md's verdict
  else
    md_release "$uid" "$name"
    dr_release "$uid" "$name"   # NWP-20261028-07: roaming's outcome is logged; the RES stays md's
    hs_release "$uid" "$name"   # NWP-20261028-10: the gate stops and resets the hotspot; the RES stays md's
  fi
  echo "$MD_VERDICT" > "$RES"; chmod 600 "$RES"; exit 0
fi
# ---- NWP-20261026-05: SESSION-SCOPED MOBILE DATA (end) --------------------------------------------------------------
# ---- NWP-20261027-05: SESSION DEVICE TOGGLES (begin) ----------------------------------------------------------------
# Four DEVICE-WIDE toggles can be flipped from inside a signed-in session and nothing puts them back, so they outlive
# the sign-out: airplane mode (left on, the gate is offline and the next sign-in cannot reach the store), battery saver,
# Data Saver (background data blocked for the gate's own updates) and NFC (off breaks the FIDO2 NFC tap at the gate; on
# stays on). Chester, 2026-10-19 (docs/product-decisions.md, item 3): roamd records the GATE's value of each when a
# session first comes to the front and puts it back at every release path and at boot. On the location pattern above:
# roamd is the only writer, the daemon decides when, and every write is read back.
#   - CLAIM (op dtclaim): records the gate's values if no record exists. NOTHING is written to any setting at claim: the
#     gate's values are what the phone has when a session first comes to the front, or the record already holds them.
#   - RELEASE (op dtrelease, and cleanstorage's reap): every recorded key is read and, if it is not at its baseline,
#     written back. THE SESSION'S OWN CHOICE IS NEVER STORED: only the gate's value is ever kept.
#   - THE BOOT SWEEP (dt_boot, fix 13) restores them at every boot, so a power loss costs one boot, never a leak.
# THE BASELINE RECORD, $DT_BASE, is up to four lines <key>=<0|1> in /data/nowhere, OUTSIDE the tmpfs on purpose: $STATE
# is empty at every boot, and after a power loss mid-session the toggles may hold the SESSION's values, so only a record
# that survives can say what the gate had. It is safe under the amnesia rule: it is the gate's own device settings,
# four digits at most, no uid, no reason, naming no profile; it says only that some session was in front and had not
# released when the power went. Keys are in a fixed order, only those that READ at claim time; a key that did not read
# is left out and never restored. Written by temp file + rename, so a reader never sees half of it.
# THE RECAPTURE TRAP: the record is written only when none exists, and NEVER rewritten by a claim. A second session's
# claim while the first was never released would otherwise record the first session's values as the gate's. The one
# rewrite is a release or boot sweep that failed on some keys: it keeps ONLY the keys still not at baseline.
# A WRITE IS APPLIED ONLY WHEN IT READS BACK: dt_write needs the command's exit status 0 AND the read-back to equal the
# value. A key that is already at its baseline is not written.
# OWNERSHIP follows md_owner: $DT_OWNER (tmpfs) names the uid whose session is in front; a release for any OTHER uid
# leaves the phone alone; an owner whose user is gone (loc_gone) is no owner.
# NAMES FROM AOSP, NOT FROM THE GRAPHENEOS TREE: settings airplane_mode_on / low_power, `cmd connectivity airplane-mode`,
# `cmd power set-mode`, `cmd netpolicy ... restrict-background`, `dumpsys nfc` (the mState= line) and `svc nfc` were not
# read from the GrapheneOS source. On an Endospore USER build roamd runs as endospore_priv and any of them may be denied
# by policy: a denied read is ?, a denied write never reads as restored (docs/backlog.md).
# Called by the daemon since NOWHERE-688 (core/agent/devtoggles.go: claimDevToggles, releaseDevTogglesAsync, releaseDevTogglesAtLock). Logs carry the uid, key names and digits only: never a profile name.
DT_BASE=/data/nowhere/devtoggles.base  # the GATE's toggle values while a session is in front: <key>=<0|1> lines, outside the tmpfs
DT_OWNER="$STATE/.devtoggles"          # the uid whose session is in front; on the tmpfs, so every boot starts with no owner
DT_KEYS="airplane saver datasaver nfc" # the fixed order of the record

# dt_read <key>: the toggle's current value, 0 or 1, else ? (null, empty, an unparsable answer, a denial).
dt_read() {
  local _v="" _o=""
  case "$1" in
    airplane)  _v=$(settings get global airplane_mode_on </dev/null 2>/dev/null | tr -d ' \t\r\n') ;;
    saver)     _v=$(settings get global low_power </dev/null 2>/dev/null | tr -d ' \t\r\n') ;;
    datasaver) _o=$(cmd netpolicy get restrict-background </dev/null 2>/dev/null)
               case "$_o" in *disabled*) _v=0 ;; *enabled*) _v=1 ;; esac ;;
    nfc)       _o=$(dumpsys nfc </dev/null 2>/dev/null | sed -n 's/^[[:space:]]*mState=//p' | head -n 1 | tr -d ' \t\r')
               case "$_o" in on) _v=1 ;; off) _v=0 ;; esac ;;
  esac
  case "$_v" in 0|1) echo "$_v" ;; *) echo '?' ;; esac
}

# dt_write <key> <0|1>: switch the toggle, then read it back. True iff the command exited 0 AND the read-back equals
# the value. DT_SEEN says what it read. The command's stdio goes to /dev/null (DIA-56), never to $LOG (DIA-20260807-07).
dt_write() {
  local _rc
  DT_SEEN='?'
  case "$1:$2" in
    airplane:1)  cmd connectivity airplane-mode enable </dev/null >/dev/null 2>&1; _rc=$? ;;
    airplane:0)  cmd connectivity airplane-mode disable </dev/null >/dev/null 2>&1; _rc=$? ;;
    saver:1)     cmd power set-mode 1 </dev/null >/dev/null 2>&1; _rc=$? ;;
    saver:0)     cmd power set-mode 0 </dev/null >/dev/null 2>&1; _rc=$? ;;
    datasaver:1) cmd netpolicy set restrict-background true </dev/null >/dev/null 2>&1; _rc=$? ;;
    datasaver:0) cmd netpolicy set restrict-background false </dev/null >/dev/null 2>&1; _rc=$? ;;
    nfc:1)       svc nfc enable </dev/null >/dev/null 2>&1; _rc=$? ;;
    nfc:0)       svc nfc disable </dev/null >/dev/null 2>&1; _rc=$? ;;
    *) return 1 ;;
  esac
  DT_SEEN=$(dt_read "$1")
  [ "$_rc" = 0 ] && [ "$DT_SEEN" = "$2" ]
}

# dt_base_get <key>: the record's digit for the key (its first line, CR stripped, exactly 0 or 1), or nothing.
dt_base_get() {
  local _l _v
  [ -f "$DT_BASE" ] || return 0
  while IFS= read -r _l || [ -n "$_l" ]; do
    _l=$(printf '%s' "$_l" | tr -d '\r')
    case "$_l" in
      "$1="*)
        _v="${_l#*=}"
        case "$_v" in 0|1) echo "$_v"; return 0 ;; esac ;;
    esac
  done < "$DT_BASE"
  return 0
}

# dt_base_count: how many keys the record holds a valid line for (0 when there is no record).
dt_base_count() {
  local _k _n=0
  for _k in $DT_KEYS; do
    [ -n "$(dt_base_get "$_k")" ] && _n=$((_n + 1))
  done
  echo "$_n"
}

# dt_base_put <text>: write the record by temp file + sync + rename in its own directory, then sync the
#   directory. False when it could not be written.
# NWP-20261124-24: synced as md_base_put says (a power loss before the next f2fs checkpoint lost the record).
dt_base_put() {
  local _tbs=0
  if ! { printf '%s' "$1" > "$DT_BASE.new"; } 2>/dev/null; then rm -f "$DT_BASE.new" 2>/dev/null; return 1; fi
  sync "$DT_BASE.new" 2>/dev/null || _tbs=1
  if ! mv -f "$DT_BASE.new" "$DT_BASE" 2>/dev/null; then rm -f "$DT_BASE.new" 2>/dev/null; return 1; fi
  sync "${DT_BASE%/*}" 2>/dev/null || _tbs=1
  [ "$_tbs" = 0 ] || echo "[roamd] dt baseline record written but its sync failed -- it may not survive a power loss (NWP-20261124-24) $(date)" >> "$LOG"
  return 0
}

# dt_owner: the uid $DT_OWNER names, or nothing (no record, not a number, or a user that no longer exists).
dt_owner() {
  local _o=""
  [ -f "$DT_OWNER" ] && IFS= read -r _o < "$DT_OWNER"
  case "$_o" in *[!0-9]*) _o="" ;; esac
  if [ -n "$_o" ] && loc_gone "$_o"; then
    echo "[roamd] devtoggles: the owner, user $_o, no longer exists -- not counted as an owner $(date)" >> "$LOG"
    _o=""
  fi
  echo "$_o"
}

# dt_restore: put every recorded key that is not at its baseline back, then drop the record -- or, when some key would
# not go back, rewrite it holding ONLY those keys (the reap and the boot sweep retry). Sets DT_WROTE (writes made),
# DT_FAILED (<key>=<seen> ...) and DT_FAILKEYS (<key>,<key>); empty DT_FAILED means every key now reads its baseline.
dt_restore() {
  local _k _b _cur _keep=""
  DT_WROTE=0; DT_FAILED=""; DT_FAILKEYS=""
  for _k in $DT_KEYS; do
    _b=$(dt_base_get "$_k")
    [ -n "$_b" ] || continue
    _cur=$(dt_read "$_k")
    [ "$_cur" = "$_b" ] && continue
    if dt_write "$_k" "$_b"; then
      DT_WROTE=$((DT_WROTE + 1))
    else
      DT_FAILED="${DT_FAILED:+$DT_FAILED }$_k=$DT_SEEN"
      DT_FAILKEYS="${DT_FAILKEYS:+$DT_FAILKEYS,}$_k"
      _keep="$_keep$_k=$_b
"
    fi
  done
  if [ -z "$DT_FAILED" ]; then
    rm -f "$DT_BASE"
  elif ! dt_base_put "$_keep"; then
    # The old record stays: it still holds every failed key, and restoring a key already at baseline is a no-op.
    echo "[roamd] devtoggles: the shrunken record could not be written -- the old one stays $(date)" >> "$LOG"
  fi
}

# dt_claim <uid> <why>: uid's session is in front -- record it as the owner, then keep the gate's values. Writes NO
# setting. Sets DT_VERDICT: OK CLAIMED <keys in the record>.
dt_claim() {
  local _u="$1" _why _k _v _t="" _rec=""
  _why=$(loc_why "$2")
  if ! { echo "$_u" > "$DT_OWNER"; } 2>/dev/null; then
    echo "[roamd] devtoggles user $_u ($_why): the owner record could not be written $(date)" >> "$LOG"
  fi
  if [ -f "$DT_BASE" ]; then
    # A record exists: a session is already in front or never released. What the phone reads now may be ITS values,
    # so the record is never rewritten (the recapture trap above).
    echo "[roamd] devtoggles user $_u ($_why): record kept ($(dt_base_count) keys) $(date)" >> "$LOG"
  else
    for _k in $DT_KEYS; do
      _v=$(dt_read "$_k")
      case "$_v" in
        0|1) _t="$_t$_k=$_v
"
             _rec="$_rec $_k=$_v" ;;
        *) echo "[roamd] devtoggles user $_u ($_why): $_k unreadable -- left out of the record, never restored $(date)" >> "$LOG" ;;
      esac
    done
    if [ -z "$_t" ]; then
      echo "[roamd] devtoggles user $_u ($_why): nothing readable -- no record $(date)" >> "$LOG"
    elif dt_base_put "$_t"; then
      echo "[roamd] devtoggles user $_u ($_why): recorded$_rec $(date)" >> "$LOG"
    else
      echo "[roamd] devtoggles user $_u ($_why): the record could not be written $(date)" >> "$LOG"
    fi
  fi
  DT_VERDICT="OK CLAIMED $(dt_base_count)"
}

# dt_release <uid> <why>: uid's session is no longer in front. The gate's values go back unless ANOTHER session, whose
# user still exists, owns the phone now. Sets DT_VERDICT: OK RESTORED <writes made> | OK KEPT | OK NONE |
# ERR-DT <key>=<seen>[ <key>=<seen>...].
dt_release() {
  local _u="$1" _why _o
  _why=$(loc_why "$2")
  _o=$(dt_owner)
  if [ -n "$_o" ] && [ "$_o" != "$_u" ]; then
    echo "[roamd] devtoggles user $_u ($_why): left as they are -- user $_o's session holds them $(date)" >> "$LOG"
    DT_VERDICT="OK KEPT"; return 0
  fi
  if [ "$(dt_base_count)" = 0 ]; then
    rm -f "$DT_OWNER" "$DT_BASE"
    echo "[roamd] devtoggles user $_u ($_why): no record -- nothing to put back $(date)" >> "$LOG"
    DT_VERDICT="OK NONE"; return 0
  fi
  dt_restore
  if [ -z "$DT_FAILED" ]; then
    rm -f "$DT_OWNER"
    echo "[roamd] devtoggles user $_u ($_why): RESTORED $DT_WROTE $(date)" >> "$LOG"
    DT_VERDICT="OK RESTORED $DT_WROTE"
  else
    # The record and the owner stay, so the reap's release of this uid tries again; the boot sweep is the last resort.
    echo "[roamd] devtoggles user $_u ($_why): NOT RESTORED: $DT_FAILED (the reap and the boot sweep retry) $(date)" >> "$LOG"
    DT_VERDICT="ERR-DT $DT_FAILED"
  fi
}

# dt_boot: the boot backstop. Sets DT_BOOT for the result line: KEPT:user<n> | none | baseline | FAILED(<key>,<key>).
dt_boot() {
  local _o
  _o=$(dt_owner)
  if [ -n "$_o" ]; then DT_BOOT="KEPT:user$_o"; return 0; fi
  if [ "$(dt_base_count)" = 0 ]; then rm -f "$DT_BASE"; DT_BOOT=none; return 0; fi
  dt_restore
  if [ -z "$DT_FAILED" ]; then
    echo "[roamd] devtoggles boot: RESTORED $DT_WROTE $(date)" >> "$LOG"
    DT_BOOT=baseline
  else
    echo "[roamd] devtoggles boot: NOT RESTORED: $DT_FAILED $(date)" >> "$LOG"
    DT_BOOT="FAILED($DT_FAILKEYS)"
  fi
}

# The daemon's two ops, handled before the name/uid arg check like the mobile-data pair. Every RES is one line.
if [ "$op" = "dtclaim" ] || [ "$op" = "dtrelease" ]; then
  case "$uid" in ''|*[!0-9]*|0?*) echo "ERR-UID" > "$RES"; chmod 600 "$RES"; exit 0;; esac
  [ "$uid" -ge 10 ] || { echo "ERR-UID" > "$RES"; chmod 600 "$RES"; exit 0; }
  if [ "$op" = dtclaim ]; then dt_claim "$uid" "$name"; else dt_release "$uid" "$name"; fi
  echo "$DT_VERDICT" > "$RES"; chmod 600 "$RES"; exit 0
fi
# ---- NWP-20261027-05: SESSION DEVICE TOGGLES (end) ------------------------------------------------------------------

# #101 (credential-tiers P1b): re-key the LIVE session keyguard to a new passphrase, for the PROMOTE Save
# ceremony (the user chose a different/stronger pass than the throwaway they typed at login). The confined
# login daemon can't exec `cmd` (SELinux: fork/exec permission denied), but this su:s0 worker can -- same
# reason it runs dpm/pm/settz. old=pass (line 3), new=sesec (line 5, empty for a non-hardened rekey), user=uid.
# cmd needs </dev/null from su:s0 (the DIA-56 fd-passing denial); the passphrases ride argv (never captured,
# never logged), and the exit code is the signal. Handled here (root-only, no seal), before the name/uid gate.
if [ "$op" = "rekey" ]; then
  newp="$sesec"
  if [ -z "$newp" ] || [ -z "$uid" ]; then echo "ERR-ARGS" > "$RES"; chmod 600 "$RES"; exit 0; fi
  # NWP-20261116-17: user 0 is the gate, whose keyguard the provisioner disables; a credential there is never a session's.
  case "$uid" in *[!0-9]*|0?*) echo "[roamd] rekey: bad uid $(date)" >> "$LOG"; echo "ERR-UID" > "$RES"; chmod 600 "$RES"; exit 0;; esac
  [ "$uid" -ge 10 ] || { echo "[roamd] rekey: uid under 10 refused $(date)" >> "$LOG"; echo "ERR-UID" > "$RES"; chmod 600 "$RES"; exit 0; }
  # Preserve the credential TYPE (see armcred): an all-numeric new credential must be a PIN (set-pin), else the
  # numeric gate can't enter it. A non-digit anywhere -> set-password.
  case "$newp" in *[!0-9]*) _kscmd=set-password ;; *) _kscmd=set-pin ;; esac
  # Two-rung ladder: the session keyguard is armed on the FIRST SCREEN-OFF (L1 sCredArmer), so a user who
  # goes straight from login to Save has NO credential yet -- set-* with --old fails there ("no old
  # credential to match"; the on-device #101 failure). Try the no-credential form first; when a credential
  # IS set that form fails and the --old form takes over.
  if cmd lock_settings "$_kscmd" --user "$uid" "$newp" </dev/null >/dev/null 2>&1; then
    echo "[roamd] rekey user $uid OK (no prior credential) $(date)" >> "$LOG"
    echo "OK" > "$RES"
  elif cmd lock_settings "$_kscmd" --old "$pass" --user "$uid" "$newp" </dev/null >/dev/null 2>&1; then
    echo "[roamd] rekey user $uid OK (re-keyed from old) $(date)" >> "$LOG"
    echo "OK" > "$RES"
  else
    echo "[roamd] rekey user $uid FAILED $(date)" >> "$LOG"
    echo "ERR-REKEY" > "$RES"
  fi
  chmod 600 "$RES"; exit 0
fi

# #81: enroll a FIDO2 security key as a 2FA factor on the live session's stored profile. The confined login
# daemon can't open /dev/hidraw (SELinux); this su:s0 worker can. USB host mode must be forced (the FP3 does
# NOT auto-OTG) and the key needs ~2s to settle after re-enumeration (else CTAP2 0x27). The agent does
# makeCredential + getAssertion (the user touches the key) + writes the fido2 slot (managed-mode paid).
if [ "$op" = "fido2-enroll" ]; then
  [ -n "$name" ] && [ -n "$pass" ] || { echo "ERR-ARGS" > "$RES"; chmod 600 "$RES"; exit 0; }
  # Multi-key (DIA-20260704-35): adding a SECOND key needs the vault opened via the ALREADY-enrolled key's
  # login-cached hmac (the pass slot is gone on a 2FA vault) -- export the stash so the agent's openVaultDK
  # finds it. Harmless on a first enroll (no stash / pass slot opens).
  [ -f "$STATE/.fido2hmac" ] && export NOWHERE_FIDO2_HMAC="$(cat "$STATE/.fido2hmac")"
  usb_host on; sleep 2
  if "$AGENT" fido2-enroll s3 "$name" "$(pw "$pass")" >> "$LOG" 2>&1; then
    print -r -- "[roamd] fido2-enroll OK for $(qn "$name") $(date)" >> "$LOG"; echo "OK" > "$RES"
  else
    print -r -- "[roamd] fido2-enroll FAILED for $(qn "$name") $(date)" >> "$LOG"; echo "ERR-ENROLL" > "$RES"
  fi
  usb_host off
  chmod 600 "$RES"; exit 0
fi

# NWP-20261111-04 (Q016): the stranded phone's "Use your security key" -- ADOPT-FIDO2 from the session's own chooser.
# A key enrolled on ANOTHER handset dropped the head's pass slot, so this live session can no longer seal. Assert the
# plugged key over USB (host mode + ~2s settle, as fido2-enroll); the agent's fido2-adopt prints the hmac ONLY when it
# opens a fido2 slot of the CURRENT stored head, and stages the non-secret slot spec as .fido2slots.pre only then.
# Success adopts it the way the `in` commit arm does: the hmac to the 0600 tmpfs stash (print -rn --, NEVER printf --
# the #106 note in the fido2hmac op below), the spec promoted for cold lock's marker. A FAILED adopt must not cost the
# session what it had: .fido2hmac and .fido2slots stay exactly as they were (unlike the cold re-assert, which purges),
# and only a .pre this attempt did not prove is removed. The passphrase rides @file:; nothing secret is logged.
if [ "$op" = "fido2adopt" ]; then
  [ -n "$name" ] && [ -n "$pass" ] || { echo "ERR-ARGS" > "$RES"; chmod 600 "$RES"; exit 0; }
  usb_host on; sleep 2
  H="$("$AGENT" fido2-adopt s3 "$name" "$(pw "$pass")" "$STATE" 2>> "$LOG")"
  usb_host off
  if [ -n "$H" ]; then
    print -rn -- "$H" > "$STATE/.fido2hmac"; chmod 600 "$STATE/.fido2hmac"
    [ -f "$STATE/.fido2slots.pre" ] && mv "$STATE/.fido2slots.pre" "$STATE/.fido2slots" 2>> "$LOG"
    print -r -- "[roamd] fido2adopt OK for $(qn "$name") $(date)" >> "$LOG"; echo "OK" > "$RES"
  else
    rm -f "$STATE/.fido2slots.pre" 2>> "$LOG"
    print -r -- "[roamd] fido2adopt FAILED for $(qn "$name") $(date)" >> "$LOG"; echo "ERR-NOKEY" > "$RES"
  fi
  chmod 600 "$RES"; exit 0
fi

# Cold-resume key re-assert (#81 resume gap, DIA-20260704-34): cold-lock PURGED the session's hmac stash (a
# cold device holds no key material), so resuming a key-protected session requires the PHYSICAL key again --
# host mode, one touch, re-stash for the resumed session's seals. The daemon recomputes the derived cold
# credential from the typed pass + this hmac; no/wrong key -> ERR-NOKEY and the CE stays cold. The pass is
# NEVER logged; the hmac goes only to the 0600 tmpfs stash.
if [ "$op" = "fido2hmac" ]; then
  [ -n "$name" ] || { echo "ERR-ARGS" > "$RES"; chmod 600 "$RES"; exit 0; }
  # NWP-20261017-03: THE MARKER IS THE ONLY SOURCE, and this op never touches the typed entry. handleResume
  # sends a fixed non-secret placeholder in $pass, because the entry is not proven yet: it is only proven by
  # coldResumeProof AFTER this assert, so an entry that was a stranger's guess must reach nothing -- not this
  # request file, not a .pw stage, not a head ref sent to the store. The slot spec is line 7 of the cold-lock
  # marker (NWP-20260823-09): the NON-SECRET credId:salt list the cold-lock teardown copied from the session's
  # slot stash, which every login stages and every enrol and removal keeps in step (syncFido2SlotsStash). So the assert needs
  # no profile lookup at all, which is also why a PIN resume works: it has no passphrase to resolve a head with.
  # Read the MARKER DIRECTLY (NWP-20260823-12): a plain 0600 text file this worker owns, no probe verb to skew.
  # A spec always contains ':' (b64credId:b64salt) and no whitespace; anything else is no spec.
  # The legacy `fido2-hmac s3 <name> <pass>` fallback that used to sit beneath this (NWP-20260823-10, for a marker
  # whose spec no longer matched the vault) is GONE from this op: it staged the entry in a .pw file and sent head
  # refs derived from it to the store. handleResume refuses a marker with no usable spec before it gets here,
  # and a spec that no longer opens the vault answers NOKEY like any wrong key. (The login `in` op keeps its own
  # fido2-hmac call: there the passphrase is the user's claim to a profile, not a guess at a parked session.)
  SPEC="$(sed -n 7p "$STATE/.coldlock" 2>/dev/null)"
  case "$SPEC" in *[[:space:]]*|"") SPEC="" ;; *:*) ;; *) SPEC="" ;; esac
  H=""
  if [ -n "$SPEC" ]; then
    usb_host on; sleep 2
    H="$("$AGENT" fido2-hmac-cold "$STATE" 2>> "$LOG")"
    usb_host off
  fi
  if [ -n "$H" ]; then
    # DIA-20260812-03 (#106): print -rn --, NOT printf. printf is an external binary on Android, so the old
    # line put the FIDO2 HMAC -- the SECOND vault factor for a 2FA profile -- into a process argv, i.e. into
    # world-readable /proc/<pid>/cmdline. The hmac is deterministic per (credId,salt) and is deliberately
    # cached for reuse by every later seal, so capturing it once yields the factor the physical key exists to
    # withhold, with no key touch ever again. -n keeps this byte-identical to printf '%s' (no newline);
    # -r stops the value being escape-mangled. The comment 12 lines up claims "the hmac goes only to the 0600
    # tmpfs stash" -- with printf that was not true, and now it is.
    print -rn -- "$H" > "$STATE/.fido2hmac"; chmod 600 "$STATE/.fido2hmac"
    echo "[roamd] resume fido2 re-assert OK $(date)" >> "$LOG"; echo "OK" > "$RES"
  else
    rm -f "$STATE/.fido2hmac"
    echo "[roamd] resume fido2 re-assert NOKEY $(date)" >> "$LOG"; echo "ERR-NOKEY" > "$RES"
  fi
  chmod 600 "$RES"; exit 0
fi

# ev_probe UID: the cold-lock eviction probe (DIA-20260816-05), shared since NWP-20261004-01 by dropcaches (at the
# lock) and evictcheck (after vold's retry window). A locked user's /data holds only ENCRYPTED filenames, so a name
# that RESOLVES proves the CE is still decrypted, and a CE SQLite file that still starts with its plaintext magic
# proves the same for that file:
#   (a) /data/user/<uid>/android resolving at all
#   (b) accounts_ce.db starting with the plaintext SQLite magic
# Prints the paths that are still readable, or nothing.
ev_probe() {
  local _b="" _a="/data/system_ce/$1/accounts_ce.db"
  ls -d "/data/user/$1/android" >/dev/null 2>&1 && _b="$_b /data/user/$1/android"
  # No separate [ -r ] test: dd prints nothing for a file it cannot read, which is the same answer, and one
  # reader is one thing for test-evict-verdict.sh to stand in for.
  if [ "$(dd if="$_a" bs=6 count=1 2>/dev/null)" = "SQLite" ]; then
    _b="$_b $_a(PLAINTEXT)"
  fi
  echo "$_b"
}

# ev_verdict UID SETTLE: one token for the eviction state of UID's CE.
#   OK EVICTED                 nothing readable
#   OK EVICTED settled         the first probe saw something, a re-check SETTLE seconds later saw nothing
#   ERR-EVICT-INCOMPLETE <p>   still readable; <p> is the paths
#   ERR-EVICT-PROBE <why>      THE PROBE CANNOT SEE, so it proves nothing either way
#
# ⚠⚠ NWP-20261004-01: A PROBE THAT CANNOT SEE IS NOT A PROBE THAT FOUND NOTHING. Both checks in ev_probe fail
# OPEN -- a missing dd, a denied read, an ls this domain may not run all print nothing, which is exactly what
# "evicted" prints. Since NWP-20261004-01 the answer also decides whether a session is WIPED (evictcheck), so a
# blind "OK EVICTED" is no longer a wrong log line, it is a wrong decision. So run the SAME two primitives
# against user 0 first, whose CE is unlocked for as long as the phone is on: the control MUST see both, or the
# verdict is "cannot tell", never "evicted".
ev_verdict() {
  local _uid="$1" _settle="$2" _ctl _ev1 _ev2
  _ctl=$(ev_probe 0)
  case "$_ctl" in
    *"/data/user/0/android"*"/data/system_ce/0/accounts_ce.db(PLAINTEXT)"*) : ;;
    *) echo "ERR-EVICT-PROBE the control saw [${_ctl# }] of user 0's CE, which is unlocked"; return 0 ;;
  esac
  _ev1=$(ev_probe "$_uid")
  _ev2="$_ev1"
  if [ -n "$_ev1" ] && [ "${_settle:-0}" -gt 0 ]; then
    sleep "$_settle"               # let an in-flight eviction finish before calling it a failure
    _ev2=$(ev_probe "$_uid")
  fi
  if [ -n "$_ev2" ]; then echo "ERR-EVICT-INCOMPLETE$_ev2"
  elif [ -n "$_ev1" ]; then echo "OK EVICTED settled"
  else echo "OK EVICTED"; fi
}

# Cold-lock cache flush (P3, DIA-20260625-13): after the chooser STOPs a user (CE key evicted), drop the kernel
# dentry/inode cache so even a POWERED-ON locked device is immediately ciphertext -- a stopped user's already-
# cached inodes stay readable from RAM until dropped. Root-only; no name/uid, so handled before the arg check.
# NWP-20261005-23 (the plaintext-email P0, part 2 of 2): PARK a cold-locked session's accounts_de.db in the RAM
# tmpfs for the lock, and put it back at resume. /data/system_de/<uid> is under the SYSTEM's DE key, so the account
# names in that file (the identity's Google email, a phone-number-shaped WhatsApp account) were readable on a
# locked phone (NWP-20260913-13). In the tmpfs they leave persistent storage and die at power-off; while the phone
# runs they are in RAM, the same class as the account snapshot system_server keeps (Chester: "memory is fine").
#
# ⚠⚠ ONLY WITH endospore-ams-stopped-user-snapshot.sh IN THE IMAGE. Without it SyncManager rebuilds the stopped
# user's accounts from DE 236 ms after every stop (NWP-20261005-20), so a parked file comes back EMPTY, and at resume
# AccountManagerService deletes the CE accounts as removed-while-locked: the session signs out of everything. The
# gate reads the patch's own log literal out of services.jar, beside a control literal that every build carries, so
# a grep that cannot read the jar refuses too (fail closed both ways; measured on lynx: 283 ms).
DE_PARK_ROOT="$STATE/coldde"
DE_SYS_ROOT="${DE_SYS_ROOT:-/data/system_de}"                   # overridable for test-coldlock-de-park.sh only
DE_JAR="${DE_JAR:-/system/framework/services.jar}"
_de_park_ok() {
  local _j="$DE_JAR"
  grep -a -q "onUserStopped " "$_j" 2>/dev/null || return 2                                   # control
  grep -a -q "stopped-user snapshot dropped (NWP-20261005-22)" "$_j" 2>/dev/null || return 1  # the patch
  return 0
}
# de_park <uid>: move accounts_de.db (+ -wal/-shm) into the tmpfs. Copy, sync, compare, then remove -- a failure at
# any step leaves the file where it was (a leak, never a loss). The removal is read back: a file still in DE logs
# "could NOT be removed", keeps the park and returns 1 (NWP-20261127-09).
de_park() {
  local _u="$1" _src="$DE_SYS_ROOT/$1" _dst="$DE_PARK_ROOT/$1" _f _n=0 _k=0
  [ -f "$_src/accounts_de.db" ] || { echo "[roamd] coldlock-de-park: user $_u has no accounts_de.db $(date)" >> "$LOG"; return 0; }
  _de_park_ok; case $? in
    0) : ;;
    1) echo "[roamd] coldlock-de-park: NOT parked, user $_u -- the AMS snapshot patch is not in this image $(date)" >> "$LOG"; return 0 ;;
    *) echo "[roamd] coldlock-de-park: NOT parked, user $_u -- services.jar unreadable (control missing) $(date)" >> "$LOG"; return 0 ;;
  esac
  rm -rf "$_dst" 2>/dev/null
  ( umask 077; mkdir -p "$_dst" ) 2>>"$LOG" || { echo "[roamd] coldlock-de-park: FAILED mkdir, user $_u $(date)" >> "$LOG"; return 1; }
  for _f in accounts_de.db accounts_de.db-wal accounts_de.db-shm; do
    [ -e "$_src/$_f" ] || continue
    cp -a "$_src/$_f" "$_dst/$_f" 2>>"$LOG" && cmp -s "$_src/$_f" "$_dst/$_f" \
      || { rm -rf "$_dst"; echo "[roamd] coldlock-de-park: FAILED copy of $_f, user $_u -- left in place $(date)" >> "$LOG"; return 1; }
    _n=$((_n + 1))
  done
  sync
  rm -f "$_src/accounts_de.db" "$_src/accounts_de.db-wal" "$_src/accounts_de.db-shm" 2>>"$LOG"
  for _f in accounts_de.db accounts_de.db-wal accounts_de.db-shm; do   # NWP-20261127-09: read the removal back
    if [ -e "$_src/$_f" ] || [ -L "$_src/$_f" ]; then _k=$((_k + 1)); fi
  done
  [ "$_k" -eq 0 ] || { echo "[roamd] coldlock-de-park: user $_u -- $_k file(s) could NOT be removed from DE: the account names stay on disk (a copy is parked in RAM) $(date)" >> "$LOG"; return 1; }
  echo "[roamd] coldlock-de-park: user $_u accounts_de parked in RAM ($_n file(s)) $(date)" >> "$LOG"
}
# de_unpark <uid>: put a parked file back, owner and label as the account roam's
# own restore does (acct_reload's chown system:system and restorecon).
# Returns non-zero when a parked file could not be restored -- the resume must then NOT start the user, because a
# start without its DE file builds an empty one and deletes the CE accounts. No parked dir = nothing to do (0).
de_unpark() {
  local _u="$1" _src="$DE_PARK_ROOT/$1" _dst="$DE_SYS_ROOT/$1" _f
  [ -d "$_src" ] || return 0
  [ -f "$_src/accounts_de.db" ] || { rm -rf "$_src"; return 0; }
  rm -f "$_dst/accounts_de.db" "$_dst/accounts_de.db-wal" "$_dst/accounts_de.db-shm" 2>>"$LOG"  # anything recreated meanwhile
  for _f in accounts_de.db accounts_de.db-wal accounts_de.db-shm; do
    [ -e "$_src/$_f" ] || continue
    cp -a "$_src/$_f" "$_dst/$_f" 2>>"$LOG" && cmp -s "$_src/$_f" "$_dst/$_f" \
      || { echo "[roamd] coldlock-de-unpark: FAILED to restore $_f, user $_u -- parked copy kept $(date)" >> "$LOG"; return 1; }
  done
  chown system:system "$_dst/"accounts_de.db* 2>>"$LOG"; restorecon "$_dst/"accounts_de.db* 2>>"$LOG"
  sync
  rm -rf "$_src"
  echo "[roamd] coldlock-de-unpark: user $_u accounts_de restored $(date)" >> "$LOG"
}
# Cleanup is the reap's (cleanstorage removes "$DE_PARK_ROOT/<uid>"), and the tmpfs dies at power-off. NOT at a
# sign-in: a sign-in that fails can leave the parked session resumable (the open "A fresh sign-in over a cold-locked
# session ..." row), and resuming it with its file gone would build an empty one and delete its accounts.

if [ "$op" = "dropcaches" ]; then
  # #84 P3d: detach mediad's dead FUSE overlays + binds, so a resume-restart or the 12h wipe's removeUser never
  # trips over a defunct mountpoint. Since NWP-20261004-01 the teardown sweeps BEFORE the stop (coldsweep), so
  # this normally finds nothing; it stays as the backstop for a sweep that left something behind.
  stop_mediad
  sync
  echo 3 > /proc/sys/vm/drop_caches 2>> "$LOG"
  echo "[roamd] drop_caches $(date)" >> "$LOG"
  # DIA-20260816-05 (amnesia audit fix 8): VERIFY THE EVICTION, do not assume it.
  #
  # The premise "a stopped user's CE key is gone" is what the comment above asserts and what the docs
  # repeated. It is NOT always true: the audit found /data/system_ce/<uid>/accounts_ce.db still beginning
  # with the plaintext `SQLite` magic on a COLD-LOCKED session, readable as root, because
  # FS_IOC_REMOVE_ENCRYPTION_KEY reports "some files are still in use" when AccountManagerService is holding
  # its per-user DB open across stopUser. That file is exactly where acct_seal/acct_restore roam real Google
  # account rows, so the mechanism matters more than the byte count on any one device.
  #
  # Two probes, both free, using the technique the `verify` op below already relies on -- a locked user's
  # /data holds only ENCRYPTED filenames, so a name that RESOLVES proves the CE is still decrypted:
  #   (a) /data/user/<uid>/android resolving at all
  #   (b) accounts_ce.db starting with the plaintext SQLite magic
  # The probe does not FIX the eviction. The framework side is endospore-accountsdb-close-ce.sh
  # (NWP-20261004-01), which closes AccountManagerService's CE handle at the stop; the probe is what proves it
  # on each lock, and evictcheck below is what acts when it did not.
  _ev=""
  case "$uid" in ''|*[!0-9]*) : ;; *)
    if [ "$uid" -ge 10 ]; then
      # DIA-20260816-09: probe TWICE, seconds apart, and report only what SURVIVES both.
      #
      # Measured on lynx 2026081602: the first cut fired at 12:02:21 and flagged BOTH
      # /data/user/<uid>/android and accounts_ce.db. Re-checked by hand at 12:03:19, /data/user/<uid> had
      # become properly encrypted while accounts_ce.db was still plaintext. So the directory-tree eviction is
      # ASYNCHRONOUS and had simply not finished when the probe ran -- even though the chooser's
      # isUserUnlocked poll had already returned false and it had logged "drop_caches after CE-evict".
      # A single-shot probe therefore reports a false positive on /data/user/<uid> at EVERY cold-lock, and a
      # check that cries wolf every time is a check nobody reads -- which would bury the one finding that is
      # real.
      #
      # WHAT IS REAL, and why this probe still earns its place: accounts_ce.db stays plaintext indefinitely
      # (the audit found it on a long-cold-locked session too). The framework says evicted; the file says
      # otherwise. isUserUnlocked is NOT a trustworthy signal for "this session's data is now at rest", and
      # nothing else on the device was checking.
      _ev=$(ev_verdict "$uid" 5)
      case "$_ev" in
        ERR-EVICT-INCOMPLETE*)
          echo "[roamd] EVICT-INCOMPLETE user $uid -- CE STILL readable 5s after stopUser:${_ev#ERR-EVICT-INCOMPLETE} $(date)" >> "$LOG" ;;
        ERR-EVICT-PROBE*)
          echo "[roamd] EVICT-PROBE-BLIND user $uid -- proves nothing: ${_ev#ERR-EVICT-PROBE } $(date)" >> "$LOG" ;;
        "OK EVICTED settled")
          echo "[roamd] evict ok (settled): user $uid -- the first probe saw a readable CE, clear on re-check $(date)" >> "$LOG" ;;
        *)
          echo "[roamd] evict ok: user $uid CE not readable after stopUser (the control read user 0's) $(date)" >> "$LOG" ;;
      esac
      # DIA-20260816-08 (amnesia audit fix 9): clear the cold-locked session's DE CLEARTEXT.
      #
      # /data/system/users/<uid> is NOT under the per-user CE key -- it lives under the SYSTEM's DE key, which
      # is always available. So while a session sits cold-locked (the device's normal resting state under the
      # resumable model), these files are readable plaintext to anyone holding the powered-off phone, even
      # though the CE half is properly encrypted. The reap clears them, but the reap only runs when the
      # session ENDS; cold-lock is the session CONTINUING, and that window is measured in hours or days.
      #
      # ⚠ settings_ssaid.xml IS DELIBERATELY NOT IN THIS LIST, and must not be added.
      # It carries the profile's cross-device SSAID userkey -- "the very thing that makes an app present the
      # same device identity across a roam" (see the reap classifier's own note). #210 exists precisely
      # because without it every app saw a brand-new device each login and device-bound sessions (Amazon MAP
      # et al.) dropped. Deleting it here would resume the session SIGNED OUT OF EVERYTHING. The audit's
      # wording was "seal or clear"; only the seal half is safe for that file, and sealing it is a larger
      # change that has to restore on resume -- tracked separately, not smuggled in here.
      #
      # What IS cleared, and what it costs:
      #   app_idle_stats.xml   which packages this identity used and when (76 KB measured). Pure telemetry;
      #                        the framework rebuilds its standby buckets. No user-visible cost.
      #   inputmethod/         the keyboard and its languages (German + French were found on lynx). Costs the
      #                        session its keyboard-language preference on resume -- a real but small
      #                        regression, taken deliberately because the languages a person types in are a
      #                        strong identifying signal.
      for _de in app_idle_stats.xml inputmethod; do
        _dep="/data/system/users/$uid/$_de"
        if [ -e "$_dep" ]; then
          rm -rf "$_dep" 2>> "$LOG"
          if [ -e "$_dep" ]; then echo "[roamd] coldlock-de: FAILED to clear $_dep $(date)" >> "$LOG"
          else echo "[roamd] coldlock-de: cleared $_dep $(date)" >> "$LOG"; fi
        fi
      done
      de_park "$uid"   # NWP-20261005-23: the account names, out of DE for the lock (gated on the AMS patch)
    fi
  ;; esac
  # NWP-20261004-01: reply with the verdict rather than a bare OK. Still "OK"-prefixed when the CE is not
  # readable and for the uid-less form, so a reader that only looks for OK sees no change there.
  echo "${_ev:-OK}" > "$RES"; chmod 600 "$RES"; exit 0
fi

# NWP-20261004-01: the eviction RE-CHECK, after vold has given up. When FS_IOC_REMOVE_ENCRYPTION_KEY finds files in
# use it removes the key from the keyring but keeps the busy inodes decryptable, and vold retries the clean-up
# at 3.2/9.6/22.4/48/99.2 s before giving up for good ("Waiting for files to close never completed",
# device-measured on lynx 2026-10-04 with system_server holding accounts_ce.db). dropcaches probes ~5 s after the
# stop, inside that window, so its EVICT-INCOMPLETE can still clear on its own. This is the same probe AFTER the
# window: whatever it finds now is what stays. Root-only, uid but no name, so handled before the arg check like
# dropcaches. The DAEMON decides what follows (EVICT-RECHECK), because only it knows whether the session's last
# save landed.
if [ "$op" = "evictcheck" ]; then
  case "$uid" in ''|*[!0-9]*|0?*) echo "ERR-UID" > "$RES"; chmod 600 "$RES"; exit 0;; esac
  [ "$uid" -ge 10 ] || { echo "ERR-UID" > "$RES"; chmod 600 "$RES"; exit 0; }
  sync
  echo 3 > /proc/sys/vm/drop_caches 2>> "$LOG"
  _ev=$(ev_verdict "$uid" 0)
  echo "[roamd] evictcheck user $uid: $_ev $(date)" >> "$LOG"
  echo "$_ev" > "$RES"; chmod 600 "$RES"; exit 0
fi

# NWP-20261005-23: put a cold-locked session's parked accounts_de.db back, at resume, BEFORE the user is started.
# The daemon calls this only after `verify` has accepted the entry -- never on the proof alone, which would make the
# op a timing oracle that skips the keyguard's throttling. OK = restored or nothing parked; anything else = the user
# must not be started. uid only, so before the arg check like evictcheck.
if [ "$op" = "deunpark" ]; then
  case "$uid" in ''|*[!0-9]*|0?*) echo "ERR-UID" > "$RES"; chmod 600 "$RES"; exit 0;; esac
  [ "$uid" -ge 10 ] || { echo "ERR-UID" > "$RES"; chmod 600 "$RES"; exit 0; }
  if de_unpark "$uid"; then echo "OK" > "$RES"; else echo "ERR-UNPARK" > "$RES"; fi
  chmod 600 "$RES"; exit 0
fi
# Cold-lock RESUME credential check (P4, DIA-20260625-13): verify the typed credential against a COLD-LOCKED
# user's keyguard so the gate can resume it (verify-BEFORE-switch is what avoids the keyguard-timeout crash when
# switching into a stopped user). Uses uid but no name/profile, so handled before the name/uid arg check. The
# credential is NEVER logged.
#
# ⚠⚠ NWP-20260924-01: `ls` IS NOT PROOF. This op used `ls -d /data/user/<uid>/android` as its ground truth and
# threw away cmd's exit status. `ls` says the CE is decrypted NOW, not that the credential was right -- and the
# CE stays readable in the window before eviction, and indefinitely under EVICT-INCOMPLETE, so ANY credential
# passed. (The old header's "the caller drop_caches'd at cold-lock, so a stale RAM cache can't fake it" is
# contradicted by the dropcaches op's own EVICT-INCOMPLETE probes.) The exit status IS readable under /dev/null
# stdio -- only cmd's OUTPUT is blocked (DIA-56); rekey and armcred already branch on it. So accept only when
# the keyguard says yes (rc 0), or when a CE that was COLD before the verify is readable after it (the
# transition is caused by the credential, whatever rc says). The agent sends only entries it has already proven
# against the marker, or random decoys. This op NEVER clears the credential: that is `resumeclear`, below, which
# the agent runs only after the resume has committed (see that op for why).
if [ "$op" = "verify" ]; then
  case "$uid" in ''|*[!0-9]*|0?*) echo "ERR-UID" > "$RES"; chmod 600 "$RES"; exit 0;; esac
  [ "$uid" -ge 10 ] || { echo "ERR-UID" > "$RES"; chmod 600 "$RES"; exit 0; }
  _pre=0; ls -d "/data/user/$uid/android" >/dev/null 2>&1 && _pre=1
  cmd lock_settings verify --old "$pass" --user "$uid" </dev/null >/dev/null 2>/dev/null; _vrc=$?
  _post=0; ls -d "/data/user/$uid/android" >/dev/null 2>&1 && _post=1
  if [ "$_vrc" = 0 ] || { [ "$_pre" = 0 ] && [ "$_post" = 1 ]; }; then
    echo "OK" > "$RES"; echo "[roamd] resume verify user $uid OK (rc=$_vrc pre=$_pre post=$_post) $(date)" >> "$LOG"
  else
    echo "FAIL" > "$RES"; echo "[roamd] resume verify user $uid FAIL (rc=$_vrc pre=$_pre post=$_post) $(date)" >> "$LOG"
  fi
  chmod 600 "$RES"; exit 0
fi

# Cold-lock RESUME, step 2 (NWP-20260924-01): REMOVE the lockscreen credential so the resume's switch lands
# straight on HOME with a SINGLE entry, instead of re-prompting on user N's own keyguard (the double-prompt). The
# chooser re-arms the credential on the next screen-off, exactly like a fresh login. `clear` needs the CE
# unlocked, which the verify did. It is its OWN op, run by the agent only AFTER the resume has committed: done
# inside `verify`, a verify that succeeded but whose resume never committed left a parked .coldlock on a user
# with no credential and a readable CE, where no retry could pass the verify again. The credential is NEVER
# logged.
if [ "$op" = "resumeclear" ]; then
  case "$uid" in ''|*[!0-9]*|0?*) echo "ERR-UID" > "$RES"; chmod 600 "$RES"; exit 0;; esac
  [ "$uid" -ge 10 ] || { echo "ERR-UID" > "$RES"; chmod 600 "$RES"; exit 0; }
  cmd lock_settings clear --old "$pass" --user "$uid" </dev/null >/dev/null 2>/dev/null; _crc=$?
  if [ "$_crc" = 0 ]; then echo "OK" > "$RES"; else echo "FAIL" > "$RES"; fi
  echo "[roamd] resume clear user $uid rc=$_crc $(date)" >> "$LOG"
  chmod 600 "$RES"; exit 0
fi

# DIA-20260807-03: the Bluetooth block is defined HERE, ABOVE the credless `cleanstorage` handler, because
# that handler is the universal reap hook and calls bt_reset. A shell function defined further down the file is
# an UNDEFINED COMMAND at that point -- a silent no-op, not an error. This file already records that exact trap
# biting keystore_push (see the KS_CREDS note above), so it is not hypothetical. If you move this block, move it
# UP, never down.
# ---- #154 Bluetooth bond roam/wipe (gap #17) -------------------------------------------------------------
# BT bonds live DEVICE-GLOBAL in /data/misc/bluedroid (bt_config.conf = link keys + LE keys; bt_remote_dev_info
# = cached name/class), NOT per-user. Without this they neither roam with a profile nor clear between same-boot
# sessions -- the next user (and the gate) inherits the previous user's paired devices (power-off wipes /data,
# but the mid-boot gate/next-login would still see them). We snapshot this session's per-remote [MAC] sections
# at each seal into the roamed user's CE dir (so they seal + roam with the profile), re-lay THIS profile's
# sections at login (clearing any leftover first), and WIPE them at logoff -- reloading the stack each time so
# it re-reads the files. su:s0 reads/writes bluetooth_data_file + drives cmd bluetooth_manager, and dumpsys
# capture works in this context (cf. the `dumpsys user` call above); no sepolicy change on this dev su:s0 build.
# (A future enforcing endospore_priv migration would need bluetooth_data_file + bluetooth service grants.)
# DIA-20260807-01: REWRITTEN, because as shipped none of this ran. #154 was developed and proven on a userdebug
# lynx where the workers were still su:s0 PERMISSIVE; the endospore_priv migration then went out WITHOUT the
# bluetooth grants the comment above asks for by name. Under enforcing, roamd cannot stat /data/misc/bluedroid,
# so the old work probe ([ -f ] on files it cannot see) found nothing to do, took the do-nothing return, and the
# caller logged "bt bonds wiped at logoff" -- inert in BOTH directions, announcing success, on every build we
# ship. Three changes follow from that, and from what the device says (verified on lynx 2026-08-07):
#
#  1. FAIL CLOSED. "I cannot see any bonds" must never read as "there are no bonds". Every step is verified, the
#     result IS the return value, and the callers log what happened rather than what was attempted.
#  2. WIPE BY DELETING, not by editing. A missing file is rebuilt empty by the stack, so a delete's failure mode
#     is "no bonds"; an edit's failure modes are a half-written config, a section the glob missed, and a stack
#     that had not finished shutting down flushing its in-memory copy back over the top. Deleting the directory
#     also reaches what nobody enumerated -- lynx keeps interop_database_dynamic.conf right beside the two files
#     BT_FILES names.
#  3. ROAM WHOLE FILES, not [MAC] sections. A config carrying only [Info] plus device sections yields
#     `Bonded devices: 0` -- the [Adapter] block (the local identity keys) is load-bearing. Section-surgery only
#     ever worked because it left the device's own [Adapter] in place, which a delete-based wipe does not.
#     Copying whole files also takes the INI parser out of the amnesia path entirely.
#
# Clearing at BOTH ends of a session is deliberate: a session that ended without a clean logoff cannot then hand
# its bonds to the next person, and after a verified clear at login anything in these files belongs to THIS
# session -- which is what makes the capture below self-attributing without tracking who owns what.
BT_DIR=/data/misc/bluedroid
# The Bluetooth app is singleUser + directBootAware, so its stores live in user 0 and serve whichever user is in
# the foreground: per-remote-device metadata, and an OPP transfer history naming every file ever sent or
# received over BT. Device-global residue exactly like bluedroid -- and all three paths carry the SAME label
# (u:object_r:bluetooth_data_file:s0, checked on lynx), so one sepolicy type covers them.
BT_APP_DIRS="/data/user_de/0/com.android.bluetooth /data/user/0/com.android.bluetooth"
BT_FILES="bt_config.conf bt_remote_dev_info.conf"   # the two we ROAM; the wipe deletes everything present
# DIA-20260807-05: the device NAME is not in bt_config.conf -- its [Adapter] block has no Name field (checked on
# lynx). It lives in user-0 settings, so deleting bluedroid does not touch it and `cmd bluetooth_manager enable`
# re-stamps it straight back from there. Whatever the departing user typed in Settings > Device name is otherwise
# left visible to the next user AND broadcast to every peer this phone pairs with. Both keys matter: Bluetooth
# reads `secure bluetooth_name`, and `global device_name` is what the Device name UI writes and what Bluetooth
# (and Cast, Wi-Fi Direct) fall back to.
#
# ⚠ NWP-20260902-06: THIS COMMENT USED TO SAY "deleting them returns the model default". IT DOES NOT. A UI
# surface substitutes the model, but a direct Settings.Global.getString("device_name") reads back NULL --
# measured on lynx for user 0 AND for a roamed user. So the wipe left a HOLE where every app looking up a
# device name found nothing, and one very common lookup pattern turns that hole into a CRASH:
#
#     Settings.Global.getString("device_name")      -> null here, because we deleted it
#     Settings.Secure.getString("bluetooth_name")   -> SecurityException: readable only at targetSdk <= 31
#     Build.MODEL                                   -> the app's own safe fallback, NEVER REACHED
#
# The middle call throws instead of returning null, so the app's third tier is unreachable and the exception
# escapes Application.onCreate. Found by decompiling the American Express app (7.32.2, targetSdk 35) after it
# died at launch on lynx with exactly that stack; the pattern is generic, so this was breaking an unknown
# number of apps, not one.
#
# So we now SET these to the model default instead of deleting them. Amnesia is unchanged -- every profile
# reads the same generic string and nothing a departing user typed survives -- and it leaks nothing, because
# it is the identical value the app's own last-resort tier would have used and any app can read Build.MODEL
# directly. It also makes the sentence above true rather than aspirational.
BT_NAME_KEYS="secure:bluetooth_name global:device_name"

# The generic name every profile sees. Never a per-user value, never anything a user typed.
bt_default_name() {
  local _m
  _m=$(getprop ro.product.model 2>/dev/null)
  [ -n "$_m" ] || _m="Android"
  printf '%s' "$_m"
}
# ⚠ NEVER send a cmd/settings/dumpsys stderr to $LOG. `cmd` hands its stdio FDs to system_server over binder,
# and system_server has no access to nowhere_data_file -- so `2>>"$LOG"` makes the kernel deny system_server an
# `append` on our log and the WHOLE CALL FAILS, silently and with empty stderr. Device-proven on lynx
# 2026-08-07: `avc: denied { append } for comm="cmd" path="/data/nowhere/roam.log" scontext=system_server`.
# Diagnosing this cost two build-flash-test rounds, because the redirect that broke the call was the one added
# to capture the error it would have reported. Use 2>/dev/null and check the EXIT STATUS, like every other
# cmd call in this file already does.

# The adapter state, tolerantly parsed and VALIDATED against the states that exist. The old exact-two-space sed
# made a denied or absent dumpsys indistinguishable from a live adapter: it printed nothing, `[ "" = OFF ]` was
# false, and the code concluded "BT is up" and edited the config under a stack it had never asked to stop.
bt_state() { dumpsys bluetooth_manager 2>/dev/null | sed -n 's/^[[:space:]]*State:[[:space:]]*//p' | head -1; }
_bt_state_ok() {
  case "$1" in ON|OFF|TURNING_ON|TURNING_OFF|BLE_ON|BLE_TURNING_ON|BLE_TURNING_OFF) return 0;; *) return 1;; esac
}
# Wait for the adapter to REACH OFF; non-zero on timeout or on an unreadable state. bluedroid owns the config in
# memory and flushes it on its own timer and at shutdown, so touching the files before OFF can be silently undone.
_bt_wait_off() {
  local _i=0; local _bad=0; local _s
  while [ $_i -lt 60 ]; do
    _s=$(bt_state)
    [ "$_s" = OFF ] && return 0
    if _bt_state_ok "$_s"; then _bad=0; else _bad=$((_bad+1)); [ $_bad -ge 3 ] && return 1; fi
    sleep 0.2; _i=$((_i+1))
  done
  return 1
}

# Snapshot this session's Bluetooth state into the roamed user's CE dir so it seals + roams with the profile.
# $1=USERDIR. An UNREADABLE bluedroid leaves the profile's existing artifacts ALONE: the old code read "I could
# not open the device file" as "the user unpaired everything" and deleted them -- and because capture is the
# first step of the seal, that deletion rode the very next push into the store, dropping a profile's pairings
# permanently within a couple of minutes of login.
# NWP-20260914-04: roam the navigation mode (3-button vs gestural). It is NOT a setting -- it is which RRO in
# category com.android.internal.navigation_bar_mode is enabled FOR THE USER, persisted as per-user rows in the
# device-global /data/system/overlays.xml, which is in no Nowhere scope and which OMS purges on removeUser.
# So every login fell back to config_navBarInteractionMode, and the complaint MIRRORS across editions:
# GrapheneOS patched that default to gestural (aa95a028f15d), LineageOS keeps AOSP 3-button -- an Endospore
# user loses 3-button, a Diaspore user loses gestural. A tester reported the first on 2026-09-14.
#
# CAPTURE HERE, AT SEAL TIME, AND NOWHERE ELSE. A cold lock -- explicit or idle -- performs NO seal
# (main.go handleColdLock), so what the store holds after either cold lock is the LAST PERIODIC SEAL. The
# value therefore has to be in the sealed tree at that moment, which means capturing it at the top of every
# `out` op is the only design that covers all three exits (logoff, explicit cold lock, idle cold lock). The
# chooser alternatives were checked and rejected: capturePrefs() runs only inside doLogoff(), the idle path
# never enters ProfileActivity, and no chooser component is guaranteed alive in the roamed user at change
# time. Eager capture buys nothing over seal-time capture because the seal is the only moment the value
# can leave the device -- the same argument #151 already made for the alarm relay.
#
# WHAT IS READ: the SystemUI mirror `Secure.navigation_mode` (0 = 3-button, 1 = 2-button, 2 = gestural),
# which NavigationModeController writes into the CURRENT user table whenever the mode resolves. Do NOT read
# /data/system/overlays.xml -- it is binary ABX on this Android (Xml.resolveSerializer). `settings get` from
# this domain already works and is captured at bt_seal_restore above (the </dev/null is DIA-20260807-06).
#
# WHERE IT IS WRITTEN: a roamd-owned SIBLING file in the chooser CE dir, next to the bt-bond-* files, so it
# seals into the vault exactly as they do. Deliberately NOT a `nav=` line in nowhere-prefs: ProfileActivity
# setPref() rewrites that file WHOLE from a fixed enumeration and destroys any key it does not know -- the
# #159 incident -- and NWP-20260914-09 has the general question open. A sibling file cannot be eaten.
#
# SUPERSEDED for the EMPTY read (NWP-20261108-17): once this session's apply has marked, an empty read KEEPS the
# record; a malformed one still removes it. The original rule: a read that yields nothing REMOVES the file rather
# than leaving a stale one: a failed capture must never turn into a forced mode at the next login.
#
# ⚠ NOT BEFORE THIS SESSION'S APPLY (NWP-20261108-17). The capture runs at the top of EVERY `out`, periodic seals
# included, and a brand-new user's Secure rows are unset until the `grant` op's nav_apply makes the profile's mode
# the live one. The sync loop holds periodic seals only for the login window, which SELF-EXPIRES at 180 s
# (loginWindowCap) and closes 15 s after GRANT-PERMS (loginWindowTail); GRANT-PERMS itself waits for the
# PackageInstaller commits, and a chooser that dies before it never sends it. A sign-in whose installs outlast the
# window therefore got a periodic seal that read the empty row, removed the record and sealed that: the choice was
# lost for good. So nothing is captured until nav_apply has marked $STATE/.navapplied.<uid> (the `in` op clears it,
# keyed by uid, so a recycled uid never inherits one; a cold-lock resume keeps it: same boot, same uid). Before
# the marker the record is left byte for byte. COST: nothing to capture before this session's grant -- the user is
# not in front yet.
#
# THE EMPTY READ ALONE IS NOT SAFE EVEN AFTER THE MARKER. The mirror is written for the CURRENT user only, so it
# stays empty from nav_apply until after the switch-in, which the chooser queues after applyRoamedPrefs and
# ensureRoamedHomeRole, while the login window closes 15 s after GRANT-PERMS. An empty read after the marker is
# therefore "not resolved yet", and keeps the record. So does a read of `null`, which is what `settings get` prints
# for a row never set (vpn_seal_capture and bt_seal_restore treat it the same way). A malformed read still clears;
# a valid one writes.
nav_seal_capture() {
  local _bd="$1/com.nowhere.chooser/files"; local _uid="$2"; local _v; local _out="$_bd/nowhere-nav"
  [ -d "$_bd" ] || return 0
  if [ ! -e "$STATE/.navapplied.$_uid" ]; then
    echo "[roamd] nav: not applied yet this session for user $_uid -> the profile's record is kept (NWP-20261108-17) $(date)" >> "$LOG"
    return 0
  fi
  _v=$(settings get --user "$_uid" secure navigation_mode </dev/null 2>/dev/null)
  case "$_v" in
    0|1|2)
      if printf "%s\n" "$_v" > "$_out.tmp" 2>>"$LOG"; then
        mv -f "$_out.tmp" "$_out" 2>>"$LOG"; chmod 600 "$_out" 2>/dev/null
      else
        rm -f "$_out.tmp" 2>/dev/null
        echo "[roamd] nav: could not write capture for user $_uid $(date)" >> "$LOG"
      fi ;;
    ""|null)
      echo "[roamd] nav: no mode resolved yet for user $_uid -> the profile's record is kept (NWP-20261108-17) $(date)" >> "$LOG" ;;
    *)
      # Malformed. Remove any stale capture so the next login lands on the EDITION default, which is what a
      # fresh user gets anyway.
      rm -f "$_out" "$_out.tmp" 2>/dev/null
      echo "[roamd] nav: no readable mode for user $_uid (got '$_v') -- capture cleared, edition default $(date)" >> "$LOG" ;;
  esac
  return 0
}

# nav_pkg_for <mode> -> the overlay package for that mode, or "" when this image ships no overlay for it.
# BOTH editions build only the 3-button and gestural overlays; 2-button exists in source but in no product
# Nowhere runs (it is referenced only by the goldfish emulator product). The file test is against the APK the
# build actually laid down, so a future edition that drops one degrades to "edition default", never to a
# broken enable-exclusive. Split out so a test can pin the mapping without a device.
nav_pkg_for() {
  case "$1" in
    0) [ -f "${NAV_OVERLAY_ROOT:-/product/overlay}/NavigationBarMode3Button/NavigationBarMode3ButtonOverlay.apk" ] \
         && printf "%s" "com.android.internal.systemui.navbar.threebutton" ;;
    2) [ -f "${NAV_OVERLAY_ROOT:-/product/overlay}/NavigationBarModeGestural/NavigationBarModeGesturalOverlay.apk" ] \
         && printf "%s" "com.android.internal.systemui.navbar.gestural" ;;
  esac
  return 0
}

# nav_apply <uid>: enable the captured mode for the freshly created user. Runs in the `grant` op -- AFTER
# install-existing (the overlay packages are pre-installed into a FULL secondary user by
# preinstalled-packages-platform-overlays.xml, so they exist for the new uid) and BEFORE the switch-in, so
# SystemUI resolves the right mode on its first paint. No file, or a mode this image has no overlay for ->
# do NOTHING: a fresh user already resolves config_navBarInteractionMode, and forcing a mode would erase the
# Diaspore/Endospore default difference that is each product own choice. Resume needs no re-apply -- a
# stopped user keeps its overlay rows.
#
# `cmd overlay` as ROOT is allowed by OverlayActorEnforcer before any package or permission check, so no
# CHANGE_OVERLAY_PACKAGES and no chooser-side change. The SELinux gate is separate and is the one thing that
# can make this a SILENT no-op on an enforcing user build: endospore_priv needs
# `overlay_service:service_manager find` (added in this slice) -- the same silent-under-enforcing shape AGENTS.md
# records for `dumpsys user` in seed_home. cmd stdio -> /dev/null (the su:s0 fd denial),
# so the exit status is the only signal -- it is logged either way, because a line that only appears on
# success is indistinguishable from the feature not existing.
#
# NWP-20261108-17: it marks $STATE/.navapplied.<uid> on "no capture" and "applied" (the live mode IS now the
# profile's), and NOT on "no overlay on this image" (the record names a mode this image cannot apply, so it is
# kept) nor on a failed enable-exclusive (the live mode is not the profile's). nav_seal_capture waits for it.
nav_apply() {
  local _uid="$1"; local _f="${NAV_USER_ROOT:-/data/user}/$_uid/com.nowhere.chooser/files/nowhere-nav"; local _v; local _pkg
  [ -f "$_f" ] || { ( : > "$STATE/.navapplied.$_uid" ) 2>>"$LOG"; chmod 600 "$STATE/.navapplied.$_uid" 2>/dev/null; echo "[roamd] nav: no capture for user $_uid -> edition default $(date)" >> "$LOG"; return 0; }
  _v=$(head -c 4 "$_f" 2>/dev/null | tr -cd "0-9")
  _pkg=$(nav_pkg_for "$_v")
  if [ -z "$_pkg" ]; then
    echo "[roamd] nav: captured mode '$_v' has no overlay on this image -> edition default $(date)" >> "$LOG"
    return 0
  fi
  if cmd overlay enable-exclusive --user "$_uid" --category "$_pkg" </dev/null >/dev/null 2>&1; then
    ( : > "$STATE/.navapplied.$_uid" ) 2>>"$LOG"; chmod 600 "$STATE/.navapplied.$_uid" 2>/dev/null
    echo "[roamd] nav: applied mode $_v ($_pkg) for user $_uid $(date)" >> "$LOG"
  else
    echo "[roamd] nav: enable-exclusive FAILED for user $_uid mode $_v ($_pkg) -- on an enforcing build this is the overlay_service find (NWP-20260914-04) $(date)" >> "$LOG"
  fi
  return 0
}

# #46/#131: this is the FIRST of two HOME pins (the chooser's ensureRoamedHomeRole is the second, and logs to logcat only),
# so roam.log -- the log an issue report carries -- must say whether THIS one landed: the status is logged either way.
home_pin() {
  local _uid="$1"; local _rc=0
  cmd package set-home-activity --user "$_uid" com.android.launcher3/com.android.launcher3.uioverrides.QuickstepLauncher </dev/null >/dev/null 2>&1 || _rc=$?
  if [ "$_rc" = 0 ]; then
    echo "[roamd] pinned launcher3 as user $_uid home $(date)" >> "$LOG"
  else
    echo "[roamd] home pin FAILED for user $_uid (rc=$_rc) -- HOME now rests on the gate's #131 role pin alone (#46) $(date)" >> "$LOG"
  fi
  return 0
}

# NWP-20260922-02: the per-profile ALWAYS-ON DISPLAY preference. Chester: "AOD (always on display)
# doesnt roam."
#
# WHY IT CANNOT JUST BE CARRIED. Every login mints a BRAND-NEW Android user whose Secure settings table
# starts empty, and /data/system/users/<uid> is in NONE of the six roam pushes -- roamd's only references
# to settings_secure.xml are reaps (see the orphan cleanup above, which names it as residue to rm -rf). So
# there is nothing to extend: the carry has to be an explicit capture-and-re-apply into the chooser's CE
# dir, which rides the vault push for free. Same shape as the navigation mode (NWP-20260914-04) and the
# BT bonds (#154), and this is a deliberate clone of the former.
#
# Deliberately a SIBLING FILE, not an `aod=` line in nowhere-prefs: ProfileActivity setPref() rewrites
# that file WHOLE from a fixed enumeration and destroys any key it does not know -- the #159 incident.
#
# ⚠ CAPTURE AT SEAL TIME, NOT IN capturePrefs() -- and the reason has TWO halves. An earlier draft of this
# comment carried only the first, which rules capturePrefs OUT without putting this site IN:
#   (1) capturePrefs() has exactly ONE call site, inside doLogoff(), so an IDLE cold lock -- which never
#       enters ProfileActivity at all -- would silently never capture.
#   (2) A cold lock, explicit or idle, performs NO SEAL OF ITS OWN. main.go's handler says so in its own
#       words: "No seal (the periodic sync already backed it up)". So what the store holds after a cold
#       lock is whatever the LAST PERIODIC SEAL captured -- and the periodic seal runs THIS SAME `out` op
#       ("worker op=out ... (a BACKGROUND periodic seal)"), every syncIntervalDefault = 120 s. Coverage of
#       cold lock is therefore INDIRECT, via the periodic seal, and bounded by that interval.
#
# ⚠ THE RESIDUAL, STATED RATHER THAN LEFT IMPLIED: a change made inside the last interval before a cold
# lock that is never resumed never reaches the store -- roughly two minutes of exposure. That is the same
# limit every other capture on this path carries, but it is a real one, not a rounding error.
#
# A read that yields nothing REMOVES the file rather than leaving a stale one: a failed capture must never
# turn into a forced mode at the next login.
#
# ⚠ NOT BEFORE THIS SESSION'S APPLY (NWP-20261108-17). The rule above holds only once aod_apply has made the
# profile's value the live row. Until then a brand-new user's row is unset, and a periodic seal reading it removed
# the record and sealed that. The sync loop holds periodic seals only for the login window, which SELF-EXPIRES at
# 180 s (loginWindowCap) and closes 15 s after GRANT-PERMS (loginWindowTail); GRANT-PERMS waits for the
# PackageInstaller commits, and a chooser that dies before it never sends it. So nothing is captured until
# aod_apply has marked $STATE/.aodapplied.<uid> (the `in` op clears it, keyed by uid, so a recycled uid never
# inherits one; a cold-lock resume keeps it: same boot, same uid). Before the marker the record is left byte for
# byte. Unlike navigation, "empty clears" stays after the marker: aod_apply's put makes the live row the
# profile's at once. COST: nothing to capture before this session's grant -- the user is not in front yet.
aod_seal_capture() {
  local _bd="$1/com.nowhere.chooser/files"; local _uid="$2"; local _v; local _out="$_bd/nowhere-aod"
  [ -d "$_bd" ] || return 0
  if [ ! -e "$STATE/.aodapplied.$_uid" ]; then
    echo "[roamd] aod: not applied yet this session for user $_uid -> the profile's record is kept (NWP-20261108-17) $(date)" >> "$LOG"
    return 0
  fi
  _v=$(settings get --user "$_uid" secure doze_always_on </dev/null 2>/dev/null)
  case "$_v" in
    0|1)
      if printf "%s\n" "$_v" > "$_out.tmp" 2>>"$LOG"; then
        mv -f "$_out.tmp" "$_out" 2>>"$LOG"; chmod 600 "$_out" 2>/dev/null
      else
        rm -f "$_out.tmp" 2>/dev/null
        echo "[roamd] aod: could not write capture for user $_uid $(date)" >> "$LOG"
      fi ;;
    *)
      # Empty (the row was never written -- a session that never touched the setting) or malformed. Remove
      # any stale capture so the next login lands on the DEVICE default, which is what a fresh user gets.
      rm -f "$_out" "$_out.tmp" 2>/dev/null
      echo "[roamd] aod: no readable setting for user $_uid (got '$_v') -- capture cleared, device default $(date)" >> "$LOG" ;;
  esac
  return 0
}

# NWP-20261102-06 (Q148, docs/product-decisions.md 2026-10-20): the profile's LAST TIME ZONE. The ipinfo.io tier is
# dropped; the zone is saved at sign-out and applied at the next sign-in as a SEED with auto-detection on, never an
# override. A new profile, a throwaway and an offline sign-in have none and get the baked default.
#
# ⚠ A SIBLING FILE, NEVER A nowhere-prefs KEY. The 2026-10-10 account-sync decision forbids adding keys to
# nowhere-prefs for captured state: setPref rewrites that file whole from a fixed enumeration (#159). So "the
# profile's sealed prefs" is built as a sibling in the same sealed CE dir, exactly as aod_seal_capture does.
#
# Captured at SEAL time for aod's two reasons (a cold lock does no seal of its own; the periodic seal runs this
# same `out`). Read from persist.sys.timezone, which AlarmManager writes synchronously (see settz). A read that
# yields nothing valid REMOVES the file, so a failed capture never becomes a stale zone on the next login.
# Nothing here logs the zone: it is coarse location.
tz_zone_ok() {
  local _z="$1"
  [ -n "$_z" ] && [ "${#_z}" -le 64 ] || return 1
  case "$_z" in
    [!A-Za-z]*|*[!A-Za-z0-9_+/-]*|*//*|*/) return 1 ;;
  esac
  return 0
}

tz_seal_capture() {
  local _bd="$1/com.nowhere.chooser/files"; local _out="$_bd/nowhere-lasttz"; local _v
  [ -d "$_bd" ] || return 0
  _v=$(getprop persist.sys.timezone </dev/null 2>/dev/null)
  if tz_zone_ok "$_v"; then
    if printf '%s\n' "$_v" > "$_out.tmp" 2>>"$LOG"; then
      mv -f "$_out.tmp" "$_out" 2>>"$LOG"; chmod 600 "$_out" 2>/dev/null
    else
      rm -f "$_out.tmp" 2>/dev/null
      echo "[roamd] lasttz: could not write capture $(date)" >> "$LOG"
    fi
  else
    rm -f "$_out" "$_out.tmp" 2>/dev/null
    echo "[roamd] lasttz: no valid zone read -- capture cleared, next sign-in gets the baked default $(date)" >> "$LOG"
  fi
  return 0
}

# Roam-in: add the captured zone to the prefs.out surfaced from nowhere-prefs, as one `lasttz=` line. Same check as
# the capture, so a corrupt roamed file is not handed to the gate. Offline sign-in's empty prefs.out stays empty.
tz_surface() {
  local _f="$1/com.nowhere.chooser/files/nowhere-lasttz"; local _p="$2"; local _z=""
  [ -f "$_f" ] || return 0
  _z=$(head -n 1 "$_f" 2>/dev/null | head -c 80)
  tz_zone_ok "$_z" || { echo "[roamd] lasttz: capture is malformed -- not surfaced $(date)" >> "$LOG"; return 0; }
  [ -s "$_p" ] && [ -n "$(tail -c 1 "$_p" 2>/dev/null)" ] && printf '\n' >> "$_p"
  printf 'lasttz=%s\n' "$_z" >> "$_p" 2>>"$LOG"
  return 0
}

# NWP-20261130-12 (Q012, #70, docs/product-decisions.md 2026-10-20 and 2026-10-22): THE CURATED PER-USER SETTINGS ROAM.
# The allowlist is /system/etc/nowhere/settings-roam.list. The chooser reads the same file: a later slice adds a row
# there, not code. Its first row is the Quick Settings tile list, Secure sysui_qs_tiles.
#
# ⚠ A SIBLING FILE, NEVER nowhere-prefs KEYS: setPref rewrites that file whole from a fixed enumeration (#159).
# ⚠ CAPTURED AT SEAL TIME, for aod_seal_capture's two reasons: a cold lock does no seal of its own, and the periodic
# seal runs `out` too. Roamd captures here. The chooser is the one writer at sign-in (#70), through the live provider.
# ⚠ NOT BEFORE THIS SESSION'S APPLY (the NWP-20261108-17 class). After switch-in SystemUI can write its default list to
# the live row, and a seal would then replace the profile's record for good. So the chooser sets the session's Secure
# row nowhere_sroam_applied only after an apply with no failed put and no malformed value, and until then this capture
# keeps the record byte for byte. A new user's Secure table starts empty, so a recycled uid cannot inherit the row.
# ⚠ LOGS CARRY COUNTS ONLY. A tile list names installed apps. Do not copy aod_seal_capture's (got '$_v') text.
# ⚠ A VALUE MOVES ONLY AS A QUOTED "$v". A class name can hold $ and a waiting tile starts with ?: never use a value as
# a printf format, in a sed or grep expression, in eval, or unquoted outside the merge's own split.
sroam_list_path() {
  printf '%s\n' "${SROAM_LIST:-/system/etc/nowhere/settings-roam.list}"
}

# sroam_row_ok <scope> <key> <kind> <extra>: the list's row grammar. SettingsRoam.parseList holds the same rule.
sroam_row_ok() {
  case "$1" in secure|system) ;; *) return 1 ;; esac
  case "$2" in ''|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_]*) return 1 ;; esac
  case "$3" in ''|tiles) ;; *) return 1 ;; esac
  [ -z "$4" ]
}

# sroam_tiles_valid <value>: the tile value set. SettingsRoam.tilesValid is the same set, and test-settings-roam.sh's
# P1 compares the two for every printable ASCII character. The pattern stays in a single-quoted variable and the label
# expands it unquoted: written in the label, $- expands to the shell's flags and a bare ( or ) breaks the parse. The
# alphabet has no ranges, because a range depends on the locale. - stays last, because anywhere else it can form a range.
sroam_tiles_valid() {
  local _bad='*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_./(),$-]*'
  [ -n "$1" ] || return 1
  case "$1" in $_bad) return 1 ;; esac
  [ "${#1}" -le 8192 ]
}

# sroam_record_line <record> <scope> <key>: the record's line for that row, byte for byte, or nothing.
sroam_record_line() {
  local _l
  [ -f "$1" ] || return 0
  while IFS= read -r _l || [ -n "$_l" ]; do
    case "$_l" in "$2 $3 "*) printf '%s\n' "$_l"; return 0 ;; esac
  done < "$1"
  return 0
}

# sroam_merge_tiles <live> <annotated>: stdout is <live> plus each tile the annotated list (the nowhere_sroam_tiles row)
# marks ? and <live> lacks. A waiting tile goes after the nearest stored tile before it that is live, else first. A
# refused input prints nothing and returns 1. The split runs in a subshell, so IFS and set -f do not leak.
sroam_merge_tiles() {
  local _live="$1" _ann="$2" _plain="" _t _w _x _r _last=""
  sroam_tiles_valid "$_live" || return 1
  [ -n "$_ann" ] || { printf '%s\n' "$_live"; return 0; }
  (
    set -f; IFS=,
    for _t in $_ann; do _plain="$_plain${_plain:+,}${_t#\?}"; done
    sroam_tiles_valid "$_plain" || exit 1
    for _t in $_ann; do
      [ -n "$_t" ] || continue
      _w=${_t#\?}
      case ",$_live," in
        *",$_w,"*) _last=$_w ;;
        *)
          [ "$_w" != "$_t" ] || continue
          if [ -z "$_last" ]; then
            _live="$_w,$_live"
          else
            _r=""
            for _x in $_live; do
              _r="$_r${_r:+,}$_x"
              [ "$_x" != "$_last" ] || _r="$_r,$_w"
            done
            _live=$_r
          fi
          _last=$_w ;;
      esac
    done
    sroam_tiles_valid "$_live" || exit 1
    printf '%s\n' "$_live"
  )
}

# Seal: one line for each row on the list, `<scope> <key> <value>`, in the sealed CE dir. A row with no usable live value
# carries its old line. A row no longer on the list leaves the record. Called from `out`, beside the other captures.
sroam_seal_capture() {
  local _bd="$1/com.nowhere.chooser/files"; local _uid="$2"; local _out="$_bd/nowhere-settings-roam"
  local _list _s _k _kd _x _v _ann _m _old _new="" _rows=0 _got=0 _kept=0 _ref=0 _nl='
'
  [ -d "$_bd" ] || return 0
  _list=$(sroam_list_path)
  [ -r "$_list" ] || { echo "[roamd] settings-roam: no readable list -> the profile's record is kept $(date)" >> "$LOG"; return 0; }
  _v=$(settings get --user "$_uid" secure nowhere_sroam_applied </dev/null 2>/dev/null)
  if [ "$_v" != 1 ]; then
    echo "[roamd] settings-roam: not applied this session for user $_uid -> the profile's record is kept $(date)" >> "$LOG"
    return 0
  fi
  while read -r _s _k _kd _x || [ -n "${_s:-}" ]; do
    sroam_row_ok "$_s" "$_k" "$_kd" "$_x" || continue
    _rows=$((_rows+1))
    _v=$(settings get --user "$_uid" "$_s" "$_k" </dev/null 2>/dev/null)
    case "$_v" in
      ''|null|*"$_nl"*) _v="" ;;
      *)
        if [ "$_kd" = tiles ]; then
          _ann=$(settings get --user "$_uid" secure nowhere_sroam_tiles </dev/null 2>/dev/null)
          [ "$_ann" != null ] || _ann=""
          if _m=$(sroam_merge_tiles "$_v" "$_ann") && [ -n "$_m" ]; then _v=$_m; else _v=""; _ref=$((_ref+1)); fi
        fi ;;
    esac
    if [ -n "$_v" ]; then
      _new="$_new$_s $_k $_v$_nl"; _got=$((_got+1))
    else
      _old=$(sroam_record_line "$_out" "$_s" "$_k")
      if [ -n "$_old" ]; then _new="$_new$_old$_nl"; _kept=$((_kept+1)); fi
    fi
  done < "$_list"
  if [ "$_rows" -eq 0 ]; then
    echo "[roamd] settings-roam: the list has no usable row -> the profile's record is kept $(date)" >> "$LOG"
    return 0
  fi
  if [ -n "$_new" ] || [ -f "$_out" ]; then
    if printf '%s' "$_new" > "$_out.tmp" 2>>"$LOG"; then
      mv -f "$_out.tmp" "$_out" 2>>"$LOG"; chmod 600 "$_out" 2>/dev/null
    else
      rm -f "$_out.tmp" 2>/dev/null
      echo "[roamd] settings-roam: could not write capture for user $_uid $(date)" >> "$LOG"
    fi
  fi
  echo "[roamd] settings-roam: seal user $_uid rows=$_rows captured=$_got carried=$_kept refused=$_ref $(date)" >> "$LOG"
  return 0
}

# Roam-in: add each listed record row to the prefs.out surfaced from nowhere-prefs, as one `sroam=` line. It does not
# check the value: the apply must see a malformed row, so that it can withhold nowhere_sroam_applied and keep the record.
sroam_surface() {
  local _f="$1/com.nowhere.chooser/files/nowhere-settings-roam"; local _p="$2"; local _list _s _k _kd _x _l _n=0
  [ -f "$_f" ] || return 0
  _list=$(sroam_list_path)
  [ -r "$_list" ] || return 0
  while read -r _s _k _kd _x || [ -n "${_s:-}" ]; do
    sroam_row_ok "$_s" "$_k" "$_kd" "$_x" || continue
    _l=$(sroam_record_line "$_f" "$_s" "$_k")
    [ -n "$_l" ] || continue
    [ -s "$_p" ] && [ -n "$(tail -c 1 "$_p" 2>/dev/null)" ] && printf '\n' >> "$_p"
    printf 'sroam=%s\n' "$_l" >> "$_p" 2>>"$LOG"
    _n=$((_n+1))
  done < "$_list"
  echo "[roamd] settings-roam: surfaced $_n row(s) $(date)" >> "$LOG"
  return 0
}

# Re-apply the captured preference to the freshly minted user, in `grant`, before switch-in.
#
# ⚠⚠ THIS WRITES THROUGH SettingsProvider'S BINDER, AND THAT DISTINCTION IS WHY IT WORKS. #210's two dead
# attempts wrote /data/system/users/<uid>/settings_ssaid.xml UNDERNEATH SettingsProvider, which reads a
# user's XML once and is write-only afterwards -- so both were INERT and the fix had to become a framework
# patch. `settings put --user N` is the supported path, and this tree already depends on it working
# cross-user in both directions (the reads in the captures above, and the BT name reset below).
# Do NOT "optimise" this into a file write; that is the third attempt at a known-dead idea.
#
# settings stdio -> /dev/null (the su:s0 fd denial), so the exit status is the only signal -- and it is
# logged either way, because a line that only appears on success is indistinguishable from the feature
# not existing.
#
# NWP-20261108-17: it marks $STATE/.aodapplied.<uid> on "no capture", "malformed" and "applied", and NOT on a
# failed settings put (the live row is not the profile's). aod_seal_capture waits for it.
aod_apply() {
  local _uid="$1"; local _f="${AOD_USER_ROOT:-/data/user}/$_uid/com.nowhere.chooser/files/nowhere-aod"; local _v; local _raw
  [ -f "$_f" ] || { ( : > "$STATE/.aodapplied.$_uid" ) 2>>"$LOG"; chmod 600 "$STATE/.aodapplied.$_uid" 2>/dev/null; echo "[roamd] aod: no capture for user $_uid -> device default $(date)" >> "$LOG"; return 0; }
  # ⚠ KEEP THE RAW BYTES FOR THE LOG. Sanitising first and then logging "$_v" prints an EMPTY string in the
  # malformed branch -- tr has already removed exactly the bytes that branch exists to name -- so the one
  # line whose job is diagnosing a corrupt roamed capture would say nothing about it.
  _raw=$(head -c 8 "$_f" 2>/dev/null | tr -d '\000-\010\013\014\016-\037')
  _v=$(printf '%s' "$_raw" | tr -cd "0-9")
  case "$_v" in
    0|1) ;;
    *) echo "[roamd] aod: capture for user $_uid is malformed (got '$_raw') -> device default $(date)" >> "$LOG"
       ( : > "$STATE/.aodapplied.$_uid" ) 2>>"$LOG"; chmod 600 "$STATE/.aodapplied.$_uid" 2>/dev/null; return 0 ;;
  esac
  if settings put --user "$_uid" secure doze_always_on "$_v" </dev/null >/dev/null 2>&1; then
    ( : > "$STATE/.aodapplied.$_uid" ) 2>>"$LOG"; chmod 600 "$STATE/.aodapplied.$_uid" 2>/dev/null
    echo "[roamd] aod: applied doze_always_on=$_v for user $_uid $(date)" >> "$LOG"
  else
    echo "[roamd] aod: settings put FAILED for user $_uid (doze_always_on=$_v) $(date)" >> "$LOG"
  fi
  return 0
}

# NWP-20261108-15 (Q024, docs/product-decisions.md 2026-10-20): the enabled ACCESSIBILITY SERVICES and the shortcut
# targets roam with the profile. Secure settings start empty in every new user, so a blind user's screen reader was off
# at every sign-in and the accessibility shortcut target was lost. Carried, all Secure: the colon lists
# enabled_accessibility_services, accessibility_shortcut_target_service, accessibility_button_targets and
# accessibility_qs_targets, and the flag accessibility_enabled (0/1). Put back exactly as the user set them, and never
# ON by default: a profile that never enabled one has no record, and the apply only ever adds entries.
#
# ⚠ A SIBLING FILE, NEVER nowhere-prefs KEYS (the 2026-10-10 account-sync shape): setPref() rewrites nowhere-prefs WHOLE
# from a fixed enumeration and destroys a key it does not know (#159). The record is nowhere-a11y in the sealed chooser
# CE dir, owned by roamd alone.
#
# ⚠ CAPTURED AT SEAL TIME, for aod_seal_capture's two reasons: capturePrefs() has one call site (doLogoff), so an idle
# cold lock would never capture; and a cold lock does no seal of its own, so only the periodic seal -- this same `out` --
# covers it.
#
# ⚠ NOT BEFORE THIS SESSION'S APPLY, for vpn_seal_capture's reason: until a11y_apply has run, the live lists are the fresh
# user's EMPTY ones, and a periodic seal between the sign-in and the grant would read them and delete the record for
# good. aod_seal_capture has no such marker (NOWHERE-939 adds one), so this carry is NOT modelled on aod alone. The
# marker is $STATE/.a11yapplied.<uid>, written by a11y_apply only when every put landed or none was needed, and cleared
# by the `in` op so a recycled uid never inherits one.
#
# WHAT COUNTS AS INSTALLED. An entry is `<pkg>/<cls>`, or a bare `com.android.server.accessibility.<name>` (the
# magnification controller). AOSP stores its own shortcut features under the PSEUDO-PACKAGE com.android.server.accessibility
# (`com.android.server.accessibility/ColorInversion`; colour correction, one-handed mode, extra dim and font size too),
# which no package listing ever names: those FRAMEWORK TARGETS always count as installed. Any other entry is installed
# only when its package is in ONE `pm list packages --user` listing taken WITHOUT `-a`: with `-a` an archived on-demand
# placeholder would read as installed (the keystore sweep wants `-a` for the opposite reason).
#
# RESIDUAL: an on-demand app is an APK-less placeholder at sign-in, so its service cannot be enabled yet. The seal keeps
# its sealed entry only while the app is named in nowhere-appkeep AND is NOT installed. Once the app materialises in a
# session (by a tap, or by the AUTO sweep with no tap), the odrestore op puts this app's carried entries back
# (a11y_apply <uid> <pkg>, once per session, NWP-20261108-18) and the next seal captures them as live. Still open: a seal
# between installApks and RESTORE-ODDATA (about a minute, DIA-20260803), or after a failed put of that call, finds the
# app installed and not live and DROPS the entry, and the choice is then lost.
#
# Logs carry COUNTS and the uid only, never a package or a component: roam.log outlives sessions until log_scrub.
a11y_seal_capture() {
  local _bd="$1/com.nowhere.chooser/files"; local _uid="$2"; local _out="$_bd/nowhere-a11y"
  local _pl; local _ak; local _k; local _v; local _list; local _e; local _p; local _c; local _kind
  local _new; local _old; local _body=""; local _flag; local _any=0; local _nc=0; local _nw=0; local _nm=0
  [ -d "$_bd" ] || return 0
  if [ ! -e "$STATE/.a11yapplied.$_uid" ]; then
    echo "[roamd] a11y: not applied yet this session for user $_uid -> the profile's record is kept $(date)" >> "$LOG"
    return 0
  fi
  _pl=$(pm list packages --user "$_uid" </dev/null 2>/dev/null)
  if [ -z "$_pl" ]; then
    echo "[roamd] a11y: package listing empty for user $_uid -> the profile's record is kept $(date)" >> "$LOG"
    return 0
  fi
  _ak=$(cut -f1 "$_bd/nowhere-appkeep" 2>/dev/null)
  for _k in enabled_accessibility_services accessibility_shortcut_target_service accessibility_button_targets accessibility_qs_targets; do
    _v=$(settings get --user "$_uid" secure "$_k" </dev/null 2>/dev/null) || {
      echo "[roamd] a11y: settings read failed for user $_uid -> the profile's record is kept $(date)" >> "$LOG"
      return 0
    }
    [ "$_v" = null ] && _v=""
    _new=""
    _list=$(printf '%s' "$_v" | tr ':' '\n')
    while IFS= read -r _e; do
      [ -n "$_e" ] || continue
      _kind=bad
      case "$_e" in
        */*)
          _p=${_e%%/*}; _c=${_e#*/}
          if [ -n "$(printf '%s\n' "$_p" | grep -Ex '[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+')" ] && [ -n "$(printf '%s\n' "$_c" | grep -Ex '[A-Za-z0-9_.$]+')" ]; then
            _kind=pkg
            [ "$_p" = com.android.server.accessibility ] && _kind=fw
          fi ;;
        com.android.server.accessibility.*)
          [ -n "$(printf '%s\n' "$_e" | grep -Ex '[A-Za-z0-9_.$]+')" ] && _kind=fw ;;
      esac
      if [ "$_kind" = bad ]; then _nm=$((_nm+1)); continue; fi
      case ":$_new:" in *":$_e:"*) continue ;; esac
      _new="${_new:+$_new:}$_e"; _nc=$((_nc+1))
    done <<EOT
$_list
EOT
    # The existing record's entries for this key whose app is not installed yet and has never been tapped on demand.
    _old=$(sed -n "s/^$_k=//p" "$_out" 2>/dev/null | head -n 1 | tr ':' '\n')
    while IFS= read -r _e; do
      [ -n "$_e" ] || continue
      case "$_e" in */*) ;; *) continue ;; esac
      _p=${_e%%/*}; _c=${_e#*/}
      [ -n "$(printf '%s\n' "$_p" | grep -Ex '[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+')" ] && [ -n "$(printf '%s\n' "$_c" | grep -Ex '[A-Za-z0-9_.$]+')" ] || continue
      [ "$_p" = com.android.server.accessibility ] && continue
      [ -n "$(printf '%s\n' "$_pl" | grep -xF "package:$_p")" ] && continue
      [ -n "$(printf '%s\n' "$_ak" | grep -xF "$_p")" ] || continue
      case ":$_new:" in *":$_e:"*) continue ;; esac
      _new="${_new:+$_new:}$_e"; _nw=$((_nw+1))
    done <<EOT
$_old
EOT
    [ -n "$_new" ] && _any=1
    _body="${_body}${_k}=${_new}
"
  done
  _flag=$(settings get --user "$_uid" secure accessibility_enabled </dev/null 2>/dev/null) || {
    echo "[roamd] a11y: settings read failed for user $_uid -> the profile's record is kept $(date)" >> "$LOG"
    return 0
  }
  [ "$_flag" = 1 ] || _flag=0
  if [ "$_any" = 0 ] && [ "$_flag" != 1 ]; then
    rm -f "$_out" "$_out.tmp" 2>/dev/null
    echo "[roamd] a11y: nothing to carry for user $_uid -> capture removed $(date)" >> "$LOG"
    return 0
  fi
  _body="${_body}accessibility_enabled=$_flag
"
  if printf '%s' "$_body" > "$_out.tmp" 2>>"$LOG"; then
    mv -f "$_out.tmp" "$_out" 2>>"$LOG"; chmod 600 "$_out" 2>/dev/null
    echo "[roamd] a11y: captured for user $_uid: $_nc carried, $_nw waiting for install, $_nm malformed $(date)" >> "$LOG"
  else
    rm -f "$_out.tmp" 2>/dev/null
    echo "[roamd] a11y: could not write capture for user $_uid $(date)" >> "$LOG"
  fi
  return 0
}

# Re-apply the captured services and targets to the freshly minted user, in `grant`, before switch-in (Q024). Through
# SettingsProvider's binder (`settings put --user`), never a file write: see aod_apply for why. Each list gets the
# captured entries whose app is installed (or a framework target) UNIONED with what the user holds now, live entries
# first, and is put only when that adds an entry; a list is never overwritten, and accessibility_enabled is only ever put
# to 1, and only when the services list is non-empty, so nothing is turned on by default. settings stdio is /dev/null, so
# the exit status is the only signal. The marker is written when every put landed or none was needed, and NEVER after a
# failed put or a failed read: the seal stays guarded and the record survives to the next sign-in. An empty package
# listing is not marked either, for the same reason: a seal after it would read lists lacking an app the record names.
#
# NWP-20261108-18: `a11y_apply <uid> <pkg>`, from the odrestore op, is Q024's "each re-applied once its app is
# installed" for an ON-DEMAND app, an APK-less placeholder at grant that is installed at its tap (or by the AUTO sweep).
# It puts back only <pkg>'s captured entries, whatever a listing says (the op runs after installApks), unioned with the
# live lists like the grant; framework targets were put at grant and are not re-added. ONCE PER PACKAGE PER SESSION,
# for grant_perms_for's reason (NWP-20261025-10): AppInstallReceiver.heal sends RESTORE-ODDATA on every PACKAGE_ADDED,
# EXTRA_REPLACING included, so the op runs again at every update of the app, and a re-apply there would turn a carried
# service the user switched off this session back on before the next periodic seal refreshed nowhere-a11y. The record
# is $STATE/.a11ydone.<uid>, one package per line, cleared by the `in` op: a pkg call appends <pkg> once its puts landed
# (or there was nothing to put), and the grant appends every installed package it held an entry for, so an installed
# app's update heal adds nothing either. After a failed put or read nothing is recorded, and a later heal retries (it
# only ever adds). A pkg call never writes .a11yapplied: that marker is the grant's. Its log lines are counts too.
a11y_apply() {
  local _uid="$1"; local _only="${2:-}"; local _f="${A11Y_USER_ROOT:-/data/user}/$_uid/com.nowhere.chooser/files/nowhere-a11y"
  local _pl; local _k; local _cap; local _live; local _res; local _svc=""; local _list; local _e; local _p; local _c; local _kind
  local _added; local _cflag; local _lflag; local _nc=0; local _na=0; local _nw=0; local _nm=0; local _nf=0
  local _rec="$STATE/.a11ydone.$_uid"; local _done=""; local _mine=""; local _sin=0; local _d
  if [ -n "$_only" ] && grep -qxF -- "$_only" "$_rec" 2>/dev/null; then
    echo "[roamd] a11y: user $_uid: this app's entries already applied this session -> nothing written $(date)" >> "$LOG"
    return 0
  fi
  [ -f "$_f" ] || {
    echo "[roamd] a11y: no capture for user $_uid -> nothing to apply $(date)" >> "$LOG"
    if [ -n "$_only" ]; then
      ( umask 077; printf '%s\n' "$_only" >> "$_rec" ) 2>>"$LOG"
    else
      ( : > "$STATE/.a11yapplied.$_uid" ) 2>>"$LOG"
    fi
    return 0
  }
  # A pkg call takes no listing: the odrestore op has just installed <pkg>, and only <pkg>'s entries are considered.
  if [ -n "$_only" ]; then _pl="package:$_only"; else _pl=$(pm list packages --user "$_uid" </dev/null 2>/dev/null); fi
  if [ -z "$_pl" ]; then
    echo "[roamd] a11y: package listing empty for user $_uid -> nothing applied, record kept for the next sign-in $(date)" >> "$LOG"
    return 0
  fi
  for _k in enabled_accessibility_services accessibility_shortcut_target_service accessibility_button_targets accessibility_qs_targets; do
    _cap=$(sed -n "s/^$_k=//p" "$_f" 2>/dev/null | head -n 1)
    _live=$(settings get --user "$_uid" secure "$_k" </dev/null 2>/dev/null) || { _nf=$((_nf+1)); continue; }
    [ "$_live" = null ] && _live=""
    _res="$_live"; _added=0
    _list=$(printf '%s' "$_cap" | tr ':' '\n')
    while IFS= read -r _e; do
      [ -n "$_e" ] || continue
      _kind=bad
      case "$_e" in
        */*)
          _p=${_e%%/*}; _c=${_e#*/}
          if [ -n "$(printf '%s\n' "$_p" | grep -Ex '[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+')" ] && [ -n "$(printf '%s\n' "$_c" | grep -Ex '[A-Za-z0-9_.$]+')" ]; then
            _kind=pkg
            [ "$_p" = com.android.server.accessibility ] && _kind=fw
          fi ;;
        com.android.server.accessibility.*)
          [ -n "$(printf '%s\n' "$_e" | grep -Ex '[A-Za-z0-9_.$]+')" ] && _kind=fw ;;
      esac
      if [ "$_kind" = bad ]; then _nm=$((_nm+1)); continue; fi
      [ -z "$_only" ] || { [ "$_kind" = pkg ] && [ "$_p" = "$_only" ]; } || continue
      _nc=$((_nc+1))
      if [ "$_kind" = pkg ] && [ -z "$(printf '%s\n' "$_pl" | grep -xF "package:$_p")" ]; then _nw=$((_nw+1)); continue; fi
      [ -n "$_only" ] && [ "$_k" = enabled_accessibility_services ] && _mine="${_mine:+$_mine:}$_e"
      if [ "$_kind" = pkg ]; then case ":$_done:" in *":$_p:"*) ;; *) _done="${_done:+$_done:}$_p" ;; esac; fi
      case ":$_res:" in *":$_e:"*) continue ;; esac
      _res="${_res:+$_res:}$_e"; _added=1; _na=$((_na+1))
    done <<EOT
$_list
EOT
    if [ "$_added" = 1 ]; then
      if ! settings put --user "$_uid" secure "$_k" "$_res" </dev/null >/dev/null 2>&1; then
        _nf=$((_nf+1)); _res="$_live"; _added=0
      fi
    fi
    [ "$_k" = enabled_accessibility_services ] && _svc="$_res"
  done
  _cflag=$(sed -n 's/^accessibility_enabled=//p' "$_f" 2>/dev/null | head -n 1)
  # A pkg call turns the flag on only for one of <pkg>'s captured services that is now live: the grant already decided it
  # for the rest. "Now live", not "added by this call" (RF-001): when an earlier call's services put landed and its flag
  # put or read failed, <pkg> was not recorded and its service is already live here, and the flag must still be retried.
  # The record check above keeps a user's switch-off this session from being undone at an update heal.
  if [ -n "$_only" ]; then
    _list=$(printf '%s' "$_mine" | tr ':' '\n')
    while IFS= read -r _e; do
      [ -n "$_e" ] || continue
      case ":$_svc:" in *":$_e:"*) _sin=1 ;; esac
    done <<EOT
$_list
EOT
    [ "$_sin" = 1 ] || _svc=""
  fi
  if [ "$_cflag" = 1 ] && [ -n "$_svc" ]; then
    _lflag=$(settings get --user "$_uid" secure accessibility_enabled </dev/null 2>/dev/null) || _lflag=read-failed
    if [ "$_lflag" = read-failed ]; then
      _nf=$((_nf+1))
    elif [ "$_lflag" != 1 ]; then
      settings put --user "$_uid" secure accessibility_enabled 1 </dev/null >/dev/null 2>&1 || _nf=$((_nf+1))
    fi
  fi
  if [ "$_nf" != 0 ]; then
    echo "[roamd] a11y: settings put FAILED for user $_uid ($_nf key(s)) -> not marked, record kept $(date)" >> "$LOG"
  else
    if [ -n "$_only" ]; then _done="$_only"; else ( : > "$STATE/.a11yapplied.$_uid" ) 2>>"$LOG"; fi
    _list=$(printf '%s' "$_done" | tr ':' '\n')
    while IFS= read -r _d; do
      [ -n "$_d" ] || continue
      grep -qxF -- "$_d" "$_rec" 2>/dev/null || ( umask 077; printf '%s\n' "$_d" >> "$_rec" ) 2>>"$LOG"
    done <<EOT
$_list
EOT
  fi
  echo "[roamd] a11y: user $_uid: $_nc carried, $_na applied, $_nw waiting for install, $_nm malformed, $_nf failed puts $(date)" >> "$LOG"
  return 0
}

# NWP-20261109-15 (Q078, docs/product-decisions.md 2026-10-20): the AUTOFILL SERVICE a profile chooses roams with it.
# Secure autofill_service starts unset in every new user, so a password manager chosen as the autofill service had to
# be chosen again at every sign-in. Q078 filed it and left the carry to the building slice. The value is a component
# naming ONE package, so it is package-keyed: it stays outside the Q012 settings allowlist (which subtracts
# package-keyed grants) and takes the shape Q024 gave accessibility (a11y_seal_capture / a11y_apply above). Only
# autofill_service is carried: credential_service and credential_service_primary (Credential Manager) are not, and
# whether the primary has to roam too is the handset check's question.
#
# ⚠ A SIBLING FILE, NEVER A nowhere-prefs KEY: setPref() rewrites nowhere-prefs WHOLE from a fixed enumeration and
# destroys a key it does not know (#159). The record is nowhere-autofill in the sealed chooser CE dir, one line
# `<pkg>/<cls>`, owned by roamd alone.
#
# ⚠ CAPTURED AT SEAL TIME, for aod_seal_capture's two reasons: capturePrefs() has one call site (doLogoff), so an idle
# cold lock would never capture; and a cold lock does no seal of its own, so only the periodic seal -- this same `out`
# -- covers it.
#
# ⚠ NOT BEFORE THIS SESSION'S APPLY, for vpn_seal_capture's reason: until autofill_apply has run, the live row is the
# fresh user's UNSET one, and a periodic seal between the sign-in and the grant would read it and delete the record for
# good. The marker is $STATE/.autofillapplied.<uid>, written by autofill_apply unless its put failed or its package
# listing came back empty, and cleared by the `in` op so a recycled uid never inherits one.
#
# A failed read keeps the record (it is not evidence the user turned autofill off); a malformed value keeps it too.
# Both the live value and the record are validated WHOLE: one component, no second line. A value or record with a valid
# first line and anything after it is malformed, never cut down to its valid prefix (RF-001).
# `null` or empty removes it, EXCEPT while its app is not installed -- in ONE `pm list packages --user` listing taken
# WITHOUT `-a`, which would count an archived on-demand placeholder as installed -- and is named in nowhere-appkeep.
#
# RESIDUAL: an on-demand app is an APK-less placeholder at sign-in, so its service cannot be set yet; the seal keeps
# the record while the app is not installed and named in nowhere-appkeep. Once the app materialises in a session, the
# next seal finds it installed and not chosen, and DROPS the record: ~~the choice waits for a re-apply at the app's first
# install, the follow-on NOWHERE-941 is for accessibility.~~ *(superseded by NWP-20261112-12: the odrestore op's
# `autofill_apply <uid> <pkg>` puts the record back at that install, once per session and never over a service chosen
# this session, before the next seal reads it; accessibility's re-apply is a11y_apply's pkg mode, NWP-20261108-18.)*
#
# Logs carry outcomes and the uid only, never a package or a component: roam.log outlives sessions until log_scrub.
autofill_seal_capture() {
  local _bd="$1/com.nowhere.chooser/files"; local _uid="$2"; local _out="$_bd/nowhere-autofill"
  local _v; local _old; local _p; local _c; local _pl; local _nl='
'
  [ -d "$_bd" ] || return 0
  if [ ! -e "$STATE/.autofillapplied.$_uid" ]; then
    echo "[roamd] autofill: not applied yet this session for user $_uid -> the profile's record is kept $(date)" >> "$LOG"
    return 0
  fi
  # The whole output is kept (a sentinel stops $(...) stripping trailing newlines) and only settings' own output
  # terminator is removed, so a value with a trailing blank line reads as malformed, not as its valid first line; the
  # subshell exits with settings' status, so a failed read still keeps the record.
  _v=$(settings get --user "$_uid" secure autofill_service </dev/null 2>/dev/null; _c=$?; echo .; exit $_c) || {
    echo "[roamd] autofill: settings read failed for user $_uid -> the profile's record is kept $(date)" >> "$LOG"
    return 0
  }
  _v=${_v%.}; _v=${_v%"$_nl"}
  [ "$_v" = null ] && _v=""
  _old=$(cat "$_out" 2>/dev/null; echo .); _old=${_old%.}; _old=${_old%"$_nl"}
  if [ -n "$_v" ]; then
    case "$_v" in
      */*) _p=${_v%%/*}; _c=${_v#*/} ;;
      *) _p=""; _c="" ;;
    esac
    case "$_v" in *"$_nl"*) _p=""; _c="" ;; esac
    if [ -z "$(printf '%s\n' "$_p" | grep -Ex '[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+')" ] || [ -z "$(printf '%s\n' "$_c" | grep -Ex '[A-Za-z0-9_.$]+')" ]; then
      echo "[roamd] autofill: 1 malformed value for user $_uid -> the profile's record is kept $(date)" >> "$LOG"
      return 0
    fi
    if [ -f "$_out" ] && [ "$_v" = "$_old" ]; then
      echo "[roamd] autofill: unchanged for user $_uid $(date)" >> "$LOG"
      return 0
    fi
    if printf '%s\n' "$_v" > "$_out.tmp" 2>>"$LOG"; then
      mv -f "$_out.tmp" "$_out" 2>>"$LOG"; chmod 600 "$_out" 2>/dev/null
      echo "[roamd] autofill: captured for user $_uid $(date)" >> "$LOG"
    else
      rm -f "$_out.tmp" 2>/dev/null
      echo "[roamd] autofill: could not write capture for user $_uid $(date)" >> "$LOG"
    fi
    return 0
  fi
  # Unset now. The user turned autofill off, unless the record names an on-demand app not installed yet.
  _p=""
  case "$_old" in
    *"$_nl"*) ;;
    */*)
      _p=${_old%%/*}; _c=${_old#*/}
      { [ -n "$(printf '%s\n' "$_p" | grep -Ex '[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+')" ] && [ -n "$(printf '%s\n' "$_c" | grep -Ex '[A-Za-z0-9_.$]+')" ]; } || _p="" ;;
  esac
  if [ -n "$_p" ]; then
    _pl=$(pm list packages --user "$_uid" </dev/null 2>/dev/null)
    if [ -z "$_pl" ]; then
      echo "[roamd] autofill: package listing empty for user $_uid -> the profile's record is kept $(date)" >> "$LOG"
      return 0
    fi
    if [ -z "$(printf '%s\n' "$_pl" | grep -xF "package:$_p")" ] && [ -n "$(cut -f1 "$_bd/nowhere-appkeep" 2>/dev/null | grep -xF "$_p")" ]; then
      echo "[roamd] autofill: app not installed for user $_uid, kept for its install -> the profile's record is kept $(date)" >> "$LOG"
      return 0
    fi
  fi
  rm -f "$_out" "$_out.tmp" 2>/dev/null
  echo "[roamd] autofill: nothing to carry for user $_uid -> capture removed $(date)" >> "$LOG"
  return 0
}

# Re-apply the captured service to the freshly minted user, in `grant`, before switch-in (Q078). Through
# SettingsProvider's binder (`settings put --user`), never a file write: see aod_apply for why. Put only when the
# record is well formed and its app is installed (the same listing rule as the capture); settings stdio is /dev/null, so
# the exit status is the only signal, and it is logged either way. The marker is written on "no capture", "malformed",
# "applied" and "not installed", and NOT after a failed put or an empty package listing: the seal stays guarded and the
# record survives to the next sign-in.
#
# NWP-20261112-12: `autofill_apply <uid> <pkg>`, from the odrestore op, is Q078's carry for an ON-DEMAND app, an
# APK-less placeholder at grant that is installed at its tap (or by the AUTO sweep): without it the grant logged "waiting
# for install", nothing ever put the service, and the next seal found the app installed and not chosen and DROPPED the
# record. A pkg call puts the record only when it names <pkg> and the live value is unset: a service the user chose this
# session is never overwritten. It takes no listing (the op runs after installApks). ONCE PER PACKAGE PER SESSION, for
# a11y_apply's reason: AppInstallReceiver.heal sends RESTORE-ODDATA on every PACKAGE_ADDED, EXTRA_REPLACING included,
# and a re-apply at an update would undo a switch-off made this session. The record is $STATE/.autofilldone.<uid>, one
# package per line, mode 600, cleared by the `in` op: a pkg call appends <pkg> once its put landed or there was nothing
# to put, and the grant appends the installed package whose service it put, so that app's update heal puts nothing
# either. After a failed read or put nothing is recorded, and a later heal retries. A pkg call never writes
# .autofillapplied: that marker is the grant's.
autofill_apply() {
  local _uid="$1"; local _only="${2:-}"; local _f="${AUTOFILL_USER_ROOT:-/data/user}/$_uid/com.nowhere.chooser/files/nowhere-autofill"
  local _rec="$STATE/.autofilldone.$_uid"; local _comp; local _p; local _c; local _pl; local _v; local _nl='
'
  if [ -n "$_only" ] && grep -qxF -- "$_only" "$_rec" 2>/dev/null; then
    echo "[roamd] autofill: user $_uid: this app's service already applied this session -> nothing written $(date)" >> "$LOG"
    return 0
  fi
  if [ ! -f "$_f" ]; then
    echo "[roamd] autofill: no capture for user $_uid -> nothing to apply $(date)" >> "$LOG"
    if [ -n "$_only" ]; then
      ( umask 077; printf '%s\n' "$_only" >> "$_rec" ) 2>>"$LOG"
    else
      ( : > "$STATE/.autofillapplied.$_uid" ) 2>>"$LOG"; chmod 600 "$STATE/.autofillapplied.$_uid" 2>/dev/null
    fi
    return 0
  fi
  _comp=$(cat "$_f" 2>/dev/null; echo .); _comp=${_comp%.}; _comp=${_comp%"$_nl"}
  _p=""; _c=""
  case "$_comp" in *"$_nl"*) ;; */*) _p=${_comp%%/*}; _c=${_comp#*/} ;; esac
  if [ -z "$(printf '%s\n' "$_p" | grep -Ex '[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+')" ] || [ -z "$(printf '%s\n' "$_c" | grep -Ex '[A-Za-z0-9_.$]+')" ]; then
    echo "[roamd] autofill: capture for user $_uid is malformed -> nothing applied $(date)" >> "$LOG"
    if [ -n "$_only" ]; then
      ( umask 077; printf '%s\n' "$_only" >> "$_rec" ) 2>>"$LOG"
    else
      ( : > "$STATE/.autofillapplied.$_uid" ) 2>>"$LOG"; chmod 600 "$STATE/.autofillapplied.$_uid" 2>/dev/null
    fi
    return 0
  fi
  if [ -n "$_only" ]; then
    if [ "$_p" != "$_only" ]; then
      echo "[roamd] autofill: capture for user $_uid names another app -> nothing applied at this install $(date)" >> "$LOG"
      ( umask 077; printf '%s\n' "$_only" >> "$_rec" ) 2>>"$LOG"
      return 0
    fi
    # The capture's sentinel read: the whole output is kept and the subshell exits with settings' status.
    _v=$(settings get --user "$_uid" secure autofill_service </dev/null 2>/dev/null; _c=$?; echo .; exit $_c) || {
      echo "[roamd] autofill: settings read failed for user $_uid -> nothing applied at this install, not recorded $(date)" >> "$LOG"
      return 0
    }
    _v=${_v%.}; _v=${_v%"$_nl"}
    if [ -n "$_v" ] && [ "$_v" != null ]; then
      echo "[roamd] autofill: a service is chosen this session for user $_uid -> nothing applied at this install $(date)" >> "$LOG"
      ( umask 077; printf '%s\n' "$_only" >> "$_rec" ) 2>>"$LOG"
      return 0
    fi
    if settings put --user "$_uid" secure autofill_service "$_comp" </dev/null >/dev/null 2>&1; then
      ( umask 077; printf '%s\n' "$_only" >> "$_rec" ) 2>>"$LOG"
      echo "[roamd] autofill: applied at its install for user $_uid $(date)" >> "$LOG"
    else
      echo "[roamd] autofill: settings put at its install FAILED for user $_uid -> not recorded, a later heal retries $(date)" >> "$LOG"
    fi
    return 0
  fi
  _pl=$(pm list packages --user "$_uid" </dev/null 2>/dev/null)
  if [ -z "$_pl" ]; then
    echo "[roamd] autofill: package listing empty for user $_uid -> nothing applied, not marked, record kept for the next sign-in $(date)" >> "$LOG"
    return 0
  fi
  if [ -z "$(printf '%s\n' "$_pl" | grep -xF "package:$_p")" ]; then
    echo "[roamd] autofill: app not installed for user $_uid -> nothing applied, waiting for install $(date)" >> "$LOG"
    ( : > "$STATE/.autofillapplied.$_uid" ) 2>>"$LOG"; chmod 600 "$STATE/.autofillapplied.$_uid" 2>/dev/null
    return 0
  fi
  if settings put --user "$_uid" secure autofill_service "$_comp" </dev/null >/dev/null 2>&1; then
    ( : > "$STATE/.autofillapplied.$_uid" ) 2>>"$LOG"; chmod 600 "$STATE/.autofillapplied.$_uid" 2>/dev/null
    grep -qxF -- "$_p" "$_rec" 2>/dev/null || ( umask 077; printf '%s\n' "$_p" >> "$_rec" ) 2>>"$LOG"
    echo "[roamd] autofill: applied for user $_uid $(date)" >> "$LOG"
  else
    echo "[roamd] autofill: settings put FAILED for user $_uid -> not marked, record kept $(date)" >> "$LOG"
  fi
  return 0
}

# NWP-20261010-15: a user's ALWAYS-ON VPN and its "Block connections without VPN" choice ROAM WITH THE PROFILE
# (docs/product-decisions.md, 2026-10-10). Until this, nothing captured the live pair: the Profile picker wrote
# vpn=<pkg> with vpnlockdown always 1, and vpnup re-applied lockdown=1 at every sign-in -- so a block the user turned
# off in Settings came back ON every time, and a Settings-made always-on choice was gone.
#
# THE RECORD is a roamd-owned SIBLING FILE in the chooser CE dir, nowhere-vpn (`app=<pkg>`, `lockdown=<0|1>`),
# captured at every `out` beside the nav/AOD captures and for their reasons: a cold lock performs no seal of its own,
# so only a capture at the top of every `out` covers all three exits, and nowhere-prefs is rewritten WHOLE by
# ProfileActivity setPref(), which eats any key it does not know (the #159 incident).
#
# WHAT IS READ is the live pair the framework holds for the user -- Secure always_on_vpn_app and
# always_on_vpn_lockdown -- plus nowhere_vpn_lockdown_pending, the block vpn-lockdown-on-first-connect.sh deferred to
# the tunnel's first connection. A block pending on the always-on app is captured as ON: it is on the moment the
# tunnel connects, and vpnup carries an ON the same deferred way.
#
# ⚠ NOT BEFORE THIS SESSION'S APPLY. Until vpnup has applied the profile's choice, the live pair is the fresh user's
# EMPTY one, and capturing it would overwrite the record with "no VPN" -- every periodic seal between the login and a
# vpnup that is still retrying, or gave up, would do exactly that. So the capture runs only once vpnup has marked
# $STATE/.vpnapplied.<uid>; until then the restored record is left as it came and sealed again unchanged. The `in` op
# clears the marker for its uid, so a recycled user id never inherits one.
#
# A failed read (settings printed nothing, not even `null`) or a value that is not a package name keeps the record
# too: a failed read is not evidence the user switched the VPN off. An image with no helper (Diaspore ships none)
# captures nothing, because nothing could ever apply it there -- vpnup says so at every sign-in.
vpn_seal_capture() {
  local _bd="$1/com.nowhere.chooser/files"; local _uid="$2"; local _out="$_bd/nowhere-vpn"; local _app; local _lock
  local _pend; local _eff; local _jar="${NOWHERE_VPN_JAR:-/system_ext/framework/nowhere-vpnao.jar}"
  [ -d "$_bd" ] || return 0
  [ -f "$_jar" ] || return 0
  if [ ! -e "$STATE/.vpnapplied.$_uid" ]; then
    echo "[roamd] vpn: not applied yet this session for user $_uid -> the profile's record is kept $(date)" >> "$LOG"
    return 0
  fi
  _app=$(settings get --user "$_uid" secure always_on_vpn_app </dev/null 2>/dev/null)
  _lock=$(settings get --user "$_uid" secure always_on_vpn_lockdown </dev/null 2>/dev/null)
  _pend=$(settings get --user "$_uid" secure nowhere_vpn_lockdown_pending </dev/null 2>/dev/null)
  if [ -z "$_app" ] || [ -z "$_lock" ]; then
    echo "[roamd] vpn: settings read failed for user $_uid -> the profile's record is kept $(date)" >> "$LOG"
    return 0
  fi
  [ "$_app" = null ] && _app=""
  [ "$_pend" = null ] && _pend=""
  case "$_app" in
    *[!A-Za-z0-9._]*)
      echo "[roamd] vpn: always_on_vpn_app for user $_uid is not a package name -> the profile's record is kept $(date)" >> "$LOG"
      return 0 ;;
  esac
  _eff=0
  if [ -n "$_app" ]; then
    [ "$_lock" = 1 ] && _eff=1
    [ -n "$_pend" ] && [ "$_pend" = "$_app" ] && _eff=1
  fi
  if ! printf 'app=%s\nlockdown=%s\n' "$_app" "$_eff" > "$_out.tmp" 2>>"$LOG"; then
    rm -f "$_out.tmp" 2>/dev/null
    echo "[roamd] vpn: could not write capture for user $_uid $(date)" >> "$LOG"
    return 0
  fi
  # Unchanged is the common case at every periodic seal: keep the file (and the log) quiet.
  if cmp -s "$_out.tmp" "$_out"; then rm -f "$_out.tmp" 2>/dev/null; return 0; fi
  mv -f "$_out.tmp" "$_out" 2>>"$LOG"; chmod 600 "$_out" 2>/dev/null
  echo "[roamd] vpn: captured always-on ${_app:-none} lockdown=$_eff for user $_uid $(date)" >> "$LOG"
  return 0
}

# vpn_choice <pick> <capture> <prefs> -> "<source> <pkg, or - for none> <lockdown 0|1>": what vpnup applies. The
# first source holding a well-formed choice wins:
#   pick     nowhere-vpn-pick, written by the Profile screen's VPN picker: an explicit choice made FOR the next
#            sign-in. The capture cannot see it -- the picker does not change the live setting -- so it must win
#            over the capture of the session it was made in. vpnup consumes it once it is applied.
#   capture  nowhere-vpn, the live pair the last seal recorded (vpn_seal_capture).
#   prefs    the vpn=/vpnlockdown= lines pickers before NWP-20261010-15 wrote into nowhere-prefs, lockdown 1 unless
#            it says 0: exactly what vpnup applied before, so the first sign-in after this ships behaves as before.
#   none     nothing chosen anywhere.
# A malformed pick or capture is passed over, never half-applied.
vpn_choice() {
  local _f; local _p; local _l; local _src
  for _f in "$1" "$2"; do
    [ -f "$_f" ] || continue
    grep -q '^app=' "$_f" 2>/dev/null || continue
    _p=$(sed -n 's/^app=//p' "$_f" 2>/dev/null | head -n 1)
    _l=$(sed -n 's/^lockdown=//p' "$_f" 2>/dev/null | head -n 1)
    case "$_p" in *[!A-Za-z0-9._]*) continue ;; esac
    case "$_l" in 0|1) ;; *) continue ;; esac
    [ -n "$_p" ] || _l=0
    _src=capture; [ "$_f" = "$1" ] && _src=pick
    printf '%s %s %s\n' "$_src" "${_p:--}" "$_l"
    return 0
  done
  _p=$(sed -n 's/^vpn=//p' "$3" 2>/dev/null | head -n 1)
  _l=$(sed -n 's/^vpnlockdown=//p' "$3" 2>/dev/null | head -n 1)
  case "$_p" in *[!A-Za-z0-9._]*) _p="" ;; esac
  [ "$_l" = 0 ] || _l=1
  if [ -n "$_p" ]; then printf 'prefs %s %s\n' "$_p" "$_l"; else printf 'none - 0\n'; fi
  return 0
}

# vpn_apply <uid> -> prints ONE answer token (nothing else reaches stdout): what the `vpnup` op replies, and what the
# seal-time retry (vpn_deferred_retry) logs. #159 (DIA-20260721-05d) established + raised the roamed profile's always-on VPN here;
# NWP-20261010-15 applies the profile's OWN choice, carried across the sign-out (docs/product-decisions.md,
# 2026-10-10) -- vpn_choice picks it: the picker's pending pick, else the live pair the last seal captured, else the
# pre-slice vpn= pref. It used to be lockdown=1 at every sign-in, whatever the user had chosen.
#
#   A carried ON is applied through the VPN app's CONSENT (`defer`), so on Endospore the block arms at the tunnel's
#   first connection and a fresh session is never cut off before its tunnel is up (the 2026-09-25 decision;
#   vpn-lockdown-on-first-connect.sh). A carried OFF is an explicit setAlwaysOnVpnPackage with lockdown=0, which
#   clears any deferred block, so it sticks. Every apply is READ BACK from the settings before it answers OK: the
#   consent call returns nothing, and a call that returned proves nothing.
#
# Answers (retryVpnup stops at any OK):
#   OK APPLIED   applied and read back          OK NONE      the profile has no always-on VPN
#   OK NOHELPER  NOT applied: this image ships no helper (#122 -- this used to be a bare OK, i.e. "established")
#   OK DEFERRED  the VPN app is an on-demand app not yet opened: its data, and so its tunnel, are still held. Retrying
#                would spin until retryVpnup gives up and leave the session uncapturable; instead $STATE/.vpndeferred.<uid>
#                names the app -- $STATE is the RAM tmpfs (nowhere.rc), so the name never reaches /data and is gone at
#                power-off -- and vpn_deferred_retry applies it from the bootwake op's per-package step, which runs after
#                the app's restore (NWP-20261130-04: the Auto sweep holds the seals), with each seal as the fallback until
#                the apply lands (bounded; see there). Not from odrestore: the apply can take the helper's whole timeout
#                plus the WireGuard raise, and odrestore is what the user is waiting on. Until then nothing is captured, so
#                the profile keeps its choice -- unless the user sets a different always-on VPN in Settings meanwhile:
#                then the retry drops the deferral and the seal captures THEIR choice (vpn_deferred_retry).
#   NOTREADY     the CE restore, the provisioned app or its tunnel config has not landed, or the read-back missed
# APPLIED and NONE mark $STATE/.vpnapplied.<uid>, which is what lets this session's seals capture the live pair.
vpn_apply() {
  local _uid="$1"; local _ud="${VPN_USER_ROOT:-/data/user}/$_uid"; local _vf; local _pick; local _c
  local _src; local _r; local _pkg; local _lock
  _vf="$_ud/com.nowhere.chooser/files"
  if [ ! -f "$_vf/nowhere-prefs" ] || ! grep -q "^locale=" "$_vf/nowhere-prefs" 2>/dev/null; then
    printf 'NOTREADY'; return 0                 # nowhere-prefs not restored yet: the CE dir has not landed
  fi
  _pick=$(cat "$_vf/nowhere-vpn-pick" 2>/dev/null)   # what is consumed below, compared before it is removed
  _c=$(vpn_choice "$_vf/nowhere-vpn-pick" "$_vf/nowhere-vpn" "$_vf/nowhere-prefs")
  _src=${_c%% *}; _r=${_c#* }; _pkg=${_r%% *}; _lock=${_r#* }
  [ "$_pkg" = - ] && _pkg=""
  if [ -z "$_pkg" ]; then
    [ "$_src" = pick ] && vpn_pick_consume "$_vf" "$_pick"   # the picker's Off is in effect
    rm -f "$STATE/.vpndeferred.$_uid" 2>/dev/null
    ( : > "$STATE/.vpnapplied.$_uid" ) 2>>"$LOG"
    echo "[roamd] always-on VPN: none for user $_uid (from $_src) $(date)" >> "$LOG"
    printf 'OK NONE'; return 0
  fi
  if [ -d "$_ud/com.nowhere.chooser/.nowhere-odhold/$_pkg" ]; then
    # The choice itself is kept, so the seal-time retry applies exactly THIS carry and never a pick made since.
    printf '%s %s %s\n' "$_pkg" "$_lock" "$_src" > "$STATE/.vpndeferred.$_uid" 2>>"$LOG"
    echo "[roamd] always-on VPN -> $_pkg deferred for user $_uid (from $_src): an on-demand app not opened yet; applied when it materialises $(date)" >> "$LOG"
    printf 'OK DEFERRED'; return 0
  fi
  vpn_apply_choice "$_uid" "$_src" "$_pkg" "$_lock" "$_pick"
}

# vpn_apply_choice <uid> <source> <pkg> <lockdown> <the pick's content when the choice was made> -> one answer token,
# as vpn_apply. The apply proper, for a choice already made: by vpn_apply at sign-in, or by vpn_deferred_retry for the
# choice a sign-in deferred.
vpn_apply_choice() {
  local _uid="$1"; local _src="$2"; local _pkg="$3"; local _lock="$4"; local _pick="$5"
  local _ud="${VPN_USER_ROOT:-/data/user}/$_uid"; local _vf; local _jar; local _wg=""; local _mode; local _out; local _app
  local _ld; local _pd; local _ok=no
  _vf="$_ud/com.nowhere.chooser/files"; _jar="${NOWHERE_VPN_JAR:-/system_ext/framework/nowhere-vpnao.jar}"
  [ "$_pkg" = com.wireguard.android ] && { _wg=$(ls "$_ud/com.wireguard.android/files/"*.conf 2>/dev/null | head -1); [ -n "$_wg" ] && _wg=$(basename "$_wg" .conf); }
  if [ ! -d "$_ud/$_pkg" ] || { [ "$_pkg" = com.wireguard.android ] && [ -z "$_wg" ]; }; then
    printf 'NOTREADY'; return 0                 # VPN app not install-existing'd / its tunnel config not restored yet
  fi
  if [ ! -f "$_jar" ]; then
    # #122: this answered a bare "OK" -- read by retryVpnup as established -- for work it never did, and logged
    # nothing. Still an OK (retrying cannot make a helper appear), but one that says so, and a log line.
    echo "[roamd] always-on VPN -> $_pkg NOT applied for user $_uid (from $_src): this image ships no helper $(date)" >> "$LOG"
    printf 'OK NOHELPER'; return 0
  fi
  _mode=0; [ "$_lock" = 1 ] && _mode=defer
  cmd appops set --user "$_uid" "$_pkg" ACTIVATE_VPN allow </dev/null >/dev/null 2>&1
  # The helper's OWN stdout (app_process, not cmd -> no system_server fd handoff, safe to capture), bounded. The
  # always-on call fails while the VPN app is only CE-RESTORED but not yet install-existing'd for the user
  # (GRANT/provisionRoamedApps runs AFTER roam-in) -> the read-back misses -> NOTREADY, and the daemon retries.
  _out=$(CLASSPATH="$_jar" timeout "${NOWHERE_VPN_TIMEOUT:-20}" app_process /system/bin np.VpnAlwaysOn "$_uid" "$_pkg" "$_mode" </dev/null 2>&1 | tr '\n' ' ' | cut -c1-300)
  _app=$(settings get --user "$_uid" secure always_on_vpn_app </dev/null 2>/dev/null)
  _ld=$(settings get --user "$_uid" secure always_on_vpn_lockdown </dev/null 2>/dev/null)
  _pd=$(settings get --user "$_uid" secure nowhere_vpn_lockdown_pending </dev/null 2>/dev/null)
  if [ "$_app" = "$_pkg" ]; then
    if [ "$_lock" = 1 ]; then
      # ON: armed already, or deferred to the first connection. lockdown=1 straight away on Endospore is the tell
      # that vpn-lockdown-on-first-connect.sh is missing from the image (docs/framework-patches.md).
      { [ "$_ld" = 1 ] || [ "$_pd" = "$_pkg" ]; } && _ok=yes
    else
      # OFF: no block now, and none waiting for the first connection either.
      [ "$_ld" != 1 ] && [ "$_pd" != "$_pkg" ] && _ok=yes
    fi
  fi
  echo "[roamd] always-on VPN -> $_pkg (lockdown=$_lock via $_mode, from $_src) user $_uid $(date): $_out; read back app=$_app lockdown=$_ld pending=$_pd -> $_ok" >> "$LOG"
  [ "$_ok" = yes ] || { printf 'NOTREADY'; return 0; }
  if [ -n "$_wg" ]; then
    sleep 2
    # SET_TUNNEL_UP via cmd(am): stdout MUST go to /dev/null, NOT a file -- cmd hands the stdout fd to system_server,
    # which cannot write an endospore_priv-owned log => "Failed transaction" (#56).
    am broadcast --user "$_uid" -p com.wireguard.android -a com.wireguard.android.action.SET_TUNNEL_UP --es tunnel "$_wg" </dev/null >/dev/null 2>&1
    print -r -- "[roamd] WG raise tunnel $(qn "$_wg") (user $_uid) $(date)" >> "$LOG"
  fi
  [ "$_src" = pick ] && vpn_pick_consume "$_vf" "$_pick"   # the pick is now the live state
  rm -f "$STATE/.vpndeferred.$_uid" 2>/dev/null
  ( : > "$STATE/.vpnapplied.$_uid" ) 2>>"$LOG"
  printf 'OK APPLIED'; return 0
}

# vpn_pick_consume <files dir> <the pick's content when it was applied>: remove the pick only if it still says that.
# A pick the user made after this apply read it is a NEW choice for the next sign-in and must survive.
vpn_pick_consume() {
  [ "$(cat "$1/nowhere-vpn-pick" 2>/dev/null)" = "$2" ] && rm -f "$1/nowhere-vpn-pick" 2>>"$LOG"
  return 0
}

# vpn_deferred_retry <uid> [<installed pkg>]: at the top of every seal, apply the always-on VPN choice that vpn_apply
# DEFERRED for its on-demand app -- exactly that choice, as $STATE/.vpndeferred.<uid> holds it (package, lockdown,
# source), never a pick made since: the picker says "applies next sign-in", and a pick made this session stays for the next sign-in, as it
# does in a session with no deferral.
#
# ⚠ THE USER'S LIVE CHOICE WINS. If another always-on VPN is live for the user -- one they set in Settings this
# session, since the deferred app was not there to take it -- the deferral is DROPPED and the session marked applied,
# so the seal captures their choice instead of the carry overwriting it the moment the old app is opened. An unreadable
# setting (settings printed nothing) applies nothing this seal: a failed read is no evidence either way.
#
# While the app is still held this is a few shell tests and one `settings get`, no JVM. Once it has materialised, a
# NOTREADY (its tunnel config not restored yet, a read-back miss) counts in $STATE/.vpnretry.<uid>; VPN_APPLY_TRIES in
# all, then one give-up line, the deferral dropped and no more JVMs. The profile's record is kept either way: nothing
# is captured until an apply lands.
#
# NWP-20261130-04: the bootwake op also runs this after one package's restore, with that package as <installed pkg>,
# because the daemon holds periodic seals for the whole Auto sweep. Every rule above applies. A deferral for another
# package returns before the `settings get`, so a 48-app sweep costs one file read per app. The seal stays the fallback.
VPN_APPLY_TRIES=5
vpn_deferred_retry() {
  local _uid="$1"; local _inst="${2:-}"; local _r; local _n; local _pkg; local _lock; local _src; local _live
  [ -s "$STATE/.vpndeferred.$_uid" ] || return 0
  read -r _pkg _lock _src < "$STATE/.vpndeferred.$_uid" 2>/dev/null
  case "$_pkg" in ""|*[!A-Za-z0-9._]*) rm -f "$STATE/.vpndeferred.$_uid" 2>/dev/null; return 0 ;; esac
  case "$_lock" in 0|1) ;; *) rm -f "$STATE/.vpndeferred.$_uid" 2>/dev/null; return 0 ;; esac
  [ -z "$_inst" ] || [ "$_inst" = "$_pkg" ] || return 0
  _live=$(settings get --user "$_uid" secure always_on_vpn_app </dev/null 2>/dev/null)
  [ -n "$_live" ] || return 0
  if [ "$_live" != null ] && [ "$_live" != "$_pkg" ]; then
    rm -f "$STATE/.vpndeferred.$_uid" "$STATE/.vpnretry.$_uid" 2>/dev/null
    # A deferral that came from a pick consumes it here too (compare-and-remove, so a newer pick survives): left in
    # place it would outrank this session's capture of the user's choice at the next sign-in.
    [ "$_src" = pick ] && vpn_pick_consume "${VPN_USER_ROOT:-/data/user}/$_uid/com.nowhere.chooser/files" "$(printf 'app=%s\nlockdown=%s' "$_pkg" "$_lock")"
    ( : > "$STATE/.vpnapplied.$_uid" ) 2>>"$LOG"
    echo "[roamd] always-on VPN: user $_uid chose $_live in this session -> the deferred $_pkg is dropped and their choice is captured $(date)" >> "$LOG"
    return 0
  fi
  [ -d "${VPN_USER_ROOT:-/data/user}/$_uid/com.nowhere.chooser/.nowhere-odhold/$_pkg" ] && return 0   # still held
  _r=$(vpn_apply_choice "$_uid" "$_src" "$_pkg" "$_lock" "$(printf 'app=%s\nlockdown=%s' "$_pkg" "$_lock")")
  case "$_r" in
    "OK "*)
      rm -f "$STATE/.vpndeferred.$_uid" "$STATE/.vpnretry.$_uid" 2>/dev/null
      if [ -n "$_inst" ] && [ "$_r" = "OK APPLIED" ]; then
        echo "[roamd] always-on VPN: applied on install of $_pkg for user $_uid $(date)" >> "$LOG"
      else
        echo "[roamd] always-on VPN: the deferred apply for user $_uid answered $_r $(date)" >> "$LOG"
      fi
      return 0 ;;
  esac
  _n=$(cat "$STATE/.vpnretry.$_uid" 2>/dev/null); case "$_n" in ""|*[!0-9]*) _n=0 ;; esac
  _n=$((_n + 1))
  if [ "$_n" -ge "$VPN_APPLY_TRIES" ]; then
    rm -f "$STATE/.vpndeferred.$_uid" "$STATE/.vpnretry.$_uid" 2>/dev/null
    echo "[roamd] always-on VPN: the deferred apply for user $_uid was not ready $_n times -> given up for this session; the profile's record is kept $(date)" >> "$LOG"
    return 0
  fi
  printf '%s\n' "$_n" > "$STATE/.vpnretry.$_uid" 2>/dev/null
  echo "[roamd] always-on VPN: the deferred apply for user $_uid is not ready yet, attempt $_n of $VPN_APPLY_TRIES $(date)" >> "$LOG"
  return 0
}


# NWP-20261010-15: ACCOUNT SYNC SETTINGS ROAM WITH THE PROFILE (docs/product-decisions.md, 2026-10-10). Gmail said
# "Account sync is off" at every sign-in: SyncStorageEngine keeps master auto-sync and every per-account,
# per-authority switch in the device-global /data/system/sync/accounts.xml, which no scope carries, and the account
# comes back through `cmd account reload-user` with no add-account flow to switch anything on. So a "Turn on" made
# in one session died with that session's user.
#
# THE RECORD is a sibling file in the chooser CE dir, nowhere-sync, written at the seal by the np.SyncRoam helper
# (editions/endospore/vendor/helpers) -- there is no shell command for sync state, and `dumpsys content` would hand
# its output fd to system_server (the cmd fd denial) and print account names besides. The format is the helper's
# (SyncRoam.java): a header, `master <0|1>`, one `sync` line per switch, and an `end <count>` line, validated whole
# by sync_capture_valid before it is kept or applied. The helper makes its binder calls as the SYSTEM uid, never as
# root: as root every per-account switch reads 0 and every write is dropped (SyncRoam.java says why).
#
# PENDING SWITCHES. A switch the framework cannot take this session -- its account not visible (authenticator app
# absent) or no sync-adapter package for its authority (an on-demand app not yet tapped, or one RegisteredServicesCache
# has not registered yet) -- is not a failure. A carried 1 comes back from the apply as a `pend` line, kept in
# nowhere-sync-pending beside the record; a carried 0 is dropped, because a new authority row starts disabled and a 1
# found there later is the user's own newer choice. THE CAPTURE IS WHAT LANDS A PEND 1, the first time the framework
# can take it and only while the live switch is still 0; a write that does not stick stays pending and is counted on
# the helper's `stat` line, which is logged. Trade-off accepted: an app that switches its own sync on at first run beats
# a carried explicit 0 (docs/sync-vpn-carry.md). A pend line it still cannot place is carried unchanged and handed back.
# The file belongs to one session: sync_apply drops it whenever it runs -- at sign-in, or in odrestore right after the
# deferred account reload on the sandboxed-Play path -- because the capture (which carried those switches) is then
# applied afresh. Pend lines are LANDED by the capture, not by a hook on each app's materialise: RegisteredServicesCache
# registers an adapter asynchronously after its install, so a call there races the very thing it waits for. (The one
# sync apply odrestore does run is the deferred SIGN-IN apply, which waits only for the account authenticator; see
# docs/sync-vpn-carry.md for what that costs a carried 0 of a gms authority.)
#
# WHEN THE CAPTURE RUNS. A capture starts two JVMs (root, then the system-uid relaunch), so it runs only when something
# it reads may have changed: the fingerprint (sync_fp) of accounts.xml (every switch), the account db (the account set)
# and the user's two RegisteredServicesCache files (the sync adapters and the authenticators it has registered -- the
# very sets that make a pend line placeable). While switches are pending and nothing changed it still retries on a
# doubling schedule -- 1, 2, 4 ... 32 seals, about an hour at most -- as a backstop for a change no fingerprinted file
# records and for a write that did not stick. Each such retry is logged, so its cost is visible.
#
# ⚠⚠ THE CAPTURE AND THE PEND LINES HOLD ACCOUNT NAMES; NOTHING ELSE MAY. They go straight from the helper's stdout
# into files in the chooser CE dir -- never through a shell variable, never into roam.log, never into $STATE. Every log
# line here carries counts, a user id, or the helper's answer only when it matches a shape that cannot hold a name
# (sync_answer). The #39 lesson: roam.log lives on plain /data, outside every user, and the next profile reads it
# through "Report an issue".
#
# ⚠ NOT BEFORE THIS SESSION'S APPLY, for the reason vpn_seal_capture gives -- and here it would be worse: until the
# accounts are placed the live state is a fresh user's, every switch off, and one periodic seal would make every
# later sign-in start with sync off. A sign-in apply that fails (a read-back mismatch, a timeout) is retried at each
# seal, SYNC_APPLY_TRIES times in all, then given up with a log line; the record is kept untouched either way.
#
# Every helper run is bounded (SYNC_TIMEOUT, the toybox `timeout`; the helper's own bound on its relaunch is shorter,
# so roamd never kills the parent and orphans the child), and a timed-out one keeps the record and never fails the
# seal or the sign-in. An image with no helper captures and applies nothing (Diaspore ships none); sync_apply says so
# at every sign-in.
SYNC_TIMEOUT="${NOWHERE_SYNC_TIMEOUT:-20}"
SYNC_APPLY_TRIES=5

sync_capture_valid() {
  local _f="$1"; local _e; local _n
  [ -f "$_f" ] || return 1
  [ "$(head -n 1 "$_f" 2>/dev/null)" = "nowhere-sync 1" ] || return 1
  [ "$(grep -c '^master [01]$' "$_f" 2>/dev/null)" = 1 ] || return 1
  _e=$(tail -n 1 "$_f" 2>/dev/null)
  case "$_e" in "end "*) ;; *) return 1 ;; esac
  _n=${_e#end }
  case "$_n" in ""|*[!0-9]*) return 1 ;; esac
  [ "$(grep -c '^sync [01] [^ ][^ ]* [^ ][^ ]* [^ ][^ ]*$' "$_f" 2>/dev/null)" = "$_n" ] || return 1
  # header + master + the switches + end, and not one line besides
  [ "$(wc -l < "$_f" 2>/dev/null | tr -cd '0-9')" = "$((_n + 3))" ] || return 1
  return 0
}

# sync_answer <helper output file> -> the helper's answer line when it has a shape that cannot carry a name, else
# "unrecognised answer". The shapes: the counts line (`OK|ERR master=... mismatch=N`), `ERR <SomethingException|Error>`,
# and our fixed tokens. Anything else -- a stack trace, a half capture, an account name -- is never printed.
sync_answer() {
  local _l; _l=$(head -n 1 "$1" 2>/dev/null)
  if printf '%s\n' "$_l" | grep -Eqx '(OK|ERR) master=[01-] rows=[0-9]+ applied=[0-9]+ pending=[0-9]+ mismatch=[0-9]+' \
     || printf '%s\n' "$_l" | grep -Eqx 'ERR [A-Z][A-Za-z]*(Exception|Error)' \
     || printf '%s\n' "$_l" | grep -Eqx 'ERR (usage|drop-failed|timeout|no-content-service|no-account-service)'; then
    printf '%s' "$_l"
  else
    printf 'unrecognised answer'
  fi
}

# sync_fp <uid> -> mtime+size of the files a capture's inputs change with, or "" if the two that must exist cannot be
# read (then the capture always runs). SyncStorageEngine rewrites accounts.xml in the same call that changes a switch
# or master; accounts_ce.db and its -wal (absent between checkpoints) change when an account is added or removed;
# users/<uid>/registered_services/android.content.SyncAdapter.xml and .../android.accounts.AccountAuthenticator.xml are
# rewritten by RegisteredServicesCache only when that user's set of sync adapters or authenticators CHANGES
# (generateServicesMap -> writePersistentServicesLocked, "if (changed)"). Not packages.list: PackageManager rewrites it
# on every settings write, which would start a capture for nothing many times a session; and not the package count
# in it either, which an on-demand app's materialise (an archived package becoming a real one) does not change.
sync_fp() {
  local _uid="$1"; local _r="${SYNC_FP_ROOT:-/data}"; local _f; local _o=""; local _s; local _rs
  [ -f "$_r/system/sync/accounts.xml" ] && [ -f "$_r/system_ce/$_uid/accounts_ce.db" ] || return 0
  _rs="$_r/system/users/$_uid/registered_services"
  for _f in "$_r/system/sync/accounts.xml" "$_r/system_ce/$_uid/accounts_ce.db" "$_r/system_ce/$_uid/accounts_ce.db-wal" \
            "$_rs/android.content.SyncAdapter.xml" "$_rs/android.accounts.AccountAuthenticator.xml"; do
    if [ -e "$_f" ]; then
      _s=$(stat -c '%Y:%s' "$_f" 2>/dev/null) || return 0
      [ -n "$_s" ] || return 0
    else
      _s=-
    fi
    _o="$_o $_s"
  done
  printf '%s' "$_o"
}

# sync_run <uid> <mode> <input file> <output file> -> the helper's rc (124 = timed out). Bounded, stderr dropped ON
# PURPOSE (against the house rule for checks): a stack trace can carry an Account's toString, i.e. a name. The answer
# is on stdout and is validated by its caller.
sync_run() {
  CLASSPATH="${NOWHERE_SYNC_JAR:-/system_ext/framework/nowhere-syncroam.jar}" \
    timeout "$SYNC_TIMEOUT" app_process /system/bin np.SyncRoam "$2" "$1" < "$3" > "$4" 2>/dev/null
}

# sync_take_pend <helper output file> <files dir> -> 0 iff every pend line in the output is well formed and they now
# replace nowhere-sync-pending (removed when there are none). A malformed one leaves the pending file as it was.
# NWP-20261119-13: "none" is a COUNT read from the output, never grep's status into a file: a redirection that cannot
# be opened (ENOSPC, a directory in the way) also fails with 1, and that once deleted the record. A write that fails,
# or holds fewer lines than the output, changes nothing and returns 1, so the capture keeps the profile's record.
sync_take_pend() {
  local _o="$1"; local _bd="$2"; local _k
  [ "$(grep -c '^pend ' "$_o" 2>/dev/null)" = "$(grep -c '^pend [01] [^ ][^ ]* [^ ][^ ]* [^ ][^ ]*$' "$_o" 2>/dev/null)" ] || return 1
  _k=$(grep -c '^pend [01] [^ ][^ ]* [^ ][^ ]* [^ ][^ ]*$' "$_o" 2>/dev/null)
  case "$_k" in ""|*[!0-9]*) return 1 ;; esac
  if [ "$_k" = 0 ]; then
    rm -f "$_bd/nowhere-sync-pending.tmp" "$_bd/nowhere-sync-pending" 2>/dev/null
    return 0
  fi
  if grep '^pend [01] [^ ][^ ]* [^ ][^ ]* [^ ][^ ]*$' "$_o" 2>/dev/null > "$_bd/nowhere-sync-pending.tmp" \
     && [ "$(grep -c '^pend ' "$_bd/nowhere-sync-pending.tmp" 2>/dev/null)" = "$_k" ] \
     && mv -f "$_bd/nowhere-sync-pending.tmp" "$_bd/nowhere-sync-pending" 2>>"$LOG"; then
    chmod 600 "$_bd/nowhere-sync-pending" 2>/dev/null
    return 0
  fi
  rm -f "$_bd/nowhere-sync-pending.tmp" 2>/dev/null
  return 1
}

# sync_keep_lines <helper output file> <files dir> -> 0 iff every pend/fix/fixmaster line in the output is well formed
# and kept. Pend lines are ADDED to nowhere-sync-pending (sign-in starts it empty, so there it is the whole set). The
# fix lines -- what a failed apply did not land -- REPLACE nowhere-sync-retry, which is what the retry works from; it
# is removed when there are none. A malformed line changes nothing. NWP-20261119-13: "none" is a count read from the
# output, as in sync_take_pend; a write that fails, or holds fewer lines than the output, keeps the file it would have
# replaced and returns 1. A pend write that fails returns at once: the fix lines are then not touched either.
sync_keep_lines() {
  local _o="$1"; local _bd="$2"; local _k; local _rc
  # -E only: Android's grep (toybox over bionic's regex) has no BRE alternation (\|).
  [ "$(grep -Ec '^(pend|fix|fixmaster) ' "$_o" 2>/dev/null)" = \
    "$(grep -Ec '^(pend [01] [^ ]+ [^ ]+ [^ ]+|fix [01] [01-] [^ ]+ [^ ]+ [^ ]+|fixmaster [01] [01-])$' "$_o" 2>/dev/null)" ] || return 1
  _k=$(grep -c '^pend [01] ' "$_o" 2>/dev/null)
  case "$_k" in ""|*[!0-9]*) return 1 ;; esac
  if [ "$_k" != 0 ]; then
    if grep '^pend [01] ' "$_o" 2>/dev/null > "$_bd/nowhere-sync-pending.tmp" \
       && [ "$(grep -c '^pend ' "$_bd/nowhere-sync-pending.tmp" 2>/dev/null)" = "$_k" ]; then
      set -- "$_bd/nowhere-sync-pending.tmp"
      if [ -e "$_bd/nowhere-sync-pending" ]; then set -- "$_bd/nowhere-sync-pending" "$@"; fi
      sort -u "$@" 2>/dev/null > "$_bd/nowhere-sync-pending.new"; _rc=$?
    else
      _rc=1
    fi
    if [ "$_rc" = 0 ] && [ -s "$_bd/nowhere-sync-pending.new" ] \
       && mv -f "$_bd/nowhere-sync-pending.new" "$_bd/nowhere-sync-pending" 2>>"$LOG"; then
      chmod 600 "$_bd/nowhere-sync-pending" 2>/dev/null
    else
      rm -f "$_bd/nowhere-sync-pending.tmp" "$_bd/nowhere-sync-pending.new" 2>/dev/null
      return 1
    fi
  fi
  rm -f "$_bd/nowhere-sync-pending.tmp" "$_bd/nowhere-sync-pending.new" 2>/dev/null
  _k=$(grep -Ec '^(fix [01] |fixmaster )' "$_o" 2>/dev/null)
  case "$_k" in ""|*[!0-9]*) return 1 ;; esac
  if [ "$_k" = 0 ]; then
    rm -f "$_bd/nowhere-sync-retry.tmp" "$_bd/nowhere-sync-retry" 2>/dev/null
    return 0
  fi
  if grep -E '^(fix [01] |fixmaster )' "$_o" 2>/dev/null > "$_bd/nowhere-sync-retry.tmp" \
     && [ "$(grep -Ec '^(fix |fixmaster )' "$_bd/nowhere-sync-retry.tmp" 2>/dev/null)" = "$_k" ] \
     && mv -f "$_bd/nowhere-sync-retry.tmp" "$_bd/nowhere-sync-retry" 2>>"$LOG"; then
    chmod 600 "$_bd/nowhere-sync-retry" 2>/dev/null
    return 0
  fi
  rm -f "$_bd/nowhere-sync-retry.tmp" 2>/dev/null
  return 1
}

# sync_apply_once <uid> <what> [retry] -> the apply proper. Marks $STATE/.syncapplied.<uid> -- which is what lets this
# session's capture run -- only when there was nothing to apply or the helper read every switch it set back as written.
# A failure counts in $STATE/.syncretry.<uid> for sync_apply_retry, and the switches it did not land are kept in
# nowhere-sync-retry, each with its live value just after the failure; the profile's record survives it untouched.
# With `retry` it runs the helper's retry mode (SyncRoam.java retry()): on those switches only, writing each carried
# value only while the switch still reads what it read after the failure, so one the user changed since is left as
# they set it (except a change and change-back inside one seal interval, which reads as untouched). A switch that
# cannot be read during the retry is handed back unchanged and the retry is not OK. The CONSERVATIVE rule (a 1 only
# over a live 0, never a 0, never master) applies wherever there is no value-at-failure: a row whose value after the
# failure was unreadable, and the whole record when the failed apply handed nothing usable back -- it timed out,
# crashed, answered `ERR <Exception>`, or its hand-back is malformed (dropped below). ⚠ Residual: there a user's off of
# a carried-1 switch can be turned back on, and the next capture records that 1, so their off is lost from the record
# until they turn it off again.
sync_apply_once() {
  local _uid="$1"; local _what="$2"; local _mode="${3:-apply}"; local _bd="${SYNC_USER_ROOT:-/data/user}/$_uid/com.nowhere.chooser/files"
  local _f; local _o; local _a; local _n; local _in
  _f="$_bd/nowhere-sync"; _o="$_bd/nowhere-sync-apply.tmp"
  if [ ! -f "$_f" ]; then
    ( : > "$STATE/.syncapplied.$_uid" ) 2>>"$LOG"; rm -f "$STATE/.syncretry.$_uid" 2>/dev/null
    echo "[roamd] sync: no capture for user $_uid -> sync left as the restore made it; this session's seal records it $(date)" >> "$LOG"
    return 0
  fi
  if ! sync_capture_valid "$_f"; then
    ( : > "$STATE/.syncapplied.$_uid" ) 2>>"$LOG"; rm -f "$STATE/.syncretry.$_uid" 2>/dev/null
    echo "[roamd] sync: capture for user $_uid is malformed -> nothing applied; this session's seal replaces it $(date)" >> "$LOG"
    return 0
  fi
  _in="$_f"
  if [ "$_mode" = retry ] && [ -s "$_bd/nowhere-sync-retry" ]; then
    # A hand-back with any line the helper would not parse (an older format, a torn write) is no hand-back at all:
    # dropped, and the retry works from the whole record under the conservative rule -- never an empty, "OK" retry.
    if grep -Evq '^(fix [01] [01-] [^ ]+ [^ ]+ [^ ]+|fixmaster [01] [01-])$' "$_bd/nowhere-sync-retry" 2>/dev/null; then
      rm -f "$_bd/nowhere-sync-retry" 2>/dev/null
      echo "[roamd] sync: the hand-back for user $_uid is malformed -> retrying from the whole record $(date)" >> "$LOG"
    else
      _in="$_bd/nowhere-sync-retry"
    fi
  fi
  sync_run "$_uid" "$_mode" "$_in" "$_o"
  _a=$(sync_answer "$_o")
  case "$_a" in
    "OK "*)
      if sync_keep_lines "$_o" "$_bd"; then
        rm -f "$_o" "$STATE/.syncretry.$_uid" "$_bd/nowhere-sync-retry" 2>/dev/null
        ( : > "$STATE/.syncapplied.$_uid" ) 2>>"$LOG"
        echo "[roamd] sync: $_what for user $_uid: $_a $(date)" >> "$LOG"
        return 0
      fi
      _a="pend lines malformed or not written" ;;
    "ERR master="*)
      # It answered: keep what it says did not land, so the retry touches only that.
      sync_keep_lines "$_o" "$_bd" || _a="$_a, fix lines malformed or not written" ;;
  esac
  rm -f "$_o" 2>/dev/null
  _n=$(cat "$STATE/.syncretry.$_uid" 2>/dev/null); case "$_n" in ""|*[!0-9]*) _n=0 ;; esac
  printf '%s\n' "$((_n + 1))" > "$STATE/.syncretry.$_uid" 2>>"$LOG"
  echo "[roamd] sync: $_what FAILED for user $_uid ($_a), attempt $((_n + 1)) of $SYNC_APPLY_TRIES -> this session will not overwrite the profile's record $(date)" >> "$LOG"
  return 0
}

# sync_apply <uid>: re-apply the captured switches at sign-in. ⚠ STRICTLY AFTER acct_reload, in both places it runs (the
# grant op's installed path, and odrestore right after its deferred reload): a switch set for an account that does
# not exist yet is a row SyncManager's stale-account sweep deletes, so applying before the accounts are placed is
# applying nothing.
#
# ⚠ TRADE-OFF on the deferred (sandboxed-Play) path: the apply sets master auto-sync to the carried value, so a master
# toggle the user made earlier in the session, before tapping a Play app, is overwritten. Kept, deliberately: before
# that tap the profile has no account placed, so there is nothing for the master switch to sync and little reason to
# touch it; and telling a toggle from the untouched default would need the platform's default for a new user, which is
# a build config (SyncStorageEngine's master-sync default), not something the record or the device state can answer.
sync_apply() {
  local _uid="$1"; local _bd="${SYNC_USER_ROOT:-/data/user}/$_uid/com.nowhere.chooser/files"
  if [ ! -f "${NOWHERE_SYNC_JAR:-/system_ext/framework/nowhere-syncroam.jar}" ]; then
    echo "[roamd] sync: this image ships no sync helper -> account sync settings are not carried here $(date)" >> "$LOG"
    return 0
  fi
  # A previous session's pend lines and this uid's gates; all re-derived from here.
  rm -f "$_bd/nowhere-sync-pending" "$_bd/nowhere-sync-retry" "$STATE/.syncfp.$_uid" "$STATE/.syncbo.$_uid" \
    "$STATE/.syncretry.$_uid" 2>/dev/null
  sync_apply_once "$_uid" applied
  return 0
}

# sync_apply_retry <uid>: at the top of every seal, re-run a sign-in apply that FAILED (it can only have failed after
# its acct_reload, so the ordering rule holds). A transient read-back mismatch must not freeze the session's sync
# settings out of the record; SYNC_APPLY_TRIES attempts in all, then one give-up line and no more JVMs. Either way the
# profile's record is kept as it came.
sync_apply_retry() {
  local _uid="$1"; local _n
  _n=$(cat "$STATE/.syncretry.$_uid" 2>/dev/null)
  case "$_n" in ""|*[!0-9]*) return 0 ;; esac
  if [ "$_n" -ge "$SYNC_APPLY_TRIES" ]; then
    echo gave-up > "$STATE/.syncretry.$_uid" 2>>"$LOG"
    echo "[roamd] sync: the apply for user $_uid failed $_n times -> given up for this session; the profile's record is kept $(date)" >> "$LOG"
    return 0
  fi
  sync_apply_once "$_uid" "apply retried" retry
  return 0
}

sync_seal_capture() {
  local _bd="$1/com.nowhere.chooser/files"; local _uid="$2"; local _out="$_bd/nowhere-sync"; local _rc; local _n; local _m
  local _fp; local _why=change; local _w=0; local _nx=1; local _k; local _st
  [ -d "$_bd" ] || return 0
  [ -f "${NOWHERE_SYNC_JAR:-/system_ext/framework/nowhere-syncroam.jar}" ] || return 0
  if [ ! -e "$STATE/.syncapplied.$_uid" ]; then
    echo "[roamd] sync: not applied yet this session for user $_uid -> the profile's record is kept $(date)" >> "$LOG"
    return 0
  fi
  # The gate (see WHEN THE CAPTURE RUNS). Unreadable fingerprint -> always capture.
  _fp=$(sync_fp "$_uid")
  if [ -n "$_fp" ] && [ -f "$_out" ] && [ "$_fp" = "$(cat "$STATE/.syncfp.$_uid" 2>/dev/null)" ]; then
    [ -s "$_bd/nowhere-sync-pending" ] || return 0
    read -r _w _nx < "$STATE/.syncbo.$_uid" 2>/dev/null
    case "$_w" in ""|*[!0-9]*) _w=0 ;; esac
    case "$_nx" in ""|*[!0-9]*) _nx=1 ;; esac
    if [ "$_w" -gt 0 ]; then
      printf '%s %s\n' "$((_w - 1))" "$_nx" > "$STATE/.syncbo.$_uid" 2>/dev/null
      return 0
    fi
    _why=backoff
  fi
  # The previous capture and this session's pend lines are the helper's input: it re-reads only what it may, and lands
  # a pend line the moment it can.
  # NWP-20261119-13: staged only from the files that exist, and checked. The helper carries forward only the pend lines
  # it is given, so a short input would drop them from the record; a failed staging runs no helper and stores no
  # fingerprint, so the next seal tries again.
  set --
  if [ -e "$_out" ]; then set -- "$_out"; fi
  if [ -e "$_bd/nowhere-sync-pending" ]; then set -- "$@" "$_bd/nowhere-sync-pending"; fi
  cat "$@" < /dev/null 2>/dev/null > "$_bd/nowhere-sync-in.tmp"; _rc=$?
  if [ "$_rc" != 0 ]; then
    rm -f "$_bd/nowhere-sync-in.tmp" 2>/dev/null
    echo "[roamd] sync: capture FAILED for user $_uid (its input could not be staged) -> the profile's record is kept $(date)" >> "$LOG"
    return 0
  fi
  sync_run "$_uid" capture "$_bd/nowhere-sync-in.tmp" "$_out.raw"; _rc=$?
  rm -f "$_bd/nowhere-sync-in.tmp" 2>/dev/null
  grep -Ev '^(pend|stat) ' "$_out.raw" > "$_out.tmp" 2>/dev/null   # -E: no BRE alternation on Android
  # At most one `stat landed=N unstuck=M` line (counts only), after the pend lines.
  _st=$(grep '^stat landed=[0-9][0-9]* unstuck=[0-9][0-9]*$' "$_out.raw" 2>/dev/null)
  if [ "$_rc" = 0 ] && sync_capture_valid "$_out.tmp" \
     && [ "$(grep -c '^stat ' "$_out.raw" 2>/dev/null)" = "$(printf '%s' "$_st" | grep -c '^stat ')" ] \
     && [ "$(grep -c '^stat ' "$_out.raw" 2>/dev/null)" -le 1 ] && sync_take_pend "$_out.raw" "$_bd"; then
    rm -f "$_out.raw" 2>/dev/null
    # A carried 1 landed, or written and not sticking (kept pending, tried again at the next capture).
    [ -n "$_st" ] && echo "[roamd] sync: carried switches for user $_uid: ${_st#stat } $(date)" >> "$LOG"
    # Stored only after a capture that WORKED: a failed one must run again at the next seal.
    [ -n "$_fp" ] && printf '%s' "$_fp" > "$STATE/.syncfp.$_uid" 2>/dev/null
    if [ -s "$_bd/nowhere-sync-pending" ]; then
      _k=$(grep -c '^pend ' "$_bd/nowhere-sync-pending" 2>/dev/null)
      if [ "$_why" = backoff ]; then _nx=$((_nx * 2)); [ "$_nx" -gt 32 ] && _nx=32; else _nx=1; fi
      printf '%s %s\n' "$_nx" "$_nx" > "$STATE/.syncbo.$_uid" 2>/dev/null
      echo "[roamd] sync: $_k switch(es) still pending for user $_uid (their app or account is absent; retry after a $_why) -> next retry in $_nx seal(s) unless an app or account changes $(date)" >> "$LOG"
    else
      rm -f "$STATE/.syncbo.$_uid" 2>/dev/null
    fi
    if cmp -s "$_out.tmp" "$_out"; then rm -f "$_out.tmp" 2>/dev/null; return 0; fi
    mv -f "$_out.tmp" "$_out" 2>>"$LOG"; chmod 600 "$_out" 2>/dev/null
    _n=$(tail -n 1 "$_out" 2>/dev/null); _n=${_n#end }
    _m=$(sed -n 's/^master //p' "$_out" 2>/dev/null)
    echo "[roamd] sync: captured master=$_m and $_n switch(es) for user $_uid $(date)" >> "$LOG"
  else
    [ "$_rc" = 124 ] && _m="timed out" || _m=$(sync_answer "$_out.raw")
    echo "[roamd] sync: capture FAILED for user $_uid (rc=$_rc, $_m) -> the profile's record is kept $(date)" >> "$LOG"
    rm -f "$_out.tmp" "$_out.raw" 2>/dev/null
  fi
  return 0
}

bt_seal_capture() {
  local _bd="$1/com.nowhere.chooser/files"; local _f; local _out; local _v; local _rc
  [ -d "$_bd" ] || return 0
  if ! ls "$BT_DIR" >/dev/null 2>>"$LOG"; then
    echo "[roamd] bt: $BT_DIR unreadable at capture -- keeping this profile's existing artifacts $(date)" >> "$LOG"
    return 1
  fi
  for _f in $BT_FILES; do
    _out="$_bd/bt-bond-${_f%.conf}"
    if [ -s "$BT_DIR/$_f" ]; then
      if cp -f "$BT_DIR/$_f" "$_out.tmp" 2>>"$LOG"; then
        mv -f "$_out.tmp" "$_out" 2>>"$LOG"; chmod 600 "$_out" 2>/dev/null
      else
        rm -f "$_out.tmp" 2>/dev/null
        echo "[roamd] bt: could not capture $_f $(date)" >> "$LOG"
      fi
    else
      rm -f "$_out"                 # readable directory, no file: this session genuinely has no BT state
    fi
  done
  # DIA-20260807-05: and the device name, which lives in settings rather than in any file (see BT_NAME_KEYS).
  # Best-effort BY DESIGN for the CALLER: the return is 0 whatever this loop finds, so btpark's verdict stays the
  # bond half's. But it is never destructive on a read that did not happen. NWP-20261111-18: an unset key prints
  # `null`; EMPTY output is not a value, it is a call that printed nothing (failed, killed, or a settings provider
  # not answering), and a hung call used to hold the logoff seal with no bound. So the read is bounded like
  # cutoff_keep's (timeout -k 2 10), its status is kept, and each key has three outcomes:
  #   (a) a non-zero status OR empty output -> the profile's existing artifact is KEPT untouched and one line
  #       names the KEY (never the value). Deleting it here sealed the CE without it, and every later sign-in
  #       restored the model default: a name this user chose was lost for good to one failed read. The bond
  #       half keeps its artifacts on an unreadable $BT_DIR for the same reason;
  #   (b) `null` or the model default -> the artifact is removed. NWP-20260902-06: the model default is what the
  #       WIPE writes, not something this user chose, so it is "no name" for roaming purposes -- otherwise every
  #       profile would carry an identical, pointless artifact;
  #   (c) anything else -> written through $_out.tmp + mv -f like the bond half, so a failed write never leaves
  #       a cut name behind.
  # The WIPE is not best-effort: bt_reset overwrites the key with `settings put` of bt_default_name, which can
  # fail -- it logs `bt ERR: could not reset` and returns _rc=1, so the reset reports the device NOT cleared.
  for _f in $BT_NAME_KEYS; do
    _out="$_bd/bt-name-${_f%%:*}-${_f#*:}"
    _v=$(timeout -k 2 10 settings get --user 0 "${_f%%:*}" "${_f#*:}" </dev/null 2>/dev/null); _rc=$?
    if [ "$_rc" != 0 ] || [ -z "$_v" ]; then
      echo "[roamd] bt: device name ${_f#*:} unreadable (rc=$_rc) -- this profile's saved name is kept $(date)" >> "$LOG"
      continue
    fi
    case "$_v" in
      null|"$(bt_default_name)") rm -f "$_out" ;;
      *) if printf '%s' "$_v" > "$_out.tmp" 2>>"$LOG"; then
           mv -f "$_out.tmp" "$_out" 2>>"$LOG"; chmod 600 "$_out" 2>/dev/null
         else
           rm -f "$_out.tmp" 2>/dev/null
           echo "[roamd] bt: could not write device name ${_f#*:} -- this profile's saved name is kept $(date)" >> "$LOG"
         fi ;;
    esac
  done
  return 0
}

# THE AMNESIA CONTROL. Clear the device's Bluetooth state, and when $1 names a USERDIR lay that profile's own
# captured state back down afterwards. Returns 0 ONLY when the device is VERIFIED clear; sets BT_RESTORED to the
# number of files re-laid. Idempotent, so it is safe at login, at logoff, and at any other teardown.
# $2 = resume (NWP-20261116-19, #57 / dn-1109 #5): only the btresume op passes it. When the adapter never reaches
# OFF, a resume turns the radio back on before it returns 1 -- the device then holds only this session's bonds.
# Every other caller keeps the radio off on that exit (option b, "everywhere", was not chosen).
# $2 = reap, $3 = the reaped uid (NWP-20261129-06): only the cleanstorage op passes them. With a live session other than
# that uid (reap_live_other) nothing is cleared and the return is 2, neither "verified clear" nor a failed clear.
bt_reset() {
  local _bd=""; local _s; local _f; local _left; local _rc=0; local _n=0
  local _brl
  if [ "${2:-}" = reap ] && _brl=$(reap_live_other "$3"); then
    echo "[roamd] bt: a live session (user $_brl) holds the device -- its Bluetooth state left in place at the reap of user $3 (NWP-20261129-06) $(date)" >> "$LOG"
    BT_RESTORED=0
    return 2
  fi
  BT_RESTORED=0
  [ -n "$1" ] && _bd="$1/com.nowhere.chooser/files"

  _s=$(bt_state)
  if ! _bt_state_ok "$_s"; then
    echo "[roamd] bt ERR: adapter state unreadable ('$_s') -- device NOT cleared $(date)" >> "$LOG"; return 1
  fi
  if [ "$_s" != OFF ]; then
    cmd bluetooth_manager disable </dev/null >/dev/null 2>/dev/null
    if ! _bt_wait_off; then
      if [ "${2:-}" = resume ]; then
        cmd bluetooth_manager enable </dev/null >/dev/null 2>&1   # #57: at a resume, turn the radio back on (dn-1109 #5)
        echo "[roamd] bt ERR: adapter never reached OFF -- device NOT cleared -- radio turned back on (resume) $(date)" >> "$LOG"; return 1
      fi
      echo "[roamd] bt ERR: adapter never reached OFF -- device NOT cleared $(date)" >> "$LOG"; return 1
    fi
  fi

  find "$BT_DIR" -mindepth 1 -exec rm -rf {} + 2>>"$LOG"
  for _f in $BT_APP_DIRS; do
    [ -d "$_f" ] && rm -rf "$_f/databases" "$_f/shared_prefs" "$_f/cache" "$_f/code_cache" 2>>"$LOG"
  done
  # DIA-20260807-05: and the device name (see BT_NAME_KEYS). Overwritten UNCONDITIONALLY, before any restore,
  # so the departing user's name never survives. A put needs no output capture, but it can still fail, and a
  # failure is counted below (_rc=1), never passed.
  #
  # NWP-20260902-06: SET to the model default, not deleted. Deleting reads back as NULL, and a null tier-1
  # device name sends the common three-tier lookup into Settings.Secure.bluetooth_name, which throws for any
  # app targeting SDK > 31 -- see the BT_NAME_KEYS header. Writing the model is the same value the apps
  # themselves fall back to, so it is amnesia-neutral.
  _dn=$(bt_default_name)
  for _f in $BT_NAME_KEYS; do
    if ! settings put --user 0 "${_f%%:*}" "${_f#*:}" "$_dn" </dev/null >/dev/null 2>/dev/null; then
      echo "[roamd] bt ERR: could not reset ${_f#*:} -- the departing device NAME may survive $(date)" >> "$LOG"
      _rc=1
    fi
  done

  # VERIFY. A directory we cannot read is a FAILURE, never a pass -- that conflation is the whole bug.
  if ! _left=$(ls -A "$BT_DIR" 2>>"$LOG"); then
    echo "[roamd] bt ERR: cannot read $BT_DIR -- assume the previous session's bonds REMAIN $(date)" >> "$LOG"
    _rc=1
  elif [ -n "$_left" ]; then
    echo "[roamd] bt ERR: survived the wipe: $(echo $_left) $(date)" >> "$LOG"
    _rc=1
  fi

  # Re-lay only onto a device we know is clean, else this profile's bonds would join somebody else's leftovers.
  if [ "$_rc" = 0 ] && [ -n "$_bd" ]; then
    for _f in $BT_FILES; do
      [ -s "$_bd/bt-bond-${_f%.conf}" ] || continue
      if cp -f "$_bd/bt-bond-${_f%.conf}" "$BT_DIR/$_f" 2>>"$LOG"; then
        chown bluetooth:bluetooth "$BT_DIR/$_f" 2>>"$LOG"
        chmod 660 "$BT_DIR/$_f" 2>>"$LOG"
        restorecon "$BT_DIR/$_f" 2>>"$LOG"
        _n=$((_n+1))
      else
        echo "[roamd] bt ERR: could not restore $_f $(date)" >> "$LOG"; _rc=1
      fi
    done
    # ...and this profile's own device name, if it had one. Absent artifact => the model default stands.
    for _f in $BT_NAME_KEYS; do
      [ -s "$_bd/bt-name-${_f%%:*}-${_f#*:}" ] || continue
      settings put --user 0 "${_f%%:*}" "${_f#*:}" "$(cat "$_bd/bt-name-${_f%%:*}-${_f#*:}")" </dev/null >/dev/null 2>/dev/null
    done
  fi

  [ "$_s" != OFF ] && cmd bluetooth_manager enable </dev/null >/dev/null 2>&1   # restore the user's radio state
  BT_RESTORED=$_n
  return $_rc
}

# ---- DIA-20260807-12: the logs must not be a permanent roster of everyone who ever used this handset ------
# /data/nowhere/state is tmpfs; the LOGS are not -- they are on /data (f2fs) and, until this slice, nothing cleared
# them. *(NWP-20261017-01: they ARE rotated now -- log_scrub keeps a 1 MiB tail at every reap and boot, and carries
# the reaped session's seal summary lines across that cut, once.)* Measured on lynx 2026-08-07: roam.log 11.8 MB, and one grep recovered EIGHT distinct profile
# names spanning days, including FAILED logins -- identities merely ATTEMPTED on the device. DIA-20260807-11
# stopped that reaching a person through the issue report; it did not stop it EXISTING, which is what the
# amnesia guarantee is actually about.
#
# We redact by POSITION, exactly as report_issue.go does, so this never needs to know the departed name --
# which matters because the reap is credless. roamd writes `[roamd] <VERB> <name>`; the daemon writes it
# %q-quoted inside `[logind] ...`. Everything else in the line (uid, op, counts, outcome) is what debugging
# actually uses and is deliberately kept. *(NWP-20261008-09: roamd and mediad now write the name QUOTED and
# escaped, through qn, and the program below is escape-aware; the positional rules stay for lines written before.)*
#
# Truncate-IN-PLACE (cat > file), never rename: the daemon holds these open O_APPEND, so replacing the inode
# would leave it writing to an unlinked file forever. The tail cap IS the rotation (NWP-20261017-01); a reap
# also carries the just-ended session's seal summary across it (see log_scrub), so the trim cannot eat the line that prices
# the logoff it follows.
# A few lines appended during the rewrite can be lost -- acceptable at a reap, where the session being logged
# is the one going away.
NOWHERE_LOGS="login roam mediad provision ota"
LOG_KEEP_BYTES=1048576          # ~1 MB of tail kept; was unbounded, 11.8 MB observed
# NWP-20261008-09: the scrub program, ONE line so the shell suites take it whole by name and run it.
# test-log-name-scrub.sh runs it end to end against planted names, and its --mutate quotes every rule's exact text as a
# mutant needle (a needle that no longer matches is a red SKIP), so editing a rule means editing the mutants that quote
# it; log_scrub_fuzz_test.go runs it under sed on generated names; report_issue.go's issueNameRules mirror it rule for
# rule. A leak hides behind it and says nothing. In order:
#   1. OLD lines whose name a quote could derail, each healed from text the emitter printed around the name and
#      anchored at the start of the line, so no match can begin inside a quoted name, while a line written today, which
#      lacks the old text, falls through to rule 2: the daemon's export success line, which printed the export key
#      `ref/export/<name>` bare (anchored at its end too, so a name holding that line's own text cannot end the match
#      inside itself), and its cap-flush error lines; the store-retry line, twice -- as written, keeping its attempt
#      count and error (`(N/M): ` with its colon, which a name holding ` (1/2)` lacks), then, where the previous
#      program paired a quote in the name with the error's and swallowed that count, everything after the key; and the
#      fido2 lines, which printed the name BARE (#81, 2026-07-04, to NWP-20260922-05) and then RAW inside quotes, up to
#      ` -> <verb>` or the date's weekday;
#   2. quoted tokens, ESCAPE-AWARE: `\"` and `\\` stay inside the token, so a name holding a quote or a backslash goes
#      whole. The daemon's %q and logProfile, and qn here and in mediad, escape exactly those two. [restore] lines
#      quote FILE PATHS and stay exempt (DIA-20260807-14). Then an export or pay-rent line whose name token is not
#      followed by `": ` -- every one written today is -- is cut after the token: the previous program split it there;
#   3. what the PREVIOUS program already left of a name holding a quote. It paired quotes without regard to escapes, so
#      the device holds `"<name>"ne"`, and for payRent's double %q `"<name>"alice smith\"<name>"`. Two signs mark a
#      name's remainder, and no line written today shows either: text between two placeholders that ends in a
#      backslash -- the escape of the quote the previous program paired -- (a chain of them goes at once); and an ODD
#      number of quotes, where the pairing went wrong at the first placeholder and the last quote, the lone one, is the
#      original's last -- the text between them goes;
#   4. OLD bare names after `[roamd] IN|OUT|GRANT` and `[mediad] start`, PER VERB, to the LAST of the texts that verb
#      ever printed after a name -- IN: ` #`, ` NEEDKEY`, ` -> user`, ` BLANK`; GRANT: ` #`; OUT: ` #`, ` (user`,
#      ` ERR-`; mediad: ` -> user`. Per verb, because the name-less `[roamd] GRANT -> N perms + M INTERNET
#      default(s) (user U)` line would otherwise reach ` (user` and lose its counts. Every name counts as bare except a
#      quoted placeholder followed by a space, which is what rule 2 makes of a name written today; ERE has no lookahead,
#      so that exception is spelled out a character at a time. After rule 3, because rule 3 can turn an old line into
#      one only this rule heals: run first, this rule would heal it at the NEXT scrub, and the program would not be a
#      fixed point (only names that open with a quote show it, so log_scrub_fuzz_test.go pins the order, not a suite
#      plant). Greedy on purpose (ERE has no lazy match): on an old line where the verb's anchors come more than once
#      it also eats the text between, the safe direction;
#   5. any export key still unquoted, raw or URL-escaped (minio repeats the request URL unquoted when a connection
#      closes), [restore] lines exempt as from rule 2. After rule 2: its class stops at a quote but takes a backslash,
#      so ahead of it it would split a quoted name holding `ref/export/` and a `\"`, and the line would not be a fixed
#      point (mutant "rule 5 runs before rule 2");
#   6. the old ssaid seed prefix (DIA-20260815-12).
# NOT a rule here: the resolver's legacy `dns=[...]` address list is LOG_SCRUB_DNS_SED below, a program of its own with
# its own self-check, run after these (NWP-20261011-36).
# The previous program's one-word position rules are gone: a quoted name now STAYS quoted (`"<name>"`), so the next
# scrub -- every reap and boot re-scrubs the kept tail -- leaves the line alone, where a bare `<name>` would meet rule
# 4 again and lose its `#sys ... ce= de=` text. Every rule is load-bearing (removing any one leaks a name, breaks the
# fixed point, loses a diagnostic or fails the probe), and the program is a fixed point after one pass, measured on
# the suite's plants and on generated names (spaces, quotes, backslashes, apostrophes, non-ASCII and punctuation
# initials, names holding the rules' own anchor texts) in every shape: new, old, and old after the previous program.
# Accepted bounds, measured: an OLD line whose name opens with a closed quoted token followed by a space and more words
# (`"a b" c`) or by one of rule 4's texts (`"a" #b`) keeps the text after the quote, because it cannot be told apart
# from a quoted name followed by diagnostics; and a name that holds a rule's own anchor text (`: sealed 1 bytes ->
# ref/export/`) can steer that rule on its own line, which then loses diagnostics but never the name.
LOG_SCRUB_SED='s/^(\[logind\] export(-media)? ).*(: sealed [0-9]+ bytes -> ref\/export\/).*( \(blob [0-9a-f]+\))$/\1"<name>"\3<name>\4/; s/^( *retry [A-Za-z ]*ref\/export\/).*( \([0-9]+\/[0-9]+\): )/\1<name>\2/; s/^( *retry [A-Za-z ]*ref\/export\/)([^<]|<[^n]|<n[^a]|<na[^m]|<nam[^e]|<name[^>]|<name>[^ ]|<name> [^(]).*/\1<name>/; s/^(\[logind\] export(-media)? ).*(: cap-flush: gateway returned no write cap for ref\/export\/).*/\1"<name>"\3<name>/; s/^(\[logind\] export(-media)? ).*(: cap-flush: the gateway listed a POINTER as already present \(ref\/export\/).*(\) -- only content-)/\1"<name>"\3<name>\4/; s/^(\[roamd\] fido2 profile ).*( -> (adopting|NFC-first|requesting))/\1"<name>"\2/; s/^(\[roamd\] fido2-enroll (OK|FAILED) for ).*( (Mon|Tue|Wed|Thu|Fri|Sat|Sun) )/\1"<name>"\3/; /^\[restore\]/! s/"([^"\\]|\\.)*"/"<name>"/g; s/^(\[logind\] (export(-media)?|pay-rent) )"<name>"([^:]|:[^ ]).*/\1"<name>"/; /^\[restore\]/! s/"<name>"([^"]*\\"<name>")+/"<name>"/g; /^\[restore\]/! s/^([^"]*)"<name>"([^"]*"[^"]*")*[^"]*"([^"]*)$/\1"<name>"\3/; s/(\[roamd\] IN )([^"]|"[^<]|"<[^n]|"<n[^a]|"<na[^m]|"<nam[^e]|"<name[^>]|"<name>[^"]|"<name>"[^ ]).*( #| NEEDKEY| -> user| BLANK)/\1<name>\3/; s/(\[roamd\] GRANT )([^"]|"[^<]|"<[^n]|"<n[^a]|"<na[^m]|"<nam[^e]|"<name[^>]|"<name>[^"]|"<name>"[^ ]).*( #)/\1<name>\3/; s/(\[roamd\] OUT )([^"]|"[^<]|"<[^n]|"<n[^a]|"<na[^m]|"<nam[^e]|"<name[^>]|"<name>[^"]|"<name>"[^ ]).*( #| \(user| ERR-)/\1<name>\3/; s/(\[mediad\] start )([^"]|"[^<]|"<[^n]|"<n[^a]|"<na[^m]|"<nam[^e]|"<name[^>]|"<name>[^"]|"<name>"[^ ]).* -> user/\1<name> -> user/; /^\[restore\]/! s/(ref(\/|%2[Ff])export(\/|%2[Ff]))[^ "&?]+/\1<name>/g; s/(seedssaid staged )[0-9A-Fa-f]+\.\./\1<redacted>../g'
# The program it replaced, proven on this sed since DIA-20260807-13. log_scrub runs it only when LOG_SCRUB_SED fails
# the self-check: this sed cannot compile it, or it no longer redacts the probe's shapes. The probe does not prove the
# new program scrubs everything this one does; test-log-name-scrub.sh's fixtures are what carry that.
LOG_SCRUB_SED_PREV='s/(\[roamd\] (IN|OUT|GRANT) )[^ ]+/\1<name>/g; s/(\[mediad\] start )[^ ]+/\1<name>/g; s/(seedssaid staged )[0-9A-Fa-f]+\.\./\1<redacted>../g; /^\[restore\]/! s/"[^"]*"/"<name>"/g'
# The self-check: rule 2 on an escaped multi-word quoted name (which must stay quoted), rule 4 on an old unquoted
# multi-word one, and rule 6.
LOG_SCRUB_PROBE='[roamd] OUT "a\"b c" (user 1) | [roamd] IN d e -> user 1 | seedssaid staged 0a1b..'
LOG_SCRUB_PROBE_OUT='[roamd] OUT "<name>" (user 1) | [roamd] IN <name> -> user 1 | seedssaid staged <redacted>..'
# NWP-20261011-36: the resolver-address program, SEPARATE from the numbered name rules above. The agent's resolver
# egress line used to print `dns=[<addr:port> ...]` -- every network's own resolver addresses, which emitted
# change-only made the kept tail of login.log a de-duplicated travel history. egressLine now writes resolvers=[...]
# with those as placeholders (a key this never matches); this takes the list out of the lines devices already hold.
# Greedy to the last `]` before ` src=` (or the end, for lines written before src= existed, DIA-20260720-02), because
# a v6 entry is itself bracketed (`[2001:db8::53]:53`) and a `[^]]*` list stops inside it -- the probe carries one in
# the middle, so that regression fails the self-check. It is not one of the numbered rules because those mirror
# report_issue.go's issueNameRules rule for rule (log_scrub_fuzz_test.go); report_issue.go's reIssueLegacyDNS mirrors
# this one. test-resolver-dns-scrub.sh runs it end to end and mutates it.
LOG_SCRUB_DNS_SED='/^\[resolver\] egress /s/ dns=\[.*\]( src=|$)/ dns=[<redacted>]\1/'
LOG_SCRUB_DNS_PROBE='[resolver] egress iface="<name>" dns=[192.0.2.1:53 [2001:db8::1]:53 192.0.2.2:53] src=discovered dot=off'
LOG_SCRUB_DNS_PROBE_OUT='[resolver] egress iface="<name>" dns=[<redacted>] src=discovered dot=off'
# NWP-20261017-01: log_scrub [<reaped uid>]. With a uid (cleanstorage), a roam.log that exceeds the cap first writes the
# seal summary lines (`push: profile ... chunks (`) of THAT session -- those after the file's last `[roamd] IN ... ->
# user <uid>` line -- that the cut would drop, behind one marker line, then the tail. Taken from the scrubbed stream,
# newest 64. Carried lines sit before the next session's IN line, so the next reap never selects them: once, no state.
# btwipe (boot) passes nothing: no session is being reaped, so nothing is carried.
log_scrub() {
  local _l _f _p _d _u _sz _cut _in _c _n _x _o _e _r _k
  _u=${1:-}
  # NWP-20261008-09: the program must PROVE it runs before it is trusted. One this shell's sed cannot compile makes
  # every rewrite below silently do nothing -- sed's stderr is dropped and an empty output skips the rewrite --
  # which reads exactly like a clean log. On a miss it says so in roam.log and falls back to the previous program.
  _p=$LOG_SCRUB_SED
  if [ "$(print -r -- "$LOG_SCRUB_PROBE" | sed -E "$_p" 2>/dev/null)" != "$LOG_SCRUB_PROBE_OUT" ]; then
    print -r -- "[roamd] log_scrub: the scrub program FAILED its self-check -- scrubbing with the previous one $(date)" >> "$LOG"
    _p=$LOG_SCRUB_SED_PREV
  fi
  # NWP-20261011-36: the resolver-address program proves itself the same way, on its own, and only then joins the
  # name program's sed run, after every name rule. Joined, not piped as a second sed: it then cannot empty the
  # output and take the name scrub down with it through the [ -s ] guard below. A program that fails is left out
  # -- names are still scrubbed -- and says so. Unset only where a harness extracts the name program alone
  # (test-log-name-scrub.sh); there it stays out silently, as it did before it existed.
  if [ -n "${LOG_SCRUB_DNS_SED+set}" ]; then
    _d=$LOG_SCRUB_DNS_SED
    if [ -n "$_d" ] && [ "$(print -r -- "$LOG_SCRUB_DNS_PROBE" | sed -E "$_d" 2>/dev/null)" = "$LOG_SCRUB_DNS_PROBE_OUT" ]; then
      _p="$_p
$_d"
    else
      print -r -- "[roamd] log_scrub: the resolver-address program FAILED its self-check -- scrubbing names only $(date)" >> "$LOG"
    fi
  fi
  for _l in $NOWHERE_LOGS; do
    _f=/data/nowhere/$_l.log
    [ -f "$_f" ] || continue
    # DIA-20260807-13: FOUR shapes, not two. The first pass covered only `[roamd] <VERB> <name>` and the
    # daemon's %q form inside `[logind]`, and the flashed device then still held 125 occurrences of a departed
    # name -- because roamd runs the agent with its output appended straight into this log, so agent lines
    # arrive with NO bracket tag at all (`push: profile "x"`, `restore: profile "x"`, `mediad: profile "x"`),
    # and mediad writes a bare `[mediad] start <name>`. Counting <name> placeholders looked like success (230
    # of them); grepping for the actual departed name is what found it. Assert the value, never the marker.
    # DIA-20260815-12: also redact the ssaid seed prefix. The staging line no longer emits one, but devices
    # already in the field carry them -- 11 lines for a user reaped days earlier were found coexisting with
    # 2079 successful <name> placeholders, i.e. the scrub had run on that exact file and walked past them.
    # This is what makes an existing device self-heal on its next reap or boot instead of needing a reflash.
    # NWP-20261008-09: sed FIRST, then the byte cap -- it used to cut first. A cut can land inside a name, and the
    # fragment it leaves has no anchor any rule can find (LOG (4)); cut after the scrub, a partial first line holds
    # only text already scrubbed. sed now reads the whole file, which only widens the window the note above accepts.
    # NWP-20261017-01: the scrubbed stream goes to the temp WHOLE; the byte cap is applied when it is written back, so
    # the seal summary the cap would drop can be read out of it first (already name-redacted).
    sed -E "$_p" "$_f" 2>/dev/null > "$STATE/.logscrub"
    _c=; _n=0
    if [ -n "$_u" ] && [ "$_l" = roam ]; then
      _sz=$(wc -c < "$STATE/.logscrub" 2>/dev/null)
      if [ "${_sz:-0}" -gt "$LOG_KEEP_BYTES" ]; then
        _cut=$((_sz - LOG_KEEP_BYTES))
        _in=$(grep -b -E "^\[roamd\] IN .* -> user $_u( |\$)" "$STATE/.logscrub" 2>/dev/null | tail -n 1)
        if [ -n "$_in" ]; then
          _in=${_in%%:*}
          _c=$(grep -b -E '^push: profile .* chunks \(' "$STATE/.logscrub" 2>/dev/null | while IFS= read -r _x; do
            _o=${_x%%:*}
            [ "$_o" -gt "$_in" ] && [ "$_o" -lt "$_cut" ] && print -r -- "${_x#*:}"
          done | tail -n 64)
          [ -n "$_c" ] && _n=$(print -r -- "$_c" | wc -l)
        fi
      fi
    fi
    # NWP-20261120-17: default-deny, as the scrub program itself is: a log we cannot scrub is a log we do not keep.
    # The program holds no delete command, so a non-empty log with no scrubbed copy is a failed scrub, never a result.
    # A copy with content is written back as before, even when sed exited non-zero: what it wrote is scrubbed text.
    # With no copy (the redirection failed, or a full state tmpfs left it empty) the log is emptied IN PLACE (the
    # daemon holds it O_APPEND) and named after the loop. -f: a scratch that is not a regular file is no copy.
    if [ -f "$STATE/.logscrub" ] && [ -s "$STATE/.logscrub" ]; then
      {
        if [ "$_n" -gt 0 ]; then
          print -r -- "[roamd] log_scrub: kept $_n seal summary line(s) of user $_u across the trim $(date)"
          print -r -- "$_c"
        fi
        tail -c "$LOG_KEEP_BYTES" "$STATE/.logscrub"
      } > "$_f" 2>/dev/null
    elif [ -s "$_f" ]; then
      # NWP-20261123-26: and a log we can neither scrub nor empty is REMOVED, by the same rule. The truncation used to
      # be unchecked: when it failed, the log kept every name and the line below still said "emptied". The daemon
      # holds the log O_APPEND, so its later writes go to the unlinked file and are lost until it opens the log
      # again: that loss is the cost of default-deny. A log rm cannot remove keeps its names, and its line says so.
      if ( : > "$_f" ) 2>/dev/null && [ ! -s "$_f" ]; then
        _e="$_e $_l.log"
      else
        rm -f "$_f" 2>/dev/null
        if [ -e "$_f" ] || [ -L "$_f" ]; then _k="$_k $_l.log"; else _r="$_r $_l.log"; fi
      fi
    fi
    rm -f "$STATE/.logscrub" 2>/dev/null
  done
  # After the loop, never inside it: $LOG is roam.log, and the loop empties login.log before roam.log, so a line
  # written earlier would be wiped. The self-check warnings written above the loop go with an emptied roam.log.
  # NWP-20261123-26: a removed roam.log goes with them too: the first line below then creates a new roam.log.
  if [ -n "$_e" ]; then
    print -r -- "[roamd] log_scrub: could not scrub$_e -- emptied rather than kept with their names (NWP-20261120-17) $(date)" >> "$LOG"
  fi
  if [ -n "$_r" ]; then
    print -r -- "[roamd] log_scrub: could not scrub or empty$_r -- removed (NWP-20261123-26) $(date)" >> "$LOG"
  fi
  if [ -n "$_k" ]; then
    print -r -- "[roamd] log_scrub: could NOT remove$_k -- could not scrub or empty it either, so it keeps its names (NWP-20261123-26) $(date)" >> "$LOG"
  fi
}

# NWP-20261107-10 (Q143, decided 2026-10-20, bound 2026-10-21): reap_ledger_trim <file> <now>. The reap ledger is
# durable (cleanstorage and bootsweep append a row per reap and nothing removed one), so btwipe trims it at boot with
# the logs: a row is kept only when its first field is all digits and younger than 30 days, then only the last 20 such
# rows, in their order. <now> goes through a `case` before it reaches awk, which reads a non-number as 0 and would keep
# every row; when it is not all digits the age cut is skipped (the 20-row cut still runs) and the log line says so.
# No row is ever an argument (Android's printf is /system/bin/printf, an argv others can read): awk reads the file.
# NWP-20261126-17: the trim is a counted rewrite, as sync_take_pend's is. ONE awk applies the row filter, keeps the
# last 20 rows in a ring buffer, ALWAYS creates <file>.tmp (named from the argument), writes the rows to it and prints
# only the count it wrote. The ledger is replaced only when awk exited 0 and the temp is a regular file holding exactly
# that count; a printed 0 under the same checks removes the file. Anything else (a temp that cannot be created, a
# full /data, an unreadable ledger, a short temp, a failed chmod or mv) keeps the ledger byte for byte, removes the
# temp and logs `trim FAILED`: before, a temp that was never written read as "no row kept" and deleted the ledger. The
# log line is counts only: never a uid or a time. POSIX sh, so it runs unchanged under bash, dash and mksh.
reap_ledger_trim() {
  local _f _t _now _age _note _n _w _rc _bad
  _f=$1; _t="$1.tmp"; _now=$2; _age=1; _note=; _bad=
  [ -f "$_f" ] || return 0
  case "$_now" in
    ''|*[!0-9]*) _age=0; _now=0; _note=" (clock not a number: age cut skipped)" ;;
  esac
  _n=$(awk 'END { print NR }' "$_f" 2>/dev/null)
  _w=$(awk -v now="$_now" -v age="$_age" -v keep=20 -v t="$_t" '
    $1 ~ /^[0-9]+$/ && (age == 0 || now - $1 < 2592000) { r[k % keep] = $0; k++ }
    END {
      s = k - keep; if (s < 0) s = 0
      printf "" > t
      for (i = s; i < k; i++) { print r[i % keep] > t; w++ }
      if (close(t) != 0) exit 1
      print w + 0
    }' "$_f" 2>/dev/null); _rc=$?
  [ "$_rc" = 0 ] || _bad=status
  case "$_w" in ''|*[!0-9]*) _bad=count ;; esac
  [ -f "$_t" ] || _bad=temp
  [ -n "$_bad" ] || [ "$(awk 'END { print NR }' "$_t" 2>/dev/null)" = "$_w" ] || _bad=short
  if [ -z "$_bad" ] && [ "$_w" = 0 ]; then
    rm -f "$_f" "$_t"
  elif [ -n "$_bad" ] || ! chmod 600 "$_t" || ! mv -f "$_t" "$_f" 2>/dev/null; then
    rm -f "$_t"
    echo "[roamd] reap-ledger: trim FAILED -- the ledger is kept unchanged (NWP-20261126-17) $(date)" >> "$LOG"
    return 0
  fi
  echo "[roamd] reap-ledger: kept ${_w} of ${_n:-0} row(s) (last 20, under 30 days)$_note $(date)" >> "$LOG"
}

# DIA-20260816-03 (amnesia audit fix 3): per-user paths that do NOT fit the /data/<tree>/<uid> shape.
#
# The reap has always walked a list of TREES (/data/system_ce/<uid> etc). These five live elsewhere, so no
# amount of extending that loop reaches them, and the boot-wipe never could either -- it works by removing a
# USER, and none of these is inside one. Found by the power-off audit (docs/amnesia-poweroff-audit.md): of
# the five, only adservices was observed HOLDING departed data (three orphan dirs for users 10/12/13, whose
# names and mtimes are a credential-free count-and-timeline of past identities). The other four were empty on
# that device -- they are blind spots AOSP happens to cover today, and a blind spot is a future leak.
#
# ONE function, used by BOTH the rm loop and the _reapleft classifier, deliberately: the audit's finding was
# that adding to the rm alone leaves the classifier unable to report failure, and adding to the classifier
# alone leaves nothing to fix it. Two lists can drift; one cannot.
#
# NWP-20261124-20: the five are NOT all reachable under enforcing. This paragraph used to say they were and asked
# for that to be checked on an enforcing build. The SB run checked it (lynx 2026102201, enforcing, 2026-10-24):
# endospore_priv is denied search on gatekeeper_data_file and on the profiles and misc-user types. So every
# per-uid reap logged three `rm: ... Permission denied` lines and three avc denials, for
# /data/misc/profiles/cur/<uid>, /data/misc/user/<uid> and /data/misc/gatekeeper/<uid>. The framework removes
# those three directories with the user. The reap's survivor check could not see them there either: its
# existence test needs the same search, so it read them as absent.
#
# Decided 2026-11-02, "twenty-four answers to the open-decisions list ..." (#9, option B, NWP-20261102-30): on
# Endospore the three paths leave this list, and endospore_priv is not granted that search. Diaspore keeps all
# five: its workers run as su:s0, which reaches them. adservices and backup stay on both editions.
#
# The edition is told by roamd's own SELinux domain, read from /proc/self/attr/current with the builtin read
# (no fork). editions/endospore/build/stage-vendor.sh retargets every worker service from su:s0 to an
# endospore_* domain, so a context that starts u:r:endospore_ is Endospore. Every other answer (su:s0, a host's
# own context, a missing, unreadable or empty file) gives all five. That fail direction costs at worst today's
# denied rm on Endospore, which does no harm, and never leaves a path unchecked on Diaspore. The path is fixed
# here on purpose: no variable or environment override, so nothing outside roamd can change the list.
extra_user_paths() {
  # Refuse to emit anything for an empty or non-numeric uid. cleanstorage already rejects those before the
  # loop is reached, so this is belt-and-braces -- but the blast radius is what justifies it: with an empty
  # uid these templates collapse to /data/backup/, /data/misc/user/ and friends, and `rm -rf /data/backup/`
  # would destroy EVERY user's backup data rather than one departed identity's. Make it structurally
  # impossible rather than relying on a caller three hundred lines away staying correct.
  case "$1" in ''|*[!0-9]*) return 0;; esac
  local _ctx
  _ctx=
  { read -r _ctx < /proc/self/attr/current; } 2>/dev/null
  case "$_ctx" in
    u:r:endospore_*)
      echo "/data/system/adservices/$1"
      echo "/data/backup/$1"
      ;;
    *)
      echo "/data/system/adservices/$1"
      echo "/data/misc/profiles/cur/$1"
      echo "/data/backup/$1"
      echo "/data/misc/user/$1"
      echo "/data/misc/gatekeeper/$1"
      ;;
  esac
}

# NWP-20261003-01: /data/system/users/<n>, the one per-user directory that is NOT under a per-user key.
#
# It lives under the system's own DE key, so what it holds is CLEARTEXT, and it is not inside any user, so the
# boot-wipe (which removes USERS) never reaches it. The framework deletes it itself (removeUserState ->
# destroyUserData), then deletes the user's RECORD, users/<n>.xml, last. But a framework writer that runs after
# that delete puts it back: AtomicFile.startWrite mkdirs a missing parent, and ResilientAtomicFile (package-
# restrictions) mkdirs unconditionally. Seen on lynx 2026-10-02 -- SettingsProvider wrote user 11's
# settings_secure.xml and settings_ssaid.xml after the reap had removed the directory -- and reproduced on lynx
# 2026-10-03 with AppIdleHistory: `am set-standby-bucket --user 11 ...` then `dumpsys usagestats flush`
# re-created users/11/app_idle_stats.xml for a user 11 that no longer existed. The orphan survives reboots, and
# ids restart at 10 after a boot, so the next user given that id LOADS it inside createAndManageUser, before
# any Nowhere code runs (from GrapheneOS source; not yet seen on a device).
#
# These functions serve the reap (cleanstorage), the boot sweep and seedssaid, and are defined HERE, above every
# dispatch, for the reason the keystore_push note records: a function defined below the op that calls it is an
# undefined command there -- exit 127, no output, and a removal that silently never ran.

# userdir_has_record <n>: does user <n> still have a record? ALL THREE files, never <n>.xml alone. The record is
# a ResilientAtomicFile: every rewrite RENAMES <n>.xml to <n>.xml.backup before writing the new one, and the
# removal deletes <n>.xml, .backup and .reservecopy one after another. So a live user briefly has no <n>.xml at
# all, and a single-file test would read that instant as "removed" and delete a live user's directory.
userdir_has_record() {
  [ -e "/data/system/users/$1.xml" ] || [ -e "/data/system/users/$1.xml.backup" ] || [ -e "/data/system/users/$1.xml.reservecopy" ]
}

# userdir_census <dir>: what a users/<n> directory holds, as `files:<names> other=<count>`. Names come ONLY from
# a fixed allowlist of framework basenames; anything else is counted, never named. UserManagerService writes an
# app's restrictions as res_<package>.xml, so a raw listing would put a package -- which apps that identity used
# -- into roam.log and the reap ledger, both of which outlive every wipe. The allowlist is what tells the writers
# apart: SettingsProvider (settings_*), AppIdleHistory, PackageManager, the other services, and our #210 seed.
# One entry is a pattern, the one the NWP-20261003-01 framework patch names writers by:
# settings_(fingerprint|face)(_[0-9]+)?[.]xml. A HIDL biometric HAL writes the plain name; an AIDL one (lynx's
# fingerprint HAL) appends its sensor id. That name is admitted only when everything between the fixed prefix
# and .xml is digits, so nothing else -- a package least of all -- can ride in on it.
userdir_census() {
  local _f _b _id _names="" _other=0
  for _f in "$1"/* "$1"/.[!.]*; do
    [ -e "$_f" ] || continue
    _b=${_f##*/}
    case "$_b" in
      settings_secure.xml|settings_system.xml|settings_ssaid.xml|settings_config.xml) _names="${_names:+$_names,}$_b" ;;
      app_idle_stats.xml|package-restrictions.xml|appwidgets.xml|registered_services|inputmethod) _names="${_names:+$_names,}$_b" ;;
      wallpaper_info.xml|settings_fingerprint.xml|settings_face.xml|nowhere-ssaid-seed) _names="${_names:+$_names,}$_b" ;;
      settings_fingerprint_*.xml|settings_face_*.xml)
        _id=${_b#settings_fingerprint_}; [ "$_id" = "$_b" ] && _id=${_b#settings_face_}; _id=${_id%.xml}
        case "$_id" in
          ''|*[!0-9]*) _other=$((_other + 1)) ;;
          *) _names="${_names:+$_names,}$_b" ;;
        esac ;;
      *) _other=$((_other + 1)) ;;
    esac
  done
  echo "files:$_names other=$_other"
}

# userdir_census_fold <census> [left]: add one census to the reap's running total -- the union of the names and
# the sum of the others -- so a reap that has to remove the directory twice reports both writers' files in one
# field. Without `left` the census is of NEW content: _ud_took counts those folds (how many times this reap found
# something in users/<uid> and went to remove it), and _ud_lother keeps that census's `other` count. With `left`
# it is the census of a directory an earlier rm could not clear, taken just before the rm that finally cleared
# it. Its names join the union, so a writer that raced the refused rm is named too. It is not a new removal
# (took is unchanged), and `other` grows only by what it holds beyond _ud_lother, so a file that outlived the
# refused rm is not counted twice.
userdir_census_fold() {
  local _c="$1" _n
  _n=${_c##*other=}
  if [ "${2:-}" = left ]; then
    if [ "$_n" -gt "$_ud_lother" ]; then _ud_other=$((_ud_other + _n - _ud_lother)); fi
  else
    _ud_took=$((_ud_took + 1)); _ud_other=$((_ud_other + _n)); _ud_lother=$_n
  fi
  _c=${_c#files:}; _c=${_c%% other=*}
  while [ -n "$_c" ]; do
    _n=${_c%%,*}
    case ",$_ud_files," in *",$_n,"*) ;; *) _ud_files="${_ud_files:+$_ud_files,}$_n" ;; esac
    [ "$_n" = "$_c" ] && break
    _c=${_c#*,}
  done
}

# reap_userdir_settle <uid>: remove users/<uid> only once the FRAMEWORK has finished removing the user.
#
# The anchor is the record triple. removeUserState deletes users/<uid> and only then the record, last, so once
# the triple is gone the removal is complete, and anything in users/<uid> from then on is a skipped
# destroyUserData or a writer that put it back -- removing it cannot touch a live user, short of a system_server
# restart that hands the id out again (see reap_userdir_take). While a record EXISTS the user is not gone (the
# #73 orphan sweep reaches cleanstorage for a uid whose removeUser may have failed), so on a timeout this NEVER
# removes. Bounded at 80 polls (20 s) because the reap holds the RW lane and a sign-in queues behind it;
# `polls:` is logged because how long the anchor takes after the keystore wait is unmeasured.
#
# POSITIVE CONTROL FIRST. "No record" is a NEGATIVE result, and `[ -e ]` gives it for "absent" and for "not
# allowed to look" alike: a denial on <uid>.xml would read as a finished removal and turn this into a delete of
# a possibly-live user's directory. User 0's record always exists, so if this cannot see it, it is blind, and a
# blind reap removes nothing (anchor:blind).
#
# Leaves, for the cleanstorage line and the ledger: _ud_anchor (ok|timeout|blind), _ud_polls, _ud_after (the
# RE-CREATIONS seen), _ud_atanchor (it was already there at the first look), _ud_left (an rm could not clear
# it), _ud_link (a symbolic link was found at users/<uid>), _ud_took (non-zero exactly when after > 0 or
# atanchor) and the census of everything removed.
reap_userdir_settle() {
  _ud_anchor=blind; _ud_polls=0; _ud_after=0; _ud_gone=0; _ud_left=""; _ud_atanchor=""; _ud_link=""
  _ud_took=0; _ud_files=""; _ud_other=0; _ud_lother=0
  userdir_has_record 0 || return 0
  while userdir_has_record "$1"; do
    if [ "$_ud_polls" -ge 80 ]; then _ud_anchor=timeout; return 0; fi
    _ud_polls=$((_ud_polls + 1)); sleep 0.25
  done
  _ud_anchor=ok
  reap_userdir_take "$1"
}

# reap_userdir_take <uid>: one look at users/<uid>, only ever after an OK anchor. Present -> census, then rm.
# What it finds is reported as one of two things, kept apart so the diagnosis points the right way:
#  - after: a RE-CREATION, counted only on absent -> present (seen gone, then seen again) -- a writer put it
#    back after this reap had seen it gone;
#  - atanchor: it was ALREADY there at the first look, just after the record went -- a destroyUserData that was
#    skipped or failed, or a writer that put it back before this reap first looked. That second case is the
#    2026-10-02 lynx orphan: its files were written during the keystore wait, which runs before the settle.
# A directory an earlier rm could not clear (left) is neither, and is not counted again. Its census is still
# taken before every further rm, and folded (`left`) when one finally clears it, so whatever a writer added
# while it was left reaches the ledger as well; the left flag is then dropped, and the quiet tail starts.
# Never removed:
#  - an EMPTY directory, which is counted as gone instead. UserManagerService creates a new user's directory
#    empty and writes the record after it, and an empty directory holds nothing to leak. But an empty husk still
#    there when the loop ends turns the NWP-20261003-01 framework patch's refusal off for this id: that patch
#    refuses only the RE-CREATION of a MISSING users/<n>, so a later writer fills the husk unrefused, until the
#    next user given this id (whose creation discards it) or the next boot. ~~Accepted deliberately, as a recorded
#    trade-off of NWP-20261003-01: removing the husk would remove a creation in progress just the same.~~
#    SUPERSEDED (Q038, 2026-10-20; NWP-20261119-26): this function still never removes one (here a creation in
#    progress looks the same), but the cleanstorage op removes a husk left when its loop ends, with rmdir, when
#    system_server's start count is known and unchanged since the reap's start (see the block after the loop).
#  - one whose record has come back: a NEW user owns this id. Ids are not reused within one system_server
#    lifetime, but a system_server restart forgets the removed ones.
#  ⚠ Both narrow the soft-reboot window; neither closes it. A system_server restart plus a sign-in given this id,
#    both inside this reap's loop, can still lose the new user's directory if the creation starts between the
#    look and the rm.
# A SYMBOLIC LINK at users/<uid> is never followed (NWP-20261011-42), as the boot sweep never follows one: it is
# looked at FIRST, because a dangling link fails -e and would otherwise count as gone and be left in place. The
# link itself is removed with rm -f, which cannot remove a directory, and NO census is taken: a census through
# the link would put its target's file names in the ledger, and the target is not this user's directory. It sets
# _ud_link, and the ledger row says `link`; a link rm cannot remove is left, like a directory. It is not a
# removal of user content, so took is unchanged. One whose record has come back is kept, as a directory is.
# rm's stderr goes to /dev/null DELIBERATELY: its error text names the file it could not remove, and
# res_<package>.xml would put a package in roam.log; the census reports what is left.
reap_userdir_take() {
  local _d="/data/system/users/$1" _l _lc=""
  if [ -L "$_d" ]; then
    userdir_has_record "$1" && return 0
    rm -f "$_d" 2>/dev/null
    if [ -L "$_d" ] || [ -e "$_d" ]; then _ud_link=1; _ud_left=1; _ud_gone=0; return 0; fi
    _ud_link=1; _ud_left=""; _ud_gone=1; return 0
  fi
  if [ ! -e "$_d" ]; then _ud_gone=1; return 0; fi
  userdir_has_record "$1" && return 0
  if _l=$(ls -A "$_d" 2>/dev/null) && [ -z "$_l" ]; then _ud_gone=1; return 0; fi
  if [ -z "$_ud_left" ]; then
    if [ "$_ud_gone" = 1 ]; then _ud_after=$((_ud_after + 1)); else _ud_atanchor=1; fi
    userdir_census_fold "$(userdir_census "$_d")"
  else
    _lc=$(userdir_census "$_d")
  fi
  rm -rf "$_d" 2>/dev/null
  if [ -e "$_d" ]; then _ud_left=1; _ud_gone=0; return 0; fi
  if [ -n "$_ud_left" ]; then userdir_census_fold "$_lc" left; fi
  _ud_left=""; _ud_gone=1
}

# userdir_pending_add <uid>: queue a uid whose reap ended anchor:timeout or anchor:blind, so users/<uid> is looked
# at again (NWP-20261104-14, Q037). The list is $STATE/userdir-pending -- the tmpfs, so a power-off drops it and
# the boot owns the folder from there. One uid per line (`<uid>`, or `<uid> left` once a re-check's rm was
# refused), digits only, no uid listed twice, newest 32 kept.
userdir_pending_add() {
  local _f="$STATE/userdir-pending"
  case "$1" in ''|*[!0-9]*) return 0 ;; esac
  [ -f "$_f" ] && grep -qE -- "^$1( left)?\$" "$_f" 2>/dev/null && return 0
  { [ -f "$_f" ] && cat "$_f"; echo "$1"; } 2>/dev/null | tail -n 32 > "$_f.tmp" 2>/dev/null \
    && chmod 600 "$_f.tmp" 2>/dev/null && mv -f "$_f.tmp" "$_f" 2>/dev/null
  return 0
}

# userdir_recheck: look again at every queued users/<uid> (NWP-20261104-14, Q037). A reap that ended
# anchor:timeout (a removal slower than its 20 s bound) or anchor:blind (user 0's record unseen) KEPT the
# cleartext directory -- settings_ssaid.xml, the SSAID userkey, included -- and nothing looked again in that boot.
# The rules are the reap's own: NEVER delete while the uid is on record (any of the three files), and never when
# user 0's record cannot be seen (a blind check removes nothing, the list is kept). Past both, reap_userdir_take
# does the one look, the census and the rm -- no polling, no sleep, nothing but a loop over the list. A uid
# whose rm could not clear it stays queued, as `<uid> left`, and is retried at the next op; the op's own $uid is
# skipped (its reap is running). Each removal writes a class=recheck reap-ledger row and a roam.log line, uid and
# census only. A refused rm writes its `left` row and log line ONCE per uid; the next ones for that uid are
# written by the re-check that clears the directory. Every periodic seal is a read-write-lane op and nothing
# trims the ledger yet (Q143), so a row per retry would leave an unbounded on-disk timeline of the session's seals.
# ⚠ READ-WRITE LANE ONLY. It is called at the top of cleanstorage and once before the top-level `case "$op"`,
# guarded by [ "$LANE" = rw ]: the read-only lane's ops (sealdelta, storagebreakdown, uiderrors, alarmrelay, playrestart, gmsstate, gmsexits, odblock, healthprobe) are arms of that
# same case, so an unguarded call would remove directories from the read-only lane, concurrently with the
# read-write lane, on every SEAL-DELTA poll.
# RESIDUAL: the triggers are the next read-write-lane op and the timer every few minutes that Q037 also names,
# BUILT (NWP-20261107-12): the login daemon sends the credless `userdirrecheck` op every 5 minutes while
# $STATE/userdir-pending is non-empty (Q037, dn-1104 #2). A power-off before either leaves the folder to the boot, as
# before, and a suspended phone runs neither (the daemon's timer does not wake it).
# NWP-20261126-18: the rewritten list replaces the old one only when it is a regular file with one full line per
# kept uid (a `wc -l` that exits 0 and prints a number); otherwise the list is kept byte for byte and roam.log gets one line of counts. A kept list can still name a
# uid this pass cleared: the next pass finds nothing left for it and writes no row.
userdir_recheck() {
  local _f="$STATE/userdir-pending" _l _u _was _n=0 _what _got
  local _ud_anchor _ud_polls _ud_after _ud_gone _ud_left _ud_atanchor _ud_link _ud_took _ud_files _ud_other _ud_lother
  [ -f "$_f" ] || return 0
  userdir_has_record 0 || return 0
  ( : > "$_f.tmp" )
  while IFS= read -r _l; do
    _u=${_l% left}; _was=""; [ "$_u" = "$_l" ] || _was=left
    case "$_u" in ''|*[!0-9]*) continue ;; esac
    [ "$_u" -ge 10 ] || continue
    if [ "$_u" = "${uid:-}" ] || userdir_has_record "$_u"; then
      echo "$_l" >> "$_f.tmp"; _n=$((_n + 1)); continue
    fi
    _ud_anchor=ok; _ud_polls=0; _ud_after=0; _ud_gone=0; _ud_left=""; _ud_atanchor=""; _ud_link=""
    _ud_took=0; _ud_files=""; _ud_other=0; _ud_lother=0
    reap_userdir_take "$_u"
    _what=removed
    if [ -n "$_ud_left" ]; then echo "$_u left" >> "$_f.tmp"; _n=$((_n + 1)); _what=LEFT; fi
    [ -n "$_ud_left" ] && [ "$_was" = left ] && continue   # its left row is already written: once per uid
    if [ "$_ud_took" != 0 ] || [ -n "$_ud_link" ] || [ -n "$_ud_left" ]; then
      echo "$(date +%s) uid=$_u class=recheck userdir=recheck:ok${_ud_left:+,left}${_ud_link:+,link} census:files:$_ud_files other=$_ud_other" >> /data/nowhere/reap-ledger 2>/dev/null
      chmod 600 /data/nowhere/reap-ledger 2>/dev/null
      echo "[roamd] userdir recheck user $_u $_what census:files:$_ud_files other=$_ud_other $(date)" >> "$LOG"
    fi
  done < "$_f"
  if [ "$_n" = 0 ]; then
    rm -f "$_f" "$_f.tmp" 2>/dev/null
  else
    _got=-
    if [ -f "$_f.tmp" ] && [ ! -L "$_f.tmp" ]; then
      _got=$(wc -l 2>/dev/null < "$_f.tmp") || _got=-
      _got=${_got#"${_got%%[! ]*}"}; case "$_got" in ''|*[!0-9]*) _got=- ;; esac
    fi
    if [ "$_got" = "$_n" ]; then
      chmod 600 "$_f.tmp" 2>/dev/null; mv -f "$_f.tmp" "$_f" 2>/dev/null
    else
      rm -f "$_f.tmp" 2>/dev/null
      echo "[roamd] userdir recheck: the pending list could not be rewritten ($_got of $_n lines) -- kept unchanged (NWP-20261126-18) $(date)" >> "$LOG"
    fi
  fi
  return 0
}

# NWP-20261114-15 (decision #67, dn-1111 #5, 2026-10-22): a failed reap is retried at the next read-write-lane op, at
# most three times. A reap that ends residue or husk with a survivor OTHER than users/<uid> -- an FBE tree or an
# extra_user_paths entry whose rm was refused once (a busy file, a late writer) -- left that path until the next
# boot, and nothing looked again; the ledger row was the only trace. reap_retry_add queues the uid, and
# reap_retry_run, at the next three read-write-lane ops, removes the same paths again and judges only them. It
# NEVER touches users/<uid>: that directory is userdir_recheck's (Q037) and the Q038 row's, so a reap whose only
# survivor is users/<uid> is not queued at all (a retry that never looks there would write a false class=retried).
# The list is $STATE/reap-pending -- the tmpfs, so a power-off drops it and the boot sweep owns the paths from
# there. One line per uid, `<uid> <k>`, <k> the retries that already failed (0, 1 or 2), digits only, uid >= 10,
# no uid listed twice, newest 32 kept. The reap-ledger gets ONE row per queued uid: class=retried when the paths
# clear, class=gaveup with the survivors after the third failed try, never one per failed try (every periodic
# seal is a read-write-lane op, so a row per try would be an on-disk timeline of the session's seals). The issue
# report's per-class counts of those rows are the ONLY escalation: there is no gate notice. rm's stderr goes to
# /dev/null, not $LOG: /data/media/<uid> holds cleartext file names, and toybox rm names each file it cannot unlink.
# No polling, no sleep, no stop_mediad: a live session's mediad keeps serving, and a path it holds is not a
# departed uid's. The same rules as userdir_recheck: nothing while user 0's record is unseen (the list is kept),
# a uid on record or the op's own $uid is skipped with its count unchanged.
# ⚠ READ-WRITE LANE ONLY, for userdir_recheck's reason: cleanstorage calls it after its userdir_recheck, and the
# top level calls it guarded by [ "$LANE" = rw ] on the line above that one.
# NWP-20261126-18: reap_retry_run's rewritten list replaces the old one only when it is a regular file with one full
# line per kept uid (a `wc -l` that exits 0 and prints a number); otherwise the list is kept byte for byte and roam.log gets one line of counts. A kept list can
# still name a uid this pass cleared: the next pass finds nothing left for it and writes class=retried once more.
reap_retry_add() {
  local _f="$STATE/reap-pending"
  case "$1" in ''|0*|*[!0-9]*) return 0 ;; esac
  [ "$1" -ge 10 ] || return 0
  [ -f "$_f" ] && grep -qE -- "^$1 [0-9]+\$" "$_f" 2>/dev/null && return 0
  { [ -f "$_f" ] && cat "$_f"; echo "$1 0"; } 2>/dev/null | tail -n 32 > "$_f.tmp" 2>/dev/null \
    && chmod 600 "$_f.tmp" 2>/dev/null && mv -f "$_f.tmp" "$_f" 2>/dev/null
  return 0
}

reap_retry_run() {
  local _f="$STATE/reap-pending" _u _k _t _n=0 _d _p _left _got
  [ -f "$_f" ] || return 0
  userdir_has_record 0 || return 0
  ( : > "$_f.tmp" )
  while read -r _u _k; do
    case "$_u" in ''|0*|*[!0-9]*) continue ;; esac
    [ "$_u" -ge 10 ] || continue
    case "$_k" in 0|1|2) ;; *) _k=0 ;; esac
    if [ "$_u" = "${uid:-}" ] || userdir_has_record "$_u"; then
      echo "$_u $_k" >> "$_f.tmp"; _n=$((_n + 1)); continue
    fi
    _left=""
    for _d in system_ce system_de misc_ce misc_de user user_de media vendor_ce vendor_de; do
      _p="/data/$_d/$_u"
      [ -e "$_p" ] || continue
      rm -rf "$_p" 2>/dev/null
      [ -e "$_p" ] && _left="$_left $_p"
    done
    for _p in $(extra_user_paths "$_u"); do
      [ -e "$_p" ] || continue
      rm -rf "$_p" 2>/dev/null
      [ -e "$_p" ] && _left="$_left $_p"
    done
    _t=$((_k + 1))
    if [ -z "$_left" ]; then
      echo "$(date +%s) uid=$_u class=retried tries=$_t" >> /data/nowhere/reap-ledger 2>/dev/null
      chmod 600 /data/nowhere/reap-ledger 2>/dev/null
      echo "[roamd] reap retry user $_u cleared tries=$_t $(date)" >> "$LOG"
    elif [ "$_t" -lt 3 ]; then
      echo "$_u $_t" >> "$_f.tmp"; _n=$((_n + 1))
      echo "[roamd] reap retry user $_u still left tries=$_t of 3 $(date)" >> "$LOG"
    else
      # The survivors are unquoted, as in the reap's own row: see the log_scrub NOTE in cleanstorage.
      echo "$(date +%s) uid=$_u class=gaveup tries=3 survives:$_left" >> /data/nowhere/reap-ledger 2>/dev/null
      chmod 600 /data/nowhere/reap-ledger 2>/dev/null
      echo "[roamd] reap retry user $_u GAVE UP tries=3 $(date)" >> "$LOG"
    fi
  done < "$_f"
  if [ "$_n" = 0 ]; then
    rm -f "$_f" "$_f.tmp" 2>/dev/null
  else
    _got=-
    if [ -f "$_f.tmp" ] && [ ! -L "$_f.tmp" ]; then
      _got=$(wc -l 2>/dev/null < "$_f.tmp") || _got=-
      _got=${_got#"${_got%%[! ]*}"}; case "$_got" in ''|*[!0-9]*) _got=- ;; esac
    fi
    if [ "$_got" = "$_n" ]; then
      chmod 600 "$_f.tmp" 2>/dev/null; mv -f "$_f.tmp" "$_f" 2>/dev/null
    else
      rm -f "$_f.tmp" 2>/dev/null
      echo "[roamd] reap retry: the pending list could not be rewritten ($_got of $_n lines) -- kept unchanged (NWP-20261126-18) $(date)" >> "$LOG"
    fi
  fi
  return 0
}

# reap_live_other <uid> (NWP-20261129-06): print the uid of a live session other than <uid> and return 0, else return 1.
# A reap's Bluetooth clear and media-daemon stop are device-wide, and they are safe only with no other session in
# front. $STATE/.roamsession names the live session (core/agent/roamsession_marker.go), and every session end removes it
# before its reap, so a marker that names <uid> is the reaped session's own. Any other marker is a live session, a
# damaged one too (roamSessionExists counts it): `?` stands for a line 3 that is not a uid. ONLY line 3 is read: lines
# 1-2 are the profile name and the passphrase, and they never reach a variable or a log.
reap_live_other() {
  local _rlou
  [ -s "$STATE/.roamsession" ] || return 1
  _rlou=$(sed -n 3p "$STATE/.roamsession" 2>/dev/null)
  [ "$_rlou" = "$1" ] && return 1
  case "$_rlou" in ''|*[!0-9]*|0?*) _rlou='?' ;; esac
  echo "$_rlou"
  return 0
}

# reap_media_mounted <uid> (NWP-20261129-06): 0 when a mount point lies at or under user <uid>'s own dirs, the mounts
# that would block the reap's rm, and also when the table cannot be read or reads empty (stop_mediad's rule: an unread
# table is never "no mount"). Else 1. `<dir>` and `<dir>/*`, so user 11 never matches user 110; these paths hold no
# escaped character, so field 2 is compared raw. One read, through a here-document, never a printf argument (E2BIG).
reap_media_mounted() {
  local _rmt _rmrc _rmd _rmp _rmr
  _rmt=$(cat /proc/mounts 2>>"$LOG"); _rmrc=$?
  { [ "$_rmrc" -eq 0 ] && [ -n "$_rmt" ]; } || return 0
  while read -r _rmd _rmp _rmr; do
    case "$_rmp" in
      "/data/user/$1"|"/data/user/$1"/*|"/data/user_de/$1"|"/data/user_de/$1"/*|"/data/media/$1"|"/data/media/$1"/*) return 0 ;;
    esac
  done <<EOF_RMM
$_rmt
EOF_RMM
  return 1
}

# Orphan per-user storage cleanup (P4, DIA-20260625-13): removeUser leaves /data/system_ce/<uid> (+ misc_ce) on
# this FBE build, so a REUSED user-id inherits the stale, key-mismatched CE and crashes system_server on unlock
# (AccountManagerService accounts_ce.db, code 14 SQLITE_CANTOPEN). The chooser calls this AFTER removeUser -- the
# uid is gone, so there's no live user to race -- to rm the orphaned per-uid dirs; the system recreates fresh ones
# for the next user with that id. HARD GUARD: only secondary users (uid >= 10) -- never touch user 0's storage.
# ⚠ SUPERSEDED in part (NWP-20261003-01): "the uid is gone, so there's no live user to race" is not always true.
# The #73 orphan sweep calls this for a uid whose removeUser may have FAILED (the chooser's
# reapOrphanSecondaryUsers does not check removeUser's result), so that user can still be live. That is why
# users/<uid> below waits for the framework's own record to go (reap_userdir_settle). The FBE-tree rm at the top
# of this op still runs without such a check.
# ⚠ SUPERSEDED in part (NWP-20261011-38): "does not check removeUser's result" no longer holds -- the #73 sweep
# now sends CLEAN-STORAGE only for a uid whose removeUser returned true, and logs "#73 removeUser <n> refused"
# otherwise. The FBE-tree rm below is still unchecked HERE, so every caller must keep that precondition.
if [ "$op" = "cleanstorage" ]; then
  case "$uid" in ''|*[!0-9]*|0?*) echo "ERR-UID" > "$RES"; chmod 600 "$RES"; exit 0;; esac
  # NWP-20261119-26 (Q038): system_server's start count at the reap's start, read again before the husk rmdir
  # below. Empty or not a number is UNKNOWN (no getprop, or a read the policy denies), kept as "". Above the
  # REJECT line, so that line stays directly before userdir_recheck (test-userdir-orphan.sh's P6 pins that).
  _ud_ssc0=$(getprop sys.system_server.start_count 2>/dev/null); case "$_ud_ssc0" in ''|*[!0-9]*) _ud_ssc0="" ;; esac
  if [ "$uid" -lt 10 ]; then echo "[roamd] cleanstorage REJECT uid $uid (<10) $(date)" >> "$LOG"; echo "ERR-UID" > "$RES"; chmod 600 "$RES"; exit 0; fi
  userdir_recheck   # NWP-20261104-14 (Q037): earlier timeout/blind reaps' users/<n>, before this reap's own work
  reap_retry_run   # NWP-20261114-15 (#67)
  loc_release "$uid" reap   # NWP-20261016-45: the reap's backstop for the location globals; another owner is left alone
  md_release "$uid" reap   # NWP-20261026-05: the reap's backstop for mobile data; another owner is left alone
  dt_release "$uid" reap   # NWP-20261027-05: the reap's backstop for the device toggles; another owner is left alone
  dr_release "$uid" reap   # NWP-20261028-07: the reap's backstop for data roaming; another owner is left alone
  hs_release "$uid" reap   # NWP-20261028-10: the reap's backstop for the hotspot; another session's is left alone by the gate
  stop_mediad reap "$uid"   # #84 P3d: a defunct overlay inside the removed user's dirs would block the rm below (NWP-20261129-06: left running when a live session holds it and no such mount exists)
  for d in system_ce system_de misc_ce misc_de user user_de media vendor_ce vendor_de; do
    rm -rf "/data/$d/$uid" 2>> "$LOG"
  done
  rm -rf "$DE_PARK_ROOT/$uid" 2>> "$LOG"   # NWP-20261005-23: a reaped session's parked account file goes with it
  rm -f "$STATE/.cutoff.$uid" "$STATE/.cutoff.$uid".* 2>/dev/null   # NWP-20261011-04: the reaped session's cutoff record and its .new/.tmp scratch (package names) go with it
  # NWP-20261128-36: the departed session's other per-uid package records go with it, for the same reason as its
  # cutoff record; its next sign-in clears them too. The odbatch3 glob keeps the dot, so uid 10 never takes uid 100's.
  [ -n "${STATE:-}" ] && rm -f "$STATE/.declined.$uid" "$STATE/.granted.$uid" "$STATE/.a11ydone.$uid" "$STATE/.autofilldone.$uid" "$STATE/od-unparked.$uid" "$STATE/od-unparked.$uid.tmp" "$STATE/.odbatch3.$uid".* 2>/dev/null   # NWP-20261128-36
  # NWP-20261130-03: the session's unfetched lists and plans. After the loop above removed the user's data trees, so
  # no vault or #de seal of this uid can follow.
  [ -n "${STATE:-}" ] && rm -rf "$STATE/odfetch.$uid" 2>/dev/null
  # DIA-20260816-03: and the paths outside the /data/<tree>/<uid> shape (see extra_user_paths above).
  for _xp in $(extra_user_paths "$uid"); do
    rm -rf "$_xp" 2>> "$LOG"
  done
  # DIA-20260807-16: /data/system/users/<uid> is a DIFFERENT path from the /data/system_*/<uid> above and was
  # never in this list. removeUser deletes the user RECORD (users/<uid>.xml) but leaves the DIRECTORY, so it
  # survives as a pure orphan. Found on lynx 2026-08-07 with FIVE of them still present (22, 24, 27, 28, 29)
  # while only user 0 existed: 81 KB of app_idle_stats.xml (which packages that identity used and when),
  # appwidgets.xml, settings_secure.xml, settings_system.xml, inputmethod/subtypes.xml (their keyboard and
  # languages) and settings_ssaid.xml (per-app ANDROID_IDs, plus the profile's cross-device SSAID userkey).
  # Nothing cleared it: roamd only ever rm'd settings_ssaid.xml, and only at the NEXT login of a recycled id.
  # ⚠ SUPERSEDED (NWP-20261003-01): the `rm -rf` of users/<uid> that stood on the next line is GONE.
  # "removeUser ... leaves the DIRECTORY" holds only when the framework's own delete does not happen. Normally
  # the framework deletes users/<uid> itself (destroyUserData), then the record, last (see the NWP-20261003-01
  # note above userdir_has_record). This rm ran straight after removeUser was requested, before either, so it
  # caught nothing written afterwards: the 2026-10-02 lynx orphan was put back by a framework writer after it
  # ran. What it DID do, which nothing else did in the same boot:
  #  - removed users/<uid> when destroyUserData was skipped or failed. reap_userdir_settle still does that, once
  #    the record is gone (userdir=...,atanchor);
  #  - removed it for a uid whose removeUser FAILED (the #73 sweep reaches this op without checking). That user
  #    may be LIVE, so deleting its directory was the harm: under the NWP-20261003-01 framework patch a missing
  #    users/<uid> makes that user's writes be refused for the rest of its session.
  # reap_userdir_settle, after the Bluetooth clear below, now removes it only once the record triple is gone,
  # and the survivor loop removes it again if a writer puts it back.
  # THE TRADE, accepted deliberately: when the record never goes (anchor:timeout -- a failed removeUser, or a
  # removal slower than the 20 s bound) or cannot be seen (anchor:blind), users/<uid> is now KEPT -- cleartext,
  # settings_ssaid.xml included -- where this rm deleted it in the same boot. It stays until a later reap of
  # that uid, or the next boot: the boot wipe reaps every leftover user, and a directory with no record is
  # removed by the framework patch's boot discard, or emptied (the directory is kept) by BOOT-SWEEP's userdirs
  # category. The ledger row records every such reap.
  # #210 p2 (Bug A fix): cleanstorage is credless -- recover this session's stashed creds so keystore_push seals
  # the dump THIS session produced (matching key+data), instead of deferring into the never-sealed retry path.
  # ⚠⚠ NWP-20260917-25: ONLY THIS UID'S OWN STASH. cleanstorage arrives with name="x" and an EMPTY
  # pass (main.go, the CLEAN-STORAGE verb), so the test below fires on EVERY call and replaces BOTH
  # fields -- the "x" is discarded and the push at keystore_push uses "${name}#keys" under "$pass",
  # both taken from the stash, with $uid compared against nothing.
  #
  # That is fine for the logoff, where the `out` that just ran wrote this stash for this very uid. It
  # is NOT fine for the #73 orphan sweep, which BY CONSTRUCTION reaps a uid that is not the session
  # holding the stash (it keeps the cold-locked uid and removes the others). Unchecked, that pushes the
  # REAPED user's keystore dump into the STASHED profile's #keys scope -- and the push seals $KSTAGE as
  # the WHOLE scope, so the victim's carried bundles are REPLACED, not merged. Irreversible, and on a
  # profile that did nothing but be cold-locked at the time.
  #
  # ⚠ It was never REACHED, as far as anyone can show: the prune below strips a uid's KS_MAP rows
  # at its own cleanstorage, so a later sweep finds no package mapping, _kn is 0 and keystore_push
  # early-outs without pushing. But that is an INCIDENTAL guard standing somewhere else, and the one
  # here is the one that reads the credential. Refusing a foreign stash costs a deferred dump for an
  # orphan (the documented, amnesia-correct outcome); adopting one costs a live profile its sign-ins.
  if { [ -z "$name" ] || [ -z "$pass" ]; } && [ -f "$KS_CREDS" ]; then
    _ksu=$(sed -n 3p "$KS_CREDS")
    if [ -n "$_ksu" ] && [ "$_ksu" = "$uid" ]; then
      name=$(sed -n 1p "$KS_CREDS"); pass=$(sed -n 2p "$KS_CREDS")
      _kss=$(sed -n 4p "$KS_CREDS")  # NWP-20261007-12: the chip secret, so a tied #keys head opens for the push
      [ -n "$_kss" ] && export NOWHERE_SE_SECRET="$_kss"
      unset _kss
    else
      # Loud on purpose: a silent defer is exactly what made #210 p2 undiagnosable. No credential and
      # no profile name in the log -- the uids alone say which two sessions were involved.
      echo "[roamd] cleanstorage uid $uid: keystore stash belongs to uid ${_ksu:-none} -- NOT adopting it; this dump defers rather than sealing into another profile's #keys $(date)" >> "$LOG"
    fi
    unset _ksu
  fi
  keystore_push wait   # #210 p2: seal what keystore2 dumped at remove_user (wait for the async dump); best-effort
  _ksv="$KS_VERDICT"  # DIA-20260812-11 (#115): capture BEFORE anything else can call keystore_push again
  rm -f "$KS_DROP" "$KS_DROP.new" 2>/dev/null   # NWP-20261102-05: whatever the verdict, the list never outlives the reap it was staged for
  _kssv="${KS_STAGE_VERDICT:-$_ksv}"  # NWP-20261124-13: the staging verdict, captured with _ksv (notsealed-unmapped keeps the staging)
  ks_reap_clear "$uid" "$_kssv"   # NWP-20261114-18, NWP-20261124-13 (#6): after a sealed, nothing-to-seal or notsealed push, this uid's keystore-in/<uid> and nowhere-import bundles go
  # DIA-20260812-11 (#115): a dump we could not seal is unsealable FOREVER from this point -- the prune below
  # removes the KS_MAP rows any retry would need to name it. It is keystore export material for a departed
  # identity, in /data/misc, which survives the wipe AND the power-off, under a filename that re-derives the
  # uid. So destroy it here rather than "keeping it for a retry" that is structurally guaranteed to drop it.
  # The loss is real and is the lesser one: those apps ask the user to sign in again on the next roam, which
  # is what already happens today -- the difference is that the key material no longer sits on the disk of a
  # device whose whole promise is that a power-off leaves nothing.
  if [ "$_ksv" = notsealed ]; then
    for _kx in "$KS_EXPORT/$uid"[0-9][0-9][0-9][0-9][0-9].keys; do   # NWP-20261114-18: this uid's dumps only; another reaped user's waits for its own reap
      [ -e "$_kx" ] || [ -L "$_kx" ] || continue
      rm -f "$_kx" 2>>"$LOG"
    done
    unset _kx
    echo "[roamd] reap: destroyed the unsealable #keys dump for user $uid (it could never be named again) $(date)" >> "$LOG"
  fi
  rm -f "$KS_CREDS" 2>/dev/null   # #210 p2: creds consumed
  # DIA-20260807-16: prune THIS uid's rows from the two keystore sidecars. Both are append-only while every
  # other KS_* path is cleared, so they accumulated a cleartext record of which apps each session kept signed
  # in -- observed on lynx: 60 lines of "<ns> <pkg>", e.g. a departed session's shopping app, tagged by roamed
  # uid. A namespace is uid*100000 + appId, so this uid's rows are exactly those whose ns starts with it.
  # MUST run AFTER keystore_push above, which reads KS_MAP to name the dump by package -- pruning first would
  # make every sealed key anonymous, which is the #210 p2 bug over again.
  # NWP-20260826-11: the census joins them for the same reason. It is append-only by design (keystore2 only
  # ever adds), and its rows are the same shape -- a bare namespace -- so the same prune applies. Leaving it
  # would let a departed session's app uids sit on disk for the rest of the boot; keystore2 will not re-add
  # them, because the user they belong to no longer exists.
  # NWP-20261015-32: nothing serves the census any more, but keystore2 still writes it until its half is retired, so the prune stays.
  # NWP-20261126-13: a failed filter never truncates. The old loop always ran `cat tmp > file`: a temp that could not
  # be created ($STATE full, after keystore_push staged the #keys bundles there) emptied the map, and a parked
  # session's reap then sealed none of its Keystore dumps. Now a file is rewritten only when grep returned 0 or 1 AND
  # its temp exists (in bash a redirection that cannot open its file also returns 1). Otherwise the file stays as it
  # was and one FAILED line names the uid. The map is written to keystore-map.reap beside it and renamed over it
  # (roamd is its only writer; ks_signin_reset does the same). The census and the keep-list are rewritten IN PLACE:
  # keystore2 appends to the census, and a rename would give it a file with another inode.
  # KS-PRUNE-BEGIN (NWP-20261126-13)
  rm -f "$KS_MAP.reap" 2>/dev/null
  if [ -s "$KS_MAP" ]; then
    grep -vE "^${uid}[0-9]{5}( |$)" "$KS_MAP" > "$KS_MAP.reap" 2>/dev/null; _ksmr=$?
    case "$_ksmr" in 0|1) ;; *) _ksmr=fail ;; esac
    [ -f "$KS_MAP.reap" ] || _ksmr=fail
    if [ "$_ksmr" = fail ] || ! mv -f "$KS_MAP.reap" "$KS_MAP" 2>>"$LOG"; then
      echo "[roamd] reap: keystore-map prune FAILED for user $uid -- the map is unchanged (NWP-20261126-13) $(date)" >> "$LOG"
    fi
  fi
  rm -f "$KS_MAP.reap" 2>/dev/null
  for _ksf in "$KS_KEEP" "$KS_CENSUS"; do
    [ -s "$_ksf" ] || continue
    case "$_ksf" in "$KS_CENSUS") _kspl=census ;; *) _kspl=keep-list ;; esac
    rm -f "$STATE/.ksprune" 2>/dev/null
    grep -vE "^${uid}[0-9]{5}( |$)" "$_ksf" > "$STATE/.ksprune" 2>/dev/null; _kspr=$?
    case "$_kspr" in 0|1) ;; *) _kspr=fail ;; esac
    [ -f "$STATE/.ksprune" ] || _kspr=fail
    if [ "$_kspr" = fail ]; then
      echo "[roamd] reap: $_kspl prune FAILED for user $uid -- the $_kspl is unchanged (NWP-20261126-13) $(date)" >> "$LOG"
    else
      cat "$STATE/.ksprune" > "$_ksf" 2>/dev/null
    fi
    rm -f "$STATE/.ksprune" 2>/dev/null
  done
  unset _ksf _ksmr _kspr _kspl
  # KS-PRUNE-END
  # DIA-20260804-08: reap this user's account staging. acct-hold-<uid> holds the profile's account rows in
  # CLEARTEXT under /data/nowhere, and acct_reload only removes it when it actually runs -- a session where no
  # sandboxed-Play app is ever tapped leaves it behind forever. Found on lynx: acct-hold-11 was still on disk
  # after user 11 was wiped, containing the real Google account row. That outlives the amnesiac wipe it is
  # supposed to be subject to, so reap it with the rest of the user's state.
  rm -rf "/data/nowhere/acct-hold-$uid" "/data/nowhere/acct-deferred-$uid" 2>>"$LOG"
  # NWP-20261128-09: the #apps reuse pool (package names, APK bytes) lives for one session only. Unconditional: the pool
  # of another uid costs that session one cache miss.
  rm -rf /data/nowhere/appcode-reuse 2>>"$LOG"
  rm -rf /data/nowhere/appcode-dormant 2>>"$LOG"   # NWP-20261128-01: package names and _meta of the last #apps seal
  [ -z "${STATE:-}" ] || rm -f "$STATE/appcode-pm-snapshot" 2>>"$LOG"   # NWP-20261130-16: every installed package's name, left by a killed seal
  # DIA-20260807-03: #154's clear was wired to ONE exit verb -- the logoff seal, via a marker that only
  # `sweepmedia` wrote and only handleLogout's non-LOCAL branch reached. Every other way a session can end left
  # the bonds sitting on the device: a throwaway/LOCAL logoff, the 12h coldWipe, delete-my-profile, a rollback,
  # the parked-gate orphan sweep, and the boot cleanup after a battery death. cleanstorage is where they all
  # converge -- the chooser calls it after EVERY removeUser (doRemove, coldWipe's doRemove, the #73 orphan
  # sweep) and BootReceiver calls it for each leftover user at boot. So the clear belongs HERE, as the net under
  # all of them, rather than bolted onto each verb in turn where the next teardown path added would simply not
  # have it. Credless by definition (the chooser passes name="x"), so this is a pure wipe: no profile to restore.
  # NWP-20261129-06: not while another session is live. ChooserActivity.reapSupersededColdLock runs this op after the
  # new session's `in` laid its pairings down (bt_reset "$USERDIR") and its GRANT-PERMS started its mediad, and the reaped
  # user's own state is off the device already (its cold lock ran btpark and coldsweep). A clear here empties the new
  # session's pairings and name, and its next bt_seal_capture then removes them from the seal as well. Status 2 is that
  # refusal. Residual: when the cold lock's clear and the new sign-in's clear both failed, the departed pairings stay
  # until the live session's own reap.
  bt_reset "" reap "$uid"; _rbrc=$?
  if [ "$_rbrc" = 0 ]; then echo "[roamd] bt: device cleared at reap (user $uid) $(date)" >> "$LOG"
  elif [ "$_rbrc" != 2 ]; then echo "[roamd] bt ERR: device NOT cleared at reap (user $uid) $(date)" >> "$LOG"; fi
  # NWP-20261003-01: users/<uid> is removed HERE, once the framework has finished removing the user (see
  # reap_userdir_settle), not at the top of this op, where the rm ran before the framework had deleted anything.
  # Placed after the keystore wait and the Bluetooth clear so the time those already spend counts toward the
  # anchor rather than adding to it.
  reap_userdir_settle "$uid"
  # DIA-20260808-06: SAY WHAT ACTUALLY HAPPENED. The rm loop above is the backstop for a removeUser that did
  # not finish, and under enforcing it CANNOT complete on its own. Measured on lynx 2026-08-08 by querying the
  # live policy through the selinuxfs access node:
  #   - unlinking /data/<tree>/<uid> needs write+remove_name on the PARENT, and none of the three parent types
  #     grants either (system_userdir_file, media_userdir_file, vendor_userdir_file)
  #   - /data/vendor_{ce,de}/<uid> cannot even be LISTED (vendor_data_file: read/write/remove_name/rmdir all
  #     denied), and that is where per-user biometric storage lives (fpdata/facedata)
  # It CAN empty the six system trees and /data/media, whose per-user dirs are system_data_file /
  # media_rw_data_file. So the loop clears what it can reach and leaves the rest -- and the op then reported
  # the same "cleanstorage user N" either way, which made a backstop that never fires read exactly like one
  # that did. The rm errors do land in this log, but nothing summarised them and nothing failed.
  # Existence needs NO new permission (getattr + search are already allowed), so check it and NAME survivors.
  # Bounded re-check first: the chooser calls this straight after removeUser, which completes ASYNCHRONOUSLY,
  # so a single immediate look would cry wolf on a reap that is merely still in progress.
  _reapleft=""; _reapi=0; _reapcap=12; _ud_quiet=0; _ud_seen=0; _ud_capt=0
  while [ "$_reapi" -lt "$_reapcap" ]; do
    # NWP-20261003-01: a writer can put users/<uid> back AFTER the anchor -- SettingsState writes its whole
    # map up to 2 s after a change (MAX_WRITE_SETTINGS_DELAY_MILLIS) -- so look again on every poll and remove it
    # again. Once this reap has removed something from users/<uid> -- at the anchor (atanchor) or later (after)
    # -- a writer may still be active, so the loop may not end until 12 polls (3 s, longer than that 2 s) have
    # passed since the last removal. Its cap rises only as far as that quiet tail needs: to 13 past the poll that
    # counted the removal (the 12th quiet poll is the 12th after it, and has to run), never above 40 polls (10 s).
    # So a reap that cannot end early -- an FBE tree survives it -- runs no further than the tail: 13 polls for
    # a removal at the anchor, where it ran 12 before. A removal that LEFT the directory does not restart the
    # quiet count: nothing can be re-created while it is still there, and the rm that finally clears it restarts
    # it. But a RE-CREATION whose rm is refused (a writer racing it) raises the cap the same way, once for that
    # removal (_ud_capt is the took count the cap was last raised for), whether a tail is running or not: the cap
    # -- a tail's, or the base 12 polls a surviving FBE tree runs out -- is the only budget the loop has, so one
    # counted on its last poll would get no poll to retry its rm, and a directory that never clears would move the
    # cap on every poll. With took past _ud_capt, after > 0 says exactly that: past the first look, a LEFT fold can
    # only be a re-creation. Only a LEFT at the reap's first look (atanchor, after:0) keeps the base cap, whose 12
    # polls are all retries of its rm. Only behind an OK anchor: after a timeout or a blind anchor the user may be
    # live, and users/<uid> is reported below as it was before this change, never removed. A reap that found
    # nothing in users/<uid> ends on exactly the poll it did before. Writes far later than this (an AppIdleHistory
    # flush, which follows usage activity rather than a timer, or a shutdown flush) are the boot sweep's.
    if [ "$_ud_anchor" = ok ]; then
      reap_userdir_take "$uid"
      if [ "$_ud_took" -gt "$_ud_seen" ] && [ -z "$_ud_left" ]; then
        _ud_seen=$_ud_took; _ud_capt=$_ud_took; _ud_quiet=0
        _reapcap=$((_reapi + 13)); [ "$_reapcap" -gt 40 ] && _reapcap=40
      else
        _ud_quiet=$((_ud_quiet + 1))
        if [ "$_ud_took" -gt "$_ud_capt" ] && [ "$_ud_after" -gt 0 ]; then
          _ud_capt=$_ud_took; _reapcap=$((_reapi + 13)); [ "$_reapcap" -gt 40 ] && _reapcap=40
        fi
      fi
    fi
    _reapleft=""
    for _d in system_ce system_de misc_ce misc_de user user_de media vendor_ce vendor_de; do
      [ -e "/data/$_d/$uid" ] && _reapleft="$_reapleft /data/$_d/$uid"
    done
    [ -e "/data/system/users/$uid" ] && _reapleft="$_reapleft /data/system/users/$uid"
    # DIA-20260816-03: same list the rm loop uses, so a path can never be reaped-but-unreported or
    # reported-but-unreaped.
    for _xp in $(extra_user_paths "$uid"); do
      [ -e "$_xp" ] && _reapleft="$_reapleft $_xp"
    done
    [ -z "$_reapleft" ] && { [ "$_ud_took" = 0 ] || [ "$_ud_quiet" -ge 12 ]; } && break
    _reapi=$((_reapi + 1)); sleep 0.25
  done
  # NWP-20261119-26 (Q038): an EMPTY users/<uid> still there when the loop ends is removed here, with rmdir.
  # reap_userdir_take counts it as gone and never removes it, because a creation in progress looks the same
  # (UserManagerService creates the directory empty and writes the record after it). But a husk left in place
  # turns the NWP-20261003-01 framework patch's refusal off for this id: the patch refuses only the RE-CREATION
  # of a MISSING users/<n>, so a later writer (an AppIdleHistory flush, SettingsState, a shutdown flush) would
  # fill it in cleartext, unrefused, until the next user given this id or the next boot.
  # Why it is safe: ids are not reused within one system_server lifetime, so while the start count is the one
  # this reap read at its start, an empty users/<uid> of this removed id cannot be a new user's creation. rmdir
  # removes only an empty directory: a writer that filled it since the look makes rmdir fail, and it is
  # classified below as it was before. Only behind an OK anchor (after a timeout or a blind anchor the user may
  # be live), never through a symbolic link, never while a record exists.
  # An UNKNOWN count (either read) keeps the husk, as before this change: that is the fail-safe until a device
  # shows roamd can read the property on an enforcing build. The log line says which arm ran; it names no file.
  # RESIDUAL: a system_server restart between the user's removal and the reap's start is NOT seen (both reads
  # come after it), nor a restart plus a new user given this id between the second read and the rmdir.
  _ud_d="/data/system/users/$uid"
  if [ -e "$_ud_d" ] || [ -L "$_ud_d" ]; then
    _ud_hk=""
    if [ "$_ud_anchor" != ok ]; then _ud_hk="anchor $_ud_anchor"
    elif [ -L "$_ud_d" ]; then _ud_hk=link
    elif [ ! -d "$_ud_d" ]; then _ud_hk="not a directory"
    elif ! _ud_l=$(ls -A "$_ud_d" 2>/dev/null) || [ -n "$_ud_l" ]; then _ud_hk="not empty"
    elif userdir_has_record "$uid"; then _ud_hk=record
    else
      _ud_ssc1=$(getprop sys.system_server.start_count 2>/dev/null); case "$_ud_ssc1" in ''|*[!0-9]*) _ud_ssc1="" ;; esac
      if [ -z "$_ud_ssc0" ] || [ -z "$_ud_ssc1" ]; then _ud_hk="count unknown"
      elif [ "$_ud_ssc0" != "$_ud_ssc1" ]; then _ud_hk="count changed"
      elif ! rmdir "$_ud_d" 2>/dev/null || [ -e "$_ud_d" ]; then _ud_hk="rmdir refused"
      fi
    fi
    if [ -z "$_ud_hk" ]; then
      _ud_x=""; for _p in $_reapleft; do [ "$_p" = "$_ud_d" ] || _ud_x="$_ud_x $_p"; done; _reapleft=$_ud_x
      echo "[roamd] reap husk user $uid: removed (count unchanged) $(date)" >> "$LOG"
    else
      echo "[roamd] reap husk user $uid: kept ($_ud_hk) $(date)" >> "$LOG"
    fi
  fi
  # DIA-20260812-11 (#115): THREE outcomes, not two. `[ -e ]` cannot tell an EMPTY HUSK (every file gone, the
  # directory itself unlinkable -- a tidy-disk nuisance) from RESIDUE (the departed identity's data still
  # there -- an amnesia violation). Reporting both as "INCOMPLETE" would make the line that matters look like
  # the line that does not, and train whoever reads it to skip both. That is the dontaudit lesson this tree
  # already paid for. So classify: a directory with any entry is residue, an empty one is a husk.
  #
  # WHAT "RESIDUE" MEANS PER TREE -- do not read one severity into all of them (established 2026-08-12):
  #  - the FBE trees (/data/{system,misc,vendor}_{ce,de}, user, user_de, media): removeUser destroys the
  #    per-user CE **and** DE keys as a step SEPARATE from the directory removal, and that step succeeds even
  #    when this rm fails -- device-measured on lynx, /data/misc_de/<uid> comes back with ENCRYPTED filenames.
  #    So entries here are ciphertext nobody holds a key for: a disk + metadata leak, not readable content.
  #  - /data/system/users/<uid> is the exception and the serious one. It is NOT under a per-user key; it lives
  #    under the system's own DE key, which is always available -- which is exactly why roamd can read and rm
  #    settings_ssaid.xml at all. Its contents are CLEARTEXT and, because secondary ids are recycled, they are
  #    ADOPTED by whoever gets this id next: app_idle_stats (which apps that identity used, when), the
  #    keyboard and languages, and settings_ssaid.xml -- the profile's cross-device SSAID userkey, i.e. the
  #    very thing that makes an app present the same device identity across a roam. Five of these were found
  #    surviving on lynx (DIA-20260807-16), across reboots.
  #    ⚠ SUPERSEDED in part (NWP-20261003-01): "ADOPTED by whoever gets this id next" no longer holds on an
  #    image that carries the NWP-20261003-01 framework patch: it discards whatever is in users/<id> when the id
  #    is given to a new user, and at every boot. On an image without it (the Diaspore lane, where every
  #    framework patch is applied by hand) it still holds. The contents are CLEARTEXT at rest on every image.
  # The classifier does not encode that difference in the verdict yet; it is recorded here so nobody reads a
  # `residue` on an FBE tree as "the next user can read the last user's files", and so the sweep that will
  # eventually retry this knows which path to prioritise.
  _reapclass=clean; _reapres=""; _reaphusk=""
  for _p in $_reapleft; do
    if [ -n "$(ls -A "$_p" 2>/dev/null)" ]; then _reapres="$_reapres $_p"; else _reaphusk="$_reaphusk $_p"; fi
  done
  [ -n "$_reaphusk" ] && _reapclass=husk
  [ -n "$_reapres" ] && _reapclass=residue
  case "$_reapclass" in residue|husk) for _p in $_reapres$_reaphusk; do [ "$_p" = "/data/system/users/$uid" ] || { reap_retry_add "$uid"; break; }; done ;; esac   # NWP-20261114-15 (#67): an FBE or extra path survived; users/<uid> alone is userdir_recheck's
  # NOTE the survivor lists are deliberately NOT double-quoted in the log lines below. log_scrub redacts every
  # quoted token as a profile name (DIA-20260807-14), so quoting these would rewrite the paths to <name> and
  # destroy the one diagnostic this whole change exists to produce -- open task #105, the same trap.
  case "$_reapclass" in
    residue) echo "[roamd] REAP-RESIDUE user $uid -- the departed identity's DATA is still on disk, survives:$_reapres husk:$_reaphusk $(date)" >> "$LOG" ;;
    husk)    echo "[roamd] REAP-HUSK user $uid -- emptied but not unlinked (no data left), survives:$_reaphusk $(date)" >> "$LOG" ;;
    *)       echo "[roamd] reap clean: no per-user dir survives for user $uid $(date)" >> "$LOG" ;;
  esac
  # NWP-20261003-01: the users/<uid> verdict rides the same line, unquoted like the survivor lists (see the
  # NOTE above). anchor:ok,after:0 is the normal reap.
  #  - after:>0: a writer put the directory back after this reap had seen it gone -- the framework patch absent
  #    from this image, or a writer it does not cover.
  #  - atanchor: it was still (or already) there when the record went -- a skipped or failed destroyUserData,
  #    or a writer that put it back before this reap first looked. Removed all the same.
  #  - anchor:timeout: the removal had not finished. anchor:blind: the records could not be seen. In both,
  #    users/<uid> was left alone.
  #  - left: an rm could not clear it.
  #  - link: a symbolic link was found at users/<uid> (NWP-20261011-42). It was removed, or is left if `left`
  #    is there too, and never followed: nothing is censused through it, so a link that stays reads remains:link.
  _udf="anchor:$_ud_anchor,polls:$_ud_polls,after:$_ud_after${_ud_atanchor:+,atanchor}${_ud_left:+,left}${_ud_link:+,link}"
  case "$_ud_anchor" in timeout|blind) userdir_pending_add "$uid" ;; esac   # NWP-20261104-14 (Q037): re-checked at the next read-write-lane op
  _udc=none; [ "$_ud_took" != 0 ] && _udc="files:$_ud_files other=$_ud_other"
  [ -n "$_ud_left" ] && { if [ -L "/data/system/users/$uid" ]; then _udc="$_udc remains:link"; else _udc="$_udc remains:$(userdir_census "/data/system/users/$uid")"; fi; }
  # NWP-20261128-39 (Q039's measurement): the reap's added RW-lane wait is (polls + loop) x 0.25 s, settle plus tail.
  echo "[roamd] cleanstorage user $uid class=$_reapclass keys=$_ksv userdir=$_udf loop=$_reapi cap=$_reapcap $(date)" >> "$LOG"
  # A DURABLE record, because none of the above survives. $RES is on the RAM tmpfs and is deleted by its
  # reader; roam.log is truncated to a tail by log_scrub on the very next line. The ledger is plain /data, is
  # not in NOWHERE_LOGS so the scrub never touches it, and carries NO profile name -- only uid, class and
  # paths, which is strictly less than the surviving directories themselves already disclose. This is the
  # input a retry needs, and until one exists it is how we learn how often this actually happens in the field.
  # NWP-20261003-01: ALSO written when the users/<uid> verdict is not the normal one, even if the class is
  # clean: whenever this reap removed anything from users/<uid> (after or atanchor), and whenever the anchor was
  # not ok. A directory this reap removed leaves nothing on disk to find later, and a timeout or blind anchor
  # with no directory to report leaves the class clean, so this row is the only record that either happened.
  # And whenever a link was found at users/<uid> (NWP-20261011-42): its removal takes no census, so took stays 0.
  # Its census names allowlisted framework files and counts the rest (see userdir_census).
  if [ "$_reapclass" != clean ] || [ "$_ksv" = notsealed ] || [ "$_ud_took" != 0 ] || [ "$_ud_anchor" != ok ] || [ -n "$_ud_link" ]; then
    { echo "$(date +%s) uid=$uid class=$_reapclass keys=$_ksv survives:$_reapres$_reaphusk userdir=$_udf census:$_udc"; } >> /data/nowhere/reap-ledger 2>/dev/null
    chmod 600 /data/nowhere/reap-ledger 2>/dev/null
  fi
  log_scrub "$uid"   # DIA-20260807-12: LAST -- the departed profile's name leaves the logs with the rest of its state
  # DIA-20260812-11 (#115): the verdict finally travels. It was `echo "OK"` unconditionally, so a reap that had
  # just logged REAP-INCOMPLETE told its caller it had succeeded. Safe to change: every consumer -- the daemon's
  # CLEAN-STORAGE handler and all five ChooserActivity/BootReceiver call sites -- DISCARDS this reply, so no
  # teardown can be blocked by it. It must still be a NON-EMPTY single line, and this path must never return
  # without writing it: a missing $RES holds workerMu until the caller's timeout and serialises out every login
  # and seal behind it.
  if [ "$_reapclass" = residue ]; then echo "ERR-REAP-RESIDUE" > "$RES"
  elif [ "$_reapclass" = husk ]; then echo "OK PARTIAL:reap=husk" > "$RES"
  elif [ "$_ksv" = notsealed ]; then echo "OK PARTIAL:keys=notsealed" > "$RES"
  else echo "OK" > "$RES"; fi
  chmod 600 "$RES"; exit 0
fi

# DIA-20260807-03: the credless Bluetooth clear, for teardowns that do NOT remove the user and so never reach
# cleanstorage above. Cold-lock is the one that matters: it STOPS the user (resumable, by design) and is the
# device's normal resting state, so without this a cold-locked phone sits at the gate holding that session's
# link keys for as long as it stays there. Handled here, before the name/uid arg guard, because it needs no
# credentials and no session -- like `armcred` above.
if [ "$op" = "btwipe" ]; then
  if bt_reset ""; then echo "[roamd] bt: device cleared (btwipe) $(date)" >> "$LOG"; _btw=OK
  else echo "[roamd] bt ERR: device NOT cleared (btwipe) $(date)" >> "$LOG"; _btw=ERR-BT; fi
  # DIA-20260807-12: BootReceiver calls btwipe unconditionally at every boot (DIA-20260807-09), which makes
  # this the one place the log scrub runs even when no leftover user exists -- the battery-death case, where
  # the reap below never fires and the departed name would otherwise sit on disk until the next clean logoff.
  _btw_t0=$(_ms)
  log_scrub
  # NWP-20261107-10 (Q143): the reap ledger is trimmed at boot with the logs -- the last 20 rows, none 30 days old.
  # handleRoamInOffline also runs btwipe at an offline sign-in, which only trims more often. A wrong early-boot clock
  # can only keep rows (now behind them) or drop them early (now ahead), never keep more than 20. The per-reap writes
  # (cleanstorage, bootsweep) are unchanged.
  reap_ledger_trim /data/nowhere/reap-ledger "$(date +%s)"
  _btw_t1=$(_ms)
  echo "[roamd] btwipe: log scrub and ledger trim took $(( ${_btw_t1:-0} - ${_btw_t0:-0} ))ms (NWP-20261129-20) $(date)" >> "$LOG"
  # NWP-20261129-20: the reply is LAST. runWorkerHeld returns at the first byte of $RES, and init ignores a ctl.start for
  # a oneshot that still runs, so an earlier reply let the next RW-lane op wait for the #83 lost-start recovery. That
  # op's appends would also land inside log_scrub's in-place rewrite. Residual: the daemon's other goroutines and
  # nowhere_provision.sh still append during the rewrite. Cost: BT-WIPE's callers now wait for the scrub too.
  # BootReceiver's thread: a later verb queues on the lane and does not race init. The offline sign-in:
  # handleRoamInOffline waits for this op.
  echo "$_btw" > "$RES"
  chmod 600 "$RES"; exit 0
fi

# NWP-20261027-02: the credless log scrub for a FAILED sign-in. The chooser removes that attempt's throwaway user with
# dpm.removeUser and never sends CLEAN-STORAGE, so cleanstorage's log_scrub never runs for it, and the name typed at the
# gate (login.log `roam-in BLANK NET "<name>"`, roam.log `IN <name> ...`) would sit on disk until a later reap or the next
# boot. The login daemon fires this after it has written the BLANK / BLANK NET reply. No argument, as btwipe's boot call:
# no session is being reaped, so nothing is carried. The trim it runs may drop a parked cold-locked session's seal
# summary lines from before the 1 MiB cut, exactly as the boot's btwipe scrub can. Credless, before the name/uid guard.
if [ "$op" = "logscrub" ]; then
  log_scrub
  echo "OK" > "$RES"
  chmod 600 "$RES"; exit 0
fi

# NWP-20261107-01: staging_boot -- the boot sweep's `staging` category (fix 17). Per-session staging that a crash or a
# power loss leaves under the daemon's dir: acct-stage (acct_seal's copy of accounts_ce.db), acct-hold-<uid> and
# acct-deferred-<uid>, appcode-stage and its six lists, appcode-reuse (NWP-20261128-09), fetchapp, keystore-stage and
# keystore-in.
#
# WHY REMOVING EACH IS SAFE ONLY BEHIND THE MARKER CHECK AND THREE GUARDS: every entry is staging that its next
# producer rebuilds from scratch or clears (appcode_seal, acct_seal and keystore_push rm -rf their stage first,
# keystore_restore rm -rf "$KS_IN", handleFetchApp os.RemoveAll(stage)), so once no session is in any phase nothing
# reads it again. A missing marker alone does not prove that: BootReceiver sends BOOT-SWEEP after the boot wipe while
# the gate already accepts sign-ins, and the wipe skips a user a sign-in made this boot (NWP-20261014-22), so that
# session can be signing out or cold-locked while this runs. Removing its staging then does lasting harm: without
# acct-hold-<uid> / acct-deferred-<uid>, acct_seal's PENDING-PLACEMENT guard lets `out` seal the empty account db over
# the real account; without keystore-in, the reap's keystore_push leaves those bundles out of $KSTAGE, and what is
# missing from $KSTAGE is DESTROYED in the store. So nothing is removed unless all of these pass, in this order:
#  - KEPT:session: a .roamsession marker. BOOT-SWEEP is not in main.go concurrentSafeCmd, so it holds sessionMu as
#    ROAM-IN does, and the daemon writes the marker after roamd's `in` returns: with no marker no sign-in is inside its
#    `in` (where keystore_restore and acct_restore fill these). It stays first.
#  - KEPT:reap: $KS_CREDS exists. handleLogout removes the marker BEFORE its background sweepmedia and `out`, which take
#    workerMu, not sessionMu; `out` writes $KS_CREDS and the reap's keystore_push consumes it, so its presence means an
#    `out` ran and its reap has not.
#  - KEPT:user: a users/<n> record (n >= 10) still stands, by the whole triple (userdir_has_record). That covers a
#    sign-out still in sweepmedia, before `out` writes $KS_CREDS, and a parked cold lock: doColdLock removes the marker,
#    and btpark drops $KS_CREDS, while the user still exists. The ids come from the NAMES (<n>, <n>.xml, .backup,
#    .reservecopy) and only an all-digit id is tested, before any stat, as NWP-20261003-01 does: users/ also holds
#    user.list, and a getattr on it is an AVC.
#  - UNREACHABLE: the listing of users/ produced no record of user 0 (the positive control). Without it "no record"
#    means nothing, and a live user would read as gone.
# (Superseded by NWP-20261112-01 in part: keystore_restore rm -rf's only its own user's "$KS_IN/<uid>", not "$KS_IN".)
#
# NWP-20261114-23: the *.keys files of the two keystore staging dirs, $KS_IMPORT (bundles moved out of keystore-in, not
# yet consumed) and $KS_EXPORT (keystore2's dump at remove_user), are in the category too, because after a boot nothing
# can seal or consume them (the dump's reap credentials died with the tmpfs, and an import is read only by a lookup of
# its exact namespace); the dirs themselves are never removed, re-created or chmod'ed (keystore2 owns them).
#
# A symbolic link is never followed or removed. Counts only: no path, package or uid reaches LOG or the token, and rm's
# stderr (toybox names the failing path) goes to the bit bucket. Only the fixed list below and the *.keys files of
# nowhere-import and nowhere-export: keystore-map, keystore-drop, the conf files, owner-key, reap-ledger, otacache,
# spill, enroll and the logs are not staging and are never touched.
# Sets STAGING_BOOT: KEPT:session, KEPT:reap, KEPT:user, UNREACHABLE, none, or <removed>[/LEFT:<k>][/LINK:<l>].
staging_boot() {
  local _e _n=0 _rm=0 _left=0 _lk=0 _t _p _i _s0="" _d _k
  if [ -s "$STATE/.roamsession" ]; then STAGING_BOOT=KEPT:session; return 0; fi
  if [ -e "$KS_CREDS" ]; then STAGING_BOOT=KEPT:reap; return 0; fi
  for _p in /data/system/users/*; do
    _i=${_p##*/}; _i=${_i%.reservecopy}; _i=${_i%.backup}; _i=${_i%.xml}
    case "$_i" in ''|0?*|*[!0-9]*) continue;; esac
    if [ "$_i" = 0 ]; then userdir_has_record 0 && _s0=1; continue; fi
    [ "$_i" -lt 10 ] && continue
    if userdir_has_record "$_i"; then STAGING_BOOT=KEPT:user; return 0; fi
  done
  if [ -z "$_s0" ]; then STAGING_BOOT=UNREACHABLE; return 0; fi
  # A glob over an unlistable dir expands to nothing and would read `none`.
  if ! ls -A /data/nowhere >/dev/null 2>&1; then STAGING_BOOT=UNREACHABLE; return 0; fi
  # NWP-20261116-08: keystore_push stages on $STATE now; the keystore-stage entry removes an older image's leftover.
  for _e in /data/nowhere/acct-stage \
            /data/nowhere/acct-hold-* \
            /data/nowhere/acct-deferred-* \
            /data/nowhere/appcode-stage \
            /data/nowhere/appcode-reuse \
            /data/nowhere/appcode-defer \
            /data/nowhere/appcode-dropfilter \
            /data/nowhere/appcode-dropoff \
            /data/nowhere/appcode-playstack \
            /data/nowhere/appcode-playfilter \
            /data/nowhere/appcode-dropgone \
            /data/nowhere/appcode-dormant \
            /data/nowhere/fetchapp \
            /data/nowhere/keystore-stage \
            /data/nowhere/keystore-in; do
    [ -e "$_e" ] || [ -L "$_e" ] || continue
    _n=$((_n + 1))
    if [ -L "$_e" ]; then _lk=$((_lk + 1)); continue; fi
    rm -rf "$_e" 2>/dev/null
    if [ -e "$_e" ]; then _left=$((_left + 1)); else _rm=$((_rm + 1)); fi
  done
  for _d in "$KS_IMPORT" "$KS_EXPORT"; do
    [ -n "$_d" ] || continue
    for _k in "$_d"/*.keys; do
      [ -e "$_k" ] || [ -L "$_k" ] || continue
      _n=$((_n + 1))
      if [ -L "$_k" ]; then _lk=$((_lk + 1)); continue; fi
      rm -f "$_k" 2>/dev/null
      if [ -e "$_k" ]; then _left=$((_left + 1)); else _rm=$((_rm + 1)); fi
    done
  done
  if [ "$_lk" -gt 0 ]; then
    echo "[roamd] bootsweep: $_lk staging entr(y/ies) a symbolic link -- not followed, not removed $(date)" >> "$LOG"
  fi
  if [ "$_n" -eq 0 ]; then STAGING_BOOT=none; return 0; fi
  _t=$_rm
  if [ "$_left" -gt 0 ]; then _t="$_t/LEFT:$_left"; fi
  if [ "$_lk" -gt 0 ]; then _t="$_t/LINK:$_lk"; fi
  STAGING_BOOT=$_t
}

# NWP-20261107-12 (Q037, dn-1104 #2, 2026-10-21): the re-check timer's op. The login daemon sends it every 5 minutes, and
# only while $STATE/userdir-pending is non-empty, so the users/<n> a timeout or blind reap kept is looked at again with
# no sign-in or sign-out after it. Credless like logscrub (the daemon sends no name and uid 0), so before the name/uid
# guard. It runs userdir_recheck on the read-write lane ONLY, as the top-level call does (see userdir_recheck): the
# daemon sends it there, and the guard holds even if a caller does not.
if [ "$op" = "userdirrecheck" ]; then
  [ "$LANE" = rw ] && userdir_recheck
  echo "OK" > "$RES"
  chmod 600 "$RES"; exit 0
fi

# NWP-20261201-36 (h60 #11, docs/product-decisions.md, "DECIDED: twenty answers to harvest 60"): the boot sweep's
# per-category result, reduced to what a report filed at the gate may carry. It takes the sweep's token string as $1 and
# sets BS_PLOG, with a leading space before each token. Gate scope is blind-login scope, so the copy holds keys and
# values of a fixed shape only: counts, the fixed class words, and a kept session's user id as KEPT:user<n>, as decided.
# What a value reads back, FAILED(<what it read>), FAILED(<keys>) and failed(<reason>), stays in roam.log: here it becomes
# FAILED or failed, and any other value outside the fixed shape becomes OTHER. A detail can hold spaces, so every token
# up to the one holding ")" is dropped with it. No per-category table: a category added later passes through with no edit.
# set -f: the split is unquoted, so a "*" or "?" in a value would otherwise expand against the working directory.
bootsweep_plog_line() {
  local _t _k _v _open=""
  BS_PLOG=""
  set -f
  for _t in $1; do
    if [ -n "$_open" ]; then case "$_t" in *")"*) _open="" ;; esac; continue; fi
    case "$_t" in *"("*) case "$_t" in *")"*) ;; *) _open=1 ;; esac ;; esac
    case "$_t" in *=*) ;; *) continue ;; esac
    _k=${_t%%=*}; _v=${_t#*=}
    case "$_k" in ""|*[!a-z0-9_]*) continue ;; esac
    case "$_v" in
      "FAILED("*) _v=FAILED ;;
      "failed("*) _v=failed ;;
      ""|*[!0-9A-Za-z:/]*) _v=OTHER ;;
    esac
    BS_PLOG="$BS_PLOG $_k=$_v"
  done
  set +f
}

# DIA-20260816-04 (amnesia audit fixes 4-7): the BOOT SWEEP -- system-wide residue that names departed
# identities and that NOTHING has ever cleared.
#
# WHY A SEPARATE OP RATHER THAN MORE WORK IN cleanstorage: every path below is OUTSIDE any user, so it is
# unreachable by a per-uid reap by construction. The boot-wipe could not reach them either -- it works by
# removing a USER. They have accumulated across every session this device has ever run.
#
# ORDERING IS LOAD-BEARING. BootReceiver calls this AFTER wipeLeftoverRoamedUsers, never before, because the
# boot-wipe's own removeUser calls GENERATE dropbox entries: the audit measured all 1,000 entries landing at
# 39-54s uptime, i.e. the wipe minting fresh durable records naming the slots it had just erased. Sweeping
# first would leave exactly the entries this exists to remove.
#
# Credless, like btwipe, and handled before roamd's name/uid arg guard.
if [ "$op" = "bootsweep" ]; then
  _swept=""
  # --- fix 4: orphan per-user state under /data/system that no live user names -------------------------
  # At boot, after the wipe, no secondary user should exist -- but one CAN while this runs: BootReceiver runs the
  # sweep on its own thread and the gate accepts sign-ins meanwhile, so a boot-time sign-in can be mid-creation or
  # live. The record test is what protects that user, and it is the WHOLE record triple (userdir_has_record), never
  # users/<uid>.xml alone: a rewrite renames <uid>.xml to .backup first, so a live user briefly has no <uid>.xml
  # (NWP-20261026-10). It is gated on a positive control -- user 0's record must be visible, else "no record" means
  # nothing and both categories read UNREACHABLE -- and checked AGAIN straight before each removal: that narrows the
  # window against a racing sign-in to one rm, it cannot close it (nothing orders the sweep before a sign-in).
  # UNREACHABLE: the directory exists but cannot be listed (a glob over it would expand to nothing and read =0).
  # ABSENT: only when /data/system lists and holds no such name; a failing [ -d ] alone is not an absence. A removal
  # that fails (rm's status nonzero, or the target still there) is LEFT, never counted. The lines carry counts only, and rm's stderr goes to /dev/null.
  _u0=""; userdir_has_record 0 && _u0=1
  # adservices: /data/system/adservices/<userId>
  _n=0; _nl=0; _c=""
  if [ -z "$_u0" ]; then _r=UNREACHABLE
  elif [ -d /data/system/adservices ]; then
    if ls -A /data/system/adservices > /dev/null 2>&1; then
      for _p in /data/system/adservices/*; do
        [ -e "$_p" ] || [ -L "$_p" ] || continue
        _u=${_p##*/}
        case "$_u" in ''|0?*|*[!0-9]*) continue;; esac
        [ "$_u" -lt 10 ] && continue
        userdir_has_record "$_u" || _c="$_c $_u"
      done
      for _u in $_c; do
        userdir_has_record "$_u" && continue
        rm -rf "/data/system/adservices/$_u" 2> /dev/null; _rc=$?
        if [ "$_rc" -ne 0 ] || [ -e "/data/system/adservices/$_u" ] || [ -L "/data/system/adservices/$_u" ]; then _nl=$((_nl + 1))
        else _n=$((_n + 1)); fi
      done
      _r=$_n; [ "$_nl" -gt 0 ] && _r="$_n/LEFT:$_nl"
    else _r=UNREACHABLE; fi
  elif _sl=$(ls -A /data/system 2> /dev/null); then
    case "$(printf '%s\n' "$_sl" | grep -cx adservices)" in 0) _r=ABSENT ;; *) _r=UNREACHABLE ;; esac
  else _r=UNREACHABLE; fi
  _swept="$_swept adservices=$_r"
  # JobScheduler files are named by ANDROID UID (userId * 100000 + appId), not by user id -- e.g.
  # jobs_1010188.xml is user 10, appid 10188. Divide to recover the user.
  _n=0; _nl=0; _c=""
  if [ -z "$_u0" ]; then _r=UNREACHABLE
  elif [ -d /data/system/job ]; then
    if ls -A /data/system/job > /dev/null 2>&1; then
      for _p in /data/system/job/jobs_*.xml; do
        [ -e "$_p" ] || [ -L "$_p" ] || continue
        _b=${_p##*/}; _b=${_b#jobs_}; _b=${_b%.xml}
        case "$_b" in ''|0?*|*[!0-9]*) continue;; esac
        _u=$((_b / 100000))
        [ "$_u" -lt 10 ] && continue
        userdir_has_record "$_u" || _c="$_c $_b"
      done
      for _b in $_c; do
        _u=$((_b / 100000))
        userdir_has_record "$_u" && continue
        rm -f "/data/system/job/jobs_$_b.xml" 2> /dev/null; _rc=$?
        if [ "$_rc" -ne 0 ] || [ -e "/data/system/job/jobs_$_b.xml" ] || [ -L "/data/system/job/jobs_$_b.xml" ]; then _nl=$((_nl + 1))
        else _n=$((_n + 1)); fi
      done
      _r=$_n; [ "$_nl" -gt 0 ] && _r="$_n/LEFT:$_nl"
    else _r=UNREACHABLE; fi
  elif _sl=$(ls -A /data/system 2> /dev/null); then
    case "$(printf '%s\n' "$_sl" | grep -cx job)" in 0) _r=ABSENT ;; *) _r=UNREACHABLE ;; esac
  else _r=UNREACHABLE; fi
  _swept="$_swept jobs=$_r"
  # --- NWP-20261003-01: orphaned /data/system/users/<n> ------------------------------------------------
  # A users/<n> with no record triple belongs to a removed user: a writer put it back after the reap stopped
  # watching (an AppIdleHistory flush, which follows usage activity, or a shutdown flush), or a destroyUserData
  # failed. It is cleartext, it survives reboots, and ids restart at 10, so, from GrapheneOS source, the next
  # user given that id loads it (see the note above userdir_has_record). This is the net for orphans AT REST.
  # It is not an adoption fence: nothing orders this op before the first createAndManageUser of the boot.
  #  - NUMERIC NAMES FIRST, before any stat: users/ also holds user.list, labelled user_list_data_file, and a
  #    getattr on it is an AVC. userlist.xml, user.list and the <n>.xml* records all fall out at this filter
  #    (their names are not all digits), so none of them is ever stat'ed.
  #  - CONTENTS ONLY, never the directory. A sign-in can run while this sweeps and be given exactly this id;
  #    removing the directory UserManagerService has just made for it would leave a live user with no
  #    users/<n>, whose writes the NWP-20261003-01 framework patch then refuses. An EMPTY directory owned by
  #    system is what a creation in progress looks like, and holds nothing, so it is skipped and not counted.
  #  - The record is checked again straight before the rm. That narrows the window against that sign-in; it
  #    cannot close it.
  #  - A SYMBOLIC LINK IS NEVER FOLLOWED: nothing is listed, emptied, chown'ed, chmod'ed or relabelled through
  #    one. UserManagerService never makes users/<n> a link, so one with no record was planted (system or root
  #    can), and the LINK is removed, never its target. Kept, it is the harm: the framework patch reads a link
  #    to a directory as that directory, so a late write for the removed user passes through it unrefused, into
  #    whatever it points at, and on an image without the patch the next user given that id would keep its
  #    settings there. The patch's own discards delete a link the same way, never following it. A creation in
  #    progress never makes a link, and `rm -f`, without -r, cannot remove a directory that replaced it
  #    meanwhile. A link INSIDE a real users/<n> goes with the contents: rm -rf removes a link, not its target.
  #  - THE KEPT DIRECTORY MUST BELONG TO system. The old seedssaid ran `mkdir -p users/<uid>` as root under
  #    init's umask 077, so an orphan can be root:root 0700. system_server cannot list or write that, so
  #    neither the framework patch's discard nor the user next given this id could use it: that user's settings
  #    would never persist, and a fingerprint enrolment's failed state write is rethrown by BiometricUserState
  #    on a system_server thread, which restarts the runtime. So once a directory not owned by system is empty
  #    -- emptied here, or found empty -- it gets what UserManagerService would have made: system:system, 0700,
  #    its default label. That never touches a creation in progress, which is always system's. If any of the
  #    three steps fails, the id is LEFT.
  #  - TWO POSITIVE CONTROLS, both BEFORE anything is removed: the glob must produce user 0's directory (else
  #    users/ cannot be listed), and user 0's record must be visible (else "no record" means nothing, and
  #    every LIVE user would look like an orphan). Failing either, nothing is touched and the category says
  #    UNREACHABLE, as graphicsstats and dropbox below do. A directory that cannot be listed is LEFT, never
  #    "empty". rm's stderr goes to /dev/null for the reason given at reap_userdir_take.
  # One ledger row per id, carrying the census (a link's row says `removed link` or `LEFT link` and names
  # nothing); the result line carries counts only.
  _n=0; _nl=0; _u0=""
  for _p in /data/system/users/*; do [ "${_p##*/}" = 0 ] && [ -d "$_p" ] && { _u0=1; break; }; done
  userdir_has_record 0 || _u0=""
  for _p in /data/system/users/*; do
    [ -n "$_u0" ] || break
    _u=${_p##*/}
    case "$_u" in ''|*[!0-9]*) continue;; esac
    [ "$_u" -lt 10 ] && continue
    [ -d "$_p" ] || [ -L "$_p" ] || continue
    userdir_has_record "$_u" && continue
    if [ -L "$_p" ]; then
      rm -f "$_p" 2>/dev/null
      if [ -L "$_p" ] || [ -e "$_p" ]; then _nl=$((_nl + 1)); _c="LEFT link"
      else _n=$((_n + 1)); _c="removed link"; fi
      echo "$(date +%s) userdir ctx=boot uid=$_u $_c" >> /data/nowhere/reap-ledger 2>/dev/null
      continue
    fi
    if ! _ls=$(ls -A "$_p" 2>/dev/null); then
      _nl=$((_nl + 1))
      echo "$(date +%s) userdir ctx=boot uid=$_u LEFT unreadable" >> /data/nowhere/reap-ledger 2>/dev/null
      continue
    fi
    _o=$(stat -c %u "$_p" 2>/dev/null)
    [ -z "$_ls" ] && [ "$_o" = 1000 ] && continue
    _c=$(userdir_census "$_p")
    userdir_has_record "$_u" && continue
    rm -rf "$_p"/* "$_p"/.[!.]* 2>/dev/null
    if ! _ls=$(ls -A "$_p" 2>/dev/null) || [ -n "$_ls" ]; then
      _nl=$((_nl + 1)); _c="LEFT $(userdir_census "$_p")"
    elif [ "$_o" = 1000 ]; then
      _n=$((_n + 1)); _c="cleared $_c"
    elif { chown system:system "$_p" && chmod 0700 "$_p" && restorecon "$_p"; } 2>/dev/null; then
      _n=$((_n + 1)); _c="cleared $_c owner:${_o:-none}->system"
    else
      _nl=$((_nl + 1)); _c="LEFT owner:${_o:-none} emptied $_c"
    fi
    echo "$(date +%s) userdir ctx=boot uid=$_u $_c" >> /data/nowhere/reap-ledger 2>/dev/null
  done
  chmod 600 /data/nowhere/reap-ledger 2>/dev/null
  if [ -z "$_u0" ]; then _swept="$_swept userdirs=UNREACHABLE"
  elif [ "$_nl" -gt 0 ]; then _swept="$_swept userdirs=$_n/LEFT:$_nl"
  else _swept="$_swept userdirs=$_n"; fi
  # --- fix 5: the app-op history databases -------------------------------------------------------------
  # Per-app, MILLISECOND-resolution privacy-op history: which app touched which of 20 op codes and exactly
  # when. The audit found >=2,233 rows for SIX departed slots, spanning days. A behavioural diary.
  # UNLINK the whole DB rather than DELETE-ing rows by uid: `sqlite3` does NOT exist on a `user` build (only
  # userdebug ships it), so a row-level prune would work on the bench and be silently inert in production --
  # the exact shape of the bug that left page 2 dead on every release device for a month. User 0 keeps no
  # session worth preserving on an amnesiac phone, so a full unlink is the correct backstop AND the portable
  # one. The -wal/-shm sidecars matter: the audit's row count excluded them, so it was a floor, not a total.
  # The rules fixes 8-10 state below, as they apply to a category that unlinks four NAMED files:
  #  - NO SYMLINK GUARD: this never empties a directory, it unlinks files named app_op_history_*, so a link at
  #    the directory cannot turn it into a wipe of whatever the link points at.
  #  - A DENIED LISTING IS NEVER 0: the directory is listed (ls -1A), and one that exists but cannot be listed
  #    reads UNREACHABLE. It is created lazily on the first history write, so ABSENT keeps reading 0 -- but only
  #    when /data/system lists and names no `appops`; a failing `[ -d ]` alone is a denial as often as an absence.
  #  - A FAILED UNLINK IS NEVER COUNTED AS DONE: the directory is listed again afterwards, and a database still
  #    there reads <n>/LEFT:<m> (<n>/LEFT:UNREACHABLE when that listing is denied).
  #  - COUNTS ONLY: rm's stderr goes to /dev/null, so no file name reaches the log.
  _ad="/data/system/appops"
  if [ -d "$_ad" ]; then
    if _l=$(ls -1A "$_ad" 2>/dev/null); then
      _n=$(printf '%s\n' "$_l" | grep -cE '^app_op_history_(long|short)_interval\.db')
      for _p in "$_ad"/app_op_history_long_interval.db* "$_ad"/app_op_history_short_interval.db*; do
        [ -e "$_p" ] || continue
        rm -f "$_p" 2>/dev/null
      done
      if ! _l=$(ls -1A "$_ad" 2>/dev/null); then _swept="$_swept appop_db=$_n/LEFT:UNREACHABLE"
      else
        _left=$(printf '%s\n' "$_l" | grep -cE '^app_op_history_(long|short)_interval\.db')
        if [ "$_left" -gt 0 ]; then _swept="$_swept appop_db=$_n/LEFT:$_left"
        else _swept="$_swept appop_db=$_n"; fi
      fi
    else
      _swept="$_swept appop_db=UNREACHABLE"
    fi
  elif _al=$(ls -1A /data/system 2>/dev/null) && [ -n "$_al" ] \
       && [ "$(printf '%s\n' "$_al" | grep -cx appops)" = 0 ]; then
    _swept="$_swept appop_db=0"
  else
    _swept="$_swept appop_db=UNREACHABLE"
  fi
  # --- fix 6: graphicsstats ----------------------------------------------------------------------------
  # Day-by-day app usage with time-of-day and versionCode, encoded in DIRECTORY NAMES so nothing needs
  # decoding. Survives uninstalling the app AND removing the user that ran it, so only a directory wipe
  # reaches it. Per-package pruning is fiddly and pointless here: user 0's own entries are worthless on a
  # device whose sessions all live in secondary users.
  # The rules fixes 8-10 state below (uiderrors, fingerprint, anr), kept line for line:
  #  - A SYMBOLIC LINK IS NEVER FOLLOWED. The framework never makes this path a link, so one was planted, and
  #    `rm` of its glob as root would reach whatever it points at. It is left, logged once, and reads UNREACHABLE.
  #  - A DENIED LISTING IS NEVER 0: entries are counted from `ls -1A` (dotfiles too), and a directory that
  #    cannot be listed -- or whose `[ -d ]` fails, a denial as often as an absence -- reads UNREACHABLE.
  #    Both directories are framework-created, so ABSENT is not offered.
  #  - CONTENTS ONLY, never the directory, `.x` and `..x` names too. It is listed again afterwards, so a
  #    failed removal reads <n>/LEFT:<m> (<n>/LEFT:UNREACHABLE when that listing is denied), never done.
  #  - COUNTS ONLY: this tree keeps one directory per day, per PACKAGE, per versionCode, so rm's stderr names
  #    the package of a departed profile. It goes to /dev/null, never to $LOG (a durable file): the #39 class.
  _gs="/data/system/graphicsstats"
  if [ -L "$_gs" ]; then
    echo "[roamd] bootsweep: $_gs is a symbolic link -- not followed, not emptied $(date)" >> "$LOG"
    _swept="$_swept graphicsstats=UNREACHABLE"
  elif [ -d "$_gs" ] && _l=$(ls -1A "$_gs" 2>/dev/null); then
    _n=0; [ -n "$_l" ] && _n=$(printf '%s\n' "$_l" | wc -l)
    rm -rf "$_gs"/* "$_gs"/.[!.]* "$_gs"/..?* 2>/dev/null
    if ! _l=$(ls -1A "$_gs" 2>/dev/null); then _swept="$_swept graphicsstats=$_n/LEFT:UNREACHABLE"
    elif [ -n "$_l" ]; then _swept="$_swept graphicsstats=$_n/LEFT:$(printf '%s\n' "$_l" | wc -l)"
    else _swept="$_swept graphicsstats=$_n"; fi
  else
    _swept="$_swept graphicsstats=UNREACHABLE"
  fi
  # --- fix 7: dropbox ----------------------------------------------------------------------------------
  # 814 of 1,000 entries contained departed-user paths. No personal CONTENT (verified: zero content:// URIs,
  # zero email-shaped strings, zero profile names) -- the leak is the census: how many sessions existed,
  # which slots, when to the second, and which subsystems each had state in. See the ordering note above:
  # this MUST run after the user removals or it deletes the old entries and leaves the fresh ones.
  # DIA-20260816-06: report UNREACHABLE explicitly. The first cut gated this on `[ -d ]` and on a non-zero
  # count, so when SELinux denied getattr on the directory the whole block was skipped and the summary simply
  # omitted dropbox -- indistinguishable from "there was nothing to remove". Measured on lynx 2026081602:
  # 1000 entries before, 1000 after, and a summary reading "removed: adservices=4 jobs=46 appop_db=6
  # graphicsstats=4" that looked entirely healthy. The whole justification for counting was that a sweep
  # which silently reaches nothing must not read like one that works; gating the REPORT on success
  # reintroduced exactly that. A category that cannot be reached now says so.
  # UNREACHABLE IS THIS CATEGORY'S EXPECTED ANSWER ON EVERY BUILD TODAY: `dropbox_data_file` is neverallow'd to
  # every domain but init, system_server and dumpstate (nowhere_provision.sh's dropbox retention lines are the
  # supported route), so roamd cannot get past `[ -d ]`. The rules below are hardening: they matter when the
  # directory is REPLACED by a link (the link is not dropbox_data_file, so `[ -d ]` follows it) or the policy
  # changes. They are fixes 8-10's, kept line for line:
  #  - A SYMBOLIC LINK IS NEVER FOLLOWED: left, logged once, UNREACHABLE.
  #  - A DENIED LISTING IS NEVER 0: counted from `ls -1A` (dotfiles too); a failing listing is UNREACHABLE. The
  #    old `ls -1 | wc -l` read a listing denied after an allowed getattr as 0 -- the silent result above.
  #  - CONTENTS ONLY, dotfiles included, re-listed afterwards: <n>, <n>/LEFT:<m> or <n>/LEFT:UNREACHABLE.
  #  - COUNTS ONLY: rm's stderr goes to /dev/null; no entry name reaches $LOG.
  _db="/data/system/dropbox"
  if [ -L "$_db" ]; then
    echo "[roamd] bootsweep: $_db is a symbolic link -- not followed, not emptied $(date)" >> "$LOG"; _swept="$_swept dropbox=UNREACHABLE"
  elif [ -d "$_db" ] && _l=$(ls -1A "$_db" 2>/dev/null); then
    _n=0; [ -n "$_l" ] && _n=$(printf '%s\n' "$_l" | wc -l)
    rm -rf "$_db"/* "$_db"/.[!.]* "$_db"/..?* 2>/dev/null
    if ! _l=$(ls -1A "$_db" 2>/dev/null); then _swept="$_swept dropbox=$_n/LEFT:UNREACHABLE"
    elif [ -n "$_l" ]; then _swept="$_swept dropbox=$_n/LEFT:$(printf '%s\n' "$_l" | wc -l)"
    else _swept="$_swept dropbox=$_n"; fi
  else
    _swept="$_swept dropbox=UNREACHABLE"
  fi
  # --- fix 8: uiderrors (NWP-20261011-33) ---
  # The package manager's app-data reconcile appends `Destroying /data/user_de/<uid>/<pkg> due to: ...`, with a
  # timestamp, to this system-wide file, and nothing in the framework ever trims it. So across sessions it is a
  # roster of the packages every departed profile had installed -- the #39 roster class, docs/backlog.md
  # "`/data/system/uiderrors.txt` is a cleartext record of what departed profiles had installed". Package names
  # and times only, no user content; the leak is which apps a profile had, and how many profiles there were.
  #  - TRUNCATED IN PLACE, never unlinked: the framework owns the file and keeps appending to it. Truncating keeps
  #    its inode, owner, mode and label; an unlink would leave the framework to re-create it on its next write,
  #    with whatever this boot's context makes of that.
  #  - A SYMBOLIC LINK IS NEVER FOLLOWED. The framework never makes this path a link, so one was planted, and a
  #    truncation through it as root would empty whatever it points at. It is left and reported UNREACHABLE.
  #  - AFTER dropbox, for dropbox's reason: the boot-wipe's own removeUser destroys app data too, so lines naming
  #    the slots it has just erased land before this runs and go with the rest.
  #  - ABSENT IS TOLD FROM DENIED BY stat's ERRNO, not by `[ -e ]`, which is false for both: a denied getattr
  #    reading as "nothing there" is the silent-dropbox bug this op already paid for (DIA-20260816-06).
  #  - A SIGN-IN RACING THIS SWEEP (the gate accepts one while BootReceiver runs it) took its floor before the
  #    truncation, so uiderrorsTail (report_issue.go) answers ERR-SHRUNK while the file is below that floor. If
  #    it regrows past it, every line in it was written after the truncation, i.e. this boot, after the wipe had
  #    removed every earlier user: the report can lose that session's own first lines, never show another's.
  # Counts bytes, never content: nothing of the file is printed. (The 8 continues this op's own fix numbers; in
  # docs/amnesia-poweroff-audit.md this is finding #12 and fix 11.)
  _ue="/data/system/uiderrors.txt"
  if [ -L "$_ue" ]; then
    echo "[roamd] bootsweep: $_ue is a symbolic link -- not followed, not truncated $(date)" >> "$LOG"
    _swept="$_swept uiderrors=UNREACHABLE"
  elif ! _n=$(stat -c %s "$_ue" 2>&1); then
    case "$_n" in
      *"No such file or directory"*) _swept="$_swept uiderrors=0" ;;
      *) echo "[roamd] bootsweep: cannot stat $_ue: $_n $(date)" >> "$LOG"
         _swept="$_swept uiderrors=UNREACHABLE" ;;
    esac
  elif [ "$_n" = 0 ]; then
    _swept="$_swept uiderrors=0"
  # A failed redirection on the special builtin `:` exits a POSIX shell -- dash, and mksh, the phone's own sh -- so the sweep must truncate in a subshell to reach its failure branch.
  elif ! ( : > "$_ue" ) 2>> "$LOG"; then
    _swept="$_swept uiderrors=UNREACHABLE"
  elif ! _left=$(stat -c %s "$_ue" 2>> "$LOG") || [ -z "$_left" ]; then
    _swept="$_swept uiderrors=UNREACHABLE"
  elif [ "$_left" != 0 ]; then
    _swept="$_swept uiderrors=$_n/LEFT:$_left"
  else
    _swept="$_swept uiderrors=$_n"
  fi
  # --- fix 9: fingerprint (NWP-20261011-34) ---
  # The Goodix fingerprint HAL (lynx and the other Goodix Pixels) keeps device-wide event logs in
  # /data/vendor/fingerprint/. Measured on lynx 2026-09-14 (NWP-20260914-13): EnrollEventContainer is plaintext
  # CSV, one record per enrol/remove event carrying the ANDROID USER ID and a timestamp; FingerSizes.* carries
  # per-sample finger dimensions in millimetres; AuthStats.* adds per-authentication records. It survived logoff,
  # reap and power-off, and held a user id from a session a month and dozens of logoffs earlier. Not content but
  # WHICH identities used this handset and when -- the #39 shape; on a rental handset, a roster of past renters.
  #  - BOOT, NOT THE PER-UID REAP: the directory is device-wide, not keyed by any one user, so no per-uid list can
  #    name it. The HAL's per-user templates live under /data/vendor_de/<uid>/fpdata and are reaped elsewhere.
  #  - POLICY ALREADY PERMITS IT: endospore_priv holds dir {getattr search open read write remove_name rmdir} and
  #    file {getattr unlink} on vendor_data_file and fingerprint_vendor_data_file (endospore.te, the vendor
  #    per-user types block). Delete-only: nothing here reads a file.
  #  - CONTENTS ONLY, never the directory: the HAL owns it and expects to find it.
  #  - COUNTS ONLY: no file name reaches the log, so rm's stderr goes to /dev/null and a failure shows as LEFT.
  #  - ABSENT only when /data/vendor lists and has no `fingerprint` (the Fairphone; Pixels without Goodix). A
  #    failing `[ -d ]` alone is a denial as often as an absence -- the dropbox lesson above -- so it reads
  #    UNREACHABLE, as does a directory that exists but cannot be listed.
  #  - FRANKEL IS NOT COVERED: its qti_fp HAL keeps /data/vendor/misc/qti_fp, a vendor-private type our policy
  #    (SYSTEM_EXT_PRIVATE_SEPOLICY_DIRS) cannot name. Reaching it would be a framework patch, not this sweep.
  if [ -d /data/vendor/fingerprint ]; then
    if _l=$(ls -1A /data/vendor/fingerprint 2>/dev/null); then
      _n=0; [ -n "$_l" ] && _n=$(printf '%s\n' "$_l" | wc -l)
      rm -rf /data/vendor/fingerprint/* /data/vendor/fingerprint/.[!.]* 2>/dev/null
      if ! _l=$(ls -1A /data/vendor/fingerprint 2>/dev/null); then _swept="$_swept fingerprint=$_n/LEFT:UNREACHABLE"
      elif [ -n "$_l" ]; then _swept="$_swept fingerprint=$_n/LEFT:$(printf '%s\n' "$_l" | wc -l)"
      else _swept="$_swept fingerprint=$_n"; fi
    else
      _swept="$_swept fingerprint=UNREACHABLE"
    fi
  elif _vl=$(ls -1A /data/vendor 2>/dev/null) && [ -n "$_vl" ]; then
    case "$(printf '%s\n' "$_vl" | grep -cx fingerprint)" in
      0) _swept="$_swept fingerprint=ABSENT" ;;
      *) _swept="$_swept fingerprint=UNREACHABLE" ;;
    esac
  else
    _swept="$_swept fingerprint=UNREACHABLE"
  fi
  # --- fix 10: anr (NWP-20261015-21) ---
  # ANR traces in /data/anr open with `Cmd line: <package>`, so each one names an app a departed session ran,
  # with a timestamp -- the #39 roster class, docs/backlog.md "`/data/anr` survives everything". system_server
  # and tombstoned write it, the framework never trims it, and no other remover exists in the tree. It is
  # device-wide, so it is a boot sweep category and no per-uid reap list can name it.
  #  - THE GRANT IS PART OF THIS FIX. `anr_data_file` is not `system_data_file`: before this slice endospore.te
  #    held no rule for it, so this category would have been AVC-denied and failed silently on an enforcing
  #    build. endospore.te now holds the delete-only grant (getattr + unlink on files, the dir set for contents).
  #  - CONTENTS ONLY, never the directory: system_server and tombstoned expect to find it.
  #  - A SYMBOLIC LINK IS NEVER FOLLOWED. The framework never makes this path a link, so one was planted, and
  #    `rm` of its glob as root would reach whatever it points at. It is left and reported UNREACHABLE.
  #  - COUNTS ONLY: no file name reaches the log (a trace is named for its pid and time), so rm's stderr goes to
  #    /dev/null and a failure shows as LEFT.
  #  - ABSENT only when /data lists and has no `anr`. A failing `[ -d ]` alone is a denial as often as an
  #    absence -- the dropbox lesson above -- so it reads UNREACHABLE, as does a directory that cannot be listed.
  #  - DOTFILES TOO: both `.x` and `..x` names. Nothing here reads a trace.
  # (In docs/amnesia-poweroff-audit.md this is finding #14 and fix 13.)
  _an="/data/anr"
  if [ -L "$_an" ]; then
    echo "[roamd] bootsweep: $_an is a symbolic link -- not followed, not emptied $(date)" >> "$LOG"
    _swept="$_swept anr=UNREACHABLE"
  elif [ -d "$_an" ]; then
    if _l=$(ls -1A "$_an" 2>/dev/null); then
      _n=0; [ -n "$_l" ] && _n=$(printf '%s\n' "$_l" | wc -l)
      rm -rf "$_an"/* "$_an"/.[!.]* "$_an"/..?* 2>/dev/null
      if ! _l=$(ls -1A "$_an" 2>/dev/null); then _swept="$_swept anr=$_n/LEFT:UNREACHABLE"
      elif [ -n "$_l" ]; then _swept="$_swept anr=$_n/LEFT:$(printf '%s\n' "$_l" | wc -l)"
      else _swept="$_swept anr=$_n"; fi
    else
      _swept="$_swept anr=UNREACHABLE"
    fi
  elif _dl=$(ls -1A /data 2>/dev/null) && [ -n "$_dl" ]; then
    case "$(printf '%s\n' "$_dl" | grep -cx anr)" in
      0) _swept="$_swept anr=ABSENT" ;;
      *) _swept="$_swept anr=UNREACHABLE" ;;
    esac
  else
    _swept="$_swept anr=UNREACHABLE"
  fi
  # --- appcode0: the gate's app-code staging (NWP-20261024-02) ---
  # The `in` arm stages a profile's #apps scope -- cleartext APKs of every kept sideloaded app plus manifest.tsv, which
  # names every app and its mode -- in the user-0 chooser's files/.appcode, and ChooserActivity.installRoamedAppCode
  # removes it in its `finally`. A crash, a dead battery or a reboot before that `finally` leaves the profile's app list
  # and APK bytes on durable storage under user 0's CE (effectively always unlocked) after the roamed user is gone, until
  # some sign-in's `rm -rf` reaches it (docs/backlog.md "A sign-in that crashes before the gate installs its apps ...").
  # The census of removers: that `rm -rf` and the `finally`; nothing else, until this category.
  #  - A LIVE SESSION'S STAGING IS NEVER TOUCHED: a .roamsession marker means the gate may still be installing from it
  #    (installRoamedAppCode runs after ROAM-IN returns). The check is sound only because BOOT-SWEEP is not in
  #    concurrentSafeCmd, so it holds sessionMu as ROAM-IN does, and the daemon writes the marker after roamd's `in`
  #    returns: with no marker no sign-in can be inside its `in` op or its install, so what is here is residue.
  #  - A SYMBOLIC LINK IS NEVER FOLLOWED OR REMOVED: the chooser never makes this path a link, so one was planted. It
  #    reads UNREACHABLE. This check comes before the marker's, so a link always reads so.
  #  - COUNTS ONLY: the count is the top-level entries other than manifest.tsv, one per staged package. No package name,
  #    path entry or profile name reaches the log, so rm's stderr goes to /dev/null (toybox names each failing path) and a
  #    failure shows as <n>/LEFT.
  #  - ABSENT only when the files directory lists and holds no line that is exactly `.appcode` (-F: the dot is literal).
  #    A failing `[ -d ]` alone is a denial as often as an absence -- the dropbox lesson above -- so a listing that cannot
  #    be read, or that names `.appcode`, reads UNREACHABLE.
  #  - NO POLICY CHANGE: the `in` arm already removes this path as roamd, and endospore_priv holds the create/remove set
  #    on app_data_file_type.
  _acp="/data/user/0/com.nowhere.chooser/files"
  _ac="/data/user/0/com.nowhere.chooser/files/.appcode"
  if [ -L "$_ac" ]; then
    echo "[roamd] bootsweep: the gate's .appcode staging is a symbolic link -- not followed, not removed $(date)" >> "$LOG"
    _swept="$_swept appcode0=UNREACHABLE"
  elif [ -s "$STATE/.roamsession" ]; then
    _swept="$_swept appcode0=KEPT:session"
  elif [ -d "$_ac" ]; then
    if _l=$(ls -1A "$_ac" 2>/dev/null); then
      _n=0; [ -n "$_l" ] && _n=$(printf '%s\n' "$_l" | grep -cvxF manifest.tsv)
      rm -rf "$_ac" 2>/dev/null
      if [ -e "$_ac" ]; then _swept="$_swept appcode0=$_n/LEFT"
      else _swept="$_swept appcode0=$_n"; fi
    else
      _swept="$_swept appcode0=UNREACHABLE"
    fi
  elif _l=$(ls -1A "$_acp" 2>/dev/null); then
    case "$(printf '%s\n' "$_l" | grep -cxF .appcode)" in
      0) _swept="$_swept appcode0=ABSENT" ;;
      *) _swept="$_swept appcode0=UNREACHABLE" ;;
    esac
  else
    _swept="$_swept appcode0=UNREACHABLE"
  fi
  # --- fix 11: locglobals (NWP-20261016-45) ---
  # Network location and geocoding are DEVICE settings that persist across a reboot, so a session that ended without a
  # release (a power loss, a reboot fallback, RESTART-UNSAVED) would leave its choice on for whoever signs in next.
  # loc_boot puts the baseline (both 0) back -- unless a session that signed in before this sweep ran already owns
  # them and its user still exists. Reports baseline, KEPT:user<n>, FAILED(<what they read>) or UNAVAILABLE (no
  # provider: Diaspore).
  loc_boot
  _swept="$_swept locglobals=$LOC_BOOT"
  # --- fix 12: mobiledata (NWP-20261026-05) ---
  # Mobile data is a DEVICE setting that persists, and the gate's own value is the baseline. md_boot restores it from
  # the record kept outside the tmpfs (a power loss mid-session leaves the profile's choice on the phone) unless a
  # session that signed in before this sweep ran already owns it. Reports baseline, none, KEPT:user<n> or
  # FAILED(<what it read>).
  md_boot
  _swept="$_swept mobiledata=$MD_BOOT"
  # --- fix 13: devtoggles (NWP-20261027-05) ---
  # Airplane mode, battery saver, Data Saver and NFC are DEVICE settings that persist, so a session that ended without a
  # release (a power loss, a reboot fallback) would leave its choice for whoever signs in next. dt_boot restores the
  # gate's values from the record kept outside the tmpfs unless a session that signed in before this sweep ran already
  # owns them. Reports baseline, none, KEPT:user<n> or FAILED(<keys>).
  dt_boot
  _swept="$_swept devtoggles=$DT_BOOT"
  # --- fix 14: dataroaming (NWP-20261028-07) ---
  # Data roaming is a per-subscription DEVICE setting that persists, and the gate's own value is the baseline. dr_boot
  # restores the recorded subscription from the record kept outside the tmpfs unless a session that signed in before this
  # sweep ran already owns it. Reports baseline, none, KEPT:user<n> or FAILED(<what it read>).
  dr_boot
  _swept="$_swept dataroaming=$DR_BOOT"
  # --- fix 15: hotspot (NWP-20261028-10) ---
  # At boot no session is in front, and after a power loss the stored soft-AP configuration may still hold the last
  # session's name and passphrase. The gate is asked unconditionally (uid -1) to stop sharing and reset it. Reports
  # released or failed(<reason>), one space-free token, on every path.
  hs_release -1 boot
  case "$HS_VERDICT" in
    "OK RELEASED") _hs=released ;;
    "ERR-HS "*) _hs="failed(${HS_VERDICT#ERR-HS })" ;;
    *) _hs="failed(kept)" ;;   # uid -1 is unconditional at the gate; a KEPT here means nothing was stopped
  esac
  _swept="$_swept hotspot=$_hs"
  # --- fix 16: keystore-drop (NWP-20261102-04) ---
  # A list left by a crash between `out` and the reap names a departed session's switched-off apps.
  if [ -e "$KS_DROP" ] || [ -e "$KS_DROP.new" ]; then
    rm -f "$KS_DROP" "$KS_DROP.new" 2>/dev/null
    if [ -e "$KS_DROP" ] || [ -e "$KS_DROP.new" ]; then _swept="$_swept ksdrop=LEFT"; else _swept="$_swept ksdrop=removed"; fi
  else _swept="$_swept ksdrop=none"; fi
  # --- fix 17: staging (NWP-20261107-01) ---
  # A departed session's per-session staging: acct-stage (acct_seal's copy of accounts_ce.db, removed after its push or at
  # the next acct_seal), acct-hold-<uid> / acct-deferred-<uid> (cleanstorage's, which the boot wipe sends only for a user
  # it removes, so a user removed before a power loss keeps them), appcode-stage and its six lists (after the #apps seal
  # or the next appcode_seal), appcode-reuse (a sign-out's #apps seal or the reap, NWP-20261128-09), fetchapp (stageapp, or handleFetchApp's error paths), keystore-stage (after the #keys
  # push) and keystore-in (every landed sign-in's ks_signin_reset removes it, NWP-20261108-01, and the restore replaces it: the reap copies its bundles and removes none). A crash, a
  # power loss or, for keystore-in, every sign-out leaves them. A missing marker does not prove the session is over (a
  # sign-out's `out` and reap run after handleLogout removes it, a cold lock removes it while the user is parked, and a
  # sign-in made this boot escapes the wipe), so staging_boot removes them only when no marker exists (KEPT:session), no
  # `out` awaits its reap ($KS_CREDS, KEPT:reap) and no user >= 10 has a record (KEPT:user), behind user 0's record as
  # the positive control (UNREACHABLE).
  # (Superseded by NWP-20261112-01: a landed sign-in removes only keystore-in/<its uid>, flat bundles and departed uids' dirs; a parked user's dir stays.)
  staging_boot
  _swept="$_swept staging=$STAGING_BOOT"
  # --- fix 18: siblings (NWP-20261129-44) ---
  # docs/backlog.md "Four sibling Wi-Fi/network stores nothing sweeps": the Wi-Fi siblings, the tethering netstats and
  # netpolicy are device-wide and outside every user. Stage 3's sweep waits on docs/wifi-retention-spec.md §4.8 and HW3,
  # whether roamd's domain can even see them, and that was a hand `ls -Z` nobody ran. A report with roam.log now answers it.
  #  - REPORT ONLY: nothing is removed or sealed and no store is opened. It is not a category of the result line below
  #    (it appends nothing to that line, which stays byte for byte), so it prints a line of its own.
  #  - <label>/w<0|1>: the entry's context and whether `[ -w ]` passes on its PARENT. w1 is one access check; it does not
  #    prove remove_name on the directory or unlink on the file. Stage 3 reads the label against the policy for those.
  #  - absent ONLY when the parent lists and the entry is not there. A parent that does not list is unreachable, which
  #    is a finding and never an absence: the fingerprint and dropbox lesson above. A missing parent reads the same, and
  #    its own field (wifidir=absent) gives the reason.
  #  - ONE FIXED-STRING MATCH PER NAME, captured: the device's grep silently matches nothing for BRE alternation
  #    (docs/amnesia-poweroff-audit.md §4), and a pattern's `.` would match any character in a store's name.
  #  - TOKENS ONLY: the listing stays in a variable and ls's stderr goes to /dev/null, so no entry or path reaches the log.
  #    An entry that lists with no readable label reads ?/w<n>, still one token.
  _sb_state() {
    _sb_l=$(ls -1A "$1" 2>/dev/null) || { echo unreachable; return 0; }
    _sb_c=$(printf '%s\n' "$_sb_l" | grep -Fcx -e "$2")
    if [ "$_sb_c" = 0 ]; then echo absent; return 0; fi
    _sb_z=$(ls -Zd "$1/$2" 2>/dev/null); _sb_z=${_sb_z%% *}
    _sb_w=0; [ -w "$1" ] && _sb_w=1
    echo "${_sb_z:-?}/w$_sb_w"
  }
  _sb_wd="/data/misc/apexdata/com.android.wifi"
  _sb_soft=$(_sb_state "$_sb_wd" WifiConfigStoreSoftAp.xml)
  _sb_card=$(_sb_state "$_sb_wd" WifiScoreCard.proto)
  _sb_hlth=$(_sb_state "$_sb_wd" WifiHealthMonitor.proto)
  _sb_sugg=$(_sb_state "$_sb_wd" WifiNetworkSuggestionsStore.xml)
  _sb_nets=$(_sb_state "/data/misc/apexdata/com.android.tethering" netstats)
  _sb_npol=$(_sb_state "/data/system" netpolicy.xml)
  _sb_wdir=$(_sb_state "/data/misc/apexdata" com.android.wifi)
  echo "[roamd] bootsweep siblings: softap=$_sb_soft scorecard=$_sb_card health=$_sb_hlth suggest=$_sb_sugg netstats=$_sb_nets netpolicy=$_sb_npol wifidir=$_sb_wdir $(date)" >> "$LOG"
  unset _sb_wd _sb_soft _sb_card _sb_hlth _sb_sugg _sb_nets _sb_npol _sb_wdir _sb_l _sb_c _sb_z _sb_w
  unset -f _sb_state
  # Report what was actually removed, not that the op ran. A sweep that silently reaches nothing reads
  # exactly like one that works -- the dontaudit lesson this tree has already paid for twice.
  # Always print the full per-category result, including zeros and UNREACHABLE. A category missing from this
  # line used to mean "skipped"; now nothing is ever missing, so the line cannot look healthy while a
  # category is dead.
  #
  # DIA-20260816-11: this invariant was only TWO-FIFTHS true when first claimed. DIA-20260816-06 converted
  # graphicsstats and dropbox but left adservices, jobs and appop_db gated on `[ "$_n" -gt 0 ]`, so they
  # still vanished at zero -- the very ambiguity the change existed to remove, just narrower. Caught on
  # lynx 2026081603, where the line read "result: jobs=4 appop_db=6 graphicsstats=1 dropbox=UNREACHABLE"
  # with adservices simply absent because its count was 0. All five report unconditionally now (six since
  # NWP-20261003-01 added userdirs, which reports on every path too), uiderrors (NWP-20261011-33) does too, and
  # fingerprint (NWP-20261011-34) reports a count, ABSENT or UNREACHABLE on every path, and so does anr (NWP-20261015-21);
  # locglobals (NWP-20261016-45) reports one of its four states on every path; appcode0 (NWP-20261024-02) reports a
  # count, <n>/LEFT, KEPT:session, ABSENT or UNREACHABLE on every path; mobiledata (NWP-20261026-05) reports baseline,
  # none, KEPT:user<n> or FAILED(<what it read>) on every path; devtoggles (NWP-20261027-05) reports baseline, none,
  # KEPT:user<n> or FAILED(<keys>) on every path; hotspot (NWP-20261028-10) reports released or failed(<reason>) on every
  # path; ksdrop (NWP-20261102-04) reports removed, none or LEFT on every path; staging (NWP-20261107-01) reports none,
  # <n>[/LEFT:<k>][/LINK:<l>], KEPT:session, KEPT:reap, KEPT:user or UNREACHABLE on every path.
  # INVARIANT: every category appends exactly once, on every path. If you add a category, it reports even
  # when it does nothing -- that is the entire point of this line.
  echo "[roamd] bootsweep result:$_swept $(date)" >> "$LOG"
  # NWP-20261201-36: a report filed at the gate reads provision.log, gate.log and ota.log only (report_issue.go
  # buildIssueReportWith's gate `bases`), so the fixed-shape copy goes to provision.log. This op and log_scrub's three
  # callers (cleanstorage, btwipe, logscrub) all run on the read-write worker lane (main.go triggerRoamWorker, laneFor),
  # so this append cannot land inside roamd's own rewrite of provision.log; nowhere_provision.sh's and nowhere_gate.sh's
  # can, and that residual is theirs. A failed write changes nothing else.
  bootsweep_plog_line "$_swept"
  echo "[bootsweep] result:$BS_PLOG (NWP-20261201-36) $(date)" 2>/dev/null >> /data/nowhere/provision.log
  echo "OK" > "$RES"
  chmod 600 "$RES"; exit 0
fi

# DIA-20260807-04: cold-lock, the one teardown DIA-20260807-03 could not cover with the cleanstorage hook. It
# STOPS the roamed user rather than removing it, and resume does not re-run the `in` op -- so a bare wipe at
# park would have traded an amnesia leak for silently unpairing every device the user owns. Park and resume are
# a PAIR:
#   btpark    capture THIS session's Bluetooth state into its (still-unlocked) CE, then clear the device
#   btresume  lay it back down once the CE is unlocked again
# Capturing at park rather than trusting the last periodic seal matters: anything paired since that seal is not
# in the artifact yet, and a cold-lock can follow a pairing by seconds. A capture FAILURE does NOT cancel the
# clear -- amnesia wins -- and costs less than it appears to, because a failed capture deliberately leaves the
# previous artifact in place for btresume to use.
if [ "$op" = "btpark" ] || [ "$op" = "btresume" ]; then
  # NWP-20261005-17 (P1): a COMMITTED cold lock drops the keystore-push stash, which holds this session's name and
  # PLAINTEXT passphrase. Every `out` rewrites it and only `in` and cleanstorage removed it, so it sat in the tmpfs
  # for the whole lock, beside a marker the agent is careful to keep free of any clear credential. btpark is the
  # place: the teardown runs it only past its point of no return, inside the worker slot it holds, so a lock the
  # owner aborts keeps the stash and a lock that commits never outlives it. First, before the uid check, so a bad
  # request cannot skip it. Priced by Chester 2026-10-05 ("go with 3"): a cold-locked session that is never
  # resumed and is wiped at the 12h bound now loses its #keys push -- its apps come back signed out. The keystore2
  # dump-at-lock that would keep them is its own backlog row.
  [ "$op" = btpark ] && rm -f "$KS_CREDS" 2>/dev/null && echo "[roamd] cold-lock: keystore-push credentials dropped (NWP-20261005-17) $(date)" >> "$LOG"
  case "$uid" in ''|*[!0-9]*) echo "[roamd] bt $op: bad uid $(date)" >> "$LOG"; echo "ERR-UID" > "$RES"; chmod 600 "$RES"; exit 0;; esac
  # NWP-20261116-13: this arm runs ahead of the shared guard, so it carries the guard's floor itself: no leading zero,
  # never under 10 (bt_seal_capture would copy the device's bonds into user 0's files). Still after the KS_CREDS rm.
  case "$uid" in 0?*) echo "[roamd] bt $op: bad uid (leading zero) $(date)" >> "$LOG"; echo "ERR-UID" > "$RES"; chmod 600 "$RES"; exit 0;; esac
  [ "$uid" -ge 10 ] || { echo "[roamd] bt $op: bad uid (under 10) $(date)" >> "$LOG"; echo "ERR-UID" > "$RES"; chmod 600 "$RES"; exit 0; }
  _btrc=0
  if [ "$op" = btpark ]; then
    bt_seal_capture "/data/user/$uid" || _btrc=1
    bt_reset "" || _btrc=1
    [ "$_btrc" = 0 ] && echo "[roamd] bt: captured + device cleared at cold-lock (user $uid) $(date)" >> "$LOG"
  else
    bt_reset "/data/user/$uid" resume || _btrc=1
    [ "$_btrc" = 0 ] && echo "[roamd] bt: device cleared, $BT_RESTORED file(s) restored at resume (user $uid) $(date)" >> "$LOG"
  fi
  if [ "$_btrc" = 0 ]; then echo "OK" > "$RES"
  else echo "[roamd] bt ERR: $op FAILED (user $uid) $(date)" >> "$LOG"; echo "ERR-BT" > "$RES"; fi
  chmod 600 "$RES"; exit 0
fi

# Manual-lock self-arm (P4, DIA-20260625-13): a manual cold-lock right after login may have NO lockscreen credential
# yet (the cred-armer normally sets it on the FIRST screen-off). So set it now = the session passphrase, so the
# cold-lock is passphrase-protected + RESUMABLE with zero user action. Best-effort: if a credential is already set
# (the idle path, screen-off already armed it) set-password WITHOUT --old fails harmlessly, leaving the existing
# (same) credential. Root; /dev/null stdio (the DIA-56 cmd fd denial). The pass is NEVER logged.
if [ "$op" = "armcred" ]; then
  case "$uid" in ''|*[!0-9]*) echo "ERR-UID" > "$RES"; chmod 600 "$RES"; exit 0;; esac
  # NWP-20261116-17: user 0 is the gate, whose keyguard the provisioner disables; a credential there is never a session's.
  case "$uid" in 0?*) echo "[roamd] armcred: bad uid $(date)" >> "$LOG"; echo "ERR-UID" > "$RES"; chmod 600 "$RES"; exit 0;; esac
  [ "$uid" -ge 10 ] || { echo "[roamd] armcred: uid under 10 refused $(date)" >> "$LOG"; echo "ERR-UID" > "$RES"; chmod 600 "$RES"; exit 0; }
  # Arm the lockscreen credential = $pass (the NEW credential: the session PIN, else the passphrase), preserving
  # TYPE: all-numeric -> set-pin (numeric keyguard); any non-digit -> set-password. TWO-RUNG ladder (like rekey):
  # the credential may be UNSET (fresh login) OR already the PASSPHRASE (login / a FALLBACK screen-off arm set it
  # before the PIN was active). rung1 (no --old) sets a FRESH credential and fails harmlessly if one exists; rung2
  # (--old "$sesec" = the current passphrase) CHANGES that existing credential to $pass. WITHOUT rung2 a numeric
  # PIN could never REPLACE an existing passphrase -> the warm keyguard stayed alphanumeric and cold-lock resume
  # demanded a PIN the CE was never re-keyed to (softlock, DIA-20260730). Both rungs fail harmlessly (logged, never fatal) when
  # $pass is already armed (an empty $sesec just makes rung2 a no-op -> old behaviour). For armcred (the no-key
  # path) $sesec carries the OLD passphrase, NOT an SE secret.
  if [ -n "$pass" ]; then
    case "$pass" in
      *[!0-9]*) _ks=set-password ;;
      *)        _ks=set-pin ;;
    esac
    if cmd lock_settings "$_ks" --user "$uid" "$pass" </dev/null >/dev/null 2>/dev/null; then
      _arung="set (no prior credential)"
    elif cmd lock_settings "$_ks" --old "$sesec" --user "$uid" "$pass" </dev/null >/dev/null 2>/dev/null; then
      _arung="re-keyed from the old passphrase"
    else
      _arung="neither rung set it (already this credential, or refused)"
    fi
  else
    _arung="no credential given"
  fi
  # THE VERDICT (NWP-20261031-05, decided 2026-10-20, docs/product-decisions.md): armed, or not armed. A rung that
  # succeeded armed it. When NEITHER did, the credential may already be exactly $pass (both rungs fail harmlessly
  # over it), so ask the lock settings: `verify --old "$pass"` exits 0 only if $pass IS the user's credential.
  # No credential given = nothing was armed. Anything else is not armed.
  _averdict=notarmed
  case "$_arung" in
    "set (no prior credential)"|"re-keyed from the old passphrase") _averdict=armed ;;
    "neither rung set it"*)
      if cmd lock_settings verify --old "$pass" --user "$uid" </dev/null >/dev/null 2>/dev/null; then
        _averdict=armed; _arung="neither rung set it (already this credential)"
      fi ;;
  esac
  # DIA-20260813-09 (#83): the done-marker ARM-PIN's truthful ack reads, now carrying the verdict (NWP-20261031-05):
  # `armed` = the active unlock secret IS the keyguard credential for this uid, this session; `notarmed` = the op
  # ran and it is not. Written only HERE, so a lost-start/vanished op can never read as armed. Cleared on every
  # `in` (a new session must re-arm before claiming PINSET). The OK reply says the same (`OK ARMED` / `OK NOTARMED`)
  # and ARM-PIN answers PINSET only for `armed`; this used to be "the rungs ran", which let a refused or absent
  # credential read as PINSET and skip the chooser's DPM fallback. Never print $pass or $sesec.
  echo "$_averdict" > "$STATE/.armcred.$uid" 2>>"$LOG"; chmod 600 "$STATE/.armcred.$uid" 2>>"$LOG"
  echo "[roamd] armcred user $uid: $_arung -> $_averdict $(date)" >> "$LOG"
  if [ "$_averdict" = armed ]; then echo "OK ARMED" > "$RES"; else echo "OK NOTARMED" > "$RES"; fi
  chmod 600 "$RES"; exit 0
fi

[ -n "$op" ] && [ -n "$name" ] && [ -n "$uid" ] || { echo "ERR-ARGS" > "$RES"; chmod 600 "$RES"; exit 0; }
# uid builds a root path (USERDIR) below -- defense-in-depth: reject anything non-numeric (DIA-20260618-08, audit #3).
case "$uid" in *[!0-9]*) echo "[roamd] non-numeric uid rejected $(date)" >> "$LOG"; echo "ERR-UID" > "$RES"; chmod 600 "$RES"; exit 0;; esac
# NWP-20261116-13: a session uid is 10 or more. Same HARD GUARD rule as cleanstorage: only secondary users (uid >= 10),
# never touch user 0's storage. uid 0 would restore a vault into the gate's own CE, which the reap never clears; a
# leading zero names no user. The numeric check above stays first: mksh reads a non-number in [ -ge ] as 0, silently.
case "$uid" in 0?*) echo "[roamd] uid $uid refused (leading zero) $(date)" >> "$LOG"; echo "ERR-UID" > "$RES"; chmod 600 "$RES"; exit 0;; esac
[ "$uid" -ge 10 ] || { echo "[roamd] uid $uid refused (under 10: user 0 and the system are never a session) $(date)" >> "$LOG"; echo "ERR-UID" > "$RES"; chmod 600 "$RES"; exit 0; }
USERDIR="/data/user/$uid"


# App-persistence (#199): stage + seal the opted-in user-installed app CODE as the name#apps sibling scope. The
# chooser (ProfileActivity) resolved each kept package's APK + split paths into files/nowhere-appcode.list at
# logoff -- it has the PackageManager visibility we lack (the cmd fd denial). Here we copy those apk_data_file
# bytes into a DISK staging dir (never $STATE tmpfs -- APKs are big) and `push` them under name#apps: its own
# head, CDC-deduped (a popular app stored once fleet-wide), kept OFF the login-critical vault + its #58
# snapshots. Line format of the list: pkg <tab> versionCode <tab> sideloaded <tab> apkPath1 [<tab> apkPath2 ...].
# Best-effort: any failure is logged but NEVER fails the data seal, and an empty/absent list (nothing opted in
# -- the default) is a clean no-op. The staged manifest.tsv (pkg + metadata + staged basenames) rides the scope
# for P2 restore. Needs the worker to read apk_data_file (fine on this su:s0 build; a USER/enforcing build may
# need an explicit read grant -- verify on-device).

# NWP-20261130-16 (backlog: a periodic seal's #apps stage spends about 85-124 s besides copying): the stage's ONE
# PackageManager read. Every lookup used to run its own `dumpsys package <pkg>`, once per package at every seal. The one
# call is `dumpsys package packages`: for each package it prints the same block as the per-package dump, so it carries
# codePath, flags and versionCode together. `pm list packages -f --show-versioncode` has no flags, and
# `dumpsys package --checkin` has no codePath.
# The dump is streamed into awk, never held as a shell value (the E2BIG note below). The file is root-only, under the RAM
# $STATE, one line per package: <pkg> TAB <codePath> TAB <SYSTEM 0|1> TAB <versionCode>. appcode_seal removes it before
# its "#apps staged" line; the next snapshot and the reap remove the file of a killed op.
# A BLOCK WITH A MISSING FIELD MAKES NO ROW: dumpsys stops a service that overruns its timeout, so a dump can end inside a
# block, and a block cut before its flags line must never read as "not SYSTEM". A flags line must close with its ].
# A DUMP THAT FAILS MAKES NO SNAPSHOT, WHATEVER ROWS IT PRINTED FIRST. A pipeline's status is awk's, and dash has no pipefail,
# so dumpsys's status follows the dump as the stream's last line, on a line of its own. awk exits 3 unless that line says 0.
# The first block of a name decides (the same first match as the per-package dump): an updated system app's hidden second
# block has a /system path. A package with no row falls back to its own dump, so a failed or empty snapshot is never read
# as "not installed". Sets PM_SNAP to the file, or to empty when there is no snapshot.
appcode_pm_snapshot() {
  local aps_f aps_t0 aps_n aps_why aps_rc
  PM_SNAP=""
  aps_t0=$(_ms)
  aps_f="$STATE/appcode-pm-snapshot"
  rm -f "$aps_f" 2>/dev/null
  aps_why=""
  aps_rc=0
  ( umask 077; { dumpsys package packages 2>/dev/null; printf '\nnowhere-dump-rc=%s\n' "$?"; } | awk '
    function emit() {
      if (n != "" && c != "" && f ~ /flags=\[.*\]/ && v != "") printf "%s\t%s\t%d\t%s\n", n, c, (index(f, " SYSTEM ") > 0), v
      n = ""
    }
    { l = $0 }
    /^[ \t]*Package \[/ {
      emit()
      m = $0; sub(/^[ \t]*Package \[/, "", m); sub(/\].*/, "", m)
      p = 0; q = 0; r = 0; c = ""; f = ""; v = ""
      if (!(m in seen)) { seen[m] = 1; n = m }
      next
    }
    n == "" { next }
    !p && /codePath=/ { p = 1; c = $0; sub(/.*codePath=/, "", c) }
    !q && /flags=\[/ { q = 1; f = $0 }
    !r && /(^|[ \t])versionCode=/ { r = 1; v = $0; sub(/.*versionCode=/, "", v); sub(/[^0-9].*/, "", v) }
    END { emit(); if (l != "nowhere-dump-rc=0") exit 3 }' > "$aps_f" ) 2>/dev/null || aps_rc=$?
  case "$aps_rc" in 0) ;; 3) aps_why="dump failed" ;; *) aps_why="cannot write" ;; esac
  if [ -z "$aps_why" ] && { [ ! -f "$aps_f" ] || [ -L "$aps_f" ]; }; then aps_why="cannot write"; fi
  if [ -z "$aps_why" ] && [ ! -s "$aps_f" ]; then aps_why="empty dump"; fi
  if [ -n "$aps_why" ]; then
    rm -f "$aps_f" 2>/dev/null
    echo "[roamd] #apps pm snapshot: none, $aps_why -- per-package lookups, $(( $(_ms) - aps_t0 ))ms (NWP-20261130-16) $(date)" >> "$LOG"
    return 0
  fi
  aps_n=$(grep -c . "$aps_f" 2>/dev/null)
  PM_SNAP=$aps_f
  echo "[roamd] #apps pm snapshot: ${aps_n:-0} package(s) in $(( $(_ms) - aps_t0 ))ms (NWP-20261130-16) $(date)" >> "$LOG"
  return 0
}

# NWP-20261130-16: the snapshot's row for package $1, in the caller's _pms_dir, _pms_sys and _pms_vc. Status 0: the row
# answers. Status 1: the caller reads the package's own dump. A row whose dir is gone falls back too: a package updated
# during the stage has a new dir, and only the live dump names it. The sealable rules stay in the callers, one copy each.
appcode_pm_row() {
  local apr_r apr_nl
  apr_nl='
'
  apr_r=$(awk -F'\t' -v p="$1" '$1 == p { print $2; print $3; print $4; exit }' "$PM_SNAP" 2>/dev/null)
  _pms_dir=${apr_r%%"$apr_nl"*}; apr_r=${apr_r#*"$apr_nl"}
  _pms_sys=${apr_r%%"$apr_nl"*}; _pms_vc=${apr_r#*"$apr_nl"}
  case "$_pms_sys" in 0|1) ;; *) return 1 ;; esac
  case "$_pms_vc" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$_pms_dir" ] && [ -d "$_pms_dir" ]
}

# DIA-20260805-09: a package's CURRENT code dir, from live PackageManager state. The dumpsys capture works in
# this domain (the reap above already relies on it, see reap_orphan_provisioned). Only /data/app counts: a
# system app's codePath is /system/... and must never be sealed -- captureAppCode skips FLAG_SYSTEM for the
# same reason, so this mirrors it. Empty output = not installed / not sealable.
# NWP-20261113-01: the dump is streamed into awk, which keeps the first codePath and the first flags=[ line: it
# is never a shell value passed to printf, since mksh's printf is /system/bin/printf and the kernel refuses an
# argument over 128 KiB (E2BIG) -- VLC's 365,826-byte dump was refused, so its code was never re-sealed.
# NWP-20261130-16: during an #apps stage the raw values come from the stage's snapshot; the rules below are unchanged.
live_code_dir() {
  local lcd lflags lout lnl _pms_dir _pms_sys _pms_vc
  lnl='
'
  if [ -n "${PM_SNAP:-}" ] && appcode_pm_row "$1"; then
    lcd=$_pms_dir; lflags=""; [ "$_pms_sys" = 0 ] || lflags=" SYSTEM "
  else
    lout=$(dumpsys package "$1" 2>/dev/null | awk '
      !p && /codePath=/ { p = 1; c = $0; sub(/.*codePath=/, "", c) }
      !q && /flags=\[/ { q = 1; f = $0 }
      END { print c; print f }')
    lcd=${lout%%"$lnl"*}
    case "$lout" in *"$lnl"*) lflags=${lout#*"$lnl"} ;; *) lflags="" ;; esac
  fi
  case "$lcd" in /data/app/*) ;; *) return 0 ;; esac
  [ -d "$lcd" ] || return 0
  # Mirror captureAppCode's FLAG_SYSTEM / FLAG_UPDATED_SYSTEM_APP skip. /data/app alone is NOT enough: an
  # UPDATED system app keeps its update there while still shipping in the image, so install-existing brings it
  # back for free and sealing its bytes would bloat the footprint for nothing. Device-checked on lynx
  # 2026-08-05: app.grapheneos.gmscompat.config is exactly this shape (codePath=/data/app/..., flags=[ SYSTEM
  # ... UPDATED_SYSTEM_APP ]) -- it is the only /data/app package on a clean build, so a path-only test would
  # have sealed it on every device.
  case "$lflags" in *" SYSTEM "*) return 0 ;; esac
  printf '%s' "$lcd"
}

# NWP-20261119-02: live_code_dir's answer AND the live versionCode, from ONE dump (one dumpsys per package), for an
# on-demand/auto package whose listed paths are all stale. Same three rules as live_code_dir; the dump is streamed
# into awk for the same E2BIG reason. Sets the caller's _lcv_dir (empty = not installed / not sealable) and _lcv_vc
# (the digits of the first versionCode=, or empty). live_code_dir itself is left as test-live-code-dir.sh pins it.
# NWP-20261130-16: as in live_code_dir, the stage's snapshot answers when it holds a usable row.
live_code_ver() {
  local lcv_out lcv_nl lcv_f _pms_dir _pms_sys _pms_vc
  lcv_nl='
'
  _lcv_dir=""; _lcv_vc=""
  if [ -n "${PM_SNAP:-}" ] && appcode_pm_row "$1"; then
    _lcv_dir=$_pms_dir; _lcv_vc=$_pms_vc; lcv_f=""; [ "$_pms_sys" = 0 ] || lcv_f=" SYSTEM "
  else
    lcv_out=$(dumpsys package "$1" 2>/dev/null | awk '
      !p && /codePath=/ { p = 1; c = $0; sub(/.*codePath=/, "", c) }
      !q && /flags=\[/ { q = 1; f = $0 }
      !r && /(^|[ \t])versionCode=/ { r = 1; v = $0; sub(/.*versionCode=/, "", v); sub(/[^0-9].*/, "", v) }
      END { print c; print f; print v; print "." }')
    _lcv_dir=${lcv_out%%"$lcv_nl"*}; lcv_out=${lcv_out#*"$lcv_nl"}
    lcv_f=${lcv_out%%"$lcv_nl"*}; lcv_out=${lcv_out#*"$lcv_nl"}
    _lcv_vc=${lcv_out%%"$lcv_nl"*}
  fi
  case "$_lcv_vc" in *[!0-9]*) _lcv_vc="" ;; esac
  case "$_lcv_dir" in /data/app/*) ;; *) _lcv_dir=""; return 0 ;; esac
  [ -d "$_lcv_dir" ] || { _lcv_dir=""; return 0; }
  case "$lcv_f" in *" SYSTEM "*) _lcv_dir="" ;; esac
  return 0
}

# NWP-20261128-09 (backlog: every periodic seal spends 4-6 minutes staging #apps for an unchanged 743 KiB push): stage
# one APK, SRC $1 to DST $2. appcode_seal rebuilds its stage at every seal, so every periodic seal copied every kept APK
# again (gigabytes for 71 apps) while it held the RW worker slot. A periodic or manual seal now renames its stage to
# $POOL after the push; the next seal of the same uid MOVES a pool entry to DST (a rename on one filesystem: no bytes
# copied, the mtime kept) when that entry is a regular file and has SRC's size AND SRC's mtime. NWP-20261123-02 gives
# every staged APK its source's mtime, so the pool entry of an unchanged source matches. Else today's copy: cp, the size
# check and touch -r, whose failure adds one line to $SLA_TF and never fails the copy. A reuse adds one line to $SAC_RF.
# Both are files because stage_live_apks runs in a command substitution. Only a DST under $STAGE looks in the pool.
# A link in the pool is never used: [ -f ] follows a link, so [ ! -L ] is its own test, and the candidate is read with
# stat -L (its target), so that test is the only guard against one.
# Status 0: DST is a whole copy or a reused entry. Status 1: DST is not whole (the caller drops the set, NWP-20261108-04).
stage_apk_copy() {
  local sac_c sac_sz sac_mt
  sac_c=""
  case "$2" in "$STAGE"/*) [ -z "${POOL:-}" ] || sac_c="$POOL/${2#"$STAGE"/}" ;; esac
  if [ -n "$sac_c" ] && [ -f "$sac_c" ] \
     && [ ! -L "$sac_c" ] \
     && sac_sz=$(stat -c %s "$1" 2>/dev/null) && [ -n "$sac_sz" ] \
     && [ "$sac_sz" = "$(stat -L -c %s "$sac_c" 2>/dev/null)" ] \
     && sac_mt=$(stat -c %Y "$1" 2>/dev/null) && [ -n "$sac_mt" ] \
     && [ "$sac_mt" = "$(stat -L -c %Y "$sac_c" 2>/dev/null)" ] \
     && mv "$sac_c" "$2" 2>>"$LOG"; then
    { [ -z "${SAC_RF:-}" ] || echo x >> "$SAC_RF"; } 2>/dev/null
    return 0
  fi
  if cp "$1" "$2" 2>>"$LOG" && sac_sz=$(stat -c %s "$1" 2>/dev/null) && [ "$sac_sz" = "$(stat -c %s "$2" 2>/dev/null)" ]; then
    touch -r "$1" "$2" 2>>"$LOG" || { [ -z "${SLA_TF:-}" ] || echo x >> "$SLA_TF"; } 2>/dev/null
    return 0
  fi
  return 1
}

# DIA-20260805-09: stage every .apk in a live code dir into $2, echoing the basenames as tab-prefixed fields.
# NWP-20261108-04: ALL OR NOTHING. A copy is whole when cp exits 0 and the copy's size equals the source's; on the
# first one that is not (a failed cp, a cut copy, a source gone mid-copy) every .apk in $2 is removed, nothing is
# printed and the status is 1. Callers read empty output as "not staged", so the stored set is kept.
# NWP-20261123-02: each whole copy then gets its source's mtime (touch -r; not cp -p, which copies ownership too), so a
# second staging of an unchanged APK gives the agent's scan cache the same (rel, mtime, size, mode) key. A failed touch
# never cuts the set: the bytes are whole, a failure costs one cache miss. It adds one line to $SLA_TF when the caller
# set it (appcode_seal counts them into the "mtime kept-failed" field of its "#apps staged" line): this function runs
# in a command substitution, so a counter variable would not reach the caller.
# NWP-20261128-09: each APK goes through stage_apk_copy, which reuses the previous seal's copy when it can.
stage_live_apks() {
  local sla_names sla_ap sla_bn
  sla_names=""
  for sla_ap in "$1"/*.apk; do
    [ -f "$sla_ap" ] || { [ "$sla_ap" = "$1/*.apk" ] && continue; rm -f "$2"/*.apk; return 1; }
    sla_bn=$(basename "$sla_ap")
    if stage_apk_copy "$sla_ap" "$2/$sla_bn"; then
      sla_names="$sla_names$(printf '\t')$sla_bn"
    else
      rm -f "$2"/*.apk
      return 1
    fi
  done
  printf '%s' "$sla_names"
}

# NWP-20261123-02: give each entry of $2 (a `cp -r` copy of $1) its source entry's mtime, depth first and $2 itself
# last, so a second staging of an unchanged _meta gives the same group key (the agent's groupCacheKey hashes each
# directory's mtime) and the same scan-cache key for each file. A failed touch adds 1 to the caller's _acw_tf and
# never drops the copy: the bytes are whole, a failure costs one cache miss. A symlink is skipped: touch -r would
# follow it out of the stage.
stage_keep_mtimes() {
  local skm_e
  if [ -d "$1" ]; then
    for skm_e in "$1"/* "$1"/.[!.]* "$1"/..?*; do
      [ -e "$skm_e" ] && [ ! -L "$skm_e" ] && [ ! -L "$2/${skm_e##*/}" ] || continue
      stage_keep_mtimes "$skm_e" "$2/${skm_e##*/}"
    done
  fi
  touch -r "$1" "$2" 2>>"$LOG" || _acw_tf=$(( ${_acw_tf:-0} + 1 ))
}

# NWP-20261024-07: DORMANT PLAY STACK. DECIDED 2026-09-26 (docs/product-decisions.md, "Play Store keeps its code"):
# an Off Play Store's data drops and its code stays in the account, as a dormant carried copy. An On-demand one
# already gets that shape (its APKs ride #apps as Deferred entries with no manifest line). An INSTALLED-mode one
# switched Off is in neither input of the stage -- its keep line is gone and it is not in the code list -- so its
# bytes were never staged and the carry (NOWHERE_CARRY_ESSENTIAL is off) could not keep them. (Superseded in part
# by NWP-20261118-10: the carry is on by default; this deferred staging stays, since a flag-off conf still needs
# it.) Stage such a package
# DEFERRED here: APKs under $STAGE/<pkg>, a $DEFER line per APK, NO manifest line, so nothing installs it at login.
# Selection is narrow on purpose: only a stack member the Off record (APPOFF, raw) or the inferred-orphan list
# (CODEKEEP) names, i.e. one this profile had KEPT, so code the user never kept is not put into the account.
# Touches none of n / staged / want_installed / seen: the keep-the-previous-head guard must not be satisfied by it.
# $1 seen, $2 APPOFF, $3 CODEKEEP, $4 AK; reads $STAGE $DEFER $LOG $name.
appcode_stage_play_dormant() {
  local apd_pkg apd_dir apd_kd apd_names apd_bn apd_k apd_f apd_hit apd_t0 apd_t1
  apd_k=0
  for apd_pkg in com.android.vending com.google.android.gms com.google.android.gsf; do
    case "$1" in *" $apd_pkg "*) continue ;; esac
    awk -F'\t' -v p="$apd_pkg" '$1 == p { f = 1 } END { exit !f }' "$4" 2>/dev/null && continue
    apd_hit=0
    for apd_f in "$2" "$3"; do
      [ -s "$apd_f" ] && grep -qxF "$apd_pkg" "$apd_f" 2>/dev/null && apd_hit=1
    done
    [ "$apd_hit" = 1 ] || continue
    apd_t0=$(_ms); apd_dir=$(live_code_dir "$apd_pkg"); apd_t1=$(_ms)   # NWP-20261130-16: the caller's "lookups" part
    _acw_lms=$(( ${_acw_lms:-0} + ${apd_t1:-0} - ${apd_t0:-0} )); _acw_lct=$(( ${_acw_lct:-0} + 1 ))
    [ -n "$apd_dir" ] || continue
    apd_kd="$STAGE/$apd_pkg"; mkdir -p "$apd_kd" 2>>"$LOG" || continue
    apd_t0=$(_ms)
    apd_names=$(stage_live_apks "$apd_dir" "$apd_kd")
    # NWP-20261123-02: the LAST write into a staged $apd_kd gives it its live code dir's mtime (see stage_live_apks),
    # and the copy time is added to the caller's "#apps staged" copy field.
    if [ -n "$apd_names" ]; then touch -r "$apd_dir" "$apd_kd" 2>>"$LOG" || _acw_tf=$(( ${_acw_tf:-0} + 1 )); fi
    apd_t1=$(_ms); _acw_cms=$(( ${_acw_cms:-0} + ${apd_t1:-0} - ${apd_t0:-0} ))
    [ -n "$apd_names" ] || { rmdir "$apd_kd" 2>/dev/null; continue; }
    apd_t0=$(_ms)
    for apd_bn in $apd_names; do printf '%s/%s\n' "$apd_pkg" "$apd_bn" >> "$DEFER"; done
    apd_t1=$(_ms); _acw_sms=$(( ${_acw_sms:-0} + ${apd_t1:-0} - ${apd_t0:-0} ))
    apd_k=$((apd_k+1))
  done
  [ "$apd_k" -gt 0 ] || return 0
  print -r -- "[roamd] OUT $(qn "$name") #apps: $apd_k Play stack pkg(s) not kept this session staged DEFERRED -- their code stays in the account (DECIDED 2026-09-26, NWP-20261024-07)" >> "$LOG"
  return 0
}

# _apps_stage_prog I N (NWP-20261005-04): one progress line for the #apps STAGING step, in the agent's own
# "<phase> <done> <total> <scope>" shape (writeProg), written the same atomic way (tmp + rename).
#
# Why it exists: the daemon gives up on a worker op after 150 s with NO CHANGE in this file (roamStallTicks), and
# the staging loop below cp's every kept app's whole APK while writing nothing. Device-seen on frankel 0.5.41,
# ticket NW-f6f717125af3: the logoff seal sealed the vault, #de, #media and #sys by 13:09:13, then staged #apps,
# and the daemon declared ERR-TIMEOUT exactly 150 s after that last write -- so the logoff failed and the session
# stayed signed in. It became reachable that day: the AUTO sweep had installed the profile's on-demand apps (an
# #apps head of 180 APKs, ~8.8 GB), and every installed app's APK is copied on every seal.
#
# "sizes" is the agent's unit-less phase: the gate draws the fraction and shows no byte text, which is right for
# "package i of n". One line per PACKAGE, so a single APK slower than 150 s to copy would still starve it.
_apps_stage_prog() {
  [ -n "$NOWHERE_PROGRESS" ] || return 0
  printf 'sizes %s %s apps\n' "$1" "$2" > "$NOWHERE_PROGRESS.tmp" 2>/dev/null &&
    mv -f "$NOWHERE_PROGRESS.tmp" "$NOWHERE_PROGRESS" 2>/dev/null
  return 0
}

# _restore_tail_prog I N (NWP-20261017-05): one "finishing I N" progress line for a step of the post-#media tail of
# the `in` op, written like _apps_stage_prog (atomic tmp + rename). The daemon's stall watchdog reads ANY change of
# roam.progress as liveness, and this tail (remap_tree + restorecon -R -D over the whole media tree, the
# ext-appdata re-own, the dir chmod) used to write nothing, so a large profile spent most of the 15-minute `in`
# budget with the file unchanged and a bigger one was reaped mid-restore. No background heartbeat on purpose: each
# line means a step STARTED, so a step that truly hangs still trips the watchdog.
_restore_tail_prog() {
  [ -n "$NOWHERE_PROGRESS" ] || return 0
  printf 'finishing %s %s\n' "$1" "$2" > "$NOWHERE_PROGRESS.tmp" 2>/dev/null &&
    mv -f "$NOWHERE_PROGRESS.tmp" "$NOWHERE_PROGRESS" 2>/dev/null
  return 0
}

# restore_media_tail DIR: the steps after a successful #media restore, one progress line before each (n = 3 + k,
# k = the Android/{data,obb}/* dirs present; the chmod is line n and the per-package re-owns are 3..2+k).
restore_media_tail() {
  _md="$1"
  _rt_n=3
  for _ed in "$_md"/Android/data/* "$_md"/Android/obb/*; do
    [ -d "$_ed" ] && _rt_n=$((_rt_n+1))
  done
  _restore_tail_prog 1 "$_rt_n"
  _tt=$(_ms); remap_tree "$_md"; _tlog reown-media "$_tt"
  _restore_tail_prog 2 "$_rt_n"
  _tt=$(_ms); restorecon -R -D "$_md" 2>> "$LOG"; _tlog restorecon-media "$_tt"
  # remap_tree just media_rw'd the WHOLE tree, INCLUDING the app-private Android/{data,obb}/<pkg> subtrees the
  # app reaches via the pass-through (DAC vs OWNER) -- reown those back to their app (DIA-20260730). Regular
  # (already-provisioned) apps resolve their appId now; on-demand apps aren't in packages.list yet -> skipped
  # here and re-owned by odrestore at their tap.
  _tt=$(_ms)
  _rt_i=2
  for _ed in "$_md"/Android/data/* "$_md"/Android/obb/*; do
    [ -d "$_ed" ] || continue
    _rt_i=$((_rt_i+1)); _restore_tail_prog "$_rt_i" "$_rt_n"
    reown_ext_appdata "${_ed##*/}"
  done
  _tlog ext-appdata "$_tt"
  # DIA-20260726-07: MediaProvider's FUSE reads the backing /data/media/N via the media_rw GROUP (not the owner),
  # so a restored dir that came back group-inaccessible is INVISIBLE to every app even though its bytes are intact.
  # An app that made a subfolder with a 0700 umask leaves the backing dir 0700; under the parent's setgid it seals
  # + restores as 2700 (drwx--S---, no group r/x) -> the folder lists EMPTY through the FUSE (device-proven:
  # Documents/markor hidden, note recovered by chmod g+rwx). Normalise restored media DIRS to group-traversable,
  # matching MediaProvider's own 2770 dirs. Dirs only: files seal group-rw (0660) and a -type f walk would add a
  # per-file chmod to every login. Additive (g+rwx) so setgid + owner/other bits are preserved.
  _restore_tail_prog "$_rt_n" "$_rt_n"
  _tt=$(_ms); find "$_md" -type d -exec chmod g+rwx {} + 2>> "$LOG"; _tlog chmod-media-dirs "$_tt"
}

appcode_seal() {
  # #737: the last roamd step that runs with the user ALIVE on the logoff path, so it is the last chance to
  # populate KS_KEEP before keystore2 dumps at remove_user. Hooked here rather than given its own dispatch arm
  # so it cannot be skipped by a logoff variant that takes a different route to teardown.
  # (KS_KEEP superseded by NWP-20260830-03: the sweep now writes KS_MAP, the ns->pkg map keystore_push names
  # each dump by. KS_KEEP is never written.)
  keystore_register_all
  AL="$USERDIR/com.nowhere.chooser/files/nowhere-appcode.list"
  AK="$USERDIR/com.nowhere.chooser/files/nowhere-appkeep"
  # DIA-20260805-09: the KEEP-SET alone is enough to seal from now (paths are resolved live below), so an
  # absent/empty code list is no longer a reason to bail -- that is exactly the broken state we recover from.
  # NWP-20261025-04 (backlog: uninstalling or switching Off the LAST kept app does not stick; DECIDED 2026-09-06
  # uninstall, 2026-09-26 Off): the chooser empties the keep-set by WRITING it, so an empty keep-set FILE is its
  # record that this profile kept apps and now keeps none. That seals an empty stage; only an ABSENT keep-set returns.
  # NWP-20261128-09: the previous seal's stage, kept for stage_apk_copy (one live session, one uid). Set before the
  # return below, which removes it: a sign-out's seal can return there, and a sign-out purges the pool.
  POOL=/data/nowhere/appcode-reuse
  [ -s "$AL" ] || [ -s "$AK" ] || [ -f "$AK" ] || { rm -rf "$POOL" 2>/dev/null; return 0; }
  [ -s "$AL" ] || AL=/dev/null   # keep-set-only recovery: the staging loop below must still have a readable input
  # NWP-20261005-04: time the step. NWP-20261130-16: the clock starts here, so the drop lists below count in the "lists"
  # part. _acw_lms and _acw_lct: the lookups' ms and count. _acw_kms: the carry branch. _acw_sms: the list writes. Each span
  # closes before another opens, so no ms counts twice; _acw_t0, _acw_k0 and _acw_s0 start one span each.
  local _stg_t0 _stg_i _stg_n _stg_a _stg_k
  local _acw_lms _acw_lct _acw_kms _acw_sms _acw_t0 _acw_k0 _acw_s0 _stg_ms _stg_oth _stg_kib
  _stg_t0=$(_ms); _acw_lms=0; _acw_lct=0; _acw_kms=0; _acw_sms=0
  META_SRC="$USERDIR/com.nowhere.chooser/files/nowhere-appmeta"  # #204: per-pkg archived-placeholder snapshots
  STAGE=/data/nowhere/appcode-stage
  DEFER=/data/nowhere/appcode-defer   # #204: rel-prefixes the #apps seal must DEFER (on-demand APK bytes). Kept
                                      # OUTSIDE $STAGE so the seal walk never seals the directive itself; passed
                                      # to the push via NOWHERE_DEFER_LIST.
  DORMANT=/data/nowhere/appcode-dormant   # NWP-20261128-01: the dormant shape (dir, _meta, a line naming no APK) of
                                          # each On-demand/Auto pkg the carry branch stages nothing for; the agent
                                          # adopts one only when the stored head's app index has no line for it.
  # DIA-20260804-10: switched-off apps, for the #apps push below. Empty string when absent -> the agent's
  # loadDropList sees an unset var and drops nothing, i.e. the pre-DIA-20260804-04 behaviour.
  APPDROP=""
  # NWP-20260906-19: APPKEEP is set UNCONDITIONALLY now. It used to be set only when a drop list existed,
  # which was fine while it was mere belt-and-braces. It is not any more: the keep-set is what CLEARS an
  # ACCOUNT TOMBSTONE (loadDropList refuses to drop a currently-kept package, and that is the tombstone's
  # only escape hatch), so a push that reached the agent without NOWHERE_KEEP_LIST would leave a re-added
  # app suppressed forever -- the user reinstalls it, keeps it, and it vanishes again at every seal.
  APPKEEP="$USERDIR/com.nowhere.chooser/files/nowhere-appkeep"
  if [ -s "$USERDIR/com.nowhere.chooser/files/nowhere-appdrop.list" ]; then
    APPDROP="$USERDIR/com.nowhere.chooser/files/nowhere-appdrop.list"
  fi
  # NWP-20260830-08: DROP THE DATA, KEEP THE CODE -- splitting a switch that was only ever one switch.
  #
  # The SAME drop list went to both sides: exported around the three DATA pushes in the `out` op, and passed
  # inline to the #apps push below. Those two do very different things with it. On the data side it stops an
  # app's CE/DE/external dirs being sealed -- the saving NWP-20260826-13 was written for, gms being routinely
  # the largest data dir on the phone. On the #apps side it defeats the
  # CARRY-FORWARD (the agent's pushProfile, its #84 deferred carry,
  # "a deliberate exclusion is a deletion"), and that carry is the ONLY thing preserving an archived on-demand
  # app's APK bytes across a roam. So a package on this list loses its CODE permanently.
  #
  # For an app the user explicitly switched Off that is correct, and it stays (DECIDED 2026-09-26). For an INFERRED orphan it is
  # not: the chooser never asked, the user never chose, and gms/gsf are filtered out of "Your apps" so they
  # cannot be re-added by hand. Chester lost the sandboxed Play stack in odtest35 exactly this way on
  # 2026-08-30, left with a Google account row that rendered as nothing. The chooser now names those packages
  # in nowhere-appkeepcode.list; subtract them here, on the CODE side only.
  CODEKEEP="$USERDIR/com.nowhere.chooser/files/nowhere-appkeepcode.list"
  DROPFILTER=/data/nowhere/appcode-dropfilter
  # NWP-20260906-19: THE CODE-SIDE LIST IS NOW THE EXPLICIT-OFF RECORD ONLY, intersected before anything
  # else. Dropping an app's DATA is a per-device decision and launcher enumeration is the right source for
  # it. Deleting an app's CODE FROM THE ACCOUNT is an account-level act. This list deletes an Off or uninstalled
  # app's code from the account head; only its UNINSTALL subset (NOWHERE_GONE_LIST, NWP-20261023-07, below) mints
  # the TOMBSTONE (NWP-20260906-18) that propagates to every other handset and suppresses the app there too.
  #
  # nowhere-appdrop.list also carries every launcher-visible, non-kept app found by ENUMERATION -- packages
  # the user never chose to remove. Handing those to the code side would delete their code from the
  # account. nowhere-appoff.list is the record of what the user actually did, and since NWP-20260825-22 a
  # Settings uninstall lands there too, so nothing real is lost by narrowing to it.
  #
  # BEHAVIOUR-NEUTRAL TODAY -- a non-kept app has no code in the head at all, because the stage is built
  # from readAppKeep() -- and load-bearing once a carry or a tombstone is LIVE (both built, both off on every image).
  APPOFF="$USERDIR/com.nowhere.chooser/files/nowhere-appoff.list"
  DROPOFF=/data/nowhere/appcode-dropoff
  PLAYSTACK=/data/nowhere/appcode-playstack
  PLAYTMP=/data/nowhere/appcode-playfilter
  DROPGONE=/data/nowhere/appcode-dropgone
  # NWP-20261128-26: these lists name the profile's apps outside every per-user key, so no return below leaves them; staging_boot is the backstop only for a killed op.
  rm -f "$DROPFILTER" "$DROPOFF" "$DROPGONE" "$PLAYSTACK" "$PLAYTMP"
  APPDROP_CODE=""
  if [ -n "$APPDROP" ] && [ -s "$APPOFF" ]; then
    # -x -F: whole-line and literal, for the same reason as the subtraction below.
    grep -xF -f "$APPOFF" "$APPDROP" > "$DROPOFF" 2>/dev/null || :
    # NWP-20261021-03: PLAY STORE KEEPS ITS CODE (DECIDED 2026-09-26, docs/product-decisions.md; Chester: "keep play
    # store"). The chooser's explicitlyTurnedOff skips VENDING_PKG / GMS_PKG / GSF_PKG lines of the Off record as
    # residue, but this reads the file RAW: setAppModeLocked records a Play Store the user switched Off like any app,
    # and the launcher pass of captureAppDrops puts a materialised one in nowhere-appdrop.list, so the intersection
    # above named it and the #apps carry dropped its stored APK -- and the stale odtest35 gms/gsf stamps went the
    # same way. Subtract the three here, whatever the record holds. A filter ERROR empties the list: dropping code
    # cannot be undone, keeping it is what the decision protects. Only the CODE side: the DATA drop (APPDROP,
    # exported around the data pushes) is unchanged, so an Off Play Store's data still drops as any Off's does.
    # Route (1), an INSTALLED-mode Play Store whose code comes from the keep-set: appcode_stage_play_dormant (NWP-20261024-07) stages an unkept one DEFERRED.
    printf '%s\n' com.android.vending com.google.android.gms com.google.android.gsf > "$PLAYSTACK" 2>/dev/null
    grep -vxF -f "$PLAYSTACK" "$DROPOFF" > "$PLAYTMP" 2>/dev/null; _psr=$?
    if [ "$_psr" -le 1 ]; then
      _psa=$(wc -l < "$DROPOFF" 2>/dev/null | tr -d ' ')
      _psb=$(wc -l < "$PLAYTMP" 2>/dev/null | tr -d ' ')
      _psn=$(( ${_psa:-0} - ${_psb:-0} ))
      if mv -f "$PLAYTMP" "$DROPOFF" 2>/dev/null; then
        [ "$_psn" -gt 0 ] && print -r -- "[roamd] OUT $(qn "$name") #apps: code KEPT for $_psn Play stack pkg(s) the Off record names -- DECIDED 2026-09-26 (NWP-20261021-03) $(date)" >> "$LOG"
      else
        ( : > "$DROPOFF" )
      fi
    else
      ( : > "$DROPOFF" )
    fi
    rm -f "$PLAYSTACK" "$PLAYTMP"
    [ -s "$DROPOFF" ] && APPDROP_CODE="$DROPOFF"
  fi
  if [ -n "$APPDROP_CODE" ] && [ -s "$CODEKEEP" ]; then
    # -x -F: whole-line and literal. A package name is never a regex, and a substring match would retain the
    # wrong app's code. grep exits 1 when EVERY line got filtered out -- a real outcome (nothing left to drop
    # code for), not an error -- so swallow the status and decide on the file with -s.
    grep -vxF -f "$CODEKEEP" "$APPDROP_CODE" > "$DROPFILTER" 2>/dev/null || :
    if [ -s "$DROPFILTER" ]; then APPDROP_CODE="$DROPFILTER"; else APPDROP_CODE=""; fi
    print -r -- "[roamd] OUT $(qn "$name") #apps: code RETAINED for $(wc -l < "$CODEKEEP" 2>/dev/null | tr -d ' ') inferred-orphan pkg(s), their data still drops (NWP-20260830-08) $(date)" >> "$LOG"
  fi
  # NWP-20261023-07: THE UNINSTALL SUBSET, the only thing that may mint an account tombstone. DECIDED 2026-09-26: an
  # app switched Off leaves the store at the next roam but never mints the tombstone, and nowhere-appoff.list holds
  # Offs and uninstalls alike, so APPDROP_CODE cannot tell them apart. The chooser records an uninstall in
  # nowhere-appgone.list (not the stamped nowhere-appgone); intersecting with APPDROP_CODE means the result can
  # never name the Play stack, an inferred orphan or an enumerated app. grep status 0 = use it, 1 = nothing was
  # uninstalled, above 1 = an error: the partial file is removed and NOTHING is minted -- a missing tombstone is
  # the shipped behaviour, a wrong one deletes an app from the whole account. The log is counts only: roam.log
  # sits outside every wipe path, so no package name goes in it. The list reaches the #apps push only.
  APPGONE="$USERDIR/com.nowhere.chooser/files/nowhere-appgone.list"
  APPGONE_CODE=""
  if [ -n "$APPDROP_CODE" ] && [ -s "$APPGONE" ]; then
    grep -xF -f "$APPGONE" "$APPDROP_CODE" > "$DROPGONE" 2>/dev/null; _gnr=$?
    if [ "$_gnr" = 0 ] && [ -s "$DROPGONE" ]; then
      APPGONE_CODE="$DROPGONE"
      print -r -- "[roamd] OUT $(qn "$name") #apps: $(wc -l < "$DROPGONE" 2>/dev/null | tr -d ' ') code-dropped pkg(s) were uninstalled -- only those mint an account tombstone (NWP-20261023-07) $(date)" >> "$LOG"
    else
      rm -f "$DROPGONE"
    fi
  fi
  # DIA-20260812-10 (#118): a stage we cannot create is a FAILURE, not a no-op. Returning 0 here reported a
  # seal that never even started as a success.
  # NWP-20261128-09: keep the pool only when it is a real dir (not a link) whose .uid (a regular file, not a link) names
  # this seal's uid; any other pool is another profile's or not ours, and is removed before anything reads it.
  local _acw_pu
  _acw_pu=""
  _acw_sms=$(( $(_ms) - _stg_t0 ))   # NWP-20261130-16: the drop lists above
  case "$uid" in ''|*[!0-9]*) rm -rf "$POOL" 2>/dev/null ;; esac
  [ -d "$POOL" ] && [ ! -L "$POOL" ] && [ -f "$POOL/.uid" ] && [ ! -L "$POOL/.uid" ] \
    && { IFS= read -r _acw_pu < "$POOL/.uid"; } 2>/dev/null \
    && [ "$_acw_pu" = "$uid" ] || rm -rf "$POOL" 2>/dev/null
  rm -rf "$DORMANT"
  rm -rf "$STAGE"; mkdir -p "$STAGE" 2>>"$LOG" || { print -r -- "[roamd] OUT $(qn "$name") #apps cannot create the stage -- NOT SEALED $(date)" >> "$LOG"; rm -rf "$POOL" 2>/dev/null; rm -f "$DROPFILTER" "$DROPOFF" "$DROPGONE" 2>/dev/null; return 1; }
  # NWP-20261123-10: a manifest we cannot create is a stage we cannot build (DIA-20260812-10), so it refuses the
  # same way. The next sign-in restores #apps only when the head holds a manifest.tsv; a head of APKs without one
  # installs no app. [ -f ] catches a truncation that succeeds on a non-file: a symlink to /dev/null truncates
  # cleanly and swallows every line. The subshell stays (NWP-20261114-09): a failed redirection on : ends mksh.
  MAN="$STAGE/manifest.tsv"
  ( : > "$MAN" ) 2>>"$LOG" && [ -f "$MAN" ] || { print -r -- "[roamd] OUT $(qn "$name") #apps cannot create the stage's manifest -- NOT SEALED $(date)" >> "$LOG"; rm -rf "$STAGE" "$POOL" "$DORMANT" 2>/dev/null; rm -f "$DROPFILTER" "$DROPOFF" "$DROPGONE" 2>/dev/null; return 1; }
  # NWP-20261123-02: stage_live_apks's failed touches, one line each; counted and removed before the "#apps staged" line.
  SLA_TF="$STAGE/.mtime-kept-failed"
  # NWP-20261128-09: stage_apk_copy's reuses, one line each; counted and removed before the "#apps staged" line.
  SAC_RF="$STAGE/.apk-reused"
  ( : > "$DEFER" )
  mkdir -p "$DORMANT" 2>>"$LOG"
  n=0
  staged=0   # DIA-20260805-09: packages for which at least one real APK landed in the stage
  seen=" "   # packages the code list already covered, so the keep-set sweep below doesn't double-stage
  # NWP-20261005-04: keep the daemon's stall watchdog fed while staging (_apps_stage_prog).
  # The total is both lists' line counts, an upper bound; it grows if a count runs past it.
  local _acw_n _acw_w _acw_cut _acw_bn _acw_left
  # NWP-20261119-02: the parse (_pl_*), the stale-path class (_acw_gone, _acw_stale, _acw_why), its counts (_st_*),
  # live_code_ver's answer (_lcv_*) and the meta's own vc (_mvc, _ml).
  local _acw_tab _acw_gone _acw_stale _acw_why _pl_r _pl_v _pl_k _pl_more _pl_f4 _pl_aps _pl_amore
  local _st_s _st_c _st_k _st_n _lcv_dir _lcv_vc _mvc _ml
  # NWP-20261123-02: staged entries keep their sources' mtimes. _acw_tf counts the touches that failed, _acw_cms the
  # ms spent copying (cp, size check, touch), _acw_c0 starts one span, _acw_src is the source of the package dir's mtime.
  # NWP-20261128-09: _acw_ru counts the APKs stage_apk_copy reused from the pool.
  local _acw_tf _acw_cms _acw_c0 _acw_src _acw_l _acw_ru
  _stg_i=0; _acw_left=0; _st_s=0; _st_c=0; _st_k=0; _acw_tf=0; _acw_cms=0; _acw_ru=0
  _acw_tab=$(printf '\t')
  _stg_a=$(grep -c . "$AL" 2>/dev/null); _stg_k=$(grep -c . "$AK" 2>/dev/null)
  _stg_n=$(( ${_stg_a:-0} + ${_stg_k:-0} ))
  # NWP-20261130-16: one PackageManager read for the whole stage. Its time counts in the "lookups" ms, not in the count.
  _acw_t0=$(_ms); appcode_pm_snapshot; _acw_lms=$((_acw_lms + $(_ms) - _acw_t0))
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # NWP-20261119-02: ONE builtin pass per line. Each field used to be `$(printf '%s' "$line" | cut -fN)`, and on the
    # device printf is /system/bin/printf: two execs per field, a few hundred per seal. The split copies `cut -f N`
    # exactly: a line with no TAB is printed WHOLE for every N (so its pkg and mode are the line, and its one APK
    # field is the line -- the old loop never ended on one, since cut -f$i never came back empty), a line with TABs
    # gives field N or empty past its last, and meta is cut -f1-3 (the first min(3, fields) fields).
    case "$line" in
      *"$_acw_tab"*)
        _pl_r=$line; _pl_more=1; _pl_k=0; pkg=""; meta=""; _pl_f4=""
        while [ "$_pl_k" -lt 4 ] && [ "$_pl_more" = 1 ]; do
          _pl_k=$((_pl_k+1))
          case "$_pl_r" in *"$_acw_tab"*) _pl_v=${_pl_r%%"$_acw_tab"*}; _pl_r=${_pl_r#*"$_acw_tab"} ;; *) _pl_v=$_pl_r; _pl_more=0 ;; esac
          case "$_pl_k" in 1) pkg=$_pl_v; meta=$_pl_v ;; 2|3) meta="$meta$_acw_tab$_pl_v" ;; 4) _pl_f4=$_pl_v ;; esac
        done ;;
      *) pkg=$line; meta=$line; _pl_f4=$line; _pl_k=4; _pl_more=0; _pl_r="" ;;
    esac
    [ -n "$pkg" ] || continue
    _stg_i=$((_stg_i+1)); [ "$_stg_i" -le "$_stg_n" ] || _stg_n=$_stg_i; _apps_stage_prog "$_stg_i" "$_stg_n"
    pkgname_ok "$pkg" || { echo "[roamd] appcode: code-list line skipped -- not a package name $(date)" >> "$LOG"; continue; }
    # #204: column 4 is the keep MODE (installed|ondemand|auto, #130). A stale pre-#204 list has an apk PATH
    # there instead (absolute, leading '/') -- treat that as legacy: mode=installed, apk paths from col 4.
    # _pl_aps holds the APK fields TAB-joined (col 5 on, or col 4 on for legacy); _pl_amore=0 means there are none.
    mode=$_pl_f4
    case "$mode" in
      installed|ondemand|auto) _pl_aps=$_pl_r; _pl_amore=$_pl_more ;;
      *)                       mode=installed
                               if [ "$_pl_k" -lt 4 ]; then _pl_aps=""; _pl_amore=0
                               elif [ "$_pl_more" = 1 ]; then _pl_aps="$_pl_f4$_acw_tab$_pl_r"; _pl_amore=1
                               else _pl_aps=$_pl_f4; _pl_amore=1; fi ;;
    esac
    meta="$meta$_acw_tab$mode"   # pkg \t versionCode \t sideloaded \t mode
    d="$STAGE/$pkg"; mkdir -p "$d" 2>>"$LOG" || continue
    names=""; grp=""; _acw_src=""
    _acw_n=0; _acw_w=0; _acw_cut=0; _acw_gone=0
    _acw_c0=$(_ms)
    while [ "$_pl_amore" = 1 ]; do
      case "$_pl_aps" in *"$_acw_tab"*) ap=${_pl_aps%%"$_acw_tab"*}; _pl_aps=${_pl_aps#*"$_acw_tab"} ;; *) ap=$_pl_aps; _pl_amore=0 ;; esac
      [ -n "$ap" ] || break
      # group-materialize: an optional trailing `group:<name>` token rides after the apk basenames. Capture it
      # (it is NOT an apk: don't cp, don't defer, don't add to $names) and re-emit it as the manifest trailing field
      # so the chooser login reader sees the group. col4=mode / col5=apk stay literal.
      case "$ap" in group:*) grp="$ap"; continue;; esac
      _acw_n=$((_acw_n+1))
      case "$ap" in */../*|*/..|*/./*) _acw_cut=1; continue;; /data/app/*) ;; *) _acw_cut=1; continue;; esac
      [ -f "$ap" ] || _acw_gone=$((_acw_gone+1))
      [ -f "$ap" ] || { _acw_cut=1; continue; }
      bn=$(basename "$ap")
      # NWP-20261123-02, NWP-20261128-09: stage_apk_copy keeps the source's mtime (a failed touch is counted through
      # $SLA_TF, never a cut) and reuses the previous seal's copy of an unchanged source.
      if stage_apk_copy "$ap" "$d/$bn"; then
        [ -n "$_acw_src" ] || _acw_src=${ap%/*}
        _acw_w=$((_acw_w+1))
        names="$names$_acw_tab$bn"
      else
        _acw_cut=1
      fi
    done
    _acw_cms=$((_acw_cms + $(_ms) - _acw_c0))
    # NWP-20261119-02: STALE is not CUT. The list is written only at sign-out and the app is reinstalled into a fresh
    # /data/app/~~<rand>~~ dir at every sign-in, so on a periodic seal EVERY listed path is the previous session's.
    # A package none of whose listed paths exists (each one under /data/app, so none was refused by the guard
    # above) copied nothing and cut nothing: it is re-resolved live below or carried, and never counts as "did not
    # copy whole". CUT stays what NWP-20261108-04 meant: a copy that failed or came out short, a refused path, or
    # SOME of the set missing.
    _acw_stale=0
    if [ "$_acw_n" -gt 0 ] && [ "$_acw_gone" -eq "$_acw_n" ]; then
      _acw_stale=1
      _acw_cut=0   # stale, not cut: only a failed live copy below makes it cut
    fi
    # NWP-20261108-04: a package's APK set is staged WHOLE or not at all (NOWHERE-721's stageapp rule). A copy that
    # failed part-way (ENOSPC) or came out short left a cut file here, and the set went on without that split: the
    # package counted as staged, the agent's presence guard saw bytes, and the push replaced the stored complete set
    # with an incomplete one. Any listed APK that is not whole drops the package's APKs (the dir stays, _meta goes
    # in below) and its names: an installed one falls into the live re-resolve, an on-demand/auto one is left in the
    # dormant shape so NOWHERE_CARRY_DEFERRED keeps the stored set.
    if [ "$_acw_w" -eq "$_acw_n" ]; then
      # On-demand/auto (#130): the APK bytes ride the seal (a tap or the auto sweep materialises them) but are
      # DEFERRED -- excluded from the login restore. Installed apps stay essential (restored whole at login, #200).
      case "$mode" in ondemand|auto) _acw_s0=$(_ms); for _acw_bn in $names; do printf '%s/%s\n' "$pkg" "$_acw_bn" >> "$DEFER"; done; _acw_sms=$((_acw_sms + $(_ms) - _acw_s0));; esac
    else
      rm -f "$d"/*.apk
      names=""; _acw_src=""
    fi
    # DIA-20260805-09: the paths above were recorded by the session that WROTE this list, and the list ROAMS.
    # After a login the app is reinstalled into a freshly randomized /data/app/~~<rand>~~/<pkg>-<rand>/ dir, so
    # every recorded path is dead for the whole session: `[ -f "$ap" ] || continue` stages NOTHING and the
    # 120s periodic seal commits an #apps head with no code for this app. Device-proven on lynx 2026-08-05
    # (odtest27/user 12: all 3 recorded paths MISSING, head went 4 pkg -> 1 pkg, .appcode restored empty).
    # It is also self-sustaining: captureAppCode reads ai.sourceDir, which needs the app INSTALLED, so once an
    # app fails to restore it is dropped from the list and can never re-add itself. Re-resolve live instead.
    # ~~On-demand apps are exempt: their bytes are DEFERRED and NOWHERE_CARRY_DEFERRED re-emits them, and a
    # dormant placeholder has no local APK to find anyway.~~ (Superseded by NWP-20261119-02 for STALE paths: an
    # on-demand/auto app the session materialised, or Play updated, has its live code here, and carrying the stored
    # bytes beside a fresh _meta sealed a pair whose versions differ. It is re-resolved in the branch below. A CUT
    # on-demand/auto copy is still exempt.)
    if [ -z "$names" ] && [ "$mode" != ondemand ] && [ "$mode" != auto ]; then   # #130: deferred bytes cover auto too
      _acw_t0=$(_ms); cdir=$(live_code_dir "$pkg"); _acw_lms=$((_acw_lms + $(_ms) - _acw_t0)); _acw_lct=$((_acw_lct+1))
      if [ -n "$cdir" ]; then
        _acw_c0=$(_ms)
        names=$(stage_live_apks "$cdir" "$d") || _acw_cut=1
        _acw_cms=$((_acw_cms + $(_ms) - _acw_c0))
        [ -z "$names" ] || _acw_src=$cdir
        [ -n "$names" ] && echo "[roamd] appcode re-resolved $pkg -> $cdir (list paths were stale) $(date)" >> "$LOG"
        [ -n "$names" ] && [ "$_acw_stale" = 1 ] && _st_s=$((_st_s+1))
      fi
    fi
    # NWP-20261119-02: a STALE on-demand/auto package. Its live code is staged DEFERRED only when the captured
    # placeholder metadata describes those very bytes (meta's vc = the live versionCode): a _meta is never sealed
    # beside APK bytes it does not describe (frankel 2026-10-28: INSTALL_FAILED_INVALID_APK, the _meta's version
    # code newer than the carried APK's). Otherwise it is a CARRY: with NOWHERE_CARRY_ESSENTIAL=1 nothing of it is
    # staged -- no dir, no _meta, no line -- so the agent carries the stored line, _meta and APKs together; with it
    # off the old dormant shape (dir + _meta + a line naming no APK) stays, for the deferred carry. _acw_why is
    # s (staged), c (carried: no live dir, or a version unknown on either side), k (carried: the versions differ)
    # or x (the live copy cut: counted as not whole, then carried).
    if [ "$_acw_stale" = 1 ] && { [ "$mode" = ondemand ] || [ "$mode" = auto ]; }; then
      _acw_t0=$(_ms); live_code_ver "$pkg"; _acw_lms=$((_acw_lms + $(_ms) - _acw_t0)); _acw_lct=$((_acw_lct+1))
      _acw_k0=$(_ms)   # NWP-20261130-16: the "carry" part: this branch, less its lookup, copy and list writes
      _mvc=""
      if [ -f "$META_SRC/$pkg/meta" ]; then
        while IFS= read -r _ml; do case "$_ml" in "vc$_acw_tab"*) _mvc=${_ml#"vc$_acw_tab"}; break ;; esac; done < "$META_SRC/$pkg/meta"
      fi
      case "$_mvc" in *[!0-9]*) _mvc="" ;; esac
      _acw_why=c
      if [ -n "$_lcv_dir" ] && [ -n "$_mvc" ] && [ -n "$_lcv_vc" ]; then
        if [ "$_mvc" = "$_lcv_vc" ]; then _acw_why=s; else _acw_why=k; fi
      fi
      if [ "$_acw_why" = s ]; then
        _acw_kms=$((_acw_kms + $(_ms) - _acw_k0))
        _acw_c0=$(_ms)
        names=$(stage_live_apks "$_lcv_dir" "$d") || _acw_cut=1
        _acw_cms=$((_acw_cms + $(_ms) - _acw_c0))
        if [ -n "$names" ]; then
          _acw_src=$_lcv_dir
          _acw_s0=$(_ms)
          for _acw_bn in $names; do printf '%s/%s\n' "$pkg" "$_acw_bn" >> "$DEFER"; done
          _acw_sms=$((_acw_sms + $(_ms) - _acw_s0))
          _st_s=$((_st_s+1))
        elif [ "$_acw_cut" = 1 ]; then
          _acw_left=$((_acw_left+1)); _acw_why=x
        else
          _acw_why=c
        fi
        _acw_k0=$(_ms)
      fi
      case "$_acw_why" in c) _st_c=$((_st_c+1)) ;; k) _st_k=$((_st_k+1)) ;; esac
      if [ "$_acw_why" != s ]; then
        seen="$seen$pkg "
        if [ "$NOWHERE_CARRY_ESSENTIAL" = 1 ]; then
          # NWP-20261128-01: the flag-off dormant shape (dir, _meta, a line naming no APK) goes to $DORMANT, never to
          # $STAGE. The agent adopts it only when the stored head's app index has no line for $pkg (a head sealed
          # before 0.5.51 has no index, so the carry has nothing to carry from); otherwise the index carries it.
          if mkdir -p "$DORMANT/$pkg" 2>>"$LOG"; then
            _acw_src=""
            if [ -d "$META_SRC/$pkg" ]; then
              cp -r "$META_SRC/$pkg" "$DORMANT/$pkg/_meta" 2>>"$LOG"
              if [ -d "$DORMANT/$pkg/_meta" ]; then stage_keep_mtimes "$META_SRC/$pkg" "$DORMANT/$pkg/_meta"; _acw_src="$META_SRC/$pkg"; fi
            fi
            if [ -n "$_acw_src" ]; then touch -r "$_acw_src" "$DORMANT/$pkg" 2>>"$LOG" || _acw_tf=$((_acw_tf+1)); fi
            [ -n "$_acw_src" ] || TZ=UTC0 touch -t 200001010000.00 "$DORMANT/$pkg" 2>>"$LOG" || _acw_tf=$((_acw_tf+1))
            _acw_kms=$((_acw_kms + $(_ms) - _acw_k0)); _acw_s0=$(_ms)
            printf '%s%s\n' "$meta" "${grp:+$_acw_tab$grp}" >> "$DORMANT/manifest.tsv"
            _acw_sms=$((_acw_sms + $(_ms) - _acw_s0)); _acw_k0=$(_ms)
          fi
          rm -f "${d:?}"/*.apk; rmdir "$d" 2>/dev/null
          _acw_kms=$((_acw_kms + $(_ms) - _acw_k0))
          continue
        fi
        _acw_cut=0   # the flag is off: the dormant shape below, its _meta and a line naming no APK
      fi
      _acw_kms=$((_acw_kms + $(_ms) - _acw_k0))
    fi
    if [ -z "$names" ] && [ "$_acw_cut" = 1 ]; then _acw_left=$((_acw_left+1)); fi
    [ -n "$names" ] && staged=$((staged+1))
    seen="$seen$pkg "
    # On-demand: also stage the archived-placeholder metadata (certs + launcher activities + icons) the chooser
    # captured into nowhere-appmeta/<pkg>/, as <pkg>/_meta -- ESSENTIAL, so the placeholder installs at login
    # WITHOUT the APK bytes. The chooser reads it from .appcode/<pkg>/_meta (installArchivedPlaceholder).
    _acw_c0=$(_ms)
    if { [ "$mode" = ondemand ] || [ "$mode" = auto ]; } && [ -d "$META_SRC/$pkg" ]; then   # #130: auto raises a placeholder -> needs _meta
      cp -r "$META_SRC/$pkg" "$d/_meta" 2>>"$LOG"
      if [ -d "$d/_meta" ]; then
        stage_keep_mtimes "$META_SRC/$pkg" "$d/_meta"
        [ -n "$_acw_src" ] || _acw_src="$META_SRC/$pkg"   # no APK staged (the dormant shape): the _meta source
      fi
    fi
    # NWP-20261123-02: the package dir's mtime, from the dir of its first staged APK (or the live code dir, or the
    # _meta source). This must stay the LAST write into $d: any later create or remove in it gives it a new mtime,
    # and the agent's groupCacheKey hashes it. A dir with no source (nothing staged in it: an on-demand line naming no
    # APK and with no _meta) still rides the stage, so it gets a FIXED mtime, 2000-01-01 00:00:00 UTC, the same at
    # every seal; a fresh one would miss its group at every seal.
    if [ -n "$_acw_src" ]; then touch -r "$_acw_src" "$d" 2>>"$LOG" || _acw_tf=$((_acw_tf+1)); fi
    [ -n "$_acw_src" ] || TZ=UTC0 touch -t 200001010000.00 "$d" 2>>"$LOG" || _acw_tf=$((_acw_tf+1))
    _acw_cms=$((_acw_cms + $(_ms) - _acw_c0))
    _acw_s0=$(_ms)
    printf '%s%s%s\n' "$meta" "$names" "${grp:+$_acw_tab$grp}" >> "$MAN"
    _acw_sms=$((_acw_sms + $(_ms) - _acw_s0))
    n=$((n+1))
  done < "$AL"
  # DIA-20260805-09: sweep the KEEP-SET for installed-mode apps the code list does not mention at all. This is
  # the recovery half: the list is written only by captureAppCode at logoff, and it needs the app INSTALLED to
  # read ai.sourceDir -- so an app that failed to restore once is silently dropped from the list, and every
  # later logoff drops it again because it is still not installed. Device-proven on lynx 2026-08-05: keep-set
  # held 4 apps, the list held 1. Resolving from live state re-seals whatever IS on the phone, which is what
  # breaks the loop. #124: on-demand/auto entries are NO LONGER skipped outright -- they are staged whenever
  # their APK is actually on the phone, and skipped only when it is not (a dormant placeholder, where
  # carry-forward is the right mechanism). See the branch below for why the old blanket skip lost a 214 MB app.
  want_installed=0
  if [ -s "$AK" ]; then
    while IFS= read -r kline; do
      [ -n "$kline" ] || continue
      kpkg=$(printf '%s' "$kline" | cut -f1); [ -n "$kpkg" ] || continue
      case "$kpkg" in group:*|\#*) continue ;; esac
      _stg_i=$((_stg_i+1)); [ "$_stg_i" -le "$_stg_n" ] || _stg_n=$_stg_i; _apps_stage_prog "$_stg_i" "$_stg_n"
      # NWP-20261128-38: before kmode and want_installed++, so a line that is not a package never counts as a wanted installed app.
      pkgname_ok "$kpkg" || { echo "[roamd] appcode: keep-set line skipped -- not a package name $(date)" >> "$LOG"; continue; }
      kmode=$(printf '%s' "$kline" | cut -f2)
      [ "$kmode" = "$kpkg" ] && kmode=installed   # no tab in the line -> cut echoes it whole; mode defaults to installed
      [ -n "$kmode" ] || kmode=installed
      # #124 (Chester, lynx 2026-08-15): ondemand/auto used to be skipped OUTRIGHT here, on the stated grounds
      # that "deferred bytes + carry-forward already cover them" and that "a dormant placeholder has no local
      # APK to find anyway". Both hold AFTER a roam. NEITHER holds in the session the app was INSTALLED: its
      # real APK is sitting on the phone, and there is no prior head to carry anything forward FROM. So a
      # freshly installed app set to on-demand fell through every path -- no code-list line (captureAppCode
      # runs only at logoff), skipped here, nothing to carry -- and #apps committed EMPTY while logging
      # "sealed (0 pkg)" as a success. Worse, the `continue` fired BEFORE want_installed++, so the guard below
      # ("staged 0 -> keep the previous head") could not see the loss either.
      #
      # MEASURED ON DEVICE: a 214 MB game installed and set to on-demand, 0 bytes of it in the store for the
      # whole session, across seven consecutive periodic seals. A power-off in that window loses the app, and
      # the on-demand toggle is precisely the control that promised it would roam.
      #
      # So skip only the case the skip was WRITTEN for -- a dormant placeholder with no local APK -- and stage
      # the bytes whenever they are actually here. They are staged DEFERRED, exactly like every other
      # on-demand APK, so the login-restore shape is unchanged; the only thing that changes is how soon the
      # store gets a copy.
      case "$kmode" in
        ondemand|auto)
          case "$seen" in *" $kpkg "*) continue ;; esac   # the code list already covered it
          _acw_t0=$(_ms); kdir=$(live_code_dir "$kpkg"); _acw_lms=$((_acw_lms + $(_ms) - _acw_t0)); _acw_lct=$((_acw_lct+1))
          [ -n "$kdir" ] || continue                      # dormant placeholder -> carry-forward, exactly as before
          kd="$STAGE/$kpkg"; mkdir -p "$kd" 2>>"$LOG" || continue
          _acw_c0=$(_ms)
          knames=$(stage_live_apks "$kdir" "$kd") || _acw_left=$((_acw_left+1))
          _acw_cms=$((_acw_cms + $(_ms) - _acw_c0))
          [ -n "$knames" ] || { rmdir "$kd" 2>/dev/null; continue; }
          # #124 PART 2 -- DEVICE-PROVEN 2026-08-15, and the first cut of this fix got it WRONG.
          #
          # A DEFERRED line is only restorable if the archived-placeholder metadata rides with it:
          # installRoamedAppCode raises the app from .appcode/<pkg>/_meta and, having already added it to
          # `od`, SKIPS install-existing for it (provisionRoamedApps in ChooserActivity.java skips
          # every package installRoamedAppCode returns). The chooser captures that
          # metadata when it ARCHIVES the app, which happens at LOGOFF -- so an app installed THIS session
          # has none yet. Sealing it deferred regardless produced exactly what Chester measured: 252 MB
          # safely in the store, surviving a power-off, and the app MISSING afterwards, because login had
          # nothing to raise it from AND had excluded it from the normal install path.
          #
          # So seal deferred ONLY when the placeholder exists. Without it, seal INSTALLED: essential bytes
          # that restore the app WHOLE at login. Slower login, correct data, app actually present -- and the
          # user's on-demand choice takes effect at the next logoff, when the chooser archives it properly
          # and captures the metadata. That is the same safe fallback an OLD build already makes when it
          # meets an `auto` line it does not understand ("slower login, correct data").
          _acw_c0=$(_ms)
          if [ -d "$META_SRC/$kpkg" ]; then
            cp -r "$META_SRC/$kpkg" "$kd/_meta" 2>>"$LOG"
            [ ! -d "$kd/_meta" ] || stage_keep_mtimes "$META_SRC/$kpkg" "$kd/_meta"
            kmode_out="$kmode"
            # knames is a TAB-prefixed list of basenames; word-splitting it is safe.
            _acw_cms=$((_acw_cms + $(_ms) - _acw_c0)); _acw_s0=$(_ms)
            for kbn in $knames; do printf '%s/%s\n' "$kpkg" "$kbn" >> "$DEFER"; done
            _acw_sms=$((_acw_sms + $(_ms) - _acw_s0)); _acw_c0=$(_ms)
          else
            kmode_out=installed
            echo "[roamd] appcode $kpkg ($kmode) has no placeholder metadata yet -> sealing ESSENTIAL as installed so it restores WHOLE (#124) $(date)" >> "$LOG"
          fi
          # NWP-20261123-02: the LAST write into $kd: its live code dir's mtime (see the code-list loop's dir touch).
          touch -r "$kdir" "$kd" 2>>"$LOG" || _acw_tf=$((_acw_tf+1))
          _acw_cms=$((_acw_cms + $(_ms) - _acw_c0))
          _acw_s0=$(_ms)
          printf '%s\t0\t0\t%s%s\n' "$kpkg" "$kmode_out" "$knames" >> "$MAN"
          _acw_sms=$((_acw_sms + $(_ms) - _acw_s0))
          n=$((n+1)); staged=$((staged+1)); seen="$seen$kpkg "
          echo "[roamd] appcode recovered $kpkg ($kmode -> sealed $kmode_out) from the keep-set -> $kdir (installed this session, absent from the code list) $(date)" >> "$LOG"
          continue
          ;;
      esac
      want_installed=$((want_installed+1))
      case "$seen" in *" $kpkg "*) continue ;; esac
      _acw_t0=$(_ms); kdir=$(live_code_dir "$kpkg"); _acw_lms=$((_acw_lms + $(_ms) - _acw_t0)); _acw_lct=$((_acw_lct+1))
      [ -n "$kdir" ] || continue
      kd="$STAGE/$kpkg"; mkdir -p "$kd" 2>>"$LOG" || continue
      _acw_c0=$(_ms)
      knames=$(stage_live_apks "$kdir" "$kd") || _acw_left=$((_acw_left+1))
      [ -n "$knames" ] || { rmdir "$kd" 2>/dev/null; _acw_cms=$((_acw_cms + $(_ms) - _acw_c0)); continue; }
      # NWP-20261123-02: the LAST write into $kd: its live code dir's mtime (see the code-list loop's dir touch).
      touch -r "$kdir" "$kd" 2>>"$LOG" || _acw_tf=$((_acw_tf+1))
      _acw_cms=$((_acw_cms + $(_ms) - _acw_c0))
      # cols 2/3 (versionCode, sideloaded) are not read by the restore side -- it consumes pkg, mode and the
      # apk basenames -- so 0/0 is safe for a synthesized line.
      _acw_s0=$(_ms)
      printf '%s\t0\t0\tinstalled%s\n' "$kpkg" "$knames" >> "$MAN"
      _acw_sms=$((_acw_sms + $(_ms) - _acw_s0))
      n=$((n+1)); staged=$((staged+1)); seen="$seen$kpkg "
      echo "[roamd] appcode recovered $kpkg from the keep-set -> $kdir (absent from the code list) $(date)" >> "$LOG"
    done < "$AK"
  fi
  appcode_stage_play_dormant "$seen" "$APPOFF" "$CODEKEEP" "$AK"
  [ "$_acw_left" -eq 0 ] || print -r -- "[roamd] OUT $(qn "$name") #apps: $_acw_left package(s) whose APK set did not copy whole were left out of this stage -- their stored code is kept (NWP-20261108-04)" >> "$LOG"
  # NWP-20261119-02: what the code list's stale paths became. Counts only: roam.log outlives every wipe.
  _st_n=$((_st_s + _st_c + _st_k))
  [ "$_st_n" -eq 0 ] || print -r -- "[roamd] OUT $(qn "$name") #apps: $_st_s staged from live code dirs, $_st_c carried (stale list paths), $_st_k carried (meta version differs) (NWP-20261119-02)" >> "$LOG"
  # NWP-20261123-02: count stage_live_apks's failed touches and remove their file, so neither du nor the push sees it.
  if [ -f "$SLA_TF" ]; then
    while IFS= read -r _acw_l; do _acw_tf=$((_acw_tf+1)); done < "$SLA_TF"
    rm -f "$SLA_TF"
  fi
  SLA_TF=""
  if [ -f "$SAC_RF" ]; then
    while IFS= read -r _acw_l; do _acw_ru=$((_acw_ru+1)); done < "$SAC_RF"
    rm -f "$SAC_RF"
  fi
  SAC_RF=""
  # NWP-20261005-04: what staging cost. Before this line nothing measured it, which is why a logoff that timed
  # out here could only be inferred, not shown. Counts and sizes only: no profile name, no package name.
  # NWP-20261123-02: "copy <c>ms" is the part spent copying (cp, size check, touch). "<f> mtime kept-failed" counts the
  # touches that failed (each one costs a cache miss only).
  # NWP-20261128-09: "<r> reused" counts the APKs moved from the previous seal's stage instead of copied (a count only).
  # NWP-20261130-16: the rest of the total, named: "lookups <ms>ms/<n>" (the snapshot and <n> live_code_dir/live_code_ver
  # calls), "carry" (the stale-path branch less its lookup, copy and list writes), "lists" (the drop, manifest, defer and
  # dormant list writes), "other" (the remainder: the parse, progress lines, du), so copy + the four parts = the total.
  # Every return below this point comes after the snapshot's removal, and no return comes between it and its creation.
  [ -z "${PM_SNAP:-}" ] || rm -f "$PM_SNAP"; PM_SNAP=""
  _stg_kib=$(du -sk "$STAGE" 2>/dev/null | cut -f1)
  _stg_ms=$(( $(_ms) - _stg_t0 ))
  _stg_oth=$(( _stg_ms - _acw_cms - _acw_lms - _acw_kms - _acw_sms ))
  echo "[roamd] #apps staged $staged pkg(s), $_stg_kib KiB, in ${_stg_ms}ms (copy ${_acw_cms}ms, $_acw_tf mtime kept-failed, $_acw_ru reused) (NWP-20261005-04, NWP-20261123-02, NWP-20261128-09) (lookups ${_acw_lms}ms/$_acw_lct, carry ${_acw_kms}ms, lists ${_acw_sms}ms, other ${_stg_oth}ms) $(date)" >> "$LOG"
  # NWP-20261123-10: on a full /data a zero-byte create succeeds and every append to the manifest fails (ENOSPC),
  # unchecked. A stage that staged packages but holds an empty manifest would seal APKs no sign-in installs: the
  # same refusal as above, with the staged-0 refusal's cleanup (the defer list holds package names by now). The
  # empty stage of NWP-20261025-04 (staged 0) still seals.
  [ "$staged" -eq 0 ] || [ -s "$MAN" ] || { print -r -- "[roamd] OUT $(qn "$name") #apps staged $staged pkg(s) but the stage's manifest took no line -- NOT SEALED $(date)" >> "$LOG"; rm -rf "$STAGE" "$POOL" "$DORMANT"; rm -f "$DEFER"; rm -f "$DROPFILTER" "$DROPOFF" "$DROPGONE" 2>/dev/null; return 1; }
  # DIA-20260805-09: never COMMIT a head that would drop code. If nothing staged while the keep-set still wants
  # installed-mode apps, the local state is broken (dead paths, apps not restored), and pushing would un-lease
  # the code the PREVIOUS head still holds -- irrecoverably, since re-capture needs the app installed. Keep the
  # good head; the next seal that stages something commits normally. ⚠ An EMPTY keep-set FILE does get this far
  # (NWP-20261025-04): want_installed is 0, so the refusal below does not fire and an empty stage is sealed; the
  # agent's shrink and presence guards decide it. Only an ABSENT keep-set returns at the top.
  if [ "$staged" -eq 0 ] && [ "$want_installed" -gt 0 ]; then
    print -r -- "[roamd] OUT $(qn "$name") #apps SKIPPED: staged 0 apk for $want_installed installed-mode app(s) -- keeping the previous head $(date)" >> "$LOG"
    rm -rf "$STAGE" "$POOL" "$DORMANT"; rm -f "$DEFER"
    rm -f "$DROPFILTER" "$DROPOFF" "$DROPGONE" 2>/dev/null
    # DIA-20260812-10 (#118): this is a REFUSAL in exactly the agent's sense -- "the local state is broken, so
    # keep the good head" -- and it is the #apps analogue of the shrink guard. It returned 0, so the one scope
    # whose loss users describe as "all my apps are gone" reported the refusal as a successful seal.
    return 4
  fi
  # #200: INSTALLED app code must ride the login restore whole (a deferred installed APK restores as a mediad
  # stub -> uninstallable). The media heuristic stays OFF (NOWHERE_ONDEMAND_MEDIA=0); ON-DEMAND APKs defer ONLY
  # via the explicit .defer list (NOWHERE_DEFER_LIST), independent of the media tiering. An empty list (no
  # on-demand apps) => a clean all-essential seal, byte-identical to the #200 behavior.
  [ -s "$DEFER" ] || { rm -f "$DEFER"; DEFER=""; }
  # #204: NOWHERE_CARRY_DEFERRED=1 makes the push carry forward a prior head's deferred entries the walk didn't
  # see -- an on-demand app that is now an ARCHIVED placeholder locally has no APK to stage, so its deferred bytes
  # must be carried (not dropped) or a later tap can't materialise them. Independent of the media flag (which
  # stays off so INSTALLED apps ride the login restore whole).
  # appcode_seal is a BEST-EFFORT step ("never sets rc") that runs on the LOGOFF critical path (the `out` op waits
  # for it before signalling seal-OK to the daemon). A HANG here therefore wedges the whole logoff -> the daemon's
  # 22-minute anti-wedge watchdog reboots the phone (device-observed on lynx 2026-07-26: the #apps push stalled at a
  # logoff that raced a periodic seal, no seal-OK, reboot). The DATA seal (vault/#de/#media) already succeeded above,
  # so this must never block it. Bound the push with `timeout` (SIGTERM at 120s, SIGKILL 5s later): a normal push is
  # ~2s, so this never false-fires, but a stall now yields ret!=0 -> best-effort miss (the last periodic seal's #apps
  # head + carry-forward cover it) instead of a reboot. A killed push leaves the store ref un-updated (the gen commit
  # is the last step), so the previous #apps head stays intact -- no partial/corrupt seal.
  # #DIA-20260802: the "~2s push" assumption breaks for a LARGE app -- sandboxed Play Services' code alone is ~249
  # chunks / 100s of MB, which does NOT upload in 120s on a normal uplink, so `timeout` KILLS it (rc=124), the gen
  # never commits, and the NEXT roam restores #apps EMPTY (device-proven on lynx: gms roamed back with no code, so no
  # account). The push is content-addressed + RESUMABLE: a killed attempt's chunks still land, so a retry net-skips
  # them (device-proven 190/249 skipped on try 2) and converges. Retry a few BOUNDED attempts instead of one long
  # timeout that would wedge logoff: each attempt is short, the total stays well under the 22-min anti-wedge watchdog,
  # and dedup makes 2-3 tries enough. Once sealed, later seals dedup (fast), so this only stretches a first-time big seal.
  # DIA-20260811-05: the retry premise above is right about the UPLOAD and wrong about the PER-ATTEMPT FIXED COST, and
  # a fixed bound cannot serve both a small profile and a large one. Device-proven on lynx 2026-08-11 (odtest4, 331
  # chunks): try 5 net-skipped 326 of the 331 chunks -- dedup did exactly what the comment above promises, leaving only
  # 5 to upload -- and STILL took 2m27.152s against the 150s bound, dying ~3s short of the gen commit. The walk/stat/
  # manifest pass is O(profile) and does NOT dedup, so it grows as a profile ages; once it alone crosses the bound,
  # every attempt fails at the same point with the SAME gen (3ca550647cb2 on all five here). That is not a retry, it is
  # the same doomed attempt five times: 5 x 150s = a 12.5-minute logoff that ends UNSEALED with the app code not
  # carried. The next login restored a 2-chunk head and Play/GMS/YouTube were simply gone from the session.
  # So ESCALATE the bound instead of repeating it. Try 1 stays at 150s, so a small profile logs off as fast as it does
  # today and this costs nothing in the common case; a large profile gets room to actually finish. Worst case is
  # 150+300+600 = 17.5 min, still inside the daemon's 22-min anti-wedge watchdog
  # (handleLogout's #86 Fix C in the agent's main.go) with margin -- and the
  # old 5x150 spent 12.5 of those minutes to guarantee failure. Three attempts, not five: since dedup makes each retry
  # cheaper only in upload and the fixed cost is what binds, a 4th attempt at the same bound adds cost, not odds.
  # `lim` is local because the roam data-loss saga was caused by roamd helpers leaking loop/temp vars into the global
  # scope. ret/try are pre-existing globals here and are left alone deliberately -- rescoping them is a behaviour change
  # that does not belong in this fix.
  # DIA-20260812-05: the bound is a BACKSTOP now, not a stopwatch. The escalating 150/300/600 ladder killed
  # HEALTHY uploads: on lynx 2026-08-12 a first seal of three on-demand packages was cut off at 150s mid-flight
  # ("push try 1 rc=124") and only landed on the 300s retry, ~6 minutes in total. Nothing was wrong with it --
  # it was simply a large upload, and a wall-clock timer cannot tell that from a hang.
  #
  # The right question is "is anything still happening?", and it is ALREADY ASKED, one level up: the daemon's
  # triggerRoamWorker (main.go, DIA-20260811-06/#86) polls roam.progress -- which the agent writes PER CHUNK --
  # and gives up only after 150s with NO NEW PROGRESS, with a 60-minute absolute ceiling. That is a genuine
  # stall detector and it already covers this whole run. #86's own comment makes the argument against what
  # this line used to do: "hardCap only ever fires on work that IS progressing, i.e. it can only truncate
  # honest work". The ladder was that mistake, one level down.
  #
  # So: one generous bound that only a truly wedged process can reach, and the retries stay for genuine
  # failures (a dropped connection, a lease error) rather than for self-inflicted timeouts. Exit 7 is the one exit
  # that ends the ladder at once (NWP-20261128-25): a sign-out's stop (h47 #1) is a request, not a failure.
  # Raising 150 to 600 was rejected as the fix -- it only moves the cliff, and a 700 MB first seal would walk off
  # that one too.
  # The bound is kept at all because roamd is a su:s0 init service and an unbounded hang here is worse than a
  # late kill; it is not kept as a performance limit.
  local lim _dmt
  # NWP-20261128-01: the dormant dir goes to the agent only when it holds a line; empty is the agent's "unset".
  _dmt=""; [ -s "$DORMANT/manifest.tsv" ] && _dmt="$DORMANT"
  _apt0=$(_ms)   # NWP-20261123-06: the push ladder's wall time -> APPCODE_PUSH_MS, #apps' push in the seal split
  ret=124; try=0
  for lim in 3600 3600 3600; do
    if [ "$ret" = 0 ]; then break; fi
    try=$((try + 1))
    # DIA-20260804-10: the drop list IS load-bearing HERE, passed inline like NOWHERE_DEFER_LIST rather than
    # inherited. The #apps stage is a tree of <pkg>/ dirs, and NOWHERE_CARRY_DEFERRED=1 above re-emits the
    # PREVIOUS head's deferred entries for any package the walk did not see -- which is exactly how a dormant
    # on-demand app keeps its code across roams. A switched-off app is never staged, so without the drop list
    # its APK bytes are carried forward by that rule FOREVER: still referenced, still billed, for an app that
    # will never be reinstalled. DIA-20260804-08 scoped these vars off the whole tail of the `out` op to keep
    # them away from acct_seal, which silently took this with it.
    # NWP-20261023-07: NOWHERE_GONE_LIST (the uninstall subset that may mint a tombstone) rides here only.
    NOWHERE_ONDEMAND_MEDIA=0 NOWHERE_CARRY_DEFERRED=1 NOWHERE_DEFER_LIST="$DEFER" \
      NOWHERE_CARRY_ESSENTIAL="$NOWHERE_CARRY_ESSENTIAL" NOWHERE_CARRY_ESSENTIAL_MEDIA=0 \
      NOWHERE_DROP_LIST="$APPDROP_CODE" NOWHERE_GONE_LIST="$APPGONE_CODE" NOWHERE_KEEP_LIST="$APPKEEP" \
      NOWHERE_APPS_DORMANT="$_dmt" \
      NOWHERE_PUSH_STAT="$STATE/pushstat.apps" \
      timeout -k 5 "$lim" "$AGENT" push s3 "${name}#apps" "$(pw "$pass")" "$STAGE" >> "$LOG" 2>&1; ret=$?
    [ "$ret" = 0 ] || print -r -- "[roamd] OUT $(qn "$name") #apps push try $try rc=$ret (${lim}s bound, resumable retry) $(date)" >> "$LOG"
    # h47 #1 (NWP-20261128-25): a stop asks the seal to end and .sealstop stays until the sign-out's own out op, so a retry can only stop again.
    [ "$ret" = 7 ] && break
  done
  APPCODE_PUSH_MS=$(( $(_ms) - _apt0 )); unset _apt0
  # NWP-20261128-09: a periodic or manual seal keeps its stage as the next seal's pool (stage_apk_copy), with this uid in
  # .uid, whatever the push did: the pool is a cache keyed by size and mtime and claims nothing about the store. A
  # sign-out's seal removes both: the pool holds package names and APK bytes, and must not outlive the session.
  case "${skind:-}" in
    logoff|logoff-pinned) rm -rf "$STAGE" "$POOL" ;;
    *) rm -rf "$POOL"
       case "$uid" in
         ''|*[!0-9]*) rm -rf "$STAGE" ;;
         *) if mv "$STAGE" "$POOL" 2>>"$LOG"; then
              ( printf '%s\n' "$uid" > "$POOL/.uid" ) 2>>"$LOG" || rm -rf "$POOL"
            else rm -rf "$STAGE" "$POOL"; fi ;;
       esac ;;
  esac
  rm -f /data/nowhere/appcode-defer /data/nowhere/appcode-dropfilter /data/nowhere/appcode-dropoff /data/nowhere/appcode-dropgone
  rm -rf "$DORMANT"   # NWP-20261128-01: after a landed or a failed push
  if [ "$ret" = 0 ]; then
    print -r -- "[roamd] OUT $(qn "$name") #apps sealed ($n pkg) $(date)" >> "$LOG"
  elif [ "$ret" = 7 ]; then
    # h47 #1 (NWP-20261128-25): a stop is not a loss -- the sign-out's own out op seals #apps a moment later.
    print -r -- "[roamd] OUT $(qn "$name") #apps push stopped for a sign-out (rc=7) -- no head published, the sign-out's own seal saves this session's app code (h47 #1) $(date)" >> "$LOG"
  else
    # DIA-20260811-05: say what actually happened. "push rc=124" reads like a transient blip, but this line means the
    # gen never committed, the head still points at the PREVIOUS seal, and every app kept since that seal will be
    # MISSING after the next login -- which is exactly how odtest4 came back without Play/GMS/YouTube on 2026-08-11
    # while the log looked merely noisy. $try attempts is the tell for a profile that has outgrown even the 600s bound.
    print -r -- "[roamd] OUT $(qn "$name") #apps push rc=$ret after $try attempts -- NOT SEALED, head unchanged, app code from this session is NOT carried $(date)" >> "$LOG"
  fi
  # #DIA-20260726-08: the on-demand archived-record REAP (clearing the retained placeholder record so the NEXT
  # login's installArchivedPlaceholder doesn't collide into a label-less ghost) is NOT done here anymore. Doing it
  # on the logoff path was fragile two ways: (1) it raced the concurrent user teardown / a periodic seal, and (2) if
  # the logoff was INTERRUPTED before it ran (the 22-min watchdog reboot on 2026-07-26 is exactly this), the record
  # leaked and the next login collided anyway. It now runs at ROAM-IN (`in` op, reap_stale_ondemand, after
  # hold_ondemand + before the chooser raises placeholders) -- idempotent + self-healing regardless of how the last
  # logoff ended, and off the logoff critical path entirely. See reap_stale_ondemand.
  # DIA-20260812-10 (#118): return the PUSH's outcome. This used to be a hard 0 under the banner "never fails
  # the data seal" -- but that phrase describes what the CALLER should do with the verdict, not a reason to
  # destroy the verdict. The caller still does not fail the data seal on it; it now reports it. Without this,
  # the loud "NOT SEALED, head unchanged" line above was the ONLY trace that app code was lost.
  return "$ret"
}

# NWP-20261104-05 (#743, dn-1025 #2): the facts the #sys account guard needs before it can let a DELIBERATE Google
# sign-out seal. These choices are fixed here; the guard honouring a mark (acct_seal) and the chooser's "Sign out
# of Google" row rely on them:
#   MARK HASH -- lowercase hex SHA-256 of the bytes `nowhere-acct-mark-v1:` followed by the account name.
#     com.google accounts only. A mark is never the name.
#   MARK FILE -- acct_mark_file <uid>: ${ACCT_MARK_ROOT:-/data/user}/<uid>/com.nowhere.chooser/files/nowhere-acct-marks,
#     one hash per line: the chooser's own per-user file, so it seals with the profile like nowhere-appkeep and is
#     never a cleartext file outside the seal, as $STATE/.had_account is. Never user 0; never sent to the gateway.
#   A MARK NEVER OUTLIVES ITS SESSION -- acct_restore deletes the file at every stored sign-in, BEFORE its agent
#     restore, so the void happens whether or not a #sys head exists or restores. Voiding only where a CE db is
#     placed would miss a sign-in whose #sys restore failed, and a mark restored from an older session could then
#     let a later #732 destruction seal once that account is signed in again.
#   ARRIVAL RECORD -- /data/system_ce/<uid>/nowhere-acct-arrival (root, 0600), written by acct_reload at placement:
#     line 1 the total row count of `accounts` (every type), then one mark hash per com.google row, `?` for a name
#     nowhere_db_fix would not print. In the user's CE storage, NOT on the tmpfs: a cold lock evicts it with the CE
#     key, the reap's rm of /data/system_ce/<uid> removes it, and #sys never stages it (only accounts_*.db*). A hash
#     list under $STATE would survive a cold lock in the clear. No file = which accounts arrived is unknown, and the
#     guard then behaves as it did before this record existed. $STATE/.had_account is unchanged: an empty flag.
# An account name lives only in a pipe or in roamd's own memory: never in a log line, a file or an argv. mksh's
# `print` is a builtin; `printf` is /system/bin/printf on Android, so what it prints sits in a world-readable argv
# (DIA-20260812-02). Hence `print -rn --` below, and never printf or echo with a name in its arguments.
acct_mark_file() {
  local _u="$1"
  case "$_u" in ''|0|*[!0-9]*) return 1 ;; esac
  print -r -- "${ACCT_MARK_ROOT:-/data/user}/$_u/com.nowhere.chooser/files/nowhere-acct-marks"
}

# acct_mark_hashes: account names on stdin, one per line -> their mark hashes on stdout, one per line. `?` (the
# stand-in nowhere_db_fix prints for a name it will not print) and an empty line come out as `?`.
acct_mark_hashes() {
  local _n
  while IFS= read -r _n; do
    case "$_n" in
      ''|'?') print -r -- '?' ;;
      *) print -rn -- "nowhere-acct-mark-v1:$_n" | sha256sum | cut -d' ' -f1 ;;
    esac
  done
}

# ---------------------------------------------------------------------------------------------------------
# #DIA-20260802-02: roam the AccountManager ACCOUNT ROWS so a signed-in account (e.g. sandboxed Play's Google
# account) survives the roam. They live in /data/system_ce/<uid>/accounts_ce.db (+ /data/system_de/<uid>/
# accounts_de.db) -- a scope the CE (/data/user), #de and #media restores do NOT cover, so the account list roamed
# back EMPTY (device-proven on lynx: Accounts: 0 even after gms + its app data restored; zero `system_ce` in
# roam.log). Seal the two dbs under a name#sys sibling scope and restore them into the fresh user. NB the auth
# tokens inside are keystore-wrapped, so a restored account still needs the keystore-key roam (below) to be USABLE
# -- but the account ROW must roam first. All vars `local` (roamd helpers must never clobber the global name/uid,
# per the #72/#78 saga); reads global $name/$pass (the profile identity) but never assigns them.
# The user is still RUNNING at the `out` seal, so snapshot each db with sqlite3 `.backup` (a consistent online
# copy -- no torn WAL) rather than a raw file cp.
acct_seal() {
  local uid="$1" stage="/data/nowhere/acct-stage" r _wf _wsrc _wgot
  local _stg="" _stgl _stgc _sh _arr _mf _t _case _h _i _hn _keep _kn _dn _mks _nl='
'
  # DIA-20260804-10: REFUSE while a restored account is still PENDING PLACEMENT. This is the guard that
  # actually matters, and the size check below does NOT cover it.
  #
  # acct_restore lands the sealed dbs in acct-hold-<uid> and acct_reload places them -- but on the
  # sandboxed-Play path that placement is DEFERRED until the user taps a Play app (acct-deferred-<uid>).
  # Until then /data/system_ce/<uid>/accounts_ce.db is AMS's OWN db, created row-empty at unlock. It exists
  # and is non-zero, so `-s` happily passes it, and this function would seal an account-LESS db over a head
  # that holds the real account.
  #
  # And this is not a logoff-only hazard: acct_seal runs inside the `out` op, which syncLoop drives every
  # syncIntervalDefault=120s. So a session where the user simply never taps a Play app destroys the sealed
  # account within two minutes of logging in, silently, and every later roam starts signed out. That matches
  # what was observed on lynx/odtest27.
  #
  # Same shape as the restore-receipt rule the data seal already uses: no proof this session holds the real
  # thing -> do not overwrite the copy that does. The previous head stays, and the next seal after a real
  # placement supersedes it normally.
  if [ -e "/data/nowhere/acct-deferred-$uid" ] || [ -d "/data/nowhere/acct-hold-$uid" ]; then
    print -r -- "[roamd] OUT $(qn "$name") #sys accounts PENDING-PLACEMENT -- the restored account has not been placed yet for user $uid (hold/deferred still present), so the live CE db is AMS's row-empty one and sealing it would destroy the account head. This is NORMAL after a login and clears itself once acct_reload runs; nothing is lost and no action is needed. $(date)" >> "$LOG"
    # DIA-20260812-10 (#118) made this 4 -- the same code the agent uses for a guard refusal -- so one
    # vocabulary covered both layers. That was right about the vocabulary and wrong about the word: this is
    # not a REFUSAL in the sense the other 4s mean. A guard refusal says "the data offered was bad and the
    # stored copy was protected"; this says "the account has not landed YET, ask again in 120s". It clears
    # itself with no intervention, loses nothing, and needs no reader's attention.
    #
    # DIA-20260816-16 (#63): 5 -> `pending-placement`. Sharing 4 meant a normal post-login window rendered as
    # `sys=refused`, indistinguishable from the media/vault refusals that DO mean something was wrong, and it
    # dominated the counts: 52 of the 105 partial seals measured on lynx were this.
    # NWP-20261014-67: 6, not 5 -- the agent's push exits 5 when the store is unreachable (see _cause).
    return 6
  fi
  rm -rf "$stage"; mkdir -p "$stage/ce" "$stage/de" 2>>"$LOG"
  # DIA-20260802-03: copy the db + WAL sidecar READ-ONLY. Do NOT open the live db with sqlite3 -- a `.backup` of an
  # ACTIVELY-WRITTEN db (AMS is tearing the user down at logoff) LIVELOCKS: the online backup restarts on every
  # writer commit and never finishes, which hung this seal for 22m and tripped the daemon's anti-wedge watchdog
  # REBOOT (device-observed on lynx). A plain cp is a bounded read that can NOT hang; SQLite recovers from the copied
  # db+wal on restore. cp errors on a missing -wal (non-WAL mode) are harmless -- the db itself still copies.
  cp -a "/data/system_ce/$uid/accounts_ce.db" "/data/system_ce/$uid/accounts_ce.db-wal" "$stage/ce/" 2>>"$LOG"
  cp -a "/data/system_de/$uid/accounts_de.db" "/data/system_de/$uid/accounts_de.db-wal" "$stage/de/" 2>>"$LOG"
  # NWP-20261118-03: the CE copy must be WHOLE (NWP-20261108-04's rule for a staged copy). The `-s` guard
  # below refuses only an EMPTY db. A cp cut short (ENOSPC on /data, CE storage going away at teardown)
  # leaves a NON-EMPTY short db or -wal that passes `-s`. The #743 count cannot read a torn db and fails open,
  # and SQLite silently drops a torn WAL tail, so the copy opens without its last commit -- maybe the account
  # row. So each CE file that exists at the source must be staged at the source's byte size. A missing source
  # is not checked: no -wal is non-WAL mode, and a missing db is the `-s` guard's case. A source that grew
  # after the copy refuses too; the next seal retries.
  for _wf in accounts_ce.db accounts_ce.db-wal; do
    [ -e "/data/system_ce/$uid/$_wf" ] || continue
    _wsrc=$(stat -c %s "/data/system_ce/$uid/$_wf" 2>/dev/null)
    _wgot=$(stat -c %s "$stage/ce/$_wf" 2>/dev/null) || _wgot=0
    if [ ! -f "$stage/ce/$_wf" ] || [ "$_wgot" != "$_wsrc" ]; then
      print -r -- "[roamd] OUT $(qn "$name") #sys accounts REFUSED -- $_wf copied short (${_wgot}B of ${_wsrc}B); keeping the previous head $(date)" >> "$LOG"
      rm -rf "$stage"
      return 4   # a refusal, in the shared vocabulary (_cause -> refused)
    fi
  done
  # DIA-20260804-08: REFUSE to seal without the CE half. The account ROW lives in accounts_ce.db; accounts_de.db
  # is only metadata. Both copies above are unchecked `cp`s, and at logoff this user is being torn down with its
  # CREDENTIAL-ENCRYPTED storage going away underneath us -- so the CE copy can fail silently while the DE one
  # succeeds. Pushing that pair replaced a GOOD head with a DE-only one; the next login then restored metadata
  # with no account, acct_reload placed exactly the half that does not matter, and the profile came back signed
  # out of every Google app with rc=0 in every log. Device-proven on lynx/odtest27 2026-08-04: user 12 had
  # accounts_de.db replaced at 16:38 while accounts_ce.db still held AMS's empty 16:30 db, dumpsys account
  # reported Accounts: 0, and YouTube + Play Store were both signed out.
  #
  # Same rule the data seal already enforces via sealBlind: a short capture must NOT overwrite a good head.
  # Keeping the previous head is always the safe direction -- it is a real backup of a real account, whereas
  # this stage demonstrably is not. A profile that genuinely has no accounts still seals fine: AMS creates
  # accounts_ce.db at unlock, so it EXISTS and is merely row-empty, and removing an account seals normally.
  if [ ! -s "$stage/ce/accounts_ce.db" ]; then
    print -r -- "[roamd] OUT $(qn "$name") #sys accounts REFUSED -- accounts_ce.db missing/empty in the stage (CE locked at teardown?); keeping the previous head rather than sealing metadata with no account $(date)" >> "$LOG"
    rm -rf "$stage"
    return 4   # DIA-20260812-10 (#118): a refusal, in the shared vocabulary
  fi
  # DIA-20260818-15 (#743): the check above tests BYTE SIZE, which cannot see the case the comment above
  # describes. SQLite never shrinks on row delete -- measured on lynx, 12288 bytes with one account and 12288
  # with none -- so a db whose account row was DESTROYED passes `-s` and seals straight over a good head. That
  # is what turned #732 from one bad session into an unrecoverable one (roam.log 2026-08-18: #sys head
  # 21170B -> 21173B, rc=0, twelve minutes after validateAccountsInternal deleted the row).
  #
  # So ask for rows, not bytes. Via nowhere_db_fix because `sqlite3` does NOT exist on a `user` build -- the
  # exact trap that caused #732 in the first place.
  #
  # Refuse only on the TRANSITION: this profile arrived WITH an account (.had_account, written at placement)
  # and is leaving with none. A profile that never had one still seals its row-empty db exactly as before, which
  # the comment above is right to require.
  #
  # ⚠ THE RULE (NWP-20261104-06, decided 2026-10-20, dn-1025 #2): a removal made through Nowhere's OWN Sign out
  # seals; any other removal still refuses and the account comes back. The chooser writes the account's mark
  # BEFORE it removes the account (see the choices above acct_mark_file), so a mark in the marks file is the proof
  # that the user asked for the drop. EVERY account that arrived must carry a mark, not any one: a destruction
  # (#732) takes the accounts it takes, and one marked account must never be the cover that lets an unmarked one
  # seal away. The cost is deliberately lopsided -- a wrong refusal costs a repeated sign-out, a wrong acceptance
  # costs the account PERMANENTLY -- so every doubt refuses: no arrival record, no mark, a non-Google account
  # (T above the hash count), a name nowhere_db_fix would not print (`?`). The log says which case happened,
  # by count and case word only, never a name or a hash.
  #
  # _stg is the staged set in the arrival record's format (total row count, then one mark hash per Google row),
  # empty when it cannot be read. The push below uses it to clear the marks of the accounts that left and to keep
  # the arrival record equal to what the head now holds.
  if [ -x /system/bin/nowhere_db_fix ]; then
    _stgl=$(/system/bin/nowhere_db_fix accounts-google "$stage/ce/accounts_ce.db" 2>>"$LOG") && {
      _stgc=$(print -r -- "$_stgl" | sed -n 1p)
      case "$_stgc" in
        ''|*[!0-9]*) ;;
        *)
          _sh=$(print -r -- "$_stgl" | sed 1d | acct_mark_hashes)
          _stg="$_stgc${_sh:+
$_sh}"
          ;;
      esac
    }
    _stgl=""; _sh=""
  fi
  # NWP-20261123-19: -e, not -f. Any entry at this path keeps the guard ARMED: a directory left where acct_reload's
  # write failed is a doubt, and every doubt arms. The disarm lines below and in acct_reload stay `rm -f`, which
  # cannot remove a directory, so such an entry stays armed: the safe direction (a wrong refusal costs one repeated
  # sign-out, a wrong acceptance the account).
  if [ -e "$STATE/.had_account" ] && [ -x /system/bin/nowhere_db_fix ]; then
    _arows=$(/system/bin/nowhere_db_fix accounts-count "$stage/ce/accounts_ce.db" 2>>"$LOG" | tr -cd '0-9-')
    case "$_arows" in
      0)
        _arr="/data/system_ce/$uid/nowhere-acct-arrival"; _case=""; _t=""
        if [ ! -f "$_arr" ]; then
          _case="no record"
        else
          _t=$(sed -n 1p "$_arr" 2>/dev/null)
          case "$_t" in ''|*[!0-9]*|0*) _case="no record" ;; esac
        fi
        if [ -z "$_case" ]; then
          if ! _mf=$(acct_mark_file "$uid") || [ ! -s "$_mf" ]; then
            _case="no mark"
          elif [ -s "$_mf.pending" ]; then
            # RF-001 (NWP-20261107-11): the chooser's journal (nowhere-acct-marks.pending, same line format) is open
            # while a sign-out's removal is unsettled or its rollback could not land. A mark beside an open entry is
            # not proof the user wants the drop, so refuse until the chooser has cleared it.
            _case="pending"
          else
            # A mark hash never goes into an exec'd argv: argv is readable by `ps` (DIA-20260812-02) and the hash is
            # unsalted, enough to confirm which account a profile holds. So the file is read once and membership is
            # tested in the shell, newline-anchored on both sides; the prune after the push does the same.
            _i=0; _hn=0; _mks="$_nl$(cat "$_mf" 2>/dev/null)$_nl"
            while IFS= read -r _h; do
              _i=$((_i + 1))
              [ "$_i" = 1 ] && continue
              _hn=$((_hn + 1))
              case "$_h" in
                ''|'?') _case="unmarked" ;;
                *) case "$_mks" in *"$_nl$_h$_nl"*) ;; *) _case="unmarked" ;; esac ;;
              esac
            done < "$_arr"
            [ "$_hn" = "$_t" ] || _case="unmarked"
          fi
        fi
        if [ -z "$_case" ]; then
          print -r -- "[roamd] OUT $(qn "$name") #sys accounts: ZERO rows, and every one of the $_t arriving account(s) was signed out on purpose through Nowhere -- sealing the drop (dn-1025 #2) $(date)" >> "$LOG"
        else
          print -r -- "[roamd] OUT $(qn "$name") #sys accounts REFUSED -- the staged accounts_ce.db has ZERO account rows but this profile arrived WITH an account, so sealing it would destroy the head PERMANENTLY (#743). Keeping the previous head. If you deliberately signed out, sign in again or the account returns at next login; case: $_case $(date)" >> "$LOG"
          rm -rf "$stage"
          return 4
        fi
        ;;
      ''|-1|*[!0-9]*)
        # unreadable / no `accounts` table: NOT evidence of loss. Fail OPEN and say so, rather than refusing
        # every seal on an unrelated schema change -- that failure mode would be silent and total.
        print -r -- "[roamd] OUT $(qn "$name") #sys accounts: row count unavailable ('$_arows'), falling back to the byte check (#743) $(date)" >> "$LOG"
        ;;
      *)
        print -r -- "[roamd] OUT $(qn "$name") #sys accounts: $_arows row(s) staged (#743) $(date)" >> "$LOG"
        ;;
    esac
  fi
  # DIA-20260812-05: backstop, not a stopwatch -- see the note at the #apps ladder.
  # NWP-20260908-01: pinned OFF -- see the note in _push. The #sys stage is `ce`/`de`, not app packages.
  ACCT_PUSHED=1   # NWP-20261123-06: this seal reached the #sys push -> a sys entry in the seal split
  NOWHERE_CARRY_ESSENTIAL=0 NOWHERE_CARRY_ESSENTIAL_MEDIA=0 \
    timeout -k 5 3600 "$AGENT" push s3 "${name}#sys" "$(pw "$pass")" "$stage" >> "$LOG" 2>&1; r=$?
  rm -rf "$stage"
  print -r -- "[roamd] OUT $(qn "$name") #sys accounts push rc=$r $(date)" >> "$LOG"
  # NWP-20261104-06: only a SEALED head changes the books; rc != 0 touches nothing (the old head still stands).
  if [ "$r" = 0 ] && [ -n "$_stg" ]; then
    # A mark is spent once its account has left the head; one whose account is still staged stays. The file is
    # rewritten IN PLACE (one redirection to the same path): the chooser app owns it and keeps its owner, mode and
    # label, which a new file moved over it would not. Membership is tested in the shell, as in the guard above: a
    # mark hash never reaches an exec'd argv.
    if _mf=$(acct_mark_file "$uid") && [ -f "$_mf" ]; then
      _sh="$_nl$(print -r -- "$_stg" | sed 1d)$_nl"
      _keep=""; _kn=0; _dn=0
      while IFS= read -r _h; do
        [ -n "$_h" ] || continue
        if case "$_sh" in *"$_nl$_h$_nl"*) true ;; *) false ;; esac; then
          _keep="${_keep:+$_keep
}$_h"; _kn=$((_kn + 1))
        else
          _dn=$((_dn + 1))
        fi
      done < "$_mf"
      if [ "$_kn" = 0 ]; then
        rm -f "$_mf" 2>>"$LOG"
      elif [ "$_dn" != 0 ]; then
        print -r -- "$_keep" > "$_mf" 2>>"$LOG"
      fi
      [ "$_dn" = 0 ] || print -r -- "[roamd] OUT $(qn "$name") #sys accounts: cleared $_dn account mark(s) after the drop sealed, $_kn kept (dn-1025 #2) $(date)" >> "$LOG"
    fi
    # The arrival record follows the head, but only on a profile the guard is armed for: this never CREATES
    # .had_account (arming a mid-session add is not decided). An account-less head disarms it for good. It reads the
    # marker as the guard does, with -e (NWP-20261123-19).
    if [ -e "$STATE/.had_account" ]; then
      _arr="/data/system_ce/$uid/nowhere-acct-arrival"
      _stgc=$(print -r -- "$_stg" | sed -n 1p)
      if [ "$_stgc" = 0 ]; then
        rm -f "$_arr" "$STATE/.had_account" 2>>"$LOG"
      elif ( umask 077; print -r -- "$_stg" > "$_arr" ) 2>>"$LOG"; then
        chmod 600 "$_arr" 2>>"$LOG"
      else
        rm -f "$_arr" 2>>"$LOG"
      fi
    fi
  fi
  return "$r"
}

# acct_restore UID (DIA-20260802-05): STAGE the sealed account dbs into a HOLD dir -- do NOT place them into
# /data/system_ce|de yet. AMS opened its OWN (empty) accounts db the instant this user UNLOCKED and holds the SQLite
# connection OPEN; overwriting the files under it is unsafe (a close-time WAL checkpoint can write AMS's cached empty
# pages back over the restored rows). So defer the actual placement to acct_reload (grant op), which runs AFTER the
# authenticator app is installed and brackets the copy with the patched `cmd account detach-user`/`reload-user` so the
# db is replaced while AMS's connection is CLOSED. Here we just land the sealed bytes locally. Empty ref -> no-op.
# NWP-20261104-05: it first voids an earlier session's account marks (see the choices above acct_mark_file).
acct_restore() {
  local uid="$1" hold="/data/nowhere/acct-hold-$uid" mf mn
  # NWP-20261104-05 (dn-1025 #2): void an earlier session's account marks FIRST, before the agent restore, so it
  # happens whether or not a #sys head exists or restores. Count only in the log.
  if mf=$(acct_mark_file "$uid") && [ -f "$mf" ]; then
    mn=$(grep -c '' "$mf" 2>>"$LOG")
    rm -f "$mf" 2>>"$LOG"
    print -r -- "[roamd] IN $(qn "$name") #sys: voided ${mn:-0} account mark(s) left from an earlier session (dn-1025 #2) $(date)" >> "$LOG"
  fi
  # the chooser's journal of unsettled sign-outs (acct_seal refuses while it is open) is as stale as the marks
  if mf=$(acct_mark_file "$uid"); then rm -f "$mf.pending" 2>>"$LOG"; fi
  rm -rf "$hold"; mkdir -p "$hold" 2>>"$LOG"
  NOWHERE_PHASE=accounts "$AGENT" restore s3 "${name}#sys" "$(pw "$pass")" "$hold" >> "$LOG" 2>&1 || { rm -rf "$hold"; return 0; }
  { [ -f "$hold/ce/accounts_ce.db" ] || [ -f "$hold/de/accounts_de.db" ]; } || { rm -rf "$hold"; return 0; }
  # DIA-20260804-08: a hold with only the DE half carries NO account -- the row lives in CE. That combination
  # means a previous logoff sealed a short #sys (see acct_seal, now refused there). Say so loudly instead of
  # staging it silently: placing DE-only later logs a cheerful "placed + reloaded" while the profile comes back
  # signed out, which is exactly how this hid.
  if [ ! -s "$hold/ce/accounts_ce.db" ]; then
    print -r -- "[roamd] IN $(qn "$name") #sys accounts hold has NO CE half (accounts_de.db only) -- the sealed head carries no account row; this profile WILL come back signed out $(date)" >> "$LOG"
  fi
  print -r -- "[roamd] IN $(qn "$name") #sys accounts staged (hold) ce=$([ -s "$hold/ce/accounts_ce.db" ] && echo yes || echo NO) de=$([ -s "$hold/de/accounts_de.db" ] && echo yes || echo no) -> user $uid $(date)" >> "$LOG"
}

# acct_reload UID (DIA-20260802-05): place the staged account dbs into /data/system_ce|de and make AMS re-read them.
# Runs in the `grant` op -- AFTER provisionRoamedApps installed the authenticator (else AMS's validate purges the
# account for a missing authenticator). Brackets the placement with the patched AccountManagerService shell commands:
# `detach-user` drops + closes AMS's (still-empty) connection so its checkpoint is a no-op and the files aren't open;
# then lay the restored dbs down; then `reload-user` re-opens + re-reads + re-validates + broadcasts ACCOUNTS_CHANGED.
# cmd stdio -> /dev/null (su:s0 cmd fd denial). No hold -> nothing to do.
acct_reload() {
  local uid="$1" hold="/data/nowhere/acct-hold-$uid" pce=no pde=no pcs=no _acf _acs
  [ -d "$hold" ] || return 0
  cmd account detach-user "$uid" </dev/null >/dev/null 2>&1
  if [ -f "$hold/ce/accounts_ce.db" ]; then
    pce=yes
    rm -f "/data/system_ce/$uid/accounts_ce.db-wal" "/data/system_ce/$uid/accounts_ce.db-shm" 2>>"$LOG"
    cp -a "$hold"/ce/accounts_ce.db* "/data/system_ce/$uid/" 2>>"$LOG"
    # NWP-20261118-09: the copy must land WHOLE before the row count below trusts it. A short copy (ENOSPC) left a
    # torn accounts_ce.db or -wal: AMS's reopen can replace a corrupt db with a fresh row-empty one, and SQLite drops a
    # torn WAL tail, so the count read a CONFIRMED zero, disarmed the #743 guard, and the next seal pushed the
    # row-empty db over the stored account. So every file the hold carries must be here at its own size. On the first
    # miss the placed files go, so AMS opens a fresh db at reload-user (never a torn one) and acct_seal can never seal
    # a torn file; pcs=yes keeps the guard ARMED below. pce goes to no, so the GRANT line and the no-CE WARNING say so.
    for _acf in "$hold"/ce/accounts_ce.db*; do
      [ -e "$_acf" ] || continue
      _acs=$(stat -c %s "$_acf" 2>/dev/null)
      case "$_acs" in ""|*[!0-9]*) ;; *) [ "$_acs" = "$(stat -c %s "/data/system_ce/$uid/${_acf##*/}" 2>/dev/null)" ] && continue ;; esac
      pce=no; pcs=yes
      rm -f "/data/system_ce/$uid/"accounts_ce.db* 2>>"$LOG"
      print -r -- "[roamd] GRANT $(qn "$name") #sys WARNING: accounts_ce.db copied short for user $uid -- removed it, the guard stays armed $(date)" >> "$LOG"
      break
    done
    chown system:system "/data/system_ce/$uid/"accounts_ce.db* 2>>"$LOG"; restorecon "/data/system_ce/$uid/"accounts_ce.db* 2>>"$LOG"
  fi
  if [ -f "$hold/de/accounts_de.db" ]; then
    pde=yes
    rm -f "/data/system_de/$uid/accounts_de.db-wal" "/data/system_de/$uid/accounts_de.db-shm" 2>>"$LOG"
    cp -a "$hold"/de/accounts_de.db* "/data/system_de/$uid/" 2>>"$LOG"
    chown system:system "/data/system_de/$uid/"accounts_de.db* 2>>"$LOG"; restorecon "/data/system_de/$uid/"accounts_de.db* 2>>"$LOG"
    # DIA-20260802-06: strip the STALE authenticator-uid meta from the restored DE db. A roamed account carries the
    # OLD device/user's authenticator uid (TABLE_META key auth_uid_for_type:<type>), which is never an installed uid
    # on the fresh user -> AccountManagerService.validateAccountsInternal flags it obsolete and DESTRUCTIVELY DELETES
    # the account ("validateAccountsInternal#Deleted", proven on lynx) even though gms's authenticator IS registered.
    # Clearing these rows makes validate see no stored uid -> it keeps the account and re-populates the meta with the
    # CURRENT authenticator uid. SAFE: the db is detached (no AMS connection between detach-user and reload-user), so
    # this quick DELETE can't contend/livelock (unlike a .backup of a live db). Restores system ownership after.
    # DIA-20260817-01 (#732): the strip now happens IN-PROCESS inside `cmd account reload-user` (see
    # endospore-ams-account-reload.sh) -- reloadUserAccounts deletes the stale auth_uid_for_type rows via
    # AccountsDb before validateAccountsInternal runs, under AMS's own locks. The sqlite3 shell-out that
    # lived here was USERDEBUG-ONLY: on every `user` build it failed ("sqlite3: inaccessible or not found",
    # captured verbatim by issue report NW-f73faa55d1da), the stale rows survived, and validate DESTROYED
    # the roamed account seconds after this function logged "placed ... + reloaded". Same-device
    # same-profile A/B proved it: userdebug-relocked roams, user destroys. No shell-side fallback on
    # purpose: a fallback that only works on userdebug is the disease, not a safety net.
  fi
  cmd account reload-user "$uid" </dev/null >/dev/null 2>&1
  rm -rf "$hold"
  # DIA-20260804-08: report what was ACTUALLY placed. This line used to print unconditionally -- including when
  # neither db was in the hold -- so a profile that came back with no account still logged a clean "placed +
  # reloaded", and the failure was invisible until someone compared file mtimes by hand. ce=NO is the one that
  # matters: the account row lives there, so ce=NO means signed out no matter how healthy everything else looks.
  print -r -- "[roamd] GRANT $(qn "$name") #sys accounts placed ce=$pce de=$pde + reloaded -> user $uid $(date)" >> "$LOG"
  [ "$pce" = yes ] || print -r -- "[roamd] GRANT $(qn "$name") #sys WARNING: no CE db placed for user $uid -- the profile has NO account and every Google app will be signed out $(date)" >> "$LOG"
  # DIA-20260818-15 (#743): remember that THIS profile arrived with an account, so the logoff guard can refuse a
  # rowless db instead of sealing it over a good head. The marker is the cheap proxy for "the store head holds an
  # account" -- the honest test would be reading that head, which costs a restore we already did right here.
  # Only ce=yes counts: the account ROW lives in the CE db, so a de-only placement is already signed out.
  # NWP-20260903-14: PLACEMENT IS NOT POSSESSION. This used to mark on `pce = yes` alone -- i.e. on a CE db
  # FILE having been copied -- but AMS creates accounts_ce.db at unlock, so a profile that has NEVER held an
  # account still seals a valid, ROW-EMPTY db, still gets it placed, and so still got marked. The logoff
  # guard then read the marker, counted zero rows, and refused #sys -- PERMANENTLY, on every logoff, since
  # nothing clears the marker for such a profile. Device-observed on lynx 2026-09-03 (throwaway odcamp1, no
  # Google account ever): `accounts placed ce=yes`, then every subsequent logoff logged
  # "REFUSED -- ZERO account rows but this profile arrived WITH an account" and "PARTIAL: sys=refused".
  #
  # The guard above already states the rule this restores: "A profile that never had one still seals its
  # row-empty db exactly as before." Its exemption was simply unreachable, because the marker could not
  # distinguish the two cases. So ask the same question the guard asks, with the same tool, at the same
  # fidelity: ROWS, not bytes, not file presence.
  #
  # ⚠ UNKNOWN MARKS. An unreadable count / missing tool marks the profile as having an account, keeping the
  # guard ARMED. That is the asymmetry #743 was built on and it is unchanged here: a wrong refusal costs one
  # repeated sign-in, a wrong acceptance costs the account PERMANENTLY. Only a CONFIRMED zero disarms.
  # NWP-20261123-19: a write that leaves no entry at the path cannot arm the guard (acct_seal reads it with -e). Each
  # arm checks after its write, and then logs that the guard is DISARMED instead of its armed or marking line.
  # NWP-20261104-05 (dn-1025 #2): the ARRIVAL RECORD -- which accounts this profile arrived with: the total row
  # count, then one mark hash per Google row (format and home: the choices above acct_mark_file). Written only where
  # .had_account is, from a CONFIRMED positive count; every other outcome below removes it, so a record never
  # describes an older placement. Counts only in the log: never a name, never a hash.
  _arr="/data/system_ce/$uid/nowhere-acct-arrival"
  if [ "$pce" = yes ]; then
    _prows=-1
    [ -x /system/bin/nowhere_db_fix ] && _prows=$(/system/bin/nowhere_db_fix accounts-count "/data/system_ce/$uid/accounts_ce.db" 2>>"$LOG" | tr -cd "0-9-")
    case "$_prows" in
      0)
        rm -f "$STATE/.had_account" 2>>"$LOG"
        rm -f "$_arr" 2>>"$LOG"
        print -r -- "[roamd] GRANT $(qn "$name") #sys arrival record: unavailable (NWP-20261104-05) $(date)" >> "$LOG"
        print -r -- "[roamd] GRANT $(qn "$name") #sys placed a ROW-EMPTY accounts db -- NOT marking .had_account, so this account-less profile can still seal #sys (NWP-20260903-14) $(date)" >> "$LOG"
        ;;
      *[!0-9-]*|""|-1)
        mkdir -p "$STATE" 2>>"$LOG"
        ( : > "$STATE/.had_account" ) 2>>"$LOG"
        rm -f "$_arr" 2>>"$LOG"
        print -r -- "[roamd] GRANT $(qn "$name") #sys arrival record: unavailable (NWP-20261104-05) $(date)" >> "$LOG"
        if [ -e "$STATE/.had_account" ]; then
          print -r -- "[roamd] GRANT $(qn "$name") #sys account row count unavailable ('$_prows') -- marking .had_account anyway; the guard stays armed (NWP-20260903-14) $(date)" >> "$LOG"
        else
          print -r -- "[roamd] GRANT $(qn "$name") #sys could NOT write .had_account -- the #743 guard is DISARMED this session (NWP-20261123-19) $(date)" >> "$LOG"
        fi
        ;;
      *)
        mkdir -p "$STATE" 2>>"$LOG"
        ( : > "$STATE/.had_account" ) 2>>"$LOG"
        [ -e "$STATE/.had_account" ] || print -r -- "[roamd] GRANT $(qn "$name") #sys could NOT write .had_account -- the #743 guard is DISARMED this session (NWP-20261123-19) $(date)" >> "$LOG"
        _agt=""
        _agl=$([ -x /system/bin/nowhere_db_fix ] && /system/bin/nowhere_db_fix accounts-google "/data/system_ce/$uid/accounts_ce.db" 2>>"$LOG") && _agt=$(print -r -- "$_agl" | sed -n 1p)
        case "$_agt" in
          ""|*[!0-9]*)
            rm -f "$_arr" 2>>"$LOG"
            print -r -- "[roamd] GRANT $(qn "$name") #sys arrival record: unavailable (NWP-20261104-05) $(date)" >> "$LOG"
            ;;
          *)
            if ( umask 077; { print -r -- "$_agt"; print -r -- "$_agl" | sed 1d | acct_mark_hashes; } > "$_arr" ) 2>>"$LOG"; then
              chmod 600 "$_arr" 2>>"$LOG"
              _agk=$(print -r -- "$_agl" | sed 1d | grep -c '')
              print -r -- "[roamd] GRANT $(qn "$name") #sys arrival record: $_agt row(s), $_agk Google (NWP-20261104-05) $(date)" >> "$LOG"
            else
              rm -f "$_arr" 2>>"$LOG"
              print -r -- "[roamd] GRANT $(qn "$name") #sys arrival record: unavailable (NWP-20261104-05) $(date)" >> "$LOG"
            fi
            ;;
        esac
        _agl=""
        ;;
    esac
  # NWP-20261118-09: a short CE copy is a doubt, and every doubt keeps the guard ARMED (the unreadable-count arm).
  elif [ "$pcs" = yes ]; then
    mkdir -p "$STATE" 2>>"$LOG"
    ( : > "$STATE/.had_account" ) 2>>"$LOG"
    rm -f "$_arr" 2>>"$LOG"
    print -r -- "[roamd] GRANT $(qn "$name") #sys arrival record: unavailable (NWP-20261104-05) $(date)" >> "$LOG"
    if [ -e "$STATE/.had_account" ]; then
      print -r -- "[roamd] GRANT $(qn "$name") #sys short CE copy -- marking .had_account so the next seal cannot replace the stored account (NWP-20261118-09) $(date)" >> "$LOG"
    else
      print -r -- "[roamd] GRANT $(qn "$name") #sys could NOT write .had_account -- the #743 guard is DISARMED this session (NWP-20261123-19) $(date)" >> "$LOG"
    fi
  else
    rm -f "$STATE/.had_account" 2>>"$LOG"
    rm -f "$_arr" 2>>"$LOG"
    print -r -- "[roamd] GRANT $(qn "$name") #sys arrival record: unavailable (NWP-20261104-05) $(date)" >> "$LOG"
  fi
}

ACCT_USERS_ROOT="${ACCT_USERS_ROOT:-/data/system/users}"           # overridable for test-acct-authenticator-wait.sh only, as DE_SYS_ROOT is

# acct_type_registered FILE TYPE -- true iff FILE (AccountManagerService's per-user registered-authenticators
# file) records TYPE as a WHOLE attribute value, never as a part of a longer type (NWP-20261121-03). Two forms:
#   text XML: the fixed string type="TYPE" (grep -F, so a `.` in TYPE is a literal dot);
#   ABX: BinaryXmlSerializer writes an attribute string with writeUTF -- a 2-byte big-endian byte length, then the
#        bytes -- so TYPE is the byte run <len high> <len low> <TYPE bytes>. That run is matched BYTE-ALIGNED in an
#        od hex dump (toybox od and GNU od both print lower-case two-digit bytes), so the match needs no grep over
#        binary data (the device's grep/regexec stops at a NUL: docs/amnesia-poweroff-audit.md, "Two tooling
#        hazards"). ${#type} is the byte length because account types are ASCII.
# A missing, unreadable or empty file, or an empty TYPE, is false.
acct_type_registered() {
  local f="$1" type="$2" len dump want
  [ -n "$type" ] && [ -f "$f" ] && [ -r "$f" ] || return 1
  grep -qF "type=\"$type\"" "$f" 2>/dev/null && return 0
  len=${#type}
  dump=$(od -An -tx1 -v "$f" 2>/dev/null | tr -s ' \n' '  ')
  want=$(printf '%s' "$type" | od -An -tx1 -v | tr -s ' \n' '  ')
  dump=${dump# }; dump=${dump% }; want=${want# }; want=${want% }
  want="$(printf '%02x %02x' $((len / 256)) $((len % 256))) $want"
  case " $dump " in *" $want "*) return 0 ;; esac
  return 1
}

# wait_acct_authenticator UID [TYPE] -- block (bounded) until the account authenticator of TYPE (default
# com.google) is REGISTERED for user UID. group-materialize BLOCKER 2: on the on-demand path gms is installed
# only moments before its odrestore runs, so AccountManagerService may not have scanned its
# GoogleAccountAuthenticatorService yet. If acct_reload places + reloads the account DB before the authenticator
# is registered, validateAccountsInternal finds an account with no matching authenticator and DESTRUCTIVELY
# purges it ("Accounts: 0", accounts_ce.db emptied -- proven on lynx odtest20->user11). AMS persists its
# registered authenticators to a per-user XML as they are scanned; that file gaining a `com.google` account-type
# entry is a lower bound on "authenticator ready". Poll THAT file (a normal read -- NOT a `cmd`/dumpsys binder fd,
# which su:s0 can't capture). NB the file is ANDROID BINARY XML (ABX), not text -- the type is stored as a
# length-prefixed string, so a text `type="..."` pattern alone never matches (proven on odtest22->user11: the poll
# ran its full 30s and fell through even though the account survived). The match must be the WHOLE type, not a
# substring: Gmail registers com.google.android.gm.exchange, .legacyimap and .pop3, which all contain com.google,
# so a substring match ended the wait on Gmail's entries before GMS registered and let acct_reload purge the
# account (NWP-20261121-03; acct_type_registered above). The login `grant` path runs after a natural delay and
# doesn't need this, so it's added ONLY on the odrestore path. Falls through after the timeout so a
# never-registered authenticator is no worse than pre-fix.
wait_acct_authenticator() {
  local uid="$1" type="${2:-com.google}" i=0
  local f="$ACCT_USERS_ROOT/$uid/registered_services/android.accounts.AccountAuthenticator.xml"
  while [ "$i" -lt 30 ]; do
    if acct_type_registered "$f" "$type"; then
      echo "[roamd] acct authenticator $type registered for user $uid (waited ${i}s) $(date)" >> "$LOG"
      return 0
    fi
    sleep 1; i=$((i+1))
  done
  echo "[roamd] WARN acct authenticator $type NOT seen for user $uid after ${i}s -- reloading anyway $(date)" >> "$LOG"
  return 1
}

# ---------------------------------------------------------------------------------------------------------
# #210 part 2 -- "keep me signed in to <app> on this device". Capture side (DIA-20260728-11).
#
# WHY. #210 made an app's SSAID roam, which was necessary but not sufficient: Amazon still signed out every
# login because MAP seals its token under KEYSTORE keys (aliases IDENTITY_MAP_KEYSTORE_ALIAS +
# mshop_rcs_master_key, observed on lynx), and keystore entries are namespaced by app uid -- they die with the
# roamed user. Verified against system/security/keystore2: the TEE has NO concept of Android users, a KeyMint
# blob is DEVICE-bound not uid-bound, and ownership is pure sqlite bookkeeping
# (`Domain::APP => KeyDescriptor { nspace: caller_uid.0, .. }`). So re-parenting a key to the next login's uid
# is a DATABASE operation, not a cryptographic one -- ON THE SAME DEVICE.
#
# WHAT WE REFUSE TO CARRY. A key whose blob is SUPERENCRYPTED is wrapped under the OLD user's LSKF-derived
# super key, which the new user does not have; restoring it would yield a key that EXISTS BUT CANNOT BE USED,
# and apps handle that far worse than a missing key (InvalidKeyException in a retry loop, often with no
# re-login path). We detect that DIRECTLY rather than by re-deriving keystore2's policy: a superencrypted blob
# carries a blobmetadata row with tag 0 = EncryptedBy (BlobMetaEntry's variant order:
# EncryptedBy=0, Salt=1, Iv=2, AeadTag=3, KmUuid=4). Any key with such a row is skipped, whatever the policy
# reason was (UserSecureID / UnlockedDeviceRequired / boot-level).
#
# DEVICE GATE. The bundle records this device's unit id and the IMPORT side must refuse a bundle stamped for
# another device. It is stamped here rather than relying on a per-unit store ref because per-unit refs are
# gated behind NOWHERE_MULTIDEVICE=1 (multidevice.go), which is not set -- so `#keys` resolves to a shared
# head today and the bytes WOULD reach a second phone. Unit id lives on f2fs /data/nowhere (NOT the tmpfs
# /data/nowhere/state), so it survives reboot; if it is ever lost the stamp simply stops matching and the user
# signs in again -- the safe direction.
#
# ALWAYS ON: every app namespace keystore2 dumps is captured, on the same rule as app data.
# (Superseded by NWP-20260830-03: this read "OPT-IN, DEFAULT OFF: nothing is captured unless the chooser lists
# the package in nowhere-keepkeys.list. Amnesia stays the default; carrying identity is the choice." The
# switch and the list are gone.) Best-effort throughout -- this must NEVER fail the data seal.
# (KS_KEEP/KS_MAP/KS_EXPORT/KS_IMPORT/KS_IN/KS_UNIT are defined ahead of the op-dispatch -- see the keystore_push
#  forward-ref note above -- so the credless cleanstorage handler can seal.)

# keystore_unit: read-or-mint this device's unit id, the SAME file the agent's deviceUnitID() uses, so the
# stamp keystore2 writes and the one it checks agree. /data/nowhere is f2fs (only /data/nowhere/state is
# tmpfs), so it survives a reboot. If it is ever lost the stamp stops matching and the user signs in again --
# the safe direction to fail.
# ⚠ CRITICAL (root-caused 2026-07-28): the keystore2 patch runs as the `keystore` UNIX USER, not root, so it
# cannot read a root:root 0600 file NOR the `nowhere_data_file` SELinux type of /data/nowhere. Its export
# (read_keep_set + read_unit) therefore silently no-op'd on the un-readable files -> keys never exported.
# (Superseded in part by NWP-20260830-03: read_keep_set and keep-uids are gone; read_unit is the one reader
# left, and the import bundles are still made 0644.)
# So we ALSO stage the unit id into KS_UNIT under /data/misc/keystore (`keystore_data_file`, world-readable),
# where the keystore domain CAN reach it. keep-uids + the import bundles are made 0644 for the same reason;
# the SELinux keystore_data_file label -- not the DAC bits -- is the real boundary (non-keystore domains
# can't touch that type at all).
keystore_unit() {
  UIDF=/data/nowhere/unit-id
  if [ ! -s "$UIDF" ]; then
    (od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n') > "$UIDF" 2>>"$LOG"
    chmod 600 "$UIDF" 2>>"$LOG"
  fi
  _u=$(cat "$UIDF" 2>/dev/null)
  # Mirror it where keystore2 (keystore user) can read it. Rewrite only when stale/absent.
  if [ -n "$_u" ] && [ "$(cat "$KS_UNIT" 2>/dev/null)" != "$_u" ]; then
    mkdir -p /data/misc/keystore 2>>"$LOG"
    printf '%s' "$_u" > "$KS_UNIT" 2>>"$LOG"
    chmod 644 "$KS_UNIT" 2>>"$LOG"; restorecon "$KS_UNIT" 2>>"$LOG"
  fi
  printf '%s' "$_u"
}

# keystore_register PKG: called at odrestore, the FIRST moment this login's app uid exists -- the app is
# reinstalled during the roam and assigned a fresh appId (seen drifting 10328->10336->10340->10344->10348
# across one afternoon), so nothing earlier can know it. Registers the namespace for keystore2 to export at
# reap, and promotes any restored bundle to the uid-keyed name the import hook looks for.
# keystore_register_all: register EVERY opted-in package that is installed right now (#737).
# (Superseded by NWP-20260830-03: there is no opt-in. The sweep maps EVERY package `pm list packages -U -a`
# reports into KS_MAP in one pass and no longer calls keystore_register per package -- see the body. The
# history below explains why the sweep exists; its opt-in wording describes the code before that slice.)
#
# THE FIRST-CYCLE GAP. keystore_register is the only writer of KS_KEEP, and until now it was reached from one
# place: odrestore -- the on-demand TAP on a roamed-IN session. A profile's FIRST session installs its apps
# through the store/Play path, which never passes through odrestore, so nothing was ever registered, keystore2
# had an empty KS_KEEP at remove_user, it dumped nothing, and keystore_push had nothing to seal. Cycle 1
# therefore ALWAYS lost the carried sign-in, and the user only got it from cycle 2 onward.
#
# Measured on frankel 2026-08-18 (ticket NW-27a6b7949e4c, Chester: "Amozan login doesnt roam"):
#     10:11:54  OUT <name> #apps sealed (4 pkg)                      <- the code sealed
#     10:18:25  keystore registered com.amazon...  for carry (#210)  <- SEVEN MINUTES LATER, at the tap
#               restore: <name> #keys empty -> nothing               <- so the store held no keys at all
# Amazon came back installed and signed out. Same on lynx 2026081810, so it is not variant-specific.
#
# The registration cannot happen any earlier than a live session -- the app is reinstalled during the roam and
# gets a FRESH appId (observed drifting 10328->10336->10340->10344->10348 in one afternoon), so only the
# running user knows it. But it can happen LATER-but-still-in-time: this sweep runs on the logoff path while
# the user is still alive, which is the last moment packages.list can be read and still the right side of
# remove_user. Every opted-in app that exists gets registered, tapped this session or not.
#
# Deliberately reuses keystore_register per package rather than reimplementing: that function already handles
# the opt-in check, the appId lookup, KS_KEEP/KS_MAP dedupe and the KS_IN promotion, and a second copy of that
# logic is exactly how two paths drift.
# (Superseded in part by NWP-20261119-08: the sweep still calls keystore_register per bundle, for the namespace, the
# KS_MAP row and the mv, but in batch mode. The import dir is prepared once before the loop, and one chmod, chown and
# restorecon cover every staged bundle after it. See the promotion loop in the body.)
keystore_register_all() {
  # NWP-20260826-15: STAGE THE OPT-IN LIST DE-SIDE, HERE, WHILE THE USER IS STILL ALIVE.
  #
  # (SUPERSEDED by NWP-20261102-05, Q049: keystore_push now filters against the DROP list `out` stages at
  # $KS_DROP (ks_stage_drop), uid-stamped the same way; no opt-in list is staged or read. The reasoning below
  # is why the list must be staged de-side, and still holds for $KS_DROP.)
  #
  # ⚠ WITHOUT THIS THE #keys SCOPE COULD NEVER SHRINK. keystore_push's drop filter reads the opt-in list from
  # the roamed user's CE storage, but it runs on `cleanstorage` -- next to the reap -- by which point that
  # storage is gone. Its fail-safe ("unreadable is not 'nobody opted in'") then leaves _kdrop at 0, and with no
  # fresh dump either (_kn=0) keystore_push EARLY-RETURNS and leaves the head completely untouched. So a
  # bundle for an app the user removed is re-restored every single login, forever.
  #
  # DEVICE-PROVEN on lynx 2026-08-26. Chester removed Tesla the previous day and roamed 15+ times; the #keys
  # head was still frozen at its 18:52 content, com.teslamotors.tesla.keys restored on every login, and
  # `no longer opted in` had never been logged once. The `0 dropped` in the seal line was the filter being
  # SKIPPED, not the filter deciding to keep it.
  #
  # This is the same fix KEEP_PATH already documents for the same reason -- "it cannot be read at reap time,
  # which is exactly when we need it, so it is staged to this DE-side path in advance".
  #
  # ⚠ STAMPED WITH THE UID, so a file left behind by a previous session can never be mistaken for this one's.
  # Filtering a profile's bundles against another profile's opt-in list would destroy them.
  # ⚠ ABSENT means "could not tell" -> keystore_push does not filter. EMPTY (header only) means "nobody is
  # opted in" -> everything is legitimately dropped. Those must stay distinguishable, which is why the header
  # is always written even when the list is empty.
  # NWP-20260830-03: the staged opt-in list is gone with the filter it fed (see keystore_push). Nothing
  # reads KS_OPTIN any more, so writing it would be staging a file for a consumer that no longer exists.
  # NWP-20260830-03: THERE IS NO OPT-IN ANY MORE. "Keep me signed in" was removed because it named an outcome
  # it could not deliver -- a session may live in Keystore, in app data, or both, and the switch governed only
  # the first, so OFF still left apps signed in. Keys now roam unconditionally, on the same rule as app data.
  #
  # ⚠ WHY THIS IS NOW ONE PASS AND NOT A PER-PACKAGE LOOP. keystore_register does a chmod + restorecon on
  # KS_KEEP on EVERY call. Over an opt-in list of ~11 that was invisible; over every package it would be ~245
  # restorecon round-trips ON THE LOGIN PATH, and login latency is already an open P0 (NWP-20260828-16, a
  # measured 179s login). So the sweep no longer calls keystore_register at all: it derives KS_MAP directly
  # from the single `pm` output it already has, in one write.
  #
  # ⚠ KS_KEEP IS NO LONGER WRITTEN. It existed solely so keystore2 could read the opt-in set; that reader
  # (read_keep_set/KEEP_PATH) is gone in the same slice, so populating it would be writing a file nothing
  # reads. The reap-time prune still lists it, which is harmless for a file that is absent.
  #
  # ⚠ KS_MAP IS STILL REQUIRED, and this is the reason the sweep survives at all rather than being deleted:
  # keystore_push names each dump by package via KS_MAP (`<ns> <pkg>`), and a dump it cannot name is NOT
  # SEALED. With every namespace now exportable, the map has to cover every package -- resolved here, while
  # the user is alive, because `pm` cannot answer once the reap has started.
  #
  # ⚠ `-a` INCLUDES ARCHIVED, and that is load-bearing rather than incidental: an ON-DEMAND app is an archived
  # placeholder for most of its life, and NWP-20260827-05/-06 were both bugs caused by lookups that miss those.
  # ONE `pm` call for the whole sweep -- it is a binder round-trip and this runs on the logoff path.
  _pu=$(pm list packages -U -a --user "$uid" 2>/dev/null)
  mkdir -p /data/misc/keystore 2>>"$LOG"
  keystore_unit >/dev/null    # the keystore-readable unit-id mirror must exist before any export can fire
  # Build the ns->pkg map in a single pass. Merged with whatever is already there (a mid-session sweep must not
  # drop rows an earlier one resolved), then written once -- not once per package.
  _kmtmp="$KS_MAP.sweep.$$"
  { [ -f "$KS_MAP" ] && cat "$KS_MAP"
    printf '%s
' "$_pu" | sed -n 's/^package:\([^ ]*\) uid:\([0-9][0-9]*\)$/\2 \1/p'
  } 2>/dev/null | sort -u > "$_kmtmp" && mv -f "$_kmtmp" "$KS_MAP" 2>>"$LOG"
  rm -f "$_kmtmp" 2>/dev/null
  _n=$(grep -c . "$KS_MAP" 2>/dev/null || echo 0); _nskip=0
  # Promote any bundle the restore staged for THIS user (NWP-20261112-01: keystore-in/<uid>, one file per package
  # name), so this is driven off the files we actually have rather than off every installed package.
  # NWP-20261113-05: each bundle's namespace comes from the sweep's own `pm` capture above, the whole
  # `package:<pkg> uid:<n>` line matched exactly (a prefix of a listed package does not match), so the sweep costs ONE
  # `pm` call however many bundles there are; a package the capture does not list gets "", and keystore_register looks
  # it up itself (and counts it unresolvable), as before. The grant arm runs this sweep on the login path.
  #
  # ⚠ NWP-20261119-08: THE STAGING IS BATCHED. keystore_register used to prepare the import dir and chmod, chown and
  # restorecon each staged file on every call: two restorecons per bundle, each loading the file contexts afresh,
  # inside the grant op, which holds the RW slot and, through GRANT-PERMS, the daemon's session lock (0.5.49 on
  # frankel: the worker held 122.55 s). Now the loop calls keystore_register in batch mode, which only resolves the
  # namespace, keeps the KS_MAP row and mv's the bundle, and appends the namespace to KS_BATCH. The dir is prepared
  # ONCE before the loop, and ONE chmod, chown and restorecon run over every staged path after it. The sweep's execs
  # are a fixed number, plus one grep and one mv per bundle (neither loads file contexts), plus pm, grep, head and sed
  # (and the SKIPPED line's date) for a bundle the capture does not list. `$(ks_in_dir)` in each call is a subshell
  # fork of a shell function, not an exec. The restorecon names the staged paths only, never -R on KS_IMPORT: the dir
  # holds other users' bundles.
  local _kad _kpk _kns _knl='
' _kpu _kaf _kbn _nst=0
  _kpu="$_knl$_pu$_knl"; KS_BATCH=""
  if _kad=$(ks_in_dir) && [ -d "$_kad" ]; then
    for _kaf in "$_kad"/*.keys; do [ -e "$_kaf" ] && break; done
    # keystore2 (keystore user) must OWN+traverse the dir: it reads bundles here AND rewrites/removes them as the
    # create-path hook consumes each alias (DIA-20260729); root:root 0700 blocked try_import silently. A failed mkdir
    # is #132 (DIA-20260813-04): name it in our log, and still attempt the mv's. Every line of this block carries the
    # same tag, so the block can be addressed whole.
    if [ -e "$_kaf" ]; then   # NWP-20261119-08: import dir, once
      mkdir -p "$KS_IMPORT" 2>>"$LOG" || echo "[roamd] keystore stage FAILED: cannot create $KS_IMPORT -- carried sign-in will NOT land (#210/#132) $(date)" >> "$LOG"   # NWP-20261119-08: import dir, once
      chmod 0755 "$KS_IMPORT" 2>>"$LOG"; chown keystore:keystore "$KS_IMPORT" 2>>"$LOG"; restorecon "$KS_IMPORT" 2>>"$LOG"   # NWP-20261119-08: import dir, once
    fi   # NWP-20261119-08: import dir, once
    for _inf in "$_kad"/*.keys; do
      [ -e "$_inf" ] || continue
      _kpk=${_inf##*/}; _kpk=${_kpk%.keys}; _kns=""
      case "$_kpu" in *"${_knl}package:$_kpk uid:"[0-9]*)
        _kns=${_kpu#*"${_knl}package:$_kpk uid:"}; _kns=${_kns%%"$_knl"*} ;;
      esac
      case "$_kns" in *[!0-9]*) _kns="" ;; esac
      keystore_register "$_kpk" "$_kns" batch >/dev/null 2>&1 || _nskip=$((_nskip+1))
    done
  fi
  # KS_BATCH holds namespaces only (keystore_register refuses anything but digits), so splitting it is safe. `set --`
  # sets this function's own positional parameters; the function takes none. keystore2 OWNS each file: it reads it on
  # import and rewrites/removes it as it consumes each alias. A failure line names the count, never a package.
  if [ -n "$KS_BATCH" ]; then
    set --
    for _kbn in $KS_BATCH; do set -- "$@" "$KS_IMPORT/$_kbn.keys"; done
    _nst=$#
    chmod 644 "$@" 2>>"$LOG" || echo "[roamd] keystore stage: chmod failed on $_nst staged bundle(s) -- keystore2 may not read them (#210/#132) $(date)" >> "$LOG"
    chown keystore:keystore "$@" 2>>"$LOG" || echo "[roamd] keystore stage: chown failed on $_nst staged bundle(s) -- keystore2 may not read them (#210/#132) $(date)" >> "$LOG"
    restorecon "$@" 2>>"$LOG" || echo "[roamd] keystore stage: restorecon failed on $_nst staged bundle(s) -- keystore2 may not read them (#210/#132) $(date)" >> "$LOG"
  fi
  echo "[roamd] keystore sweep registered $_n package(s) before teardown ($_nskip unresolvable), $_nst bundle(s) staged (#737, NWP-20260827-06, NWP-20261119-08) $(date)" >> "$LOG"
  return 0
}

keystore_register() {
  _p="$1"
  # NWP-20261119-08: $3 = "batch" only from keystore_register_all. Batch mode skips what the sweep runs once for every
  # bundle (the keystore dir and unit mirror, the import dir, the staged file's chmod/chown/restorecon) and the dates,
  # and appends the namespace to KS_BATCH. Without it every line runs as before (odrestore, the tap).
  local _kb="${3:-}"
  # NWP-20260830-03: THE OPT-IN GATE IS GONE. It read the chooser's keepkeys list and returned 1 for any
  # package not on it; with the switch removed that list does not exist, so every call would have returned 1
  # and nothing would ever be registered or promoted.
  # The status still MEANS "registered" (NWP-20260827-05), so callers can count what actually happened.
  # ⚠ NWP-20260827-06: RESOLVE THE NAMESPACE FROM `pm`, NOT /data/system/packages.list.
  #
  # NWP-20260827-05 replaced a `pm list packages` GATE with this packages.list lookup on the belief that it
  # "lists a package whether or not its APK is on disk". THAT IS FALSE, and measuring it on lynx 2026-08-27
  # settled it in one line: of 11 opted-in packages, packages.list contained ZERO. It has 245 entries and no
  # trace of com.walmart.android, while `dumpsys package` knows the app perfectly well (appId=10398). An
  # ARCHIVED placeholder has no APK and no data-dir path, and packages.list is keyed on exactly that.
  # So -05 swapped one lookup that fails for archived apps for another that fails for archived apps.
  #
  # `pm list packages -U -a` is the one that works: `-a` includes archived, `-U` prints the uid, and it
  # returns the FULL namespace (uid:1010398 = user 10, appId 10398) rather than an appId to recompute.
  # Device-measured: 11 of 11 resolvable, against 0 of 11 for packages.list.
  #
  # $2 lets keystore_register_all pass a namespace it already resolved, so the sweep costs ONE `pm` call
  # instead of one per package; the single-package callers (odrestore, the tap) fall through to their own.
  _ns="${2:-}"
  if [ -z "$_ns" ]; then
    _ns=$(pm list packages -U -a --user "$uid" 2>/dev/null | grep -F "package:$_p uid:" | head -1 | sed 's/.* uid://')
  fi
  case "$_ns" in ''|*[!0-9]*)
    echo "[roamd] keystore register SKIPPED $_p -- no uid from pm for user $uid (NWP-20260827-06) $(date)" >> "$LOG"
    return 1 ;;
  esac
  if [ "$_kb" != batch ]; then
    mkdir -p /data/misc/keystore 2>>"$LOG"
    keystore_unit >/dev/null    # ensure the keystore-readable unit-id mirror exists before any export can fire
  fi
  # NWP-20260830-03: KS_KEEP is no longer written. It existed only so keystore2's read_keep_set could learn the
  # opt-in namespaces, and that reader is gone in this same slice. Removing the write also removes a chmod +
  # restorecon PER PACKAGE, which is why the sweep can now cover every app without paying ~245 round-trips on
  # the login path (NWP-20260828-16 is an open latency P0 -- do not put them back).
  grep -q "^$_ns " "$KS_MAP" 2>/dev/null || echo "$_ns $_p" >> "$KS_MAP"
  local _krd
  _krd=$(ks_in_dir) || _krd=""   # NWP-20261112-01: only a bundle restored for THIS user is promoted
  if [ -n "$_krd" ] && [ -f "$_krd/$_p.keys" ]; then
    # DIA-20260813-04 (#132): mkdir failing HERE is exactly how the whole carry died silently on 2026-08-13 --
    # sepolicy denied `keystore_data_file:dir create`, the restored bundle stranded in KS_IN, Amazon opened
    # signed out, and the only trace was a raw avc line in dmesg. Name the failure in OUR log so the next one
    # is a grep away; still attempt the mv (a pre-existing dir makes a failed mkdir harmless, and the mv's own
    # else names the second half).
    if [ "$_kb" != batch ]; then   # NWP-20261119-08: the sweep prepares the dir in batch mode
      mkdir -p "$KS_IMPORT" 2>>"$LOG" || \
        echo "[roamd] keystore stage FAILED for $_p: cannot create $KS_IMPORT -- carried sign-in will NOT land (#210/#132) $(date)" >> "$LOG"
      chmod 0755 "$KS_IMPORT" 2>>"$LOG"; chown keystore:keystore "$KS_IMPORT" 2>>"$LOG"; restorecon "$KS_IMPORT" 2>>"$LOG"   # keystore2 (keystore user) must OWN+traverse the dir: reads bundles here AND rewrites/removes them as the create-path hook consumes each alias (DIA-20260729); root:root 0700 blocked try_import silently
    fi
    # keystore2 rewrites the ns line to match its own view; we only have to name the file by uid.
    if mv -f "$_krd/$_p.keys" "$KS_IMPORT/$_ns.keys" 2>>"$LOG"; then
      if [ "$_kb" = batch ]; then
        KS_BATCH="$KS_BATCH $_ns"
        echo "[roamd] keystore staged $_p -> ns $_ns for import (#210)" >> "$LOG"
      else
        chmod 644 "$KS_IMPORT/$_ns.keys" 2>>"$LOG"; chown keystore:keystore "$KS_IMPORT/$_ns.keys" 2>>"$LOG"; restorecon "$KS_IMPORT/$_ns.keys" 2>>"$LOG"  # keystore2 OWNS it: reads on import, rewrites/removes as it consumes each alias
        echo "[roamd] keystore staged $_p -> ns $_ns for import (#210) $(date)" >> "$LOG"
      fi
    else
      echo "[roamd] keystore stage FAILED for $_p: bundle kept in $KS_IN, not staged to ns $_ns -- carried sign-in will NOT land (#210/#132) $(date)" >> "$LOG"
    fi
  fi
  if [ "$_kb" = batch ]; then
    echo "[roamd] keystore registered $_p ns $_ns for carry (#210)" >> "$LOG"
  else
    echo "[roamd] keystore registered $_p ns $_ns for carry (#210) $(date)" >> "$LOG"
  fi
  return 0
}

# ks_signin_reset UID (NWP-20261108-01): a landed sign-in starts with no other session's Keystore staging.
# THE RULE (DIA-20260803): a bundle is valid ONLY for the login that staged it. keystore-in, the import and export
#   dirs and this uid's map rows can each carry another identity: keystore_register_all, at every `out`, promotes any
#   KS_IN bundle whose package the new user has (a profile with no #apps head never ran keystore_restore, which was
#   the only thing that cleared KS_IN); a dump in KS_EXPORT at a sign-in is a departed identity's (an unfinished reap);
#   and a recycled uid's stale KS_MAP rows name the new session's dumps with the old packages (keystore_register keeps
#   the FIRST row for a ns).
# WHY THE LANDING: called once in the `in` arm after the CE restore succeeded, never above it: a refused, NEEDKEY or
#   failed sign-in is a pure no-op on a live or parked session (NWP-20260822-09, NWP-20261020-01); and before
#   keystore_restore, so this profile's own restored bundles survive it.
# RESIDUAL (docs/backlog.md): keystore-in is not stamped with the session that restored it; the map rows of an OTHER
#   departed uid stay until that uid's next reap. The log carries counts only: no package, ns or profile name.
#   (Superseded by NWP-20261112-01 for keystore-in: it is per uid (ks_in_dir); this removes this uid's dir, flat bundles and departed uids' dirs, and keeps a parked user's.)
#   (Superseded by NWP-20261114-10 for the import dir: a nowhere-import/<ns>.keys whose owner (<ns> less its last five
#   digits) is another user with a record is kept and counted; this uid's, a departed user's, a malformed name and a
#   symbolic link go. Safe only because keystore_push seals only its own uid's imports (ks_ns_mine, NWP-20261114-08).)
ks_signin_reset() {
  local _ksu="$1" _ksa=0 _ksb=0 _ksc=0 _ksd=0 _kse=0 _ksg=0 _ksk=0 _ksj=0 _ksf _ksn _kso _kst _ksr
  case "$_ksu" in ''|*[!0-9]*) _ksu="" ;; esac
  if [ -n "$_ksu" ]; then
    for _ksf in "$KS_IN/$_ksu"/*.keys; do [ -e "$_ksf" ] || continue; _ksa=$((_ksa + 1)); done
    rm -rf "$KS_IN/$_ksu" 2>>"$LOG"
  fi
  for _ksf in "$KS_IN"/*.keys; do [ -e "$_ksf" ] || continue; rm -f "$_ksf" 2>>"$LOG" && _kse=$((_kse + 1)); done
  for _ksf in "$KS_IN"/*; do
    _ksn=${_ksf##*/}
    case "$_ksn" in ''|*[!0-9]*) continue ;; esac
    [ "$_ksn" = "$_ksu" ] && continue
    [ -d "$_ksf" ] && [ ! -L "$_ksf" ] || continue
    if userdir_has_record "$_ksn"; then _ksk=$((_ksk + 1)); continue; fi
    rm -rf "$_ksf" 2>>"$LOG" && _ksg=$((_ksg + 1))
  done
  for _ksf in "$KS_IMPORT"/*.keys; do
    [ -e "$_ksf" ] || continue
    _kso=""; _ksn=${_ksf##*/}; _ksn=${_ksn%.keys}
    if [ ! -L "$_ksf" ]; then
      case "$_ksn" in ''|*[!0-9]*) ;; ??????*) _kso=${_ksn%?????} ;; esac
    fi
    if [ -n "$_kso" ] && [ "$_kso" != "$_ksu" ] && userdir_has_record "$_kso"; then _ksj=$((_ksj + 1)); continue; fi
    rm -f "$_ksf" 2>>"$LOG" && _ksb=$((_ksb + 1))
  done
  for _ksf in "$KS_EXPORT"/*.keys; do [ -e "$_ksf" ] || continue; rm -f "$_ksf" 2>>"$LOG" && _ksc=$((_ksc + 1)); done
  if [ -n "$_ksu" ] && [ -s "$KS_MAP" ]; then
    # NWP-20261124-24: the temp sits beside the map and is renamed over it. An in-place rewrite cut by a power loss or
    #   ENOSPC lost a parked session's ns->pkg rows, and its reap then sealed none of its Keystore dumps.
    _kst="$KS_MAP.signin"
    _ksd=$(grep -cE "^${_ksu}[0-9]{5}( |$)" "$KS_MAP" 2>/dev/null)
    case "$_ksd" in ''|*[!0-9]*) _ksd=0 ;; esac
    grep -vE "^${_ksu}[0-9]{5}( |$)" "$KS_MAP" > "$_kst" 2>/dev/null; _ksr=$?
    if [ "$_ksr" = 0 ] || [ "$_ksr" = 1 ]; then mv -f "$_kst" "$KS_MAP" 2>>"$LOG" || { _ksd=0; echo "[roamd] IN keystore-map rewrite FAILED -- the map is unchanged (NWP-20261124-24)" >> "$LOG"; }; else _ksd=0; fi
  fi
  # NWP-20261124-24: the one removal point of the temp, also of one a power loss left mid-rewrite in /data/nowhere.
  rm -f "$KS_MAP.signin" 2>/dev/null
  echo "[roamd] IN keystore staging reset for user $1: $_ksa bundle(s) left by an earlier session, $_kse flat bundle(s) of an older build, $_ksg departed session dir(s), $_ksk parked session dir(s) kept, $_ksb import(s), $_ksj parked import(s) kept, $_ksc unsealed dump(s), $_ksd map row(s) of an earlier user $1 (NWP-20261108-01, NWP-20261112-01)" >> "$LOG"
  return 0
}

# keystore_restore: pull the name#keys scope at roam-in into keystore-in/<uid> (NWP-20261112-01), where keystore_register promotes each
# bundle once its app's uid exists (keystore_register_all, at every `out`, bundled apps included).
#   (Superseded by NWP-20261113-05: keystore_register_all also runs in the `grant` arm, before switch-in, so an installed
#   bundled app's bundle is staged before the session is handed over; `out` still sweeps whatever is left.)
# RUNS ON EVERY LANDED SIGN-IN (NWP-20261108-06), once, after ks_signin_reset: with an #apps head or without one, a
#   throwaway too. It used to run only after an #apps restore, so a profile that keeps no apps never restored its
#   #keys head, and every sign-out after its first had its #keys push refused for want of a restore receipt
#   (pushProfile's no-receipt guard; an empty head passes it, so the head froze at its first session).
# Best-effort. (Superseded by NWP-20261108-06: "no scope yet (nobody has opted in) is the normal case" -- there is
#   no opt-in since NWP-20260830-03; every app namespace is carried.) An absent head is the new-profile case and
#   costs one agent restore, which every sign-in now pays alike (blind-login parity).
keystore_restore() {
  local _krd
  if ! _krd=$(ks_in_dir); then
    echo "[roamd] IN keystore restore skipped: no user id in scope, 0 bundle(s) staged (NWP-20261112-01)" >> "$LOG"
    return 0
  fi
  rm -rf "$_krd"; mkdir -p "$_krd" 2>>"$LOG" || return 0
  # DIA-20260812-05: backstop, not a stopwatch -- see the note at the #apps ladder. A truncated #keys RESTORE
  # is how an app silently loses its signed-in state after a roam, so a stopwatch here is worse than elsewhere.
  timeout -k 5 3600 "$AGENT" restore s3 "${name}#keys" "$(pw "$pass")" "$_krd" >> "$LOG" 2>&1 || return 0
  _n=$(ls "$_krd" 2>/dev/null | wc -l)
  [ "$_n" -gt 0 ] && print -r -- "[roamd] IN $(qn "$name") #keys restored ($_n bundle(s)) $(date)" >> "$LOG"
  return 0
}

# keystore_push is defined ahead of the op-dispatch (see the forward-ref note there) so the credless cleanstorage
# handler can seal; the roam-in retry below calls the same single definition.
# (Superseded by NWP-20261108-01: the `in` arm no longer calls keystore_push; cleanstorage is its only caller.)
# ---------------------------------------------------------------------------------------------------------

# ---- NWP-20261011-04: THE LOGOFF CUTOFF ---------------------------------------------------------------------
# docs/product-decisions.md, 2026-10-10: "logoff stops the session's apps at its start, before anything is sealed".
# The daemon's handleLogout runs `cutoff` as the first step of a sign-out (after its 2 s onStop window) and
# `cutoffwake` on every exit that keeps the session signed in; core/agent/logoff_cutoff.go has the sequencing.
#
# WHAT A FORCE-STOP DOES, read from the framework source (GrapheneOS 2026061600, LineageOS the same): it kills the
# package's processes in that user, sets its STOPPED flag, cancels the alarms of its whole UID (AlarmManagerService
# removeLocked(uid) on PACKAGE_RESTARTED) and its jobs (JobSchedulerService), drops its notifications and pending
# intents, and -- with the flag set -- keeps implicit broadcasts away from it, FCM included. That is the cutoff:
# nothing can start it again except an explicit launch.
#
# WHAT IT IS NEVER APPLIED TO (cutoff_keep). Each entry is either needed by the logoff itself or a package whose
# force-stop makes the FRAMEWORK change a persistent user setting or a device-wide state -- found by reading every
# PackageMonitor.onHandleForceStop in services/, not assumed:
#   com.nowhere.chooser     the "Saving…" screen (LogoffActivity polls SEAL-STATUS) and CredentialService run here.
#   android                 the framework package itself, not an app: it receives nothing, and stopping it fires
#                           PACKAGE_RESTARTED for the framework in this user (its alarms, jobs, pending intents).
#   com.android.systemui    two persistent harms. WallpaperManagerService CLEARS a wallpaper whose component's package
#                           is force-stopped, and a still image's component IS SystemUI's ImageWallpaper -- every
#                           user's wallpaper would be reset to the default. And its per-user process
#                           (SystemUISecondaryUserService) is started only at a USER SWITCH, so a kept session would
#                           run without it.
#   com.android.bluetooth   not persistent (android:persistent="false"): BluetoothManagerService runs it in the
#                           FOREGROUND user, so a stop kills the stack mid-logoff -- racing the #154 bond capture and
#                           wipe this logoff's own seal and reap perform -- and a kept session loses Bluetooth.
#                           Checked beside it: com.android.nfc, com.android.networkstack, com.android.se and
#                           com.android.cellbroadcastservice are persistent (user 0 only), so `--user <uid>` never
#                           touches them; Telecom runs inside system_server under the system uid, which the shared-uid
#                           rule below keeps with `android`.
#   ...providers.media.module  MediaProvider is this user's /storage FUSE daemon. When it dies StorageUserConnection
#                           calls resetUser, which StorageManagerService implements as "reset everything" (H_RESET):
#                           every volume of every user remounted, mid-seal, under the gate too. The google-signed
#                           module carries the second name; listing both costs nothing.
#   the alarm clock's owner Chester, 2026-10-11: "Never stop the alarm app". The daemon passes it (roam.req line 7,
#                           from the session's last SET-GATE-ALARM relay). Stopping it cancels the alarm, the logoff's
#                           post-seal relay then reads none, and its clear deleted the gate's copy: it never rang.
#                           ITS LIMITS: only the owner of the NEXT alarm clock is kept -- getNextAlarmClock() is all the
#                           public API exposes, so a second alarm app's alarms are cancelled; an alarm whose showIntent
#                           is null names no owner, so none is kept; and an app that misuses setAlarmClock for something
#                           else is kept running through the seal. On a sign-out that FAILS, cutoffwake's boot re-arm is
#                           the remedy for the other alarm apps; on one that lands they go with the session anyway.
#   the selected IME        InputMethodManagerService resets default_input_method and picks a new default when the
#                           selected keyboard's package is force-stopped: the user's keyboard choice would be lost.
#   enabled a11y services   AccessibilityManagerService removes a force-stopped package's services from
#                           enabled_accessibility_services and PERSISTS that: they would be switched off for good.
#   a11y shortcut targets   the same handler erases and persists a SHORTCUT target (accessibility_shortcut_target_service,
#                           accessibility_button_targets, accessibility_qs_targets) whose service requests the
#                           accessibility button, enabled or not -- and this stop runs BEFORE the seal, so it would roam.
#   voice recognition and   VoiceInteractionManagerService shuts down and re-initialises the current interactor or
#   interaction services    recognizer when its package is force-stopped (voice_interaction_service,
#                           voice_recognition_service).
#   live wallpaper          the WallpaperManagerService clear above, for a wallpaper that is not SystemUI's. Read from
#                           /data/system/users/<uid>/wallpaper_info.xml (system_data_file, which this domain may read;
#                           `dumpsys wallpaper` is denied on an enforcing Endospore build). The file is binary XML
#                           (ABX) since Android 12, whose attribute values are stored as plain bytes, and the component
#                           is written only for a LIVE wallpaper (WallpaperDataParser skips ImageWallpaper).
#   always-on VPN app       the framework restarts an always-on VPN only at user unlock, on a package update or when
#                           it is set (VpnManagerService); a kept session would be left without its tunnel -- and,
#                           with "Block connections without VPN", without ANY network.
#   ...and every package that SHARES A UID with a kept one. A force-stop's alarm and job cancellation is per UID, and a
#   shared-uid process hosting both packages dies with either, so stopping a sibling would undo the keep.
# Not kept, deliberately: the keyboard's PROCESS recovers by itself (the IME binding reconnects after
# TIME_TO_RECONNECT_MS, 3 s); the launcher is restarted by the activity manager the moment home is shown; telephony's
# SMS intake is the gate's receiver in USER 0, which a `--user <uid>` stop never touches; mediad is a native daemon,
# torn down by the sweep after this, not a package.
#
# ⚠ THE PROFILE'S PACKAGE NAMES NEVER REACH THE LOG -- counts only. A per-package line would make roam.log a roster of
# what this profile has installed, the #39 class. The record of what was stopped is $STATE/.cutoff.<uid> (and its
# .new/.tmp scratch), 0600 on the RAM tmpfs: gone at power-off, removed by cutoffwake and by cleanstorage at the reap.
CUTOFF_BUDGET="${NOWHERE_CUTOFF_BUDGET:-45}"   # seconds per op (each pass, the wake); the worker never wedges a logoff
CUTOFF_PAR="${NOWHERE_CUTOFF_PAR:-8}"         # calls in flight at once: ~250 serial `am` calls would cost ~15 s
CUTOFF_SYSUSERS="${NOWHERE_CUTOFF_SYSUSERS:-/data/system/users}"

# cutoff_pkgok <name>: a plain package name -- it becomes an argument to `am` and `pm`.
cutoff_pkgok() {
  case "$1" in ""|-*|.*|*[!A-Za-z0-9._]*) return 1 ;; esac
  return 0
}

# cutoff_prog <word>: one progress line for the daemon's stall clocks (a NEW line each call, so it reads as progress).
cutoff_prog() {
  [ -n "${NOWHERE_PROGRESS:-}" ] || return 0
  CUTOFF_TICK=$(( ${CUTOFF_TICK:-0} + 1 ))
  echo "cutoff $1 $CUTOFF_TICK" > "$NOWHERE_PROGRESS.tmp" 2>/dev/null && mv -f "$NOWHERE_PROGRESS.tmp" "$NOWHERE_PROGRESS" 2>/dev/null
  return 0
}

# cutoff_keep <uid> <alarm owner or ""> -> " pkg pkg ... ", space-delimited at both ends: the packages the cutoff
# never stops (above), before the shared-uid widening. A setting that cannot be read adds nothing -- the fixed entries
# still hold. Each read is bounded. settings uses </dev/null stdio: its OUTPUT is captured, as vpn_apply_choice does;
# it is cmd's fd-passing that su:s0 cannot (DIA-56).
cutoff_keep() {
  local _k _v _a _s
  _k=" com.nowhere.chooser android com.android.systemui com.android.bluetooth com.android.providers.media.module com.google.android.providers.media.module "
  cutoff_pkgok "$2" && _k="$_k$2 "
  # The settings that name a package the framework would reset or not restart on a force-stop (above). Every value is
  # a colon-separated list of components or packages, so one shape covers all of them: the package is the part before
  # "/". NWP-20261011-04 round 3 adds the accessibility SHORTCUT targets -- onPackagesForceStoppedLocked also erases
  # and persists a shortcut target whose service requests the accessibility button, enabled or not -- and the voice
  # recognition / interaction services, which VoiceInteractionManagerService re-initialises on a force-stop.
  for _s in default_input_method always_on_vpn_app enabled_accessibility_services accessibility_shortcut_target_service \
            accessibility_button_targets accessibility_qs_targets voice_recognition_service voice_interaction_service; do
    _v=$(timeout -k 2 10 settings get --user "$1" secure "$_s" </dev/null 2>/dev/null)
    # set -f: the split is unquoted, so a "*" or "?" in a value would otherwise expand against the working directory.
    set -f
    for _a in $(echo "$_v" | tr ':' ' '); do
      _a=${_a%%/*}; cutoff_pkgok "$_a" && [ "$_a" != null ] && _k="$_k$_a "
    done
    set +f
  done
  # The live wallpaper's package, system and lock alike: every "<pkg>/<class>" in the file whose package has a dot.
  # Keeping one more package than needed costs nothing; missing the live one resets the user's wallpaper. In ABX a
  # string is preceded by its 2-byte length, whose low byte is a printable letter for a 65-122 byte value and would
  # then read as the name's first character -- so the name without its first character is kept as well.
  for _a in $(grep -a -o '[A-Za-z][A-Za-z0-9_]*[.][A-Za-z0-9_.]*/[A-Za-z0-9_.$]*' "$CUTOFF_SYSUSERS/$1/wallpaper_info.xml" 2>/dev/null); do
    _a=${_a%%/*}; cutoff_pkgok "$_a" && _k="$_k$_a "
    _a=${_a#?}; cutoff_pkgok "$_a" && _k="$_k$_a "
  done
  printf '%s' "$_k"
}

# cutoff_list <uid>: the user's packages with their stopped flag and uid, one
# "package:<name> stopped=<true|false> uid:<uid>" per line (PackageManagerShellCommand -U --show-stopped). Bounded.
cutoff_list() {
  timeout -k 2 20 pm list packages --user "$1" -U --show-stopped </dev/null 2>/dev/null
}

# cutoff_keepuids <keep>: reads cutoff_list lines, prints " uid uid ... " -- the uids of the kept packages.
cutoff_keepuids() {
  local _l _p _u _o=" "
  while IFS= read -r _l; do
    case "$_l" in "package:"*" uid:"*) ;; *) continue ;; esac
    _p=${_l#package:}; _p=${_p%% *}; _u=${_l##* uid:}
    case "$_u" in ""|*[!0-9]*) continue ;; esac
    case "$1" in *" $_p "*) case "$_o" in *" $_u "*) ;; *) _o="$_o$_u " ;; esac ;; esac
  done
  printf '%s' "$_o"
}

# cutoff_filter <keep> <keep uids> <true|false>: reads cutoff_list lines, prints the names whose stopped flag is $3,
# minus <keep> and minus every package sharing a kept uid. A name that is not a plain package name is dropped.
cutoff_filter() {
  local _l _p _f _u
  while IFS= read -r _l; do
    case "$_l" in "package:"*" stopped="*) ;; *) continue ;; esac
    _p=${_l#package:}; _p=${_p%% *}
    _f=${_l#* stopped=}; _f=${_f%% *}
    [ "$_f" = "$3" ] || continue
    cutoff_pkgok "$_p" || continue
    case "$1" in *" $_p "*) continue ;; esac
    _u=""; case "$_l" in *" uid:"*) _u=${_l##* uid:} ;; esac
    case "$_u" in ""|*[!0-9]*) ;; *) case "$2" in *" $_u "*) continue ;; esac ;; esac
    echo "$_p"
  done
}

# cutoff_run <verb> <uid> <file> <deadline epoch>: for every package named in <file>, run `am force-stop` (verb stop),
# `pm unstop` (verb unstop) or the boot re-arm broadcasts (verb boot), CUTOFF_PAR at a time, each call bounded, and
# nothing new started once the deadline has passed. Writes a progress line per batch; CUTOFF_RAN is how many it started.
cutoff_run() {
  local _p _n=0
  while IFS= read -r _p; do
    cutoff_pkgok "$_p" || continue
    [ "$(date +%s)" -lt "$4" ] || break
    if [ "$1" = stop ]; then
      timeout -k 2 10 am force-stop --user "$2" "$_p" </dev/null >/dev/null 2>&1 &
    elif [ "$1" = unstop ]; then
      timeout -k 2 10 pm unstop --user "$2" "$_p" </dev/null >/dev/null 2>&1 &
    else
      # An explicit-package broadcast (-p) is not an implicit one, so no background-execution limit applies to it.
      # --allow-fgs-start-reason (round 4): a real boot sends these with getTemporaryAppAllowlistBroadcastOptions, so a
      # target-31+ boot receiver may start a foreground service (Conversations does); without the allowance that start
      # fails. 202 / 200 are PowerExemptionManager.REASON_LOCKED_BOOT_COMPLETED / REASON_BOOT_COMPLETED, the codes
      # UserController uses; ActivityManagerShellCommand takes the flag in both trees and root passes the check.
      { timeout -k 2 10 am broadcast --user "$2" -p "$_p" --include-stopped-packages --allow-fgs-start-reason 202 -a android.intent.action.LOCKED_BOOT_COMPLETED </dev/null >/dev/null 2>&1
        timeout -k 2 10 am broadcast --user "$2" -p "$_p" --include-stopped-packages --allow-fgs-start-reason 200 -a android.intent.action.BOOT_COMPLETED </dev/null >/dev/null 2>&1; } &
    fi
    _n=$((_n + 1))
    if [ $((_n % CUTOFF_PAR)) -eq 0 ]; then wait; cutoff_prog "$1"; fi
  done < "$3"
  wait
  CUTOFF_RAN=$_n
  cutoff_prog "$1"
}

# bootwake_list <uid> [<form file>] (NWP-20261114-01): every package of the user that declares a receiver for
# LOCKED_BOOT_COMPLETED or BOOT_COMPLETED, once each, one per line, in first-seen order. Two bounded reads, one per
# action. ⚠ The `--components` output form (one "<pkg>/<component>" per line, maybe indented) is read from
# PackageManagerShellCommand, not yet from a device. The parse is lenient: leading blanks are stripped, any other line
# is dropped, and a name that is not a plain package name is dropped, so an unknown form gives an empty list and the
# bootwake op sends nothing.
# NWP-20261128-37: with a <form file>, it also writes `<parsed> <none> <other>` there, the counts of the non-empty
# lines of both listings: parsed = a component line that passed the checks (counted before the dedup), none = exactly
# "No receivers found" (AOSP's runQueryIntentReceivers prints it for an empty result; read from AOSP source, not from
# a device), other = every other line, so the unknown form above is counted. A failed write is silent and changes
# nothing else: the counts are evidence, the list is the wake.
bootwake_list() {
  local _a _l _p _v _o=" " _np=0 _nn=0 _no=0
  for _a in android.intent.action.LOCKED_BOOT_COMPLETED android.intent.action.BOOT_COMPLETED; do
    _v=$(timeout -k 2 20 pm query-receivers --user "$1" --components --include-stopped-packages -a "$_a" </dev/null 2>/dev/null)
    # Not a pipe into the loop: a pipe runs the loop in a subshell, and the dedup set _o would be lost.
    while read -r _l; do   # the default IFS: read strips the leading and the trailing blanks
      [ -n "$_l" ] || continue
      if [ "$_l" = "No receivers found" ]; then _nn=$((_nn + 1)); continue; fi
      case "$_l" in *" "*|*"	"*) _no=$((_no + 1)); continue ;; ?*/?*) ;; *) _no=$((_no + 1)); continue ;; esac
      _p=${_l%%/*}
      cutoff_pkgok "$_p" || { _no=$((_no + 1)); continue; }
      _np=$((_np + 1))
      case "$_o" in *" $_p "*) continue ;; esac
      _o="$_o$_p "; echo "$_p"
    done <<EOT
$_v
EOT
  done
  if [ -n "${2:-}" ]; then echo "$_np $_nn $_no" 2>/dev/null > "$2"; fi
  return 0
}

# NWP-20261113-15: the scope tokens of the `in` arm's landing line, one per best-effort restore (#de, then #media):
# `+<scope>` for exit 0, `-<scope>` for `skip` (the per-user dir did not exist, so nothing ran), `!<scope>(rc=<n>)`
# for any other status. A clean sign-in prints exactly `+de +media`, byte-identical to the literal the line printed
# before. Only the agent's numeric exit status is printed: no name, path or package.
in_scope_tokens() {
  local _ist_out="" _ist_rc _ist_s
  for _ist_s in de media; do
    if [ "$_ist_s" = de ]; then _ist_rc="$1"; else _ist_rc="$2"; fi
    case "$_ist_rc" in
      0) _ist_out="${_ist_out:+$_ist_out }+$_ist_s" ;;
      skip) _ist_out="${_ist_out:+$_ist_out }-$_ist_s" ;;
      *) _ist_out="${_ist_out:+$_ist_out }!$_ist_s(rc=$_ist_rc)" ;;
    esac
  done
  printf '%s' "$_ist_out"
}

# NWP-20261117-02 (decision 2026-10-28, its sixth bullet, docs/product-decisions.md): the `out` op holds the kernel
# wakelock nowhere_seal for the whole seal. Without it a periodic or sign-out seal started with the screen on stalled
# when the screen went off: one seal on frankel took 20 m 35 s, 803 s of it with the CPU suspended. The model is
# nowhere_otad.sh (WLNAME, wl_release, susp); the lock has its own name, so the two never release each other.
# A leaked KERNEL wakelock never expires: it has no owner and no timeout, so the phone does not suspend again until
# it reboots. The traps in the `out` arm are the guard, and that arm is the only place that takes or releases it.
# Only SEAL_WL_S0 (the suspend count at the acquire, set by the arm) is global.
SEAL_WL=nowhere_seal
seal_wl_release() { echo "$SEAL_WL" > /sys/power/wake_unlock 2>/dev/null; }
seal_susp() { cat /sys/power/suspend_stats/success 2>/dev/null || echo "?"; }
seal_wl_end() {
  local _swe_s1 _swe_d=unknown
  _swe_s1=$(seal_susp)
  # Each count is tested on its own: mksh reads a non-number in arithmetic as 0 with no error.
  case "${SEAL_WL_S0:-}" in
    ''|*[!0-9]*) ;;
    *) case "$_swe_s1" in ''|*[!0-9]*) ;; *) _swe_d=$((_swe_s1 - SEAL_WL_S0)) ;; esac ;;
  esac
  echo "[roamd] out wakelock $SEAL_WL released (suspends during seal: $_swe_d) $(date)" >> "$LOG"
  seal_wl_release
}

# NWP-20261104-14 (Q037): queued users/<n> of earlier timeout/blind reaps, re-checked before any read-write-lane op.
# NWP-20261114-15 (#67): and, first, the queued FBE-tree and extra paths of earlier residue or husk reaps (reap_retry_run).
# The guard is load-bearing on both lines: the read-only lane's ops are arms of this same case (see userdir_recheck).
_sumt=$(_ms)   # NWP-20261130-08: the `in` arm writes these two steps' time as its first reap line
[ "$LANE" = rw ] && reap_retry_run
[ "$LANE" = rw ] && userdir_recheck
case "$op" in
  in)
    # NWP-20261003-01: this op's verdict for the SSAID clean-up below. Only the OK branch sets it, as it writes
    # its reply.
    _inres=""
    _uefloor=$(uiderrors_floor_take)   # NWP-20261010-06: committed only with the OK reply below
    # NWP-20261020-01: the commit arm PARKS the per-login entries of $STATE here instead of deleting them, so a
    # sign-in whose CE restore fails can put them back. _parked is set only by a park THIS run created.
    PARK="$STATE/.in-park"; _parked=0
    _odoff=0   # NWP-20261130-03: 1 = this sign-in skips no parked app's data (the commit arm or the shipped list failed)
    # NWP-20261010-15: a session for this uid starts here, so neither carry may capture until THIS session has
    # applied it (vpn_seal_capture / sync_seal_capture). Keyed by uid, so a straggler sign-in -- always a new user --
    # cannot clear the live session's markers.
    rm -f "$STATE/.vpnapplied.$uid" "$STATE/.syncapplied.$uid" "$STATE/.syncfp.$uid" "$STATE/.syncbo.$uid" \
      "$STATE/.syncretry.$uid" "$STATE/.vpndeferred.$uid" "$STATE/.vpnretry.$uid" 2>/dev/null
    rm -f "$STATE/.navapplied.$uid" "$STATE/.aodapplied.$uid" 2>/dev/null   # NWP-20261108-17: nav/AOD likewise
    rm -f "$STATE/.a11yapplied.$uid" 2>/dev/null   # NWP-20261108-15: same reason, for a11y_seal_capture
    rm -f "$STATE/.autofillapplied.$uid" 2>/dev/null   # NWP-20261109-15: same reason, for autofill_seal_capture
    # NWP-20260923-02: ONE deadline for every heal in this sign-in. The vault and #de restores each fetch what
    # their head still carries deferred (core/agent/media_heal.go), and the daemon's 60-minute ceiling covers
    # this whole op, so the heals share 40 minutes from here rather than taking a budget each. What is left at
    # the deadline stays deferred and the next sign-in continues.
    export NOWHERE_HEAL_UNTIL=$(( $(date +%s) + 2400 ))
    # NWP-20261122-09: this sign-in's restore and parked summary for the issue report (signinSummaryAppend,
    # od_parked_report; core/agent/signin_summary.go). Per uid, so a refused or later attempt -- always a new user --
    # never touches a live or parked session's record. The rm drops a recycled uid's leftover.
    case "$uid" in ''|*[!0-9]*) ;; *) rm -f "$STATE/signin-summary.$uid" 2>/dev/null
      export NOWHERE_SIGNIN_SUMMARY="$STATE/signin-summary.$uid" ;; esac
    _ssum reap "$_sumt"   # NWP-20261130-08: reap_retry_run and userdir_recheck, which ran before this file existed
    # #84 P3d: a predecessor's media daemon is stopped at the head of the landing branch, after the scope verdict
    # (NWP-20261117-16, NWP-20261124-05).
    # #81: a FIDO2-enrolled profile needs a security key at login (2FA). The check is a cheap head read (no
    # key); only if enrolled do we adopt the NFC pre-assert or force USB host mode + assert the key (one touch)
    # and export the hmac the restore's resolveKey consumes. If NO key is asserted, we DON'T blank-restore an
    # empty session (it could never seal -> "not backed up" -> strands): the NEEDKEY guard below returns to the
    # gate to obtain the key. Non-fido2 profiles are untouched.
    #
    # STASH DISCIPLINE (device-proven on `c` 2026-07-16): this attempt's assertion lands in fresh_hmac, and
    # $STATE/.fido2hmac is replaced ONLY WHEN THE LOGIN COMMITS (proceeds past the NEEDKEY guard). Clearing it
    # up-front let a STRAGGLER login -- the gate re-firing seconds after a successful switch -- get refused
    # NEEDKEY yet still rm the LIVE session's stash, after which every one of that session's seals and key ops
    # failed ("no slot opens" / ERR-PUSH) until a re-login. A refused login must be a pure no-op on the session.
    # #81: is this profile key-protected (2FA)? One cheap head read; drives BOTH the USB assert path and the
    # NEEDKEY guard below (so a keyless sign-in on a 2FA profile can't strand an unsealable empty session).
    # NWP-20261020-01: the probe's STATUS is kept. 0 = enrolled, 1 = no head / not a vault / no fido2 slot, 5 =
    # exitStoreUnreachable (a store read that failed after its retries), anything else = could not read. Only 5 and
    # "anything else" are could-not-tell: reading them as "not enrolled" committed a key-enrolled profile's sign-in
    # with no key and no hmac stash, so the live session ran keyless and its cold lock wrote `nokey`.
    fido2_needed=0; _probe=""
    "$AGENT" fido2-is-enrolled s3 "$name" "$(pw "$pass")" 2>/dev/null
    case $? in
      0) fido2_needed=1 ;;
      1) ;;
      5) _probe=unreachable ;;
      *) _probe=unknown ;;
    esac
    fresh_hmac=""
    if [ -n "$_probe" ]; then
      # Could not tell whether a key is needed: take none of the adoption, the USB assert or the commit arm.
      # A pre-asserted hmac was made for THIS attempt, so no later sign-in may adopt it.
      rm -f "$STATE/.fido2hmac.pre"
      if [ "$_probe" = unreachable ]; then
        print -r -- "[roamd] IN $(qn "$name") BLANK NET (the key check could not reach the store) $(date)" >> "$LOG"
        echo "BLANK NET" > "$RES"
      else
        print -r -- "[roamd] IN $(qn "$name") BLANK (the key check could not read the store) $(date)" >> "$LOG"
        echo "BLANK" > "$RES"
      fi
    elif [ -f "$STATE/.fido2hmac.pre" ]; then
      # #81 item 5 (NFC): the gate already asserted the key over NFC (FIDO2-NFC-ASSERT, chooser-driven) and
      # pre-stashed the hmac -- adopt it and SKIP the USB path (no key sits in the USB-C port on the NFC path).
      # Consume the marker so it can't be reused by a later login.
      print -r -- "[roamd] fido2 profile $(qn "$name") -> adopting the NFC pre-asserted hmac $(date)" >> "$LOG"
      fresh_hmac="$(cat "$STATE/.fido2hmac.pre")"
      rm -f "$STATE/.fido2hmac.pre"
    elif [ "$fido2_needed" = 1 ] && [ "$keymode" = "nfcfirst" ]; then
      # NWP-20260824-05: NFC-FIRST. Do NOT flip USB. Fall through with an empty fresh_hmac so the NEEDKEY
      # guard below answers, and the GATE parks with its reader armed and no login in flight -- which is the
      # only state in which a tap can actually be serviced. It is not an RF problem: the chooser refuses to
      # build an NFC verb while loginInProgress is true, ROAM-IN holds sessionMu for the whole restore so a
      # concurrent assert would block on it anyway, and this script reads .fido2hmac.pre exactly ONCE, above,
      # before this point. So the tap has to happen BEFORE the login, not during it.
      print -r -- "[roamd] fido2 profile $(qn "$name") -> NFC-first: no USB flip, returning NEEDKEY $(date)" >> "$LOG"
    elif [ "$fido2_needed" = 1 ]; then
      print -r -- "[roamd] fido2 profile $(qn "$name") -> requesting the security key $(date)" >> "$LOG"
      usb_host on; sleep 2
      # NWP-20260823-09: the 4th arg is the state dir -- the agent caches this session's NON-SECRET slot spec
      # there, and cold-lock carries it into the marker so a PIN resume can re-assert without the passphrase.
      fresh_hmac="$("$AGENT" fido2-hmac s3 "$name" "$(pw "$pass")" "$STATE" 2>> "$LOG")"
      usb_host off
    fi
    if [ -z "$_probe" ] && { [ "$fido2_needed" = 0 ] || [ -n "$fresh_hmac" ]; }; then
      # This login COMMITS (a wrong passphrase lands as an OK throwaway, so it commits and replaces the session;
      # a login whose CE restore then FAILS puts the parked per-login state back -- NWP-20261020-01): swap the stash
      # to THIS attempt's assertion. #81: the RAM-tmpfs stash lets EVERY subsequent seal (periodic sync,
      # app/prefs capture, and the logoff seal) open the key-protected vault WITHOUT re-touching the key each
      # time -- the hmac is deterministic per (credId,salt), so caching it is exactly reusing what the key
      # would return. Gone on power-off/reap, 0600, same treatment as the passphrase in .roamsession. Cleared
      # (not replaced) for a non-fido2 profile so it can't inherit a stale one.
      # NWP-20261020-01: every per-login entry below is PARKED, not deleted, when the park can be made (else:
      # deleted, see below). The commit arm runs before the CE restore (NWP-20260822-07), and $STATE is boot-lifetime
      # and shared by every login, so a sign-in that never lands (a straggler over a live session, a fresh one over a
      # COLD-LOCKED session the owner can still resume) would otherwise have destroyed the state of a session that
      # still exists: pushProfile refuses every seal of a non-empty head that has no restore receipt. A park left by
      # a killed run is discarded here, and this op never restores it. When THIS run cannot make the park, the else
      # DELETES the six entries instead, as before NWP-20261020-01, so the moves below find nothing to move and a
      # sign-in that does not land puts nothing back. The plain mkdir fails when this tmpfs is out of INODES, not bytes (on tmpfs a
      # mkdir costs an inode and no data pages, and nowhere.rc mounts $STATE size=256m with no nr_inodes, so a $STATE
      # full by bytes still gets its park), on a kernel ENOMEM, or when a stale park rm could not clear is still there.
      # Moving into a missing park would fail for a file, keeping the previous profile's .fido2hmac, and would RENAME
      # restore-receipts to the park path, where nothing puts it back and the next commit's rm discards it; moving
      # into a stale one would mix the session's entries with a killed run's.
      # NWP-20261129-17 (h59 #2): after OK this op leaves the park. The daemon drops it once the session marker is
      # written, and puts it back on ERR-UNRECORDED, on BLANK NET after the restore and when the next op on the lane
      # finds an abandoned `in` (core/agent/in_park.go). Two residuals: (a) a daemon that dies between its marker and
      # dropInPark leaves the park, which the next commit discards here; (b) a daemon that dies between this op's OK
      # and its marker also leaves the park, and nothing restores it (the restarted daemon records "(daemon start)",
      # not "in", and cannot tell (a) from (b)), so a cold-locked session resumed after that keeps the attempt's
      # receipts, as before this slice, until the next commit discards the park.
      rm -rf "$PARK" 2>> "$LOG"
      if mkdir "$PARK" 2>> "$LOG"; then
        _parked=1
      else
        for _pn in restore-receipts media.restore-ok .btlogoff .had_account .fido2hmac .fido2slots; do rm -rf "$STATE/$_pn" 2>> "$LOG"; done
        print -r -- "[roamd] IN $(qn "$name") could not make the park -- per-login state deleted, not parked $(date)" >> "$LOG"
      fi
      [ -e "$STATE/.fido2hmac" ] && mv "$STATE/.fido2hmac" "$PARK/" 2>> "$LOG"
      if [ -n "$fresh_hmac" ]; then
        # DIA-20260812-03 (#106): same fix as the cold-resume path above -- this is the LOGIN one. printf is
        # external on Android, so this put the second vault factor in a world-readable argv on every 2FA login.
        print -rn -- "$fresh_hmac" > "$STATE/.fido2hmac"; chmod 600 "$STATE/.fido2hmac"
        NOWHERE_FIDO2_HMAC="$fresh_hmac"
        export NOWHERE_FIDO2_HMAC
      fi
      # NWP-20260822-09: EVERY per-login reset of $STATE belongs HERE, in the COMMIT arm -- never at the top of
      # `in)`. This arm's condition IS "this login commits"; its complement is the NEEDKEY refusal below. The
      # stash discipline documented 30 lines above already learned this the hard way for .fido2hmac, and the
      # sentence it ends with is the general rule, not a fido2 detail: A REFUSED LOGIN MUST BE A PURE NO-OP ON
      # THE SESSION. These four files were the rest of the family, and three of them were getting it wrong.
      #
      # ⚠ restore-receipts (#72) was the DANGEROUS one. A straggler NEEDKEY -- the gate re-firing seconds
      # after a successful switch -- used to delete the LIVE session's
      # receipts, and the agent's pushProfile refuses any
      # push over a non-empty store head without one. Every scope with data (vault, #de, #media, #sys, #apps,
      # #keys) was then refused for the rest of that session, self-sustainingly, because only a SUCCESSFUL push
      # writes a receipt. The logoff is loud (handleLogout in the agent's
      # main.go keeps the session signed in and does NOT reap), so
      # the loss landed at power-off or a re-login. FIDO2 profiles only -- the same population as the
      # .fido2hmac bug, which is why both belong in this one arm.
      #
      # ⚠ .btlogoff and .had_account were never cleared at login AT ALL, on any path:
      #   .btlogoff   -- set at logoff (sweepmedia), consumed by `out)`. But `out)` is ALSO the 120s periodic
      #                  seal, and only its rc=0 arm consumes it, so a FAILED logoff seal left it set. The
      #                  comment at that consumer says the marker survives "so the retry -- or the next login's
      #                  reset -- still clears it"; there was no such reset. The next successful periodic seal
      #                  then ran bt_reset "" on a LIVE user -- adapter off, /data/misc/bluedroid deleted,
      #                  nothing restored -- and the seal after that captured the emptied dir and sealed it
      #                  over the profile's pairings. Exactly the harm that consumer's comment claims to avoid.
      #   .had_account -- device-global, written at placement, and acct_reload RETURNS EARLY for a profile with
      #                  no #sys hold, so it never reaches the arm that clears it. Profile A's flag therefore
      #                  outlived A and made accountless profile B's #sys seal fail the #743 zero-row check on
      #                  every seal for the rest of the boot, each time asserting a PERMANENT-destruction
      #                  hazard that did not exist. Nothing was lost; a real guard just became routine noise.
      #
      # Ordering within the login still matters and is preserved: this runs before any `restore`, so the #72
      # receipts and media.restore-ok are still absent when the restores that write them begin (NWP-20260822-07).
      [ -e "$STATE/restore-receipts" ] && mv "$STATE/restore-receipts" "$PARK/" 2>> "$LOG"
      for _pn in media.restore-ok .btlogoff .had_account; do [ -e "$STATE/$_pn" ] && mv "$STATE/$_pn" "$PARK/" 2>> "$LOG"; done
      # NWP-20261130-03: this session's unfetched lists start EMPTY here, at the commit, never at the top of the op (a
      # refused sign-in must not touch them). A failure turns the skip off for this sign-in; the pushes still name
      # the paths, so a missing list refuses the seal rather than sealing unguarded.
      rm -rf "$STATE/odfetch.$uid" 2>> "$LOG"
      if ! { mkdir -m 700 "$STATE/odfetch.$uid" && ( : > "$STATE/odfetch.$uid/unfetched.ce" ) && ( : > "$STATE/odfetch.$uid/unfetched.de" ); } 2>> "$LOG"; then
        _odoff=1; echo "[roamd] IN odfetch state could not be made -- every app's data fetched at sign-in (NWP-20261130-03) $(date)" >> "$LOG"
      fi
    # NWP-20260823-11 (fixing -10, which was INERT): .fido2slots belongs to THIS login's profile -- $STATE is
    # boot-lifetime and shared by every login, so a passphrase-only profile that enrolls its first key
    # mid-session must not cold-lock carrying the PREVIOUS profile's credId. But -10 put a bare `rm` here, in
    # the commit arm, which runs AFTER the assert at the top of this op that WRITES the spec -- so every keyed
    # login deleted its own freshly-cached spec, marker line 7 came out empty, and the whole PIN-resume feature
    # did nothing. The assert now writes .fido2slots.pre and this arm PROMOTES it, which also keeps a REFUSED
    # login from overwriting the live session's spec (the straggler rule in the STASH DISCIPLINE note above).
    [ -e "$STATE/.fido2slots" ] && mv "$STATE/.fido2slots" "$PARK/" 2>> "$LOG"
    if [ "$fido2_needed" = 1 ] && [ -f "$STATE/.fido2slots.pre" ]; then
      mv "$STATE/.fido2slots.pre" "$STATE/.fido2slots" 2>> "$LOG"
    fi
    rm -f "$STATE/.fido2slots.pre" 2>> "$LOG"
    fi
    # CE storage of a RUNNING user is unlocked (the chooser started user N before triggering us). The CE
    # restore is the login GATE -- if its ref doesn't resolve (wrong creds / no profile) the user lands
    # empty == blind login; DE + media + app code below are best-effort completeness on top of a valid CE login, except
    # that a restore of one of them that cannot reach the store (exit 5) ends the sign-in as BLANK NET (NWP-20261124-05,
    # NWP-20261201-16).
    # NWP-20261029-06: the bare restore below stages a claim seed in $STATE. A copy left by an earlier sign-in
    # that never reached the install (a BLANK, a crash) belongs to another moment and must never be installed
    # for this one, so it goes before the restore, not only after the install.
    rm -f "$STATE/claims.seed" 2>> "$LOG"
    # NWP-20261124-05: _ceok is set when the vault restore landed; _innet names the scope (de, media or apps) whose restore
    # could not reach the store. The verdict after this chain reads both.
    _ceok=""; _innet=""
    if [ -n "$_probe" ]; then
      :   # the key check could not tell: answered above, before the commit arm
    elif [ "$fido2_needed" = 1 ] && [ -z "$fresh_hmac" ]; then
      # #81 item 5: key-protected profile, but NO key was asserted (the user signed in without tapping the NFC
      # key / inserting the USB key). REFUSE the keyless roam-in -- a 2FA session with no cached hmac can never
      # SEAL ("no slot opens" -> "not backed up") and would strand as an empty running user. Signal the gate to
      # obtain the key instead (its NFC reader is armed; a tap re-runs the login WITH the asserted hmac). NOT
      # recorded as a session, so there's nothing to reap-seal -- and the LIVE session's stash stays untouched
      # (the commit block above never ran; testing fresh_hmac, not the stash file, is what keeps a stale live
      # stash from waving a keyless straggler THROUGH the guard).
      print -r -- "[roamd] IN $(qn "$name") NEEDKEY (2FA, no key asserted) $(date)" >> "$LOG"
      echo "NEEDKEY" > "$RES"
    elif od_shipped_prep && NOWHERE_PARK_KEEP="$(od_park_var keep)" NOWHERE_PARK_SHIPPED="$(od_park_var shipped)" NOWHERE_UNFETCHED_LIST="$(od_park_var ce)" NOWHERE_PHASE=apps NOWHERE_CLAIMS_SEED="$STATE/claims.seed" "$AGENT" restore s3 "$name" "$(pw "$pass")" "$USERDIR" >> "$LOG" 2>&1; then
      _ceok=1
      _sumt=$(_ms)
      relabel_launcher "$uid" "$USERDIR"   # rewrite home-layout serial so the launcher keeps it (see above)
      remap_media_db "$uid" "$USERDIR"   # NWP-20261124-01: repoint the roamed MediaStore index; before remap_per_pkg/restorecon, which re-own and relabel any -wal/-shm it creates
      _tt=$(_ms); remap_per_pkg "$USERDIR"; _tlog reown-ce "$_tt"
      # -D ("apply to /data/data too") is REQUIRED. toybox restorecon REFUSES to descend into app-data
      # trees without it, so `restorecon -R` on /data/user/N relabels NOTHING -- it considers the userdir
      # root and stops. Measured on lynx 2026-08-06 with a dry run: `-R` -> 7 paths, `-R -D` -> 1566.
      # Every restored file has therefore kept whatever label the untar gave it, for as long as this has
      # existed. It was invisible because the one relabel it DID attempt (the userdir root) is denied and
      # that denial was dontaudit'd as harmless noise -- which it is; the harm was everything it never
      # reached. (DIA-20260806-10)
# DIA-20260806-15: the -D was REMOVED from the app-data walks above, and this is why.
#
# `-D` ("apply to /data/data too") makes toybox restorecon descend into app data. Descending reaches
# libselinux's pkgdir_selabel_lookup(), which contains an aliasing bug: `info->uid += userid_from_path *
# AID_USER_OFFSET` mutates an entry in the PROCESS-GLOBAL pkgTab cache, so the Nth lookup of a package within
# one restorecon process derives a userid of N x the real one. For user 10 that walks the MCS user category
# c522 -> c532 -> c542 -> ... +10 per entry, in fts order. Measured on lynx: 743/798 CE entries and 446/500 DE
# entries mislabelled, across 202 of 202 category-bearing packages -- Launcher3, contacts, MTP and
# cellbroadcast all crashing with "Permission denied" on their own databases.
#
# It stayed invisible until today because BOTH halves had to land: -D made the path reachable (DIA-20260806-10)
# and selinux_check_context (DIA-20260806-11) removed the denial that had been rejecting every corrupted label
# before it could be written. Before that grant, restorecon_sb() failed security_check_context() and returned
# WITHOUT calling lsetfilecon -- which is also why the DIA-20260806-11 roam looked clean.
#
# And that is the part worth keeping: in the roam that "proved" -D, restorecon wrote ZERO app-data labels. The
# labels were already correct before it ran, because a file created inside an app-data directory inherits that
# directory's context. The premise of the -D change -- that restored files would otherwise carry wrong labels
# -- was never demonstrated, and the evidence now says it was false.
#
# The libselinux bug is fixed separately (editions/endospore/build/patches/libselinux-pkgdir-uid-aliasing.sh),
# so -D would be safe again. It is still not re-enabled here: nothing needs it.
      _tt=$(_ms); restorecon -R "$USERDIR" 2>> "$LOG"; _tlog restorecon-ce "$_tt"
      _ssum reown "$_sumt"
      # Roam completeness: also restore device-encrypted per-user app data and the shared media tree
      # (photos, downloads, files), each on its own store ref (name#de / name#media) so a fresh profile
      # simply has none yet and the restore is a harmless no-op. Best-effort: a failure here other than exit 5 does
      # not un-gate the (already valid) CE login. Exit 5 (the store could not be reached) goes to the verdict after
      # this chain (NWP-20261124-05). NWP-20261113-15: each restore's outcome is kept (_derc / _mdrc: its exit
      # status, or `skip` when the dir is absent) for the IN line below; the tail still runs only on 0.
      DEDIR="/data/user_de/$uid"
      _derc=skip
      [ -d "$DEDIR" ] && { NOWHERE_PHASE=secure NOWHERE_PARK_KEEP="$(od_park_var keep)" NOWHERE_PARK_SHIPPED="$(od_park_var shipped)" NOWHERE_UNFETCHED_LIST="$(od_park_var de)" "$AGENT" restore s3 "${name}#de" "$(pw "$pass")" "$DEDIR" >> "$LOG" 2>&1; _derc=$?; }
      if [ "$_derc" = 0 ]; then
        _sumt=$(_ms)
        remap_media_db "$uid" "$DEDIR"   # NWP-20261124-01: MediaProvider is directBootAware; same order rule as the CE call
        _tt=$(_ms); remap_per_pkg "$DEDIR"; _tlog reown-de "$_tt"; _tt=$(_ms); restorecon -R "$DEDIR" 2>> "$LOG"; _tlog restorecon-de "$_tt"
        _ssum reown "$_sumt"
      fi
      # NWP-20261124-05: a #de restore that could not reach the store ends the sign-in (the verdict below). The
      # account, MMS, #media and #apps steps would spend minutes failing on the same dead network, so none of them runs.
      if [ "$_derc" = 5 ]; then _innet=de; fi
      if [ -z "$_innet" ]; then
        _sumt=$(_ms)
        acct_restore "$uid"   # #DIA-20260802-02: restore the AccountManager account rows (name#sys) BEFORE provisionRoamedApps installs the authenticator
        _ssum acct "$_sumt"
        # #148: the MMS `part._data` column stores an ABSOLUTE /data/user_de/<sealing-uid>/ path with the user
        # id baked in. The CE mmssms.db (restored with the apps phase) and the DE app_parts files (restored just
        # above) both roam to THIS user, but the paths INSIDE the db still name the OLD user -> MmsProvider.openFile
        # rejects them cross-user -> the MMS attachment renders BLANK and the "unknown-thread" conversation can't be
        # deleted (device-proven: db under /data/user/10, _data=/data/user_de/11/...). remap_per_pkg only rewrites
        # file-tree paths, not sqlite column contents, so rewrite the column to THIS user here. Bounded to the
        # cross-user part rows, best-effort + non-fatal: a wrong/failed rewrite only leaves an already-broken
        # attachment broken, never loses data. nowhere_db_fix + radio_data_file rw are already granted (the gate
        # janitor scrubs the same db class). Runs before Messaging's post-login provider sync reads the rows.
        # NWP-20261124-27: the log line reports the tool's exit status; it used to say "remapped" whatever the
        # tool returned, so a missing tool or a locked/malformed db read as success in an issue report.
        TELDB="/data/user/$uid/com.android.providers.telephony/databases/mmssms.db"
        if [ -f "$TELDB" ]; then
          # DIA-20260817-01 (#732): nowhere_db_fix `mms-remap` runs the identical UPDATE; the sqlite3 form
          # was userdebug-only, so restored MMS attachments never remapped on a `user` build. Still
          # best-effort for the same reason as before -- a failed rewrite leaves an already-broken
          # attachment broken, never loses data -- so the status is logged (uid and exit code only, never
          # the db path or the tool's text; its stderr goes to the log as before) and never fails the sign-in.
          /system/bin/nowhere_db_fix mms-remap "$TELDB" "$uid" </dev/null >/dev/null 2>> "$LOG"
          _mmsrc=$?
          case "$_mmsrc" in
            0) echo "[roamd] remapped MMS part._data -> user $uid $(date)" >> "$LOG" ;;
            126|127) echo "[roamd] MMS part._data NOT remapped -- /system/bin/nowhere_db_fix missing or not executable (rc=$_mmsrc, user $uid; attachments of restored MMS may show blank) (NWP-20261124-27) $(date)" >> "$LOG" ;;
            *) echo "[roamd] MMS part._data remap FAILED rc=$_mmsrc (user $uid; attachments of restored MMS may show blank) (NWP-20261124-27) $(date)" >> "$LOG" ;;
          esac
          unset _mmsrc
        fi
        MEDIADIR="/data/media/$uid"
        _mdrc=skip
        [ -d "$MEDIADIR" ] && { NOWHERE_PHASE=media "$AGENT" restore s3 "${name}#media" "$(pw "$pass")" "$MEDIADIR" >> "$LOG" 2>&1; _mdrc=$?; }
        if [ "$_mdrc" = 0 ]; then
          _sumt=$(_ms)
          restore_media_tail "$MEDIADIR"
          _ssum reown "$_sumt"
          insert_deferred_media "$uid" "$USERDIR" "$DEDIR"   # NWP-20261130-02: the Gallery's rows for media not yet downloaded
        fi
        rm -f "$STATE/media.rows" 2>> "$LOG"   # NWP-20261130-02: the session's file names, gone on every path
        if [ "$_mdrc" = 5 ]; then _innet=media; fi
        # App CODE restore (#200): restore the opted-in user-installed APK bytes (the name#apps scope) into the
        # USER-0 chooser's files dir so the device-owner chooser can PackageInstaller them back for the roamed
        # user (the su:s0 worker can't pm-install -- the device-owner wall). Root writes there, then chown+relabel
        # to the chooser's user-0 uid so it reads its own files. An absent scope (nothing opted in) or a failed
        # restore just leaves no .appcode → the chooser installs nothing, and the sign-in lands. The exception is
        # exit 5, the store could not be reached (NWP-20261201-16, docs/product-decisions.md, "twenty answers to
        # harvest 60 ...", #5): that ends the sign-in at the verdict below, which is why this block runs before it
        # and not with the landing steps. The chooser deletes .appcode after install (amnesia); we rm it first so a
        # stale set from a prior login can't linger. A #media exit 5 has already ended the sign-in, so it skips this.
        if [ -z "$_innet" ]; then
          CHOOSER0="/data/user/0/com.nowhere.chooser/files"
          APPCODE="$CHOOSER0/.appcode"
          rm -rf "$APPCODE"
          # _tt spans the WALL of the agent invocation (fork + conf + head resolution + restore), which the
          # agent's own key=/restore= line does NOT fully cover -- head= starts inside the process. The delta
          # between this and the agent's head+restore sum is process start + pw() staging + rm/mkdir.
          _tt=$(_ms)
          # _aprc is the agent's exit status, or `skip` when it never ran (no chooser files dir, or the mkdir failed).
          _aprc=skip
          if [ -d "$CHOOSER0" ] && mkdir -p "$APPCODE" 2>>"$LOG"; then
            NOWHERE_PHASE=appcode "$AGENT" restore s3 "${name}#apps" "$(pw "$pass")" "$APPCODE" >> "$LOG" 2>&1
            _aprc=$?
          fi
          if [ "$_aprc" = 0 ] && [ -f "$APPCODE/manifest.tsv" ]; then
            _tlog appcode-agent "$_tt"
            _tt=$(_ms)
            cuid=$(stat -c %u "$CHOOSER0" 2>/dev/null)
            [ -n "$cuid" ] && chown -R "$cuid:$cuid" "$APPCODE" 2>>"$LOG"
            restorecon -R -D "$APPCODE" 2>>"$LOG"
            _tlog appcode-chown "$_tt"
            print -r -- "[roamd] IN $(qn "$name") #apps code restored → user0 chooser $(date)" >> "$LOG"
          else
            _tlog appcode-agent "$_tt"   # the blank/failed arm still reports the wall -- an empty scope's cost was invisible before
            rm -rf "$APPCODE"
          fi
          if [ "$_aprc" = 5 ]; then _innet=apps; fi
        fi
      fi
    else
      # $? is still the vault restore's status: it is the last command run, as the elif's condition. Read it
      # first, before anything else runs.
      _rrc=$?
      # The restore FAILED. Not a wrong passphrase: a head that does not exist restores as "empty -> nothing"
      # and exits 0, and the daemon makes that a throwaway (NWP-20260910-06 corrected the line that said
      # otherwise). Exit 5 is exitStoreUnreachable: the store could not be reached after every retry, so the
      # gate offers a retry and never the last-good-version rollback. A wrong passphrase on the same dead
      # network fails the same way, so the reply says nothing about the profile.
      if [ "$_rrc" = 5 ]; then
        print -r -- "[roamd] IN $(qn "$name") BLANK NET (the store could not be reached) $(date)" >> "$LOG"
        echo "BLANK NET" > "$RES"
      else
        print -r -- "[roamd] IN $(qn "$name") BLANK (restore failed, rc=$_rrc) $(date)" >> "$LOG"
        echo "BLANK" > "$RES"
      fi
    fi
    # NWP-20261124-05: the scope verdict, decided 2026-11-02 (docs/product-decisions.md, "twenty-four answers to the
    # open-decisions list ...", #4, option A): a sign-in whose #de or #media restore could not reach the store (exit
    # 5) does not land. NWP-20261201-16: #apps too ("twenty answers to harvest 60 ...", 2026-11-06, #5). It ends as
    # BLANK NET before every landing step, so the daemon answers BLANK NET (handleRoamIn) and the gate offers a retry
    # only, never the last-good-version rollback. _inres stays unset, so the park put-back and the SSAID clean-up
    # below run as for any sign-in that did not land.
    if [ -n "$_innet" ]; then
      print -r -- "[roamd] IN $(qn "$name") BLANK NET (the $_innet restore could not reach the store) $(date)" >> "$LOG"
      rm -f "$STATE/claims.seed" 2>> "$LOG"
      # acct_restore staged this profile's account rows in CLEARTEXT before a #media or #apps failure; nothing consumes the
      # hold of a uid the chooser abandons. $uid is the user created for THIS attempt (see the SSAID clean-up).
      rm -rf "/data/nowhere/acct-hold-$uid" 2>> "$LOG"
      echo "BLANK NET" > "$RES"
    elif [ "$_ceok" = 1 ]; then
      # NWP-20261117-16: a refused or failed sign-in is a no-op on the live or cold-locked session (the arm's rule),
      # so the stop waits for the landed CE restore. It stays before the OK reply: GRANT-PERMS starts this session's
      # mediad after it, and the sweep detaches every user's mounts. The reap, dropcaches and both media sweeps stop
      # mediad themselves.
      stop_mediad   # NWP-20261117-16: a predecessor's media daemon goes only once this sign-in has landed
      # App provisioning: surface the roamed launchable-app list (the chooser sealed it into its own files
      # dir with the data) into the RAM tmpfs, so the daemon can hand it back to the chooser to reinstall
      # the apps for the fresh user (the worker can't do pm under the device owner).
      ( : > "$STATE/apps.out" )
      [ -f "$USERDIR/com.nowhere.chooser/files/nowhere-apps.list" ] \
        && cp "$USERDIR/com.nowhere.chooser/files/nowhere-apps.list" "$STATE/apps.out" 2>> "$LOG"
      # NWP-20261002-02: surface this profile's own battery-Unrestricted app set (nowhere-doze-apps, sealed with
      # the profile's CE like nowhere-apps.list) into the tmpfs, so the device-owner gate can re-apply it to the
      # Doze allow-list at login via GET-DOZE-APPS (the worker is not the device owner, so it cannot).
      # NWP-20261002-03: a FAILED copy removes the file, so GET-DOZE-APPS answers ERR instead of an empty set
      # that would read as "this profile has no choices" (the gate arms its live record only on a known-good read).
      ( : > "$STATE/doze-apps.out" )
      [ -f "$USERDIR/com.nowhere.chooser/files/nowhere-doze-apps" ] \
        && { cp "$USERDIR/com.nowhere.chooser/files/nowhere-doze-apps" "$STATE/doze-apps.out" 2>> "$LOG" \
             || rm -f "$STATE/doze-apps.out"; }
      ks_signin_reset "$uid"   # NWP-20261108-01: this landed sign-in drops every other session's Keystore staging, before keystore_restore
      # NWP-20261108-06: outside the #apps branch -- a profile that keeps no apps has no #apps head but still carries #keys, and a sign-in that never restores it has every later #keys push refused (no receipt)
      keystore_restore   # #210 p2: pull name#keys; keystore_register promotes each bundle at the tap
      # Roamed prefs (timezone + locale): same surface-from-the-sealed-CE-data trick as the app list, so the
      # user-0 gate can re-apply them on login (the worker can't set tz/locale; the device-owner gate does).
      # NWP-20261016-45: the file also carries netloc=/geocoder= now. The gate ignores them; they are applied by the
      # daemon's locapply claim once the session is recorded, which reads this CE copy (see loc_claim), not prefs.out.
      ( : > "$STATE/prefs.out" )
      [ -f "$USERDIR/com.nowhere.chooser/files/nowhere-prefs" ] \
        && cp "$USERDIR/com.nowhere.chooser/files/nowhere-prefs" "$STATE/prefs.out" 2>> "$LOG"
      # NWP-20261005-08: surface the #129 "download over mobile data" opt-in the same way. The daemon used to read it
      # in place and MLS refuses it /data/user/<uid> (an avc every 30 s; the opt-in never took effect). Keyed by uid
      # so the daemon never answers one session with another's value; anything but "1" is the Wi-Fi-only default.
      if [ "$(cat "$USERDIR/com.nowhere.chooser/files/nowhere-prefetch-metered" 2>/dev/null)" = "1" ]; then
        echo "$uid 1" > "$STATE/prefetch-metered.out"
      else
        echo "$uid 0" > "$STATE/prefetch-metered.out"
      fi
      # NWP-20261011-01: and the profile's "while apps set up" choice -- how long materialisation may hold periodic
      # seals back (2, 10 or 30 minutes, or "run": as long as it runs). Keyed by uid like the opt-in above; anything
      # but the four choices is the 30-minute default. The daemon re-reads it before every periodic decision.
      case "$(cat "$USERDIR/com.nowhere.chooser/files/nowhere-seal-hold" 2>/dev/null)" in
        2) echo "$uid 2" > "$STATE/seal-hold.out" ;;
        10) echo "$uid 10" > "$STATE/seal-hold.out" ;;
        run) echo "$uid run" > "$STATE/seal-hold.out" ;;
        *) echo "$uid 30" > "$STATE/seal-hold.out" ;;
      esac
      # NWP-20261201-03: and the profile's save mode -- when its periodic saves run. Keyed by uid like the two above;
      # anything but wifi or off is Always. The daemon re-reads it before every periodic decision.
      case "$(cat "$USERDIR/com.nowhere.chooser/files/nowhere-save-mode" 2>/dev/null)" in
        wifi) echo "$uid wifi" > "$STATE/save-mode.out" ;;
        off) echo "$uid off" > "$STATE/save-mode.out" ;;
        *) echo "$uid always" > "$STATE/save-mode.out" ;;
      esac
      # NWP-20261102-06 (Q148): add the profile's last time zone to the prefs.out surfaced above, as lasttz= -- the
      # gate's seed (applied with auto-detection on, never an override). From its own sibling file, never nowhere-prefs.
      tz_surface "$USERDIR" "$STATE/prefs.out"
      sroam_surface "$USERDIR" "$STATE/prefs.out"   # NWP-20261130-12 (Q012): the curated settings, for the gate's apply
      # #154: clear the device of whatever Bluetooth state is on it, then lay THIS profile's back down. Running
      # the clear at login as well as logoff is what covers the session ends that never reach a logoff seal --
      # a cold-lock, a battery death, a crash mid-seal. It also makes the next capture self-attributing.
      if bt_reset "$USERDIR"; then
        echo "[roamd] bt: device cleared, $BT_RESTORED profile file(s) restored (user $uid, login) $(date)" >> "$LOG"
      else
        echo "[roamd] bt ERR: device NOT cleared at login (user $uid) -- see the bt ERR above $(date)" >> "$LOG"
      fi
      # #204: LAST restore step -- park each on-demand app's restored CE+DE data into .nowhere-odhold BEFORE the
      # chooser installs its archived placeholder (which would else find the root-owned dir and WIPE it). The tap's
      # odrestore op moves it back + reowns + re-grants perms. Runs after ALL restores/remaps so nothing it moves is
      # still being reowned, and before the OK that lets the chooser run provisionRoamedApps.
      hold_ondemand "$uid"
      od_parked_report "$uid"   # NWP-20261119-17: how much On-demand/Auto data the restores fetched only to park
      # #204 perms carry-forward fix (DIA-20260726-08): reset the on-demand "materialised THIS session" marker at
      # login. capturePerms uses it to decide whether an on-demand app's grants are LIVE-authoritative (materialised
      # this session -> trust the live enum, honour an in-session revoke) or must be CARRIED FORWARD (placeholder all
      # session -> re-emit the sealed grants). The marker lives in the chooser's CE dir, which is SEALED + RESTORED --
      # so it ROAMS and accumulates rather than self-clearing (the UnarchiveService "ephemeral -> self-clears" comment
      # is wrong: the ephemeral USER is new each login, but its CE *content* is restored from the seal). A stale entry
      # makes every later DORMANT session mis-classify that app as materialised-this-session, capturePerms then SKIPS
      # its carry-forward, and its All-files-access + runtime grants silently vanish on the roam (device-proven on
      # lynx: markor lost storage perms after a no-tap roam). rm (not truncate) so the chooser recreates it chooser-
      # owned on the next tap; absent == empty for capturePerms's reader. Runs after hold_ondemand so the (now stale)
      # restored marker is gone before the chooser can materialise anything this session.
      rm -f "$USERDIR/com.nowhere.chooser/files/nowhere-od-materialised" 2>>"$LOG"
      # DIA-20260804: same reset for the RESTORE-CONFIRMED marker, and for the same reason. The chooser skips a
      # group dep that is both installed AND restored, so a marker surviving into a NEW session would let the
      # first tap skip a dep whose data has NOT been restored here -- and for gms that means odrestore never
      # runs, so acct-deferred is never cleared and the account never comes back. This session's own restores
      # re-create it. Sits next to the materialised reset so the pair cannot drift apart.
      rm -f "$USERDIR/com.nowhere.chooser/files/nowhere-od-restored" 2>>"$LOG"
      # NWP-20261012-05: and grant_perms_for's "declines already applied this session" list, for the same reason --
      # it is per SESSION, and the uid of a new session can be one a previous session used.
      rm -f "$STATE/.declined.$uid" 2>>"$LOG"
      rm -f "$STATE/.granted.$uid" 2>>"$LOG"   # per session: a new session can reuse a uid (NWP-20261025-10)
      rm -f "$STATE/.a11ydone.$uid" 2>>"$LOG"   # and a11y_apply's record, for the same reason (NWP-20261108-18)
      rm -f "$STATE/.autofilldone.$uid" 2>>"$LOG"   # and autofill_apply's record, for the same reason (NWP-20261112-12)
      rm -f "$STATE/.odbatch3.$uid".* 2>>"$LOG"   # and a RESTORE-ODDATA list's -3 read, per session (NWP-20261125-08)
      # NWP-20261012-06: and its Keep-installed twin (UnarchiveService.INSTALLED_RESTORED), for the same reason: a
      # tap on Your apps' "Wake for notifications" wakes a Keep-installed app only if this session's restore of it
      # answered OK, so a marker from an earlier session would let it wake an app over data that is not back.
      rm -f "$USERDIR/com.nowhere.chooser/files/nowhere-installed-restored" 2>>"$LOG"
      # DIA-20260804-04: and the switched-off-app drop list, for the SAME reason -- it is a LOGOFF artifact
      # that happens to live in the chooser's CE dir, so it seals, roams and is restored like the two markers
      # above. Left in place it would be read by every PERIODIC seal of THIS session (syncLoop drives the same
      # roamd `out` op every 120s, not just logoff) using the PREVIOUS session's decisions -- dropping an app
      # the user has since switched back On, or one that an OTA has since made BUNDLED, whose data is the
      # profile itself. That matters because the last periodic seal is the authoritative head for any session
      # that does NOT end in a clean logoff: cold-lock seals nothing, the 12h backstop wipes without sealing,
      # and an unclean power-off is why the sync loop exists at all. captureAppDrops re-creates this at the
      # next logoff, so the only cost of clearing it is that mid-session periodic seals carry a switched-off
      # app's data -- the SAFE direction, since the logoff seal still drops it.
      rm -f "$USERDIR/com.nowhere.chooser/files/nowhere-appdrop.list" 2>>"$LOG"
      # NWP-20260830-08: and its code-side companion, cleared on exactly the same terms and for the same
      # reason. captureAppDrops rewrites BOTH together at the next logoff, and a keepcode list that outlived
      # its drop list would retain code for packages nothing is dropping any more. Note the asymmetry with
      # nowhere-apporphan.list, which is NOT cleared here: that one is the standing record of which packages
      # were inferred (never chosen) and it persists with the profile exactly as nowhere-appoff.list does.
      rm -f "$USERDIR/com.nowhere.chooser/files/nowhere-appkeepcode.list" 2>>"$LOG"
      # NWP-20260821-15: and the SESSION-PRESENCE RECEIPT, for the same reason and with the sharpest teeth of the
      # four. captureAppCode prunes a keep-set line when the app was present when this session settled and is
      # absent at logoff -- that is how "uninstall it from Settings" finally stops the roam bringing it back. The
      # receipt is what makes "was present" mean anything, and like the three markers above it lives in the
      # chooser's CE dir, so it SEALS AND RESTORES rather than dying with the ephemeral user (see the correction
      # at the materialised marker above -- the USER is new each login, its CE CONTENT is not). Left in place, a
      # session that never wrote its own snapshot would inherit the PREVIOUS session's list and prune against it:
      # an on-demand app present last time and simply not tapped this time reads as "the user removed it", and its
      # opt-in is deleted. The stamp inside the file already rejects a foreign session, so this rm is the
      # belt-and-braces half -- but it is the half that does not depend on the stamp being right, so it is not
      # optional. Absent == empty for the reader, which prunes NOTHING; every failure mode here loses the prune,
      # never the user's apps.
      rm -f "$USERDIR/com.nowhere.chooser/files/nowhere-appseen" 2>>"$LOG"
      # NWP-20260904-06: and its sibling, the WATCHED-DEPARTURE record. Same reasoning exactly -- it is
      # stamped, but a stale one would let this session prune a keep line on a departure the PREVIOUS
      # session watched, which is a user choice we cannot get back. Absent == empty == prune nothing.
      rm -f "$USERDIR/com.nowhere.chooser/files/nowhere-appgone" 2>>"$LOG"
      # NWP-20260821-17: and the GosPackageState APPLY RECEIPT, same class as the four above and with the same
      # consequence if it survives. GosState.capture may only DROP a sealed hardening-flag row when this
      # session's apply positively confirmed it can write that state -- a denied read is indistinguishable from
      # "no state", so without that gate an image missing gos-chooser-grant.sh would read nothing, write an
      # empty file, and destroy every per-app setting the user had. A receipt restored from the PREVIOUS
      # session's seal would forge exactly that confirmation for a session that never wrote anything. Absent ==
      # not-confirmed for the reader, which carries every row forward untouched -- the safe direction.
      rm -f "$USERDIR/com.nowhere.chooser/files/nowhere-gos-applied" 2>>"$LOG"
      # NWP-20261010-13: and the SMS-app APPLY MARKER, same class again. SmsRoleRoam.capture records the profile's
      # SMS app only once this session's sign-in apply wrote nowhere-sms-applied, because before that the role holder
      # is a fresh user's and would overwrite the choice with Messaging. The marker names its session by the user's
      # serial number, but serials are a per-DEVICE counter: a marker sealed on another handset can carry the very
      # serial this one just minted, and would then forge "applied" for a session that has not applied anything.
      # This rm is the primary defence; the serial is the second lock. Absent == not applied == capture nothing.
      rm -f "$USERDIR/com.nowhere.chooser/files/nowhere-sms-applied" 2>>"$LOG"
      # NWP-20260911-02: and the two halves of the per-app CLAIM handoff, on exactly the same terms as the
      # receipts above. Both live in the chooser CE dir, so both SEAL, ROAM AND ARE RESTORED.
      #
      # nowhere-claims is the enforcement file the seal writes. A restored one describes the claim map as it
      # stood on the OTHER handset at ITS last seal, and the chooser kick fires before this session has
      # sealed anything -- so the first thing a fresh login would do is suspend apps on the strength of a
      # stale record. This session's own first seal rewrites it within one cycle; absent means hold nothing.
      #
      # nowhere-appclaim is the RECEIPT, and it has the sharper teeth of the two -- the same shape as the
      # gos-applied receipt directly above. It is scoped by target user id, and two handsets both mint LOW
      # user ids, so a restored receipt can MATCH this session's user and make applyFromFile believe those
      # packages are already held. The hold then never happens and nothing says so. Absent == this session
      # holds nothing yet, which is the truth at roam-in.
      #
      # Login only, and that matters: a cold-lock RESUME never traverses this block (the only
      # triggerRoamWorkerKind(dest, "in", ...) in the tree is inside handleRoamIn), so a live session's
      # receipt survives a resume -- which is correct, because the hold survives it too.
      rm -f "$USERDIR/com.nowhere.chooser/files/nowhere-claims" 2>>"$LOG"
      rm -f "$USERDIR/com.nowhere.chooser/files/nowhere-appclaim" 2>>"$LOG"
      # NWP-20261029-06 (§B EVERY LOGIN STARTS WITH THE OTHER HANDSET'S APPS TAPPABLE): install the claim
      # file the bare-vault restore staged from the head it had just decrypted, so enforcement has something
      # to read before this handset's first seal. It is installed HERE, after the two rms above, because they
      # delete whatever the roam-in restored and a copy installed earlier would be deleted with it. The owner
      # is the files dir's and is set BEFORE the mv, so the chooser (an app, not root) never sees the file
      # under the wrong owner -- the rule writeClaimsOut states. Any failure leaves NO nowhere-claims, which is
      # today's state (absent == hold nothing). The staged copy is unlinked either way; it names other
      # handsets' packages and lives only in this tmpfs. The count is taken before the hand-over.
      if [ -f "$STATE/claims.seed" ]; then
        _csdst="$USERDIR/com.nowhere.chooser/files/nowhere-claims"
        _csn=$(grep -cv "^#" "$STATE/claims.seed" 2>/dev/null | tr -d " ")
        _csown=$(stat -c "%u:%g" "$USERDIR/com.nowhere.chooser/files" 2>/dev/null)
        if [ -n "$_csown" ] && cp "$STATE/claims.seed" "$_csdst.tmp" 2>> "$LOG" \
           && chown "$_csown" "$_csdst.tmp" 2>> "$LOG" && chmod 600 "$_csdst.tmp" 2>> "$LOG" \
           && restorecon "$_csdst.tmp" 2>> "$LOG" && mv -f "$_csdst.tmp" "$_csdst" 2>> "$LOG"; then
          echo "[roamd] claims seed: ${_csn:-0} package(s) held elsewhere -> installed for user $uid $(date)" >> "$LOG"
        else
          rm -f "$_csdst.tmp" "$_csdst" 2>> "$LOG"
          echo "[roamd] claims seed: NOT installed for user $uid -- nothing is held until the first seal $(date)" >> "$LOG"
        fi
        unset _csdst _csn _csown
      else
        echo "[roamd] claims seed: none -- the restore wrote no seed (user $uid) $(date)" >> "$LOG"
      fi
      rm -f "$STATE/claims.seed" 2>> "$LOG"
      # NWP-20260912-06: and the HELD LIST the chooser now writes, on the same terms as the pair above. It is
      # stamped with the user serial so a restored one reads as foreign anyway, but that is the second lock;
      # this rm is the first. A held list carried in from another handset would otherwise be published under
      # THIS unit id at the first seal -- claiming, in our name, apps the other phone is actually using.
      rm -f "$USERDIR/com.nowhere.chooser/files/nowhere-appheld.list" 2>>"$LOG"
      # #204 (DIA-20260726-08): clear any leftover archived placeholder record from a prior session BEFORE the chooser
      # raises this login's placeholders, so the raise can't collide into a label-less ghost. Reads the ondemand set
      # from the restored .appcode manifest (the exact set about to be raised). Idempotent + self-healing; replaces the
      # fragile logoff-time reap. Must follow hold_ondemand (data already parked) and precede the chooser's raise.
      # NWP-20261125-01: with the uid it CHECKS that park and skips (and lists) an app whose data was left in place.
      _sumt=$(_ms)
      reap_stale_ondemand "$CHOOSER0/.appcode/manifest.tsv" "$uid"
      # DIA-20260730-06 amnesia backstop: reap ANY chooser-provisioned pkg not in THIS profile's manifest (a leak
      # from a different profile / a retained record / a residual user-0 install), so it can't ghost across profiles.
      # DIA-20260811-07: pass the roaming uid explicitly rather than leaning on the global -- roamd helpers reading
      # globals they did not declare is what caused the roam data-loss saga.
      reap_orphan_provisioned "$CHOOSER0/.appcode/manifest.tsv" "$uid"
      _ssum reap "$_sumt"
      # NWP-20261113-15: the scopes are the restores' real outcomes, no longer the fixed literal `(+de +media)`. On
      # lynx 2026102201 (NWP-20261024-18) Wi-Fi was cut during the #media chunk download: roam.log read
      # `ERR: fetch chunk 80 ...` and then `IN "<profile>" -> user 18 (+de +media)`, a sign-in called restored although
      # #media had failed. NWP-20261124-05: that sign-in no longer lands. The decision is recorded in
      # docs/product-decisions.md, "twenty-four answers to the open-decisions list ..." (2026-11-02), #4: a #de or
      # #media restore that could not reach the store (exit 5) ends as BLANK NET at the verdict above, before this
      # line (NWP-20261201-16: an #apps restore too; the tokens never name #apps). Any other #de or #media failure
      # (1: damage, a missing chunk) still lands and is named here as `!<scope>(rc=<n>)`.
      print -r -- "[roamd] IN $(qn "$name") -> user $uid ($(in_scope_tokens "$_derc" "$_mdrc")) $(date)" >> "$LOG"
      _ssum in "$_sum0"
      uiderrors_floor_commit "$_uefloor"   # NWP-20261010-06: this session's lines in uiderrors.txt start here
      echo "OK $uid" > "$RES"; _inres=OK
      # NWP-20261129-17 (h59 #2): the park stays. The daemon drops or restores it once it knows the OK is recorded
      # (core/agent/in_park.go).
    fi
    # NWP-20261020-01: the commit arm moved the session's per-login entries into the park and this sign-in
    # did not land, so put each name back as it was: first remove whatever THIS attempt left there (the restore
    # writes restore-receipts/roster.<ref> before it fails; the commit arm wrote the fresh .fido2hmac and the
    # promoted .fido2slots), then move the parked one back. A name absent before is absent after. Only a park
    # this run created is ever restored here, and a landed sign-in (OK) leaves its own to the daemon.
    if [ "$_parked" = 1 ] && [ "$_inres" != OK ]; then
      _pbn=0
      for _pn in restore-receipts media.restore-ok .btlogoff .had_account .fido2hmac .fido2slots; do
        rm -rf "$STATE/$_pn" 2>> "$LOG"
        if [ -e "$PARK/$_pn" ]; then mv "$PARK/$_pn" "$STATE/$_pn" 2>> "$LOG"; _pbn=$((_pbn + 1)); fi
      done
      rm -rf "$PARK" 2>> "$LOG"
      print -r -- "[roamd] IN $(qn "$name") did not land -- per-login state put back ($_pbn entries) $(date)" >> "$LOG"
    fi
    # NWP-20261130-03: a sign-in that did not land drops its own odfetch state (its uid is abandoned; a straggler is
    # always a new user, so no live session's lists are touched).
    [ "$_inres" != OK ] && [ "$_parked" = 1 ] && rm -rf "$STATE/odfetch.$uid" 2>> "$LOG"
    # NWP-20261003-01: a sign-in that did not land takes its SSAID material with it. SEED-SSAID staged
    # users/<uid>/nowhere-ssaid-seed BEFORE this op ran, and the seed is derived from the passphrase just tried
    # (see seedssaid): a passphrase VERIFIER, in cleartext. SEED-SSAID also runs before the user is STARTED, and
    # this op can take minutes, so an app in the new user may already have asked for its ANDROID_ID. The patched
    # SettingsProvider then CONSUMED the seed: it deleted it and wrote the same 64 hex as the userkey in
    # users/<uid>/settings_ssaid.xml, where the verifier lives on. On every outcome but OK -- NEEDKEY, BLANK for
    # a failed restore (a wrong passphrase is NOT one: it lands as an OK throwaway), BLANK for a store or connection
    # error, where the passphrase may well be the right one -- the
    # chooser abandons this uid for good: it only calls removeUser (stopRoamUser), which runs no CLEAN-STORAGE,
    # and every retry creates a NEW user. So if the framework's own delete of users/<uid> is skipped or fails,
    # either file survives the sign-in and the power-off. Both are removed HERE, after the verdict, because every
    # outcome of this op passes this point. The verdict is the OK branch's own _inres, never a re-read of $RES:
    # the agent deletes $RES the moment it reads a reply, so a re-read can find it gone and take a landed sign-in
    # for one that did not land. Only those two files, and only if they exist: this never creates anything. A
    # SettingsProvider write pending at this point, or an SSAID minted before removeUser runs, puts
    # settings_ssaid.xml back -- SettingsState writes its whole map, the userkey included -- and only the
    # framework's own delete and the boot backstops remain for that. Not on OK -- the framework reads the seed
    # later, and settings_ssaid.xml is then the session's own. It cannot reach a live session's files: $uid is
    # always the user the chooser created for THIS attempt (its one ROAM-IN sender passes createRoamUser's new
    # id).
    case "$_inres" in
      OK*) ;;
      *) for _sf in nowhere-ssaid-seed settings_ssaid.xml; do
           _seed="/data/system/users/$uid/$_sf"
           [ -e "$_seed" ] || continue
           _what="$_sf"; [ "$_sf" = nowhere-ssaid-seed ] && _what="SSAID seed"
           rm -f "$_seed" 2>/dev/null
           if [ -e "$_seed" ]; then
             echo "[roamd] roam-in for user $uid did not land -- its $_what could NOT be removed (NWP-20261003-01) $(date)" >> "$LOG"
           else
             echo "[roamd] roam-in for user $uid did not land -- its $_what removed (NWP-20261003-01) $(date)" >> "$LOG"
           fi
         done ;;
    esac
    # NWP-20260820-33: reclaim the head-blob prefetch cache (staged by the DAEMON at SEED-SSAID, i.e.
    # BEFORE this op ran -- which is why the clear sits HERE and must never move to the prologue: a
    # prologue clear would delete the prefetched blobs the restores above were about to hit). Content is
    # ciphertext named by its own sha256 on the RAM tmpfs; a leftover from a failed login is harmless and
    # power-off wipes it, so this is tmpfs hygiene, not a security step.
    rm -rf "$STATE/headblobs" 2>/dev/null
    ;;
  out)
    # NWP-20260821-19: say when a seal STARTS. This arm's first possible output is conditional and far below,
    # so a long seal logged NOTHING until it finished -- which is exactly why the 94-second seal that blocked a
    # login on 2026-08-21 read as an unexplained gap in the log rather than as a seal. With this, the gap has a
    # name and the agent's workerMu wait line has something to correlate against.
    echo "[roamd] out start user $uid $(date)" >> "$LOG"
    od_block_installed   # NWP-20261130-03: an install no RESTORE-ODDATA followed is not launchable
    # h47 #1 (NWP-20261117-01): the pushes THIS op runs may stop at a chunk boundary when $STATE/.sealstop exists
    # (the agent's seal_stop.go). Only here: cleanstorage's keystore_push runs the same verb, and its retry ladder
    # ends with the reap destroying the dump, so a #keys push must never stop. roamd runs one op per process.
    export NOWHERE_SEAL_STOPPABLE=1
    # NWP-20261117-02: hold nowhere_seal from here to the end of the op. The battery cost is accepted (decision
    # 2026-10-28): the phone stays awake for the length of each seal. The traps are set before the acquire, so a
    # signal between the two still releases. They depart from otad's `trap wl_release EXIT INT TERM HUP` on purpose:
    # that form returns to the op after a TERM, so the seal would run on with no lock. Today an untrapped TERM ends
    # roamd, and these traps keep that (exit 128+signo). `trap - EXIT` stops a second release line at that exit.
    # A SIGKILL runs no trap: the pre-acquire release below, in the next `out` op, or a reboot clears that lock.
    # A refused write never fails a seal; it only logs the WARNING.
    seal_wl_release                      # belt-and-braces, as otad: clears a lock an earlier SIGKILLed op left
    SEAL_WL_S0=$(seal_susp)
    trap seal_wl_end EXIT
    trap 'seal_wl_end; trap - EXIT; exit 130' INT
    trap 'seal_wl_end; trap - EXIT; exit 143' TERM
    trap 'seal_wl_end; trap - EXIT; exit 129' HUP
    if echo "$SEAL_WL" > /sys/power/wake_lock 2>/dev/null; then
      echo "[roamd] out wakelock $SEAL_WL held (suspends since boot: $SEAL_WL_S0) $(date)" >> "$LOG"
    else
      echo "[roamd] out WARNING: /sys/power/wake_lock refused -- the seal can stall while the screen is off (suspends since boot: $SEAL_WL_S0) $(date)" >> "$LOG"
    fi
    bt_seal_capture "$USERDIR"     # #154: snapshot BT bonds into the CE dir so they seal + roam with the profile
    nav_seal_capture "$USERDIR" "$uid"   # NWP-20260914-04: navigation mode, same dir, same seal
    aod_seal_capture "$USERDIR" "$uid"   # NWP-20260922-02: always-on display, same dir, same seal
    a11y_seal_capture "$USERDIR" "$uid"  # NWP-20261108-15: accessibility services + shortcut targets (Q024)
    autofill_seal_capture "$USERDIR" "$uid"  # NWP-20261109-15: the chosen autofill service (Q078), same dir, same seal
    tz_seal_capture "$USERDIR"           # NWP-20261102-06: last time zone (Q148), same dir, same seal
    vpn_deferred_retry "$uid"            # NWP-20261010-15: a VPN deferred for its on-demand app, once it exists
    vpn_seal_capture "$USERDIR" "$uid"   # NWP-20261010-15: always-on VPN + its block, same dir, same seal
    sync_apply_retry "$uid"              # NWP-20261010-15: a sign-in apply that failed is retried (bounded), then
    sync_seal_capture "$USERDIR" "$uid"  # NWP-20261010-15: account sync switches, same dir, same seal
    sroam_seal_capture "$USERDIR" "$uid" # NWP-20261130-12 (Q012): the curated settings allowlist, same dir, same seal
    # Seal while the user is still RUNNING (CE unlocked); the chooser stops+removes it after we return.
    # Seal all three classes (CE + DE + shared media), each to its own ref, mirroring the restore split.
    # (Runtime perms are captured by the chooser at logoff into files/nowhere-perms -- via PackageManager, which
    # reads LIVE state; the on-disk runtime-permissions.xml is written lazily so a su:s0 read here is stale.)
    # #84: the media overlays STAY MOUNTED through a seal. The agent's walker reads each live overlay's
    # bind-hidden .under dir (the real on-disk files) in its place -- stubs stay absent (carried forward by
    # the manifest), real files seal normally, nothing is read through FUSE (media_seal.go). The old per-seal
    # stop_mediad here blinded every RUNNING app about once a minute: the unmount+remount strands running
    # apps' mount-namespace views, and an app scanning inside the window registers nothing (OrganicMaps
    # "maps gone", proven on FP3 2026-07-03). Teardown now happens only where the session actually ends:
    # login-predecessor cleanup (`in`), cold-lock (dropcaches), reap (cleanstorage), and the login daemon's
    # stopMediad right before the LOGOFF seal.
    # #81: a fido2 2FA profile's DK is behind passphrase + key -- the push (seal) can't open the vault with
    # the passphrase alone. Reuse the login-cached hmac stash so the logoff seal opens it WITHOUT a key touch.
    [ -f "$STATE/.fido2hmac" ] && export NOWHERE_FIDO2_HMAC="$(cat "$STATE/.fido2hmac")"
    # DIA-20260804-04: apps the user switched OFF in "Your apps". Until now the keep-set gated only
    # appcode_seal (the APK bytes -> name#apps) while the three data pushes below took the tree WHOLESALE, so a
    # switched-off app's data stayed sealed, billed and roaming forever even though the app was never
    # reinstalled -- invisible dead weight, and it made "Off means it's gone at logoff" false. The chooser
    # writes this list at logoff from the keep-set it already computes (USER-INSTALLED packages only: bundled
    # apps' data IS the profile and must always roam). Exported for ALL THREE scopes because one package's
    # data spans CE, DE and external. Absent/empty file -> the agent drops nothing (previous behaviour).
    DROPLIST="$USERDIR/com.nowhere.chooser/files/nowhere-appdrop.list"
    # NWP-20261102-04 (Q049): the #keys push runs at the reap, after this CE file is gone -- stage a DE-side copy
    # now, whatever this seal's outcome. ~~Off, Stop carrying and inferred orphans only, never a Settings uninstall.~~
    # (superseded by NWP-20261109-20: Off, Stop carrying, inferred orphans, and a Settings or launcher uninstall
    # that captureAppCode's keep-set prune saw go -- recorded through recordTurnedOff and listed by captureAppDrops
    # before this seal.)
    ks_stage_drop "$USERDIR" "$uid"
    # NWP-20260911-01: the claim pair. HELDLIST is written by the chooser (absent = this handset holds
    # nothing, the safe direction); CLAIMSOUT is written by the seal for the chooser to read back.
    HELDLIST="$USERDIR/com.nowhere.chooser/files/nowhere-appheld.list"
    CLAIMSOUT="$USERDIR/com.nowhere.chooser/files/nowhere-claims"
    [ -s "$HELDLIST" ] || HELDLIST=""   # empty var -> the agent reads no held list at all
    # NWP-20260912-06: COUNTS ONLY, never package names -- roam.log sits outside every wipe path and a list of
    # what the user runs, written there, is the #39 identity-roster shape. Without this line the producer is
    # undiagnosable on a user build: a held list that is empty and one that was never written look identical.
    # ⚠ THE FIRST VERSION OF THIS LINE PRINTED 0 FOR BOTH CASES IT EXISTS TO SEPARATE, which made it
    # exactly the useless diagnostic its own comment warns about: `grep -cv "^#"` prints 0 for a
    # comment-only file, and for an ABSENT file grep exits 2 printing nothing, which ${_hln:-0} also
    # renders as 0. Test for the file first and say "none" when it was never written -- the two states
    # mean completely different things (nothing held, versus the producer never ran).
    _hlf="$USERDIR/com.nowhere.chooser/files/nowhere-appheld.list"
    if [ -f "$_hlf" ]; then
      _hln=$(grep -cv "^#" "$_hlf" 2>/dev/null | tr -d " ")
      echo "[roamd] held: ${_hln:-0} package(s) claimed by this handset (user $uid) $(date)" >> "$LOG"
    else
      echo "[roamd] held: none -- the chooser has not written a list this session (user $uid) $(date)" >> "$LOG"
    fi
    unset _hln _hlf
    if [ -s "$DROPLIST" ]; then
      export NOWHERE_DROP_LIST="$DROPLIST"
      # The live keep-set travels with it: the agent refuses to drop anything currently kept, so even a stale
      # drop list (one that survived the roam-in reset) cannot drop an app the user has switched back On.
      export NOWHERE_KEEP_LIST="$USERDIR/com.nowhere.chooser/files/nowhere-appkeep"
      echo "[roamd] out: dropping $(wc -l < "$DROPLIST" 2>/dev/null) switched-off app(s) from the data seal $(date)" >> "$LOG"
    else
      unset NOWHERE_DROP_LIST NOWHERE_KEEP_LIST
    fi
    # rc carries the WORST outcome, and nc remembers whether any scope failed specifically for lack of
    # storage credit (agent exit 3). Collapsing every failure into one string is why the chooser tells a
    # user with no credit to check their connection -- advice that ends at power-off, i.e. the wipe.
    rc=0; nc=0; refused=0; stopped=0   # stopped: h47 #1, a push exited 7 -- nothing more is pushed
    # DIA-20260812-10 (#118): a PER-SCOPE record, because the flat rc/nc/refused triple cannot say WHICH scope
    # failed -- and for three of the six it could not say anything at all. acct_seal (#sys), appcode_seal
    # (#apps) and keystore_push (#keys) are documented "best-effort, never fails the data seal", and that was
    # implemented by discarding their return values. So the identical guards that produce ERR-REFUSED on the
    # vault/#de/#media fired SILENTLY on the other three, and #apps -- the scope whose loss users experience as
    # "all my apps are gone" -- was structurally incapable of reporting failure. Keeping "never fails the data
    # seal" (rc is still untouched by these) while making the verdict EXIST is the whole change.
    parts=""
    _note() { # <scope-label> <cause>
      if [ -z "$parts" ]; then parts="$1=$2"; else parts="$parts,$1=$2"; fi
    }
    # NWP-20261123-06: the SEAL SPLIT -- each scope's wall time and upload KiB, for the daemon's periodic seal line in
    # login.log (syncLoop, takeSealSplit). roam.log holds the same figures per push, but its tail rolls past a long
    # save that login.log still names. Labels and numbers only: the daemon drops a file holding anything else. A
    # scope not pushed is absent; a push that left no stat file (pushProfile writes it from its summary) reads ?KiB.
    split=""
    _split() { # <entry>
      if [ -z "$split" ]; then split="$1"; else split="$split,$1"; fi
    }
    _pstat() { # <stat-file> -> the push's upload KiB, or ?; the file is removed either way
      local _l _k
      _k="?"
      if [ -f "$1" ] && read -r _l < "$1"; then
        _k=${_l#kib=}; _k=${_k%% *}
        case "$_k" in ''|*[!0-9]*) _k="?" ;; esac
      fi
      rm -f "$1"
      echo "$_k"
    }
    _ssplit() { # the split for the daemon, through a tmp + mv: called before EVERY RES write below
      printf '%s\n' "$split" > "$STATE/seal-split.tmp" 2>> "$LOG" && mv -f "$STATE/seal-split.tmp" "$STATE/seal-split" 2>> "$LOG"
    }
    # _cause is defined ONCE, above the early op-dispatch (see the note there). DIA-20260812-10 defined it
    # HERE, which made it unreachable from the credless cleanstorage handler that exits hundreds of lines
    # earlier; #115 needed it there, so it moved rather than being copied. Two copies of a vocabulary is how
    # the two layers drift back apart.
    _push() { # <scope-label> <profile-arg> <dir> [deleted-file] [carry-essential-media] [media-sync-out]
      local _r _c _t0 _k _unf=""
      [ "$stopped" = 1 ] && return 0   # h47 #1: a stopped seal pushes nothing more
      # NWP-20261130-03: the vault and #de seals name their own scope's unfetched list, ALWAYS (a lost file refuses the
      # seal as unfetched-unknown). Every other scope names none.
      case "$1" in
        vault) _unf=$(od_unf_path "$uid" ce) || { echo "[roamd] OUT $1 not pushed: no unfetched list path (NWP-20261130-03) $(date)" >> "$LOG"; rc=1; return 0; } ;;
        de) _unf=$(od_unf_path "$uid" de) || { echo "[roamd] OUT $1 not pushed: no unfetched list path (NWP-20261130-03) $(date)" >> "$LOG"; rc=1; return 0; } ;;
      esac
      rm -f "$STATE/pushstat.$1"; _t0=$(_ms)   # NWP-20261123-06: this scope's wall time and stat (the seal split)
      # NWP-20260908-01: PIN NOWHERE_CARRY_ESSENTIAL OFF HERE. It is exported PROCESS-WIDE at the top of this
      # file, so every agent this daemon runs inherits it -- the vault, #de and #media pushes included. The
      # agent’s own comments claimed the opposite ("which appcode_seal alone sets"), and appcode_seal’s
      # inline re-pass of the same variable reads like scoping while doing nothing. So the day anyone sets it
      # in a ring conf to enable the #apps carry, EVERY scope silently switches to threshold-0 file-aligned
      # chunking and re-uploads once -- on /data/media/$uid that is one region per file over a camera roll,
      # and it carries NOTHING in return (the carry selects by package against a head that has no Apps index).
      # All of the cost, none of the benefit, and no log line anywhere says so.
      #
      # Pinned rather than un-exported because the export is what TestEveryDocumentedConfFlagIsExportedByADaemon
      # matches on, and because an explicit 0 at the call site is the thing a reader checks.
      # NWP-20260908-03: $4 is where THIS scope’s mediad records deletions. The agent used to compute it from
      # the tree it was handed, which is right for the CE scope (mediad’s cache is inside it) and wrong for
      # #media, whose serving daemon caches OUTSIDE the tree under a different name. Passing it explicitly
      # keeps the one true answer with the process that knows it. Empty for every scope that has no daemon.
      # NWP-20260908-21: $6 is where a #media push records the rels it MATERIALIZED this cycle -- another
      # handset's new media, fetched by span so it lands on this phone now rather than at the next login.
      # Empty for every other scope: only #media has a carry to materialize from.
      # NWP-20260911-01: the per-app CLAIM record. $HELDLIST is what the chooser says this handset is
      # holding; $CLAIMSOUT is where the seal writes back what the OTHER handsets hold, which is the list
      # the chooser enforces. Same file-handoff shape as NOWHERE_DROP_LIST, and for the same reason: the
      # seal is a separate agent process, so the daemon's RAM is invisible to it.
      #
      # Passed for EVERY scope on purpose, and the agent -- not this line -- decides which scope owns the
      # index: it publishes claims and writes the enforcement file only for the BARE vault, so the record
      # has one home and two scopes can never disagree about who holds an app. That gate is tested
      # (TestClaims_AScopedSealPublishesNothingAndDoesNotClobberTheEnforcementFile); a second gate here
      # would just be a place for the two to drift apart.
      NOWHERE_CARRY_ESSENTIAL=0 NOWHERE_MEDIA_TOMBSTONES="${4:-}" NOWHERE_CARRY_ESSENTIAL_MEDIA="${5:-0}" \
        NOWHERE_MEDIA_SYNC_OUT="${6:-}" \
        NOWHERE_HELD_LIST="$HELDLIST" NOWHERE_CLAIMS_OUT="$CLAIMSOUT" \
        NOWHERE_PUSH_STAT="$STATE/pushstat.$1" \
        NOWHERE_UNFETCHED_LIST="$_unf" \
        "$AGENT" push s3 "$2" "$(pw "$pass")" "$3" >> "$LOG" 2>&1
      _r=$?; _c=$(_cause "$_r")
      _k=$(_pstat "$STATE/pushstat.$1"); _split "$1=$(( $(_ms) - _t0 ))ms/${_k}KiB"   # NWP-20261123-06
      [ "$_c" = ok ] || _note "$1" "$_c"
      case $_r in
        0) ;;
        3) rc=1; nc=1 ;;
        7) stopped=1 ;;   # h47 #1: stopped at a chunk boundary -- no head after the last whole scope (rc untouched)
        # DIA-20260812-06 (#111): 4 = a GUARD refused this seal, so NOTHING was stored. Before the agent
        # returned a code for it, a refusal exited 0 and landed in the `0)` arm above: roamd logged
        # "OUT ... +de +media", published OK, and the chooser told the user "Saved" while the session's
        # changes were never written. Measured on lynx: 13 consecutive refusals of one scope in 16 hours,
        # 77 MB never stored, every one reported as a successful save.
        #
        # Kept SEPARATE from the generic failure for the same reason ERR-NOCREDIT is -- the correct advice
        # differs. ERR-PUSH means the store was unreachable and retrying is right. A REFUSAL means the
        # stored copy is intact and deliberately protected: retrying changes nothing, and the cause (a short
        # walk, a missing restore receipt, a collapsed head) is what needs attention.
        4) rc=1; refused=1 ;;
        *) rc=1 ;;
      esac
    }
    _push vault "$name" "$USERDIR"
    [ -d "/data/user_de/$uid" ] && _push de    "${name}#de"    "/data/user_de/$uid"
    # NWP-20260908-03: the EXTERNAL mediad serves /data/media/$uid but caches under the CHOOSER’s CE dir, in
    # `.nowhere-media-ext` -- a different root AND a different basename from the CE instance. So the deletion
    # tombstones for this scope live at a path that is NOT under the tree being sealed, and the agent cannot
    # derive it from src. Same wrong-root shape DIA-20260813-06 fixed for the overlay binds; this call site
    # was missed, so external media deletions never propagated at all.
    # NWP-20260908-21: CLEAR THE LIST BEFORE THE PUSH, not after. The agent writes it only when it actually
    # landed something, so a cycle that lands nothing would otherwise leave the PREVIOUS cycle's list in
    # place and re-scan those paths every 120s forever -- wasted work that reads as success.
    rm -f "$STATE/mediasync.list" 2>> "$LOG"
    [ -d "/data/media/$uid" ]   && _push media "${name}#media" "/data/media/$uid" \
                                    "$USERDIR/com.nowhere.chooser/files/.nowhere-media-ext/.deleted" \
                                    "$NOWHERE_CARRY_ESSENTIAL_MEDIA" \
                                    "$STATE/mediasync.list"
    # Hand what landed to the chooser: bytes on disk are NOT in MediaStore. Nothing in this tree has ever
    # triggered a media scan -- what makes a LOGIN work is the volume mount at user start, and there is no
    # mid-session equivalent (NWP-20260908-18, device-proven). The scan must be issued AS THE ROAMED USER,
    # which this daemon is not, so the chooser instance already running there does it.
    #
    # A file plus a nudge, matching every other roamd->chooser handoff. The paths deliberately do NOT ride
    # the broadcast: a space in a filename cannot become a parsing bug, and a big cycle cannot overrun the
    # broadcast size limit.
    if [ "$stopped" = 0 ] && [ -s "$STATE/mediasync.list" ]; then
      _msdst="$USERDIR/com.nowhere.chooser/files/nowhere-mediascan.list"
      # ⚠ TRANSLATE THE PATHS. The agent writes what it wrote: /data/media/$uid/... , the LOWER filesystem.
      # An app -- including our own receiver -- sees that tree as /storage/emulated/$uid/... , and that is the
      # form MediaStore records in _data (device-verified). Handing over the lower path would either be
      # rejected by the receiver bound or indexed under a path no app can open.
      if sed "s|^/data/media/$uid/|/storage/emulated/$uid/|" "$STATE/mediasync.list" > "$_msdst" 2>> "$LOG"; then
        _msown=$(stat -c "%u:%g" "$USERDIR/com.nowhere.chooser/files" 2>/dev/null)
        [ -n "$_msown" ] && chown "$_msown" "$_msdst" 2>> "$LOG"
        chmod 600 "$_msdst" 2>> "$LOG"
        restorecon "$_msdst" 2>> "$LOG"
        # ⚠ COUNT BEFORE THE BROADCAST. The receiver DELETES this list the moment it has read it, so a
        # `wc -l` afterwards races it and prints an EMPTY count -- which is exactly what the first device
        # run logged: "media-sync:  path(s) landed". This is the diagnostic line for the whole feature,
        # so a blank number here is the "count that says nothing" shape in the one place a reader looks
        # first when the sync appears not to be working.
        _msn=$(wc -l < "$_msdst" 2>/dev/null | tr -d " ")
        am broadcast --user "$uid" --include-stopped-packages \
          -n com.nowhere.chooser/.MediaScanReceiver </dev/null >/dev/null 2>&1
        echo "[roamd] media-sync: ${_msn:-0} path(s) landed -> chooser scan (user $uid) $(date)" >> "$LOG"
      fi
      rm -f "$STATE/mediasync.list" 2>> "$LOG"
      unset _msdst _msown _msn
    fi
    # NWP-20260911-01: apply the per-app CLAIM record this seal just wrote. The agent writes
    # $CLAIMSOUT during the vault push -- one line per package another handset is holding, and an EMPTY
    # file when nothing is held elsewhere, because empty is the instruction to RELEASE. The chooser reads
    # it inside the roamed user and suspends or unsuspends to match.
    #
    # Kicked on EVERY out op, which is the periodic seal as well as logoff, so a claim made on the other
    # handset shows up here within a sync interval rather than at the next login. That cadence is the
    # whole latency of the feature and the product decision already accepts it ("knowable minutes late").
    #
    # ⚠ stdio to /dev/null: a su:s0 init script cannot CAPTURE am/pm output (DIA-56), and a redirect to
    # the log is what turned an earlier cross-user cmd into a silent total failure.
    if [ "$stopped" = 0 ] && [ -f "$CLAIMSOUT" ]; then
      _cln=$(grep -cv "^#" "$CLAIMSOUT" 2>/dev/null | tr -d " ")
      am startservice --user "$uid" -n com.nowhere.chooser/.CredentialService \
        --ez claims true </dev/null >/dev/null 2>&1
      echo "[roamd] claims: ${_cln:-0} package(s) held elsewhere -> chooser apply (user $uid) $(date)" >> "$LOG"
      unset _cln
    fi
    # DIA-20260804-08: the drop list applies to the three DATA scopes ONLY. Leaving it exported past this point
    # let it reach acct_seal's #sys stage and appcode_seal's #apps stage, whose trees are not per-user app-data
    # dirs at all. Harmless today (the #sys stage's top level is `ce`/`de`, which cannot collide with a package
    # name -- Android package names must contain a dot), but it is a loaded gun aimed at the account seal, and
    # the seal path is where a silent mis-drop costs the user data. Scope it to the pushes that need it.
    unset NOWHERE_DROP_LIST NOWHERE_KEEP_LIST
    # #DIA-20260802-02 / #199: best-effort seals of the AccountManager rows (name#sys) and of opted-in app CODE
    # (name#apps). "Best-effort" still holds in the sense that MATTERS -- neither touches rc, so neither can fail
    # the data seal, keep the session signed in, or block the reap. DIA-20260812-10 (#118) only stops their
    # verdicts being thrown away: `_sr=$?` instead of nothing. Assign IMMEDIATELY after the call -- any command
    # in between (including a comment-only line is fine, but a `[ ... ]` test is not) would clobber $?.
    # h47 #1: once a push stopped, neither runs (appcode_seal's staging included), and a return of 7 stops the rest.
    _sr=0; _ar=0
    # NWP-20261123-06: both are timed for the seal split. acct_seal runs one push, which reads NOWHERE_PUSH_STAT from
    # the environment: exported around the call and unset after it, because a prefix on a FUNCTION call is left
    # unspecified by POSIX (dash and mksh differ). appcode_seal sets APPCODE_PUSH_MS to its push ladder's wall time,
    # so #apps reads as its staging plus its push. A helper that returns before its push (acct_seal with nothing to
    # seal, appcode_seal with no keep-set) leaves ACCT_PUSHED / APPCODE_PUSH_MS empty, and its scope stays absent.
    if [ "$stopped" = 0 ]; then
      rm -f "$STATE/pushstat.sys"; _t0=$(_ms); ACCT_PUSHED=""; NOWHERE_PUSH_STAT="$STATE/pushstat.sys"; export NOWHERE_PUSH_STAT
      acct_seal "$uid"; _sr=$?
      unset NOWHERE_PUSH_STAT
      _k=$(_pstat "$STATE/pushstat.sys")
      [ -z "$ACCT_PUSHED" ] || _split "sys=$(( $(_ms) - _t0 ))ms/${_k}KiB"
      unset _k
      [ "$_sr" = 0 ] || _note sys "$(_cause "$_sr")"
      [ "$_sr" != 7 ] || stopped=1
    fi
    if [ "$stopped" = 0 ]; then
      rm -f "$STATE/pushstat.apps"; _t0=$(_ms); APPCODE_PUSH_MS=""
      appcode_seal; _ar=$?
      _tw=$(( $(_ms) - _t0 )); _tp=$APPCODE_PUSH_MS; _k=$(_pstat "$STATE/pushstat.apps")
      if [ -n "$_tp" ]; then
        case "$_tp" in *[!0-9]*) _tp=0 ;; esac
        _ts=$(( _tw - _tp )); [ "$_ts" -lt 0 ] && _ts=0
        _split "apps=stage ${_ts}ms+push ${_tp}ms/${_k}KiB"
      fi
      unset _tw _tp _ts _k
      [ "$_ar" = 0 ] || _note apps "$(_cause "$_ar")"
      [ "$_ar" != 7 ] || stopped=1
    fi
    # NB the #keys scope is NOT sealed here. keystore2 dumps those blobs from remove_user, which runs at the
    # REAP -- after this seal -- so keystore_push runs at cleanstorage instead.
    if [ "$stopped" = 1 ]; then
      # h47 #1: SKIP-, because the daemon reads a SKIP- verdict as "ran no seal" (as SKIP-SUPERSEDED). Bluetooth is
      # not cleared: .btlogoff is handled only on a whole seal, in the rc=0 branch below.
      print -r -- "[roamd] OUT $(qn "$name") SKIP-STOPPED -- a sign-out asked this seal to stop; no head after the last whole scope $(date)" >> "$LOG"
      _ssplit
      echo "SKIP-STOPPED" > "$RES"
    elif [ "$rc" = 0 ]; then
      # #154: if this was the LOGOFF seal (sweepmedia dropped the marker), clear the device's Bluetooth state
      # BEFORE publishing OK -- $RES is what releases the caller to front the gate, so a wipe sequenced after it
      # races the next session. Only on a SUCCESSFUL seal: a failed one keeps this session signed in (#86 Fix A),
      # and wiping there would drop a live user's headset mid-call and then seal the emptied device over their
      # profile. The marker survives a failure so the retry -- or the next login's reset -- still clears it.
      # NWP-20261010-10 (round 3): ...and it is honoured ONLY on the logoff's own run (line 6 kind "logoff"). A marker
      # that outlived a failed sign-out -- or that a sweep which timed out wrote AFTER the daemon gave up on it --
      # used to be read by the next PERIODIC seal that landed: bt_reset on a LIVE user, and the seal after that
      # sealed the emptied pairings over the profile. Any other run drops a marker it finds and clears nothing.
      # h49 #13 (NWP-20261119-03): a "logoff-pinned" run is the sign-out's own run too (it stopped a Back up now).
      if [ -f "$STATE/.btlogoff" ] && [ "$skind" != logoff ] && [ "$skind" != logoff-pinned ]; then
        rm -f "$STATE/.btlogoff"
        echo "[roamd] bt: stale logoff marker on a ${skind:-periodic} seal -- dropped, device NOT cleared (user $uid) $(date)" >> "$LOG"
      fi
      if [ -f "$STATE/.btlogoff" ]; then
        if bt_reset ""; then
          rm -f "$STATE/.btlogoff"
          echo "[roamd] bt: device cleared at logoff (user $uid) $(date)" >> "$LOG"
        else
          echo "[roamd] bt ERR: device NOT cleared at logoff (user $uid) -- marker kept for retry $(date)" >> "$LOG"
        fi
      fi
      # DIA-20260812-10 (#118): the DATA scopes landed, so this is still an OK -- the reap may proceed and the
      # session is genuinely saved. But if #sys or #apps did not seal, say which and why, as a SUFFIX. The verb
      # stays OK so every existing reader keeps working (the daemon now prefix-matches; see handleLogout), and
      # a reader that ignores the suffix behaves exactly as it did before.
      if [ -n "$parts" ]; then
        print -r -- "[roamd] OUT $(qn "$name") (user $uid) +de +media -- PARTIAL: $parts $(date)" >> "$LOG"
        _ssplit
        echo "OK PARTIAL:$parts" > "$RES"
      else
        print -r -- "[roamd] OUT $(qn "$name") (user $uid) +de +media $(date)" >> "$LOG"
        _ssplit
        echo "OK" > "$RES"
      fi
    else
      # Name the cause. ERR-NOCREDIT is a DIFFERENT instruction to the user: an offline seal retries by
      # itself, a credit one never will. Any other failure keeps the old string, so nothing that reads
      # only ERR-PUSH changes behaviour.
      # DIA-20260812-10 (#118): the PARTIAL suffix rides every failure verb too. The primary verb still picks
      # the most actionable cause, but it no longer ERASES the others -- before this, a logoff that hit BOTH a
      # credit failure and a guard refusal reported only the credit one, because nc wins this if/elif and the
      # refusal had nowhere else to appear. `_sfx` is empty when nothing else is known, so the three verbs are
      # byte-identical to before in the common case.
      _sfx=""; [ -n "$parts" ] && _sfx=" PARTIAL:$parts"
      if [ "$nc" = 1 ]; then
        print -r -- "[roamd] OUT $(qn "$name") ERR-NOCREDIT$_sfx $(date)" >> "$LOG"
        _ssplit
        echo "ERR-NOCREDIT$_sfx" > "$RES"
      elif [ "$refused" = 1 ]; then
        # DIA-20260812-06 (#111). A THIRD verdict, because it needs a third message. The guard did its job:
        # the stored copy is intact and was protected from being overwritten by a session that could not be
        # sealed completely. But this session's changes are NOT saved, and the next login will restore the
        # older head -- which is what the owner experienced as "all my apps are gone". Saying "couldn't
        # save, your last saved copy is safe" is both true and actionable; saying "Saved" was neither.
        print -r -- "[roamd] OUT $(qn "$name") ERR-REFUSED$_sfx -- a seal guard refused: the stored copy is intact and this session was NOT saved (the PARTIAL list names which scope and why) $(date)" >> "$LOG"
        _ssplit
        echo "ERR-REFUSED$_sfx" > "$RES"
      else
        print -r -- "[roamd] OUT $(qn "$name") ERR-PUSH$_sfx $(date)" >> "$LOG"
        _ssplit
        echo "ERR-PUSH$_sfx" > "$RES"
      fi
    fi
    ;;
  sweepmedia)
    # #84 data-safety (logoff pre-seal teardown): cleanly unmount the media overlays + .under binds NOW, so the
    # LOGOFF seal that follows walks the REAL app dirs directly. The periodic seal deliberately keeps overlays
    # mounted and reads each dir's .under bind (running apps need a stable view); but if a bind is broken/racing,
    # walkChunks SKIPS that dir -- which merely costs a periodic seal one cycle, yet at LOGOFF (no next seal)
    # silently DROPS any newly-downloaded map that isn't yet in the store head. Tearing the overlays down here
    # removes the .under dependency for the final seal: /proc/mounts has no fuse.nowheremedia left, mediaUndersFn
    # returns empty, and the walk reads the plain real dirs -- new files sealed, old deferred entries carried
    # forward by the seen-set rule. The user is leaving, so blinding the (dying) apps no longer matters.
    # NWP-20261010-10 (review): VERIFIED, as coldsweep is. This answered OK without looking, and the daemon did not
    # read the answer either: a mount stop_mediad could not detach let the logoff seal walk the overlay's .under
    # (a false shrink, refused as if this phone's copy were short) and then the reap tried to delete through it.
    # Now the ground truth is read back out of /proc/mounts, the logoff does not seal over a mount that is left,
    # and END-UNSAVED does not tear down over one. The #154 marker is written only on a VERIFIED sweep: a logoff
    # that stops here keeps its session, and the next periodic seal (rc=0) would otherwise read the marker and
    # wipe a LIVE user's Bluetooth.
    # NWP-20261024-15: and the read itself is verified. The count was a grep of /proc/mounts with its error thrown
    # away: a grep that cannot read the table (a sepolicy change that drops this domain's read) exits 2 with nothing
    # on stdout, `wc -l` printed 0, and an UNREAD table answered OK -- the logoff sealed over the overlays this check
    # exists to catch, and the #154 marker armed the next seal's Bluetooth wipe. An unread table must never count as
    # zero: the table is read ONCE with its status kept, and a failed or empty read (no Linux system has an empty
    # mounts table) answers ERR-MEDIA-SWEEP UNREAD, which the daemon refuses like any other non-OK, and marks nothing.
    # NWP-20261115-11: the table never goes to grep as an argument (/system/bin/printf: E2BIG over 128 KiB, so 0 read as OK over live mounts); stop_mediad states the same rule.
    stop_mediad
    _mt=$(cat /proc/mounts 2>>"$LOG"); _mtrc=$?
    _left=-1
    if [ "$_mtrc" -eq 0 ] && [ -n "$_mt" ]; then
      _left=$(grep -c -e " fuse.nowheremedia " -e "/.nowhere-media[^/]*/.under/" <<EOF_MT
$_mt
EOF_MT
)
    fi
    if [ "$_left" -lt 0 ]; then
      echo "ERR-MEDIA-SWEEP UNREAD" > "$RES"
      _said="mount table unreadable"
    elif [ "$_left" -gt 0 ]; then
      echo "ERR-MEDIA-SWEEP $_left" > "$RES"
      _said="$_left media mount(s) left"
    else
      # #154: mark the logoff so the following seal wipes BT bonds from the device. NWP-20261123-26: checked, and a
      # marker that cannot be written says so; the answer stays OK on purpose: the sweep's own verdict is correct,
      # and refusing the sign-out over this marker is not decided.
      if ! ( : > "$STATE/.btlogoff" ) 2>> "$LOG"; then
        echo "[roamd] sweepmedia user $uid: could NOT mark .btlogoff -- this logoff's seal will NOT wipe the Bluetooth bonds (#154) (NWP-20261123-26) $(date)" >> "$LOG"
      fi
      echo "OK" > "$RES"
      _said="0 media mount(s) left"
    fi
    echo "[roamd] sweepmedia (logoff pre-seal teardown) user $uid: $_said $(date)" >> "$LOG"
    unset _left _mt _mtrc _said
    ;;
  coldsweep)
    # NWP-20261004-01: the cold lock's media teardown, BEFORE the user is stopped. Until now the teardown only
    # SIGKILLed mediad and left its FUSE overlays and .under binds mounted inside /data/user/<uid> until roamd's
    # dropcaches ran -- AFTER the stop, i.e. after vold had already tried to remove the CE key. A mounted
    # overlay keeps its mountpoint dentries in use, so that first key removal was FILES_BUSY by construction
    # for any session with on-demand media, and the eviction then depended on the sweep landing inside vold's
    # ~99 s retry window. Same sweep as sweepmedia, without its logoff-only .btlogoff marker (cold lock parks
    # Bluetooth through btpark instead). The verdict is the ground truth read back out of /proc/mounts.
    # NWP-20261024-15: an UNREAD table must never count as zero. The count used to discard grep's read error, so a
    # table this domain could not read printed 0 and the eviction went on believing its overlays were gone. The
    # table is read ONCE with its status kept; a failed or empty read answers ERR-MEDIA-SWEEP UNREAD.
    # NWP-20261115-11: the table never goes to grep as an argument (/system/bin/printf: E2BIG over 128 KiB, so 0 read as OK over live mounts); stop_mediad states the same rule.
    stop_mediad
    _mt=$(cat /proc/mounts 2>>"$LOG"); _mtrc=$?
    if [ "$_mtrc" -ne 0 ] || [ -z "$_mt" ]; then
      echo "ERR-MEDIA-SWEEP UNREAD" > "$RES"
      _said="mount table unreadable"
    else
      _left=$(grep -c -e " fuse.nowheremedia " -e "/.nowhere-media[^/]*/.under/" <<EOF_MT
$_mt
EOF_MT
)
      if [ "${_left:-0}" -gt 0 ]; then echo "ERR-MEDIA-SWEEP $_left" > "$RES"; else echo "OK" > "$RES"; fi
      _said="${_left:-0} media mount(s) left"
    fi
    echo "[roamd] coldsweep (cold-lock pre-stop teardown) user $uid: $_said $(date)" >> "$LOG"
    unset _left _mt _mtrc _said
    ;;
  odblock)
    # NWP-20261130-03: the launch barrier of an app an outside installer (Aurora, Play, sideload) put on the phone with
    # its data still in the store. Nowhere's own installs fetch first (materializeapp, stageapp), so they never reach
    # this. The daemon sends this on the RO lane BEFORE it queues odrestore on the RW lane, where a seal can hold the slot
    # for minutes. It answers within the seconds PackageManager needs, and only odrestore's OK reply lifts the block
    # (od_unblock_app). A background retry can land after that OK: when this op set the block itself and the package has
    # left the lists meanwhile, it lifts its own block. Since 2b the chooser suspends the app at its package-added event
    # (OdDataBarrier), without a worker lane; this op is the backstop. An outside install is launchable only for the moment
    # between its commit and that event, because Android offers no hold on a package that is not yet installed.
    pkg="$srcunit"
    pkgname_ok "$pkg" || { echo "[roamd] odblock bad pkg $(date)" >> "$LOG"; echo "ERR-PKG" > "$RES"; chmod 600 "$RES"; exit 0; }
    if od_listed "$pkg"; then
      _had=0; [ -s "$STATE/odfetch.$uid/blocked.$pkg" ] && _had=1
      if ! od_block_app "$pkg"; then
        echo "ERR-NOBLOCK" > "$RES"
      elif [ "$_had" = 0 ] && ! od_listed "$pkg"; then
        od_unblock_app "$pkg"; echo "OK NONE" > "$RES"
      else
        echo "OK BLOCKED" > "$RES"
      fi
    else
      echo "OK NONE" > "$RES"
    fi
    ;;
  alarmrelay)
    # NWP-20261004-01 (#151): ask the cold-locking session for its next alarm, so the gate can ring it. The
    # periodic relay rides the post-seal claims kick, which fires only when the vault push happens -- so a
    # phone that is OFFLINE (airplane mode at bedtime) never relayed the alarm it set. That used to be hidden
    # because the framework restarted the stopped user around each alarm and its own clock rang; the
    # Endospore overlay now turns that restart off (config_allowAlarmsOnStoppedUsers=false), so the gate's
    # copy is the only ring there is, and it must not depend on the network. The session is still running
    # here (the teardown calls this before the stop) and CredentialService already runs AS that user.
    # stdio to /dev/null: a su:s0 init script cannot CAPTURE am output (DIA-56). The daemon waits for the
    # SET-GATE-ALARM this produces; that wait, not this line, is the proof it arrived.
    am startservice --user "$uid" -n com.nowhere.chooser/.CredentialService \
      --ez alarm true </dev/null >/dev/null 2>&1
    echo "[roamd] alarmrelay: asked user $uid for its next alarm before the cold-lock stop $(date)" >> "$LOG"
    echo "OK" > "$RES"
    ;;
  playrestart)
    # NWP-20261201-10: a health notice's Fix for the rule play-push-frozen. Force-stopping Play services in the
    # session's user recovers a frozen push process (lynx 2026110701, GmsCompat binds it again in about 20 s). Only the
    # user's tap reaches this op. A refused uid is not logged: it can be any text. Stdio to /dev/null (DIA-56). The
    # reply is renamed into $RES, and the log line comes first because the poller removes $RES once it reads it.
    case "$uid" in
      ""|0*|*[!0-9]*)
        echo "ERR-NOSESSION" > "$RES.part"
        _prs="refused, no session user"
        ;;
      *)
        am force-stop --user "$uid" com.google.android.gms </dev/null >/dev/null 2>&1
        echo "OK" > "$RES.part"
        _prs="force-stopped Play services in user $uid"
        ;;
    esac
    chmod 600 "$RES.part" 2>>"$LOG"
    echo "[roamd] playrestart: $_prs $(date)" >> "$LOG"
    mv -f "$RES.part" "$RES" 2>>"$LOG"
    unset _prs
    exit 0
    ;;
  freemedia)
    # #84 P5 "Free up space": purge the on-demand-media FETCH caches for the live session, on the user's request
    # (Profile -> Storage). The caches are per-user (wiped with the ephemeral user at logoff anyway); this reclaims
    # them MID-session for a device tight on /data. BOTH of mediad's caches: `.nowhere-media` serves the CE vault
    # and `.nowhere-media-ext` the `#media` scope (nowhere_mediad.sh MEDIACACHE). Since NWP-20260923-02 the vault
    # defers almost nothing, so on-demand media streams through `-ext`; purging only the CE cache freed close to
    # nothing while the row reported the `-ext` bytes too (NWP-20261016-49). Delete only COMPLETE cache entries: a
    # top-level regular file named exactly 64 lowercase hex (mediad's cacheKey -- the same rule evictCache applies,
    # no dot in the name). Everything else in each dir is KEPT: `.deleted` is that scope's tombstone list, the one
    # positive-deletion signal the next seal reads, so removing it brings every file the user deleted this session
    # back at the next sign-in (NWP-20261015-20); a `.fetch-*` temp or a `.part`/`.have` pair is a fetch mediad may
    # be filling (its evictCache skips them too: deleting a `.part` under a chunk write strands the write), and an
    # idle `.part` stays until a read completes it or the session ends; `.under/` holds the bind mounts of the live
    # overlaid dirs, the user's REAL files (deleting through those destroys them). Safe while mediad serves: an app
    # mid-read holds the inode via its open fd, and the next access simply re-fetches from the store (the bytes are
    # content-addressed there). A glob, not `$(find)`, so a name with whitespace is never split into paths.
    # Reports freed BYTES (both caches summed) so the gate can say "Freed X MB".
    freed=0
    for CACHE in "$USERDIR/com.nowhere.chooser/files/.nowhere-media" \
                 "$USERDIR/com.nowhere.chooser/files/.nowhere-media-ext"; do
      [ -d "$CACHE" ] || continue
      for f in "$CACHE"/*; do
        [ -f "$f" ] && [ ! -L "$f" ] || continue
        name=${f##*/}
        [ "${#name}" -eq 64 ] || continue
        case "$name" in *[!0-9a-f]*) continue;; esac
        sz=$(stat -c %s "$f" 2>/dev/null); case "$sz" in ''|*[!0-9]*) sz=0;; esac
        rm -f "$f" 2>> "$LOG" && freed=$((freed + sz))
      done
    done
    echo "[roamd] freemedia user $uid freed ${freed}B $(date)" >> "$LOG"
    echo "OK $freed" > "$RES"
    ;;
  sealdelta)
    # #145 S5 (NWP-20260901-29): "changed since the last save" -- a stat-only walk of the three data
    # scopes with the daemon-dumped deferred index ($STATE/sealdelta.idx) for the exact half. Runs HERE
    # for the same reason storagebreakdown does: only this domain can read a roamed user's
    # MCS-categorised data. srcunit rides the since-unix stamp (the slot is per-op, materializeapp
    # precedent). LOCAL op -- reads disk + one tmpfs file, touches no store, writes nothing.
    # NWP-20261024-17: RENAME INTO $RES, as uiderrors does -- the poller returns at the first non-empty byte
    # and removes $RES the moment it has read it, so a write in place followed by `[ -s "$RES" ]` could find
    # $RES already consumed, write a stale ERR-WALK, and a queued RO op would read that as ITS reply. After
    # the mv this arm neither reads nor writes $RES.
    "$AGENT" sealdeltawalk "$uid" "$srcunit" > "$RES.part" 2>>"$LOG" || echo "ERR-WALK" > "$RES.part"
    [ -s "$RES.part" ] || echo "ERR-WALK" > "$RES.part"
    chmod 600 "$RES.part"
    echo "[roamd] sealdelta user $uid since=$srcunit -> $(wc -c < "$RES.part" 2>/dev/null)B $(date)" >> "$LOG"
    mv -f "$RES.part" "$RES" 2>>"$LOG"
    exit 0
    ;;
  storagebreakdown)
    # DIA-20260804-03 "free up space": per-app on-disk cost for the Storage screen, so a user over their plan
    # can see what to remove. Runs HERE rather than in the login daemon for one reason: only this domain can
    # read the data. Walking /data/user/N needs system_data_file + system_app_data_file read AND
    # mlstrustedsubject -- per-user app data carries MCS categories (system_data_file:s0:c522,c768) and an s0
    # subject is refused by the CATEGORY constraint, which no type rule fixes (DIA-20260620-03, the enforcing
    # BLANK). endospore_priv holds all three; the `nowhere` domain holds none, so the walk there would have
    # reported ZERO bytes for every app, silently. LOCAL op -- touches NO store and deletes NOTHING; it only
    # measures. The agent does the walk itself (it has to skip mediad's FUSE overlays by device id and
    # de-duplicate hard links -- neither of which a `du` here expresses) and prints one JSON object.
    # NWP-20261024-17: RENAME INTO $RES, as uiderrors does -- the poller returns at the first non-empty byte
    # and removes $RES the moment it has read it, so a write in place followed by `[ -s "$RES" ]` could find
    # $RES already consumed, write a stale ERR-WALK, and a queued RO op would read that as ITS reply. After
    # the mv this arm neither reads nor writes $RES.
    "$AGENT" storagebreakdown "$uid" > "$RES.part" 2>>"$LOG" || echo "ERR-WALK" > "$RES.part"
    [ -s "$RES.part" ] || echo "ERR-WALK" > "$RES.part"
    chmod 600 "$RES.part"
    echo "[roamd] storagebreakdown user $uid -> $(wc -c < "$RES.part" 2>/dev/null)B $(date)" >> "$LOG"
    mv -f "$RES.part" "$RES" 2>>"$LOG"
    exit 0
    ;;
  uiderrors)
    # NWP-20261010-06: this session's lines of the package manager's /data/system/uiderrors.txt, for
    # REPORT-ISSUE. Its `Destroying <dir> due to: <reason>` lines have ONE writer, the app-data reconcile at a
    # user start (not uninstall, clear-data or user removal), and the file is the one persistent record of it on
    # a locked user build. HERE, not in the daemon, because the file is system_data_file: endospore_priv already
    # reads that type (endospore.te) and su:s0 reads anything, while granting the network-facing `nowhere` domain
    # read on all of /data/system to collect one diagnostic file would be the wrong trade. LOCAL op -- reads one
    # file, no store, writes nothing. The agent does the read and the filtering (past this session's floor, naming
    # this session's user -- uiderrorsTail), so no other session's line reaches $RES. ⚠ RENAME INTO $RES, never
    # write in place: the poller returns at the first non-empty byte (the keystorens lesson, NWP-20260827-02).
    # NWP-20261111-27: the log line's reply is read from $RES.part BEFORE the mv -- the poller removes $RES the
    # moment it has read it, so a read of $RES after the mv logged a blank exactly when the daemon was fast.
    # After the mv this arm neither reads nor writes $RES.
    "$AGENT" uiderrorstail "$(cat "$STATE/uiderrors.floor" 2>/dev/null)" "$uid" > "$RES.part" 2>>"$LOG" \
      || echo "ERR-READ the agent exited non-zero" > "$RES.part"
    [ -s "$RES.part" ] || echo "ERR-READ the agent printed nothing" > "$RES.part"
    chmod 600 "$RES.part" 2>>"$LOG"
    _ueh=$(head -n 1 "$RES.part" 2>/dev/null | cut -c1-160)
    mv -f "$RES.part" "$RES" 2>>"$LOG"
    echo "[roamd] uiderrors -> $_ueh $(date)" >> "$LOG"
    unset _ueh
    exit 0
    ;;
  gmsstate)
    # NWP-20261201-01: this session's Play services process state, for REPORT-ISSUE. LOCAL op -- two read-only dumps, no
    # store. The agent keeps only the two fixed gms processes of this user, so no other process reaches $RES. Each
    # dump's exit status follows it on a nowhere-dump-rc= line, so a failed dump reads `unread` and never as a healthy
    # or empty one. ⚠ dumpsys stderr goes to /dev/null, NEVER to $LOG (see above bt_default_name: the redirect makes
    # the whole call fail). The agent is not a binder dump, so its own stderr may go to $LOG. ⚠ RENAME INTO $RES, and
    # read the log line's reply from $RES.part BEFORE the mv, as the uiderrors arm does.
    { printf '== processes\n'; dumpsys activity processes com.google.android.gms </dev/null 2>/dev/null; printf '\nnowhere-dump-rc=%s\n' "$?"
      printf '== oom\n'; dumpsys activity oom </dev/null 2>/dev/null; printf '\nnowhere-dump-rc=%s\n' "$?"; } \
      | "$AGENT" gmsstate "$uid" > "$RES.part" 2>>"$LOG" \
      || echo "ERR-READ the agent exited non-zero" > "$RES.part"
    [ -s "$RES.part" ] || echo "ERR-READ the agent printed nothing" > "$RES.part"
    chmod 600 "$RES.part" 2>>"$LOG"
    _gmh=$(head -n 1 "$RES.part" 2>/dev/null | cut -c1-160)
    mv -f "$RES.part" "$RES" 2>>"$LOG"
    echo "[roamd] gmsstate -> $_gmh $(date)" >> "$LOG"
    unset _gmh
    exit 0
    ;;
  gmsexits)
    # NWP-20261201-02: why this session's Play services processes exited, for REPORT-ISSUE (the framework's
    # ApplicationExitInfo). HERE because the login daemon's domain cannot run dumpsys. LOCAL op -- one dumpsys, no
    # store, writes nothing but $RES and $LOG. The agent keeps this user's two gms processes and only their words and
    # digits (parseGmsExits), so $RES and the log line carry counts and fixed words, never a description. The clock
    # line is the device's local time, the same naive clock as the dump's stamps. dumpsys's stderr goes to /dev/null,
    # never $LOG: system_server cannot append to our log, and the denial fails the whole call (the ⚠ NEVER note near
    # bt_default_name).
    # ⚠ RENAME INTO $RES, never write in place, and read the log line's reply from $RES.part BEFORE the mv: the uiderrors
    # arm above says why for both.
    { printf 'nowhere-now=%s %s\n' "$(date +%s)" "$(date '+%Y-%m-%d %H:%M:%S')"
      dumpsys activity exit-info com.google.android.gms </dev/null 2>/dev/null
      printf '\nnowhere-dump-rc=%s\n' "$?"
    } | "$AGENT" gmsexits "$uid" > "$RES.part" 2>>"$LOG" \
      || echo "ERR-READ the agent exited non-zero" > "$RES.part"
    [ -s "$RES.part" ] || echo "ERR-READ the agent printed nothing" > "$RES.part"
    chmod 600 "$RES.part" 2>>"$LOG"
    _geh=$(head -n 1 "$RES.part" 2>/dev/null | cut -c1-160)
    mv -f "$RES.part" "$RES" 2>>"$LOG"
    echo "[roamd] gmsexits -> $_geh $(date)" >> "$LOG"
    unset _geh
    exit 0
    ;;
  healthprobe)
    # NWP-20261201-08: one read of the process table for the login daemon's health checks; why it is here and on the
    # RO lane is above the allowlist. The agent reduces the dump to numbers and one state token, so no app name reaches $RES.
    # ⚠ dumpsys stderr goes to /dev/null, never $LOG (the warning near bt_state). ⚠ RENAME INTO $RES, never write in
    # place: the poller returns at the first non-empty byte. The word for the log line is read from $RES.part BEFORE
    # the mv (NWP-20261111-27). After the mv this arm neither reads nor writes $RES.
    case "$uid" in
      ''|0|*[!0-9]*) echo "ERR-NOSESSION" > "$RES.part" ;;
      *) dumpsys activity oom </dev/null 2>/dev/null | "$AGENT" healthoom "$uid" > "$RES.part" 2>>"$LOG"
         [ -s "$RES.part" ] || echo "ERR-READ the agent printed nothing" > "$RES.part" ;;
    esac
    chmod 600 "$RES.part" 2>>"$LOG"
    _hpw=$(head -n 1 "$RES.part" 2>/dev/null | cut -d' ' -f1 | cut -c1-40)
    mv -f "$RES.part" "$RES" 2>>"$LOG"
    echo "[roamd] healthprobe -> $_hpw $(date)" >> "$LOG"
    unset _hpw
    exit 0
    ;;
  materializeapp)
    # #204 on-demand apps: the user tapped an archived placeholder. The framework sends ACTION_UNARCHIVE_PACKAGE
    # to the installer-of-record (the chooser) IN THE USER THE APP IS ARCHIVED IN -- i.e. THIS roamed user
    # (PackageArchiver.unarchiveInternal -> sendOrderedBroadcastAsUser(userForUnarchival)). So the roamed-user
    # chooser does the install and must READ the APK bytes from its OWN CE dir. Here (su:s0) we fetch JUST that
    # package from the name#apps scope into the ROAMED user's chooser .appcode/<pkg> + chown to that user's
    # chooser uid, so the roamed chooser PackageInstaller-completes the unarchive. pkg rides the srcunit slot
    # (roam.req line 7); name/pass/uid are the live session creds. Best-effort: a failed fetch leaves no
    # .appcode/<pkg> and returns ERR so the chooser can reportUnarchivalStatus a download failure.
    pkg="$srcunit"
    # NWP-20261014-20: the Android package grammar (pkgname_ok, the same check as validPkgName in pkgname.go).
    pkgname_ok "$pkg" || { echo "[roamd] materializeapp bad pkg $(date)" >> "$LOG"; echo "ERR-PKG" > "$RES"; chmod 600 "$RES"; exit 0; }
    # A FIDO2-2FA identity DROPPED its pass-only vault slot at enrollment, so name#apps opens only via the fido2
    # keyslot -- which needs the login-cached hmac in env (the `out` and
    # `fido2-enroll` ops export it the same way). Without
    # this the restore-app resolveKey fails for a key-enrolled profile with no SE and the tap can never install.
    [ -f "$STATE/.fido2hmac" ] && export NOWHERE_FIDO2_HMAC="$(cat "$STATE/.fido2hmac")"
    CHOOSERU="$USERDIR/com.nowhere.chooser/files"   # $USERDIR=/data/user/$uid -- the ROAMED user (the receiver)
    APPCODE="$CHOOSERU/.appcode"
    rm -rf "$APPCODE/$pkg"                 # clear any stale set for THIS pkg; leave sibling in-flight apps alone
    # NWP-20261130-03: the app's skipped data comes back FIRST, into its hold. A failed fetch stages no APK, so the
    # placeholder stays archived: an app is never launchable before its data is back.
    if ! od_fetch_data "$pkg"; then
      if test -e "$STATE/od-cancel"; then
        echo "[roamd] materializeapp $pkg CANCELLED for a sign-out $(date)" >> "$LOG"; echo "ERR-CANCELLED" > "$RES"
      else
        echo "[roamd] materializeapp $pkg FAILED (data fetch) $(date)" >> "$LOG"; echo "ERR-FETCH" > "$RES"
      fi
      exit 0
    fi
    # NWP-20261109-11 (Q116, DECIDED 2026-10-20): a sign-out cancels this download at its next safe point. The login
    # daemon writes $STATE/od-cancel while LOGOUT waits for the session lock this op holds (NOWHERE-968); the agent
    # polls it between chunks. Nothing is installed until the chooser commits the WHOLE set, so a cut between chunks
    # leaves nothing: the failure branch below removes the partial set. $STATE is the tmpfs, so the marker never
    # outlives a power-off. The env assignment is inline, not exported: only restore-app reads it.
    if [ -d "$CHOOSERU" ] && mkdir -p "$APPCODE" 2>>"$LOG" \
       && NOWHERE_PHASE=apps NOWHERE_OD_CANCEL="$STATE/od-cancel" "$AGENT" restore-app s3 "${name}#apps" "$(pw "$pass")" "$pkg" "$APPCODE" >> "$LOG" 2>&1 \
       && [ -d "$APPCODE/$pkg" ]; then
      cuid=$(stat -c %u "$CHOOSERU" 2>/dev/null)
      [ -n "$cuid" ] && chown -R "$cuid:$cuid" "$APPCODE" 2>>"$LOG"
      restorecon -R -D "$APPCODE" 2>>"$LOG"
      echo "[roamd] materializeapp $pkg -> user $uid chooser $(date)" >> "$LOG"
      echo "OK $pkg" > "$RES"
    else
      rm -rf "$APPCODE/$pkg"
      if [ -e "$STATE/od-cancel" ]; then
        echo "[roamd] materializeapp $pkg CANCELLED for a sign-out $(date)" >> "$LOG"
        echo "ERR-CANCELLED" > "$RES"
      else
        echo "[roamd] materializeapp $pkg FAILED $(date)" >> "$LOG"
        echo "ERR-FETCH" > "$RES"
      fi
    fi
    ;;
  stageapp)
    # FETCH-APP (Phase 2b, DIA-20260730): the login daemon already DOWNLOADED + sha256-VERIFIED the catalog app's
    # APK(s) into /data/nowhere/fetchapp/<pkg> (network + crypto happen in Go). Here (su:s0) we do the privileged
    # half -- move the verified bytes into the ROAMED user's chooser .appcode/<pkg>, append the manifest line, and
    # chown to that user's chooser uid -- so the storefront/chooser PackageInstaller-installs it. Mirrors
    # materializeapp, but the SOURCE is the curated catalog (a URL), not name#apps. The APK move is LOCAL; the store is
    # read only for a parked package's data (NWP-20261130-03, below). pkg rides the srcunit slot.
    pkg="$srcunit"
    # NWP-20261014-20: the Android package grammar (pkgname_ok, the same check as validPkgName in pkgname.go).
    pkgname_ok "$pkg" || { echo "[roamd] stageapp bad pkg $(date)" >> "$LOG"; echo "ERR-PKG" > "$RES"; chmod 600 "$RES"; exit 0; }
    STAGE="/data/nowhere/fetchapp/$pkg"
    CHOOSERU="$USERDIR/com.nowhere.chooser/files"   # $USERDIR=/data/user/$uid -- the ROAMED user
    APPCODE="$CHOOSERU/.appcode"
    # NWP-20261130-03: a store Get installs what this op stages, and the app is launchable the moment it lands, so a
    # package the sign-in skipped has its data placed in its hold HERE, before there is an APK to install. A failed fetch
    # stages nothing and the chooser installs nothing. No odfetch dir is a session that skipped nothing (a local one).
    if [ -d "$STATE/odfetch.$uid" ] && ! od_fetch_data "$pkg"; then
      rm -rf "$STAGE"; echo "[roamd] stageapp $pkg FAILED (data fetch) -- not installed (NWP-20261130-03) $(date)" >> "$LOG"; echo "ERR-STAGE" > "$RES"; chmod 600 "$RES"; exit 0
    fi
    if [ -d "$STAGE" ] && [ -d "$CHOOSERU" ]; then
      rm -rf "$APPCODE/$pkg"                        # clear any stale set for THIS pkg; leave sibling apps alone
      mkdir -p "$APPCODE/$pkg" 2>>"$LOG"
      # Every staged APK must land WHOLE before this answers OK. The daemon sha256-verified the STAGE, not these
      # copies, and the chooser's installStaged commits whatever *.apk it finds in .appcode/<pkg> as one session:
      # a split that failed to copy (ENOSPC) would install a base without its native libs, and a cp that died
      # part-way would commit a cut file. cmp (toybox's on the device) proves each copy is the verified bytes.
      want=0; n=0
      for _a in "$STAGE"/*.apk; do
        [ -f "$_a" ] || continue
        want=$((want+1)); _d="$APPCODE/$pkg/${_a##*/}"
        cp "$_a" "$_d" 2>>"$LOG" && cmp -s "$_a" "$_d" && n=$((n+1))
      done
      whole=no; [ "$want" -gt 0 ] && [ "$n" -eq "$want" ] && whole=yes
      [ "$whole" = yes ] || { rm -rf "$APPCODE/$pkg"; echo "[roamd] stageapp $pkg FAILED ($n of $want apk copied whole) $(date)" >> "$LOG"; }
      [ "$whole" = yes ] && [ -f "$STAGE/manifest.line" ] && cat "$STAGE/manifest.line" >> "$APPCODE/manifest.tsv" 2>>"$LOG"
      cuid=$(stat -c %u "$CHOOSERU" 2>/dev/null)
      [ -n "$cuid" ] && chown -R "$cuid:$cuid" "$APPCODE" 2>>"$LOG"
      restorecon -R -D "$APPCODE" 2>>"$LOG"
      rm -rf "$STAGE"                               # amnesia: no downloaded APK bytes linger in the daemon dir
      if [ "$whole" = yes ]; then
        echo "[roamd] stageapp $pkg ($n apk) -> user $uid chooser $(date)" >> "$LOG"; echo "OK $pkg" > "$RES"
      else
        echo "ERR-STAGE" > "$RES"
      fi
    else
      rm -rf "$STAGE" 2>/dev/null
      echo "[roamd] stageapp $pkg FAILED (no stage/chooser dir) $(date)" >> "$LOG"; echo "ERR-STAGE" > "$RES"
    fi
    ;;
  grant)
    # NWP-20261119-07 (backlog: 0.5.49's grant op runs the Keystore sweep, ...): this grant's bundle count and step
    # timings go to $STATE/grant-timing at its end, for the issue report (core/agent/grant_timing.go). Remove the last
    # grant's file first, so a grant cut off before its end leaves no earlier session's figures.
    if [ -n "${STATE:-}" ]; then rm -f "$STATE/grant-timing" 2>/dev/null; fi
    _gt0=$(_ms)
    # #46: pin launcher3 as THIS roamed user's HOME. Runs HERE (not in the roam-in op) because the chooser
    # triggers `grant` as its LAST login step -- AFTER provisionRoamedApps's install-existing, which re-resolves
    # HOME and RESETS an earlier pin back to the ambiguous 2-candidate picker (the gate now also declares
    # CATEGORY_HOME for #46). Pinning here makes the roamed session's home stay the real launcher (its
    # gestures/drawer/search) and never resolve to the gate. cmd stdio -> /dev/null (the su:s0 cmd fd denial).
    home_pin "$uid"
    nav_apply "$uid"   # NWP-20260914-04: after install-existing (overlays exist), before switch-in
    aod_apply "$uid"   # NWP-20260922-02: same point -- a Secure write, before switch-in
    a11y_apply "$uid"  # NWP-20261108-15: Q024 -- a Secure write, before switch-in; marks .a11yapplied
    autofill_apply "$uid"  # NWP-20261109-15: Q078 -- a Secure write, before switch-in; marks .autofillapplied
    # NWP-20261113-05: stage this session's restored #keys bundles BEFORE switch-in. A bundled (system / /product) app
    # never passes odrestore, so its bundle used to wait in keystore-in for the first periodic `out` sweep: on the S3
    # device-proof run `#keys restored (1 bundle(s))` at 17:33:31, Seedvault staged for import only at 17:36:21, and an
    # app that looks up its key in that window misses the carry (a create-on-miss app mints fresh keys whose dump then
    # wins at logoff). One `pm` call; idempotent with the later `out` sweeps (KS_MAP merge; a staged bundle has left
    # keystore-in); a package not installed yet keeps its bundle in keystore-in for odrestore.
    # NWP-20261119-07: count this user's restored bundles BEFORE the sweep moves them (a glob, no exec per file).
    _gtb=0; if _gtd=$(ks_in_dir); then for _gtf in "$_gtd"/*.keys; do [ -e "$_gtf" ] && _gtb=$((_gtb + 1)); done; fi
    _tt=$(_ms); keystore_register_all; _tlog grant-keystore "$_tt"
    _gtk=$(( $(_ms) - _tt ))
    # Re-grant the roamed runtime perms captured at the last logout, now that the chooser has install-existing'd
    # the apps for this user (a perm can only be granted to an INSTALLED app, so this runs AFTER provisionRoamedApps,
    # triggered by the chooser). NB: an ON-DEMAND app is an APK-less archived placeholder here, so its perms cannot
    # be granted yet -- odrestore re-grants them at the tap (after the real APK install). (DIA-20260625-06)
    _tt=$(_ms); grant_perms_for "$uid"; _tlog grant-135 "$_tt"
    _gtp=$(( $(_ms) - _tt ))
    # #DIA-20260802-05: place + reload the roamed account (detach/place/reload) now the authenticator is installed.
    # group-materialize (DIA-20260802): but DEFER it when the account authenticator is an un-materialised ON-DEMAND
    # group member -- its app-data hold is still parked, so it is NOT installed and AMS.validateAccountsInternal
    # would DESTRUCTIVELY purge the account. Mark it deferred; the member's tap-time odrestore reloads instead. For
    # an INSTALLED authenticator the login-time odrestore already consumed its hold, so acct_reload runs here EXACTLY
    # as the proven path does today (marker cleared).
    if [ -d "/data/user/$uid/com.nowhere.chooser/.nowhere-odhold/$ACCT_AUTH_PKG" ]; then
      ( : > "/data/nowhere/acct-deferred-$uid" ) 2>>"$LOG"
      echo "[roamd] GRANT acct_reload DEFERRED: $ACCT_AUTH_PKG held on-demand -> odrestore $(date)" >> "$LOG"
      echo "[roamd] sync: apply for user $uid deferred with the account reload -> odrestore $(date)" >> "$LOG"   # NWP-20261010-15
    else
      rm -f "/data/nowhere/acct-deferred-$uid" 2>>"$LOG"
      # DIA-20260811-08: the INSTALLED path was missing BOTH halves of the fix the on-demand path already has.
      # DIA-20260802-12 established that checkin state does not roam, so a roamed gms starts with android_id=0 and
      # Finsky loops on "Reauthenticating account ... try again" until a checkin lands -- and that a Finsky process
      # which came up before the checkin CACHES the no-identity state and keeps failing until it is force-stopped
      # (proven odtest22->user11). Both cures were written inside odrestore, gated on the tapped package being the
      # authenticator -- i.e. the ON-DEMAND path only. When the Play stack roams as INSTALLED the login takes THIS
      # branch, which called acct_reload and stopped, so every roam left the user on Play's "Try again" screen
      # until they closed and reopened Play by hand. Reported on lynx 2026-08-11 with the account placed (#sys
      # accounts push rc=0), the stack carried (#apps sealed 3 pkg = vending+gms+gsf) and the network provably
      # fine (play.googleapis.com resolving and reachable) -- never connectivity, only Finsky's cached state.
      #
      # Kick BEFORE acct_reload, exactly as odrestore does. --include-stopped-packages opts out of AMS's
      # FLAG_EXCLUDE_STOPPED_PACKAGES so the broadcast is not silently filtered for a stopped gms, and it also
      # cold-starts gms and clears the stopped flag, which is what lets acct_reload's LOGIN_ACCOUNTS_CHANGED
      # fan-out reach gms. Do NOT rewrite as `-f 0x00000020`: -f setFlags CLOBBERS, --include-stopped-packages
      # addFlags. Fire-and-forget, stdio -> /dev/null (su:s0 cmd fd denial).
      am broadcast --user "$uid" --include-stopped-packages -a android.server.checkin.CHECKIN </dev/null >/dev/null 2>&1
      echo "[roamd] GRANT checkin kicked for user $uid (android_id bootstrap, installed path) $(date)" >> "$LOG"
      acct_reload "$uid"
      sync_apply "$uid"   # NWP-20261010-15: STRICTLY after acct_reload -- the accounts must exist first (sync_apply)
      # Then drop any Finsky already up. Unlike odrestore -- where vending has not materialised yet and gets ~60s
      # of slack -- an INSTALLED vending may already be running against the pre-account, pre-checkin state, and
      # nothing else ever evicts that cache. Restarting it IS the manual workaround, done for the user. Guarded on
      # the package being installed for THIS user so the log line cannot claim a restart that did not happen (the
      # same `pm list packages` capture reap_orphan_provisioned already relies on). Best-effort by design: a
      # failure here costs one manual restart, which is today's behaviour, so it must never fail the login.
      if pm list packages --user "$uid" 2>/dev/null | grep -qx "package:$PLAY_STORE_PKG"; then
        am force-stop --user "$uid" "$PLAY_STORE_PKG" </dev/null >/dev/null 2>&1
        echo "[roamd] GRANT $PLAY_STORE_PKG force-stopped after checkin+reload (drops the android_id=0 cache) $(date)" >> "$LOG"
      fi
    fi
    # NWP-20261119-07: one line, digits only, published by a temp file and a rename; nothing when STATE is unset or a
    # value is not a whole number.
    _gtt=$(( $(_ms) - _gt0 ))
    case "$_gtb.$_gtk.$_gtp.$_gtt" in
      *[!0-9.]*|.*|*.|*..*) ;;
      *) if [ -n "${STATE:-}" ]; then
           printf 'v=1 bundles=%s keystore_ms=%s perms_ms=%s total_ms=%s\n' "$_gtb" "$_gtk" "$_gtp" "$_gtt" \
             > "$STATE/grant-timing.tmp" 2>/dev/null && mv -f "$STATE/grant-timing.tmp" "$STATE/grant-timing" 2>/dev/null
         fi ;;
    esac
    echo "OK" > "$RES"
    ;;
  seedssaid)
    # #210 (DIA-20260728-09): STAGE this profile's SSAID "userkey" for the brand-new user; the framework mints
    # from it. An app's ANDROID_ID is DERIVED -- f(per-user userkey, app signing cert) -- so a userkey the
    # profile reproduces on every device reproduces every app's id, and device-bound logins (Amazon MAP et al.)
    # stop dropping at each login. $sesec carries the 64-hex userkey the daemon derived.
    #
    # WE DO NOT WRITE settings_ssaid.xml ANY MORE, at any time -- that can never work. SettingsProvider
    # instantiates the per-user ssaid state when the user is created, caches it in system_server, and only ever
    # WRITES that file, never re-reads it. Proven on lynx 2026-07-28: "No settings state .../11/settings_ssaid.xml"
    # at 12:19:24.351, our write at 12:19:25 -- on disk, ignored, then clobbered on the first mint. Instead the
    # patched generateUserKeyLocked() consumes this seed when it lazily mints the key (first app to ask for its
    # id, well after login): editions/diaspore/build/patches/ssaid-userkey-seed.sh. NO framework patch on the
    # image => this seed is simply never read and ids rotate as before, which is the pre-#210 behaviour.
    # h49 #7 (NWP-20261119-20): roamd's own time for a staging attempt is logged on its own line below, a number and
    # the uid only, so a sign-in's seed-ssaid can be split into roamd's time and the agent's poll.
    _ss_t0=$(_ms)
    _uk="$sesec"
    case "$_uk" in
      [0-9A-Fa-f]*) ;;
      *) echo "[roamd] seedssaid bad userkey $(date)" >> "$LOG"; echo "ERR-KEY" > "$RES"; chmod 600 "$RES"; exit 0;;
    esac
    case "$_uk" in *[!0-9A-Fa-f]*) echo "ERR-KEY" > "$RES"; chmod 600 "$RES"; exit 0;; esac
    # Exactly 64 hex or the framework rejects it and mints a random key. Fail HERE, where it lands in roam.log,
    # rather than let a truncated key look seeded and silently rotate every id.
    if [ "${#_uk}" -ne 64 ]; then
      echo "[roamd] seedssaid userkey wrong length ${#_uk} (want 64) user $uid $(date)" >> "$LOG"
      echo "ERR-KEY" > "$RES"; chmod 600 "$RES"; exit 0
    fi
    # NWP-20261003-01: NEVER create users/<uid> here. This used to mkdir it, which made roamd itself a maker
    # of the very orphan the reap and the boot sweep remove: a SEED-SSAID reaching roamd for a uid whose user is
    # already gone would leave users/<uid> holding nowhere-ssaid-seed -- a passphrase VERIFIER (see the staging
    # note below) -- in cleartext, across reboots, and owned by root, which system_server cannot empty.
    # UserManagerService creates the directory and writes the record before createAndManageUser returns, and the
    # chooser sends SEED-SSAID only after that, so on a real sign-in both exist. If either is missing there is no
    # user to seed: refuse and stage nothing. The chooser treats any non-OK reply as best-effort -- the SSAID
    # carry is lost, never the login.
    # "No record" is a NEGATIVE result, so it is trusted only when user 0's record CAN be seen (the positive
    # control reap_userdir_settle uses). If it cannot, the records are unreadable, not absent -- refusing then
    # would drop the SSAID carry on every sign-in -- so record=blind stages into the directory, which must still
    # exist: blind or not, nothing here ever creates it.
    # A SYMBOLIC LINK at users/<uid> is not the directory (NWP-20261011-42): -d follows one, so a link to a
    # directory would pass, and the seed -- a passphrase verifier -- would be written through it into whatever it
    # points at. A link is refused like a missing directory; the log says `(link)` and never where it points.
    _udd=0; _udr=0
    [ -d "/data/system/users/$uid" ] && [ ! -L "/data/system/users/$uid" ] && _udd=1
    _udl=""; [ -L "/data/system/users/$uid" ] && _udl=" (link)"
    if userdir_has_record "$uid"; then _udr=1
    elif ! userdir_has_record 0; then _udr=blind; fi
    if [ "$_udd" = 0 ] || [ "$_udr" = 0 ]; then
      echo "[roamd] seedssaid user $uid has no system dir or no record (dir=$_udd record=$_udr)$_udl -- NOT staging, dir NOT created (NWP-20261003-01) $(date)" >> "$LOG"
      echo "ERR-NOUSER" > "$RES"; chmod 600 "$RES"; exit 0
    fi
    if [ "$_udr" = blind ]; then
      echo "[roamd] seedssaid user $uid: records cannot be seen (record=blind) -- staging into the existing dir (NWP-20261003-01) $(date)" >> "$LOG"
    fi
    # DIA-20260728-08, and now load-bearing for a different reason: a stale settings_ssaid.xml left by a REAPED
    # user with this same (recycled) id makes SettingsProvider load a userkey from disk, so generateUserKeyLocked
    # is never called and the seed below is never consumed. This user has not started yet -- it cannot have
    # legitimate ssaid state -- so the file is stale by construction. Remove it.
    _stale="/data/system/users/$uid/settings_ssaid.xml"
    # The guard takes -L too: -e follows a link, so a dangling link would skip the rm and be refused below.
    if [ -e "$_stale" ] || [ -L "$_stale" ]; then
      echo "[roamd] seedssaid removing stale ssaid from a recycled user id $uid $(date)" >> "$LOG"
      rm -f "$_stale" 2>>"$LOG"
    fi
    # NWP-20261127-10: read it back. rm can fail (a directory at that name, a sepolicy that allows the seed's
    # write but not this unlink, an I/O error), and a surviving file makes SettingsProvider load the PREVIOUS
    # profile's key: every app takes its ANDROID_ID. Refuse and stage nothing; the chooser and the agent treat any
    # non-OK reply as a lost SSAID carry, never a lost login. The log names the uid only.
    if [ -e "$_stale" ] || [ -L "$_stale" ]; then
      echo "[roamd] seedssaid user $uid: the stale settings_ssaid.xml could NOT be removed -- NOT staging (the framework would load the old key) (NWP-20261127-10) $(date)" >> "$LOG"
      echo "ERR-STALE" > "$RES"; chmod 600 "$RES"; exit 0
    fi
    _dst="/data/system/users/$uid/nowhere-ssaid-seed"
    _tmp="$_dst.tmp"   # same dir => same fs + same SELinux context, so the rename is atomic and label-safe
    # DIA-20260812-03 (#106): print -rn --, NOT printf (external on Android => the key would land in a
    # world-readable argv). Worth noting how visible this was: the log line 3 lines below deliberately emits
    # only a 12-char PREFIX, "never the key" -- while the write above disclosed all 64 characters to any
    # process that sampled /proc at the right moment. -n keeps it byte-identical; the framework reader
    # regex-matches exactly [0-9A-Fa-f]{64}, so a stray newline would be a malformed seed and a random SSAID.
    if print -rn -- "$_uk" > "$_tmp" 2>>"$LOG" && mv -f "$_tmp" "$_dst" 2>>"$LOG"; then
      chown system:system "$_dst" 2>>"$LOG"; chmod 600 "$_dst" 2>>"$LOG"; restorecon "$_dst" 2>>"$LOG"
      # DIA-20260815-12: log NOTHING derived from the seed. The old line emitted a 12-char prefix on the
      # reasoning that a prefix is "never the key" -- but the seed is sha256("nowhere-ssaid-userkey\0" || dk)
      # and dk is the Argon2id key from name+passphrase (deriveKey in the
      # agent's main.go), so ANY function of it is a passphrase
      # VERIFIER: guess -> Argon2id -> SHA256 -> compare. At 48 bits that is a definitive yes/no per guess,
      # entirely offline, and roam.log is outside every wipe path (the boot-wipe removes USERS). It was also a
      # linkability record on its own -- prefixes recurred across recycled user ids, proving which sessions
      # were one profile. The uid + the framework's own "nowhere: seeded ssaid userkey for user N" logcat line
      # are enough to prove consumption, which is all the prefix was ever for.
      echo "[roamd] seedssaid staged ${#_uk} chars user $uid (#210) $(date)" >> "$LOG"
      echo "OK" > "$RES"
    else
      rm -f "$_tmp" 2>>"$LOG"
      echo "[roamd] seedssaid stage FAILED user $uid $(date)" >> "$LOG"; echo "ERR-STAGE" > "$RES"
    fi
    echo "[roamd] seedssaid took $(( $(_ms) - _ss_t0 ))ms user $uid $(date)" >> "$LOG"
    chmod 600 "$RES"; exit 0
    ;;
  dropssaid)
    # NWP-20261115-01 (dn-1023 #4, docs/product-decisions.md 2026-10-24): the gate's clean-up of a sign-in that did
    # not land. SEED-SSAID staged users/<uid>/nowhere-ssaid-seed, and once the patched SettingsProvider consumed it
    # settings_ssaid.xml holds the same 64 hex: both are a passphrase VERIFIER, in cleartext. The `in` arm removes them
    # on its own non-OK verdicts, but the agent-side outcomes in which `in` never runs or its OK is overturned reach
    # only the gate's stopRoamUser, a bare removeUser. After that removeUser returns, the gate sends DROP-SSAID, and
    # the daemon runs this op (it refuses the uid of a live or cold-locked session first). The name slot is "x".
    # Exactly the two files, nothing else: never create users/<uid>, never follow a link at it (rm -f of a link entry
    # removes the link, not its target). Not covered: a framework write that re-creates a file after this rm.
    # The uid checks come in this order: mksh reads a non-number in [ -ge ] as 0, silently.
    case "$uid" in ''|*[!0-9]*) echo "ERR-UID" > "$RES"; chmod 600 "$RES"; exit 0;; esac
    [ "$uid" -ge 10 ] || { echo "ERR-UID" > "$RES"; chmod 600 "$RES"; exit 0; }
    _dsd="/data/system/users/$uid"
    if [ -L "$_dsd" ]; then
      echo "[roamd] dropssaid user $uid: the system dir is a link -- nothing removed (dn-1023 #4) $(date)" >> "$LOG"
      echo "ERR-LINK" > "$RES"; chmod 600 "$RES"; exit 0
    fi
    _dsn=0; _dss=0
    if [ -d "$_dsd" ]; then
      for _dsf in nowhere-ssaid-seed settings_ssaid.xml; do
        [ -e "$_dsd/$_dsf" ] || [ -L "$_dsd/$_dsf" ] || continue
        rm -f "$_dsd/$_dsf" 2>/dev/null
        if [ -e "$_dsd/$_dsf" ] || [ -L "$_dsd/$_dsf" ]; then _dss=$((_dss + 1)); else _dsn=$((_dsn + 1)); fi
      done
    fi
    echo "[roamd] dropssaid user $uid: $_dsn SSAID file(s) removed, $_dss stuck (dn-1023 #4) $(date)" >> "$LOG"
    if [ "$_dss" = 0 ]; then _dsr="OK $_dsn"; else _dsr="ERR-RM"; fi
    echo "$_dsr" > "$RES"; chmod 600 "$RES"; exit 0
    ;;
  odrestore)
    # #204 on-demand data + perms restore-on-tap. UnarchiveService sends RESTORE-ODDATA <pkg> AFTER installApks
    # installs the REAL APK (so pkg is now in packages.list with a stable appId) and BEFORE launchApp. Move the
    # held CE+DE data (parked by hold_ondemand at login into .nowhere-odhold) back into the now-app-owned canonical
    # dir, reown to the app uid, then re-grant that one package's runtime perms (the login grant no-op'd on the
    # placeholder). pkg rides the srcunit slot. LOCAL op -- touches NO store. NEVER destroy the only copy: if
    # installApks didn't create the dest, leave the hold for the next login+tap (recoverable, not lost).
    pkg="$srcunit"
    # NWP-20261125-08: line 6 is a RESTORE-ODDATA list's batch token b<8 hex>.<i>.<n> (i, n from 1, no leading zero),
    # or empty. Anything else is no token. No arithmetic on the parts: mksh reads a non-number as 0, silently.
    odbatch=""
    case "${skind:-}" in
      b[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f].?*.?*)
        _odbi=${skind#*.}; _odbn=${_odbi#*.}; _odbi=${_odbi%%.*}
        case "$_odbi.$_odbn" in *[!0-9.]*|0*|*.0*|.*|*.|*.*.*) ;; *) odbatch="$skind" ;; esac ;;
    esac
    odlast=0; [ -n "$odbatch" ] && [ "$_odbi" = "$_odbn" ] && odlast=1
    # NWP-20261128-42: the Android package grammar (pkgname_ok, the same check as validPkgName in pkgname.go).
    pkgname_ok "$pkg" || { echo "[roamd] odrestore bad pkg $(date)" >> "$LOG"; echo "ERR-PKG" > "$RES"; chmod 600 "$RES"; exit 0; }
    # DIA-20260803: the app is very likely ALREADY RUNNING by the time we get here, against the EMPTY data dir
    # installApks just created -- gmscompat binds a Play-Services client's GmsCompatClientService the moment the
    # install completes ("Start proc ... for bound-service {PKG/GmsCompatClientService}"), which is a minute
    # before this op stages its data and keys. Such a process initialises as a FIRST RUN: it mints its own
    # keystore keys and writes a fresh vault, then keeps that state in memory and flushes it back over whatever
    # we restore below (proven odtest4: Ring re-wrote secure_store.xml AFTER the restore and signed the user
    # out). Kill it FIRST, so the copy lands under no writer and the chooser's launchApp starts a clean process
    # that reads the restored data + carried keys. Safe: it has no user-visible state worth keeping (it came up
    # on an empty profile) and it is not foreground -- the entry point is opened only after this op replies OK.
    # stdio -> /dev/null (su:s0 cmd fd denial, [[diaspore-suzero-cmd-fd-denial]]); best-effort by design.
    # NWP-20260903-11: PROBE THE HOLD FIRST, and kill only when one exists. This op now has a second caller
    # -- the install-heal (AppInstallReceiver fires it for EVERY install path: nApps, Aurora, Play, sideload,
    # NWP-20260820-10) -- and on the no-hold path (a plain new install that just needs its perms/INTERNET
    # default) the kill is not protecting anything: there is no restored data for a gap process to clobber,
    # and the user may have opened the app the second Play finished. Killing it there is a visible app crash
    # for zero benefit. When a hold DOES exist the kill is as load-bearing as ever (Ring re-wrote
    # secure_store.xml over a restore, proven odtest4) -- and the gms checkin choreography below relies on
    # the STOPPED flag only on the hold path, which is exactly the path that still sets it.
    # NWP-20261130-03: an install that bypassed materializeapp (nApps, Aurora, Play, sideload) still gets its skipped
    # data first, into the hold the probe below then finds. A failed fetch touches no hold and answers ERR-NOTREADY.
    # Such an app is INSTALLED and could be opened on fresh data, so od_block_app stops and suspends it before the
    # fetch, and only the OK reply below lifts that (od_unblock_app). An app that cannot be blocked is not fetched.
    if od_listed "$pkg"; then
      od_block_app "$pkg" || { echo "ERR-NOTREADY" > "$RES"; chmod 600 "$RES"; exit 0; }
    fi
    od_fetch_data "$pkg" || { echo "ERR-NOTREADY" > "$RES"; chmod 600 "$RES"; exit 0; }
    _hold=0
    for vol in "/data/user/$uid" "/data/user_de/$uid" "/data/media/$uid/Android/data" "/data/media/$uid/Android/obb"; do
      [ -d "$vol/com.nowhere.chooser/$ODHOLD/$pkg" ] && { _hold=1; break; }
    done
    if [ "$_hold" = 1 ]; then
      am force-stop --user "$uid" "$pkg" </dev/null >/dev/null 2>&1
      _odfsrc=$?
      # ⚠ NWP-20260922-09: OBSERVE THE OUTCOME, DO NOT REPORT THE CALL -- the same rule the silence-alarm op
      # states below ("the fifth time a silent no-op in this tree has claimed to work"), applied to the twin
      # of its own command in the same file. This kill is load-bearing: a live gap process re-writes its
      # state over the restore (proven on odtest4, Ring’s secure_store.xml). Logging success without asking
      # is how that comes back silently.
      _odalive=$(pkg_live_pids "$pkg" "$uid")
      if [ -n "$_odalive" ]; then
        echo "[roamd] WARN odrestore $pkg -> am force-stop rc=$_odfsrc but STILL RUNNING (pids: $_odalive) -- restore may be clobbered by the gap process $(date)" >> "$LOG"
      else
        echo "[roamd] odrestore $pkg -> force-stopped pre-restore, rc=$_odfsrc (gap process; hold exists) $(date)" >> "$LOG"
      fi
    fi
    odn=0; odsrc=0; odkept=0
    # DIA-20260816-19: the EXTERNAL volumes ride the same loop. Their dest is created by the app/MediaProvider
    # rather than installApks, so a missing dest is normal here -- mkdir it, then the shared body copies the
    # hold in. Order matters: CE/DE first (installApks made those dirs), external after.
    for vol in "/data/user/$uid" "/data/user_de/$uid" "/data/media/$uid/Android/data" "/data/media/$uid/Android/obb"; do
      src="$vol/com.nowhere.chooser/$ODHOLD/$pkg"   # hold lives under the chooser pkg dir (reconcile-safe)
      dst="$vol/$pkg"
      case "$vol" in
        /data/media/*) [ -d "$src" ] && [ ! -d "$dst" ] && mkdir -p "$dst" 2>>"$LOG" ;;
      esac
      [ -d "$src" ] || continue
      odsrc=1
      cutoff_prog od   # NWP-20261119-09: one progress line per held volume for the daemon's 150 s stall clock; no package name
      # NWP-20260913-03: THE DEST EXISTING IS NOT THE SAME AS THE APP BEING INSTALLED, and the difference is
      # every message in the app. Device-proven on lynx 2026-09-13 (agent 2026091209), reproducing Chester’s
      # "whatsapp messages disappear after a roam": login parked 76 MB of com.whatsapp CE data correctly
      # ("held on-demand data com.whatsapp (/data/user/15)"), and 17 seconds later THIS BRANCH gave it back --
      # into a directory belonging to a package the platform did not have:
      #     SELinux: Could not look up information for package com.whatsapp, cannot restorecon /data/user/15/com.whatsapp
      #     restorecon: restorecon failed: /data/user/15/com.whatsapp
      #     [roamd] odrestore com.whatsapp (/data/user/15) restored+reowned   <-- logged success over that
      # The hold was consumed, the data sat root-owned in the canonical dir, and the REAL install at the tap
      # wiped it: msgstore gone, 76M -> 65M, WhatsApp asked to register again. `[ -d "$dst" ]` alone cannot
      # tell installApks’ app-owned dir from a placeholder or leftover one, and this op has a SECOND caller
      # (AppInstallReceiver, every install path) that can reach it before the real APK lands.
      #
      # So require what actually matters: the dest is owned by THIS user’s app uid. installd creates it that
      # way; a placeholder or leftover is root-owned. An unresolvable appId counts as not-ready too -- keeping
      # a hold is always recoverable (the next tap re-fires this op), consuming one wrongly never is. That is
      # this op’s own stated rule: "NEVER destroy the only copy".
      #
      # ⚠ CE/DE ONLY. The external volumes above have their dest MKDIR’d by this script, so they are root-owned
      # by construction and an ownership test there would refuse every external restore.
      case "$vol" in
        /data/user/*|/data/user_de/*)
          if [ -d "$dst" ]; then
            # Exact on field 1 (NWP-20261111-22): the grep this replaced read $pkg as a regex, so a look-alike's appId kept the hold.
            _odappid=$(NW_PKG="$pkg" awk '$1 == ENVIRON["NW_PKG"] { print $2; exit }' /data/system/packages.list 2>/dev/null)
            case "$_odappid" in
              ""|*[!0-9]*) _odwant="";;
              *) _odwant=$((uid * 100000 + _odappid));;
            esac
            _odgot=$(stat -c "%u" "$dst" 2>/dev/null)
            if [ -z "$_odwant" ] || [ "$_odgot" != "$_odwant" ]; then
              echo "[roamd] odrestore $pkg ($vol) dest NOT app-owned (is ${_odgot:-?}, want ${_odwant:-unresolved}) -- not installed for this user yet; hold KEPT (NWP-20260913-03) $(date)" >> "$LOG"
              odkept=$((odkept+1))
              continue
            fi
          fi
          ;;
      esac
      if [ -d "$dst" ]; then
        # installApks created the app-owned (empty) data dir; copy the held data INTO it (preserves installd's dir +
        # its PMS-tracked inode), reown the whole tree to the app uid (idempotent), relabel, then drop the hold.
        # cp -a "$src"/. copies contents incl. dotfiles; only rm the hold on a clean copy so a failure is recoverable.
        # NWP-20260922-09: reown/relabel/count/log moved INSIDE the copy. They used to run unconditionally,
        # so a PARTIALLY FAILED cp -- half the messages copied, hold correctly kept -- was counted in `odn`
        # and logged "restored+reowned", the same shape as the failure the probe above exists to catch.
        # reown+restorecon still run on a failure (the bytes that DID land must not stay root-owned), but the
        # claim of success does not, and `odn` stays honest so the reply below can refuse.
        # NWP-20261109-09: the copy's and rm's per-file errors stay out of roam.log -- see hold_ondemand's CE/DE merge.
        # NWP-20261121-02: on an external volume a live mediad overlay inside $dst refuses every write under it (Q114
        # keeps Android/data deferred), so od_served_copy copies around the entries it serves. Only when mediad has
        # published media-unders: with none, or none live under $dst (rc 2), the plain copy below runs as before.
        _odsc=2; _odsk=
        case "$vol" in
          /data/media/*)
            if [ -n "${STATE:-}" ] && [ -s "$STATE/media-unders" ]; then
              _ce=$(od_watched "$dst" od_served_copy "$src" "$dst"); _odsc=$?
              case "$_ce" in *served=*) _odsk=${_ce##*served=}; _ce=${_ce%served=*}; _ce=${_ce%?};; esac
              case "$_odsc:$_odsk" in 2:*) _odsk= ;; *:|*:*[!0-9]*) _odsk=0 ;; esac
            fi ;;
        esac
        [ "$_odsc" = 2 ] && { _ce=$(od_watched "$dst" cp -a "$src"/. "$dst"/); _odsc=$?; }
        if [ "$_odsc" = 0 ]; then
          # NWP-20261119-09: reown and relabel BEFORE the hold is dropped; both are idempotent, so a retry over a reowned copy is safe.
          # ONE WINDOW IS LEFT: `cp -a "$src"/.` also gives $dst itself the hold's owner (root), so a stop after the copy
          # and before reown_restored changes $dst's top-level owner leaves a root-owned $dst beside the full hold. Every
          # retry this session then keeps the hold at the NWP-20260913-03 probe; the next sign-in's hold_ondemand merge
          # recovers it. A stop at any later point leaves an app-owned $dst with the hold, or a finished $dst.
          reown_restored "$dst"
          od_relabel "$vol" "$dst"
          rm -rf "$src" 2>/dev/null
          [ -e "$src" ] && echo "[roamd] WARN odrestore $pkg ($vol) could not remove all of the hold after the merge -- the rest is left in place (NWP-20261109-09) $(date)" >> "$LOG"
          odn=$((odn+1))
          _odsn=; [ -n "$_odsk" ] && _odsn=" ($_odsk entr(y/ies) left served by mediad)"
          echo "[roamd] odrestore $pkg ($vol) restored+reowned$_odsn $(date)" >> "$LOG"
        else
          # ⚠⚠ NWP-20261005-03: DO NOT "fix" a refused chown here by counting the restore as done. The known
          # cause of `cp: chown ... Permission denied` on a CE hand-back is a read-only mediad overlay over a
          # deferred dir (WhatsApp files/Logs; Play's files/phonesky-download-service/<n>; both device-seen):
          # the destination there is a stub tree, so bytes that seem to have landed did not, and dropping the
          # hold would delete the only real copy. The fix is to stop deferring CE files (NWP-20260923-02).
          # The external volume keeps deferring (Q114) and copes with a served destination: od_served_copy (NWP-20261121-02).
          reown_restored "$dst"
          od_relabel "$vol" "$dst"
          _cn=$(printf '%s\n' "$_ce" | grep -c .)
          _cl=$(printf '%s\n' "$_ce" | sed -n '$p')
          case "$_cl" in *': '*) _cl=${_cl##*: } ;; *) _cl= ;; esac
          case "$_cl" in ''|*/*|*\'*|*\"*) _cl=error ;; esac
          [ "${#_cl}" -le 80 ] || _cl=error
          echo "[roamd] WARN odrestore $pkg ($vol) cp FAILED -- hold KEPT, NOT counted as restored (NWP-20260922-09) $(date) ($_cn error line(s), last: $_cl)" >> "$LOG"
          odkept=$((odkept+1))
        fi
      else
        echo "[roamd] odrestore $pkg ($vol) dest missing -- hold KEPT $(date)" >> "$LOG"
        odkept=$((odkept+1))
      fi
    done
    # NWP-20261012-05, NWP-20261022-05: the declined pass only on the package's FIRST install this session: one the
    # hold shows (data parked at login) OR one this session's own materialise recorded in the chooser's
    # nowhere-od-materialised (UnarchiveService writes it after installApks and before RESTORE-ODDATA; roam-in clears
    # it, so it lists only this session's materialises). The install-heal sends this op for updates too; an update of
    # such an app finds it in $STATE/.declined.<uid> and declines nothing (see grant_perms_for). _first decides only
    # the declines -- the hold alone still decides everything about data. NOT covered: an app another installer
    # (Play, Aurora, the App store) installs over a placeholder with no parked data is in neither record, so its
    # declines still wait for a sign-in at which it is installed.
    _first="$_hold"
    [ "$_first" = 1 ] || { grep -qxF -- "$pkg" "$USERDIR/com.nowhere.chooser/files/nowhere-od-materialised" 2>/dev/null && _first=1; }
    # NWP-20261122-03: ONE filtered pm read of this package decides the four steps below. pm's FILTER matches
    # substrings, so only the exact line `package:<pkg> uid:<digits>` counts, newline-anchored in-shell as
    # keystore_register_all matches its capture (a look-alike such as <pkg>.bar never counts).
    #   - Listed without -a: the app has code. Its namespace goes to keystore_register, which then lists nothing
    #     (before this, its one-argument form listed every package on the device to find this one line).
    #   - Absent without -a and listed with it: read as an ARCHIVED PLACEHOLDER with no code for this user yet. That
    #     reading is an INFERENCE from the `-a INCLUDES ARCHIVED` note at keystore_register_all (NWP-20260827-06), not
    #     a device measurement. Nothing can be granted to a package with no APK, and its real install runs this op
    #     again (the install-heal at PACKAGE_ADDED), so the grant, a11y, autofill and Keystore steps are left to that
    #     run. Run here, they spent the package's once-per-session records (.declined.<uid>, .a11ydone,
    #     .autofilldone) on the placeholder, and the install's declines pass was then skipped. -a also lists a package
    #     installed only for another user; skipping is right there too, for the same reasons.
    #   - Any other answer (no exact line in either call, a uid that is not all digits, a pm failure): the steps run
    #     exactly as before, the one-argument keystore_register included.
    # The external re-own, the account block and the reply below do not depend on this.
    _odnl='
'
    _odcode=""; _odns=""
    if _odpu=$(pm list packages -U --user "$uid" "$pkg" </dev/null 2>/dev/null); then
      _odpu="$_odnl$_odpu$_odnl"
      case "$_odpu" in
        *"${_odnl}package:$pkg uid:"*)
          _odns=${_odpu#*"${_odnl}package:$pkg uid:"}; _odns=${_odns%%"$_odnl"*}
          case "$_odns" in ''|*[!0-9]*) _odns="" ;; *) _odcode=yes ;; esac ;;
        *)
          if _odpu=$(pm list packages -U -a --user "$uid" "$pkg" </dev/null 2>/dev/null); then
            _odpu="$_odnl$_odpu$_odnl"
            case "$_odpu" in
              *"${_odnl}package:$pkg uid:"*)
                _odpu=${_odpu#*"${_odnl}package:$pkg uid:"}; _odpu=${_odpu%%"$_odnl"*}
                case "$_odpu" in ''|*[!0-9]*) ;; *) _odcode=no ;; esac ;;
            esac
          fi ;;
      esac
    fi
    if [ "$_odcode" = no ]; then
      echo "[roamd] odrestore $pkg -> no code for user $uid yet: grant, a11y, autofill and Keystore steps left to its install (NWP-20261122-03) $(date)" >> "$LOG"
    else
      grant_perms_for "$uid" "$pkg" "$_first" ${odbatch:+"$odbatch"}
      a11y_apply "$uid" "$pkg"  # NWP-20261108-18: Q024 -- this app's carried a11y entries, once per session (.a11ydone)
      autofill_apply "$uid" "$pkg"  # NWP-20261112-12: Q078 -- this app's carried autofill service, once per session (.autofilldone)
      # Once per package per session because this op runs again at every update of the app (the heal sends it on every
      # PACKAGE_ADDED), and a re-apply there would undo an autofill switch-off made this session.
      # #210 p2: the app's uid exists for the first time HERE -- installApks has run, so packages.list carries a
      # stable appId. Register it for keystore2 to export at reap, and promote any restored bundle to the
      # uid-keyed filename the import hook looks for. NWP-20261122-03: with the namespace read above, or with ""
      # when that read gave none, so keystore_register lists the packages itself as before.
      keystore_register "$pkg" "$_odns"
    fi
    # NWP-20261125-08: the list's last op (i = n) removes the list's -3 read HERE, after the grant step and outside
    # grant_perms_for: an archived placeholder skips that function, which would otherwise leave the file behind until
    # the next sign-in.
    [ "$odlast" = 1 ] && rm -f "$STATE/.odbatch3.$uid.${odbatch%%.*}" 2>>"$LOG"
    # DIA-20260730: also reown this app's EXTERNAL app-data (/data/media/N/Android/{data,obb}/PKG). At login it was
    # blanket-media_rw'd by remap_tree BEFORE the on-demand appId existed, so the app can't read its own files
    # (il2cpp/unity.ver etc. -> EACCES -> "not enough storage to install required resources"). installApks has now
    # landed the stable appId, so this resolves + fixes it. Independent of $odsrc (that tracks only the CE/DE hold).
    reown_ext_appdata "$pkg"; restorecon -R -D "/data/media/$uid/Android/data/$pkg" 2>>"$LOG"
    # group-materialize (DIA-20260802): if this is the account authenticator AND the grant op DEFERRED its reload
    # (on-demand group member), fire the #sys account reload NOW -- its APK + authenticator are installed and its
    # held data is restored, so AMS re-reads the account with the authenticator present. The marker gates this to
    # the on-demand path so the proven installed-gms timing (reload at grant) is unchanged. acct_reload is
    # idempotent (no-ops if the acct-hold was already consumed).
    if [ "$pkg" = "$ACCT_AUTH_PKG" ]; then
      # group-materialize (DIA-20260802-12): a freshly-materialised gms has NO checkin identity (android_id=0 --
      # checkin state does not roam), so Play Store loops on "Reauthenticating account ... try again" until a checkin
      # lands. Kick it NOW -- this runs BEFORE the entry point (vending) materialises + auto-launches Finsky ~a
      # minute later, so Play starts with android_id already established instead of caching the no-identity state (a
      # stale pre-checkin Finsky kept failing until force-stopped -- proven odtest22->user11). Fire-and-forget over
      # the net; the ~60s until vending auto-launches is ample. stdio -> /dev/null (su:s0 cmd fd denial).
      # --include-stopped-packages is MANDATORY and is tied to the pre-restore force-stop at the top of this op:
      # that kill leaves $pkg in the STOPPED state, and AMS adds FLAG_EXCLUDE_STOPPED_PACKAGES to every broadcast
      # unless the sender opts in, so PM filters a stopped package's manifest receivers out of resolution --
      # without the flag this kick is silently dropped (and the log line below would still claim success), gms
      # never checks in, android_id stays 0 and Finsky is back in the "Reauthenticating account" loop this fix
      # exists to prevent. Nothing between the kill and here un-stops gms (cp/reown/restorecon, pm grant,
      # keystore_register all leave the flag set) and materializeMember never launches a dep. Opting in also
      # cold-STARTS gms, which is what the kick wants anyway -- and clears the stopped flag before the
      # acct_reload below, so its LOGIN_ACCOUNTS_CHANGED fan-out reaches gms too. Do NOT "simplify" this to
      # `-f 0x00000020`: -f is setFlags (clobbers), while --include-stopped-packages addFlags's it.
      am broadcast --user "$uid" --include-stopped-packages -a android.server.checkin.CHECKIN </dev/null >/dev/null 2>&1
      echo "[roamd] odrestore $pkg -> checkin kicked (android_id bootstrap) $(date)" >> "$LOG"
      # BLOCKER 2: if the grant op DEFERRED the #sys reload (on-demand group member), fire it NOW -- but first WAIT
      # for gms's account authenticator to register, else validateAccountsInternal purges the account. The marker
      # gates this to the on-demand path so the proven installed-gms timing (reload at grant) is unchanged.
      # acct_reload is idempotent (no-ops if the acct-hold was already consumed).
      if [ -f "/data/nowhere/acct-deferred-$uid" ]; then
        wait_acct_authenticator "$uid"
        acct_reload "$uid"; rm -f "/data/nowhere/acct-deferred-$uid" 2>>"$LOG"
        # NWP-20261010-15: the deferred half of grant's sync apply, STRICTLY after the reload above and right here,
        # on the user's path: correctness over latency. Deferring it to a seal left a window in which a "Turn on" the
        # user made, or a switch of an account this same reload placed, was then overwritten by the carried record.
        # The cost is one helper run on this materialise (two JVM starts, typically 1-2 s, bounded at SYNC_TIMEOUT).
        # A failure is retried at the next seals by the bounded sync_apply_retry.
        sync_apply "$uid"
        echo "[roamd] odrestore $pkg -> deferred acct_reload fired (group-materialize) $(date)" >> "$LOG"
      fi
    fi
    # ⚠⚠ NWP-20260922-09: THREE OUTCOMES, NOT TWO. `odsrc` records only that a hold EXISTED; it is set at
    # ~:4096 BEFORE the NWP-20260913-03 ownership probe, whose miss path logs "dest NOT app-owned ... hold
    # KEPT" and `continue`s. So when every volume deliberately kept its hold, this line still answered
    # "OK $pkg" -- and both callers mark on ANY reply starting with OK. markOdRestored’s own comment promises
    # it marks "ONLY on a confirmed OK ... so a later tap re-materialises anything whose restore did not
    # land" (~~re-materialises~~ -- SUPERSEDED by NWP-20261012-04: a later sweep or tap now retries the RESTORE
    # only, never a re-download or reinstall of an app that has code); the false OK defeated exactly that
    # promise, so nothing ever retried and the hold stranded for the rest of the profile’s life. That stranded hold is what arms the merge branch in hold_ondemand.
    # `odn` counts volumes actually handed back, but ONE counter across CE, DE, external data and obb answered
    # OK whenever any volume succeeded, so a CE failure beside an external success was masked: marker written,
    # retry suppressed, CE hold stranded (NWP-20260923-01, the frankel ticket). The reply is therefore PER-VOLUME:
    # `odkept` counts every volume whose hold was kept, and any kept hold answers ERR-NOTREADY. That is safe
    # since NWP-20261012-04: a retry is a RESTORE-ODDATA alone and never re-downloads or reinstalls an app that
    # has code, and an external hold already consumed is simply absent on the retry (it adds nothing to
    # `odsrc` or `odkept`), so the retry converges instead of looping.
    #
    # A non-OK reply is already a supported, safe answer on BOTH sides: UnarchiveService (twice) and
    # AppInstallReceiver each ~~log "unconfirmed -- next tap will re-materialise it"~~, skip the marker, and
    # still open the app. No Java change, no versionCode bump. SUPERSEDED in part by NWP-20261012-04: the
    # chooser now logs "unconfirmed -- the next sweep or tap retries the restore only", and that retry is a
    # RESTORE-ODDATA alone -- it never re-downloads or reinstalls an app that has code.
    # NWP-20261130-03: an OK reply means the data is back and the block od_block_app set above, if any, is off. A block
    # that will not lift keeps its record and answers ERR-NOTREADY, so the next sweep or tap retries the unblock.
    # NWP-20261130-03: the pending marker goes before the OK reply: the chooser asks OD-DATA-PENDING as soon as it reads
    # OK, and lifts its suspension only on NO.
    if [ "$odsrc" = 0 ]; then
      if od_unblock_app "$pkg"; then od_pending_clear "$pkg"; echo "OK NOSRC" > "$RES"; else echo "ERR-NOTREADY" > "$RES"; fi
    elif [ "$odkept" -gt 0 ]; then
      echo "[roamd] odrestore $pkg -> hold(s) kept on $odkept volume(s) -- ERR-NOTREADY so the next sweep or tap retries the restore (NWP-20260922-09, NWP-20261013-22) $(date)" >> "$LOG"
      echo "ERR-NOTREADY" > "$RES"
    else
      if od_unblock_app "$pkg"; then od_pending_clear "$pkg"; echo "OK $pkg" > "$RES"; else echo "ERR-NOTREADY" > "$RES"; fi
    fi
    ;;
  silence-alarm)
    # NWP-20260913-07 (#151): stop the clock app that is ringing inside the roamed session, on behalf of the
    # gate. The gate's Alarm screen lives in user 0 and its Dismiss cannot reach an app in user N, so both
    # clocks sound until someone signs in -- device-observed on lynx 2026091301.
    #
    # ⚠ IT LIVES HERE AND NOT IN THE DAEMON, AND THAT IS THE WHOLE POINT. The first cut ran `am` from the
    # daemon, whose domain is init_daemon_domain with NO service_manager find and no binder grants:
    #   avc: denied { find } ... name=activity scontext=u:r:nowhere:s0 tcontext=u:object_r:activity_service:s0
    # It logged "silenced" and the phone kept ringing. Granting the daemon its way to ActivityManager would
    # mean find + binder_call + the exec chain on a ROOT daemon, each one a build cycle to find; roamd already
    # runs this exact command today (the odrestore force-stop above), so the reach already exists here.
    pkg="$srcunit"
    case "$pkg" in ""|*/*|*" "*|-*) echo "[roamd] silence-alarm bad pkg $(date)" >> "$LOG"; echo "ERR-PKG" > "$RES"; chmod 600 "$RES"; exit 0;; esac
    am force-stop --user "$uid" "$pkg" </dev/null >/dev/null 2>&1
    _sarc=$?
    # ⚠⚠ OBSERVE THE OUTCOME, DO NOT REPORT THE CALL. The bug this op replaces was not the denial -- it was
    # that the code discarded the result and logged success beside it, which is the fifth time a silent no-op
    # in this tree has claimed to work. `am` exiting 0 is not evidence the app stopped, so ask.
    _salive=$(pkg_live_pids "$pkg" "$uid")
    if [ -n "$_salive" ]; then
      echo "[roamd] silence-alarm $pkg (user $uid): am rc=$_sarc but STILL RUNNING (pids: $_salive) -- NOT silenced $(date)" >> "$LOG"
      echo "ERR-LIVE" > "$RES"
    else
      echo "[roamd] silence-alarm $pkg (user $uid): stopped, am rc=$_sarc $(date)" >> "$LOG"
      echo "OK" > "$RES"
    fi
    ;;

  seed-home)
    # E.5d: seed a fresh profile's page-2 home apps (see seed_home). Triggered by the daemon a few seconds
    # AFTER grant (a SEPARATE, non-blocking op) -- NOT inline in grant, because the launcher creates its
    # launcher.db only a few seconds after the user switch, and grant holds the shared worker lock, so a long
    # poll there would stall every other roamd op. Here it's a brief, isolated op. No-op once seeded.
    seed_home "$uid" "$USERDIR"
    seed_aurora_installer "$uid"   # DIA-20260731: default Aurora -> AuroraServices silent installer (Option 2)
    # NWP-20261015-39 (#122): the reply names what seed_home did, in ONE redirect (the poller returns at the first
    # non-empty byte). An empty verdict would leave $RES empty -- the poller would wait out its whole timeout.
    echo "${SEED_VERDICT:-ERR-SEED noverdict}" > "$RES"
    ;;

  vpnup)
    # #159 (DIA-20260721-05d): establish + RAISE the roamed profile's always-on VPN. A SHORT op -- the long-lived
    # daemon (retryVpnup) RETRIES this until "OK", because roamd is a oneshot init service (init SIGKILLs its
    # cgroup on exit) and MUST NOT wait, and the nowhere:s0 daemon can't call setAlwaysOnVpnPackage (uid-0). The work
    # and every answer are vpn_apply's (NWP-20261010-15).
    vpn_apply "$uid" > "$RES"
    ;;
  telingest)
    # #135 B2 delivery v2: RETIRED -- the roamed chooser now pulls + inserts its own telephony rows (see the
    # comment where tel_ingest lived). Kept as an accepted no-op so a mixed daemon/worker pair during an
    # update window can't error a login.
    echo "OK" > "$RES"
    ;;
  cutoff)
    # NWP-20261011-04: the logoff cutoff (see the block above cutoff_keep). $srcunit (roam.req line 7) is the package
    # that owns the session's next alarm clock, or empty. Answers:
    #   OK <n>                 <n> packages stopped, and a listing after the stop shows none of them running
    #   PARTIAL <n> <left>     <left> packages outside the keep-set still not stopped (the budget ran out, or one would
    #                          not stop); the logoff seals anyway, as every logoff did before this op existed
    #   UNVERIFIED <n>         the listing after the stop could not be read
    #   ERR-LIST               the package list could not be read: NOTHING was stopped
    #   ERR-RECORD             the record could not be written whole: NOTHING was stopped, and an earlier record is
    #                          left as it was
    # The record ($STATE/.cutoff.<uid>) is written BEFORE the first stop, so a worker killed mid-pass still leaves
    # cutoffwake everything it may have stopped. It is a UNION with any record already there: a sign-out that failed
    # and whose wake never ran must not have its stopped set forgotten by the retry. umask 077: the record and its
    # scratch files hold the profile's package names, so they are 0600 from the moment they exist.
    # NWP-20261125-21 (the NWP-20261119-13 rule): a short write changes nothing. The union replaces the record only
    # when its pipeline succeeded and it holds every line of this pass's live set and of the earlier record. The check
    # counts the missing lines with grep -cvxF, never with sort: with an emptied union, -v selects every line, so it
    # is refused. A refused union leaves the record as it was and stops NOTHING, so no package is stopped that the
    # wake cannot find.
    umask 077
    _ct0=$(_ms); _cdl=$(( $(date +%s) + CUTOFF_BUDGET ))
    _cf="$STATE/.cutoff.$uid"
    cutoff_prog list
    _ckeep=$(cutoff_keep "$uid" "$srcunit")
    _call=$(cutoff_list "$uid")
    case "$_call" in
      *"package:"*)
        _ckuid=$(printf '%s\n' "$_call" | cutoff_keepuids "$_ckeep")
        printf '%s\n' "$_call" | cutoff_filter "$_ckeep" "$_ckuid" false > "$_cf.new"
        cat "$_cf" "$_cf.new" 2>/dev/null | sort -u > "$_cf.tmp"; _crc=$?
        _cn=$(grep -c . "$_cf.new" 2>/dev/null); _cn=${_cn:-0}
        _cro=0; [ -e "$_cf" ] && { _cro=$(grep -c . "$_cf" 2>/dev/null); _cro=${_cro:-0}; }
        # Complete only when every line of the live set, and of an earlier record, is a whole line of the union: a
        # count of 0 with grep's status 0 or 1. Status 2 (an input or the union unreadable) refuses.
        _cok=no
        if [ "$_crc" = 0 ]; then
          _cok=yes
          for _cq in "$_cf.new" "$_cf"; do
            [ "$_cq" = "$_cf" ] && [ ! -e "$_cf" ] && continue
            _cmiss=$(grep -cvxF -f "$_cf.tmp" "$_cq" 2>/dev/null); _cgs=$?
            case "$_cgs:$_cmiss" in 0:0|1:0) ;; *) _cok=no ;; esac
          done
        fi
        if [ "$_cok" = yes ]; then
          mv -f "$_cf.tmp" "$_cf"; chmod 600 "$_cf" 2>/dev/null
          cutoff_run stop "$uid" "$_cf.new" "$_cdl"
          # Second pass: anything running again -- started by a peer that was still alive while the first pass ran (an
          # explicit start un-stops a package), or not reached. Only the FIRST pass's set is recorded for the wake: a
          # package that was stopped when the sign-out began is left stopped.
          cutoff_list "$uid" | cutoff_filter "$_ckeep" "$_ckuid" false > "$_cf.new"
          if [ -s "$_cf.new" ]; then cutoff_run stop "$uid" "$_cf.new" "$_cdl"; fi
          _call=$(cutoff_list "$uid")
          case "$_call" in
            *"package:"*)
              _cleft=$(printf '%s\n' "$_call" | cutoff_filter "$_ckeep" "$_ckuid" false | grep -c .)
              if [ "${_cleft:-0}" -eq 0 ]; then echo "OK $_cn" > "$RES"; else echo "PARTIAL $_cn $_cleft" > "$RES"; fi ;;
            *) _cleft=unknown; echo "UNVERIFIED $_cn" > "$RES" ;;
          esac
          rm -f "$_cf.new"
          _cak=no; [ -n "$srcunit" ] && case "$_ckeep" in *" $srcunit "*) _cak=yes ;; esac
          echo "[roamd] cutoff user $uid: stopped $_cn package(s), $_cleft still running, $(echo $_ckeep | wc -w) kept (+$(echo $_ckuid | wc -w) shared uid(s)), alarm owner kept=$_cak, $(( $(_ms) - _ct0 ))ms (NWP-20261011-04) $(date)" >> "$LOG"
        else
          rm -f "$_cf.tmp" "$_cf.new" 2>/dev/null
          echo "ERR-RECORD" > "$RES"
          echo "[roamd] cutoff user $uid: record could not be written ($_cn live, $_cro already recorded) -- NOTHING stopped; the logoff seals as it did before the cutoff (NWP-20261125-21) $(date)" >> "$LOG"
        fi
        ;;
      *)
        echo "ERR-LIST" > "$RES"
        echo "[roamd] cutoff user $uid: package list unreadable -- NOTHING stopped; the logoff seals as it did before the cutoff (NWP-20261011-04) $(date)" >> "$LOG"
        ;;
    esac
    unset _ct0 _cdl _cf _ckeep _ckuid _call _cn _cleft _cak _crc _cro _cok _cq _cmiss _cgs
    ;;
  cutoffwake)
    # NWP-20261011-04: undo the cutoff for a session that STAYS signed in -- a sign-out whose sweep did not verify,
    # whose seal failed or was refused, or whose verdict landed after the stall watchdog un-stuck it. Answers WAKE OK <n>,
    # WAKE PARTIAL <n> <still stopped>, WAKE UNVERIFIED <n>; WAKE OK 0 when there is no record (nothing was stopped, or a
    # wake already ran: it is idempotent, which the daemon relies on). Each pass is bounded by CUTOFF_BUDGET like the cutoff.
    # THE RECORD FOLLOWS THE ANSWER (NWP-20261125-21). WAKE OK deletes it. A partial wake keeps the recorded packages
    # that still read stopped=true, and only those, recorded for the next wake; the daemon asks once more. An unverified
    # wake keeps the record whole. A leftover that cannot be written whole keeps the old record: a second unstop of an
    # app already awake is harmless, and a package dropped from the record stays stopped for the session.
    # ⚠ THE ANSWER NAMES THE OP (round 3). An op that timed out on the daemon's side -- a media sweep answering
    # ERR-TIMEOUT -- can still be running here, so init ignores the ctl.start for THIS run and the late op's own answer is
    # the next roam.res written; a bare "OK" from it would read as this wake's. The daemon takes only a "WAKE " answer.
    #
    # WHAT THIS RESTORES -- and what it cannot, stated plainly so nobody reads "woken" as "as it was":
    #   restored  every package the cutoff stopped leaves the stopped state (`pm unstop`, which is exactly
    #             setPackageStoppedState(false)): implicit broadcasts reach it again, and push messages are delivered
    #             to it again once Play services runs. Play services, if it was stopped, is STARTED again with the
    #             checkin kick odrestore already uses, so push resumes without the user opening an app.
    #   re-armed  the alarms and JobScheduler jobs the stop cancelled, as far as the app re-arms them at boot (round 3):
    #             each recorded package is sent LOCKED_BOOT_COMPLETED then BOOT_COMPLETED, explicitly (-p), with the
    #             foreground-service start allowance a real boot carries. `pm unstop` alone sends only a REGISTERED-ONLY
    #             PACKAGE_UNSTOPPED, which an app that is not running never sees. ⚠ What re-arms is up to each app. Read
    #             from the default APKs (aapt2, round 4): WorkManager's RescheduleReceiver ships DISABLED in every one of
    #             them, so WorkManager work comes back only through the app's own boot receiver or when it is next
    #             opened. Own boot receivers: Etar's reminders are scheduled by com.android.providers.calendar
    #             (CalendarReceiver: BOOT_COMPLETED), Conversations (SystemEventReceiver), Thunderbird
    #             (BootCompleteReceiver, push), Notally (ReminderReceiver), BreezyWeather (BootReceiver), F-Droid
    #             (StartupReceiver), WireGuard (BootShutdownReceiver), Aegis (QsTileRefreshReceiver). None: AntennaPod,
    #             AuroraStore, Fennec, NewPipe, OrganicMaps, Catima, AuroraServices -- their work waits for the next open.
    #             These are protected broadcasts: AMS lets ROOT_UID send them (BroadcastController isCallerSystem), roamd
    #             runs as root (nowhere.rc), and it already runs `am broadcast` here (the checkin kick, the WireGuard
    #             raise) under the same activity_service grant.
    #   ORDER     (round 4) both passes are bounded, so who comes first matters when the budget truncates: Play
    #             services (push), the calendar provider (reminders), then the default SMS and dialer apps, then the
    #             rest. The alarm clock's owner is never stopped, so it needs no place here.
    #   restarts by itself  the launcher (home is restarted when shown), the keyboard (the IME binding reconnects),
    #             an app the user opens.
    #   NOT restored  the processes themselves beyond what a boot broadcast starts; alarms and jobs of an app that
    #             re-arms them only when OPENED (not at boot); the notifications the stop cleared; a foreground service.
    umask 077
    _cf="$STATE/.cutoff.$uid"
    if [ ! -s "$_cf" ]; then
      rm -f "$_cf"; echo "WAKE OK 0" > "$RES"
      echo "[roamd] cutoffwake user $uid: nothing to wake (NWP-20261011-04) $(date)" >> "$LOG"
    else
      _wn=$(grep -c . "$_cf" 2>/dev/null); _wn=${_wn:-0}
      # ORDER (above): the priority packages that are in the record, in priority order, then the rest as recorded.
      _wsms=$(timeout -k 2 10 settings get --user "$uid" secure sms_default_application </dev/null 2>/dev/null)
      _wdial=$(timeout -k 2 10 settings get --user "$uid" secure dialer_default_application </dev/null 2>/dev/null)
      _wpri=" "; ( : > "$_cf.ord" )
      for _p in "$ACCT_AUTH_PKG" com.android.providers.calendar "$_wsms" "$_wdial"; do
        cutoff_pkgok "$_p" || continue
        case "$_wpri" in *" $_p "*) continue ;; esac
        grep -qxF "$_p" "$_cf" || continue
        echo "$_p" >> "$_cf.ord"; _wpri="$_wpri$_p "
      done
      while IFS= read -r _p; do
        case "$_wpri" in *" $_p "*) ;; *) echo "$_p" >> "$_cf.ord" ;; esac
      done < "$_cf"
      # The deadline starts HERE, after the two `settings get` reads above (up to ~12 s each), so they cannot eat the
      # unstop pass's budget.
      _wdl=$(( $(date +%s) + CUTOFF_BUDGET ))
      cutoff_run unstop "$uid" "$_cf.ord" "$_wdl"
      _wgms=no
      if grep -qxF "$ACCT_AUTH_PKG" "$_cf"; then
        # The odrestore kick, for the same reason: it cold-STARTS Play services, which push needs running.
        timeout -k 2 10 am broadcast --user "$uid" --include-stopped-packages -a android.server.checkin.CHECKIN </dev/null >/dev/null 2>&1
        _wgms=yes
      fi
      # The boot re-arm, AFTER the unstop and the Play kick, on its own budget so a slow unstop pass cannot starve it.
      cutoff_run boot "$uid" "$_cf.ord" "$(( $(date +%s) + CUTOFF_BUDGET ))"
      _wboot=${CUTOFF_RAN:-0}
      _call=$(cutoff_list "$uid")
      case "$_call" in
        *"package:"*)
          # Of the recorded packages, how many still read stopped=true.
          _wst=" $(printf '%s\n' "$_call" | cutoff_filter " " " " true | tr '\n' ' ')"
          _wleft=0
          while IFS= read -r _p; do
            case "$_wst" in *" $_p "*) _wleft=$((_wleft + 1)) ;; esac
          done < "$_cf"
          if [ "$_wleft" -eq 0 ]; then echo "WAKE OK $_wn" > "$RES"; else echo "WAKE PARTIAL $_wn $_wleft" > "$RES"; fi ;;
        *) _wleft=unknown; echo "WAKE UNVERIFIED $_wn" > "$RES" ;;
      esac
      case "$_wleft" in
        0) rm -f "$_cf" ;;
        unknown) : ;;
        *)
          # A loop of its own, in a subshell: a redirect that fails must neither end the op nor touch _wleft. A write
          # that fails ends the subshell at once: a later awake entry's unmatched case would otherwise return 0 over it,
          # and the count below counts a cut-short name as a line. The count check is the NWP-20261119-13 rule: a short
          # write changes nothing.
          if ( while IFS= read -r _p; do case "$_wst" in *" $_p "*) echo "$_p" || exit 1 ;; esac; done < "$_cf" > "$_cf.left" ) 2>/dev/null \
             && [ "$(grep -c . "$_cf.left" 2>/dev/null)" = "$_wleft" ] \
             && mv -f "$_cf.left" "$_cf" 2>/dev/null; then
            chmod 600 "$_cf" 2>/dev/null
          else
            rm -f "$_cf.left" 2>/dev/null
          fi ;;
      esac
      rm -f "$_cf.ord"
      echo "[roamd] cutoffwake user $uid: unstopped $_wn package(s), $_wleft still stopped, boot re-arm sent to $_wboot, play services kicked=$_wgms (NWP-20261011-04) $(date)" >> "$LOG"
    fi
    unset _cf _wdl _wn _p _wgms _wboot _wsms _wdial _wpri _call _wst _wleft
    ;;
  bootwake)
    # NWP-20261114-01 (docs/product-decisions.md 2026-10-24, "at sign-in, every app that asked to start at boot gets
    # the boot broadcasts once the restore has landed"): send LOCKED_BOOT_COMPLETED, then BOOT_COMPLETED, to every
    # session package that declares a receiver for one of them (bootwake_list). srcunit = one package (after its own
    # restore), or empty for all. Answers BOOTWAKE <sent> <declaring>, ERR-PKG or ERR-LIST. NOWHERE-1163 calls it.
    # These are protected broadcasts: only root may send them, so roamd sends them (see cutoff_run).
    # NOT SENT: cutoff_keep's FIXED entries (processes that got the user's real boot). The keeps cutoff_keep reads from
    # settings (the keyboard, the VPN, accessibility) are NOT excluded: they need the boot like any app. Also not sent: a
    # package whose on-demand data is still parked under the chooser's $ODHOLD on any of odrestore's four volumes. Its
    # data has not landed; its own RESTORE-ODDATA answer brings it here later.
    # ⚠ stopped=false IS NOT SKIPPED. The "Wake for notifications" unstop (UnarchiveService.wakeRestored /
    # restoreOnlyLocked) clears the stopped flag WITHOUT a boot broadcast, so the flag cannot say who missed one. A
    # non-stopped system package may get a second boot broadcast: the cost the decision accepts ("exactly what those
    # apps get after a real reboot"). The stopped ones are unstopped first, then every candidate gets the boot
    # (cutoffwake's order), each pass on its own CUTOFF_BUDGET. Counts only in the op's own log line, never a name (#39).
    # The always-on VPN lines of vpn_deferred_retry name their app, as every such line does (NWP-20261130-04).
    # The scratch is $STATE/.cutoff.<uid>.bootwake*, so cleanstorage's .cutoff.<uid>.* removal takes a killed worker's
    # leftover at the reap.
    umask 077
    _bf="$STATE/.cutoff.$uid.bootwake"
    rm -f "$_bf" "$_bf.u" "$_bf.form"
    if [ -n "$srcunit" ] && ! cutoff_pkgok "$srcunit"; then
      echo "ERR-PKG" > "$RES"
      echo "[roamd] bootwake user $uid: bad package argument -- nothing sent (NWP-20261114-01) $(date)" >> "$LOG"
    else
      _call=$(cutoff_list "$uid")
      case "$_call" in
        *"package:"*)
          # cutoff_keep's fixed entries, as a literal: cutoff_keep itself also adds the settings-read keeps (above).
          _bfixed=" com.nowhere.chooser android com.android.systemui com.android.bluetooth com.android.providers.media.module com.google.android.providers.media.module "
          _bst=" $(printf '%s\n' "$_call" | cutoff_filter " " " " true | tr '\n' ' ')"
          _blist=$(bootwake_list "$uid" "$_bf.form")
          # NWP-20261128-37: how pm's receiver listing parsed, for the log line. other > 0: the listing has a form the
          # parse does not know, so those apps were sent nothing. All three 0: pm printed nothing (a capture denial, an
          # error or the 20 s timeout). none = 2 with the rest 0: no app of the session declares a receiver. The
          # no-receivers form is from AOSP source, not from a device. An unreadable count logs as ?.
          _bfp=""; _bfn=""; _bfo=""; _bfx=""
          { read -r _bfp _bfn _bfo _bfx < "$_bf.form"; } 2>/dev/null
          case "$_bfp" in ""|*[!0-9]*) _bfp="?" ;; esac
          case "$_bfn" in ""|*[!0-9]*) _bfn="?" ;; esac
          case "$_bfo" in ""|*[!0-9]*) _bfo="?" ;; esac
          _bdecl=0; _bheld=0
          # The split is unquoted: every name passed cutoff_pkgok, so it holds no blank and no glob character.
          { for _p in $_blist; do
              _bdecl=$((_bdecl + 1))
              case "$_bfixed" in *" $_p "*) continue ;; esac
              if [ -n "$srcunit" ] && [ "$_p" != "$srcunit" ]; then continue; fi
              _bh=0
              for _bv in "/data/user/$uid" "/data/user_de/$uid" "/data/media/$uid/Android/data" "/data/media/$uid/Android/obb"; do
                [ -d "$_bv/com.nowhere.chooser/$ODHOLD/$_p" ] && { _bh=1; break; }
              done
              if [ "$_bh" = 1 ]; then _bheld=$((_bheld + 1)); continue; fi
              echo "$_p"
            done; } > "$_bf"
          _bcand=$(grep -c . "$_bf" 2>/dev/null); _bcand=${_bcand:-0}
          while IFS= read -r _p; do case "$_bst" in *" $_p "*) echo "$_p" ;; esac; done < "$_bf" > "$_bf.u"
          cutoff_run unstop "$uid" "$_bf.u" "$(( $(date +%s) + CUTOFF_BUDGET ))"; _bun=${CUTOFF_RAN:-0}
          cutoff_run boot "$uid" "$_bf" "$(( $(date +%s) + CUTOFF_BUDGET ))"; _bsent=${CUTOFF_RAN:-0}
          rm -f "$_bf" "$_bf.u" "$_bf.form"   # the scratch goes at the end too
          # NWP-20261130-04: this package's restore has landed, so a deferred always-on VPN that names it is applied now,
          # not at the next seal. Outside the receiver loop: a VPN app with no boot receiver needs it too. Before the
          # reply: the daemon's next op can start at the reply's first byte. The sign-in's all-package pass applies nothing.
          [ -z "$srcunit" ] || vpn_deferred_retry "$uid" "$srcunit"
          echo "BOOTWAKE $_bsent $_bdecl" > "$RES"
          if [ -n "$srcunit" ]; then _bwho="one package: boot broadcasts sent to $_bsent of $_bcand"
          else _bwho="boot broadcasts sent to $_bsent of $_bcand package(s)"; fi
          echo "[roamd] bootwake user $uid: $_bwho ($_bun unstopped first, $_bheld skipped with parked data, $_bdecl declare a boot receiver) (NWP-20261114-01); pm listed $_bfp component line(s), $_bfn no-receivers line(s), $_bfo other line(s) (NWP-20261128-37) $(date)" >> "$LOG"
          ;;
        *)
          echo "ERR-LIST" > "$RES"
          echo "[roamd] bootwake user $uid: package list unreadable -- nothing sent (NWP-20261114-01) $(date)" >> "$LOG"
          ;;
      esac
    fi
    unset _bf _call _bfixed _bst _blist _bdecl _bheld _bh _bv _p _bcand _bun _bsent _bwho _bfp _bfn _bfo _bfx
    ;;
  *) echo "ERR-OP" > "$RES" ;;
esac
chmod 600 "$RES"
