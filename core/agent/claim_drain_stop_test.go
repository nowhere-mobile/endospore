package main

// NWP-20261129-43: a claim drain cut short by an error or an unexpected status, after some tokens landed, returns the
// landed count with no error, as a complete drain does. login.log must say that it stopped and why, in counts and a
// fixed word only: h53 #6 makes a claim code a paid bearer instrument that is never logged. Every test has its own
// claim code and its own wallet in a t.TempDir().

import (
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"math/big"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"nowhereagent/blindrsa"
)

// cdsRefusalText is the gateway's text in the 503 body. The exact line match in S3 proves that it is not logged.
const cdsRefusalText = "cds-gateway-refusal-text"

// cdsFault answers an /issue call after the good ones. blinded is the call's request.
type cdsFault func(t *testing.T, w http.ResponseWriter, blinded []string)

// cdsDrop closes the connection with no answer.
func cdsDrop(t *testing.T, w http.ResponseWriter, _ []string) {
	conn, _, err := w.(http.Hijacker).Hijack()
	if err != nil {
		t.Errorf("hijack: %v", err)
		return
	}
	conn.Close()
}

// cdsBadSigs answers 200 with signatures from a key other than the served one. Raw RSA reduced mod the other key's
// modulus, as cbsGateway's cbsBadKey does: BlindSign would refuse a value at or above that modulus.
func cdsBadSigs(t *testing.T, w http.ResponseWriter, blinded []string) {
	_, other := cbsKeys(t)
	sigs := make([]string, len(blinded))
	for i, b := range blinded {
		raw, _ := base64.StdEncoding.DecodeString(b)
		z := new(big.Int).Mod(new(big.Int).SetBytes(raw), other.N)
		s := new(big.Int).Exp(z, other.D, other.N).FillBytes(make([]byte, (other.N.BitLen()+7)/8))
		sigs[i] = base64.StdEncoding.EncodeToString(s)
	}
	json.NewEncoder(w).Encode(issueResp{BlindSigs: sigs, Periods: 3, GB: 50})
}

// cds503 answers 503 with a refusal text.
func cds503(_ *testing.T, w http.ResponseWriter, _ []string) {
	w.WriteHeader(http.StatusServiceUnavailable)
	json.NewEncoder(w).Encode(map[string]string{"error": cdsRefusalText})
}

