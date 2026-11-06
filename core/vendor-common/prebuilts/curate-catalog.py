#!/usr/bin/env python3
# App-store catalog curation pipeline (Phase 4, DIA-20260730). For each curated F-Droid package, pull the
# SUGGESTED (highest-versionCode) release's REAL apkName + sha256 + size + versionCode + display metadata from
# F-Droid's index, and emit a catalog.json the daemon serves (GET-CATALOG) and FETCH-APP installs from
# (sha256-gated, fail-closed). Multi-ABI apps: prefer a universal APK, else the device ABI (arm64-v8a).
#
# The per-APK sha256 here is the F-Droid index's hash of the exact file at the URL -- so FETCH-APP's download
# verifies against it. Sign the output separately for a signed /data override / dynamic push (sign-catalog.sh);
# the baked /system copy rides verified boot.
#
#   curate-catalog.py OUT.json [--abi arm64-v8a] PKG[:versionCode] ...
#   curate-catalog.py OUT.json --list curated.txt      (one "PKG[:versionCode]" per line; # comments ok)
#
# Needs network (downloads entry.jar, then index-v2.json, ~54 MB, from f-droid.org/repo). The index is VERIFIED
# against F-Droid's signed entry.jar and the pinned F-Droid repo cert through trim-fdroid-index.py's
# verify_entry_jar (decided 2026-10-20, docs/product-decisions.md): entry.jar's signature and signer fingerprint
# are checked, and the index is parsed only if its sha256 is the one the signed entry.json names. The curation
# host needs jarsigner and keytool (JDK) on PATH, and trim-fdroid-index.py beside this script (or at
# $NOWHERE_TRIM_SCRIPT): its absence is fatal, never a fallback to TLS. The verified index is cached for 6h in a
# PRIVATE directory ($NOWHERE_FDROID_CACHE, else ~/.cache/nowhere-fdroid, mode 0700) and reused only if the
# directory and file are ours, not group/world-writable, the file is regular, fresh, and hashes to the signed
# sha256. The only thing made in the shared temp directory is a private directory holding entry.jar, removed
# before load_index returns.
import sys, os, json, re, stat, time, hashlib, tempfile, zipfile, importlib.util, urllib.request

FDROID = "https://f-droid.org/repo"
ENTRY_URL = FDROID + "/entry.jar"
_TRIM = None


def _trim():
    """trim-fdroid-index.py loaded as a module: ONE trust root (its verify_entry_jar and the pinned repo cert),
    not a copy. Lazy, so importing this script needs no JDK. A missing or unloadable script is fatal."""
    global _TRIM
    if _TRIM is None:
        path = os.environ.get("NOWHERE_TRIM_SCRIPT") or os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                                     "trim-fdroid-index.py")
        try:
            spec = importlib.util.spec_from_file_location("nowhere_trim_fdroid_index", path)
            m = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(m)
            m.verify_entry_jar, m.FDROID_REPO_CERT_SHA256
        except Exception as e:
            sys.exit("FATAL cannot load the entry.jar verifier %s: %s" % (path, type(e).__name__))
        _TRIM = m
    return _TRIM


def _cache_dir():
    """The private cache directory: $NOWHERE_FDROID_CACHE, else ~/.cache/nowhere-fdroid. Created 0700 here, and
    only here: a directory that already exists is judged by _cache_reason, never silently re-permissioned."""
    d = os.environ.get("NOWHERE_FDROID_CACHE") or os.path.join(os.path.expanduser("~"), ".cache", "nowhere-fdroid")
    if not os.path.isdir(d):
        os.makedirs(d, mode=0o700, exist_ok=True)
        os.chmod(d, 0o700)
    return d


