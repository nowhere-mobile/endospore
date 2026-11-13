#!/usr/bin/env bash
# test-canary-guard.sh [--mutate] [<build-dir>] -- a fleet device's OTA publish waits for the canary pass (NWP-20261202-12).
#
# Decided 2026-10-30 (docs/product-decisions.md, "every release is proved on a canary first -- husky joins the release
# devices on a user build, publishes alone, and the rest of the fleet publishes only after its smoke test passes") and
# 2026-11-04 h57 #2 ("nine answers to harvest 57 -- every recommendation accepted"): canary-guard.sh, called by
# e4-ota-publish.sh and e4-ota-promote.sh before any store write, refuses a fleet device for version V unless a valid
# editions/endospore/canary-pass/<V> names the canary's build and a passed smoke, or --without-canary is given and logged.
#
# Guard cases run canary-guard.sh under every shell found (bash, sh, dash, mksh; CG_TEST_SHELLS overrides). Executed
# cases run COPIES of e4-ota-publish.sh and e4-ota-promote.sh in scratch worlds with a recording stub agent: with no
# pass each refuses with the guard's line and the agent records no store verb; with a pass, or with --without-canary,
# the same run gets past the guard; husky (the canary) needs no pass. <build-dir> runs the cases against the scripts in
# another directory (the mutants use it).
#
#   bash test-canary-guard.sh            # the cases
#   bash test-canary-guard.sh --mutate   # ... plus mutants, each of which must be CONVICTED
set -uo pipefail

MUTATE=no; DIR=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; -*) echo "usage: $0 [--mutate] [<build-dir>]" >&2; exit 2 ;; *) DIR="$a" ;; esac; done
for t in zip unzip; do command -v "$t" >/dev/null 2>&1 || { echo "FAIL: $t is required" >&2; exit 1; }; done
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
DIR="${DIR:-$HERE}"
SCRIPTS="canary-guard.sh support-guard.sh e4-ota-publish.sh e4-ota-promote.sh"
for f in $SCRIPTS; do [ -s "$DIR/$f" ] || { echo "FAIL: $DIR/$f does not exist or is empty" >&2; exit 1; }; done
CG="$DIR/canary-guard.sh"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT
export TMPDIR="$W/tmp"; mkdir -p "$TMPDIR"
SHELLS="${CG_TEST_SHELLS:-}"
if [ -z "$SHELLS" ]; then for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done; fi

# The guard's three lines, byte for byte.
refusal() {   # <dev> <version>
  printf "refusing: %s %s has no canary pass -- commit editions/endospore/canary-pass/%s after husky's smoke passes, or pass --without-canary (docs/product-decisions.md, 2026-11-04 h57 #2)" "$1" "$2" "$2"
}
passline() {  # <dev> <version> <canary> <build> <date>
  printf 'canary-guard: %s %s follows canary %s build %s, smoke passed %s' "$1" "$2" "$3" "$4" "$5"
}
withoutline() {  # <dev> <version>
  printf 'canary-guard: WITHOUT CANARY: %s %s is published with no canary pass (--without-canary)' "$1" "$2"
}
GOOD=$'canary husky\nbuild 2026120101\nsmoke pass 2026-12-01\n'
pass() { printf '%s' "$GOOD" > "$1/$2"; }   # <canary-pass-dir> <version>
# empty_pass <dir>: a canary-pass dir holding only the README. A world never copies committed pass files, so a real
# one (0.5.55's, after that release) cannot turn a refusal case into a pass; passes come from pass().
empty_pass() { mkdir -p "$1" && cp "$ROOT/editions/endospore/canary-pass/README" "$1/"; }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }   # <text> <needle>