// cdsGateway signs its first goodCalls /issue calls with the served key, as a 50 GB x 3 plan, and runs fault on each
// later call.
func cdsGateway(t *testing.T, goodCalls int, fault cdsFault) *gatewayClient {
	t.Helper()
	served, _ := cbsKeys(t)
	var mu sync.Mutex
	calls := 0
	mux := http.NewServeMux()
	mux.HandleFunc("/issue/pubkey", func(w http.ResponseWriter, _ *http.Request) {
		der, _ := x509.MarshalPKIXPublicKey(&served.PublicKey)
		p := string(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der}))
		json.NewEncoder(w).Encode(map[string]string{"pubkey_pem": p, "denom": "1GBmo"})
	})
	mux.HandleFunc("/issue", func(w http.ResponseWriter, r *http.Request) {
		var req issueReq
		json.NewDecoder(r.Body).Decode(&req)
		mu.Lock()
		calls++
		good := calls <= goodCalls
		mu.Unlock()
		if !good {
			fault(t, w, req.Blinded)
			return
		}
		sigs := make([]string, len(req.Blinded))
		for i, b := range req.Blinded {
			raw, _ := base64.StdEncoding.DecodeString(b)
			s, err := blindrsa.BlindSign(served, raw)
			if err != nil {
				w.WriteHeader(http.StatusBadRequest)
				return
			}
			sigs[i] = base64.StdEncoding.EncodeToString(s)
		}
		json.NewEncoder(w).Encode(issueResp{BlindSigs: sigs, Periods: 3, GB: 50})
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return newGatewayClient(srv.URL, gwDefault)
}

// cdsResult is one drain: what it returned, what it wrote to stderr, and its claim code and wallet.
type cdsResult struct {
	n      int
	err    error
	out    string
	claim  string
	wallet string
}

func cdsDrain(t *testing.T, g *gatewayClient, claim string) cdsResult {
	t.Helper()
	r := cdsResult{claim: claim, wallet: filepath.Join(t.TempDir(), "wallet.json")}
	r.out = captureStderr(t, func() { r.n, r.err = drainClaim(g, r.wallet, claim, false) })
	return r
}

func cdsNoAnswer(t *testing.T) cdsResult {
	return cdsDrain(t, cdsGateway(t, 2, cdsDrop), "cdsNoAnswerClaimCode00001")
}

func cdsSignaturesRefused(t *testing.T) cdsResult {
	return cdsDrain(t, cdsGateway(t, 1, cdsBadSigs), "cdsSigsRefusedClaimCode02")
}

func cdsUnexpectedStatus(t *testing.T) cdsResult {
	return cdsDrain(t, cdsGateway(t, 1, cds503), "cdsHttp503ClaimCode000003")
}

func cdsComplete(t *testing.T) cdsResult {
	served, _ := cbsKeys(t)
	claim := "cdsCompleteClaimCode00004"
	srv := blindGateway(t, served, claim, 7)
	t.Cleanup(srv.Close)
	return cdsDrain(t, newGatewayClient(srv.URL, gwDefault), claim)
}

func cdsUnknown(t *testing.T) cdsResult {
	served, _ := cbsKeys(t)
	srv := blindGateway(t, served, "cdsAnotherClaimCode000005", 7)
	t.Cleanup(srv.Close)
	return cdsDrain(t, newGatewayClient(srv.URL, gwDefault), "cdsUnknownClaimCode000006")
}

// cdsStopLines returns each captured line about a stopped drain.
func cdsStopLines(out string) []string {
	var lines []string
	for _, l := range strings.Split(out, "\n") {
		if strings.Contains(l, "the drain stopped") {
			lines = append(lines, l)
		}
	}
	return lines
}

// cdsWant is the whole expected line. The test holds its own copy of the text: an exact match also proves that the
// line carries no URL, no error text and no text from the gateway.
func cdsWant(n int, why string) string {
	return fmt.Sprintf("[agent] claim: the drain stopped after %d token(s) (%s) -- the code keeps the rest, and redeeming it again finishes the drain (NWP-20261129-43)", n, why)
}

// cdsAssertStopped checks the partial success the callers read, and the one stop line.
func cdsAssertStopped(t *testing.T, r cdsResult, n int, why string) {
	t.Helper()
	if r.err != nil || r.n != n {
		t.Fatalf("drain = (%d, %v), want (%d, nil)", r.n, r.err, n)
	}
	lines := cdsStopLines(r.out)
	if len(lines) != 1 || lines[0] != cdsWant(n, why) {
		t.Fatalf("stop lines = %q, want exactly %q", lines, cdsWant(n, why))
	}
	w, err := loadWallet(r.wallet)
	if err != nil {
		t.Fatal(err)
	}
	if len(w.BlindTokens) != n {
		t.Fatalf("wallet holds %d tokens, want %d", len(w.BlindTokens), n)
	}
}

// S1: the failure scenario in small: the network drops after some tokens landed. The first batch recorded the plan and
// the wallet cannot fund it, so nothing activates.
func TestClaimDrainStop_S1_NoAnswer(t *testing.T) {
	r := cdsNoAnswer(t)
	cdsAssertStopped(t, r, 3, "no answer")
	w, err := loadWallet(r.wallet)
	if err != nil {
		t.Fatal(err)
	}
	if w.PlanGB != 50 || w.PlanPeriods != 3 || w.planPending() {
		t.Fatalf("plan %d GB x %d, pending %v; want 50 GB x 3, not pending", w.PlanGB, w.PlanPeriods, w.planPending())
	}
}

func TestClaimDrainStop_S2_SignaturesRefused(t *testing.T) {
	cdsAssertStopped(t, cdsSignaturesRefused(t), 1, "signatures refused")
}

func TestClaimDrainStop_S3_UnexpectedStatus(t *testing.T) {
	cdsAssertStopped(t, cdsUnexpectedStatus(t), 1, "HTTP 503")
}

func TestClaimDrainStop_S4_CompleteOrUnknownWritesNone(t *testing.T) {
	r := cdsComplete(t)
	if r.err != nil || r.n != 7 {
		t.Fatalf("complete drain = (%d, %v), want (7, nil)", r.n, r.err)
	}
	if lines := cdsStopLines(r.out); len(lines) != 0 {
		t.Fatalf("a complete drain wrote %q", lines)
	}
	r = cdsUnknown(t)
	if r.err != nil || r.n != 0 {
		t.Fatalf("unknown code = (%d, %v), want (0, nil)", r.n, r.err)
	}
	if lines := cdsStopLines(r.out); len(lines) != 0 {
		t.Fatalf("an unknown code wrote %q", lines)
	}
}

// S5 reads the whole capture of every S1-S4 flow: no line may hold the code, or a token in either encoding.
func TestClaimDrainStop_S5_NamesNoCodeOrToken(t *testing.T) {
	for _, c := range []struct {
		name string
		run  func(*testing.T) cdsResult
		toks int
	}{
		{"no answer", cdsNoAnswer, 3},
		{"signatures refused", cdsSignaturesRefused, 1},
		{"unexpected status", cdsUnexpectedStatus, 1},
		{"complete", cdsComplete, 7},
		{"unknown", cdsUnknown, 0},
	} {
		t.Run(c.name, func(t *testing.T) {
			r := c.run(t)
			if strings.Contains(r.out, r.claim) {
				t.Errorf("stderr holds the claim code: %q", r.out)
			}
			w, err := loadWallet(r.wallet)
			if err != nil {
				t.Fatal(err)
			}
			if len(w.BlindTokens) != c.toks {
				t.Fatalf("wallet holds %d tokens, want %d: this flow proves nothing about them", len(w.BlindTokens), c.toks)
			}
			for _, tok := range w.BlindTokens {
				msg, err := base64.StdEncoding.DecodeString(tok.Msg)
				if err != nil {
					t.Fatal(err)
				}
				for _, secret := range []string{tok.Msg, tok.Sig, string(msg)} {
					if strings.Contains(r.out, secret) {
						t.Errorf("stderr holds a token: %q", r.out)
					}
				}
			}
		})
	}
}

// The word for an error with any other code: no path through a gateway reaches it today, so the function is read
// directly.
func TestClaimDrainStop_ErrWords(t *testing.T) {
	for code, want := range map[int]string{0: "no answer", http.StatusOK: "signatures refused", http.StatusInternalServerError: "error"} {
		if got := claimDrainErrWhy(code); got != want {
			t.Errorf("claimDrainErrWhy(%d) = %q, want %q", code, got, want)
		}
	}
}
