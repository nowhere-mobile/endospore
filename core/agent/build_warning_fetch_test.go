package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// bwfEnv is a signed envelope for a seq-numbered warning.
func bwfEnv(k ed25519.PrivateKey, seq, issued, expires int64, versions ...string) []byte {
	body := bwBody(seq, issued, expires, versions...)
	return buildWarningEnvelope(body, bwSign(k, body))
}

// bwfFresh is a signed envelope issued a day before bwNow, expiring a month after it.
func bwfFresh(k ed25519.PrivateKey, seq int64, versions ...string) []byte {
	return bwfEnv(k, seq, bwNow-86400, bwNow+30*86400, versions...)
}

func bwfHash(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

// bwfFloor is a floor path in the test's own temp dir; it also points buildWarningSeqPath at it.
func bwfFloor(t *testing.T) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "build-warning-seq")
	old := buildWarningSeqPath
	buildWarningSeqPath = p
	t.Cleanup(func() { buildWarningSeqPath = old })
	return p
}

// bwfRead returns the floor file's bytes, or ok=false when it is absent.
func bwfRead(t *testing.T, path string) (string, bool) {
	t.Helper()
	b, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return "", false
	}
	if err != nil {
		t.Fatalf("read floor: %v", err)
	}
	return string(b), true
}

// bwfStore is an http store holding refs (name -> hash) and blobs (hash -> bytes), as TestFetchOtaReleaseVerifies.
func bwfStore(t *testing.T, refs map[string]string, blobs map[string][]byte) string {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if ref, ok := strings.CutPrefix(r.URL.Path, "/ref/"); ok {
			if v, ok := refs[ref]; ok {
				w.Write([]byte(v))
				return
			}
		}
		if k, ok := strings.CutPrefix(r.URL.Path, "/blob/"); ok {
			if v, ok := blobs[k]; ok {
				w.Write(v)
				return
			}
		}
		http.NotFound(w, r)
	}))
	t.Cleanup(srv.Close)
	return srv.URL
}

func TestBuildWarningFetchAbsentIsNone(t *testing.T) {
	bwUseKey(t)
	floor := bwfFloor(t)
	url := bwfStore(t, map[string]string{}, map[string][]byte{})
	if w, err := fetchBuildWarning(url, bwNow); w != nil || err != nil {
		t.Fatalf("nothing published must be (nil, nil): %+v, %v", w, err)
	}
	if _, ok := bwfRead(t, floor); ok {
		t.Fatal("a floor file was created with nothing published")
	}
}

func TestBuildWarningFetchRefusesBadBlob(t *testing.T) {
	k := bwUseKey(t)
	floor := bwfFloor(t)
	good := bwfFresh(k, 3, "0.5.45")
	h := bwfHash(good)
	renamed := "00" + h[2:]
	big := append([]byte(buildWarningMagic+"\n"), bytes.Repeat([]byte{'x'}, buildWarningEnvMax+1-len(buildWarningMagic)-1)...)
	hb := bwfHash(big)
	missing := bwfHash([]byte("never stored"))

	cases := []struct {
		name  string
		ref   string
		blobs map[string][]byte
		want  error
	}{
		{"renamed", renamed, map[string][]byte{renamed: good}, errBuildWarningHash},
		{"over the cap", hb, map[string][]byte{hb: big}, errBuildWarningTooBig},
		{"missing", missing, map[string][]byte{}, errBuildWarningMissing},
	}
	for _, c := range cases {
		url := bwfStore(t, map[string]string{buildWarningRefName: c.ref}, c.blobs)
		w, err := fetchBuildWarning(url, bwNow)
		if err == nil || w != nil {
			t.Errorf("%s: believed: %+v, %v", c.name, w, err)
			continue
		}
		if !errors.Is(err, c.want) {
			t.Errorf("%s: error %v, want %v", c.name, err, c.want)
		}
	}
	if _, ok := bwfRead(t, floor); ok {
		t.Fatal("a refused blob wrote the floor")
	}

	// Control: the same envelope under its true name is accepted, so the refusals above are not vacuous.
	url := bwfStore(t, map[string]string{buildWarningRefName: h}, map[string][]byte{h: good})
	w, err := fetchBuildWarning(url, bwNow)
	if err != nil || w == nil || w.Seq != 3 {
		t.Fatalf("a good blob was refused: %+v, %v", w, err)
	}
	if got, _ := bwfRead(t, floor); got != "3 "+h+"\n" {
		t.Fatalf("floor %q, want seq 3 and the envelope's hash", got)
	}
}

