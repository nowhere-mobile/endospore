#!/usr/bin/env bash
# test-app-code-line-java.sh [--mutate] -- one package's line of files/nowhere-appcode.list is rebuilt in a session
# when a kept app is installed or updated, by the same builder the sign-out uses (NWP-20261119-10).
#
# WHY THIS IS COMMITTED. Backlog row "A periodic seal's `#apps` staging spends two to three minutes staging nothing:
# ...": ProfileActivity.captureAppCode was the only writer of the code list and ran only at sign-out. A kept
# On-demand app materialised after a sign-in, or updated by Play, moves to a new /data/app/~~rand~~ dir, so every
# list path was dead until the next sign-out and every periodic seal staged nothing for it. Since this slice
# AppInstallReceiver.recaptureCode rewrites that one line on ACTION_PACKAGE_ADDED (a new install) and
# ACTION_PACKAGE_REPLACED (an update), in a roamed session only, under the lock captureAppCode also holds.
#
# WHAT RUNS. AppCodeLine.java (pure java.*) is compiled ALONE with javac and AppCodeLineCases (below) runs over it:
# build's column order, splits and group token; replaceIn's whole-field match, append and byte-for-byte copy of every
# other line; lineOf and groupOf. The receiver, NowhereApp and ProfileActivity need Android and cannot be compiled
# here, so their wiring is PINNED in source: the REPLACED action in the AppInstallReceiver filter (not the push-doze
# filter), the user-0 guard before the write, the meta capture before the write, one whole-content read, the shared
# lock in both writers, the keep-set mode passed to build, and captureAppCode building its lines through
# AppCodeLine.build. NWP-20261123-12: oldLinesByPkg's cases (null stays null, unknown), and captureAppCode's strict
# reads pinned in source: one readAppModesStrictIn of the keep-set and SettingsText.read of the old list, where a null
# from either returns before any delete, write or rmTree.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (exit 2), like the other javac suites.
#
#   bash test-app-code-line-java.sh            # the cases and the pins
#   bash test-app-code-line-java.sh --mutate   # ... plus broken copies that must each FAIL them
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/src/com/nowhere/chooser"
ALC="${ALC:-$SRC/AppCodeLine.java}"
AIR="${AIR:-$SRC/AppInstallReceiver.java}"
NAPP="${NAPP:-$SRC/NowhereApp.java}"
PA="${PA:-$SRC/ProfileActivity.java}"
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
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
"$JAVAC" -version >/dev/null 2>&1 || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
[ -f "$AIR" ] && [ -f "$NAPP" ] && [ -f "$PA" ] || { echo "FAIL: missing $AIR, $NAPP or $PA" >&2; exit 2; }

# The one temp root: every class dir and every mutant live inside it, and the EXIT trap removes it on every path.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok    $1"; }
no(){ FAIL=$((FAIL+1)); echo "  FAIL  $1"; }

