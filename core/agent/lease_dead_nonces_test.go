package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// NWP-20261020-03. A /lease 409 used to hand EVERY presented token back to the wallet because its body named no
// nonce, so one dead token kept planPending true and the next seal re-declared the same nonces and 409ed
// identically: dead credit advertised as spendable, forever. The gateway (NWC-20261020-01) now lists, in the 409's
// `spent`, the presented nonces its ledger already held. Both purchase paths retire exactly those, BEFORE
// settlePayment; a 409 without the list (older gateway, failed read, truncated or malformed body) keeps every
// token as before. Each test names the mutant it convicts (see test-lease-dead-nonces.sh).

const (
	deadN1 = "n1AAAAAAAAAAAAAAAAAAAA"
	deadN2 = "n2AAAAAAAAAAAAAAAAAAAA"
	deadN3 = "n3AAAAAAAAAAAAAAAAAAAA"
)

func deadBlind(nonce string) BlindToken {
	return BlindToken{Msg: base64.StdEncoding.EncodeToString([]byte("1GBmo|" + nonce + "|2000000000"))}
}

func deadNonceSet(w *Wallet) map[string]bool {
	m := map[string]bool{}
	for _, t := range w.Tokens {
		m[t.Nonce] = true
	}
	return m
}

func deadWallet() *Wallet {
	return &Wallet{Tokens: []Token{{Nonce: deadN1}, {Nonce: deadN2}, {Nonce: deadN3}}, PlanGB: 2, PlanPeriods: 1}
}

func deadBody(spent ...string) []byte {
	b, _ := json.Marshal(map[string]any{"error": "token already spent", "spent": spent})
	return b
}

// deadNonceSeal is capSealWith over a caller-chosen wallet (capSealWith buys faucet tokens, whose nonces are random).
func deadNonceSeal(t *testing.T, g *conflictGateway, name, pass string, w *Wallet) *Wallet {
	t.Helper()
	t.Setenv("GATEWAY_URL", g.srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	capReadCache = map[string]capEntry{}
	blobCache = nil
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)
	if err := saveWallet(wpath, w); err != nil {
		t.Fatal(err)
	}
	dk := deriveKey(name, pass)
	bn := capBegin()
	capSetSession(name, pass, dk)
	h := postBlob("s3", bytes.Repeat([]byte("d"), 4096))
	putRef("s3", profileRefV2(name, pass), h)
	capFlush(bn)
	after, err := loadWallet(wpath)
	if err != nil {
		t.Fatal(err)
	}
	return after
}

func deadLeaseRefs(t *testing.T, g *conflictGateway, w *Wallet) *Wallet {
	t.Helper()
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	if err := saveWallet(wpath, w); err != nil {
		t.Fatal(err)
	}
	if _, _, err := leaseRefs(newGatewayClient(g.srv.URL, gwDefault), wpath, "profX", map[string]int64{"blob/a": 8 * giB}, nil); err != nil {
		t.Fatalf("leaseRefs: %v", err)
	}
	after, err := loadWallet(wpath)
	if err != nil {
		t.Fatal(err)
	}
	return after
}

// Mutant M12 (blind nonce read from field 1) and M1-M6's filter result are convicted here.
func TestLeaseDeadNonces_DropsNamedPlainAndBlind(t *testing.T) {
	kp, kb, n := dropNamedSpent([]Token{{Nonce: deadN1}, {Nonce: deadN2}},
		[]BlindToken{deadBlind("b1AAAAAAAAAAAAAA"), deadBlind("b2AAAAAAAAAAAAAA")}, []string{deadN1, "b2AAAAAAAAAAAAAA"})
	if n != 2 || len(kp) != 1 || kp[0].Nonce != deadN2 || len(kb) != 1 || !reflect.DeepEqual(kb[0], deadBlind("b1AAAAAAAAAAAAAA")) {
		t.Fatalf("kept plain %v blind %v dropped %d, want only n2 and b1 kept, 2 dropped", kp, kb, n)
	}
}

func TestLeaseDeadNonces_IgnoresANameNotPresented(t *testing.T) {
	kp, kb, n := dropNamedSpent([]Token{{Nonce: deadN1}, {Nonce: deadN2}}, nil, []string{deadN3})
	if n != 0 || len(kp) != 2 || len(kb) != 0 {
		t.Fatalf("kept %v dropped %d, want both kept", kp, n)
	}
}

