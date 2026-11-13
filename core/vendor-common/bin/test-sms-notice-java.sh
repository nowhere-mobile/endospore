#!/usr/bin/env bash
# test-sms-notice-java.sh [--mutate] -- NWP-20261010-13: the roamed session's message notices and its SMS app. Runs
# core/chooser/tests/sms-notice: the chooser's pure decisions, compiled and EXECUTED, and the wiring around them pinned
# byte for byte (tests/sms-notice/run.sh says how).
#
# WHY THIS IS COMMITTED. TelIngest posts the session's one notice per text or MMS. It must clear when the message is
# read -- at any time, not for 3 minutes after delivery -- and must never be cleared by a read-back that could not see
# (a missing READ_SMS grant answers an EMPTY cursor, which looks exactly like "every row gone"). The re-sweep that backs
# up the provider observers must stop for a notice whose read never reaches the provider. A tap must open the thread in
# the profile's SMS app, never the chooser, never an "Open with" chooser. The SMS app the profile chose is used at every
# sign-in (Chester, 2026-10-11), is captured only after this session applied it, and the gate's repair must never
# replace it. The chooser's default-SMS-app components are disabled in a roamed user, all of them. Each of these is one
# line a later edit can change without breaking a build.
#
# It needs a JDK, and it FAILS when there is none: a Java suite that skips without one would read green on a runner that
# never ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21. --mutate re-runs it against
# deliberately broken copies, each of which must fail a CASE or a PIN (a copy that no longer compiles convicts nothing
# and is reported).
#
#   bash test-sms-notice-java.sh            # the cases and the pins
#   bash test-sms-notice-java.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail
MUTATE=no; for a in "$@"; do [ "$a" = --mutate ] && MUTATE=yes; done
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
CH="$ROOT/core/chooser"
RUN="$CH/tests/sms-notice/run.sh"
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-sms-notice-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
export JAVAC JAVA

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

echo "== the cases and the pins =="
bash "$RUN" "$CH"; rc=$?
if [ "$rc" = 0 ]; then ok "every case and pin passes"; else no "the suite did not pass (run.sh exit $rc: 1 a case or pin, 2 cannot run, 3 no compile)"; fi

