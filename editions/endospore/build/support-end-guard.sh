#!/bin/sh
# support-end-guard.sh <repo> <device> <today YYYY-MM-DD> <dev|release> -- refuse a build of a device past its
# GrapheneOS full support.
#
# We ship no release for a device in GrapheneOS's extended support (#23, 2026-11-02): its releases stop when it leaves
# full support. h55 #2 (docs/product-decisions.md, 2026-11-03) puts that date in the repo, one file per device, and has
# build-device.sh refuse to build the device past it. build-device.sh calls this before anything is read from the ring
# record, written or prompted. The phone's notice reads the same file (one file serves both halves).
#
# The file is <repo>/editions/endospore/devices/<device>/support-end, outside vendor/ on purpose (stage-vendor.sh rsyncs
# vendor/ into a shared etc/, the #627 race). '#' lines and blank lines are comments. Exactly two data lines, in order:
#   last-supported <YYYY-MM or YYYY-MM-DD>   the last month (or day) of full support
#   source <text>                            the public page the date comes from
# Past the date means: for a month, any day of a later month; for a day, any later day.
#
#   0  not past the date (prints one line on stdout); or no file and a dev build (a WARNING on stderr)
#   2  usage: not four arguments, a device not lowercase alphanumerics, a today not a YYYY-MM-DD calendar day, a kind
#      not dev|release
#   3  past the date (every build kind), a malformed or unreadable file (a day that is not on the calendar included,
#      2028-02-31 or 2029-02-29; every build kind), or no file and a release
#
# Writes nothing. POSIX sh: it runs under bash, dash and mksh. No arithmetic on file text: every check is a case pattern.
set -u
usage() { echo "usage: support-end-guard.sh <repo> <device> <today YYYY-MM-DD> <dev|release>" >&2; exit 2; }
# on_calendar <YYYY-MM-DD, already matched by the day patterns>: 0 if that day exists. Day 31 of a 30-day month, day 30 or
# 31 of February, and February 29 of a year that is not a leap year do not. A leap year divides by 4, and a century year
# also by 400: the last two digits pick it, or the first two when the last two are 00.
on_calendar() {
  case "$1" in
    ????-0[469]-31 | ????-11-31 | ????-02-3[01]) return 1 ;;
    ????-02-29)
      case "$1" in
        ??00-*) case "$1" in [02468][048]* | [13579][26]*) return 0 ;; esac; return 1 ;;
        ??[02468][048]-* | ??[13579][26]-*) return 0 ;;
      esac
      return 1 ;;
  esac
  return 0
}
[ "$#" -eq 4 ] || usage
REPO="$1"; DEV="$2"; TODAY="$3"; KIND="$4"
case "$DEV" in '' | *[!a-z0-9]*) usage ;; esac
case "$TODAY" in
  [0-9][0-9][0-9][0-9]-0[1-9]-0[1-9] | [0-9][0-9][0-9][0-9]-0[1-9]-[12][0-9] | [0-9][0-9][0-9][0-9]-0[1-9]-3[01]) ;;
  [0-9][0-9][0-9][0-9]-1[0-2]-0[1-9] | [0-9][0-9][0-9][0-9]-1[0-2]-[12][0-9] | [0-9][0-9][0-9][0-9]-1[0-2]-3[01]) ;;
  *) usage ;;
esac
on_calendar "$TODAY" || usage
case "$KIND" in dev | release) ;; *) usage ;; esac

F="$REPO/editions/endospore/devices/$DEV/support-end"
malformed() {
  echo "refusing: $F is malformed ($1); it needs a 'last-supported <YYYY-MM or YYYY-MM-DD>' line and then a 'source <page>' line" >&2
  exit 3
}
if [ ! -e "$F" ]; then
  if [ "$KIND" = release ]; then
    echo "refusing --release: $DEV has no support-end file ($F); add its date and source first" >&2
    exit 3
  fi
  echo "WARNING: $DEV has no support-end file ($F); a dev build goes on, a --release refuses" >&2
  exit 0
fi
{ [ -f "$F" ] && [ -r "$F" ]; } || malformed "not a readable file"

CR=$(printf '\r')
n=0; bad=""; L=""; SRC=""
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%"$CR"}"
  case "$line" in '' | '#'*) continue ;; esac
  n=$((n + 1))
  case "$line" in *' '*) ;; *) bad="data line '$line' has no value"; break ;; esac
  key="${line%% *}"; val="${line#* }"
  case "$n:$key" in
    1:last-supported)
      case "$val" in
        [0-9][0-9][0-9][0-9]-0[1-9] | [0-9][0-9][0-9][0-9]-1[0-2]) ;;
        [0-9][0-9][0-9][0-9]-0[1-9]-0[1-9] | [0-9][0-9][0-9][0-9]-0[1-9]-[12][0-9] | [0-9][0-9][0-9][0-9]-0[1-9]-3[01]) ;;
        [0-9][0-9][0-9][0-9]-1[0-2]-0[1-9] | [0-9][0-9][0-9][0-9]-1[0-2]-[12][0-9] | [0-9][0-9][0-9][0-9]-1[0-2]-3[01]) ;;
        *) bad="last-supported '$val' is not YYYY-MM or YYYY-MM-DD"; break ;;
      esac
      on_calendar "$val" || { bad="last-supported '$val' is not a day on the calendar"; break; }
      L="$val" ;;
    2:source)
      [ -n "$(printf '%s' "$val" | tr -d ' \t')" ] || { bad="the source is empty"; break; }
      SRC="$val" ;;
    1:* | 2:*) bad="data line $n is '$key', want '$( [ "$n" = 1 ] && echo last-supported || echo source )'"; break ;;
    *) bad="a third data line"; break ;;
  esac
done < "$F"
[ -z "$bad" ] || malformed "$bad"
[ "$n" = 2 ] || malformed "$n data line(s), want 2"

# A month compares against today's month, a day against today. Both sides have one fixed width, so a byte sort is a
# date sort; dash's test has no string '>'.
case "$L" in ????-??) T="${TODAY%-??}" ;; *) T="$TODAY" ;; esac
if [ "$T" != "$L" ] && [ "$(printf '%s\n%s\n' "$L" "$T" | LC_ALL=C sort | tail -n 1)" = "$T" ]; then
  echo "refusing: $DEV left GrapheneOS's full support after $L ($F, source: $SRC); releases stop there (docs/product-decisions.md, h55 #2)" >&2
  exit 3
fi
echo "support: $DEV full support through $L"
