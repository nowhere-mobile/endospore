package main

import (
	"encoding/hex"
	"strings"
	"testing"
)

// NWP-20261208-14: a #media head that is a VAULT releases at its seal the chunks its retention dropped, like the four
// scope vaults, with the media export's pinned manifest kept (sealPruneMediaPin) and the compare bounded
// (sealPruneMediaMaxKeys). test-seal-prune-media.sh re-runs these tests against copies of seal_prune_release.go with
// each guard broken in turn. Every test uses its OWN profile name and its own blob cache dir (sprelSetup or relGenEnv).

// sprmdCase is one #media pruning seal: the fixture, the heads on each side of it and its log.
type sprmdCase struct {
	r             *sprel
	scoped        string
	key           []byte // the #media scope key
	before, after *vault
	dropped       []string
	logs          string
}

// sprmdFixture is the #media scope vault with four kept seals and the pruning retention set: the pruning seal is left
// to the test, so it can publish an export pointer first.
func sprmdFixture(t *testing.T, name string) *sprmdCase {
	t.Helper()
	r := sprelSetup(t, name, "the media scope releases what it pruned", 3*cdcMax)
	sprscOn(t)
	c := &sprmdCase{r: r, scoped: r.name + "#media"}
	sprscVault(t, r, c.scoped)
	for i := 0; i < 4; i++ {
		sprscSeal(t, r, c.scoped, true)
	}
	c.before, c.key = snapDelHead(t, r.base, c.scoped, r.pass)
	sprelPrune(t)
	return c
}

// seal runs the pruning seal and records what it dropped.
func (c *sprmdCase) seal(t *testing.T) {
	t.Helper()
	c.logs = sprscSeal(t, c.r, c.scoped, false)
	if sealRefused {
		t.Fatalf("fixture: the pruning seal was refused: %s", c.logs)
	}
	c.after, _ = snapDelHead(t, c.r.base, c.scoped, c.r.pass)
	kept := map[string]bool{c.after.Manifest: true}
	for _, s := range c.after.History {
		kept[s.Manifest] = true
	}
	for _, m := range append([]string{c.before.Manifest}, histManifests(c.before.History)...) {
		if !kept[m] {
			c.dropped = append(c.dropped, m)
		}
	}
	if len(c.dropped) == 0 {
		t.Fatalf("fixture: the pruning seal dropped nothing\n%s", c.logs)
	}
}

// want is blobs(dropped) minus blobs(new head + kept History).
func (c *sprmdCase) want(t *testing.T) map[string]bool {
	t.Helper()
	want := sprscBlobs(t, c.r, c.key, c.dropped...)
	for k := range sprscBlobs(t, c.r, c.key, append([]string{c.after.Manifest}, histManifests(c.after.History)...)...) {
		delete(want, k)
	}
	if len(want) == 0 {
		t.Fatal("fixture: nothing to release")
	}
	return want
}

// recorded asserts the scope head's generation was recorded (a skip records it as a release does).
func (c *sprmdCase) recorded(t *testing.T) {
	t.Helper()
	if g, ok := relGenSeen(c.r.cache, relGenHeadKey(c.r.base, c.scoped, c.r.pass)); !ok || g != c.after.ReleaseGen {
		t.Errorf("recorded #media generation (%d, %v), the head carries %d", g, ok, c.after.ReleaseGen)
	}
}

// pin publishes ref -> value in a cap bracket, as the media export does.
func (c *sprmdCase) pin(t *testing.T, ref, value string) {
	t.Helper()
	dk := resolveDK(c.r.base, c.r.name, c.r.pass, nil)
	if dk == nil {
		t.Fatal("fixture: the bare vault does not open")
	}
	capWrite(c.r.name, c.r.pass, dk, func() { putRef(c.r.base, ref, value) })
	if got := getRef(c.r.base, ref); got != value {
		t.Fatalf("fixture: the pointer reads %q", got)
	}
}

// oldest is the oldest kept manifest before the pruning seal: the one the prune drops.
func (c *sprmdCase) oldest(t *testing.T) string {
	t.Helper()
	if len(c.before.History) == 0 {
		t.Fatal("fixture: no History before the pruning seal")
	}
	return c.before.History[len(c.before.History)-1].Manifest
}

// pinKept is PinKept and LegacyPinKept: a pointer under ref names a manifest the prune drops; none of its blobs is
// released and the rest of the want set is.
func sprmdPinKept(t *testing.T, name string, ref func(c *sprmdCase) string) {
	c := sprmdFixture(t, name)
	pinned := c.oldest(t)
	c.pin(t, ref(c), pinned)
	c.seal(t)
	dropped := false
	for _, m := range c.dropped {
		dropped = dropped || m == pinned
	}
	if !dropped {
		t.Fatal("fixture: the pinned manifest was not dropped by the pruning seal")
	}
	want := c.want(t)
	pin := sprscBlobs(t, c.r, c.key, pinned)
	inter, rest := 0, map[string]bool{}
	for k := range want {
		if pin[k] {
			inter++
		} else {
			rest[k] = true
		}
	}
	if inter == 0 || len(rest) == 0 {
		t.Fatalf("fixture: %d pinned key(s) in the release set, %d other(s)", inter, len(rest))
	}
	got := c.r.sent(t)
	for k := range pin {
		if _, ok := got[k]; ok {
			t.Errorf("%s was released, but the media export pins a manifest that names it\n%s", short(k), c.logs)
		}
	}
	for k := range rest {
		if _, ok := got[k]; !ok {
			t.Errorf("%s was not released\n%s", short(k), c.logs)
		}
	}
}

