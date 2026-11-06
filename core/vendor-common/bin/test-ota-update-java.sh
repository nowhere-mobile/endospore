#!/usr/bin/env bash
# test-ota-update-java.sh [--mutate] -- the chooser's update decisions and copy, run under javac (NWP-20261011-05).
#
# WHY THIS IS COMMITTED. Whether an update is mandatory (and the fail-safe that reads anything malformed as ordinary),
# its deadline date, when the notice may sound and on which channel, whether the gate shows its banner on the resume
# screen, and every line of copy around the SIGNED reason live in core/chooser/src/com/nowhere/chooser/OtaUpdate.java.
# Nothing else executes them off a device. core/chooser/tests/ota-update/run.sh compiles that file as it stands, with
# OtaUpdateCases.
#
# THE CALL SITES ARE PINNED, AS BLOCKS. A correct helper called wrongly is the same bug: a review mutant passing `true`
# for "is the screen on" at the ChooserActivity call site survived the cases, because the cases never see the call.
# The pins below hold each wiring block byte for byte (a "contains this line" check passes the same line moved into a
# dead branch), and the call-site mutations at the end must each be convicted by one.
#
# THE "PREPARING THE UPDATE" LINE (NWP-20261113-22). After "Sign out & install", from the first RETRY reply to
# OTA-APPLY-AFTER-LOGOFF the gate shows OtaUpdate.PREPARING on its status line with an indeterminate bar -- a line, not
# a cover: the sign-in form and the emergency link stay usable. prep_checks reads maybeInstallAfterLogoff and its
# helper afterLogoffPreparing for the shape (asked inside the retry loop, set only under the idle-gate guard, no
# setContentView but Settings', cleared on the way out); the pins hold the blocks byte for byte. Ownership is
# behaviour: core/chooser/tests/ota-update/prep/run.sh lifts afterLogoffPreparing and afterLogoffPrepHandOff unchanged
# into a class over recording TextView/ProgressBar stubs, and PrepCases drives the hand-over (the first write by anyone
# else gives the bar back determinate, at once) and the late clears (never a write to a line or bar not ours).
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (the missing-gofmt rc-127 false green, nowhere-phone/worklog.md).
# javac comes from PATH, else from the build host's JDK below; the CI runner is the build VM, which has it. The version
# is printed first so the log proves which compiler ran.
#
#   bash test-ota-update-java.sh            # the cases + the pins
#   bash test-ota-update-java.sh --mutate   # ... plus broken copies that must each FAIL them
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
# one temp root for the whole run: every mutant copy and run.sh's compile dir (via TMPDIR) are made inside it
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W"

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
DIR="$root/core/chooser/src/com/nowhere/chooser"
SRC="$DIR/OtaUpdate.java"
CHO="$DIR/ChooserActivity.java"
PRO="$DIR/ProfileActivity.java"
PPR="$DIR/ProfileProbe.java" # NWP-20261113-06: the fresh screen's withdraw moved here from probeSession
RUN="$root/core/chooser/tests/ota-update/run.sh"
PREP="$root/core/chooser/tests/ota-update/prep/run.sh"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip: install a JDK or run it on the" \
       "build VM." >&2
  exit 1
fi
export JAVAC JAVA
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 1; }
for f in "$SRC" "$CHO" "$PRO" "$RUN" "$PREP"; do [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }; done

# ---- the pinned blocks (quoted heredocs: every backslash below is literal source text) ----
IFS= read -r -d '' P_ALERT <<'EOF'
                        boolean alert = OtaUpdate.shouldAlert(us, now, updLastAlertMs, on);
                        postUpdateNotice(app, uid, us, "1".equals(pollDaemon("GET-OTA-AUTO\n").trim()), alert);
                        if (alert) updLastAlertMs = now;
EOF
IFS= read -r -d '' P_LATCH <<'EOF'
                    if (updAlertUid != uid) { updAlertUid = uid; updLastAlertMs = -1; }
                    if (us.mandatory()) {
                        android.os.PowerManager pm = app.getSystemService(android.os.PowerManager.class);
                        boolean on = pm != null && pm.isInteractive();
EOF
IFS= read -r -d '' P_ORDINARY <<'EOF'
                    } else if (us.avail && (updShownForUid != uid || updMandatory)) {
EOF
IFS= read -r -d '' P_CHANNEL <<'EOF'
            String active = null;
            for (android.service.notification.StatusBarNotification sbn : nm.getActiveNotifications()) {
                if (sbn.getId() == NOTIF_UPDATE_ID) active = sbn.getNotification().getChannelId();
            }
            final String chId = OtaUpdate.noticeChannel(s, alert, active);
EOF
IFS= read -r -d '' P_FLAGS <<'EOF'
            if (mand) {
                b.setOngoing(true)                // not swipeable where the platform honours it
                 .setOnlyAlertOnce(!alert)        // an update of the shown notice sounds only when alert says so
                 .setCategory(android.app.Notification.CATEGORY_REMINDER);
            }
            // An ordinary notice stays dismissible (no setOngoing) -- see the call site.
            nm.notify(NOTIF_UPDATE_ID, b.build());
EOF
IFS= read -r -d '' P_BANNER <<'EOF'
        otaBanner.setText(OtaUpdate.bannerText(st, resumeMode, otaAuto, java.util.TimeZone.getDefault(), java.util.Locale.getDefault()));
EOF
IFS= read -r -d '' P_REAP <<'EOF'
gg.maybeMirrorWifi(); final int ru = uid; gg.maybeRelogin(() -> gg.maybeInstallAfterLogoff(ru), () -> gg.afterLogoffUndecided(ru)); } }
EOF
IFS= read -r -d '' P_RELOGINQ <<'EOF'
                java.util.List<String> lines = DaemonSocket.roundTripLinesOrNull("GET-RELOGIN\n", 30000);
                String ans = OtaUpdate.reloginAnswer(lines);
