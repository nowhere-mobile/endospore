"""Executes build-icon-pack.py's fetch and ImageMagick hand-off (NWP-20261029-14): the structural URL allow-list for
the first URL and every redirect, the PNG/JPEG/WebP sniff, the explicit `<coder>:-` input, the 4 MiB cap and the
refusal counts main() prints.

No network and no ImageMagick: the script's `_open` and `subprocess.run` are replaced. Run from anywhere:
    python3 -I core/vendor-common/prebuilts/test_build_icon_pack.py            (what CI runs)
    python3 -I core/vendor-common/prebuilts/test_build_icon_pack.py --mutate   (every broken copy must be convicted)
"""
import contextlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import types
import unittest
import urllib.request
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.environ.get("ICON_PACK_SCRIPT") or os.path.join(HERE, "build-icon-pack.py")


def _load(path):
    spec = importlib.util.spec_from_file_location("build_icon_pack_under_test", path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


B = _load(SCRIPT)
PNG = b"\x89PNG\r\n\x1a\n" + b"\0" * 8
JPEG = b"\xff\xd8\xff\xe0" + b"\0" * 8
WEBP = b"RIFF\x10\0\0\0WEBPVP8 "
GOOD = "https://f-droid.org/repo/a/icon.png"


class Fakes(unittest.TestCase):
    """Replaces B._open and subprocess.run for one test; records what each was called with."""

    def setUp(self):
        self.opened, self.converted = [], []
        self.body = PNG
        self.convert_rc = 0

        def fake_open(url):
            self.opened.append(url)
            return self.body

        def fake_run(argv, **kw):
            self.converted.append((argv, kw.get("input")))
            return types.SimpleNamespace(returncode=self.convert_rc, stdout=b"SCALED", stderr=b"")

        self.old = (B._open, B.subprocess.run)
        B._open, B.subprocess.run = fake_open, fake_run
        self.addCleanup(lambda: setattr(B, "_open", self.old[0]))
        self.addCleanup(lambda: setattr(B.subprocess, "run", self.old[1]))


class Sniffed(Fakes):
    def test_image_formats_get_their_own_coder(self):
        for raw, coder in ((PNG, "png:-"), (JPEG, "jpeg:-"), (WEBP, "webp:-")):
            self.converted.clear()
            self.body = raw
            self.assertEqual(B.fetch_and_scale("a.b", GOOD, 96), ("a.b", b"SCALED"))
            self.assertEqual(len(self.converted), 1)
            self.assertEqual(self.converted[0][0][1], coder)
            self.assertEqual(self.converted[0][1], raw)

    def test_non_images_never_reach_convert(self):
        for raw in (b"push graphic-context\nviewbox 0 0 1 1\n", b"<?xml version='1.0'?><svg/>", b"<svg xmlns=''/>",
                    b"GIF89a\1\0\1\0", b"RIFF\0\0\0\0WAVE", b""):
            self.body = raw
            self.assertEqual(B.fetch_icon("a.b", GOOD, 96), (None, "not-image"), raw)
        self.assertEqual(self.converted, [])

    def test_oversized(self):
        self.body = PNG + b"\0" * ((4 << 20) + 1 - len(PNG))
        self.assertEqual(len(self.body), (4 << 20) + 1)
        self.assertEqual(B.fetch_icon("a.b", GOOD, 96), (None, "oversized"))
        self.assertEqual(self.converted, [])

    def test_convert_failure(self):
        self.convert_rc = 1
        self.assertEqual(B.fetch_icon("a.b", GOOD, 96), (None, "convert"))

    def test_fetch_failure(self):
        def boom(url):
            raise OSError("down")
        B._open = boom
        self.assertEqual(B.fetch_icon("a.b", GOOD, 96), (None, "fetch"))


class InitialUrl(Fakes):
    def test_startswith_passes_but_structure_refuses(self):
        for url in ("https://f-droid.org/repo/../etc/x.png", "https://f-droid.org/repo/a.png?x=1",
                    "https://f-droid.org/repo/a.png#f", "https://evil.example/x.png",
                    "http://f-droid.org/repo/a.png", "https://f-droid.org/repo/a\\b.png"):
            self.assertEqual(B.fetch_icon("a.b", url, 96), (None, "off-repo"), url)
        self.assertEqual(self.opened, [])
        self.assertEqual(self.converted, [])


class RedirectHandler(unittest.TestCase):
    def target(self, url):
        h = B._RepoRedirects()
        req = urllib.request.Request(GOOD)
        return h.redirect_request(req, None, 302, "Found", {}, url)

    def test_off_list_targets_are_not_followed(self):
        for url in ("https://evil.example/x.png", "http://f-droid.org/repo/x.png",
                    "https://f-droid.org/repo/../x", "https://f-droid.org/repo/a?b"):
            self.assertIsNone(self.target(url), url)

    def test_on_list_target_is_followed(self):
        self.assertIsInstance(self.target("https://f-droid.org/repo/a/icon.png"), urllib.request.Request)

    def test_refused_redirect_counts_as_redirect(self):
        def redirected(url):
            raise B.urllib.error.HTTPError(url, 302, "Found", {}, None)
        old, B._open = B._open, redirected
        try:
            self.assertEqual(B.fetch_icon("a.b", GOOD, 96), (None, "redirect"))
        finally:
            B._open = old

    def test_the_opener_uses_the_handler(self):
        self.assertTrue(any(isinstance(h, B._RepoRedirects) for h in B._OPENER.handlers))


class Main(Fakes):
    def run_main(self, entries, tmp):
        idx, out = os.path.join(tmp, "idx.json"), os.path.join(tmp, "out.pack")
        with open(idx, "w") as f:
            json.dump({"entries": entries}, f)
        bodies = {"https://f-droid.org/repo/good.png": PNG, "https://f-droid.org/repo/bad.png": b"<svg/>"}
        B._open = lambda url: bodies[url]
        old_argv, sys.argv = sys.argv, ["build-icon-pack.py", idx, out]
        err = io.StringIO()
        try:
            with contextlib.redirect_stderr(err):
                with self.assertRaises(SystemExit) as cm:
                    B.main()
        finally:
            sys.argv = old_argv
        return cm.exception.code, err.getvalue(), out

    def test_pack_and_refusal_line(self):
        with tempfile.TemporaryDirectory() as tmp:
            code, err, out = self.run_main([
                {"pkg": "good.app", "iconRef": "https://f-droid.org/repo/good.png"},
                {"pkg": "svg.app", "iconRef": "https://f-droid.org/repo/bad.png"},
                {"pkg": "none.app", "iconRef": ""}], tmp)
            self.assertEqual(code, 0)
            self.assertIn("refused: 0 off-repo, 0 redirect, 1 not an image, 0 oversized, 0 fetch, 0 convert\n", err)
            with zipfile.ZipFile(out) as z:
                self.assertEqual(z.namelist(), ["good.app"])
                self.assertEqual(z.read("good.app"), b"SCALED")

    def test_no_good_icon_exits_1(self):
        with tempfile.TemporaryDirectory() as tmp:
            code, err, _ = self.run_main([{"pkg": "svg.app", "iconRef": "https://f-droid.org/repo/bad.png"}], tmp)
            self.assertEqual(code, 1)
            self.assertIn("1 not an image", err)


MUTANTS = [
    ("B1 sniff removed", "    coder = sniff(raw)\n", '    coder = "png"\n'),
    ("B2 coder back to bare -", '["convert", "%s:-" % coder,', '["convert", "-",'),
    ("B3 redirect check removed", "        if not allowed(newurl):\n            return None", "        if False:\n            return None"),
    ("B4 4 MiB cap removed", "    if len(raw) > ICON_FETCH_CAP:", "    if False:"),
    ("B5 allow-list is startswith", None, None),
]


def mutate():
    with open(SCRIPT) as f:
        src = f.read()
    bad = 0
    with tempfile.TemporaryDirectory() as d:
        env = dict(os.environ, TMPDIR=d)
        for name, old, new in MUTANTS:
            if old is None:
                a = src.index("def allowed(url):")
                b = src.index("class _RepoRedirects")
                m = src[:a] + 'def allowed(url):\n    return url.startswith("https://f-droid.org/repo/")\n\n\n' + src[b:]
            elif src.count(old) != 1:
                print("MUTANT DID NOT APPLY: %s" % name)
                bad += 1
                continue
            else:
                m = src.replace(old, new)
            p = os.path.join(d, "mut.py")
            with open(p, "w") as f:
                f.write(m)
            r = subprocess.run([sys.executable, "-I", os.path.abspath(__file__)], capture_output=True, text=True,
                               env=dict(env, ICON_PACK_SCRIPT=p))
            if r.returncode == 0:
                print("SURVIVED: %s" % name)
                bad += 1
            else:
                print("convicted: %s" % name)
    return 1 if bad else 0


if __name__ == "__main__":
    if "--mutate" in sys.argv[1:]:
        sys.exit(mutate())
    unittest.main()
