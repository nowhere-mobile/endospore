package main

import (
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	bip39 "github.com/tyler-smith/go-bip39"
)

// NWP-20260905-06. profileFootprint is BOTH the lease set (payRent -- what the gateway GC spares) and, from
// this slice on, the copy set (the `footprint` verb -- what a store-to-store move has to carry). Two things
// it computed were wrong for both jobs, and each was silent:
//
//  1. #sys was never in the fan-out, though it is sealed on every logoff, prefetched on every login and
//     purged on delete like any other scope. It carries accounts_ce.db -- the Google account.
//  2. The RECOVERY REF was never emitted, though the push path writes it on every seal. On a hardened
//     (Endospore E.3b) vault the pass-only keyslot is DROPPED at create, so the 12-word code is the only
//     key that opens the profile off that handset -- and a copy without it is a profile nobody can open.
//
// TestFootprintCoversSysScope mirrors TestFootprintCoversAppsScope for #sys.
func TestFootprintCoversSysScope(t *testing.T) {
	base := newHTTPStore(t)
	name, pass := "sysscope", "footprint horse battery staple"
	createVault(base, name, pass)

	vsrc := t.TempDir()
	if err := os.WriteFile(filepath.Join(vsrc, "vault.txt"), []byte("small vault file"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, vsrc)

	// #sys scope: the account dbs, exactly what nowhere_roamd.sh's acct_seal stages before `push s3 name#sys`.
	ssrc := t.TempDir()
	accounts := prBytes(768 << 10)
	if err := os.WriteFile(filepath.Join(ssrc, "accounts_ce.db"), accounts, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(ssrc, "accounts_de.db"), prBytes(64<<10), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name+"#sys", pass, ssrc)

	fpBase, _ := profileFootprint(base, name, pass, nil)
	fpSys, _ := profileFootprint(base, name+"#sys", pass, nil)
	if len(fpBase) == 0 || len(fpSys) == 0 {
		t.Fatalf("empty footprint(s): base=%d sys=%d", len(fpBase), len(fpSys))
	}
	for ref := range fpSys {
		if _, ok := fpBase[ref]; !ok {
			t.Fatalf("#sys ref %q missing from the base footprint -- un-leased (GC reaps the Google account) "+
				"and absent from any copy driven by this walk", ref)
		}
	}
	// GET-USAGE undercounted the account dbs by exactly these bytes.
	var total int64
	for _, sz := range fpBase {
		total += sz
	}
	if total < int64(len(accounts)) {
		t.Fatalf("base footprint total %d does not cover the %d-byte accounts db -> GET-USAGE undercount", total, len(accounts))
	}
}

// TestFootprintCarriesRecoveryRef derives the recovery ref the way recoverVault does -- from the 12 words the
// user was shown -- and requires the footprint to carry it.
func TestFootprintCarriesRecoveryRef(t *testing.T) {
	base := newHTTPStore(t)
	name, pass := "recref", "footprint horse battery staple"
	mnemonic := createVault(base, name, pass)
	if mnemonic == "" {
		t.Fatal("createVault returned no recovery mnemonic")
	}
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "vault.txt"), []byte("small vault file"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src)

	entropy, err := bip39.EntropyFromMnemonic(mnemonic)
	if err != nil {
		t.Fatal(err)
	}
	want := "ref/" + recoveryRef(name, entropy)
	fp, _ := profileFootprint(base, name, pass, nil)
	if _, ok := fp[want]; !ok {
		t.Fatalf("recovery ref %q absent from the footprint (%d keys) -- the push path writes it on every "+
			"seal (pushProfile's RecoveryRef putRef, main.go), so the enumerator disagrees with the writer: un-leased against the "+
			"GC, and dropped by any copy driven by this walk", want, len(fp))
	}
}

// TestFootprintCopyRoundTripsRecovery is the feature, end to end: copy EXACTLY the object keys the footprint
// names into a second, empty store, then open the profile there with nothing but the 12-word code. That is
// the (i)/(iii) path in docs/data-portability.md section iii -- and the only check that fails for the reason
// a user would actually experience, rather than on a key being absent from a map.
func TestFootprintCopyRoundTripsRecovery(t *testing.T) {
	src := newHTTPStore(t)
	dst := newHTTPStore(t)
	name, pass := "movestore", "footprint horse battery staple"
	mnemonic := createVault(src, name, pass)

	work := t.TempDir()
	if err := os.WriteFile(filepath.Join(work, "vault.txt"), []byte("a file worth moving"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(src, name, pass, work)

	fp, _ := profileFootprint(src, name, pass, nil)
	if len(fp) == 0 {
		t.Fatal("empty footprint -- nothing to copy")
	}
	for key := range fp {
		copyObject(t, src, dst, key)
	}

	// The destination now holds exactly what the footprint named and not one byte more. If the recovery ref
	// was not among those keys, this is where it shows: recoverVault cannot resolve the head.
	if err := recoverVault(dst, name, mnemonic, "a brand new passphrase"); err != nil {
		t.Fatalf("recovery FAILED at the destination after copying every object the footprint named "+
			"(%d keys): %v -- a profile moved by this walk cannot be opened by its owner", len(fp), err)
	}
	key, _, ok := resolveKey(dst, name, "a brand new passphrase")
	if !ok || key == nil {
		t.Fatal("recovered profile does not resolve at the destination")
	}
}

// copyObject moves one footprint object key ("blob/<hash>" or "ref/<key>") between two test stores, the way
// rclone or a /caps read loop would -- ciphertext only, no key material, no interpretation of the bytes.
func copyObject(t *testing.T, src, dst, key string) {
	t.Helper()
	resp, err := http.Get(src + "/" + key)
	if err != nil {
		t.Fatalf("GET %s: %v", key, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET %s -> HTTP %d (the footprint named an object the store does not have)", key, resp.StatusCode)
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	switch {
	case strings.HasPrefix(key, "blob/"):
		// Content-addressed: POST /blob re-derives the same hash, so the key is preserved by construction.
		r, err := http.Post(dst+"/blob", "application/octet-stream", strings.NewReader(string(body)))
		if err != nil {
			t.Fatalf("POST blob for %s: %v", key, err)
		}
		got, _ := io.ReadAll(r.Body)
		r.Body.Close()
		if "blob/"+strings.TrimSpace(string(got)) != key {
			t.Fatalf("copied blob landed at %q, not %q -- content addressing broken", "blob/"+strings.TrimSpace(string(got)), key)
		}
	case strings.HasPrefix(key, "ref/"):
		req, err := http.NewRequest("PUT", dst+"/"+key, strings.NewReader(string(body)))
		if err != nil {
			t.Fatal(err)
		}
		r, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("PUT %s: %v", key, err)
		}
		r.Body.Close()
	default:
		t.Fatalf("footprint named %q, which is neither a blob nor a ref -- a copy recipe cannot place it", key)
	}
}
