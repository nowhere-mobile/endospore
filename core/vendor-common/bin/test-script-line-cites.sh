#!/usr/bin/env bash
# test-script-line-cites.sh [--mutate] [--root=<git checkout>] -- the device scripts and the rc files cite code by
# symbol, never by line number.
#
# WHY THIS IS COMMITTED (NWP-20261122-20). The device scripts cited core/agent's main.go, the chooser's
# ChooserActivity.java, docs/fleet-lock-design.md and nowhere_roamd.sh itself by line number. The 2026-11-22 sweep
# found that every one of those citations had drifted to an unrelated line: a `return nil`, a `}`, an
# onCheckedChanged override. The cited files move by hundreds of lines a week, so a line citation is right on the day
# it is written and wrong soon after. docs/check_line_cites.py refuses line citations into backlog.md and worklog.md
# for the same reason; nothing guarded the scripts. Cite the function, the constant, the note or the quoted log text.
#
# WHAT IT SCANS: the six device scripts core/vendor-common/bin/nowhere_{gate,login,mediad,otad,provision,roamd}.sh
# and every core/vendor-common/etc/*.rc: each one git tracks, plus any other on disk. A missing or empty one is a
# harness failure (exit 2).
#
# WHAT FAILS (each offence prints <file>:<line>, the rule, the token and an excerpt):
#   (a) on any line, a `<name>.<ext>:<digits>` token whose basename is the basename of a file `git ls-files` lists.
#       A basename the repo does not track is an UPSTREAM citation (an AOSP source file, say). Upstream files do not
#       move under us, so it is allowed and counted. The CONTROL line prints that count and it must be > 0: a scan
#       that allowed nothing read nothing.
#   (b) in a comment, a self-citation: `:<two or more digits>` after a blank, `(` or `~` (`:574`, `(:3300-3301)`,
#       `~:259`), or `line <n>` / `lines <n>` with three or more digits.
#   (c) in a comment, a named-site self-citation `<word>:<3 to 5 digits>` (`cleanstorage:1060`). A clock time, a
#       uid:gid pair and a 7-digit namespace id do not match.
# Comment text is the whole line when its first non-blank is `#`, else the part from the first `#` after a blank (a
# space or a tab: `x=1<TAB># ...` is a comment too).
#
# THE ONE NAMED EXCEPTION. The odrestore arm of nowhere_roamd.sh says `odsrc` "is set at ~:4096 BEFORE the
# NWP-20260913-03 ownership probe". It means the arm's own `odsrc=1`. NOWHERE-1402 edits that arm, so this slice did
# not touch it. The exception is keyed by file and text, not by line, and it covers ONE offence: rule (b), token
# `~:4096`, on the one line that holds the text. Another citation on that line is an offence; so is a second copy of
# the text. The suite FAILS when the text is gone, so the exception cannot outlive the citation: when NOWHERE-1402
# lands, name `odsrc=1` there and delete EXC_* below.
#
# BASH ONLY. The suite reads the files as data with awk and runs no device code, so the every-shell rule for suites
# that execute daemon script code (bash, sh, dash, mksh) does not apply.
#
# Exit 0 = no offence; 1 = an offence, a stale exception or a failed mutant; 2 = a harness failure (no git, an empty
# `git ls-files`, a missing input, a CONTROL of 0, an unknown argument).
#
#   bash core/vendor-common/bin/test-script-line-cites.sh                 # scan the repo that holds the suite
#   bash core/vendor-common/bin/test-script-line-cites.sh --root=<dir>    # scan another checkout (origin/main, say)
#   bash core/vendor-common/bin/test-script-line-cites.sh --mutate        # ... plus planted copies that must CONVICT
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
MUTATE=no
for a in "$@"; do
  case "$a" in
    --mutate) MUTATE=yes ;;
    --root=*) ROOT="${a#--root=}" ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done

