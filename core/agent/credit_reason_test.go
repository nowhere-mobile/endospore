package main

import (
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20260904-09: the gateway's 402 REASON is read, bounded, and carried into the seal verdict and the log.
// Before this, postJSON closed every non-2xx body unread, so `insufficient valid tokens`, `free quota
// exceeded` and `no live lease for ref` all reached the device as the same bare 402.

// gatewayReasonOK checks the bound gatewayReason promises: at most gatewayReasonMax bytes, printable ASCII
// only, no newline, no double quote (the issue reporter redacts every quoted token in a log line as a name).
func gatewayReasonOK(t *testing.T, reason string) {
	t.Helper()
	if len(reason) > gatewayReasonMax {
		t.Fatalf("reason is %d bytes, bound is %d", len(reason), gatewayReasonMax)
	}
	for i := 0; i < len(reason); i++ {
		if c := reason[i]; c < 0x20 || c > 0x7e || c == '"' {
			t.Fatalf("reason byte %d = %#x is not sanitised: %q", i, c, reason)
		}
	}
}

// TestPostJSONReasonBounded: every non-2xx keeps a bounded, sanitised reason -- the gateway's httpErr JSON
// unwrapped, plain text taken verbatim, a hostile body cut to 200 printable bytes -- and a 200 is untouched.
func TestPostJSONReasonBounded(t *testing.T) {
	var status int
	var body []byte
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(status)
		w.Write(body)
	}))
	t.Cleanup(srv.Close)
	gw := newGatewayClient(srv.URL, gwDefault)

	// The gateway's own shape (httpErr in nowhere-cloud): {"error": msg}.
	status, body = http.StatusPaymentRequired, []byte("{\"error\":\"free quota exceeded\"}\n")
	code, reason, err := gw.postJSONReason("/lease", map[string]any{}, nil)
	if err != nil || code != http.StatusPaymentRequired {
		t.Fatalf("402 JSON: code=%d err=%v", code, err)
	}
	if reason != "free quota exceeded" {
		t.Fatalf("402 JSON: reason %q, want the unwrapped error", reason)
	}

	// A body that is not ours (a proxy's plain-text 502) is taken verbatim, trimmed.
	status, body = http.StatusBadGateway, []byte("bad gateway\r\n")
	if _, reason, _ = gw.postJSONReason("/lease", nil, nil); reason != "bad gateway" {
		t.Fatalf("502 text: reason %q", reason)
	}

	// 10 KB of newlines, control bytes, quotes and UTF-8: bounded to 200 printable bytes, single line.
	big := make([]byte, 10*1024)
	for i := range big {
		switch i % 9 {
		case 0:
			big[i] = '\n'
		case 1:
			big[i] = 0x01
		case 2:
			big[i] = '"'
		case 3:
			big[i] = 0xc3 // a UTF-8 lead byte
		case 4:
			big[i] = '\t'
		default:
			big[i] = byte('a' + i%26)
		}
	}
	status, body = http.StatusPaymentRequired, big
	code, reason, err = gw.postJSONReason("/lease", nil, nil)
	if err != nil || code != http.StatusPaymentRequired {
		t.Fatalf("402 hostile: code=%d err=%v", code, err)
	}
	if reason == "" {
		t.Fatal("402 hostile: the body was not read at all")
	}
	if len(reason) != gatewayReasonMax {
		t.Fatalf("402 hostile: %d bytes kept, want exactly the %d-byte bound from a 10 KB body", len(reason), gatewayReasonMax)
	}
	gatewayReasonOK(t, reason)
	if !strings.Contains(reason, "?") {
		t.Fatalf("402 hostile: control bytes were not replaced by '?': %q", reason)
	}
	if strings.ContainsAny(reason, "\n\t\"") {
		t.Fatalf("402 hostile: newline/tab/quote survived: %q", reason)
	}

	// 200 is unaffected: the body is decoded into out and there is no reason.
	var li leaseInfo
	status, body = http.StatusOK, []byte("{\"through_epoch\":7,\"spent\":1}")
	code, reason, err = gw.postJSONReason("/lease", nil, &li)
	if err != nil || code != http.StatusOK || reason != "" {
		t.Fatalf("200: code=%d reason=%q err=%v", code, reason, err)
	}
	if li.ThroughEpoch != 7 || li.Spent != 1 {
		t.Fatalf("200: body not decoded: %+v", li)
	}

	// The lease calls carry it in leaseInfo.Reason, where the status-branching callers can read it.
	status, body = http.StatusPaymentRequired, []byte("{\"error\":\"no live lease for ref\"}")
	info, code, err := gw.leaseFree("p", map[string]int64{"blob/x": 1}, nil)
	if err != nil || code != http.StatusPaymentRequired || info.Reason != "no live lease for ref" {
		t.Fatalf("leaseFree: code=%d reason=%q err=%v", code, info.Reason, err)
	}
	// And the status-only wrapper still works for everyone else.
	if code, err := gw.postJSON("/tokens", nil, nil); err != nil || code != http.StatusPaymentRequired {
		t.Fatalf("postJSON: code=%d err=%v", code, err)
	}
}

