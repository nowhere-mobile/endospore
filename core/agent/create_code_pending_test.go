package main

import (
	"bytes"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"
)

// NWP-20261207-01 (h53 #6 slice 2, the create half; decided 2026-11-02 and 2026-11-03, h55 #1): CREATE-CODE does not
// redeem its code. It stages the code as a pending claim beside the create, and the create publishes it with the new
// profile's wallet; a later session drains it at a randomised moment (NOWHERE-1748). No request the create sends
// carries the code, so the store never sees an identified purchase joined to a new profileRefV2 seconds later.

const (
	ccpPaid    = "ccpPaidCode_0123456789-A" // the code createCodeEnv funds
	ccpUnknown = "ccpUnknownCode-98765_Zzz" // well formed, but the fake gateway does not fund it
	ccpPass    = "a passphrase for the create-code pending case"
)

// ccpReq is one request the spy saw: everything a request can carry the code in.
type ccpReq struct {
	method, path, query string
	headers             []string
	body                []byte
}

// ccpSpy is clSpy with the whole request recorded: method, path, raw query, every header value and the full body.
func ccpSpy(t *testing.T) func() []ccpReq {
	t.Helper()
	target, err := url.Parse(os.Getenv("GATEWAY_URL"))
	if err != nil || target.Host == "" {
		t.Fatalf("no gateway to spy on: %v", err)
	}
	var mu sync.Mutex
	var seen []ccpReq
	rp := httputil.NewSingleHostReverseProxy(target)
	spy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		r.Body = io.NopCloser(bytes.NewReader(b))
		r.ContentLength = int64(len(b))
		rec := ccpReq{method: r.Method, path: r.URL.Path, query: r.URL.RawQuery, body: b}
		for k, vs := range r.Header {
			for _, v := range vs {
				rec.headers = append(rec.headers, k+": "+v)
			}
		}
		mu.Lock()
		seen = append(seen, rec)
		mu.Unlock()
		rp.ServeHTTP(w, r)
	}))
	t.Cleanup(spy.Close)
	t.Setenv("GATEWAY_URL", spy.URL)
	capReadCache = map[string]capEntry{}
	return func() []ccpReq {
		mu.Lock()
		defer mu.Unlock()
		return append([]ccpReq(nil), seen...)
	}
}

// ccpCarries reports whether r carries code anywhere: its path, its query, a header value or its body.
func ccpCarries(r ccpReq, code string) bool {
	if strings.Contains(r.path, code) || strings.Contains(r.query, code) || bytes.Contains(r.body, []byte(code)) {
		return true
	}
	for _, h := range r.headers {
		if strings.Contains(h, code) {
			return true
		}
	}
	return false
}

func ccpIsClaimPath(p string) bool {
	return strings.HasPrefix(p, "/issue") || strings.HasPrefix(p, "/claim")
}

func ccpCreateCode(dest, name, code string) string {
	return verb(func(c net.Conn) { handleCreateCode(c, dest, name, ccpPass, code) })
}

// The row's own pin: the create sends no /issue or /claim request, and no request carries the code.
func TestCreateCodePending_NoRequestCarriesTheCode(t *testing.T) {
	const name = "ccp-a"
	dest, _ := createCodeEnv(t, ccpPaid, 3)
	seen := ccpSpy(t)
	blobCache, contentCache = nil, nil
	if got := ccpCreateCode(dest, name, ccpPaid); !strings.HasPrefix(got, "OK 0 RECOVERY ") {
		t.Fatalf("CREATE-CODE replied %q, want OK 0 RECOVERY ...", got)
	}
	reqs := seen()
	if len(reqs) == 0 {
		t.Fatal("control: the create sent no request at all -- the spy is not in front of the store")
	}
	for _, r := range reqs {
		if ccpIsClaimPath(r.path) {
			t.Errorf("the create sent %s %s: the code was redeemed at the create (h53 #6)", r.method, r.path)
		}
		if ccpCarries(r, ccpPaid) {
			t.Errorf("the create's %s %s carries the code in its path, query, headers or body", r.method, r.path)
		}
	}
}

// The new profile's head carries the code as a pending claim and no tokens; the staging is gone, and wallet.json,
// which is somebody else's at the gate, is byte for byte as it was. A cold-lock marker of a gone user makes the
// create's wipe keep wallet.json (wipeAfterCreate), so the file the create must not touch is still there to compare.
func TestCreateCodePending_TheHeadCarriesTheCode(t *testing.T) {
	const name = "ccp-b"
	dest, wpath := createCodeEnv(t, ccpPaid, 3)
	useTempUsersDir(t) // user 0 only: the marker's user 12 is gone, so the create is not refused
	parkColdLock(t, dest)
	fundWallet(t, wpath, 2) // the departed session's leftovers
	before, _ := os.ReadFile(wpath)
	gen := walletGeneration(wpath)
	blobCache, contentCache = nil, nil
	if got := ccpCreateCode(dest, name, ccpPaid); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("CREATE-CODE replied %q", got)
	}
	sw := storedWallet(t, name, ccpPass)
	if sw == nil {
		t.Fatal("the new profile has no published wallet")
	}
	if !slices.Equal(sw.PendingClaims, []string{ccpPaid}) {
		t.Errorf("the new profile's head holds %d pending code(s), want exactly the create's code", len(sw.PendingClaims))
	}
	if sw.balance() != 0 || len(sw.BlindTokens) != 0 {
		t.Errorf("the new profile's head holds %d token(s), %d blind: the code was redeemed at the create", sw.balance(), len(sw.BlindTokens))
	}
	if _, err := os.Stat(createStagingPath(name, ccpPass)); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("the staged claim outlived the create that published it (stat err %v)", err)
	}
	if after, err := os.ReadFile(wpath); err != nil || !bytes.Equal(after, before) {
		t.Errorf("the create changed wallet.json, which is somebody else's (err %v)", err)
	}
	if walletGeneration(wpath) != gen {
		t.Error("the create bumped wallet.json's generation")
	}
}

