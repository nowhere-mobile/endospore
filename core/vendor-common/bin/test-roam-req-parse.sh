#!/usr/bin/env bash
# test-roam-req-parse.sh [<nowhere_roamd.sh>] [--mutate] -- roamd's generic request-header parse (NWP-20260917-13),
# run for real rather than grepped, under EVERY shell found (NWP-20261111-21).
#
# The daemon publishes roam.req (and roamro.req / roamcred.req) by temp + rename, so any ONE open of $REQ sees
# exactly one whole request. That only helps if roamd reads all seven lines from a single open: seven separate
# `sed -n Np "$REQ"` opens can straddle a rename and hand the worker op/name from one request and pass/uid from the
# next. The cases here pin:
#   - all seven values land, verbatim (a pass with a backslash, leading spaces and a `$` survives untouched, and a
#     pass ending in one backslash neither eats the newline nor swallows the uid after it);
#   - a short request leaves the missing trailing fields EMPTY, as sed did, and a last line with no newline lands;
#   - the exports that key on those fields still run after their variables are set;
#   - the req (it holds the passphrase) is removed once parsed;
#   - a rename over $REQ between two reads cannot mix two requests: `read` and `sed` are wrapped so the FIRST call
#     swaps a second request in, and every value must still come from the first.
#
# SHELLS. The device runs this block under mksh (/system/bin/sh), and `read`'s backslash, IFS and no-final-newline
# behaviour is exactly where shells differ. So each case writes the block into a runner script and runs it as
# `"$sh" runner.sh` under each of bash, sh, dash and mksh found by `command -v` -- each under its OWN name, no de-dup
# by resolved path (bash run as sh is in POSIX mode). Every ok/FAIL line carries its shell's [<sh>] tag. The runner
# is POSIX only: roamd has no `set -u`, so neither has the runner.
#
# The block is extracted from nowhere_roamd.sh BY ANCHOR, from the `[ -f "$REQ" ]` line to the `rm -f "$REQ"` line
# (the only one in the file), never copied; if the anchors move, extraction fails loudly rather than a stale copy
# passing forever. The end anchor does not require column 1, so a mutant that prefixes that line still bounds the
# block, and a block over 60 lines is refused (rc 2): a runaway extraction must never execute the rest of roamd.
#
# Temps: one root with an EXIT trap; every case dir and mutant copy is made inside it.
#
#   bash test-roam-req-parse.sh            # the behaviour cases
#   bash test-roam-req-parse.sh --mutate   # ... plus mutations that must each CONVICT the suite under EACH shell:
#                                          #     a FAILED [<sh>] line naming the mutant's own case for every shell
#                                          #     found; a mutant that does not apply, or a harness rc 2, is a failure
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

SHELLS=""
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "no shell found" >&2; exit 2; }

# --- extraction -----------------------------------------------------------------------------------------
# extract <roamd.sh> -> the block on stdout, or rc 2 with the reason on stderr
extract(){
  local b n
  b=$(sed -n '/^\[ -f "\$REQ" \] || /,/rm -f "\$REQ" /p' "$1")
  case "$b" in *ERR-NOREQ*) ;; *) echo "EXTRACTION FAILED: no [ -f \"\$REQ\" ] anchor in $1" >&2; return 2 ;; esac
  case "$b" in *'rm -f "$REQ"'*) ;; *) echo "EXTRACTION FAILED: no rm -f \"\$REQ\" anchor in $1" >&2; return 2 ;; esac
  case "$b" in *NOWHERE_UNIT_SRC*) ;; *) echo "EXTRACTION FAILED: the block lost its srcunit export in $1" >&2; return 2 ;; esac
  n=$(printf '%s\n' "$b" | wc -l)
  [ "$n" -le 60 ] || { echo "EXTRACTION FAILED: $n lines from the anchors -- the block ran past rm -f \"\$REQ\" in $1" >&2; return 2; }
  printf '%s\n' "$b"
}

