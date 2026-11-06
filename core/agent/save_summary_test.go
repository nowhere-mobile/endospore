package main

import "testing"

// #145 S6 (NWP-20260901-30): the save-composition accumulator. The frames are the seal's own progress
// stream; the LAST frame per scope is that scope's final done-byte figure, and a frame with no scope field
// belongs to no area.
func TestAccumSaveScope(t *testing.T) {
	m := map[string]int64{}
	accumSaveScope(m, "save 100 200 vault")
	accumSaveScope(m, "save 1500 2000 vault") // later frame WINS -- it is the final figure
	accumSaveScope(m, "save 300 300 media")
	accumSaveScope(m, "prepare 50 100") // 3-field: no scope, no area -- ignored
	accumSaveScope(m, "save x 300 de")  // unparseable done -- ignored
	accumSaveScope(m, "save -5 300 de") // negative -- ignored
	if len(m) != 2 {
		t.Fatalf("areas = %d (%v), want 2", len(m), m)
	}
	if m["vault"] != 1500 {
		t.Errorf("vault = %d, want 1500 (last frame wins)", m["vault"])
	}
	if m["media"] != 300 {
		t.Errorf("media = %d, want 300", m["media"])
	}
}

func TestPublishSaveSummary(t *testing.T) {
	lastSaveBytes.Store(0)
	lastSaveAreas.Store(0)
	lastSaveSeq.Store(0)
	t.Cleanup(func() { lastSaveBytes.Store(0); lastSaveAreas.Store(0); lastSaveSeq.Store(0) })
	publishSaveSummary(map[string]int64{"vault": 1500, "media": 300, "de": 0}, 7)
	if lastSaveBytes.Load() != 1800 {
		t.Errorf("bytes = %d, want 1800", lastSaveBytes.Load())
	}
	if lastSaveAreas.Load() != 3 {
		t.Errorf("areas = %d, want 3", lastSaveAreas.Load())
	}
	if lastSaveSeq.Load() != 7 {
		t.Errorf("seq = %d, want 7 (the landed-seal sequence it was given, #55)", lastSaveSeq.Load())
	}
}
