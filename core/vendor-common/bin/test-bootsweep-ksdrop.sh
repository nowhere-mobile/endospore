#!/usr/bin/env bash
# test-bootsweep-ksdrop.sh [<nowhere_roamd.sh>] [--mutate] -- the boot sweep's keystore-drop category
# (fix 16, NWP-20261102-04), run for real under every shell (NWP-20261117-44).
#
# $KS_DROP (/data/nowhere/keystore-drop) is on device-encrypted /data, not the tmpfs. ks_stage_drop writes it at a
# sign-out's `out`: a `# <uid>` header plus the apps that session switched off, stopped carrying or inferred
# orphaned. The reap removes it after keystore_push. A crash or power loss between `out` and the reap leaves it on
# /data, and until the next session's first `out` the boot sweep is its only remover (docs/threat-model.md section 2).
# The category must:
#   - remove $KS_DROP and $KS_DROP.new, and never follow a symbolic link into its target;
#   - report ksdrop=removed when it removed something and nothing stays, ksdrop=LEFT when something stays,
#     and ksdrop=none when neither path exists (and create nothing);
#   - append to `_swept` exactly once on every path (the bootsweep INVARIANT above its result line).
# It pins SHIPPED behaviour: every case passes on the code as merged; the fail-first rule is met by the mutants
# D1-D5, each a copy of roamd broken in one way, which each case must convict.
#
# Residual, pinned and not tested: unlike staging_boot (fix 17), this block has no KEPT:session or KEPT:reap guard.
# A BOOT-SWEEP that lands between a this-boot sign-out's `out` and its reap removes that session's fresh list. That
# only delays its drop by one sign-out (an absent list filters nothing: keystore_push FAILS SAFE), and after a
# refused sign-out the next seal restages it.
#
# The block is extracted BY ANCHOR, from the line that begins `  # --- fix 16: keystore-drop` up to (not
# including) the line that begins `  # --- fix 17: staging`. Extraction asks only for the category's own `ksdrop=`
# token and `$KS_DROP`, never for the rm line or a verdict: an extraction exit is rc 2, a harness error, and never a
# conviction, so every mutant must be convicted by the cases. Each case writes a runner file into its own root
# (the shell identity probe, KS_DROP=<root>/keystore-drop, the block, then `_swept` into a file) and runs it in a
# CHILD of each shell found among bash, sh, dash and mksh, each by its own name. A runner that records no
# identity, or another shell's, is a harness error: the suite exits 2 and prints no FAIL line for it.
#
#   bash test-bootsweep-ksdrop.sh            # the behaviour cases
#   bash test-bootsweep-ksdrop.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

# One root for every temp; nothing outlives the suite.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

# Each shell by its own name, no dedup. ONLY_SHELL=<name> (internal, the mutant re-run) runs exactly that shell.
SHELLS=()
if [ -n "${ONLY_SHELL:-}" ]; then
  case "$ONLY_SHELL" in bash|sh|dash|mksh) ;; *) echo "FAIL  ONLY_SHELL=$ONLY_SHELL is not an available shell"; exit 2 ;; esac
  command -v "$ONLY_SHELL" >/dev/null 2>&1 || { echo "FAIL  ONLY_SHELL=$ONLY_SHELL is not an available shell"; exit 2; }
  SHELLS=("$ONLY_SHELL")
else
  for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS+=("$s"); done
fi
[ "${#SHELLS[@]}" -gt 0 ] || { echo "FAIL  no shell found"; exit 2; }

PASS=0; FAIL=0; SH=all; SHP=""
ok(){ PASS=$((PASS+1)); printf '  ok    [%s] %s\n' "$SH" "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  [%s] %s\n' "$SH" "$1"; }

# --- shell identity (as test-in-refused-noop.sh) --------------------------------------------------------
IDPROBE='_id="${KSH_VERSION:+ksh:$KSH_VERSION}${BASH_VERSION:+bash:$BASH_VERSION}"; [ -n "$_id" ] || _id=posix; _pr=none; command -v print >/dev/null 2>&1 && _pr=builtin'
REF_SH=""; command -v sh >/dev/null 2>&1 && REF_SH=$(sh -c "$IDPROBE; printf '%s|%s\n' \"\$_id\" \"\$_pr\"")
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

# --- extraction -----------------------------------------------------------------------------------------
BLOCK=$(awk '
  index($0, "  # --- fix 17: staging") == 1 { if (on) exit }
  index($0, "  # --- fix 16: keystore-drop") == 1 { on = 1 }
  on { print }' "$SUT")
ORDER=$(awk '
  index($0, "  # --- fix 16: keystore-drop") == 1 && !s { s = NR }
  index($0, "  # --- fix 17: staging") == 1 && !e { e = NR }
  END { print (s && e && s < e) ? "ok" : "bad" }' "$SUT")
case "$ORDER" in ok) ;; *) echo "EXTRACTION FAILED: the fix 16 / fix 17 anchors are missing or out of order" >&2; exit 2 ;; esac
case "$BLOCK" in *'ksdrop='*) ;; *) echo "EXTRACTION FAILED: the block holds no ksdrop= token" >&2; exit 2 ;; esac
case "$BLOCK" in *'$KS_DROP'*) ;; *) echo "EXTRACTION FAILED: the block holds no \$KS_DROP" >&2; exit 2 ;; esac

