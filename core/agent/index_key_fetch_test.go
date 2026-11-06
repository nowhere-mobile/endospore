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
	"strconv"
	"strings"
	"testing"
)

// ikfEnv is a signed index-key envelope over the body m.
func ikfEnv(k ed25519.PrivateKey, m map[string]any) []byte {
	body := iktBody(m)
	return indexKeyEnvelope(body, iktSign(k, indexKeyDomain, body))
}

// ikfRollover is a signed rollover to key at seq.
func ikfRollover(k ed25519.PrivateKey, seq int64, key string) []byte {
	return ikfEnv(k, map[string]any{"schema": 1, "seq": seq, "issued": iktNow - 3600, "key": key})
}

// ikfRevoke is a signed revocation of the keys revoked at seq, naming no new key.
func ikfRevoke(k ed25519.PrivateKey, seq int64, revoked ...string) []byte {
	return ikfEnv(k, map[string]any{"schema": 1, "seq": seq, "issued": iktNow - 3600, "revoked": revoked})
}

func ikfHash(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

// ikfPaths is the floor and held paths in the test's own temp dir; it also points indexKeySeqPath and
// indexKeyHeldPath at them.
func ikfPaths(t *testing.T) (seqPath, heldPath string) {
	t.Helper()
	d := t.TempDir()
	seqPath, heldPath = filepath.Join(d, "index-key-seq"), filepath.Join(d, "index-key")
	oldSeq, oldHeld := indexKeySeqPath, indexKeyHeldPath
	indexKeySeqPath, indexKeyHeldPath = seqPath, heldPath
	t.Cleanup(func() { indexKeySeqPath, indexKeyHeldPath = oldSeq, oldHeld })
	return seqPath, heldPath
}

// ikfCountSync wraps indexKeyFileSync and counts its calls: one per file written.
func ikfCountSync(t *testing.T) *int {
	t.Helper()
	n := new(int)
	old := indexKeyFileSync
	indexKeyFileSync = func(f *os.File) error { *n++; return old(f) }
	t.Cleanup(func() { indexKeyFileSync = old })
	return n
}

// ikfRead returns a file's bytes, or ok=false when it is absent.
func ikfRead(t *testing.T, path string) (string, bool) {
	t.Helper()
	b, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return "", false
	}
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return string(b), true
}

// ikfWrite writes a file the test sets up, 0600.
func ikfWrite(t *testing.T, path, data string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(data), 0o600); err != nil {
		t.Fatal(err)
	}
}

// ikfHold sets up the durable pair as an accept would leave it: env held and the floor at seq with env's hash.
func ikfHold(t *testing.T, seqPath, heldPath string, seq int64, env []byte) {
	t.Helper()
	ikfWrite(t, heldPath, string(env))
	ikfWrite(t, seqPath, ikfFloor(seq, env))
}

// ikfFloor is the floor line naming seq and env's hash.
func ikfFloor(seq int64, env []byte) string {
	return strconv.FormatInt(seq, 10) + " " + ikfHash(env) + "\n"
}

// ikfStore is an http store holding refs (name -> hash) and blobs (hash -> bytes), as bwfStore.
func ikfStore(t *testing.T, refs map[string]string, blobs map[string][]byte) string {
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

// ikfUseBaked swaps indexPubKey for the seed-7 test index key and restores it on cleanup.
func ikfUseBaked(t *testing.T) string {
	t.Helper()
	old := indexPubKey
	indexPubKey = iktIndexKey(7)
	t.Cleanup(func() { indexPubKey = old })
	return indexPubKey
}

// ikfNoFiles fails when any of the durable files, or their temps, exists.
func ikfNoFiles(t *testing.T, seqPath, heldPath string) {
	t.Helper()
	for _, p := range []string{seqPath, heldPath, seqPath + ".tmp", heldPath + ".tmp"} {
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Fatalf("%s exists (stat err %v)", p, err)
		}
	}
}

