#!/usr/bin/env bash
# test-uiderrors-op.sh [<nowhere_roamd.sh>] [--mutate] -- roamd's half of the issue report's uiderrors section
# (NWP-20261010-06), run for real rather than grepped.
#
# Two pieces of the script carry a privacy or a correctness property that the Go tests cannot reach:
#   - uiderrors_floor_commit records this session's offset in /data/system/uiderrors.txt. The report shows only
#     lines past it, so a commit that left an OLDER session's floor in place would hand this session the previous
#     renter's lines. An empty or non-numeric take must REMOVE the floor, never keep one.
#   - the `uiderrors)` op must pass that floor and this session's uid to the agent, and must publish its reply by
#     RENAME: the daemon's poller returns at the first non-empty byte of $RES (the lesson of the
#     retired keystorens op, NWP-20260827-02), so a reply written in place is read half-written.
#   - the op's log line must carry the reply it published, read from $RES.part BEFORE the rename
#     (NWP-20261111-27): the poller removes $RES the moment it has read it, so a read of $RES after the mv logs a
#     blank exactly when the daemon was fast, and roam.log is the only persisted trace of what the report got.
#   - WHERE `in` takes and commits the floor: the take first thing in the op, the commit only on its OK path,
#     immediately before the OK reply. A commit on a failure branch would let a refused or straggler login move
#     the live session's floor; a take after the restore would push this session's own early lines below it.
#
# Blocks are extracted from nowhere_roamd.sh BY ANCHOR, never copied; if the anchors move, extraction fails
# loudly rather than a stale copy passing forever.
#
# The op and the floor commit run as scripts under EVERY shell present (bash, sh, dash, mksh -- mksh is the
# device's /system/bin/sh), and each mutant must be convicted by a run restricted to each shell on its own.
#
#   bash test-uiderrors-op.sh               # the behaviour cases, under every shell found
#   bash test-uiderrors-op.sh --mutate      # ... plus mutations that must each CONVICT the suite under each shell
#   bash test-uiderrors-op.sh --shell mksh  # the behaviour cases under that one shell only
#   bash test-uiderrors-op.sh --no-pins     # skip the shell-independent source pins on `in` (the mutant runner's
#                                           # per-shell runs use it, so only that shell's cases can convict)
set -uo pipefail

MUTATE=no; SUT=""; ONLY=""; PINS=yes; _next=""
for a in "$@"; do
  if [ "$_next" = shell ]; then ONLY="$a"; _next=""; continue; fi
  case "$a" in --mutate) MUTATE=yes ;; --shell) _next=shell ;; --no-pins) PINS=no ;; *) SUT="$a" ;; esac
done
[ -z "$_next" ] || { echo "--shell needs a shell name" >&2; exit 2; }
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
SHELLS=""
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
if [ -n "$ONLY" ]; then
  command -v "$ONLY" >/dev/null 2>&1 || { echo "no such shell: $ONLY" >&2; exit 2; }
  SHELLS=" $ONLY"
fi

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT   # every temp below lives inside $W
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

# --- extraction -----------------------------------------------------------------------------------------
COMMIT_FN=$(sed -n '/^uiderrors_floor_commit() {$/,/^}$/p' "$SUT")
OP=$(sed -n '/^  uiderrors)$/,/^    ;;$/p' "$SUT" | sed '1d;$d')
case "$COMMIT_FN" in *uiderrors.floor*) ;; *) echo "EXTRACTION FAILED: uiderrors_floor_commit" >&2; exit 2 ;; esac
case "$OP" in *uiderrorstail*) ;; *) echo "EXTRACTION FAILED: the uiderrors) op" >&2; exit 2 ;; esac

