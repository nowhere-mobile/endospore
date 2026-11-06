package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestOnDemandAppDefersAndSelectiveFetch (#204 on-demand apps P2): an app kept ON-DEMAND has its APK bytes sealed
// into name#apps but listed in NOWHERE_DEFER_LIST, so the seal puts them in the manifest's DEFERRED index --
// EXCLUDED from the login restore -- while the installed app, the _meta placeholder, and manifest.tsv stay
// essential. Then a tap materialises ONLY that package's bytes via restoreAppCode. This proves the three P2
// invariants together: (a) selective defer (only the listed rels), (b) login restore skips the deferred APK but
// keeps the placeholder, (c) restoreAppCode fetches one package's APK set byte-for-byte and nothing else.
func TestOnDemandAppDefersAndSelectiveFetch(t *testing.T) {
	// The worker forces the media heuristic OFF for #apps (#200): installed code must ride the login restore
	// whole. On-demand APKs defer ONLY via the explicit list, independent of this.
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "0")
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "4096") // multi-MB APKs are "large file" candidates

	base := newHTTPStore(t)
	name, pass := "ondemand", "materialise horse battery staple"
	createVault(base, name, pass)

	src := t.TempDir()
	mustDir := func(p string) {
		if err := os.MkdirAll(p, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	mustDir(filepath.Join(src, "com.keep"))
	mustDir(filepath.Join(src, "com.od"))
	mustDir(filepath.Join(src, "com.od", "_meta"))

	keepApk := prBytes(3 << 20) // installed app: essential (not in the defer list)
	odBase := prBytes(5 << 20)  // on-demand app: base + split, both deferred
	odSplit := prBytes(1 << 20)
	write := func(p string, b []byte) {
		if err := os.WriteFile(p, b, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	write(filepath.Join(src, "com.keep", "base.apk"), keepApk)
	write(filepath.Join(src, "com.od", "base.apk"), odBase)
	write(filepath.Join(src, "com.od", "split_x.apk"), odSplit)
	// _meta is the archived-placeholder snapshot the chooser reads at login -- essential, tiny.
	write(filepath.Join(src, "com.od", "_meta", "meta"), []byte("vc\t42\ncert\tZm9v\nact\tcom.od/.Main\tOnDemand\n"))
	write(filepath.Join(src, "manifest.tsv"),
		[]byte("com.keep\t7\t1\tinstalled\tbase.apk\ncom.od\t42\t1\tondemand\tbase.apk\tsplit_x.apk\n"))

	// The worker's NOWHERE_DEFER_LIST: the on-demand app's APK rels, kept OUTSIDE the staged tree so the seal
	// walk never seals the directive itself.
	deferPath := filepath.Join(t.TempDir(), "defer")
	write(deferPath, []byte("com.od/base.apk\ncom.od/split_x.apk\n"))
	t.Setenv("NOWHERE_DEFER_LIST", deferPath)

	pushProfile(base, name+"#apps", pass, src)

	// The sealed manifest must DEFER exactly the two on-demand APKs -- and nothing else.
	key, mb, ok := resolveKey(base, name+"#apps", pass)
	if !ok {
		t.Fatal("no #apps head after push")
	}
	var m chunkManifest
	if err := json.Unmarshal(unseal(key, mb)[len(cdcMagic):], &m); err != nil {
		t.Fatalf("decode #apps manifest: %v", err)
	}
	wantDef := map[string]bool{"com.od/base.apk": true, "com.od/split_x.apk": true}
	if len(m.Deferred) != len(wantDef) {
		t.Fatalf("deferred set = %v, want exactly %v", deferredRels(m.Deferred), wantDef)
	}
	for rel := range wantDef {
		if _, ok := m.Deferred[rel]; !ok {
			t.Fatalf("expected %q deferred; deferred set = %v", rel, deferredRels(m.Deferred))
		}
	}

	// (b) The LOGIN restore (essential region only) brings back the installed app, the _meta placeholder, and
	// manifest.tsv -- but NOT the on-demand APK bytes.
	login := t.TempDir()
	cdcRestore(base, key, m, login)
	if got, err := os.ReadFile(filepath.Join(login, "com.keep", "base.apk")); err != nil || !bytes.Equal(got, keepApk) {
		t.Fatalf("installed app must restore at login (err=%v)", err)
	}
	if _, err := os.Stat(filepath.Join(login, "com.od", "_meta", "meta")); err != nil {
		t.Fatalf("on-demand _meta placeholder must restore at login: %v", err)
	}
	if _, err := os.Stat(filepath.Join(login, "manifest.tsv")); err != nil {
		t.Fatalf("manifest.tsv must restore at login: %v", err)
	}
	if _, err := os.Stat(filepath.Join(login, "com.od", "base.apk")); !os.IsNotExist(err) {
		t.Fatalf("on-demand APK must NOT restore at login (deferred); stat err=%v", err)
	}

	// (c) A tap materialises ONLY com.od's APK set, byte-for-byte. restoreAppCode takes the FULL scope verbatim
	// (symmetric with the restore/push verbs -- the worker + CLI pass "${name}#apps").
	tap := t.TempDir()
	n, err := restoreAppCode(base, name+"#apps", pass, "com.od", tap)
	if err != nil {
		t.Fatalf("restoreAppCode: %v", err)
	}
	if n != 2 {
		t.Fatalf("materialised %d apk, want 2", n)
	}
	if got, err := os.ReadFile(filepath.Join(tap, "com.od", "base.apk")); err != nil || !bytes.Equal(got, odBase) {
		t.Fatalf("com.od/base.apk did not materialise whole (err=%v)", err)
	}
	if got, err := os.ReadFile(filepath.Join(tap, "com.od", "split_x.apk")); err != nil || !bytes.Equal(got, odSplit) {
		t.Fatalf("com.od/split_x.apk did not materialise whole (err=%v)", err)
	}
	// Selective: the tap must NOT drag the OTHER app's bytes along.
	if _, err := os.Stat(filepath.Join(tap, "com.keep", "base.apk")); !os.IsNotExist(err) {
		t.Fatalf("restoreAppCode must fetch ONLY the tapped package; com.keep leaked (err=%v)", err)
	}

	// A package with no deferred bytes (e.g. an installed-only app, or a typo) is a loud error, not a silent
	// empty success.
	if _, err := restoreAppCode(base, name+"#apps", pass, "com.keep", t.TempDir()); err == nil {
		t.Fatal("restoreAppCode of an installed-only package should error (no deferred bytes)")
	}
}

// TestOnDemandArchivedReseal (#204) is the seal-safety regression for the on-demand tap. appcode_seal re-seals
// name#apps on EVERY periodic sync, rebuilding the staging from local state. Once an on-demand app is an ARCHIVED
// placeholder it has NO local APK to stage, so the walk never sees "<pkg>/base.apk" -- and the re-seal would DROP
// the app's deferred bytes, so a later tap materialises nothing (ERR-FETCH, proven on lynx 2026-07-25). The worker
// sets NOWHERE_CARRY_DEFERRED=1 so the push extends the present-not-deleted carry (the #84 media seal-safety) to
// the media-flag-off #apps seal: an un-seen deferred entry is carried forward, not dropped. This proves the flag
// is load-bearing -- with it the archived re-seal KEEPS the APK, without it the archived re-seal loses it.
func TestOnDemandArchivedReseal(t *testing.T) {
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "0") // #200: installed code rides the login restore whole; APKs defer via the list only
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "4096")

	odBase := prBytes(5 << 20)
	odSplit := prBytes(1 << 20)
	write := func(p string, b []byte) {
		if err := os.WriteFile(p, b, 0o600); err != nil {
			t.Fatal(err)
		}
	}

	// firstSeal stages com.od as on-demand (APK bytes present + in the defer list) and pushes -- the head that a
	// later archived re-seal must not clobber. Returns the store so the caller re-seals the SAME scope.
	firstSeal := func(base, name, pass string) {
		src := t.TempDir()
		if err := os.MkdirAll(filepath.Join(src, "com.od", "_meta"), 0o755); err != nil {
			t.Fatal(err)
		}
		write(filepath.Join(src, "com.od", "base.apk"), odBase)
		write(filepath.Join(src, "com.od", "split_x.apk"), odSplit)
		write(filepath.Join(src, "com.od", "_meta", "meta"), []byte("vc\t42\ncert\tZm9v\n"))
		write(filepath.Join(src, "manifest.tsv"), []byte("com.od\t42\t1\tondemand\tbase.apk\tsplit_x.apk\n"))
		deferPath := filepath.Join(t.TempDir(), "defer")
		write(deferPath, []byte("com.od/base.apk\ncom.od/split_x.apk\n"))
		t.Setenv("NOWHERE_DEFER_LIST", deferPath)
		pushProfile(base, name+"#apps", pass, src)
	}

	// archivedSeal simulates the periodic re-seal AFTER com.od became an archived placeholder: only the _meta +
	// manifest.tsv are staged (the chooser can't resolve an archived app's APK), and the defer list is empty.
	archivedSeal := func(base, name, pass string) {
		src := t.TempDir()
		if err := os.MkdirAll(filepath.Join(src, "com.od", "_meta"), 0o755); err != nil {
			t.Fatal(err)
		}
		write(filepath.Join(src, "com.od", "_meta", "meta"), []byte("vc\t42\ncert\tZm9v\n"))
		write(filepath.Join(src, "manifest.tsv"), []byte("com.od\t42\t1\tondemand\n"))
		t.Setenv("NOWHERE_DEFER_LIST", "") // no APK to defer while archived
		pushProfile(base, name+"#apps", pass, src)
	}

	t.Run("carry keeps the archived on-demand APK", func(t *testing.T) {
		t.Setenv("NOWHERE_CARRY_DEFERRED", "1") // the worker sets this on appcode_seal
		base := newHTTPStore(t)
		name, pass := "carry", "materialise horse battery staple"
		createVault(base, name, pass)
		firstSeal(base, name, pass)
		archivedSeal(base, name, pass) // re-seal while archived -- must NOT drop the deferred APK

		tap := t.TempDir()
		n, err := restoreAppCode(base, name+"#apps", pass, "com.od", tap)
		if err != nil {
			t.Fatalf("after an archived re-seal the tap must still materialise the carried APK: %v", err)
		}
		if n != 2 {
			t.Fatalf("materialised %d apk, want 2 (base + split carried forward)", n)
		}
		if got, err := os.ReadFile(filepath.Join(tap, "com.od", "base.apk")); err != nil || !bytes.Equal(got, odBase) {
			t.Fatalf("carried com.od/base.apk did not materialise whole (err=%v)", err)
		}
		if got, err := os.ReadFile(filepath.Join(tap, "com.od", "split_x.apk")); err != nil || !bytes.Equal(got, odSplit) {
			t.Fatalf("carried com.od/split_x.apk did not materialise whole (err=%v)", err)
		}
	})

	t.Run("without the flag the archived re-seal drops the APK (the bug)", func(t *testing.T) {
		t.Setenv("NOWHERE_CARRY_DEFERRED", "") // pre-fix behaviour: media-flag-off seal drops un-seen deferred entries
		base := newHTTPStore(t)
		name, pass := "drop", "materialise horse battery staple"
		createVault(base, name, pass)
		firstSeal(base, name, pass)
		archivedSeal(base, name, pass) // re-seal while archived -- drops the deferred APK

		if _, err := restoreAppCode(base, name+"#apps", pass, "com.od", t.TempDir()); err == nil {
			t.Fatal("without NOWHERE_CARRY_DEFERRED the archived re-seal should drop the APK -> restoreAppCode errors")
		}
	})
}

func deferredRels(m map[string]deferredFile) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}

