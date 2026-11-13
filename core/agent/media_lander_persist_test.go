package main

// NWP-20261130-17: the landed roster is written per landing, before the next fetch (docs/media-after-gate.md §5 and
// §6's "mediad dies" row). TestMediaLander_L13, run and mutated by test-media-lander.sh with the S4a cases.

import (
	"os"
	"testing"
)

// mlKilled is the panic value that stands for a kill of mediad: nothing after it runs in landBackground.
type mlKilled struct{}

// landUntilKilled runs the lander until a hook panics with mlKilled. The panic skips every flush that a normal return
// or stop would do; any other panic is re-raised.
func (r *mlRun) landUntilKilled() (killed bool) {
	r.t.Helper()
	defer func() {
		if v := recover(); v != nil {
			if _, ok := v.(mlKilled); !ok {
				panic(v)
			}
			killed = true
		}
	}()
	r.land()
	return false
}

// L13a: the user deletes a landed file while the next fetch runs, then mediad dies. The restart fetches nothing for
// the deleted file and does not resurrect it; the rest still land.
func TestMediaLander_L13a_ADeletionDuringTheNextFetchSurvivesAKill(t *testing.T) {
	first, second, third := "DCIM/first.jpg", "DCIM/second.jpg", "DCIM/third.jpg"
	r := mlNew(t, []string{first, second, third}, map[string]int64{first: 3000, second: 2000, third: 1000})
	r.hook = func(rel string) ([]byte, error, bool) {
		if rel == second {
			if err := os.Remove(r.path(first)); err != nil {
				t.Fatalf("the user's deletion of the first landing: %v", err)
			}
			panic(mlKilled{})
		}
		return nil, nil, false
	}
	if !r.landUntilKilled() {
		t.Fatal("the run was not killed: the fixture did not fetch the second rel")
	}
	mlWant(t, r.fetched, []string{first, second}, "the first run's fetches")

	r.mlRestart()
	r.hook = nil
	c := r.land()
	mlWant(t, r.fetched, []string{second, third}, "the restart's fetches (the deleted landing is not fetched)")
	mlGone(t, r.path(first))
	if c.landed != 2 || c.pending != 0 {
		t.Fatalf("the restart's counts: %+v", c)
	}
	mlWant(t, mlRoster(t, "mlref"), mlDigests(mlDK, first, second, third), "the roster after the restart")
}

// L13b: a present-skip's digest is written before the next fetch too: the app's file is deleted during that fetch,
// mediad dies, and the restart does not place the store's copy where the app removed its own.
func TestMediaLander_L13b_ASkipIsRecordedBeforeTheNextFetch(t *testing.T) {
	app, next := "DCIM/app.jpg", "DCIM/next.jpg"
	r := mlNew(t, []string{app, next}, map[string]int64{app: 2000, next: 1000})
	if err := os.MkdirAll(r.path("DCIM"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(r.path(app), []byte("the app's own bytes"), 0o600); err != nil {
		t.Fatal(err)
	}
	r.hook = func(rel string) ([]byte, error, bool) {
		if rel == next {
			if err := os.Remove(r.path(app)); err != nil {
				t.Fatalf("the app's deletion of its file: %v", err)
			}
			panic(mlKilled{})
		}
		return nil, nil, false
	}
	if !r.landUntilKilled() {
		t.Fatal("the run was not killed: the fixture did not fetch the second rel")
	}
	r.mlRestart()
	r.hook = nil
	r.land()
	mlWant(t, r.fetched, []string{next}, "the restart's fetches (the skipped rel is not fetched)")
	mlGone(t, r.path(app))
}

// L13c: appendLandedRoster appends one line, keeps 0600, is a no-op with receipts off, and refuses a link at the
// roster's path.
func TestMediaLander_L13c_AppendLandedRoster(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	appendLandedRoster("mla", mlDK, "DCIM/a.jpg")
	recordLandedRoster("mla", mlDK, []string{"DCIM/b.jpg"})
	appendLandedRoster("mla", mlDK, "DCIM/c.jpg")
	appendLandedRoster("mla", mlDK, "DCIM/a.jpg")
	mlWant(t, mlRoster(t, "mla"), mlDigests(mlDK, "DCIM/a.jpg", "DCIM/b.jpg", "DCIM/c.jpg"), "the appended roster")
	if st, err := os.Lstat(landedRosterFile("mla")); err != nil || st.Mode().Perm() != 0o600 {
		t.Fatalf("the roster's mode: %v, %v", st, err)
	}

	elsewhere := t.TempDir() + "/elsewhere"
	if err := os.Symlink(elsewhere, landedRosterFile("mll")); err != nil {
		t.Fatal(err)
	}
	appendLandedRoster("mll", mlDK, "DCIM/a.jpg")
	if _, err := os.Lstat(elsewhere); !os.IsNotExist(err) {
		t.Fatalf("the append followed a link at the roster's path: %v", err)
	}

	appendLandedRoster("", mlDK, "DCIM/a.jpg")
	t.Setenv("NOWHERE_STATE", "")
	appendLandedRoster("mla", mlDK, "DCIM/a.jpg") // nowhere to write: no panic
	if loadLandedRoster("mla", mlDK)("DCIM/a.jpg") {
		t.Fatal("receipts off: nothing can read as landed")
	}
}
