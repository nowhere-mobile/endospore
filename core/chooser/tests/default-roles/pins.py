#!/usr/bin/env python3
"""pins.py <repo-root> -- NWP-20261202-05: source checks that the chooser's call sites reach DefaultRoleRoam, that
roamd's `in` op removes the roles marker, that DefaultRoleRoam goes through DefaultRoles' pure rules, and that no
DefaultRoleRoam log line names an app. It reads the Java sources with comments dropped (string literals kept) and
whitespace collapsed, prints one 'ok   <pin>' or 'FAIL <pin> ...' line per pin, and exits 1 when any pin fails. It
reads the files and never writes."""
import re
import sys

CH = "core/chooser/src/com/nowhere/chooser"
ROAMD = "core/vendor-common/bin/nowhere_roamd.sh"
RM = '      rm -f "$USERDIR/com.nowhere.chooser/files/nowhere-roles-applied" 2>>"$LOG"'
TRY = "try { SmsRoleRoam.applyAtSignIn(this); DefaultRoleRoam.applyAtSignIn(this); } finally { finishUnit(); }"
LOOP = "h.post(() -> { for (String r : DefaultRoles.ROLES) DefaultRoleRoam.capture(this, r); });"
LISTEN = "if (DefaultRoles.isRole(roleName)) h.post(() -> DefaultRoleRoam.capture(this, roleName));"
SMSLISTEN = "if (android.app.role.RoleManager.ROLE_SMS.equals(roleName)) h.post(() -> SmsRoleRoam.capture(this));"
# the identifiers that hold a package name in DefaultRoleRoam: none may reach a log call
NAMES = ("pkg", "want", "holder", "record", "target", "self", "v", "rec")
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


def skip_string(s, i):
    """The index just past the string or char literal that starts at i."""
    j = i + 1
    while j < len(s) and s[j] != s[i]:
        j += 2 if s[j] == "\\" else 1
    return j + 1


def log_calls(s):
    """[(argument text, top-level argument count)] of every android.util.Log.<x>( call in s."""
    out = []
    for mt in re.finditer(r"android\.util\.Log\.\w+\(", s):
        i, depth, args, start = mt.end(), 1, 1, mt.end()
        while i < len(s) and depth:
            c = s[i]
            if c in "\"'":
                i = skip_string(s, i)
                continue
            if c in "({[":
                depth += 1
            elif c in ")}]":
                depth -= 1
            elif c == "," and depth == 1:
                args += 1
            i += 1
        out.append((s[start:i - 1], args))
    return out


def no_strings(s):
    out, i = [], 0
    while i < len(s):
        if s[i] in "\"'":
            i = skip_string(s, i)
            out.append('""')
        else:
            out.append(s[i])
            i += 1
    return "".join(out)


def in_op(path):
    """roamd's `in` op (`  in)` to its first `    ;;`), comment lines dropped."""
    lines, on = [], False
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if line == "  in)":
                on = True
            if on:
                if not re.match(r"^\s*#", line):
                    lines.append(line)
                if line == "    ;;":
                    break
    return lines


