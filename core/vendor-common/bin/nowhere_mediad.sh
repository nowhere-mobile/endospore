#!/system/bin/sh
# Nowhere on-demand media daemon launcher (#84, su:s0 -- see nowhere.rc for why not a confined domain).
# On-demand like nowhere_roamd: the caller writes the request file into the RAM tmpfs then
# `setprop ctl.start nowhere_mediad`. Unlike roamd this LAUNCHES A LONG-RUNNING daemon: `nowhere_agent mediad`
# mounts a context=nowhere_media_file FUSE overlay per deferred-media dir and serves large media from the store
# on first open, until it is stopped at logoff/cold-lock.
#   req (state tmpfs = RAM, consumed at each START -- see the read below):  name\npass\nuid\nsesec
# This EXECs the agent (does NOT background it), so the agent is init's tracked service main process and stays
# alive -- a backgrounded daemon under a oneshot service is process-group-reaped the instant this script
# returns (init killed it 0.168s after start on-device before it could mount). Stopped via
# `setprop ctl.stop nowhere_mediad` (SIGKILL); roamd's stop_mediad then kicks the SWEEP below.
STATE=/data/nowhere/state
REQ="$STATE/mediad.req"
LOG=/data/nowhere/mediad.log          # status only -- never creds
AGENT=/system/bin/nowhere_agent
SWEEP="$STATE/mediad.sweep"

# unesc_mount PATH: decode the octal escapes /proc/mounts writes for space, tab and backslash.
#
# NWP-20260828-06. Every umount below used to take the path STRAIGHT from /proc/mounts, where a space is
# written "\040". umount(8) then names a file that does not exist and fails -- SILENTLY, because the error
# goes to $LOG and the trailing && drops the success line too, so the loop reports nothing at all. WhatsApp
# names every media folder with a space ("WhatsApp Images", "WhatsApp Voice Notes", ...), so on any profile
# with WhatsApp media EVERY overlay leaked, went ENOTCONN, and the logoff seal was refused forever: the walk
# could not read them, #111's guard correctly refused a short manifest, and the session could never be
# saved. Measured on lynx: of 126 mounts, the 60 with a space were ALL dead and the 66 without were ALL
# alive, and stop_mediad's retry loop reported "left 60 mount(s)" twice -- the same 60, every time.
#
# Mirrors unescapeMountPath in media_seal.go, which the Go walker already needed for the same reason.
# \134 (backslash) is decoded LAST so a path literally containing the text "\040" round-trips: it arrives
# as "\134040", no "\040" substring matches, and the final rule yields "\040" again -- same as the Go
# single pass. \012 (newline) is deliberately absent: it cannot survive `read` line-splitting anyway.
unesc_mount() {
  printf '%s' "$1" | sed -e 's/\\040/ /g' -e 's/\\011/'"$(printf '\t')"'/g' -e 's/\\134/\\/g'
}

# qn: a profile name as ONE escaped, double-quoted log token (NWP-20261008-09). The same helper as roamd's, where
# the reason is written down: log_scrub redacts a quoted token whole, and a bare name after `start` kept every word
# after the first. Written with `print -r --`, never echo, which would undo the escaping.
# Since NWP-20261109-02 it also renders a mount path as one scrubbable token (the sweep lines below).
qn() {
  print -rn -- "\"$(print -r -- "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')\""
}

