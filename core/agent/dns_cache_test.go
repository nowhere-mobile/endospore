package main

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

// NWP-20260822-06. installResolver runs ONCE PER PROCESS, and the restores are separate short-lived forks
// (roamd runs `NOWHERE_PHASE=media "$AGENT" restore ...` per scope). Each begins with an empty cache, so
// NWP-20260822-04's "keep the last good list" -- a property of a process that already HAS one -- could never
// help them: their first refreshNet went straight to the cold-start public fallback. That is precisely why the
// resolver fix could not move #80. This is the cross-process half.
func TestDNSCacheRoundTrip(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("NOWHERE_STATE", dir)

	if _, _, ok := loadDNSCache(); ok {
		t.Fatal("no file yet, but loadDNSCache reported ok")
	}

	want := []string{"192.0.2.53:53", "198.51.100.53:53"}
	saveDNSCache(want, "", nil, "")
	got, age, ok := loadDNSCache()
	if !ok || !reflect.DeepEqual(got, want) {
		t.Fatalf("round trip = %v (ok=%v), want %v", got, ok, want)
	}
	if age > time.Minute {
		t.Errorf("a just-written cache reported age %v", age)
	}
}

// Every degenerate input must read as "no cache", never as an empty-but-usable list -- a process that adopted
// an empty list would have no servers at all and no fallback, which is worse than starting cold.
func TestDNSCacheRejectsJunk(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("NOWHERE_STATE", dir)

	for _, junk := range []string{"", "\n", "   \n\t\n"} {
		if err := os.WriteFile(filepath.Join(dir, dnsCacheFile), []byte(junk), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, _, ok := loadDNSCache(); ok {
			t.Errorf("cache content %q must read as absent", junk)
		}
	}
	// An unset state dir (unit tests, a CLI run) must also be a clean miss, never a panic.
	t.Setenv("NOWHERE_STATE", "")
	if _, _, ok := loadDNSCache(); ok {
		t.Error("an unset NOWHERE_STATE must read as absent")
	}
	saveDNSCache([]string{"1.2.3.4:53"}, "", nil, "") // must not panic
}

// saveDNSCache must never publish an empty list: doing so would hand every later fork a file that reads as
// junk, which is only harmless because loadDNSCache rejects it. Belt and braces on the writer side too.
func TestDNSCacheNeverPublishesEmpty(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("NOWHERE_STATE", dir)
	saveDNSCache(nil, "", nil, "")
	if _, err := os.Stat(filepath.Join(dir, dnsCacheFile)); !os.IsNotExist(err) {
		t.Fatal("saveDNSCache(nil) created a file; it must be a no-op")
	}
}

// The seed is a CACHE, not a discovery, and since NWP-20261119-25 it seeds at ANY age. The file is per-boot tmpfs,
// and NWP-20261113-19 retired the age rule for the daemon; a fork that kept applying it started cold after any idle
// spell and fell to the public fallback in a switch window. The interface key, not age, bounds a seed now.
func TestDNSCacheSeedIgnoresAge(t *testing.T) {
	resetResolverState(t)
	dir := t.TempDir()
	t.Setenv("NOWHERE_STATE", dir)
	f := filepath.Join(dir, dnsCacheFile)
	if err := os.WriteFile(f, []byte("9.9.9.9:53\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	// Back-date it well past dnsKeepMax; the seed must still take it, with its honest age.
	old := time.Now().Add(-10 * dnsKeepMax)
	if err := os.Chtimes(f, old, old); err != nil {
		t.Fatal(err)
	}

	seedDNSFromCache()

	netMu.Lock()
	seeded := append([]string(nil), dnsServers...)
	goodAt := dnsGoodAt
	netMu.Unlock()
	if !reflect.DeepEqual(seeded, []string{"9.9.9.9:53"}) {
		t.Fatalf("a cache older than dnsKeepMax (%v) was not seeded (got %v); a fork seeds a cache of any age "+
			"(NWP-20261119-25)", dnsKeepMax, seeded)
	}
	if a := time.Since(goodAt); a < 10*dnsKeepMax-time.Second {
		t.Fatalf("the seed's dnsGoodAt is %v old; it must carry the file's honest age (~%v)", a, 10*dnsKeepMax)
	}
}
