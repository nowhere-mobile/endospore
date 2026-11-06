package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

// ADD-DEVICE EDITS THE VAULT IT READS INSIDE ITS BRACKET (NWP-20261111-10).
//
// hardenVaultTo used to append the new phone's `se` slot to the vault its CALLER read before the bracket, and
// publish that at Version+1 with nothing armed. A seal, PIN change or key revocation that phone A published while
// phone B sat in Argon2 was then put back to the older vault: the head named the old Manifest again and a revoked
// slot came back. These tests make that move for real, through a proxy in front of the store, at the two moments
// that matter: between the caller's read and the bracket (kept), and inside the bracket after its read (refused).
//
// ⚠ NONE OF THEM SETS NOWHERE_STATE. headBlobGet caches head blobs under the state dir; unset, every head read goes
// over the wire, which is what lets a hook on a blob GET mark the moment a read happens.

// addDeviceStaleProxy fronts store: it forwards every request unchanged and runs each hook once, before forwarding
// the request it is keyed on ("GET /blob/<hash>" or "POST /blob"). gets counts GETs per blob hash.
type addDeviceStaleProxy struct {
	url   string
	store string
	mu    sync.Mutex
	hooks map[string]func()
	fired map[string]bool
	gets  map[string]int
}

func newAddDeviceStaleProxy(t *testing.T, store string) *addDeviceStaleProxy {
	t.Helper()
	p := &addDeviceStaleProxy{store: store, hooks: map[string]func(){}, fired: map[string]bool{}, gets: map[string]int{}}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		key := r.Method + " " + r.URL.Path
		p.mu.Lock()
		if r.Method == "GET" && strings.HasPrefix(r.URL.Path, "/blob/") {
			p.gets[strings.TrimPrefix(r.URL.Path, "/blob/")]++
		}
		hook := p.hooks[key]
		if hook != nil && !p.fired[key] {
			p.fired[key] = true
		} else {
			hook = nil
		}
		p.mu.Unlock()
		if hook != nil {
			hook()
		}
		req, err := http.NewRequest(r.Method, store+r.URL.RequestURI(), r.Body)
		if err != nil {
			w.WriteHeader(http.StatusBadGateway)
			return
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			w.WriteHeader(http.StatusBadGateway)
			return
		}
		defer resp.Body.Close()
		w.WriteHeader(resp.StatusCode)
		io.Copy(w, resp.Body)
	}))
	t.Cleanup(srv.Close)
	p.url = srv.URL
	return p
}

func (p *addDeviceStaleProxy) onBlobGet(hash string, fn func()) { p.on("GET /blob/"+hash, fn) }
func (p *addDeviceStaleProxy) onFirstPost(fn func())            { p.on("POST /blob", fn) }

func (p *addDeviceStaleProxy) on(key string, fn func()) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.hooks[key] = fn
}

// assertFired is every test's control: a hook that never ran moved nothing, and the test proved nothing.
func (p *addDeviceStaleProxy) assertFired(t *testing.T) {
	t.Helper()
	p.mu.Lock()
	defer p.mu.Unlock()
	for key := range p.hooks {
		if !p.fired[key] {
			t.Errorf("control: the hook on %q never fired, so the store never moved and this test proved nothing", key)
		}
	}
}

func (p *addDeviceStaleProxy) blobGets(hash string) int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.gets[hash]
}

// addDeviceEditPutRaw writes ref straight to the backing store over HTTP -- never putRef, whose stale and fence
// guards belong to the bracket under test.
func addDeviceEditPutRaw(t *testing.T, store, ref, val string) {
	req, err := http.NewRequest("PUT", store+"/ref/"+ref, strings.NewReader(val))
	if err != nil {
		t.Errorf("raw ref write: %v", err)
		return
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Errorf("raw ref write: %v", err)
		return
	}
	resp.Body.Close()
}

// addDeviceEditFixture is a profile whose head is V1, signed with dk.
type addDeviceEditFixture struct {
	store, name, pass, mnemonic string
	v1h                         string
	v1                          *vault
	dk                          []byte
}

var (
	addDeviceEditPass = "horse battery staple correct"
	addDeviceEditSeA  = []byte("adddevedit-handset-A-secret")
	addDeviceEditSeB  = []byte("adddevedit-handset-B-secret")
)

