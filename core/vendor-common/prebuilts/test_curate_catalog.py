"""Executes curate-catalog.py (NWP-20261022-17): the ABI-first version pick, the fail-closed refusal, entry_for's
guards, play_entry, and main()'s category grouping and exit code.

No network and no JDK: main()'s cases replace `load_index` on the loaded module with a fixture, and load_index's
cases stub curate's urlopen and the loaded trim-fdroid-index.py's `_sh` (jarsigner/keytool) with fake output, as
test_trim_fdroid_index.py does. Run from anywhere:
    python3 -I core/vendor-common/prebuilts/test_curate_catalog.py            (what CI runs)
    python3 -I core/vendor-common/prebuilts/test_curate_catalog.py --mutate   (every broken copy must be convicted)
"""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import time
import types
import unittest
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.environ.get("CURATE_SCRIPT") or os.path.join(HERE, "curate-catalog.py")
TRIM = os.path.join(HERE, "trim-fdroid-index.py")


def _load(path):
    spec = importlib.util.spec_from_file_location("curate_catalog_under_test", path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


C = _load(SCRIPT)
ABI = "arm64-v8a"
SHA = "ab" * 32


def ver(pkg, vc, nativecode=None, name=None, sha=SHA, **extra):
    man = {"versionCode": vc, "versionName": "v%d" % vc, "signer": {"sha256": ["AB" * 32]}}
    if nativecode is not None:
        man["nativecode"] = nativecode
    man.update(extra)
    return {"manifest": man, "file": {"name": name if name is not None else "/%s_%d.apk" % (pkg, vc),
                                      "sha256": sha, "size": 1234}}


def pkgobj(versions, **meta):
    return {"versions": {("h%d" % i): v for i, v in enumerate(versions)}, "metadata": meta}


def vcs(pv):
    return pv[0] if pv else None


class PickVersion(unittest.TestCase):
    def test_vlc_per_abi_picks_arm64(self):
        p = "org.videolan.vlc"
        po = pkgobj([ver(p, 13070105, ["armeabi-v7a"]), ver(p, 13070106, ["arm64-v8a"]),
                     ver(p, 13070107, ["x86"]), ver(p, 13070108, ["x86_64"])])
        self.assertEqual(vcs(C.pick_version(p, po, 0, ABI)), 13070106)

    def test_universal_to_split_newest_runnable_wins(self):
        p = "a.b"
        po = pkgobj([ver(p, 10), ver(p, 11, ["arm64-v8a"])])
        self.assertEqual(vcs(C.pick_version(p, po, 0, ABI)), 11)

    def test_universal_beats_arm64_at_same_versioncode(self):
        p = "a.b"
        uni = ver(p, 10, name="/u_10.apk")
        arm = ver(p, 10, ["arm64-v8a"], name="/a_10.apk")
        for order in ([uni, arm], [arm, uni]):
            got = C.pick_version(p, pkgobj(order), 0, ABI)
            self.assertEqual(got[1]["file"]["name"], "/u_10.apk")

    def test_canonical_file_beats_variant_in_both_orders(self):
        p = "a.b"
        canon = ver(p, 10)
        variant = ver(p, 10, name="/%s_10_cb84069.apk" % p)
        for order in ([canon, variant], [variant, canon]):
            got = C.pick_version(p, pkgobj(order), 0, ABI)
            self.assertEqual(got[1]["file"]["name"], "/a.b_10.apk")

    def test_only_foreign_abi_refuses(self):
        p = "a.b"
        po = pkgobj([ver(p, 1, ["x86"]), ver(p, 2, ["x86_64"])])
        with self.assertRaises(SystemExit) as cm:
            C.pick_version(p, po, 0, ABI)
        self.assertIn(p, str(cm.exception.code))
        self.assertIn("refusing", str(cm.exception.code))

    def test_absent_pinned_versioncode(self):
        p = "a.b"
        self.assertIsNone(C.pick_version(p, pkgobj([ver(p, 1), ver(p, 2)]), 3, ABI))


class EntryFor(unittest.TestCase):
    def test_nameless_file_refused(self):
        v = ver("a.b", 1)
        v["file"]["name"] = ""
        self.assertIsNone(C.entry_for("a.b", 0, pkgobj([v]), ABI))

    def test_short_sha_refused(self):
        v = ver("a.b", 1, sha="a" * 63)
        self.assertIsNone(C.entry_for("a.b", 0, pkgobj([v]), ABI))

    def test_good_entry(self):
        v = ver("a.b", 7)
        po = pkgobj([v], name={"en-US": "Ab"}, summary={"en": " sum "}, categories=["Tools"],
                    icon={"en-US": {"name": "/a.b/icon.png"}})
        e = C.entry_for("a.b", 0, po, ABI)
        self.assertEqual(e["apks"][0]["url"], C.FDROID + "/a.b_7.apk")
        self.assertEqual(e["apks"][0]["sha256"], SHA)
        self.assertEqual(e["sizeBytes"], 1234)
        self.assertEqual(e["signingCert"], "ab" * 32)
        self.assertEqual(e["iconRef"], C.FDROID + "/a.b/icon.png")
        self.assertEqual((e["label"], e["category"], e["description"], e["source"]),
                         ("Ab", "Tools", "sum", "fdroid"))


class SignerRequired(unittest.TestCase):
    def bad(self, **kw):
        v = ver("a.b", 1)
        if kw:
            v["manifest"].update(kw)
        else:
            del v["manifest"]["signer"]
        return v

    def refused(self, v):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            got = C.entry_for("a.b", 0, pkgobj([v]), ABI)
        self.assertIsNone(got)
        self.assertIn("a.b vc=1 carries no 64-hex signer", err.getvalue())

    def test_no_signer_key(self):
        self.refused(self.bad())

    def test_empty_list(self):
        self.refused(self.bad(signer={"sha256": []}))

    def test_63_char_signer(self):
        self.refused(self.bad(signer={"sha256": ["a" * 63]}))

    def test_non_string_signer(self):
        self.refused(self.bad(signer={"sha256": [12345]}))

    def test_non_hex_signer(self):
        self.refused(self.bad(signer={"sha256": ["z" * 64]}))


class PlayEntry(unittest.TestCase):
    def test_full(self):
        e = C.play_entry("p.q|Label|Cat|Desc")
        self.assertEqual((e["pkg"], e["label"], e["category"], e["description"], e["source"], e["apks"]),
                         ("p.q", "Label", "Cat", "Desc", "play", []))

    def test_bare_pkg(self):
        e = C.play_entry("p.q")
        self.assertEqual((e["label"], e["category"]), ("p.q", "Apps"))

    def test_empty(self):
        self.assertIsNone(C.play_entry(""))


class Main(unittest.TestCase):
    def run_main(self, index, specs):
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "catalog.json")
            saved_argv, saved_load = sys.argv, C.load_index
            sys.argv = ["curate-catalog.py", out] + specs
            C.load_index = lambda: index
            try:
                with contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit) as cm:
                        C.main()
            finally:
                sys.argv, C.load_index = saved_argv, saved_load
            with open(out, "rb") as f:
                raw = f.read()
        return cm.exception.code, raw

    def test_categories_contiguous(self):
        pk = {}
        for name, cat in (("p.one", "A"), ("p.two", "B"), ("p.three", "A")):
            pk[name] = pkgobj([ver(name, 1)], categories=[cat])
        code, raw = self.run_main({"packages": pk}, ["p.one", "p.two", "p.three"])
        self.assertEqual(code, 0)
        got = [e["pkg"] for e in json.loads(raw)["entries"]]
        self.assertEqual(got, ["p.one", "p.three", "p.two"])

    def test_miss_exits_1_and_keeps_others(self):
        pk = {"p.one": pkgobj([ver("p.one", 1)])}
        code, raw = self.run_main({"packages": pk}, ["p.one", "p.gone"])
        self.assertEqual(code, 1)
        self.assertEqual([e["pkg"] for e in json.loads(raw)["entries"]], ["p.one"])
        self.assertTrue(raw.endswith(b"\n"))
        self.assertNotIn(b"\r", raw)

    def test_unsigned_package_refused_good_one_written(self):
        bad = ver("p.bad", 1)
        del bad["manifest"]["signer"]
        pk = {"p.good": pkgobj([ver("p.good", 1)]), "p.bad": pkgobj([bad])}
        code, raw = self.run_main({"packages": pk}, ["p.good", "p.bad"])
        self.assertEqual(code, 1)
        self.assertEqual([e["pkg"] for e in json.loads(raw)["entries"]], ["p.good"])