# --- harness --------------------------------------------------------------------------------------------
# Modes are asserted only where the filesystem keeps them: on a Windows checkout (Git Bash on NTFS) chmod is a
# no-op, and a mode check there would fail for the host, not the script. Probed, never assumed.
P=$(mktemp -d -p "$W"); : > "$P/f"; chmod 600 "$P/f" 2>/dev/null
MODES=no; [ "$(stat -c %a "$P/f" 2>/dev/null)" = 600 ] && MODES=yes; rm -rf "$P"
mode600(){ [ "$MODES" = no ] || [ "$(stat -c %a "$1" 2>/dev/null)" = 600 ]; }
# A fake agent: records its argv, and notes whether $RES already existed while it was still writing -- which is
# exactly the half-written window the rename exists to close.
mkagent(){   # mkagent <dir> <ok|fail>
  cat > "$1/agent" <<EOF
#!/usr/bin/env bash
printf '%s|%s|%s|%s\n' "\$#" "\$1" "\$2" "\$3" > "$1/args"
[ "$2" = fail ] && exit 1
echo "OK 3 0 0 10"
[ -e "$1/roamro.res" ] && : > "$1/partial"
echo "10/10/26, 5:04 PM: Destroying /data/user_de/10/com.x due to: y"
EOF
  chmod +x "$1/agent"
}
# RACE=yes makes every mv remove its destination the moment it lands: the daemon's poller winning the race,
# reading $RES and removing it before the op's next line runs. Written in POSIX sh (no `local`, no ${*: -1}):
# it runs inside the op's script, under each shell.
RACE=no
runop(){     # runop <shell> <dir> <ok|fail> [floor] -> runs the op with uid 10 under <shell>
  local sh="$1" T="$2"; mkagent "$T" "$3"
  [ $# -ge 4 ] && echo "$4" > "$T/uiderrors.floor"
  { printf 'STATE=%s\nLOG=%s\nRES=%s\nAGENT=%s\nuid=10\n' "$T" "$T/log" "$T/roamro.res" "$T/agent"
    if [ "$RACE" = yes ]; then
      printf '%s\n' 'mv(){ for _a in "$@"; do _dst=$_a; done; command mv "$@" || return' \
        "  cp -f \"\$_dst\" '$T/polled' 2>/dev/null; rm -f \"\$_dst\"; }"
    fi
    printf '%s\n' "$OP"; } > "$T/op.sh"
  "$sh" "$T/op.sh" >/dev/null 2>&1
}

behaviour(){   # behaviour <shell>: every case that runs roamd code, under that shell
  local sh="$1" T LOGTXT
  echo "== [$sh] the op passes this session's floor and uid, and publishes by rename =="
  T=$(mktemp -d -p "$W"); runop "$sh" "$T" ok 123
  [ "$(cat "$T/args" 2>/dev/null)" = "3|uiderrorstail|123|10" ] && ok "[$sh] agent gets the floor and the uid" \
    || no "[$sh] agent argv was '$(cat "$T/args" 2>/dev/null)', want 3|uiderrorstail|123|10"
  [ "$(head -n 1 "$T/roamro.res" 2>/dev/null)" = "OK 3 0 0 10" ] && [ "$(wc -l < "$T/roamro.res")" -eq 2 ] \
    && ok "[$sh] the whole reply lands in RES" || no "[$sh] RES holds '$(cat "$T/roamro.res" 2>/dev/null)'"
  [ ! -e "$T/partial" ] && ok "[$sh] RES did not exist while the agent was writing (rename, not in place)" \
    || no "[$sh] RES existed mid-write: the poller would read a half reply"
  [ ! -e "$T/roamro.res.part" ] && ok "[$sh] no .part left behind" || no "[$sh] .part left behind"
  mode600 "$T/roamro.res" && ok "[$sh] RES is 600 (modes checked: $MODES)" || no "[$sh] RES mode is $(stat -c %a "$T/roamro.res" 2>/dev/null)"
  rm -rf "$T"

  T=$(mktemp -d -p "$W"); runop "$sh" "$T" ok
  [ "$(cat "$T/args" 2>/dev/null)" = "3|uiderrorstail||10" ] \
    && ok "[$sh] no floor file: the agent gets an EMPTY floor (and answers ERR-NOFLOOR)" || no "[$sh] no-floor argv was '$(cat "$T/args")'"
  rm -rf "$T"

  T=$(mktemp -d -p "$W"); runop "$sh" "$T" fail 5
  [ "$(cat "$T/roamro.res" 2>/dev/null)" = "ERR-READ the agent exited non-zero" ] && ok "[$sh] a failing agent still answers, as an error" \
    || no "[$sh] failing agent left RES '$(cat "$T/roamro.res" 2>/dev/null)'"
  LOGTXT=$(cat "$T/log" 2>/dev/null)
  case "$LOGTXT" in *"[roamd] uiderrors -> ERR-READ the agent exited non-zero "*) ok "[$sh] the log line carries the failing agent's ERR-READ" ;;
    *) no "[$sh] failing agent: log reads '$LOGTXT'" ;; esac
  rm -rf "$T"

  echo "== [$sh] the log line carries the reply even when the poller removes \$RES at once (NWP-20261111-27) =="
  T=$(mktemp -d -p "$W"); RACE=yes; runop "$sh" "$T" ok 7; RACE=no
  [ "$(head -n 1 "$T/polled" 2>/dev/null)" = "OK 3 0 0 10" ] && [ ! -e "$T/roamro.res" ] \
    && ok "[$sh] the poller got the reply and removed RES (the race happened)" || no "[$sh] race harness did not fire"
  LOGTXT=$(cat "$T/log" 2>/dev/null)
  case "$LOGTXT" in *"[roamd] uiderrors -> OK 3 0 0 10 "*) ok "[$sh] log reads 'uiderrors -> OK 3 0 0 10' though RES is gone" ;;
    *) no "[$sh] race: log reads '$LOGTXT', want 'uiderrors -> OK 3 0 0 10 <date>'" ;; esac
  [ ! -e "$T/roamro.res" ] && ok "[$sh] after the mv the op did not re-create RES" || no "[$sh] RES re-created after the poller removed it"
  rm -rf "$T"

  echo "== [$sh] the floor commit never keeps an older session's floor =="
  T=$(mktemp -d -p "$W")
  commit(){   # commit <take>: runs uiderrors_floor_commit under $sh
    { printf 'STATE=%s\nLOG=%s\n' "$T" "$T/log"; printf '%s\n' "$COMMIT_FN" 'uiderrors_floor_commit "$1"'; } > "$T/commit.sh"
    "$sh" "$T/commit.sh" "$1" >/dev/null 2>&1
  }
  commit 456
  [ "$(cat "$T/uiderrors.floor" 2>/dev/null)" = 456 ] && mode600 "$T/uiderrors.floor" \
    && ok "[$sh] a numeric take is recorded, 600" || no "[$sh] floor holds '$(cat "$T/uiderrors.floor" 2>/dev/null)'"
  commit ""
  [ ! -e "$T/uiderrors.floor" ] && ok "[$sh] an empty take REMOVES the previous floor" || no "[$sh] an empty take kept the older floor"
  commit 456; commit "12x"
  [ ! -e "$T/uiderrors.floor" ] && ok "[$sh] a non-numeric take REMOVES the previous floor" || no "[$sh] a non-numeric take kept the older floor"
  commit 111; mkdir "$T/uiderrors.floor.part"; commit 456   # the write fails: .part is a directory
  [ ! -e "$T/uiderrors.floor" ] && ok "[$sh] a FAILED write removes the previous floor rather than leaving it standing" \
    || no "[$sh] a failed write left floor '$(cat "$T/uiderrors.floor" 2>/dev/null)' standing"
  rm -rf "$T"
}
for sh in $SHELLS; do behaviour "$sh"; done

