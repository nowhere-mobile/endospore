package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"regexp"
	"strings"
	"sync"
	"testing"
)

// Golden vectors for the derivation (dk = 32 x 0x01, key = blob/ + 64 x 'a'). A change to any of these is a
// change to every blob already leased: the commitments on the gateway would stop matching.
const (
	goldenRelKey = "61b9c56a8c9cada06d4719d18ebbaf873ea47584987e3b9b435a435928eb9427"
	goldenProof  = "9b46e647d410e9ddb54fb9f6c6a610ee2533d6b4de50a1a89fead24bca10f226"
	goldenCommit = "5531a6194a7bf28fe10a424be39d2111add6303941dd897f6b31561ecaf15dec"
)

func TestBlobReleaseGoldenVectors(t *testing.T) {
	dk := bytes.Repeat([]byte{1}, 32)
	key := "blob/" + strings.Repeat("a", 64)
	if got := hex.EncodeToString(blobReleaseKey(dk)); got != goldenRelKey {
		t.Errorf("blobReleaseKey = %s, want %s", got, goldenRelKey)
	}
	proof := blobReleaseProof(dk, key)
	if len(proof) != 32 {
		t.Errorf("proof is %d bytes, want 32", len(proof))
	}
	if got := hex.EncodeToString(proof); got != goldenProof {
		t.Errorf("blobReleaseProof = %s, want %s", got, goldenProof)
	}
	commit := blobReleaseCommit(dk, key)
	if commit != goldenCommit {
		t.Errorf("blobReleaseCommit = %s, want %s", commit, goldenCommit)
	}
	sum := sha256.Sum256(proof)
	if commit != hex.EncodeToString(sum[:]) {
		t.Errorf("commit %s is not hex(sha256(proof))", commit)
	}
	dk2 := bytes.Repeat([]byte{2}, 32)
	key2 := "blob/" + strings.Repeat("b", 64)
	for name, other := range map[string][2]any{"dk": {dk2, key}, "key": {dk, key2}} {
		d, k := other[0].([]byte), other[1].(string)
		if bytes.Equal(blobReleaseKey(d), blobReleaseKey(dk)) && name == "dk" {
			t.Errorf("a different dk left blobReleaseKey unchanged")
		}
		if hex.EncodeToString(blobReleaseProof(d, k)) == goldenProof {
			t.Errorf("a different %s left the proof unchanged", name)
		}
		if blobReleaseCommit(d, k) == goldenCommit {
			t.Errorf("a different %s left the commit unchanged", name)
		}
	}
}

func TestReleaseCommitsCoversExactlyTheBlobKeys(t *testing.T) {
	dk := bytes.Repeat([]byte{1}, 32)
	got := releaseCommits(dk, map[string]int64{"blob/x": 1, "ref/y": 2, "blob/z": 3})
	if len(got) != 2 || got["blob/x"] != blobReleaseCommit(dk, "blob/x") || got["blob/z"] != blobReleaseCommit(dk, "blob/z") {
		t.Errorf("releaseCommits = %v, want exactly blob/x and blob/z", got)
	}
	if got := releaseCommits(nil, map[string]int64{"blob/x": 1}); got != nil {
		t.Errorf("nil dk gave %v, want nil", got)
	}
	if got := releaseCommits(dk, map[string]int64{"ref/y": 1}); got != nil {
		t.Errorf("no blob gave %v, want nil", got)
	}
}