FRESH = {"packages": {"from.download": {}}}
PLANTED = {"packages": {"planted.by.someone": {}}}


def raw(index):
    return json.dumps(index).encode()                           # what plant() writes and fake_urlopen serves


def sha(index):
    return hashlib.sha256(raw(index)).hexdigest()


def jar_bytes(index_sha, entry=None):
    """A real zip holding entry.json, as F-Droid's entry.jar does (the signature itself is stubbed)."""
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("entry.json", json.dumps(entry or {"timestamp": 5, "index": {"name": "/index-v2.json",
                                                                               "sha256": index_sha}}))
    return buf.getvalue()


def fake_sh(jarsigner="jar verified.\n", fp=None):
    out = {"jarsigner": jarsigner, "keytool": "Certificate fingerprints:\n\t SHA256: %s\n"
           % ":".join(fp[i:i + 2].upper() for i in range(0, len(fp), 2))}
    return lambda *args: types.SimpleNamespace(stdout=out[args[0]], stderr="")


class LoadIndex(unittest.TestCase):
    """load_index verifies the index against entry.jar and the pinned cert; its cache is private and owner-only;
    nothing is read from or written to the shared temp dir."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = tmp.name
        self.tmp = os.path.join(self.root, "tmp")
        self.cache = os.path.join(self.root, "cache")
        os.mkdir(self.tmp)
        self.saved = (os.environ.get("TMPDIR"), os.environ.get("NOWHERE_FDROID_CACHE"), tempfile.tempdir,
                      C.urllib.request.urlopen, C.os, C._TRIM, os.environ.get("NOWHERE_TRIM_SCRIPT"))
        os.environ["TMPDIR"] = self.tmp
        os.environ["NOWHERE_FDROID_CACHE"] = self.cache
        tempfile.tempdir = None
        C._TRIM = None
        self.pin = C._trim().FDROID_REPO_CERT_SHA256
        self.set_sh()
        self.calls = 0                                          # INDEX downloads only
        self.jar_calls = 0
        self.signed = FRESH                                     # the index entry.json's sha256 is taken from
        self.signed_sha = None                                  # ... unless this overrides it
        self.jar = None                                         # ... or this replaces the whole jar
        self.served = raw(FRESH)
        C.urllib.request.urlopen = self.fake_urlopen
        self.addCleanup(self.restore)

    def set_sh(self, **kw):
        kw.setdefault("fp", self.pin)
        C._trim()._sh = fake_sh(**kw)

    def restore(self):
        tm, ca, tempfile.tempdir, C.urllib.request.urlopen, C.os, C._TRIM, tr = self.saved
        for k, v in (("TMPDIR", tm), ("NOWHERE_FDROID_CACHE", ca), ("NOWHERE_TRIM_SCRIPT", tr)):
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def fake_urlopen(self, url, timeout=None):
        if url.endswith("entry.jar"):
            self.jar_calls += 1
            return io.BytesIO(self.jar or jar_bytes(self.signed_sha or sha(self.signed)))
        self.calls += 1
        return io.BytesIO(self.served)

    def load(self):
        with contextlib.redirect_stderr(io.StringIO()):
            return C.load_index()

    def refused(self):
        with self.assertRaises(SystemExit) as cm:
            self.load()
        self.assertEqual(os.listdir(self.tmp), [])
        return str(cm.exception.code)

    def plant(self, path, index, mode=0o600):
        with open(path, "w") as f:
            json.dump(index, f)
        os.chmod(path, mode)

    def good_cache(self, index=PLANTED):
        os.mkdir(self.cache, 0o700)
        path = os.path.join(self.cache, "fdroid-index-v2.json")
        self.plant(path, index)
        return path

    def test_verified_pair_is_accepted(self):
        self.assertEqual(self.load(), FRESH)
        self.assertEqual((self.calls, self.jar_calls), (1, 1))
        self.assertEqual(os.listdir(self.tmp), [])

    def test_tampered_index_refused_and_not_cached(self):
        self.signed_sha = sha(PLANTED)                          # entry.json signs other bytes than are served
        self.assertIn("tampered", self.refused())
        self.assertFalse(os.path.lexists(os.path.join(self.cache, "fdroid-index-v2.json")))

    def test_wrong_cert_refused_before_index_fetch(self):
        self.set_sh(fp="00" * 32)
        self.assertIn("!= pinned", self.refused())
        self.assertEqual(self.calls, 0)

    def test_unsigned_jar_refused(self):
        self.set_sh(jarsigner="jar is unsigned.\n")
        self.assertIn("did not verify", self.refused())
        self.assertEqual(self.calls, 0)

    def test_unverified_jar_refused(self):
        self.set_sh(jarsigner="something else\n")
        self.assertIn("did not verify", self.refused())
        self.assertEqual(self.calls, 0)

    def test_malformed_entry_json_is_fatal(self):
        for entry in ({"timestamp": 5}, {"index": {"name": "/index-v2.json", "sha256": "a" * 63}}):
            self.jar = jar_bytes(None, entry)
            self.refused()
            self.assertEqual(self.calls, 0)

    def test_missing_trim_script_is_fatal(self):
        C._TRIM = None
        os.environ["NOWHERE_TRIM_SCRIPT"] = os.path.join(self.root, "no-such-trim.py")
        self.assertIn("cannot load the entry.jar verifier", self.refused())
        self.assertEqual((self.calls, self.jar_calls), (0, 0))

    @unittest.skipUnless(hasattr(os, "getuid"), "owner check needs getuid")
    def test_fresh_cache_not_matching_signed_sha_is_redownloaded(self):
        path = self.good_cache(PLANTED)                         # ours and private, but not the signed bytes
        self.assertEqual(self.load(), FRESH)
        self.assertEqual(self.calls, 1)
        with open(path) as f:
            self.assertEqual(json.load(f), FRESH)

    @unittest.skipUnless(hasattr(os, "getuid"), "owner check needs getuid")
    def test_fresh_cache_matching_signed_sha_is_reused(self):
        self.good_cache(FRESH)
        self.assertEqual(self.load(), FRESH)
        self.assertEqual((self.calls, self.jar_calls), (0, 1))

    @unittest.skipUnless(hasattr(os, "getuid"), "owner check needs getuid")
    def test_group_writable_cache_dir_holding_signed_bytes_is_not_reused(self):
        self.good_cache(FRESH)
        os.chmod(self.cache, 0o770)
        self.assertEqual(self.load(), FRESH)
        self.assertEqual(self.calls, 1)

    def test_planted_file_in_shared_tmp_is_not_read(self):
        self.plant(os.path.join(tempfile.gettempdir(), "fdroid-index-v2.json"), FRESH)   # signed: only the dir rule refuses
        self.assertEqual(self.load(), FRESH)
        self.assertEqual(self.calls, 1)

    @unittest.skipUnless(hasattr(os, "getuid"), "owner check needs getuid")
    def test_good_own_cache_is_reused(self):
        self.signed = PLANTED
        self.good_cache()
        self.assertEqual(self.load(), PLANTED)
        self.assertEqual(self.calls, 0)

    @unittest.skipUnless(hasattr(os, "getuid"), "owner check needs getuid")
    def test_stale_cache_is_downloaded(self):
        path = self.good_cache(FRESH)                           # signed bytes: only staleness refuses it
        old = time.time() - 7 * 3600
        os.utime(path, (old, old))
        self.assertEqual(self.load(), FRESH)
        self.assertEqual(self.calls, 1)

    @unittest.skipUnless(hasattr(os, "getuid"), "owner check needs getuid")
    def test_world_writable_cache_is_downloaded(self):
        os.chmod(self.good_cache(FRESH), 0o666)
        self.assertEqual(self.load(), FRESH)
        self.assertEqual(self.calls, 1)

    @unittest.skipUnless(hasattr(os, "getuid"), "owner check needs getuid")
    def test_symlink_in_place_of_cache_is_downloaded(self):
        os.mkdir(self.cache, 0o700)
        target = os.path.join(self.root, "elsewhere.json")
        self.plant(target, FRESH)
        os.symlink(target, os.path.join(self.cache, "fdroid-index-v2.json"))
        self.assertEqual(self.load(), FRESH)
        self.assertEqual(self.calls, 1)

    @unittest.skipUnless(hasattr(os, "getuid"), "owner check needs getuid")
    def test_directory_in_place_of_cache_is_downloaded(self):
        os.mkdir(self.cache, 0o700)
        os.mkdir(os.path.join(self.cache, "fdroid-index-v2.json"), 0o700)
        self.assertEqual(self.load(), FRESH)
        self.assertEqual(self.calls, 1)

    @unittest.skipUnless(hasattr(os, "getuid"), "owner check needs getuid")
    def test_group_writable_cache_dir_is_not_trusted(self):
        self.good_cache()
        os.chmod(self.cache, 0o770)
        self.assertEqual(self.load(), FRESH)
        self.assertEqual(self.calls, 1)
        self.assertEqual(os.listdir(self.cache), ["fdroid-index-v2.json"])
        with open(os.path.join(self.cache, "fdroid-index-v2.json")) as f:
            self.assertEqual(json.load(f), PLANTED)             # a shared dir is never written to either

    @unittest.skipUnless(hasattr(os, "getuid"), "owner check needs getuid")
    def test_download_leaves_a_private_dir_holding_only_the_index(self):
        self.assertEqual(self.load(), FRESH)
        self.assertEqual(os.stat(self.cache).st_mode & 0o777, 0o700)
        self.assertEqual(os.listdir(self.cache), ["fdroid-index-v2.json"])
        self.assertEqual(os.listdir(self.tmp), [])
        self.assertEqual(self.load(), FRESH)                    # and the cache it wrote is then reused
        self.assertEqual(self.calls, 1)

    def test_no_getuid_never_reuses_a_cache(self):
        self.good_cache(FRESH)
        view = types.SimpleNamespace(**{k: getattr(os, k) for k in dir(os) if k != "getuid"})
        C.os = view
        self.assertEqual(self.load(), FRESH)
        self.assertEqual(self.calls, 1)


MUTANTS = [
    ("versionCode ranked above runnable", "return (runnable, vc, universal, canon_s)",
     "return (vc, runnable, universal, canon_s)"),
    ("universal ranked above versionCode", "return (runnable, vc, universal, canon_s)",
     "return (runnable, universal, vc, canon_s)"),
    ("canonical-file tie-break removed", "return (runnable, vc, universal, canon_s)",
     "return (runnable, vc, universal)"),
    ("fail-closed exit removed", "if nc and abi not in nc:", "if False:"),
    ("64-character sha check removed", "if not name or len(sha) != 64:", "if not name:"),
    ("signer refusal removed", "        return None\n    signer = signer.lower()",
     "        signer = str(signer or \"\")\n    signer = signer.lower()"),
    ("category grouping sort removed", "    entries.sort(key=lambda e: order[e.get(\"category\", \"\")])\n", ""),
    ("C1: cache back in the shared temp dir",
     'd = os.environ.get("NOWHERE_FDROID_CACHE") or os.path.join(os.path.expanduser("~"), ".cache", "nowhere-fdroid")',
     'd = tempfile.gettempdir()'),
    ("C2: owner/mode check removed", "if fs.st_uid != uid or fs.st_mode & 0o022:", "if False:"),
    ("C3: regular-file check removed", "if not stat.S_ISREG(fs.st_mode):", "if False:"),
    ("V1: verify_entry_jar call deleted", "        t.verify_entry_jar(jar)\n", ""),
    ("V2: download sha256 comparison deleted", "if got != sha:", "if False:"),
    ("V3: cache reused without the hash check", "if hashlib.sha256(data).hexdigest() != sha:", "if False:"),
    ("V4: missing trim script falls back to the unverified download",
     'sys.exit("FATAL cannot load the entry.jar verifier %s: %s" % (path, type(e).__name__))',
     'm = __import__("types").SimpleNamespace(verify_entry_jar=lambda j: None, FDROID_REPO_CERT_SHA256="")'),
    ("V5: parsed bytes re-read from disk after hashing", "return json.loads(data)",
     'return json.load(open(cache, "rb"))'),
]


def mutate():
    with open(SCRIPT) as f:
        src = f.read()
    bad = 0
    with tempfile.TemporaryDirectory() as d:
        for name, old, new in MUTANTS:
            if src.count(old) != 1:
                print("MUTANT DID NOT APPLY: %s" % name)
                bad += 1
                continue
            p = os.path.join(d, "mut.py")
            with open(p, "w") as f:
                f.write(src.replace(old, new))
            r = subprocess.run([sys.executable, "-I", os.path.abspath(__file__)], capture_output=True, text=True,
                               env=dict(os.environ, CURATE_SCRIPT=p, NOWHERE_TRIM_SCRIPT=TRIM, TMPDIR=d))
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
