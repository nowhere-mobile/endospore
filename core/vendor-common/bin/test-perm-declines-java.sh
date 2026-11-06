#!/usr/bin/env bash
# test-perm-declines-java.sh [--mutate] -- the chooser's half of "a declined permission stays declined"
# (NWP-20261012-05): PermDeclines run under javac, plus the role re-apply wired where the roles are added.
#
# WHY THIS IS COMMITTED. roamd's grant_perms_for re-declines what the profile declined at login, but the SMS role apply
# runs AFTER it (SmsRoleRoam.applyAtSignIn -> ensureHolder -> addRoleHolderAsUser), and the SMS and dialer roles are
# overrideUserWhenGranting="true": PermissionController grants every role permission that was not granted and CLEARS
# USER_SET / USER_FIXED. So the profile's SMS app had every decline undone at every sign-in, and the cleared flags meant
# the next capture lost the decline as well. The chooser now snapshots the target's live declines before a role add
# and applies them after, and re-applies the recorded declines to the SMS and dialer holders after its sign-in role
# step. Every way that breaks is silent: the app is granted what the user refused, or asks again.
#
# ⚠ THE ONE EXCEPTION (NWP-20261012-08, Chester 2026-10-12: "yes keep the read_sms access"): the SMS ROLE holder keeps
# the six permissions the SMS role grants (READ_SMS, RECEIVE_SMS, RECEIVE_MMS, RECEIVE_WAP_PUSH, SEND_SMS,
# READ_CELL_BROADCASTS; Chester 2026-10-13: "All six") over a recorded decline, and nothing else does --
# not its other declines, not the dialer holder, not the candidate roamd spared that did not get the role. The cases
# pin the six and the capture's carry of a recorded decline for EVERY permission (keptDecline; widened by
# NWP-20261102-10, Q059: a mid-session fill of an empty dialer or SMS role re-grants and clears the flags, the capture
# keeps the decline, and the re-grant lasts only the rest of that session -- nothing revokes); the wiring pins the role add's snapshot without
# them, the sign-in re-apply that spares only the SMS holder, and the decline of a candidate that is not the holder --
# at sign-in, and in session (every onMaterialised path that does not end holding the role, the stand-in after a
# takeover) where it touches only what the user has not answered (unanswered), so an update can neither take back a
# mid-session grant nor harden a mid-session "Don't allow" into USER_FIXED.
#
#   - core/chooser/tests/perm-declines/run.sh lifts PermDeclines' PURE block and runs Cases.java: the words the capture
#     writes, roamd's allowlist (the re-apply must honour exactly what roamd honours), and the file parse.
#   - The rest is Android API code (PackageManager, RoleManager) with no harness off a device, so it is pinned on its
#     FUNCTIONAL source forms, each scoped to one method: flags BEFORE the revoke, what counts as declined, the
#     snapshot/apply around the SMS role add, the sign-in re-apply for the SMS and dialer holders, and the manifest's
#     REVOKE_RUNTIME_PERMISSIONS (without it every write throws).
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (same rule as test-owner-throttle-java.sh). javac comes from PATH,
# else from the build host's JDK below; the CI runner is the build VM, which has it.
#
#   bash test-perm-declines-java.sh            # the cases
#   bash test-perm-declines-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W"

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
CH="core/chooser/src/com/nowhere/chooser"
RUN="$root/core/chooser/tests/perm-declines/run.sh"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip: install a JDK or run it on the" \
       "build VM." >&2
  exit 2
fi
export JAVAC JAVA
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
[ -f "$RUN" ] || { echo "FAIL: missing $RUN" >&2; exit 2; }

