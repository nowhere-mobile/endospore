# Nowhere — Gate telephony & owner mode (per-profile SIM binding + sealed inbox)

Status: **design** · 2026-07-10 · target: Phase 2/3 · tasks: **#135** (gate telephony), **#136** (owner mode)

## Problem

Telephony is fundamentally **user-0-owned and non-amnesiac**, which collides with the amnesiac
roaming model:

- The radio belongs to the system user (user-0). Every inbound call/SMS is delivered by the
  telephony framework running as user-0, regardless of which roamed user (if any) is foreground.
- user-0 storage is **never wiped** by the amnesiac machinery — every wipe path is guarded to
  *secondary* users (`BootReceiver.wipeLeftoverRoamedUsers` iterates only `getSecondaryUsers`;
  `nowhere_roamd.sh` `cleanstorage` hard-refuses `uid < 10`). A call/SMS landing at the gate is
  written to user-0's providers and survives logoff, cold-lock, boot-wipe, **and** power-off.
- user-0 CE is **unlocked cleartext** the whole time the device sits at the gate — unlike roamed
  sessions, which are per-session FBE-encrypted and crypto-shredded on logoff.

Naive handling forces a bad trade: either **discard** gate-arrived telephony (you're notified about a
message you can then never read) or **retain** it (a growing pile of plaintext-at-rest on the one
part of the device that only a factory reset clears). This design does neither.

**Goal:** telephony becomes a *per-person feature* — each SIM is bound to a profile, inbound is
**delivered to that profile's owner**, and user-0 holds **nothing readable at rest**.

Related: [roaming-boundaries.md](roaming-boundaries.md), [threat-model.md](threat-model.md),
[identity-model.md](identity-model.md), [lock-model.md](lock-model.md),
[se-binding.md](se-binding.md), [credential-tiers.md](credential-tiers.md).

## One principle

> **user-0 owns the radio, so our user-0 handlers always catch every inbound event.** The *data* path
> is uniform — **seal-to-owner → ingest-when-unlocked** (instant if the owner is live, deferred to a
> sealed inbox otherwise). Only the *answer / notify surface* varies with device state and the owner's
> per-SIM visibility setting.

Everything below is a consequence of that one sentence.

## SIM ↔ profile binding

A **binding record** ties a physical SIM to its profile identities:

```
binding: sub-id (ICCID / subscription) → { owners: [{profileRef, telephonyPubKey}...], label, visibility }
```

⚠ Corrected 2026-09-01 (`NWP-20260901-13`): this line previously showed a single `profileRef`, but
the implementation has been **many-to-many since the binding model's first commit** (`bindings.go:31`,
`Owners` is a slice; inbound is a fan-out sealing one box per owner key, `main.go:7033-7041`,
unit-tested). The doc sentence was the artefact, not the code. Many-owner is now RATIFIED
(`product-decisions.md` 2026-09-01), and per-SIM `label`/`visibility` — shared by all owners, because
the dial governs what a stranger at the gate sees, a property of the line — is a recorded choice.

