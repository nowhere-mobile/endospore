package main

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

// NWP-20261119-25 (backlog row "The resolver no longer discards a known-good nameserver list (`NWP-20260822-04`)"):
// a short-lived fork seeds the daemon's .dnscache at ANY age. The old rule refused a file older than dnsKeepMax,
// and the daemon rewrites the file only on a non-empty discovery, so a fork born after an idle spell started cold
// and logged `src=PUBLIC-FALLBACK (discovery empty, nothing cached)` in a switch window (lynx 2026102201). The
// cache now records its egress interface, and refreshNet drops the seed when the fork's own discovery names
// another one. A seeded fork has netIface "", so the existing interface-change key cannot do that for it.
//
// Every seed here is 10 x dnsKeepMax old, so each test's seed precondition also fails on the old age gate.

// the switch window on Wi-Fi: wlan0 is the default network, and no resolver is named anywhere
const rsiWlanEmptyDump = "Active default network: 121\nNetworkAgentInfo{network{121} lp{{InterfaceName: wlan0 MTU: 1500}}"

// the switch window on cellular: rmnet0 is the default network, and no resolver is named anywhere
const rsiRmnetEmptyDump = "Active default network: 104\nNetworkAgentInfo{network{104} lp{{InterfaceName: rmnet0 MTU: 1430}}"

// no default network at all: the interface is unknown ("")
const rsiNoIfaceEmptyDump = `NetworkAgentInfo{network{121} lp{{InterfaceName: wlan0 ServerAddress: /192.168.4.1}}`

var rsiSeedList = []string{"192.0.2.53:53"} // TEST-NET-1: no real resolver

func rsiSetup(t *testing.T) string {
	t.Helper()
	resetResolverState(t)
	dir := t.TempDir()
	t.Setenv("NOWHERE_STATE", dir)
	return dir
}

func rsiState() (servers []string, seedIface string, goodAt time.Time) {
	netMu.Lock()
	defer netMu.Unlock()
	return append([]string(nil), dnsServers...), dnsSeedIface, dnsGoodAt
}

func rsiDump(d string) { dumpsysConnectivity = func() string { return d } }

// rsiSeed writes a cache discovered on iface, back-dates it by age and seeds this process from it.
func rsiSeed(t *testing.T, dir, iface string, age time.Duration) string {
	t.Helper()
	saveDNSCache(rsiSeedList, "", nil, iface)
	old := time.Now().Add(-age)
	if err := os.Chtimes(filepath.Join(dir, dnsCacheFile), old, old); err != nil {
		t.Fatal(err)
	}
	log := captureStderr(t, seedDNSFromCache)
	if got, _, _ := rsiState(); !slices.Equal(got, rsiSeedList) {
		t.Fatalf("a cache %v old was not seeded (got %v); a fork seeds a cache of any age; log:\n%s", age, got, log)
	}
	return log
}

func TestResolverSeed_AnyAgeIsSeeded(t *testing.T) {
	dir := rsiSetup(t)
	log := rsiSeed(t, dir, "wlan0", 10*dnsKeepMax)
	_, seedIface, goodAt := rsiState()
	if seedIface != "wlan0" {
		t.Fatalf("dnsSeedIface = %q after a seed discovered on wlan0", seedIface)
	}
	if a := time.Since(goodAt); a < 10*dnsKeepMax-time.Second {
		t.Fatalf("the seed's dnsGoodAt is %v old; it must carry the file's honest age (~%v)", a, 10*dnsKeepMax)
	}
	if !strings.Contains(log, "seeded 1 server(s) from the shared cache") {
		t.Fatalf("the seed did not log its line:\n%s", log)
	}
}