func TestLeaseDeadNonces_KeepsAnUndecodableOrMisshapenBlindMsg(t *testing.T) {
	bad := BlindToken{Msg: "!!!"}
	short := BlindToken{Msg: base64.StdEncoding.EncodeToString([]byte("a|b"))}
	_, kb, n := dropNamedSpent(nil, []BlindToken{bad, short}, []string{"a", "b", "!!!"})
	if n != 0 || len(kb) != 2 {
		t.Fatalf("kept %v dropped %d, want both kept", kb, n)
	}
}

func TestLeaseDeadNonces_RepeatedNameDropsOnce(t *testing.T) {
	kp, _, n := dropNamedSpent([]Token{{Nonce: deadN1}, {Nonce: deadN2}}, nil, []string{deadN1, deadN1})
	if n != 1 || len(kp) != 1 || kp[0].Nonce != deadN2 {
		t.Fatalf("kept %v dropped %d, want n2 kept, 1 dropped", kp, n)
	}
}

// Mutants M10 (alphabet test always true) and M11 (length cap removed).
func TestLeaseDeadNonces_DecodeAcceptsOnlyBase64urlUpTo64(t *testing.T) {
	ok64 := strings.Repeat("A", 64)
	body := fmt.Sprintf(`{"spent":["n1","n.1","a b","é","","%s","%s",7,null]}`, strings.Repeat("A", 65), ok64)
	if got, want := spentNamed([]byte(body)), []string{"n1", ok64}; !reflect.DeepEqual(got, want) {
		t.Fatalf("spentNamed = %v, want %v", got, want)
	}
	for name, b := range map[string]string{"no key": `{"error":"x"}`, "number": `{"spent":3}`, "not json": `nope`, "empty": ``} {
		if got := spentNamed([]byte(b)); got != nil {
			t.Fatalf("%s: spentNamed = %v, want nil", name, got)
		}
	}
}

// Mutant M9 (Reason computed over the longer read) and M13 (SpentNonces never set).
func TestLeaseDeadNonces_ReasonUnchangedByTheLongerRead(t *testing.T) {
	var names []string
	for i := 0; i < 200; i++ {
		names = append(names, fmt.Sprintf("%022d", i))
	}
	body := deadBody(names...)
	if len(body) <= gatewayReasonRead {
		t.Fatalf("fixture body is %d bytes, want more than %d", len(body), gatewayReasonRead)
	}
	for _, code := range []int{http.StatusConflict, http.StatusPaymentRequired} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(code)
			w.Write(body)
		}))
		toks := make([]Token, 200)
		for i := range toks {
			toks[i] = Token{Nonce: names[i]}
		}
		info, got, err := newGatewayClient(srv.URL, gwDefault).leaseEntitled("p", toks, nil, map[string]int64{"r": 1}, 1, 1, "", nil)
		srv.Close()
		if err != nil || got != code {
			t.Fatalf("code %d: got %d err %v", code, got, err)
		}
		if want := gatewayReason(body[:gatewayReasonRead]); info.Reason != want {
			t.Fatalf("code %d: Reason %q, want %q", code, info.Reason, want)
		}
		if code == http.StatusConflict && len(info.SpentNonces) != 200 {
			t.Fatalf("409 SpentNonces has %d entries, want 200", len(info.SpentNonces))
		}
		if code != http.StatusConflict && info.SpentNonces != nil {
			t.Fatalf("a %d must not carry a list, got %d entries", code, len(info.SpentNonces))
		}
	}
}

// Mutants M1 (every presented token dropped), M3 (filter after settle), M13.
func TestLeaseDeadNonces_CapFlush409RetiresTheNamed(t *testing.T) {
	g := newConflictGateway(t, 0)
	g.conflictBody = deadBody(deadN1)
	after := deadNonceSeal(t, g, "deadnamed", "the gateway names one", deadWallet())
	got := deadNonceSet(after)
	if got[deadN1] || !got[deadN2] || !got[deadN3] || after.balance() != 2 {
		t.Fatalf("wallet holds %v, want exactly n2 and n3", got)
	}
	g.mu.Lock()
	retries, lastGB := g.freeBuys, g.lastBuyGB
	g.mu.Unlock()
	if retries == 0 || lastGB != 0 {
		t.Fatalf("token-less retry did not land (freeBuys=%d last_buy_gb=%d)", retries, lastGB)
	}
	if after.PaidThrough == g.through {
		t.Fatalf("PaidThrough was stamped %d from a lease that bought nothing", after.PaidThrough)
	}
}

