package main

import (
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// NWP-20261103-03: REPAIR-WALLET (Q153). The cases drive handleRepairWallet over a pipe, so the bytes the Profile
// screen will read are what is pinned, against a real http store fronted by a proxy that can damage or fail the
// profile's #wallet reads.

const walletRepairPass = "walletrepair-pass"

type walletRepairFix struct {
	name, pass string
	px         *httptest.Server
	dest, wp   string
	dk         []byte
	ref, head  string
	mu         sync.Mutex
	intercept  func(w http.ResponseWriter, r *http.Request) bool
	hits       int
}

func walletRepairSetup(t *testing.T, name string) *walletRepairFix {
	t.Helper()
	t.Setenv("GATEWAY_URL", "")
	blobCache = nil
	base := newHTTPStore(t)
	target, _ := url.Parse(base)
	proxy := httputil.NewSingleHostReverseProxy(target)
	f := &walletRepairFix{name: name, pass: walletRepairPass}
	f.px = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		f.hits++
		ic := f.intercept
		f.mu.Unlock()
		if ic != nil && ic(w, r) {
			return
		}
		proxy.ServeHTTP(w, r)
	}))
	t.Cleanup(f.px.Close)
	oldBase := repairWalletBase
	repairWalletBase = f.px.URL
	oldHook := repairWalletAfterReadHook
	t.Cleanup(func() { repairWalletBase = oldBase; repairWalletAfterReadHook = oldHook })

	createVault(f.px.URL, name, f.pass)
	f.dk = resolveDK(f.px.URL, name, f.pass, nil)
	src := filepath.Join(t.TempDir(), "wallet.json")
	var toks []BlindToken
	for i := 0; i < 10; i++ {
		toks = append(toks, BlindToken{Msg: "stored-" + string(rune('a'+i)), Sig: "sig"})
	}
	if err := saveWallet(src, &Wallet{BlindTokens: toks}); err != nil {
		t.Fatal(err)
	}
	markWalletRestoreLanded(src, walletGeneration(src))
	if _, err := sealWallet(f.px.URL, name, f.pass, f.dk, src); err != nil {
		t.Fatalf("fixture: sealWallet: %v", err)
	}
	f.ref = walletHeadKey(f.px.URL, name, f.pass)
	f.head = getRef(f.px.URL, f.ref)
	if f.head == "" {
		t.Fatal("fixture: no stored wallet head")
	}

	// the session: a sign-in whose wallet read failed, so it holds only its own two tokens and no proof
	f.dest = t.TempDir()
	if err := writeRoamSession(f.dest, name, f.pass, "11", "", true); err != nil {
		t.Fatal(err)
	}
	f.wp = walletPathFor(f.dest)
	removeWallet(f.wp)
	if err := appendTokens(f.wp, newBlindTokens()); err != nil {
		t.Fatal(err)
	}
	if !walletNotRestored(f.wp, walletGeneration(f.wp)) {
		t.Fatal("fixture: the session already has a restore proof")
	}
	return f
}

func (f *walletRepairFix) set(ic func(w http.ResponseWriter, r *http.Request) bool) {
	f.mu.Lock()
	f.intercept = ic
	f.mu.Unlock()
}

func (f *walletRepairFix) hitCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.hits
}

// walletRefRead is a GET of the profile's #wallet head, on any rung of its ladder.
func (f *walletRepairFix) walletRefRead(r *http.Request) bool {
	if r.Method != http.MethodGet || !strings.HasPrefix(r.URL.Path, "/ref/") {
		return false
	}
	ref := strings.TrimPrefix(r.URL.Path, "/ref/")
	return ref == f.ref || ref == profileRefV2(f.name+"#wallet", f.pass) || ref == profileRefLegacy(f.name+"#wallet", f.pass)
}

func (f *walletRepairFix) blobRead(r *http.Request) bool {
	return r.Method == http.MethodGet && r.URL.Path == "/blob/"+f.head
}

// breakWith makes every read of the wallet head (blob=false) or of the wallet blob (blob=true) go through fn.
func (f *walletRepairFix) breakWith(blob bool, fn func(w http.ResponseWriter, r *http.Request)) {
	f.set(func(w http.ResponseWriter, r *http.Request) bool {
		if (blob && f.blobRead(r)) || (!blob && f.walletRefRead(r)) {
			fn(w, r)
			return true
		}
		return false
	})
}

