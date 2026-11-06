package main

import (
	"os"
	"strings"
	"testing"
	"time"
)

// NWP-20261019-12: the OTA-VERSIONS line a tap on "Check for updates" waits on.
func withOtaState(t *testing.T, at, tried time.Time, lastErr string, refreshing bool) {
	t.Helper()
	save := func() (time.Time, time.Time, string, bool) {
		otaCacheMu.Lock()
		defer otaCacheMu.Unlock()
		return otaCacheAt, otaLastTry, otaLastErr, otaRefreshing
	}
	a, tr, e, r := save()
	t.Cleanup(func() {
		otaCacheMu.Lock()
		otaCacheAt, otaLastTry, otaLastErr, otaRefreshing = a, tr, e, r
		otaCacheMu.Unlock()
	})
	otaCacheMu.Lock()
	otaCacheAt, otaLastTry, otaLastErr, otaRefreshing = at, tried, lastErr, refreshing
	otaCacheMu.Unlock()
}

func TestOtaVersionsLineKeepsTheFieldedPrefix(t *testing.T) {
	withOtaState(t, time.Time{}, time.Time{}, "", false)
	f := strings.Fields(otaVersionsLine("0.5.4"))
	want := []string{"running", "0.5.4", "checked", "-1", "lasterr", "none", "store"}
	for i, w := range want {
		if f[i] != w {
			t.Fatalf("field %d = %q, want %q (line %v)", i, f[i], w, f)
		}
	}
	if f[7] != "yes" && f[7] != "no" {
		t.Fatalf("store value = %q", f[7])
	}
	if f[8] != "tried_ms" || f[10] != "refreshing" || len(f) != 12 {
		t.Fatalf("the new keys must follow the fielded eight, got %v", f)
	}
}

func TestOtaVersionsLineTriedMs(t *testing.T) {
	withOtaState(t, time.Time{}, time.Time{}, "", false)
	if f := strings.Fields(otaVersionsLine("1")); f[9] != "-1" {
		t.Errorf("before any refresh tried_ms = %q, want -1", f[9])
	}
	tried := time.UnixMilli(1792454400123)
	withOtaState(t, time.Unix(1792454400, 0), tried, "unreachable", false)
	f := strings.Fields(otaVersionsLine("1"))
	if f[9] != "1792454400123" {
		t.Errorf("tried_ms = %q, want the stamp in milliseconds", f[9])
	}
	if f[5] != "unreachable" || f[3] != "1792454400" {
		t.Errorf("checked/lasterr changed: %v", f)
	}
}

func TestOtaVersionsLineRefreshing(t *testing.T) {
	withOtaState(t, time.Time{}, time.Time{}, "", true)
	if f := strings.Fields(otaVersionsLine("1")); f[11] != "1" {
		t.Errorf("refreshing = %q while the flag is set, want 1", f[11])
	}
	withOtaState(t, time.Time{}, time.Time{}, "", false)
	if f := strings.Fields(otaVersionsLine("1")); f[11] != "0" {
		t.Errorf("refreshing = %q with the flag clear, want 0", f[11])
	}
}

// The handler must reply through the helper, not a second hand-built line.
func TestOtaVersionsHandlerUsesTheHelper(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	i := strings.Index(src, `if name == "OTA-VERSIONS" {`)
	if i < 0 {
		t.Fatal("OTA-VERSIONS handler not found")
	}
	body := src[i:]
	if j := strings.Index(body, `if name == "OTA-APPLY" {`); j > 0 {
		body = body[:j]
	}
	if !strings.Contains(body, "fmt.Fprint(conn, otaVersionsLine(running))") {
		t.Error("the OTA-VERSIONS handler does not reply with otaVersionsLine(running)")
	}
	if strings.Contains(body, "store %s") {
		t.Error("the OTA-VERSIONS handler still formats its own line")
	}
}
