#!/bin/sh
# sitting-guard.sh <wrapper-pid> -- refuse a signing sitting while another process of the signing user runs (NWP-20261122-01).
#
# WHY. During a sitting the decrypted keys sit in /dev/shm/release_keys.* and the passphrase sits in a child's environment.
# Any process of the same uid can read both: an agent ssh session left running as the signing user is enough. Decided
# 2026-11-01 (h52 #4, docs/product-decisions.md, "twenty-two answers to harvests 50, 51 and 52 ..."): sign-release.sh
# refuses to ask for the passphrase while such a process runs, and names each one. Chester ends them, then runs again.
#
# ALLOWED (every other process of this uid is foreign):
#   1. this guard and its ancestors up to pid 1 (sign-release.sh, the operator's shell, tmux's pane, sshd ...);
#   2. <wrapper-pid> and all its descendants;
#   3. this guard's own descendants (its ps calls and command-substitution subshells). In a sitting the guard is a
#      descendant of the wrapper, so 2 already holds them; 3 matters only when the guard runs alone (the suite);
#   4. with $TMUX set: each client of `tmux list-clients` and its ancestors (the operator's attached terminal);
#   5. this uid's user manager: a `systemd` with ppid 1 and its `(sd-pam)` child. That is an INFERENCE from systemd's
#      user@<uid>.service layout, not a fact read from the build host.
# The pid->ppid edges come from BOTH tables. The first ps lists itself (and often the subshell that ran it); both are
# children of this guard and both have exited before the second ps runs, so the -e table alone would name them foreign.
#
#   exit 0  no foreign process (one line on stdout)
#   exit 1  foreign processes: one `pid <n> <comm>` line each on stderr, then what to do
#   exit 2  usage, a process table that cannot be read, or the awk judge failed (a broken judge never decides)
# Writes nothing. POSIX sh: it runs under bash, dash and mksh.
set -u

[ "$#" -eq 1 ] || { echo "usage: sitting-guard.sh <wrapper-pid>" >&2; exit 2; }
WP="$1"
case "$WP" in '' | *[!0-9]* ) echo "sitting-guard: wrapper pid '$WP' is not a number" >&2; exit 2 ;; esac
ME=$$
UID_N=$(id -u) || { echo "sitting-guard: cannot read the uid" >&2; exit 2; }

UT=$(ps -u "$UID_N" -o pid=,ppid=,comm=) || { echo "sitting-guard: ps -u $UID_N failed -- refusing" >&2; exit 2; }
AT=$(ps -e -o pid=,ppid=) || { echo "sitting-guard: ps -e failed -- refusing" >&2; exit 2; }
[ -n "$UT" ] && [ -n "$AT" ] || { echo "sitting-guard: an empty process table -- refusing" >&2; exit 2; }
CL=""
if [ -n "${TMUX:-}" ]; then
  CL=$(tmux list-clients -F '#{client_pid}' 2>/dev/null) || CL=""
fi

# One record per line, tagged: A <pid> <ppid> | U <pid> <ppid> <comm...> | C <client-pid>.
IN=$(
  printf '%s\n' "$AT" | sed 's/^/A /'
  printf '%s\n' "$UT" | sed 's/^/U /'
  [ -z "$CL" ] || printf '%s\n' "$CL" | sed 's/^/C /'
)
OUT=$(printf '%s\n' "$IN" | awk -v me="$ME" -v wp="$WP" '
  $1 == "A" && NF >= 3 { par[$2] = $3; next }
  $1 == "U" && NF >= 3 {
    p = $2; pp = $3
    c = $0; sub(/^U[ \t]+[0-9]+[ \t]+[0-9]+[ \t]*/, "", c)
    n++; up[n] = p; uc[n] = c; uppid[p] = pp; ucomm[p] = c
    next
  }
  $1 == "C" && NF >= 2 { ncl++; cl[ncl] = $2; next }
  END {
    # The edges of the -u rows the -e table lacks (the first ps itself); -e wins on a reused pid.
    for (p in uppid) {
      pp = uppid[p]
      if (!(p in par)) par[p] = pp
    }
    # 1 and 4: ancestor chains.
    walk(me)
    for (i = 1; i <= ncl; i++) walk(cl[i])
    # 2 and 3: descendants of the wrapper and of the guard (a fixed point).
    root[wp] = 1; root[me] = 1
    for (p in root) ok[p] = 1
    do {
      added = 0
      for (p in par) if (!(p in ok) && (par[p] in root)) { root[p] = 1; ok[p] = 1; added = 1 }
    } while (added)
    # 5: the user manager (an inference).
    for (p in uppid) if (ucomm[p] == "systemd" && uppid[p] == 1) um[p] = 1
    for (p in uppid) if (ucomm[p] == "(sd-pam)" && (uppid[p] in um)) ok[p] = 1
    for (p in um) ok[p] = 1
    for (i = 1; i <= n; i++) if (!(up[i] in ok)) print "pid " up[i] " " uc[i]
  }
  function walk(p,   guard) {
    guard = 0
    while (p != "" && p != 0 && guard < 4096) {
      ok[p] = 1
      if (p == 1 || !(p in par)) break
      p = par[p]; guard++
    }
  }
')
RC=$?
if [ "$RC" -ne 0 ]; then
  echo "sitting-guard: the process-table judge failed (awk exit $RC) -- refusing" >&2
  exit 2
fi
if [ -n "$OUT" ]; then
  printf '%s\n' "$OUT" >&2
  echo "end these (an agent session included) and run again" >&2
  exit 1
fi
echo "sitting-guard: no other process of uid $UID_N"
