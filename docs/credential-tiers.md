# Nowhere — Credential tiers: passphrase floor + FIDO2 keyslot

Status: **design** · 2026-07-01 · target: Phase 1 hardening (floor) + Phase 2/3 differentiator (FIDO2)

## Problem

The passphrase is the **sole roaming secret**, and it carries more weight here than in a normal app:

- There is **no server-side login** — the store is world-readable by design (reads are free; the
  amnesiac-wallet chicken-and-egg), so there is no online throttle, lockout, or 2FA to lean on. The data
  is self-protecting ciphertext; the passphrase is the whole wall.
- `ref = sha256("nowhere-ref:" + name + "\0" + passphrase)` is a **fast existence oracle**: anyone holding
  a dump of the store's ref keys can test guesses for a target name at raw SHA-256 speed (billions/s,
  offline). The Argon2id in `deriveKey` protects the *data*, *not* the ref — a dictionary passphrase falls
  to the ref oracle long before anyone touches the ciphertext.
- A **PIN/pattern cannot roam**: anything derived from 4–6 digits is offline-crackable against a
  world-readable store, no matter the KDF. (A gateway-throttled "stretch oracle" could fix the entropy gap
  but costs availability — no offline login — plus a trust surface and a per-profile linkability channel at
  the gateway. Rejected for now; kept in the back pocket.)

Constraints that shape every fix:

- **Blind login is inviolable**: wrong creds → uniform blank. No check may run at *login*, and nothing in
  the store may reveal that a profile exists.
