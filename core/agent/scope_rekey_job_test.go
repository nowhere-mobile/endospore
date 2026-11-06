package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20261008-03: the background re-key of a tied profile's large scopes (docs/tie-scope-keys.md §9), in a cap-mode
// store as on the phone, with batches of one chunk so a small scope spans several.

// sealMediaInSession seals #media holding f.txt = body and a random camera photo big enough for several chunks,
// which the seal defers (on-demand), so the deferred regions are re-keyed too.
func sealMediaInSession(t *testing.T, name, pass, body string) {
	t.Helper()
	d := t.TempDir()
	if err := os.WriteFile(filepath.Join(d, "f.txt"), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	big := make([]byte, 3<<20)
	rand.Read(big)
	cam := filepath.Join(d, "DCIM", "Camera")
	if err := os.MkdirAll(cam, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cam, "big.jpg"), big, 0o600); err != nil { // a camera photo: deferred
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1") // roamd exports it for every seal: bulk media is deferred
	pushProfile("s3", name+"#media", pass, d)
	pushFenceSeq, pushFenceSampled = 0, false // see rotateFixture
}

// tiedWithMedia is a tied profile (the small scopes re-keyed by SE-TIE) whose #media holds content, with batches of
// one chunk and the chip secret in the environment, as roamd's seals have it.
func tiedWithMedia(t *testing.T) (dest, name, pass string) {
	t.Helper()
	dest, name, pass, _ = tieFixture(t, hex.EncodeToString(seA))
	sealMediaInSession(t, name, pass, "photos v1")
	if err := sessionTie("s3", name, pass, seA); err != nil {
		t.Fatal(err)
	}
	old := rekeyBatchBytes
	rekeyBatchBytes = 1
	t.Cleanup(func() { rekeyBatchBytes = old })
	t.Setenv("NOWHERE_SE_SECRET", hex.EncodeToString(seA))
	return dest, name, pass
}

// rekeyIndex opens the vault through the chip and returns its scope index.
func rekeyIndex(t *testing.T, name, pass string) map[string]scopeRec {
	t.Helper()
	v, err := readSessionVault("s3", name, pass)
	if err != nil {
		t.Fatal(err)
	}
	dk := unwrapDK(v, "se", kekSE(name, pass, seA))
	if dk == nil {
		t.Fatal("the chip does not open the vault")
	}
	idx, ok := openScopeIndex(dk, v.Scopes)
	if !ok {
		t.Fatal("no scope index")
	}
	return idx
}

// stepUntilSwitched runs steps until #media switches, failing after limit steps; it returns the batches run.
func stepUntilSwitched(t *testing.T, name, pass string, limit int) int {
	t.Helper()
	batches := 0
	for i := 0; i < limit; i++ {
		st, err := largeScopeRekeyStep("s3", name, pass, seA, "#media")
		if err != nil {
			t.Fatalf("step %d: %v", i, err)
		}
		if st.Batched {
			batches++
		}
		if st.Switched {
			return batches
		}
	}
	t.Fatalf("#media did not switch within %d steps", limit)
	return batches
}

func TestLargeScopeRekeyRunsInBatchesAndSwitches(t *testing.T) {
	_, name, pass := tiedWithMedia(t)
	st, err := largeScopeRekeyStep("s3", name, pass, seA, "#media")
	if err != nil || !st.Batched || st.Switched {
		t.Fatalf("first step = %+v, %v; want one batch, not yet switched", st, err)
	}
	if rec := rekeyIndex(t, name, pass)["#media"]; rec.Next == "" || rec.Progress == "" || rec.Minted {
		t.Fatalf("after a batch the index entry is %+v; want Next and Progress recorded and the key not yet switched", rec)
	}
	if got, ok := readScopeFile(t, "s3", name+"#media", pass, nil); !ok || got != "photos v1" {
		t.Fatalf("mid-job the scope must still read as before (passphrase): %q %v", got, ok)
	}
	if b := stepUntilSwitched(t, name, pass, 50); b < 1 {
		t.Fatalf("the rest took %d batches: a scope of several chunks must span several", b)
	}
	if _, ok := readScopeFile(t, "s3", name+"#media", pass, nil); ok {
		t.Fatal("after the switch the passphrase alone still opens #media")
	}
	if got, ok := readScopeFile(t, "s3", name+"#media", pass, seA); !ok || got != "photos v1" {
		t.Fatalf("after the switch this phone reads #media as %q (%v)", got, ok)
	}
	if rec := rekeyIndex(t, name, pass)["#media"]; rec.Next == "" || !rec.Minted || rec.Prev == "" {
		t.Fatalf("right after the switch the index entry is %+v; want the job kept until the switch is seen, Minted, Prev", rec)
	}
	if st, err := largeScopeRekeyStep("s3", name, pass, seA, "#media"); err != nil || !st.Switched || st.Batched {
		t.Fatalf("a step on a switched scope = %+v, %v; want nothing to re-seal", st, err)
	}
	if rec := rekeyIndex(t, name, pass)["#media"]; rec.Next != "" || rec.Progress != "" || !rec.Minted || rec.Prev == "" {
		t.Fatalf("once the switch is seen the index entry is %+v; want the job cleared, Minted, and Prev", rec)
	}
	// The deferred (on-demand) regions moved too: every chunk the new manifest defers opens under the new key.
	hv := scopeHeadVault(t, "s3", name+"#media", pass)
	k := scopeTiedHere(hv, name+"#media", pass, seA)
	m, ml := classifyManifestLoad("s3", k, hv.Manifest)
	if ml != mlOK {
		t.Fatalf("the switched manifest does not load under the new key: %v", ml)
	}
	if len(m.Deferred) == 0 {
		t.Fatal("precondition: the fixture's #media defers nothing, so the deferred re-key is untested")
	}
	for rel, d := range m.Deferred {
		for _, h := range d.Chunks {
			if err := recovered(func() { unseal(k, getChunk("s3", h)) }); err != nil {
				t.Fatalf("deferred %s: chunk %s does not open under the new key: %v", rel, short(h), err)
			}
		}
	}
}

// A seal of the scope between batches is picked up: the switched head carries the newest content.
func TestLargeScopeRekeyPicksUpASealBetweenBatches(t *testing.T) {
	_, name, pass := tiedWithMedia(t)
	if _, err := largeScopeRekeyStep("s3", name, pass, seA, "#media"); err != nil {
		t.Fatal(err)
	}
	sealMediaInSession(t, name, pass, "photos v2")
	stepUntilSwitched(t, name, pass, 80)
	if got, ok := readScopeFile(t, "s3", name+"#media", pass, seA); !ok || got != "photos v2" {
		t.Fatalf("after the switch #media reads %q (%v), want the content sealed mid-job", got, ok)
	}
}

// A seal that moves the head between the switch's read and its publish: the head move is refused, the vault lands,
// and the job is NOT lost -- the next steps map the new content under the same key and switch.
func TestLargeScopeRekeyKeepsTheJobWhenTheSwitchIsRefused(t *testing.T) {
	_, name, pass := tiedWithMedia(t)
	for i := 0; ; i++ { // batches until everything is mapped: the next step is the switch
		if i > 50 {
			t.Fatal("never mapped every chunk")
		}
		st, err := largeScopeRekeyStep("s3", name, pass, seA, "#media")
		if err != nil {
			t.Fatal(err)
		}
		if st.Batched && st.Done == st.Total {
			break
		}
	}
	key := rekeyIndex(t, name, pass)["#media"].Next
	rekeyAfterRead = func() { rekeyAfterRead = nil; sealMediaInSession(t, name, pass, "photos v3") }
	t.Cleanup(func() { rekeyAfterRead = nil })
	if _, err := largeScopeRekeyStep("s3", name, pass, seA, "#media"); err == nil {
		t.Fatal("a switch over a head a seal had just moved was not refused")
	}
	if rec := rekeyIndex(t, name, pass)["#media"]; rec.Next != key || rec.Progress == "" {
		t.Fatalf("after a refused switch the job is %+v; want the same key and its progress kept", rec)
	}
	stepUntilSwitched(t, name, pass, 80)
	if got, ok := readScopeFile(t, "s3", name+"#media", pass, seA); !ok || got != "photos v3" {
		t.Fatalf("after the switch #media reads %q (%v), want the content the seal wrote", got, ok)
	}
}

// The job resumes from the store: a fresh process (no caches) continues from the recorded progress.
func TestLargeScopeRekeyResumesFromTheStore(t *testing.T) {
	_, name, pass := tiedWithMedia(t)
	first, err := largeScopeRekeyStep("s3", name, pass, seA, "#media")
	if err != nil {
		t.Fatal(err)
	}
	capReadCache = map[string]capEntry{}
	blobCacheMu.Lock()
	blobCache = nil
	blobCacheMu.Unlock()
	second, err := largeScopeRekeyStep("s3", name, pass, seA, "#media")
	if err != nil {
		t.Fatal(err)
	}
	if second.Total != first.Total || second.Done <= first.Done {
		t.Fatalf("after a restart the job reports %d of %d, before it %d of %d: it must continue, not start over",
			second.Done, second.Total, first.Done, first.Total)
	}
}

// An untie drops a job in flight; the scope still opens by passphrase.
func TestUntieDropsALargeScopeRekeyInFlight(t *testing.T) {
	_, name, pass := tiedWithMedia(t)
	if _, err := largeScopeRekeyStep("s3", name, pass, seA, "#media"); err != nil {
		t.Fatal(err)
	}
	if err := sessionUntie("s3", name, pass, seA); err != nil {
		t.Fatal(err)
	}
	v, _ := readSessionVault("s3", name, pass)
	dk := unwrapDK(v, "pass", deriveKey(name, pass))
	idx, ok := openScopeIndex(dk, v.Scopes)
	if !ok {
		t.Fatal("no scope index after untie")
	}
	if rec := idx["#media"]; rec.Next != "" || rec.Progress != "" {
		t.Fatalf("after an untie the job is still recorded: %+v", rec)
	}
	if got, ok := readScopeFile(t, "s3", name+"#media", pass, nil); !ok || got != "photos v1" {
		t.Fatalf("after an untie #media reads %q (%v) by passphrase", got, ok)
	}
}

// The footprint leases a job in flight: the progress record and every chunk it has re-sealed.
func TestFootprintLeasesALargeScopeRekeyInFlight(t *testing.T) {
	_, name, pass := tiedWithMedia(t)
	if _, err := largeScopeRekeyStep("s3", name, pass, seA, "#media"); err != nil {
		t.Fatal(err)
	}
	rec := rekeyIndex(t, name, pass)["#media"]
	refs, measured := profileFootprint("s3", name, pass, seA)
	if !measured {
		t.Fatal("the footprint of a tied profile was not measured")
	}
	if _, ok := refs["blob/"+rec.Progress]; !ok {
		t.Fatal("the footprint does not lease the progress record: the GC would reap the job's state")
	}
	k, _ := unwrap(kekScopes(rekeyDK(t, name, pass)), rec.Next)
	var p rekeyProgress
	if err := recovered(func() { check(json.Unmarshal(unseal(k, getBlob("s3", rec.Progress)), &p)) }); err != nil {
		t.Fatal(err)
	}
	if len(p.Chunks) == 0 {
		t.Fatal("the progress record maps no chunk")
	}
	for _, c := range p.Chunks {
		if _, ok := refs["blob/"+c.H]; !ok {
			t.Fatalf("the footprint does not lease re-sealed chunk %s: the GC would reap it before the switch", short(c.H))
		}
	}
}

// Another tied phone's batch landing between our read and our publish: ours is refused, theirs stands.
func TestLargeScopeRekeyRefusesWhenTheVaultMoved(t *testing.T) {
	_, name, pass := tiedWithMedia(t)
	rekeyAfterRead = func() {
		rekeyAfterRead = nil
		v, _ := readSessionVault("s3", name, pass)
		if err := publishSessionVault("s3", name, pass, v, rekeyDK(t, name, pass)); err != nil {
			t.Fatal(err)
		}
	}
	t.Cleanup(func() { rekeyAfterRead = nil })
	moved, _ := readSessionVault("s3", name, pass)
	_, err := largeScopeRekeyStep("s3", name, pass, seA, "#media")
	if err == nil || !strings.Contains(err.Error(), "refused at publish") {
		t.Fatalf("a batch over a vault that moved = %v, want refused at publish", err)
	}
	if v, _ := readSessionVault("s3", name, pass); v.Version != moved.Version+1 {
		t.Fatalf("the vault reads version %d, want the other phone's %d: the refused batch overwrote it", v.Version, moved.Version+1)
	}
	if st, err := largeScopeRekeyStep("s3", name, pass, seA, "#media"); err != nil || !st.Batched {
		t.Fatalf("the next step after a refusal = %+v, %v; want a batch", st, err)
	}
}

// A passphrase change carries a job in flight: the new credential continues it to the switch.
func TestPassphraseChangeCarriesALargeScopeRekey(t *testing.T) {
	_, name, pass := tiedWithMedia(t)
	if _, err := largeScopeRekeyStep("s3", name, pass, seA, "#media"); err != nil {
		t.Fatal(err)
	}
	before := rekeyIndex(t, name, pass)["#media"]
	const p2 = "a brand new passphrase"
	if _, err := rotateVault("s3", name, pass, p2, seA, true); err != nil {
		t.Fatal(err)
	}
	after := rekeyIndex(t, name, p2)["#media"]
	if after.Next != before.Next || after.Progress != before.Progress {
		t.Fatalf("a passphrase change dropped the job: before %+v, after %+v", before, after)
	}
	stepUntilSwitched(t, name, p2, 50)
	if got, ok := readScopeFile(t, "s3", name+"#media", p2, seA); !ok || got != "photos v1" {
		t.Fatalf("after the switch under the new passphrase #media reads %q (%v)", got, ok)
	}
}

// The daemon runs a batch only when the gate has armed it for this session.
func TestRekeyOnceRunsOnlyWhenArmed(t *testing.T) {
	dest, name, pass := tiedWithMedia(t)
	rekeyOnce(dest)
	if rec := rekeyIndex(t, name, pass)["#media"]; rec.Progress != "" {
		t.Fatal("a batch ran with the gate unarmed")
	}
	os.WriteFile(filepath.Join(dest, rekeyArmedFile), []byte("13\n"), 0o600) // another session's arm
	rekeyOnce(dest)
	if rec := rekeyIndex(t, name, pass)["#media"]; rec.Progress != "" {
		t.Fatal("a batch ran on another session's arm")
	}
	os.WriteFile(filepath.Join(dest, rekeyArmedFile), []byte("12\n"), 0o600)
	rekeyOnce(dest)
	if rec := rekeyIndex(t, name, pass)["#media"]; rec.Progress == "" {
		t.Fatal("no batch ran with the gate armed for this session")
	}
}

func rekeyDK(t *testing.T, name, pass string) []byte {
	t.Helper()
	v, err := readSessionVault("s3", name, pass)
	if err != nil {
		t.Fatal(err)
	}
	return unwrapDK(v, "se", kekSE(name, pass, seA))
}