// TestCreditRefusedWrapsSentinel: the wrapped error keeps errors.Is(err, errInsufficientCredit) true at every
// recovery site, says the reason, and gives it back through creditReason; an empty reason is the bare sentinel.
func TestCreditRefusedWrapsSentinel(t *testing.T) {
	err := creditRefused("insufficient valid tokens")
	if !errors.Is(err, errInsufficientCredit) {
		t.Fatalf("errors.Is must hold through the wrap: %v", err)
	}
	if !strings.Contains(err.Error(), "insufficient valid tokens") || !strings.Contains(err.Error(), errInsufficientCredit.Error()) {
		t.Fatalf("message must carry both the sentinel and the reason: %q", err.Error())
	}
	if strings.Contains(err.Error(), "\"") {
		t.Fatalf("the reason must not be quoted in the message -- the reporter redacts quoted tokens as names: %q", err.Error())
	}
	if got := creditReason(err); got != "insufficient valid tokens" {
		t.Fatalf("creditReason = %q", got)
	}
	if creditRefused("") != errInsufficientCredit {
		t.Fatal("an empty reason must be the bare sentinel")
	}
	if creditReason(errors.New("other")) != "" || creditReason(errInsufficientCredit) != "" {
		t.Fatal("creditReason must be empty for anything but a creditRefusal")
	}
}

