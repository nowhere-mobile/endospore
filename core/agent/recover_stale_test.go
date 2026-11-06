package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// NWP-20261116-06, backlog row "A 12-word recovery overwrites a seal another signed-in handset landed while it
// ran" (docs/product-decisions.md 2026-10-22 #20; the ERR-MOVED words, h47 #3, 2026-10-28). recoverVault reads
// ref/<RecoveryRef> before its bracket, and a seal on another handset republishes that ref beside its own head.
// The recovery now holds the ref at the value it read: a seal landed since refuses it, and RECOVER answers
// ERR-MOVED. Cap mode, the fielded fleet's mode; every test has its own profile name.

const recStaleOldPass = "old horse battery staple stale"

// recStaleProfile is a cap-mode profile created and sealed once, so its head and recovery ref name a sealed
// vault. It returns the recovery phrase and the fake store.
func recStaleProfile(t *testing.T, name string) (mnemonic string, objs map[string][]byte, mu *sync.Mutex) {
	t.Helper()
	objs, mu = capLockEnv(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Cleanup(clearStaleHit)
	t.Cleanup(func() { recoverAfterUnwrapHook, recoverBeforePublishHook, capStorePutHook = nil, nil, nil })
	mnemonic = createVault("s3", name, recStaleOldPass)
	if mnemonic == "" {
		t.Fatal("createVault (cap mode) returned no recovery code")
	}
	recStaleSeal(t, name, "the first seal")
	capReadCache = map[string]capEntry{}
	return mnemonic, objs, mu
}

// recStaleSeal seals (name, old pass) with a payload of its own, as a signed-in handset does: a new vault blob,
// the head and ref/<RecoveryRef> all move. It returns the recovery ref's value and the sealed vault's manifest.
func recStaleSeal(t *testing.T, name, payload string) (rrefVal, manifest string) {
	t.Helper()
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "f.txt"), []byte(payload), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile("s3", name, recStaleOldPass, src)
	if sealStaleHit {
		t.Fatalf("the seal %q, with nothing else writing, was refused", payload)
	}
	v, err := readSessionVault("s3", name, recStaleOldPass)
	if err != nil {
		t.Fatalf("the seal %q left no readable vault: %v", payload, err)
	}
	return getRef("s3", v.RecoveryRef), v.Manifest
}

// recStaleRref reads the recovery ref's name from the old-credential vault.
func recStaleRref(t *testing.T, name string) string {
	t.Helper()
	v, err := readSessionVault("s3", name, recStaleOldPass)
	if err != nil || v.RecoveryRef == "" {
		t.Fatalf("the profile has no vault with a recovery ref: %v", err)
	}
	return v.RecoveryRef
}

// recStaleOther is what another handset's seals published: how many landed, and the last one's recovery ref
// value and manifest.
type recStaleOther struct {
	n        int
	rrefVal  string
	manifest string
}

// recStaleOtherSealHook lands another handset's seal each time the recovery has unwrapped and not yet opened its
// bracket. once stops it after the first seal.
func recStaleOtherSealHook(t *testing.T, name string, once bool) *recStaleOther {
	o := &recStaleOther{}
	recoverAfterUnwrapHook = func() {
		o.n++
		o.rrefVal, o.manifest = recStaleSeal(t, name, fmt.Sprintf("the other handset's seal %d", o.n))
		if once {
			recoverAfterUnwrapHook = nil
		}
	}
	return o
}

// recStaleHeldBack seals another handset's seal S2 and rewinds the recovery ref and the old-credential head to the
// seal S1 before it, so the recovery reads S1. land puts S2 back in the store directly, without a bracket, so it
// can run inside the recovery's own bracket.
func recStaleHeldBack(t *testing.T, objs map[string][]byte, mu *sync.Mutex, name, rref, oldHead string) (s2 string, land func()) {
	t.Helper()
	s1 := storeRef(objs, mu, rref)
	s2, _ = recStaleSeal(t, name, "the other handset's seal, held back")
	if s2 == s1 || s2 == "" {
		t.Fatal("test setup: the second seal did not move the recovery ref")
	}
	set := func(v string) {
		mu.Lock()
		objs["ref/"+rref] = []byte(v)
		objs["ref/"+oldHead] = []byte(v)
		mu.Unlock()
	}
	set(s1)
	capReadCache = map[string]capEntry{}
	return s2, func() { set(s2) }
}

// recStaleNothingUnderNewPass fails t if anything under the new passphrase resolves.
func recStaleNothingUnderNewPass(t *testing.T, objs map[string][]byte, mu *sync.Mutex, name string) {
	t.Helper()
	if got := storeRef(objs, mu, profileRefV2(name, recNewPass)); got != "" {
		t.Errorf("a refused recovery published a head under the new passphrase: %s", short(got))
	}
	wref, _ := headWriteRef(name, recNewPass)
	if got := storeRef(objs, mu, wref); got != "" {
		t.Errorf("a refused recovery published this device's head under the new passphrase: %s", short(got))
	}
	capReadCache = map[string]capEntry{}
	if _, _, ok := resolveKey("s3", name, recNewPass); ok {
		t.Error("the new passphrase opens a vault after a refused recovery")
	}
}