// addDeviceEditSetup creates name's vault on a fresh store and, when harden, hardens it to handset A.
func addDeviceEditSetup(t *testing.T, name string, harden bool) addDeviceEditFixture {
	t.Helper()
	t.Cleanup(clearSealExpectations)
	f := addDeviceEditFixture{store: newHTTPStore(t), name: name, pass: addDeviceEditPass}
	f.mnemonic = createVault(f.store, name, f.pass)
	if f.mnemonic == "" {
		t.Fatal("createVault returned no recovery code")
	}
	if harden {
		if err := enrollSE(f.store, name, f.pass, addDeviceEditSeA); err != nil {
			t.Fatalf("enrollSE (handset A): %v", err)
		}
	}
	f.v1h = getRef(f.store, profileRefV2(name, f.pass))
	v, ok := parseVault(getHeadBlob(f.store, f.v1h))
	if !ok {
		t.Fatal("the head is not a vault")
	}
	f.v1 = v
	if harden {
		f.dk = unwrapDK(v, "se", kekSE(name, f.pass, addDeviceEditSeA))
	} else {
		f.dk = unwrapDK(v, "pass", deriveKey(name, f.pass))
	}
	if f.dk == nil {
		t.Fatal("no slot opens V1")
	}
	if v.RecoveryRef == "" {
		t.Fatal("V1 has no recovery ref")
	}
	return f
}

// next builds the vault after prev, as another device's publish would: a copy with a new Manifest (or edit
// applied), Version+1, signed with the DK. It is posted to the store but published nowhere.
func (f addDeviceEditFixture) next(t *testing.T, prev *vault, manifest string, edit func(*vault)) (*vault, string) {
	t.Helper()
	v, ok := parseVault(serializeVault(prev))
	if !ok {
		t.Fatal("re-parse of a vault failed")
	}
	if manifest != "" {
		v.Manifest = postBlob(f.store, []byte(manifest))
	}
	if edit != nil {
		edit(v)
	}
	v.Version++
	signVault(v, f.dk)
	return v, postBlob(f.store, serializeVault(v))
}

// publish points the head and the recovery ref at h, as another device's flush does.
func (f addDeviceEditFixture) publish(t *testing.T, h string) {
	addDeviceEditPutRaw(t, f.store, profileRefV2(f.name, f.pass), h)
	addDeviceEditPutRaw(t, f.store, f.v1.RecoveryRef, h)
}

func (f addDeviceEditFixture) head(t *testing.T) (string, *vault) {
	t.Helper()
	h := getRef(f.store, profileRefV2(f.name, f.pass))
	v, ok := parseVault(getHeadBlob(f.store, h))
	if !ok {
		t.Fatal("the head is not a vault")
	}
	return h, v
}

// T1. Phone A publishes V2 (a seal) after phone B read V1 and before B's bracket opens. B's slot must land on V2:
// the head keeps V2's Manifest, at V2.Version+1, and both phones open it.
func TestAddDeviceEditKeepsAMoveBeforeTheBracket(t *testing.T) {
	f := addDeviceEditSetup(t, "adddevedit-a", true)
	v2, v2h := f.next(t, f.v1, "adddevedit-a manifest V2", nil)
	p := newAddDeviceStaleProxy(t, f.store)
	p.onBlobGet(f.v1h, func() { f.publish(t, v2h) })

	if err := enrollSEViaRecovery(p.url, f.name, f.mnemonic, f.pass, addDeviceEditSeB); err != nil {
		t.Fatalf("add-device: %v", err)
	}
	p.assertFired(t)
	_, cur := f.head(t)
	if cur.Manifest != v2.Manifest {
		t.Errorf("the head names Manifest %s, want V2's %s: add-device put the vault it read before its bracket "+
			"back over phone A's seal", short(cur.Manifest), short(v2.Manifest))
	}
	if cur.Version != v2.Version+1 {
		t.Errorf("head Version %d, want V2.Version+1 = %d", cur.Version, v2.Version+1)
	}
	if n := seSlotsOpenableBy(t, f.store, f.name, f.pass, addDeviceEditSeA); n != 1 {
		t.Errorf("handset A opens %d se slots, want 1", n)
	}
	if n := seSlotsOpenableBy(t, f.store, f.name, f.pass, addDeviceEditSeB); n != 1 {
		t.Errorf("handset B opens %d se slots, want 1", n)
	}
}

