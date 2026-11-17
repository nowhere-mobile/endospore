#!/usr/bin/env bash
# test-drm-wipe.sh [<nowhere_roamd.sh>] [--mutate] -- the reap's DRM store wipe (NWP-20261203-08), run for real.
#
# docs/product-decisions.md 2026-11-10, item 2: the phone's DRM licenses and per-app DRM certificates are wiped at
# every sign-out. Android keeps them in one device-wide store, /data/vendor/mediadrm/IDM1013/{L1,L3}/, that cannot
# tell profiles apart. roamd's drm_wipe, called once by the cleanstorage op, must:
#   - remove every `*.lic` (an offline license) and every `cert?*.bin` (a per-app, per-origin certificate);
#   - keep cert.bin, oemcert.bin, usgtable.bin, ay64.dat, ay64.dat<digits>, persistent.dat, every dotfile (even one
#     named like a license, `.private.lic`) and every other name,
#     and never remove a directory;
#   - never follow a symbolic link, read ABSENT only when a parent lists and lacks the missing element, and read
#     UNREACHABLE for any other failure;
#   - report counts only: no file name in DRM_LINE, the log or stderr.
# The source checks pin the one call in the cleanstorage op (after the Bluetooth clear, before reap_userdir_settle,
# not gated on reap_live_other) and the delete-only grant. Since NWP-20261116-37 the grant is on the public attribute
# nowhere_drm_store_file (sepolicy_public/nowhere_drm.te), which the device type joins in sepolicy_vendor/nowhere_drm.te;
# no live rule in endospore.te may name mediadrm_vendor_data_file, the device-only type whose name there broke every
# Endospore policy compile. These pins are text: only the GrapheneOS policy compile on the build host proves it builds.
#
# drm_wipe is extracted from nowhere_roamd.sh BY ANCHOR (its `drm_wipe() {` line up to the first column-0 `}`),
# never copied. Each case writes the function, its stubs and its variables into a runner file and runs it under
# each shell found (bash, dash, mksh under their own names; sh only when it is a distinct binary). ONLY_SHELL=<name>
# (internal, the mutant re-run) runs exactly that shell. A mutant convicts only when its re-run under EACH shell exits
# 1 with a `FAIL  [<sh>]` line of its own. Every temp lives under one root, removed on exit.
#
#   bash test-drm-wipe.sh            # the behaviour cases and the source checks
#   bash test-drm-wipe.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
TE="${TE:-$(dirname "$0")/../../../editions/endospore/vendor/sepolicy/endospore.te}"
PUBTE="${PUBTE:-$(dirname "$0")/../../../editions/endospore/vendor/sepolicy_public/nowhere_drm.te}"
VENTE="${VENTE:-$(dirname "$0")/../../../editions/endospore/vendor/sepolicy_vendor/nowhere_drm.te}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
[ -f "$TE" ] || { echo "no such policy file: $TE" >&2; exit 2; }
[ -f "$PUBTE" ] || { echo "no such policy file: $PUBTE" >&2; exit 2; }
[ -f "$VENTE" ] || { echo "no such policy file: $VENTE" >&2; exit 2; }

# One root for every temp; nothing outlives the suite.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

SHELLS=()
if [ -n "${ONLY_SHELL:-}" ]; then
  case "$ONLY_SHELL" in bash|sh|dash|mksh) ;; *) echo "FAIL  ONLY_SHELL=$ONLY_SHELL is not an available shell"; exit 2 ;; esac
  command -v "$ONLY_SHELL" >/dev/null 2>&1 || { echo "FAIL  ONLY_SHELL=$ONLY_SHELL is not an available shell"; exit 2; }
  SHELLS=("$ONLY_SHELL")
else
  for s in bash dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS+=("$s"); done
  if p=$(command -v sh 2>/dev/null); then
    r=$(readlink -f "$p"); dup=""
    for s in "${SHELLS[@]}"; do [ "$(readlink -f "$(command -v "$s")")" = "$r" ] && { dup=$s; break; }; done
    if [ -n "$dup" ]; then echo "skip shell sh: same binary as $dup"; else SHELLS+=(sh); fi
  fi
