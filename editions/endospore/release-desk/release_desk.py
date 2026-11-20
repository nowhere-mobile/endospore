#!/usr/bin/env python3
"""The Release Desk: docs/release-desk.md §7 stage 4 (NWP-20261202-24) and stage 5 (NWP-20261205-04).

A page on the build host, behind `tailscale serve`, where the operator follows a release the maintainer opened:

  release_desk.py open <BN> <verified-commit> <dev>[:<out>]...   the maintainer, in a shell on the build host
  release_desk.py serve --name <tailnet name> [--port 8770 | --socket PATH] [--idle 900]

`serve` runs as the signing user, started by systemd socket activation (nowhere-release-desk.socket), and exits after
--idle seconds with no request and no child. It shows each release's preflight (`sign-release.sh --preflight-only`),
its verify (`verify-release.sh`), and its installer manifests. It hands the manifests to the Manifest Signer and places
a returned signature only after three checks of its own (§5.4): the phone's own `ota-release-check`, the webfactory
zip's size and sha256 against the manifest, and the manifest on disk against the bytes it handed out.

The Desk listens in one of two ways (NWP-20261205-06). A Unix socket (the shipped unit's
%t/nowhere-release-desk.sock, or --socket PATH) marks the server `private`: only the signing user and root can connect,
and the Host must be the tailnet name (or `localhost` with the tailnet name in X-Forwarded-Host, which is what
`tailscale serve` sends to a unix: target). A loopback TCP port (--port, or a TCP socket from systemd) is not private: it
serves the read-only Desk of stage 4, and stage 5's Sign is refused there.

Stage 5 (§4.3 item 3): a release page that is ready to sign shows one passphrase field and a Sign button. Sign starts
`sign-release.sh <BN> <commit> <dev>[:<out>]...` as the Desk's own child (sitting-guard.sh allows its ancestors) in a
pseudo-terminal with echo off, and writes the passphrase to it ONCE, after the script's prompt. The passphrase is held
only in memory between the button press and that write: never on argv or in the child's environment (`password` and
`PW` are removed from it), never in a file, a URL, a log line or a reply. Sign is refused unless the server is marked
private (`server.private is True`, the Unix socket above; README "Known limits / The socket"): over loopback TCP every
Desk answers 403. A failed device offers Retry this device, which reruns the script for that device alone.

The Desk runs ONE child at a time (§4.2): a preflight, a verify, the agent's signature check or a signing session,
which holds the lock until the script ends. A second request while one runs is answered 409 "busy".

Stdlib only. Pinned by test_release_desk.py (--mutate).
"""

import base64
import datetime
import getpass
import hashlib
import html
import json
import os
import re
import select
import signal
import socket
import socketserver
import stat
import subprocess
import sys
import tempfile
import termios
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

PORT = 8770
IDLE = 900
CHILD_TIMEOUT = 3600   # a preflight reads every target-files zip
AGENT_TIMEOUT = 60
BODY_MAX = 4096
MANIFEST_MAX = 1 << 20
BN_RE = re.compile(r"[0-9]{10}")
DEV_RE = re.compile(r"[a-z0-9]+")
COMMIT_RE = re.compile(r"[0-9a-f]{7,40}")
SIG_RE = re.compile(r"[A-Za-z0-9_-]{1,200}={0,2}")
VERSION_RE = re.compile(r"[0-9]+(\.[0-9]+){1,3}")
SHA_RE = re.compile(r"[0-9a-f]{64}")
LOGIN_RE = re.compile(r"[\x21-\x7e]{1,256}")
LINE_RE = re.compile(r"PREFLIGHT\t(OK|FAIL|WARN)\t(-|[a-z0-9]+)\t([a-z0-9-]+)\t(.*)")
SIGFILE_RE = r"^([a-z0-9]+)-manifest-([0-9]{10})\.json\.sig$"
SIGN_TIMEOUT_PER_DEVICE = 7200   # a signing session may run this long per device before its group is sent TERM
SIGN_KILL_GRACE = 60             # after TERM, the seconds before KILL
PASS_MAX = 1024                  # UTF-8 bytes; a canonical-mode pty line holds 4095
PASS_BAD_RE = re.compile(r"[\x00-\x1f\x7f]")   # a canonical-mode pty acts on ^C, ^U, ^D, erase and LF
# The literals of sign-release.sh the Desk parses. test_parsed_strings_are_in_sign_release pins each one.
SIGN_PROMPT = "passphrase for the release keys"
SIGN_WRONG = "the passphrase does not open"
SIGN_FINALIZE = ": finalize"
SIGN_DONE = "RELEASE DONE"
SIGN_FAILED = "FAILED"
SIGN_SIGNED = "signed"

# One plain sentence per check id of `sign-release.sh --preflight-only` (M04a). Draft words for Chester.
# An id not listed here shows the script's own text.
CHECK_WORDS = {
    "commit": "The release's commit is not a commit the build host's code has. Ask the maintainer.",
    "ota-conf": "The build host has no store settings for the update check. Ask the maintainer.",
    "image": "A device's build is missing. Ask the maintainer to build it first.",
    "build-number": "A device's build carries a different build number. Ask the maintainer to rebuild it.",
    "build-type": "A device's build is a test build, not a release build. Ask the maintainer to rebuild it.",
    "os-ref": "A device's build is for another device. Ask the maintainer to rebuild it.",
    "source-commit": "The build host's copy of the code is not at the release's commit. Ask the maintainer.",
    "patch-markers": "A device's build is missing a system change it must carry. Ask the maintainer.",
    "ring": "A device's build does not carry its release settings. Ask the maintainer.",
    "keys": "A device's signing keys are missing or incomplete. Ask the maintainer. Do not make new keys.",
    "signer-key": "The signing key check failed. Ask the maintainer.",
    "support": "A device is past its GrapheneOS support. Ask the maintainer.",
    "ota-stamp": "The version number is not above the one phones already run. Ask the maintainer.",
    "tmpdir": "The build host does not have enough free disk space to sign. Ask the maintainer.",
    "stale-keys": "A signing session ended without removing its keys. Ask the maintainer to remove them.",
    "upstream-gate": "GrapheneOS changed its signing scripts. Ask the maintainer to check them before signing.",
    "session": "Another program of the signing user is running. Close it, or ask the maintainer.",
}
UNREADABLE = "The preflight's output could not be read."

CHILD_LOCK = threading.Lock()   # ONE child at a time across the Desk (§4.2)
ACTIVE_BN = None                # the release a signing session runs for; written only by the session, under the lock

# Draft words for Chester. Every word stage 5 adds to the page and its replies.
DESK_WORDS = {
    "header": "Follow a release, sign its device images, and place its manifest signatures.",
    "sign heading": "Sign the device images",
    "field": "Passphrase for the release keys",
    "sign": "Sign",
    "retry": "Retry this device",
    "not open": "Signing opens when the preflight is ready. The Desk must be on its private socket.",
    "waiting": "waiting",
    "signing": "signing",
    "signed": "signed",
    "failed": "failed",
    "result running": "The signing session runs. This page reloads every 10 seconds.",
    "result signed": "Every device is signed.",
    "result some failed": "Some devices failed. Use Retry this device.",
    "result wrong passphrase": "The passphrase does not open the keys. Nothing was signed. Try again.",
    "result refused before the prompt": "The signing script refused to start. Nothing was signed. Read the details.",
    "result timed out": "The signing session ran too long. The Desk stopped it. The keys were removed.",
    "result ended without a result": "The signing session ended without a result. Ask the maintainer.",
    "started": "The signing session started.",
    "not private": "The Desk is not on its private socket. It cannot sign.",
    "run the preflight first": "Run the preflight first.",
    "bad request": "Type the passphrase. Do not use control characters.",
    "busy": "The Desk is busy with another task. Try again later.",
    "this device has not failed": "This device has not failed.",
    "use Retry this device": "A device is already signed. Use Retry this device for each failed device.",
}