EOF
IFS= read -r -d '' P_TIMEDOUT <<'EOF'
                String ans = OtaUpdate.reloginAnswer(lines);
                boolean timedOut = lines == null; // any failed read may still have taken the creds on the daemon
EOF
IFS= read -r -d '' P_RETRYHDR <<'EOF'
                boolean timedOut = lines == null; // any failed read may still have taken the creds on the daemon
                if ("UNKNOWN".equals(ans) && (noRelogin != null || undecided != null)) {
                    final long until = android.os.SystemClock.uptimeMillis() + OtaUpdate.AFTER_LOGOFF_WAIT_MS;
                    for (int attempt = 0; "UNKNOWN".equals(ans) && android.os.SystemClock.uptimeMillis() < until; attempt++) {
                        try { Thread.sleep(OtaUpdate.retryDelayMs(attempt)); } catch (InterruptedException ie) { break; }
                        lines = DaemonSocket.roundTripLinesOrNull("GET-RELOGIN\n", 30000);
EOF
IFS= read -r -d '' P_TIMEDOUT2 <<'EOF'
                        ans = OtaUpdate.reloginAnswer(lines);
                        if (lines == null) timedOut = true;
                    }
                }
                ans = OtaUpdate.reloginVerdict(ans, timedOut); // after a timeout, a NONE proves nothing
EOF
IFS= read -r -d '' P_NORELOGIN <<'EOF'
                if ("UNKNOWN".equals(ans)) {
                    if (undecided != null) undecided.run();
                    return;
                }
                if ("NONE".equals(ans)) {
                    if (noRelogin != null) noRelogin.run();
                    return;
                }
EOF
IFS= read -r -d '' P_APPLY <<'EOF'
                for (int attempt = 0; ; attempt++) {
                    String r = daemonCmd("OTA-APPLY-AFTER-LOGOFF\n" + uid).trim();
                    outcome = OtaUpdate.afterLogoffNext(r);
                    if (!shown && OtaUpdate.showsPreparing(outcome)) {
                        shown = true;
                        runOnUiThread(() -> afterLogoffPreparing(true));
                    }
                    if (!"RETRY".equals(outcome)) break;
                    if (android.os.SystemClock.uptimeMillis() >= until) {
                        outcome = "DROPPED".equals(daemonCmd("OTA-APPLY-AFTER-LOGOFF\n" + uid + " drop").trim())
                                ? "TIMEOUT" : "NONE";
                        break;
                    }
                    try { Thread.sleep(OtaUpdate.retryDelayMs(attempt)); }
                    catch (InterruptedException ie) { runOnUiThread(() -> afterLogoffPreparing(false)); return; }
                }
EOF
IFS= read -r -d '' P_PREPEXIT <<'EOF'
                }
                runOnUiThread(() -> afterLogoffPreparing(false)); // every exit: Settings or the outcome takes over
                android.util.Log.i("NowhereChooser", "sign out & install: " + outcome);
EOF
IFS= read -r -d '' P_PREPHELPER <<'EOF'
    private void afterLogoffPreparing(boolean on) {
        if (result == null || progressBar == null) return;
        boolean gateIdle = !sessionLive && !loginInProgress && !resumeMode;
        if (on) {
            if (!gateIdle || afterLogoffPrepWatch != null) return;
            StatusLine.busy(result, OtaUpdate.PREPARING);
            progressBar.setIndeterminate(true);
            progressBar.setVisibility(View.VISIBLE);
            afterLogoffPrepWatch = new android.text.TextWatcher() {
                @Override public void beforeTextChanged(CharSequence s, int start, int count, int after) {}
                @Override public void onTextChanged(CharSequence s, int start, int before, int count) {}
                @Override public void afterTextChanged(android.text.Editable s) {
                    if (!String.valueOf(result.getText()).endsWith(OtaUpdate.PREPARING)) afterLogoffPrepHandOff();
                }
            };
            result.addTextChangedListener(afterLogoffPrepWatch);
            return;
        }
        if (afterLogoffPrepWatch == null) return; // handed over already: the line and the bar are someone else's
        if (!gateIdle) return;                    // a sign-in owns the gate; its first write hands them over
        result.setText("");                       // the watcher sees it and hands the bar back
    }
