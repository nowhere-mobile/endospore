package main

import (
	"bytes"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// NWP-20261122-09 (backlog: An issue report's logs sections keep only the last 299 lines of each log, ...): the `in`
// op's restores and od_parked_report write $STATE/signin-summary.<uid>, and an in-session issue report carries it as
// signin_* status keys, digits only, for its own uid only, never at the gate.

var signinSummaryDigits = regexp.MustCompile(`^[0-9]+$`)

// signinSummaryCounters sets the restore's cache counters for one test, and the store counters to values no other
// field of a fixture holds (signinSummaryTrace), and puts them back after it.
func signinSummaryCounters(t *testing.T, hits, miss int64) {
	t.Helper()
	h0, m0 := atomic.LoadInt64(&chunkHits), atomic.LoadInt64(&chunkMiss)
	g0, c0 := atomic.LoadInt64(&traceGetN), atomic.LoadInt64(&traceCapN)
	atomic.StoreInt64(&chunkHits, hits)
	atomic.StoreInt64(&chunkMiss, miss)
	atomic.StoreInt64(&traceGetN, 21)
	atomic.StoreInt64(&traceCapN, 2)
	t.Cleanup(func() {
		atomic.StoreInt64(&chunkHits, h0)
		atomic.StoreInt64(&chunkMiss, m0)
		atomic.StoreInt64(&traceGetN, g0)
		atomic.StoreInt64(&traceCapN, c0)
	})
}

// signinSummaryTrace is the store fields of a line signinSummaryAppend writes under signinSummaryCounters.
const signinSummaryTrace = " store_reads=21 cap_calls=2"

func signinSummaryRead(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	return string(b)
}

func signinSummaryPlant(t *testing.T, dir, name, body string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestSigninSummaryAppendEachPhase(t *testing.T) {
	signinSummaryCounters(t, 3, 4)
	m := chunkManifest{Chunks: []string{"a", "b", "c", "d", "e", "f", "g"}}
	for phase, scope := range map[string]string{"apps": "vault", "secure": "de", "appcode": "apps", "accounts": "sys"} {
		p := filepath.Join(t.TempDir(), "signin-summary.10")
		t.Setenv("NOWHERE_SIGNIN_SUMMARY", p)
		t.Setenv("NOWHERE_PHASE", phase)
		signinSummaryAppend(m, 1234, 0)
		want := "v=1 scope=" + scope + " ms=1234 chunks=7 cached=3 fetched=4 heal_ms=0" + signinSummaryTrace + "\n"
		if got := signinSummaryRead(t, p); got != want {
			t.Errorf("phase %s: %q, want %q", phase, got, want)
		}
		if fi, err := os.Stat(p); err != nil || fi.Mode().Perm() != 0o600 {
			t.Errorf("phase %s: mode %v (%v), want 0600", phase, fi, err)
		}
	}
	// A non-media phase never carries the share extras, even for a head with an index.
	p := filepath.Join(t.TempDir(), "signin-summary.10")
	t.Setenv("NOWHERE_SIGNIN_SUMMARY", p)
	t.Setenv("NOWHERE_PHASE", "apps")
	signinSummaryAppend(chunkManifest{Chunks: []string{"a"}, Ess: map[string]essRegion{"DCIM/a": {S: 0, E: 1, Size: 5}}}, 1, 0)
	if got := signinSummaryRead(t, p); got != "v=1 scope=vault ms=1 chunks=1 cached=3 fetched=4 heal_ms=0"+signinSummaryTrace+"\n" {
		t.Errorf("vault with an index: %q, want no extras", got)
	}
}

func TestSigninSummaryAppendMedia(t *testing.T) {
	signinSummaryCounters(t, 1, 2)
	t.Setenv("NOWHERE_PHASE", "media")
	m := chunkManifest{
		Chunks: []string{"c0", "c1", "c2"},
		Ess: map[string]essRegion{
			"DCIM/Camera/a.jpg":     {S: 0, E: 1, Size: 1000},
			"Download/f.pdf":        {S: 1, E: 2, Size: 200},
			"Android/data/com.x/db": {S: 2, E: 3, Size: 30},
		},
	}
	p := filepath.Join(t.TempDir(), "signin-summary.10")
	t.Setenv("NOWHERE_SIGNIN_SUMMARY", p)
	signinSummaryAppend(m, 88000, 0)
	uf, ub, of, ob, _ := mediaUserShare(m)
	if uf != 2 || ub != 1200 || of != 1 || ob != 30 {
		t.Fatalf("mediaUserShare = %d %d %d %d, want 2 1200 1 30", uf, ub, of, ob)
	}
	want := "v=1 scope=media ms=88000 chunks=3 cached=1 fetched=2 heal_ms=0" + signinSummaryTrace + " user_files=2 user_bytes=1200 other_files=1 other_bytes=30\n"
	if got := signinSummaryRead(t, p); got != want {
		t.Errorf("media: %q, want %q", got, want)
	}

	p = filepath.Join(t.TempDir(), "signin-summary.10")
	t.Setenv("NOWHERE_SIGNIN_SUMMARY", p)
	signinSummaryAppend(chunkManifest{Chunks: []string{"c0"}}, 5, 0)
	if got := signinSummaryRead(t, p); got != "v=1 scope=media ms=5 chunks=1 cached=1 fetched=2 heal_ms=0"+signinSummaryTrace+" indexed=0\n" {
		t.Errorf("media without an index: %q, want indexed=0", got)
	}
}

func TestSigninSummaryAppendWritesNothing(t *testing.T) {
	signinSummaryCounters(t, 0, 0)
	m := chunkManifest{Chunks: []string{"a"}}
	for _, phase := range []string{"", "vault", "restore", "de", "sys", "APPS", "apps "} {
		d := t.TempDir()
		t.Setenv("NOWHERE_SIGNIN_SUMMARY", filepath.Join(d, "signin-summary.10"))
		t.Setenv("NOWHERE_PHASE", phase)
		signinSummaryAppend(m, 1, 0)
		if ents, _ := os.ReadDir(d); len(ents) != 0 {
			t.Errorf("phase %q wrote %d file(s), want none", phase, len(ents))
		}
	}
	t.Setenv("NOWHERE_PHASE", "apps")
	t.Setenv("NOWHERE_SIGNIN_SUMMARY", "")
	signinSummaryAppend(m, 1, 0) // nothing to check but that it does not panic or write into the cwd
	d := t.TempDir()
	t.Chdir(d)
	t.Setenv("NOWHERE_SIGNIN_SUMMARY", "signin-summary.10")
	signinSummaryAppend(m, 1, 0)
	if ents, _ := os.ReadDir(d); len(ents) != 0 {
		t.Errorf("a relative path wrote %d file(s), want none", len(ents))
	}
}

func TestSigninSummaryAppendTwoLines(t *testing.T) {
	signinSummaryCounters(t, 0, 9)
	p := filepath.Join(t.TempDir(), "signin-summary.10")
	t.Setenv("NOWHERE_SIGNIN_SUMMARY", p)
	t.Setenv("NOWHERE_PHASE", "apps")
	signinSummaryAppend(chunkManifest{Chunks: []string{"a"}}, 10, 0)
	t.Setenv("NOWHERE_PHASE", "secure")
	signinSummaryAppend(chunkManifest{Chunks: []string{"a", "b"}}, 20, 0)
	want := "v=1 scope=vault ms=10 chunks=1 cached=0 fetched=9 heal_ms=0" + signinSummaryTrace + "\nv=1 scope=de ms=20 chunks=2 cached=0 fetched=9 heal_ms=0" + signinSummaryTrace + "\n"
	if got := signinSummaryRead(t, p); got != want {
		t.Errorf("two appends: %q, want %q", got, want)
	}
	// And the reader takes what the writer wrote.
	got := signinSummaryStatus(p)
	if got["signin_vault_ms"] != "10" || got["signin_de_chunks"] != "2" || got["signin_summary"] != "" {
		t.Errorf("read back: %v", got)
	}
}

const signinSummaryFull = "v=1 scope=vault ms=61000 chunks=900 cached=12 fetched=888 heal_ms=7000 store_reads=901 cap_calls=4\n" +
	"v=1 scope=de ms=4000 chunks=40 cached=1 fetched=39 heal_ms=500 store_reads=41 cap_calls=3\n" +
	"v=1 scope=media ms=88000 chunks=1700 cached=0 fetched=1700 heal_ms=0 store_reads=1702 cap_calls=6 user_files=310 user_bytes=1700000000 other_files=55 other_bytes=90000000\n" +
	"v=1 scope=apps ms=9000 chunks=120 cached=100 fetched=20 heal_ms=0 store_reads=22 cap_calls=5\n" +
	"v=1 scope=sys ms=700 chunks=3 cached=0 fetched=3 heal_ms=0 store_reads=8 cap_calls=1\n" +
	"v=1 parked apps=14 ce_kib=812000 de_kib=4100\n" +
	"v=1 phase=reap ms=25000\n" +
	"v=1 phase=reown ms=30000\n" +
	"v=1 phase=reown ms=2000\n" +
	"v=1 phase=acct ms=1500\n" +
	"v=1 phase=reown ms=45000\n" +
	"v=1 phase=reap ms=60000\n" +
	"v=1 phase=in ms=320000\n"

// signinSummaryFullKeys is every key signinSummaryFull gives.
var signinSummaryFullKeys = map[string]string{
	"signin_vault_ms": "61000", "signin_vault_chunks": "900", "signin_vault_cached": "12", "signin_vault_fetched": "888",
	"signin_vault_store_reads": "901", "signin_vault_cap_calls": "4",
	"signin_de_ms": "4000", "signin_de_chunks": "40", "signin_de_cached": "1", "signin_de_fetched": "39",
	"signin_de_store_reads": "41", "signin_de_cap_calls": "3",
	"signin_media_ms": "88000", "signin_media_chunks": "1700", "signin_media_cached": "0", "signin_media_fetched": "1700",
	"signin_media_store_reads": "1702", "signin_media_cap_calls": "6",
	"signin_media_user_files": "310", "signin_media_user_bytes": "1700000000",
	"signin_media_other_files": "55", "signin_media_other_bytes": "90000000", "signin_media_indexed": "1",
	"signin_apps_ms": "9000", "signin_apps_chunks": "120", "signin_apps_cached": "100", "signin_apps_fetched": "20",
	"signin_apps_store_reads": "22", "signin_apps_cap_calls": "5",
	"signin_sys_ms": "700", "signin_sys_chunks": "3", "signin_sys_cached": "0", "signin_sys_fetched": "3",
	"signin_sys_store_reads": "8", "signin_sys_cap_calls": "1",
	"signin_parked_apps": "14", "signin_parked_ce_kib": "812000", "signin_parked_de_kib": "4100",
	"signin_heal_ms": "7500", // vault plus #de
	"signin_in_ms":   "320000",
	"signin_reap_ms": "85000", "signin_reown_ms": "77000", "signin_acct_ms": "1500",
}

func TestSigninSummaryStatusFull(t *testing.T) {
	got := signinSummaryStatus(signinSummaryPlant(t, t.TempDir(), "signin-summary.10", signinSummaryFull))
	want := signinSummaryFullKeys
	if len(got) != len(want) {
		t.Errorf("%d keys %v, want %d", len(got), got, len(want))
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s = %q, want %q", k, got[k], v)
		}
	}
	for k, v := range got {
		if !strings.HasPrefix(k, "signin_") || !signinSummaryDigits.MatchString(v) {
			t.Errorf("%s = %q: every key is signin_* and every value digits only", k, v)
		}
	}
	// Without a trailing newline too.
	if g := signinSummaryStatus(signinSummaryPlant(t, t.TempDir(), "s", strings.TrimSuffix(signinSummaryFull, "\n"))); len(g) != len(want) {
		t.Errorf("no trailing newline: %d keys, want %d", len(g), len(want))
	}
}

// NWP-20261130-08: ms holds the restore less its heal, and heal_ms the heal, whole and exact.
func TestSigninSummaryAppendHeal(t *testing.T) {
	signinSummaryCounters(t, 3, 4)
	m := chunkManifest{Chunks: []string{"a"}}
	t.Setenv("NOWHERE_PHASE", "apps")
	for _, c := range []struct {
		rest, heal int64
		want       string
	}{
		{100, 30, "v=1 scope=vault ms=70 chunks=1 cached=3 fetched=4 heal_ms=30" + signinSummaryTrace + "\n"},
		{100, 100, "v=1 scope=vault ms=0 chunks=1 cached=3 fetched=4 heal_ms=100" + signinSummaryTrace + "\n"},
		{100, 130, "v=1 scope=vault ms=0 chunks=1 cached=3 fetched=4 heal_ms=130" + signinSummaryTrace + "\n"},
	} {
		p := filepath.Join(t.TempDir(), "signin-summary.10")
		t.Setenv("NOWHERE_SIGNIN_SUMMARY", p)
		signinSummaryAppend(m, c.rest, c.heal)
		if got := signinSummaryRead(t, p); got != c.want {
			t.Errorf("rest %d heal %d: %q, want %q", c.rest, c.heal, got, c.want)
		}
		if got := signinSummaryStatus(p); got["signin_summary"] != "" {
			t.Errorf("rest %d heal %d: the reader refused the writer's line: %v", c.rest, c.heal, got)
		}
	}
}

// The header's sum adds each scope's ms and signin_heal_ms: from what the writer wrote, the heal counts once.
func TestSigninSummaryHealCountsOnce(t *testing.T) {
	signinSummaryCounters(t, 0, 0)
	p := filepath.Join(t.TempDir(), "signin-summary.10")
	t.Setenv("NOWHERE_SIGNIN_SUMMARY", p)
	m := chunkManifest{Chunks: []string{"a"}}
	t.Setenv("NOWHERE_PHASE", "apps")
	signinSummaryAppend(m, 1000, 300)
	t.Setenv("NOWHERE_PHASE", "secure")
	signinSummaryAppend(m, 200, 50)
	got := signinSummaryStatus(p)
	if got["signin_vault_ms"] != "700" || got["signin_de_ms"] != "150" || got["signin_heal_ms"] != "350" {
		t.Errorf("vault %q de %q heal %q, want 700, 150, 350 (700 + 150 + 350 = the restores' 1200)",
			got["signin_vault_ms"], got["signin_de_ms"], got["signin_heal_ms"])
	}
}

func TestSigninSummaryStatusHeal(t *testing.T) {
	// A later line of a scope replaces the earlier line's heal, as it does every other key of that scope.
	got := signinSummaryStatus(signinSummaryPlant(t, t.TempDir(), "s",
		"v=1 scope=vault ms=1 chunks=1 cached=1 fetched=0 heal_ms=5 store_reads=1 cap_calls=1\n"+
			"v=1 scope=de ms=1 chunks=1 cached=1 fetched=0 heal_ms=7 store_reads=1 cap_calls=1\n"+
			"v=1 scope=vault ms=1 chunks=1 cached=1 fetched=0 heal_ms=9 store_reads=3 cap_calls=2\n"))
	if got["signin_heal_ms"] != "16" {
		t.Errorf("signin_heal_ms = %q, want 16 (the vault's last 9 plus #de's 7)", got["signin_heal_ms"])
	}
	if got["signin_vault_store_reads"] != "3" || got["signin_vault_cap_calls"] != "2" {
		t.Errorf("vault reads %q caps %q, want the later line's 3 and 2", got["signin_vault_store_reads"], got["signin_vault_cap_calls"])
	}
	// A scope line with no heal still says 0.
	got = signinSummaryStatus(signinSummaryPlant(t, t.TempDir(), "s", "v=1 scope=sys ms=1 chunks=1 cached=1 fetched=0 heal_ms=0 store_reads=1 cap_calls=0\n"))
	if v, ok := got["signin_heal_ms"]; !ok || v != "0" {
		t.Errorf("a scope line with no heal: signin_heal_ms = %q (%v), want 0", v, ok)
	}
	// No scope line at all gives no heal key; a phase line gives only its own key.
	got = signinSummaryStatus(signinSummaryPlant(t, t.TempDir(), "s", "v=1 parked apps=3 size=unknown\nv=1 phase=acct ms=4\n"))
	want := map[string]string{"signin_parked_apps": "3", "signin_acct_ms": "4"}
	if len(got) != len(want) || got["signin_parked_apps"] != "3" || got["signin_acct_ms"] != "4" {
		t.Errorf("no scope line: %v, want %v", got, want)
	}
}

// restoreHeal times its heal, a scope that still defers reports no time, and a fixture restore's line carries it: the
// scope's ms and the heal add to the restore's whole time, and the store fields are the process's counters.
func TestSigninSummaryRestoreHealTime(t *testing.T) {
	state := healTestEnv(t)
	base := newHTTPStore(t)
	name, pass := "signin-summary-heal", "signin summary heal horse battery"
	createVault(base, name, pass)
	rel := "app.maps/files/maps/region.mwm"
	m := preGateHead(t, base, name, pass, rel, bytes.Repeat([]byte("SIGNIN-HEAL-TIME"), 5000), 0o644, time.Unix(1700000000, 0))
	dk := resolveDK(base, name, pass, nil)

	const delay = 80 * time.Millisecond
	orig := healFetchChunk
	healFetchChunk = func(b string, key []byte, version int, h string) ([]byte, error) {
		time.Sleep(delay)
		return orig(b, key, version, h)
	}
	t.Cleanup(func() { healFetchChunk = orig })

	cStart := time.Now()
	hr := restoreHeal(base, dk, m, t.TempDir(), name, pass, state)
	restMs := time.Since(cStart).Milliseconds()
	if hr.fetched != 1 || hr.ms < delay.Milliseconds() {
		t.Fatalf("vault: fetched %d in %d ms, want 1 file in at least %d ms", hr.fetched, hr.ms, delay.Milliseconds())
	}
	if hm := restoreHeal(base, dk, m, t.TempDir(), name+"#media", pass, state); hm.ms != 0 {
		t.Errorf("#media still defers: heal time %d, want 0", hm.ms)
	}

	p := filepath.Join(t.TempDir(), "signin-summary.10")
	t.Setenv("NOWHERE_SIGNIN_SUMMARY", p)
	t.Setenv("NOWHERE_PHASE", "apps")
	signinSummaryAppend(m, restMs, hr.ms)
	got := signinSummaryStatus(p)
	if got["signin_heal_ms"] != strconv.FormatInt(hr.ms, 10) || got["signin_vault_ms"] != strconv.FormatInt(restMs-hr.ms, 10) {
		t.Errorf("heal %q vault %q, want %d and %d", got["signin_heal_ms"], got["signin_vault_ms"], hr.ms, restMs-hr.ms)
	}
	if got["signin_vault_store_reads"] != strconv.FormatInt(atomic.LoadInt64(&traceGetN), 10) ||
		got["signin_vault_cap_calls"] != strconv.FormatInt(atomic.LoadInt64(&traceCapN), 10) {
		t.Errorf("reads %q caps %q, want the process's %d and %d", got["signin_vault_store_reads"], got["signin_vault_cap_calls"],
			atomic.LoadInt64(&traceGetN), atomic.LoadInt64(&traceCapN))
	}
}

// A batch /caps POST is a cap call: the normal restore's caps come through prefetchReadCapsOK since NWP-20261128-21.
func TestSigninSummaryPrefetchCountsCapCalls(t *testing.T) {
	resetCapReadCache(t)
	capReadGateway(t)
	c0 := atomic.LoadInt64(&traceCapN)
	prefetchReadCaps([]string{"k1", "k2"})
	if n := atomic.LoadInt64(&traceCapN) - c0; n != 1 {
		t.Errorf("one batch: %d cap call(s), want 1", n)
	}
	keys := make([]string, 513) // the prefetch's batch is 512
	for i := range keys {
		keys[i] = "b" + strconv.Itoa(i)
	}
	c0 = atomic.LoadInt64(&traceCapN)
	prefetchReadCaps(keys)
	if n := atomic.LoadInt64(&traceCapN) - c0; n != 2 {
		t.Errorf("513 keys: %d cap call(s), want 2", n)
	}
}

// The thirteen lines a sign-in writes, every field at its widest, fit the reader's bound and read back.
func TestSigninSummaryWidestFits(t *testing.T) {
	n := "999999999999"
	wide := "ms=" + n + " chunks=" + n + " cached=" + n + " fetched=" + n + " heal_ms=" + n + " store_reads=" + n + " cap_calls=" + n
	var b strings.Builder
	for _, s := range []string{"vault", "de", "apps", "sys"} {
		b.WriteString("v=1 scope=" + s + " " + wide + "\n")
	}
	b.WriteString("v=1 scope=media " + wide + " user_files=" + n + " user_bytes=999999999999999 other_files=" + n + " other_bytes=999999999999999\n")
	b.WriteString("v=1 parked apps=999999999 ce_kib=" + n + " de_kib=" + n + "\n")
	for _, w := range []string{"in", "reap", "reap", "reown", "reown", "reown", "acct"} {
		b.WriteString("v=1 phase=" + w + " ms=" + n + "\n")
	}
	if b.Len() > signinSummaryMaxBytes {
		t.Fatalf("the widest file is %d bytes, over the reader's %d", b.Len(), signinSummaryMaxBytes)
	}
	got := signinSummaryStatus(signinSummaryPlant(t, t.TempDir(), "s", b.String()))
	if got["signin_summary"] != "" || got["signin_reown_ms"] != "2999999999997" || got["signin_heal_ms"] != "4999999999995" {
		t.Errorf("the widest file: unreadable %q reown %q heal %q", got["signin_summary"], got["signin_reown_ms"], got["signin_heal_ms"])
	}
}

func TestSigninSummaryStatusSizeUnknownAndIndexed0(t *testing.T) {
	got := signinSummaryStatus(signinSummaryPlant(t, t.TempDir(), "s",
		"v=1 parked apps=3 size=unknown\nv=1 scope=media ms=5 chunks=1 cached=0 fetched=1 heal_ms=0 store_reads=0 cap_calls=0 indexed=0\n"))
	want := map[string]string{
		"signin_parked_apps": "3",
		"signin_media_ms":    "5", "signin_media_chunks": "1", "signin_media_cached": "0", "signin_media_fetched": "1",
		"signin_media_store_reads": "0", "signin_media_cap_calls": "0", "signin_heal_ms": "0",
		"signin_media_indexed": "0",
	}
	if len(got) != len(want) {
		t.Errorf("%d keys %v, want %v", len(got), got, want)
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s = %q, want %q", k, got[k], v)
		}
	}
}