// T2. A move INSIDE the bracket, after its read: V3 lands while B's edit is being posted. The flush must refuse
// B's publish (an error, a stale hit), and both refs must still hold V3.
//
// The move fires on the first POST /blob, which is hardenVaultTo's postBlob of the edited vault: inside the bracket
// and after capReadVaultForEdit armed both refs. Fired on V2's blob GET instead, it would land inside readVaultHead
// before that reads the recovery ref's own value, so the recovery ref would be armed at V3 already.
func TestAddDeviceEditRefusesAMoveInsideTheBracket(t *testing.T) {
	f := addDeviceEditSetup(t, "adddevedit-b", true)
	v2, v2h := f.next(t, f.v1, "adddevedit-b manifest V2", nil)
	_, v3h := f.next(t, v2, "adddevedit-b manifest V3", nil)
	p := newAddDeviceStaleProxy(t, f.store)
	p.onBlobGet(f.v1h, func() { f.publish(t, v2h) })
	p.onFirstPost(func() { f.publish(t, v3h) })

	err := enrollSEViaRecovery(p.url, f.name, f.mnemonic, f.pass, addDeviceEditSeB)
	p.assertFired(t)
	if p.blobGets(v2h) == 0 {
		t.Error("V2's blob was never read: the edit did not read the head inside its bracket")
	}
	if err == nil {
		t.Error("add-device reported SUCCESS over a publish the store had moved past -- the phone is told it was " +
			"added while V3 is the head")
	}
	if !sealStaleHit {
		t.Error("no stale refusal was recorded: nothing armed the head this edit read")
	}
	if got := getRef(f.store, profileRefV2(f.name, f.pass)); got != v3h {
		t.Errorf("the head is %s, want V3 %s: add-device overwrote a publish made after its read", short(got), short(v3h))
	}
	if got := getRef(f.store, f.v1.RecoveryRef); got != v3h {
		t.Errorf("the recovery ref is %s, want V3 %s", short(got), short(v3h))
	}
}

// T3. The CLI path (enrollSE, the first hardening): the same move before the bracket is kept.
func TestAddDeviceEditCLIKeepsAMoveBeforeTheBracket(t *testing.T) {
	f := addDeviceEditSetup(t, "adddevedit-c", false)
	v2, v2h := f.next(t, f.v1, "adddevedit-c manifest V2", nil)
	p := newAddDeviceStaleProxy(t, f.store)
	p.onBlobGet(f.v1h, func() { f.publish(t, v2h) })

	if err := enrollSE(p.url, f.name, f.pass, addDeviceEditSeA); err != nil {
		t.Fatalf("enrollSE: %v", err)
	}
	p.assertFired(t)
	_, cur := f.head(t)
	if cur.Manifest != v2.Manifest {
		t.Errorf("the head names Manifest %s, want V2's %s: enrollSE put the vault it read before its bracket "+
			"back over a newer publish", short(cur.Manifest), short(v2.Manifest))
	}
	if n := seSlotsOpenableBy(t, f.store, f.name, f.pass, addDeviceEditSeA); n != 1 {
		t.Errorf("handset A opens %d se slots, want 1", n)
	}
	for _, s := range cur.Slots {
		if s.Kind == "pass" {
			t.Error("a `pass` slot survived hardening")
		}
	}
}

// T4. Idempotence is judged on the head read inside the bracket: another run already added B in V2, so there is
// nothing to write -- no second B slot, no new head.
func TestAddDeviceEditIsIdempotentOnTheHeadItReads(t *testing.T) {
	f := addDeviceEditSetup(t, "adddevedit-d", true)
	_, v2h := f.next(t, f.v1, "", func(v *vault) {
		v.Slots = append(v.Slots, keyslot{Kind: "se", Wrapped: wrap(kekSE(f.name, f.pass, addDeviceEditSeB), f.dk)})
	})
	p := newAddDeviceStaleProxy(t, f.store)
	p.onBlobGet(f.v1h, func() { f.publish(t, v2h) })

	if err := enrollSEViaRecovery(p.url, f.name, f.mnemonic, f.pass, addDeviceEditSeB); err != nil {
		t.Fatalf("add-device: %v", err)
	}
	p.assertFired(t)
	if got := getRef(f.store, profileRefV2(f.name, f.pass)); got != v2h {
		t.Errorf("the head moved to %s, want V2 %s untouched: B's slot was already on the head", short(got), short(v2h))
	}
	if n := seSlotsOpenableBy(t, f.store, f.name, f.pass, addDeviceEditSeB); n != 1 {
		t.Errorf("handset B opens %d se slots, want 1", n)
	}
}