func TestBuildWarningAcceptFirstAndSame(t *testing.T) {
	k := bwUseKey(t)
	floor := filepath.Join(t.TempDir(), "build-warning-seq")
	env := bwfFresh(k, 3, "0.5.45")
	w, err := acceptBuildWarning(floor, env, bwNow)
	if err != nil || w == nil || w.Seq != 3 || !w.affects("0.5.45") {
		t.Fatalf("first accept: %+v, %v", w, err)
	}
	first, ok := bwfRead(t, floor)
	if !ok || first != "3 "+bwfHash(env)+"\n" {
		t.Fatalf("floor %q after the first accept", first)
	}
	if fi, err := os.Stat(floor); err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("floor mode: %v, %v", fi, err)
	}
	w, err = acceptBuildWarning(floor, env, bwNow+3600)
	if err != nil || w == nil || w.Seq != 3 {
		t.Fatalf("the same object at the next refresh was refused: %+v, %v", w, err)
	}
	if again, _ := bwfRead(t, floor); again != first {
		t.Fatalf("the floor changed on a re-accept: %q -> %q", first, again)
	}
	if _, ok := bwfRead(t, floor+".tmp"); ok {
		t.Fatal("a temp file was left beside the floor")
	}
}

func TestBuildWarningAcceptRefusesReplay(t *testing.T) {
	k := bwUseKey(t)
	floor := filepath.Join(t.TempDir(), "build-warning-seq")
	env4 := bwfFresh(k, 4, "0.5.45")
	if w, err := acceptBuildWarning(floor, env4, bwNow); err != nil || w == nil {
		t.Fatalf("seq 4: %+v, %v", w, err)
	}
	want4 := "4 " + bwfHash(env4) + "\n"
	if got, _ := bwfRead(t, floor); got != want4 {
		t.Fatalf("floor %q, want %q", got, want4)
	}
	for _, c := range []struct {
		name string
		env  []byte
	}{
		{"an older object (seq 3)", bwfFresh(k, 3, "0.5.45")},
		{"a different object at the floor's seq (4)", bwfFresh(k, 4, "0.5.46")},
	} {
		if w, err := acceptBuildWarning(floor, c.env, bwNow); err == nil || w != nil {
			t.Errorf("%s was accepted: %+v", c.name, w)
		}
		if got, _ := bwfRead(t, floor); got != want4 {
			t.Errorf("%s moved the floor to %q", c.name, got)
		}
	}
	env5 := bwfFresh(k, 5, "0.5.46")
	if w, err := acceptBuildWarning(floor, env5, bwNow); err != nil || w == nil || w.Seq != 5 {
		t.Fatalf("seq 5: %+v, %v", w, err)
	}
	if got, _ := bwfRead(t, floor); got != "5 "+bwfHash(env5)+"\n" {
		t.Fatalf("floor %q after seq 5", got)
	}
}