func TestSigninSummaryStatusMissingAndEmpty(t *testing.T) {
	if got := signinSummaryStatus(filepath.Join(t.TempDir(), "signin-summary.10")); len(got) != 0 {
		t.Errorf("no file: %v, want no keys", got)
	}
	if got := signinSummaryStatus(signinSummaryPlant(t, t.TempDir(), "s", "")); len(got) != 0 {
		t.Errorf("an empty file: %v, want no keys", got)
	}
}

func TestSigninSummaryStatusUnreadable(t *testing.T) {
	good := "v=1 scope=vault ms=1 chunks=2 cached=0 fetched=2 heal_ms=0 store_reads=0 cap_calls=0\n"
	big := strings.Repeat(good, signinSummaryMaxBytes/len(good)+1)
	for _, c := range []struct{ label, body string }{
		{"oversized", big},
		{"a letter in a number", good + "v=1 scope=de ms=12a chunks=1 cached=0 fetched=1 heal_ms=0 store_reads=0 cap_calls=0\n"},
		{"an extra field", "v=1 scope=de ms=1 chunks=1 cached=0 fetched=1 heal_ms=0 store_reads=0 cap_calls=0 x=1\n"},
		{"extras on a non-media scope", "v=1 scope=vault ms=1 chunks=1 cached=0 fetched=1 heal_ms=0 store_reads=0 cap_calls=0 user_files=1 user_bytes=1 other_files=1 other_bytes=1\n"},
		{"a media line with neither the share nor indexed=0", "v=1 scope=media ms=1 chunks=2 cached=0 fetched=2 heal_ms=0 store_reads=0 cap_calls=0\n"},
		{"a truncated media line after a whole one", "v=1 scope=media ms=1 chunks=2 cached=0 fetched=2 heal_ms=0 store_reads=0 cap_calls=0 user_files=1 user_bytes=9 other_files=1 other_bytes=9\n" +
			"v=1 scope=media ms=1 chunks=2 cached=0 fetched=2 heal_ms=0 store_reads=0 cap_calls=0\n"},
		{"indexed=0 on a non-media scope", "v=1 scope=de ms=1 chunks=1 cached=0 fetched=1 heal_ms=0 store_reads=0 cap_calls=0 indexed=0\n"},
		{"a profile-name-shaped scope", "v=1 scope=alice ms=1 chunks=1 cached=0 fetched=1 heal_ms=0 store_reads=0 cap_calls=0\n"},
		{"a profile-name-shaped token", good + "v=1 parked apps=2 size=unknown gt1424-alice\n"},
		{"a path", good + "/data/user/10/com.ex.app\n"},
		{"a path in a value", "v=1 parked apps=/data/user/10 size=unknown\n"},
		{"v=2", "v=2 scope=vault ms=1 chunks=2 cached=0 fetched=2\n"},
		{"fields out of order", "v=1 scope=vault chunks=2 ms=1 cached=0 fetched=2 heal_ms=0 store_reads=0 cap_calls=0\n"},
		{"a blank line inside", good + "\n" + good},
		{"a negative value", "v=1 parked apps=-1 size=unknown\n"},
		{"half the sizes", "v=1 parked apps=1 ce_kib=5\n"},
		{"a CR line end", "v=1 parked apps=1 size=unknown\r\n"},
		{"a scope line without the store fields", "v=1 scope=vault ms=1 chunks=2 cached=0 fetched=2\n"},
		{"a scope line without cap_calls", "v=1 scope=vault ms=1 chunks=2 cached=0 fetched=2 heal_ms=0 store_reads=0\n"},
		{"the store fields out of order", "v=1 scope=vault ms=1 chunks=2 cached=0 fetched=2 heal_ms=0 cap_calls=0 store_reads=0\n"},
		{"a letter in heal_ms", "v=1 scope=vault ms=1 chunks=2 cached=0 fetched=2 heal_ms=1x store_reads=0 cap_calls=0\n"},
		{"a phase word outside the list", good + "v=1 phase=keystore ms=1\n"},
		{"a profile-name-shaped phase word", "v=1 phase=alice ms=1\n"},
		{"a letter in a phase value", "v=1 phase=in ms=1a\n"},
		{"an extra field on a phase line", "v=1 phase=in ms=1 x=1\n"},
		{"a phase line with no value", "v=1 phase=in\n"},
	} {
		got := signinSummaryStatus(signinSummaryPlant(t, t.TempDir(), "s", c.body))
		if len(got) != 1 || got["signin_summary"] != "unreadable" {
			t.Errorf("%s: %v, want exactly signin_summary=unreadable", c.label, got)
		}
	}
	d := filepath.Join(t.TempDir(), "signin-summary.10")
	if err := os.Mkdir(d, 0o700); err != nil {
		t.Fatal(err)
	}
	if got := signinSummaryStatus(d); len(got) != 1 || got["signin_summary"] != "unreadable" {
		t.Errorf("a directory: %v, want exactly signin_summary=unreadable", got)
	}
}

