#!/usr/bin/env bash
# test-passfield-reveal.sh [--mutate] -- every passField in ProfileActivity has the #81 show/hide eye (NWP-20261113-32).
#
# WHY THIS IS COMMITTED. #81 put a show/hide eye on every passphrase field by wrapping it in PassReveal.wrap, but
# nothing pinned that a NEW field gets one: the Hotspot & tethering passphrase (showHotspot) was added bare, so it had
# no eye. This suite reads ProfileActivity.java as data (the chooser cannot compile off the build host) and, for every
# `final EditText <v> = passField(`, requires in the same method (that line to the method's closing `    }`):
#   - `PassReveal.wrap(<v>,` -- the field reaches the layout through the wrapper;
#   - no `addView(<v>,` -- the bare field is never added beside or instead of it.
# A control refuses a run that finds no passField site at all, so a broken extraction cannot pass.
# Variable names repeat across methods (`confirm` is a passField in showSessionPin and a plain view in showPhoneTie),
# which is why both checks are scoped to the method and never file-wide.
#
#   bash test-passfield-reveal.sh            # the check
#   bash test-passfield-reveal.sh --mutate   # ... plus broken copies that must each FAIL it
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PA="$HERE/src/com/nowhere/chooser/ProfileActivity.java"
SITE_RE='^\s*final EditText (\w+) = passField\('
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
command -v perl >/dev/null 2>&1 || { echo "FAIL: this suite needs perl, and there is none -- refusing to report" >&2; exit 2; }
[ -f "$PA" ] || { echo "FAIL: missing $PA" >&2; exit 2; }

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

# check <ProfileActivity.java> [<site-regex>] -- prints one line per site, exits 1 on any unwrapped or bare site.
check() {
  SITE_RE="${2:-$SITE_RE}" perl -ne '
    BEGIN { $re = $ENV{SITE_RE}; $fails = 0; $n = 0 }
    push @lines, $_;
    END {
      for my $i (0 .. $#lines) {
        next unless $lines[$i] =~ /$re/;
        my $v = $1; my $ln = $i + 1; $n++;
        my ($wrapped, @bare) = (0);
        for my $j ($i .. $#lines) {
          last if $j > $i && $lines[$j] =~ /^    \}$/;
          $wrapped = 1 if index($lines[$j], "PassReveal.wrap($v,") >= 0;
          push @bare, $j + 1 if $lines[$j] =~ /addView\(\Q$v\E,/;
        }
        my $ok = 1;
        unless ($wrapped) { print "FAIL: $v (line $ln) is never wrapped in PassReveal.wrap\n"; $ok = 0 }
        for my $b (@bare) { print "FAIL: $v (line $ln) is added bare: addView($v, ... at line $b\n"; $ok = 0 }
        if ($ok) { print "ok   $v (line $ln)\n" } else { $fails++ }
      }
      print "passField sites: $n\n";
      if ($n == 0) { print "FAIL: found no passField sites -- the extraction is broken\n"; exit 1 }
      exit($fails ? 1 : 0);
    }' "$1"
}

echo "== every passField goes through PassReveal.wrap"
out=$(check "$PA"); rc=$?
printf '%s\n' "$out"
if [ "$rc" -ne 0 ]; then echo "FAILED (rc=$rc)"; exit 1; fi
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED; one that does not apply is a failure)"
judge() { # judge <label> <rc>
  case "$2" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the check did not run (rc=$2)"; return 1 ;;
  esac
}
mut() { # mut <label> <perl-expr> -- a source mutant: exactly one line of a copy changes
  local src rc changed
  src=$(mktemp -p "$W")
  cp "$PA" "$src"
  if ! perl -pi -e "$2" "$src"; then echo "  ERROR     $1 -- perl failed on the mutation"; return 1; fi
  if cmp -s "$PA" "$src"; then echo "  INERT     $1 -- the mutation changed nothing"; return 1; fi
  changed=$(diff "$PA" "$src" | grep -c '^>')
  if [ "$changed" -ne 1 ]; then echo "  ERROR     $1 -- the mutation changed $changed line(s), expected 1"; return 1; fi
  check "$src" >/dev/null 2>&1; rc=$?
  judge "$1" "$rc"
}
fails=0
mut "M1 the hotspot passphrase added bare again" \
  's/ll\.addView\(PassReveal\.wrap\(pwF, MUTED\), flp\);.*$/ll.addView(pwF, flp);/' || fails=$((fails+1))
mut "M2 the PIN confirm added bare" \
  's/ll\.addView\(PassReveal\.wrap\(confirm, MUTED, pinRevGrp\), fieldLp\(dp\(11\)\)\);.*$/ll.addView(confirm, fieldLp(dp(11)));/' \
  || fails=$((fails+1))
broken='^\s*final EditText (\w+) = passFieldX\('
if [ "$broken" = "$SITE_RE" ]; then
  echo "  INERT     M3 the extraction finds no sites -- the broken pattern is the real one"; fails=$((fails+1))
else
  check "$PA" "$broken" >/dev/null 2>&1; rc=$?
  judge "M3 the extraction finds no sites (the control)" "$rc" || fails=$((fails+1))
fi
echo "mutants: 3 tried, $fails failed"
[ "$fails" -eq 0 ] || exit 1
exit 0
