package main

import (
	"bufio"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

// Tests for handleFido2NFCAssert, the FIDO2-NFC-ASSERT / FIDO2-NFC-RESUME verbs. Each case pins one of the
// verb's recorded decisions: a PIN resume never probes the store, each verb writes only its own stash, a fresh
// login stages its slot spec, and every no-slot answer is the same bare ERR.

type nfcVerbEnv struct {
	dest   string
	direct string        // store URL for fixtures (uncounted)
	base   string        // the same store behind a request counter
	reqs   *atomic.Int64 // requests the verb made through base
}

func newNFCVerbEnv(t *testing.T) *nfcVerbEnv {
	t.Helper()
	direct := newHTTPStore(t)
	u, err := url.Parse(direct)
	if err != nil {
		t.Fatal(err)
	}
	var n atomic.Int64
	proxy := httputil.NewSingleHostReverseProxy(u)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n.Add(1)
		proxy.ServeHTTP(w, r)
	}))
	t.Cleanup(srv.Close)
	return &nfcVerbEnv{dest: t.TempDir(), direct: direct, base: srv.URL, reqs: &n}
}

var nfcVerbHmac = func() []byte {
	h := make([]byte, fido2HMACLen)
	for i := range h {
		h[i] = byte(i + 1)
	}
	return h
}()

func stubNFCAssert(t *testing.T, h []byte, err error) {
	t.Helper()
	old := nfcAssert
	nfcAssert = func(transceiver, []fido2SlotInfo) ([]byte, error) { return h, err }
	t.Cleanup(func() { nfcAssert = old })
}

// fido2Profile creates a profile with one enrolled fido2 slot and returns that slot.
func (e *nfcVerbEnv) fido2Profile(t *testing.T, name, pass string) fido2SlotInfo {
	t.Helper()
	createVault(e.direct, name, pass)
	salt := make([]byte, 32)
	rand.Read(salt)
	slot := fido2SlotInfo{
		CredID: base64.StdEncoding.EncodeToString([]byte("cred-" + name)),
		Salt:   base64.StdEncoding.EncodeToString(salt),
		UV:     true,
	}
	if err := enrollFido2(e.direct, name, pass, slot.CredID, slot.Salt, hex.EncodeToString(nfcVerbHmac), slot.UV, "", nil); err != nil {
		t.Fatalf("enrollFido2: %v", err)
	}
	e.reqs.Store(0)
	return slot
}

// coldLock writes a .coldlock marker in readColdLock's layout and checks it parses back as intended.
func (e *nfcVerbEnv) coldLock(t *testing.T, name string, keyed, pin bool, slots []fido2SlotInfo) {
	t.Helper()
	key, pn := "nokey", "nopin"
	if keyed {
		key = "fido2"
	}
	if pin {
		pn = "pin"
	}
	marker := strings.Join([]string{name, "10", "se", key, pn, "cGFzc3dyYXA=", encodeSlotSpec(slots)}, "\n") + "\n"
	if err := os.WriteFile(filepath.Join(e.dest, ".coldlock"), []byte(marker), 0o600); err != nil {
		t.Fatal(err)
	}
	gn, _, _, gk, gp, _ := readColdLock(e.dest)
	if gn != name || gk != keyed || gp != pin {
		t.Fatalf("marker parsed as name=%q keyed=%v pin=%v", gn, gk, gp)
	}
	if got := len(parseSlotSpec(coldLockSlots(e.dest))); got != len(slots) {
		t.Fatalf("marker lists %d slots, want %d", got, len(slots))
	}
}

// run drives one verb over a pipe and returns the reply line.
func (e *nfcVerbEnv) run(t *testing.T, verb, name, secret string) string {
	t.Helper()
	srv, cli := net.Pipe()
	defer cli.Close()
	done := make(chan struct{})
	go func() {
		defer close(done)
		defer srv.Close()
		handleFido2NFCAssert(srv, bufio.NewReader(srv), e.dest, e.base, verb)
	}()
	if _, err := cli.Write([]byte(name + "\n" + secret + "\n")); err != nil {
		t.Fatal(err)
	}
	reply, _ := bufio.NewReader(cli).ReadString('\n')
	<-done
	return reply
}

func (e *nfcVerbEnv) has(name string) bool {
	_, err := os.Stat(filepath.Join(e.dest, name))
	return err == nil
}

func (e *nfcVerbEnv) wantStash(t *testing.T, file string) {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(e.dest, file))
	if err != nil || string(b) != hex.EncodeToString(nfcVerbHmac) {
		t.Fatalf("%s = %q, %v; want the asserted hmac", file, b, err)
	}
}

func TestNFCResumeUsesMarkerSlotsWithoutTheStore(t *testing.T) {
	e := newNFCVerbEnv(t)
	stubNFCAssert(t, nfcVerbHmac, nil)
	e.coldLock(t, "alice", true, true, []fido2SlotInfo{{CredID: "Y3JlZA==", Salt: "c2FsdA==", UV: true}})
	if got := e.run(t, "FIDO2-NFC-RESUME", "alice", "1234"); got != "OK\n" {
		t.Fatalf("reply %q, want OK", got)
	}
	e.wantStash(t, ".fido2hmac.resume")
	if e.has(".fido2hmac.pre") {
		t.Fatal("a resume wrote the login stash .fido2hmac.pre")
	}
	if n := e.reqs.Load(); n != 0 {
		t.Fatalf("a resume with marker slots made %d store requests", n)
	}
}

