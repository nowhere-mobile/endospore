package main

import (
	"fmt"
	"net"
	"regexp"
	"slices"
	"strings"
	"testing"
	"time"
)

// NWP-20261129-29 (backlog row "The resolver no longer discards a known-good nameserver list (`NWP-20260822-04`)"): the
// egress line is change-only and a kept list IS the current list, so a keep across a switch window printed nothing, and
// the fallback line said "nothing cached" whichever key dropped the keep. An empty run now states its own start and
// end, and the fallback line names the key. This changes logging only; resolver_keep_streak_test.go pins the keep.

const (
	klHeldLine    = "the kept list held (NWP-20261129-29)"
	klDroppedLine = "the kept list was dropped (NWP-20261129-29)"
	klColdSrc     = "src=PUBLIC-FALLBACK (discovery empty, nothing cached) dot="
)

var klBackRe = regexp.MustCompile(`(?m)^\[resolver\] discovery back after \d+ms empty; the kept list (held|was dropped) \(NWP-20261129-29\)$`)

func klKeepLine(servers int) string {
	return fmt.Sprintf("[resolver] discovery empty: keeping the last discovered list (%d server(s)) for up to 20s (NWP-20261129-29)\n", servers)
}

func klKeepCount(log string) int { return strings.Count(log, "[resolver] discovery empty:") }

// klRefresh runs one refresh on dump and returns what it logged.
func klRefresh(t *testing.T, dump string, force bool) string {
	t.Helper()
	ksDump(dump)
	return captureStderr(t, func() { refreshNet(force) })
}

// (a) A run that keeps the list says so once, however many empty discoveries it holds, and says when it ends. The state
// is reset where the run ends, so the next run speaks again.
func TestKeepLog_KeptRunPrintsOnceAndBack(t *testing.T) {
	ksSetup(t)
	good := ksGood(t)
	log := klRefresh(t, keepStreakEmptyDump, false) + klRefresh(t, keepStreakEmptyDump, false)
	if got := strings.Count(log, klKeepLine(len(good))); got != 1 || klKeepCount(log) != 1 {
		t.Fatalf("two empty discoveries printed the keep line %d time(s), want exactly once as %q:\n%s", got, klKeepLine(len(good)), log)
	}
	if strings.Contains(log, "PUBLIC-FALLBACK") {
		t.Fatalf("a kept run logged the public fallback:\n%s", log)
	}
	if klBackRe.MatchString(log) {
		t.Fatalf("a run still empty printed a back line:\n%s", log)
	}
	back := klRefresh(t, sampleDumpsysDefaultWifi, false)
	if m := klBackRe.FindAllString(back, -1); len(m) != 1 || !strings.Contains(m[0], klHeldLine) {
		t.Fatalf("the good discovery that ends the run printed %q, want one back line with %q:\n%s", m, klHeldLine, back)
	}
	if again := klRefresh(t, sampleDumpsysDefaultWifi, false); klBackRe.MatchString(again) {
		t.Fatalf("a second good discovery repeated the back line:\n%s", again)
	}
	next := klRefresh(t, keepStreakEmptyDump, false)
	if got := strings.Count(next, klKeepLine(len(good))); got != 1 {
		t.Fatalf("the next run's first empty discovery printed the keep line %d time(s), want once:\n%s", got, next)
	}
}

// (b) A run longer than dnsKeepMax falls to the fallback: the line names that key, and the back line says the keep did
// not hold.
func TestKeepLog_LongRunNamesTheDrop(t *testing.T) {
	ksSetup(t)
	ksGood(t)
	first := klRefresh(t, keepStreakEmptyDump, false)
	if klKeepCount(first) != 1 {
		t.Fatalf("the first empty discovery printed no keep line:\n%s", first)
	}
	ksSet(func() { dnsEmptySince = time.Now().Add(-2 * dnsKeepMax) })
	log := klRefresh(t, keepStreakEmptyDump, false)
	if !strings.Contains(log, "src=PUBLIC-FALLBACK (discovery empty, kept list dropped: empty-over-20s) dot=") {
		t.Fatalf("the fallback line does not name the key:\n%s", log)
	}
	if strings.Contains(log, "nothing cached") {
		t.Fatalf("a daemon that had a list logged nothing cached:\n%s", log)
	}
	if klKeepCount(log) != 0 {
		t.Fatalf("the fall repeated the keep line:\n%s", log)
	}
	back := klRefresh(t, sampleDumpsysDefaultWifi, false)
	if m := klBackRe.FindAllString(back, -1); len(m) != 1 || !strings.Contains(m[0], klDroppedLine) {
		t.Fatalf("the good discovery after the fall printed %q, want one back line with %q:\n%s", m, klDroppedLine, back)
	}
}

