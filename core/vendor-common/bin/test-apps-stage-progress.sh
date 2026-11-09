#!/usr/bin/env bash
# test-apps-stage-progress.sh [<nowhere_roamd.sh>] [--mutate] -- the #apps staging step keeps the daemon's stall
# watchdog fed and times itself (NWP-20261005-04).
#
# WHY THIS IS COMMITTED. The daemon gives up on a worker op after 150 s with no CHANGE in the progress file, and
# appcode_seal's staging loop copies every kept app's whole APK while writing nothing. On frankel 0.5.41 (ticket
# NW-f6f717125af3) a logoff seal finished every data scope, started staging #apps, and was declared ERR-TIMEOUT
# exactly 150 s after its last progress write, so the logoff failed. The fix is one progress line per package and
# a timing line. Both are silent when they regress -- a watchdog that starves only shows up as a failed logoff on
# a profile with gigabytes of apps -- so this suite pins them.
#
# _apps_stage_prog is extracted BY ANCHOR and run against a temp file; the wiring inside appcode_seal is pinned
# line for line (a suite guarding a shell script pins the block, not a spelling).
#
# Each writer case (P1-P3) writes the extracted function, its variables and the case body into a run file and executes
# that file in a CHILD of each shell found among bash, sh, dash and mksh (the device's /system/bin/sh), NWP-20261113-42.
# Each run file records the identity of the shell that ran it and the suite asserts it is the shell the case launched;
# a run file that records none is a HARNESS error (exit 2), never a FAIL. The wiring pins (W1-W8) are text and run once.
# A writer mutant is convicted only when every shell found has its own FAIL line.
#
#   bash test-apps-stage-progress.sh            # the cases
#   bash test-apps-stage-progress.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
# Every temp of the run lives inside W.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

SHELLS=""; for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "no shell to run under" >&2; exit 2; }
IDPROBE='_id="${KSH_VERSION:+ksh:$KSH_VERSION}${BASH_VERSION:+bash:$BASH_VERSION}"; [ -n "$_id" ] || _id=posix; _pr=none; command -v print >/dev/null 2>&1 && _pr=builtin'
REF_SH=""; command -v sh >/dev/null 2>&1 && REF_SH=$(sh -c "$IDPROBE; printf '%s|%s\n' \"\$_id\" \"\$_pr\"")
PRINT_SHIM='command -v print >/dev/null 2>&1 || print() { _pn=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) _pn=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$_pn" = 1 ]; then printf "%s\n" "$*"; else printf "%s" "$*"; fi; }'
sq(){ printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
runsh(){ "$1" "$2" >/dev/null 2>&1; }
# idok <shell> <id file> -> 0 iff the file holds at least one line and every line is that shell's identity
idok(){
  local s="$1" f="$2" l n=0
  [ -s "$f" ] || return 1
  while IFS= read -r l; do
    n=$((n+1))
    case "$s" in
      bash) case "$l" in bash:*'|none') ;; *) return 1 ;; esac ;;
      dash) [ "$l" = 'posix|none' ] || return 1 ;;
      mksh) case "$l" in 'ksh:|'*) return 1 ;; ksh:?*'|builtin') ;; *) return 1 ;; esac ;;
      sh)   [ "$l" = "$REF_SH" ] || return 1 ;;
      *)    return 1 ;;
    esac
  done < "$f"
  [ "$n" -gt 0 ]
}
# notrun <shell> <case dir>: a run file that recorded no identity never launched -- a HARNESS error (noted in
# $W/harness, which suite turns into exit 2), never a behavioural FAIL a mutant could be convicted by. One that recorded
# the WRONG shell is noted in $W/notrun for suite's per-shell FAIL line.
notrun() {
  [ -s "$2/shell.id" ] || { echo "$1" >> "$W/harness"; return 1; }
  idok "$1" "$2/shell.id" || { echo "$1" >> "$W/notrun"; return 1; }
}