# umount_err TEXT: the reason in a failed umount's output, as one word safe for the log (NWP-20261109-02).
# toybox writes `umount: <path>: <errno>`, and the path is the session's folder tree, which the scrub cannot
# take bare: keep only the text after the last ": " of the last line, or `error` when that has a "/" in it,
# is empty or runs past 80 bytes.
umount_err() {
  local l e
  l=$(printf '%s\n' "$1" | sed -n '$p')
  case "$l" in *': '*) e=${l##*: } ;; *) e= ;; esac
  case "$e" in ''|*/*) e=error ;; esac
  [ "$(printf '%s' "$e" | wc -c)" -le 80 ] || e=error
  printf '%s' "$e"
}

# SWEEP-ONLY MODE (E.5x). Endospore runs this daemon in its OWN confined domain (endospore_mediad) because
# mounting needs CAP_SYS_ADMIN and the roam worker deliberately does not hold it -- so roamd's stop_mediad can
# no longer umount our leftovers inline. It drops this marker and kicks us instead; we detach every mount WE
# make (for ANY user -- at logoff the profile is already going away) and remove the marker, which is how the
# caller sees we finished. Deliberately BEFORE the conf sourcing and the req read: a sweep involves no
# credentials and must still work when the profile is gone and the store is unreachable. The marker means
# "clean up", never "serve", so it wins over any req that happens to be present.
# NEVER touch /sys/fs/fuse/connections -- aborting it kills Android's own emulated-storage FUSE (see header).
if [ -f "$SWEEP" ]; then
  _t0=$(date +%s)                               # NWP-20261119-05: the sweep's time goes into its summary line
  # ONE underlying mount appears at SEVERAL paths -- the real one under /data/media or /data/user, plus
  # Android's own views of it under /data_mirror and /mnt/pass_through. Detaching any one of them takes the
  # others with it, so by the time the loop reaches a sibling entry that mount is ALREADY GONE and umount
  # fails with ENOENT/EINVAL. That is not a failure, it is the same mount counted twice.
  #
  # NWP-20260828-09: the first cut called every one of those SWEEP-FAILED and produced 114 alarming lines
  # across two clean logoffs that left /proc/mounts EMPTY. Measured over those runs, /data_mirror paths
  # detached successfully 576 times and "failed" 37 -- the same prefix on both sides of the verdict -- which
  # is why FILTERING BY PREFIX would be wrong: it would skip 576 real unmounts to silence 37 non-events.
  # Re-read /proc/mounts instead and let the kernel say whether the mount is still there. Since NWP-20261119-05
  # that re-read happens ONCE, after the loop, for every failed entry together, not once per failure.
  #
  # NWP-20261119-05 (h49 #3, docs/product-decisions.md, 2026-10-31): the sweep's work was quadratic in the mount
  # count. The list kept /proc/mounts order, so most entries were a sibling view whose layer was already gone, and
  # each such failure ran a full `cat /proc/mounts` and a grep of a table that grows with the profile. frankel's
  # large profile left 90, then 46, then 24 mounts across one sign-out's passes (ticket NW-a17e164b51d3), and one
  # field sweep logged "63 detached, 63 already gone": 63 full reads for one sign-out, long enough to outlast
  # roamd's verify wait (ERR-MEDIA-SWEEP). Now:
  #   - the list holds every fuse.nowheremedia line first (each layer and its other views), then the .under binds,
  #     each line once. Detaching a layer takes its /data_mirror and /mnt/pass_through views with it, so those
  #     entries fail fast; a bind is its own mount and detaches on its own;
  #   - a failed `umount -l` reads nothing: its raw mount field goes to $PEND as ` <field> `, and the same with its
  #     umount_err word to $PENDWHY as ` <field> <word>`;
  #   - after the loop, ONE re-read (the same unreadable rule) and field 2 of it to $MNTSET as ` <field> `; two grep
  #     -f calls split the queue: `grep -cvxF` counts $PEND's "already gone", `grep -F` copies $PENDWHY's still
  #     mounted lines to $STILL, and only those lines are walked to name them. No pending entry is searched for in
  #     the shell (an earlier cut of this slice matched each $PENDWHY line against the whole still-mounted list,
  #     quadratic again when many mounts survive). grep never gets an empty -f file (GNU and toybox differ on one):
  #     an empty $MNTSET counts every pending entry unverified, because a table with no field 2 proves nothing;
  #   - the match is exact. A raw field never holds a space or a tab (the table writes \040 and \011), so ` <field> `
  #     with -x is exact on $PEND. On $PENDWHY ` <field> ` can match only at the line's start: $MNTSET keeps only
  #     fields that start with `/` (a mount point always does), and umount_err never prints a `/`;
  #   - the summary keeps its words and adds the sweep's time (` in <n>s`), so a handset log shows the cost.
  # The verify wait in roamd's stop_mediad and its marker contract are unchanged; the decided retry stays the
  # backstop.
  #
  # NWP-20261125-13: a list the sweep cannot write is never a clean sweep. Each list's truncation is a subshell
  # (NWP-20261114-09), and a full state tmpfs or a permission change can still fail it. Now:
  #   - $SWEPT that cannot be truncated logs SWEEP-UNWRITABLE, detaches nothing and removes the lists and the marker,
  #     as SWEEP-UNREADABLE does: an empty list used to log "0 detached ... 0 FAILED, 0 unverified";
  #   - a failed write to $PEND or $PENDWHY counts that entry unverified, and once one has failed every queued entry
  #     is unverified: the queue is short, so a failure it lost would be counted nowhere;
  #   - $STILL that cannot be truncated counts every pending entry unverified: the grep's redirection failure reads
  #     as its "no line", which counted a still-mounted entry neither FAILED nor unverified.
  # Residual: the two writes of $SWEPT cannot tell a redirection failure from grep's "no line" (both are status 1).
  # A write that fails AFTER a good truncation (a tmpfs that fills mid-write) leaves a short list. stop_mediad's
  # verified read still sees the mounts that list missed.
  #
  # An alarming label on an expected failure is how the NEXT real one gets ignored.
  SWEPT="$STATE/mediad.sweep.list"
  PEND="$STATE/mediad.sweep.pending"            # NWP-20261119-05: ` <raw mount field> ` of each failed umount
  PENDWHY="$STATE/mediad.sweep.pending.why"     # the same field and its umount_err word, one space between
  MNTSET="$STATE/mediad.sweep.mounted"          # ` <field 2> ` of the one re-read after the loop
  STILL="$STATE/mediad.sweep.still"             # the $PENDWHY lines whose field is still mounted
  # NWP-20261114-09: a failed redirection on the special builtin ':' ends mksh and dash; in a subshell it ends only the subshell.
  ( : > "$SWEPT" ); _swrc=$?; chmod 600 "$SWEPT"          # 600 like the marker: everything in $STATE is root-only
  ( : > "$PEND" ); chmod 600 "$PEND"
  ( : > "$PENDWHY" ); chmod 600 "$PENDWHY"
  ( : > "$MNTSET" ); chmod 600 "$MNTSET"
  ( : > "$STILL" ); _strc=$?; chmod 600 "$STILL"
  # NWP-20261125-13: a sweep list that cannot be written is never a clean sweep. Detach nothing; remove the lists and
  # the marker as below: the caller waits on the marker and does its own verified read.
  if [ "$_swrc" -ne 0 ]; then
    echo "[mediad] SWEEP-UNWRITABLE: the sweep list could not be written -- nothing detached (NWP-20261125-13) $(date)" >> "$LOG"
    rm -f "$SWEPT"
    rm -f "$PEND" "$PENDWHY" "$MNTSET" "$STILL"
    rm -f "$SWEEP"
    exit 0
  fi
  # Read the table ONCE, keeping the status: a read that failed, or that printed nothing, is UNREADABLE
  # (no Linux system has an empty mounts table -- roamd's stop_mediad applies the same rule). This domain
  # (endospore_mediad) can lose read access to /proc/mounts while roamd's still works, and a swallowed read
  # error here logged "sweep done: 0 detached ... 0 FAILED", a clean bill from the process that detached
  # nothing. Still remove the list and the marker: the caller waits on the marker and does its own verified read.
  _mt=$(cat /proc/mounts 2>>"$LOG"); _mtrc=$?
  if [ "$_mtrc" -ne 0 ] || [ -z "$_mt" ]; then
    echo "[mediad] SWEEP-UNREADABLE: the mount table could not be read -- nothing detached $(date)" >> "$LOG"
    rm -f "$SWEPT"
    rm -f "$PEND" "$PENDWHY" "$MNTSET" "$STILL"
    rm -f "$SWEEP"
    exit 0
  fi
  # NWP-20261115-05: the table reaches grep through `print`, never as a printf argument. On the device printf is
  # /system/bin/printf (mksh has no printf builtin), so the table went through exec(2): a table over 128 KiB
  # (MAX_ARG_STRLEN) failed with E2BIG, the list came out empty and the sweep detached nothing. `print` is a mksh
  # builtin, so nothing is exec'd and no length limit applies; qn writes every line with it already. It is not a
  # here-document as in roamd's stop_mediad: on Endospore this block runs in endospore_mediad, where no here-document
  # has run yet, so it keeps to what it already uses there. The re-read below follows the same rule.
  # A table with no media line is not an error here: grep exits 1 and the list stays empty.
  # NWP-20261119-05: layers first, then the binds that are not layer lines (a line matching both is listed once).
  print -r -- "$_mt" | grep -e " fuse.nowheremedia " > "$SWEPT"
  print -r -- "$_mt" | grep -v -e " fuse.nowheremedia " | grep -e "/.nowhere-media[^/]*/.under/" >> "$SWEPT"
  n_ok=0; n_gone=0; n_fail=0; n_unk=0; n_pend=0; _qbad=0
  # `< "$SWEPT"` and NOT a pipe: a piped while runs in a subshell and the counters would die with it.
  while read -r _dev mnt _rest; do
    m=$(unesc_mount "$mnt")
    if _ue=$(umount -l "$m" 2>&1); then
      n_ok=$((n_ok + 1))
    else
      # ~~Re-read the table the same way (status kept; failed or empty = unreadable).~~ Superseded by
      # NWP-20261119-05 (h49 #3): a failure reads nothing here; it is queued, and the one re-read after the loop
      # classifies the queue. An unreadable re-read still proves nothing either way: count it as unverified rather
      # than as "already gone".
      # NWP-20261125-13: an entry the queue could not take is unverified, and so is the rest of the queue.
      if print -r -- " $mnt " >> "$PEND" && print -r -- " $mnt $(umount_err "$_ue")" >> "$PENDWHY"; then
        n_pend=$((n_pend + 1))
      else
        n_unk=$((n_unk + 1)); _qbad=1
      fi
    fi
  done < "$SWEPT"
  if [ "$_qbad" -ne 0 ]; then
    # NWP-20261125-13: a queue write failed, so the queue is short: every queued entry is unverified.
    n_unk=$((n_unk + n_pend))
  elif [ -s "$PEND" ]; then
    # ONE re-read for every failed entry (NWP-20261119-05), the same way as the top read (status kept; failed or
    # empty = unreadable, every pending entry unverified).
    _rr=$(cat /proc/mounts 2>>"$LOG"); _rrrc=$?
    if [ "$_rrrc" -ne 0 ] || [ -z "$_rr" ]; then
      n_unk=$((n_unk + n_pend))
    else
      print -r -- "$_rr" | sed -n 's/^[^ ]* \(\/[^ ]*\) .*/ \1 /p' > "$MNTSET"
      _grc=2; _src=2; _gone=
      if [ -s "$MNTSET" ]; then
        _gone=$(grep -cvxF -f "$MNTSET" "$PEND"); _grc=$?     # pending entries the kernel no longer lists
        grep -F -f "$MNTSET" "$PENDWHY" > "$STILL"; _src=$?   # pending entries it still lists, with their word
      fi
      # grep exits 1 for "no line", 2 for an error; a count that is not a number is an error too. An error, or no
      # field 2 at all, proves nothing: every pending entry is unverified, never "already gone". A $STILL that could
      # not be truncated cannot record which entries are still mounted (NWP-20261125-13): unverified too.
      case "$_gone" in ''|*[!0-9]*) _grc=2 ;; esac
      if [ "$_grc" -gt 1 ] || [ "$_src" -gt 1 ] || [ "$_strc" -ne 0 ]; then
        n_unk=$((n_unk + n_pend))
      else
        n_gone=$((n_gone + _gone))   # already detached via one of its other paths -- expected, not a fault
        # STILL MOUNTED after a failed umount: a real one. Name it -- silence here is what made
        # NWP-20260828-06 undiagnosable, where the sweep left the identical count twice and said nothing.
        # The loop walks $STILL, grep's own result, once: its work grows with the still-mounted count only.
        while read -r k w; do
          m=$(unesc_mount "$k")
          n_fail=$((n_fail + 1))
          print -r -- "[mediad] SWEEP-FAILED (still mounted): $(qn "$m") ($w)" >> "$LOG"
        done < "$STILL"
      fi
    fi
  fi
  rm -f "$SWEPT"
  rm -f "$PEND" "$PENDWHY" "$MNTSET" "$STILL"
  rm -f "$SWEEP"
  _t1=$(date +%s); _dt=0
  case "$_t0$_t1" in ''|*[!0-9]*) ;; *) [ -n "$_t0" ] && [ -n "$_t1" ] && _dt=$((_t1 - _t0)) ;; esac
  # One summary line instead of a line per mount: the counts are the diagnostic, and a non-zero n_fail is
  # the only part that should ever draw the eye. NWP-20261119-05: ` in <n>s` is the sweep's own time.
  echo "[mediad] sweep done: $n_ok detached, $n_gone already gone, $n_fail FAILED, $n_unk unverified in ${_dt}s $(date)" >> "$LOG"
  exit 0
