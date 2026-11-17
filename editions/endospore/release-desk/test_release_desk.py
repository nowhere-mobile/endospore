#!/usr/bin/env python3
"""Pins release_desk.py, the Release Desk (docs/release-desk.md §7 stage 4, NWP-20261202-24; stage 5,
NWP-20261205-04: the passphrase field, the signing session, Retry this device; and the private socket,
NWP-20261205-06).

    python3 editions/endospore/release-desk/test_release_desk.py            the suite
    python3 editions/endospore/release-desk/test_release_desk.py --mutate   every broken copy must be convicted

The real handler runs in a thread, on 127.0.0.1 and on a Unix socket, against a fixture tree with stub sign-release.sh, verify-release.sh
and agent. The agent stub accepts only the fixture's good signature over the fixture's manifest and records its argv.
Every file lives under ONE temp root, removed on every exit (a pass, a failure, --mutate). No test sleeps: the busy
case waits on a FIFO with a 10 s bound that only a failure reaches, a signing session's end is CHILD_LOCK.acquire with
a 30 s bound, and one progress poll is bounded at 5 s.

The sign stub never writes the passphrase: only its sha256, whether stdin is a tty, whether /dev/tty opens, its
environment's names and its ancestor chain. A test session runs only when the test marks the server private.
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
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
DESK_PATH = os.environ.get("RELEASE_DESK_PATH") or os.path.join(HERE, "release_desk.py")
ROOT = tempfile.mkdtemp(prefix="rdt.")  # short: a --mutate child's AF_UNIX socket path must fit in 107 bytes
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

PASS = "corr3ct horse-\u00e9 battery"
PASS_SHA = hashlib.sha256(PASS.encode("utf-8")).hexdigest()

SIGN_STUB = r"""#!/bin/bash
if [ "$1" = --preflight-only ]; then
printf '%s\n' "$*" > "$FIX/sign.argv"
cat "$FIX/pf.stdout"
cat "$FIX/pf.stderr" >&2
if [ -e "$FIX/block" ]; then
  exec 3<>"$FIX/started.fifo"; printf x >&3
  i=0; while [ ! -e "$FIX/release" ] && [ $i -lt 200 ]; do sleep 0.05; i=$((i+1)); done
  [ -e "$FIX/release" ] || exit 3
fi
exit "$(cat "$FIX/pf.rc")"
fi
printf '%s\n' "$*" > "$FIX/sign.argv"
compgen -e | sort > "$FIX/sign.env"
if [ -t 0 ]; then echo yes > "$FIX/sign.tty"; else echo no > "$FIX/sign.tty"; fi
if ( exec 9</dev/tty ) 2>/dev/null; then echo yes > "$FIX/sign.ctty"; else echo no > "$FIX/sign.ctty"; fi
p=$$; : > "$FIX/sign.chain"
while [ "$p" -gt 1 ]; do echo "$p" >> "$FIX/sign.chain"; p=$(awk '{print $4}' "/proc/$p/stat"); done
mode=$(cat "$FIX/sign.mode")
shift 2
if [ "$mode" = refuse ]; then
  echo "REFUSING: lynx: keys: a key is missing" >&2
  echo "REFUSING: tokay: ring: no ring conf" >&2
  echo "sign-release: preflight refused (2 check(s)) -- nothing was signed" >&2
  X=""; IFS= read -rs -t 1 X; echo "${#X}" > "$FIX/sign.late"
  exit 1
fi
if [ "$mode" = slowterm ]; then
  trap 'exec 3<>"$FIX/started.fifo"; printf x >&3
    i=0; while [ ! -e "$FIX/release" ] && [ $i -lt 200 ]; do sleep 0.05; i=$((i+1)); done
    echo t > "$FIX/termed"; exit 143' TERM