# ---- guard cases, under every shell ---------------------------------------------------------------------------------
# g <shell> <label> <want-rc> <dir> <want-stdout|-> <stderr-needle|-|=exact> <args...>: RC, OUT, ERR.
#   want-stdout: '-' = empty, else exact.  stderr: '-' = empty, '=<text>' = exact, else a needle.
g() {
  local s="$1" label="$2" want="$3" d="$4" wout="$5" werr="$6" o e; shift 6
  o=$(mktemp -p "$W") || return 1; e=$(mktemp -p "$W") || return 1
  NOWHERE_CANARY_PASS_DIR="$d" "$s" "$CG" "$@" > "$o" 2> "$e"; RC=$?
  OUT=$(cat "$o"); ERR=$(cat "$e")
  [ "$RC" = "$want" ] || { no "[$s] $label: exit $RC, want $want (stdout: $OUT; stderr: $ERR)"; return; }
  if [ "$wout" = - ]; then
    [ -z "$OUT" ] || { no "[$s] $label: stdout not empty: $OUT"; return; }
  else
    [ "$OUT" = "$wout" ] || { no "[$s] $label: stdout is not '$wout': $OUT"; return; }
  fi
  case "$werr" in
    - ) [ -z "$ERR" ] || { no "[$s] $label: stderr not empty: $ERR"; return; } ;;
    =* ) [ "$ERR" = "${werr#=}" ] || { no "[$s] $label: stderr is not exactly '${werr#=}': $ERR"; return; } ;;
    * ) has "$ERR" "$werr" || { no "[$s] $label: stderr lacks '$werr': $ERR"; return; } ;;
  esac
  ok "[$s] $label"
}

guard_cases() {
  local s d x m bad f fl
  for s in $SHELLS; do
    d=$(mktemp -d -p "$W") || return 1
    empty_pass "$d"
    g "$s" "G1 husky (the canary), no pass -> 0, silent" 0 "$d" - - husky 0.5.55
    g "$s" "G2 lynx (fleet), no pass -> 2, exactly the refusal" 2 "$d" - "=$(refusal lynx 0.5.55)" lynx 0.5.55
    g "$s" "G2b tegu (fleet), no pass, a two-part version -> 2" 2 "$d" - "=$(refusal tegu 1.0)" tegu 1.0
    g "$s" "G4 lynx, no pass, --without-canary -> 0, exactly the WITHOUT CANARY line" 0 "$d" - "=$(withoutline lynx 0.5.55)" lynx 0.5.55 --without-canary
    pass "$d" 0.5.55
    g "$s" "G3 lynx, a valid pass -> 0, exactly the pass line" 0 "$d" "$(passline lynx 0.5.55 husky 2026120101 2026-12-01)" - lynx 0.5.55
    g "$s" "G3b lynx, a valid pass and --without-canary -> 0, the pass line, no WITHOUT CANARY" 0 "$d" "$(passline lynx 0.5.55 husky 2026120101 2026-12-01)" - lynx 0.5.55 --without-canary
    g "$s" "G3c a pass for 0.5.55 does not cover 0.5.56 -> 2" 2 "$d" - "=$(refusal lynx 0.5.56)" lynx 0.5.56
    printf 'canary husky\nbuild 2026120101\nsmoke pass 2026-12-01' > "$d/0.5.57"
    g "$s" "G3d no final newline still counts three lines -> 0" 0 "$d" "$(passline lynx 0.5.57 husky 2026120101 2026-12-01)" - lynx 0.5.57
    m=0
    for bad in $'canary husky\nbuild 2026120101\n' \
               $'canary husky\nbuild 2026120101\nsmoke pass 2026-12-01\nextra\n' \
               $'canary husky\nbuild 2026120101\r\nsmoke pass 2026-12-01\n' \
               $'canary husky\nbuild 2026120101\nsmoke fail 2026-12-01\n' \
               $'canary husky\nbuild 202612010\nsmoke pass 2026-12-01\n' \
               $'canary lynx\nbuild 2026120101\nsmoke pass 2026-12-01\n' \
               $'canary husky\n\nsmoke pass 2026-12-01\n' \
               $'canary husky\nbuild 2026120101\nsmoke pass 2026-13-01\n' \
               ''; do
      m=$((m+1)); f="$d/0.5.60"; printf '%s' "$bad" > "$f"
      g "$s" "G5-11 malformed pass #$m -> 2, names the file" 2 "$d" - "malformed canary pass $f" lynx 0.5.60
      g "$s" "G5-11 malformed pass #$m with --without-canary -> still 2" 2 "$d" - "malformed canary pass $f" lynx 0.5.60 --without-canary
    done
    rm -f "$d/0.5.60"; mkdir "$d/0.5.60"
    g "$s" "G11b a pass that is a directory -> 2" 2 "$d" - "not a regular file" lynx 0.5.60
    g "$s" "G11b ... with --without-canary -> still 2" 2 "$d" - "not a regular file" lynx 0.5.60 --without-canary
    rmdir "$d/0.5.60"
    g "$s" "G12 the pass dir missing -> 2, names it" 2 "$W/none" - "no canary-pass directory at $W/none" lynx 0.5.55
    g "$s" "G12b the pass dir missing, husky -> 2 too" 2 "$W/none" - "no canary-pass directory at $W/none" husky 0.5.55
    for x in Lynx "" "../lynx" "lynx/x"; do
      g "$s" "G13 bad device '$x' -> 2" 2 "$d" - "bad device" "$x" 0.5.55
    done
    for x in ../x 0.5.55/../0.5.55 0 0.5.55.1 0.5.x ""; do
      g "$s" "G13 bad version '$x' -> 2" 2 "$d" - "bad version" lynx "$x"
    done
    g "$s" "G13 a version with a newline -> 2" 2 "$d" - "bad version" lynx $'0.5.55\n0.5.56'
    g "$s" "G13 no argument -> 2" 2 "$d" - "usage"
    g "$s" "G13 one argument -> 2" 2 "$d" - "usage" lynx
    g "$s" "G13 four arguments -> 2" 2 "$d" - "usage" lynx 0.5.55 --without-canary x
    g "$s" "G13 a third argument that is not --without-canary -> 2" 2 "$d" - "usage" lynx 0.5.55 --force
    # G14: unset, it reads ../canary-pass beside its own dir, never one beside the working directory.
    x=$(mktemp -d -p "$W") || return 1
    mkdir -p "$x/build" "$x/elsewhere/a" "$x/elsewhere/canary-pass"; cp "$CG" "$x/build/"; empty_pass "$x/canary-pass"; pass "$x/canary-pass" 0.5.55
    OUT=$(cd "$x/elsewhere/a" && env -u NOWHERE_CANARY_PASS_DIR "$s" "$x/build/canary-guard.sh" lynx 0.5.55 2>&1); RC=$?
    { [ "$RC" = 0 ] && [ "$OUT" = "$(passline lynx 0.5.55 husky 2026120101 2026-12-01)" ]; } \
      && ok "[$s] G14 the default dir is <guard>/../canary-pass, not <cwd>/../canary-pass" || no "[$s] G14 default dir: exit $RC: $OUT"
    # G15: the guard writes nothing.
    fl=$(cd "$d" && ls -lA --time-style=full-iso . 2>/dev/null)
    NOWHERE_CANARY_PASS_DIR="$d" "$s" "$CG" lynx 0.5.99 --without-canary >/dev/null 2>&1
    NOWHERE_CANARY_PASS_DIR="$d" "$s" "$CG" lynx 0.5.55 >/dev/null 2>&1
    [ "$fl" = "$(cd "$d" && ls -lA --time-style=full-iso . 2>/dev/null)" ] && ok "[$s] G15 the guard writes nothing in the pass dir" \
      || no "[$s] G15 the pass dir changed"
  done
}

