package main

import (
	"encoding/hex"
	"encoding/json"
	"io"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"testing"
	"time"
)

// These run the display verbs' refusal and success arms. TestTheDisplayVerbsAreWiredAndRefuseRatherThanUnderstate
// used to pin them by searching function bodies for literals, which proves the code exists and never that
// anything reaches it. The handlers hardcode the "s3" store, so the store reads go through two package-level
// seams (footprintOf, storePkgBytesOf, storeFolderBytesOf) that the tests replace.

const (
	dvName = "dvprofile"
	dvPass = "dv-pass-not-real"
	dvSE   = "a1b2c3d4"
)

// dvSession writes a complete .roamsession carrying a NON-EMPTY secure-element secret and returns the dest.
func dvSession(t *testing.T) string {
	t.Helper()
	dest := t.TempDir()
	body := dvName + "\n" + dvPass + "\n10\n" + dvSE + "\n"
	if err := os.WriteFile(filepath.Join(dest, roamSessionFile), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return dest
}

// dvDrive runs a handler over net.Pipe and returns everything it wrote.
func dvDrive(t *testing.T, h func(net.Conn, string), dest string) string {
	t.Helper()
	server, client := net.Pipe()
	go func() {
		h(server, dest)
		server.Close()
	}()
	client.SetReadDeadline(time.Now().Add(10 * time.Second))
	b, err := io.ReadAll(client)
	client.Close()
	if err != nil {
		t.Fatalf("reading the handler's reply: %v", err)
	}
	return string(b)
}

// dvStubFootprint replaces footprintOf for one test, recording the secret it was handed.
func dvStubFootprint(t *testing.T, refs map[string]int64, measured bool) *[]byte {
	t.Helper()
	var gotSE []byte
	called := false
	old := footprintOf
	footprintOf = func(base, profile, pass string, se []byte) (map[string]int64, bool) {
		called = true
		gotSE = se
		if base != "s3" || profile != dvName || pass != dvPass {
			t.Errorf("footprintOf(%q, %q, %q): wrong store or session credentials", base, profile, pass)
		}
		return refs, measured
	}
	t.Cleanup(func() {
		footprintOf = old
		if !called {
			t.Error("the handler never reached footprintOf")
		}
	})
	return &gotSE
}

func dvWantSE(t *testing.T, got []byte) {
	t.Helper()
	want, _ := hex.DecodeString(dvSE)
	if len(want) == 0 || !reflect.DeepEqual(got, want) {
		t.Errorf("footprintOf received se=%x, want seFromSession(dest) = %x -- without it a hardened profile "+
			"is measured from its head refs alone", got, want)
	}
}

func TestSeamsDefaultToTheRealStoreReaders(t *testing.T) {
	if reflect.ValueOf(footprintOf).Pointer() != reflect.ValueOf(profileFootprint).Pointer() {
		t.Error("footprintOf does not default to profileFootprint")
	}
	if reflect.ValueOf(storePkgBytesOf).Pointer() != reflect.ValueOf(storePkgBytes).Pointer() {
		t.Error("storePkgBytesOf does not default to storePkgBytes")
	}
	if reflect.ValueOf(storeFolderBytesOf).Pointer() != reflect.ValueOf(storeFolderBytes).Pointer() {
		t.Error("storeFolderBytesOf does not default to storeFolderBytes")
	}
}

func TestGetUsageAndGetFootprintAnswerNoneAndLocal(t *testing.T) {
	for name, h := range map[string]func(net.Conn, string){"GET-USAGE": handleGetUsage, "GET-FOOTPRINT": handleGetFootprint} {
		t.Run(name, func(t *testing.T) {
			if got := dvDrive(t, h, t.TempDir()); got != "NONE\n" {
				t.Errorf("no session: %q, want NONE", got)
			}
			dest := dvSession(t)
			if err := os.WriteFile(filepath.Join(dest, ".localsession"), []byte("1\n"), 0o600); err != nil {
				t.Fatal(err)
			}
			if got := dvDrive(t, h, dest); got != "LOCAL\n" {
				t.Errorf("local session: %q, want LOCAL", got)
			}
		})
	}
}

func TestGetUsageRefusesAnUnmeasuredFootprintAndSumsAMeasuredOne(t *testing.T) {
	dest := dvSession(t)
	t.Run("unmeasured", func(t *testing.T) {
		se := dvStubFootprint(t, map[string]int64{"a": 5}, false)
		if got := dvDrive(t, handleGetUsage, dest); got != "UNMEASURED\n" {
			t.Errorf("got %q, want UNMEASURED", got)
		}
		dvWantSE(t, *se)
	})
	t.Run("measured", func(t *testing.T) {
		se := dvStubFootprint(t, map[string]int64{"b": 3, "a": 5}, true)
		if got := dvDrive(t, handleGetUsage, dest); got != "OK bytes=8\n" {
			t.Errorf("got %q, want OK bytes=8", got)
		}
		dvWantSE(t, *se)
	})
}

func TestGetFootprintRefusesAnUnmeasuredFootprintAndListsAMeasuredOne(t *testing.T) {
	dest := dvSession(t)
	t.Run("unmeasured", func(t *testing.T) {
		se := dvStubFootprint(t, map[string]int64{"a": 5}, false)
		if got := dvDrive(t, handleGetFootprint, dest); got != "ERR-UNMEASURED\n" {
			t.Errorf("got %q, want ERR-UNMEASURED", got)
		}
		dvWantSE(t, *se)
	})
	t.Run("measured", func(t *testing.T) {
		se := dvStubFootprint(t, map[string]int64{"b": 3, "a": 5}, true)
		body := "a\t5\nb\t3\n"
		want := "OK " + strconv.Itoa(len(body)) + "\n" + body
		if got := dvDrive(t, handleGetFootprint, dest); got != want {
			t.Errorf("got %q, want %q", got, want)
		}
		dvWantSE(t, *se)
	})
}

func dvStubPkgBytes(t *testing.T) {
	t.Helper()
	old := storePkgBytesOf
	storePkgBytesOf = func(base, profile, pass string, se []byte) (map[string]int64, map[string]bool, bool, bool) {
		return map[string]int64{"com.a": 40, "com.b": 2}, map[string]bool{"com.a": true}, true, true
	}
	oldF := storeFolderBytesOf
	storeFolderBytesOf = func(base, profile, pass string, se []byte) (map[string]int64, bool) { return nil, false }
	t.Cleanup(func() { storePkgBytesOf, storeFolderBytesOf = old, oldF })
}

const dvWorkerJSON = `{"apps":[{"pkg":"com.a","bytes":100,"mode":"installed"}],"media_bytes":1,"cache_bytes":0,"total_bytes":101,"blind":0}`

func TestBreakdownMergeServesTheLocalWalkWhenTheFootprintIsUnmeasured(t *testing.T) {
	dvStubPkgBytes(t)
	se := dvStubFootprint(t, map[string]int64{"x": 1}, false)
	se2, _ := hex.DecodeString(dvSE)
	got, err := withStoreBytes(dvWorkerJSON, dvName, dvPass, se2)
	if err != nil {
		t.Fatal(err)
	}
	if got != dvWorkerJSON {
		t.Errorf("an unmeasured footprint must return the worker JSON unchanged (no store numbers rather than "+
			"wrong ones), got %s", got)
	}
	var b storageBreakdown
	if err := json.Unmarshal([]byte(got), &b); err != nil || b.StoreMeasured {
		t.Errorf("StoreMeasured must be false (err=%v)", err)
	}
	dvWantSE(t, *se)
}

func TestBreakdownMergeFillsTheStoreNumbersFromAMeasuredFootprint(t *testing.T) {
	dvStubPkgBytes(t)
	se := dvStubFootprint(t, map[string]int64{"x": 30, "y": 20}, true)
	se2, _ := hex.DecodeString(dvSE)
	got, err := withStoreBytes(dvWorkerJSON, dvName, dvPass, se2)
	if err != nil {
		t.Fatal(err)
	}
	var b storageBreakdown
	if err := json.Unmarshal([]byte(got), &b); err != nil {
		t.Fatal(err)
	}
	if !b.StoreMeasured || b.StoreTotal != 50 || b.StoreOther != 8 {
		t.Errorf("StoreMeasured=%v StoreTotal=%d StoreOther=%d, want true 50 8 (50 billed, 42 attributed)",
			b.StoreMeasured, b.StoreTotal, b.StoreOther)
	}
	dvWantSE(t, *se)
}

func TestBreakdownMergeRefusesAnEmptySessionKey(t *testing.T) {
	if _, err := withStoreBytes(dvWorkerJSON, dvName, "", nil); err == nil {
		t.Error("an empty session key must be refused")
	}
}
