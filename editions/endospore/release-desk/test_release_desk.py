#!/usr/bin/env python3
"""Pins release_desk.py, the Release Desk read-only (docs/release-desk.md §7 stage 4, NWP-20261202-24).

    python3 editions/endospore/release-desk/test_release_desk.py            the suite
    python3 editions/endospore/release-desk/test_release_desk.py --mutate   every broken copy must be convicted

The real handler runs on 127.0.0.1 in a thread, against a fixture tree with stub sign-release.sh, verify-release.sh
and agent. The agent stub accepts only the fixture's good signature over the fixture's manifest and records its argv.
Every file lives under ONE temp root, removed on every exit (a pass, a failure, --mutate). No test sleeps: the busy
case waits on a FIFO with a 10 s bound that only a failure reaches.
"""

import base64
import contextlib
import io
import hashlib
import http.client
import importlib.util
import json
import os
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
DESK_PATH = os.environ.get("RELEASE_DESK_PATH") or os.path.join(HERE, "release_desk.py")
ROOT = tempfile.mkdtemp(prefix="release-desk-test.")
tempfile.tempdir = ROOT
os.environ["TMPDIR"] = ROOT

try:
    _spec = importlib.util.spec_from_file_location("release_desk", DESK_PATH)
    desk = importlib.util.module_from_spec(_spec)
    _spec.loader.exec_module(desk)
except BaseException:
    shutil.rmtree(ROOT, ignore_errors=True)
    raise

NAME = "desk.example.ts.net"
LOGIN = "chester@example.com"
GOOD = {"Host": NAME, "Tailscale-User-Login": LOGIN, "Origin": "https://" + NAME}
BN = "2026112001"
COMMIT = "3f2a9c1d"
VERSION = "0.5.60"
GOOD_SIG = "R" * 86
MARKER = "zz-manifest-marker-1773"

SIGN_STUB = r"""#!/bin/bash
printf '%s\n' "$*" > "$FIX/sign.argv"
cat "$FIX/pf.stdout"
cat "$FIX/pf.stderr" >&2
if [ -e "$FIX/block" ]; then
  exec 3<>"$FIX/started.fifo"; printf x >&3
  i=0; while [ ! -e "$FIX/release" ] && [ $i -lt 200 ]; do sleep 0.05; i=$((i+1)); done
  [ -e "$FIX/release" ] || exit 3
fi
exit "$(cat "$FIX/pf.rc")"
"""

VERIFY_STUB = r"""#!/bin/bash
printf '%s\n' "$*" > "$FIX/verify.argv"
printf '%s\n' "$TREE" > "$FIX/verify.tree"
cat "$FIX/vf.stdout"
exit "$(cat "$FIX/vf.rc")"
"""

AGENT_STUB = r"""#!/bin/bash
( IFS=$'\x1f'; printf '%s\n' "$*" ) >> "$FIX/agent.argv"
if [ -e "$FIX/agentblock" ]; then
  ok=1; [ "$(cat "$3")" = "$(cat "$FIX/good.sig")" ] && cmp -s "$2" "$FIX/good.manifest" || ok=0
  exec 3<>"$FIX/agent.fifo"; printf x >&3
  i=0; while [ ! -e "$FIX/agentgo" ] && [ $i -lt 200 ]; do sleep 0.05; i=$((i+1)); done
  [ -e "$FIX/agentgo" ] && [ $ok = 1 ] && { echo "ota-release-check: ok"; exit 0; }
  exit 1
fi
if [ "$(cat "$3")" = "$(cat "$FIX/good.sig")" ] && cmp -s "$2" "$FIX/good.manifest"; then
  echo "ota-release-check: $4 $5 severity - published 2026-11-20 due-if-seen-today -"; exit 0
fi
echo "ota-release-check: $2: the release signature does not verify"; exit 1
"""