fi
printf 'passphrase for the release keys (one prompt for %d device(s)): ' "$#" >&2
PW=""
if [ "$mode" = echo ]; then IFS= read -r -t 10 PW; else IFS= read -rs -t 10 PW; fi
echo >&2
printf '%s' "$PW" | sha256sum | cut -d' ' -f1 >> "$FIX/sign.got"
Y=""; IFS= read -rs -t 0.3 Y; [ -n "$Y" ] && echo extra >> "$FIX/sign.got"
unset PW Y
case "$mode" in
  happy|echo)
    for a in "$@"; do d=${a%%:*}; echo "== $d: finalize (BUILD_DATETIME 1) =="; echo "== $d RELEASE DONE -- /x =="; done
    for a in "$@"; do echo "  ${a%%:*} signed"; done
    exit 0 ;;
  wrong)
    echo "the passphrase does not open /x/keys/lynx/releasekey.pk8 -- nothing was signed" >&2
    exit 1 ;;
  partial)
    echo "== lynx: finalize (BUILD_DATETIME 1) =="; echo "== lynx RELEASE DONE -- /x =="
    echo "== tokay: finalize (BUILD_DATETIME 1) =="
    echo "sign-release: tokay FAILED (exit 1); the next device runs" >&2
    exec 3<>"$FIX/started.fifo"; printf x >&3
    i=0; while [ ! -e "$FIX/release" ] && [ $i -lt 400 ]; do sleep 0.05; i=$((i+1)); done
    echo "  lynx signed"; echo "  tokay FAILED"
    exit 1 ;;
  bothfail)
    for a in "$@"; do d=${a%%:*}; echo "== $d: finalize (BUILD_DATETIME 1) =="; echo "sign-release: $d FAILED (exit 1)" >&2; done
    for a in "$@"; do echo "  ${a%%:*} FAILED"; done
    exit 1 ;;
  slowterm)
    i=0; while [ $i -lt 400 ]; do sleep 0.05; i=$((i+1)); done
    exit 3 ;;
  block)
    trap 'echo t > "$FIX/termed"; exit 143' TERM
    echo "== ${1%%:*}: finalize (BUILD_DATETIME 1) =="
    i=0; while [ ! -e "$FIX/release" ] && [ $i -lt 200 ]; do sleep 0.05; i=$((i+1)); done
    exit 3 ;;
esac
exit 9
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


def sock_dir():
    """A 0700 directory under ROOT, short enough for an AF_UNIX path even inside a --mutate child."""
    d = tempfile.mkdtemp(dir=ROOT, prefix="s")
    os.chmod(d, 0o700)
    return d


def sock_path(d):
    p = os.path.join(d, "d.sock")
    assert len(p.encode()) <= 107, "TMPDIR is too long for an AF_UNIX socket path: " + p
    return p


