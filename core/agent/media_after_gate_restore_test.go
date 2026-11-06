package main

// NWP-20261125-03: mediaRestorePlan, the #media restore's split (Q106 slice S2, docs/media-after-gate.md §5 item 1
// and §8). The sealed fixture goes through the real seal path and the real cdcRestore, as
// TestBgSplit_SealedFixture_PreGateUntarsToTheRest does: the marker is written before the roster, a failed marker
// restores everything, the flag off is today's restore, and the pre-gate pass earns the receipt.

import (
	"os"
	"path"
	"path/filepath"
	"reflect"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"testing"
)

// mrPlan is one sealed #media head, ready for the plan.
type mrPlan struct {
	a       *handset
	profile string
	key     []byte
	m       chunkManifest
	head    string
	bgWant  map[string]string
	preWant map[string]string
}

// mrPlanFixture seals a #media head that holds Q106 files and others. NOWHERE_STATE is a fresh directory after the
// seal, so the restore-receipts dir starts empty for the plan. The flag is left unset.
func mrPlanFixture(t *testing.T, name string) mrPlan {
	t.Helper()
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_CARRY_ESSENTIAL_MEDIA", "1")
	t.Setenv("NOWHERE_MEDIA_TOMBSTONES", "")
	t.Setenv("NOWHERE_MEDIA_AFTER_GATE", "")
	t.Setenv("NOWHERE_STATE", t.TempDir())

	a, _ := twoWriters(t, name, "correct horse battery staple")
	p := mrPlan{a: a, profile: a.name + "#media",
		bgWant: map[string]string{
			"DCIM/a.jpg":       "a photo",
			"Pictures/x/b.png": "a picture in a sub-folder",
			"Download/c.pdf":   "a downloaded document, longer",
		},
		preWant: map[string]string{
			"Documents/g.txt":                "not in Q106's list",
			"Android/data/com.example/i.bin": "app-private data",
			"DCIM/.nomedia":                  "",
			"Pictures/k.db":                  "a database in a user folder",
		}}
	for _, set := range []map[string]string{p.bgWant, p.preWant} {
		for rel, body := range set {
			a.put(rel, body)
		}
	}
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	p.m = headManifestOf(t, a.base, p.profile, a.pass)
	p.head = a.head("#media")
	p.key = resolveDK(a.base, p.profile, a.pass, nil)
	if bg, _ := bgSplit(p.m); !p.m.EssIdx || len(bg) != len(p.bgWant) {
		t.Fatalf("the fixture does not split: EssIdx=%v bg=%v", p.m.EssIdx, bg)
	}
	if p.head == "" {
		t.Fatal("the fixture has no #media head")
	}
	t.Setenv("NOWHERE_STATE", t.TempDir())
	return p
}

func (p mrPlan) ref() string { return profileRefV2(p.profile, p.a.pass) }

// plan runs mediaRestorePlan for this fixture and returns its result and what it printed.
func (p mrPlan) plan(t *testing.T, profile string, m chunkManifest) (got chunkManifest, out string) {
	t.Helper()
	out = captureStdout(t, func() { got = mediaRestorePlan(profile, p.a.pass, p.head, m) })
	return got, out
}

// restoreInto streams chunks through the real cdcRestore into a fresh directory.
func (p mrPlan) restoreInto(t *testing.T, m chunkManifest) (dest string, skipped int) {
	t.Helper()
	dest = t.TempDir()
	captureStdout(t, func() { skipped = cdcRestore(p.a.base, p.key, m, dest) })
	return dest, skipped
}

func mrPlanSame(t *testing.T, what string, got, m chunkManifest, out string, marker string) {
	t.Helper()
	if !reflect.DeepEqual(got, m) {
		t.Errorf("%s: the plan changed the manifest: %d chunks, want %d", what, len(got.Chunks), len(m.Chunks))
	}
	if len(got.Chunks) == 0 || &got.Chunks[0] != &m.Chunks[0] {
		t.Errorf("%s: the plan returned a copy of Chunks, want the same backing array", what)
	}
	if out != "" {
		t.Errorf("%s: the plan printed %q, want nothing", what, out)
	}
	if marker == "" {
		return
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Errorf("%s: an after-gate marker was written (stat err=%v)", what, err)
	}
}

