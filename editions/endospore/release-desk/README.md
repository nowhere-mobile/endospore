# The Release Desk (stages 4 and 5)

Design: `docs/release-desk.md` §4, §5.4, §5.5 and §7 stages 4 and 5. Work IDs
`NWP-20261202-24` (stage 4) and `NWP-20261205-04` (stage 5). The private socket is stage 5, part 1
(`NWP-20261205-06`).

The Release Desk is a page on the build host. The operator reaches it over the tailnet through `tailscale serve`.
The Desk does these things:

- It lists the releases that the maintainer opened, with the state of each release.
- It runs `sign-release.sh --preflight-only` and shows one line for each check, green, amber or red.
- It signs the device images through `sign-release.sh` (stage 5, below).
- It runs `verify-release.sh` and shows pass or fail for each device.
- It gives each waiting installer manifest to the Manifest Signer.
- It receives each signature and places it only after its own three checks (§5.4).

## Sign the device images (stage 5)

The release page shows one passphrase field and a Sign button only when both of these are true:

- The last preflight is ready.
- The Desk serves on its private Unix socket: `make_server` marks that server `private`. Over loopback TCP, the
  Desk shows no field and answers Sign with 403. Until the private socket is installed, every Desk is TCP and
  every Sign answers 403.

When the operator presses Sign, the Desk does these things:

1. It starts `setsid --ctty bash sign-release.sh <BN> <commit> <dev>[:<out>]...` as its own child. The child gets a
   pseudo-terminal as its controlling terminal, as tmux gives it today. Echo is off on that terminal. `setsid` is
   from util-linux and execs in place, so the script stays a child of the Desk (`sitting-guard.sh` allows ancestors).
2. It copies the script's output to `results/<BN>/sign.out` (mode 0600).
3. It writes the passphrase to the terminal once, after the script prints its prompt. If the script stops before
   the prompt, the Desk never writes the passphrase.
4. It shows each device as waiting, signing, signed or failed, and the session's result: signed, some failed,
   wrong passphrase, refused before the prompt, timed out, or ended without a result.

A failed device shows "Retry this device" with its own passphrase field. Retry runs the script for that device
alone. A Retry that meets a wrong passphrase, or a refusal before the prompt, leaves the device failed.

The passphrase rules:

- The Desk holds the passphrase only in memory, between the button press and the write to the terminal.
- The Desk never writes it to a file, a log line, a URL or a reply. It is never on the child's argv.
- The child's environment never holds `password` or `PW`. The Desk removes both.
- The Desk refuses an empty passphrase, a passphrase longer than 1024 bytes, and any control character (400). The
  script's own refusal of an empty passphrase stays.

A session holds the Desk's one child slot until the script ends, so preflight, verify and signatures answer 409
while it runs. A session that runs longer than 7200 seconds per device gets TERM on its process group. The script's
TERM trap removes the key dirs. The Desk does the same when it cannot go on, for example when `sign.out` cannot be
written. It keeps the child slot until the script exits, or until 60 seconds after TERM, when it sends KILL and waits.
A session is "signed" only when every device of the release is signed, so a Retry of one device does not hide another
failed device. If the Desk itself dies, the kernel sends HUP to the session, and the script's HUP
trap removes the key dirs.

## Files

| File | What it is |
| --- | --- |
| `release_desk.py` | The Desk: `open` (the maintainer) and `serve` (systemd). Python 3, standard library only. |
| `nowhere-release-desk.socket` | The systemd user socket: `%t/nowhere-release-desk.sock` (`/run/user/<uid>/nowhere-release-desk.sock`), a Unix socket, mode 0600. |
| `nowhere-release-desk.service` | The systemd user service: `serve --idle 900`. It stops after 15 idle minutes. |
| `test_release_desk.py` | The suite. Run it plain and with `--mutate`. |

## Install (the signing user, on the build host)

Do these steps as the signing user. Lingering for this user is on since 2026-11-07, so systemd can start the Desk
when nobody is logged in.

1. Copy the Desk:
   `mkdir -p ~/nowhere-release-desk && cp release_desk.py ~/nowhere-release-desk/`
2. Copy the two units:
   `mkdir -p ~/.config/systemd/user && cp nowhere-release-desk.socket nowhere-release-desk.service ~/.config/systemd/user/`
3. Write the tailnet name into `~/.config/nowhere-release-desk.env`, one line:
   `NOWHERE_DESK_NAME=<the build host's tailnet name>`.
   The name stays out of the repo. Add `NOWHERE_AGENT=<path>` on a second line if the agent is not at
   `/tmp/agent_host`.
