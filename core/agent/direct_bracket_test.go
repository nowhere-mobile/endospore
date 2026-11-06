package main

import (
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/minio/minio-go/v7"
)

// NWP-20261029-02: on a self-hosted store the wallet publishes and the legacy LOGOFF's pushSet wrote with no
// bracket, so a refusal they met (sealFenceHit / the stale flag) could be snapshotted by another open bracket's
// capEnd. Each now runs in a bracket of its own: with one open, it WAITS for capBracketMu.

// directBracketEnv puts the test in direct mode with the bracket trace reset, and checks at the end that no
// bracket was leaked. It registers the leak check first, so it runs after the held bracket has been released.
func directBracketEnv(t *testing.T) {
	t.Helper()
	t.Setenv("GATEWAY_URL", "")
	capBracketTrace = nil
	t.Cleanup(func() { capBracketTrace = nil })
	t.Cleanup(func() { capBracketLeakCheck(t) })
}

// directBracketWallet writes a wallet holding tokens at a fresh path and proves its generation.
func directBracketWallet(t *testing.T) string {
	t.Helper()
	wp := filepath.Join(t.TempDir(), "wallet.json")
	if err := appendTokens(wp, newBlindTokens()); err != nil {
		t.Fatal(err)
	}
	if err := markWalletRestoreLanded(wp, walletGeneration(wp)); err != nil {
		t.Fatal(err)
	}
	return wp
}

// directBracketHold opens bracket A and holds it until release (or the test's end). It returns once A is
// inside fn. A's verdict is written to *v before done is closed.
func directBracketHold(t *testing.T, name, pass string) (release func(), v *capVerdict, done <-chan struct{}) {
	t.Helper()
	inside, rel, fin := make(chan struct{}), make(chan struct{}), make(chan struct{})
	enter, release := closer(inside), closer(rel)
	v = new(capVerdict)
	go func() {
		defer close(fin)
		defer enter()
		*v = capWrite(name, pass, nil, func() {
			enter()
			<-rel
		})
	}()
	t.Cleanup(func() {
		release()
		select {
		case <-fin:
		case <-time.After(10 * time.Second):
			t.Error("bracket A did not end after its release")
		}
	})
	select {
	case <-inside:
	case <-time.After(10 * time.Second):
		t.Fatal("bracket A never opened")
	}
	return release, v, fin
}

// directBracketOrdered reports whether the writer waited on the open bracket before it finished. When it did
// not, the test records it and returns false; the caller then releases A as usual.
func directBracketOrdered(t *testing.T, writer string, waits, done <-chan struct{}) bool {
	t.Helper()
	select {
	case <-waits:
		return true
	case <-done:
		t.Errorf("%s ran while bracket A was open: it never waited on capBracketMu (NWP-20261029-02)", writer)
		return false
	case <-time.After(10 * time.Second):
		t.Error(writer + " neither waited on bracket A nor finished within 10 s")
		return false
	}
}

func directBracketJoin(t *testing.T, what string, done <-chan struct{}) {
	t.Helper()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatalf("%s did not finish after bracket A was released", what)
	}
}

func TestDirectSealWallet_WaitsForOpenBracket(t *testing.T) {
	directBracketEnv(t)
	base := newHTTPStore(t)
	const name, pass = "dbrsw", "pass of dbrsw"
	wp := directBracketWallet(t)
	release, _, _ := directBracketHold(t, "dbrsw-a", "pass of dbrsw a")
	waits := bracketWaits()
	var h string
	var err error
	done := make(chan struct{})
	go func() {
		defer close(done)
		h, err = sealWallet(base, name, pass, deriveKey(name, pass), wp)
	}()
	directBracketOrdered(t, "sealWallet", waits, done)
	release()
	directBracketJoin(t, "sealWallet", done)
	if err != nil || h == "" {
		t.Fatalf("sealWallet = %q, %v", h, err)
	}
	if getRef(base, profileRefV2(name+"#wallet", pass)) == "" {
		t.Error("the #wallet head was not published")
	}
}