# suite <root> -> 0 pass, 1 a case failed, 2 a file or method is missing, 3 the lifted class did not compile.
suite() {
  local r="$1" PD SR MF rc fails=0 body
  PD="$r/$CH/PermDeclines.java"; SR="$r/$CH/SmsRoleRoam.java"; MF="$r/core/chooser/AndroidManifest.xml"
  [ -f "$PD" ] && [ -f "$SR" ] && [ -f "$MF" ] || { echo "missing source under $r" >&2; return 2; }
  echo "== behaviour (lifted PURE block)"
  bash "$RUN" "$PD"; rc=$?
  case "$rc" in 0) ;; 1) fails=$((fails+1)) ;; *) return "$rc" ;; esac

  echo "== wiring (source forms, one method each)"
  ok(){ printf '  ok    %s\n' "$1"; }
  no(){ printf '  FAIL  %s\n' "$1"; fails=$((fails+1)); }
  # m <file> <method-signature substring>: the method's text, from its signature to the brace that closes it
  m(){ awk -v s="$2" '!on && index($0, s) { on=1; depth=0 } on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }' "$1"; }
  # ln <text> <fixed string>: line number of its first occurrence, 0 when absent
  ln(){ local l; l=$(grep -nF -- "$2" <<<"$1" | head -1 | cut -d: -f1); echo "${l:-0}"; }

  body=$(m "$PD" "static int apply(Context uc,")
  local fl rv; fl=$(ln "$body" 'pm.updatePermissionFlags(d[0], pkg, mask, mask, uh);'); rv=$(ln "$body" 'pm.revokeRuntimePermission(pkg, d[0], uh);')
  if [ "$fl" -gt 0 ] && [ "$rv" -gt "$fl" ]; then ok "apply sets the flags BEFORE it revokes ($fl<$rv)"
  else no "apply no longer sets the flags before the revoke (flags $fl, revoke $rv)"; fi
  if grep -qF 'flagFails.add(t);' <<<"$body" && grep -qF 'revokeFails.add(t);' <<<"$body" \
     && grep -qF 'android.util.Log.w("NowhereChooser", "declines " + pkg + ": " + flagFails.n + " flag write(s) FAILED' <<<"$body"; then
    ok "apply counts and logs a failed flag write or revoke"
  else no "apply swallows a failure -- a decline that did not land would look applied"; fi

  if grep -qF 'if (declines == null || declines.isEmpty() || pkg == null || !plainName(pkg)) return 0;' <<<"$body" \
     && grep -qF 'if (bits == 0 || !plainName(d[0])) continue;' <<<"$body"; then
    ok "apply refuses a package or permission name roamd would refuse (M4)"
  else no "apply dropped a plainName check -- an option-shaped name reaches PackageManager"; fi

  body=$(m "$PD" "static java.util.List<String[]> snapshot(")
  if grep -qF '& android.content.pm.PackageInfo.REQUESTED_PERMISSION_GRANTED) != 0) continue;' <<<"$body"; then
    ok "snapshot skips GRANTED permissions -- else the re-apply after a role add would REVOKE them all (M1)"
  else no "snapshot no longer skips granted permissions -- ensureHolder would revoke every granted permission of the SMS app"; fi
  if grep -qF 'if ("android.permission.INTERNET".equals(perm)) continue;' <<<"$body"; then
    ok "snapshot leaves INTERNET to its deny: channel (M5)"
  else no "snapshot keeps INTERNET -- the re-apply would revoke the SMS app's network"; fi

  body=$(m "$PD" "static String declinedWord(")
  if grep -qF '!= android.content.pm.PermissionInfo.PROTECTION_DANGEROUS) return null;' <<<"$body"; then
    ok "only a DANGEROUS permission can be declined (C1)"
  else no "the PROTECTION_DANGEROUS filter is gone -- normal and signature permissions would be written as declines"; fi
  if [ "$(grep -cF 'fails.add(t);' <<<"$body")" = 2 ] \
     && grep -qF 'catch (android.content.pm.PackageManager.NameNotFoundException undefined) {' <<<"$body"; then
    ok "an undefined permission is skipped; any other failure of either read is counted (F6)"
  else no "a read failure is swallowed or escapes -- it drops the rest of the package unseen"; fi
  if grep -qF 'if ((pflags & android.content.pm.PackageManager.FLAG_PERMISSION_AUTO_REVOKED) != 0) return null;' <<<"$body"; then
    ok "a permission hibernation AUTO_REVOKED is not a decline (F5)"
  else no "AUTO_REVOKED counts as a decline -- hibernation would be roamed as the user's refusal"; fi
  if grep -qF '(pflags & android.content.pm.PackageManager.FLAG_PERMISSION_USER_SET) != 0,' <<<"$body" \
     && grep -qF '(pflags & android.content.pm.PackageManager.FLAG_PERMISSION_USER_FIXED) != 0);' <<<"$body"; then
    ok "USER_SET and USER_FIXED both decide it"
  else no "a user flag is ignored"; fi

  body=$(m "$SR" "static String ensureHolder(")
  local sn ad ap; sn=$(ln "$body" 'if (declines == null) declines = self.equals(want) ? new java.util.ArrayList<>()')
  [ "$sn" -gt 0 ] && [ "$(sed -n "$((sn + 1))p" <<<"$body" | tr -d ' ')" = ':PermDeclines.exceptSmsRole(PermDeclines.snapshot(uc,uh,want));' ] || sn=0
  ad=$(ln "$body" 'rm.addRoleHolderAsUser(android.app.role.RoleManager.ROLE_SMS, want,')
  ap=$(grep -cF 'PermDeclines.apply(uc, uh, want, declines, "sms role add");' <<<"$body")
  if [ "$sn" -gt 0 ] && [ "$ad" -gt "$sn" ] && [ "$ap" = 2 ]; then
    ok "ensureHolder snapshots the live declines before the add and applies them when the role is held (2 sites)"
  else no "the SMS role add is no longer bracketed (snapshot $sn, add $ad, applies $ap) -- it re-grants every decline"; fi
  # NWP-20261012-08: the snapshot is taken WITHOUT the SMS permissions (the add's grant of them stands) -- pinned by
  # the two-line form just above, which sn is 0 without.
  if [ "$sn" -gt 0 ]; then
    ok "the role add's snapshot leaves out the SMS permissions -- the new SMS app keeps them (X1)"
  else no "the role add's re-apply would revoke the SMS permissions it just granted the SMS app"; fi
  if grep -qF 'if (declines != null) PermDeclines.apply(uc, uh, want, declines, "sms role add");' <<<"$body"; then
    ok "an add that is only verified on a later attempt still gets its declines back"
  else no "a late-landing add keeps its re-grants"; fi

  body=$(m "$SR" "static void applyAtSignIn(Context ctx)")
  if [ "$(grep -v '^ *//' <<<"$body" | grep -v '^ *}$' | tail -1 | tr -d ' ')" = 'PermDeclines.reapplyRoleHolders(ctx,"sign-inrolestep");' ]; then
    ok "the sign-in apply re-applies the recorded declines LAST, after its role step"
  else no "the sign-in apply no longer ends with reapplyRoleHolders -- the SMS and dialer holders keep the role grants"; fi

  body=$(m "$PD" "static void reapplyRoleHolders(")
  if grep -qF 'new String[] { android.app.role.RoleManager.ROLE_SMS, android.app.role.RoleManager.ROLE_DIALER }' <<<"$body" \
     && grep -qF 'java.util.List<String[]> d = fromFile(ctx, h);' <<<"$body" \
     && grep -qF 'if (h == null || h.equals(self)) continue;' <<<"$body"; then
    ok "reapplyRoleHolders covers the SMS and dialer holders from the recorded file"
  else no "reapplyRoleHolders lost a role, its source, or its skip of the chooser (M2)"; fi

  # NWP-20261012-08: the SMS app keeps its SMS permissions; the candidate that did not get the role does not.
  if grep -qF 'if (android.app.role.RoleManager.ROLE_SMS.equals(role)) sms.addAll(h);' <<<"$body" \
     && [ "$(sed -n "$(( $(ln "$body" 'java.util.List<String[]> d = fromFile(ctx, h);') + 1 ))p" <<<"$body" | tr -d ' ')" \
          = 'if(sms.contains(h))d=exceptSmsRole(d);//NWP-20261012-08:theSMSappkeepsitsSMSpermissions' ]; then
    ok "reapplyRoleHolders leaves the SMS permissions to the SMS role holder only, not the dialer holder (X2)"
  else no "reapplyRoleHolders revokes the SMS app's SMS permissions, or spares the dialer's"; fi
  if grep -qF 'for (String c : smsCandidates(recordedSmsApp(ctx), self, SmsRoleRoam.MESSAGING)) {' <<<"$body" \
     && grep -qF 'if (holders.contains(c)) continue; // a dialer holder had all its declines above' <<<"$body" \
     && grep -qF 'declineSmsRoleIfNotHolder(ctx, c, sms, false, why); // the sign-in step: revokes, as roamd' <<<"$body"; then
    ok "reapplyRoleHolders declines the six for the candidate roamd spared that did not get the role, revoking (X3)"
  else no "a candidate that did not become the SMS app keeps SMS permissions the profile declined"; fi

  # recordedSmsApp is the chooser's half of the record read roamd mirrors: pinned whole (a null answer would make
  # Messaging the only candidate, so a recorded app that did not get the role would keep its six all session).
  body=$(m "$PD" "static String recordedSmsApp(Context ctx) {")
  if [ "$body" = '    static String recordedSmsApp(Context ctx) {
        try {
            java.io.File f = new java.io.File(ctx.getFilesDir(), SmsRoleRoam.RECORD);
            if (!f.isFile() || f.length() > 4096) return null;
            return SmsRoleRoam.parseSmsRecord(new String(java.nio.file.Files.readAllBytes(f.toPath()),
                    java.nio.charset.StandardCharsets.UTF_8));
        } catch (Throwable t) {
            return null;
        }
    }' ]; then
    ok "recordedSmsApp reads nowhere-sms through parseSmsRecord, at most 4096 bytes, as roamd does (X7)"
  else no "recordedSmsApp changed -- the chooser and roamd no longer agree on the recorded SMS app"; fi

  body=$(m "$PD" "static void declineSmsRoleIfNotHolder(")
  if grep -qF 'if (smsHolders.contains(pkg)) return;' <<<"$body" \
     && grep -qF 'if (!inSession && !smsCandidates(recordedSmsApp(ctx), ctx.getPackageName(), SmsRoleRoam.MESSAGING).contains(pkg)) return;' <<<"$body" \
     && grep -qF 'java.util.List<String[]> d = onlySmsRole(fromFile(ctx, pkg));' <<<"$body" \
     && grep -qF 'if (!"installed".equals(SmsRoleRoam.presence(ctx, pkg))) return;' <<<"$body"; then
    ok "declineSmsRoleIfNotHolder: an installed non-holder, a candidate at sign-in, only its SMS declines (X4)"
  else no "declineSmsRoleIfNotHolder can decline the SMS app, a non-candidate, or more than the SMS permissions"; fi
  if [ "$(grep -A3 -F 'android.util.Log.w("NowhereChooser", "declines: SMS role holders unreadable after " + why' <<<"$body" | grep -cxF '                return;')" = 1 ]; then
    ok "unreadable SMS role holders decline nothing (the app may hold the role)"
  else no "unreadable role holders still decline -- the SMS app could lose READ_SMS"; fi
  if [ "$(sed -n "$(( $(ln "$body" 'java.util.List<String[]> d = onlySmsRole(fromFile(ctx, pkg));') + 1 ))p" <<<"$body" | tr -d ' ')" \
       = 'if(inSession)d=unanswered(ctx,pkg,d);' ]; then
    ok "in session the decline is limited to what the user has not answered -- no revoke of a grant, no hardening (X8)"
  else no "an in-session decline can revoke a grant -- an update would take back the user's mid-session READ_SMS"; fi
  body=$(m "$PD" "static java.util.List<String[]> unanswered(")
  if [ "$(grep -A4 -F 'for (String[] x : d) {' <<<"$body" | tr -d ' ' | tr '\n' '~')" \
       = 'for(String[]x:d){~try{~if(pm.checkPermission(x[0],pkg)==android.content.pm.PackageManager.PERMISSION_GRANTED)continue;~if((pm.getPermissionFlags(x[0],pkg,me)&answered)!=0)continue;~out.add(x);~' ] \
     && [ "$(grep -A1 -F 'final int answered = android.content.pm.PackageManager.FLAG_PERMISSION_USER_SET' <<<"$body" | tr -d ' ' | tr '\n' '~')" \
       = 'finalintanswered=android.content.pm.PackageManager.FLAG_PERMISSION_USER_SET~|android.content.pm.PackageManager.FLAG_PERMISSION_USER_FIXED;~' ] \
     && [ "$(grep -A2 -F '} catch (Throwable t) {' <<<"$body" | grep -cxF '                fails.add(t);')" = 1 ] \
     && ! grep -qF 'out.add(x);' <<<"$(grep -A3 -F '} catch (Throwable t) {' <<<"$body")"; then
    ok "unanswered keeps only what is not granted and carries no user flag, and drops what it could not read (X9)"
  else no "unanswered keeps a granted or user-answered permission, or one it could not read -- a mid-session change on a guess"; fi

  body=$(m "$PD" "static String carriedDecline(")
  if grep -qxF '        String old = oldDeclineWord(oldLines, pkg, perm);' <<<"$body" \
     && grep -qF '!= android.content.pm.PermissionInfo.PROTECTION_DANGEROUS) return null;' <<<"$body" \
     && [ "$(grep -A1 -F 'PackageManager.NameNotFoundException undefined) {' <<<"$body" | grep -cxF '            return null;')" = 1 ] \
     && [ "$(grep -A2 -F 'fails.add(t);' <<<"$body" | grep -cxF '            return old;')" = 2 ] \
     && grep -qF 'return keptDecline(perm, (f & android.content.pm.PackageManager.FLAG_PERMISSION_USER_SET) != 0,' <<<"$body" \
     && grep -qF '(f & android.content.pm.PackageManager.FLAG_PERMISSION_USER_FIXED) != 0, old);' <<<"$body" \
     && grep -qF 'f = pm.getPermissionFlags(perm, pkg, user);' <<<"$body"; then
    ok "carriedDecline looks up pkg's own decline for ANY permission, skips a not-dangerous or undefined one, reads both user flags, keeps the decline on a failed read (X5, K3, K4)"
  else no "carriedDecline looks up the wrong line, is SMS-only, carries a not-dangerous permission, ignores a user flag, or drops the decline when a read fails"; fi

  # The in-session declines, every one passing inSession=true (never a revoke of a grant): onMaterialised on each path
  # that does not end with pkg holding the role, and the stand-in after a takeover there and in retryRefused.
  body=$(m "$SR" "static void onMaterialised(" | grep -v '^ *//' | tr -d ' ')
  if [ "$(grep -A2 -F 'if(m==null||"applied".equals(m[0])||!m[2].equals(pkg)){' <<<"$body" | tr '\n' '~')" \
       = 'if(m==null||"applied".equals(m[0])||!m[2].equals(pkg)){//nottheappwewaitfor~PermDeclines.declineSmsRoleIfNotHolder(ctx,pkg,null,true,"smsroleonmaterialise");~return;~' ]; then
    ok "onMaterialised: an app that is not the one waited for (or no marker) gets the six's declines (X6a)"
  else no "onMaterialised's first early return skips the decline -- a recorded app keeps its six undeclined"; fi
  if [ "$(grep -A4 -F 'if(materialiseTarget(m,pkg,holders,self)==null){' <<<"$body" | tail -2 | tr '\n' '~')" \
       = 'PermDeclines.declineSmsRoleIfNotHolder(ctx,pkg,holders,true,"smsroleonmaterialise");~return;~' ]; then
    ok "onMaterialised: an app whose takeover is left (another holder) gets the six's declines (X6b)"
  else no "onMaterialised's 'another app holds the role' return skips the decline"; fi
  if [ "$(grep -A5 -F 'if("held".equals(r)){' <<<"$body" | tr '\n' '~')" \
       = 'if("held".equals(r)){~write(ctx,MARKER,markerText(session,"applied",pkg,pkg));~PermDeclines.declineSmsRoleIfNotHolder(ctx,m[1],null,true,"smsroletakenover");~}elsePermDeclines.declineSmsRoleIfNotHolder(ctx,pkg,null,true,"smsroleonmaterialise");~}catch(Throwablet){~android.util.Log.w("NowhereChooser","NWP-20261010-13smsroleonmaterialise",t);~' ]; then
    ok "onMaterialised: a takeover declines the six for the stand-in it took over from; a failed one for the app (X6c)"
  else no "onMaterialised: the stand-in keeps the six after a takeover, or a takeover that did not hold leaves them"; fi
  [ "$(grep -c 'declineSmsRoleIfNotHolder(' <<<"$body")" = 4 ] && [ "$(grep -c 'declineSmsRoleIfNotHolder(ctx,[^,]*,[^,]*,true,' <<<"$body")" = 4 ] \
    && ok "onMaterialised declines at exactly four sites, all in-session" \
    || no "onMaterialised's decline sites changed, or one revokes like the sign-in step"
  body=$(m "$SR" "static void retryRefused(Context ctx)" | grep -v '^ *//' | tr -d ' ')
  if [ "$(grep -A3 -F 'if("held".equals(r)){' <<<"$body" | tr '\n' '~')" \
       = 'if("held".equals(r)){~write(ctx,MARKER,markerText(session,"applied",t,t));~PermDeclines.declineSmsRoleIfNotHolder(ctx,MESSAGING,null,true,"smsroletakenover");~}~' ]; then
    ok "retryRefused: a takeover declines the six for Messaging, the stand-in (X10)"
  else no "retryRefused: Messaging keeps the six after the recorded app takes the role over"; fi

  if grep -qF '<uses-permission android:name="android.permission.REVOKE_RUNTIME_PERMISSIONS"/>' "$MF"; then
    ok "the manifest requests REVOKE_RUNTIME_PERMISSIONS"
  else no "the manifest does not request REVOKE_RUNTIME_PERMISSIONS -- every re-apply throws"; fi

  [ "$fails" = 0 ]
}

