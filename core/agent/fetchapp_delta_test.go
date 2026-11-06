package main

import (
	"os"
	"strings"
	"testing"
)

func TestFetchAppAddBytes(t *testing.T) {
	stored := map[string]int64{"org.a": 300, "org.big": 900, "org.zero": 0}
	cases := []struct {
		name     string
		stored   map[string]int64
		measured bool
		pkg      string
		want     int64
	}{
		{"fresh install, no entry", stored, true, "org.new", 500},
		{"update, stored below estimate", stored, true, "org.a", 200},
		{"update, stored above estimate", stored, true, "org.big", 0},
		{"stored equals estimate", map[string]int64{"org.e": 500}, true, "org.e", 0},
		{"unknown ignores a held entry", stored, false, "org.big", 500},
		{"unknown ignores a small entry", stored, false, "org.a", 500},
		{"nil map", nil, true, "org.a", 500},
		{"zero entry is not a size", stored, true, "org.zero", 500},
		{"other package's entry ignored", stored, true, "org.other", 500},
	}
	for _, c := range cases {
		if got := fetchAppAddBytes(500, c.stored, c.measured, c.pkg); got != c.want {
			t.Errorf("%s: got %d, want %d", c.name, got, c.want)
		}
	}
}

// handleFetchApp must feed installHeadroom the helper's result, not the raw estimate.
func TestHandleFetchAppGatesOnDelta(t *testing.T) {
	b, err := os.ReadFile("catalog.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	i := strings.Index(src, "func handleFetchApp(")
	if i < 0 {
		t.Fatal("handleFetchApp not found")
	}
	body := src[i:]
	if !strings.Contains(body, "gateAdd := fetchAppAddBytes(estAdd, stored, measured, pkg)") {
		t.Error("handleFetchApp does not compute gateAdd via fetchAppAddBytes")
	}
	if !strings.Contains(body, "capWalletPath(), gateAdd,") {
		t.Error("installHeadroom is not passed gateAdd")
	}
	if strings.Contains(body, "capWalletPath(), estAdd,") {
		t.Error("installHeadroom is passed the raw estAdd")
	}
	if !strings.Contains(body, "overPlanReply(short, used, covered, gateAdd)") {
		t.Error("refusal does not carry the gated bytes")
	}
}
