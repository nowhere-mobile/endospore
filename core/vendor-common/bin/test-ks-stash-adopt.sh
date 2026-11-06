#!/usr/bin/env bash
# test-ks-stash-adopt.sh [<nowhere_roamd.sh>] [--mutate] -- the keystore stash round trip: roamd's `out` writes
# $KS_CREDS (name, passphrase, uid, chip secret) and cleanstorage adopts it ONLY for the uid it belongs to
# (NWP-20260917-25, NWP-20261007-12).
#
# WHY THIS IS COMMITTED. A wrong adopt seals a reaped user's keystore dump into ANOTHER profile's #keys and REPLACES
# its carried bundles; a broken adopt defers every logoff's #keys silently. The happy path was device-proven, but
# nothing off-device ran the adopt or its refusal, and roamd has no harness of its own. The writer block and the
# adopt block are extracted BY ANCHOR from the real script (never copied) and run as a round trip, so the stash's
# line order is pinned from both ends.
#
#   bash test-ks-stash-adopt.sh            # the cases, under every shell installed
#   bash test-ks-stash-adopt.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

PRINT_SHIM='print() { local nl=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) nl=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$nl" = 1 ]; then printf "%s\n" "$*"; else printf "%s" "$*"; fi; }'

W_ANCHOR='if [ "$op" = "out" ] && [ -n "$name" ] && [ -n "$pass" ]; then'
A_ANCHOR='  if { [ -z "$name" ] || [ -z "$pass" ]'

# count <anchor> <file> -- how many lines start with the anchor
count() { awk -v a="$1" 'index($0,a)==1{n++} END{print n+0}' "$2"; }
extract_writer() { awk -v a="$W_ANCHOR" 'index($0,a)==1{on=1} on{print} on&&/^fi$/{exit}' "$1"; }
extract_adopt() { awk -v a="$A_ANCHOR" 'index($0,a)==1{on=1} on{print} on&&/^    unset _ksu$/{u=1} on&&u&&/^  fi$/{exit}' "$1"; }

SHELLS=()
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS+=("$s"); done