fi
[ "${#SHELLS[@]}" -gt 0 ] || { echo "FAIL  no shell found"; exit 2; }

PASS=0; FAIL=0; SH=all; SHP=""
ok(){ PASS=$((PASS+1)); printf '  ok    [%s] %s\n' "$SH" "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  [%s] %s\n' "$SH" "$1"; }

# --- extraction -----------------------------------------------------------------------------------------
FN=$(awk '/^drm_wipe\(\) \{$/ { on = 1 } on { print } on && /^}$/ { exit }' "$SUT")
# The cleanstorage op, from its dispatch line to its first column-0 `fi`, with line numbers.
OP=$(awk '/^if \[ "\$op" = "cleanstorage" \]; then$/ { on = 1 } on { print NR ":" $0 } on && /^fi$/ { exit }' "$SUT")
FN_LINE=$(grep -n '^drm_wipe() {$' "$SUT" | head -1 | cut -d: -f1)
OP_LINE=$(printf '%s\n' "$OP" | head -1 | cut -d: -f1)

# --- harness --------------------------------------------------------------------------------------------
# ls and rm are POSIX function stubs: DENY_LS fails a listing whose last argument it names (root ignores mode bits,
# so chmod 000 proves nothing on a CI runner that runs as root); FAIL_RM makes rm fail, and do nothing, for one path.
STUBS=$(cat <<'EOF'
ls(){ for _st_last; do :; done; case " ${DENY_LS:-} " in *" $_st_last "*) return 1 ;; esac; command ls "$@"; }
rm(){ for _st_last; do :; done; [ -n "${FAIL_RM:-}" ] && [ "$_st_last" = "$FAIL_RM" ] && return 1; command rm "$@"; }
EOF
)
# run <root>: prints DRM_LINE; the LOG is <root>/log, stderr goes to <root>/stderr, the store is <root>/vendor/mediadrm.
run(){
  local r="$1" f="$1/run.sh" n v
  {
    for n in R DENY_LS FAIL_RM; do
      if [ "$n" = R ]; then v=$r; else v=${!n:-}; fi
      case "$v" in *"'"*) echo "run: a quote in $n" >&2; return 2 ;; esac
      printf "%s='%s'\n" "$n" "$v"
    done
    printf '%s\n' 'LOG="$R/log"; DRM_STORE="$R/vendor/mediadrm"; DRM_LINE=""' "$STUBS" "$FN" \
      'drm_wipe reap 11; rc=$?' 'printf "%s" "$DRM_LINE"; [ "$rc" = 0 ] || printf " rc=%s" "$rc"'
  } > "$f" || return 2
  "$SHP" "$f" 2>>"$r/stderr"
}
H1='Ab3_x-Yz9QwErTyUiOp12A'; H2='Zz0-_aBcDeFgHiJkLmNoPq'
mkstore(){   # mkstore <root>: the lynx-shaped L1 + L3 fixture
  local d="$1/vendor/mediadrm/IDM1013" i
  mkdir -p "$d/L1" "$d/L3"
  for i in 1 2 3 4 5 6; do : > "$d/L1/cert${H1}${i}==.bin"; done
  : > "$d/L1/usgtable.bin"; : > "$d/L1/a1b2keyset.lic"; : > "$d/L1/cert.bin"; : > "$d/L1/oemcert.bin"
  : > "$d/L1/.private.lic"   # a dotfile named like a license: unclassified, kept
  for i in 1 2 3 4 5; do : > "$d/L3/cert${H2}${i}==.bin"; done
  : > "$d/L3/ay64.dat"; : > "$d/L3/ay64.dat5"; : > "$d/L3/ay64.dat6"; : > "$d/L3/persistent.dat"
  : > "$d/L3/usgtable.bin"; : > "$d/L3/c3d4keyset.lic"; : > "$d/L3/x.bin"; : > "$d/L3/.hidden"
}
KEPT1="usgtable.bin cert.bin oemcert.bin .private.lic"
KEPT3="ay64.dat ay64.dat5 ay64.dat6 persistent.dat usgtable.bin x.bin .hidden"
wiped_left(){   # wiped_left <dir>: how many *.lic and cert?*.bin are still there (a dotfile is kept, not counted)
  command ls -1A "$1" 2>/dev/null | grep -v '^\.' | grep -c -e '\.lic$' -e '^cert..*\.bin$'
}

