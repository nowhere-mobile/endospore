package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync/atomic"
	"testing"
)

// NWP-20261122-09 (backlog: An issue report's logs sections keep only the last 299 lines of each log, ...): the `in`
// op's restores and od_parked_report write $STATE/signin-summary.<uid>, and an in-session issue report carries it as
// signin_* status keys, digits only, for its own uid only, never at the gate.

var signinSummaryDigits = regexp.MustCompile(`^[0-9]+$`)

// signinSummaryCounters sets the restore's cache counters for one test and puts them back after it.
func signinSummaryCounters(t *testing.T, hits, miss int64) {
	t.Helper()
	h0, m0 := atomic.LoadInt64(&chunkHits), atomic.LoadInt64(&chunkMiss)
	atomic.StoreInt64(&chunkHits, hits)
	atomic.StoreInt64(&chunkMiss, miss)
	t.Cleanup(func() {
		atomic.StoreInt64(&chunkHits, h0)
		atomic.StoreInt64(&chunkMiss, m0)
	})
}

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
		signinSummaryAppend(m, 1234)
		want := "v=1 scope=" + scope + " ms=1234 chunks=7 cached=3 fetched=4\n"
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
	signinSummaryAppend(chunkManifest{Chunks: []string{"a"}, Ess: map[string]essRegion{"DCIM/a": {S: 0, E: 1, Size: 5}}}, 1)
	if got := signinSummaryRead(t, p); got != "v=1 scope=vault ms=1 chunks=1 cached=3 fetched=4\n" {
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
	signinSummaryAppend(m, 88000)
	uf, ub, of, ob, _ := mediaUserShare(m)
	if uf != 2 || ub != 1200 || of != 1 || ob != 30 {
		t.Fatalf("mediaUserShare = %d %d %d %d, want 2 1200 1 30", uf, ub, of, ob)
	}
	want := "v=1 scope=media ms=88000 chunks=3 cached=1 fetched=2 user_files=2 user_bytes=1200 other_files=1 other_bytes=30\n"
	if got := signinSummaryRead(t, p); got != want {
		t.Errorf("media: %q, want %q", got, want)
	}

	p = filepath.Join(t.TempDir(), "signin-summary.10")
	t.Setenv("NOWHERE_SIGNIN_SUMMARY", p)
	signinSummaryAppend(chunkManifest{Chunks: []string{"c0"}}, 5)
	if got := signinSummaryRead(t, p); got != "v=1 scope=media ms=5 chunks=1 cached=1 fetched=2 indexed=0\n" {
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
		signinSummaryAppend(m, 1)
		if ents, _ := os.ReadDir(d); len(ents) != 0 {
			t.Errorf("phase %q wrote %d file(s), want none", phase, len(ents))
		}
	}
	t.Setenv("NOWHERE_PHASE", "apps")
	t.Setenv("NOWHERE_SIGNIN_SUMMARY", "")
	signinSummaryAppend(m, 1) // nothing to check but that it does not panic or write into the cwd
	d := t.TempDir()
	t.Chdir(d)
	t.Setenv("NOWHERE_SIGNIN_SUMMARY", "signin-summary.10")
	signinSummaryAppend(m, 1)
	if ents, _ := os.ReadDir(d); len(ents) != 0 {
		t.Errorf("a relative path wrote %d file(s), want none", len(ents))
	}
}

func TestSigninSummaryAppendTwoLines(t *testing.T) {
	signinSummaryCounters(t, 0, 9)
	p := filepath.Join(t.TempDir(), "signin-summary.10")
	t.Setenv("NOWHERE_SIGNIN_SUMMARY", p)
	t.Setenv("NOWHERE_PHASE", "apps")
	signinSummaryAppend(chunkManifest{Chunks: []string{"a"}}, 10)
	t.Setenv("NOWHERE_PHASE", "secure")
	signinSummaryAppend(chunkManifest{Chunks: []string{"a", "b"}}, 20)
	want := "v=1 scope=vault ms=10 chunks=1 cached=0 fetched=9\nv=1 scope=de ms=20 chunks=2 cached=0 fetched=9\n"
	if got := signinSummaryRead(t, p); got != want {
		t.Errorf("two appends: %q, want %q", got, want)
	}
	// And the reader takes what the writer wrote.
	got := signinSummaryStatus(p)
	if got["signin_vault_ms"] != "10" || got["signin_de_chunks"] != "2" || got["signin_summary"] != "" {
		t.Errorf("read back: %v", got)
	}
}

const signinSummaryFull = "v=1 scope=vault ms=61000 chunks=900 cached=12 fetched=888\n" +
	"v=1 scope=de ms=4000 chunks=40 cached=1 fetched=39\n" +
	"v=1 scope=media ms=88000 chunks=1700 cached=0 fetched=1700 user_files=310 user_bytes=1700000000 other_files=55 other_bytes=90000000\n" +
	"v=1 scope=apps ms=9000 chunks=120 cached=100 fetched=20\n" +
	"v=1 scope=sys ms=700 chunks=3 cached=0 fetched=3\n" +
	"v=1 parked apps=14 ce_kib=812000 de_kib=4100\n"

