#!/bin/bash
# Secondary-user launch smoke test for the bundled default apps.
#
# The nowhere OS runs every app in a ROAMED SECONDARY USER (its data roams and wipes on power-off), and
# some apps misbehave outside user 0 -- e.g. Fennec 152 crashed on a secondary user, and anything that
# needs a primary-user-only service (NFC, some DataStore/CameraX paths) can fail. Newly-bundled apps
# (Thunderbird among them) MUST be checked in a secondary user, not just user 0.
#
# This install-existing's each bundled app into a secondary user and launches it, failing if the process
# dies or logs a crash/ANR. Run it against a REAL roamed login (log into a profile first, then run this),
# or let it create a throwaway secondary user.
#
# Usage: test-default-apps-secondary-user.sh [-s SERIAL] [--user N] [--edition ED] [--list] [PKG ...]
#   -s SERIAL   adb device serial (else $ANDROID_SERIAL / the only device)
#   --user N    target secondary user id (else the current foreground user when >0, else a throwaway)
#   --edition ED  diaspore|endospore: test only the manifest rows whose module (first column) is in a
#               PRODUCT_PACKAGES += block of editions/ED/ED.mk -- the apps that edition actually bakes
#               (Endospore has no Fennec, so the unfiltered default fails there by design)
#   --list      print the resolved package list, one per line, and exit 0 without touching adb
#   PKG ...     packages to test (else the --edition set, else every package in default-apps.manifest)
#
# Needs a userdebug/eng build: adb shell must be able to run pm/am user commands. On a provisioned user
# build the device owner blocks adb user management, so run this on a dev image. Exit 0 = all launched clean.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="$HERE/default-apps.manifest"

ADB=(adb)
USER_ARG=""
PKGS=()
EDITION=""
LIST=0
while [ $# -gt 0 ]; do
  case "$1" in
    -s) ADB=(adb -s "$2"); shift 2 ;;
    --user) USER_ARG="$2"; shift 2 ;;
    --edition) EDITION="${2:-}"; shift 2 ;;
    --list) LIST=1; shift ;;
    *) PKGS+=("$1"); shift ;;
  esac
done
ash() { "${ADB[@]}" shell "$@"; }

# Default package set = the manifest's Package column, narrowed to the edition's modules under --edition.
if [ ${#PKGS[@]} -eq 0 ]; then
  [ -f "$MANIFEST" ] || { echo "no manifest at $MANIFEST and no packages given" >&2; exit 2; }
  MODS=""
  if [ -n "$EDITION" ]; then
    case "$EDITION" in diaspore|endospore) ;; *) echo "unknown edition '$EDITION' (diaspore|endospore)" >&2; exit 2 ;; esac
    MK="$HERE/../../../editions/$EDITION/$EDITION.mk"
    [ -f "$MK" ] || { echo "no $MK" >&2; exit 2; }
    # Every `PRODUCT_PACKAGES += a \ b ...` block (backslash continuations), comments stripped.
    MODS="$(sed -e 's/#.*//' "$MK" | awk '
      /^[[:space:]]*PRODUCT_PACKAGES[[:space:]]*\+=/ { on = 1; sub(/^[^=]*=/, "") }
      on { c = ($0 ~ /\\[[:space:]]*$/); sub(/\\[[:space:]]*$/, ""); for (i = 1; i <= NF; i++) print $i; if (!c) on = 0 }')"
  fi
  while read -r name pkg _rest; do
    case "${name:-}" in ""|\#*) continue ;; esac
    if [ -n "$EDITION" ] && ! grep -qxF "$name" <<<"$MODS"; then continue; fi
    PKGS+=("$pkg")
  done < "$MANIFEST"
fi
if [ "$LIST" = 1 ]; then
  printf '%s\n' "${PKGS[@]}"
  exit 0
fi

# Resolve the target secondary user.
CREATED=""
if [ -n "$USER_ARG" ]; then
  U="$USER_ARG"
else
  U="$(ash am get-current-user 2>/dev/null | tr -dc 0-9)"
  if [ -z "$U" ] || [ "$U" = "0" ]; then
    echo "no roamed session (current user is 0/unknown) -- creating a throwaway secondary user"
    OUT="$(ash pm create-user nw_apptest 2>&1)"
    # Only accept the "Success: created user id N" line -- an error like "(code 10)" must NOT be parsed as
    # a user id. On a provisioned device the owner blocks adb user-add (no_add_user), so guide the operator.
    U="$(echo "$OUT" | grep -oiE 'created user id [0-9]+' | grep -oE '[0-9]+' | tail -1)"
    if [ -z "$U" ]; then
      echo "could not create a secondary user: $OUT" >&2
      echo "A provisioned device blocks adb user-add (device owner sets no_add_user). Log into a profile at" >&2
      echo "the gate first, then re-run this against that roamed session -- or pass --user N explicitly." >&2
      exit 3
    fi
    CREATED="$U"
    ash am start-user "$U" >/dev/null 2>&1
    sleep 2
  fi
fi
echo "target secondary user: $U"

fail=0
ash logcat -c >/dev/null 2>&1
for pkg in "${PKGS[@]}"; do
  ash pm install-existing --user "$U" "$pkg" >/dev/null 2>&1
  comp="$(ash cmd package resolve-activity --brief --user "$U" \
            -a android.intent.action.MAIN -c android.intent.category.LAUNCHER "$pkg" 2>/dev/null \
          | tr -d '\r' | grep '/' | tail -1)"
  if [ -z "$comp" ]; then
    echo "FAIL $pkg : no launcher activity in user $U (not installed / no LAUNCHER intent)"
    fail=1; continue
  fi
  # The launcher's own intent, not a bare component: Android 14+ blocks an explicit intent that does not match the
  # component's filters when the app targets SDK 34+ ("Access blocked"; Thunderbird 24.0 targets 36, NWP-20261029-26).
  ash am start --user "$U" -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -n "$comp" >/dev/null 2>&1
  sleep 4
  pid="$(ash pidof "$pkg" 2>/dev/null | tr -dc 0-9)"
  crash="$( { ash logcat -d -b crash 2>/dev/null | grep -F "$pkg";
              ash logcat -d 2>/dev/null | grep -E "FATAL EXCEPTION|ANR in $pkg"; } | grep -F "$pkg" | head -1)"
  if [ -z "$pid" ] || [ -n "$crash" ]; then
    printf 'FAIL %s :' "$pkg"
    [ -z "$pid" ] && printf ' process not alive after launch;'
    [ -n "$crash" ] && printf ' crash: %s' "$crash"
    printf '\n'
    fail=1
  else
    echo "ok   $pkg (pid $pid, no crash) via $comp"
  fi
  ash am force-stop --user "$U" "$pkg" >/dev/null 2>&1
done

if [ -n "$CREATED" ]; then
  echo "removing throwaway user $CREATED"
  ash pm remove-user "$CREATED" >/dev/null 2>&1
fi
[ "$fail" = 0 ] && echo "PASS: all bundled apps launched clean in user $U" || echo "FAIL: some apps failed in user $U"
exit $fail