func (f *walletRepairFix) damageHash() {
	f.breakWith(true, func(w http.ResponseWriter, r *http.Request) {
		// a sealed wallet holding a token the session never had, but not the bytes its key names
		w.Write(seal(f.dk, []byte(`{"blind_tokens":[{"msg":"damaged-copy-token","sig":"sig"}]}`)))
	})
}

func (f *walletRepairFix) damageUnopenable() {
	k := postBlob(f.px.URL, []byte("walletrepair: not a sealed blob, but it hashes"))
	putRef(f.px.URL, f.ref, k)
}

func (f *walletRepairFix) damageUnparsable() {
	k := postBlob(f.px.URL, seal(f.dk, []byte("walletrepair: not json")))
	putRef(f.px.URL, f.ref, k)
}

func walletRepairStatus(code int) func(w http.ResponseWriter, r *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(code) }
}

func walletRepairDrop(w http.ResponseWriter, r *http.Request) {
	c, _, err := w.(http.Hijacker).Hijack()
	if err == nil {
		c.Close()
	}
}

// verb drives the daemon handler over a pipe and returns the reply line.
func (f *walletRepairFix) verb(t *testing.T, op string) string {
	t.Helper()
	return walletRepairVerb(t, f.dest, op)
}

func walletRepairVerb(t *testing.T, dest, op string) string {
	t.Helper()
	c1, c2 := net.Pipe()
	go func() {
		handleRepairWallet(c2, dest, op)
		c2.Close()
	}()
	c1.SetReadDeadline(time.Now().Add(60 * time.Second))
	var sb strings.Builder
	buf := make([]byte, 256)
	for {
		n, err := c1.Read(buf)
		sb.Write(buf[:n])
		if err != nil {
			break
		}
	}
	return strings.TrimSpace(sb.String())
}

func (f *walletRepairFix) noProof(t *testing.T) {
	t.Helper()
	if !walletNotRestored(f.wp, walletGeneration(f.wp)) {
		t.Fatal("the generation has a restore proof")
	}
	m, _ := filepath.Glob(filepath.Join(f.dest, "wallet.json.landed-*"))
	if len(m) != 0 {
		t.Fatalf("restore proof files exist: %v", m)
	}
}

func walletRepairWant(t *testing.T, got, want string) {
	t.Helper()
	if got != want {
		t.Fatalf("reply %q, want %q", got, want)
	}
}

func TestStrictWallet_TypedDamage(t *testing.T) {
	f := walletRepairSetup(t, "walletrepair-typed")
	read := func() error { _, _, err := readStoredWalletStrict(f.px.URL, f.name, f.pass, f.dk); return err }
	if err := read(); err != nil {
		t.Fatalf("healthy fixture: %v", err)
	}
	f.damageHash()
	err := read()
	if !errors.Is(err, errWalletBlobDamaged) || !walletDamage(err) {
		t.Fatalf("hash mismatch: %v", err)
	}
	f.set(nil)
	f.damageUnopenable()
	err = read()
	if !errors.Is(err, errWalletUnopenable) || !walletDamage(err) {
		t.Fatalf("unopenable: %v", err)
	}
	if err.Error() != "the stored wallet does not open with this profile's key" {
		t.Fatalf("unopenable text changed: %q", err)
	}
	f.damageUnparsable()
	err = read()
	if !errors.Is(err, errWalletUnparsable) || !walletDamage(err) {
		t.Fatalf("unparsable: %v", err)
	}
	if err.Error() != "the stored wallet does not parse" {
		t.Fatalf("unparsable text changed: %q", err)
	}
	// no key: untyped
	_, _, err = readStoredWalletStrict(f.px.URL, f.name, f.pass, nil)
	if err == nil || walletDamage(err) {
		t.Fatalf("dk nil must be an untyped failure, got %v", err)
	}
	// 403 and 500
	for _, code := range []int{403, 500} {
		f.breakWith(true, walletRepairStatus(code))
		f.set(func(w http.ResponseWriter, r *http.Request) bool {
			if f.walletRefRead(r) {
				w.WriteHeader(code)
				return true
			}
			return false
		})
		if err := read(); err == nil || walletDamage(err) {
			t.Fatalf("status %d must not be damage, got %v", code, err)
		}
	}
}

