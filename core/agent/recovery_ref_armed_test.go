package main

import (
	"strings"
	"sync"
	"testing"
)

// NWP-20261017-31, backlog row "A publish refused at the flush withholds only the head pointer; the recovery ref
// and the account head's keyslots in the same batch still land". capFlush refuses a pointer only when ITS OWN
// key fails the stale check, so a vault head another process moved between the in-bracket read and the flush
// was refused while the recovery ref from the stale basis, beside it in the batch, still landed. The recovery
// ref is now armed at its own in-bracket value (capHoldRecovery), so the two refuse together.

const (
	movedHead     = "cd"
	movedRecovery = "ef"
)

// recoveryArmEdit is a vault edit that buffers a new head and recovery ref the way SET-PIN and a key enrol do:
// it reads inside the bracket (capReadVaultForEdit), then publishes.
func recoveryArmEdit(name, pass string, dk []byte) capVerdict {
	return capWrite(name, pass, dk, func() {
		v, err := capReadVaultForEdit("s3", "test edit", name, pass, dk, true)
		if err != nil {
			panic(err)
		}
		publishSessionVaultIn("s3", name, pass, v, dk)
	})
}

// moveBothAtFlush moves (name, pass)'s head AND recovery ref in the store as the flush starts uploading, as a
// publish from another process would. Either may be left alone with "".
func moveBothAtFlush(objs map[string][]byte, mu *sync.Mutex, name, pass, rref string, moveHead, moveRec bool) {
	wref, _ := headWriteRef(name, pass)
	var once sync.Once
	capStorePutHook = func(key string, _ []byte) error {
		if strings.HasPrefix(key, "blob/") {
			once.Do(func() {
				mu.Lock()
				if moveHead {
					objs["ref/"+wref] = []byte(strings.Repeat(movedHead, 32))
				}
				if moveRec {
					objs["ref/"+rref] = []byte(strings.Repeat(movedRecovery, 32))
				}
				mu.Unlock()
			})
		}
		return nil
	}
}

func recoveryArmProfile(t *testing.T, name, pass string) (v *vault, dk []byte, objs map[string][]byte, mu *sync.Mutex) {
	t.Helper()
	objs, mu = capLockEnv(t)
	t.Cleanup(clearStaleHit)
	t.Cleanup(func() { capStorePutHook = nil })
	v, dk = sessionVaultForTest(t, name, pass)
	return v, dk, objs, mu
}

func storeRef(objs map[string][]byte, mu *sync.Mutex, ref string) string {
	mu.Lock()
	defer mu.Unlock()
	return strings.TrimSpace(string(objs["ref/"+ref]))
}

// The row's closing test: another process moves the vault head and the recovery ref after the in-bracket read;
// nothing of the batch lands and the verdict is stale.
func TestRecoveryRefArm_MovedHeadLandsNoPointerOfTheBatch(t *testing.T) {
	name, pass := "recarmmoved", "a head moved at the flush"
	v, dk, objs, mu := recoveryArmProfile(t, name, pass)
	wref, _ := headWriteRef(name, pass)
	moveBothAtFlush(objs, mu, name, pass, v.RecoveryRef, true, true)

	vd := recoveryArmEdit(name, pass, dk)

	if !vd.StaleHit {
		t.Error("the verdict is not stale: the caller would report success over a refused batch")
	}
	if got := storeRef(objs, mu, v.RecoveryRef); got != strings.Repeat(movedRecovery, 32) {
		t.Errorf("the recovery ref landed from the stale basis: store holds %q", got)
	}
	if got := storeRef(objs, mu, wref); got != strings.Repeat(movedHead, 32) {
		t.Errorf("the vault head landed over the one the other process published: store holds %q", got)
	}
}

// Control: nothing moved -> both land, on the same blob, and the verdict is clean.
func TestRecoveryRefArm_NothingMovedLandsBoth(t *testing.T) {
	name, pass := "recarmcontrol", "nothing moves"
	v, dk, _, _ := recoveryArmProfile(t, name, pass)

	vd := recoveryArmEdit(name, pass, dk)

	if vd.Refused() {
		t.Fatalf("a flush with nothing moved was refused: %+v", vd)
	}
	_, head, rec := headAndRecovery(t, name, pass)
	if rec != head {
		t.Errorf("the recovery ref names %s while the head names %s", short(rec), short(head))
	}
	if nv, err := readSessionVault("s3", name, pass); err != nil || nv.Version != v.Version+1 {
		t.Errorf("the edit did not land (err %v)", err)
	}
}

// Drift control: a profile whose stored recovery ref differs from its head -- an older publisher left it so --
// and nothing moves during the flush publishes both and is not stale. Arming the recovery ref at the HEAD's
// value would refuse it forever.
func TestRecoveryRefArm_DriftedRecoveryRefStillPublishes(t *testing.T) {
	name, pass := "recarmdrift", "a drifted recovery ref"
	v, dk, objs, mu := recoveryArmProfile(t, name, pass)
	drift := strings.Repeat("ab", 32)
	mu.Lock()
	objs["ref/"+v.RecoveryRef] = []byte(drift)
	mu.Unlock()
	capReadCache = map[string]capEntry{}

	vd := recoveryArmEdit(name, pass, dk)

	if vd.Refused() {
		t.Fatalf("a drifted recovery ref (nothing moved) was refused: %+v", vd)
	}
	_, head, rec := headAndRecovery(t, name, pass)
	if rec != head || rec == drift {
		t.Errorf("the recovery ref was not republished: names %s, head %s", short(rec), short(head))
	}
}

// A publisher that read the vault BEFORE its bracket (a tie, a rotation: capHoldHead) arms the recovery ref at
// the value it read, not at whatever the store holds when the bracket opens: another process publishing in
// between must refuse it. Driven through capHoldRecovery alone, because capHoldHead's early re-read refuses the
// same case first and would hide an arm taken at the wrong value.
func TestRecoveryRefArm_HeldAtTheValueReadNotTheValueNow(t *testing.T) {
	name, pass := "recarmheld", "read before the bracket"
	v, dk, objs, mu := recoveryArmProfile(t, name, pass)
	hd, _, ok := readVaultHead("s3", name, pass)
	if !ok || hd.rref != v.RecoveryRef {
		t.Fatalf("readVaultHead did not read the recovery ref (ok %v, rref %q)", ok, hd.rref)
	}
	mu.Lock()
	objs["ref/"+v.RecoveryRef] = []byte(strings.Repeat(movedRecovery, 32)) // another process publishes meanwhile
	mu.Unlock()
	capReadCache = map[string]capEntry{}

	vd := capWrite(name, pass, dk, func() {
		capHoldRecovery("test hold", hd)
		cur, err := readSessionVault("s3", name, pass)
		if err != nil {
			panic(err)
		}
		publishSessionVaultIn("s3", name, pass, cur, dk)
	})

	if !vd.StaleHit {
		t.Error("the recovery ref landed over a publish made after it was read")
	}
	if got := storeRef(objs, mu, v.RecoveryRef); got != strings.Repeat(movedRecovery, 32) {
		t.Errorf("the recovery ref was overwritten: store holds %q", got)
	}
}