cases(){
echo "== [$SH] (a) a lynx-shaped store: the profile traces go, the device state stays =="
T=$(mktemp -d -p "$W"); mkstore "$T"; D="$T/vendor/mediadrm/IDM1013"; S=$(run "$T")
[ "$S" = "lic=2 cert=11 kept=11 left=0 store=OK" ] && ok "DRM_LINE is lic=2 cert=11 kept=11 left=0 store=OK" \
  || no "DRM_LINE is '$S', want 'lic=2 cert=11 kept=11 left=0 store=OK'"
[ -z "$(command ls -1A "$D/L1" "$D/L3" | grep -v '^\.' | grep '\.lic$')" ] && ok "no *.lic left in L1/L3" || no "a *.lic is left in L1/L3"
[ -z "$(command ls -1A "$D/L1" "$D/L3" | grep -v '^\.' | grep '^cert..*\.bin$')" ] && ok "no cert?*.bin left in L1/L3" \
  || no "a cert?*.bin is left in L1/L3"
[ -f "$D/L1/cert.bin" ] && ok "L1/cert.bin still exists" || no "L1/cert.bin was removed"
[ -f "$D/L1/.private.lic" ] && ok "the dotfile L1/.private.lic still exists" || no "the dotfile L1/.private.lic was removed"
miss=""
for k in $KEPT1; do [ -f "$D/L1/$k" ] || miss="$miss L1/$k"; done
for k in $KEPT3; do [ -f "$D/L3/$k" ] || miss="$miss L3/$k"; done
[ -z "$miss" ] && ok "every KEPT name is still there" || no "KEPT names removed:$miss"
[ -d "$D/L1" ] && [ -d "$D/L3" ] && [ -d "$D" ] && ok "L1, L3 and IDM1013 are still directories" \
  || no "a directory of the store was removed"

echo "== [$SH] (b) no fixture name reaches DRM_LINE, the log or stderr =="
leak=$(cat "$T/log" "$T/stderr" 2>/dev/null; printf '%s\n' "$S")
case "$leak" in
  *"$H1"*|*"$H2"*|*keyset*|*usgtable*|*oemcert*|*ay64*|*persistent*|*hidden*|*private*|*x.bin*|*cert.bin*) no "a fixture name was printed" ;;
  *) ok "no fixture name in DRM_LINE, the log or stderr" ;;
esac
rm -rf "$T"

echo "== [$SH] (c) a store that is not there =="
T=$(mktemp -d -p "$W"); mkdir -p "$T/vendor/other"; S=$(run "$T")
[ "$S" = "lic=0 cert=0 kept=0 left=0 store=ABSENT" ] && ok "a listable parent without mediadrm: store=ABSENT" || no "DRM_LINE is '$S'"
[ "$(command ls -1A "$T/vendor")" = other ] && ok "nothing is created" || no "something was created under vendor"
rm -rf "$T"
T=$(mktemp -d -p "$W"); mkdir -p "$T/vendor/mediadrm"; S=$(run "$T")
[ "$S" = "lic=0 cert=0 kept=0 left=0 store=ABSENT" ] && ok "mediadrm without IDM1013: store=ABSENT" || no "DRM_LINE is '$S'"
[ -z "$(command ls -1A "$T/vendor/mediadrm")" ] && ok "nothing is created in mediadrm" || no "something was created in mediadrm"
rm -rf "$T"
T=$(mktemp -d -p "$W"); mkdir -p "$T/vendor/other"; S=$(DENY_LS="$T/vendor" run "$T")
[ "$S" = "lic=0 cert=0 kept=0 left=0 store=UNREACHABLE" ] && ok "an unlistable parent: store=UNREACHABLE, not ABSENT" \
  || no "DRM_LINE is '$S'"