func TestIndexKeyFetchAbsentIsNone(t *testing.T) {
	iktUseKey(t)
	seqPath, heldPath := ikfPaths(t)
	url := ikfStore(t, map[string]string{}, map[string][]byte{})
	if obj, err := fetchIndexKey(url, iktNow); obj != nil || err != nil {
		t.Fatalf("nothing published must be (nil, nil): %+v, %v", obj, err)
	}
	ikfNoFiles(t, seqPath, heldPath)
}

func TestIndexKeyFetchRefusesBadBlob(t *testing.T) {
	k := iktUseKey(t)
	seqPath, heldPath := ikfPaths(t)
	good := ikfRollover(k, 1, iktIndexKey(1))
	h := ikfHash(good)
	renamed := "00" + h[2:]
	big := append([]byte(indexKeyMagic+"\n"), bytes.Repeat([]byte{'x'}, indexKeyEnvMax+1-len(indexKeyMagic)-1)...)
	hb := ikfHash(big)
	missing := ikfHash([]byte("never stored"))

	cases := []struct {
		name  string
		ref   string
		blobs map[string][]byte
		want  error
	}{
		{"renamed", renamed, map[string][]byte{renamed: good}, errIndexKeyHash},
		{"over the cap", hb, map[string][]byte{hb: big}, errIndexKeyTooBig},
		{"missing", missing, map[string][]byte{}, errIndexKeyMissing},
	}
	for _, c := range cases {
		url := ikfStore(t, map[string]string{indexKeyRefName: c.ref}, c.blobs)
		obj, err := fetchIndexKey(url, iktNow)
		if err == nil || obj != nil {
			t.Errorf("%s: believed: %+v, %v", c.name, obj, err)
			continue
		}
		if !errors.Is(err, c.want) {
			t.Errorf("%s: error %v, want %v", c.name, err, c.want)
		}
	}
	ikfNoFiles(t, seqPath, heldPath)
}

// TestIndexKeyFetchStorePanicIsFixed: a store read that fails makes checkRead (main.go) panic with storeReadErr.
// The fetch must turn that into the fixed errIndexKeyStore: the transport error's text holds the store URL.
func TestIndexKeyFetchStorePanicIsFixed(t *testing.T) {
	seqPath, heldPath := ikfPaths(t)
	srv := httptest.NewServer(http.NotFoundHandler())
	base := srv.URL
	srv.Close() // closed BEFORE the call: getRefBytes's http.Get fails, and checkRead panics
	env, err := fetchIndexKeyEnvelope(base)
	if env != nil {
		t.Fatalf("envelope %q, want nil", env)
	}
	if err != errIndexKeyStore || !errors.Is(err, errIndexKeyStore) {
		t.Fatalf("fetchIndexKeyEnvelope err = %v, want errIndexKeyStore", err)
	}
	if strings.Contains(err.Error(), base) || strings.Contains(err.Error(), "127.0.0.1") {
		t.Fatalf("error text %q holds the store URL", err)
	}
	obj, err := fetchIndexKey(base, iktNow)
	if obj != nil {
		t.Fatalf("object %+v, want nil", obj)
	}
	if err != errIndexKeyStore || !errors.Is(err, errIndexKeyStore) {
		t.Fatalf("fetchIndexKey err = %v, want errIndexKeyStore", err)
	}
	if strings.Contains(err.Error(), base) {
		t.Fatalf("error text %q holds the store URL", err)
	}
	for _, p := range []string{seqPath, heldPath, seqPath + ".tmp", heldPath + ".tmp"} {
		if _, serr := os.Stat(p); !os.IsNotExist(serr) {
			t.Fatalf("%s exists after a store failure (stat err %v)", p, serr)
		}
	}
}

// TestIndexKeyFetchAccepts is the control for the refusals above: a good blob under its true name is accepted.
func TestIndexKeyFetchAccepts(t *testing.T) {
	k := iktUseKey(t)
	seqPath, heldPath := ikfPaths(t)
	good := ikfRollover(k, 1, iktIndexKey(1))
	h := ikfHash(good)
	url := ikfStore(t, map[string]string{indexKeyRefName: h}, map[string][]byte{h: good})
	obj, err := fetchIndexKey(url, iktNow)
	if err != nil || obj == nil || obj.Seq != 1 || obj.Key != iktIndexKey(1) {
		t.Fatalf("a good blob was refused: %+v, %v", obj, err)
	}
	if got, _ := ikfRead(t, seqPath); got != "1 "+h+"\n" {
		t.Fatalf("floor %q, want seq 1 and the envelope's hash", got)
	}
	if got, _ := ikfRead(t, heldPath); got != string(good) {
		t.Fatalf("held %q, want the envelope verbatim", got)
	}
}