suite() {
  local f="$1" quiet="${2:-}" p=0 x=0 wblk ablk d sh
  ok(){ p=$((p+1)); [ -n "$quiet" ] || printf '  ok    %s\n' "$1"; }
  no(){ x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  %s\n' "$1"; }

  if [ "$(count "$W_ANCHOR" "$f")" != 1 ] || [ "$(count "$A_ANCHOR" "$f")" != 1 ]; then
    echo "EXTRACTION FAILED -- an anchor is missing or ambiguous in $f" >&2; return 2
  fi
  wblk=$(extract_writer "$f"); ablk=$(extract_adopt "$f")
  case "$wblk" in *'print -r -- "$sesec"'*) ;; *) echo "EXTRACTION FAILED -- the writer block moved in $f" >&2; return 2 ;; esac
  case "$ablk" in *'unset _ksu'*) ;; *) echo "EXTRACTION FAILED -- the adopt block moved in $f" >&2; return 2 ;; esac

  d=$(mktemp -d)
  # write_stash <sh> <op> <uid> <name> <pass> <sesec>
  write_stash() {
    { printf '%s\n' "$PRINT_SHIM"; printf 'KS_CREDS=%q\nop=%q uid=%q name=%q pass=%q sesec=%q\n' "$d/ks" "$2" "$3" "$4" "$5" "$6"; printf '%s\n' "$wblk"; } > "$d/w.sh"
    "$1" "$d/w.sh" >/dev/null 2>&1
  }
  # adopt <sh> <uid> <name> <pass> -> $d/res as NAME=<..> PASS=<..> SE=<set|unset:..>
  adopt() {
    command rm -f "$d/log"
    { printf '%s\n' "$PRINT_SHIM"; printf 'KS_CREDS=%q LOG=%q\nuid=%q name=%q pass=%q\nunset NOWHERE_SE_SECRET\n' "$d/ks" "$d/log" "$2" "$3" "$4"
      printf '%s\n' "$ablk"
      printf 'printf "NAME=<%%s>\\nPASS=<%%s>\\n" "$name" "$pass" > %q\nif [ "${NOWHERE_SE_SECRET+set}" = set ]; then printf "SE=<%%s>\\n" "$NOWHERE_SE_SECRET" >> %q; else echo SE=unset >> %q; fi\n' "$d/res" "$d/res" "$d/res"
    } > "$d/a.sh"
    "$1" "$d/a.sh" >/dev/null 2>&1
  }
  local P='pa ss\word' N='p q' S='chip-secret-1'
  for sh in "${SHELLS[@]}"; do
    command rm -f "$d/ks" "$d/log" "$d/res"
    write_stash "$sh" out 11 "$N" "$P" "$S"; adopt "$sh" 11 x ""
    [ "$(cat "$d/res" 2>/dev/null)" = "NAME=<$N>"$'\n'"PASS=<$P>"$'\n'"SE=<$S>" ] && ok "A1 own uid adopts name, passphrase and chip secret byte for byte [$sh]" || no "A1 own-uid adopt wrong [$sh]: $(cat "$d/res" 2>/dev/null)"
    [ ! -s "$d/log" ] && ok "A1b the adopt logs nothing [$sh]" || no "A1b the adopt logged [$sh]"

    command rm -f "$d/ks"; write_stash "$sh" out 11 "$N" "$P" "$S"; adopt "$sh" 12 x ""
    [ "$(cat "$d/res" 2>/dev/null)" = $'NAME=<x>\nPASS=<>\nSE=unset' ] && ok "A2 foreign uid: name/pass untouched, no chip secret [$sh]" || no "A2 foreign-uid stash adopted [$sh]: $(cat "$d/res" 2>/dev/null)"
    if grep -q 'cleanstorage uid 12: keystore stash belongs to uid 11 -- NOT adopting it' "$d/log" 2>/dev/null \
       && ! grep -qF -e "$N" -e "$P" -e "$S" "$d/log"; then ok "A2b refusal logged with both uids and no credential [$sh]"; else no "A2b refusal log wrong [$sh]: $(cat "$d/log" 2>/dev/null)"; fi

    command rm -f "$d/ks"; write_stash "$sh" out 11 "$N" "$P" ""; adopt "$sh" 11 x ""
    [ "$(cat "$d/res" 2>/dev/null)" = "NAME=<$N>"$'\n'"PASS=<$P>"$'\n'"SE=unset" ] && ok "A3 no chip secret: adopted, secret not exported [$sh]" || no "A3 wrong [$sh]: $(cat "$d/res" 2>/dev/null)"

    printf 'alice\nsecret\n' > "$d/ks"; adopt "$sh" 11 x ""
    [ "$(cat "$d/res" 2>/dev/null)" = $'NAME=<x>\nPASS=<>\nSE=unset' ] && grep -q 'stash belongs to uid none' "$d/log" 2>/dev/null && ok "A4 legacy 2-line stash refused as 'uid none' [$sh]" || no "A4 legacy stash handled wrong [$sh]"

    command rm -f "$d/ks"; adopt "$sh" 11 x ""
    [ "$(cat "$d/res" 2>/dev/null)" = $'NAME=<x>\nPASS=<>\nSE=unset' ] && [ ! -e "$d/log" ] && ok "A5 no stash: nothing changes, nothing logged [$sh]" || no "A5 no-stash case wrong [$sh]"

    command rm -f "$d/ks"; write_stash "$sh" out 11 "$N" "$P" "$S"; adopt "$sh" 11 given givenpass
    [ "$(cat "$d/res" 2>/dev/null)" = $'NAME=<given>\nPASS=<givenpass>\nSE=unset' ] && [ ! -e "$d/log" ] && ok "A6 given creds are kept over a same-uid stash [$sh]" || no "A6 given creds overwritten [$sh]: $(cat "$d/res" 2>/dev/null)"

    command rm -f "$d/ks"; write_stash "$sh" in 11 "$N" "$P" "$S"
    [ ! -e "$d/ks" ] && ok "A7a the writer ignores an op other than out [$sh]" || no "A7a the writer fired for op in [$sh]"
    write_stash "$sh" out 11 "$N" "" "$S"
    [ ! -e "$d/ks" ] && ok "A7b the writer ignores an empty passphrase [$sh]" || no "A7b the writer stashed an empty passphrase [$sh]"
  done

  # Controls: the extraction found the real blocks, and the adopt really adopted (a filter matching nothing must not pass).
  case "$ablk" in *'"$_ksu" = "$uid"'*) ok "K1 the adopt block carries the uid comparison" ;; *) no "K1 the adopt block lost its uid comparison" ;; esac
  command rm -f "$d/ks"; write_stash bash out 11 "$N" "$P" "$S"; adopt bash 11 x ""
  grep -q "^NAME=<$N>" "$d/res" 2>/dev/null && ok "K2 A1 actually adopted" || no "K2 the adopt never adopted"
  command rm -rf "$d"

  [ -n "$quiet" ] || printf '  -- %d ok, %d failed\n' "$p" "$x"
  [ "$x" -eq 0 ] && return 0 || return 1
}

echo "== $SUT (shells: ${SHELLS[*]})"
suite "$SUT"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED)"
mut() { # mut <label> <sed-expr>
  local m r; m=$(mktemp)
  if ! sed -e "$2" "$SUT" > "$m"; then echo "  ERROR     $1 -- the mutant could not be written"; command rm -f "$m"; return 1; fi
  if cmp -s "$SUT" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; command rm -f "$m"; return 1; fi
  suite "$m" quiet 2>/dev/null; r=$?
  command rm -f "$m"
  if [ "$r" -eq 1 ]; then echo "  convicted $1"; return 0; fi
  echo "  NOT CONVICTED (rc=$r) $1"; return 1
}
fails=0
mut "M1 the uid comparison removed"        's/\[ -n "\$_ksu" \] && \[ "\$_ksu" = "\$uid" \]/[ -n "$_ksu" ]/' || fails=$((fails+1))
mut "M2 passphrase read from line 1"        's/pass=\$(sed -n 2p "\$KS_CREDS")/pass=$(sed -n 1p "$KS_CREDS")/' || fails=$((fails+1))
mut "M3 chip-secret export deleted"         '/\[ -n "\$_kss" \] && export NOWHERE_SE_SECRET/d' || fails=$((fails+1))
mut "M4 refusal log line deleted"           's/^      echo "\[roamd\] cleanstorage uid \$uid: keystore stash belongs.*$/      :/' || fails=$((fails+1))
mut "M5 adopt guard made unconditional"     's/{ \[ -z "\$name" \] || \[ -z "\$pass" \]; } && \[ -f "\$KS_CREDS" \]/{ [ -z "$name" ] || [ -z "$pass" ] || true; } \&\& [ -f "$KS_CREDS" ]/' || fails=$((fails+1))
mut "M6 writer uid and passphrase swapped" 's/print -r -- "\$pass"; print -r -- "\$uid";/print -r -- "$uid"; print -r -- "$pass";/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
