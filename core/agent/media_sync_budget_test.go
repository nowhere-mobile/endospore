package main

// NWP-20261129-25: THE POST-SEAL MEDIA SYNC IS BOUNDED, AND THE SIGN-OUT'S OWN SEAL FETCHES NOTHING.
//
// classifyDeferred defers only the media trees, so a file in Documents/ or Audiobooks/ is essential at ANY size: the
// essential tier was unbounded, and it ran before the deferred capFlush committed the head. And handleLogout's seal
// downloaded another handset's new files onto a session the reap deletes moments later.

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// syncBudgetFixture sets two handsets up on one profile, B logged in holding the shared file, with the sync's own
// files inside the test's temp dir. It returns A, B and the sync list's path.
func syncBudgetFixture(t *testing.T, name string) (a, b *handset, syncOut string) {
	t.Helper()
	essentialMediaEnv(t)
	state := t.TempDir()
	t.Setenv("NOWHERE_STATE", state)
	syncOut = filepath.Join(state, "mediasync.list")
	t.Setenv("NOWHERE_MEDIA_SYNC_OUT", syncOut)
	const pass = "correct horse battery staple"
	a, b = twoWriters(t, name, pass)
	a.put("Documents/shared.txt", "both handsets hold this")
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	atLogin := a.head("#media")
	b.put("Documents/shared.txt", "both handsets hold this")
	b.as(func() { loginArrived(profileRefV2(name+"#media", pass), atLogin) })
	return a, b, syncOut
}

// A SIGN-OUT'S OWN SEAL STILL CARRIES THE ARRIVAL INTO THE HEAD, AND IT FETCHES NOTHING ONTO THE ENDING SESSION.
func TestMediaSync_ASignOutSealFetchesNothing(t *testing.T) {
	a, b, syncOut := syncBudgetFixture(t, "syncsignout")
	const photo = "DCIM/from-a.jpg"
	const body = "a small photo, under the deferral floor, so it rides the essential tar"
	a.put(photo, body)
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("A's photo seal: %s", msg)
	}
	target := filepath.Join(b.work, filepath.FromSlash(photo))
	if landed(b, photo) {
		t.Fatal("the photo is already on B before any sync -- this fixture proves nothing")
	}

	for _, kind := range []string{"logoff", "logoff-pinned"} {
		// B's own new file: A's head already indexes the photo, so only this shows that B's seal published.
		own := "Documents/b-" + kind + ".txt"
		b.put(own, "this handset's own file, for "+kind)
		t.Setenv("NOWHERE_SEAL_KIND", kind)
		if msg := b.seal("#media"); msg != "" {
			t.Fatalf("B's %s seal: %s", kind, msg)
		}
		if landed(b, photo) {
			t.Errorf("a %s seal fetched the photo onto a session the reap is about to delete", kind)
		}
		if list, err := os.ReadFile(syncOut); err == nil && strings.Contains(string(list), target) {
			t.Errorf("a %s seal named the photo in the sync list: %q", kind, string(list))
		}
		m := headManifestOf(t, b.base, b.name+"#media", b.pass)
		if _, ok := m.Ess[photo]; !ok {
			t.Errorf("a %s seal dropped the photo from the head: the carry must still run: %v", kind, keysOfEss(m.Ess))
		}
		if _, ok := m.Ess[own]; !ok {
			t.Errorf("the head does not index B's own file, so B's %s seal did not publish: %v", kind, keysOfEss(m.Ess))
		}
	}

	// The control: the same handset and the same arrival, on a seal that is not the sign-out's.
	t.Setenv("NOWHERE_SEAL_KIND", "")
	if msg := b.seal("#media"); msg != "" {
		t.Fatalf("B's periodic seal: %s", msg)
	}
	got, err := os.ReadFile(target)
	if err != nil {
		t.Fatalf("the photo did not land on a periodic seal (%v), so the checks above prove nothing", err)
	}
	if string(got) != body {
		t.Errorf("the photo landed with the wrong bytes: %q", string(got))
	}
	list, err := os.ReadFile(syncOut)
	if err != nil || !strings.Contains(string(list), target) {
		t.Errorf("the sync list does not name the photo that landed (%v): %q", err, string(list))
	}
}

