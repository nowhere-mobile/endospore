#!/usr/bin/env bash
# test-login-anr-read.sh [--mutate] -- the login daemon may READ /data/anr (anr_data_file), and nothing more
# (NWP-20261205-11; backlog: "The login daemon's SELinux domain has no rule on `anr_data_file`, so on an enforcing
# build the session's `/data/anr` snapshot is never taken and no issue report carries an anr section").
#
# WHY COMMITTED. The login daemon runs as u:r:nowhere:s0. recordAnrSeen (core/agent/report_issue.go) lists
# /data/anr at sign-in and anrHeaders reads the new traces' headers into an issue report. With no rule on
# anr_data_file both are denied on an enforcing build: on lynx 2026102201 (2026-10-24) every sign-in logged
# `anr snapshot not taken (open /data/anr: permission denied)`. The 2026-11-14 decision (F12) grants READ only.
# Nothing breaks at build time when a line goes, and nothing breaks when the grant is widened, so this pins:
#   C1. `allow nowhere anr_data_file:dir r_dir_perms;` exactly once, a whole line, uncommented, in nowhere.te;
#   C2. `allow nowhere anr_data_file:file r_file_perms;` the same;
#   C3. no other rule gives `nowhere` anything on anr_data_file: the nowhere.te statements that start
#       `allow nowhere` (the whole token) and name anr_data_file are exactly those two;
#   C4. no neverallow in any *.te under core/ or editions/ names the token `nowhere` with anr_data_file;
#   C5. control: `allow nowhere system_file:file r_file_perms;` exactly once, so a broken grep cannot pass;
#   C6. premise: report_issue.go holds `var anrDir = "/data/anr"` exactly once.
# The policy compile (the real neverallow check) and an enforcing sign-in with no `anr snapshot not taken` line
# are the build host's and the merger's.
#
#   bash test-login-anr-read.sh            # the checks
#   bash test-login-anr-read.sh --mutate   # ... plus broken copies that must each be CONVICTED
#
# TE=<file>, POLICY_DIRS="<dir> ..." and RI=<report_issue.go> override the inputs (a mutant copy, or
# origin/main's nowhere.te).
set -uo pipefail
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TE="${TE:-$ROOT/core/vendor-common/sepolicy/nowhere.te}"
POLICY_DIRS="${POLICY_DIRS:-$ROOT/core $ROOT/editions}"
RI="${RI:-$ROOT/core/agent/report_issue.go}"
[ -f "$TE" ] || { echo "no such file: $TE" >&2; exit 2; }
[ -f "$RI" ] || { echo "no such file: $RI" >&2; exit 2; }
for d in $POLICY_DIRS; do [ -d "$d" ] || { echo "no such dir: $d" >&2; exit 2; }; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

DIR_LINE='allow nowhere anr_data_file:dir r_dir_perms;'
FILE_LINE='allow nowhere anr_data_file:file r_file_perms;'
CONTROL='allow nowhere system_file:file r_file_perms;'
PREMISE='var anrDir = "/data/anr"'
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

# stmts <file...>: comments stripped, split into statements on ';' AND before every allow/neverallow/dontaudit
# token. A macro line such as `net_domain(nowhere)` ends with no ';', so a ';'-only split glues the next rule onto
# it and hides it. The leading-space anchor keeps `neverallow` whole.
stmts(){
  sed 's/#.*//' "$@" | tr '\n' ' ' | tr ';' '\n' \
    | sed -E 's/(^|[[:space:]])(allow|neverallow|dontaudit)[[:space:]]/\n\2 /g'
}
# names <type...>: awk filter -- the statement holds each type as a whole token (nowhere != nowhere_chooser).
NAMES_AWK='function has(w,  i, n, t) { n = split($0, t, /[^A-Za-z0-9_]+/); for (i = 1; i <= n; i++) if (t[i] == w) return 1; return 0 }'

c_exact(){ local n; n=$(grep -cxF -- "$2" "$1"); [ "$n" = 1 ]; }
c_dir(){ c_exact "$1" "$DIR_LINE"; }
c_file(){ c_exact "$1" "$FILE_LINE"; }
c_control(){ c_exact "$1" "$CONTROL"; }
c_premise(){ c_exact "$1" "$PREMISE"; }
# c_only <te>: the allow statements for `nowhere` naming anr_data_file are exactly the two lines.
c_only(){
  local got want
  got=$(stmts "$1" | awk "$NAMES_AWK"' $1 == "allow" && $2 == "nowhere" && has("anr_data_file") { $1 = $1; print }' | sort)
  want=$(printf '%s\n%s\n' "${DIR_LINE%;}" "${FILE_LINE%;}" | sort)
  [ "$got" = "$want" ]
}
# c_never <dir...>: no neverallow in any *.te under the dirs names both tokens. An empty file list fails.
c_never(){
  local files hit
  files=$(find "$@" -name '*.te' -type f 2>/dev/null) || return 1
  [ -n "$files" ] || return 1
  # shellcheck disable=SC2086
  hit=$(stmts $files | awk "$NAMES_AWK"' $1 == "neverallow" && has("nowhere") && has("anr_data_file") { print }')
  [ -z "$hit" ]
}