# --- harness --------------------------------------------------------------------------------------------
# runblk <root>: write <root>/run.sh, run it in a child of "$SHP", check the identity it left, print _swept.
# It never exits: a harness error returns 2, and every caller runs `S=$(runblk "$T"); [ "$?" = 2 ] && exit 2`.
runblk(){
  local r="$1"
  case "$r" in *"'"*) echo "HARNESS ERROR: [$SH] a quote in the case root" >&2; return 2 ;; esac
  {
    printf '%s; printf '\''%%s|%%s\\n'\'' "$_id" "$_pr" >> '\''%s/shell.id'\''\n' "$IDPROBE" "$r"
    printf "KS_DROP='%s/keystore-drop'; _swept=\"\"\n" "$r"
    printf '%s\n' "$BLOCK"
    printf "printf '%%s' \"\$_swept\" > '%s/swept'\n" "$r"
  } > "$r/run.sh" || { echo "HARNESS ERROR: [$SH] cannot write the runner" >&2; return 2; }
  "$SHP" "$r/run.sh" 2>>"$r/stderr"
  if [ ! -s "$r/shell.id" ]; then echo "HARNESS ERROR: [$SH] the runner left no shell identity" >&2; return 2; fi
  if ! idok "$SH" "$r/shell.id"; then echo "HARNESS ERROR: [$SH] the runner left the identity of another shell" >&2; return 2; fi
  cat "$r/swept" 2>/dev/null
  return 0
}
# once <swept> -> 0 iff it holds exactly one ksdrop= token (K6, the result-line invariant)
once(){ local c; c=$(printf '%s\n' "$1" | grep -o 'ksdrop=' | wc -l); [ "$c" -eq 1 ]; }
# k6 <case> <swept>
k6(){ if once "$2"; then ok "K6 $1: exactly one ksdrop= token"; else no "K6 $1: _swept is '$2', want exactly one ksdrop= token"; fi; }

cases(){
  local T S L
  echo "== [$SH] K1: the list and its .new both present =="
  T=$(mktemp -d -p "$W"); printf '# 10\ncom.example.off\n' > "$T/keystore-drop"; printf '# 10\n' > "$T/keystore-drop.new"
  S=$(runblk "$T"); [ "$?" = 2 ] && exit 2
  [ ! -e "$T/keystore-drop" ] && [ ! -e "$T/keystore-drop.new" ] && ok "K1 both removed" \
    || no "K1 left: $(cd "$T" && ls -d keystore-drop* 2>/dev/null | tr '\n' ' ')"
  [ "$S" = " ksdrop=removed" ] && ok "K1 reports ksdrop=removed" || no "K1 reported '$S', want ' ksdrop=removed'"
  k6 K1 "$S"; rm -rf "$T"

  echo "== [$SH] K2: only the .new present =="
  T=$(mktemp -d -p "$W"); printf '# 10\ncom.example.off\n' > "$T/keystore-drop.new"
  S=$(runblk "$T"); [ "$?" = 2 ] && exit 2
  [ ! -e "$T/keystore-drop.new" ] && ok "K2 the .new is removed" || no "K2 the .new is still there"
  [ ! -e "$T/keystore-drop" ] && ok "K2 no list is created" || no "K2 a list was created"
  [ "$S" = " ksdrop=removed" ] && ok "K2 reports ksdrop=removed" || no "K2 reported '$S', want ' ksdrop=removed'"
  k6 K2 "$S"; rm -rf "$T"

  echo "== [$SH] K3: neither present =="
  T=$(mktemp -d -p "$W")
  S=$(runblk "$T"); [ "$?" = 2 ] && exit 2
  [ "$S" = " ksdrop=none" ] && ok "K3 reports ksdrop=none" || no "K3 reported '$S', want ' ksdrop=none'"
  L=$(cd "$T" && ls -1A | grep -vxE 'run\.sh|shell\.id|swept|stderr' | tr '\n' ' ')
  [ -z "$L" ] && ok "K3 nothing is created" || no "K3 created: $L"
  k6 K3 "$S"; rm -rf "$T"

  echo "== [$SH] K4: KS_DROP is a non-empty directory (rm -f cannot remove it) =="
  T=$(mktemp -d -p "$W"); mkdir "$T/keystore-drop"; echo keep > "$T/keystore-drop/f"
  S=$(runblk "$T"); [ "$?" = 2 ] && exit 2
  [ "$S" = " ksdrop=LEFT" ] && ok "K4 reports ksdrop=LEFT" || no "K4 reported '$S', want ' ksdrop=LEFT'"
  [ -d "$T/keystore-drop" ] && [ "$(cat "$T/keystore-drop/f" 2>/dev/null)" = keep ] && ok "K4 the directory and its file are still there" \
    || no "K4 the directory or its file is gone"
  k6 K4 "$S"; rm -rf "$T"

  echo "== [$SH] K5: KS_DROP is a symbolic link to a file outside the keystore-drop path =="
  T=$(mktemp -d -p "$W"); mkdir "$T/outside"; echo sentinel > "$T/outside/target"; ln -s "$T/outside/target" "$T/keystore-drop"
  S=$(runblk "$T"); [ "$?" = 2 ] && exit 2
  [ ! -L "$T/keystore-drop" ] && [ ! -e "$T/keystore-drop" ] && ok "K5 the link is removed" || no "K5 the link is still there"
  [ "$(cat "$T/outside/target" 2>/dev/null)" = sentinel ] && ok "K5 the link target is untouched" || no "K5 the link target was changed or removed"
  [ "$S" = " ksdrop=removed" ] && ok "K5 reports ksdrop=removed" || no "K5 reported '$S', want ' ksdrop=removed'"
  k6 K5 "$S"; rm -rf "$T"
}

