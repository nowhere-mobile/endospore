#!/usr/bin/env bash
# test-push-doze.sh [--mutate] -- push apps stay on the Doze allow-list, by appId (NWP-20261001-05 / -20261002-01).
#
# WHY COMMITTED. On this OS deep Doze (15 s timers) firewalls the network of every app not on the Doze allow-list,
# so any app whose push rides its OWN connection -- sandboxed Play services (FCM), Thunderbird (IMAP IDLE),
# Conversations (XMPP) -- goes silent on battery until Doze ends (proven for Play, incl. a dropped WhatsApp call,
# on frankel/lynx 2026-10). The gate keeps each on the allow-list BY APPID. Every piece is SILENT when broken
# (push just stops minutes after screen-off), and several earlier defects were only a byte-level reading or a
# device apart: a by-name re-add left a stale appId; an in-session trigger never ran; an Endospore gate read an
# empty property; a missing sepolicy find made every call throw. So the package SET, both methods, the NowhereApp
# receiver, GMS_PKG and the trace writer are pinned BYTE FOR BYTE; DEVICE_POWER (comments stripped), the platform
# certificate and the deviceidle sepolicy rule too.
#
#   bash test-push-doze.sh            # the invariants
#   bash test-push-doze.sh --mutate   # ... plus mutations that must each CONVICT the checks
set -uo pipefail
MUTATE=no; for a in "$@"; do [ "$a" = --mutate ] && MUTATE=yes; done
D="$(dirname "$0")"
ACT="$D/src/com/nowhere/chooser/ChooserActivity.java"
APP="$D/src/com/nowhere/chooser/NowhereApp.java"
PRO="$D/src/com/nowhere/chooser/ProfileActivity.java"
MAN="$D/AndroidManifest.xml"
BP="$D/../vendor-common/Android.bp"
TE="$D/../vendor-common/sepolicy/nowhere.te"
for f in "$ACT" "$APP" "$PRO" "$MAN" "$BP" "$TE"; do [ -f "$f" ] || { echo "no such file: $f" >&2; exit 2; }; done
# An interpreter that RUNS, not merely one on PATH: Windows ships a python3 stub that exists and fails.
PY=""; for c in python3 python; do "$c" -c 'import re, sys' >/dev/null 2>&1 && { PY="$c"; break; }; done
[ -n "$PY" ] || { echo "python3 is required (the permission check strips XML comments)" >&2; exit 2; }
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