// T1: another handset's seal lands between the recovery's read and its bracket. The recovery refuses with both
// sentinels, publishes nothing, and the other seal stands at the recovery ref and the old-credential head.
func TestRecoverStale_SealBeforeTheBracketRefuses(t *testing.T) {
	name := "recstalebefore"
	mn, objs, mu := recStaleProfile(t, name)
	rref := recStaleRref(t, name)
	oldHead, _ := headWriteRef(name, recStaleOldPass)
	other := recStaleOtherSealHook(t, name, false)

	var err error
	log := captureStderr(t, func() { err = recoverVault("s3", name, mn, recNewPass) })

	if other.n != 1 {
		t.Fatalf("test setup: the other handset sealed %d times, want 1", other.n)
	}
	if !errors.Is(err, errRecoverAfterUnwrap) || !errors.Is(err, errRecoverMoved) {
		t.Errorf("the recovery returned %v; want an error that is errRecoverAfterUnwrap AND errRecoverMoved", err)
	}
	// The in-bracket re-read refuses before the scopes are re-pointed or anything is buffered, and says so.
	if !strings.Contains(log, "[agent] recover: refused before anything was written") {
		t.Errorf("the recovery did not refuse at its in-bracket re-read; its log:\n%s", log)
	}
	if got := storeRef(objs, mu, rref); got != other.rrefVal {
		t.Errorf("the recovery ref names %s, not the other handset's seal %s: the recovery overwrote it",
			short(got), short(other.rrefVal))
	}
	if got := storeRef(objs, mu, oldHead); got != other.rrefVal {
		t.Errorf("the old-credential head names %s, not the other handset's seal %s", short(got), short(other.rrefVal))
	}
	recStaleNothingUnderNewPass(t, objs, mu, name)

	if got := recoverReply(name, mn, recNewPass); got != "ERR-MOVED" {
		t.Errorf("RECOVER answered %q over a seal landed during the recovery; want ERR-MOVED", got)
	}
	if got := storeRef(objs, mu, rref); got != other.rrefVal {
		t.Errorf("after RECOVER the recovery ref names %s, not the other handset's seal %s", short(got),
			short(other.rrefVal))
	}
}

// T2: the other seal lands inside the bracket, after the arming and the re-read, as the flush uploads. The flush
// refuses the recovery ref, and because it is a gate (capExpectGate) buffered before the heads, it withholds the
// heads under the new passphrase too. The reply is ERR-MOVED, the same outcome as T1.
func TestRecoverStale_SealInsideTheBracketRefuses(t *testing.T) {
	name := "recstaleinside"
	mn, objs, mu := recStaleProfile(t, name)
	rref := recStaleRref(t, name)
	oldHead, _ := headWriteRef(name, recStaleOldPass)
	s2, land := recStaleHeldBack(t, objs, mu, name, rref, oldHead)
	var once sync.Once
	capStorePutHook = func(key string, _ []byte) error {
		if strings.HasPrefix(key, "blob/") {
			once.Do(land)
		}
		return nil
	}

	got := recoverReply(name, mn, recNewPass)

	if got != "ERR-MOVED" {
		t.Errorf("RECOVER answered %q over a seal landed at the flush; want ERR-MOVED", got)
	}
	if v := storeRef(objs, mu, rref); v != s2 {
		t.Errorf("the recovery ref names %s, not the other handset's seal %s: the recovery overwrote it",
			short(v), short(s2))
	}
	if v := storeRef(objs, mu, oldHead); v != s2 {
		t.Errorf("the old-credential head names %s, not the other handset's seal %s", short(v), short(s2))
	}
	capStorePutHook = nil
	recStaleNothingUnderNewPass(t, objs, mu, name)
}

// T6: the other seal lands inside the bracket, after the re-read and before the recovery ref is buffered (the
// re-point of the scopes runs there). putRef refuses the ref at once, and the recovery must then buffer no head:
// in cap mode a ref refused at the buffer never reaches the flush, so the flush's gate cannot withhold the heads.
func TestRecoverStale_SealBeforeTheRecoveryRefIsBufferedRefuses(t *testing.T) {
	name := "recstalebuffer"
	mn, objs, mu := recStaleProfile(t, name)
	rref := recStaleRref(t, name)
	oldHead, _ := headWriteRef(name, recStaleOldPass)
	s2, land := recStaleHeldBack(t, objs, mu, name, rref, oldHead)
	recoverBeforePublishHook = land

	got := recoverReply(name, mn, recNewPass)

	if got != "ERR-MOVED" {
		t.Errorf("RECOVER answered %q over a seal landed before the recovery ref was buffered; want ERR-MOVED", got)
	}
	if v := storeRef(objs, mu, rref); v != s2 {
		t.Errorf("the recovery ref names %s, not the other handset's seal %s: the recovery overwrote it",
			short(v), short(s2))
	}
	if v := storeRef(objs, mu, oldHead); v != s2 {
		t.Errorf("the old-credential head names %s, not the other handset's seal %s", short(v), short(s2))
	}
	recoverBeforePublishHook = nil
	recStaleNothingUnderNewPass(t, objs, mu, name)
}