func TestWalletRepair_HashMismatchRepairsAndPublishesTheSessionTokens(t *testing.T) {
	f := walletRepairSetup(t, "walletrepair-hash")
	f.damageHash()
	if _, err := sealWallet(f.px.URL, f.name, f.pass, f.dk, f.wp); !errors.Is(err, errWalletNotRestored) {
		t.Fatalf("before the repair a publish must be refused, got %v", err)
	}
	walletRepairWant(t, f.verb(t, "CHECK"), "DAMAGED")
	f.noProof(t)
	gen := walletGeneration(f.wp)
	out := captureStderr(t, func() { walletRepairWant(t, f.verb(t, "CONFIRM"), "OK REPAIRED") })
	if !walletRestoreLanded(f.wp, gen) {
		t.Fatal("no restore proof after OK REPAIRED")
	}
	if !strings.Contains(out, "REPAIR-WALLET CONFIRM -> OK REPAIRED") {
		t.Fatalf("no verdict line; stderr:\n%s", out)
	}
	// the damaged copy stays in place, decryptable and holding a token the session never had: the publish must not merge it
	if _, err := sealWallet(f.px.URL, f.name, f.pass, f.dk, f.wp); err != nil {
		t.Fatalf("publish after the repair: %v", err)
	}
	f.set(nil) // read the published wallet back honestly
	w, _, err := readStoredWalletStrict(f.px.URL, f.name, f.pass, f.dk)
	if err != nil || w == nil {
		t.Fatalf("read back: %v %v", w, err)
	}
	want := newBlindTokens()
	if len(w.BlindTokens) != len(want) {
		t.Fatalf("published %d tokens, want the session's %d", len(w.BlindTokens), len(want))
	}
	for i := range want {
		if w.BlindTokens[i] != want[i] {
			t.Fatalf("token %d is %v, want %v", i, w.BlindTokens[i], want[i])
		}
	}
}

func TestWalletRepair_UnopenableIsDamaged(t *testing.T) {
	f := walletRepairSetup(t, "walletrepair-unopenable")
	f.damageUnopenable()
	walletRepairWant(t, f.verb(t, "CHECK"), "DAMAGED")
	f.noProof(t)
	gen := walletGeneration(f.wp)
	walletRepairWant(t, f.verb(t, "CONFIRM"), "OK REPAIRED")
	if !walletRestoreLanded(f.wp, gen) {
		t.Fatal("no restore proof")
	}
}

func TestWalletRepair_UnparsableIsDamaged(t *testing.T) {
	f := walletRepairSetup(t, "walletrepair-unparsable")
	f.damageUnparsable()
	walletRepairWant(t, f.verb(t, "CHECK"), "DAMAGED")
	f.noProof(t)
	gen := walletGeneration(f.wp)
	walletRepairWant(t, f.verb(t, "CONFIRM"), "OK REPAIRED")
	if !walletRestoreLanded(f.wp, gen) {
		t.Fatal("no restore proof")
	}
}

func TestWalletRepair_StoreFailuresAreUnknown(t *testing.T) {
	cases := []struct {
		name string
		blob bool
		fn   func(w http.ResponseWriter, r *http.Request)
	}{
		{"403head", false, walletRepairStatus(403)},
		{"500head", false, walletRepairStatus(500)},
		{"403blob", true, walletRepairStatus(403)},
		{"500blob", true, walletRepairStatus(500)},
		{"drophead", false, walletRepairDrop},
		{"dropblob", true, walletRepairDrop},
	}
	oldWait := s3RetryBase
	s3RetryBase = time.Millisecond
	t.Cleanup(func() { s3RetryBase = oldWait })
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := walletRepairSetup(t, "walletrepair-fail-"+c.name)
			f.breakWith(c.blob, c.fn)
			walletRepairWant(t, f.verb(t, "CHECK"), "UNKNOWN")
			walletRepairWant(t, f.verb(t, "CONFIRM"), "REFUSED UNKNOWN")
			f.noProof(t)
		})
	}
}

func TestWalletRepair_HealthyWalletIsOK(t *testing.T) {
	f := walletRepairSetup(t, "walletrepair-healthy")
	walletRepairWant(t, f.verb(t, "CHECK"), "OK")
	walletRepairWant(t, f.verb(t, "CONFIRM"), "REFUSED OK")
	f.noProof(t)
}