PIN_PKGS=$(cat <<'PIN'
    static final String[] PUSH_DOZE_PKGS = {
        ProfileActivity.GMS_PKG,            // sandboxed Play services (FCM) -- Endospore only, gmscompat-gated below
        "net.thunderbird.android",          // Thunderbird -- IMAP IDLE
        "eu.siacs.conversations",           // Conversations -- XMPP
    };
PIN
)
PIN_METHOD=$(cat <<'PIN'
    static void ensurePushDozeExemption(android.content.Context ctx) {
        synchronized (PUSH_DOZE_LOCK) {
            try {
                final android.os.PowerExemptionManager pem = ctx.getSystemService(android.os.PowerExemptionManager.class);
                if (pem == null) return;
                boolean endospore;
                try { ctx.getPackageManager().getApplicationInfo("app.grapheneos.gmscompat", 0); endospore = true; }
                catch (android.content.pm.PackageManager.NameNotFoundException notEndospore) { endospore = false; }
                for (String pkg : PUSH_DOZE_PKGS) {
                    if (ProfileActivity.GMS_PKG.equals(pkg) && !endospore) continue;
                    ensurePushDozeFor(ctx, pem, pkg);
                }
            } catch (Throwable t) {
                idleTrace("pushdoze err");
                android.util.Log.w("NowhereChooser", "ensurePushDozeExemption", t);
            }
        }
    }
PIN
)
PIN_PERAPP=$(cat <<'PIN'
    private static void ensurePushDozeFor(android.content.Context ctx, android.os.PowerExemptionManager pem, String pkg) {
        final int appId;
        try {
            appId = android.os.UserHandle.getAppId(ctx.getPackageManager().getApplicationInfo(
                    pkg, android.content.pm.PackageManager.MATCH_ANY_USER).uid);
        } catch (android.content.pm.PackageManager.NameNotFoundException absent) {
            try { pem.removeFromPermanentAllowList(pkg); } catch (Throwable notListed) {}
            return;
        }
        if (pushDozeAllowListed(pem, appId)) return;
        try { pem.removeFromPermanentAllowList(pkg); } catch (Throwable systemEntry) {}
        pem.addToPermanentAllowList(pkg);
        idleTrace("pushdoze " + pushDozeLabel(pkg) + " appid=" + appId + " ok=" + (pushDozeAllowListed(pem, appId) ? 1 : 0));
    }
PIN
)
PIN_LABEL=$(cat <<'PIN'
    private static String pushDozeLabel(String pkg) {
        if (ProfileActivity.GMS_PKG.equals(pkg)) return "play";
        if ("net.thunderbird.android".equals(pkg)) return "tbird";
        if ("eu.siacs.conversations".equals(pkg)) return "xmpp";
        return "other";
    }
PIN
)
PIN_TRACE=$(cat <<'PIN'
    static void idleTrace(final String ev) {
        new Thread(() -> {
            try { DaemonSocket.roundTrip("IDLE-TRACE\n" + ev + "\n", 3000); } catch (Throwable ignore) {}
        }, "nowhere-idle-trace").start();
    }
PIN
)
PIN_LAUNCH=$(cat <<'PIN'
        startSyncStatusWatcher(); // user-0 only: surface a "not backed up" notification when periodic seals fail
        ensureDefaultSmsRole(); // #135 B3: become user-0's default SMS app so SMS_DELIVER comes to us (idempotent)
        ensureDefaultDialerRole(); // #135 B4: become user-0's default dialer so incoming calls bind our InCallService
        ensureTransmitPerms(); // 637: self-grant SEND_SMS + CALL_PHONE (default-permissions miss an OTA'd user 0)
        ensurePushDozeExemptionAsync(getApplicationContext()); // NWP-20261001-05: push apps on Doze allow-list
PIN
)
PIN_ASYNC=$(cat <<'PIN'
    static void ensurePushDozeExemptionAsync(Context app) {
        new Thread(() -> ensurePushDozeExemption(app), "nowhere-pushdoze").start();
    }
PIN
)
PIN_APP=$(cat <<'PIN'
        // NWP-20261001-05 / NWP-20261002-01: keep the push apps on the Doze allow-list (ChooserActivity
        // .ensurePushDozeExemption) when any of them is installed, replaced or removed in ANY user. A session's
        // (re)install gives the app a new appId, which is exactly what leaves the allow-list stale, and the gate
        // Activity cannot see it: it finish()es at the switch, so none of its triggers run during a session. The
        // filter lists each push package, and the handler re-scans the whole set. USER 0 ONLY -- this Application
        // also runs in session users' chooser processes, and one device-wide owner is enough. Also once at process
        // birth, for a restart while a session holds one of them.
        if (android.os.UserHandle.myUserId() == 0) {
            try {
                android.content.IntentFilter pf = new android.content.IntentFilter(android.content.Intent.ACTION_PACKAGE_ADDED);
                pf.addAction(android.content.Intent.ACTION_PACKAGE_REPLACED);
                pf.addAction(android.content.Intent.ACTION_PACKAGE_REMOVED);
                pf.addDataScheme("package");
                for (String pkg : ChooserActivity.PUSH_DOZE_PKGS)
                    pf.addDataSchemeSpecificPart(pkg, android.os.PatternMatcher.PATTERN_LITERAL);
                registerReceiverForAllUsers(new android.content.BroadcastReceiver() {
                    @Override public void onReceive(android.content.Context c, android.content.Intent i) {
                        new Thread(() -> ChooserActivity.ensurePushDozeExemption(NowhereApp.this), "nowhere-pushdoze").start();
                    }
                }, pf, null, null, android.content.Context.RECEIVER_NOT_EXPORTED);
            } catch (Throwable t) {
                android.util.Log.w("NowhereChooser", "NowhereApp: push-doze receiver register", t);
            }
            new Thread(() -> ChooserActivity.ensurePushDozeExemption(this), "nowhere-pushdoze").start();
            // NWP-20261110-15: MMS_ALWAYS_ALLOWED is a persistent per-SIM policy and its ref count (MmsInFlight) dies
            // with this process: a crash, low-memory kill or power loss inside a gate MMS download left it on, across
            // reboots. Turn it off at every user-0 process birth on each active SIM with no download in flight.
            new Thread(() -> WapPushDeliverReceiver.resetIdlePolicies(this), "nowhere-mms-policy").start();
            // NWP-20261126-10: the idle cold lock lives in this process's statics and runtime receivers, and a restart
            // during a session loses both. Once the reap watcher's self-heal marks the session live, ask the session to
            // resend its lock prefs, so applyLivePrefs re-arms the idle watcher. RestartRearm owns the window and retry.
            try {
                RestartRearm.atProcessBirth(this);
            } catch (Throwable t) {
                android.util.Log.w("NowhereChooser", "NowhereApp: restart rearm", t);
            }
        }
    }