def write(path, data, mode=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb" if isinstance(data, bytes) else "w") as f:
        f.write(data)
    if mode is not None:
        os.chmod(path, mode)


def read(path, mode="r"):
    with open(path, mode) as f:
        return f.read()


class DeskTest(unittest.TestCase):
    def setUp(self):
        self.fix = tempfile.mkdtemp(dir=ROOT)
        f = self.fix
        self.repo, self.tree, self.state = f + "/repo", f + "/tree", f + "/state"
        self.agent = f + "/agent"
        b = self.repo + "/editions/endospore/build"
        write(b + "/sign-release.sh", SIGN_STUB, 0o755)
        write(b + "/verify-release.sh", VERIFY_STUB, 0o755)
        os.makedirs(self.repo + "/editions/endospore/ota-mandatory")
        write(self.agent, AGENT_STUB, 0o755)
        write(f + "/good.sig", GOOD_SIG)
        self.devs = ["lynx", "tokay"]
        for d in self.devs:
            zip_bytes = os.urandom(4096)
            write(self.webfactory(d), zip_bytes)
            write(self.manifest(d), self.manifest_bytes(zip_bytes))
        write(f + "/good.manifest", read(self.manifest("lynx"), "rb"))
        write(f + "/pf.stdout", "")
        write(f + "/pf.stderr", "the script's own words\n")
        write(f + "/pf.rc", "0")
        write(f + "/vf.stdout", "")
        write(f + "/vf.rc", "0")
        self.old_env = dict(os.environ)
        os.environ.update({"NOWHERE_DESK_STATE": self.state, "ENDOSPORE_TREE": self.tree,
                           "ENDOSPORE_REPO": self.repo, "NOWHERE_AGENT": self.agent, "FIX": f})
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(desk.cmd_open([BN, COMMIT, "lynx", "tokay:out-x"]), 0)
        self.srv = desk.make_server(NAME, 0, 900)
        self.port = self.srv.server_address[1]
        self.thr = threading.Thread(target=self.srv.serve_forever, args=(0.05,), daemon=True)
        self.thr.start()

    def tearDown(self):
        write(self.fix + "/release", "")
        self.srv.shutdown()
        self.srv.server_close()
        os.environ.clear()
        os.environ.update(self.old_env)

    # ---- fixture helpers ----
    def rel(self, d):
        return "%s/releases/%s/release-%s-%s" % (self.tree, BN, d, BN)

    def manifest(self, d):
        return "%s/%s-manifest-%s.json" % (self.rel(d), d, BN)

    def sig(self, d):
        return self.manifest(d) + ".sig"

    def webfactory(self, d):
        return "%s/%s-webfactory-%s.zip" % (self.rel(d), d, BN)

    @staticmethod
    def manifest_bytes(zip_bytes, extra=""):
        m = {"edition": "endospore", "build": BN, "notes": MARKER,
             "images": [{"partition": "factory", "size": len(zip_bytes),
                         "sha256": hashlib.sha256(zip_bytes).hexdigest()}],
             "ota": {"version": VERSION, "severity": "ordinary"}}
        return (json.dumps(m, indent=1) + extra + "\n").encode()

    def req(self, method, path, headers=None, body=None):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=30)
        h = dict(GOOD if headers is None else headers)
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
            h.setdefault("Content-Type", "application/json")
        c.putrequest(method, path, skip_host=True, skip_accept_encoding=True)
        for k, v in h.items():
            c.putheader(k, v)
        if body is not None or method == "POST":
            c.putheader("Content-Length", str(len(body or b"")))
        c.endheaders(body)
        r = c.getresponse()
        data = r.read()
        c.close()
        return r.status, dict((k.lower(), v) for k, v in r.getheaders()), data

    def post_sig(self, sig=GOOD_SIG, dev="lynx", headers=None):
        st, h, d = self.req("POST", "/api/signatures", headers, {"bn": BN, "device": dev, "sig": sig})
        return st, json.loads(d)

    def pf(self, stdout, rc=0):
        write(self.fix + "/pf.stdout", stdout)
        write(self.fix + "/pf.rc", str(rc))
        st, _, d = self.req("POST", "/api/release/%s/preflight" % BN)
        self.assertEqual(st, 200, d)
        return json.loads(d)

    def page(self):
        st, _, d = self.req("GET", "/release/" + BN)
        self.assertEqual(st, 200)
        return d.decode()

    def rstate(self):
        rec = desk.load_release(BN)
        return desk.release_state(rec)

    def agent_calls(self):
        p = self.fix + "/agent.argv"
        return read(p).splitlines() if os.path.exists(p) else []

    def log(self):
        return [json.loads(l) for l in read(self.state + "/log.jsonl").splitlines()]

    def verify_all_pass(self):
        write(self.fix + "/vf.stdout", "head\n== lynx ==\n    ok    a\n== tokay ==\n    ok    b\n")
        st, _, d = self.req("POST", "/api/release/%s/verify" % BN)
        self.assertEqual(json.loads(d)["devices"], {"lynx": "pass", "tokay": "pass"})

    ALL_OK = "PREFLIGHT\tOK\t-\tcommit\tcommit found\nPREFLIGHT\tOK\tlynx\tsource-commit\tat 3f2a9c1\n" \
             "PREFLIGHT\tOK\ttokay\tkeys\tkeys complete\n"

    # ---- the gate ----
    def test_no_login_header_is_403(self):
        h = dict(GOOD)
        del h["Tailscale-User-Login"]
        self.assertEqual(self.req("GET", "/", h)[0], 403)
        self.assertEqual(self.req("GET", "/")[0], 200)

    def test_wrong_host_is_403(self):
        self.assertEqual(self.req("GET", "/", dict(GOOD, Host="evil.example"))[0], 403)
        self.assertEqual(self.req("GET", "/", dict(GOOD, Host="127.0.0.1:%d" % self.port))[0], 200)

    def test_cross_origin_post_to_preflight_is_403(self):
        p = "/api/release/%s/preflight" % BN
        self.assertEqual(self.req("POST", p, dict(GOOD, Origin="https://evil.example"))[0], 403)
        h = dict(GOOD)
        del h["Origin"]
        self.assertEqual(self.req("POST", p, h)[0], 403)
        self.assertFalse(os.path.exists(self.fix + "/sign.argv"))

    def test_open_refusals(self):
        for argv in (["202611200", COMMIT, "lynx"], ["2026112099", COMMIT, "Lynx"],
                     ["2026112099", COMMIT, "lynx", "lynx"], ["2026112099", COMMIT, "lynx:"],
                     ["2026112099", "xyz", "lynx"], ["2026112099", "abcdef", "lynx"],
                     ["2026112099", "a" * 41, "lynx"], ["2026112099", COMMIT]):
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(desk.cmd_open(argv), 2, argv)
        self.assertEqual(os.listdir(self.state + "/releases"), [BN + ".json"])
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(desk.cmd_open([BN, COMMIT, "lynx"]), 1)
        rec = json.loads(read(self.state + "/releases/%s.json" % BN))
        self.assertEqual(rec["devices"], [{"device": "lynx"}, {"device": "tokay", "out": "out-x"}])
        self.assertEqual(os.stat(self.state).st_mode & 0o777, 0o700)

    # ---- preflight ----
    def test_preflight_all_ok_is_ready(self):
        r = self.pf(self.ALL_OK + "PREFLIGHT\tPASS\n")
        self.assertTrue(r["ready"])
        self.assertEqual(self.rstate(), "ready to sign")
        self.assertEqual(read(self.fix + "/sign.argv").strip(), "--preflight-only %s %s lynx tokay:out-x" % (BN, COMMIT))

    def test_rc0_with_one_fail_line_is_not_ready(self):
        r = self.pf(self.ALL_OK + "PREFLIGHT\tFAIL\tlynx\tsource-commit\tHEAD is 9b10e44\nPREFLIGHT\tPASS\n")
        self.assertFalse(r["ready"])
        self.assertEqual(self.rstate(), "waiting for preflight")
        self.assertIn(desk.CHECK_WORDS["source-commit"].replace("'", "&#x27;"), self.page())

    def test_warn_is_not_red(self):
        r = self.pf(self.ALL_OK + "PREFLIGHT\tWARN\ttokay\ttmpdir\t21 GiB free\nPREFLIGHT\tPASS\n")
        self.assertTrue(r["ready"])
        self.assertIn("<tr class=warn>", self.page())

    def test_garbled_line_is_red(self):
        r = self.pf(self.ALL_OK + "PREFLIGHT OK lynx keys spaces-not-tabs\nPREFLIGHT\tPASS\n")
        self.assertFalse(r["ready"])
        self.assertFalse(r["readable"])
        self.assertIn("could not be read", self.page())
        r = self.pf(self.ALL_OK)
        self.assertFalse(r["ready"])
        self.assertFalse(r["readable"])

    def test_rc1_is_red(self):
        r = self.pf(self.ALL_OK + "PREFLIGHT\tPASS\n", rc=1)
        self.assertFalse(r["ready"])
        self.assertFalse(r["readable"])
        self.assertIn("could not be read", self.page())

    def test_unknown_id_shows_script_text(self):
        self.pf(self.ALL_OK + "PREFLIGHT\tFAIL\t-\tnewcheck\tthe new check says no\nPREFLIGHT\tREFUSED\t1\n", rc=1)
        self.assertIn("the new check says no", self.page())

    def test_second_child_is_409(self):
        self.req("GET", "/api/manifests")
        fifo = self.fix + "/started.fifo"
        os.mkfifo(fifo)
        write(self.fix + "/block", "")
        write(self.fix + "/pf.stdout", self.ALL_OK + "PREFLIGHT\tPASS\n")
        fd = os.open(fifo, os.O_RDONLY | os.O_NONBLOCK)
        first = []
        t = threading.Thread(target=lambda: first.append(self.req("POST", "/api/release/%s/preflight" % BN)))
        try:
            t.start()
            r, _, _ = select.select([fd], [], [], 10)
            if not r:
                self.fail("the preflight child did not start within 10 s (first reply: %r)" % first)
            self.assertEqual(os.read(fd, 1), b"x")
            st, _, d = self.req("POST", "/api/release/%s/verify" % BN)
            self.assertEqual((st, json.loads(d)), (409, {"error": "busy"}))
            self.assertEqual(self.post_sig()[0], 409)
            self.assertFalse(os.path.exists(self.sig("lynx")))
        finally:
            write(self.fix + "/release", "")
            os.close(fd)
            t.join(30)
        self.assertFalse(t.is_alive())
        self.assertEqual(first[0][0], 200)

    # ---- verify ----
    def test_verify_parse_both_ways(self):
        self.verify_all_pass()
        self.assertEqual(read(self.fix + "/verify.tree").strip(), self.tree)
        self.assertEqual(read(self.fix + "/verify.argv").strip(), "%s lynx tokay" % BN)
        write(self.fix + "/vf.stdout", "== lynx ==\n    ok    a\n== tokay ==\n    ok    b\n    FAIL  c\n")
        write(self.fix + "/vf.rc", "1")
        st, _, d = self.req("POST", "/api/release/%s/verify" % BN)
        self.assertEqual(json.loads(d)["devices"], {"lynx": "fail", "tokay": "fail"})
        self.assertEqual(desk.parse_verify(0, "== lynx ==\n    ok    a\n== tokay ==\n    ok    b\n    FAIL  c\n",
                                           ["lynx", "tokay"]), {"lynx": "pass", "tokay": "fail"})
        self.assertEqual(desk.parse_verify(0, "== lynx ==\n    ok    a\n== tokay ==\nnothing\n", ["lynx", "tokay"]),
                         {"lynx": "pass", "tokay": "fail"})

    # ---- CORS ----
    def test_cors_null_on_two_routes_and_absent_elsewhere(self):
        for m, p in (("GET", "/api/manifests"), ("OPTIONS", "/api/manifests"), ("OPTIONS", "/api/signatures")):
            self.assertEqual(self.req(m, p)[1].get("access-control-allow-origin"), "null", (m, p))
        st, h, _ = self.req("POST", "/api/signatures", dict(GOOD, Origin="null"), {"bn": BN, "device": "lynx",
                                                                                  "sig": GOOD_SIG})
        self.assertEqual(h.get("access-control-allow-origin"), "null")
        for m, p in (("GET", "/"), ("GET", "/release/" + BN), ("POST", "/api/release/%s/preflight" % BN),
                     ("GET", "/nothing"), ("OPTIONS", "/")):
            self.assertNotIn("access-control-allow-origin", self.req(m, p)[1], (m, p))

    # ---- signatures ----
    def test_good_sig_is_placed_with_ota_mandatory_path(self):
        self.verify_all_pass()
        st, _, d = self.req("GET", "/api/manifests")
        items = {i["device"]: i for i in json.loads(d)}
        self.assertEqual(sorted(items), ["lynx", "tokay"])
        man = read(self.manifest("lynx"), "rb")
        self.assertEqual(base64.b64decode(items["lynx"]["manifest"]), man)
        self.assertEqual(items["lynx"]["sha256"], hashlib.sha256(man).hexdigest())
        self.assertEqual(items["lynx"]["name"], "lynx-manifest-%s.json" % BN)
        self.assertEqual(self.post_sig(), (200, {"result": "placed"}))
        self.assertEqual(read(self.sig("lynx")), GOOD_SIG)
        argv = self.agent_calls()[-1].split("\x1f")
        self.assertEqual(len(argv), 6, argv)
        self.assertEqual(argv[0], "ota-release-check")
        self.assertEqual(argv[3:], ["lynx", VERSION, self.repo + "/editions/endospore/ota-mandatory/" + VERSION])
        st, _, d = self.req("GET", "/api/manifests")
        self.assertEqual([i["device"] for i in json.loads(d)], ["tokay"])
        self.assertEqual(self.post_sig(), (200, {"result": "already placed"}))
        self.assertEqual(self.rstate(), "waiting for manifest signatures")
        write(self.sig("tokay"), "x")
        self.assertEqual(self.rstate(), "done")

    def assert_refused(self, reply, words):
        st, j = reply
        self.assertEqual(st, 422, j)
        self.assertEqual(j["result"], "refused")
        self.assertIn(words, j["reason"])
        self.assertFalse(os.path.exists(self.sig("lynx")))
        self.assertEqual([n for n in os.listdir(self.rel("lynx")) if n.startswith(".")], [])

    def test_agent_refusal_writes_nothing(self):
        self.req("GET", "/api/manifests")
        self.assert_refused(self.post_sig("B" * 86), "phone's check")
        self.assertIn("refused: signature does not pass the phone's check", [l["result"] for l in self.log()])

    def test_manifest_changed_after_handout_is_refused(self):
        self.req("GET", "/api/manifests")
        write(self.manifest("lynx"), self.manifest_bytes(read(self.webfactory("lynx"), "rb"), " "))
        write(self.fix + "/good.manifest", read(self.manifest("lynx"), "rb"))
        self.assert_refused(self.post_sig(), "changed after it was handed out")
        self.assertEqual(self.agent_calls(), [])

    def test_manifest_replaced_and_handed_out_during_the_agent_check_is_refused(self):
        # RF-001: A is handed out, the agent accepts A's signature, and meanwhile B replaces A on disk and a GET
        # records B's hash. The signature must be checked against the bytes the agent saw, so it is refused.
        self.req("GET", "/api/manifests")
        fifo = self.fix + "/agent.fifo"
        os.mkfifo(fifo)
        write(self.fix + "/agentblock", "")
        fd = os.open(fifo, os.O_RDONLY | os.O_NONBLOCK)
        first = []
        t = threading.Thread(target=lambda: first.append(self.post_sig()))
        try:
            t.start()
            r, _, _ = select.select([fd], [], [], 10)
            if not r:
                self.fail("the agent check did not start within 10 s (reply: %r)" % first)
            self.assertEqual(os.read(fd, 1), b"x")
            write(self.manifest("lynx"), self.manifest_bytes(read(self.webfactory("lynx"), "rb"), " "))
            st, _, d = self.req("GET", "/api/manifests")
            self.assertIn("lynx", [i["device"] for i in json.loads(d)])
        finally:
            write(self.fix + "/agentgo", "")
            os.close(fd)
            t.join(30)
        self.assertFalse(t.is_alive())
        self.assert_refused(first[0], "changed after it was handed out")

    def test_never_handed_out_is_refused(self):
        self.assert_refused(self.post_sig(), "never handed out")
        self.assertEqual(self.agent_calls(), [])

    def test_webfactory_size_mismatch_is_refused(self):
        self.req("GET", "/api/manifests")
        zp = self.webfactory("lynx")
        orig = read(zp, "rb")
        write(zp, orig + b"!")
        self.assert_refused(self.post_sig(), "webfactory")
        write(zp, bytes([orig[0] ^ 1]) + orig[1:])
        self.assert_refused(self.post_sig(), "webfactory")
        self.assertEqual(self.agent_calls(), [])

    def test_different_existing_sig_is_refused(self):
        st, _, d = self.req("GET", "/api/manifests")
        self.assertIn("lynx", [i["device"] for i in json.loads(d)])
        write(self.sig("lynx"), "OTHER")
        st, j = self.post_sig()
        self.assertEqual(st, 422, j)
        self.assertEqual(j["reason"], "a different signature is already placed")
        self.assertEqual(len(self.agent_calls()), 1)
        self.assertEqual(read(self.sig("lynx")), "OTHER")

    def test_missing_agent_refuses(self):
        os.environ["NOWHERE_AGENT"] = self.fix + "/no-such-agent"
        self.req("GET", "/api/manifests")
        self.assert_refused(self.post_sig(), "agent missing")

    def test_mandatory_without_file_is_left_to_the_agent(self):
        # The Desk passes the ota-mandatory path even when no file is committed: the agent then refuses a
        # mandatory manifest, as e4-ota-publish.sh relies on.
        self.req("GET", "/api/manifests")
        self.post_sig()
        self.assertFalse(os.path.exists(self.repo + "/editions/endospore/ota-mandatory/" + VERSION))
        self.assertTrue(self.agent_calls()[-1].endswith("/ota-mandatory/" + VERSION))

    def test_log_has_login_and_no_manifest_bytes(self):
        self.req("GET", "/api/manifests")
        self.post_sig()
        text = read(self.state + "/log.jsonl")
        lines = self.log()
        for l in lines:
            self.assertEqual(sorted(l), ["action", "bn", "device", "login", "result", "utc"])
        self.assertIn({"login": LOGIN, "action": "signature", "bn": BN, "device": "lynx", "result": "placed"},
                      [{k: v for k, v in l.items() if k != "utc"} for l in lines])
        man = read(self.manifest("lynx"), "rb")
        for secret in (MARKER, GOOD_SIG, hashlib.sha256(man).hexdigest(),
                       hashlib.sha256(read(self.webfactory("lynx"), "rb")).hexdigest(),
                       base64.b64encode(man).decode()[:40]):
            self.assertNotIn(secret, text)

    def test_page_has_no_password_input(self):
        self.pf(self.ALL_OK + "PREFLIGHT\tPASS\n")
        for p in ("/", "/release/" + BN):
            body = self.req("GET", p)[2].decode().lower()
            self.assertNotIn("password", body, p)
            self.assertNotIn(">sign<", body, p)

    def test_body_limits(self):
        self.req("GET", "/api/manifests")
        st, _, _ = self.req("POST", "/api/signatures", body=b"{" + b" " * 4999 + b"}")
        self.assertEqual(st, 413)
        self.assertEqual(self.post_sig("A" * 201)[0], 400)
        self.assertEqual(self.post_sig("A b")[0], 400)
        self.assertFalse(os.path.exists(self.sig("lynx")))

    def test_page_download_then_dropped_sig_is_placed(self):
        href = "/release/%s/manifest/lynx" % BN
        self.assertIn('href="%s"' % href, self.page())
        st, h, d = self.req("GET", href)
        self.assertEqual(st, 200)
        self.assertEqual(d, read(self.manifest("lynx"), "rb"))
        self.assertIn("lynx-manifest-%s.json" % BN, h["content-disposition"])
        self.assertNotIn("access-control-allow-origin", h)
        self.assertIn(("handout", "downloaded"), [(l["action"], l["result"]) for l in self.log()])
        self.assertEqual(self.post_sig(headers=GOOD), (200, {"result": "placed"}))
        self.assertNotIn('href="%s"' % href, self.page())
        self.assertEqual(self.req("GET", href)[0], 404)
        self.assertEqual(self.req("GET", "/release/%s/manifest/nosuchdev" % BN)[0], 404)

    # ---- serving ----
    def test_systemd_fd(self):
        self.assertEqual(desk.systemd_fd({"LISTEN_PID": "42", "LISTEN_FDS": "1"}, 42), 3)
        self.assertIsNone(desk.systemd_fd({"LISTEN_PID": "43", "LISTEN_FDS": "1"}, 42))
        self.assertIsNone(desk.systemd_fd({"LISTEN_PID": "42", "LISTEN_FDS": "2"}, 42))
        self.assertIsNone(desk.systemd_fd({}, 42))

    def test_idle_expired(self):
        now = self.srv.last_activity
        self.assertFalse(desk.idle_expired(self.srv, now + 1))
        self.assertTrue(desk.idle_expired(self.srv, now + 900))
        with desk.CHILD_LOCK:
            self.assertFalse(desk.idle_expired(self.srv, now + 900))

    def test_listens_on_loopback_only(self):
        self.assertEqual(self.srv.server_address[0], "127.0.0.1")