class UnixConnection(http.client.HTTPConnection):
    def __init__(self, path):
        http.client.HTTPConnection.__init__(self, "localhost", timeout=30)
        self.unix_path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.unix_path)


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
        write(f + "/sign.mode", "happy")
        self.old_env = dict(os.environ)
        os.environ.update({"NOWHERE_DESK_STATE": self.state, "ENDOSPORE_TREE": self.tree,
                           "ENDOSPORE_REPO": self.repo, "NOWHERE_AGENT": self.agent, "FIX": f})
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(desk.cmd_open([BN, COMMIT, "lynx", "tokay:out-x"]), 0)
        self.srv = desk.make_server(NAME, 0, 900)
        self.port = self.srv.server_address[1]
        self.thr = threading.Thread(target=self.srv.serve_forever, args=(0.05,), daemon=True)
        self.thr.start()
        self.replies = []

    def tearDown(self):
        write(self.fix + "/release", "")
        self.wait_session()
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

    def req(self, method, path, headers=None, body=None, conn=None):
        c = conn() if conn else http.client.HTTPConnection("127.0.0.1", self.port, timeout=30)
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

    # ---- signing (stage 5) ----
    def mode(self, m):
        write(self.fix + "/sign.mode", m)

    def ready(self):
        self.assertTrue(self.pf(self.ALL_OK + "PREFLIGHT\tPASS\n")["ready"])

    def sign(self, body=None, headers=None, device=None):
        if body is None:
            body = {"passphrase": PASS}
            if device is not None:
                body["device"] = device
        st, _, d = self.req("POST", "/api/release/%s/sign" % BN, headers, body)
        self.replies.append(d)
        return st, json.loads(d)

    def wait_session(self):
        self.assertTrue(desk.CHILD_LOCK.acquire(timeout=30), "the signing session did not end within 30 s")
        desk.CHILD_LOCK.release()

    def sign_rec(self):
        st, _, d = self.req("GET", "/api/release/%s/sign" % BN)
        self.replies.append(d)
        self.assertEqual(st, 200, d)
        return json.loads(d)

    def signed_session(self, device=None):
        st, j = self.sign(device=device)
        self.assertEqual((st, j), (202, {"result": "started"}))
        self.wait_session()
        return self.sign_rec()

    def fixfile(self, name):
        p = self.fix + "/" + name
        return read(p) if os.path.exists(p) else None

    def full_sign_argv(self):
        a = self.fixfile("sign.argv")
        return None if a is None or a.startswith("--preflight-only") else a.strip()

    def test_sign_happy_two_devices(self):
        self.srv.private = True
        self.ready()
        self.assertEqual(self.rstate(), "ready to sign")
        rec = self.signed_session()
        self.assertEqual(self.fixfile("sign.got"), PASS_SHA + "\n")
        self.assertEqual(self.fixfile("sign.tty"), "yes\n")
        self.assertEqual(self.fixfile("sign.ctty"), "yes\n")
        self.assertIn(str(os.getpid()), self.fixfile("sign.chain").split())
        self.assertEqual(self.full_sign_argv(), "%s %s lynx tokay:out-x" % (BN, COMMIT))
        self.assertEqual(rec["devices"], {"lynx": "signed", "tokay": "signed"})
        self.assertEqual(rec["result"], "signed")
        self.assertEqual(rec["session"], ["lynx", "tokay"])
        self.assertEqual(self.rstate(), "signed")
        self.assertEqual(os.stat(self.state + "/results/%s/sign.out" % BN).st_mode & 0o777, 0o600)
        self.assertEqual(os.stat(self.state + "/results/%s/sign.json" % BN).st_mode & 0o777, 0o600)
        self.assertIn(("sign", "lynx,tokay", "signed"), [(l["action"], l["device"], l["result"]) for l in self.log()])

    def test_output_never_holds_passphrase(self):
        self.srv.private = True
        self.ready()
        self.mode("echo")
        self.signed_session()
        self.assertEqual(self.fixfile("sign.got"), PASS_SHA + "\n")
        out = read(self.state + "/results/%s/sign.out" % BN, "rb")
        self.assertIn(b"passphrase for the release keys", out)
        self.assertNotIn(PASS.encode("utf-8"), out)

    def test_refused_before_prompt_never_gets_passphrase(self):
        self.srv.private = True
        self.ready()
        self.mode("refuse")
        rec = self.signed_session()
        self.assertEqual(self.fixfile("sign.late"), "0\n")
        self.assertIsNone(self.fixfile("sign.got"))
        self.assertEqual(rec["result"], "refused before the prompt")
        self.assertEqual(rec["devices"], {"lynx": "waiting", "tokay": "waiting"})
        self.assertEqual(self.rstate(), "ready to sign")
        self.assertIn("preflight refused", self.req("GET", "/release/%s/details/sign" % BN)[2].decode())

    def test_child_env_and_argv_clean(self):
        self.srv.private = True
        self.ready()
        os.environ["password"] = "x-pw"
        os.environ["PW"] = "x-pw2"
        self.signed_session()
        names = self.fixfile("sign.env").split()
        self.assertIn("FIX", names)
        self.assertNotIn("password", names)
        self.assertNotIn("PW", names)
        argv = self.fixfile("sign.argv")
        self.assertNotIn(PASS, argv)
        self.assertNotIn("--preflight-only", argv)

    def test_empty_and_control_passphrase_refused(self):
        self.srv.private = True
        self.ready()
        for body in ({"passphrase": ""}, {"passphrase": "a\nb"}, {"passphrase": "a\x03b"}, {"passphrase": "a\x15b"},
                     {"passphrase": "a\x04b"}, {"passphrase": "a\x7fb"}, {"passphrase": "a" * 1025},
                     {"passphrase": "\u00e9" * 513}, {"passphrase": 5}, {"device": "lynx"}, ["x"],
                     {"passphrase": PASS, "other": 1}, {"passphrase": PASS, "device": "Lynx"}):
            st, j = self.sign(body)
            self.assertEqual((st, j), (400, {"error": "bad request"}), body)
        self.assertIsNone(self.full_sign_argv())
        self.assertFalse(desk.CHILD_LOCK.locked())
        self.assertNotIn("sign.json", os.listdir(self.state + "/results/" + BN))

    def test_sign_needs_ready_preflight(self):
        self.srv.private = True
        self.assertEqual(self.sign(), (409, {"error": "run the preflight first"}))
        self.pf(self.ALL_OK + "PREFLIGHT\tFAIL\tlynx\tkeys\tmissing\nPREFLIGHT\tPASS\n")
        self.assertEqual(self.sign(), (409, {"error": "run the preflight first"}))
        self.assertIsNone(self.full_sign_argv())
        self.assertFalse(desk.CHILD_LOCK.locked())

    def test_sign_refused_when_not_private(self):
        self.ready()
        self.assertEqual(self.sign(), (403, {"error": "not private"}))
        self.assertIsNone(self.full_sign_argv())
        self.assertFalse(desk.CHILD_LOCK.locked())

    def test_cross_origin_sign_is_403(self):
        self.srv.private = True
        self.ready()
        self.assertEqual(self.sign(headers=dict(GOOD, Origin="https://evil.example"))[0], 403)
        self.assertEqual(self.sign(headers=dict(GOOD, Origin="null"))[0], 403)
        h = dict(GOOD)
        del h["Origin"]
        self.assertEqual(self.sign(headers=h)[0], 403)
        self.assertIsNone(self.full_sign_argv())
        self.assertNotIn("access-control-allow-origin", self.req("OPTIONS", "/api/release/%s/sign" % BN)[1])
        self.assertEqual(self.signed_session()["result"], "signed")   # the same request with its own Origin signs

    def partial_session(self, during):
        """Start a `partial` session and run `during` while the stub blocks, after lynx signed and tokay failed."""
        fifo = self.fix + "/started.fifo"
        if os.path.exists(fifo):
            os.unlink(fifo)
        os.mkfifo(fifo)
        if os.path.exists(self.fix + "/release"):
            os.unlink(self.fix + "/release")
        self.mode("partial")
        fd = os.open(fifo, os.O_RDONLY | os.O_NONBLOCK)
        try:
            self.assertEqual(self.sign(), (202, {"result": "started"}))
            r, _, _ = select.select([fd], [], [], 10)
            if not r:
                self.fail("the signing child did not reach the block within 10 s")
            self.assertEqual(os.read(fd, 1), b"x")
            during()
        finally:
            write(self.fix + "/release", "")
            os.close(fd)
        self.wait_session()
        return self.sign_rec()

    def test_second_child_while_signing_is_409(self):
        self.srv.private = True
        self.ready()
        self.req("GET", "/api/manifests")

        def during():
            self.assertEqual(self.rstate(), "signing")
            self.assertEqual(self.sign(), (409, {"error": "busy"}))
            st, _, d = self.req("POST", "/api/release/%s/preflight" % BN)
            self.assertEqual((st, json.loads(d)), (409, {"error": "busy"}))
            st, _, d = self.req("POST", "/api/release/%s/verify" % BN)
            self.assertEqual((st, json.loads(d)), (409, {"error": "busy"}))
            self.assertEqual(self.post_sig()[0], 409)
            self.assertIn("<meta http-equiv=refresh", self.page())
        self.partial_session(during)
        self.assertFalse(desk.CHILD_LOCK.locked())
        self.assertNotEqual(self.rstate(), "signing")

    def test_wrong_passphrase_result(self):
        self.srv.private = True
        self.ready()
        self.mode("wrong")
        rec = self.signed_session()
        self.assertEqual(rec["result"], "wrong passphrase")
        self.assertEqual(rec["devices"], {"lynx": "waiting", "tokay": "waiting"})
        self.assertEqual(self.rstate(), "ready to sign")
        page = self.page()
        self.assertIn("type=password", page)
        self.assertIn(desk.DESK_WORDS["result wrong passphrase"], page)

    def test_retry_one_device_argv(self):
        self.srv.private = True
        self.ready()
        seen = []
        self.partial_session(lambda: self.wait_for(
            lambda: seen.append(self.sign_rec()["devices"]) or seen[-1] == {"lynx": "signed", "tokay": "failed"}))
        rec = self.sign_rec()
        self.assertEqual(rec["result"], "some failed")
        self.assertEqual(rec["devices"], {"lynx": "signed", "tokay": "failed"})
        self.assertEqual(self.sign(), (409, {"error": "use Retry this device"}))
        self.assertEqual(self.sign(device="lynx"), (409, {"error": "this device has not failed"}))
        self.assertEqual(self.sign(device="nosuch"), (404, {"error": "unknown device"}))
        page = self.page()
        self.assertIn("sign('tokay')", page)
        self.assertNotIn("sign('lynx')", page)
        self.assertNotIn("id=pp>", page)
        # a Retry that meets a wrong passphrase leaves tokay failed, so Retry stays possible
        self.mode("wrong")
        rec = self.signed_session("tokay")
        self.assertEqual(rec["result"], "wrong passphrase")
        self.assertEqual(rec["devices"]["tokay"], "failed")
        self.assertEqual(rec["devices"]["lynx"], "signed")
        self.assertIn("sign('tokay')", self.page())
        self.assertEqual(self.rstate(), "ready to sign")
        # so does a Retry the script refuses before its prompt
        self.mode("refuse")
        rec = self.signed_session("tokay")
        self.assertEqual(rec["result"], "refused before the prompt")
        self.assertEqual(rec["devices"]["tokay"], "failed")
        self.assertEqual(self.fixfile("sign.late"), "0\n")
        self.assertIn("sign('tokay')", self.page())
        self.mode("happy")
        rec = self.signed_session("tokay")
        self.assertEqual(self.full_sign_argv(), "%s %s tokay:out-x" % (BN, COMMIT))
        self.assertEqual(rec["devices"], {"lynx": "signed", "tokay": "signed"})
        self.assertEqual(rec["session"], ["tokay"])
        self.assertEqual(rec["result"], "signed")
        self.assertEqual(self.rstate(), "signed")
        self.assertNotIn("type=password", self.page())

    def wait_for(self, pred):
        """The one progress poll: 5 s, well inside the partial stub's 20 s block, so its summary never answers it."""
        end = time.monotonic() + 5
        while time.monotonic() < end:
            if pred():
                return
            select.select([], [], [], 0.02)
        self.fail("the condition did not hold within 5 s")

    def test_timeout_terms_the_group(self):
        self.srv.private = True
        self.ready()
        self.mode("block")
        old = desk.SIGN_TIMEOUT_PER_DEVICE
        desk.SIGN_TIMEOUT_PER_DEVICE = 0.5
        try:
            rec = self.signed_session()
        finally:
            desk.SIGN_TIMEOUT_PER_DEVICE = old
        self.assertEqual(self.fixfile("termed"), "t\n")
        self.assertEqual(rec["result"], "timed out")
        self.assertEqual(rec["devices"], {"lynx": "failed", "tokay": "failed"})
        self.assertNotIn("signed", rec["devices"].values())

    def test_output_error_holds_the_lock_until_the_child_exits(self):
        """RF-001: sign.out cannot be written (a full disk). The session TERMs the child and keeps CHILD_LOCK while the
        child's TERM trap runs (the real script sweeps its key dirs there): a second Sign is busy until it exits."""
        self.srv.private = True
        self.ready()
        self.mode("slowterm")
        fifo = self.fix + "/started.fifo"
        os.mkfifo(fifo)
        fd = os.open(fifo, os.O_RDONLY | os.O_NONBLOCK)
        old = desk.write_out

        def full(_fd, _chunk):
            raise OSError(28, "No space left on device")
        desk.write_out = full
        try:
            self.assertEqual(self.sign(), (202, {"result": "started"}))
            r, _, _ = select.select([fd], [], [], 10)
            if not r:
                self.fail("the child's TERM trap did not start within 10 s")
            self.assertEqual(os.read(fd, 1), b"x")
            self.assertIsNone(self.fixfile("termed"))
            self.assertTrue(desk.CHILD_LOCK.locked())
            self.assertEqual(self.sign(), (409, {"error": "busy"}))
            self.assertEqual(self.rstate(), "signing")
        finally:
            write(self.fix + "/release", "")
            os.close(fd)
            desk.write_out = old
        self.wait_session()
        self.assertEqual(self.fixfile("termed"), "t\n")
        rec = self.sign_rec()
        self.assertEqual(rec["result"], "ended without a result")
        self.assertEqual(rec["devices"], {"lynx": "failed", "tokay": "failed"})
        self.assertIn(("sign", "lynx,tokay", "error"), [(l["action"], l["device"], l["result"]) for l in self.log()])

    def test_retry_of_one_of_two_failed_devices_is_not_signed(self):
        """RF-002: lynx and tokay both fail; a Retry signs tokay. The release is not signed while lynx stays failed."""
        self.srv.private = True
        self.ready()
        self.mode("bothfail")
        rec = self.signed_session()
        self.assertEqual((rec["result"], rec["devices"]), ("some failed", {"lynx": "failed", "tokay": "failed"}))
        self.mode("happy")
        rec = self.signed_session("tokay")
        self.assertEqual(rec["devices"], {"lynx": "failed", "tokay": "signed"})
        self.assertEqual(rec["result"], "some failed")
        page = self.page()
        self.assertNotIn("<p>%s</p>" % desk.DESK_WORDS["result signed"], page)
        self.assertIn("<p>%s</p>" % desk.DESK_WORDS["result some failed"], page)
        self.assertIn("sign('lynx')", page)
        self.assertEqual(self.rstate(), "ready to sign")
        rec = self.signed_session("lynx")
        self.assertEqual((rec["result"], rec["devices"]), ("signed", {"lynx": "signed", "tokay": "signed"}))
        self.assertIn("<p>%s</p>" % desk.DESK_WORDS["result signed"], self.page())
        self.assertEqual(self.rstate(), "signed")

    def test_no_secret_anywhere(self):
        self.srv.private = True
        self.ready()
        self.mode("wrong")
        self.signed_session()
        self.partial_session(lambda: None)
        self.mode("echo")
        self.signed_session("tokay")
        for p in ("/", "/release/" + BN, "/api/release/%s/sign" % BN, "/release/%s/details/sign" % BN):
            self.replies.append(self.req("GET", p)[2])
        # the raw bytes, and the ASCII head that survives json.dumps's \u escape of the non-ASCII char
        secrets = (PASS.encode("utf-8"), PASS.split("-")[0].encode("ascii"))
        for d in self.replies:
            for secret in secrets:
                self.assertNotIn(secret, d)
        for top in (self.state, self.fix):
            for dirpath, _, files in os.walk(top):
                for n in files:
                    p = os.path.join(dirpath, n)
                    if os.path.isfile(p):
                        for secret in secrets:
                            self.assertNotIn(secret, read(p, "rb"), p)
        signs = [l for l in self.log() if l["action"] == "sign"]
        self.assertGreaterEqual(len(signs), 6)
        for l in signs:
            self.assertEqual(sorted(l), ["action", "bn", "device", "login", "result", "utc"])

    def test_password_field_only_when_ready(self):
        for p in ("/", "/release/" + BN):
            self.assertNotIn("type=password", self.req("GET", p)[2].decode(), p)
        self.ready()
        self.assertNotIn("type=password", self.page())   # loopback TCP: never private
        self.srv.private = True
        self.pf(self.ALL_OK + "PREFLIGHT\tFAIL\tlynx\tkeys\tmissing\nPREFLIGHT\tPASS\n")
        self.assertNotIn("type=password", self.page())
        self.assertNotIn("type=password", self.req("GET", "/")[2].decode())
        self.ready()
        page = self.page()
        self.assertIn("<input type=password autocomplete=off id=pp>", page)
        self.assertIn(">%s</button>" % desk.DESK_WORDS["sign"], page)
        self.assertNotIn("type=password", self.req("GET", "/")[2].decode())
        self.assertNotIn("Read only", page)

        def during():
            self.assertNotIn("type=password", self.page())
        self.partial_session(during)

    def test_parsed_strings_are_in_sign_release(self):
        text = read(os.path.join(HERE, "..", "build", "sign-release.sh"))
        for lit in (desk.SIGN_PROMPT, desk.SIGN_WRONG, desk.SIGN_FINALIZE, desk.SIGN_DONE, desk.SIGN_FAILED,
                    desk.SIGN_SIGNED, "IFS= read -rs PW", 'echo "== $DEV: finalize', 'echo "== $DEV RELEASE DONE',
                    'echo "sign-release: $DEV FAILED', 'echo "  $DEV signed"', 'echo "  $DEV FAILED"',
                    "trap 'sweep 129 HUP' HUP", "trap 'sweep 143 TERM' TERM"):
            self.assertIn(lit, text, lit)

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

    def start(self, srv):
        """Serve srv in a thread until the test ends."""
        threading.Thread(target=srv.serve_forever, args=(0.05,), daemon=True).start()
        self.addCleanup(srv.server_close)
        self.addCleanup(srv.shutdown)
        return srv

    def test_tcp_is_not_private(self):
        self.assertIs(self.srv.private, False)

    def test_unix_socket_serves_and_is_private(self):
        p = sock_path(sock_dir())
        srv = self.start(desk.make_server(NAME, None, 900, path=p))
        self.assertIs(srv.private, True)
        self.assertIsNone(srv.port)
        self.assertEqual(stat.S_IMODE(os.lstat(p).st_mode), 0o600)
        st, _, d = self.req("GET", "/", conn=lambda: UnixConnection(p))
        self.assertEqual(st, 200, d)
        srv.shutdown()
        srv.server_close()
        self.assertFalse(os.path.lexists(p))

    def test_unix_host_must_be_the_name(self):
        p = sock_path(sock_dir())
        self.start(desk.make_server(NAME, None, 900, path=p))

        def c():
            return UnixConnection(p)
        self.assertEqual(self.req("GET", "/", dict(GOOD, Host="127.0.0.1:8770"), conn=c)[0], 403)
        self.assertEqual(self.req("GET", "/", dict(GOOD, Host="127.0.0.1:%d" % self.port), conn=c)[0], 403)
        self.assertEqual(self.req("GET", "/", GOOD, conn=c)[0], 200)

    def test_systemd_unix_fd(self):
        p = sock_path(sock_dir())
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.bind(p)
        s.listen()
        srv = self.start(desk.make_server(NAME, None, 900, fd=s.detach()))
        self.assertIs(srv.private, True)
        self.assertEqual(srv.server_address, p)
        self.assertIsNone(srv.port)
        self.assertEqual(self.req("GET", "/", conn=lambda: UnixConnection(p))[0], 200)
        t = socket.socket()
        t.bind(("127.0.0.1", 0))
        t.listen()
        port = t.getsockname()[1]
        srv2 = self.start(desk.make_server(NAME, None, 900, fd=t.detach()))
        self.assertIs(srv2.private, False)
        self.assertEqual(srv2.port, port)

    def test_socket_path_refusals(self):
        d = sock_dir()
        os.chmod(d, 0o770)
        p = sock_path(d)
        with self.assertRaises(desk.UnsafeSocketPath):
            self.start(desk.make_server(NAME, None, 900, path=p))
        self.assertFalse(os.path.lexists(p))
        os.chmod(d, 0o700)
        write(p, "not a socket\n")
        with self.assertRaises(desk.UnsafeSocketPath):
            self.start(desk.make_server(NAME, None, 900, path=p))
        self.assertEqual(read(p), "not a socket\n")

    def test_serve_refuses_port_and_socket_together(self):
        with contextlib.redirect_stderr(io.StringIO()) as err:
            self.assertEqual(desk.cmd_serve(["--name", NAME, "--port", "1", "--socket", "x"]), 2)
        self.assertIn("--socket PATH", err.getvalue())