class UsageError(Exception):
    pass


class Refused(Exception):
    def __init__(self, reason, detail=""):
        Exception.__init__(self, reason)
        self.reason = reason
        self.detail = detail


# ---- paths -----------------------------------------------------------------------------------------------------------

def state_dir():
    d = os.environ.get("NOWHERE_DESK_STATE") or os.path.expanduser("~/.local/state/nowhere-release-desk")
    os.makedirs(d, mode=0o700, exist_ok=True)
    st = os.stat(d)
    if st.st_uid != os.getuid():
        raise SystemExit("release-desk: %s is not owned by this user" % d)
    if st.st_mode & 0o777 != 0o700:
        os.chmod(d, 0o700)
    return d


def sub(*parts):
    p = os.path.join(state_dir(), *parts)
    os.makedirs(os.path.dirname(p), mode=0o700, exist_ok=True)
    return p


def tree():
    return os.environ.get("ENDOSPORE_TREE") or "/mnt/build/graphene/grapheneos-2026110200"


def repo():
    return os.environ.get("ENDOSPORE_REPO") or "/mnt/build/nowhere-phone"


def agent_path():
    return os.environ.get("NOWHERE_AGENT") or "/tmp/agent_host"


def rel_dir(bn, dev):
    return os.path.join(tree(), "releases", bn, "release-%s-%s" % (dev, bn))


def manifest_path(bn, dev):
    return os.path.join(rel_dir(bn, dev), "%s-manifest-%s.json" % (dev, bn))


def sig_path(bn, dev):
    return manifest_path(bn, dev) + ".sig"


def webfactory_path(bn, dev):
    return os.path.join(rel_dir(bn, dev), "%s-webfactory-%s.zip" % (dev, bn))


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def write_atomic(path, data, mode=0o600):
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=d, prefix="." + os.path.basename(path) + ".")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def read_json(path):
    try:
        with open(path, "rb") as f:
            return json.loads(f.read().decode("utf-8"))
    except (OSError, ValueError):
        return None


def log_action(login, action, bn, device, result):
    """Append one line to log.jsonl. Only these six short fields: never a manifest's or a signature's bytes, and
    never a child's output."""
    line = json.dumps({"utc": utc_now(), "login": str(login), "action": str(action), "bn": str(bn),
                       "device": str(device), "result": str(result)}, sort_keys=False) + "\n"
    fd = os.open(sub("log.jsonl"), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        os.write(fd, line.encode("utf-8"))
    finally:
        os.close(fd)


# ---- open (the maintainer, in a shell) -------------------------------------------------------------------------------

def parse_open_args(argv):
    """-> (bn, commit, [(dev, out or None)]). The checks and words of sign-release.sh's own usage."""
    if len(argv) < 3:
        raise UsageError("name the build number, the verified commit and at least one device")
    bn, commit, rest = argv[0], argv[1], argv[2:]
    if not BN_RE.fullmatch(bn):
        raise UsageError("build number '%s' is not 10 digits" % bn)
    if not COMMIT_RE.fullmatch(commit):
        raise UsageError("commit '%s' is not 7-40 lowercase hex" % commit)
    devs = []
    for a in rest:
        d, out = a, None
        if ":" in a:
            d, out = a.split(":", 1)
            if not out:
                raise UsageError("device '%s' names an empty out dir" % d)
        if not DEV_RE.fullmatch(d):
            raise UsageError("bad device '%s' -- use lowercase alphanumerics" % d)
        if any(d == e for e, _ in devs):
            raise UsageError("device '%s' is named twice" % d)
        devs.append((d, out))
    return bn, commit, devs


def cmd_open(argv):
    try:
        bn, commit, devs = parse_open_args(argv)
    except UsageError as e:
        sys.stderr.write("usage: release_desk.py open <BN> <verified-commit> <dev>[:<out-dir>]...\n    %s\n" % e)
        return 2
    path = sub("releases", bn + ".json")
    if os.path.exists(path):
        sys.stderr.write("release_desk.py: release %s is already open\n" % bn)
        return 1
    who = "shell:" + getpass.getuser()
    rec = {"bn": bn, "commit": commit,
           "devices": [dict({"device": d}, **({"out": o} if o is not None else {})) for d, o in devs],
           "opened_utc": utc_now(), "opened_by": who}
    write_atomic(path, (json.dumps(rec, indent=1) + "\n").encode("utf-8"))
    log_action(who, "open", bn, ",".join(d for d, _ in devs), "opened")
    print("release %s opened: %s at %s" % (bn, " ".join(d for d, _ in devs), commit))
    return 0


def load_release(bn):
    if not BN_RE.fullmatch(bn or ""):
        return None
    rec = read_json(os.path.join(state_dir(), "releases", bn + ".json"))
    if not isinstance(rec, dict) or rec.get("bn") != bn:
        return None
    return rec


def release_devices(rec):
    return [d["device"] for d in rec.get("devices", [])]


def list_releases():
    d = os.path.join(state_dir(), "releases")
    try:
        names = sorted(os.listdir(d), reverse=True)
    except OSError:
        return []
    out = []
    for n in names:
        if n.endswith(".json"):
            rec = load_release(n[:-5])
            if rec is not None:
                out.append(rec)
    return out


# ---- children and their output ---------------------------------------------------------------------------------------

def parse_preflight(rc, text):
    """Pins M04a's grammar. -> {ready, readable, lines, last, rc}."""
    lines, readable, last, fail = [], True, None, False
    raw = text.splitlines()
    for i, ln in enumerate(raw):
        m = LINE_RE.fullmatch(ln)
        if m:
            level, dev, check, txt = m.groups()
            fail = fail or level == "FAIL"
            lines.append({"level": level, "device": dev, "check": check, "text": txt,
                          "words": CHECK_WORDS.get(check, "")})
            continue
        if i == len(raw) - 1 and (ln == "PREFLIGHT\tPASS" or re.fullmatch(r"PREFLIGHT\tREFUSED\t[0-9]+", ln)):
            last = "PASS" if ln.endswith("PASS") else "REFUSED"
            continue
        readable = False
    if last is None:
        readable = False
    ready = rc == 0 and readable and last == "PASS" and not fail
    return {"ready": ready, "readable": readable and rc == 0, "lines": lines, "last": last, "rc": rc}


def parse_verify(rc, text, devices):
    """-> {dev: "pass"|"fail"}. A device passes only when rc is 0 and its block has an ok line and no FAIL line."""
    blocks, cur = {}, None
    for ln in text.splitlines():
        m = re.fullmatch(r"== ([a-z0-9]+) ==", ln)
        if m:
            cur = m.group(1)
            blocks.setdefault(cur, [])
        elif cur is not None:
            blocks[cur].append(ln)
    res = {}
    for d in devices:
        b = blocks.get(d)
        ok = b is not None and any(x.startswith("    ok    ") for x in b)
        bad = b is None or any(x.startswith("    FAIL  ") for x in b)
        res[d] = "pass" if rc == 0 and ok and not bad else "fail"
    return res


def run_child(argv, env, out_path, err_path):
    """Run one child of the Desk, stdin /dev/null. -> rc (-9 when it ran past CHILD_TIMEOUT and was killed)."""
    with open(out_path, "wb") as out, open(err_path, "wb") as err:
        p = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=out, stderr=err, env=env)
        try:
            return p.wait(timeout=CHILD_TIMEOUT)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()
            return -9


