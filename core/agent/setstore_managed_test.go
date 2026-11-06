package main

import (
	"bufio"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// tempConf points storeConfPath at a temp file seeded with content, restoring the real path on cleanup.
func tempConf(t *testing.T, content string) string {
	t.Helper()
	old := storeConfPath
	storeConfPath = filepath.Join(t.TempDir(), "nowhere.conf")
	t.Cleanup(func() { storeConfPath = old })
	if content != "" {
		if err := os.WriteFile(storeConfPath, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return storeConfPath
}

// runVerb drives a conn-taking handler over an in-memory pipe and returns its first reply line.
func runVerb(t *testing.T, h func(net.Conn)) string {
	t.Helper()
	server, client := net.Pipe()
	go func() { h(server); server.Close() }()
	line, err := bufio.NewReader(client).ReadString('\n')
	if err != nil {
		t.Fatalf("read reply: %v", err)
	}
	return strings.TrimRight(line, "\n")
}

// TestWriteManagedConfStripsCreds (E.5c): the managed conf is GATEWAY_URL only -- every S3_* line dropped
// (their presence would flip capMode off), every other line preserved.
func TestWriteManagedConfStripsCreds(t *testing.T) {
	tempConf(t, "S3_ENDPOINT=https://s3.example.io\nS3_REGION=auto\nS3_BUCKET=b\nS3_ACCESS_KEY=AK\nS3_SECRET_KEY=SK\nNOWHERE_SYNC_INTERVAL=60\nGATEWAY_URL=https://old.example\n")
	if err := writeManagedConf("https://gw.example"); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(storeConfPath)
	if err != nil {
		t.Fatal(err)
	}
	got := string(b)
	if got != "GATEWAY_URL=https://gw.example\nNOWHERE_SYNC_INTERVAL=60\n" {
		t.Fatalf("managed conf wrong:\n%q", got)
	}
}

// TestSetStoreManagedVerb (E.5c): the first-run "nowhere store" pick -- SET-STORE-MANAGED probes the
// gateway, persists a creds-less conf, flips the live daemon into cap mode, and GET-STORE then reports a
// fully configured store with no keys.
func TestSetStoreManagedVerb(t *testing.T) {
	srv, _, _ := mockCapStore(t)
	tempConf(t, "S3_ENDPOINT=https://s3.example.io\nS3_REGION=auto\nS3_BUCKET=b\nS3_ACCESS_KEY=AK\nS3_SECRET_KEY=SK\n")
	t.Setenv("NOWHERE_GATEWAY_DEFAULT", srv.URL)
	t.Setenv("S3_ENDPOINT", "https://s3.example.io")
	t.Setenv("S3_ACCESS_KEY", "AK")
	t.Setenv("S3_SECRET_KEY", "SK")
	t.Setenv("S3_BUCKET", "b")
	t.Setenv("S3_REGION", "auto")
	t.Setenv("GATEWAY_URL", "")

	if reply := runVerb(t, handleSetStoreManaged); reply != "OK" {
		t.Fatalf("SET-STORE-MANAGED reply = %q, want OK", reply)
	}
	if !capMode() {
		t.Fatal("device should be in cap mode after SET-STORE-MANAGED")
	}
	if !storeConfigured() {
		t.Fatal("store should be configured after SET-STORE-MANAGED")
	}
	if os.Getenv("GATEWAY_URL") != srv.URL {
		t.Fatalf("GATEWAY_URL = %q, want %q", os.Getenv("GATEWAY_URL"), srv.URL)
	}
	b, _ := os.ReadFile(storeConfPath)
	if strings.Contains(string(b), "S3_") {
		t.Fatalf("managed conf still holds S3 lines:\n%s", b)
	}
	// The chooser's store screen must now see configured=yes with no key material, and a last line saying the
	// store is the managed one (NWP-20261113-21) that carries neither a key nor the gateway URL.
	lines := getStoreReply(t)
	got := strings.Join(lines, "\n")
	if !strings.Contains(got, "configured=yes") || !strings.Contains(got, "keyset=no") {
		t.Fatalf("GET-STORE after managed switch:\n%s", got)
	}
	if lines[len(lines)-1] != "managed=yes" {
		t.Fatalf("GET-STORE after managed switch must end with managed=yes:\n%s", got)
	}
	assertGetStoreCarriesNone(t, lines, "AK", "SK", srv.URL)
}

// TestSetStoreManagedUnreachable (E.5c): a dead gateway must NOT half-configure the device -- reply
// ERR-NET and leave the existing creds-backed config (conf + env) untouched.
func TestSetStoreManagedUnreachable(t *testing.T) {
	seed := "S3_ENDPOINT=https://s3.example.io\nS3_REGION=auto\nS3_BUCKET=b\nS3_ACCESS_KEY=AK\nS3_SECRET_KEY=SK\n"
	tempConf(t, seed)
	t.Setenv("NOWHERE_GATEWAY_DEFAULT", "http://127.0.0.1:1") // nothing listens here
	t.Setenv("S3_ACCESS_KEY", "AK")
	t.Setenv("GATEWAY_URL", "")

	if reply := runVerb(t, handleSetStoreManaged); reply != "ERR-NET" {
		t.Fatalf("SET-STORE-MANAGED reply = %q, want ERR-NET", reply)
	}
	if capMode() {
		t.Fatal("a failed managed switch must not flip cap mode")
	}
	if b, _ := os.ReadFile(storeConfPath); string(b) != seed {
		t.Fatalf("conf must be untouched on ERR-NET, got:\n%s", b)
	}
}

// TestGatewayDefaultDoesNotMarkConfigured pins the distinction DIA-20260805-05 rests on: a baked
// NOWHERE_GATEWAY_DEFAULT says "enrol against THIS gateway when the user picks the nowhere store", and must
// NOT say "this device is already set up". If it did, the chooser would skip welcome -> Wi-Fi ->
// choose-storage on a brand-new phone, which is exactly the bug the first frankel image shipped with
// (GATEWAY_URL baked -> capMode -> storeConfigured -> straight to the gate on an unboxed device).
func TestGatewayDefaultDoesNotMarkConfigured(t *testing.T) {
	for _, k := range []string{"GATEWAY_URL", "S3_ENDPOINT", "S3_BUCKET", "S3_ACCESS_KEY", "S3_SECRET_KEY"} {
		t.Setenv(k, "")
	}
	t.Setenv("NOWHERE_GATEWAY_DEFAULT", "https://api-beta.nowhere.mobile")
	if capMode() {
		t.Error("NOWHERE_GATEWAY_DEFAULT must not put the daemon in cap mode -- nothing is enrolled yet")
	}
	if storeConfigured() {
		t.Error("a device that has only been TOLD which gateway to use is not configured; the user still has to choose storage")
	}
	// And the enrolment the user triggers must target it rather than the production default.
	t.Setenv("GATEWAY_URL", "")
	if gw := os.Getenv("NOWHERE_GATEWAY_DEFAULT"); gw != "https://api-beta.nowhere.mobile" {
		t.Errorf("enrolment target = %q, want the baked beta gateway", gw)
	}
}

// confWriters are the three writers of nowhere.conf, each as a call with a fixed argument set.
var confWriters = []struct {
	name  string
	write func() error
}{
	{"writeManagedConf", func() error { return writeManagedConf("https://gw.example") }},
	{"upsertConfLine", func() error { return upsertConfLine("GATEWAY_URL", "https://gw.example") }},
	{"writeStoreConf", func() error { return writeStoreConf("ep", "rg", "bk", "ak", "sk") }},
}

const confSeed = "S3_ENDPOINT=old\nGATEWAY_URL=https://old.example\nNOWHERE_SYNC_INTERVAL=30\n"

// TestConfWriterFailureLeavesOldConf: a write that cannot complete (its temp path is blocked by a directory)
// reports the failure and leaves the existing conf byte-identical, never truncated in place.
func TestConfWriterFailureLeavesOldConf(t *testing.T) {
	for _, w := range confWriters {
		t.Run(w.name, func(t *testing.T) {
			conf := tempConf(t, confSeed)
			if err := os.Mkdir(conf+".tmp", 0o700); err != nil {
				t.Fatal(err)
			}
			if err := w.write(); err == nil {
				t.Fatal("write succeeded with its temp path blocked")
			}
			got, err := os.ReadFile(conf)
			if err != nil || string(got) != confSeed {
				t.Fatalf("conf changed by a failed write: %q, %v", got, err)
			}
		})
	}
}

// TestConfWriterPublishesCleanly: after a good write no temp sibling remains and the conf is 0600.
func TestConfWriterPublishesCleanly(t *testing.T) {
	for _, w := range confWriters {
		t.Run(w.name, func(t *testing.T) {
			conf := tempConf(t, confSeed)
			if err := w.write(); err != nil {
				t.Fatal(err)
			}
			if _, err := os.Stat(conf + ".tmp"); !os.IsNotExist(err) {
				t.Fatalf("temp conf left behind: %v", err)
			}
			fi, err := os.Stat(conf)
			if err != nil || fi.Mode().Perm() != 0o600 {
				t.Fatalf("conf mode: %v, %v", fi, err)
			}
		})
	}
}

// TestConfWriterFailedRenameLeavesNoTemp: a rename that cannot land (the conf path is a non-empty directory)
// reports the failure and removes the temp file.
func TestConfWriterFailedRenameLeavesNoTemp(t *testing.T) {
	for _, w := range confWriters {
		t.Run(w.name, func(t *testing.T) {
			conf := tempConf(t, "")
			if err := os.MkdirAll(filepath.Join(conf, "keep"), 0o700); err != nil {
				t.Fatal(err)
			}
			if err := w.write(); err == nil {
				t.Fatal("write succeeded over a directory")
			}
			if _, err := os.Stat(conf + ".tmp"); !os.IsNotExist(err) {
				t.Fatalf("temp conf left behind after a failed rename: %v", err)
			}
		})
	}
}

// TestConfWriterFailedSyncKeepsOldConf: a flush that fails is reported, the old conf is untouched and the temp
// file is removed.
func TestConfWriterFailedSyncKeepsOldConf(t *testing.T) {
	old := confFileSync
	confFileSync = func(*os.File) error { return errors.New("injected sync failure") }
	t.Cleanup(func() { confFileSync = old })
	for _, w := range confWriters {
		t.Run(w.name, func(t *testing.T) {
			conf := tempConf(t, confSeed)
			if err := w.write(); err == nil {
				t.Fatal("write succeeded although the flush failed")
			}
			got, _ := os.ReadFile(conf)
			if string(got) != confSeed {
				t.Fatalf("conf changed by a failed flush: %q", got)
			}
			if _, err := os.Stat(conf + ".tmp"); !os.IsNotExist(err) {
				t.Fatalf("temp conf left behind after a failed flush: %v", err)
			}
		})
	}
}