# --- the suite ------------------------------------------------------------------------------------------
# suite <roamd.sh> [quiet] -> 0 every case passed under every shell, 1 a case failed, 2 harness. Quiet prints only
# `FAILED [<sh>] <label>` lines, which is what the mutation runner matches.
suite(){
  local f="$1" quiet="${2:-}" p=0 x=0 sh T got pass_got BLOCK P
  BLOCK=$(extract "$f") || return 2
  # Every failure goes through no() with the case's own label, so a mutant's regex can name it.
  ok(){ p=$((p+1)); [ -n "$quiet" ] || printf '  ok    [%s] %s\n' "$sh" "$1"; }
  no(){ x=$((x+1)); if [ -n "$quiet" ]; then echo "FAILED [$sh] $1"; else printf '  FAIL  [%s] %s\n' "$sh" "$1"; fi; }
  say(){ [ -n "$quiet" ] || echo "$1"; }
  # want <label> <got> <line...> -- compares got against the expected lines joined by newlines.
  want(){
    local label="$1" got="$2" exp; shift 2
    exp=$(printf '%s\n' "$@")
    if [ "$got" = "$exp" ]; then ok "$label"; else
      no "$label"
      [ -n "$quiet" ] || { printf '        got:  %s\n' "${got//$'\n'/|}"; printf '        want: %s\n' "${exp//$'\n'/|}"; }
    fi
  }
  # parse <dir> [swap] -> runs the block under "$sh" against <dir>/roam.req and prints the seven fields, keymode and
  # the three exports, one per line. With "swap", the first `read` or `sed` call renames <dir>/next.req over
  # roam.req -- the daemon publishing the NEXT request while this worker is mid-parse. The wrappers are POSIX:
  # `command read` / `command sed` reach the shadowed builtin/utility in bash, dash and mksh alike (no `builtin`, no
  # `local`), and `swaprc` is a name the block never uses.
  parse(){
    local d="$1" swap="${2:-}"
    {
      printf "T='%s'\n" "$d"
      printf '%s\n' 'REQ="$T/roam.req"; RES="$T/roam.res"; STATE="$T"; LOG="$T/log"' \
                    'unset NOWHERE_SE_SECRET NOWHERE_SEAL_KIND NOWHERE_UNIT_SRC'
      if [ "$swap" = swap ]; then cat <<'EOF'
read() { command read "$@"; swaprc=$?; [ -e "$T/next.req" ] && mv -f "$T/next.req" "$REQ"; return $swaprc; }
sed() { command sed "$@"; swaprc=$?; [ -e "$T/next.req" ] && mv -f "$T/next.req" "$REQ"; return $swaprc; }
EOF
      fi
      printf '%s\n' "$BLOCK"
      cat <<'EOF'
printf '%s\n' "$op" "$name" "$pass" "$uid" "$sesec" "$skind" "$srcunit" "$keymode" \
  "${NOWHERE_SE_SECRET-<unset>}" "${NOWHERE_SEAL_KIND-<unset>}" "${NOWHERE_UNIT_SRC-<unset>}"
EOF
    } > "$d/runner.sh"
    "$sh" "$d/runner.sh" 2>"$d/stderr"
  }

  for sh in $SHELLS; do
    say "== [$sh] a full request: all seven lines, verbatim, and the exports =="
    T=$(mktemp -d -p "$W")
    printf '%s\n' in profile-a 'passphrase-a' 10 abc123 nfcfirst unit-src-7 > "$T/roam.req"
    got=$(parse "$T")
    want "a full in request parses all seven fields" "$got" \
      in profile-a passphrase-a 10 abc123 nfcfirst unit-src-7 nfcfirst abc123 '<unset>' unit-src-7
    [ ! -e "$T/roam.req" ] && ok "the req is removed once parsed" || no "the req (it holds the passphrase) was left behind"
    [ ! -s "$T/stderr" ] && ok "a full request parses with nothing on stderr" \
      || no "a full request parses with nothing on stderr (got '$(cat "$T/stderr")')"

    T=$(mktemp -d -p "$W")
    printf '%s\n' out profile-a '' 10 '' manual '' > "$T/roam.req"
    got=$(parse "$T")
    want "a manual seal exports NOWHERE_SEAL_KIND and no keymode" "$got" \
      out profile-a '' 10 '' manual '' '' '<unset>' manual '<unset>'

    say "== [$sh] a passphrase is taken byte for byte =="
    T=$(mktemp -d -p "$W")
    P='  back\slash $HOME \n end\'
    printf '%s\n' in profile-a "$P" 10 '' '' '' > "$T/roam.req"
    got=$(parse "$T")
    pass_got=$(printf '%s\n' "$got" | sed -n 3p)
    [ "$pass_got" = "$P" ] && ok "a pass with a backslash, leading spaces and a \$ survives untouched" \
      || no "a pass with a backslash, leading spaces and a \$ survives untouched (got '$pass_got')"

    # A `read` without -r takes a trailing backslash as a line continuation: pass becomes `tail10`, uid empties.
    T=$(mktemp -d -p "$W")
    printf '%s\n' in profile-a 'tail\' 10 '' '' '' > "$T/roam.req"
    got=$(parse "$T")
    want "a pass ending in one backslash comes back verbatim and the uid after it stays its own" "$got" \
      in profile-a 'tail\' 10 '' '' '' '' '<unset>' '<unset>' '<unset>'

    say "== [$sh] a short request leaves the missing fields empty =="
    T=$(mktemp -d -p "$W")
    printf '%s\n' in profile-a passphrase-a 10 > "$T/roam.req"
    got=$(parse "$T")
    want "a 4-line request leaves sesec/skind/srcunit empty and exports nothing" "$got" \
      in profile-a passphrase-a 10 '' '' '' '' '<unset>' '<unset>' '<unset>'
    [ ! -e "$T/roam.req" ] && ok "a short req is removed too" || no "a short req was left behind"

    T=$(mktemp -d -p "$W")
    printf 'in\nprofile-a\npassphrase-a\n10\n\n\nunit-src-7' > "$T/roam.req"
    got=$(parse "$T")
    want "a last line with no trailing newline still lands" "$got" \
      in profile-a passphrase-a 10 '' '' unit-src-7 '' '<unset>' '<unset>' unit-src-7

    say "== [$sh] no request: ERR-NOREQ, nothing parsed =="
    T=$(mktemp -d -p "$W")
    got=$(parse "$T")
    [ -z "$got" ] && [ "$(cat "$T/roam.res" 2>/dev/null)" = "ERR-NOREQ" ] && ok "a missing req answers ERR-NOREQ and exits" \
      || no "a missing req answers ERR-NOREQ and exits (res='$(cat "$T/roam.res" 2>/dev/null)' out='${got//$'\n'/|}')"

    say "== [$sh] a rename between reads cannot mix two requests =="
    T=$(mktemp -d -p "$W")
    printf '%s\n' in profile-a passphrase-a 10 sesec-a nfcfirst unit-a > "$T/roam.req"
    printf '%s\n' out profile-b passphrase-b 11 sesec-b manual unit-b > "$T/next.req"
    got=$(parse "$T" swap)
    [ ! -e "$T/next.req" ] && ok "the swap fired (control: the next request was renamed in mid-parse)" \
      || no "the swap never fired under $sh -- the parse made no read/sed call, so this case proves nothing"
    want "every field comes from the request that was open, none from the one renamed in" "$got" \
      in profile-a passphrase-a 10 sesec-a nfcfirst unit-a nfcfirst sesec-a '<unset>' unit-a
  done

  say ""
  say "passed $p, failed $x (shells:$SHELLS)"
  [ "$x" = 0 ]
}