func fileBody(t *testing.T, f string) (string, bool) {
	t.Helper()
	b, err := os.ReadFile(f)
	if err != nil {
		return "", false
	}
	return string(b), true
}

func TestMediaRestorePlan_FlagOffIsTodaysRestore(t *testing.T) {
	p := mrPlanFixture(t, "mrplanoff")
	marker := aftergateFile(p.ref())
	if marker == "" {
		t.Fatal("receipts are off -- this test proves nothing")
	}
	for _, v := range []string{"unset", "0", "true", " 1", "yes"} {
		if v == "unset" {
			os.Unsetenv("NOWHERE_MEDIA_AFTER_GATE")
		} else {
			t.Setenv("NOWHERE_MEDIA_AFTER_GATE", v)
		}
		got, out := p.plan(t, p.profile, p.m)
		mrPlanSame(t, "flag "+strconv.Quote(v), got, p.m, out, marker)
	}
}

func TestMediaRestorePlan_NonMediaScopeIsUntouched(t *testing.T) {
	p := mrPlanFixture(t, "mrplanscope")
	t.Setenv("NOWHERE_MEDIA_AFTER_GATE", "1")
	for _, profile := range []string{p.a.name, p.a.name + "#de", p.a.name + "#apps"} {
		got, out := p.plan(t, profile, p.m)
		mrPlanSame(t, "scope "+strconv.Quote(profile), got, p.m, out, aftergateFile(profileRefV2(profile, p.a.pass)))
	}
}

func TestMediaRestorePlan_SplitStreamsPreGateOnly(t *testing.T) {
	p := mrPlanFixture(t, "mrplansplit")
	t.Setenv("NOWHERE_MEDIA_AFTER_GATE", "1")
	before := slices.Clone(p.m.Chunks)
	_, pre := bgSplit(p.m)

	got, _ := p.plan(t, p.profile, p.m)

	// The marker is on disk when the plan returns: before cdcRestore streams a chunk, and before the roster.
	marker := aftergateFile(p.ref())
	if body, ok := fileBody(t, marker); !ok || body != p.head {
		t.Fatalf("aftergate.<ref> after the plan = %q (present=%v), want the restored head %q", body, ok, p.head)
	}
	if _, err := os.Stat(loginRosterFile(p.ref())); !os.IsNotExist(err) {
		t.Fatalf("the roster exists before the restore ran (stat err=%v)", err)
	}

	if !reflect.DeepEqual(got.Chunks, pre) || len(got.Chunks) >= len(p.m.Chunks) {
		t.Fatalf("the plan streams %d chunks, want bgSplit's %d pre-gate chunks of %d", len(got.Chunks), len(pre), len(p.m.Chunks))
	}
	want := p.m
	want.Chunks = pre
	if !reflect.DeepEqual(got, want) {
		t.Error("the plan changed a field other than Chunks")
	}
	if &got.Chunks[0] == &p.m.Chunks[0] {
		t.Error("the plan's Chunks aliases m.Chunks")
	}
	if !reflect.DeepEqual(p.m.Chunks, before) {
		t.Error("the plan changed the caller's m.Chunks")
	}

	dest, sk := p.restoreInto(t, got)
	if sk != 0 {
		t.Fatalf("the pre-gate restore skipped %d entries", sk)
	}
	for rel := range p.bgWant {
		if _, err := os.Stat(filepath.Join(dest, rel)); !os.IsNotExist(err) {
			t.Errorf("background file %s restored before the gate (stat err=%v)", rel, err)
		}
	}
	for rel, body := range p.preWant {
		if b, ok := fileBody(t, filepath.Join(dest, rel)); !ok || b != body {
			t.Errorf("pre-gate file %s = %q (present=%v), want %q", rel, b, ok, body)
		}
	}
	if fi, err := os.Stat(filepath.Join(dest, "Pictures", "x")); err != nil || !fi.IsDir() {
		t.Errorf("the directory of a background file did not restore before the gate (err=%v)", err)
	}

	captureStdout(t, func() { finishRestore(p.profile, p.a.pass, p.head, sk) })
	mi, err := os.Stat(marker)
	if err != nil {
		t.Fatalf("the marker is gone after finishRestore: %v", err)
	}
	ri, err := os.Stat(loginRosterFile(p.ref()))
	if err != nil {
		t.Fatalf("finishRestore wrote no roster: %v", err)
	}
	if mi.ModTime().After(ri.ModTime()) {
		t.Errorf("the marker (%v) was written after the roster (%v)", mi.ModTime(), ri.ModTime())
	}
}

