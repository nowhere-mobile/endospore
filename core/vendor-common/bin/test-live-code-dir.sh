#!/usr/bin/env bash
# test-live-code-dir.sh [<nowhere_roamd.sh>] [--mutate] -- which code dir #apps seals, and what it stages.
#
# WHY THIS IS COMMITTED. appcode_seal decides what app CODE rides the name#apps scope from two helpers in
# roamd: live_code_dir (a package's current code dir, from live `dumpsys package`) and stage_live_apks (copy
# that dir's .apk files into the staging dir, echoing their basenames). Both fail quiet by design -- an
# empty answer means "nothing to seal" -- so a wrong answer is invisible on a device: an updated system app
# sealed on every logoff (app.grapheneos.gmscompat.config is exactly that shape, device-checked on lynx
# 2026-08-05), or a manifest naming an APK that was never copied. Neither had a test.
#
# What is pinned: only an existing dir under /data/app counts; SYSTEM in the first flags line skips (that is
# how UPDATED_SYSTEM_APP is caught); the FIRST codePath wins (the Packages section, not a later 'Hidden
# system packages' block); a dump over 128 KiB resolves like a small one (NWP-20261113-01: it is streamed, never
# an argument); staging copies exactly the top-level .apk files byte-identical, names only what it copied, and
# never touches the literal glob of an empty dir.
#
#   bash test-live-code-dir.sh            # the truth table
#   bash test-live-code-dir.sh --mutate   # ... plus mutations that must each CONVICT the suite
#
# Host-run, no device: dumpsys is a shell-function stub reading fixtures, and only the `/data/app/*` case
# pattern is rewritten to a temp root. The logic under test is otherwise byte-for-byte roamd's.
#
# THE DEVICE'S ARGUMENT LIMIT, EMULATED (NWP-20261113-01). The generated sut.sh shadows `printf` with a function
# that refuses (`printf: Argument list too long` on stderr, nothing on stdout, status 1) when any argument is
# longer than 131072 bytes. On the device /system/bin/sh is mksh, whose printf is /system/bin/printf: an exec,
# so the kernel bounds each argument (MAX_ARG_STRLEN) and refuses a longer one with E2BIG -- VLC's 365,826-byte
# dump was. Under bash and dash printf is a builtin and nothing would fail, so without the function a dump-sized
# printf would pass here and break only on the device. Every live_code_dir and stage_live_apks row runs under
# every shell found (bash, sh, dash, mksh), each line tagged [shell]; the farm host has bash and sh only, the CI
# runner all four.
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# --- extraction: the helpers, by name (stage_apk_copy is stage_live_apks's copy, NWP-20261128-09) -------------
FNS=$(sed -n '/^live_code_dir() {$/,/^}$/p; /^stage_apk_copy() {$/,/^}$/p; /^stage_live_apks() {$/,/^}$/p' "$SUT")
case "$FNS" in
  *'live_code_dir() {'*'stage_apk_copy() {'*'stage_live_apks() {'*) ;;
  *) echo "EXTRACTION FAILED -- live_code_dir, stage_apk_copy or stage_live_apks moved in $SUT" >&2; exit 2 ;;
esac

# Rewrite ONLY the case pattern. The body also says codePath=/data/app/... in a comment; that must stay put,
# so a global /data/app/ rewrite would be the wrong edit even though it would run.
REW=$(printf '%s\n' "$FNS" | sed 's#in /data/app/\*)#in '"$T"'/data/app/*)#')
CHANGED=$(diff <(printf '%s\n' "$FNS") <(printf '%s\n' "$REW") | grep -cE '^>')
[ "$CHANGED" = 1 ] || { echo "EXTRACTION FAILED -- the /data/app case pattern rewrote $CHANGED lines, want 1" >&2; exit 2; }
case "$REW" in
  *"in $T/data/app/*)"*) ;;
  *) echo "EXTRACTION FAILED -- the rewritten case pattern is missing" >&2; exit 2 ;;
esac