func TestIndexKeyAcceptFresh(t *testing.T) {
	k := iktUseKey(t)
	seqPath, heldPath := ikfPaths(t)
	env := ikfRollover(k, 1, iktIndexKey(1))
	obj, err := acceptIndexKey(seqPath, heldPath, env, iktNow)
	if err != nil || obj == nil || obj.Seq != 1 {
		t.Fatalf("a fresh seq-1 object was refused: %+v, %v", obj, err)
	}
	if got, _ := ikfRead(t, seqPath); got != "1 "+ikfHash(env)+"\n" {
		t.Fatalf("floor %q", got)
	}
	if got, _ := ikfRead(t, heldPath); got != string(env) {
		t.Fatalf("held %q, want the envelope verbatim", got)
	}
	for _, p := range []string{seqPath, heldPath} {
		if fi, err := os.Stat(p); err != nil || fi.Mode().Perm() != 0o600 {
			t.Fatalf("%s: mode %v, err %v, want 0600", p, fi.Mode().Perm(), err)
		}
	}
}

func TestIndexKeyAcceptSameObjectWritesNothing(t *testing.T) {
	k := iktUseKey(t)
	seqPath, heldPath := ikfPaths(t)
	env := ikfRollover(k, 3, iktIndexKey(1))
	ikfHold(t, seqPath, heldPath, 3, env)
	writes := ikfCountSync(t)
	obj, err := acceptIndexKey(seqPath, heldPath, env, iktNow)
	if err != nil || obj == nil || obj.Seq != 3 || obj.Key != iktIndexKey(1) {
		t.Fatalf("the floor's own object was refused: %+v, %v", obj, err)
	}
	if *writes != 0 {
		t.Fatalf("the same object wrote %d file(s), want none", *writes)
	}
	if got, _ := ikfRead(t, seqPath); got != ikfFloor(3, env) {
		t.Fatalf("floor rewritten: %q", got)
	}
}

func TestIndexKeyAcceptRefusesOlder(t *testing.T) {
	k := iktUseKey(t)
	seqPath, heldPath := ikfPaths(t)
	cur := ikfRollover(k, 3, iktIndexKey(1))
	ikfHold(t, seqPath, heldPath, 3, cur)
	writes := ikfCountSync(t)
	obj, err := acceptIndexKey(seqPath, heldPath, ikfRollover(k, 2, iktIndexKey(3)), iktNow)
	if err == nil || obj != nil {
		t.Fatalf("an older object was accepted: %+v", obj)
	}
	if *writes != 0 {
		t.Fatalf("a refused object wrote %d file(s)", *writes)
	}
	if got, _ := ikfRead(t, heldPath); got != string(cur) {
		t.Fatal("a refused object replaced the held copy")
	}
}

func TestIndexKeyAcceptRefusesOtherAtSameSeq(t *testing.T) {
	k := iktUseKey(t)
	seqPath, heldPath := ikfPaths(t)
	a := ikfRollover(k, 3, iktIndexKey(1))
	ikfHold(t, seqPath, heldPath, 3, a)
	obj, err := acceptIndexKey(seqPath, heldPath, ikfRollover(k, 3, iktIndexKey(3)), iktNow)
	if err == nil || obj != nil {
		t.Fatalf("a different object at the floor's seq was accepted: %+v", obj)
	}
	if got, _ := ikfRead(t, seqPath); got != ikfFloor(3, a) {
		t.Fatalf("floor changed: %q", got)
	}
	if got, _ := ikfRead(t, heldPath); got != string(a) {
		t.Fatal("held copy changed")
	}
}