func TestMediaRestorePlan_FailedMarkerRestoresEverything(t *testing.T) {
	p := mrPlanFixture(t, "mrplanfail")
	t.Setenv("NOWHERE_MEDIA_AFTER_GATE", "1")
	st := t.TempDir()
	t.Setenv("NOWHERE_STATE", st)
	if err := os.WriteFile(filepath.Join(st, "restore-receipts"), []byte("not a dir"), 0o600); err != nil {
		t.Fatal(err)
	}
	check := func(what string) {
		t.Helper()
		got, out := p.plan(t, p.profile, p.m)
		if !reflect.DeepEqual(got, p.m) {
			t.Fatalf("%s: the plan split with no marker: %d chunks, want all %d", what, len(got.Chunks), len(p.m.Chunks))
		}
		if !strings.Contains(out, "the after-gate marker could not be written, so the whole set restores inline") {
			t.Errorf("%s: no marker-failure line; printed %q", what, out)
		}
		dest, sk := p.restoreInto(t, got)
		if sk != 0 {
			t.Fatalf("%s: the inline restore skipped %d entries", what, sk)
		}
		for _, set := range []map[string]string{p.bgWant, p.preWant} {
			for rel, body := range set {
				if b, ok := fileBody(t, filepath.Join(dest, rel)); !ok || b != body {
					t.Errorf("%s: %s = %q (present=%v), want %q", what, rel, b, ok, body)
				}
			}
		}
	}
	check("unwritable receipts dir")

	// Receipts off (no NOWHERE_STATE: host CLI): the same arm, and nothing lands in the working directory.
	os.Unsetenv("NOWHERE_STATE")
	wd := t.TempDir()
	t.Chdir(wd)
	check("receipts off")
	if ents, _ := os.ReadDir(wd); len(ents) != 0 {
		t.Errorf("the plan wrote %d file(s) into the working directory with receipts off", len(ents))
	}
}

func TestMediaRestorePlan_NoIndexMeansNoSplit(t *testing.T) {
	p := mrPlanFixture(t, "mrplannoidx")
	t.Setenv("NOWHERE_MEDIA_AFTER_GATE", "1")
	marker := aftergateFile(p.ref())
	noIdx := p.m
	noIdx.EssIdx = false
	noEss := p.m
	noEss.Ess = nil
	for what, mi := range map[string]chunkManifest{"no EssIdx": noIdx, "no Ess": noEss} {
		if err := publishReceiptFile(marker, []byte("an older head")); err != nil {
			t.Fatal(err)
		}
		got, out := p.plan(t, p.profile, mi)
		mrPlanSame(t, what, got, mi, out, marker) // the stale marker is gone, too
	}
}

func TestMediaRestorePlan_ReceiptEarnedByThePreGatePass(t *testing.T) {
	p := mrPlanFixture(t, "mrplanrcpt")
	t.Setenv("NOWHERE_MEDIA_AFTER_GATE", "1")
	got, _ := p.plan(t, p.profile, p.m)
	if len(got.Chunks) >= len(p.m.Chunks) {
		t.Fatal("the plan did not split -- this test proves nothing")
	}
	_, sk := p.restoreInto(t, got)
	if sk != 0 {
		t.Fatalf("the pre-gate restore skipped %d entries", sk)
	}
	captureStdout(t, func() { finishRestore(p.profile, p.a.pass, p.head, sk) })
	if r, ok := fileBody(t, receiptFile(p.ref())); !ok || strings.TrimSpace(r) != p.head {
		t.Errorf("the #72 receipt = %q (present=%v), want the restored head %q", r, ok, p.head)
	}
	if r, ok := fileBody(t, loginRosterFile(p.ref())); !ok || r != p.head {
		t.Errorf("the login roster = %q (present=%v), want the restored head %q", r, ok, p.head)
	}
}

