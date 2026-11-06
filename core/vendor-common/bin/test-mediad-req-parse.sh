#!/usr/bin/env bash
# test-mediad-req-parse.sh [<nowhere_mediad.sh>] [--mutate] -- the mediad launcher's request parse (NWP-20261123-21),
# run for real rather than grepped, under EVERY shell found.
#
# kickMediad publishes mediad.req by temp + rename, as the daemon publishes roam.req (NWP-20260917-13), so any ONE
# open of $REQ sees exactly one whole request. That only helps if the launcher reads all four lines from a single
# open: four separate `sed -n Np "$REQ"` opens can straddle a second kick's rename and hand mediad the name of one
# request and the pass of the next. The cases here pin:
#   - all four values land, verbatim (a pass with a backslash, leading spaces and a `$` survives untouched, and a
#     pass ending in one backslash neither eats the newline nor swallows the uid after it);
#   - a short request leaves the missing trailing fields EMPTY, as sed did, and a last line with no newline lands;
#   - a short request clears values the launcher's environment already held, it does not keep them;
#   - the req (it holds the passphrase) is removed once parsed, and a missing req logs `no req` and exits;
#   - a rename over $REQ between two reads cannot mix two requests: `read` and `sed` are wrapped so the FIRST call
#     swaps a second request in, and every value must still come from the first;
#   - the reads are not chained with &&. With the reset line above them a chain behaves the same today, so no
#     behaviour case can tell; it is pinned on the text because the chain is safe only while that reset line
#     stays, and a chain hides the coupling. The mutant that drops both is convicted by the stale-value case.
#
# SHELLS. The device runs this block under mksh (/system/bin/sh), and `read`'s backslash, IFS and no-final-newline
# behaviour is exactly where shells differ. So each case writes the block into a runner script and runs it as
# `"$sh" runner.sh` under each of bash, sh, dash and mksh found by `command -v` -- each under its OWN name, no de-dup
# by resolved path (bash run as sh is in POSIX mode). Every ok/FAIL line carries its shell's [<sh>] tag. The runner
# is POSIX only: the launcher has no `set -u`, so neither has the runner.
#
# The block is extracted from nowhere_mediad.sh BY ANCHOR, from the `[ -f "$REQ" ]` line to the `rm -f "$REQ"` line,
# never copied; if the anchors move, extraction fails loudly rather than a stale copy passing forever. The end
# anchor does not require column 1, so a mutant that prefixes that line still bounds the block, and a block over 15
# lines is refused (rc 2): a runaway extraction must never execute the rest of the launcher (its exec of the agent).
#
# Temps: one root with an EXIT trap; every case dir and mutant copy is made inside it.
#
#   bash test-mediad-req-parse.sh            # the behaviour cases
#   bash test-mediad-req-parse.sh --mutate   # ... plus mutations that must each CONVICT the suite under EACH shell:
#                                            #     a FAILED [<sh>] line naming the mutant's own case for every shell
#                                            #     found; a mutant that does not apply, or a harness rc 2, is a failure
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_mediad.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

SHELLS=""
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "no shell found" >&2; exit 2; }

# --- extraction -----------------------------------------------------------------------------------------
# extract <mediad.sh> -> the block on stdout, or rc 2 with the reason on stderr
extract(){
  local b n
  b=$(sed -n '/^\[ -f "\$REQ" \] || /,/rm -f "\$REQ" /p' "$1")
  case "$b" in *'no req'*) ;; *) echo "EXTRACTION FAILED: no [ -f \"\$REQ\" ] anchor in $1" >&2; return 2 ;; esac
  case "$b" in *'rm -f "$REQ"'*) ;; *) echo "EXTRACTION FAILED: no rm -f \"\$REQ\" anchor in $1" >&2; return 2 ;; esac
  n=$(printf '%s\n' "$b" | wc -l)
  [ "$n" -le 15 ] || { echo "EXTRACTION FAILED: $n lines from the anchors -- the block ran past rm -f \"\$REQ\" in $1" >&2; return 2; }
  printf '%s\n' "$b"
}