# Parse first, then every case, under each shell. cases runs in this shell, so its `exit 2` ends the suite.
printf '%s\n' 'KS_DROP=/nonexistent; _swept=""' "$BLOCK" > "$W/parse.sh"
for SH in "${SHELLS[@]}"; do
  SHP=$(command -v "$SH")
  "$SHP" -n "$W/parse.sh" 2>/dev/null || { echo "HARNESS ERROR: the block does not parse under $SH" >&2; exit 2; }
  cases
done
SH=all

if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each must CONVICT the suite under every shell) =="
  # Every edit is scoped to the fix 16 range: the same rm line also sits in ks_stage_drop.
  R='/^  # --- fix 16: keystore-drop/,/^  # --- fix 17: staging/'
  # A mutant convicts only when its re-run under EACH shell exits 1 with a FAIL line tagged for that shell.
  mutate(){
    local SH=all s out rc ev m
    m=$(mktemp -p "$W") || { no "MUTATION BROKEN (mktemp): $1"; return; }
    if ! sed "$2" "$SUT" > "$m" 2>"$m.err"; then no "MUTATION BROKEN (sed): $1: $(cat "$m.err")"; rm -f "$m" "$m.err"; return; fi
    rm -f "$m.err"
    if cmp -s "$SUT" "$m"; then no "MUTATION INERT: $1"; rm -f "$m"; return; fi
    for s in "${SHELLS[@]}"; do
      SH=$s
      out=$(ONLY_SHELL="$s" TMPDIR="$W" bash "$0" "$m" 2>&1); rc=$?
      ev=$(printf '%s\n' "$out" | grep -F "  FAIL  [$s] " || true)
      if [ "$rc" = 0 ]; then no "NOT CONVICTED: $1 -- suite passes on broken code"
      elif [ "$rc" != 1 ]; then no "MUTANT BROKEN: $1 (rc=$rc)"
      elif [ -z "$ev" ]; then no "UNPROVEN: $1 -- rc 1 with no FAIL line under $s"
      else ok "CONVICTED: $1"; printf '%s\n' "$ev" | sed 's/^/        /'; fi
    done
    rm -f "$m"
  }
  mutate "D1 the rm line is deleted (K1)" "$R"'{/^    rm -f "\$KS_DROP" "\$KS_DROP\.new" 2>\/dev\/null$/d}'
  mutate "D2 the .new is dropped from the rm (K2)" "$R"'{s@^    rm -f "\$KS_DROP" "\$KS_DROP\.new" 2>/dev/null$@    rm -f "$KS_DROP" 2>/dev/null@}'
  mutate "D3 the post-rm re-check is false: always removed (K4)" "$R"'{/ksdrop=LEFT/s@^    if .*; then _swept=@    if false; then _swept=@}'
  mutate "D4 the outer else reports removed (K3)" "$R"'{s@else _swept="\$_swept ksdrop=none"; fi@else _swept="$_swept ksdrop=removed"; fi@}'
  mutate "D5 the category appends its token twice (K6)" "$R"'{/ksdrop=none"; fi$/s@$@\n  _swept="$_swept ${_swept##* }"@}'
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