echo "== the login daemon may read /data/anr =="
c_dir "$TE"     && ok "C1 nowhere.te holds '$DIR_LINE' exactly once, uncommented" \
                || no "C1 the anr_data_file dir read is missing, commented out, reshaped or duplicated in $TE"
c_file "$TE"    && ok "C2 nowhere.te holds '$FILE_LINE' exactly once, uncommented" \
                || no "C2 the anr_data_file file read is missing, commented out, reshaped or duplicated in $TE"
c_only "$TE"    && ok "C3 no other rule gives nowhere anything on anr_data_file" \
                || no "C3 the nowhere rules on anr_data_file are not exactly the two read lines"
# shellcheck disable=SC2086
c_never $POLICY_DIRS && ok "C4 no neverallow names nowhere with anr_data_file" \
                     || no "C4 a neverallow in the policy names nowhere with anr_data_file"
echo "== control and premise =="
c_control "$TE" && ok "C5 control: the system_file read is still present" \
                || no "C5 control: the system_file read is gone -- the check itself cannot be trusted"
c_premise "$RI" && ok "C6 premise: report_issue.go reads anrDir = \"/data/anr\"" \
                || no "C6 premise: report_issue.go no longer holds '$PREMISE'"

if [ "$MUTATE" = yes ]; then
  echo; echo "== mutations (each MUST be convicted by every check named) =="
  # mut <label> <file> <sed-expr> <check...>: a sed copy of <file>; every check named must FAIL on it.
  mut(){
    local label src expr x c bad names
    label=$1; src=$2; expr=$3; shift 3
    x=$(mktemp -p "$W")
    if ! sed "$expr" "$src" > "$x" 2>/dev/null; then no "MUTATION BROKEN (sed): $label"; return; fi
    if cmp -s "$src" "$x"; then no "MUTATION INERT: $label"; return; fi
    bad=; names=
    for c in "$@"; do
      names="$names${names:+, }$c"
      if "check_$c" "$x"; then bad="$bad $c"; fi
    done
    if [ -n "$bad" ]; then no "NOT CONVICTED by$bad: $label"; else ok "convicted by $names: $label"; fi
  }
  check_C1(){ c_dir "$1"; }
  check_C2(){ c_file "$1"; }
  check_C3(){ c_only "$1"; }
  check_C5(){ c_control "$1"; }
  check_C6(){ c_premise "$1"; }
  # plant <label> <text> <convict|pass>: <text> appended to a copy of TE in a dir of its own; C4 over that dir.
  plant(){
    local label text want nd
    label=$1; text=$2; want=$3
    nd=$(mktemp -d -p "$W")
    cp "$TE" "$nd/nowhere.te"
    printf '%s\n' "$text" >> "$nd/nowhere.te"
    if c_never "$nd"; then
      if [ "$want" = convict ]; then no "NOT CONVICTED by C4: $label"; else ok "not convicted, as it must not be: $label"; fi
    else
      if [ "$want" = convict ]; then ok "convicted by C4: $label"; else no "WRONGLY CONVICTED by C4: $label"; fi
    fi
  }
  D='allow nowhere anr_data_file:dir r_dir_perms;'
  F='allow nowhere anr_data_file:file r_file_perms;'
  mut "the dir line deleted"                    "$TE" "/^$D\$/d"                                     C1
  mut "the file line deleted"                   "$TE" "/^$F\$/d"                                     C2
  mut "the dir line commented out"              "$TE" "s/^$D\$/# &/"                                 C1
  mut "the file line commented out"             "$TE" "s/^$F\$/# &/"                                 C2
  mut "the dir line's class changed to file"    "$TE" "s/^allow nowhere anr_data_file:dir r_dir_perms;\$/allow nowhere anr_data_file:file r_dir_perms;/" C1 C3
  mut "the file line widened to rw_file_perms"  "$TE" "s/^allow nowhere anr_data_file:file r_file_perms;\$/allow nowhere anr_data_file:file rw_file_perms;/" C2 C3
  mut "an unlink rule appended"                 "$TE" '$a allow nowhere anr_data_file:file unlink;'  C3
  mut "an unlink rule right after net_domain(nowhere)" "$TE" '/^net_domain(nowhere)$/a allow nowhere anr_data_file:file unlink;' C3
  mut "the domain changed to nowhere_chooser"   "$TE" 's/^allow nowhere anr_data_file:/allow nowhere_chooser anr_data_file:/' C1 C2
  mut "the dir line duplicated"                 "$TE" "/^$D\$/p"                                     C1
  mut "the file line duplicated"                "$TE" "/^$F\$/p"                                     C2
  mut "the control (system_file read) deleted"  "$TE" "/^$CONTROL\$/d"                               C5
  mut "anrDir changed to /data/anr2"            "$RI" 's|^var anrDir = "/data/anr"$|var anrDir = "/data/anr2"|' C6
  plant "a multi-line neverallow naming nowhere with anr_data_file" \
        "$(printf 'neverallow nowhere {\n    anr_data_file # planted\n}:file read;')" convict
  plant "a neverallow naming only nowhere_chooser with anr_data_file" \
        'neverallow nowhere_chooser anr_data_file:file read;' pass
  plant "a commented neverallow naming nowhere with anr_data_file" \
        '# neverallow nowhere anr_data_file:file read;' pass
fi

echo; echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