# ---- executed cases: copies of the two scripts in scratch worlds ----------------------------------------------------
# e4-ota-publish.sh, in test-support-guard.sh's layout. publish_world <dev> <pass-version|-> -> prints its dir.
publish_world() {
  local T B dev="$1"
  T=$(mktemp -d -p "$W" pub.XXXXXX) || return 1; B="$T/editions/endospore/build"
  mkdir -p "$B" "$T/editions/endospore/ota-mandatory" "$T/core/vendor-common/etc/ota-notes" "$T/rel" "$T/img/SYSTEM/etc"
  cp "$DIR/e4-ota-publish.sh" "$DIR/support-guard.sh" "$DIR/canary-guard.sh" "$B/"
  mkdir -p "$T/editions/endospore/support-ended"; cp "$ROOT/editions/endospore/support-ended/README" "$T/editions/endospore/support-ended/"
  empty_pass "$T/editions/endospore/canary-pass"
  [ "$2" = - ] || pass "$T/editions/endospore/canary-pass" "$2"
  printf '#!/bin/sh\nexit 0\n' > "$B/check-agent-fresh.sh"; chmod +x "$B/check-agent-fresh.sh"
  echo 0.5.43 > "$T/core/vendor-common/etc/nowhere-ota-version"; echo 0.5.43 > "$T/img/SYSTEM/etc/nowhere-ota-version"
  printf 'version 0.5.43\nprevious 0.5.42\n- A point.\n' > "$T/core/vendor-common/etc/ota-notes/0.5.43"
  cp "$T/core/vendor-common/etc/ota-notes/0.5.43" "$T/img/SYSTEM/etc/nowhere-ota-notes"
  (cd "$T/img" && zip -qr "$T/rel/$dev-target_files.zip" SYSTEM)
  printf 'p' > "$T/payload.bin"; printf 'q' > "$T/payload_properties.txt"
  (cd "$T" && zip -q "$T/rel/$dev-ota_update-1.zip" payload.bin payload_properties.txt)
  printf 'S3_ENDPOINT=x\nS3_REGION=x\nS3_BUCKET=x\nS3_ACCESS_KEY=x\nS3_SECRET_KEY=x\n' > "$T/conf"
  printf '#!/bin/sh\necho "agent $*" >> "$(dirname "$0")/rec"\n[ "$1" = ota-check ] && { echo "ota-check: no published OS version"; exit 3; }\nexit 0\n' > "$T/agent"
  chmod +x "$T/agent"
  printf '%s\n' "$T"
}
pub_run() {   # <T> <dev> [flags...]: RC, OUT
  local T="$1" dev="$2"; shift 2
  OUT=$(bash "$T/editions/endospore/build/e4-ota-publish.sh" --device "$dev" "$@" "$T/rel/$dev-ota_update-1.zip" 0.5.43 "$T/conf" "$T/agent" 2>&1 < /dev/null); RC=$?
}
# e4-ota-promote.sh: the stub agent answers ota-check with 0.5.43 on the beta ring, an absent stable ring.
promote_world() {   # <pass-version|-> -> prints its dir; the script copy is in <dir>/build
  local T
  T=$(mktemp -d -p "$W" pro.XXXXXX) || return 1
  mkdir -p "$T/build"; cp "$DIR/e4-ota-promote.sh" "$DIR/support-guard.sh" "$DIR/canary-guard.sh" "$T/build/"
  printf '#!/bin/sh\nexit 0\n' > "$T/build/check-agent-fresh.sh"; chmod +x "$T/build/check-agent-fresh.sh"
  mkdir -p "$T/support-ended"; cp "$ROOT/editions/endospore/support-ended/README" "$T/support-ended/"
  empty_pass "$T/canary-pass"
  [ "$1" = - ] || pass "$T/canary-pass" "$1"
  printf 'S3_ENDPOINT=x\nS3_REGION=x\nS3_BUCKET=x\nS3_ACCESS_KEY=x\nS3_SECRET_KEY=x\n' > "$T/conf"
  cat > "$T/agent" <<'AGENT'
#!/bin/sh
T=$(dirname "$0")
echo "agent $* ref=$NOWHERE_OTA_VERSION_REF" >> "$T/rec"
case "$1" in
  ota-check)
    case "$NOWHERE_OTA_VERSION_REF" in
      *version-beta) echo "ota-check: UPDATE -> 0.5.43"; exit 0 ;;
      *) if [ -s "$T/marked" ]; then echo "ota-check: UPDATE -> $(cat "$T/marked")"; exit 0; fi
         echo "ota-check: no published OS version"; exit 3 ;;
    esac ;;
  ota-mark) echo "$3" > "$T/marked"; exit 0 ;;