// A FILE LARGER THAN THE WHOLE BUDGET CAN NEVER FIT A CYCLE and must not end the pass: what sorts after it lands.
func TestMediaSync_AnOversizeEssentialFileWaitsAndTheRestLand(t *testing.T) {
	t.Setenv("NOWHERE_MEDIA_SYNC_BUDGET", "1000")
	a, b, _ := syncBudgetFixture(t, "syncessoversize")
	const big, small = "Documents/a-big.bin", "Documents/b-small.txt"
	body := strings.Repeat("s", 300)
	a.put(big, strings.Repeat("b", 1500))
	a.put(small, body)
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("A's seal: %s", msg)
	}

	var msg string
	out := captureStdout(t, func() { msg = b.seal("#media") })
	if msg != "" {
		t.Fatalf("B's seal: %s", msg)
	}
	got, err := os.ReadFile(filepath.Join(b.work, filepath.FromSlash(small)))
	if err != nil {
		t.Fatalf("the file after the oversize one did not land (%v): the oversize file ended the pass", err)
	}
	if string(got) != body {
		t.Errorf("the small file landed with the wrong bytes: %q", string(got))
	}
	if landed(b, big) {
		t.Error("a file larger than the whole per-cycle budget landed")
	}
	if want := "1 essential file(s) larger than the per-cycle budget (1000 B) wait for the next login"; !strings.Contains(out, want) {
		t.Errorf("no count line %q in B's output:\n%s", want, out)
	}
	if strings.Contains(out, "a-big") {
		t.Errorf("the oversize file is a count only, but B's output names it:\n%s", out)
	}
	m := headManifestOf(t, b.base, b.name+"#media", b.pass)
	for _, rel := range []string{big, small} {
		if _, ok := m.Ess[rel]; !ok {
			t.Errorf("B's head does not index %s: %v", rel, keysOfEss(m.Ess))
		}
	}
}

// WHAT FITS THE BUDGET BUT NOT WHAT IS LEFT OF IT ENDS THE PASS, so progress is monotonic in rel order across cycles.
func TestMediaSync_AnEssentialFileThatFitsTheBudgetButNotTheRemainderEndsThePass(t *testing.T) {
	t.Setenv("NOWHERE_MEDIA_SYNC_BUDGET", "1000")
	a, b, _ := syncBudgetFixture(t, "syncessremainder")
	const first, second, third = "Documents/a.bin", "Documents/b.bin", "Documents/c.txt"
	a.put(first, strings.Repeat("a", 600))
	a.put(second, strings.Repeat("b", 600))
	a.put(third, strings.Repeat("c", 100))
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("A's seal: %s", msg)
	}

	if msg := b.seal("#media"); msg != "" {
		t.Fatalf("B's first seal: %s", msg)
	}
	if !landed(b, first) {
		t.Errorf("%s did not land on the first cycle", first)
	}
	if landed(b, second) {
		t.Errorf("%s landed past the budget: the first cycle fetched 1200 B of 1000", second)
	}
	if landed(b, third) {
		t.Errorf("%s landed after the pass should have ended, so the order is not monotonic", third)
	}

	if msg := b.seal("#media"); msg != "" {
		t.Fatalf("B's second seal: %s", msg)
	}
	for _, rel := range []string{second, third} {
		if !landed(b, rel) {
			t.Errorf("%s did not land on the second cycle", rel)
		}
	}
}

func TestSignOutSealKinds(t *testing.T) {
	for kind, want := range map[string]bool{
		"logoff":        true,
		"logoff-pinned": true,
		"":              false,
		"manual":        false,
		"periodic":      false,
	} {
		t.Setenv("NOWHERE_SEAL_KIND", kind)
		if got := signOutSeal(); got != want {
			t.Errorf("signOutSeal() with NOWHERE_SEAL_KIND=%q = %v, want %v", kind, got, want)
		}
	}
}