4. Build the host agent once (the phone's own signature check):
   `(cd core/agent && CGO_ENABLED=0 GOOS=linux go build -o /tmp/agent_host .)`.
   Without it, the Desk refuses every signature with `agent missing`.
5. Start the socket:
   `systemctl --user daemon-reload && systemctl --user enable --now nowhere-release-desk.socket`.
   Then `systemctl --user status nowhere-release-desk.socket` shows
   `Listen: /run/user/<uid>/nowhere-release-desk.sock (Stream)`.

**Chester's root step:**

1. Run `tailscale serve --help` and make sure that it lists a `unix:` target.
2. Run `tailscale serve --bg --https=443 unix:/run/user/<uid of the signing user>/nowhere-release-desk.sock`.

Tailscale then sends the caller's login in the `Tailscale-User-Login` header and the tailnet name in `Host`. The
Desk refuses a request without both (403). On the Unix socket, the Desk accepts only the tailnet name in `Host`.

If `tailscale serve` has no `unix:` target, use the old TCP socket. In `nowhere-release-desk.socket`, replace the
two lines `ListenStream=%t/nowhere-release-desk.sock` and `SocketMode=0600` with `ListenStream=127.0.0.1:8770`.
Then run `tailscale serve --bg --https=443 http://127.0.0.1:8770`. The Desk is then usable READ-ONLY. Stage 5's Sign
stays refused on a TCP port, because the Desk does not mark a TCP port private.

## Open a release (the maintainer)

The maintainer opens a release in a shell on the build host. Read the verified commit where you did the verifying,
as `docs/release-runbook.md` §2 says. Do not read it from the build host's checkout.

    python3 ~/nowhere-release-desk/release_desk.py open <BN> <verified-commit> lynx tokay:out-tokay

The arguments are the arguments of `sign-release.sh`. The Desk refuses a build number that is not 10 digits, a
device that is not lowercase letters and digits, a device named twice, and a commit that is not 7-40 hex.

## Sign the installer manifests (the operator)

The Manifest Signer works by drag and drop today:

1. On the release page, click "Download for the Signer" for each waiting manifest.
2. Drop those `<dev>-manifest-<BN>.json` files on the Manifest Signer and sign them.
3. Drop the Signer's `<dev>-manifest-<BN>.json.sig` files on the release page.

Do not use `manifests-<BN>.tar` for this. The Desk records the hash of each manifest that it gives out. It refuses
a signature over a manifest that it did not give out.

The Desk places a signature only when all of these checks pass:

- The manifest on disk has the same sha256 as the manifest that the Desk gave out.
- The agent's `ota-release-check` accepts the signature, with the committed `ota-mandatory/<version>` file. This is
  the check that phones use.
- The manifest's `images[0].size` and `images[0].sha256` match the webfactory zip on disk.
- Just before the Desk writes the `.sig`, the manifest on disk is still byte for byte the manifest that the agent
  checked. A new handout during the check does not change this reference.

The Desk refuses a different signature when a `.sig` file is already there. It writes nothing for a refusal.

## State and log

- `NOWHERE_DESK_STATE` (default `~/.local/state/nowhere-release-desk`, mode 0700) holds the open releases, the last
  preflight and verify output, the handout hashes, and each release's signing session: `results/<BN>/sign.json`
  (the device states and the result) and `results/<BN>/sign.out` (the script's output). Neither holds the
  passphrase.
- `log.jsonl` in that directory is append-only. Each line has the time, the Tailscale login, the action, the build
  number, the device and the result. It never holds manifest bytes, signature bytes or a child's output.
- Other settings: `ENDOSPORE_TREE` and `ENDOSPORE_REPO` (the same defaults as `sign-release.sh`), `NOWHERE_AGENT`
  (default `/tmp/agent_host`).

The Desk runs one child at a time: a preflight, a verify, a signature check or a signing session. It answers a
second request with 409 "busy".

## Known limits

- **The socket.** The Desk listens on a Unix socket in `/run/user/<uid>`. That directory is mode 0700 and the
  socket is mode 0600. Only the signing user and root can connect. No other local user can send a false
  `Tailscale-User-Login` header. There is no port that another user can take while the Desk is down, because no
  other user can make a file in `/run/user/<uid>`. This does not close root: root on the build host can connect to
  the socket and can read the memory of every process. The TCP fallback (`127.0.0.1:8770`) keeps the old limit:
  any local user can connect to it or take the port. For this reason the Desk does not mark a TCP port private.
  Stage 5 adds the passphrase, so the Desk refuses Sign (403) and shows no passphrase field unless the server is
  marked private, which only the Unix socket sets.
- **The signing output.** The Desk reads the device lines of `sign-release.sh` (`== <dev>: finalize`,
  `== <dev> RELEASE DONE`, `sign-release: <dev> FAILED`, and the summary) and its prompt. The suite pins each literal
  against the real script.
- **The preflight's output.** The Desk reads the `PREFLIGHT` lines of `sign-release.sh --preflight-only` from
  standard output. If the script writes them elsewhere, every preflight shows red. The stub in the suite pins the
  line format.

## Tests

    python3 editions/endospore/release-desk/test_release_desk.py
    python3 editions/endospore/release-desk/test_release_desk.py --mutate

The suite runs the real handler on 127.0.0.1 and on a Unix socket, against stub scripts and a stub agent. `--mutate` breaks one guard at a
time and requires the named test to fail.