command -v git >/dev/null 2>&1 || { echo "harness: git is not installed" >&2; exit 2; }
command -v awk >/dev/null 2>&1 || { echo "harness: awk is not installed" >&2; exit 2; }
[ -d "$ROOT" ] || { echo "harness: no such root: $ROOT" >&2; exit 2; }

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT

TRACKED=$(git -C "$ROOT" ls-files) || { echo "harness: git ls-files failed in $ROOT" >&2; exit 2; }
[ -n "$TRACKED" ] || { echo "harness: git ls-files lists nothing in $ROOT" >&2; exit 2; }
BASES=$(mktemp -p "$W") || exit 2
printf '%s\n' "$TRACKED" | sed 's#.*/##' | sort -u > "$BASES"

SCRIPTS="core/vendor-common/bin/nowhere_gate.sh core/vendor-common/bin/nowhere_login.sh
core/vendor-common/bin/nowhere_mediad.sh core/vendor-common/bin/nowhere_otad.sh
core/vendor-common/bin/nowhere_provision.sh core/vendor-common/bin/nowhere_roamd.sh"
# The rc files git tracks. Each one MUST be on disk and non-empty: a glob alone would scan the files that are there
# and skip a deleted or emptied nowhere.rc in silence while another rc kept the loop busy.
TRACKED_RC=$(printf '%s\n' "$TRACKED" | grep '^core/vendor-common/etc/[^/]*\.rc$')
[ -n "$TRACKED_RC" ] || { echo "harness: git tracks no core/vendor-common/etc/*.rc file in $ROOT" >&2; exit 2; }

# collect_inputs <root>: set INPUTS to the six scripts, every tracked rc and every other rc on disk under <root>.
# Returns 2 when any of them is missing or empty, so the scan never passes blind.
INPUTS=""
collect_inputs() {
  local root="$1" f rel
  INPUTS=""
  for f in $SCRIPTS $TRACKED_RC; do
    [ -s "$root/$f" ] || { echo "harness: missing or empty input: $root/$f" >&2; return 2; }
    INPUTS="$INPUTS $f"
  done
  for f in "$root"/core/vendor-common/etc/*.rc; do
    [ -e "$f" ] || continue
    rel="core/vendor-common/etc/${f##*/}"
    case " $INPUTS " in *" $rel "*) continue ;; esac
    [ -s "$f" ] || { echo "harness: empty input: $f" >&2; return 2; }
    INPUTS="$INPUTS $rel"
  done
  return 0
}
collect_inputs "$ROOT" || exit 2

EXC_FILE=core/vendor-common/bin/nowhere_roamd.sh
EXC_TEXT='~:4096 BEFORE the NWP-20260913-03 ownership probe'
EXC_TASK=NOWHERE-1402
EXC_RULE='(b) self-citation'
EXC_TOK='~:4096'