def _cache_reason(cache_dir, path):
    """None when the cached index may be reused, else the reason it may not (never the file's content). A
    cache is trusted only if the directory and the file are ours, neither is group/world-writable, the file is
    a regular file (lstat: a symlink is not) and it is under 6 hours old."""
    if not hasattr(os, "getuid"):
        return "no owner check on this platform"
    uid = os.getuid()
    try:
        ds = os.stat(cache_dir)
        fs = os.lstat(path)
    except OSError:
        return "no cached index"
    if ds.st_uid != uid or ds.st_mode & 0o022:
        return "cache directory is not private to this user"
    if not stat.S_ISREG(fs.st_mode):
        return "cached index is not a regular file"
    if fs.st_uid != uid or fs.st_mode & 0o022:
        return "cached index is not private to this user"
    if not 0 <= time.time() - fs.st_mtime < 6 * 3600:
        return "cached index is stale"
    return None


def load_index():
    t = _trim()
    cache_dir = _cache_dir()
    cache = os.path.join(cache_dir, "fdroid-index-v2.json")
    with tempfile.TemporaryDirectory() as d:                # private (0700) and gone before we return
        jar = os.path.join(d, "entry.jar")
        sys.stderr.write("downloading %s ...\n" % ENTRY_URL)
        with urllib.request.urlopen(ENTRY_URL, timeout=180) as r:
            body = r.read()
        with open(jar, "wb") as f:
            f.write(body)
        t.verify_entry_jar(jar)
        try:
            with zipfile.ZipFile(jar) as z:
                entry = json.loads(z.read("entry.json"))
            name = entry["index"]["name"].lstrip("/")
            sha = (entry["index"]["sha256"] or "").lower()
        except (zipfile.BadZipFile, KeyError, TypeError, AttributeError, ValueError) as e:
            sys.exit("FATAL entry.jar's entry.json is malformed: %s" % type(e).__name__)
    if not re.fullmatch(r"[0-9a-f]{64}", sha):
        sys.exit("FATAL signed entry.json's index sha256 is not 64 hex")
    data = None
    why = _cache_reason(cache_dir, cache)
    if why is None:
        fd = os.open(cache, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        with os.fdopen(fd, "rb") as f:
            data = f.read()                                 # read ONCE; these are the bytes hashed and parsed
        if hashlib.sha256(data).hexdigest() != sha:
            why = "cached index does not match the signed entry.json"
            data = None
        else:
            sys.stderr.write("using cached index %s\n" % cache)
    if data is None:
        if why != "no cached index":
            sys.stderr.write("not reusing %s: %s\n" % (cache, why))
        url = FDROID + "/" + name
        sys.stderr.write("downloading %s ...\n" % url)
        with urllib.request.urlopen(url, timeout=180) as r:
            data = r.read()
        got = hashlib.sha256(data).hexdigest()
        if got != sha:
            sys.exit("FATAL %s sha256 %s != signed entry.json's %s (tampered/stale mirror)" % (url, got, sha))
        # Cache only into a directory that is ours and private: a shared one would hand the next run a planted file.
        if _cache_reason(cache_dir, cache) not in ("cache directory is not private to this user",
                                                   "no owner check on this platform"):
            fd, tmp = tempfile.mkstemp(dir=cache_dir)
            try:
                with os.fdopen(fd, "wb") as f:
                    f.write(data)
                os.replace(tmp, cache)
            except OSError as e:
                sys.stderr.write("could not cache the index: %s\n" % e.strerror)
                if os.path.lexists(tmp):
                    os.remove(tmp)
    try:
        return json.loads(data)
    except ValueError:
        sys.exit("FATAL the verified index is not valid JSON")


def loc(d):
    """A localized F-Droid field: {"en-US": v} | {"en": v} | str -> a plain value."""
    if isinstance(d, dict):
        for k in ("en-US", "en"):
            if k in d:
                return d[k]
        return next(iter(d.values()), "")
    return d if d is not None else ""


def pick_version(pkg, pkgobj, want_vc, abi):
    vers = pkgobj.get("versions", {})
    cands = []
    for v in vers.values():
        vc = v.get("manifest", {}).get("versionCode")
        if vc is None or (want_vc and vc != want_vc):
            continue
        cands.append((vc, v))
    if not cands:
        return None

    # NWP-20260825-24: ABI FIRST, VERSION SECOND. This used to take max(versionCode) and only then score the
    # ABI among files sharing that one versionCode -- which makes the ABI preference unreachable for exactly
    # the apps it exists for. VLC ships one APK PER ABI, each with its OWN versionCode, ordered
    # ...05 armeabi-v7a / ...06 arm64-v8a / ...07 x86 / ...08 x86_64. So max() picked 13070108, the x86_64
    # build, `same` held that single file, and the scoring had nothing to choose between. The catalog shipped
    # an x86_64 APK to an arm64-only phone, and every install of it failed on-device with
    # INSTALL_FAILED_NO_MATCHING_ABIS ("Failed to extract native libraries, res=-113") -- proven on lynx
    # 2026-08-25, where it was also the only broken entry of the eleven.
    #
    # Ranking each candidate as (abi, versionCode, canonical-filename) picks the NEWEST version that this
    # device can actually run, and degrades to the old behaviour for single-APK apps, where every candidate
    # scores the same on ABI and versionCode decides as before.
    # ⚠ COMPATIBILITY FILTERS, IT DOES NOT OUTRANK THE VERSION. An earlier cut of this ranked
    # (universal > our-ABI > incompatible) ABOVE the versionCode, which quietly introduced the opposite bug:
    # an app that moved from a universal APK to per-ABI splits would pin FOREVER to the last universal build,
    # because abi_s=2 beat every newer abi_s=1 candidate. Pinned by test_curate_catalog.py (NWP-20261022-17). So the only
    # thing ABI decides is CAN THIS DEVICE RUN IT; among runnable candidates the newest version wins, and
    # `universal` is merely a tie-break between files at the SAME version.
    def score(vc, v):
        nc = v.get("manifest", {}).get("nativecode") or []
        runnable = 1 if (not nc or abi in nc) else 0
        universal = 1 if not nc else 0
        # F-Droid can carry >1 file at the same versionCode (a reproducible-build variant is suffixed with a
        # short hash, e.g. `_1013_cb84069.apk`). Prefer the canonical `{pkg}_{vc}.apk` so the catalog serves the
        # exact file baked into /product -- otherwise a same-version re-fetch could pull a different binary.
        canon_s = 1 if (v.get("file", {}).get("name") or "").lstrip("/") == ("%s_%d.apk" % (pkg, vc)) else 0
        return (runnable, vc, universal, canon_s)

    best_vc, best = max(cands, key=lambda c: score(c[0], c[1]))

    # FAIL CLOSED. An APK carrying native code for other architectures cannot install here, so emitting it
    # would pin a catalog entry that is guaranteed to fail on every device -- silently, since the failure only
    # appears in logcat as a PackageInstaller session result. Refusing is the whole point: the previous
    # behaviour was not "picked a worse APK", it was "shipped one that could never work".
    nc = best.get("manifest", {}).get("nativecode") or []
    if nc and abi not in nc:
        sys.exit("curate: %s has no %s build (only %s) -- refusing to pin an APK this device cannot install"
                 % (pkg, abi, ",".join(sorted(nc))))
    return best_vc, best


def entry_for(pkg, want_vc, pkgobj, abi):
    pv = pick_version(pkg, pkgobj, want_vc, abi)
    if not pv:
        return None
    vc, v = pv
    f = v.get("file", {})
    name = (f.get("name") or "").lstrip("/")
    sha = f.get("sha256") or ""
    size = int(f.get("size") or 0)
    if not name or len(sha) != 64:
        return None
    man = v.get("manifest", {})
    # signer.sha256 = SHA-256 of the APK signing certificate (matches Android's signing-cert digest). Recorded so
    # the installer can verify the fetched APK is signed by the expected publisher (provenance / update pinning).
    # FAIL CLOSED, as trim-fdroid-index.py trim_entry does: an entry without a signer would install on every
    # phone with no signer pin (the device skips the pin for an empty signingCert).
    shas = (man.get("signer") or {}).get("sha256") or []
    signer = shas[0] if isinstance(shas, list) and shas else None
    if not (isinstance(signer, str) and len(signer) == 64 and all(c in "0123456789abcdefABCDEF" for c in signer)):
        sys.stderr.write("curate: %s vc=%s carries no 64-hex signer in index-v2 -- refusing an entry whose "
                         "install would skip the signer pin\n" % (pkg, vc))
        return None
    signer = signer.lower()
    meta = pkgobj.get("metadata", {})
    cats = meta.get("categories") or []
    icon = ""
    ic = meta.get("icon")
    if isinstance(ic, dict):
        one = loc(ic)
        if isinstance(one, dict):
            icon = one.get("name", "") or ""
    return {
        "pkg": pkg,
        "versionCode": vc,
        "versionName": man.get("versionName", "") or "",
        "label": loc(meta.get("name")) or pkg,
        "category": (cats[0] if cats else "Apps"),
        "description": (loc(meta.get("summary")) or "").strip(),
        "sizeBytes": size,
        "source": "fdroid",
        "signingCert": signer,
        "iconRef": (FDROID + icon) if icon else "",
        "apks": [{"name": "base.apk", "url": FDROID + "/" + name, "sha256": sha, "size": size}],
    }


def play_entry(spec):
    # "pkg|Label|Category|Description": a Google-Play app the store DELEGATES to Aurora Store (anonymous Play
    # download). No static URL/hash/apks -- FETCH-APP doesn't apply; the storefront opens it in Aurora and the
    # user installs there. source="play" so the UI badges it + routes it through the provenance notice.
    parts = (spec.split("|") + ["", "", ""])[:4]
    pkg = parts[0].strip()
    if not pkg:
        return None
    return {
        "pkg": pkg,
        "label": parts[1].strip() or pkg,
        "category": parts[2].strip() or "Apps",
        "description": parts[3].strip(),
        "source": "play",
        "apks": [],
    }


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit("usage: curate-catalog.py OUT.json [--abi ABI] PKG[:vc] ... | --list FILE")
    out = args.pop(0)
    abi = "arm64-v8a"
    specs = []
    play_specs = []
    while args:
        a = args.pop(0)
        if a == "--abi":
            abi = args.pop(0)
        elif a == "--play":  # a Google-Play app, delegated to Aurora: "pkg|Label|Category|Description"
            play_specs.append(args.pop(0))
        elif a == "--list":
            with open(args.pop(0)) as fh:
                for ln in fh:
                    ln = ln.split("#", 1)[0].strip()
                    if ln:
                        specs.append(ln)
        else:
            specs.append(a)

    entries, missed = [], []
    if specs:  # only F-Droid specs need the (54 MB) index
        idx = load_index()
        pkgs = idx.get("packages", {})
        for spec in specs:
            pkg, _, vc = spec.partition(":")
            po = pkgs.get(pkg)
            e = entry_for(pkg, int(vc) if vc else 0, po, abi) if po else None
            if e:
                entries.append(e)
                sys.stderr.write("OK  %-32s vc=%d %s size=%d\n" % (e["pkg"], e["versionCode"], e["apks"][0]["sha256"][:12], e["sizeBytes"]))
            else:
                missed.append(pkg)
                sys.stderr.write("MISS %s\n" % pkg)
    for ps in play_specs:  # Aurora-delegated Play apps (no static URL/hash -- opened in Aurora, not FETCH-APP)
        e = play_entry(ps)
        if e:
            entries.append(e)
            sys.stderr.write("PLAY %-32s (Aurora-delegated)\n" % e["pkg"])

    # Group entries so same-category rows are CONTIGUOUS: the storefront (renderCatalog) emits a section header
    # whenever a row's category differs from the previous row's, so a category that reappeared non-contiguously
    # would render a DUPLICATE header. Stable-group by first appearance (preserves the curation order otherwise).
    order = {}
    for e in entries:
        order.setdefault(e.get("category", ""), len(order))
    entries.sort(key=lambda e: order[e.get("category", "")])

    catalog = {"schema": 1, "ring": "stable", "generated": int(time.time()), "entries": entries}
    with open(out, "w", newline="\n") as fh:  # LF always (a CR breaks the LF convention + git churn)
        json.dump(catalog, fh, indent=2)
        fh.write("\n")
    sys.stderr.write("wrote %s: %d entries%s\n" % (out, len(entries), (" (missed: %s)" % ",".join(missed)) if missed else ""))
    sys.exit(1 if missed else 0)


if __name__ == "__main__":
    main()
