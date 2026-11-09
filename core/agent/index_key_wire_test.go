package main

// index_key_wire_test.go -- the index-key object wired into index.go and refreshOtaCache (NWP-20261129-18, decision #8
// of 2026-11-02 in docs/product-decisions.md). The selected key checks the /data refresh and each fetched index; the
// baked /system copy keeps the baked key; the parsed index follows the held object; the fetch runs after each completed
// OTA check.

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"os"
	"strings"
	"testing"
	"time"
)

const (
	ikwBakedGen = int64(100)
	ikwDataGen  = int64(200)
)

// ikwKeys is what a test signs with: the baked index key A, a new index key B, and the test release key.
type ikwKeys struct {
	a, b, release ed25519.PrivateKey
	aPub, bPub    string
}

// ikwSetup points every index and index-key path into a temp dir, bakes key A, and writes the baked copy signed by A.
func ikwSetup(t *testing.T) ikwKeys {
	t.Helper()
	a, _, restore := withIndexKey(t)
	t.Cleanup(restore)
	release := iktUseKey(t)
	bPub, b, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("keygen: %v", err)
	}
	writeSignedIndex(t, indexSystemPath, a, ikwCatalog(ikwBakedGen))
	return ikwKeys{a: a, b: b, release: release, aPub: indexPubKey, bPub: base64.StdEncoding.EncodeToString(bPub)}
}

func ikwCatalog(gen int64) catalog {
	return catalog{Schema: 1, Generated: gen, Entries: []catalogEntry{idxEntry("a.b", "A", gen)}}
}

// ikwData writes the /data copy at ikwDataGen, signed by priv.
func ikwData(t *testing.T, priv ed25519.PrivateKey) {
	t.Helper()
	writeSignedIndex(t, indexDataPath, priv, ikwCatalog(ikwDataGen))
}

// ikwAccept holds env through acceptIndexKey at the test paths.
func ikwAccept(t *testing.T, env []byte) {
	t.Helper()
	if _, err := acceptIndexKey(indexKeySeqPath, indexKeyHeldPath, env, iktNow); err != nil {
		t.Fatalf("acceptIndexKey: %v", err)
	}
}

// ikwServed is the generation loadIndexBytes serves.
func ikwServed() int64 { return indexGeneratedOf(loadIndexBytes()) }

// ikwNoDataCopy fails when refreshIndex left any part of the /data copy behind.
func ikwNoDataCopy(t *testing.T) {
	t.Helper()
	for _, p := range []string{indexDataPath, indexDataPath + ".sig"} {
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Fatalf("%s exists (stat err %v)", p, err)
		}
	}
}

// W1: nothing held, so the baked key checks /data as it always did.
func TestIndexKeyWireNothingHeld(t *testing.T) {
	k := ikwSetup(t)
	ikwData(t, k.a)
	if got := ikwServed(); got != ikwDataGen {
		t.Fatalf("served generation %d, want the /data copy's %d", got, ikwDataGen)
	}
}

// W2: a held rollover moves the /data check to B, and only B. The baked copy still serves under A.
func TestIndexKeyWireRollover(t *testing.T) {
	k := ikwSetup(t)
	ikwAccept(t, ikfRollover(k.release, 1, k.bPub))
	ikwData(t, k.b)
	if got := ikwServed(); got != ikwDataGen {
		t.Errorf("a /data copy signed by the new key: served generation %d, want %d", got, ikwDataGen)
	}
	ikwData(t, k.a)
	if got := ikwServed(); got != ikwBakedGen {
		t.Errorf("a /data copy signed by the old key: served generation %d, want the baked %d", got, ikwBakedGen)
	}
}

// W3: the baked key revoked with no new key: no /data copy serves, the baked copy does, and a refresh asks nothing of
// the network and answers ERR, not NONE.
func TestIndexKeyWireRevoked(t *testing.T) {
	k := ikwSetup(t)
	ikwAccept(t, ikfRevoke(k.release, 1, k.aPub))
	ikwData(t, k.a)
	if got := ikwServed(); got != ikwBakedGen {
		t.Errorf("served generation %d, want the baked %d", got, ikwBakedGen)
	}
	srv := newCondIndexServer(t, k.a, time.Now().Unix()-60, time.Now().Add(-time.Minute))
	err := refreshIndex()
	if err == nil {
		t.Error("refreshIndex under a revoked key returned nil")
	} else if errors.Is(err, errRefreshOff) {
		t.Errorf("refreshIndex under a revoked key is errRefreshOff (REFRESH-INDEX would answer NONE): %v", err)
	}
	if idx, sig := srv.counts(); idx != 0 || sig != 0 {
		t.Errorf("refreshIndex under a revoked key made %d index and %d .sig requests, want none", idx, sig)
	}
	if got := refreshIndexReply(t); got != "ERR" {
		t.Errorf("REFRESH-INDEX under a revoked key answered %q, want ERR", got)
	}
}