{
  echo "LC_ALL=C; export LC_ALL"
  echo "printf() { local pa; for pa in \"\$@\"; do [ \"\${#pa}\" -gt 131072 ] && { echo 'printf: Argument list too long' >&2; return 1; }; done; command printf \"\$@\"; }"
  echo "LOG='$T/log'"
  echo "dumpsys() { [ \"\$1\" = package ] || return 0; [ -f '$T/dumps/'\"\$2\" ] && cat '$T/dumps/'\"\$2\"; return 0; }"
  printf '%s\n' "$REW"
} > "$T/sut.sh"

# --- fixtures ----------------------------------------------------------------------------------------------
mkdir -p "$T/dumps" "$T/system/app/Clock"
U="$T/data/app/~~Ab==/com.x-Cd=="         # an ordinary user app
G="$T/data/app/~~Gm==/app.gos.config-Ef=="   # an updated system app (gmscompat.config's shape)
F1="$T/data/app/~~F1==/com.first-A1=="       # the Packages-section codePath
F2="$T/data/app/~~F2==/com.first-B2=="       # a later block's codePath
mkdir -p "$U" "$G" "$F1" "$F2"

cat > "$T/dumps/com.x" <<EOF
Packages:
  Package [com.x] (1a2b3c):
    userId=10123
    codePath=$U
    resourcePath=$U
    flags=[ HAS_CODE ALLOW_CLEAR_USER_DATA ALLOW_BACKUP ]
    privateFlags=[ PRIVATE_FLAG_ACTIVITIES_RESIZE_MODE_RESIZEABLE ]
EOF
cat > "$T/dumps/app.gos.config" <<EOF
Packages:
  Package [app.gos.config] (4d5e6f):
    codePath=$G
    flags=[ SYSTEM HAS_CODE ALLOW_CLEAR_USER_DATA UPDATED_SYSTEM_APP ]
EOF
# A codePath OUTSIDE data/app whose dir exists, with no SYSTEM flag: only the path arm can reject it.
cat > "$T/dumps/com.sysapp" <<EOF
Packages:
  Package [com.sysapp] (7a8b9c):
    codePath=$T/system/app/Clock
    flags=[ HAS_CODE ALLOW_CLEAR_USER_DATA ]
EOF
cat > "$T/dumps/com.gone" <<EOF
Packages:
  Package [com.gone] (0d1e2f):
    codePath=$T/data/app/~~Zz==/com.gone-Yy==
    flags=[ HAS_CODE ALLOW_CLEAR_USER_DATA ]
EOF
cat > "$T/dumps/com.first" <<EOF
Packages:
  Package [com.first] (3a4b5c):
    codePath=$F1
    flags=[ HAS_CODE ALLOW_CLEAR_USER_DATA ]

Hidden system packages:
  Package [com.first] (6d7e8f):
    codePath=$F2
    flags=[ HAS_CODE ALLOW_CLEAR_USER_DATA ]
EOF