if [ "$MUTATE" = no ]; then suite "$SUT"; exit $?; fi
suite "$SUT"; rc=$?; [ "$rc" = 0 ] || exit "$rc"

# --- mutations ------------------------------------------------------------------------------------------
echo
echo "== mutations (each MUST be convicted under every shell:$SHELLS) =="
MFAIL=0
# mut <name> <sed-expr> <regex a FAILED [<sh>] line must match, for EACH shell found>
mut(){
  local name="$1" expr="$2" need="$3" t out r s conv n
  t=$(mktemp -p "$W")
  if ! sed "$expr" "$SUT" > "$t" 2>"$t.err"; then echo "  FAIL  MUTATION BROKEN (sed): $name"; MFAIL=1; return; fi
  if cmp -s "$SUT" "$t"; then echo "  FAIL  MUTATION INERT: $name"; MFAIL=1; return; fi
  out=$(suite "$t" quiet 2>&1); r=$?
  # Convicted only when EACH shell found printed a FAILED line for the mutant's own case. The count is CAPTURED
  # (grep -c reads all its input, so printf never takes SIGPIPE) and the decision rests on the number, never on a
  # `cmd | grep -q` status under pipefail.
  conv=1
  for s in $SHELLS; do
    n=$(printf '%s\n' "$out" | grep -cE -- "^FAILED \[$s\] $need")
    [ "${n:-0}" -ge 1 ] || conv=0
  done
  if [ "$r" = 1 ] && [ "$conv" = 1 ]; then echo "  ok    CONVICTED under$SHELLS: $name"
  else
    echo "  FAIL  NOT CONVICTED (rc=$r): $name"
    printf '%s\n' "$out" | grep -E '^(FAILED|EXTRACTION)' | head -8
    MFAIL=1
  fi
}
mut "back to seven per-line sed opens" \
  's@^{ IFS= read -r op; .*} < "\$REQ"$@op=$(sed -n 1p "$REQ"); name=$(sed -n 2p "$REQ"); pass=$(sed -n 3p "$REQ"); uid=$(sed -n 4p "$REQ"); sesec=$(sed -n 5p "$REQ"); skind=$(sed -n 6p "$REQ"); srcunit=$(sed -n 7p "$REQ")@' \
  'every field comes from the request that was open'
mut "read without -r (backslashes eaten)" '/^{ IFS= read -r op; /s@read -r @read @g' \
  'a pass ending in one backslash'
mut "read without IFS= (leading spaces stripped)" '/^{ IFS= read -r op; /s@IFS= read@read@g' \
  'a pass with a backslash, leading spaces'
mut "srcunit no longer read" '/^{ IFS= read -r op; /s@ IFS= read -r srcunit;@@' \
  'a full in request parses all seven fields'
mut "the req is not removed" 's@^rm -f "\$REQ"  @: rm -f "$REQ"@' \
  'the req \(it holds the passphrase\) was left behind'

if [ "$MFAIL" = 0 ]; then echo "== all mutations convicted"; else echo "== a mutation was not convicted"; exit 1; fi