func TestDirectSealWalletValueDurable_WaitsForOpenBracket(t *testing.T) {
	directBracketEnv(t)
	base := newHTTPStore(t)
	const name, pass = "dbrvd", "pass of dbrvd"
	wp := directBracketWallet(t)
	basis, err := os.ReadFile(wp)
	if err != nil {
		t.Fatal(err)
	}
	w, err := loadWallet(wp)
	if err != nil {
		t.Fatal(err)
	}
	gen := walletGeneration(wp)
	release, _, _ := directBracketHold(t, "dbrvd-a", "pass of dbrvd a")
	waits := bracketWaits()
	var h string
	var werr error
	done := make(chan struct{})
	go func() {
		defer close(done)
		h, werr = sealWalletValueDurable(base, name, pass, deriveKey(name, pass), wp, w, basis, gen, true)
	}()
	directBracketOrdered(t, "sealWalletValueDurable", waits, done)
	release()
	directBracketJoin(t, "sealWalletValueDurable", done)
	if werr != nil || h == "" {
		t.Fatalf("sealWalletValueDurable = %q, %v", h, werr)
	}
	if getRef(base, profileRefV2(name+"#wallet", pass)) == "" {
		t.Error("the #wallet head was not published")
	}
}

func TestDirectLegacyLogoff_WaitsForOpenBracket(t *testing.T) {
	directBracketEnv(t)
	const name, pass = "dbrlo", "pass of dbrlo"
	dest := t.TempDir()
	if err := os.WriteFile(filepath.Join(dest, ".session"), []byte(name+"\n"+pass+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if why := sessionInPlay(dest); why != "" {
		t.Fatalf("precondition: a session is in play (%s), so LOGOFF would answer BUSY", why)
	}
	// pushSet goes through s3Init: point it at a server that refuses everything, so nothing leaves the host.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	t.Cleanup(srv.Close)
	u, err := url.Parse(srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("S3_ENDPOINT", "http://"+u.Host)
	t.Setenv("S3_BUCKET", "dbrbucket")
	t.Setenv("S3_ACCESS_KEY", "dbr-ak")
	t.Setenv("S3_SECRET_KEY", "dbr-sk")
	oc, orb, omr := s3client, s3RetryBase, minio.MaxRetry
	s3client, s3RetryBase, minio.MaxRetry = nil, time.Millisecond, 1
	t.Cleanup(func() { s3client, s3RetryBase, minio.MaxRetry = oc, orb, omr })

	release, _, _ := directBracketHold(t, "dbrlo-a", "pass of dbrlo a")
	waits := bracketWaits()
	c1, c2 := net.Pipe()
	go func() {
		defer c1.Close()
		handleLogoff(c1, dest)
	}()
	var reply []byte
	done := make(chan struct{})
	go func() {
		defer close(done)
		reply, _ = io.ReadAll(c2)
	}()
	directBracketOrdered(t, "the legacy LOGOFF", waits, done)
	release()
	directBracketJoin(t, "the legacy LOGOFF", done)
	if got := strings.TrimSpace(string(reply)); got != "OK" {
		t.Errorf("LOGOFF answered %q", got)
	}
}

// With a bracket open, a refusal the wallet publish meets is the publish's own, not the open bracket's verdict.
func TestDirectSealWallet_RefusalStaysOutOfAnotherVerdict(t *testing.T) {
	directBracketEnv(t)
	fenceTestEnv(t)
	t.Cleanup(clearStaleHit)
	base := newHTTPStore(t)
	const name, pass = "dbrrf", "pass of dbrrf"
	wp := directBracketWallet(t)
	ref := profileRefV2(name+"#wallet", pass)
	t.Cleanup(func() {
		liftSealFence([]string{ref})
		sealFenceHit = false
		clearSealExpectations()
	})
	if !armSealFence([]string{ref}) {
		t.Fatal("precondition: could not arm the publish fence")
	}
	release, av, aDone := directBracketHold(t, "dbrrf-a", "pass of dbrrf a")
	waits := bracketWaits()
	done := make(chan struct{})
	go func() {
		defer close(done)
		sealWallet(base, name, pass, deriveKey(name, pass), wp)
	}()
	directBracketOrdered(t, "sealWallet", waits, done)
	release()
	directBracketJoin(t, "sealWallet", done)
	directBracketJoin(t, "bracket A", aDone)
	if getRef(base, ref) != "" {
		t.Fatal("precondition: the fenced #wallet head was published, so no refusal happened")
	}
	if av.Refused() {
		t.Errorf("bracket A's verdict carries sealWallet's refusal: %+v (NWP-20261029-02)", *av)
	}
}