# NWP-20261113-01: dumps over 300 KiB, the size class of VLC's (365,826 bytes on lynx). Thousands of
# intent-filter-like lines (none holds codePath= or flags=[) sit BEFORE and AFTER the Package block, so neither
# field is near either end of the dump.
BG="$T/data/app/~~Bg==/com.big-Bh=="         # the big user app
BS="$T/data/app/~~Bs==/com.bigsys-Bt=="      # the big updated system app
BF1="$T/data/app/~~Bf1==/com.bigfirst-A1=="  # the big dump's Packages-section codePath
BF2="$T/data/app/~~Bf2==/com.bigfirst-B2=="  # its later block's codePath
mkdir -p "$BG" "$BS" "$BF1" "$BF2"
awk 'BEGIN { for (i = 0; i < 1000; i++) {
  printf "        Action: \"android.intent.action.VIEW.%05d\"\n", i
  printf "        Category: \"android.intent.category.BROWSABLE\"\n"
  printf "        Scheme: \"content\"\n"
  printf "        Type: \"video/x-matroska-%05d\"\n", i } }' > "$T/filler"
{ cat "$T/filler"
  printf 'Packages:\n  Package [com.big] (1b2b3b):\n    userId=10200\n    codePath=%s\n    resourcePath=%s\n' "$BG" "$BG"
  printf '    flags=[ HAS_CODE ALLOW_CLEAR_USER_DATA ALLOW_BACKUP LARGE_HEAP ]\n'
  cat "$T/filler"; } > "$T/dumps/com.big"
{ cat "$T/filler"
  printf 'Packages:\n  Package [com.bigsys] (4b5b6b):\n    codePath=%s\n' "$BS"
  printf '    flags=[ SYSTEM HAS_CODE ALLOW_CLEAR_USER_DATA UPDATED_SYSTEM_APP ]\n'
  cat "$T/filler"; } > "$T/dumps/com.bigsys"
{ cat "$T/filler"
  printf 'Packages:\n  Package [com.bigfirst] (7b8b9b):\n    codePath=%s\n    flags=[ HAS_CODE ]\n' "$BF1"
  cat "$T/filler"
  printf '\nHidden system packages:\n  Package [com.bigfirst] (0c1c2c):\n    codePath=%s\n    flags=[ HAS_CODE ]\n' "$BF2"
  cat "$T/filler"; } > "$T/dumps/com.bigfirst"

# --- harness -----------------------------------------------------------------------------------------------
# The trailing x keeps a trailing newline visible: "prints the path exactly" means no newline either. stderr
# lands in $T/lcd_err (lcd runs in a command substitution, so a variable would not survive) for lcd_quiet.
lcd(){ local o; o=$("${LCD_SH:-bash}" -c '. "$1"; live_code_dir "$2"; printf x' _ "$T/sut.sh" "$1" 2>"$T/lcd_err"); printf '%s' "${o%x}"; }
lcd_is(){ local got; got=$(lcd "$2"; printf x); got=${got%x}
          [ "$got" = "$1" ] && ok "$3" || no "$3 -- got '$got', want '$1'"; }
# lcd_quiet <label>: the last lcd call hit no argument limit. On the old body the SYSTEM row's stdout is empty
# either way (the refused printf empties the codePath too), so this is the assertion that sees it.
lcd_quiet(){ local e; e=$(grep -m1 'Argument list too long' "$T/lcd_err")
             [ -z "$e" ] && ok "$1" || no "$1 -- stderr: $e"; }

# Every shell found runs every row (the device's /system/bin/sh is mksh); each line carries its shell as [sh].
W6_SHELLS=""
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && W6_SHELLS="$W6_SHELLS $s"; done
# NWP-20261108-04: `cp` is a function when $T/cpfail (the basename whose copy writes half and fails), $T/cpshort
# (half, exit 0) or $T/cpvanish (the source is removed just before its copy) names a file. The status of
# stage_live_apks lands in $T/sla_rc (sla runs in a command substitution, so a variable would not survive).
sla(){ local o; : > "$T/log"
       o=$(T="$T" "${SLA_SH:-bash}" -c 'cp() { local b; b=$(basename "$1")
                           if [ -f "$T/cpfail" ] && [ "$b" = "$(cat "$T/cpfail")" ]; then head -c $(( $(wc -c < "$1") / 2 )) "$1" > "$2"; return 1; fi
                           if [ -f "$T/cpshort" ] && [ "$b" = "$(cat "$T/cpshort")" ]; then head -c $(( $(wc -c < "$1") / 2 )) "$1" > "$2"; return 0; fi
                           if [ -f "$T/cpvanish" ] && [ "$b" = "$(cat "$T/cpvanish")" ]; then rm -f "$(dirname "$1")/c_split.apk"; fi
                           command cp "$@"; }
                  . "$1"; stage_live_apks "$2" "$3"; echo "$?" > "$T/sla_rc"; printf x' _ "$T/sut.sh" "$1" "$2")
       printf '%s' "${o%x}"; }