func TestBuildWarningAcceptDamagedFloor(t *testing.T) {
	k := bwUseKey(t)
	other := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{8}, 32))
	env := bwfFresh(k, 3, "0.5.45")
	hx := strings.Repeat("ab", 32)
	for _, content := range []string{
		"garbage",
		"garbage\n",
		"4",
		"4\n",
		"-1 " + hx + "\n",
		"4 " + hx + " extra\n",
		"4 " + strings.ToUpper(hx) + "\n",
		"4 " + hx,
		"4 " + hx + "\n4 " + hx + "\n",
		"0 " + hx + "\n",
		"99999999999999999999 " + hx + "\n",
	} {
		// A damaged floor is read as an absent one (h54 #4): the next verified object is accepted and replaces it.
		floor := filepath.Join(t.TempDir(), "build-warning-seq")
		if err := os.WriteFile(floor, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
		if w, err := acceptBuildWarning(floor, env, bwNow); err != nil || w == nil || w.Seq != 3 {
			t.Errorf("floor %q: the next verified object was not accepted: %+v, %v", content, w, err)
		}
		if got, _ := bwfRead(t, floor); got != "3 "+bwfHash(env)+"\n" {
			t.Errorf("floor %q was not replaced by the accepted object: %q", content, got)
		}
		if _, err := os.Lstat(floor + ".tmp"); !errors.Is(err, fs.ErrNotExist) {
			t.Errorf("floor %q: a temp file was left beside the replaced floor: %v", content, err)
		}

		// A damaged floor plus an object that does not verify: refused, and the damaged file is left as it is.
		for _, bad := range []struct {
			what string
			env  []byte
		}{
			{"an expired object", bwfEnv(k, 3, bwNow-2*86400, bwNow-100, "0.5.45")},
			{"a badly signed object", bwfFresh(other, 3, "0.5.45")},
		} {
			floor := filepath.Join(t.TempDir(), "build-warning-seq")
			if err := os.WriteFile(floor, []byte(content), 0o600); err != nil {
				t.Fatal(err)
			}
			if w, err := acceptBuildWarning(floor, bad.env, bwNow); err == nil || w != nil {
				t.Errorf("floor %q: %s accepted %+v", content, bad.what, w)
			}
			if got, _ := bwfRead(t, floor); got != content {
				t.Errorf("floor %q was rewritten to %q after %s was refused", content, got, bad.what)
			}
		}
	}

	// An unreadable floor is not damage: h54 #4 settles damaged content, so a read that cannot complete still refuses.

	floor := filepath.Join(t.TempDir(), "build-warning-seq")
	if err := os.Mkdir(floor, 0o700); err != nil {
		t.Fatal(err)
	}
	if w, err := acceptBuildWarning(floor, env, bwNow); err == nil || w != nil {
		t.Errorf("an unreadable floor: accepted %+v", w)
	}
	if fi, err := os.Stat(floor); err != nil || !fi.IsDir() {
		t.Errorf("the unreadable floor was touched: %v, %v", fi, err)
	}
	if _, err := os.Lstat(floor + ".tmp"); !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("a temp file was left beside the unreadable floor: %v", err)
	}
}

// TestBuildWarningAcceptIntactFloorRefusesOlder is the control for TestBuildWarningAcceptDamagedFloor: only damage
// reads as absent, so an intact floor at seq 4 still refuses an object of seq 3 and is left as it is.
func TestBuildWarningAcceptIntactFloorRefusesOlder(t *testing.T) {
	k := bwUseKey(t)
	floor := filepath.Join(t.TempDir(), "build-warning-seq")
	intact := "4 " + strings.Repeat("ab", 32) + "\n"
	if err := os.WriteFile(floor, []byte(intact), 0o600); err != nil {
		t.Fatal(err)
	}
	if w, err := acceptBuildWarning(floor, bwfFresh(k, 3, "0.5.45"), bwNow); err == nil || w != nil {
		t.Errorf("an intact floor at seq 4 accepted an object of seq 3: %+v", w)
	}
	if got, _ := bwfRead(t, floor); got != intact {
		t.Errorf("the intact floor was rewritten to %q", got)
	}
}

func TestBuildWarningAcceptExpiredSame(t *testing.T) {
	k := bwUseKey(t)
	floor := filepath.Join(t.TempDir(), "build-warning-seq")
	env := bwfEnv(k, 3, bwNow-86400, bwNow+100, "0.5.45")
	if w, err := acceptBuildWarning(floor, env, bwNow); err != nil || w == nil {
		t.Fatalf("before expiry: %+v, %v", w, err)
	}
	stored, _ := bwfRead(t, floor)
	if w, err := acceptBuildWarning(floor, env, bwNow+200); err == nil || w != nil {
		t.Fatalf("the stored object past its expiry was accepted: %+v", w)
	}
	if got, _ := bwfRead(t, floor); got != stored {
		t.Fatalf("the floor changed: %q -> %q", stored, got)
	}
}

func TestBuildWarningAcceptWriteFails(t *testing.T) {
	k := bwUseKey(t)
	floor := filepath.Join(t.TempDir(), "missing", "build-warning-seq")
	w, err := acceptBuildWarning(floor, bwfFresh(k, 3, "0.5.45"), bwNow)
	if err != nil || w == nil || w.Seq != 3 {
		t.Fatalf("a failed floor write suppressed the warning: %+v, %v", w, err)
	}
	if _, err := os.Lstat(filepath.Dir(floor)); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("something was created at the floor's dir: %v", err)
	}
}
