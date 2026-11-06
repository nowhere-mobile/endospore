# #157 — App distribution (Aurora) + push (UnifiedPush)

How a de-Googled, amnesiac roaming phone gets **Play-store apps** and **push notifications**
without Google Play Services. Companion to [app-model.md](app-model.md) (which decided *only
private data roams; app code re-downloads per device*). Gaps #5 (push) + #10 (app store).

Decided 2026-07-23: **anonymous Aurora Store** (no microG) + a **gateway-integrated
UnifiedPush distributor** (our own push relay, native seal-and-replay for a logged-out owner).

---

## Part A — Aurora Store (anonymous Play distribution)

### Why
[app-model.md](app-model.md) already blessed Aurora/microG as the Play-app re-download path;
only F-Droid is bundled today. Aurora Store (`com.aurora.store`, FOSS/GPLv3) downloads Play
apps over Google's own delivery API using a **shared anonymous session** (Aurora's dispenser) —
no Google account, no Google Services Framework, no GCM. This is the privacy-preserving posture:
we get Play *app code* (device-correct splits) while push stays entirely on UnifiedPush (Part B).

**microG is explicitly rejected** for this task: on a verified-boot fork without signature
spoofing it's crippled, and its GCM path would compete with UnifiedPush and the amnesiac
seal-and-replay. If a future banking-style app forces the issue it's a separate decision.