# (name, exact old text in release_desk.py, new text, the test that must convict it)
MUTANTS = [
    ("login check removed", "if not LOGIN_RE.fullmatch(self.login()):", "if False:",
     "test_no_login_header_is_403"),
    ("Host check removed", 'if host not in (self.server.name, "127.0.0.1:%d" % self.server.port):', "if False:",
     "test_wrong_host_is_403"),
    ("Origin check removed", 'if self.headers.get("Origin") != self.own_origin(host):', "if False:",
     "test_cross_origin_post_to_preflight_is_403"),
    ("CORS *", 'self.send_header("Access-Control-Allow-Origin", "null")',
     'self.send_header("Access-Control-Allow-Origin", "*")', "test_cors_null_on_two_routes_and_absent_elsewhere"),
    ("agent check skipped", "    if rc != 0:\n        raise Refused(\"signature does not pass",
     "    if False:\n        raise Refused(\"signature does not pass", "test_agent_refusal_writes_nothing"),
    ("webfactory check skipped", "ok = os.stat(p).st_size == size and file_sha256(p) == sha", "ok = True",
     "test_webfactory_size_mismatch_is_refused"),
    ("handout hash skipped", "if data is None or hashlib.sha256(data).hexdigest() != want:", "if False:",
     "test_manifest_changed_after_handout_is_refused"),
    ("final check against the mutable handout", "if read_manifest(bn, dev) != data:",
     "if check_handout(bn, dev, read_manifest(bn, dev)):",
     "test_manifest_replaced_and_handed_out_during_the_agent_check_is_refused"),
    ("ready from rc alone", 'ready = rc == 0 and readable and last == "PASS" and not fail', "ready = rc == 0",
     "test_rc0_with_one_fail_line_is_not_ready"),
    ("existing .sig overwritten", 'raise Refused("a different signature is already placed")', "pass",
     "test_different_existing_sig_is_refused"),
    ("lock removed", "if not CHILD_LOCK.acquire(blocking=False):\n            log_action(login, m.group(2)",
     "if CHILD_LOCK.acquire(blocking=False) and False:\n            log_action(login, m.group(2)",
     "test_second_child_is_409"),
    ("download skips the handout", 'record_handout(login, bn, dev, data, "downloaded")', "pass",
     "test_page_download_then_dropped_sig_is_placed"),
    ("--preflight-only dropped", '"--preflight-only", bn,', "bn,", "test_preflight_all_ok_is_ready"),
    ("ota-mandatory argument dropped", "dev, version, mand], stdin", "dev, version], stdin",
     "test_good_sig_is_placed_with_ota_mandatory_path"),
    ("verify FAIL line ignored", 'bad = b is None or any(x.startswith("    FAIL  ") for x in b)', "bad = b is None",
     "test_verify_parse_both_ways"),
    ("bind to every address", 'desk = Desk(("127.0.0.1", port), Handler)', 'desk = Desk(("", port), Handler)',
     "test_listens_on_loopback_only"),
]
CHILD_TIMEOUT = 120