// TestCapFlushNoCreditCarriesReason: the whole path. A spy gateway refuses the lease with the gateway's own
// 402 body; capFlush panics errInsufficientCredit WRAPPED with that reason (so every errors.Is site still
// fires); main's recover stashes it through the tmpfs state dir; the daemon's recordSeal keeps the verdict
// "nocredit" unchanged and adds the reason, which SEAL-DELTA renders as `reason` and the log line appends.
func TestCapFlushNoCreditCarriesReason(t *testing.T) {
	// The seal verdict is package-global state; leave it as found so a later test that reads a fresh daemon's
	// verdict does not inherit this one's "nocredit" (review of NWP-20260904-09).
	t.Cleanup(resetSealStatus)
	mux := http.NewServeMux()
	mux.HandleFunc("/cap", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(capResp{URL: "http://" + r.Host + "/obj?k=" + url.QueryEscape(r.URL.Query().Get("ref"))})
	})
	mux.HandleFunc("GET /quote", func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(quoteInfo{Denom: "1GBmo", GBPerToken: 1, EpochSeconds: 604800, EpochsPerLease: 4, CurrentEpoch: 42})
	})
	mux.HandleFunc("POST /lease", func(w http.ResponseWriter, r *http.Request) {
		io.Copy(io.Discard, r.Body)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusPaymentRequired)
		json.NewEncoder(w).Encode(map[string]string{"error": "free quota exceeded"}) // httpErr's shape
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	t.Setenv("NOWHERE_STATE", "")
	capReadCache = map[string]capEntry{}
	blobCache = nil
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)
	if err := saveWallet(wpath, &Wallet{}); err != nil {
		t.Fatal(err)
	}

	name, pass := "whyu", "free quota blown with a reason"
	bn := capBegin()
	capSetSession(name, pass, deriveKey(name, pass))
	postBlob("s3", []byte("data over the free quota"))
	putRef("s3", profileRefV2(name, pass), "deadbeef")
	var got any
	func() {
		defer func() { got = recover() }()
		capFlush(bn)
	}()
	e, _ := got.(error)
	if e == nil || !errors.Is(e, errInsufficientCredit) {
		t.Fatalf("over-quota flush must still panic errInsufficientCredit (errors.Is), got %v", got)
	}
	if !strings.Contains(e.Error(), "free quota exceeded") {
		t.Fatalf("the panic must carry the gateway's reason: %v", e)
	}
	if creditReason(e) != "free quota exceeded" {
		t.Fatalf("creditReason = %q", creditReason(e))
	}

	// main's recover: the exit code roamd maps to ERR-NOCREDIT is unchanged, and the reason is stashed for
	// the daemon through the tmpfs state dir. Then the daemon side. The session's placement reset comes
	// FIRST, as it does on device: resetSealStatus is the login boundary and clears any stash, so it must
	// never sit between a seal's exit and that seal's verdict.
	st := t.TempDir()
	t.Setenv("NOWHERE_STATE", st)
	resetSealStatus()
	if code := exitStatus(e); code != exitNoCredit {
		t.Fatalf("a wrapped refusal must still exit %d, got %d", exitNoCredit, code)
	}
	if b, err := os.ReadFile(filepath.Join(st, creditReasonFile)); err != nil || string(b) != "free quota exceeded\n" {
		t.Fatalf("recover must stash the reason for the daemon (one line per refusing scope): %q err=%v", b, err)
	}
	if exitStatus(errors.New("store unreachable")) != 1 || exitStatus("not an error") != 1 {
		t.Fatal("every other panic must still exit 1")
	}
	recordSeal("ERR-NOCREDIT PARTIAL:apps=refused") // the wire shape roamd writes, untouched
	if sealStatusGet() != "nocredit" {
		t.Fatalf("verdict must stay nocredit, got %q", sealStatusGet())
	}
	if sealReasonGet() != "free quota exceeded" {
		t.Fatalf("recorded reason = %q", sealReasonGet())
	}
	if _, err := os.Stat(filepath.Join(st, creditReasonFile)); !os.IsNotExist(err) {
		t.Fatalf("the stash must be consumed by recordSeal, stat err=%v", err)
	}
	if got := sealVerdictLog("ERR-NOCREDIT PARTIAL:apps=refused"); got != "ERR-NOCREDIT PARTIAL:apps=refused (gateway: free quota exceeded)" {
		t.Fatalf("log line = %q", got)
	}
	if got := sealVerdictLog("OK"); got != "OK" {
		t.Fatalf("an OK verdict must log untouched, got %q", got)
	}

	// SEAL-DELTA renders it as `reason` beside the unchanged verdict.
	dest := t.TempDir()
	if err := os.WriteFile(filepath.Join(dest, ".roamsession"), []byte(name+"\n"+pass+"\n10\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dest, ".offlinesession"), nil, 0o600); err != nil { // local: no store walk
		t.Fatal(err)
	}
	c1, c2 := net.Pipe()
	go func() {
		handleSealDelta(c2, dest)
		c2.Close()
	}()
	raw, err := io.ReadAll(c1)
	if err != nil {
		t.Fatal(err)
	}
	hdr, js, ok := strings.Cut(string(raw), "\n")
	if !ok || !strings.HasPrefix(hdr, "OK ") {
		t.Fatalf("SEAL-DELTA reply: %q", raw)
	}
	var r sealDeltaReply
	if err := json.Unmarshal([]byte(js), &r); err != nil {
		t.Fatalf("SEAL-DELTA JSON: %v: %q", err, js)
	}
	if r.Verdict != "nocredit" || r.Parts != "apps=refused" || r.Reason != "free quota exceeded" {
		t.Fatalf("SEAL-DELTA verdict=%q parts=%q reason=%q", r.Verdict, r.Parts, r.Reason)
	}
	if !strings.Contains(js, "\"reason\":\"free quota exceeded\"") {
		t.Fatalf("SEAL-DELTA must carry the reason under the `reason` key: %s", js)
	}

	// A later verdict without a stash carries no reason, and an OK clears it -- nothing stale survives.
	recordSeal("ERR-NOCREDIT")
	if sealReasonGet() != "" {
		t.Fatalf("a refusal with no stash must not inherit the old reason, got %q", sealReasonGet())
	}
	stashCreditReason("insufficient valid tokens")
	recordSeal("OK")
	if sealReasonGet() != "" || sealStatusGet() != "ok" {
		t.Fatalf("OK must clear the reason: status=%q reason=%q", sealStatusGet(), sealReasonGet())
	}
	if _, err := os.Stat(filepath.Join(st, creditReasonFile)); !os.IsNotExist(err) {
		t.Fatal("the stash must be consumed even when the verdict is not a refusal")
	}
	// The JSON is omitted entirely when there is no reason (omitempty), so an old chooser sees nothing new.
	resetSealStatus()
	recordSeal("ERR-NOCREDIT")
	c1, c2 = net.Pipe()
	go func() {
		handleSealDelta(c2, dest)
		c2.Close()
	}()
	raw, _ = io.ReadAll(c1)
	if strings.Contains(string(raw), "\"reason\"") {
		t.Fatalf("no reason -> no `reason` key: %s", raw)
	}
}