# run_writer <shell> <fn-file> <progress: set|unset> <case body> -> the body's stdout, then "NOTRUN" when the run file
# did not run under <shell>. With <progress> set, NOWHERE_PROGRESS is a file in the case dir; unset, it is empty.
run_writer() {
  local sh="$1" fnf="$2" prog="$3" body="$4" d np=""
  d=$(mktemp -d -p "$W") || exit 2
  [ "$prog" = set ] && np="$d/roam.progress"
  {
    printf '%s; printf "%%s|%%s\\n" "$_id" "$_pr" >> %s\n' "$IDPROBE" "$(sq "$d/shell.id")"
    printf '%s\n' "$PRINT_SHIM"
    printf 'NOWHERE_PROGRESS=%s\n' "$(sq "$np")"
    cat "$fnf"
    printf '{\n%s\n} > %s\n' "$body" "$(sq "$d/out")"
  } > "$d/run.sh"
  runsh "$sh" "$d/run.sh"
  cat "$d/out" 2>/dev/null
  notrun "$sh" "$d" || echo NOTRUN
  rm -rf "$d"
}

CALL='_stg_i=$((_stg_i+1)); [ "$_stg_i" -le "$_stg_n" ] || _stg_n=$_stg_i; _apps_stage_prog "$_stg_i" "$_stg_n"'