rm -rf "$T"

echo "== [$SH] (d) an unlistable level =="
T=$(mktemp -d -p "$W"); mkstore "$T"; D="$T/vendor/mediadrm/IDM1013"; S=$(DENY_LS="$D/L3" run "$T")
case "$S" in *" store=UNREACHABLE") ok "L3 cannot be listed: store=UNREACHABLE" ;; *) no "DRM_LINE is '$S', want store=UNREACHABLE" ;; esac
[ "$(wiped_left "$D/L3")" -eq 6 ] && ok "nothing in L3 was removed blind" || no "files in L3 were removed"
[ "$(wiped_left "$D/L1")" -eq 0 ] && ok "L1 is still wiped" || no "L1 was not wiped"
rm -rf "$T"

echo "== [$SH] (e) a removal that fails shows as left =="
T=$(mktemp -d -p "$W"); mkstore "$T"; D="$T/vendor/mediadrm/IDM1013"; S=$(FAIL_RM="$D/L1/a1b2keyset.lic" run "$T")
[ "$S" = "lic=2 cert=11 kept=11 left=1 store=OK" ] && ok "one license rm fails: left=1" || no "DRM_LINE is '$S', want left=1"
rm -rf "$T"

echo "== [$SH] (f) a symbolic link is never followed =="
T=$(mktemp -d -p "$W"); mkstore "$T"; D="$T/vendor/mediadrm/IDM1013"
mkdir -p "$T/elsewhere"; : > "$T/elsewhere/z.lic"; command rm -rf "$D/L1"; ln -s "$T/elsewhere" "$D/L1"
S=$(run "$T")
[ -f "$T/elsewhere/z.lic" ] && ok "the link target's z.lic survives" || no "the link was followed: z.lic was removed"
case "$S" in *" store=UNREACHABLE") ok "an L1 that is a link: store=UNREACHABLE" ;; *) no "DRM_LINE is '$S', want store=UNREACHABLE" ;; esac
[ -L "$D/L1" ] && ok "the link itself is kept" || no "the link was removed"
rm -rf "$T"

echo "== [$SH] (g) source: one call in the cleanstorage op, and the delete-only grant =="
[ -n "$FN" ] && ok "drm_wipe() is defined in roamd" || no "drm_wipe() is not defined in roamd"
[ -n "$FN_LINE" ] && [ -n "$OP_LINE" ] && [ "$FN_LINE" -lt "$OP_LINE" ] && ok "drm_wipe() is defined above the cleanstorage op" \
  || no "drm_wipe() is not defined above the cleanstorage op"
c=$(printf '%s\n' "$OP" | grep -c '^[0-9]*:  drm_wipe reap "\$uid"$')
[ "$c" = 1 ] && ok "the cleanstorage op holds exactly one drm_wipe reap \"\$uid\"" || no "the cleanstorage op holds $c drm_wipe reap calls"
lc=$(printf '%s\n' "$OP" | grep '^[0-9]*:  drm_wipe reap "\$uid"$' | head -1 | cut -d: -f1)
lb=$(printf '%s\n' "$OP" | grep '^[0-9]*:  elif \[ "\$_rbrc" != 2 \]; then' | head -1 | cut -d: -f1)
ls_=$(printf '%s\n' "$OP" | grep '^[0-9]*:  reap_userdir_settle "\$uid"$' | head -1 | cut -d: -f1)
if [ -n "$lc" ] && [ -n "$lb" ] && [ -n "$ls_" ] && [ "$lb" -lt "$lc" ] && [ "$lc" -lt "$ls_" ]; then
  ok "the call sits after the Bluetooth clear and before reap_userdir_settle"
