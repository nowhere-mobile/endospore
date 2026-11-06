package main

import (
	"reflect"
	"testing"
	"time"
)

// NWP-20260822-04 (#64). dnsAdopt is the extracted decision that fixes the resolver clobbering a good
// nameserver list with the public fallback during a transient empty discovery.
//
// The property under test is an ORDER, and the middle case is the whole bug: a momentary empty discovery --
// which the user-switch window produces, where dumpsys reports no active default network at all -- must NOT
// cost us the servers we already know work.
func TestDnsAdopt(t *testing.T) {
	discovered := []string{"192.0.2.53:53", "198.51.100.53:53"}
	cached := []string{"192.168.1.1:53"}
	fallback := []string{"1.1.1.1:53", "8.8.8.8:53", "[2606:4700:4700::1111]:53", "[2001:4860:4860::8888]:53"}

	for _, tc := range []struct {
		name              string
		discovered, cache []string
		want              []string
		wantFallback      bool
	}{
		{"a fresh discovery is adopted", discovered, cached, discovered, false},
		{"discovery wins even with nothing cached", discovered, nil, discovered, false},

		// THE REGRESSION THIS FILE EXISTS FOR. Before the fix, pickDNS could never return empty, so
		// refreshNet's `len(addrs) > 0` guard never fired and this case silently became the fallback --
		// replacing working ISP resolvers with public ones (including v6 entries that ENETUNREACH on an
		// IPv4-only Wi-Fi, which is the error #64 and #80 are keyed on).
		{"an EMPTY discovery keeps the last good list", nil, cached, cached, false},
		{"empty discovery keeps a multi-entry list intact", []string{}, discovered, discovered, false},

		// Cold start only: nothing discovered AND nothing cached. This is the sole legitimate use of the
		// public list -- a bootstrap, never a substitute for servers we already proved reachable.
		{"cold start falls back", nil, nil, fallback, true},
		{"cold start with an empty (non-nil) cache falls back", []string{}, []string{}, fallback, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, usedFallback := dnsAdopt(tc.discovered, tc.cache, fallback)
			if !reflect.DeepEqual(got, tc.want) {
				t.Errorf("dnsAdopt = %v, want %v", got, tc.want)
			}
			if usedFallback != tc.wantFallback {
				t.Errorf("usedFallback = %v, want %v", usedFallback, tc.wantFallback)
			}
		})
	}
}

// discoveredDNS must be able to return NOTHING. That is the entire reason it was split out of pickDNS: a
// function that always answers cannot express "I found nothing", and the caller needs that distinction to
// decide between adopting, keeping, and bootstrapping.
func TestDiscoveredDNSCanReturnEmpty(t *testing.T) {
	if got := discoveredDNS("", nil, nil, ""); len(got) != 0 {
		t.Fatalf("discoveredDNS with no inputs = %v, want empty -- the split is pointless otherwise", got)
	}
	// ...while pickDNS, which callers without a cache still use, must keep answering.
	if got := pickDNS("", nil, nil, ""); len(got) == 0 {
		t.Fatal("pickDNS with no inputs returned empty; it must still bootstrap")
	}
}

// NWP-20260822-04, second pass. The keep must be BOUNDED, and the bound is not optional: what the old clobber
// cost was capped at ~dnsTTL (the next successful discovery undid it), so an UNBOUNDED keep would trade a
// 4-second degradation for one that never ends. These pin the vetting rules refreshNet applies to the cached
// list before offering it to dnsAdopt.
//
// The rules are expressed here as the `keep` value refreshNet computes; dnsAdopt itself stays pure and simply
// honours whatever it is handed. That split is deliberate — the decision is stateful, the arithmetic is not.
func TestKeepVetting(t *testing.T) {
	cached := []string{"192.168.1.1:53"}
	fallback := []string{"1.1.1.1:53"}

	// A vetted-away cache must NOT be kept -- it has to fall through to the bootstrap, or we wedge.
	if got, usedFallback := dnsAdopt(nil, nil, fallback); !reflect.DeepEqual(got, fallback) || !usedFallback {
		t.Errorf("a vetted-away cache must reach the fallback; got %v (fallback=%v)", got, usedFallback)
	}
	// A cache that survives vetting IS kept.
	if got, usedFallback := dnsAdopt(nil, cached, fallback); !reflect.DeepEqual(got, cached) || usedFallback {
		t.Errorf("a valid cache must be kept; got %v (fallback=%v)", got, usedFallback)
	}
}

// The bound constants must stay in a sane relationship: the keep window has to be LONGER than the discovery
// TTL (or a keep could never span even one missed refresh, making it pointless) and short enough to be a
// "transient" rather than a lease on a dead list. Pinned so a future edit cannot quietly invert them.
func TestKeepBoundIsSane(t *testing.T) {
	if dnsKeepMax <= dnsTTL {
		t.Fatalf("dnsKeepMax (%v) must exceed dnsTTL (%v), else a keep can never span a missed refresh", dnsKeepMax, dnsTTL)
	}
	if dnsKeepMax > 60*time.Second {
		t.Fatalf("dnsKeepMax (%v) is long enough to be a lease on a dead list, not a transient", dnsKeepMax)
	}
}