fi

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
export S3_ENDPOINT S3_REGION S3_BUCKET S3_ACCESS_KEY S3_SECRET_KEY
export GATEWAY_URL NOWHERE_STATE="$STATE"
# #91 slice 3 / NWP-20260822-24 (-08e): per-unit head model -- the SAME export the daemon and roamd carry,
# and mediad MUST match them: all three source this conf, and with NOWHERE_MULTIDEVICE=1 set there the
# other two resolve/seal at unitHeadRef while an un-exported mediad falls through to the frozen v2 head
# (putHead deliberately stops updating it). A pre-flag profile then serves a STALE CE manifest as current,
# and a post-flag profile reads "empty/absent -> nothing to serve" -- byte-identical to genuinely having
# no deferred media. Latent until the #91 rollout flips the flag; found by the NWP-20260822-08 audit.
export NOWHERE_MULTIDEVICE="${NOWHERE_MULTIDEVICE:-0}"
export SSL_CERT_DIR=/system/etc/security/cacerts
export NOWHERE_DNS="${NOWHERE_DNS:-}"
# #84 P5: media fetch-cache eviction. Default is FREE-SPACE based -- keep 2 GiB free on /data (evict only under
# real storage pressure), so on a spacious phone nothing is evicted and hot maps stay fast. Tune in nowhere.conf:
# NOWHERE_MEDIA_CACHE_MIN_FREE (bytes free to keep; 0 disables), NOWHERE_MEDIA_CACHE_MAX (optional hard byte cap;
# default none). Export both so os.Getenv sees them.
export NOWHERE_MEDIA_CACHE_MAX="${NOWHERE_MEDIA_CACHE_MAX:-}"
export NOWHERE_MEDIA_CACHE_MIN_FREE="${NOWHERE_MEDIA_CACHE_MIN_FREE:-}"
# NOWHERE_MEDIA_DEBUG=1 re-enables the high-frequency per-open/fetch/prefetch trace (quiet by default; the
# error + lifecycle logs always print). Set it in nowhere.conf to diagnose a serve/search issue without a rebuild.
export NOWHERE_MEDIA_DEBUG="${NOWHERE_MEDIA_DEBUG:-}"

