"""Executes publish-nowhere-app.py (NWP-20261029-13): --merge refuses an entry whose signingCert is not 64 hex
characters BEFORE the catalog is opened for writing; print mode still prints the entry and exits 0.

No network, no apksigner: `signer_sha256` is replaced on the loaded module. Run from anywhere:
    python3 -I core/vendor-common/prebuilts/test_publish_nowhere_app.py            (what CI runs)
    python3 -I core/vendor-common/prebuilts/test_publish_nowhere_app.py --mutate   (every broken copy must be convicted)
"""
import contextlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.environ.get("PUBLISH_SCRIPT") or os.path.join(HERE, "publish-nowhere-app.py")


def _load(path):
    spec = importlib.util.spec_from_file_location("publish_nowhere_app_under_test", path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


P = _load(SCRIPT)
GOOD = "cd" * 32
OLD = {"pkg": "com.nowhere.app", "versionCode": 1, "label": "old", "source": "nowhere", "signingCert": GOOD}
OTHER = {"pkg": "org.other", "versionCode": 5, "label": "other", "source": "fdroid", "signingCert": "ab" * 32}


class Publish(unittest.TestCase):
    def setUp(self):
        self._td = tempfile.TemporaryDirectory()
        self.addCleanup(self._td.cleanup)
        self.d = self._td.name
        self.apk = os.path.join(self.d, "app.apk")
        with open(self.apk, "wb") as f:
            f.write(b"not a real apk")
        self.cat = os.path.join(self.d, "catalog.json")
        with open(self.cat, "w", newline="\n") as f:
            json.dump({"entries": [OTHER, OLD]}, f, indent=2)
            f.write("\n")
        saved = P.signer_sha256
        self.addCleanup(setattr, P, "signer_sha256", saved)

    def run_main(self, signer, merge):
        P.signer_sha256 = lambda apk: signer
        argv = [os.path.basename(SCRIPT), self.apk, "--pkg", "com.nowhere.app", "--label", "New",
                "--version-code", "2", "--base-url", "https://example.invalid/nowhere/apps"]
        if merge:
            argv += ["--merge", self.cat]
        saved_argv, sys.argv = sys.argv, argv
        out, err = io.StringIO(), io.StringIO()
        code = 0
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                P.main()
        except SystemExit as e:
            code = e.code if e.code is not None else 0
        finally:
            sys.argv = saved_argv
        return code, out.getvalue()

    def catalog_bytes(self):
        with open(self.cat, "rb") as f:
            return f.read()

    def refused(self, signer):
        before = self.catalog_bytes()
        code, _ = self.run_main(signer, True)
        self.assertNotIn(code, (0, None))
        self.assertIn("sign", str(code))
        self.assertEqual(self.catalog_bytes(), before)

    def test_merge_empty_signer_refused(self):
        self.refused("")

    def test_merge_40_char_signer_refused(self):
        self.refused("a" * 40)

    def test_merge_good_signer_replaces_same_pkg(self):
        code, _ = self.run_main(GOOD, True)
        self.assertEqual(code, 0)
        raw = self.catalog_bytes()
        self.assertTrue(raw.endswith(b"\n"))
        self.assertNotIn(b"\r", raw)
        entries = json.loads(raw)["entries"]
        self.assertEqual([e["pkg"] for e in entries], ["org.other", "com.nowhere.app"])
        self.assertEqual(entries[1]["label"], "New")
        self.assertEqual(entries[1]["signingCert"], GOOD)

    def test_print_mode_empty_signer_prints_entry(self):
        before = self.catalog_bytes()
        code, out = self.run_main("", False)
        self.assertEqual(code, 0)
        e = json.loads(out)
        self.assertEqual((e["pkg"], e["source"], e["signingCert"]), ("com.nowhere.app", "nowhere", ""))
        self.assertEqual(self.catalog_bytes(), before)


MUTANTS = [
    ("merge refusal removed", "        if not is_hex64(signer):\n", "        if False:\n"),
    ("refusal placed after the catalog is written",
     "        if not is_hex64(signer):\n            sys.exit(",
     "        if False:\n            sys.exit("),
    ("length check reduced to non-empty", "len(s) == 64 and all(", "len(s) > 0 and all("),
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
            mutated = src.replace(old, new)
            if name.startswith("refusal placed after"):
                # the same refusal, run only once the catalog has been rewritten
                tail = ('        sys.stderr.write("merged %s into %s (%d entries)\\n"')
                if mutated.count(tail) != 1:
                    print("MUTANT DID NOT APPLY: %s" % name)
                    bad += 1
                    continue
                mutated = mutated.replace(tail, '        if not is_hex64(signer):\n            sys.exit("late")\n' + tail)
            p = os.path.join(d, "mut.py")
            with open(p, "w") as f:
                f.write(mutated)
            r = subprocess.run([sys.executable, "-I", os.path.abspath(__file__)], capture_output=True, text=True,
                               env=dict(os.environ, PUBLISH_SCRIPT=p, TMPDIR=d))
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