- **The device is amnesiac**: any credential must work on a *fresh* device with nothing durable on it.
- **Throwaways stay zero-friction** (#4): a local-only session protects nothing store-resident, so it gets
  no ceremony.

## The ladder

| Tier | Credential | For | Mechanism |
|------|-----------|-----|-----------|
| 1 | passphrase | everyone (baseline) | strength **floor** at create/promote/rotate + KDF-derived refs |
| 2a | passphrase **+** FIDO2 key | 2FA | DK unwrap needs both (KEK mixes pass and hmac-secret) |
| 2b | FIDO2 key + its PIN | daily-driver high security | key-primary: hmac-secret is the KEK; the key's own PIN throttles it in hardware *(⚠ superseded in part 2026-10-21, dn-1025 #5: a key's PIN alone never signs in at the gate, so key-primary needs the key's fingerprint, or fingerprint and PIN; the entry *"twenty-two recommendations accepted — the login daemon forgets a session's keys ..."* in `docs/product-decisions.md`, `NWP-20261021-27`)* |

The 12-word recovery mnemonic ([recovery.md](recovery.md)) remains the universal floor under every tier.
Endospore's SE slot ([se-binding.md](se-binding.md)) is orthogonal: it binds an identity to *one device's*
secure element; FIDO2 binds to a *portable* authenticator — which is what actually matches roaming.

## Tier 1a — passphrase strength floor

**Where enforced — only where data becomes durable:**

- `create-vault` (new stored profile), **PROMOTE** (throwaway → store), `rotate`, `recover` (setting the
  new passphrase).
- **Never at login** (blind login), **never on throwaways** (nothing crackable exists; friction kills the
  feature).

**What (NIST 800-63B-aligned — length/entropy, not composition rules):**

- Floor: ≥ 12 characters ~~or a ≥ 4-word passphrase~~ *(superseded 2026-10-20, dn-1025 #4: 12 characters overall whatever the word count, and 3 distinct words in a phrase of 4 or more; built by NWP-20261102-02)*. ~~zxcvbn-style meter in the create/promote UI.~~ *(Superseded 2026-10-22 (`docs/product-decisions.md`, *"seventy-two recommendations accepted, and three more answers ..."*), #29: no strength estimator runs on the phone; the rule-based floor is validated offline against a zxcvbn corpus.)*
- Blocklist: the profile name itself, top-N common passwords, keyboard walks, all-one-class trivia, a phrase that is one word or unit repeated (dn-1023 #11, NWP-20261116-07).
- A **"generate passphrase"** button (diceware-style, from the bip39 wordlist already shipped for the
  mnemonic) as the low-friction path: strong by default, and the mnemonic is the forget-me backstop.
- Enforced in the **agent** (`create-vault`/`rotate`/`recover` refuse below-floor, overridable for tests
  via env), mirrored in the **chooser UI** (meter + inline error) so the refusal is never the first
  feedback.

**The PROMOTE ceremony** (the one subtle case): a throwaway's passphrase was typed casually — possibly a
typo. Promote is the commitment moment, so it must:

1. Require the passphrase **typed** (not silently reuse the session's copy) — proves the user can
   reproduce the credential their data is about to be sealed under. Choosing a *different* one here is
   free: nothing exists in the store under the old `(name, pass)` (that's what made it a throwaway).
2. Apply the floor (step 1's input).
3. **Refuse** if the chosen `(name, pass)` already resolves to an existing head — otherwise promote would
   seal a local session over someone's real profile. Same accepted ceremony-time leak as `create-vault`'s
   "profile already exists"; the #72 restore-receipt guard backstops this at the seal layer too.
4. Show the recovery mnemonic once (promote creates the vault, so this screen exists anyway).

### Running the floor against zxcvbn's list (h49 #5, NWP-20261119-24)

The decision is h49 #5 (`docs/product-decisions.md`, *"thirteen answers to harvest 49 ..."*, 2026-10-31). The list is
zxcvbn's own password list. The repo does not hold it. The run happens on the build server, never on the phone: no
strength estimator runs on the phone (2026-10-22, #29).

**The lists.** Source: `https://github.com/dropbox/zxcvbn`, tag `v4.4.2` (its last release). Each line of both files
is `<token> <count>`.

| file | use | lines | SHA-256 |
|---|---|---|---|
| `data/passwords.txt` | the password list | 47,023 | `6313cc5ef683a0461416318ee3b16f3d771a3cd10ea2aae54571d27ff95d951f` |
| `data/english_wikipedia.txt` | the word list | 100,000 | `d328355469e93df15b091fd20a8fd171e056e5a870b65bcf08298a4eb93a6160` |

`NWP-20261119-24` fetched both files from the tag and computed these hashes. The procedure below stops on a file with
a different hash, before the verb or the scorer reads it.

**The tools.**

- `nowhere_agent floor-corpus <list> [--words <wordlist> [--top <n>]]` (`core/agent/floor_corpus.go`). It calls the
  shipped `passphraseStrong` with an empty profile name, and it holds no rule of its own. It reads the list line by
  line. It prints each pass as one `{"p": ...}` line on stdout and prints nothing for a refusal. It prints the
  counts on stderr: `list:`, `words:` and, last, the total `<n> tested, <p> passed`.
- With `--words`, it takes the first field of each line and keeps the top N distinct words, lower-cased (N = 200 by
  default). From these words it builds four families of weak phrases. (1) Every 4-word phrase of the first K = 10
  words (10,000 phrases). (2) Each word four times. (3) The four 3-distinct-of-4 patterns (`a a b c`, `a b a c`,
  `a b c a`, `a b c c`) of each run of three words. (4) The capitalised form of each phrase of (1) to (3).
- The tool removes duplicates. The grid already holds families (2) and (3) for its own K words. So the count is
  2·(K^4 + max(0, N − K) + 4·max(0, (N − 2) − max(0, K − 2))), with K = min(10, N). At the defaults this is 21,900
  phrases. A word whose first character has no upper case gives no new capitalised phrase. Then the count is lower.
- `ci/floor-corpus-score.py` reads the passes. For each pass it adds zxcvbn's `score` and `guesses_log10`. Then it
  prints a count for each score from 0 to 4 and the total. It needs the `zxcvbn` Python module. Without the module it
  exits 2. It writes only to stdout.
- CI runs both tools on made-up lists only (`core/agent/test-floor-corpus.sh`, `ci/test_floor_corpus_score.py`).

**Procedure (build server).** Run it from the top of a checkout of `main`. The script runs under
`bash -euo pipefail`, so the first command that fails stops the run. A failed fetch, build, hash check, install, verb
or scorer stops it. A hash mismatch stops it before `awk`, so changed bytes never reach the verb or the scorer. The
`EXIT` trap removes `$W` on success and on failure. The last `grep` finds no line when no pass scores 0 or 1. Its exit
status 1 is accepted as that empty result; any other status stops the run.

```
bash -euo pipefail <<'RUN'
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
git rev-parse HEAD
(cd core/agent && GOTOOLCHAIN=auto CGO_ENABLED=0 go build -o "$W/nowhere_agent" .)   # host build: no GOOS/GOARCH
ZX=https://raw.githubusercontent.com/dropbox/zxcvbn/v4.4.2/data
curl -fsSL "$ZX/passwords.txt" -o "$W/passwords.txt"
curl -fsSL "$ZX/english_wikipedia.txt" -o "$W/words.txt"
printf '%s  %s\n' 6313cc5ef683a0461416318ee3b16f3d771a3cd10ea2aae54571d27ff95d951f "$W/passwords.txt" \
  d328355469e93df15b091fd20a8fd171e056e5a870b65bcf08298a4eb93a6160 "$W/words.txt" | sha256sum -c -
awk '{print $1}' "$W/passwords.txt" > "$W/list.txt"
python3 -m venv "$W/venv"
"$W/venv/bin/pip" install -q zxcvbn
"$W/venv/bin/pip" show zxcvbn | grep '^Version'
"$W/nowhere_agent" floor-corpus "$W/list.txt" --words "$W/words.txt" > "$W/passes.jsonl"
"$W/venv/bin/python" ci/floor-corpus-score.py "$W/passes.jsonl" > "$W/scored.jsonl"
grep -E '^(score [0-4]|total):' "$W/scored.jsonl"
grep -E '"score": [01],' "$W/scored.jsonl" || [ "$?" -eq 1 ]
RUN
```

All files stay in `$W`, outside the repo, and the trap removes them on exit. Never give the tool a real passphrase.

**Recording the result.** The run is the record. The operator writes one dated paragraph here, in the slice that
closes the backlog row: the commit, the `sha256sum -c` lines, the zxcvbn module version, the verb's three stderr
count lines, the scorer's `score N:` and `total:` lines, and the passes with score 0 or 1. Each pass with score 0 or
1 is a finding. A rule change that it suggests is its own question (2026-10-22, #29). No run has happened yet, so
this section holds no result.

## Tier 1b — kill the ref existence oracle (KDF-derived refs)

The higher-impact half. Derive the ref from the *same* Argon2 output the login already computes:

```
K    = Argon2id(passphrase, salt(name))          // deriveKey — unchanged, already paid at login
ref  = HMAC-SHA256(K, "nowhere-ref-v2")           // replaces sha256(name+pass)
```

- **Zero added login latency** (the Argon2 is already computed for the KEK); a store-dump attacker now
  pays the full 64 MB Argon2 **per guess** instead of one SHA-256. This multiplies the effective strength
  of every passphrase by the KDF cost — worth more than any complexity rule.
- Blind login unchanged: the v2 ref is exactly as unguessable, just costlier to grind.
- **Migration**: on login, try `ref_v2`, fall back to the legacy sha256 ref; on first successful v2-era
  seal, publish the vault at `ref_v2` and tombstone the legacy ref (same pattern as `migrate-ref` /
  `migrateVault`). The recovery ref gets the same treatment (`HMAC(K_recovery, ...)`).

## Tier 2 — FIDO2 as a vault keyslot (CTAP2 `hmac-secret`)

FIDO2 here is **not** authentication (there is nothing to authenticate against) — it is a *key-material*
source. CTAP2's `hmac-secret` extension holds a per-credential HMAC key inside the authenticator; an
assertion with a salt returns `HMAC(key, salt)` — deterministic, high-entropy, never-exported. (Same
primitive systemd-cryptenroll/LUKS use for FIDO2 disk unlock.) That output slots straight into the
existing vault keyslot array as a third `kind`:

```
{ "kind": "fido2", "credId": "<b64>", "salt": "<b64>", "wrapped": "<b64: nonce|ct|tag>" }
```

`credId` + `salt` are public-safe metadata, exactly like a LUKS header.

- **2a (2FA)**: `KEK = HKDF(K_pass || hmac_output)` — neither the passphrase nor the key alone unwraps DK.
- **2b (key-primary)**: `KEK = HKDF(hmac_output)`; the key's **own PIN** (8 tries → hardware lockout)
  gates the assertion. This is the PIN answer: low-entropy secret, throttled in tamper-resistant hardware
  the *user carries*, fully offline, zero extra trust — the roaming analog of Endospore's Weaver throttle.
  With a **discoverable (resident) credential**, the key also carries the profile name (userHandle) and a
  ref-derivation secret, so login = insert/NFC-tap + PIN. No typing. *(⚠ Superseded in part 2026-10-21, dn-1025 #5 as Chester corrected it: at a gate sign-in a key's PIN alone is never accepted, so this is not the gate's PIN answer; key-primary login is for a key verified by its fingerprint, or by fingerprint and PIN, a key without a fingerprint sensor is a second factor beside the passphrase, and Nowhere's warm and cold lock PIN is unchanged; the entry *"twenty-two recommendations accepted — the login daemon forgets a session's keys ..."* in `docs/product-decisions.md`, `NWP-20261021-27`.)*

**Rules:**

- **External security keys only — never platform passkeys.** A phone-resident passkey dies with the
  amnesiac wipe. USB-C and NFC (FP3 has NFC) roaming authenticators only; keys without `hmac-secret`
  (U2F-only) are unsupported.
- **Enrollment requires the escape hatches**: strongly push ≥ 2 keys (the slots array already supports
  multiples), and re-show the recovery mnemonic at enrollment. Lose-the-key must never mean
  lose-the-data.
- **Blind login preserved**: no key / wrong key / wrong key-PIN → blank, indistinguishable. The v2 ref for
  a key-primary profile derives from the hmac output, so the store still reveals nothing.
- **UV policy is fixed per slot and MUST match enroll ↔ login.** `hmac-secret` derives a *different* secret
  for a **user-verified (UV)** assertion than for a non-UV one (CTAP2 `CredRandomWithUV` vs `WithoutUV`). If a
  slot is enrolled with UV, every login must use UV, or the key returns a different output
  and DK won't unwrap (silent "wrong key" → blank). ⚠ **The axis is UV vs NO-UV, not PIN vs touch**
  (corrected 2026-09-15): the key's PIN and the key's built-in biometric are BOTH user verification and both
  yield the same `CredRandomWithUV`, so they are interchangeable — a bio key satisfies a slot enrolled with
  the PIN, and vice versa. What must match is only *whether UV happened at all*. So the `fido2` slot records
  its UV policy; **key-primary (2b) is always UV-required**; a 2FA (2a) slot fixes its choice once at enrollment. Note a no-PIN key
  is a valid *second* factor (passphrase is the "know") but a dangerous *sole* factor — theft = full access.
- ⚠ **WHAT SHIPS TODAY IS NO-UV, AND IT BLOCKS BIO KEYS ENTIRELY.** `getAssertionHMAC` sends no `uv` option
  and no `pinUvAuthParam`, and `makeCredential` relies on `makeCredUvNotRqd` (`ctap_cmd.go:78`) — so every
  existing slot is a `CredRandomWithoutUV` slot. A YubiKey Bio enforces `alwaysUV` in hardware and therefore
  **cannot enrol or assert against this client at all**. Adding the UV path breaks every existing slot;
  `NWP-20260915-01` carries that work and records Chester's authorisation for the clean break.

**The real cost is the CTAP2 client.** De-Googled build → no Play-services FIDO API. The gate (user 0)
must speak raw CTAP2 (CBOR over USB-HID and/or NFC). Bounded, in character with the hand-rolled blind-RSA
work, but it is the bulk of the effort — the agent/vault side is a small new slot kind. Transport order:
USB-C first (simplest HID path), NFC second.

## Not this doc: the in-session lock screen (L5)

The session keyguard PIN is a **local-only** credential: Android throttles attempts, and the 15-min
cold-lock + 12-h wipe backstop it. It never derives store keys and never roams, so a short PIN is fine
there. L5 proceeds independently.

## Phasing

- **P1** — floor + generator + blocklist: agent checks in `create-vault`/`rotate`/`recover`; chooser
  meter/generator UI; the PROMOTE ceremony (typed passphrase, floor, exists-check, mnemonic).
- **P2** — KDF-derived refs (`ref_v2`) + fallback lookup + migrate-on-seal, incl. recovery ref.
- **P3** — `fido2` vault slot in the agent (enroll/open), 2FA mode first (pass + key).
- **P4** — CTAP2 client in the gate (USB-C HID, then NFC); key-primary login UX (discoverable creds).

## Open questions

- ~~CTAP2 client: hand-roll (CBOR + HID framing) vs. vendor a minimal library — audit cost vs. build cost.~~ *(superseded 2026-10-24 by NWP-20261024-14: hand-rolled, and shipped -- `core/agent/ctap_cbor.go`, `ctap_hid.go`, `ctap_nfc.go`, `ctap_cmd.go`)*
- ~~Key-primary ref bootstrap: fixed well-known salt for the ref-slot assertion vs. salt carried in the~~
  ~~discoverable credential's blob (credBlob extension availability varies by key).~~ *(superseded 2026-10-24 by NWP-20261024-14: docs/fido2-key-only-login.md §2 (NWP-20260917-28) resolves it -- a fixed, domain-separated discovery salt; credBlob is not used)*
- Floor numbers: 12 chars / 4 words is the opening bid — validate against zxcvbn scoring on-device. *(Decided in part 2026-10-20, dn-1025 #4, (`docs/product-decisions.md` 2026-10-20, *"nineteen recommendations accepted (second set) — the fleet ER's runtime ceiling is `ceiling_runtime_h` ..."*): a phrase that passes on word count also needs 12 characters overall, so `1 2 3 4` no longer passes; unbuilt. ~~The zxcvbn validation is not decided.~~ Decided 2026-10-22 (`docs/product-decisions.md`, *"seventy-two recommendations accepted, and three more answers ..."*), #29: offline against a zxcvbn corpus, never on the phone.)* *(And 2026-10-24, dn-1023 #11, `docs/product-decisions.md`, the entry *"fourteen recommendations accepted — a key-only profile may keep a passphrase ..."*: a phrase made of one repeated word or unit, such as `alice alice alice` or `abcdabcdabcd`, is refused at any length; unbuilt.)* *(2026-10-31, h49 #5: the run uses zxcvbn's own list on the build server. NWP-20261119-24 built the runner; see "Running the floor against zxcvbn's list" above. The run has not happened yet.)*
- Whether PROMOTE should *offer* keeping the typed-at-gate passphrase when it already meets the floor
  (one fewer step) or always require the full ceremony (uniformity). Leaning: offer it, pre-validated.