func TestIndexKeyAcceptHigherReplaces(t *testing.T) {
	k := iktUseKey(t)
	seqPath, heldPath := ikfPaths(t)
	ikfHold(t, seqPath, heldPath, 3, ikfRollover(k, 3, iktIndexKey(1)))
	next := ikfRollover(k, 4, iktIndexKey(3))
	obj, err := acceptIndexKey(seqPath, heldPath, next, iktNow)
	if err != nil || obj == nil || obj.Seq != 4 || obj.Key != iktIndexKey(3) {
		t.Fatalf("a higher object was refused: %+v, %v", obj, err)
	}
	if got, _ := ikfRead(t, seqPath); got != ikfFloor(4, next) {
		t.Fatalf("floor %q, want seq 4", got)
	}
	if got, _ := ikfRead(t, heldPath); got != string(next) {
		t.Fatal("held copy not replaced")
	}
}

func TestIndexKeyAcceptDamagedFloorRefuses(t *testing.T) {
	k := iktUseKey(t)
	env := ikfRollover(k, 1, iktIndexKey(1))
	for name, floor := range map[string]string{
		"garbage":    "garbage\n",
		"seq 0":      "0 " + ikfHash(env) + "\n",
		"two lines":  "1 " + ikfHash(env) + "\n1 " + ikfHash(env) + "\n",
		"no newline": "1 " + ikfHash(env),
		"empty":      "",
	} {
		t.Run(name, func(t *testing.T) {
			seqPath, heldPath := ikfPaths(t)
			ikfWrite(t, seqPath, floor)
			obj, err := acceptIndexKey(seqPath, heldPath, env, iktNow)
			if obj != nil || !errors.Is(err, errIndexKeyFloorDamaged) {
				t.Fatalf("a damaged floor let a valid object in: %+v, %v", obj, err)
			}
			if got, _ := ikfRead(t, seqPath); got != floor {
				t.Fatalf("the damaged floor was rewritten: %q", got)
			}
			if _, ok := ikfRead(t, heldPath); ok {
				t.Fatal("a held copy was written past a damaged floor")
			}
		})
	}
}

// TestIndexKeyAcceptHeldWriteFailure: the held copy is written FIRST, and a failed write is an error, so the floor is
// left as it was and the object is not used.
func TestIndexKeyAcceptHeldWriteFailure(t *testing.T) {
	k := iktUseKey(t)
	seqPath, heldPath := ikfPaths(t)
	cur := ikfRollover(k, 3, iktIndexKey(1))
	ikfHold(t, seqPath, heldPath, 3, cur)
	badHeld := filepath.Join(filepath.Dir(heldPath), "missing-dir", "index-key")
	obj, err := acceptIndexKey(seqPath, badHeld, ikfRollover(k, 4, iktIndexKey(3)), iktNow)
	if err == nil || obj != nil {
		t.Fatalf("an object whose held copy was not kept was used: %+v, %v", obj, err)
	}
	if got, _ := ikfRead(t, seqPath); got != ikfFloor(3, cur) {
		t.Fatalf("the floor moved past a held copy that was not kept: %q", got)
	}
}

// TestIndexKeyAcceptFloorWriteFailure: a failed floor write is an error too.
func TestIndexKeyAcceptFloorWriteFailure(t *testing.T) {
	k := iktUseKey(t)
	seqPath, heldPath := ikfPaths(t)
	n := 0
	old := indexKeyFileSync
	indexKeyFileSync = func(f *os.File) error {
		n++
		if n == 2 {
			return errors.New("sync failed")
		}
		return old(f)
	}
	t.Cleanup(func() { indexKeyFileSync = old })
	obj, err := acceptIndexKey(seqPath, heldPath, ikfRollover(k, 1, iktIndexKey(1)), iktNow)
	if err == nil || obj != nil {
		t.Fatalf("an object whose floor was not kept was used: %+v, %v", obj, err)
	}
	if _, ok := ikfRead(t, seqPath); ok {
		t.Fatal("a floor exists after its write failed")
	}
	if _, ok := ikfRead(t, seqPath+".tmp"); ok {
		t.Fatal("the floor's temp file was left behind")
	}
}

