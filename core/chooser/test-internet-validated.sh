#!/usr/bin/env bash
# test-internet-validated.sh [--mutate] -- the gate's online test requires a VALIDATED network (NWP-20261013-32), and
# so do the session watcher's two "Back online" deciders (NWP-20261210-27).
#
# WHY COMMITTED. hasInternet() tests only NET_CAPABILITY_INTERNET, which a captive portal carries. When
# hasInternetWithGrace's fast path used it, a portal network read as online, the sign-in failed, and the user was told
# to check their passphrase -- the worst message on a blind-login product (docs/wifi-retention-spec.md CP1). The fast
# path and the final fallback must go through hasValidatedInternet(), whose body must require
# NET_CAPABILITY_VALIDATED. Nothing fails to build or logs when this regresses, so the source is pinned.
#
# The session watcher (startSyncStatusWatcher, the 5-second tick) had the same fault (backlog row 'A network that is
# connected but has no internet makes a session say "Back online"'). Its GET-OFFLINE arm posted the reconnect notice,
# and its drop arm cleared the drop and let BackNowCycle offer "Back up now", on hasInternetCtx, which tests INTERNET
# only. A captive portal or a hotspot with no upstream carries INTERNET, so the user was told saves can resume when
# they cannot. Both arms must go through hasValidatedInternetCtx, the static twin of hasValidatedInternet, which
# requires INTERNET and VALIDATED and fails closed (false) like hasInternetCtx. hasInternetCtx itself stays INTERNET
# only: its other callers (the prefetch tick, pinned by test-auto-sweep-net-java.sh, and others) keep their meaning.
# W5 is scoped to the two arms, not the whole watcher body, because the prefetch tick's hasInternetCtx call is in it.
#
#   bash test-internet-validated.sh            # the invariants
#   bash test-internet-validated.sh --mutate   # ... plus mutants that must each be CONVICTED
set -uo pipefail
MUTATE=no; for a in "$@"; do [ "$a" = --mutate ] && MUTATE=yes; done
D="$(dirname "$0")"
ACT="$D/src/com/nowhere/chooser/ChooserActivity.java"
[ -f "$ACT" ] || { echo "no such file: $ACT" >&2; exit 2; }
T=$(mktemp -d) || exit 2; trap 'rm -rf "$T"' EXIT

# method NAME FILE -- the text from the declaration line to its closing 4-space brace (anchor, not line numbers)
method() { awk -v n="$1" '
    !f && $0 ~ "^    private boolean " n "\\(" { f=1 }
    f { print }
    f && /^    }$/ { exit }' "$2"; }

# static_method NAME FILE -- the same, for a package-private `static boolean NAME(`
static_method() { awk -v n="$1" '
    !f && $0 ~ "^    static boolean " n "\\(" { f=1 }
    f { print }
    f && /^    }$/ { exit }' "$2"; }

# watcher FILE -- startSyncStatusWatcher's body, to its closing 4-space brace
watcher() { awk '
    !f && /^    private void startSyncStatusWatcher\(\)/ { f=1 }
    f { print }
    f && /^    }$/ { exit }' "$1"; }

# nocomment -- strip // comments and whole /* */ or javadoc comment lines, so a comment never satisfies a check
nocomment() { sed -e 's#[[:space:]]*//.*$##' -e '/^[[:space:]]*\/\*/d' -e '/^[[:space:]]*\*/d'; }

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
    check_watcher "$f" || fails=1
    return $fails
}