### Bundling (mirrors the F-Droid default-app pattern, `*.mk` + `fetch-default-apps.sh`)
- Fetch a pinned Aurora release APK into `core/vendor-common/prebuilts/` (its own repo, not
  Play — Aurora self-updates in place via F-Droid once installed, so it stays **presigned**
  (⚠ Diaspore only: on Endospore Aurora is a `/product` system app, and GrapheneOS refuses its in-place updates —
  `NWP-20260924-05`)
  with Aurora's key, same as the curated F-Droid apps).
- Add an `Android.bp` prebuilt module + list it in both `diaspore.mk` and `endospore.mk`.
- **Silent install** — Aurora normally drives the non-privileged `PackageInstaller` session UI
  (a per-app confirm dialog), which the kiosk gate would trap and a roamed reinstall can't
  babysit. Give Aurora the privileged installer path instead: place it in **`priv-app`** and
  allowlist `android.permission.INSTALL_PACKAGES` (+ `DELETE_PACKAGES`) in
  privapp-permissions, so `AuroraServices`-style silent install works with no dialog. (Priv-app
  ⇒ needs a full build + flash and a versionCode-aware PM re-scan; not hot-patchable.)

### Roam wiring (P2-A, overlaps #168)
The app **manifest** (`{package, source=aurora|fdroid|carried, version}`) is already the roaming
private state. `provisionRoamedApps` today only `install-existing`s *baked* apps; extend it so a
manifest entry with `source=aurora` triggers a background Aurora fetch-by-package on roam-in
(deferred if offline; data re-attaches when the code lands — app-model's install-then-restore
ordering). Aurora runs headless via an install-by-package intent; no user interaction.

### Phasing (A)
- **P1-A** — bundle Aurora as a silent-install priv-app; prove it installs a named Play app
  on-device with no dialog (manual trigger). *Needs the tonight build + flash.*
- **P2-A** — wire `source=aurora` manifest entries into `provisionRoamedApps` roam-in reinstall
  (with the offline-defer path); prove a roamed app list reconstitutes a Play app on a 2nd device.

---

## Part B — Gateway UnifiedPush distributor (push without FCM)

### UnifiedPush in one paragraph
An app that wants push uses a UnifiedPush **connector** library and broadcasts `REGISTER` to
whatever **distributor** app is installed. The distributor obtains an **endpoint URL** from its
**push server**, hands it back (`NEW_ENDPOINT`); the app forwards that URL to *its own*
application server (Mastodon, Matrix, …). When there's a notification the app server `POST`s the
(RFC 8291 **webpush-encrypted**) payload to the endpoint URL; the push server routes it to the
connected distributor over a persistent link; the distributor broadcasts `MESSAGE` to the app,
which **decrypts locally** and shows it. **The push server and distributor see only ciphertext.**

### Our design: the gateway is the push server (relay), the distributor is our app
This fits the gateway's stated ethos exactly — *never sees plaintext, no accounts, meters opaque
refs*. The gateway already store-and-forwards **sealed** blobs; a push relay store-and-forwards
**webpush-encrypted** payloads keyed to an opaque endpoint. New endpoints (all E2E-ciphertext):

| Endpoint | Caller | Purpose |
|---|---|---|
| `POST /push/register` | distributor | mint an opaque `endpoint = /push/{token}` (random 128-bit); returns the full URL *(and, decided 2026-10-21 (dn-1102 #5, the entry *"twenty-two recommendations accepted — the login daemon forgets a session's keys ..."* in `docs/product-decisions.md`, `NWP-20261021-27`), a stream secret that the stream and unregister require; a registration without one is served as today until a NowherePush release that sends the secret has reached every handset, then refused 90 days later with a `gone:` line, decided 2026-10-22 (`docs/product-decisions.md`, *"seventy-two recommendations accepted, and three more answers ..."*), #3; unbuilt)* |
| `POST /push/{token}` | an app's server | enqueue one webpush payload for `token` (size-capped, TTL'd); 201 if a live stream took it, 202 if queued |
| `POST /push/stream` | distributor | **SSE** long-lived link; the tokens travel in the JSON body `{"tokens":[…]}`, never in the URL or a header; drains the queued backlog then streams live pushes for the session's endpoints *(⚠ superseded in part 2026-10-21, dn-1102 #5: the token alone will not open a stream; each endpoint's stream secret rides in the same body)* |
| `GET  /push/stream?tokens=…` | distributor | the transition form of the stream above (tokens in the query string); `NowherePush` uses it only after an older gateway answers the POST 404 or 405 *(it can carry no stream secret, which never goes in a URL: dn-1102 #5, 2026-10-21, an inference)* |
| `POST /push/unregister` | distributor | drop an endpoint + its queue *(⚠ superseded in part 2026-10-21, dn-1102 #5: only with the endpoint's stream secret)* |

- **Transport = SSE** (one-way server→device, trivial through the gateway's plain HTTP, no
  websocket upgrade). The distributor holds one `/push/stream` per live session covering all its
  endpoints.
- **Queue = per-endpoint, ciphertext, bounded** (e.g. ≤4 KiB × N, 24 h TTL) — a lapsed queue is
  GC'd like a lapsed lease. The gateway can't read it; the webpush privkey lives in the app's
  roamed data.
- **No accounts / no metering** — push is a free relay (like `/cap?op=read`), rate-limited per
  endpoint. Endpoints are unlinkable random tokens; the gateway never learns which app/profile.

### The amnesiac model — seal-and-replay = store-and-forward + drain-at-login
This is the #135 telephony pattern, realized server-side because the payload is *already*
E2E-encrypted:
- **Owner logged in** → the distributor (in the roamed session) holds `/push/stream`; pushes
  arrive live. Endpoints are re-minted per registration, so a fresh device re-registers and the
  app re-sends its new endpoint to its server (standard UnifiedPush; a brief switch window can
  miss a push, same as reinstalling a push app on stock Android).
- **Owner logged out / roamed away** → the stream is gone; the gateway **queues** each push
  (ciphertext, TTL'd). At next login the distributor reconnects and the SSE **backlog drains
  first** → the notifications appear. Nothing plaintext ever rests server-side, and nothing
  telephony-style needs to be sealed on the device.
- **P2-B (optional hardening)** — a user-0/gate distributor component could hold streams for
  away-owners and seal pushes into a device push-inbox (a `telinbox` cousin) so *nothing*
  (not even ciphertext) rests on the gateway. Deferred: given webpush E2E encryption + TTL, the
  server-side queue already meets the privacy bar; this only removes the metadata that *an*
  endpoint received *a* push at *a* time.

### Distributor app (`core/` new app, both editions)
Implements the UnifiedPush distributor spec (the `REGISTER`/`UNREGISTER`/`NEW_ENDPOINT`/`MESSAGE`
broadcast contract): on `REGISTER` call `/push/register`, return the URL; run a foreground
service holding the `/push/stream` SSE while the session is live; on a streamed push broadcast
`MESSAGE` to the target app. Ships as a normal roamed app (per-app registrations live in the
app's own roamed data). Bundle the FOSS **UnifiedPush connector** into our default apps so a
bundled Fediverse/Matrix client can exercise it.

### Phasing (B)
- **P0** — this doc (protocol locked). ✅
- **P1-B** — gateway relay (`/push/register|{token}|stream|unregister`) with an in-memory queue
  + SSE, unit-tested in `nowhere-cloud`; a minimal distributor app; prove **in-session**
  end-to-end (register → server POST → SSE → `MESSAGE` → notification) with a test client.
  *No device flash needed for the gateway half.*
- **P2-B** — endpoint lifecycle across roam + queue TTL/GC + login-drain proven on-device;
  bundle a real UnifiedPush-capable app; (optional) the gate-side seal.

---

## Privacy summary
- Gateway sees **only** webpush ciphertext + opaque random endpoints; no accounts, no app
  identity, no plaintext. Same trust surface as the sealed-blob store.
- Aurora runs **anonymous** (no Google account, no GSF); it fetches public app *code*, which
  app-model.md already treats as non-secret.
- App **list** (which apps, which endpoints) stays in the encrypted roaming state; app **code**
  and **push ciphertext** are the only things that touch the network in the clear-of-identity.

## Build/verify notes
- Gateway (Go, `nowhere-cloud`) builds+tests on the VM (no local Go); the push relay is pure
  `net/http` + SSE, unit-testable with `httptest` — no store/issuer coupling.
- Aurora + the distributor app land in `/product` ⇒ a full `m systemimage` + flash (priv-app,
  not hot-patchable) — batch into a night build.