PIN
)
PIN_GMS=$(cat <<'PIN'
    static final String GMS_PKG = "com.google.android.gms";
PIN
)

# A pinned block must occur in the file exactly once, byte for byte. Pins go through ENVIRON (awk -v would
# interpret the backslash escape inside the trace pin).
once(){ PINV="$1" awk 'BEGIN { n = split(ENVIRON["PINV"], P, "\n") }
  { L[++m] = $0; if (m >= n) { same = 1; for (k = 1; k <= n; k++) if (L[m - n + k] != P[k]) same = 0; if (same) hits++ } }
  END { exit !(hits == 1) }' "$2"; }
c_pkgs(){   once "$PIN_PKGS"   "$1"; }   # the exact SET of exempted packages
c_method(){ once "$PIN_METHOD" "$1"; }   # gmscompat gate + Play-only skip + loop
c_perapp(){ once "$PIN_PERAPP" "$1"; }   # the appId-checked re-bind / drop-when-absent
c_label(){  once "$PIN_LABEL"  "$1"; }
c_trace(){  once "$PIN_TRACE"  "$1"; }
c_launch(){ once "$PIN_LAUNCH" "$1"; }
c_async(){  once "$PIN_ASYNC"  "$1"; }   # the gate-launch call runs on its own thread, with the app context
c_app(){    once "$PIN_APP"    "$1"; }
c_gms(){    once "$PIN_GMS"    "$1"; }
c_perm(){ "$PY" - "$1" <<'PYEOF'
import re, sys
s = open(sys.argv[1], encoding="utf-8").read()
s = re.sub(r"<!--.*?-->", "", s, flags=re.S)
sys.exit(0 if '<uses-permission android:name="android.permission.DEVICE_POWER"/>' in s else 1)
PYEOF
}
c_cert(){ awk '/name: "NowhereChooser",/{f=1} f&&/^    certificate: "platform",$/{hit=1} f&&/^}/{f=0} END{exit !hit}' "$1"; }
c_sepol(){ grep -qx 'allow nowhere_chooser deviceidle_service:service_manager find;' "$1"; }

echo "== push apps are kept on the Doze allow-list, by appId =="
c_pkgs "$ACT"   && ok "the exempted set is exactly Play + Thunderbird + Conversations (pinned)"           || no "PUSH_DOZE_PKGS changed -- the set of device-wide Doze exemptions is the security surface"
c_method "$ACT" && ok "ensurePushDozeExemption: gmscompat-gates ONLY Play, loops the set (pinned)"        || no "ensurePushDozeExemption differs from the pinned block"
c_perapp "$ACT" && ok "ensurePushDozeFor: appId-checked re-bind, drop when absent (pinned)"               || no "ensurePushDozeFor differs from the pinned block"
c_label "$ACT"  && ok "the trace labels are the pinned play/tbird/xmpp set"                               || no "pushDozeLabel changed"
c_launch "$ACT" && ok "called in the gate-launch ensure sequence (pinned)"                                || no "the gate-launch sequence is missing, changed or wrapped"
c_async "$ACT"  && ok "the gate-launch call runs off the UI thread with the app context (pinned)"          || no "ensurePushDozeExemptionAsync changed -- onCreate could wait on PUSH_DOZE_LOCK"
c_app "$APP"    && ok "NowhereApp: user-0 receiver over PUSH_DOZE_PKGS + a run at birth (pinned)"          || no "the NowhereApp session-time trigger is missing or changed"
c_trace "$ACT"  && ok "idleTrace still sends IDLE-TRACE to the daemon (pinned)"                           || no "idleTrace changed -- the pushdoze login.log line could vanish"
c_gms "$PRO"    && ok "GMS_PKG is com.google.android.gms (pinned)"                                        || no "GMS_PKG changed"
c_perm "$MAN"   && ok "the chooser declares DEVICE_POWER (not commented out)"                             || no "DEVICE_POWER not declared -- the allow-list calls would throw"
c_cert "$BP"    && ok "NowhereChooser is platform-signed (what grants DEVICE_POWER)"                      || no "NowhereChooser is not platform-signed -- DEVICE_POWER would not be granted"
c_sepol "$TE"   && ok "sepolicy lets nowhere_chooser find deviceidle_service"                             || no "the deviceidle_service find rule is gone -- PowerExemptionManager would NPE on every call"

if [ "$MUTATE" = yes ]; then
  echo; echo "== mutations (each MUST be convicted) =="
  M=$(mktemp -d)
  mut(){ if ! sed "$4" "$3" > "$M/x" 2>/dev/null; then no "MUTATION BROKEN (sed): $1"; return; fi
         if cmp -s "$3" "$M/x"; then no "MUTATION INERT: $1"; return; fi
         if "$2" "$M/x"; then no "NOT CONVICTED: $1"; else ok "convicted: $1"; fi; }
  mut "Thunderbird dropped from the exempted set"               c_pkgs   "$ACT" '/"net.thunderbird.android",/d'
  mut "Conversations dropped from the exempted set"             c_pkgs   "$ACT" '/"eu.siacs.conversations",/d'
  mut "a stray package added to the exempted set"               c_pkgs   "$ACT" 's#"eu.siacs.conversations",           // Conversations -- XMPP#"eu.siacs.conversations", "com.evil.app",#'
  mut "the Play-only gmscompat skip removed (Play exempted on Diaspore)"  c_method "$ACT" '/if (ProfileActivity.GMS_PKG.equals(pkg) \&\& !endospore) continue;/d'
  mut "the skip inverted (gmscompat gates the curated apps instead)"      c_method "$ACT" 's/if (ProfileActivity.GMS_PKG.equals(pkg) \&\& !endospore) continue;/if (!ProfileActivity.GMS_PKG.equals(pkg) \&\& !endospore) continue;/'
  mut "the loop body no longer calls the per-app ensure"        c_method "$ACT" '/ensurePushDozeFor(ctx, pem, pkg);/d'
  mut "the gmscompat gate always true (Play on Diaspore)"       c_method "$ACT" 's/boolean endospore;/boolean endospore = true; if (true) {} else/'
  mut "re-add without the remove (stale appId stays effective)" c_perapp "$ACT" '/catch (Throwable systemEntry) {}/d'
  mut "the effective-appId check removed (adds every time)"     c_perapp "$ACT" '/if (pushDozeAllowListed(pem, appId)) return;/d'
  mut "MATCH_ANY_USER dropped (misses an app installed only in a session)" c_perapp "$ACT" 's/android.content.pm.PackageManager.MATCH_ANY_USER/0/'
  mut "the absent-package branch no longer returns"             c_perapp "$ACT" '/^            return;$/d'
  mut "the trace no longer reports the outcome"                 c_perapp "$ACT" 's/ + " ok=" + (pushDozeAllowListed(pem, appId) ? 1 : 0)//'
  mut "the gate-launch call removed"                            c_launch "$ACT" '/^        ensurePushDozeExemptionAsync(getApplicationContext());/d'
  mut "the gate-launch call back on the UI thread"               c_launch "$ACT" 's#^        ensurePushDozeExemptionAsync(getApplicationContext());#        ensurePushDozeExemption(this);#'
  mut "the async helper runs on the calling thread"              c_async "$ACT" 's#        new Thread(() -> ensurePushDozeExemption(app), "nowhere-pushdoze").start();#        ensurePushDozeExemption(app);#'
  mut "NowhereApp: the user-0 guard removed"                    c_app "$APP" 's/if (android.os.UserHandle.myUserId() == 0) {/if (true) {/'
  mut "NowhereApp: the filter no longer loops the set"          c_app "$APP" '/for (String pkg : ChooserActivity.PUSH_DOZE_PKGS)/d'
  mut "NowhereApp: REPLACED (app updates) not watched"          c_app "$APP" '/ACTION_PACKAGE_REPLACED/d'
  mut "NowhereApp: only user 0 installs seen"                   c_app "$APP" 's/registerReceiverForAllUsers(/registerReceiver(/'
  mut "NowhereApp: the run at process birth removed"            c_app "$APP" '/^            new Thread(() -> ChooserActivity.ensurePushDozeExemption(this), "nowhere-pushdoze").start();$/d'
  mut "idleTrace made a no-op"                                  c_trace "$ACT" '/DaemonSocket.roundTrip("IDLE-TRACE\\n" + ev + "\\n", 3000)/d'
  mut "GMS_PKG renamed"                                         c_gms "$PRO" 's/"com.google.android.gms";/"com.google.android.gsf";/'
  mut "DEVICE_POWER commented out"                              c_perm "$MAN" 's|^  <uses-permission android:name="android.permission.DEVICE_POWER"/>$|  <!-- & -->|'
  mut "DEVICE_POWER dropped"                                    c_perm "$MAN" '/android.permission.DEVICE_POWER"\/>$/d'
  mut "NowhereChooser certificate commented out"                c_cert "$BP" '/name: "NowhereChooser",/,/^}/s|^    certificate: "platform",$|    // certificate: "platform",|'
  mut "the deviceidle_service find rule removed"                c_sepol "$TE" '/^allow nowhere_chooser deviceidle_service:service_manager find;$/d'
  rm -rf "$M"
fi

echo; echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
