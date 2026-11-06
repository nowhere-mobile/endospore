package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"testing"
)

// The CREATE throttle's bucket is published by a synced temp file and a rename (NWP-20261118-23): a save that fails
// before the rename -- a power cut, a full /data -- must leave the previous bucket on disk, never an empty or cut
// file, because enrollAllow reads a file that does not parse as an unseen device with a full bucket.

// failEnrollSync makes confFileSync fail until the test ends and returns a pointer to its call count.
func failEnrollSync(t *testing.T) *int {
	t.Helper()
	old := confFileSync
	calls := 0
	confFileSync = func(*os.File) error { calls++; return errors.New("injected sync failure") }
	t.Cleanup(func() { confFileSync = old })
	return &calls
}

func assertNoEnrollTmp(t *testing.T, state string) {
	t.Helper()
	if _, err := os.Stat(state + ".tmp"); !os.IsNotExist(err) {
		t.Fatalf("%s.tmp is left behind (stat err %v)", state, err)
	}
}

// A failed save on an allowed create keeps the bucket from the create before it.
func TestEnrollFailedSaveKeepsOldBucket(t *testing.T) {
	state := setEnrollEnv(t, "5", "3600")
	for i := 0; i < 2; i++ {
		if ok, _ := enrollAllow(); !ok {
			t.Fatalf("create %d denied with a fresh bucket of 5", i+1)
		}
	}
	before, err := os.ReadFile(state)
	if err != nil || len(before) == 0 {
		t.Fatalf("no bucket after two creates: %q, %v", before, err)
	}
	calls := failEnrollSync(t)
	if ok, _ := enrollAllow(); !ok {
		t.Fatal("the third create was denied: a failed save must not change the decision of the call")
	}
	if *calls < 1 {
		t.Error("saveEnroll did not publish through the synced temp file (confFileSync was never called)")
	}
	after, _ := os.ReadFile(state)
	if !bytes.Equal(before, after) {
		t.Errorf("a failed save changed the bucket on disk:\nbefore %q\nafter  %q", before, after)
	}
	assertNoEnrollTmp(t, state)
}

// A failed save on a denied create keeps the previous bucket too: the denial also saves an advanced timestamp.
func TestEnrollFailedSaveOnDeniedCreateKeepsOldBucket(t *testing.T) {
	state := setEnrollEnv(t, "2", "3600")
	for i := 0; i < 2; i++ {
		if ok, _ := enrollAllow(); !ok {
			t.Fatalf("create %d denied with a fresh bucket of 2", i+1)
		}
	}
	// Age the bucket by 60 s, so the denied call saves a CHANGED bucket (a new TS and a small refill) even when
	// every call lands in the same second.
	raw, err := os.ReadFile(state)
	if err != nil {
		t.Fatal(err)
	}
	var b enrollBucket
	if err := json.Unmarshal(raw, &b); err != nil || b.TS <= 0 {
		t.Fatalf("bucket %q does not parse: %v", raw, err)
	}
	b.TS -= 60
	raw, _ = json.Marshal(b)
	if err := os.WriteFile(state, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	before, _ := os.ReadFile(state)
	calls := failEnrollSync(t)
	if ok, retry := enrollAllow(); ok || retry < 1 {
		t.Fatalf("the third create got (%v, %d), want a denial with a retry", ok, retry)
	}
	if *calls < 1 {
		t.Error("the denial's save did not publish through the synced temp file (confFileSync was never called)")
	}
	after, _ := os.ReadFile(state)
	if !bytes.Equal(before, after) {
		t.Errorf("a failed save on a denial changed the bucket on disk:\nbefore %q\nafter  %q", before, after)
	}
	assertNoEnrollTmp(t, state)
}

// A good save goes through the synced publish, is 0600, holds the spent bucket and leaves no temp file.
func TestEnrollSavePublishesDurably(t *testing.T) {
	state := setEnrollEnv(t, "5", "3600")
	old := confFileSync
	calls := 0
	confFileSync = func(f *os.File) error { calls++; return old(f) }
	t.Cleanup(func() { confFileSync = old })
	if ok, _ := enrollAllow(); !ok {
		t.Fatal("the first create was denied with a fresh bucket of 5")
	}
	if calls < 1 {
		t.Error("saveEnroll did not publish through the synced temp file (confFileSync was never called)")
	}
	fi, err := os.Stat(state)
	if err != nil {
		t.Fatal(err)
	}
	if perm := fi.Mode().Perm(); perm != 0o600 {
		t.Fatalf("bucket mode %o, want 600", perm)
	}
	raw, _ := os.ReadFile(state)
	var b enrollBucket
	if err := json.Unmarshal(raw, &b); err != nil {
		t.Fatalf("bucket %q does not parse: %v", raw, err)
	}
	if b.Tokens < 3.99 || b.Tokens > 4.01 || b.TS <= 0 {
		t.Fatalf("bucket %+v, want 4 tokens and a timestamp", b)
	}
	assertNoEnrollTmp(t, state)
}
