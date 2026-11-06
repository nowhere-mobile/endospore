package main

import (
	"bufio"
	"net"
	"strings"
	"testing"
)

// GET-STORE's last line says whether the device saves to the managed store (NWP-20261113-21). Backlog row "Store
// settings on a managed (gateway) device says "no store yet — set one up" under its own "Managed store — connected"
// banner": the chooser chose its message from keyset= alone, and a managed device has no keys, so it read as having no
// store. managed=yes iff capMode(); the first five lines stay as they were, and no line carries a key or the gateway URL.

// getStoreReply drives handleGetStore over an in-memory pipe and returns every reply line.
func getStoreReply(t *testing.T) []string {
	t.Helper()
	server, client := net.Pipe()
	go func() { handleGetStore(server); server.Close() }()
	var lines []string
	sc := bufio.NewScanner(client)
	for sc.Scan() {
		lines = append(lines, sc.Text())
	}
	if err := sc.Err(); err != nil {
		t.Fatalf("read GET-STORE reply: %v", err)
	}
	if len(lines) == 0 {
		t.Fatal("GET-STORE replied nothing")
	}
	return lines
}

// assertGetStoreCarriesNone fails when any reply line's value holds one of the secrets.
func assertGetStoreCarriesNone(t *testing.T, lines []string, secrets ...string) {
	t.Helper()
	for _, l := range lines {
		_, v, _ := strings.Cut(l, "=")
		for _, s := range secrets {
			if s != "" && strings.Contains(v, s) {
				t.Errorf("GET-STORE line %q carries %q", l, s)
			}
		}
	}
}

// setStoreEnv sets every variable handleGetStore, capMode and storeConfigured read.
func setStoreEnv(t *testing.T, gw, ep, rg, bk, ak, sk string) {
	t.Helper()
	t.Setenv("GATEWAY_URL", gw)
	t.Setenv("S3_ENDPOINT", ep)
	t.Setenv("S3_REGION", rg)
	t.Setenv("S3_BUCKET", bk)
	t.Setenv("S3_ACCESS_KEY", ak)
	t.Setenv("S3_SECRET_KEY", sk)
}

func wantGetStore(t *testing.T, lines []string, want ...string) {
	t.Helper()
	if strings.Join(lines, "\n") != strings.Join(want, "\n") {
		t.Fatalf("GET-STORE reply:\n%s\nwant:\n%s", strings.Join(lines, "\n"), strings.Join(want, "\n"))
	}
}

// TestGetStoreS3ConfigIsNotManaged: a self-hosted store with keys answers the five lines it always did, in order,
// then managed=no, and never the access or secret key.
func TestGetStoreS3ConfigIsNotManaged(t *testing.T) {
	setStoreEnv(t, "", "https://s3.example.io", "auto", "bkt", "AKIDTESTGETSTORE", "SECRETTESTGETSTORE")
	lines := getStoreReply(t)
	wantGetStore(t, lines, "configured=yes", "endpoint=https://s3.example.io", "region=auto", "bucket=bkt",
		"keyset=yes", "managed=no")
	assertGetStoreCarriesNone(t, lines, "AKIDTESTGETSTORE", "SECRETTESTGETSTORE")
}

// TestGetStoreGatewayWithKeysIsNotManaged: a GATEWAY_URL beside S3 keys is not cap mode, so not managed, and the
// gateway URL is not printed.
func TestGetStoreGatewayWithKeysIsNotManaged(t *testing.T) {
	setStoreEnv(t, "https://gw.example/tokGW1", "https://s3.example.io", "auto", "bkt", "AKIDTESTGETSTORE", "SECRETTESTGETSTORE")
	lines := getStoreReply(t)
	if lines[len(lines)-1] != "managed=no" {
		t.Fatalf("GET-STORE with S3 keys must end with managed=no:\n%s", strings.Join(lines, "\n"))
	}
	assertGetStoreCarriesNone(t, lines, "AKIDTESTGETSTORE", "SECRETTESTGETSTORE", "https://gw.example/tokGW1", "tokGW1")
}

// TestGetStoreNoStore: nothing configured answers configured=no, keyset=no, managed=no.
func TestGetStoreNoStore(t *testing.T) {
	setStoreEnv(t, "", "", "", "", "", "")
	wantGetStore(t, getStoreReply(t), "configured=no", "endpoint=", "region=", "bucket=", "keyset=no", "managed=no")
}

// TestGetStoreManagedNoSecrets: cap mode (a gateway, no keys) ends with managed=yes and never prints the gateway URL
// or the token in its path.
func TestGetStoreManagedNoSecrets(t *testing.T) {
	setStoreEnv(t, "https://gw-secret-token.example/tok123", "", "", "", "", "")
	lines := getStoreReply(t)
	wantGetStore(t, lines, "configured=yes", "endpoint=", "region=", "bucket=", "keyset=no", "managed=yes")
	assertGetStoreCarriesNone(t, lines, "https://gw-secret-token.example/tok123", "gw-secret-token", "tok123")
}