# Source pins: shell-independent, so they run once, not per shell.
if [ "$PINS" = yes ]; then
  echo "== \`in\` takes the floor first and commits it only with its OK reply =="
  INBLK=$(awk '/^  in\)$/{f=1} f{print NR": "$0} f&&/^  [a-z][a-z0-9_-]*\)$/&&!/^  in\)$/{exit}' "$SUT")
  IN_AT=$(grep -n '^  in)$' "$SUT" | cut -d: -f1)
  TAKE_AT=$(grep -n '^    _uefloor=$(uiderrors_floor_take)' "$SUT" | cut -d: -f1)
  COMMITS=$(grep -c 'uiderrors_floor_commit "\$_uefloor"' "$SUT")
  COMMIT_AT=$(grep -n 'uiderrors_floor_commit "\$_uefloor"' "$SUT" | cut -d: -f1)
  OK_AT=$(grep -n '^      echo "OK \$uid" > "\$RES"; _inres=OK$' "$SUT" | cut -d: -f1)
  [ -n "$INBLK" ] && [ -n "$IN_AT" ] || { echo "EXTRACTION FAILED: the in) op" >&2; exit 2; }
  [ -n "$TAKE_AT" ] && [ "$TAKE_AT" -gt "$IN_AT" ] && [ "$TAKE_AT" -le $((IN_AT + 6)) ] \
    && ok "the take is the op's first work (line $TAKE_AT, op at $IN_AT)" || no "the take is not at the start of in) (take=$TAKE_AT, in=$IN_AT)"
  [ "$COMMITS" = 1 ] && [ -n "$OK_AT" ] && [ "$COMMIT_AT" = $((OK_AT - 1)) ] \
    && ok "one commit, immediately before the only OK reply (line $COMMIT_AT)" \
    || no "commit not pinned to the OK path (commits=$COMMITS at $COMMIT_AT, OK at $OK_AT)"
