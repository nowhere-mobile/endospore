package main

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

// NWP-20261113-19 (backlog row "The resolver no longer discards a known-good nameserver list (`NWP-20260822-04`)"):
// a kept list is dropped after dnsKeepMax of CONTINUOUS empty discovery, measured from the first empty one
// (dnsEmptySince), not when the last good discovery is dnsKeepMax old. Device evidence (lynx 2026102201,
// NWP-20261024-18): an idle daemon's first empty discovery in a 3 s Wi-Fi blip fell to the public fallback.
//
// The egress line is change-only, so a kept list that equals the current one prints nothing; these tests compare
// dnsServers and refuse a PUBLIC-FALLBACK line instead of asserting a `src=kept` line.

// the switch window: a network is described, but there is no default marker and no resolver anywhere
const keepStreakEmptyDump = `NetworkAgentInfo{network{121} lp{{InterfaceName: wlan0 ServerAddress: /192.168.4.1}}`

// a different default network (rmnet17) whose dump names no resolvers
const keepStreakOtherIfaceDump = "Active default network: 104\nNetworkAgentInfo{network{104} lp{{InterfaceName: rmnet17 MTU: 1430}}"

func ksServers() []string {
	netMu.Lock()
	defer netMu.Unlock()
	return append([]string(nil), dnsServers...)
}

func ksEmptySince() time.Time {
	netMu.Lock()
	defer netMu.Unlock()
	return dnsEmptySince
}

func ksSet(fn func()) {
	netMu.Lock()
	fn()
	netMu.Unlock()
}

func ksDump(d string) { dumpsysConnectivity = func() string { return d } }

// ksGood runs one refresh on the validated Wi-Fi dump and returns the discovered list.
func ksGood(t *testing.T) []string {
	t.Helper()
	ksDump(sampleDumpsysDefaultWifi)
	refreshNet(false)
	good := ksServers()
	if len(good) == 0 || slices.Equal(good, fallbackAddrs()) {
		t.Fatalf("a good discovery yielded %v; want the Wi-Fi network's own resolvers", good)
	}
	if !ksEmptySince().IsZero() {
		t.Fatalf("dnsEmptySince is set after a good discovery")
	}
	return good
}