func TestSigninSummaryStatusLastWins(t *testing.T) {
	got := signinSummaryStatus(signinSummaryPlant(t, t.TempDir(), "s",
		"v=1 scope=vault ms=1 chunks=1 cached=1 fetched=0 heal_ms=0 store_reads=0 cap_calls=0\n"+
			"v=1 scope=media ms=2 chunks=2 cached=0 fetched=2 heal_ms=0 store_reads=0 cap_calls=0 user_files=1 user_bytes=9 other_files=1 other_bytes=9\n"+
			"v=1 parked apps=4 ce_kib=10 de_kib=20\n"+
			"v=1 scope=vault ms=7 chunks=8 cached=0 fetched=8 heal_ms=0 store_reads=0 cap_calls=0\n"+
			"v=1 scope=media ms=3 chunks=3 cached=3 fetched=0 heal_ms=0 store_reads=0 cap_calls=0 indexed=0\n"+
			"v=1 parked apps=5 size=unknown\n"))
	want := map[string]string{
		"signin_vault_ms": "7", "signin_vault_chunks": "8", "signin_vault_cached": "0", "signin_vault_fetched": "8",
		"signin_vault_store_reads": "0", "signin_vault_cap_calls": "0",
		"signin_media_ms": "3", "signin_media_chunks": "3", "signin_media_cached": "3", "signin_media_fetched": "0",
		"signin_media_store_reads": "0", "signin_media_cap_calls": "0", "signin_heal_ms": "0",
		"signin_media_indexed": "0",
		"signin_parked_apps":   "5",
	}
	if len(got) != len(want) {
		t.Errorf("%d keys %v, want %v (an earlier line's extras or sizes must not survive)", len(got), got, want)
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s = %q, want %q", k, got[k], v)
		}
	}
	for k, v := range got {
		if !signinSummaryDigits.MatchString(v) {
			t.Errorf("%s = %q, want digits only", k, v)
		}
	}
}