# scan_awk <basenames> <rel> < <file>: one record per hit, tab-separated:
#   OFF <rel>:<n> <rule> <token> <excerpt>   an offence
#   UP  <rel>:<n> <token>                    an allowed upstream citation
# mawk has no {m,n} intervals, so the digit counts are spelled out.
scan_awk() {
  awk -v bases="$1" -v rel="$2" '
    BEGIN { while ((getline b < bases) > 0) tracked[b] = 1; close(bases) }
    function ex(s) { gsub(/\t/, " ", s); sub(/^[ ]+/, "", s); return length(s) > 140 ? substr(s, 1, 140) "..." : s }
    {
      line = $0
      # (a) every line.
      s = line
      while (match(s, /[A-Za-z0-9_.\/-]*[A-Za-z0-9_-]\.[A-Za-z][A-Za-z0-9]*:[0-9]+/)) {
        tok = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
        nm = tok; sub(/:[0-9]+$/, "", nm); sub(/.*\//, "", nm)
        if (nm in tracked) printf "OFF\t%s:%d\t(a) tracked file by line\t%s\t%s\n", rel, NR, tok, ex(line)
        else printf "UP\t%s:%d\t%s\n", rel, NR, tok
      }
      # Comment text for (b) and (c).
      c = ""
      if (line ~ /^[ \t]*#/) c = line
      else if (match(line, /[ \t]#/)) c = substr(line, RSTART + 1)
      if (c == "") next
      s = c
      while (match(s, /(^|[ (~]):[0-9][0-9]+/)) {
        tok = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH); sub(/^[ (]/, "", tok)
        printf "OFF\t%s:%d\t(b) self-citation\t%s\t%s\n", rel, NR, tok, ex(line)
      }
      s = c
      while (match(s, /lines? [0-9][0-9][0-9]+/)) {
        tok = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
        printf "OFF\t%s:%d\t(b) self-citation\t%s\t%s\n", rel, NR, tok, ex(line)
      }
      s = c
      while (match(s, /(^|[^A-Za-z0-9_.\/-])[A-Za-z_][A-Za-z0-9_-]*:[0-9][0-9][0-9][0-9]?[0-9]?([^0-9:]|$)/)) {
        tok = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
        sub(/^[^A-Za-z_]/, "", tok); sub(/[^0-9]$/, "", tok)
        printf "OFF\t%s:%d\t(c) named-site self-citation\t%s\t%s\n", rel, NR, tok, ex(line)
      }
    }' < "$3"
}

# scan <root>: print the offences and the CONTROL; set SCAN_OFF and SCAN_UP. Returns 0 clean, 1 offence, 2 harness.
SCAN_OFF=0; SCAN_UP=0
scan() {
  local root="$1" f out exc_used=0 exc_lines rec kind where rule tok text
  SCAN_OFF=0; SCAN_UP=0
  for f in $INPUTS; do
    [ -s "$root/$f" ] || { echo "harness: missing or empty input: $root/$f" >&2; return 2; }
    out=$(scan_awk "$BASES" "$f" "$root/$f") || { echo "harness: awk failed on $root/$f" >&2; return 2; }
    [ -n "$out" ] || continue
    while IFS= read -r rec; do
      IFS=$'\t' read -r kind where rule tok text <<< "$rec"
      if [ "$kind" = UP ]; then SCAN_UP=$((SCAN_UP+1)); continue; fi
      # The exception covers ONE offence: rule (b), token ~:4096, on the line that holds EXC_TEXT. Any other
      # citation on that line, or a second ~:4096 there, is an offence like any other.
      if [ "$f" = "$EXC_FILE" ] && [ "$rule" = "$EXC_RULE" ] && [ "$tok" = "$EXC_TOK" ] && [ "$exc_used" -eq 0 ]; then
        case "$(sed -n "${where##*:}p" "$root/$f")" in
          *"$EXC_TEXT"*) exc_used=1; echo "  EXCEPTION ($EXC_TASK): $where $tok"; continue ;;
        esac
      fi
      SCAN_OFF=$((SCAN_OFF+1))
      echo "  FAIL  $where: $rule $tok | $text"
    done <<< "$out"
  done
  exc_lines=$(grep -cF -- "$EXC_TEXT" "$root/$EXC_FILE")
  if [ "$exc_lines" -eq 0 ] || [ "$exc_used" -eq 0 ]; then
    SCAN_OFF=$((SCAN_OFF+1))
    echo "  FAIL  stale exception: $EXC_FILE no longer cites \"$EXC_TOK\" in \"$EXC_TEXT\" -- delete EXC_* ($EXC_TASK) from this suite"
  elif [ "$exc_lines" -ne 1 ]; then
    SCAN_OFF=$((SCAN_OFF+1))
    echo "  FAIL  the exception text is on $exc_lines lines of $EXC_FILE; it covers one ($EXC_TASK)"
  fi
  echo "  CONTROL: $SCAN_UP upstream citation(s) allowed"
  [ "$SCAN_UP" -gt 0 ] || { echo "harness: CONTROL is 0 -- the scan read nothing" >&2; return 2; }
  [ "$SCAN_OFF" -eq 0 ] || return 1
  return 0
}

echo "== line citations in the device scripts and rc files ($ROOT)"
scan "$ROOT"; rc=$?
[ "$rc" -eq 2 ] && exit 2
if [ "$rc" -ne 0 ]; then
  echo "FAIL: $SCAN_OFF line citation(s). Cite the function, constant, note or log text, not the line."
  exit 1
fi
echo "PASS: no line citation into a tracked file or into a script itself"
[ "$MUTATE" = yes ] || exit 0

echo "== --mutate"
BASE_UP=$SCAN_UP
MFAIL=0
# fresh_copy: a new copy of the scanned files under $W; prints its root.
fresh_copy() {
  local d f
  d=$(mktemp -d -p "$W") || return 1
  for f in $INPUTS; do
    mkdir -p "$d/${f%/*}" && cp "$ROOT/$f" "$d/$f" || return 1
  done
  printf '%s\n' "$d"
}
# plant <label> <want: convict|alone> <rel> <line to append | "--sed=<sed script>">
plant() {
  local label="$1" want="$2" rel="$3" text="$4" d rc out
  d=$(fresh_copy) || { echo "  mutate: NOT APPLIED (copy failed) -- $label"; MFAIL=$((MFAIL+1)); return; }
  case "$text" in
  --sed=*)
    sed -i -e "${text#--sed=}" "$d/$rel"
    if cmp -s "$ROOT/$rel" "$d/$rel"; then
      echo "  mutate: NOT APPLIED -- $label"; MFAIL=$((MFAIL+1)); rm -rf "$d"; return
    fi ;;
  *)
    printf '%s\n' "$text" >> "$d/$rel"
    case "$(tail -n 1 "$d/$rel")" in
      "$text") ;;
      *) echo "  mutate: NOT APPLIED -- $label"; MFAIL=$((MFAIL+1)); rm -rf "$d"; return ;;
    esac ;;
  esac
  out=$(scan "$d" 2>&1); rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 2 ]; then
    echo "  mutate: HARNESS FAILURE -- $label"; printf '%s\n' "$out" | sed 's/^/      /'; MFAIL=$((MFAIL+1)); return
  fi
  case "$want" in
    convict)
      if [ "$rc" -eq 1 ]; then echo "  mutate: convicted -- $label"
      else echo "  mutate: NOT CONVICTED -- $label"; MFAIL=$((MFAIL+1)); fi ;;
    alone)
      if [ "$rc" -ne 0 ]; then
        echo "  mutate: WRONGLY CONVICTED -- $label"; printf '%s\n' "$out" | sed 's/^/      /'; MFAIL=$((MFAIL+1))
      else echo "  mutate: left alone -- $label"; fi ;;
  esac
}
# plant_up <label> <rel> <line>: must be left alone AND raise the CONTROL by one.
plant_up() {
  local label="$1" rel="$2" text="$3" d rc
  d=$(fresh_copy) || { echo "  mutate: NOT APPLIED (copy failed) -- $label"; MFAIL=$((MFAIL+1)); return; }
  printf '%s\n' "$text" >> "$d/$rel"
  scan "$d" > /dev/null 2>&1; rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ] && [ "$SCAN_UP" -eq $((BASE_UP+1)) ]; then
    echo "  mutate: left alone, counted (CONTROL $BASE_UP -> $SCAN_UP) -- $label"
  else
    echo "  mutate: WRONG (rc $rc, CONTROL $SCAN_UP, want 0 and $((BASE_UP+1))) -- $label"; MFAIL=$((MFAIL+1))
  fi
}