[ -f "$REQ" ] || { echo "[mediad] no req $(date)" >> "$LOG"; exit 0; }
# NWP-20261123-21: ALL FOUR LINES FROM ONE OPEN, as roamd reads roam.req (NWP-20260917-13). kickMediad publishes
# the req by temp + rename, so one open sees one whole request; four `sed -n Np` opens could straddle a second
# kick's rename and pair one request's name with the next one's pass. A short req leaves the rest EMPTY, as sed
# did, and a last line with no newline still lands (read fails but sets it): never chain the reads with &&.
name=""; pass=""; uid=""; sesec=""
{ IFS= read -r name; IFS= read -r pass; IFS= read -r uid; IFS= read -r sesec; } < "$REQ"   # line 4, NWP-20261007-16: the session's chip secret, empty when there is none
rm -f "$REQ"                          # consume creds immediately on read -- NOT a sub-second window, below
# NWP-20260917-23: this delete runs only when mediad STARTS. Since NWP-20260829-27, kickMediad (main.go) rewrites
# this file on every sync tick and then fires a ctl.start that init IGNORES while mediad is already running, so
# between starts the req -- the profile passphrase on line 2 -- sits here for the life of the session, until
# the next start, stopMediad or roamd's teardown removes it. Accepted, not a new exposure: $STATE is the
# root-only 0700 RAM tmpfs, the file is 0600, it never survives power-off, and roam.req carries the same
# secret on the same tmpfs. Skipping the write while mediad runs needs a service-state check, and init reports
# that state unreliably while a service is dying (#83).