// W4: under a rollover to B a fetched index signed by A is refused and writes nothing; one signed by B is installed.
func TestIndexKeyWireRefreshFollowsKey(t *testing.T) {
	k := ikwSetup(t)
	ikwAccept(t, ikfRollover(k.release, 1, k.bPub))
	now := time.Now()
	srv := newCondIndexServer(t, k.a, now.Unix()-120, now.Add(-2*time.Hour))
	if err := refreshIndex(); err == nil {
		t.Error("an index signed by the old key was accepted")
	}
	ikwNoDataCopy(t)

	gen := now.Unix() - 60
	srv.set(k.b, gen, now.Add(-time.Hour))
	if err := refreshIndex(); err != nil {
		t.Fatalf("an index signed by the new key: %v", err)
	}
	if got := ikwServed(); got != gen {
		t.Errorf("served generation %d, want the installed %d", got, gen)
	}
}

// W5: an If-Modified-Since is sent exactly when /data is the copy served, or a 304 would pin a copy not in use. Each
// state names its answer: the two readers agreeing with each other would pass with both on the wrong key.
func TestIndexKeyWireMtimeFollowsServedCopy(t *testing.T) {
	for _, tc := range []struct {
		name  string
		setup func(t *testing.T, k ikwKeys)
		want  bool // /data is served, and its mtime is asked about
	}{
		{"nothing held", func(t *testing.T, k ikwKeys) { ikwData(t, k.a) }, true},
		{"rollover, new key", func(t *testing.T, k ikwKeys) {
			ikwAccept(t, ikfRollover(k.release, 1, k.bPub))
			ikwData(t, k.b)
		}, true},
		{"rollover, old key", func(t *testing.T, k ikwKeys) {
			ikwAccept(t, ikfRollover(k.release, 1, k.bPub))
			ikwData(t, k.a)
		}, false},
		{"revoked", func(t *testing.T, k ikwKeys) {
			ikwAccept(t, ikfRevoke(k.release, 1, k.aPub))
			ikwData(t, k.a)
		}, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			k := ikwSetup(t)
			tc.setup(t, k)
			if served := ikwServed() == ikwDataGen; served != tc.want {
				t.Errorf("/data served = %v, want %v", served, tc.want)
			}
			if has := !servedIndexDataMtime().IsZero(); has != tc.want {
				t.Errorf("a non-zero /data mtime = %v, want %v", has, tc.want)
			}
		})
	}
}

// W6: a rollover that arrives after a parse drops that parse: the next read does not serve the old key's copy.
func TestIndexKeyWireHeldObjectDropsParse(t *testing.T) {
	k := ikwSetup(t)
	ikwData(t, k.a)
	if got := cachedGenerated(); got != ikwDataGen {
		t.Fatalf("before the rollover: generation %d, want %d", got, ikwDataGen)
	}
	ikwAccept(t, ikfRollover(k.release, 1, k.bPub))
	if got := cachedGenerated(); got != ikwBakedGen {
		t.Errorf("after the rollover: generation %d, want the baked %d (a stale parse)", got, ikwBakedGen)
	}
}

// W7: with no key baked the baked copy is trusted unsigned, and a held rollover must not change that: the selected key
// reaches neither the unsigned branch nor a /data copy.
func TestIndexKeyWireNoBakedKeyStaysUnsigned(t *testing.T) {
	k := ikwSetup(t)
	ikwAccept(t, ikfRollover(k.release, 1, k.bPub))
	ikwData(t, k.b)
	if err := os.Remove(indexSystemPath + ".sig"); err != nil {
		t.Fatal(err)
	}
	indexPubKey = "" // withIndexKey's restore puts the old value back
	if got := ikwServed(); got != ikwBakedGen {
		t.Errorf("served generation %d, want the baked %d, unsigned", got, ikwBakedGen)
	}
}

// W8: refreshOtaCache fetches the object after the unreachable-store return, beside the build warning, and whatever the
// offer. Its body is read as TestRefreshOtaCacheRefreshesBuildWarning reads it.
func TestIndexKeyWireFetchIsCalled(t *testing.T) {
	src, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	main := string(src)
	i := strings.Index(main, "func refreshOtaCache() {")
	if i < 0 {
		t.Fatal("refreshOtaCache is gone")
	}
	body := main[i:]
	body = body[:strings.Index(body, "\n}\n")]
	warning := "\n\trefreshBuildWarning("
	call := "\tif strings.TrimSpace(indexPubKey) != \"\" {\n\t\tfetchIndexKey(\"s3\", time.Now().Unix())\n\t}\n"
	gate := "if latest != \"\" && avail {"
	if c := strings.Count(body, "fetchIndexKey(\"s3\""); c != 1 {
		t.Fatalf("refreshOtaCache holds fetchIndexKey(\"s3\" %d times, want once", c)
	}
	for _, s := range []string{warning, call, gate} {
		if c := strings.Count(body, s); c != 1 {
			t.Fatalf("refreshOtaCache holds %q %d times, want once", strings.TrimSpace(s), c)
		}
	}
	if strings.Index(body, call) < strings.Index(body, warning) {
		t.Error("refreshOtaCache fetches the index key before the build-warning refresh")
	}
	if strings.Index(body, call) > strings.Index(body, gate) {
		t.Error("refreshOtaCache fetches the index key only when an update is offered")
	}
}