// Every lease a bare seal sends carries a commitment for exactly the blobs of its refs.
func TestSealReleaseCommitNamesExactlyTheLeasedBlobs(t *testing.T) {
	led := ledgerFixture(t)
	var mu sync.Mutex
	var seen []leaseReq
	capStoreLeaseStatus = func(req leaseReq) (int, string) {
		mu.Lock()
		seen = append(seen, req)
		mu.Unlock()
		return led.lease(req)
	}
	const name, pass = "relcommit", "a passphrase for the release suite"
	if createVault("s3", name, pass) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	dk, _, ok := resolveKey("s3", name, pass)
	if !ok {
		t.Fatal("the vault does not resolve")
	}
	check := func(label string, reqs []leaseReq) map[string]bool {
		blobs := map[string]bool{}
		if len(reqs) == 0 {
			t.Fatalf("%s: no lease was sent", label)
		}
		for _, r := range reqs {
			want := map[string]bool{}
			for k := range r.Refs {
				if strings.HasPrefix(k, "blob/") {
					want[k] = true
					blobs[k] = true
				}
			}
			if len(want) == 0 {
				t.Errorf("%s: a lease with no blob in its refs", label)
			}
			for k := range want {
				if c, ok := r.ReleaseCommit[k]; !ok {
					t.Errorf("%s: no commitment for %s", label, k)
				} else if c != blobReleaseCommit(dk, k) {
					t.Errorf("%s: wrong commitment for %s", label, k)
				}
			}
			for k := range r.ReleaseCommit {
				if !want[k] {
					t.Errorf("%s: a commitment for %s, which is not a blob of the refs", label, k)
				}
			}
		}
		return blobs
	}
	if sealBare(t, name, pass, "one") {
		t.Fatal("the first seal was refused")
	}
	mu.Lock()
	first := append([]leaseReq(nil), seen...)
	seen = nil
	mu.Unlock()
	b1 := check("first seal", first)
	if sealBare(t, name, pass, "two, different bytes") {
		t.Fatal("the second seal was refused")
	}
	mu.Lock()
	second := append([]leaseReq(nil), seen...)
	mu.Unlock()
	b2 := check("second seal", second)
	fresh := 0
	for k := range b2 {
		if !b1[k] {
			fresh++
		}
	}
	if fresh == 0 {
		t.Error("the second seal buffered no new blob, so its entries were not exercised")
	}
}

func TestSealReleaseCommitKeyOmittedWhenNothingToSend(t *testing.T) {
	b, err := json.Marshal(leaseReq{Refs: map[string]int64{"blob/x": 1}})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(b), "release_commit") {
		t.Errorf("an empty ReleaseCommit still serialised: %s", b)
	}
	b, _ = json.Marshal(leaseReq{Refs: map[string]int64{"blob/x": 1}, ReleaseCommit: map[string]string{"blob/x": "00"}})
	if !strings.Contains(string(b), `"release_commit":{"blob/x":"00"}`) {
		t.Errorf("a set ReleaseCommit did not serialise: %s", b)
	}
}

// Source pin: capFlush's profile-arm lease calls compute the map as their own argument.
func TestSealReleaseCommitIsComputedAtEachLeaseCall(t *testing.T) {
	path := "main.go"
	if p := os.Getenv("NOWHERE_PIN_MAIN_GO"); p != "" { // test-seal-release-commit.sh --mutate points this at the mutant copy
		path = p
	}
	src, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	s := string(src)
	i := strings.Index(s, "func capFlush(")
	if i < 0 {
		t.Fatal("capFlush not found")
	}
	body := s[i:]
	if j := strings.Index(body[1:], "\nfunc "); j >= 0 {
		body = body[:j+1]
	}
	calls := regexp.MustCompile(`gw\.lease(Free|Entitled)Expire\(([^\n]*)\)`).FindAllStringSubmatch(body, -1)
	// Five since NWP-20261112-08: the free arm, the entitled arm's purchase, the token-less 409 retry, the re-lease
	// after a declared purchase is charged short, and the entitled arm's later batches (Q090). Each must carry the
	// commitments of the refs it leases: its release argument is releaseCommits(sess.dk, X), X its own refs argument.
	if len(calls) != 5 {
		t.Fatalf("capFlush has %d leaseFreeExpire/leaseEntitledExpire calls, want exactly 5", len(calls))
	}
	for _, c := range calls {
		args := splitTopLevelArgs(c[2])
		refsAt := 3 // leaseEntitledExpire(profile, tokens, blind, refs, ...)
		if c[1] == "Free" {
			refsAt = 1 // leaseFreeExpire(profile, refs, ...)
		}
		if len(args) <= refsAt {
			t.Errorf("a lease call has too few arguments: %s", c[0])
			continue
		}
		if want := "releaseCommits(sess.dk, " + args[refsAt] + ")"; args[len(args)-1] != want {
			t.Errorf("a lease call does not pass %s as its argument: %s", want, c[0])
		}
	}
}

// splitTopLevelArgs splits a call's argument text on the commas outside any parentheses or brackets.
func splitTopLevelArgs(s string) []string {
	var out []string
	depth, start := 0, 0
	for i, r := range s {
		switch r {
		case '(', '[', '{':
			depth++
		case ')', ']', '}':
			depth--
		case ',':
			if depth == 0 {
				out = append(out, strings.TrimSpace(s[start:i]))
				start = i + 1
			}
		}
	}
	return append(out, strings.TrimSpace(s[start:]))
}