# DIA-20260812-02 (#106): stage the passphrase in a file instead of argv. See the long note on `pw` in
# nowhere_roamd.sh for the mechanism and for why `print -r --` (not printf, not echo) is the only correct
# writer here. THIS script is the worst of the argv leaks and the reason the fix is not cosmetic: roamd's
# agent calls are seals and restores that end, but the exec below is a DAEMON that lives for the whole
# session, so `ps` showed the profile passphrase continuously from login to logoff.
# No sweep here, deliberately. roamd sweeps its own .pw.roamd.* prefix; this script has nothing to sweep,
# because it EXECs the agent -- so the process that unlinks our file IS this script's own process, and there
# is no predecessor of ours to clean up after. An unscoped `rm -f "$STATE"/.pw.*` here would be pure risk:
# the only files it could ever delete are roamd's live ones (roamd and mediad share no lock), turning a
# periodic seal into "NOT SEALED".
pw() {
  local f
  f=$(mktemp "$STATE/.pw.mediad.XXXXXX" 2>/dev/null)
  if [ -n "$f" ] && print -r -- "$1" > "$f" 2>/dev/null; then
    print -r -- "@file:$f"
    return 0
  fi
  [ -n "$f" ] && rm -f "$f"
  echo "[mediad] WARN cannot stage a secret under $STATE -- passing it as a value, where ps or /proc can read it, for the life of this daemon. $(date)" >> "$LOG"
  # print -r --, NOT echo: see the note in nowhere_roamd.sh. echo mangles backslashes and eats a leading -n,
  # so the degraded path would hand the agent a different secret and mediad would serve nothing.
  print -r -- "$1"
}