// TestIndexKeyAcceptFloorSeqMismatch: the floor names the envelope's hash but another seq.
func TestIndexKeyAcceptFloorSeqMismatch(t *testing.T) {
	k := iktUseKey(t)
	seqPath, heldPath := ikfPaths(t)
	env := ikfRollover(k, 3, iktIndexKey(1))
	ikfWrite(t, heldPath, string(env))
	ikfWrite(t, seqPath, ikfFloor(2, env))
	if obj, err := acceptIndexKey(seqPath, heldPath, env, iktNow); obj != nil || !errors.Is(err, errIndexKeyFloorSeq) {
		t.Fatalf("an object whose seq is not the floor's was accepted: %+v, %v", obj, err)
	}
}

func TestCurrentIndexKeyNothingHeld(t *testing.T) {
	iktUseKey(t)
	baked := ikfUseBaked(t)
	ikfPaths(t)
	if got := currentIndexKey(iktNow); got != baked {
		t.Fatalf("currentIndexKey = %q, want the baked key", got)
	}
}

func TestCurrentIndexKeyRollover(t *testing.T) {
	k := iktUseKey(t)
	ikfUseBaked(t)
	seqPath, heldPath := ikfPaths(t)
	if _, err := acceptIndexKey(seqPath, heldPath, ikfRollover(k, 1, iktIndexKey(1)), iktNow); err != nil {
		t.Fatal(err)
	}
	if got := currentIndexKey(iktNow); got != iktIndexKey(1) {
		t.Fatalf("currentIndexKey = %q, want the rollover's key", got)
	}
}

func TestCurrentIndexKeyRevokesBaked(t *testing.T) {
	k := iktUseKey(t)
	baked := ikfUseBaked(t)
	seqPath, heldPath := ikfPaths(t)
	if _, err := acceptIndexKey(seqPath, heldPath, ikfRevoke(k, 1, baked), iktNow); err != nil {
		t.Fatal(err)
	}
	if got := currentIndexKey(iktNow); got != "" {
		t.Fatalf("currentIndexKey = %q, want none: the baked key is revoked", got)
	}
}

func TestCurrentIndexKeyRevokesOther(t *testing.T) {
	k := iktUseKey(t)
	baked := ikfUseBaked(t)
	seqPath, heldPath := ikfPaths(t)
	if _, err := acceptIndexKey(seqPath, heldPath, ikfRevoke(k, 1, iktIndexKey(2)), iktNow); err != nil {
		t.Fatal(err)
	}
	if got := currentIndexKey(iktNow); got != baked {
		t.Fatalf("currentIndexKey = %q, want the baked key", got)
	}
}

func TestCurrentIndexKeyInconsistent(t *testing.T) {
	k := iktUseKey(t)
	ikfUseBaked(t)
	env := ikfRollover(k, 3, iktIndexKey(1))
	other := ikfRollover(k, 3, iktIndexKey(3)) // a valid object of its own, at the same seq
	cases := map[string]func(seqPath, heldPath string){
		"floor without held": func(s, h string) { ikfWrite(t, s, ikfFloor(3, env)) },
		"held without floor": func(s, h string) { ikfWrite(t, h, string(env)) },
		"hash mismatch": func(s, h string) {
			ikfWrite(t, s, ikfFloor(3, env))
			ikfWrite(t, h, string(other))
		},
		"damaged floor": func(s, h string) {
			ikfWrite(t, s, "garbage\n")
			ikfWrite(t, h, string(env))
		},
		"held no longer verifies": func(s, h string) {
			ikfWrite(t, s, ikfFloor(4, env))
			ikfWrite(t, h, string(env))
		},
	}
	for name, setup := range cases {
		t.Run(name, func(t *testing.T) {
			seqPath, heldPath := ikfPaths(t)
			setup(seqPath, heldPath)
			if got := currentIndexKey(iktNow); got != "" {
				t.Fatalf("currentIndexKey = %q, want none", got)
			}
		})
	}
}