echo "== live_code_dir: only an existing, non-system dir under /data/app =="
for d in com.big com.bigsys com.bigfirst; do
  sz=$(wc -c < "$T/dumps/$d" | tr -d ' ')
  [ "$sz" -gt 307200 ] && ok "fixture $d is over 300 KiB ($sz bytes)" || no "fixture $d is $sz bytes, want over 307200"
done
for LCD_SH in $W6_SHELLS; do
  lcd_is "$U" com.x            "[$LCD_SH] user app, dir exists -> its codePath exactly, no trailing newline"
  lcd_is ""   app.gos.config   "[$LCD_SH] updated system app (codePath under data/app, flags SYSTEM ... UPDATED_SYSTEM_APP) -> nothing"
  lcd_is ""   com.sysapp       "[$LCD_SH] codePath outside data/app (dir exists, no SYSTEM flag) -> nothing"
  lcd_is ""   com.gone         "[$LCD_SH] codePath under data/app whose dir does not exist -> nothing"
  lcd_is ""   com.absent       "[$LCD_SH] not installed (dumpsys prints nothing) -> nothing"
  lcd_is "$F1" com.first       "[$LCD_SH] two codePath lines (Packages, then Hidden system packages) -> the FIRST wins"
  lcd_is "$BG" com.big         "[$LCD_SH] dump over 300 KiB, no SYSTEM -> its codePath exactly"
  lcd_quiet                    "[$LCD_SH] dump over 300 KiB, no SYSTEM -> no argument refused"
  lcd_is ""   com.bigsys       "[$LCD_SH] dump over 300 KiB, SYSTEM in the first flags line -> nothing"
  lcd_quiet                    "[$LCD_SH] dump over 300 KiB, SYSTEM in the first flags line -> no argument refused"
  lcd_is "$BF1" com.bigfirst   "[$LCD_SH] dump over 300 KiB, two codePath lines -> the FIRST wins"
  lcd_quiet                    "[$LCD_SH] dump over 300 KiB, two codePath lines -> no argument refused"
done
LCD_SH=bash
# NO pkgFlags ROW. roamd's first-`flags=[`-line match is case-sensitive, so it does NOT see an older
# `pkgFlags=[ SYSTEM ...` line (capital F) -- checked before this row was dropped. That is not a defect:
# the skip reads the Packages section's `flags=[` line, which is the line live_code_dir's lynx device check saw
# carry SYSTEM for gmscompat.config. Asserting a skip that does not exist would be a false pin.

