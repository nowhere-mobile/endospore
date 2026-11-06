#!/usr/bin/env bash
# test-mediad-serve.sh [<nowhere_mediad.sh>] [--mutate] -- mediad's SERVE path is executed (NWP-20261112-27).
#
# WHY THIS IS COMMITTED. Everything nowhere_mediad.sh does after its sweep-only block -- the req read and its
# `rm -f "$REQ"`, the ERR-ARGS and non-numeric-uid guards, the uid floor (no leading zero, nothing under 10:
# NWP-20261117-30), pw, the files/ re-own, the hmac and chip-secret
# exports and the two `exec "$AGENT" mediad s3 ...` lines -- was executed by no test: test-mediad-sweep.sh stops at
# the sweep marker, test-launcher-env.sh checks only which conf keys are exported, and mediad_chip_secret_test.go
# greps the source. This launcher is why #106 was not cosmetic: its exec is a daemon that lives for the whole
# session, so a passphrase in its argv sat in `ps` from login to logoff. The edits that would pass every other
# check: "$pass" handed to the exec again; the pass file written with echo (a backslash or a leading -n is mangled,
# so mediad derives a different key and serves nothing); the req no longer consumed; the MEDIADIR arm dropped (the
# offline maps sealed to name#media are captured but never served, #129); the FIDO2 hmac or the chip secret put
# back in the environment as a value, or an empty chip secret staged; the uid floor dropped, so a req for uid 0
# mounts a profile's media over the gate's own storage and caches it in plaintext where no reap removes it.
#
# HOW. Each case stages the WHOLE script into its own scratch root with every absolute path rewritten into it
# (STAGING FAILED, exit 2, when the agent path or a parse no longer comes out right), and runs it under every shell
# found (each of bash, sh, dash and mksh, by name: a sh that links to bash is run as sh, in POSIX mode) with an
# empty /proc/mounts fixture. /system/bin/nowhere_agent becomes a stub that records its argv one per line, its env, and the CONTENTS of every argv element and env value
# that starts with @file:, then exits 0. chown, chcon, stat, umount and date are PATH stubs that record their
# arguments. A shell without a `print` builtin (bash, dash) gets the same shim as test-log-name-scrub.sh's
# PRINT_SHIM on the staged copy's line 2; mksh (the device's sh) uses its own.
#
# S4c (pass `-n`) is there because bash's echo leaves `x\\y` and `-n z` intact: only an argument that is wholly an
# option word is eaten, so without it the echo-writer mutant survives under bash (dash and mksh also mangle `x\\y`).
#
# This suite pins SHIPPED behaviour: its cases pass on main. What must fail is every mutant, under every shell.
#
#   bash test-mediad-serve.sh            # the cases
#   bash test-mediad-serve.sh --mutate   # ... plus mutations that must each CONVICT the suite under every shell
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_mediad.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