# plant_harness <label> <shell commands run in the copy's root>: input discovery plus the scan must exit 2.
plant_harness() {
  local label="$1" cmds="$2" d rc
  d=$(fresh_copy) || { echo "  mutate: NOT APPLIED (copy failed) -- $label"; MFAIL=$((MFAIL+1)); return; }
  if ! (cd "$d" && eval "$cmds"); then
    echo "  mutate: NOT APPLIED -- $label"; MFAIL=$((MFAIL+1)); rm -rf "$d"; return
  fi
  ( collect_inputs "$d" && scan "$d" ) > /dev/null 2>&1; rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 2 ]; then echo "  mutate: refused as a harness failure (exit 2) -- $label"
  else echo "  mutate: NOT REFUSED (rc $rc, want 2) -- $label"; MFAIL=$((MFAIL+1)); fi
}

RD=core/vendor-common/bin/nowhere_roamd.sh
RC=core/vendor-common/etc/nowhere.rc
plant 'M1 main.go:123 in a roamd comment'                   convict "$RD" '# plant: see main.go:123 for the carry'
plant 'M2 (:1234) in a roamd comment'                       convict "$RD" '# plant: the note above (:1234) says so'
plant 'M3 lines 290/688 in a roamd comment'                 convict "$RD" '# plant: same as the ops at lines 290/688'
plant 'M4 ChooserActivity.java:10-20 in a roamd comment'    convict "$RD" '# plant: it SKIPS it (ChooserActivity.java:10-20)'
plant 'M5 docs/backlog-ui.py:5 in nowhere.rc'               convict "$RC" '# plant: see docs/backlog-ui.py:5'
plant 'M6 ~:4242 in a roamd comment'                        convict "$RD" '# plant: set at ~:4242 above'
plant 'M7 cleanstorage:1060 in a roamd comment'             convict "$RD" '# plant: both callers (cleanstorage:1060)'
plant 'M8 (:1234) in a trailing roamd comment'              convict "$RD" 'x=1  # plant: a trailing comment (:1234)'
plant 'M9 (:1234) in a trailing roamd comment after a tab'  convict "$RD" $'x=1\t# plant: a trailing comment (:1234)'
plant_up 'C1 aosp/update_engine_client_android.cc:197'      "$RD" '# plant: (aosp/update_engine_client_android.cc:197)'
plant 'C2 a clock time and a uid:gid pair'                  alone   "$RD" '# plant: fired at 12:02:21, owner 1010232:1010232'
plant 'C3 the exception text gone (a stale exception)'      convict "$RD" \
  '--sed=s/~:4096 BEFORE the NWP-20260913-03 ownership probe/the odsrc=1 line, BEFORE the ownership probe/'
