package main

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// NWP-20261019-10, backlog row "`ref/<RecoveryRef>` is LAST-WRITER-WINS and the compare-and-swap guard cannot
// see it". recovery_ref_armed_test.go pins the arm for in-bracket edits (capWrite); these drive the REAL
// pushProfile seal of the bare vault, which arms the recovery ref itself at expectRef(v.RecoveryRef, ...).
// Each case seals once so the profile has a head and recovery ref, then seals again while a second handset
// moves the pointers as the flush starts uploading. Flag off (NOWHERE_MULTIDEVICE unset), cap mode.
//
// The writers that move the head without a seal (dropBillPrev / dropBillRetag) publish the recovery ref
// beside it too; recovery_ref_billdrop_test.go pins that, sequentially and behind another bracket.

func sealBareVault(t *testing.T, name, pass string) {
	t.Helper()
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "f.txt"), []byte("seal payload"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile("s3", name, pass, src)
}

// sealArmProfile returns a profile sealed once, so its head and recovery ref name a sealed vault.
func sealArmProfile(t *testing.T, name, pass string) (v *vault, prev, wref string, objs map[string][]byte, mu *sync.Mutex) {
	t.Helper()
	v, _, objs, mu = recoveryArmProfile(t, name, pass)
	sealBareVault(t, name, pass)
	if sealStaleHit {
		t.Fatal("the first seal, with nothing moved, was refused")
	}
	wref, _ = headWriteRef(name, pass)
	_, prev, _ = headAndRecovery(t, name, pass)
	return v, prev, wref, objs, mu
}

// Handset B's seal moves both pointers while A's seal is in flight: A's head AND recovery ref are refused, so
// the recovery pointer cannot name A's vault while the head names B's.
func TestRecoveryRefArm_SealBothMoved(t *testing.T) {
	name, pass := "recarmsealboth", "two seals interleave"
	v, prev, wref, objs, mu := sealArmProfile(t, name, pass)
	moveBothAtFlush(objs, mu, name, pass, v.RecoveryRef, true, true)

	sealBareVault(t, name, pass)

	if !sealStaleHit {
		t.Error("the seal was not judged stale: the caller would report success over a refused seal")
	}
	if got := storeRef(objs, mu, wref); got != strings.Repeat(movedHead, 32) {
		t.Errorf("the head landed over the one the other handset published: store holds %q", got)
	}
	if got := storeRef(objs, mu, v.RecoveryRef); got != strings.Repeat(movedRecovery, 32) {
		t.Errorf("the recovery ref names this seal's vault, not the other handset's: store holds %q", got)
	}
	if prev == strings.Repeat(movedHead, 32) {
		t.Fatal("test setup: the moved value equals the sealed head")
	}
}

// The recovery ref alone moved: the seal's arm is judged at the recovery ref's OWN value, so its write is
// refused while the head, which did not move, lands.
func TestRecoveryRefArm_SealRecoveryOnlyMoved(t *testing.T) {
	name, pass := "recarmsealrec", "only the recovery ref moves"
	v, prev, wref, objs, mu := sealArmProfile(t, name, pass)
	moveBothAtFlush(objs, mu, name, pass, v.RecoveryRef, false, true)

	sealBareVault(t, name, pass)

	if !sealStaleHit {
		t.Error("the seal was not judged stale: its recovery ref landed over a publish made after it was read")
	}
	if got := storeRef(objs, mu, v.RecoveryRef); got != strings.Repeat(movedRecovery, 32) {
		t.Errorf("the recovery ref was overwritten by the seal: store holds %q", got)
	}
	if got := storeRef(objs, mu, wref); got == prev || got == "" {
		t.Errorf("the head did not land (still %q)", got)
	}
}

// Control: nothing moved -> head and recovery ref both name this seal's new vault, which names that ref.
func TestRecoveryRefArm_SealNothingMovedLandsBoth(t *testing.T) {
	name, pass := "recarmsealctl", "nothing moves"
	v, prev, _, _, _ := sealArmProfile(t, name, pass)

	sealBareVault(t, name, pass)

	if sealStaleHit {
		t.Error("a seal with nothing moved was judged stale")
	}
	nv, head, recv := headAndRecovery(t, name, pass)
	if head == prev {
		t.Error("the seal did not publish a new head")
	}
	if recv != head {
		t.Errorf("the recovery ref names %s while the head names %s", short(recv), short(head))
	}
	if nv.RecoveryRef != v.RecoveryRef {
		t.Errorf("the new vault names recovery ref %s, not the one written (%s)", short(nv.RecoveryRef), short(v.RecoveryRef))
	}
}
