#!/usr/bin/env python3
# build-icon-pack.py -- Phase A of "store installs any F-Droid app" (docs/store-fdroid-search.md).
#
# Given a trimmed-index.json (from trim-fdroid-index.py), fetch each app's F-Droid icon, downscale it to a small
# PNG, and pack them into a single `icons.pack` (a ZIP keyed by package name). The pack is baked into /system and
# served by the daemon's FETCH-ICON LOCALLY, so browsing the store reveals NOTHING to f-droid.org -- the privacy
# win (Chester's decision). A brand-new app surfaced only by a /data index refresh has no baked icon -> the client
# shows a generic placeholder (NOT a live fetch, which would reintroduce the leak); its icon rides the next release.
#
# Pack format (read by the Phase B daemon): a ZIP, each entry NAMED EXACTLY `<pkg>`, value = 96x96 PNG bytes.
# Signing (icons.pack.sig, the SEPARATE index key) is a later step, like the index.
#
#   build-icon-pack.py TRIMMED-INDEX.json OUT.pack [--size 96] [--workers 16] [--limit N]
#
# Requires ImageMagick `convert` on PATH (no webp delegate needed -- PNG out). The job runs on the signing host beside
# the online index key, so ImageMagick is fed nothing but a SNIFFED PNG/JPEG/WebP, under an EXPLICIT coder (`png:-`),
# fetched from a structurally allow-listed URL with no redirect off the list -- never its format auto-detection, which
# reaches the MVG/MSL/SVG/text script coders (the ImageTragick shape).
import sys, os, json, zipfile, subprocess, urllib.request, urllib.parse, urllib.error, posixpath
from concurrent.futures import ThreadPoolExecutor

ICON_FETCH_CAP = 4 << 20                      # a hostile "icon" over 4 MiB is dropped (defends memory + the pack)
REASONS = ("off-repo", "redirect", "not-image", "oversized", "fetch", "convert")


def allowed(url):
    """Host allow-list for every fetch, the first URL AND each redirect target (copy of trim-fdroid-index.py's
    under_repo): exact https scheme + host f-droid.org, no params/query/fragment/backslash, and a path under /repo/
    that survives normpath unchanged (no `..` or `.` segment). A plain startswith is true by construction."""
    if "\\" in url:
        return False
    u = urllib.parse.urlparse(url)
    if u.scheme != "https" or u.netloc != "f-droid.org" or u.params or u.query or u.fragment:
        return False
    return u.path.startswith("/repo/") and posixpath.normpath(u.path).startswith("/repo/") \
        and posixpath.normpath(u.path) == u.path


class _RepoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not allowed(newurl):
            return None          # not followed: the fetch fails with the 3xx HTTPError
        return super().redirect_request(req, fp, code, msg, headers, newurl)


_OPENER = urllib.request.build_opener(_RepoRedirects)


def _open(url):
    """GET url through the redirect-checking opener; return at most ICON_FETCH_CAP + 1 body bytes. Raises on any
    non-200 status, network error or refused redirect."""
    with _OPENER.open(url, timeout=25) as r:
        if r.status != 200:
            raise urllib.error.URLError("status %s" % r.status)
        return r.read(ICON_FETCH_CAP + 1)


def sniff(raw):
    """The ImageMagick coder name for PNG / JPEG / WebP bytes, else None (SVG, MVG, MSL, GIF, text, empty...)."""
    if raw.startswith(b"\x89PNG\r\n\x1a\n"):
        return "png"
    if raw.startswith(b"\xff\xd8\xff"):
        return "jpeg"
    if raw[:4] == b"RIFF" and raw[8:12] == b"WEBP":
        return "webp"
    return None


def fetch_icon(pkg, url, size):
    """Fetch one icon and downscale it to a `size`x`size` PNG via ImageMagick. Return ((pkg, png_bytes), None) or
    (None, reason) with reason one of REASONS -> that app just gets the on-device placeholder."""
    if not allowed(url):
        return None, "off-repo"
    try:
        raw = _open(url)
    except urllib.error.HTTPError as e:
        return None, ("redirect" if 300 <= e.code < 400 else "fetch")
    except Exception:
        return None, "fetch"
    if len(raw) > ICON_FETCH_CAP:
        return None, "oversized"
    coder = sniff(raw)
    if coder is None:
        return None, "not-image"
    try:
        # `convert <coder>:- ... png:-`: read stdin under the sniffed coder, fit within size x size preserving aspect
        # + alpha, strip metadata, max PNG compression. Bound the subprocess so a pathological input can't hang it.
        p = subprocess.run(
            ["convert", "%s:-" % coder, "-thumbnail", "%dx%d" % (size, size), "-strip",
             "-colors", "256",   # palette-quantize (app icons are low-color) -> ~halves the PNG; keeps alpha
             "-define", "png:compression-level=9", "png:-"],
            input=raw, capture_output=True, timeout=30)
    except Exception:
        return None, "convert"
    if p.returncode != 0 or not p.stdout:
        return None, "convert"
    return (pkg, p.stdout), None


def fetch_and_scale(pkg, url, size):
    return fetch_icon(pkg, url, size)[0]


def main():
    args = sys.argv[1:]
    if len(args) < 2:
        sys.exit("usage: build-icon-pack.py TRIMMED-INDEX.json OUT.pack [--size 96] [--workers 16] [--limit N]")
    index_path, out = args[0], args[1]
    size, workers, limit = 96, 16, 0
    rest = args[2:]
    while rest:
        a = rest.pop(0)
        if a == "--size":
            size = int(rest.pop(0))
        elif a == "--workers":
            workers = int(rest.pop(0))
        elif a == "--limit":
            limit = int(rest.pop(0))
        else:
            sys.exit("unknown arg " + a)

    d = json.load(open(index_path, encoding="utf-8"))
    jobs = [(e["pkg"], e["iconRef"]) for e in d["entries"] if e.get("iconRef")]
    if limit:
        jobs = jobs[:limit]
    sys.stderr.write("icons to fetch: %d (of %d entries), %dx%d, %d workers\n"
                     % (len(jobs), len(d["entries"]), size, size, workers))

    ok = 0
    done = 0
    refused = dict.fromkeys(REASONS, 0)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_STORED) as z:   # PNGs are already compressed -> STORED
        with ThreadPoolExecutor(max_workers=workers) as ex:
            for res in ex.map(lambda j: fetch_icon(j[0], j[1], size), jobs):
                done += 1
                res, why = res
                if not res:
                    refused[why] += 1
                else:
                    z.writestr(res[0], res[1])   # entry name == pkg (exact), value = PNG bytes
                    ok += 1
                if done % 250 == 0:
                    sys.stderr.write("  %d/%d fetched, %d packed\n" % (done, len(jobs), ok))
    sys.stderr.write("refused: %d off-repo, %d redirect, %d not an image, %d oversized, %d fetch, %d convert\n"
                     % tuple(refused[r] for r in REASONS))
    sz = os.path.getsize(out)
    sys.stderr.write("wrote %s: %d/%d icons packed, %d bytes (%.1f MB), avg %d B/icon\n"
                     % (out, ok, len(jobs), sz, sz / 1e6, (sz // ok) if ok else 0))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