suite() {  # suite <roamd.sh> <shell> [quiet] -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" s="$2" quiet="${3:-}" p=0 x=0 fn fnf out
  ok(){ p=$((p+1)); [ -n "$quiet" ] || printf '  ok    [%s] %s\n' "$s" "$1"; }
  no(){ x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  [%s] %s\n' "$s" "$1"; }

  fn=$(sed -n '/^_apps_stage_prog() {$/,/^}$/p' "$f")
  case "$fn" in *'NOWHERE_PROGRESS'*) ;; *) echo "EXTRACTION FAILED -- _apps_stage_prog moved in $f" >&2; return 2 ;; esac
  fnf=$(mktemp -p "$W") || return 2
  printf '%s\n' "$fn" > "$fnf"
  if ! bash -n "$fnf" || ! "$s" -n "$fnf"; then
    echo "EXTRACTION FAILED -- _apps_stage_prog does not parse under $s in $f" >&2; rm -f "$fnf"; return 2
  fi
  : > "$W/notrun"; : > "$W/harness"

  # --- the writer ---
  out=$(run_writer "$s" "$fnf" set '
    _apps_stage_prog 3 41; cat "$NOWHERE_PROGRESS"; [ -e "$NOWHERE_PROGRESS.tmp" ] && echo TMP-LEFT; true')
  [ "$out" = "sizes 3 41 apps" ] && ok "P1 writes the agent's line shape: sizes <done> <total> apps" || no "P1 wrote [$out]"
  out=$(run_writer "$s" "$fnf" set '
    _apps_stage_prog 1 2; a=$(cat "$NOWHERE_PROGRESS"); _apps_stage_prog 2 2; b=$(cat "$NOWHERE_PROGRESS"); [ "$a" != "$b" ] && echo CHANGED')
  [ "$out" = "CHANGED" ] && ok "P2 successive packages CHANGE the line (the watchdog resets only on a change)" || no "P2 the line did not change [$out]"
  out=$(run_writer "$s" "$fnf" unset '_apps_stage_prog 1 1; echo rc=$?')
  [ "$out" = "rc=0" ] && ok "P3 no progress file configured: a no-op that never fails the seal" || no "P3 got [$out]"

  rm -f "$fnf"
  if [ -s "$W/harness" ]; then echo "HARNESS ERROR: a run file left no identity: $s did not launch it" >&2; return 2; fi
  # run_writer runs inside $( ), so a case that did not run under $s says so through $W/notrun
  if grep -qx "$s" "$W/notrun"; then no "identity: a case did not run under $s"; else ok "identity: every case ran under $s"; fi
  [ -n "$quiet" ] || printf '  -- [%s] %d ok, %d failed\n' "$s" "$p" "$x"
  [ "$x" -eq 0 ] && return 0 || return 1
}

textpins() {  # textpins <roamd.sh> [quiet] -> 0 all ok, 1 a pin failed, 2 appcode_seal moved; shell-independent, run once
  local f="$1" quiet="${2:-}" p=0 x=0 body
  ok(){ p=$((p+1)); [ -n "$quiet" ] || printf '  ok    [text] %s\n' "$1"; }
  no(){ x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  [text] %s\n' "$1"; }
  # ⚠ Every match below reads its input to the end: a here-string (`grep -q PAT <<<"$var"`) or
  # `grep -c PAT >/dev/null` on a pipe, never `cmd | grep -q`. Under pipefail grep -q exits at its first match,
  # the producer can die of SIGPIPE, and the pipeline fails: an absence check then passes on the code it exists
  # to reject, a presence check goes red at random (docs/backlog.md, "pipes into grep -q under pipefail").

  body=$(sed -n '/^appcode_seal() {$/,/^}$/p' "$f")
  case "$body" in *'stage_apk_copy "$ap" "$d/$bn"'*) ;; *) echo "EXTRACTION FAILED -- appcode_seal moved in $f" >&2; return 2 ;; esac

  # --- the wiring, pinned line for line ---
  local nc
  nc=$(printf '%s\n' "$body" | grep -cxF "    $CALL")
  [ "$nc" = 1 ] && ok "W1 the code-list loop writes progress once per package" || no "W1 code-list loop call count $nc, want 1"
  nc=$(printf '%s\n' "$body" | grep -cxF "      $CALL")
  [ "$nc" = 1 ] && ok "W2 the keep-set sweep writes progress once per package" || no "W2 keep-set call count $nc, want 1"
  # Each call must sit INSIDE its loop, after the line that skips non-packages: before the loop it would fire
  # once, after `continue`-able checks it would still fire per package.
  grep -A1 -xF '    [ -n "$pkg" ] || continue' <<<"$body" | grep -cxF "    $CALL" >/dev/null \
    && ok "W3 the code-list call follows the package check" || no "W3 the code-list call is not right after [ -n \"\$pkg\" ] || continue"
  grep -A1 -xF '      case "$kpkg" in group:*|\#*) continue ;; esac' <<<"$body" | grep -cxF "      $CALL" >/dev/null \
    && ok "W4 the keep-set call follows the group/comment skip" || no "W4 the keep-set call is misplaced"
  grep -qxF '  local _stg_t0 _stg_i _stg_n _stg_a _stg_k' <<<"$body" \
    && ok "W5 the counters are local (a roamd helper that leaks a global has lost a roam before)" || no "W5 the counters are not declared local"
  grep -qxF '  _stg_kib=$(du -sk "$STAGE" 2>/dev/null | cut -f1)' <<<"$body" && grep -qxF '  _stg_ms=$(( $(_ms) - _stg_t0 ))' <<<"$body" \
    && grep -qF '[roamd] #apps staged $staged pkg(s), $_stg_kib KiB, in ${_stg_ms}ms (copy ${_acw_cms}ms, $_acw_tf mtime kept-failed, $_acw_ru reused) (NWP-20261005-04, NWP-20261123-02, NWP-20261128-09) (lookups ${_acw_lms}ms/$_acw_lct, carry ${_acw_kms}ms, lists ${_acw_sms}ms, other ${_stg_oth}ms)' <<<"$body" \
    && ok "W6 staging is timed and sized, with no profile or package name" || no "W6 the timing line is missing or changed"
  # The timing line must come AFTER both loops, or it times nothing.
  printf '%s\n' "$body" | awk '/done < "\$AK"/{d=1} /#apps staged/{if(d) ok=1} END{exit ok?0:1}' \
    && ok "W7 the timing line follows the keep-set sweep" || no "W7 the timing line runs before staging ends"
  # W8: the line must survive roamd's own log_scrub, which rewrites the token after "[roamd] OUT|IN|GRANT " to
  # <name> at rest. The first cut started "[roamd] OUT #apps staged", and on lynx 2026-10-05 it read back as
  # "[roamd] OUT <name> staged" -- no name leaked, but the line lost the label that says what it measures.
  local scrub sample
  scrub=$(grep -m1 "^LOG_SCRUB_SED='" "$f"); scrub=${scrub#LOG_SCRUB_SED=\'}; scrub=${scrub%\'}
  sample=$(printf '%s\n' "$body" | grep -F '#apps staged $staged' | sed -E 's/^ *echo "//; s/" >> "\$LOG"$//; s/\$staged/3/; s/\$\(du[^)]*\)\)?/120/; s/\$\(\( [^)]*\)\)ms/40ms/')
  if [ -z "$scrub" ] || [ -z "$sample" ]; then no "W8 EXTRACTION FAILED -- log_scrub's sed or the timing line moved"
  elif sed -E "$scrub" <<<"$sample" | grep -cF '#apps staged 3 pkg(s)' >/dev/null; then ok "W8 the timing line survives log_scrub with its label"
  else no "W8 log_scrub rewrites the timing line: $(printf '%s\n' "$sample" | sed -E "$scrub")"; fi

  [ -n "$quiet" ] || printf '  -- [text] %d ok, %d failed\n' "$p" "$x"
  [ "$x" -eq 0 ] && return 0 || return 1
}

echo "#apps staging progress: $SUT"
echo "shells:$SHELLS"
echo "sh identity: $REF_SH"
textpins "$SUT"; rc=$?
[ "$rc" = 0 ] || FAILED=$rc
for s in $SHELLS; do
  suite "$SUT" "$s"; rc=$?
  [ "$rc" -gt "${FAILED:-0}" ] && FAILED=$rc
done

if [ "$MUTATE" = yes ]; then
  echo
  echo "mutations (each must CONVICT; a writer mutant under every shell found):"
  mtmp=$(mktemp -d -p "$W") || exit 2
  mutate() {  # <beh|text> <label> <sed program>
    local kind="$1" label="$2" prog="$3" mf="$mtmp/r.sh" r s out alive="" err=""
    if ! sed -E "$prog" "$SUT" > "$mf"; then printf '  ERR   %-58s sed program failed\n' "$label"; MFAIL=1; return; fi
    if cmp -s "$SUT" "$mf"; then printf '  SKIP  %-58s mutation was a NO-OP\n' "$label"; MFAIL=1; return; fi
    if [ "$kind" = text ]; then
      textpins "$mf" quiet >/dev/null 2>&1; r=$?
      case "$r" in
        0) printf '  XX    %-58s SURVIVED [text]\n' "$label"; MFAIL=1 ;;
        1) printf '  ok    %-58s convicted [text]\n' "$label" ;;
        *) printf '  ERR   %-58s harness error (rc=%s)\n' "$label" "$r"; MFAIL=1 ;;
      esac
      return
    fi
    # a writer mutant convicts under a shell only with rc 1 AND that shell's own FAIL line
    for s in $SHELLS; do
      out=$(suite "$mf" "$s" 2>&1); r=$?
      case "$r" in
        1) case "$out" in *"FAIL  [$s]"*) ;; *) alive="$alive $s" ;; esac ;;
        0) alive="$alive $s" ;;
        *) err="$err $s" ;;
      esac
    done
    if [ -n "$alive" ]; then printf '  XX    %-58s SURVIVED under:%s\n' "$label" "$alive"; MFAIL=1
    elif [ -n "$err" ]; then printf '  ERR   %-58s harness error (not a conviction) under:%s\n' "$label" "$err"; MFAIL=1
    else printf '  ok    %-58s convicted under every shell\n' "$label"; fi
  }
  mutate beh  'the writer writes a constant line'          's/^  printf .sizes %s %s apps\\n. "\$1" "\$2"/  printf "sizes 0 0 apps\\n"/'
  mutate beh  'the writer uses another phase'              's/^  printf .sizes %s %s apps/  printf '"'"'save %s %s apps/'
  mutate text 'the code-list loop writes nothing'          '0,/^    _stg_i=\$\(\(_stg_i\+1\)\);.*$/ s//    :/'
  mutate text 'the keep-set sweep writes nothing'          's/^      _stg_i=\$\(\(_stg_i\+1\)\);.*$/      :/'
  mutate text 'the counters leak as globals'               's/^  local _stg_t0 _stg_i _stg_n _stg_a _stg_k$/  :/'
  mutate text 'staging is not timed'                       's/^  echo "\[roamd\] #apps staged .*$/  :/'
  mutate text 'the timing line names the profile'          's/\[roamd\] #apps staged \$staged/[roamd] OUT $name #apps staged $staged/'
  mutate text 'the timing line starts with OUT (scrubbed)' 's/\[roamd\] #apps staged \$staged/[roamd] OUT #apps staged $staged/'
  # harness-error probe: a child that never launches must end the suite with exit 2 and HARNESS ERROR -- not exit 1
  # with FAIL lines, which a mutation run would count as a conviction
  probe() {  # probe <label> <sed program over this suite>
    local cp="$mtmp/suite-probe.sh" r
    sed "$2" "$0" > "$cp"
    if cmp -s "$0" "$cp"; then printf '  SKIP  %-58s mutation was a NO-OP\n' "$1"; MFAIL=1; return; fi
    bash "$cp" "$SUT" > "$mtmp/probe.out" 2>&1; r=$?
    if [ "$r" -eq 2 ] && grep -q 'HARNESS ERROR' "$mtmp/probe.out"; then printf '  ok    %-58s harness error, not a conviction\n' "$1"
    else printf '  XX    %-58s HARNESS ERROR NOT RAISED (rc %s)\n' "$1" "$r"; MFAIL=1; fi
  }
  # runner_verdict <suite copy> <shell>...: run the copy; it convicts only when it exits 1 (exit 2 is a HARNESS error,
  # never a conviction) and printed its own FAIL line for each shell named. Prints what missed; returns 0 on conviction.
  runner_verdict() {
    local cp="$1" s r miss=""; shift
    bash "$cp" "$SUT" > "$mtmp/runner.out" 2>&1; r=$?
    [ "$r" -eq 1 ] || miss=" (rc $r, not 1)"
    grep -q 'HARNESS ERROR' "$mtmp/runner.out" && miss="$miss (HARNESS ERROR)"
    for s in "$@"; do grep -q "FAIL  \[$s\]" "$mtmp/runner.out" || miss="$miss $s"; done
    printf '%s' "$miss"; [ -z "$miss" ]
  }
  # the runner ignores its shell argument and always runs bash: the identity check must convict it under every non-bash shell
  mutate_runner() {
    local s miss="" want="" cp="$mtmp/suite-runner.sh"
    sed 's/^runsh(){ "\$1" "\$2"/runsh(){ bash "$2"/' "$0" > "$cp"
    if cmp -s "$0" "$cp"; then printf '  SKIP  %-58s mutation was a NO-OP\n' "the runner always runs bash"; MFAIL=1; return; fi
    for s in $SHELLS; do
      case "$s" in
        bash) ;;
        sh) case "$REF_SH" in bash:*) ;; *) want="$want $s" ;; esac ;;
        *) want="$want $s" ;;
      esac
    done
    [ -n "$want" ] || { printf '  n/a   %-58s no non-bash shell on this host (CI has dash and mksh)\n' "the runner always runs bash"; return; }
    # shellcheck disable=SC2086
    if miss=$(runner_verdict "$cp" $want); then printf '  ok    %-58s convicted under:%s\n' "the runner always runs bash" "$want"
    else printf '  XX    %-58s SURVIVED under:%s\n' "the runner always runs bash" "$miss"; MFAIL=1; fi
  }
  # the verdict itself: a child that never launches prints a FAIL line per shell and exits 2; runner_verdict must refuse it
  verdict_refuses_harness_error() {
    local cp="$mtmp/suite-nolaunch.sh" miss
    sed 's/^runsh(){ .*$/runsh(){ return 127; }/' "$0" > "$cp"
    if cmp -s "$0" "$cp"; then printf '  SKIP  %-58s mutation was a NO-OP\n' "runner_verdict refuses a harness error"; MFAIL=1; return; fi
    # shellcheck disable=SC2086
    if miss=$(runner_verdict "$cp" $SHELLS); then printf '  XX    %-58s HARNESS ERROR COUNTED AS A CONVICTION\n' "runner_verdict refuses a harness error"; MFAIL=1
    else printf '  ok    %-58s refused:%s\n' "runner_verdict refuses a harness error" "$miss"; fi
  }
  probe 'the child never launches' 's/^runsh(){ .*$/runsh(){ return 127; }/'
  verdict_refuses_harness_error
  mutate_runner
  echo
  [ "${MFAIL:-0}" = 0 ] && echo "ALL MUTATIONS BEHAVED" || { echo "PROBLEM: a mutation did not behave"; [ "${FAILED:-0}" -gt 1 ] || FAILED=1; }
fi

exit "${FAILED:-0}"