esac
exit 0
AGENT
  chmod +x "$T/agent"
  printf '%s\n' "$T"
}
pro_run() {   # <T> <dev> [flags...]: RC, OUT
  local T="$1" dev="$2"; shift 2
  OUT=$(bash "$T/build/e4-ota-promote.sh" "$T/conf" --device "$dev" "$T/agent" --yes "$@" 2>&1 < /dev/null); RC=$?
}
rec() { cat "$1/rec" 2>/dev/null; }

publish_cases() {
  local T
  T=$(publish_world lynx -) || { no "publish world"; return; }
  pub_run "$T" lynx
  [ "$RC" = 2 ] && ok "E1 publish: lynx, no pass -> exit 2" || no "E1 publish: lynx, no pass: exit $RC, want 2: $OUT"
  has "$OUT" "$(refusal lynx 0.5.43)" && ok "E1 ... with the guard's refusal line" || no "E1 no refusal line: $OUT"
  [ ! -e "$T/rec" ] && ok "E1 ... and the agent recorded no verb (no store call)" || no "E1 the agent ran past the guard: $(rec "$T")"
  T=$(publish_world lynx 0.5.43) || { no "publish world"; return; }
  pub_run "$T" lynx
  { [ -s "$T/rec" ] && has "$OUT" "$(passline lynx 0.5.43 husky 2026120101 2026-12-01)" && ! has "$OUT" "refusing: lynx"; } \
    && ok "E2 publish: lynx with a pass for 0.5.43 gets past the guard, printing the pass line" || no "E2 publish with a pass: exit $RC: $OUT"
  has "$(rec "$T")" "agent ota-mark" && ok "E2 ... and reaches the ota-mark" || no "E2 no ota-mark recorded: $(rec "$T")"
  T=$(publish_world lynx -) || { no "publish world"; return; }
  pub_run "$T" lynx --without-canary
  { [ -s "$T/rec" ] && has "$OUT" "$(withoutline lynx 0.5.43)"; } \
    && ok "E3 publish: --without-canary gets past the guard, and the output holds the WITHOUT CANARY line" || no "E3 publish --without-canary: exit $RC: $OUT"
  T=$(publish_world husky -) || { no "publish world"; return; }
  pub_run "$T" husky
  { [ -s "$T/rec" ] && ! has "$OUT" "refusing: husky" && ! has "$OUT" "canary-guard:"; } \
    && ok "E4 publish: husky (the canary) needs no pass" || no "E4 publish husky: exit $RC: $OUT"
  T=$(publish_world lynx 0.5.42) || { no "publish world"; return; }
  pub_run "$T" lynx
  { [ "$RC" = 2 ] && has "$OUT" "$(refusal lynx 0.5.43)" && [ ! -e "$T/rec" ]; } \
    && ok "E4b publish: a pass for another version does not open 0.5.43" || no "E4b publish with a pass for 0.5.42: exit $RC: $OUT"
}