# --- mutations ------------------------------------------------------------------------------------------
if [ "$MUTATE" = yes ] && [ "$rc" = 0 ]; then
  echo
  echo "== mutations (each MUST be convicted by a case or a pin) =="
  M=$(mktemp -d)
  trap 'rm -rf "$M"' EXIT
  mutate(){ # mutate <label> <file under the chooser dir> <sed script>
    rm -rf "$M/c"; mkdir -p "$M/c/src/com/nowhere/chooser"
    cp "$CH"/src/com/nowhere/chooser/*.java "$M/c/src/com/nowhere/chooser/"
    cp "$CH/AndroidManifest.xml" "$M/c/"
    cp -r "$CH/res" "$M/c/" # NWP-20261123-24: the drawable case reads res/ beside the manifest
    local f="$M/c/$2"
    if ! sed -i "$3" "$f" 2>"$M/err"; then no "MUTATION BROKEN (sed): $1"; return; fi
    if cmp -s "$f" "$CH/$2"; then no "MUTATION INERT: $1"; return; fi
    bash "$RUN" "$M/c" >/dev/null 2>&1; local r=$?
    case "$r" in
      1) ok "convicted: $1" ;;
      0) no "NOT CONVICTED: $1 -- suite passes on broken code" ;;
      *) no "MUTATION BROKEN (run.sh exit $r, not a case): $1" ;;
    esac
  }
  T=src/com/nowhere/chooser/TelIngest.java; S=src/com/nowhere/chooser/MessagingSuppressor.java
  C=src/com/nowhere/chooser/ChooserActivity.java; R=src/com/nowhere/chooser/SmsDeliverReceiver.java
  RR=src/com/nowhere/chooser/SmsRoleRoam.java; CS=src/com/nowhere/chooser/CredentialService.java
  U=src/com/nowhere/chooser/UnarchiveService.java; SN=src/com/nowhere/chooser/SenderName.java
  # the clear
  mutate "a blind read-back polls"                         $T 's/^        return NOTICE_KEEP;$/        return NOTICE_POLL;/'
  mutate "a blind read-back clears"                        $T 's/^        return NOTICE_KEEP;$/        return NOTICE_CLEAR;/'
  mutate "a gone row cleared with no grace"                $T 's/return ageMs >= GONE_GRACE_MS ? NOTICE_CLEAR : NOTICE_POLL;/return NOTICE_CLEAR;/'
  mutate "a deleted conversation never clears"             $T 's/return ageMs >= GONE_GRACE_MS ? NOTICE_CLEAR : NOTICE_POLL;/return NOTICE_POLL;/'
  mutate "an unread row cleared"                           $T 's/if (state == 0) return NOTICE_POLL;/if (state == 0) return NOTICE_CLEAR;/'
  mutate "the READ_SMS op ignored (empty cursor = gone)"   $T 's/if (!canRead || !answered) return ROW_BLIND;/if (!answered) return ROW_BLIND;/'
  mutate "an answered empty read-back read as blind"       $T 's/if (!found) return ROW_GONE;/if (!found) return ROW_BLIND;/'
  mutate "the grace shorter than the login delivery"       $T 's/static final long GONE_GRACE_MS = 120_000L;/static final long GONE_GRACE_MS = 30_000L;/'
  mutate "a non-canonical tag names a row"                 $T 's/if (when <= 0 || !tag.equals(noticeTag(kind, when))) return null;/if (when <= 0) return null;/'
  mutate "a foreign tag names a row"                       $T 's/if (!"sms".equals(kind) \&\& !"mms".equals(kind)) return null;//'
  mutate "an MMS found by its date"                        $T 's/"m_id=?", mmsKey(Long.parseLong(row\[1\]))/"date=?", row[1]/'
  mutate "a repeated tag looked up twice"                  $T 's/if (row == null || out.containsKey(tag)) continue;/if (row == null) continue;/'
  # the re-sweep
  mutate "the re-sweep never stops"                        $S 's/if (pollable <= 0 || idle >= 6) return -1L;/if (pollable <= 0) return -1L;/'
  mutate "the re-sweep never backs off"                    $S 's/return 15_000L << Math.max(idle, 0);/return 15_000L;/'
  mutate "an event does not restart the backoff"           $S 's/return event || cleared > 0 ? 0 : idle + 1;/return cleared > 0 ? 0 : idle + 1;/'
  mutate "the sweep debounced with no throttle"            $S 's/return Math.max(0L, Math.min(500L, pendingSince + 2_000L - now));/return 500L;/'
  # the tap
  mutate "the tap pinned to the chooser"                   $T 's/if (roleHolder != null \&\& !roleHolder.isEmpty() \&\& !roleHolder.equals(self)) return roleHolder;/if (roleHolder != null \&\& !roleHolder.isEmpty()) return roleHolder;/'
  mutate "the tap left implicit when the holder is unknown" $T 's/return fallback == null || fallback.isEmpty() || fallback.equals(self) ? null : fallback;/return null;/'
  mutate "the tap never falls back to SENDTO"              $T 's/return !pinned || viewResolves ? "view" : "sendto";/return "view";/'
  # the role step and the components
  mutate "the repair replaces the profile's app"           $RR 's/return holders.isEmpty() || roleHeldBy(holders, self) ? "assign" : "leave";/return "assign";/'
  mutate "the repair never repairs"                        $RR 's/return holders.isEmpty() || roleHeldBy(holders, self) ? "assign" : "leave";/return "leave";/'
  mutate "the sign-in apply keeps another app"             $RR 's/^        if (signIn) return "assign";$/        if (signIn \&\& holders == null) return "assign";/'
  mutate "the SENDTO stub left enabled in a roamed user"   $C 's/ ".ComposeSmsActivity",//'
  mutate "the WAP push receiver left enabled"              $C 's/".WapPushDeliverReceiver", //'
  # the name
  mutate "a call notice named Messages"                    $R 's/return "call".equals(kind) ? "Phone" : "Messages";/return "Messages";/'
  mutate "the substitute-name permission not requested"    AndroidManifest.xml '/<uses-permission android:name="android.permission.SUBSTITUTE_NOTIFICATION_APP_NAME"\/>/d'
  # the call notices (NWP-20261123-24)
  mutate "a call keeps the label again"                    $R 's/return "call".equals(kind) ? "Phone" : "Messages";/return "call".equals(kind) ? null : "Messages";/'
  mutate "the gate call notice drawn as an envelope"       $R 's/.setSmallIcon(isCall ? R.drawable.ic_notif_call : R.drawable.ic_notif_message) \/\/ NWP-20261010-13/.setSmallIcon(R.drawable.ic_notif_message) \/\/ NWP-20261010-13/'
  mutate "the loss call notice drawn as an envelope"       $R 's/.setSmallIcon(isCall ? R.drawable.ic_notif_call : R.drawable.ic_notif_message).setAutoCancel(true)/.setSmallIcon(R.drawable.ic_notif_message).setAutoCancel(true)/'
  mutate "the session missed call unnamed"                 $T '/static void postMissedCallNotice(/,/^    }$/{/^                    .addExtras(named)$/d}'
  mutate "the session missed call on the legacy glyph"     $T '/static void postMissedCallNotice(/,/^    }$/s/.setSmallIcon(R.drawable.ic_notif_call)/.setSmallIcon(android.R.drawable.stat_notify_missed_call)/'
  mutate "the call glyph not white"                        res/drawable/ic_notif_call.xml 's/#FFFFFFFF/#FF000000/'
  # the wiring (round-2 review: these survived both suites until the pins)
  mutate "the watcher repairs at once, racing the sign-in apply" $C 's/^                    repairSmsRoleLater(uid, "watcher");$/                    new Thread(() -> ensureRoamedSmsRole(uid)).start();/'
  mutate "the lift repairs at once"                        $C 's/^                repairSmsRoleLater(uid, "lift");$/                ensureRoamedSmsRole(uid);/'
  mutate "the gate's repair replaces the profile's app"    $C 's/SmsRoleRoam.ensureHolder(uc, uh, SmsRoleRoam.MESSAGING, false, getPackageName(),/SmsRoleRoam.ensureHolder(uc, uh, SmsRoleRoam.MESSAGING, true, getPackageName(),/'
  mutate "the repair without its delay"                    $C '/^            try { Thread.sleep(SmsRoleRoam.SMS_REPAIR_DELAY_MS); } catch (InterruptedException ie) { return; }$/d'
  mutate "the cede never kicks the sign-in apply"          $C 's/putExtra("smsrole", true)/putExtra("smsrole", false)/'
  mutate "a null cursor read as gone"                      $T 's/if (c == null) return rowState(true, false, false, 0);/if (c == null) return rowState(true, true, false, 0);/'
  mutate "a throwing query read as gone"                   $T '/private static int readState(Context ctx, String\[\] q, boolean canRead) {/,/^    }$/s/^            return rowState(true, false, false, 0);$/            return rowState(true, true, false, 0);/'
  mutate "canReadMessages ignores the op"                  $T 's/return ao != null \&\& ao.unsafeCheckOpNoThrow(/return true || ao.unsafeCheckOpNoThrow(/'
  mutate "the notice without its public version"           $T '/^                    .setPublicVersion(locked)$/d'
  mutate "the notice without its name"                     $T '/^                    .setPublicVersion(locked)$/{n;d}'
  mutate "the public version without its name"             $T '/^                    .setSmallIcon(R.drawable.ic_notif_message)$/{n;/addExtras(named)/d}'
  mutate "the MMS notice tagged nowhere_mms again"         $T 's/postRoamedMessageNotice(ctx, noticeTag("mms", when), from,/postRoamedMessageNotice(ctx, "nowhere_mms", from,/'
  mutate "the listener never starts its read clear"        $S '/^        startReadClear();$/d'
  mutate "the restricted-read re-grant dropped from the repair" $C '/^                try { grantMessagingRestrictedRead(ruc); } catch (Throwable ignore) {} \/\/ #150: after the role settles$/d'
  # the profile's SMS app (Chester, 2026-10-11)
  mutate "the listener never starts the SMS-app capture"   $S '/^        startRoleCapture();$/d'
  mutate "the role listener never registered"              $S 's/getSystemService(android.app.role.RoleManager.class).addOnRoleHoldersChangedListenerAsUser(/if (false) getSystemService(android.app.role.RoleManager.class).addOnRoleHoldersChangedListenerAsUser(/'
  mutate "the sign-in apply never runs"                    $CS 's/try { SmsRoleRoam.applyAtSignIn(this); DefaultRoleRoam.applyAtSignIn(this); } finally { finishUnit(); }/try { DefaultRoleRoam.applyAtSignIn(this); } finally { finishUnit(); }/'
  mutate "the materialise hook dropped"                    $U '/^        SmsRoleRoam.onMaterialised(ctx, pkg);$/d'
  mutate "no listener grant at sign-in"                    $RR '/^        TelIngest.ensureNotificationListener(ctx);$/d'
  mutate "a capture before this session's apply"           $RR 's/^        if (!session.equals(s)) return null;$/        if (s == null) return null;/'
  mutate "the stand-in Messaging captured over the record" $RR '/if (("deferred".equals(state) || "fallback".equals(state)) \&\& holder.equals(applied)) return null;/d'
  mutate "the chooser captured as a choice"                $RR 's/if (!isPackageName(holder) || holder.equals(self)) return null;/if (!isPackageName(holder)) return null;/'
  mutate "Messaging recorded with no choice made"          $RR '/if (holder.equals(messaging) \&\& record == null) return null;/d'
  mutate "an archived app given the role before it exists" $RR 's/^        return new String\[\]{messaging, "deferred", record};$/        return new String[]{record, "applied", record};/'
  mutate "an absent app dropped at sign-in (absence read as a choice)" $RR 's/^        return new String\[\]{messaging, "deferred", record};$/        return new String[]{messaging, "applied", messaging};/'
  mutate "an unknown presence read as absent at sign-in"    $RR 's/if ("installed".equals(presence) || "unknown".equals(presence)) return new String\[\]{record, "applied", record};/if ("installed".equals(presence)) return new String[]{record, "applied", record};/'
  mutate "a materialised app takes over the user's new pick" $RR 's/return holders.isEmpty() || holders.contains(applied) || holders.contains(self);/return true;/'
  mutate "the repair delay shorter than the apply"         $RR 's/static final long SMS_REPAIR_DELAY_MS = 60_000L;/static final long SMS_REPAIR_DELAY_MS = 5_000L;/'
  mutate "the capture permission not requested"            AndroidManifest.xml '/<uses-permission android:name="android.permission.OBSERVE_ROLE_HOLDERS"\/>/d'
  # round 3 review: re-archive, foreign markers, stale repairs, the sign-in regrant
  mutate "a re-archive captured as a choice of Messaging"  $RR 's/if (record == null || record.equals(messaging) || record.equals(self) || "installed".equals(presence)) return null;/if (true) return null;/'
  mutate "an unknown presence changes the capture"         $RR 's/if (!"archived".equals(presence) \&\& !"absent".equals(presence)) return "none";//'
  mutate "the capture's none ignored"                      $RR '/^                if ("none".equals(st)) return; \/\/ PackageManager could not say: change nothing$/d'
  mutate "a binder failure read as absent"                 $RR '/^    static String presence(Context ctx, String pkg) {$/,/^    }$/s/^            return "unknown";$/            return "absent";/'
  mutate "a binder failure read as installed-nothing (falls to the archive check)" $RR '/^    static String presence(Context ctx, String pkg) {$/,/^    }$/{/^        } catch (Throwable t) {$/{n;s/^            return "unknown";$/            \/\/ fall through/}}'
  mutate "absence read as a choice at capture"             $RR '/^    static String standInState(/,/^    }$/s/^        return "deferred";$/        return null;/'
  # NWP-20261123-23: an unreadable record at sign-in is unknown -- Messaging stands in, no marker
  mutate "an unreadable record's content ignored (every record file is unknown)" $RR 's/return isFile \&\& length <= 4096 \&\& content == null;/return isFile \&\& length <= 4096;/'
  mutate "an absent record read as unknown"                $RR 's/return isFile \&\& length <= 4096 \&\& content == null;/return !isFile;/'
  mutate "an oversized record read as unknown"             $RR 's/return isFile \&\& length <= 4096 \&\& content == null;/return isFile \&\& content == null;/'
  mutate "the unreadable-record guard at sign-in disabled" $RR 's/^            if (recordUnknown(isFile, length, content)) {$/            if (false) {/'
  mutate "the unreadable-record branch writes a marker"    $RR 's/^\(                        + " stands in, no marker (NWP-20261123-23)");\)$/\1 if (session != null) write(ctx, MARKER, markerText(session, "applied", MESSAGING, MESSAGING));/'
  mutate "materialise: an applied marker still takes over" $RR 's/^        if (m == null || "applied".equals(m\[0\]) || !m\[2\].equals(pkg)) return null;$/        if (m == null || !m[2].equals(pkg)) return null;/'
  mutate "materialise: any app takes the role"             $RR 's/^        if (m == null || "applied".equals(m\[0\]) || !m\[2\].equals(pkg)) return null;$/        if (m == null || "applied".equals(m[0])) return null;/'
  mutate "materialise: a missing marker reaches the role"  $RR 's/^        if (m == null || "applied".equals(m\[0\]) || !m\[2\].equals(pkg)) return null;$/        if (m != null \&\& ("applied".equals(m[0]) || !m[2].equals(pkg))) return null;/'
  mutate "materialise: over the user's pick"               $RR 's/^        return takeOverFromStandIn(holders, m\[1\], self) ? pkg : null;$/        return pkg;/'
  mutate "onMaterialised ignores its target guard"         $RR 's/^                    if (materialiseTarget(m, pkg, holders, self) == null) {$/                    if (false) {/'
  mutate "retry: any state retried"                        $RR 's/if (m == null || !"fallback".equals(m\[0\]) || m\[2\].equals(messaging) || !"installed".equals(presence)) return null;/if (m == null || m[2].equals(messaging) || !"installed".equals(presence)) return null;/'
  mutate "retry: an absent app retried"                    $RR 's/if (m == null || !"fallback".equals(m\[0\]) || m\[2\].equals(messaging) || !"installed".equals(presence)) return null;/if (m == null || !"fallback".equals(m[0]) || m[2].equals(messaging)) return null;/'
  mutate "retry: over the user's pick"                     $RR 's/^        return roleHeldBy(holders, messaging) ? m\[2\] : null;$/        return m[2];/'
  mutate "retry: never retried"                            $RR 's/^        return roleHeldBy(holders, messaging) ? m\[2\] : null;$/        return null;/'
  mutate "the repair never kicks the retry"                $C 's/putExtra("smsretry", true)/putExtra("smsretry", false)/'
  mutate "the retry start never runs it"                   $CS 's/try { SmsRoleRoam.retryRefused(this); } finally { finishUnit(); }/try { } finally { finishUnit(); }/'
  mutate "a takeover assigns over a pick made between attempts" $RR 's/^        return holders.isEmpty() || holders.contains(standIn) || roleHeldBy(holders, self) ? "assign" : "leave";$/        return "assign";/'
  mutate "a takeover with an unreadable list assigns"      $RR '/^    static String takeoverStep(/,/^    }$/s/^        if (holders == null) return "leave";$/        if (holders == null) return "assign";/'
  mutate "ensureHolder ignores the takeover mode"          $RR 's/String step = standIn != null ? takeoverStep(holders, self, want, standIn) : smsRoleStep(holders, signIn, self, want);/String step = smsRoleStep(holders, signIn, self, want);/'
  mutate "the retry runs in sign-in mode"                  $RR 's/t, true, self, ctx.getMainExecutor(), MESSAGING);/t, true, self, ctx.getMainExecutor(), null);/'
  mutate "onMaterialised runs in sign-in mode"             $RR 's/pkg, true, self, ctx.getMainExecutor(), m\[1\]);/pkg, true, self, ctx.getMainExecutor(), null);/'
  mutate "a reinstall never hands the role back"           src/com/nowhere/chooser/AppInstallReceiver.java '/^                SmsRoleRoam.onMaterialised(context, pkg);$/d'
  mutate "a session matched by prefix"                     $RR 's/^        if (!session.equals(s)) return null;$/        if (s == null || !session.startsWith(s)) return null;/'
  mutate "no marker when the apply did not land"           $RR 's/^                if (session != null) write(ctx, MARKER, markerText(session, state, want, target));$/                if (session != null \&\& "held".equals(r)) write(ctx, MARKER, markerText(session, state, want, target));/'
  mutate "a refused apply still marked applied"            $RR '/^                if (!"held".equals(r)) state = "fallback";/d'
  mutate "the sign-in +4 s regrant dropped"                $RR '/^            try { Thread.sleep(4000); } catch (InterruptedException ie) { return; }$/{n;d}'
  mutate "a stale repair runs into the next session"       $RR 's/return scheduledSerial >= 0 \&\& scheduledSerial == nowSerial;/return true;/'
  mutate "the repair ignores its session"                  $C '/^            if (!SmsRoleRoam.repairStillValid(serial, userSerial(uid))) {$/,/^            }$/d'
  mutate "the repair assigns an empty role without a second look" $RR '/^                if (!confirmed) { \/\/ a repair: look again before taking a role that may be changing hands$/,/^                }$/d'
  # the sender's name (NWP-20261201-29)
  mutate "M1 the notice ignores the contact's name (case: title: a saved contact shows the name)" $SN '/if (!name.isEmpty()) return name;/d'
  mutate "M2 a blank name does not fall back (case: title: a blank name falls back to the number)" $SN 's/if (!name.isEmpty()) return name;/if (contactName != null) return name;/'
  mutate "M3 the lookup runs in user 0 (case: lookup: never in user 0)" $SN 's/ \&\& userId != 0;/;/'
  mutate "M4 the call site passes no name (pin: TelIngest.postRoamedMessageNotice)" $T 's/? contactName(ctx, from) : null);/? null : null);/'
  mutate "M5 run() never grants READ_CONTACTS (pin: TelIngest.run.contactsGrant)" $T '/^        ensureContactsRead(ctx);/d'
  mutate "M6 the grant adds WRITE_CONTACTS (pin: TelIngest.ensureContactsRead)" $T '/private static void ensureContactsRead(/,/^    }$/s/^            if (dpm == null) return;$/&\n            dpm.setPermissionGrantState(new android.content.ComponentName(ctx, AdminReceiver.class), ctx.getPackageName(), android.Manifest.permission.WRITE_CONTACTS, android.app.admin.DevicePolicyManager.PERMISSION_GRANT_STATE_GRANTED);/'
  mutate "M7 the notice loses the envelope (pin: TelIngest.postRoamedMessageNotice)" $T '/private static void postRoamedMessageNotice(/,/^    }$/s/.setSmallIcon(R.drawable.ic_notif_message)/.setSmallIcon(R.drawable.ic_nowhere_notif)/'
  mutate "M8 the tap takes the title (pin: TelIngest.postRoamedMessageNotice)" $T 's/^                    messageTapIntent(ctx, from),$/                    messageTapIntent(ctx, title),/'
  mutate "M9 contactName logs the name (pin: TelIngest.contactName)" $T '/private static String contactName(/,/^    }$/s/^            return c != null \&\& c.moveToFirst() ? c.getString(0) : null;$/            String n = c != null \&\& c.moveToFirst() ? c.getString(0) : null; android.util.Log.i("NowhereChooser", "contact " + n); return n;/'
  mutate "M10 the grant's user-0 guard removed (pin: TelIngest.ensureContactsRead)" $T '/private static void ensureContactsRead(/,/^    }$/{/android.os.UserHandle.myUserId() == 0/d}'
  mutate "M11 the envelope not white (case: drawable: ic_notif_message path 0)" res/drawable/ic_notif_message.xml 's/#FFFFFFFF/#FF000000/'
  mutate "M11b the envelope's second path not white (case: drawable: ic_notif_message path 1)" res/drawable/ic_notif_message.xml '/fillColor="#FFFFFFFF"/{N;/M4,6 L12/s/#FFFFFFFF/#FF000000/}'
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