// TestCreditReasonStashLifetime (review of NWP-20260904-09): the stash is ONE seal attempt's record and
// nothing else. roamd runs a seal as several agent processes (vault, #de, #media), so each refusing scope's
// reason is kept and the verdict is joined to all of them, not just the last; the file is emptied when a seal
// attempt takes the worker slot and when a new session is placed (resetSealStatus), so no text crosses an
// attempt or a login; and a FAILED logoff seal records its verdict like every other seal, so a logoff-time
// 402 reaches sealStatus/sealReason and consumes its stash instead of leaving it in the shared tmpfs.
func TestCreditReasonStashLifetime(t *testing.T) {
	st := t.TempDir()
	t.Setenv("NOWHERE_STATE", st)
	t.Cleanup(func() {
		resetSealStatus()
		pendingReapMu.Lock()
		sealInFlight, sealRunKind, sealFail, sealFailWhy = false, "", false, ""
		pendingReapMu.Unlock()
	})
	stashed := func() (string, bool) {
		b, err := os.ReadFile(filepath.Join(st, creditReasonFile))
		return string(b), err == nil
	}

	// Two scopes refuse for different reasons: BOTH are recorded, in order; a repeat adds nothing; a refusal
	// without a body neither erases nor pads what an earlier scope wrote.
	stashCreditReason("free quota exceeded")   // vault
	stashCreditReason("no live lease for ref") // #media
	stashCreditReason("free quota exceeded")   // #de, the same refusal again
	stashCreditReason("")                      // a 402 with no body
	if b, ok := stashed(); !ok || b != "free quota exceeded\nno live lease for ref\n" {
		t.Fatalf("stash must hold each distinct scope reason once, in order: %q ok=%v", b, ok)
	}
	if got := takeCreditReason(); got != "free quota exceeded; no live lease for ref" {
		t.Fatalf("takeCreditReason = %q, want both scopes joined", got)
	}
	if _, ok := stashed(); ok {
		t.Fatal("take must consume the file")
	}
	// The merge keeps the single-reason bound: many distinct long lines still come out as <=gatewayReasonMax
	// printable bytes with no newline.
	for i := 0; i < 5; i++ {
		stashCreditReason(strings.Repeat(string(rune('a'+i)), gatewayReasonMax))
	}
	merged := takeCreditReason()
	gatewayReasonOK(t, merged)
	if len(merged) != gatewayReasonMax || !strings.HasPrefix(merged, strings.Repeat("a", gatewayReasonMax)) {
		t.Fatalf("merged reason = %d bytes %q, want the bound applied to the join", len(merged), merged)
	}

	// Boundary 1: a new session's placement clears whatever the previous profile's last seal left.
	stashCreditReason("insufficient valid tokens")
	resetSealStatus()
	if b, ok := stashed(); ok {
		t.Fatalf("resetSealStatus must remove the previous session's stash, still holds %q", b)
	}
	// Boundary 2: the start of a seal attempt (clearCreditReason is what triggerRoamWorkerKind runs under
	// the slot for an `out`).
	stashCreditReason("insufficient valid tokens")
	clearCreditReason()
	if b, ok := stashed(); ok {
		t.Fatalf("clearCreditReason must empty the stash, still holds %q", b)
	}
	if got := takeCreditReason(); got != "" {
		t.Fatalf("an empty stash yields no reason, got %q", got)
	}

	// A FAILED logoff seal: SEAL-STATUS keeps the wire verdict verbatim, the sync verdict is recorded WITH the
	// reason, and the stash is consumed.
	resetSealStatus()
	pendingReapMu.Lock()
	sealInFlight, sealRunKind = true, "logoff"
	pendingReapMu.Unlock()
	stashCreditReason("free quota exceeded")
	logoffSealFailed("ERR-NOCREDIT PARTIAL:apps=refused")
	pendingReapMu.Lock()
	inFlight, kind, failed, why := sealInFlight, sealRunKind, sealFail, sealFailWhy
	pendingReapMu.Unlock()
	if inFlight || kind != "" || !failed || why != "ERR-NOCREDIT PARTIAL:apps=refused" {
		t.Fatalf("SEAL-STATUS fields: inFlight=%v kind=%q failed=%v why=%q", inFlight, kind, failed, why)
	}
	if sealStatusGet() != "nocredit" || sealPartsGet() != "apps=refused" || sealReasonGet() != "free quota exceeded" {
		t.Fatalf("a failed logoff seal must be recorded: status=%q parts=%q reason=%q",
			sealStatusGet(), sealPartsGet(), sealReasonGet())
	}
	if b, ok := stashed(); ok {
		t.Fatalf("the logoff verdict must consume the stash, still holds %q", b)
	}
	if got := sealVerdictLog("ERR-NOCREDIT PARTIAL:apps=refused"); got != "ERR-NOCREDIT PARTIAL:apps=refused (gateway: free quota exceeded)" {
		t.Fatalf("logoff FAILED log line = %q", got)
	}
}

