package main

// GET-CATALOG's reply frame (NWP-20261119-31). handleGetCatalog is the storefront's only catalog read, and
// StoreService.lenReply reads it as the header line `OK <n>` followed by exactly n bytes. These tests drive the verb
// through handleLogin and compare the RAW reply, byte for byte: a header that counts another buffer, a byte after the
// body or the ERR-SIG and NONE arms swapped all fail here. test-catalog-reply.sh --mutate convicts each of them.

import (
	"bytes"
	"crypto/ed25519"
	"io"
	"net"
	"os"
	"strconv"
	"testing"
	"time"
)

// getCatalogReply sends `GET-CATALOG\n` to handleLogin over a net.Pipe and returns every byte of the reply up to EOF,
// not trimmed: the exact length of the frame is what these tests pin.
func getCatalogReply(t *testing.T) []byte {
	t.Helper()
	srv, cli := net.Pipe()
	defer cli.Close()
	go func() { cli.Write([]byte("GET-CATALOG\n")) }()
	type result struct {
		b   []byte
		err error
	}
	done := make(chan result, 1)
	go func() {
		b, err := io.ReadAll(cli)
		done <- result{b, err}
	}()
	handleLogin(srv, t.TempDir())
	select {
	case r := <-done:
		if r.err != nil {
			t.Fatalf("GET-CATALOG: reading the reply: %v", r.err)
		}
		return r.b
	case <-time.After(10 * time.Second):
		t.Fatal("GET-CATALOG: the reply did not end in 10 s")
		return nil
	}
}

// checkOKFrame requires the reply to be exactly `OK <len(body)>\n` + body, and the count in the header to equal the
// number of bytes after it (the check StoreService.lenReply depends on).
func checkOKFrame(t *testing.T, got, body []byte) {
	t.Helper()
	want := append([]byte("OK "+strconv.Itoa(len(body))+"\n"), body...)
	if !bytes.Equal(got, want) {
		t.Errorf("GET-CATALOG reply:\n got %q\nwant %q", got, want)
	}
	i := bytes.IndexByte(got, '\n')
	if i < 0 || !bytes.HasPrefix(got, []byte("OK ")) {
		t.Fatalf("GET-CATALOG reply has no `OK <n>` header line: %q", got)
	}
	n, err := strconv.Atoi(string(got[len("OK "):i]))
	if err != nil {
		t.Fatalf("GET-CATALOG header count is not a number: %q", got[:i])
	}
	if rest := got[i+1:]; n != len(rest) {
		t.Errorf("GET-CATALOG header counts %d bytes, but %d bytes follow it", n, len(rest))
	}
}

func checkExactReply(t *testing.T, got []byte, want string) {
	t.Helper()
	if string(got) != want {
		t.Errorf("GET-CATALOG reply: got %q, want exactly %q", got, want)
	}
}

// (a) A signed baked catalog and no /data copy: `OK <len>\n` and the baked bytes, with nothing after them.
func TestGetCatalogReply_signedBaked(t *testing.T) {
	priv, sys, _, restore := catalogRollbackFixture(t)
	defer restore()
	baked := catalogWithGenerated(100, "org.baked")
	writeSignedCatalog(t, priv, sys, baked)
	checkOKFrame(t, getCatalogReply(t), baked)
}

// (b) A newer signed /data override: the header counts the OVERRIDE's bytes, not the baked copy's, and the body is
// the override.
func TestGetCatalogReply_newerOverrideCounted(t *testing.T) {
	priv, sys, data, restore := catalogRollbackFixture(t)
	defer restore()
	baked := catalogWithGenerated(100, "org.baked")
	override := catalogWithGenerated(200, "org.override.longer")
	if len(override) == len(baked) {
		t.Fatalf("fixture: the override and the baked copy have the same length (%d), so a header that counts the wrong one would pass", len(baked))
	}
	writeSignedCatalog(t, priv, sys, baked)
	writeSignedCatalog(t, priv, data, override)
	checkOKFrame(t, getCatalogReply(t), override)
}

// (c) A baked catalog that is present but untrusted (its .sig missing or over other bytes), no override: ERR-SIG.
func TestGetCatalogReply_untrustedBaked(t *testing.T) {
	t.Run("missing sig", func(t *testing.T) {
		_, sys, _, restore := catalogRollbackFixture(t)
		defer restore()
		if err := os.WriteFile(sys, catalogWithGenerated(100, "org.baked"), 0o644); err != nil {
			t.Fatal(err)
		}
		checkExactReply(t, getCatalogReply(t), "ERR-SIG\n")
	})
	t.Run("wrong sig", func(t *testing.T) {
		priv, sys, _, restore := catalogRollbackFixture(t)
		defer restore()
		if err := os.WriteFile(sys, catalogWithGenerated(100, "org.baked"), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(sys+".sig", ed25519.Sign(priv, catalogWithGenerated(100, "org.other")), 0o644); err != nil {
			t.Fatal(err)
		}
		checkExactReply(t, getCatalogReply(t), "ERR-SIG\n")
	})
}

// (d) No baked catalog and no override: NONE.
func TestGetCatalogReply_noCatalog(t *testing.T) {
	_, _, _, restore := catalogRollbackFixture(t)
	defer restore()
	checkExactReply(t, getCatalogReply(t), "NONE\n")
}

// (e) No baked catalog and a /data override whose signature fails: NONE. This pins TODAY's behaviour: the ERR-SIG arm
// stats only the baked path. ERR-SIG ("present but untrusted") would be the more precise answer; changing it is a
// follow-up, not this slice.
func TestGetCatalogReply_noBakedBadOverride(t *testing.T) {
	priv, _, data, restore := catalogRollbackFixture(t)
	defer restore()
	if err := os.WriteFile(data, catalogWithGenerated(200, "org.override"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(data+".sig", ed25519.Sign(priv, catalogWithGenerated(200, "org.other")), 0o644); err != nil {
		t.Fatal(err)
	}
	checkExactReply(t, getCatalogReply(t), "NONE\n")
}