EOF
IFS= read -r -d '' P_PREPHANDOFF <<'EOF'
    private void afterLogoffPrepHandOff() {
        if (afterLogoffPrepWatch == null) return;
        result.removeTextChangedListener(afterLogoffPrepWatch);
        afterLogoffPrepWatch = null;
        progressBar.setIndeterminate(false);
        if (!sessionLive && !loginInProgress && !resumeMode) progressBar.setVisibility(View.GONE);
    }
EOF
IFS= read -r -d '' P_UIGUARD <<'EOF'
                if ("STARTED".equals(outcome)) {
                    runOnUiThread(() -> {
                        if (!sessionLive && !loginInProgress && !resumeMode) setContentView(buildSettingsScreen());
                    });
                    return;
                }
                final String msg = OtaUpdate.afterLogoffMessage(outcome);
                if (!msg.isEmpty() && !sessionLive && !loginInProgress) showMsg(msg);
EOF
IFS= read -r -d '' P_UNDECIDED <<'EOF'
            if (!"DROPPED".equals(daemonCmd("OTA-APPLY-AFTER-LOGOFF\n" + uid + " drop").trim())) return;
EOF
IFS= read -r -d '' P_PREQ <<'EOF'
                    final boolean ok = sendDaemon("OTA-AFTER-LOGOFF\n1 " + android.os.UserHandle.myUserId() + " "
                            + otaReqNonce + "\n").trim().startsWith("OK");