# --- the suite ------------------------------------------------------------------------------------------
# suite <mediad.sh> [quiet] -> 0 every case passed under every shell, 1 a case failed, 2 harness. Quiet prints only
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
  # parse <dir> [swap|stale] -> runs the block under "$sh" against <dir>/mediad.req and prints the four fields, one
  # per line. With "swap", the first `read` or `sed` call renames <dir>/next.req over mediad.req -- a second kick
  # publishing the NEXT request while the launcher is mid-parse. The wrappers are POSIX: `command read` /
  # `command sed` reach the shadowed builtin/utility in bash, dash and mksh alike (no `builtin`, no `local`), and
  # `swaprc` is a name the block never uses. With "stale", the four variables hold STALE-* values before the block,
  # as an inherited environment would.
  parse(){
    local d="$1" mode="${2:-}"
    {
      printf "T='%s'\n" "$d"
      printf '%s\n' 'REQ="$T/mediad.req"; STATE="$T"; LOG="$T/log"'
      if [ "$mode" = stale ]; then
        printf '%s\n' 'name=STALE-name; pass=STALE-pass; uid=STALE-uid; sesec=STALE-sesec'
      fi
      if [ "$mode" = swap ]; then cat <<'EOF'
read() { command read "$@"; swaprc=$?; [ -e "$T/next.req" ] && mv -f "$T/next.req" "$REQ"; return $swaprc; }
sed() { command sed "$@"; swaprc=$?; [ -e "$T/next.req" ] && mv -f "$T/next.req" "$REQ"; return $swaprc; }
EOF
      fi
      printf '%s\n' "$BLOCK"
      printf '%s\n' 'printf '"'"'%s\n'"'"' "$name" "$pass" "$uid" "$sesec"'
    } > "$d/runner.sh"
    "$sh" "$d/runner.sh" 2>"$d/stderr"
  }

  for sh in $SHELLS; do
    say "== [$sh] a full request: all four lines, verbatim =="
    T=$(mktemp -d -p "$W")
    printf '%s\n' profile-a passphrase-a 10 abc123 > "$T/mediad.req"
    got=$(parse "$T")
    want "a full request parses all four fields" "$got" profile-a passphrase-a 10 abc123
    [ ! -e "$T/mediad.req" ] && ok "the req is removed once parsed" || no "the req (it holds the passphrase) was left behind"
    [ ! -s "$T/stderr" ] && ok "a full request parses with nothing on stderr" \
      || no "a full request parses with nothing on stderr (got '$(cat "$T/stderr")')"

    say "== [$sh] a passphrase is taken byte for byte =="
    T=$(mktemp -d -p "$W")
    P='  back\slash $HOME \n end\'
    printf '%s\n' profile-a "$P" 10 '' > "$T/mediad.req"
    got=$(parse "$T")
    pass_got=$(printf '%s\n' "$got" | sed -n 2p)
    [ "$pass_got" = "$P" ] && ok "a pass with a backslash, leading spaces and a \$ survives untouched" \
      || no "a pass with a backslash, leading spaces and a \$ survives untouched (got '$pass_got')"

    # A `read` without -r takes a trailing backslash as a line continuation: pass becomes `tail10`, uid empties.
    T=$(mktemp -d -p "$W")
    printf '%s\n' profile-a 'tail\' 10 '' > "$T/mediad.req"
    got=$(parse "$T")
    want "a pass ending in one backslash comes back verbatim and the uid after it stays its own" "$got" \
      profile-a 'tail\' 10 ''

    say "== [$sh] a short request leaves the missing fields empty =="
    T=$(mktemp -d -p "$W")
    printf '%s\n' profile-a passphrase-a 10 > "$T/mediad.req"
    got=$(parse "$T")
    want "a 3-line request leaves sesec empty" "$got" profile-a passphrase-a 10 ''
    [ ! -e "$T/mediad.req" ] && ok "a short req is removed too" || no "a short req was left behind"

    T=$(mktemp -d -p "$W")
    printf 'profile-a\npassphrase-a\n10\nabc123' > "$T/mediad.req"
    got=$(parse "$T")
    want "a last line with no trailing newline still lands" "$got" profile-a passphrase-a 10 abc123

    T=$(mktemp -d -p "$W")
    printf 'profile-a\npassphrase-a' > "$T/mediad.req"
    got=$(parse "$T" stale)
    want "a short request clears stale values, it does not keep them" "$got" profile-a passphrase-a '' ''

    say "== [$sh] no request: logs no req, nothing parsed =="
    T=$(mktemp -d -p "$W")
    got=$(parse "$T")
    if [ -z "$got" ] && grep -q '^\[mediad\] no req ' "$T/log" 2>/dev/null; then ok "a missing req logs no req and exits"
    else no "a missing req logs no req and exits (log='$(cat "$T/log" 2>/dev/null)' out='${got//$'\n'/|}')"; fi

    say "== [$sh] a rename between reads cannot mix two requests =="
    T=$(mktemp -d -p "$W")
    printf '%s\n' profile-a passphrase-a 10 sesec-a > "$T/mediad.req"
    printf '%s\n' profile-b passphrase-b 11 sesec-b > "$T/next.req"
    got=$(parse "$T" swap)
    [ ! -e "$T/next.req" ] && ok "the swap fired (control: the next request was renamed in mid-parse)" \
      || no "the swap never fired under $sh -- the parse made no read/sed call, so this case proves nothing"
    want "every field comes from the request that was open, none from the one renamed in" "$got" \
      profile-a passphrase-a 10 sesec-a

    say "== [$sh] the reads are separate statements =="
    # Structural, see the header: with the reset line a && chain is equivalent today, so only the text can pin it.
    case "$BLOCK" in
      *'&& IFS= read'*) no "the reads are not chained with && (a chain is safe only while the reset line stays)" ;;
      *) ok "the reads are not chained with &&" ;;
    esac
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
# mut <name> <regex a FAILED [<sh>] line must match, for EACH shell found> <sed-expr>...
mut(){
  local name="$1" need="$2" t out r s conv n e
  shift 2
  local args=()
  for e in "$@"; do args+=(-e "$e"); done
  t=$(mktemp -p "$W")
  if ! sed "${args[@]}" "$SUT" > "$t" 2>"$t.err"; then echo "  FAIL  MUTATION BROKEN (sed): $name"; MFAIL=1; return; fi
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
mut "back to four per-line sed opens" 'every field comes from the request that was open' \
  's@^{ IFS= read -r name; .*} < "\$REQ"\(.*\)$@name=$(sed -n 1p "$REQ"); pass=$(sed -n 2p "$REQ"); uid=$(sed -n 3p "$REQ"); sesec=$(sed -n 4p "$REQ")\1@'
mut "read without -r (backslashes eaten)" 'a pass ending in one backslash' \
  '/^{ IFS= read -r name; /s@read -r @read @g'
mut "read without IFS= (leading spaces stripped)" 'a pass with a backslash, leading spaces' \
  '/^{ IFS= read -r name; /s@IFS= read@read@g'
mut "sesec (line 4) no longer read" 'a full request parses all four fields' \
  '/^{ IFS= read -r name; /s@ IFS= read -r sesec;@@'
mut "the reads chained with &&" 'the reads are not chained with &&' \
  '/^{ IFS= read -r name; /s@; IFS= read@ \&\& IFS= read@g'
mut "the reads chained with && and the reset line dropped" 'a short request clears stale values' \
  '/^name=""; pass=""; uid=""; sesec=""$/d' '/^{ IFS= read -r name; /s@; IFS= read@ \&\& IFS= read@g'
mut "the req is not removed" 'the req \(it holds the passphrase\) was left behind' \
  's@^rm -f "\$REQ"  @: rm -f "$REQ"@'

if [ "$MFAIL" = 0 ]; then echo "== all mutations convicted"; else echo "== a mutation was not convicted"; exit 1; fi