plant 'E1 main.go:123 added to the exception line'            convict "$RD" \
  '--sed=/~:4096 BEFORE the NWP-20260913-03 ownership probe/s/$/; see main.go:123/'
plant 'E2 (:4100) added to the exception line'                convict "$RD" \
  '--sed=/~:4096 BEFORE the NWP-20260913-03 ownership probe/s/$/ (:4100)/'
plant 'E3 a second ~:4096 on the exception line'              convict "$RD" \
  '--sed=/~:4096 BEFORE the NWP-20260913-03 ownership probe/s/$/ (and ~:4096 again)/'
plant 'E4 the exception text copied to a second line'        convict "$RD" \
  '# plant: is set at ~:4096 BEFORE the NWP-20260913-03 ownership probe'
plant_harness 'H1 nowhere.rc deleted, another rc present' \
  "rm -f $RC && printf '%s\\n' 'on boot' > core/vendor-common/etc/plant-extra.rc"
plant_harness 'H2 nowhere.rc emptied, another rc present' \
  ": > $RC && printf '%s\\n' 'on boot' > core/vendor-common/etc/plant-extra.rc"
plant_harness 'H3 an empty untracked rc beside nowhere.rc' \
  ": > core/vendor-common/etc/plant-extra.rc"
plant_harness 'H4 nowhere_otad.sh deleted' \
  "rm -f core/vendor-common/bin/nowhere_otad.sh"

if [ "$MFAIL" -ne 0 ]; then echo "FAIL: $MFAIL mutant(s) not handled as required"; exit 1; fi
echo "PASS: every mutant handled as required"
exit 0