EOF
# the refused sign-out's branch opens with the NWP-20261019-04 delivery re-kick, which only starts a thread and so does
# not hold the withdraw back; the block still runs from the branch's first line, so the withdraw cannot leave the branch
IFS= read -r -d '' P_PREFUSED <<'EOF'
                if (sealFailed) {
                    SignOutGate.end(); // NWP-20261109-06: still signed in, so a later sweep must run (Q116)
                    // NWP-20261019-04 (an arrival during a logoff's seal reaches the session only at its next login or
                    // resume when the logoff fails or stalls): the daemon re-arms the session and stages the RAM-only
                    // inbox for it, but it does so AFTER SEAL-STATUS says FAILED, so one delivery run can claim an
                    // empty mailbox. Re-kick every 2 s, 8 times, from a thread that outlives this activity; each run
                    // claims its mailbox atomically, so overlapping runs take disjoint sets.
                    final android.content.Context kickApp = getApplicationContext();
                    new Thread(() -> TelKick.repeat(() -> {
                        try {
                            kickApp.startService(new android.content.Intent(kickApp, CredentialService.class).putExtra("telingest", true));
                        } catch (Throwable t) { android.util.Log.w("NowhereChooser", "logoff telingest kick", t); }
                    }, 8, 2000, Thread::sleep), "nowhere-logoff-telkick").start();
                    // NWP-20261011-05: and a "Sign out & install" request goes with it. The user asked for an install
                    // AFTER a sign-out; this sign-out did not happen, so the request must not wait for some later one.
                    sendDaemon("OTA-AFTER-LOGOFF\n0 " + otaReqNonce + "\n"); // only THIS screen's request
EOF
IFS= read -r -d '' P_PSTART <<'EOF'
        // an earlier screen of this session is stale by definition: the session it asked to end is still here.
        if (!nm.isEmpty()) wd = reply(s, "OTA-AFTER-LOGOFF\n0\n");
EOF
# the two auto-install triggers: each opens with the live-session term, and neither block can match the other's site
IFS= read -r -d '' P_AUTOTIME <<'EOF'
                if (!sessionLive && !otaTriggered && "1".equals(daemonCmd("GET-OTA-AUTO"))) {
                    String t = daemonCmd("GET-OTA-TIME");
                    if (!t.isEmpty() && nowWithinWindow(t) && isCharging()
                            && otaStatusAndProg()[0].startsWith("AVAIL") && !parkedHoldsAutoInstall()) {
                        otaTriggered = true;
                        daemonCmd("OTA-APPLY");
                    }
                }
EOF
IFS= read -r -d '' P_AUTOSCREEN <<'EOF'
                        if (!sessionLive && !otaTriggered && "1".equals(daemonCmd("GET-OTA-AUTO"))
                                && daemonCmd("GET-OTA-TIME").isEmpty() // a set time uses the timer, not screen-off
                                && isCharging() && otaStatusAndProg()[0].startsWith("AVAIL")
                                && !parkedHoldsAutoInstall()) {
                            otaTriggered = true;
                            daemonCmd("OTA-APPLY");
EOF

# pinned <file> <label> <block>: the block must appear verbatim in the file.
pinned() {
  local body; body=$(cat "$1")
  [[ "$body" == *"$3"* ]] && return 0
  echo "  PIN   $2 -- the block is gone or changed in $(basename "$1")" >&2
  return 1
}

# body <file> <signature line>: the method from its signature to its first closing `    }` (4-space indent).
body() {
  awk -v sig="$2" '$0 == sig { on = 1 } on { print } on && /^    }$/ { exit }' "$1"
}

# prep_checks <ChooserActivity>: the shape of the "Preparing the update" line (NWP-20261113-22). 0 ok, 1 a check failed.
prep_checks() {
  local c="$1" bad=0 m h loop exitpart n line
  m=$(body "$c" '    void maybeInstallAfterLogoff(final int uid) {')
  h=$(body "$c" '    private void afterLogoffPreparing(boolean on) {')
  [ -n "$m" ] || { echo "  CHECK maybeInstallAfterLogoff not found" >&2; return 1; }
  # 1. the preparing state is asked for inside the retry loop: between its header and its back-off
  loop=$(printf '%s\n' "$m" | awk '/for \(int attempt = 0; ; attempt\+\+\) \{/ { on = 1 } on { print } on && /Thread\.sleep\(OtaUpdate\.retryDelayMs/ { exit }')
  [[ "$loop" == *"OtaUpdate.showsPreparing(outcome)"* ]] \
    || { echo "  CHECK OtaUpdate.showsPreparing is not called inside the retry loop" >&2; bad=1; }
  # 2. no cover: the only setContentView in the method is the STARTED branch's Settings screen
  n=$(printf '%s\n' "$m" | grep -c 'setContentView(')
  line=$(printf '%s\n' "$m" | grep 'setContentView(')
  { [ "$n" = 1 ] && [[ "$line" == *"setContentView(buildSettingsScreen())"* ]]; } \
    || { echo "  CHECK maybeInstallAfterLogoff has a setContentView other than buildSettingsScreen's ($n)" >&2; bad=1; }
  # 3. the way out of the loop clears the line before the outcome is acted on (STARTED or not)
  exitpart=$(printf '%s\n' "$m" | awk '/catch \(InterruptedException ie\)/ { on = 1; next } /if \("STARTED"\.equals\(outcome\)\)/ { exit } on { print }')
  [[ "$exitpart" == *"runOnUiThread(() -> afterLogoffPreparing(false));"* ]] \
    || { echo "  CHECK the loop's exit does not clear the preparing line" >&2; bad=1; }
  # 4. the line is set only under the idle-gate guard, re-read on the UI thread, and only by the helper
  [ -n "$h" ] || { echo "  CHECK afterLogoffPreparing not found" >&2; return 1; }
  [[ "$h" == *"boolean gateIdle = !sessionLive && !loginInProgress && !resumeMode;"* ]] \
    || { echo "  CHECK afterLogoffPreparing does not read sessionLive, loginInProgress and resumeMode" >&2; bad=1; }
  line=$(printf '%s\n' "$h" | awk '/StatusLine\.busy\(result, OtaUpdate\.PREPARING\);/ { print g; exit } /if \(!gateIdle \|\| afterLogoffPrepWatch != null\) return;/ { g = "guarded" }')
  [ "$line" = guarded ] || { echo "  CHECK the preparing line is set without the idle-gate guard before it" >&2; bad=1; }
  n=$(grep -c 'StatusLine\.busy(result, OtaUpdate\.PREPARING)' "$c")
  [ "$n" = 1 ] || { echo "  CHECK the preparing line is set outside its guarded helper ($n sites)" >&2; bad=1; }
  # 5. the clear writes only a line still ours, only on a gate still idle: both returns come before its one write
  line=$(printf '%s\n' "$h" | awk '/^        if \(afterLogoffPrepWatch == null\) return;/ { g = g "o" }
    /^        if \(!gateIdle\) return;/ { g = g "i" } /^        result\.setText\(""\);/ { print g; exit }')
  [ "$line" = oi ] || { echo "  CHECK the clear writes without first checking the line is ours and the gate idle" >&2; bad=1; }
  return "$bad"
}

# suite <OtaUpdate> <ChooserActivity> <ProfileActivity> <ProfileProbe> -> 0 pass; 1 a case or a pin failed (both are
# behaviour for this purpose: a pin is how a call-site mutant is convicted); 3 the class or the cases did not compile.
suite() {
  local o="$1" c="$2" p="$3" q="$4" bad=0
  pinned "$c" "the alert decision at the notice's call site"        "$P_ALERT"     || bad=1
  pinned "$c" "the alert latch is per session, not per resume"       "$P_LATCH"     || bad=1
  pinned "$c" "an ordinary update replaces a mandatory notice"       "$P_ORDINARY"  || bad=1
  pinned "$c" "the notice's channel: the shown one, then noticeChannel" "$P_CHANNEL" || bad=1
  pinned "$c" "the mandatory notice's builder flags"                 "$P_FLAGS"     || bad=1
  pinned "$c" "the gate banner knows the auto setting"               "$P_BANNER"    || bad=1
  pinned "$c" "the reap: install only after a relogin NONE, else undecided" "$P_REAP" || bad=1
  pinned "$c" "a GET-RELOGIN timeout is UNKNOWN, not none"           "$P_RELOGINQ"  || bad=1
  pinned "$c" "a timed-out read is remembered for the whole reap"    "$P_TIMEDOUT"  || bad=1
  pinned "$c" "the relogin retry: its entry guard and its until bound" "$P_RETRYHDR" || bad=1
  pinned "$c" "after a timeout, a later NONE is not definitive"      "$P_TIMEDOUT2" || bad=1
  pinned "$c" "unknown -> undecided, none -> the install"            "$P_NORELOGIN" || bad=1
  pinned "$c" "the install retries RETRY, then drops and says so"    "$P_APPLY"     || bad=1
  pinned "$c" "the outcome is shown on the gate, guarded"            "$P_UIGUARD"   || bad=1
  pinned "$c" "every exit of the loop clears the preparing line"     "$P_PREPEXIT"  || bad=1
  pinned "$c" "the preparing line: set on an idle gate, cleared if still ours" "$P_PREPHELPER" || bad=1
  pinned "$c" "the preparing line's hand-over: determinate, hidden unless owned" "$P_PREPHANDOFF" || bad=1
  prep_checks "$c" || bad=1
  pinned "$c" "undecided drops only a real request"                  "$P_UNDECIDED" || bad=1
  pinned "$c" "the install-time trigger skips a live session"       "$P_AUTOTIME"  || bad=1
  pinned "$c" "the screen-off trigger skips a live session"         "$P_AUTOSCREEN" || bad=1
  pinned "$p" "Profile's request names this user and this screen"   "$P_PREQ"      || bad=1
  pinned "$p" "a refused sign-out withdraws this screen's request"   "$P_PREFUSED"  || bad=1
  pinned "$q" "a fresh Profile screen withdraws any stale request"   "$P_PSTART"    || bad=1
  [ "$bad" = 0 ] || return 1
  bash "$RUN" "$o" || return $?
  bash "$PREP" "$o" "$c"
}

echo "== $SRC (+ pins in $(basename "$CHO"), $(basename "$PRO"), $(basename "$PPR"))"
suite "$SRC" "$CHO" "$PRO" "$PPR" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- by behaviour or a pin: a mutant that does not compile proves nothing)"
# mut <label> <which: O|C|P|Q> <perl-expr>
mut() {
  local d rc o="$SRC" c="$CHO" p="$PRO" q="$PPR" t
  d=$(mktemp -d -p "$W")
  case "$2" in O) t="$SRC" ;; C) t="$CHO" ;; P) t="$PRO" ;; Q) t="$PPR" ;; esac
  local m="$d/$(basename "$t")"
  if ! perl -0pe "$3" "$t" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$t" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  case "$2" in O) o="$m" ;; C) c="$m" ;; P) p="$m" ;; Q) q="$m" ;; esac
  suite "$o" "$c" "$p" "$q" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
