#!/usr/bin/env python3
"""pins.py <repo-root> -- NWP-20261125-11 (h51 #4 B2): source checks that the chooser's "What's using your space" row
offers Free on this phone through FreeOnPhone.offer, that ReArchiveReceiver.freeNow archives only under an "ok"
verdict, that the tap neither repaints nor touches a finished activity, and that the sweep's archive call is still the
idle reclaim. It reads the sources with comments dropped (string literals kept) and whitespace collapsed, prints one
'ok   <pin>' or 'FAIL <pin> ...' line per pin, and exits 1 when any pin fails. Each pin first checks a control
pattern, so a pin whose anchor moved fails instead of passing on an empty match. It reads the files and never
writes."""
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

    pa, rcv = read("ProfileActivity.java"), read("ReArchiveReceiver.java")
    bad = 0

    def pin(name, control, ok, why):
        nonlocal bad
        if not control:
            print(f"FAIL {name} -- control did not match")
            bad = 1
        elif ok:
            print(f"ok   {name}")
        else:
            print(f"FAIL {name} -- {why}")
            bad = 1

    row = block(pa, "private LinearLayout storageAppRow(")
    pin("p1 storageAppRow calls FreeOnPhone.offer",
        row != "" and "paintModeChip(" in row,
        "FreeOnPhone.offer(r.mode, installedNow, bundled, appsMeasured, r.code, playStack)" in row
        and "boolean playStack = GMS_PKG.equals(r.pkg) || GSF_PKG.equals(r.pkg) || VENDING_PKG.equals(r.pkg);" in row,
        "storageAppRow must compute playStack from GMS_PKG, GSF_PKG and VENDING_PKG and call "
        "FreeOnPhone.offer(r.mode, installedNow, bundled, appsMeasured, r.code, playStack)")

    fn = block(rcv, "static String freeNow(Context ctx, String pkg)")
    ok_anchor = 'if ("ok".equals(v))'
    ok_block = block(fn, ok_anchor)
    rest = fn.replace(ok_anchor + " " + ok_block, "", 1) if ok_block else fn
    pin('p2 freeNow archives only under an "ok" verdict',
        fn != "",
        "FreeOnPhone.verdict(" in fn and fn.count("readJobs(") == 1 and "ReArchiveGate.holdsJob(" in fn
        and fn.count("readPlayNeeded(") == 1
        and 0 <= fn.find("readJobs(") < fn.find("readPlayNeeded(") < fn.find("FreeOnPhone.verdict(")
        and ", roles, needed)" in fn
        and "archive(ctx, pkg" in ok_block and "archive(ctx, pkg" not in rest,
        'freeNow must read the jobs and then the needed Play stack once, decide through FreeOnPhone.verdict and '
        'ReArchiveGate.holdsJob with that set, and call '
        'archive(ctx, pkg, ...) only inside if ("ok".equals(v)) { ... }')

    tap = block(row, "free.setOnClickListener(")
    pin("p3 the Free tap handler does not repaint",
        "repaint" in row,
        tap != "" and "ReArchiveReceiver.freeNow(" in tap and "repaint" not in tap,
        "the free.setOnClickListener handler must call ReArchiveReceiver.freeNow and must not touch repaint")

    pin("p4 the tap result is guarded by isFinishing/isDestroyed",
        tap != "",
        before(tap, "runOnUiThread(", "if (isFinishing() || isDestroyed()) return;"),
        "the handler's runOnUiThread must return first when the activity is finishing or destroyed")

    sweep = block(rcv, "private void sweep(")
    two = block(rcv, "private static boolean archive(Context ctx, String pkg)")
    pin("p5 the sweep's archive line is still the idle reclaim",
        sweep != "",
        "archive(ctx, pkg);" in sweep and 'return archive(ctx, pkg, "idle reclaim");' in two,
        'sweep must call archive(ctx, pkg); and that 2-arg archive must return archive(ctx, pkg, "idle reclaim")')
    return bad


if __name__ == "__main__":
    sys.exit(main())
