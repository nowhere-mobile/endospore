package main

import (
	"archive/tar"
	"bytes"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"testing"
)

// NWP-20261207-08 (h47 #2, docs/product-decisions.md 2026-10-28; built on the carry, 2026-10-30 #2): an #apps restore
// whose only skips are local write failures inside kept packages still earns its receipt, so the session's #apps
// seals carry those packages by hash instead of refusing.

// stopUntarSkipRecording turns the skip record off and clears it, so no later test in the package records.
func stopUntarSkipRecording() {
	untarSkip.mu.Lock()
	defer untarSkip.mu.Unlock()
	untarSkip.on = false
	untarSkip.names = nil
	untarSkip.prof, untarSkip.pass = "", ""
}

// skipCarryEntry is one entry of a test tar: a file with a body, a directory, or a symlink.
type skipCarryEntry struct {
	name, body, link string
	dir              bool
}

func skipCarryTar(t *testing.T, entries ...skipCarryEntry) *bytes.Reader {
	t.Helper()
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	for _, e := range entries {
		hdr := &tar.Header{Name: e.name, Mode: 0o600, Typeflag: tar.TypeReg, Size: int64(len(e.body))}
		switch {
		case e.dir:
			hdr.Typeflag, hdr.Mode, hdr.Size = tar.TypeDir, 0o700, 0
		case e.link != "":
			hdr.Typeflag, hdr.Linkname, hdr.Size = tar.TypeSymlink, e.link, 0
		}
		if err := tw.WriteHeader(hdr); err != nil {
			t.Fatal(err)
		}
		if hdr.Typeflag == tar.TypeReg {
			if _, err := tw.Write([]byte(e.body)); err != nil {
				t.Fatal(err)
			}
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	return bytes.NewReader(buf.Bytes())
}

// skipCarryBlock makes rel under dest a directory with a child, so opening it for write fails.
func skipCarryBlock(t *testing.T, dest, rel string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(dest, rel, "child"), 0o700); err != nil {
		t.Fatal(err)
	}
}

func TestAppsSkipsExcusable(t *testing.T) {
	for _, c := range []struct {
		label   string
		profile string
		names   []string
		skipped int
		carry   string
		want    []string
		ok      bool
	}{
		{"one package file", "skipcarryx#apps", []string{"com.ex.a/base.apk"}, 1, "1", []string{"com.ex.a"}, true},
		{"two packages, sorted", "skipcarryx#apps", []string{"com.ex.b/x", "com.ex.a/base.apk"}, 2, "1", []string{"com.ex.a", "com.ex.b"}, true},
		{"one package twice", "skipcarryx#apps", []string{"com.ex.a/base.apk", "com.ex.a/split.apk"}, 2, "1", []string{"com.ex.a"}, true},
		{"a package dir entry", "skipcarryx#apps", []string{"com.ex.a/"}, 1, "1", []string{"com.ex.a"}, true},
		{"manifest.tsv", "skipcarryx#apps", []string{"manifest.tsv"}, 1, "1", nil, false},
		{"a root file beside a package", "skipcarryx#apps", []string{"com.ex.a/base.apk", "manifest.tsv"}, 2, "1", nil, false},
		{"an unsafe entry or a link", "skipcarryx#apps", []string{""}, 1, "1", nil, false},
		{"a non-package first segment", "skipcarryx#apps", []string{"_meta/x"}, 1, "1", nil, false},
		{"names fewer than skipped", "skipcarryx#apps", []string{"com.ex.a/base.apk"}, 2, "1", nil, false},
		{"a #media profile", "skipcarryx#media", []string{"com.ex.a/base.apk"}, 1, "1", nil, false},
		{"a bare profile", "skipcarryx", []string{"com.ex.a/base.apk"}, 1, "1", nil, false},
		{"the carry off", "skipcarryx#apps", []string{"com.ex.a/base.apk"}, 1, "0", nil, false},
		{"nothing skipped", "skipcarryx#apps", nil, 0, "1", nil, false},
	} {
		t.Run(c.label, func(t *testing.T) {
			t.Setenv("NOWHERE_CARRY_ESSENTIAL", c.carry)
			got, ok := appsSkipsExcusable(c.profile, c.names, c.skipped)
			if ok != c.ok || !reflect.DeepEqual(got, c.want) {
				t.Fatalf("appsSkipsExcusable(%q, %q, %d) = %q, %v; want %q, %v", c.profile, c.names, c.skipped, got, ok, c.want, c.ok)
			}
		})
	}
}

func TestUntarRecordsSkipNames(t *testing.T) {
	t.Cleanup(stopUntarSkipRecording)
	unwritable := func() (string, *bytes.Reader) {
		dest := t.TempDir()
		// dest/com.ex.a is a regular file, so the mkdir-parent site fails for com.ex.a/base.apk.
		if err := os.WriteFile(filepath.Join(dest, "com.ex.a"), []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
		return dest, skipCarryTar(t, skipCarryEntry{name: "com.ex.a/base.apk", body: "apk"})
	}

	stopUntarSkipRecording()
	dest, tr := unwritable()
	if n := untarFrom(dest, tr); n != 1 {
		t.Fatalf("fixture: untarFrom skipped %d, want 1", n)
	}
	if got := untarSkipNamesSnapshot(); len(got) != 0 {
		t.Fatalf("an untar with recording not enabled recorded %q: only the restore verb may record", got)
	}

	resetUntarSkipNames()
	dest, tr = unwritable()
	untarFrom(dest, tr)
	if got := untarSkipNamesSnapshot(); !reflect.DeepEqual(got, []string{"com.ex.a/base.apk"}) {
		t.Fatalf("the mkdir-parent skip recorded %q, want [com.ex.a/base.apk]", got)
	}

	resetUntarSkipNames()
	if n := untarFrom(t.TempDir(), skipCarryTar(t, skipCarryEntry{name: "com.ex.b/x", link: "/etc/passwd"})); n != 1 {
		t.Fatalf("fixture: the link entry skipped %d, want 1", n)
	}
	if got := untarSkipNamesSnapshot(); !reflect.DeepEqual(got, []string{""}) {
		t.Fatalf("the link rejection recorded %q, want [\"\"]: a link must never be excusable", got)
	}
}

func TestAppsRestoreSkipEarnsReceipt(t *testing.T) {
	t.Cleanup(stopUntarSkipRecording)
	t.Setenv("NOWHERE_CARRY_ESSENTIAL", "1")
	const profile, other, pass = "skipcarrya#apps", "skipcarryb#apps", "correct horse battery staple"
	st := t.TempDir()
	t.Setenv("NOWHERE_STATE", st)
	list := filepath.Join(st, appsNotRestoredFile(profile, pass))

	// A list from an earlier sign-in of this profile goes at the top of the restore.
	if err := os.WriteFile(list, []byte("com.ex.old\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	resetUntarSkipNames()
	beginAppsNotRestored(profile, pass)
	if _, err := os.Stat(list); !os.IsNotExist(err) {
		t.Fatalf("beginAppsNotRestored left the earlier sign-in's list: %v", err)
	}

	dest := t.TempDir()
	skipCarryBlock(t, dest, "com.ex.a/base.apk")
	skipped := untarFrom(dest, skipCarryTar(t,
		skipCarryEntry{name: "manifest.tsv", body: "com.ex.a\t0\t0\tinstalled\tsplit.apk,base.apk\n"},
		skipCarryEntry{name: "com.ex.a/split.apk", body: "split"},
		skipCarryEntry{name: "com.ex.a/base.apk", body: "base"}))
	if skipped != 1 {
		t.Fatalf("fixture: untarFrom skipped %d, want 1", skipped)
	}
	if n := excuseAppsSkips(profile, dest, skipped); n != 0 {
		t.Fatalf("excuseAppsSkips = %d, want 0 for one kept package's write failure", n)
	}
	if _, err := os.Stat(filepath.Join(dest, "com.ex.a")); !os.IsNotExist(err) {
		t.Fatalf("the cut package directory stayed (%v): the chooser would install a partial APK set (NOWHERE-924)", err)
	}
	b, err := os.ReadFile(list)
	if err != nil || string(b) != "com.ex.a\n" {
		t.Fatalf("the apps-not-restored list reads %q (%v), want \"com.ex.a\\n\"", b, err)
	}
	if fi, err := os.Stat(list); err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("the list's mode is not 0600: %v %v", fi, err)
	}
	if _, err := os.Stat(filepath.Join(st, appsNotRestoredFile(other, pass))); !os.IsNotExist(err) {
		t.Fatalf("another profile has a list: %v", err)
	}
	for _, n := range []string{appsNotRestoredFile(profile, pass), "apps-not-restored-123456789.tmp"} {
		if !isSessionFileList(n) {
			t.Fatalf("the reap does not take %q (h59 #11)", n)
		}
	}
	finishRestore(profile, pass, "deadbeef", 0)
	if !haveRestoreReceipt(profileRefV2(profile, pass)) {
		t.Fatal("the excused restore wrote no receipt: every #apps seal of the session would be refused")
	}

	// A root file among the skips is never excused.
	st2 := t.TempDir()
	t.Setenv("NOWHERE_STATE", st2)
	resetUntarSkipNames()
	beginAppsNotRestored(profile, pass)
	dest = t.TempDir()
	skipCarryBlock(t, dest, "manifest.tsv")
	skipCarryBlock(t, dest, "com.ex.a/base.apk")
	skipped = untarFrom(dest, skipCarryTar(t,
		skipCarryEntry{name: "manifest.tsv", body: "com.ex.a\t0\t0\tinstalled\tbase.apk\n"},
		skipCarryEntry{name: "com.ex.a/base.apk", body: "base"}))
	if skipped != 2 {
		t.Fatalf("fixture: untarFrom skipped %d, want 2", skipped)
	}
	if n := excuseAppsSkips(profile, dest, skipped); n != 2 {
		t.Fatalf("excuseAppsSkips = %d with manifest.tsv among the skips, want 2", n)
	}
	if _, err := os.Stat(filepath.Join(dest, "com.ex.a")); err != nil {
		t.Fatalf("an unexcused restore removed a package directory: %v", err)
	}
	if _, err := os.Stat(filepath.Join(st2, appsNotRestoredFile(profile, pass))); !os.IsNotExist(err) {
		t.Fatalf("an unexcused restore wrote a list: %v", err)
	}
	finishRestore(profile, pass, "deadbeef", 2)
	if haveRestoreReceipt(profileRefV2(profile, pass)) {
		t.Fatal("an unexcused restore wrote a receipt")
	}
}

func TestSkippedAppCarriedNotRefused(t *testing.T) {
	t.Cleanup(stopUntarSkipRecording)
	st := t.TempDir()
	t.Setenv("NOWHERE_STATE", st)
	base := newHTTPStore(t)
	const name, pass = "skipcarryseal", "correct horse battery staple"
	createVault(base, name, pass)
	scope := name + "#apps"

	first := carrySeal(t, base, name, pass, stageApps(t, "com.example.keep", "com.example.aegis"))
	h := restoreReceiptHead(profileRefV2(scope, pass))
	if h == "" {
		t.Fatal("fixture: the first seal left no receipt head")
	}
	// A new session holds no receipt: only the restore can earn one.
	if err := os.RemoveAll(filepath.Join(st, "restore-receipts")); err != nil {
		t.Fatal(err)
	}

	// The sign-in's #apps restore: com.example.aegis/base.apk cannot be written.
	t.Setenv("NOWHERE_CARRY_ESSENTIAL", "1")
	resetUntarSkipNames()
	beginAppsNotRestored(scope, pass)
	dest := t.TempDir()
	skipCarryBlock(t, dest, "com.example.aegis/base.apk")
	skipped := untarFrom(dest, skipCarryTar(t, skipCarryEntry{name: "com.example.aegis/base.apk", body: "apk"}))
	if skipped != 1 {
		t.Fatalf("fixture: untarFrom skipped %d, want 1", skipped)
	}
	skipped = excuseAppsSkips(scope, dest, skipped)
	finishRestore(scope, pass, h, skipped)

	var second chunkManifest
	out := captureStdout(t, func() {
		second = carrySeal(t, base, name, pass, stageApps(t, "com.example.keep"))
	})
	if second.Apps["com.example.aegis"] != first.Apps["com.example.aegis"] {
		t.Fatalf("the not-restored app's Apps line changed: %q, want %q", second.Apps["com.example.aegis"], first.Apps["com.example.aegis"])
	}
	r1, ok1 := first.Ess["com.example.aegis/base.apk"]
	r2, ok2 := second.Ess["com.example.aegis/base.apk"]
	if !ok1 || !ok2 {
		t.Fatalf("the not-restored app's APK is not indexed (first %v, second %v)", ok1, ok2)
	}
	if got, want := strings.Join(second.Chunks[r2.S:r2.E], ","), strings.Join(first.Chunks[r1.S:r1.E], ","); got != want {
		t.Fatalf("the not-restored app's chunks changed:\n got %v\nwant %v", got, want)
	}
	if want := "push: profile " + logProfile(scope) + " 1 carried package(s) were not restored at this sign-in: kept from the last save (h47 #2)"; !strings.Contains(out, want) {
		t.Fatalf("the seal's stdout lacks %q:\n%s", want, out)
	}
	if strings.Contains(out, "com.example.aegis") {
		t.Fatal("the seal's stdout names the not-restored package: counts only (NWP-20261119-02)")
	}
}

func TestRestoreCaseExcusesBeforeFinish(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	i := strings.Index(src, `case "restore":`)
	if i < 0 {
		t.Fatal(`no case "restore": in main.go`)
	}
	body := src[i:]
	if j := strings.Index(body, `case "export-fetch":`); j > 0 {
		body = body[:j]
	}
	reset := strings.Index(body, "resetUntarSkipNames()")
	begin := strings.Index(body, "beginAppsNotRestored(profile, pass)")
	firstReturn := len(body) // the first return statement; a comment that says "return" does not count
	if loc := regexp.MustCompile(`(?m)^\s*return\b`).FindStringIndex(body); loc != nil {
		firstReturn = loc[0]
	}
	if reset < 0 || begin < 0 {
		t.Fatal("the restore case does not reset the skip record and the apps-not-restored list")
	}
	if begin > firstReturn || reset > firstReturn {
		t.Fatal("the skip record reset or the list removal comes after a return of the restore case")
	}
	for _, call := range []string{"restoreSkippingParked(", "skipped = untarFrom(dest"} {
		if k := strings.Index(body, call); k < 0 || k < reset {
			t.Fatalf("%s is missing or runs before resetUntarSkipNames", call)
		}
	}
	pair := "skipped = excuseAppsSkips(profile, dest, skipped)\n\t\tfinishRestore(profile, pass, restoredHead, skipped)"
	if strings.Count(body, pair) != 1 {
		t.Fatal("excuseAppsSkips must run directly before finishRestore, once")
	}
}
