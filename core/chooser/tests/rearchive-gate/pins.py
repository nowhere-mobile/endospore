#!/usr/bin/env python3
"""pins.py <repo-root> -- NWP-20261102-15 / NWP-20261120-12: source checks that the chooser's ReArchiveReceiver,
CredentialService and UnarchiveService reach ReArchiveGate and keep the idle-reclaim sweep armed. NWP-20261122-10
adds s8-s11: the sweep reads every job source once, archives nothing when one cannot be read, and passes holdsJob and
the visible and foreground-service times to ReArchiveGate.archive. NWP-20261129-14 adds s12: sweep and freeNow read
the needed Play stack once, the reader refuses an unknown nowhere-playdeps and maps only packages with code. It reads
the sources with comments dropped (string literals kept) and whitespace collapsed, prints one 'ok   <pin>' or
'FAIL <pin> ...' line per pin, and exits 1 when any pin fails. It reads the files and never writes."""
import re
import sys

CH = "core/chooser/src/com/nowhere/chooser"


def strip(src):
    """Drop // and /* */ comments outside string and char literals, then collapse whitespace."""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if c in "\"'":
            j = i + 1
            while j < n and src[j] != c:
                j += 2 if src[j] == "\\" else 1
            out.append(src[i:j + 1])
            i = j + 1
        elif src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            i = n if j < 0 else j + 2
            out.append(" ")
        else:
            out.append(c)
            i += 1
    return re.sub(r"\s+", " ", "".join(out))


def block(s, anchor):
    """The brace-matched block whose '{' is the first after anchor ('' when the anchor is absent)."""
    a = s.find(anchor)
    if a < 0:
        return ""
    o = s.find("{", a + len(anchor) - 1)
    if o < 0:
        return ""
    depth = 0
    for k in range(o, len(s)):
        if s[k] == "{":
            depth += 1
        elif s[k] == "}":
            depth -= 1
            if depth == 0:
                return s[o:k + 1]
    return ""


def before(s, first, second):
    """True iff first occurs in s and second occurs after it."""
    a = s.find(first)
    return a >= 0 and s.find(second, a + len(first)) >= 0


