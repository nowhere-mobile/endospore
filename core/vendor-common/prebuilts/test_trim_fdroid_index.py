"""Executes trim-fdroid-index.py's trust-root checks (NWP-20261019-35): the entry.jar signature + fingerprint pin,
the index sha256 against the signed entry.json, and trim_entry's signer / file / URL / single-APK refusals.

No network and no JDK: the script's `_sh` and `_fetch` are stubbed. Run from anywhere:
    python3 -I core/vendor-common/prebuilts/test_trim_fdroid_index.py            (what CI runs)
    python3 -I core/vendor-common/prebuilts/test_trim_fdroid_index.py --mutate   (every broken copy must be convicted)
"""
import atexit
import builtins
import contextlib
import hashlib
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import types
import unittest
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.environ.get("TRIM_SCRIPT") or os.path.join(HERE, "trim-fdroid-index.py")


def _load(path):
    spec = importlib.util.spec_from_file_location("trim_fdroid_index_under_test", path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


T = _load(SCRIPT)
ROOT = tempfile.mkdtemp(prefix="test-trim-fdroid-")      # every temp of this process lives in here
atexit.register(shutil.rmtree, ROOT, True)
PIN = T.FDROID_REPO_CERT_SHA256
SIGNER = "AB" * 32
SHA = "cd" * 32


def _run(out_by_cmd):
    def fake(*args):
        return types.SimpleNamespace(stdout=out_by_cmd[args[0]], stderr="")
    return fake


def _colon(h):
    return ":".join(h[i:i + 2].upper() for i in range(0, len(h), 2))


def _jar_ok(fp=None):
    return _run({"jarsigner": "jar verified.\n",
                 "keytool": "Certificate fingerprints:\n\t SHA256: %s\n" % _colon(fp or PIN)})


def _exits(fn):
    try:
        fn()
    except SystemExit as e:
        return str(e.code)
    return None


class VerifyEntryJar(unittest.TestCase):
    def check(self, runner):
        old, T._sh = T._sh, runner
        try:
            return _exits(lambda: T.verify_entry_jar("x.jar"))
        finally:
            T._sh = old

    def test_pass(self):
        self.assertIsNone(self.check(_jar_ok()))

    def test_unsigned(self):
        self.assertIsNotNone(self.check(_run({"jarsigner": "jar is unsigned.\n", "keytool": ""})))

    def test_not_verified(self):
        self.assertIsNotNone(self.check(_run({"jarsigner": "something else\n", "keytool": ""})))

    def test_no_sha256_line(self):
        r = _run({"jarsigner": "jar verified.\n", "keytool": "Certificate fingerprints:\n\t SHA1: AA:BB\n"})
        self.assertIn("could not read", self.check(r))

    def test_wrong_fingerprint(self):
        self.assertIn("!= pinned", self.check(_jar_ok("00" * 32)))


class LoadVerifiedIndex(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(dir=ROOT)
        self.addCleanup(tmp.cleanup)
        self.d = tmp.name
        self.index = os.path.join(self.d, "index-v2.json")
        with open(self.index, "w") as f:
            json.dump({"packages": {"a.b": {}}}, f)
        with open(self.index, "rb") as f:
            self.sha = hashlib.sha256(f.read()).hexdigest()
        self.jar = os.path.join(self.d, "entry.jar")
        self.old = T.verify_entry_jar
        T.verify_entry_jar = lambda j: None

    def tearDown(self):
        T.verify_entry_jar = self.old

    def entry(self, sha):
        with zipfile.ZipFile(self.jar, "w") as z:
            z.writestr("entry.json", json.dumps(
                {"timestamp": 5, "index": {"name": "/index-v2.json", "sha256": sha}}))

    def test_mismatch_exits(self):
        self.entry("0" * 64)
        msg = _exits(lambda: T.load_verified_index(self.d, self.index, self.jar))
        self.assertIn("tampered", msg or "")

    def test_match_returns_index(self):
        self.entry(self.sha.upper())
        idx, ts = T.load_verified_index(self.d, self.index, self.jar)
        self.assertEqual(idx, {"packages": {"a.b": {}}})
        self.assertEqual(ts, 5)


    def test_parses_the_bytes_it_hashed(self):
        self.entry(self.sha)
        opens = []
        real_open = builtins.open

        def fake_open(path, *a, **kw):
            if path == self.index:
                opens.append(path)
                if len(opens) > 1:
                    return io.BytesIO(b'{"packages": {"swapped": {}}}')
            return real_open(path, *a, **kw)

        T.open = fake_open
        try:
            idx, _ = T.load_verified_index(self.d, self.index, self.jar)
        finally:
            del T.open
        self.assertEqual(idx, {"packages": {"a.b": {}}})
        self.assertEqual(len(opens), 1)


class MainTempDir(unittest.TestCase):
    """main() keeps its fixed-name downloads in a private directory of its own, removed on every exit."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory(dir=ROOT)
        self.addCleanup(tmp.cleanup)
        self.root = tmp.name
        self.tmp = os.path.join(self.root, "tmp")
        os.mkdir(self.tmp)
        self.saved = (os.environ.get("TMPDIR"), tempfile.tempdir, T._fetch, T.verify_entry_jar, sys.argv)
        os.environ["TMPDIR"] = self.tmp
        tempfile.tempdir = None
        self.dests = []
        self.index = json.dumps({"packages": {}}).encode()
        T._fetch = self.fake_fetch
        T.verify_entry_jar = lambda j: None
        self.addCleanup(self.restore)

    def restore(self):
        tm, tempfile.tempdir, T._fetch, T.verify_entry_jar, sys.argv = self.saved
        if tm is None:
            os.environ.pop("TMPDIR", None)
        else:
            os.environ["TMPDIR"] = tm

    def fake_fetch(self, url, dest):
        self.dests.append(dest)
        if dest.endswith(".jar"):
            sha = self.sha or hashlib.sha256(self.index).hexdigest()
            with zipfile.ZipFile(dest, "w") as z:
                z.writestr("entry.json", json.dumps(
                    {"timestamp": 5, "index": {"name": "/index-v2.json", "sha256": sha}}))
        else:
            with open(dest, "wb") as f:
                f.write(self.index)

    def run_main(self):
        sys.argv = ["trim-fdroid-index.py", os.path.join(self.root, "out.json")]
        self.err = io.StringIO()
        with contextlib.redirect_stderr(self.err):
            return _exits(T.main)

    def check_dests(self):
        self.assertEqual(len(self.dests), 2)
        for dest in self.dests:
            d = os.path.dirname(dest)
            self.assertNotEqual(d, tempfile.gettempdir())
            self.assertFalse(os.path.exists(d), "left behind: " + d)
        self.assertEqual(os.listdir(self.tmp), [])

    def test_success_uses_and_removes_a_private_dir(self):
        self.sha = None
        self.assertIsNone(self.run_main())
        self.check_dests()

    def test_fatal_exit_removes_it_too(self):
        self.sha = "0" * 64
        self.assertIn("tampered", self.run_main() or "")
        self.check_dests()

    def test_tally_counts_notsingleapk(self):
        self.sha = None
        self.index = json.dumps({"packages": {"a.b": _pkg(), "c.d": _pkg(name="c.d_1.zip")}}).encode()
        self.assertIsNone(self.run_main())
        self.assertIn("'notsingleapk': 1", self.err.getvalue())
        with open(os.path.join(self.root, "out.json")) as f:
            self.assertEqual([e["pkg"] for e in json.load(f)["entries"]], ["a.b"])


def _pkg(name="a.b_1.apk", signer=SIGNER, sha=SHA, icon=None, native=None, file=None, **extra):
    man = {"versionCode": 1, "versionName": "1.0", "usesSdk": {"minSdkVersion": 21}}
    if signer is not None:
        man["signer"] = {"sha256": [signer]}
    if native:
        man["nativecode"] = native
    meta = {"name": {"en-US": "Ab"}, "summary": {"en-US": " sum "}, "categories": ["Tools"]}
    if icon:
        meta["icon"] = {"en-US": {"name": icon}}
    ver = {"manifest": man, "file": {"name": name, "sha256": sha, "size": 9} if file is None else file}
    ver.update(extra)
    return {"metadata": meta, "versions": {"h": ver}}


class TrimEntry(unittest.TestCase):
    def test_nosigner(self):
        self.assertEqual(T.trim_entry("a.b", _pkg(signer=None), "arm64-v8a")[1], "nosigner")
        self.assertEqual(T.trim_entry("a.b", _pkg(signer="ab" * 31 + "a"), "arm64-v8a")[1], "nosigner")

    def test_nofile(self):
        self.assertEqual(T.trim_entry("a.b", _pkg(name=""), "arm64-v8a")[1], "nofile")
        self.assertEqual(T.trim_entry("a.b", _pkg(sha="ab" * 31), "arm64-v8a")[1], "nofile")

    def test_badurl(self):
        for n in ("../evil.apk", "a/../../x.apk", "x.apk?y", "x.apk#y", "a\\b.apk"):
            self.assertEqual(T.trim_entry("a.b", _pkg(name=n), "arm64-v8a")[1], "badurl", n)

    def test_icon_outside_repo_blanked(self):
        e, why = T.trim_entry("a.b", _pkg(icon="/../x.png"), "arm64-v8a")
        self.assertIsNone(why)
        self.assertEqual(e["iconRef"], "")

    def test_icon_inside_repo_kept(self):
        e, _ = T.trim_entry("a.b", _pkg(icon="/icons/x.png"), "arm64-v8a")
        self.assertEqual(e["iconRef"], "https://f-droid.org/repo/icons/x.png")

    def test_well_formed(self):
        e, why = T.trim_entry("a.b", _pkg(icon="/a.b/en-US/icon.png"), "arm64-v8a")
        self.assertIsNone(why)
        self.assertEqual(e, {
            "pkg": "a.b", "versionCode": 1, "versionName": "1.0", "label": "Ab", "category": "Tools",
            "description": "sum", "sizeBytes": 9, "source": "fdroid", "signingCert": SIGNER.lower(),
            "iconRef": "https://f-droid.org/repo/a.b/en-US/icon.png", "minSdk": 21, "nativecode": [],
            "antiFeatures": [],
            "apks": [{"name": "base.apk", "url": "https://f-droid.org/repo/a.b_1.apk", "sha256": SHA, "size": 9}]})

    def refused(self, pkgobj):
        self.assertEqual(T.trim_entry("a.b", pkgobj, "arm64-v8a"), (None, "notsingleapk"))

    def test_not_an_apk_file_refused(self):
        self.refused(_pkg(name="x.zip"))

    def test_splits_refused(self):
        self.refused(_pkg(splits=["config.arm64_v8a.apk"]))

    def test_other_multi_file_keys_refused(self):
        for k in ("apks", "files", "obbMainFile", "obbPatchFile", "obbMainFileSha256", "obbPatchFileSha256"):
            self.refused(_pkg(**{k: {"name": "/main.obb"} if "Sha" not in k else "ab" * 32}))

    def test_obb_refused(self):
        self.refused(_pkg(obbMainFile={"name": "/main.1.a.b.obb", "sha256": SHA, "size": 5}))

    def test_file_as_list_refused_not_raised(self):
        self.refused(_pkg(file=[{"name": "a.b_1.apk", "sha256": SHA, "size": 9}]))

    def test_multi_file_keys_refused_when_file_is_null_or_absent(self):
        for how in ("null", "absent"):
            for extra in ({"splits": ["config.x.apk"]}, {"obbMainFile": {"name": "/main.obb"}}):
                po = _pkg(**extra)
                for v in po["versions"].values():
                    if how == "null":
                        v["file"] = None
                    else:
                        del v["file"]
                self.refused(po)
        plain = _pkg()
        plain["versions"]["h"]["file"] = None
        self.assertEqual(T.trim_entry("a.b", plain, "arm64-v8a")[1], "nofile")

    def test_uppercase_suffix_and_empty_split_keys_pass(self):
        self.assertIsNone(T.trim_entry("a.b", _pkg(name="a.b_1.APK", splits=[], obbMainFile=None), "arm64-v8a")[1])

    def test_normal_entry_with_src_channels_notes_is_unchanged(self):
        plain = T.trim_entry("a.b", _pkg(), "arm64-v8a")[0]
        rich, why = T.trim_entry("a.b", _pkg(
            added=1, src={"name": "/a.b_1_src.tar.gz", "sha256": SHA, "size": 4}, releaseChannels=["Beta"],
            whatsNew={"en-US": "fixes"}, antiFeatures={}), "arm64-v8a")
        self.assertIsNone(why)
        ser = lambda e: json.dumps(e, separators=(",", ":"))
        self.assertEqual(ser(rich), ser(plain))
        self.assertEqual(ser(rich), json.dumps({
            "pkg": "a.b", "versionCode": 1, "versionName": "1.0", "label": "Ab", "category": "Tools",
            "description": "sum", "sizeBytes": 9, "source": "fdroid", "signingCert": SIGNER.lower(), "iconRef": "",
            "minSdk": 21, "nativecode": [], "antiFeatures": [],
            "apks": [{"name": "base.apk", "url": "https://f-droid.org/repo/a.b_1.apk", "sha256": SHA, "size": 9}]},
            separators=(",", ":")))


class PickVersion(unittest.TestCase):
    def vers(self, *specs):
        return {"versions": {str(i): {"manifest": {"versionCode": 3, "nativecode": nc}, "file": {"name": n}}
                             for i, (n, nc) in enumerate(specs)}}

    def test_abi_match_beats_mismatch(self):
        po = self.vers(("p_3.apk", ["x86"]), ("other.apk", ["arm64-v8a"]))
        self.assertEqual(T.pick_version("p", po, "arm64-v8a")[1]["file"]["name"], "other.apk")

    def test_canonical_name_breaks_tie(self):
        po = self.vers(("other.apk", []), ("p_3.apk", []))
        self.assertEqual(T.pick_version("p", po, "arm64-v8a")[1]["file"]["name"], "p_3.apk")


# name, source fragment, replacement. Each must apply (the fragment must exist) and be convicted.
MUTANTS = [
    ("under_repo is startswith", None, None),
    ("normpath comparison removed",
     '    return u.path.startswith("/repo/") and posixpath.normpath(u.path).startswith("/repo/") \\\n'
     '        and posixpath.normpath(u.path) == u.path\n',
     '    return u.path.startswith("/repo/")\n'),
    ("signer length check removed", "if len(signer) != 64:", "if False:"),
    ("fingerprint comparison removed", "if got != FDROID_REPO_CERT_SHA256:", "if False:"),
    ("index sha256 comparison removed", "if got != idx_sha:", "if False:"),
    ("T1: main's cachedir back to the shared temp dir", "cachedir = tempfile.mkdtemp()", "cachedir = tempfile.gettempdir()"),
    ("T2: rmtree removed", "        shutil.rmtree(cachedir, ignore_errors=True)\n", "        pass\n"),
    ("M1: apk suffix check removed", '    if name and not re.split("[?#]", name)[0].lower().endswith(".apk"):', "    if False:"),
    ("M2: multi-file key check removed", "    if any(v.get(k) for k in NOT_SINGLE_APK_KEYS):", "    if False:"),
    ("M3: guard returns the entry anyway", 'return None, "notsingleapk"', "pass"),
    ("M4: guard also refuses on releaseChannels", 'NOT_SINGLE_APK_KEYS = ("splits",',
     'NOT_SINGLE_APK_KEYS = ("releaseChannels", "splits",'),
    ("T3: index opened a second time for json.load", "    return json.loads(data), int(entry.get(\"timestamp\") or 0)\n",
     "    with open(index_json, \"rb\") as f2:\n        return json.load(f2), int(entry.get(\"timestamp\") or 0)\n"),
]


def mutate():
    with open(SCRIPT) as f:
        src = f.read()
    bad = 0
    with tempfile.TemporaryDirectory(dir=ROOT) as d:
        for name, old, new in MUTANTS:
            if old is None:
                a = src.index("def under_repo(url):")
                b = src.index("def _sh(")
                m = (src[:a] + 'def under_repo(url):\n    return url.startswith(FDROID + "/")\n\n\n' + src[b:])
            else:
                if src.count(old) != 1:
                    print("MUTANT DID NOT APPLY: %s" % name)
                    bad += 1
                    continue
                m = src.replace(old, new)
            p = os.path.join(d, "mut.py")
            with open(p, "w") as f:
                f.write(m)
            r = subprocess.run([sys.executable, "-I", os.path.abspath(__file__)], capture_output=True, text=True,
                               env=dict(os.environ, TRIM_SCRIPT=p, TMPDIR=d))
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
