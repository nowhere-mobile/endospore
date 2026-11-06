package main

// NWP-20261013-36: the #134 essential->deferred migration credit that keeps "log in, use one app, log off" sealable
// on an on-demand #media profile. deferredGrowth and shrinkWalkExplains are the pure halves of the pushProfile
// shrink guard's ALLOWED arm; before they were extracted no test exercised that arm, so dropping defMigrated from
// the sum or removing the clamp passed CI.

import (
	"os"
	"strings"
	"testing"
)

func defSet(sizes ...int64) map[string]deferredFile {
	m := map[string]deferredFile{}
	for i, sz := range sizes {
		m[string(rune('a'+i))] = deferredFile{Size: sz}
	}
	return m
}

func TestDeferredGrowth(t *testing.T) {
	cases := []struct {
		name     string
		old, new map[string]deferredFile
		want     int64
	}{
		{"migration credits the growth", defSet(10), defSet(10, 90), 90},
		{"from nothing", nil, defSet(5, 5), 10},
		{"shrinkage is zero, never negative", defSet(100, 50), defSet(20), 0},
		{"unchanged", defSet(7), defSet(7), 0},
		{"both empty", nil, nil, 0},
	}
	for _, c := range cases {
		if got := deferredGrowth(c.old, c.new); got != c.want {
			t.Errorf("%s: deferredGrowth = %d, want %d", c.name, got, c.want)
		}
	}
}

func TestShrinkWalkExplains(t *testing.T) {
	cases := []struct {
		name               string
		dropped, mig, lost int64
		want               bool
	}{
		{"migration alone covers the loss", 0, 100, 80, true},
		{"credit equals lost allows", 40, 60, 100, true},
		{"lost exceeds credit refuses", 40, 59, 100, false},
		{"sealDropped-only credit allows", 100, 0, 100, true},
		{"zero credit, lost <= 0 refuses via > 0", 0, 0, 0, false},
		{"zero credit, negative lost refuses", 0, 0, -5, false},
		{"positive credit, lost <= 0 allows", 0, 1, 0, true},
	}
	for _, c := range cases {
		if got := shrinkWalkExplains(c.dropped, c.mig, c.lost); got != c.want {
			t.Errorf("%s: shrinkWalkExplains(%d,%d,%d) = %v, want %v", c.name, c.dropped, c.mig, c.lost, got, c.want)
		}
	}
}

// The guard must go through the helpers, or the truth tables above pin nothing.
func TestShrinkGuardUsesCreditHelpers(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	for _, need := range []string{"case shrinkWalkExplains(sealDropped, defMigrated, lost):", "defMigrated := deferredGrowth(oldM.Deferred, deferredMap)"} {
		if !strings.Contains(src, need) {
			t.Errorf("pushProfile's shrink guard no longer contains %q", need)
		}
	}
}