// TestRestoreOdDataGuards (#204): the RESTORE-ODDATA daemon verb's guard paths. A bad pkg name is rejected BEFORE
// any session read (defence-in-depth -- pkg builds a per-app path in the worker's odrestore op); no session -> NONE;
// a local/offline throwaway session has no roamed on-demand hold to restore -> "OK LOCAL". The happy path (move the
// hold back + reown + re-grant) is su:s0 shell + on-device, validated live; the property this asserts is that the
// verb itself NEVER touches the store (it dispatches a local worker op only after a real session is confirmed).
func TestRestoreOdDataGuards(t *testing.T) {
	dest := t.TempDir()

	// bad pkg -> ERR-PKG, before any session read
	for _, bad := range []string{"", "../etc", "a b", "a/b", "a\tb", "a\nb", ".", ".."} {
		cli, srv := net.Pipe()
		go func(p string) { handleRestoreOdData(srv, dest, p); srv.Close() }(bad)
		b, _ := io.ReadAll(cli)
		if got := strings.TrimSpace(string(b)); got != "ERR-PKG" {
			t.Fatalf("bad pkg %q: got %q want ERR-PKG", bad, got)
		}
	}

	// a valid pkg but no logged-in session -> NONE
	cli, srv := net.Pipe()
	go func() { handleRestoreOdData(srv, dest, "org.fossify.math"); srv.Close() }()
	b, _ := io.ReadAll(cli)
	if got := strings.TrimSpace(string(b)); got != "NONE" {
		t.Fatalf("no session: got %q want NONE", got)
	}

	// a local/throwaway session has no roamed hold -> OK LOCAL (never reaches the worker/store)
	markRoamSession(dest, "x", "y", "12", "")
	markLocalSession(dest)
	cli2, srv2 := net.Pipe()
	go func() { handleRestoreOdData(srv2, dest, "org.fossify.math"); srv2.Close() }()
	b2, _ := io.ReadAll(cli2)
	if got := strings.TrimSpace(string(b2)); got != "OK LOCAL" {
		t.Fatalf("local session: got %q want 'OK LOCAL'", got)
	}
}
