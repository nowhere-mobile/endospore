#!/usr/bin/env python3
# trim-fdroid-index.py -- Phase A of "store installs any F-Droid app" (docs/store-fdroid-search.md).
#
# Fetch F-Droid's index-v2.json, VERIFY its authenticity against F-Droid's PINNED repo signing cert (via the
# JAR-signed entry.jar -> its sha256 of index-v2.json), trim EVERY app to the Nowhere trimmed-index schema (a
# schema-1 `catalog` the daemon already parses), and emit a COMPACT trimmed-index.json. This job is the TRUST
# ROOT: `verify_entry_jar` and the pin below are the ONLY place F-Droid's index authenticity is established;
# curate-catalog.py (12 hand-checked apps) loads this script and verifies through the same `verify_entry_jar`
# (decided 2026-10-20), and an automated ~4000-app mirror MUST verify the repo signature.
#
# Signing the output (sign-catalog.sh with the INDEX key -- a SEPARATE ed25519 key from catalogPubKey) and the
# icon pack are SEPARATE later steps in Phase A. This tool only produces + verifies the trimmed JSON.
#
#   trim-fdroid-index.py OUT.json [--abi arm64-v8a] [--index index-v2.json --entry entry.jar]
#
# Without --index/--entry it fetches entry.jar + index-v2.json from f-droid.org/repo and verifies both.
# REQUIRES jarsigner + keytool (JDK) on PATH for the entry.jar signature + cert-fingerprint check.
import sys, os, json, time, tempfile, shutil, subprocess, hashlib, zipfile, re, posixpath, urllib.request, urllib.parse

FDROID = "https://f-droid.org/repo"

# F-Droid.org repo signing-cert SHA-256 -- the trust anchor. This is the widely-published f-droid.org/repo
# fingerprint; it is also the signer of the F-Droid client (== org.fdroid.fdroid's signingCert in our catalog).
# TODO(release): re-confirm against fdroidserver / the F-Droid client's baked repo config before shipping.
FDROID_REPO_CERT_SHA256 = "43238d512c1e5eb2d6569f4a3afbf5523418b82e0a3ed1552770abb9a9c9ccab"


def under_repo(url):
    """Host allow-list: every apk url + iconRef MUST live under https://f-droid.org/repo/. A plain startswith on
    FDROID + "/" + name is true by construction, so it is checked structurally: exact scheme + host, no
    params/query/fragment/backslash, and a path that survives normpath unchanged (no `..` or `.` segment)."""
    if "\\" in url:
        return False
    u = urllib.parse.urlparse(url)
    if u.scheme != "https" or u.netloc != "f-droid.org" or u.params or u.query or u.fragment:
        return False
    return u.path.startswith("/repo/") and posixpath.normpath(u.path).startswith("/repo/") \
        and posixpath.normpath(u.path) == u.path


def _sh(*args):
    return subprocess.run(args, capture_output=True, text=True)


def _fetch(url, dest):
    sys.stderr.write("fetch %s\n" % url)
    with urllib.request.urlopen(url, timeout=300) as r, open(dest, "wb") as f:
        f.write(r.read())


def verify_entry_jar(entry_jar):
    """entry.jar is JAR-signed by F-Droid's repo key. Verify (1) the JAR signature is cryptographically valid AND
    (2) the signer cert's SHA-256 equals our pinned F-Droid repo cert. Abort on any failure -- this is the trust
    root. NB: F-Droid signs with a SELF-SIGNED cert (no CA chain -- normal for Android/F-Droid; trust is by
    PINNING the fingerprint, not a CA path), so we do NOT use `jarsigner -strict` (it errors on self-signed). The
    fingerprint pin below -- not a CA chain -- is what establishes trust."""
    r = _sh("jarsigner", "-verify", entry_jar)
    out = ((r.stdout or "") + (r.stderr or "")).lower()
    if "jar verified" not in out or "jar is unsigned" in out or "not verif" in out:
        sys.exit("FATAL entry.jar signature did not verify:\n%s" % ((r.stdout or "") + (r.stderr or ""))[:500])
    r = _sh("keytool", "-printcert", "-jarfile", entry_jar)
    m = re.search(r"SHA256:\s*([0-9A-Fa-f:]+)", r.stdout or "")
    if not m:
        sys.exit("FATAL could not read entry.jar signer cert fingerprint:\n%s" % (r.stdout or r.stderr)[:400])
    got = m.group(1).replace(":", "").lower()
    if got != FDROID_REPO_CERT_SHA256:
        sys.exit("FATAL entry.jar signer %s != pinned F-Droid repo cert %s" % (got, FDROID_REPO_CERT_SHA256))
    sys.stderr.write("entry.jar VERIFIED: JAR sig valid + signer == pinned F-Droid repo cert\n")