func TestSealPruneMediaFrees(t *testing.T) {
	c := sprmdFixture(t, "sprmd-frees")
	c.seal(t)
	want := c.want(t)
	got := c.r.sent(t)
	if len(got) != len(want) {
		t.Errorf("released %d keys, want %d\n%s", len(got), len(want), c.logs)
	}
	for k := range want {
		if p, ok := got[k]; !ok {
			t.Errorf("%s was not released", short(k))
		} else if p != hex.EncodeToString(blobReleaseProof(c.key, k)) {
			t.Errorf("%s: the preimage is not blobReleaseProof(media key, key)", short(k))
		}
	}
	for k := range got {
		if !want[k] {
			t.Errorf("%s was released, but a kept version or the new head names it", short(k))
		}
	}
	if c.after.ReleaseGen != c.before.ReleaseGen+1 {
		t.Errorf("#media head generation %d -> %d, want +1", c.before.ReleaseGen, c.after.ReleaseGen)
	}
	c.recorded(t)
}

func TestSealPruneMediaPinKept(t *testing.T) {
	sprmdPinKept(t, "sprmd-pin", func(c *sprmdCase) string {
		return exportMediaRef(deriveKey(c.r.name, c.r.pass)).name()
	})
}

func TestSealPruneMediaLegacyPinKept(t *testing.T) {
	sprmdPinKept(t, "sprmd-legacy", func(c *sprmdCase) string { return "export/" + c.r.name + "#media" })
}

func TestSealPruneMediaPinUnreadable(t *testing.T) {
	c := sprmdFixture(t, "sprmd-unread")
	c.pin(t, exportMediaRef(deriveKey(c.r.name, c.r.pass)).name(), strings.Repeat("ab", 32))
	c.seal(t)
	if n := c.r.releases(); n != 0 {
		t.Errorf("%d /release request(s) while the export's pinned manifest could not be read\n%s", n, c.logs)
	}
	if !strings.Contains(c.logs, "nothing released early -- a kept version could not be read") {
		t.Errorf("no skip line for an unreadable export pin\n%s", c.logs)
	}
	c.recorded(t)
}

func TestSealPruneMediaTooLarge(t *testing.T) {
	old := sealPruneMediaMaxKeys
	sealPruneMediaMaxKeys = 3
	t.Cleanup(func() { sealPruneMediaMaxKeys = old })
	t.Run("media", func(t *testing.T) {
		c := sprmdFixture(t, "sprmd-large")
		c.seal(t)
		if n := c.r.releases(); n != 0 {
			t.Errorf("%d /release request(s) above the #media bound\n%s", n, c.logs)
		}
		if !strings.Contains(c.logs, "nothing released early -- too many objects to compare") {
			t.Errorf("no skip line for a #media compare above the bound\n%s", c.logs)
		}
		c.recorded(t)
	})
	t.Run("bare", func(t *testing.T) {
		r := sprelSetup(t, "sprmd-large-bare", "the bare vault has no bound", 3*cdcMax)
		r.fourSeals(t)
		sprelPrune(t)
		logs := r.seal(t, false)
		if n := r.releases(); n == 0 {
			t.Errorf("the bare vault released nothing under the #media bound\n%s", logs)
		}
		if strings.Contains(logs, "too many objects to compare") {
			t.Errorf("the #media bound was applied to the bare vault\n%s", logs)
		}
	})
}

func TestSealPruneMediaRestoreDistrust(t *testing.T) {
	base := newHTTPStore(t)
	p := relGenEnv(t)
	const name, pass = "sprmd-restore", "media restore release generation horse staple"
	createVault(base, name, pass)
	scoped := name + "#media"
	head := sprscPlainVault(t, base, scoped, pass, 3)
	hk := relGenHeadKey(base, scoped, pass)
	if err := relGenRecord(p, hk, 1); err != nil {
		t.Fatal(err)
	}
	blobCache = nil
	blobCacheAdd("sprmdrestoreK")
	captureStdout(t, func() { relGenAtScopeRestore(base, scoped, pass, head) })
	if relGenCacheLines(p)["sprmdrestoreK"] || blobCacheKnown("sprmdrestoreK") {
		t.Error("a #media vault restore kept a chunk cache filled under an older release generation")
	}
	if g, ok := relGenSeen(p, hk); !ok || g != 3 {
		t.Errorf("record after the #media restore = (%d, %v), want (3, true)", g, ok)
	}
}