- Set in **owner mode** (#136) — the only place with device-admin authority over the physical SIM. *(Superseded in part by `docs/product-decisions.md` 2026-09-01 (d): on a rental phone a SIM is also bound by an operator-issued code plus approval on the operator portal.)*
- **Persistent** across reboot — this is the *one* deliberate exception to "nothing kept after a
  reboot." *(Superseded in part 2026-09-27, `docs/product-decisions.md`: the device-owner telephony keypair Chester chose there (agent-held, its private half wrapped under a key derived from the owner passphrase) will also persist on user 0. That it persists across a reboot is our engineering reading of his choice, recorded there as not part of what he chose. Key material, not a record of any call or message. BUILT 2026-09-28 (`NWP-20260928-01`): `/data/nowhere/owner-key`, see “Device-owner key” below.)* It is *config, not content*: an opaque `profileRef`, a **public** key, a display label, and
  an enum. No message/call content and nothing secret. Stored on persistent user-0
  (`/data/nowhere/bindings.conf`, LF-only per the conf convention).
- An **unbound** SIM (fresh device, or a SIM nobody bound) **belongs to the device owner** — decided; see
  §"PARTLY DECIDED ALREADY" below and `product-decisions.md` 2026-09-01 / 2026-09-24. Its inbound is sealed to
  a device-owner key and read behind the owner passphrase; its outbound is the owner's, from owner mode at the
  gate; no profile may remove the record — only the owner or a reboot.
  ⚠ SUPERSEDED TEXT, kept so the history reads: this bullet used to say *"inbound falls back to
  notify-content-free-and-wipe (nothing to deliver, so nothing is retained)"*. ✅ BUILT `NWP-20261001-01`/`-02`
  (device-unproven): the v2 wire now seals an unbound arrival to the device-owner inbox (`sealArrival` →
  `sealUnboundToOwner`), read behind the owner passphrase; only the legacy v1 `handleSealTel` still drops. The
  content-free `#466` notice it posts is decided and stays.
- **Unassign** (`NWP-20260924-07`) — owner mode's “Unbind all” sends `DELETE-BINDING`, which unbinds the whole SIM
  and deletes every pending record that came in on it, sealed and mailbox, for every owner, at that moment
  (Chester, 2026-09-24, `product-decisions.md` Open section). It cannot reach rows the chooser has already
  claimed; those still land — `backlog.md` “A sealed telephony record is dropped at the hand-off, before the
  chooser inserts it”. Records go first and the binding second, so a failure leaves the SIM bound and a
  retry finishes the job. Replies: `OK`; `NOTFOUND` (no SIM with that ICCID is bound); `ERR` (an empty ICCID, a
  per-owner unbind, which no caller sends, a record that would not delete, or a binding that would not save after
  its records were deleted); `BUSY` (a login or seal holds the session lock); since `NWP-20260930-04` also `ERR damaged` (bindings.conf cannot be read at all; nothing is deleted). ICCIDs compare with the chooser's
  rule: trimmed, lower-case, one trailing filler `f` ignored. An arrival that carries an ICCID is matched by it or
  is unbound *(since `NWP-20260930-04`, on the v2 wire, also UNRESOLVED while a line of bindings.conf does not read back and no good line holds the SIM, and REMOVED when its SIM was unassigned after it arrived)*; only one without an ICCID falls back to a sub id of 0 or more. The `OK` reply names the line's
  labels (`OK L<label_b64> ...`, a bare `L` for a blank label), and owner mode clears the gate notices under them
  (`NWP-20260924-08`, Chester 2026-09-24): by label, so another line's notice with the same label clears too, and a
  notice posted under a label the line no longer has is missed. Owner mode's **Clear notices** on a line
  (`NWP-20261105-05`, Q103) clears that line's gate notices without an unbind: by the labels GET-BINDINGS lists for its
  ICCID, with unbind's costs (another line with the same label loses its notice too), but it deletes nothing, so the
  records still land at the owning profile's sign-in; loss notices stay until reboot.

Telephony is explicitly outside the anonymity model already ([threat-model.md](threat-model.md): "your
number / SIM / carrier are outside the model"), so a persistent SIM→profile map is consistent with the
existing posture — it does not weaken any *content* guarantee.

## Per-profile telephony keypair

Sealing at the gate requires the owner's **public** key while the owner is *not* logged in, so each
profile gets an **X25519 keypair**:

- **pubkey** → stored in the binding registry (readable at the gate, non-secret).
- **privkey** → wrapped in the profile's vault, opened at login by the credential ladder → DK
  (same mechanism as everything else the vault protects; see [credential-tiers.md](credential-tiers.md)).
- **Bootstrapping:** generated at profile creation; the pubkey is captured into the binding when the
  owner binds the SIM (which may require the profile to have logged in once, since owner mode alone
  cannot produce the profile's key — see build plan A3/B1).

**Sealing** is stdlib-only (matching the billing crypto posture): ephemeral X25519 → ECDH with the
recipient pubkey → HKDF-SHA256 → AES-256-GCM (`crypto/ecdh`, `crypto/hmac`, `crypto/cipher`). A sealed
item is an anonymous sealed-box addressed to exactly one profile. *(Superseded in part: an unbound SIM's record is sealed to the device-owner key instead — 2026-07-24, key design 2026-09-27, `docs/product-decisions.md`.)*

## Sealed inbox (the delivery mechanism)

When the owner is **not** live, an inbound item (a call-log entry, or an SMS's fields) is:

1. shuttled from the Java gate app to `nowhere_agent` over the existing peer-pinned LocalSocket
   (in-memory, never touching disk as cleartext);
2. **sealed** to the owning profile's pubkey (Go, stdlib);
3. written as ciphertext into a per-profile buffer in the **tmpfs**
   `/data/nowhere/state/tel/inbox/<profileRef>/` (`$STATE/tel/`, which the session-state wipes spare since
   `NWP-20260924-04`), named `<simTag>.<random>.seal` — the tag, a hash of the binding's ICCID, is the SIM the item
   came in on, so an unassign can find it without opening it (`NWP-20260924-07`) — RAM-backed, so it is **automatically gone on
   power-off/reboot** (the tmpfs is mounted fresh at `sys.boot_completed`); and
4. the transient cleartext provider row is prevented (SMS) or deleted-and-scrubbed (calls) — see
   *Strict zero-window* below. *(Superseded in part 2026-09-28, `docs/product-decisions.md`: SMS's `raw` rows are not prevented — the framework stores every segment there before `SMS_DELIVER` reaches us; see the marks under *Strict zero-window*.)*

**Ingest at login:** the profile opens its vault → privkey → decrypts its `telinbox` buffer →
privileged `content insert --user N` into its *own* call-log/SMS providers (via the roamd worker;
DIA-56 stdio→/dev/null gotcha) → clears the buffer. From then it roams and seals with the session
like any other data. *(⚠ The build superseded this mechanism: delivery v2 stages the decrypted rows for the
roamed user's own chooser (`TelIngest`, `GET-TELINGEST`) instead of a worker `content insert` — see the roam-in
comment in `core/agent/main.go`. Since `NWP-20260924-04` the sealed copy is dropped only after the hand-off
is written (`stageTelInbox`) — which is still before the chooser inserts the rows, so not yet at the landing:
`backlog.md` "A sealed telephony record is dropped at the hand-off, before the chooser inserts it" *(re-pointed by `NWP-20260927-08`; it cited the `CREATE` + `LOGOFF` wipe row)*. *(⚠ SUPERSEDED by `NWP-20261006-05`: the copy is no longer dropped at the hand-off. It is kept,
pending for the session, until the chooser acknowledges inserting the row (`ACK-TELROWS`); a copy never acknowledged
is staged again at the profile's next sign-in.)* The staged rows wait in one
plaintext mailbox file per SIM, `tel/telingest.<uid>.<simTag>`, and GET-TELINGEST serves every file of the uid as
one reply; a call row also carries the tag in its body slot, which the chooser echoes when it re-stages the row.)*

**Lifetime:** cleared on **login OR reboot, whichever is first**. *(⚠ SUPERSEDED 2026-09-24 for the login
half: a bound record lives until it has landed in its profile's store, and no other profile's login may clear
it — §"PARTLY DECIDED ALREADY", "WHO MAY WIPE IT".)* tmpfs makes reboot/power-off
automatic; ingest handles login. Delivery is **best-effort** — an undelivered item is *gone* at the
next reboot. This is amnesia-first by design and upholds the "nothing kept after a reboot" claim
(content is RAM-only ciphertext; only the non-secret binding persists).

## Visibility dial (per-SIM, owner-set)

The owner sets, per bound SIM, how visible their line is to *whoever is at the gate* (it never
changes whether the owner eventually receives it — the record always seals to them *(narrowed 2026-09-30: not past a hard RAM budget line, where nothing is kept and a loss notice shows; nor for an emergency service's callback that the emergency exemption lets ring in a stranger's session, answer 4 — `docs/product-decisions.md`, the entry of that date. ~~Any other call the exemption lets ring there is still owed its record, and its loss is a defect: the state matrix's different-user row, and `docs/backlog.md` §B *“An ordinary call on a SIM, let through in a stranger's session by the emergency exemption's window, leaves the line's owner no record”*~~ *(superseded 2026-10-20, Q046: no call the exemption lets ring there gets a record, an intended loss; the entry *"twenty-eight more recommendations accepted — a delete releases the profile's rows ..."*, `NWP-20261020-48`)*)*):

| Level | Incoming **call** | Message **notice** |
|---|---|---|
| **Open** (default) | Rings; anyone at the gate can answer | "New message · `<label>`" |
| **Notify-only** | Not answerable at the gate → missed, sealed to owner | "New message · `<label>`" |
| **Private** | Missed, sealed silently | Nothing shown at the gate *(narrowed 2026-09-30: when the phone cannot tell that the line is Private — its SIM not identified, or its bindings unreadable — an arrival it cannot keep shows a content-free “may not have been saved” notice; `docs/product-decisions.md`, the entry of that date, answer 2)* |

`<label>` is owner-set (defaults to the carrier name / "SIM 1 / SIM 2") *(superseded: blank by default since Chester's call of 2026-07-18, recorded at `ChooserActivity.java:5644-5647`; `docs/product-decisions.md` 2026-09-24 describes it as “none by default”)*. A *personal* label shown to a
stranger at the gate is a small identity leak, so the default is neutral and a custom label is opt-in;
an owner who wants their line invisible picks **Private**.

## State matrix

Applying the one principle across every device state:

| State | Incoming **call** | Incoming **message** | Record goes to |
|---|---|---|---|
| **Owner logged in** (live) | **Normal phone** — rings in their session, answered live | Lands in their Messaging immediately | **Directly into their profile** (roams/seals with them); no sealing |
| **At the gate** (no profile) | Per dial (Open→anyone answers; else missed) | Content-free notice per dial | Sealed → delivered at next login; wiped at reboot |
| **Cold-locked** | **Same as the gate** — owner's keys evicted, can't deliver live; answerable at the resume screen per dial | Content-free notice per dial | Sealed to the owner's **persistent** pubkey (survives a cold-session hard-wipe) → delivered on unlock/next fresh login |
| **Different user logged in** | Owner treated as **absent** — the active session is **not** interrupted; call missed | Not shown to the foreground user | Sealed → delivered when the *owner* next logs in *(narrowed 2026-09-30: a call the emergency exemption lets ring in this session is not sealed — for an emergency service's callback by decision, `docs/product-decisions.md`, the entry of that date, answer 4; ~~for any other call a defect, `docs/backlog.md` §B, *“An ordinary call on a SIM, let through in a stranger's session by the emergency exemption's window, leaves the line's owner no record”*~~ *(superseded 2026-10-20, Q046: for any other call the exemption lets ring here, also by decision; the entry *"twenty-eight more recommendations accepted — a delete releases the profile's rows ..."*, `NWP-20261020-48`)*)* |
| **SIM bound to NO profile** — **the device owner's line** (decided 2026-07-24 / 2026-09-01) | **Rings at the gate**; the owner may place a call / send a text on it from **owner mode** at the gate (behind the owner passphrase) — ✅ owner-mode transmit BUILT `NWP-20261001-04` (device-unproven), fire-and-forget (no sent record), the placed call getting Hang up / Mute / Speaker via the shared call UI. No roamed *session* may dial it (outbound stays blocked for every profile). In a stranger's roamed session the call is rejected there (existing behaviour, *decided 2026-10-07 by Chester: “keep it rejected”*; no ring, chime or buzz reaches that session for an arrival on this line, `docs/product-decisions.md`, the entry of that date) and its record, like the gate's, is the owner's *(narrowed 2026-09-30: unless the emergency exemption lets it ring there, when nothing is sealed — the different-user row's note)* | Content-free notice reading *"an unassigned SIM"* (built, `#466`); tappable to the owner *verify* and never past it (decided 2026-09-01; ⚠ tap NOT BUILT — `backlog.md` "Unassigned-SIM notice → owner-verify route") | **Sealed to a device-owner key** → read from the owner inbox behind the owner passphrase (how it is built decided 2026-09-27: an agent-held key wrapped under the owner passphrase, an inbox row in the owner menu for calls, SMS and MMS that keeps items until cleared — `docs/product-decisions.md`); RAM-only, gone at reboot; **no profile may remove it** — only the owner or a reboot (Chester 2026-09-24). ✅ BUILT `NWP-20261001-01`/`-02` (device-unproven): the v2 wire seals it (`sealArrival` → `sealUnboundToOwner`) and the owner reads it in the owner-menu **Inbox**; only the legacy v1 `handleSealTel` still answers `NONE` |

Rationale for the "different user" row: interrupting user B's private session with user A's call is both a
privacy leak and the fragile cross-user-overlay case; treating the owner as absent (missed + sealed) is
cleaner on both counts. Flippable to "shared-phone" semantics later if wanted; default is no.

### The unbound row is the one with open questions (`NWP-20260822-02`) — answered 2026-09-01, below

Every other row above assumes the SIM has a **profile** owner. The unbound row was implicit until 2026-08-22 and
is written out here because its *composite* behaviour was stated nowhere, and it is not an exotic state —
it is the default on a fresh device, and plausibly the steady state on a **rental** handset, where
`product-decisions.md` records that the operator owns the handsets and holds the
SIM account and we supply neither.

What the code does today (the unbound row above states the decided design; its "built" / "existing
behaviour" / ⚠ NOT BUILT annotations describe the code):

- **Outbound is blocked for every profile session.** `shouldBlockOutbound` asks `TEL-OWNER` and blocks on a
  definite `NO` (`ChooserActivity.java:7037-7054`). No profile owns an unbound SIM, so no profile may call or
  text with it. It fails *open* on any error, deliberately — wrongly blocking a real owner is worse. ✅ The
  device owner is the exception, not a profile: **owner mode at the gate** can place a call / send a text on
  the unbound SIM (owner-mode transmit, `NWP-20261001-04`, device-unproven), on the SIM's own subId, failing
  closed if that SIM's binding or phone account can't be resolved (never the default/bound SIM).
- **Binding needs owner mode.** `SET-BINDING` is reachable only from the owner-mode screen
  (`ChooserActivity.java:5692`), i.e. it needs the device-owner passphrase.
- **No login clears the notice.** `cancelTelNotices` is scoped to the logging-in profile's own SIM
  labels, so a notice nobody owns is never cancelled by any login — only a cold-lock resume clears all tel
  notices (`ChooserActivity.java:3214`) (see the backlog row; distinct from #466,
  which is the notice *appearing*).

So an unbound SIM is a working radio that no profile *session* may use — though the device owner may, from
owner mode at the gate (owner-mode transmit, `NWP-20261001-04`) — which answers every inbound event with a
notice naming nothing that no login clears (only a cold-lock resume's clear-all does), and which offers the user no route from that notice to binding it.

### ⚠ PARTLY DECIDED ALREADY — `#196`, and it was never written down

<!-- backlog: inbound is DROPPED, not delivered to the device owner -->

**DECIDED by Chester 2026-07-24** (recovered from agent memory 2026-08-22 — it appears **nowhere** in
this repo, which is exactly the failure `AGENTS.md` warns about): an unbound SIM's
inbound **must land on the DEVICE OWNER** rather than being dropped. Concretely:

- the call **still rings** at the gate;
- the record — SMS **and** call *(widened to MMS 2026-09-27, `docs/product-decisions.md`)* — is **sealed to a device-owner key** and delivered to the owner,
  modelled on the existing unbound-SMS handling;
- so the owner gets **relevant inboxes under the device-owner screen**.

The reasoning recorded with the decision: today a call to an unbound SIM rings, reaches
`NowhereInCallService`, and then produces **no seal and no notice** because there is no telephony key
to seal to. **Ring-without-record is the worst of the three options** — the caller believes they got
through and nobody gets any trace of it. *(Note 2026-09-24: since `#466` the gate does post the content-free
"an unassigned SIM" notice, so "no notice" no longer holds; there is still no seal and no record.)*

It will touch the cold-resume delivery path (`#195`).

**WHO MAY WIPE IT — DECIDED by Chester 2026-09-24**, verbatim: *"bound - it should get wiped after it lands to the assigned sim profile store"*; *"unbound - it shouldnt get wiped by any profile (only the owner or a reboot can clean it)"*.
(“Landed” = in the profile's Messages or call log; and anything delivered while a SIM is bound to a profile is
that profile's content — deleted with it, removed at an unassign, never the owner's — both Chester, 2026-09-24,
`product-decisions.md` Open section.) So a bound record lives until it has landed in its
profile's store, its profile is deleted, its SIM is unassigned, or the reboot; and an unbound record
until the owner clears it or the reboot — **never until another profile's create, login or logoff**. Before
`NWP-20260924-04` the inbox sat inside the agent's session directory, and `handleCreate`, the legacy `handleLogoff`
and the legacy login fallthrough `os.RemoveAll`ed that directory (`core/agent/main.go`), so a stranger enrolling at
the gate destroyed every undelivered record. Since then the records live in `$STATE/tel/`, which every one of
those wipes spares. Record: `product-decisions.md` 2026-09-24; row: `backlog.md` "Legacy `CREATE` + `LOGOFF` can still wipe the shared roam-state tmpfs".
Where the inbox lives is his too — *"the idea is to have an inbox behind owner passphrase (where we've bunch of other things)"*; that it is a row in the owner menu is our reading of
that, not his words. *(Resolved 2026-09-27: he chose the option put to him as “A row in the owner menu listing calls, SMS and MMS …”, `docs/product-decisions.md`.)*

**RETENTION: RAM-ONLY, and that is deliberate — a privacy choice, not an implementation detail.**
Confirmed by Chester 2026-08-22: *"we intentionally kept in only ram for privacy purposes."* The
owner's unbound-SIM inbox uses the same tmpfs as every other sealed item —
`/data/nowhere/state` is a **tmpfs** mount (`nowhere.rc:134`, `size=256m`; verified live on lynx
2026-08-22) — so it is RAM-backed and **gone at power-off**. Per the 2026-09-24 wipe rule below it must also
sit where no profile-lifecycle wipe reaches — `$STATE/tel/`, which the wipes spare since `NWP-20260924-04`.

Why it has to be that way, stated so nobody "improves" it later: this inbox belongs to the DEVICE
OWNER, whose storage is **user-0**, and user-0 is the one user the amnesiac machinery never wipes.
Persisting it would therefore create a standing at-rest record of *who called this handset and when*,
surviving power-off, on exactly the partition that no wipe path reaches — and it would be a **second**
exception to "nothing kept after a reboot" beside the binding registry above. *(Superseded in part 2026-09-27, `docs/product-decisions.md`: the device-owner telephony keypair will also persist on user 0 — our engineering reading of the owner-key choice, built 2026-09-28 (`NWP-20260928-01`) — so persisting this inbox would be a third exception, and the first that is a record of calls and messages rather than config or key material.)* Sealing it to an owner
key makes it ciphertext, but the metadata trail would still exist and still outlive the device being
switched off. RAM-only keeps the promise: **an undelivered record is simply gone at the next reboot**,
which is the same best-effort contract the sealed inbox already makes for bound SIMs.

⚠ The cost is real and accepted: an owner who does not open the device before a reboot **loses** those
records. That is the deliberate trade. *(Narrowed 2026-09-27 by Chester's answers 2–4, `docs/product-decisions.md` *“no telephony arrival may be lost…”*: a reboot the daemon or the gate forces on its own — the unacknowledged switch and remove fallbacks, a delete with no uid, a user that will not remove, an unacknowledged LOGOUT — is not part of this trade. The reboots stay, and a record lost to one is a defect: `docs/backlog.md` §B, the rows *“The daemon's reboot fallback after a logoff or delete that the gate does not acknowledge in time loses every profile's pending telephony records”*, *“A delete whose session marker has no uid reboots at once and loses every profile's pending telephony records”* and *“The gate's own reboots lose every profile's pending telephony records: the reap's when the user will not remove (after a logoff, delete or rollback, or at the 12 h hard-wipe), and the logoff screen's when LOGOUT goes unacknowledged”*.)*

**DECIDED 2026-09-01** — the five questions this section held are answered in
`product-decisions.md` ("The unbound SIM is the device owner's line"), which
is the record; this doc now states the outcomes so a reader here is not misled:

1. **Outbound on an unbound SIM belongs to the DEVICE OWNER** — from owner mode at the gate, behind
   the device passphrase (the gate already holds user-0's `ROLE_DIALER`). Roamed sessions remain
   blocked, and the block finally gets a user-facing explanation and a route. *(Where and in what words,
   decided 2026-11-01, `docs/product-decisions.md`, 2026-11-01, *"twenty-two answers to harvests 50, 51 and 52 ..."*, h52 #3: one line on the session's Profile screen under
   "Mobile data", shown while the phone has an active SIM the profile does not own, naming no SIM and worded
   the same whether that SIM is unbound or bound to another profile; the route it names is owner mode at the gate.)*
2. **Emergency**: the callback rejection is fixed (`NWP-20260901-12`); T1 (outbound 112 under the
   restriction) and T2 (gate emergency end-to-end) were **PROVEN 2026-10-01 on lynx `2026100100`**
   (`NWP-20261001-03`), via Android's test-emergency-number override — never a live 911: T2 placed a
   genuine emergency call (`isEmergency=true`) from the gate's "Emergency call" link inside Lock Task,
   connected end-to-end; T1 confirmed a normal call is refused under `DISALLOW_OUTGOING_CALLS` while the
   emergency number still places and connects. This cleared the gate on owner-mode transmit.
3. **Many-owner is ratified** — see the corrected binding-record shape above.
4. **Rental binding is the code + portal-approval flow**: the renter enters an operator-issued code;
   the request surfaces on the operator portal carrying ONLY the code — nothing profile-related; the
   operator approves and the bind completes. Interactive approval, not a unilateral offline redeem —
   `#138`'s `REDEEM-SIM` row is to be reshaped to this. Direct-to-customer keeps owner-mode binding.
   All of it sits behind the mandatory-owner-passphrase P0. Refined same day: the **approval process
   is operator-configurable** (auto-approve on a valid code, or manual approval — the policy lives in
   the operator's portal config, not the OS); while approval is pending the renter gets an **in-band
   nudge** (a should-have, not a ship gate), and the pending UI must never present itself as the only
   channel — out-of-band contact with the operator always exists and the screen says so.
5. **The notice offers a ROUTE, never a control**: a single notice — the unassigned line's — is
   tappable to the owner *verify* (never past it — the screens beyond leak owner counts and a full
   ICCID); a banner summarising SEVERAL notices is tappable to a popup listing each notice's own line
   and nothing more (Q064, decided 2026-10-20, `NWP-20261105-06`), and the same route sits on the
   unassigned line's entry as an "Open owner inbox" button to that verify, never past it. The route
   is hard-gated on `ownerSecretSet()` so a no-passphrase device has none (the popup still opens), and
   the notice never promises completion at the gate.

## Strict zero-window & the cleartext-transient problem

The owner chose **strict zero-window**. `content delete` alone is *not* erasure — deleted sqlite rows
sit in free pages + WAL until VACUUM, and the providers aren't the only surface (framework caches,
RIL last-call, dialer MRU). So:

- **SMS — achievable zero-window.** The gate app is the **default SMS app on user-0**, so `SMS_DELIVER`
  comes to us and *we* own the inbox write — which we simply **skip**: seal the fields, never persist
  cleartext to `mmssms.db`. *(Verify V2: whether the framework writes the assembly `raw` table before
  our handler runs, and scrub it if so.)* *(Superseded in part 2026-09-28, `docs/product-decisions.md`: SMS is not zero-window. V2 is answered yes — the framework stores every segment in `raw` before `SMS_DELIVER` reaches us, and keeps a delivered text's rows, to discard a network re-send, until their SMSC timestamp is an hour old (so not at all, for a text the SMSC held longer, as in a power-on flush after a longer power-off); `TelScrub.sms` removes them at its first run after that, or the framework at its next raw-table query, and an incomplete text's segments stay, across power-offs, until the framework expires them — by default at a boot seven days after their SMSC timestamp, or after a day in service, with no ceiling while the phone is off.)* *(extended 2026-09-29: on a SIM hidden from user 0 by another SIM's link to the gate, multi-part texts and multi-part MMS notices, complete ones included, and single-part texts and MMS notices left for a scan, stay with no expiry while it stays hidden, on, in service or rebooted, and in some cases with no bound after, and a network re-send of a text already delivered on it is not discarded — `docs/backlog.md`, “While one SIM is linked to the gate user, the phone never reassembles a multi-part SMS or MMS notice on the other SIM”, which gives the rule for which SIM is hidden)* *(Not on a build carrying `sms-raw-no-sim-filter.sh`, `NWP-20260929-02`, where the phone sees every SIM's `raw` rows.)*
- **Calls — near-zero, best-effort.** The platform auto-logs a *managed* carrier call to the CallLog on
  end (the dialer app doesn't control this). So a transient cleartext call-log row exists; we **seal +
  delete + secure-scrub** (delete → VACUUM/WAL-truncate the CallLog db) to minimize the window.
  Honest caveat: calls are *near*-zero, not truly zero. *(V3.)*
- **Sealed buffer** lives in **tmpfs** (RAM ciphertext). **Persistent binding config** is non-secret.
- A **per-boot janitor** (in `nowhere_gate.sh` / `BootReceiver`) scrubs any residual telephony rows as
  the crash/battery-death backstop (no shutdown hook exists; `nowhere.rc` has only `sys.boot_completed`). *(Superseded in part 2026-09-28, `docs/product-decisions.md`: the janitor no longer touches the SMS `raw` table, which at `sys.boot_completed` can hold texts not yet delivered; `TelScrub.sms` removes only the rows the framework has dispatched, once past its one-hour window, and a row the framework never dispatched stays until the framework delivers or expires it.)* *(Superseded in part 2026-11-08, NWP-20261108-10, Q033: a raw row still at `deleted=0` is removed 24 hours after the gate first saw it, including a complete text the framework stored but never dispatched (asked of Chester in the NWP-20261108-10 PR), except on a SIM hidden from user 0 while another SIM is linked to the gate user.)*

## Answer surface (fixing the call-answer hole)

The in-call UI is a **full-screen-intent incoming-call activity** with turn-screen-on /
show-when-locked semantics — **not** the earlier "`setContentView` swap inside `ChooserActivity`",
which only works when the gate is already foreground with the screen on (an idle gate has the screen
*off*). Our own package is LockTask-allowlisted, so a full-screen-intent activity can wake + show
without dropping the kiosk. It shows the **raw number + SIM label** (no profile → no contacts). The
AOSP Dialer is **not** added to the LockTask allowlist (keypad/contacts/add-call = kiosk escape); the
emergency-dialer path (`com.android.phone`) is untouched. `GLOBAL_ACTIONS` stays enabled during a call
so the user can always power off.

## Owner mode (#136)

Owner mode is the device-admin escape hatch and the home of SIM binding.

- **Owner secret** — set at the **initial setup flow** (first boot), **SE-bound** (Weaver-throttled,
  hardware-bound; see [se-binding.md](se-binding.md) + task #18), **separate** from every profile
  passphrase. It authenticates the *device owner*, not a roaming identity.
- **Flow:** gate → "Owner settings" affordance → owner-secret auth → **stand down** LockTask + the
  #46 watchdog → **user-0 Settings** (a hardened "normal phone": enable USB debugging, remove/manage
  eSIM, and other user-0-only admin ops that a secondary user cannot perform) **+ the SIM-binding UI**
  → "Back to gate" → **re-arm** LockTask + watchdog + re-pin user-0 HOME.
- **Binding UI:** bind a SIM → pick/confirm the owning profile, set its label + visibility dial, and
  capture the profile's telephony pubkey.
- **Choreography:** the watchdog stand-down + LockTask exit/re-enter must be transactional so a crash
  mid-owner-session can't leave the kiosk unlocked (re-arm on any resume/boot).

## Amnesia / persistence summary

| Thing | Persists across reboot? | Encrypted at rest? |
|---|---|---|
| SIM→profile binding (ref, **pubkey**, label, dial) | **Yes** (deliberate; config, non-secret) | n/a (public) |
| Sealed telephony inbox (undelivered) | **No** (tmpfs, RAM); deleted at an unassign of its SIM | Yes (sealed to profile pubkey) |
| Device-owner inbox (unbound SIM) — ✅ BUILT `NWP-20261001-01`/`-02` (device-unproven); stored at `$STATE/tel/owner/` | **No** (same tmpfs; removed only by the owner or the reboot, never by a profile — Chester 2026-09-24) | Yes (sealed to the device-owner key `NWP-20260928-01`; read in the owner-menu Inbox behind the owner passphrase) |
| Delivered telephony (inside a profile) | Roams/seals with the profile | Yes (profile vault) |
| Transient provider rows (SMS raw / call-log) | **No** (prevented or scrubbed) *(SMS `raw`: superseded in part 2026-09-28 — a delivered text's rows stay until their SMSC timestamp is an hour old (so not at all, for a text the SMSC held longer, as in a power-on flush after a longer power-off), and then until the first scrub or raw-table query after that, across a power-off too; an incomplete text's, across power-offs, until the framework expires it, with no ceiling while the phone is off; a complete undelivered text whose SIM is out of the phone, with no expiry; `docs/product-decisions.md`)* *(extended 2026-09-30: on lynx such a text stayed even with its SIM in the phone, because the boot scan ran before the SIMs were ready at the one boot measured (2026-09-29, `2026092902`) — INFERENCE that it holds at every boot — until a day in service within one boot: `docs/backlog.md`, “At boot the framework scans for undelivered texts before the SIMs are ready, so on lynx that scan delivers none of them”)* *(extended 2026-09-29: on a SIM hidden from user 0 by another SIM's link to the gate, multi-part texts and multi-part MMS notices, complete ones included, and single-part texts and MMS notices left for a scan, stay with no expiry while it stays hidden, on, in service or rebooted, and in some cases with no bound after, and a network re-send of a text already delivered on it is not discarded — `docs/backlog.md`, “While one SIM is linked to the gate user, the phone never reassembles a multi-part SMS or MMS notice on the other SIM”, which gives the rule for which SIM is hidden)* *(Not on a build carrying `sms-raw-no-sim-filter.sh`, `NWP-20260929-02`, where the phone sees every SIM's `raw` rows.)* | No (why we prevent/scrub) |
| Profile telephony privkey | With the profile vault | Yes (vault) |
| Device-owner telephony keypair (decided 2026-09-27) — BUILT 2026-09-28 (`NWP-20260928-01`); DEVICE-PROVEN 2026-09-28 on lynx `2026092802` for the verify path, the enrol path not yet run on a device | **Yes** (`/data/nowhere/owner-key`, `nowhere_data_file`, user 0 like the binding; our engineering reading of the 2026-09-27 choice, not his words) | Private half wrapped (AES-256-GCM) under Argon2id t=3, 64 MiB over the owner passphrase with its own 32-byte random salt, HKDF-mixed on a StrongBox phone with a StrongBox pepper (2026-09-28) |

## Device-owner key (`NWP-20260928-01`)

The key the unbound SIM's records are sealed to (decided 2026-09-27; StrongBox tie decided 2026-09-28, `docs/product-decisions.md`). ✅ The seal-to-owner slice landed `NWP-20261001-01`/`-02` (device-unproven): `sealUnboundToOwner` seals an unbound arrival to this key's public half under `$STATE/tel/owner/`, and the owner-menu Inbox reads it behind the owner passphrase.

- **File:** `/data/nowhere/owner-key`, 0600, five LF-terminated lines: `nowhere-owner-key v1`, `pub=` (X25519, the same kind as a profile's telephony key, so `sealTelItem`/`openTelItem` work unchanged), `pepper=none|strongbox`, `salt=` (32 random bytes), `wrapped=` (`wrap()` of the private half). Published by temp file, fsync and rename. Since `NWP-20261021-11` a rewrap writes **v2**: seven lines, `nowhere-owner-key v2`, `pub=`, `pepper=` (one mode for the file), `salt=` + `wrapped=` (the NEW wrapping), `old.salt=` + `old.wrapped=` (the wrapping the old passphrase opened), each with its own salt and both of the same private key. At a verify, a header naming a version above v2 is kept (so an agent from before `NWP-20261021-11` keeps a v2 file and answers `ERR version`) and any other file that is not exactly the v1 or v2 grammar is replaced; an enrol replaces any file. A directory at the path, or a non-empty directory at `.owner-key.tmp`, makes both answer `ERR io` (a rename will not replace a directory), and nothing but its removal recovers.
- **Verbs:** `OWNER-KEY-NEW` at an enrol whose `owner.conf` read back correctly, and `OWNER-KEY-ENSURE` at a successful verify — the heal for a device enrolled before the key existed. Request: `<verb>\nv1\n<pepper base64 or ->\n<passphrase base64>\n`. `OWNER-KEY-NEW` always mints a new key (`CREATED`, or `REPLACED` over any file). `OWNER-KEY-ENSURE`, in `ownerKeyOp`'s order: no file → mint, `CREATED`; not exactly the v1 or v2 grammar → mint, `REPLACED`; a newer-version header → kept, `ERR version`; a `pepper=strongbox` key and no pepper → kept and not opened, `ERR mode` (never downgraded, 2026-09-28); a `pepper=none` key and a pepper → mint without opening the old one, `REPLACED`; opens and `pub=` matches → nothing written, `OK`; on a v2 file (`NWP-20261021-11`): the passphrase opens the NEW wrapping → v1 written from it, `REPAIRED`, logged `owner-key pruned the old wrapping`; it opens only the OLD wrapping → nothing written, `OK` (the change has not landed, or this is the verify that preceded the rewrap, whose ENSURE can arrive after it; pruning to the old wrapping would drop the new one); it opens neither → mint, `REPLACED`; opens and `pub=` differs → `pub=` rewritten from the wrapped half, which is the authenticated part, `REPAIRED`; does not open → mint, `REPLACED`. A read error other than “absent”, or a failed publish, answers `ERR io` and leaves the old file as it was. `OWNER-KEY-REWRAP` (`NWP-20261021-11`, the passphrase change; ~~the chooser's change screen is not built yet~~ *(superseded by NWP-20261022-01: owner mode's Device passphrase screen verifies the old passphrase, sends it, and writes `owner.conf` only on `OK` or `NOKEY`; every owner-key verb goes through one FIFO sender, so an ENSURE for the old passphrase cannot land after the prune)*): `OWNER-KEY-REWRAP\nv1\n<old pepper or ->\n<old passphrase base64>\n<new pepper or ->\n<new passphrase base64>\n`, replies in order, nothing written unless `OK`: no file or an unreadable one → `NOKEY` (the next ENSURE under the new passphrase creates a key); a newer file → `ERR version`; an old or new pepper that does not match the file's `pepper=` → `ERR mode` (never a pepperless wrapping on a StrongBox file, no mode change through this verb); the old passphrase and pepper open no wrapping → `WRONG` (the destructive replace stays ENSURE's alone); a failed read or publish → `ERR io`; otherwise v2 {new wrapping under a fresh salt, the wrapping the old passphrase opened}, `pub=` unchanged, `OK`. It derives once per wrapping tried (the new first), then once for the new wrap. The owner inbox (`ownerKeyFromRequest`) opens either wrapping, so no item is unreadable at any order of the rewrap, the verify's ENSURE and a failed `owner.conf` write. The gate sends a StrongBox phone's request only with its pepper (`seBroken` otherwise), so a StrongBox phone never mints a pepperless key. Only the user-0 gate chooser may call the verbs (an app uid, at least 10000, equal to the pinned chooser appId): a roamed session's chooser, root, a system uid that became the pin, and a failed peer lookup are refused before the request is read.
- **Locks:** the verbs never take `sessionMu`. Argon2 runs outside every lock but `ownerKeyMu`, and the publishing rename takes `telMu`; the order is `ownerKeyMu` then `telMu`, and nothing that holds `telMu` or `sessionMu` takes `ownerKeyMu`.
- **Logs:** class-only `[logind] owner-key …` lines (no colon after `key`, which the issue-report scrubber would read as a secret pair); never the passphrase, the pepper, or anything in the file.
- **Lifetime:** survives reboot and power-off; removed only with `/data` (a factory reset, or Leave Nowhere). Not tied to any profile, so blind login is untouched.

## Build plan

**Phase A — owner-mode foundation (#136), lands first (the binding everything reads):**
- **A1** Owner secret: set at initial setup, SE-bound (Weaver), verified from the gate. (Ties to #18.)
- **A2** Owner-mode session: auth → LockTask + #46 watchdog stand-down → user-0 Settings → back-to-gate
  re-arm. Independently valuable (the "hardened normal phone" escape hatch).
- **A3** Binding UI + `bindings.conf`: SIM → profileRef + label + visibility; capture pubkey.

**Phase B — telephony data path (#135):**
- **B1** Per-profile X25519 keypair (gen at profile create; pubkey→binding; privkey→vault).
- **B2** Sealed inbox: seal→tmpfs; ingest-at-login (`content insert --user N` — built instead as delivery v2, the
  roamed chooser's `TelIngest`); lifetime = login|reboot *(superseded 2026-09-24: until it lands in its profile's store, or reboot)*.
- **B3** SMS: default-SMS-app on user-0 → `SMS_DELIVER` → seal (no cleartext write) → content-free
  notice per dial; instant ingest if owner live. default-permissions XML for `RECEIVE_SMS`.
- **B4** Calls: InCallService + `ROLE_DIALER` (user-0); full-screen-intent incoming-call activity per
  state+dial; on end seal call-log entry + delete/scrub; native in-session if owner live (see V1).
  default-permissions XML for `ANSWER_PHONE_CALLS`/`MANAGE_OWN_CALLS`.
- **B5** Janitor / secure-erase: prevent (SMS) + delete-and-scrub (calls) + per-boot backstop. *(Superseded in part 2026-09-28, `docs/product-decisions.md`: SMS `raw` is not prevented, and the per-boot backstop no longer touches it; `TelScrub.sms` removes only the rows the framework has dispatched.)* *(Superseded in part 2026-11-08, NWP-20261108-10, Q033: a raw row still at `deleted=0` is removed 24 hours after the gate first saw it, including a complete text the framework stored but never dispatched (asked of Chester in the NWP-20261108-10 PR), except on a SIM hidden from user 0 while another SIM is linked to the gate user.)* *(Calls, NWP-20261012-07: Telecom's own missed-call notification, which carries the caller's number in the clear, is prevented rather than cancelled. Telecom posts it in user 0 for a live miss at the gate and at every switch back to user 0, from the call log every SIM call is also written to, unless user 0's dialer declares a receiver for `ACTION_SHOW_MISSED_CALLS_NOTIFICATION`; the chooser's `MissedCallReceiver` is that receiver. It posts nothing and scrubs user 0's call log. The gate's own notices are the chooser's, not Telecom's, and are untouched.)*
- **B6** sepolicy: `telecom_service` find + two-way `binder_call(nowhere_chooser, telecom)` in
  `nowhere.te`; harvest on **userdebug-ENFORCING lynx** and mirror into `endospore.te` (permissive
  hides the denials — the #137 trap).

**Phase C — verification** on FP3 (permissive su:s0) *and* lynx (enforcing endospore_priv).

**Dependencies:** B needs A3 (binding) for the owner lookup; B1/B2 (keypair, sealed inbox) can be
built in parallel with A. A2 is independently shippable.

## Open verification items

- **V1 (biggest):** does an *incoming* call route natively to a **foreground roamed** (secondary) user
  on lynx/GrapheneOS and FP3/Lineage? The roamed-telephony work enabled *outgoing* + Messaging; incoming
  presentation is separate. Fallback: user-0 InCallService mediates presentation (audio is radio-level
  so it works cross-user; the record ingests to the live owner). The "normal-phone feel" is the risk,
  not the function.
- **V2:** does the framework write the SMS body to `mmssms.db`'s assembly `raw` table *before* our
  default-SMS-app handler runs? If so, scrub it. (Decides whether SMS is truly zero-window.) *(Answered yes: the B5 comment in `SmsDeliverReceiver`, 2026-07-11. What is kept and for how long: `docs/product-decisions.md`, 2026-09-28. SMS is not zero-window.)*
- **V3:** can the transient managed-call CallLog row be prevented, or only delete+scrubbed? (Decides
  "strict zero-window" reachability for calls.)
- **V4:** cross-user call presentation for the different-user case — we choose **not** to present, which
  sidesteps it; confirm no stray surfacing.
- **V5:** Weaver/SE binding for the owner secret on both editions (ties to #18).

## Doc updates on landing

Update [threat-model.md](threat-model.md) (persistent SIM binding + telephony sealed-inbox posture),
[roaming-boundaries.md](roaming-boundaries.md) (telephony now roams via sealed delivery, not "doesn't
roam"), [identity-model.md](identity-model.md) (per-profile telephony keypair), and `AGENTS.md`
(owner-mode entry + binding). Cross-link [lock-model.md](lock-model.md) for the cold-lock row.

*(All five DONE: four on 2026-10-12, `NWP-20261011-49`, and the fifth on 2026-10-13, `NWP-20261013-47`: threat-model.md marks “Telephony doesn't roam” superseded in
place and lists `bindings.conf` with the rest of what user 0 keeps, under “What user 0 keeps across a reboot”;
roaming-boundaries.md carries sealed delivery in its Messages bullet and a worked-examples row; identity-model.md
has “A profile's telephony keypair”; AGENTS.md has the owner-mode + SIM-bindings entry under “Where Things Live”.
lock-model.md links this doc's cold-locked row from its resumable cold-lock section.)*