# check_watcher FILE -> W1-W6, prints FAIL lines, exit 1 on any
check_watcher() {
    local f="$1" vctx ictx body arms next fails=0
    vctx=$(static_method hasValidatedInternetCtx "$f" | nocomment)
    ictx=$(static_method hasInternetCtx "$f" | nocomment)
    body=$(watcher "$f" | nocomment)
    if [ -z "$vctx" ]; then
        echo "FAIL W1 hasValidatedInternetCtx not found"; fails=1
    elif ! grep -q 'NET_CAPABILITY_INTERNET' <<<"$vctx" || ! grep -q 'NET_CAPABILITY_VALIDATED' <<<"$vctx"; then
        echo "FAIL W1 hasValidatedInternetCtx does not require both NET_CAPABILITY_INTERNET and NET_CAPABILITY_VALIDATED"
        fails=1
    fi
    if [ -n "$vctx" ]; then
        if ! grep -q 'if (cm == null) return false;' <<<"$vctx" \
           || [ "$(awk '/catch \(Throwable t\) \{/ { c=1; next } c && /return / { print; exit }' <<<"$vctx" \
                   | tr -d '[:space:]')" != "returnfalse;" ]; then
            echo "FAIL W2 hasValidatedInternetCtx does not fail closed (null cm or its catch must return false)"; fails=1
        fi
    else
        echo "FAIL W2 hasValidatedInternetCtx not found"; fails=1
    fi
    if [ -z "$body" ]; then echo "FAIL startSyncStatusWatcher not found"; return 1; fi
    next=$(awk '/if \(off\.startsWith\("1"\)\) \{/ { f=1; next } f && NF { print; exit }' <<<"$body")
    case "$next" in
        *"if (hasValidatedInternetCtx(app)) {"*) ;;
        *) echo "FAIL W3 the GET-OFFLINE arm does not decide on hasValidatedInternetCtx(app): $next"; fails=1 ;;
    esac
    if ! grep -qF 'boolean online = hasValidatedInternetCtx(app);' <<<"$body"; then
        echo "FAIL W4 the drop arm does not decide online on hasValidatedInternetCtx(app)"; fails=1
    fi
    arms=$(awk '/String off = pollDaemon\("GET-OFFLINE\\n"\)/ { f=1 } f { print } f && /boolean stored =/ { exit }' <<<"$body")
    if [ -z "$arms" ]; then
        echo "FAIL W5 the GET-OFFLINE arm and the drop arm not found"; fails=1
    elif grep -q 'hasInternetCtx(' <<<"$arms"; then
        echo "FAIL W5 a Back online decider still calls hasInternetCtx"; fails=1
    fi
    if [ -z "$ictx" ]; then
        echo "FAIL W6 hasInternetCtx not found"; fails=1
    elif ! grep -q 'NET_CAPABILITY_INTERNET' <<<"$ictx" || grep -q 'NET_CAPABILITY_VALIDATED' <<<"$ictx"; then
        echo "FAIL W6 hasInternetCtx is no longer INTERNET only"; fails=1
    fi
    return $fails
}

out=$(check "$ACT"); rc=$?
if [ $rc -eq 0 ]; then echo "  ok    hasInternetWithGrace requires a VALIDATED network (fast path, final return)"
else printf '%s\n' "$out"; echo "FAILED"; exit 1; fi
echo "  ok    the session watcher's Back online deciders require a VALIDATED network (W1-W6)"

[ "$MUTATE" = yes ] || { echo "PASSED"; exit 0; }

bad=0
mutant() { # name, python-free sed expression, [the assertion ids that must convict it]
    local name="$1" expr="$2" m w o rc
    shift 2
    m=$(mktemp -p "$T" m.XXXXXX.java)
    cp "$ACT" "$m"; sed -i "$expr" "$m"
    if cmp -s "$ACT" "$m"; then echo "  FAIL  mutant did not apply (INERT): $name"; bad=1; return; fi
    o=$(check "$m"); rc=$?
    if [ $rc -eq 0 ]; then echo "  FAIL  survived: $name"; bad=1; return; fi
    for w in "$@"; do
        case "$o" in
            *"FAIL $w "*) ;;
            *) echo "  FAIL  $name was not convicted by $w: $o"; bad=1; return ;;
        esac
    done
    echo "  ok    convicted${1:+ by $*}: $name"
}
mutant "fast path back to hasInternet()" 's/if (hasValidatedInternet()) return true;/if (hasInternet()) return true;/'
mutant "final return back to hasInternet()" 's/return validated || hasValidatedInternet();/return validated || hasInternet();/'
# drop VALIDATED from the helper only (the slow-path callback keeps its own use)
mutant "VALIDATED dropped from the helper" '/private boolean hasValidatedInternet/,/^    }$/{s/NET_CAPABILITY_VALIDATED/NET_CAPABILITY_NOT_METERED/}'
# NWP-20261210-27: the session watcher's Back online deciders
mutant "V1 GET-OFFLINE arm back to hasInternetCtx" '/private void startSyncStatusWatcher()/,/^    }$/{s/if (hasValidatedInternetCtx(app)) {/if (hasInternetCtx(app)) {/}' W3 W5
mutant "V2 drop arm back to hasInternetCtx" 's/boolean online = hasValidatedInternetCtx(app);/boolean online = hasInternetCtx(app);/' W4 W5
mutant "V3 VALIDATED dropped from hasValidatedInternetCtx" '/^    static boolean hasValidatedInternetCtx(/,/^    }$/{s/NET_CAPABILITY_VALIDATED/NET_CAPABILITY_NOT_METERED/}' W1
mutant "V4 hasValidatedInternetCtx null-cm returns true" '/^    static boolean hasValidatedInternetCtx(/,/^    }$/{s/if (cm == null) return false;/if (cm == null) return true;/}' W2
mutant "V5 hasInternetCtx requires VALIDATED" '/^    static boolean hasInternetCtx(/,/^    }$/{s/nc.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET);/nc.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET) \&\& nc.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_VALIDATED);/}' W6
[ $bad -eq 0 ] && echo "PASSED (mutants)" || { echo "FAILED (mutants)"; exit 1; }