# Shells: every one of bash, sh, dash and mksh found, each run by the path its own name resolves to and tagged with
# that name. Never deduplicated by realpath: a sh that is a link to bash runs bash in POSIX mode, which is a
# different interpreter for this suite's purposes.
SHELLS=""
for cand in bash sh dash mksh; do
  p=$(command -v "$cand" 2>/dev/null) || continue
  case "$p" in /*) SHELLS="$SHELLS $p" ;; esac
done
[ -n "$SHELLS" ] || { echo "no POSIX shell found" >&2; exit 2; }

# The same shim as test-log-name-scrub.sh's PRINT_SHIM: bash and dash have no `print`; mksh (the device's sh) does.
PRINT_SHIM='print() { local nl=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) nl=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$nl" = 1 ]; then printf "%s\n" "$*"; else printf "%s" "$*"; fi; }'

# Fixed answers of the stat stub: what chown and chcon must then be handed.
OWNER=10077:10077
LABEL=u:object_r:app_data_file:s0:c77,c256,c512,c768

# ---- stubs ----------------------------------------------------------------------------------------------------
mkdir -p "$W/stubbin"
for s in chown chcon umount; do
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$TST_REC/%s.calls"\nexit 0\n' "$s" > "$W/stubbin/$s"
done
cat > "$W/stubbin/stat" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "\$TST_REC/stat.calls"
case "\$2" in %u:%g) echo $OWNER ;; %C) echo $LABEL ;; *) exit 1 ;; esac
EOF
printf '#!/bin/sh\necho DATE\n' > "$W/stubbin/date"
chmod +x "$W/stubbin/"*

# The agent stub's body; stage() bakes the case root in as R. It never writes to stdout: the exec appends that to
# the log.
AGENT_BODY='i=0; : > "$R/agent.argv"
for a; do
  i=$((i + 1)); printf "%s\n" "$a" >> "$R/agent.argv"
  case "$a" in @file:*) cat "${a#@file:}" > "$R/agent.arg.$i" ;; esac
done
env > "$R/agent.env"
while IFS= read -r l; do
  k=${l%%=*}; v=${l#*=}
  case "$v" in @file:*) cat "${v#@file:}" > "$R/agent.envf.$k" ;; esac
done < "$R/agent.env"
exit 0'

# ---- helpers --------------------------------------------------------------------------------------------------
FAILS=0
ok() { [ -n "${QUIET:-}" ] || printf '  ok    %s\n' "$1"; }
no() { FAILS=$((FAILS + 1)); printf '  FAIL  %s\n' "$1"; }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
staging_fail() { echo "STAGING FAILED: $1 in $SUT" >&2; exit 2; }

# stage <shell> <R>: the whole script with every absolute path rewritten into R, the print shim on line 2 for a
# shell without a print builtin, the agent stub, and an empty mounts table. No conf is staged.
stage() {
  local sh="$1" R="$2" shim=""
  mkdir -p "$R/run" "$R/stub" "$R/proc" "$R/data/nowhere/state" "$R/data/user/10/com.nowhere.chooser"
  case "$("$sh" -c 'command -v print' 2>/dev/null)" in print) ;; *) shim="eval '$PRINT_SHIM'" ;; esac
  sed -e 's@/system/etc/nowhere/nowhere.conf@__R__/system/etc/nowhere/nowhere.conf@g' \
      -e 's@/system/bin/nowhere_agent@__R__/stub/nowhere_agent@g' \
      -e 's@/proc/mounts@__R__/proc/mounts@g' \
      -e 's@/data/@__R__/data/@g' \
      -e "s@__R__@$R@g" "$SUT" \
    | SHIM="$shim" awk 'NR==1 && ENVIRON["SHIM"] != "" {print; print ENVIRON["SHIM"]; next} {print}' > "$R/run/mediad.sh"
  { printf "#!/bin/sh\nR='%s'\n" "$R"; printf '%s\n' "$AGENT_BODY"; } > "$R/stub/nowhere_agent"
  chmod +x "$R/stub/nowhere_agent"
  : > "$R/proc/mounts"
  local body
  body=$(cat "$R/run/mediad.sh")
  has "$body" "AGENT=$R/stub/nowhere_agent" || staging_fail "the agent path"
  has "$body" "/system/bin/nowhere_agent" && staging_fail "an unrewritten agent path"
  has "$body" "$R/proc/mounts" || staging_fail "the mounts table"
  "$sh" -n "$R/run/mediad.sh" 2>/dev/null || staging_fail "a staged copy that does not parse under $sh"
}

# req <R> <name> <pass> <uid> [<sesec>]: the four-line request, written with printf (never echo).
req() {
  printf '%s\n%s\n%s\n%s\n' "$2" "$3" "$4" "${5:-}" > "$1/data/nowhere/state/mediad.req"
  chmod 600 "$1/data/nowhere/state/mediad.req"
}

run() { # run <shell> <R>
  ( cd "$2" && env -i PATH="$W/stubbin:/usr/bin:/bin" TMPDIR="$W" TST_REC="$2" \
      timeout 60 "$1" "$2/run/mediad.sh" ) >/dev/null 2>&1
}

logof() { cat "$1/data/nowhere/mediad.log" 2>/dev/null; }

# bytes_are <file> <text>: <file> holds exactly <text> plus one newline (what `print -r --` writes).
bytes_are() {
  local exp
  exp=$(mktemp -p "$W")
  printf '%s\n' "$2" > "$exp"
  cmp -s "$exp" "$1"
}

# argv_line <R> <n>: the agent's nth argument.
argv_line() { sed -n "${2}p" "$1/agent.argv" 2>/dev/null; }
argc() { if [ -f "$1/agent.argv" ]; then wc -l < "$1/agent.argv" | tr -d ' '; else echo none; fi; }

# no_exec <label> <R> <shell>
no_exec() {
  if [ ! -e "$2/agent.argv" ]; then ok "$1: the agent is not exec'd ($3)"
  else no "$1: the agent was exec'd ($3)"; fi
}
req_gone() {
  if [ ! -e "$2/data/nowhere/state/mediad.req" ]; then ok "$1: the req is removed ($3)"
  else no "$1: the req is still there ($3)"; fi
}

# refused <label> <R> <uid> <reason> <shell>: the uid floor refused the req, with its reason, before any mkdir,
# chown, chcon or umount (NWP-20261117-30).
refused() {
  local label="$1" R="$2" u="$3" why="$4" sh="$5" L s calls=""
  L=$(logof "$R")
  if has "$L" "[mediad] uid $u refused ($why"; then ok "$label: refused, $why ($sh)"
  else no "$label: not refused with the reason $why ($sh)"; fi
  req_gone "$label" "$R" "$sh"; no_exec "$label" "$R" "$sh"
  if [ ! -e "$R/data/user/$u" ]; then ok "$label: no data/user/$u is made ($sh)"
  else no "$label: data/user/$u was made ($sh)"; fi
  for s in chown chcon umount; do [ -s "$R/$s.calls" ] && calls="$calls $s"; done
  if [ -z "$calls" ]; then ok "$label: no chown, chcon or umount call ($sh)"
  else no "$label: called$calls ($sh)"; fi
}

# pass_absent <label> <R> <pass> <shell>: no argv element and no env line holds the pass. An exact match always; a
# substring only for a pass long enough not to occur by chance in a scratch path.
pass_absent() {
  local label="$1" R="$2" pass="$3" sh="$4" l hit=""
  while IFS= read -r l; do
    [ "$l" = "$pass" ] && hit=argv
    [ "${#pass}" -ge 4 ] && has "$l" "$pass" && hit=argv
  done < "$R/agent.argv"
  while IFS= read -r l; do
    [ "${l#*=}" = "$pass" ] && hit="${hit:+$hit+}env"
    [ "${#pass}" -ge 4 ] && has "$l" "$pass" && hit="${hit:+$hit+}env"
  done < "$R/agent.env"
  if [ -z "$hit" ]; then ok "$label: the pass is in no argv element or env value ($sh)"
  else no "$label: the pass is in the agent's $hit ($sh)"; fi
}

# staged_pw <label> <R> <arg> <text> <shell> <what>: <arg> is @file:<state>/.pw.mediad.XXXXXX and the file the stub
# copied out of it holds exactly <text>.
staged_pw() {
  local label="$1" R="$2" arg="$3" text="$4" sh="$5" copy="$6"
  case "$arg" in
    "@file:$R/data/nowhere/state/.pw.mediad."??????) ok "$label: an @file: path under the state dir ($sh)" ;;
    *) no "$label: not an @file: path under the state dir ($sh)"; return ;;
  esac
  if bytes_are "$copy" "$text"; then ok "$label: the staged file holds the value byte for byte ($sh)"
  else no "$label: the staged file does not hold the value byte for byte ($sh)"; fi
}

mode700() {
  if [ -d "$2" ] && [ "$(stat -c %a "$2")" = 700 ]; then ok "$1: the cache dir exists, mode 700 ($3)"
  else no "$1: the cache dir is missing or not mode 700 ($3)"; fi
}

# serve <label> <shell> <pass> <with-media>: S4 (and S5 with <with-media>=yes) for one pass. Leaves the root in RS.
RS=""
serve() {
  local label="$1" sh="$2" pass="$3" media="$4" R n want L u
  R=$(mktemp -d -p "$W"); RS="$R"; stage "$sh" "$R"
  [ "$media" = yes ] && mkdir -p "$R/data/media/10"
  req "$R" 'a "b" c' "$pass" 10
  run "$sh" "$R"
  u="$R/data/user/10"
  if [ ! -f "$R/agent.argv" ]; then no "$label: the agent was not exec'd ($sh)"; return; fi
  want=6; [ "$media" = yes ] && want=8
  n=$(argc "$R")
  if [ "$n" = "$want" ]; then ok "$label: $want arguments ($sh)"; else no "$label: $n arguments, not $want ($sh)"; fi
  if [ "$(argv_line "$R" 1)" = mediad ] && [ "$(argv_line "$R" 2)" = s3 ] && [ "$(argv_line "$R" 3)" = 'a "b" c' ] \
     && [ "$(argv_line "$R" 5)" = "$u" ] && [ "$(argv_line "$R" 6)" = "$u/com.nowhere.chooser/files/.nowhere-media" ]
  then ok "$label: argv is mediad s3 <name> <pw> <userdir> <cache> ($sh)"
  else no "$label: argv is not mediad s3 <name> <pw> <userdir> <cache> ($sh)"; fi
  staged_pw "$label pass" "$R" "$(argv_line "$R" 4)" "$pass" "$sh" "$R/agent.arg.4"
  pass_absent "$label" "$R" "$pass" "$sh"
  req_gone "$label" "$R" "$sh"
  mode700 "$label" "$u/com.nowhere.chooser/files/.nowhere-media" "$sh"
  L=$(logof "$R")
  if has "$L" '[mediad] start "a \"b\" c" -> user 10 DATE'; then ok "$label: the start line holds the name as one quoted token ($sh)"
  else no "$label: the start line does not hold the name as one quoted token ($sh)"; fi
  if [ ! -s "$R/umount.calls" ]; then ok "$label: an empty mounts table detaches nothing ($sh)"
  else no "$label: umount was called on an empty mounts table ($sh)"; fi
  if [ "$media" = yes ]; then
    if [ "$(argv_line "$R" 7)" = "$R/data/media/10" ] \
       && [ "$(argv_line "$R" 8)" = "$u/com.nowhere.chooser/files/.nowhere-media-ext" ]
    then ok "$label: argv ends with <mediadir> <mediacache> ($sh)"
    else no "$label: argv does not end with <mediadir> <mediacache> ($sh)"; fi
    mode700 "$label ext" "$u/com.nowhere.chooser/files/.nowhere-media-ext" "$sh"
  fi
}

# envcase <shell> <sesec> <hmac>: one serving run with a chip secret and/or a FIDO2 hmac stash. Leaves the root in RS.
envcase() {
  local sh="$1" R
  R=$(mktemp -d -p "$W"); RS="$R"; stage "$sh" "$R"
  [ -n "$3" ] && printf '%s\n' "$3" > "$R/data/nowhere/state/.fido2hmac"
  req "$R" envcase pw1 10 "$2"
  run "$sh" "$R"
}

# env_value <R> <KEY>: the value of KEY in the agent's env, or the word ABSENT.
env_value() {
  local l v=ABSENT
  [ -f "$1/agent.env" ] || { echo NOEXEC; return; }
  while IFS= read -r l; do case "$l" in "$2="*) v=${l#*=} ;; esac; done < "$1/agent.env"
  printf '%s' "$v"
}

# ---- the cases ------------------------------------------------------------------------------------------------
suite() {
  local sh l R L v
  for sh in $SHELLS; do
    l=$(basename "$sh")

    # S1: no req.
    R=$(mktemp -d -p "$W"); stage "$sh" "$R"; run "$sh" "$R"; L=$(logof "$R")
    if has "$L" '[mediad] no req'; then ok "S1 no req: logged ($l)"; else no "S1 no req: not logged ($l)"; fi
    no_exec "S1 no req" "$R" "$l"

    # S2 / S2b: an empty name, an empty uid.
    R=$(mktemp -d -p "$W"); stage "$sh" "$R"; req "$R" '' pw1 10; run "$sh" "$R"; L=$(logof "$R")
    if has "$L" '[mediad] ERR-ARGS'; then ok "S2 empty name: ERR-ARGS ($l)"; else no "S2 empty name: no ERR-ARGS ($l)"; fi
    req_gone "S2 empty name" "$R" "$l"; no_exec "S2 empty name" "$R" "$l"
    R=$(mktemp -d -p "$W"); stage "$sh" "$R"; req "$R" s2b pw1 ''; run "$sh" "$R"; L=$(logof "$R")
    if has "$L" '[mediad] ERR-ARGS'; then ok "S2b empty uid: ERR-ARGS ($l)"; else no "S2b empty uid: no ERR-ARGS ($l)"; fi
    req_gone "S2b empty uid" "$R" "$l"; no_exec "S2b empty uid" "$R" "$l"

    # S3: a non-numeric uid.
    R=$(mktemp -d -p "$W"); stage "$sh" "$R"; req "$R" s3 pw1 1x; run "$sh" "$R"; L=$(logof "$R")
    if has "$L" '[mediad] non-numeric uid rejected'; then ok "S3 uid 1x: rejected ($l)"; else no "S3 uid 1x: not rejected ($l)"; fi
    req_gone "S3 uid 1x" "$R" "$l"; no_exec "S3 uid 1x" "$R" "$l"

    # S9 / S9a / S9b / S9c: the uid floor (NWP-20261117-30), as roamd's shared guard: nothing under 10, no leading zero.
    R=$(mktemp -d -p "$W"); stage "$sh" "$R"; req "$R" s9 pw1 0; run "$sh" "$R"
    refused "S9 uid 0" "$R" 0 'under 10' "$l"
    R=$(mktemp -d -p "$W"); stage "$sh" "$R"; req "$R" s9a pw1 9; run "$sh" "$R"
    refused "S9a uid 9" "$R" 9 'under 10' "$l"
    R=$(mktemp -d -p "$W"); stage "$sh" "$R"; req "$R" s9b pw1 010; run "$sh" "$R"
    refused "S9b uid 010" "$R" 010 'leading zero' "$l"
    R=$(mktemp -d -p "$W"); stage "$sh" "$R"; req "$R" s9c pw1 00; run "$sh" "$R"
    refused "S9c uid 00" "$R" 00 'leading zero' "$l"

    # S4 / S4b / S4c: a valid req without /data/media/<uid>; S8 on the S4 root.
    serve "S4 x\\\\y" "$l" 'x\\y' no
    R="$RS"
    if [ "$(cat "$R/stat.calls" 2>/dev/null)" = "-c %u:%g $R/data/user/10/com.nowhere.chooser
-c %C $R/data/user/10/com.nowhere.chooser" ]
    then ok "S8 files/ re-own: stat reads the package dir ($l)"; else no "S8 files/ re-own: stat does not read the package dir ($l)"; fi
    if [ "$(cat "$R/chown.calls" 2>/dev/null)" = "$OWNER $R/data/user/10/com.nowhere.chooser/files" ]
    then ok "S8 files/ re-own: chown hands files/ the package dir's uid:gid ($l)"; else no "S8 files/ re-own: chown does not hand files/ the package dir's uid:gid ($l)"; fi
    if [ "$(cat "$R/chcon.calls" 2>/dev/null)" = "$LABEL $R/data/user/10/com.nowhere.chooser/files" ]
    then ok "S8 files/ re-own: chcon hands files/ the package dir's context ($l)"; else no "S8 files/ re-own: chcon does not hand files/ the package dir's context ($l)"; fi
    serve "S4b -n z" "$l" '-n z' no
    serve "S4c -n" "$l" '-n' no

    # S5: /data/media/<uid> present.
    serve "S5 media" "$l" 'x\\y' yes

    # S6 / S6b: the chip secret, present and empty.
    envcase "$l" 0a1b ''; R="$RS"; v=$(env_value "$R" NOWHERE_SE_SECRET)
    staged_pw "S6 chip secret" "$R" "$v" 0a1b "$l" "$R/agent.envf.NOWHERE_SE_SECRET"
    envcase "$l" '' ''; R="$RS"; v=$(env_value "$R" NOWHERE_SE_SECRET)
    if [ "$v" = ABSENT ]; then ok "S6b no chip secret: NOWHERE_SE_SECRET is not in env ($l)"
    else no "S6b no chip secret: NOWHERE_SE_SECRET is in env ($l)"; fi

    # S7 / S7b: the FIDO2 hmac stash, present and absent (NWP-20261112-29 stages it through pw).
    envcase "$l" '' deadbeef; R="$RS"; v=$(env_value "$R" NOWHERE_FIDO2_HMAC)
    staged_pw "S7 fido2 hmac" "$R" "$v" deadbeef "$l" "$R/agent.envf.NOWHERE_FIDO2_HMAC"
    v=$(env_value "$R" NOWHERE_SE_SECRET)
    if [ "$v" = ABSENT ]; then ok "S7 fido2 hmac: no chip secret alongside ($l)"; else no "S7 fido2 hmac: a chip secret alongside ($l)"; fi
    envcase "$l" '' ''; R="$RS"; v=$(env_value "$R" NOWHERE_FIDO2_HMAC)
    if [ "$v" = ABSENT ]; then ok "S7b no hmac stash: NOWHERE_FIDO2_HMAC is not in env ($l)"
    else no "S7b no hmac stash: NOWHERE_FIDO2_HMAC is in env ($l)"; fi
  done
}

suite
if [ "$FAILS" -gt 0 ]; then echo "FAILED: $FAILS check(s)"; exit 1; fi
echo "PASS: mediad serve cases ($(for s in $SHELLS; do printf '%s ' "$(basename "$s")"; done | sed 's/ $//'))"
[ "$MUTATE" = yes ] || exit 0

# ---- mutants --------------------------------------------------------------------------------------------------
MFAILS=0

# failed_on <output> <case> <shell>: true when ONE line of <output> is `  FAIL  <case> ... (<shell>)` -- the case
# and the shell tag on the same line, the tag at its end, so a FAIL under one shell never convicts another.
failed_on() {
  local line
  while IFS= read -r line; do
    case "$line" in "  FAIL  $2 "*"($3)") return 0 ;; esac
  done <<EOF
$1
EOF
  return 1
}
_mixed='  FAIL  S4 x pass (bash)
  ok    S4 x pass (mksh)'
if ! failed_on "$_mixed" 'S4' bash || failed_on "$_mixed" 'S4' mksh; then
  echo "  BROKEN    failed_on lets one shell's FAIL convict another"; MFAILS=$((MFAILS + 1))
fi
if failed_on '  FAIL  S4b -n z: x (bash)' 'S4' bash; then
  echo "  BROKEN    failed_on lets S4b convict S4"; MFAILS=$((MFAILS + 1))
fi

# convict_each <label> <copy> <case>...: EVERY shell found must fail EVERY named case on its own line.
convict_each() {
  local label="$1" copy="$2" out rc e sh l miss=""; shift 2
  if cmp -s "$SUT" "$copy"; then echo "  INERT     $label -- the mutation changed nothing"; MFAILS=$((MFAILS + 1)); return; fi
  out=$(TMPDIR="$W" bash "$0" "$copy" 2>&1); rc=$?
  if [ "$rc" -eq 2 ]; then echo "  BROKEN    $label -- the mutant no longer stages or parses"; MFAILS=$((MFAILS + 1)); return; fi
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $label"; MFAILS=$((MFAILS + 1)); return; fi
  for sh in $SHELLS; do
    l=$(basename "$sh")
    for e in "$@"; do
      failed_on "$out" "$e" "$l" || miss="$miss $e/$l"
    done
  done
  if [ -n "$miss" ]; then echo "  UNCONVICTED $label -- it failed, but not on:$miss"; MFAILS=$((MFAILS + 1)); return; fi
  echo "  convicted $label (every shell)"
}
# sedmut_each <label> <sed-program> <case>...: the program must change exactly one line.
sedmut_each() {
  local label="$1" prog="$2" copy n; shift 2
  copy=$(mktemp -p "$W")
  sed -e "$prog" "$SUT" > "$copy"
  n=$(diff "$SUT" "$copy" | grep -c '^<')
  if [ "$n" -gt 1 ]; then echo "  BROKEN    $label -- the mutation changed $n lines, not one"; MFAILS=$((MFAILS + 1)); return; fi
  convict_each "$label" "$copy" "$@"
}

sedmut_each 'the exec without MEDIADIR hands the agent "$pass"' \
  '/^exec "\$AGENT" mediad s3 "\$name" "\$(pw "\$pass")" "\$USERDIR" "\$CACHE" >> /s/"\$(pw "\$pass")"/"$pass"/' \
  'S4' 'S4b' 'S4c'
sedmut_each 'the exec with MEDIADIR hands the agent "$pass"' \
  '/"\$MEDIADIR" "\$MEDIACACHE" >> /s/"\$(pw "\$pass")"/"$pass"/' 'S5'
sedmut_each "pw writes the pass file with echo" \
  's/print -r -- "\$1" > "\$f"/echo "$1" > "$f"/' 'S4c'
sedmut_each 'the req is no longer removed' '/^rm -f "\$REQ"/d' 'S2' 'S2b' 'S3' 'S4'
sedmut_each 'the non-numeric uid guard removed' '/^case "\$uid" in \*\[!0-9\]\*)/d' 'S3'
sedmut_each 'the MEDIADIR arm never taken' 's/^if \[ -d "\$MEDIADIR" \]; then$/if false; then/' 'S5'
sedmut_each 'the hmac exported as a value again' \
  's/NOWHERE_FIDO2_HMAC="\$(pw "\$(cat "\$STATE\/.fido2hmac")")"/NOWHERE_FIDO2_HMAC="$(cat "$STATE\/.fido2hmac")"/' 'S7'
sedmut_each 'an empty chip secret staged' 's/^\[ -n "\$sesec" \] && export/export/' 'S6b'
sedmut_each 'F1 the uid floor -ge 10 line deleted' '/^\[ "\$uid" -ge 10 \] ||/d' 'S9' 'S9a'
sedmut_each 'F2 the uid floor lowered to -ge 1' 's/^\[ "\$uid" -ge 10 \]/[ "$uid" -ge 1 ]/' 'S9a'
sedmut_each 'F3 the leading-zero guard deleted' '/^case "\$uid" in 0?\*)/d' 'S9b' 'S9c'
sedmut_each 'F4 the non-numeric guard moved below the -ge 10 line' \
  '/^case "\$uid" in \*\[!0-9\]\*)/{h;d};/^\[ "\$uid" -ge 10 \] ||/G' 'S3'

if [ "$MFAILS" -gt 0 ]; then echo "FAILED: $MFAILS mutant(s) not convicted"; exit 1; fi
echo "PASS: all mutants convicted"