func TestSigninSummaryMerge(t *testing.T) {
	st := t.TempDir()
	t.Setenv("NOWHERE_STATE", st)
	signinSummaryPlant(t, st, "signin-summary.10", "v=1 scope=media ms=42 chunks=1 cached=0 fetched=1 heal_ms=0 store_reads=0 cap_calls=0 indexed=0\n")
	signinSummaryPlant(t, st, "signin-summary.11", "v=1 scope=vault ms=99 chunks=9 cached=9 fetched=0 heal_ms=0 store_reads=0 cap_calls=0\n")
	signinSummaryPlant(t, st, "signin-summary", "v=1 scope=apps ms=77 chunks=7 cached=7 fetched=0 heal_ms=0 store_reads=0 cap_calls=0\n")
	signinSummaryPlant(t, st, "signin-summary.", "v=1 scope=apps ms=78 chunks=7 cached=7 fetched=0 heal_ms=0 store_reads=0 cap_calls=0\n")

	// Device scope: nothing is added and nothing is removed.
	s := map[string]string{"x": "1", "signin_media_ms": "abc"}
	mergeSigninSummary(s, "10", true)
	if len(s) != 2 || s["signin_media_ms"] != "abc" {
		t.Errorf("device scope changed the status: %v", s)
	}
	// A uid that is empty or not all digits adds nothing.
	for _, uid := range []string{"", "1a", "../10", "10/", " 10", "-1"} {
		s := map[string]string{"x": "1"}
		mergeSigninSummary(s, uid, false)
		if len(s) != 1 {
			t.Errorf("uid %q: %v, want nothing added", uid, s)
		}
	}
	mergeSigninSummary(nil, "10", false) // must not panic

	// Session scope: the caller's signin_* keys are dropped, this uid's file is read, the other uid's is not.
	s = map[string]string{"x": "1", "signin_media_ms": "abc", "signin_bogus": "x", "last_signin_failure": "keep"}
	mergeSigninSummary(s, "10", false)
	want := map[string]string{
		"x": "1", "last_signin_failure": "keep",
		"signin_media_ms": "42", "signin_media_chunks": "1", "signin_media_cached": "0", "signin_media_fetched": "1",
		"signin_media_store_reads": "0", "signin_media_cap_calls": "0", "signin_heal_ms": "0",
		"signin_media_indexed": "0",
	}
	if len(s) != len(want) {
		t.Errorf("session scope: %v, want %v", s, want)
	}
	for k, v := range want {
		if s[k] != v {
			t.Errorf("session scope: %s = %q, want %q", k, s[k], v)
		}
	}
	for _, k := range []string{"signin_vault_ms", "signin_apps_ms", "signin_bogus"} {
		if _, ok := s[k]; ok {
			t.Errorf("session scope for uid 10 carries %s = %q (another uid's or a shared file, or a caller's key)", k, s[k])
		}
	}

	// A uid with no file of its own gets no keys, and still loses the caller's.
	s = map[string]string{"signin_vault_ms": "5"}
	mergeSigninSummary(s, "12", false)
	if len(s) != 0 {
		t.Errorf("uid 12, no file: %v, want no keys", s)
	}
}

