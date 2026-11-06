#!/usr/bin/env bash
# test-userdir-orphan.sh [<nowhere_roamd.sh>] [--mutate] [--baseline] -- roamd's backstops for a removed user's
# /data/system/users/<n> (NWP-20261003-01): the reap (cleanstorage), the boot sweep, seedssaid, and the roam-in
# that did not land.
#
# WHY THIS IS COMMITTED. users/<n> is the one per-user directory under the SYSTEM's DE key, so it is cleartext,
# and it is outside every user, so the boot-wipe never reaches it. A framework writer re-creates it after the
# reap (AtomicFile mkdirs a missing parent): on lynx 2026-10-02 user 11's settings_secure.xml and
# settings_ssaid.xml -- the profile's SSAID userkey -- came back after roamd had removed the directory, and, from
# GrapheneOS source (not yet seen on a device), the next user given that id after a reboot loads them inside
# createAndManageUser. Each backstop here decides by the ABSENCE of a file, which is the shape that fails
# silently: a record test that misses .backup deletes a live user's directory mid-rewrite, a census that echoes
# `ls` puts a package name in a log that outlives every wipe, and a sweep that cannot see users/ reports "0"
# exactly like one that found nothing. So this suite plants real trees, drives the REAL extracted code over a
# scripted clock, and asserts WHICH FILES SURVIVED.
#
#   bash test-userdir-orphan.sh              # the behaviour cases + static pins
#   bash test-userdir-orphan.sh --mutate     # ... plus mutations that must each CONVICT, and probes that must not
#   MUTJOBS=8 bash test-userdir-orphan.sh --mutate   # the same, 8 mutants at a time; results print in order
#   bash test-userdir-orphan.sh --baseline <old roamd>
#        # run the same cases against the code BEFORE this change: every [new] assertion must FAIL there and
#        # every [guard] must still hold, or the case proves nothing about the change
#
# Pure logic -- no device. Functions and op blocks are EXTRACTED from nowhere_roamd.sh by anchor, never copied,
# and re-rooted to a temp tree; sleep is a scripted clock, and rm, ls, stat, chown, chmod, restorecon and the
# agent (which, in the consume cases, takes roamd's reply the instant it is written) are stubbed only to do what
# a scenario says they do.
set -uo pipefail

MUTATE=no; BASE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; --baseline) BASE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

# One root for everything this suite makes; the EXIT trap is the only top-level one (sim_stubs' trap runs in
# subshells only), and it leaves nothing behind on a pass, a failed check or --mutate.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

KEY64=0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF
# The shells the R5 re-check cases run under, each one found; the R5 mutants are judged against the same list.
R5SHELLS="bash dash mksh sh"

