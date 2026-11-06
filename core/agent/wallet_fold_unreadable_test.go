package main

import (
	"errors"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20261107-02 (dn-1031 #1, decided 2026-10-21, option (b)): the cap-mode fold writes no #wallet head while the
// stored copy cannot be read, so a store hiccup on handset B's wallet read does not publish B's local set over the
// tokens handset A claimed. The data still seals; the wallet publishes at the next save that can read it. Absence and a
// damaged copy keep publishing the local set (the restore-proof gate and REPAIR-WALLET govern a damaged one).

var errFoldStoreRead = errors.New("store read failed")

// foldUnreadableSeam makes the fold's read of the stored wallet answer err, until the test ends.
func foldUnreadableSeam(t *testing.T, err error) {
	t.Helper()
	orig := readStoredWalletForPublish
	readStoredWalletForPublish = func(base, name, pass string, dk []byte) (*Wallet, []byte, error) {
		return nil, nil, err
	}
	t.Cleanup(func() { readStoredWalletForPublish = orig })
}

// foldUnreadableRig is two handsets against one fake store: wa is handset A's wallet file (walletRaceEnv's), wb is
// handset B's. Both generations carry a restore proof, or the fold's own gate would publish nothing and prove nothing.
type foldUnreadableRig struct {
	name, pass string
	dk         []byte
	wa, wb     string
	walletRef  string
}

func newFoldUnreadableRig(t *testing.T, name, pass string) *foldUnreadableRig {
	t.Helper()
	contentCache = nil
	r := &foldUnreadableRig{name: name, pass: pass}
	r.wa = walletRaceEnv(t)
	r.wb = filepath.Join(t.TempDir(), "wallet.json")
	provenWallet(t, r.wb)
	standUpProfile(t, name, pass)
	r.dk = resolveDK("s3", name, pass, nil)
	r.walletRef, _ = headWriteRef(name+"#wallet", pass)
	return r
}

func (r *foldUnreadableRig) save(t *testing.T, wpath string, nonces ...string) {
	t.Helper()
	w := &Wallet{}
	for _, n := range nonces {
		w.Tokens = append(w.Tokens, Token{Nonce: n})
	}
	if err := saveWallet(wpath, w); err != nil {
		t.Fatal(err)
	}
}

// publishA is handset A's durable publish of nonces.
func (r *foldUnreadableRig) publishA(t *testing.T, nonces ...string) {
	t.Helper()
	r.save(t, r.wa, nonces...)
	t.Setenv("NOWHERE_WALLET", r.wa)
	if _, err := sealWalletDurable("s3", r.name, r.pass, r.dk, r.wa); err != nil {
		t.Fatalf("handset A's publish: %v", err)
	}
}

// foldB is handset B's seal: it carries a data head, so capFlush folds B's wallet.
func (r *foldUnreadableRig) foldB(t *testing.T) {
	t.Helper()
	t.Setenv("NOWHERE_WALLET", r.wb)
	foldingSeal(t, r.name, r.pass, r.dk)
}

func (r *foldUnreadableRig) walletHead() string { return getRef("s3", r.walletRef) }
func (r *foldUnreadableRig) dataHead() string   { return getRef("s3", profileRefV2(r.name, r.pass)) }

func (r *foldUnreadableRig) stored(t *testing.T) map[string]bool {
	t.Helper()
	// r.dk, not storedWallet: foldingSeal's data head is a bare blob, from which resolveDK finds no key.
	sw := readStoredWallet("s3", r.name, r.pass, r.dk)
	if sw == nil {
		t.Fatal("no stored wallet")
	}
	return twoWriterNonces(sw)
}

func TestWalletFoldUnreadable_U1_AnUnreadableCopyIsNotOverwrittenByTheLocalSet(t *testing.T) {
	r := newFoldUnreadableRig(t, "foldunreadu1", "an unreadable copy keeps A's tokens")
	r.publishA(t, "A1", "A2", "A3")
	headA, dataBefore := r.walletHead(), r.dataHead()
	if headA == "" {
		t.Fatal("control: handset A's publish wrote no wallet head")
	}
	r.save(t, r.wb, "B1")

	foldUnreadableSeam(t, errFoldStoreRead)
	r.foldB(t)

	if got := r.walletHead(); got != headA {
		t.Errorf("the #wallet head moved from %s to %s while the stored copy could not be read", headA, got)
	}
	got := r.stored(t)
	if got["B1"] || !got["A1"] || !got["A2"] || !got["A3"] {
		t.Errorf("the stored wallet is %v, want A's three tokens and not B's", got)
	}
	if r.dataHead() == dataBefore {
		t.Error("the data head did not move: the seal did not land, so this case proves nothing about the fold")
	}
}

func TestWalletFoldUnreadable_U2_TheNextReadableSavePublishesTheMerge(t *testing.T) {
	r := newFoldUnreadableRig(t, "foldunreadu2", "the next readable save merges")
	r.publishA(t, "A1", "A2")
	headA := r.walletHead()
	r.save(t, r.wb, "B1")

	foldUnreadableSeam(t, errFoldStoreRead)
	r.foldB(t)
	if r.walletHead() != headA {
		t.Fatal("control: the unreadable fold moved the wallet head")
	}
	readStoredWalletForPublish = readStoredWalletStrict
	r.foldB(t)

	if r.walletHead() == headA {
		t.Error("the readable fold published no wallet")
	}
	got := r.stored(t)
	for _, k := range []string{"A1", "A2", "B1"} {
		if !got[k] {
			t.Errorf("the merge lost %s (stored %v)", k, got)
		}
	}
}

func TestWalletFoldUnreadable_U3_ADamagedCopyStillPublishesTheLocalSet(t *testing.T) {
	r := newFoldUnreadableRig(t, "foldunreadu3", "a damaged copy is Q153's path")
	r.publishA(t, "A1", "A2")
	headA := r.walletHead()
	r.save(t, r.wb, "B1")

	foldUnreadableSeam(t, errWalletBlobDamaged)
	r.foldB(t)

	if r.walletHead() == headA {
		t.Error("a damaged stored copy published no wallet: today's local-set publish is the Q153 path")
	}
	got := r.stored(t)
	if !got["B1"] || got["A1"] {
		t.Errorf("the stored wallet is %v, want B's local set alone", got)
	}
}

func TestWalletFoldUnreadable_U4_NoStoredWalletAtAllPublishesTheFirstFold(t *testing.T) {
	r := newFoldUnreadableRig(t, "foldunreadu4", "the first fold publishes")
	if r.walletHead() != "" {
		t.Fatal("control: a wallet head exists before any publish")
	}
	r.save(t, r.wb, "B1")

	r.foldB(t)

	if got := r.stored(t); !got["B1"] {
		t.Errorf("the first fold published %v, want B's token", got)
	}
}

func TestWalletFoldUnreadable_U5_ASecondFoldWhoseReadFailsUnstagesTheFirst(t *testing.T) {
	r := newFoldUnreadableRig(t, "foldunreadu5", "the re-fold unstages the first fold")
	r.publishA(t, "A1", "A2")
	headA := r.walletHead()
	r.save(t, r.wb, "B1")
	dataBefore := r.dataHead()

	reads := 0
	orig := readStoredWalletForPublish
	readStoredWalletForPublish = func(base, name, pass string, dk []byte) (*Wallet, []byte, error) {
		reads++
		if reads == 1 {
			return readStoredWalletStrict(base, name, pass, dk)
		}
		return nil, nil, errFoldStoreRead
	}
	t.Cleanup(func() { readStoredWalletForPublish = orig })

	var leases []map[string]int64
	capStoreLeaseStatus = func(req leaseReq) (int, string) {
		leases = append(leases, req.Refs)
		if req.Free {
			return http.StatusPaymentRequired, "" // over the free quota: the entitled arm re-folds
		}
		return http.StatusOK, "" // granted whatever B's wallet holds, as wallet_two_writer_test.go does
	}
	t.Cleanup(func() { capStoreLeaseStatus = nil })

	func() {
		defer func() {
			if p := recover(); p != nil {
				t.Errorf("the flush panicked: %v", p)
			}
		}()
		r.foldB(t)
	}()

	ref := "ref/" + r.walletRef
	if reads < 2 || len(leases) < 2 {
		t.Fatalf("control: %d reads and %d leases, want a flush that folded twice", reads, len(leases))
	}
	first, last := leases[0], leases[len(leases)-1]
	if _, ok := first[ref]; !ok {
		t.Fatal("control: the first fold staged no wallet head")
	}
	if _, ok := last[ref]; ok {
		t.Error("the entitled lease still carries the first fold's wallet head")
	}
	for k := range first {
		if _, ok := last[k]; !ok && len(k) > 5 && k[:5] == "blob/" && walletStoreHas(t, k) {
			t.Errorf("the first fold's snapshot %s was PUT although the re-fold could not read the stored copy", k)
		}
	}
	if got := r.walletHead(); got != headA {
		t.Errorf("the #wallet head moved from %s to %s", headA, got)
	}
	if got := r.stored(t); got["B1"] {
		t.Errorf("the stored wallet holds B's token: %v", got)
	}
	if r.dataHead() == dataBefore {
		t.Error("B's data head did not move: the seal did not land, so this case proves nothing about the fold")
	}
}

func TestWalletFoldUnreadable_U6_ADurablePublishKeepsItsOwnHeadWhenTheReFoldCannotRead(t *testing.T) {
	r := newFoldUnreadableRig(t, "foldunreadu6", "a durable publish keeps its own head")
	r.publishA(t, "A1")
	headA := r.walletHead()
	// A purchase waiting: the flush skips the free lease, and the entitled arm re-folds. Both folds seal the same
	// wallet: the purchase holds in its jitter window (the quote's free allowance covers this flush), so B1 is not
	// spent, and the wallet already records this epoch's free 402 (mockCapStore's epoch is 42), so the entitled arm
	// changes nothing in it. So this case pins the copy the first fold read alone; U8 is the re-fold of changed bytes.
	b := &Wallet{Tokens: []Token{{Nonce: "B1"}}, PlanGB: 1, PlanPeriods: 1, ActivateAfter: 1 << 40, FreeFullEpoch: 42}
	if err := saveWallet(r.wb, b); err != nil {
		t.Fatal(err)
	}
	capStoreQuote = func(_ http.Header, q *quoteInfo) { q.FreeGB = 5 }
	t.Cleanup(func() { capStoreQuote = nil })

	// The fold's first read lands, on a stored copy one token on from the one sealWalletDurable merged (handset A has
	// published A2 since), and every later read fails: the re-fold cannot read.
	reads := 0
	orig := readStoredWalletForPublish
	readStoredWalletForPublish = func(base, name, pass string, dk []byte) (*Wallet, []byte, error) {
		reads++
		if reads == 1 {
			w, pt, err := readStoredWalletStrict(base, name, pass, dk)
			if w != nil {
				w.Tokens = append(w.Tokens, Token{Nonce: "A2"})
			}
			return w, pt, err
		}
		return nil, nil, errFoldStoreRead
	}
	t.Cleanup(func() { readStoredWalletForPublish = orig })

	var free, entitled int
	capStoreLeaseStatus = func(req leaseReq) (int, string) {
		if req.Free {
			free++
			return http.StatusPaymentRequired, ""
		}
		entitled++
		return http.StatusOK, ""
	}
	t.Cleanup(func() { capStoreLeaseStatus = nil })

	t.Setenv("NOWHERE_WALLET", r.wb)
	if _, err := sealWalletDurable("s3", r.name, r.pass, r.dk, r.wb); err != nil {
		t.Fatalf("the durable publish failed: %v", err)
	}

	if free != 0 || entitled == 0 {
		t.Fatalf("control: %d free and %d entitled leases, want the entitled arm alone (it re-folds)", free, entitled)
	}
	if reads < 2 {
		t.Fatalf("control: %d reads of the stored copy through the fold's reader, want the fold's and the re-fold's", reads)
	}
	if r.walletHead() == headA {
		t.Fatal("sealWalletDurable returned nil, but its #wallet head did not move: the re-fold unstaged it")
	}
	if got := r.stored(t); !got["B1"] || !got["A1"] || !got["A2"] {
		t.Errorf("the stored wallet is %v, want B's token with A1 and A2 (the re-fold merges the copy the first fold read)", got)
	}
}

func TestWalletFoldUnreadable_U7_ADurablePublishWhoseFoldCannotReadKeepsItsMergedHead(t *testing.T) {
	r := newFoldUnreadableRig(t, "foldunreadu7", "a durable publish keeps its merged head")
	r.publishA(t, "A1")
	headA := r.walletHead()
	r.save(t, r.wb, "B1")

	// sealWalletDurable reads the stored copy {A1} and buffers B's token merged with it. Then, inside its flush and
	// before the fold, the stored head is pointed at a blob the store does not hold, so the fold's read fails whichever
	// reader it takes -- the strict one answers unreadable and the fail-soft one nil -- as a store that stops answering
	// between the two reads would. No seam: this is the store itself failing.
	missing := strings.Repeat("0", 64)
	strictReadable, softRead := true, true
	capFlushWalletLoaded = func() {
		capFlushWalletLoaded = nil
		putStoreObject(t, "ref/"+r.walletRef, missing)
		_, strictReadable = storedWalletForPublish("s3", r.name, r.pass, r.dk)
		softRead = readStoredWallet("s3", r.name, r.pass, r.dk) != nil
	}
	t.Cleanup(func() { capFlushWalletLoaded = nil })
	capStoreLeaseStatus = func(leaseReq) (int, string) { return http.StatusOK, "" } // the free lease lands: one fold
	t.Cleanup(func() { capStoreLeaseStatus = nil })

	t.Setenv("NOWHERE_WALLET", r.wb)
	if _, err := sealWalletDurable("s3", r.name, r.pass, r.dk, r.wb); err != nil {
		t.Fatalf("the durable publish failed: %v", err)
	}

	if strictReadable || softRead {
		t.Fatalf("control: the stored copy was readable inside the flush (strict %v, fail-soft %v)", strictReadable, softRead)
	}
	if got := r.walletHead(); got == headA || got == missing {
		t.Fatalf("sealWalletDurable returned nil, but its #wallet head is %s (A's was %s)", got, headA)
	}
	if got := r.stored(t); !got["B1"] || !got["A1"] {
		t.Errorf("the stored wallet is %v, want B's token with A's: the fold wrote its local set over the merged head", got)
	}
}

func TestWalletFoldUnreadable_U8_ADurablePublishWhoseEveryFoldCannotReadPublishesThePostSpendWallet(t *testing.T) {
	r := newFoldUnreadableRig(t, "foldunreadu8", "a durable publish publishes what it spent")
	r.publishA(t, "A1")
	headA := r.walletHead()
	// END-UNSAVED's case: a purchase past its activation (ActivateAfter 0), so the flush skips the free lease and the
	// entitled arm buys with P1. sealWalletDurable's own read lands ({A1}), and every read of the fold fails, so no
	// fold of this flush ever reads the stored copy. The re-fold seals other bytes than the first fold (P1 is taken),
	// and the first fold seals the very bytes of the head sealWalletDurable buffered (seal is convergent).
	b := &Wallet{Tokens: []Token{{Nonce: "P1"}, {Nonce: "B2"}}, PlanGB: 1, PlanPeriods: 1}
	if err := saveWallet(r.wb, b); err != nil {
		t.Fatal(err)
	}
	reads := 0
	orig := readStoredWalletForPublish
	readStoredWalletForPublish = func(base, name, pass string, dk []byte) (*Wallet, []byte, error) {
		reads++
		return nil, nil, errFoldStoreRead
	}
	t.Cleanup(func() { readStoredWalletForPublish = orig })

	var free int
	var presented []string
	capStoreLeaseStatus = func(req leaseReq) (int, string) {
		if req.Free {
			free++
			return http.StatusPaymentRequired, ""
		}
		for _, tok := range req.Tokens {
			presented = append(presented, tok.Nonce)
		}
		return http.StatusOK, ""
	}
	t.Cleanup(func() { capStoreLeaseStatus = nil })

	t.Setenv("NOWHERE_WALLET", r.wb)
	if _, err := sealWalletDurable("s3", r.name, r.pass, r.dk, r.wb); err != nil {
		t.Fatalf("the durable publish failed: %v", err)
	}

	if free != 0 || len(presented) != 1 || presented[0] != "P1" {
		t.Fatalf("control: %d free leases and %v presented, want the entitled arm alone buying with P1", free, presented)
	}
	if reads < 2 {
		t.Fatalf("control: %d reads of the stored copy through the fold's reader, want the fold's and the re-fold's", reads)
	}
	if r.walletHead() == headA {
		t.Fatal("sealWalletDurable returned nil, but its #wallet head did not move")
	}
	got := r.stored(t)
	if got["P1"] {
		t.Errorf("the stored wallet is %v: it still holds P1, which the gateway was just presented (the pre-spend head)", got)
	}
	if !got["A1"] || !got["B2"] {
		t.Errorf("the stored wallet is %v, want A1 and B2 kept", got)
	}
}

// putStoreObject writes body at key straight into walletRaceEnv's fake store, as another handset's write would land.
func putStoreObject(t *testing.T, key, body string) {
	t.Helper()
	req, err := http.NewRequest(http.MethodPut, os.Getenv("GATEWAY_URL")+"/obj?k="+url.QueryEscape(key), strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("PUT %s answered %d", key, resp.StatusCode)
	}
}