def load_verified_index(cachedir, index_arg, entry_arg):
    """Return (index-v2 dict, timestamp-ms). Chain: verify entry.jar (signed) -> it names index-v2.json + its
    sha256 -> fetch index-v2.json -> confirm its sha256 matches. So the index is trusted transitively."""
    entry_jar = entry_arg or os.path.join(cachedir, "fdroid-entry.jar")
    if not entry_arg:
        _fetch(FDROID + "/entry.jar", entry_jar)
    verify_entry_jar(entry_jar)
    with zipfile.ZipFile(entry_jar) as z:
        entry = json.loads(z.read("entry.json"))
    idx_meta = entry["index"]                       # {name, sha256, size, numPackages}
    idx_name = idx_meta["name"].lstrip("/")
    idx_sha = (idx_meta["sha256"] or "").lower()
    index_json = index_arg or os.path.join(cachedir, "fdroid-index-v2.json")
    if not index_arg:
        _fetch(FDROID + "/" + idx_name, index_json)
    with open(index_json, "rb") as f:                       # read ONCE: the bytes hashed are the bytes parsed
        data = f.read()
    got = hashlib.sha256(data).hexdigest()
    if got != idx_sha:
        sys.exit("FATAL index-v2.json sha256 %s != signed entry.json's %s (tampered/stale mirror)" % (got, idx_sha))
    sys.stderr.write("index-v2.json VERIFIED: sha256 matches the signed entry.json (%d bytes)\n" % len(data))
    return json.loads(data), int(entry.get("timestamp") or 0)


# --- per-app trim. Mirrors curate-catalog.py's loc/pick_version/entry_for (canonical-apk tie-break) + adds
#     minSdk / nativecode / antiFeatures + a REQUIRED signer + host allow-list. TODO: dedupe into a shared module. ---
def loc(d):
    if isinstance(d, dict):
        for k in ("en-US", "en"):
            if k in d:
                return d[k]
        return next(iter(d.values()), "")
    return d if d is not None else ""


def pick_version(pkg, pkgobj, abi):
    vers = pkgobj.get("versions", {})
    cands = [(v.get("manifest", {}).get("versionCode"), v) for v in vers.values()
             if v.get("manifest", {}).get("versionCode")]
    if not cands:
        return None
    maxvc = max(c[0] for c in cands)
    same = [v for vc, v in cands if vc == maxvc]
    canonical = "%s_%d.apk" % (pkg, maxvc)

    def score(v):
        nc = v.get("manifest", {}).get("nativecode") or []
        abi_s = 2 if not nc else (1 if abi in nc else 0)
        fo = v.get("file")
        fn = fo.get("name") if isinstance(fo, dict) else ""   # a malformed `file` is the guard's to refuse
        canon_s = 1 if (fn if isinstance(fn, str) else "").lstrip("/") == canonical else 0
        return (abi_s, canon_s)

    same.sort(key=score, reverse=True)
    return maxvc, same[0]


# Q079 (docs/product-decisions.md, 2026-10-20): the trim ships every entry as ONE `base.apk`, so a version that is more
# than one file, or not an APK, would install incompletely. This is a fail-closed guard against a format change at
# F-Droid, not a filter on today's index (F-Droid lists one file per version). Only `file` is installable: `src` is the
# source tarball and, like releaseChannels / whatsNew / antiFeatures, is deliberately not a reason to refuse.
NOT_SINGLE_APK_KEYS = ("splits", "apks", "files", "obbMainFile", "obbPatchFile",
                       "obbMainFileSha256", "obbPatchFileSha256")


