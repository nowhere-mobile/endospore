package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20261208-01 (backlog: "P1: On-demand apps that are not on the phone at a sign-out are dropped from the `#apps`
// code list, ..."). An #apps seal records its carry counts in the state dir; the next #apps restore of the same
// profile moves them into that sign-in's summary file, which a session issue report reads into status keys.

// appsSealRead reads a profile's record WITHOUT removing it; "" when there is none.
func appsSealRead(t *testing.T, state, profile, pass string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(state, appsSealFile(profile, pass)))
	if os.IsNotExist(err) {
		return ""
	}
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// appsSealFields parses a record into its nine fields; it fails the test on any other shape.
func appsSealFields(t *testing.T, rec string) map[string]string {
	t.Helper()
	line := strings.TrimSuffix(rec, "\n")
	m := signinSummaryAppsSealRe.FindStringSubmatch(line)
	if m == nil || !strings.HasSuffix(rec, "\n") {
		t.Fatalf("the record %q is not one appsseal line", rec)
	}
	out := map[string]string{}
	for i, k := range signinSummaryAppsSealKeys {
		out[k] = m[i+1]
	}
	return out
}

func TestAppsSealRoundTrip(t *testing.T) {
	st := t.TempDir()
	const prof, pass = "asrt#apps", "correct horse battery staple"
	writeAppsSeal(st, prof, pass, appsSealCounts{1, 2, 3, 4, 5, 6, 7, 8, "passed"})
	fi, err := os.Stat(filepath.Join(st, appsSealFile(prof, pass)))
	if err != nil {
		t.Fatalf("the record was not written: %v", err)
	}
	if fi.Mode().Perm() != 0o600 {
		t.Errorf("the record's mode is %v, want 0600", fi.Mode().Perm())
	}
	want := "v=1 appsseal stored=1 dormant=2 adopted=3 carried=4 dropped=5 published=6 lost=7 vanished=8 guard=passed"
	line, ok := takeAppsSeal(st, prof, pass)
	if !ok || line != want {
		t.Fatalf("take = %q, %v; want %q, true", line, ok, want)
	}
	if _, err := os.Stat(filepath.Join(st, appsSealFile(prof, pass))); !os.IsNotExist(err) {
		t.Fatalf("the record is still there after a take (%v): the next sign-in would report an old seal", err)
	}
	if line, ok := takeAppsSeal(st, prof, pass); ok || line != "" {
		t.Fatalf("a second take = %q, %v; want nothing", line, ok)
	}
	if ents, _ := os.ReadDir(st); len(ents) != 0 {
		t.Fatalf("the state dir holds %d entries after the take, want none", len(ents))
	}

	// A record that is not the exact shape is removed and not returned.
	junk := filepath.Join(st, appsSealFile(prof, pass))
	if err := os.WriteFile(junk, []byte("v=1 appsseal stored=com.example.x\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if line, ok := takeAppsSeal(st, prof, pass); ok || line != "" {
		t.Fatalf("a junk record was taken as %q", line)
	}
	if _, err := os.Stat(junk); !os.IsNotExist(err) {
		t.Fatal("a junk record was left in place")
	}

	// stateDir "" is inert: no file appears in the working directory.
	cwd := t.TempDir()
	t.Chdir(cwd)
	writeAppsSeal("", prof, pass, appsSealCounts{guard: "none"})
	removeAppsSeal("", prof, pass)
	if line, ok := takeAppsSeal("", prof, pass); ok || line != "" {
		t.Fatalf("take with no state dir = %q, %v", line, ok)
	}
	if ents, _ := os.ReadDir(cwd); len(ents) != 0 {
		t.Fatalf("an empty state dir wrote %d file(s) into the working directory", len(ents))
	}
}

func TestAppsSealOtherProfile(t *testing.T) {
	st := t.TempDir()
	const a, b = "asoa#apps", "asob#apps"
	const p1, p2 = "correct horse battery staple", "another passphrase entirely"
	writeAppsSeal(st, a, p1, appsSealCounts{stored: 3, guard: "passed"})
	sum := filepath.Join(t.TempDir(), "signin-summary.10")
	t.Setenv("NOWHERE_PHASE", "appcode")
	t.Setenv("NOWHERE_SIGNIN_SUMMARY", sum)
	m := chunkManifest{Apps: map[string]string{"com.example.x": "l"}}
	signinSummaryAppendApps(m, st, b, p1) // another profile
	signinSummaryAppendApps(m, st, a, p2) // the same name under another passphrase
	got, _ := os.ReadFile(sum)
	if string(got) != "v=1 appsindex pkgs=1\nv=1 appsindex pkgs=1\n" {
		t.Fatalf("another profile's restore wrote %q; it must never take this profile's record", got)
	}
	if appsSealRead(t, st, a, p1) == "" {
		t.Fatal("another profile's restore removed this profile's record")
	}
	signinSummaryAppendApps(m, st, a, p1)
	got, _ = os.ReadFile(sum)
	if !strings.HasSuffix(string(got), "v=1 appsindex pkgs=1\nv=1 appsseal stored=3 dormant=0 adopted=0 carried=0 dropped=0 published=0 lost=0 vanished=0 guard=passed\n") {
		t.Fatalf("the profile's own restore did not take its record: %q", got)
	}
}

func TestAppsSealOverIndexlessHead(t *testing.T) {
	st := t.TempDir()
	t.Setenv("NOWHERE_STATE", st)
	const name = "asdormant"
	dormantD1(t, newHTTPStore(t), name)
	f := appsSealFields(t, appsSealRead(t, st, name+"#apps", dormantPass))
	want := map[string]string{"stored": "0", "dormant": "3", "adopted": "3", "carried": "0", "dropped": "0",
		"published": "4", "lost": "0", "vanished": "0", "guard": "passed"}
	for k, v := range want {
		if f[k] != v {
			t.Errorf("the record's %s is %q, want %q (record %v)", k, f[k], v, f)
		}
	}
}

func TestAppsSealGuardRefused(t *testing.T) {
	st := t.TempDir()
	t.Setenv("NOWHERE_STATE", st)
	base := newHTTPStore(t)
	const name = "asguard"
	before := dormantIndexless(t, base, name, dormantOD...)
	out, refused := dormantSeal(t, base, name, dormantStage(t), true, "")
	if !refused || sealRefusedWhy != "apps-vanished" {
		t.Fatalf("fixture: the D4 seal was not refused apps-vanished (refused %v, why %q):\n%s", refused, sealRefusedWhy, out)
	}
	f := appsSealFields(t, appsSealRead(t, st, name+"#apps", dormantPass))
	if f["guard"] != "refused" || (f["lost"] == "0" && f["vanished"] == "0") {
		t.Errorf("the refused seal's record says guard=%s lost=%s vanished=%s, want guard=refused with a loss",
			f["guard"], f["lost"], f["vanished"])
	}
	if f["lost"] != "3" {
		t.Errorf("the record's lost is %q, want 3", f["lost"])
	}
	if dormantHeadJSON(t, headManifestOf(t, base, name+"#apps", dormantPass)) != dormantHeadJSON(t, before) {
		t.Error("the refused seal changed the stored head")
	}
	sealRefused, sealRefusedWhy = false, ""
}

// TestAppsSealStaleRemoved: the shrink guard, carry off, refuses an empty #apps stage over a six-chunk head ("walked
// ... NONE >=" a 1 KiB file threshold). It returns before the presence guard and writes no record; an older record
// must not survive it.
func TestAppsSealStaleRemoved(t *testing.T) {
	base := newHTTPStore(t)
	st := t.TempDir()
	t.Setenv("NOWHERE_STATE", st)
	t.Setenv("NOWHERE_CARRY_ESSENTIAL", "0")
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "1024") // each base.apk is its own chunk, so the head clears the floor of 4
	const name, pass = "asstale", "correct horse battery staple"
	createVault(base, name, pass)
	if refused := sealApps(t, base, name, pass, stageApps(t, "com.example.s1", "com.example.s2", "com.example.s3",
		"com.example.s4", "com.example.s5", "com.example.s6")); refused {
		t.Fatal("fixture: the first #apps seal was refused")
	}
	writeAppsSeal(st, name+"#apps", pass, appsSealCounts{stored: 99, guard: "none"})
	if refused := sealApps(t, base, name, pass, stageApps(t)); !refused || sealRefusedWhy != "shrink" {
		t.Fatalf("fixture: the empty stage was not refused by the shrink guard (refused %v, why %q)", refused, sealRefusedWhy)
	}
	if rec := appsSealRead(t, st, name+"#apps", pass); rec != "" {
		t.Fatalf("a seal refused before the presence guard left an older seal's record: %q", rec)
	}
	sealRefused, sealRefusedWhy = false, ""
}

func TestAppsSealRestoreAppends(t *testing.T) {
	const prof, pass = "asrestore#apps", "correct horse battery staple"
	m := chunkManifest{Apps: map[string]string{"a.a": "1", "b.b": "2", "c.c": "3", "d.d": "4"}}
	rec := appsSealCounts{stored: 2, dormant: 3, adopted: 3, published: 5, guard: "passed"}

	// The #apps phase appends the index count, then the taken record.
	st := t.TempDir()
	sum := filepath.Join(t.TempDir(), "signin-summary.11")
	writeAppsSeal(st, prof, pass, rec)
	t.Setenv("NOWHERE_SIGNIN_SUMMARY", sum)
	t.Setenv("NOWHERE_PHASE", "appcode")
	signinSummaryAppendApps(m, st, prof, pass)
	got, _ := os.ReadFile(sum)
	if want := "v=1 appsindex pkgs=4\n" + appsSealLine(rec) + "\n"; string(got) != want {
		t.Fatalf("the #apps restore wrote %q, want %q", got, want)
	}
	if appsSealRead(t, st, prof, pass) != "" {
		t.Fatal("the record is still there after the #apps restore took it")
	}
	keys := signinSummaryStatus(sum)
	if keys["signin_apps_index_pkgs"] != "4" || keys["lastseal_apps_adopted"] != "3" || keys["lastseal_apps_guard"] != "passed" {
		t.Fatalf("the summary's keys: %v", keys)
	}

	// Any other phase writes nothing and leaves the record.
	st2 := t.TempDir()
	sum2 := filepath.Join(t.TempDir(), "signin-summary.12")
	writeAppsSeal(st2, prof, pass, rec)
	t.Setenv("NOWHERE_SIGNIN_SUMMARY", sum2)
	for _, ph := range []string{"apps", "secure", "media", "accounts", ""} {
		t.Setenv("NOWHERE_PHASE", ph)
		signinSummaryAppendApps(m, st2, prof, pass)
	}
	if b, err := os.ReadFile(sum2); err == nil {
		t.Fatalf("a restore of another phase wrote %q", b)
	}
	if appsSealRead(t, st2, prof, pass) == "" {
		t.Fatal("a restore of another phase took the #apps record")
	}

	// A relative summary path writes nothing and leaves the record.
	t.Setenv("NOWHERE_PHASE", "appcode")
	t.Setenv("NOWHERE_SIGNIN_SUMMARY", "signin-summary.13")
	signinSummaryAppendApps(m, st2, prof, pass)
	if appsSealRead(t, st2, prof, pass) == "" {
		t.Fatal("a relative summary path took the record")
	}

	// The restore verb calls it in the CDC branch, after signinSummaryAppend.
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	i := strings.Index(src, "if bytes.HasPrefix(pt, cdcMagic) {\n\t\t\tvar m chunkManifest")
	if i < 0 {
		t.Fatal("main.go: the restore verb's CDC branch head not found")
	}
	j := strings.Index(src[i:], "} else {\n\t\t\tskipped = untarFrom(")
	if j < 0 {
		t.Fatal("main.go: the restore verb's legacy branch not found")
	}
	branch := src[i : i+j]
	k := strings.Index(branch, "signinSummaryAppend(m, restMs, hr.ms)")
	a := strings.Index(branch, "\n\t\t\tsigninSummaryAppendApps(m, os.Getenv(\"NOWHERE_STATE\"), profile, pass)\n")
	if k < 0 || a < 0 || a < k {
		t.Errorf("main.go: the CDC branch must call signinSummaryAppendApps after signinSummaryAppend (at %d, append at %d)", a, k)
	}
}

func TestSigninSummaryAppsKeys(t *testing.T) {
	dir := t.TempDir()
	seal := "v=1 appsseal stored=46 dormant=23 adopted=23 carried=0 dropped=1 published=46 lost=0 vanished=0 guard=passed"
	got := signinSummaryStatus(signinSummaryPlant(t, dir, "ok", "v=1 appsindex pkgs=46\n"+seal+"\n"))
	want := map[string]string{
		"signin_apps_index_pkgs": "46",
		"lastseal_apps_stored":   "46", "lastseal_apps_dormant": "23", "lastseal_apps_adopted": "23",
		"lastseal_apps_carried": "0", "lastseal_apps_dropped": "1", "lastseal_apps_published": "46",
		"lastseal_apps_lost": "0", "lastseal_apps_vanished": "0", "lastseal_apps_guard": "passed",
	}
	if len(got) != len(want) {
		t.Errorf("%d keys %v, want %v", len(got), got, want)
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s = %q, want %q", k, got[k], v)
		}
	}
	for i, bad := range []string{
		seal + " extra=1",
		strings.Replace(seal, "stored=46", "stored=com.example.x", 1),
		strings.Replace(seal, "guard=passed", "guard=maybe", 1),
		strings.Replace(seal, "guard=passed", "guard=passed\x00", 1),
		strings.Replace(seal, "lost=0", "lost=1234567890", 1),
		"v=1 appsindex pkgs=1 x=2",
		"v=1 appsindex pkgs=",
	} {
		got := signinSummaryStatus(signinSummaryPlant(t, dir, "bad", "v=1 appsindex pkgs=1\n"+bad+"\n"))
		if len(got) != 1 || got["signin_summary"] != "unreadable" {
			t.Errorf("case %d %q gave %v, want signin_summary=unreadable alone", i, bad, got)
		}
	}

	// Only the file sets a lastseal key: a caller-sent one is deleted when the file has none.
	t.Setenv("NOWHERE_STATE", dir)
	status := map[string]string{"lastseal_apps_guard": "passed", "signin_apps_index_pkgs": "9", "other": "x"}
	mergeSigninSummary(status, "424242", false)
	if len(status) != 1 || status["other"] != "x" {
		t.Errorf("a caller-sent lastseal or signin key survived the merge: %v", status)
	}
}