echo "== stage_live_apks: exactly the top-level .apk files, named only when copied =="
S="$T/code"; D="$T/stage"
mkdir -p "$S/lib/arm64" "$S/oat" "$D"
printf 'base-bytes\001\002' > "$S/base.apk"
printf 'split-bytes\003'    > "$S/split_config.arm64_v8a.apk"
printf 'lib'                > "$S/lib/arm64/libx.so"
printf 'oat'                > "$S/oat/x.apk"
for SLA_SH in $W6_SHELLS; do rm -rf "$D" "$T/stage2" "$T/stage3"; mkdir -p "$D" "$T/stage2" "$T/stage3"
  got=$(sla "$S" "$D")
  want=$(printf '\tbase.apk\tsplit_config.arm64_v8a.apk')
  [ "$got" = "$want" ] && ok "[$SLA_SH] names are tab-prefixed, in glob order" || no "[$SLA_SH] names -- got '$got', want '$want'"
  lst=$(cd "$D" && ls -A | tr '\n' ' ')
  [ "$lst" = "base.apk split_config.arm64_v8a.apk " ] && ok "[$SLA_SH] only the two top-level .apk files land in the dest" \
    || no "[$SLA_SH] dest holds '$lst', want 'base.apk split_config.arm64_v8a.apk '"
  cmp -s "$S/base.apk" "$D/base.apk" && cmp -s "$S/split_config.arm64_v8a.apk" "$D/split_config.arm64_v8a.apk" \
    && ok "[$SLA_SH] both copies are byte-identical" || no "[$SLA_SH] a staged copy differs from its source"

  E="$T/empty"; mkdir -p "$E"
  got=$(sla "$E" "$T/stage2")
  [ -z "$got" ] && ok "[$SLA_SH] empty dir -> ''" || no "[$SLA_SH] empty dir -> '$got', want ''"
  case "$got" in *'*.apk'*) no "[$SLA_SH] empty dir echoed the literal *.apk" ;; *) ok "[$SLA_SH] empty dir never echoes the literal *.apk" ;; esac
  # The unmatched glob stays literal; without the -f guard, cp of '*.apk' fails into $LOG and `|| continue`
  # hides it from the output -- so the log is the only witness.
  [ -s "$T/log" ] && no "[$SLA_SH] empty dir wrote to \$LOG: $(head -c 200 "$T/log")" || ok "[$SLA_SH] empty dir leaves \$LOG empty"
  [ "$(cat "$T/sla_rc")" = 0 ] && ok "[$SLA_SH] empty dir -> rc 0" || no "[$SLA_SH] empty dir -> rc $(cat "$T/sla_rc"), want 0"
  sla "$S" "$T/stage3" >/dev/null
  [ "$(cat "$T/sla_rc")" = 0 ] && ok "[$SLA_SH] full dir, every copy whole -> rc 0" || no "[$SLA_SH] full dir -> rc $(cat "$T/sla_rc"), want 0"

  got=$(sla "$S" "$T/no/such/dest")
  [ -z "$got" ] && ok "[$SLA_SH] nonexistent dest -> every failed copy's name is omitted" || no "[$SLA_SH] nonexistent dest -> '$got', want ''"
  [ -s "$T/log" ] && ok "[$SLA_SH] nonexistent dest -> the cp failure goes to \$LOG" || no "[$SLA_SH] nonexistent dest -> nothing logged"
done

# NWP-20261108-04: ALL OR NOTHING. A copy that fails, comes out short or whose source vanished leaves no .apk behind.
echo "== stage_live_apks: a set that does not copy whole is not staged at all =="
S3="$T/code3"; mkdir -p "$S3"
printf 'first-apk-bytes-0123456789'  > "$S3/a_base.apk"
printf 'second-apk-bytes-0123456789' > "$S3/b_split.apk"
printf 'third-apk-bytes-0123456789'  > "$S3/c_split.apk"
w6(){ # w6 <label> <marker file: cpfail|cpshort|cpvanish>
  local d got n src; d="$T/w6-$2"; rm -rf "$d"; mkdir -p "$d"
  rm -f "$T/cpfail" "$T/cpshort" "$T/cpvanish"
  if [ "$2" = cpvanish ]; then rm -rf "$T/code-v"; cp -r "$S3" "$T/code-v"; src="$T/code-v"; else src="$S3"; fi
  printf 'b_split.apk' > "$T/$2"
  got=$(sla "$src" "$d"); n=$(find "$d" -name '*.apk' | wc -l | tr -d ' ')
  rm -f "$T/$2"
  if [ -z "$got" ] && [ "$(cat "$T/sla_rc")" = 1 ] && [ "$n" = 0 ]; then ok "$1: prints nothing, rc 1, no .apk left in the dest"
  else no "$1: out '$got', rc $(cat "$T/sla_rc"), $n .apk left in the dest -- want '', 1, 0"; fi
}
for SLA_SH in $W6_SHELLS; do
  w6 "[$SLA_SH] W6 a dir of 3 APKs whose second copy fails" cpfail
  w6 "[$SLA_SH] W6c the second copy is cut but exits 0 (size differs)" cpshort
  w6 "[$SLA_SH] W6b the third source vanishes after the glob, before the loop reaches it" cpvanish
done
SLA_SH=bash