func ksSetup(t *testing.T) {
	t.Helper()
	resetResolverState(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
}

// (a) A daemon idle for 5 minutes keeps its list across the first empty discovery of a switch window, and a second
// empty discovery does not move the start of the run.
func TestKeepStreak_IdleDaemonKeepsAcrossFirstEmpty(t *testing.T) {
	ksSetup(t)
	good := ksGood(t)
	ksSet(func() { dnsGoodAt = time.Now().Add(-5 * time.Minute) })
	ksDump(keepStreakEmptyDump)
	log := captureStderr(t, func() { refreshNet(false) })
	if got := ksServers(); !slices.Equal(got, good) {
		t.Fatalf("an idle daemon's first empty discovery replaced the known-good list %v with %v; log:\n%s", good, got, log)
	}
	if strings.Contains(log, "PUBLIC-FALLBACK") {
		t.Fatalf("an idle daemon's first empty discovery logged the public fallback:\n%s", log)
	}
	start := ksEmptySince()
	if start.IsZero() || time.Since(start) > 5*time.Second {
		t.Fatalf("dnsEmptySince = %v after an empty discovery; want the time of that discovery", start)
	}
	refreshNet(false)
	if got := ksEmptySince(); !got.Equal(start) {
		t.Fatalf("a second empty discovery moved the run's start from %v to %v", start, got)
	}
	if got := ksServers(); !slices.Equal(got, good) {
		t.Fatalf("a second empty discovery inside the window dropped the list: %v", got)
	}
}

// (b) An empty run longer than dnsKeepMax is not a transient: the next refresh adopts the public fallback.
func TestKeepStreak_LongEmptyRunFallsBack(t *testing.T) {
	ksSetup(t)
	ksGood(t)
	ksDump(keepStreakEmptyDump)
	refreshNet(false)
	ksSet(func() { dnsEmptySince = time.Now().Add(-2 * dnsKeepMax) })
	log := captureStderr(t, func() { refreshNet(false) })
	if got := ksServers(); !slices.Equal(got, fallbackAddrs()) {
		t.Fatalf("an empty run of 2 x dnsKeepMax kept %v; want the public fallback %v", got, fallbackAddrs())
	}
	if !strings.Contains(log, "src=PUBLIC-FALLBACK") {
		t.Fatalf("the fallback was not logged as src=PUBLIC-FALLBACK:\n%s", log)
	}
}

// (c) A good discovery ends the run, so a later empty discovery starts a new one rather than inheriting a stale start.
func TestKeepStreak_GoodDiscoveryEndsTheRun(t *testing.T) {
	ksSetup(t)
	ksGood(t)
	ksDump(keepStreakEmptyDump)
	refreshNet(false)
	if ksEmptySince().IsZero() {
		t.Fatalf("dnsEmptySince stayed zero after an empty discovery")
	}
	ksSet(func() { dnsEmptySince = time.Now().Add(-2 * dnsKeepMax) })
	good := ksGood(t) // fails if the good discovery left dnsEmptySince set
	ksSet(func() { dnsGoodAt = time.Now().Add(-5 * time.Minute) })
	ksDump(keepStreakEmptyDump)
	refreshNet(false)
	if got := ksServers(); !slices.Equal(got, good) {
		t.Fatalf("after a good discovery, the first empty one dropped the list %v for %v", good, got)
	}
}

// (d) A forced refresh (every cached address just failed to dial) drops the keep at once, however young the run.
func TestKeepStreak_ForceDropsAtOnce(t *testing.T) {
	ksSetup(t)
	good := ksGood(t)
	ksDump(keepStreakEmptyDump)
	refreshNet(false)
	if got := ksServers(); !slices.Equal(got, good) {
		t.Fatalf("the first empty discovery dropped the list: %v", got)
	}
	refreshNet(true)
	if got := ksServers(); !slices.Equal(got, fallbackAddrs()) {
		t.Fatalf("a forced refresh kept %v; want the public fallback", got)
	}
}

// (e) A change of egress interface drops the keep at once: the list was never validated for the new network.
func TestKeepStreak_IfaceChangeDropsAtOnce(t *testing.T) {
	ksSetup(t)
	ksGood(t)
	ksDump(keepStreakOtherIfaceDump)
	refreshNet(false)
	if got := ksServers(); !slices.Equal(got, fallbackAddrs()) {
		t.Fatalf("an interface change kept %v; want the public fallback", got)
	}
}

// (f) A list seeded from a 15 s old cache file survives this process's first empty discovery, even once the seed is
// more than dnsKeepMax since its discovery, and is dropped when the empty run passes dnsKeepMax.
func TestKeepStreak_SeededListFollowsTheRun(t *testing.T) {
	resetResolverState(t)
	dir := t.TempDir()
	t.Setenv("NOWHERE_STATE", dir)
	seed := []string{"192.0.2.53:53"} // TEST-NET-1: no real resolver
	saveDNSCache(seed, "", nil, "")
	old := time.Now().Add(-15 * time.Second)
	if err := os.Chtimes(filepath.Join(dir, dnsCacheFile), old, old); err != nil {
		t.Fatal(err)
	}
	seedDNSFromCache()
	if got := ksServers(); !slices.Equal(got, seed) {
		t.Fatalf("a 15 s old cache was not seeded: %v", got)
	}
	if !ksEmptySince().IsZero() {
		t.Fatalf("seedDNSFromCache set dnsEmptySince")
	}
	ksDump(keepStreakEmptyDump)
	refreshNet(false)
	if got := ksServers(); !slices.Equal(got, seed) {
		t.Fatalf("the seed did not survive this process's first empty discovery: %v", got)
	}
	ksSet(func() { dnsGoodAt = dnsGoodAt.Add(-10 * time.Second) }) // seed now ~25 s since discovery
	refreshNet(false)
	if got := ksServers(); !slices.Equal(got, seed) {
		t.Fatalf("a seed older than dnsKeepMax was dropped though the empty run is seconds old: %v", got)
	}
	ksSet(func() { dnsEmptySince = time.Now().Add(-dnsKeepMax - time.Second) })
	refreshNet(false)
	if got := ksServers(); !slices.Equal(got, fallbackAddrs()) {
		t.Fatalf("the seed outlived an empty run of more than dnsKeepMax: %v", got)
	}
}