[ -n "$name" ] && [ -n "$uid" ] || { echo "[mediad] ERR-ARGS $(date)" >> "$LOG"; exit 0; }
case "$uid" in *[!0-9]*) echo "[mediad] non-numeric uid rejected $(date)" >> "$LOG"; exit 0;; esac
# NWP-20261117-30: a session uid is 10 or more, as roamd's shared guard (NWP-20261116-13) and cleanstorage's HARD
# GUARD: never user 0's storage. uid 0 would mount a profile's media over the gate's own app dirs and cache it in the
# gate's CE, which no reap clears; a leading zero names no user, so the cache would land outside every FBE policy.
# The numeric check above stays first: mksh reads a non-number in [ -ge ] as 0, silently.
case "$uid" in 0?*) echo "[mediad] uid $uid refused (leading zero) $(date)" >> "$LOG"; exit 0;; esac
[ "$uid" -ge 10 ] || { echo "[mediad] uid $uid refused (under 10: user 0 and the system are never a session) $(date)" >> "$LOG"; exit 0; }
USERDIR="/data/user/$uid"
MEDIADIR="/data/media/$uid"   # #129: the EXTERNAL-media scope (offline maps live here, sealed to name#media)

# Stale sweep: a SIGKILL'd (or crashed) previous instance leaves its FUSE overlays + binds behind; a read
# through a dead-daemon mount hangs forever. Detach ONLY our own mounts for this user -- the overlay's
# /proc/mounts fstype is "fuse.nowheremedia" (go-fuse mounts "fuse."+Name; the device field is the FsName
# nowhere_media) -- NEVER touch /sys/fs/fuse/connections (aborting it kills Android's own emulated-storage
# FUSE for the live user; cost a session in the Phase-0 spike).
# NWP-20261122-18: read the table ONCE and keep the status, as the sweep-only block reads it. A read that failed, or
# that printed nothing, is UNREADABLE, never "nothing stale": no Linux system has an empty mounts table (roamd's
# stop_mediad: an unread table must never count as zero). Both loops used to read /proc/mounts with the error
# discarded, so a domain that lost the read ran zero iterations, logged nothing, and mounted the new overlays over a
# dead daemon's ones. Now it logs STALE-SWEEP-UNREADABLE and checks nothing. mediad still starts: whether a start
# should refuse over an unread table is not decided. The table reaches grep through `print -r --`, never as a printf
# argument (the NWP-20261115-05 note in the sweep-only block: E2BIG over 128 KiB on mksh).
_smt=$(cat /proc/mounts 2>>"$LOG"); _smtrc=$?
if [ "$_smtrc" -ne 0 ] || [ -z "$_smt" ]; then
  echo "[mediad] STALE-SWEEP-UNREADABLE: the mount table could not be read -- no stale overlay or bind was checked $(date)" >> "$LOG"
