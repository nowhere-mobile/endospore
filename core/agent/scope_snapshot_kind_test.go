package main

import (
	"os"
	"path/filepath"
	"testing"
)

// Q141 (docs/product-decisions.md, 2026-10-20): #media and #apps keep only automatic snapshots, so a "Back up
// now" pins neither; the bare vault and the other scopes keep their manual pins.

func TestScopeSnapshotKind_Helper(t *testing.T) {
	for _, c := range []struct {
		profile string
		want    bool
	}{
		{"sskname", true},
		{"sskname#media", false},
		{"sskname#apps", false},
		{"sskname#de", true},
		{"sskname#sys", true},
		{"sskname#keys", true},
		{"sskname#appsy", true},
		{"sskname#apps#de", true},
	} {
		if got := scopeKeepsManualPins(c.profile); got != c.want {
			t.Errorf("scopeKeepsManualPins(%q) = %v, want %v", c.profile, got, c.want)
		}
	}
}

func TestScopeSnapshotKind_DemoteManualSnaps(t *testing.T) {
	in := []headSnap{
		{Version: 5, Manifest: "m5", Time: 50, Kind: "manual"},
		{Version: 4, Manifest: "m4", Time: 40},
		{Version: 3, Manifest: "m3", Time: 30, Kind: "manual"},
	}
	got := demoteManualSnaps(in)
	if len(got) != len(in) {
		t.Fatalf("len = %d, want %d", len(got), len(in))
	}
	for i, s := range got {
		if s.Kind != "" || s.Version != in[i].Version || s.Manifest != in[i].Manifest || s.Time != in[i].Time {
			t.Errorf("entry %d = %+v from %+v", i, s, in[i])
		}
	}
	if in[0].Kind != "manual" || in[2].Kind != "manual" {
		t.Errorf("the input slice was mutated: %+v", in)
	}
	if n := len(demoteManualSnaps(nil)); n != 0 {
		t.Errorf("demoteManualSnaps(nil) has %d entries", n)
	}
}

// sskSealFile seals a one-file tree for name+suf whose content is body.
func sskSealFile(t *testing.T, base, name, pass, body string) {
	t.Helper()
	d := t.TempDir()
	if err := os.WriteFile(filepath.Join(d, "f.txt"), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, d)
	pushFenceSeq, pushFenceSampled = 0, false
}

// sskRekeyed returns a store holding a profile that changed its passphrase, so #apps and #media are vaults.
func sskRekeyed(t *testing.T, name, p1, p2 string) string {
	t.Helper()
	base := newHTTPStore(t)
	if createVault(base, name, p1) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	pushProfile(base, name, p1, stageDir(t, "bare0"))
	pushProfile(base, name+"#apps", p1, stageApps(t, "com.example.a"))
	sskSealFile(t, base, name+"#media", p1, "media0")
	pushProfile(base, name, p1, stageDir(t, "bare1"))
	pushFenceSeq, pushFenceSampled = 0, false
	if _, err := rotateVault(base, name, p1, p2, nil, true); err != nil {
		t.Fatalf("rotateVault: %v", err)
	}
	for _, suf := range []string{"#apps", "#media"} {
		scopeHeadVault(t, base, name+suf, p2) // fatals when the head is not a vault
	}
	return base
}

func stageDir(t *testing.T, body string) string {
	t.Helper()
	d := t.TempDir()
	if err := os.WriteFile(filepath.Join(d, "f.txt"), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return d
}

// sskInjectManual makes the scope's head vault look like one sealed before Q141: a manual head and a manual
// History entry.
func sskInjectManual(t *testing.T, base, scoped, pass string) {
	t.Helper()
	v := scopeHeadVault(t, base, scoped, pass)
	if len(v.History) == 0 {
		t.Fatalf("%s: no History to inject into", scoped)
	}
	v.History[0].Kind = "manual"
	v.HeadKind = "manual"
	v.Version++
	key, _, ok := resolveKeySession(base, scoped, pass, nil)
	if !ok {
		t.Fatalf("%s: no key", scoped)
	}
	signVault(v, key)
	putHead(base, scoped, pass, postBlob(base, serializeVault(v)))
	pushFenceSeq, pushFenceSampled = 0, false
	got := scopeHeadVault(t, base, scoped, pass)
	if got.HeadKind != "manual" || got.History[0].Kind != "manual" {
		t.Fatalf("%s: the injected manual pin did not stick", scoped)
	}
}

func assertNoManualPin(t *testing.T, v *vault, scoped string) {
	t.Helper()
	if len(v.History) == 0 {
		t.Errorf("%s: no History -- the seals took no snapshot", scoped)
	}
	if v.HeadKind != "" {
		t.Errorf("%s: HeadKind = %q, want automatic", scoped, v.HeadKind)
	}
	for _, s := range v.History {
		if s.Kind == "manual" {
			t.Errorf("%s: History holds a manual pin: %+v", scoped, s)
		}
	}
}

func TestScopeSnapshotKind_AppsManualSaveIsNotPinned(t *testing.T) {
	const name, p1, p2 = "sskapps", "ssk apps first passphrase", "ssk apps second passphrase"
	base := sskRekeyed(t, name, p1, p2)
	pushProfile(base, name+"#apps", p2, stageApps(t, "com.example.a", "com.example.b"))
	pushFenceSeq, pushFenceSampled = 0, false
	sskInjectManual(t, base, name+"#apps", p2)
	t.Setenv("NOWHERE_SEAL_KIND", "manual")
	pushProfile(base, name+"#apps", p2, stageApps(t, "com.example.a", "com.example.b", "com.example.c"))
	pushFenceSeq, pushFenceSampled = 0, false
	pushProfile(base, name+"#apps", p2, stageApps(t, "com.example.a", "com.example.b", "com.example.c", "com.example.d"))
	pushFenceSeq, pushFenceSampled = 0, false
	assertNoManualPin(t, scopeHeadVault(t, base, name+"#apps", p2), name+"#apps")
}

func TestScopeSnapshotKind_MediaManualSaveIsNotPinned(t *testing.T) {
	const name, p1, p2 = "sskmedia", "ssk media first passphrase", "ssk media second passphrase"
	base := sskRekeyed(t, name, p1, p2)
	sskSealFile(t, base, name+"#media", p2, "media1")
	sskInjectManual(t, base, name+"#media", p2)
	t.Setenv("NOWHERE_SEAL_KIND", "manual")
	sskSealFile(t, base, name+"#media", p2, "media2")
	sskSealFile(t, base, name+"#media", p2, "media3")
	assertNoManualPin(t, scopeHeadVault(t, base, name+"#media", p2), name+"#media")
}

func TestScopeSnapshotKind_BareVaultKeepsItsManualPin(t *testing.T) {
	const name, p1, p2 = "sskbare", "ssk bare first passphrase", "ssk bare second passphrase"
	base := sskRekeyed(t, name, p1, p2)
	t.Setenv("NOWHERE_SEAL_KIND", "manual")
	sskSealFile(t, base, name, p2, "bare2")
	sskSealFile(t, base, name, p2, "bare3")
	v := scopeHeadVault(t, base, name, p2)
	if v.HeadKind != "manual" {
		t.Errorf("bare HeadKind = %q, want manual", v.HeadKind)
	}
	pinned := 0
	for _, s := range v.History {
		if s.Kind == "manual" {
			pinned++
		}
	}
	if pinned == 0 {
		t.Errorf("the bare vault kept no manual pin: %+v", v.History)
	}
}