func TestResolverSeed_IfaceLineRoundTrips(t *testing.T) {
	dir := rsiSetup(t)
	f := filepath.Join(dir, dnsCacheFile)
	saveDNSCache([]string{"192.0.2.53:53", "198.51.100.53:53"}, "dns.example", []string{"194.242.2.2"}, "wlan0")
	addrs, dotHost, _, _, ok, iface := readDNSCache()
	if !ok || iface != "wlan0" || dotHost != "dns.example" {
		t.Fatalf("readDNSCache = ok %v iface %q dotHost %q; want ok, wlan0, dns.example", ok, iface, dotHost)
	}
	if !slices.Equal(addrs, []string{"192.0.2.53:53", "198.51.100.53:53"}) {
		t.Fatalf("readDNSCache servers = %v; the iface line must never read as a server", addrs)
	}

	back := time.Now().Add(-time.Minute)
	if err := os.Chtimes(f, back, back); err != nil {
		t.Fatal(err)
	}
	saveDoTCache("dns.example", []string{"194.242.2.2"})
	_, dotHost, _, _, _, iface = readDNSCache()
	if iface != "wlan0" {
		t.Fatalf("saveDoTCache dropped the iface line (iface now %q)", iface)
	}
	if dotHost != "dns.example" {
		t.Fatalf("saveDoTCache did not keep the DoT line (dotHost now %q)", dotHost)
	}
	fi, err := os.Stat(f)
	if err != nil {
		t.Fatal(err)
	}
	if a := time.Since(fi.ModTime()); a < 50*time.Second {
		t.Fatalf("saveDoTCache refreshed the cache file's mtime (age now %v); the server list's age must stay honest", a)
	}

	// A file that holds only an iface line is no cache: ok follows the servers.
	if err := os.WriteFile(f, []byte(dnsCacheIfacePrefix+"wlan0\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got, _, ok := loadDNSCache(); ok {
		t.Fatalf("a file holding only an iface line read as a cache: %v", got)
	}
}

func TestResolverSeed_InvalidIfaceWritesNoLine(t *testing.T) {
	dir := rsiSetup(t)
	f := filepath.Join(dir, dnsCacheFile)
	for _, c := range []struct {
		iface string
		line  bool
	}{
		{"", false},
		{"has space", false},
		{"a/b", false},
		{"sixteen-chars-xx", false},
		{"wl\nan0", false},
		{"abcdefghijklmno", true}, // 15 characters: the longest valid name
		{"rmnet_data0", true},
	} {
		saveDNSCache(rsiSeedList, "", nil, c.iface)
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		has := false
		for _, ln := range strings.Split(string(b), "\n") {
			if strings.HasPrefix(ln, dnsCacheIfacePrefix) {
				has = true
			}
		}
		if has != c.line {
			t.Fatalf("saveDNSCache(iface %q) wrote an iface line = %v, want %v; file:\n%s", c.iface, has, c.line, b)
		}
		addrs, _, _, _, _, iface := readDNSCache()
		want := ""
		if c.line {
			want = c.iface
		}
		if iface != want {
			t.Fatalf("readDNSCache iface = %q after saveDNSCache(iface %q), want %q", iface, c.iface, want)
		}
		if !slices.Equal(addrs, rsiSeedList) {
			t.Fatalf("readDNSCache servers = %v after saveDNSCache(iface %q), want %v", addrs, c.iface, rsiSeedList)
		}
	}
}

func TestResolverSeed_OtherIfaceDropsSeed(t *testing.T) {
	dir := rsiSetup(t)
	rsiSeed(t, dir, "wlan0", 10*dnsKeepMax)
	rsiDump(rsiRmnetEmptyDump)
	log := captureStderr(t, func() { refreshNet(false) })
	if got, _, _ := rsiState(); !slices.Equal(got, fallbackAddrs()) {
		t.Fatalf("a seed discovered on wlan0 was kept on rmnet0 (%v); want the public fallback; log:\n%s", got, log)
	}
	if !strings.Contains(log, "src=PUBLIC-FALLBACK") {
		t.Fatalf("dropping the seed on another interface did not log the public fallback:\n%s", log)
	}
}

func TestResolverSeed_SameOrNoIfaceKeepsSeed(t *testing.T) {
	for _, c := range []struct {
		name, dump string
	}{
		{"same interface", rsiWlanEmptyDump},
		{"no interface", rsiNoIfaceEmptyDump},
	} {
		t.Run(c.name, func(t *testing.T) {
			dir := rsiSetup(t)
			rsiSeed(t, dir, "wlan0", 10*dnsKeepMax)
			rsiDump(c.dump)
			log := captureStderr(t, func() { refreshNet(false) })
			if got, _, _ := rsiState(); !slices.Equal(got, rsiSeedList) {
				t.Fatalf("%s: an empty discovery replaced the seed %v with %v; log:\n%s", c.name, rsiSeedList, got, log)
			}
			if strings.Contains(log, "PUBLIC-FALLBACK") {
				t.Fatalf("%s: an empty discovery logged the public fallback with a seed in hand:\n%s", c.name, log)
			}
		})
	}
}

func TestResolverSeed_GoodDiscoveryClearsSeedIface(t *testing.T) {
	dir := rsiSetup(t)
	rsiSeed(t, dir, "wlan0", 10*dnsKeepMax)
	rsiDump(sampleDumpsysDefaultWifi)
	refreshNet(false)
	if _, seedIface, _ := rsiState(); seedIface != "" {
		t.Fatalf("dnsSeedIface = %q after this process's own non-empty discovery; it must be cleared", seedIface)
	}
	// The daemon-side save passes the interface this discovery named.
	if _, _, _, _, ok, iface := readDNSCache(); !ok || iface != "wlan0" {
		t.Fatalf("the cache written by a discovery on wlan0 reads ok %v iface %q", ok, iface)
	}
}

func TestResolverSeed_ForceStillDropsSeed(t *testing.T) {
	dir := rsiSetup(t)
	rsiSeed(t, dir, "wlan0", 10*dnsKeepMax)
	rsiDump(rsiWlanEmptyDump)
	refreshNet(true)
	if got, _, _ := rsiState(); !slices.Equal(got, fallbackAddrs()) {
		t.Fatalf("a forced refresh kept the seed (%v); want the public fallback", got)
	}
}