// (c) A change of egress interface names its key.
func TestKeepLog_IfaceChange(t *testing.T) {
	ksSetup(t)
	ksGood(t)
	log := klRefresh(t, keepStreakOtherIfaceDump, false)
	if !strings.Contains(log, "src=PUBLIC-FALLBACK (discovery empty, kept list dropped: iface-changed) dot=") {
		t.Fatalf("the fallback line does not name the interface change:\n%s", log)
	}
}

// (d) A forced refresh over an empty dump names its key.
func TestKeepLog_Forced(t *testing.T) {
	ksSetup(t)
	ksGood(t)
	log := klRefresh(t, keepStreakEmptyDump, true)
	if !strings.Contains(log, "src=PUBLIC-FALLBACK (discovery empty, kept list dropped: forced) dot=") {
		t.Fatalf("the fallback line does not name the forced refresh:\n%s", log)
	}
}

// A forced refresh inside a kept run is a fall after the keep line: the run does not print the keep line again when the
// next empty discovery holds the fallback list, and its end says the keep was dropped.
func TestKeepLog_ForcedInsideARun(t *testing.T) {
	ksSetup(t)
	ksGood(t)
	log := klRefresh(t, keepStreakEmptyDump, false) + klRefresh(t, keepStreakEmptyDump, true) + klRefresh(t, keepStreakEmptyDump, false)
	if klKeepCount(log) != 1 || !strings.Contains(log, "kept list dropped: forced") {
		t.Fatalf("want one keep line and one forced drop:\n%s", log)
	}
	back := klRefresh(t, sampleDumpsysDefaultWifi, false)
	if m := klBackRe.FindAllString(back, -1); len(m) != 1 || !strings.Contains(m[0], klDroppedLine) {
		t.Fatalf("the end of the run printed %q, want one back line with %q:\n%s", m, klDroppedLine, back)
	}
}

// (e) "nothing cached" stays byte for byte on a cold start, the one case where it is true, and a cold start keeps nothing.
func TestKeepLog_ColdStart(t *testing.T) {
	ksSetup(t)
	log := klRefresh(t, keepStreakEmptyDump, false)
	if !strings.Contains(log, klColdSrc) {
		t.Fatalf("a cold start did not log %q:\n%s", klColdSrc, log)
	}
	if strings.Contains(log, "kept list dropped") || klKeepCount(log) != 0 {
		t.Fatalf("a cold start claimed a kept list:\n%s", log)
	}
}

// A drop with no keep line before it leaves the public fallback as the current list, and the next empty discovery
// "keeps" that with no key firing. That is not the discovered list, so neither the keep line nor a back line may print.
func TestKeepLog_SilentFallPrintsNoClaim(t *testing.T) {
	ksSetup(t)
	ksGood(t)
	log := klRefresh(t, keepStreakOtherIfaceDump, false) + klRefresh(t, keepStreakOtherIfaceDump, false) + klRefresh(t, sampleDumpsysDefaultWifi, false)
	if klKeepCount(log) != 0 || klBackRe.MatchString(log) {
		t.Fatalf("a run that dropped the list at once claimed a keep:\n%s", log)
	}
	if next := klRefresh(t, keepStreakEmptyDump, false); klKeepCount(next) != 1 {
		t.Fatalf("a good discovery did not end the silent run: the next run printed no keep line:\n%s", next)
	}
}