else
  print -r -- "$_smt" | grep -e " fuse.nowheremedia " | while read -r _dev mnt _rest; do
    m=$(unesc_mount "$mnt")   # match AND umount on the decoded path, never the escaped one
    case "$m" in "$USERDIR"/*|"$MEDIADIR"/*)
      if _ue=$(umount -l "$m" 2>&1); then print -r -- "[mediad] stale overlay detached: $(qn "$m")" >> "$LOG"
      else print -r -- "[mediad] STALE-OVERLAY-DETACH-FAILED: $(qn "$m") ($(umount_err "$_ue"))" >> "$LOG"; fi;;
    esac
  done
  # Detach any leftover .under BIND -- including one Android's app-data reconcile renamed to "<uuid>==deleted=="
  # while trying to reap an old cache (#92). Matching the substring "/.nowhere-media/.under/" catches both the
  # live path and a "==deleted==/.nowhere-media/.under/" one, so no dead bind is left for a later rm -rf to walk.
  print -r -- "$_smt" | grep -e " .*/.nowhere-media[^/]*/.under/" | while read -r _dev mnt _rest; do
    m=$(unesc_mount "$mnt")   # match AND umount on the decoded path, never the escaped one
    case "$m" in *"/$uid/"*|*"/$uid==deleted=="*)
      if _ue=$(umount -l "$m" 2>&1); then print -r -- "[mediad] stale bind detached: $(qn "$m")" >> "$LOG"
      else print -r -- "[mediad] STALE-BIND-DETACH-FAILED: $(qn "$m") ($(umount_err "$_ue"))" >> "$LOG"; fi;;
    esac
  done
fi
unset _smt _smtrc

# The media cache lives INSIDE the roamed user's CE storage so cached plaintext media is FBE-encrypted at
# rest, gone when the ephemeral user is reaped at logoff, unreadable after power-off. It sits INSIDE the
# chooser's package dir -- NOT at the user root -- because Android's app-data reconcile reaps any orphan
# top-level dir under /data/user/N and would rm -rf THROUGH our .under binds into the real app data (#92).
# MUST match mediaCacheRel in media_server.go (the seal derives the .under path from it).
CACHE="$USERDIR/com.nowhere.chooser/files/.nowhere-media"
mkdir -p "$CACHE"
chmod 700 "$CACHE"
# #159 (DIA-20260721): the `mkdir -p "$CACHE"` above creates the chooser's OWN files/ dir as ROOT when the
# app has not run yet (a fresh roamed profile, before the gate/Profile app calls getFilesDir) -- which then
# EACCES's the app's own writes into files/ (nowhere-prefs / nowhere-apps.list / nowhere-perms: in-session
# Profile settings, e.g. the always-on-VPN picker, silently fail to persist). Hand files/ back to the app
# (match its package-dir owner + SELinux label); the root-owned .nowhere-media* cache subdirs stay as-is.
_cdir="$USERDIR/com.nowhere.chooser"
if [ -d "$_cdir/files" ]; then
  chown "$(stat -c %u:%g "$_cdir")" "$_cdir/files" 2>> "$LOG"
  chcon "$(stat -c %C "$_cdir")" "$_cdir/files" 2>> "$LOG"