def main():
    root = sys.argv[1]

    def read(name):
        with open(f"{root}/{CH}/{name}", encoding="utf-8") as f:
            return strip(f.read())

    rcv, cred, unarch = read("ReArchiveReceiver.java"), read("CredentialService.java"), read("UnarchiveService.java")
    bad = 0

    def pin(name, ok, why):
        nonlocal bad
        if ok:
            print(f"ok   {name}")
        else:
            print(f"FAIL {name} -- {why}")
            bad = 1

    sweep = block(rcv, "private void sweep(")
    pin("s1 sweep decides through ReArchiveGate.archive",
        "ReArchiveGate.archive(" in sweep and not re.search(r"now *- *last", sweep),
        "sweep must call ReArchiveGate.archive and hold no now - last comparison")
    pin("s2 idleMs decides through ReArchiveGate.effectiveIdle",
        "ReArchiveGate.effectiveIdle(" in block(rcv, "static long idleMs("),
        "idleMs must call ReArchiveGate.effectiveIdle")

    arm = block(rcv, " void arm(Context ctx, long whenMs)")
    keep = re.search(r"if \(at == DUE\.get\(\)[^;{}]*\) return;", arm)
    setat = arm.find("am.setAndAllowWhileIdle(AlarmManager.RTC, at, pi);")
    pin("s3 arm keeps the pending sweep through ReArchiveGate.armAt",
        "long at = ReArchiveGate.armAt(DUE.get(), System.currentTimeMillis(), whenMs);" in arm
        and keep is not None and setat > keep.end()
        and arm.find("DUE.set(at);", setat) > setat,
        "arm must compute at = ReArchiveGate.armAt(DUE.get(), now, whenMs), return when at == DUE.get(), "
        "set the alarm at 'at', and store DUE.set(at) after the set")

    fin = block(block(rcv, "public void onReceive(Context ctx, Intent intent)"), "finally {")
    pin("s4 onReceive clears DUE before its finally re-arms",
        before(fin, "DUE.set(0L);", "arm(ctx, System.currentTimeMillis() + CHECK_MS);"),
        "onReceive's finally must call DUE.set(0L) before its arm(...)")

    ka = block(rcv, "static void keepArmed(Context ctx)")
    pin("s5 keepArmed arms only on a non-empty ondemandKeepSet",
        before(ka, "if (ProfileActivity.ondemandKeepSet(ctx).isEmpty()) return;",
               "arm(ctx, System.currentTimeMillis() + CHECK_MS);")
        and ka.count("arm(") == 1 and "catch (Throwable" in ka,
        "keepArmed must return on an empty ondemandKeepSet before its one arm(...) and catch Throwable")

    claims = block(cred, 'getBooleanExtra("claims", false)) {')
    login = block(cred, 'getBooleanExtra("claimsLogin", false)) {')
    pin("s6 the claims branch calls keepArmed and claimsLogin does not",
        before(claims, 'relayNextAlarm(this, "post-seal");', "ReArchiveReceiver.keepArmed(this);")
        and login != "" and "keepArmed" not in login,
        "the claims branch must call ReArchiveReceiver.keepArmed(this) after relayNextAlarm, "
        "and the claimsLogin branch must not call it")

    pin("s7 UnarchiveService still calls ReArchiveReceiver.arm",
        "ReArchiveReceiver.arm(this," in unarch, "UnarchiveService no longer calls ReArchiveReceiver.arm(this, ...)")

    loop = block(sweep, "for (String pkg : od)")
    rj = block(rcv, "private static String readJobs(")
    hj = loop.find("boolean job = ReArchiveGate.holdsJob(pkg, jobs[0], jobs[1], jobs[2], jobs[3], roles, needed);")
    av = loop.find("ReArchiveGate.archive(now, idle, lastUsed, lastVisible, lastFgs, lastUpdate, job)")
    ac = loop.find("archive(ctx, pkg);")
    pin("s8 sweep passes holdsJob for each package to ReArchiveGate.archive before archive(ctx, pkg)",
        0 <= hj < av < ac,
        "the loop must compute job = ReArchiveGate.holdsJob(pkg, jobs[0..3], roles, needed), pass it to "
        "ReArchiveGate.archive(now, idle, lastUsed, lastVisible, lastFgs, lastUpdate, job), then archive(ctx, pkg)")

    keys = re.search(r"JOB_KEYS = \{ ([^}]*)\}", rcv)
    roles = re.search(r"JOB_ROLES = \{ ([^}]*)\}", rcv)
    want_roles = ["RoleManager.ROLE_" + r for r in
                  ("SMS", "DIALER", "BROWSER", "HOME", "ASSISTANT", "CALL_SCREENING", "CALL_REDIRECTION", "EMERGENCY")]
    want_roles += ['"android.app.role.NOTES"', '"android.app.role.WALLET"']
    pin("s9 sweep reads the four Settings keys and the role holders",
        "String failed = readJobs(ctx, jobs, roles);" in sweep
        and "Settings.Secure.getString(cr, JOB_KEYS[i])" in rj
        and "rm.getRoleHolders(role)" in rj and 'if (rm == null) return "RoleManager";' in rj
        and keys is not None and [k.strip() for k in keys.group(1).split(",") if k.strip()] ==
        ['"default_input_method"', '"always_on_vpn_app"', '"enabled_accessibility_services"',
         '"enabled_notification_listeners"']
        and roles is not None and sorted(r.strip() for r in roles.group(1).split(",") if r.strip()) == sorted(want_roles)
        and "getRoleHoldersAsUser" not in rcv,
        "readJobs must read the four JOB_KEYS in holdsJob's order through Settings.Secure.getString, treat a null "
        "RoleManager as a failure, and read every JOB_ROLES holder through the same-user getRoleHolders")

    f = block(sweep, "if (failed != null) {")
    fo, ro, lo = sweep.find("if (failed != null) {"), sweep.find("String failed = readJobs(ctx, jobs, roles);"), \
        sweep.find("for (String pkg : od)")
    pin("s10 a failed job read returns before the loop",
        f != "" and "return;" in f and 0 <= ro < fo < lo and sweep.count("readJobs(") == 1,
        "sweep must call readJobs once, then 'if (failed != null) { ... return; }', both before the loop")

    reads = [loop.find(r) for r in ("lastUsed = s.getLastTimeUsed();", "lastVisible = s.getLastTimeVisible();",
                                    "lastFgs = s.getLastTimeForegroundServiceUsed();")]
    pin("s11 getLastTimeVisible and getLastTimeForegroundServiceUsed reach archive",
        all(0 <= r < av for r in reads),
        "the loop must read getLastTimeUsed, getLastTimeVisible and getLastTimeForegroundServiceUsed into "
        "lastUsed, lastVisible and lastFgs before ReArchiveGate.archive")

    call = "if (failed == null) failed = readPlayNeeded(ctx, needed);"
    fn = block(rcv, "static String freeNow(Context ctx, String pkg)")
    rpn = block(rcv, "private static String readPlayNeeded(")
    each = block(rpn, "for (String pkg : ProfileActivity.keepSetAll(ctx))")
    code = each.find("pm.getApplicationInfo(pkg, 0);")
    skip = each.find("catch (PackageManager.NameNotFoundException e) { continue;")
    put = each.find("deps.put(pkg, AppDeps.appDeps(pkg, groups, ProfileActivity.DEFAULT_GROUPS, deferred, playDeps,")
    pin("s12 sweep and freeNow read playNeeded once, and the reader refuses unknown and maps only code",
        sweep.count("readPlayNeeded(") == 1 and 0 <= ro < sweep.find(call) < fo
        and fn.count("readPlayNeeded(") == 1 and ", roles, needed)" in fn
        and 0 <= fn.find("readJobs(ctx, jobs, roles);") < fn.find(call) < fn.find("FreeOnPhone.verdict(failed,")
        and "Set<String> playDeps = ProfileActivity.readPlayDepsStrict(ctx); "
            'if (playDeps == null) return "nowhere-playdeps";' in rpn
        and 0 <= code < skip < put and 'return "packages";' in each
        and each != "" and rpn.find("out.addAll(ReArchiveGate.playNeeded(deps));") > rpn.find(each)
        and not re.search(r"ProfileActivity\.(appDeps|readPlayDeps|readAppGroups|deferredKeepSet)\b", each),
        "sweep and freeNow must each call readPlayNeeded once, after readJobs and before their failure check; the "
        "reader must return a failure on a null readPlayDepsStrict, read its inputs outside the loop, and map only "
        "packages whose getApplicationInfo(pkg, 0) answered")
    return bad


if __name__ == "__main__":
    sys.exit(main())
