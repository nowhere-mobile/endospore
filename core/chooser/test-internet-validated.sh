#!/usr/bin/env bash
# test-internet-validated.sh [--mutate] -- the gate's online test requires a VALIDATED network (NWP-20261013-32).
#
# WHY COMMITTED. hasInternet() tests only NET_CAPABILITY_INTERNET, which a captive portal carries. When
# hasInternetWithGrace's fast path used it, a portal network read as online, the sign-in failed, and the user was told
# to check their passphrase -- the worst message on a blind-login product (docs/wifi-retention-spec.md CP1). The fast
# path and the final fallback must go through hasValidatedInternet(), whose body must require
# NET_CAPABILITY_VALIDATED. Nothing fails to build or logs when this regresses, so the source is pinned.
#
#   bash test-internet-validated.sh            # the invariants
#   bash test-internet-validated.sh --mutate   # ... plus mutants that must each be CONVICTED
set -uo pipefail
MUTATE=no; for a in "$@"; do [ "$a" = --mutate ] && MUTATE=yes; done
D="$(dirname "$0")"
ACT="$D/src/com/nowhere/chooser/ChooserActivity.java"
[ -f "$ACT" ] || { echo "no such file: $ACT" >&2; exit 2; }

# method NAME FILE -- the text from the declaration line to its closing 4-space brace (anchor, not line numbers)
method() { awk -v n="$1" '
    !f && $0 ~ "^    private boolean " n "\\(" { f=1 }
    f { print }
    f && /^    }$/ { exit }' "$2"; }

# check FILE -> prints FAIL lines, exit 1 on any
check() {
    local f="$1" grace helper fails=0 first last
    grace=$(method hasInternetWithGrace "$f")
    helper=$(method hasValidatedInternet "$f")
    if [ -z "$grace" ]; then echo "FAIL hasInternetWithGrace not found"; return 1; fi
    if [ -z "$helper" ]; then echo "FAIL hasValidatedInternet not found"; return 1; fi
    first=$(printf '%s\n' "$grace" | sed -n '2p')
    case "$first" in
        *"if (hasValidatedInternet()) return true;"*) ;;
        *) echo "FAIL first statement of hasInternetWithGrace is not the hasValidatedInternet() fast path: $first"; fails=1 ;;
    esac
    last=$(printf '%s\n' "$grace" | grep -E '^\s+return ' | tail -1)
    case "$last" in
        *"return validated || hasValidatedInternet();"*) ;;
        *) echo "FAIL final return of hasInternetWithGrace does not use hasValidatedInternet(): $last"; fails=1 ;;
    esac
    if ! grep -q 'NET_CAPABILITY_VALIDATED' <<<"$helper"; then
        echo "FAIL hasValidatedInternet does not require NET_CAPABILITY_VALIDATED"; fails=1
    fi
    if ! grep -q 'NET_CAPABILITY_INTERNET' <<<"$helper"; then
        echo "FAIL hasValidatedInternet does not require NET_CAPABILITY_INTERNET"; fails=1
    fi
    if ! grep -q 'if (cm == null) return true;' <<<"$helper" \
       || ! grep -q 'catch (Throwable t) {' <<<"$helper" ; then
        echo "FAIL hasValidatedInternet lost its fail-open"; fails=1
    fi
    return $fails
}

out=$(check "$ACT"); rc=$?
if [ $rc -eq 0 ]; then echo "  ok    hasInternetWithGrace requires a VALIDATED network (fast path, final return)"
else printf '%s\n' "$out"; echo "FAILED"; exit 1; fi

[ "$MUTATE" = yes ] || { echo "PASSED"; exit 0; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
bad=0
mutant() { # name, python-free sed expression
    local name="$1" expr="$2" m="$T/m.java"
    cp "$ACT" "$m"; sed -i "$expr" "$m"
    if cmp -s "$ACT" "$m"; then echo "  FAIL  mutant did not apply: $name"; bad=1; return; fi
    local o; o=$(check "$m")
    if [ $? -ne 0 ]; then echo "  ok    convicted: $name"; else echo "  FAIL  survived: $name"; bad=1; fi
}
mutant "fast path back to hasInternet()" 's/if (hasValidatedInternet()) return true;/if (hasInternet()) return true;/'
mutant "final return back to hasInternet()" 's/return validated || hasValidatedInternet();/return validated || hasInternet();/'
# drop VALIDATED from the helper only (the slow-path callback keeps its own use)
mutant "VALIDATED dropped from the helper" '/private boolean hasValidatedInternet/,/^    }$/{s/NET_CAPABILITY_VALIDATED/NET_CAPABILITY_NOT_METERED/}'
[ $bad -eq 0 ] && echo "PASSED (mutants)" || { echo "FAILED (mutants)"; exit 1; }