// A later session drains the published code: the drain adds the claim's tokens and clears the entry, and its /issue
// is the first request carrying the code, after every request the create sent.
func TestCreateCodePending_TheLaterDrainSpendsIt(t *testing.T) {
	const name = "ccp-c"
	dest, wpath := createCodeEnv(t, ccpPaid, 3)
	seen := ccpSpy(t)
	blobCache, contentCache = nil, nil
	if got := ccpCreateCode(dest, name, ccpPaid); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("CREATE-CODE replied %q", got)
	}
	k := len(seen())
	sw := storedWallet(t, name, ccpPass)
	if sw == nil || !slices.Equal(sw.PendingClaims, []string{ccpPaid}) {
		t.Fatal("the new profile's head does not carry the code as a pending claim")
	}
	if err := saveWallet(wpath, sw); err != nil { // the later session's restore
		t.Fatal(err)
	}
	n, err := drainPendingClaims(newGatewayClient(os.Getenv("GATEWAY_URL"), gwDefault), wpath)
	if err != nil || n != 3 {
		t.Fatalf("the later drain = (%d, %v), want (3, nil)", n, err)
	}
	w, err := loadWallet(wpath)
	if err != nil {
		t.Fatal(err)
	}
	if len(w.PendingClaims) != 0 || len(w.BlindTokens) != 3 {
		t.Errorf("after the drain the wallet holds %d pending code(s) and %d token(s), want 0 and 3", len(w.PendingClaims), len(w.BlindTokens))
	}
	first := -1
	for i, r := range seen() {
		if strings.HasPrefix(r.path, "/issue") {
			first = i
			break
		}
	}
	if first < 0 {
		t.Fatal("the drain sent no /issue")
	}
	if first < k {
		t.Errorf("the first /issue is request %d, before the create's last request %d", first, k-1)
	}
}

// h55 #1: a well-formed code the gateway does not know creates a free profile; the code waits in its head for the
// later drain, which clears it (NOWHERE-1748's rule, not re-tested here).
func TestCreateCodePending_UnknownCodeCreatesFree(t *testing.T) {
	const name = "ccp-d"
	dest, _ := createCodeEnv(t, ccpPaid, 3)
	seen := ccpSpy(t)
	blobCache, contentCache = nil, nil
	if got := ccpCreateCode(dest, name, ccpUnknown); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("CREATE-CODE with a well-formed unknown code replied %q, want OK (h55 #1)", got)
	}
	for _, r := range seen() {
		if strings.HasPrefix(r.path, "/issue") {
			t.Errorf("the create sent %s %s", r.method, r.path)
		}
	}
	sw := storedWallet(t, name, ccpPass)
	if sw == nil || !slices.Equal(sw.PendingClaims, []string{ccpUnknown}) || sw.balance() != 0 {
		t.Fatal("the free profile's head does not carry the unknown code alone as a pending claim")
	}
}

// A staging wallet busy past walletSignInWait: ERR-BUSY, and nothing is created.
func TestCreateCodePending_BusyStagingCreatesNothing(t *testing.T) {
	const name = "ccp-e"
	old := walletSignInWait
	walletSignInWait = 300 * time.Millisecond
	t.Cleanup(func() { walletSignInWait = old })
	dest, _ := createCodeEnv(t, ccpPaid, 3)
	blobCache, contentCache = nil, nil
	unlock := lockWallet(createStagingPath(name, ccpPass))
	got := ccpCreateCode(dest, name, ccpPaid)
	unlock()
	if got != "ERR-BUSY" {
		t.Errorf("CREATE-CODE against a busy staging wallet replied %q, want ERR-BUSY", got)
	}
	if ref := getRef("s3", headKey("s3", name, ccpPass)); ref != "" {
		t.Error("a CREATE-CODE refused as busy created the profile")
	}
}

// A create whose flush is refused keeps the code staged; the retry with the same code creates, and the head holds the
// code once.
func TestCreateCodePending_FailedCreateKeepsItForTheRetry(t *testing.T) {
	const name = "ccp-f"
	dest, _ := createCodeEnv(t, ccpPaid, 3)
	t.Cleanup(func() { capStoreLeaseStatus = nil })
	blobCache, contentCache = nil, nil
	refuseLeasesOf(name, ccpPass, http.StatusInternalServerError)
	if got := ccpCreateCode(dest, name, ccpPaid); got != "BLANK STAGED" && got != "NOCREDIT STAGED" {
		t.Fatalf("the refused create replied %q, want BLANK STAGED or NOCREDIT STAGED", got)
	}
	staged := createStagingPath(name, ccpPass)
	if w, err := loadWallet(staged); err != nil || !slices.Equal(w.PendingClaims, []string{ccpPaid}) {
		t.Fatalf("after the failed create the code is not staged (err %v)", err)
	}
	capStoreLeaseStatus = nil
	if got := ccpCreateCode(dest, name, ccpPaid); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("the retry replied %q", got)
	}
	if sw := storedWallet(t, name, ccpPass); sw == nil || !slices.Equal(sw.PendingClaims, []string{ccpPaid}) {
		t.Error("after the retry the head does not hold the code exactly once")
	}
	if _, err := os.Stat(staged); !errors.Is(err, os.ErrNotExist) {
		t.Error("the staged claim outlived the create that published it")
	}
}
