#!/bin/bash
# Roamed KEEP-SET launch smoke test -- Phase 1 (app-store: automated roam-in reinstall).
#
# After a roam-in, provisionRoamedApps (ChooserActivity) restores the profile's kept USER-installed apps from
# the sealed name#apps scope: a MODE_INSTALLED app gets a real APK back (installApkSet), a MODE_ONDEMAND app
# gets an APK-less archived PLACEHOLDER (its APK is fetched from name#apps only on the tap -> UnarchiveService).
# This verifies, in the LIVE roamed session, that EVERY restored third-party (user-installed) app is either:
#   - installed (has an APK path)      -> LAUNCHES without a crash/ANR, or
#   - a valid archived placeholder     -> resolves as archived (raisable on tap), no APK on disk (amnesia).
# A third-party pkg that is NEITHER (no APK path AND not archived) is a BROKEN restore -> FAIL.
#
# Complements test-default-apps-secondary-user.sh, which covers the BUNDLED image apps via install-existing;
# THIS covers the roam-restore path (installApkSet / installArchivedPlaceholder) that Phase 1 hardens.
#
# Run against a REAL roamed login: sign into a profile that has kept some user apps (Installed and/or On-demand
# in "Your apps"), roam, then run this. It launches each installed app briefly and force-stops it.
#
# Usage: test-roamed-keepset-launch.sh [-s SERIAL] [--user N] [--materialize] [PKG ...]
#   -s SERIAL      adb device serial (else $ANDROID_SERIAL / the only device)
#   --user N       roamed user id (else the current foreground user; must be > 0)
#   --materialize  ALSO trigger unarchive on each on-demand placeholder and assert it materialises an APK
#                  (best-effort: needs a build whose `pm` exposes unarchive; a real tap is the ground truth)
#   PKG ...        limit to these packages (else every third-party app in the roamed user)
#
# Needs a userdebug/eng build (adb can run pm/am). Exit 0 = every restored keep-set app is OK.
set -uo pipefail
ADB=(adb); USER_ARG=""; MAT=0; PKGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -s) ADB=(adb -s "$2"); shift 2 ;;
    --user) USER_ARG="$2"; shift 2 ;;
    --materialize) MAT=1; shift ;;
    *) PKGS+=("$1"); shift ;;
  esac
done
ash() { "${ADB[@]}" shell "$@"; }

# Resolve the roamed user -- Phase-1 restore only happens for a roamed SECONDARY user (never user 0, the gate).
U="${USER_ARG:-$(ash am get-current-user 2>/dev/null | tr -dc 0-9)}"
if [ -z "$U" ] || [ "$U" = "0" ]; then
  echo "no roamed session (current user is 0/unknown). Sign into a profile at the gate first, then re-run" >&2
  echo "(or pass --user N). Phase-1 keep-set restore only happens for a roamed secondary user." >&2
  exit 3
fi
echo "roamed user: $U"

# Default set = every THIRD-PARTY (user-installed) package in the roamed user = the keep-set restore result.
if [ ${#PKGS[@]} -eq 0 ]; then
  while read -r line; do
    p="${line#package:}"; [ -n "$p" ] && PKGS+=("$p")
  done < <(ash pm list packages -3 --user "$U" 2>/dev/null | tr -d '\r')
fi
if [ ${#PKGS[@]} -eq 0 ]; then
  echo "no third-party apps restored in user $U -- nothing to test (did the profile keep any user apps?)"
  exit 0
fi

# ⚠ Every match below reads its input to the end: a here-string (`grep -q PAT <<<"$var"`) or
# `grep -c PAT >/dev/null` on a pipe, never `cmd | grep -q`. Under pipefail grep -q exits at its first match,
# the producer can die of SIGPIPE, and the pipeline fails: an absence check then passes on the code it exists
# to reject, a presence check goes red at random (docs/backlog.md, "pipes into grep -q under pipefail").
fail=0; ninst=0; nod=0
ash logcat -c >/dev/null 2>&1
for pkg in "${PKGS[@]}"; do
  # An archived placeholder has NO APK on disk -> `pm path` is empty; an installed app returns its base.apk.
  has_path="$(ash pm path --user "$U" "$pkg" 2>/dev/null | tr -d '\r' | grep -c '^package:')"
  if [ "$has_path" = "0" ]; then
    if ash dumpsys package "$pkg" 2>/dev/null | grep -ciE "isArchived=true|archiveState|archived=true" >/dev/null; then
      echo "ok   $pkg : on-demand archived placeholder (no APK on disk, raises on tap)"; nod=$((nod+1))
      if [ "$MAT" = 1 ]; then
        echo "     --materialize: unarchiving $pkg ..."
        ash cmd package unarchive --user "$U" "$pkg" >/dev/null 2>&1 || ash pm unarchive --user "$U" "$pkg" >/dev/null 2>&1
        sleep 15
        if [ "$(ash pm path --user "$U" "$pkg" 2>/dev/null | tr -d '\r' | grep -c '^package:')" = "0" ]; then
          echo "FAIL $pkg : unarchive did not materialise an APK"; fail=1
        else
          echo "     materialised OK ($pkg now has an APK path)"
        fi
      fi
    else
      echo "FAIL $pkg : no APK path AND not archived -- broken restore (neither installed nor a valid placeholder)"
      fail=1
    fi
    continue
  fi
  # Installed (real APK) -> must launch clean in the roamed user.
  comp="$(ash cmd package resolve-activity --brief --user "$U" \
            -a android.intent.action.MAIN -c android.intent.category.LAUNCHER "$pkg" 2>/dev/null \
          | tr -d '\r' | grep '/' | tail -1)"
  if [ -z "$comp" ]; then
    echo "skip $pkg : installed but no LAUNCHER activity (service/provider-only, nothing to launch)"; continue
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
    echo "ok   $pkg (pid $pid, no crash) via $comp"; ninst=$((ninst+1))
  fi
  ash am force-stop --user "$U" "$pkg" >/dev/null 2>&1
done

echo "---"
echo "installed+launched: $ninst   on-demand placeholders: $nod"
if [ "$fail" = 0 ]; then echo "PASS: every restored keep-set app is OK in user $U"; else echo "FAIL: some restored keep-set apps failed in user $U"; fi
exit $fail