if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each MUST be convicted) =="
  M=$(mktemp -d -p "$T")
  mutate(){
    if ! sed "$2" "$SUT" > "$M/m.sh" 2>"$M/err"; then no "MUTATION BROKEN (sed): $1"; return; fi
    if cmp -s "$SUT" "$M/m.sh"; then no "MUTATION INERT: $1"; return; fi
    if bash "$0" "$M/m.sh" > "$M/out" 2>&1; then no "NOT CONVICTED: $1 -- suite passes on broken code"; return; fi
    if [ -n "${3:-}" ]; then
      local sh bad=""
      for sh in $W6_SHELLS; do grep -q "FAIL  \[$sh\]" "$M/out" || bad="$bad $sh"; done
      [ -z "$bad" ] || { no "NOT CONVICTED under:$bad: $1"; return; }
    fi
    # A conviction must come from a truth-table row, not from the extraction refusing the mutant.
    case "$(cat "$M/out")" in
      *'EXTRACTION FAILED'*) no "MUTATION BROKE EXTRACTION: $1" ;;
      *) ok "convicted: $1" ;;
    esac
  }
  # NWP-20261113-01: re-targeted at the streamed body, same meanings; every live_code_dir mutant is pershell.
  mutate "drop the SYSTEM flags skip (updated system apps sealed again)" \
         '/^live_code_dir() {$/,/^}$/{/^  case "\$lflags" in \*" SYSTEM "\*) return 0 ;; esac$/d}' pershell
  mutate "drop [ -d \"\$lcd\" ] || return 0 (a vanished dir is still sealed)" \
         '/^live_code_dir() {$/,/^}$/{/^  \[ -d "\$lcd" \] || return 0$/d}' pershell
  mutate "awk keeps the LAST codePath (a later block's codePath wins)" \
         '/^live_code_dir() {$/,/^}$/s#^    !p \&\& /codePath=/ {#    /codePath=/ {#' pershell
  mutate "the /data/app arm stops rejecting other paths" \
         '/^live_code_dir() {$/,/^}$/s#^  case "\$lcd" in /data/app/\*) ;; \*) return 0 ;; esac$#  case "$lcd" in /data/app/*) ;; *) ;; esac#' pershell
  # M1/M2: the dump captured in a variable and handed to printf again, for one field each.
  M1_SED=$(cat <<'EOF'
/^live_code_dir() {$/,/^}$/s|^  lcd=\${lout%%"\$lnl"\*}$|  ldump=$(dumpsys package "$1" 2>/dev/null); lcd=$(printf '%s' "$ldump" \| sed -n 's/.*codePath=//p' \| head -1)|
EOF
)
  M2_SED=$(cat <<'EOF'
/^live_code_dir() {$/,/^}$/s|^  case "\$lout" in \*"\$lnl"\*) lflags=.*$|  ldump=$(dumpsys package "$1" 2>/dev/null); lflags=$(printf '%s' "$ldump" \| grep -m1 'flags=\\[')|
EOF
)
  mutate "M1 the codePath read from printf '%s' \"\$ldump\" | sed again" "$M1_SED" pershell
  mutate "M2 the flags line read from printf '%s' \"\$ldump\" | grep again" "$M2_SED" pershell
  mutate "a copy that is not whole keeps the partial set (the discard removed, return 1 -> continue)" \
         '/^stage_live_apks() {$/,/^}$/{/^      rm -f "\$2"\/\*\.apk$/d;s/^      return 1$/      continue/}' pershell
  mutate "the size check dropped (a cut copy that exits 0 is named)" \
         '/^stage_apk_copy() {$/,/^}$/s# \&\& sac_sz=\$(stat -c %s "\$1" 2>/dev/null) \&\& \[ "\$sac_sz" = "\$(stat -c %s "\$2" 2>/dev/null)" \]##' pershell
  mutate "a vanished source is skipped again (the brace group -> continue)" \
         '/^stage_live_apks() {$/,/^}$/s#^    \[ -f "\$sla_ap" \] || { .*$#    [ -f "$sla_ap" ] || continue#' pershell
  mutate "the empty-dir literal-glob skip dropped" \
         '/^stage_live_apks() {$/,/^}$/s#\[ "\$sla_ap" = "\$1/\*.apk" \] \&\& continue; ##' pershell
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