def single_apk(v):
    if any(v.get(k) for k in NOT_SINGLE_APK_KEYS):          # checked first: a null/absent `file` must not hide them
        return False
    f = v.get("file")
    if f is None:
        return True                                         # absent / null: the `nofile` gate refuses it
    if not isinstance(f, dict):
        return False
    name = f.get("name")
    if name is not None and not isinstance(name, str):
        return False
    if name and not re.split("[?#]", name)[0].lower().endswith(".apk"):   # a ?/# name is `badurl`'s to refuse
        return False
    return True


def trim_entry(pkg, pkgobj, abi):
    pv = pick_version(pkg, pkgobj, abi)
    if not pv:
        return None, "noversion"
    vc, v = pv
    if not single_apk(v):
        return None, "notsingleapk"
    f = v.get("file") or {}
    name = (f.get("name") or "").lstrip("/")
    sha = (f.get("sha256") or "").lower()
    size = int(f.get("size") or 0)
    if not name or len(sha) != 64:
        return None, "nofile"
    man = v.get("manifest", {})
    shas = (man.get("signer") or {}).get("sha256") or []
    signer = shas[0].lower() if (shas and isinstance(shas[0], str)) else ""
    if len(signer) != 64:                                   # REQUIRE a signer -- fail-closed (never ship an
        return None, "nosigner"                             # entry whose install would silently skip the gate)
    url = FDROID + "/" + name
    if not under_repo(url):                                 # host allow-list (apk)
        return None, "badurl"
    meta = pkgobj.get("metadata", {})
    cats = meta.get("categories") or []
    iconRef = ""
    ic = meta.get("icon")
    if isinstance(ic, dict):
        one = loc(ic)
        nm = one.get("name", "") if isinstance(one, dict) else ""
        if nm:
            iconRef = FDROID + nm                            # icon `name` carries a leading slash, no /repo
            if not under_repo(iconRef):                     # host allow-list (icon)
                iconRef = ""
    af = v.get("antiFeatures") or {}                         # per-version in index-v2 (feature -> localized reason)
    e = {
        "pkg": pkg,
        "versionCode": vc,
        "versionName": man.get("versionName", "") or "",
        "label": loc(meta.get("name")) or pkg,
        "category": (cats[0] if cats else "Apps"),
        "description": (loc(meta.get("summary")) or "").strip(),
        "sizeBytes": size,
        "source": "fdroid",
        "signingCert": signer,
        "iconRef": iconRef,
        "minSdk": int((man.get("usesSdk") or {}).get("minSdkVersion") or 0),
        "nativecode": man.get("nativecode") or [],
        "antiFeatures": sorted(af.keys()) if isinstance(af, dict) else list(af),
        "apks": [{"name": "base.apk", "url": url, "sha256": sha, "size": size}],
    }
    return e, None


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit("usage: trim-fdroid-index.py OUT.json [--abi ABI] [--index F --entry F]")
    out = args.pop(0)
    abi = "arm64-v8a"
    index_arg = entry_arg = None
    while args:
        a = args.pop(0)
        if a == "--abi":
            abi = args.pop(0)
        elif a == "--index":
            index_arg = args.pop(0)
        elif a == "--entry":
            entry_arg = args.pop(0)
        else:
            sys.exit("unknown arg " + a)

    cachedir = tempfile.mkdtemp()                           # 0700 by construction; the fixed names live only in it
    try:
        idx, ts_ms = load_verified_index(cachedir, index_arg, entry_arg)
    finally:
        shutil.rmtree(cachedir, ignore_errors=True)
    pkgs = idx.get("packages", {})
    entries, skip = [], {}
    for pkg, po in pkgs.items():
        e, why = trim_entry(pkg, po, abi)
        if e:
            entries.append(e)
        else:
            skip[why] = skip.get(why, 0) + 1
    entries.sort(key=lambda e: e["pkg"])                    # stable order; the daemon search re-ranks anyway
    catalog = {
        "schema": 1, "ring": "stable",
        "generated": int(ts_ms / 1000) if ts_ms else int(time.time()),   # F-Droid timestamp is ms; daemon wants s
        "entries": entries,
    }
    with open(out, "w", newline="\n") as f:
        json.dump(catalog, f, separators=(",", ":"))        # COMPACT -- ~4000 apps would balloon at indent=2
        f.write("\n")
    sys.stderr.write("wrote %s: %d apps (from %d packages; skipped %s) -> %d bytes\n"
                     % (out, len(entries), len(pkgs), skip, os.path.getsize(out)))


if __name__ == "__main__":
    main()