func TestSigninSummaryStatusFull(t *testing.T) {
	got := signinSummaryStatus(signinSummaryPlant(t, t.TempDir(), "signin-summary.10", signinSummaryFull))
	want := map[string]string{
		"signin_vault_ms": "61000", "signin_vault_chunks": "900", "signin_vault_cached": "12", "signin_vault_fetched": "888",
		"signin_de_ms": "4000", "signin_de_chunks": "40", "signin_de_cached": "1", "signin_de_fetched": "39",
		"signin_media_ms": "88000", "signin_media_chunks": "1700", "signin_media_cached": "0", "signin_media_fetched": "1700",
		"signin_media_user_files": "310", "signin_media_user_bytes": "1700000000",
		"signin_media_other_files": "55", "signin_media_other_bytes": "90000000", "signin_media_indexed": "1",
		"signin_apps_ms": "9000", "signin_apps_chunks": "120", "signin_apps_cached": "100", "signin_apps_fetched": "20",
		"signin_sys_ms": "700", "signin_sys_chunks": "3", "signin_sys_cached": "0", "signin_sys_fetched": "3",
		"signin_parked_apps": "14", "signin_parked_ce_kib": "812000", "signin_parked_de_kib": "4100",
	}
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

func TestSigninSummaryStatusSizeUnknownAndIndexed0(t *testing.T) {
	got := signinSummaryStatus(signinSummaryPlant(t, t.TempDir(), "s",
		"v=1 parked apps=3 size=unknown\nv=1 scope=media ms=5 chunks=1 cached=0 fetched=1 indexed=0\n"))
	want := map[string]string{
		"signin_parked_apps": "3",
		"signin_media_ms":    "5", "signin_media_chunks": "1", "signin_media_cached": "0", "signin_media_fetched": "1",
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
	good := "v=1 scope=vault ms=1 chunks=2 cached=0 fetched=2\n"
	big := strings.Repeat(good, signinSummaryMaxBytes/len(good)+1)
	for _, c := range []struct{ label, body string }{
		{"oversized", big},
		{"a letter in a number", good + "v=1 scope=de ms=12a chunks=1 cached=0 fetched=1\n"},
		{"an extra field", "v=1 scope=de ms=1 chunks=1 cached=0 fetched=1 x=1\n"},
		{"extras on a non-media scope", "v=1 scope=vault ms=1 chunks=1 cached=0 fetched=1 user_files=1 user_bytes=1 other_files=1 other_bytes=1\n"},
		{"a media line with neither the share nor indexed=0", "v=1 scope=media ms=1 chunks=2 cached=0 fetched=2\n"},
		{"a truncated media line after a whole one", "v=1 scope=media ms=1 chunks=2 cached=0 fetched=2 user_files=1 user_bytes=9 other_files=1 other_bytes=9\n" +
			"v=1 scope=media ms=1 chunks=2 cached=0 fetched=2\n"},
		{"indexed=0 on a non-media scope", "v=1 scope=de ms=1 chunks=1 cached=0 fetched=1 indexed=0\n"},
		{"a profile-name-shaped scope", "v=1 scope=alice ms=1 chunks=1 cached=0 fetched=1\n"},
		{"a profile-name-shaped token", good + "v=1 parked apps=2 size=unknown gt1424-alice\n"},
		{"a path", good + "/data/user/10/com.ex.app\n"},
		{"a path in a value", "v=1 parked apps=/data/user/10 size=unknown\n"},
		{"v=2", "v=2 scope=vault ms=1 chunks=2 cached=0 fetched=2\n"},
		{"fields out of order", "v=1 scope=vault chunks=2 ms=1 cached=0 fetched=2\n"},
		{"a blank line inside", good + "\n" + good},
		{"a negative value", "v=1 parked apps=-1 size=unknown\n"},
		{"half the sizes", "v=1 parked apps=1 ce_kib=5\n"},
		{"a CR line end", "v=1 parked apps=1 size=unknown\r\n"},
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
		"v=1 scope=vault ms=1 chunks=1 cached=1 fetched=0\n"+
			"v=1 scope=media ms=2 chunks=2 cached=0 fetched=2 user_files=1 user_bytes=9 other_files=1 other_bytes=9\n"+
			"v=1 parked apps=4 ce_kib=10 de_kib=20\n"+
			"v=1 scope=vault ms=7 chunks=8 cached=0 fetched=8\n"+
			"v=1 scope=media ms=3 chunks=3 cached=3 fetched=0 indexed=0\n"+
			"v=1 parked apps=5 size=unknown\n"))
	want := map[string]string{
		"signin_vault_ms": "7", "signin_vault_chunks": "8", "signin_vault_cached": "0", "signin_vault_fetched": "8",
		"signin_media_ms": "3", "signin_media_chunks": "3", "signin_media_cached": "3", "signin_media_fetched": "0",
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
	signinSummaryPlant(t, st, "signin-summary.10", "v=1 scope=media ms=42 chunks=1 cached=0 fetched=1 indexed=0\n")
	signinSummaryPlant(t, st, "signin-summary.11", "v=1 scope=vault ms=99 chunks=9 cached=9 fetched=0\n")
	signinSummaryPlant(t, st, "signin-summary", "v=1 scope=apps ms=77 chunks=7 cached=7 fetched=0\n")
	signinSummaryPlant(t, st, "signin-summary.", "v=1 scope=apps ms=78 chunks=7 cached=7 fetched=0\n")

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
	k := strings.Index(branch, "signinSummaryAppend(m, restMs)")
	r := strings.Index(branch, `fmt.Printf("restore: profile %s (%d chunks: %d cached`)
	if k < 0 || r < 0 || k < r {
		t.Errorf("main.go: signinSummaryAppend(m, restMs) must sit in the CDC branch after the restore line (at %d, restore line at %d)", k, r)
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
