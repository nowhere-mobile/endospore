package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// TestAppsScopeRestoresWhole (#200 app-persistence P2): captured app CODE (name#apps) must seal ALL-ESSENTIAL --
// never split into the on-demand Deferred index -- so a restore materializes every APK byte-for-byte at login. A
// deferred APK would come back as a mediad stub, and PackageInstaller can't install a stub. The logoff worker
// forces NOWHERE_ONDEMAND_MEDIA=0 for the #apps push; this proves that seal round-trips whole even for a large,
// multi-chunk APK set (base + split), which the file-aligned walk treats as "large files".
func TestAppsScopeRestoresWhole(t *testing.T) {
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "0")         // app code is always login-essential (the worker sets this)
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "4096") // small threshold -> the multi-MB APKs are "large file" candidates

	base := newHTTPStore(t)
	name, pass := "appsrt", "footprint horse battery staple"
	createVault(base, name, pass)

	// stage an APK set (base + a split) + the restore manifest, exactly as appcode_seal does before the push
	src := t.TempDir()
	if err := os.MkdirAll(filepath.Join(src, "com.example.app"), 0o755); err != nil {
		t.Fatal(err)
	}
	baseApk := prBytes(5 << 20) // multi-chunk, well above the file threshold
	split := prBytes(1 << 20)
	if err := os.WriteFile(filepath.Join(src, "com.example.app", "base.apk"), baseApk, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(src, "com.example.app", "split_x.apk"), split, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(src, "manifest.tsv"),
		[]byte("com.example.app\t42\t1\tbase.apk\tsplit_x.apk\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name+"#apps", pass, src)

	// the sealed manifest must be ALL-ESSENTIAL (no Deferred entries) -- else an APK restores as a stub
	key, mb, ok := resolveKey(base, name+"#apps", pass)
	if !ok {
		t.Fatal("no #apps head after push")
	}
	var m chunkManifest
	if err := json.Unmarshal(unseal(key, mb)[len(cdcMagic):], &m); err != nil {
		t.Fatalf("decode #apps manifest: %v", err)
	}
	if len(m.Deferred) != 0 {
		t.Fatalf("app code must seal ALL-essential; got %d deferred entries (a deferred APK restores as a stub)", len(m.Deferred))
	}
	if len(m.Chunks) == 0 {
		t.Fatal("no essential chunks in the #apps manifest")
	}

	// and it restores byte-for-byte -- the crux: the roamed APK comes back installable
	dst := t.TempDir()
	cdcRestore(base, key, m, dst)
	if got, err := os.ReadFile(filepath.Join(dst, "com.example.app", "base.apk")); err != nil || !bytes.Equal(got, baseApk) {
		t.Fatalf("base.apk did not restore whole (err=%v)", err)
	}
	if got, err := os.ReadFile(filepath.Join(dst, "com.example.app", "split_x.apk")); err != nil || !bytes.Equal(got, split) {
		t.Fatalf("split_x.apk did not restore whole (err=%v)", err)
	}
	if b, err := os.ReadFile(filepath.Join(dst, "manifest.tsv")); err != nil || !bytes.Contains(b, []byte("com.example.app")) {
		t.Fatalf("manifest.tsv missing from restore: %v", err)
	}
}