def main():
    root = sys.argv[1]

    def read(name):
        """The stripped source, or "" when the file is absent (each pin on it then FAILs by name)."""
        try:
            with open(f"{root}/{CH}/{name}", encoding="utf-8") as f:
                return strip(f.read())
        except FileNotFoundError:
            return ""

    cred, sup, unarch = read("CredentialService.java"), read("MessagingSuppressor.java"), read("UnarchiveService.java")
    inst, drr = read("AppInstallReceiver.java"), read("DefaultRoleRoam.java")
    bad = 0

    def pin(name, ok, why):
        nonlocal bad
        if ok:
            print(f"ok   {name}")
        else:
            print(f"FAIL {name} -- {why}")
            bad = 1

    sms = block(cred, 'getBooleanExtra("smsrole", false)) {')
    pin("p1 the smsrole branch runs SmsRoleRoam then DefaultRoleRoam",
        TRY in sms and cred.count("DefaultRoleRoam.applyAtSignIn(") == 1,
        "the smsrole branch must hold, once: " + TRY)

    rc = block(sup, "private synchronized void startRoleCapture()")
    pin("p2 the role listener captures the default roles",
        rc.count(LOOP) == 1 and rc.count(LISTEN) == 1 and SMSLISTEN in rc and sup.count("DefaultRoleRoam.capture(") == 2,
        "startRoleCapture must post the connect-time loop once and the listener's role line once, "
        "beside the unchanged ROLE_SMS line")

    mo = block(unarch, "static void markOdRestored(android.content.Context ctx")
    pin("p3 a materialise hands a recorded role back",
        before(mo, "SmsRoleRoam.onMaterialised(ctx, pkg);", "DefaultRoleRoam.onMaterialised(ctx, pkg);")
        and unarch.count("DefaultRoleRoam.onMaterialised(") == 1,
        "markOdRestored must call DefaultRoleRoam.onMaterialised(ctx, pkg) once, after SmsRoleRoam's")

    pin("p4 an install hands a recorded role back",
        inst.count("DefaultRoleRoam.onMaterialised(") == 1
        and 'recaptureCode(context, pkg, "new"); SettingsRoamLive.reconcile(context); '
            'DefaultRoleRoam.onMaterialised(context, pkg);' in inst,
        "the ADDED arm must call DefaultRoleRoam.onMaterialised(context, pkg) once, right after "
        "SettingsRoamLive.reconcile(context)")

    op = in_op(f"{root}/{ROAMD}")
    pin("p5 roamd's in op removes the roles marker",
        op.count(RM) == 1, "the in op must hold, once and as code: " + RM.strip())

    calls = log_calls(drr)
    leaks = [a for a, _ in calls if any(re.search(r"\b" + n + r"\b", no_strings(a)) for n in NAMES)]
    three = [a for a, n in calls if n > 2]
    pin("p6 no DefaultRoleRoam log line names a package",
        len(calls) > 0 and not leaks and not three,
        f"{len(calls)} log call(s); naming a package: {leaks[:1]}; with a Throwable argument: {three[:1]}")

    sign = block(drr, "static void applyAtSignIn(Context ctx)")
    ru, mk = sign.find("DefaultRoles.recordUnknown("), sign.find("markerText(")
    pin("p7 the sign-in apply is gated",
        0 <= ru < mk and sign.find("return;", ru) < mk and sign.find("return;", ru) >= 0
        and "isRoleAvailable(" in sign and "exceptSmsRole" not in drr,
        "applyAtSignIn must call DefaultRoles.recordUnknown and return before markerText, ask isRoleAvailable, "
        "and DefaultRoleRoam must never call exceptSmsRole")

    cap = block(drr, "static void capture(Context ctx, String role)")
    mat = block(drr, "static void onMaterialised(Context ctx, String pkg)")
    eh = block(drr, "static String ensureHolder(")
    loop = block(eh, "for (int attempt = 1; attempt <= 4; attempt++)")
    pin("p8 capture and take-back go through the pure rules",
        "DefaultRoles.captureStep(" in cap and "DefaultRoles.materialiseTarget(" in mat and "new Thread(" in mat
        and "DefaultRoles.takeoverStep(" in loop and "DefaultRoles.signInStep(" in loop
        and "PermDeclines.snapshot(" in loop and "PermDeclines.apply(" in loop,
        "capture must call captureStep, onMaterialised materialiseTarget on its own thread, and ensureHolder's "
        "attempt loop takeoverStep, signInStep, PermDeclines.snapshot and PermDeclines.apply")

    rfc, nul = cap.find("DefaultRoles.recordForCapture("), cap.find("if (rec == null) {")
    wr = cap.find("write(ctx, DefaultRoles.RECORD")
    pin("p9 capture writes nothing while the record cannot be read",
        0 <= rfc < nul < wr and 0 <= cap.find("return;", nul) < wr and "DefaultRoles.parseRecord(" not in cap,
        "capture must read the record through DefaultRoles.recordForCapture and return on null before it writes "
        "the record, and must never parse the record directly")

    return bad


if __name__ == "__main__":
    sys.exit(main())