promote_cases() {
  local T
  T=$(promote_world -) || { no "promote world"; return; }
  pro_run "$T" lynx
  [ "$RC" = 2 ] && ok "E5 promote: lynx, no pass -> exit 2" || no "E5 promote: lynx, no pass: exit $RC, want 2: $OUT"
  has "$OUT" "$(refusal lynx 0.5.43)" && ok "E5 ... with the guard's refusal line" || no "E5 no refusal line: $OUT"
  has "$(rec "$T")" "ota-mark" && no "E5 ... but an ota-mark was recorded: $(rec "$T")" || ok "E5 ... and no ota-mark was recorded"
  [ "$(rec "$T")" = "agent ota-check s3 ref=ota/lynx/version-beta" ] && ok "E5 ... the only agent call was the source read" \
    || no "E5 the agent ran past the guard: $(rec "$T")"
  T=$(promote_world 0.5.43) || { no "promote world"; return; }
  pro_run "$T" lynx
  { [ "$RC" = 0 ] && has "$(rec "$T")" "agent ota-mark s3 0.5.43 ref=ota/lynx/version" && has "$OUT" "$(passline lynx 0.5.43 husky 2026120101 2026-12-01)"; } \
    && ok "E6 promote: with a pass, ota-mark 0.5.43 is recorded" || no "E6 promote with a pass: exit $RC: $OUT / $(rec "$T")"
  T=$(promote_world -) || { no "promote world"; return; }
  pro_run "$T" lynx --without-canary
  { [ "$RC" = 0 ] && has "$(rec "$T")" "agent ota-mark s3 0.5.43" && has "$OUT" "$(withoutline lynx 0.5.43)"; } \
    && ok "E7 promote: --without-canary marks, and the output holds the WITHOUT CANARY line" || no "E7 promote --without-canary: exit $RC: $OUT"
  T=$(promote_world -) || { no "promote world"; return; }
  pro_run "$T" husky
  { [ "$RC" = 0 ] && has "$(rec "$T")" "agent ota-mark s3 0.5.43"; } && ok "E8 promote: husky (the canary) needs no pass" \
    || no "E8 promote husky: exit $RC: $OUT"
}

