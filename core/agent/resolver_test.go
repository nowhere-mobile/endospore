package main

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// the real shape of a `dumpsys connectivity` DnsAddresses list (IPv6 + the network's own IPv4 resolvers)
const sampleDumpsys = `NetworkAgentInfo{network{104} lp{{InterfaceName: wlan0 ` +
	`DnsAddresses: [ /2001:4860:4860::8844,/2001:4860:4860::8888,/192.0.2.53,/198.51.100.53 ] ServerAddress: /192.168.4.1}}`

// a DUAL-network dump as seen on the Pixel 7a: a cellular IMS-only PDN listed FIRST (its DNS is a private
// link-local resolver reachable only over that radio), then the validated Wi-Fi. The IMS DNS must NOT shadow
// the reachable Wi-Fi resolver -- parseDumpsysDNS collects both and pickDNS's IPv4-first ordering picks Wi-Fi.
const sampleDumpsysMulti = `NetworkAgentInfo{network{100} lp{{InterfaceName: rmnet1 ` +
	`DnsAddresses: [ /fc00:a:a::400 ] MTU: 1430}} ` +
	`NetworkAgentInfo{network{121} lp{{InterfaceName: wlan0 ` +
	`DnsAddresses: [ /2001:4860:4860::8844,/192.0.2.53 ] ServerAddress: /192.168.4.1}}`

// a 3-network dump WITH the "Active default network" marker, captured on the Pixel 7a with 2 SIMs + Wi-Fi and
// mobile data ON: a cellular INTERNET PDN (rmnet17) whose IPv4 resolver 172.26.38.2 is a PRIVATE address
// reachable ONLY over the radio, plus the validated Wi-Fi (wlan0) as the ACTIVE DEFAULT. The default-scoped
// pick must yield the Wi-Fi resolvers and NEVER 172.26.38.2 (100% packet loss once we SO_BINDTODEVICE wlan0).
// The cellular block is listed FIRST to prove parseDefaultNetworkDNS reads the *default's* block, not the first.
const sampleDumpsysDefaultWifi = `Active default network: 121
NetworkAgentInfo{network{104} lp{{InterfaceName: rmnet17 ` +
	`DnsAddresses: [ /fc00:a:a::400,/172.26.38.2 ] MTU: 1430}} ` +
	`NetworkAgentInfo{network{121} lp{{InterfaceName: wlan0 ` +
	`DnsAddresses: [ /2001:4860:4860::8844,/192.0.2.53,/198.51.100.53 ] ServerAddress: /192.168.4.1}}`

// same two networks but CELLULAR is the active default (e.g. Wi-Fi dropped): the pick must use the cellular
// block's own IPv4 resolver 172.26.38.2 -- reachable over rmnet17, the interface bindControl now binds -- and
// NOT the Wi-Fi 192.0.2.53, which is (in general) unreachable over the radio.
const sampleDumpsysDefaultCell = `Active default network: 104
NetworkAgentInfo{network{121} lp{{InterfaceName: wlan0 ` +
	`DnsAddresses: [ /192.0.2.53 ] ServerAddress: /192.168.4.1}} ` +
	`NetworkAgentInfo{network{104} lp{{InterfaceName: rmnet17 ` +
	`DnsAddresses: [ /fc00:a:a::400,/172.26.38.2 ] MTU: 1430}}`

func TestPickDNS(t *testing.T) {
	cases := []struct {
		name       string
		override   string
		props      []string
		defaultDNS []string
		dumpsys    string
		want       []string
	}{
		{"explicit override wins", "8.8.8.8, 8.8.4.4", []string{"192.168.1.1"}, nil, sampleDumpsys, []string{"8.8.8.8", "8.8.4.4"}},
		{"props when no override", "", []string{"192.168.1.1", "10.0.0.1"}, nil, sampleDumpsys, []string{"192.168.1.1", "10.0.0.1"}},
		// #180: the default network's own resolvers win over the all-networks union -- the private cellular
		// 172.26.38.2 present in the dump is never considered because the (Wi-Fi) default block has servers.
		{"default-network scope preferred over the union (drops private cellular v4)", "", nil,
			[]string{"2001:4860:4860::8844", "192.0.2.53", "198.51.100.53"}, sampleDumpsysDefaultWifi,
			[]string{"192.0.2.53", "198.51.100.53"}},
		// end-to-end via parseDefaultNetworkDNS: Wi-Fi default -> only its v4 resolvers.
		{"Wi-Fi default, scoped via parseDefaultNetworkDNS", "", nil,
			parseDefaultNetworkDNS(sampleDumpsysDefaultWifi), sampleDumpsysDefaultWifi,
			[]string{"192.0.2.53", "198.51.100.53"}},
		// cellular default -> its OWN v4 resolver (reachable over rmnet), not the Wi-Fi one.
		{"cellular default uses its own reachable v4", "", nil,
			parseDefaultNetworkDNS(sampleDumpsysDefaultCell), sampleDumpsysDefaultCell,
			[]string{"172.26.38.2"}},
		{"union fallback when no default marker (IPv4-only when v4 present)", "", nil, nil, sampleDumpsys,
			[]string{"192.0.2.53", "198.51.100.53"}},
		{"multi-network union, no marker: reachable Wi-Fi v4 only, drop cellular IMS v6", "", nil, nil, sampleDumpsysMulti,
			[]string{"192.0.2.53"}},
		{"public fallback when all empty (both families)", "", nil, nil, "",
			[]string{"1.1.1.1", "8.8.8.8", "2606:4700:4700::1111", "2001:4860:4860::8888"}},
		{"garbage ignored, dedup", "1.2.3.4, notanip, 1.2.3.4", nil, nil, "", []string{"1.2.3.4"}},
		// DIA-20260730: a cellular/IMS default whose ONLY resolver is an fc00::/7 ULA (as seen on the real
		// device: cellular DnsAddresses = [ /fc00:a:a::400 ], no v4) must NOT be adopted -- it's unreachable
		// over the validated default iface bindControl binds to, so the resolver wedged on it and mediad's
		// gateway cap-refresh got "network is unreachable" (the on-demand-game "not enough storage" bug). Drop
		// it and fall through to the reachable union v4, or the public fallback when there is nothing else.
		{"IMS-only fc00 default dropped -> reachable union Wi-Fi v4", "", nil, []string{"fc00:a:a::400"}, sampleDumpsysMulti,
			[]string{"192.0.2.53"}},
		{"IMS-only fc00 default, empty union -> public fallback", "", nil, []string{"fc00:a:a::400"}, "",
			[]string{"1.1.1.1", "8.8.8.8", "2606:4700:4700::1111", "2001:4860:4860::8888"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := pickDNS(c.override, c.props, c.defaultDNS, c.dumpsys); !reflect.DeepEqual(got, c.want) {
				t.Fatalf("pickDNS = %v, want %v", got, c.want)
			}
		})
	}
}

