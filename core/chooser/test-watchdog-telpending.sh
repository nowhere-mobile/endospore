#!/usr/bin/env bash
# test-watchdog-telpending.sh [--mutate] -- the #46 watchdog's reboot logs what it costs (NWP-20261029-20).
#
# ensureReapWatcher's watchdog reboots the device when the gate stays out of Lock Task. A reboot destroys every
# profile's sealed telephony records (RAM), so before it the watcher thread asks the daemon's TEL-PENDING and logs the
# count through RemoveRetry.countWords (docs/product-decisions.md 2026-09-27, answer 4). ChooserActivity.java is read as
# data (no javac): the reboot block is cut out by anchor and checked on comment-stripped text.
#
#   bash test-watchdog-telpending.sh            # the checks
#   bash test-watchdog-telpending.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
CHOOSER="$here/src/com/nowhere/chooser/ChooserActivity.java"
command -v perl >/dev/null 2>&1 || { echo "FAIL: comment stripping needs perl" >&2; exit 2; }

# count_lines <body> <fixed text> -> lines containing it.
count_lines() { printf '%s\n' "$1" | T="$2" awk 'index($0, ENVIRON["T"]) { n++ } END { print n + 0 }'; }
# count_occ <body> <fixed text> -> occurrences (not lines): two calls on one line count twice.
count_occ() { local rest="$1" t="$2" n=0; while [[ "$rest" == *"$t"* ]]; do n=$((n + 1)); rest="${rest#*"$t"}"; done; echo "$n"; }
# offset <body> <fixed text> -> character offset of the first occurrence, empty when none.
offset() { local pre="${1%%"$2"*}"; [[ "$1" == *"$2"* ]] && echo "${#pre}"; }
# first_line <body> <fixed text> -> first line number containing it, empty when none.
first_line() { printf '%s\n' "$1" | T="$2" awk 'index($0, ENVIRON["T"]) { print NR; exit }'; }

# check <ChooserActivity.java> -> 0 all hold, 1 a check failed, 2 an anchor is missing or duplicated.
check() {
  local f="$1" fn nfn stripped blk bad=0
  local n_start n_ask ask stamp reboot n_reboot logline var
  nfn=$(grep -c 'static void ensureReapWatcher(Context ctx) {' "$f")
  [ "$nfn" -eq 1 ] || { echo "  FAIL  anchor: $nfn ensureReapWatcher definitions" >&2; return 2; }
  fn=$(awk '/static void ensureReapWatcher\(Context ctx\) \{/ { on = 1 } on { print } on && /^    }$/ { exit }' "$f")
  stripped=$(printf '%s\n' "$fn" | perl -0pe 's{/\*.*?\*/}{ (my $x = $&) =~ s/[^\n]//g; $x }gse; s{//[^\n]*}{}g')
  n_start=$(count_lines "$stripped" 'if (wdogFail >= 15)')
  [ "$n_start" -eq 1 ] || { echo "  FAIL  anchor: $n_start 'if (wdogFail >= 15)' lines" >&2; return 2; }
  # the block: from the threshold line to the line that closes it (indent-matched).
  blk=$(printf '%s\n' "$stripped" | awk '
    index($0, "if (wdogFail >= 15)") { on = 1; match($0, /^ */); ind = RLENGTH }
    on { print }
    on && NR > 0 { match($0, /^ */); if (RLENGTH == ind && $0 ~ /^ *}/) exit }')
  [ -n "$blk" ] || { echo "  FAIL  anchor: reboot block is empty" >&2; return 2; }

  n_ask=$(count_occ "$blk" 'DaemonSocket.roundTrip("TEL-PENDING\n", 5000)')
  [ "$n_ask" -eq 1 ] || { echo "  FAIL  ask: $n_ask TEL-PENDING roundTrips in the reboot block, want 1" >&2; bad=1; }
  ask=$(offset "$blk" 'DaemonSocket.roundTrip("TEL-PENDING\n", 5000)')
  # the stamp WRITE (fo.write), not the file name: an ask between the stream's construction and the write is before it.
  [ "$(count_occ "$blk" 'fo.write(')" -eq 1 ] || { echo "  FAIL  stamp: want exactly one fo.write( in the block" >&2; bad=1; }
  [ "$(count_occ "$blk" '"wdog_reboot"')" -eq 1 ] || { echo "  FAIL  stamp: want exactly one \"wdog_reboot\" in the block" >&2; bad=1; }
  stamp=$(offset "$blk" 'fo.write(')
  reboot=$(offset "$blk" 'dpm.reboot(admin)')
  n_reboot=$(count_occ "$blk" 'dpm.reboot(admin)')
  [ "$n_reboot" -eq 1 ] || { echo "  FAIL  dpm.reboot(admin) appears $n_reboot times in the block, want 1" >&2; bad=1; }
  if [ -n "$ask" ] && [ -n "$stamp" ] && [ -n "$reboot" ]; then
    [ "$stamp" -lt "$ask" ] && [ "$ask" -lt "$reboot" ] \
      || { echo "  FAIL  order: stamp-write@$stamp ask@$ask reboot@$reboot (offsets), want stamp < ask < reboot" >&2; bad=1; }
  else
    echo "  FAIL  order: stamp/ask/reboot not all found (stamp='$stamp' ask='$ask' reboot='$reboot')" >&2; bad=1
  fi

  logline=$(printf '%s\n' "$blk" | awk '/Log\.e\(/ { on = 1 } on { print } on && /\);[ ]*$/ { exit }')
  case "$logline" in *'watchdog: gate unrecoverable -> REBOOT'*'RemoveRetry.countWords('*) ;;
    *) echo "  FAIL  log: the reboot log line does not carry RemoveRetry.countWords(" >&2; bad=1 ;; esac
  var=$(printf '%s\n' "$blk" | sed -n 's/.*[( ]\([A-Za-z_][A-Za-z0-9_]*\) = DaemonSocket\.roundTrip("TEL-PENDING.*/\1/p' | head -1)
  if [ -z "$var" ]; then
    echo "  FAIL  log: the variable the reply is read into was not found" >&2; bad=1
  else
    # every Log. call: the variable may appear only inside RemoveRetry.countWords( ... ).
    local logs
    logs=$(printf '%s\n' "$blk" | awk '/Log\.[a-z]\(/ { on = 1 } on { print } on && /\);[ ]*$/ { on = 0 }' \
      | sed "s/RemoveRetry\.countWords($var)//g")
    case "$logs" in *"$var"*) echo "  FAIL  log: the raw reply '$var' reaches a Log call" >&2; bad=1 ;; esac
  fi

  case "$blk" in *main.post*|*h.post*|*runOnUiThread*) echo "  FAIL  thread: the reboot block posts to the main looper" >&2; bad=1 ;; esac
  [ "$(count_lines "$blk" '300000L')" -eq 1 ] || { echo "  FAIL  rate limit: 300000L is not in the block exactly once" >&2; bad=1; }
  [ "$(count_lines "$stripped" 'now - wdogLastReboot > 300000L')" -eq 1 ] \
    || { echo "  FAIL  rate limit: 'now - wdogLastReboot > 300000L' changed" >&2; bad=1; }
  [ "$bad" -eq 0 ]
}

