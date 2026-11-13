#!/usr/bin/env python3
"""pins.py <repo-root> -- NWP-20261202-29: source checks that ProfileActivity.reportStatus puts default_roles exactly
once, from readDefaultRoles, and that readDefaultRoles reads every RoleReport role and maps each holder's flags through
RoleReport.isBundled. It reads the source with comments dropped (string literals kept) and whitespace collapsed,
prints one 'ok   <pin>' or 'FAIL <pin> ...' line per pin, and exits 1 when any pin fails. It reads the file and never
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


def main():
    root = sys.argv[1]
    with open(f"{root}/{CH}/ProfileActivity.java", encoding="utf-8") as f:
        src = strip(f.read())
    bad = 0

    def pin(name, ok, why):
        nonlocal bad
        if ok:
            print(f"ok   {name}")
        else:
            print(f"FAIL {name} -- {why}")
            bad = 1

    put = 'st.put("default_roles", readDefaultRoles(ctx));'
    rs = block(src, "static org.json.JSONObject reportStatus(")
    ret = rs.find("return st;")
    pin("p1 reportStatus puts default_roles exactly once",
        rs.count(put) == 1 and ret > rs.find(put) >= 0 and src.count('"default_roles"') == 1,
        f"reportStatus holds {put!r} {rs.count(put)} time(s) (want 1, before return st;); "
        f"the file holds \"default_roles\" {src.count(chr(34) + 'default_roles' + chr(34))} time(s)")
    rd = block(src, "static String readDefaultRoles(")
    need = ["RoleReport.ROLES", "isRoleAvailable(", "getRoleHolders(", "RoleReport.isBundled(", ".flags",
            "RoleReport.format("]
    missing = [n for n in need if n not in rd]
    pin("p2 readDefaultRoles reads every role and maps flags through isBundled",
        rd != "" and not missing and "Log." not in rd and "getRoleHoldersAsUser" not in rd,
        "readDefaultRoles is absent" if rd == "" else f"missing {missing}, or it logs, or it reads another user")
    sys.exit(bad)


if __name__ == "__main__":
    main()