# (name, exact old text in release_desk.py, new text, the test that must convict it)
MUTANTS = [
    ("login check removed", "if not LOGIN_RE.fullmatch(self.login()):", "if False:",
     "test_no_login_header_is_403"),
    ("Host check removed", "if host != self.server.name and not loopback:", "if False:",
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
    # stage 5, NWP-20261205-04
    ("S1 ECHO not cleared", "attrs[3] &= ~(termios.ECHO | termios.ECHONL)", "pass",
     "test_output_never_holds_passphrase"),
    ("S2 passphrase written without waiting for the prompt", 'if SIGN_PROMPT.encode("utf-8") in tail:', "if True:",
     "test_refused_before_prompt_never_gets_passphrase"),
    ("S3 password left in the child env", 'if k not in ("password", "PW")}', "}",
     "test_child_env_and_argv_clean"),
    ("S4 empty passphrase accepted", "isinstance(v, str) and len(v) > 0 and", "isinstance(v, str) and",
     "test_empty_and_control_passphrase_refused"),
    ("S4b control characters accepted", "\n                and not PASS_BAD_RE.search(v))", ")",
     "test_empty_and_control_passphrase_refused"),
    ("S5 ready check dropped", '"preflight.json")) or {}).get("ready") is not True:', '"preflight.json")) or {}) and False:',
     "test_sign_needs_ready_preflight"),
    ("S6 private check dropped", 'if getattr(self.server, "private", False) is not True:\n            self.drain()',
     "if False:\n            self.drain()", "test_sign_refused_when_not_private"),
    ("S7 sign route exempt from the Origin gate", 'if self.command == "POST" and path != "/api/signatures":',
     'if self.command == "POST" and path != "/api/signatures" and not path.endswith("/sign"):',
     "test_cross_origin_sign_is_403"),
    ("S8 lock not taken by Sign", 'if not CHILD_LOCK.acquire(blocking=False):\n        log_action(login, "sign"',
     'if False:\n        log_action(login, "sign"', "test_second_child_while_signing_is_409"),
    ("S9 the timeout kill removed", "os.killpg(p.pid, signal.SIGTERM)", "pass", "test_timeout_terms_the_group"),
    ("S10 Retry signs every device", "p = subprocess.Popen(sign_argv(rec, devs),",
     "p = subprocess.Popen(sign_argv(rec, release_devices(rec)),", "test_retry_one_device_argv"),
    ("S11 the FAILED line ignored", '(re.compile(r"sign-release: ([a-z0-9]+) %s( .*)?" % SIGN_FAILED), "failed"),', "",
     "test_retry_one_device_argv"),
    ("S12 the field rendered when not ready", 'return private is True and release_state(rec) == "ready to sign"',
     "return private is True", "test_password_field_only_when_ready"),
    ("S13 the passphrase in the log result", 'log_action(login, "sign", bn, what, "started")',
     'log_action(login, "sign", bn, what, "started " + passphrase)', "test_no_secret_anywhere"),
    ("S14 a refused or wrong Retry resets the device to waiting", "st[\"devices\"][d] = prev[d]  # restore",
     "st[\"devices\"][d] = \"waiting\"  # restore", "test_retry_one_device_argv"),
    ("S15 the lock released before the child exits", "        if p is not None:\n            reap(p, m)\n",
     "        if p is not None:\n            stop_group(p, signal.SIGTERM)\n",
     "test_output_error_holds_the_lock_until_the_child_exits"),
    ("S16 a Retry's success judged on its own devices", 'all(v == "signed" for v in st["devices"].values())',
     'all(st["devices"].get(d) == "signed" for d in devs)', "test_retry_of_one_of_two_failed_devices_is_not_signed"),
    # the private socket, NWP-20261205-06
    ("U1 private for every family", "desk.private = desk.socket.family == socket.AF_UNIX", "desk.private = True",
     "test_tcp_is_not_private"),
    ("U2 socket umask dropped", "old = os.umask(0o177)", "old = os.umask(0)",
     "test_unix_socket_serves_and_is_private"),
    ("U3 loopback Host on a private Desk", "loopback = not self.server.private and host ==",
     'loopback = host.startswith("127.0.0.1:") or not self.server.private and host ==',
     "test_unix_host_must_be_the_name"),
    ("U4 regular file unlinked", "if not stat.S_ISSOCK(st.st_mode) or st.st_uid != os.getuid():",
     "if st.st_uid != os.getuid():", "test_socket_path_refusals"),
    ("U5 AF_UNIX fd read as AF_INET", "if sock.family == socket.AF_UNIX:", "if False:", "test_systemd_unix_fd"),
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