fi

# --- mutations ------------------------------------------------------------------------------------------
if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each MUST be convicted) =="
  M=$(mktemp -d -p "$W")
  # mutate <run|pin> <name> <sed>: a `run` mutant breaks code the cases execute, so it must be convicted by a run
  # restricted to EACH shell on its own with the source pins off; a `pin` mutant moves a line the source pins
  # check, so it is convicted once, shell-independently.
  mutate(){
    local kind="$1" name="$2" sh
    if ! sed "$3" "$SUT" > "$M/m.sh" 2>"$M/err"; then no "MUTATION BROKEN (sed): $name"; return; fi
    if cmp -s "$SUT" "$M/m.sh"; then no "MUTATION INERT: $name"; return; fi
    bash -n "$M/m.sh" 2>/dev/null || { no "MUTATION BROKEN (does not parse): $name"; return; }
    if [ "$kind" = pin ]; then
      if bash "$0" --shell bash "$M/m.sh" >/dev/null 2>&1; then no "NOT CONVICTED: $name -- suite passes on broken code"
      else ok "convicted (source pin): $name"; fi
      return
    fi
    for sh in $SHELLS; do
      if bash "$0" --no-pins --shell "$sh" "$M/m.sh" >/dev/null 2>&1; then no "NOT CONVICTED under $sh: $name"
      else ok "convicted under $sh: $name"; fi
    done
  }
  mutate run "reply written in place" 's@"\$uid" > "\$RES.part"@"$uid" > "$RES"@'
  mutate run "floor not passed to the agent" 's@uiderrorstail "\$(cat "\$STATE/uiderrors.floor" 2>/dev/null)" "\$uid"@uiderrorstail "" "$uid"@'
  mutate run "uid not passed to the agent" 's@2>/dev/null)" "\$uid" > @2>/dev/null)" "" > @'
  mutate run "an empty take keeps the older floor" '0,/rm -f "\$_f" "\$_f.part" 2>>"\$LOG"/s@rm -f "\$_f" "\$_f.part" 2>>"\$LOG"@:@'
  mutate run "a failed write keeps the older floor" '/^  if ! { echo "\$1"/,/^  fi$/s@^    rm -f "\$_f" "\$_f.part" 2>>"\$LOG"$@    :@'
  mutate pin "commit moved onto a failure branch" '/^      uiderrors_floor_commit "\$_uefloor"/d; s@^\(        echo "BLANK NET" > "\$RES"\)$@        uiderrors_floor_commit "$_uefloor"\n\1@'
  mutate run "the log line reads \$RES again, after the mv" '/^    _ueh=\$(head -n 1 "\$RES\.part"/{N;s@^\(    _ueh=\$(head -n 1 "\$RES\)\.part\(".*\)\n\(    mv -f .*\)$@\3\n\1\2@}'
  mutate pin "take moved after the restore" '/^    _uefloor=\$(uiderrors_floor_take)/d; s@^\(      uiderrors_floor_commit "\$_uefloor"\)@      _uefloor=$(uiderrors_floor_take)\n\1@'
  rm -rf "$M"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