# \x5c is a backslash and \x27 a quote: written that way, a mutation survives every layer of quoting unchanged.
mut "M1 a block with no reason is mandatory"       O 's/if \(!sawMandatory \|\| reason\.isEmpty\(\) \|\| consequence\.isEmpty\(\)\) \{/if (!sawMandatory) {/' || fails=$((fails+1))
mut "M2 an unknown severity is believed"           O 's/if \(!"mandatory"\.equals\(f\[0\]\) && !"critical"\.equals\(f\[0\]\)\) continue;//' || fails=$((fails+1))
mut "M3 a non-AVAIL reply carries the flag"        O 's/if \(!head\.equals\("AVAIL"\) && !head\.startsWith\("AVAIL "\)\) return NONE;/if (head.isEmpty()) return NONE;/' || fails=$((fails+1))
mut "M4 the notice sounds with the screen off"     O 's/if \(!s\.mandatory\(\) \|\| !interactive\) return false;/if (!s.mandatory()) return false;/' || fails=$((fails+1))
mut "M5 a not-yet-due update re-alerts"            O 's/if \(!s\.overdue\) return false;\n//' || fails=$((fails+1))
mut "M6 the re-alert every 20 minutes"             O 's/REALERT_MS = 2L \* 60 \* 60 \* 1000;/REALERT_MS = 20L * 60 * 1000;/' || fails=$((fails+1))
mut "M7 the due date is the deadline day itself"   O 's/new Date\(deadlineSec \* 1000L - 1\)/new Date(deadlineSec * 1000L)/' || fails=$((fails+1))
mut "M8 an ordinary update shown on resume"        O 's/return !resumeMode \|\| s\.mandatory\(\);/return true;/' || fails=$((fails+1))
mut "M9 the auto copy says only after sign-out"    O 's/ Automatic install is on: it installs while the phone is charging and you\x27re signed"/ It installs on its own after you sign out, while the phone is charging, and you\x27re signed"/' || fails=$((fails+1))
mut "M10 critical called required"                 O 's/String kind = s\.critical\(\) \? "Critical update" : "Required update";\n        return s\.overdue/String kind = "Required update";\n        return s.overdue/' || fails=$((fails+1))
mut "M11 the overdue title ignores the deadline"   O 's/return s\.overdue \? kind \+ " is overdue" : /return false ? kind + " is overdue" : /' || fails=$((fails+1))
mut "M12 the phone composes its own reason"        O 's/return s\.mandatory\(\) \? s\.reason : what\(s\);/return s.mandatory() ? "This update is required." : what(s);/' || fails=$((fails+1))
mut "M13 the consequence dropped from the notice"  O 's/\+ "\x5cn\x5cnIf it isn.t installed: " \+ s\.consequence\n {16}\+ "\x5cn\x5cn" \+ \(s\.overdue/+ "\x5cn\x5cn" + (s.overdue/' || fails=$((fails+1))
mut "M14 the resume banner offers a tap"           O 's/After you unlock, tap Sign out & install in Profile\./  ·   tap to install/' || fails=$((fails+1))
mut "M15 an unsaved session told it is saved"      O 's/\? "You.ll be signed out first\. This session isn.t saved to your store, so it.s erased when you sign out\."/? "You\x27ll be signed out first, and this session is saved as usual."/' || fails=$((fails+1))
mut "M16 overdue since the last due day"           O 's/(static String overdueDate[^}]*?)new Date\(deadlineSec \* 1000L\)/$1new Date(deadlineSec * 1000L - 1)/s' || fails=$((fails+1))
mut "M17 a silent re-post goes on HIGH"            O 's/return CH_REQUIRED\.equals\(activeChannel\) \? CH_REQUIRED : CH_REQUIRED_QUIET;/return CH_REQUIRED;/' || fails=$((fails+1))
mut "M18 the quiet channel is the HIGH one"        O 's/CH_REQUIRED_QUIET = "nowhere\.update\.required\.quiet";/CH_REQUIRED_QUIET = "nowhere.update.required";/' || fails=$((fails+1))
# call sites -- each must be convicted by a pin
mut "C1 the call site says the screen is always on" C 's/OtaUpdate\.shouldAlert\(us, now, updLastAlertMs, on\)/OtaUpdate.shouldAlert(us, now, updLastAlertMs, true)/' || fails=$((fails+1))
mut "C2 the latch resets at every resume"           C 's/if \(updAlertUid != uid\) \{ updAlertUid = uid; updLastAlertMs = -1; \}/if (updShownForUid != uid) { updAlertUid = uid; updLastAlertMs = -1; }/' || fails=$((fails+1))
mut "C3 every mandatory post may sound"             C 's/\.setOnlyAlertOnce\(!alert\)        /.setOnlyAlertOnce(false)        /' || fails=$((fails+1))
mut "C4 the channel decision bypassed"              C 's/final String chId = OtaUpdate\.noticeChannel\(s, alert, active\);/final String chId = mand ? OtaUpdate.CH_REQUIRED : OtaUpdate.CH_UPDATE;/' || fails=$((fails+1))
mut "C5 the install races the relogin decision"     C 's/gg\.maybeRelogin\(\(\) -> gg\.maybeInstallAfterLogoff\(ru\), \(\) -> gg\.afterLogoffUndecided\(ru\)\);/gg.maybeInstallAfterLogoff(ru); gg.maybeRelogin();/' || fails=$((fails+1))
mut "C6 no relogin, and no install either"          C 's/                    if \(noRelogin != null\) noRelogin\.run\(\);\n//' || fails=$((fails+1))
mut "C7 the gate installs without asking the daemon" C 's/daemonCmd\("OTA-APPLY-AFTER-LOGOFF\x5cn" \+ uid\)/daemonCmd("OTA-APPLY")/' || fails=$((fails+1))
mut "C8 the request names no user"                  P 's/sendDaemon\("OTA-AFTER-LOGOFF\x5cn1 " \+ android\.os\.UserHandle\.myUserId\(\) \+ " "/sendDaemon("OTA-AFTER-LOGOFF\x5cn1 " + 0 + " "/' || fails=$((fails+1))
mut "C9 a refused sign-out keeps its request"       P 's/                    sendDaemon\("OTA-AFTER-LOGOFF\x5cn0 " \+ otaReqNonce \+ "\x5cn"\); \/\/ only THIS screen.s request\n//' || fails=$((fails+1))
mut "C10 a fresh Profile keeps a stale request"     Q 's/        if \(!nm\.isEmpty\(\)\) wd = reply\(s, "OTA-AFTER-LOGOFF\x5cn0\x5cn"\);\n//' || fails=$((fails+1))
mut "J2 an ordinary update never replaces a mandatory notice" C 's/\} else if \(us\.avail && \(updShownForUid != uid \|\| updMandatory\)\) \{/} else if (us.avail \&\& updShownForUid != uid) {/' || fails=$((fails+1))
mut "J4 the shown channel is never read"            C 's/if \(sbn\.getId\(\) == NOTIF_UPDATE_ID\) active = sbn\.getNotification\(\)\.getChannelId\(\);/if (sbn.getId() == NOTIF_UPDATE_ID) active = null;/' || fails=$((fails+1))
mut "J6 the settings screen jumps over a new session" C 's/                        if \(!sessionLive && !loginInProgress && !resumeMode\) setContentView\(buildSettingsScreen\(\)\);/                        setContentView(buildSettingsScreen());/' || fails=$((fails+1))
mut "J7 the mandatory notice ignores the auto setting" C 's/postUpdateNotice\(app, uid, us, "1"\.equals\(pollDaemon\("GET-OTA-AUTO\x5cn"\)\.trim\(\)\), alert\);/postUpdateNotice(app, uid, us, false, alert);/' || fails=$((fails+1))
mut "J8 the resume banner ignores the auto setting" C 's/OtaUpdate\.bannerText\(st, resumeMode, otaAuto, /OtaUpdate.bannerText(st, resumeMode, false, /' || fails=$((fails+1))
mut "J9 a GET-RELOGIN timeout reads as none"        C 's/java\.util\.List<String> lines = DaemonSocket\.roundTripLinesOrNull\("GET-RELOGIN\x5cn", 30000\);/java.util.List<String> lines = DaemonSocket.roundTripLines("GET-RELOGIN\x5cn", 30000);/' || fails=$((fails+1))
mut "J10 an unknown relogin answer installs anyway" C 's/                    if \(undecided != null\) undecided\.run\(\);\n/                    if (noRelogin != null) noRelogin.run();\n/' || fails=$((fails+1))
mut "J11 RETRY taken as final"                      C 's/                    if \(!"RETRY"\.equals\(outcome\)\) break;\n/                    break;\n/' || fails=$((fails+1))
mut "J12 giving up leaves the request behind"       C 's/outcome = "DROPPED"\.equals\(daemonCmd\("OTA-APPLY-AFTER-LOGOFF\x5cn" \+ uid \+ " drop"\)\.trim\(\)\)\n {32}\? "TIMEOUT" : "NONE";/outcome = "TIMEOUT";/' || fails=$((fails+1))
mut "J13 the outcome is never shown"                C 's/if \(!msg\.isEmpty\(\) && !sessionLive && !loginInProgress\) showMsg\(msg\);/if (false) showMsg(msg);/' || fails=$((fails+1))
mut "J14 undecided says it even when nothing was asked" C 's/            if \(!"DROPPED"\.equals\(daemonCmd\("OTA-APPLY-AFTER-LOGOFF\x5cn" \+ uid \+ " drop"\)\.trim\(\)\)\) return;/            daemonCmd("OTA-APPLY-AFTER-LOGOFF\x5cn" + uid + " drop");/' || fails=$((fails+1))
mut "O1 a timeout reads as no relogin"              O 's/if \(lines == null \|\| lines\.isEmpty\(\)\) return "UNKNOWN";/if (lines == null || lines.isEmpty()) return "NONE";/' || fails=$((fails+1))
mut "O2 no answer from the daemon is final"         O 's/        if \(r\.startsWith\("REFUSED"\)\) return "REFUSED";\n        return "RETRY";/        if (r.startsWith("REFUSED")) return "REFUSED";\n        return "NONE";/' || fails=$((fails+1))
mut "O3 busy is final"                              O 's/r\.equals\("BUSY"\) \|\| r\.startsWith\("BUSY "\)/false/' || fails=$((fails+1))
mut "O4 the wait is 20 seconds"                     O 's/AFTER_LOGOFF_WAIT_MS = 2L \* 60 \* 1000;/AFTER_LOGOFF_WAIT_MS = 20L * 1000;/' || fails=$((fails+1))
mut "O5 the locked-session warning dropped"         O 's/\+ act \+ SLOW \+ \(auto \? AUTO_LOCKED : ""\);/+ act + SLOW;/' || fails=$((fails+1))
mut "O6 the idle lock left out of the ordinary copy" O 's/ \(with Lock, or on its own after the phone sits idle\) it waits"/ with Lock it waits"/' || fails=$((fails+1))
mut "O7 the resume banner hides the auto install"   O 's/\+ \(auto \? " Automatic install is on: it waits while this session is locked"/+ (false ? " Automatic install is on: it waits while this session is locked"/' || fails=$((fails+1))
mut "O8 the resume banner says it installs over the lock" O 's/it waits while this session is locked"\n( +)\+ " and installs after you sign out, while/it installs over this locked session"\n$1+ " and the restart ends it, while/' || fails=$((fails+1))
mut "O9 the mandatory auto copy drops signed-out"   O 's/it installs on its own while the phone is charging and"\n {12}\+ " you\x27re signed out\. While this session is locked/it installs on its own while the phone is charging and"\n            + " this session is locked. While this session is locked/' || fails=$((fails+1))
mut "O10 a NONE after a timeout is believed"        O 's/if \(anyTimedOut && "NONE"\.equals\(answer\)\) return "UNKNOWN";/if (false) return "UNKNOWN";/' || fails=$((fails+1))
mut "J15 a first timeout is forgotten"              C 's/boolean timedOut = lines == null; /boolean timedOut = false; /' || fails=$((fails+1))
mut "J16 a retry timeout is forgotten"              C 's/                        if \(lines == null\) timedOut = true;\n//' || fails=$((fails+1))
mut "J17 the verdict is never applied"              C 's/                ans = OtaUpdate\.reloginVerdict\(ans, timedOut\); /                timedOut = false; /' || fails=$((fails+1))
mut "MJ3 the retry entry guard inverted"            C 's/if \(\x22UNKNOWN\x22\.equals\(ans\) && \(noRelogin != null \|\| undecided != null\)\) \{/if (!\x22UNKNOWN\x22.equals(ans) \&\& (noRelogin != null || undecided != null)) {/' || fails=$((fails+1))
mut "J19 the install-time trigger installs over a live session" C 's/if \(!sessionLive && (!otaTriggered && "1"\.equals\(daemonCmd\("GET-OTA-AUTO"\)\))\) \{\n( +String t = daemonCmd)/if ($1) {\n$2/' || fails=$((fails+1))
mut "J20 the screen-off trigger installs over a live session" C 's/if \(!sessionLive && (!otaTriggered && "1"\.equals\(daemonCmd\("GET-OTA-AUTO"\)\)\n)( +&& daemonCmd\("GET-OTA-TIME"\))/if ($1$2/' || fails=$((fails+1))
mut "J18 the retry window unbounded"                C 's/\x22UNKNOWN\x22\.equals\(ans\) && android\.os\.SystemClock\.uptimeMillis\(\) < until; attempt\+\+/\x22UNKNOWN\x22.equals(ans); attempt++/' || fails=$((fails+1))
mut "A1 the screen-off trigger drops the parked hold" C 's/\n +&& !parkedHoldsAutoInstall\(\)\) \{/) {/' || fails=$((fails+1))
mut "A2 otaTimeCheck drops the parked hold"         C 's/ && !parkedHoldsAutoInstall\(\)\) \{\n( +otaTriggered = true;\n +daemonCmd\("OTA-APPLY"\);\n +\}\n +\}\n +\}\)\.start\(\);\n +android)/) {\n$1/' || fails=$((fails+1))
mut "A3 an empty reply reads as not parked"         O 's/if \(cl\.isEmpty\(\) \|\| cl\.startsWith\("COLDLOCK "\)\) return true;/if (cl.startsWith("COLDLOCK ")) return true;/' || fails=$((fails+1))
mut "A4 AUTO_LOCKED says the restart ends the session again" O 's/ you\x27re signed out\. While this session is locked \(with Lock, or on its own after the phone sits idle\) it"\n( +)\+ " waits until you sign out\. If/ you\x27re signed out, or while this session is locked (with Lock, or on its own after the phone sits idle) it"\n$1+ " waits until you sign out \x{2014} the restart then ends the locked session. If/' || fails=$((fails+1))
# NWP-20261113-22: the "Preparing the update" line
mut "P1 showsPreparing true for STARTED"            O 's/(static boolean showsPreparing\(String outcome\) \{\n {8})return "RETRY"\.equals\(outcome\);/$1return "RETRY".equals(outcome) || "STARTED".equals(outcome);/' || fails=$((fails+1))
mut "P2 showsPreparing always false"                O 's/(static boolean showsPreparing\(String outcome\) \{\n {8})return "RETRY"\.equals\(outcome\);/$1return false;/' || fails=$((fails+1))
mut "P3 the guard dropped from the set"             C 's/if \(!gateIdle \|\| afterLogoffPrepWatch != null\) return;/if (afterLogoffPrepWatch != null) return;/' || fails=$((fails+1))
mut "P4 the clear on the loop's exit removed"       C 's/ {16}runOnUiThread\(\(\) -> afterLogoffPreparing\(false\)\); \/\/ every exit[^\n]*\n//' || fails=$((fails+1))
mut "P5 a setContentView for the preparing state"   C 's/runOnUiThread\(\(\) -> afterLogoffPreparing\(true\)\);/runOnUiThread(() -> { setContentView(buildCoverView(OtaUpdate.PREPARING)); afterLogoffPreparing(true); });/' || fails=$((fails+1))
mut "P6 PREPARING emptied"                          O 's/PREPARING = "Preparing the update[^"]*";/PREPARING = "";/' || fails=$((fails+1))
mut "P7 the hand-over leaves the bar indeterminate" C 's/(afterLogoffPrepWatch = null;\n {8})progressBar\.setIndeterminate\(false\);\n/$1/' || fails=$((fails+1))
mut "P8 a late clear wipes a line no longer ours"   C 's/ {8}if \(afterLogoffPrepWatch == null\) return; \/\/ handed over[^\n]*\n//' || fails=$((fails+1))
mut "P9 a late clear under a sign-in"               C 's/ {8}if \(!gateIdle\) return; {20}\/\/ a sign-in owns[^\n]*\n//' || fails=$((fails+1))
mut "P10 the hand-over hides a sign-in's bar"       C 's/if \(!sessionLive && !loginInProgress && !resumeMode\) progressBar\.setVisibility\(View\.GONE\);/progressBar.setVisibility(View.GONE);/' || fails=$((fails+1))
mut "P11 no watcher: no hand-over at the first write" C 's/ {12}result\.addTextChangedListener\(afterLogoffPrepWatch\);\n//' || fails=$((fails+1))
mut "P12 the hand-over fires on any write"          C 's/if \(!String\.valueOf\(result\.getText\(\)\)\.endsWith\(OtaUpdate\.PREPARING\)\) afterLogoffPrepHandOff\(\);/afterLogoffPrepHandOff();/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