# Source pins: each call appears once, at column 0, in the right place.
source_pins() {
  local P="$DIR/e4-ota-publish.sh" R="$DIR/e4-ota-promote.sh" n r a s m
  n=$(grep -n '^sh .*canary-guard\.sh' "$P" | cut -d: -f1)
  r=$(grep -n '^if \[ "\$RING" != stable \] && \[ "\$STABLE_CURRENT" != 1 \]; then$' "$P" | cut -d: -f1)
  a=$(grep -n '^\[ -x "\$AGENT" \]' "$P" | cut -d: -f1)
  case "$n:$r:$a" in *[!0-9:]*|:*|*::*|*:) no "P1 e4-ota-publish.sh: one canary-guard call, the ring refusal and the agent check (found '$n' '$r' '$a')" ;;
    *) { [ "$n" -lt "$r" ] && [ "$n" -lt "$a" ]; } && ok "P1 e4-ota-publish.sh calls the guard once, before the ring refusal and the agent check" \
         || no "P1 the publish call (line $n) is not before the ring refusal ($r) and the agent check ($a)" ;;
  esac
  n=$(grep -n '^sh .*canary-guard\.sh' "$R" | cut -d: -f1)
  s=$(grep -n '^\[ -n "\$SRC" \]' "$R" | cut -d: -f1)
  m=$(grep -n '"\$AGENT" ota-mark' "$R" | cut -d: -f1)
  case "$n:$s:$m" in *[!0-9:]*|:*|*::*|*:) no "P2 e4-ota-promote.sh: one canary-guard call, the SRC check and one ota-mark (found '$n' '$s' '$m')" ;;
    *) { [ "$s" -lt "$n" ] && [ "$n" -lt "$m" ]; } && ok "P2 e4-ota-promote.sh calls the guard once, after the SRC check and before the ota-mark" \
         || no "P2 the promote call (line $n) is not between the SRC check ($s) and the ota-mark ($m)" ;;
  esac
}

guard_cases
publish_cases
promote_cases
source_pins

if [ "$MUTATE" = yes ]; then
  [ "$FAIL" -eq 0 ] || { echo "$PASS passed, $FAIL failed -- not mutating a failing suite"; exit 1; }
  echo "== mutants =="
  # mut <id> <convicted-by> <file> <awk program over the file>: the mutant replaces one script in a copy of the four.
  mut() {
    local id="$1" by="$2" f="$3" prog="$4" M s rc f2
    M=$(mktemp -d -p "$W" mut.XXXXXX) || return 1
    for f2 in $SCRIPTS; do cp "$DIR/$f2" "$M/"; done
    awk "$prog" "$DIR/$f" > "$M/$f"
    if cmp -s "$DIR/$f" "$M/$f"; then no "MUTANT DID NOT APPLY: $id"; return; fi
    if [ "$f" = canary-guard.sh ]; then
      for s in $SHELLS; do
        CG_TEST_SHELLS=$s bash "$0" "$M" >/dev/null 2>&1; rc=$?
        [ "$rc" != 0 ] && ok "convicted $id [$s] (by $by)" || no "NOT CONVICTED $id [$s] (want: $by)"
      done
    else
      CG_TEST_SHELLS=sh bash "$0" "$M" >/dev/null 2>&1; rc=$?
      [ "$rc" != 0 ] && ok "convicted $id (by $by)" || no "NOT CONVICTED $id (want: $by)"
    fi
  }
  mut C1-canary-list-check-removed "G2, E1, E5" canary-guard.sh '{sub(/^is_canary "\$DEV" && exit 0$/,"exit 0")} {print}'
  mut C2-file-existence-inverted "G2, G3" canary-guard.sh '{sub(/^if \[ -e "\$F" \] \|\| \[ -L "\$F" \]; then$/,"if ! { [ -e \"$F\" ] || [ -L \"$F\" ]; }; then")} {print}'
  mut C3-line-count-check-removed "G5-11 #2 (4 lines)" canary-guard.sh '!/^  \[ "\$N" = 3 \] \|\| bad/'
  mut C4-smoke-word-check-removed "G5-11 #4 (smoke fail)" canary-guard.sh '/\^smoke pass /{sub(/\^smoke pass /,"^smoke [a-z]+ ")} {print}'
  mut C5-without-canary-silent "G4, E3, E7" canary-guard.sh '!/^  echo "canary-guard: WITHOUT CANARY: /'
  mut C6-flag-overrides-malformed "G5-11 with --without-canary" canary-guard.sh '{print} /^bad\(\) \{$/{print "  [ -n \"$WITHOUT\" ] && exit 0"}'
  mut C7-pass-dir-from-PWD "G14" canary-guard.sh '{sub(/\$HERE\/\.\.\/canary-pass/,"$PWD/../canary-pass")} {print}'
  mut C8-publish-call-removed "E1, P1" e4-ota-publish.sh '!/^sh .*canary-guard\.sh/'
  mut C9-promote-call-removed "E5, P2" e4-ota-promote.sh '!/^sh .*canary-guard\.sh/'
  mut C10-promote-call-after-ota-mark "E5 (ota-mark recorded), P2" e4-ota-promote.sh \
    '/^sh .*canary-guard\.sh/{c=$0; next} {print} /^NOWHERE_OTA_VERSION_REF=.*"\$AGENT" ota-mark/{print c}'
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