func TestParseDefaultNetworkDNS(t *testing.T) {
	// Wi-Fi (121) is the active default -> only its resolvers, never the cellular 172.26.x listed earlier.
	got := parseDefaultNetworkDNS(sampleDumpsysDefaultWifi)
	want := []string{"2001:4860:4860::8844", "192.0.2.53", "198.51.100.53"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("parseDefaultNetworkDNS(wifi default) = %v, want %v", got, want)
	}
	// cellular (104) is the active default -> its own block's resolvers.
	gotCell := parseDefaultNetworkDNS(sampleDumpsysDefaultCell)
	wantCell := []string{"fc00:a:a::400", "172.26.38.2"}
	if !reflect.DeepEqual(gotCell, wantCell) {
		t.Fatalf("parseDefaultNetworkDNS(cell default) = %v, want %v", gotCell, wantCell)
	}
	// no "Active default network" marker -> nil, so pickDNS falls through to the all-networks union.
	if parseDefaultNetworkDNS(sampleDumpsys) != nil {
		t.Fatal("expected nil when there is no Active-default marker")
	}
	// marker present but that network's block absent -> nil (don't grab a different network's DNS).
	if parseDefaultNetworkDNS("Active default network: 999\n"+sampleDumpsysDefaultWifi) != nil {
		t.Fatal("expected nil when the default network's block is missing")
	}
}

func TestParseDumpsysDNS(t *testing.T) {
	got := parseDumpsysDNS(sampleDumpsys)
	want := []string{"/2001:4860:4860::8844", "/2001:4860:4860::8888", "/192.0.2.53", "/198.51.100.53"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("parseDumpsysDNS = %v, want %v", got, want)
	}
	if parseDumpsysDNS("no dns here") != nil {
		t.Fatal("expected nil when DnsAddresses is absent")
	}
	// every network's DnsAddresses, in dump order (cellular IMS first, Wi-Fi second)
	gotMulti := parseDumpsysDNS(sampleDumpsysMulti)
	wantMulti := []string{"/fc00:a:a::400", "/2001:4860:4860::8844", "/192.0.2.53"}
	if !reflect.DeepEqual(gotMulti, wantMulti) {
		t.Fatalf("parseDumpsysDNS(multi) = %v, want %v", gotMulti, wantMulti)
	}
}

func TestHasResolvConf(t *testing.T) {
	dir := t.TempDir()
	good := filepath.Join(dir, "good")
	_ = os.WriteFile(good, []byte("# comment\nnameserver 1.1.1.1\n"), 0o644)
	empty := filepath.Join(dir, "empty")
	_ = os.WriteFile(empty, []byte("# nothing useful\n"), 0o644)

	if !hasResolvConf(good) {
		t.Error("file with a nameserver should be usable")
	}
	if hasResolvConf(empty) {
		t.Error("file with no nameserver should be unusable")
	}
	if hasResolvConf(filepath.Join(dir, "missing")) {
		t.Error("missing file should be unusable")
	}
}

func TestWithPort53(t *testing.T) {
	for in, want := range map[string]string{
		"1.1.1.1":         "1.1.1.1:53",
		"1.1.1.1:5353":    "1.1.1.1:5353",
		"2001:4860::8888": "[2001:4860::8888]:53",
	} {
		if got := withPort53(in); got != want {
			t.Errorf("withPort53(%q) = %q, want %q", in, got, want)
		}
	}
}