else no "the call is not between the Bluetooth clear ($lb) and reap_userdir_settle ($ls_): '$lc'"; fi
gate=""
if [ -n "$lc" ] && [ -n "$lb" ]; then
  gate=$(printf '%s\n' "$OP" | awk -F: -v a="$lb" -v b="$lc" '$1 > a && $1 < b' | cut -d: -f2- \
    | grep -v '^[[:space:]]*#' | grep -e 'reap_live_other' -e '^[[:space:]]*\(if\|fi\|elif\|else\)\b' || true)
fi
[ -n "$lc" ] && [ -z "$gate" ] && ok "the call is not inside a reap_live_other branch" \
  || no "the call is gated or missing: '$gate'"
DIRL='allow endospore_priv nowhere_drm_store_file:dir { getattr search open read write remove_name };'
FILEL='allow endospore_priv nowhere_drm_store_file:{ file lnk_file } { getattr unlink };'
[ "$(grep -cxF -- "$DIRL" "$TE")" = 1 ] && ok "endospore.te holds the dir allow line" || no "endospore.te lacks the dir allow line"
[ "$(grep -cxF -- "$FILEL" "$TE")" = 1 ] && ok "endospore.te holds the file allow line" || no "endospore.te lacks the file allow line"
live=$(grep -v '^[[:space:]]*#' "$TE" | grep -c 'mediadrm_vendor_data_file' || true)
[ "$live" = 0 ] && ok "no live endospore.te rule names mediadrm_vendor_data_file" \
  || no "endospore.te names the device-only type in $live live line(s): the private policy cannot see it"
pub=$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$PUBTE" || true)
[ "$pub" = 'attribute nowhere_drm_store_file;' ] && ok "the public policy declares the attribute and nothing else" \
  || no "the public policy is not exactly the attribute: '$pub'"
ven=$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$VENTE" || true)
[ "$ven" = 'typeattribute mediadrm_vendor_data_file nowhere_drm_store_file;' ] \
  && ok "the vendor policy puts the device type into the attribute and does nothing else" \
  || no "the vendor policy is not exactly the typeattribute line: '$ven'"
fl=$(grep '^allow endospore_priv nowhere_drm_store_file:{' "$TE" || true)
case "$fl" in
  *" read "*|*" read}"*|*"{read "*) no "the file-class line grants read: '$fl'" ;;
  *) ok "no read in the file-class line" ;;
esac
dl=$(grep '^allow endospore_priv nowhere_drm_store_file:dir' "$TE" || true)
case "$dl" in *rmdir*) no "the dir line grants rmdir" ;; *) ok "no rmdir in the dir line" ;; esac
}

# Parse first, then every case, under each shell.
printf '%s\n' "$STUBS" "$FN" > "$W/parse.sh"
for SH in "${SHELLS[@]}"; do
  SHP=$(command -v "$SH")
  "$SHP" -n "$W/parse.sh" 2>/dev/null || { no "drm_wipe DOES NOT PARSE under $SH"; exit 2; }
  cases
done
SH=all

