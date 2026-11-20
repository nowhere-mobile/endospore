package main

import (
	"bytes"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"
)

// NWP-20261208-15: a bare-shaped #de, #sys, #keys or #apps seal records the chunks it stopped naming, the next due
// bare-vault seal releases them under the BARE vault's release generation, and a bare-shaped scope push checks that
// generation. test-seal-prune-scopedrop.sh re-runs these tests against copies of seal_prune_release.go and main.go
// with each guard broken in turn. Every test uses its OWN profile name and its own blob cache dir (sprelSetup or
// relGenEnv). The record file is parsed here by hand, so every assertion runs (and fails) against a tree without it.

// sprsdRecords parses <cache>.scopedrop: the records by tag, whether a `last` line is there, and the raw bytes.
func sprsdRecords(t *testing.T, cache string) (map[string]map[string]bool, bool, string) {
	t.Helper()
	byTag := map[string]map[string]bool{}
	b, err := os.ReadFile(cache + ".scopedrop")
	if err != nil {
		if os.IsNotExist(err) {
			return byTag, false, ""
		}
		t.Fatal(err)
	}
	last := false
	for _, line := range strings.Split(string(b), "\n") {
		f := strings.Fields(line)
		if len(f) != 2 {
			continue
		}
		if f[0] == "last" {
			last = true
			continue
		}
		if byTag[f[0]] == nil {
			byTag[f[0]] = map[string]bool{}
		}
		byTag[f[0]][f[1]] = true
	}
	return byTag, last, string(b)
}

func sprsdTag(r *sprel, scoped string) string {
	return relGenTag(relGenHeadKey(r.base, scoped, r.pass))
}

func sprsdBareGen(t *testing.T, r *sprel) uint64 {
	t.Helper()
	v, _ := snapDelHead(t, r.base, r.name, r.pass)
	return v.ReleaseGen
}