func TestMediaRestorePlan_SplitLineIsCountsOnly(t *testing.T) {
	p := mrPlanFixture(t, "mrplanline")
	t.Setenv("NOWHERE_MEDIA_AFTER_GATE", "1")
	bg, pre := bgSplit(p.m)
	_, out := p.plan(t, p.profile, p.m)

	const prefix = "restore: #media split -- pre-gate "
	var lines []string
	for _, ln := range strings.Split(strings.TrimRight(out, "\n"), "\n") {
		if strings.HasPrefix(ln, prefix) {
			lines = append(lines, ln)
		}
	}
	if len(lines) != 1 || strings.Count(out, "\n") != 1 {
		t.Fatalf("the plan printed %q, want exactly one split line", out)
	}
	re := regexp.MustCompile(`^restore: #media split -- pre-gate (\d+) chunks / background (\d+) files, (\d+) bytes \(NWP-20261125-03\)$`)
	g := re.FindStringSubmatch(lines[0])
	if g == nil {
		t.Fatalf("the split line %q is not in the counts-only shape", lines[0])
	}
	var size int64
	for _, rel := range bg {
		size += p.m.Ess[rel].Size
	}
	if g[1] != strconv.Itoa(len(pre)) || g[2] != strconv.Itoa(len(bg)) || g[3] != strconv.FormatInt(size, 10) {
		t.Errorf("the split line %q, want %d chunks / %d files, %d bytes", lines[0], len(pre), len(bg), size)
	}
	for _, rel := range bg {
		if strings.Contains(out, path.Base(rel)) || strings.Contains(out, rel) {
			t.Errorf("the split line names the background file %s: %q", rel, out)
		}
	}
	if strings.Contains(out, p.a.name) {
		t.Errorf("the split line names the profile: %q", out)
	}
}

// TestMediaRestorePlan_CallSiteStreamsThePlan pins the call in main.go's restore case: a correct helper nothing
// calls is the failure this area keeps repeating.
func TestMediaRestorePlan_CallSiteStreamsThePlan(t *testing.T) {
	src, err := readSource(t, "main.go")
	if err != nil {
		t.Fatal(err)
	}
	if err := mediaRestorePlanCalled(src); err != nil {
		t.Fatal(err)
	}
	// Self-checks: today's call, and the plan called after the restore, must both fail the scan.
	const call = "skipped = cdcRestore(base, key, mediaRestorePlan(profile, pass, restoredHead, m), dest)"
	if mediaRestorePlanCalled(strings.Replace(src, call, "skipped = cdcRestore(base, key, m, dest)", 1)) == nil {
		t.Error("the unsplit call passes the scan")
	}
	after := strings.Replace(src, call, "skipped = cdcRestore(base, key, m, dest)\n\t\t\t_ = mediaRestorePlan(profile, pass, restoredHead, m)", 1)
	if mediaRestorePlanCalled(after) == nil {
		t.Error("a plan called after cdcRestore passes the scan")
	}
}

func mediaRestorePlanCalled(src string) error {
	const call = "skipped = cdcRestore(base, key, mediaRestorePlan(profile, pass, restoredHead, m), dest)"
	i := strings.Index(src, `case "restore":`)
	if i < 0 {
		return errSeed("no restore case")
	}
	rest := src[i:]
	end := strings.Index(rest, "finishRestore(profile, pass, restoredHead, skipped)")
	if end < 0 {
		return errSeed("no finishRestore in the restore case")
	}
	if strings.Count(src, "mediaRestorePlan(") != 1 {
		return errSeed("mediaRestorePlan must be called exactly once in main.go")
	}
	if strings.Count(rest[:end], call) != 1 {
		return errSeed("the restore case does not stream the plan before finishRestore: want " + call)
	}
	if strings.Contains(src, "skipped = cdcRestore(base, key, m, dest)") {
		return errSeed("the restore case still streams the full m")
	}
	return nil
}