// The two keys the other tests do not reach.
func TestKeepLog_OtherReasons(t *testing.T) {
	ksSetup(t)
	saveDNSCache([]string{"192.0.2.53:53"}, "", nil, "wlan0") // TEST-NET-1: no real resolver
	seedDNSFromCache()
	log := klRefresh(t, keepStreakOtherIfaceDump, false)
	if !strings.Contains(log, "kept list dropped: seed-other-iface) dot=") {
		t.Fatalf("the fallback line does not name the seed's interface:\n%s", log)
	}

	ksSetup(t)
	ksGood(t)
	ksSet(func() { dnsFromVPN = true })
	log = klRefresh(t, keepStreakEmptyDump, false)
	if !strings.Contains(log, "kept list dropped: vpn-gone) dot=") {
		t.Fatalf("the fallback line does not name the VPN:\n%s", log)
	}
}

func klAssertNoAddressOrIface(t *testing.T, text string) {
	t.Helper()
	for _, tok := range strings.Fields(text) {
		if net.ParseIP(strings.Trim(tok, "()[],;:=")) != nil {
			t.Fatalf("an IP literal %q in %q", tok, text)
		}
	}
	for _, bad := range []string{"wlan", "rmnet", "tun", "iface=", "dot=", "192.0.2.", "198.51.100.", "2001:"} {
		if strings.Contains(text, bad) {
			t.Fatalf("%q in %q", bad, text)
		}
	}
}

// (f) The keep and back lines hold counts and durations only, a drop's src holds a key only, and the report's scrub
// leaves them as they are. The one change is the work ID's digit run: reIssueDigits rewrites any run of 7+ digits, as it
// does for the `seeded ... (NWP-20260822-06)` line.
func TestKeepLog_NoAddressOrIface(t *testing.T) {
	ksSetup(t)
	ksGood(t)
	var lines []string
	collect := func(s string) { lines = append(lines, strings.Split(strings.TrimSpace(s), "\n")...) }
	collect(klRefresh(t, keepStreakEmptyDump, false))
	collect(klRefresh(t, sampleDumpsysDefaultWifi, false))
	collect(klRefresh(t, keepStreakEmptyDump, false))
	ksSet(func() { dnsEmptySince = time.Now().Add(-2 * dnsKeepMax) })
	drop := klRefresh(t, keepStreakEmptyDump, false)
	collect(klRefresh(t, sampleDumpsysDefaultWifi, false))

	var saw []string
	for _, ln := range lines {
		if !strings.Contains(ln, "[resolver] discovery ") {
			continue
		}
		saw = append(saw, ln)
		klAssertNoAddressOrIface(t, ln)
		if got := applyIssueNameRules(ln); got != ln {
			t.Fatalf("the name rules changed %q to %q", ln, got)
		}
		want := strings.ReplaceAll(ln, "NWP-20261129-29", "NWP-<num>-29")
		if got, keep := scrubIssueLine(ln, nil); !keep || got != want {
			t.Fatalf("scrubIssueLine(%q) = %q %v, want %q", ln, got, keep, want)
		}
	}
	if len(saw) != 4 { // two keep lines, a held and a dropped
		t.Fatalf("want 4 new lines, saw %d: %q", len(saw), saw)
	}
	if !slices.ContainsFunc(saw, func(s string) bool { return strings.Contains(s, klHeldLine) }) ||
		!slices.ContainsFunc(saw, func(s string) bool { return strings.Contains(s, klDroppedLine) }) {
		t.Fatalf("want a held and a dropped back line: %q", saw)
	}

	egress := strings.TrimSpace(drop)
	src := regexp.MustCompile(`src=(.*) dot=`).FindStringSubmatch(egress)
	if src == nil || !strings.Contains(src[1], "kept list dropped: empty-over-20s") {
		t.Fatalf("no drop src in %q", egress)
	}
	klAssertNoAddressOrIface(t, src[1])
	if got, keep := scrubIssueLine(egress, nil); !keep || got != applyIssueNameRules(egress) {
		t.Fatalf("the report's scrub changed the fallback line beyond the name rules:\n got %q\nwant %q", got, applyIssueNameRules(egress))
	}
}