if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each must CONVICT the suite) =="
  M=$(mktemp -d -p "$W")
  # mutate <what> <roamd|te|pub|ven> <sed>. A mutant convicts only when its re-run under EACH shell exits 1 with a FAIL line
  # tagged for that shell; a mutant that does not change its file is a failure, never a pass.
  mutate(){
    local SH=all s out rc ev src
    case "$2" in roamd) src=$SUT ;; te) src=$TE ;; pub) src=$PUBTE ;; ven) src=$VENTE ;; esac
    if ! sed "$3" "$src" > "$M/m" 2>"$M/err"; then no "MUTATION BROKEN (sed): $1"; return; fi
    if cmp -s "$src" "$M/m"; then no "MUTATION INERT: $1"; return; fi
    for s in "${SHELLS[@]}"; do
      SH=$s
      case "$2" in
        roamd) out=$(ONLY_SHELL="$s" TMPDIR="$W" TE="$TE" PUBTE="$PUBTE" VENTE="$VENTE" bash "$0" "$M/m" 2>&1); rc=$? ;;
        te) out=$(ONLY_SHELL="$s" TMPDIR="$W" TE="$M/m" PUBTE="$PUBTE" VENTE="$VENTE" bash "$0" "$SUT" 2>&1); rc=$? ;;
        pub) out=$(ONLY_SHELL="$s" TMPDIR="$W" TE="$TE" PUBTE="$M/m" VENTE="$VENTE" bash "$0" "$SUT" 2>&1); rc=$? ;;
        ven) out=$(ONLY_SHELL="$s" TMPDIR="$W" TE="$TE" PUBTE="$PUBTE" VENTE="$M/m" bash "$0" "$SUT" 2>&1); rc=$? ;;
      esac
      ev=$(printf '%s\n' "$out" | grep -F "  FAIL  [$s] " || true)
      if [ "$rc" = 0 ]; then no "NOT CONVICTED: $1 -- suite passes on broken code"
      elif [ "$rc" != 1 ]; then no "MUTANT BROKEN: $1 (rc=$rc)"
      elif [ -z "$ev" ]; then no "UNPROVEN: $1 -- rc 1 with no FAIL line under $s"
      else ok "convicted: $1"; printf '%s\n' "$ev" | sed 's/^/        /'; fi
    done
  }
  R='/^drm_wipe() {$/,/^}$/'
  mutate "the *.lic arm removed" roamd "$R{/^        \\*\\.lic)\$/,/fi ;;\$/d}"
  mutate "the dotfile arm removed from the wipe" roamd "$R"'{/^        \.\*) _dwkept=\$((_dwkept + 1)) ;;$/d}'
  mutate "the dotfile arm removed from the re-list" roamd "$R"'{/^        \.\*) ;;$/d}'
  mutate "the cert pattern widened to cert*.bin" roamd "$R"'s/^        cert?\*\.bin)$/        cert*.bin)/'
  mutate "the cert arm removed" roamd "$R{/^        cert?\\*\\.bin)\$/,/fi ;;\$/d}"
  mutate "the cleanstorage call removed" roamd '/^  drm_wipe reap "\$uid"$/d'
  mutate "the call wrapped in if ! reap_live_other" roamd \
    's/^  drm_wipe reap "\$uid"$/  if ! reap_live_other "$uid" >\/dev\/null; then\n  drm_wipe reap "$uid"\n  fi/'
  mutate "a name echoed to \$LOG" roamd "$R"'s/rm -f "\$_dwd\/\$_dwb" 2>\/dev\/null; _dwlic=/echo "$_dwb" >> "$LOG"; &/'
  mutate "UNREACHABLE replaced by ABSENT" roamd "$R"'s/UNREACHABLE/ABSENT/g'
  mutate "the left count forced to 0" roamd "$R"'s/left=\$_dwleft/left=0/'
  mutate "the [ ! -L ] test removed" roamd "$R"'s/\[ -d "\$_dwp" \] && \[ ! -L "\$_dwp" \] && continue/[ -d "$_dwp" ] \&\& continue/'
  mutate "the file allow line removed" te '/^allow endospore_priv nowhere_drm_store_file:{ file lnk_file }/d'
  mutate "read added to the file allow line" te \
    's/^\(allow endospore_priv nowhere_drm_store_file:{ file lnk_file } { getattr\) unlink };$/\1 read unlink };/'
  mutate "the grant names the device-only type again (the 0.5.58 break)" te \
    's/^allow endospore_priv nowhere_drm_store_file:dir /allow endospore_priv mediadrm_vendor_data_file:dir /'
  mutate "rmdir added to the dir allow line" te \
    's/^\(allow endospore_priv nowhere_drm_store_file:dir { getattr search open read write remove_name\) };$/\1 rmdir };/'
  mutate "the public attribute removed" pub '/^attribute nowhere_drm_store_file;$/d'
  mutate "the vendor policy grants instead of joining" ven \
    's/^typeattribute mediadrm_vendor_data_file nowhere_drm_store_file;$/allow endospore_priv mediadrm_vendor_data_file:file unlink;/'
  rm -rf "$M"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