fi
# #129: the external-media (name#media) scope's fetch cache + .under binds. Kept INSIDE the roamed user's CE
# storage (like $CACHE) so cached plaintext + the bind mountpoints are FBE-encrypted and reaped at logoff --
# the bind targets are the real /data/media/$uid dirs, so prefetched maps still land in external storage.
MEDIACACHE="$USERDIR/com.nowhere.chooser/files/.nowhere-media-ext"

# #81/#84 (nfctest 2026-07-05): a FIDO2 (2FA) profile's vault opens with the passphrase + the security-key
# hmac, NOT the pass alone. roamd stashes the login-cached hmac at $STATE/.fido2hmac (same file the seal
# reads); hand it to mediad's agent so it can OPEN the vault to read the deferred-media manifest. WITHOUT this,
# resolveKey fails "empty/absent" for every 2FA profile and mediad serves NOTHING -- the deferred maps look
# lost even though they're safe in the store. Harmless for a non-2FA profile: roamd rm's the stash at login,
# so the `[ -f ]` guard skips the export and the passphrase keyslot opens the vault as before.
# NWP-20261112-29: staged as a file through pw, like the chip secret below, never as a value in this long-lived
# daemon's environment: the agent resolves it at startup (adoptStagedSESecret), so only the path stays in environ.
[ -f "$STATE/.fido2hmac" ] && export NOWHERE_FIDO2_HMAC="$(pw "$(cat "$STATE/.fido2hmac")")"

# NWP-20261007-16: a TIED profile's vault, #de and #sys open only through this phone's chip. Without the secret the
# agent's own check (scopeOwnerLocked) reads the profile as tied to another phone and exits, so a tied session got
# no on-demand media at all, and a restart left the previous daemon's mounts dead under the seal walk. Staged as a
# file like the passphrase (pw), never as a value in this long-lived daemon's environment: the agent resolves the
# @file: marker at startup (adoptStagedSESecret) and only the path stays in /proc/<pid>/environ. Chester,
# 2026-10-07: mediad may hold the chip secret for the session, the same lifetime as the passphrase it holds.
[ -n "$sesec" ] && export NOWHERE_SE_SECRET="$(pw "$sesec")"
unset sesec

print -r -- "[mediad] start $(qn "$name") -> user $uid $(date)" >> "$LOG"
# EXEC, do NOT background (see the header): the agent becomes this service's main process so init keeps it
# alive; it mounts in init's GLOBAL mount namespace, which is why an init-launched overlay propagates into the
# app's namespace (proven on-device) whereas a manually-launched one does not.
# #129: pass the external-media scope (/data/media/$uid) too when it exists, so ONE mediad serves BOTH the CE
# and the name#media deferred sets -- the offline maps sealed to name#media are otherwise captured-but-unserved.
if [ -d "$MEDIADIR" ]; then
  mkdir -p "$MEDIACACHE"; chmod 700 "$MEDIACACHE"
  exec "$AGENT" mediad s3 "$name" "$(pw "$pass")" "$USERDIR" "$CACHE" "$MEDIADIR" "$MEDIACACHE" >> "$LOG" 2>&1
fi
exec "$AGENT" mediad s3 "$name" "$(pw "$pass")" "$USERDIR" "$CACHE" >> "$LOG" 2>&1