# --- extraction ---------------------------------------------------------------------------------------------
fn_of() { awk -v n="$2" '$0 == n "() {" {f=1} f{print} f&&/^\}$/{exit}' "$1"; }
op_of() { sed -n "/^if \\[ \"\\\$op\" = \"$2\" \\]; then\$/,/^fi\$/p" "$1"; }
arm_of() { awk -v a="  $2)" '$0 == a {f=1} f{print} f&&/^    ;;$/{exit}' "$1"; }
# The log_scrub sed program, from the one line that defines it (as test-log-name-scrub.sh takes it; NWP-20261008-09
# moved it out of the pipeline into LOG_SCRUB_SED).
scrub_expr() {
  local e
  e=$(grep -m1 "^LOG_SCRUB_SED='" "$1")
  [ -n "$e" ] || return 1
  e=${e#LOG_SCRUB_SED=\'}
  e=${e%\'}
  [ -n "$e" ] || return 1
  printf '%s\n' "$e"
}
# Re-root every /data path, quoted or a bare word, and ASSERT it was complete: one absolute path left behind
# points at a real /data that is not here, its [ -e ] is false, and the scenario passes having tested nothing.
# Comments are stripped first (a # that starts a word, so ${x#y} survives) -- many of them quote /data paths.
# Only an ABSOLUTE /data counts as left behind: "$MEDIADIR"/Android/data/ is a relative path and is fine.
reroot() { printf '%s\n' "$1" | sed -E 's#([" ])/data/#\1$ROOT/data/#g'; }
nleft() { printf '%s\n' "$1" | sed -E 's/(^|[[:space:]])#.*$//' | sed 's#\$ROOT/data/##g' | grep -cE '(^|[^[:alnum:]_])/data/'; }
nrew() { printf '%s\n' "$1" | grep -o '\$ROOT/data/' | grep -c .; }

# --- the simulated device -----------------------------------------------------------------------------------
# One scenario = one temp tree under $ROOT. Events are shell snippets in sim/ev.<tick>, run when the scripted
# clock reaches that tick: the framework deleting a record, a writer re-creating a directory. They use
# `command rm` so they are not refused by the stub. sim/kshook runs inside keystore_push, which is where the
# 2026-10-02 writer actually landed -- before the reap's first look at users/<uid>.
mkroot() {
  R=$(mktemp -d -p "$W")
  mkdir -p "$R/sim" "$R/state" "$R/data/nowhere" "$R/data/system/users/0"
  : > "$R/data/system/users/0.xml"
}
plant() { mkdir -p "$(dirname "$1")"; printf '%s' "${2:-x}" > "$1"; }
ev() { printf '%s\n' "$3" >> "$1/sim/ev.$2"; }
refuse() { printf '%s\n' "$2" >> "$1/sim/refuse"; }
# drain <root>: run every event the op did not live to see, in tick order. A writer does not stop writing because
# roamd stopped watching: a reap that ends early must be caught by what is ON DISK afterwards, not excused by
# an event that simply never fired.
drain() {
  local last t
  last=$(cat "$1/sim/ticks" 2>/dev/null || echo 0)
  for t in $(for f in "$1"/sim/ev.*; do [ -e "$f" ] && echo "${f##*.}"; done | sort -n); do
    [ "$t" -gt "$last" ] && ( ROOT="$1"; . "$1/sim/ev.$t" ) 2>>"$1/sim/stderr"
  done
  return 0
}
sim_stubs() {  # defines the stubs in the CALLING (sub)shell
  _TICK=0
  trap 'echo "$_TICK" > "$ROOT/sim/ticks"' EXIT
  sleep() { _TICK=$((_TICK + 1)); if [ -f "$ROOT/sim/ev.$_TICK" ]; then . "$ROOT/sim/ev.$_TICK"; fi; return 0; }
  # rm refuses any path listed in sim/refuse (and anything under it), and says so on stderr the way toybox
  # does -- naming each file it could not unlink -- so a caller that sends rm's stderr to the log is caught.
  rm() {
    local a r skip rc=0 f
    for a in "$@"; do
      case "$a" in -*) continue ;; esac
      skip=""
      if [ -f "$ROOT/sim/refuse" ]; then
        while IFS= read -r r; do [ -n "$r" ] || continue; case "$a" in "$r"|"$r"/*) skip=1 ;; esac; done < "$ROOT/sim/refuse"
      fi
      if [ -n "$skip" ]; then
        rc=1
        if [ -d "$a" ]; then for f in "$a"/*; do [ -e "$f" ] && echo "rm: $f: Permission denied" >&2; done
        else echo "rm: $a: Permission denied" >&2; fi
      else
        command rm -rf -- "$a" || rc=1
      fi
    done
    return $rc
  }
  # ls fails for a path listed in sim/lsfail; for a path listed in sim/lsrecord as "<path> <file>", it first
  # creates <file> -- a record landing while the sweep looks, which is the race the second look narrows.
  ls() {
    local a last="" p f
    for a in "$@"; do last="$a"; done
    if [ -f "$ROOT/sim/lsfail" ] && grep -qxF -- "$last" "$ROOT/sim/lsfail"; then return 2; fi
    if [ -f "$ROOT/sim/lsrecord" ]; then
      while read -r p f; do [ "$p" = "$last" ] && : > "$f"; done < "$ROOT/sim/lsrecord"
    fi
    command ls "$@"
  }
}

suite() {  # suite <roamd.sh> [quiet] -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" quiet="${2:-}" p=0 x=0 fn FUNCS="" PRE SD CLEAN BOOT SEED IN EXPR n cl ldg lg t
  say() { [ -n "$quiet" ] || printf '%s\n' "$1"; }
  # chk <new|guard> <label> <command...>. [new] is this slice's behaviour: it must hold here and must FAIL on the
  # old code (--baseline), or it is not testing the change. [guard] must hold on both: a safety property the old
  # code also had, kept so the change cannot lose it.
  chk() {
    local k="$1" l="$2" r; shift 2
    if "$@"; then r=1; else r=0; fi
    if [ "$BASE" = yes ]; then
      if [ "$k" = new ] && [ "$r" = 0 ]; then p=$((p+1)); say "  ok    [new: FAILS on old] $l"
      elif [ "$k" = new ]; then x=$((x+1)); say "  FAIL  [new, but HOLDS on old -- proves nothing] $l"
      elif [ "$r" = 1 ]; then p=$((p+1)); say "  ok    [guard: holds on old] $l"
      else x=$((x+1)); say "  FAIL  [guard, BROKEN on old] $l"; fi
    elif [ "$r" = 1 ]; then p=$((p+1)); say "  ok    $l"
    else x=$((x+1)); say "  FAIL  $l"; fi
  }
  has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
  hasnt() { ! has "$1" "$2"; }
  eqv() { [ "$1" = "$2" ]; }
  isdir() { [ -d "$1" ]; }
  absent() { [ ! -e "$1" ]; }
  empty() { [ -d "$1" ] && [ -z "$(command ls -A "$1")" ]; }
  rows() { cat "$1" 2>/dev/null | grep -c -- "$2" || true; }   # a missing ledger is 0 rows, not ""

  # Extract. Every new function must be there -- a missing one would be an undefined command at the call site,
  # exit 127, and a removal that silently never ran (the forward-reference trap this file records). Only the
  # --baseline run (old code, which has none of them) may proceed without them.
  # qn (NWP-20261008-09): the in arm prints the profile name through it.
  # reap_retry_add / reap_retry_run (NWP-20261114-15): the reap now calls both; test-reap-retry.sh is their suite.
  for fn in extra_user_paths userdir_has_record userdir_census userdir_census_fold reap_userdir_settle reap_userdir_take userdir_pending_add userdir_recheck reap_retry_add reap_retry_run qn; do
    t=$(fn_of "$f" "$fn")
    if [ -z "$t" ] && { [ "$BASE" = no ] || [ "$fn" = extra_user_paths ]; }; then
      echo "EXTRACTION FAILED: function $fn not found in $f" >&2; return 2
    fi
    # NWP-20261104-14: the baseline (old code) has neither re-check function; a no-op stands in so the [new]
    # cases fail by behaviour and not by an undefined command tripping guard H.
    if [ -z "$t" ] && [ "$BASE" = yes ]; then
      case "$fn" in userdir_pending_add|userdir_recheck|reap_retry_add|reap_retry_run) t="$fn() { :; }" ;; esac
    fi
    FUNCS="$FUNCS$t"$'\n'
  done
  # NWP-20261104-14: the line directly before the one top-level `case "$op" in` is where the re-check is called.
  # It is taken from the file, never typed here, so a mutant that edits it is run as edited. Anything else there
  # (a comment, another statement, or the old code's closing brace) runs as `:`.
  n=$(awk '$0 == "case \"$op\" in" {c++; next} c == 1 && $0 == "  sealdelta)" {a=1} END {print (c == 1 && a == 1) ? "ok" : "no"}' "$f")
  [ "$n" = ok ] || { echo "EXTRACTION FAILED: the top-level case \"\$op\" (with a sealdelta arm below it) in $f" >&2; return 2; }
  PRE=$(awk 'prev != "" && $0 == "case \"$op\" in" {print prev; exit} {prev=$0}' "$f")
  case "$PRE" in '#'*) PRE=: ;; *userdir_recheck*) ;; *) PRE=: ;; esac
  CLEAN=$(op_of "$f" cleanstorage); BOOT=$(op_of "$f" bootsweep); SEED=$(arm_of "$f" seedssaid); IN=$(arm_of "$f" in)
  case "$CLEAN" in *'_reapleft'*'reap-ledger'*) ;; *) echo "EXTRACTION FAILED: cleanstorage op in $f" >&2; return 2 ;; esac
  case "$BOOT" in *'bootsweep result'*) ;; *) echo "EXTRACTION FAILED: bootsweep op in $f" >&2; return 2 ;; esac
  # NWP-20261005-23: the reap removes "$DE_PARK_ROOT/$uid", a global defined outside the op, so run_clean defines it
  # the same way; this keeps that copy honest.
  grep -qxF 'DE_PARK_ROOT="$STATE/coldde"' "$f" || { echo "EXTRACTION FAILED: DE_PARK_ROOT definition in $f" >&2; return 2; }
  case "$SEED" in *'nowhere-ssaid-seed'*) ;; *) echo "EXTRACTION FAILED: seedssaid arm in $f" >&2; return 2 ;; esac
  case "$IN" in *'echo "NEEDKEY" > "$RES"'*'echo "BLANK" > "$RES"'*'headblobs'*) ;; *) echo "EXTRACTION FAILED: the in arm in $f" >&2; return 2 ;; esac
  EXPR=$(scrub_expr "$f") || { echo "EXTRACTION FAILED: log_scrub's sed expression in $f" >&2; return 2; }
  local RF RC RB RS RI v
  RF=$(reroot "$FUNCS"); RC=$(reroot "$CLEAN"); RB=$(reroot "$BOOT"); RS=$(reroot "$SEED"); RI=$(reroot "$IN")
  for t in RF:5 RC:6 RB:8 RS:3 RI:5; do
    v=${t%%:*}
    n=$(nrew "${!v}")
    [ "$n" -ge "${t#*:}" ] || { echo "RE-ROOT FAILED: $v has $n rewritten paths, want >= ${t#*:}" >&2; return 2; }
    n=$(nleft "${!v}")
    [ "$n" = 0 ] || { echo "RE-ROOT INCOMPLETE: $v keeps $n absolute /data path(s) in live code" >&2; return 2; }
  done

  # An undefined function is exit 127 with no output -- the forward-reference trap -- and an unbound variable or
  # a parse error aborts a run that may still have written half its result. Any of those makes a scenario
  # meaningless, so every run's stderr is checked, and the last assertion of the suite says whether it was clean.
  HARN=""
  SD=$(mktemp -d -p "$W")   # this suite run's own scratch (mutants run concurrently, each in its own)
  printf '%s\n' "$RF" > "$SD/rf.sh"
  harness_check() {
    local e
    # -i and `: not found`: dash reports "Syntax error" and "<cmd>: not found", mksh "<cmd>: inaccessible or not found"
    e=$(grep -m1 -iE 'command not found|: (inaccessible or )?not found|unbound variable|syntax error|bad substitution' "$1/sim/stderr" 2>/dev/null)
    [ -z "$e" ] || HARN="$HARN [$e]"
  }
  run_clean() {  # run_clean <root> <uid>; then drain
    ( ROOT="$1"; uid="$2"; op=cleanstorage; name=""; pass=""; LANE=rw
      LOG="$ROOT/roam.log"; RES="$ROOT/res"; STATE="$ROOT/state"; KS_DROP="$ROOT/keystore-drop"   # NWP-20261102-05: cleanstorage removes the staged drop list
      KS_CREDS="$STATE/ks-creds"; KS_EXPORT="$ROOT/ks-export"; KS_MAP="$ROOT/ks-map"; KS_KEEP="$ROOT/ks-keep"; KS_CENSUS="$ROOT/ks-census"
      DE_PARK_ROOT="$STATE/coldde"   # as roamd defines it (checked at extraction)
      stop_mediad() { :; }; bt_reset() { return 0; }; log_scrub() { :; }
      loc_release() { :; }   # NWP-20261016-45: the location globals are test-locglobals.sh's, not this suite's
      md_release() { :; }    # NWP-20261026-05: mobile data is test-mobiledata's, not this suite's
      dt_release() { :; }    # NWP-20261027-05: the device toggles are test-devtoggles's, not this suite's
      dr_release() { :; }    # NWP-20261028-07: data roaming is test-dataroaming's, not this suite's
      hs_release() { :; }    # NWP-20261028-10: the hotspot is test-hotspot-release's, not this suite's
      ks_reap_clear() { :; } # NWP-20261114-18: the keystore staging clear is test-reap-ks-staging's, not this suite's
      keystore_push() { if [ -f "$ROOT/sim/kshook" ]; then . "$ROOT/sim/kshook"; fi; KS_VERDICT=sealed; }
      sim_stubs
      eval "$RF"
      eval "$RC" ) >/dev/null 2>>"$1/sim/stderr"
    drain "$1"
    harness_check "$1"
  }
  run_boot() {  # run_boot <root>
    ( ROOT="$1"; op=bootsweep; name=""; pass=""; uid=""
      LOG="$ROOT/roam.log"; RES="$ROOT/res"; STATE="$ROOT/state"; KS_DROP="$ROOT/keystore-drop"   # NWP-20261102-04: the bootsweep ksdrop block
      sim_stubs
      loc_boot() { LOC_BOOT=stub; }   # NWP-20261016-45: test-locglobals.sh runs the real one
      md_boot() { MD_BOOT=stub; }     # NWP-20261026-05: the mobile-data suite runs the real one
      staging_boot() { STAGING_BOOT=stub; }   # NWP-20261107-01: test-bootsweep-staging.sh runs the real one
      dt_boot() { DT_BOOT=stub; }     # NWP-20261027-05: the device-toggles suite runs the real one
      dr_boot() { DR_BOOT=stub; }     # NWP-20261028-07: the data-roaming suite runs the real one
      hs_release() { HS_VERDICT="OK RELEASED"; }   # NWP-20261028-10: the hotspot suite runs the real one
      # stat -c %u answers 1000 (system) unless sim/owner says "<path> <uid>". chown, chmod and restorecon fail
      # for a path listed in sim/ownfail, sim/chmodfail and sim/rcfail respectively, and each leaves a line in
      # sim/calls whether or not it fails. (A test host cannot chown, nor relabel.)
      stat() {
        if [ "$1" = -c ] && [ "$2" = %u ]; then
          local o=1000 a b
          if [ -f "$ROOT/sim/owner" ]; then while read -r a b; do [ "$a" = "$3" ] && o=$b; done < "$ROOT/sim/owner"; fi
          printf '%s\n' "$o"; return 0
        fi
        command stat "$@"
      }
      chown() {
        local l; for l in "$@"; do :; done
        echo "chown $*" >> "$ROOT/sim/calls"
        ! grep -qxF -- "$l" "$ROOT/sim/ownfail" 2>/dev/null
      }
      chmod() {
        local l; for l in "$@"; do :; done
        echo "chmod $*" >> "$ROOT/sim/calls"
        grep -qxF -- "$l" "$ROOT/sim/chmodfail" 2>/dev/null && return 1
        command chmod "$@"
      }
      restorecon() {
        local l; for l in "$@"; do :; done
        echo "restorecon $*" >> "$ROOT/sim/calls"
        ! grep -qxF -- "$l" "$ROOT/sim/rcfail" 2>/dev/null
      }
      eval "$RF"
      eval "$RB" ) >/dev/null 2>>"$1/sim/stderr"
    harness_check "$1"
  }
  run_seed() {  # run_seed <root> <uid>
    ( ROOT="$1"; uid="$2"; op=seedssaid; name=x; pass=""; sesec="$KEY64"
      LOG="$ROOT/roam.log"; RES="$ROOT/res"; STATE="$ROOT/state"
      chown() { :; }; restorecon() { :; }; _ms() { echo 0; }
      print() {  # mksh's builtin, as this arm uses it: print -r -- / print -rn --
        local nl=1
        while [ $# -gt 0 ]; do case "$1" in -rn|-nr) nl=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done
        if [ "$nl" = 1 ]; then printf '%s\n' "$*"; else printf '%s' "$*"; fi
      }
      sim_stubs
      eval "$RF"
      eval "case \"\$op\" in $RS esac" ) >/dev/null 2>>"$1/sim/stderr"
    harness_check "$1"
  }
  # run_in <root> <uid> <ok|blank|needkey> [consume]: the REAL roam-in arm. The agent is a stub that answers what
  # the scenario says: "ok" restores, "blank" fails the restore (wrong creds, or a store/connection error -- both
  # reach roamd as a failed restore), "needkey" is a 2FA profile signing in with no key, in NFC-first mode.
  # Every helper the arm calls is a no-op; the arm's own decisions and its own file operations are real.
  # "consume" is the agent's other half: it takes roamd's reply and deletes $RES the instant the reply is
  # written, before roamd's next line -- the worst case of what its poll really does (runWorkerHeld removes $RES
  # on its first non-empty read and does not wait for roamd to exit). echo is wrapped to do that for the three
  # replies, and sim/consumed keeps what it took.
  run_in() {
    ( ROOT="$1"; uid="$2"; SIM_MODE="$3"; op=in; name=prof; pass=pw; keymode=""; srcunit=""; sesec=""
      [ "$3" = needkey ] && keymode=nfcfirst
      LOG="$ROOT/roam.log"; RES="$ROOT/res"; STATE="$ROOT/state"; USERDIR="$ROOT/data/user/$uid"; AGENT=agent_sim
      if [ "${4:-}" = consume ]; then
        echo() {
          builtin echo "$@"
          case "$*" in "OK $uid"|BLANK|NEEDKEY) command cat "$RES" >> "$ROOT/sim/consumed"; command rm -f "$RES" ;; esac
        }
      fi
      agent_sim() {
        case "$1" in
          fido2-is-enrolled) [ "$SIM_MODE" = needkey ] ;;
          restore) [ "$SIM_MODE" = ok ] ;;
          *) return 1 ;;
        esac
      }
      pw() { printf '%s\n' "$ROOT/sim/pw"; }
      _ms() { echo 0; }
      for t in stop_mediad usb_host relabel_launcher remap_media_db remap_per_pkg _tlog acct_restore remap_tree reown_ext_appdata \
               keystore_push keystore_restore ks_signin_reset hold_ondemand od_parked_report reap_stale_ondemand reap_orphan_provisioned restorecon \n               uiderrors_floor_take uiderrors_floor_commit tz_surface; do  # NWP-20261010-06: the report's sign-in floor
        eval "$t() { :; }"
      done
      in_scope_tokens() { printf '+de +media'; }   # NWP-20261113-15: the IN line's scope tokens
      bt_reset() { BT_RESTORED=0; return 0; }
      print() {
        local nl=1
        while [ $# -gt 0 ]; do case "$1" in -rn|-nr) nl=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done
        if [ "$nl" = 1 ]; then printf '%s\n' "$*"; else printf '%s' "$*"; fi
      }
      sim_stubs
      eval "$RF"
      eval "case \"\$op\" in $RI esac" ) >/dev/null 2>>"$1/sim/stderr"
    harness_check "$1"
  }
  # run_recheck <root> <own uid or ""> <lane> <shell> [<body>]: the pre-case line (taken from the file), or <body>,
  # run by <shell> over the real extracted functions. The scenario is a script file so dash and mksh, which the
  # device's sh is (mksh), run it too; the bash-only parts of this harness (${!v}, declare -f) stay out of it.
  # bash 5.2+ prints a nested function as `function f ()`, which dash cannot parse: the sed writes `f ()`.
  run_recheck() {
    local r="$1" own="$2" lane="${3:-rw}" shl="${4:-bash}" s="$SD/rr.sh" body="${5-$PRE}"
    { printf "ROOT='%s'; uid='%s'; LANE='%s'; LOG=\"\$ROOT/roam.log\"; STATE=\"\$ROOT/state\"\n" "$r" "$own" "$lane"
      declare -f sim_stubs | sed -E 's/^([[:space:]]*)function ([A-Za-z_][A-Za-z0-9_]*) \(\)/\1\2 ()/'
      printf 'sim_stubs\n. "%s/rf.sh"\n%s\n' "$SD" "$body"
    } > "$s"
    "$shl" "$s" >/dev/null 2>>"$r/sim/stderr"
    drain "$r"
    harness_check "$r"
  }
  pend() { printf '%s\n' "$2" > "$1/state/userdir-pending"; }
  pendof() { cat "$1/state/userdir-pending" 2>/dev/null; }
  ledof() { cat "$1/data/nowhere/reap-ledger" 2>/dev/null; }
  nouser0() { command rm -f "$1/data/system/users/0.xml"; }
  U="data/system/users"
  cline() { grep '^\[roamd\] cleanstorage user 11 ' "$1/roam.log" 2>/dev/null; }

  say "== R1, the reap: users/<uid> is removed only after the record goes, and again if a writer puts it back =="
  # The 2026-10-02 shape: the framework deletes the dir (tick 2) and then the record (tick 3); an FBE tree the
  # rm cannot unlink survives until tick 5; a writer re-creates the dir at tick 5 (with a package-named file)
  # and again at tick 6, after every other survivor has cleared -- caught only because of the quiet tail.
  mkroot
  : > "$R/$U/11.xml"; plant "$R/$U/11/settings_secure.xml"
  plant "$R/data/user_de/11/f"; refuse "$R" "$R/data/user_de/11"
  ev "$R" 2 'command rm -rf "$ROOT/data/system/users/11"'
  ev "$R" 3 'command rm -f "$ROOT/data/system/users/11.xml"'
  ev "$R" 5 'command rm -rf "$ROOT/data/user_de/11"; mkdir -p "$ROOT/data/system/users/11"; echo s > "$ROOT/data/system/users/11/settings_secure.xml"; echo p > "$ROOT/data/system/users/11/res_com.example.SENTINEL.xml"'
  ev "$R" 6 'mkdir -p "$ROOT/data/system/users/11"; echo i > "$ROOT/data/system/users/11/settings_ssaid.xml"'
  run_clean "$R" 11
  cl=$(cline "$R"); ldg=$(cat "$R/data/nowhere/reap-ledger" 2>/dev/null); lg=$(cat "$R/roam.log" 2>/dev/null)
  chk new "R1a two re-creations after the anchor -> after:2, anchor polls:3, no left" has "$cl" " userdir=anchor:ok,polls:3,after:2 "
  chk new "R1a users/11 is GONE at the end, including the late (tick 6) re-creation" absent "$R/$U/11"
  chk new "R1a the reap is class=clean -- nothing survived it" has "$cl" " class=clean "
  chk new "R1a the quiet tail ran exactly: last re-creation at tick 6, then 12 quiet polls (18 sleeps)" eqv "$(cat "$R/sim/ticks")" 18
  chk new "R1a a ledger row is written although the class is clean, with the userdir verdict" has "$ldg" "class=clean keys=sealed survives: userdir=anchor:ok,polls:3,after:2 "
  chk new "R1a its census names both writers' files and counts the package-named one" has "$ldg" "census:files:settings_secure.xml,settings_ssaid.xml other=1"
  chk guard "R1a the package-named file is never named, in the ledger" hasnt "$ldg" SENTINEL
  chk guard "R1a ... nor in roam.log" hasnt "$lg" SENTINEL
  chk new "R1a positive control: an allowlisted name IS written (the census can name things)" has "$ldg" "settings_ssaid.xml"
  if has "$(printf '%s\n' 'userdir="anchor:ok"' | sed -E "$EXPR")" 'anchor:ok'; then
    chk guard "R1a log_scrub control: the extracted expression rewrites a quoted token" false
  else
    chk new "R1a the userdir field survives the REAL log_scrub (it is unquoted)" has "$(printf '%s\n' "$cl" | sed -E "$EXPR")" " userdir=anchor:ok,polls:3,after:2 "
  fi
  chk new "R1a the reply is OK (the old code left the re-created directory and replied residue)" eqv "$(cat "$R/res" 2>/dev/null)" OK
  command rm -rf "$R"

  say ""
  say "== R1: a re-creation INSIDE the quiet tail is caught, past the loop's base cap of 12 polls =="
  # R1a plus a third writer at tick 15: 9 polls into the tail that started at tick 6, and the poll it lands
  # before is the loop's 13th -- beyond the 12 a reap without the raised cap would run.
  mkroot
  : > "$R/$U/11.xml"; plant "$R/$U/11/settings_secure.xml"
  plant "$R/data/user_de/11/f"; refuse "$R" "$R/data/user_de/11"
  ev "$R" 2 'command rm -rf "$ROOT/data/system/users/11"'
  ev "$R" 3 'command rm -f "$ROOT/data/system/users/11.xml"'
  ev "$R" 5 'command rm -rf "$ROOT/data/user_de/11"; mkdir -p "$ROOT/data/system/users/11"; echo s > "$ROOT/data/system/users/11/settings_secure.xml"'
  ev "$R" 6 'mkdir -p "$ROOT/data/system/users/11"; echo i > "$ROOT/data/system/users/11/settings_ssaid.xml"'
  ev "$R" 15 'mkdir -p "$ROOT/data/system/users/11"; echo a > "$ROOT/data/system/users/11/app_idle_stats.xml"'
  run_clean "$R" 11
  cl=$(cline "$R"); ldg=$(cat "$R/data/nowhere/reap-ledger" 2>/dev/null)
  chk new "R1i the tick-15 re-creation is caught: after:3" has "$cl" " userdir=anchor:ok,polls:3,after:3 "
  chk new "R1i users/11 is GONE at the end (a reap that stopped early leaves the tick-15 write on disk)" absent "$R/$U/11"
  chk new "R1i the tail restarts at the third removal: 12 more polls (27 sleeps)" eqv "$(cat "$R/sim/ticks")" 27
  chk new "R1i the census names all three writers' files" has "$ldg" "census:files:settings_secure.xml,settings_ssaid.xml,app_idle_stats.xml other=0"
  command rm -rf "$R"

  say ""
  say "== R1: the raised cap is only what the tail needs -- a reap that cannot end early is not held to 40 polls =="
  # A skipped destroyUserData: users/11 is still full when the record goes, and an FBE tree the rm cannot unlink
  # survives the whole reap, so the loop can never break and runs to its cap. The tail after the removal at the
  # anchor needs 13 polls; HEAD ran 12 here, and a flat raise to 40 held the RW lane for 27 more polls that serve
  # no tail.
  mkroot
  plant "$R/$U/11/settings_system.xml"; plant "$R/data/user_de/11/f"; refuse "$R" "$R/data/user_de/11"
  run_clean "$R" 11
  cl=$(cline "$R")
  chk guard "R1p a removal at the anchor on a residue reap runs at most 13 polls (it ran 12 before)" test "$(cat "$R/sim/ticks")" -le 13
  chk new "R1p ... and it is the removal at the anchor, on a residue reap" has "$cl" " class=residue keys=sealed userdir=anchor:ok,polls:0,after:0,atanchor "
  chk guard "R1p ... users/11 is gone" absent "$R/$U/11"
  command rm -rf "$R"
  # A writer that never stops (here: users/11 is there at the anchor, and is put back every 3 ticks until tick
  # 60). Each removal raises the cap again, and the ceiling of 40 polls is all that ends the loop. The writer
  # outlives the reap; that is the boot sweep's.
  mkroot
  plant "$R/$U/11/app_idle_stats.xml"
  for t in $(seq 3 3 60); do ev "$R" "$t" 'mkdir -p "$ROOT/data/system/users/11"; echo a > "$ROOT/data/system/users/11/app_idle_stats.xml"'; done
  run_clean "$R" 11
  cl=$(cline "$R")
  chk guard "R1r a writer that never stops cannot hold the reap past 40 polls" test "$(cat "$R/sim/ticks")" -le 40
  chk new "R1r ... and the loop runs to that ceiling, removing every re-creation it sees (after:13)" \
      eqv "$(cat "$R/sim/ticks")$(has "$cl" ' userdir=anchor:ok,polls:0,after:13,atanchor ' && echo A)" 40A
  command rm -rf "$R"

  say ""
  say "== R1: the 2026-10-02 timing -- a writer put users/11 back DURING the keystore wait, before the first look =="
  # The framework deletes users/11 and then 11.xml, and SettingsProvider writes settings_secure.xml and
  # settings_ssaid.xml into a new users/11 -- all while keystore_push waits, so the settle finds the directory
  # already there when the record has gone. That is how the lynx orphan was found.
  mkroot
  : > "$R/$U/11.xml"; plant "$R/$U/11/settings_secure.xml" OLD
  printf '%s\n' 'command rm -rf "$ROOT/data/system/users/11"; command rm -f "$ROOT/data/system/users/11.xml"' \
    'mkdir -p "$ROOT/data/system/users/11"; echo s > "$ROOT/data/system/users/11/settings_secure.xml"; echo i > "$ROOT/data/system/users/11/settings_ssaid.xml"' > "$R/sim/kshook"
  run_clean "$R" 11
  cl=$(cline "$R"); ldg=$(cat "$R/data/nowhere/reap-ledger" 2>/dev/null)
  chk new "R1j there at the first look -> atanchor, and not counted as a re-creation" has "$cl" " userdir=anchor:ok,polls:0,after:0,atanchor "
  chk new "R1j users/11 is GONE at the end" absent "$R/$U/11"
  chk new "R1j a ledger row is written for it although the class is clean" has "$ldg" "uid=11 class=clean keys=sealed survives: userdir=anchor:ok,polls:0,after:0,atanchor "
  chk new "R1j ... and its census names the files the writer left" has "$ldg" "census:files:settings_secure.xml,settings_ssaid.xml other=0"
  chk new "R1j the quiet tail runs after a removal at the anchor too: 12 polls, ending clean" eqv "$(cat "$R/sim/ticks")$(has "$cl" ' class=clean ' && echo C)" 12C
  chk new "R1j the reply is OK" eqv "$(cat "$R/res" 2>/dev/null)" OK
  command rm -rf "$R"

  say ""
  say "== R1: ... and the same writer writing again 0.5 s later is caught by that tail =="
  mkroot
  : > "$R/$U/11.xml"; plant "$R/$U/11/settings_secure.xml" OLD
  printf '%s\n' 'command rm -rf "$ROOT/data/system/users/11"; command rm -f "$ROOT/data/system/users/11.xml"' \
    'mkdir -p "$ROOT/data/system/users/11"; echo s > "$ROOT/data/system/users/11/settings_secure.xml"' > "$R/sim/kshook"
  ev "$R" 2 'mkdir -p "$ROOT/data/system/users/11"; echo i > "$ROOT/data/system/users/11/settings_ssaid.xml"'
  run_clean "$R" 11
  cl=$(cline "$R"); ldg=$(cat "$R/data/nowhere/reap-ledger" 2>/dev/null)
  chk new "R1k atanchor plus one re-creation inside the tail -> after:1,atanchor" has "$cl" " userdir=anchor:ok,polls:0,after:1,atanchor "
  chk new "R1k users/11 is GONE at the end -- the second write did not outlive the reap" absent "$R/$U/11"
  chk new "R1k the ledger census names both writes" has "$ldg" "userdir=anchor:ok,polls:0,after:1,atanchor census:files:settings_secure.xml,settings_ssaid.xml other=0"
  command rm -rf "$R"

  say ""
  say "== R1: ... and a write landing just before the tail's LAST poll (the 12th quiet one) is caught too =="
  # The tail's 12th quiet poll is the 13th past the removal's poll, so the raised cap must let it run: a cap of
  # 12 past the removal ends the loop on the same sleep count without making that look.
  mkroot
  : > "$R/$U/11.xml"; plant "$R/$U/11/settings_secure.xml" OLD
  printf '%s\n' 'command rm -rf "$ROOT/data/system/users/11"; command rm -f "$ROOT/data/system/users/11.xml"' \
    'mkdir -p "$ROOT/data/system/users/11"; echo s > "$ROOT/data/system/users/11/settings_secure.xml"' > "$R/sim/kshook"
  ev "$R" 12 'mkdir -p "$ROOT/data/system/users/11"; echo i > "$ROOT/data/system/users/11/settings_ssaid.xml"'
  run_clean "$R" 11
  cl=$(cline "$R")
  chk new "R1s the tick-12 write is seen: after:1,atanchor" has "$cl" " userdir=anchor:ok,polls:0,after:1,atanchor "
  chk new "R1s users/11 is GONE at the end, and the tail restarted from that removal (24 sleeps)" \
      eqv "$(cat "$R/sim/ticks")$(absent "$R/$U/11" && echo G)" 24G
  command rm -rf "$R"

  say ""
  say "== R1: a re-creation whose rm a writer races still gets polls to retry it, in a tail or not =="
  # R1s's write at tick 12, but the rm at that poll is refused (rmdir loses to a writer still filling the
  # directory) and the race is over at tick 13. Once a tail is running its cap is the loop's only budget, so a
  # refused removal must raise it too, or the loop ends on the tail's last poll with the cleartext left behind.
  mkroot
  : > "$R/$U/11.xml"; plant "$R/$U/11/settings_secure.xml" OLD
  printf '%s\n' 'command rm -rf "$ROOT/data/system/users/11"; command rm -f "$ROOT/data/system/users/11.xml"' \
    'mkdir -p "$ROOT/data/system/users/11"; echo s > "$ROOT/data/system/users/11/settings_secure.xml"' > "$R/sim/kshook"
  ev "$R" 12 'mkdir -p "$ROOT/data/system/users/11"; echo i > "$ROOT/data/system/users/11/settings_ssaid.xml"; echo "$ROOT/data/system/users/11" > "$ROOT/sim/refuse"'
  ev "$R" 13 'command rm -f "$ROOT/sim/refuse"'
  run_clean "$R" 11
  cl=$(cline "$R")
  chk new "R1t the refused tick-12 re-creation is cleared on the retry -> after:1,atanchor, NOT left" \
      has "$cl" " class=clean keys=sealed userdir=anchor:ok,polls:0,after:1,atanchor "
  chk new "R1t users/11 and its settings_ssaid.xml are gone, and the tail ran from the rm that cleared it (25 sleeps)" \
      eqv "$(cat "$R/sim/ticks")$(absent "$R/$U/11" && echo G)" 25G
  command rm -rf "$R"
  # The raise is once per removal: a re-creation that is never cleared buys the same 13 polls as any other, and
  # the cap does not move again on each poll it stays (which would hold the reap to the ceiling every time).
  mkroot
  plant "$R/$U/11/settings_system.xml"
  ev "$R" 5 'mkdir -p "$ROOT/data/system/users/11"; echo i > "$ROOT/data/system/users/11/settings_ssaid.xml"; echo "$ROOT/data/system/users/11" > "$ROOT/sim/refuse"'
  run_clean "$R" 11
  cl=$(cline "$R")
  chk new "R1w a re-creation that stays LEFT raises the cap once: 13 past its poll (18 sleeps), then reported left" \
      eqv "$(cat "$R/sim/ticks")$(has "$cl" ' class=residue keys=sealed userdir=anchor:ok,polls:0,after:1,atanchor,left ' && echo L)" 18L
  chk guard "R1w ... and the directory the rm could not clear is still there, not reported gone" isdir "$R/$U/11"
  command rm -rf "$R"
  # ... and that raise is held to the same ceiling: a writer that kept the tail going to poll 36, then put the
  # directory back at poll 39 where its rm is refused for good.
  mkroot
  plant "$R/$U/11/app_idle_stats.xml"
  for t in $(seq 3 3 36); do ev "$R" "$t" 'mkdir -p "$ROOT/data/system/users/11"; echo a > "$ROOT/data/system/users/11/app_idle_stats.xml"'; done
  ev "$R" 39 'mkdir -p "$ROOT/data/system/users/11"; echo a > "$ROOT/data/system/users/11/app_idle_stats.xml"; echo "$ROOT/data/system/users/11" > "$ROOT/sim/refuse"'
  run_clean "$R" 11
  cl=$(cline "$R")
  chk guard "R1x a refused re-creation late in the tail cannot hold the reap past 40 polls" test "$(cat "$R/sim/ticks")" -le 40
  chk new "R1x ... it ends on the ceiling, left (40 sleeps, after:13)" \
      eqv "$(cat "$R/sim/ticks")$(has "$cl" ' userdir=anchor:ok,polls:0,after:13,atanchor,left ' && echo L)" 40L
  command rm -rf "$R"
  # The same race when the re-creation is the reap's FIRST removal, so no tail is running: users/11 is already
  # gone at the anchor, and an FBE tree the rm cannot unlink keeps the loop running its base 12 polls (the usual
  # enforcing shape). The re-creation lands before the 12th of them (tick 11) with its rm refused, and the race is
  # over at tick 12. The base cap is then the loop's only budget, as a tail's cap is, so the rm needs polls too.
  mkroot
  plant "$R/data/system_ce/11/blob"; refuse "$R" "$R/data/system_ce/11"
  ev "$R" 11 'mkdir -p "$ROOT/data/system/users/11"; echo i > "$ROOT/data/system/users/11/settings_ssaid.xml"; echo "$ROOT/data/system/users/11" >> "$ROOT/sim/refuse"'
  ev "$R" 12 'grep -vxF "$ROOT/data/system/users/11" "$ROOT/sim/refuse" > "$ROOT/sim/refuse.n"; command mv "$ROOT/sim/refuse.n" "$ROOT/sim/refuse"'
  run_clean "$R" 11
  cl=$(cline "$R")
  chk new "R1y a refused re-creation with no tail running is cleared on the retry -> after:1, NOT left" \
      has "$cl" " class=residue keys=sealed userdir=anchor:ok,polls:0,after:1 "
  chk new "R1y users/11 and its settings_ssaid.xml are gone, and the tail ran from the rm that cleared it (25 sleeps)" \
      eqv "$(cat "$R/sim/ticks")$(absent "$R/$U/11" && echo G)" 25G
  command rm -rf "$R"
  # ... and its control: the same re-creation with an rm that is NOT refused starts the tail on that poll, so the
  # cap is 13 past it (24 sleeps; R1y's 25 is this plus the one poll its refused rm waited). The new tail records
  # the removal it raised the cap for (_ud_capt), or the next poll would take it for an unanswered one and raise
  # the cap a second time.
  mkroot
  plant "$R/data/system_ce/11/blob"; refuse "$R" "$R/data/system_ce/11"
  ev "$R" 11 'mkdir -p "$ROOT/data/system/users/11"; echo i > "$ROOT/data/system/users/11/settings_ssaid.xml"'
  run_clean "$R" 11
  cl=$(cline "$R")
  chk new "R1z the same re-creation with its rm not refused -> after:1, removed on that poll" \
      has "$cl" " class=residue keys=sealed userdir=anchor:ok,polls:0,after:1 "
  chk new "R1z users/11 is gone, and the cap is 13 past the removal, raised once (24 sleeps)" \
      eqv "$(cat "$R/sim/ticks")$(absent "$R/$U/11" && echo G)" 24G
  command rm -rf "$R"

  say ""
  say "== R1: a record that never goes means the user may be live -- never remove =="
  mkroot
  : > "$R/$U/11.xml"; plant "$R/$U/11/settings_secure.xml" LIVE
  run_clean "$R" 11
  cl=$(cline "$R"); ldg=$(cat "$R/data/nowhere/reap-ledger" 2>/dev/null)
  chk new "R1b anchor:timeout after 80 polls, nothing re-created" has "$cl" " userdir=anchor:timeout,polls:80,after:0 "
  chk new "R1b users/11 is UNTOUCHED -- its file is still there" eqv "$(cat "$R/$U/11/settings_secure.xml" 2>/dev/null)" LIVE
  chk new "R1b the ledger says so: residue, anchor:timeout, nothing removed" has "$ldg" "class=residue keys=sealed survives: $R/$U/11 userdir=anchor:timeout,polls:80,after:0 census:none"
  chk new "R1b the reply reports the residue (the old code deleted it and replied OK)" eqv "$(cat "$R/res" 2>/dev/null)" ERR-REAP-RESIDUE
  command rm -rf "$R"

  say ""
  say "== R1: a record that is only .backup (a rewrite in flight) or only .reservecopy is still a record =="
  for t in backup reservecopy; do
    mkroot
    : > "$R/$U/11.xml.$t"; plant "$R/$U/11/settings_secure.xml" LIVE
    run_clean "$R" 11
    cl=$(cline "$R")
    chk new "R1c only 11.xml.$t -> anchor:timeout" has "$cl" " userdir=anchor:timeout,polls:80,after:0 "
    chk new "R1c only 11.xml.$t -> the live file survives" eqv "$(cat "$R/$U/11/settings_secure.xml" 2>/dev/null)" LIVE
    command rm -rf "$R"
  done

  say ""
  say "== R1: if user 0's record cannot be seen, the reap is BLIND and removes nothing =="
  mkroot
  command rm -f "$R/$U/0.xml"; plant "$R/$U/11/settings_secure.xml" KEEP
  run_clean "$R" 11
  cl=$(cline "$R"); ldg=$(cat "$R/data/nowhere/reap-ledger" 2>/dev/null)
  chk new "R1d no 0.xml -> anchor:blind, polls:0" has "$cl" " userdir=anchor:blind,polls:0,after:0 "
  chk new "R1d ... and users/11 is untouched" eqv "$(cat "$R/$U/11/settings_secure.xml" 2>/dev/null)" KEEP
  chk new "R1d the ledger records the blind anchor" has "$ldg" "userdir=anchor:blind,polls:0,after:0 census:none"
  command rm -rf "$R"

  say ""
  say "== R1: a blind or timed-out anchor with NO users/11 is still recorded -- the class alone says clean =="
  mkroot
  command rm -f "$R/$U/0.xml"
  run_clean "$R" 11
  cl=$(cline "$R"); ldg=$(cat "$R/data/nowhere/reap-ledger" 2>/dev/null)
  chk guard "R1l blind, nothing on disk -> class=clean" has "$cl" " class=clean "
  chk new "R1l ... and the ledger still gets a row saying the anchor was blind" has "$ldg" "uid=11 class=clean keys=sealed survives: userdir=anchor:blind,polls:0,after:0 census:none"
  command rm -rf "$R"
  mkroot
  : > "$R/$U/11.xml"
  run_clean "$R" 11
  cl=$(cline "$R"); ldg=$(cat "$R/data/nowhere/reap-ledger" 2>/dev/null)
  chk guard "R1m timeout, nothing on disk -> class=clean" has "$cl" " class=clean "
  chk new "R1m ... and the ledger still gets a row saying the removal never finished" has "$ldg" "uid=11 class=clean keys=sealed survives: userdir=anchor:timeout,polls:80,after:0 census:none"
  command rm -rf "$R"

  say ""
  say "== R1: a reap that finds nothing in users/<uid> is unchanged -- same polls as before, no ledger row =="
  mkroot
  plant "$R/data/user_de/11/f"; refuse "$R" "$R/data/user_de/11"
  ev "$R" 4 'command rm -rf "$ROOT/data/user_de/11"'
  run_clean "$R" 11
  cl=$(cline "$R")
  chk new "R1e anchor:ok, polls:0, after:0" has "$cl" " class=clean keys=sealed userdir=anchor:ok,polls:0,after:0 "
  chk guard "R1e the loop sleeps exactly as before: 4 polls, until the last survivor cleared at tick 4" eqv "$(cat "$R/sim/ticks")" 4
  chk guard "R1e no ledger row for a clean reap" absent "$R/data/nowhere/reap-ledger"
  chk guard "R1e the reply is OK" eqv "$(cat "$R/res" 2>/dev/null)" OK
  command rm -rf "$R"

  say ""
  say "== R1: a directory still there at the anchor is removed, flagged atanchor, and NOT counted as a re-creation =="
  mkroot
  plant "$R/$U/11/settings_system.xml"
  run_clean "$R" 11
  cl=$(cline "$R"); ldg=$(cat "$R/data/nowhere/reap-ledger" 2>/dev/null)
  chk new "R1f present at the anchor -> after:0,atanchor (a skipped destroyUserData is not a writer)" has "$cl" " userdir=anchor:ok,polls:0,after:0,atanchor "
  chk guard "R1f ... and it is gone" absent "$R/$U/11"
  chk new "R1f class=clean, and the quiet tail ran: 12 sleeps" eqv "$(cat "$R/sim/ticks")$(has "$cl" ' class=clean ' && echo C)" 12C
  chk new "R1f the ledger records what was removed" has "$ldg" "userdir=anchor:ok,polls:0,after:0,atanchor census:files:settings_system.xml other=0"
  command rm -rf "$R"

  say ""
  say "== R1: an rm that cannot clear users/<uid> is LEFT, not a stream of re-creations =="
  mkroot
  plant "$R/$U/11/settings_ssaid.xml"; plant "$R/$U/11/res_com.example.SENTINEL.xml"; refuse "$R" "$R/$U/11"
  run_clean "$R" 11
  cl=$(cline "$R"); ldg=$(cat "$R/data/nowhere/reap-ledger" 2>/dev/null); lg=$(cat "$R/roam.log" 2>/dev/null)
  chk new "R1g refused rm -> after:0,atanchor,left (never after:~12)" has "$cl" " userdir=anchor:ok,polls:0,after:0,atanchor,left "
  chk new "R1g the ledger names what REMAINS, by allowlist" has "$ldg" "census:files:settings_ssaid.xml other=1 remains:files:settings_ssaid.xml other=1"
  chk guard "R1g it is residue, and the loop ran its normal 12 polls (a LEFT removal starts no tail)" eqv "$(cat "$R/sim/ticks")$(has "$cl" ' class=residue ' && echo R)" 12R
  chk guard "R1g the package-named file is not in the ledger" hasnt "$ldg" SENTINEL
  chk new "R1g ... nor in roam.log, although rm complained about it (rm's stderr does not reach the log)" hasnt "$lg" SENTINEL
  command rm -rf "$R"

  say ""
  say "== R1: a LEFT directory that a later rm clears is no longer LEFT, and what a writer added meanwhile is named =="
  # A writer racing the rm at the anchor: the rm cannot clear users/11 (refused here), then at tick 2 the race is
  # over and the writer has added two files -- one allowlisted, one package-named. The poll after that clears it.
  mkroot
  plant "$R/$U/11/settings_system.xml"; plant "$R/$U/11/res_com.example.A.xml"; refuse "$R" "$R/$U/11"
  ev "$R" 2 'command rm -f "$ROOT/sim/refuse"; echo s > "$ROOT/data/system/users/11/settings_secure.xml"; echo p > "$ROOT/data/system/users/11/res_com.example.SENTINEL.xml"'
  run_clean "$R" 11
  cl=$(cline "$R"); ldg=$(cat "$R/data/nowhere/reap-ledger" 2>/dev/null)
  chk new "R1q cleared at tick 2 -> after:0,atanchor and NOT left" has "$cl" " class=clean keys=sealed userdir=anchor:ok,polls:0,after:0,atanchor "
  chk new "R1q users/11 is gone, and the tail ran from the rm that cleared it: 14 sleeps" eqv "$(cat "$R/sim/ticks")$(absent "$R/$U/11" && echo G)" 14G
  chk new "R1q the ledger names the racing writer's file too, and counts each package-named file once" \
      has "$ldg" "userdir=anchor:ok,polls:0,after:0,atanchor census:files:settings_system.xml,settings_secure.xml other=2"
  chk guard "R1q ... and one row, with no remains: nothing is left" eqv "$(rows "$R/data/nowhere/reap-ledger" 'remains:')$(rows "$R/data/nowhere/reap-ledger" 'uid=11 ')" 01
  chk guard "R1q the package-named files are never named in the ledger" hasnt "$ldg" "com.example"
  command rm -rf "$R"
  # The same, but the LEFT episode starts at a RE-CREATION, after an earlier removal: users/11 is removed at the
  # anchor (nothing unnamed in it), put back at tick 3 holding one package-named file with its rm refused, and at
  # tick 5 the race is over and an allowlisted file has been added. The file that outlived the refused rm must be
  # counted once -- against the census of the removal that started THIS episode, not the first removal's.
  mkroot
  plant "$R/$U/11/settings_system.xml"
  ev "$R" 3 'mkdir -p "$ROOT/data/system/users/11"; echo p > "$ROOT/data/system/users/11/res_com.example.A.xml"; echo "$ROOT/data/system/users/11" > "$ROOT/sim/refuse"'
  ev "$R" 5 'command rm -f "$ROOT/sim/refuse"; echo s > "$ROOT/data/system/users/11/settings_secure.xml"'
  run_clean "$R" 11
  cl=$(cline "$R"); ldg=$(cat "$R/data/nowhere/reap-ledger" 2>/dev/null)
  chk new "R1u a LEFT re-creation cleared at tick 5 -> after:1,atanchor and NOT left" \
      has "$cl" " class=clean keys=sealed userdir=anchor:ok,polls:0,after:1,atanchor "
  chk new "R1u users/11 is gone, and the tail ran from the rm that cleared it: 17 sleeps" \
      eqv "$(cat "$R/sim/ticks")$(absent "$R/$U/11" && echo G)" 17G
  chk new "R1u the census counts the file that outlived the refused rm once (other=1) and names the rest" \
      has "$ldg" "userdir=anchor:ok,polls:0,after:1,atanchor census:files:settings_system.xml,settings_secure.xml other=1"
  chk guard "R1u the package-named file is never named in the ledger" hasnt "$ldg" "com.example"
  command rm -rf "$R"

  say ""
  say "== R1: a record that COMES BACK (a soft reboot reissued the id) is a new user -- never remove =="
  mkroot
  plant "$R/data/user_de/11/f"; refuse "$R" "$R/data/user_de/11"
  ev "$R" 2 ': > "$ROOT/data/system/users/11.xml"; mkdir -p "$ROOT/data/system/users/11"; echo n > "$ROOT/data/system/users/11/settings_secure.xml"'
  ev "$R" 6 'command rm -rf "$ROOT/data/user_de/11"'
  run_clean "$R" 11
  cl=$(cline "$R")
  chk new "R1h the reissued user's dir is not counted as a re-creation" has "$cl" " userdir=anchor:ok,polls:0,after:0 "
  chk guard "R1h ... and its file is still there" eqv "$(cat "$R/$U/11/settings_secure.xml" 2>/dev/null)" n
  command rm -rf "$R"

  say ""
  say "== R1: an EMPTY users/<uid> is what a creation looks like before its record -- never removed =="
  # UserManagerService makes the directory (tick 2) and writes the record a tick later; the new user's first
  # file follows. The reap's loop is still running because an FBE tree survives until tick 6.
  mkroot
  plant "$R/data/user_de/11/f"; refuse "$R" "$R/data/user_de/11"
  ev "$R" 2 'mkdir -p "$ROOT/data/system/users/11"'
  ev "$R" 3 ': > "$ROOT/data/system/users/11.xml"; echo s > "$ROOT/data/system/users/11/settings_secure.xml"'
  ev "$R" 6 'command rm -rf "$ROOT/data/user_de/11"'
  run_clean "$R" 11
  cl=$(cline "$R")
  chk guard "R1n the new user's directory survives, with the file written after its record" eqv "$(cat "$R/$U/11/settings_secure.xml" 2>/dev/null)" s
  chk new "R1n ... and nothing was counted" has "$cl" " userdir=anchor:ok,polls:0,after:0 "
  command rm -rf "$R"
  # An empty directory at the anchor is counted as GONE, so a writer that fills it later is a re-creation.
  mkroot
  mkdir -p "$R/$U/11"
  ev "$R" 2 'mkdir -p "$ROOT/data/system/users/11"; echo s > "$ROOT/data/system/users/11/settings_secure.xml"'
  run_clean "$R" 11
  cl=$(cline "$R")
  chk new "R1o empty at the anchor, filled at tick 2 -> after:1, not atanchor" has "$cl" " userdir=anchor:ok,polls:0,after:1 "
  chk new "R1o ... and the filled directory is removed" absent "$R/$U/11"
  command rm -rf "$R"

  say ""
  say "== the census names an AIDL biometric HAL's settings file, and nothing that only looks like one =="
  # An AIDL fingerprint or face HAL (lynx) writes settings_fingerprint_<sensorId>.xml / settings_face_<id>.xml.
  # The pattern is the framework patch's settings_(fingerprint|face)(_[0-9]+)?[.]xml: the two real ones below are
  # named. Each decoy is a name a looser match would admit -- a package after the prefix, a package before a
  # final _<digits>, an empty id, a second prefix -- and must only be counted.
  mkroot
  plant "$R/$U/11/settings_fingerprint_0.xml"; plant "$R/$U/11/settings_face_12.xml"
  plant "$R/$U/11/settings_face_com.example.SENTINEL.xml"; plant "$R/$U/11/settings_face_com.example.SENTINEL_3.xml"
  plant "$R/$U/11/settings_fingerprint_.xml"; plant "$R/$U/11/settings_fingerprint_settings_face_3.xml"
  run_clean "$R" 11
  ldg=$(cat "$R/data/nowhere/reap-ledger" 2>/dev/null)
  chk new "R1v both sensor-id files are named, and the four decoys counted: other=4" \
      has "$ldg" "userdir=anchor:ok,polls:0,after:0,atanchor census:files:settings_face_12.xml,settings_fingerprint_0.xml other=4"
  chk guard "R1v a package never rides in on the pattern (the ledger names no SENTINEL)" hasnt "$ldg" SENTINEL
  chk guard "R1v ... nor a name the pattern rejects: an empty id, or a second prefix" \
      eqv "$(has "$ldg" 'settings_fingerprint_.xml' && echo E)$(has "$ldg" 'settings_fingerprint_settings_face' && echo D)" ""
  command rm -rf "$R"

  say ""
  say "== R4, the reap: a symbolic link at users/<uid> is removed itself, and nothing is censused through it =="
  # NWP-20261011-42. 11 is a link to a directory OUTSIDE users/ holding allowlisted names. The old take censused
  # through it -- the target's file names reached the ledger -- before rm -rf removed the link. The target is
  # never this user's directory, so the take must remove the link alone and name nothing.
  mkroot
  plant "$R/out11/settings_ssaid.xml" TARGET; plant "$R/out11/app_idle_stats.xml" TARGET
  ln -s "$R/out11" "$R/$U/11"
  run_clean "$R" 11
  cl=$(cline "$R"); ldg=$(cat "$R/data/nowhere/reap-ledger" 2>/dev/null)
  chk guard "R4a the link itself is gone: nothing is left at users/11" eqv "$([ -L "$R/$U/11" ] && echo L)$([ -e "$R/$U/11" ] && echo E)" ""
  chk guard "R4a the target is untouched: both its files are still there" \
      eqv "$(cat "$R/out11/settings_ssaid.xml" "$R/out11/app_idle_stats.xml" 2>/dev/null)" TARGETTARGET
  chk new "R4a the reap line says link, not atanchor" has "$cl" " userdir=anchor:ok,polls:0,after:0,link "
  chk new "R4a one ledger row, flagged link, with census:none" \
      eqv "$(rows "$R/data/nowhere/reap-ledger" '^[0-9]* uid=11 class=clean keys=sealed survives: userdir=anchor:ok,polls:0,after:0,link census:none$')" 1
  chk new "R4a the ledger names none of the target's files" \
      eqv "$(hasnt "$ldg" settings_ssaid.xml && echo S)$(hasnt "$ldg" app_idle_stats.xml && echo A)" SA
  chk guard "R4a the reply is OK" eqv "$(cat "$R/res" 2>/dev/null)" OK
  command rm -rf "$R"
  # The same link, but its rm is refused: it stays for the whole reap. LEFT, and still never followed: the
  # remains: field is a census too, and must not be taken through the link either.
  mkroot
  plant "$R/out11/settings_ssaid.xml" TARGET; ln -s "$R/out11" "$R/$U/11"; refuse "$R" "$R/$U/11"
  run_clean "$R" 11
  cl=$(cline "$R"); ldg=$(cat "$R/data/nowhere/reap-ledger" 2>/dev/null); lg=$(cat "$R/roam.log" 2>/dev/null)
  chk guard "R4b a link rm cannot remove is still there, and its target untouched" \
      eqv "$([ -L "$R/$U/11" ] && echo L)$(cat "$R/out11/settings_ssaid.xml" 2>/dev/null)" LTARGET
  chk new "R4b the ledger row says left,link and remains:link, with census:none" \
      eqv "$(rows "$R/data/nowhere/reap-ledger" ' userdir=anchor:ok,polls:0,after:0,left,link census:none remains:link$')" 1
  chk new "R4b neither the ledger nor roam.log names the target's file" \
      eqv "$(hasnt "$ldg" settings_ssaid.xml && echo D)$(hasnt "$lg" settings_ssaid.xml && echo L)" DL
  command rm -rf "$R"
  # A record that comes back (R1h's soft reboot) with a link at users/11: the take keeps it and its target, and
  # censuses nothing. Held open by an FBE survivor until tick 6 so the loop looks at it.
  mkroot
  plant "$R/out11/settings_ssaid.xml" TARGET
  plant "$R/data/user_de/11/f"; refuse "$R" "$R/data/user_de/11"
  ev "$R" 2 ': > "$ROOT/data/system/users/11.xml"; ln -s "$ROOT/out11" "$ROOT/data/system/users/11"'
  ev "$R" 6 'command rm -rf "$ROOT/data/user_de/11"'
  run_clean "$R" 11
  cl=$(cline "$R"); ldg=$(cat "$R/data/nowhere/reap-ledger" 2>/dev/null)
  chk guard "R4c a link whose user has a record is kept, with its target" \
      eqv "$([ -L "$R/$U/11" ] && echo L)$(cat "$R/out11/settings_ssaid.xml" 2>/dev/null)" LTARGET
  chk guard "R4c ... nothing is censused through it: the reap line and ledger name no target file" \
      eqv "$(hasnt "$cl" settings_ssaid.xml && echo C)$(hasnt "$ldg" settings_ssaid.xml && echo D)$(has "$cl" " userdir=anchor:ok,polls:0,after:0 " && echo U)" CDU
  command rm -rf "$R"

  say ""
  say "== R2, the boot sweep: an orphan's CONTENTS go, the directory and everything with a record stays =="
  mkroot
  plant "$R/$U/0/settings_secure.xml" U0
  plant "$R/$U/9/settings_secure.xml" U9
  : > "$R/$U/12.xml"; plant "$R/$U/12/settings_secure.xml" U12
  : > "$R/$U/13.xml.backup"; plant "$R/$U/13/settings_secure.xml" U13
  : > "$R/$U/14.xml.reservecopy"; plant "$R/$U/14/settings_secure.xml" U14
  mkdir -p "$R/$U/15"
  plant "$R/$U/foo/settings_secure.xml" FOO
  plant "$R/$U/userlist.xml" UL; plant "$R/$U/user.list" ULIST
  plant "$R/$U/30/settings_secure.xml"; plant "$R/$U/30/settings_ssaid.xml"; plant "$R/$U/30/res_com.example.SENTINEL.xml"
  plant "$R/$U/30/inputmethod/subtypes.xml"; plant "$R/$U/30/.hidden"
  plant "$R/$U/31/settings_system.xml" U31; refuse "$R" "$R/$U/31"
  mkdir -p "$R/data/system/graphicsstats" "$R/data/system/dropbox"
  run_boot "$R"
  lg=$(grep '^\[roamd\] bootsweep result:' "$R/roam.log" 2>/dev/null); ldg=$(cat "$R/data/nowhere/reap-ledger" 2>/dev/null)
  chk new "R2a result: userdirs=1/LEFT:1" has "$lg" " userdirs=1/LEFT:1 "
  chk new "R2a the orphan's contents are gone, dotfiles and subdirectories too" empty "$R/$U/30"
  chk guard "R2a ... and its DIRECTORY is kept (a sign-in may just have been given that id)" isdir "$R/$U/30"
  chk new "R2a one ledger row for 30: cleared, census names the settings files" has "$ldg" "userdir ctx=boot uid=30 cleared files:inputmethod,settings_secure.xml,settings_ssaid.xml other=2"
  chk new "R2a one ledger row for 31: LEFT, with what remains" has "$ldg" "userdir ctx=boot uid=31 LEFT files:settings_system.xml other=0"
  chk guard "R2a the refused orphan's file is still there (nothing pretends otherwise)" eqv "$(cat "$R/$U/31/settings_system.xml" 2>/dev/null)" U31
  chk guard "R2a SENTINEL is never named (ledger + log)" hasnt "$ldg$(cat "$R/roam.log")" SENTINEL
  chk guard "R2a kept: user 0" eqv "$(cat "$R/$U/0/settings_secure.xml" 2>/dev/null)" U0
  chk guard "R2a kept: id 9 (below 10)" eqv "$(cat "$R/$U/9/settings_secure.xml" 2>/dev/null)" U9
  chk guard "R2a kept: 12, which has 12.xml" eqv "$(cat "$R/$U/12/settings_secure.xml" 2>/dev/null)" U12
  chk guard "R2a kept: 13, which has ONLY 13.xml.backup (a record rewrite in flight)" eqv "$(cat "$R/$U/13/settings_secure.xml" 2>/dev/null)" U13
  chk guard "R2a kept: 14, which has ONLY 14.xml.reservecopy" eqv "$(cat "$R/$U/14/settings_secure.xml" 2>/dev/null)" U14
  chk guard "R2a kept: the empty, system-owned 15 (a creation in progress looks like this)" isdir "$R/$U/15"
  chk guard "R2a kept: a non-numeric directory" eqv "$(cat "$R/$U/foo/settings_secure.xml" 2>/dev/null)" FOO
  chk guard "R2a kept: userlist.xml and user.list" eqv "$(cat "$R/$U/userlist.xml" "$R/$U/user.list" 2>/dev/null)" ULULIST
  chk new "R2a exactly two ledger rows, and they are 30 and 31 (this counter can see rows)" eqv "$(rows "$R/data/nowhere/reap-ledger" 'userdir ctx=boot uid=')$(rows "$R/data/nowhere/reap-ledger" 'userdir ctx=boot uid=\(30\|31\) ')" 22
  chk guard "R2a no ledger row for any kept id" eqv "$(rows "$R/data/nowhere/reap-ledger" 'userdir ctx=boot uid=\(0\|9\|12\|13\|14\|15\|foo\) ')" 0
  chk guard "R2a a system-owned directory is never chown'ed" eqv "$(cat "$R/sim/calls" 2>/dev/null | grep -c '^chown ' || true)" 0
  command rm -rf "$R"

  say ""
  say "== R2: a kept directory NOT owned by system (the old seedssaid's root mkdir) is handed back to system =="
  mkroot
  plant "$R/$U/32/nowhere-ssaid-seed"; printf '%s 0\n' "$R/$U/32" >> "$R/sim/owner"
  plant "$R/$U/33/nowhere-ssaid-seed"; printf '%s 0\n' "$R/$U/33" >> "$R/sim/owner"; printf '%s\n' "$R/$U/33" > "$R/sim/ownfail"
  plant "$R/$U/34/nowhere-ssaid-seed"; printf '%s 0\n' "$R/$U/34" >> "$R/sim/owner"; printf '%s\n' "$R/$U/34" > "$R/sim/chmodfail"
  plant "$R/$U/35/settings_ssaid.xml"; printf '%s 0\n' "$R/$U/35" >> "$R/sim/owner"; printf '%s\n' "$R/$U/35" > "$R/sim/rcfail"
  mkdir -p "$R/$U/16"; printf '%s 0\n' "$R/$U/16" >> "$R/sim/owner"
  mkdir -p "$R/$U/17"
  run_boot "$R"
  lg=$(grep '^\[roamd\] bootsweep result:' "$R/roam.log" 2>/dev/null); ldg=$(cat "$R/data/nowhere/reap-ledger" 2>/dev/null)
  t=$(cat "$R/sim/calls" 2>/dev/null)
  chk new "R2g result: 32 and 16 cleared; 33, 34 and 35 LEFT -> userdirs=2/LEFT:3" has "$lg" " userdirs=2/LEFT:3 "
  chk new "R2g 32 emptied, and chown system:system + chmod 0700 + restorecon, in that order" \
      eqv "$(printf '%s\n' "$t" | grep -F "$R/$U/32" | cut -d' ' -f1-2)" "$(printf 'chown system:system\nchmod 0700\nrestorecon %s' "$R/$U/32")"
  chk new "R2g 32's ledger row says the owner was restored" has "$ldg" "userdir ctx=boot uid=32 cleared files:nowhere-ssaid-seed other=0 owner:0->system"
  chk new "R2g 32's seed is gone and its directory kept" empty "$R/$U/32"
  chk new "R2g 33: chown refused -> LEFT, emptied, with the owner on the row" has "$ldg" "userdir ctx=boot uid=33 LEFT owner:0 emptied files:nowhere-ssaid-seed other=0"
  chk new "R2g 34: chmod refused -> LEFT, emptied, with the owner on the row" has "$ldg" "userdir ctx=boot uid=34 LEFT owner:0 emptied files:nowhere-ssaid-seed other=0"
  chk new "R2g 35: restorecon refused -> LEFT, emptied, with the owner on the row" has "$ldg" "userdir ctx=boot uid=35 LEFT owner:0 emptied files:settings_ssaid.xml other=0"
  chk new "R2g 34 and 35 failed at the step named: 34's chmod and 35's restorecon were reached, 34's chain stopped" \
      eqv "$(printf '%s\n' "$t" | grep -cxF "chmod 0700 $R/$U/34")$(printf '%s\n' "$t" | grep -cxF "restorecon $R/$U/35")$(printf '%s\n' "$t" | grep -cxF "restorecon $R/$U/34")" 110
  chk new "R2g an EMPTY 16 owned by root is not a creation in progress: handed back to system, counted" has "$ldg" "userdir ctx=boot uid=16 cleared files: other=0 owner:0->system"
  chk guard "R2g ... while the empty, system-owned 17 is left alone: no row, no chown" eqv "$(rows "$R/data/nowhere/reap-ledger" 'uid=17 ')$(printf '%s\n' "$t" | grep -c "$R/$U/17" || true)" 00
  command rm -rf "$R"

  mkroot
  : > "$R/$U/12.xml"; plant "$R/$U/12/settings_secure.xml"
  run_boot "$R"
  lg=$(grep '^\[roamd\] bootsweep result:' "$R/roam.log" 2>/dev/null)
  chk new "R2b nothing to do -> userdirs=0, reported anyway" has "$lg" " userdirs=0 "
  chk new "R2b userdirs= appears EXACTLY once on the result line" eqv "$(printf '%s\n' "$lg" | grep -o ' userdirs=' | grep -c .)" 1
  command rm -rf "$R"

  mkroot
  command rm -rf "$R/$U/0"; plant "$R/$U/30/settings_secure.xml" KEEP
  run_boot "$R"
  lg=$(grep '^\[roamd\] bootsweep result:' "$R/roam.log" 2>/dev/null)
  chk new "R2c no user-0 directory in the listing -> userdirs=UNREACHABLE, never 0" has "$lg" " userdirs=UNREACHABLE "
  chk guard "R2c ... and NOTHING is removed while blind" eqv "$(cat "$R/$U/30/settings_secure.xml" 2>/dev/null)" KEEP
  command rm -rf "$R"

  mkroot
  command rm -f "$R/$U/0.xml"; plant "$R/$U/30/settings_secure.xml" KEEP
  run_boot "$R"
  lg=$(grep '^\[roamd\] bootsweep result:' "$R/roam.log" 2>/dev/null)
  chk new "R2f user 0's record not visible (records cannot be seen) -> userdirs=UNREACHABLE" has "$lg" " userdirs=UNREACHABLE "
  chk guard "R2f ... and NOTHING is removed: a live user would look exactly like this orphan" eqv "$(cat "$R/$U/30/settings_secure.xml" 2>/dev/null)" KEEP
  command rm -rf "$R"

  mkroot
  plant "$R/$U/40/settings_secure.xml" KEEP; printf '%s\n' "$R/$U/40" > "$R/sim/lsfail"
  run_boot "$R"
  lg=$(grep '^\[roamd\] bootsweep result:' "$R/roam.log" 2>/dev/null)
  chk new "R2d a directory that cannot be listed is LEFT, not empty" has "$lg" " userdirs=0/LEFT:1 "
  chk new "R2d ... with a ledger row saying unreadable" has "$(cat "$R/data/nowhere/reap-ledger" 2>/dev/null)" "userdir ctx=boot uid=40 LEFT unreadable"
  chk guard "R2d ... and its file is untouched" eqv "$(cat "$R/$U/40/settings_secure.xml" 2>/dev/null)" KEEP
  command rm -rf "$R"

  mkroot
  plant "$R/$U/41/settings_secure.xml" LIVE; printf '%s %s\n' "$R/$U/41" "$R/$U/41.xml" > "$R/sim/lsrecord"
  run_boot "$R"
  lg=$(grep '^\[roamd\] bootsweep result:' "$R/roam.log" 2>/dev/null)
  chk new "R2e a record that lands during the sweep is honoured: userdirs=0" has "$lg" " userdirs=0 "
  chk guard "R2e ... and the new user's file is untouched" eqv "$(cat "$R/$U/41/settings_secure.xml" 2>/dev/null)" LIVE
  command rm -rf "$R"

  say ""
  say "== R2: a symbolic link is never followed -- a link at users/<n> is removed itself, its target untouched =="
  # 12: a root-owned link to a directory OUTSIDE users/, mode 755, holding a file -- followed, the sweep would
  # empty that directory and hand it to system 0700 (chmod follows a link; chown here is only recorded). 18: a
  # link whose user has a record. 19: a dangling link. 20: a link whose rm is refused. 36: a real orphan holding
  # a link INSIDE it, to another outside directory.
  mkroot
  mkdir -p "$R/out12"; plant "$R/out12/settings_secure.xml" TARGET; command chmod 755 "$R/out12"
  ln -s "$R/out12" "$R/$U/12"; printf '%s 0\n' "$R/$U/12" >> "$R/sim/owner"
  plant "$R/out18/f" T18; ln -s "$R/out18" "$R/$U/18"; : > "$R/$U/18.xml"
  ln -s "$R/no-such-target" "$R/$U/19"
  plant "$R/out20/f" T20; ln -s "$R/out20" "$R/$U/20"; refuse "$R" "$R/$U/20"
  plant "$R/$U/36/settings_secure.xml"; plant "$R/out36/keep" T36; ln -s "$R/out36" "$R/$U/36/inlink"
  run_boot "$R"
  lg=$(grep '^\[roamd\] bootsweep result:' "$R/roam.log" 2>/dev/null); ldg=$(cat "$R/data/nowhere/reap-ledger" 2>/dev/null)
  t=$(cat "$R/sim/calls" 2>/dev/null)
  chk new "R2h result: links 12 and 19 removed, 36 cleared, 20 LEFT -> userdirs=3/LEFT:1" has "$lg" " userdirs=3/LEFT:1 "
  chk guard "R2h the target of the link is untouched: its file is still there" eqv "$(cat "$R/out12/settings_secure.xml" 2>/dev/null)" TARGET
  chk guard "R2h ... its mode is still 755 (nothing chmod'ed through the link)" eqv "$(command stat -c %a "$R/out12" 2>/dev/null)" 755
  chk guard "R2h ... and no chown, chmod or restorecon names users/12" eqv "$(printf '%s\n' "$t" | grep -cF "$R/$U/12" || true)" 0
  chk new "R2h the link itself is gone: nothing is left at users/12" eqv "$([ -L "$R/$U/12" ] && echo L)$([ -e "$R/$U/12" ] && echo E)" ""
  chk new "R2h its ledger row says removed link, and names nothing" eqv "$(rows "$R/data/nowhere/reap-ledger" '^[0-9]* userdir ctx=boot uid=12 removed link$')" 1
  chk new "R2h a dangling link (19) is removed too, with its row" \
      eqv "$([ -L "$R/$U/19" ] && echo L)$(rows "$R/data/nowhere/reap-ledger" '^[0-9]* userdir ctx=boot uid=19 removed link$')" 1
  chk guard "R2h a link whose user has a record (18) is kept, with its target, and gets no row" \
      eqv "$([ -L "$R/$U/18" ] && echo L)$(cat "$R/out18/f" 2>/dev/null)$(rows "$R/data/nowhere/reap-ledger" 'uid=18 ')" LT180
  chk new "R2h a link rm cannot remove (20) is LEFT, never reported removed" \
      eqv "$(rows "$R/data/nowhere/reap-ledger" '^[0-9]* userdir ctx=boot uid=20 LEFT link$')$(rows "$R/data/nowhere/reap-ledger" 'uid=20 removed')" 10
  chk guard "R2h ... and its target is untouched" eqv "$(cat "$R/out20/f" 2>/dev/null)" T20
  chk guard "R2i a link INSIDE a real orphan never takes what it points at" eqv "$(cat "$R/out36/keep" 2>/dev/null)" T36
  chk new "R2i ... the orphan is emptied, the link included" empty "$R/$U/36"
  chk new "R2i ... and its row counts the link without naming it" has "$ldg" "userdir ctx=boot uid=36 cleared files:settings_secure.xml other=1"
  command rm -rf "$R"

  say ""
  say "== R3, seedssaid: never creates users/<uid>, and stages only for a user that exists =="
  mkroot
  : > "$R/$U/11.xml"
  run_seed "$R" 11
  chk new "R3a record but no directory -> ERR-NOUSER" eqv "$(cat "$R/res" 2>/dev/null)" ERR-NOUSER
  chk new "R3a ... and the directory is NOT created" absent "$R/$U/11"
  chk new "R3a the log line carries the uid and flags only" has "$(cat "$R/roam.log" 2>/dev/null)" "seedssaid user 11 has no system dir or no record (dir=0 record=1)"
  command rm -rf "$R"
  mkroot
  run_seed "$R" 11
  chk new "R3b neither -> ERR-NOUSER, nothing created" eqv "$(cat "$R/res" 2>/dev/null)$([ -e "$R/$U/11" ] && echo +dir)" ERR-NOUSER
  command rm -rf "$R"
  mkroot
  mkdir -p "$R/$U/11"
  run_seed "$R" 11
  chk new "R3c a directory with no record (an orphan) -> ERR-NOUSER" eqv "$(cat "$R/res" 2>/dev/null)" ERR-NOUSER
  chk new "R3c ... and no seed is staged into it" absent "$R/$U/11/nowhere-ssaid-seed"
  command rm -rf "$R"
  mkroot
  : > "$R/$U/11.xml"; mkdir -p "$R/$U/11"
  run_seed "$R" 11
  chk guard "R3d a real user (directory + record) -> OK" eqv "$(cat "$R/res" 2>/dev/null)" OK
  chk guard "R3d ... and the seed is the 64 hex chars, byte-exact" eqv "$(cat "$R/$U/11/nowhere-ssaid-seed" 2>/dev/null)" "$KEY64"
  command rm -rf "$R"
  # Positive control: when user 0's record cannot be seen either, "no record" means "cannot look", not "gone".
  mkroot
  command rm -f "$R/$U/0.xml"; mkdir -p "$R/$U/11"
  run_seed "$R" 11
  chk guard "R3e records blind, directory present -> staged anyway: OK" eqv "$(cat "$R/res" 2>/dev/null)" OK
  chk guard "R3e ... the seed byte-exact" eqv "$(cat "$R/$U/11/nowhere-ssaid-seed" 2>/dev/null)" "$KEY64"
  chk new "R3e ... and the log says record=blind" has "$(cat "$R/roam.log" 2>/dev/null)" "seedssaid user 11: records cannot be seen (record=blind) -- staging into the existing dir"
  command rm -rf "$R"
  mkroot
  command rm -f "$R/$U/0.xml"
  run_seed "$R" 11
  chk new "R3f records blind and NO directory -> ERR-NOUSER: blind never creates it" eqv "$(cat "$R/res" 2>/dev/null)$([ -e "$R/$U/11" ] && echo +dir)" ERR-NOUSER
  chk new "R3f ... and the log line says so" has "$(cat "$R/roam.log" 2>/dev/null)" "(dir=0 record=blind)"
  command rm -rf "$R"
  # NWP-20261011-42: a symbolic link at users/11, for a user that HAS a record. -d follows a link, so the old arm
  # took it for the directory: it removed the target's settings_ssaid.xml as "stale" and wrote the seed -- a
  # passphrase verifier -- into the target.
  mkroot
  : > "$R/$U/11.xml"; plant "$R/out11/settings_ssaid.xml" TARGET; ln -s "$R/out11" "$R/$U/11"
  run_seed "$R" 11
  lg=$(cat "$R/roam.log" 2>/dev/null)
  chk new "R3g a link at users/11 with a record -> ERR-NOUSER" eqv "$(cat "$R/res" 2>/dev/null)" ERR-NOUSER
  chk new "R3g ... no seed is written through it into the target" absent "$R/out11/nowhere-ssaid-seed"
  chk new "R3g ... and the target's settings_ssaid.xml is untouched" eqv "$(cat "$R/out11/settings_ssaid.xml" 2>/dev/null)" TARGET
  chk new "R3g the log line says (link)" has "$lg" "seedssaid user 11 has no system dir or no record (dir=0 record=1) (link) -- NOT staging"
  chk guard "R3g ... and never where it points" hasnt "$lg" "$R/out11"
  chk guard "R3g the link itself is left alone" eqv "$([ -L "$R/$U/11" ] && echo L)" L
  command rm -rf "$R"
  # Records blind, the link present: blind stages only into a directory that exists, and a link is not one.
  mkroot
  command rm -f "$R/$U/0.xml"; mkdir -p "$R/out11"; ln -s "$R/out11" "$R/$U/11"
  run_seed "$R" 11
  chk new "R3h records blind and a link at users/11 -> ERR-NOUSER, nothing in the target" \
      eqv "$(cat "$R/res" 2>/dev/null)$(absent "$R/out11/nowhere-ssaid-seed" || echo +seed)" ERR-NOUSER
  command rm -rf "$R"

  say ""
  say "== IN, the roam-in that does not land takes its SSAID seed (a passphrase verifier) with it =="
  # SEED-SSAID ran before the roam-in, so a real attempt has users/11 with its record, the seed, and whatever
  # else the framework wrote. Only the seed and settings_ssaid.xml may go.
  for t in blank needkey; do
    mkroot
    : > "$R/$U/11.xml"; plant "$R/$U/11/nowhere-ssaid-seed" "$KEY64"; plant "$R/$U/11/settings_secure.xml" KEEP
    run_in "$R" 11 "$t"
    lg=$(cat "$R/roam.log" 2>/dev/null)
    case "$t" in blank) v=BLANK; n=INa ;; *) v=NEEDKEY; n=INb ;; esac
    chk guard "$n control: the arm answered $v" eqv "$(cat "$R/res" 2>/dev/null)" "$v"
    chk new "$n $v -> the seed is gone" absent "$R/$U/11/nowhere-ssaid-seed"
    chk guard "$n ... and ONLY the seed: users/11 and its other file are untouched" eqv "$(cat "$R/$U/11/settings_secure.xml" 2>/dev/null)" KEEP
    chk new "$n ... and the log says so, with the uid only" has "$lg" "[roamd] roam-in for user 11 did not land -- its SSAID seed removed (NWP-20261003-01)"
    command rm -rf "$R"
  done
  # The seed may already be CONSUMED: SEED-SSAID runs before the user is started and the restore can take
  # minutes, so an app may have asked for its ANDROID_ID meanwhile. The patched SettingsProvider then deleted the
  # seed and wrote the same 64 hex as the userkey in settings_ssaid.xml -- the verifier, under another name.
  for t in blank needkey; do
    mkroot
    : > "$R/$U/11.xml"; plant "$R/$U/11/settings_ssaid.xml" "<userkey $KEY64>"; plant "$R/$U/11/settings_secure.xml" KEEP
    run_in "$R" 11 "$t"
    lg=$(cat "$R/roam.log" 2>/dev/null)
    case "$t" in blank) v=BLANK; n=INf ;; *) v=NEEDKEY; n=INg ;; esac
    chk guard "$n control: the arm answered $v" eqv "$(cat "$R/res" 2>/dev/null)" "$v"
    chk new "$n $v after the seed was consumed -> settings_ssaid.xml, which holds it, is gone" absent "$R/$U/11/settings_ssaid.xml"
    chk guard "$n ... and ONLY that file: users/11 and its other file are untouched" eqv "$(cat "$R/$U/11/settings_secure.xml" 2>/dev/null)" KEEP
    chk new "$n ... and the log says so, with the uid and the allowlisted name only" has "$lg" "[roamd] roam-in for user 11 did not land -- its settings_ssaid.xml removed (NWP-20261003-01)"
    command rm -rf "$R"
  done
  mkroot
  : > "$R/$U/11.xml"; plant "$R/$U/11/nowhere-ssaid-seed" "$KEY64"; plant "$R/$U/11/settings_ssaid.xml" LIVE
  run_in "$R" 11 ok
  chk guard "INc control: the arm answered OK 11" eqv "$(cat "$R/res" 2>/dev/null)" "OK 11"
  chk guard "INc a sign-in that landed keeps its seed, byte-exact (the framework reads it later)" eqv "$(cat "$R/$U/11/nowhere-ssaid-seed" 2>/dev/null)" "$KEY64"
  chk guard "INc ... and its settings_ssaid.xml, which is the session's own" eqv "$(cat "$R/$U/11/settings_ssaid.xml" 2>/dev/null)" LIVE
  chk guard "INc ... and logs no line about either" hasnt "$(cat "$R/roam.log" 2>/dev/null)" "roam-in for user"
  command rm -rf "$R"
  mkroot
  run_in "$R" 11 blank
  chk guard "INd no users/11 at all -> nothing is created" absent "$R/$U/11"
  chk guard "INd ... and no line is logged" hasnt "$(cat "$R/roam.log" 2>/dev/null)" "roam-in for user"
  command rm -rf "$R"
  mkroot
  : > "$R/$U/11.xml"; plant "$R/$U/11/nowhere-ssaid-seed" "$KEY64"; refuse "$R" "$R/$U/11/nowhere-ssaid-seed"
  plant "$R/$U/11/settings_ssaid.xml"; refuse "$R" "$R/$U/11/settings_ssaid.xml"
  run_in "$R" 11 blank
  lg=$(cat "$R/roam.log" 2>/dev/null)
  chk new "INe an rm that cannot remove the seed says so -- it never claims a removal" has "$lg" "roam-in for user 11 did not land -- its SSAID seed could NOT be removed"
  chk new "INe ... nor for settings_ssaid.xml" has "$lg" "roam-in for user 11 did not land -- its settings_ssaid.xml could NOT be removed"
  chk guard "INe ... and no removal is claimed for either" eqv "$(printf '%s\n' "$lg" | grep -cE 'its (SSAID seed|settings_ssaid\.xml) removed' || true)" 0
  command rm -rf "$R"

  say ""
  say "== IN: the verdict is roamd's own, never a re-read of \$RES, which the agent may already have taken =="
  # The agent removes $RES on its first non-empty read, and roamd's next line can run after that. A clean-up
  # that read its verdict back from $RES would find it gone and take a landed sign-in for one that did not
  # land: the unconsumed seed goes (SettingsProvider then mints a random userkey, and every ANDROID_ID rotates),
  # with the live session's settings_ssaid.xml.
  mkroot
  : > "$R/$U/11.xml"; plant "$R/$U/11/nowhere-ssaid-seed" "$KEY64"; plant "$R/$U/11/settings_ssaid.xml" LIVE
  run_in "$R" 11 ok consume
  chk guard "INh control: the agent took the reply 'OK 11' and deleted it before roamd's next line" \
      eqv "$(cat "$R/sim/consumed" 2>/dev/null)$([ -e "$R/res" ] && echo +res)" "OK 11"
  chk guard "INh a sign-in that landed keeps its seed, byte-exact, although its reply was already taken" \
      eqv "$(cat "$R/$U/11/nowhere-ssaid-seed" 2>/dev/null)" "$KEY64"
  chk guard "INh ... and its settings_ssaid.xml, which is the session's own" eqv "$(cat "$R/$U/11/settings_ssaid.xml" 2>/dev/null)" LIVE
  chk guard "INh ... and logs no line about either" hasnt "$(cat "$R/roam.log" 2>/dev/null)" "did not land"
  command rm -rf "$R"
  for t in blank needkey; do
    mkroot
    : > "$R/$U/11.xml"; plant "$R/$U/11/nowhere-ssaid-seed" "$KEY64"; plant "$R/$U/11/settings_ssaid.xml" "<userkey $KEY64>"
    plant "$R/$U/11/settings_secure.xml" KEEP
    run_in "$R" 11 "$t" consume
    lg=$(cat "$R/roam.log" 2>/dev/null)
    case "$t" in blank) v=BLANK; n=INi ;; *) v=NEEDKEY; n=INj ;; esac
    chk guard "$n control: the agent took the reply $v and deleted it before roamd's next line" \
        eqv "$(cat "$R/sim/consumed" 2>/dev/null)$([ -e "$R/res" ] && echo +res)" "$v"
    chk new "$n $v with the reply already taken -> the seed and settings_ssaid.xml are both gone" \
        eqv "$(absent "$R/$U/11/nowhere-ssaid-seed" && echo S)$(absent "$R/$U/11/settings_ssaid.xml" && echo X)" SX
    chk guard "$n ... and ONLY those: users/11 and its other file are untouched" eqv "$(cat "$R/$U/11/settings_secure.xml" 2>/dev/null)" KEEP
    chk new "$n ... and the log says both went" \
        eqv "$(printf '%s\n' "$lg" | grep -cE 'roam-in for user 11 did not land -- its (SSAID seed|settings_ssaid\.xml) removed' || true)" 2
    command rm -rf "$R"
  done

  say ""
  say "== R5, the re-check (NWP-20261104-14, Q037): a timeout or blind reap's users/<uid> is looked at again =="
  local sh exp rel ctl1 ctl2 ro1 t0 QL RL
  mkroot
  : > "$R/$U/11.xml"; plant "$R/$U/11/settings_secure.xml" LIVE
  run_clean "$R" 11
  chk new "R5a a reap whose record never goes (anchor:timeout) queues its uid" eqv "$(pendof "$R")" 11
  chk guard "R5a ... and keeps the directory, as before" eqv "$(cat "$R/$U/11/settings_secure.xml" 2>/dev/null)" LIVE
  run_clean "$R" 11
  chk new "R5a a second reap of the same uid does not list it twice" eqv "$(pendof "$R")" 11
  command rm -rf "$R"
  mkroot
  nouser0 "$R"; plant "$R/$U/11/settings_secure.xml" KEEP
  run_clean "$R" 11
  chk new "R5b a blind reap (anchor:blind) queues its uid too" eqv "$(pendof "$R")" 11
  command rm -rf "$R"
  mkroot
  run_clean "$R" 11
  chk guard "R5b a reap that ends anchor:ok queues nothing" absent "$R/state/userdir-pending"
  command rm -rf "$R"

  # cleanstorage's two re-check lines, so R5a, R5b and R5j also run under every shell, not only through run_clean
  # (bash). They are taken by POSITION, as PRE is, never by their own text: a text match turns any edit to the line
  # into an empty one, and the shells then run nothing. The queue line is the one right after `_udf=`, the re-check
  # call the one right after the uid<10 REJECT line, and P6 pins both positions. A line there that does not call
  # the function runs as `:`, so a removed or moved line runs as nothing, and an edited one runs as edited.
  QL=$(printf '%s\n' "$CLEAN" | awk 'f {print; exit} /^  _udf=/ {f=1}')
  case "$QL" in *userdir_pending_add*) ;; *) QL=: ;; esac
  RL=$(printf '%s\n' "$CLEAN" | awk 'f {print; exit} /^  if \[ "\$uid" -lt 10 \]; then echo "\[roamd\] cleanstorage REJECT/ {f=1}')
  case "$RL" in *userdir_recheck*) ;; *) RL=: ;; esac
  for sh in $R5SHELLS; do
    command -v "$sh" >/dev/null 2>&1 || continue
    say "-- R5 re-check cases under $sh"
    # R5a/R5b: cleanstorage's queue line queues a timeout or blind reap's uid, once; an anchor:ok one queues nothing
    mkroot
    run_recheck "$R" 11 rw "$sh" "_ud_anchor=timeout; $QL"
    chk new "R5a $sh: cleanstorage's queue line queues a timeout reap's uid" eqv "$(pendof "$R")" 11
    run_recheck "$R" 11 rw "$sh" "_ud_anchor=timeout; $QL"
    chk new "R5a $sh: ... and a second timeout reap of it does not list it twice" eqv "$(pendof "$R")" 11
    command rm -rf "$R"
    mkroot
    run_recheck "$R" 11 rw "$sh" "_ud_anchor=blind; $QL"
    chk new "R5b $sh: ... a blind reap's uid too" eqv "$(pendof "$R")" 11
    command rm -rf "$R"
    mkroot
    run_recheck "$R" 11 rw "$sh" "_ud_anchor=ok; $QL"
    chk guard "R5b $sh: ... an anchor:ok reap queues nothing" absent "$R/state/userdir-pending"
    command rm -rf "$R"
    # R5j: cleanstorage's own re-check line removes an earlier uid's users/12 and skips the uid being reaped
    mkroot
    plant "$R/$U/12/settings_ssaid.xml" OLD; plant "$R/$U/11/settings_secure.xml" LIVE
    printf '%s\n' 12 11 > "$R/state/userdir-pending"
    run_recheck "$R" 11 rw "$sh" "$RL"
    chk new "R5j $sh: cleanstorage's re-check line removes an earlier uid's users/12" absent "$R/$U/12"
    chk guard "R5j $sh: ... and leaves the uid being reaped (11) to its own reap" eqv "$(cat "$R/$U/11/settings_secure.xml" 2>/dev/null)" LIVE
    command rm -rf "$R"
    # R5c: record gone, user 0 visible -> removed, line dropped, one class=recheck row
    mkroot
    plant "$R/$U/11/settings_secure.xml"; plant "$R/$U/11/settings_ssaid.xml"; plant "$R/$U/11/res_com.example.x.xml"
    pend "$R" 11
    exp=$( ROOT="$R"; eval "$RF"; userdir_census "$R/$U/11" )
    run_recheck "$R" "" rw "$sh"
    ldg=$(ledof "$R"); lg=$(cat "$R/roam.log" 2>/dev/null)
    chk new "R5c $sh: the record is gone and user 0 is visible -> users/11 is removed" absent "$R/$U/11"
    chk new "R5c $sh: ... the line is dropped (an empty list is no file)" absent "$R/state/userdir-pending"
    chk new "R5c $sh: ... one class=recheck ledger row" eqv "$(rows "$R/data/nowhere/reap-ledger" 'class=recheck')" 1
    chk new "R5c $sh: ... its census is userdir_census of the removed tree" has "$ldg" "uid=11 class=recheck userdir=recheck:ok census:$exp"
    chk guard "R5c $sh: ... (control: that census names the two writers' files and counts the package one)" eqv "$exp" "files:settings_secure.xml,settings_ssaid.xml other=1"
    chk new "R5c $sh: ... one roam.log line, naming no package" has "$lg" "userdir recheck user 11 removed census:$exp"
    chk guard "R5c $sh: ... the package is in neither the ledger nor the log" hasnt "$ldg$lg" com.example
    command rm -rf "$R"
    # R5d: a record still present (any of the three files) -> kept
    for rel in "" .backup .reservecopy; do
      mkroot
      : > "$R/$U/11.xml$rel"; plant "$R/$U/11/settings_ssaid.xml" LIVE
      pend "$R" 11
      run_recheck "$R" "" rw "$sh"
      chk guard "R5d $sh: 11.xml$rel still there -> users/11 is kept" eqv "$(cat "$R/$U/11/settings_ssaid.xml" 2>/dev/null)" LIVE
      chk guard "R5d $sh: 11.xml$rel ... and the line is kept, with no ledger row" eqv "$(pendof "$R")|$(ledof "$R")" "11|"
      command rm -rf "$R"
    done
    # R5e: user 0 invisible -> nothing removed, list kept
    mkroot
    nouser0 "$R"; plant "$R/$U/11/settings_ssaid.xml" KEEP
    pend "$R" 11
    run_recheck "$R" "" rw "$sh"
    chk guard "R5e $sh: user 0's record cannot be seen -> nothing is removed" eqv "$(cat "$R/$U/11/settings_ssaid.xml" 2>/dev/null)" KEEP
    chk guard "R5e $sh: ... the list is kept and no row is written" eqv "$(pendof "$R")|$(ledof "$R")" "11|"
    command rm -rf "$R"
    # R5f: the op's own uid is skipped
    mkroot
    plant "$R/$U/11/settings_ssaid.xml" KEEP
    pend "$R" 11
    run_recheck "$R" 11 rw "$sh"
    chk guard "R5f $sh: the op's own uid is skipped -> users/11 is kept" eqv "$(cat "$R/$U/11/settings_ssaid.xml" 2>/dev/null)" KEEP
    chk guard "R5f $sh: ... and its line is kept" eqv "$(pendof "$R")" 11
    command rm -rf "$R"
    # R5n: a skipped `<uid> left` line keeps its mark, both for a uid on record (11) and the op's own uid (12), or
    # the next refused rm of it writes a second left row. [guard]: the old code, with no re-check, keeps every line.
    mkroot
    : > "$R/$U/11.xml"; plant "$R/$U/11/settings_ssaid.xml" LIVE; plant "$R/$U/12/settings_ssaid.xml" KEEP
    printf '%s\n' '11 left' '12 left' > "$R/state/userdir-pending"
    run_recheck "$R" 12 rw "$sh"
    chk guard "R5n $sh: a left uid on record, and the op's own left uid, keep their left mark" \
        eqv "$(pendof "$R" | tr '\n' '|')" "11 left|12 left|"
    chk guard "R5n $sh: ... both directories are kept and no ledger row is written" \
        eqv "$(cat "$R/$U/11/settings_ssaid.xml" 2>/dev/null)|$(cat "$R/$U/12/settings_ssaid.xml" 2>/dev/null)|$(ledof "$R")" "LIVE|KEEP|"
    command rm -rf "$R"
    # R5g: an rm the stub refuses -> the line is kept and the row says left
    mkroot
    plant "$R/$U/11/settings_ssaid.xml" KEEP
    refuse "$R" "$R/$U/11"; pend "$R" 11
    run_recheck "$R" "" rw "$sh"
    ldg=$(ledof "$R"); lg=$(cat "$R/roam.log" 2>/dev/null)
    chk guard "R5g $sh: a refused rm leaves the directory" eqv "$(cat "$R/$U/11/settings_ssaid.xml" 2>/dev/null)" KEEP
    chk new "R5g $sh: ... the line is kept for the next op, marked left" eqv "$(pendof "$R")" "11 left"
    chk new "R5g $sh: ... the row says left" has "$ldg" "uid=11 class=recheck userdir=recheck:ok,left census:files:settings_ssaid.xml other=0"
    chk new "R5g $sh: ... the log line says LEFT" has "$lg" "userdir recheck user 11 LEFT "
    chk guard "R5g $sh: ... rm's own error text (a file name) is in neither" hasnt "$ldg$lg" 'Permission denied'
    command rm -rf "$R"
    # R5g2: a refused rm writes its left row once, not at every op; once the rm can clear it, one recheck:ok row
    mkroot
    plant "$R/$U/11/settings_ssaid.xml" KEEP
    refuse "$R" "$R/$U/11"; pend "$R" 11
    run_recheck "$R" "" rw "$sh"; run_recheck "$R" "" rw "$sh"
    run_recheck "$R" "" rw "$sh" 'userdir_pending_add 11'
    chk new "R5g2 $sh: two re-checks with the rm still refused -> exactly one class=recheck row and one LEFT log line" \
        eqv "$(rows "$R/data/nowhere/reap-ledger" 'class=recheck')|$(rows "$R/roam.log" 'userdir recheck user 11 LEFT ')" "1|1"
    chk new "R5g2 $sh: ... and one line, still marked left (a later reap's queue call adds no second one)" eqv "$(pendof "$R")" "11 left"
    command rm -f "$R/sim/refuse"
    run_recheck "$R" "" rw "$sh"
    chk new "R5g2 $sh: the refusal lifted -> users/11 is removed" absent "$R/$U/11"
    chk new "R5g2 $sh: ... with one recheck:ok row (no left), the second row for that uid" \
        eqv "$(rows "$R/data/nowhere/reap-ledger" 'uid=11 class=recheck userdir=recheck:ok census:files:settings_ssaid.xml other=0')|$(rows "$R/data/nowhere/reap-ledger" 'class=recheck')" "1|2"
    chk new "R5g2 $sh: ... and the line is dropped" absent "$R/state/userdir-pending"
    command rm -rf "$R"
    # R5o: the queue's uid match is anchored at both ends, so a listed uid that starts with 11 (110) or ends with it
    # (111, marked left) does not stop 11 being queued. Uids pass 100 in one long boot: every sign-in mints a user.
    mkroot
    printf '%s\n' 110 '111 left' > "$R/state/userdir-pending"
    run_recheck "$R" "" rw "$sh" 'userdir_pending_add 11'
    chk new "R5o $sh: 110 and '111 left' listed -> 11 is still queued" eqv "$(pendof "$R" | tr '\n' '|')" "110|111 left|11|"
    command rm -rf "$R"
    # R5h: a symbolic link at users/11 is never followed
    mkroot
    plant "$R/target/secret.xml" T; command chmod 755 "$R/target"
    ln -s "$R/target" "$R/$U/11"; pend "$R" 11
    run_recheck "$R" "" rw "$sh"
    ldg=$(ledof "$R")
    chk new "R5h $sh: a link at users/11 is removed itself" absent "$R/$U/11"
    chk guard "R5h $sh: ... its target and the target's file are untouched" eqv "$(cat "$R/target/secret.xml" 2>/dev/null)$(command stat -c %a "$R/target")" T755
    chk new "R5h $sh: ... the row says link, with an empty census (no target names)" has "$ldg" "uid=11 class=recheck userdir=recheck:ok,link census:files: other=0"
    chk new "R5h $sh: ... the line is dropped" absent "$R/state/userdir-pending"
    command rm -rf "$R"
    # R5i: no pending file -> no change at all
    mkroot
    plant "$R/$U/11/settings_ssaid.xml" KEEP
    run_recheck "$R" "" rw "$sh"
    chk guard "R5i $sh: no pending file -> users/11 (no record) is not touched" eqv "$(cat "$R/$U/11/settings_ssaid.xml" 2>/dev/null)" KEEP
    chk guard "R5i $sh: ... no ledger row, no pending file created" eqv "$(ledof "$R")|$(command ls "$R/state" | tr '\n' ' ')" "|"
    command rm -rf "$R"
    # R5k: only the read-write lane re-checks
    for t0 in ro cred rw; do
      mkroot
      plant "$R/$U/11/settings_ssaid.xml" KEEP; pend "$R" 11
      run_recheck "$R" "" "$t0" "$sh"
      if [ "$t0" = rw ]; then
        chk new "R5k $sh: lane rw -> the line before case \"\$op\" re-checks (users/11 removed)" absent "$R/$U/11"
      else
        chk guard "R5k $sh: lane $t0 -> nothing is removed" eqv "$(cat "$R/$U/11/settings_ssaid.xml" 2>/dev/null)|$(pendof "$R")" "KEEP|11"
      fi
      command rm -rf "$R"
    done
    # R5l: a line that is not a plain uid >= 10 is dropped and never acted on
    mkroot
    plant "$R/$U/5/settings_ssaid.xml" KEEP; plant "$R/$U/11/settings_ssaid.xml" KEEP
    printf '%s\n' '../0' 5 '' 11 > "$R/state/userdir-pending"
    run_recheck "$R" "" rw "$sh"
    chk new "R5l $sh: users/5 (a uid below 10) is untouched; users/11 is removed" eqv "$(cat "$R/$U/5/settings_ssaid.xml" 2>/dev/null)|$(absent "$R/$U/11" && echo gone)" "KEEP|gone"
    chk new "R5l $sh: ... the junk lines are not kept" absent "$R/state/userdir-pending"
    command rm -rf "$R"
  done

  # R5j: the re-check at the start of cleanstorage leaves that reap's own anchor, polls and ledger row unchanged
  mkroot
  : > "$R/$U/11.xml"; plant "$R/$U/11/settings_secure.xml" LIVE
  run_clean "$R" 11
  ctl1=$(ledof "$R" | sed "s/^[0-9]* //; s#$R#ROOT#g"); ctl2=$(cat "$R/sim/ticks")
  ro1=$(cline "$R" | sed 's/ userdir=\([^ ]*\) .*/ userdir=\1/')
  command rm -rf "$R"
  mkroot
  : > "$R/$U/11.xml"; plant "$R/$U/11/settings_secure.xml" LIVE
  plant "$R/$U/12/settings_ssaid.xml" OLD; pend "$R" 12
  run_clean "$R" 11
  ldg=$(ledof "$R")
  chk new "R5j cleanstorage re-checks an earlier uid first: users/12 is removed" absent "$R/$U/12"
  chk new "R5j ... with its own class=recheck row" has "$ldg" "uid=12 class=recheck userdir=recheck:ok census:files:settings_ssaid.xml other=0"
  chk guard "R5j ... this reap's own ledger row is byte-identical to the one it writes with no pending file" \
      eqv "$(printf '%s\n' "$ldg" | grep ' uid=11 ' | sed "s/^[0-9]* //; s#$R#ROOT#g")" "$ctl1"
  chk guard "R5j ... as are its reap line (anchor, polls) and its poll count" \
      eqv "$(cline "$R" | sed 's/ userdir=\([^ ]*\) .*/ userdir=\1/')|$(cat "$R/sim/ticks")" "$ro1|$ctl2"
  chk new "R5j ... and only its own uid is left queued" eqv "$(pendof "$R")" 11
  command rm -rf "$R"

  say ""
  say "== static pins =="
  local ln_op ln_bt ln_set ln_loop
  chk new "P1 nothing in roamd creates users/<n> (no mkdir -p of a users/ path)" eqv "$(grep -c 'mkdir -p "/data/system/users/' "$f")" 0
  chk new "P2 the cleanstorage op itself never rm's users/\$uid (only the anchored take does)" \
      eqv "$(printf '%s\n' "$CLEAN" | grep -v '^[[:space:]]*#' | grep -c 'rm .*"/data/system/users/\$uid"')$(printf '%s\n' "$CLEAN" | grep -c '^  reap_userdir_settle "\$uid"$')" 01
  ln_bt=$(printf '%s\n' "$CLEAN" | grep -n '^  if bt_reset ""; then' | head -1 | cut -d: -f1)
  ln_set=$(printf '%s\n' "$CLEAN" | grep -n '^  reap_userdir_settle "\$uid"$' | head -1 | cut -d: -f1)
  ln_loop=$(printf '%s\n' "$CLEAN" | grep -n '^  _reapleft=""; _reapi=0' | head -1 | cut -d: -f1)
  chk new "P3 the settle runs after bt_reset and before the survivor loop" test "${ln_bt:-0}" -gt 0 -a "${ln_set:-0}" -gt "${ln_bt:-0}" -a "${ln_loop:-0}" -gt "${ln_set:-0}"
  ln_op=$(grep -n '^if \[ "\$op" = "cleanstorage" \]; then$' "$f" | cut -d: -f1)
  n=0
  for fn in userdir_has_record userdir_census userdir_census_fold reap_userdir_settle reap_userdir_take userdir_pending_add userdir_recheck; do
    t=$(grep -n "^$fn() {\$" "$f" | head -1 | cut -d: -f1)
    [ -n "$t" ] && [ "$t" -lt "${ln_op:-0}" ] && n=$((n + 1))
  done
  chk new "P4 all seven functions are defined ABOVE the cleanstorage dispatch (the forward-reference trap)" eqv "$n" 7
  chk new "P5 the line right before the top-level case \"\$op\" is exactly the lane-guarded call" \
      eqv "$(awk 'prev != "" && $0 == "case \"$op\" in" {print prev; exit} {prev=$0}' "$f")" '[ "$LANE" = rw ] && userdir_recheck'
  chk guard "P5 control: exactly one top-level case \"\$op\" in, with the sealdelta arm (a read-only op) below it" \
      eqv "$(grep -c '^case "\$op" in$' "$f")|$(grep -c '^  sealdelta)$' "$f")" "1|1"
  ln_op=$(printf '%s\n' "$CLEAN" | grep -n '^  if \[ "\$uid" -lt 10 \]; then echo "\[roamd\] cleanstorage REJECT' | head -1 | cut -d: -f1)
  ln_set=$(printf '%s\n' "$CLEAN" | grep -n '^  userdir_recheck   #' | head -1 | cut -d: -f1)
  ln_bt=$(printf '%s\n' "$CLEAN" | grep -n '^  reap_userdir_settle "\$uid"$' | head -1 | cut -d: -f1)
  chk new "P6 cleanstorage calls userdir_recheck once, on the line right after the uid checks, before its own settle" \
      test "$(printf '%s\n' "$CLEAN" | grep -c '^  userdir_recheck')" = 1 -a "${ln_op:-0}" -gt 0 -a "${ln_set:-0}" -eq "$((${ln_op:-0} + 1))" -a "${ln_bt:-0}" -gt "${ln_set:-0}"
  ln_loop=$(printf '%s\n' "$CLEAN" | grep -n '^  _udf=' | head -1 | cut -d: -f1)
  ln_set=$(printf '%s\n' "$CLEAN" | grep -n '^  case "\$_ud_anchor" in timeout|blind) userdir_pending_add "\$uid" ;; esac' | head -1 | cut -d: -f1)
  chk new "P6 ... and queues a timeout or blind reap's uid right after building _udf" test "${ln_loop:-0}" -gt 0 -a "${ln_set:-0}" -eq "$((${ln_loop:-0} + 1))"
  chk guard "H no run hit an undefined command, an unbound variable or a parse error${HARN:+ -- got:$HARN}" eqv "$HARN" ""

  [ -n "$quiet" ] || printf '  -- %d ok, %d failed\n' "$p" "$x"
  [ "$x" -eq 0 ] && return 0 || return 1
}

if [ "$BASE" = yes ]; then echo "users/<n> backstops, BASELINE (old code -- [new] must fail, [guard] must hold): $SUT"
else echo "users/<n> backstops: $SUT"; fi
suite "$SUT"; rc=$?
[ "$rc" = 0 ] || FAILED=1

if [ "$MUTATE" = yes ] && [ "$BASE" = no ]; then
  echo
  echo "mutations (each must CONVICT through the assertion it names) and probes (each must SURVIVE):"
  mtmp=$(mktemp -d -p "$W"); MN=0
  # judge <label> <mutant> <survive | [!]ERE...>: one verdict line. A conviction is rc 1 -- an assertion that ran
  # and failed -- AND, for every ERE given, a FAIL line that matches it: a mutant convicted only by some unrelated
  # assertion has not shown that the behaviour it breaks is guarded. An ERE written `!<ERE>` is the reverse: NO
  # FAIL line may match it. It names cases a behaviour-neutral edit must leave passing; one that fails anyway
  # pins the line's text, not its behaviour. rc 2 is the harness refusing to run, NOT a verdict: counting it as a
  # conviction is how a suite praises itself for never having executed.
  judge() {
    local label="$1" mf="$2" out r e miss="" also=""; shift 2
    out=$(suite "$mf" 2>&1); r=$?
    if [ "${1:-}" = survive ]; then
      case "$r" in
        0) printf '  ok    %-84s survived, as it must\n' "$label" ;;
        1) printf '  XX    %-84s WRONGLY CONVICTED -- the suite pins prose\n' "$label" ;;
        *) printf '  ERR   %-84s harness error (rc=%s), not a verdict\n' "$label" "$r" ;;
      esac
      return
    fi
    case "$r" in
      0) printf '  XX    %-84s SURVIVED\n' "$label"; return ;;
      1) ;;
      *) printf '  ERR   %-84s harness error (rc=%s), not a verdict\n' "$label" "$r"; return ;;
    esac
    # A here-string, NEVER `printf ... | grep -q`: under pipefail, grep -q exits at its first match, printf's
    # next write hits the closed pipe, and the pipeline fails -- a match reported as a miss. Measured: 30 false
    # misses in 2000 runs on a suite-sized text, 200 in 200 once it outgrows the pipe buffer.
    for e in "$@"; do
      case "$e" in
        '!'*) ! grep -qE "^  FAIL  .*(${e#!})" <<< "$out" || also="$also [${e#!}]" ;;
        *) grep -qE "^  FAIL  .*($e)" <<< "$out" || miss="$miss [$e]" ;;
      esac
    done
    if [ -z "$miss$also" ]; then printf '  ok    %-84s convicted\n' "$label"
    else printf '  XX    %-84s convicted, but%s%s\n' "$label" "${miss:+ NOT by:$miss}" "${also:+ ALSO by (must pass):$also}"; fi
  }
  # Sequentially (the default) each verdict prints as it lands; with MUTJOBS > 1 they print in order at the end.
  par() { [ "${MUTJOBS:-1}" -gt 1 ]; }
  mutate() {  # <label> <sed -E program> <survive | [!]ERE...>
    local label="$1" prog="$2" mf res; shift 2
    MN=$((MN + 1)); mf="$mtmp/m$MN.sh"; res="$mtmp/m$MN.res"
    if ! sed -E "$prog" "$SUT" > "$mf"; then printf '  ERR   %-84s sed program failed\n' "$label" > "$res"
    elif cmp -s "$SUT" "$mf"; then printf '  SKIP  %-84s mutation was a NO-OP\n' "$label" > "$res"
    elif ! bash -n "$mf" 2>/dev/null; then printf '  ERR   %-84s mutant does not parse\n' "$label" > "$res"
    elif par; then
      while [ "$(jobs -rp | wc -l)" -ge "$MUTJOBS" ]; do command sleep 0.2; done
      judge "$label" "$mf" "$@" > "$res" &
      return
    else
      judge "$label" "$mf" "$@" > "$res"
    fi
    par || cat "$res"
  }
  # R1, the reap
  mutate 'R1: the early rm of users/$uid is restored' \
    's@^(  # #210 p2 \(Bug A fix\): cleanstorage is credless)@  rm -rf "/data/system/users/$uid" 2>> "$LOG"\n\1@' 'R1b users/11 is UNTOUCHED'
  mutate "R1: the settle stops waiting; the take's own record re-check still protects" \
    's@^  while userdir_has_record "\$1"; do$@  while false; do@' 'R1b anchor:timeout'
  mutate "R1: no wait AND no record re-check -- the take removes a live user's directory" \
    's@^  while userdir_has_record "\$1"; do$@  while false; do@; s@^  userdir_has_record "\$1" && return 0$@  :@' \
    'R1b users/11 is UNTOUCHED' 'R1c only 11.xml.backup -> the live file survives' 'R1c only 11.xml.reservecopy -> the live file survives'
  mutate 'R1: the record test forgets .backup' \
    's@ \|\| \[ -e "/data/system/users/\$1\.xml\.backup" \]@@' 'R1c only 11.xml.backup -> the live file survives'
  mutate 'R1: the record test forgets .reservecopy' \
    's@ \|\| \[ -e "/data/system/users/\$1\.xml\.reservecopy" \]@@' 'R1c only 11.xml.reservecopy -> the live file survives'
  mutate 'R1: the positive control (user 0 record) is dropped' \
    's@^  userdir_has_record 0 \|\| return 0$@  :@' 'R1d \.\.\. and users/11 is untouched'
  mutate 'R1: the settle waits only 8 polls, not 80' \
    's@\[ "\$_ud_polls" -ge 80 \]@[ "$_ud_polls" -ge 8 ]@' 'R1b anchor:timeout after 80 polls'
  mutate 'R1: the survivor loop no longer re-removes' \
    's@^      reap_userdir_take "\$uid"$@      :@' 'R1a users/11 is GONE'
  mutate 'R1: the loop removes behind any anchor, not only an ok one' \
    's@^    if \[ "\$_ud_anchor" = ok \]; then$@    if true; then@' 'R1d \.\.\. and users/11 is untouched'
  mutate 'R1: the quiet tail is dropped' \
    's@^    \[ -z "\$_reapleft" \] && \{ .* \} && break$@    [ -z "$_reapleft" ] \&\& break@' 'R1a users/11 is GONE' 'R1k users/11 is GONE'
  mutate 'R1: a removal at the anchor does not start the quiet tail' \
    's@\[ "\$_ud_took" = 0 \] \|\| \[ "\$_ud_quiet" -ge 12 \]@[ "$_ud_after" = 0 ] || [ "$_ud_quiet" -ge 12 ]@' 'R1k users/11 is GONE' 'R1j the quiet tail'
  mutate 'R1: a removal that LEFT the directory starts the tail anyway' \
    's@^      if \[ "\$_ud_took" -gt "\$_ud_seen" \] && \[ -z "\$_ud_left" \]; then$@      if [ "$_ud_took" -gt "$_ud_seen" ]; then@' \
    'R1g it is residue, and the loop ran its normal 12 polls'
  mutate 'R1: the cap is never raised (it stays 12)' \
    's@ _reapcap=\$\(\(_reapi \+ 13\)\); \[ "\$_reapcap" -gt 40 \] && _reapcap=40$@ _reapcap=12@' 'R1i users/11 is GONE'
  mutate 'R1: the raised cap is a flat 40 polls, not just what the tail needs' \
    's@ _reapcap=\$\(\(_reapi \+ 13\)\); \[ "\$_reapcap" -gt 40 \] && _reapcap=40$@ _reapcap=40@' 'R1p a removal at the anchor on a residue reap'
  mutate 'R1: the raised cap is 12 past the removal, not 13 (the tail loses its last poll)' \
    's@_reapcap=\$\(\(_reapi \+ 13\)\)@_reapcap=$((_reapi + 12))@' 'R1s the tick-12 write is seen' 'R1s users/11 is GONE'
  mutate 'R1: the raised cap has no ceiling' \
    's@; \[ "\$_reapcap" -gt 40 \] && _reapcap=40$@@' 'R1r a writer that never stops'
  mutate 'R1: a refused re-creation does not raise the cap (its rm gets no retry)' \
    's@^        if \[ "\$_ud_took" -gt "\$_ud_capt" \] && \[ "\$_ud_after" -gt 0 \]; then$@        if false; then@' \
    'R1t the refused tick-12 re-creation is cleared' 'R1t users/11 and its settings_ssaid.xml are gone' \
    'R1y a refused re-creation with no tail running' 'R1y users/11 and its settings_ssaid.xml are gone'
  mutate 'R1: a refused re-creation raises the cap only while a tail runs (the first removal gets no retry)' \
    's@ && \[ "\$_ud_after" -gt 0 \]; then$@ \&\& [ "$_ud_seen" -gt 0 ]; then@' \
    'R1y a refused re-creation with no tail running' 'R1y users/11 and its settings_ssaid.xml are gone'
  mutate 'R1: a LEFT at the first look raises the cap as well' \
    's@ && \[ "\$_ud_after" -gt 0 \]; then$@; then@' 'R1g it is residue, and the loop ran its normal 12 polls'
  mutate 'R1: a new tail does not record the removal it raised the cap for (the next poll raises it again)' \
    's@^        _ud_seen=\$_ud_took; _ud_capt=\$_ud_took; _ud_quiet=0$@        _ud_seen=$_ud_took; _ud_quiet=0@' \
    'R1z users/11 is gone, and the cap is 13 past the removal'
  mutate 'R1: a directory that stays LEFT moves the cap on every poll (no once-per-removal counter)' \
    's@^        if \[ "\$_ud_took" -gt "\$_ud_capt" \] && @        if [ -n "$_ud_left" ] \&\& @' 'R1w a re-creation that stays LEFT'
  mutate 'R1: the raise for a refused re-creation has no ceiling' \
    's@^(          _ud_capt=\$_ud_took; _reapcap=\$\(\(_reapi \+ 13\)\)); \[ "\$_reapcap" -gt 40 \] && _reapcap=40$@\1@' \
    'R1x a refused re-creation late in the tail' 'R1x \.\.\. it ends on the ceiling'
  mutate 'R1: a LEFT directory that an rm clears stays LEFT (the reset is dropped)' \
    's@^  _ud_left=""; _ud_gone=1$@  _ud_gone=1@' 'R1q cleared at tick 2' 'R1q users/11 is gone, and the tail ran'
  mutate "R1: a LEFT directory's last census is not folded (a racing writer goes unnamed)" \
    's@^  if \[ -n "\$_ud_left" \]; then userdir_census_fold "\$_lc" left; fi$@  :@' 'R1q the ledger names the racing writer'
  mutate "R1: a LEFT directory's last census adds all its others (a file that outlived the rm counts twice)" \
    's@^    if \[ "\$_n" -gt "\$_ud_lother" \]; then _ud_other=\$\(\(_ud_other \+ _n - _ud_lother\)\); fi$@    _ud_other=$((_ud_other + _n))@' \
    'R1q the ledger names the racing writer'
  mutate "R1: a LEFT episode is measured against the FIRST removal's other count, not its own (a file counts twice)" \
    's@_ud_other=\$\(\(_ud_other \+ _n\)\); _ud_lother=\$_n$@_ud_other=$((_ud_other + _n)); [ "$_ud_took" = 1 ] \&\& _ud_lother=$_n@' \
    'R1u the census counts the file that outlived the refused rm once'
  mutate 'R1: the quiet tail is 1 poll, not 12' \
    's@\[ "\$_ud_quiet" -ge 12 \]@[ "$_ud_quiet" -ge 1 ]@' 'R1i users/11 is GONE'
  mutate 'R1: ANY presence counts as a re-creation, not only absent->present' \
    's@^    if \[ "\$_ud_gone" = 1 \]; then _ud_after=\$\(\(_ud_after \+ 1\)\); else _ud_atanchor=1; fi$@    _ud_after=$((_ud_after + 1))@' 'R1f present at the anchor'
  mutate 'R1: a directory there at the first look is not flagged atanchor' \
    's@; else _ud_atanchor=1; fi$@; fi@' 'R1j there at the first look' 'R1f present at the anchor'
  mutate 'R1: a removal after an rm that could not clear it is counted again' \
    's@^  if \[ -z "\$_ud_left" \]; then$@  if true; then@' 'R1g the ledger names what REMAINS'
  mutate 'R1: an EMPTY directory is removed (a creation in progress loses it)' \
    's@^  if _l=\$\(ls -A "\$_d" 2>/dev/null\) && \[ -z "\$_l" \]; then _ud_gone=1; return 0; fi$@  :@' 'R1n the new user'
  mutate 'R1: an empty directory is skipped but not counted as gone' \
    's@\[ -z "\$_l" \]; then _ud_gone=1; return 0; fi$@[ -z "$_l" ]; then return 0; fi@' 'R1o empty at the anchor'
  mutate 'R1: a record that came back is removed anyway' \
    's@^  userdir_has_record "\$1" && return 0$@  :@' 'R1h'
  mutate 'R1: the census is the raw ls listing' \
    's@^  echo "files:\$_names other=\$_other"$@  echo "files:$(echo $(ls -A "$1")) other=$_other"@' 'R1a the package-named file is never named'
  mutate 'R1: the census misses hidden files' \
    's@^  for _f in "\$1"/\* "\$1"/\.\[!\.\]\*; do$@  for _f in "$1"/*; do@' 'R2a one ledger row for 30'
  # The census's biometric pattern. `..` (any two characters) stands for its '' alternative, which a
  # single-quoted sed program cannot spell.
  mutate 'census: an AIDL biometric settings file is not named (it falls to other=)' \
    's@^          \*\) _names="\$\{_names:\+\$_names,\}\$_b" ;;$@          *) _other=$((_other + 1)) ;;@' \
    'R1v both sensor-id files are named'
  mutate 'census: any settings_(fingerprint|face)_*.xml is named, digits or not' \
    's@^          ..\|\*\[!0-9\]\*\) _other=@          NOT-A-NAME) _other=@' 'R1v a package never rides in on the pattern'
  mutate 'census: an empty sensor id is admitted (settings_fingerprint_.xml is named)' \
    's@^          ..\|\*\[!0-9\]\*\) _other=@          *[!0-9]*) _other=@' 'R1v \.\.\. nor a name the pattern rejects'
  mutate 'census: the sensor id is whatever follows the LAST underscore (a package before _<digits> is named)' \
    's@^        _id=\$\{_b#settings_fingerprint_\}; \[ "\$_id" = "\$_b" \] && _id=\$\{_b#settings_face_\}; _id=\$\{_id%\.xml\}$@        _id=${_b%.xml}; _id=${_id##*_}@' \
    'R1v a package never rides in on the pattern'
  mutate 'census: both prefixes are stripped in turn (a name with a second prefix is admitted)' \
    's@ \[ "\$_id" = "\$_b" \] && _id=\$\{_b#settings_face_\};@ _id=${_id#settings_face_};@' 'R1v \.\.\. nor a name the pattern rejects'
  mutate "R1: the take's rm stderr goes to the log" \
    's@^  rm -rf "\$_d" 2>/dev/null$@  rm -rf "$_d" 2>> "$LOG"@' 'R1g \.\.\. nor in roam\.log'
  mutate 'R1: the ledger is written only when class != clean' \
    's@^  if \[ "\$_reapclass" != clean \] \|\| \[ "\$_ksv" = notsealed \] \|\| .*; then$@  if [ "$_reapclass" != clean ] || [ "$_ksv" = notsealed ]; then@' \
    'R1a a ledger row is written' 'R1j a ledger row is written' 'R1l' 'R1m'
  mutate 'R1: the ledger forgets what this reap removed (the took clause is dropped)' \
    's@ \|\| \[ "\$_ud_took" != 0 \]@@' 'R1a a ledger row is written' 'R1j a ledger row is written'
  mutate 'R1: the ledger forgets a timeout or blind anchor (the anchor clause is dropped)' \
    's@ \|\| \[ "\$_ud_anchor" != ok \]@@' 'R1l' 'R1m'
  # The quotes must be ESCAPED to reach the log: a bare "..." inside the already double-quoted echo just closes
  # and reopens the shell string, so the line would be byte-identical and the mutant inert in effect.
  mutate 'R1: the userdir field is quoted (log_scrub eats it)' \
    's@ userdir=\$_udf \$\(date\)@ userdir=\\"$_udf\\" $(date)@' 'the REAL log_scrub'
  mutate 'R1: the settle is an undefined command at its call site (the forward-reference trap)' \
    's@^  reap_userdir_settle "\$uid"$@  reap_userdir_setle "$uid"@' 'H no run hit an undefined command'
  # R4, the reap and a link at users/<uid>
  mutate 'R4: the take follows a link like a directory (no link branch)' \
    's@^  if \[ -L "\$_d" \]; then$@  if false; then@' 'R4a the reap line says link' 'R4a the ledger names none' 'R4b the ledger row says' 'R4b neither the ledger'
  mutate 'R4: a removed link is not flagged (_ud_link unset)' \
    's@^    _ud_link=1; _ud_left=""; _ud_gone=1; return 0$@    _ud_left=""; _ud_gone=1; return 0@' 'R4a the reap line says link' 'R4a one ledger row'
  mutate 'R4: the ledger forgets a link (the link clause is dropped)' \
    's@ \|\| \[ -n "\$_ud_link" \]; then$@; then@' 'R4a one ledger row'
  mutate 'R4: the remains: census follows a link the rm left' \
    's@if \[ -L "/data/system/users/\$uid" \]; then _udc="\$_udc remains:link"; else @if false; then :; else @' \
    'R4b the ledger row says' 'R4b neither the ledger'
  mutate 'R4: a link its rm could not remove is reported removed' \
    's@^    if \[ -L "\$_d" \] \|\| \[ -e "\$_d" \]; then _ud_link=1; _ud_left=1; _ud_gone=0; return 0; fi$@    :@' 'R4b the ledger row says'
  mutate 'R4: a link whose record came back is removed anyway' \
    's@^    userdir_has_record "\$1" && return 0$@    :@' 'R4c a link whose user has a record is kept'
  # R2, the boot sweep
  mutate 'R2: the numeric-name filter is dropped' \
    '\%^  for _p in /data/system/users/\*; do$%,\%^  done$%s@^    case "\$_u" in .* esac$@    :@' 'R2a kept: a non-numeric directory'
  mutate 'R2: the id floor is 0, not 10' \
    '\%^  for _p in /data/system/users/\*; do$%,\%^  done$%s@^    \[ "\$_u" -lt 10 \] && continue$@    [ "$_u" -lt 0 ] \&\& continue@' 'R2a kept: id 9'
  mutate 'R2: an empty system-owned directory is no longer skipped' \
    's@^    \[ -z "\$_ls" \] && \[ "\$_o" = 1000 \] && continue$@    :@' 'R2a result' 'R2a no ledger row for any kept id'
  mutate 'R2: an empty directory is skipped whoever owns it' \
    's@^    \[ -z "\$_ls" \] && \[ "\$_o" = 1000 \] && continue$@    [ -z "$_ls" ] \&\& continue@' 'R2g an EMPTY 16 owned by root'
  mutate 'R2: the DIRECTORY is removed, not its contents' \
    's@^    rm -rf "\$_p"/\* "\$_p"/\.\[!\.\]\* 2>/dev/null$@    rm -rf "$_p" 2>/dev/null@' 'R2a \.\.\. and its DIRECTORY is kept'
  mutate 'R2: the contents rm skips dotfiles' \
    's@^    rm -rf "\$_p"/\* "\$_p"/\.\[!\.\]\* 2>/dev/null$@    rm -rf "$_p"/* 2>/dev/null@' "R2a the orphan's contents are gone"
  mutate 'R2: a kept directory is not handed back to system' \
    's@^    elif \{ chown system:system "\$_p" && chmod 0700 "\$_p" && restorecon "\$_p"; \} 2>/dev/null; then$@    elif true; then@' \
    'R2g 32 emptied, and chown' 'R2g 33: chown refused'
  mutate 'R2: the hand-back skips restorecon' \
    's@ && restorecon "\$_p"; \} 2>/dev/null; then$@; } 2>/dev/null; then@' 'R2g 32 emptied, and chown'
  mutate 'R2: a restorecon failure no longer makes the id LEFT' \
    's@ && restorecon "\$_p"; \} 2>/dev/null; then$@ \&\& { restorecon "$_p" || :; }; } 2>/dev/null; then@' \
    'R2g 35: restorecon refused' 'R2g result'
  mutate 'R2: a chmod failure no longer makes the id LEFT' \
    's@ && chmod 0700 "\$_p" && @ \&\& { chmod 0700 "$_p" || :; } \&\& @' 'R2g 34: chmod refused' 'R2g result'
  mutate 'R2: no ledger row per id' \
    's@^    echo "\$\(date \+%s\) userdir ctx=boot uid=\$_u \$_c" >> /data/nowhere/reap-ledger 2>/dev/null$@    :@' 'R2a one ledger row for 30'
  mutate 'R2: userdirs= is only appended when non-zero' \
    's@^  else _swept="\$_swept userdirs=\$_n"; fi$@  elif [ "$_n" -gt 0 ]; then _swept="$_swept userdirs=$_n"; fi@' 'R2b nothing to do'
  mutate 'R2: the sweep runs although the controls failed' \
    's@^    \[ -n "\$_u0" \] \|\| break$@    :@' 'R2c \.\.\. and NOTHING is removed' 'R2f \.\.\. and NOTHING is removed'
  mutate "R2: user 0's record is no longer required" \
    's@^  userdir_has_record 0 \|\| _u0=""$@  :@' 'R2f'
  mutate 'R2: a failed control reports a count, not UNREACHABLE' \
    's@^  if \[ -z "\$_u0" \]; then _swept="\$_swept userdirs=UNREACHABLE"$@  if false; then :@' 'R2c no user-0 directory'
  mutate 'R2: the second record look is dropped' \
    '\%^    _c=\$\(userdir_census "\$_p"\)$%,\%^    rm -rf %s@^    userdir_has_record "\$_u" && continue$@    :@' 'R2e'
  mutate 'R2: an unlistable directory reads as empty' \
    's@^    if ! _ls=\$\(ls -A "\$_p" 2>/dev/null\); then$@    if _ls=$(ls -A "$_p" 2>/dev/null); false; then@' 'R2d'
  mutate 'R2: a symbolic link is followed like a directory (its target emptied and handed to system)' \
    's@^    if \[ -L "\$_p" \]; then$@    if false; then@' 'R2h the target of the link is untouched' 'R2h \.\.\. its mode is still 755'
  mutate 'R2: a dangling link is skipped (only a link to a directory is removed)' \
    's@^    \[ -d "\$_p" \] \|\| \[ -L "\$_p" \] \|\| continue$@    [ -d "$_p" ] || continue@' 'R2h a dangling link'
  mutate 'R2: a link its rm could not remove is reported removed' \
    's@^      if \[ -L "\$_p" \] \|\| \[ -e "\$_p" \]; then _nl=\$\(\(_nl \+ 1\)\); _c="LEFT link"$@      if false; then :@' \
    'R2h a link rm cannot remove'
  # R3, seedssaid
  mutate 'R3: seedssaid creates users/$uid again' \
    's@^    _udd=0; _udr=0$@    mkdir -p "/data/system/users/$uid" 2>>"$LOG"; _udd=0; _udr=0@' 'R3a \.\.\. and the directory is NOT created'
  mutate 'R3: seedssaid checks the directory only, not the record' \
    's@^    if userdir_has_record "\$uid"; then _udr=1$@    if true; then _udr=1@' 'R3c'
  mutate 'R3: a missing directory no longer refuses' \
    's@^    if \[ "\$_udd" = 0 \] \|\| \[ "\$_udr" = 0 \]; then$@    if [ "$_udr" = 0 ]; then@' 'R3a record but no directory'
  mutate 'R3: blind records refuse (no positive control)' \
    's@^    elif ! userdir_has_record 0; then _udr=blind; fi$@    fi@' 'R3e'
  mutate 'R3: a refusal still stages' \
    's@^      echo "ERR-NOUSER" > "\$RES"; chmod 600 "\$RES"; exit 0$@      :@' 'R3c'
  mutate 'R3: seedssaid takes a link to a directory for the directory' \
    's@ && \[ ! -L "/data/system/users/\$uid" \] && _udd=1$@ \&\& _udd=1@' 'R3g a link at users/11' 'R3g \.\.\. no seed is written' 'R3g \.\.\. and the target'
  mutate "R3: seedssaid's refusal does not say (link)" \
    's@^    _udl=""; \[ -L "/data/system/users/\$uid" \] && _udl=" \(link\)"$@    _udl=""@' 'R3g the log line says \(link\)'
  # IN, the roam-in that does not land
  mutate 'IN: the seed is kept when the sign-in does not land' \
    's@^           rm -f "\$_seed" 2>/dev/null$@           :@' 'INa BLANK -> the seed is gone' 'INb NEEDKEY -> the seed is gone'
  mutate 'IN: a consumed seed is left in settings_ssaid.xml (only the seed file is removed)' \
    's@^      \*\) for _sf in nowhere-ssaid-seed settings_ssaid\.xml; do$@      *) for _sf in nowhere-ssaid-seed; do@' \
    'INf BLANK after the seed was consumed' 'INg NEEDKEY after the seed was consumed'
  mutate 'IN: the seed is removed even when the sign-in lands' \
    's@^      OK\*\) ;;$@      OK-NEVER*) ;;@' 'INc a sign-in that landed keeps its seed'
  mutate 'IN: a seed that could not be removed is logged as removed' \
    's@^           if \[ -e "\$_seed" \]; then$@           if false; then@' 'INe'
  mutate 'IN: the verdict is read back from $RES (a reply the agent already took reads as not landed)' \
    's@^    case "\$_inres" in$@    _inres=""; [ -f "$RES" ] \&\& read -r _inres < "$RES"\n    case "$_inres" in@' \
    'INh a sign-in that landed keeps its seed' 'INh \.\.\. and its settings_ssaid\.xml' 'INh \.\.\. and logs no line'
  mutate 'IN: the verdict starts as OK (a reply that never said OK keeps the seed)' \
    's@^    _inres=""$@    _inres=OK@' 'INa BLANK -> the seed is gone' 'INi BLANK with the reply already taken'
  # R5, the re-check (NWP-20261104-14). Each R5 case in the per-shell loop runs under every shell found and is
  # labelled "R5<x> <sh>:". The run_clean R5a/R5b/R5j cases are bash's alone and carry no shell label: no
  # conviction here rests on them, and only the `!R5a ` and `!R5j ` checks take them in, with every shell's lines.
  # r5 <case...> sets R5E to one ERE per (case, shell found), so a mutant is convicted only when EVERY shell's own
  # line fails -- one shell's conviction cannot hide another's survivor (mksh is the device's shell).
  r5() { local c s1; R5E=(); for c in "$@"; do for s1 in $R5SHELLS; do command -v "$s1" >/dev/null 2>&1 && R5E+=("$c $s1:"); done; done; }
  r5 R5d; mutate 'R5: the record check is dropped (a uid on record is removed)' \
    's@ \|\| userdir_has_record "\$_u"; then$@; then@' "${R5E[@]}"
  r5 R5e; mutate "R5: user 0's record is no longer required" \
    '\%^userdir_recheck\(\) \{$%,\%^\}$%s@^  userdir_has_record 0 \|\| return 0$@  :@' "${R5E[@]}"
  r5 R5d R5f; mutate 'R5: the line is dropped though the record remains' \
    's@^      echo "\$_l" >> "\$_f\.tmp"; _n=\$\(\(_n \+ 1\)\); continue$@      continue@' "${R5E[@]}"
  r5 R5n; mutate 'R5: a skipped uid loses its left mark (the next refused rm writes a second left row)' \
    's@^      echo "\$_l" >> "\$_f\.tmp"; _n=\$\(\(_n \+ 1\)\); continue$@      echo "$_u" >> "$_f.tmp"; _n=$((_n + 1)); continue@' "${R5E[@]}"
  r5 R5g; mutate 'R5: the line is dropped when the rm left the directory' \
    's@^    if \[ -n "\$_ud_left" \]; then echo "\$_u left" >> "\$_f\.tmp"; _n=\$\(\(_n \+ 1\)\); _what=LEFT; fi$@    if [ -n "$_ud_left" ]; then _what=LEFT; fi@' "${R5E[@]}"
  r5 R5g2; mutate 'R5: the left row is written again at every re-check (the once-only check dropped)' \
    's@^    \[ -n "\$_ud_left" \] && \[ "\$_was" = left \] && continue.*$@    :@' "${R5E[@]}"
  r5 R5g2; mutate 'R5: the queue dedups the whole line, not the uid (a left uid is listed twice)' \
    's@grep -qE -- "\^\$1\( left\)\?\\\$"@grep -qxF -- "$1"@' "${R5E[@]}"
  r5 R5o; mutate 'R5: the queue match loses its end anchor (110 listed -> 11 is never queued)' \
    's@grep -qE -- "\^\$1\( left\)\?\\\$"@grep -qE -- "^$1( left)?"@' "${R5E[@]}"
  r5 R5o; mutate "R5: the queue match loses its start anchor ('111 left' listed -> 11 is never queued)" \
    's@grep -qE -- "\^\$1\( left\)\?\\\$"@grep -qE -- "$1( left)?\\$"@' "${R5E[@]}"
  r5 R5f; mutate 'R5: the op'"'"'s own uid is not skipped' \
    's@\[ "\$_u" = "\$\{uid:-\}" \] \|\| @@' "${R5E[@]}"
  r5 R5c; mutate 'R5: no ledger row for a re-check' \
    's@^      echo "\$\(date \+%s\) uid=\$_u class=recheck .*$@      :@' "${R5E[@]}"
  r5 R5k; mutate 'R5: the lane guard is dropped (the read-only lane would remove directories)' \
    's@^\[ "\$LANE" = rw \] && userdir_recheck$@userdir_recheck@' 'P5 the line right before' "${R5E[@]}"
  r5 R5c R5k; mutate 'R5: the call before case "$op" is removed' \
    '\%^\[ "\$LANE" = rw \] && userdir_recheck$%d' 'P5 the line right before' "${R5E[@]}"
  r5 R5a R5b; mutate 'R5: cleanstorage queues nothing' \
    's@^  case "\$_ud_anchor" in timeout\|blind\) userdir_pending_add "\$uid" ;; esac.*$@  :@' "${R5E[@]}"
  r5 R5j; mutate 'R5: cleanstorage does not re-check first' \
    's@^  userdir_recheck   #.*$@  :@' "${R5E[@]}"
  # QL and RL are taken by position, so an edit that keeps a line's behaviour must leave every R5a or R5j case
  # passing (`!`), and a line moved off its position is P6's to convict.
  r5 R5b; mutate "R5: cleanstorage's queue line drops blind (a timeout reap is still queued)" \
    's@^(  case "\$_ud_anchor" in timeout)\|blind\)@\1)@' "${R5E[@]}" '!R5a '
  mutate "R5: cleanstorage's re-check call gains an argument it ignores (only P6's text pin convicts)" \
    's@^  userdir_recheck   #@  userdir_recheck x #@' 'P6 cleanstorage calls userdir_recheck once' '!R5j '
  mutate "R5: cleanstorage's re-check moves below loc_release (off the position RL is taken from)" \
    '/^  userdir_recheck   #/{h;d};/^  loc_release "\$uid" reap/G' 'P6 cleanstorage calls userdir_recheck once'
  r5 R5c R5h; mutate 'R5: the re-check never takes (no removal at all)' \
    's@^    reap_userdir_take "\$_u"$@    :@' "${R5E[@]}"
  # PROBES. If one of these is convicted the suite is pinning wording or redundancy, not behaviour.
  mutate 'PROBE: a word in the re-check comment changes' \
    's@the timer every few minutes that Q037 also names@the timer every several minutes that Q037 also names@' survive
  mutate 'PROBE: a word in a new comment changes' \
    's@a removal that silently never ran@a removal that quietly never ran@' survive
  mutate 'PROBE: two allowlisted names swap places in the census' \
    's@settings_secure\.xml\|settings_system\.xml\|@settings_system.xml|settings_secure.xml|@' survive
  mutate "PROBE: the settle's own take is dropped (the loop's first poll repeats it)" \
    's@^  reap_userdir_take "\$1"$@  :@' survive
  mutate 'PROBE: R2 tests -d and -L before the id floor' \
    '\%^  for _p in /data/system/users/\*; do$%,\%^  done$%{s@^    \[ "\$_u" -lt 10 \] && continue$@    [ -d "$_p" ] || [ -L "$_p" ] || continue@;t;s@^    \[ -d "\$_p" \] \|\| \[ -L "\$_p" \] \|\| continue$@    [ "$_u" -lt 10 ] \&\& continue@}' survive
  wait
  # Every mutant must have left exactly one verdict line, and it must be an ok: a job that died without writing
  # one is a failure of this runner, not a pass.
  bad=0
  for t in $(seq 1 "$MN"); do
    if [ ! -s "$mtmp/m$t.res" ]; then printf '  ERR   mutation %d left no verdict\n' "$t"; bad=1
    elif par; then cat "$mtmp/m$t.res"; fi
    grep -q '^  ok ' "$mtmp/m$t.res" 2>/dev/null || bad=1
  done
  echo
  if [ "$bad" = 0 ]; then echo "ALL $MN MUTATIONS BEHAVED"
  else echo "PROBLEM: a mutation did not behave"; FAILED=1; fi
  rm -rf "$mtmp"
fi

exit "${FAILED:-0}"