// The report side: every key of the full fixture reaches a session report whatever the caller sent, none a gate report.
func TestSigninSummaryMergeCarriesEveryKey(t *testing.T) {
	st := t.TempDir()
	t.Setenv("NOWHERE_STATE", st)
	signinSummaryPlant(t, st, "signin-summary.10", signinSummaryFull)

	s := map[string]string{"x": "1", "signin_in_ms": "abc", "signin_heal_ms": "abc", "signin_reap_ms": "abc"}
	mergeSigninSummary(s, "10", false)
	if len(s) != len(signinSummaryFullKeys)+1 || s["x"] != "1" {
		t.Errorf("session scope: %d keys %v, want the %d of the fixture plus x", len(s), s, len(signinSummaryFullKeys))
	}
	for k, v := range signinSummaryFullKeys {
		if s[k] != v {
			t.Errorf("session scope: %s = %q, want %q", k, s[k], v)
		}
	}

	s = map[string]string{"x": "1"}
	mergeSigninSummary(s, "10", true)
	if len(s) != 1 {
		t.Errorf("device scope: %v, want nothing added", s)
	}

	// A caller's key never survives: a uid with a phase-only file gives that key and removes the caller's others.
	signinSummaryPlant(t, st, "signin-summary.11", "v=1 phase=reap ms=5\n")
	s = map[string]string{"signin_in_ms": "9", "signin_acct_ms": "9"}
	mergeSigninSummary(s, "11", false)
	if len(s) != 1 || s["signin_reap_ms"] != "5" {
		t.Errorf("uid 11: %v, want only signin_reap_ms=5", s)
	}
}