# ⚠ Every match reads its input to the end (a here-string or a count, never `cmd | grep -q`).
# body <file> <fixed signature text>: from the line holding the signature to the brace that closes it. Empty when the
# signature is absent or its braces do not balance. The members it reads hold no brace in a literal or a comment.
body(){ SIG="$2" awk '
  BEGIN { sig = ENVIRON["SIG"]; on = 0; d = 0 }
  !on && index($0, sig) { on = 1 }
  on {
    print
    n = length($0)
    for (i = 1; i <= n; i++) { c = substr($0, i, 1); if (c == "{") d++; else if (c == "}") { d--; if (d == 0) exit } }
  }' "$1"; }
# count <text> <fixed string>: how many lines of text hold the string.
count(){ local n; n=$(grep -cF -- "$2" <<<"$1"); echo "${n:-0}"; }
# lineno <text> <fixed string>: the first line of text holding the string, 0 when none.
lineno(){ local n; n=$(grep -nF -- "$2" <<<"$1" | head -n1 | cut -d: -f1); echo "${n:-0}"; }

echo "== AppCodeLine under javac =="
CASES='package com.nowhere.chooser;

public class AppCodeLineCases {
    static int fails = 0;
    static void check(String name, boolean c) { System.out.println((c ? "  ok    " : "  FAIL  ") + name); if (!c) fails++; }
    static void eq(String name, String got, String want) {
        boolean c = want == null ? got == null : want.equals(got);
        check(name + (c ? "" : " -- got [" + esc(got) + "] want [" + esc(want) + "]"), c);
    }
    static String esc(String s) { return s == null ? "null" : s.replace("\t", "\\t").replace("\n", "\\n").replace("\r", "\\r"); }

    public static void main(String[] a) {
        // B1: the column order, with one split and a group token.
        eq("B1 build: pkg vc sideloaded mode base splits group, in that order",
           AppCodeLine.build("com.x", 42, true, "ondemand", "/data/app/~~r/com.x-1/base.apk",
                             new String[]{"/s/a.apk"}, "sandboxed-play"),
           "com.x\t42\t1\tondemand\t/data/app/~~r/com.x-1/base.apk\t/s/a.apk\tgroup:sandboxed-play");
        eq("B1b build: an auto line keeps its mode",
           AppCodeLine.build("com.y", 7, false, "auto", "/b.apk", null, null), "com.y\t7\t0\tauto\t/b.apk");
        // B2: an empty split list, null or empty array: no trailing tab.
        eq("B2 build: no splits (empty array)", AppCodeLine.build("com.x", 1, false, "installed", "/b.apk", new String[0], null),
           "com.x\t1\t0\tinstalled\t/b.apk");
        eq("B2 build: no splits (null)", AppCodeLine.build("com.x", 1, false, "installed", "/b.apk", null, ""),
           "com.x\t1\t0\tinstalled\t/b.apk");
        // B3: a split list of 3, a null and an empty entry mixed in.
        eq("B3 build: three splits in order, null and empty skipped",
           AppCodeLine.build("com.x", 9, false, "installed", "/b.apk",
                             new String[]{"/s1.apk", null, "/s2.apk", "", "/s3.apk"}, null),
           "com.x\t9\t0\tinstalled\t/b.apk\t/s1.apk\t/s2.apk\t/s3.apk");
        // B4: a null or empty group writes no token; a group follows the last split.
        eq("B4 build: the group token is last, after every split",
           AppCodeLine.build("com.x", 9, false, "auto", "/b.apk", new String[]{"/s1.apk", "/s2.apk"}, "g"),
           "com.x\t9\t0\tauto\t/b.apk\t/s1.apk\t/s2.apk\tgroup:g");

        String la = "com.a\t1\t0\tondemand\t/old/a/base.apk\tgroup:ga";
        String lab = "com.ab\t2\t0\tinstalled\t/old/ab/base.apk";
        String lacb = "com.a.b\t3\t1\tauto\t/old/acb/base.apk";
        String text = la + "\n" + lab + "\n" + lacb + "\n";
        String na = "com.a\t5\t0\tondemand\t/new/a/base.apk\tgroup:ga";
        String nab = "com.ab\t6\t0\tinstalled\t/new/ab/base.apk";
        // R1: whole-field match: com.a never takes com.ab or com.a.b.
        eq("R1 replaceIn com.a: only the com.a line changes", AppCodeLine.replaceIn(text, "com.a", na),
           na + "\n" + lab + "\n" + lacb + "\n");
        eq("R1 replaceIn com.ab: only the com.ab line changes", AppCodeLine.replaceIn(text, "com.ab", nab),
           la + "\n" + nab + "\n" + lacb + "\n");
        String prefixFirst = lab + "\n" + la + "\n";
        eq("R1 replaceIn com.a after a com.ab line: com.ab is not taken", AppCodeLine.replaceIn(prefixFirst, "com.a", na),
           lab + "\n" + na + "\n");
        eq("R1 replaceIn com.a over only com.ab: appended, com.ab kept",
           AppCodeLine.replaceIn(lab + "\n", "com.a", na), lab + "\n" + na + "\n");
        // R2: append when absent.
        String nz = "com.z\t1\t0\tinstalled\t/z.apk";
        eq("R2 replaceIn: an absent package is appended", AppCodeLine.replaceIn(text, "com.z", nz), text + nz + "\n");
        // R3: a last line with no newline stays intact.
        String unterm = la + "\n" + lab;
        eq("R3 replaceIn: append after an unterminated last line keeps it whole",
           AppCodeLine.replaceIn(unterm, "com.z", nz), la + "\n" + lab + "\n" + nz + "\n");
        eq("R3 replaceIn: replacing a middle line keeps the unterminated last line byte for byte",
           AppCodeLine.replaceIn(la + "\n" + lab + "\n" + lacb, "com.ab", nab), la + "\n" + nab + "\n" + lacb);
        eq("R3 replaceIn: replacing the unterminated last line leaves it unterminated",
           AppCodeLine.replaceIn(unterm, "com.ab", nab), la + "\n" + nab);
        // R4: every other line byte for byte, in order: trailing spaces, an empty line, a CR, a leading space.
        String odd = "com.q\t1\t0\tinstalled\t/q.apk  \n\n com.lead\t1\t0\tinstalled\t/l.apk\n"
                   + "com.cr\t1\t0\tinstalled\t/cr.apk\r\n" + la + "\n" + "com.tail\t1\t0\tauto\t/t.apk \t\n";
        String oddWant = "com.q\t1\t0\tinstalled\t/q.apk  \n\n com.lead\t1\t0\tinstalled\t/l.apk\n"
                   + "com.cr\t1\t0\tinstalled\t/cr.apk\r\n" + na + "\n" + "com.tail\t1\t0\tauto\t/t.apk \t\n";
        eq("R4 replaceIn: every other line is copied byte for byte, in order", AppCodeLine.replaceIn(odd, "com.a", na), oddWant);
        eq("R4 replaceIn: an append copies every other line byte for byte", AppCodeLine.replaceIn(odd, "com.z", nz), odd + nz + "\n");
        // R5: a later duplicate goes; the first becomes the new line.
        eq("R5 replaceIn: a later duplicate of the package is removed",
           AppCodeLine.replaceIn(la + "\n" + lab + "\n" + la + "\n", "com.a", na), na + "\n" + lab + "\n");
        // R6: an empty text.
        eq("R6 replaceIn: an empty text gets the line and a newline", AppCodeLine.replaceIn("", "com.z", nz), nz + "\n");
        // G1: groupOf.
        eq("G1 groupOf: the trailing token", AppCodeLine.groupOf(la), "ga");
        eq("G1 groupOf: no token", AppCodeLine.groupOf(lab), null);
        eq("G1 groupOf: a null line", AppCodeLine.groupOf(null), null);
        eq("G1 groupOf: an empty name", AppCodeLine.groupOf("com.x\t1\t0\tauto\t/b.apk\tgroup:"), null);
        // L1: lineOf, whole-field.
        eq("L1 lineOf com.a: not the com.ab line", AppCodeLine.lineOf(prefixFirst, "com.a"), la);
        eq("L1 lineOf: null when absent", AppCodeLine.lineOf(lab + "\n", "com.a"), null);
        eq("L1 lineOf: an unterminated last line", AppCodeLine.lineOf(unterm, "com.ab"), lab);
        // O1-O5: oldLinesByPkg, the old list keyed by field 1 (NWP-20261123-12).
        check("O1 oldLinesByPkg: null (unreadable) is null, never empty", AppCodeLine.oldLinesByPkg(null) == null);
        java.util.Map<String,String> o0 = AppCodeLine.oldLinesByPkg("");
        check("O2 oldLinesByPkg: an empty text is an empty map", o0 != null && o0.isEmpty());
        java.util.Map<String,String> o2 = AppCodeLine.oldLinesByPkg(la + "\n" + lab + "\n");
        check("O3 oldLinesByPkg: two packages, two entries", o2 != null && o2.size() == 2);
        eq("O3 oldLinesByPkg: com.a keys its whole line", o2 == null ? null : o2.get("com.a"), la);
        eq("O3 oldLinesByPkg: com.ab keys its whole line", o2 == null ? null : o2.get("com.ab"), lab);
        java.util.Map<String,String> os = AppCodeLine.oldLinesByPkg("notab\n\tcom.lead\t1\n" + la + "\n");
        check("O4 oldLinesByPkg: a line with no tab and a line starting with a tab are skipped",
              os != null && os.size() == 1 && la.equals(os.get("com.a")));
        java.util.Map<String,String> od = AppCodeLine.oldLinesByPkg(la + "\n" + na + "\n");
        eq("O5 oldLinesByPkg: a repeated package keeps the last line", od == null ? null : od.get("com.a"), na);
        System.out.println(fails == 0 ? "cases: all passed" : "cases: " + fails + " failed");
        System.exit(fails == 0 ? 0 : 1);
    }
}'
run_cases(){  # <AppCodeLine.java>: compile it ALONE with the cases and run them; prints the case lines.
  local d out rc
  d=$(mktemp -d -p "$W") || exit 2
  mkdir -p "$d/src/com/nowhere/chooser" "$d/classes" || exit 2
  cp -- "$1" "$d/src/com/nowhere/chooser/AppCodeLine.java" || exit 2
  printf '%s\n' "$CASES" > "$d/src/com/nowhere/chooser/AppCodeLineCases.java" || exit 2
  out=$("$JAVAC" -J-Djava.io.tmpdir="$W" -d "$d/classes" "$d/src/com/nowhere/chooser/AppCodeLine.java" \
        "$d/src/com/nowhere/chooser/AppCodeLineCases.java" 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then printf '%s\n' "$out"; echo "  FAIL  cases: AppCodeLine.java does not compile alone"; return 1; fi
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d/classes" com.nowhere.chooser.AppCodeLineCases
}
if [ -f "$ALC" ]; then
  out=$(run_cases "$ALC"); rc=$?
  printf '%s\n' "$out"
  n=$(grep -c '^  ok    ' <<<"$out"); PASS=$((PASS+${n:-0}))
  n=$(grep -c '^  FAIL  ' <<<"$out"); FAIL=$((FAIL+${n:-0}))
  [ "$rc" -eq 0 ] || [ "${n:-0}" -gt 0 ] || no "cases: the case run failed (rc=$rc)"
else
  no "cases: no AppCodeLine.java at $ALC"
fi

echo "== AppCodeLine: the shared lock =="
if [ -f "$ALC" ] && [ "$(count "$(cat -- "$ALC")" 'static final Object LOCK = new Object();')" -eq 1 ]; then
  ok "P0 AppCodeLine declares the one static LOCK"
else
  no "P0 AppCodeLine declares no static final Object LOCK"
fi

echo "== NowhereApp: the AppInstallReceiver filter carries ACTION_PACKAGE_REPLACED =="
fblk=$(awk '
  index($0, "android.content.IntentFilter f = new android.content.IntentFilter(") { on = 1 }
  on { print }
  on && index($0, "registerReceiver(new AppInstallReceiver(), f") { exit }' "$NAPP")
if [ -z "$fblk" ] || [ "$(count "$fblk" 'registerReceiver(new AppInstallReceiver(), f')" -ne 1 ] \
   || [ "$(count "$fblk" 'android.content.Intent.ACTION_PACKAGE_ADDED);')" -ne 1 ]; then
  no "P1 the AppInstallReceiver filter block is not found in NowhereApp"
elif [ "$(count "$fblk" 'f.addAction(android.content.Intent.ACTION_PACKAGE_REPLACED);')" -eq 1 ]; then
  ok "P1 the AppInstallReceiver filter adds ACTION_PACKAGE_REPLACED"
else
  no "P1 the AppInstallReceiver filter does not add ACTION_PACKAGE_REPLACED"
fi

echo "== AppInstallReceiver: recaptureCode and its dispatch =="
air=$(cat -- "$AIR")
rc_body=$(body "$AIR" 'private static void recaptureCode(Context ctx, String pkg, String via) {')
if [ -z "$rc_body" ]; then
  no "P2 AppInstallReceiver has no recaptureCode(Context, String, String)"
else
  g=$(lineno "$rc_body" 'if (android.os.UserHandle.myUserId() == 0) return;')
  rp=$(lineno "$rc_body" 'AppCodeLine.replaceIn(')
  if [ "$(count "$air" 'AppCodeLine.replaceIn(')" -eq 1 ] && [ "$rp" -gt 0 ] && [ "$g" -gt 0 ] && [ "$g" -lt "$rp" ]; then
    ok "P2 AppCodeLine.replaceIn is reached only in recaptureCode, behind the user-0 guard"
  else
    no "P2 AppCodeLine.replaceIn is not behind 'if (android.os.UserHandle.myUserId() == 0) return;' in recaptureCode only"
  fi
  lk=$(lineno "$rc_body" 'synchronized (AppCodeLine.LOCK) {')
  mt=$(lineno "$rc_body" 'if (ProfileActivity.deferredMode(mode)) ProfileActivity.captureArchivedMeta(ctx, pm, pkg, vc);')
  wa=$(lineno "$rc_body" 'StoreInstaller.writeAtomic(out, AppCodeLine.replaceIn(text, pkg, line));')
  if [ "$lk" -gt 0 ] && [ "$mt" -gt "$lk" ] && [ "$wa" -gt "$mt" ]; then
    ok "P3 under AppCodeLine.LOCK, a deferred mode re-captures its meta before the line is written"
  else
    no "P3 the lock, the deferred meta capture and the write are not in that order (lock=$lk meta=$mt write=$wa)"
  fi
  md=$(lineno "$rc_body" 'String mode = ProfileActivity.readAppModesIn(ctx.getFilesDir()).get(pkg);')
  bd=$(lineno "$rc_body" 'ProfileActivity.isSideloaded(pm, pkg), mode,')
  if [ "$md" -gt 0 ] && [ "$bd" -gt "$md" ] && [ "$(count "$rc_body" 'MODE_INSTALLED')" -eq 0 ] \
     && [ "$(count "$rc_body" 'if (mode == null) return;')" -eq 1 ]; then
    ok "P4 build takes the keep-set mode, and a package not kept writes nothing"
  else
    no "P4 build does not take the keep-set mode as read (mode=$md build=$bd)"
  fi
  rd=$(count "$rc_body" 'String text = new String(java.nio.file.Files.readAllBytes(out.toPath()), java.nio.charset.StandardCharsets.UTF_8);')
  if [ "$rd" -eq 1 ] && [ "$(count "$rc_body" 'readLine(')" -eq 0 ] && [ "$(count "$rc_body" 'BufferedReader')" -eq 0 ] \
     && [ "$(count "$rc_body" 'FileReader')" -eq 0 ]; then
    ok "P7 the list is read whole, as bytes, never line by line"
  else
    no "P7 recaptureCode does not read the list as one whole-content read"
  fi
  if [ "$(count "$rc_body" 'if (!out.isFile()) return;')" -eq 1 ] && [ "$(count "$rc_body" 'StoreInstaller.writeAtomic(')" -eq 1 ] \
     && [ "$(count "$rc_body" 'removeKeepLines')" -eq 0 ] && [ "$(count "$rc_body" 'recordTurnedOff')" -eq 0 ]; then
    ok "P8 a missing list writes nothing, and the one write is the list: no prune, no drop record"
  else
    no "P8 recaptureCode writes without a list, writes twice, or prunes"
  fi
fi
rp_blk=$(awk 'index($0, "if (Intent.ACTION_PACKAGE_REPLACED.equals(intent.getAction())) {") { on = 1 } on { print } on && /^ *}$/ { exit }' "$AIR")
add_at=$(lineno "$air" 'SmsRoleRoam.onMaterialised(context, pkg);')
new_at=$(lineno "$air" 'if (!replacing) recaptureCode(context, pkg, "new");')
if [ "$(count "$rp_blk" 'recaptureCode(context, up, "update");')" -eq 1 ] && [ "$add_at" -gt 0 ] && [ "$new_at" -eq $((add_at+1)) ]; then
  ok "P5 REPLACED re-captures the update; a new ADDED re-captures after decide, heal and the SMS role"
else
  no "P5 the dispatch is not REPLACED -> recaptureCode(update) and ADDED(!replacing) -> recaptureCode(new)"
fi

echo "== ProfileActivity: captureAppCode builds its lines through AppCodeLine.build, under the same lock =="
cac=$(body "$PA" 'private void captureAppCode() {')
if [ -n "$cac" ] && [ "$(count "$cac" 'synchronized (AppCodeLine.LOCK) {')" -eq 1 ] \
   && [ "$(lineno "$cac" 'synchronized (AppCodeLine.LOCK) {')" -le 5 ] \
   && [ "$(count "$cac" 'sb.append(AppCodeLine.build(pkg, vc, isSideloaded(pm, pkg), mode, ai.sourceDir, ai.splitSourceDirs,')" -eq 1 ] \
   && [ "$(count "$cac" "sb.append(pkg).append('\\t')")" -eq 0 ]; then
  ok "P6 captureAppCode holds AppCodeLine.LOCK and builds each line with AppCodeLine.build"
else
  no "P6 captureAppCode does not hold AppCodeLine.LOCK around its body, or builds its lines by hand"
fi
if [ "$(count "$(cat -- "$PA")" '    static void captureArchivedMeta(android.content.Context ctx, android.content.pm.PackageManager pm, String pkg, long vc) {')" -eq 1 ]; then
  ok "P6b captureArchivedMeta is static and takes the Context"
else
  no "P6b captureArchivedMeta is not static void captureArchivedMeta(Context, PackageManager, String, long)"
fi

echo "== ProfileActivity: captureAppCode reads its keep-set and its old list strictly (NWP-20261123-12) =="
# cc: the method with its // comments cut (no string literal in it holds //). at <text> <n>: line n, blanks removed.
cc=$(sed 's#//.*$##' <<<"$cac")
at(){ local s; s=$(sed -n "${2}p" <<<"$1"); echo "${s//[[:space:]]/}"; }
kr=$(lineno "$cc" 'java.util.Map<String,String> km = readAppModesStrictIn(getFilesDir());')
if [ -n "$cac" ] && [ "$(count "$cc" 'java.util.Map<String,String> km = readAppModesStrictIn(getFilesDir());')" -eq 1 ] \
   && [ "$(count "$cc" 'allow.addAll(km.keySet());')" -eq 1 ] && [ "$(count "$cc" 'allow.addAll(readAppKeep())')" -eq 0 ]; then
  ok "P9 the keep-set is read once, strictly, and the opt-in set comes from that read"
else
  no "P9 captureAppCode does not read the keep-set once with readAppModesStrictIn(getFilesDir()), or still adds readAppKeep()"
fi
kn=$(lineno "$cc" 'if (km == null) {')
ka=$(lineno "$cc" 'if (!all) {'); kd=$(lineno "$cc" 'out.delete()'); kw=$(lineno "$cc" 'StoreInstaller.writeAtomic(')
kt=$(lineno "$cc" 'rmTree(')
if [ "$kr" -gt 0 ] && [ "$kn" -gt "$kr" ] && [ "$ka" -gt 0 ] && [ "$kd" -gt 0 ] && [ "$kw" -gt 0 ] && [ "$kt" -gt 0 ] \
   && [ "$(count "$(sed -n "$((kn+1))p" <<<"$cc")" 'nowhere-appkeep unreadable -- code list left as restored (NWP-20261123-12)')" -eq 1 ] \
   && [ "$(at "$cc" $((kn+2)))" = 'return;' ] \
   && [ "$kn" -lt "$ka" ] && [ "$kn" -lt "$kd" ] && [ "$kn" -lt "$kw" ] && [ "$kn" -lt "$kt" ]; then
  ok "P10 a null keep-set logs one line and returns before the all path, out.delete(), writeAtomic( and rmTree("
else
  no "P10 a null keep-set does not return first (read=$kr null=$kn all=$ka delete=$kd write=$kw rmTree=$kt)"
fi
orl=$(lineno "$cc" 'java.util.Map<String,String> oldCodeByPkg = AppCodeLine.oldLinesByPkg(SettingsText.read(out));')
on=$(lineno "$cc" 'if (oldCodeByPkg == null) {'); lp=$(lineno "$cc" 'for (String pkg : pkgs) {')
if [ "$(count "$cc" 'java.util.Map<String,String> oldCodeByPkg = AppCodeLine.oldLinesByPkg(SettingsText.read(out));')" -eq 1 ] \
   && [ "$(count "$cc" 'new java.io.FileReader(out)')" -eq 0 ] \
   && [ "$orl" -gt 0 ] && [ "$on" -gt "$orl" ] && [ "$lp" -gt 0 ] && [ "$kw" -gt 0 ] && [ "$kt" -gt 0 ] \
   && [ "$(count "$(sed -n "$((on+1))p" <<<"$cc")" 'nowhere-appcode.list unreadable -- left as restored, meta untouched (NWP-20261123-12)')" -eq 1 ] \
   && [ "$(at "$cc" $((on+2)))" = 'return;' ] \
   && [ "$on" -lt "$lp" ] && [ "$on" -lt "$kw" ] && [ "$on" -lt "$kt" ]; then
  ok "P11 the old list is read through SettingsText.read and oldLinesByPkg, and a null map returns before the capture loop"
else
  no "P11 a null old list does not return before the capture loop (read=$orl null=$on loop=$lp write=$kw rmTree=$kt)"
fi
if [ "$(count "$cc" 'readAppModes()')" -eq 0 ] \
   && [ "$(count "$cc" 'for (java.util.Map.Entry<String, String> e : km.entrySet()) {')" -eq 1 ]; then
  ok "P12 the carry-forward walks the one keep-set read, never readAppModes() again"
else
  no "P12 the carry-forward does not walk km.entrySet(), or captureAppCode still calls readAppModes()"
fi
if [ -f "$ALC" ] && [ "$(count "$(cat -- "$ALC")" 'static java.util.Map<String,String> oldLinesByPkg(String text) {')" -eq 1 ]; then
  ok "P13 AppCodeLine declares static Map<String,String> oldLinesByPkg(String)"
else
  no "P13 AppCodeLine has no static java.util.Map<String,String> oldLinesByPkg(String text)"
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
[ "$MUTATE" = yes ] || exit 0

PY=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c "pass" >/dev/null 2>&1; then PY=$c; break; fi
done
[ -n "$PY" ] || { echo "FAIL: --mutate needs python" >&2; exit 2; }

echo "== mutations (each MUST be convicted) =="
MPASS=0; MFAIL=0
# mutant <label> <ALC|AIR|NAPP|PA> <python statements calling r(old, new)>: r needs EXACTLY one match, or the mutant
# failed to apply, which is a failure, never a pass.
mutant(){
  local label="$1" var="$2" py="$3" src out o rc
  src="${!var}"
  out=$(mktemp -p "$W" mut.XXXXXX.java) || exit 2
  "$PY" -c '
import sys
s = open(sys.argv[1], encoding="utf-8").read()
def r(old, new):
    global s
    if s.count(old) != 1: sys.exit(3)
    s = s.replace(old, new)
exec(sys.argv[3])
open(sys.argv[2], "w", encoding="utf-8").write(s)' "$src" "$out" "$py" || { MFAIL=$((MFAIL+1)); echo "  FAIL  MUTANT DID NOT APPLY: $label"; return; }
  if cmp -s "$src" "$out"; then MFAIL=$((MFAIL+1)); echo "  FAIL  MUTANT INERT: $label"; return; fi
  o=$(env "$var=$out" bash "$0" 2>&1); rc=$?
  if [ "$rc" -eq 1 ] && grep -qE '^  FAIL  ' <<<"$o"; then
    MPASS=$((MPASS+1)); echo "  ok    convicted: $label -- $(grep -E '^  FAIL  ' <<<"$o" | head -n1 | sed 's/^  FAIL  //')"
  else
    MFAIL=$((MFAIL+1)); echo "  FAIL  NOT CONVICTED: $label (rc=$rc)"
  fi
}
mutant "M1a prefix match in replaceIn" ALC 'r("if (field1(text.substring(i, end)).equals(pkg)) {", "if (field1(text.substring(i, end)).startsWith(pkg)) {")'
mutant "M1b prefix match in lineOf" ALC 'r("if (field1(ln).equals(pkg)) return ln;", "if (ln.startsWith(pkg)) return ln;")'
mutant "M2 the group token dropped" ALC 'r("if (group != null && !group.isEmpty()) sb.append(\x27\\t\x27).append(\"group:\").append(group);", "")'
mutant "M3a replaceIn trims every other line" ALC 'r("sb.append(text, i, next);", "sb.append(text.substring(i, end).trim()).append(text, end, next);")'
mutant "M3b replaceIn puts an appended line first" ALC 'r("sb.append(line).append(\x27\\n\x27);\n        }\n        return sb.toString();", "sb.insert(0, line + \"\\n\");\n        }\n        return sb.toString();")'
mutant "M3c replaceIn drops an unterminated last line" ALC 'r("int next = nl < 0 ? n : nl + 1;", "int next = nl < 0 ? n : nl + 1;\n            if (nl < 0) break;")'
mutant "M4a build writes installed for every mode" ALC 'r("sb.append(\x27\\t\x27).append(mode);", "sb.append(\x27\\t\x27).append(\"installed\");")'
mutant "M4b the receiver overwrites the mode with installed" AIR 'r("ProfileActivity.isSideloaded(pm, pkg), mode,", "ProfileActivity.isSideloaded(pm, pkg), ProfileActivity.MODE_INSTALLED,")'
mutant "M5 the user-0 guard removed" AIR 'r("            if (android.os.UserHandle.myUserId() == 0) return;\n", "")'
mutant "M6 REPLACED dropped from the AppInstallReceiver filter" NAPP 'r("            f.addAction(android.content.Intent.ACTION_PACKAGE_REPLACED);\n", "")'
mutant "M7 the meta captured after the write" AIR '
m = "                if (ProfileActivity.deferredMode(mode)) ProfileActivity.captureArchivedMeta(ctx, pm, pkg, vc);\n"
w = "                StoreInstaller.writeAtomic(out, AppCodeLine.replaceIn(text, pkg, line));\n"
r(m, "")
r(w, w + m)'
mutant "M8 the list read line by line and joined" AIR 'r("String text = new String(java.nio.file.Files.readAllBytes(out.toPath()), java.nio.charset.StandardCharsets.UTF_8);", "StringBuilder jb = new StringBuilder(); try (java.io.BufferedReader br = new java.io.BufferedReader(new java.io.FileReader(out))) { String ln; while ((ln = br.readLine()) != null) jb.append(ln).append(\x27\\n\x27); } String text = jb.toString();")'
mutant "M9 the receiver takes no lock" AIR 'r("            synchronized (AppCodeLine.LOCK) {\n", "            {\n")'
mutant "M10 captureAppCode takes no lock" PA 'r("        synchronized (AppCodeLine.LOCK) {\n            // Prune the keep-set BEFORE", "        {\n            // Prune the keep-set BEFORE")'
mutant "M11 captureAppCode builds its line by hand" PA 'r("sb.append(AppCodeLine.build(pkg, vc, isSideloaded(pm, pkg), mode, ai.sourceDir, ai.splitSourceDirs,\n                                groupFor(this, pkg))).append(\x27\\n\x27);", "sb.append(pkg).append(\x27\\t\x27).append(AppCodeLine.build(\"\", vc, isSideloaded(pm, pkg), mode, ai.sourceDir, ai.splitSourceDirs,\n                                groupFor(this, pkg)).substring(1)).append(\x27\\n\x27);")'
mutant "M12 a new install is not re-captured" AIR 'r("                if (!replacing) recaptureCode(context, pkg, \"new\"); // NWP-20261119-10: REPLACED covers an update\n", "")'
mutant "M13 an update is not re-captured" AIR 'r("                    recaptureCode(context, up, \"update\");\n", "")'
mutant "M14 a missing list is created" AIR 'r("                if (!out.isFile()) return;\n", "")'
mutant "M15 oldLinesByPkg reads null as empty" ALC 'r("if (text == null) return null;", "if (text == null) return new java.util.HashMap<>();")'
mutant "M16 the keep-set null check removed" PA 'r("                if (km == null) {\n                    android.util.Log.w(\"NowhereChooser\", \"nowhere-appkeep unreadable -- code list left as restored (NWP-20261123-12)\");\n                    return;\n                }\n", "")'
mutant "M17 the code-list null check removed" PA 'r("                if (oldCodeByPkg == null) {\n                    android.util.Log.w(\"NowhereChooser\", \"nowhere-appcode.list unreadable -- left as restored, meta untouched (NWP-20261123-12)\");\n                    return;\n                }\n", "")'
mutant "M18 the lenient keep-set read restored" PA 'r("allow.addAll(km.keySet());", "allow.addAll(readAppKeep());")'
mutant "M19 the carry-forward reads the keep-set again" PA 'r("e : km.entrySet()) {", "e : readAppModes().entrySet()) {")'
echo "$MPASS convicted, $MFAIL failed"
[ "$MFAIL" -eq 0 ] && [ "$MPASS" -eq 23 ] || exit 1
exit 0
