package main

// NWP-20261208-29: the bare vault and #de heal continue their scope's restore bar (restore_heal_band.go), so
// "Restoring app data" no longer goes 100% -> 0% -> 100% at sign-in.

import (
	"bytes"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// fixHealBand pins the band and the progress globals per test and restores them.
func fixHealBand(t *testing.T) string {
	t.Helper()
	fixProgPhase(t, "")
	prevScope, _ := progScope.Load().(string)
	progScope.Store("")
	t.Cleanup(func() { progScope.Store(prevScope) })
	clearHealBand()
	t.Cleanup(clearHealBand)
	pf := filepath.Join(t.TempDir(), "progress")
	t.Setenv("NOWHERE_PROGRESS", pf)
	t.Setenv("NOWHERE_PHASE", "apps")
	return pf
}

// progFrame reads the last progress line as numbers.
func progFrame(t *testing.T, pf string) (int64, int64) {
	t.Helper()
	_, d, tot := readProgLine(t, pf)
	done, err1 := strconv.ParseInt(d, 10, 64)
	total, err2 := strconv.ParseInt(tot, 10, 64)
	if err1 != nil || err2 != nil {
		t.Fatalf("progress frame %q %q is not numbers", d, tot)
	}
	return done, total
}

// settledFrame waits for cdcRestoreProg's last frame: its ordered writer writes the last chunk's frame and can
// do so after cdcUntar returns, so a frame read at once may be the one before it, and a heal started at once may
// be overwritten by it. Returns the last frame read when (done, total) does not appear within the bound.
func settledFrame(t *testing.T, pf string, done, total int64) (int64, int64) {
	t.Helper()
	var d, tot int64
	for until := time.Now().Add(5 * time.Second); ; time.Sleep(10 * time.Millisecond) {
		if d, tot = progFrame(t, pf); (d == done && tot == total) || time.Now().After(until) {
			return d, tot
		}
	}
}

// B1
func TestHealBandFrame(t *testing.T) {
	for _, c := range []struct {
		base, est, h, H, done, total int64
	}{
		{1000, 500, 0, 200, 1000, 1500},
		{1000, 500, 100, 200, 1250, 1500},
		{1000, 500, 200, 200, 1500, 1500},
		{1000, 500, 0, 0, 1500, 1500},     // nothing to fetch: still the full frame
		{1000, 500, 300, 200, 1500, 1500}, // h > H clamps
		{1000, 500, -5, 200, 1000, 1500},  // h < 0 clamps
		{1000, 0, 70, 200, 70, 200},       // no band: passthrough
		{0, 500, 70, 200, 70, 200},        // no base (legacy manifest without Sizes): passthrough
	} {
		d, tot := healBandFrame(c.base, c.est, c.h, c.H)
		if d != c.done || tot != c.total {
			t.Errorf("healBandFrame(%d, %d, %d, %d) = (%d, %d), want (%d, %d)", c.base, c.est, c.h, c.H, d, tot, c.done, c.total)
		}
	}
	// A multi-GiB heal: h*est passes int64, the frame must not (RF-001).
	const gib = int64(1) << 30
	for _, c := range []struct {
		base, est, h, H, done, total int64
	}{
		{1000, 4 * gib, 4 * gib, 4 * gib, 1000 + 4*gib, 1000 + 4*gib},
		{1000, 4 * gib, 3 * gib, 4 * gib, 1000 + 3*gib, 1000 + 4*gib},
		{1000, 64 * gib, 16 * gib, 64 * gib, 1000 + 16*gib, 1000 + 64*gib},
		{1000, 64 * gib, 100 * gib, 100 * gib, 1000 + 64*gib, 1000 + 64*gib},
	} {
		d, tot := healBandFrame(c.base, c.est, c.h, c.H)
		if d != c.done || tot != c.total {
			t.Errorf("healBandFrame(%d, %d, %d, %d) = (%d, %d), want (%d, %d)", c.base, c.est, c.h, c.H, d, tot, c.done, c.total)
		}
	}
	prevBig := int64(-1)
	for h := int64(0); h <= 8*gib; h += gib / 4 {
		d, tot := healBandFrame(1000, 4*gib, h, 8*gib)
		if d < prevBig || d > tot {
			t.Fatalf("multi-GiB healBandFrame left the band at h=%d: %d of %d after %d", h, d, tot, prevBig)
		}
		prevBig = d
	}
	prev := int64(-1)
	for h := int64(0); h <= 200; h++ {
		d, _ := healBandFrame(1000, 500, h, 200)
		if d < prev {
			t.Fatalf("healBandFrame went back at h=%d: %d after %d", h, d, prev)
		}
		prev = d
	}
}

// B2
func TestHealProgEstimate(t *testing.T) {
	ch := []string{"c0ffee"}
	cache := "app.ex/files/" + mediaCacheDirName + "/thumb.bin"
	stage := appCodeStageRel + "/base.apk"
	hold := chooserPkg + "/" + odHoldDirName + "/com.ex.b/files/x"
	if !isMediaCachePath(cache) || !isAppCodeStagePath(stage) || !strings.Contains(hold, "/"+odHoldDirName+"/") {
		t.Fatal("fixture: the excluded paths no longer match their predicates")
	}
	m := chunkManifest{Deferred: map[string]deferredFile{
		"com.ex.a/files/big.bin":   {Size: 700, Chunks: ch},
		cache:                      {Size: 11, Chunks: ch},
		stage:                      {Size: 13, Chunks: ch},
		hold:                       {Size: 17, Chunks: ch},
		"com.ex.a/files/empty.bin": {Size: 0, Chunks: ch},
		"com.ex.a/files/nochunk":   {Size: 19},
	}}
	for _, c := range []struct {
		scope string
		want  int64
	}{
		{"bandest", 700}, {"bandest#de", 700},
		{"bandest#media", 0}, {"bandest#sys", 0}, {"bandest#apps", 0}, {"bandest#keys", 0},
	} {
		if got := healProgEstimate(c.scope, m); got != c.want {
			t.Errorf("healProgEstimate(%q) = %d, want %d", c.scope, got, c.want)
		}
	}
}

// healBandFixture seals a vault head with one deferred file, as media_heal_test.go does.
func healBandFixture(t *testing.T, name string) (base string, dk []byte, m chunkManifest, pass, state string) {
	t.Helper()
	state = healTestEnv(t)
	base = newHTTPStore(t)
	pass = name + " horse battery staple"
	createVault(base, name, pass)
	rel := "app.maps/files/maps/region.mwm"
	m = preGateHead(t, base, name, pass, rel, bytes.Repeat([]byte("HEAL-BAND-BAR"), 5000), 0o644, time.Unix(1700000000, 0))
	if len(m.Sizes) == 0 {
		t.Fatal("fixture: the head has no Sizes, so the bar has no byte ladder")
	}
	return base, resolveDK(base, name, pass, nil), m, pass, state
}

// B3: the essential restore leaves room for the heal, and the heal fills it to 100%.
func TestHealBandEndToEnd(t *testing.T) {
	pf := fixHealBand(t)
	name := "bandend"
	base, dk, m, pass, state := healBandFixture(t, name)
	est := healProgEstimate(name, m)
	if est <= 0 {
		t.Fatalf("fixture: estimate %d, want the deferred file's size", est)
	}
	sum := sumSizes(m)
	dest := t.TempDir()
	setHealBand(est)
	cdcRestoreProg(base, dk, m, dest, 0, 0, nil)
	if d, tot := settledFrame(t, pf, sum, sum+est); d != sum || tot != sum+est {
		t.Fatalf("essential restore ends at (%d, %d), want (%d, %d): it must leave room for the heal", d, tot, sum, sum+est)
	}
	if b := healBandBase.Load(); b != sum {
		t.Fatalf("band base %d, want %d (where the essential restore stops)", b, sum)
	}
	hr := restoreHeal(base, dk, m, dest, name, pass, state)
	if hr.fetched != 1 {
		t.Fatalf("heal %+v, want the deferred file fetched", hr)
	}
	if d, tot := progFrame(t, pf); d != sum+est || tot != sum+est {
		t.Fatalf("heal ends at (%d, %d), want (%d, %d)", d, tot, sum+est, sum+est)
	}
}

// B4: every deferred file is late (after landing), so the heal fetches nothing; the bar still ends at 100%.
func TestHealBandAllLate(t *testing.T) {
	pf := fixHealBand(t)
	name := "bandlate"
	base, dk, m, pass, state := healBandFixture(t, name)
	t.Setenv("NOWHERE_HEAL_AFTER_LANDING", "1")
	est := healProgEstimate(name, m)
	sum := sumSizes(m)
	dest := t.TempDir()
	setHealBand(est)
	cdcRestoreProg(base, dk, m, dest, 0, 0, nil)
	if d, tot := settledFrame(t, pf, sum, sum+est); d != sum || tot != sum+est {
		t.Fatalf("essential restore ends at (%d, %d), want (%d, %d)", d, tot, sum, sum+est)
	}
	hr := restoreHeal(base, dk, m, dest, name, pass, state)
	if hr.fetched != 0 {
		t.Fatalf("heal %+v, want nothing fetched (every file after landing)", hr)
	}
	if d, tot := progFrame(t, pf); d != sum+est || tot != sum+est {
		t.Fatalf("heal with nothing to fetch ends at (%d, %d), want (%d, %d)", d, tot, sum+est, sum+est)
	}
}

// B5: with no band the frames are today's, and the verb closes the band right after the heal.
func TestHealBandOffMatchesToday(t *testing.T) {
	pf := fixHealBand(t)
	name := "bandoff"
	base, dk, m, pass, state := healBandFixture(t, name)
	setHealBand(healProgEstimate(name, m))
	clearHealBand()
	sum := sumSizes(m)
	dest := t.TempDir()
	cdcRestoreProg(base, dk, m, dest, 0, 0, nil)
	if d, tot := settledFrame(t, pf, sum, sum); d != sum || tot != sum {
		t.Fatalf("no band: restore ends at (%d, %d), want (%d, %d)", d, tot, sum, sum)
	}
	restoreHeal(base, dk, m, dest, name, pass, state)
	var H int64
	for _, d := range m.Deferred {
		H += d.Size
	}
	if d, tot := progFrame(t, pf); d != H || tot != H {
		t.Fatalf("no band: heal ends at (%d, %d), want its own (%d, %d)", d, tot, H, H)
	}

	src, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(string(src), "\n")
	var set, clear bool
	for i, l := range lines {
		if strings.Contains(l, "skipped = restoreSkippingParked(base, key, profile,") && i > 0 &&
			strings.Contains(lines[i-1], "setHealBand(healProgEstimate(profile, m))") {
			set = true
		}
		if strings.Contains(l, "hr := restoreHeal(base, key, m, dest, profile, pass,") {
			for _, n := range lines[i+1:] {
				if strings.TrimSpace(n) == "" {
					continue
				}
				clear = strings.TrimSpace(n) == "clearHealBand()"
				break
			}
		}
	}
	if !set {
		t.Error("main.go: the restore verb does not open the heal band on the line before restoreSkippingParked")
	}
	if !clear {
		t.Error("main.go: the restore verb does not close the heal band on the line after restoreHeal")
	}
}