func TestNFCResumePINWithoutSlotsNeverProbesTheStore(t *testing.T) {
	e := newNFCVerbEnv(t)
	stubNFCAssert(t, nfcVerbHmac, nil)
	e.coldLock(t, "alice", true, true, nil)
	if got := e.run(t, "FIDO2-NFC-RESUME", "alice", "1234"); got != "ERR\n" {
		t.Fatalf("reply %q, want ERR", got)
	}
	if n := e.reqs.Load(); n != 0 {
		t.Fatalf("a PIN resume sent %d requests to the store: refs derived from a PIN are offline-exhaustible", n)
	}
	if e.has(".fido2hmac.resume") || e.has(".fido2hmac.pre") {
		t.Fatal("a refused resume wrote a stash")
	}
}

// NWP-20261017-03: a keyed no-PIN marker with no slot spec no longer falls back to resolving the head with the
// typed secret -- that secret is unproven here, so the lookup would send refs derived from a stranger's guess to
// the gateway. Even the right passphrase answers ERR, with no store request and no stash.
func TestNFCResumeKeyedNoPINWithoutSlotsNeverProbesTheStore(t *testing.T) {
	e := newNFCVerbEnv(t)
	stubNFCAssert(t, nfcVerbHmac, nil)
	e.fido2Profile(t, "alice", "correct horse battery")
	e.coldLock(t, "alice", true, false, nil)
	if got := e.run(t, "FIDO2-NFC-RESUME", "alice", "correct horse battery"); got != "ERR\n" {
		t.Fatalf("reply %q, want ERR", got)
	}
	if n := e.reqs.Load(); n != 0 {
		t.Fatalf("a keyed no-PIN resume with no marker slots made %d store requests", n)
	}
	if e.has(".fido2hmac.resume") || e.has(".fido2hmac.pre") {
		t.Fatal("a refused resume wrote a stash")
	}
}

func TestNFCResumeWithoutMarkerIsERR(t *testing.T) {
	e := newNFCVerbEnv(t)
	stubNFCAssert(t, nfcVerbHmac, nil)
	if got := e.run(t, "FIDO2-NFC-RESUME", "alice", "secret"); got != "ERR\n" {
		t.Fatalf("reply %q, want ERR", got)
	}
	if e.reqs.Load() != 0 || e.has(".fido2hmac.resume") {
		t.Fatal("a markerless resume touched the store or wrote a stash")
	}
}

func TestNFCAssertNoSlotAnswersAreIdentical(t *testing.T) {
	e := newNFCVerbEnv(t)
	stubNFCAssert(t, nfcVerbHmac, nil)
	e.fido2Profile(t, "alice", "correct horse battery")
	createVault(e.direct, "plain", "plain passphrase") // a profile with no fido2 slot
	for _, c := range []struct{ what, name, pass string }{
		{"wrong passphrase", "alice", "wrong passphrase"},
		{"unknown name", "nobody", "correct horse battery"},
		{"non-fido2 profile", "plain", "plain passphrase"},
	} {
		if got := e.run(t, "FIDO2-NFC-ASSERT", c.name, c.pass); got != "ERR\n" {
			t.Fatalf("%s: reply %q, want the bare ERR", c.what, got)
		}
		for _, f := range []string{".fido2hmac.pre", ".fido2hmac.resume", ".fido2slots.pre"} {
			if e.has(f) {
				t.Fatalf("%s: wrote %s", c.what, f)
			}
		}
	}
}

func TestNFCAssertFreshLoginStashesHmacAndSlotSpec(t *testing.T) {
	e := newNFCVerbEnv(t)
	stubNFCAssert(t, nfcVerbHmac, nil)
	slot := e.fido2Profile(t, "alice", "correct horse battery")
	if got := e.run(t, "FIDO2-NFC-ASSERT", "alice", "correct horse battery"); got != "OK\n" {
		t.Fatalf("reply %q, want OK", got)
	}
	e.wantStash(t, ".fido2hmac.pre")
	if e.has(".fido2hmac.resume") {
		t.Fatal("a login wrote the resume stash")
	}
	b, err := os.ReadFile(filepath.Join(e.dest, ".fido2slots.pre"))
	if err != nil {
		t.Fatalf("the login did not stage its slot spec: %v", err)
	}
	got := parseSlotSpec(string(b))
	if len(got) != 1 || got[0].CredID != slot.CredID || got[0].Salt != slot.Salt || got[0].UV != slot.UV {
		t.Fatalf("staged spec %q does not match the enrolled slot", b)
	}
}

func TestNFCAssertErrorWritesNoHmacStash(t *testing.T) {
	stubNFCAssert(t, nil, errors.New("tag lost"))
	for _, verb := range []string{"FIDO2-NFC-ASSERT", "FIDO2-NFC-RESUME"} {
		e := newNFCVerbEnv(t)
		e.fido2Profile(t, "alice", "correct horse battery")
		e.coldLock(t, "alice", true, false, []fido2SlotInfo{{CredID: "Y3JlZA==", Salt: "c2FsdA=="}})
		if got := e.run(t, verb, "alice", "correct horse battery"); got != "ERR\n" {
			t.Fatalf("%s: reply %q, want ERR", verb, got)
		}
		if e.has(".fido2hmac.pre") || e.has(".fido2hmac.resume") {
			t.Fatalf("%s: a failed assertion left an hmac stash", verb)
		}
		if verb == "FIDO2-NFC-ASSERT" && !e.has(".fido2slots.pre") {
			t.Fatal("ASSERT stages its slot spec before asserting, as it does today")
		}
	}
}