# mutant <name> <perl -0pe program> -> the mutant copy must apply and then FAIL the checks.
mutant() {
  local name="$1" prog="$2" copy rc
  copy=$(mktemp -p "$W") || return 1
  perl -0pe "$prog" "$CHOOSER" > "$copy" || { echo "  FAIL  mutant '$name': its perl program does not run" >&2; return 1; }
  if cmp -s "$CHOOSER" "$copy"; then echo "  FAIL  mutant '$name' did not apply" >&2; return 1; fi
  check "$copy" >/dev/null 2>&1; rc=$?
  rm -f "$copy"
  if [ "$rc" -eq 0 ]; then echo "  FAIL  mutant '$name' was not convicted" >&2; return 1; fi
  echo "  ok    mutant '$name' convicted"
}

check "$CHOOSER"; rc=$?
if [ "$rc" -ne 0 ]; then echo "FAIL: the watchdog reboot checks (rc=$rc)" >&2; exit 1; fi
echo "ok: the watchdog's reboot asks TEL-PENDING off the main looper and logs the count"

[ "$MUTATE" = yes ] || exit 0
fail=0
# Every ask mutant anchors on the watchdog's own line (catch (Throwable ig)): perl edits the FIRST match, and an
# earlier TEL-PENDING ask (rebootForCreateOverLive, NWP-20261116-09) would otherwise take the edit.
mutant 'ask removed' 's{[^\n]*roundTrip\("TEL-PENDING\\n", 5000\); \} catch \(Throwable ig\)[^\n]*\n}{}' || fail=1
mutant 'ask after reboot' 's{([^\n]*roundTrip\("TEL-PENDING\\n", 5000\); \} catch \(Throwable ig\)[^\n]*\n)(.*?)([^\n]*dpm\.reboot\(admin\)[^\n]*\n)}{$2$3$1}s' || fail=1
mutant 'ask doubled on its line' 's{(try \{ pr = DaemonSocket\.roundTrip\("TEL-PENDING\\n", 5000\); \} catch \(Throwable ig\) \{ pr = ""; \})}{$1 $1}' || fail=1
mutant 'ask before the stamp write' 's{(String pr;\n\s*try \{ pr = DaemonSocket\.roundTrip[^\n]*catch \(Throwable ig\)[^\n]*\n)}{}; s{(new java\.io\.File\(app\.getFilesDir\(\), "wdog_reboot"\)\)\) \{\n)}{$1 String pr; try { pr = DaemonSocket.roundTrip("TEL-PENDING\\n", 5000); } catch (Throwable ig) { pr = ""; }\n}' || fail=1
mutant 'raw reply logged' 's{"watchdog: gate unrecoverable -> REBOOT; "}{"watchdog: gate unrecoverable -> REBOOT; " + pr + }' || fail=1
mutant 'ask posted to main' 's#try \{ pr = DaemonSocket\.roundTrip(\("TEL-PENDING\\n", 5000\); \} catch \(Throwable ig\))#main.post(() -> {}); try { pr = DaemonSocket.roundTrip$1#' || fail=1
mutant 'rate limit changed' 's{wdogLastReboot > 300000L}{wdogLastReboot > 30000L}' || fail=1
[ "$fail" -eq 0 ] || exit 1
echo "ok: every mutant convicted"