echo "== $root"
suite "$root" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED; a mutant that does not extract or compile proves nothing)"
mut() { # mut <label> <file under CH, or MANIFEST> <perl-expr>
  local d f rel rc
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/$CH"
  cp "$root/$CH/PermDeclines.java" "$root/$CH/SmsRoleRoam.java" "$d/$CH/"
  cp "$root/core/chooser/AndroidManifest.xml" "$d/core/chooser/"
  if [ "$2" = MANIFEST ]; then rel="core/chooser/AndroidManifest.xml"; else rel="$CH/$2"; fi
  f="$d/$rel"
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed"; rm -rf "$d"; return 1; fi
  if cmp -s "$root/$rel" "$f"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  suite "$d" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not extract or compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "B1 user-fixed alone is not a decline"            PermDeclines.java 's/return userFixed \? "user-fixed" : null;/return null;/' || fails=$((fails+1))
mut "B2 the allowlist takes review-required"          PermDeclines.java 's/if \("user-set"\.equals\(w\)\) return 1;/if ("user-set".equals(w) || "review-required".equals(w)) return 1;/' || fails=$((fails+1))
mut "B3 a dash-led name passes"                       PermDeclines.java 's/if \(!\(\(c0 >= .A. && c0 <= .Z.\) \|\| \(c0 >= .a. && c0 <= .z.\)\)\) return false;/if (c0 == 0) return false;/' || fails=$((fails+1))
mut "B4 INTERNET is honoured"                         PermDeclines.java 's/\n                    \|\| "android\.permission\.INTERNET"\.equals\(perm\)\) continue;/) continue;/' || fails=$((fails+1))
mut "B5 the unterminated last line is read"           PermDeclines.java 's/for \(String ln : text\.substring\(0, end\)\.split\("\\n", -1\)\) \{/for (String ln : text.split("\\n", -1)) {/' || fails=$((fails+1))
mut "B6 another package's lines are read"             PermDeclines.java 's/\|\| !f\[0\]\.equals\(pkg\) \|\|/||/' || fails=$((fails+1))
mut "B7 a carried user-fixed is not softened"        PermDeclines.java 's/return prefix \+ "user-set" \+ rest\.substring\(c\);/return line;/' || fails=$((fails+1))
mut "M1 snapshot keeps GRANTED permissions"          PermDeclines.java 's/                    if \(\(pi\.requestedPermissionsFlags\[i\]\n                            & android\.content\.pm\.PackageInfo\.REQUESTED_PERMISSION_GRANTED\) != 0\) continue;\n//' || fails=$((fails+1))
mut "M5 snapshot keeps INTERNET"                     PermDeclines.java 's/                    if \("android\.permission\.INTERNET"\.equals\(perm\)\) continue;\n//' || fails=$((fails+1))
mut "M2 reapplyRoleHolders re-applies to the chooser" PermDeclines.java 's/if \(h == null \|\| h\.equals\(self\)\) continue;/if (h == null) continue;/' || fails=$((fails+1))
mut "M4a apply takes any package name"               PermDeclines.java 's/ \|\| pkg == null \|\| !plainName\(pkg\)\) return 0;/ || pkg == null) return 0;/' || fails=$((fails+1))
mut "M4b apply takes any permission name"            PermDeclines.java 's/if \(bits == 0 \|\| !plainName\(d\[0\]\)\) continue;/if (bits == 0) continue;/' || fails=$((fails+1))
mut "S1 apply revokes BEFORE it sets the flags"       PermDeclines.java 's/(            try \{\n                pm\.updatePermissionFlags\(d\[0\], pkg, mask, mask, uh\);)/            try { pm.revokeRuntimePermission(pkg, d[0], uh); } catch (Throwable t0) {}\n$1/' || fails=$((fails+1))
mut "S2 a failed flag write is swallowed"             PermDeclines.java 's/                flagFails\.add\(t\);\n                continue;/                continue;/' || fails=$((fails+1))
mut "C1 the PROTECTION_DANGEROUS filter is gone"      PermDeclines.java 's/            if \(pm\.getPermissionInfo\(perm, 0\)\.getProtection\(\)\n                    != android\.content\.pm\.PermissionInfo\.PROTECTION_DANGEROUS\) return null;/            pm.getPermissionInfo(perm, 0);/' || fails=$((fails+1))
mut "F6 a getPermissionInfo failure is swallowed"     PermDeclines.java 's/        \} catch \(Throwable t\) \{\n            fails\.add\(t\);\n            return null;\n        \}\n        int pflags;/        } catch (Throwable t) {\n            return null;\n        }\n        int pflags;/' || fails=$((fails+1))
mut "F5 AUTO_REVOKED counts as a decline"             PermDeclines.java 's/        if \(\(pflags & android\.content\.pm\.PackageManager\.FLAG_PERMISSION_AUTO_REVOKED\) != 0\) return null;\n//' || fails=$((fails+1))
mut "S3 reapplyRoleHolders forgets the dialer"        PermDeclines.java 's/, android\.app\.role\.RoleManager\.ROLE_DIALER \}/ }/' || fails=$((fails+1))
mut "S4 ensureHolder takes no snapshot"               SmsRoleRoam.java 's/PermDeclines\.exceptSmsRole\(PermDeclines\.snapshot\(uc, uh, want\)\);/new java.util.ArrayList<>();/' || fails=$((fails+1))
mut "S5 ensureHolder does not apply after its add"    SmsRoleRoam.java 's/                if \(ok\[0\]\) \{\n                    PermDeclines\.apply\(uc, uh, want, declines, "sms role add"\);/                if (ok[0]) {/' || fails=$((fails+1))
mut "S6 a later-verified add is not re-declined"      SmsRoleRoam.java 's/                    if \(declines != null\) PermDeclines\.apply\(uc, uh, want, declines, "sms role add"\);[^\n]*\n//' || fails=$((fails+1))
mut "S7 the sign-in apply skips reapplyRoleHolders"   SmsRoleRoam.java 's/        PermDeclines\.reapplyRoleHolders\(ctx, "sign-in role step"\);\n//' || fails=$((fails+1))
mut "S8 the manifest drops REVOKE_RUNTIME_PERMISSIONS" MANIFEST         's/  <uses-permission android:name="android\.permission\.REVOKE_RUNTIME_PERMISSIONS"\/>\n//' || fails=$((fails+1))
# NWP-20261012-08: the SMS app keeps its SMS permissions -- only the SMS role holder, only the six.
mut "B8 READ_CELL_BROADCASTS is not the SMS role's"  PermDeclines.java 's/"android\.permission\.SEND_SMS", "android\.permission\.READ_CELL_BROADCASTS",/"android.permission.SEND_SMS",/' || fails=$((fails+1))
mut "B9 the exempt set widened to READ_CONTACTS"      PermDeclines.java 's/"android\.permission\.READ_CELL_BROADCASTS",\n/"android.permission.READ_CELL_BROADCASTS", "android.permission.READ_CONTACTS",\n/' || fails=$((fails+1))
mut "K2 keptDecline ignores USER_SET (a user grant)" PermDeclines.java 's/if \(userSet \|\| userFixed \|\| wordBits\(oldWord\) == 0\)/if (userFixed || wordBits(oldWord) == 0)/' || fails=$((fails+1))
mut "K1 keptDecline only for the SMS role's six again" PermDeclines.java 's/if \(userSet \|\| userFixed \|\| wordBits\(oldWord\) == 0\)/if (!smsRolePerm(perm) || userSet || userFixed || wordBits(oldWord) == 0)/' || fails=$((fails+1))
mut "B12 smsCandidates forgets Messaging"             PermDeclines.java 's/        out\.add\(messaging\);\n//' || fails=$((fails+1))
mut "B13 smsCandidates takes the chooser"             PermDeclines.java 's/if \(recorded != null && !recorded\.equals\(self\) && /if (recorded != null && /' || fails=$((fails+1))
mut "B14 oldDeclineWord takes a refused word"         PermDeclines.java 's/            if \(wordBits\(w\) != 0\) return w;/            return w;/' || fails=$((fails+1))
mut "B15 exceptSmsRole keeps the SMS declines"        PermDeclines.java 's/if \(!smsRolePerm\(d\[0\]\)\) out\.add\(d\);/out.add(d);/' || fails=$((fails+1))
mut "X1 the role add re-declines the SMS permissions" SmsRoleRoam.java  's/: PermDeclines\.exceptSmsRole\(PermDeclines\.snapshot\(uc, uh, want\)\);/: PermDeclines.snapshot(uc, uh, want);/' || fails=$((fails+1))
mut "X2a the SMS holder gets every decline at sign-in" PermDeclines.java 's/            if \(sms\.contains\(h\)\) d = exceptSmsRole\(d\);[^\n]*\n//' || fails=$((fails+1))
mut "X2b the SMS holders are never collected"         PermDeclines.java 's/                if \(android\.app\.role\.RoleManager\.ROLE_SMS\.equals\(role\)\) sms\.addAll\(h\);\n//' || fails=$((fails+1))
mut "X2c the dialer holder is exempt too"             PermDeclines.java 's/if \(android\.app\.role\.RoleManager\.ROLE_SMS\.equals\(role\)\) sms\.addAll\(h\);/sms.addAll(h);/' || fails=$((fails+1))
mut "X3 no decline for the candidate without the role" PermDeclines.java 's/            declineSmsRoleIfNotHolder\(ctx, c, sms, false, why\);[^\n]*\n//' || fails=$((fails+1))
mut "X4a the holder is declined after all"            PermDeclines.java 's/        if \(smsHolders\.contains\(pkg\)\) return;\n//' || fails=$((fails+1))
mut "X4c every decline, not just the SMS ones"        PermDeclines.java 's/onlySmsRole\(fromFile\(ctx, pkg\)\)/fromFile(ctx, pkg)/' || fails=$((fails+1))
mut "X4d unreadable holders still decline"            PermDeclines.java 's/(SMS role holders unreadable after " \+ why\n[^\n]*\n)                return;\n/$1/' || fails=$((fails+1))
mut "X5a a failed flag read drops the kept decline"  PermDeclines.java 's/(f = pm\.getPermissionFlags\(perm, pkg, user\);\n        \} catch \(Throwable t\) \{\n            fails\.add\(t\);\n            return) old;/$1 null;/' || fails=$((fails+1))
mut "X5b carriedDecline ignores USER_SET"               PermDeclines.java 's/\(f & android\.content\.pm\.PackageManager\.FLAG_PERMISSION_USER_SET\) != 0,/false,/' || fails=$((fails+1))
mut "X6a no decline when the marker says not this app" SmsRoleRoam.java  's/                    if \(m == null \|\| "applied"\.equals\(m\[0\]\) \|\| !m\[2\]\.equals\(pkg\)\) \{ \/\/ not the app we wait for\n                        PermDeclines\.declineSmsRoleIfNotHolder\(ctx, pkg, null, true, "sms role on materialise"\);\n/                    if (m == null || "applied".equals(m[0]) || !m[2].equals(pkg)) { \/\/ not the app we wait for\n/' || fails=$((fails+1))
mut "X6b no decline when another app holds the role" SmsRoleRoam.java  's/                        PermDeclines\.declineSmsRoleIfNotHolder\(ctx, pkg, holders, true, "sms role on materialise"\);\n//' || fails=$((fails+1))
mut "X6c the stand-in keeps the six after a takeover" SmsRoleRoam.java  's/                        PermDeclines\.declineSmsRoleIfNotHolder\(ctx, m\[1\], null, true, "sms role taken over"\);\n//' || fails=$((fails+1))
mut "X6d a takeover that did not hold leaves the six" SmsRoleRoam.java  's/ else PermDeclines\.declineSmsRoleIfNotHolder\(ctx, pkg, null, true, "sms role on materialise"\);//' || fails=$((fails+1))
mut "X6e onMaterialised revokes in session"           SmsRoleRoam.java  's/declineSmsRoleIfNotHolder\(ctx, pkg, holders, true,/declineSmsRoleIfNotHolder(ctx, pkg, holders, false,/' || fails=$((fails+1))
mut "X7 recordedSmsApp always answers no record (M6)" PermDeclines.java 's/            return SmsRoleRoam\.parseSmsRecord\(new String\(java\.nio\.file\.Files\.readAllBytes\(f\.toPath\(\)\),\n                    java\.nio\.charset\.StandardCharsets\.UTF_8\)\);/            return null;/' || fails=$((fails+1))
mut "X7b recordedSmsApp has no size cap"              PermDeclines.java 's/            if \(!f\.isFile\(\) \|\| f\.length\(\) > 4096\) return null;/            if (!f.isFile()) return null;/' || fails=$((fails+1))
mut "X8 the in-session decline revokes grants"       PermDeclines.java 's/        if \(inSession\) d = unanswered\(ctx, pkg, d\);\n//' || fails=$((fails+1))
mut "X9a unanswered keeps a granted permission"      PermDeclines.java 's/                if \(pm\.checkPermission\(x\[0\], pkg\) == android\.content\.pm\.PackageManager\.PERMISSION_GRANTED\) continue;\n//' || fails=$((fails+1))
mut "X9c unanswered hardens a mid-session answer"    PermDeclines.java 's/                if \(\(pm\.getPermissionFlags\(x\[0\], pkg, me\) & answered\) != 0\) continue;\n//' || fails=$((fails+1))
mut "X9d unanswered ignores USER_FIXED"              PermDeclines.java 's/FLAG_PERMISSION_USER_SET\n                \| android\.content\.pm\.PackageManager\.FLAG_PERMISSION_USER_FIXED;/FLAG_PERMISSION_USER_SET;/' || fails=$((fails+1))
mut "X12 in session only today's candidates (no X after a switch)" PermDeclines.java 's/        if \(!inSession && !smsCandidates\(/        if (!smsCandidates(/' || fails=$((fails+1))
mut "X13 the sign-in step declines any app"          PermDeclines.java 's/        if \(!inSession && !smsCandidates\(recordedSmsApp\(ctx\), ctx\.getPackageName\(\), SmsRoleRoam\.MESSAGING\)\.contains\(pkg\)\) return;\n//' || fails=$((fails+1))
mut "X9b unanswered keeps one it could not read"     PermDeclines.java 's/                fails\.add\(t\);\n            \}\n        \}\n        if \(fails\.n > 0\)/                fails.add(t);\n                out.add(x);\n            }\n        }\n        if (fails.n > 0)/' || fails=$((fails+1))
mut "X10 retryRefused leaves Messaging the six"      SmsRoleRoam.java  's/                    PermDeclines\.declineSmsRoleIfNotHolder\(ctx, MESSAGING, null, true, "sms role taken over"\);\n//' || fails=$((fails+1))
mut "X11 the sign-in step stops revoking"            PermDeclines.java 's/declineSmsRoleIfNotHolder\(ctx, c, sms, false, why\);/declineSmsRoleIfNotHolder(ctx, c, sms, true, why);/' || fails=$((fails+1))
mut "X5c carriedDecline looks up perm as the pkg (M8)" PermDeclines.java 's/        String old = oldDeclineWord\(oldLines, pkg, perm\);/        String old = oldDeclineWord(oldLines, perm, perm);/' || fails=$((fails+1))
mut "B16 oldDeclineWord looks up perm as the pkg"    PermDeclines.java 's/String prefix = pkg \+ " flags:", suffix/String prefix = perm + " flags:", suffix/' || fails=$((fails+1))
mut "K3 the carry's lookup is SMS-only again"        PermDeclines.java 's/        String old = oldDeclineWord\(oldLines, pkg, perm\);/        String old = smsRolePerm(perm) ? oldDeclineWord(oldLines, pkg, perm) : null;/' || fails=$((fails+1))
mut "K4 the carry records a not-dangerous permission" PermDeclines.java 's/(        if \(old == null\) return null;\n        try \{\n)            if \(pm\.getPermissionInfo\(perm, 0\)\.getProtection\(\)\n                    != android\.content\.pm\.PermissionInfo\.PROTECTION_DANGEROUS\) return null;/$1            pm.getPermissionInfo(perm, 0);/' || fails=$((fails+1))
mut "K5 the carry records an undefined permission"    PermDeclines.java 's/(PackageManager\.NameNotFoundException undefined\) \{\n)            return null;(\n        \} catch \(Throwable t\) \{\n            fails\.add\(t\);\n            return old;)/$1            return old;$2/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