// NWP-20261017-16: SEAL-STATUS carries the gateway's reason after FAILED NOCREDIT, as a second line.
// failLogoff drives a failed logoff seal with reason (a stash the seal process left) behind verdict.
func failLogoff(t *testing.T, verdict, reason string) {
	t.Helper()
	resetSealStatus()
	pendingReapMu.Lock()
	sealInFlight, sealRunKind = true, "logoff"
	pendingReapMu.Unlock()
	stashCreditReason(reason)
	logoffSealFailed(verdict)
}

func sealStatusWire(t *testing.T) string {
	t.Helper()
	return strings.Join(composeSealStatus(t.TempDir()), "|")
}

func TestSealStatusNoCreditReason(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Cleanup(func() {
		resetSealStatus()
		pendingReapMu.Lock()
		sealInFlight, sealRunKind, sealFail, sealFailWhy, sealFailReason = false, "", false, "", ""
		pendingReapMu.Unlock()
	})

	// NOCREDIT with a stashed reason: line one is exactly what every startsWith reader saw before.
	failLogoff(t, "ERR-NOCREDIT", "free quota exceeded")
	if got := sealStatusWire(t); got != "FAILED NOCREDIT|REASON free quota exceeded" {
		t.Fatalf("FAILED NOCREDIT with a reason = %q", got)
	}
	// NOCREDIT with no body on the 402: one line, as before.
	failLogoff(t, "ERR-NOCREDIT", "")
	if got := sealStatusWire(t); got != "FAILED NOCREDIT" {
		t.Fatalf("FAILED NOCREDIT without a reason = %q", got)
	}
	// REFUSED never carries a REASON, even when a stash exists.
	failLogoff(t, "ERR-REFUSED", "free quota exceeded")
	if got := sealStatusWire(t); got != "FAILED REFUSED" {
		t.Fatalf("FAILED REFUSED must have no REASON line, got %q", got)
	}
	// A reason with CR/LF is flattened to one line by oneLine.
	pendingReapMu.Lock()
	sealFail, sealFailWhy, sealFailReason = true, "ERR-NOCREDIT", "a\r\nb"
	pendingReapMu.Unlock()
	if got := sealStatusWire(t); got != "FAILED NOCREDIT|REASON a  b" {
		t.Fatalf("CR/LF must be flattened to one line, got %q", got)
	}
	// A fresh logoff clears it.
	resetSealStatus()
	if got := sealStatusWire(t); got != "DONE" {
		t.Fatalf("resetSealStatus must clear the reason, got %q", got)
	}
}

// TestSealStatusReasonIsTheLogoffs: the reason belongs to the LOGOFF verdict, not to whichever seal ran last.
// A periodic OK blanks sealReason and a later refusal replaces it; SEAL-STATUS must still name reason A.
func TestSealStatusReasonIsTheLogoffs(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Cleanup(func() {
		resetSealStatus()
		pendingReapMu.Lock()
		sealInFlight, sealRunKind, sealFail, sealFailWhy, sealFailReason = false, "", false, "", ""
		pendingReapMu.Unlock()
	})
	const want = "FAILED NOCREDIT|REASON reason A"
	failLogoff(t, "ERR-NOCREDIT", "reason A")
	if got := sealStatusWire(t); got != want {
		t.Fatalf("after the logoff: %q", got)
	}
	recordSeal("OK")
	if sealReasonGet() != "" {
		t.Fatalf("a periodic OK must blank sealReason, got %q", sealReasonGet())
	}
	if got := sealStatusWire(t); got != want {
		t.Fatalf("after a periodic OK: %q", got)
	}
	stashCreditReason("reason B")
	recordSeal("ERR-NOCREDIT")
	if sealReasonGet() != "reason B" {
		t.Fatalf("setup: sealReason = %q", sealReasonGet())
	}
	if got := sealStatusWire(t); got != want {
		t.Fatalf("after a later refusal with reason B: %q", got)
	}
}
