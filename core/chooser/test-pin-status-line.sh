#!/usr/bin/env bash
# test-pin-status-line.sh [--mutate] -- the PIN screen states whether a PIN is set, and Remove PIN confirms (NWP-20261014-36).
#
# WHY COMMITTED. The screen only relabelled its button, so a user who suspected the PIN was gone could not check; and
# "Remove PIN" destroys a roamed credential. Neither regresses loudly (no build break, no log line), so the source
# of the PIN screen is pinned: the PIN-STATUS callback writes "A PIN is set for this profile." for SET and
# "No PIN is set." for NONE, only while the status line is empty and in MUTED, and the Remove click opens an
# AlertDialog titled "Remove PIN?" with "Keep it" / "Remove" before any SET-PIN is sent.
#
#   bash test-pin-status-line.sh            # the invariants
#   bash test-pin-status-line.sh --mutate   # ... plus mutants that must each be CONVICTED
set -uo pipefail
MUTATE=no; for a in "$@"; do [ "$a" = --mutate ] && MUTATE=yes; done
D="$(dirname "$0")"
ACT="$D/src/com/nowhere/chooser/ProfileActivity.java"
[ -f "$ACT" ] || { echo "no such file: $ACT" >&2; exit 2; }

# the PIN screen's Remove link through its PIN-STATUS thread (anchors, not line numbers)
region() { awk '/remove.setOnClickListener/ { f=1 } f { print } f && /"nowhere-pin-status"\)\.start\(\);/ { exit }' "$1"; }

check() {
    local r fails=0 dlg cb
    r=$(region "$1")
    if [ -z "$r" ]; then echo "FAIL PIN screen Remove/PIN-STATUS region not found"; return 1; fi
    dlg=${r%%\"nowhere-clear-pin\"*}
    case "$dlg" in *"new android.app.AlertDialog.Builder(this)"*) ;; *) echo "FAIL Remove PIN opens no AlertDialog"; fails=1 ;; esac
    case "$dlg" in *'.setTitle("Remove PIN?")'*) ;; *) echo "FAIL dialog title is not \"Remove PIN?\""; fails=1 ;; esac
    case "$dlg" in *'.setNegativeButton("Keep it"'*) ;; *) echo "FAIL dialog lost \"Keep it\""; fails=1 ;; esac
    case "$dlg" in *'.setPositiveButton("Remove"'*) ;; *) echo "FAIL dialog lost \"Remove\""; fails=1 ;; esac
    case "${dlg%%.setPositiveButton*}" in *'SET-PIN'*) echo "FAIL SET-PIN sent before the confirm"; fails=1 ;; esac
    cb=${r#*\"nowhere-clear-pin\"}
    case "$cb" in *'"A PIN is set for this profile."'*) ;; *) echo "FAIL SET status sentence missing"; fails=1 ;; esac
    case "$cb" in *'"No PIN is set."'*) ;; *) echo "FAIL NONE status sentence missing"; fails=1 ;; esac
    case "$cb" in *'(has || "NONE".equals(ps)) && msg.getText().length() == 0'*) ;;
        *) echo "FAIL status sentence not guarded by an empty status line"; fails=1 ;; esac
    case "$cb" in *'msg.setTextColor(MUTED)'*) ;; *) echo "FAIL status sentence not MUTED"; fails=1 ;; esac
    return $fails
}

out=$(check "$ACT"); rc=$?
if [ $rc -eq 0 ]; then echo "  ok    PIN screen states SET/NONE (empty status only, MUTED) and Remove PIN confirms"
else printf '%s\n' "$out"; echo "FAILED"; exit 1; fi

[ "$MUTATE" = yes ] || { echo "PASSED"; exit 0; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
bad=0
mutant() { # name, sed expression
    local name="$1" expr="$2" m="$T/m.java"
    cp "$ACT" "$m"; sed -i "$expr" "$m"
    if cmp -s "$ACT" "$m"; then echo "  FAIL  mutant did not apply: $name"; bad=1; return; fi
    local o; o=$(check "$m")
    if [ $? -ne 0 ]; then echo "  ok    convicted: $name"; else echo "  FAIL  survived: $name"; bad=1; fi
}
mutant "dialog builder removed" 's/new android.app.AlertDialog.Builder(this)/new android.app.AlertDialog.Builder(this) \/\/ gone/;s/\.setTitle("Remove PIN?")/.setTitle("Remove?")/'
mutant "Keep it button removed" 's/\.setNegativeButton("Keep it", (d, w) -> {})\r\?$/.setNeutralButton("Cancel", (d, w) -> {})/;/Remove PIN?/,/nowhere-clear-pin/s/setNegativeButton("Keep it"/setNeutralButton("Cancel"/'
mutant "SET sentence dropped" 's/"A PIN is set for this profile."/""/'
mutant "NONE sentence dropped" 's/"No PIN is set."/""/'
mutant "empty-status guard dropped" 's/(has || "NONE".equals(ps)) \&\& msg.getText().length() == 0/(has || "NONE".equals(ps))/'
mutant "MUTED dropped" 's/msg.setTextColor(MUTED);/msg.setTextColor(0xFFFFFFFF);/'
[ $bad -eq 0 ] && echo "PASSED (mutants)" || { echo "FAILED (mutants)"; exit 1; }