// The call sites: main.go appends once, in the restore verb's CDC branch after the restore line; the report
// handler merges once, right after mergeSigninFail.
func TestSigninSummarySourcePins(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	if n := strings.Count(src, "signinSummaryAppend("); n != 1 {
		t.Fatalf("main.go calls signinSummaryAppend %d times, want 1", n)
	}
	head := "if bytes.HasPrefix(pt, cdcMagic) {\n\t\t\tvar m chunkManifest"
	tail := "skipped = untarFrom(dest, bytes.NewReader(pt))"
	i := strings.Index(src, head)
	if i < 0 {
		t.Fatal("main.go: the restore verb's CDC branch head not found")
	}
	j := strings.Index(src[i:], tail)
	if j < 0 {
		t.Fatal("main.go: the restore verb's legacy branch not found after its CDC branch")
	}
	branch := src[i : i+j]
	k := strings.Index(branch, "signinSummaryAppend(m, restMs, hr.ms)")
	r := strings.Index(branch, `fmt.Printf("restore: profile %s (%d chunks: %d cached`)
	if k < 0 || r < 0 || k < r {
		t.Errorf("main.go: signinSummaryAppend(m, restMs, hr.ms) must sit in the CDC branch after the restore line (at %d, restore line at %d)", k, r)
	}
	if !strings.Contains(branch, "hr := restoreHeal(base, key, m, dest, profile, pass,") {
		t.Error("main.go: the restore verb must keep restoreHeal's result for the summary")
	}

	b, err = os.ReadFile("report_issue.go")
	if err != nil {
		t.Fatal(err)
	}
	src = string(b)
	call := "mergeSigninSummary(rep.Status, uid, deviceScope)"
	if n := strings.Count(src, call); n != 1 {
		t.Fatalf("report_issue.go holds %q %d times, want 1", call, n)
	}
	f := strings.Index(src, "mergeSigninFail(rep.Status, dest, deviceScope, time.Now())")
	if f < 0 {
		t.Fatal("report_issue.go: the mergeSigninFail call not found")
	}
	nl := strings.Index(src[f:], "\n")
	next := strings.TrimSpace(strings.SplitN(src[f+nl+1:], "\n", 2)[0])
	if !strings.HasPrefix(next, call) {
		t.Errorf("report_issue.go: the line after mergeSigninFail is %q, want %s", next, call)
	}
}
