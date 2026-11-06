package main

import (
	"regexp"
	"strings"
	"testing"
)

// NWP-20261011-36: login.log on a fielded device still holds the resolver's LEGACY egress line, whose dns=[...]
// list is every network's own resolver addresses. The issue reporter must take that list out whole -- v6 entries
// are bracketed inside it, at any position -- and must leave the line egressLine writes today exactly as the
// name rules leave it, so the dns rule is provably confined to the legacy form.
func TestScrubIssueLineRedactsLegacyDNS(t *testing.T) {
	planted := []string{"192.0.2.53", "198.51.100.53", "2001:db8::53", "2001:db8:1::99"}
	cases := []struct{ in, want string }{
		{`[resolver] egress iface="wlan0" dns=[192.0.2.53:53 198.51.100.53:53] src=discovered dot=off`,
			`[resolver] egress iface="<name>" dns=[<redacted>] src=discovered dot=off`},
		// a v6 entry in the middle: a [^\]]* list would stop inside it and leave the later addresses
		{`[resolver] egress iface="wlan0" dns=[192.0.2.53:53 [2001:db8::53]:53 198.51.100.53:53] src=discovered dot=off`,
			`[resolver] egress iface="<name>" dns=[<redacted>] src=discovered dot=off`},
		// ...and at the end
		{`[resolver] egress iface="wlan0" dns=[198.51.100.53:53 [2001:db8:1::99]:53] src=kept (discovery empty, cache still valid) dot=off`,
			`[resolver] egress iface="<name>" dns=[<redacted>] src=kept (discovery empty, cache still valid) dot=off`},
		// a line written before src= existed (DIA-20260720-02)
		{`[resolver] egress iface="wlan0" dns=[192.0.2.53:53 [2001:db8::53]:53]`,
			`[resolver] egress iface="<name>" dns=[<redacted>]`},
		// a fixed point: a second scrub changes nothing
		{`[resolver] egress iface="<name>" dns=[<redacted>] src=discovered dot=off`,
			`[resolver] egress iface="<name>" dns=[<redacted>] src=discovered dot=off`},
	}
	digits := regexp.MustCompile(`[0-9a-f]{2,}`)
	for _, c := range cases {
		got, keep := scrubIssueLine(c.in, nil)
		if !keep || got != c.want {
			t.Fatalf("scrubIssueLine(%q) = %q %v, want %q", c.in, got, keep, c.want)
		}
		for _, a := range planted {
			for _, run := range digits.FindAllString(a, -1) {
				if run != "db8" && strings.Contains(got, run) {
					t.Fatalf("a run %q of planted resolver %s survives: %q", run, a, got)
				}
			}
		}
	}

	// a line that only mentions the legacy text, not the resolver's own line, is not touched by this rule
	other := `[roamd] note: dns=[192.0.2.53:53] src=x`
	if got, _ := scrubIssueLine(other, nil); got != applyIssueNameRules(other) {
		t.Fatalf("the dns rule reached a non-resolver line: %q", got)
	}
}

func TestScrubIssueLineLeavesNewEgressLine(t *testing.T) {
	for _, ln := range []string{
		egressLine("wlan0", []string{"192.0.2.53:53", "[2001:db8::53]:53"}, "discovered", ""),
		egressLine("wlan0", fallbackAddrs(), "PUBLIC-FALLBACK (discovery empty, nothing cached)", "dns.mullvad.net"),
	} {
		got, keep := scrubIssueLine(ln, nil)
		if want := applyIssueNameRules(ln); !keep || got != want {
			t.Fatalf("a new-form line changed beyond the name rules:\n got %q\nwant %q", got, want)
		}
		if strings.Contains(got, "<redacted>") {
			t.Fatalf("the legacy dns rule fired on a new-form line: %q", got)
		}
	}
}