def read_text(path, cap=1 << 20):
    try:
        with open(path, "rb") as f:
            return f.read(cap).decode("utf-8", "replace")
    except OSError:
        return ""


def preflight(login, rec):
    bn = rec["bn"]
    argv = ["bash", os.path.join(repo(), "editions/endospore/build/sign-release.sh"), "--preflight-only", bn,
            rec["commit"]]
    argv += [d["device"] + (":" + d["out"] if d.get("out") else "") for d in rec["devices"]]
    out, err = sub("results", bn, "preflight.stdout"), sub("results", bn, "preflight.stderr")
    rc = run_child(argv, dict(os.environ), out, err)
    res = parse_preflight(rc, read_text(out))
    res.update({"utc": utc_now(), "login": login})
    write_atomic(sub("results", bn, "preflight.json"), json.dumps(res).encode("utf-8"))
    log_action(login, "preflight", bn, "-", "ready" if res["ready"] else ("not ready" if res["readable"] else "red"))
    return res


def verify(login, rec):
    bn, devs = rec["bn"], release_devices(rec)
    argv = ["bash", os.path.join(repo(), "editions/endospore/build/verify-release.sh"), bn] + devs
    env = dict(os.environ)
    env["TREE"] = tree()
    out, err = sub("results", bn, "verify.stdout"), sub("results", bn, "verify.stderr")
    rc = run_child(argv, env, out, err)
    res = {"devices": parse_verify(rc, read_text(out), devs), "rc": rc, "utc": utc_now(), "login": login}
    write_atomic(sub("results", bn, "verify.json"), json.dumps(res).encode("utf-8"))
    log_action(login, "verify", bn, "-", " ".join("%s:%s" % kv for kv in sorted(res["devices"].items())))
    return res


# ---- signing (§4.3 item 3) -------------------------------------------------------------------------------------------

def sign_path(bn):
    return sub("results", bn, "sign.json")


def sign_out_path(bn):
    return sub("results", bn, "sign.out")


def load_sign(bn):
    """results/<BN>/sign.json, or None. A "running" record while this process runs no session for the release was left
    by a Desk that died mid-session: it reads as "ended without a result", its unfinished devices as failed."""
    rec = read_json(os.path.join(state_dir(), "results", bn, "sign.json"))
    if not isinstance(rec, dict) or not isinstance(rec.get("devices"), dict):
        return None
    if rec.get("result") == "running" and ACTIVE_BN != bn:
        rec["result"] = "ended without a result"
        for d in rec.get("session") or []:
            if rec["devices"].get(d) in ("waiting", "signing"):
                rec["devices"][d] = "failed"
    return rec


def valid_passphrase(v):
    """A non-empty string of at most PASS_MAX UTF-8 bytes with no C0 control and no DEL. An empty passphrase must
    never reach the script (an empty-but-defined password makes decrypt-keys prompt per key on /dev/tty)."""
    try:
        return (isinstance(v, str) and len(v) > 0 and len(v.encode("utf-8")) <= PASS_MAX
                and not PASS_BAD_RE.search(v))
    except UnicodeEncodeError:
        return False


def child_env():
    """The Desk's environment minus `password` and `PW`: the passphrase reaches the script only through the pty."""
    return {k: v for k, v in os.environ.items() if k not in ("password", "PW")}


def sign_argv(rec, devs):
    """`setsid --ctty` makes the pty the child's controlling terminal (sign-release.sh's `set -m` needs one, as tmux
    gives it today) and execs in place: bash stays a direct child of the Desk, never a double fork."""
    argv = ["setsid", "--ctty", "bash", os.path.join(repo(), "editions/endospore/build/sign-release.sh"), rec["bn"],
            rec["commit"]]
    return argv + [d["device"] + (":" + d["out"] if d.get("out") else "") for d in rec["devices"]
                   if d["device"] in devs]


SIGN_LINES = (
    (re.compile(r"== ([a-z0-9]+)%s( .*)?" % re.escape(SIGN_FINALIZE)), "signing"),
    (re.compile(r"== ([a-z0-9]+) %s( .*)?" % re.escape(SIGN_DONE)), "signed"),
    (re.compile(r"sign-release: ([a-z0-9]+) %s( .*)?" % SIGN_FAILED), "failed"),
    (re.compile(r"  ([a-z0-9]+) %s" % SIGN_SIGNED), "signed"),
    (re.compile(r"  ([a-z0-9]+) %s" % SIGN_FAILED), "failed"),
)


def parse_sign_line(line, devs, st):
    """One line of the script's output. -> True when a device of this session changed state."""
    if SIGN_WRONG in line:
        st["wrong"] = True
    for rx, state in SIGN_LINES:
        m = rx.fullmatch(line)
        if m and m.group(1) in devs and st["devices"].get(m.group(1)) != state:
            st["devices"][m.group(1)] = state
            return True
    return False


def save_sign(bn, st):
    rec = {k: v for k, v in st.items() if k != "wrong"}
    write_atomic(sign_path(bn), (json.dumps(rec, indent=1) + "\n").encode("utf-8"))


def restore_devices(st, devs, prev):
    """A session that signed nothing leaves each of its devices as it found them: a refused or wrong-passphrase Retry
    keeps the device failed, so Retry this device stays on the page."""
    for d in devs:
        st["devices"][d] = prev[d]  # restore: nothing was signed


def stop_group(p, sig):
    try:
        os.killpg(p.pid, sig)
    except ProcessLookupError:
        pass


def write_out(fd, chunk):
    """One chunk of the script's output into sign.out. A failed write (a full disk) ends the session."""
    os.write(fd, chunk)


def reap(p, m):
    """Ends a child the session gives up on and waits for it to exit: TERM to its group (sign-release.sh's TERM trap
    sweeps the key dirs), SIGN_KILL_GRACE seconds draining the pty so the trap's output never blocks it, then KILL.
    The session releases CHILD_LOCK only after this returns, so no second child starts during that cleanup."""
    if p.poll() is not None:
        return
    stop_group(p, signal.SIGTERM)
    end = time.monotonic() + SIGN_KILL_GRACE
    while p.poll() is None and time.monotonic() < end:
        if m is None:
            select.select([], [], [], 0.1)
            continue
        try:
            if select.select([m], [], [], 0.1)[0] and not os.read(m, 65536):
                m = None   # EOF: nothing more to drain
        except (OSError, ValueError):
            m = None
    if p.poll() is None:
        stop_group(p, signal.SIGKILL)
        p.wait()


