#!/usr/bin/env python3
# Publish a NOWHERE-OWN app into the store catalog (source:"nowhere") -- the mirror of curate-catalog.py, but for
# a FIRST-PARTY app Nowhere builds/signs/hosts itself rather than one curated from F-Droid or delegated to Play.
# source:"nowhere" is already a VETTED source in the storefront (installs without the sideload warning) and is
# signer-gated at install (the fetched APK's signing cert must match signingCert), so a Nowhere slot makes Nowhere
# the single trust root end-to-end: it signs the catalog, signs the app, and hosts the bytes.
#
# STATUS: a STUB / dormant helper (there are no Nowhere-own apps yet). It computes everything derivable from the
# APK -- sha256, size, and (if apksigner is on PATH) the signing-cert sha256 -- and emits a ready-to-merge catalog
# entry. The two steps it deliberately does NOT perform are RELEASE-SECRET operations that belong to the release
# owner, not this tool:
#   1) SIGN the APK with the Nowhere app-signing key (a release secret, like the catalog-signing key).
#   2) UPLOAD the signed APK to the R2 "nowhere" bucket at --base-url.
# After those, re-run this with the SIGNED apk to fill signingCert, then merge the entry into catalog.json and
# re-sign the catalog (sign-catalog.sh).
#
#   publish-nowhere-app.py APP.apk \
#       --pkg com.nowhere.app --label "Nowhere App" --version-code 1 \
#       --category "Nowhere" --description "..." \
#       --base-url https://<r2-host>/nowhere/apps  [--icon-url https://.../icon.png] [--merge catalog.json]
#
# With --merge (refused unless signingCert is 64-hex) the entry is spliced into an existing catalog.json (replacing any prior entry for the same pkg);
# otherwise the single entry is printed to stdout. LF output always.
import sys, os, json, hashlib, shutil, subprocess


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def signer_sha256(apk):
    # Best-effort: apksigner prints the signer cert's SHA-256. Returns "" if the tool isn't on PATH or the APK
    # isn't signed yet (the expected STUB case -- sign with the Nowhere key first, then re-run to fill this in).
    exe = shutil.which("apksigner")
    if not exe:
        return ""
    try:
        out = subprocess.run([exe, "verify", "--print-certs", apk], capture_output=True, text=True, timeout=60)
        for line in out.stdout.splitlines():
            low = line.lower()
            if "sha-256 digest" in low and "certificate" in low:  # "... certificate SHA-256 digest: <hex>"
                return line.split(":")[-1].strip().replace(" ", "").lower()
    except Exception:
        pass
    return ""


def is_hex64(s):
    return isinstance(s, str) and len(s) == 64 and all(c in "0123456789abcdef" for c in s)


def main():
    args = sys.argv[1:]
    if not args or args[0].startswith("--"):
        sys.exit("usage: publish-nowhere-app.py APP.apk --pkg P --label L --version-code N --category C "
                 "--description D --base-url URL [--icon-url URL] [--merge catalog.json]")
    apk = args.pop(0)
    opt = {"category": "Nowhere", "description": "", "version-code": "0", "base-url": "", "icon-url": ""}
    key = None
    for a in args:
        if a.startswith("--"):
            key = a[2:]
        elif key is not None:
            opt[key] = a
            key = None
    for req in ("pkg", "label", "base-url"):
        if not opt.get(req):
            sys.exit("missing --%s" % req)

    size = os.path.getsize(apk)
    sha = sha256_file(apk)
    signer = signer_sha256(apk)
    name = os.path.basename(apk)
    if not name.endswith(".apk"):
        name = "base.apk"
    url = opt["base-url"].rstrip("/") + "/" + name

    entry = {
        "pkg": opt["pkg"],
        "versionCode": int(opt["version-code"] or 0),
        "label": opt["label"],
        "category": opt["category"] or "Nowhere",
        "description": opt["description"],
        "sizeBytes": size,
        "source": "nowhere",       # first-party: VETTED (no sideload warning) + signer-gated at install
        "signingCert": signer,     # empty until the APK is signed with the Nowhere app key + this is re-run
        "iconRef": opt.get("icon-url", ""),
        "apks": [{"name": name, "url": url, "sha256": sha, "size": size}],
    }
    if not signer:
        sys.stderr.write("WARN: signingCert is EMPTY -- sign %s with the Nowhere app-signing key (a release "
                         "secret), then re-run this so the install-time signer gate can pin it.\n" % name)
    sys.stderr.write("NEXT: (1) sign the APK with the Nowhere app key; (2) upload it to %s; (3) merge this entry "
                     "+ re-sign the catalog (sign-catalog.sh).\n" % url)

    merge = opt.get("merge")
    if merge:
        if not is_hex64(signer):
            sys.exit("refusing to merge %s: signingCert is not a 64-hex SHA-256 -- sign %s with the Nowhere app "
                     "key, then re-run (the install-time signer pin is skipped for an empty cert)"
                     % (entry["pkg"], name))
        with open(merge, "rb") as f:
            cat = json.load(f)
        cat.setdefault("entries", [])
        cat["entries"] = [e for e in cat["entries"] if e.get("pkg") != entry["pkg"]] + [entry]
        with open(merge, "w", newline="\n") as f:  # LF always (a CR breaks the convention + churns git)
            json.dump(cat, f, indent=2)
            f.write("\n")
        sys.stderr.write("merged %s into %s (%d entries)\n" % (entry["pkg"], merge, len(cat["entries"])))
    else:
        sys.stdout.write(json.dumps(entry, indent=2) + "\n")


if __name__ == "__main__":
    main()
