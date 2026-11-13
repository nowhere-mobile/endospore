package main

// NWP-20261130-17: the lander's corrupt roster (docs/media-after-gate.md §6: a corrupt chunk is "not retried this
// session", and §6's "mediad dies" row: the lander resumes as after a cold lock). TestMediaLander_L12, run and mutated by
// test-media-lander.sh with the S4a cases.

import (
	"errors"
	"os"
	"slices"
	"strings"
	"testing"
)

// mlCorrupt is the corrupt roster's lines, for an exact comparison.
func mlCorrupt(t *testing.T, ref string) []string {
	t.Helper()
	var out []string
	for d := range readWalkedDigests(corruptRosterFile(ref)) {
		out = append(out, d)
	}
	slices.Sort(out)
	return out
}

// mlRestart clears the per-process seams' records, as a new mediad starts with nothing in memory.
func (r *mlRun) mlRestart() {
	r.fetched, r.damaged, r.sleeps, r.in.stop = nil, nil, nil, nil
}

// L12a: a corrupt rel is fetched once in the session. A restart of mediad fetches nothing for it and reports it again;
// its digest is in the corrupt roster and never in the landed one, so the seal still carries it.
func TestMediaLander_L12a_ACorruptRelIsNotFetchedAfterARestart(t *testing.T) {
	bad := "DCIM/bad.jpg"
	r := mlNew(t, []string{bad, "Pictures/ok.png"}, nil)
	r.hook = func(rel string) ([]byte, error, bool) {
		if rel == bad {
			return nil, errors.New("fetch span [0,1): corrupt chunk in store: blob/c0"), true
		}
		return nil, nil, false
	}
	c := r.land()
	mlAssertDamaged(t, r, bad, 1, c)
	mlWant(t, mlCorrupt(t, "mlref"), mlDigests(mlDK, bad), "the corrupt roster after the first run")

	r.mlRestart()
	var started []string
	r.in.onStart = func(p []string) { started = slices.Clone(p) }
	c = r.land()
	mlWant(t, r.fetched, nil, "the restart's fetches")
	mlWant(t, r.damaged, []string{bad}, "the restart's onDamaged")
	mlWant(t, started, []string{bad}, "the restart's pending set (bgLander's count of files left needs the rel)")
	if c.damaged != 1 || c.landed != 0 || c.pending != 0 {
		t.Fatalf("the restart's counts: %+v", c)
	}
	if loadLandedRoster("mlref", mlDK)(bad) {
		t.Fatal("a corrupt rel's digest is in the landed roster: the seal would drop it as a deletion")
	}
	mlGone(t, r.path(bad))
	mlWant(t, mlCorrupt(t, "mlref"), mlDigests(mlDK, bad), "the corrupt roster after the restart")
}

// L12b: a transient error is not corrupt: the restart fetches the rel again and lands it.
func TestMediaLander_L12b_ATransientRelIsFetchedAfterARestart(t *testing.T) {
	rel := "DCIM/later.jpg"
	r := mlNew(t, []string{rel}, nil)
	r.maxWait = 1
	r.hook = func(string) ([]byte, error, bool) { return nil, errors.New("dial tcp: i/o timeout"), true }
	if c := r.land(); c.pending != 1 || c.damaged != 0 {
		t.Fatalf("first run: %+v", c)
	}
	mlWant(t, mlCorrupt(t, "mlref"), nil, "the corrupt roster after a transient error")

	r.mlRestart()
	r.hook = nil
	if c := r.land(); c.landed != 1 {
		t.Fatalf("the restart: %+v", c)
	}
	mlWant(t, r.fetched, []string{rel}, "the restart's fetches")
}

// L12c: the next sign-in tries again. roamd parks the receipts directory at a sign-in, so the corrupt roster is gone and
// the rel is fetched once more.
func TestMediaLander_L12c_ASignInTriesACorruptRelAgain(t *testing.T) {
	bad := "DCIM/bad.jpg"
	r := mlNew(t, []string{bad}, nil)
	r.hook = func(string) ([]byte, error, bool) {
		return nil, errors.New("fetch span [0,1): corrupt chunk in store: blob/c0"), true
	}
	r.land()
	if err := os.RemoveAll(restoreReceiptDir()); err != nil {
		t.Fatal(err)
	}
	r.mlRestart()
	r.hook = nil
	if c := r.land(); c.landed != 1 || c.damaged != 0 {
		t.Fatalf("after a sign-in: %+v", c)
	}
	mlWant(t, r.fetched, []string{bad}, "the fetches after a sign-in")
}

// L12d: the corrupt roster holds digests only, never a name, and is 0600.
func TestMediaLander_L12d_TheCorruptRosterHoldsNoName(t *testing.T) {
	bad := "DCIM/a-secret-name.jpg"
	r := mlNew(t, []string{bad}, nil)
	r.hook = func(string) ([]byte, error, bool) {
		return nil, errors.New("fetch span [0,1): corrupt chunk in store: blob/c0"), true
	}
	r.land()
	f := corruptRosterFile("mlref")
	b := mlRead(t, f)
	if strings.Contains(b, "secret") || strings.Contains(b, "DCIM") {
		t.Fatalf("the corrupt roster names the file: %q", b)
	}
	st, err := os.Stat(f)
	if err != nil {
		t.Fatal(err)
	}
	if st.Mode().Perm() != 0o600 {
		t.Fatalf("the corrupt roster is %v, want 0600", st.Mode().Perm())
	}
}