// sprsdSealAt is sprscSeal with round n's files and fixed times, so two seals of one round write the same stream.
func sprsdSealAt(t *testing.T, r *sprel, scoped string, n int) string {
	t.Helper()
	files := map[string][]byte{
		"churn.txt": bytes.Repeat([]byte(fmt.Sprintf("round %d of %s ", n, scoped)), 900),
		"stay.bin":  sprelRandom(1, r.big),
		"gone.bin":  sprelRandom(2, r.big),
	}
	for f, b := range files {
		if err := os.WriteFile(filepath.Join(r.src, f), b, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	at := time.Unix(1700000000+int64(n), 0)
	for _, f := range []string{"churn.txt", "stay.bin", "gone.bin", ""} {
		if err := os.Chtimes(filepath.Join(r.src, f), at, at); err != nil {
			t.Fatal(err)
		}
	}
	return captureStdout(t, func() { pushProfile(r.base, scoped, r.pass, r.src) })
}

func sprsdMinus(a, b map[string]bool) map[string]bool {
	out := map[string]bool{}
	for k := range a {
		if !b[k] {
			out[k] = true
		}
	}
	return out
}

func TestSealPruneScopeDropOffRecordsNothing(t *testing.T) {
	r := sprelSetup(t, "sprsd-off", "scope drop off records nothing", 4096)
	// NWP-20261116-56: the flag ships on, so the off case is set here, not assumed from package init.
	old := scopeReleaseOn
	t.Cleanup(func() { scopeReleaseOn = old })
	scopeReleaseOn = false
	scoped := r.name + "#de"
	for i := 0; i < 3; i++ {
		sprscSeal(t, r, scoped, true)
	}
	if _, err := os.Stat(r.cache + ".scopedrop"); !os.IsNotExist(err) {
		t.Errorf("three #de seals with scopeReleaseOn off left a record file (stat: %v)", err)
	}
	// The control: the same seal with the release on records.
	sprscOn(t)
	sprscSeal(t, r, scoped, true)
	if recs, _, _ := sprsdRecords(t, r.cache); len(recs[sprsdTag(r, scoped)]) == 0 {
		t.Error("a churned #de seal with scopeReleaseOn on recorded nothing")
	}
}

func TestSealPruneScopeDropRecordsFreed(t *testing.T) {
	r := sprelSetup(t, "sprsd-rec", "scope drop records the freed chunks", 4096)
	sprscOn(t)
	scoped := r.name + "#de"
	key := deriveKey(scoped, r.pass)
	sprscSeal(t, r, scoped, true)
	h1 := readHead(r.base, scoped, r.pass)
	logs := sprscSeal(t, r, scoped, true)
	h2 := readHead(r.base, scoped, r.pass)
	if h1 == "" || h2 == "" || h1 == h2 {
		t.Fatalf("fixture: heads %q, %q", short(h1), short(h2))
	}
	want := sprsdMinus(sprscBlobs(t, r, key, h1), sprscBlobs(t, r, key, h2))
	if len(want) == 0 {
		t.Fatal("fixture: the second seal stopped naming nothing")
	}
	recs, _, _ := sprsdRecords(t, r.cache)
	got := recs[sprsdTag(r, scoped)]
	for k := range want {
		if !got[k] {
			t.Errorf("%s: the #de seal stopped naming it, but it was not recorded", short(k))
		}
	}
	for k := range got {
		if !want[k] {
			t.Errorf("%s was recorded, but the new #de head names it", short(k))
		}
	}
	if n := r.releases(); n != 0 {
		t.Errorf("%d /release request(s) from a bare-shaped scope seal\n%s", n, logs)
	}
}

func TestSealPruneScopeDropBareSealReleases(t *testing.T) {
	r := sprelSetup(t, "sprsd-bare", "scope drop releases at the bare seal", 4096)
	sprscOn(t)
	scoped := r.name + "#de"
	key := deriveKey(scoped, r.pass)
	for i := 0; i < 3; i++ {
		sprscSeal(t, r, scoped, true)
	}
	tag := sprsdTag(r, scoped)
	recs, _, _ := sprsdRecords(t, r.cache)
	recorded := recs[tag]
	if len(recorded) == 0 {
		t.Fatal("precondition: three churned #de seals recorded nothing")
	}
	want := sprsdMinus(recorded, sprscBlobs(t, r, key, readHead(r.base, scoped, r.pass)))
	g0 := sprsdBareGen(t, r)
	logs := r.seal(t, true)
	if g := sprsdBareGen(t, r); g != g0+1 {
		t.Errorf("bare release generation %d -> %d, want +1\n%s", g0, g, logs)
	}
	if n := r.releases(); n != 1 {
		t.Fatalf("%d /release request(s) from the bare seal, want 1\n%s", n, logs)
	}
	got := r.sent(t)
	if len(got) != len(want) {
		t.Errorf("released %d keys, want %d\n%s", len(got), len(want), logs)
	}
	for k := range want {
		if p, ok := got[k]; !ok {
			t.Errorf("%s was recorded but not released", short(k))
		} else if p != hex.EncodeToString(blobReleaseProof(key, k)) {
			t.Errorf("%s: the preimage is not blobReleaseProof(#de key, key)", short(k))
		}
	}
	after, last, _ := sprsdRecords(t, r.cache)
	if len(after[tag]) != 0 {
		t.Errorf("%d #de record(s) left after the release", len(after[tag]))
	}
	if !last {
		t.Error("no `last` line after the release")
	}
	// An immediate second bare seal is inside the gap: nothing is bumped or sent.
	sprscSeal(t, r, scoped, true)
	g1 := sprsdBareGen(t, r)
	logs = r.seal(t, true)
	if g := sprsdBareGen(t, r); g != g1 {
		t.Errorf("a second bare seal inside the gap moved the generation %d -> %d\n%s", g1, g, logs)
	}
	if n := r.releases(); n != 1 {
		t.Errorf("%d /release request(s) after a second bare seal inside the gap, want 1\n%s", n, logs)
	}
}

func TestSealPruneScopeDropGapHolds(t *testing.T) {
	r := sprelSetup(t, "sprsd-gap", "scope drop holds inside the gap", 4096)
	sprscOn(t)
	scoped := r.name + "#de"
	if err := os.WriteFile(r.cache+".scopedrop", []byte("last "+strconv.FormatInt(time.Now().Unix(), 10)+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	sprscSeal(t, r, scoped, true)
	sprscSeal(t, r, scoped, true)
	tag := sprsdTag(r, scoped)
	recs, _, _ := sprsdRecords(t, r.cache)
	n0 := len(recs[tag])
	if n0 == 0 {
		t.Fatal("precondition: two churned #de seals recorded nothing")
	}
	g0 := sprsdBareGen(t, r)
	logs := r.seal(t, true)
	if g := sprsdBareGen(t, r); g != g0 {
		t.Errorf("a bare seal inside the gap moved the generation %d -> %d\n%s", g0, g, logs)
	}
	if n := r.releases(); n != 0 {
		t.Errorf("%d /release request(s) inside the gap\n%s", n, logs)
	}
	if after, _, _ := sprsdRecords(t, r.cache); len(after[tag]) != n0 {
		t.Errorf("%d #de record(s) after a bare seal inside the gap, want %d", len(after[tag]), n0)
	}
}

func TestSealPruneScopeDropVaultSkipped(t *testing.T) {
	r := sprelSetup(t, "sprsd-vault", "scope drop skips a scope vault", 4096)
	sprscOn(t)
	scoped := r.name + "#sys"
	sprscSeal(t, r, scoped, true)
	sprscSeal(t, r, scoped, true)
	tag := sprsdTag(r, scoped)
	recs, _, _ := sprsdRecords(t, r.cache)
	if len(recs[tag]) == 0 {
		t.Fatal("precondition: two churned #sys seals recorded nothing")
	}
	sprscVault(t, r, scoped)
	recs, _, _ = sprsdRecords(t, r.cache)
	recorded := recs[tag]
	out := r.seal(t, true)
	for k := range r.sent(t) {
		if recorded[k] {
			t.Errorf("%s of the #sys records was released, but #sys is a vault now", short(k))
		}
	}
	lp, sp := logProfile(r.name), logProfile(scoped)
	if want := "push: profile " + lp + ": nothing released early from " + sp + " -- the scope head is a vault now"; !strings.Contains(out, want) {
		t.Errorf("the bare seal did not say the #sys head is a vault now:\n%s", out)
	}
	if strings.Contains(out, "from "+sp+" -- the scope head could not be read") {
		t.Errorf("the #sys vault was skipped as unreadable, not as a vault:\n%s", out)
	}
}

func TestSealPruneScopeDropReAddedKept(t *testing.T) {
	r := sprelSetup(t, "sprsd-readd", "scope drop keeps a re-added chunk", 4096)
	sprscOn(t)
	scoped := r.name + "#keys"
	key := deriveKey(scoped, r.pass)
	sprsdSealAt(t, r, scoped, 0) // A
	sprsdSealAt(t, r, scoped, 1) // B: records A less B
	sprsdSealAt(t, r, scoped, 0) // C, the bytes and times of A again: records B less C
	tag := sprsdTag(r, scoped)
	recs, _, _ := sprsdRecords(t, r.cache)
	recorded := recs[tag]
	current := sprscBlobs(t, r, key, readHead(r.base, scoped, r.pass))
	overlap := map[string]bool{}
	for k := range recorded {
		if current[k] {
			overlap[k] = true
		}
	}
	if len(overlap) == 0 {
		t.Fatalf("precondition: no #keys record is named again by the current head (%d records)", len(recorded))
	}
	logs := r.seal(t, true)
	got := r.sent(t)
	for k := range current {
		if _, ok := got[k]; ok {
			t.Errorf("%s was released, but the current #keys head names it again\n%s", short(k), logs)
		}
	}
	other := 0
	for k := range got {
		if recorded[k] && !overlap[k] {
			other++
		}
	}
	if other == 0 {
		t.Errorf("no other #keys record was released\n%s", logs)
	}
}

func TestSealPruneScopeDropMediaNotRecorded(t *testing.T) {
	r := sprelSetup(t, "sprsd-media", "scope drop leaves media alone", 4096)
	sprscOn(t)
	media := r.name + "#media"
	for i := 0; i < 3; i++ {
		sprscSeal(t, r, media, true)
	}
	de := r.name + "#de"
	sprscSeal(t, r, de, true)
	sprscSeal(t, r, de, true)
	recs, _, _ := sprsdRecords(t, r.cache)
	if len(recs[sprsdTag(r, de)]) == 0 {
		t.Error("control: two churned #de seals recorded nothing")
	}
	if n := len(recs[sprsdTag(r, media)]); n != 0 {
		t.Errorf("%d record(s) under the #media head: bare-shaped #media is a later slice", n)
	}
}

func TestSealPruneScopeDropPushChecksBareGen(t *testing.T) {
	base := newHTTPStore(t)
	p := relGenEnv(t)
	const name, pass = "sprsd-push", "scope drop push checks the bare generation"
	createVault(base, name, pass)
	relGenSetGen(t, base, name, pass, 3)
	bareKey := relGenHeadKey(base, name, pass)
	if err := relGenRecord(p, bareKey, 1); err != nil {
		t.Fatal(err)
	}
	scoped := name + "#apps"
	push := func(round int) string {
		t.Helper()
		src := t.TempDir()
		if err := os.WriteFile(filepath.Join(src, "a.txt"), []byte("apps payload "+strconv.Itoa(round)), 0o600); err != nil {
			t.Fatal(err)
		}
		var out string
		if didPanic(func() { out = captureStdout(t, func() { pushProfile(base, scoped, pass, src) }) }) || sealRefused {
			t.Fatalf("the #apps seal failed:\n%s", out)
		}
		return out
	}

	// (a) the bare head is generation 3, the cache was filled under 1: the bare-shaped #apps push drops it.
	blobCacheAdd("sprsdpushK")
	out := push(1)
	if _, isV := parseVault(getHeadBlob(base, readHead(base, scoped, pass))); isV {
		t.Fatal("fixture: the #apps head is a vault")
	}
	if blobCacheKnown("sprsdpushK") {
		t.Errorf("a bare-shaped #apps push kept a chunk cache filled under an older bare release generation\n%s", out)
	}
	if g, ok := relGenSeen(p, bareKey); !ok || g != 3 {
		t.Errorf("bare record after the #apps push = (%d, %v), want (3, true)", g, ok)
	}

	// (b) the record matches: the cache is kept.
	blobCache = nil
	blobCacheAdd("sprsdpushK2")
	out = push(2)
	if !blobCacheKnown("sprsdpushK2") {
		t.Errorf("a bare-shaped #apps push at the recorded bare generation dropped the chunk cache\n%s", out)
	}
}

func TestSealPruneScopeDropNoName(t *testing.T) {
	r := sprelSetup(t, "sprsd-noname", "scope drop names nobody", 4096)
	sprscOn(t)
	scoped := r.name + "#de"
	sprscSeal(t, r, scoped, true)
	sprscSeal(t, r, scoped, true)
	line := regexp.MustCompile(`^([0-9a-f]{16} blob/[0-9a-f]+|last [0-9]+)$`)
	check := func(when string, wantRecord bool) {
		t.Helper()
		path := r.cache + ".scopedrop"
		st, err := os.Stat(path)
		if err != nil {
			t.Fatalf("%s: no record file: %v", when, err)
		}
		if st.Mode().Perm() != 0o600 {
			t.Errorf("%s: the record file is %o, want 600", when, st.Mode().Perm())
		}
		recs, _, raw := sprsdRecords(t, r.cache)
		if wantRecord && len(recs) == 0 {
			t.Fatalf("%s: the record file holds no record", when)
		}
		for _, bad := range []string{r.name, r.pass, "#"} {
			if strings.Contains(raw, bad) {
				t.Errorf("%s: the record file holds %q", when, bad)
			}
		}
		for _, l := range strings.Split(strings.TrimSuffix(raw, "\n"), "\n") {
			if !line.MatchString(l) {
				t.Errorf("%s: the record file holds the line %q", when, l)
			}
		}
	}
	check("after the scope seals", true)
	r.seal(t, true)
	check("after the bare release", false)
}