def run_copy(path):
    """Run this suite against path in its own session. -> (rc, output); rc None when it hung and was killed."""
    env = dict(os.environ, RELEASE_DESK_PATH=path)
    p = subprocess.Popen([sys.executable, os.path.abspath(__file__)], env=env, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, start_new_session=True)
    try:
        out, _ = p.communicate(timeout=CHILD_TIMEOUT)
        return p.returncode, out.decode("utf-8", "replace")
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        out, _ = p.communicate()
        return None, out.decode("utf-8", "replace")


def mutate():
    src = read(DESK_PATH)
    bad = 0
    rc, out = run_copy(DESK_PATH)
    if rc != 0:
        print("FAILED: the unmutated suite does not pass:\n" + out)
        return 1
    print("baseline: passes")
    for name, old, new, test in MUTANTS:
        n = src.count(old)
        if n != 1:
            print("FAILED: mutant %r: its text is found %d times, not once" % (name, n))
            bad += 1
            continue
        path = os.path.join(tempfile.mkdtemp(dir=ROOT), "release_desk.py")
        write(path, src.replace(old, new))
        rc, out = run_copy(path)
        if rc is None:
            print("FAILED: %s hung past %d s" % (name, CHILD_TIMEOUT))
            bad += 1
        elif rc != 0 and ("FAIL: %s " % test in out or "ERROR: %s " % test in out):
            print("convicted: %s (by %s)" % (name, test))
        else:
            print("FAILED: mutant %r survived (%s did not fail)\n%s" % (name, test, out[-2000:]))
            bad += 1
    print("all %d mutants convicted" % len(MUTANTS) if not bad else "%d mutant(s) not convicted" % bad)
    return 1 if bad else 0


def main():
    try:
        if "--mutate" in sys.argv[1:]:
            return mutate()
        r = unittest.main(argv=[sys.argv[0]], exit=False, verbosity=1).result
        return 0 if r.wasSuccessful() else 1
    finally:
        shutil.rmtree(ROOT, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