func TestWalletRepair_ProofStandingIsOKWithNoRead(t *testing.T) {
	f := walletRepairSetup(t, "walletrepair-proofstanding")
	markWalletRestoreLanded(f.wp, walletGeneration(f.wp))
	f.mu.Lock()
	f.hits = 0
	f.mu.Unlock()
	f.set(func(w http.ResponseWriter, r *http.Request) bool { w.WriteHeader(500); return true })
	walletRepairWant(t, f.verb(t, "CHECK"), "OK")
	if n := f.hitCount(); n != 0 {
		t.Fatalf("a standing proof made %d store requests", n)
	}
}

func TestWalletRepair_GenerationMovedBeforeTheRead(t *testing.T) {
	f := walletRepairSetup(t, "walletrepair-genbefore")
	f.damageUnparsable()
	gen := walletGeneration(f.wp)
	if err := bumpWalletGeneration(f.wp); err != nil {
		t.Fatal(err)
	}
	walletRepairWant(t, repairWalletDamaged(f.wp, gen, f.name, f.pass, nil, true), "REFUSED GEN")
	if walletRestoreLanded(f.wp, gen) || walletRestoreLanded(f.wp, walletGeneration(f.wp)) {
		t.Fatal("a proof was written")
	}
}

func TestWalletRepair_GenerationMovedAfterTheRead(t *testing.T) {
	f := walletRepairSetup(t, "walletrepair-genafter")
	f.damageUnparsable()
	gen := walletGeneration(f.wp)
	repairWalletAfterReadHook = func() { bumpWalletGeneration(f.wp) }
	walletRepairWant(t, f.verb(t, "CONFIRM"), "REFUSED GEN")
	if walletRestoreLanded(f.wp, gen) || walletRestoreLanded(f.wp, walletGeneration(f.wp)) {
		t.Fatal("a proof was written")
	}
}

func TestWalletRepair_Busy(t *testing.T) {
	f := walletRepairSetup(t, "walletrepair-busy")
	f.damageUnparsable()
	old := walletSignInWait
	walletSignInWait = 300 * time.Millisecond
	t.Cleanup(func() { walletSignInWait = old })
	unlock, state := lockWalletWithin(f.wp, time.Second)
	if state != walletLocked {
		t.Fatalf("fixture: could not take the wallet lock (%v)", state)
	}
	defer unlock()
	walletRepairWant(t, f.verb(t, "CONFIRM"), "REFUSED BUSY")
	if walletRestoreLanded(f.wp, walletGeneration(f.wp)) {
		t.Fatal("a proof was written")
	}
}

func TestWalletRepair_NoSession(t *testing.T) {
	f := walletRepairSetup(t, "walletrepair-nosession")
	f.damageUnparsable()
	f.mu.Lock()
	f.hits = 0
	f.mu.Unlock()

	empty := t.TempDir()
	walletRepairWant(t, walletRepairVerb(t, empty, "CONFIRM"), "NONE")

	local := t.TempDir()
	writeRoamSession(local, f.name, f.pass, "11", "", true)
	os.WriteFile(filepath.Join(local, ".localsession"), []byte("1"), 0o600)
	walletRepairWant(t, walletRepairVerb(t, local, "CONFIRM"), "NONE")

	offline := t.TempDir()
	writeRoamSession(offline, f.name, f.pass, "11", "", true)
	markOfflineSession(offline)
	walletRepairWant(t, walletRepairVerb(t, offline, "CONFIRM"), "NONE")

	walletRepairWant(t, f.verb(t, "WIPE"), "ERR")
	walletRepairWant(t, f.verb(t, ""), "ERR")
	f.noProof(t)
	if n := f.hitCount(); n != 0 {
		t.Fatalf("%d store requests", n)
	}
}

func TestWalletRepair_ConfirmLogsTheVerdictOnly(t *testing.T) {
	f := walletRepairSetup(t, "walletrepair-log")
	f.damageUnparsable()
	out := captureStderr(t, func() { walletRepairWant(t, f.verb(t, "CONFIRM"), "OK REPAIRED") })
	if !strings.Contains(out, "REPAIR-WALLET CONFIRM -> OK REPAIRED") {
		t.Fatalf("no verdict line:\n%s", out)
	}
	for _, leak := range []string{f.name, f.ref, f.head, f.pass} {
		if strings.Contains(out, leak) {
			t.Fatalf("the log carries %q:\n%s", leak, out)
		}
	}
}