// T3: no other writer. The recovery lands: the new passphrase opens the sealed vault, and the recovery ref names
// the new head.
func TestRecoverStale_NoOtherWriterLands(t *testing.T) {
	name := "recstalequiet"
	mn, objs, mu := recStaleProfile(t, name)
	rref := recStaleRref(t, name)
	sealed, err := readSessionVault("s3", name, recStaleOldPass)
	if err != nil {
		t.Fatal(err)
	}

	if err := recoverVault("s3", name, mn, recNewPass); err != nil {
		t.Fatalf("a recovery with no other writer failed: %v", err)
	}

	capReadCache = map[string]capEntry{}
	nv, err := readSessionVault("s3", name, recNewPass)
	if err != nil {
		t.Fatalf("the new passphrase opens nothing after the recovery: %v", err)
	}
	if nv.Manifest != sealed.Manifest {
		t.Error("the recovered vault does not carry the sealed manifest")
	}
	if got, want := storeRef(objs, mu, rref), storeRef(objs, mu, profileRefV2(name, recNewPass)); got != want || got == "" {
		t.Errorf("the recovery ref names %s, the new head %s", short(got), short(want))
	}
}

// T4: a retry after T1, with the other handset quiet, lands and carries the OTHER handset's seal, not the vault
// the first attempt read.
func TestRecoverStale_RetryCarriesTheOtherSeal(t *testing.T) {
	name := "recstaleretry"
	mn, objs, mu := recStaleProfile(t, name)
	rref := recStaleRref(t, name)
	first, err := readSessionVault("s3", name, recStaleOldPass)
	if err != nil {
		t.Fatal(err)
	}
	other := recStaleOtherSealHook(t, name, true)

	if err := recoverVault("s3", name, mn, recNewPass); !errors.Is(err, errRecoverMoved) {
		t.Fatalf("the first attempt returned %v; want errRecoverMoved", err)
	}
	if other.manifest == first.Manifest {
		t.Fatal("test setup: the other handset's seal has the manifest the first attempt read")
	}
	capReadCache = map[string]capEntry{}
	if err := recoverVault("s3", name, mn, recNewPass); err != nil {
		t.Fatalf("the retry, with the other handset quiet, failed: %v", err)
	}

	capReadCache = map[string]capEntry{}
	nv, err := readSessionVault("s3", name, recNewPass)
	if err != nil {
		t.Fatalf("the new passphrase opens nothing after the retry: %v", err)
	}
	if nv.Manifest != other.manifest {
		t.Error("the retry did not carry the other handset's seal: its manifest is not the other seal's")
	}
	if got, want := storeRef(objs, mu, rref), storeRef(objs, mu, profileRefV2(name, recNewPass)); got != want || got == "" {
		t.Errorf("the recovery ref names %s, the new head %s", short(got), short(want))
	}
}

// T5: NOWHERE_MULTIDEVICE=1. readVaultHead skips the recovery ref under the flag, but a recovery must arm it
// anyway: another handset's seal (a real pushProfile under the flag, which republishes the shared recovery ref)
// lands before the bracket, and the recovery still refuses with ERR-MOVED.
func TestRecoverStale_ArmedUnderMultiDevice(t *testing.T) {
	t.Setenv("NOWHERE_MULTIDEVICE", "1")
	name := "recstalemulti"
	mn, objs, mu := recStaleProfile(t, name)
	rref := recStaleRref(t, name)
	other := recStaleOtherSealHook(t, name, false)

	got := recoverReply(name, mn, recNewPass)

	if other.n != 1 {
		t.Fatalf("test setup: the other handset sealed %d times, want 1", other.n)
	}
	if got != "ERR-MOVED" {
		t.Errorf("RECOVER under NOWHERE_MULTIDEVICE answered %q over a seal landed during the recovery; want ERR-MOVED", got)
	}
	if v := storeRef(objs, mu, rref); v != other.rrefVal {
		t.Errorf("the recovery ref names %s, not the other handset's seal %s: the recovery overwrote it",
			short(v), short(other.rrefVal))
	}
	recStaleNothingUnderNewPass(t, objs, mu, name)
}

// The RECOVER codes stay prefix-free with ERR-MOVED among them: the chooser matches ERR-MOVED on equality.
func TestRecoverStale_ReplyIsNoPrefix(t *testing.T) {
	codes := []string{"OK", "BLANK", "ERR-STORE", "ERR-MOVED", "WEAK"}
	for _, a := range codes {
		for _, b := range codes {
			if a != b && strings.HasPrefix(b, a) {
				t.Errorf("RECOVER code %q is a prefix of %q", a, b)
			}
		}
	}
}
