# The Release Desk, read-only (stage 4)

Design: `docs/release-desk.md` §4, §5.4, §5.5 and §7 stage 4. Work ID
`NWP-20261202-24`.

The Release Desk is a page on the build host. The operator reaches it over the tailnet through `tailscale serve`.
In stage 4 the Desk does these things:

- It lists the releases that the maintainer opened, with the state of each release.
- It runs `sign-release.sh --preflight-only` and shows one line for each check, green, amber or red.
- It runs `verify-release.sh` and shows pass or fail for each device.
- It gives each waiting installer manifest to the Manifest Signer.
- It receives each signature and places it only after its own three checks (§5.4).

**Stage 5 is not built.** The page has no passphrase field, no Sign button and no "Retry this device" button. The
Desk never runs `sign-release.sh` without `--preflight-only`. Sign the device images in a terminal, as
`docs/release-runbook.md` says.

## Files

| File | What it is |
| --- | --- |
| `release_desk.py` | The Desk: `open` (the maintainer) and `serve` (systemd). Python 3, standard library only. |
| `nowhere-release-desk.socket` | The systemd user socket: `127.0.0.1:8770`, loopback only. |
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
   `systemctl --user daemon-reload && systemctl --user enable --now nowhere-release-desk.socket`

**Chester's root step:** `tailscale serve --bg --https=443 http://127.0.0.1:8770`. Tailscale then sends the
caller's login in the `Tailscale-User-Login` header and the tailnet name in `Host`. The Desk refuses a request
without both (403).

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
  preflight and verify output, and the handout hashes.
- `log.jsonl` in that directory is append-only. Each line has the time, the Tailscale login, the action, the build
  number, the device and the result. It never holds manifest bytes, signature bytes or a child's output.
- Other settings: `ENDOSPORE_TREE` and `ENDOSPORE_REPO` (the same defaults as `sign-release.sh`), `NOWHERE_AGENT`
  (default `/tmp/agent_host`).

The Desk runs one child at a time: a preflight, a verify or a signature check. It answers a second request with
409 "busy".

## Known limits

- **Loopback.** Any local user of the build host can connect to `127.0.0.1:8770` and send a false
  `Tailscale-User-Login` header. In stage 4 that user can only run a preflight or a verify, or send a signature that
  must still pass the three checks. Stage 5 adds the passphrase and must close this, for example with a Unix socket
  for `tailscale serve`.
- **The preflight's output.** The Desk reads the `PREFLIGHT` lines of `sign-release.sh --preflight-only` from
  standard output. If the script writes them elsewhere, every preflight shows red. The stub in the suite pins the
  line format.

## Tests

    python3 editions/endospore/release-desk/test_release_desk.py
    python3 editions/endospore/release-desk/test_release_desk.py --mutate

The suite runs the real handler on 127.0.0.1 against stub scripts and a stub agent. `--mutate` breaks one guard at a
time and requires the named test to fail.