// The control: today's behaviour. Convicts M1 as well (everything dropped).
func TestLeaseDeadNonces_CapFlush409WithoutTheListKeepsAll(t *testing.T) {
	g := newConflictGateway(t, 0)
	g.conflictBody = []byte(`{"error":"token already spent"}`)
	after := deadNonceSeal(t, g, "deadnolist", "the gateway names none", deadWallet())
	if got := deadNonceSet(after); after.balance() != 3 || !got[deadN1] {
		t.Fatalf("wallet holds %v, want all three", got)
	}
}

// Mutant M5 (a name that was not presented removes a wallet token): n3 is in the wallet, not presented.
func TestLeaseDeadNonces_CapFlush409NameNotPresentedKeepsTheWallet(t *testing.T) {
	g := newConflictGateway(t, 0)
	g.conflictBody = deadBody(deadN1, deadN3)
	after := deadNonceSeal(t, g, "deadnotpres", "the gateway names a bystander", deadWallet())
	got := deadNonceSet(after)
	if got[deadN1] || !got[deadN2] || !got[deadN3] {
		t.Fatalf("wallet holds %v, want n2 and n3 (n3 was never presented)", got)
	}
}

// Mutants M7 (bound removed) and M8 (truncation check removed). Trailing spaces keep the body VALID JSON, so only
// the bound can keep n1 in the wallet.
func TestLeaseDeadNonces_CapFlush409OversizeBodyKeepsAll(t *testing.T) {
	g := newConflictGateway(t, 0)
	g.conflictBody = append(deadBody(deadN1), bytes.Repeat([]byte(" "), gatewayReasonRead+128+512)...)
	after := deadNonceSeal(t, g, "deadbig", "the body is past its bound", deadWallet())
	if got := deadNonceSet(after); after.balance() != 3 || !got[deadN1] {
		t.Fatalf("wallet holds %v, want all three", got)
	}
}

// Mutants M2, M4, M6, M13.
func TestLeaseDeadNonces_LeaseRefs409RetiresTheNamed(t *testing.T) {
	g := newConflictGateway(t, 0)
	g.conflictBody = deadBody(deadN1, deadN3)
	after := deadLeaseRefs(t, g, deadWallet())
	got := deadNonceSet(after)
	if got[deadN1] || !got[deadN2] || !got[deadN3] || after.balance() != 2 {
		t.Fatalf("wallet holds %v, want exactly n2 and n3", got)
	}
	g.mu.Lock()
	retries := g.freeBuys
	g.mu.Unlock()
	if retries == 0 {
		t.Fatal("no token-less renewal followed the 409")
	}
}

func TestLeaseDeadNonces_LeaseRefs409WithoutTheListKeepsAll(t *testing.T) {
	g := newConflictGateway(t, 0)
	g.conflictBody = []byte(`{"error":"token already spent"}`)
	if after := deadLeaseRefs(t, g, deadWallet()); after.balance() != 3 {
		t.Fatalf("wallet holds %d, want 3", after.balance())
	}
}

func TestLeaseDeadNonces_LeaseRefs409RetiresANamedBlindToken(t *testing.T) {
	g := newConflictGateway(t, 0)
	g.conflictBody = deadBody("b1AAAAAAAAAAAAAA")
	after := deadLeaseRefs(t, g, &Wallet{BlindTokens: []BlindToken{deadBlind("b1AAAAAAAAAAAAAA"), deadBlind("b2AAAAAAAAAAAAAA")}, PlanGB: 2, PlanPeriods: 1})
	if len(after.BlindTokens) != 1 || !reflect.DeepEqual(after.BlindTokens[0], deadBlind("b2AAAAAAAAAAAAAA")) {
		t.Fatalf("wallet blind tokens %v, want only b2", after.BlindTokens)
	}
}