def run_session(login, rec, devs, prev, box, st):
    """The signing session's thread. It holds CHILD_LOCK (taken by begin_sign) and releases it LAST. `box` is a
    one-element list holding the passphrase: it is written to the pty once, after the prompt, and the list is then
    emptied. It is never stored anywhere else."""
    global ACTIVE_BN
    bn = rec["bn"]
    m = s = out = p = None
    written = timed_out = False
    st["wrong"] = False
    result, logged = None, None
    try:
        m, s = os.openpty()
        attrs = termios.tcgetattr(s)
        attrs[3] &= ~(termios.ECHO | termios.ECHONL)
        termios.tcsetattr(s, termios.TCSANOW, attrs)
        out = os.open(sign_out_path(bn), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.fchmod(out, 0o600)
        try:
            p = subprocess.Popen(sign_argv(rec, devs), stdin=s, stdout=s, stderr=s, env=child_env(), close_fds=True)
        except OSError:
            p = None
        os.close(s)
        s = None
        if p is None:
            box.clear()
            result, logged = "ended without a result", "could not start"
            restore_devices(st, devs, prev)
            return
        deadline = time.monotonic() + SIGN_TIMEOUT_PER_DEVICE * len(devs)
        kill_at = None
        tail, part = b"", b""
        while True:
            now = time.monotonic()
            if not timed_out and now >= deadline:
                timed_out = True
                os.killpg(p.pid, signal.SIGTERM)
                kill_at = now + SIGN_KILL_GRACE
            if kill_at is not None and now >= kill_at:
                stop_group(p, signal.SIGKILL)
                kill_at = None
            until = kill_at if kill_at is not None else (deadline if not timed_out else now + 1)
            r, _, _ = select.select([m], [], [], max(0.0, min(1.0, until - now)))
            if not r:
                if p.poll() is not None:
                    break   # an orphan holding the slave must not hold the session
                continue
            try:
                chunk = os.read(m, 65536)
            except OSError:
                chunk = b""
            if not chunk:
                break
            write_out(out, chunk)
            if box:
                tail = (tail + chunk)[-4096:]
                if SIGN_PROMPT.encode("utf-8") in tail:
                    os.write(m, box[0].encode("utf-8") + b"\n")
                    box.clear()
                    written = True
            lines = (part + chunk).split(b"\n")
            part = lines.pop()
            changed = False
            for ln in lines:
                changed = parse_sign_line(ln.decode("utf-8", "replace").rstrip("\r"), devs, st) or changed
            if changed:
                save_sign(bn, st)
        if part:
            parse_sign_line(part.decode("utf-8", "replace").rstrip("\r"), devs, st)
        try:
            st["rc"] = p.wait(timeout=SIGN_KILL_GRACE)
        except subprocess.TimeoutExpired:
            stop_group(p, signal.SIGKILL)
            st["rc"] = p.wait()
        if not written:
            result = "timed out" if timed_out else "refused before the prompt"
            restore_devices(st, devs, prev)
        elif st["wrong"]:
            result = "wrong passphrase"
            restore_devices(st, devs, prev)
        else:
            for d in devs:
                if st["devices"].get(d) in ("waiting", "signing"):
                    st["devices"][d] = "failed"
            if timed_out:
                result = "timed out"
            elif st["rc"] == 0 and all(v == "signed" for v in st["devices"].values()):
                result = "signed"
            else:
                result = "some failed"
    except Exception:
        result, logged = "ended without a result", "error"
        for d in devs:
            if st["devices"].get(d) in ("waiting", "signing"):
                st["devices"][d] = "failed"
    finally:
        box.clear()
        if p is not None:
            reap(p, m)
        for fd in (m, s, out):
            if fd is not None:
                try:
                    os.close(fd)
                except OSError:
                    pass
        try:
            st["result"] = result or "ended without a result"
            st["ended_utc"] = utc_now()
            save_sign(bn, st)
            log_action(login, "sign", bn, ",".join(devs), logged or st["result"])
        finally:
            ACTIVE_BN = None
            CHILD_LOCK.release()


def begin_sign(login, rec, passphrase, device):
    """POST /api/release/<BN>/sign after the handler's checks. -> (status, reply). Starts the session thread, which
    then owns CHILD_LOCK; every refusal here releases it and starts nothing."""
    global ACTIVE_BN
    bn = rec["bn"]
    devs = [device] if device is not None else release_devices(rec)
    what = ",".join(devs)
    if not CHILD_LOCK.acquire(blocking=False):
        log_action(login, "sign", bn, what, "busy")
        return 409, {"error": "busy"}
    started = False
    try:
        if (read_json(os.path.join(state_dir(), "results", bn, "preflight.json")) or {}).get("ready") is not True:
            refusal = "run the preflight first"
        else:
            cur = (load_sign(bn) or {}).get("devices") or {}
            if device is not None and cur.get(device) != "failed":
                refusal = "this device has not failed"
            elif device is None and any(cur.get(d) == "signed" for d in release_devices(rec)):
                refusal = "use Retry this device"
            else:
                refusal = None
        if refusal:
            log_action(login, "sign", bn, what, "refused: " + refusal)
            return 409, {"error": refusal}
        prev = {d: cur.get(d, "waiting") for d in devs}
        devices = dict(cur) if device is not None else {}
        for d in release_devices(rec):
            devices.setdefault(d, "waiting")
        for d in devs:
            devices[d] = "waiting"
        st = {"result": "running", "devices": devices, "session": devs, "prev": prev, "rc": None, "login": login,
              "started_utc": utc_now(), "ended_utc": None}
        ACTIVE_BN = bn
        save_sign(bn, st)
        log_action(login, "sign", bn, what, "started")
        threading.Thread(target=run_session, args=(login, rec, devs, prev, [passphrase], st), daemon=True).start()
        started = True
        return 202, {"result": "started"}
    finally:
        if not started:
            ACTIVE_BN = None
            CHILD_LOCK.release()


def release_state(rec):
    bn, devs = rec["bn"], release_devices(rec)
    pf = read_json(os.path.join(state_dir(), "results", bn, "preflight.json")) or {}
    vf = read_json(os.path.join(state_dir(), "results", bn, "verify.json")) or {}
    verified = bool(devs) and all((vf.get("devices") or {}).get(d) == "pass" for d in devs)
    if verified:
        sigs = [os.path.isfile(sig_path(bn, d)) for d in devs]
        mans = [os.path.isfile(manifest_path(bn, d)) for d in devs]
        if all(sigs):
            return "done"
        if any(m and not s for m, s in zip(mans, sigs)):
            return "waiting for manifest signatures"
        return "verified"
    if ACTIVE_BN == bn:
        return "signing"
    if devs and all(((load_sign(bn) or {}).get("devices") or {}).get(d) == "signed" for d in devs):
        return "signed"
    if pf.get("ready") is True:
        return "ready to sign"
    return "waiting for preflight"


# ---- manifests out, signatures in (§5.4) -----------------------------------------------------------------------------

def read_manifest(bn, dev):
    try:
        with open(manifest_path(bn, dev), "rb") as f:
            data = f.read(MANIFEST_MAX + 1)
    except OSError:
        return None
    return data if 0 < len(data) <= MANIFEST_MAX else None


def record_handout(login, bn, dev, data, how):
    """The ONLY writer of handouts/<BN>/<dev>: the sha256 of the exact bytes that left the Desk for signing."""
    write_atomic(sub("handouts", bn, dev), hashlib.sha256(data).hexdigest().encode("ascii"))
    log_action(login, "handout", bn, dev, how)


def handout(login):
    """GET /api/manifests: every open release's device manifest that is on disk and has no .sig yet."""
    out = []
    for rec in list_releases():
        bn = rec["bn"]
        for dev in release_devices(rec):
            if os.path.exists(sig_path(bn, dev)):
                continue
            data = read_manifest(bn, dev)
            if data is None:
                continue
            record_handout(login, bn, dev, data, "listed")
            out.append({"bn": bn, "device": dev, "name": "%s-manifest-%s.json" % (dev, bn),
                        "manifest": base64.b64encode(data).decode("ascii"),
                        "sha256": hashlib.sha256(data).hexdigest()})
    return out


def manifest_download(login, bn, dev):
    """GET /release/<BN>/manifest/<dev>, the Signer's drag-and-drop mode. Reads the file ONCE, records the hash of
    those bytes and returns them. None when the release or device is unknown, the manifest is absent, or it is
    already signed."""
    rec = load_release(bn)
    if rec is None or not DEV_RE.fullmatch(dev) or dev not in release_devices(rec):
        return None
    if os.path.exists(sig_path(bn, dev)):
        return None
    data = read_manifest(bn, dev)
    if data is None:
        return None
    record_handout(login, bn, dev, data, "downloaded")
    return data


def file_sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(1 << 20)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def check_handout(bn, dev, data):
    want = read_text(os.path.join(state_dir(), "handouts", bn, dev)).strip()
    if not want:
        raise Refused("manifest was never handed out")
    if data is None or hashlib.sha256(data).hexdigest() != want:
        raise Refused("manifest changed after it was handed out")


def manifest_fields(data):
    try:
        m = json.loads(data.decode("utf-8"))
        version = m["ota"]["version"]
        size = m["images"][0]["size"]
        sha = m["images"][0]["sha256"]
    except (ValueError, KeyError, IndexError, TypeError, AttributeError):
        raise Refused("manifest fields unreadable")
    if not (isinstance(version, str) and VERSION_RE.fullmatch(version) and type(size) is int and size >= 0
            and isinstance(sha, str) and SHA_RE.fullmatch(sha)):
        raise Refused("manifest fields unreadable")
    return version, size, sha


def check_webfactory(bn, dev, size, sha):
    p = webfactory_path(bn, dev)
    try:
        ok = os.stat(p).st_size == size and file_sha256(p) == sha
    except OSError:
        ok = False
    if not ok:
        raise Refused("webfactory zip does not match the manifest")


def check_agent(bn, dev, data, sig, version, sdir):
    """The phone's own check: `<agent> ota-release-check <manifest> <sig> <dev> <version> <ota-mandatory file>`, run
    on a private copy of exactly the bytes checked above. -> the agent's first output line."""
    agent = agent_path()
    if not (os.path.isfile(agent) and os.access(agent, os.X_OK)):
        raise Refused("agent missing")
    man, sg = os.path.join(sdir, "manifest.json"), os.path.join(sdir, "manifest.json.sig")
    with open(man, "wb") as f:
        f.write(data)
    with open(sg, "w") as f:
        f.write(sig)
    mand = os.path.join(repo(), "editions/endospore/ota-mandatory", version)
    p = subprocess.Popen([agent, "ota-release-check", man, sg, dev, version, mand], stdin=subprocess.DEVNULL,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        out, _ = p.communicate(timeout=AGENT_TIMEOUT)
    except subprocess.TimeoutExpired:
        p.kill()
        out, _ = p.communicate()
    rc = p.returncode
    first = (out.decode("utf-8", "replace").splitlines() or [""])[0][:300]
    write_atomic(sub("sigs", bn, dev + ".out"), out[:65536])
    if rc != 0:
        raise Refused("signature does not pass the phone's check", first)
    return first


def place_signature(login, bn, dev, sig):
    """§5.4. -> (http status, reply). Every refusal is named in the reply and the log; nothing is written for it."""
    rec = load_release(bn)
    if rec is None or dev not in release_devices(rec):
        return 404, {"result": "refused", "reason": "unknown release or device"}
    if not CHILD_LOCK.acquire(blocking=False):
        log_action(login, "signature", bn, dev, "busy")
        return 409, {"error": "busy"}
    sdir = None
    try:
        sdir = tempfile.mkdtemp(dir=os.path.dirname(sub("tmp", "x")))
        data = read_manifest(bn, dev)
        check_handout(bn, dev, data)
        version, size, sha = manifest_fields(data)
        check_webfactory(bn, dev, size, sha)
        check_agent(bn, dev, data, sig, version, sdir)
        sp = sig_path(bn, dev)
        if os.path.exists(sp):
            if read_text(sp).strip() == sig.strip():
                return done(login, bn, dev, 200, "already placed")
            raise Refused("a different signature is already placed")
        # The fixed reference is the bytes the agent checked, never the handout record: a GET during the check
        # can record a new hash for a changed manifest, and A's signature must not land beside B.
        if read_manifest(bn, dev) != data:
            raise Refused("manifest changed after it was handed out")
        fd, tmp = tempfile.mkstemp(dir=rel_dir(bn, dev), prefix=".%s.sig." % os.path.basename(manifest_path(bn, dev)))
        try:
            with os.fdopen(fd, "w") as f:
                f.write(sig)
                f.flush()
                os.fsync(f.fileno())
            os.chmod(tmp, 0o644)
            os.replace(tmp, sp)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
        return done(login, bn, dev, 200, "placed")
    except Refused as r:
        reply = {"result": "refused", "reason": r.reason}
        if r.detail:
            reply["detail"] = r.detail
        log_action(login, "signature", bn, dev, "refused: " + r.reason)
        write_atomic(sub("sigs", bn, dev + ".json"),
                     json.dumps({"utc": utc_now(), "login": login, "result": "refused: " + r.reason}).encode())
        return 422, reply
    finally:
        if sdir:
            for n in os.listdir(sdir):
                os.unlink(os.path.join(sdir, n))
            os.rmdir(sdir)
        CHILD_LOCK.release()


def done(login, bn, dev, status, result):
    log_action(login, "signature", bn, dev, result)
    write_atomic(sub("sigs", bn, dev + ".json"),
                 json.dumps({"utc": utc_now(), "login": login, "result": result}).encode())
    return status, {"result": result}


# ---- pages -----------------------------------------------------------------------------------------------------------

STYLE = """body{font:15px/1.4 system-ui,sans-serif;margin:2em;max-width:60em;color:#222}
h1{font-size:1.3em}h2{font-size:1.1em;margin-top:1.5em}table{border-collapse:collapse}
td,th{padding:.2em .6em;text-align:left;vertical-align:top}.ok{color:#1a7f37}.warn{color:#9a6700}
.fail{color:#cf222e}.small{font-size:.85em;color:#555}#drop{border:2px dashed #888;padding:1.5em;margin-top:1em}
button{font-size:1em;padding:.3em .8em}"""

SCRIPT = """function run(u){var b=document.querySelectorAll('button');for(var i=0;i<b.length;i++)b[i].disabled=true;
document.getElementById('msg').textContent='Running. This can take some minutes.';
fetch(u,{method:'POST'}).then(function(r){return r.json().then(function(j){
if(r.status==409){document.getElementById('msg').textContent='The Desk is busy with another check. Try again later.';
for(var i=0;i<b.length;i++)b[i].disabled=false;}else{location.reload();}});});}
var dz=document.getElementById('drop');
if(dz){dz.addEventListener('dragover',function(e){e.preventDefault();});
dz.addEventListener('drop',function(e){e.preventDefault();var fs=e.dataTransfer.files;
for(var i=0;i<fs.length;i++)(function(f){var out=document.getElementById('dropout');var li=document.createElement('li');
out.appendChild(li);var m=f.name.match(/%s/);
if(!m){li.textContent=f.name+': not a Manifest Signer .sig file';return;}
f.text().then(function(t){return fetch('/api/signatures',{method:'POST',headers:{'Content-Type':'application/json'},
body:JSON.stringify({bn:m[2],device:m[1],sig:t.trim()})});}).then(function(r){return r.json();}).then(function(j){
li.textContent=f.name+': '+(j.result=='refused'?'refused: '+j.reason:(j.result||j.error));});})(fs[i]);});}
function sign(d){var f=document.getElementById(d?'pp-'+d:'pp');var q={passphrase:f.value};f.value='';
if(d)q.device=d;var b=document.querySelectorAll('button');for(var i=0;i<b.length;i++)b[i].disabled=true;
fetch('/api'+location.pathname+'/sign',{method:'POST',headers:{'Content-Type':'application/json'},
body:JSON.stringify(q)}).then(function(r){q=null;return r.json().then(function(j){
if(r.status==202){location.reload();return;}
document.getElementById('msg').textContent=W[j.error]||j.error;for(var i=0;i<b.length;i++)b[i].disabled=false;});});}
""" % SIGFILE_RE


def page(title, body, script=True, refresh=False):
    words = json.dumps(DESK_WORDS).replace("<", "\\u003c")
    s = "<script>%s\nvar W=%s;</script>" % (SCRIPT, words) if script else ""
    r = "<meta http-equiv=refresh content=10>" if refresh else ""
    return ("<!doctype html><html><head><meta charset=utf-8>%s<title>%s</title><style>%s</style></head><body>"
            "<h1>Nowhere Release Desk</h1><p class=small>%s</p>%s%s"
            "</body></html>" % (r, html.escape(title), STYLE, html.escape(DESK_WORDS["header"]), body, s)
            ).encode("utf-8")


def index_page():
    rows = []
    for rec in list_releases():
        bn = rec["bn"]
        rows.append("<tr><td><a href=\"/release/%s\">%s</a></td><td>%s</td><td>commit %s</td><td>%s</td></tr>" % (
            bn, bn, html.escape(", ".join(release_devices(rec))), html.escape(rec["commit"][:7]),
            html.escape(release_state(rec))))
    body = "<h2>Releases</h2>"
    body += "<table>%s</table>" % "".join(rows) if rows else "<p>No release is open. The maintainer opens one.</p>"
    return page("Releases", body, script=False)


def sign_open(private, rec):
    """The one predicate for the passphrase field: the Desk is on its private socket and the release is ready."""
    return private is True and release_state(rec) == "ready to sign"


def sign_section(rec, private):
    bn = rec["bn"]
    e = html.escape
    sg = load_sign(bn) or {}
    states = sg.get("devices") or {}
    is_open = sign_open(private, rec)
    b = ["<h2>%s</h2>" % e(DESK_WORDS["sign heading"])]
    if sg:
        b.append("<p>%s</p>" % e(DESK_WORDS.get("result " + str(sg.get("result")), str(sg.get("result")))))
    b.append("<table>")
    for dev in release_devices(rec):
        ds = states.get(dev, "waiting")
        cls = {"signed": "ok", "failed": "fail"}.get(ds, "")
        retry = ""
        if is_open and ds == "failed":
            retry = (" <input type=password autocomplete=off id=pp-%s aria-label=\"%s\"> "
                     "<button onclick=\"sign('%s')\">%s</button>") % (dev, e(DESK_WORDS["field"]), dev,
                                                                    e(DESK_WORDS["retry"]))
        b.append("<tr><td>%s</td><td class=%s>%s</td><td>%s</td></tr>" % (
            e(dev), cls or "small", e(DESK_WORDS.get(ds, ds)), retry))
    b.append("</table>")
    if sg:
        b.append("<p><a href=\"/release/%s/details/sign\">Details</a></p>" % bn)
    if is_open and not any(states.get(d) == "signed" for d in release_devices(rec)):
        b.append("<p><label>%s <input type=password autocomplete=off id=pp></label> "
                 "<button onclick=\"sign('')\">%s</button></p>" % (e(DESK_WORDS["field"]), e(DESK_WORDS["sign"])))
    elif not is_open and release_state(rec) in ("waiting for preflight", "ready to sign"):
        b.append("<p class=small>%s</p>" % e(DESK_WORDS["not open"]))
    return "".join(b)


def release_page(rec, private):
    bn = rec["bn"]
    e = html.escape
    pf = read_json(os.path.join(state_dir(), "results", bn, "preflight.json"))
    vf = read_json(os.path.join(state_dir(), "results", bn, "verify.json"))
    state = release_state(rec)
    b = ["<p><a href=\"/\">All releases</a></p>",
         "<h2>Release %s</h2><p>Commit %s, opened by %s. State: <b>%s</b>.</p>" % (
             bn, e(rec["commit"]), e(rec.get("opened_by", "")), e(state)),
         "<p id=msg></p>",
         "<h2>Preflight</h2><p><button onclick=\"run('/api/release/%s/preflight')\">Run the preflight</button></p>" % bn]
    if pf:
        if not pf.get("readable"):
            b.append("<p class=fail>%s (exit code %s)</p>" % (UNREADABLE, e(str(pf.get("rc")))))
        b.append("<p>Last run %s: %s</p>" % (e(pf.get("utc", "")),
                                                "ready to sign" if pf.get("ready") else "<span class=fail>not ready</span>"))
        b.append("<table>")
        for ln in pf.get("lines", []):
            cls = {"OK": "ok", "WARN": "warn"}.get(ln["level"], "fail")
            mark = {"OK": "&#10003;", "WARN": "!"}.get(ln["level"], "&#10007;")
            words = ln.get("words") if ln["level"] != "OK" else ""
            b.append("<tr class=%s><td>%s</td><td>%s</td><td>%s</td><td>%s<div class=small>%s</div></td></tr>" % (
                cls, mark, e("" if ln["device"] == "-" else ln["device"]), e(ln["check"]), e(words or ""),
                e(ln["text"])))
        b.append("</table><p><a href=\"/release/%s/details/preflight\">Details</a></p>" % bn)
    b.append(sign_section(rec, private))
    b.append("<h2>Verify</h2><p><button onclick=\"run('/api/release/%s/verify')\">Run verify</button></p>" % bn)
    if vf:
        b.append("<p>Last run %s: %s <a href=\"/release/%s/details/verify\">Details</a></p>" % (
            e(vf.get("utc", "")), " ".join("%s <span class=%s>%s</span>" % (
                e(d), "ok" if r == "pass" else "fail", r) for d, r in sorted((vf.get("devices") or {}).items())), bn))
    b.append("<h2>Manifests</h2><table>")
    for dev in release_devices(rec):
        name = "%s-manifest-%s.json" % (dev, bn)
        last = read_json(os.path.join(state_dir(), "sigs", bn, dev + ".json")) or {}
        det = ""
        if os.path.exists(os.path.join(state_dir(), "sigs", bn, dev + ".out")):
            det = " <a href=\"/release/%s/details/sig-%s\">Details</a>" % (bn, dev)
        if os.path.exists(sig_path(bn, dev)):
            st = "<span class=ok>placed</span>"
        elif not os.path.exists(manifest_path(bn, dev)):
            st = "not built yet"
        else:
            st = "waiting for a signature <a href=\"/release/%s/manifest/%s\" download>Download for the Signer</a>" % (
                bn, dev)
            if str(last.get("result", "")).startswith("refused"):
                st = "<span class=fail>%s</span>, %s" % (e(last["result"]), st)
        b.append("<tr><td>%s</td><td>%s%s</td></tr>" % (e(name), st, det))
    b.append("</table><div id=drop>Drop the Manifest Signer's .sig files here.</div><ul id=dropout></ul>")
    return page("Release " + bn, "".join(b), refresh=state == "signing")


# ---- the server ------------------------------------------------------------------------------------------------------

class Desk(ThreadingHTTPServer):
    daemon_threads = True

    def server_bind(self):
        # HTTPServer.server_bind asks DNS for this host's full name (socket.getfqdn), which the Desk never uses.
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]

    def process_request_thread(self, request, client_address):
        with self.act_lock:
            self.inflight += 1
            self.last_activity = time.monotonic()
        try:
            ThreadingHTTPServer.process_request_thread(self, request, client_address)
        finally:
            with self.act_lock:
                self.inflight -= 1
                self.last_activity = time.monotonic()


class UnsafeSocketPath(Exception):
    pass


class UnixDesk(Desk):
    """The Desk on an AF_UNIX socket: a systemd fd or `serve --socket PATH`. server_address is the path."""
    address_family = socket.AF_UNIX
    owned = None  # (st_dev, st_ino) of a socket file this Desk bound itself; None for a systemd fd

    def server_bind(self):
        # The same no-DNS rule as Desk.server_bind.
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address, None

    def server_close(self):
        Desk.server_close(self)
        if self.owned is None:
            return
        try:
            st = os.lstat(self.server_address)
        except FileNotFoundError:
            return
        if (st.st_dev, st.st_ino) == self.owned:
            os.unlink(self.server_address)
        self.owned = None


def idle_expired(desk, now):
    with desk.act_lock:
        return desk.inflight == 0 and not CHILD_LOCK.locked() and now - desk.last_activity >= desk.idle


def systemd_fd(env, pid):
    """3 when systemd passed this process exactly one listening socket, else None."""
    if env.get("LISTEN_PID") == str(pid) and env.get("LISTEN_FDS") == "1":
        return 3
    return None


def unix_server(path):
    """Bind the Desk at path, private: the directory is this user's and closed to group and other, the socket 0600."""
    d = os.path.dirname(os.path.abspath(path))
    st = os.stat(d)
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077:
        raise UnsafeSocketPath("%s is not a directory of this user closed to group and other" % d)
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        pass
    else:
        if not stat.S_ISSOCK(st.st_mode) or st.st_uid != os.getuid():
            raise UnsafeSocketPath("%s exists and is not a socket of this user" % path)
        os.unlink(path)
    old = os.umask(0o177)
    try:
        desk = UnixDesk(path, Handler)
    finally:
        os.umask(old)
    st = os.lstat(path)
    desk.owned = (st.st_dev, st.st_ino)
    return desk


def make_server(name, port, idle, fd=None, path=None):
    if fd is not None:
        sock = socket.socket(fileno=fd)
        if sock.family == socket.AF_UNIX:
            desk = UnixDesk(sock.getsockname(), Handler, bind_and_activate=False)
        else:
            desk = Desk(sock.getsockname()[:2], Handler, bind_and_activate=False)
        desk.socket.close()
        desk.socket = sock
    elif path is not None:
        desk = unix_server(path)
    else:
        desk = Desk(("127.0.0.1", port), Handler)
    # private: only the signing user and root can connect (an AF_UNIX socket). Stage 5's Sign requires it.
    desk.private = desk.socket.family == socket.AF_UNIX
    desk.name = name.strip().lower()
    desk.port = None if desk.private else desk.server_address[1]
    desk.idle = idle
    desk.inflight = 0
    desk.act_lock = threading.Lock()
    desk.last_activity = time.monotonic()
    return desk


class Handler(BaseHTTPRequestHandler):
    server_version = "nowhere-release-desk"
    sys_version = ""

    def log_message(self, *a):  # quiet: the Desk's own log is log.jsonl
        pass

    def login(self):
        return self.headers.get("Tailscale-User-Login", "")

    def own_origin(self, host):
        return "https://" + host if host == self.server.name else "http://" + host

    def gate(self, path):
        """Login header, then Host, then (POST except /api/signatures) Origin. -> True when the request may go on.

        The Host is the tailnet name; only a TCP Desk also accepts 127.0.0.1:<port>. The sign route is never
        exempt: it is not a CORS route."""
        if not LOGIN_RE.fullmatch(self.login()):
            return self.deny("no Tailscale login")
        host = (self.headers.get("Host") or "").strip().lower()
        if self.server.private and host == "localhost":
            # `tailscale serve` to a unix: target sends `Host: localhost` and the name the browser used in
            # X-Forwarded-Host (Tailscale 1.104.5 on the build host, 2026-11-17, NWP-20261116-60). Only the signing
            # user and root can reach the private socket, the same trust the login header already rests on; a TCP
            # Desk never reads this header.
            host = (self.headers.get("X-Forwarded-Host") or "").strip().lower()
        loopback = not self.server.private and host == "127.0.0.1:%d" % self.server.port
        if host != self.server.name and not loopback:
            return self.deny("wrong host")
        if self.command == "POST" and path != "/api/signatures":
            if self.headers.get("Origin") != self.own_origin(host):
                return self.deny("cross-origin request")
        return True

    def deny(self, why):
        self.reply(403, json.dumps({"error": why}).encode(), "application/json")
        return False

    def cors(self):
        self.send_header("Access-Control-Allow-Origin", "null")

    def reply(self, status, body, ctype, cors=False, extra=()):
        self.send_response(status)
        if cors:
            self.cors()
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        if ctype.startswith("text/html"):
            self.send_header("Content-Security-Policy", "default-src 'none'; script-src 'unsafe-inline'; "
                             "style-src 'unsafe-inline'; connect-src 'self'")
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def json(self, status, obj, cors=False):
        self.reply(status, json.dumps(obj).encode("utf-8"), "application/json", cors=cors)

    def do_OPTIONS(self):
        path = urlsplit(self.path).path
        if not self.gate(path):
            return
        if path in ("/api/manifests", "/api/signatures"):
            self.send_response(204)
            self.cors()
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "Content-Type")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.json(404, {"error": "not found"})

    def do_GET(self):
        path = urlsplit(self.path).path
        if not self.gate(path):
            return
        if path == "/":
            return self.reply(200, index_page(), "text/html; charset=utf-8")
        if path == "/api/manifests":
            return self.json(200, handout(self.login()), cors=True)
        m = re.fullmatch(r"/release/([0-9]{10})", path)
        if m:
            rec = load_release(m.group(1))
            if rec is None:
                return self.json(404, {"error": "unknown release"})
            return self.reply(200, release_page(rec, getattr(self.server, "private", False) is True),
                              "text/html; charset=utf-8")
        m = re.fullmatch(r"/release/([0-9]{10})/manifest/([a-z0-9]+)", path)
        if m:
            bn, dev = m.groups()
            data = manifest_download(self.login(), bn, dev)
            if data is None:
                return self.json(404, {"error": "no manifest waiting for a signature"})
            return self.reply(200, data, "application/json", extra=[
                ("Content-Disposition", "attachment; filename=\"%s-manifest-%s.json\"" % (dev, bn))])
        m = re.fullmatch(r"/api/release/([0-9]{10})/sign", path)
        if m:
            sg = load_sign(m.group(1)) if load_release(m.group(1)) is not None else None
            if sg is None:
                return self.json(404, {"error": "no signing session"})
            return self.json(200, sg)
        m = re.fullmatch(r"/release/([0-9]{10})/details/(preflight|verify|sign|sig-[a-z0-9]+)", path)
        if m and load_release(m.group(1)) is not None:
            bn, kind = m.groups()
            d = os.path.join(state_dir(), "results", bn)
            if kind == "preflight":
                text = read_text(os.path.join(d, "preflight.stderr"))
            elif kind == "verify":
                text = read_text(os.path.join(d, "verify.stdout")) + read_text(os.path.join(d, "verify.stderr"))
            elif kind == "sign":
                text = read_text(os.path.join(d, "sign.out"))
            else:
                text = read_text(os.path.join(state_dir(), "sigs", bn, kind[4:] + ".out"))
            return self.reply(200, text.encode("utf-8"), "text/plain; charset=utf-8")
        self.json(404, {"error": "not found"})

    def do_POST(self):
        path = urlsplit(self.path).path
        if not self.gate(path):
            return
        if path == "/api/signatures":
            return self.signatures()
        m = re.fullmatch(r"/api/release/([0-9]{10})/sign", path)
        if m:
            return self.sign(m.group(1))
        m = re.fullmatch(r"/api/release/([0-9]{10})/(preflight|verify)", path)
        if not m:
            return self.json(404, {"error": "not found"})
        self.drain()
        rec = load_release(m.group(1))
        if rec is None:
            return self.json(404, {"error": "unknown release"})
        login = self.login()
        if not CHILD_LOCK.acquire(blocking=False):
            log_action(login, m.group(2), rec["bn"], "-", "busy")
            return self.json(409, {"error": "busy"})
        try:
            res = preflight(login, rec) if m.group(2) == "preflight" else verify(login, rec)
        finally:
            CHILD_LOCK.release()
        self.json(200, res)

    def drain(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            n = 0
        if 0 < n <= BODY_MAX:
            self.rfile.read(n)

    def sign(self, bn):
        """POST /api/release/<BN>/sign, {"passphrase": s} or {"passphrase": s, "device": d} (Retry this device). The
        body is never echoed in a reply or a log, and the passphrase is never stored: begin_sign hands it to the
        session thread, which writes it to the pty once."""
        login = self.login()
        if getattr(self.server, "private", False) is not True:
            self.drain()
            log_action(login, "sign", bn, "-", "refused: not private")
            return self.json(403, {"error": "not private"})
        rec = load_release(bn)
        if rec is None:
            self.drain()
            return self.json(404, {"error": "unknown release"})
        cl = self.headers.get("Content-Length")
        if cl is None:
            return self.json(411, {"error": "length required"})
        try:
            n = int(cl)
        except ValueError:
            n = -1
        if n < 0 or n > BODY_MAX:
            return self.json(413, {"error": "body too large"})
        try:
            req = json.loads(self.rfile.read(n).decode("utf-8"))
            good = (isinstance(req, dict) and set(req) <= {"passphrase", "device"}
                    and valid_passphrase(req.get("passphrase"))
                    and ("device" not in req or (isinstance(req["device"], str)
                                                 and DEV_RE.fullmatch(req["device"]) is not None)))
        except (ValueError, UnicodeDecodeError):
            req, good = None, False
        if not good:
            req = None
            log_action(login, "sign", bn, "-", "refused: bad request")
            return self.json(400, {"error": "bad request"})
        device = req.get("device")
        if device is not None and device not in release_devices(rec):
            req = None
            return self.json(404, {"error": "unknown device"})
        status, reply = begin_sign(login, rec, req.pop("passphrase"), device)
        req = None
        self.json(status, reply)

    def signatures(self):
        cl = self.headers.get("Content-Length")
        if cl is None:
            return self.json(411, {"result": "refused", "reason": "length required"}, cors=True)
        try:
            n = int(cl)
        except ValueError:
            n = -1
        if n < 0 or n > BODY_MAX:
            return self.json(413, {"result": "refused", "reason": "body too large"}, cors=True)
        try:
            req = json.loads(self.rfile.read(n).decode("utf-8"))
            bn, dev, sig = req["bn"], req["device"], req["sig"]
            good = (isinstance(bn, str) and BN_RE.fullmatch(bn) and isinstance(dev, str) and DEV_RE.fullmatch(dev)
                    and isinstance(sig, str) and len(sig) <= 200 and SIG_RE.fullmatch(sig))
        except (ValueError, KeyError, TypeError, UnicodeDecodeError):
            good = False
        if not good:
            return self.json(400, {"result": "refused", "reason": "bad request"}, cors=True)
        status, reply = place_signature(self.login(), bn, dev, sig)
        self.json(status, reply, cors=True)


def cmd_serve(argv):
    name, port, idle, path, port_given = None, PORT, IDLE, None, False
    i = 0
    try:
        while i < len(argv):
            if argv[i] == "--name":
                name = argv[i + 1]
            elif argv[i] == "--port":
                port, port_given = int(argv[i + 1]), True
            elif argv[i] == "--socket":
                path = argv[i + 1]
            elif argv[i] == "--idle":
                idle = int(argv[i + 1])
            else:
                raise ValueError(argv[i])
            i += 2
        if port_given and path is not None:
            raise ValueError("--port and --socket")
    except (IndexError, ValueError):
        sys.stderr.write("usage: release_desk.py serve --name <tailnet name> [--port %d | --socket PATH] [--idle %d]\n"
                         % (PORT, IDLE))
        return 2
    if not name or not name.strip():
        sys.stderr.write("release_desk.py serve: --name is empty\n")
        return 2
    state_dir()
    try:
        desk = make_server(name, port, idle, systemd_fd(os.environ, os.getpid()), path=path)
    except (UnsafeSocketPath, OSError) as ex:
        sys.stderr.write("release_desk.py serve: %s\n" % ex)
        return 2

    def watch():
        while not idle_expired(desk, time.monotonic()):
            time.sleep(min(5, max(idle, 1)))
        desk.shutdown()

    threading.Thread(target=watch, daemon=True).start()
    try:
        desk.serve_forever()
    finally:
        desk.server_close()
    return 0


def main(argv):
    if argv[:1] == ["open"]:
        return cmd_open(argv[1:])
    if argv[:1] == ["serve"]:
        return cmd_serve(argv[1:])
    sys.stderr.write(__doc__.split("\n\n")[1] + "\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
